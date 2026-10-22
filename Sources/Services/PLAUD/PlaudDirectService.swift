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

        /// Scanning or binding — the UI shows a spinner and must not start a
        /// second attempt (two scans race and clear each other's state).
        var isBusy: Bool {
            switch self {
            case .scanning, .connecting: return true
            default: return false
            }
        }
    }

    struct ScannedCard: Identifiable, Equatable {
        let sn: String
        let name: String
        let rssi: Int
        var id: String { sn }
    }

    /// One recording sitting on the card. Deliberately a value copy of the SDK's
    /// `BleFile`: the SDK object is mutable and lives on its own queue, so the UI
    /// must not read it directly.
    struct PlaudCardFile: Identifiable, Equatable {
        let sessionID: Int
        let size: Int
        /// Card-reported duration in seconds (nil when the SDK can't derive it).
        let duration: TimeInterval?
        /// Card-reported recording start (unix seconds), when the file carries one.
        let recordedAt: Date?
        /// Bookmarks ("打点") the user pressed while recording — `BleFile.penCollect`.
        let marks: Int
        var id: Int { sessionID }
        /// `sessionId` is documented as "timezone timestamp" — usable as a
        /// fallback time when `recordedAt` is missing.
        var approxDate: Date? { recordedAt ?? (sessionID > 1_600_000_000 ? Date(timeIntervalSince1970: TimeInterval(sessionID)) : nil) }
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
    /// Transfer feedback (2026-10-21, 3rd round — "downloading needs work").
    /// `downloadProgress` is the **current file** 0…1, `downloadSpeed` the SDK's
    /// own live figure ("12.4 KB/s"), and the counters let the header say
    /// "2 / 5" instead of the bare "Transferring file 2…" that looked stuck.
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadSpeed: String = ""
    @Published private(set) var downloadDone: Int = 0
    @Published private(set) var downloadTotal: Int = 0
    /// User-visible card name — the custom alias when one is set, otherwise the
    /// model name. Written by `rename(to:)` and mirrored into the device ledger
    /// so Settings, the pill and the home row all agree.
    @Published private(set) var displayName: String = "PLAUD"
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
    /// ★ Recording clock (2026-10-21). `startedAt` is our anchor when the card
    /// confirms a start; `deviceElapsed` is the card's OWN millisecond counter
    /// from `blePcmData`. The UI shows `deviceElapsed ?? now-startedAt`, so the
    /// clock follows the card when it reports and never freezes in between.
    @Published private(set) var recordStartedAt: Date?
    @Published private(set) var deviceElapsed: TimeInterval?
    @Published private(set) var recordSessionID: Int?
    /// Live file on the card for this session (bytes written so far) — the SDK's
    /// "real-time duration through the sync-file offset".
    @Published private(set) var recordBytes: Int = 0
    /// Why a start/stop was refused (space full / U-disk mode / busy / wrong mode).
    @Published private(set) var recordNotice: String?
    /// Recordings currently on the card, newest first, for the home device
    /// segment. Empty + `cardFilesLoaded == false` = "not read yet" (never a
    /// claim that the card is empty).
    @Published private(set) var cardFiles: [PlaudCardFile] = []
    @Published private(set) var cardFilesLoaded = false
    /// Live PCM stream state (the sync-file channel opened while recording).
    @Published private(set) var liveStreaming = false
    @Published private(set) var livePCMBytes = 0
    /// 0…1 loudness of the newest PCM block (drives the level meter while recording).
    @Published private(set) var liveLevel: Double = 0
    /// Live transcript text (finals + in-flight hypothesis) for the current
    /// recording. Empty when speech recognition is unavailable/undesired.
    @Published private(set) var liveTranscript = ""
    /// The same transcript as timestamped lines — what the panel renders.
    @Published private(set) var liveSegments: [PlaudLiveSegment] = []
    /// The in-flight hypothesis (not yet a committed line).
    @Published private(set) var livePartial = ""
    /// Why live transcription is silent (`nil` = working / not started). Shown
    /// instead of an empty box, because "no text" and "no permission" look
    /// identical on screen and only one of them is the user's to fix.
    @Published private(set) var liveASRNotice: String?
    /// Which engine is producing the live text ("azure" / "ondevice") — shown in
    /// the panel header so "is it using my Azure key?" has a visible answer.
    @Published private(set) var liveASRProvider = ""
    /// Positions of the marks of the current/last take, on the card's clock.
    ///
    /// `getMarking` never answers on this firmware, so a mark is *detected* by
    /// the `penCollect` poll (every ~6 s) and stamped with the clock at that
    /// moment — accurate to the poll interval, which is why the transcript marks
    /// it as a marker line rather than pretending to know the exact second.
    @Published private(set) var liveMarkers: [TimeInterval] = []
    /// Which take the live transcript belongs to. Used to (a) not wipe the text
    /// when we re-attach to the same take, and (b) know which pulled clip the
    /// transcript must be written next to.
    @Published private(set) var liveTranscriptSessionID: Int?
    /// Clip name the live transcript was already written next to (`nil` = not
    /// saved into the library yet). The Live screen shows this as proof.
    @Published private(set) var liveTranscriptSavedTo: String?
    /// Bookmarks pressed on the card during THIS recording ("打点"). The card
    /// pushes them via `bleMarking`; there is no "how many" query mid-recording,
    /// so this is "what we heard" — same contract as the A1's remark count.
    @Published private(set) var recordMarks: [UInt32] = []
    // `markTimestamps` (seconds) lives below, next to the mark accounting — it
    // has to consider `liveMarkers` too.
    /// Mark count as the UI shows it. `max` of everything the card has told us,
    /// because two independent channels can report it (see the marks poll):
    ///   · `bleMarking(markList:)` — the answer to `getMarking(sessionId:)`,
    ///     carries the timestamps;
    ///   · `bleFileList` for the live session — `BleFile.penCollect`, the file's
    ///     own counter. On firmware where `getMarking` answers nothing, this one
    ///     still moves, and a single press must not be counted twice.
    @Published private(set) var recordMarkCount = 0
    /// Sessions already pulled into the library. Mirrors the private
    /// `syncedSessions` set — that one lives behind `UserDefaults` and would not
    /// republish, so the card list could not show "already saved" after a pull.
    @Published private(set) var pulledSessions: Set<Int> = []
    @Published private(set) var isPaused = false
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
    /// ★ 2026-10-21: "record now" tapped while the link is still down. The home
    /// page keeps ONE record button (device info no longer has any), so a tap on
    /// a sleeping card must wake it and start on its own — being told "not
    /// connected, go open device info first" is the exact round-trip the user
    /// asked us to remove.
    private var pendingStartAfterConnect = false

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
    /// Session ids waiting for their turn to be erased (multi-select delete).
    /// One `deleteFile` command in flight at a time — see `pumpDeletes`.
    private var pendingDeletes: [Int] = []
    private var deletePumpScheduled = false
    private var deletePumpGeneration = 0
    /// Last time the export pipeline showed any sign of life (progress /
    /// completion / error / next file). The watchdog compares against this.
    private var lastSyncActivity = Date.distantPast
    private var syncWatchdog: Task<Void, Never>?
    /// Sessions the watchdog gave up on — kept so "retry" doesn't spin on the
    /// same broken file within one sitting.
    private var stalledSessions: Set<Int> = []
    /// How many files this pass had to skip (surfaced in the finish message).
    @Published private(set) var downloadSkipped = 0
    /// True while the next `bleFileList` answer is the single-entry marks probe
    /// (`getFile(sessionId:)`), not a card listing. See `bleFileList`.
    private var fileProbeForMarks = false
    /// Session we are in the middle of re-attaching to (app relaunched / link
    /// restored while the card kept recording). The file probe answers with the
    /// byte offset the live channel must resume from — see
    /// `attachToRunningRecording`.
    private var pendingAttachSessionID: Int?
    /// Session the current `recordMarks` belong to, so a new take starts at zero.
    private var marksSessionID: Int?
    /// ★ 2026-10-21 (7th round): how many `getMarking` requests went out without
    /// a single `bleMarking` answer. Hardware evidence (2 MB of SDK command log
    /// from a Note Pro on V1.7): 52 requests, **zero** `recv-cmd:cmd 35` replies
    /// — this firmware ignores `getMarking` entirely, live. So the probe gives up
    /// after two silent attempts instead of injecting a dead command every few
    /// seconds into the same channel that carries the audio.
    private var markingProbeStrikes = 0
    /// Set once the card ever answers `getMarking`. When false the UI says the
    /// count arrives after the recording instead of showing a permanent "—".
    @Published private(set) var marksAvailableLive = true
    // ★ Recording mode (2026-10-22, user: "把官方 App 的几个模式搬过来"): the
    // official app's 电池电量 page — 高性能 / 自适应 / 长续航 — is the card's
    // `BatteryMode` common setting, read/written on the LOW-level BleAgent
    // (`readBatteryMode` / `setBatteryMode(value:)`); the high-level agent
    // exposes nothing for it. Value semantics (inferred, cross-check pending):
    // 0 = high performance, 1 = adaptive, 2 = long endurance — the official
    // page ships with high performance selected and lists them in that order.
    @Published private(set) var batteryMode: Int?
    @Published private(set) var batteryModeUnsupported = false
    /// ★ Read-back is unavailable: the high-level agent handles the BatteryMode
    /// response internally and `PlaudDeviceAgentProtocol` has no `bleBatteryMode`
    /// (verified on hardware 2026-10-22 — a read produced no callback). So the
    /// last value WE set (or the agent echoed, if forwarding ever appears) is
    /// persisted locally, otherwise the picker forgets the mode on relaunch.
    private static let batteryModeKey = "plaud.battery_mode"
    private var currentExportSession: Int?
    /// Session ids already pulled into the library (persisted) — the card
    /// keeps files until deleted, so dedup is what makes re-syncs cheap.
    private var syncedSessions: Set<Int>
    /// Set while a file-list request is a pure "how many recordings?" probe
    /// (device pages), so the answer must NOT kick off a download queue — the
    /// user only asked to look.
    private var fileListProbeOnly = false
    /// Rate limit for `handleExportProgress` — the SDK reports per packet.
    private var lastProgressPublish = Date.distantPast
    /// Throttle for the live level meter (see `blePcmData`) — a published change
    /// per PCM block rebuilt the whole device list dozens of times a second.
    private var lastLevelPublish = Date.distantPast
    /// PCM blocks seen this session (diag only, see `blePcmData`).
    private var pcmBlockCount = 0
    /// SN we are trying to re-bind automatically (`reconnect()`). Cleared as
    /// soon as the card is seen or the attempt is abandoned.
    private var reconnectTarget: String?
    // MARK: Device Recovery (docs.plaud.ai "Recovering a Plaud device")
    /// ★ 2026-10-21 (9th round): a card whose cloud and local bind state went
    /// out-of-sync locks EVERY app out — our normal handshake no longer matches
    /// the on-device lock ("Nomily 无法匹配") and the official app has no key
    /// at all ("官方 App 加不上"). The documented escape is a recovery connect:
    /// re-handshake with each **previously bound client ID** using force-clear
    /// until one matches the lock; the stale lock is wiped and the card can be
    /// bound again — by us (then depair(clear:true) hands it to another app)
    /// or directly by the official app.
    private var recoveryMode = false
    private var recoveryIndex = 0
    private var recoveryDevice: BleDevice?
    /// Identities the on-device lock could have been minted against. The
    /// registry's `bind_history` is empty once unbound, so we reconstruct the
    /// candidates locally: the partner client id, its bare-UUID form, and the
    /// user-token subject (`client_user_…`) — the lock's key pair is generated
    /// from the user token, so its subject is the most likely match.
    private var recoveryClientIDs: [String] {
        var ids: [String] = []
        if let tok = userToken, let sub = Self.jwtSubject(tok), !sub.isEmpty {
            ids.append(sub)
        }
        let cid = clientId
        if !cid.isEmpty {
            ids.append(cid)
            if cid.hasPrefix("client_") { ids.append(String(cid.dropFirst("client_".count))) }
        }
        return ids
    }

    /// `sub` claim of a JWT payload (base64url, unpadded).
    private static func jwtSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["sub"] as? String
    }
    /// Periodic `getState()` while connected (see `startStatePolling`).
    private var statePollTask: Task<Void, Never>?

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
    /// Receives every decoded PCM block while a recording is live (16-bit LE,
    /// whatever the card sends) **plus the card's own clock for that block**.
    /// A live-transcription sink attaches here; when nothing is attached the
    /// blocks are simply metered and dropped.
    var liveAudioSink: ((Data, TimeInterval) -> Void)?

    /// On-device live transcription for the current recording (see
    /// `PlaudLiveTranscriber`). Lives only while a recording is live.
    /// The live engine for the current take — Azure (PCM over WebSocket) or the
    /// on-device recogniser, whichever the ASR chain names (see
    /// `makeLiveASREngine`).
    private var liveTranscriber: (any PlaudLiveASR)?

    /// Begin transcribing the live PCM stream (no-op when speech is not
    /// authorized — recording itself never depends on ASR).
    ///
    /// ★ 2026-10-22 ("the live text lags / is unreadable"): the transcriber now
    ///   owns timestamps and a segment model, and this method mirrors those into
    ///   published state instead of a single joined string. The card's clock is
    ///   passed through with every block, so each line knows when it was said.
    @MainActor private func startLiveTranscription(sessionID: Int? = nil) {
        let sid = sessionID ?? recordSessionID
        // ★ 2026-10-22 ("the text disappears"): re-attaching to the **same** take
        // must not wipe what was already transcribed. `attachToRunningRecording`
        // and the state poll can call this again mid-take (a dropped link, a
        // re-read after the card slept), and resetting there threw the text away
        // exactly when the user was looking at it.
        let continuingSameTake = (sid != nil && sid == liveTranscriptSessionID)
            && (!liveSegments.isEmpty || !livePartial.isEmpty)
        liveTranscriber?.stop()
        liveTranscriber = nil
        if !continuingSameTake {
            liveSegments = []
            livePartial = ""
            liveTranscript = ""
            liveMarkers = []
            liveTranscriptSavedTo = nil
        }
        liveTranscriptSessionID = sid
        liveASRNotice = nil

        // ★ 2026-10-22 ("实时转录没文字 … 使用的是 Azure"): the engine now follows
        //   the same provider chain as the rest of the app instead of being
        //   hard-wired to Apple's offline model. Azure takes the card's PCM
        //   directly (`PlaudAzureLiveTranscriber`); the on-device recogniser is
        //   the last resort, exactly like `LiveModel` treats it.
        guard let engine = makeLiveASREngine() else {
            liveASRNotice = L10n.Plaud.liveNeedsPermission
            liveASRProvider = ""
            TicNoteDiagLog.log("PLAUD-ASR", "no engine: chain=\(String(describing: configService?.config.defaults.asr)) azure=\(String(describing: configService?.config.asrProviders.azure != nil)) onDeviceEnabled=\(String(describing: configService?.config.onDeviceASREnabled))")
            log.info("plaud live transcript unavailable (no engine)")
            return
        }
        attachLiveEngine(engine)
    }

    /// Pick the best available engine for the card's PCM.
    ///
    /// Order: the user's `defaults.asr` chain (primary, then fallbacks), then
    /// on-device. Providers that need Opus (`local`, `remote`) are skipped — they
    /// cannot take PCM from this card, and silently sending PCM to an Opus
    /// endpoint would produce noise instead of an error.
    @MainActor private func makeLiveASREngine() -> (any PlaudLiveASR)? {
        let cfg = configService?.config
        let localeID = Self.bcp47Language(cfg?.lastSourceLang)
        var chain: [String] = []
        if let defaults = cfg?.defaults.asr {
            chain = [defaults.primary] + defaults.fallbacks
        }
        chain.append("ondevice")
        for name in chain.map({ $0.lowercased() }) where !name.isEmpty {
            switch name {
            case "azure":
                if let azure = cfg?.asrProviders.azure,
                   !azure.key.isEmpty, !azure.region.isEmpty {
                    log.info("plaud live asr engine=azure lang=\(localeID, privacy: .public)")
                    return PlaudAzureLiveTranscriber(key: azure.key, region: azure.region, lang: localeID)
                }
            case "ondevice":
                guard cfg?.onDeviceASREnabled != false else { continue }
                if let engine = PlaudLiveTranscriber.makeIfPermitted(localeID: cfg?.lastSourceLang) {
                    log.info("plaud live asr engine=ondevice")
                    return engine
                }
            default:
                // local / remote / custom: Opus-only, cannot consume raw PCM.
                continue
            }
        }
        return nil
    }

    /// Wire an engine's output into the published state and start feeding it.
    @MainActor private func attachLiveEngine(_ engine: any PlaudLiveASR) {
        liveTranscriber?.stop()
        engine.onTextChange = { [weak self, weak engine] in
            guard let self, let engine else { return }
            self.liveSegments = engine.segments
            self.livePartial = engine.partial
            self.liveTranscript = Self.joinedTranscript(engine.segments, partial: engine.partial)
        }
        engine.onFailure = { [weak self] reason in
            Task { @MainActor in self?.fallbackLiveEngine(reason: reason) }
        }
        engine.start()
        switch engine.unavailable {
        case .modelMissing: liveASRNotice = L10n.Plaud.liveModelMissing
        case .noRecognizer, .notAuthorized: liveASRNotice = L10n.Plaud.liveNeedsPermission
        case .azureMissing: liveASRNotice = L10n.Plaud.liveNeedsPermission
        case .azureFailed(let message): liveASRNotice = L10n.Plaud.liveAzureFailed(message)
        case .none: liveASRNotice = nil
        }
        liveASRProvider = engine.providerName
        liveTranscriber = engine
        TicNoteDiagLog.log("PLAUD-ASR", "engine=\(engine.providerName) sid=\(liveTranscriptSessionID.map(String.init) ?? "-") notice=\(liveASRNotice ?? "none")")
        // Called straight from the SDK's BLE queue; each engine does its own
        // threading from here (the on-device one has its own PCM queue, Azure
        // batches into ~100 ms WebSocket frames).
        liveAudioSink = { [weak engine] pcm, elapsed in
            engine?.append(pcm, elapsed: elapsed)
        }
    }

    /// Azure died mid-take (quota / expired key / network): keep the text that is
    /// already on screen and continue with the on-device recogniser rather than
    /// leaving the user with a frozen transcript.
    @MainActor private func fallbackLiveEngine(reason: PlaudLiveASRUnavailable) {
        guard liveTranscriber?.providerName == "azure" else { return }
        log.warning("plaud live asr: azure failed (\(String(describing: reason), privacy: .public)) — falling back to on-device")
        guard let onDevice = PlaudLiveTranscriber.makeIfPermitted(localeID: configService?.config.lastSourceLang) else {
            liveASRNotice = L10n.Plaud.liveNeedsPermission
            return
        }
        onDevice.seed(segments: liveSegments)
        attachLiveEngine(onDevice)
        liveASRNotice = L10n.Plaud.liveAzureFellBack
        TicNoteDiagLog.log("PLAUD-ASR", "fallback to ondevice, seeded \(liveSegments.count) lines")
    }

    /// Segments + in-flight hypothesis, joined the way the panel renders them.
    static func joinedTranscript(_ segments: [PlaudLiveSegment], partial: String) -> String {
        var parts = segments.map(\.text)
        let tail = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts.joined(separator: "\n")
    }

    /// "zh" → "zh-CN", "en" → "en-US", full ids pass through. Azure needs a
    /// concrete BCP-47 tag; the app's config stores bare language codes.
    static func bcp47Language(_ raw: String?) -> String {
        let id = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            return Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        }
        if id.contains("-") { return id }
        if id.contains("_") { return id.replacingOccurrences(of: "_", with: "-") }
        switch id.lowercased() {
        case "zh": return "zh-CN"
        case "en": return "en-US"
        case "ja": return "ja-JP"
        case "ko": return "ko-KR"
        case "de": return "de-DE"
        case "fr": return "fr-FR"
        case "es": return "es-ES"
        case "pt": return "pt-BR"
        case "ru": return "ru-RU"
        case "ar": return "ar-SA"
        case "it": return "it-IT"
        default: return id
        }
    }

    /// Stop feeding audio. ⚠️ Deliberately **keeps** the transcript: the text of
    /// the take you just finished is the whole point of a live transcript, and
    /// it used to be wiped the moment the card stopped.
    @MainActor private func stopLiveTranscription() {
        liveTranscriber?.stop()
        liveTranscriber = nil
        liveAudioSink = nil
    }

    // MARK: - Marks on the transcript

    /// Bookmark positions as seconds — the card's own offsets when it reports
    /// them, otherwise the clock at the moment the count moved.
    var markTimestamps: [TimeInterval] {
        if !liveMarkers.isEmpty { return liveMarkers.sorted() }
        return recordMarks.map { Self.secondsFromMark($0) }.sorted()
    }

    /// `getMarking` reports offsets in milliseconds on the firmware that answers
    /// at all; anything that already looks like seconds is left alone.
    static func secondsFromMark(_ raw: UInt32) -> TimeInterval {
        let value = Double(raw)
        return value > 24 * 3600 ? value / 1000 : value
    }

    /// Record that this take has `count` marks.
    ///
    /// A mark must appear **in the transcript** ("打点也要有标记"), so each new one
    /// gets stamped on the card's clock. On this firmware `getMarking` is
    /// ignored, so the stamp is the moment the `penCollect` poll noticed the
    /// change — accurate to the poll interval, never claimed to be exact.
    func applyMarkCount(_ count: Int, explicitTimes: [UInt32] = []) {
        guard count > recordMarkCount else { return }
        let added = count - recordMarkCount
        if explicitTimes.count >= count {
            liveMarkers = explicitTimes.map(Self.secondsFromMark)
        } else {
            let at = deviceElapsed ?? 0
            liveMarkers.append(contentsOf: Array(repeating: at, count: added))
        }
        recordMarkCount = count
    }

    // MARK: - Saving the live transcript into the library

    /// The transcript exactly as displayed, plus a marker line per mark.
    func liveTranscriptWithMarks() -> String {
        var lines: [(at: TimeInterval, text: String)] = liveSegments.map { ($0.at, $0.text) }
        lines += liveMarkers.map { ($0, L10n.Plaud.liveMarkLine(PlaudLiveSegment.clock($0))) }
        return lines.sorted { $0.at < $1.at }.map(\.text).joined(separator: "\n")
    }

    /// Write the live transcript next to the clip the card just produced, and
    /// tag that clip as **live transcript** in the library.
    ///
    /// ★ 2026-10-22 on request ("方便结束后保存到资料库 / 来源要区分"): until now the
    ///   text only lived in memory and vanished with the next take. It is now
    ///   persisted as the clip's own transcript (`.txt` + `.asr.json`, provider
    ///   `live`), so the detail page shows it immediately, and the library entry
    ///   carries `source = "live"` → its badge reads 实时转录 instead of the
    ///   card's name.
    ///
    /// Call on the main thread (it reads `configService.config` and registers in
    /// the library, both main-actor bound).
    @MainActor func saveLiveTranscript(sessionID: Int, clipName: String, size: Int) {
        guard sessionID == liveTranscriptSessionID, liveTranscriptSavedTo == nil else { return }
        let text = liveTranscriptWithMarks().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Timestamps: each line ends at its own card clock, the previous line's
        // clock is its start (the same shape `LiveModel.buildAsrSegments` uses).
        let merged: [(at: TimeInterval, text: String)] = {
            var items: [(at: TimeInterval, text: String)] = liveSegments.map { ($0.at, $0.text) }
            items += liveMarkers.map { ($0, L10n.Plaud.liveMarkLine(PlaudLiveSegment.clock($0))) }
            return items.sorted { $0.at < $1.at }
        }()
        let segments: [AsrSegment] = merged.enumerated().map { index, item in
            let start = index > 0 ? merged[index - 1].at : 0
            let end = max(item.at, start)
            return AsrSegment(speaker: nil, text: item.text,
                              start: (start * 10).rounded() / 10,
                              end: (end * 10).rounded() / 10,
                              duration: ((end - start) * 10).rounded() / 10)
        }

        let url = StorageLocations.transcriptURLs(for: clipName)
        let locale = configService?.config.lastSourceLang ?? Locale.current.identifier
        do {
            try text.data(using: .utf8)?.write(to: url.txt, options: .atomic)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let result = AsrResult(text: text, segments: segments, provider: "live", locale: locale)
            try encoder.encode(result).write(to: url.json, options: .atomic)
        } catch {
            log.error("plaud live transcript write failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        liveTranscriptSavedTo = clipName
        library?.recordDownload(
            name: clipName,
            size: size,
            transport: "ble",
            deviceSerial: "plaud-\(pairedSN ?? "")",
            deviceName: "PLAUD",
            localName: clipName,
            // The bytes came over BLE, the **text** came from live transcription.
            // This is what the library badge keys off.
            source: "live"
        )
        log.info("plaud live transcript saved next to \(clipName, privacy: .public)")
    }

    /// Manual "save to library" from the Live screen: the transcript can only be
    /// written next to a real clip, so this re-asks the card for its recordings
    /// (the export completion then attaches the text).
    func saveLiveTranscriptToLibrary() {
        guard liveTranscriptSavedTo == nil else { return }
        guard !liveSegments.isEmpty || !livePartial.isEmpty else { return }
        if isSyncing { return }
        log.info("plaud live transcript: manual save — re-reading the card list")
        autoPullNewRecordings()
    }

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

    /// The name to show for a card: the user's alias if they renamed it, the
    /// product name otherwise. Keyed by SN so the alias survives reconnects and
    /// a second card keeps its own name.
    static func storedName(for sn: String) -> String {
        let alias = UserDefaults.standard.string(forKey: "plaud.name.\(sn)") ?? ""
        return alias.isEmpty ? modelName(for: sn) : alias
    }

    /// Rename the card. Empty input falls back to the product name.
    ///
    /// Why a rename lives on the phone and not on the card: the SDK's
    /// `setDeviceName` writes the BLE advertising name, which is shared by every
    /// phone that ever pairs with it — and a wrong name there would break
    /// reconnection for the official app too. A local alias is the reversible
    /// choice, and it is what the other cards do as well.
    func rename(to newName: String) {
        let sn: String
        if let paired = pairedSN {
            sn = paired
        } else if case .connected(let connected) = phase {
            sn = connected
        } else {
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? Self.modelName(for: sn) : trimmed
        if final == Self.modelName(for: sn) {
            UserDefaults.standard.removeObject(forKey: "plaud.name.\(sn)")
        } else {
            UserDefaults.standard.set(final, forKey: "plaud.name.\(sn)")
        }
        displayName = final
        // The ledger row (Settings → Devices) and the pill both read this name.
        let ledger = Self.ledgerID(for: sn)
        Task { @MainActor [weak self] in
            self?.configService?.renameDevice(id: ledger, name: final)
        }
    }

    private override init() {
        let d = UserDefaults.standard
        isConfigured = !(d.string(forKey: "plaud.client_id") ?? "").isEmpty
            && !(d.string(forKey: "plaud.client_secret") ?? "").isEmpty
        let storedSN = d.string(forKey: "plaud.paired_sn")
        pairedSN = storedSN
        if let sn = storedSN { displayName = Self.storedName(for: sn) }
        deleteAfterSync = d.bool(forKey: "plaud.delete_after_sync")
        syncedSessions = Set(d.array(forKey: "plaud.synced_sessions") as? [Int] ?? [])
        pulledSessions = syncedSessions
        if d.object(forKey: Self.batteryModeKey) != nil {
            batteryMode = d.integer(forKey: Self.batteryModeKey)
        }
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
        stopStatePolling()
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
            // Wake the card first: after a sleep it stops advertising, and a
            // scan alone would run out before it ever shows up (the reported
            // "tapping PLAUD does not connect / wake it").
            PlaudDeviceAgent.shared.setDeviceActive(status: 1)
            setPhase(.connecting(name: Self.modelName(for: sn)))
            clearScanned()
            reconnectTarget = sn
            PlaudDeviceAgent.shared.startScan()
        }
    }

    /// ★ Device Recovery ("救砖"): the card refuses every app. Scan for it and
    /// re-handshake with each historical client ID (force-clear) until the
    /// on-device lock matches one; then wipe the card completely
    /// (`depair(clear: true)` + cloud unbind) so ANY app — including the
    /// official one — can bind it like new. Erases all recordings on the card.
    func startRecovery() {
        guard !phase.isBusy, !phase.isConnected else { return }
        guard isConfigured else {
            setPhase(.failed(PlaudCloudService.PlaudError
                .badResponse("Direct connect is not activated yet.").localizedDescription))
            return
        }
        Task {
            do { try await ensureInitialized() } catch {
                setPhase(.failed(error.localizedDescription))
                return
            }
            guard !recoveryClientIDs.isEmpty else {
                setPhase(.failed(L10n.Plaud.recoveryFailed))
                return
            }
            recoveryMode = true
            recoveryIndex = 0
            recoveryDevice = nil
            setRecordNotice(nil)
            setSyncMessage(L10n.Plaud.recoveryRunning)
            setPhase(.scanning)
            clearScanned()
            reconnectTarget = nil
            PlaudDeviceAgent.shared.setDeviceActive(status: 1)
            PlaudDeviceAgent.shared.startScan()
        }
    }

    /// Try historical identity #`index` against the card found by the scan.
    private func attemptRecovery(_ index: Int) {
        let ids = recoveryClientIDs
        guard recoveryMode, let ble = recoveryDevice else { return }
        guard index < ids.count else {
            log.warning("plaud recovery: all \(ids.count) historical ids rejected")
            recoveryMode = false
            setSyncMessage(nil)
            setPhase(.failed(L10n.Plaud.recoveryFailed))
            return
        }
        recoveryIndex = index
        log.info("plaud recovery attempt #\(index + 1)/\(ids.count) id=\(ids[index], privacy: .public)")
        setPhase(.connecting(name: L10n.Plaud.recoveryRunning))
        PlaudDeviceAgent.shared.recoveryConnectBleDevice(
            bleDevice: ble, historicalUserId: ids[index])
    }

    /// Recovery handshake succeeded: the stale lock is gone and the card is
    /// bound to us — immediately wipe it (lock + recordings) and drop the link,
    /// leaving factory state for the official app.
    private func finishRecovery(sn: String) {
        recoveryMode = false
        log.info("plaud recovery succeeded for \(sn, privacy: .public) — wiping card")
        setSyncMessage(L10n.Plaud.recoveryRunning)
        PlaudDeviceAgent.shared.depair(clear: true)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureInitialized()
                try await self.cloudUnbind(sn: sn)
            } catch {
                log.warning("plaud recovery cloud unbind skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Give the depair command a beat to reach the card before dropping
        // the link (same pattern the unbind path uses implicitly).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            PlaudDeviceAgent.shared.disconnect()
            self.forgetLedger(sn: sn)
            self.pairedSN = nil
            UserDefaults.standard.removeObject(forKey: "plaud.paired_sn")
            self.scanned = []
            self.setSyncMessage(L10n.Plaud.recoveryDone)
            self.setPhase(.idle)
        }
    }

    /// Connect a card we know by SN only (the pill / picker hands us the ledger
    /// id `plaud-<SN>`). ★ 2026-10-21: needed because the "remembered" marker can
    /// be empty (first launch after an unbind, or data restored from a backup)
    /// while the ledger row is still there — and then tapping that row used to
    /// fall into the recorder-card scan, which can never find a PLAUD card.
    func connectKnown(sn: String) {
        guard !phase.isBusy, !phase.isConnected else { return }
        if pairedSN != sn {
            pairedSN = sn
            UserDefaults.standard.set(sn, forKey: "plaud.paired_sn")
            rememberInLedger(sn: sn)
        }
        reconnect()
    }

    func stopScan() {        PlaudDeviceAgent.shared.stopScan()
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
        // Close the live channel first: leaving it open makes the card keep
        // pushing PCM that nobody reads, which is exactly the "disconnect looks
        // like it did nothing, card still busy" symptom.
        recoveryMode = false
        if liveStreaming { PlaudDeviceAgent.shared.stopSyncFile() }
        stopStatePolling()
        Task { @MainActor in self.stopLiveTranscription() }
        PlaudDeviceAgent.shared.disconnect()
        // ★ Keep `pairedSN` (2026-10-21). Disconnecting is not unbinding: the
        // card stays "remembered", which is what lets the pill show its name and
        // lets one tap reconnect. Clearing it here made `reconnect()` impossible
        // (it needs the SN) and forced a full re-scan after every disconnect.
        // Unbind paths (`deactivate` / `releaseDevice`) still clear it.
        cardFileCount = nil
        cardFiles = []
        cardFilesLoaded = false
        // A queued batch delete is meaningless once the link is gone: the card
        // would still hold the files, and the UI already dropped them optimistically.
        pendingDeletes.removeAll()
        deletePumpScheduled = false
        // Same for a transfer: the export dies with the link, so the queue and
        // the watchdog must go too — otherwise `isSyncing` stays true and every
        // later pull is silently swallowed (the "下载无法传输" report).
        hardResetSync(keepCardFiles: true)
        stalledSessions.removeAll()
        liveStreaming = false
        livePCMBytes = 0
        clearRecordClock()
        recordMarks = []
        recordMarkCount = 0
        marksSessionID = nil
        fileProbeForMarks = false
        isRecording = false
        isPaused = false
        battery = nil
        storageFree = nil
        storageTotal = nil
        firmware = nil
        setRecordNotice(nil)
        setPhase(.idle)
    }

    // MARK: - Card controls (official-app parity)

    /// Home-page record button. One tap, whether or not the card is awake yet.
    ///
    /// · connected  → send `startRecord()` straight away;
    /// · remembered but asleep → wake + bind, then start as soon as `bleBind`
    ///   says status 0 (see the `pendingStartAfterConnect` consumer there);
    /// · no card at all → tell the user why nothing happened instead of a
    ///   silent no-op (the "button does nothing" class of bug).
    func startRecordingWhenReady() {
        guard !isRecording else { return }
        if phase.isConnected {
            startRecording()
            return
        }
        guard pairedSN != nil else {
            setRecordNotice(L10n.Plaud.notConnected)
            return
        }
        pendingStartAfterConnect = true
        setRecordNotice(L10n.Plaud.connectingThenRecord)
        if !phase.isBusy { reconnect() }
    }

    /// Cancel a queued "start after connect" (user changed their mind).
    func cancelPendingStart() {
        guard pendingStartAfterConnect else { return }
        pendingStartAfterConnect = false
        setRecordNotice(nil)
    }

    /// Start a recording on the card.
    ///
    /// ⚠️ The SDK is **asynchronous**: `startRecord()` sends the command and the
    /// truth comes back in `bleRecordStart(status:)`. Nothing here may set
    /// `isRecording = true` optimistically — that is exactly how the old build
    /// ended up with a button that "did nothing": it flipped a local flag, the
    /// card refused (busy / no space), and the UI quietly lied.
    func startRecording() {
        guard phase.isConnected else {
            setRecordNotice(L10n.Plaud.notConnected)
            return
        }
        setRecordNotice(nil)
        PlaudDeviceAgent.shared.startRecord()
    }

    /// Stop the card's ongoing recording.
    func stopRecording() {
        guard phase.isConnected else { return }
        setRecordNotice(nil)
        PlaudDeviceAgent.shared.stopRecord()
    }

    /// Pause / resume (the SDK exposes both; official app has pause).
    func pauseRecording() { PlaudDeviceAgent.shared.pauseRecord() }
    func resumeRecording() { PlaudDeviceAgent.shared.resumeRecord() }

    /// Pull battery/charging straight from the card.
    func refreshVitals() {
        // Same rule as the state poll: no chatter on the link while a file is
        // moving (this is called from `onAppear`/`onChange`, which fire exactly
        // when the user opens a page mid-transfer).
        guard !isSyncing else { return }
        PlaudDeviceAgent.shared.getChargingState()
        PlaudDeviceAgent.shared.getState()
        PlaudDeviceAgent.shared.getStorage()
        refreshBatteryMode()
    }

    /// Ask the card for its recording mode (BatteryMode). The answer arrives
    /// as `bleBatteryMode` — either forwarded by the agent to this delegate or
    /// silently swallowed; if it never arrives the UI keeps "not read yet".
    func refreshBatteryMode() {
        guard phase.isConnected, !batteryModeUnsupported, !isSyncing else { return }
        PlaudDeviceAgent.shared.bleAgent?.readBatteryMode()
    }

    /// Switch the recording mode. Optimistically publishes the new value and
    /// persists it (the read-back path is unavailable — see the key comment).
    func setBatteryMode(_ mode: Int) {
        guard phase.isConnected, !batteryModeUnsupported else { return }
        log.info("plaud set battery mode \(mode)")
        PlaudDeviceAgent.shared.bleAgent?.setBatteryMode(value: mode)
        DispatchQueue.main.async {
            self.batteryMode = mode
            UserDefaults.standard.set(mode, forKey: Self.batteryModeKey)
        }
    }

    /// Download ONE recording off the card. Queued through the same serial queue
    /// as a full sync, so a per-row tap can't run two BLE transfers at once.
    func download(file: PlaudCardFile) {
        download(files: [file])
    }

    /// Pull several recordings at once — the multi-select bar on the card list.
    ///
    /// Appends instead of replacing `pendingDownloads`: a row tap may already be
    /// mid-queue, and wiping it would silently abandon the file the card is
    /// currently exporting (`currentExportSession` would then never be cleared).
    func download(files: [PlaudCardFile]) {
        guard phase.isConnected else {
            setRecordNotice(L10n.Plaud.notConnected)
            return
        }
        // ★ 2026-10-21 (6th round, "点击下载无法传输 / 卡在 2/6"): a transfer that
        // stalled mid-queue used to hold `isSyncing` forever. Every later tap
        // then just appended to a dead queue — the button looked broken. So a
        // tap arriving at a silent transfer first *reclaims* the link, then
        // starts a fresh queue with what the user asked for.
        if isSyncing, isSyncStalled {
            log.warning("plaud sync looked stalled (\(Int(Date().timeIntervalSince(self.lastSyncActivity)))s of silence) — resetting before a new pull")
            hardResetSync(keepCardFiles: true)
            setSyncMessage(L10n.Plaud.syncStalledReset)
        }
        let unique = files.filter { file in
            // Skip what is already queued *and* what the card is exporting right
            // now — re-queueing the in-flight session would export it twice and
            // clear `currentExportSession` while the first copy is still writing.
            file.sessionID != currentExportSession
                && !pendingDownloads.contains { $0.sessionId == file.sessionID }
        }
        guard !unique.isEmpty else { return }
        // A manual pull clears the "gave up" mark: otherwise the 30 s fallback
        // would keep excluding that session forever and the user's retry would
        // never become part of normal auto-pull again.
        unique.forEach { stalledSessions.remove($0.sessionID) }
        let bles = unique.map { BleFile("", $0.sessionID, $0.size) }
        pendingDownloads.append(contentsOf: bles)
        if isSyncing {
            // A transfer is already running: just widen the queue, keep the bar
            // honest by growing the denominator. Say so — silently growing the
            // queue is what made the row button look dead.
            DispatchQueue.main.async { self.downloadTotal += bles.count }
            setSyncMessage(L10n.Plaud.queuedBehindTransfer(bles.count, pendingDownloads.count))
            return
        }
        setSyncing(true)
        DispatchQueue.main.async {
            self.downloadTotal = bles.count
            self.downloadDone = 0
            self.downloadProgress = 0
        }
        setSyncMessage(L10n.Plaud.syncDownloading(bles.count))
        downloadNext()
    }

    // MARK: - Transfer watchdog

    /// "No progress, no completion, no error" is the one state the SDK does not
    /// report — and it is exactly what the card produces when it falls asleep or
    /// drops mid-file. `isSyncStalled` is how the rest of the class asks.
    private var isSyncStalled: Bool {
        isSyncing && Date().timeIntervalSince(lastSyncActivity) > Self.syncSilenceLimit
    }

    /// Silence allowed before a transfer is declared stalled. A single 20 MB
    /// file at ~20 KB/s still ticks the progress callback dozens of times a
    /// second, so 20 s of complete quiet means the link is gone, not slow.
    private static let syncSilenceLimit: TimeInterval = 20

    private func noteSyncActivity() {
        lastSyncActivity = Date()
    }

    private func startSyncWatchdog() {
        syncWatchdog?.cancel()
        syncWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.isSyncing else { return }
                guard self.isSyncStalled else { continue }
                log.warning("plaud export stalled on session \(self.currentExportSession ?? -1) — skipping")
                self.skipStalledExport()
            }
        }
    }

    private func stopSyncWatchdog() {
        syncWatchdog?.cancel()
        syncWatchdog = nil
    }

    /// Drop the current file, move on to the next one. The card keeps the
    /// recording (nothing is deleted), so a later retry can still pull it.
    private func skipStalledExport() {
        if let stalled = currentExportSession {
            stalledSessions.insert(stalled)
        }
        // Tell the card to stop pushing; otherwise it keeps streaming into a
        // channel nobody drains and the next export inherits the mess.
        PlaudDeviceAgent.shared.stopDownloadFile()
        currentExportSession = nil
        noteSyncActivity()
        let remaining = pendingDownloads.count
        DispatchQueue.main.async {
            self.downloadSkipped += 1
            self.downloadProgress = 0
            self.downloadSpeed = ""
        }
        if remaining == 0 {
            finishSync()
        } else {
            setSyncMessage(L10n.Plaud.syncSkipped(remaining))
            downloadNext()
        }
    }

    /// User pressed "停止" (or switching pages forced it): stop the SDK, clear
    /// the queue, and say so. Never leaves `isSyncing` stuck.
    func cancelSync() {
        guard isSyncing else { return }
        PlaudDeviceAgent.shared.stopDownloadFile()
        hardResetSync(keepCardFiles: true)
        setSyncMessage(L10n.Plaud.syncCancelled)
    }

    private func hardResetSync(keepCardFiles: Bool) {
        pendingDownloads.removeAll()
        currentExportSession = nil
        stopSyncWatchdog()
        setSyncing(false)
        noteSyncActivity()
        DispatchQueue.main.async {
            self.downloadProgress = 0
            self.downloadSpeed = ""
            self.downloadSkipped = 0
        }
        _ = keepCardFiles
    }

    private func finishSync() {
        currentExportSession = nil
        stopSyncWatchdog()
        setSyncing(false)
        let skipped = downloadSkipped
        DispatchQueue.main.async {
            self.downloadProgress = 0
            self.downloadSpeed = ""
            self.downloadSkipped = 0
        }
        setSyncMessage(skipped > 0 ? L10n.Plaud.syncDoneWithSkips(skipped) : L10n.Plaud.syncDone)
    }

    /// Delete one recording from the card. Removed from the list immediately so
    /// the row can't be tapped twice; the card's own `bleDeleteFile` answer
    /// triggers a re-read that reconciles reality.
    func delete(file: PlaudCardFile) {
        delete(files: [file])
    }

    /// Erase several recordings (multi-select bar), one command at a time.
    ///
    /// The card answers each `deleteFile` asynchronously; firing ten of them
    /// back to back puts ten commands in front of whatever else is on the BLE
    /// channel. So: optimistic UI removal right away, then a pump that sends the
    /// next id when the previous answer arrives (1 s fallback if an answer is
    /// ever lost, so the queue can't wedge).
    func delete(files: [PlaudCardFile]) {
        guard phase.isConnected else {
            setRecordNotice(L10n.Plaud.notConnected)
            return
        }
        guard !isRecording else {
            setRecordNotice(L10n.Plaud.recordingNow)
            return
        }
        // ★ 2026-10-21 (4th round): deleting used to be blocked whenever a
        // transfer was running — and since the card auto-pulls, a transfer is
        // running most of the time, so the swipe button looked dead ("点击删除
        // 不了"). Only the file that is *currently* being exported has to wait.
        let targets = files.filter { $0.sessionID != currentExportSession }
        guard !targets.isEmpty else {
            setSyncMessage(L10n.Plaud.recordBusy)
            return
        }
        if targets.count != files.count {
            setSyncMessage(L10n.Plaud.recordBusy)
        }
        DispatchQueue.main.async {
            let ids = Set(targets.map(\.sessionID))
            self.cardFiles.removeAll { ids.contains($0.sessionID) }
            self.cardFileCount = self.cardFiles.count
            ids.forEach { self.syncedSessions.remove($0) }
            self.pulledSessions = self.syncedSessions
            UserDefaults.standard.set(Array(self.syncedSessions), forKey: "plaud.synced_sessions")
        }
        pendingDeletes.append(contentsOf: targets.map(\.sessionID))
        pumpDeletes()
    }

    /// Send the next queued `deleteFile` (one in flight at a time).
    private func pumpDeletes() {
        guard !deletePumpScheduled else { return }
        guard !pendingDeletes.isEmpty else { return }
        guard phase.isConnected else {
            pendingDeletes.removeAll()
            return
        }
        let sid = pendingDeletes.removeFirst()
        PlaudDeviceAgent.shared.deleteFile(sessionId: sid)
        deletePumpScheduled = true
        let generation = deletePumpGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.deletePumpGeneration == generation else { return }
            self.deletePumpScheduled = false
            self.pumpDeletes()
        }
    }

    /// Called on every `bleDeleteFile` answer: release the gate and move on.
    private func deleteAnswered() {
        deletePumpGeneration &+= 1
        deletePumpScheduled = false
        pumpDeletes()
    }

    // MARK: - Device ledger (Settings → Devices & Library)

    /// Write this card into `config.devices` so it is listed next to the other
    /// recorder cards. `ConfigService` is main-actor bound and this is called
    /// from the SDK's callback queue, hence the hop.
    private func rememberInLedger(sn: String) {
        let name = Self.storedName(for: sn)
        Task { @MainActor [weak self] in
            self?.configService?.rememberDevice(
                id: Self.ledgerID(for: sn),
                name: name,
                isRecorder: true
            )
        }
    }

    private func forgetLedger(sn: String) {
        Task { @MainActor [weak self] in
            self?.configService?.forgetDevice(id: Self.ledgerID(for: sn))
        }
    }

    // MARK: - State polling (card → app sync)

    /// Ask the card for its state every few seconds while connected.
    ///
    /// ★ Why polling (2026-10-21 user: "if recording starts on the PLAUD device,
    /// Nomily must sync too"): starting a recording **on the card** pushes
    /// nothing to us — `blePenState` is an *answer*, only sent in reply to
    /// `getState()`. Without this loop the app kept showing "Start recording"
    /// for a card that had been recording for minutes.
    private func startStatePolling() {
        statePollTask?.cancel()
        statePollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                guard self.phase.isConnected else { continue }
                // ★ Never talk to the card mid-transfer (2026-10-21: "the
                // transfer stutters"). Every command we send is queued ahead of
                // the file packets on the same serial BLE channel, so a 3 s
                // heartbeat of getState/getChargingState (plus getMarking) is
                // exactly what makes progress freeze and jump. The transfer
                // owns the link while it runs; the UI already shows its bar.
                if self.isSyncing { continue }
                // ★ Safety net for "卡片上有录音则自动传输" (4th round): the
                // event paths (bind / record-stop) cover the common cases, but a
                // card-side recording that starts AND stops between two state
                // polls would otherwise sit unpulled forever. Every ~30 s, while
                // idle, ask for the list — it only queues files we don't have.
                tick += 1
                if tick % 10 == 0 {
                    self.autoPullNewRecordings()
                    continue
                }
                PlaudDeviceAgent.shared.getState()
                PlaudDeviceAgent.shared.getChargingState()
                // ★ Marks ("打点") do NOT arrive on their own while recording —
                // `bleMarking` is an *answer* to `getMarking(sessionId:)`, and the
                // high-level agent has no such call: it lives on the low-level
                // `bleAgent`. Without this poll the mark count stayed at 0 until
                // the recording had finished (user: "打点没有实时同步到手机").
                //
                // ★ 2026-10-21 (7th round, "打点数值不增加"): two fixes here.
                //   · The poll is no longer gated on `isRecording`. That flag comes
                //     from `blePenState`, and if a card reports anything but 4099
                //     while recording (firmware dependent) the marks were never
                //     asked for at all. What matters is "there is a live session".
                //   · Every other tick also asks for the single file entry
                //     (`getFile(sessionId:)` → `bleFileList` with one item) and
                //     reads `penCollect`. If `getMarking` is a no-op on this
                //     firmware, the file's own mark counter still moves.
                if let sid = self.activeRecordSessionID {
                    if self.markingProbeStrikes < 2 {
                        self.markingProbeStrikes += 1
                        log.info("plaud marks probe #\(self.markingProbeStrikes): getMarking sid=\(sid) (bleAgent=\(PlaudDeviceAgent.shared.bleAgent != nil))")
                        PlaudDeviceAgent.shared.bleAgent?.getMarking(sid)
                        if self.markingProbeStrikes == 2, self.recordMarkCount == 0 {
                            // Two requests, no `bleMarking` answer: stop pretending
                            // a live count is coming and tell the UI the truth.
                            DispatchQueue.main.async { self.marksAvailableLive = false }
                        }
                    } else if tick % 2 == 1 {
                        // getMarking is being ignored on this firmware — fall back
                        // to the file entry's own counter (cheap, one command).
                        log.info("plaud marks fallback: getFile sid=\(sid)")
                        self.fileProbeForMarks = true
                        PlaudDeviceAgent.shared.getFile(sessionId: sid)
                    }
                }
            }
        }
    }

    private func stopStatePolling() {
        statePollTask?.cancel()
        statePollTask = nil
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
        if liveStreaming { PlaudDeviceAgent.shared.stopSyncFile() }
        stopStatePolling()
        Task { @MainActor in self.stopLiveTranscription() }
        PlaudDeviceAgent.shared.depair(clear: factoryReset)
        // ★ 2026-10-21 (8th round, "切换回官方 App"): `depair` releases the keys it
        // stored, but it does not necessarily drop the central-side link. If we
        // keep it, the official app can see the card on scan and still fail to
        // connect — which reads as "官方 App 用不了". So free the radio here:
        // disconnect the agent and drop the scan results.
        PlaudDeviceAgent.shared.disconnect()
        scanned = []
        selectedCard = nil
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
        guard !isRecording else {
            setRecordNotice(L10n.Plaud.recordingNow)
            return
        }
        fileListProbeOnly = false
        setSyncMessage(nil)
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    /// Ask the card "how many recordings do you hold?" **without** queueing any
    /// download. Used by the device pages (ledger row / device card) so the
    /// history count can be shown before the user decides to pull.
    func refreshCardRecordings() {
        guard phase.isConnected else { return }
        // The SDK documents `getFileList` as unavailable **while recording**;
        // sending it anyway poisons the command queue and the list never comes
        // back. The list refreshes itself right after `bleRecordStop`.
        guard !isRecording else {
            log.info("plaud file list skipped: card is recording")
            return
        }
        fileListProbeOnly = true
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    /// ★ "Anything on the card transfers by itself" (2026-10-21 user request).
    ///
    /// Same read as `syncFromCard`, minus the user-facing guards: the card just
    /// connected (or just stopped recording), so whatever it holds and we have
    /// not pulled yet is queued right away. This is the path that makes the
    /// promise true — a probe-only read would only count the files and leave
    /// them sitting there.
    private func autoPullNewRecordings() {
        guard phase.isConnected, !isRecording, !isSyncing else { return }
        fileListProbeOnly = false
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    // MARK: - Download queue

    private func handleFileList(_ files: [BleFile]) {
        let probeOnly = fileListProbeOnly
        fileListProbeOnly = false
        // The count is meaningful on BOTH paths — it is the card's history size.
        let mapped: [PlaudCardFile] = files.map { f in
            // ⚠️ `BleFile.duration()` is **milliseconds** (verified on hardware:
            // taken as seconds a 1.9 MB clip displayed as "7166:20").
            let seconds = f.size > 0 ? Double(f.duration()) / 1000.0 : 0
            let stamp = f.utsStamp()
            return PlaudCardFile(
                sessionID: f.sessionId,
                size: f.size,
                duration: seconds > 0 ? seconds : nil,
                recordedAt: stamp > 0 ? Date(timeIntervalSince1970: TimeInterval(stamp)) : nil,
                marks: f.penCollect
            )
        }
        .sorted { $0.sessionID > $1.sessionID }
        // ★ 2026-10-22 relaunch fallback: the card is recording, but the SDK's
        // `getCurrentSessionID()` only learns a session from a `bleRecordStart`
        // — and a relaunch produces none. Without this, reopening the app during
        // a take left the clock at our guess and pulled no audio at all. The
        // live take is the newest entry in the card's own list, so adopt it.
        if isRecording, recordStartedAt == nil, let newest = mapped.first, newest.size > 0 {
            log.info("plaud attach fallback: adopting newest card file sid=\(newest.sessionID) size=\(newest.size)")
            DispatchQueue.main.async {
                self.recordSessionID = newest.sessionID
                if let duration = newest.duration {
                    self.deviceElapsed = max(self.deviceElapsed ?? 0, duration)
                    self.recordStartedAt = Date().addingTimeInterval(-duration)
                } else if let recordedAt = newest.recordedAt {
                    self.recordStartedAt = recordedAt
                    self.deviceElapsed = max(0, Date().timeIntervalSince(recordedAt))
                }
            }
            PlaudDeviceAgent.shared.syncFile(sessionId: newest.sessionID, start: newest.size, end: 0)
            Task { @MainActor in self.startLiveTranscription(sessionID: newest.sessionID) }
        }
        DispatchQueue.main.async {
            self.cardFileCount = mapped.count
            self.cardFiles = mapped
            self.cardFilesLoaded = true
            // ★ 2026-10-21 (7th round): the ONLY dependable mark source on this
            // firmware. `getMarking` is ignored while recording (52 requests, 0
            // replies in the SDK log), but the finished file carries
            // `penCollect` — so once the list includes the take we just made,
            // that number is the real mark count and must replace the dead "—".
            if let sid = self.marksSessionID,
               let entry = mapped.first(where: { $0.sessionID == sid }),
               entry.marks > 0 {
                self.applyMarkCount(entry.marks)
                self.marksAvailableLive = false
            }
        }
        let fresh = files.filter {
            !syncedSessions.contains($0.sessionId) && !stalledSessions.contains($0.sessionId)
        }
        log.info("plaud file list: \(files.count) on card, \(fresh.count) new (probe=\(probeOnly))")
        if probeOnly { return }
        // ★ 2026-10-21 (6th round): a file list that lands **while a transfer is
        // running** must extend the queue, not replace it. Replacing it dropped
        // the files already queued behind the current one, and the old code's
        // "nothing new → setSyncing(false)" turned the bar off while an export
        // was still running (the card kept pushing; the UI said stopped).
        if isSyncing {
            let queued = Set(pendingDownloads.map(\.sessionId))
            let extra = fresh.filter {
                $0.sessionId != currentExportSession && !queued.contains($0.sessionId)
            }
            guard !extra.isEmpty else { return }
            pendingDownloads.append(contentsOf: extra)
            DispatchQueue.main.async { self.downloadTotal += extra.count }
            return
        }
        guard !fresh.isEmpty else {
            setSyncing(false)
            setSyncMessage(nil)
            return
        }
        setSyncing(true)
        setSyncMessage(L10n.Plaud.syncStarting(fresh.count))
        pendingDownloads = fresh
        DispatchQueue.main.async {
            self.downloadTotal = fresh.count
            self.downloadDone = 0
        }
        downloadNext()
    }

    private func downloadNext() {
        guard let next = pendingDownloads.first else {
            finishSync()
            return
        }
        pendingDownloads.removeFirst()
        currentExportSession = next.sessionId
        noteSyncActivity()
        startSyncWatchdog()
        setSyncMessage(L10n.Plaud.syncDownloading(pendingDownloads.count + 1))
        DispatchQueue.main.async {
            self.downloadProgress = 0
            self.downloadSpeed = ""
        }
        let handler = ExportHandler(service: self, sessionId: next.sessionId)
        PlaudDeviceAgent.shared.exportAudio(
            sessionId: next.sessionId,
            outputDir: NSTemporaryDirectory(),
            format: .mp3,
            channels: 1,
            callback: handler
        )
    }

    /// Live transfer feedback from the SDK's export callback.
    func handleExportProgress(sessionId: Int, progress: Int) {
        // Same guard as the completion path: a progress event for a session we
        // are no longer exporting (user deleted it / cancelled) must not move
        // the bar.
        guard currentExportSession == sessionId else { return }
        // Feed the watchdog **before** the UI throttle: activity is about "the
        // link is alive", not "the bar moved".
        noteSyncActivity()
        // ★ Throttle (2026-10-21 "the transfer stutters"): the callback fires for
        // every packet — dozens of times a second. Publishing each one rebuilds
        // the whole file list on the main thread, which competes with the SDK's
        // own decoding and *looks* like a stutter. 5 updates/s is all a progress
        // bar can show anyway.
        let now = Date()
        guard progress >= 100 || now.timeIntervalSince(lastProgressPublish) > 0.2 else { return }
        lastProgressPublish = now
        let speed = PlaudDeviceAgent.shared.getFormattedDownloadSpeed()
        DispatchQueue.main.async {
            self.downloadProgress = min(1, max(0, Double(progress) / 100))
            self.downloadSpeed = speed
        }
    }

    /// SDK finished writing the transcoded file — move it into the library
    /// directory under a friendly timestamped name and register it.
    func handleExportComplete(sessionId: Int, outputPath: String) {
        currentExportSession = nil
        noteSyncActivity()
        markSynced(sessionId)
        DispatchQueue.main.async {
            self.downloadDone += 1
            self.downloadProgress = 0
        }
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
                // ★ 2026-10-22: the clip for the take we just transcribed live is
                // in the library — write the transcript next to it now (and tag
                // the entry as 实时转录), so the text stops living only in memory.
                Task { @MainActor in
                    self.saveLiveTranscript(sessionID: sessionId, clipName: name, size: size)
                }
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
        noteSyncActivity()
        log.error("plaud export error for \(sessionId): \(message, privacy: .public)")
        // ★ 2026-10-21 (6th round, "卡在 2/6"): one bad file used to wipe the
        // WHOLE queue, so a six-file auto-pull died at the first refusal and the
        // user lost the four that were still fine. Skip and continue instead;
        // the counters say how many were missed.
        stalledSessions.insert(sessionId)
        DispatchQueue.main.async {
            self.downloadSkipped += 1
            self.downloadProgress = 0
            self.downloadSpeed = ""
        }
        if pendingDownloads.isEmpty {
            finishSync()
            setSyncMessage(L10n.Plaud.syncFailed(message))
        } else {
            setSyncMessage(L10n.Plaud.syncFailedOne(message))
            downloadNext()
        }
    }

    private func markSynced(_ sessionId: Int) {
        syncedSessions.insert(sessionId)
        UserDefaults.standard.set(Array(syncedSessions), forKey: "plaud.synced_sessions")
        let snapshot = syncedSessions
        DispatchQueue.main.async { self.pulledSessions = snapshot }
    }

    // MARK: - State marshalling

    private func setPhase(_ p: Phase) {
        // A queued "record after connect" is only meaningful while a link is on
        // its way up. Any other verdict (failed / idle) must drop it, otherwise
        // the next unrelated connect would start recording out of nowhere.
        if pendingStartAfterConnect {
            switch p {
            case .failed, .idle:
                pendingStartAfterConnect = false
                DispatchQueue.main.async { self.recordNotice = nil }
            default:
                break
            }
        }
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
    private func setRecordNotice(_ text: String?) {
        DispatchQueue.main.async { self.recordNotice = text }
    }

    /// Clear the running clock. Main-queue only (call sites are already marshalled).
    private func clearRecordClock() {
        recordStartedAt = nil
        deviceElapsed = nil
        recordSessionID = nil
        recordBytes = 0
        liveLevel = 0
    }

    /// Session id of the recording that is running right now, from either source.
    ///
    /// Used by the marks poll: `recordSessionID` is only set when *we* started
    /// the take, while `getCurrentSessionID()` also covers a take started on the
    /// card's own key. Returns nil as soon as the card says it is idle.
    private var activeRecordSessionID: Int? {
        if let sid = recordSessionID, sid > 0 { return sid }
        let current = PlaudDeviceAgent.shared.getCurrentSessionID()
        return current > 0 ? current : nil
    }

    /// Peak level of a 16-bit LE PCM block, normalised to 0…1.
    ///
    /// Peak (not RMS) on purpose: it is a "is the card hearing anything" meter,
    /// and a short word should visibly move it.
    static func peakLevel(of data: Data) -> Double {
        guard data.count >= 2 else { return 0 }
        var peak = 0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for s in samples {
                let v = abs(Int(s))
                if v > peak { peak = v }
            }
        }
        return min(1.0, Double(peak) / 32_768.0 * 3.0)   // ×3 so normal speech is visible
    }

    /// Human-readable reason for a non-zero `bleRecordStart` status.
    /// Mapping straight from the SDK header (1 space full / 2 U-disk / 3 hardware /
    /// 4 busy / 255 wrong mode) — silence here is what makes a button look dead.
    private func recordRefusal(_ status: Int) -> String {
        switch status {
        case 1:  return L10n.Plaud.recordSpaceFull
        case 2:  return L10n.Plaud.recordUDisk
        case 3:  return L10n.Plaud.recordHardware
        case 4:  return L10n.Plaud.recordBusy
        case 255: return L10n.Plaud.recordWrongMode
        default: return L10n.Plaud.recordFailed(status)
        }
    }
}

// MARK: - Export callback adapter

/// One handler per in-flight export. The SDK holds the callback strongly for
/// the duration of the call, so a fresh instance per file is safe (template
/// app does the same with ExportCallbackHandler / WiFiExportHandler).
private final class ExportHandler: NSObject, AudioExportCallback {
    private weak var service: PlaudDirectService?
    private let sessionId: Int
    /// ⚠️ The SDK fires `onProgress` **per BLE packet** (tens per second). An
    /// `os_log` call per packet is not free — it formats a string and hands it
    /// to the logging daemon on the same queue that is draining the transfer, so
    /// logging every packet adds exactly the stutter the user reported. One line
    /// per 10 % is plenty to reconstruct a transfer after the fact.
    private var lastLogged = -10

    init(service: PlaudDirectService, sessionId: Int) {
        self.service = service
        self.sessionId = sessionId
        super.init()
    }

    func onProgress(_ progress: Int, message: String) {
        if progress >= 100 || progress - lastLogged >= 10 {
            lastLogged = progress
            log.info("plaud export \(self.sessionId): \(progress)% \(message, privacy: .public)")
        }
        service?.handleExportProgress(sessionId: sessionId, progress: progress)
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
        // ★ Recovery path: take the strongest card we find and start the
        // force-clear handshake ladder — no pick list, the user asked for a
        // rescue, not a browse.
        if recoveryMode, let best = supported.sorted(by: { $0.rssi > $1.rssi }).first {
            recoveryDevice = best
            PlaudDeviceAgent.shared.stopScan()
            attemptRecovery(0)
            return
        }
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
        if recoveryMode {
            recoveryMode = false
            setSyncMessage(nil)
            setPhase(.failed(L10n.Plaud.cardGone))
            return
        }
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
        // Recovery ladder: a refused link means this historical id did not
        // match the lock — try the next one.
        if recoveryMode, state != 1 {
            attemptRecovery(recoveryIndex + 1)
            return
        }
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
        // ★ Recovery verdict: force-clear handshake accepted → the stale lock
        // is wiped; finish by erasing the card and dropping the link. Rejected
        // → the next historical id gets its try.
        if recoveryMode {
            if status == 0, let sn {
                finishRecovery(sn: sn)
            } else {
                log.warning("plaud recovery bind rejected: status \(status)")
                attemptRecovery(recoveryIndex + 1)
            }
            return
        }
        guard status == 0, let sn else {
            log.warning("plaud bind rejected: status \(status)")
            setPhase(.failed(L10n.Plaud.pairRejected))
            return
        }
        log.info("plaud bound: \(sn, privacy: .public)")
        pairedSN = sn
        UserDefaults.standard.set(sn, forKey: "plaud.paired_sn")
        // Keep the user's alias across reconnects (and across cards, since it is
        // keyed by SN) instead of snapping back to the product name.
        DispatchQueue.main.async { self.displayName = Self.storedName(for: sn) }
        // A bound card is one of "my devices" now — same ledger the other
        // recorder cards live in, so it appears in Settings → Devices.
        rememberInLedger(sn: sn)
        // Firmware is read off the advertisement at scan time.
        if let card = selectedCard, card.sn == sn {
            firmware = cachedBleDevices[sn].map { $0.wholeVersion() }
        }
        DispatchQueue.main.async { self.selectedCard = nil }
        setPhase(.connected(sn: sn))
        startStatePolling()
        // Pull vitals right away, then auto-pull the file list like the
        // official template does.
        refreshVitals()
        // ★ If the card is ALREADY recording (started by its own key), attach to
        // that session instead of pretending it is idle: without a sync-file
        // channel there is no clock and no live audio, and the user sees a
        // "Start recording" button for a card that is busy recording.
        let current = PlaudDeviceAgent.shared.getCurrentSessionID()
        if current > 0 {
            log.info("plaud attached to a recording already in progress (sid \(current))")
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordSessionID = current
                if self.recordStartedAt == nil { self.recordStartedAt = Date() }
            }
            PlaudDeviceAgent.shared.syncFile(sessionId: current, start: 0, end: 0)
            DispatchQueue.main.async { self.liveStreaming = true }
        } else {
            // Auto-pull: a card that just connected with recordings on it should
            // start transferring them without a tap (2026-10-21 request).
            autoPullNewRecordings()
            // Honour a "record now" tap that arrived while the card was asleep.
            // A short beat, because `startRecord` right on top of the bind
            // handshake gets refused by the card (it is still reading its own
            // storage); 0.6 s matches the gap the official app leaves.
            if pendingStartAfterConnect {
                pendingStartAfterConnect = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard self.phase.isConnected, !self.isRecording else { return }
                    self.setRecordNotice(nil)
                    PlaudDeviceAgent.shared.startRecord()
                }
            }
        }
    }

    /// @required — recorder state push.
    ///
    /// ⚠️ **`state == 1` is IDLE** (verified on hardware 2026-10-21): the card
    /// answers every 3 s poll with `state 1, privacy 1, key 0` while it is doing
    /// nothing, so treating 1 as "recording" made the app claim a recording that
    /// never happened — the clock even ticked, because we then opened a sync-file
    /// channel on a stale session. Recording is the high-bit value (4099) that the
    /// official app's state dump showed.
    func blePenState(state: Int, privacy: Int, keyState: Int, uDisk: Int, findMyToken: Int, hasSndpKey: Int, deviceAccessToken: Int) {
        log.info("plaud pen state \(state) privacy \(privacy) key \(keyState) udisk \(uDisk)")
        let nowRecording = (state == 4099)
        let wasRecording = isRecording
        DispatchQueue.main.async {
            self.isRecording = nowRecording
            // The card stopped on its own (key press / out of space): clear the
            // clock here too, otherwise the timer keeps running on screen.
            if wasRecording && !nowRecording { self.clearRecordClock() }
        }
        if wasRecording && !nowRecording {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard self.phase.isConnected else { return }
                self.refreshCardRecordings()
            }
        }
        // ★ A recording that was started by the card's own key never produces a
        // `bleRecordStart` for us, so this push is the ONLY place we learn about
        // it. Without an anchor the clock sat at 0:00 while audio flowed
        // (hardware, 2026-10-21); without a sync-file channel there is no
        // duration and no PCM at all.
        if nowRecording && recordStartedAt == nil {
            attachToRunningRecording()
        }
    }

    /// Start following a recording we did **not** start (physical key, or it was
    /// already running when we connected).
    ///
    /// ★ 2026-10-22 ("killed the app while the card was recording, the clock
    ///   never matched the card again"). Two independent faults made the timer
    ///   restart from 0:00 on relaunch:
    ///
    ///   ① **The anchor was `Date()`** — literally "the recording began when the
    ///      app reopened" — and only a positive `blePcmData.millsec` could move
    ///      it, which that field often is not.
    ///   ② **The sync channel opened at byte 0**, so the card replayed the whole
    ///      file from the beginning. What arrived was a backlog of old audio
    ///      timed from zero, while the card itself was minutes in.
    ///
    ///   Now the start time comes from the session id itself (the SDK documents
    ///   it as a 0-timezone timestamp), the file entry is probed for its real
    ///   `duration`/`utsStamp`, and the channel opens at the **current end** so
    ///   only new audio is pushed.
    private func attachToRunningRecording() {
        let sid = PlaudDeviceAgent.shared.getCurrentSessionID()
        log.info("plaud attaching to a running recording (sid \(sid))")
        guard sid > 0 else {
            // No sid yet: the SDK has not read the card's session after the
            // relaunch. Do **not** anchor the clock to "now" here — that is the
            // bogus 0:00 clock this method exists to fix. Leave `recordStartedAt`
            // nil and ask the card for its list: the live take is the newest
            // entry, and `handleFileList` adopts it (see the relaunch fallback).
            log.warning("plaud attach: no live session id yet — asking for the card list")
            DispatchQueue.main.async {
                self.isRecording = true
                self.liveStreaming = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.isRecording, self.recordStartedAt == nil else { return }
                self.fileListProbeOnly = true   // count only — never queue a pull mid-take
                PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
            }
            return
        }
        let anchored = Self.startDate(fromSessionID: sid)
        DispatchQueue.main.async {
            self.isRecording = true
            if self.recordStartedAt == nil {
                self.recordStartedAt = anchored ?? Date()
            }
            if self.deviceElapsed == nil, let start = self.recordStartedAt {
                // The session id already tells us how long the take has been running.
                self.deviceElapsed = max(0, Date().timeIntervalSince(start))
            }
            self.recordSessionID = sid
            // A take started on the card's key: marks belong to it, so start
            // from zero instead of carrying the previous take's number over.
            if self.marksSessionID != sid {
                self.recordMarks = []
                self.recordMarkCount = 0
                self.marksSessionID = sid
            }
            self.liveStreaming = true
        }
        // Probe the file entry first — it carries the byte offset we must start
        // from and the card's own duration.
        pendingAttachSessionID = sid
        fileProbeForMarks = true
        PlaudDeviceAgent.shared.getFile(sessionId: sid)
        // If the card never answers the probe, keep audio flowing the old way
        // (from 0) — the clock stays honest thanks to the session-id anchor.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.pendingAttachSessionID == sid else { return }
            self.pendingAttachSessionID = nil
            self.fileProbeForMarks = false
            log.warning("plaud attach: file probe timed out — opening sync at 0")
            PlaudDeviceAgent.shared.syncFile(sessionId: sid, start: 0, end: 0)
            Task { @MainActor in self.startLiveTranscription(sessionID: sid) }
        }
    }

    /// The take's start time from a session id.
    ///
    /// The SDK documents `sessionId` as "0 timezone timestamp" — i.e. unix
    /// seconds in UTC, which `Date(timeIntervalSince1970:)` renders in local
    /// time correctly. The ±timezone candidates exist because one firmware build
    /// was seen stamping **local wall-clock seconds as if they were UTC**; the
    /// first candidate within a sane window wins.
    private static func startDate(fromSessionID sid: Int) -> Date? {
        guard sid > 1_600_000_000 else { return nil }
        let now = Date().timeIntervalSince1970
        let offset = Double(TimeZone.current.secondsFromGMT())
        for candidate in [Double(sid), Double(sid) - offset, Double(sid) + offset] {
            guard candidate <= now + 300, now - candidate < 2 * 86_400 else { continue }
            return Date(timeIntervalSince1970: candidate)
        }
        return nil
    }

    // MARK: Recording callbacks (the whole interaction hangs on these)
    //
    // Before 2026-10-21 none of these were implemented, so `startRecord()` /
    // `stopRecord()` sent bytes to the card and the app never heard back: the
    // buttons "did nothing" and no duration ever appeared. The SDK answers
    // asynchronously — start/stop are only true once these fire.

    func bleRecordStart(sessionId: Int, start: Int, status: Int, scene: Int, startTime: Int, reason: Int) {
        log.info("plaud record start sid=\(sessionId) start=\(start) status=\(status) scene=\(scene) startTime=\(startTime) reason=\(reason)")
        guard status == 0 else {
            DispatchQueue.main.async { self.isRecording = false }
            setRecordNotice(recordRefusal(status))
            return
        }
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordSessionID = sessionId
            self.recordBytes = start
            self.recordNotice = nil
            self.recordMarks = []
            self.recordMarkCount = 0
            self.marksSessionID = sessionId
            self.markingProbeStrikes = 0
            self.marksAvailableLive = true
            // `startTime` is the card's own start stamp (unix seconds). Using it
            // keeps the clock honest when we TAKE OVER a recording that was
            // started by the physical key before the app was listening.
            if startTime > 1_600_000_000 {
                self.recordStartedAt = Date(timeIntervalSince1970: TimeInterval(startTime))
            } else {
                self.recordStartedAt = Date()
            }
            // `start` > 0 = the card was already recording: the elapsed byte
            // count alone can't give seconds, so let the PCM clock correct it.
            if start == 0 { self.deviceElapsed = nil }
        }
        // ★ Open the sync-file channel: that is what makes the SDK push
        // `blePcmData` (real-time duration + audio for live transcription).
        // Without this call a recording is silent to the app until it stops.
        if !isSyncing {
            PlaudDeviceAgent.shared.syncFile(sessionId: sessionId, start: start, end: 0)
            DispatchQueue.main.async {
                self.liveStreaming = true
                self.livePCMBytes = 0
            }
            Task { @MainActor in self.startLiveTranscription(sessionID: sessionId) }
        }
    }

    func bleRecordResume(sessionId: Int, start: Int, status: Int, scene: Int, startTime: Int) {
        log.info("plaud record resume sid=\(sessionId) start=\(start) status=\(status)")
        guard status == 0 else {
            setRecordNotice(recordRefusal(status))
            return
        }
        DispatchQueue.main.async {
            self.isRecording = true
            self.isPaused = false
            self.recordSessionID = sessionId
            self.recordBytes = start
            if self.recordStartedAt == nil { self.recordStartedAt = Date() }
        }
    }

    func bleRecordPause(sessionId: Int, reason: Int, fileExist: Bool, fileSize: Int) {
        log.info("plaud record pause sid=\(sessionId) fileSize=\(fileSize)")
        DispatchQueue.main.async {
            self.isPaused = true
            self.isRecording = false
        }
    }

    func bleRecordStop(sessionId: Int, reason: Int, fileExist: Bool, fileSize: Int) {
        log.info("plaud record stop sid=\(sessionId) reason=\(reason) exist=\(fileExist) size=\(fileSize)")
        PlaudDeviceAgent.shared.stopSyncFile()
        Task { @MainActor in self.stopLiveTranscription() }
        DispatchQueue.main.async {
            self.clearRecordClock()
            self.isRecording = false
            self.isPaused = false
            self.liveStreaming = false
        }
        // The stop just wrote a file to the card — re-read the list so the home
        // segment shows it immediately instead of lagging one clip behind, and
        // pull it right away ("卡片上有录音则自动传输").
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard self.phase.isConnected else { return }
            self.autoPullNewRecordings()
        }
    }

    /// Live audio + the card's own recording clock.
    ///
    /// `millsec` is the card's elapsed recording time — the number to show. The
    /// PCM payload is what a live transcript needs; we keep a rolling level
    /// meter here and forward the buffer to the live sink when one is attached.
    func blePcmData(sessionId: Int, millsec: Int, pcmData: Data, isMusic: Bool) {
        let seconds = Double(millsec) / 1000
        // ★ 2026-10-22: measure the block **here**, on the SDK's queue. This used
        //   to run inside the `main.async` below, i.e. a full pass over the PCM
        //   buffer on the main thread for every block the card pushed — pure
        //   competition with SwiftUI while the live transcript is on screen.
        let level = Self.peakLevel(of: pcmData)
        let bytes = pcmData.count
        // ★ Diag proof of "is the card pushing audio at all": one line every
        // ~200 blocks, so a dead live transcript can be told apart from a dead
        // stream without a syslog session.
        pcmBlockCount += 1
        if pcmBlockCount % 200 == 0 {
            TicNoteDiagLog.log("PLAUD-PCM", "blocks=\(pcmBlockCount) bytes=\(bytes) elapsed=\(Int(seconds))s")
        }
        // The level meter cannot show more than ~20 steps a second anyway; every
        // extra publish rebuilds the device list.
        let publishLevel = Date().timeIntervalSince(lastLevelPublish) > 0.05
        if publishLevel { lastLevelPublish = Date() }
        DispatchQueue.main.async {
            // ⚠️ `millsec == 0` means the card did not stamp this block. Taking
            // it at face value pinned the clock at 0:00 while audio flowed
            // (seen on hardware); only a positive, non-decreasing report may
            // move `deviceElapsed`, otherwise the local anchor keeps ticking.
            if seconds > 0 {
                self.deviceElapsed = max(self.deviceElapsed ?? 0, seconds)
            }
            if self.recordStartedAt == nil {
                self.recordStartedAt = Date().addingTimeInterval(-max(0, seconds))
            }
            self.livePCMBytes += bytes
            if publishLevel { self.liveLevel = level }
            if !self.isRecording { self.isRecording = true }
        }
        liveAudioSink?(pcmData, seconds)
    }

    func bleDataComplete() {
        log.info("plaud data complete")
    }

    /// Bookmark pressed on the card ("打点"). Pushed while recording, so the app
    /// can show the count live instead of only finding out after the transfer.
    func bleMarking(sessionId: Int, status: Int, markList: [UInt32]) {
        // ★ Log the head of the list, not just its length: when the count "does
        // not increase" the question is always *what* the card sent — an empty
        // list, a stale one, or the same one repeated.
        let head = markList.prefix(6).map(String.init).joined(separator: ",")
        log.info("plaud marking sid=\(sessionId) status=\(status) count=\(markList.count) first=[\(head)]")
        DispatchQueue.main.async {
            self.markingProbeStrikes = 0
            self.marksAvailableLive = true
            self.recordMarks = markList
            self.applyMarkCount(markList.count, explicitTimes: markList)
            self.marksSessionID = sessionId
        }
    }

    func bleSyncFileStop() {
        log.info("plaud sync-file stopped")
        DispatchQueue.main.async { self.liveStreaming = false }
    }

    func bleDecodeFail(start: Int) {
        log.warning("plaud decode fail at offset \(start)")
    }

    func bleDeleteFile(sessionId: Int, status: Int) {
        log.info("plaud delete file \(sessionId) status \(status)")
        // Release the one-in-flight gate first, so a batch delete does not wait
        // out the 1 s fallback between every file.
        deleteAnswered()
        // Re-reading the list per deleted file would fire N `getFileList`s in a
        // row (each one a full BLE round trip). Only reconcile once the queue
        // is drained — or when a single swipe-delete is all there was.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard self.phase.isConnected, self.pendingDeletes.isEmpty else { return }
            self.refreshCardRecordings()
        }
    }

    func bleDepair(_ status: Int) {
        log.info("plaud depair status \(status)")
    }

    func bleDeviceDisconnectErr() {
        log.warning("plaud device dropped")
        stopStatePolling()
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

    /// Recording mode answer (BatteryMode common setting, CMD-8 family).
    /// ★ On hardware (2026-10-22) this never fired — the agent consumes the
    /// response internally. Kept wired anyway: if a firmware/SDK update starts
    /// forwarding it, the UI heals and the persisted value gets confirmed.
    /// `0xFFFFFFFF` = the firmware does not implement it — grey the UI out,
    /// never render the sentinel as a mode (nil ≠ 0 rule).
    func bleBatteryMode(_ value: Int) {
        log.info("plaud battery mode \(value)")
        DispatchQueue.main.async {
            if value < 0 || value > 0xFFFFFFF {
                self.batteryModeUnsupported = true
            } else {
                self.batteryMode = value
                UserDefaults.standard.set(value, forKey: Self.batteryModeKey)
            }
        }
    }

    /// Generic settings echo — kept as a probe: when the agent forwards a
    /// setting response it names the setting here even when it does not carry
    /// the value, which still proves the read reached the card.
    func bleCommonSetting(setting: Int) {
        log.info("plaud common setting echo \(setting)")
    }

    func bleFileList(bleFiles: [BleFile]) {
        // ★ Marks fallback (7th round): the poll asks for ONE file entry while
        // recording (`getFile(sessionId:)`) so `penCollect` — the card's own mark
        // counter — can be read even when `getMarking` answers nothing. That
        // answer must not be mistaken for a full card listing (it would blank the
        // list down to a single row).
        if fileProbeForMarks {
            fileProbeForMarks = false
            if let sid = activeRecordSessionID,
               let entry = bleFiles.first(where: { $0.sessionId == sid }) {
                let collect = entry.penCollect
                let size = entry.size
                // ⚠️ `duration` is milliseconds (same trap as the file list).
                let seconds = size > 0 ? Double(entry.duration()) / 1000.0 : 0
                let stamp = entry.utsStamp()
                log.info("plaud file probe sid=\(sid) penCollect=\(collect) size=\(size) duration=\(Int(seconds))s stamp=\(stamp)")
                let attaching = pendingAttachSessionID == sid
                DispatchQueue.main.async {
                    self.applyMarkCount(collect)
                    // The card's own duration beats every local guess — this is
                    // what a relaunch during a take needs to land on the right
                    // second instead of starting from 0:00.
                    if seconds > 0 {
                        self.deviceElapsed = max(self.deviceElapsed ?? 0, seconds)
                        self.recordStartedAt = Date().addingTimeInterval(-seconds)
                    } else if stamp > 0 {
                        let started = Date(timeIntervalSince1970: TimeInterval(stamp))
                        if abs(started.timeIntervalSinceNow) < 2 * 86_400 {
                            self.recordStartedAt = started
                            self.deviceElapsed = max(0, Date().timeIntervalSince(started))
                        }
                    }
                }
                if attaching {
                    pendingAttachSessionID = nil
                    // ★ From the CURRENT end, not byte 0: opening at 0 made the
                    // card replay the whole file, so the app heard a backlog
                    // timed from zero while the card was already minutes in.
                    log.info("plaud attach: opening sync at current end (\(size) bytes)")
                    PlaudDeviceAgent.shared.syncFile(sessionId: sid, start: size, end: 0)
                    Task { @MainActor in self.startLiveTranscription(sessionID: sid) }
                }
                return
            }
            // Fall through to the normal handling if the entry was not there.
        }
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
