import SwiftUI

/// Which expression the watch home face wears (Settings → Apple Watch → Home Face).
///
/// ★ added in 2026-10-16 revision thirteen (user: "the Nomily AI app's settings need one more
///    is a setting for the watch home screen's eye expressions, bringing the gork bot expressions from the earlier github into
///    the Nomily AI app's settings so their expressions can be used").
///
/// ★ 2026-10-20 extended with three more settings (user: "more expressions, and let the phone
///    set its colour and blink pace, show the square frame, and let the face change on its own"):
///    auto-cycle toggle, blink pace, eye colour, square frame. All four ride the same
///    `updateApplicationContext` as the style (see `WatchSyncService.sendFaceSettings` — that
///    call *replaces* the whole context, so every push must carry all five keys).
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
/// ## Why the previews sit on a dark chip when a colour is picked
/// The watch home face is drawn on the watch's dark screen. In light phone mode the form row is
/// near-white, so a white/pale eye colour would be invisible right where the user is choosing it.
/// When a custom colour is in force the preview therefore gets a small dark chip behind it —
/// the closest a phone row gets to the real surface. No colour picked (`nil`) keeps the plain
/// foreground-colour preview, same as before.
struct WatchFacePickerView: View {
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var watch: WatchSyncService

    /// The currently selected option. Never stored = `calm` (must match the watch side's default,
    /// otherwise what the phone shows and what the watch draws won't line up).
    private var chosen: BotFaceStyle {
        BotFaceStyle.decode(configService.config.watchFaceStyle) ?? .calm
    }

    /// The eye colour in force. `nil` = "follow watch" (the watch's own Appearance pick).
    /// Only well-formed hex counts — a malformed stored value means "unset", never black.
    private var chosenColorHex: String? {
        Self.validHex(configService.config.watchEyeColor)
    }

    private var chosenBlink: BotBlinkSpeed {
        BotBlinkSpeed(rawValue: configService.config.watchBlinkSpeed ?? "") ?? .normal
    }

    var body: some View {
        Form {
            Section {
                ForEach(BotFaceStyle.allCases) { style in
                    row(style)
                }
            } header: {
                Text(L10n.Face.title)
            } footer: {
                Text(L10n.Face.footer)
            }

            Section {
                Toggle(L10n.Face.autoCycle, isOn: Binding(
                    get: { configService.config.watchFaceAutoCycle ?? true },
                    set: { configService.config.watchFaceAutoCycle = $0; persistAndPush() }
                ))
            } footer: {
                Text(L10n.Face.autoCycleFooter)
            }

            Section {
                Picker(L10n.Face.blinkSpeed, selection: Binding(
                    get: { chosenBlink },
                    set: { configService.config.watchBlinkSpeed = $0.rawValue; persistAndPush() }
                )) {
                    ForEach(BotBlinkSpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L10n.Face.blinkSpeed)
            }

            Section {
                colorSwatches
            } header: {
                Text(L10n.Face.eyeColor)
            }

            Section {
                Toggle(L10n.Face.frame, isOn: Binding(
                    get: { configService.config.watchFaceFrame ?? true },
                    set: { configService.config.watchFaceFrame = $0; persistAndPush() }
                ))
            } footer: {
                Text(L10n.Face.frameFooter)
            }
        }
        .navigationTitle(L10n.Face.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Expression row

    private func row(_ style: BotFaceStyle) -> some View {
        Button {
            choose(style)
        } label: {
            HStack(spacing: 12) {
                preview(style)

                Text(style.title)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                if style == chosen {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.appAccent)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(style == chosen ? [.isSelected] : [])
    }

    /// The drawn eyes, on a dark chip when a custom colour makes that necessary (see the header comment).
    @ViewBuilder
    private func preview(_ style: BotFaceStyle) -> some View {
        let tint = chosenColorHex.map { Color(botHex: $0) } ?? Color.primary
        if chosenColorHex != nil {
            BotFacePair(style: style, size: Self.previewSize, tint: tint)
                .frame(width: Self.previewBoxWidth, height: Self.previewBoxWidth, alignment: .center)
                .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            BotFacePair(style: style, size: Self.previewSize, tint: tint)
                .frame(width: Self.previewBoxWidth, alignment: .center)
        }
    }

    // MARK: - Colour swatches

    /// A fixed, friendly palette. These ride the wire as `RRGGBB` hex (no `#`),
    /// the same shape `WatchFaceStore.applySettings` validates on the watch side.
    private static let palette: [String] = [
        "FFFFFF", // white — the classic on the dark watch screen
        "E41D25", // brand red
        "FF7A45", // orange
        "FFD60A", // yellow
        "34C759", // green
        "00C7BE", // teal
        "0A84FF", // blue
        "5E5CE6", // indigo
        "BF5AF2", // purple
        "FF375F", // pink
    ]

    @ViewBuilder
    private var colorSwatches: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 10)], spacing: 12) {
            followWatchSwatch
            ForEach(Self.palette, id: \.self) { hex in
                colorSwatch(hex)
            }
        }
        .padding(.vertical, 4)
    }

    /// The "don't override the watch" option: a hollow, dashed circle.
    private var followWatchSwatch: some View {
        Button {
            configService.config.watchEyeColor = nil
            persistAndPush()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.swatchSize, height: Self.swatchSize)
                if chosenColorHex == nil {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Face.followWatch)
        .accessibilityAddTraits(chosenColorHex == nil ? [.isSelected] : [])
    }

    private func colorSwatch(_ hex: String) -> some View {
        let selected = chosenColorHex == hex
        return Button {
            configService.config.watchEyeColor = hex
            persistAndPush()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(botHex: hex))
                    .frame(width: Self.swatchSize, height: Self.swatchSize)
                if selected {
                    // The check rides on an outline so it stays visible on light AND dark swatches.
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.85), lineWidth: 2)
                        .frame(width: Self.swatchSize + 8, height: Self.swatchSize + 8)
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(white: 0.1).opacity(0.9))
                        .shadow(color: .white.opacity(0.9), radius: 1.2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(hex))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - Persist + push

    /// Every change on this page goes through here: write to disk **now** (a tap, not a drag —
    /// and pushing depends on the value being persisted, the watch may not wake for minutes),
    /// then push the **complete** five-key bundle (the context call replaces wholesale).
    private func persistAndPush() {
        configService.saveNow()
        watch.sendFaceSettings(
            style: chosen.rawValue,
            colorHex: chosenColorHex,
            blinkSpeed: chosenBlink.rawValue,
            autoCycle: configService.config.watchFaceAutoCycle ?? true,
            frameVisible: configService.config.watchFaceFrame ?? true
        )
    }

    private func choose(_ style: BotFaceStyle) {
        guard style != chosen else { return }
        configService.config.watchFaceStyle = style.rawValue
        persistAndPush()
    }

    private static func validHex(_ value: String?) -> String? {
        guard let value, isValidFaceHex(value) else { return nil }
        return value
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
    /// Diameter of one colour swatch.
    private static let swatchSize: CGFloat = 30
}
