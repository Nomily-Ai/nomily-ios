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
// ## The things that make this face "alive" (after revision twelve)
//
//   · **Gaze drift** (`runGazeLoop`, **this is the main idle motion**) -- the two eyes **as a whole**
//     look gently left and right, **pausing a moment** at each side before switching, with a 4.8-second period. The reference implementation uses
//     `tanh(2.8·sin)`, a smooth square wave, to express "long pause, fast transition"; here
//     `withAnimation(.easeInOut(0.9))` + sleeping out half a period is an equivalent implementation.
//     ⚠️ It is **the whole pair translating together**, not each eye looking its own way -- doing it separately becomes a squint.
//   · **Occasionally blink once** (`runBlinkLoop`) -- close fast (70ms) → pause 70ms →
//     open to a 1.08 overshoot (80ms) → fall back to 1 over 150ms. **300ms** total, mostly single blinks,
//     14% chance of adding one more after 70ms. The interval draws from **two tiers** at random (mostly 3.5~6.5 seconds,
//     22% chance of inserting a 10~18 second stretch), see `nextBlinkGap()`.
//   · **A tap gives an expression** (`EyeMood`) -- one of five is drawn and played once: ∩ arched smiling eye / ∪ drooping eye /
//     wide-open / squint / angry glare. This is the **only** action that "actually changes the eye shape";
//     there is still well over half of that 20-slot library in the reference implementation that cannot be brought over, for the reason see the `EyeMood` paragraph below
//     (put simply: a round-tipped vertical bar has only four dimensions it can express).
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
// ⚠️ The second item above **was reversed by revision twelve** -- but reversed in a different way from the reference implementation: not
//    "swap a 4% difference every 9~16 seconds" (nobody can see that kind of swap, and it requires maintaining one more loop),
//    but **a tap giving a whole, instantly distinguishable expression**, returning to idle once it finishes.
//    So there is still no "rotation loop" here, only a one-shot `mood` (see `EyeMood`).
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision twelve (user's words: "in the current colors is there no white on the watch, and while recording
//    the heart-rate rise and fall needs a large amplitude and to take up a big part of the screen, and the eyes need to show various expressions on a light touch rather than
//    a single eye wobble, and the random blink frequency should be just like a normal person's"):
//
// Two of the four items concern this face:
//
// **1. A tap should produce an expression, not just a bounce.** Revision ten's `pokeOnce()` did one thing:
//    bounce the whole face 5%. The user read that as "a single eye wobble" -- and was right; that bounce
//    really is just an "I got it," with no **expression** to speak of.
//    Now a tap **draws a random expression and plays it once** (`EyeMood`, five options: ∩ arched smiling eye / ∪ drooping eye /
//    wide-open / squint / angry glare), springing in, holding about 0.8 seconds, then relaxing back. The overall bounce stays,
//    but is pulled in to 3% -- it is demoted to a "close-up response," and the expression is the star.
//
// **2. Blink frequency is changed back to "a normal person."** Revision ten had tightened it to
//    9~20 seconds based on the user's two rounds of "don't keep blinking," averaging about 1 per 15 seconds. This round the user explicitly asked for "like a normal person," so it was changed to a
//    **two-tier** distribution (`blinkGapNear` / `blinkGapFar`) -- the reasoning and the arithmetic are written over in
//    `nextBlinkGap()`, in one sentence: human blinking is not uniformly random, it is "short intervals with an occasional
//    long stretch inserted." The average is about 1 per 7 seconds (≈ 8.6 per minute), exactly the **person staring at a screen**
//    tier, which is exactly the posture the user is in right now looking at this watch.
//    ⚠️ Revision ten's constraint "don't go back to tuning the fixed period" **was not** violated: what changed is the range, the mechanism
//        is still "draw fresh after every blink," with no fixed period of any kind.
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
    ///
    /// ⚠️ Revision twelve pulled the amplitude in to **3%** (from 5%): it is no longer the **whole** expression of "being poked" --
    ///    the main act became that random expression (`mood`), and this only gives a close-up response.
    ///    Leaving it at 5% would read again as the "single eye wobble" the user described (see `figureScale`).
    @State private var poke: CGFloat = 0
    /// The expression drawn on a tap. `nil` = idle (a pair of vertical capsules).
    ///
    /// ★ Added in revision twelve (user: "the eyes need to have various expressions on a light touch rather than a single eye wobble").
    @State private var mood: EyeMood?
    /// The handle for the expression's `Task`.
    ///
    /// ⚠️ When tapping twice in a row it must **cancel the previous one first**: the two `Task`s each sleep 0.8 seconds and then leave,
    ///    unaware of each other, so the one that wakes first would erase **the new expression that has just come on** --
    ///    showing up as "tapping twice produced nothing at all."
    @State private var moodTask: Task<Void, Never>?
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

    // MARK: The idle rhythm (revision twelve)
    //
    // For where the numbers come from see the "revision ten" and "revision twelve" paragraphs at the top of the file: the mechanism is copied from `aora-bot`'s idle state,
    // and the numbers follow the user's actual feedback -- revision ten tightened them ("don't keep blinking"),
    // revision twelve went back to "a normal person" ("random blink frequency like a normal person").
    //
    // ⚠️ Why "**draw fresh every time**" rather than a fixed period: see item 1 at the top.
    //    A fixed period = a metronome, and no matter how long it is it still gets read out. Here `Task.sleep` sleeps a random value,
    //    wakes up, blinks once, then draws the next -- structurally there is no beat to speak of.
    /// The interval between two blinks (seconds) -- **two tiers**, not one.
    ///
    /// ★ Revision twelve: there used to be only one tier, `9 ... 20`; now it is split into "near" and "far"
    /// (user: "random blink frequency just like a normal person's").
    ///
    /// ## Why it must be two tiers
    /// Human blinking is **not uniformly random**: the vast majority of intervals bunch within a few seconds, but now and then a
    /// long interval of a dozen-plus seconds gets inserted (blinking drops noticeably when spacing out, concentrating, or thinking). Fitting that distribution
    /// with a single uniform range can only hit half of it no matter where you set the range --
    /// tuned dense it is like using a stopwatch, tuned sparse it is like dead-fish eyes. Two tiers express exactly
    /// "the dense majority" and "the sparse minority" separately.
    ///
    /// ## Where the numbers come from
    /// | state | times/min | interval |
    /// |---|---|---|
    /// | relaxed conversation | 15~20 | 3.0~4.0s |
    /// | **staring at a screen / focused** | **5~7** | **8.6~12s** |
    /// | resting average | 12~15 | 4.0~5.0s |
    ///
    /// ⇒ the near tier takes **3.5~6.5** (≈ the human resting tier), the far tier takes **10~18**
    ///   (≈ the staring-at-a-screen tier), with a 22% chance of the far tier.
    ///   Weighted average ≈ 0.78 × 5 + 0.22 × 14 ≈ **7.0 seconds ≈ 8.6 per minute**.
    ///
    /// ⚠️ Revision ten's constraint "don't go back to tuning that fixed period" **was not violated**: what changed is
    ///    **the random range and its distribution**; the mechanism is still "draw a fresh value after every blink,"
    ///    and structurally there is no fixed period. Any "fixed duration + `repeatForever`" is still
    ///    forbidden (that is exactly why revision eight turned into a metronome).
    /// ⚠️ Each tier has one thing it must not do visually: the near tier **must not** drop below 2 seconds (that becomes
    ///    a jitter, not a blink), and the far tier **must not** stretch past 20 seconds (that falls back to revision ten's
    ///    "dead-fish eyes" look -- this is the feedback revision ten received).
    private static let blinkGapNear: ClosedRange<Double> = 3.5 ... 6.5
    private static let blinkGapFar: ClosedRange<Double> = 10 ... 18
    /// The chance of taking the "far" tier. 22% ≈ inserting a long one about every four or five blinks.
    private static let blinkGapFarChance: Double = 0.22
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
            // ★ Revision twelve: the expression one has to be shut down too -- same as above.
            moodTask?.cancel()
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

    /// Starts and stops **all** idle motion: breathing + gaze drift + blinking + expression.
    ///
    /// ★ Before revision ten this only handled breathing, with blinking run by `phaseAnimator` itself (blinking as long as the view was around).
    /// Now blinking and gaze are both `Task` loops, and someone has to **explicitly start and explicitly stop** them -- so this
    /// became the single switch: dimming, recording, leaving the page, all shut down from here.
    /// ★ After revision twelve there is one more managed object: the expression (`moodTask`). It is **not** a loop,
    /// it is a one-shot `Task`; but "invalidated the moment recording starts" is exactly the same as the two loops,
    /// so it is hung on this switch all the same -- rather than adding another cancel line in `onChange(of: isRecording)`,
    /// better to let the single switch shut it all down (the duplicated copy will eventually miss something newly added).
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
        // ★ Revision twelve: the expression's `Task` is managed here too. When recording starts / when dimmed, the expression currently being played has to be
        //   shut down on the spot -- it changes the eyes' size and shape, and in the recording state the eyes are simply absent,
        //   so leaving it hanging would make an expression from two actions ago suddenly pop up after recording ends.
        moodTask?.cancel()
        moodTask = nil

        guard !dimmed, !isRecording else {
            // Back to the rest position. Dimming wants a static open-eyed face, and in the recording state the eyes are simply absent --
            // Both are handled by these four lines, leaving no gaze stopped halfway and no expression half-played.
            withAnimation(.linear(duration: 0.2)) {
                breathe = false
                openness = 1
                gaze = .zero
                mood = nil
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
    //   · `runBlinkLoop` sleeps a random interval (near tier 3.5~6.5s / far tier 10~18s) → blinks once → draws again
    //
    // ⚠️ The two periods are **deliberately unequal** (4.8 vs the two-tier random), so their relative phase is always
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
    ///
    /// ★ Revision twelve changed only one thing: `Double.random(in: blinkWait)` → `nextBlinkGap()`.
    ///    The loop structure, the double-blink chance and `blinkOnce()`'s keyframes **did not move a single cell**.
    private func runBlinkLoop() async {
        while !Task.isCancelled {
            let wait = Self.nextBlinkGap()
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

    /// Draw the next "interval between two blinks."
    ///
    /// ★ Added in revision twelve. This is the whole implementation of "like a normal person" -- first decide by probability whether this round
    /// is "dense" or "sparse," then randomize within that tier. The numbers for the two tiers are documented over at the constants.
    ///
    /// ⚠️ Why draw **twice** rather than use "a skewed distribution": `Double.random` only has a uniform distribution,
    ///    and building a skewed distribution on top of it would need an inverse transform, not worth it for two numbers. The two-tier approach
    ///    instead puts the intent out in the open -- whoever reads the code immediately sees "mostly a few seconds, occasionally a dozen-plus."
    private static func nextBlinkGap() -> Double {
        let far = Double.random(in: 0 ..< 1) < blinkGapFarChance
        return Double.random(in: far ? blinkGapFar : blinkGapNear)
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
    ///
    /// ⚠️ Revision twelve pulled the poke from 5% in to **3%**: it is now just a side dish (the main act is `mood`).
    ///    There are still only **three layers** here, and the expression's deformation is not in this product -- the expression changes the eyes'
    ///    own size and shape (`eye(mirrored:)`), which is a different matter from the whole face's inflate-deflate,
    ///    and mixing it into this product would turn into "how big the expression is depends on where the breathing happened to be."
    private var figureScale: CGFloat {
        var s: CGFloat = (dimmed || isRecording) ? 1 : (breathe ? 1.028 : 0.992)
        s *= 1 + poke * 0.03
        return s
    }

    /// Tapped while idle: **bounce once + play a random expression**.
    ///
    /// ⚠️ Starting recording is still not this -- starting recording is a 2-second hold, a Double Tap, or a shake.
    ///
    /// Why there has to be feedback: if a tap does nothing at all, the user assumes "maybe I have to hold it," so
    /// they start trying random things. So this one has to say "I got it."
    ///
    /// ★ Revision twelve (user: "the eyes need to have various expressions on a light touch rather than a single eye wobble"):
    /// before revision ten there was only the overall bounce here, and the user described that bounce as "a single eye wobble"
    /// -- accurate. Now the bounce is only the **response**, and the **expression** is the content:
    /// one of five is drawn at random (∩ arched smiling eye / ∪ drooping eye / wide-open / squint / angry glare), played once and withdrawn.
    ///
    /// ⚠️ Their **happening at once** is deliberate (not casually stacked): a pure expression change has no "I was tapped" feel,
    ///    and a pure bounce has no expression -- what the user complained about was exactly "only the latter."
    private func pokeOnce() {
        guard !isRecording, !dimmed else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { poke = 1 }
        Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { poke = 0 }
        }
        playRandomMood()
    }

    /// Play one expression once: 0.26 seconds coming in → hold about 0.8 seconds → 0.34 seconds leaving.
    ///
    /// ⚠️ Every time it **cancels the previous** `Task` first (see the `moodTask` paragraph): on a double tap,
    ///    the one that wakes first erases the new expression that has just come on.
    ///
    /// ⚠️ The exit uses `easeOut` rather than `spring`: the entrance should spring ("got amused"),
    ///    and the exit should go back **loosely**. Using spring at both ends makes "withdrawing the expression" look like it is being sprung back.
    ///
    /// ⚠️ 0.8 seconds is the level between "clearly visible" and "not in the way." Below 0.5 seconds it looks like a flash,
    ///    above 1.2 seconds the user starts waiting for it to go back (this face can be held at any moment, so it cannot hang
    ///    an expression for a long time).
    private func playRandomMood() {
        moodTask?.cancel()
        guard let next = EyeMood.allCases.randomElement() else { return }
        moodTask = Task {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.72)) { mood = next }
            try? await Task.sleep(nanoseconds: 820_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.34)) { mood = nil }
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
            // ★ Revision twelve: the two eyes each know whether they are the "right eye." `EyeMood.tilt` writes only one
            //   number (the left eye's), and the right eye takes its negation -- so "the two eyes slanting symmetrically" (an angry face)
            //   needs only one number to express, rather than writing an angle for each eye.
            //   ⚠️ What is meant here is **the symmetry of the eye shape itself**, which is a different thing from the `gaze`
            //      below (the whole pair translating together); do not mix them up.
            eye(mirrored: false)
            eye(mirrored: true)
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
    ///
    /// ★ Revision twelve: both **drawing methods** (capsule + arc) sit inside at once, cross-fading via `opacity`,
    /// rather than picking one with `if/else`. The reason is that `if/else` swaps **view identity**,
    /// and the frame it swaps on gives only a hard cut (the view is removed and another inserted), whereas these two precisely need
    /// a smooth transition -- what the user should see is "the eye squints into an arc," not "it flashed."
    ///
    /// ⚠️ The outer `frame` is **fixed** (`eyeWidth × eyeHeight`) and does not follow the expression.
    ///   With it fixed: the `HStack`'s spacing does not change with the expression (the two eyes' spacing suddenly widening is more conspicuous than the expression
    ///   itself), and both drawing methods have the same alignment reference.
    ///   Anything beyond this box is not clipped -- `frame` does not clip, only `.clipped()` does.
    private func eye(mirrored: Bool) -> some View {
        let current = mood
        let widthScale = current?.scaleX ?? 1
        let isArc = current?.isArc ?? false

        return ZStack {
            eyeShape(widthScale: widthScale, heightScale: current?.scaleY ?? 1)
                .opacity(isArc ? 0 : 1)
            eyeArc(up: current?.arcUp ?? true, widthScale: widthScale)
                .opacity(isArc ? 1 : 0)
        }
        .frame(width: eyeWidth, height: eyeHeight)
        .rotationEffect(.degrees(mirrored ? -(current?.tilt ?? 0) : (current?.tilt ?? 0)))
        .scaleEffect(y: openness, anchor: .center)
    }

    /// The eyes for the idle state, and for the expressions that "do not change shape": a round-tipped vertical bar.
    ///
    /// Uses the color chosen on the "Appearance" page, **solid** (revision nine dropped the gradient).
    private func eyeShape(widthScale: CGFloat, heightScale: CGFloat) -> some View {
        Capsule()
            .fill(tint)
            .frame(width: eyeWidth * widthScale, height: eyeHeight * heightScale)
    }

    /// The arc for the arched smiling eye (∩) / drooping eye (∪).
    ///
    /// ⚠️ height = `eyeHeight × 0.44`, thickness = `eyeHeight × 0.20` (about 20pt tall and
    ///    9pt thick on 40mm). **It must not be drawn thin**: a thin arc on the watch face reads as an eyebrow, or a scratch;
    ///    only thick enough to approach the thickness of a closed eye does it read as "this is a smiling eye."
    ///    This is also why `EyeCurve` is a "stroke" rather than a "fill" -- so the thickness can be adjusted on its own.
    private func eyeArc(up: Bool, widthScale: CGFloat) -> some View {
        EyeCurve(up: up)
            .stroke(
                tint,
                style: StrokeStyle(lineWidth: eyeHeight * 0.20, lineCap: .round)
            )
            .frame(width: eyeWidth * widthScale, height: eyeHeight * 0.44)
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

// MARK: - Expressions (★ 2026-10-16 added in revision twelve)
//
// The user's exact words: "the eyes need to have various expressions on a light touch rather than a single eye wobble."
//
// ## Where the assets come from
// The `aora-bot` expression library (`mood-mates/src/core/geometry.js`) has **20 eye-shape
// slots**: `calm / calm2 / happy / happy2 / wide / wide2 / closed / closed2 /
// sleepy / squint / squint2 / angry / angry2 / scan / scan2 / scan3 /
// listen / listen2 / shy / sad`. Each slot is a set of parameters
// `{ w, h, bend, taper, slope, shift }`。
//
// ## Why only five could be brought over
// An eye here is a `Capsule` (a round-tipped vertical bar), not a bendable path. In the reference implementation
// `bend` / `taper` describe "how this eye line bends and how its ends taper" --
// that needs a shape capable of drawing an arbitrary curve. So the dimensions expressible here are only four:
//
//   · **height** (`scaleY`) -- open wide / squint
//   · **width** (`scaleX`)
//   · **tilt** (`tilt`) -- slant
//   · **straight / curved** (`isArc`) -- the two curved ones swap in an `EyeCurve` stroke
//
// So the five below were "selected" from the 20 slots, not accepted wholesale.
//
// ## ⚠️ Two rules kept when choosing
// 1. **Distinguishable at a glance.** In the reference implementation the difference between `calm` and `calm2` is width ×0.96, height ×1.05
//    -- 4% / 5%, not much more than the idle breathing (plus or minus 1.8%). Put into this pool, tapping five times in a row
//    might land on the "indistinguishable" two tiers four times, and the user concludes "tapping does nothing."
//    ⇒ The five that get drawn must be **recognizable as different expressions from half a meter away**.
// 2. **They cannot be "closed eyes."** The `closed` / `sleepy` tiers would collide with **blinking** on the watch --
//    the user could not tell "it is blinking at me" from "it switched to sleeping." So they are not in the pool.
private enum EyeMood: CaseIterable {
    /// ∩ arched smiling eye. The reference implementation's `happy`: `{ w: ×1.05, h: ×0.5, bend: 0.62, taper: 1.15 }`.
    case happy
    /// ∪ drooping eye. The reference implementation's `sad` tier -- the same arc flipped over, a "deflated" eye.
    case sad
    /// Wide-open. The reference implementation's `wide`: `{ w: ×1.12, h: ×1.3, bend: 0, taper: 0.8 }`.
    case wide
    /// Squint. The reference implementation's `squint` tier (height compressed to about a third).
    case squint
    /// Angry glare. The reference implementation's `angry`: `{ slope: -0.5, shift: 0.3 }` -- the inner side pressed down.
    case angry

    /// The eye width multiplier.
    var scaleX: CGFloat {
        switch self {
        case .happy:  return 1.06
        case .sad:    return 1.00
        case .wide:   return 1.06
        case .squint: return 1.04
        case .angry:  return 1.00
        }
    }

    /// The eye height multiplier (relative to the idle `0.375 × size` vertical bar).
    ///
    /// ⚠️ The two arc shapes **ignore** this value -- the arc's height is set by `eyeArc` itself (`0.44 ×`),
    ///    because "multiplying a 20pt-tall arc by 0.5" would turn it into an almost invisible thin line,
    ///    rather than "a squint." So these two tiers are given 1, letting the arc keep its own shape.
    var scaleY: CGFloat {
        switch self {
        case .happy, .sad: return 1
        case .wide:        return 1.24
        case .squint:      return 0.34
        case .angry:       return 0.80
        }
    }

    /// How many degrees the **left eye** turns; the right eye takes the negative (see `eye(mirrored:)`), so the two eyes
    /// are automatically symmetric.
    ///
    /// ## Why it is negative
    /// The screen's y-axis points down, so **a positive angle = clockwise**. The left eye turns −12° (counterclockwise) ⇒
    /// the top end of this vertical bar tilts **outward** (further from the midline) and the bottom end tilts **inward** --
    /// so the two eyes **converge toward the midline at the bottom**, and the brow forms a "∧".
    ///
    /// ⚠️ This direction is the entire source of "angry"; written the other way it becomes a different expression:
    ///    · bottom ends converging (−12°) = "∧" = angry brows (inner ends pressed down);
    ///    · top ends converging (+12°) = "∨" = that is aggrieved / pitiful, not angry.
    ///    So **do not casually flip this number to positive** -- before changing it, draw the two bars on paper first.
    ///
    /// ⚠️ More important is "the two eyes are **opposite**" itself: both eyes turning the same direction (`///`)
    ///    is not angry, it is a squint. In the reference implementation `slope` is signed, for the same reason.
    var tilt: Double {
        switch self {
        case .angry: return -12
        default:     return 0
        }
    }

    /// Whether it is drawn as an arc (arched smiling eye / drooping eye).
    var isArc: Bool { self == .happy || self == .sad }

    /// Whether the arc arches up or down.
    var arcUp: Bool { self == .happy }
}

/// An arc bowing up (∩) or down (∪).
///
/// ★ Added in revision twelve; it is the only tier in the whole expression set that **changes shape** (the other four are scaling/rotation).
///
/// ⚠️ Use a quadratic Bézier rather than `Circle().trim(from:to:)`: `trim`'s start position and drawing
///    direction hang on SwiftUI's "y axis down, angles clockwise" convention, which is the easiest place to
///    go wrong and the hardest to read when changing the drawing. Writing "both ends on the midline, the apex raised to the edge" with control points is
///    **self-evident** -- the formulas in the two comment lines below can be verified directly.
private struct EyeCurve: Shape {
    /// `true` = ∩ (smile), `false` = ∪ (droop).
    let up: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // The midpoint of a quadratic Bézier is B(0.5) = ¼P₀ + ½P₁ + ¼P₂. To have the midpoint land exactly on the edge
        // (the `minY` when bowing up), the control point must sit one more height **outside the box**:
        //   0.5·maxY + 0.5·P₁.y = minY  ⇒  P₁.y = 2·minY − maxY
        // the two ends are pinned to the other edge, so the arc exactly fills the whole `rect`.
        let anchor = up ? rect.maxY : rect.minY
        let controlY = up ? rect.minY - rect.height : rect.maxY + rect.height
        path.move(to: CGPoint(x: rect.minX, y: anchor))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: anchor),
            control: CGPoint(x: rect.midX, y: controlY)
        )
        return path
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

// MARK: - The blink rhythm (five versions, the ledger stays here)
//
// | version | blink rhythm | user feedback |
// |---|---|---|
// | revision seven | fixed 4.63s, a double blink in every round | first version |
// | revision eight | fixed 8.12s, a double blink every round | "the blinking is too fast, slow the rhythm down" |
// | revision nine | fixed 19.12s, a double blink every round | "the eyes should not keep blinking"... "**not no blinking**" |
// | revision ten | 9~20s random, redrawn each time; mostly single blinks, 14% add one | "**no need to keep blinking**" |
// | **revision twelve** | **two-tier random: mostly 3.5~6.5s, 22% chance of 10~18s; mostly single blinks, 14% add one** | "**random blink frequency just like a normal person's**" |
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
// ★★ Revision twelve is **the first time this line went the other way** (denser). Revision ten had tightened the range to 9~20,
// based on the user's two rounds of "don't keep blinking"; this round the user explicitly changed their mind and asked for "like a normal person,"
// so it was redrawn against the measured human frequency and switched from **one uniform tier** to **two tiers**:
// human blinking is "short intervals with an occasional long stretch inserted," not a uniform distribution -- for the arithmetic see the table
// above `nextBlinkGap()` and the comments on `blinkGapNear` / `blinkGapFar`. The weighted average ≈ 1 per 7 seconds
// (≈ 8.6 per minute), landing in the "person staring at a screen" tier.
//
// ⚠️ The only thing on this line that **has never been reversed** is: no fixed period.
//    · want it quieter → tune `blinkGapFar` (the far tier's upper bound);
//    · want it denser → tune `blinkGapNear` / lower `blinkGapFarChance`.
//    Any combination of "fixed duration + `repeatForever`" falls back into a metronome (that is how revision eight crashed).
//
// ⚠️ Three invariants; do not casually break them while changing numbers:
//    · blink total duration **300ms** (revision nine was 450ms -- the longer it lingers the more conspicuous);
//    · the eyes **overshoot to 1.08** then fall back to 1 (without it, it looks like a mechanical shutter);
//    · the closed value sits at **0.05**, not 0 (when you go to 0 and then scale back up, `scaleEffect` at extremely thin
//      sizes shows a gap thinner than the line width, which looks like "the eye dropped for a frame").
//
// ⚠️ The gaze period (4.8s) and the blink interval (two-tier random) are **deliberately unequal**, see
//    the "idle loops" comment below `startIdleMotion`: two motions with equal periods phase-lock.
//
// ⚠️ The implementation is no longer at the end of this file -- revision ten deleted the phase-by-phase `BlinkPhase` outright,
//    replacing it with `runBlinkLoop()` / `blinkOnce()` (below `startIdleMotion()`).
//    For the reason see "why `phaseAnimator` is no longer used" at the top of the file.
//    Revision twelve changed only the "draw the interval" step (`nextBlinkGap()`); the loop structure did not move a single cell.
