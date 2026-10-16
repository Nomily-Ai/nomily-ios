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

/// 中心那块（以及录音态下的环）用哪一套颜色。
///
/// ★ 2026-10-16 十二改：补上**白色**（用户："当前颜色里面呢没有白色吗手表"）。
/// 这是这个枚举第一次出现"必须在别处配套改"的颜色 —— 白底白字、白块白框
/// 两处都得跟着反色，见 `onSolid` / `selectionRing`。
/// ⚠️ 存档兼容：`rawValue` 枚举 + `Codable`。**加 case 是安全的** —— 老存档里
///    存的是 "green" 这类仍然存在的字符串，多出来一个 `white` 不影响解码。
///    （反向不安全：存了 white 之后回退到旧版本，旧版本解不出这个字符串，
///    整份外观会退回默认 —— 只有降级才会遇到，不为它写迁移。）
enum WatchRingPalette: String, CaseIterable, Identifiable, Codable {
    /// 健康 App 活动圆环三色（品红 / 荧光绿 / 青）。
    /// **默认** —— 用户 2026-10-15 拿着活动圆环的截图点名"参考这种配色"。
    case activity
    case green, teal, blue, indigo, purple, pink, orange, red, graphite
    /// ★ 十二改新增（用户："当前颜色里面呢没有白色吗手表"）。
    ///
    /// 放在**最后**：它是唯一一个"无彩色但又不是黑"的选项，和 `graphite` 挨着
    /// 正好构成一条灰阶（灰 → 白）。插到彩色轮中间会把"activity 之后是一排色相"
    /// 这个顺序打乱。
    ///
    /// ⚠️ 白色是这一套里唯一会把两处 UI 变成"白底白字"的颜色，
    ///    所以它必须同时看 `onSolid` 与 `selectionRing` 两个属性 ——
    ///    加颜色**不是**往这个枚举里塞一个 case 就完事。
    case white

    var id: String { rawValue }

    /// 渐变的端点色；纯色模式只取 `[0]`，三色及以上沿环铺开（见 `ringGradient`）。
    ///
    /// ⚠️ 单/双色盘选的都是**深色**（不是浅色）：画在这个颜色**上面**的图标和
    /// 文字默认是白的，浅底色会让它们糊成一团（`onSolid` 说的就是这件事）。
    /// `activity` 是例外 —— 它走三色环铺色，中心只取首尾两色（见 `centerFill`），
    /// 亮度由渐变兜着；`white` 是另一个例外，它靠 `onSolid` 反色解决。
    var colors: [Color] {
        switch self {
        case .activity: return [
            // Apple 活动圆环三原色：Move 品红 / Exercise 荧光绿 / Stand 青。
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
        // ★ 十二改：纯白。`[0]` 就是 `Color(white: 1)` —— 它在黑表盘上是最亮的
        // 那只眼睛，也是唯一一个"中心图标和计时本来就会糊掉"的反例
        // （见下面 `onSolid`）。
        case .white:    return [Color(white: 1.00), Color(white: 0.86)]
        }
    }

    /// Solid color (used when "gradient" is off).
    var solid: Color { colors[0] }

    /// 画在 `solid` **上面**的文字/图标该用什么颜色。
    ///
    /// ★ 十二改新增。加白色之前这个位置上一直"默认就是白色"（watchOS 上
    ///    `Text` 的默认色），因为其余十种盘都够深，白字压得住。白色一进来这条
    ///    隐式约定当场失效 —— 外观页那颗选中的胶囊会变成**白底白字**。
    ///
    /// ⚠️ 判据是"这个颜色亮不亮"，不是"它是不是白"。现在只有 `.white` 亮到需要
    ///    反色；以后再加浅色（浅黄、浅青之类）时，这里就该长出第二个分支，
    ///    而不是去改调用方。
    var onSolid: Color {
        switch self {
        case .white: return .black
        default:     return .white
        }
    }

    /// 色块被选中时那圈描边用什么颜色。
    ///
    /// ★ 十二改新增。原来写死 `Color.white`，白盘上等于没画 —— 用户会看到
    ///    "点了白色但没有任何选中反馈"。
    ///
    /// ⚠️ 描边是 `strokeBorder`（画在圆**内侧**），所以它落在色块自己身上，
    ///    必须取 `onSolid` 而不是"一个能在黑背景上看见的颜色"。
    var selectionRing: Color { onSolid }

    /// 内圈（小时圈）的取色；`nil` = 沿用主色 `solid`。
    ///
    /// 只有三色盘（`activity`）指定 —— 取中间那道荧光绿，正好复刻活动圆环
    /// "外品红 / 中荧光绿 / 内青"的层次。双色渐变盘**不能**这么干：
    /// 它们的 `[1]` 是渐变的暗端，拿来画圈会在黑底上发黑。
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

/// 一份可持久化的外观。
///
/// ★ 2026-10-16 九改：**取消了"渐变"这个维度**（用户："取消渐变"）。
///
/// 原来的三个维度是 颜色 / 渐变 / 呼吸灯，其中"渐变"管的是"中心那块填纯色还是
/// 填两道色的线性渐变"。它被整个删掉，因为已经不剩什么可管的东西：
///   · 首页那张脸在八改去掉了底板，九改眼睛只取**纯色**；
///   · `WatchRingControl` 那只圆环现在没有任何界面在用（见那个文件顶部）；
///   · 剩下唯一还看得见的用处只有外观页里那个小预览 —— 为一个预览养一个开关不值。
///
/// ⚠️ 删属性**不会**让老存档解不开：Swift 合成的 `init(from:)` 会忽略 JSON 里
///    多余的键，所以存着 `"gradient": true` 的旧数据照样正常读出其余两项。
///    这正是这里敢直接删、而不留个 `deprecated` 空壳的原因。
struct WatchRingStyle: Equatable, Codable {
    /// 默认就是健康圆环三色（见 `WatchRingPalette.activity`）。
    var palette: WatchRingPalette = .activity
    var breathing: WatchBreathing = .off

    static let `default` = WatchRingStyle()

    /// 这个主题的**那一个**颜色。
    ///
    /// ★ 九改之后"一个主题只有一种颜色"是一个明确结论，不再是"从三色里挑端点"：
    /// 它用在首页的眼睛、录音时那条音波、两侧菜单的图标、以及录音计时那行字上。
    /// 收口成这一个属性，就不会再出现"某处用了 `colors[0]`、另一处用了
    /// `colors[1]`"这种同一个主题有几种颜色的情况（那种漂移正是上一轮
    /// 用户看到菜单图标是绿色、而脸是别的颜色的原因）。
    var tint: Color { palette.solid }

    /// 中心那块的填充。
    ///
    /// ⚠️ 现在恒等于 `tint`。之所以不删掉、让调用方直接用 `tint`：
    ///    `WatchRingControl` 和外观页预览都是按"中心那块"的语义在用它的，
    ///    以后真要给中心换一种画法，改一处就够。
    var centerFill: Color { tint }

    /// 环的取色。
    ///
    /// ⚠️ 返回的仍然是 `AngularGradient` 而不是 `Color`：唯一的调用方是
    ///    `.stroke(_:style:)`，换成纯色会把"两端压一点透明度"这层同色深浅
    ///    一起丢掉。那不是渐变，是立体感。
    ///
    /// ⚠️ 原来这里还有一条"三色盘沿环把三色铺开"的分支（那是活动圆环的观感）。
    ///    渐变取消之后它没用了 —— 三色铺开本质就是一种渐变。
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

// MARK: - 菜单项定义已移到 `WatchMenuPreferences.swift`
//
// ★ 2026-10-16 七改：原来这里的 `WatchRingCorner`（四个角标，各自通向一页）
// 随首页改版一起搬走了 —— 四项不再钉在四角，而是变成**往左/往右滑出现的
// 两侧菜单**，而且放哪几项由用户勾选。新定义是 `WatchHomeMenu`，见
// `WatchMenuPreferences.swift`。
//
// 为什么不留个 `typealias` 兼容：没有任何外部调用方（这个枚举只在本 target
// 内部用），留一层别名只会让"菜单项到底有几种"这个问题有两个答案。

/// 存手表本地 `UserDefaults`。做法与 `RecorderAliasStore` 同款：
/// JSON + 可重建缓存，解不开就当没存过（一份偏好不值得为它报错，
/// 更不能顺手清掉别人存的东西）。
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
