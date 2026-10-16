import SwiftUI

/// 手表首页常驻的那个表情。
///
/// ★ 2026-10-16 十三改新增（用户："需要在 Nomily AI APP 里面的设置里面增加一个
///    就是设置手表的首页眼睛的表情"）。
///
/// ## 这一份和 `WatchMenuPreferences` / `WatchRingStyleStore` 是**同一类东西**
/// 存手表本地、`UserDefaults` 单键、`ObservableObject` 好让首页立刻重绘。
/// 做法照抄那两份（单键 + 解不开就当没存过），不另立一套。
///
/// ## `private(set)` 是有意的：**作者是手机，不是手表**
/// 和另外两份偏好不同的是，这一个的**唯一**写入方是 iPhone ——
/// 用户在手机的设置里挑，经 `WatchConnectivity` 推过来（见 `WatchLink`）。
/// 手表自己不摆选择器（表上那点地方留给别的），所以对外只暴露 `apply(_:)`，
/// 没有 `select(_:)`。
///
/// ⚠️ 但**必须**在手表本地存一份：`updateApplicationContext` 是"最新一版替换掉
///    还没送出去的那一版"，它既不保证手机在线、也不保证手表活着的时候送达。
///    手表冷启动时如果只靠内存里那点东西，抬腕第一帧会先画默认表情、
///    等手机想起来再跳一下。存下来之后，第一帧就是用户上次选的那个。
final class WatchFaceStore: ObservableObject {
    static let shared = WatchFaceStore()

    private static let key = "watch.face_style.v1"

    /// 当前常驻的那一档。
    ///
    /// **没存过 = `calm`**（十三改之前那张脸的样子）—— 默认值必须等于
    /// "这个功能不存在时的行为"，否则老用户升上来会发现表上的脸莫名其妙变了。
    @Published private(set) var style: BotFaceStyle

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style = BotFaceStyle.decode(defaults.string(forKey: Self.key)) ?? .calm
    }

    /// 手机推过来的选择。**幂等** —— 每次握手手机都会重推一遍同一个值，
    /// 每次都写盘没有意义。
    ///
    /// ⚠️ **不认识的值直接忽略，不回落默认值。** 手机与手表的 App 版本可以不一致
    ///    （手表的更新由 iPhone 择机推送，常常晚一个重启周期）。新版手机推来一个
    ///    旧版手表没有的 tag 时，退回 `calm` 会让用户"换了表情却变回默认"，
    ///    而保持原样只是"这一个没生效" —— 两害相权取其轻。
    func apply(_ tag: String?) {
        guard let next = BotFaceStyle.decode(tag), next != style else { return }
        style = next
        defaults.set(next.rawValue, forKey: Self.key)
    }
}
