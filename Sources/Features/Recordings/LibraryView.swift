import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Library segment of the Recordings tab. Lists every playable clip in
/// `audio_clips/decrypted/` (the dir `RecordingsView.writeAndDecrypt`
/// drops files into) sorted newest-first, with a transcript-ready
/// badge derived from the side-by-side `{name}.txt` produced by
/// `TranscriptionService`.
struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @StateObject private var model = LibraryListModel()
    /// Solely so that "after a card is renamed, the source badge in the list follows along."
    ///
    /// Why the store must be hooked up as observed: the source badge takes the SN to
    /// `RecorderAliasStore` to look up the alias, and that is a **plain dictionary lookup** — SwiftUI doesn't know
    /// it needs to redraw — the comment at the top of `RecorderAliasStore` records the same pitfall
    /// (that's exactly how `DiscoveredRecorder.displayName` fell into it).
    @ObservedObject private var recorderAliases = RecorderAliasStore.shared
    @State private var showImportConfirm = false
    @State private var showImporter = false
    @State private var importError: String?
    @State private var pendingMerge: MergePair?

    /// The caption on the overlay shown while busy; `nil` = don't show it.
    ///
    /// Merge / export staging / batch delete all share one overlay — each takes anywhere from a few hundred milliseconds
    /// to tens of seconds (export copies the audio one file at a time), and during that time **taps must be blocked**:
    /// otherwise the user can tap export again halfway through a delete.
    @State private var busyMessage: String?
    @State private var mergeError: String?
    /// Details of a batch-export failure (the title is always `L10n.Library.exportFailed`).
    ///
    /// Like `mergeError` / `importError`, this is the "one string is one alert" style:
    /// the alert title is fixed with `.alert(_:isPresented:)`, so **export and delete must
    /// be two separate states**, or a failure reason pops up under another action's title.
    @State private var exportError: String?
    @State private var deleteError: String?

    // MARK: Multi-select (★ 2026-10-15, user asked for "long-press to select + batch export/delete")
    //
    // The structure is **deliberately identical** to `RecorderSheet`'s set (`isSelecting` + `selectedIDs`
    // + a bottom selectionBar); the only difference is: there it's "transfer the selection", here it's "export/delete the selection".
    // The same action looks the same on the watch/phone, so the user doesn't have to relearn it.
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBatchDeleteConfirm = false
    /// The target for programmatic navigation. For why **`NavigationLink` isn't used**, see `row(_:)`.
    @State private var detailItem: LibraryItem?

    // MARK: Knowledge-base search
    @State private var query = ""
    @State private var scope: LibrarySearchScope = .knowledge
    /// `base -> matched snippet`. Empty = not searching, or this entry's body didn't match.
    @State private var snippets: [String: String] = [:]
    @State private var isSearching = false
    /// The top-level export staging directory (the one handed to the system share sheet).
    @State private var exportURL: URL?
    @State private var showExportSheet = false

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
            } else if isSearchActive, displayedRows.isEmpty, isSearching {
                // The first search has to read from disk and build the index (a brief moment when the library has hundreds of entries with bodies).
                // During that time we **must not** report "nothing found" — that's a lie, and the user will think the search is wrong.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedRows.isEmpty {
                // Reaching here can only mean "searching but no match" (the library itself is non-empty, see the two branches above).
                EmptyStateView(
                    L10n.Library.searchEmptyTitle,
                    systemImage: "magnifyingglass",
                    message: L10n.Library.searchEmptyMessage
                )
            } else {
                List {
                    Section {
                        ForEach(displayedRows, id: \.element.id) { entry in
                            row(entry.element, at: entry.offset)
                        }
                    } footer: {
                        footer
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
        // Knowledge-base search. `.task(id:)` is the key: change the query or the scope and SwiftUI will
        // **cancel the previous run entirely**, so fast typing doesn't have several rounds of disk reading running at once.
        .task(id: searchKey) { await runSearch() }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(L10n.Library.searchPrompt)
        )
        .searchScopes($scope) {
            ForEach(LibrarySearchScope.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar }
        }
        .navigationDestination(isPresented: Binding(
            get: { detailItem != nil },
            set: { if !$0 { detailItem = nil } }
        )) {
            if let detailItem { ClipDetailView(item: detailItem) }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSelecting {
                    Button(L10n.Common.cancel) { exitSelection() }
                } else {
                    HStack(spacing: 16) {
                        Button(L10n.Library.select) {
                            selectedIDs = []
                            isSelecting = true
                        }
                        // Multi-select isn't allowed during a search: the result set changes with the input,
                        // an already-ticked entry may vanish from the screen as you type the next character,
                        // while the selection set still holds it — then "3 selected" won't match the screen.
                        .disabled(model.items.isEmpty || isSearchActive)

                        Button { showImportConfirm = true } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .accessibilityLabel(L10n.Library.importAudio)
                    }
                }
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
        // The batch-delete confirmation. Uses `.alert` rather than `.confirmationDialog`:
        // it needs a line spelling out that it "also deletes the transcript and summary, and can't be undone".
        .alert(L10n.Library.deleteSelectedTitle, isPresented: $showBatchDeleteConfirm) {
            Button(L10n.Common.delete, role: .destructive) {
                Task { await runBatchDelete() }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Library.deleteSelectedMessage(selectedIDs.count))
        }
        .alert(
            L10n.Library.exportFailed,
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ),
            presenting: exportError
        ) { _ in
            Button(L10n.Common.ok, role: .cancel) { exportError = nil }
        } message: { msg in
            Text(msg)
        }
        .alert(
            L10n.Library.deleteFailed,
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            ),
            presenting: deleteError
        ) { _ in
            Button(L10n.Common.ok, role: .cancel) { deleteError = nil }
        } message: { msg in
            Text(msg)
        }
        // Export goes through the system share sheet: saving to "Files", AirDrop, sending to someone — all of it.
        // What's handed over is a **directory** (one subdirectory per clip), not an archive — see `runBatchExport`.
        .sheet(isPresented: $showExportSheet, onDismiss: { exportURL = nil }) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .overlay {
            if let busyMessage {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(busyMessage)
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
        busyMessage = L10n.Library.merging
        defer { busyMessage = nil }
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

    // MARK: - List rows / footer

    /// One row. Tap to open detail, long-press to enter multi-select, swipe right to merge.
    ///
    /// Use `LongPressGesture.exclusively(before: TapGesture())` rather than
    /// "Button + onLongPressGesture": in the latter the two gestures are recognised **independently**,
    /// so when you release a long press the Button's action may still fire once — which shows as "long-pressed to select,
    /// and it jumped into the detail page along the way". `exclusively` hard-codes the priority: if the long press wins, the tap isn't recognised.
    private func row(_ item: LibraryItem, at index: Int) -> some View {
        let isSelected = selectedIDs.contains(item.name)
        return HStack(spacing: 10) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .transition(.scale.combined(with: .opacity))
            }
            LibraryRow(
                item: item,
                source: library.source(forLocalName: item.name),
                snippet: snippets[item.base]
            )
            if !isSelecting {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        // Without a Button, the hit area no longer fills the whole row automatically — only the text is tappable.
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .gesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    guard !isSelecting else { return }
                    enterSelection(with: item)
                }
                .exclusively(
                    before: TapGesture().onEnded {
                        if isSelecting {
                            toggleSelection(item)
                        } else {
                            detailItem = item
                        }
                    }
                )
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // No merging in search mode: only the matches are on screen, while "adjacent" is computed over the **whole library**'s
            // time order — that neighbour isn't in the list at all right now, and after merging it looks like
            // "it swallowed something else".
            if !isSelecting, !isSearchActive, let older = adjacentOlder(at: index) {
                Button {
                    pendingMerge = MergePair(older: older, newer: item)
                } label: {
                    Label(L10n.Library.merge, systemImage: "arrow.triangle.merge")
                }
                .tint(.indigo)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        // No count in search mode: the screen shows a filtered subset, and reporting the library total makes it look "wrongly displayed",
        // while reporting the subset count looks like the same thing as the bottom "N selected" line.
        if !isSearchActive {
            Text(L10n.Recordings.clipCount(model.items.count, formatBytes(model.totalBytes)))
        }
    }

    // MARK: - Derived state

    /// The entries to show on screen: `(index into model.items, entry)`.
    ///
    /// The index is there for `adjacentOlder(at:)` — it finds the adjacent previous clip by the **whole library**'s time order,
    /// and that index is exactly its position in `model.items`. In search mode every body evaluation has to re-filter,
    /// so here we run `enumerated()` just once, rather than looking the index up again inside ForEach
    /// (which would be O(n²): the library has reached 1900 entries).
    private var displayedRows: [(offset: Int, element: LibraryItem)] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Array(model.items.enumerated()) }
        var out: [(offset: Int, element: LibraryItem)] = []
        for (index, item) in model.items.enumerated() {
            let inBody = snippets[item.base] != nil
            switch scope {
            case .knowledge:
                if inBody { out.append((index, item)) }
            case .all:
                // This is the one thing "All" has that "Knowledge base" doesn't: recordings not yet transcribed, with only a name.
                if inBody || item.matchesName(needle) { out.append((index, item)) }
            }
        }
        return out
    }

    private var isSearchActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The `.task(id:)` key: scope + directory fingerprint + query term.
    ///
    /// Including the fingerprint is necessary: once what's in the library changes (a new recording, a summary just generated for one),
    /// the search has to re-run. And the fingerprint is exactly `LibraryKnowledgeIndex`'s cache-invalidation key —
    /// the same value governs both "should we re-search" and "is the body cache still valid", so you never get
    /// "the index refreshed but the screen still shows old results".
    private var searchKey: String {
        let stamp = model.signature
            .map { "\($0.entryCount)@\($0.newestEntry.timeIntervalSince1970)" } ?? "-"
        return "\(scope.rawValue)|\(stamp)|\(query)"
    }

    /// The ticked entries, given in **list order** (newest first).
    ///
    /// In `model.items` order, not `selectedIDs`' hash order: the ordering in the export directory
    /// and the error order on a failed delete both follow the screen, so when something goes wrong you can match them up at a glance.
    private var selectedItems: [LibraryItem] {
        model.items.filter { selectedIDs.contains($0.name) }
    }

    private var allItemsSelected: Bool {
        let names = Set(displayedRows.map(\.element.name))
        return !names.isEmpty && names.isSubset(of: selectedIDs)
    }

    // MARK: - Multi-select

    private func enterSelection(with item: LibraryItem) {
        selectedIDs = [item.name]
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.2)) { isSelecting = true }
    }

    private func toggleSelection(_ item: LibraryItem) {
        if selectedIDs.contains(item.name) {
            selectedIDs.remove(item.name)
        } else {
            selectedIDs.insert(item.name)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func exitSelection() {
        selectedIDs.removeAll()
        withAnimation(.easeInOut(duration: 0.2)) { isSelecting = false }
    }

    private var selectionBar: some View {
        VStack(spacing: 10) {
            HStack {
                Button(allItemsSelected ? L10n.Library.deselectAll : L10n.Library.selectAll) {
                    if allItemsSelected {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(displayedRows.map(\.element.name))
                    }
                }
                .font(.subheadline)
                .disabled(displayedRows.isEmpty)

                Spacer()

                Text(L10n.Library.selectedCount(selectedIDs.count))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await runBatchExport() }
                } label: {
                    Label(L10n.Library.export, systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    showBatchDeleteConfirm = true
                } label: {
                    Label(L10n.Common.delete, systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            // With nothing ticked neither action has anything to do (export an empty directory, delete 0 clips) —
            // so grey both out together, rather than waiting for a tap and then popping "please select something".
            .disabled(selectedItems.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Knowledge-base search

    private func runSearch() async {
        guard isSearchActive else {
            // Backspacing to empty = leaving search, and the match set must be cleared with it,
            // otherwise typing one character again flashes the **previous** results first.
            snippets = [:]
            isSearching = false
            return
        }
        // Only entries with a body are worth reading from disk (`hasText` is determined by the scanner in the directory listing,
        // zero extra syscalls). "All" doesn't read many more either — the menu/title is an in-memory comparison.
        let bases = model.items.filter(\.hasText).map(\.base)
        isSearching = true
        let hits = await LibraryKnowledgeIndex.shared.search(
            query, bases: bases, stamp: model.signature
        )
        // With fast typing the previous run is cancelled entirely by `.task(id:)`; the cancelled run must not write
        // `snippets` again — otherwise old results overwrite the new round's.
        guard !Task.isCancelled else { return }
        snippets = hits
        isSearching = false
    }

    // MARK: - Batch export

    /// The root export staging directory. A fixed path, **wiped entirely before every export**.
    ///
    /// Put in `tmp` rather than Documents: this is a way station, not user data. The system reclaims it on its own,
    /// we don't need to account for it (and shouldn't hold the user's storage quota).
    private static var exportStagingDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nomily-export", isDirectory: true)
    }

    /// A clip's folder name in the export directory: use the **display title** (the name the user changed) rather than
    /// the filename — the export is for people to read.
    ///
    /// Stripping `:` is mandatory: on iOS the colon is HFS's old separator and gets **quietly** turned into
    /// `/` when writing a path, so a title like "Note 10:30" would sprout an extra directory level out of nowhere.
    /// Duplicate names (two clips both called "Meeting") go to `Meeting (2)`, never overwriting.
    private static func exportFolderName(
        for item: LibraryItem, taken: inout Set<String>
    ) -> String {
        var base = item.displayTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = item.base }
        if base.count > 80 { base = String(base.prefix(80)) }
        var candidate = base
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(base) (\(n))"
            n += 1
        }
        taken.insert(candidate)
        return candidate
    }

    /// A clip's **text** sidecars: `(disk location, name at export time)`.
    ///
    /// Deliberately **excludes** `.asr.json` / `.translated.json`: those are intermediate formats for the App to
    /// read back itself (with timeline, confidence, speaker), and are useless to a person. What the user wants is
    /// "audio + transcript/summary **text**".
    ///
    /// The export name is written as readable English (`Transcript.txt`) rather than the on-disk name
    /// (`20240101010101.txt`): the folder is already named by title, so another timestamp inside
    /// would be a waste. One folder holds one clip, so these names never collide.
    private static func textArtefacts(for item: LibraryItem) -> [(source: URL, name: String)] {
        let dir = StorageLocations.decryptedDir
        func url(_ suffix: String) -> URL {
            dir.appendingPathComponent(item.base + suffix)
        }
        return [
            (url(".txt"), "Transcript.txt"),
            (url(".translated.txt"), "Transcript (translated).txt"),
            (url(".summary.md"), "Summary.md"),
            (url(".summary.translated.md"), "Summary (translated).md"),
        ]
    }

    /// **Copy the ticked entries as-is** into a temporary directory, then hand it to the system share sheet.
    ///
    /// Why not zip: `UIActivityViewController` can "Save to Files" and AirDrop a directory just as well,
    /// saving one copy of tens of GB being written again — exporting 20 meeting recordings
    /// takes tens of seconds as it is, and during that the device's space use doubles.
    private func runBatchExport() async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        busyMessage = L10n.Library.exportPreparing
        defer { busyMessage = nil }

        let fm = FileManager.default
        let root = Self.exportStagingDir
        // Clear the previous staging first, or "export 3 clips" gets mixed with the previous 20.
        try? fm.removeItem(at: root)

        var failures: [String] = []
        var staged = 0
        var taken = Set<String>()
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for item in items {
                let dir = root.appendingPathComponent(
                    Self.exportFolderName(for: item, taken: &taken), isDirectory: true
                )
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)

                // The audio keeps its **original filename** (the .opus / .m4a / .mp3 extension is how a player
                // recognises it, so it can't be changed).
                if let url = item.url, fm.fileExists(atPath: url.path) {
                    do {
                        try fm.copyItem(at: url, to: dir.appendingPathComponent(item.name))
                        staged += 1
                    } catch {
                        failures.append("\(item.displayTitle): \(error.localizedDescription)")
                    }
                }
                for artefact in Self.textArtefacts(for: item)
                where fm.fileExists(atPath: artefact.source.path) {
                    do {
                        try fm.copyItem(
                            at: artefact.source,
                            to: dir.appendingPathComponent(artefact.name)
                        )
                        staged += 1
                    } catch {
                        failures.append("\(item.displayTitle): \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            exportError = error.localizedDescription
            return
        }

        // If there's a real I/O error, say so honestly and don't show the share sheet: making the user "Save to Files"
        // a directory that's missing content is worse than telling them outright which clips failed to export.
        // (A text-only entry with no audio **doesn't count as a failure** — it had no audio to export anyway.)
        if !failures.isEmpty {
            exportError = failures.joined(separator: "\n")
            return
        }
        guard staged > 0 else {
            exportError = L10n.Library.exportEmpty
            return
        }
        exportURL = root
        showExportSheet = true
    }

    // MARK: - Batch delete

    /// Delete the whole clip: audio + transcript + summary + translation + custom title, plus deregistering
    /// the record in `Library`.
    ///
    /// ⚠️ **The order can't be reversed** — it must be "delete the files first, then clear the manifest". Reverse it and
    /// `LibraryScanner` will, in the window where "the manifest is cleared but the files remain", rebuild this entry as an
    /// **imported file** (no manifest record = the user imported it themselves),
    /// and what the user sees is "deleted but not deleted".
    private func runBatchDelete() async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        busyMessage = L10n.Library.deleting
        defer { busyMessage = nil }

        let fm = FileManager.default
        var failures: [String] = []
        for item in items {
            if let url = item.url, fm.fileExists(atPath: url.path) {
                do {
                    try fm.removeItem(at: url)
                } catch {
                    // If the audio can't be deleted, **keep the manifest record** (half the clip is still here),
                    // report it to the user to retry, rather than leaving an orphan with "the files are there, the record is gone".
                    failures.append("\(item.displayTitle): \(error.localizedDescription)")
                    continue
                }
            }
            for artefact in Self.textArtefacts(for: item) {
                try? fm.removeItem(at: artefact.source)
            }
            try? fm.removeItem(at: StorageLocations.titleURL(for: item.name))
            // The only proof that "this one was already downloaded from the device". Miss it and the same clip can never
            // be downloaded again — in the device list it stays "downloaded" forever.
            library.forget(localName: item.name)
        }

        // Clear orphan `.title`s: the delete above removes the "selected entry's own", but duplicate-name persistence
        // and the like can leave other orphans.
        ClipArtefact.sweepOrphanTitles()
        exitSelection()
        await model.refresh(force: true)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        if !failures.isEmpty {
            deleteError = failures.joined(separator: "\n")
        }
    }

    private func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

private struct LibraryRow: View {
    let item: LibraryItem
    let source: Library.ClipSource
    /// The body text where knowledge-base search matched (`nil` = not searching, or this entry's body didn't match).
    ///
    /// The caller looks it up in `snippets` and passes it in; the row itself doesn't touch the search — the list scrolls,
    /// and a row shouldn't have the cost of "looking it up itself".
    var snippet: String? = nil

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
                if !item.hasAudio {
                    Image(systemName: "waveform.slash")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                }
                if item.hasTranscript {
                    Image(systemName: "text.bubble.fill")
                        .foregroundColor(.green)
                        .imageScale(.small)
                        .accessibilityLabel(L10n.Library.hasTranscript)
                }
                if item.hasSummary {
                    Image(systemName: "doc.plaintext.fill")
                        .foregroundColor(.orange)
                        .imageScale(.small)
                        .accessibilityLabel(L10n.Library.hasSummary)
                }
            }
            if let snippet {
                // The matched snippet. Newlines have been flattened (see `LibraryKnowledgeIndex.snippet`),
                // and `lineLimit(2)` covers it here too — a transcript occasionally has a whole stretch with no punctuation.
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                // ★ 2026-10-15: the source badge goes **first**. In a pile of recordings with nearly identical
                //   filenames, "who recorded this" is the first criterion for picking one, more useful than the byte count.
                SourceBadge(source: source)
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

/// "Who recorded this": a symbol + one line of small text.
///
/// Of the form `TicNote-3N9H`, `My Meeting Card-3N9H`, `Apple Watch`, `This Device`, `Imported`.
private struct SourceBadge: View {
    let source: Library.ClipSource

    var body: some View {
        let text = Self.text(for: source)
        HStack(spacing: 3) {
            Image(systemName: Self.symbol(for: source.kind))
                .imageScale(.small)
            Text(text)
        }
        .accessibilityLabel(L10n.Library.sourceAccessibility(text))
    }

    /// Display text.
    ///
    /// The card naming order is deliberately **user alias → name recorded at persistence → fallback word**,
    /// with the **last 4 digits of the SN** uniformly appended: two cards of the same model both labeled "Recorder Card" are indistinguishable,
    /// while the SN's last 4 digits happen to match the Wi-Fi hotspot naming convention (`TicNote-3N9H`),
    /// so users can match them up directly (see `protocol-notes.md` §18.1).
    ///
    /// The alias is looked up **at display time**, not frozen into storage — so when the user renames a card later,
    /// the badge on old records changes too, without leaving a pile of stale names behind.
    private static func text(for source: Library.ClipSource) -> String {
        switch source.kind {
        case .watch:
            return L10n.Library.sourceWatch
        case .phone:
            return L10n.Library.sourcePhone
        case .imported:
            return L10n.Library.sourceImported
        case .card:
            let alias = source.serial.flatMap {
                RecorderAliasStore.shared.alias(identityHex: $0)
            }
            let unit = alias ?? source.storedName ?? L10n.Library.sourceCard
            guard let suffix = serialSuffix(source.serial) else { return unit }
            return "\(unit)-\(suffix)"
        }
    }

    /// Last 4 digits of the SN. Returns nil when the SN is too short — better to display only the name
    /// than to splice together something half-done like `-09H`.
    private static func serialSuffix(_ serial: String?) -> String? {
        guard let serial else { return nil }
        let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4 else { return nil }
        return String(trimmed.suffix(4))
    }

    private static func symbol(for kind: Library.ClipSource.Kind) -> String {
        switch kind {
        case .card: return "creditcard"
        case .watch: return "applewatch"
        case .phone: return "iphone"
        case .imported: return "square.and.arrow.down"
        }
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
    /// ★ 2026-10-15: a summary has been generated (`{base}.summary.md` exists).
    ///
    /// Like `hasTranscript`, this is determined directly by the scanner from the **existing directory listing**,
    /// zero extra syscalls. Knowledge-base search relies on it and `hasTranscript` to decide "does this entry have a body",
    /// and the list hangs a badge off it accordingly.
    let hasSummary: Bool
    /// Has a translation: the translation of the whole transcript, or of the summary.
    let hasTranslation: Bool
    let customTitle: String?

    var id: String { name }

    /// The filename without its extension. **Every sidecar file** (transcript / summary / translation / title)
    /// is prefixed with it — the search index builds paths from it, so don't each call `deletingPathExtension`
    /// again (`LibraryScanner`'s synthesised `.opus` name for text-only entries also lines up through this).
    var base: String { (name as NSString).deletingPathExtension }

    /// Whether this entry has a **searchable body** — that is, "does it count as a knowledge-base entry".
    var hasText: Bool { hasTranscript || hasSummary }

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

    /// Whether this entry matches the keyword **by name** (on-disk name / display title).
    ///
    /// Only serves the "All" scope: an untranscribed recording's body is empty, so only the name can be searched.
    /// Matching is case- and diacritic-insensitive — the same set of criteria as
    /// `LibraryKnowledgeIndex`, or the same word gives different results in the two scopes.
    func matchesName(_ needle: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if name.range(of: needle, options: options) != nil { return true }
        return displayTitle.range(of: needle, options: options) != nil
    }

    /// Single-entry on-the-spot disk read: turn an **existing audio file** on disk into a `LibraryItem`.
    ///
    /// The whole-library path goes through `LibraryScanner` (one directory listing for a batch decision, see
    /// `textFlags`); this is the single-entry path for "just recorded", "just navigated in", with only the filename to hand,
    /// so it can only `fileExists` one at a time. **The decision logic must exist in only this one place** — these two paths (and
    /// the live-page entry point) each had their own copy before, and adding `hasSummary` meant three places missed it together.
    ///
    /// `duration` is given by the caller: the two places compute duration differently anyway (the live page only looks at Opus,
    /// the recording page asks `AVURLAsset` asynchronously for non-Opus), and forcing them together would only add a branch.
    static func readFromDisk(name: String, duration: Double?) -> LibraryItem? {
        let dir = StorageLocations.decryptedDir
        let url = dir.appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let base = (name as NSString).deletingPathExtension
        func artefact(_ suffix: String) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent(base + suffix).path)
        }
        let titleURL = StorageLocations.titleURL(for: name)
        let title = (try? String(contentsOf: titleURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryItem(
            name: name,
            url: url,
            size: Int64(attrs?.fileSize ?? 0),
            modifiedAt: attrs?.contentModificationDate ?? Date(),
            duration: duration,
            hasTranscript: artefact(".txt"),
            hasSummary: artefact(".summary.md"),
            hasTranslation: artefact(".translated.txt") || artefact(".summary.translated.md"),
            customTitle: (title?.isEmpty ?? true) ? nil : title
        )
    }
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
    ///
    /// ★ 2026-10-15: exposed read-only to the outside. Knowledge-base search uses it as the **cache-invalidation key** —
    /// it changes whenever any file in the directory is written (re-transcription, summary generation), so the body cache
    /// is invalidated wholesale. Cheaper than comparing mtime file by file, and it doesn't miss anything.
    private(set) var signature: LibraryScanner.Signature?

    private let scanner = LibraryScanner()

    func refresh(force: Bool = false) async {
        inFlight?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let previous = force ? nil : self.signature
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
                self.signature = signature
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

            let text = Self.textFlags(base: base, presentNames: presentNames)
            built.append(LibraryItem(
                name: name,
                url: url,
                size: size,
                modifiedAt: mtime,
                duration: duration,
                hasTranscript: text.transcript,
                hasSummary: text.summary,
                hasTranslation: text.translation,
                customTitle: Self.readTitle(base: base, presentNames: presentNames)
            ))
        }

        for (base, mtime) in orphanMtimes {
            // Synthetic ".opus" so deletingPathExtension in the StorageLocations
            // helpers still yields `base` for these text-only entries.
            let text = Self.textFlags(base: base, presentNames: presentNames)
            built.append(LibraryItem(
                name: "\(base).opus",
                url: nil,
                size: 0,
                modifiedAt: mtime,
                duration: nil,
                hasTranscript: text.transcript,
                hasSummary: text.summary,
                hasTranslation: text.translation,
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

    /// A clip's text status: transcript / summary / translation.
    ///
    /// All three are **looked up in the already-listed directory names** — the scanner already has
    /// `presentNames` to hand, and another `fileExists` each would be 1900 entries × 3 wasted runs.
    private static func textFlags(
        base: String, presentNames: Set<String>
    ) -> (transcript: Bool, summary: Bool, translation: Bool) {
        (
            transcript: presentNames.contains("\(base).txt"),
            summary: presentNames.contains("\(base).summary.md"),
            translation: presentNames.contains("\(base).translated.txt")
                || presentNames.contains("\(base).summary.translated.md")
        )
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
