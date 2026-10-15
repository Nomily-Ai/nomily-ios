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
/// ★ Fourth revision, 2026-10-15 (user's words: "for now don't just have a plain 'get ready to record' in the middle, have it turn
/// automatically with the ring even when recording isn't tapped"):
///
/// * **The ring turns while idle too** — the whole circle slowly rotates through the current gradient (one lap in 14 seconds). Previously the idle state
///   was a neutral grey circle with a dead ring, and that middle "ready" line was the only source of information;
///   now "the ring is moving" itself says it's standing by, so that line can go.
/// * **The middle lost the "ready" text**, leaving just a microphone; while recording the same spot becomes a stop square,
///   and the timer and byte count are demoted to a small line at the bottom of the disc. The icon is **always pinned to the disc's centre** and never
///   moves in either state — the user explicitly asked for "it needs to be centred, don't let it wobble".
/// * Idle vs recording is now distinguished by **brightness and moving things** (a slow-turning gradient at 0.55 opacity
///   vs full brightness + progress arc + comet + ripples), no longer by "is there any colour".
struct WatchRingControl: View {
    let isRecording: Bool
    let elapsed: TimeInterval
    /// The small line at the bottom of the disc while recording (currently the bytes written). Hidden when idle.
    ///
    /// Passed in rather than computed here: this page's purpose is "the state of this recording", and the byte count
    /// belongs to the recording pipeline; the skin layer shouldn't be asking for it.
    let detail: String?
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
    /// Whether the idle whole-circle gradient is rotating. Same playbook as `spin`: one flip +
    /// `repeatForever`, after which the render server interpolates for free, at zero cost to the app.
    @State private var idleSpin: Bool = false
    /// One-shot ring flash fired on start. Two plain numbers rather than a
    /// repeating animation, so the reset can be made instantaneous and can't
    /// be seen.
    @State private var burstScale: CGFloat = 1
    @State private var burstOpacity: CGFloat = 0
    /// Whether the breathing halo is mid-breath. Same one-flip trick as
    /// `spin` — see `syncBreathing()`.
    @State private var breath: Bool = false
    /// Ripple spread: three expanding rings with offset phases. Same playbook as `spin` / `breath` —
    /// a single `false → true` flip + `repeatForever`, with all interpolation done by the render server.
    @State private var rippleA = false
    @State private var rippleB = false
    @State private var rippleC = false
    /// Ripple batch number: +1 on stop, invalidating every delayed wave that hasn't set off yet,
    /// so that on "stop → immediately record again" the previous batch's delayed closure doesn't pop up and run one wave on its own.
    @State private var rippleBatch = 0

    // Geometry. Everything is expressed as an inset from the square's edge so
    // the rings keep their proportions at any size.
    //
    // 2026-10-15 the ring was scaled up overall to approach the Health app's screen coverage, with the line width thickened a notch to match,
    // otherwise the ring grows but the line doesn't, and it looks like a loop of thin wire.
    private static let progressWidth: CGFloat = 12
    private static let lapWidth: CGFloat = 6
    private static let gap: CGFloat = 6
    private static let cometDuration: Double = 2.4
    /// How long the idle gradient takes for one lap. Deliberately **slow**: it wants "alive", not "busy".
    /// 8 seconds looks like loading; 14 seconds looks like breathing.
    private static let idleSpinDuration: Double = 14
    /// How long one ripple takes from birth to fading out; the three waves are offset by a 1/3 phase.
    private static let rippleDuration: Double = 1.9

    private var progressInset: CGFloat { Self.progressWidth / 2 }
    private var lapInset: CGFloat { Self.progressWidth + Self.gap + Self.lapWidth / 2 }
    private var discInset: CGFloat { Self.progressWidth + Self.gap + Self.lapWidth + Self.gap + 4 }

    /// The accent colour used while recording (progress arc, comet, centre stroke).
    ///
    /// The idle state is **no longer** neutral grey (the user wanted "the ring to turn even when recording isn't tapped", and a grey ring
    /// doesn't look like it's turning). Idle vs recording is now carried by `idleRing`'s opacity, the presence or absence of
    /// comet/ripples, and the centre icon.
    private var accent: Color {
        isRecording ? style.palette.solid : Color(white: 0.72)
    }

    /// The outer ring's gradient while recording. The colour logic moved into `WatchRingStyle.ringAngularGradient`
    /// — the colour page's small preview needs the same copy, and two copies would drift.
    private var ringGradient: AngularGradient { style.ringAngularGradient }

    /// Colour of the inner ring (the hour ring). While recording it prefers the palette's `lapColor`
    /// (activity's neon green); if none is specified or it isn't recording (the neutral-grey test) it falls back to `accent`.
    private var lapAccent: Color {
        isRecording ? (style.palette.lapColor ?? accent) : accent
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
                ripples
                burstRing
                idleRing
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
            if isRecording {
                startSpin()
                startRipples()
            }
            startIdleSpin()
            syncBreathing()
        }
        .onChange(of: isRecording) { _, recording in
            if recording {
                fireBurst()
                startSpin()
                startRipples()
                stopIdleSpin()
            } else {
                stopSpin()
                stopRipples()
                startIdleSpin()
            }
        }
        .onChange(of: style.breathing) { _, _ in syncBreathing() }
        .onChange(of: dimmed) { _, reduced in
            if reduced {
                stopSpin()
                stopBreathing()
                stopRipples()
                stopIdleSpin()
            } else {
                if isRecording {
                    startSpin()
                    startRipples()
                } else {
                    startIdleSpin()
                }
                syncBreathing()
            }
        }
    }

    // MARK: - rings

    /// The idle circle: the whole ring takes its colour from the current gradient and **slowly rotates**.
    ///
    /// What rotates is **the view with the gradient already painted** (the whole thing turns via `rotationEffect`), so "colours moving
    /// around the ring" and "the colour rules" are decoupled — swapping palettes or turning the gradient off needs no change here.
    ///
    /// ⚠️ Only this "whole-circle stroke" layer rotates, **not** `progressRing`: that arc's position is precisely
    /// "how much of this minute has passed", and rotating it would be a lie.
    private var idleRing: some View {
        Circle()
            .inset(by: progressInset)
            .stroke(ringGradient, style: StrokeStyle(lineWidth: Self.progressWidth, lineCap: .round))
            .rotationEffect(.degrees(idleSpin ? 360 : 0))
            // Dim it further when the always-on face darkens, so it doesn't grab attention while you raise your wrist to check the time.
            .opacity(isRecording ? 0 : (dimmed ? 0.34 : 0.58))
            .animation(.easeInOut(duration: 0.3), value: isRecording)
    }

    /// The minute gauge: a faint track with a growing arc over it.
    private var progressRing: some View {
        ZStack {
            // The track only shows while recording: the idle circle is drawn by `idleRing` (in colour),
            // and two full circles of the same radius stacked up would muddy the colours underneath.
            Circle()
                .inset(by: progressInset)
                .stroke(accent.opacity(0.16),
                        style: StrokeStyle(lineWidth: Self.progressWidth, lineCap: .round))
                .opacity(isRecording ? 1 : 0)

            Circle()
                .inset(by: progressInset)
                .trim(from: 0, to: minuteLap)
                .stroke(ringGradient, style: StrokeStyle(lineWidth: Self.progressWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: style.palette.solid.opacity(isRecording ? 0.55 : 0), radius: 4)
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
                .stroke(lapAccent.opacity(0.12), style: StrokeStyle(lineWidth: Self.lapWidth, lineCap: .round))

            Circle()
                .inset(by: lapInset)
                .trim(from: 0, to: hourLap)
                .stroke(lapAccent.opacity(0.9), style: StrokeStyle(lineWidth: Self.lapWidth, lineCap: .round))
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

    // MARK: - ripples

    /// Ripple colour: the three-colour palette (activity) uses the outermost **cyan**, giving it separation from the magenta main ring;
    /// a double-colour palette's end colour is the gradient's dark end and is invisible on a black background, so it falls back to the main colour.
    private var rippleColor: Color {
        let cs = style.palette.colors
        return cs.count > 2 ? cs[cs.count - 1] : style.palette.solid
    }

    /// "Ripple spread": three thin rings expanding outward from the ring, fading as they grow, each a 1/3 cycle out of phase.
    ///
    /// Appears only while recording — like comet it's a signal that "it's still recording", not skin.
    ///
    /// ⚠️ Same performance red line as `breathHalo`: only `scaleEffect` + `opacity`,
    /// never `.blur` / large-radius `.shadow` (offscreen-rendered every frame on watchOS; a 40mm watch drops frames).
    /// The ripple expanding past the parent view's bounds is **deliberate**: being clipped by the screen edge looks better than shrinking inside it,
    /// and SwiftUI doesn't clip by default, which is just right.
    private var ripples: some View {
        ZStack {
            rippleRing(active: rippleC)
            rippleRing(active: rippleB)
            rippleRing(active: rippleA)
        }
        .opacity(isRecording && !dimmed ? 1 : 0)
        .allowsHitTesting(false)
    }

    private func rippleRing(active: Bool) -> some View {
        Circle()
            .inset(by: progressInset)
            .stroke(rippleColor, lineWidth: 3)
            .scaleEffect(active ? 1.42 : 1.0)
            .opacity(active ? 0 : 0.5)
    }

    /// The three waves start a 1/3 cycle apart. **Idempotent**: if `rippleA` is running, no second batch is scheduled.
    private func startRipples() {
        guard isRecording, !dimmed, !rippleA else { return }
        rippleBatch += 1
        let batch = rippleBatch
        func launch(after delay: Double, _ fire: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // The batch number changed (it stopped midway) or recording is no longer active ⇒ this wave doesn't set off.
                guard batch == rippleBatch, isRecording, !dimmed else { return }
                withAnimation(.linear(duration: Self.rippleDuration)
                    .repeatForever(autoreverses: false)) { fire() }
            }
        }
        launch(after: 0)    { rippleA = true }
        launch(after: Self.rippleDuration / 3) { rippleB = true }
        launch(after: Self.rippleDuration * 2 / 3) { rippleC = true }
    }

    private func stopRipples() {
        // First invalidate the delayed waves that haven't set off, then snap the three waves to zero (animation off,
        // otherwise you'd see the ripples suck back in — same reason as `stopSpin`).
        rippleBatch += 1
        guard rippleA || rippleB || rippleC else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            rippleA = false
            rippleB = false
            rippleC = false
        }
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

            // ★ The icon is **always pinned to the disc's centre**, not laid out in a VStack with the timer.
            //
            // The user's words: "when recording is tapped the icon centres itself, and when it isn't it also needs to be centred,
            // don't let it wobble". Laid out as a VStack, idle shows only the icon (centred), while recording adds
            // the timer line below it, pushing the icon up by about 8pt overall — and on a 40mm watch that
            // is a visible jump. Pinned to the ZStack centre, there's no such problem.
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 28, weight: .semibold))
                // White text + a little black shadow: the center is now colored, and using `accent` would
                // collide with the base color while recording (the old green collided because it was itself a green ring).
                .foregroundStyle(Color(white: 0.96))
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .contentTransition(.symbolEffect(.replace))

            // The timer and byte count are demoted to **a small line at the bottom of the disc** (where "ready" used to be).
            // The whole block is absent when idle — the user explicitly asked not to have that "get ready to record" text in the middle,
            // and "the ring turning + a microphone" already makes "standing by" clear.
            if isRecording {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(WatchFormat.compactDuration(elapsed))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color(white: 0.96))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color(white: 0.72))
                    }
                }
                .padding(.bottom, discInset * 0.55)
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .transition(.opacity)
            }
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

    /// Starts the idle gradient rotating. Same reason as `startSpin`: one flip + `repeatForever`,
    /// after which every frame is interpolated by the render server, with no further cost on the app side.
    ///
    /// ⚠️ It must start a new round only **after returning to 0**. Leaving `idleSpin` at true straight from true
    /// produces no animation (the value didn't change), and when recording ends and it returns to idle it happens to be false,
    /// so all that's needed here is re-entrancy protection.
    private func startIdleSpin() {
        guard !dimmed, !isRecording, !idleSpin else { return }
        withAnimation(.linear(duration: Self.idleSpinDuration).repeatForever(autoreverses: false)) {
            idleSpin = true
        }
    }

    private func stopIdleSpin() {
        // Same as `stopSpin`: with animation off, snap straight to zero, otherwise you'd see the ring spin **backwards** to its start.
        guard idleSpin else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { idleSpin = false }
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
