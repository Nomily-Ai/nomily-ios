import SwiftUI

// MARK: - The watch ring "appearance"
//
// ## Why a **watch-local** preference rather than config synced with the iPhone
// The user's own words: "adjust it directly on the watch, takes effect immediately" (confirmed 2026-10-15). So it lives in the watch's
// own `UserDefaults`:
//   · changing a color on the watch face should not cost a WatchConnectivity round trip;
//   · it must work even when the iPhone is not nearby;
//   · it is purely "what my watch looks like" and unrelated to recording data -- putting it in `AppConfig` would only add one more dimension on which
//     the two sides' configs can drift apart.
//
// ## Three dimensions: color / gradient / breathing -- deliberately not subdivided further
// These are the three items the user asked for by name. No color wheel, brightness or gradient angle: on a 40mm face they are neither tappable precisely
// nor visibly different, which would only turn "can change" into "changed it wrong".
//
// ## ⚠️ Only swap the **color choice and the center disc**; never touch the animation semantics
// `WatchRingControl`'s "outer ring one turn per minute / inner ring one turn per hour / comet one turn per 2.4 s"
// carry the "is it still recording?" information (see the top of that file). Skins must not alter them --
// they are not styling, they are function.

/// Which color set the center disc (and the ring while recording) uses.
enum WatchRingPalette: String, CaseIterable, Identifiable, Codable {
    /// The three colours of the Health app activity rings (magenta / neon green / cyan).
    /// **The default** — on 2026-10-15 the user brought a screenshot of the activity rings and called it out: "reference this colour scheme".
    case activity
    case green, teal, blue, indigo, purple, pink, orange, red, graphite

    var id: String { rawValue }

    /// The gradient's endpoint colours; solid mode takes only `[0]`, and three or more colours spread around the ring (see `ringGradient`).
    ///
    /// ⚠️ Single/double-colour palettes are all **dark** (not light): the centre icon and timer are white text,
    /// and a light base colour would smear the "stop" icon into a blob while recording. `activity` is the exception — it uses
    /// three-colour ring spreading with the centre taking only the first and last colours (see `centerFill`), brightness carried by the gradient.
    var colors: [Color] {
        switch self {
        case .activity: return [
            // Apple's three activity-ring primaries: Move magenta / Exercise neon green / Stand cyan.
            Color(red: 0.98, green: 0.07, blue: 0.31),
            Color(red: 0.57, green: 0.91, blue: 0.16),
            Color(red: 0.10, green: 0.88, blue: 1.00),
        ]
        case .green:    return [Color(red: 0.24, green: 0.78, blue: 0.38), Color(red: 0.05, green: 0.48, blue: 0.24)]
        case .teal:     return [Color(red: 0.20, green: 0.76, blue: 0.72), Color(red: 0.02, green: 0.42, blue: 0.46)]
        case .blue:     return [Color(red: 0.26, green: 0.56, blue: 0.94), Color(red: 0.04, green: 0.26, blue: 0.68)]
        case .indigo:   return [Color(red: 0.38, green: 0.42, blue: 0.90), Color(red: 0.18, green: 0.15, blue: 0.60)]
        case .purple:   return [Color(red: 0.62, green: 0.36, blue: 0.88), Color(red: 0.38, green: 0.12, blue: 0.58)]
        case .pink:     return [Color(red: 0.86, green: 0.32, blue: 0.56), Color(red: 0.62, green: 0.06, blue: 0.30)]
        case .orange:   return [Color(red: 0.90, green: 0.52, blue: 0.16), Color(red: 0.70, green: 0.24, blue: 0.02)]
        case .red:      return [Color(red: 0.86, green: 0.26, blue: 0.24), Color(red: 0.62, green: 0.04, blue: 0.10)]
        case .graphite: return [Color(white: 0.52), Color(white: 0.26)]
        }
    }

    /// Solid color (used when "gradient" is off).
    var solid: Color { colors[0] }

    /// Colour of the inner ring (the hour ring); `nil` = keep the main colour `solid`.
    ///
    /// Only the three-colour palette (`activity`) specifies it — it takes the middle neon green, exactly reproducing the activity ring's
    /// "outer magenta / middle neon green / inner cyan" layering. Double-colour gradient palettes **must not** do that:
    /// their `[1]` is the gradient's dark end, and using it to draw a ring would go black on a black background.
    var lapColor: Color? {
        colors.count > 2 ? colors[1] : nil
    }
}

/// The "breathing light" rhythm. `period` = seconds for one full inhale-exhale cycle.
enum WatchBreathing: String, CaseIterable, Identifiable, Codable {
    case off, slow, medium, fast

    var id: String { rawValue }

    var period: Double? {
        switch self {
        case .off:    return nil
        case .slow:   return 3.4
        case .medium: return 2.2
        case .fast:   return 1.2
        }
    }

    var label: String {
        switch self {
        case .off:    return L10n.Watch.styleBreathingOff
        case .slow:   return L10n.Watch.styleBreathingSlow
        case .medium: return L10n.Watch.styleBreathingMedium
        case .fast:   return L10n.Watch.styleBreathingFast
        }
    }
}

/// A persistable appearance.
///
/// ★ Ninth revision, 2026-10-16: **the "gradient" dimension was removed** (user: "remove the gradient").
///
/// The original three dimensions were colour / gradient / breathing light, where "gradient" governed "whether the centre disc is filled with a solid colour or
/// a two-colour linear gradient". It was deleted entirely because there's hardly anything left for it to govern:
///   · the home screen face lost its base plate in the eighth revision, and in the ninth the eyes take only a **solid colour**;
///   · nothing in any UI uses `WatchRingControl`'s ring now (see the top of that file);
///   · the only visible use left is the small preview on the appearance page — not worth keeping a switch for one preview.
///
/// ⚠️ Deleting a property **does not** make old saves undecodable: Swift's synthesised `init(from:)` ignores
///    extra keys in the JSON, so old data holding `"gradient": true` still reads the other two items fine.
///    That's exactly why it's safe to delete outright here instead of leaving a `deprecated` shell.
struct WatchRingStyle: Equatable, Codable {
    /// Defaults to the Health ring's three colours (see `WatchRingPalette.activity`).
    var palette: WatchRingPalette = .activity
    var breathing: WatchBreathing = .off

    static let `default` = WatchRingStyle()

    /// **The one** colour of this theme.
    ///
    /// ★ After the ninth revision "a theme has exactly one colour" is a settled conclusion, no longer "pick an endpoint from three colours":
    /// it is used for the home screen eyes, the waveform while recording, the side-menu icons, and the recording timer line.
    /// Funnelling it into this one property means there can no longer be cases of "one place uses `colors[0]`, another uses
    /// `colors[1]`", where one theme has several colours (that drift is exactly why in the last round
    /// the user saw a green menu icon while the face was another colour).
    var tint: Color { palette.solid }

    /// Fill of the center disc.
    ///
    /// ⚠️ It now always equals `tint`. Why it isn't deleted so callers can just use `tint`:
    ///    both `WatchRingControl` and the appearance-page preview use it with the semantics of "the centre disc",
    ///    so if the centre ever really gets a different way of being drawn, one place is enough to change.
    var centerFill: Color { tint }

    /// The ring's colour.
    ///
    /// ⚠️ What comes back is still an `AngularGradient` rather than a `Color`: the only caller is
    ///    `.stroke(_:style:)`, and a solid colour would lose the "a touch of opacity at each end" layer of same-hue shading
    ///    altogether. That isn't a gradient, it's a sense of depth.
    ///
    /// ⚠️ There used to be a branch here for "the three-colour palette spreading three colours around the ring" (that was the activity-ring look).
    ///    With the gradient removed it's useless — spreading three colours is itself a kind of gradient.
    var ringAngularGradient: AngularGradient {
        let c = tint
        return AngularGradient(
            colors: [c.opacity(0.55), c, c, c.opacity(0.75)],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }
}

// MARK: - Menu item definitions moved to `WatchMenuPreferences.swift`
//
// ★ Seventh revision, 2026-10-16: the `WatchRingCorner` that used to be here (four corner dots, each leading to a page)
// moved out along with the home screen redesign — the four items are no longer pinned to the four corners but became **side menus
// that appear on a left/right swipe**, and the user ticks which items go in. The new definition is `WatchHomeMenu`, see
// `WatchMenuPreferences.swift`。
//
// Why leave no `typealias` for compatibility: there is no external caller at all (this enum is used only inside this target),
// and an alias layer would only give "how many kinds of menu item are there" two answers.

/// Stored in the watch-local `UserDefaults`. Same approach as `RecorderAliasStore`:
/// JSON + a rebuildable cache; if it cannot be decoded, treat it as never saved (a preference is not worth raising an error for,
/// and must never wipe anything else that was stored along the way).
///
/// ⚠️ Deliberately **not** marked `@MainActor`: the read entry point is SwiftUI's `body`,
/// the same trade-off as `RecorderAliasStore` (see the paragraph at the top of that file). All writes originate from
/// UI actions, so in practice they only run on the main thread.
final class WatchRingStyleStore: ObservableObject {
    static let shared = WatchRingStyleStore()

    private static let storageKey = "watch.ring_style.v1"

    @Published var style: WatchRingStyle {
        // `didSet` does not fire during init, so reading from disk at construction never writes back.
        didSet { persist() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.style = Self.load(from: defaults)
    }

    func reset() { style = .default }

    private static func load(from defaults: UserDefaults) -> WatchRingStyle {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(WatchRingStyle.self, from: data)
        else { return .default }
        return decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(style) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
