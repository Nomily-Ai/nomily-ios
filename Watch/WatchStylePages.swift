import SwiftUI

// MARK: - Standalone pages reached from the corner badges
//
// ★ Second revision, 2026-10-15: these four pages used to be "a small menu expanded in place on the home screen", which the user
// explicitly rejected — "tapping the 4 menus should open a separate page". After switching to pages:
//
//   · The home screen is cleared out, leaving only "time + ring + 4 corner badges" — the same structure as the Health app's
//     Activity rings page (the user's words were "just follow the Apple Health layout");
//   · The **gradient**, which used to occupy a corner badge of its own, merged into the color page — a gradient was always about "how color is used",
//     and shouldn't sit beside color holding its own slot;
//   · The **language** text link that used to hang at the bottom of the home screen moved in, taking the vacated corner badge;
//   · **Version + restore defaults** merged into a "Settings" page — both are low-frequency actions touched only occasionally.
//
// The language page reuses `WatchLanguageView` (which also handles rebuilding `LocalizedWatchRoot`),
// rather than duplicating it here.

// MARK: - Color (with gradient)

/// Color page: palette + gradient toggle.
///
/// A small ring preview at the top. **Deliberately not `WatchRingControl`** — that's a button,
/// with comet, ripples, and a timer, and tapping it starts a recording; here we only want to "glance at whether the colors look right".
struct WatchColorStyleView: View {
    @ObservedObject private var store = WatchRingStyleStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                WatchRingPreview(style: store.style)
                    .frame(width: 68, height: 68)
                    .accessibilityHidden(true)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                    spacing: 8
                ) {
                    ForEach(WatchRingPalette.allCases) { palette in
                        Button {
                            store.style.palette = palette
                        } label: {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: palette.colors,
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle().strokeBorder(
                                        Color.white,
                                        lineWidth: store.style.palette == palette ? 2 : 0
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(palette.rawValue)
                    }
                }

                // The merged-in "gradient". Two equal-width capsules, keeping one row style with the breathing-light page.
                HStack(spacing: 4) {
                    ForEach([false, true], id: \.self) { on in
                        Button {
                            store.style.gradient = on
                        } label: {
                            Text(on ? L10n.Watch.styleGradientOn : L10n.Watch.styleGradientOff)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(
                                    Capsule().fill(
                                        store.style.gradient == on
                                            ? store.style.palette.solid.opacity(0.9)
                                            : Color.white.opacity(0.12)
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(L10n.Watch.styleColor)
    }
}

// MARK: - Breathing light

/// Breathing light page: off / slow / medium / fast.
///
/// Uses `List` + checkmarks, cast from the same mold as the language page — on the watch face, "list + checkmark" is the choice control
/// that needs the least relearning.
struct WatchBreathingStyleView: View {
    @ObservedObject private var store = WatchRingStyleStore.shared

    var body: some View {
        List {
            ForEach(WatchBreathing.allCases) { option in
                Button {
                    store.style.breathing = option
                } label: {
                    HStack {
                        Text(option.label)
                        Spacer(minLength: 4)
                        if store.style.breathing == option {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(store.style.palette.solid)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(L10n.Watch.styleBreathing)
    }
}

// MARK: - Settings

/// Settings page: version + restore default appearance.
///
/// The build number still doubles as "did the build I just made actually reach the watch" — watch updates are pushed opportunistically by the iPhone,
/// lagging the iPhone's install by several minutes (see the note at the top of `WatchAboutView`).
struct WatchSettingsView: View {
    @ObservedObject private var store = WatchRingStyleStore.shared

    var body: some View {
        List {
            HStack {
                Text(L10n.Settings.version)
                Spacer(minLength: 4)
                Text(WatchAboutView.appVersion)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button {
                store.reset()
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text(L10n.Watch.styleReset)
                }
                .foregroundStyle(store.style.palette.solid)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Resets only the appearance (color / gradient / breathing light), leaving language and recordings untouched —
            // so no confirmation is needed; picking the wrong color again is easy enough.
        }
        .navigationTitle(L10n.Watch.menuSettings)
    }
}

// MARK: - Preview

/// The small ring preview at the top of the color page: the outer ring takes the current gradient colors, the center the current fill.
///
/// Shares `WatchRingStyle.ringAngularGradient` with the main ring — writing the color logic twice
/// would eventually drift (especially the three-color palette and "gradient off" branches).
private struct WatchRingPreview: View {
    let style: WatchRingStyle

    var body: some View {
        ZStack {
            Circle()
                .inset(by: 5)
                .stroke(style.ringAngularGradient,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))

            Circle()
                .inset(by: 17)
                .fill(Color(white: 0.10))

            Circle()
                .inset(by: 17)
                .fill(style.centerFill)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
