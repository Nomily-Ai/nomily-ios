import SwiftUI

// MARK: - 录音时那条音波
//
// 这条波只有**一个**输入：麦克风电平（`meter.level`，12.5Hz）。
// 基线贴画布底部，尖峰高度就是电平，所以纵向行程是整张画布。
//
// ⚠️ 安静时就是一条贴底的平线，光看它分不出"没声音"和"坏了"。
//    兜底靠基线那条淡轴、以及波下面的录音计时和首页那行字节数。
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 十六改（用户原话：
//    "录音那边在生动一点，参考手表里面的移动心电图软件里面的粒子特效当音波图
//     而不是当前简单的一条线"）。
//
// ## 参考物是 Apple Watch 的「心电图」App
// 它好看不在于"曲线画得准"，在于三件事：
//   ① **一条滚动得很顺的迹**（不是每 80ms 跳一格 —— 那是我改造前的样子）；
//   ② **迹本身有辉光**，不是一根 1pt 的细线；
//   ③ **笔尖有一颗亮的点**，跟着最新那一格走，像示波器的光标。
// 用户把这三件合起来叫作"粒子特效"。所以这一轮加的是这么几层：
//
// | 层 | 作用 |
// |---|---|
// | 面积填充（`0.14`） | 让"现在有多响"变成一个**面**，而不是一根线的高度 |
// | **上升粒子** | 从每一格"真的有声音"的位置往上冒，越高越淡 —— 这是"粒子"那两个字最直接的落点 |
// | 两层辉光描边 | 心电图那条迹的发光质感（宽而淡 + 中等宽，最后才是主线） |
// | 笔尖光斑 | 停在最新那一格上，外圈一层淡光晕 |
//
// ## ① 平滑滚动是这一轮真正的技术改动
// 电平是 **12.5Hz** 来的（`WatchRecorderModel.meterInterval = 0.08`）。
// 改造前每次 tick 整条左移一格 —— 在 131pt 宽的画布上是每 80ms 跳 4pt，
// 肉眼就是"一格一格地挪"。现在用 `TimelineView(.animation)` 以 **30fps** 重绘，
// 并在两格之间按**时间**插一个 `phase ∈ [0,1)`，把整条迹左移 `phase × 格宽`：
// 迹在两次采样之间是**连续滑动**的，新采样到的那一刻正好滑满一格，
// 于是看不出接缝（右端用"笔尖"补上最新的高度，不留空档）。
//
// ## ② 粒子必须是**确定性**的
// `Canvas` 每帧重画。用 `random()` 的话每帧位置都不同，看起来是**噪点闪烁**，
// 不是粒子。所以每个粒子的相位/速度/漂移都来自 `noise(index, salt)` ——
// 一个纯函数哈希，同一个粒子在连续帧里算出来的永远是同一条轨迹，
// 只有时间在推进。这是"粒子在飞"和"屏幕在噪"的分界。
//
// ## ③ 粒子的上升高度**受画布余量限制**
// 满量程的尖峰顶在画布上沿，它上方一点余量都没有。硬让它往上冲就是被 `Canvas`
// 的边界切掉（切掉的地方 alpha 还不是 0，看起来是"被削平"）。
// 所以上升距离取 `min(余量, 该有多高)` —— 于是"越响喷得越高"一直成立，
// 直到真的顶到天花板为止，永远不会被削。
//
// ⚠️ 这一层是**纯装饰**，它不改任何数值：高度、面积、笔尖位置全部严格等于
//    真实电平。这一点从九改起就是这个文件的红线（"假的波形在'确认它在录'
//    这个用途上是负资产"），粒子再多也不能越。
//
// ⚠️ **降亮度（Always-On）时整条时间线暂停**（`paused: reduced`）。
//    30fps 重绘在手里是看得见的电池开销，而表盘降亮度时用户根本没在看它。
//    暂停之后画面会停在一帧上 —— 与降亮度时"整表静止"的观感一致。
// ─────────────────────────────────────────────────────────────────────────
// ## 为什么自己存一段历史，而不是只画瞬时值
// 音波是"一条随时间往左滚的线"，不是一根上下乱跳的柱子。所以要有一小段
// 历史（`sampleCount` 格），每滴答一次在右端追加一格。
struct WatchVoiceWave: View {
    /// 当前电平。`level` 决定这一格多高；`tick` 用来驱动前进 ——
    /// 理由见 `WatchAudioMeter` 顶部那段（安静时 `level` 恒等于 0，
    /// `onChange(of: level)` 一次都不会触发，靠 `tick` 才知道该走）。
    let meter: WatchAudioMeter
    /// 这张脸的名义边长，跟眼睛共用一套比例。
    let size: CGFloat
    /// 波的颜色。跟着"外观"页选的那个颜色走（和眼睛同一个来源）。
    let tint: Color

    /// 滚动窗口里的电平历史，最右边是最新的一格。
    @State private var samples: [CGFloat]
    /// 最后一格是什么时候进来的。用来算两次采样之间滑到哪儿了（见"十六改 ①"）。
    @State private var lastTickAt = Date()
    /// 降亮度时把整条时间线停掉（见"十六改"末尾那条 ⚠️）。
    @Environment(\.isLuminanceReduced) private var reduced

    /// 一屏显示多少格。34 格 ÷ 12.5Hz ≈ 2.7 秒。
    ///
    /// ⚠️ 太多了会让"滚"的感觉消失（一屏塞进几十秒，几乎看不出在动），
    ///    太少了又会显得很吵。34 是"一眼看得出起伏、又确实在往左走"的那档。
    private static let sampleCount = 34

    /// 一次采样之间的间隔。与 `WatchRecorderModel.meterInterval` 必须一致 ——
    /// 插值那一步拿它当分母。
    private static let tickInterval: TimeInterval = 0.08

    /// 重绘频率。
    ///
    /// ⚠️ 30fps 是权衡过的：粒子流动在 24fps 以下能看出台阶，而 60fps 在
    ///    40mm 的表上肉眼分辨不出、开销却翻倍。
    private static let frameInterval: TimeInterval = 1.0 / 30.0

    /// 电平高过这个值才算"真的有声音"，才从那一格冒粒子。
    ///
    /// ⚠️ 不能去掉这一关：安静时整条波贴底，配上一圈往上冒的粒子会变成
    ///    一个**假的"它很忙"**的信号 —— 而这条波存在的全部意义就是
    ///    "分清它在跳"和"麦克风真的收到声音了"。
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
        // ★★ 十三改：`1.06 × 0.44` → **`1.10 × 0.68`**。
        //
        // ⚠️ 宽度上限由 `WatchBotFace` 的外框卡死（那张脸的外框是 `size × 1.14`），
        //    1.10 只剩约 3.5% 的余量，**这一项已经到头了**。还想更宽，该动的是
        //    `WatchRecorderView.botFraction`（整张脸的占比），不是这一个数。
        .frame(width: size * 1.10, height: size * 0.68)
        // ⚠️ 十六改把原来挂在这里的 `.shadow(color:radius:)` **删掉了**：
        //    辉光改成在 `Canvas` 里用两层更宽的描边画（见 `render`）。
        //    理由是这个视图现在 30fps 重绘，而 `.shadow` 是每一帧一次离屏渲染；
        //    `Canvas` 内部多描两笔便宜得多，而且能控制每一层的不透明度。
        .onChange(of: meter) { _, new in advance(using: new) }
        .accessibilityHidden(true)
    }

    /// 两次采样之间滑到哪儿了，`0 ..< 1`。
    ///
    /// ★ 十六改新增，见文件顶部"十六改 ①"。
    private func scrollPhase(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(lastTickAt)
        guard elapsed > 0 else { return 0 }
        return min(1, elapsed / Self.tickInterval)
    }

    /// 前进一格。**由 `tick` 驱动**，不是由 `level` —— 见 `WatchAudioMeter` 那段。
    ///
    /// 这一格的高度**就是**电平，没有第二项。
    private func advance(using meter: WatchAudioMeter) {
        var next = samples
        next.append(CGFloat(meter.level))
        if next.count > Self.sampleCount {
            next.removeFirst(next.count - Self.sampleCount)
        }
        samples = next
        lastTickAt = Date()
    }

    // MARK: - 画

    private func render(
        into context: inout GraphicsContext,
        canvas: CGSize,
        time: Double,
        phase: Double
    ) {
        let lineWidth = Self.lineWidth(for: size)

        // ★★ 十三改：基线从**中线**挪到**画布底部**。
        //
        // 0.75 个线宽是给圆头笔帽留的：不留的话，贴底那条线会被自己的
        // 端点切掉一半（圆头是以线宽为直径画的半圆）。
        let baseline = canvas.height - lineWidth * 0.75
        // 同样扣掉两头，免得满幅的尖峰被圆头切平。
        let reach = max(1, canvas.height - lineWidth * 1.5)

        let count = samples.count
        guard count > 1 else { return }
        let step = canvas.width / CGFloat(count - 1)
        let shift = CGFloat(phase) * step

        // 一条很淡的基线。它不是装饰 —— 有了它，"现在没有声音"和
        // "这东西坏了不动了"才分得开（前者是贴着基线的一条平线，后者是一片空）。
        // 它是这张画布上唯一的静态参照物。
        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: baseline))
        axis.addLine(to: CGPoint(x: canvas.width, y: baseline))
        context.stroke(
            axis,
            with: .color(tint.opacity(0.14)),
            style: StrokeStyle(lineWidth: max(1, lineWidth * 0.4), lineCap: .round)
        )

        // 点位。★ 十六改：整体左移一个 `phase`，让它在两次采样之间连续滑动；
        // 末尾再补一个"笔尖"，把最新那一格拉到画布右沿，右边不留空档。
        var points: [CGPoint] = []
        points.reserveCapacity(count + 1)
        for (index, value) in samples.enumerated() {
            let x = CGFloat(index) * step - shift
            // 先把值夹到 0...1：电平理论上就在这个区间，但还是夹一道，
            // 免得任何一处算错都变成一条画出框的线。
            let clamped = min(1, max(0, value))
            points.append(CGPoint(x: x, y: baseline - clamped * reach))
        }
        points.append(CGPoint(x: canvas.width, y: points[count - 1].y))

        var trace = Path()
        trace.move(to: points[0])
        for point in points.dropFirst() {
            trace.addLine(to: point)
        }

        // 曲线下面那层填充。
        //
        // ⚠️ 它的高度**严格等于真实电平**，没有引入任何假数据 —— 差别只在
        //    "它是面，不是线"。用闭合路径手写，而不是拼两个 `Path`：
        //    `fill` 会把**没闭合**的路径自动连回起点，那条边很容易画歪。
        var area = trace
        area.addLine(to: CGPoint(x: canvas.width, y: baseline))
        area.addLine(to: CGPoint(x: points[0].x, y: baseline))
        area.closeSubpath()
        context.fill(area, with: .color(tint.opacity(0.14)))

        // 粒子压在辉光**下面**：辉光叠在粒子上会把它们洗淡。
        drawParticles(into: &context, points: Array(points.prefix(count)), canvas: canvas, time: time)

        // 两层辉光 + 主线，从宽到窄。这就是心电图那种"迹本身在发光"的质感
        // （十六改之前只有最后那一层）。
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

        // 笔尖。停在最新那一格上，跟着一起滑 —— 示波器的那个光标。
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

    /// 上升的粒子。**只从"真的有声音"的那几格冒**。
    ///
    /// ★ 十六改新增（用户："参考手表里面的移动心电图软件里面的粒子特效"）。
    ///
    /// ## 每个粒子怎么算
    /// `noise(index, salt)` 给三样东西：速度（决定多久走一轮）、相位（错开起跳
    /// 时刻）、横向漂移。它们在连续帧里是**同一个值** —— 所以同一个粒子会沿着
    /// 一条固定的线往上飞，而不是每帧乱跳（见文件顶部"十六改 ②"）。
    ///
    /// ## 上升高度为什么取 `min(余量, 该有多高)`
    /// 见文件顶部"十六改 ③"：满量程的尖峰顶上没有空间，硬冲就是被画布切掉。
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
            // 到画布上沿还剩多少地方可去。
            let room = origin.y - lineWidth
            guard room > 2 else { continue }

            // 越响喷得越多：大声时一格两粒，小声一粒。
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

    /// 一个纯函数哈希，给区间 `[0, 1)`。
    ///
    /// ⚠️ 参数是 `index` + `salt` **而不是一个单调序号**：粒子的身份必须只由
    ///    "它从哪一格来"和"它是那一格的第几粒"决定，这样同一格的粒子在整个
    ///    生命周期里算出来的速度/相位都是同一个值。改成一个全局递增的序号，
    ///    每来一格新采样都会把整条轨迹重新洗一遍 —— 那就退化成噪点了。
    private static func noise(_ index: Int, _ salt: Int) -> Double {
        var x = UInt64(truncatingIfNeeded: index &* 73_856_093 &+ salt &* 19_349_663)
        x ^= x >> 33
        x = x &* 0xff51_afd7_ed55_8ccd
        x ^= x >> 33
        return Double(x % 100_000) / 100_000
    }

    /// 线宽按 `size` 取，不写死 —— 40mm 到 49mm 差 40pt，写死会在某一种表上出错。
    ///
    /// ★ 十二改：0.024 → **0.028**（40mm 上 2.9pt → 3.3pt）。画布放大之后同样的
    /// 线宽在画面上会显得更细，跟着加一档才保住原来那点"笔触感"。
    private static func lineWidth(for size: CGFloat) -> CGFloat {
        max(2, size * 0.028)
    }
}
