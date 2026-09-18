import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "clipstore")

/// Store a recording artifact that is **already playable**.
///
/// Why `PostDownload.process` can't simply be reused: that function's input contract is "**raw device-side bytes**",
/// and it dispatches on the **file name suffix** (`.opus` + `OggS` magic → as-is; `.opus` otherwise → wrap bare Opus frames
/// in an Ogg envelope; `.wav` + `RIFF` → as-is). TicNote's artifact suffix is `.ogg`,
/// and falling into that dispatch ends at the last line `return .raw(_, .wavWithoutHeader)` ——
/// so the file is treated as "something that can't be stored" and left in `audioDir`, invisible and unplayable in the recording library.
///
/// Rather than modify `PostDownload` (D·NOTE uses that path, and touching it means re-verifying D·NOTE),
/// it's better to open a separate, explicit path for "**already a finished container**": go straight into `decryptedDir`
/// (the semantics of that directory are "files that can be handed directly to the player").
enum RecorderClipStore {

    /// Artifact suffix → which existing `PostDownload` branch it is equivalent to.
    ///
    /// Why a table rather than `if ext == "ogg"`: this decision determines **where the file goes**,
    /// and when a new kind of card is added later (say one that hands out m4a directly), it's worth being forced to think once about "is it finished or pre-finished".
    static func isReadyContainer(_ fileExtension: String) -> Bool {
        ["ogg", "opus", "wav", "m4a", "mp3"].contains(fileExtension.lowercased())
    }

    /// Land a `RecorderClip` into `decryptedDir` and return the playable file URL.
    ///
    /// ⚠️ **Does not share a file name space** with D·NOTE artifacts: D·NOTE names come from the card (timestamp style),
    /// while names here are given by the caller (see `suggestedName(for:)`). Both are written under
    /// `decryptedDir`, so the naming must carry a protocol prefix to avoid "two devices each record one on the same day,
    /// names collide → the later write overwrites the earlier one".
    @discardableResult
    static func store(_ clip: RecorderClip, name: String) throws -> URL {
        guard isReadyContainer(clip.fileExtension) else {
            throw RecorderLinkError.malformed(
                "\(clip.fileExtension) is not a ready-to-play container"
            )
        }
        try FileManager.default.createDirectory(
            at: StorageLocations.decryptedDir,
            withIntermediateDirectories: true
        )
        let url = StorageLocations.decryptedDir.appendingPathComponent(name)
        try clip.data.write(to: url, options: .atomic)
        log.info("stored \(clip.byteCount, privacy: .public) B as \(name, privacy: .public)")
        return url
    }

    /// Suggested on-disk file name.
    ///
    /// Shape: `<protocol>_<start time>_<sessionId in hex>.<suffix>`
    ///   · **Protocol prefix**: prevents name collisions with D·NOTE artifacts (see above);
    ///   · **Start time**: human-readable and sort-friendly;
    ///   · **sessionId**: the timestamp is affected by the card's RTC offset, while the sessionId is a stable key given by the card itself
    ///     —— keeping only the time would lose the fact of "which recording this is".
    ///
    /// The time is formatted in the **local time zone**: the card's RTC is set by the time-sync command (`0x04`) from the phone's time,
    /// so its "local time" is the user's local time and shouldn't be shown in UTC again.
    static func suggestedName(
        protocolID: String,
        startedAt: Date?,
        sessionID: UInt32?,
        fileExtension: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = startedAt.map { formatter.string(from: $0) } ?? "unknown"
        let sid = sessionID.map { String(format: "%08X", $0) } ?? "nosid"
        return "\(protocolID)_\(stamp)_\(sid).\(fileExtension)"
    }
}
