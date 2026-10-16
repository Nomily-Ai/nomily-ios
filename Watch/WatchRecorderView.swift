import SwiftUI
import WatchKit

/// Wrist recorder page.
///
/// ★ 2026-10-16 revision seven (user's words: "make it like Grok Bot, two eyes, then look at how they
/// do the natural-blinking animations; the 4 menus should appear when you swipe left or right; remove the record button from the home screen
/// and make it alive like the bot; start recording by holding its eyes for 2s, or with the earlier gestures
/// and shake to start and stop recording"):
///
/// ```
///   swipe right ←┊            ┊→ swipe left
///   ┌────────┐  ┌────────┐  ┌────────┐
///   │ ◉ Appearance │  │        │  │ ◉ Language │
///   │ ◉ Transfers │  │  ⬤⬤    │  │ ◉ Settings │
///   │ ⊕ Edit │  │  Bot   │  │ ⊕ Edit │
///   └────────┘  └────────┘  └────────┘
///                   2 pending ›
/// ```
///
/// Three things change at once:
///
/// * **The ring button in the middle becomes a Bot face** (`WatchBotFace`). The ring's "one tap starts recording"
///   misfires far too easily on the wrist, and raising it to check the time or a brush from a cuff would start recording. Now a **2-second hold**
///   is what starts it -- 2 seconds is long enough that "raise the wrist to check the time" never misfires, yet short enough that when you really want
///   to record you don't feel like you're waiting.
/// * **The 4 corner dots move to the left and right pages** (user: "they should appear when you swipe left or right"). The center of the home screen
///   is therefore cleared completely for the Bot; the buttons that used to be pinned to the four corners take that old "fighting the ring for space" problem with them
///   (see the "0.74 is derived from the corner dot size" passage in `WatchRingControl`).
///   Which items go there is up to the user (see `WatchMenuPreferences`), and both pages have an "Edit" entry at the bottom.
/// * **The hold has a charge ring.** Without it the user doesn't know how long to press, or whether their press
///   was even recognized -- an interaction that "only reacts after two seconds" must have "progress" feedback, or it reads
///   as "I pressed and nothing happened".
///
/// Three ways to start/stop recording are **all live at once**, all landing on `model.toggleRecording()`:
///   1. Hold the face for 2 seconds (start) -- the gesture lives on the face, see `WatchBotFace`;
///   2. Double tap (start/stop; there's a toggle on watchOS 11+, and 10.x dispatches it automatically) --
///      also attached to the face, see `PrimaryHandGesture`;
///   3. Shake (start/stop) -- the only one not on the face, see `WatchShakeDetector`.
///
/// ⚠️ **A tap while idle does not record**, it just gives a bounce. This is the very habit this revision set out to break:
///    "one tap records" misfires far too easily on the wrist. So a finger tap only does something while recording (stop).
///    To start, hold for 2 seconds, double tap, or shake.
struct WatchRecorderView: View {
    @EnvironmentObject private var model: WatchRecorderModel
    /// Transfer state is read straight off the link rather than snapshotted
    /// into `PendingClip`, so a queue that drains (or a transfer that fails)
    /// re-renders the row without the model having to notice.
    @EnvironmentObject private var link: WatchLink
    /// Appearance preference. Held as an `@ObservedObject` rather than reading `shared` each time -- after changing a color
    /// the UI must update immediately, and `WatchBotFace` is a plain `View`,
    /// so SwiftUI would not know to redraw (same pitfall as the top of `RecorderAliasStore`).
    @ObservedObject private var styleStore = WatchRingStyleStore.shared
    /// Shake / double-tap toggle. It needs observing too: flip it in the settings page and it has to take effect here immediately.
    @ObservedObject private var prefs = WatchRecordingPrefs.shared
    /// Which items go on the two side menus. Tick one in the settings page and this page has to re-lay-out at once.
    @ObservedObject private var menuPrefs = WatchMenuPreferences.shared
    /// ⚠️ It has to be `@State`, not `let`: this `View` struct is re-constructed on every redraw,
    /// and a `let` would create a fresh detector every time (the sampler gets swapped out the moment it starts, so it never takes effect).
    /// `@State` keeps it in SwiftUI's storage and initializes it only once.
    @State private var shake = WatchShakeDetector()

    /// Current page of the horizontal paging: 0 = left menu page, 1 = Bot, 2 = right menu page.
    ///
    /// Defaults to **1** (Bot) -- the first thing you see when you raise your wrist has to be the page that "starts recording right away",
    /// not a menu page.
    @State private var page: Int = 1
    /// Number of times it's tapped while idle, handed to `WatchBotFace` for a single bounce.
    @State private var pokeTick = 0
    /// Just after a hold has fired, **swallow the tap that comes right behind it**.
    ///
    /// ⚠️ This is where the whole interaction chain is most likely to fall apart: the hold gesture succeeds, and as the user lifts their finger,
    /// the `Button`'s tap comes right after (the face itself is that button), so "hold to start recording"
    /// is immediately overridden by "lift = stop" and the user never gets a recording. A brief time gate
    /// swallows that lift.
    @State private var tapGateUntil = Date.distantPast

    /// Usable length of one side of the watch face: the actual screen width minus a 6pt inset on each side.
    ///
    /// ⚠️ Use `WKInterfaceDevice`'s **actual** screen width, never hard-code it -- the 40mm/44mm/45mm/49mm
    /// screen widths run from 162 to 205pt, so hard-coding either end is wrong on at least one watch.
    private static var dialSide: CGFloat {
        max(132, WKInterfaceDevice.current().screenBounds.width - 6)
    }

    /// Fraction of the screen width taken by the Bot face's side length.
    ///
    /// ⚠️ It leaves room for two things: the charge ring around the face (1.14×) and the line of
    /// status text below the face (timer/hint). 0.70 is 109pt on the 40mm, 124pt including the ring,
    /// and with a line of text it still fits in a 162×194 screen.
    private static let botFraction: CGFloat = 0.70

    var body: some View {
        TabView(selection: $page) {
            menuPane(menuPrefs.leadingItems).tag(0)
            botPane.tag(1)
            menuPane(menuPrefs.trailingItems).tag(2)
        }
        // ⚠️ `.page` is **horizontal** paging. watchOS's `TabView` is vertical by default (Digital Crown scrolling),
        //    and what the user wants is "swipe left or right".
        // ⚠️ `indexDisplayMode: .never`: the system's row of little dots is tiny and blurry on the watch face,
        //    and it pushes each page down -- the home screen has only one face, so being pushed off is obvious.
        .tabViewStyle(.page(indexDisplayMode: .never))
        .overlay(alignment: .bottom) { queueBar }
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

    // MARK: - The Bot home screen

    /// That Bot face. Hold to start, tap to stop, double tap to start/stop -- **all three live on it**
    /// (see the passage at the top of `WatchBotFace`); this is only responsible for catching its two callbacks.
    private var botPane: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)

            WatchBotFace(
                size: Self.dialSide * Self.botFraction,
                isRecording: model.isRecording,
                style: styleStore.style,
                pokeTick: pokeTick,
                handGestureEnabled: prefs.pinchToRecord,
                onTap: handleTap,
                onHold: beginRecordingByHold,
                onToggle: handleToggle
            )

            caption

            // Leave room for the pending hint at the bottom so the two don't overlap.
            Spacer(minLength: 0).frame(height: 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The small line below the face. While idle it's a usage hint; while recording it's the timer + byte count.
    ///
    /// ⚠️ While idle that hint **cannot be dropped**. "Hold for 2 seconds" is an **invisible** interaction --
    /// without the hint, a first-time user just pokes once, finds nothing happens, and gives up.
    @ViewBuilder
    private var caption: some View {
        if model.isRecording {
            HStack(spacing: 5) {
                Text(WatchFormat.compactDuration(model.elapsed))
                    .monospacedDigit()
                Text("·")
                Text(WatchFormat.bytes(model.currentBytes))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(styleStore.style.palette.solid)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        } else {
            Text(L10n.Watch.holdToRecord)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// The hold reaches 2 seconds (the progress ring has already been taken care of by `WatchBotFace` itself).
    private func beginRecordingByHold() {
        guard !model.isRecording else { return }
        // The lift is read by the `Button` as a tap (see the `tapGateUntil` passage).
        tapGateUntil = Date().addingTimeInterval(0.5)
        model.toggleRecording()
    }

    /// Tap. While recording = stop; while idle = just a poke.
    ///
    /// ⚠️ Not starting a recording **while idle** is deliberate: "one tap records" is exactly the habit this revision set out to break
    /// (raising the wrist to check the time, or a brush from a cuff, would start recording). To start, hold for 2 seconds, double tap, or shake.
    private func handleTap() {
        guard Date() >= tapGateUntil else { return }
        if model.isRecording {
            model.toggleRecording()
        } else {
            pokeTick += 1
        }
    }

    /// Double tap. Start / stop.
    ///
    /// Shares the same `Button` as the tap, and `WatchBotFace.handlePrimaryAction()` tells them apart by
    /// "whether this one came with a touch" (a double tap is an in-air gesture with no touch).
    private func handleToggle() {
        guard Date() >= tapGateUntil else { return }
        model.toggleRecording()
    }

    // MARK: - The two side swipe menus

    /// One menu page. When `items` is empty it shows "add some in settings" rather than a blank page --
    /// a blank page looks broken.
    private func menuPane(_ items: [WatchHomeMenu]) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            if items.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text(L10n.Watch.quickMenuEmpty)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    NavigationLink {
                        item.destination
                    } label: {
                        menuTile(item, tintIndex: index)
                    }
                    .buttonStyle(.plain)
                }
            }

            editTile

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A menu item. The icon takes its color from the palette (cycling) -- so the two side menus are themselves
    /// part of the current color scheme rather than identical gray blocks.
    private func menuTile(_ item: WatchHomeMenu, tintIndex: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(menuTint(tintIndex))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.13)))
            Text(item.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel(item.title)
    }

    /// The "edit quick menu" entry. A dashed border and secondary color set it apart from the real menu items above --
    /// it isn't "the Nth menu", it's "where you edit the menus".
    private var editTile: some View {
        NavigationLink {
            WatchQuickMenuSettingsView()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                Text(L10n.Watch.quickMenuAdd)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(0.18),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Watch.quickMenuAdd)
    }

    /// Icon color for the `index`-th menu item. Cycles through the palette without going out of bounds.
    private func menuTint(_ index: Int) -> Color {
        let cs = styleStore.style.palette.colors
        guard !cs.isEmpty else { return Color(white: 0.75) }
        return cs[index % cs.count]
    }

    // MARK: - The pending hint bar

    /// The thin hint at the very bottom of the screen. **Only appears when something is pending**, about one line of text tall.
    ///
    /// Why not spread it back into a column: the center of the home screen is the Bot now, and spreading it out would shove it up.
    /// Details are on a separate page (`WatchQueueView`), so the two don't conflict.
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
struct WatchQueueView: View {
    @EnvironmentObject private var model: WatchRecorderModel
    @EnvironmentObject private var link: WatchLink

    var body: some View {
        Group {
            if model.pending.isEmpty {
                // ★ 2026-10-16 revision seven: this page can now be **reached straight from the menu** (it became one
                // of the addable menu items), so "empty" is the normal case and it needs an empty state --
                // otherwise tapping in from the menu just shows a black screen.
                VStack(spacing: 5) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text(L10n.Watch.queueEmpty)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
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
