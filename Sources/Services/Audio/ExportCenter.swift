import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "export")

/// The ledger + staging area for "the export is ready and waiting for you to share".
///
/// ## Why it's needed
/// The user's own words: **"exporting audio takes a very long time for large files ... it needs to run in the background, and also
/// let you tap transfer after the app finishes, so that leaving does not mean waiting all over again"**.
///
/// Look at it as two halves:
///
/// 1. **Hanging in the background** — that half is `BackgroundKeeper.acquire(.export)`'s job,
///    keeping the copy / re-encode from being suspended when the user switches away.
/// 2. **Come back after exiting and still be able to tap transfer** — that's this. The original staging directory was fixed at
///    `FileManager.default.temporaryDirectory/nomily-export`, with two problems:
///    * iOS can clear `tmp/` **at any time** (especially when the App isn't in the foreground), and if an export was ready
///      but not yet shared, the file is gone overnight — the user taps share and there's nothing;
///    * nothing records that "the last export succeeded", so coming back shows only an empty list
///      and the only choice is **waiting all over again**.
///
///    So the staging moves into the App container (`root`, not `tmp`), and "which one is ready"
///    is persisted. Coming back, you can just tap share without redoing it.
///
/// ## Only one copy is kept (**deliberately**)
/// Every new export deletes the previous one entirely. Reason: this is a **way station**, not user data —
/// what the user actually wants gets saved to "Files" or AirDropped from the share sheet. Keeping several would only
/// fill the phone up (twenty meeting recordings easily reach a few GB), and "the previous one" is of no
/// use to the user: what they want is always the batch they just ticked.
@MainActor
final class ExportCenter: ObservableObject {
    static let shared = ExportCenter()

    /// One export that is **ready and waiting to be shared**.
    struct Ready: Codable, Equatable, Identifiable {
        /// The staging directory name (which is also the identity). What gets shared is `stagingRoot/<id>`.
        var id: String
        /// The name given to this export in the UI ("3 recordings" / "Meeting notes").
        var title: String
        var itemCount: Int
        var bytes: Int64
        var createdAt: Date
        /// **Which recording this export came from** (a single export fills in `LibraryItem.name`,
        /// a batch export is nil).
        ///
        /// Why the distinction: the detail page only wants to surface the share entry when "this one was exported from this very recording".
        /// Without it, the user would see a "Share 3 recordings"
        /// button on the detail page — a batch with nothing to do with what's in front of them.
        var origin: String?

        var isBatch: Bool { origin == nil }
    }

    /// The one that's ready but hasn't been shared yet. `nil` = none.
    @Published private(set) var ready: Ready?

    /// Auto-cleared if it hasn't been shared after this long.
    ///
    /// 72 hours (three days): short enough that a few GB of transit files don't occupy space long-term, long enough to cover
    /// the most common span, "exported Friday before leaving work, come back Monday and send it". Real space management still
    /// relies on that explicit "Clean up" button in the UI — this is just a fuse.
    nonisolated static let retention: TimeInterval = 72 * 3600

    private init() {
        // `loadReady` also checks whether the directory still exists and whether it's expired (see the comment there).
        self.ready = Self.loadReady()
    }

    // MARK: - Location

    /// The staging root. **Inside the App container, not `tmp`** — see point 2 at the top of the type.
    ///
    /// The directory name has a leading dot: with `UIFileSharingEnabled` on it's invisible in the "Files" App,
    /// and the library scanner won't pick it up as material either.
    private static var stagingRoot: URL {
        StorageLocations.root.appendingPathComponent(".export-staging", isDirectory: true)
    }

    private static var indexURL: URL {
        stagingRoot.appendingPathComponent("ready.json")
    }

    // MARK: - Opening a new one

    /// Open a new staging directory and return it. **Also deletes the previous one** (see the note at the top of the type).
    func beginNewStaging() throws -> URL {
        let fm = FileManager.default
        // Clear the previous one (along with its record). Since the user started a new export,
        // the previous one isn't what they want any more.
        try? fm.removeItem(at: Self.stagingRoot)
        let dir = Self.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        ready = nil
        return dir
    }

    /// Record that "this one is ready".
    func publish(id: String, title: String, itemCount: Int, bytes: Int64, origin: String?) {
        let item = Ready(
            id: id,
            title: title,
            itemCount: itemCount,
            bytes: bytes,
            createdAt: Date(),
            origin: origin
        )
        ready = item
        Self.save(item)
        log.info("export ready: \(title, privacy: .public) (\(itemCount) item(s), \(bytes) bytes)")
    }

    // MARK: - Use / discard

    /// The on-disk path of this thing right now (returned only if it's still there).
    func url(for item: Ready) -> URL? {
        let url = Self.stagingRoot.appendingPathComponent(item.id, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Does this one belong to a recording? The detail page uses it to decide whether to show the share entry.
    func ready(forOrigin origin: String) -> Ready? {
        guard let ready, ready.origin == origin else { return nil }
        return url(for: ready) == nil ? nil : ready
    }

    /// The user finished sharing / explicitly cleaned up. Frees space.
    func discard() {
        guard let item = ready else { return }
        try? FileManager.default.removeItem(
            at: Self.stagingRoot.appendingPathComponent(item.id, isDirectory: true)
        )
        ready = nil
        Self.save(nil)
        log.info("export staging discarded: \(item.title, privacy: .public)")
    }

    /// How much transit data is left on disk (for the UI to show "how much a cleanup would free").
    var stagedBytes: Int64 { ready?.bytes ?? 0 }

    // MARK: - Disk

    private static func loadReady() -> Ready? {
        guard let data = try? Data(contentsOf: indexURL),
              let item = try? JSONDecoder().decode(Ready.self, from: data) else {
            // If the index exists, read it; if the index is broken/absent but the directory still has things in it — those are
            // orphans left by a previous version; clear them. No UI can reach them, they just take up space.
            try? FileManager.default.removeItem(at: stagingRoot)
            return nil
        }
        // Is the directory still there? (cleared by iOS / deleted by the user from "Files")
        let url = stagingRoot.appendingPathComponent(item.id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            log.notice("export staging gone from disk; dropping record")
            save(nil)
            return nil
        }
        // The expiry fuse. See `retention`.
        guard Date().timeIntervalSince(item.createdAt) < retention else {
            log.info("export staging expired; purging")
            try? FileManager.default.removeItem(at: url)
            save(nil)
            return nil
        }
        return item
    }

    private static func save(_ item: Ready?) {
        let fm = FileManager.default
        guard let item else {
            try? fm.removeItem(at: indexURL)
            return
        }
        do {
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(item)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            log.error("export index save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
