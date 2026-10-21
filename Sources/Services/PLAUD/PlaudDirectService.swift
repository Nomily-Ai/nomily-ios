import Foundation
import os.log
import PlaudDeviceBasicSDK
import PlaudBleSDK

private let log = Logger(subsystem: "com.nomily.app.ios", category: "plaud.direct")

/// PLAUD **direct connect** (SDK takeover mode) — the primary PLAUD experience.
///
/// Mirrors the other recorder cards (A1 / D·NOTE): Bluetooth scan → connect →
/// pull the ORIGINAL audio files off the card. No PLAUD consumer account is
/// involved (neither phone-number nor email); the only credential is the
/// developer Client ID + Client Secret from dev.plaud.ai, used to mint a
/// short-lived User Access Token that the official SDK wants at init.
///
/// ## Verified auth chain (2026-10-21, curl against platform-us.plaud.ai)
///   1. `POST /developer/api/oauth/partner/access-token`
///      `Authorization: Basic base64(client_id:secret)`, body `{}` → partner token (~1h)
///   2. `POST /developer/api/open/partner/users/access-token`
///      `Authorization: Bearer <partner>`, `{"user_id":"..."}` → user JWT (600 s!)
///
/// ⚠️ The user token lives only 600 s, so it is re-minted on every
/// activate/scan instead of being persisted. The handshake identity the
/// device binds to is derived from the JWT `sub`, which is DETERMINISTIC for
/// a given (client_id, user_id) — re-minting never re-binds the card.
/// The user_id itself is therefore a stable per-install random string.
///
/// ## First takeover
/// The card firmware is single-binding: while the official app owns it, our
/// handshake is rejected (status 255 / drop before handshake). The user must
/// unbind once in the official PLAUD app; recordings stay on the card.
///
/// ## File flow
/// connect → `getFileList` → queue `exportAudio(.mp3)` per session (dedup by
/// sessionId) → move into `StorageLocations.decryptedDir` under a
/// timestamped name → `LibraryItem.readFromDisk` via the `.libraryDidChange`
/// notification, i.e. the same landing path as every other recorder.
/// mp3 (not opus) because AVPlayer cannot play ogg/opus, matching the
/// official template's reasoning.
///
/// Deliberately NOT used here: WiFi fast transfer, iBeacon wake-up, firmware
/// OTA — the SDK supports them but the first cut keeps the surface small.
/// Threading: the SDK calls back on arbitrary queues, so @Published writes
/// are marshalled to the main queue explicitly (template app does the same).
final class PlaudDirectService: NSObject, ObservableObject {
    static let shared = PlaudDirectService()

    enum Phase: Equatable {
        case idle
        case scanning
        case connecting(name: String)
        case connected(sn: String)
        case failed(String)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    struct ScannedCard: Identifiable, Equatable {
        let sn: String
        let name: String
        let rssi: Int
        var id: String { sn }
    }

    /// SDK officially supports NotePro (881) / NotePin S (882).
    static let supportedSNPrefixes = ["881", "882"]
    /// Header example domain; no CN platform host exists yet (probed 2026-10-21).
    static let defaultDomain = "platform-us.plaud.ai"
    /// The minted user token expires in 600 s — treat anything older than
    /// 9 minutes as stale and re-mint before the next SDK operation.
    static let tokenFreshWindow: TimeInterval = 540

    // MARK: Published state (main-queue writes only)

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var scanned: [ScannedCard] = []
    @Published private(set) var isConfigured = false
    @Published private(set) var pairedSN: String?
    @Published private(set) var syncMessage: String?
    @Published private(set) var isSyncing = false
    /// Live device vitals for the device-page card (populated by the SDK
    /// power/storage callbacks; nil until the card reports them).
    @Published private(set) var battery: Int?
    @Published private(set) var storageFree: Int?
    @Published private(set) var storageTotal: Int?
    /// ★ Official-app parity (2026-10-21): recording state + stop/start from
    /// the app. `blePenState` reports 4099 (or 1) while the card is recording.
    @Published private(set) var isRecording = false
    @Published private(set) var isCharging = false
    @Published private(set) var firmware: String?
    /// How many recordings sit ON the card right now (the SDK's `getFileList`
    /// answer). `nil` = never asked / card not connected — the UI shows a dash
    /// instead of a fake "0", because "0 recordings" and "don't know yet" are
    /// different claims. Same rule as the A1 `sizeBytes` trap: never let an
    /// unknown masquerade as a measurement.
    @Published private(set) var cardFileCount: Int?
    /// The card the user tapped in the scan list (before credentials exist —
    /// the official app shows cards + SN first, key comes after).
    @Published private(set) var selectedCard: ScannedCard?
    @Published var deleteAfterSync: Bool {
        didSet { UserDefaults.standard.set(deleteAfterSync, forKey: "plaud.delete_after_sync") }
    }

    // MARK: Credentials (UserDefaults; nomily already stores plaud.email there)

    var clientId: String {
        get { UserDefaults.standard.string(forKey: "plaud.client_id") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "plaud.client_id") }
    }
    var clientSecret: String {
        get { UserDefaults.standard.string(forKey: "plaud.client_secret") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "plaud.client_secret") }
    }
    var domain: String {
        get { UserDefaults.standard.string(forKey: "plaud.domain") ?? Self.defaultDomain }
        set { UserDefaults.standard.set(newValue, forKey: "plaud.domain") }
    }

    /// Stable per-install handshake identity. The card binds to this id (via
    /// the token's `sub`), so it must never change for a given install.
    private var userId: String {
        if let saved = UserDefaults.standard.string(forKey: "plaud.sdk_user_id"), !saved.isEmpty {
            return saved
        }
        let fresh = "nomily-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
        UserDefaults.standard.set(fresh, forKey: "plaud.sdk_user_id")
        return fresh
    }

    // MARK: SDK session state

    private var cachedBleDevices: [String: BleDevice] = [:]
    private var userToken: String?
    private var userTokenAt = Date.distantPast
    private var isInitialized = false
    private var pendingDownloads: [BleFile] = []
    private var currentExportSession: Int?
    /// Session ids already pulled into the library (persisted) — the card
    /// keeps files until deleted, so dedup is what makes re-syncs cheap.
    private var syncedSessions: Set<Int>
    /// Set while a file-list request is a pure "how many recordings?" probe
    /// (device pages), so the answer must NOT kick off a download queue — the
    /// user only asked to look.
    private var fileListProbeOnly = false
    /// SN we are trying to re-bind automatically (`reconnect()`). Cleared as
    /// soon as the card is seen or the attempt is abandoned.
    private var reconnectTarget: String?

    private let session: URLSession
    private let exportQueue = DispatchQueue(label: "com.nomily.app.plaud-export")

    /// Injected by `AppEnvironment` at launch. Needed to register every
    /// pulled clip in the library manifest — that registration is what makes
    /// the library's device filter show a **PLAUD** group (and row badges).
    /// Without it the clips would read as "imported files".
    var library: Library?

    /// Injected by `AppEnvironment` (main actor). On a successful handshake the
    /// card is written into the **same device ledger** the other three recorder
    /// cards use (`config.devices`), which is what makes it show up in
    /// Settings → Devices & Library → Known devices instead of living only in
    /// PLAUD's own sheet.
    var configService: ConfigService?

    /// Ledger key for a card. Prefixed so the device list can tell a PLAUD
    /// entry apart (it renders richer rows, and it survives `plaud-paired-sn`
    /// changes for the same SN).
    static func ledgerID(for sn: String) -> String { "plaud-" + sn }

    /// Product name for the ledger row — the SN prefix tells the model apart
    /// (881 = Note Pro, 882 = NotePin S), same test `cloudUnbind` uses.
    static func modelName(for sn: String) -> String {
        sn.hasPrefix("882") ? "PLAUD NotePin S" : "PLAUD Note Pro"
    }

    private override init() {
        let d = UserDefaults.standard
        isConfigured = !(d.string(forKey: "plaud.client_id") ?? "").isEmpty
            && !(d.string(forKey: "plaud.client_secret") ?? "").isEmpty
        pairedSN = d.string(forKey: "plaud.paired_sn")
        deleteAfterSync = d.bool(forKey: "plaud.delete_after_sync")
        syncedSessions = Set(d.array(forKey: "plaud.synced_sessions") as? [Int] ?? [])
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
        super.init()
        PlaudDeviceAgent.shared.delegate = self
        // ★ `paired_sn` means "we have paired with this card before", NOT
        // "the card is connected right now". Claiming `.connected` at launch
        // would print a live-looking card (battery/history) for a link that
        // does not exist — the same nil-≠-0 rule as everywhere else. The row
        // and the device card read `pairedSN` and offer a reconnect instead.
    }

    // MARK: - Activation

    /// Store credentials and bring the SDK up (mint token → initSDK).
    func activate(clientId cid: String, secret: String, domain dom: String) async throws {
        let trimmedId = cid.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = dom.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty, !trimmedSecret.isEmpty else {
            throw PlaudCloudService.PlaudError.badResponse("Client ID and Secret are both required.")
        }
        clientId = trimmedId
        clientSecret = trimmedSecret
        domain = trimmedDomain.isEmpty ? Self.defaultDomain : trimmedDomain
        isConfigured = true
        try await ensureInitialized()
        log.info("plaud direct connect activated (domain \(self.domain, privacy: .public))")
    }

    func deactivate() {
        PlaudDeviceAgent.shared.disconnect()
        isConfigured = false
        isInitialized = false
        userToken = nil
        if let sn = pairedSN { forgetLedger(sn: sn) }
        pairedSN = nil
        phase = .idle
        scanned = []
        pendingDownloads.removeAll()
        currentExportSession = nil
        cardFileCount = nil
        battery = nil
        storageFree = nil
        storageTotal = nil
        isRecording = false
        firmware = nil
        let d = UserDefaults.standard
        d.removeObject(forKey: "plaud.client_id")
        d.removeObject(forKey: "plaud.client_secret")
        d.removeObject(forKey: "plaud.paired_sn")
        // Keep sdk_user_id: if the user re-activates later, the card should
        // still recognize this install instead of needing another unbind.
    }

    /// Mint a fresh user token if needed and (re)initialize the SDK.
    private func ensureInitialized() async throws {
        guard isConfigured else {
            throw PlaudCloudService.PlaudError.badResponse("Direct connect is not activated yet.")
        }
        if isInitialized, userToken != nil,
           Date().timeIntervalSince(userTokenAt) < Self.tokenFreshWindow {
            return
        }
        let token = try await mintUserToken()
        userToken = token
        userTokenAt = Date()
        PlaudDeviceAgent.shared.initSDK(userAccessToken: token, customDomain: domain, extra: [:])
        isInitialized = true
        log.info("plaud SDK initialized (user_id \(self.userId, privacy: .public))")
    }

    private func mintUserToken() async throws -> String {
        let partner = try await mintPartnerToken()
        guard let url = URL(string: "https://\(domain)/developer/api/open/partner/users/access-token") else {
            throw PlaudCloudService.PlaudError.badResponse("Bad PLAUD platform URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(partner)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["user_id": userId])
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            log.error("plaud user-token mint failed: HTTP \(code) \(String(data: data, encoding: .utf8) ?? "", privacy: .public)")
            throw PlaudCloudService.PlaudError.badResponse("PLAUD rejected the user token request (HTTP \(code)).")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else {
            throw PlaudCloudService.PlaudError.badResponse("PLAUD did not return a user token.")
        }
        return token
    }

    private func mintPartnerToken() async throws -> String {
        guard let url = URL(string: "https://\(domain)/developer/api/oauth/partner/access-token") else {
            throw PlaudCloudService.PlaudError.badResponse("Bad PLAUD platform URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let raw = "\(clientId):\(clientSecret)"
        let encoded = Data(raw.utf8).base64EncodedString()
        req.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            log.error("plaud partner-token mint failed: HTTP \(code) \(String(data: data, encoding: .utf8) ?? "", privacy: .public)")
            if code == 401 {
                throw PlaudCloudService.PlaudError.badResponse("Client ID / Secret rejected by PLAUD (check the `client_` prefix is kept).")
            }
            throw PlaudCloudService.PlaudError.badResponse("PLAUD platform unreachable (HTTP \(code)).")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String, !token.isEmpty else {
            throw PlaudCloudService.PlaudError.badResponse("PLAUD did not return a partner token.")
        }
        return token
    }

    // MARK: - Scan / connect / sync (public, UI-facing)

    /// ★ Scan does NOT require credentials (official-app parity: the user
    /// sees cards + SN first, the key comes after). If credentials exist and
    /// the token is fresh we still bring the SDK up so `connect` right after
    /// a tap needs no extra round trip; failure is non-fatal — scanning is a
    /// pure BLE operation under the hood.
    func startScan() {
        Task {
            if isConfigured {
                try? await ensureInitialized()
            }
            setPhase(.scanning)
            clearScanned()
            reconnectTarget = nil
            PlaudDeviceAgent.shared.startScan()
        }
    }

    /// Reconnect a **previously paired** card without making the user pick it
    /// out of a scan list (the situation after every app relaunch, or after the
    /// card went to sleep). Scans in the background and binds as soon as the
    /// stored SN shows up.
    func reconnect() {
        guard let sn = pairedSN else {
            startScan()
            return
        }
        guard isConfigured else {
            setPhase(.failed(PlaudCloudService.PlaudError
                .badResponse("Direct connect is not activated yet.").localizedDescription))
            return
        }
        Task {
            try? await ensureInitialized()
            setPhase(.connecting(name: Self.modelName(for: sn)))
            clearScanned()
            reconnectTarget = sn
            PlaudDeviceAgent.shared.startScan()
        }
    }

    func stopScan() {
        PlaudDeviceAgent.shared.stopScan()
        reconnectTarget = nil
        // Cancelling a scan says nothing about the link — never promote it to
        // "connected" (that bug made a stale card look live after relaunch).
        if phase == .scanning { setPhase(.idle) }
    }

    /// User tapped a card in the scan list. Connecting needs credentials; the
    /// UI keeps the selection visible and asks for the key when missing.
    func select(_ card: ScannedCard) {
        selectedCard = card
        guard isConfigured else {
            setPhase(.idle)
            return
        }
        connect(card)
    }

    /// Connect the previously selected card (called right after activation).
    func connectSelected() {
        guard let card = selectedCard else {
            setPhase(.failed(L10n.Plaud.cardGone))
            return
        }
        connect(card)
    }

    /// Bind a specific card. Takes the card by value on purpose: the
    /// auto-reconnect path calls this from the SDK's scan callback, where the
    /// published `selectedCard` may not have been written yet (that race made
    /// reconnect always say "card is out of range").
    private func connect(_ card: ScannedCard) {
        guard let ble = cachedBleDevices[card.sn] else {
            setPhase(.failed(L10n.Plaud.cardGone))
            return
        }
        firmware = nil
        setPhase(.connecting(name: card.name))
        PlaudDeviceAgent.shared.stopScan()
        PlaudDeviceAgent.shared.connectBleDevice(bleDevice: ble, deviceToken: userId)
    }

    func disconnect() {
        PlaudDeviceAgent.shared.disconnect()
        pairedSN = nil
        UserDefaults.standard.removeObject(forKey: "plaud.paired_sn")
        cardFileCount = nil
        setPhase(.idle)
    }

    // MARK: - Card controls (official-app parity)

    /// Stop the card's ongoing recording from the app.
    func stopRecording() {
        PlaudDeviceAgent.shared.stopRecord()
        // The card answers via blePenState; optimistically flip so the button
        // doesn't look stuck if the state push is slow.
        DispatchQueue.main.async { self.isRecording = false }
    }

    /// Start a recording from the app (remote record).
    func startRecording() {
        PlaudDeviceAgent.shared.startRecord()
        DispatchQueue.main.async { self.isRecording = true }
    }

    /// Pull battery/charging straight from the card.
    func refreshVitals() {
        PlaudDeviceAgent.shared.getChargingState()
        PlaudDeviceAgent.shared.getState()
    }

    // MARK: - Device ledger (Settings → Devices & Library)

    /// Write this card into `config.devices` so it is listed next to the other
    /// recorder cards. `ConfigService` is main-actor bound and this is called
    /// from the SDK's callback queue, hence the hop.
    private func rememberInLedger(sn: String) {
        Task { @MainActor [weak self] in
            self?.configService?.rememberDevice(
                id: Self.ledgerID(for: sn),
                name: Self.modelName(for: sn),
                isRecorder: true
            )
        }
    }

    private func forgetLedger(sn: String) {
        Task { @MainActor [weak self] in
            self?.configService?.forgetDevice(id: Self.ledgerID(for: sn))
        }
    }

    // MARK: Release (unbind) — return-to-seller / hand-back support

    /// Unbind the card so ANOTHER app (the official PLAUD app, or a buyer's)
    /// can pair it again as if new. This is the guarantee behind the 7-day
    /// no-reason return: takeover is fully reversible.
    ///
    /// Two layers:
    ///   1. BLE `depair(clear:)` — the card firmware forgets this app's
    ///      binding keys. With `clear: true` it also erases every recording,
    ///      i.e. true factory condition. Afterwards the card re-advertises
    ///      (its MAC changes) and any app can pair it from scratch.
    ///   2. Cloud `POST /developer/api/open/partner/sdk/unbind` — clears the
    ///      partner-cloud binding record so no stale bind_history lingers.
    ///      Best-effort: the card-side depair is what actually frees the
    ///      hardware; the cloud record only matters for SDK recovery flows.
    func releaseDevice(factoryReset: Bool) {
        guard case .connected(let sn) = phase else { return }
        log.info("plaud release (factoryReset=\(factoryReset)) sn=\(sn, privacy: .public)")
        PlaudDeviceAgent.shared.depair(clear: factoryReset)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureInitialized()
                try await self.cloudUnbind(sn: sn)
            } catch {
                log.warning("plaud cloud unbind skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
        pendingDownloads.removeAll()
        currentExportSession = nil
        // The card is handed back, so it must also leave the user-visible
        // device list — a released card is not "my device" any more (same
        // concluding step `RecorderDeviceView.unbindAndRemove` does).
        forgetLedger(sn: sn)
        pairedSN = nil
        UserDefaults.standard.removeObject(forKey: "plaud.paired_sn")
        battery = nil
        storageFree = nil
        storageTotal = nil
        cardFileCount = nil
        isRecording = false
        setPhase(.idle)
    }

    private func cloudUnbind(sn: String) async throws {
        guard let url = URL(string: "https://\(domain)/developer/api/open/partner/sdk/unbind") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(userToken ?? "")", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let type = sn.hasPrefix("882") ? "notepins" : "notepro"
        req.httpBody = try JSONSerialization.data(withJSONObject: ["type": type, "sn": sn])
        let (_, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        log.info("plaud cloud unbind HTTP \(code)")
        guard (200..<300).contains(code) else {
            throw PlaudCloudService.PlaudError.badResponse("Cloud unbind HTTP \(code).")
        }
    }

    /// Pull the file list off the card and download everything new.
    func syncFromCard() {
        guard phase.isConnected else { return }
        fileListProbeOnly = false
        setSyncMessage(nil)
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    /// Ask the card "how many recordings do you hold?" **without** queueing any
    /// download. Used by the device pages (ledger row / device card) so the
    /// history count can be shown before the user decides to pull.
    func refreshCardRecordings() {
        guard phase.isConnected else { return }
        fileListProbeOnly = true
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    // MARK: - Download queue

    private func handleFileList(_ files: [BleFile]) {
        let probeOnly = fileListProbeOnly
        fileListProbeOnly = false
        // The count is meaningful on BOTH paths — it is the card's history size.
        let count = files.count
        DispatchQueue.main.async { self.cardFileCount = count }
        let fresh = files.filter { !syncedSessions.contains($0.sessionId) }
        log.info("plaud file list: \(count) on card, \(fresh.count) new (probe=\(probeOnly))")
        if probeOnly { return }
        guard !fresh.isEmpty else {
            setSyncing(false)
            setSyncMessage(nil)
            return
        }
        setSyncing(true)
        setSyncMessage(L10n.Plaud.syncStarting(fresh.count))
        pendingDownloads = fresh
        downloadNext()
    }

    private func downloadNext() {
        guard let next = pendingDownloads.first else {
            currentExportSession = nil
            setSyncing(false)
            setSyncMessage(L10n.Plaud.syncDone)
            return
        }
        pendingDownloads.removeFirst()
        currentExportSession = next.sessionId
        setSyncMessage(L10n.Plaud.syncDownloading(pendingDownloads.count + 1))
        let handler = ExportHandler(service: self, sessionId: next.sessionId)
        PlaudDeviceAgent.shared.exportAudio(
            sessionId: next.sessionId,
            outputDir: NSTemporaryDirectory(),
            format: .mp3,
            channels: 1,
            callback: handler
        )
    }

    /// SDK finished writing the transcoded file — move it into the library
    /// directory under a friendly timestamped name and register it.
    func handleExportComplete(sessionId: Int, outputPath: String) {
        currentExportSession = nil
        markSynced(sessionId)
        let src = URL(fileURLWithPath: outputPath)
        let stamp: String = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH.mm.ss"
            return fmt.string(from: Date())
        }()
        let dir = StorageLocations.decryptedDir
        var name = "PLAUD \(stamp).mp3"
        var n = 2
        while dir.appendingPathComponent(name).pathExists {
            name = "PLAUD \(stamp) (\(n)).mp3"
            n += 1
        }
        let dest = dir.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: src, to: dest)
            log.info("plaud export landed: \(name, privacy: .public)")
            // Register in the library manifest so the clip groups under a
            // **PLAUD** device (filter chip + row badge), like every card.
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
            let sn = pairedSN ?? ""
            DispatchQueue.main.async {
                self.library?.recordDownload(
                    name: name,
                    size: size,
                    transport: "ble",
                    deviceSerial: "plaud-\(sn)",
                    deviceName: "PLAUD",
                    localName: name
                )
            }
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        } catch {
            log.error("plaud export move failed: \(error.localizedDescription, privacy: .public)")
            setSyncMessage(error.localizedDescription)
        }
        if deleteAfterSync {
            PlaudDeviceAgent.shared.deleteFile(sessionId: sessionId)
        }
        downloadNext()
    }

    func handleExportError(sessionId: Int, message: String) {
        currentExportSession = nil
        log.error("plaud export error for \(sessionId): \(message, privacy: .public)")
        setSyncMessage(L10n.Plaud.syncFailed(message))
        pendingDownloads.removeAll()
        setSyncing(false)
    }

    private func markSynced(_ sessionId: Int) {
        syncedSessions.insert(sessionId)
        UserDefaults.standard.set(Array(syncedSessions), forKey: "plaud.synced_sessions")
    }

    // MARK: - State marshalling

    private func setPhase(_ p: Phase) {
        DispatchQueue.main.async { self.phase = p }
    }
    private func clearScanned() {
        DispatchQueue.main.async { self.scanned = [] }
    }
    private func setSyncing(_ v: Bool) {
        DispatchQueue.main.async { self.isSyncing = v }
    }
    private func setSyncMessage(_ m: String?) {
        DispatchQueue.main.async { self.syncMessage = m }
    }
    private func setScanned(_ cards: [ScannedCard]) {
        DispatchQueue.main.async { self.scanned = cards }
    }
}

// MARK: - Export callback adapter

/// One handler per in-flight export. The SDK holds the callback strongly for
/// the duration of the call, so a fresh instance per file is safe (template
/// app does the same with ExportCallbackHandler / WiFiExportHandler).
private final class ExportHandler: NSObject, AudioExportCallback {
    private weak var service: PlaudDirectService?
    private let sessionId: Int

    init(service: PlaudDirectService, sessionId: Int) {
        self.service = service
        self.sessionId = sessionId
        super.init()
    }

    func onProgress(_ progress: Int, message: String) {
        log.info("plaud export \(self.sessionId): \(progress)% \(message, privacy: .public)")
    }

    func onComplete(outputPath: String) {
        service?.handleExportComplete(sessionId: sessionId, outputPath: outputPath)
    }

    func onError(_ error: String) {
        service?.handleExportError(sessionId: sessionId, message: error)
    }
}

// MARK: - PlaudDeviceAgentProtocol

extension PlaudDirectService: PlaudDeviceAgentProtocol {

    /// Scan hit. Cache BleDevice objects (needed for connect) and publish a
    /// clean pick-list sorted by signal strength.
    func bleScanResult(bleDevices: [BleDevice]) {
        let supported = bleDevices.filter { dev in
            Self.supportedSNPrefixes.contains { dev.serialNumber.hasPrefix($0) }
        }
        cachedBleDevices = Dictionary(uniqueKeysWithValues: supported.map { ($0.serialNumber, $0) })
        let cards = supported
            .map { ScannedCard(sn: $0.serialNumber, name: Self.displayName($0), rssi: Int($0.rssi)) }
            .sorted { $0.rssi > $1.rssi }
        setScanned(cards)
        // Auto-bind the card we were told to reconnect as soon as its
        // advertisement arrives (`reconnect()` path).
        if let target = reconnectTarget, let card = cards.first(where: { $0.sn == target }) {
            reconnectTarget = nil
            DispatchQueue.main.async { self.selectedCard = card }
            connect(card)
        }
    }

    private static func displayName(_ dev: BleDevice) -> String {
        let cleaned = dev.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "PLAUD \(dev.serialNumber.suffix(4))" : cleaned
    }

    func bleScanOverTime() {
        // Scan timed out. Still not connected — say so instead of re-asserting
        // the last known SN as a live link.
        if phase == .scanning || reconnectTarget != nil {
            reconnectTarget = nil
            if case .connecting = phase {
                setPhase(.failed(L10n.Plaud.cardGone))
            } else {
                setPhase(.idle)
            }
        }
    }

    /// 0 = disconnected, 1 = GATT up (handshake still pending), 2/-1/-2 = failed.
    func bleConnectState(state: Int) {
        log.info("plaud connect state \(state)")
        switch state {
        case 1:
            break // wait for bleBind — GATT alone is not success
        case 0:
            if case .connecting = phase {
                setPhase(.failed(L10n.Plaud.pairRejected))
            } else {
                setPhase(.idle)
            }
        default:
            setPhase(.failed(L10n.Plaud.pairRejected))
        }
    }

    /// Handshake verdict — status 0 is the real "connected".
    func bleBind(sn: String?, status: Int, protVersion: Int, timezone: Int) {
        guard status == 0, let sn else {
            log.warning("plaud bind rejected: status \(status)")
            setPhase(.failed(L10n.Plaud.pairRejected))
            return
        }
        log.info("plaud bound: \(sn, privacy: .public)")
        pairedSN = sn
        UserDefaults.standard.set(sn, forKey: "plaud.paired_sn")
        // A bound card is one of "my devices" now — same ledger the other
        // recorder cards live in, so it appears in Settings → Devices.
        rememberInLedger(sn: sn)
        // Firmware is read off the advertisement at scan time.
        if let card = selectedCard, card.sn == sn {
            firmware = cachedBleDevices[sn].map { $0.wholeVersion() }
        }
        DispatchQueue.main.async { self.selectedCard = nil }
        setPhase(.connected(sn: sn))
        // Pull vitals right away, then auto-pull the file list like the
        // official template does.
        refreshVitals()
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    /// @required — recorder state push. `state == 4099` (or 1) = recording.
    func blePenState(state: Int, privacy: Int, keyState: Int, uDisk: Int, findMyToken: Int, hasSndpKey: Int, deviceAccessToken: Int) {
        log.info("plaud pen state \(state) privacy \(privacy) key \(keyState)")
        let nowRecording = (state == 4099 || state == 1)
        let wasRecording = isRecording
        DispatchQueue.main.async { self.isRecording = nowRecording }
        // A recording that just ended adds a file to the card — re-read the
        // count so "recordings on card" doesn't lag one clip behind reality.
        if wasRecording && !nowRecording {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard self.phase.isConnected else { return }
                self.refreshCardRecordings()
            }
        }
    }

    func bleDeviceDisconnectErr() {
        log.warning("plaud device dropped")
        DispatchQueue.main.async { self.cardFileCount = nil }
        if case .connected = phase { setPhase(.idle) }
    }

    func bleStorage(total: Int, free: Int, duration: Int) {
        log.info("plaud storage total=\(total) free=\(free)")
        DispatchQueue.main.async {
            self.storageTotal = total
            self.storageFree = free
        }
    }

    func blePowerChange(power: Int, oldPower: Int) {
        DispatchQueue.main.async { self.battery = power }
    }

    func bleChargingState(isCharging charging: Bool, level: Int) {
        DispatchQueue.main.async {
            self.isCharging = charging
            if level > 0 { self.battery = level }
        }
    }

    func bleFileList(bleFiles: [BleFile]) {
        handleFileList(bleFiles)
    }

    func bleSyncFileHead(sessionId: Int, status: Int) {
        if status != 0 {
            log.warning("plaud sync head status \(status) for \(sessionId)")
        }
    }

    func bleSyncFileTail(sessionId: Int, crc: Int) {
        log.info("plaud sync tail \(sessionId)")
    }

    func bleDownloadFileStop() {}

    func bleData(sessionId: Int, start: Int, data: Data) {}
}

private extension URL {
    var pathExists: Bool { FileManager.default.fileExists(atPath: path) }
}
