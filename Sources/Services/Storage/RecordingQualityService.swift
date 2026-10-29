import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "quality")

/// ★ 2026-10-29（饭耳移植 · 规格 §2.2 录音质量 + 冷数据降级）
///
/// Four bitrate tiers (the spec's sizes are speech-AAC approximations —
/// "原样 29MB/h" is what 64 kbps mono already costs us) plus the cold-data
/// downgrade pass: recordings older than N days get re-encoded in place to the
/// selected tier, **after** their transcript exists. Original quality is what
/// transcription runs against; the downgrade only ever trades playback
/// fidelity the user explicitly opted out of.
///
/// Safety rails, all deliberate:
///   · Never touch a clip whose transcript hasn't landed — transcription is
///     the reason the audio is kept at full fidelity in the first place.
///   · Skip when the current effective bitrate is already within ~15% of the
///     target (re-encoding an already-small file costs time, saves nothing).
///   · Transcode to a temp file first and only replace the original when the
///     result is genuinely smaller — a failed or degenerate encode must never
///     be able to destroy the source.
///   · `asIs` (the default) means the pass is a no-op entirely.
enum RecordingQualityTier: String, CaseIterable, Codable, Identifiable {

    case asIs       // 原样 — no re-encode
    case standard   // 标准 ~15MB/h
    case compact    // 省空间 ~11MB/h (spec: 不建议)
    case minimal    // 最省 ~8MB/h  (spec: 极度不建议)

    var id: String { rawValue }

    /// Target mono-AAC bitrate (bps), picked so the *resulting* size per hour
    /// lands near the spec's published figures (bitrate × 3600 ÷ 8⁴…): 32 kbps
    /// ≈ 14 MB/h, 24 kbps ≈ 10 MB/h, 16 kbps ≈ 7 MB/h.
    var targetBitrate: Int? {
        switch self {
        case .asIs: return nil
        case .standard: return 32_000
        case .compact: return 24_000
        case .minimal: return 16_000
        }
    }

    /// "约 29MB/小时" — shown in the picker; `asIs` carries the measured default.
    var sizePerHourLabel: String {
        switch self {
        case .asIs: return "约 29MB/小时"
        case .standard: return "约 15MB/小时"
        case .compact: return "约 11MB/小时"
        case .minimal: return "约 8MB/小时"
        }
    }

    /// Spec's recommendation marks: nil for the neutral tiers.
    var recommendationLabel: String? {
        switch self {
        case .asIs: return nil
        case .standard: return nil
        case .compact: return "不建议"
        case .minimal: return "极度不建议"
        }
    }
}

@MainActor
final class RecordingQualityService: ObservableObject {

    static let shared = RecordingQualityService()
    private init() {}

    /// True while the downgrade pass is running (drives the settings button).
    @Published var isRunning = false
    /// Human-readable result of the last pass, shown under the button.
    @Published var lastReport: String?

    /// The cold-data pass. Called at launch (when the switch is on) and from
    /// the "run now" button (`ignoreSwitch` for the button so a user can run it
    /// without leaving the toggle on).
    func runDowngrade(config: AppConfig, ignoreSwitch: Bool = false) async {
        guard let tierRaw = config.recordingQualityTier,
              let tier = RecordingQualityTier(rawValue: tierRaw),
              tier != .asIs
        else { return }
        guard ignoreSwitch || config.coldDataDowngradeEnabled else { return }

        isRunning = true
        defer { isRunning = false }

        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        let audioExtensions: Set<String> = ["m4a", "aac", "wav", "caf", "mp3", "aif", "aiff", "flac", "opus"]
        let cutoff = Date().addingTimeInterval(-Double(config.coldDataDowngradeDays) * 86_400)

        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let candidates = names
            .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .filter { name in
                // Cold means old by modification date — a clip re-downloaded
                // yesterday is not cold no matter when it was recorded.
                let path = dir.appendingPathComponent(name).path
                let attrs = try? fm.attributesOfItem(atPath: path)
                let modified = attrs?[.modificationDate] as? Date ?? .distantPast
                return modified < cutoff
            }
            .filter { name in
                // Transcript must exist first — see the class comment.
                let base = (name as NSString).deletingPathExtension
                return fm.fileExists(atPath: dir.appendingPathComponent("\(base).txt").path)
            }
            .sorted()

        guard !candidates.isEmpty else {
            lastReport = L10n.RecordingsSettings.qualityNothingCold
            return
        }

        var done = 0
        var skipped = 0
        for name in candidates {
            let url = dir.appendingPathComponent(name)
            do {
                if try await Self.transcodeToTier(url: url, tier: tier) {
                    done += 1
                } else {
                    skipped += 1
                }
            } catch {
                log.error("transcode failed for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                skipped += 1
            }
        }
        lastReport = L10n.RecordingsSettings.qualityReport(done, skipped)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    // MARK: - Audition (规格 §2.2 每档试听)

    /// Transcode `source` down to `tier` into the Caches directory — the
    /// "试听" path. Never touches the library: the result is a preview copy
    /// keyed by clip+tier, reused on repeated taps.
    nonisolated static func makeAudition(source: URL, tier: RecordingQualityTier) async throws -> URL {
        guard let bitrate = tier.targetBitrate else { return source }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("quality-audition", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let base = (source.lastPathComponent as NSString).deletingPathExtension
        let dst = cache.appendingPathComponent("\(base)-\(tier.rawValue).m4a")
        if FileManager.default.fileExists(atPath: dst.path) { return dst }
        try await Self.encode(input: source, output: dst, bitrate: bitrate)
        return dst
    }

    /// The most recently modified clips (audition source pool, newest first).
    nonisolated static func recentClips(limit: Int = 20) -> [URL] {
        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        let audioExtensions: Set<String> = ["m4a", "aac", "wav", "caf", "mp3", "aif", "aiff", "flac", "opus"]
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .compactMap { name -> (URL, Date)? in
                let url = dir.appendingPathComponent(name)
                let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
                return (url, modified ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Re-encode (nonisolated — all heavy work off the main actor)

    /// Re-encode `url` in place to `tier`'s bitrate. Returns true when the file
    /// was replaced, false when it was skipped (already small / encode not
    /// smaller). Throws only on hard failures; the original is never destroyed
    /// by a failed encode.
    nonisolated static func transcodeToTier(url: URL, tier: RecordingQualityTier) async throws -> Bool {
        guard let bitrate = tier.targetBitrate else { return false }
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int) ?? 0

        let asset = AVURLAsset(url: url)
        let durationSeconds: Double
        do {
            let duration = try await asset.load(.duration)
            durationSeconds = duration.seconds
        } catch {
            // Unreadable asset: leave it alone rather than retry forever.
            log.error("cannot read duration of \(url.lastPathComponent, privacy: .public)")
            return false
        }
        guard durationSeconds > 1 else { return false }

        // Current effective bitrate; within 15% of target ⇒ skip.
        let currentBitrate = Double(size) * 8.0 / durationSeconds
        if currentBitrate <= Double(bitrate) * 1.15 { return false }

        let tmp = fm.temporaryDirectory
            .appendingPathComponent("quality-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        defer { try? fm.removeItem(at: tmp) }

        try await Self.encode(input: url, output: tmp, bitrate: bitrate)

        let newSize = ((try? fm.attributesOfItem(atPath: tmp.path))?[.size] as? Int) ?? 0
        // Only replace when genuinely smaller — a "re-encode" that saved 5%
        // isn't worth a generation loss.
        guard newSize > 0, newSize < Int(Double(size) * 0.95) else { return false }
        _ = try fm.replaceItemAt(url, withItemAt: tmp)
        log.notice("downgraded \(url.lastPathComponent, privacy: .public): \(size) → \(newSize) bytes")
        return true
    }

    /// AVAssetReader (decode → mono 16 kHz PCM) → AVAssetWriter (AAC at the
    /// tier's bitrate). Speech content is what these clips are; 16 kHz mono is
    /// the telephony band and pairs with the low bitrates above.
    nonisolated private static func encode(input: URL, output: URL, bitrate: Int) async throws {
        let asset = AVURLAsset(url: input)
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard let track = audioTracks.first else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let reader = try AVAssetReader(asset: asset)
        let readSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16_000,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: readSettings)
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let writeSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitrate,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writeSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(writerInput)

        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let pumpDone = DispatchSemaphore(value: 0)
        let pumpQueue = DispatchQueue(label: "com.nomily.app.quality.pump")
        writerInput.requestMediaDataWhenReady(on: pumpQueue) {
            while writerInput.isReadyForMoreMediaData {
                if let sample = readerOutput.copyNextSampleBuffer() {
                    writerInput.append(sample)
                } else {
                    writerInput.markAsFinished()
                    pumpDone.signal()
                    break
                }
            }
        }
        pumpDone.wait()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        if writer.status != .completed {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        if reader.status == .failed {
            throw reader.error ?? CocoaError(.fileReadUnknown)
        }
    }
}
