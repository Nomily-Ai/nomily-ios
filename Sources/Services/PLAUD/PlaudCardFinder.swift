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
    @Published var notifyOnDisconnect: Bool {
        didSet { UserDefaults.standard.set(notifyOnDisconnect, forKey: Self.notifyKey) }
    }

    /// The advertisement name to look for (e.g. the card's BLE name), as read
    /// from the scan result. Matching is deliberately fuzzy — see `matches(_:)`.
    var targetName: String?

    /// Names PLAUD cards actually advertise under, used when `targetName` is
    /// empty (the card was re-bound from a cold launch and the scan result is
    /// gone). Scanning runs with `withServices: nil` so it sees every nearby
    /// peripheral — AirPods, a keyboard — hence the list stays PLAUD-specific
    /// rather than matching "note" and pinging on a neighbour's laptop.
    private static let nameHints = ["plaud", "notepin", "note pin", "notepro", "note pro", "notecard"]

    private var central: CBCentralManager?
    private let location = CLLocationManager()
    private var scanTimer: Task<Void, Never>?
    private static let notifyKey = "plaud.notify_disconnect"
    private static let lastSeenKey = "plaud.last_seen_at"
    private static let lastSeenPlaceKey = "plaud.last_seen_place"
    private static let lastSeenLatKey = "plaud.last_seen_lat"
    private static let lastSeenLonKey = "plaud.last_seen_lon"

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
        super.init()
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
    }

    /// The link dropped. `unexpected` drives the notification: a user who
    /// pressed "disconnect" does not need to be told the card is gone.
    ///
    /// Note the double-call guard: `disconnect()` reports the drop itself *and*
    /// the SDK's `bleDeviceDisconnectErr` fires right after, so without it the
    /// user gets two notifications for one disconnect.
    func noteDisconnected(unexpected: Bool, cardName: String?) {
        lastSeenAt = Date()
        UserDefaults.standard.set(lastSeenAt, forKey: Self.lastSeenKey)
        capturePlace()
        guard unexpected, notifyOnDisconnect else { return }
        guard Date().timeIntervalSince(lastDropAlertAt) > 5 else { return }
        lastDropAlertAt = Date()
        notify(title: L10n.Find.title,
               body: L10n.Find.dropBody(cardName ?? L10n.Find.thisCard))
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

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: "plaud.card.drop.\(UUID().uuidString)",
                                                content: content, trigger: nil)
            center.add(request)
        }
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
