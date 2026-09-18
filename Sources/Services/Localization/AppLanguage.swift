import Foundation
import SwiftUI

/// The app's UI languages.
///
/// Display names are **autonyms** and are never translated: someone opens this
/// screen precisely because they can't read the current UI, so showing
/// "German" translated into Japanese would defeat the purpose. The system
/// Settings language list does the same.
///
/// This table and `Sources/Resources/*.lproj` must move together — a language
/// listed here without an `.lproj` shows up in the picker and then silently
/// falls back to English.
enum AppLanguage {

    /// Fallback used when a stored/system language isn't one we ship.
    static let fallback = "en"

    struct Language: Identifiable, Equatable {
        let tag: String
        let autonym: String
        var id: String { tag }
    }

    /// English first (it's the fallback), then alphabetical by tag.
    static let supported: [Language] = [
        Language(tag: "en", autonym: "English"),
        Language(tag: "ar", autonym: "العربية"),
        Language(tag: "de", autonym: "Deutsch"),
        Language(tag: "es", autonym: "Español"),
        Language(tag: "fr", autonym: "Français"),
        Language(tag: "ja", autonym: "日本語"),
        Language(tag: "ko", autonym: "한국어"),
        Language(tag: "pt-BR", autonym: "Português (Brasil)"),
        Language(tag: "ru", autonym: "Русский"),
        Language(tag: "zh-Hans", autonym: "简体中文")
    ]

    /// Tag → autonym; unknown tags come back unchanged so a row never renders blank.
    static func autonym(of tag: String) -> String {
        supported.first { $0.tag.caseInsensitiveCompare(tag) == .orderedSame }?.autonym ?? tag
    }

    /// Narrows any language tag down to one we actually ship translations for.
    ///
    /// Three passes, strictest first: exact tag → primary subtag
    /// (`zh-Hant-TW` → `zh-Hans`, `pt-PT` → `pt-BR`; same language family beats
    /// dropping to English) → `fallback`.
    static func resolve(_ tag: String?) -> String {
        guard let raw = tag?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return fallback }
        if let exact = supported.first(where: { $0.tag.caseInsensitiveCompare(raw) == .orderedSame }) {
            return exact.tag
        }
        let primary = raw.split(separator: "-").first.map(String.init)
            ?? raw.split(separator: "_").first.map(String.init) ?? raw
        if let family = supported.first(where: {
            $0.tag.split(separator: "-").first.map(String.init)?
                .caseInsensitiveCompare(primary) == .orderedSame
        }) {
            return family.tag
        }
        return fallback
    }
}

// MARK: - Runtime language switching

/// Swaps the bundle `NSLocalizedString` reads from, so picking a language
/// re-renders the UI immediately instead of waiting for the next launch.
///
/// ## Why a Bundle subclass
///
/// The usual trick — writing `AppleLanguages` into `UserDefaults` — only takes
/// effect on the **next launch**, because `Bundle.main` resolves its
/// localization once at startup. Re-classing `Bundle.main` so
/// `localizedString(forKey:…)` forwards to the selected `.lproj` makes every
/// lookup honour the current choice.
///
/// This is also why every entry in `L10n` is a computed `static var` and not a
/// `static let`: `static let` is lazy-once, so any string read before the
/// switch would stay frozen in the old language for the rest of the process.
final class LocalizationService: ObservableObject {

    /// Currently selected tag; `nil` = follow the system (the default).
    @Published private(set) var selected: String?

    /// The language actually being rendered — what the picker ticks and what
    /// `Locale`/layout direction are derived from.
    var effective: String {
        AppLanguage.resolve(selected ?? Locale.preferredLanguages.first)
    }

    /// Arabic is the one RTL language we ship; SwiftUI won't flip on its own
    /// when the language comes from an overridden bundle rather than the system.
    var layoutDirection: LayoutDirection {
        effective.hasPrefix("ar") ? .rightToLeft : .leftToRight
    }

    init(selected: String?) {
        self.selected = selected
        Bundle.applyLanguage(selected)
    }

    func select(_ tag: String?) {
        guard tag != selected else { return }
        selected = tag
        Bundle.applyLanguage(tag)
    }
}

private var overrideBundle: Bundle?
private var didSwizzle = false

private final class LocalizedBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let override = overrideBundle else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }
        return override.localizedString(forKey: key, value: value, table: tableName)
    }
}

extension Bundle {
    /// Points `Bundle.main`'s string lookups at `tag`'s `.lproj`.
    /// `nil` restores normal system-language resolution — including Apple's own
    /// fallback to the development region (English) for languages we don't ship.
    static func applyLanguage(_ tag: String?) {
        if !didSwizzle {
            object_setClass(Bundle.main, LocalizedBundle.self)
            didSwizzle = true
        }
        guard let tag else {
            overrideBundle = nil
            return
        }
        let resolved = AppLanguage.resolve(tag)
        overrideBundle = Bundle.main.path(forResource: resolved, ofType: "lproj")
            .flatMap(Bundle.init(path:))
    }
}
