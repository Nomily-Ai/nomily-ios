import SwiftUI

/// The trash page (Settings → Trash).
///
/// ## Why this feature lives on the phone
/// The user's words were "need to add a trash feature in Settings to protect against accidental deletion, with a 30-day protection period".
/// Deletions happen on the phone anyway (multi-select in the library to delete a whole item, the detail page to delete audio/transcription/summary),
/// and only putting the trash on this side covers every entry point. On the watch the only thing you can delete is
/// the files on the recorder card, which can't "protect" the copy already pulled down to the phone.
///
/// ## There are three actions here, don't mix them up
/// * **Restore** — the files move back to the library and the device-download credential is put back too (otherwise the list's
///   source label becomes "Imported").
/// * **Delete permanently** — deletes just this one.
/// * **Empty** — deletes everything. Both deletions carry a confirmation prompt; restore doesn't need one (it's lossless).
///
/// ★ Second revision, 2026-10-15: all three actions now **have buttons sitting in the row**; swiping is just a shortcut.
/// In the first revision restore was only a left swipe and permanent delete only a right swipe, so what users saw on entering was rows and rows of "deletable"
/// records, and they fed back "why is there only delete". The same row also gained a **source**.
///
/// ★★ Fourteenth revision, 2026-10-16 (user: "trash supports multi-select and select-all to restore or delete"):
///
/// Multi-select mode is **entered and left with an explicit button**, not "long-press to enter" — the library enters multi-select on a long press
/// because its rows are **short** and a long press doesn't conflict; every trash row carries two buttons, so the long-press
/// recogniser would fight the buttons, and this page's rows are **tall** (four lines of content), so a mis-tap costs more.
///
/// * Toolbar: outside multi-select it's "Select" (left) + "Empty" (right); in multi-select it's
///   "Select all / Deselect all" (left) + "Done" (right) — "Empty" is **tucked away** in multi-select,
///   since it overlaps with multi-select's function, and having two destructive entry points side by side only interferes.
/// * Bottom: restore (lossless, no confirmation) + delete (**with** a confirmation that states the count in the dialog).
/// * Row: in multi-select the **whole row is tappable** (toggles the check), and the two in-row buttons and the swipe actions are tucked away —
///   leaving "restore this one" in place during multi-select makes people think the check didn't register.
struct TrashView: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var trash = ClipTrash.shared

    /// The pending action. An optional carries "which item" rather than a `Bool` plus a separate
    /// `@State` holding the item — the latter can be overwritten between the dialog appearing and the confirmation tap.
    @State private var pendingPurge: ClipTrash.TrashedItem?
    @State private var showPurgeAll = false
    @State private var restoreFailed = false

    // MARK: Multi-select state (★ fourteenth revision)

    /// Whether multi-select mode is active.
    @State private var isSelecting = false
    /// Which ones are checked. Stores `TrashedItem.id` (the deleted item's file name), not objects —
    /// the list changes at any moment from `purgeExpired()` / other entry points, and storing objects would capture a stale snapshot.
    @State private var selected: Set<String> = []
    /// The confirmation for batch permanent deletion.
    @State private var showPurgeSelected = false

    /// The checked items, in **list order** (not the order they were checked).
    ///
    /// ⚠️ It must filter once: `selected` may hold ids that have already been purged (say, right after tapping
    /// "Empty", or auto-purged when the 30-day period expired). Without filtering, a batch operation would get
    /// non-existent entries; `purge` is safe on that side, but the books wouldn't add up when "restore 3"
    /// actually restores 2.
    private var selectedItems: [ClipTrash.TrashedItem] {
        trash.items.filter { selected.contains($0.id) }
    }

    /// Whether everything is "selected". An empty list doesn't count as all-selected — the button should read "Select all" then.
    private var allSelected: Bool {
        !trash.items.isEmpty && selected.count == trash.items.count
    }

    /// ★ Thirteenth revision, 2026-10-16: follows the **app language** (`AppLocale`), not the device language.
    /// It used to be a `static let`, with locale defaulting to `Locale.current` — after choosing English in the app
    /// this column of times was still Chinese (another source of that "voice year/month/day" feedback).
    private static var dateFormatter: DateFormatter {
        AppLocale.formatter("trash.row_date") { f in
            f.dateStyle = .medium
            f.timeStyle = .short
        }
    }

    var body: some View {
        Group {
            if trash.items.isEmpty {
                EmptyStateView(
                    L10n.Trash.emptyTitle,
                    systemImage: "trash.slash",
                    message: L10n.Trash.emptyMessage
                )
            } else {
                List {
                    Section {
                        ForEach(trash.items) { item in
                            if isSelecting {
                                selectableRow(item)
                            } else {
                                row(item)
                            }
                        }
                    } footer: {
                        Text(L10n.Trash.retentionFooter(ClipTrash.retentionDays))
                    }
                }
            }
        }
        .navigationTitle(L10n.Trash.title)
        .navigationBarTitleDisplayMode(.inline)
        // ★ Fourteenth revision: the bottom action bar for multi-select mode.
        .safeAreaInset(edge: .bottom) { selectionBar }
        .toolbar { toolbarContent }
        // Entering this page purges expired items once — this is the second trigger for "auto-delete after 30 days"
        // (the first is at app launch). There's no background task to hook onto, so it relies on the user still opening it.
        //
        // ⚠️ It **mutates** `trash.items`, so orphan ids may be left behind in the selection set —
        //    `selectedItems` already handles it by "filter first", so nothing extra is needed here.
        .onAppear { trash.purgeExpired() }
        // Leaving this page closes multi-select: coming back should show an ordinary list,
        // not a multi-select mode "half checked with no idea what's checked".
        .onDisappear {
            isSelecting = false
            selected.removeAll()
        }
        .onChange(of: trash.items) { items in
            // ★ Fourteenth revision: sync the selection set when the list changes (when `purgeExpired` / another entry point purges items).
            //    Assign the intersection directly, which clears orphan ids on the way.
            let live = Set(items.map(\.id))
            selected.formIntersection(live)
            // Exit multi-select when nothing is left — staying in an empty multi-select mode only confuses people.
            if isSelecting, items.isEmpty { isSelecting = false }
        }
        .alert(
            L10n.Trash.deleteForeverTitle,
            isPresented: Binding(
                get: { pendingPurge != nil },
                set: { if !$0 { pendingPurge = nil } }
            ),
            presenting: pendingPurge
        ) { item in
            Button(L10n.Trash.deleteForever, role: .destructive) {
                trash.purge(item)
                selected.remove(item.id)
            }
            Button(L10n.Common.cancel, role: .cancel) { pendingPurge = nil }
        } message: { item in
            Text("\(item.title)\n\n\(L10n.Trash.deleteForeverMessage)")
        }
        .alert(L10n.Trash.emptyAllTitle, isPresented: $showPurgeAll) {
            Button(L10n.Trash.emptyAll, role: .destructive) { trash.purgeAll() }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Trash.emptyAllMessage(trash.items.count))
        }
        // ★ Fourteenth revision: the confirmation for batch permanent deletion. The count must be in the dialog — deletion is irreversible,
        //   and users have to know "how many am I deleting" before they tap.
        .alert(L10n.Trash.deleteSelectedTitle, isPresented: $showPurgeSelected) {
            Button(L10n.Trash.deleteSelected(selectedItems.count), role: .destructive) {
                purgeSelected()
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Trash.deleteSelectedMessage(selectedItems.count))
        }
        .alert(L10n.Trash.restoreFailedTitle, isPresented: $restoreFailed) {
            Button(L10n.Common.ok, role: .cancel) {}
        } message: {
            Text(L10n.Trash.restoreFailedMessage)
        }
    }

    // MARK: - Toolbar (★ fourteenth revision)

    /// Two forms: normal = Select + Empty; multi-select = Select all/Deselect all + Done.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !trash.items.isEmpty {
            if isSelecting {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(allSelected ? L10n.Trash.deselectAll : L10n.Trash.selectAll) {
                        if allSelected {
                            selected.removeAll()
                        } else {
                            selected = Set(trash.items.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Common.done) {
                        isSelecting = false
                        selected.removeAll()
                    }
                }
            } else {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.Trash.select) {
                        isSelecting = true
                        selected.removeAll()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Trash.emptyAll, role: .destructive) { showPurgeAll = true }
                }
            }
        }
    }

    // MARK: - Multi-select bottom action bar (★ fourteenth revision)

    /// Appears only in multi-select mode **and only when something is actually checked**.
    ///
    /// ⚠️ Uses `safeAreaInset` rather than `overlay(alignment: .bottom)`: the former **gives up**
    ///   the list's available height so the last row isn't hidden by this bar (`overlay` would cover it).
    @ViewBuilder
    private var selectionBar: some View {
        if isSelecting, !selectedItems.isEmpty {
            HStack(spacing: 12) {
                Button {
                    restoreSelected()
                } label: {
                    Label(L10n.Trash.restoreSelected(selectedItems.count),
                          systemImage: "arrow.uturn.backward")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)

                Button(role: .destructive) {
                    showPurgeSelected = true
                } label: {
                    Label(L10n.Trash.deleteSelected(selectedItems.count),
                          systemImage: "trash")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    // MARK: - One row

    /// One row.
    ///
    /// ★ Second revision, 2026-10-15 (user: "why is there only delete in the trash, and there also needs to be the source of the
    /// audio, plus restoring the current recording"):
    ///
    /// * **Source** — added as a small line under the title. The data was recorded **at the moment of deletion**
    ///   (`TrashedItem.source`), because the moment `move` runs it unregisters that
    ///   manifest entry, and asking `Library` afterwards only yields "Imported".
    /// * **Restore became an explicit button**. Originally only a **left swipe** offered restore, while a right swipe was permanent delete —
    ///   and the swipe directions on either side were known only to a single comment. Users saw only rows of "deletable" records
    ///   and naturally thought "why is there only delete here". Now both actions sit in the row:
    ///   restore (green, outlined) on the outside, permanent delete (red) on the far right, with swiping kept as before.
    private func row(_ item: ClipTrash.TrashedItem) -> some View {
        rowContent(item)
            // The swipe actions stay as before — a gesture is a shortcut for the experienced, a button is an entry point for everyone,
            // The two don't conflict. (Multi-select mode uses `selectableRow`, which doesn't attach this.)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    restore(item)
                } label: {
                    Label(L10n.Trash.restore, systemImage: "arrow.uturn.backward")
                }
                .tint(.green)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { pendingPurge = item } label: {
                    Label(L10n.Trash.deleteForever, systemImage: "trash")
                }
            }
    }

    /// A row's **content** (without the swipe actions).
    ///
    /// ★ Split out in the fourteenth revision: multi-select mode has to reuse this layout (`selectableRow`),
    /// but it **must not** carry swipe actions — a swipe gesture would fight the "whole row is tappable" check
    /// and multi-select already has batch entry points.
    ///
    /// ★ Second revision, 2026-10-15 (user: "why is there only delete in the trash, and there also needs to be the source of the
    /// audio, plus restoring the current recording"):
    ///
    /// * **Source** — added as a small line under the title. The data was recorded **at the moment of deletion**
    ///   (`TrashedItem.source`), because the moment `move` runs it unregisters that
    ///   manifest entry, and asking `Library` afterwards only yields "Imported".
    /// * **Restore became an explicit button**. Originally only a **left swipe** offered restore, while a right swipe was permanent delete —
    ///   and the swipe directions on either side were known only to a single comment. Users saw only rows of "deletable" records
    ///   and naturally thought "why is there only delete here". Now both actions sit in the row:
    ///   restore (green, outlined) on the outside, permanent delete (red) on the far right, with swiping kept as before.
    private func rowContent(_ item: ClipTrash.TrashedItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.body)
                .lineLimit(2)

            // The source. When an old index has no such field (`decodeIfPresent` gives nil) the whole line is hidden,
            // rather than filling in "unknown source" — which tells the user nothing at all.
            if let source = item.source, !source.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .imageScale(.small)
                    Text(source)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            // What's left inside. **It must be shown**: the trash may hold an item "with only the transcription deleted",
            // and by the title alone you'd think the whole thing is gone.
            HStack(spacing: 6) {
                if item.hasAudio { chip(L10n.Trash.artefactAudio, "waveform") }
                if item.hasTranscript { chip(L10n.Trash.artefactTranscript, "text.bubble") }
                if item.hasSummary { chip(L10n.Trash.artefactSummary, "doc.plaintext") }
            }

            HStack(spacing: 8) {
                Text("\(L10n.Trash.deletedOn) \(Self.dateFormatter.string(from: item.deletedAt))")
                if item.bytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                }
                Spacer(minLength: 4)
                Text(L10n.Trash.daysLeft(item.daysLeft))
                    .foregroundStyle(item.daysLeft <= 3 ? Color.orange : Color.secondary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            // Show both actions. Restore comes first (the primary action), permanent delete is pushed to the back —
            // restore is lossless, permanent delete is not.
            HStack(spacing: 8) {
                Button {
                    restore(item)
                } label: {
                    Label(L10n.Trash.restore, systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.green)

                Button(role: .destructive) {
                    pendingPurge = item
                } label: {
                    Label(L10n.Trash.deleteForever, systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
            .padding(.vertical, 4)
    }

    /// Restore one item.
    ///
    /// Pulled out into a function because there are now **two** entry points (the in-row button + left swipe) — writing it twice
    /// would sooner or later miss the notification from one of them. That `libraryDidChange` is essential:
    /// `LibraryView`'s `.task` only re-runs when returning from the detail page, and the trash is another path.
    private func restore(_ item: ClipTrash.TrashedItem) {
        if !trash.restore(item, library: env.library) { restoreFailed = true }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    // MARK: - Multi-select (★ fourteenth revision)

    /// A row in multi-select mode: **the whole row is tappable**, with a check circle on the left and all in-row buttons and swipes tucked away.
    ///
    /// ⚠️ It still uses `row`'s **content** (title / source / badge / time), just wrapped in a
    ///   button. Copy the layout and the two will sooner or later look different — and this page's rows were already
    ///   four layers of content, the kind least worth copying.
    private func selectableRow(_ item: ClipTrash.TrashedItem) -> some View {
        Button {
            toggle(item)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected.contains(item.id)
                        ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(selected.contains(item.id) ? Color.appAccent : Color.secondary)
                    // The check circle hugs the first line rather than the whole row — the row has four layers of content and centring would drift.
                    .padding(.top, 2)

                row(item)
                    // The two in-row buttons are meaningless in multi-select (there are batch entry points below),
                    // and the whole row becomes "toggle the check".
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected.contains(item.id) ? [.isSelected] : [])
    }

    private func toggle(_ item: ClipTrash.TrashedItem) {
        if selected.contains(item.id) {
            selected.remove(item.id)
        } else {
            selected.insert(item.id)
        }
    }

    /// Batch restore. **No confirmation** — restoring is lossless (files move back to the library),
    /// and popping up "are you sure you want to restore" only makes this page look like it's guarding against a good thing.
    ///
    /// The notification fires only once, **after the whole batch is done**: one re-run of `LibraryView`'s `.task` is enough,
    /// and firing per item would just make it re-run N times.
    private func restoreSelected() {
        var anyFailed = false
        for item in selectedItems {
            if !trash.restore(item, library: env.library) { anyFailed = true }
        }
        if anyFailed { restoreFailed = true }
        selected.removeAll()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    /// Batch permanent deletion. The dialog is in `body` (the count has to be written into the confirmation text).
    ///
    /// ⚠️ It iterates `selectedItems` — a **filtered, list-ordered** snapshot,
    ///   so however `trash.items` changes during the loop, it's unaffected.
    private func purgeSelected() {
        for item in selectedItems {
            trash.purge(item)
        }
        selected.removeAll()
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).imageScale(.small)
            Text(text)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
