import SwiftUI
import WatchKit
import os.log

/// Wrist recorder page.
///
/// ★★ 2026-11-02（用户："手表的整体风格朝着这个看起，往左侧是按照这个网页里面手表来，
/// 往右侧则是现在有的菜单，然后他这个里面的内容你也可以加入进来"）：
/// 参考 `nomily-watch-v3-blink.html`，首页改成 **4 页横向翻页**，录音页落在最左：
///
/// ```
///   ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐
///   │ 0 录音    │ │ 1 最近    │ │ 2 同步    │ │ 3 菜单    │
///   │  ◉◉ / 〜  │ │ 标题·时间 │ │ 1 项待传  │ │ 快捷入口  │
///   │  00:12   │ │ 摘要要点  │ │ Wi-Fi·存储│ │ ⊕ 编辑    │
///   └──────────┘ └──────────┘ └──────────┘ └──────────┘
/// ```
///
/// 下面这段是 revision seven 起的旧结构说明（3 页：菜单 / 机器人 / 菜单），
/// **保留**是为了解释"为什么翻页是自己写的、为什么页码条不能做成按钮"——
/// 那两条结论至今有效，只是页数和内容变了。
///
/// ★ 2026-10-16 revision seven (user's words: "make it like Grok Bot, two eyes, then look at how they
/// do the natural-blinking animations; the 4 menus should appear when you swipe left or right; remove the record button from the home screen
/// and make it alive like the bot; start recording by holding its eyes for 2s, or with the earlier gestures
/// and shake to start and stop recording"):
///
/// ```
///   swipe right ←┊            ┊→ swipe left
///   ┌────────┐  ┌────────┐  ┌────────┐
///   │ ◉ Appearance │  │        │  │ ◉ Language │
///   │ ◉ Transfers │  │  ⬤⬤    │  │ ◉ Settings │
///   │ ⊕ Edit │  │  Bot   │  │ ⊕ Edit │
///   └────────┘  └────────┘  └────────┘
///                   2 pending ›
/// ```
///
/// ─────────────────────────────────────────────────────────────────────────
/// ★★ 2026-10-16 revision eight (user feedback on real hardware):
///
/// > `needs work, the blinking is too fast right now, slow the rhythm down, no green, just make the frame two eyes,
/// >  the current interaction needs work, swiping left and right doesn't reach the menus`
///
/// All four were changed:
///
/// * **Horizontal swiping never reaches the menus** -- revision seven used `TabView` + `.tabViewStyle(.page)` for horizontal paging,
///   which was a judgement made from the docs, and **the real hardware overturned it**: on watchOS the `.page` style exists but
///   doesn't give horizontal paging (`VerticalPageTabViewStyle` was only split out as its own
///   style in watchOS 10, which is exactly the hint that **vertical is the default on the watch**). Now it's our own horizontal paging (see
///   `pageDrag`): the three pages sit in one `HStack`, translated by the finger's displacement, and only flip once it crosses the threshold.
///   The upside is that direction, threshold and damping are all in our hands, with no more guessing at how the system interprets that style.
/// * **Nobody knew "you can swipe here"** -- a row of three little dots was added (`pageDots`). A big part of why users
///   couldn't find the menus is that nothing on screen ever hinted that you could swipe here.
/// * **Blinking too fast / slow the rhythm down** -- the `BlinkPhase` cycle stretches from 4.63 seconds to about 8.12 seconds,
///   and breathing from 2.6 seconds to 3.6 seconds (the accounting is written up in those two places).
/// * **No green / just make the frame two eyes** -- the Bot's rounded-square plate is deleted outright, leaving only the two
///   eyes; and this face **no longer takes any color from the palette**, it's all white (reasons at the top of `WatchBotFace`).
///
/// ─────────────────────────────────────────────────────────────────────────
/// ★★ 2026-10-16 revision nine (user feedback on real hardware):
///
/// > `inside the watch the eyes shouldn't keep blinking; when recording starts it should be a waveform just like heart rate,
/// >  not "never blink", you can go look at grok bot and their expression library,
/// >  and the color in the watch settings should be the color of the eye bot, drop the gradient`
///
/// * **The eyes shouldn't keep blinking** (but "**not never blink**") -- the `BlinkPhase` cycle stretches from
///   8.12 seconds out to about **19.12 seconds**. The structure is untouched (still "one rapid double-blink between two rests"),
///   only the two rest periods are stretched proportionally -- we want "a calm occasional blink", not "a dead-fish stare".
///   ⚠️ **Revision ten overturns this**, see below.
/// * **While recording swap in a waveform** (`WatchVoiceWave`): the peak height follows the microphone's **real level**
///   (`isMeteringEnabled`, only turned on in `WatchRecorderModel` this round; the sample rate
///   goes 1Hz → **12.5Hz**), and while quiet it runs flat along the bottom.
///   The recording state is no longer "a variant of the eyes" but another form altogether -- which is exactly following Grok's
///   "don't give the state its own indicator light; let the character's motion express it all".
/// * **Color comes back to the eyes** -- but only **a single solid color** (`WatchRingStyle.tint`).
///   Revision eight's wholesale removal of color removed the plate and the gradient, not color itself.
/// * **Drop the gradient** -- the `gradient` dimension in `WatchRingStyle` is deleted entirely; the appearance page loses a row;
///   the swatches become solid-color dots; and the menu icons go from "cycling through the palette" to the same color
///   (cycling gave the three-color palette's 2nd entry a neon green -- one of the sources of last round's "green" complaint).
///
/// ─────────────────────────────────────────────────────────────────────────
/// ★★ 2026-10-16 revision ten (user feedback on real hardware):
///
/// > `those eyes of his aren't blinking all the time, they don't need to keep blinking,
/// >  https://github.com/sam70361/aora-bot go look at the expression handling in this repo,
/// >  just the eyes, the two eyes shouldn't keep blinking, inside the watch`
///
/// **This one kills the whole approach of revisions eight and nine.** Those two did the same thing:
/// stretching the "fixed blink cycle" longer and longer (4.63s → 8.12s → 19.12s). Stretching it to 19 seconds and still being told
/// "they don't need to keep blinking" means **the root cause isn't the frequency**.
///
/// After reading that repo (`mood-mates/` and `emotion-ball/`, two engines from the same source, pure SVG + vanilla JS)
/// and its idle state, the problem turned into four points: a fixed cycle = a metronome, a rapid double-blink every round, blinking is the only thing moving,
/// and one open-close takes too long (450ms). All four were fixed, with the accounting written up at the top of `WatchBotFace`
/// in the "revision ten" passage and in "the rhythm of blinking" at the end of the file.
///
/// In one line: **promote "gaze drift" to the main idle motion and demote blinking to an occasional garnish** --
/// once the eyes are never still, "blinking" is no longer the thing the user notices.
/// It also turned up something counterintuitive: the total blink rate on both sides is about the same (roughly one per 9 seconds),
/// so what needs changing isn't the speed, it's the **regularity** and the **make-up of the motion**.
///
/// Three things change at once:
///
/// * **The ring button in the middle becomes a Bot face** (`WatchBotFace`). The ring's "one tap starts recording"
///   misfires far too easily on the wrist, and raising it to check the time or a brush from a cuff would start recording. Now a **2-second hold**
///   is what starts it -- 2 seconds is long enough that "raise the wrist to check the time" never misfires, yet short enough that when you really want
///   to record you don't feel like you're waiting.
/// * **The 4 corner dots move to the left and right pages** (user: "they should appear when you swipe left or right"). The center of the home screen
///   is therefore cleared completely for the Bot; the buttons that used to be pinned to the four corners take that old "fighting the ring for space" problem with them
///   (see the "0.74 is derived from the corner dot size" passage in `WatchRingControl`).
///   Which items go there is up to the user (see `WatchMenuPreferences`), and both pages have an "Edit" entry at the bottom.
/// * **The hold has a charge ring.** Without it the user doesn't know how long to press, or whether their press
///   was even recognized -- an interaction that "only reacts after two seconds" must have "progress" feedback, or it reads
///   as "I pressed and nothing happened".
///
/// Three ways to start/stop recording are **all live at once**, all landing on `model.toggleRecording()`:
///   1. Hold the face for 2 seconds (start) -- the gesture lives on the face, see `WatchBotFace`;
///   2. Double tap (start/stop; there's a toggle on watchOS 11+, and 10.x dispatches it automatically) --
///      also attached to the face, see `PrimaryHandGesture`;
///   3. Shake (start/stop) -- the only one not on the face, see `WatchShakeDetector`.
///
/// ⚠️ **A tap while idle does not record**, it just gives a bounce. This is the very habit this revision set out to break:
///    "one tap records" misfires far too easily on the wrist. So a finger tap only does something while recording (stop).
///    To start, hold for 2 seconds, double tap, or shake.
struct WatchRecorderView: View {
    @EnvironmentObject private var model: WatchRecorderModel
    /// Transfer state is read straight off the link rather than snapshotted
    /// into `PendingClip`, so a queue that drains (or a transfer that fails)
    /// re-renders the row without the model having to notice.
    @EnvironmentObject private var link: WatchLink
    /// Appearance preference. Held as an `@ObservedObject` rather than reading `shared` each time -- after changing a color
    /// the UI must update immediately, and `WatchBotFace` is a plain `View`,
    /// so SwiftUI would not know to redraw (same pitfall as the top of `RecorderAliasStore`).
    @ObservedObject private var styleStore = WatchRingStyleStore.shared
    /// Shake / double-tap toggle. It needs observing too: flip it in the settings page and it has to take effect here immediately.
    @ObservedObject private var prefs = WatchRecordingPrefs.shared
    /// Which items go on the two side menus. Tick one in the settings page and this page has to re-lay-out at once.
    @ObservedObject private var menuPrefs = WatchMenuPreferences.shared
    /// The home screen's resident expression. **Decided by the iPhone's settings** and pushed over via `WatchLink`
    /// (★ revision thirteen). The reason for `@ObservedObject`, same as `styleStore` above:
    /// after the phone pushes a new value, this page has to switch along with it immediately, and `WatchBotFace` is a
    /// plain `View`, so SwiftUI won't know on its own to redraw.
    @ObservedObject private var faceStore = WatchFaceStore.shared
    /// ⚠️ It has to be `@State`, not `let`: this `View` struct is re-constructed on every redraw,
    /// and a `let` would create a fresh detector every time (the sampler gets swapped out the moment it starts, so it never takes effect).
    /// `@State` keeps it in SwiftUI's storage and initializes it only once.
    @State private var shake = WatchShakeDetector()

    // ★ 2026-10-23 (功耗优化): the two signals that say "nobody is looking".
    // `isLuminanceReduced` — watchOS dimmed the display (wrist down, always-on
    // state); `scenePhase` — the app left the foreground. Either one lets the
    // model stop the 12.5 Hz meter (see `WatchRecorderModel.setUIDormant`);
    // the recording itself is untouched.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.scenePhase) private var scenePhase

    /// Current page of the horizontal paging.
    ///
    /// ★ 2026-11-02 第二轮（用户："菜单栏在左侧，右滑才是最近跟上传"）：页序改为
    ///
    /// ```
    ///   0 菜单 │ 1 录音（默认页）│ 2 最近 │ 3 同步
    /// ```
    ///
    /// 菜单回到机器人左侧；「最近 / 同步」在录音页右侧。默认落在第 **1** 页（录音）——
    /// 抬腕第一眼仍是"能立刻开始录音"的那一页。
    @State private var page: Int = 1

    /// 总页数。写成常量而不是散落的字面量：页码条、位移、边界判断三处必须同步，
    /// 少改一处就会出现"能划到不存在的第 5 页"或者"最后一页划不动"。
    private static let pageCount = 4

    /// 录音页与同步页的索引。原来这些数字是散落的字面量（`page != 0`、`page = 3`），
    /// 第二轮换过页序之后「暖线该在哪些页出现」就悄悄错了一格——改成常量，
    /// 下次再换序只有这一处要动。
    private static let recordPage = 1
    private static let syncPage = 3

    /// The displacement (pt) the finger is currently dragging. Returns to 0 during the page-flip animation.
    ///
    /// ★ Added in revision eight, the key state for **implementing horizontal paging ourselves**: the three pages are laid side by side and the whole thing is
    /// translated by `-page × screen width + dragX`. `dragX` makes the content **follow the finger** while dragging --
    /// without it you only get "let go and it snaps over", which doesn't feel like a page turn, it feels like a switch.
    @State private var dragX: CGFloat = 0

    /// The finger has to travel this far before we accept that "this is a page turn".
    ///
    /// ⚠️ It must be **greater** than the jitter of a tap and **less** than `WatchBotFace.holdSlop` (34).
    /// The three are three points on one line:
    ///   < 24  → neither a page turn nor a cancelled hold, pure jitter, ignored;
    ///   24~34 → no longer counts as "holding still", judged a paging intent;
    ///   > 34  → the hold is void.
    /// The 10pt in between is a **buffer zone**: a twitch of the hand and you're choosing between "start recording" and "turn the page",
    /// which is the most common way this kind of interaction falls apart.
    private static let pageDragSlop: CGFloat = 24

    /// Travel this far and letting go actually turns the page.
    ///
    /// ⚠️ Much larger than `pageDragSlop` (24 → 44): after recognizing "they're swiping" you still have to see whether they
    /// **swiped far enough**. If the two thresholds were one, a slight brush would turn the page and the user would keep overshooting.
    private static let pageFlipDistance: CGFloat = 44

    /// Number of times it's tapped while idle, handed to `WatchBotFace` for a single bounce.
    @State private var pokeTick = 0
    /// Number of times shake fired, handed to `WatchBotFace` to make the eyes **spin in circles**.
    ///
    /// ★ Added in revision fourteen (user: "shaking makes the eyes spin in circles with a dizzy feel").
    /// The reason for using a count as the trigger is the same as `pokeTick`.
    @State private var dizzyTick = 0
    /// Just after a hold has fired, **swallow the tap that comes right behind it**.
    ///
    /// ⚠️ This is where the whole interaction chain is most likely to fall apart: the hold gesture succeeds, and as the user lifts their finger,
    /// the `Button`'s tap comes right after (the face itself is that button), so "hold to start recording"
    /// is immediately overridden by "lift = stop" and the user never gets a recording. A brief time gate
    /// swallows that lift.
    @State private var tapGateUntil = Date.distantPast

    /// ★ 2026-10-20: the "end this take?" confirmation (double-tap / shake while
    /// recording). Both gestures are misfire-prone, so neither stops outright any more;
    /// the deliberate hold-to-stop needs no confirmation by construction.
    @State private var showStopConfirm = false
    /// ★ 2026-10-22: the confirmation **auto-closes after 2 s** and the take keeps
    /// rolling — user: "这个地方在 2s 后自动结束…默认不动则继续". A prompt that waits
    /// forever on a watch either gets answered by accident or leaves the user
    /// staring at a modal while the recording they wanted keeps running.
    @State private var stopConfirmTask: Task<Void, Never>?

    /// 页面底部那行读数现在是什么（★ 2026-11-02 · v3 原型）。
    ///
    /// 三态而不是两个 `Bool`：`saved` 只在"停止录音、眼睛还没睁开"的那 1.1 秒里存在，
    /// 用布尔量拼出来会变成"isShowingTimer && !isShowingSaved && ..."这种一看就错的组合。
    private enum ReadoutState { case hidden, timer, saved }

    @State private var readoutState: ReadoutState = .hidden
    /// 读数时间轴的 `Task`。连按两次（开始→停止→开始）必须取消上一段，
    /// 否则上一段的 `sleep` 醒来会把新状态写回 `hidden`。
    @State private var readoutTask: Task<Void, Never>?

    /// ★ 2026-11-03 八轮（用户："有些需要标记重点的，能否在手表下方按一下就打点"）：
    /// 打点按钮被按下的那 0.2 秒高亮。没有这一下，用户点完只会觉得"是不是没点中"
    /// ——手表的触感反馈比屏幕迟，而这一下动作本身又没有任何别的东西在变。
    @State private var markFlash = false
    @State private var markFlashTask: Task<Void, Never>?

    /// ★ 2026-11-03（V4 原型）：页码条的"滑动时出现、1.4 秒后淡出"整段**删掉**了。
    /// 它现在常显在底部中央，`pageBarVisible` / `pageBarHideTask` 两个状态随之作废——
    /// 留着它们只会变成"某个地方还在改一个没人读的布尔量"。

    /// Usable length of one side of the watch face: the actual screen width minus a 6pt inset on each side.
    ///
    /// ⚠️ Use `WKInterfaceDevice`'s **actual** screen width, never hard-code it -- the 40mm/44mm/45mm/49mm
    /// screen widths run from 162 to 205pt, so hard-coding either end is wrong on at least one watch.
    private static var dialSide: CGFloat {
        max(132, WKInterfaceDevice.current().screenBounds.width - 6)
    }

    /// 机器人脸外面那圈环的直径相对脸径的倍数（长按进度环 / 呼吸光晕都骑在这条线上）。
    ///
    /// ⚠️ 这个数字**同时**是"脸能长多大"的分母：环是画面上最外的东西，
    /// 它顶到可用宽/高的那一刻，脸就到顶了。见 `recordPane` 里的 `budget`。
    private static let ringSpan: CGFloat = 1.14

    /// 轻点/呼吸动画的峰值缩放。算脸径时要**按峰值反除**，否则最大的那一帧会顶进表盘圆角。
    private static let facePeak: CGFloat = 1.03

    var body: some View {
        // ★ Revision eight: **no more `TabView`**, we lay out a horizontal row ourselves. Reasons in the "revision eight" passage at the top of the file
        //    -- on watchOS, `.tabViewStyle(.page)` doesn't give horizontal paging.
        //
        // The structure is plain: each of the three pages fills one screen width, the whole row is translated by `page`, and `dragX`
        // makes it follow the finger while dragging.
        GeometryReader { geo in
            HStack(spacing: 0) {
                // ★ 2026-11-02 第二轮（用户："菜单栏在左侧，右滑才是最近跟上传"）：
                // 页序调整为 **菜单 · 录音 · 最近 · 同步**——
                // 菜单回到机器人**左侧**（revision eight 之前的老位置），
                // 原型新增的「最近 / 同步」放在录音页右侧；默认落在录音页。
                // ⚠️ 若想再换序，改这里的排列即可，`pageCount` 与页码条不用动。
                menuPane(menuPrefs.leadingItems + menuPrefs.trailingItems)
                    .frame(width: geo.size.width)
                recordPane
                    .frame(width: geo.size.width)
                WatchRecentsPane()
                    .frame(width: geo.size.width)
                WatchSyncPane()
                    .frame(width: geo.size.width)
            }
            .frame(width: geo.size.width * CGFloat(Self.pageCount), alignment: .leading)
            .offset(x: -CGFloat(page) * geo.size.width + dragX)
        }
        // ★★ 2026-11-03 三轮（用户："手表这边都错位了，上面的区域没办法显示了，
        //    然后点击结束录音都没效果"）：**撤回** `.ignoresSafeArea([.top, .bottom])`。
        //
        // 上一版加它，是想把那 20pt 顶部 inset 抢回来（见下面被删掉的那段注释的历史）。
        // 它在真机上换来两个更糟的后果，而且都是"画"和"点"不一致：
        //
        // ① **画的坐标放开了，命的坐标没放开**。SwiftUI 的 hit-test 只覆盖到父视图的
        //    安全区矩形，安全区外的子视图照样被画出来，却收不到点击——
        //    「结束」按钮正好落在那一带，于是"看得见、点不动"。
        // ② 整页内容整体上移了约 20pt，`topBar` 的 LISTENING 徽章被顶到表盘上沿的
        //    圆角/时钟带里，看起来就是"上面那块没了"。
        //
        // 结论：**可点的东西必须待在安全区里**。真正的竖向预算是靠 `recordPane` 里
        // 那套"由 `geo.size.height` 反推脸尺寸"的算法去适配的，不是靠抢 inset——
        // 抢来的 20pt 换来的是溢出，适得其反。
        //
        // ⚠️ 别再往这里加 `ignoresSafeArea`。要"用满屏"，改 `recordPane` 里
        //    那段按状态现算的竖向预算（原 `bottomStackReserve`，已内联），别动安全区。
        // Three pages side by side, but only one should be visible -- without clipping, the left and right pages spill over the current one.
        .clipped()
        // `simultaneousGesture`, not `.gesture`: the paging gesture has to **coexist** with the subviews'
        // own gestures. `.gesture` would override the Bot `Button`'s hold/tap --
        // which is exactly this page's most important interaction.
        .simultaneousGesture(pageDrag)
        // ★★ 2026-10-23 (user: "手表底部三个小点…放在其他地方，不然的话就把它充当成
        // 嘴巴去了" + "长按那个圆圈底部都是被遮挡的"):
        //
        // The bottom edge used to carry the page dots **and** the pending pill,
        // stacked in one overlay. On the Bot page that edge is exactly where the
        // hold ring's 6-o'clock arc runs — so the ring got cut off by the pill,
        // and the three dots under a round face + two red eyes read as a **mouth**
        // (the screenshots the user sent are literally that face).
        //
        // Both moved to the top edge, which the Bot page leaves empty: the pill
        // top-leading, the page indicator top-trailing as a **three-segment bar**
        // rather than dots — a bar can't be mistaken for a mouth, and it sits at
        // the same height as the pill so the two never fight the ring.
        .overlay(alignment: .top) { topBar }
        // ★ 2026-11-02（照 v3 原型）：录音中**翻到别的页时**，顶部留一根 2pt 暖线。
        //
        // 录音是个"系统状态"，它不能因为用户划到第 3 页看菜单就从感知里消失——
        // 而这根线用的是原型里唯一的暖色（`WatchHomeStyle.amber`），
        // 和 LISTENING 那颗呼吸点同源，一眼就知道"还在录"。
        //
        // ⚠️ 只在 `page != 0` 时亮：留在录音页时它和波形争同一条视线，纯属多余。
        .overlay(alignment: .top) {
            Rectangle()
                .fill(WatchHomeStyle.amber)
                .frame(height: 2)
                .padding(.horizontal, 16)
                .opacity(model.isRecording && page != Self.recordPage ? 0.55 : 0)
                .animation(.easeInOut(duration: 0.35), value: page)
                .allowsHitTesting(false)
        }
        // ★ 2026-11-03（V4 原型）：页码条从右上角搬到**底部中央、常显**。
        //
        // 两个理由都能单独成立：① 右上角已经压着系统时间，两条并排像两行字；
        // ② 上一版让它在松手 1.4 秒后淡出，结果绝大多数用户根本不知道左边还有一页菜单——
        //    一个"只有滑动时才出现"的入口等于没有入口。改成常显，代价只是 3pt 高的四根短线。
        .overlay(alignment: .bottom) {
            pageBar.padding(.bottom, 3)
        }
        // What's hidden is **this page's** navigation bar; the pushed sub-pages have their own bars and back buttons.
        //
        // ⚠️ You need both: `.toolbar(.hidden, for: .navigationBar)` hides the navigation bar itself,
        // and `.persistentSystemOverlays(.hidden)` hides **the watchOS system clock
        // clock** -- the system clock isn't part of the navigation bar; hiding only the navigation bar won't necessarily take it along.
        .toolbar(.hidden, for: .navigationBar)
        .persistentSystemOverlays(.hidden)
        .alert(
            L10n.Watch.recorderTitle,
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button(L10n.Common.ok) { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        // ★ 2026-10-30（用户："录音断联需要状态弹出提醒告知，点击或者在附近就重连"）：
        // 录音期间与手机断联（掉线持续 20 s 才弹，锁屏/切走的瞬时断开不算）。
        // 「重连」立即补推状态+补发队列；「继续」关掉弹窗、录音照跑——
        // 手机回到附近时模型会自动重连并撤掉提醒。
        .alert(
            L10n.Watch.linkLostTitle,
            isPresented: Binding(
                get: { model.linkLost },
                set: { if !$0 { model.dismissLinkLost() } }
            )
        ) {
            Button(L10n.Watch.linkLostRetry) { model.reconnectNow() }
            Button(L10n.Common.ok, role: .cancel) { model.dismissLinkLost() }
        } message: {
            Text(L10n.Watch.linkLostMessage)
        }
        // ★ 2026-11-05（用户："中断下次唤醒 Nomily AI APP 手表也要继续录音，
        // 中断则弹窗继续"）：上一场录音被系统放弃（不是用户按停）且全天候录音
        // 开着时，回到前台弹这一问。「继续」当场重开一场；「先不用」清掉标记。
        // get 在 scenePhase 变化时会随 body 重估——抬腕唤醒正是靠这个时机。
        .alert(
            L10n.Watch.resumePromptTitle,
            isPresented: Binding(
                get: { model.shouldOfferResume },
                set: { if !$0 { model.clearResumePending() } }
            )
        ) {
            Button(L10n.Watch.resumePromptContinue) { model.resumeInterruptedTake() }
            Button(L10n.Watch.resumePromptDismiss, role: .cancel) { model.clearResumePending() }
        } message: {
            Text(L10n.Watch.resumePromptBody)
        }
        .onAppear {
            syncShakeDetector()
        }
        // Stop sampling when leaving this page: keeping the accelerometer on is a big line on the battery bill,
        // and this page only comes to the foreground when you raise your wrist.
        .onDisappear { shake.stop() }
        .onChange(of: prefs.shakeToRecord) { _, _ in syncShakeDetector() }
        // ★ 2026-10-23 (功耗优化): dimmed or backgrounded → pause UI work.
        // One shared funnel (`syncDormancy`) rather than two raw calls, so a
        // "dimmed cleared while backgrounded" overlap can't send conflicting
        // values — the last state computed from both signals is always right.
        .onChange(of: isLuminanceReduced) { _, _ in syncDormancy() }
        .onChange(of: scenePhase) { _, _ in syncDormancy() }
    }

    /// Dormant = dimmed **or** not in the foreground. Both must say "awake"
    /// before the meter runs again.
    private func syncDormancy() {
        model.setUIDormant(isLuminanceReduced || scenePhase != .active)
    }

    // MARK: - 录音页（第 0 页）

    /// 录音页：机器人脸 + 底部读数。
    ///
    /// That Bot face. Hold to start, tap to stop, double tap to start/stop -- **all three live on it**
    /// (see the passage at the top of `WatchBotFace`); this is only responsible for catching its two callbacks.
    ///
    /// ★★ 2026-11-02（用户："整体风格朝着这个看起"，参考 `nomily-watch-v3-blink.html`）：
    /// 这一页相对上一版改了三处，全部来自原型：
    ///
    /// ① **计时搬到页面底部，并且变大变细**。以前它是贴在波形下面的 13pt semibold
    ///    （revision eleven 的"计时得贴着波形"），原型把它做成页面底部的一个 38pt 细体大数字。
    ///    这里是 **34pt**（★ 2026-11-03 从 26pt 提级：原型 38pt 是按 314px 宽的模拟屏量的，
    ///    162pt 屏上等比折算只有 20pt，太细看不清；34pt 保住了"细体大数字"的气质，
    ///    又能在抬腕 20cm 的距离读出来）。
    /// ② **待机时不显示读数**。原型 idle 状态下 `readOp = 0` —— 没在录音，底部就是空的，
    ///    整页只有脸和一句提示。以前那行"长按开始"留着（它是唯一的可见入口），
    ///    但不再和数字抢位置。
    /// ③ **停止时闪一下「已保存」**。原型 opening 段 320~760ms 处闪的那个词——
    ///    这是"文件已经落盘"唯一的视觉确认（手表上没法像手机那样弹 toast）。
    ///
    /// ⚠️ 脸从 0.76 缩到 0.72：40mm 总高只有 197pt，脸 + 大数字 + 一行小字要一起塞进去。
    ///    0.72 与 0.76 差 5%，肉眼几乎看不出，但正好腾出底部读数需要的那 20pt。
    private var recordPane: some View {
        // ★ 2026-11-03 二轮（用户："读数秒无法正常查看""结束录音点不到"）：
        //   脸的尺寸不再只看**屏宽**，而是同时受**实际可用高度**约束——
        //   40/41mm 上"脸(1.14 外框) + 34pt 读数 + meta 行 + 页码条避让"的竖向预算
        //   一旦爆掉，SwiftUI 会把整根 VStack 居中后两端裁切，读数先出屏，
        //   底部确认条（overlay 对齐 VStack 底）跟着一起出不了屏。
        //   现在从 `geo.size.height` 反推脸的最大尺寸，读数/按钮**永远**在屏内。
        //   ⚠️ `max(84, …)` 是兜底下限：再小脸就不可辨了，宁可牺牲 meta 行。
        GeometryReader { geo in
        #if DEBUG
        let _ = Self.logLayout(geo: geo)
        #endif
        // ★★ 2026-11-03 五轮（用户："开录跟结束都有一个白色的光环往内靠，需要取消"）：
        //   根因之一就是上一版的"按状态现算脸径"——待机一套、录音一套，开关录那一帧
        //   整只脸连同外圈环一起缩放，环淡出时看起来正是一整圈白线**往里收**。
        //   现在脸径只由屏宽/屏高**定一次**、与录音状态无关；读数与 meta 改成
        //   **浮在底部空白区**（原型本来也是 absolute 定位：脸居中、readout 贴底 64px）。
        //   ⇒ 开关录时画面里没有任何元素在缩放，只有眼睛/波形在形变。
        // ★ 2026-11-03 九轮（用户："轻点一下眼睛的效果太夸张了，而且变大弄得超出屏幕边框，
        //   上下要有一个保护距离"）：脸径必须按**峰值**（`facePeak`，1.03）反除，
        //   保证最大的那一帧也不顶到表盘圆角。
        // ★★ 2026-11-04 第三轮（用户："白色圆圈没有达到最大化，这个圆圈不协调需要大点"）：
        //   上一版把宽那一侧的 0.78 折去掉了，但**竖向预算还在扣三笔**——
        //   底部 14pt 给页码条、上下各 10pt 呼吸位。而页码条早就搬到顶部
        //   （见 body 里 `.overlay(alignment: .top) { topBar }`），底部那 14pt 是**历史遗留的
        //   空扣**；上下各 10pt 在圆形表盘上也不必要——圆环贴着圆角本来就是这套设计的样子。
        //   结果就是竖项一直赢过宽项：45mm 上脸只到 ~141pt、外圈 ~161pt，而屏宽有 192pt，
        //   四周一整圈黑边，正是用户说的"不协调"。
        //   现在按**圆的本义**算：外圈直径 = min(可用宽, 可用高)，只留 4pt 上下余量。
        //   读数与页码条都是浮层（`ZStack(alignment: .bottom)` 里的 VStack），
        //   不占版面，也不参与这里的高度计算——这是脸能真正吃满屏的前提。
        let budget = min(Self.dialSide, max(120, geo.size.height - 8))
        let faceSize = max(84, budget / (Self.ringSpan * Self.facePeak))
        ZStack(alignment: .bottom) {
            // ★ 2026-11-05 第四轮（用户："点击了全天候录音的开关则需要自动就开启了录音…
            // 然后其他的波纹也不要显示了"）：全天候录音**进行中**时整页换「环境态」——
            // 波形、眨眼、表情全部退场，只剩一颗呼吸红点 + 计时 + 结束按钮。
            // 对标 Plaud NotePin（红灯常亮=在录）与 Limitless Pendant（指示灯不可关）
            // 的"指示灯哲学"：长录场景屏幕是仪表盘的**待机灯**，不是表演舞台。
            // ⚠️ 只在"全天候开着**且**正在录"时替换；全天候开着但没在录（用户手动停过）
            //    仍回正常脸——那是给"重新开录"用的操作台。
            // 撑满整页 → ZStack 虽然是 bottom 对齐，这一层把脸/环境态都拉回页面正中。
            Group {
                if prefs.allDayRecording, model.isRecording {
                    ambientRecording
                } else {
                    WatchBotFace(
                size: faceSize,
                isRecording: model.isRecording,
                // ★ Revision thirteen: which expression to wear while idle is decided by the iPhone's settings.
                style: faceStore.style,
                // ★ 2026-10-20: the eye colour now comes from the iPhone when the user picked
                // one there (`faceStore.colorHex`); only when they haven't (`nil`) does the
                // watch fall back to its own "Appearance" palette.
                tint: faceTint,
                meter: model.meter,
                // ★ 2026-11-02（v3 原型）：计时**不再贴在波形下面**，改为页面底部的大数字
                //   （见 `readout`）。这里传 nil 之后 `figure` 里那层 `VStack` 只剩波形，
                //   波形因此重新居中——正是原型"一根线在脸中间"的样子。
                elapsedText: nil,
                pokeTick: pokeTick,
                dizzyTick: dizzyTick,
                handGestureEnabled: prefs.pinchToRecord,
                // ★ 2026-10-20: blink pace / auto-cycling expressions / square frame — all set on the iPhone.
                blinkSpeed: faceStore.blinkSpeed,
                autoCycle: faceStore.autoCycle,
                // ★★ 2026-11-03 七轮（用户："为什么这个方框还是存在呀" +
                //    "按下去会有一个透明的圆环往里面缩小，暂停录音也是"）：
                //   那个"白色半透明圆环"就是**方框**——`BotFaceFrame` 的圆角是 0.30×size，
                //   白 0.85、3~6pt 粗，在大脸上看起来已经很接近圆环。开录时它随 `eyesFade`
                //   淡出（观感就是"圆环往里缩"），停录时又淡回来（"又出现一圈白光"）。
                //   录音页**不再画方框**：这里直接传 false，不再看手机端那个开关
                //   （开关保留给手机预览用；表上这个位置属于脸，不属于装饰）。
                frameVisible: false,
                onTap: handleTap,
                onHold: beginRecordingByHold,
                onToggle: handleToggle,
                // ★ 2026-11-02（全天候录音 · 省电）：波形重绘 30fps → 2fps。
                lowPower: prefs.allDayRecording,
                // ★ 2026-11-06（表情常亮）：暗显时首页显示表情（默认）还是黑屏省电。
                alwaysOnFace: prefs.alwaysOnFace,
                // ★ 2026-11-06 二轮（"让脸活起来"四设置）：形状 / 打盹 / 瞳孔跟随，
                // 全部从手机设置或表上跟随值来（`WatchRecordingPrefs`）。
                eyeShape: prefs.eyeShape,
                drowsyEnabled: prefs.drowsyEnabled,
                drowsyAfter: prefs.drowsyAfter,
                pupilFollow: prefs.pupilFollow
            )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)

            // 底部读数区：贴底浮层，**不参与脸的高度计算**（这是脸能被放大的关键）。
            // readout / caption 都是纯文字，关掉命中测试，别挡住脸的长按与点按；
            // stashChip 是按钮，保留可点。
            // ★ 第四轮：环境态（全天候录音中）不显示——计时/chip 由 `ambientRecording`
            //   自带，两份计时叠在一起没法看。
            if !(prefs.allDayRecording && model.isRecording) {
                VStack(spacing: 4) {
                    stashChip
                    readout.allowsHitTesting(false)
                    caption.allowsHitTesting(false)
                    // 底部留 10pt 给屏幕正中的页码条（V4 原型），否则最后一行小字会和 tick 叠在一起。
                    Color.clear.frame(height: 10)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        // ★ 2026-11-02：读数的出现/消失跟着**眨眼的时间轴**走，不跟着 `isRecording` 走——
        //   按下那一刻眼睛刚开始压扁，这时候数字就弹出来会把"眨眼"打散。
        //   原型里数字在 520ms 才淡入、停止时 320ms 才换成「已保存」，见 `runReadoutTimeline`。
        .onChange(of: model.isRecording) { _, recording in
            runReadoutTimeline(recording: recording)
            // ★ 2026-11-03（用户："点击结束了那个窗口还在页面"）：兜底——录音只要不再录了，
            //   确认条就必须走人。除了「结束」按钮，还有三条路会在条开着的时候结束录音：
            //   手机端停、体能训练会话被系统结束、看门狗连拒 6 次自动停。它们都不经过按钮，
            //   谁也不会去关这个条，所以在这里统一收口。
            if !recording {
                stopConfirmTask?.cancel()
                showStopConfirm = false
            }
        }
        .onAppear {
            readoutState = model.isRecording ? .timer : .hidden
            // ★ 2026-11-02（全天候录音）：启动时把设置页的开关同步进模型（幂等）。
            model.setPowerSaver(prefs.allDayRecording)
        }
        .onDisappear {
            readoutTask?.cancel()
        }
        // ★ 2026-11-02（全天候录音）：开关一翻，采样频率与回传策略立即跟着变；
        //   关掉时模型会自动补发攒下的待传。
        // ★ 第四轮：翻开时若还没在录（比如手机端刚推过来、而本页正活着）就地补开——
        //   与设置页/链接回调共用一个幂等收口，重复触发无害。
        .onChange(of: prefs.allDayRecording) { _, on in
            model.setPowerSaver(on)
            if on { model.autoStartForAllDayIfNeeded() }
        }
        // ★ 2026-11-03（用户："录音暂停会有弹窗如果不点击则继续录音这个交互也要加入"）：
        //   系统弹窗换成**原型样式的底部确认条**（结束 / 继续录音 + 2 秒倒计时线）。
        //   默认仍然是"不点 = 继续录音"，只是从系统 alert 换成页面内的条——
        //   原型 `.sheet` 的样式（圆角 32、暖色"结束"、白色细线倒计时）在表上比 alert 轻得多。
        }
        // ★ 确认条挂在 **GeometryReader** 上（而不是里面那根 VStack）：
        //   它必须钉在页面真正的底边——之前它对齐的是 VStack 的底，
        //   VStack 一旦超出屏幕，确认条就跟着到屏幕外去了（"结束按钮点不到"的直接原因）。
        .overlay(alignment: .bottom) { stopConfirmSheet }
        // ★ 2026-11-03 八轮：录音中的「标记重点」按钮——放在右下角，**不参与任何竖向预算**
        //   （读数字号、脸径都不因为它变），也不压住居中的大计时。
        //   只在录音中出现：待机时没有"当前录音"可打点。
        .overlay(alignment: .bottomTrailing) { markButton }
    }

    // MARK: - 打点（★ 2026-11-03 八轮）

    /// 录音中的「标记重点」。
    ///
    /// 交互按用户原话定：**底部按一下**就记一个点，不弹窗、不暂停、不需要二次确认。
    /// 已经在听的场合（会议、访谈）里，任何"点完还要再点一次"的设计都会让人放弃使用。
    ///
    /// ⚠️ 尺寸按下限给的：38×30 是拇指在 45mm 表上能稳定命中的最小尺寸，
    ///    再小就会被表冠/边缘手势抢走。位置贴右下角，和居中的读数字号不重叠。
    // MARK: - 环境态（★ 2026-11-05 第四轮，全天候录音中的界面）

    /// 全天候录音进行中的整页视图。
    ///
    /// ## 设计对标（用户："对比其他做全天候显示的 app"）
    /// * **Plaud Note / NotePin**：没有屏幕，录音中 = 一颗**红灯常亮**，官方明确"不能关"——
    ///   长录场景要的不是信息量，是"还在录"这一个 bit。
    /// * **Limitless Pendant**：录音中白色 LED 常亮，同样不可关闭（知情同意 + 状态透明）。
    /// * **Apple Watch 体能训练**：常亮变暗后只剩数据与小图标，动画全部停掉。
    ///
    /// 共同点 = **"仪表盘 → 指示灯"**：活跃元素压到一枚点，其余信息（时长/段数）
    /// 全是静态文本，波形/眨眼/表情这类"表演"退场。落到实现上：
    ///
    /// * 呼吸红点：唯一的动画元素，2.4 s 一个周期——比波形每秒重绘省电得多，
    ///   也比"完全静止"更容易确认"没卡死"。
    /// * 计时：38pt thin 大数字，与常规录音页同款（`readoutFontSize` 大表档）。
    /// * 「已攒 N 段」chip 直接复用 `stashChip`（省电承诺的可点入口）。
    /// * 「结束」小按钮：环境态里脸不在了，点按/长按手势跟着脸一起消失，
    ///   必须给一个显式出口；点了走**同一条**结束确认条（`askStopConfirm`），
    ///   不直接停——误触保护在长录场景更重要。
    @State private var ambientDotOn = true

    private var ambientRecording: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .opacity(ambientDotOn ? 1 : 0.25)
                Text(L10n.Watch.ambientRec)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(WatchFormat.compactDuration(model.elapsed))
                .font(.system(size: 38, weight: .thin))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.94))
            stashChip
            Button {
                askStopConfirm()
            } label: {
                Text(L10n.Watch.stop)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            // 呼吸：repeatForever 挂在 onAppear，仅这一颗点有动画。
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                ambientDotOn = false
            }
        }
    }

    @ViewBuilder
    private var markButton: some View {
        // 结束确认条占着底部那块地方时先收起来：两条东西叠在一起，用户会点到下面那个。
        if model.isRecording, !showStopConfirm {
            Button {
                model.addBookmark()
                markFlashTask?.cancel()
                withAnimation(.easeOut(duration: 0.12)) { markFlash = true }
                markFlashTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.22)) { markFlash = false }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                    if model.totalMarks > 0 {
                        Text("\(model.totalMarks)")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(faceTint)
                .frame(width: 38, height: 30)
                .background(
                    Capsule().fill(Color.white.opacity(markFlash ? 0.24 : 0.10))
                )
                .overlay(
                    Capsule().strokeBorder(faceTint.opacity(0.45), lineWidth: 0.5)
                )
                .scaleEffect(markFlash ? 1.08 : 1)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            // 让开底部页码条（3pt 高、贴底 3pt）与屏幕圆角。
            .padding(.bottom, 26)
            .transition(.opacity)
        }
    }

    /// 录音页底部（读数 + meta + 避让 + chip 预算）的竖向预算。
    /// 脸的尺寸 = (可用高度 - 这个数) / 1.14 与屏宽比例取小。
    ///
    /// ★ 2026-11-03 四轮：`bottomStackReserve` 常量**已废弃删除**——竖向预算
    ///   改为在 `recordPane` 里按当前状态现算（待机 18 / 录音 +读数行 +meta /
    ///   省电 chip +26），脸在待机时不再被读数预算压小。
    ///   读数字号本身见 `readoutFontSize`（小表 30 / 大表 34，仍有效）。

    /// 脸的**主题色**（眼睛 / 波形 / 长按环 / 结束按钮同一支颜色）。
    ///
    /// 来源：手机端「外观」页选的色板（`faceStore.colorHex`）；没选过才回落到手表
    /// 自己那套 `styleStore.style.tint`。
    /// ★ 2026-11-03 七轮：抽成一个属性——确认条里的「结束」按钮要跟它同色，
    ///   写在两处迟早会漂。
    private var faceTint: Color {
        faceStore.colorHex.map { Color(botHex: $0) } ?? styleStore.style.tint
    }

    /// 底部大数字的字号：小表 **26**、大表 **30**。
    ///
    /// ★ 2026-11-03 下午（用户："眼睛为啥缩小了"）：34pt 放在 40mm 上会连带把脸压小，
    ///   而 30pt 在抬腕距离上仍然读得出"仪表感"（.thin 字重是关键，不是字号）。
    ///   优先保脸：脸是这只表的识别符号，读数是它的仪表盘。
    /// ★ 2026-11-03 七轮（用户："那个数字可以再小一点"）：30/34 → **26/30**。
    ///   读数现在浮在底部（不参与脸的高度计算），所以缩小纯粹是为了"别抢脸"。
    private static var readoutFontSize: CGFloat {
        dialSide < 176 ? 26 : 30
    }

    #if DEBUG
    /// 布局取证：真机上"读数被裁"这类问题光靠算数追不出来，把两个关键值打进日志。
    /// `log stream --predicate 'category == "recorder"'` 即可看到。
    private static func logLayout(geo: GeometryProxy) {
        let log = Logger(subsystem: "com.nomily.app.watch", category: "layout")
        let screen = WKInterfaceDevice.current().screenBounds.size
        log.info("record pane layout: geo=\(geo.size.width, privacy: .public)x\(geo.size.height, privacy: .public) screen=\(screen.width, privacy: .public)x\(screen.height, privacy: .public)")
    }
    #endif

    // MARK: - 结束录音确认条（★ 2026-11-03 · V4 原型）

    /// 录音中轻点 / 双指捏合 / 摇一摇弹出的底部确认条。
    ///
    /// ⚠️ 语义与旧 alert 完全一致：**2 秒不动 = 自动继续录音**（`askStopConfirm` 里的
    ///   `stopConfirmTask`），倒计时线走到头就是那个"自动继续"——看得见的默认值。
    @ViewBuilder
    private var stopConfirmSheet: some View {
        if showStopConfirm {
            VStack(spacing: 8) {
                Text(L10n.Watch.stopConfirmTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 6) {
                    Button {
                        // The 2-second timer must not fire *after* the answer was given.
                        stopConfirmTask?.cancel()
                        tapGateUntil = Date().addingTimeInterval(0.5)
                        // 触感统一由 `model.stop()` 里的「两下」负责（2026-11-04）。
                        // 这里原来先放一发 `.stop`——那是**带声音**的触感，而且此刻
                        // 麦克风还开着，那声"当"会落在录音尾巴上。
                        // ★ 2026-11-06（全天候语义）：用户点"结束" = 关开关语义，
                        // 走 stopByUser（全天候开着时先翻开关再停，录音不会被打断
                        // 又立刻自动续上）。
                        model.stopByUser()
                        // ★ 2026-11-03（用户："点击结束了那个窗口还在页面"）：
                        //   这里以前**只**调了 `model.stop()`，没有收条——而上面刚把
                        //   自动收条的 Task cancel 掉了，于是这个确认条再没人负责关闭，
                        //   会一直停在录音页上（「继续录音」那条路径才有 dismiss）。
                        //   收条与结束必须原子：先落 stop，再关条，顺序反过来会闪一帧。
                        withAnimation(.easeOut(duration: 0.22)) { showStopConfirm = false }
                    } label: {
                        Text(L10n.Watch.stopConfirmAction)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    // ★ 2026-11-03 七轮（用户："结束这个选项要跟随主题颜色"）：
                                    //   「结束」原来是固定的暖色 amber；现在跟脸/波形同一个
                                    //   主题色（手机上选的 Appearance 色），三者同源。
                                    .fill(faceTint)
                            )
                    }
                    .buttonStyle(.plain)
                    Button {
                        stopConfirmTask?.cancel()
                        withAnimation(.easeOut(duration: 0.25)) { showStopConfirm = false }
                    } label: {
                        Text(L10n.Watch.continueAction)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.10))
                            )
                    }
                    .buttonStyle(.plain)
                }
                // 2 秒倒计时线：走完 = 自动继续（和 `askStopConfirm` 的 Task 同一条时间轴）。
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule()
                            .fill(Color.white.opacity(0.40))
                            .frame(width: geo.size.width * stopConfirmCountdown)
                    }
                }
                .frame(height: 1.5)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            // ★ 2026-11-03：底部 12 → 18。页码条（3pt 高、贴底 3pt）和屏幕圆角
            //   都在这一带，确认条贴得太低会被两者夹住、末排按钮难按。
            .padding(.bottom, 18)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(white: 0.09).opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 倒计时线的剩余比例（1 → 0）。弹出时用 `Self.stopConfirmSeconds` 的线性动画走完，
    /// 和 `askStopConfirm` 里那个 Task 是同一个时长（同源常量，不会走岔）。
    @State private var stopConfirmCountdown: CGFloat = 1

    private func armStopConfirmCountdown() {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { stopConfirmCountdown = 1 }
        withAnimation(.linear(duration: Self.stopConfirmSeconds)) { stopConfirmCountdown = 0 }
    }

    /// The small line below the face. While idle it's a usage hint; while recording it's the **byte count written so far**.
    ///
    /// ⚠️ The byte count is the **only** hard evidence that "the recording is really being written to disk" --
    ///   the wave is a flat line hugging the bottom when things are quiet, and from it alone you can't tell "no sound" from "broken".
    ///
    /// ★ 2026-11-02（v3 原型）：计时搬去 `readout` 之后，这一行只剩两件事要说，
    /// 于是从"两行竖排"压成**一行**——40mm 上每一行都是预算。
    /// ★ 2026-11-03（用户："长按 2s 开始录音这个字体显示这个需要取消"）：待机的提示字**整行删掉**。
    ///   长按的进度现在有"眯眼 + 细环走满"两路动画，比一句永远挂着的字更有说服力；
    ///   首次用户的引导交给手机端首用引导（`FirstRunGuide`），表上不再常驻说明书。
    @ViewBuilder
    private var caption: some View {
        if model.isRecording {
            // ★ 2026-11-03（V4 原型）：这行改成「● 1.2 MB · 12.5Hz」——录音页要能回答
            //   "录了多少、用的是什么节奏"，而不是再重复一遍手势说明（原型里也没有）。
            //   ⚠️ 字节数不能删：波形在安静时是贴着底的一条线，从它看不出"没声音"和"坏了"的区别，
            //      落盘的字节数是唯一的硬证据。
            HStack(spacing: 3) {
                Circle()
                    .fill(Color.white.opacity(0.32))
                    .frame(width: 3, height: 3)
                Text(metaLine)
                    .monospacedDigit()
            }
            .font(.system(size: 9.5, weight: .regular))
            .foregroundStyle(.white.opacity(0.34))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .padding(.top, 2)
        }
        // 待机：什么都不显示——原型的 idle 页只有脸和提示，提示已按用户要求取消。
    }

    /// 音量表的采样节奏：常规 12.5Hz、省电 2Hz（与 `WatchRecorderModel` 的
    /// `meterInterval` / `meterIntervalSaver` 一一对应）。原型在读数下面写着这个值，
    /// 它是"省电模式真的生效了"唯一看得见的证据——否
    /// 则用户只看到波形变钝，会以为麦克风出了问题。
    private var metaLine: String {
        let rate = model.powerSaver ? "2Hz" : "12.5Hz"
        return "\(WatchFormat.bytes(model.currentBytes)) · \(rate)"
    }

    /// 省电 + 有待传时，录音页中间那颗暖色 chip：「已攒 N 段 ›」。
    ///
    /// ★ 2026-11-03（V4 原型）：省电模式的核心承诺是"攒着、充电再传"，
    ///   翻译到界面上就是这句话。它必须**可点**且直跳同步页——否则用户看到
    ///   "已攒 3 段"却找不到人在哪传，只能下滑到菜单里翻。
    @ViewBuilder
    private var stashChip: some View {
        if model.powerSaver, !model.pending.isEmpty {
            Button {
                WKInterfaceDevice.current().play(.click)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    page = Self.syncPage
                }
            } label: {
                HStack(spacing: 3) {
                    Text(L10n.Watch.stashedCount(model.pending.count))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(WatchHomeStyle.amber)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .overlay(
                    Capsule().stroke(WatchHomeStyle.amber.opacity(0.4), lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 5)
            .accessibilityLabel(L10n.Watch.stashedCount(model.pending.count))
        }
    }

    // MARK: - 底部读数（★ 2026-11-02 · v3 原型）

    /// 页面底部那行大数字：录音时是计时，停止时闪一下「已保存」，待机时**不存在**。
    ///
    /// ⚠️ 用 `.font(.system(size: 26, weight: .thin))` 而不是 `.light`：原型是 38pt/重量 200，
    ///    细体是它"不像控件、像仪表"的全部来源；换成 semibold 立刻变回一块 UI 标签。
    /// ⚠️ `monospacedDigit()` 必须有：9 秒到 10 秒时数字会整体左右跳一格，那点抖动在细体上特别明显。
    @ViewBuilder
    private var readout: some View {
        switch readoutState {
        case .hidden:
            EmptyView()
        case .timer:
            Text(WatchFormat.compactDuration(model.elapsed))
                // ★ 2026-11-03（V4 原型）：26 → **34pt thin**。计时是录音页真正的仪表，
                //   26pt 在抬腕 20cm 的距离上只是"一行字"；34pt 细体才读得出"仪表"。
                //   ⚠️ 重量必须留 `.thin`：换成 `.light` 立刻变回 UI 标签。
                // ★ 2026-11-03 下午：小表降到 30pt，把高度让回给脸（见 `readoutFontSize`）。
                .font(.system(size: Self.readoutFontSize, weight: .thin))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.94))
                .transition(.opacity)
        case .saved:
            Text(L10n.Watch.saved)
                .font(.system(size: 14, weight: .medium))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.78))
                .transition(.opacity)
        }
    }

    /// 读数跟着「眨眼」的时间轴走。
    ///
    /// | 时刻 | 读数 |
    /// |---|---|
    /// | 开始录音 0ms | 计时**立即**淡入（★ 第二轮改） |
    /// | 停止录音 320ms | 换成「已保存」 |
    /// | 停止录音 1450ms | 收掉（此时眼睛已经睁回来） |
    ///
    /// ★ 2026-11-02 第二轮（用户："手表的录音时长没有了"）：计时从"起录 520ms 后才淡入"
    ///   改为**按下就出现**。原型的延迟是为了让眨眼独占前半秒，但真机上"这个数字什么时候来"
    ///   比"节奏感"重要——计时是"录音还在进行"最硬的证据，它迟到的半秒里用户只能对着
    ///   一条还没起振的波形猜。省下的 520ms 也顺带让"有没有在录"不再依赖波形那一下。
    ///
    /// ⚠️ 数字只在 `isRecording` 翻转时出现，之后由 `model.elapsed` 自己刷新——
    ///    不要把它绑到 `elapsed` 上做动画，秒级刷新会把每一下都变成一次淡入。
    private func runReadoutTimeline(recording: Bool) {
        readoutTask?.cancel()
        if recording {
            withAnimation(.easeOut(duration: 0.35)) { readoutState = .timer }
        } else {
            readoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 320_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.24)) { readoutState = .saved }
                try? await Task.sleep(nanoseconds: 1_130_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { readoutState = .hidden }
            }
        }
    }

    /// ★ 2026-10-20: a hold while **recording** now ends the take (hold-to-stop).
    /// The ring the user sees filling is the same transition as starting — symmetric,
    /// and immune to misfires because a 2-second deliberate press is nothing like a
    /// cuff brush. Starting a recording still goes through `toggleRecording()`.
    private func beginRecordingByHold() {
        // The lift is read by the `Button` as a tap (see the `tapGateUntil` passage).
        tapGateUntil = Date().addingTimeInterval(0.5)
        if model.isRecording {
            // ★ 2026-11-06（全天候语义）：长按停 = 关开关语义（stopByUser）。
            model.stopByUser()
        } else {
            model.toggleRecording()
        }
    }

    /// Tap. While idle = poke; **while recording = the "end / keep" prompt**.
    ///
    /// ★ 2026-10-20: a tap used to stop the take, which is exactly the misfire the user
    /// reported ("录音结束…防止误触中断") — a cuff brush reads as a tap.
    ///
    /// ★ 2026-10-22 (user: "如果是手势控制点击了后就弹出结束跟继续录音，…2s 后自动结束…
    /// 默认不动则继续"): the tap used to be **refused** with a hint line. It now opens the
    /// same two-button prompt the pinch and the shake use, and that prompt closes
    /// itself after two seconds with "keep recording" as the answer. Same prompt,
    /// same default, every gesture — a stray touch can no longer end a take, and it
    /// no longer needs a second, weaker explanation of what *would*.
    private func handleTap() {
        guard Date() >= tapGateUntil else { return }
        if model.isRecording {
            WKInterfaceDevice.current().play(.click)
            askStopConfirm()
        } else {
            pokeTick += 1
        }
    }

    /// Show "End this recording? / End · Keep recording" and **arm the auto-close**.
    /// Every recording-state gesture funnels through here so the three of them
    /// can never drift apart again.
    ///
    /// ★ 2026-11-03 三轮（用户："点击结束录音都没效果"）：窗口 2s → **3.5s**。
    ///   2 秒是 10-22 那轮按"误触后要尽快恢复录音"定的；但在真机上，
    ///   从手指离开脸、眼睛看到条、挪到「结束」上，2 秒根本不够——
    ///   条在手指落下的前一帧就自己收了，于是"点了没反应"。
    ///   弹条本身已经挡住了误触（不点就是继续），所以这 1.5 秒不增加误停风险。
    ///   ⚠️ 想调回去只改 `Self.stopConfirmSeconds`，倒计时线跟着它走。
    private func askStopConfirm() {
        stopConfirmTask?.cancel()
        showStopConfirm = true
        armStopConfirmCountdown()
        stopConfirmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.stopConfirmSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Timeout = "keep recording", never "end". The user asked for the
            // default to be the safe one, and it also matches what the alert's
            // cancel button does.
            showStopConfirm = false
        }
    }

    /// 确认条存在多久后自动按「继续录音」收掉（秒）。
    ///
    /// ⚠️ 倒计时线（`armStopConfirmCountdown`）必须用同一个常量，
    ///    否则线走完了按钮还在、或者反过来，两种都让人以为界面卡死。
    private static let stopConfirmSeconds: Double = 3.5

    /// Double tap. Start / stop-with-confirmation.
    ///
    /// Shares the same `Button` as the tap, and `WatchBotFace.handlePrimaryAction()` tells them apart by
    /// "whether this one came with a touch" (a double tap is an in-air gesture with no touch).
    ///
    /// ★ 2026-10-20: while recording the pinch **asks** instead of stopping outright
    /// (user: "双指捏合…需要弹出一个确定或者继续防止误触中断") — an in-air pinch is easy
    /// to fire while reaching for something else, and it used to end the take instantly.
    private func handleToggle() {
        guard Date() >= tapGateUntil else { return }
        if model.isRecording {
            askStopConfirm()
        } else {
            model.toggleRecording()
        }
    }

    // MARK: - The two side swipe menus

    /// One menu page. When `items` is empty it shows "add some in settings" rather than a blank page --
    /// a blank page looks broken.
    private func menuPane(_ items: [WatchHomeMenu]) -> some View {
        // ★ 2026-10-30（用户："手表滑动到侧边菜单栏不支持上下滑动选择需要优化，
        // 因为下面还有"）：原来是一个 `VStack` + 两个 `Spacer` 居中，条目多出
        // 屏幕高度后**直接被裁掉**，下面的条目根本够不着。现在包进竖向
        // `ScrollView`：条目少时靠上排（不再上下顶开），条目多时整页可以滚。
        //
        // ⚠️ 与横向翻页手势不冲突：`pageDrag` 只接受"明显横向"的滑动
        //    （`abs(dx) > abs(dy)`），竖向从来交给 ScrollView。内容超高时
        //    关掉 `pageDrag`（`canPage`），否则滚动的起手会被误判成翻页。
        // ★ 2026-10-30 第二轮（用户："在手表首页左滑后要支持往下往上滑动"）：
        //   第一轮只是把内容包进 `ScrollView`，但滚动**看起来仍然不动**，两个原因：
        //   ① `pageDrag` 每帧都写 `dragX = translation.width`，竖滑时手指那点横向
        //      抖动会把整页左右蹭走（`.clipped()` 一裁，用户看到的就是"卡住/被挡住"），
        //      松手再弹回去，永远不会出现滚动的位移感 —— 现在 onChanged 里先判方向，
        //      竖向一律 `dragX = 0`，横向位移完全交给 ScrollView；
        //   ② 内容贴边：第一块砖被顶部页码条压住、最后一块被底边裁掉，看起来"下面还有
        //      但够不着"。现在上下各留出避让空间（顶部 12pt 让页码条，底部 8pt 兜底）。
        ScrollView(.vertical, showsIndicators: true) {
            // ★ 2026-11-03：行之间不留间距——发丝线就是分隔，再留 7pt 的空会变成
            //   "一堆分开的卡片"，又回到磁贴的样子。
            VStack(spacing: 0) {
                // ★ 2026-11-02：加一个小标题，和「最近 / 同步」两页的语言对齐
                // （三页都以一行压暗、字距拉开的小标题开头）。空列表时它也是唯一的说明。
                Text(L10n.Watch.menuHeader)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(WatchHomeStyle.header)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 1)
                if items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text(L10n.Watch.quickMenuEmpty)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 10)
                } else {
                    ForEach(items) { item in
                        NavigationLink {
                            item.destination
                        } label: {
                            menuTile(item)
                        }
                        .buttonStyle(.plain)
                    }
                }

                editTile
            }
            .padding(.horizontal, 10)
            // ★ 2026-11-03 二轮（用户："顶部跟底部的显示好像又没用全"）：顶部 30 → **12**，
            //   只让开右上角系统时间那一行；底部 16 给页码条避让。
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A menu item: **52pt 行 + 0.5pt 发丝线 + 1.5pt 描边图标**（★ 2026-11-03 · V4 原型）。
    ///
    /// 以前是"白 0.12 圆底卡片 + 32pt 实心圆图标"，那是 iOS 设置页的语言；
    /// 而「最近 / 同步」两页是黑底 + 发丝线 + 行内文字。一个 App 里两套材质，
    /// 翻页时最刺眼的不是内容不同，是**同一样东西长得不一样**。
    /// 现在改成和「最近」页完全同构的行，整页终于像同一个 App 的第四页，
    /// 而不是"从设置里抠出来的一屏"。
    ///
    /// 唯一例外：待传队列右侧的**暖色反白数字**——它是全页唯一带「量」的入口，
    /// 静默一个数字等于让用户猜"有没有东西没传上去"。
    private func menuTile(_ item: WatchHomeMenu) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.symbol)
                // ⚠️ SF Symbols 改不了描边宽度，用 `.light` 近似原型的 1.5pt 描边：
                //    换成 `.semibold` 会立刻变回"实心图标"的观感。
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
            Text(item.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.25))
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WatchHomeStyle.hairline)
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .accessibilityLabel(item.title)
    }

    /// 「添加快捷菜单」。和真菜单项同构，只把颜色压暗、上面加一道虚线——
    /// 它读作"这里还能加东西"，而不是"第 N 个菜单"。
    private var editTile: some View {
        NavigationLink {
            WatchQuickMenuSettingsView()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .light))
                    .frame(width: 30, height: 30)
                Text(L10n.Watch.quickMenuAdd)
                    .font(.system(size: 13.5, weight: .regular))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white.opacity(0.45))
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Watch.quickMenuAdd)
    }

    // MARK: - Horizontal paging

    /// The paging gesture. **Implemented ourselves, not via `TabView`** -- reasons in the "revision eight" passage at the top of the file.
    ///
    /// Three things are decided here:
    /// * Whether to accept it (`pageDragSlop`) -- under 24pt counts as jitter and is ignored;
    /// * Whether to flip (`pageFlipDistance`) -- only a full 44pt actually changes page;
    /// * Direction -- only **clearly horizontal** swipes count (`abs(dx) > abs(dy)`). A vertical swipe is
    ///   the user brushing the Digital Crown or flipping the system layer; swallowing it here would be baffling.
    private var pageDrag: some Gesture {
        DragGesture(minimumDistance: Self.pageDragSlop)
            .onChanged { value in
                // ⚠️ Animations **must be off** while dragging: this follows the finger frame by frame, and adding animation
                //    turns it into "a rubber band a beat behind". Only the short settle on release needs animation.
                var tx = Transaction()
                tx.disablesAnimations = true

                let raw = value.translation.width
                // ★ 2026-10-30（用户："左滑后要支持往下往上滑动"）：**先判方向再动手**。
                //   竖向滑动一律不参与翻页——手指竖着划的时候横向分量总有十几点抖，
                //   以前直接写进 `dragX`，整页被左右蹭走再弹回，用户的体感就是"滑不动"。
                //   这里把竖滑干净地让给 `ScrollView`，只在明显横向时才驱动位移。
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    if dragX != 0 { withTransaction(tx) { dragX = 0 } }
                    return
                }
                // Already at the start/end and still swiping outward → damp to 1/4. It gives a bit of "you've pulled to the end" feel,
                // otherwise the user thinks it's stuck and swipes harder.
                let pastStart = page == 0 && raw > 0
                let pastEnd = page == Self.pageCount - 1 && raw < 0
                let damped = (pastStart || pastEnd) ? raw * 0.25 : raw

                withTransaction(tx) { dragX = damped }
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height

                // ★ When the paging swipe is released, the `Button` also fires its action at the **moment the finger lifts**
                //   (that's defined `Button` behavior, not a bug). If we didn't block it,
                //   swiping the screen while idle would make the eyes bounce for no reason -- with nothing actually tapped.
                //   Reusing the same gate as the hold path; one fix for two traps.
                tapGateUntil = Date().addingTimeInterval(0.35)

                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    if abs(dx) > abs(dy), abs(dx) > Self.pageFlipDistance {
                        page = min(Self.pageCount - 1, max(0, page + (dx < 0 ? 1 : -1)))
                    }
                    // Below threshold it settles back -- that "spring back" is itself the feedback that "you didn't swipe far enough".
                    dragX = 0
                }
            }
    }

    // MARK: - Top edge of the screen

    /// The little stack at the very top: pending pill on the left, page
    /// indicator on the right.
    ///
    /// ⚠️ One overlay, one `HStack` — two separate `.overlay(alignment: .top)`
    ///    modifiers would stack on the same spot, which is the mistake the old
    ///    bottom bar documented and then this rewrite removed along with it.
    ///
    /// ★ 2026-11-02：左上角在录音时多一颗呼吸的暖点 + LISTENING。
    ///
    /// ★★ 2026-11-02（用户："顶部右上角已经有时间了，这个 bot 的右上角就不要出时间，
    ///    不然就是 2 个时间了"）：**自己画的那个时钟已经删掉**。
    ///    上一版加它是想照原型的「时钟 + 页码条」竖排，但在真机上 watchOS 自己
    ///    就会在右上角画时间（`persistentSystemOverlays(.hidden)` 只压掉了导航栏那一层，
    ///    状态栏的时间仍在），于是屏幕上出现了两个一样的时间。
    ///    现在右上角只剩页码条，并且**往下让开系统时间那一行**（`padding(.top, 24)`）。
    private var topBar: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                if model.isRecording {
                    // ★ 2026-11-03（V4 原型）：省电时换成月亮 + MOONLIT。
                    WatchListeningBadge(powerSaver: model.powerSaver)
                }
                queueBar
            }
            Spacer(minLength: 0)
            // ★ 2026-11-03：页码条已搬到**底部中央常显**（见 `body` 的 bottom overlay）。
            //   右上角现在只剩系统时间，两者不再抢同一块地方。
        }
        .padding(.horizontal, 5)
        // 顶部留 6pt：那根 2pt 暖线贴着屏幕最上沿，压住它会看起来像标签被裁了。
        .padding(.top, 6)
    }

    /// 页码条：**底部中央常显**的四根发丝 tick（★ 2026-11-03 · V4 原型）。
    ///
    /// 常态白 0.24，当前页拉长到 14pt、白 0.66——不抢视线，但一直答得出
    /// "我在第几页、还能往哪边划"。搬家的理由见 `body` 里那处 overlay 的注释。
    ///
    /// ⚠️ 刻意**不可点**：3pt 高、40mm 表上根本点不中，做成按钮只会带来
    ///    "我点了没反应"。它的职责是"告诉你这里能滑"。
    private var pageBar: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< Self.pageCount, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index == page ? 0.66 : 0.24))
                    .frame(width: index == page ? 14 : 3, height: 3)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: page)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - The pending hint

    /// The compact pending pill. **Only appears when something is pending.**
    ///
    /// ★ Moved 2026-10-23 from the bottom edge to the top-leading corner: on the
    /// Bot page the bottom edge is the hold ring's arc, and the pill was literally
    /// covering it ("长按那个圆圈底部都是被遮挡的"). Details stay on their own page
    /// (`WatchQueueView`), so the pill is just an icon + count + chevron.
    @ViewBuilder
    private var queueBar: some View {
        if !model.pending.isEmpty {
            // ★ 2026-11-03：直接跳**同步页**——「待传队列」独立页和同步页重复，已并入那里。
            Button {
                WKInterfaceDevice.current().play(.click)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    page = Self.syncPage
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.circle.fill")
                    Text(L10n.Watch.pendingCount(model.pending.count))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 10, weight: .medium))
                // ★★ 2026-11-04（用户："左上角的 1 项目待传为啥不跟随手表的主题颜色，
                //    当前是白色他是红色"）：用的是 `styleStore.style.tint` —— 表本地
                //   「外观」里那套配色，和手机推下来的**眼睛颜色**（faceTint，用户说的
                //   "主题颜色"）是两个来源。用户在外观里选了浅色系时，这个 pill 就是白的。
                //   录音页上所有该带主题色的元素（眼睛 / stashChip / 这里）统一走 faceTint。
                .foregroundStyle(faceTint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(faceTint.opacity(0.14)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Watch.pendingHeader)
        }
    }

    // MARK: - Shake

    /// Line the sampling state up with the current toggle. **Idempotent** -- called blindly from both `onAppear` and the toggle change.
    private func syncShakeDetector() {
        guard prefs.shakeToRecord else {
            shake.stop()
            return
        }
        shake.start { [model] in
            // 触感分工（2026-11-04）：
            //   · 真开/真停 → 由 `WatchRecorderModel.playHaptics` 出「开始一下、结束两下」，
            //     这里**不再自己放**，否则一次摇动会响两遍（且 `.start`/`.stop` 带声音，
            //     开录那一下会被录进文件开头）。
            //   · 录音中摇一摇只是**弹确认**、不会真停，模型那边不会响，所以这里补一下，
            //     用 `.click` 而不是 `.stop`——此时麦克风还开着。
            guard !model.isRecording else {
                WKInterfaceDevice.current().play(.click)
                // ★ 2026-10-20: while **recording** the shake asks before acting (user:
                // "摇一摇也是需要弹出是否确认取消") — a shake is the easiest gesture to
                // produce by accident while moving, and it used to end the take outright.
                // (The detector fires on the main queue, so the @State write is safe.)
                // ★ 2026-10-22: same prompt as tap / pinch, and it closes itself
                // after 2 s with "keep recording" — see `askStopConfirm`.
                askStopConfirm()
                return
            }
            // ★ Revision fourteen: the eyes **spin in circles** (user: "shaking makes the eyes spin in circles with a dizzy feel
            //   to add more interaction"). A haptic for the wrist and the dizzy for the eyes; together the two channels say "received".
            dizzyTick += 1
            // ⚠️ The actual start/stop is **pushed back 0.45 seconds**: without that, the recording state immediately swaps in the waveform
            //    the moment the eyes start spinning and the "dizzy" is never seen.
            //    0.45 seconds falls in the **first half** of the two spins (0.9 seconds total): when recording starts you see
            //    the eyes dizzy through half a turn, then the color floods in; when recording stops the wave exits and the eyes come back
            //    with the second half of the dizzy. Both directions get their moment.
            //
            //    The delay is **added on the perception side**, but shake already has about a 0.9-second detection window
            //    (`WatchShakeDetector.burstWindow`), and the user's expectation for a "shake" was never
            //    instant anyway. Any longer and it's no good -- that reads as "I shook it and nothing happened".
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                model.toggleRecording()
            }
        }
    }
}

// MARK: - The pending page（已删除，2026-11-03）
//
// 「待传队列」独立页和「同步」页是同一份数据的两张皮，队列列表已并入
// `WatchSyncPane`（见 WatchHomePanes.swift），左上角待传胶囊直跳同步页。

enum WatchFormat {
    /// What fits inside the ring. `mm:ss` while the hours field would only
    /// ever read zero — the ring's inner lap already carries "how far into the
    /// hour are we", so an `00:` prefix is four characters of nothing.
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        guard hours > 0 else {
            return String(format: "%02d:%02d", (total / 60) % 60, total % 60)
        }
        return String(format: "%d:%02d:%02d", hours, (total / 60) % 60, total % 60)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// Day + time for the Recap rows (★ 2026-10-23): "10/23 14:30" shape.
    /// Recap entries live for 7 days, so the date is as relevant as the time —
    /// a bare `HH:mm` leaves "which morning was this?" unanswered. Cached
    /// formatter: `DateFormatter` init is expensive enough that a watch app
    /// shouldn't pay it per row per render.
    private static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "MMdd HH:mm", options: 0, locale: .current
        )
        return formatter
    }()

    static func dayTime(_ date: Date) -> String {
        dayTimeFormatter.string(from: date)
    }
}
