import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "languages")

@MainActor
final class LanguageService: ObservableObject {
    struct Language: Identifiable, Equatable {
        let code: String
        let name: String
        let nativeName: String
        var id: String { code }
    }

    @Published private(set) var targetLanguages: [Language] = []
    private var fetched = false

    func fetchTargetLanguagesIfNeeded() {
        guard !fetched else { return }
        fetched = true
        Task { await fetchTargetLanguages() }
    }

    private func fetchTargetLanguages() async {
        if let cached = loadCache() {
            targetLanguages = cached
            log.info("loaded \(cached.count) cached target languages")
        }

        guard let url = URL(string:
            "https://api.cognitive.microsofttranslator.com/languages?api-version=3.0&scope=translation"
        ) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let translation = parsed?["translation"] as? [String: [String: Any]] else { return }

            var result: [Language] = []
            for (code, info) in translation {
                let name = info["name"] as? String ?? code
                let native = info["nativeName"] as? String ?? name
                result.append(Language(code: code, name: name, nativeName: native))
            }
            result.sort { $0.name < $1.name }
            targetLanguages = result
            saveCache(result)
            log.info("fetched \(result.count) target languages from API")
        } catch {
            log.warning("failed to fetch target languages: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Source languages (static per provider)

    static func sourceLanguages(for provider: String) -> [Language] {
        switch provider.lowercased() {
        case "azure":
            return azureSpeechLocales
        case "local":
            return whisperLanguages
        default:
            return azureSpeechLocales
        }
    }

    /// The 15 locales Azure Fast Transcription's multi-language model
    /// recognizes when `locales` is specified (or auto-detects across when
    /// omitted). Keep in sync with Microsoft's published supported list —
    /// passing a locale outside this set has undefined behavior.
    static let azureMultiLanguageLocales: [Language] = {
        let codes: Set<String> = [
            "de-DE", "en-AU", "en-CA", "en-GB", "en-IN", "en-US",
            "es-ES", "es-MX", "fr-CA", "fr-FR", "it-IT",
            "ja-JP", "ko-KR", "pt-BR", "zh-CN",
        ]
        let byCode = Dictionary(uniqueKeysWithValues: azureSpeechLocales.map { ($0.code, $0) })
        return codes.compactMap { byCode[$0] ?? supplementalLocale(for: $0) }
            .sorted { $0.name < $1.name }
    }()

    private static func supplementalLocale(for code: String) -> Language? {
        switch code {
        case "en-CA": return Language(code: "en-CA", name: "English (Canada)", nativeName: "English (Canada)")
        case "en-IN": return Language(code: "en-IN", name: "English (India)", nativeName: "English (India)")
        case "fr-CA": return Language(code: "fr-CA", name: "French (Canada)", nativeName: "Français (Canada)")
        default: return nil
        }
    }

    // MARK: - Disk cache

    private static var cacheURL: URL {
        StorageLocations.root.appendingPathComponent("target_languages.json")
    }

    private func loadCache() -> [Language]? {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let arr = try? JSONDecoder().decode([CachedLang].self, from: data) else { return nil }
        return arr.map { Language(code: $0.code, name: $0.name, nativeName: $0.nativeName) }
    }

    private func saveCache(_ languages: [Language]) {
        let arr = languages.map { CachedLang(code: $0.code, name: $0.name, nativeName: $0.nativeName) }
        if let data = try? JSONEncoder().encode(arr) {
            try? data.write(to: Self.cacheURL, options: .atomic)
        }
    }

    private struct CachedLang: Codable {
        let code: String
        let name: String
        let nativeName: String
    }

    // MARK: - Static language lists

    private static let azureSpeechLocales: [Language] = [
        Language(code: "zh-CN", name: "Chinese (Mandarin)", nativeName: "中文 (普通话)"),
        Language(code: "zh-TW", name: "Chinese (Taiwanese)", nativeName: "中文 (台灣)"),
        Language(code: "zh-HK", name: "Chinese (Cantonese)", nativeName: "中文 (粵語)"),
        Language(code: "en-US", name: "English (US)", nativeName: "English (US)"),
        Language(code: "en-GB", name: "English (UK)", nativeName: "English (UK)"),
        Language(code: "en-AU", name: "English (Australia)", nativeName: "English (Australia)"),
        Language(code: "ja-JP", name: "Japanese", nativeName: "日本語"),
        Language(code: "ko-KR", name: "Korean", nativeName: "한국어"),
        Language(code: "fr-FR", name: "French", nativeName: "Français"),
        Language(code: "de-DE", name: "German", nativeName: "Deutsch"),
        Language(code: "es-ES", name: "Spanish (Spain)", nativeName: "Español (España)"),
        Language(code: "es-MX", name: "Spanish (Mexico)", nativeName: "Español (México)"),
        Language(code: "pt-BR", name: "Portuguese (Brazil)", nativeName: "Português (Brasil)"),
        Language(code: "pt-PT", name: "Portuguese (Portugal)", nativeName: "Português (Portugal)"),
        Language(code: "it-IT", name: "Italian", nativeName: "Italiano"),
        Language(code: "ru-RU", name: "Russian", nativeName: "Русский"),
        Language(code: "ar-SA", name: "Arabic (Saudi)", nativeName: "العربية"),
        Language(code: "hi-IN", name: "Hindi", nativeName: "हिन्दी"),
        Language(code: "th-TH", name: "Thai", nativeName: "ไทย"),
        Language(code: "vi-VN", name: "Vietnamese", nativeName: "Tiếng Việt"),
        Language(code: "id-ID", name: "Indonesian", nativeName: "Bahasa Indonesia"),
        Language(code: "ms-MY", name: "Malay", nativeName: "Bahasa Melayu"),
        Language(code: "nl-NL", name: "Dutch", nativeName: "Nederlands"),
        Language(code: "pl-PL", name: "Polish", nativeName: "Polski"),
        Language(code: "tr-TR", name: "Turkish", nativeName: "Türkçe"),
        Language(code: "uk-UA", name: "Ukrainian", nativeName: "Українська"),
        Language(code: "sv-SE", name: "Swedish", nativeName: "Svenska"),
        Language(code: "cs-CZ", name: "Czech", nativeName: "Čeština"),
        Language(code: "da-DK", name: "Danish", nativeName: "Dansk"),
        Language(code: "fi-FI", name: "Finnish", nativeName: "Suomi"),
    ]

    private static let whisperLanguages: [Language] = [
        Language(code: "zh", name: "Chinese", nativeName: "中文"),
        Language(code: "en", name: "English", nativeName: "English"),
        Language(code: "ja", name: "Japanese", nativeName: "日本語"),
        Language(code: "ko", name: "Korean", nativeName: "한국어"),
        Language(code: "fr", name: "French", nativeName: "Français"),
        Language(code: "de", name: "German", nativeName: "Deutsch"),
        Language(code: "es", name: "Spanish", nativeName: "Español"),
        Language(code: "pt", name: "Portuguese", nativeName: "Português"),
        Language(code: "it", name: "Italian", nativeName: "Italiano"),
        Language(code: "ru", name: "Russian", nativeName: "Русский"),
        Language(code: "ar", name: "Arabic", nativeName: "العربية"),
        Language(code: "hi", name: "Hindi", nativeName: "हिन्दी"),
        Language(code: "th", name: "Thai", nativeName: "ไทย"),
        Language(code: "vi", name: "Vietnamese", nativeName: "Tiếng Việt"),
        Language(code: "id", name: "Indonesian", nativeName: "Bahasa Indonesia"),
        Language(code: "ms", name: "Malay", nativeName: "Bahasa Melayu"),
        Language(code: "nl", name: "Dutch", nativeName: "Nederlands"),
        Language(code: "pl", name: "Polish", nativeName: "Polski"),
        Language(code: "tr", name: "Turkish", nativeName: "Türkçe"),
        Language(code: "uk", name: "Ukrainian", nativeName: "Українська"),
        Language(code: "sv", name: "Swedish", nativeName: "Svenska"),
        Language(code: "cs", name: "Czech", nativeName: "Čeština"),
        Language(code: "da", name: "Danish", nativeName: "Dansk"),
        Language(code: "fi", name: "Finnish", nativeName: "Suomi"),
        Language(code: "el", name: "Greek", nativeName: "Ελληνικά"),
        Language(code: "he", name: "Hebrew", nativeName: "עברית"),
        Language(code: "hu", name: "Hungarian", nativeName: "Magyar"),
        Language(code: "no", name: "Norwegian", nativeName: "Norsk"),
        Language(code: "ro", name: "Romanian", nativeName: "Română"),
        Language(code: "sk", name: "Slovak", nativeName: "Slovenčina"),
        Language(code: "bg", name: "Bulgarian", nativeName: "Български"),
        Language(code: "hr", name: "Croatian", nativeName: "Hrvatski"),
        Language(code: "sr", name: "Serbian", nativeName: "Српски"),
        Language(code: "sl", name: "Slovenian", nativeName: "Slovenščina"),
        Language(code: "et", name: "Estonian", nativeName: "Eesti"),
        Language(code: "lv", name: "Latvian", nativeName: "Latviešu"),
        Language(code: "lt", name: "Lithuanian", nativeName: "Lietuvių"),
        Language(code: "tl", name: "Tagalog", nativeName: "Tagalog"),
        Language(code: "sw", name: "Swahili", nativeName: "Kiswahili"),
        Language(code: "ta", name: "Tamil", nativeName: "தமிழ்"),
        Language(code: "te", name: "Telugu", nativeName: "తెలుగు"),
        Language(code: "bn", name: "Bengali", nativeName: "বাংলা"),
        Language(code: "ur", name: "Urdu", nativeName: "اردو"),
        Language(code: "fa", name: "Persian", nativeName: "فارسی"),
        Language(code: "ml", name: "Malayalam", nativeName: "മലയാളം"),
        Language(code: "kn", name: "Kannada", nativeName: "ಕನ್ನಡ"),
        Language(code: "my", name: "Myanmar", nativeName: "မြန်မာ"),
        Language(code: "ka", name: "Georgian", nativeName: "ქართული"),
        Language(code: "az", name: "Azerbaijani", nativeName: "Azərbaycan"),
        Language(code: "af", name: "Afrikaans", nativeName: "Afrikaans"),
    ]
}
