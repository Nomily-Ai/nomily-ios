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
            return L10n.ASR.clipTooShort(duration, minimum)
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
