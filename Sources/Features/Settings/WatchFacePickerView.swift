import SwiftUI

/// Which expression the watch home face wears (Settings → Apple Watch → Home Face).
///
/// ★ added in 2026-10-16 revision thirteen (user: "the Nomily AI app's settings need one more
///    is a setting for the watch home screen's eye expressions, bringing the gork bot expressions from the earlier github into
///    the Nomily AI app's settings so their expressions can be used").
///
/// ## One row = one expression, and the left is what it **really** looks like
/// The left of each row isn't an icon or text but **a directly drawn pair of eyes** —
/// and it uses **exactly the same** drawing code as on the watch (`BotFacePair`).
///
/// ⚠️ This is the one thing on this page worth being strict about: an expression is something **you can't pin down by name**.
///    "Shy" and "Sad" both take a sentence to explain in Chinese, yet drawn out they're told apart at a glance.
///    More importantly, if the preview and the real hardware each drew their own, the user would pick a smiling eye on the phone
///    and find a droopy one on raising the wrist — so sharing the same code in one file across both sides isn't about saving effort,
///    it's a **correctness** requirement (the reasoning is at the top of `BotFaceStyle`).
///
/// ## Why the colour is the foreground colour, not the one on the watch
/// The watch's colour (the "Appearance" page) is a **watch-local** preference, and the phone doesn't know which one it picked
/// (that preference has never gone over WatchConnectivity). So this doesn't pretend to know —
/// it always draws with `.primary`. What's picked on this page is the **shape**; colour isn't changed here.
struct WatchFacePickerView: View {
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var watch: WatchSyncService

    /// The currently selected option. Never stored = `calm` (must match the watch side's default,
    /// otherwise what the phone shows and what the watch draws won't line up).
    private var chosen: BotFaceStyle {
        BotFaceStyle.decode(configService.config.watchFaceStyle) ?? .calm
    }

    var body: some View {
        Form {
            Section {
                ForEach(BotFaceStyle.allCases) { style in
                    row(style)
                }
            } footer: {
                Text(L10n.Face.footer)
            }
        }
        .navigationTitle(L10n.Face.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ style: BotFaceStyle) -> some View {
        Button {
            choose(style)
        } label: {
            HStack(spacing: 12) {
                // Preview. Given a fixed width, the nine rows of eyes all sit on the same vertical line —
                // if each row sized itself, `scan` (narrow) and `shy` (flat and wide) would make the text jump left and right.
                BotFacePair(style: style, size: Self.previewSize, tint: .primary)
                    .frame(width: Self.previewBoxWidth, alignment: .center)

                Text(style.title)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                if style == chosen {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(style == chosen ? [.isSelected] : [])
    }

    /// The nominal edge length of the preview face.
    ///
    /// ⚠️ This isn't the size on the watch (there it's 0.76 of the screen width, about 119pt on a 40mm).
    ///    What's taken here is the level that "fits in a phone row yet still shows the shape differences":
    ///    at 40pt the idle eyes are about 9.4 × 15pt, and the arc option's stroke width is about 3pt —
    ///    any smaller and you can't tell `listen` from `scan`.
    private static let previewSize: CGFloat = 40
    /// The width of the preview column. A little wider than the widest option (the eye cluster is about 40pt).
    private static let previewBoxWidth: CGFloat = 52

    private func choose(_ style: BotFaceStyle) {
        guard style != chosen else { return }
        configService.config.watchFaceStyle = style.rawValue
        // Writes to disk immediately rather than waiting for the usual debounced save: this is a single tap, not a slider drag;
        // and pushing to the watch **depends on** this value already being persisted (the watch may not wake for minutes).
        configService.saveNow()
        watch.sendFaceStyle(style.rawValue)
    }
}
