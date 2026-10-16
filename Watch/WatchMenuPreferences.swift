import Foundation
import SwiftUI

// MARK: - The side swipe menus on the home screen
//
// ★ 2026-10-16 revision seven (user's words: "the four menus should appear by swiping left or right ... and then
// the watch menu bar for quick recording should offer a setting to add a shortcut, and that setting is
// the component added by tapping in the watch's Wi-Fi menu bar"):
//
// These 4 items used to be **pinned to the four corners of the home screen** (`WatchRingCorner`, one
// `NavigationLink` per corner). Now the centre of the home screen is given to the Bot, and the four become **two side menus with horizontal paging**:
// swiping left and right each reveals a page, and **which items go there is ticked by the user**.
//
// ## Why "which items" is made configurable
// The user explicitly asked for "menu settings you can add to". So the option list grew from 4 to **6**
// (adding the pending-transfer queue and version) — only when "there are more options than defaults" is there really
// something to add; a toggle list you can only turn off isn't "adding".
//
// ## Why store "which are on" rather than "the order"
// The order always follows `allCases`. If the user arranged the order, unticking then re-ticking would send an item to the back,
// menu items would jump around between the left and right pages, and the user would have to hunt for the same feature again.

/// Which pages can go in the home screen's side swipe menus.
enum WatchHomeMenu: String, CaseIterable, Identifiable, Codable {
    // ⚠️ Declaration order = paging order: the first half goes to the left page, the second half to the right.
    // The first four are the original 4 corner dots (on by default), keeping "upgrading still leaves the familiar four".
    case appearance
    case history
    case language
    case settings
    // The last two are the new "can be added on" ones.
    case queue
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return L10n.Watch.styleAppearance
        case .history:    return L10n.Watch.transferHistory
        case .language:   return L10n.Settings.language
        case .settings:   return L10n.Watch.menuSettings
        case .queue:      return L10n.Watch.pendingHeader
        case .about:      return L10n.Settings.version
        }
    }

    var symbol: String {
        switch self {
        case .appearance: return "paintpalette.fill"
        case .history:    return "arrow.up.arrow.down.circle.fill"
        case .language:   return "globe"
        case .settings:   return "gearshape.fill"
        case .queue:      return "tray.full.fill"
        case .about:      return "info.circle.fill"
        }
    }

    /// The small print under that row on the settings page. One sentence to make clear "what you'll see when you tap in" —
    /// space on the watch is too tight, and a bare "Appearance" doesn't show what it adjusts.
    var subtitle: String {
        switch self {
        case .appearance: return L10n.Watch.menuHintAppearance
        case .history:    return L10n.Watch.menuHintHistory
        case .language:   return L10n.Watch.menuHintLanguage
        case .settings:   return L10n.Watch.menuHintSettings
        case .queue:      return L10n.Watch.menuHintQueue
        case .about:      return L10n.Watch.menuHintAbout
        }
    }

    /// Which page this menu item leads to. All of them are **standalone pages** (the user's 2026-10-15 request:
    /// "tapping the four menus should open a page of their own").
    ///
    /// ⚠️ The language page reuses `WatchLanguageView` (which also doubles as the whole-tree
    /// rebuild of `LocalizedWatchRoot`), rather than starting another copy here.
    @ViewBuilder
    var destination: some View {
        switch self {
        case .appearance: WatchColorStyleView()
        case .history:    WatchTransferHistoryView()
        case .language:   WatchLanguageView()
        case .settings:   WatchSettingsView()
        case .queue:      WatchQueueView()
        case .about:      WatchAboutView()
        }
    }
}

/// The "which menus show on the home screen's two sides" preference, stored in the watch's local `UserDefaults`.
///
/// Same approach as `WatchRingStyleStore` / `WatchRecordingPrefs`: JSON-encode it,
/// and treat it as never stored if it won't decode. **Deliberately a separate third store** — those two's `reset()` are
/// "restore default appearance" and "restore default recording method", and resetting the menu layout too would be surprising.
final class WatchMenuPreferences: ObservableObject {
    static let shared = WatchMenuPreferences()

    private static let key = "watch.home_menu.v1"

    /// Defaults to the original 4 corner dots. **Upgrading must still leave these four** —
    /// if an existing user never touched the settings yet the home screen lost two entries, that's losing a feature, not gaining one.
    static let defaultItems: [WatchHomeMenu] = [.appearance, .history, .language, .settings]

    @Published var enabled: Set<WatchHomeMenu> {
        // `didSet` doesn't fire during init, so reading from disk in the initialiser won't write back to disk.
        didSet { persist() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.array(forKey: Self.key) as? [String] {
            self.enabled = Set(raw.compactMap(WatchHomeMenu.init(rawValue:)))
        } else {
            self.enabled = Set(Self.defaultItems)
        }
    }

    /// The currently on menu items, **in `allCases` order**.
    ///
    /// ⚠️ Not in the order the user ticked them: see the block at the top of the file — the order would jump.
    var ordered: [WatchHomeMenu] {
        WatchHomeMenu.allCases.filter { enabled.contains($0) }
    }

    /// The page that appears when swiping right (the left page).
    ///
    /// When there's only one item **it all goes left**: leaving a blank page on the right would make the user think it's broken when they swipe over.
    var leadingItems: [WatchHomeMenu] {
        let all = ordered
        guard all.count > 1 else { return all }
        return Array(all.prefix((all.count + 1) / 2))
    }

    /// The page that appears when swiping left (the right page).
    var trailingItems: [WatchHomeMenu] {
        let all = ordered
        guard all.count > 1 else { return [] }
        return Array(all.suffix(from: (all.count + 1) / 2))
    }

    /// Whether the middle page of the home screen is the only one (= no menus on either side).
    ///
    /// Used to decide whether to hint "go add shortcut menus in Settings" — turn them all off and the home screen becomes
    /// a lone Bot, and without a word the user would think the menus were deleted.
    var isEmpty: Bool { ordered.isEmpty }

    func isOn(_ item: WatchHomeMenu) -> Bool { enabled.contains(item) }

    func set(_ item: WatchHomeMenu, on: Bool) {
        if on {
            enabled.insert(item)
        } else {
            enabled.remove(item)
        }
    }

    /// Only resets the **menu layout**, not appearance, not recording method (see the block at the top of the type).
    func reset() { enabled = Set(Self.defaultItems) }

    private func persist() {
        // Stores an array of rawValues rather than the `Set` itself: a `Set`'s JSON representation is unordered,
        // and although reading back here re-sorts by `allCases`, keeping what's persisted readable
        // and human-checkable is worth those few dozen bytes when chasing a "where are my menus" kind of problem.
        defaults.set(ordered.map(\.rawValue), forKey: Self.key)
    }
}
