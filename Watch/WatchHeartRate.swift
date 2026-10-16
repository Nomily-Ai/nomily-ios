import Foundation
import HealthKit

// MARK: - 手表实测的心率
//
// ⛔⛔ **2026-10-16 十五改：整个文件已经停用，当前没有任何调用方。**
//
// 停用原因（用户原话）："录音时候的那个音波起伏还是根据声音周围录音分贝吧，
// 不要走心率来，因为他现在不准确都是一条白色直的"。
//
// 它当初（十一改）被写出来只有**一个**用途：定那条音波的心跳底型走多快。
// 十五改把那条波改成纯麦克风电平驱动之后，这个类就没有消费者了。
// 连带的失效点（都已删干净）：
//   · `WatchRecorderModel.heartRate` / `.prepareHeartRate()` / `heart.follow()`
//   · `WatchRecorderView` 里的权限申请与那行心率读数
//   · `WatchVoiceWave` 的 `bpm` 参数（连同 `beat` 底型表）
//
// ## 为什么是"停用"而不是"删掉"
// 这里攒了一条**没法从别处查到**的结论（见下面那几段）：watchOS 上非运动状态
// 拿不到"每秒级"心率、唯一的路是 `HKWorkoutSession` 而它的代价是表盘上出现
// 绿色运动图标；以及"锚定查询看起来更实时、实际整场录音可能一次都不回调"。
// 这些是评估过一轮才留下的判断，删了下次还得重跑一遍。
//
// ## ⚠️ 如果哪天要恢复
// 两件事一起做，别只做一半：
//   ① 在 `WatchRecorderModel.start()` / `stop()` 里成对地 `follow()` / `unfollow()`，
//      并在 `WatchRecorderView.onAppear` 里调一次 `prepare()`；
//   ② **不要**再让它去开合那条波的闸门 —— 十四改就是那么翻车的：
//      读不到心率（静息时十几分钟一条、或者用户没给权限）时整条波被冻成直线。
//      心率只能当**附加信息**，不能当**必要条件**。
//
// ## 它解决的是什么
// 十改那条波的心跳底型是一张**写死的**表：十格 = 0.8 秒 ≈ **75 次/分**。
// 那是一个"成年人的平均静息心率"，不是**这个人此刻**的心率。用户要的是
// "跟着我的心跳跳" —— 所以这里去 HealthKit 读真实读数，拿它定那条波的周期。
//
// ## ★ 为什么是"轮询最近一条"，而不是 `HKAnchoredObjectQuery`
// 锚定查询只在**新样本落库**那一刻回调。而 Apple Watch 在**非运动状态下**
// 存心率的节奏完全由系统决定 —— 静息时可能好几分钟才一条。也就是说锚定查询
// 看起来更"实时"，实际很可能**整场录音一次都不回调**，那条波反而全程在跑兜底值
// —— 一个"看着高级但其实不工作"的实现。
//
// 所以这里反过来：**每 8 秒主动问一次"最近一条心率是多少"**。
//   · 传感器给得快 → 8 秒内必定拿到新值；
//   · 传感器给得慢 → 拿到的还是上一条（几分钟内心率本来就没多少变化，够用）；
//   · 一直没有 → 保留上一个值；从头就没有 → 视图侧回落 75。
// 三种情况都有确定的、能解释的行为，这比"等推送"可控得多。
//
// ## ⚠️ 拿不到"每秒级"心率 —— 这是 Apple 的限制，不是这里的疏漏
// 想让心率传感器真的高频采样，唯一的办法是开 `HKWorkoutSession`。
// 代价：表盘上出现**绿色运动图标**、更费电，而且"录音"根本不是运动 ——
// 为一个录音机开运动会话，观感和语义都不对。评估下来不值，没走。
// **这条说明是留给以后的人（和以后的自己）的**：如果哪天用户说"心率不够实时"，
// 答案在这里，不是去改那个 8 秒。
//
// ## ⚠️ 权限被拒时静默降级，不弹任何错
// HealthKit 对**读**权限故意不告诉你结果（`authorizationStatus(for:)` 对读类型
// 会一直回 `.notDetermined`），所以这里压根不去判"有没有被拒"——
// 查得到就更新，查不到就保持兜底。用户拒了权限，那条波退回原来的固定节律，
// 不会因为"读不到心率"而报错或者变空。
@MainActor
final class WatchHeartRateMonitor {
    /// 读到新心率时回调（**一定在主线程**）。参数是 bpm。
    var onUpdate: ((Double) -> Void)?

    private let store = HKHealthStore()

    /// `.heartRate` 在本项目的部署目标（watchOS 10）上必然存在。
    /// 用可选 + `guard` 而不是强解包 —— 不为一个理论上不会发生的情况留崩溃点。
    private var heartType: HKQuantityType? {
        HKQuantityType.quantityType(forIdentifier: .heartRate)
    }

    /// `count/min`，也就是 bpm。
    private let unit = HKUnit.count().unitDivided(by: .minute())

    private var poll: Timer?
    /// 平滑后的心率。见 `ingest`。
    private var smoothed: Double?

    /// 多久问一次 HealthKit。
    ///
    /// ⚠️ 8 秒是权衡：再快没有意义（传感器本身就慢），再慢则"换了姿势心率上去了"
    ///    要等太久才反映到那条波上。见文件顶部那段。
    private static let pollInterval: TimeInterval = 8

    /// 多久以前的样本还算"当前心率"。
    ///
    /// 15 分钟是刻意放宽的：静息时手表可能就是这个节奏才存一条，卡太紧会让
    /// 读数频繁作废、那条波在两套节律之间来回跳 —— 比用一个稍旧的值更糟。
    private static let maxSampleAge: TimeInterval = 900

    /// 新值占多少比重。
    ///
    /// ⚠️ 必须平滑。HealthKit 里相邻两条读数会上下抖几个 bpm（测量噪声），
    /// 直接拿原始值定周期，那条波的快慢会跟着一抖一抖 —— 看起来像故障。
    /// 0.35 是"跟得上真实变化、又不跟着噪声跳"那一档（约 3 个采样内收敛）。
    private static let smoothing = 0.35

    // MARK: - 权限

    /// 申请读心率的权限。**与录音无关，在首页出现时调一次就好。**
    ///
    /// ⚠️ 刻意**不放在录音开始时**：那一刻弹一张系统授权页，很可能把刚开始的
    ///    录音打断（授权页是系统模态）。放在首页出现时，用户还没开始录，
    ///    打断了也没有损失。
    ///
    /// ⚠️ 这个方法可以在每次启动时放心调用：`getRequestStatusForAuthorization`
    ///    在用户已经回答过之后返回 `.unnecessary`，系统也不会把授权页弹第二次。
    func prepare() {
        guard HKHealthStore.isHealthDataAvailable(), let type = heartType else { return }
        let read: Set<HKObjectType> = [type]
        store.getRequestStatusForAuthorization(toShare: [], read: read) { [weak self] status, _ in
            guard status == .shouldRequest, let self else { return }
            self.store.requestAuthorization(toShare: [], read: read) { _, _ in }
        }
    }

    // MARK: - 跟随录音起停

    /// 开始跟随。**录音开始时调。**
    func follow() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        stopPolling()
        smoothed = nil

        // 立刻读一次，别让那条波开场先跑几秒兜底值。
        readLatest()

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readLatest() }
        }
        // `.common` 而不是默认 mode：默认 mode 在滚动/跟踪期间会被暂停，
        // 而这一页正好有横向翻页手势 —— 用默认 mode 会在滑动时悄悄停掉采样。
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    /// 停止跟随。**录音结束时调。**
    func unfollow() {
        stopPolling()
        // 不清 `smoothed`：同一个人前后两次录音的心率差不多，
        // 下次开场直接从这个值起步比从头（无值 → 兜底 75）更连贯。
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    // MARK: - 读

    private func readLatest() {
        guard let type = heartType else { return }
        let start = Date().addingTimeInterval(-Self.maxSampleAge)
        let query = HKSampleQuery(
            sampleType: type,
            predicate: HKQuery.predicateForSamples(withStart: start, end: nil),
            limit: 1,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
        ) { [weak self] _, samples, _ in
            guard let sample = samples?.first as? HKQuantitySample else { return }
            let bpm = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            Task { @MainActor in self?.ingest(bpm) }
        }
        store.execute(query)
    }

    private func ingest(_ bpm: Double) {
        // 明显不合理的值直接丢：0 或负数一定是坏的（传感器没贴紧时的典型输出），
        // 而一个 0 会把那条波直接冻成一条平线。
        guard bpm > 20, bpm < 250 else { return }
        let next = smoothed.map { $0 + (bpm - $0) * Self.smoothing } ?? bpm
        smoothed = next
        onUpdate?(next)
    }
}
