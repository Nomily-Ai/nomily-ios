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
struct WatchRingStyle: Equatable, Codable {
    /// Defaults to the Health ring's three colours (see `WatchRingPalette.activity`).
    var palette: WatchRingPalette = .activity
    /// Whether the center uses a gradient (off = solid color).
    var gradient: Bool = true
    var breathing: WatchBreathing = .off

    static let `default` = WatchRingStyle()

    /// Fill of the center disc.
    ///
    /// The three-colour palette uses only the **first and last colours**: squeezing a three-stop linear gradient into that small centre disc looks muddy,
    /// and the diagonal magenta→cyan gradient is the clean look "the centre of an activity ring" should have.
    var centerFill: AnyShapeStyle {
        let cs = palette.colors
        let pair = cs.count > 2 ? [cs[0], cs[cs.count - 1]] : cs
        return gradient
            ? AnyShapeStyle(
                LinearGradient(
                    colors: pair,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            : AnyShapeStyle(palette.solid)
    }

    /// Ring color while recording. Supplies the `AngularGradient` when gradient is on.
    var ringColors: [Color] { gradient ? palette.colors : [palette.solid] }

    /// The ring's colour gradient.
    ///
    /// ⚠️ `WatchRingControl`'s main ring and the colour page's small preview **share this one copy** —
    /// write it twice and they'll drift; and the subscript out-of-bounds trap is worth guarding exactly once, here.
    ///
    /// * Three colours or more (`activity`): spread the three colours around one lap of the ring — that's the activity ring's
    ///   "three colours readable in one lap" look;
    /// * Single/double colour: first colour + end colour + each end's own reduced opacity; with a single colour it degrades to
    ///   "same colour at both ends", equivalent to the original solid look.
    ///
    /// Deliberately **not** indexing `ringColors[1]`: with the gradient off the array has one element,
    /// and the subscript would go straight out of bounds.
    var ringAngularGradient: AngularGradient {
        let colors = ringColors
        if colors.count > 2 {
            return AngularGradient(
                colors: colors,
                center: .center,
                startAngle: .degrees(-90),
                endAngle: .degrees(270)
            )
        }
        let from = colors.first ?? palette.solid
        let to = colors.count > 1 ? colors[1] : from
        return AngularGradient(
            colors: [from.opacity(0.55), from, to, to.opacity(0.75)],
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
