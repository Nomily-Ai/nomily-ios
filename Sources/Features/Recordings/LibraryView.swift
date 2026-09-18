import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Library segment of the Recordings tab. Lists every playable clip in
/// `audio_clips/decrypted/` (the dir `RecordingsView.writeAndDecrypt`
/// drops files into) sorted newest-first, with a transcript-ready
/// badge derived from the side-by-side `{name}.txt` produced by
/// `TranscriptionService`.
struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @StateObject private var model = LibraryListModel()
    @State private var showImportConfirm = false
    @State private var showImporter = false
    @State private var importError: String?
    @State private var pendingMerge: MergePair?
    @State private var isMerging = false
    @State private var mergeError: String?

    private struct MergePair: Identifiable {
        let older: LibraryItem
        let newer: LibraryItem
        var id: String { "\(older.id)|\(newer.id)" }
    }

    /// Max gap between the older clip's *end* (its `modifiedAt`,
    /// which is when the file finalised on disk) and the newer
    /// clip's *start* (`modifiedAt - duration`). Wide enough to
    /// cover an accidental stop+restart mid-meeting but tight
    /// enough that unrelated clips don't get the swipe action.
    private static let adjacentThreshold: TimeInterval = 10 * 60

    var body: some View {
        Group {
            if model.items.isEmpty {
                EmptyStateView(
                    L10n.Recordings.noClipsYet,
                    systemImage: "tray",
                    message: L10n.Recordings.noClipsMessage
                )
            } else {
                List {
                    Section {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            NavigationLink {
                                ClipDetailView(item: item)
                            } label: {
                                LibraryRow(
                                    item: item,
                                    isFromWatch: library.entry(for: item.name)?.transport == "watch"
                                )
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if let older = adjacentOlder(at: index) {
                                    Button {
                                        pendingMerge = MergePair(older: older, newer: item)
                                    } label: {
                                        Label(L10n.Library.merge, systemImage: "arrow.triangle.merge")
                                    }
                                    .tint(.indigo)
                                }
                            }
                        }
                    } footer: {
                        Text(L10n.Recordings.clipCount(model.items.count, formatBytes(model.totalBytes)))
                    }
                }
                .environment(\.defaultMinListHeaderHeight, 0)
                .padding(.top, -22)
                .clipped()
            }
        }
        .task { await model.refresh() }
        // A watch recording can land while this list is on screen; the file
        // arrives outside any SwiftUI lifecycle, so it has to say so.
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            Task { await model.refresh() }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showImportConfirm = true } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel(L10n.Library.importAudio)
            }
        }
        .alert(L10n.Library.importConfirmTitle, isPresented: $showImportConfirm) {
            Button(L10n.Library.importChooseFile) { showImporter = true }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Library.importConfirmMessage)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result: result)
        }
        .alert(
            L10n.Library.importFailed,
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            ),
            presenting: importError
        ) { _ in
            Button(L10n.Common.ok, role: .cancel) { importError = nil }
        } message: { msg in
            Text(msg)
        }
        .alert(
            L10n.Library.mergeConfirmTitle,
            isPresented: Binding(
                get: { pendingMerge != nil },
                set: { if !$0 { pendingMerge = nil } }
            ),
            presenting: pendingMerge
        ) { pair in
            Button(L10n.Library.merge, role: .destructive) {
                let captured = pair
                Task { await runMerge(older: captured.older, newer: captured.newer) }
            }
            Button(L10n.Common.cancel, role: .cancel) { pendingMerge = nil }
        } message: { pair in
            Text(L10n.Library.mergeConfirmMessage(pair.older.displayTitle, pair.newer.displayTitle))
        }
        .alert(
            L10n.Library.mergeFailed,
            isPresented: Binding(
                get: { mergeError != nil },
                set: { if !$0 { mergeError = nil } }
            ),
            presenting: mergeError
        ) { _ in
            Button(L10n.Common.ok, role: .cancel) { mergeError = nil }
        } message: { msg in
            Text(msg)
        }
        .overlay {
            if isMerging {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(L10n.Library.merging)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    /// Returns the older clip immediately following `item` in the
    /// time-sorted list, if the gap between the two is short enough
    /// to count as "the user stopped + restarted the device".
    /// `items` is sorted newest-first, so the older peer lives at
    /// `index + 1`.
    ///
    /// Gap = (newer's start) − (older's end). For device clips the
    /// filename (`yyyyMMddHHmmss.opus`) gives us the recording start
    /// directly, so older's end = parsed start + duration. For imports
    /// we fall back to the legacy mtime proxy (mtime ≈ end, start ≈
    /// mtime − duration); this is lossy on iPhone-copied files but
    /// it's the only signal we have. If we can't derive a duration we
    /// hide the action rather than guess — better to miss a real
    /// adjacency than offer to merge unrelated clips.
    private func adjacentOlder(at index: Int) -> LibraryItem? {
        guard index + 1 < model.items.count else { return nil }
        let newer = model.items[index]
        let older = model.items[index + 1]
        guard newer.hasAudio, older.hasAudio else { return nil }
        let newerStart: Date
        if let t = RecordingName.date(from: newer.name) {
            newerStart = t
        } else if let d = newer.duration {
            newerStart = newer.modifiedAt.addingTimeInterval(-d)
        } else {
            return nil
        }
        let olderEnd: Date
        if let t = RecordingName.date(from: older.name) {
            guard let d = older.duration else { return nil }
            olderEnd = t.addingTimeInterval(d)
        } else {
            olderEnd = older.modifiedAt
        }
        let gap = newerStart.timeIntervalSince(olderEnd)
        // Allow a touch of negative jitter — filename timestamps round
        // to the second, so two truly back-to-back clips can land a
        // fraction overlapping.
        guard gap >= -2, gap <= Self.adjacentThreshold else { return nil }
        return older
    }

    private func runMerge(older: LibraryItem, newer: LibraryItem) async {
        isMerging = true
        defer { isMerging = false }
        do {
            _ = try await AudioMerger.merge(older: older, newer: newer)
            deleteSourceArtefacts(for: older)
            deleteSourceArtefacts(for: newer)
            await model.refresh(force: true)
        } catch {
            mergeError = error.localizedDescription
        }
    }

    /// Mirrors the cleanup list in `ClipDetailView.deleteFile`, minus
    /// the in-memory player stop (we're operating from the Library,
    /// not Detail). Kept in sync deliberately — forgetting an artefact
    /// here leaves orphan files after a merge.
    private func deleteSourceArtefacts(for item: LibraryItem) {
        let fm = FileManager.default
        let urls = StorageLocations.transcriptURLs(for: item.name)
        if let url = item.url { try? fm.removeItem(at: url) }
        try? fm.removeItem(at: urls.txt)
        try? fm.removeItem(at: urls.json)
        let tr = StorageLocations.translationURLs(for: item.name)
        try? fm.removeItem(at: tr.txt)
        try? fm.removeItem(at: tr.json)
        try? fm.removeItem(at: StorageLocations.summaryURL(for: item.name))
        try? fm.removeItem(at: StorageLocations.summaryTranslatedURL(for: item.name))
        try? fm.removeItem(at: StorageLocations.titleURL(for: item.name))
    }

    private func handleImport(result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            var failures: [String] = []
            for source in urls {
                let granted = source.startAccessingSecurityScopedResource()
                defer { if granted { source.stopAccessingSecurityScopedResource() } }
                do {
                    _ = try AudioImporter.importFile(from: source)
                } catch {
                    failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            Task { await model.refresh(force: true) }
            if !failures.isEmpty {
                importError = failures.joined(separator: "\n")
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    private func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

private struct LibraryRow: View {
    let item: LibraryItem
    let isFromWatch: Bool

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.displayTitle)
                    .font(.body)
                    .lineLimit(2)
                Spacer()
                if isFromWatch {
                    Image(systemName: "applewatch")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                        .accessibilityLabel(L10n.Library.recordedOnWatch)
                }
                if !item.hasAudio {
                    Image(systemName: "waveform.slash")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                }
                if item.hasTranscript {
                    Image(systemName: "text.bubble.fill")
                        .foregroundColor(.green)
                        .imageScale(.small)
                }
            }
            HStack(spacing: 8) {
                if item.hasCustomTitle {
                    Text(Self.shortDate.string(from: item.recordedAt))
                }
                if item.hasAudio {
                    Text(formatBytes(item.size))
                }
                if let dur = item.durationLabel {
                    Text("\u{00B7}")
                    Text(dur)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: - Model

struct LibraryItem: Identifiable, Equatable {
    let name: String
    /// `nil` when the audio file has been cleared but text artifacts
    /// (transcript / summary) still exist on disk.
    let url: URL?
    let size: Int64
    let modifiedAt: Date
    let duration: Double?
    let hasTranscript: Bool
    let customTitle: String?

    var id: String { name }
    var hasAudio: Bool { url != nil }
    var displayTitle: String {
        if let customTitle { return customTitle }
        // Text-only entries carry a synthetic ".opus" name — LibraryListModel
        // appends it so the StorageLocations helpers' deletingPathExtension
        // still yields the right base even for dotted names. Never surface
        // that fabricated extension: an imported "meeting.mp3" whose audio was
        // cleared must not come back reading as "meeting.opus" (omkn6rf).
        // Timestamped device names still render as a date, so only the
        // unparseable (imported) case needs the raw base.
        if url == nil, RecordingName.date(from: name) == nil {
            return (name as NSString).deletingPathExtension
        }
        return RecordingName.displayTitle(for: name)
    }
    var hasCustomTitle: Bool { customTitle != nil }
    /// The recording's real timestamp: parsed from the device filename
    /// (device RTC at record time) when present, else the file mtime for
    /// imported clips that carry no timestamped name. Display should use
    /// this, not `modifiedAt` (which is the download-to-phone time) — the
    /// filename is the authoritative recording time (l7jwpnd).
    var recordedAt: Date { RecordingName.date(from: name) ?? modifiedAt }

    var durationLabel: String? {
        guard let duration else { return nil }
        return ClockLabel.mmss(duration)
    }
}

/// The sole formatting point for duration: shared by list cards, detail page header, and the right side of the player progress bar.
/// Always round to the nearest second—letting each place truncate individually would cause a 5.6 s audio to show as 0:05 in one place and 0:06 in another,
// and the merged file would almost never be an exact number of seconds, leading to collisions.
enum ClockLabel {
    static func mmss(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded()))
        if t >= 3600 {
            return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
        }
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

@MainActor
final class LibraryListModel: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []

    /// Summed once per scan instead of on every body evaluation — with ~1900
    /// items the old computed property re-reduced the whole array each time
    /// SwiftUI asked for the footer.
    private(set) var totalBytes: Int64 = 0

    /// Coalesces overlapping refreshes. `.task` on appear and the pop-back
    /// re-appear can both fire within a frame of each other; without this the
    /// second one starts a whole duplicate scan.
    private var inFlight: Task<Void, Never>?

    /// Signature of the last completed scan (directory mtime + entry count).
    /// Popping back from Clip Detail is by far the most common refresh and
    /// almost never changes the directory, so it can return immediately.
    private var lastSignature: LibraryScanner.Signature?

    private let scanner = LibraryScanner()

    func refresh(force: Bool = false) async {
        inFlight?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let previous = force ? nil : self.lastSignature
            let scanner = self.scanner
            // The whole scan is filesystem work: 1900 files means thousands of
            // stat calls plus a duration probe each. Running it on the main
            // actor is what froze the list for seconds on every appear.
            // ⚠️ Detached tasks **do not inherit cancellation**: a simple `guard !Task.isCancelled` here is insufficient —
            // If the outer task is cancelled (e.g., switching tabs or triggering a refresh), this scan will still stat and probe the duration of thousands of files.
            // Repeatedly entering and leaving the library causes multiple full scans to run concurrently,
            // which amplifies the “a few seconds of lag when there are many files” issue.
            // Use `withTaskCancellationHandler` to manually forward cancellation (as in `LocalVAD.analyze`).
            let scanTask = Task.detached(priority: .userInitiated) {
                await scanner.scan(skippingIfUnchangedFrom: previous)
            }
            let outcome = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .unchanged:
                break
            case let .scanned(items, signature, totalBytes):
                self.items = items
                self.totalBytes = totalBytes
                self.lastSignature = signature
            }
        }
        inFlight = task
        await task.value
    }
}

/// Filesystem side of the Library list. Lives off the main actor and owns the
/// duration cache, which is the expensive part: `OpusOgg.duration` page-walks
/// the file and `AVURLAsset.load(.duration)` opens a demuxer, so recomputing
/// either for every clip on every appear does not scale — QA measured a 14 s
/// cold start and multi-second stalls at ~1900 clips / 25 GB.
actor LibraryScanner {

    /// Fingerprint of the directory listing. Deliberately **not** the
    /// directory's own mtime: that misses an in-place overwrite, and renaming
    /// a clip rewrites an existing `.title` without touching the directory —
    /// the rename would then not show up until something else changed.
    /// The newest entry mtime catches those; the count catches add/remove.
    /// Both come from the batch the enumerator already prefetched.
    struct Signature: Equatable {
        let newestEntry: Date
        let entryCount: Int
    }

    enum Outcome {
        case unchanged
        case scanned(items: [LibraryItem], signature: Signature, totalBytes: Int64)
    }

    /// name → duration, valid only while the file's size and mtime match.
    /// Persisted so a cold start doesn't have to re-probe the whole library.
    private struct DurationEntry: Codable {
        let size: Int64
        let modified: Date
        let duration: Double?
    }
    private var durations: [String: DurationEntry] = [:]
    private var durationsLoaded = false

    private var cacheURL: URL {
        StorageLocations.audioDir.appendingPathComponent(".durations.json", isDirectory: false)
    }

    func scan(skippingIfUnchangedFrom previous: Signature?) async -> Outcome {
        let dir = StorageLocations.decryptedDir
        let fm = FileManager.default

        guard let allEntries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .scanned(items: [], signature: Signature(newestEntry: .distantPast, entryCount: 0), totalBytes: 0)
        }

        var newest = Date.distantPast
        for url in allEntries {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            if m > newest { newest = m }
        }
        let signature = Signature(newestEntry: newest, entryCount: allEntries.count)
        if let previous, previous == signature { return .unchanged }

        loadDurationCacheIfNeeded()

        // Every artefact lives in this same directory, so membership questions
        // ("does this clip have a transcript?") are answered from the listing
        // we already have rather than a `fileExists` syscall per clip.
        let presentNames = Set(allEntries.map(\.lastPathComponent))

        let audioExts = AudioImporter.acceptedExtensions
        let audioFiles = allEntries.filter { audioExts.contains($0.pathExtension.lowercased()) }
        var audioBases = Set<String>()
        audioBases.reserveCapacity(audioFiles.count)
        for url in audioFiles {
            audioBases.insert((url.lastPathComponent as NSString).deletingPathExtension)
        }

        // Artifact files whose audio is gone (text survived a "Clear Media"
        // wipe). Longer suffixes first so "foo.asr.json" matches ".asr.json"
        // before ".json".
        let artifactSuffixes = [".asr.json", ".translated.txt", ".translated.json",
                                ".summary.translated.md", ".summary.md", ".title", ".txt"]
        var orphanMtimes: [String: Date] = [:]
        for url in allEntries where !audioExts.contains(url.pathExtension.lowercased()) {
            let fname = url.lastPathComponent
            guard let suffix = artifactSuffixes.first(where: { fname.hasSuffix($0) }) else { continue }
            let base = String(fname.dropLast(suffix.count))
            guard !audioBases.contains(base) else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            orphanMtimes[base] = max(orphanMtimes[base] ?? Date.distantPast, mtime)
        }

        var built: [LibraryItem] = []
        built.reserveCapacity(audioFiles.count + orphanMtimes.count)
        var totalBytes: Int64 = 0
        var cacheDirty = false

        for url in audioFiles {
            // The forwarded cancellation must take effect **here**, otherwise the upper layer just forwards it uselessly:
            // Scanning 1,900 files, each potentially requiring a page‑wise Ogg duration probe, is the most expensive part of the whole scan.
            if Task.isCancelled { return .unchanged }
            let name = url.lastPathComponent
            let base = (name as NSString).deletingPathExtension
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(attrs?.fileSize ?? 0)
            let mtime = attrs?.contentModificationDate ?? Date.distantPast
            totalBytes += size

            let duration: Double?
            if let cached = durations[name], cached.size == size, cached.modified == mtime {
                duration = cached.duration
            } else {
                duration = await Self.probeDuration(url)
                durations[name] = DurationEntry(size: size, modified: mtime, duration: duration)
                cacheDirty = true
            }

            built.append(LibraryItem(
                name: name,
                url: url,
                size: size,
                modifiedAt: mtime,
                duration: duration,
                hasTranscript: presentNames.contains("\(base).txt"),
                customTitle: Self.readTitle(base: base, presentNames: presentNames)
            ))
        }

        for (base, mtime) in orphanMtimes {
            // Synthetic ".opus" so deletingPathExtension in the StorageLocations
            // helpers still yields `base` for these text-only entries.
            built.append(LibraryItem(
                name: "\(base).opus",
                url: nil,
                size: 0,
                modifiedAt: mtime,
                duration: nil,
                hasTranscript: presentNames.contains("\(base).txt"),
                customTitle: Self.readTitle(base: base, presentNames: presentNames)
            ))
        }

        // Drop cache rows for clips that no longer exist, so the file doesn't
        // grow forever across deletes.
        let liveNames = Set(audioFiles.map(\.lastPathComponent))
        if durations.keys.contains(where: { !liveNames.contains($0) }) {
            durations = durations.filter { liveNames.contains($0.key) }
            cacheDirty = true
        }
        if cacheDirty { saveDurationCache() }

        let sorted = built.sorted { lhs, rhs in
            let l = RecordingName.date(from: lhs.name) ?? lhs.modifiedAt
            let r = RecordingName.date(from: rhs.name) ?? rhs.modifiedAt
            return l > r
        }
        return .scanned(items: sorted, signature: signature, totalBytes: totalBytes)
    }

    /// Only opens the `.title` file when the listing says there is one —
    /// otherwise this was a failed `Data(contentsOf:)` per clip.
    private static func readTitle(base: String, presentNames: Set<String>) -> String? {
        guard presentNames.contains("\(base).title") else { return nil }
        let url = StorageLocations.decryptedDir.appendingPathComponent("\(base).title")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func probeDuration(_ url: URL) async -> Double? {
        if url.pathExtension.lowercased() == "opus" {
            return OpusOgg.duration(ofOggOpusAt: url)
        }
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        return (seconds.isFinite && seconds > 0) ? seconds : nil
    }

    private func loadDurationCacheIfNeeded() {
        guard !durationsLoaded else { return }
        durationsLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: DurationEntry].self, from: data)
        else { return }
        durations = decoded
    }

    private func saveDurationCache() {
        guard let data = try? JSONEncoder().encode(durations) else { return }
        try? FileManager.default.createDirectory(
            at: StorageLocations.audioDir, withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}
