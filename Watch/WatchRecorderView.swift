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
///   goes 1Hz → **12.5Hz**), and while quiet it runs flat along the bottom.
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

    // ★ 2026-10-23 (功耗优化): the two signals that say "nobody is looking".
    // `isLuminanceReduced` — watchOS dimmed the display (wrist down, always-on
    // state); `scenePhase` — the app left the foreground. Either one lets the
    // model stop the 12.5 Hz meter (see `WatchRecorderModel.setUIDormant`);
    // the recording itself is untouched.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.scenePhase) private var scenePhase

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

    /// ★ 2026-10-20: the "end this take?" confirmation (double-tap / shake while
    /// recording). Both gestures are misfire-prone, so neither stops outright any more;
    /// the deliberate hold-to-stop needs no confirmation by construction.
    @State private var showStopConfirm = false
    /// ★ 2026-10-22: the confirmation **auto-closes after 2 s** and the take keeps
    /// rolling — user: "这个地方在 2s 后自动结束…默认不动则继续". A prompt that waits
    /// forever on a watch either gets answered by accident or leaves the user
    /// staring at a modal while the recording they wanted keeps running.
    @State private var stopConfirmTask: Task<Void, Never>?

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
        // ★★ 2026-10-23 (user: "手表底部三个小点…放在其他地方，不然的话就把它充当成
        // 嘴巴去了" + "长按那个圆圈底部都是被遮挡的"):
        //
        // The bottom edge used to carry the page dots **and** the pending pill,
        // stacked in one overlay. On the Bot page that edge is exactly where the
        // hold ring's 6-o'clock arc runs — so the ring got cut off by the pill,
        // and the three dots under a round face + two red eyes read as a **mouth**
        // (the screenshots the user sent are literally that face).
        //
        // Both moved to the top edge, which the Bot page leaves empty: the pill
        // top-leading, the page indicator top-trailing as a **three-segment bar**
        // rather than dots — a bar can't be mistaken for a mouth, and it sits at
        // the same height as the pill so the two never fight the ring.
        .overlay(alignment: .top) { topBar }
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
        // ★ 2026-10-30（用户："录音断联需要状态弹出提醒告知，点击或者在附近就重连"）：
        // 录音期间与手机断联（掉线持续 20 s 才弹，锁屏/切走的瞬时断开不算）。
        // 「重连」立即补推状态+补发队列；「继续」关掉弹窗、录音照跑——
        // 手机回到附近时模型会自动重连并撤掉提醒。
        .alert(
            L10n.Watch.linkLostTitle,
            isPresented: Binding(
                get: { model.linkLost },
                set: { if !$0 { model.dismissLinkLost() } }
            )
        ) {
            Button(L10n.Watch.linkLostRetry) { model.reconnectNow() }
            Button(L10n.Common.ok, role: .cancel) { model.dismissLinkLost() }
        } message: {
            Text(L10n.Watch.linkLostMessage)
        }
        .onAppear {
            syncShakeDetector()
        }
        // Stop sampling when leaving this page: keeping the accelerometer on is a big line on the battery bill,
        // and this page only comes to the foreground when you raise your wrist.
        .onDisappear { shake.stop() }
        .onChange(of: prefs.shakeToRecord) { _, _ in syncShakeDetector() }
        // ★ 2026-10-23 (功耗优化): dimmed or backgrounded → pause UI work.
        // One shared funnel (`syncDormancy`) rather than two raw calls, so a
        // "dimmed cleared while backgrounded" overlap can't send conflicting
        // values — the last state computed from both signals is always right.
        .onChange(of: isLuminanceReduced) { _, _ in syncDormancy() }
        .onChange(of: scenePhase) { _, _ in syncDormancy() }
    }

    /// Dormant = dimmed **or** not in the foreground. Both must say "awake"
    /// before the meter runs again.
    private func syncDormancy() {
        model.setUIDormant(isLuminanceReduced || scenePhase != .active)
    }

    // MARK: - The Bot home screen

    /// That Bot face. Hold to start, tap to stop, double tap to start/stop -- **all three live on it**
    /// (see the passage at the top of `WatchBotFace`); this is only responsible for catching its two callbacks.
    private var botPane: some View {
        VStack(spacing: 5) {
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

            // ★ 2026-10-23: only the top bar needs clearance now — the page
            // indicator and the pending pill moved up out of the ring's way.
            Spacer(minLength: 0).frame(height: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // ★ 2026-10-20: double-tap / shake while recording land here instead of
        // stopping outright. "End" takes the destructive role; "Keep recording" is
        // the default the user most often wants after a misfire.
        .alert(L10n.Watch.stopConfirmTitle, isPresented: $showStopConfirm) {
            Button(L10n.Watch.stopConfirmAction, role: .destructive) {
                // The 2-second timer must not fire *after* the answer was given.
                stopConfirmTask?.cancel()
                tapGateUntil = Date().addingTimeInterval(0.5)
                model.stop()
            }
            Button(L10n.Watch.continueAction, role: .cancel) {
                stopConfirmTask?.cancel()
            }
        } message: {
            Text(L10n.Watch.stopConfirmMessage)
        }
    }

    /// The small line below the face. While idle it's a usage hint; while recording it's the **byte count written so far**.
    ///
    /// ⚠️ While idle that hint **cannot be dropped**. "Hold for 2 seconds" is an **invisible** interaction --
    /// without the hint, a first-time user just pokes once, finds nothing happens, and gives up.
    /// ★ The recording timer sits right below the wave (see `WatchBotFace.elapsedText`), so this line no longer shows time.
    /// ⚠️ The byte count is the **only** hard evidence that "the recording is really being written to disk" --
    ///   the wave is a flat line hugging the bottom when things are quiet, and from it alone you can't tell "no sound" from "broken".
    @ViewBuilder
    private var caption: some View {
        if model.isRecording {
            // ★ 2026-10-22: the "tap refused, long-press to stop" hint is gone —
            // a tap now asks "End / Keep recording" outright (see `askStopConfirm`),
            // so there is nothing left for a second, weaker hint to explain. That
            // line goes back to being the byte counter, which is the only hard
            // evidence that audio is reaching the file.
            //
            // ★ 2026-10-23 (user: "启动跟关闭都是更暂停"): the counter alone left
            // both presses looking the same — you hold 2 s to start and hold 2 s
            // to stop, and nothing on screen said which one this press was. The
            // action label now sits **directly under the counter**, small and
            // secondary, so it explains the gesture without competing with the
            // one number that proves the take is alive.
            VStack(spacing: 1) {
                Text(WatchFormat.bytes(model.currentBytes))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(styleStore.style.tint)
                    .monospacedDigit()
                Text(L10n.Watch.holdToStop)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
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

    /// ★ 2026-10-20: a hold while **recording** now ends the take (hold-to-stop).
    /// The ring the user sees filling is the same transition as starting — symmetric,
    /// and immune to misfires because a 2-second deliberate press is nothing like a
    /// cuff brush. Starting a recording still goes through `toggleRecording()`.
    private func beginRecordingByHold() {
        // The lift is read by the `Button` as a tap (see the `tapGateUntil` passage).
        tapGateUntil = Date().addingTimeInterval(0.5)
        if model.isRecording {
            model.stop()
        } else {
            model.toggleRecording()
        }
    }

    /// Tap. While idle = poke; **while recording = the "end / keep" prompt**.
    ///
    /// ★ 2026-10-20: a tap used to stop the take, which is exactly the misfire the user
    /// reported ("录音结束…防止误触中断") — a cuff brush reads as a tap.
    ///
    /// ★ 2026-10-22 (user: "如果是手势控制点击了后就弹出结束跟继续录音，…2s 后自动结束…
    /// 默认不动则继续"): the tap used to be **refused** with a hint line. It now opens the
    /// same two-button prompt the pinch and the shake use, and that prompt closes
    /// itself after two seconds with "keep recording" as the answer. Same prompt,
    /// same default, every gesture — a stray touch can no longer end a take, and it
    /// no longer needs a second, weaker explanation of what *would*.
    private func handleTap() {
        guard Date() >= tapGateUntil else { return }
        if model.isRecording {
            WKInterfaceDevice.current().play(.click)
            askStopConfirm()
        } else {
            pokeTick += 1
        }
    }

    /// Show "End this recording? / End · Keep recording" and **arm the 2-second
    /// auto-close**. Every recording-state gesture funnels through here so the three
    /// of them can never drift apart again.
    private func askStopConfirm() {
        stopConfirmTask?.cancel()
        showStopConfirm = true
        stopConfirmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            // Timeout = "keep recording", never "end". The user asked for the
            // default to be the safe one, and it also matches what the alert's
            // cancel button does.
            showStopConfirm = false
        }
    }

    /// Double tap. Start / stop-with-confirmation.
    ///
    /// Shares the same `Button` as the tap, and `WatchBotFace.handlePrimaryAction()` tells them apart by
    /// "whether this one came with a touch" (a double tap is an in-air gesture with no touch).
    ///
    /// ★ 2026-10-20: while recording the pinch **asks** instead of stopping outright
    /// (user: "双指捏合…需要弹出一个确定或者继续防止误触中断") — an in-air pinch is easy
    /// to fire while reaching for something else, and it used to end the take instantly.
    private func handleToggle() {
        guard Date() >= tapGateUntil else { return }
        if model.isRecording {
            askStopConfirm()
        } else {
            model.toggleRecording()
        }
    }

    // MARK: - The two side swipe menus

    /// One menu page. When `items` is empty it shows "add some in settings" rather than a blank page --
    /// a blank page looks broken.
    private func menuPane(_ items: [WatchHomeMenu]) -> some View {
        // ★ 2026-10-30（用户："手表滑动到侧边菜单栏不支持上下滑动选择需要优化，
        // 因为下面还有"）：原来是一个 `VStack` + 两个 `Spacer` 居中，条目多出
        // 屏幕高度后**直接被裁掉**，下面的条目根本够不着。现在包进竖向
        // `ScrollView`：条目少时靠上排（不再上下顶开），条目多时整页可以滚。
        //
        // ⚠️ 与横向翻页手势不冲突：`pageDrag` 只接受"明显横向"的滑动
        //    （`abs(dx) > abs(dy)`），竖向从来交给 ScrollView。内容超高时
        //    关掉 `pageDrag`（`canPage`），否则滚动的起手会被误判成翻页。
        // ★ 2026-10-30 第二轮（用户："在手表首页左滑后要支持往下往上滑动"）：
        //   第一轮只是把内容包进 `ScrollView`，但滚动**看起来仍然不动**，两个原因：
        //   ① `pageDrag` 每帧都写 `dragX = translation.width`，竖滑时手指那点横向
        //      抖动会把整页左右蹭走（`.clipped()` 一裁，用户看到的就是"卡住/被挡住"），
        //      松手再弹回去，永远不会出现滚动的位移感 —— 现在 onChanged 里先判方向，
        //      竖向一律 `dragX = 0`，横向位移完全交给 ScrollView；
        //   ② 内容贴边：第一块砖被顶部页码条压住、最后一块被底边裁掉，看起来"下面还有
        //      但够不着"。现在上下各留出避让空间（顶部 12pt 让页码条，底部 8pt 兜底）。
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 7) {
                if items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text(L10n.Watch.quickMenuEmpty)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 10)
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
            }
            .padding(.horizontal, 5)
            .padding(.top, 13)
            .padding(.bottom, 8)
        }
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
        // ★ 2026-10-30（用户："这个菜单选择需要大一点，不要太小了"）：整块从
        //   "38pt 高、14pt 字"放大到 **约 50pt 高、16pt 字**，图标底盘 28 → 32。
        //   40mm 表盘上一行 50pt 正好是"一屏三块半"，既点得准又不至于一屏只放得下两块。
        //   这也是"方框"优化的正题：原来方框偏矮、文字贴边，底部一行压着屏幕边缘，
        //   现在方框有固定的最小高度、内边距左右一致、圆角跟着高度走，视觉上不再被裁。
        HStack(spacing: 9) {
            Image(systemName: item.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(styleStore.style.tint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.14)))
            Text(item.title)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityLabel(item.title)
    }

    /// The "edit quick menu" entry. A dashed border and secondary color set it apart from the real menu items above --
    /// it isn't "the Nth menu", it's "where you edit the menus".
    private var editTile: some View {
        NavigationLink {
            WatchQuickMenuSettingsView()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 32)
                Text(L10n.Watch.quickMenuAdd)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(0.18),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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
                // ★ 2026-10-30（用户："左滑后要支持往下往上滑动"）：**先判方向再动手**。
                //   竖向滑动一律不参与翻页——手指竖着划的时候横向分量总有十几点抖，
                //   以前直接写进 `dragX`，整页被左右蹭走再弹回，用户的体感就是"滑不动"。
                //   这里把竖滑干净地让给 `ScrollView`，只在明显横向时才驱动位移。
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    if dragX != 0 { withTransaction(tx) { dragX = 0 } }
                    return
                }
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

    // MARK: - Top edge of the screen

    /// The little stack at the very top: pending pill on the left, page
    /// indicator on the right.
    ///
    /// ⚠️ One overlay, one `HStack` — two separate `.overlay(alignment: .top)`
    ///    modifiers would stack on the same spot, which is the mistake the old
    ///    bottom bar documented and then this rewrite removed along with it.
    private var topBar: some View {
        HStack(alignment: .top, spacing: 0) {
            queueBar
            Spacer(minLength: 0)
            pageBar
        }
        .padding(.horizontal, 4)
        .padding(.top, 1)
    }

    /// Three little **segments** showing which page you're on.
    ///
    /// ★ Rewritten 2026-10-23 from dots to a bar, for the reason in `body`:
    /// three round dots under a face read as a mouth. Three short capsules in a
    /// row read as a page control — the shape itself is the explanation.
    ///
    /// ★ Added in revision eight as dots. The user reported "swiping left and
    /// right doesn't reach the menus"; half of that was broken behavior
    /// (`.page` not giving horizontal paging, now fixed) and the other half was
    /// **discoverability**: nothing on screen ever hinted that you could swipe here.
    ///
    /// ⚠️ Deliberately **not tappable**: a 4pt-tall bar is impossible to hit on a
    ///    40mm watch, and making it a button would only bring "I tapped and
    ///    nothing happened". Its job is "tell you that you can swipe".
    private var pageBar: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index == page ? 0.85 : 0.22))
                    .frame(width: index == page ? 12 : 6, height: 3)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: page)
        .allowsHitTesting(false)
    }

    // MARK: - The pending hint

    /// The compact pending pill. **Only appears when something is pending.**
    ///
    /// ★ Moved 2026-10-23 from the bottom edge to the top-leading corner: on the
    /// Bot page the bottom edge is the hold ring's arc, and the pill was literally
    /// covering it ("长按那个圆圈底部都是被遮挡的"). Details stay on their own page
    /// (`WatchQueueView`), so the pill is just an icon + count + chevron.
    @ViewBuilder
    private var queueBar: some View {
        if !model.pending.isEmpty {
            NavigationLink {
                WatchQueueView()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.circle.fill")
                    Text(L10n.Watch.pendingCount(model.pending.count))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(styleStore.style.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
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
            // ★ 2026-10-20: while **recording** the shake asks before acting (user:
            // "摇一摇也是需要弹出是否确认取消") — a shake is the easiest gesture to
            // produce by accident while moving, and it used to end the take outright.
            // (The detector fires on the main queue, so the @State write is safe.)
            guard !model.isRecording else {
                // ★ 2026-10-22: same prompt as tap / pinch, and it closes itself
                // after 2 s with "keep recording" — see `askStopConfirm`.
                askStopConfirm()
                return
            }
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

    /// Day + time for the Recap rows (★ 2026-10-23): "10/23 14:30" shape.
    /// Recap entries live for 7 days, so the date is as relevant as the time —
    /// a bare `HH:mm` leaves "which morning was this?" unanswered. Cached
    /// formatter: `DateFormatter` init is expensive enough that a watch app
    /// shouldn't pay it per row per render.
    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "MMdd HH:mm", options: 0, locale: .current
        )
        return formatter
    }()

    static func dayTime(_ date: Date) -> String {
        dayTimeFormatter.string(from: date)
    }
}
