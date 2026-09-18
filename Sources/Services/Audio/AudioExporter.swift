import AVFoundation
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
}
