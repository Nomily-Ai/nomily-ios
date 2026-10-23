import SwiftUI

/// The wrist Recap page (★ 2026-10-23, "watch 那边能否靠 Siri Recap 的看齐").
///
/// Siri-Recap-shaped but Nomily's own content: one row per finished phone
/// summary — the recording's time, the digest title, and up to three key
/// points. Newest first, kept 7 days (the store prunes), cleared by hand with
/// the toolbar button.
///
/// Deliberately a plain `List`, like `WatchQueueView`: this page renders at
/// most 8 entries and nothing about it needs custom paging or gesture plumbing.
struct WatchRecapView: View {
    @ObservedObject private var store = WatchRecapStore.shared

    var body: some View {
        Group {
            if store.recaps.isEmpty {
                // Reached straight from the home menu, so "empty" is a normal
                // first-run state and needs to say what fills the page.
                VStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text(L10n.Watch.recapEmpty)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                List {
                    ForEach(store.recaps) { recap in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(WatchFormat.dayTime(recap.recordedAt))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(recap.title)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(2)
                            ForEach(Array(recap.points.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .top, spacing: 4) {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 3, height: 3)
                                        .padding(.top, 5)
                                    Text(point)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(L10n.Watch.recapTitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !store.recaps.isEmpty {
                    Button {
                        store.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }
}
