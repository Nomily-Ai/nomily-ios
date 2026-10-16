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
    /// The whole fallback chain has been walked. `failures` holds the reason from **each channel individually** —
    /// reporting only the last one would make users think the problem is on the last channel (the fallback one,
    /// usually the local Ollama, when the real cause is often the first channel having no key configured).
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

    /// Result of one completion **with fallback**.
    ///
    /// `providerKey` is the channel that **actually did the work** (it may be the fallback channel, not the primary):
    /// the UI has to be able to say "who generated this one", otherwise "I set it to Open Router" —
    /// when it was really the local Ollama standing in — leaves that question with nowhere to be answered.
    struct Outcome {
        var completion: Completion
        var providerKey: String
        /// The channels that failed before it; each already carries a human-readable name and reason.
        var warnings: [String]
        /// Whether the "chunk → merge" path was taken (long transcripts).
        var chunked: Bool
        /// How many chunks it was split into.
        var chunkCount: Int
    }

    /// Output cap sent to every provider. `maxOutputTokens(for:)` lowers it for
    /// local models — see there.
    static let maxOutputTokens = 4096

    /// Output cap for local models (Ollama / self-hosted endpoints).
    ///
    /// Measured on 2026-10-15: local `qwen2.5:3b` on this Intel Mac runs at about
    /// **5 token/s** on **CPU alone** ⇒ 4096 tokens take 13 minutes. And one chunked summary at 2048 already
    /// amounts to over a thousand Chinese characters, which is enough. Halve the cap and the worst-case time is halved too.
    static let localMaxOutputTokens = 2048

    /// Input cap for a single request (characters).
    ///
    /// ★ Why chunking is mandatory rather than "cram in as much as fits":
    /// `num_ctx` **is not available**. Ollama's OpenAI-compatible endpoint has no such field in the request,
    /// and the measured default on this machine is `16384` — but another machine or another model gives a different number.
    /// The worst part of exceeding it isn't an error, it's **silently truncating from the start**: the user gets a summary that looks complete,
    /// is actually missing the first half, and has no warning at all. Chunking is the only way to guarantee that "input + output
    /// lands safely inside any common context". 8000 characters ≈ 5000 tokens (the measured ratio for Chinese
    /// is 0.62 tokens/character), plus 4096 output = 9096 < 16384, leaving ample headroom.
    static let maxCharsPerRequest = 8000

    /// Session for **locally hosted** models (Ollama, and any self-hosted
    /// OpenAI-compatible endpoint).
    ///
    /// `URLSession.shared` gives every request a 60 s `timeoutIntervalForRequest`,
    /// and that timer measures the gap between *incoming bytes* — not the total
    /// request.
    ///
    /// ★ 2026-10-15: the local path now **streams** (see `openAICompatible`),
    /// so the meaning of this 600 s shifted from "the total budget for one generation" to "**how long without a byte** counts as stuck":
    /// prefill (the slowest step of all — a 12000-token prompt takes minutes on CPU alone) counts
    /// before the first chunk, and every chunk after that resets it. Only the two together let "even a slow model finish"
    /// — under the old non-streaming setup 600 s was the **total** budget and any long transcript was bound to hit it.
    private static let localSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        // Hard cap on the whole request. Under streaming this is the fuse for a "genuinely infinite loop", not a performance metric.
        cfg.timeoutIntervalForResource = 7200
        // Surviving a Wi-Fi hand-off matters on a phone that is talking to a
        // box on the LAN; without this the request fails instantly while the
        // radio is still coming up.
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    /// URLSession for cloud channels. It also widens the resource cap a little: after a very long transcript is split up,
    /// a single request can still run for a minute or two.
    private static let cloudSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 1800
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()

    // MARK: - Channels

    /// A channel's display name. **One copy only** — the settings page, error messages and fallback notices all read it here,
    /// and three separate copies would sooner or later produce "the settings page calls it Open Router, the error calls it openRouter".
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

    /// Whether this channel runs on the local machine (decides the timeout policy and the output cap).
    static func isLocal(_ key: String) -> Bool {
        key == "ollama" || key == "custom"
    }

    /// Fallback order.
    ///
    /// **Local channels come first**: they cost no quota and never leave the machine, and a fallback only ever happens
    /// after "the primary channel has already proved unusable", at which point gambling on a cloud channel is pointless.
    private static let fallbackOrder = ["ollama", "custom", "openRouter", "openai", "claude", "gemini"]

    /// The channels to try in order this time: **the primary channel leads** (even if it isn't fully configured — that way "no key configured"
    /// can be reported as a **concrete reason** instead of being silently skipped), followed by everything usable.
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

    /// Whether this channel has enough config "to send one request". Whatever is missing, that reason is what it returns.
    ///
    /// ★ Its job differs from `configuredProviders` (which lists only **fully configured** channels): this one has to
    /// say what's missing. The user's current situation is exactly this — `llm_providers.primary`
    /// points at Open Router, yet the `open_router` section doesn't even have an `api_key` field,
    /// and the UI shows only "No API key configured", with no hint of where to go to fix it.
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

    /// The primary channel **can't** be used, but can a fallback be? Used for a health check on Settings / the summary page.
    ///
    /// A non-nil return ⇒ this summary will definitely "fail first, then fall back", which is worth telling the user in advance.
    static func primaryGapWithFallback(_ config: AppConfig) -> (gap: String, fallback: String?)? {
        guard let primary = config.llmProviders.primary, !primary.isEmpty else { return nil }
        guard let gap = configGap(primary, config) else { return nil }
        let others = candidateChain(config).dropFirst()
        return (gap, others.first.map { providerLabel($0) })
    }

    /// Which channel to switch to when the primary one can't be used — what's returned is the **channel key** ("ollama"),
    /// not the display name, so the UI can write it straight back to `llm_providers.primary`.
    ///
    /// ★ 2026-10-15: used for "one-tap fix". The root cause measured this time has exactly this shape —
    /// `llm_providers.primary` points at Open Router, yet the `open_router` section doesn't even have
    /// an `api_key`, and what the user actually wants is the local Ollama. A hint alone still leaves them to
    /// find "Settings → LLM providers" themselves, scroll to Open Router and locate the primary-channel selector;
    /// and there is only one right answer to this.
    ///
    /// Returns nil when the primary channel is fine or there's no fallback at all (in which case the button shouldn't show).
    static func suggestedPrimary(_ config: AppConfig) -> String? {
        guard let primary = config.llmProviders.primary, !primary.isEmpty else { return nil }
        guard configGap(primary, config) != nil else { return nil }
        // `primary` non-empty ⇒ it is always at index 0 of `candidateChain`, so
        // what `dropFirst()` gives you is the first usable fallback.
        return candidateChain(config).dropFirst().first
    }

    // MARK: - Entry points

    /// Translate `text` into the given language using the active LLM
    /// provider. `targetLanguage` should be a human-readable English
    /// name (e.g. "Spanish (Spain)") — most models handle a name better
    /// than a BCP-47 code. Markdown / bullet / paragraph structure is
    /// preserved so the same helper works for both plain transcripts
    /// and markdown summaries.
    ///
    /// - Parameter allowFallback: `true` for manual translation (that button on the detail page);
    ///   `false` for live translation — the live path is a loop that runs **every few seconds**,
    ///   and falling back to a CPU-only local model just piles up a growing backlog, so it's better to report the error honestly.
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
                // Translation is **not** chunked: chunking severs the coherence of the context (pronoun references and
                // consistent terminology both depend on the whole piece), and "one chunk left untranslated" is harder to spot than "the whole thing failed".
                allowChunking: false
            ).completion
        }
        return try await complete(systemPrompt: system, userContent: text, config: config)
    }

    /// Single-channel completion, where **the channel is the primary one from the config**.
    static func complete(systemPrompt: String, userContent: String, config: AppConfig) async throws -> Completion {
        guard let primary = config.llmProviders.primary, !primary.isEmpty else {
            throw LLMCompletionError.noProvider
        }
        return try await complete(
            providerKey: primary,
            systemPrompt: systemPrompt, userContent: userContent, config: config
        )
    }

    /// Completion with fallback — actions like summaries and titles, where "the user tapped and must get a result", all go through it.
    ///
    /// Behaviour: primary channel → (on failure) local channels → other cloud channels. The failure reason at each step
    /// is collected into `Outcome.warnings` and reported all together at the end, rather than keeping only the last one.
    ///
    /// - Parameter preferred: the channel that did the real work last time; it gets moved to the head of the queue.
    ///   A summary is immediately followed by generating a title — without specifying it you'd **have to retry
    ///   the primary channel already proved unusable** once more (waiting for it to time out every time), wasting another dozen seconds.
    /// - Parameter onChunk: during chunked processing, calls back once per finished chunk with `(completed, total)`.
    ///   A long transcript runs for several minutes; a spinner going for a minute feels completely different to the user from "chunk 3/5".
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

    // MARK: - Chain

    /// Walk down the chain; the first one to succeed wins.
    private static func runChain(
        chain: [String], systemPrompt: String, userContent: String,
        config: AppConfig, chunked: Bool, chunkCount: Int,
        warnings seeded: [String] = []
    ) async throws -> Outcome {
        var warnings = seeded
        for key in chain {
            // A channel that isn't fully configured **sends no request**, but what's missing gets recorded in warnings —
            // that is exactly the most useful line the user can get out of this particular failure.
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
                // The user hit cancel / closed the page: **do not** go on to try the next channel —
                // that would turn into "cancelled but still burning money in the background".
                if Task.isCancelled { throw CancellationError() }
                if let urlError = error as? URLError, urlError.code == .cancelled { throw error }
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log.warning("LLM provider \(key, privacy: .public) failed: \(reason, privacy: .public)")
                warnings.append("\(providerLabel(key)): \(reason)")
            }
        }
        throw LLMCompletionError.allProvidersFailed(warnings)
    }

    // MARK: - Long transcripts: chunk → merge

    /// Read it once:
    ///
    /// 1. **Chunk**: split on blank lines / newlines / sentences, each chunk ≤ `maxCharsPerRequest`;
    /// 2. run every chunk through the same instruction, producing only **that chunk's key points**;
    /// 3. run all the key points together with **the original instruction** once more to produce the final result.
    ///
    /// Why not just truncate the whole thing: after truncation the user gets a summary that "looks complete but is actually missing
    /// half of it", with no warning at all — which is far worse than an error.
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
            // The merge step counts as one more unit of progress, otherwise it would sit at "n/n" waiting.
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

    /// The chunking instruction. **Appended after the original system prompt**, so that every constraint in the template
    /// (language, structure, don't fabricate) is still in place.
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

    /// Input to the merge step. **It must state clearly that "these are per-chunk key points, not the original transcript"**, otherwise the model will
    /// treat them as fresh material and summarise again, each level getting shallower.
    private static func mergePrompt(_ sections: [String]) -> String {
        """
        Below are the per-section findings from one long recording, in order. \
        Merge them into ONE final result that satisfies the original instructions exactly: \
        de-duplicate, group related items together, keep the requested structure, and \
        remove any trace of how it was split up (no "part 1 / part 2" headings).

        \(sections.enumerated().map { "--- section \($0.offset + 1) ---\n\($0.element)" }.joined(separator: "\n\n"))
        """
    }

    /// Greedy splitting: break at a blank line first, then a newline, and only then at sentence-ending punctuation.
    /// The point of the three tiers is "avoid cutting a sentence in half wherever possible" — feed half a sentence to the model
    /// and the result starts mid-thought, so the merge looks like a chunk went missing.
    static func split(_ text: String) -> [String] {
        guard text.count > maxCharsPerRequest else { return [text] }

        var chunks: [String] = []
        var current = ""
        // First split into blocks on blank lines, then pack the blocks into boxes by newline and by character.
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

    /// A single paragraph is over the limit on its own (voice transcripts are often **one whole piece with no blank lines**).
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

    /// Last resort: split at sentence-ending punctuation, and if there really is none, cut it hard.
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
                // Twice the cap with no sentence-ending punctuation in sight (long foreign sentences / unpunctuated transcripts) —
                // cut it hard, which beats accumulating forever.
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Single-channel request

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

    /// ★ 2026-10-15: this path was changed to **streaming** (`stream: true` + parsing SSE chunk by chunk).
    ///
    /// Three reasons, none of them optional:
    ///
    /// 1. **Timeout semantics**. Non-streaming, the server sends **not a single byte** until the whole generation is done,
    ///    so `timeoutIntervalForRequest` turns into "the total budget for one generation": a local
    ///    CPU-only 3B model takes over ten minutes to generate 4096 tokens, and 600 s trips it every time —
    ///    that is the direct cause of "every summary attempt fails". With streaming it goes back to its original meaning
    ///    (how long without a byte), and a slow model won't be killed as long as it's moving.
    /// 2. **Visible progress**. `onDelta` lets the layer above show "300 characters written so far",
    ///    instead of a spinner turning for over ten minutes.
    /// 3. **`finish_reason` as before**: it comes in the last chunk and truncation can still be detected.
    ///
    /// ⚠️ Compatibility fallback: in case some implementation doesn't recognise `stream` (older proxies and certain self-hosted gateways
    ///    just return one complete JSON), the code below **automatically falls back to non-streaming and retries once**.
    ///    Better one extra round trip than letting "summarise" break entirely after switching gateways.
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
            // Only "the streaming path itself didn't work" falls back to non-streaming:
            //   · `emptyResponse` — not a single token streamed out;
            //   · `decodingError` — what came back wasn't SSE but something else.
            // HTTP errors (401/429/5xx) are **not** retried: that error has nothing to do with streaming,
            // and firing once more only burns another unit of quota for nothing.
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

    /// Streaming. Call back per chunk + accumulate.
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
            // The vast majority of implementations give `delta.content`; a few (including some Ollama versions, in the last
            // chunk) give `message.content`. Accept both, don't pick one —
            // the one you miss is exactly the chunk that holds "the entire text is in here".
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
            // SSE frames arrive but the body is empty ⇒ upstream sent an error frame (OpenRouter, for instance, puts
            // insufficient quota in `error`); that is not an "empty response", and the original message has to be surfaced.
            throw LLMCompletionError.emptyResponse
        }
        return Completion(text: text, truncated: finishReason == "length" || finishReason == "max_tokens")
    }

    /// Non-streaming. Acts as the fallback for "the gateway doesn't recognise stream".
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

    /// Collect a response body for error reporting. **It must be capped**: even an error page can be tens of KB of HTML.
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
