import SwiftUI

struct ClipDetailView: View {
    let item: LibraryItem
    var onChanged: () -> Void = {}

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var transcription: TranscriptionService
    /// 摘要 / 翻译 / 格式转换的落盘队列。
    ///
    /// ⚠️ 必须**单独注入**、而不是走 `env.jobs` 取：嵌套 `ObservableObject` 的
    ///    `@Published` 变化不会让只观察父对象的视图失效（同 `NomilyApp` 里
    ///    `watch` 那段注释）。走 `env.jobs` 的话，活跑完了这一页不会更新 ——
    ///    那正是这次改动最不能出的问题。
    @EnvironmentObject private var jobs: JobQueue
    @EnvironmentObject private var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AudioPlaybackController()
    @StateObject private var languages = LanguageService()
    @State private var transcript: TranscriptDocument?
    @State private var deleteAudioAlert = false
    @State private var deleteTranscriptAlert = false
    @State private var deleteSummaryAlert = false
    @State private var summary: String?
    @State private var showSummarize = false
    @State private var showNoProvider = false
    @State private var showNoASR = false
    @State private var showPlayer = false
    @State private var retranscribeAlert = false
    @State private var translation: String?
    @State private var translatedSummary: String?
    @State private var showLocalesPicker = false
    @State private var lastLocalesPicked: [String] = []
    @State private var showTranscribeChoice = false
    @State private var showRetranscribeChoice = false
    @State private var showTranslatePicker = false
    @State private var translateTarget: TranslateTarget = .transcript
    // ★ 2026-10-16 十二改：`translatingTranscript` / `translatingSummary` /
    // `isExporting` 三个 `@State` 忙碌标记**全部删掉了**，改成从 `jobs`
    // 算出来（见下面 `activeJob(_:target:)` 那一段）。
    //
    // 理由与这次改动的动机是同一条：内存里的标记在 App 被系统结束之后什么都
    // 不剩，而活还在磁盘上排着。那种时候界面会显示"没在跑"，比显示不出来更糟
    // —— 用户会以为任务丢了、又点一次，于是排成两条。
    //
    // `translateError` / `exportError` 那两个 `@State` 加两个 alert 也一并删了：
    // 活现在可能在**用户看不见的时候**失败，alert 那种"当场弹一下"的形式根本
    // 覆盖不到；改成在各自的 section 里就地显示（`failedRow`），看得见、可重试。
    @State private var exportShareURL: URL?
    /// 用户按下导出之后如果**没离开这一页**，导完把分享面板直接推出来（与十二
    /// 改之前的行为一致）。离开了就靠 `exportReady` 那一行 —— 它本来就存在。
    /// 这个标记随视图一起消失，正合语义。
    @State private var pendingExportShare = false
    @State private var showVADPreview = false
    @State private var showMindMap = false
    @State private var showExportChoice = false

    private enum TranslateTarget { case transcript, summary }

    var body: some View {
        Form {
            if item.hasAudio { heroCard }
            transcriptSection
            if translation != nil { translationSection }
            summarySection
            if translatedSummary != nil { translatedSummarySection }
            if item.hasAudio { exportSection }
            destructiveSection
        }
        .padding(.top, -20)
        .navigationTitle(item.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        // ★ 2026-10-15：详情页一出现就算"打开过了"，列表上那颗红点随之消失。
        //
        // 挂在这里而不是列表的点击回调里：详情页有好几个入口（资料库、
        // 录音列表、实时页跳过来），挂在点击回调上就只能覆盖到其中一个 ——
        // 用户从别处点开会发现红点还在，像是没生效。这里只有一处，也永远
        // 不会因为新增入口而漏。
        .onAppear { ClipReadStore.shared.markSeen(name: item.name) }
        .toolbar {
            if configService.config.isDeveloperMode {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showVADPreview = true
                    } label: {
                        Image(systemName: "waveform.and.magnifyingglass")
                    }
                    .accessibilityLabel("Preview VAD")
                }
            }
        }
        .sheet(isPresented: $showVADPreview) {
            VADPreviewView(item: item)
        }
        .fullScreenCover(isPresented: $showMindMap) {
            // Re-read from state rather than capture: the summary can be
            // regenerated while the sheet is closed.
            MindMapScreen(markdown: summary ?? "", fallbackTitle: item.displayTitle)
        }
        .task {
            if let url = item.url { player.load(url) }
            languages.fetchTargetLanguagesIfNeeded()
            transcript = TranscriptDocument.load(for: item.name)
            loadTranslation()
            loadSummary()
            loadTranslatedSummary()
        }
        .onDisappear { player.stop() }
        .onChange(of: transcription.inFlight.contains(item.name)) { isRunning in
            // Auto-transcribe landing: the service flips `inFlight` off as
            // soon as the write completes, so this is where the newly-
            // produced `{name}.txt` + `.asr.json` become readable. Manual
            // runTranscribe also benefits — it no longer has to reload
            // the doc itself.
            if !isRunning { transcript = TranscriptDocument.load(for: item.name) }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerSheet(player: player, title: item.displayTitle, totalDuration: item.duration)
        }
        .sheet(isPresented: $showSummarize) {
            if let doc = transcript {
                SummarizeSheet(
                    transcriptText: Self.textForSummarization(doc),
                    audioName: item.name
                ) { text in
                    summary = text
                }
            }
        }
        .alert(L10n.LLM.noProvider, isPresented: $showNoProvider) {
            Button(L10n.Common.openSettings) {
                dismiss()
                env.navigateToLLMProviders = true
                NotificationCenter.default.post(name: .navigateToSettings, object: nil)
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.LLM.noProviderMessage)
        }
        .alert(L10n.ClipDetail.retranscribe, isPresented: $retranscribeAlert) {
            Button(L10n.ClipDetail.retranscribe, role: .destructive) {
                showRetranscribeChoice = true
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.ClipDetail.retranscribeMessage)
        }
        .sheet(isPresented: $showLocalesPicker) {
            AzureLocalesPickerSheet(initial: lastLocalesPicked) { codes in
                lastLocalesPicked = codes
                runTranscribe(locales: codes)
            }
        }
        .confirmationDialog(L10n.ClipDetail.transcribe, isPresented: $showTranscribeChoice, titleVisibility: .hidden) {
            Button(L10n.ASR.transcribeAuto) { triggerTranscribe(locales: nil) }
            Button(L10n.ASR.specifyLanguages) { showLocalesPicker = true }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
        .confirmationDialog(L10n.ClipDetail.exportAudio, isPresented: $showExportChoice, titleVisibility: .visible) {
            Button(L10n.ClipDetail.exportAsM4A) { enqueueExport(.m4a) }
            Button(L10n.ClipDetail.exportAsWAV) { enqueueExport(.wav) }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
        .confirmationDialog(L10n.ClipDetail.retranscribe, isPresented: $showRetranscribeChoice, titleVisibility: .hidden) {
            Button(L10n.ASR.transcribeAuto) { runTranscribe(locales: nil) }
            Button(L10n.ASR.specifyLanguages) { showLocalesPicker = true }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
        .alert(L10n.ASR.noProvider, isPresented: $showNoASR) {
            Button(L10n.Common.openSettings) {
                dismiss()
                env.navigateToASRProviders = true
                NotificationCenter.default.post(name: .navigateToSettings, object: nil)
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.ASR.noProviderMessage)
        }
        .alert(L10n.ClipDetail.deleteAudio, isPresented: $deleteAudioAlert) {
            Button(L10n.Common.delete, role: .destructive, action: deleteAudio)
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.ClipDetail.deleteAudioMessage)
        }
        .alert(L10n.ClipDetail.deleteTranscript, isPresented: $deleteTranscriptAlert) {
            Button(L10n.Common.delete, role: .destructive, action: deleteTranscript)
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.ClipDetail.deleteTranscriptMessage)
        }
        .alert(L10n.ClipDetail.deleteSummary, isPresented: $deleteSummaryAlert) {
            Button(L10n.Common.delete, role: .destructive, action: deleteSummary)
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.ClipDetail.deleteSummaryMessage)
        }
        .sheet(isPresented: $showTranslatePicker) {
            LanguagePickerSheet(
                title: L10n.ClipDetail.translate,
                languages: languages.targetLanguages,
                defaultOption: nil
            ) { lang in
                showTranslatePicker = false
                guard !lang.code.isEmpty else { return }
                env.config.config.lastTargetLang = lang.code
                env.config.scheduleSave()
                enqueueTranslate(target: translateTarget, languageName: lang.name)
            }
        }
        // ★ 十二改：这两个 alert（翻译失败 / 导出失败）删掉了。
        //
        // 活现在可能在**用户看不见的时候**失败，而 alert 只在"当场那一下"能弹；
        // 更要命的是它还会**重复弹** —— 台账里那条 `lastError` 会一直留着，
        // 每次界面刷新都能再触发一遍。改成在各自的 section 里就地显示
        // （`failedRow`）：看得见、可重试、不会自己冒出来。
        .sheet(
            isPresented: Binding(
                get: { exportShareURL != nil },
                set: { if !$0 { exportShareURL = nil } }
            ),
            onDismiss: { exportShareURL = nil }
        ) {
            if let url = exportShareURL {
                ShareSheet(items: [url])
            }
        }
        // 队列一有变化就跟上：这条录音上的活跑完了 / 放弃了，摘要、译文、
        // 分享入口都得跟着变。
        .onChange(of: jobs.jobs) { _ in jobsChanged() }
    }

    // MARK: - hero card

    private var heroCard: some View {
        Section {
            Button { showPlayer = true } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 48, height: 48)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if let dur = item.durationLabel {
                                Text(dur)
                                    .font(.callout.weight(.medium).monospacedDigit())
                                    .fixedSize()
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        // ★ 2026-10-16 十三改：`.formatted(date:time:)` **不读**
                        //   SwiftUI 环境里的 locale —— 它取 `Locale.current`，
                        //   而这句话在 `Text` 看到它之前就已经算成字符串了
                        //   （只有 `Text(date, format:)` 才会去读环境）。
                        //   所以这里显式走 `AppLocale`，跟 App 语言走。
                        //
                        // ⚠️ 原来的 `.abbreviated` / `.shortened` 是
                        //   `Date.FormatStyle` 的符号，不是 `DateFormatter.Style`
                        //   的 —— 后者的取值只有 none/short/medium/long/full。
                        //   等价换算：`.abbreviated → .medium`、`.shortened → .short`。
                        Text(AppLocale.string(from: item.recordedAt,
                                              dateStyle: .medium,
                                              timeStyle: .short))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                        Text(item.name)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 4)
                // `.buttonStyle(.plain)` only takes hits on drawn pixels, so
                // the gaps between the icon and the labels were dead — the
                // card looked tappable everywhere but only responded on the
                // artwork and text.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - transcript

    private var isTranscribing: Bool {
        transcription.inFlight.contains(item.name)
    }

    /// 这条录音在转录队列里、且已经试满放弃的那一条。
    ///
    /// 判据与设置页那行 `asr.queue_stuck` 完全一致（`attempts >= maxAttempts`），
    /// 故意不另立标准 —— 同一个事实在两个地方说法不同，用户就不知道该信哪个。
    private var stuckTranscription: TranscriptionService.PendingJob? {
        transcription.pending.first {
            $0.name == item.name && $0.attempts >= TranscriptionService.maxAttempts
        }
    }

    @ViewBuilder
    private var transcriptSection: some View {
        Section {
            if isTranscribing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.ClipDetail.transcribing)
                    Spacer()
                    Button(L10n.Common.cancel) {
                        transcription.cancel(name: item.name)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if let stuck = stuckTranscription {
                // 转录试满三次、放弃了。
                //
                // 以前这种状态只在设置页那一行里能看到（`asr.queue_stuck_detail`），
                // 而用户是在**这条录音**上按的按钮 —— 他只会觉得"点了没反应"。
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.Jobs.statusGaveUp, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    if let reason = stuck.lastError {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // 重试就是再入一次队 —— `enqueue` 会把尝试计数清零，
                    // 与 `JobQueue.retry(id:)` 是同一个语义。
                    Button(L10n.Jobs.retry) { runTranscribe(locales: stuck.locales) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            // 转录翻译：跑着 / 放弃了都在这里就地显示。
            //
            // 以前这一行挂在内存里的 `translatingTranscript` 上，切走再回来它
            // 就没了 —— 用户看不出这条活还在不在，多半会再点一次翻译。
            if let job = activeJob(.translate, target: "transcript") {
                runningRow(job, L10n.ClipDetail.translating)
            } else if let job = failedJob(.translate, target: "transcript") {
                failedRow(job)
            }
            if let job = lastFinishedJob(.translate, target: "transcript") { notesRow(job) }

            if let doc = transcript {
                Text(transcriptPreview(doc))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                NavigationLink(L10n.ClipDetail.viewFullTranscript) {
                    TranscriptFullView(document: doc)
                }
            } else if item.hasAudio, !isTranscribing {
                Button {
                    if env.config.config.asrProviders.hasConfiguredProvider {
                        showTranscribeChoice = true
                    } else {
                        showNoASR = true
                    }
                } label: {
                    Label(L10n.ClipDetail.transcribe, systemImage: "text.bubble")
                }
            }

            // Provider-fallback is silent on success: if the fallback chain
            // ultimately produced a transcript, the user doesn't need a
            // degrade warning (6tddu, pwtlfr). Failures still surface via the
            // transcribe error state.
        } header: {
            HStack {
                Text(L10n.ClipDetail.transcript)
                Spacer()
                if transcript != nil, !isTranscribing {
                    Button { tapTranslate(.transcript) } label: {
                        Image(systemName: "character.bubble")
                            .font(.caption)
                    }
                    .disabled(translatingTranscript)
                    if item.hasAudio {
                        Button { retranscribeAlert = true } label: {
                            Image(systemName: "arrow.trianglehead.2.counterclockwise")
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func triggerTranscribe(locales: [String]?) {
        if env.config.config.asrProviders.hasConfiguredProvider {
            runTranscribe(locales: locales)
        } else {
            showNoASR = true
        }
    }

    /// 转发到 `JobRunners.summarizableText` —— **只留一份实现**。
    ///
    /// 十二改之后摘要有了第二条入口（`JobQueue` 的 runner，它从磁盘读转录），
    /// 那一条必须喂进去一模一样的文本。两处各写一遍，迟早会漂开，而表现是
    /// "同一个模板，隔一天跑出来的摘要结构不一样" —— 那种问题没人查得动。
    private static func textForSummarization(_ doc: TranscriptDocument) -> String {
        JobRunners.summarizableText(text: doc.text, segments: doc.segments)
    }

    private func transcriptPreview(_ doc: TranscriptDocument) -> String {
        if doc.segments.isEmpty { return String(doc.text.prefix(200)) }
        return String(doc.segments.map(\.text).joined(separator: " ").prefix(200))
    }

    /// 发起转录。
    ///
    /// ★ 2026-10-16 十二改：改走 `enqueue` 而**不是** `transcribe`。
    ///
    /// 差别只在"App 中途被杀"那一种情况下看得出来：直接跑的那条活在进程没了
    /// 的时候就凭空消失，用户第二天回来只看到一条没转录的录音，也不会知道曾经
    /// 试过。`enqueue` 先落盘再开跑，`resumePending()` 下次启动会把它捞回来 ——
    /// 这正是用户那句"可以先退出后台等完成后再进行查看"要的东西。
    ///
    /// 不再是 `async`：入队本身是同步的，真正的等待由 `transcription.inFlight`
    /// / `pending` 驱动界面（见 `isTranscribing` 与 `stuckTranscription`）。
    /// 硬留着 `async` 会让每个调用点报 "no 'async' operations occur within
    /// 'await' expression"，而本工程是零告警的。
    private func runTranscribe(locales: [String]? = nil) {
        guard let fileURL = item.url else { return }
        env.transcription.enqueue(fileURL: fileURL, locales: locales)
    }

    // MARK: - 任务队列联动（★ 2026-10-16 十二改）

    /// 这条录音上、这一类活里正在跑的那条（界面拿它决定按钮的忙碌态）。
    private func activeJob(_ kind: JobKind, target: String? = nil) -> Job? {
        jobs.activeJobs(for: item.name).first { job in
            job.kind == kind && (target == nil || job.translateTarget == target)
        }
    }

    /// 这条录音上、这一类活里**试满放弃**的那条。
    ///
    /// "有 `finishedAt` 且有 `lastError`" 就是放弃 —— 成功那条 `lastError` 是
    /// nil，取消那条也是 nil，三个状态靠这两个字段就能分开（见 `JobQueue.State`）。
    /// 用户一旦重新发起（`enqueue` 会清 `lastError`）或点重试，这一行自动消失。
    private func failedJob(_ kind: JobKind, target: String? = nil) -> Job? {
        jobs.jobs.first { job in
            job.clipName == item.name && job.kind == kind
                && job.finishedAt != nil && job.lastError != nil
                && (target == nil || job.translateTarget == target)
        }
    }

    /// 某类活**最近一次成功跑完**的那条（用来显示结果附注）。
    ///
    /// 只认"成功"（`finishedAt` 有值且 `lastError` 为 nil）：失败的原因已经在
    /// `failedRow` 里说过一次了，在这里再说一遍只会让人以为是两个问题。
    /// 取"最近一次"而不是任意一条：同一条录音可以先后翻成好几种语言，附注
    /// （比如"被截断"）必须对应**用户现在看到的那份内容**。
    private func lastFinishedJob(_ kind: JobKind, target: String? = nil) -> Job? {
        jobs.jobs
            .filter {
                $0.clipName == item.name && $0.kind == kind
                    && $0.finishedAt != nil && $0.lastError == nil
                    && (target == nil || $0.translateTarget == target)
            }
            .max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
    }

    /// 结果附注那一小块（兜底通道 / 走了分段 / 正文被截断）。
    ///
    /// 没有内容时它什么都不画。**为什么非要有它**：附注是"结果的一部分"，
    /// 而这条活多半是在用户看不见的时候跑完的 —— 不留在这里，"我明明设的是
    /// Open Router，怎么是 Ollama 生成的"就永远没人回答；而一份被截断的
    /// 正文读起来和完整的完全一样。
    @ViewBuilder
    private func notesRow(_ job: Job) -> some View {
        if job.wasTruncated == true {
            Label(L10n.Summarize.truncatedWarning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        ForEach(job.notes ?? [], id: \.self) { note in
            Label(note, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 「正在跑」那一行。
    ///
    /// 用户在详情页发起、然后切走再回来时，这是他能看出"它还在跑"的唯一地方
    /// —— 以前这一行只在 `await` 还没返回时存在（内存标记），切走回来就没了。
    @ViewBuilder
    private func runningRow(_ job: Job, _ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .foregroundStyle(.secondary)
                if let done = job.progressDone, let total = job.progressTotal {
                    Text(L10n.Jobs.progress(done, total))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                } else if let detail = job.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 「试满放弃」那一行 + 就地重试。
    ///
    /// **必须显示**：用户切走再回来，如果只看到内容还是旧的，会以为它还在跑
    /// （或者以为按钮坏了），然后多半会再点一次 —— 结果又排一条。
    @ViewBuilder
    private func failedRow(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.Jobs.statusGaveUp, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
            if let error = job.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(L10n.Jobs.retry) { jobs.retry(id: job.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    /// 队列一有变化就跟上。
    ///
    /// ⚠️ 挂 `.onChange(of: jobs.jobs)` 而不是等 runner 回调视图：活很可能
    ///    是在这一页**根本不存在**的时候跑完的（那正是十二改要支持的场景）。
    ///    所以这里能做的只有一件事 —— 重新从**磁盘**读一遍产物。
    ///
    /// 代价是分段进度每跳一次也重读一次（几十次小文件读），换来的是一条不需要
    /// 任何额外状态同步的实现。值。
    private func jobsChanged() {
        loadSummary()
        loadTranslation()
        loadTranslatedSummary()

        // 导出完成 → 分享面板（与十二改之前"导完就弹"一致）。
        //
        // 只在用户按下导出后**没离开这一页**的时候弹：那个标记随视图一起消失，
        // 离开了就靠 `exportReady` 那一行 —— 它本来就在，不需要新加东西。
        if pendingExportShare, activeJob(.export) == nil, failedJob(.export) == nil,
           let staged = ExportCenter.shared.ready(forOrigin: item.name) {
            pendingExportShare = false
            exportShareURL = ExportCenter.shared.url(for: staged)
        }
    }

    // MARK: - translation (Live-produced or on-demand via tapTranslate(.transcript))

    /// 转录翻译正在跑。
    ///
    /// 从 `@State` 改成算出来 —— 见文件顶部那段注释。三个标记一套写法，这样
    /// "界面显示在跑、其实早就不在跑了"（App 被杀之后的状态）从结构上不可能发生。
    private var translatingTranscript: Bool { activeJob(.translate, target: "transcript") != nil }
    private var translatingSummary: Bool { activeJob(.translate, target: "summary") != nil }


    @ViewBuilder
    private var translationSection: some View {
        Section {
            Text(String(translation!.prefix(200)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            NavigationLink(L10n.ClipDetail.viewFullTranslation) {
                TranslationFullView(text: translation!)
            }
        } header: {
            Text(L10n.ClipDetail.translation)
        }
    }

    private func loadTranslation() {
        let url = StorageLocations.translationURLs(for: item.name).txt
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            translation = text
        }
    }

    // MARK: - translated summary

    @ViewBuilder
    private var translatedSummarySection: some View {
        Section {
            Text(String(translatedSummary!.prefix(200)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            NavigationLink(L10n.ClipDetail.viewFullTranslatedSummary) {
                SummaryFullView(text: translatedSummary!)
            }
        } header: {
            Text(L10n.ClipDetail.translatedSummary)
        }
    }

    private func loadTranslatedSummary() {
        let url = StorageLocations.summaryTranslatedURL(for: item.name)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            translatedSummary = text
        }
    }

    // MARK: - translate action

    private func tapTranslate(_ target: TranslateTarget) {
        let providers = env.config.config.llmProviders
        if providers.primary == nil || providers.primary!.isEmpty || providers.configuredProviders.isEmpty {
            showNoProvider = true
            return
        }
        translateTarget = target
        showTranslatePicker = true
    }

    /// 入队一份翻译。**不再自己 `await`** —— 见 `JobQueue` 顶部那段：
    /// 内存里的 `Task` 在 App 被系统结束时一起消失，落盘的活不会。
    ///
    /// 保活令牌（`BackgroundKeeper.acquire(.summary)`）也搬进了
    /// `JobRunners.translate` —— 谁干活谁占令牌，四个执行体一套写法。
    private func enqueueTranslate(target: TranslateTarget, languageName: String) {
        // `TranslateTarget` → 活里的 `translateTarget` 字符串。用 `String` 而不是
        // 把这个私有枚举搬到 `Job` 里：那个枚举是**界面**的（它决定点的是哪个
        // 按钮），而活需要的是"翻的是转录还是摘要"这个事实；两件事不必共用一个类型。
        let t = target == .summary ? "summary" : "transcript"
        jobs.enqueue(Job.translate(clip: item.name, target: t, languageName: languageName))
    }

    // MARK: - summary

    @ViewBuilder
    private var summarySection: some View {
        Section {
            // 摘要本身 + 摘要的翻译，两种活都产出"摘要区的内容"，摆在一起。
            //
            // ★ 这里最重要的一种情况：用户在**摘要 sheet 里点了模板、然后
            //   直接把它划掉了**（那正是十二改要支持的用法）。没有这两行的话，
            //   他回到详情页只看到"生成摘要"按钮还在，完全看不出活正在跑。
            if let job = activeJob(.summarize) {
                runningRow(job, L10n.Summarize.summarizing)
            } else if let job = failedJob(.summarize) {
                failedRow(job)
            }
            if let job = activeJob(.translate, target: "summary") {
                runningRow(job, L10n.ClipDetail.translating)
            } else if let job = failedJob(.translate, target: "summary") {
                failedRow(job)
            }
            if let summary {
                Text(String(summary.prefix(200)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                NavigationLink(L10n.ClipDetail.viewFullSummary) {
                    SummaryFullView(text: summary)
                }

                // Only offered when the summary actually has section
                // structure to plot — a flat block of prose has no map.
                if MarkdownOutline.parse(summary) != nil {
                    Button {
                        showMindMap = true
                    } label: {
                        Label(L10n.ClipDetail.mindMap, systemImage: "arrow.triangle.branch")
                    }
                }
            } else if transcript != nil {
                Button {
                    tapSummarize()
                } label: {
                    Label(L10n.ClipDetail.summarize, systemImage: "sparkles")
                }
            } else {
                Text(L10n.ClipDetail.transcribeFirst)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            // 结果附注（兜底通道 / 分段 / 被截断）。放在内容之后 —— 它描述的
            // 是上面那一份内容。
            if let job = lastFinishedJob(.summarize) { notesRow(job) }
            if let job = lastFinishedJob(.translate, target: "summary") { notesRow(job) }
        } header: {
            HStack {
                Text(L10n.ClipDetail.summary)
                Spacer()
                if summary != nil {
                    Button { tapTranslate(.summary) } label: {
                        Image(systemName: "character.bubble")
                            .font(.caption)
                    }
                    .disabled(translatingSummary)
                    if transcript != nil {
                        Button { tapSummarize() } label: {
                            Image(systemName: "arrow.trianglehead.2.counterclockwise")
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func tapSummarize() {
        let providers = env.config.config.llmProviders
        if providers.primary == nil || providers.primary!.isEmpty || providers.configuredProviders.isEmpty {
            showNoProvider = true
        } else {
            showSummarize = true
        }
    }

    private func loadSummary() {
        let url = StorageLocations.summaryURL(for: item.name)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            summary = text
        }
    }

    // MARK: - export

    @ViewBuilder
    private var exportSection: some View {
        Section {
            Button {
                showExportChoice = true
            } label: {
                HStack {
                    Label(L10n.ClipDetail.exportAudio, systemImage: "square.and.arrow.up.on.square")
                    Spacer()
                    if activeJob(.export) != nil {
                        ProgressView()
                    }
                }
            }
            .disabled(activeJob(.export) != nil)

            // 转换中 / 转换失败（试满三次）。都在这里就地显示 —— 用户切走再
            // 回来，这一行是他唯一能看出"转码还在跑"或者"它其实失败了"的地方。
            if let job = activeJob(.export) {
                runningRow(job, L10n.ClipDetail.exporting)
            } else if let job = failedJob(.export) {
                failedRow(job)
            }

            // ★ 2026-10-15 六改：**上次已经导好的那一份还在**就直接给分享入口。
            //
            // 这一行解决的是用户的原话"防止退出需要重新等待"：大文件转码要
            // 等很久，用户等不及切走了 —— 回来的时候如果只看到那个"导出音频"
            // 按钮，等于让他从头再等一遍。这里告诉他"东西已经好了，点这里发
            // 出去"，顺带给出体积（那是他决定要不要先清掉它的依据）。
            //
            // ⚠️ 只认 `origin == item.name`：批量导出备好的那份属于别的条目，
            //    在这条录音的详情页上给它一个分享入口会让人以为"分享的是这条"。
            if activeJob(.export) == nil, let staged = ExportCenter.shared.ready(forOrigin: item.name) {
                HStack(spacing: 8) {
                    Button {
                        // 复用上面那个由 `exportShareURL` 驱动的分享面板 ——
                        // 为这个入口再挂一个 `.sheet` 只会多一条需要同步的状态。
                        exportShareURL = ExportCenter.shared.url(for: staged)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L10n.ClipDetail.exportReady)
                                Text(Self.readyDetail(staged))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        ExportCenter.shared.discard()
                    } label: {
                        Label(L10n.ClipDetail.clearExportStaging, systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.ClipDetail.clearExportStaging)
                }
            }
        } header: {
            Text(L10n.ClipDetail.export)
        } footer: {
            Text(L10n.ClipDetail.exportFormatFooter)
        }
    }

    /// 「1 个文件 · 42 MB」。体积要给，那是用户判断"要不要先清掉它"的依据。
    private static func readyDetail(_ item: ExportCenter.Ready) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        return "\(L10n.ClipDetail.exportReadyFiles(item.itemCount)) · \(size)"
    }

    /// 入队一次格式转换。**不再自己 `await`**（理由同 `enqueueTranslate`）。
    ///
    /// `ExportCenter.publish` 也搬进了 `JobRunners.export` —— 产物落盘与台账
    /// 登记必须是同一段代码，否则"App 被杀"会留下"文件转了但台账里没有"。
    private func enqueueExport(_ format: AudioExportFormat) {
        pendingExportShare = true
        jobs.enqueue(Job.export(clip: item.name, format: format))
    }

    // MARK: - delete

    /// Audio, transcript and summary delete independently — nothing cascades.
    /// Each entry only appears when that artefact actually exists, so the
    /// section empties out as the user removes things.
    @ViewBuilder
    private var destructiveSection: some View {
        Section {
            if item.hasAudio {
                Button(role: .destructive) { deleteAudioAlert = true } label: {
                    Label(L10n.ClipDetail.deleteAudio, systemImage: "trash")
                }
            }
            if transcript != nil {
                Button(role: .destructive) { deleteTranscriptAlert = true } label: {
                    Label(L10n.ClipDetail.deleteTranscript, systemImage: "text.badge.xmark")
                }
            }
            if summary != nil {
                Button(role: .destructive) { deleteSummaryAlert = true } label: {
                    Label(L10n.ClipDetail.deleteSummary, systemImage: "doc.badge.ellipsis")
                }
            }
        } footer: {
            Text(L10n.ClipDetail.deleteIndependentFooter)
        }
    }

    /// Removes only the audio payload. The transcript / translation / summary
    /// / title stay on disk and the clip lives on as a text-only Library entry.
    ///
    /// ★ 2026-10-15：音频不再直接 `removeItem`，而是**搬进回收站**（保护 30 天）。
    /// 落盘名与路径一律不变，所以恢复回去之后扫描器看到的就是原来那一条。
    private func deleteAudio() {
        player.stop()
        var urls: [URL] = []
        if let url = item.url { urls.append(url) }
        // 音频是这条最后一块拼图时，`.title` 会立刻变成"孤儿标题" —— 扫描器
        // 照着它能重建出一条既没音频也没正文的幽灵条目。所以一起搬走。
        if let title = ClipTrash.titleSidecar(
            forLocalName: item.name,
            hasOtherArtefacts: item.hasTranscript || item.hasSummary
        ) {
            urls.append(title)
        }
        ClipTrash.shared.move(
            [ClipTrash.Payload(
                localName: item.name,
                title: item.displayTitle,
                urls: urls,
                // 音频这一份没了，所以"已从设备下过"的凭据要注销 —— 否则
                // 设备列表里它永远显示"已下载"，再也下不回来。恢复时补回去。
                download: ClipTrash.downloadRecord(forLocalName: item.name, in: env.library),
                // 来源在删除这一刻定死，见 `TrashedItem.source`。
                source: ClipTrash.sourceLabel(forLocalName: item.name, in: env.library)
            )],
            library: env.library
        )
        dismiss()
    }

    /// Removes the transcript and the translation derived from it. Audio and
    /// summary are untouched.
    private func deleteTranscript() {
        let t = StorageLocations.transcriptURLs(for: item.name)
        let tr = StorageLocations.translationURLs(for: item.name)
        var urls = [t.txt, t.json, tr.txt, tr.json]
        if let title = ClipTrash.titleSidecar(
            forLocalName: item.name,
            hasOtherArtefacts: item.hasAudio || item.hasSummary
        ) {
            urls.append(title)
        }
        ClipTrash.shared.move(
            [ClipTrash.Payload(
                localName: item.name,
                title: item.displayTitle,
                urls: urls,
                // ⚠️ 这里**不能**带 download：音频还在，注销了凭据就等于
                // 把一条仍然存在的素材从 manifest 里抹掉。
                download: nil,
                source: ClipTrash.sourceLabel(forLocalName: item.name, in: env.library)
            )],
            library: env.library
        )
        transcript = nil
        translation = nil
    }

    /// Removes the summary and its translation. Audio and transcript are
    /// untouched.
    private func deleteSummary() {
        var urls = [
            StorageLocations.summaryURL(for: item.name),
            StorageLocations.summaryTranslatedURL(for: item.name),
        ]
        if let title = ClipTrash.titleSidecar(
            forLocalName: item.name,
            hasOtherArtefacts: item.hasAudio || item.hasTranscript
        ) {
            urls.append(title)
        }
        ClipTrash.shared.move(
            [ClipTrash.Payload(
                localName: item.name,
                title: item.displayTitle,
                urls: urls,
                download: nil,    // 同上：音频没动，凭据留着。
                source: ClipTrash.sourceLabel(forLocalName: item.name, in: env.library)
            )],
            library: env.library
        )
        summary = nil
        translatedSummary = nil
    }
}

// MARK: - Player sheet

struct PlayerSheet: View {
    @ObservedObject var player: AudioPlaybackController
    let title: String
    /// Duration calculated by the database (Ogg page scanning). `AVAudioPlayer.duration` is the decoded length,
    /// which can differ by nearly a second—this is why the list shows 0:27 while the player shows 0:28.
    /// Total duration always uses the database value; the player's duration is only used to set the progress bar range.
    let totalDuration: TimeInterval?
    @Environment(\.dismiss) private var dismiss
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if let err = player.loadError {
                    // Playback unavailable (e.g. Opus on iOS 16). Show the
                    // reason instead of a dead play button.
                    VStack(spacing: 12) {
                        Image(systemName: "play.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                    }
                } else {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.1))
                            .frame(width: 120, height: 120)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.accentColor)
                    }
                    // The hit area must be larger than the drawn circle, or the
                    // padding around it swallows taps. An explicit 140pt area and
                    // a real button trait also make it reachable by VoiceOver and
                    // Switch Control.
                    .frame(width: 140, height: 140)
                    .contentShape(Circle())
                    .onTapGesture { player.toggle() }
                    .accessibilityAddTraits(.isButton)
                }

                if player.loadError == nil, player.duration > 0 {
                    VStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { isScrubbing ? scrubTime : player.currentTime },
                                set: { scrubTime = $0 }
                            ),
                            in: 0...max(player.duration, 0.01),
                            onEditingChanged: { editing in
                                if editing {
                                    scrubTime = player.currentTime
                                    isScrubbing = true
                                    // Hold the audio while the thumb is held:
                                    // the bar freezes at the finger, so the
                                    // audio must freeze with it.
                                    player.beginScrub()
                                } else {
                                    // endScrub first: it sets currentTime to
                                    // the target synchronously, so dropping
                                    // isScrubbing can't show a stale frame.
                                    player.endScrub(at: scrubTime)
                                    isScrubbing = false
                                }
                            }
                        )
                        .padding(.horizontal)

                        HStack {
                            Text(formatTime(isScrubbing ? scrubTime : player.currentTime))
                            Spacer()
                            Text(formatTime(totalDuration ?? player.duration))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    }
                }

                Spacer()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        ClockLabel.mmss(seconds)
    }
}

// MARK: - Full-screen transcript view

struct TranscriptFullView: View {
    let document: TranscriptDocument
    @State private var showShareSheet = false

    private var plainText: String {
        if document.segments.isEmpty { return document.text }
        return document.segments.map { seg in
            var line = ""
            if let speaker = seg.speaker, !speaker.isEmpty {
                line += "[\(speaker)] "
            }
            let s = Int(seg.start)
            let e = Int(seg.end)
            line += "(\(s / 60):\(String(format: "%02d", s % 60))\u{2013}\(e / 60):\(String(format: "%02d", e % 60))) "
            line += seg.text
            return line
        }.joined(separator: "\n\n")
    }

    var body: some View {
        Group {
            if document.segments.isEmpty {
                LongTextScroll(text: document.text)
            } else {
                // Lazy: a multi-hour clip is thousands of segments, and an
                // eager VStack lays every one of them out before the push
                // animation can start.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(document.segments.enumerated()), id: \.offset) { _, seg in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    if let speaker = seg.speaker, !speaker.isEmpty {
                                        Text(L10n.ClipDetail.speaker(speaker))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(stampLabel(seg))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(seg.text)
                                    .font(.body)
                                    .lineSpacing(6)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(L10n.ClipDetail.transcript)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [plainText])
        }
    }

    private func stampLabel(_ seg: AsrSegment) -> String {
        let s = Int(seg.start)
        let e = Int(seg.end)
        return String(format: "%d:%02d\u{2013}%d:%02d", s / 60, s % 60, e / 60, e % 60)
    }
}

// MARK: - Full-screen summary view

struct SummaryFullView: View {
    let text: String
    @State private var showRaw = false
    @State private var showShareSheet = false
    @State private var showMindMap = false

    var body: some View {
        Group {
            if showRaw {
                LongTextScroll(text: text, font: .body.monospaced())
            } else {
                MarkdownView(markdown: text)
            }
        }
        .navigationTitle(L10n.ClipDetail.summary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    if MarkdownOutline.parse(text) != nil {
                        Button {
                            showMindMap = true
                        } label: {
                            Image(systemName: "arrow.triangle.branch")
                        }
                        .accessibilityLabel(L10n.ClipDetail.mindMap)
                    }
                    Button {
                        showRaw.toggle()
                    } label: {
                        Image(systemName: showRaw ? "doc.richtext" : "doc.plaintext")
                    }
                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [text])
        }
        .fullScreenCover(isPresented: $showMindMap) {
            MindMapScreen(markdown: text, fallbackTitle: L10n.ClipDetail.summary)
        }
    }
}

// MARK: - Full-screen translation view

struct TranslationFullView: View {
    let text: String
    @State private var showShareSheet = false

    var body: some View {
        LongTextScroll(text: text)
            .navigationTitle(L10n.ClipDetail.translation)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: [text])
            }
    }
}

// MARK: - Long-text reader

/// Scrolling reader for transcripts, translations and raw summaries.
///
/// Two things it fixes over a plain `ScrollView { Text(whole) }`:
///
/// 1. **Latency.** One `Text` holding a whole transcript is laid out in a
///    single synchronous pass when the destination is pushed, which is what
///    made the translation entry take ~2 s on long clips. Splitting into
///    paragraphs inside a `LazyVStack` lets SwiftUI lay out only what's on
///    screen, so the push is immediate regardless of length.
/// 2. **Density.** CJK — Japanese especially — has no inter-word spaces, so
///    default `.body` line spacing reads as a solid block. The extra line
///    and paragraph spacing below is what makes translated output legible;
///    it is deliberate, not padding for its own sake.
struct LongTextScroll: View {
    let text: String
    var font: Font = .body

    /// Blank-line-separated blocks, falling back to single lines when the
    /// source has no blank lines (ASR transcripts are one line per phrase).
    private var paragraphs: [Substring] {
        let byBlankLine = text.split(separator: "\n", omittingEmptySubsequences: true)
        return byBlankLine.isEmpty ? [text[...]] : byBlankLine
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                    Text(para)
                        .font(font)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Share sheet (UIActivityViewController wrapper)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - helpers

struct TranscriptDocument {
    let text: String
    let segments: [AsrSegment]

    static func load(for audioName: String) -> TranscriptDocument? {
        let urls = StorageLocations.transcriptURLs(for: audioName)
        let fm = FileManager.default
        if fm.fileExists(atPath: urls.json.path),
           let data = try? Data(contentsOf: urls.json),
           let result = try? JSONDecoder().decode(AsrResult.self, from: data) {
            return TranscriptDocument(text: result.text, segments: result.segments)
        }
        if fm.fileExists(atPath: urls.txt.path),
           let data = try? Data(contentsOf: urls.txt),
           let text = String(data: data, encoding: .utf8) {
            return TranscriptDocument(text: text, segments: [])
        }
        return nil
    }
}
