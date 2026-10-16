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
// ⚠️ The level is **real** (`AVAudioRecorder.isMeteringEnabled`), not a decorative animation.
//    It's worth being strict here: a purely random fake waveform keeps bouncing merrily even when the mic picks up no sound at all,
//    and the user watches this wave precisely to confirm **it's recording**. For that purpose a fake waveform is a liability.
//
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

    /// The level history inside the scrolling window, with the newest slot on the right.
    @State private var samples: [CGFloat]

    /// How many slots fit on one screen. 34 slots ÷ 12.5Hz ≈ 2.7 seconds.
    ///
    /// ⚠️ Too many and the sense of "scrolling" disappears (tens of seconds crammed into one screen barely looks like it's moving),
    ///    too few and it looks noisy. 34 is the setting where "you can see the rises and falls at a glance, and it really is moving left".
    private static let sampleCount = 34

    /// The heartbeat template for when it's quiet. One slot = one 12.5Hz beat = 80ms, ten slots = 0.8 seconds ≈ 75 bpm
    /// — exactly the resting-heart-rate range, which is the user's "like a heart rate".
    ///
    /// The shape is **boom-tick**: slot 2 is a tall peak (ventricular contraction), slot 7 a shorter
    /// second sound, and the rest a baseline near 0. This looks far more like a heart rate than "every slot the same height".
    ///
    /// ⚠️ The peak is deliberately kept under **0.35**: it's the "I'm still here" idle hum, not the star.
    ///    Make it bigger and you can't tell "it's beating" from "the mic really picked up sound" — and telling those two apart
    ///    is the only purpose this wave has.
    private static let beat: [CGFloat] = [
        0.05, 0.34, 0.16, 0.06, 0.04,
        0.04, 0.15, 0.07, 0.04, 0.03,
    ]

    init(meter: WatchAudioMeter, size: CGFloat, tint: Color) {
        self.meter = meter
        self.size = size
        self.tint = tint
        _samples = State(initialValue: Array(repeating: 0, count: Self.sampleCount))
    }

    var body: some View {
        Canvas { context, canvasSize in
            let lineWidth = Self.lineWidth(for: size)
            let mid = canvasSize.height / 2
            // Leave room for the line width, so a full-scale spike isn't clipped off by its own round cap.
            let reach = mid - lineWidth

            // A very faint centre line. It isn't decoration — with it, "there's no sound right now" and
            // "this thing is broken and stuck" can be told apart (the former is a flat line hugging the centre, the latter is a blank).
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: mid))
            axis.addLine(to: CGPoint(x: canvasSize.width, y: mid))
            context.stroke(
                axis,
                with: .color(tint.opacity(0.18)),
                style: StrokeStyle(lineWidth: max(1, lineWidth * 0.4), lineCap: .round)
            )

            guard samples.count > 1 else { return }
            var path = Path()
            for (index, value) in samples.enumerated() {
                let x = canvasSize.width * CGFloat(index) / CGFloat(samples.count - 1)
                // Clamp the value to 0...1 first: the level is theoretically in that range, but after taking
                // `max` of `beat` and the level, clamp once more, so no single miscalculation turns into a line drawn outside the canvas.
                let clamped = min(1, max(0, value))
                let y = mid - clamped * reach
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(
                path,
                with: .color(tint),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: size * 0.86, height: size * 0.30)
        // The glow for the recording state. It used to hang on the eyes and moved over once the eyes were replaced by this wave —
        // on the watch face there's nowhere else to say "it's working".
        .shadow(color: tint.opacity(0.55), radius: 7)
        .onChange(of: meter) { _, new in advance(using: new) }
        .accessibilityHidden(true)
    }

    /// Advance one slot. **Driven by `tick`**, not by `level` — see the `WatchAudioMeter` block.
    private func advance(using meter: WatchAudioMeter) {
        let pulse = Self.beat[meter.tick % Self.beat.count]
        var next = samples
        next.append(max(CGFloat(meter.level), pulse))
        if next.count > Self.sampleCount {
            next.removeFirst(next.count - Self.sampleCount)
        }
        samples = next
    }

    /// The line width is derived from `size`, not hard-coded — 40mm to 49mm differ by 40pt, and a hard-coded value would be wrong on one of them.
    private static func lineWidth(for size: CGFloat) -> CGFloat {
        max(2, size * 0.024)
    }
}
