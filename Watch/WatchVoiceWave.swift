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
// ⚠️ The second item above was **deleted entirely in revision 15** — see the "revision 15" block at the end of this file.
//    This block is kept because it explains why this wave once wore both a waveform face and a heart-rate face.
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
// ⚠️ **The judgement above is wrong after revision 14**, and it's exactly the bug revision 15 fixes —
//    revision 14 added a `bpm != nil` gate on `onChange(of: meter)`,
//    so "can't read it" no longer degrades to the old behaviour, but **freezes the whole thing**.
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
// ⚠️ But the line "don't hit full scale" **must not be crossed**: full height is reserved for the real level (see the block above).
//    ⚠️ This discipline **vanishes on its own** after revision 15 — the base shape is gone, so full scale belongs only to the real level.
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
// ⇒ The same level, the same `beat` table, now travels **about three and a half times** as far.
//
// ## Two other things that came along
//
//   · **Centre line → bottom line**. The faint axis moves to the baseline too.
//   · **A very faint fill below the curve**: the **area** follows the level — loud makes the whole block open up,
//     and you can see at a glance that "it's eating sound". The fill height still equals the real level exactly, with no fake data introduced.
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision 14 (user's words: "when the watch isn't being worn there's no up-and-down
//    ripple during recording; you have to be wearing the watch"):
//
// **From now on this wave only moves when it's "worn".**
//
// ## Why "is there a heart-rate reading" is the criterion for "worn or not"
// The watch records on the wrist, so physically there are only two ways "not wearing the watch" can happen: take it off and set it aside,
// or leave it on the charger. In both cases HealthKit **gives no heart-rate reading** —
// `bpm` is `nil`. Conversely, as long as the wrist is in the band, the optical heart rate gives a number within seconds.
// So "is `bpm` `nil`" is the **only** reliable signal for "worn or not".
//
// ## What gets drawn when it isn't worn
// **A flat line hugging the baseline**, with nothing moving. The mic level stops too.
//
// ⚠️ The criterion above **is wrong on real hardware**; the user overturned it with one line, see below.
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision fifteen (user's words:
//    "when recording, the waveform's rise and fall should still go by the surrounding sound's recording decibels, don't drive it off the heart rate,
//     because it's inaccurate right now and it's just a straight white line"):
//
// ## Symptom and root cause
//
// What the user sees is **a straight white line hugging the bottom**. The root cause isn't that the level isn't coming in, it's the gate
// revision 14 added: in `.onChange(of: meter)`, `guard bpm != nil else { return }` —
// **if the heart rate can't be read, not one slot advances**.
//
// And "the heart rate can't be read" is the **norm** in this chain, not an exception:
//   · At rest an Apple Watch may take a dozen minutes to drop a single sample into HealthKit
//     (which is why `WatchHeartRateMonitor.maxSampleAge` was relaxed to 900 seconds);
//   · With no health permission granted, it's **never** read.
// In both cases `bpm` is `nil`, so that gate swapped the one problem of "the heartbeat base shape is weak"
// for the far more serious "the whole wave dies" — and that's exactly the worry revision 14's
// own comment wrote down ("can't read it, so nothing gets drawn").
//
// ## The fix: this wave has **one** input left — the mic level
//
//   · Delete the `bpm` parameter, the `beat` heartbeat base table, `restingBPM`, `beatPhase`,
//     `nextBeatSample()` (the whole heart-rate-varying advance machinery);
//   · `advance(using:)` writes `meter.level` directly, no longer taking `max` with the base shape;
//   · Revision 14's "unworn means nothing moves" gate is deleted entirely.
//
// ⇒ From now on this wave **equals exactly "how loud the mic heard this instant"**: talk and it shoots up,
//   quiet and it returns to the baseline. This is exactly what the user wanted since revision 9 (the re-9 comment
//   literally says "spike height = the mic's live level"); back then it was buried by the heartbeat base shape.
//
// ## Three things that came along to become obsolete / degrade (all deliberate, not oversights)
//
//   · **The re-12 discipline "don't push the base shape to full scale" is void**: the base shape is gone, so full scale
//     belongs only to the real level, and there's no "can't tell a heartbeat from speech" problem.
//   · **The ability to "tell it's working even when quiet" is gone**. The cost must be spelled out:
//     when the mic picks up no sound at all, this wave is **a flat line hugging the bottom** — identical to "broken".
//     Two things other than **shape** now cover this: the faint baseline axis (`tint.opacity(0.16)`,
//     it proves "the canvas is there"), and the **recording timer** right below the wave (`elapsedText`, its running
//     proves it's recording). The timer is the harder of the two pieces of evidence.
//   · **Revision 14's "no watch on the wrist, no wave" degrades to "quiet means flat"**. This isn't an implementation regression, it's that the
//     criterion was overturned by the user ("don't drive it off the heart rate"): since the heart rate isn't trustworthy, "worn or not"
//     has no signal left — take the watch off and record on the desk and the mic still picks up ambient sound.
//     To really tell "worn or not" apart again, you'd need another criterion (not the heart rate).
//
// ℹ️ The heart-rate chain (`WatchHeartRateMonitor` / `WatchRecorderModel.heartRate`)
//    is **no longer called from anywhere** as of this round. The files are kept; for the reason see
//    the block at the top of `WatchHeartRate.swift` — this is not a deletion.
// ─────────────────────────────────────────────────────────────────────────
// ## Why keep a short history instead of drawing only the instantaneous value
// A waveform is "a line that scrolls left over time", not a bar jumping up and down. So you need a little
// history (`sampleCount` slots), appending one slot at the right on each tick and shifting the whole thing left.
// The sample rate follows the model's 12.5Hz clock ⇒ about 2.7 seconds per screen.
struct WatchVoiceWave: View {
    /// The current level. `level` decides how tall this slot is; `tick` drives the advance —
    /// see the block at the top of `WatchAudioMeter` (when quiet `level` is constantly 0,
    /// `onChange(of: level)` never fires once, and `tick` is how we know to move).
    let meter: WatchAudioMeter
    /// The nominal side length of this face, sharing one set of proportions with the eyes.
    let size: CGFloat
    /// The wave's colour. It follows the colour chosen on the "Appearance" page (the same source as the eyes).
    let tint: Color

    /// The level history inside the scrolling window, with the newest slot on the right.
    @State private var samples: [CGFloat]

    /// How many slots fit on one screen. 34 slots ÷ 12.5Hz ≈ 2.7 seconds.
    ///
    /// ⚠️ Too many and the sense of "scrolling" disappears (tens of seconds crammed into one screen barely looks like it's moving),
    ///    too few and it looks noisy. 34 is the setting where "you can see the rises and falls at a glance, and it really is moving left".
    private static let sampleCount = 34

    init(meter: WatchAudioMeter, size: CGFloat, tint: Color) {
        self.meter = meter
        self.size = size
        self.tint = tint
        _samples = State(initialValue: Array(repeating: 0, count: Self.sampleCount))
    }

    var body: some View {
        Canvas { context, canvasSize in
            let lineWidth = Self.lineWidth(for: size)

            // ★★ Revision 13: the baseline moves from the **centre line** to the **bottom of the canvas**.
            //
            // ⚠️ This is where "not enough rise and fall" came from: a baseline on the centre line + values drawn upward only ⇒
            //    the lower half of the canvas is always empty, and the usable vertical travel is only half the canvas.
            //
            // 0.75 of a line width is left for the round pen cap: without it, the bottom-hugging line would be
            // half-clipped by its own end cap (the round cap is a semicircle drawn with the line width as its diameter).
            let baseline = canvasSize.height - lineWidth * 0.75
            // Same deduction at both ends, so a full-scale spike isn't flattened by the round cap.
            let reach = max(1, canvasSize.height - lineWidth * 1.5)

            // A very faint baseline. It isn't decoration — with it, "there's no sound right now" and
            // "this thing is broken and stuck" can be told apart (the former is a flat line hugging the baseline,
            // the latter is a blank). ★ After revision 15 it is, once "the whole wave is driven by one input",
            // the only static reference still standing — don't delete it along the way.
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
                // Clamp the value to 0...1 first: the level is theoretically in that range, but clamp once anyway,
                // so no single miscalculation turns into a line drawn outside the canvas.
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
            //    fake data — the only difference is "it's a surface, not a line". When quiet, that thin bottom-hugging line's
            //    "share of the screen" is tiny; with this layer, speech opens the whole block up and you can see at a glance that it's eating sound.
            // ⚠️ Hand-write a closed path rather than putting together two `Path`s — `fill` will automatically
            //    connect an **unclosed** path back to its start, and that "edge that closes back" is easily drawn crooked.
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
        // ⚠️ The width cap is set hard by the `WatchBotFace` frame (that face's frame is `size × 1.14`),
        //    1.10 leaves only about 3.5% of headroom, **this one is maxed out**. Want it wider? What should change is
        //    `WatchRecorderView.botFraction` (the whole face's share), not this one number.
        .frame(width: size * 1.10, height: size * 0.68)
        // The glow for the recording state. On the watch face there's nowhere else to say "it's working".
        .shadow(color: tint.opacity(0.55), radius: 7)
        // Advance one slot on every sample received.
        //
        // ★ Revision 15: there used to be a `guard bpm != nil else { return }` here
        //   (revision 14's "unworn means nothing moves"); it was the thing that froze this wave into a straight line.
        //   With it gone the wave only knows the level — for the reasoning and consequences see the "revision 15" block at the top of the file.
        .onChange(of: meter) { _, new in
            advance(using: new)
        }
        .accessibilityHidden(true)
    }

    /// Advance one slot. **Driven by `tick`**, not by `level` — see the `WatchAudioMeter` block.
    ///
    /// ★ Revision 15: this slot's height **is** the level, with no second term.
    ///   The re-9 through re-14 version was `max(level, pulse)`: no matter how quiet, it pushed
    ///   the `beat` table up a slot as a "heartbeat". That's exactly where "the heartbeat and speech are mixed up and neither is recognisable" came from —
    ///   and the verdict the user gave on real hardware was "what I want is the waveform".
    private func advance(using meter: WatchAudioMeter) {
        var next = samples
        next.append(CGFloat(meter.level))
        if next.count > Self.sampleCount {
            next.removeFirst(next.count - Self.sampleCount)
        }
        samples = next
    }

    /// The line width is derived from `size`, not hard-coded — 40mm to 49mm differ by 40pt, and a hard-coded value would be wrong on one of them.
    ///
    /// ★ Revision 12: 0.024 → **0.028** (2.9pt → 3.3pt on 40mm). Once the canvas is enlarged the same
    /// line width looks thinner on screen, so it goes up a notch to keep that bit of "brushstroke" feel.
    private static func lineWidth(for size: CGFloat) -> CGFloat {
        max(2, size * 0.028)
    }
}
