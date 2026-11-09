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
    // The last one is the "can be added on" one.
    //
    // ★ 2026-11-03（用户："手表里面的回顾跟最近功能都是一样的" + "这个页面跟等待同步到
    // iPhone 页面重复了"）：删掉 `.queue` 与 `.recap` 两个菜单项——
    // · 「回顾」和首页第 2 页「最近」是同一份 `WatchRecapStore` 数据的两张皮，留一个（最近）；
    // · 「待传队列」和第 3 页「同步」重复，队列内容已并入同步页（列表），左上角待传胶囊
    //   也直跳同步页。旧值还留在 `UserDefaults` 里也没关系，`compactMap` 会把未知值丢掉。
    case about
    /// ★ 2026-11-03 八轮（用户："全天候录音要能监控 APP 的电量消耗，加在菜单栏里"）：
    /// 电量 / 耗电页。**默认不进菜单**（`defaultItems` 不含它），用户在手表「设置 →
    /// 快捷菜单」里勾上才出现——老用户的首页不该突然多一行。
    case battery
    /// ★ 2026-11-04（用户："需要在 Apple Watch 里面加入一个声纹，录制声纹说话"）：
    /// 声纹录制页。**放进默认菜单**——这是一个需要用户主动做一次的动作，
    /// 藏在"快捷菜单"设置里等于没人会做。
    case voiceprint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: return L10n.Watch.styleAppearance
        case .history:    return L10n.Watch.transferHistory
        case .language:   return L10n.Settings.language
        case .settings:   return L10n.Watch.menuSettings
        case .about:      return L10n.Settings.version
        case .battery:    return L10n.Watch.menuBattery
        case .voiceprint: return L10n.Voiceprint.title
        }
    }

    /// ★ 2026-11-03（V4 原型）：全部换成**描边版**（去掉 `.fill`）。
    ///
    /// 菜单页的材质改成了「发丝线行 + 1.5pt 描边图标」，和「最近 / 同步」两页同构。
    /// 实心图标在这套材质里像一颗颗按钮，会把行的"轻"全部压掉。
    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .history:    return "arrow.up.arrow.down.circle"
        case .language:   return "globe"
        case .settings:   return "gearshape"
        case .about:      return "info.circle"
        // 「电池 75%」的描边版，和上面四个同为 1.5pt 描边，不抢焦点。
        case .battery:    return "battery.75percent"
        case .voiceprint: return "person.wave.2"
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
        case .about:      return L10n.Watch.menuHintAbout
        case .battery:    return L10n.Watch.menuHintBattery
        case .voiceprint: return L10n.Watch.menuHintVoiceprint
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
        case .about:      WatchAboutView()
        case .battery:    WatchBatteryView()
        case .voiceprint: WatchVoiceprintView()
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
    static let defaultItems: [WatchHomeMenu] = [.appearance, .history, .language, .settings, .voiceprint]

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
