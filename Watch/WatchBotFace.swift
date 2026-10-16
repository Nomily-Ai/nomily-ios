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
// ## How this face is put together (the conclusion after four revisions)
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
// ★★ Revision ten (the problem that neither of revision eight's nor nine's two slow-downs solved):
// > `his eyes are not blinking all the time, no need to keep blinking,
// >  https://github.com/sam70361/aora-bot look at the expression management in this repo,
// >  just the eyes is enough, the two eyes should not keep blinking, in the watch`
//
// So I went and read that repo (the `mood-mates/` and `emotion-ball/` engines, two engines from one source, pure SVG +
// native JS), and took apart its idle state (`02 idle blank-out`):
//
// ```js
// pool: [0, 8], poolMs: [9000, 16000], blinkMs: [6000, 14000], antics: true,
// body: { breathe: 0.012 },
// anims: [
//   { target: 'eyes', prop: 'lookX', type: 'glance', amp: 10, period: 4800 },
//   { target: 'eyes', prop: 'lookY', type: 'sine',   amp: 2,  period: 4100, phase: 1.1 }
// ]
// ```
//
// **★ That read turned the whole problem in a different direction.** Revision nine's approach was "stretch the blink cycle longer and longer,"
// and that road had already run out -- because the root cause is not **frequency**, it is these four things below:
//
// 1. **A metronome.** Revision nine was a **fixed 19.12 seconds** per round. A fixed period is the pattern the human eye is best at catching,
//    and once it is caught, every blink becomes "it blinked on schedule again," still mechanical no matter how slow.
//    The reference implementation's `blinkMs: [6000, 14000]` is **drawing a fresh random wait within a range after every blink**
//    (`this._blinkNext = now + rand(...)`), so there is never a beat.
// 2. **A double blink every round.** Revision nine was "one double blink inserted between the singles" -- a cycle **necessarily** has two open-close pairs.
//    The reference implementation is `if (Math.random() < 0.14)` -- **only a 14% chance** of a second blink.
//    So the great majority of the reference implementation's blinks are **a single, 300ms flash**, half the visual weight of revision nine.
// 3. **Blinking is the only motion.** The plus-or-minus 1.8% breathing in revision nine is invisible to the naked eye, so
//    this face was **completely still** for 19 seconds, then suddenly "snap-snap" twice -- both rigid and noisy.
//    The reference implementation's main idle motion is **gaze drift** (`lookX` pausing a moment at each side, `lookY`
//    slowly rising and falling), with blinking only as an accent. The eyes **are never still**, so "blinking" is not noticed at all.
// 4. **Slow.** Revision nine's open-close took 0.45 seconds (140+90+220). The reference implementation totals 300ms,
//    and when opening it **overshoots to 1.08 then falls back to 1** -- that light "spring open" is where "alive" comes from.
//
// ⚠️ Which incidentally works out to a counter-intuitive fact: **the overall blink frequency on both sides is actually about the same.**
//    Revision nine = 2 open-close pairs per 19.12 seconds = **1 per 9.6 seconds**;
//    reference implementation = 1 per 6~14 seconds, 14% of which add a second ≈ **1 per 9 seconds**.
//    ⇒ So revision ten **does not** need to go any slower; what has to change is the **regularity** and the **motion make-up**.
//    (Revision ten still raised the range to 9~20 seconds, quieter than the reference implementation -- the user said "don't
//    keep blinking" two rounds in a row, and when the "reference mechanism" conflicts with the "user constraint" the user wins: copy the mechanism, tighten the numbers.)
//
// ─────────────────────────────────────────────────────────────────────────
// ## The things that make this face "alive" (after revision ten)
//
//   · **Gaze drift** (`runGazeLoop`, **this is the main idle motion**) -- the two eyes **as a whole**
//     look gently left and right, **pausing a moment** at each side before switching, with a 4.8-second period. The reference implementation uses
//     `tanh(2.8·sin)`, a smooth square wave, to express "long pause, fast transition"; here
//     `withAnimation(.easeInOut(0.9))` + sleeping out half a period is an equivalent implementation.
//     ⚠️ It is **the whole pair translating together**, not each eye looking its own way -- doing it separately becomes a squint.
//   · **Occasionally blink once** (`runBlinkLoop`) -- close fast (70ms) → pause 70ms →
//     open to a 1.08 overshoot (80ms) → fall back to 1 over 150ms. **300ms** total, mostly single blinks,
//     14% chance of adding one more after 70ms.
//   · **Breathing** -- the whole pair of eyes slowly inflates and deflates (plus or minus 1.8%, once every 3.6 seconds). The amplitude must be small:
//     any larger and it looks like it is pulsing; it should be small enough that "you can't say what is moving, but it is alive."
//   · **Swap in a waveform while recording** (`WatchVoiceWave`) -- user: "when recording starts it should be
//     a waveform just like heart rate." So the recording state is **not a variant of the eyes**, it is another form:
//     the peak height is the microphone's real level, and when quiet a "thump-tick" base shape keeps a heartbeat-like rhythm.
//   · **The charge ring while holding** -- while the finger stays down, a 2-second progress arc runs around the outside of the eyes. Without it,
//     the user does not know how long to press, nor whether that press was even picked up.
//
// ⚠️ **Why `phaseAnimator` is no longer used** (revisions eight and nine both used it):
//    `phaseAnimator`'s phase list is re-evaluated **whenever the view is rebuilt**, so it cannot give a random duration
//    -- that limitation is what the line "no random numbers here" in revision nine's comment refers to. And the core of this round
//    is precisely **randomness** (drawing a fresh wait after every blink), so the whole thing was switched to a `Task` loop +
//    `withAnimation` driving. That limitation is real and cannot be worked around, so the mechanism had to change.
//
// ⚠️ **Two things from the reference implementation that did not come across** (deliberate, not missed):
//   · The independent sine on `lookY` (amplitude 2 / canvas 240 = 0.83%, only 6.7% relative to the eye-center distance)
//     -- converted to the watch face it is **±1.7pt**, invisible to the naked eye. Its only job is "keep the gaze from being a
//     perfectly horizontal rail," so folding it into the very small vertical component in `runGazeLoop` is enough;
//     it is not worth keeping a separate phase alive for it.
//   · Rotating the eye-shape pool (`calm` / `calm2` swapping every 9~16 seconds). The difference between those two is
//     width ×0.96, height ×1.05 -- that is, **4% / 5%**, smaller than the breathing here,
//     yet it means maintaining one more scale layer. The scale layers already stacked in this file are the two of breathing × poke,
//     and adding one more means nobody can work out the total amplitude (the `figureScale` comment made this point).
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
    /// The heart rate measured by the watch while recording (bpm), forwarded all the way to `WatchVoiceWave` to set the rhythm.
    ///
    /// ★ Added in revision eleven (user: "the overall rise and fall should follow your personal real-time heart rate from the watch").
    /// ⚠️ This face **does not read** this value itself, it only carries it -- the sampling and starting/stopping are both
    ///    inside `WatchHeartRateMonitor`, and the face should not know HealthKit exists.
    let bpm: Double?
    /// The timer shown **directly below** the waveform while recording (`mm:ss`). Pass `nil` while idle.
    ///
    /// ★ Added in revision eleven (user: "attach the recording time below if recording has started").
    ///
    /// ⚠️ Why pass a string in from outside rather than passing a `TimeInterval` in and formatting it here:
    ///    the formatting rules (whether hours appear, whether to pad) belong to the home screen's `WatchFormat`,
    ///    and this only handles placement. Passing a string means the face still does not understand the concept of "time."
    let elapsedText: String?
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
    /// Blink openness. 1 = fully open, 0.05 = closed, may briefly exceed 1 (overshoot).
    ///
    /// ★ Added in revision ten. Revisions eight/nine drove it phase by phase with `phaseAnimator`; here it was changed to
    /// **plain state + assigning each one with `withAnimation` inside a `Task` loop** -- for the reason see
    /// "why `phaseAnimator` is no longer used" at the top of the file (it cannot give a random duration).
    @State private var openness: CGFloat = 1
    /// The idle-state gaze offset. The whole pair translates together, **not** each eye looking its own way.
    @State private var gaze = CGSize.zero
    /// The handles for the two idle loops (blink + gaze), one each.
    ///
    /// ⚠️ Why **two** `Task`s rather than one `withTaskGroup`: `addTask`'s closure is
    ///    `@Sendable`, and capturing `self` (a view struct containing several closures) trips the concurrency checker;
    ///    this project has zero warnings, and it does not go looking for that trouble.
    ///
    /// ⚠️ Why not `.task(id:)`: same reason -- that modifier's closure is `@Sendable` too.
    ///    The `Task {}` here carries `_inheritActorContext` (this file's `pokeOnce()` already uses it),
    ///    so capturing `self` inherits the main actor and, as a bonus, can be cancelled proactively.
    @State private var idleLoop: Task<Void, Never>?
    @State private var gazeLoop: Task<Void, Never>?
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

    // MARK: The idle rhythm (revision ten)
    //
    // For where the numbers come from see the "revision ten" paragraph at the top of the file: the mechanism is copied from `aora-bot`'s idle state, the numbers
    // follow the user's actual feedback -- revision ten tightened them ("don't keep blinking").
    //
    // ⚠️ Why "**draw fresh every time**" rather than a fixed period: see item 1 at the top.
    //    A fixed period = a metronome, and no matter how long it is it still gets read out. Here `Task.sleep` sleeps a random value,
    //    wakes up, blinks once, then draws the next -- structurally there is no beat to speak of.
    /// How long to wait between two blinks (seconds). The reference implementation's idle is `[6, 14]`; here it is raised to **9~20**.
    private static let blinkWait: ClosedRange<Double> = 9 ... 20
    /// The chance of adding one more after a blink. The reference implementation's `Math.random() < 0.14`.
    ///
    /// ⚠️ Do **not** raise this number. Revision nine was "a double blink every round" (= 100%), and that is half the source
    ///    of the "always blinking" look -- a double blink should be the exception, not the beat.
    private static let doubleBlinkChance: Double = 0.14
    /// How long the gaze holds on one side and how long it takes to switch (seconds). The reference implementation's `lookX` has a 4800ms period,
    /// about 1.4 seconds holding on one side and about 1.0 second in transition -- here 1.5 + 0.9, essentially the same.
    private static let gazeHold: Double = 2.4
    private static let gazeShift: Double = 0.9
    /// How far the gaze can travel left and right (relative to `size`).
    ///
    /// The reference implementation's `amp 10` / eye-center-to-midline `30` = **1/3**. This file's eye-center distance is
    /// `0.235 × size`, and copying that directly would reach ±0.078 × size (about ±9pt on 40mm),
    /// which wobbles too much on a watch face. Take **about 55%** of it: ±5.3pt on 40mm, ±6.8pt on 49mm --
    /// you can tell it is "looking around," without looking like it is searching for something.
    private var gazeAmpX: CGFloat { size * 0.045 }
    /// The vertical component of the gaze. Only so the motion is not a **perfectly horizontal rail** --
    /// it is too small to see; see "two things from the reference implementation that did not come across" at the top of the file.
    private var gazeAmpY: CGFloat { size * 0.011 }

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
        .onChange(of: isRecording) { _, _ in
            // ⚠️ Revision ten: both branches now call `startIdleMotion()`, no longer each writing their own.
            //    Because "what to do while recording" is no longer just "park the breathing flat" -- there are now two
            //    `Task` loops to shut down. Letting the single switch decide is safer than duplicating the condition here
            //    (the duplicated copy will eventually miss a newly added loop).
            //
            //    Incidentally: the recording state's waveform has its own rhythm (a heartbeat), and stacking another slow inflate-deflate
            //    makes two cycles fight -- `startIdleMotion()` parks `breathe` flat.
            //
            // ⚠️ Before revision nine there was also a `sway` here (the two eyes drifting out of phase). The recording state
            //    is now swapped entirely for a waveform, the eyes are simply absent, and that state was deleted along with it.
            startIdleMotion()
        }
        .onChange(of: dimmed) { _, _ in
            // Dimmed: stop everything at the rest position. See the paragraph at the top of the file. Same reasoning -- leave it to the single switch.
            startIdleMotion()
        }
        .onDisappear {
            // Close the loops when leaving the home screen. If you do not, this pair of `Task`s keeps hanging around,
            // and each round they write a `@State` nobody is looking at any more.
            idleLoop?.cancel()
            gazeLoop?.cancel()
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

    /// Starts and stops **all** idle motion: breathing + gaze drift + blinking.
    ///
    /// ★ Before revision ten this only handled breathing, with blinking run by `phaseAnimator` itself (blinking as long as the view was around).
    /// Now blinking and gaze are both `Task` loops, and someone has to **explicitly start and explicitly stop** them -- so this
    /// became the single switch: dimming, recording, leaving the page, all shut down from here.
    ///
    /// ⚠️ Every time it is entered it **cancels the old ones first** before deciding whether to start new ones. Not cancelling would stack them:
    ///    `isRecording` and `dimmed` can each change twice in a row, and every loop is a
    ///    "sleep a while → blink once" endless loop, so stacking them doubles the blink rate.
    ///
    /// ⚠️ Revision eight slowed one "inhale-exhale" from 2.6 seconds to **3.6 seconds** (user: "slow the rhythm down").
    ///    After revision ten, breathing is **no longer** this face's most constant motion (the most constant is gaze),
    ///    but any faster still reads as "panting," and it stacks with gaze and blinking to look busy.
    private func startIdleMotion() {
        idleLoop?.cancel()
        idleLoop = nil
        gazeLoop?.cancel()
        gazeLoop = nil

        guard !dimmed, !isRecording else {
            // Back to the rest position. Dimming wants a static open-eyed face, and in the recording state the eyes are simply absent --
            // both are handled by these three lines, leaving no gaze stopped halfway.
            withAnimation(.linear(duration: 0.2)) {
                breathe = false
                openness = 1
                gaze = .zero
            }
            return
        }

        withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
            breathe = true
        }
        // ★ The eyes start, on entering, from the "looking right" position rather than from dead center --
        //   starting from dead center means the first second after the user raises their wrist is "the eyes sliding out from the middle,"
        //   as if just woken up. The reference implementation's lookX is also always-on, with no starting position.
        gaze = CGSize(width: gazeAmpX, height: gazeAmpY)
        idleLoop = Task { await runBlinkLoop() }
        gazeLoop = Task { await runGazeLoop() }
    }

    // MARK: - The idle loops
    //
    // Two loops run side by side, independent of each other:
    //   · `runGazeLoop`  switches sides every 4.8 seconds (**persistent** eye motion)
    //   · `runBlinkLoop` sleeps a random value of 9~20 seconds → blinks once → draws again
    //
    // ⚠️ The two periods are **deliberately unequal** (4.8 vs the 9~20 random), so their relative phase is always
    //    changing -- two motions with equal periods phase-lock, and once phase-locked the whole face starts "tapping out a beat,"
    //    more obvious than a single metronome. In the reference implementation lookX(4.8s) / lookY(4.1s) were likewise
    //    deliberately given different periods.

    /// Gaze: pause a moment on each of the left and right, then switch quickly. The reference implementation's `glance` (`tanh(2.8·sin)`).
    private func runGazeLoop() async {
        var rightSide = true
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.gazeHold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            rightSide.toggle()
            // The vertical travels only a very short distance, and it **follows the horizontal back and forth** -- see `gazeAmpY`.
            withAnimation(.easeInOut(duration: Self.gazeShift)) {
                gaze = CGSize(
                    width: rightSide ? gazeAmpX : -gazeAmpX,
                    height: rightSide ? gazeAmpY : -gazeAmpY
                )
            }
        }
    }

    /// Blinking. **The wait is drawn fresh every time**, and that is the core of revision ten -- see item 1 at the top of the file.
    ///
    /// ⚠️ The reference implementation schedules the next blink from the **start** moment of this blink
    ///    (`this._blinkNext = now + rand(...)`). Here it is scheduled from **after the blink finishes**.
    ///    The difference is only the double blink (about 0.8 seconds), negligible in magnitude, but "after the blink finishes" was chosen deliberately
    ///    -- so that the measure of "between two blinks" is clean: the interval the user perceives does not include
    ///    the 300ms the blink itself takes.
    private func runBlinkLoop() async {
        while !Task.isCancelled {
            let wait = Double.random(in: Self.blinkWait)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await blinkOnce()

            if Double.random(in: 0 ..< 1) < Self.doubleBlinkChance {
                // Add one more after 70ms. The reference implementation is `{at: t+370}`, and this side's first blink
                // is done in 300ms -- so the gap is likewise 70ms.
                try? await Task.sleep(nanoseconds: 70_000_000)
                guard !Task.isCancelled else { return }
                await blinkOnce()
            }
        }
    }

    /// Blink once. The keyframes are copied from the reference implementation's `_blinkNow`:
    /// `close → pause 70ms → open to a 1.08 overshoot → fall back to 1 over 300ms`.
    ///
    /// ⚠️ **Total 300ms, do not stretch it.** Revision nine's open-close was 450ms (140+90+220),
    ///    and the longer it lingers on the watch the more likely it is to be noticed -- "always blinking" had a share of it.
    ///    A real human's eye closing is 100~150ms, a whole blink 200~400ms, and 300ms is exactly the natural range.
    ///
    /// ⚠️ **That 1.08 overshoot is the soul of it**: after opening all the way it opens a touch more then falls back,
    ///    which gives the eye its "spring open." Without it, a plain three-stage open-close looks like a mechanical shutter.
    private func blinkOnce() async {
        withAnimation(.easeIn(duration: 0.07)) { openness = 0.05 }
        try? await Task.sleep(nanoseconds: 70_000_000)
        guard !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: 0.08)) { openness = 1.08 }
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: 0.15)) { openness = 1 }
        try? await Task.sleep(nanoseconds: 150_000_000)
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
    ///
    /// ★ Revision eleven: the recording state goes from "just a wave" to "wave + a timer line directly below." What the user wants is
    /// "attach the recording time below" -- the timer must **hug the wave**, not sit half a face away in the
    /// home screen's little caption line. So it is rendered here instead, no longer part of the home screen's `caption`.
    ///
    /// ⚠️ Using a `VStack` re-centers the whole group inside the face frame, which means the wave sits **slightly higher** than before
    /// (the extra line takes about 8pt). This shift happens only **at the same moment** as the "eyes → wave" switch,
    /// and at that moment the whole picture is being swapped anyway, so it is invisible. Do not write a pile of offsets just to erase it
    /// -- that would turn "where exactly is the wave" into something you have to compute.
    @ViewBuilder
    private var figure: some View {
        if isRecording {
            VStack(spacing: 6) {
                WatchVoiceWave(meter: meter, size: size, tint: tint, bpm: bpm)

                if let elapsedText {
                    Text(elapsedText)
                        // Monospaced digits: otherwise the whole line jitters left and right when the seconds go from 9 to 10.
                        .monospacedDigit()
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
        } else {
            eyes
        }
    }

    /// The two eyes.
    ///
    /// ★ Revision ten: this pair of eyes **as a whole** drifts gently (`gaze`) -- this is the **main
    /// motion** of the idle state, and it is why "don't keep blinking" actually holds: the eyes are never still, so blinking degrades into
    /// an occasional accent rather than the only thing happening (see item 3 at the top of the file).
    ///
    /// ⚠️ It is **the whole pair translating together**, not each eye looking its own way. Doing it separately is not "looking,"
    ///    it is "a squint" -- the reference implementation's `lookX`, outside `_blinkNow`, is likewise the same value
    ///    added to both eyes.
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
        // Gaze. Stacked on top of the "rise" on the line above (the two `offset`s are added).
        .offset(x: gaze.width, y: gaze.height)
    }

    /// One eye.
    ///
    /// Opening/closing is squashed from the center with `scaleEffect(y:)`, not by changing `frame(height:)` --
    /// changing the height makes the eye "grow from the bottom up," whereas a real eyelid comes down **from both sides at once**.
    ///
    /// ★ Revision ten replaces `phaseAnimator` with reading `openness` directly. Revision eight/nine's phase-by-phase
    /// description was deleted outright, for the reason see "why `phaseAnimator` is no longer used" at the top of the file.
    /// The dimmed branch needs no separate check either: `startIdleMotion()` resets `openness`
    /// to 1, so when dimmed this is naturally a static open-eyed face.
    private var eye: some View {
        eyeShape
            .scaleEffect(y: openness, anchor: .center)
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

// MARK: - The blink rhythm (four versions, the ledger stays here)
//
// | version | blink rhythm | user feedback |
// |---|---|---|
// | revision seven | fixed 4.63s, a double blink in every round | first version |
// | revision eight | fixed 8.12s, a double blink every round | "the blinking is too fast, slow the rhythm down" |
// | revision nine | fixed 19.12s, a double blink every round | "the eyes should not keep blinking"... "**not no blinking**" |
// | **revision ten** | **9~20s random, redrawn each time; mostly single blinks, 14% add one** | "**no need to keep blinking**" |
//
// ★ Revision seven through nine is **one road walked three steps: stretching the fixed cycle longer and longer**. By the time it reached 19 seconds
// the user was still saying "no need to keep blinking" -- which shows the road itself is wrong.
//
// The real problem is three things, and the first three versions touched none of them:
//
// 1. **A fixed period = a metronome.** The human eye is far better at catching patterns than intuition suggests: a 19-second cycle
//    still gets caught, and once caught every blink reads as "it blinked on schedule again." **Slow is not the same as natural.**
//    Revision ten changed it to drawing a fresh random value in a range after every blink, so structurally there is no period to speak of.
// 2. **A double blink every round.** Revisions seven/eight/nine were all `100%` double blinks -- two open-close pairs necessarily in every cycle.
//    Real people are not like that: the reference implementation (`aora-bot`) is `Math.random() < 0.14`.
//    Revision ten copies 0.14 ⇒ the great majority of blinks become a single, 300ms flash.
// 3. **Blinking is the only thing moving.** The plus-or-minus 1.8% breathing in revision nine is invisible to the naked eye, so for 19 seconds
//    this face was completely still, then suddenly "snap-snap." Revision ten promotes **gaze drift** to the main idle motion
//    (`runGazeLoop`), the eyes are never still -- so blinking degrades into an accent, no longer the
//    thing that gets noticed. This one is the real solution to "no need to keep blinking."
//
// ⚠️ **Stop going back to tune that fixed period.** To make it quieter, what should change is
//    the upper bound of `blinkWait` (currently 20 seconds), not turning it back into a fixed value.
//    Any combination of "fixed duration + `repeatForever`" falls back into a metronome.
//
// ⚠️ Three invariants; do not casually break them while changing numbers:
//    · blink total duration **300ms** (revision nine was 450ms -- the longer it lingers the more conspicuous);
//    · the eyes **overshoot to 1.08** then fall back to 1 (without it, it looks like a mechanical shutter);
//    · the closed value sits at **0.05**, not 0 (when you go to 0 and then scale back up, `scaleEffect` at extremely thin
//      sizes shows a gap thinner than the line width, which looks like "the eye dropped for a frame").
//
// ⚠️ The gaze period (4.8s) and the blink interval (9~20s random) are **deliberately unequal**, see
//    the "idle loops" comment below `startIdleMotion`: two motions with equal periods phase-lock.
//
// ⚠️ The implementation is no longer at the end of this file -- revision ten deleted the phase-by-phase `BlinkPhase` outright,
//    replacing it with `runBlinkLoop()` / `blinkOnce()` (below `startIdleMotion()`).
//    For the reason see "why `phaseAnimator` is no longer used" at the top of the file.
