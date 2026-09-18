import SwiftUI

/// UI-language picker.
///
/// "Follow System" first (the default when nothing has been chosen), then every
/// language we ship, each shown under its own name. Picking one takes effect
/// immediately: `LocalizationService` swaps the string bundle and `RootView`
/// re-renders, no relaunch.
struct LanguagePickerView: View {
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var localization: LocalizationService

    /// The language actually rendering right now. A `config.json` written by a
    /// newer build (or hand-edited) can name a language this build doesn't
    /// ship; the UI is then English, so English is what gets the checkmark —
    /// ticking the unavailable language would claim something untrue.
    private var effective: String? {
        configService.config.appLanguage.map { AppLanguage.resolve($0) }
    }

    var body: some View {
        Form {
            Section {
                row(title: L10n.Language.followSystem, selected: effective == nil) {
                    choose(nil)
                }
                ForEach(AppLanguage.supported) { lang in
                    row(title: lang.autonym,
                        selected: effective?.caseInsensitiveCompare(lang.tag) == .orderedSame) {
                        choose(lang.tag)
                    }
                }
            } footer: {
                Text(L10n.Language.footer)
            }
        }
        .navigationTitle(L10n.Settings.language)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func choose(_ tag: String?) {
        guard tag != configService.config.appLanguage else { return }
        configService.config.appLanguage = tag
        // Write through immediately rather than on the usual debounce: this one
        // is worth a relaunch-safe save the moment it's tapped, and it's a
        // single tap, not a slider drag.
        configService.saveNow()
        localization.select(tag)
    }
}
