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
struct TrashView: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var trash = ClipTrash.shared

    /// The pending action. An optional carries "which item" rather than a `Bool` plus a separate
    /// `@State` holding the item — the latter can be overwritten between the dialog appearing and the confirmation tap.
    @State private var pendingPurge: ClipTrash.TrashedItem?
    @State private var showPurgeAll = false
    @State private var restoreFailed = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

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
                            row(item)
                        }
                    } footer: {
                        Text(L10n.Trash.retentionFooter(ClipTrash.retentionDays))
                    }
                }
            }
        }
        .navigationTitle(L10n.Trash.title)
        .toolbar {
            if !trash.items.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Trash.emptyAll, role: .destructive) { showPurgeAll = true }
                }
            }
        }
        // Entering this page purges expired items once — this is the second trigger for "auto-delete after 30 days"
        // (the first is at app launch). There's no background task to hook onto, so it relies on the user still opening it.
        .onAppear { trash.purgeExpired() }
        .alert(
            L10n.Trash.deleteForeverTitle,
            isPresented: Binding(
                get: { pendingPurge != nil },
                set: { if !$0 { pendingPurge = nil } }
            ),
            presenting: pendingPurge
        ) { item in
            Button(L10n.Trash.deleteForever, role: .destructive) { trash.purge(item) }
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
        .alert(L10n.Trash.restoreFailedTitle, isPresented: $restoreFailed) {
            Button(L10n.Common.ok, role: .cancel) {}
        } message: {
            Text(L10n.Trash.restoreFailedMessage)
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
        // The swipe actions stay as before — a gesture is a shortcut for the experienced, a button is an entry point for everyone,
        // and the two don't conflict.
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

    /// Restore one item.
    ///
    /// Pulled out into a function because there are now **two** entry points (the in-row button + left swipe) — writing it twice
    /// would sooner or later miss the notification from one of them. That `libraryDidChange` is essential:
    /// `LibraryView`'s `.task` only re-runs when returning from the detail page, and the trash is another path.
    private func restore(_ item: ClipTrash.TrashedItem) {
        if !trash.restore(item, library: env.library) { restoreFailed = true }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
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
