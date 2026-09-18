import Foundation

enum VerifyState: Equatable {
    case idle
    case verifying
    case success
    case failed(String)
}

struct LLMModelService {

    struct FetchResult {
        var ok: Bool
        var models: [String]
        var error: String?
        /// Supplementary info on success: model count / round-trip latency / server version.
        ///
        /// Same intent as `LocalASR.ProbeResult.detail` on the ASR side —— when the user taps "Test"
        /// what they want to know is not "there's a checkmark" but **who is actually on the other end and how fast it answers**.
        ///
        /// Optional with an implicit default of `nil`: the cloud providers can't get this info and shouldn't fabricate it.
        var detail: String?
    }

    // MARK: - OpenAI

    static func fetchOpenAI(apiKey: String) async -> FetchResult {
        await fetchBearer(
            url: "https://api.openai.com/v1/models",
            apiKey: apiKey,
            parse: parseOpenAIModels
        )
    }

    // MARK: - Claude (Anthropic)

    static func fetchClaude(apiKey: String) async -> FetchResult {
        guard let url = URL(string: "https://api.anthropic.com/v1/models?limit=100") else {
            return FetchResult(ok: false, models: [], error: "Bad URL")
        }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return await perform(req, parse: parseOpenAIModels)
    }

    // MARK: - Gemini

    static func fetchGemini(apiKey: String) async -> FetchResult {
        await fetchURL(
            url: "https://generativelanguage.googleapis.com/v1beta/models?key=\(apiKey)&pageSize=100",
            parse: parseGeminiModels
        )
    }

    // MARK: - OpenRouter (filtered by provider prefix)

    static func fetchOpenRouter(apiKey: String, providerPrefix: String) async -> FetchResult {
        let result = await fetchBearer(
            url: "https://openrouter.ai/api/v1/models",
            apiKey: apiKey,
            parse: parseOpenAIModels
        )
        guard result.ok else { return result }
        let prefix = providerPrefix.lowercased()
        let filtered = result.models.filter { $0.lowercased().hasPrefix(prefix) }
        return FetchResult(ok: true, models: filtered)
    }

    // MARK: - Ollama

    /// Fetch the model list, **and incidentally** turn this round trip into a connectivity test.
    ///
    /// Source (the user's exact words, 2026-10-14):
    /// > "ollama test click lists the models now, the click should also be able to run a connectivity test"
    ///
    /// So this returns more than model names: it measures one round-trip latency, then queries `/api/version` once,
    /// and assembles a one-line detail for the settings page to display —— speaking the same language as the local ASR probe.
    ///
    /// Latency is counted from **before the request is sent**, including DNS + connection setup + server processing,
    /// i.e. the time the user actually perceives; measuring only server processing time would be fooling ourselves.
    static func fetchOllama(endpoint: String) async -> FetchResult {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        let started = Date()
        let r = await fetchURL(url: "\(base)/api/tags", parse: parseOllamaModels)
        guard r.ok else { return r }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        // The version is a **bonus**: older versions or third-party compatible implementations have no `/api/version`,
        // and failing to get it doesn't affect the conclusion "connected", let alone make the whole probe count as failed.
        let version = await fetchOllamaVersion(base: base)
        return FetchResult(ok: true, models: r.models, error: nil,
                           detail: ollamaDetail(count: r.models.count, ms: ms, version: version))
    }

    /// `GET /api/version` → `{"version":"0.12.6"}`. Always returns `nil` on failure, never throws.
    private static func fetchOllamaVersion(base: String) async -> String? {
        guard let url = URL(string: "\(base)/api/version") else { return nil }
        var req = URLRequest(url: url)
        // The version is icing on the cake and not worth waiting longer than the main request —— the main request has its own timeout.
        req.timeoutInterval = 4
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String, !version.isEmpty
        else { return nil }
        return version
    }

    /// `1 model · 23 ms · v0.12.6`
    ///
    /// Fixed order, most informative first; if there is no version the whole segment is omitted, leaving no empty `· ·`.
    private static func ollamaDetail(count: Int, ms: Int, version: String?) -> String {
        var parts = [L10n.LLM.probeModelCount(count), "\(ms) ms"]
        if let version { parts.append("v\(version)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - OpenAI-compatible endpoint (Custom)

    /// A user-supplied OpenAI-compatible endpoint: `GET {base}/v1/models`.
    ///
    /// Differs from `fetchOpenAI` in only two ways: the address comes from user input, and the key may be empty.
    /// It doesn't reuse `fetchOpenAI` directly because the latter's URL is **hard-coded**
    /// (`https://api.openai.com/v1/models`) —— having the "custom endpoint" call it
    /// would lead troubleshooting into the pitfall of "why is it connecting to api.openai.com".
    ///
    /// Ollama also has its own `/v1/models`, so an Ollama pointed at this machine works through this path too.
    ///
    /// This also attaches connectivity detail (model count + latency). **Does not probe the version**: the OpenAI-compatible layer
    /// has no unified version endpoint, and forcing a probe only creates a request guaranteed to fail for third-party implementations.
    static func fetchOpenAICompatible(endpoint: String, apiKey: String?) async -> FetchResult {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        guard let url = URL(string: "\(base)/v1/models") else {
            return FetchResult(ok: false, models: [], error: "Bad URL")
        }
        var req = URLRequest(url: url)
        // The key is **optional**: local services basically don't validate it, so leave the header off when it's empty
        // (some self-hosted gateways actually return 401 outright when they see an empty Authorization).
        if let key = apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let started = Date()
        let r = await perform(req, parse: parseOpenAIModels)
        guard r.ok else { return r }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        return FetchResult(ok: true, models: r.models, error: nil,
                           detail: ollamaDetail(count: r.models.count, ms: ms, version: nil))
    }

    // MARK: - Azure Speech verify

    static func verifyAzure(key: String, region: String) async -> FetchResult {
        // Failure to construct a URL can only be due to a malformed region (contains spaces / Chinese characters / slashes), so we point directly to the region.
        guard let url = URL(string: "https://\(region).api.cognitive.microsoft.com/sts/v1.0/issueToken") else {
            return FetchResult(ok: false, models: [], error: L10n.AzureVerify.regionNotFound)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        req.setValue("0", forHTTPHeaderField: "Content-Length")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                return FetchResult(ok: true, models: [])
            }
            return FetchResult(ok: false, models: [], error: azureVerifyReason(code))
        } catch {
            // The hostname is `<region>.api.cognitive.microsoft.com`; if it cannot be resolved, the region is most likely incorrect,
            // but this path is also taken when offline, so this message mentions both region and network without drawing a conclusion for the user.
            let dnsFailed = (error as NSError).domain == NSURLErrorDomain
                && (error as NSError).code == NSURLErrorCannotFindHost
            return FetchResult(
                ok: false, models: [],
                error: dnsFailed ? L10n.AzureVerify.hostUnresolved : L10n.AzureVerify.network
            )
        }
    }

    /// Translate Azure status codes into a single user‑actionable sentence. A raw `HTTP 401` is neither understandable nor indicates whether to change the key or the region;
    /// the status code is kept only as secondary information in parentheses to aid log correlation during troubleshooting.
    static func azureVerifyReason(_ code: Int) -> String {
        let reason: String
        switch code {
        case 401, 403: reason = L10n.AzureVerify.badCredentials
        case 404: reason = L10n.AzureVerify.regionNotFound
        case 429: reason = L10n.AzureVerify.rateLimited
        case 500..<600: reason = L10n.AzureVerify.serviceUnavailable
        default: reason = L10n.AzureVerify.unexpected
        }
        return "\(reason) (HTTP \(code))"
    }

    // MARK: - internal

    private static func fetchBearer(
        url: String, apiKey: String,
        parse: @escaping ([String: Any]) -> [String]
    ) async -> FetchResult {
        guard let url = URL(string: url) else {
            return FetchResult(ok: false, models: [], error: "Bad URL")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return await perform(req, parse: parse)
    }

    private static func fetchURL(
        url: String,
        parse: @escaping ([String: Any]) -> [String]
    ) async -> FetchResult {
        guard let url = URL(string: url) else {
            return FetchResult(ok: false, models: [], error: "Bad URL")
        }
        return await perform(URLRequest(url: url), parse: parse)
    }

    private static func perform(
        _ req: URLRequest,
        parse: @escaping ([String: Any]) -> [String]
    ) async -> FetchResult {
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                return FetchResult(ok: false, models: [], error: "HTTP \(code)")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return FetchResult(ok: true, models: [])
            }
            return FetchResult(ok: true, models: parse(json))
        } catch {
            return FetchResult(ok: false, models: [], error: error.localizedDescription)
        }
    }

    // MARK: - parsers

    private static func parseOpenAIModels(_ json: [String: Any]) -> [String] {
        guard let data = json["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { $0["id"] as? String }.sorted()
    }

    private static func parseGeminiModels(_ json: [String: Any]) -> [String] {
        guard let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }.sorted()
    }

    private static func parseOllamaModels(_ json: [String: Any]) -> [String] {
        guard let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }
}
