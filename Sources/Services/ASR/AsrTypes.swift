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
            return "ASR provider returned HTTP \(code): \(body.prefix(200))"
        case .transport(let err):
            return "Network error: \(err.localizedDescription)"
        case .decoding(let err):
            return "Could not parse ASR response: \(err.localizedDescription)"
        case .empty:
            return L10n.ASR.transcriptEmpty
        case .tooShort(let duration, let minimum):
            return String(format: "Clip is %.1fs (under the %.0fs minimum). Adjust min_transcribe_duration in Settings to transcribe shorter clips.", duration, minimum)
        }
    }
}

/// Speaker labels are short codes from the provider (Azure = "1","2",…).
extension AsrSegment {
    func formatted() -> String {
        let stamp = String(format: "[%7.1fs - %7.1fs]", start, end)
        if let speaker = speaker, !speaker.isEmpty {
            return "\(stamp) Speaker \(speaker): \(text)"
        }
        return "\(stamp) \(text)"
    }
}
