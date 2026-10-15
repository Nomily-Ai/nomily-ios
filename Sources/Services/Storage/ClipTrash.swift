import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "trash")

/// Trash: deleted recordings lie here for 30 days, then get cleared automatically.
///
/// ## Why it "moves house" rather than "making a note and deleting"
/// Actually moving the files into `.trash/<id>/` has the advantage that **deletion immediately frees the
/// "current library" space semantics** (lists, scans and stats no longer see it), while a restore can put it back
/// byte for byte. Conversely "mark it and leave it in place" would still have `LibraryScanner` scan it up,
/// so every deletion would need another exception in the scanner — miss one of those and something in the trash
/// leaks into the list.
///
/// ## Why the directory sits at `audioDir/.trash` rather than `decryptedDir`
/// `decryptedDir` is the directory the scanner walks, so stuffing things into it would rely on "skip hidden files"
/// as an implicit convention. Put it as a **sibling directory** and the scanner can't see it by nature, and the index file sits
/// right next to `.durations.json` / `.manifest.json`.
///
/// ## How the 30 days are implemented
/// There is no background task to hook onto, so `purgeExpired()` runs once at **app launch** and once when
/// **the trash is opened**. As long as the user still opens this app, expired items won't just sit there —
/// that is the strongest promise "auto-delete after 30 days" can make without BGTaskScheduler.
@MainActor
final class ClipTrash: ObservableObject {
    static let shared = ClipTrash()

    /// Protection period. The 30 days the user asked for.
    ///
    /// ⚠️ **It must be `nonisolated`**: `TrashedItem.expiry` is a computed property on a plain
    /// struct nested inside, it isn't on the main actor, and reading this `@MainActor`
    /// class's static value directly would report "main actor-isolated static property can not be
    /// referenced from a nonisolated context". It's only a constant; leaving it unisolated is more accurate.
    nonisolated static let retentionDays = 30

    @Published private(set) var items: [TrashedItem] = []

    // MARK: - Model

    struct TrashedItem: Codable, Identifiable, Equatable {
        /// Directory name, which is also `.trash/<id>/`.
        var id: String
        /// The original on-disk base (without the extension). Restores rebuild the original name from it.
        var base: String
        /// The file names inside the directory (all original names); they are put back as-is on restore.
        var files: [String]
        var deletedAt: Date
        /// The display title at the moment of deletion. A name the user changed is in here too — after a restore
        /// the `.title` sidecar comes back with it, so this is only for the trash list to read.
        var title: String
        var bytes: Int64
        /// The credential that this item "was already downloaded from the device". Non-nil ⇒ this deletion removed the audio,
        /// and a restore has to put that manifest entry back.
        var download: Download?

        /// The original record on the device side. Fields map one-to-one with `Library.Entry`,
        /// deliberately **not** reusing that type directly: the trash has to decode independently (that type lives in
        /// `Library`, and changing its `CodingKeys` would also make already-trashed data unreadable).
        struct Download: Codable, Equatable {
            var name: String
            var size: Int
            var transport: String
            var deviceSerial: String?
            var deviceName: String?
            var localName: String
        }

        var expiry: Date {
            deletedAt.addingTimeInterval(TimeInterval(ClipTrash.retentionDays) * 24 * 3600)
        }

        /// How many days are left. Rounded up — with 3 hours left it still shows "1 day left",
        /// and showing 0 days while it's still there is more confusing than overstating by a day.
        var daysLeft: Int {
            max(0, Int(ceil(expiry.timeIntervalSinceNow / (24 * 3600))))
        }

        var hasAudio: Bool {
            files.contains { ClipArtefact.of(fileNamed: $0) == .audio }
        }
        var hasTranscript: Bool {
            files.contains { ClipArtefact.of(fileNamed: $0) == .transcript }
        }
        var hasSummary: Bool {
            files.contains { ClipArtefact.of(fileNamed: $0) == .summary }
        }
    }

    /// What one deletion has to preserve.
    struct Payload {
        /// On-disk file name. The whole sidecar path set in `StorageLocations` is based on it.
        var localName: String
        /// Display title in the list (a user-edited one takes priority).
        var title: String
        /// The files to move out this time. **Non-existent ones are skipped** — when "deleting only the transcription" the audio
        /// isn't in the list in the first place.
        var urls: [URL]
        /// See `TrashedItem.download`.
        var download: TrashedItem.Download?
    }

    // MARK: - Location

    private static var trashDir: URL {
        StorageLocations.audioDir.appendingPathComponent(".trash", isDirectory: true)
    }

    private static var indexURL: URL {
        trashDir.appendingPathComponent("index.json")
    }

    private init() {
        load()
    }

    // MARK: - Inbound

    /// Move into the trash. Returns how many groups were actually moved.
    ///
    /// - Parameter library: used only to unregister the "already downloaded from the device" credential. After the audio is deleted
    ///   it **must** be unregistered, otherwise the same recording can never be downloaded back (`isDownloaded` stays true forever).
    ///   On restore, `restore` puts it back using `download`.
    @discardableResult
    func move(_ payloads: [Payload], library: Library) -> Int {
        let fm = FileManager.default
        var added: [TrashedItem] = []

        for payload in payloads {
            let present = payload.urls.filter { fm.fileExists(atPath: $0.path) }
            guard !present.isEmpty else { continue }

            let id = UUID().uuidString
            let dir = Self.trashDir.appendingPathComponent(id, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                var names: [String] = []
                var bytes: Int64 = 0
                for url in present {
                    let dest = dir.appendingPathComponent(url.lastPathComponent)
                    try fm.moveItem(at: url, to: dest)
                    names.append(url.lastPathComponent)
                    bytes += Self.fileSize(dest)
                }
                added.append(TrashedItem(
                    id: id,
                    // Every file in the group shares this base prefix (that's the sidecar naming rule),
                    // so deriving it once from the on-disk name is enough; no need to guess each file's.
                    base: (payload.localName as NSString).deletingPathExtension,
                    files: names,
                    deletedAt: Date(),
                    title: payload.title,
                    bytes: bytes,
                    download: payload.download
                ))
                // ⚠️ **Only unregister the manifest once the files are moved**: the other way round, a mid-way error leaves
                // an orphan where "the record is gone but the files remain" — that recording can neither be downloaded back
                // nor is it in the trash. Same ordering rationale as `LibraryView.runBatchDelete`.
                if payload.download != nil {
                    library.forget(localName: payload.localName)
                }
            } catch {
                // On error, **move back** the files already moved into the temp directory; don't leave half an item.
                Self.rollback(dir: dir)
                log.error("trash move failed for \(payload.localName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if !added.isEmpty {
            items.append(contentsOf: added)
            save()
        }
        // Purge expired items while we're at it: a deletion writes to disk anyway, so hitching a ride costs nothing extra.
        purgeExpired()
        return added.count
    }

    // MARK: - Outbound

    /// Put it back. Returns whether it succeeded.
    ///
    /// On a name collision the **whole group is bumped together** to `base-2`: the sidecar files all pair with the audio
    /// via the base prefix, and renaming only the audio would orphan every `.txt` / `.summary.md`.
    @discardableResult
    func restore(_ item: TrashedItem, library: Library) -> Bool {
        let fm = FileManager.default
        let dir = Self.trashDir.appendingPathComponent(item.id, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else {
            // The directory is already gone (cleared externally at some point) — drop it from the index rather than leaving
            // a record that does nothing when tapped.
            forget(item)
            return false
        }

        // Each file's suffix relative to the base (`.opus` / `.txt` / `.summary.md` / `.title`).
        // In theory every file carries this prefix; if one doesn't (the directory was hand-edited), keep its name unchanged
        // rather than assembling a mongrel.
        let suffixes: [String?] = item.files.map {
            $0.hasPrefix(item.base) ? String($0.dropFirst(item.base.count)) : nil
        }
        let targetBase = Self.availableBase(item.base, suffixes: suffixes.compactMap { $0 })
        let target = StorageLocations.decryptedDir

        var movedBack: [String] = []
        var audioName: String?
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for (index, name) in item.files.enumerated() {
                let newName = suffixes[index].map { targetBase + $0 } ?? name
                try fm.moveItem(
                    at: dir.appendingPathComponent(name),
                    to: target.appendingPathComponent(newName)
                )
                movedBack.append(newName)
                if ClipArtefact.of(fileNamed: newName) == .audio { audioName = newName }
            }
        } catch {
            // Half-restoring is the worst — the list would show a broken entry "with a transcription but no audio". Roll it all back.
            for (index, name) in movedBack.enumerated() {
                try? fm.moveItem(
                    at: target.appendingPathComponent(name),
                    to: dir.appendingPathComponent(item.files[index])
                )
            }
            log.error("trash restore failed for \(item.base, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }

        // Put the credential back. `localName` uses the **new** on-disk name: if the name was bumped, the entry in the manifest
        // has to change with it, otherwise the next time the list loads the source label can't be found (the index is keyed by on-disk name).
        if let download = item.download {
            library.recordDownload(
                name: download.name,
                size: download.size,
                transport: download.transport,
                deviceSerial: download.deviceSerial,
                deviceName: download.deviceName,
                localName: audioName ?? download.localName
            )
        }

        // Something restored doesn't count as "newly arrived".
        //
        // The file's `modifiedAt` becomes right now — just past the `origin`
        // timestamp in the unread ledger, and without recording one, a user fishing back 5 items by hand would see 5 red dots, as if
        // 5 new recordings had come in. The name used is the **bumped** one (`base-2.opus` on a collision);
        // when the group has no audio (only the transcription was deleted), the list uses the scanner-synthesised `base.opus`.
        ClipReadStore.shared.markSeen(name: audioName ?? "\(item.base).opus")

        try? fm.removeItem(at: dir)
        forget(item)
        return true
    }

    /// Drop one entry from the index (files untouched).
    private func forget(_ item: TrashedItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    // MARK: - Cleanup

    /// Permanently delete one item. **Irreversible** — the caller is responsible for the confirmation prompt.
    func purge(_ item: TrashedItem) {
        Self.deleteFiles(of: item)
        forget(item)
    }

    /// Empty it.
    func purgeAll() {
        for item in items { Self.deleteFiles(of: item) }
        items.removeAll()
        save()
    }

    /// Purge the expired ones. Returns how many were purged.
    @discardableResult
    func purgeExpired() -> Int {
        let now = Date()
        let expired = items.filter { $0.expiry <= now }
        guard !expired.isEmpty else { return 0 }
        for item in expired { Self.deleteFiles(of: item) }
        items.removeAll { $0.expiry <= now }
        save()
        log.notice("purged \(expired.count, privacy: .public) expired trash item(s)")
        return expired.count
    }

    private static func deleteFiles(of item: TrashedItem) {
        try? FileManager.default.removeItem(
            at: trashDir.appendingPathComponent(item.id, isDirectory: true)
        )
    }

    // MARK: - Helpers

    /// Find a base that doesn't collide: use the original base if it's free, otherwise `base-2`, `base-3`…
    private static func availableBase(_ base: String, suffixes: [String]) -> String {
        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        func taken(_ candidate: String) -> Bool {
            suffixes.contains { fm.fileExists(atPath: dir.appendingPathComponent(candidate + $0).path) }
        }
        guard taken(base) else { return base }
        var n = 2
        while taken("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Move the files already moved into `.trash/<id>/` back to `decryptedDir` as-is.
    private static func rollback(dir: URL) {
        let fm = FileManager.default
        let back = StorageLocations.decryptedDir
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in entries {
            try? fm.moveItem(
                at: url,
                to: back.appendingPathComponent(url.lastPathComponent)
            )
        }
        try? fm.removeItem(at: dir)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(size)
    }

    // MARK: - Disk

    private struct Index: Codable {
        var items: [TrashedItem]
    }

    private func load() {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: Self.indexURL),
           let index = try? JSONDecoder().decode(Index.self, from: data) {
            // In the index but not in the directory ⇒ this item has no files left, drop it (otherwise tapping restore
            // just yields a "failed").
            items = index.items.filter {
                fm.fileExists(atPath: Self.trashDir.appendingPathComponent($0.id).path)
            }
        }
        // In the directory but not in the index ⇒ an orphan directory (left behind when the index write to disk failed).
        // They take up space on disk forever and no UI can reach them, so clear them outright.
        let known = Set(items.map(\.id))
        let dirs = (try? fm.contentsOfDirectory(at: Self.trashDir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where dir.hasDirectoryPath && !known.contains(dir.lastPathComponent) {
            try? fm.removeItem(at: dir)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.trashDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Index(items: items))
            try data.write(to: Self.indexURL, options: .atomic)
        } catch {
            log.error("trash index save failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Fetching the download credential from Library

extension ClipTrash {

    /// Whether the `.title` sidecar should be taken into the trash **along with** it.
    ///
    /// Returns a URL only when "this item has no other artefact besides the part being deleted".
    /// The reason is `ClipArtefact.sweepOrphanTitles()`: `.title` isn't one of the three deletable
    /// artefacts, and once it becomes the only remnant, the scanner rebuilds a ghost entry from it that has neither audio
    /// nor body, so orphan titles must be swept. But "sweep" is too final for the trash —
    /// you'd get the audio back but not the title. Moving it in and out together is what "undoable deletion" should look like.
    ///
    /// - Parameter hasOtherArtefacts: whether this item still has any other
    ///   artefact left **after this deletion** (any of audio / transcription / summary). The caller judges by "the ones not being deleted".
    static func titleSidecar(forLocalName localName: String, hasOtherArtefacts: Bool) -> URL? {
        guard !hasOtherArtefacts else { return nil }
        let url = StorageLocations.titleURL(for: localName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// This item's "already downloaded from the device" credential (nil if none).
    ///
    /// Only **device downloads** (keys shaped like `serial::name`) need bookkeeping: watch / live stream /
    /// imported entries have no such thing as "downloading it again", and recording one for them would only stuff
    /// dirty data into the manifest on restore.
    ///
    /// The name taken is the segment **after** `::` in the key (the original file name on the device side), not the on-disk name:
    /// the two differ only on a name collision, and a restore needs the former + the serial to rebuild the same key.
    static func downloadRecord(
        forLocalName localName: String, in library: Library
    ) -> TrashedItem.Download? {
        guard let raw = library.rawEntry(forLocalName: localName),
              let serial = raw.entry.deviceSerial else { return nil }
        return TrashedItem.Download(
            name: String(raw.key.dropFirst(serial.count + 2)),
            size: raw.entry.size,
            transport: raw.entry.transport,
            deviceSerial: serial,
            deviceName: raw.entry.deviceName,
            localName: raw.entry.localName ?? localName
        )
    }
}
