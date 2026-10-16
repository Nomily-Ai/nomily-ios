import SwiftUI

/// The wrist recorder's main control: an Activity-style pair of rings that
/// doubles as the record button.
///
/// ★ 2026-10-16 七改：**这一份目前没有界面在用了。**
/// 首页正中已经从这只圆环换成了一张会眨眼的 Bot 脸（`WatchBotFace`）——
/// 用户的原话是"把当前首页的录音按钮去掉改成 bot 一样生动的"。这个文件留着
/// 是因为它身上的三件事短期内还会被问起，删掉就只剩 git 历史可查：
///   · 空闲态"环自己在转"的整套做法（一次翻转 + `repeatForever`，零 App 侧成本）；
///   · 录音态的彗星 / 波纹 / 分段进度弧（"隔着屋子也看得出还在录"）；
///   · 以及 `always-on` 降亮度时该停哪些、留哪些的那一份清单。
/// 它引用的 `PrimaryHandGesture` 已经搬到 `WatchBotFace.swift`（落点变了）。
///
/// ---
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
/// ★ 2026-10-15 四改（用户原话："当前中间不要直接一个准备录制，按照圆环自动
/// 转动即使在不点击录音的时候"）：
///
/// * **空闲时环也在转** —— 整圈按当前渐变缓慢周转（一圈 14 秒）。原来空闲态
///   是一圈中性灰，环是死的，中间那行"准备就绪"就成了唯一的信息源；
///   现在"环在动"本身就说明它待命，那行字可以拿掉。
/// * **中间去掉了"准备就绪"**，只剩一颗麦克风；录音时同一位置变成停止方块，
///   计时与字节数降级成盘底的一行小字。图标**永远钉在盘心**、两种状态都不
///   移动 —— 用户明确要求"需要居中不要晃动"。
/// * 空闲与录音的区别从此靠**亮度和会动的东西**（0.55 不透明度的慢转渐变
///   vs 满亮度 + 进度弧 + 彗星 + 波纹），不再靠"有没有颜色"。
struct WatchRingControl: View {
    let isRecording: Bool
    let elapsed: TimeInterval
    /// 录音时盘底那行小字（当前是已写入的字节数）。空闲时不显示。
    ///
    /// 传进来而不是在这里算：这一页的用途是"这次录音的状态"，而字节数
    /// 属于录音链路，不该由皮肤层去问。
    let detail: String?
    /// 用户选的外观。由 `WatchRingStyleStore` 提供，改了立刻重绘。
    let style: WatchRingStyle
    let onToggle: () -> Void
    /// ★ 2026-10-15 六改：**双指互点**（食指拇指捏合）能不能开/关录音。
    ///
    /// 由 `WatchRecordingPrefs.pinchToRecord` 拨过来，设置页可关。
    /// 关掉时不能只是"不做处理" —— 在 watchOS 11 上必须显式
    /// `isEnabled: false` 把这个手势从系统那里**收回来**，否则系统仍会把它
    /// 派给这一页的主按钮，用户关了也照触发。
    var handGestureEnabled: Bool = true

    /// On an always-on wrist the screen is dimmed and continuously animating
    /// is both wasteful and impossible to read. The rings stay; the motion
    /// stops.
    @Environment(\.isLuminanceReduced) private var dimmed

    /// Whether the comet is mid-lap. Flipped once, animated forever — see
    /// `startSpin()`.
    @State private var spin: Bool = false
    /// 空闲态整圈渐变是否在周转。同 `spin` 一个套路：一次翻转 +
    /// `repeatForever`，之后由渲染服务器免费插值，App 侧零成本。
    @State private var idleSpin: Bool = false
    /// One-shot ring flash fired on start. Two plain numbers rather than a
    /// repeating animation, so the reset can be made instantaneous and can't
    /// be seen.
    @State private var burstScale: CGFloat = 1
    @State private var burstOpacity: CGFloat = 0
    /// Whether the breathing halo is mid-breath. Same one-flip trick as
    /// `spin` — see `syncBreathing()`.
    @State private var breath: Bool = false
    /// 波纹扩散：三道相位错开的扩张环。同 `spin` / `breath` 一个套路 ——
    /// 一次 `false → true` 翻转 + `repeatForever`，插值全部由渲染服务器做。
    @State private var rippleA = false
    @State private var rippleB = false
    @State private var rippleC = false
    /// 波纹的批次号：stop 时 +1，作废所有还没起跑的延迟波，
    /// 免得"停止→立刻再录"时上一批的延时闭包冒出来单独跑一道波。
    @State private var rippleBatch = 0

    // Geometry. Everything is expressed as an inset from the square's edge so
    // the rings keep their proportions at any size.
    //
    // 2026-10-15 环整体放大到接近健康 App 的屏占比，线宽同步加粗一号，
    // 否则环大了线没变，看起来像描了圈细铁丝。
    private static let progressWidth: CGFloat = 12
    private static let lapWidth: CGFloat = 6
    private static let gap: CGFloat = 6
    private static let cometDuration: Double = 2.4
    /// 空闲态渐变转一圈的时长。刻意**慢**：它要的是"活着"，不是"在忙"。
    /// 8 秒会像加载中，14 秒才像呼吸。
    private static let idleSpinDuration: Double = 14
    /// 一道波纹从出生到消散的时长；三道波按 1/3 相位错开。
    private static let rippleDuration: Double = 1.9

    private var progressInset: CGFloat { Self.progressWidth / 2 }
    private var lapInset: CGFloat { Self.progressWidth + Self.gap + Self.lapWidth / 2 }
    private var discInset: CGFloat { Self.progressWidth + Self.gap + Self.lapWidth + Self.gap + 4 }

    /// 录音态用的强调色（进度弧、彗星、中心描边）。
    ///
    /// 空闲态**不再**是中性灰了（用户要"不点录音的时候环也在转"，灰环转起来
    /// 看不出在转）。空闲与录音的区别由 `idleRing` 的不透明度、彗星/波纹的
    /// 有无、以及中心图标来承担。
    private var accent: Color {
        isRecording ? style.palette.solid : Color(white: 0.72)
    }

    /// 录音态外环的渐变。取色逻辑搬进了 `WatchRingStyle.ringAngularGradient`
    /// —— 颜色页那个小预览要用同一份，两处各写一遍迟早会漂。
    private var ringGradient: AngularGradient { style.ringAngularGradient }

    /// 内圈（小时圈）的取色。录音时优先用色板指定的 `lapColor`
    /// （activity 的荧光绿），没有指定或没在录音（中性灰判据）就回落 `accent`。
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
        // ★ 双指互点（食指拇指捏合）= 开/关录音。
        .modifier(PrimaryHandGesture(enabled: handGestureEnabled))
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

    /// 空闲态那一圈：整圈按当前渐变取色，**慢慢周转**。
    ///
    /// 转的是**画好渐变的那个视图**（`rotationEffect` 整个转），所以"颜色沿着
    /// 环移动"和"取色规则"是解耦的 —— 换色板、关渐变都不用改这里一行。
    ///
    /// ⚠️ 只转这个"整圈描边"层，**不转** `progressRing`：那条弧的位置就是
    /// "这一分钟过去多少"，转起来等于说谎。
    private var idleRing: some View {
        Circle()
            .inset(by: progressInset)
            .stroke(ringGradient, style: StrokeStyle(lineWidth: Self.progressWidth, lineCap: .round))
            .rotationEffect(.degrees(idleSpin ? 360 : 0))
            // 常亮表盘变暗时压到更低，别在抬腕看时间的时候抢注意力。
            .opacity(isRecording ? 0 : (dimmed ? 0.34 : 0.58))
            .animation(.easeInOut(duration: 0.3), value: isRecording)
    }

    /// The minute gauge: a faint track with a growing arc over it.
    private var progressRing: some View {
        ZStack {
            // 轨道只在录音时露出来：空闲态那一圈由 `idleRing` 画（彩色的），
            // 两条同半径的整圈叠着会把下面的颜色搅浑。
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

    /// 波纹取色：三色盘（activity）用最外那道**青**，跟品红主环拉开层次；
    /// 双色盘的末端色是渐变的暗端，在黑底上看不见，所以回落主色。
    private var rippleColor: Color {
        let cs = style.palette.colors
        return cs.count > 2 ? cs[cs.count - 1] : style.palette.solid
    }

    /// 「波纹扩散」：三道从环往外扩、边扩边淡出的细环，相位各差 1/3 周期。
    ///
    /// 只在录音时出现 —— 它和 comet 一样是"还在录"的信号，不是皮肤。
    ///
    /// ⚠️ 跟 `breathHalo` 同一条性能红线：只用 `scaleEffect` + `opacity`，
    /// 不碰 `.blur` / 大半径 `.shadow`（watchOS 上逐帧离屏渲染，40mm 会掉帧）。
    /// 波纹扩张超出父视图边界是**故意的**：被屏幕边缘裁掉比缩在里面好看，
    /// SwiftUI 默认不裁剪，正好。
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

    /// 三道波错开 1/3 周期起跑。**幂等**：`rippleA` 在跑就不再排第二批。
    private func startRipples() {
        guard isRecording, !dimmed, !rippleA else { return }
        rippleBatch += 1
        let batch = rippleBatch
        func launch(after delay: Double, _ fire: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // 批次号变了（中途停过）或已经不在录音态 ⇒ 这道波不发车。
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
        // 先作废未起跑的延迟波，再把三道波瞬间归零（关动画，
        // 否则会看到波纹倒吸回去 —— 同 `stopSpin` 的理由）。
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

            // ★ 图标**永远钉在盘心**，不跟计时一起排 VStack。
            //
            // 用户原话："点击录音则图标自动居中，不点的时候也需要居中，
            // 不要晃动"。排成 VStack 的话，空闲时只有图标（居中），录音时多了
            // 下面那行计时，图标就会被整体顶高约 8pt —— 在 40mm 表上那一下
            // 是看得见的跳动。挂在 ZStack 中心就没有这个问题。
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 28, weight: .semibold))
                // 白字 + 一点黑色投影：中心现在是彩色的，用 `accent` 取色会
                // 在录音时和底色撞成一片（原来的绿色能撞上就是因为它本身是绿环）。
                .foregroundStyle(Color(white: 0.96))
                .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                .contentTransition(.symbolEffect(.replace))

            // 计时与字节数降级成**盘底的一行小字**（原来"准备就绪"的位置）。
            // 空闲态整块不出现 —— 用户明确要求中间不要那句"准备录制"，
            // 而"环在转 + 一颗麦克风"已经把"待命中"说清楚了。
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

    /// 空闲渐变开始周转。同 `startSpin` 的理由：一次翻转 + `repeatForever`，
    /// 之后每一帧都由渲染服务器插值，App 侧不再有开销。
    ///
    /// ⚠️ 必须在**回到 0 之后**再起新一轮。`idleSpin` 从 true 直接留在 true
    /// 是不会有动画的（值没变），而录音结束回到空闲时它正好是 false，
    /// 所以这里只需要防重入。
    private func startIdleSpin() {
        guard !dimmed, !isRecording, !idleSpin else { return }
        withAnimation(.linear(duration: Self.idleSpinDuration).repeatForever(autoreverses: false)) {
            idleSpin = true
        }
    }

    private func stopIdleSpin() {
        // 同 `stopSpin`：关掉动画直接归零，否则会看到环**倒着**转回去。
        guard idleSpin else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { idleSpin = false }
    }

    /// 按当前节奏决定呼吸是开是停。**幂等** —— 可以在 `onAppear` /
    /// 外观变更 / 亮度变更三处无脑调用。
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

// MARK: - 双指互点
//
// ★ 2026-10-16 七改：`PrimaryHandGesture` 这个 modifier **搬走了**，现在在
// `WatchBotFace.swift`。搬家的原因不是它变了，而是它的落点变了 ——
// 首页正中不再是这只圆环按钮，而是那张 Bot 脸；那个 modifier 本来就是
// "把手势绑到当前页的主控件上"，属于**控件**的事，不属于**环**的事。
//
// 它仍然是 `internal` 的，所以这一页（如果哪天又回到首页）照旧能用。
