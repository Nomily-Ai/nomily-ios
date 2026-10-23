import Foundation

/// Watch-side store of the recaps the iPhone pushes (★ 2026-10-23,
/// "watch 那边能否靠 Siri Recap 的看齐").
///
/// Apple's Siri Recap (watchOS 26+, S11, opt-in beta, not offered in China)
/// showed what a wrist digest could be — this is Nomily's own: the phone's
/// summary runner extracts title + ≤3 key points per finished summary and
/// pushes them through `updateApplicationContext` (`WatchLinkMessage.recapsKey`).
///
/// ## Why a store rather than reading the context directly
/// The application context is "latest wins" plumbing, not state: it can be
/// read only inside the delegate callbacks, and a context the watch receives
/// while this app is suspended is handed over on the *next* activation. A
/// persisted store decouples the two — `WatchLink` feeds it, the Recap page
/// reads it whenever it is on screen, and a cold launch shows what was last
/// delivered even before any new push.
///
/// ## Retention mirrors the phone side
/// Cap 8, drop anything older than 7 days (by `createdAt`), re-summarising the
/// same clip replaces its entry — the same numbers `WatchSyncService` keeps in
/// its outbox, so both ends stay in step without talking to each other.
@MainActor
final class WatchRecapStore: ObservableObject {
    static let shared = WatchRecapStore()

    @Published private(set) var recaps: [WatchRecap] = []

    private static let key = "watch.recaps.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([WatchRecap].self, from: data) {
            recaps = Self.prune(saved)
        }
    }

    /// Feed the recaps carried in a phone-pushed application context. Safe to
    /// call with any context — a context without the key (an old phone, or the
    /// watch's own push looped back) changes nothing.
    func apply(_ context: [String: Any]) {
        guard let data = context[WatchLinkMessage.recapsKey] as? Data,
              let incoming = try? JSONDecoder().decode([WatchRecap].self, from: data),
              !incoming.isEmpty else { return }
        // Merge by id: newer `createdAt` wins. A full replace would resurrect
        // a race where the phone's outbox was rebuilt from an older push and
        // quietly deleted recaps that arrived in between — can't happen with
        // one context slot, but the merge costs four lines and makes the
        // store indifferent to push ordering.
        var merged = recaps
        for recap in incoming {
            if let index = merged.firstIndex(where: { $0.id == recap.id }) {
                if recap.createdAt > merged[index].createdAt {
                    merged[index] = recap
                }
            } else {
                merged.insert(recap, at: 0)
            }
        }
        merged = Self.prune(merged)
        guard merged != recaps else { return }
        recaps = merged
        persist()
    }

    /// Manual clear (the Recap page's toolbar button). Clears **locally** —
    /// the phone's outbox is untouched, so the next context push re-delivers
    /// what's still within retention there. That is deliberate: the phone is
    /// the source of truth, and the watch has no channel to ask it to forget.
    func clear() {
        recaps = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(recaps) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private static func prune(_ recaps: [WatchRecap]) -> [WatchRecap] {
        let cutoff = Date().addingTimeInterval(-WatchRecap.retention)
        return Array(recaps.filter { $0.createdAt > cutoff }.prefix(WatchRecap.limit))
    }
}
