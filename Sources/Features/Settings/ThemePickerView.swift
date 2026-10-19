import SwiftUI

/// Colour-theme picker.
///
/// Each row paints its own **swatch** with the palette it offers, so the choice
/// is made by looking rather than by reading a colour name. Picking one writes
/// `config.json` immediately and the root `.tint()` re-renders — no relaunch,
/// and every control (toggles, links, selection, the recording pill's active
/// state) follows along.
struct ThemePickerView: View {
    @EnvironmentObject private var configService: ConfigService

    private var current: AppTheme {
        AppTheme.resolve(configService.config.appTheme)
    }

    var body: some View {
        Form {
            Section {
                ForEach(AppTheme.allCases) { theme in
                    row(theme, selected: theme == current) { choose(theme) }
                }
            } footer: {
                Text(L10n.Theme.footer)
            }
        }
        .navigationTitle(L10n.Settings.theme)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ theme: AppTheme, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                swatch(theme)
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.title)
                        .foregroundStyle(.primary)
                    Text(theme.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.accent)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The preview. Deliberately a **filled circle with a small control mock**
    /// rather than a bare colour chip: a flat square of pigment says nothing
    /// about how the colour behaves on a control, which is where the user will
    /// actually meet it.
    private func swatch(_ theme: AppTheme) -> some View {
        ZStack {
            Circle()
                .fill(theme.gradient)
                .frame(width: 34, height: 34)
            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: 16, height: 6)
        }
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    private func choose(_ theme: AppTheme) {
        guard theme.tag != configService.config.appTheme else { return }
        // One tap, and the whole app's chrome changes with it — worth writing
        // through instead of riding the debounce. `applyTheme` also mirrors the
        // tag into `AppThemeRuntime`, so `Color.appAccent` follows immediately.
        configService.applyTheme(theme.tag)
    }
}
