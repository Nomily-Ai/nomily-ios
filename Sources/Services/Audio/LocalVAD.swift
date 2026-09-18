import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "audio.vad")

enum LocalVADError: Error {
    case noAudioTrack
    case readerSetupFailed
    case exportFailed(String)
}

/// Per-window RMS envelope + detected speech ranges for one clip.
/// Exposed so the debug preview view can render the same signal the
/// upload path thresholds against. `rms[i]` covers `[i*windowDur,
/// (i+1)*windowDur)` seconds.
struct VADReport {
    struct SpeechRange: Equatable { let start: Double; let end: Double }

    let rms: [Double]
    let windowDur: Double
    let noiseFloor: Double
    let threshold: Double
    let thresholdMultiplier: Double
    let hangoverSec: Double
    let ranges: [SpeechRange]
    let totalDuration: Double

    var speechDuration: Double { ranges.reduce(0) { $0 + ($1.end - $1.start) } }
    var savedDuration: Double { max(0, totalDuration - speechDuration) }
}

/// Energy-based Voice Activity Detection that runs before ASR upload
/// so we don't burn provider credits on silence. Reads the clip as
/// 16 kHz mono PCM, computes RMS per 30 ms window, applies an
/// adaptive noise floor, and splices the speech regions back together
/// into a temp m4a. Falls back to the original file (returns `nil`)
/// whenever the heuristic finds nothing to save — decode failure
/// (iOS 16 has no Opus decoder), no speech detected, or the trim
/// would shave off less than 10 % of the clip.
///
/// Deliberately not libwebrtc-vad / Silero: both are heavier than
/// what a cost-saving filter needs, and RMS catches ~90 % of obvious
/// silence at near-zero complexity.
enum LocalVAD {
    // 30 ms windows at 16 kHz = 480 samples per window. Short enough
    // to catch the start/end of a word, long enough that per-window
    // RMS isn't dominated by a single sample's jitter.
    static let windowSamples = 480
    static let sampleRate: Double = 16_000

    /// Default hangover and threshold multiplier. `processForUpload`
    /// uses these; `analyze(...)` overrides them for live tuning in
    /// the debug preview.
    static let defaultThresholdMultiplier: Double = 3.0
    static let defaultHangoverSec: Double = 0.3

    /// Merge speech regions separated by a short silence — shorter
    /// intra-sentence pauses aren't worth slicing out, and cutting
    /// them produces choppy audio that hurts ASR accuracy.
    private static let mergeGapSec: Double = 0.3

    /// Hard floor on the speech threshold so pristine studio
    /// recordings (near-zero noise) don't get tagged as 100 % speech.
    private static let thresholdMinimum: Double = 150.0

    /// If total speech is below this, bail — probably a misdetection
    /// on a very quiet clip and uploading the original is safer than
    /// a 0-second splice.
    private static let minSpeechSec: Double = 0.5

    /// If trimming would save less than 10 % of the duration (and at
    /// least 1 s), skip the re-encode. Re-encoding loses a tiny bit
    /// of fidelity, so only do it when there's a meaningful win.
    private static let minTrimFraction: Double = 0.1
    private static let minTrimSec: Double = 1.0

    // MARK: - Public API

    /// What `processForUpload` hands back when a trim actually ran:
    /// the m4a for the provider to consume, plus the speech ranges
    /// in the **original** timeline so the caller can remap provider
    /// timestamps via `remapToOriginal(_:ranges:)`.
    struct TrimResult {
        let url: URL
        let ranges: [VADReport.SpeechRange]
    }

    /// Returns a trimmed m4a + its speech ranges, or `nil` when the
    /// caller should upload the original file unchanged. The caller
    /// owns cleanup of the returned file.
    static func processForUpload(source: URL) async -> TrimResult? {
        do {
            let report = try await analyze(source: source)
            guard report.speechDuration >= minSpeechSec else {
                log.info("VAD: no meaningful speech, falling back to original")
                return nil
            }
            let saved = report.savedDuration
            guard saved >= max(report.totalDuration * minTrimFraction, minTrimSec) else {
                let msg = String(format: "VAD: trim %.2fs not worth re-encode, using original", saved)
                log.info("\(msg, privacy: .public)")
                return nil
            }
            let asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
            let out = try await stitchAndExport(track: track, ranges: report.ranges)
            let msg = String(format: "VAD: %.2fs -> %.2fs", report.totalDuration, report.speechDuration)
            log.info("\(msg, privacy: .public) at \(out.lastPathComponent, privacy: .public)")
            return TrimResult(url: out, ranges: report.ranges)
        } catch {
            log.warning("VAD failed, falling back to original: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Maps an offset on the trimmed timeline (what the ASR provider
    /// reports) back to the original clip timeline. The ranges are
    /// concatenated in order on the trimmed side, so this is a
    /// piecewise-linear mapping: walk ranges accumulating durations
    /// until the one that contains `trimmedTime`, then offset from
    /// its `start`. Offsets past the end of speech clamp to the last
    /// range's `end` (shouldn't normally occur — guards against
    /// provider rounding slop at the tail).
    static func remapToOriginal(
        _ trimmedTime: Double, ranges: [VADReport.SpeechRange]
    ) -> Double {
        guard !ranges.isEmpty else { return trimmedTime }
        var cumulative: Double = 0
        for r in ranges {
            let dur = r.end - r.start
            if trimmedTime <= cumulative + dur {
                return r.start + max(0, trimmedTime - cumulative)
            }
            cumulative += dur
        }
        return ranges.last?.end ?? trimmedTime
    }

    /// Decode + threshold the clip and return the full report
    /// (per-window RMS, noise floor, threshold, merged speech
    /// ranges). Used by the debug preview to render a waveform with
    /// live threshold tuning. Heavy lifting runs on a detached task
    /// so the caller's actor (typically @MainActor) stays responsive.
    static func analyze(
        source: URL,
        thresholdMultiplier: Double = defaultThresholdMultiplier,
        hangoverSec: Double = defaultHangoverSec
    ) async throws -> VADReport {
        // ⚠️ Detached tasks **do not inherit the caller’s cancellation**. Previously this used `.value` directly,
// so when the caller (e.g., entering the VAD preview page or dragging the slider) cancelled the outer task, the detached decoder would still process the entire file — a 3‑hour recording accessed six times results in six full decodings running concurrently: device heating, UI freeze, and even the waveform never renders.
// Use `withTaskCancellationHandler` to **manually forward** cancellation.
        let task = Task.detached(priority: .userInitiated) {
            try await performAnalyze(
                source: source,
                thresholdMultiplier: thresholdMultiplier,
                hangoverSec: hangoverSec
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Analysis

    private static func performAnalyze(
        source: URL, thresholdMultiplier: Double, hangoverSec: Double
    ) async throws -> VADReport {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw LocalVADError.noAudioTrack
        }
        let rms = try computeRMS(asset: asset, track: track)
        let windowDur = Double(windowSamples) / sampleRate

        // Duration should be based on **the actual number of decoded samples**, not the value reported by AVAsset.
// Device recordings are Ogg/Opus; AVFoundation cannot provide a reliable duration for this container (the duration isn’t in the header and is only known after the last page) — elsewhere we have `OpusOgg.duration`, which parses Ogg pages directly.
// Getting 0 or NaN here causes the entire silence‑removal feature to silently fail: `expandAndMerge` clamps each speech segment to zero length → `speechDuration` becomes 0 → `processForUpload` treats it as “no speech” and skips trimming. This matches the QA report of “enabling pre‑upload silence removal has no effect at all”.
        var totalDur = Double(rms.count) * windowDur
        if totalDur <= 0 {
            let reported = (try? await asset.load(.duration).seconds) ?? 0
            totalDur = reported.isFinite ? reported : 0
        }

        guard !rms.isEmpty else {
            log.warning("VAD: decoder produced no samples for \(source.lastPathComponent, privacy: .public) — trimming will be skipped")
            return VADReport(
                rms: [], windowDur: windowDur,
                noiseFloor: 0, threshold: 0,
                thresholdMultiplier: thresholdMultiplier,
                hangoverSec: hangoverSec,
                ranges: [], totalDuration: totalDur
            )
        }

        // Adaptive threshold: noise floor = 10th-percentile RMS;
        // speech threshold = floor × multiplier, with a hard minimum
        // so pristine recordings don't read as 100 % speech.
        let sorted = rms.sorted()
        let floor = sorted[sorted.count / 10]
        let threshold = max(floor * thresholdMultiplier, thresholdMinimum)

        let raw = rawSpeechRanges(rms: rms, windowDur: windowDur, threshold: threshold)
        let merged = expandAndMerge(
            ranges: raw, totalDur: totalDur, hangoverSec: hangoverSec
        )

        return VADReport(
            rms: rms, windowDur: windowDur,
            noiseFloor: floor, threshold: threshold,
            thresholdMultiplier: thresholdMultiplier,
            hangoverSec: hangoverSec,
            ranges: merged, totalDuration: totalDur
        )
    }

    private static func computeRMS(asset: AVURLAsset, track: AVAssetTrack) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw LocalVADError.readerSetupFailed }
        reader.add(output)
        guard reader.startReading() else { throw LocalVADError.readerSetupFailed }

        var rms: [Double] = []
        let windowBytes = windowSamples * 2
        var leftover = Data()

        while reader.status == .reading, let sb = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sb) }
            // Cancellation must be checked **inside the decoding loop** — otherwise `cancel()` only sets a flag,
            // and the entire file will still be read (a multi‑hour recording becomes a few seconds of full‑load decoding).
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0
            var dataPtr: UnsafeMutablePointer<Int8>?
            let err = CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &len, dataPointerOut: &dataPtr
            )
            guard err == kCMBlockBufferNoErr, let dataPtr else { continue }
            leftover.append(Data(bytes: dataPtr, count: len))
            // Process every complete window in one pass, then drop the
            // consumed prefix ONCE. Calling removeFirst(windowBytes) per
            // window is O(n) each (Data shifts the tail), making the whole
            // RMS pass O(n²) — that stalls multi-hour clips (the reason
            // transcription of 2h+ audio fell over). Index through the
            // buffer instead and compact once per sample buffer.
            var consumed = 0
            while leftover.count - consumed >= windowBytes {
                let start = leftover.startIndex + consumed
                let window = leftover[start ..< start + windowBytes]
                rms.append(windowRMS(window))
                consumed += windowBytes
            }
            if consumed > 0 { leftover.removeFirst(consumed) }
        }
        if reader.status == .failed { throw reader.error ?? LocalVADError.readerSetupFailed }
        return rms
    }

    private static func rawSpeechRanges(
        rms: [Double], windowDur: Double, threshold: Double
    ) -> [VADReport.SpeechRange] {
        var ranges: [VADReport.SpeechRange] = []
        var start: Double?
        for (i, v) in rms.enumerated() {
            let t = Double(i) * windowDur
            if v >= threshold {
                if start == nil { start = t }
            } else if let s = start {
                ranges.append(.init(start: s, end: t))
                start = nil
            }
        }
        if let s = start {
            ranges.append(.init(start: s, end: Double(rms.count) * windowDur))
        }
        return ranges
    }

    private static func expandAndMerge(
        ranges: [VADReport.SpeechRange], totalDur: Double, hangoverSec: Double
    ) -> [VADReport.SpeechRange] {
        let expanded = ranges.map {
            VADReport.SpeechRange(
                start: max(0, $0.start - hangoverSec),
                end: min(totalDur, $0.end + hangoverSec)
            )
        }
        var merged: [VADReport.SpeechRange] = []
        for r in expanded {
            if let last = merged.last, r.start <= last.end + mergeGapSec {
                merged[merged.count - 1] = .init(
                    start: last.start, end: max(last.end, r.end)
                )
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    private static func windowRMS(_ data: Data) -> Double {
        let count = data.count / 2
        guard count > 0 else { return 0 }
        return data.withUnsafeBytes { raw -> Double in
            let ptr = raw.bindMemory(to: Int16.self)
            var sum: Double = 0
            for i in 0..<count {
                let v = Double(ptr[i])
                sum += v * v
            }
            return (sum / Double(count)).squareRoot()
        }
    }

    // MARK: - Stitch & export

    private static func stitchAndExport(
        track: AVAssetTrack, ranges: [VADReport.SpeechRange]
    ) async throws -> URL {
        let comp = AVMutableComposition()
        guard let compTrack = comp.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LocalVADError.exportFailed("composition track init failed")
        }
        let timescale: CMTimeScale = 44_100
        var cursor = CMTime.zero
        for r in ranges {
            let start = CMTime(seconds: r.start, preferredTimescale: timescale)
            let dur = CMTime(seconds: r.end - r.start, preferredTimescale: timescale)
            try compTrack.insertTimeRange(
                CMTimeRange(start: start, duration: dur),
                of: track, at: cursor
            )
            cursor = cursor + dur
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vad-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(
            asset: comp, presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw LocalVADError.exportFailed("export session init failed")
        }
        session.outputURL = outURL
        session.outputFileType = .m4a
        // Put the `moov` atom at the head of the file. Without this
        // AVAssetExportSession writes it last, and Azure's decoder only
        // scans the first ~10 MB for it — a trimmed clip past that size
        // then fails with 422 InvalidAudioFormat.
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        switch session.status {
        case .completed:
            return outURL
        case .failed:
            throw LocalVADError.exportFailed(session.error?.localizedDescription ?? "export failed")
        case .cancelled:
            throw LocalVADError.exportFailed("cancelled")
        default:
            throw LocalVADError.exportFailed("unexpected state \(session.status.rawValue)")
        }
    }
}
