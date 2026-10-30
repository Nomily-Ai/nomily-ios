import SwiftUI
import WatchKit

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
    /// 清空全部的二次确认开关（★ 2026-10-30）。
    @State private var showClearConfirm = false

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
                        // ★ 2026-10-30（用户："删除的时候不是全部删除摘要，点击删除
                        // 支持选择删除哪条摘要"）：左滑删**这一条**，不再只能清空全部。
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                withAnimation { store.remove(id: recap.id) }
                            } label: {
                                Label(L10n.Common.delete, systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.Watch.recapTitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !store.recaps.isEmpty {
                    // 清空全部退到二次确认——单条删除已经在行上，这里只留"全清"。
                    Button {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            L10n.Watch.recapClearAll,
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.Watch.recapClearAllConfirm, role: .destructive) {
                withAnimation { store.clear() }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
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
    @EnvironmentObject private var link: WatchLink
    /// ★ 2026-10-30：已经点过的待办（本地即时反馈，避免重复点）。
    @State private var sent: Set<String> = []

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

                // ★ 2026-10-30（用户："在里面可以查看到待办，支持在手表里面点击可以
                // 同步到手机的待办里面"）：点一条 → 手机写进「提醒事项」。
                if !recap.todos.isEmpty {
                    Text(L10n.Watch.recapTodos)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)

                    ForEach(recap.todos, id: \.self) { todo in
                        Button {
                            guard !sent.contains(todo) else { return }
                            sent.insert(todo)
                            link.requestReminder(title: todo, source: recap.title)
                            WKInterfaceDevice.current().play(.click)
                        } label: {
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: sent.contains(todo)
                                      ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(sent.contains(todo) ? Color.green : Color.accentColor)
                                    .padding(.top, 1)
                                Text(todo)
                                    .font(.system(size: 12))
                                    .foregroundStyle(sent.contains(todo) ? Color.secondary : Color.primary)
                                    .multilineTextAlignment(.leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Text(L10n.Watch.recapTodoHint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
        .navigationTitle(L10n.Watch.recapTitle)
    }
}
