import SwiftUI
import UIKit

// MARK: - App-wide colour themes
//
// The app used to have exactly one identity colour (the `AccentColor` asset,
// brand red #E41D25) and every control, link and selection state borrowed it.
// The user's words: *"the app is white and pink and it looks washed out —
// give it a theme setting for the main colour"*.
//
// This file owns the **palettes**. It does not own the plumbing:
//
//   · `AppConfig.appTheme` stores the **bare tag** (same convention as
//     `appLanguage` / `watchFaceStyle`) — `AppConfig` is a pure disk schema and
//     must not link SwiftUI's `Color`;
//   · `RootView` reads the tag, resolves it, and applies `.tint(accent)` once at
//     the root. Everything downstream reacts because `Color.appAccent`
//     resolves through the same environment value that `.tint()` writes
//     (`EnvironmentValues.accentColor` is `tint` since iOS 16 — the old
//     `accentColor(_:)` modifier is just a deprecated spelling of it).
//
// ⚠️ The **launch screen** is `UILaunchScreen.UIColorName = AccentColor` in
// `project.yml`, so the asset colour cannot change at runtime. That is exactly
// why `crimson` stays the default: the system splash, the app icon and the
// first frame then all agree. Every other palette is opt-in.
//
// ⚠️ Never derive UI colours from `accentColor` where the meaning is *semantic*
// rather than *decorative* — the recording red dot, destructive actions,
// charging green. Those keep their fixed colours; a theme must not be able to
// turn "recording" into "not recording".

enum AppTheme: String, CaseIterable, Identifiable {

    /// Brand red. **Default**, and the only palette that matches the unchanged
    /// `AccentColor` asset (light `#E41D25`, dark `#FF6669`).
    case crimson
    /// Near-monochrome graphite. The "calm / premium" option — no hue at all.
    case graphite
    /// Deep blue.
    case ocean
    /// Forest green.
    case forest
    /// Violet.
    case violet
    /// Warm amber.
    case amber

    var id: String { rawValue }

    /// The tag written to `config.json`.
    var tag: String { rawValue }

    static let `default`: AppTheme = .crimson

    /// Unknown tags resolve to the default rather than breaking the UI — a
    /// `config.json` from a newer build (or hand-edited) must never leave the
    /// app with no tint at all.
    static func resolve(_ tag: String?) -> AppTheme {
        guard let tag, let theme = AppTheme(rawValue: tag) else { return .default }
        return theme
    }

    // MARK: Palette

    /// Primary accent: controls, links, selection, checkmarks.
    var accent: Color {
        switch self {
        case .crimson:  return .adaptive(light: 0xE41D25, dark: 0xFF6669)   // == AccentColor asset
        case .graphite: return .adaptive(light: 0x2C2C2E, dark: 0xE5E5EA)
        case .ocean:    return .adaptive(light: 0x0A63C9, dark: 0x58A6FF)
        case .forest:   return .adaptive(light: 0x14794C, dark: 0x45D08A)
        case .violet:   return .adaptive(light: 0x6437D6, dark: 0xB49BFF)
        case .amber:    return .adaptive(light: 0xA85A05, dark: 0xFFB454)
        }
    }

    /// A darker / more saturated companion for gradients and pressed states.
    /// Not used for text — contrast is not guaranteed on every background.
    var deep: Color {
        switch self {
        case .crimson:  return .adaptive(light: 0x9C0F16, dark: 0xC41E27)
        case .graphite: return .adaptive(light: 0x000000, dark: 0x8E8E93)
        case .ocean:    return .adaptive(light: 0x063E80, dark: 0x0A63C9)
        case .forest:   return .adaptive(light: 0x0A4E31, dark: 0x14794C)
        case .violet:   return .adaptive(light: 0x3F219B, dark: 0x6437D6)
        case .amber:    return .adaptive(light: 0x6E3A02, dark: 0xA85A05)
        }
    }

    /// Very low-opacity wash for selected cards / chips — replaces the many
    /// hand-written `.opacity(0.12)` / `0.16` constants so every palette stays
    /// balanced.
    var wash: Color { accent.opacity(0.14) }

    /// Gradient used by the picker previews and any hero surface.
    var gradient: LinearGradient {
        LinearGradient(colors: [accent, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Naming

    /// English fallback. `NSLocalizedString` returns it when a language has no
    /// key, which is the honest behaviour for the 8 languages we haven't
    /// translated this row into yet.
    var englishTitle: String {
        switch self {
        case .crimson:  return "Crimson"
        case .graphite: return "Graphite"
        case .ocean:    return "Ocean"
        case .forest:   return "Forest"
        case .violet:   return "Violet"
        case .amber:    return "Amber"
        }
    }

    var title: String {
        NSLocalizedString("theme.\(rawValue)", value: englishTitle, comment: "App theme name")
    }

    /// One line explaining what changes. Kept short on purpose — the swatch
    /// above it already shows the colour.
    var subtitle: String {
        NSLocalizedString("theme.\(rawValue).subtitle", value: englishSubtitle,
                          comment: "App theme description")
    }

    private var englishSubtitle: String {
        switch self {
        case .crimson:  return "Nomily's brand red"
        case .graphite: return "Neutral, no colour cast"
        case .ocean:    return "Cool and quiet"
        case .forest:   return "Grounded green"
        case .violet:   return "Soft but distinctive"
        case .amber:    return "Warm, low glare"
        }
    }
}

// MARK: - Current theme

/// Where the chosen palette is mirrored at runtime, so plain `Color.appAccent` reads work
/// without every view taking an environment dependency.
///
/// Why not just `.tint()` + `Color.appAccent`: `Color.appAccent` resolves **through the
/// environment**, and which key it reads (`tint` vs the older `accentColor`) has quietly moved
/// between iOS versions. Betting the whole feature on that is unnecessary — a one-word global
/// costs nothing and makes every decorative call site explicit. `ConfigService` is the only
/// writer; views must never assign here directly or they would drift from disk.
enum AppThemeRuntime {
    /// Mirrors `AppConfig.appTheme`. Set on load and on every change.
    static var tag: String?
}

extension Color {
    /// The active theme's accent.
    ///
    /// Use instead of `Color.appAccent` wherever the colour is **decorative** rather than
    /// attached to a control (which already gets its tint from the environment). Behaviour for
    /// an unset tag is the default palette, never transparent or nil.
    static var appAccent: Color { AppTheme.resolve(AppThemeRuntime.tag).accent }

    /// Low-opacity wash companion, see `AppTheme.wash`.
    static var appAccentWash: Color { AppTheme.resolve(AppThemeRuntime.tag).wash }
}

// MARK: - Hex → dynamic Color

extension Color {
    /// A colour that follows light/dark mode. Built on `UIColor`'s dynamic
    /// provider so it resolves correctly in any trait collection, including the
    /// ones SwiftUI builds for sheets and the widget-less watch previews.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    /// `0xRRGGBB`. Any alpha comes from the caller (these are all opaque).
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1
        )
    }
}
