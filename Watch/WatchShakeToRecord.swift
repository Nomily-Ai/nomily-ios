import CoreMotion
import Foundation
import SwiftUI

/// 「摇一摇开始录音」+「双指互点开/关录音」两个开关。
///
/// 与 `WatchRingStyleStore` **分开存**是刻意的：那个的 `reset()` 是"恢复默认
/// 外观"，而"恢复默认外观"顺手把录音行为也重置掉会很意外 —— 用户点的是
/// 颜色页里的恢复默认，结果录音方式变了。
final class WatchRecordingPrefs: ObservableObject {
    static let shared = WatchRecordingPrefs()

    private static let key = "watch.shake_to_record.v1"
    /// ★ 2026-10-15 六改：双指互点（食指拇指捏合）。**独立一个键** ——
    /// 两个手势的误触场景完全不同（晃是"抬手放下"，捏是"想按却按不到"），
    /// 共用一个开关的话，关掉一个就会顺手关掉另一个。
    private static let pinchKey = "watch.pinch_to_record.v1"

    /// 默认**开**：用户要的就是这个动作能立刻用上；真觉得会误触，
    /// 去设置页关掉即可（就在版本号下面）。
    @Published var shakeToRecord: Bool {
        didSet { defaults.set(shakeToRecord, forKey: Self.key) }
    }

    /// 默认**开**（用户点名要这个能力）。
    ///
    /// ⚠️ 只有 watchOS 11+ 真的能关：10.1~10.x 上双指互点是系统行为，
    /// 没有 API 可拦（见 `PrimaryHandGesture`）。设置页只在 11+ 显示这一行，
    /// 免得在 10.x 上给出一个拨了没用的开关。
    @Published var pinchToRecord: Bool {
        didSet { defaults.set(pinchToRecord, forKey: Self.pinchKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // ⚠️ 必须用 `object(forKey:)` 判"设过没有"：`bool(forKey:)` 在键不存在时
        // 返回 false，于是"默认开"会被静默变成"默认关"，而且用户永远
        // 打开不了 —— 每次冷启动都回到 false。
        self.shakeToRecord = (defaults.object(forKey: Self.key) as? Bool) ?? true
        self.pinchToRecord = (defaults.object(forKey: Self.pinchKey) as? Bool) ?? true
    }
}

/// 「用力晃动手表」检测。
///
/// ## 为什么用原始加速计，而不是 `deviceMotion.userAcceleration`
/// 我们只关心"手腕被猛地晃了一下"。原始加速计的**模长**在静止时恒为 1g
/// （重力），**转动**手腕改变不了它（只是重力在传感器坐标系里的方向变了），
/// 只有**平移**才会把模长顶上去 —— 正好是"晃"的物理特征。
/// 所以 `|a| > 阈值` 一条判据就够了，还省掉了 `deviceMotion` 在部分机型上
/// 可能不可用那条分支（`userAcceleration` 要先做一遍姿态解算）。
///
/// ## 为什么要求"时间窗内连着两次越过阈值"
/// 抬手放下、敲一下桌沿、戴表时扣一下表带，都会产生**一次**尖锐的峰值；
/// 真正的"摇两下"必然在一秒内连续越过两次。要求两次，代价是判定晚
/// 约 0.1 秒，换来的是走路/打字时不会自己开始录音。
///
/// ## 为什么不能光靠陀螺仪
/// 陀螺仪只测角速度，"把手腕转过去看表"这种动作角速度很大但加速度很小，
/// 用它当判据会在每次看表时误触。
final class WatchShakeDetector {
    /// 越过这个加速度（单位 g）才算一次"撞击"。静止是 1g；走路的峰值
    /// 到不了 2.3，而刻意甩手腕轻松超过 3g。
    private static let threshold: Double = 2.3
    /// 两次撞击必须落在这个时间窗里，才算"摇"。
    private static let burstWindow: TimeInterval = 0.9
    /// 触发之后静默一段，免得一次摇晃被拆成"开→关→开"。
    private static let cooldown: TimeInterval = 2.0
    /// 25Hz 足够分辨"摇"和"碰"（一次撞击持续时间约 100~200ms）。
    /// 再高只是白耗电 —— 这一页会一直开着，采集频率是电池账上的大头。
    private static let updateInterval: TimeInterval = 1.0 / 25.0

    private let manager = CMMotionManager()
    private var onShake: (() -> Void)?
    /// 轨迹上的撞击时刻，只保留 `burstWindow` 内的。
    private var peaks: [Date] = []
    /// 上一次采样是否已经在阈值以上 —— 用来只认"从下往上穿过"那一次。
    private var aboveThreshold = false
    private var lastFire = Date.distantPast

    var isRunning: Bool { manager.isAccelerometerActive }

    /// 开始监听。`handler` 会在**主队列**上被调用。
    ///
    /// 幂等：已经跑着就只换掉 handler，不重开采集（重开会让贴片重新预热，
    /// 头几十毫秒的数据不准）。
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
        // 一个撞击会连着好几个采样点都在阈值以上。只在**第一次**越线时记一笔，
        // 否则一次撞击就被数成五六次，"两次才算摇"的门槛等于没有。
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
