import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "jobs")

/// 活的种类。
///
/// ★ 2026-10-16 十二改新增。四种，但**这个队列只管其中三种** —— 见 `JobQueue`
/// 顶部"为什么转录不在里面"。
enum JobKind: String, Codable, CaseIterable {
    /// 批量转录（ASR）。**只作为枚举里的一个成员存在**，这样任务总览页能把
    /// 四类活摆在同一个列表里；它的调度仍然在 `TranscriptionService`。
    case transcribe
    case summarize
    case translate
    case export

    var symbol: String {
        switch self {
        case .transcribe: return "waveform"
        case .summarize:  return "sparkles"
        case .translate:  return "character.book.closed"
        case .export:     return "square.and.arrow.up"
        }
    }

    var title: String {
        switch self {
        case .transcribe: return L10n.Jobs.kindTranscribe
        case .summarize:  return L10n.Jobs.kindSummarize
        case .translate:  return L10n.Jobs.kindTranslate
        case .export:     return L10n.Jobs.kindExport
        }
    }
}

/// 一条**还没干完**（或刚干完）的活。
///
/// ## 为什么参数是一个"扁平的可选袋子"而不是带关联值的枚举
/// 三种活各自的参数只有一两项，而且全都是"字符串/数字"这种能直接进 JSON 的
/// 东西。为它们各写一套 `Codable`（连带 `JobKind` 的关联值编码、以及每种活的
/// 解码分支）会把文件撑大三倍，换来的只是"类型上更紧"这一条 —— 而那些参数
/// 的唯一消费者是同文件里的 `JobRunners`，`switch` 一写就全在眼前。
///
/// ⚠️ 这个袋子是**向前兼容**的：合成出来的 `init(from:)` 对 `Optional` 字段走
///    `decodeIfPresent`，所以**旧的 jobs-queue.json 里缺新字段不会解不开**，
///    将来加第四种活也不用动解码。这正是它相对关联值枚举的唯一优势，别丢。
///
/// ⚠️ `id` 是**幂等键**：同一个 `id` 再入队一次不会产生第二条活，而是把
///    重试计数清零（用户又主动点了一次，说明上次的放弃不算数）。这与
///    `TranscriptionService.PendingJob` 用文件名当键是同一个思路。
struct Job: Codable, Identifiable, Equatable {
    var id: String
    var kind: JobKind
    /// 这条活挂在哪条录音上（`LibraryItem.name`）。也是界面主标题。
    var clipName: String
    var attempts: Int = 0
    /// 最后一轮失败的原因。**成功时保持 nil** —— 界面靠它 + `finishedAt`
    /// 两个字段就能把"完成"和"试满放弃"分开，不需要第三个状态字段。
    var lastError: String?
    var enqueuedAt: Date
    /// 跑完（成功或放弃）的时刻。`nil` = 还没出队。
    var finishedAt: Date?

    /// 分段进度。只有摘要那条路会填（`LLMCompletionService.completeChunked`）。
    var progressDone: Int?
    var progressTotal: Int?
    /// 跑完之后由 runner 补上的**结果附注**（"其实是 Ollama 兜底生成的"、
    /// "内容太长被分成了 5 段"）。
    ///
    /// ⚠️ 为什么必须跟着产物一起落地、而不是只留在视图的内存里：十二改之后
    ///    这条活**很可能是在用户看不见的时候跑完的**（那正是这个改动的目的），
    ///    等用户回来看时手里已经没有 `Outcome` 了。附注留不住，用户那句
    ///    "我明明设的是 Open Router，怎么是 Ollama 生成的"就永远没人回答。
    var notes: [String]?
    /// 模型自己说它撞到输出上限了、正文是**截断**的。半截的摘要读起来和
    /// 完整的一模一样，所以这一条必须传到界面，不能默默咽掉。
    var wasTruncated: Bool?

    // MARK: 参数（按 kind 取用，其余为 nil）

    /// `summarize`：**最终**的 system prompt（已经拼上输出语言指令）。
    ///
    /// ⚠️ 存的是成品 prompt、不是模板 id：这条活可能在**几天后**才被
    ///    "重启续跑"捞起来，那时用户完全可能已经把那个模板改过或删了。
    ///    活的内容应该定格在"用户按下按钮的那一刻"，而不是跟着配置漂。
    var prompt: String?
    /// `summarize`：模板名。**只用于界面显示**，跑的时候不读它。
    var templateName: String?
    /// `translate`：目标语言的英文名（喂给 prompt 用，见 `LLMCompletionService.translate`）。
    var languageName: String?
    /// `translate`：翻的是转录还是摘要（`"transcript"` / `"summary"`）。
    var translateTarget: String?
    /// `export`：`m4a` / `wav`。
    var exportFormat: String?

    /// 一轮都没跑完、还能再试 —— 与 `TranscriptionService.runDrainLoop` 里
    /// 那道 `attempts < maxAttempts` 是同一个判据。
    var isRunnable: Bool { finishedAt == nil && attempts < JobQueue.maxAttempts }

    /// 界面副标题要的那点"这是哪种活、什么变体"。
    var detail: String? {
        switch kind {
        case .summarize: return templateName
        case .translate:
            if let name = languageName, let target = translateTarget {
                return target == "summary"
                    ? L10n.Jobs.detailTranslatedSummary(name)
                    : L10n.Jobs.detailTranslatedTranscript(name)
            }
            return languageName
        case .export:    return exportFormat?.uppercased()
        case .transcribe: return nil
        }
    }
}

/// 一条活**永远不可能成功**（源文件已经不在了）。
///
/// 单独一个类型是为了让队列能把它与"这一轮失败、等会儿再试"分开：
/// `TranscriptionService` 那边是靠 drain 循环里的 `fileExists` 直接 `forget`，
/// 而这里三种活的"源头"各不相同（导出要音频、摘要与翻译要转录或摘要文件），
/// 只有 runner 自己知道缺的是什么 —— 所以判据由它抛出来，队列照单执行。
struct JobSourceMissing: LocalizedError {
    let what: String
    var errorDescription: String? { L10n.Jobs.sourceMissing(what) }
}

/// 摘要 / 翻译 / 格式转换三类长任务的**落盘台账 + 串行泵**。
///
/// ## 为什么要有它
/// 用户的原话：**"生成摘要还有翻译，还有转录，还有转换音频格式……这个可先退出
/// 后台等完成后在进行查看跟分析"**。
///
/// 拆开看，"切出去继续跑"那半边**本来就已经成立**：`BackgroundKeeper` 的四个
/// 令牌里 `summary` / `export` 早就在被占用，静音音频 + `audio` 后台模式顶得住
/// 切走、锁屏、甚至长时间挂着。真正缺的是另一半：**进程被系统咔嚓掉（或用户
/// 强杀）之后，这三类活凭空消失** —— 转录有一份落盘的清单（
/// `transcription-queue.json`）能捞回来，另外三类只有内存里的 `Task`。
/// 用户在详情页点了"生成摘要"、切走、回来发现什么都没发生，就是这个缺口。
///
/// 于是这个类和 `TranscriptionService` 的队列**长得几乎一样**（尝试计数、
/// 指数退避、可重试判定、串行泵、跨启动恢复），因为那套语义正是这里需要的。
///
/// ## ★ 为什么转录**没有**搬进来（一个刻意的"不统一"）
/// 把四类活合进同一个 `Job<Kind>` 是更漂亮的抽象，但代价是重写
/// `TranscriptionService` 那 620 行里最要紧的一段：它有一整套已经跑通的语义 ——
/// 按文件名去重（两次 UI 同时要同一条录音只跑一次）、`enqueueAndWait`
/// （手表到货那条路要等它出队再刷新资料库）、启动时清理孤儿条目、以及
/// **ASR 专属**的可重试判定（缺密钥/没配 provider/时长不够都不重试，其余都试）。
/// 那些语义**一条都不能靠"看起来等价"来推断**，而这个 App 里转录是唯一一条
/// 用户反复用过、且被明确说过"老是失败"的路。
///
/// ⇒ 结论：**共同的是"任务总览"这一层，不是"调度"这一层。** 总览页
///   （`TaskCenterView`）把 `transcription.pending` 和这里的 `jobs` 摆进同一个
///   列表；两边各自的泵、各自的落盘、各自的重试判据都不动。
///   如果将来两类活真的需要互相让路（比如"摘要等转录先跑完"），再谈合并 ——
///   那时合并的理由是**耦合**，而不是"看起来应该统一"。
///
/// ## 泵为什么是串行的
/// 三条活里有两条打同一个 LLM（`LLMCompletionService`），而本机 Ollama 的推理
/// 本来就是串行的 —— 并发提交只会让两边都变慢，还会把 3B 模型的 `num_ctx`
/// 挤爆。导出（CPU/IO）排在后面只是晚一会儿开始，不会失败。这与
/// `TranscriptionService.runDrainLoop` 里"ASR 侧本来就有额度"是同一个判决。
@MainActor
final class JobQueue: ObservableObject {

    /// 一条活最多试几轮：1 次首发 + 2 次重试。与转录那边同口径 ——
    /// 本机 Ollama 一轮几分钟，试 5 次用户会以为卡死。
    ///
    /// ⚠️ `nonisolated`：`Job.isRunnable` 是值类型上的非隔离计算属性，要读它。
    ///    不加的话编译能过但会报"main actor-isolated static property can not be
    ///    referenced from a nonisolated autoclosure"，而那是 Swift 6 的**错误**。
    ///    不可变 `let` + `Int`，隔离不带来任何保护，去掉是安全的。
    nonisolated static let maxAttempts = 3

    /// 干完的活留多久。总览页要能回答"我刚才那条跑完了吗"，所以完成的条目
    /// **不立刻删**；但也不能无限攒 —— 一天足够覆盖"睡一觉回来看看"。
    nonisolated static let finishedRetention: TimeInterval = 24 * 3600
    /// 干完的活最多留几条（超过就丢最老的）。两道闸一起上：时间管日常，
    /// 条数管"一天里跑了几百条标题"那种极端。
    nonisolated static let finishedLimit = 60

    /// 排着队 + 刚干完的活，按入队时间倒序。
    @Published private(set) var jobs: [Job] = []

    /// 此刻正在执行的活（`id`）。界面用它区分"进行中"和"排队中"。
    @Published private(set) var running: Set<String> = []

    /// 每种活的执行体。**由组合根注册**（`AppEnvironment`），不在这个文件里
    /// 直接引用 LLM / 导出器 —— 那样这个类就得同时知道三套服务的构造方式，
    /// 而它真正需要知道的只有"给我一条活，我去跑、跑完告诉我结果"。
    typealias Runner = @MainActor (Job, Reporter) async throws -> Void

    /// 执行体回话用的小把手：跑的时候报进度，跑完补附注。
    ///
    /// ⚠️ 一个结构体而不是两个闭包参数：将来再加一种回话（比如"我其实被
    ///    别的活挡着"）不用同时改 `Runner` 的三处签名与三个执行体。
    ///
    /// ⚠️ 函数类型的参数**不能带标签**（`(done: Int, total: Int) -> Void` 是
    ///    编译错误），所以这里一律写裸 `Int`，调用点靠字段名 self-document。
    struct Reporter {
        /// 分段进度（长转录）。**不要求一定上报** —— 不上报就是"转圈但没数字"，
        /// 与十二改之前的行为一致。
        let progress: (Int, Int) -> Void
        /// 干完之后补一段"给用户看的结果附注"。见 `Job.notes`。
        /// 参数是 `(附注, 结果是否被截断)`。
        let notes: ([String], Bool) -> Void
    }

    private var runners: [JobKind: Runner] = [:]
    private var drainTask: Task<Void, Never>?
    /// 等在某个 `id` 出队的续体（`wait(for:)`）。
    private var waiters: [String: [CheckedContinuation<Job?, Never>]] = [:]

    init() {
        jobs = Self.load()
        pruneFinished()
    }

    // MARK: - 注册执行体

    /// 幂等：重复注册同一个 kind 直接覆盖（组合根只会调一次，但覆盖比崩溃好）。
    func register(_ kind: JobKind, runner: @escaping Runner) {
        runners[kind] = runner
    }

    // MARK: - 入队 / 查询

    /// 入队。**先落盘再开跑** —— 区别只在"App 中途被杀"这一种情况下才看得出来。
    func enqueue(_ job: Job) {
        guard job.kind != .transcribe else {
            // 转录有自己的队列，走 `TranscriptionService`；这里挡一道是为了让
            // 调用方的错误当场炸出来，而不是安静地排进一个永远不会跑的队列。
            assertionFailure("transcribe jobs belong to TranscriptionService, not JobQueue")
            return
        }
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            // 已经在队列里：不重复加，但把重试计数清零、把刚干完的重新变成待办
            // （用户又主动要了一次，说明上一次的结果他不满意）。
            jobs[idx].attempts = 0
            jobs[idx].lastError = nil
            jobs[idx].finishedAt = nil
            jobs[idx].progressDone = nil
            jobs[idx].progressTotal = nil
            jobs[idx].notes = nil
            jobs[idx].wasTruncated = nil
            jobs[idx].enqueuedAt = Date()
            // 参数以**新**的这一份为准：用户可能换了模板 / 换了目标语言 /
            // 换了导出格式，那就是另一条活了。
            jobs[idx] = merged(jobs[idx], with: job)
        } else {
            jobs.insert(job, at: 0)
        }
        save()
        log.info("enqueued \(job.kind.rawValue, privacy: .public) id=\(job.id, privacy: .public)")
        startDrainIfNeeded()
    }

    /// 保留旧条目的身份与计数，把新条目的参数盖上去。
    private func merged(_ old: Job, with new: Job) -> Job {
        var merged = new
        merged.id = old.id
        merged.kind = old.kind
        merged.clipName = old.clipName
        merged.enqueuedAt = old.enqueuedAt
        return merged
    }

    func job(id: String) -> Job? { jobs.first { $0.id == id } }

    /// 这条录音上还没干完的活（界面用它决定按钮要显示"开始"还是"进行中"）。
    func activeJobs(for clipName: String) -> [Job] {
        jobs.filter { $0.clipName == clipName && $0.finishedAt == nil }
    }

    func isRunning(id: String) -> Bool { running.contains(id) }

    /// 给界面用的三态。
    enum State: Equatable {
        case waiting, running, done, gaveUp
    }

    func state(of job: Job) -> State {
        if running.contains(job.id) { return .running }
        if job.finishedAt != nil { return job.lastError == nil ? .done : .gaveUp }
        return .waiting
    }

    /// 还没干完的条数（含排队与进行中）。设置页那一行靠它决定要不要出现。
    var unfinishedCount: Int {
        jobs.filter { $0.finishedAt == nil }.count
    }

    /// 干完的条数（成功 + 放弃）。总览页用它决定要不要显示"清除已完成"。
    var finishedCount: Int {
        jobs.filter { $0.finishedAt != nil }.count
    }

    // MARK: - 取消 / 重试 / 清理

    /// 取消一条活。
    ///
    /// 已经在跑的那条靠 `Task.cancel()` 打断（runner 内部的 URLSession 请求会
    /// 跟着断）；还在排队的靠**直接把它标记成"干完但没错误"** —— 也就是从
    /// 队列里出列，但不出现在"放弃"那一类里。取消是用户的意图，不是失败。
    func cancel(id: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        runningTasks[id]?.cancel()
        runningTasks[id] = nil
        guard jobs[idx].finishedAt == nil else { return }
        jobs[idx].finishedAt = Date()
        jobs[idx].lastError = nil
        jobs[idx].progressDone = nil
        jobs[idx].progressTotal = nil
        // 取消掉的活不该留着上一轮的结果附注 —— 那不是这一轮的结果。
        jobs[idx].notes = nil
        jobs[idx].wasTruncated = nil
        save()
        log.info("cancelled \(id, privacy: .public)")
        resumeWaiters(id: id)
    }

    /// 再试一次。**会重新获得 3 次机会**，与 `TranscriptionService.enqueue`
    /// 里"用户又主动要了一次，上次的放弃不算数"同一条。
    func retry(id: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].attempts = 0
        jobs[idx].lastError = nil
        jobs[idx].finishedAt = nil
        jobs[idx].notes = nil
        jobs[idx].wasTruncated = nil
        jobs[idx].enqueuedAt = Date()
        save()
        startDrainIfNeeded()
    }

    /// 从台账里彻底抹掉一条（用户看完了、不想要了 / 源头已经不在了）。
    func forget(id: String) {
        guard jobs.contains(where: { $0.id == id }) else { return }
        jobs.removeAll { $0.id == id }
        save()
    }

    func clearFinished() {
        jobs.removeAll { $0.finishedAt != nil }
        save()
    }

    /// 某条录音的所有活（录音被删 / 被清空时要一起收掉）。
    func forgetAll(clipName: String) {
        let before = jobs.count
        jobs.removeAll { $0.clipName == clipName }
        guard jobs.count != before else { return }
        save()
    }

    // MARK: - 起停

    /// 重启那些还没干完的活。挂在两个点：`AppEnvironment.init`（冷启动）
    /// 与 `RootView` 回到前台 —— 与 `transcription.resumePending()` 完全对称。
    ///
    /// 重入由 `startDrainIfNeeded` 挡着，重复调安全。
    func resume() {
        guard jobs.contains(where: { $0.isRunnable }) else { return }
        startDrainIfNeeded()
    }

    /// 等一条活**出队**（成功、试满放弃、被取消、或源头已经不在）。
    ///
    /// 给"要等结果再刷新界面"的调用方用（与
    /// `TranscriptionService.enqueueAndWait` 同一个用途）。
    /// 已经在队列里找不到这条时立刻返回 —— 那种情况说明它在**入队之前**
    /// 就已经干完了，等着只会挂住调用方。
    @discardableResult
    func wait(for id: String) async -> Job? {
        guard let snapshot = job(id: id), snapshot.finishedAt == nil else {
            return job(id: id)
        }
        return await withCheckedContinuation { cont in
            waiters[id, default: []].append(cont)
        }
    }

    // MARK: - 泵

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDrainLoop()
            self.drainTask = nil
        }
    }

    /// 正在跑的活 → 它的 `Task`（取消用）。
    ///
    /// ⚠️ 单独一层 `Task` 而不是直接 `await runner(...)`，唯一的目的就是拿到
    ///   一个能 `cancel()` 的把手。`cancel(id:)` 也是 `@MainActor`，所以"存进
    ///    字典"与"被取消"之间不存在竞态 —— 存的动作发生在第一处 `await` 之前。
    private var runningTasks: [String: Task<Result<Void, Error>, Never>] = [:]

    /// 串行地把队列里的活跑一遍。
    private func runDrainLoop() async {
        while let job = jobs.first(where: { $0.isRunnable }) {
            guard let runner = runners[job.kind] else {
                // 组合根没注册这一种活（不可能发生，但静默不跑会让队列永远
                // 卡在同一条上 —— 那是最难查的一种"什么都没发生"）。
                log.error("no runner registered for \(job.kind.rawValue, privacy: .public); dropping")
                markFinished(id: job.id, error: L10n.Jobs.noRunner)
                continue
            }
            running.insert(job.id)

            // ⚠️ 必须用 `Task { }`（带 `_inheritActorContext`），不能用
            //    `.task` / `Task.detached`：后两者的闭包是 `@Sendable`，捕获
            //    这个含闭包的类会踩并发检查，而本工程是零告警的
            //    （同一个坑见 `WatchBotFace` 顶部那段）。
            let handle = Task { @MainActor in
                let reporter = Reporter(
                    // 两个回调都 [weak self]：活跑起来之后队列**不应该**被这些
                    // 闭包吊着（虽然它本来就活到进程结束，但那是巧合不是契约）。
                    progress: { [weak self] done, total in
                        self?.recordProgress(id: job.id, done: done, total: total)
                    },
                    notes: { [weak self] notes, truncated in
                        self?.recordNotes(id: job.id, notes: notes, truncated: truncated)
                    }
                )
                do {
                    try await runner(job, reporter)
                    return Result<Void, Error>.success(())
                } catch {
                    return Result<Void, Error>.failure(error)
                }
            }
            runningTasks[job.id] = handle
            let outcome = await handle.value

            runningTasks[job.id] = nil
            running.remove(job.id)

            switch outcome {
            case .success:
                markFinished(id: job.id, error: nil)
            case .failure(let error) where error is JobSourceMissing:
                // 源头已经不在（录音被删了、转录被清了）。重试一万次也没用，
                // 直接抹掉 —— 与转录队列里 `forget(name:)` 那一步同一个判决。
                log.info("dropping \(job.id, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                forget(id: job.id)
                resumeWaiters(id: job.id)
            case .failure(let error) where Self.isCancellation(error):
                // 用户按了取消：当成"干完了但没错误"，留在列表里但不再重来。
                markFinished(id: job.id, error: nil)
            case .failure(let error):
                guard let idx = jobs.firstIndex(where: { $0.id == job.id }) else { continue }
                jobs[idx].attempts += 1
                jobs[idx].lastError = error.localizedDescription
                let attempts = jobs[idx].attempts
                save()
                if attempts >= Self.maxAttempts {
                    log.warning("giving up on \(job.id, privacy: .public) after \(attempts) attempts")
                    markFinished(id: job.id, error: error.localizedDescription)
                    continue
                }
                try? await Task.sleep(for: Self.backoff(afterAttempt: attempts))
            }
        }
    }

    /// 干完（成功 / 放弃 / 取消）。**不删条目** —— 见 `finishedRetention`。
    private func markFinished(id: String, error: String?) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].finishedAt = Date()
        jobs[idx].lastError = error
        jobs[idx].progressDone = nil
        jobs[idx].progressTotal = nil
        save()
        resumeWaiters(id: id)
    }

    private func recordProgress(id: String, done: Int, total: Int) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].progressDone = done
        jobs[idx].progressTotal = total
        // ⚠️ **不落盘**：分段进度是每段一次的高频写（一条长转录几十段），
        // 而它的价值只在"用户正看着这一页"的那几分钟里。进程被杀时丢掉进度、
        // 下轮从头报一次，代价远小于每段一次 atomic 写。
    }

    /// 跑完之后补上结果附注（见 `Job.notes`）。
    ///
    /// ⚠️ 这里**也不落盘**：紧随其后的 `markFinished` 一定会 `save()`，两条
    ///    写的是同一个文件。runner 里这个回调与 `return` 之间没有 `await`
    ///    （有的话调用点会插 `try Task.checkCancellation()`），所以不存在
    ///    "写了附注但没走到 markFinished"的窗口。
    private func recordNotes(id: String, notes: [String], truncated: Bool) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].notes = notes.isEmpty ? nil : notes
        jobs[idx].wasTruncated = truncated ? true : nil
    }

    private func resumeWaiters(id: String) {
        guard let list = waiters.removeValue(forKey: id) else { return }
        let snapshot = job(id: id)
        for cont in list { cont.resume(returning: snapshot) }
    }

    /// 第 `attempt` 轮失败后的等待。与转录那边同一组数字 —— 指数退避（2/8/30 秒），
    /// 不封顶到分钟级：用户多半就在看着这个进度，等太久不如早点报错让人重按。
    private static func backoff(afterAttempt attempt: Int) -> Duration {
        switch attempt {
        case 1: return .seconds(2)
        case 2: return .seconds(8)
        default: return .seconds(30)
        }
    }

    /// 取消的两种表现：Swift 并发的 `CancellationError`，以及 URLSession
    /// 被取消时抛的 `URLError.cancelled`。**必须都认**。
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    // MARK: - 磁盘

    private static func load() -> [Job] {
        guard let data = try? Data(contentsOf: StorageLocations.jobsQueueURL),
              let decoded = try? JSONDecoder().decode([Job].self, from: data) else {
            return []
        }
        return decoded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(jobs) else { return }
        try? FileManager.default.createDirectory(
            at: StorageLocations.root, withIntermediateDirectories: true
        )
        try? data.write(to: StorageLocations.jobsQueueURL, options: .atomic)
    }

    /// 启动时清理干完了的老条目。**只清"干完的"** —— 没干完的一条都不能动
    /// （那正是这个文件存在的理由）。
    ///
    /// 两道闸：时间（`finishedRetention`）管日常，条数（`finishedLimit`）管
    /// "一天里跑了几百条"那种极端。`jobs` 是**新在前**的，所以同一遍里
    /// "从头数够 limit 条之后的干完条目"正好就是最老的那些。
    private func pruneFinished() {
        let cutoff = Date().addingTimeInterval(-Self.finishedRetention)
        var kept: [Job] = []
        var finishedKept = 0
        for job in jobs {
            if let finishedAt = job.finishedAt {
                guard finishedAt >= cutoff else { continue }
                finishedKept += 1
                guard finishedKept <= Self.finishedLimit else { continue }
            }
            kept.append(job)
        }
        guard kept.count != jobs.count else { return }
        jobs = kept
        log.info("pruned \(self.jobs.count - kept.count) finished job(s) on load")
        save()
    }
}
