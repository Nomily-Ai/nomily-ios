import SwiftUI

/// The "transcript ready" toast that slides down under the navigation bar.
///
/// ★ 2026-10-20, user's words: "有消息转录完成则弹出顶部导航栏提示告知转录完成".
///
/// ## Why a queue, not a single flag
/// Transcription runs as a batch (a card transfer or an import can enqueue several clips),
/// and each completion fires `TranscriptionService.onTranscribed` on its own. One
/// `@Published` flag would have later completions overwrite earlier ones — the user sees
/// one banner for five clips. So completions line up here and present one at a time;
/// each shows for 4 s (the auto-dismiss timer lives in the view's `.task(id:)`, which
/// SwiftUI cancels and restarts on every swap for free).
///
/// ## Titles resolve at enqueue time
/// `LibraryItem.readFromDisk` picks up the custom title; `RecordingName` renders the
/// timestamped fallback. Resolving **now** (not in the view) means the string is frozen
/// even if the user renames the clip while the toast is up — which is fine, the toast is
/// about the moment the text landed.
///
/// ## Staleness
/// Transcription can finish while the app is in the background; a "transcript ready"
/// popping up five minutes after unlocking is confusing rather than helpful, so
/// `RootView` calls `dropStale()` when the scene turns active — anything older than
/// 10 s never gets shown.
@MainActor
final class TranscriptionBannerCenter: ObservableObject {
    static let shared = TranscriptionBannerCenter()

    struct Banner: Equatable, Identifiable {
        let id = UUID()
        /// The audio file name (`LibraryItem.name`), used by the tap handler to deep-open the clip.
        let clipName: String
        /// The display title, resolved at enqueue time (custom title if present).
        let title: String
        let createdAt = Date()
    }

    /// The banner currently on screen; `nil` = none.
    @Published private(set) var current: Banner?

    private var queue: [Banner] = []

    /// A transcription just finished — line up its toast.
    func enqueue(clipName: String) {
        let title = LibraryItem.readFromDisk(name: clipName, duration: nil)?.displayTitle
            ?? RecordingName.displayTitle(for: clipName)
        queue.append(Banner(clipName: clipName, title: title))
        presentNext()
    }

    /// The user tapped the banner or the timer ran out — show the next one, if any.
    func dismissCurrent() {
        current = nil
        presentNext()
    }

    /// Drop everything queued (and the one on screen) when it's older than the window.
    /// Called on scene-becomes-active; a stale toast reads as "the app is broken",
    /// not "the transcript finished".
    func dropStale(olderThan: TimeInterval = 10) {
        let cutoff = Date().addingTimeInterval(-olderThan)
        if let shown = current, shown.createdAt < cutoff { current = nil }
        queue.removeAll { $0.createdAt < cutoff }
        presentNext()
    }

    private func presentNext() {
        guard current == nil, !queue.isEmpty else { return }
        current = queue.removeFirst()
    }
}

/// The toast card itself. Sits in a top-aligned `.overlay` on `RootView`'s `TabView`,
/// so it slides in right under the status bar — over the navigation bar, which is
/// exactly where the user asked for it ("顶部导航栏提示").
struct TranscriptionBannerView: View {
    @ObservedObject private var center = TranscriptionBannerCenter.shared
    /// Called when the user taps the card — deep-opens the clip (tab → segment → detail).
    var onOpen: (String) -> Void

    var body: some View {
        Group {
            if let banner = center.current {
                card(banner)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: center.current)
        // One timer per banner, restarted automatically: `.task(id:)` cancels the previous
        // sleep the moment the banner swaps, so a queued second toast gets its own full 4 s.
        .task(id: center.current?.id) {
            guard center.current != nil else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            center.dismissCurrent()
        }
    }

    private func card(_ banner: TranscriptionBannerCenter.Banner) -> some View {
        Button {
            onOpen(banner.clipName)
            center.dismissCurrent()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Banner.transcribeDone)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(banner.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule(style: .continuous).fill(.regularMaterial))
            .overlay(Capsule(style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
    }
}
