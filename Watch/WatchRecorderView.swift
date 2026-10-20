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
/// ─────────────────────────────────────────────────────────────────────────
/// ★★ 2026-10-16 revision eight (user feedback on real hardware):
///
/// > `needs work, the blinking is too fast right now, slow the rhythm down, no green, just make the frame two eyes,
/// >  the current interaction needs work, swiping left and right doesn't reach the menus`
///
/// All four were changed:
///
/// * **Horizontal swiping never reaches the menus** -- revision seven used `TabView` + `.tabViewStyle(.page)` for horizontal paging,
///   which was a judgement made from the docs, and **the real hardware overturned it**: on watchOS the `.page` style exists but
///   doesn't give horizontal paging (`VerticalPageTabViewStyle` was only split out as its own
///   style in watchOS 10, which is exactly the hint that **vertical is the default on the watch**). Now it's our own horizontal paging (see
///   `pageDrag`): the three pages sit in one `HStack`, translated by the finger's displacement, and only flip once it crosses the threshold.
///   The upside is that direction, threshold and damping are all in our hands, with no more guessing at how the system interprets that style.
/// * **Nobody knew "you can swipe here"** -- a row of three little dots was added (`pageDots`). A big part of why users
///   couldn't find the menus is that nothing on screen ever hinted that you could swipe here.
/// * **Blinking too fast / slow the rhythm down** -- the `BlinkPhase` cycle stretches from 4.63 seconds to about 8.12 seconds,
///   and breathing from 2.6 seconds to 3.6 seconds (the accounting is written up in those two places).
/// * **No green / just make the frame two eyes** -- the Bot's rounded-square plate is deleted outright, leaving only the two
///   eyes; and this face **no longer takes any color from the palette**, it's all white (reasons at the top of `WatchBotFace`).
///
/// ─────────────────────────────────────────────────────────────────────────
/// ★★ 2026-10-16 revision nine (user feedback on real hardware):
///
/// > `inside the watch the eyes shouldn't keep blinking; when recording starts it should be a waveform just like heart rate,
/// >  not "never blink", you can go look at grok bot and their expression library,
/// >  and the color in the watch settings should be the color of the eye bot, drop the gradient`
///
/// * **The eyes shouldn't keep blinking** (but "**not never blink**") -- the `BlinkPhase` cycle stretches from
///   8.12 seconds out to about **19.12 seconds**. The structure is untouched (still "one rapid double-blink between two rests"),
///   only the two rest periods are stretched proportionally -- we want "a calm occasional blink", not "a dead-fish stare".
///   ⚠️ **Revision ten overturns this**, see below.
/// * **While recording swap in a waveform** (`WatchVoiceWave`): the peak height follows the microphone's **real level**
///   (`isMeteringEnabled`, only turned on in `WatchRecorderModel` this round; the sample rate
///   goes 1Hz → **12.5Hz**), and while quiet a "boom-tick" base keeps up a heartbeat-like rhythm.
///   The recording state is no longer "a variant of the eyes" but another form altogether -- which is exactly following Grok's
///   "don't give the state its own indicator light; let the character's motion express it all".
/// * **Color comes back to the eyes** -- but only **a single solid color** (`WatchRingStyle.tint`).
///   Revision eight's wholesale removal of color removed the plate and the gradient, not color itself.
/// * **Drop the gradient** -- the `gradient` dimension in `WatchRingStyle` is deleted entirely; the appearance page loses a row;
///   the swatches become solid-color dots; and the menu icons go from "cycling through the palette" to the same color
///   (cycling gave the three-color palette's 2nd entry a neon green -- one of the sources of last round's "green" complaint).
///
/// ─────────────────────────────────────────────────────────────────────────
/// ★★ 2026-10-16 revision ten (user feedback on real hardware):
///
/// > `those eyes of his aren't blinking all the time, they don't need to keep blinking,
/// >  https://github.com/sam70361/aora-bot go look at the expression handling in this repo,
/// >  just the eyes, the two eyes shouldn't keep blinking, inside the watch`
///
/// **This one kills the whole approach of revisions eight and nine.** Those two did the same thing:
/// stretching the "fixed blink cycle" longer and longer (4.63s → 8.12s → 19.12s). Stretching it to 19 seconds and still being told
/// "they don't need to keep blinking" means **the root cause isn't the frequency**.
///
/// After reading that repo (`mood-mates/` and `emotion-ball/`, two engines from the same source, pure SVG + vanilla JS)
/// and its idle state, the problem turned into four points: a fixed cycle = a metronome, a rapid double-blink every round, blinking is the only thing moving,
/// and one open-close takes too long (450ms). All four were fixed, with the accounting written up at the top of `WatchBotFace`
/// in the "revision ten" passage and in "the rhythm of blinking" at the end of the file.
///
/// In one line: **promote "gaze drift" to the main idle motion and demote blinking to an occasional garnish** --
/// once the eyes are never still, "blinking" is no longer the thing the user notices.
/// It also turned up something counterintuitive: the total blink rate on both sides is about the same (roughly one per 9 seconds),
/// so what needs changing isn't the speed, it's the **regularity** and the **make-up of the motion**.
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
    /// The home screen's resident expression. **Decided by the iPhone's settings** and pushed over via `WatchLink`
    /// (★ revision thirteen). The reason for `@ObservedObject`, same as `styleStore` above:
    /// after the phone pushes a new value, this page has to switch along with it immediately, and `WatchBotFace` is a
    /// plain `View`, so SwiftUI won't know on its own to redraw.
    @ObservedObject private var faceStore = WatchFaceStore.shared
    /// ⚠️ It has to be `@State`, not `let`: this `View` struct is re-constructed on every redraw,
    /// and a `let` would create a fresh detector every time (the sampler gets swapped out the moment it starts, so it never takes effect).
    /// `@State` keeps it in SwiftUI's storage and initializes it only once.
    @State private var shake = WatchShakeDetector()

    /// Current page of the horizontal paging: 0 = left menu page, 1 = Bot, 2 = right menu page.
    ///
    /// Defaults to **1** (Bot) -- the first thing you see when you raise your wrist has to be the page that "starts recording right away",
    /// not a menu page.
    @State private var page: Int = 1

    /// The displacement (pt) the finger is currently dragging. Returns to 0 during the page-flip animation.
    ///
    /// ★ Added in revision eight, the key state for **implementing horizontal paging ourselves**: the three pages are laid side by side and the whole thing is
    /// translated by `-page × screen width + dragX`. `dragX` makes the content **follow the finger** while dragging --
    /// without it you only get "let go and it snaps over", which doesn't feel like a page turn, it feels like a switch.
    @State private var dragX: CGFloat = 0

    /// The finger has to travel this far before we accept that "this is a page turn".
    ///
    /// ⚠️ It must be **greater** than the jitter of a tap and **less** than `WatchBotFace.holdSlop` (34).
    /// The three are three points on one line:
    ///   < 24  → neither a page turn nor a cancelled hold, pure jitter, ignored;
    ///   24~34 → no longer counts as "holding still", judged a paging intent;
    ///   > 34  → the hold is void.
    /// The 10pt in between is a **buffer zone**: a twitch of the hand and you're choosing between "start recording" and "turn the page",
    /// which is the most common way this kind of interaction falls apart.
    private static let pageDragSlop: CGFloat = 24

    /// Travel this far and letting go actually turns the page.
    ///
    /// ⚠️ Much larger than `pageDragSlop` (24 → 44): after recognizing "they're swiping" you still have to see whether they
    /// **swiped far enough**. If the two thresholds were one, a slight brush would turn the page and the user would keep overshooting.
    private static let pageFlipDistance: CGFloat = 44

    /// Number of times it's tapped while idle, handed to `WatchBotFace` for a single bounce.
    @State private var pokeTick = 0
    /// Number of times shake fired, handed to `WatchBotFace` to make the eyes **spin in circles**.
    ///
    /// ★ Added in revision fourteen (user: "shaking makes the eyes spin in circles with a dizzy feel").
    /// The reason for using a count as the trigger is the same as `pokeTick`.
    @State private var dizzyTick = 0
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
    /// Status text (timer/hint). 0.76 is 119pt on the 40mm, 136pt including the ring,
    /// and with a line of text it still fits in a 162×194 screen.
    ///
    /// ⚠️ Revision eight raised it from 0.70 to 0.76: once the plate was deleted, the 0.70 box held only the two eyes,
    ///    and at the original fraction the whole face looked small and empty. One size up exactly makes up the bulk lost with the plate.
    private static let botFraction: CGFloat = 0.76

    var body: some View {
        // ★ Revision eight: **no more `TabView`**, we lay out a horizontal row ourselves. Reasons in the "revision eight" passage at the top of the file
        //    -- on watchOS, `.tabViewStyle(.page)` doesn't give horizontal paging.
        //
        // The structure is plain: each of the three pages fills one screen width, the whole row is translated by `page`, and `dragX`
        // makes it follow the finger while dragging.
        GeometryReader { geo in
            HStack(spacing: 0) {
                menuPane(menuPrefs.leadingItems)
                    .frame(width: geo.size.width)
                botPane
                    .frame(width: geo.size.width)
                menuPane(menuPrefs.trailingItems)
                    .frame(width: geo.size.width)
            }
            .frame(width: geo.size.width * 3, alignment: .leading)
            .offset(x: -CGFloat(page) * geo.size.width + dragX)
        }
        // Three pages side by side, but only one should be visible -- without clipping, the left and right pages spill over the current one.
        .clipped()
        // `simultaneousGesture`, not `.gesture`: the paging gesture has to **coexist** with the subviews'
        // own gestures. `.gesture` would override the Bot `Button`'s hold/tap --
        // which is exactly this page's most important interaction.
        .simultaneousGesture(pageDrag)
        .overlay(alignment: .bottom) { bottomBar }
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
        .onAppear {
            syncShakeDetector()
            // ★ Revision fifteen: there used to be a `model.prepareHeartRate()` here (added in revision eleven,
            //   requesting heart-rate access when the home screen appears). From this round on, nothing calls the heart-rate chain any more,
            //   so this line goes with it -- otherwise the user sees a permission page asking "why does this recording app want
            //   to read my heart rate", and all it buys is a number nobody uses.
            //   The full reasoning is at the top of `WatchHeartRate.swift`.
        }
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
                // ★ Revision thirteen: which expression to wear while idle is decided by the iPhone's settings.
                style: faceStore.style,
                // ★ 2026-10-20: the eye colour now comes from the iPhone when the user picked
                // one there (`faceStore.colorHex`); only when they haven't (`nil`) does the
                // watch fall back to its own "Appearance" palette.
                tint: faceStore.colorHex.map { Color(botHex: $0) } ?? styleStore.style.tint,
                meter: model.meter,
                // ★ Revision eleven: while recording the timer shows right by the wave (user: "with the recording time attached below").
                // ★ Revision fifteen: the `bpm:` parameter is **deleted** -- the waveform is no longer driven by heart rate,
                //   reasons in the "revision fifteen" passage at the top of `WatchVoiceWave`.
                elapsedText: model.isRecording
                    ? WatchFormat.compactDuration(model.elapsed)
                    : nil,
                pokeTick: pokeTick,
                dizzyTick: dizzyTick,
                handGestureEnabled: prefs.pinchToRecord,
                // ★ 2026-10-20: blink pace / auto-cycling expressions / square frame — all set on the iPhone.
                blinkSpeed: faceStore.blinkSpeed,
                autoCycle: faceStore.autoCycle,
                frameVisible: faceStore.frameVisible,
                onTap: handleTap,
                onHold: beginRecordingByHold,
                onToggle: handleToggle
            )
            // ⚠️ Revision nine wired color back in, but **only a single solid color**: `tint` is the color picked on the "appearance"
            //    page (user: "the color in the watch settings should be the color of the eye bot,
            //    drop the gradient"). Revision eight removed it wholesale at one point -- what it removed was **the plate and the gradient**,
            //    not color itself; don't pass the whole `style` struct in again, that would turn
            //    "does this face use the breathing light" into a question you have to re-confirm every time.

            caption

            // Leave room for the bottom row of page dots + the pending hint so the two don't overlap.
            Spacer(minLength: 0).frame(height: 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The small line below the face. While idle it's a usage hint; while recording it's the **byte count written so far**.
    ///
    /// ⚠️ While idle that hint **cannot be dropped**. "Hold for 2 seconds" is an **invisible** interaction --
    /// without the hint, a first-time user just pokes once, finds nothing happens, and gives up.
    ///
    /// ★ Revision eleven: **the recording timer moves below the wave** (see `WatchBotFace.elapsedText`),
    /// So this no longer shows the time; at that point it was switched to the live heart rate.
    ///
    /// ★★ Revision fifteen: this line **drops back from "heart rate + byte count" to just the byte count**.
    /// Once heart rate no longer drives the waveform (see "revision fifteen" at the top of `WatchVoiceWave`), the only
    /// reason it sat here disappears -- it was shown so the user could confirm "the heart rate really is working"
    /// (the user can't see the difference between 72 and 75). And the pile of trouble it caused is real:
    ///   · When no heart rate is read you have to write "watch not worn", but the most common reason for no reading is actually
    ///     **no health permission granted**, so that line hangs permanently over a failure that isn't there;
    ///   · At rest HealthKit only records a sample every ten-odd minutes, so the number is stale most of the time.
    /// ⚠️ The byte count stays: it's the **only** hard evidence that "the recording is really being written to disk" --
    ///   after revision fifteen that waveform is a flat line hugging the bottom when things are quiet, and from it alone you can't tell "no sound" from "broken".
    @ViewBuilder
    private var caption: some View {
        if model.isRecording {
            Text(WatchFormat.bytes(model.currentBytes))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(styleStore.style.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monospacedDigit()
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
    ///
    /// ★ After revision twelve, what a "poke" does has changed: `pokeTick` now makes that face **play a random
    /// expression** (one drawn from five), no longer the single whole-face bounce and "one kind of eye wobble" of revision ten.
    /// This layer doesn't need to know which expressions exist -- it just fires the pulse off (see the `pokeTick`
    /// passage in `WatchBotFace`, which explains why it doesn't just call a method).
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
                ForEach(items) { item in
                    NavigationLink {
                        item.destination
                    } label: {
                        menuTile(item)
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

    /// A menu item.
    ///
    /// ★ Revision nine: the icon color goes from "cycling through the palette" to **all using the same color**
    /// (`WatchRingStyle.tint`). The reason is that this round fixed "one theme = one color" solid
    /// (see the top of `WatchRingStyle`) -- with cycling, the three-color palette (`activity`) would give
    /// the 2nd menu item that neon green, so under one theme the face is one color while
    /// the menu is another. That's one of the sources of last round's "green" complaint.
    private func menuTile(_ item: WatchHomeMenu) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(styleStore.style.tint)
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

    // MARK: - Horizontal paging

    /// The paging gesture. **Implemented ourselves, not via `TabView`** -- reasons in the "revision eight" passage at the top of the file.
    ///
    /// Three things are decided here:
    /// * Whether to accept it (`pageDragSlop`) -- under 24pt counts as jitter and is ignored;
    /// * Whether to flip (`pageFlipDistance`) -- only a full 44pt actually changes page;
    /// * Direction -- only **clearly horizontal** swipes count (`abs(dx) > abs(dy)`). A vertical swipe is
    ///   the user brushing the Digital Crown or flipping the system layer; swallowing it here would be baffling.
    private var pageDrag: some Gesture {
        DragGesture(minimumDistance: Self.pageDragSlop)
            .onChanged { value in
                // ⚠️ Animations **must be off** while dragging: this follows the finger frame by frame, and adding animation
                //    turns it into "a rubber band a beat behind". Only the short settle on release needs animation.
                var tx = Transaction()
                tx.disablesAnimations = true

                let raw = value.translation.width
                // Already at the start/end and still swiping outward → damp to 1/4. It gives a bit of "you've pulled to the end" feel,
                // otherwise the user thinks it's stuck and swipes harder.
                let pastStart = page == 0 && raw > 0
                let pastEnd = page == 2 && raw < 0
                let damped = (pastStart || pastEnd) ? raw * 0.25 : raw

                withTransaction(tx) { dragX = damped }
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height

                // ★ When the paging swipe is released, the `Button` also fires its action at the **moment the finger lifts**
                //   (that's defined `Button` behavior, not a bug). If we didn't block it,
                //   swiping the screen while idle would make the eyes bounce for no reason -- with nothing actually tapped.
                //   Reusing the same gate as the hold path; one fix for two traps.
                tapGateUntil = Date().addingTimeInterval(0.35)

                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    if abs(dx) > abs(dy), abs(dx) > Self.pageFlipDistance {
                        page = min(2, max(0, page + (dx < 0 ? 1 : -1)))
                    }
                    // Below threshold it settles back -- that "spring back" is itself the feedback that "you didn't swipe far enough".
                    dragX = 0
                }
            }
    }

    // MARK: - Bottom edge of the screen

    /// The little stack at the very bottom: page dots + pending hint.
    ///
    /// ⚠️ The two **must go in the same overlay** (not one overlay each): two
    ///    `alignment: .bottom` overlays **stack in the same place**, so the moment the pending bar appears
    ///    it covers the page dots.
    private var bottomBar: some View {
        VStack(spacing: 3) {
            pageDots
            queueBar
        }
        .padding(.bottom, 1)
    }

    /// Three little dots showing which page you're on.
    ///
    /// ★ Added in revision eight. The user reported "swiping left and right doesn't reach the menus"; half of that was broken behavior (`.page` not giving horizontal
    /// paging, now fixed) and the other half was **discoverability**: nothing on screen ever hinted that you could swipe here.
    /// Three dots are the least space and the least explanation.
    ///
    /// ⚠️ Deliberately **not tappable**: a 4pt dot is nearly impossible to hit on a 40mm watch, and making it a button would only
    ///    bring "I tapped and nothing happened". Its job is "tell you that you can swipe", not "swipe for you".
    private var pageDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index == page ? 0.85 : 0.25))
                    .frame(width: 4, height: 4)
            }
        }
        .allowsHitTesting(false)
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
                .foregroundStyle(styleStore.style.tint)
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
            // ★ Revision fourteen: the eyes **spin in circles** (user: "shaking makes the eyes spin in circles with a dizzy feel
            //   to add more interaction"). A haptic for the wrist and the dizzy for the eyes; together the two channels say "received".
            dizzyTick += 1
            // ⚠️ The actual start/stop is **pushed back 0.45 seconds**: without that, the recording state immediately swaps in the waveform
            //    the moment the eyes start spinning and the "dizzy" is never seen.
            //    0.45 seconds falls in the **first half** of the two spins (0.9 seconds total): when recording starts you see
            //    the eyes dizzy through half a turn, then the color floods in; when recording stops the wave exits and the eyes come back
            //    with the second half of the dizzy. Both directions get their moment.
            //
            //    The delay is **added on the perception side**, but shake already has about a 0.9-second detection window
            //    (`WatchShakeDetector.burstWindow`), and the user's expectation for a "shake" was never
            //    instant anyway. Any longer and it's no good -- that reads as "I shook it and nothing happened".
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                model.toggleRecording()
            }
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
