import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "jobs")

// MARK: - 活的构造（id 的唯一来源）
//
// ⚠️ `id` 一律从这里生成，调用方**不要**自己拼字符串。理由：`id` 同时是
//    幂等键（同一条活重复入队不叠加）、是界面的行身份、也是"这条录音的活完没完"
//    的查询键 —— 三处各拼一遍，迟早会有一处漏掉一个字段（比如翻译忘了带目标
//    语言），于是"同一条录音换一种语言再翻一次"会被误判成同一条活的重复入队。
extension Job {

    /// 摘要：**一条录音同时只允许一条**（换模板再生成就是重跑那一条）。
    static func summarize(clip: String, prompt: String, templateName: String) -> Job {
        Job(
            id: "summarize:\(clip)",
            kind: .summarize,
            clipName: clip,
            enqueuedAt: Date(),
            prompt: prompt,
            templateName: templateName
        )
    }

    /// 翻译。`target` 取 `"transcript"` / `"summary"` —— 两者是**两条独立的活**
    /// （用户可能只翻了摘要、没翻全文），所以目标语言与目标对象都要进 `id`。
    static func translate(clip: String, target: String, languageName: String) -> Job {
        Job(
            id: "translate:\(target):\(clip)",
            kind: .translate,
            clipName: clip,
            enqueuedAt: Date(),
            languageName: languageName,
            translateTarget: target
        )
    }

    /// 格式转换 / 导出。**一条录音同时只留最后点的那一种格式** —— 用户点了
    /// m4a 又点 wav，他要的是 wav；两条都跑只会让 `ExportCenter`（只留一份）
    /// 里躺着哪一份变成运气。
    static func export(clip: String, format: AudioExportFormat) -> Job {
        Job(
            id: "export:\(clip)",
            kind: .export,
            clipName: clip,
            enqueuedAt: Date(),
            exportFormat: format.rawValue
        )
    }
}

// MARK: - 三个执行体
//
// 由 `AppEnvironment` 注册进 `JobQueue`。放在这里而不是写进组合根：
// 每个执行体都有二三十行"读源文件 → 调服务 → 落产物"，塞进 `init` 会让那个
// 文件只剩下时序统计和一段查不到结尾的闭包。
//
// ## 共同的形状
// 每个执行体做三件事：**① 自己占 `BackgroundKeeper` 的令牌 → ② 读源文件、
// 没有就抛 `JobSourceMissing` → ③ 干活并落产物**。
//
// ⚠️ 令牌由执行体自己占，`JobQueue` 不碰。这样四类活（含转录那条不在队列里的）
//    对 `BackgroundKeeper` 的用法完全一致 —— 队列只负责"什么时候跑"，
//    "跑的时候别被系统挂起"是每个执行体自己的事。
enum JobRunners {

    /// 摘要。原来这段在 `SummarizeSheet.runSummarize` 里（内存 `Task`），
    /// 十二改搬到这里，唯一的目的是让它在 App 被杀之后还能被捞起来接着跑。
    ///
    /// ⚠️ 片段进度与"结果附注"（用了兜底通道 / 被分段）**必须回话给队列**，
    ///    不能只留在视图里：这条活很可能是在用户看不见的时候跑完的。
    @MainActor
    static func summarize(
        _ job: Job, config: AppConfig, reporter: JobQueue.Reporter
    ) async throws {
        guard let prompt = job.prompt else { throw JobSourceMissing(what: L10n.Jobs.sourcePrompt) }
        let source = try transcriptText(for: job.clipName)

        BackgroundKeeper.shared.acquire(.summary)
        defer { BackgroundKeeper.shared.release(.summary) }

        let outcome = try await LLMCompletionService.completeResilient(
            systemPrompt: prompt,
            userContent: source,
            config: config,
            onChunk: { done, total in reporter.progress(done, total) }
        )
        try Task.checkCancellation()

        // ⚠️ 摘要与标题**一起落盘**，不等用户点保存。
        //
        // 这是十二改带来的必然变化：活的产物必须自己落地，否则"跑完了回来
        // 看结果"就没有结果可看（原来的模式是"结果攥在 sheet 的内存里，
        // 用户点保存才写"—— 那种模式在"App 被杀"面前什么都不剩）。
        // 顺带修掉一个老毛病：以前摘要写盘与标题写盘是两步，中途取消会留下
        // "改了名但没有摘要"的状态；现在两步在同一段同步代码里，只有全成
        // 或全不成。
        try? outcome.completion.text.data(using: .utf8)?
            .write(to: StorageLocations.summaryURL(for: job.clipName), options: .atomic)

        if let title = await extractTitle(
            from: outcome.completion.text,
            config: config,
            // ★ 直接找刚才真正干活的那个通道。不指定的话，主通道已经证明
            //   不可用了，这一步还要**再等它超时一次**才轮到兜底 ——
            //   那条超时在云端是 120 秒、在本机 Ollama 是 600 秒。
            preferred: outcome.providerKey
        ) {
            try? title.data(using: .utf8)?
                .write(to: StorageLocations.titleURL(for: job.clipName), options: .atomic)
        }

        // 附注放在最后：它是**结果**的一部分，前面任何一步抛出去都不该留下
        // "跑完了而且一切正常"的假象。
        reporter.notes(notices(for: outcome, config: config), outcome.completion.truncated)
        log.info("summary done for \(job.clipName, privacy: .public) via \(outcome.providerKey, privacy: .public)")
    }

    /// 翻译。原来在 `ClipDetailView.runTranslate` 里，分转录 / 摘要两条支路。
    @MainActor
    static func translate(
        _ job: Job, config: AppConfig, reporter: JobQueue.Reporter
    ) async throws {
        guard let languageName = job.languageName else {
            throw JobSourceMissing(what: L10n.Jobs.sourceLanguage)
        }
        let target = job.translateTarget ?? "transcript"

        BackgroundKeeper.shared.acquire(.summary)
        defer { BackgroundKeeper.shared.release(.summary) }

        // 译文也可能被输出上限截断。上一版是当场弹一句 alert；活改成后台跑
        // 之后那个 alert 覆盖不到（用户不在这一页），所以改成随产物落进
        // `Job.notes`，回来随时看得到。半截的译文和完整的译文长得一模一样。
        func report(_ output: LLMCompletionService.Completion) {
            reporter.notes(
                output.truncated ? [L10n.Summarize.truncatedWarning] : [],
                output.truncated
            )
        }

        switch target {
        case "summary":
            let url = StorageLocations.summaryTranslatedURL(for: job.clipName)
            let source = try summaryText(for: job.clipName)
            let output = try await LLMCompletionService.translate(
                text: source, targetLanguage: languageName, config: config
            )
            try Task.checkCancellation()
            try output.text.data(using: .utf8)?.write(to: url, options: .atomic)
            report(output)

        default:
            let urls = StorageLocations.translationURLs(for: job.clipName)
            let source = try transcriptText(for: job.clipName)
            let output = try await LLMCompletionService.translate(
                text: source, targetLanguage: languageName, config: config
            )
            try Task.checkCancellation()
            try output.text.data(using: .utf8)?.write(to: urls.txt, options: .atomic)
            // The Live-produced `.translated.json` carries word-level
            // timestamps for a specific target language; once the user
            // re-translates on-demand to a different language, that JSON
            // is stale, so wipe it rather than let it drift out of sync
            // with the displayed text.
            try? FileManager.default.removeItem(at: urls.json)
            report(output)
        }
        log.info("translated \(job.clipName, privacy: .public) → \(languageName, privacy: .public)")
    }

    /// 格式转换 / 导出。原来在 `ClipDetailView.runExport` 里。
    @MainActor
    static func export(_ job: Job, config: AppConfig) async throws {
        guard let raw = job.exportFormat,
              let format = AudioExportFormat(rawValue: raw) else {
            throw JobSourceMissing(what: L10n.Jobs.sourceFormat)
        }
        // ⚠️ 音频按**文件名**在 `decryptedDir` 里找，不把绝对路径存进活里 ——
        //    沙盒容器路径在重装 / 迁移之后会变，存下来的路径第二天就失效
        //    （`TranscriptionService` 那条队列在这里是同一个取舍）。
        let source = StorageLocations.decryptedDir.appendingPathComponent(job.clipName)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw JobSourceMissing(what: L10n.Jobs.sourceAudio)
        }

        BackgroundKeeper.shared.acquire(.export)
        defer { BackgroundKeeper.shared.release(.export) }

        // ★ 写进 `ExportCenter` 的暂存目录而不是 `tmp`：`tmp` 会被 iOS 随时
        //   清掉，而"导完切走、回来再分享"正是这条路要支持的场景。
        let dir = try ExportCenter.shared.beginNewStaging()
        let stem = (job.clipName as NSString).deletingPathExtension
        let url = try await AudioExporter.export(
            format, source: source, suggestedName: stem, directory: dir
        )
        try Task.checkCancellation()
        ExportCenter.shared.publish(
            id: dir.lastPathComponent,
            title: stem,
            itemCount: 1,
            bytes: fileSize(url),
            origin: job.clipName
        )
        log.info("exported \(job.clipName, privacy: .public) as \(raw, privacy: .public)")
    }

    // MARK: - 源文件

    /// 这条录音喂给模型的转录正文。
    ///
    /// ⚠️ **不能直接读 `{base}.txt`**。磁盘上那份是
    ///    `TranscriptionService.formatTranscript` 写的，规则是
    ///    "有分段就用 `formatted()`（**带时间戳**），没分段就用整段文本"；
    ///    而详情页发起摘要时用的是 `textForSummarization`，规则是
    ///    "有说话人就用 `formatted()`，**没有说话人就用不带时间戳的纯文本**"。
    ///    两者在"有分段但没识别出说话人"这一种情况下**不一样** ——
    ///    直接读文件会让同一份转录生成出结构不同的摘要，用户只会觉得
    ///    "这个功能时好时坏"。
    ///
    /// ⇒ 一律转发到 `summarizableText`，与详情页**逐字同源**。
    private static func transcriptText(for clipName: String) throws -> String {
        let urls = StorageLocations.transcriptURLs(for: clipName)
        // 优先 `.asr.json`：里面有分段与说话人，`summarizableText` 需要它们。
        if let data = try? Data(contentsOf: urls.json),
           let result = try? JSONDecoder().decode(AsrResult.self, from: data) {
            return summarizableText(text: result.text, segments: result.segments)
        }
        // 只剩 `.txt` 的情况（老数据的 json 被清掉了）：它就是全部信息了。
        return try read(urls.txt, what: L10n.Jobs.sourceTranscript)
    }

    /// 摘要 / 翻译真正喂进去的那串文本。
    ///
    /// ★ 这是**唯一实现**：`ClipDetailView.textForSummarization(_:)` 现在也转发
    ///   到这里。以前它自己写了一遍，而十二改之后摘要有了第二条入口（队列），
    ///   两份拷贝迟早会漂开 —— 那时表现是"同一个按钮，隔一天跑出来的摘要
    ///   结构不一样"，非常难查。
    static func summarizableText(text: String, segments: [AsrSegment]) -> String {
        if segments.isEmpty { return text }
        if segments.contains(where: { !($0.speaker ?? "").isEmpty }) {
            return segments.map { $0.formatted() }.joined(separator: "\n")
        }
        return segments.map(\.text).joined(separator: "\n")
    }

    private static func summaryText(for clipName: String) throws -> String {
        try read(StorageLocations.summaryURL(for: clipName), what: L10n.Jobs.sourceSummary)
    }

    private static func read(_ url: URL, what: String) throws -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            throw JobSourceMissing(what: what)
        }
        return text
    }

    // MARK: - 结果附注

    /// 把 `Outcome` 翻成人话。**两条都要说清楚**：
    /// 用的不是主通道（配置出了问题）、以及内容被分段处理过（结果的结构与
    /// 整篇一次生成会有细微差别，用户看到分段标题缺失会以为是 bug）。
    ///
    /// 从 `SummarizeSheet` 搬过来的 —— 它现在是"结果的一部分"，随产物一起
    /// 落进 `Job.notes`，而不是只在发起的那一页里有意义（那条活很可能是在
    /// 用户看不见的时候跑完的）。
    static func notices(for outcome: LLMCompletionService.Outcome, config: AppConfig) -> [String] {
        var result: [String] = []
        let primary = config.llmProviders.primary ?? ""
        if !primary.isEmpty, primary != outcome.providerKey {
            result.append(L10n.LLM.fellBack(
                LLMCompletionService.providerLabel(primary),
                LLMCompletionService.providerLabel(outcome.providerKey)
            ))
        }
        if outcome.chunked {
            result.append(L10n.LLM.chunkedNote(outcome.chunkCount))
        }
        return result
    }

    // MARK: - 标题（best-effort）

    /// 从摘要正文里再要一个短标题。失败就返回 nil —— 摘要本身是有效的，
    /// 不该因为标题生成不出来而把整条活判成失败。
    @MainActor
    private static func extractTitle(
        from summary: String, config: AppConfig, preferred: String?
    ) async -> String? {
        let instruction = """
            Generate a short title (under 60 characters) for the following notes. \
            Reply with ONLY the title text, no quotes, no punctuation at the end.
            """
        do {
            let outcome = try await LLMCompletionService.completeResilient(
                systemPrompt: instruction,
                userContent: String(summary.prefix(1000)),
                config: config,
                // 标题就 1000 字输入，没什么可分段的。
                allowChunking: false,
                preferred: preferred
            )
            let clean = outcome.completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        } catch {
            return nil
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
