import SwiftUI

// MARK: - The waveform while recording
//
// ★ 2026-10-16 revision 9 (user's words: "when recording starts, it should be a single waveform like a heart rate").
//
// The recording look used to be "eyes one size bigger + floating left/right with an offset phase". After seeing it on real hardware, what the user wanted was
// **a single waveform**, and one that **moves the way a heart rate does** — the way the Apple Watch heart-rate app does it:
// the baseline runs flat, then bumps, one beat at a time.
//
// ─────────────────────────────────────────────────────────────────────────
// ## Why it's both a "waveform" and a "heart rate" — here the two are the same curve
//
//   · **Spike height = the mic's live level**. That's the "waveform" half: talk and it shoots up,
//     the louder you are, the higher it goes. So "talking at the watch" gets a direct visual answer —
//     every word you say makes it jump.
//   · **The little bumps when it's quiet** (`beat`) are the "heart rate" half: they make sure that **even with no sound you can tell
//     it's working**, rather than a flat line that looks broken.
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision 11 (user's words:
//    "when recording, the rises and falls should overall follow the personal real-time heart rate the watch picks up"):
//
// **That "heart rate" is no longer a generic value, but your own heart rate.**
//
// The re-9/re-10 table was "ten slots = 0.8 seconds ≈ 75 bpm" — an average adult's resting heart rate,
// but **not this person's rate right now**. Now we take the watch-measured
// `bpm` from `WatchHeartRateMonitor` and use it to decide how fast the table runs: each tick advances `bpm / 75` slots.
//
// ⚠️ So on this table **a slot is no longer a fixed beat**; it's just a "shape template".
//    At 60bpm the whole wave is slower, at 150bpm faster — but the **proportions** of "boom-tick" are always the same.
//    This split is deliberate: shape stays shape (this table), speed stays speed (the measured heart rate).
//
// ⚠️ When the heart rate can't be read (no permission / no reading on the watch) it falls back to `restingBPM = 75` —
//    that is, **it degrades to the re-10 behaviour**. So the worst case here is only "same as before",
//    never "can't read it, so nothing gets drawn".
//
// ℹ️ To get the heart rate to truly "per-second", the only route is starting an `HKWorkoutSession`; for the cost see
//    the block at the top of `WatchHeartRateMonitor` (it spells out why we didn't take that route).
//
// ⚠️ The level is **real** (`AVAudioRecorder.isMeteringEnabled`), not a decorative animation.
//    It's worth being strict here: a purely random fake waveform keeps bouncing merrily even when the mic picks up no sound at all,
//    and the user watches this wave precisely to confirm **it's recording**. For that purpose a fake waveform is a liability.
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision 12 (user: "when recording, the heart-rate rises and falls need a bigger amplitude and a bigger share of the screen"):
//
// What changed is **two dimensions**, not two sets of logic:
//
// | | revision 11 | revision 12 | actual size on 40mm |
// |---|---|---|---|
// | canvas width | `0.86 × size` | **`1.06 × size`** | 102pt → 126pt (screen width 162pt) |
// | canvas height | `0.30 × size` | **`0.44 × size`** | 36pt → 52pt |
// | heartbeat main peak | `0.34` | **`0.52`** | about 5pt → about 12pt (relative to the centre line) |
// | line width | `0.024 × size` | **`0.028 × size`** | 2.9pt → 3.3pt |
//
// ⚠️ The re-11/re-9 amplitude **existed only on paper**: a 0.34 peak × a 15pt reach ≈ 5pt,
//    which on a 36pt-tall canvas looks like a thin line that barely moves. When the user said it
//    "looks broken" two rounds running, that's what they meant — the heartbeat base shape was too weak to read a rhythm from.
//
// ⚠️ But the line "don't hit full scale" **must not be crossed**: full height is reserved for the real level (see the block above).
//    Revision 12 is "lift the invisible up to visible", not "lift the base shape into the main event"; telling the two apart
//    now relies on **shape** (a heartbeat's isolated 1~2-slot spike vs speech's 5~15-slot plateau),
//    so the height can go up a bit without sacrificing that discipline.
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision 13 (user's words: "and after the watch starts recording, the recording's up-and-down should be more
//    obvious; right now the up-and-down isn't enough and doesn't take up the watch's share of the screen"):
//
// This round changes **a structural problem**, not one more bump of the numbers.
//
// ## Where the problem is: the baseline is on the centre line, but values are only drawn upward
//
// The re-12 table more than doubled the amplitude (0.34 → 0.52), and the user still said "not enough". The reason isn't the number,
// it's **geometry**: the baseline is drawn at the canvas's **centre line** (`mid = height / 2`), while the curve only grows **upward**
// (`y = mid − clamped × reach`). So the "up-and-down" **has no second half at all** —
// that half of the canvas is always empty, and the vertical space any level can actually use is only **half** the canvas.
// Adding more to the numbers won't help either: at best it fills that half.
//
// ## The fix: drop the baseline to the bottom of the canvas
//
// | | revision 12 | revision 13 | actual height on 40mm |
// |---|---|---|---|
// | baseline | centre line `height/2` | **bottom** (leaving half a line width) | 0pt → about 55pt of usable travel |
// | canvas height | `0.44 × size` | **`0.68 × size`** | 52pt → 81pt |
// | canvas width | `1.06 × size` | **`1.10 × size`** | 126pt → 131pt (screen width 162pt) |
// | heartbeat main peak | `0.52` × half the canvas | `0.52` × **the whole canvas** | about 12pt → about 42pt |
//
// ⇒ The same level, the same `beat` table, now travels **about three and a half times** as far. This is the
//   "obvious" and "share of the screen" the user wanted.
//
// ⚠️ **Not one slot of the `beat` table changed.** The table describes "shape" (the relative heights of the boom-tick two beats),
//    and once the canvas is taller the same shape automatically grows taller and bigger — which also confirms the re-12 judgement:
//    for bigger, what should change is the **canvas**, not the table (the re-12 comment says exactly that; back then I
//    only did half of it: raised the canvas but left the baseline on the centre line).
//
// ## Two other things that came along
//
//   · **Centre line → bottom line**. The faint axis moves to the baseline too. Its job is unchanged ("no sound"
//     and "this thing is broken" must be distinguishable), but its position changes from "dead centre" to "bottom edge".
//   · **A very faint fill below the curve**. Revision 12 had only a line, so when quiet, on an 81pt-tall
//     canvas it was a thin line hugging the bottom, and its "share of the screen" was still tiny. Add this fill and
//     the **area** follows the level — loud makes the whole block open up and you can see at a glance that "it's eating sound".
//     This is the cheapest step toward "looks bigger" that does least damage to the semantics (the fill height still
//     equals the real level exactly, with no fake data introduced).
//
// ⚠️ The re-12 discipline "don't push the base shape to full scale" **still holds**: full height is reserved for the real level,
//    and now it's **shape** that tells them apart (a heartbeat is an isolated 1~2-slot spike, speech a continuous 5~15-slot plateau).
// ─────────────────────────────────────────────────────────────────────────
// ## Why keep a short history instead of drawing only the instantaneous value
// A heart-rate-style trace is "a line that scrolls left over time", not a bar jumping up and down. So you need a little
// history (`sampleCount` slots), appending one slot at the right on each tick and shifting the whole thing left.
// The sample rate follows the model's 12.5Hz clock ⇒ about 2.7 seconds per screen.
//
// ## Why "the heartbeat" uses a fixed table instead of a computed sine/Gaussian
// At first I wanted to compute a Gaussian spike over time, but the sampling is one slot per 12.5Hz (80ms), while a spike lasts only
// a few dozen milliseconds — **most likely a whole slot falls outside the spike**, so the same spike sometimes reads full height, sometimes
// almost zero, looking like a bad connection.
// Switching to a **fixed table laid out by slot count** (`beat`) removes the problem entirely: each slot's height is
// a constant, the rhythm is steady, and the "boom-tick" two-beat shape (`lub-dub`) comes along for free —
// that's what a heart sound's rhythm is, and a symmetric sine can't do it.
struct WatchVoiceWave: View {
    /// The current level. Only `level` is used (for height); `tick` drives the advance —
    /// see the block at the top of `WatchAudioMeter` (when quiet `level` doesn't change, and that's how we know to keep moving).
    let meter: WatchAudioMeter
    /// The nominal side length of this face, sharing one set of proportions with the eyes.
    let size: CGFloat
    /// The wave's colour. It follows the colour chosen on the "Appearance" page (the same source as the eyes).
    let tint: Color
    /// The watch-measured heart rate (bpm). `nil` = not read yet, fall back to `restingBPM`.
    ///
    /// ★ 2026-10-16 revision eleven (user: "the rises and falls should overall follow your personal real-time heart rate as the watch reads it").
    /// It does exactly one job: **setting the period of the heartbeat base shape**. The spike height is still the mic's
    /// real level, and the two don't interfere — see the block at the top of the file.
    let bpm: Double?

    /// The level history inside the scrolling window, with the newest slot on the right.
    @State private var samples: [CGFloat]

    /// How far the heartbeat base shape has travelled. **A fraction**, not an integer index.
    ///
    /// ⚠️ This is the key that makes "follows the heart rate" work. It used to advance **a whole slot** per tick,
    ///    which pinned the period at 10 slots × 80ms = 0.8 seconds = 75 bpm.
    ///    Now each tick advances `bpm / 75` slots — a heart rate of 60 advances 0.8 slots (slower),
    ///    150 advances 2 slots (faster). Whole-slot stepping can't do this, because the advance has to be continuous.
    @State private var beatPhase: Double = 0

    /// How many slots fit on one screen. 34 slots ÷ 12.5Hz ≈ 2.7 seconds.
    ///
    /// ⚠️ Too many and the sense of "scrolling" disappears (tens of seconds crammed into one screen barely looks like it's moving),
    ///    too few and it looks noisy. 34 is the setting where "you can see the rises and falls at a glance, and it really is moving left".
    private static let sampleCount = 34

    /// The resting value used when the heart rate can't be read.
    ///
    /// 75 bpm is the average adult's resting range, and also the tempo the re-10 table **originally** hard-coded
    /// — in other words, when the heart rate can't be read this degrades to exactly the re-10 behaviour, no worse.
    private static let restingBPM: Double = 75

    /// The heartbeat template for when it's quiet. **One slot = one 12.5Hz beat = 80ms**, and ten slots at
    /// `restingBPM` (75) come to exactly 0.8 seconds — so this table is naturally the "75 bpm" shape.
    /// Change the heart rate, not the table — what changes is **how fast it runs** (`beatPhase`).
    ///
    /// The shape is **boom-tick**: slot 2 is a tall peak (ventricular contraction), slot 7 a shorter
    /// second sound, and the rest a baseline near 0. This looks far more like a heart rate than "every slot the same height".
    ///
    /// ★ Revision 12: the peak goes **0.34 → 0.52**, the second sound **0.15 → 0.26**
    /// (user: "when recording, the heart-rate rises and falls need a bigger amplitude").
    /// Together with the canvas height going 0.30 → 0.44, that beat's **absolute height** goes from about 5pt to about 12pt
    /// (on 40mm) — the original amplitude was in practice almost invisible to the eye, existing only on paper.
    ///
    /// ⚠️ Why it **still** doesn't hit full scale: full height is reserved for the real level. This wave's only purpose
    ///    is to "tell 'it's beating' from 'the mic really picked up sound'", and once the base shape hits full scale those two
    ///    are down to a single criterion. Now it's **shape** rather than height alone that tells them apart —
    ///    a heartbeat is an isolated **1~2-slot** spike (narrow), speech is a continuous **5~15-slot** plateau (wide),
    ///    and even at similar heights they're obvious at a glance.
    ///    ⇒ If you want "bigger" again later, first ask whether it's the canvas height that should change, not this table.
    private static let beat: [CGFloat] = [
        0.08, 0.52, 0.24, 0.09, 0.06,
        0.06, 0.26, 0.11, 0.06, 0.05,
    ]

    init(meter: WatchAudioMeter, size: CGFloat, tint: Color, bpm: Double?) {
        self.meter = meter
        self.size = size
        self.tint = tint
        self.bpm = bpm
        _samples = State(initialValue: Array(repeating: 0, count: Self.sampleCount))
    }

    var body: some View {
        Canvas { context, canvasSize in
            let lineWidth = Self.lineWidth(for: size)

            // ★★ Revision 13: the baseline moves from the **centre line** to the **bottom of the canvas**.
            //
            // ⚠️ This is the only real change this round, and it's where "not enough rise and fall" came from:
            //    a baseline on the centre line + values drawn upward only ⇒ the lower half of the canvas is always empty,
            //    and the usable vertical travel is only half the canvas. Turning `beat` up just fills that half.
            //
            // 0.75 of a line width is left for the round pen cap: without it, the bottom-hugging line would be
            // half-clipped by its own end cap (the round cap is a semicircle drawn with the line width as its diameter).
            let baseline = canvasSize.height - lineWidth * 0.75
            // Same deduction at both ends, so a full-scale spike isn't flattened by the round cap.
            let reach = max(1, canvasSize.height - lineWidth * 1.5)

            // A very faint baseline. It isn't decoration — with it, "there's no sound right now" and
            // "this thing is broken and stuck" can be told apart (the former is a flat line hugging the baseline,
            // the latter is a blank).
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: baseline))
            axis.addLine(to: CGPoint(x: canvasSize.width, y: baseline))
            context.stroke(
                axis,
                with: .color(tint.opacity(0.16)),
                style: StrokeStyle(lineWidth: max(1, lineWidth * 0.4), lineCap: .round)
            )

            guard samples.count > 1 else { return }

            var path = Path()
            for (index, value) in samples.enumerated() {
                let x = canvasSize.width * CGFloat(index) / CGFloat(samples.count - 1)
                // Clamp the value to 0...1 first: the level is theoretically in that range, but after taking
                // `max` of `beat` and the level, clamp once more, so no single miscalculation turns into a line drawn outside the canvas.
                let clamped = min(1, max(0, value))
                let y = baseline - clamped * reach
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            // ★ Revision 13: add a very faint fill below the curve.
            //
            // ⚠️ Its height **equals the real level exactly** (the curve above), introducing no
            //    fake data — the only difference is "it's a surface, not a line". With only a line in re-12,
            //    the quiet-state wave on an 81pt-tall canvas was a thin line hugging the bottom, and its "share of the screen"
            //    was still tiny; with this layer, loud makes the whole block open up and you can see at a glance that it's eating sound.
            // ⚠️ Hand-write a closed path, rather than assembling one
            //    `Path` from two `path.addLine(baseline)` calls — `Shape`/`Path`'s `fill` will automatically
            //    connect an **unclosed** path back to its start, and that "closing edge" is easily drawn crooked on a multi-segment path.
            var area = Path()
            area.move(to: CGPoint(x: 0, y: baseline))
            for (index, value) in samples.enumerated() {
                let x = canvasSize.width * CGFloat(index) / CGFloat(samples.count - 1)
                let clamped = min(1, max(0, value))
                area.addLine(to: CGPoint(x: x, y: baseline - clamped * reach))
            }
            area.addLine(to: CGPoint(x: canvasSize.width, y: baseline))
            area.closeSubpath()
            context.fill(area, with: .color(tint.opacity(0.20)))

            context.stroke(
                path,
                with: .color(tint),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
        // ★★ Revision 13: `1.06 × 0.44` → **`1.10 × 0.68`**.
        //
        // ⚠️ The width cap is still set hard by the `WatchBotFace` frame, not by the screen:
        //    that face's frame is `size × 1.14` and the wave is drawn inside it. 1.10 leaves only about 3.5% of
        //    headroom (about 2pt per side on 40mm), **this one is maxed out** — any wider and it pushes past the face
        //    frame, and then, even if the screen hasn't clipped it, the wave no longer "belongs to this face".
        //    Want it wider still? What should change is `WatchRecorderView.botFraction` (the whole face's share),
        //    not this one number.
        //    Height has no such constraint (the face frame is also 1.14×size tall, and 0.68 + the elapsed-time allowance is just right),
        //    so the "go bigger" step favours height — and once the baseline is at the bottom, height is **all**
        //    the usable travel, with none of it wasted on an empty half-canvas.
        .frame(width: size * 1.10, height: size * 0.68)
        // The glow for the recording state. It used to hang on the eyes and moved over once the eyes were replaced by this wave —
        // on the watch face there's nowhere else to say "it's working".
        .shadow(color: tint.opacity(0.55), radius: 7)
        .onChange(of: meter) { _, new in advance(using: new) }
        .accessibilityHidden(true)
    }

    /// Advance one slot. **Driven by `tick`**, not by `level` — see the `WatchAudioMeter` block.
    ///
    /// ★ Revision 11: the heartbeat base shape is no longer fixed at 75; it now follows the measured heart rate.
    private func advance(using meter: WatchAudioMeter) {
        let pulse = nextBeatSample()
        var next = samples
        next.append(max(CGFloat(meter.level), pulse))
        if next.count > Self.sampleCount {
            next.removeFirst(next.count - Self.sampleCount)
        }
        samples = next
    }

    /// Push the heartbeat base shape forward one slot and return that slot's height.
    ///
    /// ## Where the advance amount comes from
    /// This table's ten slots come to exactly 0.8 seconds at 75bpm. So "each tick advances `bpm / 75` slots"
    /// is equivalent to "one full heartbeat = `10 / (bpm/75)` slots = `0.8 × 75 / bpm` seconds = `60/bpm` seconds"
    /// — that is, **sixty seconds divided by the heart rate**, which is precisely the definition of heart rate. So the formula isn't fudged.
    ///
    /// ## ⚠️ Why interpolate between slots instead of rounding
    /// At a heart rate of 72 each tick advances 0.96 slots — rounding would turn that into "sometimes 1 slot, sometimes 0",
    /// and the wave's speed would stutter, like dropped frames. Interpolation keeps the advance continuous, so your eyes see only
    /// the tempo smoothly speed up or slow down.
    private func nextBeatSample() -> CGFloat {
        let rate = (bpm ?? Self.restingBPM) / Self.restingBPM
        beatPhase += rate
        let span = Double(Self.beat.count)
        beatPhase = beatPhase.truncatingRemainder(dividingBy: span)

        let lower = Int(beatPhase)
        let fraction = CGFloat(beatPhase - Double(lower))
        let a = Self.beat[lower % Self.beat.count]
        let b = Self.beat[(lower + 1) % Self.beat.count]
        return a + (b - a) * fraction
    }

    /// The line width is derived from `size`, not hard-coded — 40mm to 49mm differ by 40pt, and a hard-coded value would be wrong on one of them.
    ///
    /// ★ Revision 12: 0.024 → **0.028** (2.9pt → 3.3pt on 40mm). Once the canvas is enlarged the same
    /// line width looks thinner on screen, so it goes up a notch to keep that bit of "brushstroke" feel.
    private static func lineWidth(for size: CGFloat) -> CGFloat {
        max(2, size * 0.028)
    }
}
