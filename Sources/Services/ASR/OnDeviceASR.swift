import AVFoundation
import Foundation
import Speech
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr.ondevice")

// MARK: - On-device speech recognition (Apple Speech, offline)
//
// ## Why this exists
//
// Every transcription path before this file needed either an Azure key or a faster-whisper
// server on the LAN. With neither configured, `LiveModel.openASR` threw **before the card was
// even told to record** — the user pressed Record and got "speech recognition not configured", no recording, no
// transcript. That is the shape of "the A1 cannot record".
//
// Apple's Speech framework can do the whole job **on the phone**: `requiresOnDeviceRecognition`
// keeps the audio local (no Apple server, no key, no account), and it works on a recording made
// ten minutes ago in a lift.
//
// ## The hard part: Opus → PCM
//
// Everything our recorders produce is Opus inside Ogg (A1 live frames are 84-byte packets,
// TicNote 160-byte). `SFSpeechRecognizer` wants LPCM buffers. There is no decoder in the app
// (OpusOgg only *wraps*), so we borrow the one the platform already ships: `AVAssetReader`
// decodes the exact `.opus`/`.ogg` files this app writes — the same path `AudioExporter.exportAsWAV`
// has been using in production — and we ask it for 16 kHz mono Int16 directly, which is what
// the recogniser wants.
//
// ⚠️ Tried and rejected: `AudioConverter` with `kAudioFormatOpus`. The platform *does* list an
// Opus decoder, but it latches end-of-stream after the first `AudioConverterFillComplexBuffer`
// that drains its input, so one converter cannot be fed packet-by-packet (measured 2026-10-18:
// packet 0 → 280 frames, packets 1…99 → 0 frames). Batch decoding through AVFoundation is both
// simpler and the path we already trust.

enum OnDeviceAsrError: LocalizedError {
    case unauthorized
    /// `Info.plist` has no `NSSpeechRecognitionUsageDescription` — see `hasUsageDescription`.
    case notDeclared
    case unavailable(String)
    case decode(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return L10n.ASR.onDeviceUnauthorized
        case .notDeclared: return L10n.ASR.onDeviceNotDeclared
        case .unavailable(let locale): return L10n.ASR.onDeviceUnavailable(locale)
        case .decode(let detail): return L10n.ASR.onDeviceDecodeFailed(detail)
        }
    }
}

enum OnDeviceASR {

    /// What the recogniser wants and what we decode to: 16 kHz, mono, signed 16-bit.
    static let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    // MARK: availability

    static func recognizer(localeID: String) -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale(identifier: localeID))
    }

    /// True when this locale has an **offline** model installed.
    ///
    /// `supportsOnDeviceRecognition` is the honest answer to "can this run with the network off";
    /// `isAvailable` alone only says the service is reachable, which is exactly what we don't want
    /// to depend on.
    static func isAvailable(localeID: String) -> Bool {
        guard hasUsageDescription else { return false }
        guard let recognizer = recognizer(localeID: localeID) else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    static var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        // Even *reading* the status is an access to a protected API; with the declaration
        // missing, report the honest answer instead of touching `Speech` at all.
        guard hasUsageDescription else { return .denied }
        return SFSpeechRecognizer.authorizationStatus()
    }

    /// True when the **built** app declares why it wants speech recognition.
    ///
    /// ★ (2026-10-18) This guard exists because of a real crash. Touching `Speech` without
    ///   `NSSpeechRecognitionUsageDescription` in the built `Info.plist` does not throw — iOS
    ///   kills the process (`termination.namespace = TCC`, "…must contain an
    ///   NSSpeechRecognitionUsageDescription key…"). And the plist we ship is *generated* by
    ///   xcodegen from `project.yml`, so the key can vanish between builds with no compiler
    ///   warning at all. Checking first turns that hard crash into an ordinary, readable error.
    static var hasUsageDescription: Bool {
        let value = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String
        return !(value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func requestAuthorization() async -> Bool {
        guard hasUsageDescription else {
            log.error("speech recognition usage description missing from Info.plist — refusing to call into Speech")
            // Also to the pullable file (`Documents/ticnote-ble.log`): this is the difference
            // between "the app crashed on launch" and "on-device recognition is refused".
            TicNoteDiagLog.log("ASR", "on-device refused: NSSpeechRecognitionUsageDescription missing from Info.plist")
            return false
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: decode

    /// Decode an Ogg-Opus file (or any AVFoundation-readable audio) into 16 kHz mono PCM.
    ///
    /// Streaming, not "return an array": an hour-long recording is ~115 MB of PCM and there is
    /// no reason to hold it all when the caller consumes 40 s at a time.
    static func decode(url: URL) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            let work = Task.detached(priority: .userInitiated) {
                do {
                    let asset = AVURLAsset(url: url)
                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    guard let track = tracks.first else {
                        throw OnDeviceAsrError.decode("no audio track")
                    }
                    let reader = try AVAssetReader(asset: asset)
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false,
                        AVLinearPCMIsNonInterleaved: false,
                        AVSampleRateKey: 16_000,
                        AVNumberOfChannelsKey: 1,
                    ]
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                    output.alwaysCopiesSampleData = false
                    guard reader.canAdd(output) else {
                        throw OnDeviceAsrError.decode("cannot add reader output")
                    }
                    reader.add(output)
                    guard reader.startReading() else {
                        throw OnDeviceAsrError.decode(reader.error?.localizedDescription ?? "cannot start reading")
                    }
                    while reader.status == .reading {
                        if Task.isCancelled { reader.cancelReading(); break }
                        guard let sample = output.copyNextSampleBuffer() else { break }
                        defer { CMSampleBufferInvalidate(sample) }
                        if let buffer = pcmBuffer(from: sample) {
                            continuation.yield(buffer)
                        }
                    }
                    if reader.status == .failed {
                        throw OnDeviceAsrError.decode(reader.error?.localizedDescription ?? "read failed")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        // 16-bit mono ⇒ 2 bytes per frame.
        let frames = length / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat,
                                            frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return nil }
        let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: destination)
        guard status == noErr else { return nil }
        return buffer
    }

    // MARK: whole-file transcription

    /// Transcribe one recording **offline**.
    ///
    /// Chunked at 40 s because a single recognition request is not meant to run for an hour:
    /// `SFSpeechRecognizer` finalises on its own schedule, and a 40 s slice keeps each request
    /// inside the window where partial/final behaviour is predictable. Timestamps are offset per
    /// chunk so the result still lines up with the audio (tap-to-seek relies on it).
    static func transcribeFile(url: URL, localeID: String) async throws -> AsrResult {
        guard hasUsageDescription else { throw OnDeviceAsrError.notDeclared }
        if authorizationStatus != .authorized {
            guard await requestAuthorization() else { throw OnDeviceAsrError.unauthorized }
        }
        guard let recognizer = recognizer(localeID: localeID) else {
            throw OnDeviceAsrError.unavailable(localeID)
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw OnDeviceAsrError.unavailable(localeID)
        }

        let chunkFrames = AVAudioFrameCount(16_000 * 40)
        guard let chunk = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: chunkFrames) else {
            throw OnDeviceAsrError.decode("cannot allocate chunk buffer")
        }
        chunk.frameLength = 0

        var segments: [AsrSegment] = []
        var offset: Double = 0
        var totalFrames: AVAudioFrameCount = 0

        func flush() async throws {
            guard chunk.frameLength > 0 else { return }
            let seconds = Double(chunk.frameLength) / 16_000.0
            let text = try await recognize(buffer: chunk, using: recognizer)
            if !text.isEmpty {
                segments.append(AsrSegment(
                    speaker: nil,
                    text: text,
                    start: offset,
                    end: offset + seconds,
                    duration: seconds
                ))
            }
            offset += seconds
            chunk.frameLength = 0
        }

        for try await buffer in decode(url: url) {
            totalFrames += buffer.frameLength
            var consumed: AVAudioFrameCount = 0
            while consumed < buffer.frameLength {
                let room = chunkFrames - chunk.frameLength
                let take = min(room, buffer.frameLength - consumed)
                if take > 0 {
                    copy(from: buffer, sourceOffset: consumed, frames: take, into: chunk)
                    consumed += take
                }
                if chunk.frameLength >= chunkFrames {
                    try await flush()
                } else if take == 0 {
                    break
                }
            }
        }
        try await flush()

        guard totalFrames > 0 else { throw AsrError.empty }
        let text = segments.map(\.text).joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AsrError.empty
        }
        log.info("on-device file transcription: \(segments.count) chunk(s), \(totalFrames) frames")
        return AsrResult(text: text, segments: segments, provider: "onDevice", locale: localeID)
    }

    private static func copy(from source: AVAudioPCMBuffer,
                             sourceOffset: AVAudioFrameCount,
                             frames: AVAudioFrameCount,
                             into destination: AVAudioPCMBuffer) {
        guard let src = source.int16ChannelData?[0],
              let dst = destination.int16ChannelData?[0] else { return }
        let from = Int(sourceOffset)
        let to = Int(destination.frameLength)
        for index in 0..<Int(frames) {
            dst[to + index] = src[from + index]
        }
        destination.frameLength += frames
    }

    /// One recognition request over one buffer. Resolves on `isFinal` (or the first error).
    private static func recognize(buffer: AVAudioPCMBuffer,
                                  using recognizer: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) { request.addsPunctuation = true }
        request.append(buffer)
        request.endAudio()

        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            var settled = false
            var latest = ""
            recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    latest = result.bestTranscription.formattedString
                    if result.isFinal, !settled {
                        settled = true
                        continuation.resume(returning: latest)
                        return
                    }
                }
                if error != nil, !settled {
                    settled = true
                    continuation.resume(returning: latest)
                }
            }
        }
    }
}

// MARK: - Live (streaming) on-device recognition

/// Turns the card's live Opus packets into text **without leaving the phone**.
///
/// The card pushes one packet every 20 ms. We collect ~3 s of them, wrap that slice into an Ogg
/// container in a temp file, decode it with AVFoundation, and append the PCM to a running
/// `SFSpeechAudioBufferRecognitionRequest`. 3 s is the compromise between "text that feels live"
/// and "decode as few times per minute as possible"; the recognition itself is genuinely
/// streaming, so words appear in bursts of a phrase rather than one by one.
@MainActor
final class OnDeviceLiveASR {

    enum Event {
        case partial(String)
        case final(String)
        case closed(Error?)
    }

    private let profile: OpusOgg.Profile
    private let localeID: String
    private let batchBytes: Int

    /// Loudness of the audio handed to the recogniser, normalised 0...1, several per batch.
    ///
    /// The recording screen samples this for its level bars — real signal from the same PCM the
    /// recogniser consumes, computed here because this is the only place that ever sees decoded
    /// samples on the live path. nil = nobody is listening (the common case for tests).
    var onLevels: (([Double]) -> Void)?

    /// Requests rebuilt after an error, reset by the next successful result. Bounded so a
    /// permanently broken recogniser fails loudly instead of looping.
    private var errorRebuilds = 0

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<Event>.Continuation?

    /// Bytes that haven't filled a whole batch yet.
    private var pending = Data()
    private var decodeQueue: [Data] = []
    private var decoding = false
    private var closed = false
    private var started = false
    /// ★ 2026-10-28 D3200 实时字幕：160 B 帧直解（`SoundcoreLiveDecoder`，
    /// 与阿里云 live 同一条已验证解码链）。AVAssetReader 解不了自封装的
    /// Ogg/Opus（每 batch 抛「这项操作无法完成」），这个兜底链同样要绕开。
    private var liveDecoder: SoundcoreLiveDecoder?

    /// ~3 s of audio: `packetBytes` per 20 ms ⇒ 50 packets/s.
    private static let batchSeconds = 3

    init(profile: OpusOgg.Profile, localeID: String) {
        self.profile = profile
        self.localeID = localeID
        self.batchBytes = profile.packetBytes * 50 * Self.batchSeconds
    }

    func connect() throws -> AsyncStream<Event> {
        var captured: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event>(bufferingPolicy: .unbounded) { continuation in
            captured = continuation
        }
        continuation = captured

        Task { @MainActor [weak self] in
            guard let self else { return }
            // Never call into Speech without the declaration — see `OnDeviceASR.hasUsageDescription`.
            guard OnDeviceASR.hasUsageDescription else {
                self.fail(OnDeviceAsrError.notDeclared)
                return
            }
            if OnDeviceASR.authorizationStatus != .authorized {
                let granted = await OnDeviceASR.requestAuthorization()
                guard granted else {
                    self.fail(OnDeviceAsrError.unauthorized)
                    return
                }
            }
            guard !self.closed else { return }
            guard let recognizer = OnDeviceASR.recognizer(localeID: self.localeID) else {
                self.fail(OnDeviceAsrError.unavailable(self.localeID))
                return
            }
            guard recognizer.supportsOnDeviceRecognition else {
                self.fail(OnDeviceAsrError.unavailable(self.localeID))
                return
            }
            self.recognizer = recognizer
            self.beginRequest()
            self.started = true
            self.drainPending()
        }
        return stream
    }

    /// Feed one full Opus packet (or any aligned slice of them).
    func send(_ data: Data) {
        guard !closed else { return }
        pending.append(data)
        guard started else { return }
        drainPending()
    }

    func close() {
        guard !closed else { return }
        closed = true
        request?.endAudio()
        task?.finish()
        request = nil
        task = nil
        continuation?.yield(.closed(nil))
        continuation?.finish()
        continuation = nil
    }

    // MARK: internals

    private func drainPending() {
        while pending.count >= batchBytes {
            let batch = pending.prefix(batchBytes)
            pending.removeFirst(batchBytes)
            decodeQueue.append(Data(batch))
        }
        decodeNext()
    }

    private func decodeNext() {
        guard !decoding, !decodeQueue.isEmpty, !closed else { return }
        decoding = true
        let batch = decodeQueue.removeFirst()

        // ★ 2026-10-28 D3200 fast path：160 B 帧直解出 16 kHz mono PCM，
        // 直接构 `AVAudioPCMBuffer` 喂识别请求（绕开 Ogg/AVAssetReader 死路）。
        if profile.packetBytes == SoundcoreOgg.frameSize {
            if liveDecoder == nil { liveDecoder = SoundcoreLiveDecoder() }
            let pcm = liveDecoder?.decode(batch) ?? Data()
            Task.detached(priority: .userInitiated) { [weak self] in
                await MainActor.run {
                    guard let self else { return }
                    self.decoding = false
                    if let buffer = Self.pcmBuffer(fromMono16k: pcm) {
                        self.request?.append(buffer)
                        self.onLevels?(Self.loudness(of: [buffer]))
                    }
                    self.decodeNext()
                }
            }
            return
        }

        let ogg = OpusOgg.wrap(rawFrames: batch, serial: 0xA1D1_0001, profile: profile)
        guard !ogg.isEmpty else {
            decoding = false
            decodeNext()
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            var buffers: [AVAudioPCMBuffer] = []
            var failure: Error?
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("live-ondevice-\(UUID().uuidString).opus")
                try ogg.write(to: url, options: .atomic)
                defer { try? FileManager.default.removeItem(at: url) }
                for try await buffer in OnDeviceASR.decode(url: url) {
                    buffers.append(buffer)
                }
            } catch {
                failure = error
            }
            await MainActor.run {
                guard let self else { return }
                self.decoding = false
                if let failure {
                    log.warning("on-device live decode failed: \(String(describing: failure), privacy: .public)")
                } else {
                    for buffer in buffers { self.request?.append(buffer) }
                    self.onLevels?(Self.loudness(of: buffers))
                }
                self.decodeNext()
            }
        }
    }

    /// 16 kHz mono 16-bit LE PCM → `AVAudioPCMBuffer`（int16 交织单声道）。
    private static func pcmBuffer(fromMono16k pcm: Data) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: 16_000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        pcm.withUnsafeBytes { raw in
            if let dst = buffer.int16ChannelData?[0] {
                raw.copyBytes(to: UnsafeMutableBufferPointer(start: dst, count: frames))
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    /// Split each decoded buffer into ~8 slices and RMS-normalise each into 0...1.
    ///
    /// Speech sits around 0.05–0.3 RMS, so the display gain (×4) is tuned so ordinary talking
    /// fills most of the bar without clipping on laughter.
    private static func loudness(of buffers: [AVAudioPCMBuffer]) -> [Double] {
        var levels: [Double] = []
        for buffer in buffers {
            guard let samples = buffer.int16ChannelData?[0] else { continue }
            let count = Int(buffer.frameLength)
            let slices = 8
            let slice = max(count / slices, 1)
            for index in 0..<slices {
                let start = index * slice
                let end = min(start + slice, count)
                guard end > start else { continue }
                var sum = 0.0
                for offset in stride(from: start, to: end, by: 2) {
                    let v = Double(samples[offset])
                    sum += v * v
                }
                let taken = Double((end - start + 1) / 2)
                let rms = (sum / max(taken, 1)).squareRoot() / 32_768.0
                levels.append(min(rms * 4.0, 1.0))
            }
        }
        return levels
    }

    private func beginRequest() {
        guard let recognizer else { return }
        // A finished request cannot take more audio. Cancel the old task first: its callback
        // must not fire into the *new* request's state (that was how two tasks ended up
        // appending to the same session and the text jittered).
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) { request.addsPunctuation = true }
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let result {
                    self.errorRebuilds = 0
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        if !text.isEmpty { self.continuation?.yield(.final(text)) }
                        // A request finalises on its own after a pause (and cannot be reused).
                        // Starting a fresh one keeps the session going for the whole recording.
                        self.beginRequest()
                        return
                    } else if !text.isEmpty {
                        self.continuation?.yield(.partial(text))
                    }
                }
                guard let error, self.request === request else { return }
                // ★ (2026-10-18) An **error** also terminates the task for good. Previously only
                //   `isFinal` rebuilt the request, so the first hiccup (model still loading, a
                //   dropped buffer) silenced transcription for the rest of the session while the
                //   recording kept going — "card records, phone shows nothing".
                self.errorRebuilds += 1
                log.warning("on-device live request ended (\(self.errorRebuilds)): \(String(describing: error), privacy: .public)")
                if self.errorRebuilds > 6 {
                    // Persistent failure (e.g. the offline model for this language was never
                    // downloaded): stop pretending and let the UI show the reason.
                    self.fail(OnDeviceAsrError.unavailable(self.localeID))
                    return
                }
                self.beginRequest()
            }
        }
    }

    private func fail(_ error: Error) {
        log.error("on-device live unavailable: \(String(describing: error), privacy: .public)")
        closed = true
        continuation?.yield(.closed(error))
        continuation?.finish()
        continuation = nil
    }
}
