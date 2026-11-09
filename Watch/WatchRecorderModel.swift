import AVFoundation
import Foundation
import WatchKit
import os.log

private let log = Logger(subsystem: "com.nomily.app.watch", category: "recorder")

/// A clip on the watch that hasn't been confirmed by the iPhone yet.
struct PendingClip: Identifiable {
    let url: URL
    let bytes: Int64

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var displayTitle: String { RecordingName.displayTitle(for: name) }
}

/// The live level the waveform needs while recording.
///
/// ★ added in the 2026-10-16 ninth revision (user: "when recording starts it should be a waveform like the heart rate").
///
/// ## Why not two separate values
/// It could have been split into `level: Float` + `tick: Int` as two `@Published`s, but then every tick
/// would fire two rounds of object changes. Combining them into one `Equatable` struct means the view side needs just one
/// `onChange(of: meter)`.
///
/// ## ⚠️ `tick` isn't superfluous
/// **When quiet, `level` is always 0, so `onChange(of: level)` never fires at all** —
/// and the waveform would freeze there, killing the "heartbeat". With a monotonically increasing `tick`, the waveform advances
/// one slot per tick and keeps moving even when quiet.
struct WatchAudioMeter: Equatable {
    /// The instantaneous level normalised to 0...1.
    var level: Float = 0
    /// A monotonically increasing sample index. See the block above — its only reason to exist is so that "something changes" even when quiet.
    var tick: Int = 0
}

/// Wrist recorder. AAC-in-M4A at 24 kHz mono / 48 kbps — roughly 21 MB/hour,
/// which is the balance the Ultra prototype settled on between speech clarity
/// and multi-hour sessions.
///
/// Clips are named `yyyyMMddHHmmss.m4a` so they parse through `RecordingName`
/// exactly like device clips do and sort into the phone's Library by recording
/// time. The watch-side copy is deleted once WatchConnectivity confirms the
/// phone has it; until then the clip stays here and is re-queued on launch.
@MainActor
final class WatchRecorderModel: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var currentBytes: Int64 = 0
    /// The live level while recording, for the home screen's waveform. **It only changes while recording** —
    /// it's zeroed on stop, so the idle state doesn't push the view to redraw a dozen times a second.
    @Published private(set) var meter = WatchAudioMeter()
    @Published private(set) var pending: [PendingClip] = []
    @Published var errorMessage: String?
    /// ★ 2026-10-30（用户："录音断联需要状态弹出提醒告知，点击或者在附近就重连"）：
    /// 录音期间与手机断联的提醒状态。`true` 时录音界面弹 alert，
    /// 「重连」按钮走 `reconnectNow()`；手机回到附近（可达性恢复）自动清除并补发。
    @Published private(set) var linkLost = false

    /// ★ 2026-11-03 八轮（用户："有些需要标记重点的，能否在手表下方按一下就打点"）：
    /// 这一段录音里已经被打点的时间点（秒，相对录音开头）。
    ///
    /// ⚠️ 单位是 `elapsed` 而不是绝对时间：录音可以暂停/被系统打断（那时 `currentTime`
    ///    冻结），用绝对时钟算出来的点会跑到音频的后面去。`elapsed` 就是音频自己的
    ///    时间轴，与转写/摘要能对齐。
    @Published private(set) var marks: [TimeInterval] = []

    /// 整场录音已经打过多少个点（跨分段累加）。
    ///
    /// ★ 分钟级的分段轮转会清空 `marks`（每个文件只带自己那段的时间点），
    ///   但用户眼里这是**一场**录音——底部那枚胶囊上的数字如果每 15 分钟归零，
    ///   看起来就像"点丢了"。
    @Published private(set) var totalMarks = 0

    // MARK: - 滚动分段（★ 2026-11-03 八轮，"全天候录音按建议来"）
    //
    // 用户拍板的方案：「超过 30 分钟自动切 15 分钟段 + 只在充电或非省电时立即回传」。
    //
    // ## 为什么必须切段
    // `AVAudioRecorder` 一次只写**一个**文件，写到一半的文件拷出去是坏文件——
    // 所以"边录边传"在单文件模型下根本做不到。切段之后，已经收口的那几段
    // 就是**完整可用的音频**，可以立刻排队回传：崩溃/断电的最大损失从"整段"
    // 降到"最多 15 分钟"，待传积压也不会越滚越大。
    //
    // ## 代价（必须写在这儿，别当它不存在）
    // `stop()` → 新 `AVAudioRecorder.record()` 之间有一小段空档（真机实测几十到
    // 一百多毫秒），那一段空气里说的话会丢。所以**短录音永远不切**：
    // 首段给到 30 分钟，之后每 15 分钟一刀——开会记一小时，最多两刀。
    //
    // ⚠️ `segmentOffset` 是"已经切走的时长之和"。界面上的计时 = offset + 新文件的
    //    `currentTime`，用户看到的仍是这一场录音连续的总时长，不会每一段都从 00:00 重来。
    private var segmentOffset: TimeInterval = 0
    /// 本段开始时的**逻辑**时间点（含已切走的部分），用于算这一段够不够长。
    private var segmentStart: TimeInterval = 0
    /// 首段上限：30 分钟。
    static let firstSegmentLimit: TimeInterval = 30 * 60
    /// 之后每段上限：15 分钟。
    static let segmentLimit: TimeInterval = 15 * 60

    private let link: WatchLink
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var intentObserver: NSObjectProtocol?
    private var startedAt: Date?
    private var lastPush = Date.distantPast
    /// `true` between "the system interrupted our audio" and "the interruption ended".
    ///
    /// ★ 2026-10-20: while this is set the recorder is **paused**, not stopped —
    /// `AVAudioRecorder.pause()` keeps the file and the clock (`currentTime` freezes,
    /// so elapsed time excludes the interruption automatically).
    private var interrupted = false
    /// Installed once per model lifetime. Re-registering per recording would stack
    /// observers (each delivering the first interruption N times).
    private var interruptionHandlersInstalled = false

    /// How often the phone is re-told a take is still running.
    ///
    /// ★ 2026-10-23 (功耗优化): was 10 s. A heartbeat is one
    /// `updateApplicationContext` write — cheap per call, but a 10 s beat also
    /// wakes the radio hourly on long takes. 30 s keeps the phone's staleness
    /// window meaningful (its watchdog calls a beat stale after 90 s of
    /// silence, i.e. three missed beats) while cutting context writes by ⅔.
    private static let heartbeatInterval: TimeInterval = 30

    /// The level meter's sampling interval — 12.5Hz.
    ///
    /// ★ 2026-10-16 revision nine: this meter used to tick at **1 second** (just to refresh the timer). A 1-second refresh rate
    /// can't draw a waveform: the waveform would only move one slot per tick, looking like a slideshow rather than sound.
    ///
    /// ⚠️ 12.5Hz is a considered trade-off: faster (30Hz) is indistinguishable to the eye on a 40mm watch, yet more than
    /// doubles the redraw cost; slower starts to feel juddery, "jumping a slot at a time".
    private static let meterInterval: TimeInterval = 0.08

    /// The reciprocal of `meterInterval`. Used to pick the "once a second" part of the work (timer, byte count)
    /// out of the 12.5Hz tick.
    private static let meterTicksPerSecond = 12

    // ★ 2026-11-02（用户："手表需要为全天候录音设置，这个功耗跟传输需要优化"）：
    // 「全天候录音」= 省电模式。录音本体（麦克风 + 文件写入）一根毫毛都不动，
    // 动的只有"给人看的部分"和"回传的时机"：
    //
    // | 项 | 常规 | 省电 |
    // |---|---|---|
    // | 电平采样 | 12.5Hz | 2Hz（0.5s 一次；波形变钝，但每小时的定时器唤醒从 ~45,000 降到 ~7,200） |
    // | 波形重绘 | 30fps | 2fps（见 `WatchVoiceWave.lowPower`） |
    // | 回传时机 | 每段录音结束立即发 | **攒着**：充电中、或关掉开关时自动补传；「立即同步」随时可用 |
    //
    // ⚠️ 为什么回传是功耗大头：每段结束就发一次 WCSession 文件传输会唤醒双方射频；
    //   全天候场景下录音是几十段地攒，攒一批一起发比逐段发省得多——
    //   而且塞在充电时发，电池曲线根本看不出来。
    private static let meterIntervalSaver: TimeInterval = 0.5
    private static let meterTicksPerSecondSaver = 2

    /// 当前生效的采样间隔 / 每秒 tick 数（随 `powerSaver` 切换）。
    private var meterIntervalNow: TimeInterval {
        powerSaver ? Self.meterIntervalSaver : Self.meterInterval
    }
    private var meterTicksPerSecondNow: Int {
        powerSaver ? Self.meterTicksPerSecondSaver : Self.meterTicksPerSecond
    }

    /// 省电模式开关。由设置页经 `setPowerSaver(_:)` 推过来（App 启动时也会同步一次）。
    ///
    /// ★ 2026-11-03：改成 `@Published`——V4 的录音页要显示「已攒 N 段」chip 和
    /// MOONLIT 徽章，这两处都直接读它；原来是个裸属性，翻开关时界面靠别的
    /// `@ObservedObject` 顺带刷新，属于碰巧能work，不敢再依赖。
    @Published private(set) var powerSaver = false

    /// 「正在暂缓回传」= 省电开着 **且** 没在充电。同步页拿它显示提示条。
    var transfersDeferred: Bool { powerSaver && !Self.isCharging }

    /// 手表是否在充电（或已充满）。
    ///
    /// ⚠️ `isBatteryMonitoringEnabled` 必须先打开，否则 `batteryState` 恒为 `.unknown`——
    ///    这是 WKInterfaceDevice 的一个经典坑，不开监控读到的永远是"未知"，
    ///    而"未知"在这里会被当成"没在充电"，省电模式下插着电也不补传。
    static var isCharging: Bool {
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        let state = device.batteryState
        return state == .charging || state == .full
    }

    /// 由设置页调用（幂等）。关掉时把攒下的待传一次性补发。
    func setPowerSaver(_ on: Bool) {
        guard powerSaver != on else { return }
        powerSaver = on
        if isRecording {
            // 录音中切换：按新频率重建采样定时器（startTimer 自己会先 invalidate 旧的）。
            startTimer()
        }
        if !on {
            // 关掉 = 用户要回到"录完即发"的节奏，把积压的一次性清掉。
            resendPending()
        }
        log.info("power saver \(on ? "on" : "off", privacy: .public)")
    }

    /// Felt, not heard. `.start` / `.stop` are the workout-style haptics, and
    /// those drive the speaker as well as the Taptic Engine — an audible beep
    /// at the top and tail of a take, which lands in the recording of the very
    /// meeting you're trying to capture. `.click` is the tactile-only tick the
    /// Digital Crown uses.
    private static let confirmation: WKHapticType = .click

    /// 起止触感：**开始时一声 1 秒长震；结束时两段 1 秒长震、中间隔 1 秒**
    /// （2026-11-04 第二轮，用户："需要长震动震动大的，震动一下的启动录音需要震动 1s，
    /// 震动 2 下…停止录音"）。
    ///
    /// ## 为什么是"连发"而不是换一种触感
    /// watchOS **没有 Core Haptics**（这是 iOS 才有的框架），`WKHapticType` 全是系统定长的
    /// 固定花样：`.click` 最短、`.notification` 是两下轻敲，**没有任何一种是"持续 1 秒"的**。
    /// 想让手腕真的麻一下，只能拿重触感当鼓点连发——每 `pulseInterval` 一发，
    /// 串成一段连续的震感。间隔再密系统会丢包，反而变成断开的几下。
    ///
    /// ## 节奏
    /// * 开始 = 1 段（1.0 s）→ 干脆的一下；
    /// * 结束 = 2 段（1.0 s + 1.0 s 间隔 + 1.0 s）→ 明显是"两下"，与开始区分得开。
    /// 间隔想改长/改短，只动 `pulseGap`；每段长短动 `pulseSeconds`。
    ///
    /// 🔁 同一时间只留一条队列：手快的人"停—立刻又开"时，上一段没放完的震动会盖在
    ///    开录那一下上，听着像乱震。
    /// ★ 2026-11-05 第二轮（用户："需要达到类似其他的 app 的最大震动，当前这个
    /// 震动太小没任何反馈"）：`.click` 是 Digital Crown 那种轻点，是全表**最轻**的
    /// 触感，连发出来也只是细密的麻——用户感觉"没任何反馈"。换成 `.failure`
    /// （heavy double knock，Apple 全部触感里最重的一档），连发间隔放宽到
    /// 140 ms：重触感本身更长，再密系统就会丢包。
    ///
    /// ★ 2026-11-05 第三轮（用户："震动大小分 5 个等级供用户选择"）：触感类型与
    /// 单段时长随 `WatchRecordingPrefs.hapticLevel` 走（设置页可调）：
    ///
    /// | 级 | 触感 | 单段 | 体感 |
    /// |---|---|---|---|
    /// | 1 | `.click` | 0.3s | 轻点一下（原来那副"没反馈"的样子） |
    /// | 2 | `.notification` | 0.5s | 两下轻敲 |
    /// | 3 | `.failure` | 0.7s | 重敲但短 |
    /// | 4 | `.failure` | 1.0s | 重长震（默认，原"最大震动"档） |
    /// | 5 | `.failure` | 1.4s | 最长最密（间隔收窄到 0.13s） |
    private static let pulseInterval: TimeInterval = 0.14
    private static let pulseGap: TimeInterval = 1.0

    /// 等级 → (触感类型, 单段时长, 连发间隔)。见上表。
    private static func hapticProfile(for level: Int) -> (type: WKHapticType, seconds: TimeInterval, interval: TimeInterval) {
        switch level {
        case 1: return (.click, 0.3, 0.14)
        case 2: return (.notification, 0.5, 0.14)
        case 3: return (.failure, 0.7, 0.14)
        case 5: return (.failure, 1.4, 0.13)
        default: return (.failure, 1.0, 0.14)   // 4 = 默认档
        }
    }

    private var hapticQueue: Task<Void, Never>?

    /// 设置页选触感等级时的试听：按当前等级放**一段**（花样另有专门的试听，这里只听力度）。
    func previewHaptic() {
        hapticQueue?.cancel()
        let device = WKInterfaceDevice.current()
        let profile = Self.hapticProfile(for: WatchRecordingPrefs.shared.clampedHapticLevel)
        hapticQueue = Task {
            let ticks = max(1, Int((profile.seconds / profile.interval).rounded()))
            for _ in 0..<ticks {
                if Task.isCancelled { return }
                device.play(profile.type)
                try? await Task.sleep(nanoseconds: UInt64(profile.interval * 1_000_000_000))
            }
        }
    }

    // MARK: ★ 2026-11-05 第二轮（用户："停止录音跟结束录音震动效果也要多出几个"）
    //
    // 起止录音的**花样**。watchOS 没有 Core Haptics，`WKHapticType` 只有固定几种且都是定长，
    // 所以"花样"只能靠「触感类型 + 连发几段 + 段间隔 + 每段长短」拼出来。力度（1–5 档）
    // 决定单段的基准长度与类型，花样在此基础上做缩放：
    //
    // ★ 第三轮（用户："震动样式里面分启动震动跟结束震动…启动震动一下结束震动 2 下，
    //   然后给不同的震动样式选择"）：启动与结束**各选各的**（`startPattern` / `stopPattern`），
    //   默认一下开、两下收——"一下=开录、两下=收工"的暗号保持不变。
    //
    // | 花样 | 段数 × 时长系数 | 段间隔 | 体感 |
    // |---|---|---|---|
    // | `.single` | 1 × 1.0 | — | 默认的开录：就一下 |
    // | `.double` | 2 × 1.0 | 1.00 s | 默认的结束：两下＝收工（老用户无感） |
    // | `.triple` | 3 × 0.6 | 0.55 s | 三连短敲，更急促、更"确认" |
    // | `.singleLong` | 1 × 1.6 | — | 一下到底的长嗡，最干脆 |
    // | `.heartbeat` | 4 段：0.45 / 0.45 / 0.55 / 0.55 | 0.18 / 0.85 / 0.18 | 心跳两拍（快快-停-快快） |
    // | `.crescendo` | 3 段：0.5 / 1.0 / 1.7 | 0.35 / 0.35 | 轻→中→重，渐强收尾 |
    //
    // ⚠️ 段间隔不能靠"缩短单段"实现：`device.play` 是异步排队的，同一时刻只能有一段在震，
    //    真正的"停"必须由 `Task.sleep` 撑出来，所以下面用 (段时长, 段后停顿) 的序列描述花样。

    /// 一段触感：`seconds` 是这一段的时长（会换算成 tick 数），`gap` 是这段**播完之后**的停顿。
    private typealias HapticBeat = (seconds: TimeInterval, gap: TimeInterval)

    /// 把花样展开成 beats。`base` 是当前力度档的 (类型, 单段时长, 连发间隔)。
    private static func beats(
        for pattern: WatchHapticPattern,
        base: (type: WKHapticType, seconds: TimeInterval, interval: TimeInterval)
    ) -> [HapticBeat] {
        func beat(_ scale: Double, gap: TimeInterval) -> HapticBeat {
            (base.seconds * scale, gap)
        }
        switch pattern {
        case .single:
            return [beat(1.0, gap: 0)]
        case .double:
            return [beat(1.0, gap: Self.pulseGap), beat(1.0, gap: 0)]
        case .triple:
            return [beat(0.6, gap: 0.55), beat(0.6, gap: 0.55), beat(0.6, gap: 0)]
        case .singleLong:
            return [beat(1.6, gap: 0)]
        case .heartbeat:
            // 心跳：两拍快、停一下、再两拍。后两拍比前两拍稍长一点，像心室收缩。
            return [beat(0.45, gap: 0.18), beat(0.45, gap: 0.85),
                    beat(0.55, gap: 0.18), beat(0.55, gap: 0)]
        case .crescendo:
            return [beat(0.5, gap: 0.35), beat(1.0, gap: 0.35), beat(1.7, gap: 0)]
        }
    }

    /// 按指定花样播一轮（起止共用，花样从设置页来）。
    ///
    /// 只有 1 段的类型（`.click` / `.notification` / `.failure`）本身就有固定长短，
    /// 我们靠**连发 tick 数**把段撑长/收短——`interval` 越小，重合越密，体感越"实"。
    private func playPattern(_ pattern: WatchHapticPattern) {
        hapticQueue?.cancel()
        let device = WKInterfaceDevice.current()
        let profile = Self.hapticProfile(for: WatchRecordingPrefs.shared.clampedHapticLevel)
        let beats = Self.beats(for: pattern, base: profile)
        hapticQueue = Task {
            for (index, beat) in beats.enumerated() {
                if Task.isCancelled { return }
                let ticks = max(1, Int((beat.seconds / profile.interval).rounded()))
                for _ in 0..<ticks {
                    if Task.isCancelled { return }
                    device.play(profile.type)
                    try? await Task.sleep(nanoseconds: UInt64(profile.interval * 1_000_000_000))
                }
                if beat.gap > 0, index < beats.count - 1 {
                    // 把"连发最后一 tick 的余量"扣掉，否则实测间隔会比表上长一个 interval。
                    let wait = max(0, beat.gap - profile.interval)
                    if wait > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    }
                }
            }
        }
    }

    /// 开始录音：按设置页的"启动震动"花样（默认一下）。
    private func playStartHaptics() {
        playPattern(WatchRecordingPrefs.shared.startPattern)
    }

    /// 结束录音：按设置页的"结束震动"花样（默认两下）。
    private func playStopHaptics() {
        playPattern(WatchRecordingPrefs.shared.stopPattern)
    }

    /// 设置页换启动花样时的试听：完整放一遍（只听一段听不出节奏差别）。
    func previewStartHaptic() { playStartHaptics() }

    /// 设置页换结束花样时的试听：完整放一遍。
    func previewStopHaptic() { playStopHaptics() }

    init(link: WatchLink) {
        self.link = link
        super.init()
        intentObserver = NotificationCenter.default.addObserver(
            forName: RecordingIntentBus.didRequestToggle,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.consumePendingToggle() }
        }
        // Covers the other order: the Action Button's intent ran before this
        // model existed.
        consumePendingToggle()
        link.onStored = { [weak self] name in self?.discard(named: name) }
        // ★ 2026-10-30: 可达性变化 → 断联提醒（见 handleReachability）。
        link.onReachabilityChanged = { [weak self] reachable in
            Task { @MainActor in self?.handleReachability(reachable) }
        }
        // ★ 2026-11-03：用户点了断联通知（或通知上的「重连」动作）→ 走同一条
        // 重连路径，和点应用内 alert 的「重新连接」完全一样。
        WatchLinkNotifier.shared.onReconnectRequest = { [weak self] in
            Task { @MainActor in self?.reconnectNow() }
        }
        #if targetEnvironment(simulator)
        // Simulator-only delivery has no transferUserInfo ack path; once the file lands in the shared inbox
        // it counts as delivered (see `WatchLink.transferViaSimulatorSharedInbox`).
        // Reuse `discard`: it already does reloadPending + pushState, so the pending list
        // and the phone-side state are cleared together.
        link.onSimulatorDelivered = { [weak self] name in self?.discard(named: name) }
        #endif
        // Anything an earlier launch left behind — a transfer that was never
        // queued because the session wasn't live yet, or one the app died
        // before delivering — gets another shot as soon as the link is up.
        link.onActivated = { [weak self] in self?.resendPending() }
        reloadPending()
    }

    deinit {
        if let intentObserver {
            NotificationCenter.default.removeObserver(intentObserver)
        }
    }

    // MARK: - recording

    func toggleRecording() {
        // ★ Diagnostic log added 2026-10-14 -- do not delete, see the comment on `consumePendingToggle`.
        //
        // Origin: on the watchOS simulator the app starts recording by itself right after `launch`
        // (real-device log shape: `14:11:15.565 [recorder] recording to <stamp>.m4a`
        // appears less than 1 second after launch, and 1.1 seconds later `queued` is sent out).
        // Yet the line `toggling from the Action Button intent` in `consumePendingToggle`
        // **never appeared even once** -- meaning `RecordingIntentBus.pendingToggle` was false,
        // i.e. it was **not** the Action Button path. The only remaining entry point is this function.
        // This line answers "how many times was it called, and what state was it in each time".
        log.info("toggleRecording: isRecording=\(self.isRecording, privacy: .public)")
        // 用户手动碰了录音键 = 人的意图盖过手机的定时命令，待补的远程 start 作废。
        remoteStartPending = false
        // ★ 2026-11-06（全天候语义）：录音键也是用户的手，停 = 关开关语义，
        // 走 stopByUser（全天候开着时先翻开关再停，见该方法注释）。
        isRecording ? stopByUser() : requestPermissionAndStart()
    }

    /// ★ 2026-11-05 第四轮（用户："点击了全天候录音的开关则需要自动就开启了录音，
    /// 不要手动去点击"）：全天候开关被翻开的瞬间自动开录。
    ///
    /// 调用点（两条路都收口到这里）：
    /// ① 手表设置页翻开关（`WatchSettingsView` 的 onChange）；
    /// ② 手机端翻开关经 WatchConnectivity 推过来（`NomilyWatchApp` 的 `onAllDaySetting`）。
    ///
    /// 幂等：已在录、或上一场开录还卡在重试梯子里（`startAttempt > 0` /
    /// `startRetryTask` 挂着）都不再起第二场——多个入口几乎同时触发时只会开一次。
    ///
    /// ★ 2026-11-06（全天候语义）：第四轮注释里"反方向不自动停，用户手动按停
    /// 全天候开着也尊重"已废弃——用户拍板的新语义是**全天候开着就不存在不录音
    /// 这么一说**：`stop()` 末尾检测开关还开着就回到这里续一场；用户想停只有
    /// 关开关一条路（`stopByUser()`，表上设置页 / 手机端同理）。
    func autoStartForAllDayIfNeeded() {
        guard WatchRecordingPrefs.shared.allDayRecording,
              !isRecording, startAttempt == 0, startRetryTask == nil else { return }
        log.info("all-day toggled on — auto-starting take")
        requestPermissionAndStart()
    }

    /// Runs the Action Button's request, once, whenever the recorder gets to it.
    func consumePendingToggle() {
        guard RecordingIntentBus.pendingToggle else { return }
        RecordingIntentBus.pendingToggle = false
        log.info("toggling from the Action Button intent")
        toggleRecording()
    }

    private func requestPermissionAndStart() {
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            Task { @MainActor in
                guard let self else { return }
                if allowed {
                    self.start()
                } else {
                    self.errorMessage = L10n.Watch.micDenied
                }
            }
        }
    }

    // MARK: - remote timed recording (phone → watch, ★ 2026-10-30)
    //
    // 用户："定时录音……真正在手表上录"。手机在配置窗口内通过
    // WatchConnectivity 让手表开录/停录，手表只是执行者。

    /// 最近一次 "start" 命令是否还没落实成录音（后台送达/权限未决时为 true，
    /// `WatchLink.retryUnconfirmedTimedCommand` 据此决定要不要补执行）。
    private(set) var remoteStartPending = false
    /// 窗口结束兜底——手机进程死了手表也能自己停。
    private var remoteStopTask: Task<Void, Never>?

    /// 手机定时录音：开始。已授权麦克风就直接开；没授权走正常授权流程
    /// （命令只在 App 打开时被执行，弹一次系统权限框不算"半夜偷袭"）。
    func startRemotely() {
        remoteStartPending = true
        guard !isRecording else {
            remoteStartPending = false
            return
        }
        requestPermissionAndStart()
    }

    /// 手机定时录音：到窗口结束时刻自己停（幂等：没在录就是空操作）。
    func scheduleRemoteStop(at date: Date) {
        remoteStopTask?.cancel()
        remoteStopTask = Task { [weak self] in
            let interval = date.timeIntervalSinceNow
            guard interval > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            self.stop()
        }
    }

    func cancelRemoteStop() {
        remoteStopTask?.cancel()
        remoteStopTask = nil
    }

    // MARK: - link-lost alert (★ 2026-10-30)
    //
    // 用户："手表如何在录音断联，需要状态弹出提醒告知，点击或者在附近就重连。"
    //
    // ## 为什么有防抖
    // `isReachable` 要求手机 App 在前台（见 `WatchLink.phoneReachable` 的注释），
    // 手机锁屏/切走就会瞬间置 false——没有防抖的话，录音 30 秒后手机一锁屏
    // 手表就弹窗，全是狼来了。所以：掉线要**持续** `reachabilityGrace` 秒才
    // 认定真断联；恢复则立刻清除并自动重连（补推状态 + 补发队列）。
    //
    // ## 代价与兜底
    // 断联本身不伤录音（文件在表上写盘，传输走后台队列），提醒只解决
    // 「用户以为传过去了其实没传」的信息差。点「重连」立即重推状态并
    // 重发队列；哪怕不点，回到附近也会自动补上。

    /// 掉线持续这么久才算真断联（锁屏/切走的瞬时 false 不算）。
    private static let reachabilityGrace: TimeInterval = 20

    /// 断联后每隔这么久自愈一次：重激活会话 + 重推状态。
    ///
    /// ★ 2026-11-03（用户："点击自动重连或者不点击也可以，增加重连机制"）：
    /// 「不点也重连」不能只靠"等手机自己回来"——会话被系统拆掉时它永远不回来。
    /// 这个节拍器就是那条兜底：App 还活着就每 30 秒试一次，恢复可达立刻停。
    private static let reconnectRetryInterval: TimeInterval = 30

    private var reachabilityDebounce: Task<Void, Never>?
    private var reconnectTicker: Task<Void, Never>?

    /// 还有"没送到手机的东西"：正在录音，或手上压着待传片段。
    ///
    /// 只有这两种情况才值得打扰用户——没在录、也没积压时断联是常态
    /// （表离手机远一点就"不可达"），提醒只会变成狼来了。
    private var hasUnsyncedWork: Bool { isRecording || !pending.isEmpty }

    /// 通知正文。录音中强调"录音还在"，只是积压则强调"还没传过去"。
    private var disconnectNote: String {
        isRecording ? L10n.Watch.linkLostNoteRecording : L10n.Watch.linkLostNotePending
    }

    private func handleReachability(_ reachable: Bool) {
        if reachable {
            reachabilityDebounce?.cancel()
            reachabilityDebounce = nil
            stopReconnectTicker()
            WatchLinkNotifier.shared.cancel()
            guard linkLost else { return }
            // 回到附近：自动重连——立刻把最新状态推过去、把没发出去的
            // 队列补发一遍，然后撤掉提醒。
            linkLost = false
            pushState()
            resendPending()
        } else {
            guard hasUnsyncedWork else { return }
            guard reachabilityDebounce == nil else { return }
            // ★ 2026-11-03：通知**现在就把 20 秒后的投递预约给系统**，而不是等
            //   `Task.sleep` 到点再发——等的这 20 秒里 App 极可能已经被挂起
            //   （用户刚把手机放下、抬腕熄屏），Task 根本醒不过来，通知就永远不出现。
            //   恢复可达时 `cancel()` 撤销，等于把"预约"当成防抖用。
            WatchLinkNotifier.shared.scheduleDisconnect(
                after: Self.reachabilityGrace,
                body: disconnectNote,
                recording: isRecording
            )
            reachabilityDebounce = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.reachabilityGrace * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                guard self.hasUnsyncedWork, !self.link.phoneReachable else { return }
                self.linkLost = true
                WKInterfaceDevice.current().play(.notification)
                self.startReconnectTicker()
            }
        }
    }

    private func startReconnectTicker() {
        guard reconnectTicker == nil else { return }
        reconnectTicker = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(Self.reconnectRetryInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard !self.link.phoneReachable else { return }
                self.link.reactivateIfNeeded()
                self.pushState()
            }
        }
    }

    private func stopReconnectTicker() {
        reconnectTicker?.cancel()
        reconnectTicker = nil
    }

    /// 提醒弹窗/通知上的「重连」：立即重激活会话、重推状态、补发队列；手机真回来了
    /// 就顺手撤掉提醒，没回来弹窗关掉、录音继续（后台队列照常等，节拍器继续试）。
    func reconnectNow() {
        reachabilityDebounce?.cancel()
        reachabilityDebounce = nil
        WatchLinkNotifier.shared.cancel()
        link.reactivateIfNeeded()
        pushState()
        resendPending()
        if link.phoneReachable {
            linkLost = false
            stopReconnectTicker()
        }
    }

    /// 录音结束/出错时清掉断联提醒、防抖任务、自愈节拍器与系统通知（stop 路径调用）。
    private func clearLinkLostState() {
        reachabilityDebounce?.cancel()
        reachabilityDebounce = nil
        stopReconnectTicker()
        WatchLinkNotifier.shared.cancel()
        linkLost = false
    }

    /// 用户关掉断联提醒（「继续」按钮 / 弹窗 dismiss）。录音不动——
    /// 手机回来时自动重连逻辑照常生效。
    func dismissLinkLost() {
        linkLost = false
    }

    /// ★ 2026-11-05（用户截图：睡眠模式下"无法开始录音: AVAudioRecorder refused to
    /// start … RecorderError 0"）：睡眠专注/腕放下时，watchOS 会拒绝激活音频会话
    /// 或拒绝 `record()`——这不是权限坏了，是系统在省电，**抬腕唤醒后通常就放行**。
    /// 所以开录不再一失败就报错收场，而是按这条梯子重试（全程 ≈30s）；
    /// 期间录音键保持"未在录"状态，用户随时可以再按（再按会重置梯子重新走）。
    private static let startRetryDelays: [TimeInterval] = [0.5, 1.0, 2.0, 4.0, 8.0, 15.0]
    private var startAttempt = 0
    private var startRetryTask: Task<Void, Never>?

    private func start() {
        installInterruptionHandlers()
        startAttempt = 0
        attemptStart()
    }

    private func attemptStart() {
        guard !isRecording else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // `.spokenAudio` is a playback mode and returns paramErr (-50)
            // against the record-only category on watch hardware.
            //
            // ★ 2026-10-20: category upgraded from `.record` to **`.playAndRecord`
            //   + `.mixWithOthers`** for two measured reasons:
            //   ① Background survival — the user's recordings were being killed
            //      shortly after the app went to the background. The audio background
            //      entitlement was in place, but `.record`-only sessions are the
            //      configuration field reports single out as unreliable for
            //      background continuation on watchOS; `.playAndRecord` is the
            //      category Apple's own background-recording guidance and every
            //      production watch recorder settles on.
            //   ② `.mixWithOthers` — without it, activating the session interrupts
            //      any other audio (music, podcasts), and other audio activations
            //      interrupt *us*. Mixing keeps both directions peaceful: a call or
            //      an alarm still interrupts (that's a hard interruption), but a
            //      music app no longer ends the take.
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            scheduleStartRetryOrFail(error)
            return
        }
        installInterruptionHandlers()

        do {
            let url = makeClipURL()
            let newRecorder = try makeRecorder(at: url)
            recorder = newRecorder
            elapsed = 0
            currentBytes = 0
            meter = WatchAudioMeter()
            isRecording = true
            startedAt = Date()
            // ★ 2026-11-03 八轮：分段游标归零——这一场录音的第一段从这里开始算。
            segmentOffset = 0
            segmentStart = 0
            // ★ 2026-11-03 八轮：新一段录音从零开始打点。
            marks = []
            totalMarks = 0
            // ★ 2026-11-03 八轮：把"在录音"告诉电量监控，样本才分得清「录音中」和「待机」——
            //   这个页面的全部意义就是这两条速率的差。见 `WatchBatteryMonitor`。
            WatchBatteryMonitor.shared.isRecording = true
            remoteStartPending = false
            // ★ 2026-11-05：这一场开录成功，"中断待续"的标记就地作废。
            clearResumePending()
            // 开始：按设置页的"启动震动"花样（默认一下；结束是两下，见 `playPattern`）。
            playStartHaptics()
            startTimer()
            pushState()
            // ★ 2026-11-03：授权框放在这里而不是 App 启动时——用户刚按下录音，
            //   "录音时手机断开要提醒你"这个理由当下自明。被拒绝也不影响录音。
            WatchLinkNotifier.shared.requestAuthorizationIfNeeded()
            // ★ 2026-11-03（开会停录修复）：挂上 workout 保活伞。首次录音时
            //   HealthKit 授权还在路上，session 可能被拒（degraded，日志可见）；
            //   第二次开录起就正常。详见 `WatchWorkoutKeeper`。
            WatchWorkoutKeeper.shared.requestAuthorizationIfNeeded()
            WatchWorkoutKeeper.shared.start()
            log.info("recording to \(url.lastPathComponent, privacy: .public)")
        } catch {
            try? session.setActive(false)
            scheduleStartRetryOrFail(error)
        }
    }

    /// 开录被系统拒绝：梯子没走完就延时重试，走完了才把错误亮给用户。
    private func scheduleStartRetryOrFail(_ error: Error) {
        guard startAttempt < Self.startRetryDelays.count else {
            log.error("start refused after \(self.startAttempt, privacy: .public) retries: \(error.localizedDescription, privacy: .public)")
            fail(error)
            return
        }
        let delay = Self.startRetryDelays[startAttempt]
        startAttempt += 1
        log.warning("start refused (\(error.localizedDescription, privacy: .public)) — retry #\(self.startAttempt, privacy: .public) in \(delay, privacy: .public)s")
        startRetryTask?.cancel()
        startRetryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !isRecording else { return }
            attemptStart()
        }
    }

    /// 建一个已开始录音的 recorder。设置集中在这里——分段轮转与首次开录必须用**同一份**
    /// 参数，否则第二段的采样率/码率悄悄变掉，两段接起来的音色会不一样。
    private func makeRecorder(at url: URL) throws -> AVAudioRecorder {
        let newRecorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ])
        // ★ 2026-10-16 revision nine: enable the level meter. Left off, `averagePower` always returns -160,
        //   the home screen's waveform becomes a dead line — when its one job is exactly to prove "it's recording".
        newRecorder.isMeteringEnabled = true
        guard newRecorder.record() else { throw RecorderError.couldNotStart }
        return newRecorder
    }

    // MARK: - 滚动分段

    /// 到点了就把当前文件收口、立刻开下一段。
    ///
    /// ⚠️ 这是**唯一**会"停掉 recorder 但不结束录音"的地方。三条必须同时满足：
    ///   ① 新文件先建成再放弃旧的——建不出来就结束整场（宁可少一段，不要静默不录）；
    ///   ② 计时器要绑到**新的** recorder 上（旧 timer 的闭包握着旧的引用，不重建会一直读旧文件）；
    ///   ③ 打点与已录时长按段结算：打点落盘、`segmentOffset` 累加。
    private func rotateSegment() {
        guard let current = recorder else { return }
        let url = current.url
        let elapsedNow = segmentOffset + current.currentTime
        current.stop()
        saveMarks(for: url)
        deliver(url)
        marks = []

        do {
            let next = try makeRecorder(at: makeClipURL())
            recorder = next
            segmentOffset = elapsedNow
            segmentStart = elapsedNow
            elapsed = elapsedNow
            currentBytes = 0
            // 前台才需要 UI 计时器；熄屏时由 10s 心跳继续巡检（见 `setUIDormant`）。
            if !uiDormant { startTimer() }
            reloadPending()
            pushState()
            log.info("segment rotated at \(Int(elapsedNow), privacy: .public)s → \(next.url.lastPathComponent, privacy: .public)")
        } catch {
            log.error("segment rotation failed: \(String(describing: error), privacy: .public)")
            // 与"用户按下结束"同一条收场：这一段已经在磁盘上、已经排队，宁可停也不能假装还在录。
            recorder = nil
            finishTake()
            markResumePending()
            fail(error)
        }
    }

    /// 到点检查。`segmentStart == 0` 时用首段上限（30 分钟），之后每段 15 分钟。
    private func rotateIfNeeded(elapsedNow: TimeInterval) {
        guard isRecording, recorder != nil else { return }
        let limit = segmentStart == 0 ? Self.firstSegmentLimit : Self.segmentLimit
        guard elapsedNow - segmentStart >= limit else { return }
        rotateSegment()
    }

    /// 把一段收口后的文件送出去（省电模式且没充电就先攒着）。
    private func deliver(_ url: URL) {
        if transfersDeferred {
            log.info("power saver: deferring transfer of \(url.lastPathComponent, privacy: .public)")
        } else {
            link.transfer(url)
        }
    }

    /// 收掉"这一场录音"的所有运行态（不动文件、不动打点）。
    ///
    /// 段轮转失败时与 `stop()` 共用这一段，避免两条停录路径各自忘记清一个状态。
    private func finishTake() {
        timer?.invalidate()
        timer = nil
        // ★ 2026-11-05：还没落地的"开录重试"一并撤掉——人已经收场了。
        startRetryTask?.cancel()
        startRetryTask = nil
        // ★ 2026-11-06（全天候语义）：梯子走到头的 `startAttempt` 也归零——
        // 否则残留值会让 `autoStartForAllDayIfNeeded` 的 guard 永远挡住续录，
        // "一次开录失败 → 全天候再也不自动开"。
        startAttempt = 0
        dormantHeartbeat?.invalidate()
        dormantHeartbeat = nil
        isRecording = false
        WatchBatteryMonitor.shared.isRecording = false
        interrupted = false
        remoteStartPending = false
        remoteStopTask?.cancel()
        remoteStopTask = nil
        clearLinkLostState()
        WatchWorkoutKeeper.shared.stop()
        meter = WatchAudioMeter()
        startedAt = nil
        segmentOffset = 0
        segmentStart = 0
        try? AVAudioSession.sharedInstance().setActive(false)
        reloadPending()
        pushState()
    }

    /// ★ 2026-11-03 八轮：在当前时间点打一个「重点」。
    ///
    /// 交互（用户原话："手表下方…按一下就可以标记重点打点"）：录音中，页面底部那颗
    /// 旗标胶囊按一下 → 记下 `elapsed` + 一次 "click" 触感。**不打断录音、不弹窗**：
    /// 打点的场景就是"正在听、来不及停下来说话"，任何需要确认的交互都不合格。
    ///
    /// ⚠️ 同一秒内连点只记一个：手表的触感反馈有延迟，用户会怀疑"是不是没点到"再点一次，
    ///    那一下不该变成两个重点。
    func addBookmark() {
        guard isRecording else { return }
        if let last = marks.last, elapsed - last < 1.0 { return }
        marks.append(elapsed)
        totalMarks += 1
        WKInterfaceDevice.current().play(.click)
    }

    /// 把这一段的打点写成 `<录音名>.marks.json`，与音频同目录。
    ///
    /// ★ 为什么落成旁挂文件而不是只塞 `UserDefaults`：音频会随 `transferFile` 走，
    ///   旁挂文件跟着同一批文件走（`link.transfer` 会读它并塞进 metadata），
    ///   中途 App 被杀、蓝牙断、几天后才补传，点都还在原位。
    ///   `UserDefaults` 那份要另外维护"哪一段属于哪个录音"的映射，多一层会出错的地方。
    private func saveMarks(for url: URL) {
        let sidecar = url.deletingPathExtension()
            .appendingPathExtension(WatchLinkMessage.marksFileExtension)
        guard !marks.isEmpty else {
            try? FileManager.default.removeItem(at: sidecar)
            return
        }
        let payload: [String: [Double]] = ["seconds": marks]
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: sidecar, options: .atomic)
        log.info("saved \(self.marks.count, privacy: .public) mark(s) for \(url.lastPathComponent, privacy: .public)")
    }

    /// ★ 2026-10-20: no longer `private` — the hold-to-stop path in `WatchRecorderView`
    /// ends the take directly (a deliberate 2-second hold needs no extra confirmation,
    /// unlike tap / double-tap / shake, which are all misfire-prone).
    ///
    /// ★ 2026-11-06（全天候语义，用户："全天候录音打开的就不存在说不录音这么一说…
    /// 也没暂停一说，那个暂停应该是关闭全天候录音这个开关了就是"）：全天候开着时，
    /// 走到这里的停止（系统打断放弃、看门狗放弃、远程/定时命令）都不算"录音结束"
    /// ——收口后立刻再起一场，中间丢的只有换文件那几十毫秒。真正能停的只有一条
    /// 路：把全天候开关关掉（那时 `allDayRecording` 已是 false，这里自然不重启）。
    func stop() {
        guard let recorder else { return }
        let url = recorder.url
        recorder.stop()
        // ★ 2026-11-03 八轮：先落旁挂再传（`link.transfer` 会读它）。
        saveMarks(for: url)
        self.recorder = nil
        // 结束：按设置页的花样放（默认"两下"，力度跟触感等级走）。
        // 这一句在 `recorder.stop()` 之后，麦克风已收，所以震动不会被录进文件里。
        playStopHaptics()
        // ★ 2026-11-02（全天候录音）：省电模式且没在充电时**不立即回传**——
        //   片段留在「待传」里，充电中 / 关掉开关时自动补传，「同步」页的
        //   「立即同步」随时能手动触发（`retry` 直连 `link.transfer`，不受此闸影响）。
        deliver(url)
        // 运行态统一在这里收：段轮转失败走的也是这一条（见 `finishTake`）。
        finishTake()
        // ★ 2026-11-06：全天候开着 = 立刻续一场。开录失败有重试梯子兜底
        // （梯子走完只报错不再停，不会形成 stop→start 死循环）。
        if WatchRecordingPrefs.shared.allDayRecording {
            autoStartForAllDayIfNeeded()
        }
    }

    /// 用户主动停（录音键 / 长按 / 手势确认条）。全天候开着时它的语义就是
    /// **关掉全天候开关**（用户原话见 `stop()` 注释）——先翻开关、再走同一条
    /// `stop()`；此刻偏好已是 false，`stop()` 末尾的自动续录不会触发。
    /// 偏好变化随 `finishTake` 的 `pushState` 回报手机（每次心跳都带 allDay 键）。
    func stopByUser() {
        if WatchRecordingPrefs.shared.allDayRecording {
            WatchRecordingPrefs.shared.allDayRecording = false
            setPowerSaver(false)
        }
        stop()
    }

    // MARK: - audio interruptions (★ 2026-10-20)

    /// Registers the two system notifications that can end a background take.
    ///
    /// ## Why this exists
    /// The user's background recordings were dying silently. The audio background
    /// entitlement keeps the **process** alive, but it does not shield the audio
    /// session: an incoming call, Siri, a timer alarm (anything that grabs the mic)
    /// delivers an **interruption**, and without a handler `AVAudioRecorder` simply
    /// stops while the app sits suspended in the background — from the user's side,
    /// "the recording got killed".
    ///
    /// ## What each notification does here
    /// * `interruptionNotification` — `.began` **pauses** the recorder (file and
    ///   clock preserved); `.ended` tries to resume. Resume inside a live session
    ///   works; resume from a *suspended background* app is refused by watchOS
    ///   (Apple engineer, forum 750432: background resume must be user-initiated).
    ///   When the resume attempt fails we **stop gracefully** instead of pretending:
    ///   the bytes recorded so far are transferred to the phone exactly like a
    ///   manual stop, and the state push tells the phone what happened.
    /// * `mediaServicesWereResetNotification` — the media server daemon crashed and
    ///   every audio object was invalidated. Nothing can be salvaged in place; the
    ///   take is stopped the same graceful way.
    ///
    /// Both handlers hop to the main actor because every state write here is
    /// `@MainActor`-isolated and the notifications arrive on an arbitrary queue.
    private func installInterruptionHandlers() {
        guard !interruptionHandlersInstalled else { return }
        interruptionHandlersInstalled = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleMediaServicesReset() }
        }
    }

    private func handleInterruption(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard let type = AVAudioSession.InterruptionType(rawValue: raw ?? 0) else { return }
        switch type {
        case .began:
            guard let recorder, isRecording, !interrupted else { return }
            log.warning("audio interruption began — pausing the take")
            recorder.pause()
            interrupted = true
            WKInterfaceDevice.current().play(Self.confirmation)

        case .ended:
            guard isRecording, interrupted else { return }
            interrupted = false
            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                log.error("session re-activate after interruption failed: \(error.localizedDescription, privacy: .public)")
            }
            // ★ 2026-11-02（用户："我没有结束录音就自己关闭了"）：不再以
            // `.shouldResume` 为开关——watchOS 在大量真实场景（Siri、计时器、
            // 通知、后台打断）下**根本不下发**这个标志位，旧逻辑因此直接停录。
            // 现在改为：立即试续录 → 失败则 0.5s/1.5s/3s 三次重试 → 全部被拒
            // 才优雅停（已录部分照常落盘上传）。`record()` 在暂停的 recorder
            // 上是向同一文件续写，不会开新文件。
            if let recorder, recorder.record() {
                log.info("recording resumed after interruption (immediate)")
            } else {
                log.warning("immediate resume refused — retrying before giving up")
                retryResumeAfterInterruption()
            }

        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        guard isRecording else { return }
        log.error("media services were reset — ending the take with what is on disk")
        errorMessage = L10n.Watch.recordingInterrupted
        interrupted = false
        markResumePending()
        stop()
    }

    /// ★ 2026-11-02: sees `handleInterruption(.ended)`'s retry ladder through.
    /// Re-entry safe on every axis: a new interruption re-sets `interrupted`
    /// (guard exits), a manual stop flips `isRecording` (guard exits), and the
    /// final failure goes through the same graceful `stop()` as before — the
    /// partial file rides the normal upload path.
    private func retryResumeAfterInterruption() {
        Task { @MainActor in
            for delay in [0.5, 1.5, 3.0] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard isRecording, !interrupted else { return }
                if let recorder, recorder.record() {
                    log.info("recording resumed after \(delay, privacy: .public)s")
                    return
                }
            }
            guard isRecording, !interrupted else { return }
            log.warning("all resume attempts refused — stopping gracefully")
            errorMessage = L10n.Watch.recordingInterrupted
            markResumePending()
            stop()
        }
    }

    // MARK: - 中断待续（★ 2026-11-05 全天候录音）

    /// 上一场录音**不是被用户按停**、而是系统放弃（打断重试全败 / 看门狗放弃 /
    /// media services reset / 分段轮转失败）时置位并持久化。App 被杀重启也能弹。
    ///
    /// 用户原话："只要不是用户手动点击结束录音的按下键则需要持续录音…中断下次
    /// 唤醒 Nomily AI APP 手表也要继续录音，中断则弹窗继续。" 持续录音的部分由
    /// 打断重试梯子 + 看门狗承担（上面两段）；这里是最后兜底——系统坚决不放的
    /// 那些场景，抬腕回前台时**弹窗问一句要不要接着录**（只在全天候开关开着时弹）。
    private static let resumePendingKey = "watch.take.resume_pending.v1"
    private var resumePending: Bool {
        get { UserDefaults.standard.bool(forKey: Self.resumePendingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.resumePendingKey) }
    }

    /// 系统放弃录音时调用（全天候开关关着就不标记——那时弹窗反而打扰）。
    private func markResumePending() {
        guard WatchRecordingPrefs.shared.allDayRecording else { return }
        resumePending = true
        log.warning("take ended by the system — resume prompt armed")
    }

    func clearResumePending() { resumePending = false }

    /// 录音页判断要不要弹「继续录音」。开录成功/用户忽略后即消失。
    var shouldOfferResume: Bool {
        resumePending && WatchRecordingPrefs.shared.allDayRecording && !isRecording
    }

    /// 弹窗「继续录音」：清标记，从现在起开一场新的（旧段已各自落盘待传）。
    func resumeInterruptedTake() {
        clearResumePending()
        requestPermissionAndStart()
    }

    // MARK: - resume watchdog（★ 2026-11-03，全天候录音）

    /// 录音真实性巡检：`recorder.isRecording == false` 但 `isRecording == true`。
    ///
    /// ## 为什么重试梯子之外还需要它
    /// 打断的 `.ended` 通知在后台**不保证送达**——没送达时 `interrupted` 永远是
    /// `true`，梯子永远不触发，recorder 就停在"暂停"里不动了。用户看到的正是
    /// "录音自己关闭了"。看门狗不依赖任何事件：前后台两条定时路径都会路过它，
    /// 发现"该在录但没在录"就直接续录。
    ///
    /// ## 节流
    /// 前台 1 秒路过一次、后台（休眠心跳）10 秒路过一次；真正尝试 `record()`
    /// 至少间隔 2 秒。连续被拒 6 次（后台 ≈1 分钟、前台 ≈12 秒）认定"系统
    /// 坚决不给"，优雅停——已录部分照常落盘回传，绝不静默丢内容。
    private var lastResumeAttempt = Date.distantPast
    private var watchdogFailures = 0

    private func watchdogCheck() {
        guard isRecording, let recorder else { return }
        guard !recorder.isRecording else {
            watchdogFailures = 0
            return
        }
        guard Date().timeIntervalSince(lastResumeAttempt) >= 2 else { return }
        lastResumeAttempt = Date()
        if recorder.record() {
            // `interrupted` 可能还挂着（`.ended` 没送到的情形）——续录成功即视为打断结束。
            interrupted = false
            watchdogFailures = 0
            log.info("watchdog: recorder was stalled — resumed")
        } else {
            watchdogFailures += 1
            log.warning("watchdog: resume refused (streak \(self.watchdogFailures, privacy: .public))")
            if watchdogFailures >= 6 {
                log.error("watchdog: all attempts refused — stopping gracefully")
                errorMessage = L10n.Watch.recordingInterrupted
                markResumePending()
                stop()
            }
        }
    }

    /// Re-states the whole recorder in one payload. Cheap enough to call from
    /// every transition; `pushState` is what the phone's status row is made of.
    private func pushState() {
        lastPush = Date()
        link.pushState(
            isRecording: isRecording,
            since: startedAt,
            transferPending: !pending.isEmpty
        )
    }

    private func startTimer() {
        timer?.invalidate()
        // ⚠️ This counter is **for the closure**: the tick rate is 12.5Hz, but the timer and byte count
        //    only need to be once a second (`size(of:)` does a stat on the file, and running it 12 times for nothing is wasteful,
        //    and the displayed granularity is seconds anyway).
        var ticks = 0
        timer = Timer.scheduledTimer(
            withTimeInterval: meterIntervalNow,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                ticks += 1
                self.sampleMeter(recorder, tick: ticks)
                guard ticks % self.meterTicksPerSecondNow == 0 else { return }
                // ★ 2026-11-03 八轮（滚动分段）：界面计时 = 已切走时长 + 本段时长。
                let elapsedNow = self.segmentOffset + recorder.currentTime
                self.elapsed = elapsedNow
                self.currentBytes = Self.size(of: recorder.url)
                // ★ 2026-11-03 八轮：到点切段（首段 30 分钟，之后每 15 分钟）。
                self.rotateIfNeeded(elapsedNow: elapsedNow)
                // ★ 2026-11-03：前台也巡检——1 秒路过一次，真尝试有 2 秒节流。
                self.watchdogCheck()
                if Date().timeIntervalSince(self.lastPush) >= Self.heartbeatInterval {
                    self.pushState()
                }
            }
        }
    }

    // MARK: - UI dormancy (★ 2026-10-23, 功耗优化)
    //
    // The 12.5 Hz meter exists for exactly one consumer: the waveform the user
    // sees on the home screen. When watchOS dims the display (wrist down) or
    // the app drops out of the foreground, nobody can see it — yet the timer
    // kept firing 12.5 times a second, waking the CPU to sample dBFS and
    // repaint a `@Published` nobody renders. On a one-hour take that is
    // ~45,000 wasted wakeups.
    //
    // ## What dormancy keeps
    // **The recording itself.** `AVAudioRecorder` owns the mic and the file and
    // doesn't need this timer at all; pausing UI work must never touch it.
    //
    // ## What replaces it
    // A slow heartbeat timer at `heartbeatInterval` (30 s) that only re-states
    // the recorder state to the phone. Without it the phone's watchdog would
    // read the silence as "watch went away" and flip the status strip to
    // "offline" during a take — the whole point of the heartbeat is honesty.
    // Elapsed/bytes updates are skipped while dimmed: nothing displays them,
    // and the values catch up on the first tick after wake.

    private var uiDormant = false
    private var dormantHeartbeat: Timer?

    /// Called by the view when the screen dims (`isLuminanceReduced`) or the
    /// scene leaves the foreground (`scenePhase != .active`). Idempotent.
    func setUIDormant(_ dormant: Bool) {
        guard uiDormant != dormant else { return }
        uiDormant = dormant
        if dormant {
            timer?.invalidate()
            timer = nil
            // ★ 2026-11-03：已经确认断联、而用户又把表放下了——这时应用内 alert
            //   谁也看不见，把它换成一条真正的系统通知投递出去。
            if linkLost, !link.phoneReachable {
                WatchLinkNotifier.shared.presentDisconnectNow(
                    body: disconnectNote,
                    recording: isRecording
                )
            }
            guard isRecording else { return } // idle: no timers at all
            dormantHeartbeat?.invalidate()
            // ★ 2026-11-03：30s → 10s。这个计时器现在身兼两职——
            //   ① 推状态心跳（仍按 30s 的 lastPush 节流）；
            //   ② 续录看门狗：后台是"打断后 .ended 不送达、recorder 停在暂停里"
            //      的高发区，10s 的巡检间隔把一次后台卡死的损失压到 ≤10 秒。
            dormantHeartbeat = Timer.scheduledTimer(
                withTimeInterval: 10,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    // ★ 2026-11-03 八轮：熄屏时也必须能切段——全天候录音大部分时间
                    //   表是暗的，只在亮屏时轮转等于没做。这里现算一次逻辑时长。
                    if let recorder = self.recorder {
                        self.rotateIfNeeded(elapsedNow: self.segmentOffset + recorder.currentTime)
                    }
                    self.watchdogCheck()
                    if Date().timeIntervalSince(self.lastPush) >= Self.heartbeatInterval {
                        self.pushState()
                    }
                }
            }
            log.info("UI dormant — meter paused, heartbeat slowed, recording continues")
        } else {
            dormantHeartbeat?.invalidate()
            dormantHeartbeat = nil
            // ★ 2026-11-03：回到 App 里了，应用内 alert 接手，通知中心那条撤掉，
            //   免得用户处理完还留一条"已断开"的旧消息。
            if linkLost { WatchLinkNotifier.shared.cancel() }
            if isRecording { startTimer() }
            // The phone hasn't heard from us in a while; re-state immediately
            // instead of waiting a full interval.
            pushState()
        }
    }

    /// Read the level once and write it into `meter`.
    ///
    /// ## Why dBFS is clamped at -50
    /// `averagePower` gives **dBFS** (0 = full scale, the more negative the quieter). On the watch, talking softly
    /// from tens of centimetres away lands around -50dB, while a quiet room's noise floor is below -65dB.
    /// Putting the floor at -50 keeps the noise floor from drawing any wave — otherwise the line would jitter constantly and the user would think
    /// the microphone is picking something up.
    ///
    /// ## Why it rises fast and falls slow
    /// The first syllable of speech must shoot up **immediately** (or the user will suspect nothing was recorded), but if it
    /// fell back within 80ms a single syllable would be torn into several fragments of noise. So the rise follows directly, and the fall slides
    /// at a fixed speed — 0.14 per slot, about 0.6 seconds to slide from full scale back to the floor.
    private func sampleMeter(_ recorder: AVAudioRecorder, tick: Int) {
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        let floorDb: Float = -50
        let raw = max(0, min(1, (db - floorDb) / -floorDb))
        let next = raw > meter.level ? raw : max(raw, meter.level - 0.14)
        meter = WatchAudioMeter(level: next, tick: tick)
    }

    private func fail(_ error: Error) {
        let nsError = error as NSError
        log.error("recording failed: \(String(describing: error), privacy: .public)")
        errorMessage = L10n.Watch.recordFailed("\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
    }

    // MARK: - pending clips

    /// Re-send a clip the user is tired of waiting on. Harmless while the
    /// transfer is already queued — `WatchLink` de-dupes.
    func retry(_ clip: PendingClip) {
        link.transfer(clip.url)
    }

    private func resendPending() {
        reloadPending()
        // Clips the phone's daemon already took are still pending here (the
        // wrist copy only goes after the app's ack), and re-offering those
        // sends the same bytes twice.
        //
        // ★ 2026-11-02（全天候录音）：省电且没在充电时**不自动补发**——
        //   手机一连上就把几十段全推过去，恰恰是省电模式要避免的功耗曲线。
        //   例外都走 `retry`（手动「立即同步」）或 `setPowerSaver(false)`（此处 powerSaver 已为 false）。
        for clip in pending where !link.deliveredNames.contains(clip.name) {
            if transfersDeferred { break }
            link.transfer(clip.url)
        }
        // The link just came up, so the phone's copy of our state is whatever
        // it had before the session died. Re-state it.
        pushState()
    }

    func delete(_ clip: PendingClip) {
        discard(clip.url)
    }

    private func discard(named name: String) {
        discard(Self.clipsDirectory.appendingPathComponent(name))
    }

    private func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reloadPending()
        // Clears the phone's "transferring" state the moment the queue empties.
        pushState()
    }

    private func reloadPending() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.clipsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let recordingURL = recorder?.url
        pending = urls
            .filter { $0.pathExtension == "m4a" && $0 != recordingURL }
            .map { PendingClip(url: $0, bytes: Self.size(of: $0)) }
            .sorted { $0.name > $1.name }
    }

    // MARK: - files

    private static var clipsDirectory: URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = root.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `yyyyMMddHHmmss.m4a`, matching the device's naming so the phone's
    /// `RecordingName` parses it. On the rare same-second collision the
    /// timestamp is walked forward rather than suffixed, which would break
    /// that parse.
    private func makeClipURL() -> URL {
        var stamp = Date()
        var url = Self.clipsDirectory
            .appendingPathComponent(RecordingName.filename(for: stamp, extension: "m4a"))
        while FileManager.default.fileExists(atPath: url.path) {
            stamp = stamp.addingTimeInterval(1)
            url = Self.clipsDirectory
                .appendingPathComponent(RecordingName.filename(for: stamp, extension: "m4a"))
        }
        return url
    }

    private static func size(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}

private enum RecorderError: LocalizedError {
    case couldNotStart
    var errorDescription: String? { "AVAudioRecorder refused to start" }
}
