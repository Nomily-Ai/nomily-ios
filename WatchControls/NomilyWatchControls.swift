import AppIntents
import SwiftUI
import WidgetKit

// MARK: - 控制中心的快捷录音控件（watchOS 26+）
//
// ★ 2026-10-16 八改。用户原话：
//
//   "即使脱离出手表的 Nomily APP 的软件在手表的控制菜单栏里面添加一个组件方便用户
//    直接按手表的旋转按钮下面的按键直接唤出来的控制中心里面添加一个快捷方式，
//    用户去手表里面找 Nomily 快速进入录音"
//
// 也就是：**不用先去找 App** —— 按侧边按钮（表冠下面那个键）拉出控制中心，里面
// 有一个 Nomily 的录音按钮，按一下直接开始。
//
// ─────────────────────────────────────────────────────────────────────────
// ## ★ 为什么这个 target 是 watchOS 26 起步，而不是跟着 watch App 的 10.0
//
// Control Widget 这套 API 在**手表上是到 watchOS 26 才有**的。本机 SDK
// （WatchOS26.5）的接口文件写得明明白白：
//
//     SwiftUI.ControlWidget                @available(iOS 18.0, macOS 26.0, watchOS 26.0, *)
//     SwiftUI.ControlWidgetConfiguration   @available(iOS 18.0, macOS 26.0, watchOS 26.0, *)
//     SwiftUI.ControlWidgetTemplate        @available(iOS 18.0, macOS 26.0, watchOS 26.0, *)
//     WidgetKit.ControlWidgetButton        @available(iOS 18.0, macOS 26.0, watchOS 26.0, *)
//     WidgetKit.StaticControlConfiguration @available(iOS 18.0, macOS 26.0, watchOS 26.0, *)
//
// 注意 iOS 侧写的是 18.0、watchOS 侧写的是 26.0 —— 同一套 API 在表上晚了整整
// 一个大版本。所以这一份的 `WATCHOS_DEPLOYMENT_TARGET` 必须单写 26.0：
// 跟着 `nomily_watch` 的 10.0 走的话，编译期过不去 `ControlWidget` 的可用性检查，
// 就算硬压过去，控件在 10.0~25.x 的表上也不会出现，属于"编译能过、功能没有"。
//
// ─────────────────────────────────────────────────────────────────────────
// ## ★ 为什么控件必须由 watch 端出，不能只在 iPhone 端写一个
//
// 苹果文档（WidgetKit → Controls → Overview）原文：
//
//   "On Apple Watch, people place controls from your watchOS app or from a paired
//    iPhone in Control Center or the Smart Stack. **If you offer a watchOS app in
//    addition to an iPhone app and both apps offer controls, people can only place
//    controls from your watchOS app in Control Center or the Smart Stack.**"
//
// 我们两端都有 App，所以**只有这一份**会被控制中心认。再在 iPhone 端写一个
// 一模一样的控件是纯浪费 —— 系统会直接忽略它。
//
// ─────────────────────────────────────────────────────────────────────────
// ## ★ 为什么动作直接复用 `ToggleRecordingIntent`
//
// 那个 intent 本来就是给 Ultra 的操作按钮写的（`openAppWhenRun = true`，落回 App
// 进程后由 `RecordingIntentBus` 派发给 `WatchRecorderModel`）。控制中心这条路的
// 形态与它**完全一样**：一次点击 → 拉起 App → 开始/停止录音。
// 另写一个 intent 只会让"什么算一次录音开关"多出第二个答案。
//
// ⚠️ 这里的 `openAppWhenRun = true` 是**要的**，不是将就：录音要麦克风权限、音频
//    会话和那圈计时 UI，全都长在 App 里。一个在扩展进程里偷偷起录音的版本，用户
//    既看不见也停不掉（这段踩坑记录在 `RecordingIntent.swift` 开头）。

/// 控制中心里那个录音按钮。
///
/// ⚠️ 只在 watchOS 26+ 存在（理由见文件顶部）。这一份的部署目标就是 26.0，
///    所以这里**不需要**写 `@available` —— 写了反而会被"这个 target 只跑在
///    26 以上"的事实噎住，变成一句没有信息量的噪音。
struct NomilyRecordingControl: ControlWidget {
    /// 系统按这个字符串记账（一个 App 的多个控件靠它区分）。前缀跟着扩展的
    /// bundle id 走，不要用 App 的 —— 两者以后可能各归各的。
    private static let kind = "com.nomily.app.watchkitapp.control.record"

    var body: some ControlWidgetConfiguration {
        // `StaticControlConfiguration` 而不是 `AppIntentControlConfiguration`：
        // 这个控件**没有可配项**。用户要的就是"按一下开始录"，给他一个配置页
        // 只会多一步。
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleRecordingIntent()) {
                Label {
                    // ⚠️ 文案**故意复用操作按钮那三个键**
                    //    （`watch.intent_toggle_short_title` / `_title` / `_description`）。
                    //    它们已经在 11 个语言里翻好了，而且说的本来就是同一件事
                    //    ——"开或关一次录音"。新造键只会让同一句话有两个来源，
                    //    以后改文案必漏一个。
                    Text(LocalizedStringResource(
                        "watch.intent_toggle_short_title",
                        defaultValue: "Record"
                    ))
                } icon: {
                    Image(systemName: "mic.fill")
                }
            }
        }
        // 「控制中心 → 编辑 → 添加」列表里显示的名字。
        // 用**全称**而不是"录音"：那个列表会把同一个 App 的多个控件并排列出，
        // 两个字的名字在那儿认不出是干嘛的。
        .displayName(LocalizedStringResource(
            "watch.intent_toggle_title",
            defaultValue: "Start or Stop Recording"
        ))
        // 名字底下那行说明。
        .description(LocalizedStringResource(
            "watch.intent_toggle_description",
            defaultValue: "Starts a voice note on your Apple Watch, or stops the one that's running."
        ))
    }
}

/// 这个扩展的入口。
///
/// 只有控件、没有普通 widget：用户要的是"控制中心里按一下"，不是智能叠放里
/// 多一张卡片。少一个东西就少一处要跟着维护的刷新逻辑。
@main
struct NomilyWatchControlsBundle: WidgetBundle {
    var body: some Widget {
        NomilyRecordingControl()
    }
}
