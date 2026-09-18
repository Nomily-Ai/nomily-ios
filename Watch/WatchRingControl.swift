import SwiftUI

/// The wrist recorder's main control: an Activity-style pair of rings that
/// doubles as the record button.
///
/// Three things move while a take is running, and each one is saying
/// something different:
///
/// * the **outer ring** fills once per minute,
/// * the **inner ring** fills once per hour — a second, slower lap so a long
///   meeting still has a hand that moves,
/// * a **comet** laps the outer ring every 2.4 s.
///
/// The first two are the information; the comet is the "it's live" signal.
/// That split is the whole point: a bare timer digit tells you a number, but
/// it doesn't tell you *at a glance from across the room* whether the thing
/// is still running, which is the question a wrist recorder actually has to
/// answer.
///
/// ★ 2026-10-15: color selection is now driven by `style` (the user can adjust color / gradient /
/// breathing light directly on the watch face, see `WatchRingStyle.swift`). **None of the three animation semantics above changed** --
/// they are function, not skin; a skin may only change "which colors are used" and the look of the center disc.
struct WatchRingControl: View {
    let isRecording: Bool
    let elapsed: TimeInterval
    /// The appearance the user chose. Provided by `WatchRingStyleStore`; redraws immediately on change.
    let style: WatchRingStyle
    let onToggle: () -> Void

    /// On an always-on wrist the screen is dimmed and continuously animating
    /// is both wasteful and impossible to read. The rings stay; the motion
    /// stops.
    @Environment(\.isLuminanceReduced) private var dimmed

    /// Whether the comet is mid-lap. Flipped once, animated forever — see
    /// `startSpin()`.
    @State private var spin: Bool = false
    /// One-shot ring flash fired on start. Two plain numbers rather than a
    /// repeating animation, so the reset can be made instantaneous and can't
    /// be seen.
    @State private var burstScale: CGFloat = 1
    @State private var burstOpacity: CGFloat = 0
    /// Whether the breathing halo is mid-breath. Same one-flip trick as
    /// `spin` — see `syncBreathing()`.
    @State private var breath: Bool = false

    // Geometry. Everything is expressed as an inset from the square's edge so
    // the rings keep their proportions at any size.
    private static let progressWidth: CGFloat = 10
    private static let lapWidth: CGFloat = 5
    private static let gap: CGFloat = 7
    private static let cometDuration: Double = 2.4

    private var progressInset: CGFloat { Self.progressWidth / 2 }
    private var lapInset: CGFloat { Self.progressWidth + Self.gap + Self.lapWidth / 2 }
    private var discInset: CGFloat { Self.progressWidth + Self.gap + Self.lapWidth + Self.gap + 4 }

    /// When not recording it is neutral gray -- so "gray / colored" itself serves as the
    /// first-glance indicator of "is it recording", and no color the user picks can cover it.
    private var accent: Color {
        isRecording ? style.palette.solid : Color(white: 0.52)
    }

    /// Outer-ring gradient while recording.
    ///
    /// ⚠️ Deliberately **not** indexing like `style.ringColors[1]`: with gradient off,
    /// `ringColors` has a single element and the subscript would go out of bounds. This uses `first` / `count`
    /// checks and, for a single color, degrades to "same color at both ends + each end's own opacity", equivalent to the original solid look.
    private var ringGradient: AngularGradient {
        let colors = style.ringColors
        let from = colors.first ?? style.palette.solid
        let to = colors.count > 1 ? colors[1] : from
        return AngularGradient(
            colors: [from.opacity(0.55), from, to, to.opacity(0.75)],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }

    /// Progress through the current minute. The ring laps, so the sweep never
    /// parks against a stop the way a fill-to-100% bar would after an hour.
    private var minuteLap: Double {
        guard isRecording else { return 0 }
        return min(1, elapsed.truncatingRemainder(dividingBy: 60) / 60)
    }

    /// Progress through the current hour.
    private var hourLap: Double {
        guard isRecording else { return 0 }
        return min(1, elapsed / 3600)
    }

    var body: some View {
        Button(action: onToggle) {
            ZStack {
                burstRing
                progressRing
                lapRing
                comet
                breathHalo
                core
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.34, dampingFraction: 0.62), value: isRecording)
        .accessibilityLabel(isRecording ? L10n.Watch.stop : L10n.Watch.record)
        .accessibilityValue(isRecording ? WatchFormat.compactDuration(elapsed) : L10n.Watch.ready)
        .onAppear {
            if isRecording { startSpin() }
            syncBreathing()
        }
        .onChange(of: isRecording) { _, recording in
            if recording {
                fireBurst()
                startSpin()
            } else {
                stopSpin()
            }
        }
        .onChange(of: style.breathing) { _, _ in syncBreathing() }
        .onChange(of: dimmed) { _, reduced in
            if reduced {
                stopSpin()
                stopBreathing()
            } else {
                if isRecording { startSpin() }
                syncBreathing()
            }
        }
    }

    // MARK: - rings

    /// The minute gauge: a faint track with a growing arc over it.
    private var progressRing: some View {
        ZStack {
            Circle()
                .inset(by: progressInset)
                .stroke(accent.opacity(isRecording ? 0.16 : 0.12),
                        style: StrokeStyle(lineWidth: Self.progressWidth, lineCap: .round))

            Circle()
                .inset(by: progressInset)
                .trim(from: 0, to: minuteLap)
                .stroke(ringGradient, style: StrokeStyle(lineWidth: Self.progressWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: accent.opacity(isRecording ? 0.55 : 0), radius: 4)
        }
        // One update per second, smeared into motion: the recorder's timer
        // stays at 1 Hz instead of driving the render loop, and the hand still
        // moves continuously. Turned off when idle so the reset to zero at the
        // start of a take can't be seen sweeping backwards.
        .animation(isRecording ? .linear(duration: 1) : nil, value: minuteLap)
    }

    /// The hour gauge — the same idea one scale up, so the map of the take is
    /// legible whether you've been running for 40 seconds or 40 minutes.
    private var lapRing: some View {
        ZStack {
            Circle()
                .inset(by: lapInset)
                .stroke(accent.opacity(0.12), style: StrokeStyle(lineWidth: Self.lapWidth, lineCap: .round))

            Circle()
                .inset(by: lapInset)
                .trim(from: 0, to: hourLap)
                .stroke(accent.opacity(0.9), style: StrokeStyle(lineWidth: Self.lapWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(isRecording ? .linear(duration: 1) : nil, value: hourLap)
    }

    /// The live signal. A short bright arc lapping the outer ring.
    ///
    /// Driven by a `.repeatForever` rotation rather than by writes to `@State`
    /// from a timer: once started the render server keeps it smooth for free,
    /// so this costs nothing per frame in the app process.
    private var comet: some View {
        Circle()
            .inset(by: progressInset)
            .trim(from: 0, to: 0.16)
            .stroke(accent, style: StrokeStyle(lineWidth: Self.progressWidth, lineCap: .round))
            .rotationEffect(.degrees(spin ? 270 : -90))
            .shadow(color: accent.opacity(0.9), radius: 6)
            .opacity(isRecording && !dimmed ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: isRecording)
    }

    /// One-shot flash so a tap has a visible consequence the instant it lands,
    /// rather than only the slower read of "the comet appeared".
    private var burstRing: some View {
        Circle()
            .inset(by: progressInset)
            .stroke(accent, lineWidth: 2.5)
            .scaleEffect(burstScale)
            .opacity(burstOpacity)
    }

    // MARK: - breathing

    /// "Breathing light": a halo expanding outward from the center circle.
    ///
    /// ⚠️ Uses only `scaleEffect` + `opacity`, **not** `.blur` / large-radius `.shadow`:
    /// both are rendered offscreen every frame on watchOS and visibly drop frames on a 40mm watch; scale/opacity
    /// are interpolated for free by the render server (same reason as `comet`).
    ///
    /// ⚠️ **Decoupled** from the recording state: breathing stops only when "off" / the always-on face dims. The reason is practical --
    /// when the user is picking a breathing rhythm on the face, recording is most likely not running, so it would show nothing if it only worked while recording.
    private var breathHalo: some View {
        Circle()
            .inset(by: discInset)
            .stroke(style.palette.solid, lineWidth: 2)
            .scaleEffect(breath ? 1.22 : 1.0)
            .opacity(breath ? 0 : 0.85)
    }

    // MARK: - core

    private var core: some View {
        ZStack {
            // Keep the base color dark: the center carries the white icon and timer, and must also layer against the color above it,
            // otherwise in solid mode the whole disc would blur into one block of color.
            Circle()
                .inset(by: discInset)
                .fill(Color(white: 0.10))

            // The user-selected color / gradient sits over the base color. When not recording it is dimmed to 0.35 to keep the face quiet,
            // but **not fully hidden** -- otherwise at the moment of picking a color on the face you could not see what you picked.
            Circle()
                .inset(by: discInset)
                .fill(style.centerFill)
                .opacity(isRecording ? 0.95 : 0.35)

            Circle()
                .inset(by: discInset)
                .stroke(accent.opacity(isRecording ? 0.40 : 0.16), lineWidth: 1)

            VStack(spacing: 1) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 24, weight: .semibold))
                    // White text + a little black shadow: the center is now colored, and using `accent` would
                    // collide with the base color while recording (the old green collided because it was itself a green ring).
                    .foregroundStyle(Color(white: 0.96))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .contentTransition(.symbolEffect(.replace))

                Text(isRecording ? WatchFormat.compactDuration(elapsed) : L10n.Watch.ready)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isRecording ? Color(white: 0.96) : Color(white: 0.72))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 6)
        }
    }

    // MARK: - motion

    /// Starts the comet. The rotation is a single 0→360 flip inside a
    /// `repeatForever`, so there is nothing to tick and nothing to cancel —
    /// stopping is just putting the value back with the animation turned off.
    private func startSpin() {
        guard !dimmed, !spin else { return }
        withAnimation(.linear(duration: Self.cometDuration).repeatForever(autoreverses: false)) {
            spin = true
        }
    }

    private func stopSpin() {
        // No animation: unwinding 360°→0 visibly would read as the ring
        // running backwards. By now the comet is already faded out.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { spin = false }
    }

    /// Decides from the current rhythm whether breathing runs or stops. **Idempotent** -- safe to call blindly from
    /// all three of `onAppear` / appearance change / brightness change.
    private func syncBreathing() {
        guard let period = style.breathing.period, !dimmed else {
            stopBreathing()
            return
        }
        guard !breath else { return }
        // A single `false → true` flip + `repeatForever`: the halo expands from the inside out,
        // fades to 0, then instantly snaps back to the start and repeats -- that is the "inhale-exhale".
        withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: false)) {
            breath = true
        }
    }

    private func stopBreathing() {
        guard breath else { return }
        // Same as `stopSpin`: animation must be disabled, otherwise you would see the halo slowly shrink back.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { breath = false }
    }

    private func fireBurst() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            burstScale = 0.97
            burstOpacity = 0.95
        }
        withAnimation(.easeOut(duration: 0.6)) {
            burstScale = 1.20
            burstOpacity = 0
        }
    }
}
