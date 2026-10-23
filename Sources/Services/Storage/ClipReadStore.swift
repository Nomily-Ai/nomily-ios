import Foundation

/// The single ledger for "have I seen this recording" — the entire basis for the red dot in the list.
///
/// ## Why not cram it into `Library`'s manifest
/// The manifest records "this one has already been downloaded from the device", which is a **download credential**: clearing it is a meaningful
/// operation (after clearing, the same one can be downloaded again). Whereas "read" is a **user preference**, and clearing it means a screen full
/// of red dots. The two differ entirely in lifetime, who changes them, and whether they can be lost — mixed into one table, sooner or later
/// a refactor wipes the read state along with it.
///
/// ## Why a single file rather than one `.seen` sidecar per entry
/// 1900 entries means 1900 extra files: one disk write every time a detail page opens, and `LibraryScanner`'s
/// directory fingerprint (newest mtime + entry count) jitters along with it — and one jitter invalidates the whole
/// knowledge-base search body cache. The whole JSON is only a few KB, and read/write is a single atomic overwrite.
///
/// ## ★ How "only mark newly arrived ones" is implemented
/// `origin` is the moment this feature **first ran**, written once and never moved. Entries whose arrival time is earlier than
/// `origin` are all treated as read — so there's no need to move the several thousand names that already existed into
/// `seen`, nor a one-off migration scan. The cost is that reinstalling the App resets `origin`,
/// at which point everything in the library is "read" (which is exactly the direction we want: better to under-mark
/// than to have a screen full of red dots).
@MainActor
final class ClipReadStore: ObservableObject {
    static let shared = ClipReadStore()

    /// The persisted names that were opened. **Only those arriving after `origin`** — old recordings are judged
    /// by `origin` and don't occupy space here.
    @Published private(set) var seen: Set<String> = []

    /// The moment this feature went live. `.distantFuture` until loading completes: better to first render a frame
    /// as "everything is read" than to flash a screen of red dots first.
    private var origin: Date = .distantFuture

    private let url: URL

    private struct Payload: Codable {
        var origin: Date
        var seen: [String]
    }

    private init() {
        url = StorageLocations.audioDir.appendingPathComponent(".seen.json")
        load()
    }

    /// Whether this one should show a red dot right now.
    ///
    /// - Parameter arrivedAt: the **arrival time** (`LibraryItem.modifiedAt`),
    ///   not the recording time. The criterion is "newly transferred in", so the persist-to-disk moment is used;
    ///   when the device's RTC is out of sync the recording time can be way off, and judging by it would mis-mark.
    func isUnread(name: String, arrivedAt: Date) -> Bool {
        guard arrivedAt >= origin else { return false }
        return !seen.contains(name)
    }

    /// The user has opened this one (appearing the detail page counts, no minimum dwell time).
    func markSeen(name: String) {
        guard !seen.contains(name) else { return }
        seen.insert(name)
        save()
    }

    /// Clear an entry's read record when it's deleted.
    ///
    /// Not clearing wouldn't error, but the table would grow forever with "delete then download again"; and a same-named file downloaded back
    /// would inexplicably carry "read", and the user would never see that red dot again.
    func forget(names: [String]) {
        let before = seen.count
        seen.subtract(names)
        if seen.count != before { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            // No file = this feature's first run. Everything on disk at this point counts as old.
            origin = Date()
            save()
            return
        }
        origin = payload.origin
        seen = Set(payload.seen)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Payload(origin: origin, seen: Array(seen)))
        else { return }
        try? FileManager.default.createDirectory(
            at: StorageLocations.audioDir, withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
