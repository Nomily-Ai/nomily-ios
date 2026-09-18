import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "audio.merge")

enum AudioMergeError: LocalizedError {
    case noAudioTrack
    case exportFailed(String)
    case cancelled
    case unknownDuration(String)
    case truncated(expected: Double, actual: Double)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            // iOS 16 hits this for .opus sources (Opus decode is iOS 17+);
            // same limitation as export. Tell the user clearly.
            return "Couldn't read one of the clips. iOS 16 can't decode Opus; upgrade to iOS 17 or later."
        case .exportFailed(let msg):
            return msg
        case .cancelled:
            return "Merge cancelled."
        case .unknownDuration(let name):
            return "Couldn't determine how long \(name) is, so the clips weren't merged. Nothing was deleted."
        case .truncated(let expected, let actual):
            return String(
                format: "The merged clip came out %.1fs instead of %.1fs, so it was discarded. Nothing was deleted.",
                actual, expected
            )
        }
    }
}

enum AudioMerger {
    /// Merges two clips in chronological order (older first, newer
    /// second) into a single M4A (AAC) file via AVMutableComposition
    /// + AVAssetExportSession. Transcripts are intentionally NOT carried
    /// over — the merged clip starts with no transcript so the user
    /// re-transcribes it (qg96jrp).
    ///
    /// Callers should delete the source clips + their artefacts after
    /// a successful return. Returns the merged clip's filename (e.g.
    /// `20260115123456+20260115124012.m4a`).
    static func merge(older: LibraryItem, newer: LibraryItem) async throws -> String {
        guard let olderURL = older.url, let newerURL = newer.url else {
            throw AudioMergeError.noAudioTrack
        }
        let olderAsset = AVURLAsset(url: olderURL)
        let newerAsset = AVURLAsset(url: newerURL)

        guard let olderTrack = try await olderAsset.loadTracks(withMediaType: .audio).first,
              let newerTrack = try await newerAsset.loadTracks(withMediaType: .audio).first else {
            throw AudioMergeError.noAudioTrack
        }

        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioMergeError.noAudioTrack
        }

        // ⚠️ **Do not trust `load(.duration)` directly**: device recordings are Ogg‑Opus, which have no duration in the container header, so AVFoundation returns 0 or NaN (the same pitfall previously broke local VAD silence detection, see LocalVAD).
// Getting 0 here has worse consequences: `insertTimeRange` would insert an empty segment, the export would still report “success”,
// and the caller (`LibraryView.runMerge`) would then **delete both source recordings** after success —
// leaving the user with a corrupted merged file in place of two real recordings.
// Therefore: first probe the true duration; if unavailable, **reject the merge**, never producing an ambiguous file.
        let olderDuration = try await Self.reliableDuration(of: olderAsset, at: olderURL)
        let newerDuration = try await Self.reliableDuration(of: newerAsset, at: newerURL)
        try compTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: olderDuration),
            of: olderTrack, at: .zero
        )
        try compTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: newerDuration),
            of: newerTrack, at: olderDuration
        )

        // Name the merged file after BOTH source clips so it's clear which
        // two were combined (w88rqmo).
        let olderStem = (older.name as NSString).deletingPathExtension
        let newerStem = (newer.name as NSString).deletingPathExtension
        let outputURL = AudioImporter.uniqueDestination(
            in: StorageLocations.decryptedDir,
            originalName: "\(olderStem)+\(newerStem).m4a"
        )

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioMergeError.exportFailed("Could not create export session")
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a
        // `moov` atom up front — the merged clip is a transcription input
        // and Azure only scans the first ~10 MB for it.
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }

        switch session.status {
        case .completed:
            break
        case .cancelled:
            throw AudioMergeError.cancelled
        case .failed:
            let msg = session.error?.localizedDescription ?? "Merge failed"
            log.error("merge failed: \(msg, privacy: .public)")
            throw AudioMergeError.exportFailed(msg)
        default:
            throw AudioMergeError.exportFailed("Unexpected merge state")
        }

        try await verifyMerged(outputURL, expected: olderDuration + newerDuration)

        let mergedName = outputURL.lastPathComponent
        // Transcripts are intentionally NOT carried into the merged clip
        // (qg96jrp): the merged audio starts with a clean slate so the user
        // re-transcribes it, rather than inheriting stale per-half transcript
        // data. The source clips + their artefacts are removed by the caller.

        // Park the merged file's mtime at the newer half's mtime so the
        // Library's newest-first sort keeps it in the same slot the pair
        // used to occupy. Without this, the merge would bubble to the top
        // (mtime = now), stranding the rest of the original sequence —
        // three-clip chains like A+B+C couldn't be merged incrementally
        // because the A+B result would no longer live next to C.
        try? FileManager.default.setAttributes(
            [.modificationDate: newer.modifiedAt],
            ofItemAtPath: outputURL.path
        )

        log.info("merged \(older.name, privacy: .public) + \(newer.name, privacy: .public) -> \(mergedName, privacy: .public)")
        return mergedName
    }

    /// How long a single audio track actually is — **do not trust `AVAsset.duration`**.
    ///
    /// Ogg‑Opus duration isn’t stored in the container header, so AVFoundation returns 0/NaN. The library already performs a dedicated `OpusOgg.duration` page scan (`LibraryView.probeDuration`) for this,
// but the merge path still uses AVAsset’s value. If both are unavailable, throw an error,
// **prefer not merging rather than producing a file of indeterminate length** — the caller will delete the source files after success.
    private static func reliableDuration(of asset: AVURLAsset, at url: URL) async throws -> CMTime {
        if let reported = try? await asset.load(.duration),
           reported.isValid, reported.seconds.isFinite, reported.seconds > 0 {
            return reported
        }
        if let probed = OpusOgg.duration(ofOggOpusAt: url), probed > 0 {
            log.info("duration probe fallback for \(url.lastPathComponent, privacy: .public): \(probed)s")
            return CMTime(seconds: probed, preferredTimescale: 44_100)
        }
        throw AudioMergeError.unknownDuration(url.lastPathComponent)
    }

    /// After export, **read back the actual length** once before reporting completion.
    ///
    /// This step isn’t redundant caution: after `runMerge` succeeds, the two source recordings are immediately deleted,
    // so if the exporter reports “success” but outputs a truncated file, the user ends up swapping two real recordings for a broken one.
    // Allow a 1.5 s tolerance — AAC aligns to frames, leaving a tiny padding at the end.
    private static func verifyMerged(_ url: URL, expected: CMTime) async throws {
        let asset = AVURLAsset(url: url)
        let actual = (try? await asset.load(.duration).seconds) ?? 0
        let want = expected.seconds
        guard actual.isFinite, actual > 0, abs(actual - want) <= 1.5 else {
            try? FileManager.default.removeItem(at: url)
            throw AudioMergeError.truncated(expected: want, actual: actual.isFinite ? actual : 0)
        }
    }
}
