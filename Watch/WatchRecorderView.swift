import SwiftUI

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

    /// Side length of the square occupied by the ring + 4 dots.
    ///
    /// Deliberately a **fixed value** rather than `maxWidth: .infinity`: this page sits in a `ScrollView`,
    /// where the unbounded vertical proposal would send the `maxHeight: .infinity` corner dots to unpredictable
    /// positions. The ring is a bit smaller than before (160 → 152), giving the 20pt at the edge to the 4 dots.
    private static let controlBox: CGFloat = 172

    /// Which menu is currently expanded; `nil` = no menu bar.
    @State private var openMenu: WatchRingMenu?

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ZStack {
                    WatchRingControl(
                        isRecording: model.isRecording,
                        elapsed: model.elapsed,
                        style: styleStore.style,
                        onToggle: model.toggleRecording
                    )
                    .frame(maxWidth: 152)

                    if !model.isRecording { menuDots }
                }
                .frame(width: Self.controlBox, height: Self.controlBox)

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
            .padding(.horizontal, 6)
        }
        .navigationTitle(L10n.Watch.recorderTitle)
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

    // MARK: - The 4 dots around the ring

    /// Placed diagonally at the four corners of the ring: the corners of a circle are empty anyway, so the dots neither cover the ring
    /// nor sit close enough to the center "start recording" target to cause accidental taps.
    private var menuDots: some View {
        ZStack {
            dot(.color, at: .topLeading)
            dot(.gradient, at: .topTrailing)
            dot(.breathing, at: .bottomLeading)
            dot(.reset, at: .bottomTrailing)
        }
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
                .frame(width: 30, height: 30)
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

    /// 9 color swatches. A palette only, no color wheel: on 40mm, drag-to-pick is neither precise nor visibly different.
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
