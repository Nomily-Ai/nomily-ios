import SwiftUI

/// The wrist Recap page (★ 2026-10-23, "watch 那边能否靠 Siri Recap 的看齐").
///
/// Siri-Recap-shaped but Nomily's own content: one row per finished phone
/// summary — the recording's time, the digest title, and up to three key
/// points. Newest first, kept 7 days (the store prunes), cleared by hand with
/// the toolbar button.
///
/// ★★ 2026-10-23 (second pass, user: "在手表上能够显示一个只看到一个标题，就是一个
/// 题目，然后点进去才是主要内容，这样子，而不是直接把全部内容都展示出来，且不好看"):
/// the list used to print the title **and every point** in the same row, which on
/// a 40 mm screen turns one digest into a wall of text and the page into an
/// unreadable list. Each row is now **a title and its time only** — a table of
/// contents — and the points live on a pushed detail page.
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
                        NavigationLink {
                            WatchRecapDetailView(recap: recap)
                        } label: {
                            row(recap)
                        }
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

    /// One table-of-contents row: **the time, then the title**. The title is
    /// the "题目" the user asked for — two lines is enough to recognise a take,
    /// and the chevron `NavigationLink` already says "there is more inside".
    private func row(_ recap: WatchRecap) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(WatchFormat.dayTime(recap.recordedAt))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(recap.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
        }
        .padding(.vertical, 1)
    }
}

/// The body of one digest. Split out so the list above stays a list.
///
/// The title is repeated here as the page's headline (a wrist page can be
/// reached by a swipe, not only from the list, so it must stand alone), then
/// the same bulleted points the list used to inline.
struct WatchRecapDetailView: View {
    let recap: WatchRecap

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(WatchFormat.dayTime(recap.recordedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(recap.title)
                    .font(.system(size: 15, weight: .semibold))

                if recap.points.isEmpty {
                    Text(L10n.Watch.recapNoPoints)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text(L10n.Watch.recapPoints)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)

                    ForEach(Array(recap.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .top, spacing: 5) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 3.5, height: 3.5)
                                .padding(.top, 5)
                            Text(point)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
        .navigationTitle(L10n.Watch.recapTitle)
    }
}
