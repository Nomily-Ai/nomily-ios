import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "phone-mic")

/// Phone-microphone recorder feeding both a WAV file and live ASR (★ 2026-10-22, 任务一).
///
/// ## Why this exists
/// Nomily's live pipeline used to be device-only (`LiveAudioSource` is built
/// around Opus packets from a card). "Phone recording with live captions"
/// (Plaud's `record` module) has no Opus encoder available — libopus is not
/// linked — so this source skips the Opus detour entirely: the mic's PCM is
/// written straight to a **WAV** file (universally playable, `PostDownload`
/// already passes `.wav` through) and fed as 16 kHz mono Int16 PCM to a live
/// ASR engine (`LiveCaptionController`).
///
/// ## Threading
/// The AVAudioEngine tap fires on a realtime audio thread. Nothing heavy may
/// run there: the tap converts and hands the PCM to a serial work queue that
/// does file IO and level math; `@Published` state is funnelled to the main
/// actor with a cheap throttle. Consumers (`LiveCaptionController`) receive
/// `append` calls on the main actor, matching what `PlaudLiveASR` expects.
@MainActor
final class PhoneMicRecorder: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var elapsed: TimeInterval = 0
    /// Latest loudness, normalised 0...1 (drives the level bars).
    @Published private(set) var level: Double = 0
    @Published var error: String?

    /// 16 kHz mono Int16 little-endian PCM, called on the main actor.
    /// Set before `start()`.
    var pcmSink: ((Data, TimeInterval) -> Void)?

    private let engine = AVAudioEngine()
    /// Serial queue for file IO + conversion work off the realtime thread.
    private let workQueue = DispatchQueue(label: "com.nomily.phone-mic.work")
    private var fileHandle: FileHandle?
    private var outputURL: URL?
    private var totalPCMBytes = 0
    private var startDate: Date?
    /// Audio-thread → work-queue → main throttling of `level` publishes.
    private var lastLevelPublish = Date.distantPast

    /// Where the recording will be (or was) written.
    var currentFileURL: URL? { outputURL }

    func start() throws {
        guard !isRunning else { return }
        error = nil

        let session = AVAudioSession.sharedInstance()
        session.requestRecordPermission { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                if granted {
                    self.beginSession()
                } else {
                    self.error = L10n.Phone.micDenied
                    Telemetry.failed("record_phone_start", reason: "mic_denied")
                }
            }
        }
    }

    /// Second half of `start()` after the permission round-trip.
    private func beginSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker])
            try session.setActive(true)

            let input = engine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw PhoneMicError.noInput
            }

            // Target: 16 kHz mono Int16 — the shape every live ASR engine wants.
            guard let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                channels: 1, interleaved: true) else {
                throw PhoneMicError.noInput
            }
            guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
                throw PhoneMicError.conversionUnavailable
            }

            let name = Self.timestampedName()
            let url = StorageLocations.decryptedDir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: StorageLocations.decryptedDir, withIntermediateDirectories: true)
            try Self.wavHeader().write(to: url, options: .atomic)
            let handle = try FileHandle(forWritingTo: url)

            outputURL = url
            fileHandle = handle
            totalPCMBytes = 0
            startDate = Date()
            elapsed = 0
            level = 0
            isRunning = true

            let sink = pcmSink
            input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let converted = Self.convert(buffer: buffer, with: converter) else { return }
                let data = converted
                let rms = Self.rms(of: buffer)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning else { return }
                    let elapsed = self.startDate.map { Date().timeIntervalSince($0) } ?? 0
                    let handle = self.fileHandle
                    self.workQueue.async {
                        // File IO only here — nothing actor-isolated is touched.
                        try? handle?.seekToEnd()
                        try? handle?.write(contentsOf: data)
                    }
                    self.totalPCMBytes += data.count
                    // ~20 fps ceiling on level publishing keeps SwiftUI calm.
                    if Date().timeIntervalSince(self.lastLevelPublish) > 0.05 {
                        self.lastLevelPublish = Date()
                        self.level = min(max(rms * 8, 0), 1)
                    }
                    self.elapsed = elapsed
                    sink?(data, elapsed)
                }
            }
            try engine.start()
            log.info("phone mic recording started → \(url.lastPathComponent, privacy: .public)")
            Telemetry.success("record_phone_start")
        } catch {
            self.error = error.localizedDescription
            isRunning = false
            log.error("phone mic start failed: \(String(describing: error), privacy: .public)")
            Telemetry.failed("record_phone_start", reason: String(describing: error))
        }
    }

    /// Stop and finalise. Returns the finished WAV URL when a take was actually captured.
    @discardableResult
    func stop() -> URL? {
        guard isRunning else { return nil }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let handle = fileHandle
        let url = outputURL
        let bytes = totalPCMBytes
        fileHandle = nil
        // Patch the WAV sizes on the work queue so the UI returns immediately.
        workQueue.async { [weak self] in
            defer { Task { @MainActor in self?.finishStop(handle: nil) } }
            guard let handle else { return }
            Self.patchWavSizes(handle: handle, pcmBytes: bytes)
            try? handle.close()
        }
        Telemetry.success("record_phone_stop", ["seconds": String(Int(elapsed))])
        return url
    }

    private func finishStop(handle: FileHandle?) {
        level = 0
    }

    // MARK: - Helpers

    static func timestampedName() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMddHHmmss"
        return "Phone-\(fmt.string(from: Date())).wav"
    }

    /// Convert any input buffer to interleaved Int16 16k mono `Data`.
    /// Static + nonisolated so it runs on the realtime tap thread safely.
    nonisolated private static func convert(buffer: AVAudioPCMBuffer,
                                            with converter: AVAudioConverter) -> Data? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                         frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error {
            log.error("pcm convert failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let channel = out.int16ChannelData?[0] else { return nil }
        let count = Int(out.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: channel, count: count)
    }

    /// RMS of the first channel, 0...1. Nonisolated (realtime thread).
    nonisolated private static func rms(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += channel[i] * channel[i] }
        return sqrt(Double(sum / Float(n)))
    }

    /// 44-byte canonical WAV header; sizes patched on stop.
    nonisolated private static func wavHeader() -> Data {
        var h = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        h.append(Data("RIFF".utf8)); le32(0xFFFFFFFF)
        h.append(Data("WAVE".utf8))
        h.append(Data("fmt ".utf8)); le32(16)
        le16(1)          // PCM
        le16(1)          // mono
        le32(16000)      // sample rate
        le32(32000)      // byte rate = 16000 * 2
        le16(2)          // block align
        le16(16)         // bits per sample
        h.append(Data("data".utf8)); le32(0xFFFFFFFF)
        return h
    }

    private static func patchWavSizes(handle: FileHandle, pcmBytes: Int) {
        var h = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        h.append(Data("RIFF".utf8))
        le32(UInt32(clamping: pcmBytes + 36))
        h.append(Data("WAVE".utf8))
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: h)
        try? handle.seek(toOffset: 40)
        var d = Data()
        withUnsafeBytes(of: UInt32(clamping: pcmBytes).littleEndian) { d.append(contentsOf: $0) }
        try? handle.write(contentsOf: d)
    }

    enum PhoneMicError: LocalizedError {
        case noInput
        case conversionUnavailable
        var errorDescription: String? {
            switch self {
            case .noInput: return L10n.Phone.noInput
            case .conversionUnavailable: return L10n.Phone.conversionUnavailable
            }
        }
    }
}
