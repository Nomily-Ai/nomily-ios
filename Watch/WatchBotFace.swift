import SwiftUI

// MARK: - The "face" at the center of the home screen
//
// ★ 2026-10-16 revision seven (user's words: "make it like Grok Bot, two eyes, then look at how they
// do the natural-blinking animations... Remove the record button from the home screen and make it alive like the bot; start by holding
// its eyes for 2s to record, or use the previous gestures and shake to start and stop recording"):
//
// The center of the home screen used to be a ring button; one tap started recording. The problem with "one tap starts recording" on
// the wrist is that it misfires far too easily -- raising the wrist to check the time, or a brush from a cuff, would start a recording. Now it is a human-like
// The little robot: **hold it for 2 seconds** to start, and a tap while recording stops.
//
// ─────────────────────────────────────────────────────────────────────────
// ## How this face is put together (the conclusion after three revisions)
//
// ★ Revision eight: removed the **rounded-square plate**. The user's exact words were "no green, just make the frame two eyes"
// -- with that plate it was a colored square framing the eyes, more like an app icon than a face.
// Grok backs this up too: their robot is **two white bars on a black background**, and the basic structure is
// "simple geometric shapes + a pair of expressive eyes" (their own words in the official design write-up), with no face frame.
//
// ★ Revision nine: **color comes back to the eyes, but only halfway** -- the value still comes from the palette chosen on the "Appearance" page,
// but only as a **solid color** (`palette.solid`), no more gradient (user: "the color set in the watch
// should be the color of the eye bot, drop the gradient"). So this now takes a `tint: Color`,
// not a whole `WatchRingStyle`: this face needs only a color, and handing it a whole style struct
// would turn "will it actually use the gradient / breathing light" into a question to re-confirm every time.
//
// ─────────────────────────────────────────────────────────────────────────
// ## Blinking is the whole point of this face
// A motionless eye is no different from a dot. What makes it "alive" is these few things:
//
//   · **Occasionally blink once** -- close fast, pause for a beat, open a little more slowly, then **rest for a long time**.
//     Human blinks are never a constant-rate open and close; a constant rate immediately reads as mechanical (for the phase-by-phase description see the
//     end of the file, `BlinkPhase`). Each cycle also packs in one "double blink," the most common rhythm in real people.
//     ⚠️ Revision nine slowed the rhythm **down again by more than double**: after seeing revision eight on real hardware the user said
//        "the eyes should not keep blinking," but immediately added "**not no blinking**" --
//        what they want is "blink calmly once in a while," not "dead-fish eyes." The new cycle is about **19.1 seconds**
//        (revision seven 4.63s → revision eight 8.12s → revision nine 19.12s; the ledger is in `BlinkPhase`).
//   · **Breathing** -- the whole pair of eyes slowly inflates and deflates (plus or minus 1.8%, once every 3.6 seconds). The amplitude must be small:
//     any larger and it looks like it is pulsing; it should be small enough that "you can't say what is moving, but it is alive."
//   · **Swap in a waveform while recording** (`WatchVoiceWave`) -- user: "when recording starts it should be
//     a waveform just like heart rate." So the recording state is **not a variant of the eyes**, it is another form:
//     the peak height is the microphone's real level, and when quiet a "thump-tick" base shape keeps a heartbeat-like rhythm.
//   · **The charge ring while holding** -- while the finger stays down, a 2-second progress arc runs around the outside of the eyes. Without it,
//     the user does not know how long to press, nor whether that press was even picked up.
//
// ## Why all the gestures live in this one type instead of being scattered across the home screen
// Hold to start, tap to stop, Double Tap to start/stop -- all three **land on this face**.
// Splitting it into "the home screen owns the hold, the face owns the animations" would make "how should the face react while pressed" span two
// files; and Double Tap requires the landing point to be a real `Button` (`handGestureShortcut`
// only works on button-like controls), so here the eyes are simply wrapped in a `Button`,
// with the hold attached to that same `Button` -- so the three things have just one source of truth.
//
// ⚠️ **Under always-on (`isLuminanceReduced`) everything must stop**: on a dimmed watch face
// animations are both hard to see and power-hungry, and "looping animations" happen to be the hungriest kind. When stopped, show a **static
// open-eyed face** -- not hide it; the watch face still has to show what this is.
//
// ⚠️ Revision eight removed the plate, so **the tap target has to be added back by hand** (`.contentShape`, see `body`).
//    Without that, the hit area shrinks to the two capsules -- pairing a "hold for 2 seconds" interaction with a small
//    hit area makes the user conclude "I pressed it but nothing happened."
struct WatchBotFace: View {
    /// The face's **nominal** side length (excluding the charge ring outside).
    ///
    /// ⚠️ After revision eight it is no longer the "plate side length" (the plate is gone), but the **bounding-size
    /// reference** for the eyes/waveform -- all proportions are still taken from it, so changing watches needs no recalculation.
    let size: CGFloat
    let isRecording: Bool
    /// The color of the eyes (and of the waveform while recording).
    ///
    /// The source is the **solid color** from the palette chosen on the "Appearance" page (`WatchRingStyle.palette.solid`).
    /// ⚠️ Pass only a color, not a whole `WatchRingStyle`: see the "revision nine" paragraph at the top of the file.
    let tint: Color
    /// The live level while recording, forwarded to `WatchVoiceWave`.
    ///
    /// ⚠️ The idle state does not use it -- it is passed all the way to `WatchVoiceWave`, and that view only exists
    /// in the recording state, so level changes while idle do not drag this face into redrawing.
    let meter: WatchAudioMeter
    /// Number of times tapped while idle. The home screen adds 1, and this does one "bounce."
    ///
    /// ⚠️ Why not just expose a `poke()` method for the home screen to call: `WatchBotFace` is a value type,
    /// and the home screen constructs it inline in `body`, so it cannot get a reference to that instance. Using a monotonically increasing
    /// counter as the trigger is the standard SwiftUI way to "send a child view one pulse from outside."
    let pokeTick: Int
    /// Whether Double Tap can start/stop recording. Toggled in by `WatchRecordingPrefs.pinchToRecord`.
    let handGestureEnabled: Bool
    /// Tap (a finger actually touched the face). Recording = stop; idle = the home screen decides whether to just poke it.
    let onTap: () -> Void
    /// The hold reached 2 seconds.
    let onHold: () -> Void
    /// **Double Tap**. Start / stop.
    ///
    /// ⚠️ Why it must be separate from `onTap`: Double Tap (pinching index finger and thumb) and a finger tap both
    /// land on **the same** `Button` action -- the definition of `handGestureShortcut`
    /// is "bind Double Tap to this control's primary action" (see `PrimaryHandGesture`).
    /// That is, this layer does not get the fact of "which input this actually was" and has to infer it.
    /// For the inference, see `handlePrimaryAction()`.
    let onToggle: () -> Void

    /// Always-on dimming. See the paragraph at the top of the file.
    @Environment(\.isLuminanceReduced) private var dimmed

    /// For breathing. A single `false → true` flip + `repeatForever`; interpolation is left to the render server.
    @State private var breathe = false
    /// The bounce amount when poked. 0 = original state.
    @State private var poke: CGFloat = 0
    /// Hold progress 0...1.
    @State private var holdProgress: CGFloat = 0
    /// Whether a finger is currently pressed on the eyes. Driven by `LongPressGesture.updating`.
    @GestureState private var holding = false
    /// The most recent moment "a finger actually touched the face" (updated on both press and release).
    ///
    /// ★ This is the only basis for telling **a finger tap** from **Double Tap** -- see
    /// `handlePrimaryAction()`. Double Tap is an **in-air** gesture; the whole action produces no
    /// touch events, so "there was a touch just now" equals "this was a finger tap."
    @State private var lastTouchAt = Date.distantPast

    /// How long the hold must be before recording starts.
    ///
    /// 2 seconds is the number the user named. It also sits right between "not easy to misfire" and "doesn't feel like waiting":
    /// raising the wrist to check the watch usually ends within a second, nowhere near 2 seconds.
    static let holdSeconds: TimeInterval = 2.0
    /// Allowed finger slop (pt) during a hold. Beyond it, the gesture is judged to be "paging" rather than "holding."
    ///
    /// ⚠️ Revision eight raised it from 26 to **34**: the home screen now implements horizontal paging itself (see
    /// `WatchRecorderView.pageDrag`), and it requires a 24pt swipe to register. The two thresholds must stay **separate**
    /// -- the 24-to-34 band is the buffer where "neither paging nor cancelling the hold" applies.
    /// If the two numbers collided, one twitch of the hand would have to choose between "start recording" and "page."
    private static let holdSlop: CGFloat = 34

    // MARK: Proportions
    //
    // Everything is derived as a proportion of `size`, never hard-coded -- the watch screen width differs by 40pt from 40mm to 49mm,
    // so hard-coding any single number would be off on at least one size.
    //
    // ⚠️ Revision eight **enlarged the eyes** by one step (width 0.185 → 0.235, height 0.285 → 0.375).
    //    The old sizes were calculated to go with the plate: with a plate the eyes were just "a pattern on the board," so a bit smaller
    //    still held up. Once the plate is gone the eyes are the whole face, and at the old size they look small and empty.
    private var eyeWidth: CGFloat { size * 0.235 }
    private var eyeHeight: CGFloat { size * 0.375 }
    /// The gap **between** the two eyes (not the centre-to-centre distance).
    private var eyeGap: CGFloat { size * 0.235 }

    var body: some View {
        // Use a `Button` instead of a bare view: `handGestureShortcut` (Double Tap)
        // only works on button-like controls -- see the paragraph at the top of the file.
        //
        // ⚠️ This one action receives **both** kinds of input: a finger tap and a Double Tap.
        //    So it has to be split apart again by `handlePrimaryAction()` -- you cannot write one kind's
        //    behavior directly here.
        Button(action: handlePrimaryAction) {
            ZStack {
                holdRing
                figure
                    .scaleEffect(figureScale)
                    .animation(.spring(response: 0.34, dampingFraction: 0.62), value: isRecording)
            }
            // Leave room outside for the charge ring.
            .frame(width: size * 1.14, height: size * 1.14)
            // ★ Added in revision eight, **not optional**: with the plate gone, `Button` by default treats only the drawn
            //   shape as the hit area, i.e. those two capsules (or that wave while recording).
            //   A 2-second hold needs a steady press, and with the hit area shrunk like that the user feels
            //   "I clearly pressed it but nothing happened."
            //   Add a square hit area that makes the whole `frame` tappable.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The hold and the "tap" are recognized **simultaneously**: a tap requires a quick release, a hold requires staying pressed,
        // so the two never collide on the same sequence of motion anyway. Use `simultaneousGesture` rather than
        // `.gesture`, so the hold does not displace the `Button`'s own tap (which would make "tap to stop"
        // fail during hold recognition -- exactly when the user needs it most).
        .simultaneousGesture(holdGesture)
        // ★ Double Tap (pinching index finger and thumb) = start/stop recording.
        //
        // ⚠️ When the switch is off you must **explicitly** pass `isEnabled: false`, not "leave it alone" --
        //    on watchOS 11 the system still routes Double Tap to the main button, so it fires even with the switch off.
        //    On 10.1~10.x the system routes it itself; there is no API to turn it off (see `PrimaryHandGesture`).
        .modifier(PrimaryHandGesture(enabled: handGestureEnabled))
        .accessibilityLabel(isRecording ? L10n.Watch.stop : L10n.Watch.record)
        .accessibilityValue(isRecording ? L10n.Watch.recordingBusy : L10n.Watch.holdToRecord)
        .onAppear { startIdleMotion() }
        .onChange(of: pokeTick) { _, _ in pokeOnce() }
        .onChange(of: holding) { _, pressing in
            // ★ Record a timestamp on both press and release: the Button's action fires at the moment of **release**,
            //   so recording only the press would make "hold for a moment then let go" be misjudged
            //   as a Double Tap because of the large time gap (which would turn "pressed for 1 second and gave up" into
            //   "start recording").
            lastTouchAt = Date()

            // A hold while recording does not light up the progress ring -- otherwise the user thinks "two more seconds and it starts again."
            guard !isRecording else { return }
            if pressing {
                // The progress filling up is exactly 2 seconds, aligned with the gesture's minimumDuration.
                // If the two disagree you get either "recording starts before the ring completes" or
                // "the ring completes but recording never starts" -- both make the user stop trusting the ring.
                withAnimation(.linear(duration: Self.holdSeconds)) { holdProgress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.16)) { holdProgress = 0 }
            }
        }
        .onChange(of: isRecording) { _, recording in
            // While recording, park the breathing at the "flat" position: that waveform has its own rhythm (a heartbeat),
            // and stacking another slow inflate-deflate makes two cycles fight each other.
            //
            // ⚠️ Before revision nine there was also a `sway` here (the two eyes drifting out of phase). The recording state
            //    is now swapped entirely for a waveform, the eyes are simply absent, and that state was deleted along with it.
            if recording {
                withAnimation(.linear(duration: 0.25)) { breathe = false }
            } else {
                startIdleMotion()
            }
        }
        .onChange(of: dimmed) { _, reduced in
            if reduced {
                // Dimmed: stop everything at the rest position. See the paragraph at the top of the file.
                withAnimation(.linear(duration: 0.2)) { breathe = false }
            } else if !isRecording {
                startIdleMotion()
            }
        }
    }

    // MARK: - Gestures

    /// The `Button`'s action. **It receives two kinds of input at once, and splits them apart here.**
    ///
    /// * **A finger tap** -- there must have just been a press/release, and `lastTouchAt` is only milliseconds ago.
    ///   It goes to `onTap` (recording = stop; idle = poke).
    /// * **Double Tap** -- index finger and thumb pinch **in the air**, producing no touch events at all,
    ///   so `lastTouchAt` is stuck in the distant past. It goes to `onToggle` (start/stop).
    ///
    /// ## Why a time window rather than some other criterion
    /// No other criterion is available: at this SwiftUI layer the two inputs are the same closure, and the system gives no
    /// source information. "Was there a touch in the last 0.4 seconds" is the only reliable distinction --
    /// Double Tap is an in-air gesture, and that is a **physical fact**, not a heuristic guess.
    ///
    /// ⚠️ The threshold cannot be too small: a frame or two separates the finger lifting from the action firing. 0.4 seconds is ample
    ///    for both (the normal gap is < 50ms), and far smaller than the shortest gap of "the user pinches in the air and then taps the screen"
    ///    (a person cannot pinch and then tap within 0.4 seconds).
    private func handlePrimaryAction() {
        let touched = Date().timeIntervalSince(lastTouchAt) < 0.4
        if touched {
            onTap()
        } else {
            onToggle()
        }
    }

    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: Self.holdSeconds, maximumDistance: Self.holdSlop)
            .updating($holding) { current, state, _ in state = current }
            .onEnded { _ in
                // Collapse the ring first: the user is still pressing, the face is about to switch to the recording state,
                // and leaving a fully-completed arc around would clash with the recording-state glow.
                withAnimation(.linear(duration: 0.12)) { holdProgress = 0 }
                onHold()
            }
    }

    /// Idle-state breathing. It should not run while dimmed or while recording.
    ///
    /// ⚠️ Revision eight slowed one "inhale-exhale" from 2.6 seconds to **3.6 seconds** (user: "slow the rhythm down").
    ///    Breathing is this face's **most constant** motion -- far more frequent than blinking, so any faster reads as
    ///    "panting," and it stacks with blinking to make the whole picture look busy.
    private func startIdleMotion() {
        guard !dimmed, !isRecording else {
            withAnimation(.linear(duration: 0.2)) { breathe = false }
            return
        }
        withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
            breathe = true
        }
    }

    /// The product of three scale layers: breathing × poke × recording.
    ///
    /// Multiply rather than stack three `.scaleEffect`s -- with three stacked layers, changing any one means also changing
    /// the magnitude of the other two to match the look, and soon nobody can work out the total amplitude.
    ///
    /// ⚠️ Revision eight pulled the breathing amplitude in to plus or minus 1.8% (from plus or minus 3.5%). With the cycle slowed, the same amplitude
    ///    covers less distance per second but lingers longer, so it actually looks more "swollen"; adjusting both together
    ///    is what keeps it "slow and steady," while slowing only the cycle turns it into "slowly swelling."
    ///
    /// ⚠️ The recording state is 1 (no shrink, no grow). Revision seven's version grew another 1.06 while recording, which was for
    ///    "open the eyes one size larger"; after revision nine swapped the recording state for a waveform, that wave's height **is the level itself**,
    ///    and multiplying by another factor would make "the amplitude you see" and "the real volume" stop being the same thing.
    private var figureScale: CGFloat {
        var s: CGFloat = (dimmed || isRecording) ? 1 : (breathe ? 1.028 : 0.992)
        s *= 1 + poke * 0.05
        return s
    }

    /// Tapped while idle: bounce once. It does **not** start recording -- starting recording is a 2-second hold.
    ///
    /// Why this feedback: if a tap does nothing at all, the user assumes "maybe I have to hold it,"
    /// and starts trying random things; a bounce both says "I got it" and, because it is **clearly not** the recording look
    /// (recording swaps in a whole bouncing waveform) and will not be mistaken for having already started recording.
    private func pokeOnce() {
        guard !isRecording, !dimmed else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { poke = 1 }
        Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { poke = 0 }
        }
    }

    // MARK: - The face

    /// **Which form this face is currently in**.
    ///
    /// Only two branches, and they are mutually exclusive -- this is exactly Grok's approach of "one figure, several states,
    /// no separate indicator light for the state": idle is eyes, recording is a waveform.
    /// There is nowhere on the watch face to put another "recording" line; this switch is itself that line.
    @ViewBuilder
    private var figure: some View {
        if isRecording {
            WatchVoiceWave(meter: meter, size: size, tint: tint)
        } else {
            eyes
        }
    }

    /// The two eyes.
    ///
    /// ⚠️ Revision eight deleted the "out-of-phase drift while recording" scheme (back then the recording state was still a variant of the eyes).
    ///    Revision nine swapped the whole recording state for a waveform, the eyes are simply absent, and the `sway` state was deleted along with it
    ///    -- not forgotten.
    private var eyes: some View {
        HStack(spacing: eyeGap) {
            eye
            eye
        }
        // As a group the eyes sit a little above the geometric center. Exactly centered looks "head down" --
        // the eyes on a human face sit above the midline anyway.
        .offset(y: -size * 0.03)
    }

    /// One eye.
    ///
    /// Opening/closing is squashed from the center with `scaleEffect(y:)`, not by changing `frame(height:)` --
    /// changing the height makes the eye "grow from the bottom up," whereas a real eyelid comes down **from both sides at once**.
    @ViewBuilder
    private var eye: some View {
        if dimmed {
            // Dimmed: a static open-eyed face.
            eyeShape
        } else {
            eyeShape
                // Occasionally blink once. For the rhythm see `BlinkPhase` at the end of the file.
                .phaseAnimator(BlinkPhase.allCases) { view, phase in
                    view.scaleEffect(y: phase.openness, anchor: .center)
                } animation: { phase in
                    phase.animation
                }
        }
    }

    /// Uses the color chosen on the "Appearance" page, **solid** (revision nine dropped the gradient).
    private var eyeShape: some View {
        Capsule()
            .fill(tint)
            .frame(width: eyeWidth, height: eyeHeight)
    }

    // MARK: - The charge ring

    /// The 2-second progress arc during a hold. **It appears only while pressed** (`holdProgress > 0`),
    /// and vanishes the instant you let go -- it is one-time feedback, not permanent decoration.
    ///
    /// ⚠️ Revision eight briefly made it white (that was when the whole face was colorless). After revision nine brought color back to the eyes,
    ///    this ring follows `tint` too -- so the whole face has just one color,
    ///    rather than two systems, "colored eyes plus a white arc."
    @ViewBuilder
    private var holdRing: some View {
        if holdProgress > 0.002 {
            Circle()
                .trim(from: 0, to: holdProgress)
                .stroke(
                    tint.opacity(0.9),
                    style: StrokeStyle(lineWidth: max(3, size * 0.035), lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                // Slightly larger than the eye group's bounding box (width 0.705×size, height 0.375×size),
                // so the arc does not press onto the eyes.
                .frame(width: size * 1.02, height: size * 1.02)
                // This ring is pure feedback: it must neither steal the hold (it sits right over the eyes' outer edge),
                // nor stretch the `Button`'s tap target outward.
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Double Tap
//
// ★ 2026-10-16 revision seven: moved over from `WatchRingControl.swift` (a note was left there).
// The reason for the move is not that it changed, but that its **landing point** changed: the center of the home screen is no longer a ring button
// but the Bot face above. This modifier was always "bind the gesture to the current page's main control,"
// which is a **control** concern, not a **ring** concern.
//
/// Binds **Double Tap** (pinching index finger and thumb, which Apple calls Double Tap) to the page's main button.
///
/// ## Why a separate `ViewModifier`
/// `.handGestureShortcut(_:isEnabled:)` is an API that appeared only in **watchOS 11.0**, while this
/// project's `WATCHOS_DEPLOYMENT_TARGET` is **10.0**. Splitting it into a modifier lets one explicit
/// `#available` branch spell out two things:
///
/// * **11 and above**: explicitly declare that this button is the gesture's landing point, and that it is **controlled by the switch**
///   (`isEnabled`). Here you must explicitly write `isEnabled: false` rather than "leave it alone" --
///   if you only read the switch in without touching the modifier, the system still routes Double Tap to this page's
///   main button, so it fires even with the switch off.
/// * **10.x**: do nothing. From watchOS 10.1 the system routes Double Tap by itself to the page's
///   the single main button (the center of the home screen has only this eye as a `Button`; the two side menus are
///   `NavigationLink`s and do not take part in primary-action determination), so on that version the gesture
///   works anyway -- no API means **no switch**, which is a system limitation, not an omission.
struct PrimaryHandGesture: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.handGestureShortcut(.primaryAction, isEnabled: enabled)
        } else {
            content
        }
    }
}

// MARK: - The blink rhythm
//
// A human blink is not a constant-rate "open-closed-open" loop. The measured rhythm is:
//   open and rest 2~6 seconds → close **fast** (~80ms) → pause for a beat → open a little more slowly (~130ms)
// and about one time in four it **blinks twice in a row**.
//
// Use `phaseAnimator` to describe it phase by phase, with each phase's own duration in its own `animation`:
// this is exactly why "open and close fast, rest long" can be expressed -- a single
// `repeatForever(autoreverses: true)` can only produce a **symmetric** rhythm,
// closed for as long as it opens, which looks like a twitch rather than a blink.
//
// ⚠️ **No random numbers** here: `phaseAnimator`'s phase list is re-evaluated whenever the view is rebuilt,
// and random durations would make the timeline change on every redraw, so the blink would jitter. For a "random feel," rely on
// the **fixed** structure of "occasionally blinking twice" -- that is what actually characterizes a real person's blink rhythm.
//
// ─────────────────────────────────────────────────────────────────────────
// ## Three versions, three slow-downs (this phase list was changed twice; the ledger stays here)
//
// | version | cycle | user feedback |
// |---|---|---|
// | revision seven | 4.63s | first version |
// | revision eight | 8.12s | "the blinking is too fast, slow the rhythm down" |
// | **revision nine** | **19.12s** | "the eyes should not keep blinking"... "**not no blinking**" |
//
// Revision seven blinked twice in every round, meaning two open-close pairs every 4.6 seconds -- watching it for a few seconds reads as
// "it is blinking constantly," not "it is alive." Revision eight slowed the open-close itself too (85/130ms → 140/220ms,
// a real human eye closing takes about 100~150ms; revision seven's version was really a "flash," not a "close").
//
// That sentence in revision nine **hinges on the second half**: what the user wants is "blink calmly once in a while," **not to delete blinking**.
// So the structure did not move a single cell (still "one double blink inserted between the singles"), only the two rest segments were stretched proportionally:
// `rest` 3.2 → **7.0**, `settle` 3.8 → **11.0**. There is still one
// "double blink" per cycle -- which is precisely the evidence of "not dead-fish eyes."
//
// ⚠️ Stretching only the resting and not the open-close gives a "frozen still → snap" look -- because the relative rhythm
//    is unchanged. To be "slow" you have to slow everything **proportionally**, which is the payoff of describing it phase by phase in the first place:
//    every number is out in the open, so you can change only the ones that need changing.
//
// ⚠️ Stop pushing it further. Revision seven to eight was ×1.75, revision eight to nine was ×2.35 -- doubling it again gets close to
//    once every 30 seconds, which is no longer "blinking occasionally" but "looks broken." If it really still feels too noisy,
//    what should change is **the double blink** (drop the three phases `pause`/`shutAgain`/`openAgain`),
//    not stretching the rest any further.
private enum BlinkPhase: CaseIterable {
    /// Open, resting.
    case rest
    /// Closed.
    case shut
    /// Hold closed for a beat (a real blink has a 40~80ms closed hold; omitting it makes it look like a flash).
    case hold
    /// Open.
    case open
    /// Open, short pause (the second blink of the pair is coming next).
    case pause
    case shutAgain
    case openAgain
    /// Long rest, then back to `rest`.
    case settle

    /// 1 = fully open, 0.05 = closed.
    ///
    /// ⚠️ Closed is not written as 0: when you go to 0 and then scale back up from 0, `scaleEffect` at extremely thin sizes
    /// produces a gap thinner than the line width, which looks like "the eye dropped for a frame." Leaving 0.05 is exactly
    /// the level that looks "closed" to the eye while not showing a gap.
    var openness: CGFloat {
        switch self {
        case .rest, .open, .pause, .openAgain, .settle: return 1
        case .shut, .hold, .shutAgain:                  return 0.05
        }
    }

    /// Each phase's duration = the duration of that phase's animation.
    var animation: Animation {
        switch self {
        case .rest:      return .linear(duration: 7.0)
        case .shut:      return .easeIn(duration: 0.14)
        case .hold:      return .linear(duration: 0.09)
        case .open:      return .easeOut(duration: 0.22)
        case .pause:     return .linear(duration: 0.34)
        case .shutAgain: return .easeIn(duration: 0.13)
        case .openAgain: return .easeOut(duration: 0.20)
        case .settle:    return .linear(duration: 11.0)
        }
    }
}
