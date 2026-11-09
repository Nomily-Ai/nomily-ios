import Foundation

/// Shared transcription result shape across providers (Azure, local server).
/// Structure written to `{name}.asr.json`.
struct AsrResult: Codable, Equatable {
    var text: String
    var segments: [AsrSegment]
    var provider: String
    var locale: String
}

struct AsrSegment: Codable, Equatable {
    var speaker: String?
    var text: String
    var start: Double
    var end: Double
    var duration: Double
}

enum AsrError: LocalizedError {
    /// The associated value is the **service provider name** ("Azure" / "Local server"), not the full sentence —
    // the full sentence is assembled from a localized template; otherwise each call site would hard‑code an English string.
    case missingCredentials(String)
    case noProviderConfigured
    case allProvidersUnreachable
    case azureRequiredForTranslation
    case http(Int, String)
    case transport(Error)
    case decoding(Error)
    case empty
    case tooShort(duration: Double, minimum: Double)
    /// Async cloud tasks (Aliyun file transcription) that are still running past
    /// our wait cap. **Not retriable**: resubmitting would bill the same audio
    /// twice — the server-side task keeps going, a later manual retry is right.
    case stillRunning(minutes: Int)
    /// The async cloud task itself failed server-side (e.g. the project's model
    /// doesn't match the audio's language/sample rate). Not retriable.
    case taskFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let provider):
            return L10n.ASR.missingCredentials(provider)
        case .noProviderConfigured:
            return L10n.ASR.noProviderConfigured
        case .allProvidersUnreachable:
            return L10n.ASR.allProvidersUnreachable
        case .azureRequiredForTranslation:
            return L10n.ASR.azureRequiredForTranslation
        case .http(let code, let body):
            // ★ 2026-11-06（用户："自定义端点仍报 400"）：只贴一段原始 body 不够——
            // 空 body 的 400（网关/代理/路由没通）看上去和"参数写错"一模一样，
            // 用户只能反复猜。现在：body 原样保留（截断），空体明确写 empty body，
            // 并按状态码给一句"下一步查哪里"。文案是诊断细节，保持英文与上面一致。
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = trimmed.isEmpty ? "(empty body)" : String(trimmed.prefix(200))
            return "ASR provider returned HTTP \(code): \(shown)\(AsrError.httpHint(code))"
        case .transport(let err):
            return "Network error: \(err.localizedDescription)"
        case .decoding(let err):
            return "Could not parse ASR response: \(err.localizedDescription)"
        case .empty:
            return L10n.ASR.transcriptEmpty
        case .tooShort(let duration, let minimum):
            return L10n.ASR.clipTooShort(duration, minimum)
        case .stillRunning(let minutes):
            return L10n.ASR.stillRunning(minutes)
        case .taskFailed(let detail):
            return L10n.ASR.taskFailed(detail)
        }
    }

    /// 状态码 → 一句"下一步查哪里"。只给方向，不猜具体配置（那是用户的服务器）。
    ///
    /// ★ 2026-11-06：自定义/自建 ASR 的失败现场大多是"服务端没进业务逻辑"就被
    /// 网关挡回来（空体 400/404/413），原始 body 里什么线索都没有。这里按码
    /// 分类，把最可能的那一件事说出来，省掉一轮来回猜。
    private static func httpHint(_ code: Int) -> String {
        switch code {
        case 400:
            return " — check the model name, the language hint, and that the URL ends at /v1/audio/transcriptions"
        case 401, 403:
            return " — the key was rejected; re-check the token and whether it may use this model"
        case 404:
            return " — the path does not exist on that server; base URL should be the host (or …/v1), not a custom route"
        case 413:
            return " — the clip is larger than the server's upload limit; try a shorter take or raise the limit"
        case 415:
            return " — the server refused this audio container; WAV is the safest format for strict servers"
        case 422:
            return " — a required form field is missing or malformed (model / file / response_format)"
        case 429:
            return " — rate-limited or out of quota; wait and retry, or check the plan"
        case 500...599:
            return " — the server itself failed; its logs will say why (this is not a Nomily bug)"
        default:
            return ""
        }
    }
}

/// Speaker labels are short codes from the provider (Azure = "1","2",…).
extension AsrSegment {
    /// `speakerNames` lets the caller substitute the user's own names
    /// (`SpeakerNameStore`). ★ 2026-10-22 ("还要支持修改说话人的名称"): a summary written
    /// after renaming must say "张伟", not "Speaker 1" — this is the one place the
    /// speaker is written into text handed to the model, so the map goes in here
    /// rather than being patched into every caller.
    func formatted(speakerNames: [String: String] = [:]) -> String {
        let stamp = String(format: "[%7.1fs - %7.1fs]", start, end)
        if let speaker = speaker, !speaker.isEmpty {
            let name = speakerNames[speaker].flatMap { $0.isEmpty ? nil : $0 } ?? speaker
            return "\(stamp) \(name): \(text)"
        }
        return "\(stamp) \(text)"
    }

    func formatted() -> String {
        formatted(speakerNames: [:])
    }
}
