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
// ★★ 2026-10-16 revision thirteen (user's words: "the Nomily AI app's settings need one more
//    namely a setting for the watch home screen eyes' expression, bringing the expressions of the gork bot on github into
//    the Nomily ai settings with support for putting in their expressions"):
//
// Revision twelve's five expressions are **read-only**: a tap draws one at random and plays it once, and the user cannot choose.
// This round promoted "expression" from a **behavior** to a **setting**:
//
//   · The expression library (nine tiers) moved to `Sources/Services/Watch/BotFaceStyle.swift` --
//     a file **shared by both ends**, so the preview in the picker on the iPhone and the face actually drawn on the watch
//     **are necessarily the same code**, and cannot drift.
//   · This face takes one more `style`: the **persistent** tier, chosen by the user on the iPhone and
//     pushed over via `WatchConnectivity` (see `WatchFaceStore` / `WatchLink`).
//   · The pool on a tap goes from "a hard-coded five tiers" to "the eight tiers in the library other than the persistent one" --
//     drawing a tier the same as the persistent one equals "the tap did nothing," which is exactly the complaint revision twelve was fixing.
//
// ⚠️ **The two private types `EyeMood` and `EyeCurve` were deleted outright** (the former was revision twelve's read-only
//    expression pool, the latter the shape of that arc). Their contents are now in the shared file, named
//    `BotFaceStyle` and `BotFaceEyeCurve`. Keeping the old copy would be to allow "what is drawn on the watch"
//    and "what is previewed on the phone" to go their separate ways -- and writing the geometry twice is the kind of drift that is hardest to spot
//    and does the most harm (the user picks a smiling eye on the phone and, raising their wrist, finds a drooping eye).
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision fifteen (user's words:
//    "right now tapping the eyes doesn't go straight to a white screen, it spreads those two eyes across the whole screen"):
// This is about the picture during those two seconds of holding. Revision fourteen drew a solid circle growing out from the eyes' position,
// which the user read as "the two eyes spreading," whereas what he wants is **the whole screen changing color at once**. So it became a full-screen solid color
// Use opacity as the progress.
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision sixteen (user's words:
//    "what I want is for the two eyes, based on where I press down, to automatically merge together at the place I press,
//     and then slowly spread across the whole screen and jump over to the recording side"):
// Revision fifteen's "whole screen brightening" was rejected -- clean, but with **no origin**: the color rose out of thin air across the whole screen
// with nothing to do with those two eyes. This round adds the sequence back, splitting the hold into two pieces of geometry:
// **merge first (the first 32%), then spread (the last 68%)**, with the merge target being **where the finger pressed**.
// The implementation is all in `holdLayer`; how the parameters were chosen is written in the paragraph above it.
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
//   · **What the idle state looks like is up to the user** (`style`, ★ revision thirteen) -- nine tiers of expressions are chosen
//     in the iPhone settings (`BotFaceStyle`), and the chosen tier persists on this face.
//   · **A tap gives an expression** (`BotFaceStyle.tapPool`) -- one tier is drawn from the library and played once,
//     then withdrawn to the persistent tier. This is the **only** action that "actually changes the eye shape";
//     there is still well over half of that 20-slot library in the reference implementation that cannot be brought over, for the reason see the top of
//     `Sources/Services/Watch/BotFaceStyle.swift`
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
    /// The **persistent** expression on the home screen. The user chooses it in the iPhone settings, and it is pushed
    /// over via WatchConnectivity (★ added in revision thirteen, see the paragraph at the top of the file).
    ///
    /// ⚠️ It is "what the idle state looks like," **not** "what a tap plays" -- the latter is still a one-shot
    ///    `mood`, see `playRandomMood()`.
    let style: BotFaceStyle
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
    /// The number of shake triggers. The home screen adds 1, and this makes the eyes **spin in circles** (see `playDizzy()`).
    ///
    /// ★ Added in revision fourteen (user: "change the watch's shake so a shake makes the eyes spin in circles with a dizzy feel
    /// and adds interaction"). The reason for using a counter as the trigger is the same as `pokeTick` -- this face is a value type,
    /// and the home screen constructs it inline in `body`, so it cannot get a reference to the instance.
    let dizzyTick: Int
    /// Whether Double Tap can start/stop recording. Toggled in by `WatchRecordingPrefs.pinchToRecord`.
    let handGestureEnabled: Bool
    /// Blink pace — pushed from the iPhone (★ 2026-10-20). Scales only the gaps
    /// **between** blinks, never the 300 ms blink keyframes (see `BotBlinkSpeed`).
    let blinkSpeed: BotBlinkSpeed
    /// Whether the idle expression **auto-cycles** inside the square frame
    /// (★ 2026-10-20, user: "the expression should display and change dynamically in the
    /// square frame"). When on, a background loop springs to a fresh tier from the
    /// library every few seconds; the tap one-shot (`mood`) still wins while it plays.
    let autoCycle: Bool
    /// Whether the rounded-square frame is drawn around the face (★ 2026-10-20,
    /// user: "according to the square frame"). Revision eight removed the *plate*
    /// ("no green, just make the frame two eyes"); this is the frame coming back —
    /// but as a **stroke in the eye colour**, not a filled plate.
    let frameVisible: Bool
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
    /// The expression drawn on a tap. `nil` = idle (draw the `style` tier).
    ///
    /// ★ Added in revision twelve (user: "the eyes need to have various expressions on a light touch rather than a single eye wobble").
    /// ★ Revision thirteen: the type changed from the private `EyeMood` to the shared `BotFaceStyle` -- reading it directly
    ///   makes it the same enum as "the tier chosen in settings," so the pool can be "the other tiers in the library besides the persistent one,"
    ///   rather than a separate list that has to be maintained alongside the library.
    @State private var mood: BotFaceStyle?
    /// The handle for the expression's `Task`.
    ///
    /// ⚠️ When tapping twice in a row it must **cancel the previous one first**: the two `Task`s each sleep 0.8 seconds and then leave,
    ///    unaware of each other, so the one that wakes first would erase **the new expression that has just come on** --
    ///    showing up as "tapping twice produced nothing at all."
    @State private var moodTask: Task<Void, Never>?
    /// The tier the **auto-express cycle** currently has on (★ 2026-10-20).
    /// `nil` = draw the user's persistent tier. Priority: `mood` (a tap's one-shot)
    /// → `cycleStyle` (the auto cycle) → `style` (what the phone pinned).
    @State private var cycleStyle: BotFaceStyle?
    /// The handle for the auto-express loop.
    @State private var cycleTask: Task<Void, Never>?
    /// How many degrees the eyes have **spun in circles** so far. 0 = not spinning.
    ///
    /// ★ Added in revision fourteen, see `playDizzy()`.
    @State private var dizzyAngle: Double = 0
    /// The handle for the dizzy `Task`. Shaking twice in a row must cancel the previous one first, for the same reason as `moodTask`.
    @State private var dizzyTask: Task<Void, Never>?
    /// Hold progress 0...1.
    ///
    /// ★ Revision fourteen: what it drives is no longer that ring of "2-second progress arc," but a patch of color that fills the screen.
    /// ★ Revision fifteen: the **opacity** of that color patch is it.
    /// ★★ Revision sixteen: what it drives now is **two pieces of geometry** (see `holdLayer`) --
    ///   the first 32% kneads the two eyes into one blob, the last 68% spreads that blob until it fills the whole screen.
    @State private var holdProgress: CGFloat = 0
    /// The position where the finger pressed (**this face's local coordinates**). `nil` = not pressed yet.
    ///
    /// ★★ Added in revision sixteen (user: "the two eyes automatically merge together at the place I press").
    /// It only answers "where to merge toward" and takes part in no decision -- the hold timing is still entirely
    /// `LongPressGesture`'s business.
    ///
    /// ⚠️ Lifting the finger does **not** clear it: during the 0.16 seconds that `holdProgress` rolls back, the two eyes still travel back
    ///    along this point. Clearing it would make them divert to the face center mid-return. The next press overwrites it.
    @State private var pressPoint: CGPoint?
    /// The switch for the color patch to **fade out** after the hold has run its course and recording has started.
    ///
    /// ⚠️ `holdProgress` cannot simply be zeroed: at that moment the user has just let go and the screen is about to switch to the
    ///    recording state, and a patch of color already covering the screen vanishing with a "snap" would flash. Let it **fill first,
    ///    then fade out** (0.5 seconds), and the wave picks up at the same time it fades -- this is exactly what the user wants,
    ///    "fill the entire screen **then** show the heart-rate time ripple."
    ///    ⚠️ Revision fifteen turned `holdProgress` into the color patch's **opacity**; revision sixteen turned it
    ///    into **the progress of the two pieces of geometry**, so "filled" and "faded out" are now handled separately by
    ///    what `holdLayer` draws and this layer's `sweepFading`, each minding its own business.
    @State private var sweepFading = false
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
    // ★ Revision thirteen: the eyes' size and spacing **moved to `BotFaceMetrics`** (the shared file
    // `Sources/Services/Watch/BotFaceStyle.swift`）。
    //
    // ⚠️ The reason for the move is not tidying up, it is **necessary**: the expression picker on the iPhone has to lay out a preview,
    //    and "how big the eye in the preview is" and "how big the eye on the watch is" must be **the same formula** --
    //    written separately, the user's chosen expression and what they see on real hardware would not be in proportion, and that kind of inconsistency
    //    is extremely hard to spot across two screens of different sizes.
    //
    // ℹ️ Revision eight once enlarged the eyes by one step (width 0.185 → 0.235, height 0.285 → 0.375):
    //    the old sizes were calculated to go with the rounded-square plate, and once the plate was gone the eyes were the whole face,
    //    so at the old size they looked small and empty. Those numbers are now `BotFaceMetrics`'s defaults.

    var body: some View {
        // Use a `Button` instead of a bare view: `handGestureShortcut` (Double Tap)
        // only works on button-like controls -- see the paragraph at the top of the file.
        //
        // ⚠️ This one action receives **both** kinds of input: a finger tap and a Double Tap.
        //    So it has to be split apart again by `handlePrimaryAction()` -- you cannot write one kind's
        //    behavior directly here.
        Button(action: handlePrimaryAction) {
            ZStack {
                // ★ 2026-10-20: the square frame is back (user: "按照方框动态显示变动") --
                // but as a **stroke in the eye colour**, not the filled plate revision eight
                // removed ("no green"). The expression cycles *inside* it; the frame itself
                // scales with the same breathing product as the eyes, so the whole figure
                // breathes as one.
                if frameVisible {
                    RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                        .strokeBorder(tint.opacity(0.85), lineWidth: max(3, size * 0.045))
                        .frame(width: size * 1.02, height: size * 1.02)
                        .scaleEffect(figureScale)
                        .opacity(figureOpacity)
                }
                figure
                    .scaleEffect(figureScale)
                    // During a hold, yield the position to the two inside `holdLayer` (see `figureOpacity`).
                    .opacity(figureOpacity)
                    .animation(.spring(response: 0.34, dampingFraction: 0.62), value: isRecording)
                // ★ Revision fifteen: the color patch is drawn in the **top layer** (in revision fourteen it was in the bottom layer).
                // ★★ Revision sixteen: it handles both "kneading the two eyes into one blob" and "spreading across the screen,"
                //    so from the very first frame of the press it has to take over the eyes -- which is why `figure`'s two
                //    have to yield (`figureOpacity`).
                holdLayer
            }
            // This outer frame is the face's **nominal** boundary (all of `BotFaceMetrics` derives its proportions from it).
            // ⚠️ It **does not clip** its content -- the color patch during a hold has to spill all the way to the screen edge, and this is exactly what makes that possible.
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
        // ★★ Revision sixteen: used only to answer "where the finger pressed."
        // ⚠️ It must **sit alongside** the hold (`simultaneousGesture`), not be chained into `holdGesture`
        //    : `LongPressGesture` gives no coordinates, and "where the finger was at the moment of pressing"
        //    is known only to a drag gesture -- chained together, it would not arrive until the hold ended, by which time the eyes
        //    would long since have finished merging.
        .simultaneousGesture(pressLocation)
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
        .onChange(of: dizzyTick) { _, _ in playDizzy() }
        .onChange(of: holding) { _, pressing in
            // ★ Record a timestamp on both press and release: the Button's action fires at the moment of **release**,
            //   so recording only the press would make "hold for a moment then let go" be misjudged
            //   as a Double Tap because of the large time gap (which would turn "pressed for 1 second and gave up" into
            //   "start recording").
            lastTouchAt = Date()

            // A hold while recording does not light up the progress -- otherwise the user thinks "two more seconds and it starts again."
            guard !isRecording else { return }
            if pressing {
                // ★ Revision fourteen: first clear away the residue from the previous round (**without animation**), then grow it back from scratch.
                //    The last time the hold ended, `holdProgress` was left at 1 and `sweepFading` was true
                //    (the color patch had only faded out; its size was unchanged). Without clearing it, this press starts straight from
                //    "a full-screen fill" -- what the user sees is not "the color growing," just a flash.
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) {
                    holdProgress = 0
                    sweepFading = false
                }
                // The progress filling up is exactly 2 seconds, aligned with the gesture's minimumDuration.
                // Once the two disagree, you get either "recording starts before the color has filled the screen" or
                // "the screen is full but recording never starts" -- both make the user stop trusting this action.
                withAnimation(.linear(duration: Self.holdSeconds)) { holdProgress = 1 }
            } else {
                // ⚠️ Do not collapse the **successful** hold path here: `onEnded` has already taken that over
                //    with a 0.5-second fade-out. Collapsing it again here (0.16 seconds) would yank the color patch away
                //    over 0.16 seconds -- the user's "fill the whole screen **then** see the wave" would become
                //    "a flash of white."
                //    The leftover `holdProgress` / `sweepFading` need no attention: on the next press
                //    that `if pressing` branch zeroes them **without animation**.
                guard !sweepFading else { return }
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
            // ★ Revision fourteen: the dizzy one has to be cancelled too.
            dizzyTask?.cancel()
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
                // ★ Revision fourteen: the color **fills first, then fades out**, rather than "the ring collapsing."
                //    Before revision thirteen this collapsed the progress arc within 0.12 seconds, because an arc left
                //    shown as "completed" would clash with the recording-state glow. Now it is a whole patch of color: its 0.5-second fade-out
                //    exactly covers the "eyes → wave" switch, so it reads as
                //    "the color washes across the screen → the wave lights up as the color recedes."
                withAnimation(.easeOut(duration: 0.5)) { sweepFading = true }
                onHold()
            }
    }

    /// Its only job is to answer "where the finger pressed." It makes no decisions and takes no part in timing.
    ///
    /// ★★ Added in revision sixteen (user: "the two eyes automatically merge together at the place I press").
    ///
    /// ## Why a drag with `minimumDistance: 0`
    /// * A tap (`SpatialTapGesture`) only gives coordinates on **release**, whereas what we want is
    ///   "where the finger was at the moment of pressing";
    /// * `LongPressGesture` gives no coordinates at all.
    ///
    /// ## Why it is recorded only once, on the first frame
    /// A finger held down for 2 seconds cannot stay perfectly still. Updating it every frame would make the two eyes
    /// drift along a little with the finger -- looking like they are stuck to it, rather than "merging toward where it pressed."
    private var pressLocation: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard pressPoint == nil else { return }
                pressPoint = value.startLocation
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
        // ★ 2026-10-20: the auto-express cycle is managed by the same single switch —
        //   it changes the eye shape exactly like `mood` does, so it must vanish the
        //   moment recording starts or the face dims.
        cycleTask?.cancel()
        cycleTask = nil

        guard !dimmed, !isRecording else {
            // Back to the rest position. Dimming wants a static open-eyed face, and in the recording state the eyes are simply absent --
            // Both are handled by these four lines, leaving no gaze stopped halfway and no expression half-played.
            withAnimation(.linear(duration: 0.2)) {
                breathe = false
                openness = 1
                gaze = .zero
                mood = nil
                cycleStyle = nil
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
        if autoCycle {
            cycleTask = Task { await runExpressCycle() }
        }
    }

    /// The **auto-express cycle** (★ 2026-10-20, user: "the expression should display and
    /// change dynamically in the square frame"). Every few seconds the face springs to a
    /// fresh tier drawn from the library — the square frame stays put and the expression
    /// inside it keeps changing.
    ///
    /// ## The rules
    /// * The next tier is drawn from `tapPool(excluding:)` — never the same tier twice in
    ///   a row (a "swap" to the same shape reads as the loop being broken), never `calm`
    ///   (drawing the idle state = nothing happened).
    /// * The wait is **drawn fresh** from `blinkSpeed.expressCycle` each time — the same
    ///   "no metronome" rule the blink loop lives by.
    /// * There is no "return to base": the cycle *is* the idle look while it's on. That's
    ///   what "动态显示变动" asks for — the face keeps changing, rather than playing
    ///   one shot and snapping back.
    /// * A tap still wins: `mood` sits above `cycleStyle` in `shownStyle`, and the tap's
    ///   one-shot expires back into whatever the cycle is currently wearing.
    private func runExpressCycle() async {
        while !Task.isCancelled {
            let wait = Double.random(in: blinkSpeed.expressCycle)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let current = cycleStyle ?? style
            let pool = BotFaceStyle.tapPool(excluding: current)
            guard let next = pool.randomElement() else { return }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.66)) {
                cycleStyle = next
            }
        }
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
            let wait = nextBlinkGap()
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
    /// Draw the next "interval between two blinks."
    ///
    /// ★ Added in revision twelve. This is the whole implementation of "like a normal person" -- first decide by probability whether this round
    /// is "dense" or "sparse," then randomize within that tier. The numbers for the two tiers are documented over at the constants.
    ///
    /// ⚠️ Why draw **twice** rather than use "a skewed distribution": `Double.random` only has a uniform distribution,
    ///    and building a skewed distribution on top of it would need an inverse transform, not worth it for two numbers. The two-tier approach
    ///    instead puts the intent out in the open -- whoever reads the code immediately sees "mostly a few seconds, occasionally a dozen-plus."
    ///
    /// ★ 2026-10-20: the tiers' *product* is scaled by `blinkSpeed` — the shape of the
    /// distribution (two tiers, 22 % far, 14 % double) is untouched; only the clock runs
    /// faster or slower. The blink keyframes stay 300 ms at every setting.
    private func nextBlinkGap() -> Double {
        let far = Double.random(in: 0 ..< 1) < Self.blinkGapFarChance
        let base = Double.random(in: far ? Self.blinkGapFar : Self.blinkGapNear)
        return base * blinkSpeed.gapMultiplier
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

    /// The shake "dizzy": the whole pair of eyes **spins twice** around its own center, then settles back in place.
    ///
    /// ★★ Added in revision fourteen (user: "change the watch's shake so a shake makes the eyes spin in circles with a dizzy feel
    /// and adds interaction"). The shake's feedback used to be a single vibration -- felt by the body,
    /// with the eyes taking no part. Now the eyes "go dizzy" along with it, and only then does the shake register on **this face**.
    ///
    /// ## How the rhythm was set
    /// * **720° in 0.9 seconds** (two turns). One turn is so fast it looks like fanning the air, and three or more on a 40mm
    ///   little screen blur into a single smudge. 0.9 seconds is also exactly the window for
    ///   the "two impacts within a 0.9-second window" test in `WatchShakeDetector` -- the eyes finish spinning just as the test lands.
    /// * **`timingCurve(0.3, 0, 0.4, 1)`**: slow start → fastest in the middle → easing off at the end.
    ///   Only "spinning faster and faster and then stopping" feels "dizzy"; two turns at a constant speed is an electric fan, not dizziness.
    /// * **Afterwards the angle must be reset to zero, and without animation**: parked there at 720°,
    ///   the next spin would have to start from 720°; and animating the reset to zero makes the eyes, after stopping,
    ///   spin two turns backwards again -- that is a "rewind," not "finished being dizzy."
    ///
    /// ⚠️ **It only means anything while the eyes are visible**. After a shake trigger the home screen does not actually
    ///    start or stop recording for about 0.45 seconds (see `WatchRecorderView.syncShakeDetector`), so when recording starts
    ///    the first half of the dizzy is visible; when recording stops the eyes return after 0.45 seconds,
    ///    picking up exactly the second half. Both paths get their moment; the spin is not wasted.
    private func playDizzy() {
        dizzyTask?.cancel()
        guard !dimmed else { return }
        dizzyTask = Task {
            withAnimation(.timingCurve(0.3, 0.0, 0.4, 1.0, duration: 0.9)) {
                dizzyAngle = 720
            }
            try? await Task.sleep(nanoseconds: 950_000_000)
            guard !Task.isCancelled else { return }
            var settle = Transaction()
            settle.disablesAnimations = true
            withTransaction(settle) { dizzyAngle = 0 }
        }
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
        // ★ Revision thirteen: the pool = **the expression library minus the persistent tier** (`BotFaceStyle.tapPool`).
        //
        // ⚠️ Revision twelve's list was a hard-coded five tiers; now the library is nine tiers and the user can choose which one is persistent,
        //    so a hard-coded list would immediately go wrong: the user picks `shy` as persistent, but the pool still
        //    has only those five tiers -- so `shy` can never be played, while "drawing the same tier as the persistent one"
        //    (which looks like nothing happened) becomes possible instead. Computing it from the library avoids both problems.
        let pool = BotFaceStyle.tapPool(excluding: style)
        guard let next = pool.randomElement() else { return }
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
                WatchVoiceWave(meter: meter, size: size, tint: tint)

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
    ///
    /// ★★ Revision thirteen: the whole **drawing method** for the eyes moved into `BotFacePair` (the shared file).
    ///    Only two things "only this face knows" are left here: rise it a little (`eyeRise`),
    ///    and translate it toward the gaze (`gaze`).
    ///    ⚠️ The drawing method had to move -- the picker on the iPhone has to lay out the preview with the same code.
    ///      Written separately, "the smiling eye chosen on the phone" and "the smiling eye drawn on the watch" would eventually differ.
    /// Which tier the idle eyes are wearing right now: a tap's one-shot first, then the
    /// auto-express cycle's current pick, then the tier the phone pinned (★ 2026-10-20).
    private var shownStyle: BotFaceStyle { mood ?? cycleStyle ?? style }

    private var eyes: some View {
        BotFacePair(
            // The tier played by a tap takes priority; if there is none, fall back to the user's chosen persistent tier.
            style: shownStyle,
            size: size,
            tint: tint,
            openness: openness
        )
            // ★ Revision fourteen: the shake "dizzy." The whole pair of eyes spins twice around its own center.
            .rotationEffect(.degrees(dizzyAngle), anchor: .center)
        // As a group the eyes sit a little above the geometric center. Exactly centered looks "head down" --
        // the eyes on a human face sit above the midline anyway.
        .offset(y: BotFaceMetrics.eyeRise(size))
        // Gaze. Stacked on top of the "rise" on the line above (the two `offset`s are added).
        .offset(x: gaze.width, y: gaze.height)
    }

    /// The eyes for the idle state, and for the expressions that "do not change shape": a round-tipped vertical bar.
    ///
    /// ⚠️ Revision thirteen: this pair of methods (`eyeShape` / `eyeArc`) **moved entirely to
    ///    `BotFaceEye`** (the shared file `Sources/Services/Watch/BotFaceStyle.swift`),
    ///    along with the decision to "cross-fade via `opacity` rather than pick one with `if/else`."
    ///    For the reason for the move see the `eyes` paragraph -- the picker on the iPhone has to lay out the preview with the same code.

    // MARK: - Hold: eyes merge → spread across the screen

    /// ★★ 2026-10-16 revision sixteen (user's words:
    ///   "what I want is for the two eyes, based on where I press down, to automatically merge together at the place I press,
    ///    and then slowly spread across the whole screen and jump over to the recording side").
    ///
    /// ## Both versions were rejected; what this one wants is "an origin"
    /// * Revision fourteen: a solid circle growing out of the eyes' circumscribed circle → the user read it as "the two eyes spreading";
    /// * Revision fifteen: a full-screen solid color faded in via opacity → clean, but with **no origin** --
    ///   the color rose out of thin air across the whole screen, with nothing to do with those two eyes.
    /// This time the user spelled out the order: **merge first, then spread**. So this version is two pieces of geometry,
    /// the first piece starring the two eyes, and only the second the full screen.
    ///
    /// ## Two segments (`holdProgress` 0 → 1)
    /// | Segment | Share | What it is doing |
    /// |---|---|---|
    /// | Merge | first **32%** | Each eye slides toward **the point the finger pressed**, growing from a "vertical bar" into a "circle," and they finally overlap into one blob at the press point |
    /// | Spread | last **68%** | That blob grows round from the press point until it covers the whole screen |
    ///
    /// * The merge segment's end size is a **circle of `0.47 × size`**: that number was not pulled out of a hat --
    ///   the two eyes' area is `2 × 0.235 × 0.375 ≈ 0.176 size²`, and a circle of diameter `d`
    ///   has area `0.785 d²`; setting the two equal gives `d ≈ 0.47`. That is, **after merging the blob
    ///   is the same size as before merging**, which reads as "combining," not "shrinking" or "swelling."
    /// * Both segments pass through `smoothstep` (`3x² − 2x³`): linear interpolation has a
    ///   corner at both the start and the end, and the eyes feel like they are yanked. Smoothed, it is "light start, fast middle, light finish."
    /// * The spread segment's end radius is **`2.0 × size`**: the press point can at most be at the corner of the face's square
    ///   (`0.57√2 ≈ 0.81 size` from the face center), the farthest screen corner is about `1.06 size` from the face center,
    ///   so from the press point to the farthest corner is at most `1.87 size`. 2.0 leaves a little margin.
    ///
    /// ## Why draw it by hand with `Canvas` rather than `Rectangle` + two `Capsule`s
    /// The merge segment needs the eyes to **grow round while moving**, whereas `BotFaceEye` draws a capsule
    ///   (fixed aspect ratio, and carrying `BotFaceStyle`'s `arc` branch). To deform that shape
    ///   continuously into a circle in SwiftUI, the geometry in `BotFaceStyle` would have to be rewritten -- and
    ///   that is exactly the piece shared by both sides that must never fork. Drawing a **rounded rectangle** in `Canvas`
    ///   leaves it untouched: when width = height the rounded rectangle **is** a circle, and the deformation is two parameters of the same `Path`
    ///   being interpolated, with no second set of geometry.
    ///
    /// ## Three things that are mandatory
    /// * `allowsHitTesting(false)` -- it covers the whole screen, and if it were tappable this page would be unusable.
    /// * Canvas `4.2 × size`: `Canvas` **draws only within its own bounds**, so it has to be much
    ///   larger than the screen (a 500pt square on 40mm, where the screen is only 162×194).
    ///   The ring of the circle that gets clipped falls outside the screen and is invisible.
    /// * The fade-out is left to `sweepFading`, **leaving `holdProgress` alone** -- geometry and exit are two separate things,
    ///   and mixed into one state, "fill first, then exit" cannot be written.
    @ViewBuilder
    private var holdLayer: some View {
        if holdProgress > 0.002 {
            Canvas { context, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

                // The press point is converted from "the face's local coordinates" to "canvas coordinates": the two views are concentric
                //   (both centered in the same ZStack), so they differ by a single translation.
                let faceSide = size * 1.14
                let press = pressPoint ?? CGPoint(x: faceSide / 2, y: faceSide / 2)
                let target = CGPoint(
                    x: center.x + (press.x - faceSide / 2),
                    y: center.y + (press.y - faceSide / 2)
                )

                let merge = Self.smoothstep(min(1, holdProgress / Self.mergeShare))
                let spread = Self.smoothstep(
                    max(0, (holdProgress - Self.mergeShare) / (1 - Self.mergeShare))
                )

                // Start: **matched item by item** with the two idle eyes (the same `BotFaceMetrics`,
                //   the same `style` deformation). Off by even a little and the eyes visibly jump on the first frame of the press.
                let geo = style.geometry
                let restW = BotFaceMetrics.eyeWidth(size) * geo.scaleX
                let restH = BotFaceMetrics.eyeHeight(size) * geo.scaleY
                let restGap = (BotFaceMetrics.eyeWidth(size) + BotFaceMetrics.eyeGap(size)) / 2
                let restY = BotFaceMetrics.eyeRise(size)
                let blobD = size * 0.47

                for side in [CGFloat(-1), 1] {
                    let rest = CGPoint(x: center.x + side * restGap, y: center.y + restY)
                    let eye = CGPoint(
                        x: rest.x + (target.x - rest.x) * merge,
                        y: rest.y + (target.y - rest.y) * merge
                    )
                    let w = restW + (blobD - restW) * merge
                    let h = restH + (blobD - restH) * merge
                    let rect = CGRect(x: eye.x - w / 2, y: eye.y - h / 2, width: w, height: h)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: min(w, h) / 2),
                        with: .color(tint)
                    )
                }

                if spread > 0 {
                    let from = blobD / 2
                    let r = from + (size * 2.0 - from) * spread
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: target.x - r, y: target.y - r, width: r * 2, height: r * 2
                        )),
                        with: .color(tint)
                    )
                }
            }
            .frame(width: size * 4.2, height: size * 4.2)
            // A little blur. Merging and spreading are both "liquid" affairs; hard edges read as "two geometric shapes
            //   stacked on top of each other." The radius follows `size`, about 5pt on 40mm.
            .blur(radius: size * 0.045)
            .opacity(sweepFading ? 0 : 1)
            .animation(.easeOut(duration: 0.5), value: sweepFading)
            .allowsHitTesting(false)
        }
    }

    /// The share of `holdProgress` the merge segment takes. The rest all goes to the spread segment.
    ///
    /// ⚠️ 0.32 is a measured ratio: merging too fast (<0.2) looks like "the eyes flashed once and vanished,"
    ///    and too slow (>0.45) leaves the spread only half the time, so it grows hurriedly -- what the user wants is
    ///    "spreading **slowly** across the whole screen."
    private static let mergeShare: CGFloat = 0.32

    /// Smooth interpolation: `3x² − 2x³`. The derivative is 0 at both ends, so the eyes neither start nor finish by "being yanked."
    private static func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// How much `figure`'s two eyes yield while the finger is down.
    ///
    /// ⚠️ **This handoff is mandatory**: `holdLayer` is the upper layer in the ZStack, and from the first frame of the press
    ///    it is already drawing two eyes (using the same geometry). If `figure` is not dismissed, you get two pairs of eyes
    ///    overlapping -- invisible on the base tier (a plain capsule), but with the `arc` tiers in `BotFaceStyle`
    ///    (`happy` / `sad`) it shows: an arc underneath and a straight bar on top.
    ///    0.06 of progress ≈ 0.12 seconds, too fast to tell this is a "hand-off."
    private var figureOpacity: Double {
        guard holdProgress > 0.002 else { return 1 }
        return Double(max(0, 1 - holdProgress / 0.06))
    }
}

// MARK: - Expressions (★ 2026-10-16 added in revision twelve, moved away in revision thirteen)
//
// Revision twelve's five expressions (`EyeMood`) and the shape of that arc (`EyeCurve`) both **moved to the shared file**
// `Sources/Services/Watch/BotFaceStyle.swift`, and are now called `BotFaceStyle`
// and `BotFaceEyeCurve`, expanded from five tiers to nine.
//
// ⚠️ The reason for the move is not tidying up, it is **necessary**: a new expression picker was added to the iPhone settings,
//    and it has to lay out a preview; the preview and real hardware must be **the same code**. Written separately, the user would see
//    a smiling eye on the phone and, raising their wrist, find a drooping eye -- and that kind of drift is the hardest to spot.
//    Where the assets come from, why only nine could be brought over, and the three rules kept when choosing, are all written in that file.

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
