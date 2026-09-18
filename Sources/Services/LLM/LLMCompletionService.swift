import Foundation

enum LLMCompletionError: LocalizedError {
    case noProvider
    case noModel
    case noAPIKey
    case httpError(Int, String)
    case decodingError(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .noProvider: return "No active LLM provider configured."
        case .noModel: return "No model selected for the active provider."
        case .noAPIKey: return "No API key configured for the active provider."
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .decodingError(let msg): return "Failed to parse response: \(msg)"
        case .emptyResponse: return "The model returned an empty response."
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

    /// Output cap sent to every provider. A transcript longer than the
    /// model's context still isn't split into chunks — that's a separate
    /// piece of work; for now the caller is told when the answer got cut.
    static let maxOutputTokens = 4096

    /// Session for **locally hosted** models (Ollama, and any self-hosted
    /// OpenAI-compatible endpoint).
    ///
    /// `URLSession.shared` gives every request a 60 s `timeoutIntervalForRequest`,
    /// and that timer measures the gap between *incoming bytes* — not the total
    /// request. Our calls are non-streaming, so the server writes nothing at all
    /// until the whole completion is generated. A local model chewing through a
    /// 4000-character transcript therefore produces **zero bytes for the entire
    /// run**, and anything past the one-minute mark dies as `NSURLErrorTimedOut`
    /// even though the server is working perfectly.
    ///
    /// A cloud provider answers in a couple of seconds, so the default is fine
    /// there. On-device inference has no such speed guarantee — the local ASR
    /// path already widens its timeout to 600 s for exactly this reason
    /// (see `LocalASR`); this brings the LLM path in line.
    private static let localSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 1800
        // Surviving a Wi-Fi hand-off matters on a phone that is talking to a
        // box on the LAN; without this the request fails instantly while the
        // radio is still coming up.
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }()


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
        let providers = config.llmProviders
        guard let primary = providers.primary, !primary.isEmpty else { return false }
        switch primary {
        case "openai":
            guard let p = providers.openai else { return false }
            return !p.apiKey.isEmpty && !(p.model ?? "").isEmpty
        case "claude":
            guard let p = providers.claude else { return false }
            return !p.apiKey.isEmpty && !(p.model ?? "").isEmpty
        case "gemini":
            guard let p = providers.gemini else { return false }
            return !p.apiKey.isEmpty && !(p.model ?? "").isEmpty
        case "openRouter":
            guard let p = providers.openRouter else { return false }
            return !(p.apiKey ?? "").isEmpty && !(p.model ?? "").isEmpty
        case "ollama":
            guard let p = providers.ollama else { return false }
            return !p.endpoint.isEmpty && !(p.model ?? "").isEmpty
        case "custom":
            guard let p = providers.custom else { return false }
            return !p.endpoint.isEmpty && !(p.model ?? "").isEmpty
        default:
            return false
        }
    }

    /// Translate `text` into the given language using the active LLM
    /// provider. `targetLanguage` should be a human-readable English
    /// name (e.g. "Spanish (Spain)") — most models handle a name better
    /// than a BCP-47 code. Markdown / bullet / paragraph structure is
    /// preserved so the same helper works for both plain transcripts
    /// and markdown summaries.
    static func translate(text: String, targetLanguage: String, config: AppConfig) async throws -> Completion {
        let system = """
        You are a professional translator. Translate the user's text into \(targetLanguage). \
        Preserve the original formatting — paragraphs, line breaks, markdown headings, lists, and bold/italic emphasis must all be retained. \
        Do not add commentary, do not wrap the output in quotes, do not prefix with a language label. Reply with ONLY the translation.
        """
        return try await complete(systemPrompt: system, userContent: text, config: config)
    }

    static func complete(systemPrompt: String, userContent: String, config: AppConfig) async throws -> Completion {
        let providers = config.llmProviders
        guard let primary = providers.primary, !primary.isEmpty else {
            throw LLMCompletionError.noProvider
        }

        switch primary {
        case "openai":
            guard let p = providers.openai else { throw LLMCompletionError.noProvider }
            guard let model = p.model, !model.isEmpty else { throw LLMCompletionError.noModel }
            return try await openAICompatible(
                endpoint: "https://api.openai.com/v1/chat/completions",
                apiKey: p.apiKey, model: model,
                systemPrompt: systemPrompt, userContent: userContent
            )

        case "claude":
            guard let p = providers.claude else { throw LLMCompletionError.noProvider }
            guard let model = p.model, !model.isEmpty else { throw LLMCompletionError.noModel }
            return try await anthropic(
                apiKey: p.apiKey, model: model,
                systemPrompt: systemPrompt, userContent: userContent
            )

        case "gemini":
            guard let p = providers.gemini else { throw LLMCompletionError.noProvider }
            guard let model = p.model, !model.isEmpty else { throw LLMCompletionError.noModel }
            return try await gemini(
                apiKey: p.apiKey, model: model,
                systemPrompt: systemPrompt, userContent: userContent
            )

        case "openRouter":
            guard let p = providers.openRouter else { throw LLMCompletionError.noProvider }
            guard let model = p.model, !model.isEmpty else { throw LLMCompletionError.noModel }
            guard let key = p.apiKey, !key.isEmpty else { throw LLMCompletionError.noAPIKey }
            let ep = p.endpoint.isEmpty ? "https://openrouter.ai/api/v1/chat/completions" : "\(p.endpoint)/chat/completions"
            return try await openAICompatible(
                endpoint: ep, apiKey: key, model: model,
                systemPrompt: systemPrompt, userContent: userContent
            )

        case "ollama":
            guard let p = providers.ollama else { throw LLMCompletionError.noProvider }
            guard let model = p.model, !model.isEmpty else { throw LLMCompletionError.noModel }
            let base = p.endpoint.hasSuffix("/") ? String(p.endpoint.dropLast()) : p.endpoint
            return try await openAICompatible(
                endpoint: "\(base)/v1/chat/completions",
                apiKey: p.apiKey ?? "", model: model,
                systemPrompt: systemPrompt, userContent: userContent,
                session: localSession
            )

        case "custom":
            guard let p = providers.custom else { throw LLMCompletionError.noProvider }
            guard let model = p.model, !model.isEmpty else { throw LLMCompletionError.noModel }
            let base = p.endpoint.hasSuffix("/") ? String(p.endpoint.dropLast()) : p.endpoint
            return try await openAICompatible(
                endpoint: "\(base)/chat/completions",
                apiKey: p.apiKey ?? "", model: model,
                systemPrompt: systemPrompt, userContent: userContent,
                session: localSession
            )

        default:
            throw LLMCompletionError.noProvider
        }
    }

    // MARK: - OpenAI-compatible (OpenAI, OpenRouter, Ollama, Custom)

    /// `session` defaults to the shared one (fine for cloud providers, which
    /// answer in seconds). Self-hosted providers pass `localSession` — see its
    /// doc comment for why a 60 s default would kill every local completion.
    private static func openAICompatible(
        endpoint: String, apiKey: String, model: String,
        systemPrompt: String, userContent: String,
        session: URLSession = .shared
    ) async throws -> Completion {
        guard let url = URL(string: endpoint) else {
            throw LLMCompletionError.httpError(0, "Invalid endpoint URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userContent]
            ],
            "max_tokens": maxOutputTokens
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMCompletionError.httpError(code, msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMCompletionError.decodingError("Missing choices[0].message.content")
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LLMCompletionError.emptyResponse }
        return Completion(
            text: content,
            truncated: (first["finish_reason"] as? String) == "length"
        )
    }

    // MARK: - Anthropic (Claude)

    private static func anthropic(
        apiKey: String, model: String,
        systemPrompt: String, userContent: String
    ) async throws -> Completion {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LLMCompletionError.httpError(0, "Invalid URL")
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

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMCompletionError.httpError(code, msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw LLMCompletionError.decodingError("Missing content[]")
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
            throw LLMCompletionError.httpError(0, "Invalid URL")
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

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMCompletionError.httpError(code, msg)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let contentObj = first["content"] as? [String: Any],
              let parts = contentObj["parts"] as? [[String: Any]] else {
            throw LLMCompletionError.decodingError("Missing candidates[0].content.parts")
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
