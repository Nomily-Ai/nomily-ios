import AVFoundation
import Foundation
import Speech
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "plaud.live-asr")

// MARK: - One committed line of live text

/// A single finished line of the live transcript.
///
/// Why not a joined `String` any more (2026-10-22): the old model kept
/// `finals: [String]` and concatenated with `\n`, so every line looked alike,
/// nothing carried a timestamp, and the UI could not scroll to "what was just
/// said". `at` is the **card's own clock** (seconds since the take started), so
/// a line can later be aligned with the recording without guessing.
struct PlaudLiveSegment: Identifiable, Equatable {
    let id: UUID
    let text: String
    let at: TimeInterval

    init(text: String, at: TimeInterval, id: UUID = UUID()) {
        self.id = id
        self.text = text
        self.at = at
    }

    /// `mm:ss`, or `h:mm:ss` past the hour — the shape every clock in the app
    /// uses for a take. Lives here (not in the view) because the service also
    /// needs it when it writes the transcript to disk.
    static func clock(_ seconds: TimeInterval) -> String {
        PlaudClock.text(seconds)
    }
}

// MARK: - PCM feeder (off the main thread)

/// Hands PCM blocks to the current recognition request **without touching the
/// main thread**, keeps the rolling replay tail, and answers "did this segment
/// actually contain speech".
///
/// Why this exists: the previous implementation hopped every PCM block to the
/// main actor (`Task { @MainActor in … }`, ~10–50 blocks/s) and appended there,
/// so recognition competed with SwiftUI rendering and every publish re-rendered
/// the settings list. That is exactly the "the text lags behind me" report.
///
/// It is `@unchecked Sendable` on purpose: all mutable state is behind `lock`
/// (or only touched on `queue`), and the object holds no UI state at all.
final class PlaudPCMFeeder: @unchecked Sendable {

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.nomily.app.plaud.live-pcm", qos: .userInitiated)
    private let format: AVAudioFormat

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tail = Data()
    private var heardVoice = false
    private var elapsed: TimeInterval = 0
    private var lastBlockAt = Date.distantPast

    /// Blocks below this RMS (0…1) count as silence.
    static let voiceFloor: Float = 0.006
    /// How much audio is replayed into a fresh request after a restart.
    static let replaySeconds: Double = 1.2

    init?(format: AVAudioFormat?) {
        guard let format else { return nil }
        self.format = format
    }

    private var replayBytes: Int { Int(Double(format.sampleRate) * Self.replaySeconds) * 2 }

    // MARK: Called from the main actor

    func setRequest(_ new: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let old = request
        request = new
        lock.unlock()
        if new == nil { old?.endAudio() }
    }

    /// Swap in a new request and hand back the audio that must be replayed into
    /// it. Voice state is re-seeded from the replay: the tail very likely holds
    /// the word that was in flight when the engine finalized.
    func takeReplay() -> Data {
        queue.sync {
            lock.lock()
            defer { lock.unlock() }
            let replay = tail
            tail.removeAll(keepingCapacity: true)
            heardVoice = Self.rms(replay) > Self.voiceFloor
            return replay
        }
    }

    /// Was there speech since the last commit, and what was the card's clock?
    func takeVoiceState() -> (heardVoice: Bool, elapsed: TimeInterval) {
        queue.sync {
            lock.lock()
            defer { lock.unlock() }
            let state = (heardVoice, elapsed)
            heardVoice = false
            return state
        }
    }

    func secondsSinceLastBlock() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastBlockAt)
    }

    func reset() {
        queue.sync {
            lock.lock()
            tail.removeAll(keepingCapacity: true)
            heardVoice = false
            elapsed = 0
            lastBlockAt = .distantPast
            lock.unlock()
        }
    }

    // MARK: Called from any thread

    func append(_ pcm: Data, elapsed seconds: TimeInterval) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let request = self.request
            self.elapsed = seconds
            self.lastBlockAt = Date()
            self.tail.append(pcm)
            let excess = self.tail.count - self.replayBytes
            if excess > 0 { self.tail.removeFirst(excess) }
            if Self.rms(pcm) > Self.voiceFloor { self.heardVoice = true }
            self.lock.unlock()
            // Append outside the lock: swapping the request on the main actor
            // must never wait for a buffer copy, and appending to a request that
            // was just ended is harmless (the replay covers that gap).
            if let buffer = Self.makeBuffer(pcm, format: self.format) {
                request?.append(buffer)
            }
        }
    }

    // MARK: PCM helpers

    static func makeBuffer(_ pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(pcm.count / 2)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard let dst = buffer.int16ChannelData?[0] else { return nil }
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(dst, base, pcm.count) }
        }
        return buffer
    }

    /// RMS of 16-bit little-endian mono samples, normalised to 0…1.
    static func rms(_ pcm: Data) -> Float {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        var sum: Double = 0
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let samples = base.assumingMemoryBound(to: Int16.self)
            for i in 0..<count {
                let v = Double(samples[i]) / 32768
                sum += v * v
            }
        }
        return Float((sum / Double(count)).squareRoot())
    }
}

// MARK: - Live transcriber

/// On-device live transcript for the PLAUD card.
///
/// ## Where the audio comes from
/// The PLAUD SDK only emits audio through the **sync-file channel**: once a
/// recording is live (started by the app or attached by us) we call
/// `syncFile(sessionId:start:end:)` and the card pushes decoded PCM blocks via
/// `blePcmData`. `PlaudDirectService` meters those blocks and forwards every
/// one of them to this class through `PlaudDirectService.liveAudioSink`.
///
/// ## Why on-device speech and not the ASR provider chain
/// The provider chain (Azure / whisper server) is Opus-packet based — it takes
/// whole Opus frames and decodes them itself. PLAUD hands us **raw PCM**, which
/// no provider entry point accepts. Feeding PCM into `SFSpeech` directly is the
/// one path that works with no extra codec and no network, and it is the same
/// engine the A1's `ondevice` fallback uses, so behaviour is consistent.
/// A cloud-provider live path for PCM is a deliberate follow-up, not an
/// oversight.
///
/// ## What changed on 2026-10-22 (the "lags behind / bad text" round)
/// * **Audio no longer goes through the main actor** — `PlaudPCMFeeder` appends
///   on its own queue.
/// * **A restart no longer eats a sentence.** `isFinal` used to drop the
///   in-flight hypothesis and start a bare request, so every engine rollover
///   (~1 min) lost half a phrase and the first word after it. Now the pending
///   hypothesis is committed first and the last ~1.2 s of audio is replayed into
///   the new request; the replay's duplicate words are stripped by a character
///   overlap check.
/// * **Silence no longer invents text.** SFSpeech emits "Thank you." / "谢谢观看"
///   out of pure silence; a segment whose audio never crossed the voice floor is
///   dropped before it reaches the UI.
/// * **Punctuation + dictation hint**, so lines end like sentences instead of
///   running together.
/// * **Stuck-engine watchdog** — audio flowing but no callback for 10 s rebuilds
///   the request (the on-device engine never recovers from that state itself).
///
/// ## Request lifecycle
/// `SFSpeechAudioBufferRecognitionRequest` finalizes after ~1 min of audio (or
/// on its own silence heuristics), so the request is rebuilt after every
/// `isFinal`. Audio keeps flowing into the *new* request seamlessly.
///
/// ## Threading
/// Not `@MainActor`: `append(_:elapsed:)` is called straight from the SDK's BLE
/// queue, and every published mutation is hopped to the main queue explicitly.
/// Callers observe `onTextChange` (always on main).
final class PlaudLiveTranscriber: NSObject, ObservableObject, SFSpeechRecognizerDelegate, PlaudLiveASR {

    /// Kept as an alias so existing call sites keep reading naturally; the cases
    /// themselves live in the shared `PlaudLiveASRUnavailable` now that a second
    /// engine (Azure) exists.
    typealias Unavailable = PlaudLiveASRUnavailable

    let providerName = "ondevice"

    /// Never called by this engine — the on-device recogniser recovers on its own
    /// (watchdog + rebuild). Declared so it satisfies `PlaudLiveASR`.
    var onFailure: ((PlaudLiveASRUnavailable) -> Void)?

    @Published private(set) var segments: [PlaudLiveSegment] = []
    @Published private(set) var partial = ""
    @Published private(set) var isActive = false
    @Published private(set) var unavailable: Unavailable?
    /// Locale actually used ("zh-CN", "en-US", …) — surfaced so "it transcribes
    /// but in the wrong language" is diagnosable instead of mysterious.
    @Published private(set) var localeIdentifier = ""
    @Published private(set) var restartCount = 0
    @Published private(set) var droppedFinals = 0

    /// Called on the main queue after every transcript mutation.
    var onTextChange: (() -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var feeder: PlaudPCMFeeder?
    private var watchdog: Timer?
    private var lastCallbackAt = Date()
    private var lastPartialPublish = Date.distantPast

    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16_000,
                                          channels: 1,
                                          interleaved: true)

    /// Words the engine should know about. Cheap, and it stops "Nomily" from
    /// coming back as "no milly" all session long.
    private static let contextual = ["Nomily", "PLAUD", "Note Pro", "钉钉", "转写"]

    /// Overall transcript (committed lines + the in-flight hypothesis).
    var fullText: String {
        var parts = segments.map(\.text)
        let tailText = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tailText.isEmpty { parts.append(tailText) }
        return parts.joined(separator: "\n")
    }

    // MARK: Creation

    /// - Parameter localeID: preferred spoken language ("zh", "en-US", …). Falls
    ///   back to the device locale when empty/unknown.
    static func makeIfPermitted(localeID: String?) -> PlaudLiveTranscriber? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            log.info("plaud live asr skipped: speech not authorized")
            return nil
        }
        return PlaudLiveTranscriber(localeID: localeID)
    }

    private init(localeID: String?) {
        super.init()
        feeder = PlaudPCMFeeder(format: pcmFormat)
        let resolved = Self.resolveLocale(localeID)
        recognizer = SFSpeechRecognizer(locale: resolved) ?? SFSpeechRecognizer()
        recognizer?.delegate = self
        localeIdentifier = recognizer?.locale.identifier ?? "?"
        log.info("plaud live asr locale=\(self.localeIdentifier, privacy: .public) requested=\(localeID ?? "-", privacy: .public)")
    }

    /// "zh" → a concrete Chinese locale, "en" → English, unknown → device locale.
    private static func resolveLocale(_ id: String?) -> Locale {
        guard var raw = id?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return Locale.current
        }
        // Values in config are bare codes ("zh"/"en"/"ja") or full ids.
        if !raw.contains("-") && !raw.contains("_") {
            raw = raw.lowercased() == "zh" ? "zh-CN" : raw
        }
        return Locale(identifier: raw)
    }

    // MARK: Lifecycle

    func start() {
        guard let recognizer else {
            unavailable = .noRecognizer
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // Starting anyway would make the task fail on the first result with
            // "assets unavailable" and look like a silent no-op.
            unavailable = .modelMissing
            log.info("plaud live asr: on-device model missing for \(self.localeIdentifier, privacy: .public)")
            return
        }
        restartRequest(first: true)
        startWatchdog()
    }

    /// Clear the transcript for a **new** take. Called when a recording starts;
    /// stopping deliberately keeps the text so the user can still read it.
    func reset() {
        segments = []
        partial = ""
        restartCount = 0
        droppedFinals = 0
        feeder?.reset()
        publish()
    }

    /// Carry text over when the owner switches engines mid-take (Azure dropped →
    /// on-device takes over). Without this the user would watch their transcript
    /// restart from nothing at the worst possible moment.
    func seed(segments: [PlaudLiveSegment]) {
        self.segments = segments
        publish()
    }

    func append(_ pcm: Data, elapsed: TimeInterval) {
        guard isActive, !pcm.isEmpty else { return }
        feeder?.append(pcm, elapsed: elapsed)
    }

    func stop() {
        isActive = false
        watchdog?.invalidate()
        watchdog = nil
        feeder?.setRequest(nil)
        task?.cancel()
        task = nil
        publishPartial("")
    }

    // MARK: Restart

    private func restartRequest(first: Bool = false) {
        guard let recognizer, let feeder else { return }
        let replay = first ? Data() : feeder.takeReplay()
        task?.cancel()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        if #available(iOS 16.0, *) { request.addsPunctuation = true }
        request.contextualStrings = Self.contextual

        feeder.setRequest(request)
        isActive = true
        lastCallbackAt = Date()
        if !first { restartCount += 1 }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // SFSpeech calls back on its own queue.
            DispatchQueue.main.async {
                self?.handle(result: result, error: error)
            }
        }
        // Replay the tail so the word being spoken across the swap survives.
        // The duplicate it produces is stripped in `commit`.
        if !replay.isEmpty { feeder.append(replay, elapsed: 0) }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        lastCallbackAt = Date()
        if let error {
            // A normal end ("no speech detected", "cancelled") also lands here.
            // Rebuild and keep listening — unless the session is over.
            log.info("plaud live asr ended: \(error.localizedDescription, privacy: .public)")
            if isActive { restartRequest() }
            return
        }
        guard let result else { return }
        let text = result.bestTranscription.formattedString
        if result.isFinal {
            commit(text)
            if isActive { restartRequest() }
        } else {
            publishPartial(text)
        }
    }

    // MARK: Commit

    private func commit(_ raw: String) {
        guard let feeder else { return }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = feeder.takeVoiceState()
        guard !text.isEmpty else {
            publishPartial("")
            return
        }

        // ① The engine invented a sentence out of silence.
        guard voice.heardVoice else {
            droppedFinals += 1
            publishPartial("")
            log.info("plaud live asr dropped a silent final (\(text.count, privacy: .public) chars)")
            return
        }

        // ② The replay after a restart re-hears words we already committed.
        if let last = segments.last?.text {
            if text == last {
                publishPartial("")
                return
            }
            if let stripped = Self.stripOverlap(from: text, already: last) {
                text = stripped
                if text.isEmpty {
                    publishPartial("")
                    return
                }
            }
        }

        // ③ The engine sometimes repeats a whole line verbatim.
        if segments.suffix(3).contains(where: { $0.text == text }) {
            publishPartial("")
            return
        }

        let line = PlaudLiveSegment(text: text, at: voice.elapsed)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.segments.append(line)
            self.partial = ""
            self.publish()
        }
    }

    /// Characters (CJK) at the end of `already` that `text` starts with — these
    /// were re-heard from the replay buffer and must not be shown twice.
    private static func stripOverlap(from text: String, already: String) -> String? {
        let new = Array(text)
        let old = Array(already)
        let maxOverlap = min(new.count, old.count)
        guard maxOverlap >= 4 else { return nil }
        for n in stride(from: maxOverlap, through: 4, by: -1) {
            if Array(old.suffix(n)) == Array(new.prefix(n)) {
                var rest = String(new.dropFirst(n))
                rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
                rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "，、。,.;；:：!！?？"))
                return rest
            }
        }
        return nil
    }

    // MARK: Publishing (throttled)

    private func publishPartial(_ text: String) {
        let now = Date()
        // The engine can emit 10+ hypotheses a second and every publish
        // re-renders the list. Dropping intermediates is safe — each hypothesis
        // carries the whole sentence.
        if !text.isEmpty, now.timeIntervalSince(lastPartialPublish) < 0.12 { return }
        lastPartialPublish = now
        DispatchQueue.main.async { [weak self] in
            guard let self, self.partial != text else { return }
            self.partial = text
            self.publish()
        }
    }

    private func publish() {
        onTextChange?()
    }

    // MARK: Watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        // `self` is captured only inside the hop back to main, so the timer's own
        // @Sendable closure captures nothing non-Sendable.
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            DispatchQueue.main.async { [weak self] in self?.checkWatchdog() }
        }
    }

    private func checkWatchdog() {
        guard isActive, let feeder else { return }
        // Only "stuck" when audio IS arriving — a card that stopped pushing is a
        // different problem and must not spam requests.
        guard feeder.secondsSinceLastBlock() < 2 else { return }
        guard Date().timeIntervalSince(lastCallbackAt) > 10 else { return }
        log.warning("plaud live asr stuck (no callback for 10s while audio flows) — rebuilding")
        restartRequest()
    }

    // MARK: SFSpeechRecognizerDelegate

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        DispatchQueue.main.async { [weak self] in
            log.info("plaud live asr availability \(available)")
            guard let self else { return }
            if available, !self.isActive { self.restartRequest(first: true) }
        }
    }
}
