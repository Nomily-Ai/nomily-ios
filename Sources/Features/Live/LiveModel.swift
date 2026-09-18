import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "live")

struct LiveSegment: Equatable {
    let text: String
    let translation: String?
    let timestamp: TimeInterval
}

enum LiveStartError: LocalizedError {
    /// Device is recording but has real-time upload off for this clip, so
    /// `CMD 0x68` would produce nothing.
    case deviceNotUploading

    var errorDescription: String? {
        switch self {
        case .deviceNotUploading: return L10n.Live.attachNoUpload
        }
    }
}

@MainActor
final class LiveModel: ObservableObject {
    @Published var sourceLang: String = "en"
    @Published var targetLang: String?
    @Published var isRunning = false
    @Published var isPaused = false
    @Published var bytes = 0
    @Published var frames = 0
    @Published var error: String?
    /// True when the current `error` is "this device isn't paired with the
    /// app" — the view turns it into the same "Pair now" guidance the
    /// recording entry uses, instead of a dead-end message (qhgmvqf4).
    @Published var errorNeedsPairing = false
    @Published var activeProvider: String = ""
    @Published var wsConnected = false
    @Published var finalSegments: [LiveSegment] = []
    @Published var partialText: String = ""
    @Published var partialTranslation: String = ""
    @Published var savedClipName: String?
    @Published var targetLangName: String = ""
    @Published var pendingRepair: PendingRepair?
    @Published var repairState: RepairState = .idle
    /// Set when `start()` couldn't establish whether the device is already
    /// recording. The view turns this into a confirmation — starting blind
    /// can cut off a recording the user began with the physical button.
    @Published var pendingStartConfirm = false

    /// True if the user paused at any point during the current session, so
    /// the saved iOS clip is missing audio for the paused intervals. The
    /// device has the complete recording on its own storage; we offer to
    /// pull it down via BLE to replace the incomplete iOS copy.
    private var didPauseDuringSession = false

    /// True when this session tapped a recording the device had already
    /// started (physical button). The user never paused anything, so the
    /// repair prompt must not claim they did.
    private var attachedToExistingRecording = false

    /// name → size for everything on the device when the session started.
    /// `nil` means the snapshot failed, in which case no candidate can be
    /// identified with confidence and the repair flow degrades to a
    /// manual-transfer hint rather than guessing.
    private var preSessionFiles: [String: Int]?

    /// Providers already tried and found dead this session. A provider that
    /// connects but never delivers a single result gets crossed off so the
    /// next one in the chain is used instead of retrying the same dead end.
    private var deadASRProviders: Set<String> = []

    /// Whether the current ASR link has produced anything yet. Until it has,
    /// nothing proves the WebSocket handshake and auth actually succeeded.
    private var currentASRProducedResult = false

    struct PendingRepair: Equatable {
        let deviceFileName: String
        let iosClipName: String
        let expectedSize: Int
        /// The session attached to a recording already in progress rather
        /// than the user pausing. Same offer, different wording — telling
        /// someone "your recording had a pause" when they never paused is
        /// just wrong.
        let wasAttached: Bool

        var message: String {
            wasAttached ? L10n.Live.repairMessageAttached : L10n.Live.repairMessage
        }
    }

    enum RepairState: Equatable {
        case idle
        case downloading(received: Int, total: Int)
        case failed(String)
        case succeeded
        /// Session had pauses but the device file couldn't be resolved (e.g.
        /// getFileList cancelled, or no file matched the size floor). The
        /// complete recording is still on the device; the user can fetch it
        /// manually from Recordings.
        case needsManualTransfer
    }

    @MainActor
    private enum ActiveASR {
        case local(LiveStreamASR)
        case azure(AzureLiveASR)
        case azureTranslate(AzureLiveTranslation)

        func send(_ data: Data) {
            switch self {
            case .local(let asr): asr.send(data)
            case .azure(let asr): asr.send(data)
            case .azureTranslate(let asr): asr.send(data)
            }
        }

        func close() {
            switch self {
            case .local(let asr): asr.close()
            case .azure(let asr): asr.close()
            case .azureTranslate(let asr): asr.close()
            }
        }
    }

    private var startedAt: Date?
    private var streamTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var currentASR: ActiveASR?
    /// True while `closeASR()` is tearing the WebSocket down on purpose
    /// (pause / stop / provider switch), so the resulting `.closed` event is
    /// not mistaken for a dropped link and does not trigger a reconnect.
    private var intentionalASRClose = false
    /// Bounded reconnect budget for unexpected ASR drops; reset whenever a
    /// result actually arrives (proof the link is working again).
    private var asrReconnectAttempts = 0
    private let maxASRReconnects = 5

    private var streamBuffer = Data()
    private var library: Library?
    private var config: ConfigService?

    private var silentPlayer: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?

    var statusText: String {
        if isPaused { return L10n.Live.paused }
        return isRunning ? L10n.Live.streaming : L10n.Live.ready
    }

    var durationLabel: String {
        let secs = Int(Double(bytes / OpusOgg.frameSize) * 0.02)
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // MARK: - start

    /// `assumeIdle` is only set by the "start anyway" branch of the
    /// unknown-state confirmation below. Everything else leaves it false.
    func start(client: DnoteClient, config: ConfigService, library: Library, assumeIdle: Bool = false) async {
        guard !isRunning else { return }
        frames = 0
        bytes = 0
        error = nil
        errorNeedsPairing = false
        finalSegments = []
        partialText = ""
        partialTranslation = ""
        wsConnected = false
        activeProvider = ""
        savedClipName = nil
        streamBuffer = Data()
        didPauseDuringSession = false
        pendingRepair = nil
        repairState = .idle
        pendingStartConfirm = false
        deadASRProviders = []
        currentASRProducedResult = false
        attachedToExistingRecording = false
        preSessionFiles = nil
        asrReconnectAttempts = 0
        intentionalASRClose = false
        self.library = library
        self.config = config

        do {
            try openASR(config: config)
        } catch {
            self.error = error.localizedDescription
            return
        }

        do {
            // If the device is already recording (physical-button start, or
            // a session we lost track of across app relaunch), skip
            // startRecording — CMD 0x51 on a rec=1 device would rotate the
            // in-progress clip. Tap the live stream on the existing
            // session instead. `CMD 0x68` only yields frames when the
            // device has real-time upload on for this recording (0x56
            // `upload` = 1).
            // Three outcomes, not two. `getDeviceInfo()` failing with no
            // cached state used to collapse into "not recording", so the
            // else-branch below fired CMD 0x51 at a device that might have
            // been mid-recording — rotating (cutting off) whatever the user
            // was capturing with the physical button. When the state can't
            // be established, stop and ask instead of guessing.
            let alreadyRecording: Bool
            if let info = try? await client.getDeviceInfo() {
                alreadyRecording = info.isRecording
            } else if let cached = client.lastDeviceInfo {
                alreadyRecording = cached.isRecording
            } else if assumeIdle {
                alreadyRecording = false
            } else {
                log.warning("start: device recording state unknown — asking the user before CMD 0x51")
                currentASR?.close()
                currentASR = nil
                isRunning = false
                pendingStartConfirm = true
                return
            }

            // Snapshot the device's files before we touch its recorder. At
            // stop this is what identifies "the file this session produced"
            // — a file that wasn't there before, or (when attaching) the one
            // that grew. Without it the resolve fell back to "newest name
            // above a size floor", which can be an unrelated older recording
            // that the repair flow would then overwrite and delete.
            preSessionFiles = try? await client.getFileList()
                .reduce(into: [String: Int]()) { $0[$1.name] = $1.size }
            if preSessionFiles == nil {
                log.warning("start: pre-session file snapshot failed — repair will fall back to manual transfer")
            }

            if alreadyRecording {
                // Real-time upload is decided when the recording starts:
                // 0x51 payload 0x01, or our 0x01 ack to the 0x54 push when
                // the button is pressed while we're connected. A recording
                // that began before this connection has `upload` = 0 and
                // the firmware will never push a frame for it — say so now
                // instead of showing "Listening…" until a timeout.
                if let status = try? await client.getRecordingStatus(),
                   let upload = (status["upload"] as? NSNumber)?.intValue,
                   upload == 0 {
                    log.warning("start: device recording has upload=0 — live stream unavailable for this recording")
                    throw LiveStartError.deviceNotUploading
                }
                // iOS captured audio only covers from the attach point,
                // so the saved clip will be shorter than the device file.
                // Reuse the pause-repair path so stop offers to replace
                // the iOS clip with the device's complete recording.
                didPauseDuringSession = true
                attachedToExistingRecording = true
                log.info("start: attaching to existing device recording")
                try await client.startStream()
            } else {
                try await client.startRecording(realTime: true)
                try await client.startStream()
            }
            startedAt = Date()
            isRunning = true
            spawnStreamTask(client: client)
        } catch {
            self.error = error.localizedDescription
            if let dnoteError = error as? DnoteError, case .notBound = dnoteError {
                self.errorNeedsPairing = true
            }
            isRunning = false
            currentASR?.close()
            currentASR = nil
        }
    }

    // MARK: - pause / resume

    /// Temporarily suspend the session. Closes the ASR WebSocket but leaves
    /// the BLE stream tap + device recording untouched — the stream task
    /// keeps popping frames off `streamQueue`, it just drops them while
    /// `isPaused`. Dropping frames (vs. tearing down BLE) avoids
    /// `startStream → stopStream → startStream` cycles that don't always
    /// re-arm the device's stream emitter on firmware 1.39.
    func pause() async {
        guard isRunning, !isPaused else { return }
        didPauseDuringSession = true
        commitPartial()
        await closeASR()
        isPaused = true
    }

    func resume(config: ConfigService) async {
        guard isRunning, isPaused else { return }
        do {
            try openASR(config: config)
            isPaused = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func spawnStreamTask(client: DnoteClient) {
        streamTask = Task { [weak self] in
            guard let self else { return }
            var cancelled = false
            do {
                // 10 s is generous for a device that is pushing at all
                // (frames come every 20 ms); the default 30 s is for gaps
                // mid-session, not for the first packet.
                for try await frame in client.streamAudio(firstFrameTimeout: 10) {
                    // Paused → device keeps recording its own file, but we
                    // skip appending to our buffer or forwarding to ASR so
                    // the saved clip + transcript cover only non-paused
                    // audio. `currentASR` is already nil after `pause()`,
                    // but the guard also short-circuits the buffer append.
                    if self.isPaused { continue }
                    self.streamBuffer.append(frame)
                    self.frames += 1
                    self.bytes += frame.count
                    self.currentASR?.send(frame)
                }
            } catch is CancellationError {
                cancelled = true
            } catch {
                self.error = error.localizedDescription
            }
            if !cancelled {
                await self.handleDeviceStopped(client: client)
            }
        }
    }

    // MARK: - stop

    func stop(client: DnoteClient) async {
        guard isRunning || streamTask != nil || currentASR != nil else { return }
        streamTask?.cancel()
        streamTask = nil

        try? await client.stopStream()
        let stopResult = try? await client.stopRecording()

        commitPartial()
        await closeASR()

        // Snapshot session-local flags BEFORE the detached Task hops — if
        // the user taps mic again quickly, `start()` resets
        // `didPauseDuringSession` to false and the spawned saveAndCleanup
        // would miss the repair branch.
        let hadPauses = didPauseDuringSession
        isRunning = false
        isPaused = false
        deactivateBackgroundAudio()

        // Save + cleanup runs in a fresh top-level Task so SwiftUI-driven
        // cancellation (the Button-action Task that called us dies when
        // `isRunning = false` flips the running-state views) can't abort
        // the device-name resolve, file save, or auto-delete mid-flight.
        Task { [weak self] in
            guard let self else { return }
            await self.saveAndCleanup(client: client, stopResult: stopResult, hadPauses: hadPauses)
        }
    }

    private func handleDeviceStopped(client: DnoteClient) async {
        streamTask = nil
        commitPartial()
        // `closeASR()` clears `error` (it's meant for ASR-link errors on
        // pause / stop). The stream error that brought us here is the one
        // thing the user needs to see, so carry it across.
        let streamError = error
        await closeASR()
        error = streamError
        let hadPauses = didPauseDuringSession
        isRunning = false
        deactivateBackgroundAudio()
        await saveAndCleanup(client: client, stopResult: nil, hadPauses: hadPauses)
    }

    // MARK: - ASR lifecycle

    func switchASR(config: ConfigService) async {
        commitPartial()
        await closeASR()
        do {
            try openASR(config: config)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openASR(config: ConfigService) throws {
        intentionalASRClose = false
        let wantTranslation: Bool
        if let target = targetLang, !target.isEmpty {
            let sourceBase = sourceLang.components(separatedBy: "-").first ?? sourceLang
            let targetBase = target.components(separatedBy: "-").first ?? target
            wantTranslation = targetBase.lowercased() != sourceBase.lowercased()
        } else {
            wantTranslation = false
        }

        if wantTranslation {
            guard let azure = config.config.asrProviders.azure,
                  !azure.key.isEmpty, !azure.region.isEmpty else {
                throw AsrError.azureRequiredForTranslation
            }
            let asr = AzureLiveTranslation(
                key: azure.key, region: azure.region,
                fromLang: sourceLang, toLang: targetLang!
            )
            let events = try asr.connect()
            currentASR = .azureTranslate(asr)
            activeProvider = "azure"
            currentASRProducedResult = false
            runEventLoop(translation: events)
        } else {
            let defaults = config.config.defaults.asr
            var chain = [defaults.primary]
            for fb in defaults.fallbacks where fb != defaults.primary {
                chain.append(fb)
            }
            for name in chain where !deadASRProviders.contains(name.lowercased()) {
                switch name.lowercased() {
                case "azure":
                    if let azure = config.config.asrProviders.azure,
                       !azure.key.isEmpty, !azure.region.isEmpty {
                        let asr = AzureLiveASR(key: azure.key, region: azure.region, lang: sourceLang)
                        let events = try asr.connect()
                        currentASR = .azure(asr)
                        activeProvider = "azure"
                        currentASRProducedResult = false
                        runEventLoop(azure: events)
                        return
                    }
                case "local":
                    if let local = config.config.asrProviders.local,
                       !local.host.isEmpty, local.port > 0 {
                        let asr = LiveStreamASR(host: local.host, port: local.port)
                        let events = try asr.connect()
                        currentASR = .local(asr)
                        activeProvider = "local"
                        currentASRProducedResult = false
                        runEventLoop(local: events)
                        return
                    }
                default:
                    break
                }
            }
            if deadASRProviders.isEmpty {
                throw AsrError.noProviderConfigured
            }
            throw AsrError.allProvidersUnreachable
        }
    }

    private func closeASR() async {
        intentionalASRClose = true
        currentASR?.close()
        currentASR = nil
        await eventTask?.value
        eventTask = nil
        wsConnected = false
        partialText = ""
        partialTranslation = ""
        error = nil
    }

    private func commitPartial() {
        guard !partialText.isEmpty else { return }
        let translation = partialTranslation.isEmpty ? nil : partialTranslation
        finalSegments.append(LiveSegment(text: partialText, translation: translation, timestamp: capturedDuration))
    }

    /// Seconds of audio actually captured into `streamBuffer`. Used as the
    /// transcript timestamp instead of wall-clock so paused gaps don't
    /// desync the transcript from the saved clip.
    private var capturedDuration: TimeInterval {
        Double(bytes / OpusOgg.frameSize) * 0.02
    }

    // MARK: - event loops

    /// Handle an ASR WebSocket close. An intentional teardown (pause/stop/
    /// switch, flagged by `closeASR`) just clears state. An unexpected drop —
    /// a 30s-silence receive timeout (ddxrq1r) or a mid-session disconnect
    /// (m7pyzth) — reopens the ASR over a bounded backoff while the session is
    /// still live. The BLE audio stream keeps running throughout: the stream
    /// task forwards each frame to `currentASR`, so a freshly reopened socket
    /// resumes transcription automatically with only the reconnect gap lost.
    private func handleASRClosed(_ e: Error?) {
        wsConnected = false
        currentASR = nil

        if intentionalASRClose { return }
        guard isRunning, !isPaused else { return }

        // A link that closed without ever producing a result is a dead
        // provider, not a flaky one. Cross it off and fall through to the
        // next configured service — file transcription has had this
        // primary→fallback chain all along; live never did.
        if !currentASRProducedResult, !activeProvider.isEmpty {
            deadASRProviders.insert(activeProvider.lowercased())
            log.warning("ASR provider \(self.activeProvider, privacy: .public) produced nothing before closing — trying the next one")
            asrReconnectAttempts = 0
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, !self.isPaused,
                      self.currentASR == nil, let config = self.config else { return }
                do {
                    try self.openASR(config: config)
                } catch {
                    self.error = error.localizedDescription
                }
            }
            return
        }

        guard asrReconnectAttempts < maxASRReconnects else {
            error = "ASR disconnected: \(e?.localizedDescription ?? "reconnect failed")"
            return
        }
        asrReconnectAttempts += 1
        let attempt = asrReconnectAttempts
        log.info("ASR closed unexpectedly; reconnecting (attempt \(attempt, privacy: .public)/\(self.maxASRReconnects, privacy: .public))")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(attempt, 3)) * 1_000_000_000)
            guard let self, self.isRunning, !self.isPaused,
                  self.currentASR == nil, let config = self.config else { return }
            do {
                try self.openASR(config: config)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// A delivered result proves the (possibly just-reconnected) link works, so
    /// give the next unexpected drop a fresh reconnect budget.
    private func noteASRResult() {
        asrReconnectAttempts = 0
        // The first delivered result is the earliest point at which the
        // link is *proven* — `connect()` returning only means the socket
        // was opened, and the UI used to flip to "connected" right there,
        // even when auth was about to be rejected.
        currentASRProducedResult = true
        wsConnected = true
    }

    private func runEventLoop(local events: AsyncStream<LiveStreamASR.Event>) {
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                switch event {
                case .partial(let t):
                    self.noteASRResult()
                    self.partialText = t
                case .final(let t):
                    if !t.isEmpty {
                        let ts = self.capturedDuration
                        self.finalSegments.append(LiveSegment(text: t, translation: nil, timestamp: ts))
                    }
                    self.partialText = ""
                case .closed(let e):
                    self.handleASRClosed(e)
                }
            }
        }
    }

    private func runEventLoop(azure events: AsyncStream<AzureLiveASR.Event>) {
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                switch event {
                case .partial(let t):
                    self.noteASRResult()
                    self.partialText = t
                case .final(let t):
                    if !t.isEmpty {
                        let ts = self.capturedDuration
                        self.finalSegments.append(LiveSegment(text: t, translation: nil, timestamp: ts))
                    }
                    self.partialText = ""
                case .closed(let e):
                    self.handleASRClosed(e)
                }
            }
        }
    }

    private func runEventLoop(translation events: AsyncStream<AzureLiveTranslation.Event>) {
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                switch event {
                case .partial(let bi):
                    self.noteASRResult()
                    self.partialText = bi.source
                    self.partialTranslation = bi.translation
                case .final(let bi):
                    if !bi.source.isEmpty || !bi.translation.isEmpty {
                        let ts = self.capturedDuration
                        self.finalSegments.append(LiveSegment(
                            text: bi.source, translation: bi.translation, timestamp: ts))
                    }
                    self.partialText = ""
                    self.partialTranslation = ""
                case .closed(let e):
                    self.handleASRClosed(e)
                }
            }
        }
    }

    // MARK: - repair (replace paused-gap iOS clip with full device file)

    /// Download the complete recording over BLE and overwrite the incomplete
    /// live clip. Transcript files are left alone — they're still accurate
    /// for the non-paused portions the user saw during the live session; the
    /// user can re-transcribe from Clip Detail if they want full coverage.
    ///
    /// `repair` is passed explicitly rather than read from `self.pendingRepair`
    /// because the alert's `isPresented` binding clears `pendingRepair` on
    /// dismiss — by the time our Task runs, the property is already nil.
    func repair(client: DnoteClient, repair: PendingRepair) async {
        pendingRepair = nil
        repairState = .downloading(received: 0, total: max(repair.expectedSize, 1))
        let chachaKey = KeyResolver.key(for: client)
        let autoDelete = config?.config.autoDeleteAfterTransfer ?? true
        do {
            let data = try await client.downloadFile(
                repair.deviceFileName,
                expectedSize: repair.expectedSize
            ) { [weak self] got, total in
                self?.repairState = .downloading(received: got, total: max(total, got))
            }
            let outcome = try PostDownload.process(
                data,
                name: repair.iosClipName,
                chacha20Key: chachaKey
            )
            // "Repaired" has to mean a playable file came out, so the outcome
            // has to be checked: discarded, an encrypted device file with no key
            // on this phone reports success — and the branch below then deletes
            // the device's only complete copy.
            guard case .ready = outcome else {
                log.warning("repair \(repair.deviceFileName, privacy: .public): not playable — keeping the device original")
                repairState = .failed(L10n.Live.repairNotPlayable)
                return
            }
            library?.recordDownload(name: repair.iosClipName, size: data.count, transport: "ble")
            log.info("repaired live clip \(repair.iosClipName, privacy: .public) from device file \(repair.deviceFileName, privacy: .public) (\(data.count) bytes)")
            if autoDelete {
                try? await client.deleteFile(repair.deviceFileName)
            }
            repairState = .succeeded
        } catch {
            log.warning("repair failed: \(String(describing: error), privacy: .public)")
            repairState = .failed(error.localizedDescription)
        }
    }

    /// User chose to keep the (incomplete) iOS clip. The device's file is
    /// then the **only** complete copy of this recording, so it stays put —
    /// this used to honour "delete after transfer" and delete it, which
    /// destroyed the very audio the prompt was offering.
    func declineRepair(client: DnoteClient, repair: PendingRepair) async {
        pendingRepair = nil
        log.info("repair declined — keeping device file \(repair.deviceFileName, privacy: .public)")
    }

    func dismissRepairState() {
        repairState = .idle
    }

    /// Fallback for when stopRecording doesn't echo the device file name.
    ///
    /// Identity comes from the pre-session snapshot taken in `start()`, not
    /// from a guess: this session's file is the one that **wasn't on the
    /// device before** (normal start), or — when we attached to a recording
    /// already in progress — the one that **grew** while we were streaming.
    /// If neither is unambiguous the caller gets `nil` and offers a manual
    /// transfer. A "newest name above a size floor" rule is not safe here: it
    /// can pick an unrelated older recording, which the repair flow then
    /// overwrites and deletes.
    ///
    /// Retries up to 3 times: right after stop, `RecordingsView` also
    /// triggers a `getFileList` on the recording-state falling edge, and
    /// the two callers racing through `runExclusive` plus the late-arriving
    /// 0x56/0x50 status frames from the device can stall our first attempt
    /// with a `CancellationError`. A fresh attempt after a short delay
    /// picks up cleanly once the respQueue has settled.
    private func resolveLatestDeviceFile(client: DnoteClient) async -> (name: String?, size: Int) {
        guard let before = preSessionFiles else {
            log.warning("resolveLatestDeviceFile: no pre-session snapshot — refusing to guess")
            return (nil, 0)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for attempt in 0..<3 {
            do {
                let files = try await client.getFileList().filter { !$0.name.isEmpty }

                let fresh = files.filter { before[$0.name] == nil }
                if fresh.count == 1, let only = fresh.first {
                    return (only.name, only.size)
                }
                if fresh.count > 1 {
                    // More than one file appeared (e.g. the device rotated
                    // mid-session). Newest-by-name among *new* files is still
                    // an identified candidate, not a blind guess.
                    if let newest = fresh.max(by: { $0.name < $1.name }) {
                        log.info("resolveLatestDeviceFile: \(fresh.count) new files, taking newest \(newest.name, privacy: .public)")
                        return (newest.name, newest.size)
                    }
                }

                // Attached to an in-progress recording: no new file appears,
                // the existing one just gets bigger.
                if attachedToExistingRecording {
                    let grown = files.filter { f in
                        guard let old = before[f.name] else { return false }
                        return f.size > old
                    }
                    if grown.count == 1, let only = grown.first {
                        return (only.name, only.size)
                    }
                    log.warning("resolveLatestDeviceFile: attach session matched \(grown.count) grown files — not identifiable")
                    return (nil, 0)
                }

                log.warning("resolveLatestDeviceFile attempt \(attempt + 1): no new file among \(files.count) listed")
                return (nil, 0)
            } catch {
                log.warning("resolveLatestDeviceFile attempt \(attempt + 1) failed: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        return (nil, 0)
    }

    // MARK: - save

    private func saveAndCleanup(client: DnoteClient, stopResult: [String: Any]?, hadPauses: Bool) async {
        let buffer = streamBuffer
        var segments = finalSegments
        commitPartial()
        if finalSegments.count > segments.count {
            segments = finalSegments
        }
        let provider = activeProvider
        let autoDelete = config?.config.autoDeleteAfterTransfer ?? true
        streamBuffer = Data()
        log.info("saveAndCleanup entry: buffer=\(buffer.count) hadPauses=\(hadPauses) stopResultName=\((stopResult?["name"] as? String) ?? "nil", privacy: .public)")
        guard buffer.count >= OpusOgg.frameSize else {
            log.info("saveAndCleanup: buffer too small (\(buffer.count) bytes), skipping save")
            return
        }

        persistLanguagePreferences()

        // Resolve the device filename up front. Prefer the name that
        // stopRecording's status JSON echoed back; fall back to listing
        // files and picking the newest one. Saving the iOS clip under the
        // device's name is important because the iOS `startedAt` clock and
        // the device's own clock drift by 1-2 seconds, so the timestamp
        // fallback produces `20260422002021.opus` while the device file is
        // `20260422002020.opus`. That name mismatch breaks:
        //   (1) the repair flow's in-place overwrite
        //   (2) auto-delete's direct-name delete path
        // Listing once up front solves both.
        var deviceFileName = (stopResult?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var deviceSize = (stopResult?["size"] as? Int) ?? 0
        if deviceFileName == nil {
            let resolved = await resolveLatestDeviceFile(client: client)
            deviceFileName = resolved.name
            deviceSize = resolved.size
            log.info("saveAndCleanup resolve: name=\(resolved.name ?? "nil", privacy: .public) size=\(resolved.size)")
        }

        let name: String
        if attachedToExistingRecording {
            // The buffer only covers from the attach point. Saving it under
            // the device file's name makes a minutes-long recording show up
            // in Library as a few seconds "truncated" clip. Name it by the
            // attach time instead; the repair prompt below still knows the
            // device file and can replace this clip with the complete one.
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMddHHmmss"
            name = fmt.string(from: startedAt ?? Date()) + ".opus"
        } else if let dfn = deviceFileName {
            name = dfn
        } else {
            // Device didn't echo a name AND getFileList didn't succeed —
            // fall back to startedAt. The iOS clip will have a name that
            // doesn't match any file on the device, but the save itself
            // still works and the user can manage it from Library.
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMddHHmmss"
            name = fmt.string(from: startedAt ?? Date()) + ".opus"
        }

        do {
            _ = try PostDownload.process(buffer, name: name, chacha20Key: nil)
            library?.recordDownload(name: name, size: buffer.count, transport: "stream")
            savedClipName = name
            log.info("saved stream recording: \(name, privacy: .public) (\(buffer.count) bytes)")
        } catch {
            log.error("failed to save stream: \(String(describing: error), privacy: .public)")
            return
        }

        if !segments.isEmpty {
            saveTranscript(segments: segments, audioName: name, provider: provider)
        }

        // If the user paused during the session, the iOS clip is missing
        // audio for the paused intervals. Offer to pull the complete
        // recording from the device instead of deleting it. Even when the
        // resolve fails, skip auto-delete so the user can transfer the
        // file manually from Recordings later.
        if hadPauses {
            if let dfn = deviceFileName {
                pendingRepair = PendingRepair(
                    deviceFileName: dfn,
                    iosClipName: name,
                    expectedSize: deviceSize,
                    wasAttached: attachedToExistingRecording
                )
                log.info("saveAndCleanup: offering repair from device file \(dfn, privacy: .public) size=\(deviceSize)")
            } else {
                log.warning("saveAndCleanup: pauses occurred but device file didn't resolve — showing manual-transfer hint, leaving device file intact")
                repairState = .needsManualTransfer
            }
            return
        }

        guard autoDelete else { return }

        // We know the device file name — delete by name, no duration match
        // heuristic needed. Detached so BLE delete doesn't block the
        // Live-tab UI from transitioning to the next session.
        if let dfn = deviceFileName {
            Task.detached { @MainActor in
                do {
                    try await client.deleteFile(dfn)
                    log.info("deleted device file: \(dfn, privacy: .public)")
                } catch {
                    log.warning("delete \(dfn, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            return
        }

        // Last-ditch cleanup — resolve didn't succeed, fall back to
        // duration match against the file list.
        let streamedBytes = buffer.count
        let lib = library
        Task.detached { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let streamDuration = Double(streamedBytes / OpusOgg.frameSize) * 0.02
            guard streamDuration > 1.0 else { return }
            do {
                let files = try await client.getFileList()
                let match = files
                    .filter { !$0.name.isEmpty }
                    .filter { file in
                        let d = Double(file.size / OpusOgg.frameSize) * 0.02
                        return abs(d - streamDuration) < 10.0
                    }
                    .max(by: { $0.name < $1.name })
                if let match {
                    lib?.recordDownload(name: match.name, size: match.size, transport: "stream")
                    try await client.deleteFile(match.name)
                    log.info("deleted matching device file: \(match.name, privacy: .public)")
                }
            } catch {
                log.warning("device cleanup failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func saveTranscript(segments: [LiveSegment], audioName: String, provider: String) {
        let transcriptURLs = StorageLocations.transcriptURLs(for: audioName)
        let hasTranslations = segments.contains { $0.translation != nil }

        let asrSegments = buildAsrSegments(segments.map { ($0.text, $0.timestamp) })
        let sourceText = segments.map(\.text).joined(separator: "\n")

        do {
            try FileManager.default.createDirectory(
                at: StorageLocations.decryptedDir,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            try sourceText.data(using: .utf8)?.write(to: transcriptURLs.txt, options: .atomic)
            let transcriptResult = AsrResult(
                text: sourceText, segments: asrSegments,
                provider: provider, locale: sourceLang
            )
            try encoder.encode(transcriptResult).write(to: transcriptURLs.json, options: .atomic)

            if hasTranslations {
                let translationURLs = StorageLocations.translationURLs(for: audioName)
                let translatedSegments = segments.filter { $0.translation != nil }
                let translatedText = translatedSegments.map { $0.translation! }.joined(separator: "\n")
                let translatedAsrSegments = buildAsrSegments(
                    translatedSegments.map { ($0.translation!, $0.timestamp) }
                )
                let targetLocale = targetLang ?? sourceLang

                try translatedText.data(using: .utf8)?.write(to: translationURLs.txt, options: .atomic)
                let translationResult = AsrResult(
                    text: translatedText, segments: translatedAsrSegments,
                    provider: "\(provider)-translate", locale: targetLocale
                )
                try encoder.encode(translationResult).write(to: translationURLs.json, options: .atomic)
                log.info("saved transcript + translation for \(audioName, privacy: .public)")
            } else {
                log.info("saved transcript: \(transcriptURLs.txt.lastPathComponent, privacy: .public)")
            }
        } catch {
            log.warning("failed to save transcript: \(String(describing: error), privacy: .public)")
        }
    }

    private func buildAsrSegments(_ items: [(text: String, timestamp: TimeInterval)]) -> [AsrSegment] {
        items.enumerated().map { i, item in
            let start = i > 0 ? items[i - 1].timestamp : 0
            let end = item.timestamp
            return AsrSegment(
                speaker: nil, text: item.text,
                start: round(start * 10) / 10,
                end: round(end * 10) / 10,
                duration: round((end - start) * 10) / 10
            )
        }
    }

    private func persistLanguagePreferences() {
        guard let config else { return }
        config.config.lastSourceLang = sourceLang
        config.config.lastTargetLang = targetLang
        config.scheduleSave()
    }

    // MARK: - Background keep-alive

    /// Called by LiveView when scenePhase transitions to .background.
    /// Starts a silent looping AVAudioPlayer so iOS keeps the app alive
    /// (audio background mode) and BLE notifications keep firing
    /// (bluetooth-central background mode).
    func sceneDidBackground() {
        guard isRunning else { return }
        activateBackgroundAudio()
    }

    /// Called by LiveView when scenePhase transitions to .active.
    func sceneDidForeground() {
        deactivateBackgroundAudio()
    }

    private func activateBackgroundAudio() {
        guard silentPlayer == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: silentWavData(), fileTypeHint: AVFileType.wav.rawValue)
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            silentPlayer = player
            observeInterruptions()
            log.info("background audio: activated")
        } catch {
            log.warning("background audio: activate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivateBackgroundAudio() {
        guard silentPlayer != nil else { return }
        silentPlayer?.stop()
        silentPlayer = nil
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log.info("background audio: deactivated")
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.ended.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.silentPlayer == nil else { return }
                self.activateBackgroundAudio()
            }
        }
    }

    // 1 second of silence: 8 kHz mono 16-bit PCM WAV (16 044 bytes).
    // Tiny enough to keep in memory; looped so it never stops.
    private func silentWavData() -> Data {
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = sampleRate
        let dataSize = numSamples * 2
        var d = Data()
        func u32le(_ v: UInt32) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func u16le(_ v: UInt16) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        d.append(contentsOf: [0x52,0x49,0x46,0x46]) // "RIFF"
        u32le(36 + dataSize)
        d.append(contentsOf: [0x57,0x41,0x56,0x45]) // "WAVE"
        d.append(contentsOf: [0x66,0x6D,0x74,0x20]) // "fmt "
        u32le(16); u16le(1); u16le(1)                // PCM, mono
        u32le(sampleRate); u32le(sampleRate * 2)     // sample rate, byte rate
        u16le(2); u16le(16)                          // block align, bits/sample
        d.append(contentsOf: [0x64,0x61,0x74,0x61]) // "data"
        u32le(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
