import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "audio.export")

enum AudioExportError: LocalizedError {
    case noExportSession
    case exportFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noExportSession:
            // AVAssetExportSession's init returns nil when the asset isn't
            // readable or the preset isn't compatible. On iOS 16 that
            // happens for Ogg-Opus sources — the decoder landed in 17.
            return "Could not open this clip for export. iOS 16 can't read Opus; upgrade to iOS 17 or later."
        case .exportFailed(let msg):
            return msg
        case .cancelled:
            return "Export cancelled."
        }
    }
}

/// The audio containers the app can hand out.
enum AudioExportFormat: String, CaseIterable, Identifiable {
    /// AAC in an M4A container — small, widely playable, lossy.
    case m4a
    /// Raw 16-bit PCM in a RIFF/WAVE container — lossless and universally
    /// openable by transcription tools, at roughly 10× the size.
    ///
    /// There is no MP3 case on purpose: iOS ships no MP3 *encoder*
    /// (AVAssetWriter can't write one, and AVAssetExportSession has no MP3
    /// preset), so producing MP3 would mean bundling a LAME build. WAV and
    /// M4A cover both ends of the trade-off without a third-party codec.
    case wav

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .m4a: return "m4a"
        case .wav: return "wav"
        }
    }
}

enum AudioExporter {

    /// Transcodes `source` (any container AVFoundation can read — Ogg-Opus
    /// on iOS 17+, WAV on any iOS) to AAC in an M4A container via
    /// `AVAssetExportSession`. Writes to a fresh file under the app's
    /// temporary directory; iOS purges `tmp/` on its own, and the
    /// returned URL should be handed straight to a share sheet.
    static func exportAsM4A(source: URL, suggestedName: String) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suggestedName).m4a")
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioExportError.noExportSession
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a
        // `moov` atom up front so the shared file streams (and re-imports
        // into the app, which routes it back through ASR).
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }

        switch session.status {
        case .completed:
            log.info("exported \(source.lastPathComponent, privacy: .public) -> \(outputURL.lastPathComponent, privacy: .public)")
            return outputURL
        case .cancelled:
            throw AudioExportError.cancelled
        case .failed:
            let msg = session.error?.localizedDescription ?? "Export failed"
            log.error("export failed: \(msg, privacy: .public)")
            throw AudioExportError.exportFailed(msg)
        default:
            throw AudioExportError.exportFailed("Unexpected export state")
        }
    }

    /// Decodes `source` to 16-bit PCM and writes a RIFF/WAVE container.
    ///
    /// Deliberately hand-rolled rather than routed through
    /// `AVAssetExportSession`: there is no WAV export preset, and
    /// `AVAssetWriter` cannot write a `.wav` file type. The decode itself is
    /// AVFoundation's (`AVAssetReader` + a linear-PCM output), so this only
    /// owns the 44-byte header.
    ///
    /// The whole transcode runs on a detached task: `AVAssetReader`'s copy
    /// loop is synchronous, and a 30-minute clip would otherwise block the
    /// main thread for the duration.
    static func exportAsWAV(source: URL, suggestedName: String) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suggestedName).wav")

        let work = Task.detached(priority: .userInitiated) { () throws -> URL in
            try await transcodeToPCM(source: source, outputURL: outputURL)
        }
        return try await work.value
    }

    /// Dispatch helper so callers don't have to know which format is which.
    static func export(_ format: AudioExportFormat, source: URL, suggestedName: String) async throws -> URL {
        switch format {
        case .m4a: return try await exportAsM4A(source: source, suggestedName: suggestedName)
        case .wav: return try await exportAsWAV(source: source, suggestedName: suggestedName)
        }
    }

    // MARK: - PCM / RIFF

    private static func transcodeToPCM(source: URL, outputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioExportError.noExportSession
        }
        guard let track = audioTracks.first else {
            throw AudioExportError.exportFailed("This file has no audio track to export.")
        }

        let description = await currentFormat(track)
        let sampleRate = description.sampleRate
        let channels = description.channels
        guard sampleRate > 0, channels > 0 else {
            throw AudioExportError.exportFailed("Could not read the recording's audio format.")
        }

        // Match the source's own rate and channel count: resampling here
        // would add nothing but a second generation of artefacts.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioExportError.noExportSession
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw AudioExportError.exportFailed("Could not decode this clip to PCM.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioExportError.exportFailed(reader.error?.localizedDescription ?? "Could not start reading the clip.")
        }

        try? FileManager.default.removeItem(at: outputURL)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw AudioExportError.exportFailed("Could not create the output file.")
        }
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        // Reserve the header, stream the samples, then seek back and patch
        // in the real sizes. Sizes aren't known until the reader is done.
        try handle.write(contentsOf: riffHeader(dataBytes: 0, sampleRate: sampleRate, channels: channels))
        var dataBytes = 0

        while reader.status == .reading {
            if Task.isCancelled {
                reader.cancelReading()
                try? FileManager.default.removeItem(at: outputURL)
                throw AudioExportError.cancelled
            }
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sample) }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }

            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var chunk = Data(count: length)
            let copied: OSStatus = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            guard copied == noErr else {
                reader.cancelReading()
                try? FileManager.default.removeItem(at: outputURL)
                throw AudioExportError.exportFailed("Could not read audio samples (OSStatus \(copied)).")
            }
            try handle.write(contentsOf: chunk)
            dataBytes += length
        }

        if reader.status == .failed {
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioExportError.exportFailed(reader.error?.localizedDescription ?? "Reading the clip failed.")
        }
        guard dataBytes > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioExportError.exportFailed("The clip decoded to no audio.")
        }

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: riffHeader(dataBytes: dataBytes, sampleRate: sampleRate, channels: channels))

        log.info("""
        exported PCM \(source.lastPathComponent, privacy: .public) -> \
        \(dataBytes, privacy: .public) bytes @ \(sampleRate, privacy: .public) Hz / \(channels, privacy: .public) ch
        """)
        return outputURL
    }

    /// 44-byte canonical RIFF/WAVE header for 16-bit PCM.
    ///
    /// Internal rather than private so the byte layout can be asserted
    /// directly — a wrong byte order here produces a file that looks fine
    /// until something tries to open it.
    static func riffHeader(dataBytes: Int, sampleRate: Double, channels: Int) -> Data {
        let bitsPerSample = 16
        // Clamp before the casts: an unexpected sample rate or channel count
        // from a malformed stream must not trap on `UInt16(...)`.
        let channelCount = UInt16(clamping: channels)
        let blockAlign = Int(channelCount) * bitsPerSample / 8
        let rate = UInt32(max(1, min(sampleRate.rounded(), 384_000)))
        let byteRate = UInt32(clamping: Int(rate) * blockAlign)
        let clamped = max(0, min(dataBytes, Int(UInt32.max) - 36))

        var data = Data(capacity: 44)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian(UInt32(36 + clamped)))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        data.append(littleEndian(UInt32(16)))          // PCM fmt chunk size
        data.append(littleEndian(UInt16(1)))           // wFormatTag = PCM
        data.append(littleEndian(channelCount))
        data.append(littleEndian(rate))
        data.append(littleEndian(byteRate))
        data.append(littleEndian(UInt16(clamping: blockAlign)))
        data.append(littleEndian(UInt16(bitsPerSample)))

        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian(UInt32(clamped)))
        return data
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private static func littleEndian(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Sample rate and channel count of the source track, read from its
    /// `AudioStreamBasicDescription`. Falls back to the track's natural
    /// time scale, which for audio is the sample rate.
    private static func currentFormat(_ track: AVAssetTrack) async -> (sampleRate: Double, channels: Int) {
        if let descriptions = try? await track.load(.formatDescriptions),
           let description = descriptions.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            let format = asbd.pointee
            if format.mSampleRate > 0, format.mChannelsPerFrame > 0 {
                return (format.mSampleRate, Int(format.mChannelsPerFrame))
            }
        }
        let scale = (try? await track.load(.naturalTimeScale)) ?? 0
        return (Double(scale), 1)
    }
}
