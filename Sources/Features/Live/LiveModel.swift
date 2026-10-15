import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "live")

/// One committed line of the live transcript.
///
/// ★ 2026-10-14: added `id`, `translation` changed from `let` to `var`.
///
/// Why it must be editable in place: on the local ASR path, translation is **asynchronously supplemented afterwards**
/// (using `LLMCompletionService`, each call takes several seconds), by the time the result returns this line has already been placed in
/// `finalSegments`. It can only be back‑filled by `id`, not deleted and re‑inserted — re‑insertion would cause the already
/// scrolled‑up list to jump, and would also disrupt array order (order is the timeline).
struct LiveSegment: Equatable, Identifiable {
    let id: UUID
    let text: String
    var translation: String?
    let timestamp: TimeInterval

    init(id: UUID = UUID(), text: String, translation: String? = nil,
         timestamp: TimeInterval) {
        self.id = id
        self.text = text
        self.translation = translation
        self.timestamp = timestamp
    }
}

enum LiveStartError: LocalizedError {
    /// Device is recording but has real-time upload off for this clip, so
    /// `CMD 0x68` would produce nothing.
    case deviceNotUploading
    /// When trying to take over, the device is **not recording at all** (TicNote). This line differs from the one above:
    /// The above is "recording, but this one fails to record", here it is "there is simply nothing to connect to".
    case deviceNotRecording
    /// The device did not report any session ID, candidate ladder (`0x14`/`0x17` → clock restore → wall clock)
    /// None can be assembled — at this point **no valid sid to send fragment request**, can only report early.
    case noSessionID

    var errorDescription: String? {
        switch self {
        case .deviceNotUploading: return L10n.Live.attachNoUpload
        case .deviceNotRecording: return L10n.Live.attachNotRecording
        case .noSessionID:        return L10n.Live.noSessionID
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

    /// Translation channel **soft** alert (2026-10-14).
    ///
    /// Why create a separate field instead of reusing `error`: `error` in `LiveView` would replace **the entire
    /// content with an error page**. And "translation missing" should not cause the user to lose the ongoing transcription —
    /// the transcription itself is fine, the user just misses half the content. Therefore this entry only provides a single-line hint.
    @Published var translationNotice: String?
    @Published var savedClipName: String?
    @Published var targetLangName: String = ""
    @Published var pendingRepair: PendingRepair?
    @Published var repairState: RepairState = .idle
    /// Set when `start()` couldn't establish whether the device is already
    /// recording. The view turns this into a confirmation — starting blind
    /// can cut off a recording the user began with the physical button.
    @Published var pendingStartConfirm = false

    /// `start()`'s **re‑entrancy gate** (2026-10-12).
    ///
    /// Previously there was only `guard !isRunning`, but "already running" and "starting" are two different states:
    /// During startup `isRunning` remains `false` (it is set only after `liveStartNew()` /
    /// `liveAttach()` succeeds), so a second tap can re‑enter —
    /// and the statement at the function start `pendingStartConfirm = false` will close the **just‑shown**
    /// confirmation dialog itself. The user sees "tap record, the dialog flashes and disappears".
    ///
    /// This entry **does not depend** on any device protocol assumptions; it is purely a concurrency safeguard.
    private var isStarting = false

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

        /// Device‑side file's **protocol‑agnostic handle**.
        ///
        /// ★ Why we cannot keep only `deviceFileName`: D·NOTE can read/delete by filename,
        /// but the TicNote card entry **has no name at all** (`0x1A` provides only sid + size + scene),
        /// the name is generated by us from the sid. To actually read/delete, we must include `sessionID`.
        /// `nil` = legacy path (name only), in this case `liveFetch`/`liveDelete` are not used.
        var deviceFile: LiveDeviceFile?

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

    // MARK: - Local real-time translation (★ Added 2026-10-14)

    /// Target language **readable name** (e.g., "Chinese (Simplified)"), used directly as LLM prompt.
    /// `nil` = this session does not perform translation (user did not select a target language, or target language == source language, or LLM not configured).
    private var translateTo: String?
    /// Queue of ids for final segments awaiting translation. **Must preserve order** — order is the timeline,
    /// Out‑of‑order back‑fill would attach translations next to the wrong sentences.
    private var translateFinals: [UUID] = []
    /// The segment currently being translated (flush uses it to determine if there are still pending tasks).
    private var translateInFlight: UUID?
    /// The most recent pending partial. **Only keep the latest** — partials keep scrolling,
    /// Translating an older one is pure waste (the local 3B model takes several seconds per request).
    private var translatePartial: String?
    /// The previously translated partial text, used to skip duplicates (the server may repeatedly emit the same sentence).
    private var lastPartialTranslated = ""
    /// Timestamp of the last emitted partial translation, used for throttling.
    private var lastPartialTranslateAt: Date?
    /// Serial translation pump. **Runs only one at a time**: the local model on CPU would slow each other down if two requests run concurrently.
    private var translatePump: Task<Void, Never>?
    /// Backlog alert **reported only once**, to avoid log flooding (reset after queue is cleared).
    ///
    /// Why report this: the local 3B model takes several seconds per translation on CPU, while speech is continuous —
    /// When speaking speed exceeds model speed, `translateFinals` will **continuously grow**, and the translation falls further behind.
    /// This is not a bug (no content loss), but during troubleshooting it must be immediately visible in the logs.
    private var didWarnTranslationBacklog = false

    /// At least this much time must elapse between partials before translating again.
    ///
    /// ⚠️ Here we deliberately use **throttling** instead of debounce "wait for stable text before translating": during speech the partial window
    ///    keeps expanding, text keeps changing, debounce would never meet the condition ⇒ **no partial gets translated**.
    private static let partialTranslateMinInterval: TimeInterval = 2.5

    /// At the end, wait for the upper limit of unfinished translations. Better to miss two segments than to block "stop" —
    /// The local CPU running the 3B model may take several seconds per segment when slow.
    private static let translationFlushTimeout: TimeInterval = 8

    /// When pending final translations reach this count, log a warning (**no content loss**, just a reminder that translations will lag).
    ///
    /// Why not set a limit and drop directly: dropped segments **can never be recovered**, the saved `.txt` will contain
    /// a gap of "original text only"; lag is merely slow. Users can rely on the scrolling partial translations
    /// (which bypass this queue) to see "what is being said now", so they prefer "slow" over "missing".
    private static let translationBacklogWarnThreshold = 10

    /// Audio source for this session (D·NOTE or TicNote).
    ///
    /// ★ This is the handle that decouples the entire real‑time chain from the device in this round — before this,
    /// `LiveModel` directly consumed `DnoteClient`, so TicNote wanting to connect required modifying
    /// `LiveModel` / `LiveView` together. See the documentation of `LiveAudioSource`.
    private var activeSource: (any LiveAudioSource)?

    /// Opus packet shape for this session. **Must match `activeSource.opusProfile`** —
    /// It determines the duration conversion "bytes per second" (used in `capturedDuration` /
    /// `durationLabel` / `saveAndCleanup`), and also dictates how many bytes per packet when saving.
    ///
    /// D·NOTE 40 B mono / TicNote 160 B stereo: **incorrect transmission does not error**,
    /// it only causes a 4× duration discrepancy, slicing the 160‑byte stream into four fake frames of 40 B. Therefore it is not filled in by the caller
    /// but copied from `source.opusProfile` inside `start`.
    private var opusProfile: OpusOgg.Profile = .dnote

    /// True while `closeASR()` is tearing the WebSocket down on purpose
    /// (pause / stop / provider switch), so the resulting `.closed` event is
    /// not mistaken for a dropped link and does not trigger a reconnect.
    private var intentionalASRClose = false
    /// Bounded reconnect budget for unexpected ASR drops; reset whenever a
    /// result actually arrives (proof the link is working again).
    private var asrReconnectAttempts = 0
    private let maxASRReconnects = 5

    private var streamBuffer = Data()

    /// ★ 2026-10-12: raw bytes of the previous session **not yet saved** + the stop‑recording result of that time.
    ///
    /// ## Why keep a copy
    /// `saveAndCleanup` previously cleared `streamBuffer` as soon as it entered (`streamBuffer = Data()`),
    /// so after an "auto‑save failure" there was **no second chance** — the buffer was gone,
    /// and the device copy might have already been auto‑deleted. The user could only watch the audio disappear.
    /// Keeping it allows the "**Save to Library**" button in `LiveView` to have something to store.
    ///
    /// Lifecycle: write on stop‑recording → clear on successful save → otherwise keep until the user retries.
    private var pendingSaveBuffer = Data()
    private var pendingStopOutcome: LiveStopOutcome?

    /// Is there now an audio segment **that can be manually saved to the library**?
    ///
    /// ⚠️ The condition includes `>= opusProfile.packetBytes` (instead of merely checking "non‑empty"):
    /// A half‑packet cannot form a valid Ogg, so `saveAndCleanup` will abort at the start —
    /// In that situation **a button that is guaranteed to fail should not be presented**. Better to have no button,
    /// than a button that "does nothing when clicked" (the experience we aim to fix).
    var canSaveToLibrary: Bool {
        savedClipName == nil && !isRunning
            && pendingSaveBuffer.count >= opusProfile.packetBytes
    }
    private var library: Library?
    private var config: ConfigService?

    private var silentPlayer: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?

    var statusText: String {
        if isPaused { return L10n.Live.paused }
        return isRunning ? L10n.Live.streaming : L10n.Live.ready
    }

    var durationLabel: String {
        // ⚠️ `opusProfile.packetBytes` cannot be hard‑coded to 40 — TicNote packets are 160 B,
        //    If hard‑coded, the same byte count would be displayed as **4×** the duration.
        let secs = Int(Double(bytes / opusProfile.packetBytes) * 0.02)
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // MARK: - start

    /// `assumeIdle` is only set by the "start anyway" branch of the
    /// unknown-state confirmation below. Everything else leaves it false.
    func start(source: any LiveAudioSource,
               config: ConfigService,
               library: Library,
               assumeIdle: Bool = false) async {
        guard !isRunning else { return }
        // ★ See the comment on `isStarting`: keep "starting" out of reach, otherwise overlapping second
        //   calls will clear `pendingStartConfirm` at the function start, causing the confirmation dialog to flash and disappear.
        guard !isStarting else {
            log.warning("start: already starting — ignoring the overlapping call")
            return
        }
        isStarting = true
        defer { isStarting = false }
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
        // ★ Duration conversion baseline: **each step reads values from the profile provided by the protocol**,
        //   Never hard‑code 40 / 160 anywhere below — that is exactly why "TicNote's 5‑minute recording
        //   appears as 20 minutes" (packet length 4×, duration 4×).
        self.activeSource = source
        self.opusProfile = source.opusProfile

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
            if let isRecording = await source.liveIsRecording() {
                alreadyRecording = isRecording
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
            preSessionFiles = await source.liveListFiles()?
                .reduce(into: [String: Int]()) { $0[$1.name] = $1.size }
            if preSessionFiles == nil {
                log.warning("start: pre-session file snapshot failed — repair will fall back to manual transfer")
            }

            if alreadyRecording {
                // iOS captured audio only covers from the attach point,
                // so the saved clip will be shorter than the device file.
                // Reuse the pause-repair path so stop offers to replace
                // the iOS clip with the device's complete recording.
                //
                // ⚠️ For TicNote this step also includes one more task: **ensure we can obtain a sid**.
                //    D·NOTE is "push" (device streams proactively, no sid involved),
                //    TicNote is "pull" (we must acquire a sid to send `0x1C`).
                //    Without a sid there is nothing to pull, and `liveAttach` will throw an error immediately —
                //    This is far better than making the user wait for a timeout while seeing "listening…".
                didPauseDuringSession = true
                attachedToExistingRecording = true
                log.info("start: attaching to existing device recording")
                try await source.liveAttach()
            } else {
                try await source.liveStartNew()
            }
            startedAt = Date()
            isRunning = true
            spawnStreamTask(source: source)
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

    private func spawnStreamTask(source: any LiveAudioSource) {
        streamTask = Task { [weak self] in
            guard let self else { return }
            var cancelled = false
            do {
                // 10 s is generous for a device that is pushing at all
                // (frames come every 20 ms); the default 30 s is for gaps
                // mid-session, not for the first packet.
                //
                // ⚠️ Each `Data` obtained here is a **full packet** (length = `source.opusProfile.packetBytes`).
                //    This contract is handled by `LiveAudioSource.liveAudio`: D·NOTE frames are packets themselves
                //    (40 B), TicNote's `0x02` frames are only 80 B, **one packet spans two frames**,
                //    so they are assembled in `TicNoteLivePump` before being emitted.
                //    Downstream (`streamBuffer` / ASR) therefore does not need to know which device type is used.
                for try await frame in source.liveAudio(firstFrameTimeout: 10) {
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
                await self.handleDeviceStopped(source: source)
            }
        }
    }

    // MARK: - stop

    func stop(source: any LiveAudioSource) async {
        guard isRunning || streamTask != nil || currentASR != nil else { return }
        streamTask?.cancel()
        streamTask = nil

        // ★ TicNote's "stop" does two extra things compared to D·NOTE, both in `liveStop()`:
        //   ① First stop the pull‑stream loop, then send the stop‑recording frame — otherwise the card's segment hasn't finished writing,
        //      our final piece would never receive an end‑of‑file;
        //   ② After stopping, verify the **actual** size of the card's segment (`0x17` fileSize / `0x1A` list),
        //      because "how much we pulled" and "how much is stored on the card" are **two distinct numbers** in real‑time pulling,
        //      (we might have pressed stop immediately after starting, pulling only 0 bytes).
        let outcome = await source.liveStop()

        commitPartial()
        await closeASR()

        // Snapshot session-local flags BEFORE the detached Task hops — if
        // the user taps mic again quickly, `start()` resets
        // `didPauseDuringSession` to false and the spawned saveAndCleanup
        // would miss the repair branch.
        let hadPauses = didPauseDuringSession
        // ★ Snapshot must be taken **before** `isRunning = false`: that line triggers an immediate UI redraw,
        //   and during redraw `canSaveToLibrary` must instantly answer "is there something to save" —
        //   delaying one step would cause the button to flash and disappear, giving the impression of a failure.
        let buffer = streamBuffer
        pendingSaveBuffer = buffer
        pendingStopOutcome = outcome
        isRunning = false
        isPaused = false
        deactivateBackgroundAudio()

        // Save + cleanup runs in a fresh top-level Task so SwiftUI-driven
        // cancellation (the Button-action Task that called us dies when
        // `isRunning = false` flips the running-state views) can't abort
        // the device-name resolve, file save, or auto-delete mid-flight.
        Task { [weak self] in
            guard let self else { return }
            await self.saveAndCleanup(source: source, stop: outcome,
                                      buffer: buffer, hadPauses: hadPauses)
        }
    }

    /// User tapped "**Save to Library**".
    ///
    /// ## Why this exists (2026-10-12, user quote)
    /// > "After ending the current real‑time transcription, a button to save to the library is needed"
    ///
    /// When stopping recording, an automatic save (`saveAndCleanup`) is performed. However that path may not complete:
    /// Insufficient buffer for a packet, `liveContainerize` throws, `PostDownload` fails —
    /// and at that moment **the buffer has already been cleared**, leaving the user no chance to recover, only an error message on the UI.
    /// Now the bytes remain in `pendingSaveBuffer`, and this button simply **retries that save once, unchanged**.
    ///
    /// - Returns: the filename after saving; `nil` = nothing to save, or another failure occurred.
    @discardableResult
    func saveToLibrary(source: any LiveAudioSource) async -> String? {
        if let saved = savedClipName { return saved }
        // ⚠️ The message for `log.info` is an `OSLogMessage` (interpolation is evaluated in an escaping context),
        //    so property references inside interpolation must be prefixed with `self.` — omitting it results in
        //    the three compile errors "requires explicit use of 'self'".
        guard !isRunning,
              pendingSaveBuffer.count >= opusProfile.packetBytes,
              let stop = pendingStopOutcome else {
            log.info("saveToLibrary: No bytes pending for disk write (saved=\(self.savedClipName ?? "nil", privacy: .public) pending=\(self.pendingSaveBuffer.count))")
            return nil
        }
        log.info("saveToLibrary: manual retry save \(self.pendingSaveBuffer.count) B")
        // `hadPauses` passed as false: this path does not provide a "pause gap" repair hint ——
        // The user wants to "save the already pulled segment to the library", not to trigger another series of dialogs.
        await saveAndCleanup(source: source, stop: stop,
                             buffer: pendingSaveBuffer, hadPauses: false)
        return savedClipName
    }

    private func handleDeviceStopped(source: any LiveAudioSource) async {
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
        // The device **itself** stopped (not by us): `liveStop` will ask again on this path
        // "what is the actual size on the card", and send the stop‑recording frame (idempotent).
        let outcome = await source.liveStop()
        let buffer = streamBuffer
        pendingSaveBuffer = buffer
        pendingStopOutcome = outcome
        await saveAndCleanup(source: source, stop: outcome,
                             buffer: buffer, hadPauses: hadPauses)
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

    /// Whether this session requires translation (target language selected and differs from source language).
    private func shouldTranslate() -> Bool {
        guard let target = targetLang, !target.isEmpty else { return false }
        let sourceBase = sourceLang.components(separatedBy: "-").first ?? sourceLang
        let targetBase = target.components(separatedBy: "-").first ?? target
        return targetBase.lowercased() != sourceBase.lowercased()
    }

    /// Write key real‑time translation events into **saved** diagnostics (`Documents/ticnote-ble.log`).
    ///
    /// Why write to disk instead of just using `Logger`:
    ///   * On macOS, `/usr/bin/log` is **blocked by the sandbox** (`log: Cannot run while
    ///     sandboxed`), and `dangerouslyDisableSandbox` doesn't help either ⇒ the path of
    ///     `logarchive` is dead;
    ///   * `pymobiledevice3 syslog live` connects, but the lines received **do not show
    ///     custom subsystems** (in practice only framework names like `UIKitCore`),
    ///     and it's uncertain whether `log.info` will appear in the relay.
    ///
    /// And whether a "translation was actually produced, and which path it took" **must be verifiable** ——
    /// The file on disk can definitely be pulled using `devicectl copy from`, and is not subject to the above two restrictions.
    ///
    /// ⚠️ Bounded: `TicNoteDiagLog` auto-scrolls when exceeding 512 KB, and only appends without blocking the caller.
    ///
    /// ⚠️ Use the `XLATE` tag instead of `LIVE`: the `LIVE` tag **is already occupied by the real-time streaming path**
    ///    (e.g., `LIVE stream stopped: sid=… we pulled …`), mixing them makes log reading harder to parse.
    private func diagLive(_ text: String) {
        TicNoteDiagLog.log("XLATE", text)
    }

    private func openASR(config: ConfigService) throws {
        intentionalASRClose = false
        let wantTranslation = shouldTranslate()
        let azure = config.config.asrProviders.azure
        let azureUsable = !(azure?.key.isEmpty ?? true) && !(azure?.region.isEmpty ?? true)
        diagLive("openASR wantTranslate=\(wantTranslation) azureUsable=\(azureUsable) src=\(sourceLang) tgt=\(targetLang ?? "-") profile=\(opusProfile.packetBytes)B")

        if wantTranslation, azureUsable, let azure {
            // ★★ The preferred option remains Azure real-time translation: the source and translated text **return together in the same stream**,
            //    with the lowest latency and no need for local compute power. This path is consistent with the previous word-by-word approach.
            endLiveTranslation()
            let asr = AzureLiveTranslation(
                key: azure.key, region: azure.region,
                fromLang: sourceLang, toLang: targetLang!,
                // ★ The packet shape of this session must be carried through: Azure must buffer frames into
                //   `framesPerPage` pages of Ogg before sending (`audio/ogg;codecs=opus`),
                //   where the page table is split by **packet length**. The default `.dnote` (40 B) causes TicNote's
                //   160 B stream to be split into 4 fake frames —— the remote side won't error, but will output noise.
                profile: opusProfile
            )
            let events = try asr.connect()
            currentASR = .azureTranslate(asr)
            activeProvider = "azure"
            currentASRProducedResult = false
            diagLive("provider=azureTranslate (original and translation in the same stream)")
            runEventLoop(translation: events)
            return
        }

        // ★★ Reached here: no translation needed, **or** no Azure but translation is desired.
        //
        // // ★★ Reached here: no translation needed, **or** no Azure but translation is required.
        // //
        // // Before 2026-10-14, the latter case would **directly throw `azureRequiredForTranslation`**,
        // // causing the "local ASR + wants translation" combination to fail to start the real-time session in the UI.
        if wantTranslation {
            beginLiveTranslation(config: config)
        } else {
            endLiveTranslation()
        }

        let defaults = config.config.defaults.asr
        var chain = [defaults.primary]
        for fb in defaults.fallbacks where fb != defaults.primary {
            chain.append(fb)
        }
        for name in chain where !deadASRProviders.contains(name.lowercased()) {
            switch name.lowercased() {
            case "azure":
                if azureUsable, let azure {
                    let asr = AzureLiveASR(key: azure.key, region: azure.region,
                                           lang: sourceLang, profile: opusProfile)
                    let events = try asr.connect()
                    currentASR = .azure(asr)
                    activeProvider = "azure"
                    currentASRProducedResult = false
                    diagLive("provider=azure(transcription only)")
                    runEventLoop(azure: events)
                    return
                }
            case "local":
                if let local = config.config.asrProviders.local,
                   !local.host.isEmpty, local.port > 0 {
                    // ⚠️ The local server provides a **raw byte stream** (`/v1/listen`, no container),
                    //    so it can only frame by "fixed packet length" — thus the profile here is
                    //    more critical than Azure's: sending the wrong length misaligns all subsequent packets.
                    let asr = LiveStreamASR(host: local.host, port: local.port,
                                            profile: opusProfile)
                    let events = try asr.connect()
                    currentASR = .local(asr)
                    activeProvider = "local"
                    currentASRProducedResult = false
                    diagLive("provider=local ws://\(local.host):\(local.port)/v1/listen")
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

    private func closeASR() async {
        intentionalASRClose = true
        currentASR?.close()
        currentASR = nil
        await eventTask?.value
        eventTask = nil
        wsConnected = false
        partialText = ""
        partialTranslation = ""
        // The trailing partial is no longer meaningful —— but **do not** stop the translation pump here:
        // The enqueued final translation still needs it to be persisted in `saveAndCleanup` (which has a flush).
        translatePartial = nil
        lastPartialTranslated = ""
        error = nil
    }

    private func commitPartial() {
        guard !partialText.isEmpty else { return }
        let translation = partialTranslation.isEmpty ? nil : partialTranslation
        let segment = LiveSegment(text: partialText, translation: translation,
                                  timestamp: capturedDuration)
        finalSegments.append(segment)
        // ★ This line must also be added to the translation queue, otherwise **the last sentence will never get a translation** —
        //   partial translations are throttled, so they often haven't been processed by the time we finish.
        if translateTo != nil, translation == nil {
            translateFinals.append(segment.id)
        }
        translatePartial = nil
    }

    /// Seconds of audio actually captured into `streamBuffer`. Used as the
    /// transcript timestamp instead of wall-clock so paused gaps don't
    /// desync the transcript from the saved clip.
    private var capturedDuration: TimeInterval {
        // // Same as above: convert based on `opusProfile`, do not hardcode 40.
        Double(bytes / opusProfile.packetBytes) * 0.02
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
        // The first result back is the earliest point where the link is **proven available** — log a diagnostic line,
        // so we can later distinguish between "connected but no output" and "never connected".
        if !currentASRProducedResult {
            diagLive("ASR first result received provider=\(activeProvider) profile=\(opusProfile.packetBytes)B")
        }
        // The first delivered result is the earliest point at which the
        // link is *proven* — `connect()` returning only means the socket
        // was opened, and the UI used to flip to "connected" right there,
        // even when auth was about to be rejected.
        currentASRProducedResult = true
        wsConnected = true
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

    /// Local ASR event loop — **also the enqueue point for local translation**.
    ///
    /// This is only for "registration"; the actual work is handed off to `translatePump` to process serially. Reason: the event loop must
    /// **return immediately** to receive the next frame, and must never hold up
    /// the audio stream waiting for the LLM (local 3B model, taking several seconds per inference) —— that is precisely the classic cause of "stuttering during playback".
    private func runEventLoop(local events: AsyncStream<LiveStreamASR.Event>) {
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                switch event {
                case .partial(let t):
                    self.noteASRResult()
                    self.partialText = t
                    // Partial only registers the "latest one": it keeps rolling; translating old ones is pure waste.
                    if self.translateTo != nil, !t.isEmpty { self.translatePartial = t }
                case .final(let t):
                    if !t.isEmpty {
                        let ts = self.capturedDuration
                        // ★ 2026-10-14: Grab a translation if available.
                        //
                        // The local 3B model runs on CPU, taking several seconds to translate one line. By the time it returns,
                        // this body text has already scrolled up, so the user sees "original text, no translation".
                        // The partial translation right before this finalized sentence has likely already been translated —
                        // if this sentence continues that translated text (`hasPrefix`), paste that
                        // translation first, and overwrite it when the official translation arrives.
                        //
                        // Why use `hasPrefix` as the criterion: the server progressively extends the window for the same sentence,
                        // the already-translated portion is necessarily a prefix of this sentence. If it doesn't match, it means the previous sentence is mixed in,
                        // better to leave it blank than to paste incorrectly (incorrect pasting is worse than none).
                        var seed: String?
                        if self.translateTo != nil,
                           !self.partialTranslation.isEmpty,
                           !self.lastPartialTranslated.isEmpty,
                           t.hasPrefix(self.lastPartialTranslated) {
                            seed = self.partialTranslation
                        }
                        let segment = LiveSegment(text: t, translation: seed, timestamp: ts)
                        self.finalSegments.append(segment)
                        self.diagLive("asr final#\(self.finalSegments.count) \(String(t.prefix(40))) seed=\(seed != nil)")
                        // Regardless of whether a seed translation was matched, **a formal translation must always be performed** —
                        // The seed is merely "a preliminary placeholder"; it may only be a half-sentence.
                        if self.translateTo != nil { self.translateFinals.append(segment.id) }
                    }
                    self.partialText = ""
                    // This sentence is finalized ⇒ discard the previous sentence's partial translation, so it doesn't hang around
                    // the new source text (read/write desynchronization makes it look like a mistranslation).
                    self.translatePartial = nil
                    self.lastPartialTranslated = ""
                    if self.translateTo != nil { self.partialTranslation = "" }
                case .closed(let e):
                    self.handleASRClosed(e)
                }
            }
        }
    }

    // MARK: - Local real-time translation (★ Added 2026-10-14)

    /// Prepare the local translation channel: parse the target language name and start the serial pump.
    ///
    /// **Idempotent**: On reconnect, `openASR` is called again; if the target language hasn't changed, return as-is —
    /// otherwise the in-flight translations will be lost, and those lines on the UI will never be recovered.
    ///
    /// Source of the target language name: prioritize `targetLangName` (the name `LiveView` retrieves from the MS Translator list, which is the most accurate, e.g., "Chinese (Simplified)"), fall back to the built-in static table if empty,
    /// and if that fails, use the original code — seeing `zh-Hans` is better than having nothing.
    /// 
    private func beginLiveTranslation(config: ConfigService) {
        let code = targetLang ?? ""
        let name = !targetLangName.isEmpty
            ? targetLangName
            : (LanguageService.displayName(for: code) ?? code)

        if translateTo == name, translatePump != nil { return }

        translationFinalsReset()
        partialTranslation = ""

        guard LLMCompletionService.isConfigured(config.config) else {
            // // LLM not configured ⇒ this session **transcribes only**, append a soft warning explaining why no translation is available.
            translateTo = nil
            stopTranslatePump()
            translationNotice = L10n.Live.translateUnavailable
            log.info("live translation requested but no LLM provider is configured")
            diagLive("✗ No available LLM provider ⇒ transcript only (primary=\(config.config.llmProviders.primary ?? "-")")
            return
        }
        guard !name.isEmpty else {
            translateTo = nil
            stopTranslatePump()
            diagLive("✗ Target language name is empty ⇒ No translation")
            return
        }
        translateTo = name
        translationNotice = nil
        startTranslatePump()
        log.info("live translation via LLM into \(name, privacy: .public)")
        diagLive("✓ Translation channel started target=\(name) llm=\(config.config.llmProviders.primary ?? "-")")
    }

    /// // Shut down the local translation channel (used when switching back to the Azure path or when the user cancels the target language).
    private func endLiveTranslation() {
        translateTo = nil
        translationFinalsReset()
        stopTranslatePump()
        if translationNotice == L10n.Live.translateUnavailable { translationNotice = nil }
    }

    private func translationFinalsReset() {
        translateFinals = []
        translatePartial = nil
        translateInFlight = nil
        lastPartialTranslated = ""
        lastPartialTranslateAt = nil
        didWarnTranslationBacklog = false
    }

    /// Serial translation pump. **Only one at a time** — running two requests concurrently on a local 3B model via CPU will only slow each other down.
    ///
    /// Why use polling instead of `AsyncStream` for the queue: partial translation requires the semantics of "**only translate the latest one, discard the old ones directly**", while `AsyncStream` is FIFO and cannot dequeue, which would cause a long queue of expired previews waiting to be translated. It wakes up every 200 ms when idle, does not block the main thread, and has negligible overhead.
    /// 
    /// 
    private func startTranslatePump() {
        guard translatePump == nil else { return }
        translatePump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Final takes priority over partial: final is the **finalized** body text,
                // while partial is only a preview; when competing for the same serial channel, feed final first.
                if let id = self.takeNextFinal() {
                    await self.translateFinal(id)
                    continue
                }
                if let text = self.takePendingPartial() {
                    await self.translatePartial(text)
                    continue
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func stopTranslatePump() {
        translatePump?.cancel()
        translatePump = nil
    }

    private func takeNextFinal() -> UUID? {
        guard !translateFinals.isEmpty else {
            didWarnTranslationBacklog = false
            return nil
        }
        if !didWarnTranslationBacklog,
           translateFinals.count > Self.translationBacklogWarnThreshold {
            didWarnTranslationBacklog = true
            log.warning("live translation backlog: \(self.translateFinals.count, privacy: .public) segment(s) pending — local model can't keep up with speech speed, translations will lag")
            diagLive("⚠ Translation backlog: \(translateFinals.count) segments (model can't keep up with speech speed)")
        }
        let id = translateFinals.removeFirst()
        if translateFinals.isEmpty { didWarnTranslationBacklog = false }
        return id
    }

    /// Fetch one pending partial, **throttled**.
    ///
    /// ⚠️ Intentionally using throttling instead of debouncing (waiting for text to stabilize before translating): while speaking, the partial window keeps expanding and
    ///    the text keeps changing, so the debounce condition is **never met** ⇒ no partial lines get translated.
    ///    Switching to "at most one translation every 2.5 s, always translating the latest one" allows scrolling through translated text.
    private func takePendingPartial() -> String? {
        guard let text = translatePartial else { return nil }
        if let last = lastPartialTranslateAt,
           Date().timeIntervalSince(last) < Self.partialTranslateMinInterval {
            return nil
        }
        translatePartial = nil
        return text
    }

    private func translateFinal(_ id: UUID) async {
        guard let config, let target = translateTo else { return }
        guard let index = finalSegments.firstIndex(where: { $0.id == id }) else { return }
        let source = finalSegments[index].text
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        translateInFlight = id
        defer { translateInFlight = nil }
        do {
            let result = try await LLMCompletionService.translate(
                text: source, targetLanguage: target, config: config.config)
            let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            // While waiting for the LLM, the user may have restarted the session — look up by id again first,
            // discard if not found (never write by index, as the index may now point to a different sentence).
            guard let now = finalSegments.firstIndex(where: { $0.id == id }) else { return }
            finalSegments[now].translation = cleaned
            translationNotice = nil
            diagLive("✓ #\(now + 1) \(String(source.prefix(18))) → \(String(cleaned.prefix(28)))")
        } catch {
            noteTranslationFailure(error)
        }
    }

    private func translatePartial(_ text: String) async {
        guard let config, let target = translateTo else { return }
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source != lastPartialTranslated else { return }

        lastPartialTranslateAt = Date()
        do {
            let result = try await LLMCompletionService.translate(
                text: source, targetLanguage: target, config: config.config)
            let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            // Only paste it if partial hasn't been replaced by final and the text is still the same as just now,
            // otherwise the translation of the previous sentence would be attached next to the original text of the next sentence.
            guard self.partialText == text else { return }
            lastPartialTranslated = source
            partialTranslation = cleaned
            translationNotice = nil
        } catch {
            noteTranslationFailure(error)
        }
    }

    /// Translation failure **does not interrupt transcription**: only log a soft warning, and avoid spamming (if the first one was said, do not repeat).
    private func noteTranslationFailure(_ error: Error) {
        log.warning("live translation failed: \(String(describing: error), privacy: .public)")
        diagLive("✗ Translation failed: \(String(describing: error))")
        if translationNotice == nil {
            translationNotice = L10n.Live.translateUnavailable
        }
    }

    /// Once the promised translations for this session are committed, **there is a limit**.
    ///
    /// Why this is needed: Local translations are filled in asynchronously, so the last few segments are likely still translating at the moment the session pauses.
    /// If we don't wait here, `saveTranscript` will skip them as "no translation available" ——
    /// The persisted `.txt/.json` will be missing the last few segments, even though the user clearly saw them in the UI.
    ///
    /// The upper limit is intentional: translation runs on a **3B model on the local CPU**, taking several seconds per line when slow.
    /// Blocking "stop" for it is unacceptable — better to miss two lines of translation than to leave the save hanging.
    private func flushLiveTranslation() async {
        guard translateTo != nil else { return }
        let started = translateFinals.count + (translateInFlight != nil ? 1 : 0)
        let deadline = Date().addingTimeInterval(Self.translationFlushTimeout)
        while (!translateFinals.isEmpty || translateInFlight != nil), Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !translateFinals.isEmpty || translateInFlight != nil {
            log.warning("live translation flush timed out with \(self.translateFinals.count, privacy: .public) segment(s) still pending")
            diagLive("⚠ flush timed out: \(translateFinals.count) translated segment(s) not received (will end up as \"original text only\")")
        } else if started > 0 {
            diagLive("✓ flush done (got back \(started) segment(s))")
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
    func repair(source: any LiveAudioSource, repair: PendingRepair) async {
        pendingRepair = nil
        repairState = .downloading(received: 0, total: max(repair.expectedSize, 1))
        let chachaKey = source.liveClipKey
        let autoDelete = config?.config.autoDeleteAfterTransfer ?? true
        do {
            // ★ Both paths for fetching data must remain, rather than "unifying through `liveFetch`":
            //   · `deviceFile != nil` → use the abstraction (TicNote does this, relying on `sessionID`);
            //   · `deviceFile == nil` → the legacy path (only the filename is available; D·NOTE's encrypted and plaintext data both go through this).
            // Incidentally, D·NOTE's `liveClipKey` is identical to the value returned by `KeyResolver.key(for:)`,
            // so switching here to fetch from `source` **will not** change D·NOTE's behavior.
            let data: Data
            if let file = repair.deviceFile {
                data = try await source.liveFetch(file: file) { [weak self] got, total in
                    self?.repairState = .downloading(received: got, total: max(total, got))
                }
            } else {
                guard let dnote = source as? DnoteLiveSource else {
                    throw RecorderLinkError.unsupported("no device file handle for repair")
                }
                data = try await dnote.client.downloadFile(
                    repair.deviceFileName,
                    expectedSize: repair.expectedSize
                ) { [weak self] got, total in
                    self?.repairState = .downloading(received: got, total: max(total, got))
                }
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
                if let file = repair.deviceFile {
                    try? await source.liveDelete(file: file)
                } else if let dnote = source as? DnoteLiveSource {
                    try? await dnote.client.deleteFile(repair.deviceFileName)
                }
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
    func declineRepair(repair: PendingRepair) async {
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
    private func resolveLatestDeviceFile(source: any LiveAudioSource) async -> LiveDeviceFile? {
        guard let before = preSessionFiles else {
            log.warning("resolveLatestDeviceFile: no pre-session snapshot — refusing to guess")
            return nil
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for attempt in 0..<3 {
            do {
                guard let files = await source.liveListFiles() else {
                    throw RecorderLinkError.timeout
                }

                // ★ Fastest path: the device itself reported the session key (TicNote's `0x14`/`0x17`/`0x18`).
                //   This is **exact equality**, not "guessing the latest" — the user might have used a physical button
                //   to record another track outside the app, which would appear in the list and be larger/more recent.
                //   D·NOTE does not provide this key (returns nil), so it naturally falls through to the name-based criteria below.
                if let key = source.liveLastSessionKey,
                   let exact = files.first(where: {
                       $0.name == key || $0.name.hasPrefix(key + ".")
                   }) {
                    log.info("resolveLatestDeviceFile: exact match by session key \(key, privacy: .public)")
                    return exact
                }

                let fresh = files.filter { before[$0.name] == nil }
                if fresh.count == 1, let only = fresh.first {
                    return only
                }
                if fresh.count > 1 {
                    // More than one file appeared (e.g. the device rotated
                    // mid-session). Newest-by-name among *new* files is still
                    // an identified candidate, not a blind guess.
                    if let newest = fresh.max(by: { $0.name < $1.name }) {
                        log.info("resolveLatestDeviceFile: \(fresh.count) new files, taking newest \(newest.name, privacy: .public)")
                        return newest
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
                        return only
                    }
                    log.warning("resolveLatestDeviceFile: attach session matched \(grown.count) grown files — not identifiable")
                    return nil
                }

                log.warning("resolveLatestDeviceFile attempt \(attempt + 1): no new file among \(files.count) listed")
                return nil
            } catch {
                log.warning("resolveLatestDeviceFile attempt \(attempt + 1) failed: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
        return nil
    }

    // MARK: - save

    private func saveAndCleanup(source: any LiveAudioSource,
                                stop: LiveStopOutcome,
                                buffer: Data,
                                hadPauses: Bool) async {
        var segments = finalSegments
        commitPartial()
        if finalSegments.count > segments.count {
            segments = finalSegments
        }

        // ★ Local translation is filled asynchronously: at the moment the session stops, the last few segments are likely **still being translated**.
        // If we don't wait for this and proceed, `saveTranscript` will skip them as "no translation" —
        // The persisted `.txt/.json` will miss the last few segments, even though the user clearly saw them in the UI.
        // There is a limit; see `flushLiveTranslation`: better to miss two translation segments than to block "stop".
        await flushLiveTranslation()
        // ⚠️ Must **fetch again**: `LiveSegment` is a struct, so the `segments` above is a
        //    **copy** of the array, while the translation pump backfills `finalSegments`. Without re-fetching, the wait is wasted.
        segments = finalSegments

        let provider = activeProvider
        let autoDelete = config?.config.autoDeleteAfterTransfer ?? true        // The buffer is passed in as a **snapshot** by the caller (see the note on `pendingSaveBuffer`) —
        // This only handles clearing it from the "recording" position; whether to discard these bytes is determined by the save result.
        streamBuffer = Data()
        // This buffer remains intact **until successful persistence**: if it fails, the user still has a "Save to Library" option available,
        // unlike before when only an error message was shown (the buffer had already been cleared, and the audio was truly lost).
        pendingSaveBuffer = buffer
        pendingStopOutcome = stop
        log.info("saveAndCleanup entry: buffer=\(buffer.count) hadPauses=\(hadPauses) stopFile=\(stop.file?.name ?? "nil", privacy: .public)")
        guard buffer.count >= opusProfile.packetBytes else {
            log.info("saveAndCleanup: buffer too small (\(buffer.count) bytes), skipping save")
            // A half packet cannot form a valid Ogg — **there is nothing to save here**.
            // Clear the pending save state to avoid leaving the UI with a button that will inevitably fail.
            // (`canSaveToLibrary` also checks the length; this is the second check).
            pendingSaveBuffer = Data()
            pendingStopOutcome = nil
            return
        }

        persistLanguagePreferences()

        // Resolve the device file up front. Prefer what the device echoed
        // back on stop; fall back to listing files and picking the one this
        // session produced. Saving the iOS clip under the device's name is
        // important because the iOS `startedAt` clock and the device's own
        // clock drift by 1-2 seconds, so the timestamp fallback produces
        // `20260422002021.opus` while the device file is `20260422002020.opus`.
        // That name mismatch breaks:
        //   (1) the repair flow's in-place overwrite
        //   (2) auto-delete's direct-name delete path
        // Listing once up front solves both.
        //
        // ★ TicNote follows the same path, but the "name" is derived from sid (the card's entry has no name),
        //   while `stop.file` already carries the `sessionID`, so the repair/delete logic below can precisely match it.
        var deviceFile = stop.file
        if deviceFile == nil || deviceFile?.size == 0 {
            if let resolved = await resolveLatestDeviceFile(source: source) {
                deviceFile = resolved
                log.info("saveAndCleanup resolve: name=\(resolved.name, privacy: .public) size=\(resolved.size)")
            }
        }
        let deviceFileName = deviceFile?.name

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

        // ★★ Before writing to disk, must ask the device once: "How should these raw bytes be converted into a playable file?"
        //    D·NOTE returns as-is (it is either already Ogg or an encrypted envelope);
        //    TicNote **must wrap in Ogg first** —— it is a 160 B raw packet stream, while `PostDownload`
        //    the fallback cuts by 40 B; if cut incorrectly, **no error is thrown**, only an unopenable file is written.
        let payload: Data
        do {
            payload = try source.liveContainerize(buffer, name: name)
        } catch {
            log.error("liveContainerize failed: \(String(describing: error), privacy: .public)")
            self.error = error.localizedDescription
            return
        }

        do {
            _ = try PostDownload.process(payload, name: name, chacha20Key: nil)
            library?.recordDownload(name: name, size: payload.count, transport: "stream")
            savedClipName = name
            // ★ Actually entered the database, now we can release the pending disk-write bytes.
            pendingSaveBuffer = Data()
            pendingStopOutcome = nil
            log.info("saved stream recording: \(name, privacy: .public) (\(payload.count) bytes)")
        } catch {
            log.error("failed to save stream: \(String(describing: error), privacy: .public)")
            return
        }

        diagLive("Disk write: \(segments.count) segments, of which \(segments.filter { $0.translation != nil }.count) segments have translations")
        if !segments.isEmpty {
            saveTranscript(segments: segments, audioName: name, provider: provider)
        }

        // If the user paused during the session, the iOS clip is missing
        // audio for the paused intervals. Offer to pull the complete
        // recording from the device instead of deleting it. Even when the
        // resolve fails, skip auto-delete so the user can transfer the
        // file manually from Recordings later.
        if hadPauses {
            if let file = deviceFile {
                pendingRepair = PendingRepair(
                    deviceFileName: file.name,
                    iosClipName: name,
                    expectedSize: file.size,
                    wasAttached: attachedToExistingRecording,
                    deviceFile: file
                )
                log.info("saveAndCleanup: offering repair from device file \(file.name, privacy: .public) size=\(file.size)")
            } else {
                log.warning("saveAndCleanup: pauses occurred but device file didn't resolve — showing manual-transfer hint, leaving device file intact")
                repairState = .needsManualTransfer
            }
            return
        }

        guard autoDelete else { return }

        // We know the device file — delete it directly, no duration match
        // heuristic needed. Detached so BLE delete doesn't block the
        // Live-tab UI from transitioning to the next session.
        if let file = deviceFile {
            Task.detached { @MainActor in
                do {
                    try await source.liveDelete(file: file)
                    log.info("deleted device file: \(file.name, privacy: .public)")
                } catch {
                    log.warning("delete \(file.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            return
        }

        // Last-ditch cleanup — resolve didn't succeed, fall back to
        // duration match against the file list.
        let streamedBytes = buffer.count
        let lib = library
        let packetBytes = opusProfile.packetBytes
        Task.detached { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let streamDuration = Double(streamedBytes / packetBytes) * 0.02
            guard streamDuration > 1.0 else { return }
            guard let files = await source.liveListFiles() else { return }
            let match = files
                .filter { file in
                    let d = Double(file.size / packetBytes) * 0.02
                    return abs(d - streamDuration) < 10.0
                }
                .max(by: { $0.name < $1.name })
            if let match {
                lib?.recordDownload(name: match.name, size: match.size, transport: "stream")
                try? await source.liveDelete(file: match)
                log.info("deleted matching device file: \(match.name, privacy: .public)")
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
