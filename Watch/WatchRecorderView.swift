import SwiftUI
import WatchKit

/// Wrist recorder page.
///
/// ★ 2026-10-15 revision four (user's words: "remove the time from the top of the watch, and don't have a plain 'ready
/// to record' right in the middle; let the ring spin on its own even when you're not tapping record... it needs to be centered and not wobble,
/// otherwise the time on top and the transfers below throw it off-center and it looks bad"):
///
/// ```
///   ◉                    ◉      ← the corner buttons (gone entirely while recording)
///        ╭────────╮
///        │  ⌾ ring │             ← dead center of the screen, **always** here
///        ╰────────╯
///   ◉                    ◉
///          2 pending ›           ← a thin bar that only appears when things are pending, pressed against the very bottom of the screen
/// ```
///
/// Three changes:
///
/// * **The top time line is gone.** It used to be a column of "time / ring / byte count"; whichever
///   was longer or shorter pushed the ring off-center -- exactly the "off-center and it looks bad" the user described. Now the ring is the **only layout
///   subject** (a `ZStack` filling the screen), and everything else hangs on the edges as `overlay`s,
///   no matter how much is hung there it can't move the ring. The middle clock was originally a
///   by-product of "moving the top-right system clock in", and now that the system clock is hidden with
///   `.persistentSystemOverlays(.hidden)`, this line only takes up space.
/// * **The middle no longer says "ready".** That line is redundant now: while idle the whole ring slowly rotates
///   (see `WatchRingControl.idleRing`); "it's moving" is itself the standby signal,
///   clearer than four characters and it takes no room. Only a microphone is left in the middle.
/// * **The pending list shrinks from a long column to a thin hint at the bottom**, tap through to a separate page for details.
///   That list used to be squeezed in below the ring, and the idle ring already reaches nearly to the screen edge, so the moment something
///   is pending it shoves the ring off -- and "just finished recording" is exactly when the pending list is fullest.
struct WatchRecorderView: View {
    @EnvironmentObject private var model: WatchRecorderModel
    /// Transfer state is read straight off the link rather than snapshotted
    /// into `PendingClip`, so a queue that drains (or a transfer that fails)
    /// re-renders the row without the model having to notice.
    @EnvironmentObject private var link: WatchLink
    /// Appearance preference. Held as an `@ObservedObject` rather than reading `shared` each time -- after changing a color
    /// the UI must update immediately, and `WatchRingControl` is a plain `View`,
    /// so SwiftUI would not know to redraw (same pitfall as the top of `RecorderAliasStore`).
    @ObservedObject private var styleStore = WatchRingStyleStore.shared
    /// Shake toggle. It needs observing too: flip it in the settings page and this page has to start/stop sampling immediately.
    @ObservedObject private var prefs = WatchRecordingPrefs.shared
    /// ⚠️ It has to be `@State`, not `let`: this `View` struct is re-constructed on every redraw,
    /// and a `let` would create a fresh detector every time (the sampler gets swapped out the moment it starts, so it never takes effect).
    /// `@State` keeps it in SwiftUI's storage and initializes it only once.
    @State private var shake = WatchShakeDetector()

    /// Usable length of one side of the watch face: the actual screen width minus a 6pt inset on each side.
    ///
    /// ⚠️ Use `WKInterfaceDevice`'s **actual** screen width, never hard-code it -- the 40mm/44mm/45mm/49mm
    /// Screen widths run from 162 to 205pt, so hard-coding either end is wrong on at least one watch
    /// (the old hard-coded 172pt box was already overflowing on the 40mm anyway).
    private static var dialSide: CGFloat {
        max(132, WKInterfaceDevice.current().screenBounds.width - 6)
    }

    /// Fraction of `dialSide` the ring takes while idle.
    ///
    /// ⚠️ This value is **derived from the corner buttons' size**, not picked on its own:
    /// once the buttons get bigger (see `cornerSize`), the ring has to shrink a bit more, or the two tap targets
    /// would overlap -- tapping the ring's edge would become tapping the button. 0.74 is the setting where "34pt button + 40mm watch"
    /// just barely keeps the two apart.
    private static let idleRingFraction: CGFloat = 0.74
    /// Ring fraction while recording. While recording the 4 corner dots disappear entirely and all the freed-up space goes to the ring --
    /// Matching the Health app rings' "almost touching the screen edge" look.
    private static let recordingRingFraction: CGFloat = 0.90

    var body: some View {
        ZStack {
            dial
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { queueBar }
        // The "Watch" title line at the top is gone: the ring is this page's title.
        // What's hidden is **this page's** navigation bar; the pushed sub-pages have their own bars and back buttons.
        //
        // ⚠️ You need both: `.toolbar(.hidden, for: .navigationBar)` hides the navigation bar itself,
        // and `.persistentSystemOverlays(.hidden)` hides **the watchOS system clock
        // clock** -- the system clock isn't part of the navigation bar; hiding only the navigation bar won't necessarily take it along.
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(.hidden)
        .alert(
            L10n.Watch.recorderTitle,
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button(L10n.Common.ok) { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        .onAppear { syncShakeDetector() }
        // Stop sampling when leaving this page: keeping the accelerometer on is a big line on the battery bill,
        // and this page only comes to the foreground when you raise your wrist.
        .onDisappear { shake.stop() }
        .onChange(of: prefs.shakeToRecord) { _, _ in syncShakeDetector() }
    }

    // MARK: - The ring + the four corners

    /// The ring as one piece. While recording the ring steps up a size and the corner buttons vanish entirely, all inside the same spring
    /// transition -- "recording has started" is visible in the geometry too.
    ///
    /// ⚠️ A fixed `side × side` box, so the four dots' relative positions don't change with screen size;
    /// the full-screen `ZStack` outside is what pins it dead center.
    private var dial: some View {
        let side = Self.dialSide
        let fraction: CGFloat = model.isRecording
            ? Self.recordingRingFraction
            : Self.idleRingFraction
        return ZStack {
            WatchRingControl(
                isRecording: model.isRecording,
                elapsed: model.elapsed,
                detail: model.isRecording ? WatchFormat.bytes(model.currentBytes) : nil,
                style: styleStore.style,
                onToggle: model.toggleRecording
            )
            // Do the corner buttons change size with the recording state too? No -- they only exist while idle,
            // and the idle ring is fixed at 0.74; the two were aligned at that setting to begin with.
            .frame(width: side * fraction, height: side * fraction)

            if !model.isRecording {
                corners.transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .frame(width: side, height: side)
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: model.isRecording)
    }

    /// Those 4 corner buttons. Placed diagonally: a circle's corners are empty anyway, so the buttons neither cover the ring
    /// nor sit close enough to the center "start recording" target to cause accidental taps.
    ///
    /// ⚠️ Both the button size and the edge distance scale with the screen width (see `cornerSize` / `cornerInset`),
    /// and the order is **set the buttons first, then derive the ring**: on the 40mm the button is 34pt across, its center about 23pt from the screen corner,
    /// about 78pt from the ring's center, its inner edge ≈61pt; the ring's tap radius = 0.74 × 156 / 2 ≈ 58pt
    /// ⇒ the two are 3pt apart, so tapping the ring's edge won't be stolen by the button. A bigger ring would overlap.
    private var corners: some View {
        ZStack {
            corner(.color,     at: .topLeading,     tintIndex: 0)
            corner(.breathing, at: .topTrailing,    tintIndex: 1)
            corner(.language,  at: .bottomLeading,  tintIndex: 2)
            corner(.settings,  at: .bottomTrailing, tintIndex: 3)
        }
        .padding(Self.cornerInset)
    }

    /// Diameter of the corner buttons. Scaled to the screen width, **never hard-coded**.
    ///
    /// ★ 2026-10-15 revision three: originally hard-coded at 30pt; the user reported "the menu bar is too small right now".
    /// 0.22 × dialSide ⇒ 40mm ≈ 34pt / 45mm ≈ 42pt / 49mm Ultra ≈ 44pt ——
    /// On bigger watches the buttons grow too, instead of being the same small size on all four watch sizes.
    private static var cornerSize: CGFloat { (dialSide * 0.22).rounded() }

    /// Distance from the corner buttons to the screen edge, also scaled to the screen width,
    /// so "how far the buttons sit from the edge" looks the same on every watch.
    private static var cornerInset: CGFloat { (dialSide * 0.035).rounded() }

    /// A corner dot. **One tap pushes a separate page** (not an inline menu bar).
    ///
    /// ⚠️ `.frame(maxWidth:maxHeight:alignment:)` goes **outside the `NavigationLink`**:
    /// inside, it would turn the whole quadrant into a tap target, and tapping the ring's edge would count as tapping this dot.
    /// Outside, the link's own hit area is still just that circle and the frame only handles positioning
    /// (a transparent `.frame` container does not take part in hit testing, so taps pass through to the ring below).
    ///
    /// The icon takes its color from the palette (cycling: for the three-color palette that's magenta/green/cyan/magenta) --
    /// so the "four corners" are part of the current color scheme rather than four identical grays.
    private func corner(_ item: WatchRingCorner, at alignment: Alignment, tintIndex: Int) -> some View {
        NavigationLink {
            item.destination
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: (Self.cornerSize * 0.44).rounded(), weight: .semibold))
                .foregroundStyle(cornerTint(tintIndex))
                .frame(width: Self.cornerSize, height: Self.cornerSize)
                .background(Circle().fill(Color.white.opacity(0.13)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .accessibilityLabel(item.title)
    }

    /// Icon color for the `index`-th corner dot. Cycles through the palette without going out of bounds.
    private func cornerTint(_ index: Int) -> Color {
        let cs = styleStore.style.palette.colors
        guard !cs.isEmpty else { return Color(white: 0.75) }
        return cs[index % cs.count]
    }

    // MARK: - The pending hint bar

    /// The thin hint at the very bottom of the screen. **Only appears when something is pending**, about one line of text tall.
    ///
    /// Why collapse it into one bar: the idle ring takes 0.74 of the screen width, leaving only about thirty pt below it to the bottom of the screen,
    /// which is exactly where the bottom half of the corner buttons sits. Laying the old pending list out here pushed the ring up
    /// (user: "the transfers below aren't centered"), and covering the dots would block taps. A single hint bar,
    /// with details on a separate page, and none of the three conflict.
    @ViewBuilder
    private var queueBar: some View {
        if !model.pending.isEmpty {
            NavigationLink {
                WatchQueueView()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                    Text(L10n.Watch.pendingCount(model.pending.count))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(styleStore.style.palette.solid)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 2)
            .accessibilityLabel(L10n.Watch.pendingHeader)
        }
    }

    // MARK: - Shake

    /// Line the sampling state up with the current toggle. **Idempotent** -- called blindly from both `onAppear` and the toggle change.
    private func syncShakeDetector() {
        guard prefs.shakeToRecord else {
            shake.stop()
            return
        }
        shake.start { [model] in
            // Fire a haptic on trigger: at that moment nobody is looking at the screen (raising the wrist is the shake),
            // so without feedback you can't tell whether it actually started recording. Two different feels, "start/stop",
            // let the haptic alone tell start from stop.
            WKInterfaceDevice.current().play(model.isRecording ? .stop : .start)
            model.toggleRecording()
        }
    }
}

// MARK: - The pending page

/// The separate page for the pending list (reached by tapping the hint at the bottom of the home screen).
///
/// Splitting it off from the home screen is the price of "don't wobble": there's quite a lot to show there
/// (each item's name, size, state, retry, delete), and cramming it into the home screen would push the ring off.
struct WatchQueueView: View {
    @EnvironmentObject private var model: WatchRecorderModel
    @EnvironmentObject private var link: WatchLink

    var body: some View {
        List {
            ForEach(model.pending) { clip in
                // Queued or delivered-but-unconfirmed both read as "in flight";
                // only a clip with neither state needs the retry affordance.
                let isQueued = link.queuedNames.contains(clip.name)
                    || link.deliveredNames.contains(clip.name)
                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.displayTitle)
                        .font(.caption2)
                        .lineLimit(2)
                    Text("\(isQueued ? L10n.Watch.sending : L10n.Watch.waiting) · \(WatchFormat.bytes(clip.bytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if !isQueued {
                            Button { model.retry(clip) } label: {
                                Label(L10n.Common.retry, systemImage: "arrow.clockwise")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.Common.retry)
                        }
                        Button(role: .destructive) { model.delete(clip) } label: {
                            Label(L10n.Common.delete, systemImage: "trash")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.Common.delete)
                    }
                }
            }
        }
        .navigationTitle(L10n.Watch.pendingHeader)
    }
}

enum WatchFormat {
    /// What fits inside the ring. `mm:ss` while the hours field would only
    /// ever read zero — the ring's inner lap already carries "how far into the
    /// hour are we", so an `00:` prefix is four characters of nothing.
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        guard hours > 0 else {
            return String(format: "%02d:%02d", (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d:%02d", hours, (total / 60) % 60, total % 60)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
