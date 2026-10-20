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
    /// ★ 2026-10-20: only read for `pendingClipOpen` — the tail end of the "transcript
    /// ready" banner's deep link. See `consumePendingClipOpen()`.
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var model = LibraryListModel()
    /// Solely so that "after a card is renamed, the source badge in the list follows along."
    ///
    /// Why the store must be hooked up as observed: the source badge takes the SN to
    /// `RecorderAliasStore` to look up the alias, and that is a **plain dictionary lookup** — SwiftUI doesn't know
    /// it needs to redraw — the comment at the top of `RecorderAliasStore` records the same pitfall
    /// (that's exactly how `DiscoveredRecorder.displayName` fell into it).
    @ObservedObject private var recorderAliases = RecorderAliasStore.shared
    /// The unread red dot relies on it. It must be hooked up as observed: `isUnread` is a **dictionary lookup**,
    /// and after opening detail and writing the name in, SwiftUI won't know to redraw on its own (the same pitfall appears in
    /// the `recorderAliases` comment above).
    @ObservedObject private var readStore = ClipReadStore.shared
    /// The ledger for "the last export is ready but not yet shared". Hooked up as observed:
    /// the export completes in a detached `Task`, and SwiftUI won't know on its own
    /// to redraw the banner (the same pitfall as `readStore` above).
    @ObservedObject private var exportCenter = ExportCenter.shared
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

    /// Show only one device. `nil` = all. The value is the key given by `deviceKey(_:)`.
    @State private var deviceFilter: String?

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
        content
        // ★ 2026-10-15 revision 7: the device filter bar is **pinned to the top of the list**, no longer hidden in a toolbar menu.
        //
        // Use `safeAreaInset` rather than stuffing it into `List`'s first section: stuffed in, it scrolls away with
        // the list — and "which device is being filtered right now" is exactly the information you most need to keep in sight while scrolling.
        //
        // Put it one layer below `.searchable`: the search bar is for search, the filter bar for filtering, both at the top,
        // not covering each other.
        .safeAreaInset(edge: .top, spacing: 0) {
            deviceFilterBar
        }
        .task {
            await model.refresh()
            dropStaleDeviceFilter()
            consumePendingClipOpen()
        }
        // A watch recording can land while this list is on screen; the file
        // arrives outside any SwiftUI lifecycle, so it has to say so.
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            Task {
                await model.refresh()
                dropStaleDeviceFilter()
            }
        }
        // Knowledge-base search. `.task(id:)` is the key: change the query or the scope and SwiftUI will
        // **cancel the previous run entirely**, so fast typing doesn't have several rounds of disk reading running at once.
        .task(id: searchKey) { await runSearch() }
        // ★ 2026-10-20: if the deep-link intent arrives while this list is already on
        // screen (user was browsing the library when the banner was tapped), consume it
        // right here; the `.task` above covers the fresh-mount path.
        .onChange(of: env.pendingClipOpen) { _ in consumePendingClipOpen() }
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

    /// Mirrors the cleanup list in `deleteURLs(for:)`, minus the in-memory
    /// player stop (we're operating from the Library, not Detail). Kept in
    /// sync deliberately — that's why it now just calls `deleteURLs(for:)`
    /// instead of listing the suffixes a second time: forgetting an artefact
    /// in one of the two copies leaves orphan files after a merge.
    ///
    /// ★ 2026-10-15: the two source recordings displaced by a merge also **go to the trash**. If the merged
    /// M4A sounds wrong (garbled, missing half), the two source recordings can still be recovered as they were —
    /// and this is exactly the classic case of "the user can't see the files, but they're really gone".
    ///
    /// ⚠️ **No download credential**: deregistering the manifest would make these two show up in the device list
    /// as "not downloaded" again, when they're actually on the user's phone (and in the trash right now).
    /// Merging doesn't touch the manifest anyway; this stays consistent with that.
    private func deleteSourceArtefacts(for item: LibraryItem) {
        ClipTrash.shared.move(
            [ClipTrash.Payload(
                localName: item.name,
                title: item.displayTitle,
                urls: Self.deleteURLs(for: item),
                download: nil,
                source: ClipTrash.sourceLabel(forLocalName: item.name, in: library)
            )],
            library: library
        )
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

    // MARK: - List / empty state

    /// Four choices: empty library / searching / filtered with no match / the actual content.
    ///
    /// Split out separately not for looks: `body` has `.searchable` + scopes + 5
    /// `.alert`s + a sheet + an overlay hanging off it, and cramming these four branches in makes the type checker
    /// time out (observed: "unable to type-check this expression in reasonable time").
    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            EmptyStateView(
                L10n.Recordings.noClipsYet,
                systemImage: "tray",
                message: L10n.Recordings.noClipsMessage
            )
        } else if isSearchActive, sections.isEmpty, isSearching {
            // The first search has to read from disk and build the index (a brief moment when the library has hundreds of entries with bodies).
            // During that time we **must not** report "nothing found" — that's a lie, and the user will think the search is wrong.
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sections.isEmpty {
            // Reaching here can only mean "filtered/searched with no match" (the library itself is non-empty, see the two branches above).
            EmptyStateView(
                L10n.Library.searchEmptyTitle,
                systemImage: "magnifyingglass",
                message: L10n.Library.searchEmptyMessage
            )
        } else {
            listContent
        }
    }

    /// One `Section` = one (time × device). The bucket title appears only on the first section header in its bucket
    /// (see `LibrarySection.showsBucketTitle`), so reading down you get
    /// a two-level "Today → three devices → Yesterday → …" structure, rather than repeating
    /// "Today" once for every device.
    private var listContent: some View {
        List {
            // ★ 2026-10-15 revision 6: the export-ready banner, **placed at the very top**.
            //
            // User's words: "exporting audio for large files takes a long wait, this needs to run in the background,
            // and also support tapping to transfer after the App finishes, so quitting doesn't mean waiting again".
            // A large-file export can outlast the user going off to do something else or even switching out of the App; if there's
            // no clue on the page when they come back, the only thing they can think of is to **export again**, and wait all over again.
            if let staged = exportCenter.ready {
                exportReadySection(staged)
            }
            ForEach(sections) { section in
                Section {
                    rows(of: section)
                } header: {
                    sectionHeader(section)
                }
            }
        }
        .environment(\.defaultMinListHeaderHeight, 0)
    }

    /// The last export is ready but not yet shared.
    ///
    /// Two actions: tap the whole row = share (the only forward action, so the whole row is tappable),
    /// the trash can on the right = clear this staging file to free up space (**doesn't touch** the user's library,
    /// it only deletes the copy made during export).
    private func exportReadySection(_ item: ExportCenter.Ready) -> some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    exportURL = ExportCenter.shared.url(for: item)
                    showExportSheet = exportURL != nil
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.Library.exportReady)
                                .foregroundStyle(.primary)
                            Text(Self.exportReadyDetail(item))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    ExportCenter.shared.discard()
                } label: {
                    Label(L10n.Library.clearExportStaging, systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Library.clearExportStaging)
            }
            .padding(.vertical, 2)
        } footer: {
            Text(L10n.Library.exportReadyFooter)
        }
    }

    private static func exportReadyDetail(_ item: ExportCenter.Ready) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        return "\(item.title) · \(L10n.Library.exportReadyFiles(item.itemCount)) · \(size)"
    }

    @ViewBuilder
    private func rows(of section: LibrarySection) -> some View {
        ForEach(section.entries) { entry in
            row(entry.item, at: entry.modelIndex, unread: entry.unread)
        }
    }

    // MARK: - List rows

    /// One row. Tap to open detail, long-press to enter multi-select, swipe right to merge.
    ///
    /// Use `LongPressGesture.exclusively(before: TapGesture())` rather than
    /// "Button + onLongPressGesture": in the latter the two gestures are recognised **independently**,
    /// so when you release a long press the Button's action may still fire once — which shows as "long-pressed to select,
    /// and it jumped into the detail page along the way". `exclusively` hard-codes the priority: if the long press wins, the tap isn't recognised.
    ///
    /// `unread` is **computed along the way** while sectioning and passed in; rows don't go back to the ledger:
    /// one `isUnread` is a dictionary lookup, and 1900 rows querying it on every redraw is unnecessary.
    private func row(_ item: LibraryItem, at index: Int, unread: Bool) -> some View {
        let isSelected = selectedIDs.contains(item.name)
        return HStack(spacing: 10) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Color.appAccent : Color.secondary)
                    .transition(.scale.combined(with: .opacity))
            }
            LibraryRow(
                item: item,
                source: library.source(forLocalName: item.name),
                snippet: snippets[item.base],
                isUnread: unread,
                isVoiceMemo: library.isVoiceMemo(forLocalName: item.name)
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

    /// Section header: the first line is the time bucket, the second the device.
    ///
    /// The bucket title appears once, on the first section of its bucket (the later devices in the same bucket don't repeat
    /// "Today") — that's what two-level grouping looks like. The right side of the bucket row carries the **whole bucket**'s
    /// count and size, not a single section's, or under "Today" three devices each write the numbers once,
    /// and you can't tell how many there were today in total.
    @ViewBuilder
    private func sectionHeader(_ section: LibrarySection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if section.showsBucketTitle {
                HStack(alignment: .firstTextBaseline) {
                    Text(section.bucketTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(L10n.Library.shortCount(section.bucketCount)) · \(formatBytes(section.bucketBytes))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(section.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if section.unreadCount > 0 {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text(L10n.Library.unreadCount(section.unreadCount))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        // The list uppercases and greys these by default; we want our own hierarchy.
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Derived state

    private var isSearchActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The entries actually visible in the list (after device filtering + search), before sectioning.
    /// "Whole screen" judgements like select-all and counts use it, not `model.items`.
    private var visibleEntries: [LibraryEntry] {
        sections.flatMap(\.entries)
    }

    /// Group the currently visible entries into two levels: **time → device**.
    ///
    /// One pass does three things at once: filter (device + search), record each entry's index in the **whole library**
    /// (`adjacentOlder` needs the whole library's time order to find neighbours), and slot them by bucket and device.
    /// Written separately it'd be three 1900-entry passes, and "what's displayed" would be scattered across two places,
    /// so adding one more filter later would inevitably miss one of them.
    private var sections: [LibrarySection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = !needle.isEmpty
        let filter = effectiveDeviceFilter

        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        // "This week" = the first day of the current calendar week. Use `dateInterval`, not "minus 7 days":
        // that follows the system locale's first day of the week (usually Monday in Chinese), and "this week" should be
        // this week, not "the last seven days".
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? startOfToday

        func bucket(of date: Date) -> LibraryTimeBucket {
            // When a device's RTC isn't set it may give a **future** time; those always join "Today",
            // otherwise a month nobody has seen before pops up at the top of the list.
            if date >= startOfToday { return .today }
            if date >= startOfYesterday { return .yesterday }
            if date >= weekStart { return .thisWeek }
            if date >= monthStart { return .thisMonth }
            let c = cal.dateComponents([.year, .month], from: date)
            return .month((c.year ?? 1970) * 100 + (c.month ?? 1))
        }

        // 1) Filter + slot. `model.items` is already newest-first, so appending in order to each
        //    (bucket, device) keeps buckets and groups naturally newest-first too; the device groups' order = that device's
        //    newest clip's order, with no extra sorting needed.
        var perBucket: [LibraryTimeBucket: [String: [LibraryEntry]]] = [:]
        var deviceOrder: [LibraryTimeBucket: [String]] = [:]
        var deviceNames: [String: String] = [:]

        for (index, item) in model.items.enumerated() {
            let key = deviceKey(for: item)
            if let filter, key != filter { continue }
            if searching {
                let inBody = snippets[item.base] != nil
                switch scope {
                case .knowledge:
                    if !inBody { continue }
                case .all:
                    // This is the one thing "All" has that "Knowledge base" doesn't: recordings not yet transcribed, with only a name.
                    if !inBody, !item.matchesName(needle) { continue }
                }
            }
            let b = bucket(of: item.recordedAt)
            if perBucket[b]?[key] == nil {
                deviceNames[key] = deviceName(for: item)
                deviceOrder[b, default: []].append(key)
            }
            perBucket[b, default: [:]][key, default: []].append(LibraryEntry(
                item: item,
                modelIndex: index,
                unread: readStore.isUnread(name: item.name, arrivedAt: item.modifiedAt)
            ))
        }

        // 2) Output newest-first (Today → Yesterday → This week → This month → months newest to oldest).
        var monthCache: [Int: String] = [:]
        func title(of b: LibraryTimeBucket) -> String {
            switch b {
            case .today: return L10n.Library.bucketToday
            case .yesterday: return L10n.Library.bucketYesterday
            case .thisWeek: return L10n.Library.bucketThisWeek
            case .thisMonth: return L10n.Library.bucketThisMonth
            case let .month(key):
                if let cached = monthCache[key] { return cached }
                let comps = DateComponents(year: key / 100, month: key % 100, day: 1)
                let text = Self.monthFormatter.string(from: cal.date(from: comps) ?? now)
                monthCache[key] = text
                return text
            }
        }

        let ordered = perBucket.keys.sorted {
            ($0.rank, $0.tiebreak) < ($1.rank, $1.tiebreak)
        }

        var out: [LibrarySection] = []
        for b in ordered {
            let groups = deviceOrder[b] ?? []
            let all = groups.flatMap { perBucket[b]?[$0] ?? [] }
            let bucketBytes = all.reduce(Int64(0)) { $0 + $1.item.size }
            for (i, key) in groups.enumerated() {
                let entries = perBucket[b]?[key] ?? []
                out.append(LibrarySection(
                    id: "\(b.id)|\(key)",
                    showsBucketTitle: i == 0,
                    bucketTitle: title(of: b),
                    deviceName: deviceNames[key] ?? key,
                    bucketCount: all.count,
                    bucketBytes: bucketBytes,
                    unreadCount: entries.reduce(0) { $0 + ($1.unread ? 1 : 0) },
                    entries: entries
                ))
            }
        }
        return out
    }

    /// "August 2026" / "2026-08". Assemble it per locale from the system's template format;
    /// gluing on the words "year" and "month" yourself is wrong in all 10 other languages.
    ///
    /// ★ 2026-10-16 revision 13: the locale comes from `AppLocale` (**set the locale first, then call the template**).
    ///
    /// ⚠️ This used to be a `static let`, and two independent problems stacked up:
    ///    ① the locale defaulted to `Locale.current` (the device language), so choosing English in the App had no effect;
    ///    ② `setLocalizedDateFormatFromTemplate` **bakes** the template into a concrete format string at the
    ///       **moment of the call**, using the formatter's locale at the time —
    ///       so even if the locale is changed later the template isn't recomputed. The formatter must be rebuilt,
    ///       which is exactly what `AppLocale.formatter(_:_:)`'s per-language-generation caching is for.
    private static var monthFormatter: DateFormatter {
        AppLocale.formatter("library.bucket_month") { $0.setLocalizedDateFormatFromTemplate("yMMMM") }
    }

    // MARK: - Device filter

    /// The device key used for grouping / filtering. **Two cards must be two groups**, so the SN goes into the key;
    /// the display name can be a user-changed alias — and the two must never be mixed up (aliases change,
    /// and the grouping falls apart the moment they do).
    private func deviceKey(for item: LibraryItem) -> String {
        let source = library.source(forLocalName: item.name)
        switch source.kind {
        case .card: return "card|\(source.serial ?? "")"
        default: return source.kind.rawValue
        }
    }

    private func deviceName(for item: LibraryItem) -> String {
        library.source(forLocalName: item.name).displayName
    }

    /// The devices that have appeared in the library, by count, most to least. Used for the filter items.
    private var availableDevices: [(key: String, name: String, count: Int, bytes: Int64)] {
        var order: [String] = []
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        var sizes: [String: Int64] = [:]
        for item in model.items {
            let key = deviceKey(for: item)
            if counts[key] == nil {
                order.append(key)
                names[key] = deviceName(for: item)
            }
            counts[key, default: 0] += 1
            sizes[key, default: 0] += item.size
        }
        return order
            .map { (key: $0, name: names[$0] ?? $0, count: counts[$0] ?? 0, bytes: sizes[$0] ?? 0) }
            .sorted { $0.count > $1.count }
    }

    /// Whether the selected device is **still in the library right now**. If not, treat it as "All".
    ///
    /// Why this layer rather than clearing `deviceFilter` after a refresh: after deleting the last recording of a
    /// device, the list must return to "All" immediately, rather than being stuck on an empty list waiting for
    /// the user to change it back in the menu themselves.
    private var effectiveDeviceFilter: String? {
        guard let deviceFilter else { return nil }
        return availableDevices.contains { $0.key == deviceFilter } ? deviceFilter : nil
    }

    /// Clear the selection once the device is no longer in the library. The pure computation layer already covers the display; this
    /// just makes the tick in the menu disappear too.
    private func dropStaleDeviceFilter() {
        guard let deviceFilter else { return }
        if !availableDevices.contains(where: { $0.key == deviceFilter }) {
            self.deviceFilter = nil
        }
    }

    // MARK: - Device filter bar (★ 2026-10-15 revision 7)
    //
    // It used to be a `Menu` on the toolbar. User's words: "that device filter isn't clear enough to understand,
    // ticking all isn't convenient for choosing; optimise it". The old design had three concrete problems:
    //   1. without entering the menu you **can't see which devices exist**, nor **which one is being filtered**;
    //   2. in the menu "All devices" sits side by side with each device, reading like a set of checkboxes
    //      ("All" looks like "everything is ticked") — when it's actually a **single choice**;
    //   3. each item drags "· 12 clips · 2.3 GB" behind it, and the line is too long and gets truncated by the system.
    // Switched to a horizontal pill bar, three things are laid out at once: what exists, how many each, and which is selected.

    /// Don't show the filter bar with only one device — there's nothing to filter, and one more row just crowds the list.
    ///
    /// The library usually has just two sources, the TicNote card and the phone; `availableDevices` being 1 means
    /// all recordings come from the same place, and filtering is then a **no-op**.
    private var showsDeviceBar: Bool { availableDevices.count > 1 }

    @ViewBuilder
    private var deviceFilterBar: some View {
        if showsDeviceBar {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    deviceFilterChip(
                        title: L10n.Library.filterAllDevices,
                        count: model.items.count,
                        selected: effectiveDeviceFilter == nil
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) { deviceFilter = nil }
                    }
                    ForEach(availableDevices, id: \.key) { device in
                        deviceFilterChip(
                            title: device.name,
                            count: device.count,
                            selected: effectiveDeviceFilter == device.key
                        ) {
                            withAnimation(.easeInOut(duration: 0.18)) { deviceFilter = device.key }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .accessibilityLabel(L10n.Library.filterDevices)
        }
    }

    /// One filter pill. Selected is a **solid accent**, unselected a light grey background — strong enough contrast that
    /// a glance tells you which one is filtered (the old menu's tick was only 14pt, nearly invisible).
    ///
    /// The count is a small rounded tag inside the pill rather than grey text after the name: device names vary in length
    /// ("TicNote Card · 3F2A" can fill half the screen), and following the text the count would drift out of sight.
    private func deviceFilterChip(
        title: String, count: Int, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(selected
                                       ? Color.white.opacity(0.28)
                                       : Color.primary.opacity(0.08))
                    )
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(selected ? Color.appAccent : Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                Capsule().stroke(selected ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Select all / derived

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
    /// And not by `visibleEntries` either: changing the filter after ticking shouldn't quietly drop what's ticked.
    private var selectedItems: [LibraryItem] {
        model.items.filter { selectedIDs.contains($0.name) }
    }

    /// "Select all" = select **what's on this screen** (which may be a searched subset, or a filtered
    /// single device), not the whole library.
    private var allItemsSelected: Bool {
        let names = Set(visibleEntries.map(\.item.name))
        return !names.isEmpty && names.isSubset(of: selectedIDs)
    }

    private func selectAllVisible() {
        selectedIDs = Set(visibleEntries.map(\.item.name))
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
                // ★ Revision 7: the button spells out "how many will be ticked".
                //
                // User's words: "ticking all isn't convenient for choosing". The old button only said "Select all", while select-all's scope
                // is **what's on this screen** (possibly already device-filtered and word-searched), and before tapping the user has no
                // idea how many will be ticked; only after tapping do they see "12 selected" below. Moving the number onto the button
                // makes the consequence of tapping or not visible at a glance.
                Button {
                    if allItemsSelected {
                        selectedIDs.removeAll()
                    } else {
                        selectAllVisible()
                    }
                } label: {
                    Text(allItemsSelected
                         ? L10n.Library.deselectAll
                         : L10n.Library.selectAllWithCount(visibleEntries.count))
                        .font(.subheadline)
                }
                .disabled(visibleEntries.isEmpty)

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

    // MARK: - Deep link from the transcript-ready banner

    /// ★ 2026-10-20: consume `env.pendingClipOpen` — the last layer of the deep link
    /// started by tapping the "transcript ready" toast (RootView switched tabs,
    /// `RecordingsView` switched segments; this list actually opens the clip).
    ///
    /// The scanned item is preferred (it carries the list's freshly computed flags);
    /// the single-entry disk read is the fallback for the common race where the banner
    /// fired while `model.refresh()` was still running and the clip isn't in `items`
    /// yet. Either way the intent is cleared first, so a failed open never loops back.
    private func consumePendingClipOpen() {
        guard let name = env.pendingClipOpen else { return }
        env.pendingClipOpen = nil
        guard let item = model.items.first(where: { $0.name == name })
            ?? LibraryItem.readFromDisk(name: name, duration: nil) else { return }
        detailItem = item
    }

    // MARK: - Batch export

    // ⚠️ The staging directory **is no longer here**. It used to be a fixed
    // `FileManager.default.temporaryDirectory/nomily-export`，2026-10-15
    // one that moved wholesale to `ExportCenter` in revision 6, for two reasons:
    //   1. `tmp` can be cleared by iOS at any time, and "export, switch away, come back and share" is exactly the path we need to support;
    //   2. we need somewhere to remember "what the last one prepared", or the user comes back to "wait from scratch again".
    // To get a directory use `ExportCenter.shared.beginNewStaging()`.

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
    private nonisolated static func textArtefacts(for item: LibraryItem) -> [(source: URL, name: String)] {
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
        // ★ 2026-10-15 revision 6: export (copying / re-encoding for large files) holds a background task alive for its whole duration.
        // User's words: "exporting audio for large files takes a long wait, this needs to run in the background".
        // Shares the same mechanism as transcription and summarisation; no separate one.
        BackgroundKeeper.shared.acquire(.export)
        defer { BackgroundKeeper.shared.release(.export) }

        let fm = FileManager.default
        // ⚠️ The staging directory **no longer writes to `tmp`**. `tmp` can be cleared by iOS at any time, and "export, switch away,
        //    come back and share" is exactly the path this round needs to support — it lives in the App container, and
        //    "which one is prepared" is persisted to disk (`ExportCenter`). Starting a new one deletes the last one along the way.
        let root: URL
        do {
            root = try ExportCenter.shared.beginNewStaging()
        } catch {
            exportError = error.localizedDescription
            return
        }

        var failures: [String] = []
        var staged = 0
        var bytes: Int64 = 0
        var taken = Set<String>()

        // ★ 2026-10-20 speed revision: the copy loop is **off the main actor** now.
        //
        // The whole View is MainActor-isolated (SwiftUI's View protocol is), so the previous
        // in-place loop copied GBs of bytes **on the main thread** — the entire app stuttered
        // for the whole batch, which is exactly the "导出太慢/卡" complaint. The structure now:
        //   · per item: folder naming + directory creation stay on the main actor (cheap string work,
        //     and `taken` is mutated here);
        //   · the actual byte copies (audio + text sidecars) run in a detached task — one hop per
        //     item, not per buffer, so the overhead is nil;
        //   · between items the busy overlay reports "exporting k/n: title" so a long batch no
        //     longer looks like a hang.
        for (index, item) in items.enumerated() {
            busyMessage = L10n.Library.exportProgress(index + 1, items.count, item.displayTitle)
            let dir = root.appendingPathComponent(
                Self.exportFolderName(for: item, taken: &taken), isDirectory: true
            )
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                exportError = error.localizedDescription
                return
            }
            let copied = await Task.detached(priority: .userInitiated) { () -> (staged: Int, bytes: Int64, failures: [String]) in
                Self.copyArtefacts(of: item, into: dir)
            }.value
            staged += copied.staged
            bytes += copied.bytes
            failures += copied.failures
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
        ExportCenter.shared.publish(
            id: root.lastPathComponent,
            title: L10n.Library.exportReadyTitle(items.count),
            itemCount: items.count,
            bytes: bytes,
            origin: nil
        )
        exportURL = root
        showExportSheet = true
    }

    /// One item's copies (audio + text sidecars) into its staging folder.
    ///
    /// ★ 2026-10-20 speed revision: deliberately `static` and pure I/O so it can run inside a
    /// detached task — nothing here touches view state. Per-item granularity (not per-buffer)
    /// keeps the hop overhead at zero while the multi-GB `copyItem` calls no longer block the UI.
    ///
    /// ⚠️ Must be `nonisolated`: the View's isolation would otherwise bleed into this static
    /// through protocol conformance, quietly putting the copies **back on the main actor** —
    /// the exact freeze this revision removes (and a hard error in Swift 6 mode).
    ///
    /// The audio keeps its **original filename** (the .opus / .m4a / .mp3 extension is how a player
    /// recognises it, so it can't be changed).
    private nonisolated static func copyArtefacts(
        of item: LibraryItem, into dir: URL
    ) -> (staged: Int, bytes: Int64, failures: [String]) {
        let fm = FileManager.default
        var staged = 0
        var bytes: Int64 = 0
        var failures: [String] = []
        if let url = item.url, fm.fileExists(atPath: url.path) {
            do {
                let dest = dir.appendingPathComponent(item.name)
                try fm.copyItem(at: url, to: dest)
                bytes += fileSize(dest)
                staged += 1
            } catch {
                failures.append("\(item.displayTitle): \(error.localizedDescription)")
            }
        }
        for artefact in textArtefacts(for: item)
        where fm.fileExists(atPath: artefact.source.path) {
            do {
                let dest = dir.appendingPathComponent(artefact.name)
                try fm.copyItem(at: artefact.source, to: dest)
                bytes += fileSize(dest)
                staged += 1
            } catch {
                failures.append("\(item.displayTitle): \(error.localizedDescription)")
            }
        }
        return (staged, bytes, failures)
    }

    private nonisolated static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    // MARK: - Batch delete

    /// Delete the whole clip: audio + transcript + summary + translation + custom title, plus deregistering
    /// the record in `Library`.
    ///
    /// ★ 2026-10-15: files are **no longer really deleted**, but moved as a whole group into the trash (`ClipTrash`),
    /// protected for 30 days. So this pass only handles "listing everything that should come along"; the moving and accounting happen in
    /// `ClipTrash.move` — which is also the "move the files first, then deregister the manifest" order,
    /// for the same reason as below.
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

        let payloads = items.map { item in
            ClipTrash.Payload(
                localName: item.name,
                title: item.displayTitle,
                urls: Self.deleteURLs(for: item),
                // The whole clip goes, so the "was downloaded from the device" credential must be deregistered too — miss it and
                // the same clip can never be downloaded again (in the device list it stays "downloaded" forever).
                download: ClipTrash.downloadRecord(forLocalName: item.name, in: library),
                // ★ 2026-10-15: the source is fixed **at the moment of deletion**. `move` deregisters the record
                // in the manifest along the way, and after that you can no longer find out where this recording came from.
                source: ClipTrash.sourceLabel(forLocalName: item.name, in: library)
            )
        }
        let moved = ClipTrash.shared.move(payloads, library: library)
        // Whether the cleanup action **itself reports an error** is decided here: a group that moved successfully is guaranteed to have moved all its
        // files, and a group that failed was rolled back as-is by `move`. So "which one still has files left" is the most accurate test.
        let stuck = moved < payloads.count
            ? payloads.filter { $0.urls.contains { FileManager.default.fileExists(atPath: $0.path) } }
            : []
        let failures = stuck.map(\.title)

        // The read ledger has to be cleared too — otherwise the table grows forever with "delete then download again", and a same-named
        // file downloaded again comes back mysteriously marked "read", and the user never sees that red dot again.
        readStore.forget(names: items.map(\.name))
        exitSelection()
        await model.refresh(force: true)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        if !failures.isEmpty {
            deleteError = failures.joined(separator: "\n")
        }
    }

    /// All the files a whole-clip delete has to move.
    ///
    /// Derive the paths from `LibraryItem` rather than a general directory scan: `item` already carries
    /// `url` / `base`, so appending suffixes is O(1); scanning the directory is hundreds of syscalls, and this is
    /// an action that can be tapped on the main thread.
    ///
    /// Includes the two **sidecar JSONs** `.asr.json` / `.translated.json` — the old
    /// `textArtefacts(for:)` only handled the four human-readable texts and left them out; and
    /// `ClipArtefact.of(fileNamed:)` recognises `.asr.json` as `.transcript`,
    /// so a leftover JSON is enough for the scanner to rebuild an entry that "has a transcript, but opens to nothing readable".
    private static func deleteURLs(for item: LibraryItem) -> [URL] {
        let t = StorageLocations.transcriptURLs(for: item.name)
        let tr = StorageLocations.translationURLs(for: item.name)
        var urls: [URL] = []
        if let url = item.url { urls.append(url) }
        urls.append(contentsOf: [
            t.txt, t.json, tr.txt, tr.json,
            StorageLocations.summaryURL(for: item.name),
            StorageLocations.summaryTranslatedURL(for: item.name),
            StorageLocations.titleURL(for: item.name),
        ])
        return urls
    }

    private func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: - The three grouping models

/// Time bucket. **`rank` is the display order**: Today → Yesterday → This week → This month → months newest to oldest.
///
/// Why two sort keys rather than mashing them into one integer: months must be ordered by year-and-month, and between them and
/// the first four ranks the only question is "which is on top". Written separately the sort is one tuple comparison, and a reader can see at a glance
/// that the months "sit at the very back, in reverse order internally".
private enum LibraryTimeBucket: Hashable {
    case today
    case yesterday
    case thisWeek
    case thisMonth
    /// Anything earlier, by month. The value is `yyyyMM` — sortable, usable as an id, and directly "year / month".
    case month(Int)

    var rank: Int {
        switch self {
        case .today: return 0
        case .yesterday: return 1
        case .thisWeek: return 2
        case .thisMonth: return 3
        case .month: return 4
        }
    }

    /// Within the same rank, sort again: the newer the month the higher (hence the negation).
    var tiebreak: Int {
        if case let .month(key) = self { return -key }
        return 0
    }

    var id: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "week"
        case .thisMonth: return "month"
        case let .month(key): return "m\(key)"
        }
    }
}

/// A row in the list: the entry + its index in the **whole library** (`model.items`).
///
/// The index is for `adjacentOlder(at:)` — it finds the adjacent previous clip by the whole library's time order.
/// Using a post-filter index would point at someone else, and a swipe-to-merge would fuse two completely unrelated recordings.
///
/// `unread` is computed **in the grouping pass**: one `isUnread` is a ledger query,
/// and 1900 rows each querying on every redraw is unnecessary — plus section headers also have to count "how many unread in this section".
private struct LibraryEntry: Identifiable {
    let item: LibraryItem
    let modelIndex: Int
    let unread: Bool
    var id: String { item.id }
}

/// One (time × device) section.
private struct LibrarySection: Identifiable {
    let id: String
    /// The first section of a given time bucket — the bucket title is written only above it, and the later devices
    /// in the same bucket don't repeat "Today".
    let showsBucketTitle: Bool
    let bucketTitle: String
    let deviceName: String
    /// The **whole bucket**'s total (not this section's): otherwise under "Today" three devices each write the numbers once,
    /// and you can't tell how many there were today in total.
    let bucketCount: Int
    let bucketBytes: Int64
    let unreadCount: Int
    let entries: [LibraryEntry]
}

private struct LibraryRow: View {
    let item: LibraryItem
    let source: Library.ClipSource
    /// The body text where knowledge-base search matched (`nil` = not searching, or this entry's body didn't match).
    ///
    /// The caller looks it up in `snippets` and passes it in; the row itself doesn't touch the search — the list scrolls,
    /// and a row shouldn't have the cost of "looking it up itself".
    var snippet: String? = nil
    /// not opened yet — a red dot hangs before the title.
    var isUnread: Bool = false
    /// ★ (2026-10-19) Recorded with the card's voice key — an AI voice memo, badged "Memo".
    var isVoiceMemo: Bool = false

    /// For the few with a customised title, the date is appended after the source badge.
    ///
    /// ★ 2026-10-16 revision 13: this used to be a **hard-coded** `"MM-dd HH:mm"`.
    /// A hard-coded template is simply wrong in other languages (German wants "17.04.", Japanese its own kanji order),
    /// and it's the last place in the whole App where "the date doesn't follow the App language".
    /// Switch to the system template `yMMMd jm` — `j` is "the locale's preferred hour cycle",
    /// so English/Arabic use 12-hour and Chinese/Japanese/German use 24-hour, with no need to decide yourself.
    private static var shortDate: DateFormatter {
        AppLocale.formatter("library.row_date") { $0.setLocalizedDateFormatFromTemplate("yMMMd jm") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isUnread {
                    // The red dot goes **before** the title, not on the right: the right is already taken by the transcript/summary badge
                    // and various states, and "is there anything new" has to be seen at the first glance down the list.
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(L10n.Library.unread)
                }
                Text(item.displayTitle)
                    .font(.body)
                    .lineLimit(2)
                if isVoiceMemo {
                    // ★ (2026-10-19) AI voice memo (the card's voice key) — visually distinct
                    // from regular recordings, per the user's "把录音功能跟语音备忘录功能区分开来".
                    Text(L10n.Library.voiceMemoBadge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.appAccent.opacity(0.15)))
                        .foregroundStyle(Color.appAccent)
                }
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
        let text = source.displayName
        HStack(spacing: 3) {
            Image(systemName: Self.symbol(for: source.kind))
                .imageScale(.small)
            Text(text)
        }
        .accessibilityLabel(L10n.Library.sourceAccessibility(text))
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

extension Library.ClipSource {
    /// This device's display name. The list row's badge and the section header use the **same one** —
    /// write it in both places and changing the alias rules produces "the row says the new name,
    /// the group title is still the old name".
    ///
    /// The card naming order is deliberately **user alias → name recorded at persistence → fallback word**,
    /// with the **last 4 digits of the SN** uniformly appended: two cards of the same model both labeled "Recorder Card" are indistinguishable,
    /// while the SN's last 4 digits happen to match the Wi-Fi hotspot naming convention (`TicNote-3N9H`),
    /// so users can match them up directly (see `protocol-notes.md` §18.1).
    ///
    /// The alias is looked up **at display time**, not frozen into storage — so when the user renames a card later,
    /// Old records' labels and group titles change too, without leaving a pile of stale names behind.
    var displayName: String {
        switch kind {
        case .watch:
            return L10n.Library.sourceWatch
        case .phone:
            return L10n.Library.sourcePhone
        case .imported:
            return L10n.Library.sourceImported
        case .card:
            let alias = serial.flatMap {
                RecorderAliasStore.shared.alias(identityHex: $0)
            }
            let unit = alias ?? storedName ?? L10n.Library.sourceCard
            guard let suffix = Self.serialSuffix(serial) else { return unit }
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
    /// SwiftUI asked for it. Now feeds the "all devices" row of the filter
    /// menu (the old bottom-of-list footer was removed in favour of
    /// per-section totals).
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
