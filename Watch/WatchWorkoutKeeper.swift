import Foundation
import HealthKit
import WatchKit
import os.log

private let log = Logger(subsystem: "com.nomily.app.watch", category: "workout-keeper")

/// 录音期间挂着的一条 `HKWorkoutSession` —— 后台录音的「保活伞」。
///
/// ## 为什么需要它（★ 2026-11-03，用户："开会的时候我手表录音是打开的为啥就关闭了"）
///
/// 手表录音以前只靠 `UIBackgroundModes: audio` + 活跃的 `AVAudioSession` 续命。
/// 这条命很脆：会议里的通知、计时器、来电、Siri 任何一个抢麦克风的东西都会
/// 打断会话；打断之后 watchOS **拒绝后台续录**（必须是用户主动操作），
/// 失去活跃会话的 App 随即被挂起——`WatchRecorderModel` 的重试梯子
/// （0.5s/1.5s/3s）根本没机会跑。manifest 里今天的录音全是 2~4 分钟的
/// 短片段，就是这个死法留下的尸检报告。
///
/// `HKWorkoutSession` 是 Apple 给"长时间后台工作"的正规通道：workout
/// 存续期间 App **不会被挂起**，打断结束后仍留在后台运行，续录重试
/// 才真正有机会执行。这也是为什么健身 App 能连续录几个小时的音频。
///
/// ## 边界
/// · App 不读也不写任何健康数据——workout session 只是保活载体；
/// · 授权被拒 / HealthKit 不可用时静默降级：录音照常，只是退回旧的
///   后台存活率（打日志，不弹错误）；
/// · session 必须在**前台**启动（Apple 要求）——开录本来就在前台，成立。
@MainActor
final class WatchWorkoutKeeper {

    static let shared = WatchWorkoutKeeper()

    private var session: HKWorkoutSession?
    private var healthStore = HKHealthStore()
    /// 授权问过一次就不再问（`notDetermined` 才会弹系统框）。
    private var authRequested = false

    /// 麦克风授权通过后调用一次（幂等）。拒绝也不影响录音——只是保活降级。
    func requestAuthorizationIfNeeded() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard !authRequested else { return }
        authRequested = true
        healthStore.requestAuthorization(toShare: [.workoutType()], read: []) { granted, error in
            // 后台队列回调：只打日志，授权结果不阻塞录音。
            if let error {
                log.warning("HealthKit auth error: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("HealthKit auth granted=\(granted, privacy: .public)")
            }
        }
    }

    /// 开录时调用。失败静默（录音不受影响），原因进日志。
    func start() {
        guard HKHealthStore.isHealthDataAvailable() else {
            log.warning("workout keeper: HealthKit unavailable — background keep-alive degraded")
            return
        }
        guard session == nil else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .other          // 录音不是运动；`.other` 是诚实的选择
        config.locationType = .indoor
        do {
            let workout = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            workout.startActivity(with: Date())
            session = workout
            log.info("workout keeper: session started")
        } catch {
            // 最常见的失败原因：HealthKit 授权还没批下来（首次录音授权是异步的）。
            // 下次开录就正常了；本次退回"无保活"的老路径。
            log.warning("workout keeper: session refused (\(error.localizedDescription, privacy: .public)) — degraded")
        }
    }

    /// 停录时调用。workout 不落库（没挂 builder，`end()` 后系统不留痕）。
    func stop() {
        guard let session else { return }
        self.session = nil
        session.end()
        log.info("workout keeper: session ended")
    }
}
