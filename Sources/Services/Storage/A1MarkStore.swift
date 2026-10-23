import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "a1.marks")

// MARK: - "Remark" marks made on the DingTalk A1 while recording
//
// ## What this is
//
// Mid-recording, the card's button produces `AUDIO_CONTROL_REMARK_BUTTON_CLICK`
// (`0x0B000001`) — the gesture that makes DingTalk drop a marker into the recording ("mark").
// The card stamps the event with its **own** clock, so the offset from `AUDIO_RECORD_START`
// is exact even when the report is delivered in a batch seconds later.
//
// ## Two storage shapes, on purpose
//
// * **Before download** a mark has no clip on the phone at all — only the card's `fid` exists.
//   So marks are first kept in one small JSON indexed by `fid`.
// * **After download** the clip has a name and a base; the marks are copied next to it as
//   `<base>.marks.json`, which is what the detail page reads.
//
// Keeping both means a mark survives either order ("record → download later" and
// "record → mark → download in the same session"), and deleting the clip deletes its marks
// with it — the sidecar is a clip artefact, not a hidden global database.

struct A1Mark: Codable, Equatable {
    /// Seconds from the start of that recording.
    let offset: TimeInterval
    /// When the press happened, in the phone's clock — only used for display/sorting.
    let at: Date
}

enum A1MarkStore {

    /// `{ "1792306652": [ {"offset": 12.4, "at": "…"}, … ] }`
    ///
    /// Lives next to the download manifest rather than in the container root: it is bookkeeping about
    /// device files (keyed by the card's `fid`), not a clip artefact.
    private static var indexURL: URL {
        StorageLocations.audioDir.appendingPathComponent(".a1-marks.json")
    }

    /// Where the clip sidecar goes — **the same directory as the clips themselves**.
    ///
    /// This is not cosmetic: `ClipTrash` restores every file of a group back into `decryptedDir`,
    /// so a sidecar stored anywhere else would either be left behind on delete or land in the wrong
    /// folder on restore. Same directory ⇒ trash/restore/rename all work with no special-casing.
    private static func sidecarURL(forClipBase base: String) -> URL {
        StorageLocations.decryptedDir.appendingPathComponent("\(base)\(ClipArtefact.marksSuffix)")
    }

    // MARK: Capture (before download)

    static func add(_ mark: A1Mark, toFile fid: UInt32) {
        var all = loadIndex()
        let key = String(fid)
        var list = all[key] ?? []
        // The card only reports whole seconds; two presses within the same second are the
        // same intent as far as a marker is concerned, but keeping both would draw two dots
        // on top of each other. Collapse < 1 s apart.
        if let last = list.last, abs(last.offset - mark.offset) < 1 { return }
        list.append(mark)
        all[key] = list
        saveIndex(all)
        log.info("mark \(mark.offset, format: .fixed(precision: 1))s on fid \(fid, privacy: .public) — \(list.count) total")
    }

    static func marks(forFile fid: UInt32) -> [A1Mark] {
        loadIndex()[String(fid)] ?? []
    }

    // MARK: Clip sidecar (after download)

    /// Copies a recording's marks next to its clip so the detail page can show them.
    /// Called once the download has produced `clipBase`, and again on "repair".
    static func writeSidecar(fid: UInt32, clipBase: String) {
        let marks = marks(forFile: fid)
        // Nothing to say ⇒ remove, don't leave a stale sidecar behind. A clip re-recorded under the same
        // name (the card reuses `fid`s after a wipe) would otherwise inherit the old marks forever.
        guard !marks.isEmpty else {
            removeSidecar(forClipBase: clipBase)
            return
        }
        let url = sidecarURL(forClipBase: clipBase)
        guard let data = try? JSONEncoder().encode(marks) else { return }
        do {
            try FileManager.default.createDirectory(
                at: StorageLocations.decryptedDir, withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            log.info("wrote \(marks.count) marks for \(clipBase, privacy: .public)")
        } catch {
            log.warning("mark sidecar write failed: \(error, privacy: .public)")
        }
    }

    /// What the detail page reads. Missing/failed → empty, never a placeholder.
    static func sidecar(forClipBase base: String) -> [A1Mark] {
        guard let data = try? Data(contentsOf: sidecarURL(forClipBase: base)),
              let marks = try? JSONDecoder().decode([A1Mark].self, from: data)
        else { return [] }
        return marks.sorted { $0.offset < $1.offset }
    }

    /// Mirrors `ClipArtefact`'s cleanup: removing a clip should not leave its sidecar behind.
    static func removeSidecar(forClipBase base: String) {
        try? FileManager.default.removeItem(at: sidecarURL(forClipBase: base))
    }

    /// The sidecar path, for callers that need to move it into the trash **together with the audio**.
    static func sidecarURLForTrash(clipBase: String) -> URL {
        sidecarURL(forClipBase: clipBase)
    }

    // MARK: Index plumbing

    private static func loadIndex() -> [String: [A1Mark]] {
        guard let data = try? Data(contentsOf: indexURL),
              let dict = try? JSONDecoder().decode([String: [A1Mark]].self, from: data)
        else { return [:] }
        return dict
    }

    private static func saveIndex(_ dict: [String: [A1Mark]]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
