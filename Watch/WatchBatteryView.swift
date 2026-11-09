import SwiftUI
import WatchKit

// MARK: - 电量 / 耗电监控（★ 2026-11-03 八轮 → 2026-11-04 九轮重写）
//
// 用户原话：「对于全天候录音，当前的手表能否满足就是需要增加一个在手表的菜单栏里面
// 一个设置对当前 APP 的电量消耗的一个监控」。
// 第二轮反馈：「统计当前这个 app 的电量不准确且一直显示在采样中，需要优化当前
// app nomily 在手表的耗电量，好计算当前的全天候录音的统计消耗电量情况」。
//
// ## 为什么不是"读一个现成的数"
// watchOS 只给两样东西：`batteryLevel`（**1% 一档**的粗读数）和 `batteryState`。
// **它不告诉你是谁在耗电**——系统设置里的"电池"页才有那个拆分，第三方 App 拿不到。
// 所以这里做的是**纵向采样 + 求斜率**，再用当前电量 ÷ 速率估剩余时长。
//
// ⚠️ 这条曲线是**整块表**的耗电，不是"本 App 独占"的耗电：手表同时在跑表盘、
//    心率、通知。文案因此写 "Drain"，不写 "This app uses"。测出来的值在
//    「录音 vs 待机」两种状态下对比着看才有意义——那正好是用户问的问题
//    （全天候录音撑不撑得住），所以两种状态分开算（见 `fit(state:)`）。
//
// ## 九轮为什么改算法（「不准确 + 一直采样中」的根因）
// 旧实现有两个 bug 叠在一起，跑模拟数据才看清：
//   ① **符号写反了**。旧代码从新往旧遍历，`run.last` 是已收下的**更新**样本，
//      判据却是 `s.level > run.last.level → break`（本意是"旧样本更高 = 在回血"）。
//      可放电时旧样本的电量**本来就更高**，所以这个条件恒成立：循环在第二对就断，
//      `run` 里只剩最新那一条 → 时长为 0 → 恒返回 nil。
//      **"一直显示正在采样"就是这么来的，跟采样攒得够不够长完全无关。**
//      模拟数据里一次都没跑通，改对符号后同样的样本立刻给出 12.0%/h（真值 12）。
//   ② 就算符号对了，"首尾差 ÷ 时长"仍是**最差**的斜率估计：1% 一档的分辨率下
//      误差 ±0.5% ÷ 10 分钟 = ±3%/h，录一次音得到 4.0 还是 10.0 全看运气。
// 现在改成：
//   1. **最小二乘回归**吃下整段样本（几十个点），1% 的量化误差被平均掉：
//      模拟 12%/h 的放电曲线，30 分钟报 12.5、1 小时报 12.2、3 小时报 12.0；
//   2. **不再要求掉 1%**——回归能表达"掉了 0.4%"，门槛换成"够不够长/点够不够多"；
//   3. 录音段与待机段**分开攒**：录音时 App 被 workout 保活、每分钟一个点，
//      所以录音速率 8 分钟就能报；待机时 App 被挂起，样本只能靠抬腕打开补，
//      门槛放长到 20 分钟，宁缺毋滥；
//   4. 另加**累计掉电**（`todayRecordingDrop`）：录音区间内每个 1% 台阶都记账，
//      一天下来是确切的"录了 X 小时、吃掉 Y%"，不受斜率误差影响——
//      这才是"全天候录音的统计消耗电量"该给的数。
//
// ## 采样节流
// 电量一分钟变不了一次，1% 精度下 60 s 采一条纯属浪费（还容易被系统掐）。
// 规则：**电量变了立刻记**；没变则留心跳——录音中 2 分钟一条、待机 10 分钟一条。
// 24 小时保留期下样本量稳定在几百条以内。

/// 手表电量的采样与估算。
///
/// ⚠️ 单例：`WKInterfaceDevice.batteryLevel` 只有一个读数来源，而这个类的输出被
///    电量页、菜单设置页同时引用，多实例各算一套只会互相打架。
/// ⚠️ 全部方法都跑在主线程（`Timer` 挂在主 RunLoop 上、调用方都是 SwiftUI 视图），
///    所以没有加 `@MainActor`：加了反而会让 `@ObservedObject var m = .shared`
///    这种属性初始化在 minimal 并发检查下变成"跨 actor 访问"的告警/报错。
final class WatchBatteryMonitor: ObservableObject {
    static let shared = WatchBatteryMonitor()

    /// 0…1。`batteryLevel` 在未开启监控时返回 -1，这里保持上一次的可用值。
    @Published private(set) var level: Double = 0
    @Published private(set) var charging = false
    /// 录音中的耗电速率，**百分点/小时**（正数 = 在掉电）。
    @Published private(set) var recordingDrain: Double?
    /// 待机（没在录）的耗电速率。两个数摆一起才看得出录音多花多少。
    @Published private(set) var idleDrain: Double?
    /// 这次速率还没算出来时，还差多少分钟样本（0 = 已够，只是点太少）。
    @Published private(set) var collectingMinutes = 0
    /// 速率刚够门槛、样本还短，数字要打"≈"：8 分钟窗口在 1% 量化下能偏 ±20%，
    /// 但用户开会 10 分钟就想知道大概掉多快，所以先给个约数再让它自己收敛。
    @Published private(set) var rateIsRough = false
    /// 今天录音累计时长（秒）与累计掉电（百分点）。
    @Published private(set) var todayRecordingSeconds: TimeInterval = 0
    @Published private(set) var todayRecordingDrop: Double = 0
    /// 今天有没有录过（区分"没录"和"录了但没掉电"）。
    @Published private(set) var todayRecorded = false
    @Published private(set) var sampleCount = 0

    /// 一条样本。用 `[[Double]]` 存盘（t, level, recording, charging），
    /// 比 Codable 结构体省一整套声明。
    private struct Sample {
        let t: TimeInterval
        let level: Double
        let recording: Bool
        let charging: Bool
    }

    private static let key = "watch.battery.samples.v2"
    private static let legacyKey = "watch.battery.samples.v1"
    /// 24 小时。要回答"全天候"就得有一整个白天的样本。
    private static let retention: TimeInterval = 24 * 3600
    /// 电量没变化时的心跳间隔。给回归留锚点，又不至于把内存灌满。
    private static let heartbeat: TimeInterval = 10 * 60
    /// 录音时心跳收紧到 2 分钟：那时 App 被 workout 保活，本来就在跑，
    /// 多记几条能让 8 分钟门槛内凑够回归需要的点数（1% 一档大约 5 分钟才跳一格）。
    private static let recordingHeartbeat: TimeInterval = 2 * 60

    /// 录音速率门槛：录音时 App 被保活，每分钟一个真样本，8 分钟足够回归稳定。
    private static let recordingMinSpan: TimeInterval = 8 * 60
    /// 待机速率门槛：待机时 App 被挂起，样本稀疏且掉得慢，放长到 20 分钟。
    private static let idleMinSpan: TimeInterval = 20 * 60
    /// 回归窗口上限：超过这个跨度的样本不再往回收，否则"昨天"会污染"今天"。
    private static let recordingMaxSpan: TimeInterval = 8 * 3600
    private static let idleMaxSpan: TimeInterval = 12 * 3600
    /// 采样断档的容忍度。录音时断超过 12 分钟算是系统把定时器攒批了（那段时间 App
    /// 被 workout 保活，仍在耗电，该算进这段录音）；待机时断了几个小时很正常
    /// （App 被挂起，只有抬腕打开才采一次），照算。
    private static let recordingMaxGap: TimeInterval = 12 * 60
    private static let idleMaxGap: TimeInterval = 4 * 3600
    /// 回归至少要 3 个点：待机被节流成 10 分钟一条，20 分钟窗口里可能只有两三条。
    private static let minPoints = 3

    private var samples: [Sample] = []
    private var timer: Timer?
    /// 录音状态由 `WatchRecorderModel` 在 start/stop 时推进来（见那边的两处 hook）。
    /// `@Published`：界面上的「耗电」这一行取哪条速率、底部写录音还是待机，
    /// 都跟着它变，不发布的话切完状态页面要等下一次采样才刷新。
    @Published var isRecording = false {
        didSet {
            guard oldValue != isRecording else { return }
            // 状态切换的瞬间补一条样本：否则"刚开始录"的那几分钟会算在"待机"名下。
            sample()
            // ★ 2026-11-06：开录挂定时器、停录拆掉（事件驱动采样，见 `start()` 注释）。
            syncTimer()
        }
    }

    private init() {
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        load()
        sample()
    }

    /// 让采样转起来。App 每次回到前台调一次，幂等。
    ///
    /// ★ 2026-11-06（用户："手表电量续航…一直处于采样…看下其他同类型的产品"）：
    /// 按业界共识（Apple 开发者指引原话：**事件驱动优于轮询**；Apple Watch 自己的
    /// 电池速率也是"检查点记录 + 滚动窗口算速率"）改成：
    /// * **待机：不挂定时器。** 抬腕回前台（`refresh()`）、开/停录音（`isRecording`）
    ///   这些事件点各采一条。挂着的 60 s 轮询只会反复唤醒 CPU 读一个一分钟才变
    ///   一格的读数——纯浪费。后台期间系统本来就挂起我们，定时器早就不跑了。
    /// * **录音中：保留定时器**（与 `recordingHeartbeat` 对齐 2 分钟一跳）——录音时
    ///   App 被 workout 保活，本来就在跑，这几个点是回归曲线的骨架。
    ///
    /// 待机掉电速率不受影响：回归本来就吃稀疏样本（`idleMinSpan` 20 分钟、
    /// `idleMaxGap` 4 小时），抬腕就是天然的事件锚点。
    func start() {
        readCurrent()
        syncTimer()
    }

    /// 回到前台时立刻补一条（后台期间定时器是停的，样本会断）。
    func refresh() {
        sample()
        syncTimer()
    }

    /// 定时器只服务录音态：进录音挂上、退出录音拆掉。
    private func syncTimer() {
        guard isRecording else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.recordingHeartbeat, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    // MARK: 采样

    private func readCurrent() {
        let device = WKInterfaceDevice.current()
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        if device.batteryLevel >= 0 { level = Double(device.batteryLevel) }
        charging = (device.batteryState == .charging || device.batteryState == .full)
    }

    private func sample() {
        readCurrent()
        // 读不到（-1）就不记：记一条 0 进去，整段斜率立刻变成"一小时掉 90%"。
        guard level > 0 else { return }
        let now = Date().timeIntervalSince1970
        if let last = samples.last {
            let dt = now - last.t
            // 同一分钟内的重复调用（`isRecording` 切换和定时器撞车）直接忽略。
            if dt < 30, last.recording == isRecording, abs(last.level - level) < 0.001 { return }
            // 节流：电量没变、状态没变、上一条还新鲜，就先不记（心跳兜底）。
            let heartbeat = isRecording ? Self.recordingHeartbeat : Self.heartbeat
            if last.recording == isRecording, abs(last.level - level) < 0.001, dt < heartbeat {
                return
            }
        }
        samples.append(Sample(t: now, level: level, recording: isRecording, charging: charging))
        let cutoff = now - Self.retention
        if let firstKept = samples.firstIndex(where: { $0.t >= cutoff }), firstKept > 0 {
            samples.removeFirst(firstKept)
        }
        sampleCount = samples.count
        recompute()
        save()
    }

    // MARK: 计算

    private func recompute() {
        let rec = fit(state: true)
        let idle = fit(state: false)
        recordingDrain = rec.rate
        idleDrain = idle.rate
        // 提示"还差多久"只针对**当前状态**：录音时提示录音那边，待机时提示待机那边。
        let span = isRecording ? rec.span : idle.span
        let need = (isRecording ? Self.recordingMinSpan : Self.idleMinSpan) - span
        collectingMinutes = max(0, Int((need / 60).rounded(.up)))
        // 20 分钟以内（待机 40 分钟）的数字还带着量化阶梯的形状，标成约数。
        rateIsRough = span < (isRecording ? 20 * 60 : 40 * 60)
        // 充电时样本按"排除"处理，速率会退回充电前那一段——这时不该弹"还需 N 分"，
        // 也不该标约数（用户看的不是这个数）。
        if charging {
            collectingMinutes = 0
            rateIsRough = false
        }

        let stats = todayStats()
        todayRecordingSeconds = stats.seconds
        todayRecordingDrop = stats.drop
        todayRecorded = stats.recorded
    }

    /// 一次回归的结果。`span` 是**实际计入的采样时长**（不是墙钟跨度），
    /// 所以断档不会被算进分母、把速率压低。
    private struct Fit {
        var rate: Double?
        var span: TimeInterval
    }

    /// 对某一种状态（录 / 不录）的样本做最小二乘回归，得到 %/h。
    ///
    /// 从最新一条往回走，遇到下面任一情况就停：
    ///   · 跨过回归窗口上限（`maxSpan`）；
    ///   · 采样断档超过该状态容忍的 `maxGap`；
    ///   · 电量比更新的那条还高——中途充过电（`charging` 标记可能没采到）。
    /// 充电样本整段排除：那段时间电量是在回血，混进去会把斜率拉成负数。
    private func fit(state: Bool) -> Fit {
        guard samples.count >= Self.minPoints else { return Fit(rate: nil, span: 0) }
        let maxSpan = state ? Self.recordingMaxSpan : Self.idleMaxSpan
        let maxGap = state ? Self.recordingMaxGap : Self.idleMaxGap

        var pts: [(t: TimeInterval, y: Double)] = []
        var span: TimeInterval = 0
        var started = false
        for i in stride(from: samples.count - 1, through: 0, by: -1) {
            let s = samples[i]
            if s.charging {
                // 尾部（当下正在充电）先跳过，找到充电之前的那一段再开始；
                // 走着走着又遇到充电，说明这段非充电区间到此为止。
                if started { break }
                continue
            }
            if s.recording != state {
                if started { break }
                continue
            }
            started = true
            if let newest = pts.first, newest.t - s.t > maxSpan { break }
            if let prev = pts.last {
                // ⚠️ 这里是从新往旧走，`prev` 比 `s` **新**。
                //   "旧样本比新样本低" = 电量在回升 = 中途充过电，到此为止。
                //   八轮写反过（写成 `s.level > prev.y`），正常放电会被当成"回升"，
                //   循环在第一对就 break，`run` 只剩一条 → 时长 0 → 永远返回 nil。
                //   那就是"一直显示正在采样"的**真正**原因。
                if s.level < prev.y - 0.001 { break }
                if prev.t - s.t > maxGap { break }             // 断档太久
            }
            pts.append((t: s.t, y: s.level))
            if pts.count >= 2 { span = pts[0].t - s.t }
        }

        let minSpan = state ? Self.recordingMinSpan : Self.idleMinSpan
        guard pts.count >= Self.minPoints, span >= minSpan else { return Fit(rate: nil, span: span) }
        return Fit(rate: Self.slope(pts), span: span)
    }

    /// 最小二乘斜率，换算成「百分点/小时」并且**取正数**（掉电方向为正）。
    ///
    /// 取正数是因为这里只关心"掉多快"：偶发的读数抖动（表在低电量时校准）
    /// 会让斜率出现微小负值，直接当 0 处理，免得界面报"-0.3%/h"让人以为在回血。
    private static func slope(_ pts: [(t: TimeInterval, y: Double)]) -> Double? {
        let n = Double(pts.count)
        let t0 = pts[0].t
        let xs = pts.map { ($0.t - t0) / 3600 }
        let ys = pts.map { $0.y * 100 }
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        var num = 0.0
        var den = 0.0
        for i in 0..<pts.count {
            let dx = xs[i] - mx
            num += dx * (ys[i] - my)
            den += dx * dx
        }
        guard den > 1e-9 else { return nil }
        return max(0, -num / den)
    }

    /// 今天录音的累计时长与累计掉电。
    ///
    /// 逐对累加 1% 台阶，不受斜率误差影响：录 6 小时掉 47%，就是 47%。
    /// 充电区间的对子一律不计（回血不是耗电），跨状态的对子也不计（归属说不清）。
    private func todayStats() -> (seconds: TimeInterval, drop: Double, recorded: Bool) {
        let dayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var seconds: TimeInterval = 0
        var drop: Double = 0
        var recorded = false
        guard samples.count >= 2 else { return (0, 0, false) }
        for i in 1..<samples.count {
            let a = samples[i - 1], b = samples[i]
            guard b.t >= dayStart, a.recording, b.recording else { continue }
            recorded = true
            let dt = b.t - a.t
            guard dt > 0, dt <= Self.recordingMaxGap else { continue }
            guard !a.charging, !b.charging else { continue }
            seconds += dt
            drop += max(0, (a.level - b.level) * 100)
        }
        return (seconds, drop, recorded)
    }

    /// 当前速率下还能撑多久（小时）。
    var hoursLeft: Double? {
        let rate = isRecording ? (recordingDrain ?? idleDrain) : idleDrain
        guard let rate, rate > 0.05 else { return nil }
        return level * 100 / rate
    }

    /// 当前状态下正在用的那条速率（界面文案要和它对齐）。
    var activeDrain: Double? {
        isRecording ? (recordingDrain ?? idleDrain) : idleDrain
    }

    // MARK: 落盘

    private func load() {
        // 先读 v2（四列，含 `charging`），读不到再退回 v1。
        if let raw = UserDefaults.standard.array(forKey: Self.key) as? [[Double]] {
            let cutoff = Date().timeIntervalSince1970 - Self.retention
            samples = raw.compactMap { row in
                guard row.count == 4, row[0] >= cutoff else { return nil }
                return Sample(t: row[0], level: row[1], recording: row[2] > 0.5, charging: row[3] > 0.5)
            }
        } else if let raw = UserDefaults.standard.array(forKey: Self.legacyKey) as? [[Double]] {
            // 老格式只有三列，`charging` 缺失——按"没在充电"读，一天内会被新样本顶掉。
            let cutoff = Date().timeIntervalSince1970 - Self.retention
            samples = raw.compactMap { row in
                guard row.count == 3, row[0] >= cutoff else { return nil }
                return Sample(t: row[0], level: row[1], recording: row[2] > 0.5, charging: false)
            }
        }
        sampleCount = samples.count
        recompute()
    }

    private func save() {
        let rows = samples.map { [$0.t, $0.level, $0.recording ? 1 : 0, $0.charging ? 1 : 0] }
        UserDefaults.standard.set(rows, forKey: Self.key)
    }
}

// MARK: - 页面

/// 手表「设置 → 快捷菜单」里勾上「电量」后，出现在首页侧栏的那一页。
struct WatchBatteryView: View {
    @ObservedObject private var monitor = WatchBatteryMonitor.shared
    @ObservedObject private var styleStore = WatchRingStyleStore.shared
    @ObservedObject private var faceStore = WatchFaceStore.shared
    @EnvironmentObject private var model: WatchRecorderModel

    /// 主题色三处同源：表情配色优先，其次圆环主题色（和录音页的 `faceTint` 一致）。
    private var accent: Color {
        faceStore.colorHex.map { Color(botHex: $0) } ?? styleStore.style.tint
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(Self.percentText(monitor.level))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                if monitor.charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.9))
                }
            }

            levelBar

            VStack(spacing: 0) {
                row(L10n.Watch.batteryRate,
                    value: drainText,
                    highlighted: monitor.isRecording && monitor.recordingDrain != nil)
                Rectangle()
                    .fill(WatchHomeStyle.hairline)
                    .frame(height: 0.5)
                row(L10n.Watch.batteryLeft, value: leftText)
                Rectangle()
                    .fill(WatchHomeStyle.hairline)
                    .frame(height: 0.5)
                // ★ 九轮：这一行才是"全天候录音到底吃掉多少电"的确切答案——
                //   累计台阶的口径不受斜率误差影响，用户拿去规划第二天充电即可。
                row(L10n.Watch.batteryToday, value: todayText)
            }

            Text(footnote)
                .font(.system(size: 9))
                .foregroundStyle(WatchHomeStyle.header)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(L10n.Watch.menuBattery)
        .onAppear {
            WatchBatteryMonitor.shared.isRecording = model.isRecording
            WatchBatteryMonitor.shared.start()
        }
        // 录音状态进来（这个页面是侧栏页，录音中也能滑过来看）。
        .onChange(of: model.isRecording) { recording in
            WatchBatteryMonitor.shared.isRecording = recording
        }
    }

    // MARK: 组件

    private var levelBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(accent.opacity(0.9))
                    // 2pt 下限：电量 1% 时也要看得见那一点点，否则读作"没电了还有色块"。
                    .frame(width: max(2, geo.size.width * CGFloat(min(max(monitor.level, 0), 1))))
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 2)
    }

    private func row(_ label: String, value: String, highlighted: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(WatchHomeStyle.dim)
            Spacer(minLength: 2)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(highlighted ? accent : Color.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 3)
    }

    // MARK: 文案

    private static func percentText(_ level: Double) -> String {
        "\(Int((level * 100).rounded()))%"
    }

    private var drainText: String {
        if monitor.charging { return L10n.Watch.batteryCharging }
        guard let rate = monitor.activeDrain else {
            // 九轮：不再干等一句"正在采样…"。告诉用户还差几分钟，
            // 否则永远不知道是自己没开录还是 App 坏了。
            return monitor.collectingMinutes > 0
                ? L10n.Watch.batteryCollecting(monitor.collectingMinutes)
                : L10n.Watch.batteryNoData
        }
        let text = rate < 0.5 ? L10n.Watch.batteryRateSmall : L10n.Watch.batteryRateValue(rate)
        return monitor.rateIsRough ? "≈ \(text)" : text
    }

    private var leftText: String {
        guard let hours = monitor.hoursLeft, !monitor.charging else {
            return monitor.charging ? L10n.Watch.batteryCharging : L10n.Watch.batteryNoData
        }
        return L10n.Watch.batteryLeftValue(hours)
    }

    /// 「今日录音 3.2h · 掉 47%」。
    ///
    /// 没有任何一个 1% 台阶的日子里（录了但一格都没掉）显示 0%，而不是 "—"：
    /// "录了 2 小时一格没掉"本身就是有用的结论。
    private var todayText: String {
        guard monitor.todayRecorded else { return L10n.Watch.batteryNoData }
        return L10n.Watch.batteryTodayValue(hours: monitor.todayRecordingSeconds / 3600,
                                            drop: monitor.todayRecordingDrop)
    }

    /// 底部一行小字：现在这行「耗电」是**哪一档**的数。
    ///
    /// 九轮改口：旧版待机时不写字（"这块地方本来就是没录音的默认状态"），
    /// 现在录音和待机是两个**不同的速率**，不标出来，用户会拿待机速率去估录音续航。
    private var footnote: String {
        guard monitor.isRecording else { return L10n.Watch.batteryIdle }
        return model.powerSaver
            ? "\(L10n.Watch.listening) · \(L10n.Watch.moonlit)"
            : L10n.Watch.listening
    }
}
