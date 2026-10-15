import SwiftUI
import WatchKit

/// Wrist recorder page: the ring control, the four corner buttons around it,
/// and whatever is still waiting to reach the iPhone.
///
/// The elapsed time lives *inside* the ring rather than above it. It used to
/// be the page's headline, which made a wrist recorder read like a stopwatch;
/// the ring is the headline now — it answers "is it running?" without being
/// read — and the digits are demoted to a caption within it.
///
/// ★ 2026-10-15 revision two: this page is **rebuilt entirely after the Health app's activity-ring page** (user's words
/// "not beautiful or bold enough, just follow Apple Health's layout"). Top to bottom there are only three things:
///
/// ```
///        15:47          ← current time at the top (same as the Health app)
///      ╭────────╮
///   ◉  │  ring  │  ◉     ← the ring fills the screen width as much as possible
///      ╰────────╯
///   ◉              ◉
/// ```
///
/// * **Each of the 4 corner dots leads to its own page** (color / breathing light / language / settings),
///   no longer "tap to expand a little menu below the ring" -- the user explicitly asked for "a separate page";
/// * The old "gradient" dot merged into the color page, and "language" moved from a bottom text link into a dot,
///   the freed-up spot went to "settings (version + reset to default)";
/// * **The home screen carries no text links from now on**; the two small "language · version" lines are removed as well.
///
/// ⚠️ While recording the 4 corner dots **never appear** -- the user's own words
/// "once recording starts, the menu bar around the screen should not appear", so this is not "collapsed by default"
/// but rather no entry point at all while recording; the freed-up space lets the ring grow one more size.
///
/// ★ 2026-10-15 revision three (first round of feedback on real hardware):
/// * "the menu bar is too small right now" ⇒ the dots go from a **hard-coded 30pt** to a fraction of the screen width
///   (0.22 × screen width, see `cornerSize`), 40mm ≈34pt / 45mm ≈42pt,
///   so they grow on bigger watches; the ring shrinks from 0.80 to 0.74 to make room for the larger buttons;
/// * "remove the time in the top-right and show the time in the middle" ⇒ the top-right one **is the watchOS system
///   clock** (not one of our views, so it can only be hidden, not moved); we added
///   `.persistentSystemOverlays(.hidden)` to hide it; the middle one is our own drawn
///   `clock`, bumped from 20pt to 23pt at the same time.
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

    /// Diameter of the corner buttons. Scaled to the screen width, **never hard-coded**.
    ///
    /// ★ 2026-10-15 revision three: originally hard-coded at 30pt; the user reported "the menu bar is too small right now".
    /// 0.22 × dialSide ⇒ 40mm ≈ 34pt / 45mm ≈ 42pt / 49mm Ultra ≈ 44pt ——
    /// On bigger watches the buttons grow too, instead of being the same small size on all four watch sizes.
    private static var cornerSize: CGFloat { (dialSide * 0.22).rounded() }

    /// Distance from the corner buttons to the screen edge, also scaled to the screen width,
    /// so "how far the buttons sit from the edge" looks the same on every watch.
    private static var cornerInset: CGFloat { (dialSide * 0.035).rounded() }

    var body: some View {
        ScrollView {
            VStack(spacing: 2) {
                clock
                dial

                if model.isRecording {
                    Text(WatchFormat.bytes(model.currentBytes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if !model.pending.isEmpty { pendingList }
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 4)
        }
        // The "Watch" title line at the top is gone: the ring is this page's title.
        // What's hidden is **this page's** navigation bar; the 4 pushed sub-pages have their own bars and back buttons.
        //
        // ⚠️ You need both: `.toolbar(.hidden, for: .navigationBar)` hides the navigation bar itself,
        // and `.persistentSystemOverlays(.hidden)` hides **the watchOS system clock
        // layered on top of everything** (what the user means by "the time in the top-right") -- the system clock isn't part of the navigation bar,
        // so hiding only the navigation bar won't necessarily take it with it.
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
    }

    // MARK: - The time at the top

    /// Current time. This is the line at the top of the Health app's activity-ring page.
    ///
    /// ★ 2026-10-15 revision three: the user asked to "remove the time in the top-right and show the time in the middle" --
    /// the top-right one is the **watchOS system clock** (see the
    /// `.persistentSystemOverlays(.hidden)` in `body`); this line is the one we draw ourselves in the middle.
    /// The font size went from 20 to 23 too: the same order as that line in the Health app, heavy enough to hold its own below the ring.
    ///
    /// ⚠️ The outer `.frame(maxWidth: .infinity)` is there to **pin the centering**:
    /// this page's `ScrollView` content width is exactly the screen width; without the frame,
    /// the moment the content overflows, the time gets pushed off-center along with it.
    ///
    /// Use `TimelineView(.everyMinute)` instead of spinning up a `Timer`: it only
    /// redraws once when the minute ticks over, a negligible cost; `Text(_:style:.time)` follows
    /// the locale `LocalizedWatchRoot` injects, so 12/24-hour format follows the language.
    private var clock: some View {
        TimelineView(.everyMinute) { context in
            Text(context.date, style: .time)
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(white: 0.92))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - The ring + the four corners

    /// The ring as one piece. While recording the ring steps up a size and the corner buttons vanish entirely, all inside the same spring
    /// transition -- "recording has started" is visible in the geometry too.
    private var dial: some View {
        let side = Self.dialSide
        let fraction: CGFloat = model.isRecording
            ? Self.recordingRingFraction
            : Self.idleRingFraction
        return ZStack {
            WatchRingControl(
                isRecording: model.isRecording,
                elapsed: model.elapsed,
                style: styleStore.style,
                onToggle: model.toggleRecording
            )
            .frame(width: side * fraction, height: side * fraction)

            if !model.isRecording { corners.transition(.opacity) }
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

    // MARK: - Pending list

    private var pendingList: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.Watch.pendingHeader)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.pending) { clip in
                // Queued or delivered-but-unconfirmed both read as "in flight";
                // only a clip with neither state needs the retry affordance.
                let isQueued = link.queuedNames.contains(clip.name)
                    || link.deliveredNames.contains(clip.name)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(clip.displayTitle)
                                .font(.caption2)
                                .lineLimit(1)
                            Text("\(isQueued ? L10n.Watch.sending : L10n.Watch.waiting) · \(WatchFormat.bytes(clip.bytes))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !isQueued {
                            Button { model.retry(clip) } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.Common.retry)
                        }
                        Button(role: .destructive) { model.delete(clip) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.Common.delete)
                    }
                    Divider()
                }
            }
        }
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
