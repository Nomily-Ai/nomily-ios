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

    private let session: URLSession
    private let exportQueue = DispatchQueue(label: "com.nomily.app.plaud-export")

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
        if let sn = pairedSN { phase = .connected(sn: sn) }
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
        pairedSN = nil
        phase = .idle
        scanned = []
        pendingDownloads.removeAll()
        currentExportSession = nil
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

    func startScan() {
        Task {
            do {
                try await ensureInitialized()
                setPhase(.scanning)
                clearScanned()
                PlaudDeviceAgent.shared.startScan()
            } catch {
                setPhase(.failed(error.localizedDescription))
            }
        }
    }

    func stopScan() {
        PlaudDeviceAgent.shared.stopScan()
        if phase == .scanning { setPhase(pairedSN.map { Phase.connected(sn: $0) } ?? .idle) }
    }

    func connect(_ card: ScannedCard) {
        guard let ble = cachedBleDevices[card.sn] else { return }
        setPhase(.connecting(name: card.name))
        PlaudDeviceAgent.shared.stopScan()
        PlaudDeviceAgent.shared.connectBleDevice(bleDevice: ble, deviceToken: userId)
    }

    func disconnect() {
        PlaudDeviceAgent.shared.disconnect()
        pairedSN = nil
        UserDefaults.standard.removeObject(forKey: "plaud.paired_sn")
        setPhase(.idle)
    }

    /// Pull the file list off the card and download everything new.
    func syncFromCard() {
        guard phase.isConnected else { return }
        setSyncMessage(nil)
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    // MARK: - Download queue

    private func handleFileList(_ files: [BleFile]) {
        let fresh = files.filter { !syncedSessions.contains($0.sessionId) }
        log.info("plaud file list: \(files.count) on card, \(fresh.count) new")
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
    }

    private static func displayName(_ dev: BleDevice) -> String {
        let cleaned = dev.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "PLAUD \(dev.serialNumber.suffix(4))" : cleaned
    }

    func bleScanOverTime() {
        if phase == .scanning { setPhase(pairedSN.map { Phase.connected(sn: $0) } ?? .idle) }
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
        setPhase(.connected(sn: sn))
        // Auto-pull right after binding, like the official template.
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    /// @required — recorder state push. Populates battery/storage on the
    /// connected card; recording state (4099) is deliberately ignored: the
    /// card records stand-alone and files are pulled afterwards.
    func blePenState(state: Int, privacy: Int, keyState: Int, uDisk: Int, findMyToken: Int, hasSndpKey: Int, deviceAccessToken: Int) {
        log.info("plaud pen state \(state) privacy \(privacy) key \(keyState)")
    }

    func bleDeviceDisconnectErr() {
        log.warning("plaud device dropped")
        if case .connected = phase { setPhase(.idle) }
    }

    func bleStorage(total: Int, free: Int, duration: Int) {
        log.info("plaud storage total=\(total) free=\(free)")
    }

    func blePowerChange(power: Int, oldPower: Int) {}

    func bleChargingState(isCharging: Bool, level: Int) {}

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
