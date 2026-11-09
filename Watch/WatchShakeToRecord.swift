import CoreMotion
import Foundation
import SwiftUI

/// ★ 2026-11-05（用户："停止录音跟结束录音震动效果也要多出几个"）：
/// 录音起止的**震动花样**。力度（1–5 档）管"多重"，这里管"怎么响"——
/// watchOS 只有固定触感，花样只能靠"哪种触感 + 几发 + 间隔"拼。
///
/// ★ 2026-11-05 第三轮（用户："震动样式里面分启动震动跟结束震动…启动震动一下结束震动
/// 2 下，然后给不同的震动样式选择"）：**启动与结束各选各的花样**，不再共用一档——
/// 默认启动 `.single`（一下）、结束 `.double`（两下），"一下=开录、两下=收工"的
/// 语言保持不变，但两处都能换成下面任意一种。
///
/// | 花样 | 节奏 | 体感 |
/// |---|---|---|
/// | `.single` | 一段 ×1.0 | 默认的"开录"：就一下 |
/// | `.double` | 两段长震，隔 1 s | 默认的"结束"：两下＝收工 |
/// | `.triple` | 三段短震，隔 0.6 s | 三连敲，更急促 |
/// | `.singleLong` | 一段超长震（×1.6） | 一下到底，最干脆 |
/// | `.heartbeat` | 快快-停半秒-快快 | 心跳两拍 |
/// | `.crescendo` | 轻→中→重 | 渐强收尾 |
enum WatchHapticPattern: String, CaseIterable, Identifiable {
    case single
    case double
    case triple
    case singleLong
    case heartbeat
    case crescendo

    var id: String { rawValue }

    var label: String { L10n.Watch.hapticPatternName(rawValue) }
}

/// The two toggles: "shake to start recording" + "double tap to start/stop recording".
///
/// Storing it **separately** from `WatchRingStyleStore` is deliberate: that one's `reset()` is "restore the default
/// appearance", and having "restore default appearance" reset the recording behaviour too would be surprising — the user tapped
/// restore-default on the colour page, and the recording method changed.
final class WatchRecordingPrefs: ObservableObject {
    static let shared = WatchRecordingPrefs()

    private static let key = "watch.shake_to_record.v1"
    /// ★ 2026-10-15 revision six: double tap (pinching index finger and thumb). **A separate key** —
    /// the two gestures misfire in completely different scenarios (shake is "raise and lower the wrist", pinch is "wanting to press but missing"),
    /// and sharing one toggle would turn off one along with the other.
    private static let pinchKey = "watch.pinch_to_record.v1"
    /// ★ 2026-11-02（用户："手表需要为全天候录音设置，这个功耗跟传输需要优化"）：
    /// 全天候录音（省电模式）。开启后：
    ///   · 电平采样 12.5Hz → 2Hz，波形重绘 30fps → 2fps（录音本身的麦克风/文件写入不动）；
    ///   · 每段录音结束**不再立即回传**，攒在「待传」里——充电中、或关掉这个开关时自动补传，
    ///     「同步」页的「立即同步」任何时候都能手动触发。
    /// ⚠️ 默认**关**：它牺牲了实时性（波形变钝、回传延迟），是给"一戴一整天"的场景准备的，
    ///    不该替所有用户做这个取舍。
    private static let allDayKey = "watch.all_day_recording.v1"
    /// ★ 2026-11-05（用户："手表的震动还是太小了…震动大小分 5 个等级供用户选择"）：
    /// 起止触感强度，1（最轻）–5（最重）。映射见 `WatchRecorderModel.playHaptics`。
    /// 默认 **4**：就是"重触感长震"那一档——用户抱怨过默认太轻，出厂就给明显的。
    private static let hapticLevelKey = "watch.haptic_level.v1"
    /// ★ 2026-11-05 第二轮（用户："停止录音跟结束录音震动效果也要多出几个"）：
    /// 结束录音的**花样**（节奏），与力度档位独立——力度管"多重"，花样管"怎么响"。
    /// 存在这里而不是模型里：它和"摇一摇开录"同级，是用户的偏好不是运行态。
    private static let stopHapticPatternKey = "watch.haptic_stop_pattern.v1"
    /// ★ 2026-11-06（用户："手表这边可以增加一个表情常亮让手表持续显示在首页"）：
    /// 常亮暗态下首页**显示表情**（true，默认）还是黑屏省电（false）。
    /// watchOS 的常亮规则：App 在最前台的暗显时长由系统"返回表盘时间"决定
    ///（默认 2 分钟，手表上可按 App 单独设到 1 小时/始终），代码无法覆盖——
    /// 这个开关管的是"暗显的那段时间里画什么"，不是"多久回表盘"。
    private static let alwaysOnFaceKey = "watch.always_on_face.v1"
    /// ★ 2026-11-05 第三轮（用户："震动样式里面分启动震动跟结束震动"）：
    /// 启动录音的花样，与结束的花样**各存各的**——默认一下开、两下收，
    /// 但两组都能换，用户可能就想要"开录也两下"这种对称感。
    private static let startHapticPatternKey = "watch.haptic_start_pattern.v1"
    // ★ 2026-11-06 二轮（用户："瞳孔跟随手指…不操作打瞌睡…眼睛形状也加入…手机设置里多一些"）：
    // 表情"活起来"这一组的四个偏好，全部由手机端 Apple Watch 设置页推送 +
    // 手表设置页只读跟随（同一语义：翻开关的那端说了算）。
    private static let eyeShapeKey = "watch.eye_shape.v1"
    private static let drowsyEnabledKey = "watch.drowsy.v1"
    private static let drowsyAfterKey = "watch.drowsy_after.v1"
    private static let pupilFollowKey = "watch.pupil_follow.v1"

    /// Defaults **on**: what the user wants is for this action to work right away; if they really think it misfires,
    /// they can turn it off on the settings page (right below the version number).
    @Published var shakeToRecord: Bool {
        didSet { defaults.set(shakeToRecord, forKey: Self.key) }
    }

    /// Defaults **on** (the user specifically asked for this capability).
    ///
    /// ⚠️ Only watchOS 11+ can really turn it off: on 10.1~10.x Double Tap is system behaviour,
    /// with no API to intercept it (see `PrimaryHandGesture`). The settings page only shows this row on 11+,
    /// so as not to offer a switch that does nothing on 10.x.
    @Published var pinchToRecord: Bool {
        didSet { defaults.set(pinchToRecord, forKey: Self.pinchKey) }
    }

    /// ★ 2026-11-02：全天候录音（省电）开关，见 `allDayKey` 的说明。
    @Published var allDayRecording: Bool {
        didSet { defaults.set(allDayRecording, forKey: Self.allDayKey) }
    }

    /// ★ 2026-11-05：起止触感强度 1–5，见 `hapticLevelKey` 的说明。
    /// 越界值夹回 1...5（UserDefaults 手改/旧版本数据兜底）。
    @Published var hapticLevel: Int {
        didSet { defaults.set(hapticLevel, forKey: Self.hapticLevelKey) }
    }

    /// 触感等级夹在 1–5 之间。
    var clampedHapticLevel: Int { min(5, max(1, hapticLevel)) }

    /// ★ 2026-11-05：结束录音的震动花样（`WatchHapticPattern.rawValue`，见模型里的枚举）。
    @Published var stopHapticPattern: String {
        didSet { defaults.set(stopHapticPattern, forKey: Self.stopHapticPatternKey) }
    }

    /// ★ 2026-11-06：常亮暗态下首页显示表情（true，默认）。手机端也可推过来，见
    /// `WatchLinkMessage.alwaysOnFaceKey`。
    @Published var alwaysOnFace: Bool {
        didSet { defaults.set(alwaysOnFace, forKey: Self.alwaysOnFaceKey) }
    }

    /// ★ 2026-11-05 第三轮：启动录音的震动花样，默认"一下"。
    @Published var startHapticPattern: String {
        didSet { defaults.set(startHapticPattern, forKey: Self.startHapticPatternKey) }
    }

    // MARK: ★ 2026-11-06 二轮：让脸"活起来"的四个偏好

    /// 眼睛形状（`BotEyeShape.rawValue`）。手机选择器可换，随上下文推过来。
    @Published var eyeShapeRaw: String {
        didSet { defaults.set(eyeShapeRaw, forKey: Self.eyeShapeKey) }
    }

    /// 长时间没有触摸 → 打瞌睡（半闭眼）→ 再过 8 秒睡着（闭眼、只留呼吸）。
    /// 默认开——"觉得它是个活物"的核心就是这条。任何触摸都会把它惊醒。
    @Published var drowsyEnabled: Bool {
        didSet { defaults.set(drowsyEnabled, forKey: Self.drowsyEnabledKey) }
    }

    /// 多久没触摸开始打瞌睡（秒）。手机端给 15/30/60/120 四档。
    @Published var drowsyAfter: Int {
        didSet { defaults.set(drowsyAfter, forKey: Self.drowsyAfterKey) }
    }

    /// 按住屏幕拖动时眼睛看向手指（借鉴 agent-avatars 的 `followPointer`）。
    @Published var pupilFollow: Bool {
        didSet { defaults.set(pupilFollow, forKey: Self.pupilFollowKey) }
    }

    /// 解码后的眼睛形状；未知值（降级/旧推送）回默认"竖长条"。
    var eyeShape: BotEyeShape {
        BotEyeShape(rawValue: eyeShapeRaw) ?? .tall
    }

    /// 解码后的结束花样；存了未知值（降级/手改）就回默认"两下"。
    var stopPattern: WatchHapticPattern {
        WatchHapticPattern(rawValue: stopHapticPattern) ?? .double
    }

    /// 解码后的启动花样；未知值回默认"一下"。
    var startPattern: WatchHapticPattern {
        WatchHapticPattern(rawValue: startHapticPattern) ?? .single
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // ⚠️ Must use `object(forKey:)` to tell "was it ever set": `bool(forKey:)` returns
        // false when the key is absent, so "default on" would silently become "default off", and the user could never
        // turn it on — every cold launch returns to false.
        self.shakeToRecord = (defaults.object(forKey: Self.key) as? Bool) ?? true
        self.pinchToRecord = (defaults.object(forKey: Self.pinchKey) as? Bool) ?? true
        self.allDayRecording = (defaults.object(forKey: Self.allDayKey) as? Bool) ?? false
        self.hapticLevel = (defaults.object(forKey: Self.hapticLevelKey) as? Int) ?? 4
        self.stopHapticPattern = (defaults.object(forKey: Self.stopHapticPatternKey) as? String)
            ?? WatchHapticPattern.double.rawValue
        self.startHapticPattern = (defaults.object(forKey: Self.startHapticPatternKey) as? String)
            ?? WatchHapticPattern.single.rawValue
        self.alwaysOnFace = (defaults.object(forKey: Self.alwaysOnFaceKey) as? Bool) ?? true
        self.eyeShapeRaw = (defaults.object(forKey: Self.eyeShapeKey) as? String)
            ?? BotEyeShape.tall.rawValue
        self.drowsyEnabled = (defaults.object(forKey: Self.drowsyEnabledKey) as? Bool) ?? true
        self.drowsyAfter = (defaults.object(forKey: Self.drowsyAfterKey) as? Int) ?? 45
        self.pupilFollow = (defaults.object(forKey: Self.pupilFollowKey) as? Bool) ?? true
    }
}

/// "Shake the watch hard" detection.
///
/// ## Why the raw accelerometer rather than `deviceMotion.userAcceleration`
/// All we care about is "the wrist got yanked hard". The raw accelerometer's **magnitude** is always 1g at rest
/// (gravity), **rotating** the wrist can't change it (only the direction of gravity in the sensor's coordinate frame changes),
/// and only **translation** pushes the magnitude up — exactly the physical signature of a "shake".
/// So a single `|a| > threshold` criterion suffices, and it also avoids the branch where `deviceMotion` may be
/// unavailable on some models (`userAcceleration` requires an attitude solve first).
///
/// ## Why it requires "two threshold crossings in a row within a time window"
/// Raising and lowering the wrist, tapping the edge of a desk, buckling the strap when putting the watch on — all produce **one** sharp peak;
/// a real "shake twice" necessarily crosses twice in a row within a second. Requiring two costs about 0.1 s
/// of latency in detection, and buys not starting recording by itself while walking or typing.
///
/// ## Why the gyroscope alone won't do
/// The gyroscope only measures angular velocity; a motion like "turn the wrist to look at the watch" has high angular velocity but tiny acceleration,
/// so using it as the criterion would misfire every time you check the time.
final class WatchShakeDetector {
    /// Only crossing this acceleration (in g) counts as one "impact". At rest it's 1g; walking peaks
    /// never reach 2.3, while deliberately flicking the wrist easily exceeds 3g.
    private static let threshold: Double = 2.3
    /// Two impacts must fall within this time window to count as a "shake".
    private static let burstWindow: TimeInterval = 0.9
    /// Goes quiet for a spell after triggering, so one shake isn't split into "on→off→on".
    private static let cooldown: TimeInterval = 2.0
    /// 25Hz is enough to tell "shake" from "bump" (one impact lasts about 100~200ms).
    /// Higher is just wasted power — this page stays on constantly, and the sampling rate is the big item on the battery bill.
    private static let updateInterval: TimeInterval = 1.0 / 25.0

    private let manager = CMMotionManager()
    private var onShake: (() -> Void)?
    /// Impact timestamps along the trace, keeping only those within `burstWindow`.
    private var peaks: [Date] = []
    /// Whether the previous sample was already above the threshold — used to count only the "crossing upward" event.
    private var aboveThreshold = false
    private var lastFire = Date.distantPast

    var isRunning: Bool { manager.isAccelerometerActive }

    /// Start listening. `handler` is called on the **main queue**.
    ///
    /// Idempotent: if it's already running, just swap the handler rather than restarting sampling (restarting re-warms the die,
    /// and the first few tens of milliseconds of data are inaccurate).
    func start(_ handler: @escaping () -> Void) {
        onShake = handler
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        peaks.removeAll()
        aboveThreshold = false
        manager.accelerometerUpdateInterval = Self.updateInterval
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let data else { return }
            let a = data.acceleration
            self.handle(magnitude: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot())
        }
    }

    func stop() {
        onShake = nil
        peaks.removeAll()
        aboveThreshold = false
        manager.stopAccelerometerUpdates()
    }

    private func handle(magnitude: Double) {
        guard magnitude > Self.threshold else {
            aboveThreshold = false
            return
        }
        // One impact keeps several consecutive samples above the threshold. Record only on the **first** crossing,
        // otherwise one impact gets counted five or six times and the "two to count as a shake" bar amounts to nothing.
        guard !aboveThreshold else { return }
        aboveThreshold = true

        let now = Date()
        peaks.append(now)
        peaks.removeAll { now.timeIntervalSince($0) > Self.burstWindow }
        guard peaks.count >= 2, now.timeIntervalSince(lastFire) >= Self.cooldown else { return }
        peaks.removeAll()
        lastFire = now
        onShake?()
    }
}
