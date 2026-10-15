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

    private func row(_ item: ClipTrash.TrashedItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.body)
                .lineLimit(2)

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
        }
        .padding(.vertical, 2)
        // Swipe left to restore, swipe right to delete permanently — the same directional intuition as the system's "Recently Deleted":
        // right means "take it back", left means "push it out".
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                if !trash.restore(item, library: env.library) { restoreFailed = true }
                // The list must reflect "this one came back" immediately. `LibraryView`'s `.task` re-runs when
                // returning from the detail page, but the trash is another path, so it has to rely on this notification.
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
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
