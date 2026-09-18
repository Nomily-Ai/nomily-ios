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

    static func fetchOllama(endpoint: String) async -> FetchResult {
        let base = endpoint.hasSuffix("/") ? String(endpoint.dropLast()) : endpoint
        return await fetchURL(url: "\(base)/api/tags", parse: parseOllamaModels)
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
