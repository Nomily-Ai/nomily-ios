import CoreBluetooth
import CoreLocation
import Foundation
import os.log
import UserNotifications

private let log = Logger(subsystem: "com.nomily.app.ios", category: "card-finder")

/// "Find my card" fallback that needs **no firmware support** (任务八 · 8.1).
///
/// ## Why it exists
/// Plaud ships Apple Find My and nothing else; there is no BLE beep command in
/// their SDK at all (verified by grep over the full string table: only
/// `getFindMyState` / `sendFindMyToken` / `resetFindmy`, no buzzer/beep
/// command). Task 8.2 (an actual `CMD_FIND_DEVICE`) waits on firmware. Until
/// then the honest, useful subset is pure App:
///
/// 1. **Last seen** — when the link drops, remember the time (and, when the
///    user allows it, a coarse location) so the app can answer "when/where did
///    I last have it".
/// 2. **Proximity** — while the find page is open, scan for the card's
///    advertisement and map RSSI to three tiers (far / near / very near), so
///    walking around tells you whether you are getting warmer.
/// 3. **Drop alert** — an optional local notification when a connected card
///    disappears (left behind on a table, slipped out of a bag).
///
/// ## Boundaries (written into the UI as well)
/// BLE reaches ~10–30 m. This finds a card in the sofa or a bag; it is not a
/// city-wide locator, and it never turns the card into a beacon that strangers
/// can trigger (anti-stalking — the same reason Plaud goes through Apple's
/// certification instead of rolling their own).
@MainActor
final class PlaudCardFinder: NSObject, ObservableObject {

    static let shared = PlaudCardFinder()

    /// 0–3: unknown / far / near / very near.
    enum Proximity: Int {
        case unknown = 0, far, near, veryNear
    }

    @Published private(set) var proximity: Proximity = .unknown
    @Published private(set) var rssi: Int?
    @Published private(set) var isScanning = false
    @Published private(set) var lastSeenAt: Date?
    /// Human-readable place of the last disconnect ("Starbucks · 五道口" or a
    /// coordinate string when reverse geocoding is unavailable).
    @Published private(set) var lastSeenPlace: String?
    /// The raw fix behind `lastSeenPlace`, kept so the page can draw a map
    /// thumbnail instead of only naming a street.
    @Published private(set) var lastSeenCoordinate: CLLocationCoordinate2D?
    /// True when there is no location permission at all — the page shows an
    /// explanation instead of a silently empty row.
    @Published private(set) var locationDenied = false
    /// Notification permission is off. 2026-10-22 ("卡片断开提醒手机没任何响铃"):
    /// the old code asked for permission *at the moment of the drop* and silently
    /// dropped the alert when the answer was no, so "nothing happened" was the
    /// normal outcome. The page now says so up front and offers a test.
    @Published private(set) var notificationsDenied = false
    /// Where this card was last seen, newest first, so "it was here an hour ago,
    /// then there" is answerable at all.
    @Published private(set) var history: [Seen] = []
    @Published var notifyOnDisconnect: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnDisconnect, forKey: Self.notifyKey)
            // Ask while the user is *looking at the switch they just turned on*,
            // not three days later at the moment a card is lost.
            if notifyOnDisconnect { requestNotificationPermission() }
        }
    }

    /// One "last seen" record. Coordinates are optional because location may be
    /// denied, and a record with a time but no place is still useful.
    struct Seen: Codable, Identifiable, Equatable {
        var at: Date
        var place: String?
        var latitude: Double?
        var longitude: Double?
        var id: Date { at }
        var coordinate: CLLocationCoordinate2D? {
            guard let latitude, let longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    /// The advertisement name to look for (e.g. the card's BLE name), as read
    /// from the scan result. Matching is deliberately fuzzy — see `matches(_:)`.
    var targetName: String?
    /// What the find page calls the card ("PLAUD NotePin", or the alias the
    /// user gave it). Display only — never used for matching.
    @Published private(set) var targetLabel: String?

    /// Names PLAUD cards actually advertise under, used when `targetName` is
    /// empty (the card was re-bound from a cold launch and the scan result is
    /// gone). Scanning runs with `withServices: nil` so it sees every nearby
    /// peripheral — AirPods, a keyboard — hence the list stays PLAUD-specific
    /// rather than matching "note" and pinging on a neighbour's laptop.
    ///
    /// ★ 2026-10-22 ("其他的几款卡片也要加入一下"): the finder is no longer
    /// PLAUD-only. Every recorder the app can pair advertises under one of these
    /// families — PLAUD's Note/NotePin, TicNote, DingTalk A1 — so the same
    /// proximity radar works for whichever card is in hand. Names stay specific
    /// enough not to latch onto a neighbour's headphones.
    private static let nameHints = [
        "plaud", "notepin", "note pin", "notepro", "note pro", "notecard",
        "ticnote", "tic note", "dingtalk a1", "dingtalk",
    ]

    private var central: CBCentralManager?
    private let location = CLLocationManager()
    private var scanTimer: Task<Void, Never>?
    private static let notifyKey = "plaud.notify_disconnect"
    private static let lastSeenKey = "plaud.last_seen_at"
    private static let lastSeenPlaceKey = "plaud.last_seen_place"
    private static let lastSeenLatKey = "plaud.last_seen_lat"
    private static let lastSeenLonKey = "plaud.last_seen_lon"
    private static let historyKey = "plaud.last_seen_history"
    /// A card is not a tracker: 20 entries is enough to answer "where did I leave
    /// it today" without keeping a movement log on the device.
    private static let historyLimit = 20

    private override init() {
        notifyOnDisconnect = UserDefaults.standard.object(forKey: Self.notifyKey) as? Bool ?? true
        lastSeenAt = UserDefaults.standard.object(forKey: Self.lastSeenKey) as? Date
        lastSeenPlace = UserDefaults.standard.string(forKey: Self.lastSeenPlaceKey)
        // Restore the pin too — otherwise the map thumbnail vanished on every
        // relaunch while the "last seen" timestamp survived, which reads as a bug.
        if UserDefaults.standard.object(forKey: Self.lastSeenLatKey) != nil {
            let lat = UserDefaults.standard.double(forKey: Self.lastSeenLatKey)
            let lon = UserDefaults.standard.double(forKey: Self.lastSeenLonKey)
            if lat != 0 || lon != 0 {
                lastSeenCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        if let data = UserDefaults.standard.data(forKey: Self.historyKey),
           let saved = try? JSONDecoder().decode([Seen].self, from: data) {
            history = saved
        }
        super.init()
        // Foreground delivery: without a delegate, iOS suppresses a notification
        // that fires while the app is open — which is exactly when a BLE drop is
        // noticed, so the alert looked broken by design.
        UNUserNotificationCenter.current().delegate = self
        refreshNotificationStatus()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    // MARK: - Link lifecycle (called by PlaudDirectService)

    /// A link came up: remember that the card is with us right now.
    func noteConnected() {
        lastSeenAt = Date()
        UserDefaults.standard.set(lastSeenAt, forKey: Self.lastSeenKey)
        // Warm the authorization prompt once, at a moment that makes sense.
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        }
        locationDenied = location.authorizationStatus == .denied
            || location.authorizationStatus == .restricted
        // ★ 2026-10-22: same reasoning for notifications. The toggle ships ON,
        // so a fresh install would never ask and every drop alert would then be
        // suppressed — the reported "no sound at all". Asking at connect time
        // ("the card is with you now") is the natural moment, and it is gated on
        // `notDetermined`, so it happens at most once.
        if notifyOnDisconnect { requestNotificationPermissionIfNeeded() }
    }

    /// Ask only when iOS has never been asked, so the system prompt cannot
    /// reappear on every connect.
    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            Task { @MainActor in self.requestNotificationPermission() }
        }
    }

    /// The link dropped. `unexpected` drives the notification: a user who
    /// pressed "disconnect" does not need to be told the card is gone.
    ///
    /// Note the double-call guard: `disconnect()` reports the drop itself *and*
    /// the SDK's `bleDeviceDisconnectErr` fires right after, so without it the
    /// user gets two notifications for one disconnect.
    func noteDisconnected(unexpected: Bool, cardName: String?) {
        let now = Date()
        lastSeenAt = now
        UserDefaults.standard.set(now, forKey: Self.lastSeenKey)
        // Record first, then geocode: the time is known immediately, the place
        // arrives a second later and patches the same entry.
        recordSeen(at: now, place: lastSeenPlace, coordinate: lastSeenCoordinate)
        capturePlace()
        guard unexpected, notifyOnDisconnect else { return }
        guard Date().timeIntervalSince(lastDropAlertAt) > 5 else { return }
        lastDropAlertAt = Date()
        deliver(title: L10n.Find.title,
                body: L10n.Find.dropBody(cardName ?? targetLabel ?? L10n.Find.thisCard))
    }

    /// The phone stopped listening rather than the card walking away.
    ///
    /// ★ 2026-10-22 ("卡片断开时候通知我，包含手机蓝牙直接关闭"): switching
    /// Bluetooth off in Control Centre doesn't produce the SDK's disconnect
    /// callback — the central manager itself is gone — so the "out of range"
    /// path never ran and the phone stayed silent. The watchdog that notices the
    /// adapter leaving `.poweredOn` calls this instead.
    ///
    /// Still records the point: "where was the card when I lost the link" is a
    /// property of the disconnect, not of its cause.
    func noteBluetoothOff(cardName: String?) {
        let now = Date()
        lastSeenAt = now
        UserDefaults.standard.set(now, forKey: Self.lastSeenKey)
        recordSeen(at: now, place: lastSeenPlace, coordinate: lastSeenCoordinate)
        capturePlace()
        guard notifyOnDisconnect else { return }
        guard now.timeIntervalSince(lastDropAlertAt) > 5 else { return }
        lastDropAlertAt = now
        let name = cardName ?? targetLabel ?? L10n.Find.thisCard
        deliver(title: L10n.Find.title, body: L10n.Find.bluetoothOffBody(name))
    }

    /// Register the card the app just connected to, so the radar looks for the
    /// right name. Called by every recorder, not only PLAUD.
    ///
    /// `cardName` is the **advertised** BLE name (`DiscoveredRecorder.name`) —
    /// that is what `CBAdvertisementDataLocalNameKey` carries. `label` is what
    /// the page shows in its header (`recorder.displayName`, i.e. the user's
    /// alias when there is one); it never takes part in matching, because an
    /// alias is app-side text the radio never sees.
    func register(cardName: String?, label: String? = nil) {
        if let cardName, !cardName.isEmpty { targetName = cardName }
        if let label, !label.isEmpty { targetLabel = label }
        noteConnected()
    }

    /// The name for the section header ("Find PLAUD NotePin"), so the page is
    /// explicit about *which* card it is looking for once several are paired.
    var displayName: String? { targetLabel }

    // MARK: - History

    private func recordSeen(at date: Date, place: String?, coordinate: CLLocationCoordinate2D?) {
        history.insert(Seen(at: date, place: place,
                            latitude: coordinate?.latitude, longitude: coordinate?.longitude),
                       at: 0)
        if history.count > Self.historyLimit {
            history = Array(history.prefix(Self.historyLimit))
        }
        persistHistory()
    }

    /// The geocoder answers after the record exists — fill in that entry rather
    /// than appending a second one for the same disconnect.
    private func patchNewestSeen(place: String?, coordinate: CLLocationCoordinate2D?) {
        guard !history.isEmpty else { return }
        history[0].place = place
        history[0].latitude = coordinate?.latitude
        history[0].longitude = coordinate?.longitude
        persistHistory()
    }

    func clearHistory() {
        history = []
        persistHistory()
    }

    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private var lastDropAlertAt = Date.distantPast

    /// Called by the page so a permission granted in Settings shows up without
    /// a relaunch.
    func refreshLocationStatus() {
        locationDenied = location.authorizationStatus == .denied
            || location.authorizationStatus == .restricted
    }

    // MARK: - Proximity scanning

    /// Start / stop the RSSI scan. The page owns the lifetime — a background
    /// scan would only cost battery.
    func setScanning(_ on: Bool) {
        guard on != isScanning else { return }
        isScanning = on
        if on {
            if central == nil {
                central = CBCentralManager(delegate: self, queue: .main)
            } else {
                beginScanIfReady()
            }
            // RSSI only updates on advertisement; a 500 ms cadence is the
            // requested granularity and costs nothing extra (the radio is the
            // same one the link already uses).
            scanTimer?.cancel()
            scanTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let self, self.isScanning else { return }
                    self.recomputeStaleness()
                }
            }
        } else {
            central?.stopScan()
            scanTimer?.cancel()
            scanTimer = nil
            proximity = .unknown
            rssi = nil
        }
    }

    private func beginScanIfReady() {
        guard let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    /// RSSI → tier. Thresholds come from typical BLE behaviour at 0 dBm
    /// advertising power: −55 is "arm's length", −75 is "same room".
    private func update(rssi value: Int) {
        rssi = value
        if value >= -60 {
            proximity = .veryNear
        } else if value >= -75 {
            proximity = .near
        } else {
            proximity = .far
        }
    }

    private var lastAdvAt = Date.distantPast

    /// No advertisement for 3 s = out of range; say "unknown" rather than
    /// freezing the last (misleading) tier.
    private func recomputeStaleness() {
        guard Date().timeIntervalSince(lastAdvAt) > 3 else { return }
        proximity = .unknown
        rssi = nil
    }

    // MARK: - Location (coarse, only on drop)

    /// Coarse place for the drop record. `requestLocation()` gives one fix and
    /// stops — no continuous tracking, no background location, nothing that
    /// would drain the battery or look like surveillance in App Review.
    private func capturePlace() {
        refreshLocationStatus()
        guard location.authorizationStatus == .authorizedWhenInUse
                || location.authorizationStatus == .authorizedAlways else {
            if location.authorizationStatus == .notDetermined {
                location.requestWhenInUseAuthorization()
            }
            return
        }
        location.requestLocation()
    }

    // MARK: - Notification

    /// ★ 2026-10-22 ("卡片断开提醒手机没任何响铃"). Three separate reasons the old
    /// version was silent, all fixed here:
    ///
    /// 1. it asked for permission **at delivery time** and gave up on `granted ==
    ///    false` — a first-time user, i.e. almost everyone, got nothing;
    /// 2. with no `UNUserNotificationCenterDelegate`, iOS suppresses a
    ///    notification posted while the app is in the foreground, which is exactly
    ///    when a BLE drop is witnessed;
    /// 3. nothing was logged, so "did we even try?" was unanswerable.
    func deliver(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        func enqueue() {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // Time sensitive so a Focus mode doesn't swallow "your card is gone".
            content.interruptionLevel = .timeSensitive
            let request = UNNotificationRequest(identifier: "card.finder.\(UUID().uuidString)",
                                                content: content, trigger: nil)
            center.add(request) { error in
                TicNoteDiagLog.log("FIND", "alert queued err=\(error?.localizedDescription ?? "none")")
            }
        }
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            switch status {
            case .authorized, .provisional, .ephemeral:
                enqueue()
            case .notDetermined:
                // ★ The first drop of a fresh install lands here: the toggle
                // ships ON, so nobody ever flipped it and the permission was
                // never asked — the old code simply gave up, which is exactly
                // "卡片断开提醒手机没任何响铃". Ask now and deliver if granted.
                TicNoteDiagLog.log("FIND", "alert: permission never asked — asking now")
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if granted {
                        enqueue()
                    } else {
                        Task { @MainActor in self.notificationsDenied = true }
                    }
                    TicNoteDiagLog.log("FIND", "alert permission granted=\(granted) err=\(error?.localizedDescription ?? "none")")
                }
            default:
                Task { @MainActor in self.notificationsDenied = true }
                TicNoteDiagLog.log("FIND", "alert suppressed: authorization=\(status.rawValue)")
            }
        }
    }

    /// Ask once, at a moment that makes sense (the toggle, or a first connect).
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Task { @MainActor in
                self.notificationsDenied = !granted
                TicNoteDiagLog.log("FIND", "notify permission granted=\(granted) err=\(error?.localizedDescription ?? "none")")
            }
        }
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in self.notificationsDenied = denied }
        }
    }

    /// Lets the user prove the channel works without waiting to lose a card.
    func sendTestAlert() {
        deliver(title: L10n.Find.title, body: L10n.Find.testAlertBody)
    }
}

// MARK: - CBCentralManagerDelegate

extension PlaudCardFinder: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard self.isScanning else { return }
            self.beginScanIfReady()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
        Task { @MainActor in
            guard let name, self.matches(name) else { return }
            self.lastAdvAt = Date()
            let value = RSSI.intValue
            guard value < 0 else { return }   // 127 = invalid reading
            self.update(rssi: value)
        }
    }

    /// Two-stage match: the exact name we scanned wins, the PLAUD name family
    /// is the fallback. Prefix-of-6 keeps a firmware suffix working
    /// ("PLAUD NotePin-3F2A" vs "PLAUD NotePin").
    private func matches(_ name: String) -> Bool {
        if let target = targetName, !target.isEmpty {
            if name.localizedCaseInsensitiveContains(String(target.prefix(6)))
                || target.localizedCaseInsensitiveContains(String(name.prefix(6))) {
                return true
            }
        }
        return Self.nameHints.contains { name.localizedCaseInsensitiveContains($0) }
    }
}

// MARK: - CLLocationManagerDelegate

extension PlaudCardFinder: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let coordinate = last.coordinate
        let raw = String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
        // Reverse geocode so the row says something a human can act on. The
        // coordinate stays the fallback — offline, CLGeocoder just fails and
        // the row is still honest.
        CLGeocoder().reverseGeocodeLocation(last) { placemarks, _ in
            let place = placemarks?.first
            let label = [place?.name, place?.locality]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            Task { @MainActor in
                self.lastSeenPlace = label.isEmpty ? raw : label
                self.lastSeenCoordinate = coordinate
                UserDefaults.standard.set(self.lastSeenPlace, forKey: Self.lastSeenPlaceKey)
                UserDefaults.standard.set(coordinate.latitude, forKey: Self.lastSeenLatKey)
                UserDefaults.standard.set(coordinate.longitude, forKey: Self.lastSeenLonKey)
                self.patchNewestSeen(place: self.lastSeenPlace, coordinate: coordinate)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refreshLocationStatus() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        log.info("card finder location failed: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PlaudCardFinder: UNUserNotificationCenterDelegate {

    /// Without this the alert is dropped in the foreground — the app is open
    /// exactly when someone watches the card disconnect.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
