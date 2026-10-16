import Foundation
import SwiftUI

// MARK: - 首页两侧的滑动菜单
//
// ★ 2026-10-16 七改（用户原话："4 个菜单需要往左或者往右滑在出现……然后需要在
// 手表的快捷录音的手表的菜单栏里面出现可以添加快捷的菜单设置，这个设置是在
// 手表的 wifi 那个菜单栏里面进行点击添加的组件"）：
//
// 这 4 项原来是**钉死在首页四角**的（`WatchRingCorner`，四个角各一个
// `NavigationLink`）。现在首页正中让给了 Bot，四项改成**横向分页的两侧菜单**：
// 往左滑、往右滑各出现一页，而且**放哪几项由用户自己勾**。
//
// ## 为什么把"哪几项"做成可配置
// 用户明确要"可以添加快捷的菜单设置"。所以可选清单从 4 项扩到 **6 项**
// （多了待传队列和版本）—— 只有"可选项比默认项多"，"添加"这个动作才真的有
// 东西可加；一个只能关不能开的开关列表不叫"添加"。
//
// ## 为什么存"哪些开着"而不是"顺序"
// 顺序永远按 `allCases` 走。让用户排顺序的话，取消勾选再勾回来就会跑到队尾，
// 菜单项会在左右两页之间乱跳，用户下次找同一个功能得重新找一遍。

/// 首页两侧滑动菜单里能放哪几页。
enum WatchHomeMenu: String, CaseIterable, Identifiable, Codable {
    // ⚠️ 声明顺序 = 分页顺序：前一半去左页，后一半去右页。
    // 前四项是原来那 4 个角标（默认开），保持"升级上来还是熟悉的四项"。
    case appearance
    case history
    case language
    case settings
    // 后两项是新增的"可以添加上去"的。
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

    /// 设置页里那一行底下的小字。一句话说清"点进去能看到什么"——
    /// 表上空间太小，光一个"外观"看不出是调什么。
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

    /// 这个菜单项通向哪一页。全都是**独立页面**（用户 2026-10-15 的要求：
    /// "4 个菜单点击应该是出独立一页"）。
    ///
    /// ⚠️ 语言页复用 `WatchLanguageView`（它同时兼着 `LocalizedWatchRoot`
    /// 的整树重建），不在这里另起一份。
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

/// 「首页两侧显示哪几个菜单」这一份偏好，存手表本地 `UserDefaults`。
///
/// 做法与 `WatchRingStyleStore` / `WatchRecordingPrefs` 同款：JSON 化、
/// 解不开就当没存过。**刻意独立第三份** —— 那两家的 `reset()` 分别是
/// "恢复默认外观"和"恢复默认录音方式"，把菜单布局也顺手重置掉会很意外。
final class WatchMenuPreferences: ObservableObject {
    static let shared = WatchMenuPreferences()

    private static let key = "watch.home_menu.v1"

    /// 默认就是原来那 4 个角标。**升级上来必须还是这四项** ——
    /// 老用户没去设置里动过，首页却少了两个入口，那是丢功能不是新功能。
    static let defaultItems: [WatchHomeMenu] = [.appearance, .history, .language, .settings]

    @Published var enabled: Set<WatchHomeMenu> {
        // `didSet` 在 init 期间不触发，所以构造时读盘不会反过来写盘。
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

    /// 当前开着的菜单项，**按 `allCases` 的顺序**。
    ///
    /// ⚠️ 不按用户点选的先后：见文件顶部那段 —— 顺序会跳。
    var ordered: [WatchHomeMenu] {
        WatchHomeMenu.allCases.filter { enabled.contains($0) }
    }

    /// 往右滑出现的那一页（左页）。
    ///
    /// 只有一项时**全放左边**：右边留一页空白页，用户滑过去会以为坏了。
    var leadingItems: [WatchHomeMenu] {
        let all = ordered
        guard all.count > 1 else { return all }
        return Array(all.prefix((all.count + 1) / 2))
    }

    /// 往左滑出现的那一页（右页）。
    var trailingItems: [WatchHomeMenu] {
        let all = ordered
        guard all.count > 1 else { return [] }
        return Array(all.suffix(from: (all.count + 1) / 2))
    }

    /// 首页中间那一页是不是唯一的（= 两侧都没菜单）。
    ///
    /// 用来决定要不要提示"去设置里添加快捷菜单"—— 全关掉之后首页会变成
    /// 一个孤零零的 Bot，不说明一句用户会以为菜单被删了。
    var isEmpty: Bool { ordered.isEmpty }

    func isOn(_ item: WatchHomeMenu) -> Bool { enabled.contains(item) }

    func set(_ item: WatchHomeMenu, on: Bool) {
        if on {
            enabled.insert(item)
        } else {
            enabled.remove(item)
        }
    }

    /// 只重置**菜单布局**，不碰外观、不碰录音方式（见类型顶部那段）。
    func reset() { enabled = Set(Self.defaultItems) }

    private func persist() {
        // 存 rawValue 数组而不是 `Set` 本身：`Set` 的 JSON 表现是未排序的，
        // 虽然这里读回来还会按 `allCases` 排，但落盘的东西保持可读、
        // 可人工核对 —— 排查"我的菜单呢"这类问题时值这几十个字节。
        defaults.set(ordered.map(\.rawValue), forKey: Self.key)
    }
}
