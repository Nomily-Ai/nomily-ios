import SwiftUI

struct SummarizeSheet: View {
    /// 这条录音的转录正文。
    ///
    /// ⚠️ 十二改之后**它已经不用来喂模型了** —— 活由 `JobRunners` 从磁盘读
    ///    （见那里的 `transcriptText(for:)`，两条路喂进去的文本逐字同源）。
    ///    留着它是因为它还有一个真正的用途：调用点靠它判断"这条录音到底有没有
    ///    转录"，`use(_:)` 也靠它把"空转录"挡在入队之前。
    let transcriptText: String
    let audioName: String
    let onComplete: (String) -> Void

    @EnvironmentObject private var env: AppEnvironment
    /// 摘要落盘队列。单独注入的理由见 `ClipDetailView` 里同名字段。
    @EnvironmentObject private var jobs: JobQueue
    @Environment(\.dismiss) private var dismiss
    @StateObject private var templateStore = SummarizeTemplateStore()
    @StateObject private var languages = LanguageService()
    @State private var search = ""
    @State private var selected: SummarizeTemplate?
    /// ★ 2026-10-15 七改：正在看**概览**的那个模板。
    ///
    /// 非 nil 时选择页显示概览（名字 / 分类 / 说明 / 提示词全文 / 一个主按钮），
    /// 而不是网格 —— 对应用户那句"点击进去就是一个总体的概览"。
    ///
    /// 为什么不用 `NavigationLink` push 进去：本页是
    /// `Group { switch summarizeState }` 整体换页的，push 上去的那一层会在
    /// 状态切到 `.running` 时**连着被换掉**，栈里留什么不好预测。在同一层内
    /// 切换就没有这个问题，进出都受控。
    @State private var previewing: SummarizeTemplate?
    @State private var summarizeState: SummarizeState = .picking
    @State private var result = ""
    @State private var outputLangCode: String = ""
    @State private var showLangPicker = false
    /// ★ 2026-10-16 十二改：这条活在本队列里的 id（`summarize:<audioName>`）。
    /// 非 nil = 已经入了队，界面从此只**观察**它，不再自己跑。
    ///
    /// 上一版的 `pendingTitle` / `summarizeTask` / `workingProvider` 三个
    /// `@State` 都删掉了：摘要与标题的落盘搬进了 `JobRunners.summarize`，
    /// "真正干活的是哪个通道"也随 `Job.notes` 一起落盘了。留在这里的每一份
    /// 内存状态，在"App 被杀"面前都是要丢失而且会骗人的东西。
    @State private var jobID: String?
    /// The provider said it stopped because it hit the output cap. The text
    /// is real but cut off — say so instead of presenting it as finished.
    /// 这一条是**从台账读回来的**（`Job.wasTruncated`），不再由本地变量维护。
    @State private var wasTruncated = false
    /// 给用户看的说明：兜底顶上 / 走了分段。**必须显示** ——
    /// 用户设的是 A、结果是 B 生成的，不说明就成了"它到底用没用我的配置"。
    /// 同样是从台账读回来的（`Job.notes`）。
    @State private var notices: [String] = []
    /// 分段进度。`(已完成, 总段数)`；单段时为 nil。
    @State private var chunkProgress: (done: Int, total: Int)?
    /// 主通道不可用、但有兜底通道可用 —— 开工前先在页面上说清楚。
    @State private var preflightWarning: String?

    private enum SummarizeState {
        case picking
        case running
        case done
        case failed(String)
    }

    private var filtered: [SummarizeTemplate] {
        if search.isEmpty { return templateStore.templates }
        let q = search.lowercased()
        return templateStore.templates.filter {
            $0.name.lowercased().contains(q) ||
            $0.category.lowercased().contains(q)
        }
    }

    private var filteredCategories: [String] {
        var seen = Set<String>()
        return filtered.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch summarizeState {
                case .picking:
                    templatePicker
                case .running:
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text(L10n.Summarize.summarizingWith(activeProviderLabel))
                            .foregroundStyle(.secondary)
                        // 分段时给出"第几段"。长转录要跑好几分钟，
                        // 一个转不停的菊花和一句会变的数字，感受完全不同。
                        if let chunkProgress {
                            Text(L10n.Summarize.chunkProgress(chunkProgress.done, chunkProgress.total))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if let t = selected {
                            Text(t.name)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        // ★ 2026-10-16 十二改：这一页现在**可以关掉**，而且关掉
                        //   不影响它继续跑。这句话必须写出来 —— 上一版那颗
                        //   "取消"按钮让人以为一关就把活掐了，于是只能干等。
                        Divider().padding(.horizontal, 48)
                        Text(L10n.Jobs.canLeaveHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button(L10n.Common.close) { dismiss() }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done:
                    VStack(spacing: 0) {
                        if wasTruncated {
                            Label(L10n.Summarize.truncatedWarning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                .background(Color.orange.opacity(0.12))
                        }
                        // ★ 兜底 / 分段说明。非阻塞，但**一定要显示**：
                        //   用户设的是 Open Router，结果其实是本机 Ollama
                        //   硬跑出来的 —— 不说就等于把配置状态瞒着用户。
                        if !notices.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(notices, id: \.self) { note in
                                    Label(note, systemImage: "info.circle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.12))
                        }
                        MarkdownView(markdown: result)
                    }
                case .failed(let msg):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(msg)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button(L10n.Common.tryAgain) { summarizeState = .picking }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // ★ 十二改：这颗按钮**不再取消任务**了。
                    //
                    // 用户的原话就是要"可以先退出后台等完成后在进行查看" ——
                    // 那么"离开这一页"和"不要这条活了"就必须分成两件事。
                    // 前者是这颗按钮（以及手势下滑）；后者挪到后台任务页
                    // （`TaskCenterView`），那里才是"管任务"的地方。
                    //
                    // 混在一起的代价很具体：上一版的按钮叫"取消"，用户想走又怕
                    // 点了就停，只能干等在那看菊花 —— 而这个功能存在的理由就是
                    // 不让他干等。
                    Button(closeLabel) { dismiss() }
                }
                if case .done = summarizeState {
                    ToolbarItem(placement: .confirmationAction) {
                        // 产物在 runner 里就已经落盘了（这是十二改的关键：活了
                        // 就得自己落地，否则"跑完回来看"没有东西可看），这里
                        // 只是"我看完了，收工"。
                        Button(L10n.Common.done) { dismiss() }
                    }
                }
            }
            .task {
                languages.fetchTargetLanguagesIfNeeded()
                if let saved = env.config.config.lastSummaryLang {
                    outputLangCode = saved
                }
            }
            .sheet(isPresented: $showLangPicker) {
                LanguagePickerSheet(
                    title: L10n.Summarize.outputLanguage,
                    languages: languages.targetLanguages,
                    defaultOption: L10n.Summarize.sameAsTranscript
                ) { lang in
                    showLangPicker = false
                    outputLangCode = lang.code
                    env.config.config.lastSummaryLang = lang.code
                    env.config.scheduleSave()
                }
            }
        }
        // ★ 十二改：原来这里挂的是 `.interactiveDismissDisabled(dismissGuard)`
        //   —— 跑着的时候禁止手势下滑关掉（否则滑一下就取消了，w6estkf）、
        //   生成完但没保存时也禁止（否则滑走就悄悄丢了，g17h5nk）。
        //
        // 那两条理由**在这个模型下都不成立了**：
        //   · 跑着的时候滑走，活照样跑（它就是排在那条落盘队列里的）；
        //   · 生成完的产物已经在磁盘上，不存在"没保存"这个状态。
        // 所以封锁整个删掉，改成盯着队列看这条活走到哪一步了。
        .onChange(of: jobs.jobs) { _ in observeJob() }
        .onAppear { observeJob() }
    }

    /// 关闭按钮上写什么。
    ///
    /// 选模板那一页用"取消"（此时确实什么都没发生）；已经开跑之后用"关闭"
    /// —— 那时候"取消"是个谎话，点了活并不会停。
    private var closeLabel: String {
        if case .running = summarizeState { return L10n.Common.close }
        return L10n.Common.cancel
    }

    private var navTitle: String {
        switch summarizeState {
        case .picking: return L10n.Summarize.chooseTemplate
        case .running: return L10n.Summarize.summarizing
        case .done: return L10n.ClipDetail.summary
        case .failed: return L10n.Summarize.error
        }
    }

    // MARK: - Template picker

    private var currentLangName: String {
        if outputLangCode.isEmpty { return L10n.Summarize.sameAsTranscript }
        return languages.targetLanguages.first { $0.code == outputLangCode }?.name ?? outputLangCode
    }

    private var templatePicker: some View {
        Group {
            if let previewing {
                TemplateOverviewView(
                    template: previewing,
                    onUse: { use(previewing) },
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.18)) { self.previewing = nil }
                    }
                )
            } else {
                VStack(spacing: 0) {
                    // ★ 开工前的体检。**只在这一页显示**，因为它只在"选模板"这一刻
                    //   才有用武之地：现在告诉用户"主通道没配 Key、会用 Ollama 兜底"，
                    //   他就能决定是先去补 Key、还是就这么跑。
                    //   以前这种情况只在**跑完之后**炸一句英文错误出来。
                    if let preflightWarning {
                        // ★ 2026-10-15：体检不止"说一句"，还得给**一键修复**。
                        //
                        // 实测到的真实情况就是"主通道指着 Open Router、而那段没有
                        // api_key"。光提示的话，用户要自己摸到「设置 → LLM 服务商」、
                        // 翻到 Open Router、找到主通道选择器 —— 而正确答案只有一个。
                        VStack(alignment: .leading, spacing: 6) {
                            Label(preflightWarning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            if let fix = LLMCompletionService.suggestedPrimary(env.config.config) {
                                Button {
                                    adoptFallbackAsPrimary(fix)
                                } label: {
                                    Text(L10n.LLM.adoptAsPrimary(
                                        LLMCompletionService.providerLabel(fix)
                                    ))
                                    .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.12))
                    }
                    languageBar
                    templateGrid
                }
            }
        }
        .onAppear { refreshPreflight() }
    }

    /// 开跑。**只在概览页里**调用 —— 块本身只负责"进概览"。
    ///
    /// 同一帧里把 `previewing` 清掉：这样万一这次跑失败了、用户点"重试"回到
    /// 选择页，看到的是网格而不是**上一轮那个模板的概览**。
    ///
    /// ★ 2026-10-16 十二改：这里不再自己 `Task { await runSummarize }`，而是把
    ///   活交给 `JobQueue`。区别不在"多绕一层"，而在**谁持有它**：内存里的
    ///   `Task` 在 App 被系统结束时就一起没了，落盘的活第二天还在队列里等着
    ///   被 `resume()` 捞起来。
    ///
    /// ⚠️ prompt 在**入队这一刻**就定稿（`withLanguageInstruction` 拼完再存），
    ///    不是跑的时候现算。理由见 `Job.prompt`：这条活可能在几天后才被捞起来
    ///    跑，那时模板可能已经被改过或删了。活的内容要定格在用户按下按钮的
    ///    那一刻 —— 包括他当时选的那个输出语言。
    private func use(_ template: SummarizeTemplate) {
        selected = template
        previewing = nil
        // 上一轮的结果必须清掉：失败之后回到选择页再点一次时，不清的话会先
        // 闪一下旧摘要，看起来像"新的一次没生效"。
        result = ""
        wasTruncated = false
        notices = []
        chunkProgress = nil

        // 空转录挡在入队之前。放进队列的话会白跑一轮（runner 读不到源文件，
        // 抛 `JobSourceMissing`，队列再把它抹掉）—— 结果一样，但中间那几秒
        // 界面在转圈，用户会以为有希望。
        guard !transcriptText.isEmpty else {
            summarizeState = .failed(L10n.Jobs.sourceMissing(L10n.Jobs.sourceTranscript))
            return
        }

        let job = Job.summarize(
            clip: audioName,
            prompt: withLanguageInstruction(template.localizedPrompt),
            templateName: template.name
        )
        jobID = job.id
        summarizeState = .running
        jobs.enqueue(job)
    }

    // MARK: - 观察队列

    private var isWaitingOnJob: Bool {
        if case .running = summarizeState { return true }
        return false
    }

    /// 队列一有变化就来看一眼这条活走到哪了。
    ///
    /// ⚠️ 用 `.onChange(of: jobs.jobs)` 而不是让 runner 回调这个视图：活
    ///    很可能在这一页**根本不存在**的时候跑完（用户早就把它划走了）——
    ///    那种情况回调没地方去。只从台账读状态，两种情形就都盖住了。
    private func observeJob() {
        guard isWaitingOnJob, let jobID else { return }
        guard let job = jobs.job(id: jobID) else {
            // 台账里已经没有这条了。只有一种情况会这样：源头不在（转录被清掉 /
            // 录音被删），队列判定它永远不会成功，直接抹掉、不白试三次。
            summarizeState = .failed(L10n.Jobs.sourceMissing(L10n.Jobs.sourceTranscript))
            return
        }
        if let done = job.progressDone, let total = job.progressTotal {
            chunkProgress = (done, total)
        } else {
            chunkProgress = nil
        }
        switch jobs.state(of: job) {
        case .waiting, .running:
            break
        case .done:
            adoptResult(of: job)
        case .gaveUp:
            chunkProgress = nil
            summarizeState = .failed(job.lastError ?? L10n.Summarize.error)
        }
    }

    /// 活出队了、而且是成功的那种 —— 从**磁盘**把结果读回来。
    ///
    /// 从磁盘读而不是把文本塞进活里：产物就是那份文件（`{base}.summary.md`），
    /// 详情页、全文页、思维导图读的都是它。多留一份内存副本只会多一个会不同步
    /// 的真相。
    private func adoptResult(of job: Job) {
        let url = StorageLocations.summaryURL(for: audioName)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            // 文件不在，台账却记着"成功"。只有一种可能：用户刚刚在后台任务页
            // 把这条取消了 —— 取消也是一种"出队"，在台账里与成功长得一模一样
            // （`lastError == nil`，见 `JobQueue.cancel(id:)`）。他已经不要它了，
            // 这一页安静收掉就好，不要弹一句他看不懂的报错。
            dismiss()
            return
        }
        result = text
        wasTruncated = job.wasTruncated == true
        notices = job.notes ?? []
        chunkProgress = nil
        summarizeState = .done
        // ★ 立刻告诉详情页，不等用户点那个"完成"。
        //
        // 产物已经落在磁盘上了，用户点不点它都在；详情页没理由还显示旧的
        // （或者干脆还显示"生成摘要"按钮）。
        onComplete(text)
    }

    /// 把兜底通道扶正成主通道。改完立刻重跑体检 —— 警示条要当场消失，
    /// 否则用户会以为按钮没生效。
    private func adoptFallbackAsPrimary(_ key: String) {
        env.config.config.llmProviders.primary = key
        env.config.scheduleSave()
        refreshPreflight()
    }

    /// 主通道不可用时的开工提示。有兜底通道 ⇒ 说"会用谁兜底"；
    /// 一个都不剩 ⇒ 说"跑不了"，别让用户点了再看报错。
    private func refreshPreflight() {
        let config = env.config.config
        guard let gap = LLMCompletionService.primaryGapWithFallback(config) else {
            preflightWarning = LLMCompletionService.candidateChain(config).isEmpty
                ? L10n.LLM.errorNoProvider
                : nil
            return
        }
        preflightWarning = gap.fallback.map {
            L10n.Summarize.preflightFallback(gap.gap, $0)
        } ?? gap.gap
    }

    private var languageBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(L10n.Summarize.outputLanguage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button { showLangPicker = true } label: {
                HStack(spacing: 4) {
                    Text(currentLangName)
                        .font(.subheadline)
                        .foregroundStyle(outputLangCode.isEmpty ? Color.secondary : Color.accentColor)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    // MARK: - 模板网格（★ 2026-10-15 七改）
    //
    // 以前是 `List { Section { 一行 = 图标 + 名字 + 80 字提示词预览 } }`：
    // 一屏只放得下三四个，而且**名字被大段文字淹没** —— 找模板变成了逐行阅读。
    // 现在按分类摊成块：先扫分类标题、再扫块上的名字，一屏能看到六到八个；
    // 想细看某个模板"到底会产出什么"，点进去就是概览页。
    private var templateGrid: some View {
        Group {
            if filtered.isEmpty {
                // 搜不到就说一声。网格搜空后整页是白的，用户会以为页坏了。
                EmptyStateView(
                    L10n.Summarize.noMatchingTemplates,
                    systemImage: "magnifyingglass",
                    message: L10n.Summarize.searchTemplates
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(filteredCategories, id: \.self) { category in
                            VStack(alignment: .leading, spacing: 10) {
                                categoryHeader(category)
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 148), spacing: 10)],
                                    spacing: 10
                                ) {
                                    ForEach(templatesIn(category)) { template in
                                        templateCard(template)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
        }
        // 挂在 Group 外面：这样"有结果"和"没结果"两种形态下搜索栏都在，
        // 用户才能把刚才打错的词删掉。挂在里面就得写两遍（Group 会把
        // modifier 派发给唯一的内容视图）。
        .searchable(text: $search, prompt: L10n.Summarize.searchTemplates)
    }

    private func templatesIn(_ category: String) -> [SummarizeTemplate] {
        filtered.filter { $0.category == category }
    }

    private func categoryHeader(_ category: String) -> some View {
        HStack(spacing: 6) {
            Text(SummarizeTemplate.localizedCategoryName(category))
                .font(.subheadline.weight(.semibold))
            Text(L10n.Summarize.templateCount(templatesIn(category).count))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    /// 一个模板块。**只放名字** —— 说明与提示词都在概览页，这里求的是"扫得过来"。
    private func templateCard(_ template: SummarizeTemplate) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { previewing = template }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: template.isBuiltIn ? "doc.text" : "pencil.and.outline")
                        .font(.caption)
                        .foregroundStyle(template.isBuiltIn ? Color.secondary : Color.accentColor)
                    Spacer(minLength: 0)
                    if !template.isBuiltIn {
                        Text(L10n.Summarize.customBadge)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(template.localizedName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            // `maxHeight: .infinity` 是为了**同一行里的块等高** —— 名字一行和
            // 名字三行的块并排时，参差不齐的底边非常显眼。
            .frame(maxWidth: .infinity, minHeight: 88, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Summarize

    /// Returns the chosen output language's English name (e.g. "Spanish
    /// (Spain)") when the user picked a non-default language, otherwise
    /// nil. The English name beats the BCP-47 code as a prompt hint —
    /// most LLMs respond better to "Spanish" than "es-ES".
    private var outputLangName: String? {
        guard !outputLangCode.isEmpty else { return nil }
        return languages.targetLanguages.first { $0.code == outputLangCode }?.name ?? outputLangCode
    }

    /// ★ 唯一还留在这个文件里的"干活"逻辑，而且它只做一件事：把输出语言指令
    ///   拼到模板提示词前面。
    ///
    /// 之所以留在视图里而不是搬进 `JobRunners`：它依赖 `outputLangName`，而
    /// 那是**用户此刻在这一页选的语言**（`languages.targetLanguages` 还没加载完
    /// 时还会退回语言代码）。拼好的成品由 `use(_:)` 存进 `Job.prompt` ——
    /// 也就是说它只在**入队的那一刻**执行一次，之后与这一页再没关系。
    private func withLanguageInstruction(_ prompt: String) -> String {
        if let name = outputLangName {
            return "Write your ENTIRE response in \(name) — including all section headers, labels, and body text.\n\n" + prompt
        }
        // "Same as transcript" — the template body is in English, so the
        // language directive must come FIRST and be emphatic, otherwise
        // the model follows the English context and ignores a trailing
        // "reply in the same language" hint.
        return "IMPORTANT: Detect the language of the user's content and write your ENTIRE response in that same language — including all section headers, labels, and body text. Only use English if the user's content is in English.\n\n" + prompt
    }

    /// 跑的时候报的"正在用谁生成"。
    ///
    /// ⚠️ 这里只能报**入口**（主通道），不是真正干活的那个 ——
    /// `completeResilient` 内部逐个通道试，试到哪个成功要等它返回才知道。
    /// 真正干活的是谁由 `JobRunners.notices(for:config:)` 那句"已回退到 X"
    /// 说清楚，那才是准确的。上一版用 `workingProvider` 记过一次，但那要到
    /// 第一轮**跑完之后**才有值，跑的过程中显示的其实也是主通道。
    private var activeProviderLabel: String {
        let key = env.config.config.llmProviders.primary ?? ""
        return LLMCompletionService.providerLabel(key)
    }
}

// MARK: - 模板概览页（★ 2026-10-15 七改新建）
//
// 用户点块之后要的**不是**立刻开跑，而是"先看清楚这个模板会产出什么口径的
// 东西"：名字、分类、一句话说明、以及**提示词全文**。
//
// 刻意**不**把 prompt 预览塞回块里：块上那份字只要一挤，网格立刻变回原来那张
// 读不完的清单 —— 概览页存在的意义就是把"扫"和"读"分开。
//
// 说明那一行 `localizedSummary` 是可选的老字段（早期内置模板没有）。没有就整段
// 不显示，而不是拿 prompt 前 80 字硬凑：概览页下面就是 prompt 全文，凑一份
// "预览"纯属重复。
private struct TemplateOverviewView: View {
    let template: SummarizeTemplate
    let onUse: () -> Void
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let summary = template.localizedSummary, !summary.isEmpty {
                    labelledBlock(L10n.Summarize.templateAbout, text: summary, monospaced: false)
                }
                labelledBlock(
                    L10n.Summarize.templatePromptLabel,
                    text: template.localizedPrompt,
                    monospaced: true
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) { useBar }
        .navigationTitle(template.localizedName.isEmpty
                         ? L10n.Summarize.templateOverviewTitle
                         : template.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 这一页不是 push 进来的（见 `previewing` 那段注释），系统不会
            // 自己给返回箭头 —— 得自己摆一个，否则用户只能靠下滑关闭整个
            // 选择页，看着像"退出了"。
            ToolbarItem(placement: .navigationBarLeading) {
                Button { onBack() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.footnote.weight(.semibold))
                        Text(L10n.Summarize.backToTemplates)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: template.isBuiltIn ? "doc.text" : "pencil.and.outline")
                .font(.title3)
                .foregroundStyle(template.isBuiltIn ? Color.secondary : Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
            VStack(alignment: .leading, spacing: 6) {
                Text(template.localizedName)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    chip(
                        SummarizeTemplate.localizedCategoryName(template.category),
                        tint: .secondary
                    )
                    chip(
                        template.isBuiltIn ? L10n.Summarize.builtInBadge : L10n.Summarize.customBadge,
                        tint: template.isBuiltIn ? .secondary : .accentColor
                    )
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .foregroundStyle(tint)
    }

    /// 一段带小标题的正文块。`monospaced` 给 prompt 用 —— 里面有缩进和
    /// 表格线，等宽字才看得出结构。
    private func labelledBlock(_ label: String, text: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundStyle(.primary)
                // 允许长按选中复制：用户想把这个 prompt 拿去别处改一改是很自然的。
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
        }
    }

    private var useBar: some View {
        Button { onUse() } label: {
            Label(L10n.Summarize.useTemplate, systemImage: "sparkles")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
