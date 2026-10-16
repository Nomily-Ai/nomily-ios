import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "llm")

enum LLMCompletionError: LocalizedError {
    case noProvider
    case noModel(String)
    case noAPIKey(String)
    case noEndpoint(String)
    case httpError(Int, String)
    case decodingError(String)
    case emptyResponse
    /// 整条 fallback 链都走完了。`failures` 里是**每个通道各自**的原因 ——
    /// 只报最后一条会让用户以为问题在最后一个通道上（那是兜底的那个，
    /// 通常是本机的 Ollama，而真正的原因往往是第一个通道没配 Key）。
    case allProvidersFailed([String])

    var errorDescription: String? {
        switch self {
        case .noProvider:
            return L10n.LLM.errorNoProvider
        case .noModel(let label):
            return L10n.LLM.errorNoModel(label)
        case .noAPIKey(let label):
            return L10n.LLM.errorNoAPIKey(label)
        case .noEndpoint(let label):
            return L10n.LLM.errorNoEndpoint(label)
        case .httpError(let code, let msg):
            return L10n.LLM.errorHTTP(code, msg)
        case .decodingError(let msg):
            return L10n.LLM.errorDecoding(msg)
        case .emptyResponse:
            return L10n.LLM.errorEmptyResponse
        case .allProvidersFailed(let failures):
            return L10n.LLM.errorAllProvidersFailed(failures.joined(separator: "\n"))
        }
    }
}

struct LLMCompletionService {

    /// Result of one completion. `truncated` is the provider telling us it
    /// stopped because it hit the output cap, not because it was finished —
    /// the text is real but cut off mid-thought. It must reach the caller:
    /// dropped, a half-written summary looks exactly like a complete one.
    struct Completion {
        let text: String
        let truncated: Bool
    }

    /// 一次**带兜底**的补全结果。
    ///
    /// `providerKey` 是**真正干活**的那个通道（可能就是兜底通道，不是主通道）：
    /// 用户界面上要能说出"这次是谁生成的"，否则"我明明设的是 Open Router" ——
    /// 而其实是本机 Ollama 顶上的 —— 这种疑问无处可答。
    struct Outcome {
        var completion: Completion
        var providerKey: String
        /// 前面失败掉的通道，每条已经带好人类可读的名字与原因。
        var warnings: [String]
        /// 是否走了"分段 → 合并"这条路（长转录）。
        var chunked: Bool
        /// 分成几段。
        var chunkCount: Int
    }

    /// Output cap sent to every provider. `maxOutputTokens(for:)` lowers it for
    /// local models — see there.
    static let maxOutputTokens = 4096

    /// 本地模型（Ollama / 自建端点）的输出上限。
    ///
    /// 2026-10-15 实测：本机 `qwen2.5:3b` 在这台 Intel Mac 上**纯 CPU** 约
    /// **5 token/s** ⇒ 4096 个 token 要 13 分钟。而一次分段摘要给 2048 已经
    /// 相当于一千多汉字，够用。把上限砍半，最坏耗时也就砍半。
    static let localMaxOutputTokens = 2048

    /// 单次请求的输入上限（字符）。
    ///
    /// ★ 为什么必须分段，而不是"能塞多少塞多少"：
    /// `num_ctx` **拿不到**。Ollama 的 OpenAI 兼容端点在请求里没有这个字段，
    /// 实测本机默认值是 `16384` —— 但换台机器、换个模型就是别的数字。
    /// 超了之后最糟的不是报错，而是**悄悄从头截断**：用户拿到一份看着完整、
    /// 实际少了前半段的摘要，而且没有任何提示。分段是唯一能保证"输入 + 输出
    /// 稳稳落在任何常见上下文里"的做法。8000 字符 ≈ 5000 token（中文实测
    /// 比例 0.62 token/字符），加 4096 输出 = 9096 < 16384，留足余量。
    static let maxCharsPerRequest = 8000

    /// Session for **locally hosted** models (Ollama, and any self-hosted
    /// OpenAI-compatible endpoint).
    ///
    /// `URLSession.shared` gives every request a 60 s `timeoutIntervalForRequest`,
    /// and that timer measures the gap between *incoming bytes* — not the total
    /// request.
    ///
    /// ★ 2026-10-15：本地这条路现在**走流式**（见 `openAICompatible`），
    /// 所以这个 600 s 的含义从"整次生成的总预算"变成了"**多久没吐字节**才算卡死"：
    /// 预填充（这段是最慢的一步，12000 token 的提示在纯 CPU 上要几分钟）算在
    /// 第一块之前，之后每来一块都会把它重置。这两件事合起来才让"慢模型也算得完"
    /// —— 以前非流式时 600 s 是**总**预算，一条长转录必然撞上去。
    private static let localSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        // 整次请求的硬上限。流式下这是"真的死循环"的保险丝，不是性能指标。
        cfg.timeoutIntervalForResource = 7200
        // Surviving a Wi-Fi hand-off matters on a phone that is talking to a
        // box on the LAN; without this the request fails instantly while the
        // radio is still coming up.
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    /// 云端通道的 URLSession。也放宽一点资源上限：一条超长转录分段之后，
    /// 单次请求仍然可能跑上一两分钟。
    private static let cloudSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 1800
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    // MARK: - 通道

    /// 通道的展示名。**只此一份** —— 设置页、错误信息、兜底提示都读这里，
    /// 三处各写一份迟早会出现"设置页叫 Open Router、报错里叫 openRouter"。
    static func providerLabel(_ key: String) -> String {
        switch key {
        case "openai":     return "OpenAI"
        case "claude":     return "Claude"
        case "gemini":     return "Gemini"
        case "openRouter": return "Open Router"
        case "ollama":     return "Ollama"
        case "custom":     return "Custom"
        case "":           return L10n.LLM.errorNoProvider
        default:           return key
        }
    }

    /// 这个通道是不是跑在自己机器上（决定超时策略与输出上限）。
    static func isLocal(_ key: String) -> Bool {
        key == "ollama" || key == "custom"
    }

    /// 兜底顺序。
    ///
    /// **本机通道排在前面**：它们不花额度、不出网，而兜底本来就发生在
    /// "主通道已经证明不可用"之后，这时候再赌一个云端通道没有意义。
    private static let fallbackOrder = ["ollama", "custom", "openRouter", "openai", "claude", "gemini"]

    /// 这次要依次尝试的通道：**主通道打头**（哪怕它没配全 —— 这样"没配 Key"
    /// 才能作为一条**具体原因**报出来，而不是被静默跳过），后面接所有能用的。
    static func candidateChain(_ config: AppConfig) -> [String] {
        let providers = config.llmProviders
        var chain: [String] = []
        if let primary = providers.primary, !primary.isEmpty {
            chain.append(primary)
        }
        let configured = Set(providers.configuredProviders.map(\.key))
        for key in fallbackOrder where configured.contains(key) && !chain.contains(key) {
            chain.append(key)
        }
        return chain
    }

    /// 这个通道有没有"足以发一次请求"的配置。缺什么就返回那句原因。
    ///
    /// ★ 与 `configuredProviders`（只列出**配全了**的通道）分工不同：这里要
    /// 把"缺什么"说出来。用户当前的情况就是这样 —— `llm_providers.primary`
    /// 指着 Open Router，而 `open_router` 段里连 `api_key` 字段都没有，
    /// 界面上只显示一句 "No API key configured"，完全指不出该去哪儿补。
    static func configGap(_ key: String, _ config: AppConfig) -> String? {
        let p = config.llmProviders
        switch key {
        case "openai":
            guard let c = p.openai else { return L10n.LLM.errorNoProvider }
            if c.apiKey.isEmpty { return L10n.LLM.errorNoAPIKey(providerLabel(key)) }
            if (c.model ?? "").isEmpty { return L10n.LLM.errorNoModel(providerLabel(key)) }
        case "claude":
            guard let c = p.claude else { return L10n.LLM.errorNoProvider }
            if c.apiKey.isEmpty { return L10n.LLM.errorNoAPIKey(providerLabel(key)) }
            if (c.model ?? "").isEmpty { return L10n.LLM.errorNoModel(providerLabel(key)) }
        case "gemini":
            guard let c = p.gemini else { return L10n.LLM.errorNoProvider }
            if c.apiKey.isEmpty { return L10n.LLM.errorNoAPIKey(providerLabel(key)) }
            if (c.model ?? "").isEmpty { return L10n.LLM.errorNoModel(providerLabel(key)) }
        case "openRouter":
            guard let c = p.openRouter else { return L10n.LLM.errorNoProvider }
            if (c.apiKey ?? "").isEmpty { return L10n.LLM.errorNoAPIKey(providerLabel(key)) }
            if (c.model ?? "").isEmpty { return L10n.LLM.errorNoModel(providerLabel(key)) }
        case "ollama":
            guard let c = p.ollama else { return L10n.LLM.errorNoProvider }
            if c.endpoint.isEmpty { return L10n.LLM.errorNoEndpoint(providerLabel(key)) }
            if (c.model ?? "").isEmpty { return L10n.LLM.errorNoModel(providerLabel(key)) }
        case "custom":
            guard let c = p.custom else { return L10n.LLM.errorNoProvider }
            if c.endpoint.isEmpty { return L10n.LLM.errorNoEndpoint(providerLabel(key)) }
            if (c.model ?? "").isEmpty { return L10n.LLM.errorNoModel(providerLabel(key)) }
        default:
            return L10n.LLM.errorNoProvider
        }
        return nil
    }

    /// Does the current config have everything one `complete` call needs?
    ///
    /// ★ 2026-10-14: serves as the **single criterion** for "can live translation go through the LLM".
    /// This check used to be written separately in `LiveView` (`azureConfigured`) and `LiveModel.openASR`,
    /// so whenever the two disagreed you got contradictions like
    /// "the UI says unavailable, the logic says available". Both sides now call here.
    ///
    /// ⚠️ Looks only at **whether the config is complete** (key/model/endpoint non-empty) and **makes no network request** --
    ///    it is used to "decide in advance whether to translate", not as a connectivity check.
    ///    If it really cannot connect, `translate` throws and the soft-warning path handles it.
    static func isConfigured(_ config: AppConfig) -> Bool {
        guard let primary = config.llmProviders.primary, !primary.isEmpty else { return false }
        return configGap(primary, config) == nil
    }

    /// 主通道**不能**用，但兜底通道能用吗？给 Settings / 摘要页做体检用。
    ///
    /// 返回值非 nil ⇒ 现在这一次摘要一定会"先失败、再兜底"，值得提前告诉用户。
    static func primaryGapWithFallback(_ config: AppConfig) -> (gap: String, fallback: String?)? {
        guard let primary = config.llmProviders.primary, !primary.isEmpty else { return nil }
        guard let gap = configGap(primary, config) else { return nil }
        let others = candidateChain(config).dropFirst()
        return (gap, others.first.map { providerLabel($0) })
    }

    /// 主通道不能用时，应该改用哪个通道 —— 返回的是**通道键**（"ollama"），
    /// 不是显示名，供 UI 直接写回 `llm_providers.primary`。
    ///
    /// ★ 2026-10-15：给"一键修复"用。这次实测到的根因正好就是这个形状 ——
    /// `llm_providers.primary` 指着 Open Router，而 `open_router` 段里连
    /// `api_key` 都没有，用户想用的其实是本机 Ollama。光给提示的话，他还得
    /// 自己摸到「设置 → LLM 服务商」、翻到 Open Router、找到主通道选择器；
    /// 而这件事的正确答案只有一个。
    ///
    /// 主通道没问题、或压根没有兜底时返回 nil（此时不该显示按钮）。
    static func suggestedPrimary(_ config: AppConfig) -> String? {
        guard let primary = config.llmProviders.primary, !primary.isEmpty else { return nil }
        guard configGap(primary, config) != nil else { return nil }
        // `primary` 非空 ⇒ 它一定排在 `candidateChain` 的第 0 位，所以
        // `dropFirst()` 拿到的就是第一个可用的兜底。
        return candidateChain(config).dropFirst().first
    }

    // MARK: - 入口

    /// Translate `text` into the given language using the active LLM
    /// provider. `targetLanguage` should be a human-readable English
    /// name (e.g. "Spanish (Spain)") — most models handle a name better
    /// than a BCP-47 code. Markdown / bullet / paragraph structure is
    /// preserved so the same helper works for both plain transcripts
    /// and markdown summaries.
    ///
    /// - Parameter allowFallback: 手动翻译（详情页那颗按钮）为 `true`；
    ///   实时翻译为 `false` —— 实时那条路是**每几秒一次**的循环，
    ///   退到一个纯 CPU 的本机模型只会越积越多的积压，不如老实报错。
    static func translate(
        text: String, targetLanguage: String, config: AppConfig,
        allowFallback: Bool = true
    ) async throws -> Completion {
        let system = """
        You are a professional translator. Translate the user's text into \(targetLanguage). \
        Preserve the original formatting — paragraphs, line breaks, markdown headings, lists, and bold/italic emphasis must all be retained. \
        Do not add commentary, do not wrap the output in quotes, do not prefix with a language label. Reply with ONLY the translation.
        """
        if allowFallback {
            return try await completeResilient(
                systemPrompt: system, userContent: text, config: config,
                // 翻译**不**分段：分段会把上下文的连贯性切断（代词指代、
                // 术语统一都靠整篇），而"漏译一段"比"整篇失败"更难发现。
                allowChunking: false
            ).completion
        }
        return try await complete(systemPrompt: system, userContent: text, config: config)
    }

    /// 单通道补全，**通道就是配置里的主通道**。
    static func complete(systemPrompt: String, userContent: String, config: AppConfig) async throws -> Completion {
        guard let primary = config.llmProviders.primary, !primary.isEmpty else {
            throw LLMCompletionError.noProvider
        }
        return try await complete(
            providerKey: primary,
            systemPrompt: systemPrompt, userContent: userContent, config: config
        )
    }

    /// 带兜底的补全 —— 摘要、标题这类"用户点了就得有结果"的动作都走它。
    ///
    /// 行为：主通道 → （失败就）本机通道 → 其它云端通道。每一步的失败原因
    /// 都会收进 `Outcome.warnings`，最后一起报，而不是只留最后一条。
    ///
    /// - Parameter preferred: 上一次真正干活的通道，把它挪到队首。
    ///   摘要成功后紧接着要生成标题 —— 不指定的话就要**再把那条已经证明
    ///   不可用的主通道重试一遍**（每次都要等它超时），白白多等十几秒。
    /// - Parameter onChunk: 分段处理时每完成一段回调一次 `(已完成, 总段数)`。
    ///   长转录要跑好几分钟，转一分钟的菊花和"第 3/5 段"给用户的感受完全不同。
    @discardableResult
    static func completeResilient(
        systemPrompt: String, userContent: String, config: AppConfig,
        allowChunking: Bool = true, preferred: String? = nil,
        onChunk: (@MainActor (Int, Int) -> Void)? = nil
    ) async throws -> Outcome {
        var chain = candidateChain(config)
        guard !chain.isEmpty else {
            throw LLMCompletionError.allProvidersFailed([L10n.LLM.errorNoProvider])
        }
        if let preferred, chain.contains(preferred) {
            chain.removeAll { $0 == preferred }
            chain.insert(preferred, at: 0)
        }

        if allowChunking, userContent.count > maxCharsPerRequest {
            return try await completeChunked(
                systemPrompt: systemPrompt, userContent: userContent,
                chain: chain, config: config, onChunk: onChunk
            )
        }
        return try await runChain(
            chain: chain, systemPrompt: systemPrompt,
            userContent: userContent, config: config,
            chunked: false, chunkCount: 1
        )
    }

    // MARK: - 链

    /// 沿链试下去，第一个成功的赢。
    private static func runChain(
        chain: [String], systemPrompt: String, userContent: String,
        config: AppConfig, chunked: Bool, chunkCount: Int,
        warnings seeded: [String] = []
    ) async throws -> Outcome {
        var warnings = seeded
        for key in chain {
            // 配置不全的通道**不发请求**，但要把缺什么记进 warnings ——
            // 这正是用户当前那次失败能拿到的最有用的一句话。
            if let gap = configGap(key, config) {
                warnings.append("\(providerLabel(key)): \(gap)")
                continue
            }
            do {
                let completion = try await complete(
                    providerKey: key, systemPrompt: systemPrompt,
                    userContent: userContent, config: config
                )
                if !warnings.isEmpty {
                    log.notice("LLM fell back to \(key, privacy: .public) after: \(warnings.joined(separator: " | "), privacy: .public)")
                }
                return Outcome(
                    completion: completion, providerKey: key,
                    warnings: warnings, chunked: chunked, chunkCount: chunkCount
                )
            } catch {
                // 用户点了取消 / 关掉了页面：**不要**接着试下一个通道 ——
                // 那会变成"取消了还在后台烧钱"。
                if Task.isCancelled { throw CancellationError() }
                if let urlError = error as? URLError, urlError.code == .cancelled { throw error }
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log.warning("LLM provider \(key, privacy: .public) failed: \(reason, privacy: .public)")
                warnings.append("\(providerLabel(key)): \(reason)")
            }
        }
        throw LLMCompletionError.allProvidersFailed(warnings)
    }

    // MARK: - 长转录：分段 → 合并

    /// 读一遍：
    ///
    /// 1. **分段**：按空行 / 换行 / 句子切，每段 ≤ `maxCharsPerRequest`；
    /// 2. 每段用同一个要求跑一遍，只产出**这一段的要点**；
    /// 3. 把所有要点连同**原来的要求**再跑一遍，产出最终结果。
    ///
    /// 为什么不直接把整篇截断：截断之后用户拿到的是一份"看着完整、其实少了
    /// 一半"的摘要，而且没有任何提示 —— 那比报错糟得多。
    private static func completeChunked(
        systemPrompt: String, userContent: String,
        chain: [String], config: AppConfig,
        onChunk: (@MainActor (Int, Int) -> Void)?
    ) async throws -> Outcome {
        let chunks = split(userContent)
        guard chunks.count > 1 else {
            return try await runChain(
                chain: chain, systemPrompt: systemPrompt,
                userContent: userContent, config: config,
                chunked: false, chunkCount: 1
            )
        }
        log.notice("summarising a long transcript in \(chunks.count, privacy: .public) chunks")
        await onChunk?(0, chunks.count)

        var warnings: [String] = []
        var sections: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let outcome = try await runChain(
                chain: chain,
                systemPrompt: sectionSystemPrompt(systemPrompt, index: index, total: chunks.count),
                userContent: chunk, config: config,
                chunked: true, chunkCount: chunks.count,
                warnings: warnings
            )
            warnings = outcome.warnings
            sections.append(outcome.completion.text)
            // 合并那一步也算一段进度，否则最后会停在 "n/n" 上干等。
            await onChunk?(index + 1, chunks.count + 1)
        }

        let merged = try await runChain(
            chain: chain, systemPrompt: systemPrompt,
            userContent: mergePrompt(sections),
            config: config, chunked: true, chunkCount: chunks.count,
            warnings: warnings
        )
        await onChunk?(chunks.count + 1, chunks.count + 1)
        return merged
    }

    /// 分段要求。**接在原来的 system prompt 后面**，这样模板里的所有约束
    /// （语言、结构、不要编造）都还在。
    private static func sectionSystemPrompt(_ original: String, index: Int, total: Int) -> String {
        """
        \(original)

        ———
        The user's content below is ONLY part \(index + 1) of \(total) of one longer recording. \
        Work on this part alone: produce just the findings for this part, in the same format the instructions above ask for. \
        Do NOT add an introduction, do NOT add a closing summary, and do NOT refer to "this part" — \
        your output will be merged with the other parts afterwards.
        """
    }

    /// 合并步骤的输入。**必须说清"这是各段要点、不是原始记录"**，否则模型会把
    /// 它们当成新素材再摘一次，层级越摘越浅。
    private static func mergePrompt(_ sections: [String]) -> String {
        """
        Below are the per-section findings from one long recording, in order. \
        Merge them into ONE final result that satisfies the original instructions exactly: \
        de-duplicate, group related items together, keep the requested structure, and \
        remove any trace of how it was split up (no "part 1 / part 2" headings).

        \(sections.enumerated().map { "--- section \($0.offset + 1) ---\n\($0.element)" }.joined(separator: "\n\n"))
        """
    }

    /// 贪心切分：优先在空行、其次在换行、最后在句末标点处断开。
    /// 三档的用意是"尽量别把一个句子劈成两半" —— 半句话喂给模型，
    /// 出来的结果会从中间开始，合并时看着像丢了一段。
    static func split(_ text: String) -> [String] {
        guard text.count > maxCharsPerRequest else { return [text] }

        var chunks: [String] = []
        var current = ""
        // 先按空行切成块，块再按换行、按字符塞进箱子。
        for paragraph in text.components(separatedBy: "\n\n") {
            let piece = paragraph + "\n\n"
            if piece.count > maxCharsPerRequest {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: splitLongParagraph(paragraph))
                continue
            }
            if current.count + piece.count > maxCharsPerRequest {
                chunks.append(current)
                current = piece
            } else {
                current += piece
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(current)
        }
        return chunks.isEmpty ? [text] : chunks
    }

    /// 单个段落本身就超限（语音转录经常是**一整篇没有空行**的文本）。
    private static func splitLongParagraph(_ paragraph: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in paragraph.components(separatedBy: "\n") {
            let piece = line + "\n"
            if piece.count > maxCharsPerRequest {
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(contentsOf: splitBySentence(line))
                continue
            }
            if current.count + piece.count > maxCharsPerRequest {
                chunks.append(current)
                current = piece
            } else {
                current += piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// 最后一道：按句末标点切，实在没有标点就硬切。
    private static func splitBySentence(_ line: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n", "；", ";"]
        var chunks: [String] = []
        var current = ""
        for character in line {
            current.append(character)
            if current.count >= maxCharsPerRequest, terminators.contains(character) {
                chunks.append(current)
                current = ""
            } else if current.count >= maxCharsPerRequest * 2 {
                // 两倍上限都没碰到一个句末标点（外语长句 / 无标点转录）——
                // 硬切，总比无限攒下去好。
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - 单通道请求

    private static func complete(
        providerKey: String, systemPrompt: String, userContent: String, config: AppConfig
    ) async throws -> Completion {
        let providers = config.llmProviders
        switch providerKey {
        case "openai":
            guard let p = providers.openai else { throw LLMCompletionError.noProvider }
            guard !p.apiKey.isEmpty else { throw LLMCompletionError.noAPIKey(providerLabel(providerKey)) }
            guard let model = p.model, !model.isEmpty else { throw LLMCompletionError.noModel(providerLabel(providerKey)) }
            return try await openAICompatible(
                endpoint: "https://api.openai.com/v1/chat/completions",
                apiKey: p.apiKey, model: model,
                systemPrompt: systemPrompt, userContent: userContent,
                session: cloudSession, maxTokens: maxOutputTokens
            )

        case "claude":
            guard let p = providers.claude else { throw LLMCompletionError.noProvider }
            guard !p.apiKey.isEmpty else { throw LLMCompletionError.noAPIKey(providerLabel(providerKey)) }
            guard let model = p.model, !model.isEmpty else { throw LLMCompletionError.noModel(providerLabel(providerKey)) }
            return try await anthropic(
                apiKey: p.apiKey, model: model,
                systemPrompt: systemPrompt, userContent: userContent
            )

        case "gemini":
            guard let p = providers.gemini else { throw LLMCompletionError.noProvider }
            guard !p.apiKey.isEmpty else { throw LLMCompletionError.noAPIKey(providerLabel(providerKey)) }
            guard let model = p.model, !model.isEmpty else { throw LLMCompletionError.noModel(providerLabel(providerKey)) }
            return try await gemini(
                apiKey: p.apiKey, model: model,
                systemPrompt: systemPrompt, userContent: userContent
            )

        case "openRouter":
            guard let p = providers.openRouter else { throw LLMCompletionError.noProvider }
            guard let key = p.apiKey, !key.isEmpty else { throw LLMCompletionError.noAPIKey(providerLabel(providerKey)) }
            guard let model = p.model, !model.isEmpty else { throw LLMCompletionError.noModel(providerLabel(providerKey)) }
            let ep = p.endpoint.isEmpty
                ? "https://openrouter.ai/api/v1/chat/completions"
                : "\(p.endpoint)/chat/completions"
            return try await openAICompatible(
                endpoint: ep, apiKey: key, model: model,
                systemPrompt: systemPrompt, userContent: userContent,
                session: cloudSession, maxTokens: maxOutputTokens
            )

        case "ollama":
            guard let p = providers.ollama else { throw LLMCompletionError.noProvider }
            guard !p.endpoint.isEmpty else { throw LLMCompletionError.noEndpoint(providerLabel(providerKey)) }
            guard let model = p.model, !model.isEmpty else { throw LLMCompletionError.noModel(providerLabel(providerKey)) }
            let base = p.endpoint.hasSuffix("/") ? String(p.endpoint.dropLast()) : p.endpoint
            return try await openAICompatible(
                endpoint: "\(base)/v1/chat/completions",
                apiKey: p.apiKey ?? "", model: model,
                systemPrompt: systemPrompt, userContent: userContent,
                session: localSession, maxTokens: localMaxOutputTokens
            )

        case "custom":
            guard let p = providers.custom else { throw LLMCompletionError.noProvider }
            guard !p.endpoint.isEmpty else { throw LLMCompletionError.noEndpoint(providerLabel(providerKey)) }
            guard let model = p.model, !model.isEmpty else { throw LLMCompletionError.noModel(providerLabel(providerKey)) }
            let base = p.endpoint.hasSuffix("/") ? String(p.endpoint.dropLast()) : p.endpoint
            return try await openAICompatible(
                endpoint: "\(base)/chat/completions",
                apiKey: p.apiKey ?? "", model: model,
                systemPrompt: systemPrompt, userContent: userContent,
                session: localSession, maxTokens: localMaxOutputTokens
            )

        default:
            throw LLMCompletionError.noProvider
        }
    }

    // MARK: - OpenAI-compatible (OpenAI, OpenRouter, Ollama, Custom)

    /// ★ 2026-10-15：这条路改成了**流式**（`stream: true` + 逐块解析 SSE）。
    ///
    /// 三个理由，一个都不能少：
    ///
    /// 1. **超时语义**。非流式时服务器在整段生成完之前**一个字节都不发**，
    ///    所以 `timeoutIntervalForRequest` 变成了"整次生成的总预算"：本机
    ///    纯 CPU 的 3B 模型生成 4096 个 token 要十几分钟，600 s 一到必挂 ——
    ///    这就是"摘要多少次都失败"的直接原因。流式之后它退回本来的含义
    ///    （多久没吐字节），慢模型只要在动就不会被杀。
    /// 2. **能看见进度**。`onDelta` 让上层可以显示"已经写了 300 字"，
    ///    而不是一个转十几分钟的菊花。
    /// 3. **`finish_reason` 照旧**：最后一块里带着，截断仍然能被识别。
    ///
    /// ⚠️ 兼容兜底：万一某个实现不认 `stream`（老版本代理、某些自建网关会
    ///    直接返回一个完整 JSON），下面会**自动退回非流式再试一次**。
    ///    宁可多一次往返，也不能让"摘要"在换了个网关之后整体失效。
    private static func openAICompatible(
        endpoint: String, apiKey: String, model: String,
        systemPrompt: String, userContent: String,
        session: URLSession, maxTokens: Int,
        onDelta: ((String) -> Void)? = nil
    ) async throws -> Completion {
        do {
            return try await openAICompatibleStream(
                endpoint: endpoint, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userContent: userContent,
                session: session, maxTokens: maxTokens, onDelta: onDelta
            )
        } catch let error as LLMCompletionError {
            // 只有"流式这条路本身没走通"才退回非流式：
            //   · `emptyResponse` —— 一个 token 都没流出来；
            //   · `decodingError` —— 拿到的不是 SSE 而是别的东西。
            // HTTP 错误（401/429/5xx）**不**重试：那个错误与非流式无关，
            // 再打一次只是白白多花一次额度。
            let streamPathFailed: Bool
            switch error {
            case .emptyResponse, .decodingError: streamPathFailed = true
            default:                             streamPathFailed = false
            }
            guard streamPathFailed else { throw error }
            log.notice("streaming failed for \(endpoint, privacy: .public); retrying without stream: \(error.localizedDescription, privacy: .public)")
            return try await openAICompatibleOnce(
                endpoint: endpoint, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userContent: userContent,
                session: session, maxTokens: maxTokens
            )
        }
    }

    private static func request(
        endpoint: String, apiKey: String, model: String,
        systemPrompt: String, userContent: String,
        maxTokens: Int, stream: Bool
    ) throws -> URLRequest {
        guard let url = URL(string: endpoint) else {
            throw LLMCompletionError.httpError(0, L10n.LLM.errorBadEndpointURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "max_tokens": maxTokens
        ]
        if stream { body["stream"] = true }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// 流式。逐块回调 + 累积。
    private static func openAICompatibleStream(
        endpoint: String, apiKey: String, model: String,
        systemPrompt: String, userContent: String,
        session: URLSession, maxTokens: Int,
        onDelta: ((String) -> Void)?
    ) async throws -> Completion {
        let req = try request(
            endpoint: endpoint, apiKey: apiKey, model: model,
            systemPrompt: systemPrompt, userContent: userContent,
            maxTokens: maxTokens, stream: true
        )
        let (stream, response) = try await session.bytes(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMCompletionError.httpError(code, try await bodySnippet(stream))
        }

        var text = ""
        var finishReason: String?

        for try await line in stream.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let first = choices.first
            else { continue }
            // 绝大多数实现给 `delta.content`；少数（含部分 Ollama 版本在最后
            // 一块里）给 `message.content`。两个都收，别二选一 ——
            // 漏掉的那个正好就是"全文都在这里"的那一块。
            var piece: String?
            if let delta = first["delta"] as? [String: Any] { piece = delta["content"] as? String }
            if piece == nil, let message = first["message"] as? [String: Any] {
                piece = message["content"] as? String
            }
            if let piece, !piece.isEmpty {
                text += piece
                onDelta?(piece)
            }
            if let reason = first["finish_reason"] as? String { finishReason = reason }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // 有 SSE 帧但正文为空 ⇒ 上游给了错误帧（例如 OpenRouter 会把
            // 额度不足放进 `error`），那不是"空回复"，得把原话说出来。
            throw LLMCompletionError.emptyResponse
        }
        return Completion(text: text, truncated: finishReason == "length" || finishReason == "max_tokens")
    }

    /// 非流式。充当"网关不认 stream"的兜底。
    private static func openAICompatibleOnce(
        endpoint: String, apiKey: String, model: String,
        systemPrompt: String, userContent: String,
        session: URLSession, maxTokens: Int
    ) async throws -> Completion {
        let req = try request(
            endpoint: endpoint, apiKey: apiKey, model: model,
            systemPrompt: systemPrompt, userContent: userContent,
            maxTokens: maxTokens, stream: false
        )
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw LLMCompletionError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMCompletionError.decodingError(L10n.LLM.errorMissingChoices)
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMCompletionError.emptyResponse }
        return Completion(
            text: content,
            truncated: (first["finish_reason"] as? String) == "length"
        )
    }

    /// 收集一段响应体用于报错。**必须有上限**：错误页也可能是几十 KB 的 HTML。
    private static func bodySnippet(_ stream: URLSession.AsyncBytes) async throws -> String {
        var raw = ""
        for try await line in stream.lines {
            raw += line
            if raw.count > 600 { break }
        }
        return raw
    }

    // MARK: - Anthropic (Claude)

    private static func anthropic(
        apiKey: String, model: String,
        systemPrompt: String, userContent: String
    ) async throws -> Completion {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LLMCompletionError.httpError(0, L10n.LLM.errorBadEndpointURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userContent]
            ],
            "max_tokens": maxOutputTokens
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await cloudSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw LLMCompletionError.httpError(code, msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw LLMCompletionError.decodingError(L10n.LLM.errorMissingContent)
        }
        // Join every text block. Reading only `content[0].text` broke on
        // models that emit a thinking block first (reported as "missing
        // text") and silently dropped everything after the first block.
        let text = content
            .filter { ($0["type"] as? String) == "text" || $0["type"] == nil }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMCompletionError.emptyResponse
        }
        return Completion(
            text: text,
            truncated: (json["stop_reason"] as? String) == "max_tokens"
        )
    }

    // MARK: - Gemini

    private static func gemini(
        apiKey: String, model: String,
        systemPrompt: String, userContent: String
    ) async throws -> Completion {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)") else {
            throw LLMCompletionError.httpError(0, L10n.LLM.errorBadEndpointURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": [["parts": [["text": userContent]]]],
            "generationConfig": ["maxOutputTokens": maxOutputTokens]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await cloudSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw LLMCompletionError.httpError(code, msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let contentObj = first["content"] as? [String: Any],
              let parts = contentObj["parts"] as? [[String: Any]] else {
            throw LLMCompletionError.decodingError(L10n.LLM.errorMissingCandidates)
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMCompletionError.emptyResponse
        }
        return Completion(
            text: text,
            truncated: (first["finishReason"] as? String) == "MAX_TOKENS"
        )
    }
}
