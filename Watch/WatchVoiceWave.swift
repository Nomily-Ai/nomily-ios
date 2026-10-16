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
//   · **Spike height = the mic's live level**. That's the "waveform" half: talk and it shoots up.
//   · **The little bumps when it's quiet** (`beat`) are the "heart rate" half.
//
// ⚠️ The second item above was **deleted entirely in revision 15** — see the "revision 15" block at the end of this file.
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision 11 (user's words:
//    "when recording, the rises and falls should overall follow the personal real-time heart rate the watch picks up"):
// That "heart rate" is no longer a generic value but the measured bpm taken from `WatchHeartRateMonitor`,
// used to decide how fast the table runs.
//
// ⚠️ **This route was withdrawn entirely in revision 15**.
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision 12 (user: "when recording, the heart-rate rises and falls need a bigger amplitude and a bigger share of the screen"):
// Canvas `0.86×0.30` → `1.06×0.44`, base-shape main peak `0.34` → `0.52`, line width `0.024` → `0.028`.
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision 13 (user's words: "and after the watch starts recording, the recording's up-and-down should be more
//    obvious; right now the up-and-down isn't enough and doesn't take up the watch's share of the screen"):
//
// ## Root cause: the baseline is on the centre line, but values are only drawn upward
// The baseline is drawn at the canvas's **centre line**, while the curve only grows **upward** ⇒ "up-and-down" has no second half at all,
// that half of the canvas is always empty, and the usable vertical travel is only half. Raising the numbers won't help.
//
// ## The fix: drop the baseline to the bottom of the canvas
// | | revision 12 | revision 13 |
// |---|---|---|
// | baseline | centre line | **bottom** |
// | canvas height | `0.44 × size` | **`0.68 × size`** |
// | canvas width | `1.06 × size` | **`1.10 × size`** |
// ⇒ The same level now travels **about three and a half times** as far.
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision 14 ("when the watch isn't being worn there's no up-and-down ripple during recording"):
// Added a `guard bpm != nil else { return }` on `onChange(of: meter)`.
//
// ⚠️ **That gate is the root cause of the bug in the next round**.
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision fifteen (user's words:
//    "when recording, the waveform's rise and fall should still go by the surrounding sound's recording decibels, don't drive it off the heart rate,
//     because it's inaccurate right now and it's just a straight white line"):
//
// ## Symptom and root cause
// What the user sees is a **straight white line hugging the bottom**. The root cause isn't that the level isn't coming in, it's revision 14's
// `guard bpm != nil else { return }` — **if the heart rate can't be read, not one slot advances**.
// And "can't read it" is the **norm** in this chain: at rest an Apple Watch may take a dozen minutes to
// drop a single sample into HealthKit, and with no health permission granted it's **never** read.
//
// ## The fix: this wave has **one** input left — the mic level
// Delete the `bpm` parameter, the `beat` base table, `restingBPM`, `beatPhase`,
// `nextBeatSample()`, and that gate. `advance` writes `meter.level` directly.
//
// ## Three things that came along to become obsolete / degrade (all deliberate, not oversights)
//   · The re-12 discipline "don't push the base shape to full scale" is void along with the base shape;
//   · **The ability to "tell it's working even when quiet" is gone**: when the mic picks up no sound it's a
//     bottom-hugging flat line, the same shape as "broken". The fallback is the faint baseline axis and the **recording timer** below the wave
//     (the latter is the harder evidence);
//   · Revision 14's "no watch on the wrist, no wave" degrades to "quiet means flat" — the user overturned that criterion themselves.
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 revision sixteen (user's words:
//    "make the recording side a little more alive; use the particle effects in the watch's mobile ECG app as the waveform
//     instead of the current simple line").
//
// ## The reference is the Apple Watch's "ECG" app
// What makes it look good isn't "the curve is drawn accurately", it's three things:
//   ① **a very smoothly scrolling trace** (not jumping a slot every 80ms — that's how it was before my rework);
//   ② **the trace itself glows**, not a single 1pt thin line;
//   ③ **the head has a bright dot**, following the newest slot, like an oscilloscope's cursor.
// The user calls these three together "particle effects". So this round adds these layers:
//
// | layer | job |
// |---|---|
// | area fill (`0.14`) | turns "how loud it is right now" into a **surface**, not the height of a line |
// | **rising particles** | rise from each slot where there "really is sound", fading with height — this is the most direct landing spot for the word "particles" |
// | two glow strokes | the ECG trace's glowing feel (wide and faint + medium width, the main line last) |
// | head glow | rests on the newest slot, with a faint halo around it |
//
// ## ① Smooth scrolling is the real technical change this round
// The level arrives at **12.5Hz** (`WatchRecorderModel.meterInterval = 0.08`).
// Before the rework each tick shifted the whole thing one slot left — on a 131pt-wide canvas that's a 4pt jump every 80ms,
// which the eye reads as "shuffling slot by slot". Now it redraws at **30fps** via `TimelineView(.animation)`,
// and interpolates a `phase ∈ [0,1)` between the two slots **by time**, shifting the whole trace left by `phase × slot width`:
// the trace **slides continuously** between two samples, and the moment a new sample arrives it has slid exactly one slot,
// so no seam is visible (the right end uses the "head" to add the newest height, leaving no gap).
//
// ## ② The particles must be **deterministic**
// `Canvas` redraws every frame. With `random()` the position differs every frame and it looks like **flickering noise**,
// not particles. So each particle's phase/speed/drift comes from `noise(index, salt)` —
// a pure-function hash, so the same particle always computes the same trajectory across consecutive frames,
// with only time advancing. That's the line between "particles flying" and "the screen is noisy".
//
// ## ③ A particle's rise height is **limited by the canvas headroom**
// A full-scale spike sits at the top edge of the canvas with not a bit of headroom above it. Forcing it upward just gets it clipped by `Canvas`'s
// boundary (and where it's clipped the alpha isn't 0, so it looks "shaved flat").
// So the rise distance takes `min(headroom, how high it should go)` — and then "the louder, the higher it sprays" always holds,
// right up to actually hitting the ceiling, and it's never shaved.
//
// ⚠️ This layer is **purely decorative** and changes no values: height, area and head position all equal
//    the real level exactly. This has been this file's red line since revision 9 ("a fake waveform is a
//    liability for 'confirming it's recording'"), and no amount of particles may cross it.
//
// ⚠️ **The whole timeline pauses in dimmed mode (Always-On)** (`paused: reduced`).
//    30fps redraws are a visible battery cost on the wrist, and when the face is dimmed the user isn't looking at it anyway.
//    Once paused, the picture freezes on one frame — consistent with the "whole face is still" feel when dimmed.
// ─────────────────────────────────────────────────────────────────────────
// ## Why keep a short history instead of drawing only the instantaneous value
// A waveform is "a line that scrolls left over time", not a bar jumping up and down. So you need a little
// history (`sampleCount` slots), appending one slot at the right on each tick.
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
    /// When the last slot came in. Used to work out how far it has slid between two samples (see "revision 16 ①").
    @State private var lastTickAt = Date()
    /// Stops the whole timeline when dimmed (see the ⚠️ at the end of "revision 16").
    @Environment(\.isLuminanceReduced) private var reduced

    /// How many slots fit on one screen. 34 slots ÷ 12.5Hz ≈ 2.7 seconds.
    ///
    /// ⚠️ Too many and the sense of "scrolling" disappears (tens of seconds crammed into one screen barely looks like it's moving),
    ///    too few and it looks noisy. 34 is the setting where "you can see the rises and falls at a glance, and it really is moving left".
    private static let sampleCount = 34

    /// The interval between samples. Must match `WatchRecorderModel.meterInterval` —
    /// the interpolation step uses it as the denominator.
    private static let tickInterval: TimeInterval = 0.08

    /// The redraw rate.
    ///
    /// ⚠️ 30fps is a weighed choice: particle motion shows stepping below 24fps, while 60fps
    ///    is indistinguishable to the eye on a 40mm watch yet doubles the cost.
    private static let frameInterval: TimeInterval = 1.0 / 30.0

    /// Only a level above this value counts as "there really is sound", and only then do particles rise from that slot.
    ///
    /// ⚠️ This gate can't be removed: when quiet the whole wave hugs the bottom, and a ring of rising particles would become
    ///    a **fake "it's busy"** signal — and the entire point of this wave's existence is
    ///    "tell 'it's beating' from 'the mic really picked up sound'".
    private static let particleGate: CGFloat = 0.06

    init(meter: WatchAudioMeter, size: CGFloat, tint: Color) {
        self.meter = meter
        self.size = size
        self.tint = tint
        _samples = State(initialValue: Array(repeating: 0, count: Self.sampleCount))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: reduced)) { timeline in
            Canvas { context, canvasSize in
                render(
                    into: &context,
                    canvas: canvasSize,
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    phase: scrollPhase(at: timeline.date)
                )
            }
        }
        // ★★ Revision 13: `1.06 × 0.44` → **`1.10 × 0.68`**.
        //
        // ⚠️ The width cap is set hard by the `WatchBotFace` frame (that face's frame is `size × 1.14`),
        //    1.10 leaves only about 3.5% of headroom, **this one is maxed out**. Want it wider? What should change is
        //    `WatchRecorderView.botFraction` (the whole face's share), not this one number.
        .frame(width: size * 1.10, height: size * 0.68)
        // ⚠️ Revision 16 **deleted** the `.shadow(color:radius:)` that used to hang here:
        //    the glow is now drawn inside `Canvas` with two wider strokes (see `render`).
        //    The reason is that this view now redraws at 30fps, and `.shadow` is one offscreen render per frame;
        //    two extra strokes inside `Canvas` are far cheaper, and let you control each layer's opacity.
        .onChange(of: meter) { _, new in advance(using: new) }
        .accessibilityHidden(true)
    }

    /// How far it has slid between two samples, `0 ..< 1`.
    ///
    /// ★ Added in revision 16, see "revision 16 ①" at the top of the file.
    private func scrollPhase(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(lastTickAt)
        guard elapsed > 0 else { return 0 }
        return min(1, elapsed / Self.tickInterval)
    }

    /// Advance one slot. **Driven by `tick`**, not by `level` — see the `WatchAudioMeter` block.
    ///
    /// ★ Revision 15: this slot's height **is** the level, with no second term.
    private func advance(using meter: WatchAudioMeter) {
        var next = samples
        next.append(CGFloat(meter.level))
        if next.count > Self.sampleCount {
            next.removeFirst(next.count - Self.sampleCount)
        }
        samples = next
        lastTickAt = Date()
    }

    // MARK: - Draw

    private func render(
        into context: inout GraphicsContext,
        canvas: CGSize,
        time: Double,
        phase: Double
    ) {
        let lineWidth = Self.lineWidth(for: size)

        // ★★ Revision 13: the baseline moves from the **centre line** to the **bottom of the canvas**.
        //
        // 0.75 of a line width is left for the round pen cap: without it, the bottom-hugging line would be
        // half-clipped by its own end cap (the round cap is a semicircle drawn with the line width as its diameter).
        let baseline = canvas.height - lineWidth * 0.75
        // Same deduction at both ends, so a full-scale spike isn't flattened by the round cap.
        let reach = max(1, canvas.height - lineWidth * 1.5)

        let count = samples.count
        guard count > 1 else { return }
        let step = canvas.width / CGFloat(count - 1)
        let shift = CGFloat(phase) * step

        // A very faint baseline. It isn't decoration — with it, "there's no sound right now" and
        // "this thing is broken and stuck" can be told apart (the former is a flat line hugging the baseline, the latter is a blank).
        // ★ After revision 15 it is, once "the whole wave is driven by one input", the only static reference still standing.
        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: baseline))
        axis.addLine(to: CGPoint(x: canvas.width, y: baseline))
        context.stroke(
            axis,
            with: .color(tint.opacity(0.14)),
            style: StrokeStyle(lineWidth: max(1, lineWidth * 0.4), lineCap: .round)
        )

        // The points. ★ Revision 16: shift the whole thing left by one `phase` so it slides continuously between two samples;
        // then append a "head" at the end to pull the newest slot to the canvas's right edge, leaving no gap on the right.
        var points: [CGPoint] = []
        points.reserveCapacity(count + 1)
        for (index, value) in samples.enumerated() {
            let x = CGFloat(index) * step - shift
            // Clamp the value to 0...1 first: the level is theoretically in that range, but clamp once anyway,
            // so no single miscalculation turns into a line drawn outside the canvas.
            let clamped = min(1, max(0, value))
            points.append(CGPoint(x: x, y: baseline - clamped * reach))
        }
        points.append(CGPoint(x: canvas.width, y: points[count - 1].y))

        var trace = Path()
        trace.move(to: points[0])
        for point in points.dropFirst() {
            trace.addLine(to: point)
        }

        // The fill layer below the curve.
        //
        // ⚠️ Its height **equals the real level exactly**, introducing no fake data — the only difference is
        //    "it's a surface, not a line". Hand-write a closed path rather than putting together two `Path`s:
        //    `fill` will automatically connect an **unclosed** path back to its start, and that edge is easily drawn crooked.
        var area = trace
        area.addLine(to: CGPoint(x: canvas.width, y: baseline))
        area.addLine(to: CGPoint(x: points[0].x, y: baseline))
        area.closeSubpath()
        context.fill(area, with: .color(tint.opacity(0.14)))

        // Particles sit **under** the glow: a glow over the particles would wash them out.
        drawParticles(into: &context, points: Array(points.prefix(count)), canvas: canvas, time: time)

        // Two glow layers + the main line, wide to narrow. This is the ECG's "the trace itself is glowing" feel
        // (before revision 16 there was only the last layer).
        context.stroke(
            trace,
            with: .color(tint.opacity(0.22)),
            style: StrokeStyle(lineWidth: lineWidth * 3.6, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            trace,
            with: .color(tint.opacity(0.45)),
            style: StrokeStyle(lineWidth: lineWidth * 1.8, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            trace,
            with: .color(tint),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )

        // The head. It rests on the newest slot and slides along — an oscilloscope's cursor.
        let head = points[count - 1]
        let headRadius = lineWidth * 1.5
        context.fill(
            Path(ellipseIn: CGRect(
                x: head.x - headRadius * 2.8, y: head.y - headRadius * 2.8,
                width: headRadius * 5.6, height: headRadius * 5.6
            )),
            with: .color(tint.opacity(0.15))
        )
        context.fill(
            Path(ellipseIn: CGRect(
                x: head.x - headRadius, y: head.y - headRadius,
                width: headRadius * 2, height: headRadius * 2
            )),
            with: .color(tint)
        )
    }

    /// The rising particles. **They only rise from the slots where "there really is sound"**.
    ///
    /// ★ Added in revision 16 (user: "reference the particle effects in the watch's mobile ECG app").
    ///
    /// ## How each particle is computed
    /// `noise(index, salt)` gives three things: speed (how long a cycle takes), phase (staggering the launch
    /// moment), and lateral drift. Across consecutive frames these are **the same value** — so the same particle flies up along
    /// a fixed line, rather than jumping around every frame (see "revision 16 ②" at the top of the file).
    ///
    /// ## Why the rise height takes `min(headroom, how high it should go)`
    /// See "revision 16 ③" at the top of the file: a full-scale spike has no space above it, and forcing it up just gets it clipped by the canvas.
    private func drawParticles(
        into context: inout GraphicsContext,
        points: [CGPoint],
        canvas: CGSize,
        time: Double
    ) {
        let lineWidth = Self.lineWidth(for: size)

        for index in points.indices {
            let value = min(1, max(0, samples[index]))
            guard value > Self.particleGate else { continue }

            let origin = points[index]
            // How much room is left up to the canvas's top edge.
            let room = origin.y - lineWidth
            guard room > 2 else { continue }

            // The louder, the more it sprays: two per slot when loud, one when quiet.
            let particles = value > 0.35 ? 2 : 1
            for salt in 0..<particles {
                let seed = Self.noise(index, salt)
                let speed = 0.75 + seed * 0.70
                var life = (time * speed + seed * 5.31).truncatingRemainder(dividingBy: 1)
                if life < 0 { life += 1 }
                let age = CGFloat(life)

                let wanted = age * (0.30 + 0.85 * value) * canvas.height
                let rise = min(room, wanted)
                let drift = CGFloat(Self.noise(index, salt + 17) - 0.5) * 10 * age
                let point = CGPoint(x: origin.x + drift, y: origin.y - rise)

                let radius = (0.6 + 1.4 * (1 - age)) * (0.55 + 0.75 * value)
                let alpha = (1 - age) * min(1, Double(value) * 2.4) * 0.9
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: point.x - radius, y: point.y - radius,
                        width: radius * 2, height: radius * 2
                    )),
                    with: .color(tint.opacity(alpha))
                )
            }
        }
    }

    /// A pure-function hash, giving the interval `[0, 1)`.
    ///
    /// ⚠️ The parameters are `index` + `salt`, **not a monotonic ordinal**: a particle's identity must be determined only by
    ///    "which slot it came from" and "which particle of that slot it is", so a particle from a given slot computes
    ///    the same speed/phase throughout its whole lifetime. Switch to a globally incrementing ordinal
    ///    and every new sample reshuffles the whole trajectory — which degrades into noise.
    private static func noise(_ index: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: index &* 73_856_093 &+ salt &* 19_349_663)
        x ^= x >> 33
        x = x &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 33
        return Double(x % 100_000) / 100_000
    }

    /// The line width is derived from `size`, not hard-coded — 40mm to 49mm differ by 40pt, and a hard-coded value would be wrong on one of them.
    ///
    /// ★ Revision 12: 0.024 → **0.028** (2.9pt → 3.3pt on 40mm). Once the canvas is enlarged the same
    /// line width looks thinner on screen, so it goes up a notch to keep that bit of "brushstroke" feel.
    private static func lineWidth(for size: CGFloat) -> CGFloat {
        max(2, size * 0.028)
    }
}
