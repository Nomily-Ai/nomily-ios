import SwiftUI
import WatchKit

/// Wrist recorder page: the ring control, the four style dots around it,
/// and whatever is still waiting to reach the iPhone.
///
/// The elapsed time lives *inside* the ring rather than above it. It used to
/// be the page's headline, which made a wrist recorder read like a stopwatch;
/// the ring is the headline now — it answers "is it running?" without being
/// read — and the digits are demoted to a caption within it.
///
/// ★ Since 2026-10-15: the ring has **4 dots** around it (color / gradient / breathing light / reset);
/// tapping one expands a small row of options below the ring; **tapping the center = start / stop recording**.
/// ⚠️ While recording, the 4 dots and the menu **never appear** -- the user's own words:
/// "once recording starts, the menu bar around the screen should not appear", so this is not "collapsed by default"
/// but no entry point at all while recording (see `onChange(of: model.isRecording)`).
///
/// ★ 2026-10-15 revision two (the three things the user called out with a screenshot of the Health app's rings):
/// 1. **Delete the top title ("Watch")** -- the ring is the title; another line pressed on top
///    takes up screen space and nobody reads it anyway;
/// 2. **Match the Health app's screen ratio** -- the ring diameter now scales with the actual screen width
///    (0.76 idle, 0.90 recording, see `dial`). The old hard-coded 172pt box was already
///    overflowing on the 40mm watch (162pt wide) and too small on the 45mm anyway;
/// 3. **The ring steps up a size while recording**, the four corner menus vanish at the same time, and all the freed-up space goes to the ring.
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

    /// Usable length of one side of the watch face: the actual screen width minus a 3pt inset on each side.
    ///
    /// ⚠️ Use `WKInterfaceDevice`'s **actual** screen width, never hard-code it -- the 40mm/44mm/45mm/49mm
    /// screen widths run from 162 to 205pt, so hard-coding either end is wrong on at least one watch.
    private static var dialSide: CGFloat {
        max(132, WKInterfaceDevice.current().screenBounds.width - 6)
    }

    /// Fraction of `dialSide` the ring takes while idle. The gap left outside the ring is exactly what the 4 corner dots need;
    /// any larger and it overlaps the dots (already the tightest setting on the 40mm).
    private static let idleRingFraction: CGFloat = 0.76
    /// Ring fraction while recording. While recording the 4 dots are gone entirely, and all the freed-up space goes to the ring --
    /// matching the Health app rings' "almost touching the screen edge" look (about 88~90% of the screen width).
    private static let recordingRingFraction: CGFloat = 0.90

    /// Which menu is currently expanded; `nil` = no menu bar.
    @State private var openMenu: WatchRingMenu?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                dial

                if model.isRecording {
                    Text(WatchFormat.bytes(model.currentBytes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                // Menu bar: never shown while recording (see the type comment).
                if !model.isRecording, let menu = openMenu {
                    menuPanel(menu)
                }

                if !model.pending.isEmpty { pendingList }

                // Collapse the bottom link while a menu is expanded: otherwise the options and the link crowd together,
                // and mis-taps are very easy on the watch face.
                if !model.isRecording, openMenu == nil { footerLinks }
            }
            .padding(.horizontal, 3)
        }
        // The "Watch" title line at the top is gone: the ring is this page's title.
        // What's hidden is **this page's** navigation bar; the pushed language/about pages have their own bars and back buttons.
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: model.isRecording) { _, recording in
            // The moment recording starts, collapse the menu and never offer an entry point from then on.
            if recording { openMenu = nil }
        }
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

    // MARK: - The ring + the four corners

    /// The ring as one piece. While recording the ring steps up a size and the corner dots vanish entirely, all inside the same spring
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

            if !model.isRecording { menuDots.transition(.opacity) }
        }
        .frame(width: side, height: side)
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: model.isRecording)
    }

    // MARK: - The 4 dots around the ring

    /// Placed diagonally at the four corners of the ring: the corners of a circle are empty anyway, so the dots neither cover the ring
    /// nor sit close enough to the center "start recording" target to cause accidental taps.
    ///
    /// ⚠️ The outer circle is inset 6pt: that pushes each dot's center out to about `(side/2 - 21) × √2` from the middle,
    /// just outside the idle ring's outer edge (0.76 × side, see `dial`) -- on the 40mm that is already
    /// at the limit; make the ring smaller and it would overlap the dots.
    private var menuDots: some View {
        ZStack {
            dot(.color, at: .topLeading)
            dot(.gradient, at: .topTrailing)
            dot(.breathing, at: .bottomLeading)
            dot(.reset, at: .bottomTrailing)
        }
        .padding(6)
    }

    /// A corner dot.
    ///
    /// ⚠️ `.frame(maxWidth:maxHeight:alignment:)` goes **outside the Button**:
    /// inside, it would turn the whole quadrant into a tap target, and tapping the ring edge would count as tapping this dot.
    /// Outside, the button's own hit area is still just 30×30 and the frame only handles positioning
    /// (a transparent `.frame` container does not take part in hit testing, so taps pass through to the ring below).
    private func dot(_ menu: WatchRingMenu, at alignment: Alignment) -> some View {
        Button {
            // Tapping the same dot again = collapse, so there is no need to tap elsewhere.
            openMenu = (openMenu == menu) ? nil : menu
        } label: {
            Image(systemName: menu.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(openMenu == menu ? Color.black : Color.white.opacity(0.72))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(
                        openMenu == menu
                            ? styleStore.style.palette.solid
                            : Color.white.opacity(0.14)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .accessibilityLabel(menu.title)
    }

    // MARK: - Menu panel

    @ViewBuilder
    private func menuPanel(_ menu: WatchRingMenu) -> some View {
        VStack(spacing: 6) {
            Text(menu.title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            switch menu {
            case .color:
                paletteGrid
            case .gradient:
                optionRow(
                    [
                        (label: L10n.Watch.styleGradientOff, value: false),
                        (label: L10n.Watch.styleGradientOn, value: true),
                    ],
                    selected: styleStore.style.gradient
                ) { styleStore.style.gradient = $0 }
            case .breathing:
                optionRow(
                    WatchBreathing.allCases.map { (label: $0.label, value: $0) },
                    selected: styleStore.style.breathing
                ) { styleStore.style.breathing = $0 }
            case .reset:
                Button {
                    styleStore.reset()
                    openMenu = nil
                } label: {
                    Text(L10n.Watch.styleReset)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        // Collapse after selecting -- an extra "confirm" step on the watch face is just one more tap.
        .transition(.opacity)
    }

    /// 10 color swatches (the Health rings' three colors + the original 9 solids). Deliberately a palette and no color wheel:
    /// on the 40mm, drag-to-pick is neither precise nor visibly different.
    private var paletteGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
            spacing: 6
        ) {
            ForEach(WatchRingPalette.allCases) { palette in
                Button {
                    styleStore.style.palette = palette
                    openMenu = nil
                } label: {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: palette.colors,
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 26, height: 26)
                        .overlay(
                            Circle().strokeBorder(
                                Color.white,
                                lineWidth: styleStore.style.palette == palette ? 2 : 0
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(palette.rawValue)
            }
        }
    }

    /// A row of equal-width options (gradient off/on, breathing off/slow/medium/fast).
    private func optionRow<T: Equatable>(
        _ options: [(label: String, value: T)],
        selected: T,
        select: @escaping (T) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    select(option.value)
                    openMenu = nil
                } label: {
                    Text(option.label)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule().fill(
                                option.value == selected
                                    ? styleStore.style.palette.solid.opacity(0.9)
                                    : Color.white.opacity(0.12)
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Settings entry points, kept as two small text links rather than a
    /// toolbar button: the wrist has no room for one, and this page is short
    /// enough that they aren't buried. `Version` doubles as "did my new build
    /// actually reach the watch?" — the companion propagates updates on its own
    /// schedule, minutes after the iPhone app is replaced.
    private var footerLinks: some View {
        HStack(spacing: 6) {
            NavigationLink {
                WatchLanguageView()
            } label: {
                Text(L10n.Settings.language)
            }
            Text("·")
            NavigationLink {
                WatchAboutView()
            } label: {
                Text(L10n.Settings.version)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

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
