import Foundation
import os

/// "Is this provider actually usable right now, and how fast is it?"
///
/// 2026-10-22 request:
/// > "然后再增加一个测试连通跟延迟性"
///
/// Two different questions, one probe. The existing model-list fetch answers
/// neither honestly: `/models` can succeed while chats are refused (wrong tier,
/// model not enabled for the account, quota exhausted), and it measures a
/// metadata endpoint rather than the model itself.
///
/// So this sends **one real, tiny chat request** with `max_tokens: 1` — 1 token
/// of quota, and the round-trip time is the number the user cares about: how long
/// it takes before the thing starts answering. Each provider family gets its own
/// wire format, because a probe that doesn't match what `LLMCompletionService`
/// actually sends would be measuring a different thing than the one that breaks.
enum LLMConnectivityService {

    struct Result: Equatable {
        var ok: Bool
        /// Round trip for one minimal chat completion, in milliseconds.
        /// Meaningful only when `ok` — a timeout is not a latency measurement.
        var millis: Int
        /// `HTTP 200 · gpt-4o-mini` on success, the vendor's own message on failure.
        var detail: String?
        var error: String?

        static func failure(_ error: String) -> Result {
            Result(ok: false, millis: 0, detail: nil, error: error)
        }
    }

    private static let log = Logger(subsystem: "com.nomily.app", category: "LLM-Probe")

    /// Prompt is one word on purpose: anything longer and the measurement starts
    /// including the provider's prefill work instead of just the round trip.
    private static let probePrompt = "hi"

    /// Ceiling for the probe. A cloud model that hasn't answered in 30 s is not a
    /// model this app can summarise with, so waiting longer would only waste the
    /// user's time on a screen that exists to answer quickly.
    private static let cloudTimeout: TimeInterval = 30
    private static let localTimeout: TimeInterval = 12

    // MARK: - Entry point

    static func test(
        spec: LLMProviderSpec, endpoint: String, apiKey: String, model: String
    ) async -> Result {
        guard !model.isEmpty else { return .failure(L10n.LLM.testNeedModel) }
        if spec.keyRequired, apiKey.isEmpty { return .failure(L10n.LLM.testNeedKey) }

        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard !base.isEmpty, URL(string: base) != nil else {
            return .failure(L10n.LLM.testBadEndpoint)
        }

        let request: URLRequest
        do {
            request = try build(spec: spec, base: base, apiKey: apiKey, model: model)
        } catch {
            return .failure(L10n.LLM.testBadEndpoint)
        }

        let started = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0

            guard (200..<300).contains(code) else {
                let reason = message(in: data) ?? L10n.LLM.testHTTP(code)
                log.notice("probe \(spec.id, privacy: .public) → HTTP \(code, privacy: .public)")
                return Result(ok: false, millis: millis, detail: "HTTP \(code)", error: reason)
            }
            // 200 but a body we can't read means it answered with something other
            // than a completion — worth flagging, since the summary would break
            // the same way later, only much less visibly.
            guard answered(data, provider: spec.id) else {
                return Result(ok: false, millis: millis, detail: "HTTP \(code)",
                              error: L10n.LLM.testUnexpectedBody)
            }
            log.notice("probe \(spec.id, privacy: .public) ok in \(millis, privacy: .public) ms")
            return Result(ok: true, millis: millis, detail: "HTTP \(code) · \(model)")
        } catch {
            let ns = error as NSError
            log.error("probe \(spec.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if ns.domain == NSURLErrorDomain,
               ns.code == NSURLErrorTimedOut {
                return .failure(L10n.LLM.testTimeout)
            }
            if ns.domain == NSURLErrorDomain,
               ns.code == NSURLErrorCannotFindHost || ns.code == NSURLErrorCannotConnectToHost {
                return .failure(L10n.LLM.testUnreachable)
            }
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Per-provider wire formats

    private static func build(
        spec: LLMProviderSpec, base: String, apiKey: String, model: String
    ) throws -> URLRequest {
        switch spec.id {
        case "openai":
            return try openAI(
                url: "https://api.openai.com/v1/chat/completions",
                apiKey: apiKey, model: model, timeout: cloudTimeout
            )
        case "claude":
            var req = try json(
                url: "https://api.anthropic.com/v1/messages",
                body: [
                    "model": model,
                    "max_tokens": 1,
                    "messages": [["role": "user", "content": probePrompt]],
                ],
                timeout: cloudTimeout
            )
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return req
        case "gemini":
            // The key travels in the query string here — that is Gemini's shape,
            // not a choice. Model ids also lose their `models/` prefix, which the
            // REST path re-adds.
            let name = model.hasPrefix("models/") ? model : "models/\(model)"
            var comps = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/\(name):generateContent")
            comps?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            guard let url = comps?.url else { throw ProbeError.badURL }
            return try json(
                url: url.absoluteString,
                body: [
                    "contents": [["parts": [["text": probePrompt]]]],
                    "generationConfig": ["maxOutputTokens": 1],
                ],
                timeout: cloudTimeout
            )
        case "openRouter":
            return try openAI(url: "\(base)/chat/completions", apiKey: apiKey,
                              model: model, timeout: cloudTimeout)
        case "ollama":
            // Same endpoint the completion path uses (`/v1/chat/completions`, not
            // `/api/chat`): testing a path the app never takes would clear a
            // provider that still fails at summary time.
            return try openAI(url: "\(base)/v1/chat/completions", apiKey: apiKey,
                              model: model, timeout: localTimeout)
        case "custom":
            return try openAI(url: "\(base)/chat/completions", apiKey: apiKey,
                              model: model, timeout: localTimeout)
        default:
            // Presets (Qwen / DeepSeek / Doubao): OpenAI-compatible base that
            // already ends in `/v1` or `/api/v3`.
            return try openAI(url: "\(base)/chat/completions", apiKey: apiKey,
                              model: model, timeout: cloudTimeout)
        }
    }

    private enum ProbeError: Error { case badURL }

    private static func openAI(
        url: String, apiKey: String, model: String, timeout: TimeInterval
    ) throws -> URLRequest {
        var req = try json(
            url: url,
            body: [
                "model": model,
                "messages": [["role": "user", "content": probePrompt]],
                "max_tokens": 1,
                // Explicitly off: a stream would finish the HTTP response before
                // the model did anything, and the timing would stop meaning
                // anything.
                "stream": false,
            ],
            timeout: timeout
        )
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private static func json(
        url: String, body: [String: Any], timeout: TimeInterval
    ) throws -> URLRequest {
        guard let url = URL(string: url) else { throw ProbeError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Response reading

    /// Did this 2xx body actually contain an answer? Each family nests it
    /// differently, and a proxy that returns `{"ok":true}` with status 200 would
    /// otherwise be reported as a working provider.
    private static func answered(_ data: Data, provider: String) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        switch provider {
        case "claude":
            return json["content"] is [[String: Any]] || json["type"] as? String == "message"
        case "gemini":
            return json["candidates"] is [[String: Any]]
        default:
            return json["choices"] is [[String: Any]]
        }
    }

    /// Vendors all bury the human-readable reason one level down, under `error`.
    /// Surfacing it verbatim beats any paraphrase we could write: "model
    /// `gpt-5` does not exist" is exactly what the user needs to read.
    private static func message(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let err = json["error"] as? [String: Any] {
            for key in ["message", "msg", "detail", "type"] {
                if let text = err[key] as? String, !text.isEmpty { return text }
            }
            if let text = err["error"] as? String, !text.isEmpty { return text }
        }
        if let text = json["error"] as? String, !text.isEmpty { return text }
        if let text = json["message"] as? String, !text.isEmpty { return text }
        // Last resort: a short raw snippet, so a non-JSON gateway still says
        // *something* instead of "failed".
        let raw = String(data: data.prefix(180), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty == false) ? raw : nil
    }
}

/// Last measured latency per provider, so the grid can show it without probing
/// again. Deliberately small and dumb: `UserDefaults`, milliseconds only. A stale
/// number is still better than none — it tells the user which providers they have
/// already exercised, and it is stamped `measuredAt` so the UI can fade it out.
enum LLMLatencyMemory {

    private struct Entry: Codable {
        var millis: Int
        var measuredAt: Date
    }

    private static let key = "llm.latency.byProvider"

    static func save(_ millis: Int, for id: String) {
        var map = load()
        map[id] = Entry(millis: millis, measuredAt: Date())
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func clear(_ id: String) {
        var map = load()
        map.removeValue(forKey: id)
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// `nil` after two days: a latency from last week says nothing about now.
    static func millis(for id: String) -> Int? {
        guard let entry = load()[id] else { return nil }
        guard Date().timeIntervalSince(entry.measuredAt) < 2 * 24 * 3600 else { return nil }
        return entry.millis
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return map
    }
}
