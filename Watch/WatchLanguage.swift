import SwiftUI

/// Wrist-side UI language, stored on the watch itself.
///
/// The iPhone picker (`LanguagePickerView`) writes into the phone's
/// `config.json`, and none of that crosses the WatchConnectivity link — clips
/// go one way, a store-confirmation comes back (see `WatchLink`). So the wrist
/// keeps its own choice here: `nil` means "follow the watch's system language",
/// which is exactly what the app did before this setting existed.
///
/// The *tag* is what gets stored, never the resolved language: a tag this build
/// doesn't ship still has to survive a round trip, or picking it away and back
/// again would quietly lose the user's choice.
@MainActor
final class WatchLanguageStore: ObservableObject {

    /// Deliberately plain `UserDefaults` — the watch app has no App Group (see
    /// the long note in `project.yml`) and this value belongs to the wrist
    /// alone, so there is nothing to share it with.
    private static let defaultsKey = "nomily.watch.language"

    /// `nil` = follow the watch's system language.
    @Published private(set) var selected: String?

    /// What is actually rendering — resolved, and derived rather than stored.
    /// Used for `Locale` and layout direction, which have to be concrete even
    /// while we're following the system.
    var effective: String {
        AppLanguage.resolve(selected ?? Locale.preferredLanguages.first)
    }

    /// Arabic is the one RTL language we ship, and SwiftUI won't flip on its
    /// own when the language comes from our swapped bundle rather than from the
    /// system.
    var layoutDirection: LayoutDirection {
        effective.hasPrefix("ar") ? .rightToLeft : .leftToRight
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.defaultsKey)
        selected = stored
        // Applied before the first frame: everything below reads `L10n`, which
        // goes through `Bundle.main`.
        Bundle.applyLanguage(stored)
        // ★ 2026-10-16 十三改：**两个半边都要拨**。`Bundle` 管字符串，
        //   `Locale` 管日期/数字 —— 只拨前者的表现是"界面英文、传输记录里
        //   的时间还是中文"（手机那边同款问题，见 `AppLocale` 顶部那段）。
        AppLocale.set(stored)
    }

    func select(_ tag: String?) {
        guard tag != selected else { return }
        selected = tag
        if let tag {
            defaults.set(tag, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
        Bundle.applyLanguage(tag)
        AppLocale.set(tag)
    }
}

/// The wrist's language list.
///
/// Same rows, same order, same "Follow System" first as the iPhone's
/// `LanguagePickerView`, so the two can never disagree about what the choices
/// are. Autonyms are never translated — someone opens this screen precisely
/// because they can't read the current UI.
struct WatchLanguageView: View {
    @EnvironmentObject private var language: WatchLanguageStore

    /// `nil` while following the system, so "Follow System" takes the
    /// checkmark rather than whichever language the system happens to resolve
    /// to — ticking that one would claim a choice the user never made.
    private var chosen: String? {
        language.selected.map { AppLanguage.resolve($0) }
    }

    var body: some View {
        List {
            row(title: L10n.Language.followSystem, selected: chosen == nil) {
                language.select(nil)
            }
            ForEach(AppLanguage.supported) { lang in
                row(title: lang.autonym,
                    selected: chosen?.caseInsensitiveCompare(lang.tag) == .orderedSame) {
                    language.select(lang.tag)
                }
            }
        }
        .navigationTitle(L10n.Settings.language)
    }

    private func row(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Re-renders the whole wrist UI when the language changes.
///
/// Same reason as the iPhone's `LocalizedRoot`: `L10n` reads are plain function
/// calls, so a view that doesn't observe the store has no reason to re-evaluate
/// its body and would keep showing the old language. The `.id` forces a fresh
/// subtree — which also lands the user back on the recorder page, so they see
/// the new language applied rather than a list that just re-labelled itself.
struct LocalizedWatchRoot: View {
    @EnvironmentObject private var language: WatchLanguageStore

    var body: some View {
        NavigationStack {
            WatchRecorderView()
        }
        // Numbers, dates and RTL follow the chosen language too — otherwise
        // Arabic text would render in a left-to-right layout.
        .environment(\.locale, Locale(identifier: language.effective))
        .environment(\.layoutDirection, language.layoutDirection)
        .id(language.selected ?? "system")
    }
}
