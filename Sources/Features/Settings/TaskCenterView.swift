import SwiftUI

/// 四类长任务的**总览**（★ 2026-10-16 十二改）。
///
/// ## 为什么这一页存在
/// 用户原话："生成摘要还有翻译，还有转录，还有转换音频格式……这个可先退出后台
/// 等完成后在进行查看跟分析"。
///
/// 拆开看是两件事：**"切走还在跑"** 与 **"回来看得到"**。前一件靠
/// `BackgroundKeeper` 加两条落盘队列；后一件就得靠这一页 —— 没有它，活跑完了
/// 只表现为"资料库里那条录音多了一份摘要"，用户看不出那是自己刚才排的队，
/// 也看不出它是跑完了、还是失败了、还是压根没开始。
///
/// ## 为什么四类活摆在一个列表里，却来自两个来源
/// 转录的调度仍在 `TranscriptionService`（620 行，一整套已经跑通的语义：
/// 按文件名去重、`enqueueAndWait`、启动清孤儿、ASR 专属的重试判据），
/// 摘要 / 翻译 / 格式转换在 `JobQueue`。这一页把两边的条目**抹平成同一种行**
/// —— 共同的是"总览"这一层，不是"调度"那一层。理由详见 `JobQueue` 顶部那段
/// "为什么转录没有搬进来"。
///
/// ## 行内操作的发现性问题
/// 取消 / 移除走系统原生的**左滑**（`.swipeActions`）—— 它必须与整行可点
/// （进详情页）共存，而把按钮塞进 `NavigationLink` 的 label 里点击会被链接
/// 吃掉。唯一的例外是"重试"：失败那一行**本来就不能点进去**（没有可看的结果），
/// 所以它上面那颗按钮是直接摆在行里的，看得见。
struct TaskCenterView: View {
    @EnvironmentObject private var jobs: JobQueue
    @EnvironmentObject private var transcription: TranscriptionService

    var body: some View {
        List {
            let active = rows(unfinished: true)
            let finished = rows(unfinished: false)

            if active.isEmpty && finished.isEmpty {
                emptyState
            }
            if !active.isEmpty {
                Section {
                    ForEach(active) { rowView($0) }
                } header: {
                    Text(L10n.Jobs.sectionActive)
                }
            }
            if !finished.isEmpty {
                Section {
                    ForEach(finished) { rowView($0) }
                } header: {
                    Text(L10n.Jobs.sectionFinished)
                }
            }

            Section {
                Text(L10n.Jobs.footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.Jobs.pageTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if jobs.finishedCount > 0 || stuckTranscriptionCount > 0 {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Jobs.clearFinished) { clearFinished() }
                }
            }
        }
    }

    /// 转录那条队列里"试满放弃"的条数。
    ///
    /// 为什么它也算"已完成"：对用户来说那就是一条**有了结果**的活（结果是
    /// 失败）。"清除已完成"不清它的话，点完之后列表里还留着一行，看着像没生效。
    private var stuckTranscriptionCount: Int {
        transcription.pending.filter { $0.attempts >= TranscriptionService.maxAttempts }.count
    }

    /// 清除已完成的条目。
    ///
    /// 转录那条队列没有"清除"这个概念（它成功就自己出列、失败就一直留着供
    /// 重试），所以这里替它做同一件事：把放弃的条目取消掉，也就是从台账里
    /// 抹掉。用户既然按了"清除已完成"，他要的就是"这些我不看了"。
    private func clearFinished() {
        jobs.clearFinished()
        for pending in transcription.pending
        where pending.attempts >= TranscriptionService.maxAttempts {
            transcription.cancel(name: pending.name)
        }
    }

    // MARK: - 行模型

    /// 列表里的一行。
    ///
    /// 两个来源（`JobQueue` 与转录队列）在**这一页**被抹平成同一种东西 ——
    /// 这正是这一页存在的意义。刻意不做成一个共用的领域模型：那会逼着两条
    /// 队列去共享一套字段，而它们本来就需要不同的字段（转录要多语言、
    /// 摘要要 prompt、导出要格式）。
    private struct Row: Identifiable {
        enum Origin {
            case job(Job)
            case transcription(TranscriptionService.PendingJob)
        }

        let id: String
        let kind: JobKind
        let clipName: String
        let status: JobQueue.State
        let detail: String?
        let error: String?
        let progress: (done: Int, total: Int)?
        let enqueuedAt: Date
        let origin: Origin
        /// 能查到就用它跳详情页；`nil` = 音频已经不在了（只剩文本产物，或者
        /// 连产物都被删了）。那种情况下这一行不可点。
        let item: LibraryItem?
    }

    /// 把两个来源的行拼成一个列表，按入队时间倒序（新的在上面）。
    private func rows(unfinished: Bool) -> [Row] {
        var out: [Row] = []

        for job in jobs.jobs {
            guard (job.finishedAt == nil) == unfinished else { continue }
            out.append(Row(
                id: job.id,
                kind: job.kind,
                clipName: job.clipName,
                status: jobs.state(of: job),
                detail: job.detail,
                error: job.lastError,
                progress: progress(of: job),
                enqueuedAt: job.enqueuedAt,
                origin: .job(job),
                item: LibraryItem.readFromDisk(name: job.clipName, duration: nil)
            ))
        }

        // 转录那条队列与 `JobQueue` 的判据不同：它**成功就出列**（`forget`），
        // 所以留在 `pending` 里的只有两种 —— "在跑 / 在等" 与 "试满放弃"。
        // 没有"已完成"的转录行，这不是漏了，是那条队列本来就不留。
        for pending in transcription.pending {
            let stuck = pending.attempts >= TranscriptionService.maxAttempts
            guard stuck != unfinished else { continue }
            out.append(Row(
                id: "transcribe:\(pending.name)",
                kind: .transcribe,
                clipName: pending.name,
                status: stuck
                    ? .gaveUp
                    : (transcription.inFlight.contains(pending.name) ? .running : .waiting),
                // 转录的"变体"是识别语言（`locales`），与摘要的模板名同一个位置。
                detail: pending.locales?.joined(separator: ", "),
                error: pending.lastError,
                progress: nil,
                enqueuedAt: pending.enqueuedAt,
                origin: .transcription(pending),
                item: LibraryItem.readFromDisk(name: pending.name, duration: nil)
            ))
        }

        return out.sorted { $0.enqueuedAt > $1.enqueuedAt }
    }

    private func progress(of job: Job) -> (done: Int, total: Int)? {
        guard let done = job.progressDone, let total = job.progressTotal else { return nil }
        return (done, total)
    }

    // MARK: - 行

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        // 失败那一行不进详情页：那里没有"可看的结果"，点进去只会看到一个
        // 跟任务无关的页面。它的重点是把那颗"重试"露出来。
        if row.status != .gaveUp, let item = row.item {
            NavigationLink {
                ClipDetailView(item: item)
            } label: {
                rowLabel(row)
            }
            .swipeActions(edge: .trailing) { swipeActions(row) }
        } else {
            rowLabel(row)
                .swipeActions(edge: .trailing) { swipeActions(row) }
        }
    }

    @ViewBuilder
    private func rowLabel(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: row.kind.symbol)
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .frame(width: 16)
                Text(row.item?.displayTitle ?? row.clipName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                statusChip(row.status)
            }

            HStack(spacing: 5) {
                Text(row.kind.title)
                if let detail = row.detail, !detail.isEmpty {
                    Text("·")
                    Text(detail)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let error = row.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            if let progress = row.progress {
                ProgressView(
                    value: Double(progress.done),
                    total: Double(max(progress.total, 1))
                )
                .progressViewStyle(.linear)
            }

            // 唯一的**行内**操作：重试。理由见类型注释。
            if row.status == .gaveUp {
                Button(L10n.Jobs.retry) { retry(row) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusChip(_ state: JobQueue.State) -> some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini)
        case .waiting, .done, .gaveUp:
            Text(statusLabel(state))
                .font(.caption2)
                .foregroundStyle(statusColor(state))
        }
    }

    private func statusLabel(_ state: JobQueue.State) -> String {
        switch state {
        case .waiting: return L10n.Jobs.statusWaiting
        case .running: return L10n.Jobs.statusRunning
        case .done: return L10n.Jobs.statusDone
        case .gaveUp: return L10n.Jobs.statusGaveUp
        }
    }

    private func statusColor(_ state: JobQueue.State) -> Color {
        switch state {
        case .waiting, .running: return .secondary
        case .done: return .green
        case .gaveUp: return .orange
        }
    }

    // MARK: - 操作

    @ViewBuilder
    private func swipeActions(_ row: Row) -> some View {
        let busy = row.status == .waiting || row.status == .running
        if busy {
            Button(role: .destructive) { cancel(row) } label: {
                Label(L10n.Jobs.cancel, systemImage: "xmark")
            }
        }
        // 干完的条目才允许"移除"。还在排队的直接抹掉会让用户以为活跑过了，
        // 而他真正想做的是"不要它了" —— 那是取消。
        if !busy {
            Button(role: .destructive) { remove(row) } label: {
                Label(L10n.Jobs.remove, systemImage: "trash")
            }
        }
    }

    private func cancel(_ row: Row) {
        switch row.origin {
        case .job(let job): jobs.cancel(id: job.id)
        case .transcription(let pending): transcription.cancel(name: pending.name)
        }
    }

    private func retry(_ row: Row) {
        switch row.origin {
        case .job(let job): jobs.retry(id: job.id)
        case .transcription(let pending): transcription.retry(name: pending.name)
        }
    }

    private func remove(_ row: Row) {
        switch row.origin {
        case .job(let job): jobs.forget(id: job.id)
        // 转录那条队列没有"忘掉"这一步：它成功就自己出列，失败会一直留着
        // 供重试。所以对放弃掉的转录行，"移除"就是取消 —— 效果一致。
        case .transcription(let pending): transcription.cancel(name: pending.name)
        }
    }

    // MARK: - 空态

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(L10n.Jobs.empty)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
