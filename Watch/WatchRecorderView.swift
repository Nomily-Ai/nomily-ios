import SwiftUI
import WatchKit

/// Wrist recorder page.
///
/// ★ 2026-10-16 七改（用户原话："类似 Grok Bot 一样，两个眼睛然后你参考一下他会
/// 自然眨眼做的哪些动画，4 个菜单需要往左或者往右滑在出现，把当前首页的录音按钮
/// 去掉改成 bot 一样生动的，通过长按点击它的眼睛 2s 才开始录音或者之前的手势
/// 交互跟摇一摇才开始录音跟停止录音"）：
///
/// ```
///   往右滑 ←┊            ┊→ 往左滑
///   ┌────────┐  ┌────────┐  ┌────────┐
///   │ ◉ 外观 │  │        │  │ ◉ 语言 │
///   │ ◉ 传输 │  │  ⬤⬤    │  │ ◉ 设置 │
///   │ ⊕ 编辑 │  │  Bot   │  │ ⊕ 编辑 │
///   └────────┘  └────────┘  └────────┘
///                   2 项待传 ›
/// ```
///
/// ─────────────────────────────────────────────────────────────────────────
/// ★★ 2026-10-16 八改（用户真机反馈）：
///
/// > `需要优化，当前眨眼太快，节奏慢点，不要绿色，边框直接就 2 个眼睛，
/// >  当前的交互需要优化，左右滑不到菜单`
///
/// 四条都动了：
///
/// * **左右滑不到菜单** —— 七改用 `TabView` + `.tabViewStyle(.page)` 做横向分页，
///   那是照资料判断的，**真机推翻了它**：watchOS 上 `.page` 这个样式存在，却
///   不给出横向翻页（`VerticalPageTabViewStyle` 是 watchOS 10 才单独分出来的
///   样式，恰好说明**竖排才是表上的默认**）。现在换成自己控制的横向分页（见
///   `pageDrag`）：三页摆在一条 `HStack` 里，按手指位移平移、达标才翻页。
///   好处是方向、阈值、阻尼全在手上，不用再猜系统怎么解释那个样式。
/// * **"这儿能滑"没人知道** —— 补了一排三个小圆点（`pageDots`）。用户找不到菜单
///   有很大一部分原因是：屏幕上没有任何东西提示过这里可以滑。
/// * **眨眼太快 / 节奏慢点** —— `BlinkPhase` 一个周期从 4.63 秒拉到约 8.12 秒，
///   呼吸从 2.6 秒放到 3.6 秒（账目写在那两处）。
/// * **不要绿色 / 边框直接就 2 个眼睛** —— Bot 那块圆角方底板整块删掉，只剩两只
///   眼睛；而且这张脸**不再取色板的任何颜色**，全白（理由见 `WatchBotFace` 顶部）。
///
/// ─────────────────────────────────────────────────────────────────────────
/// ★★ 2026-10-16 九改（用户真机反馈）：
///
/// > `手表里面眼睛不要一直眨眼，开始录音的时候就是一条音波跟心率一样的，
/// >  不是不眨眼，你可以去 grok bot 参考他们的那个表情库，
/// >  那个手表里的设置颜色则是眼睛 bot 的颜色，取消渐变`
///
/// * **眼睛不要一直眨眼**（但"**不是不眨眼**"）—— `BlinkPhase` 一个周期从
///   8.12 秒再拉到约 **19.12 秒**。结构一格没动（还是"两下里夹一次连眨"），
///   只把两段静置按比例拉长 —— 要"平静地偶尔眨一下"，不是"死鱼眼"。
///   ⚠️ **十改把这条推翻了**，见下。
/// * **录音时换成一条音波**（`WatchVoiceWave`）：尖峰高度取麦克风的**真实电平**
///   （`WatchRecorderModel` 这一轮才开的 `isMeteringEnabled`，采样率
///   1Hz → **12.5Hz**），安静时靠一个"咚—哒"的底型维持心率般的节律。
///   录音态从此不是"眼睛的变体"，是另一个形态 —— 也正是参考 Grok 那套
///   "状态不另做指示灯、全交给形象的动作去表达"。
/// * **颜色回到眼睛上** —— 但只回**一个纯色**（`WatchRingStyle.tint`）。
///   八改把颜色整条去掉去掉的是底板和渐变，不是颜色本身。
/// * **取消渐变** —— `WatchRingStyle` 里的 `gradient` 维度整个删掉；外观页少一行；
///   色块改成纯色圆点；菜单图标也从"色板里循环取"改成同一个颜色
///   （循环取会让三色盘的第 2 项拿到一道荧光绿 —— 上一轮"绿色"抱怨的来源之一）。
///
/// ─────────────────────────────────────────────────────────────────────────
/// ★★ 2026-10-16 十改（用户真机反馈）：
///
/// > `他的那个眼睛不是一直眨眼的，不需要一直眨眼，
/// >  https://github.com/sam70361/aora-bot 你参考这个仓库里面的表情管理，
/// >  只看眼睛就好，两个眼睛不要一直眨眼，手表里面`
///
/// **这一条直接否掉了八改/九改的整个思路。** 那两改做的是同一件事：
/// 把"固定眨眼周期"越拉越长（4.63s → 8.12s → 19.12s）。拉到 19 秒还在被说
/// "不需要一直眨眼"，就说明**根因不是频率**。
///
/// 读了那个仓库（`mood-mates/`、`emotion-ball/` 两套同源引擎，纯 SVG + 原生 JS）
/// 的待机态之后，问题翻成了四条：固定周期=节拍器、每轮必连眨、眨眼是唯一在动
/// 的东西、一次开合太慢（450ms）。四条都改掉了，账目写在 `WatchBotFace` 顶部
/// 的"十改"那段和文件末尾的"眨眼的节奏"。
///
/// 一句话概括：**把"目光游移"提成待机的主体动作，眨眼降级成偶尔的点缀** ——
/// 眼睛从不静止之后，"眨眼"就不再是用户会注意到的那件事了。
/// 顺带算出一件反直觉的事：两边眨眼的总频率其实差不多（都是约 1 次 / 9 秒），
/// 所以要换的不是快慢，是**规律性**和**动作构成**。
///
/// 三件事一变：
///
/// * **中间的圆环按钮换成了一张 Bot 脸**（`WatchBotFace`）。圆环的"点一下就开始录"
///   在手腕上太容易误触，而且抬手看时间、袖口蹭一下都会录上。现在**长按 2 秒**
///   才开始 —— 2 秒足够长，长到"抬手看表"永远不会误触发；又足够短，短到真要用
///   的时候不觉得在等。
/// * **4 个角标搬到左右两页**（用户："需要往左或者往右滑在出现"）。首页正中
///   因此彻底腾空给 Bot；原来钉在四角的按钮连"和环抢位置"这个老问题一起消失了
///   （见 `WatchRingControl` 里那段"0.74 是被角标尺寸反推出来的"）。
///   放哪几项由用户勾（见 `WatchMenuPreferences`），两页底部各有"编辑"入口。
/// * **长按有蓄力环**。没有它，用户不知道要按多久、也不知道自己那一下被没被
///   识别到 —— 一个"按两秒才有反应"的交互，必须有"进度"这层反馈，否则会被
///   当成"按了没反应"。
///
/// 三条开始/停止录音的路径**同时有效**，全部落在 `model.toggleRecording()` 上：
///   1. 长按脸 2 秒（开始）—— 手势长在脸上，见 `WatchBotFace`；
///   2. 双指互点（开始/停止；watchOS 11+ 有开关，10.x 由系统自动派发）——
///      同样挂在脸上，见 `PrimaryHandGesture`；
///   3. 摇一摇（开始/停止）—— 唯一不在脸上的那条，见 `WatchShakeDetector`。
///
/// ⚠️ **空闲态轻点不录音**，只弹一下。这是这次要改掉的毛病本身：
///    "点一下就录"放在手腕上太容易误触。所以手指轻点只在录音中有效（停止）。
///    要开始，请长按 2 秒、双指互点、或摇一摇。
struct WatchRecorderView: View {
    @EnvironmentObject private var model: WatchRecorderModel
    /// Transfer state is read straight off the link rather than snapshotted
    /// into `PendingClip`, so a queue that drains (or a transfer that fails)
    /// re-renders the row without the model having to notice.
    @EnvironmentObject private var link: WatchLink
    /// 外观偏好。挂成 `@ObservedObject` 而不是每次读 `shared` —— 改颜色之后
    /// 界面要立刻变，而 `WatchBotFace` 是个普通 `View`，
    /// SwiftUI 不知道要去重绘（同一个坑见 `RecorderAliasStore` 顶部那段）。
    @ObservedObject private var styleStore = WatchRingStyleStore.shared
    /// 摇一摇 / 双指互点开关。同样要观察：设置页里一拨，这一页得立刻生效。
    @ObservedObject private var prefs = WatchRecordingPrefs.shared
    /// 两侧菜单放哪几项。设置页里一勾，这一页要立刻重排。
    @ObservedObject private var menuPrefs = WatchMenuPreferences.shared
    /// 首页常驻的表情。**由 iPhone 的设置决定**，经 `WatchLink` 推过来
    /// （★ 十三改）。挂成 `@ObservedObject` 的理由同上面 `styleStore`：
    /// 手机推来一个新值之后，这一页必须立刻跟着换，而 `WatchBotFace` 是个
    /// 普通 `View`，SwiftUI 不会自己知道要去重绘。
    @ObservedObject private var faceStore = WatchFaceStore.shared
    /// ⚠️ 必须是 `@State` 而不是 `let`：这个 `View` 结构体每次重绘都会被重新
    /// 构造，`let` 每次都新建一个检测器（采集刚开就换人，等于一直不生效）。
    /// `@State` 把它挂在 SwiftUI 的存储里，只初始化一次。
    @State private var shake = WatchShakeDetector()

    /// 横向分页的当前页：0 = 左页菜单，1 = Bot，2 = 右页菜单。
    ///
    /// 默认落在 **1**（Bot）—— 抬腕第一眼看到的必须是"能马上开始录"的那一页，
    /// 而不是一页菜单。
    @State private var page: Int = 1

    /// 手指正拖着的那一段位移（pt）。翻页动画期间会回到 0。
    ///
    /// ★ 八改新增，是**自己实现横向分页**的关键状态：三页并排摆好，整体
    /// 平移 `-page × 屏宽 + dragX`。`dragX` 让内容在拖动过程中**跟着手指走** ——
    /// 没有它，就只能"松手之后啪地跳过去"，那不像翻页，像切换。
    @State private var dragX: CGFloat = 0

    /// 手指得先划出这么远，才承认"这是在翻页"。
    ///
    /// ⚠️ 必须**大于**轻点的抖动、又**小于** `WatchBotFace.holdSlop`（34）。
    /// 三者是一条线上的三个点：
    ///   < 24  → 既没翻页、也没取消长按，纯抖动，忽略；
    ///   24~34 → 已经不算"按住不动"了，会被判成翻页意图；
    ///   > 34  → 长按作废。
    /// 中间那 10pt 是**缓冲带**：手一抖就同时在"开始录音"和"翻页"之间二选一，
    /// 是这类交互最常见的翻车方式。
    private static let pageDragSlop: CGFloat = 24

    /// 划够这么远，松手才真的翻页。
    ///
    /// ⚠️ 比 `pageDragSlop` 大得多（24 → 44）：认出来"他在划"之后还要看他
    /// **划得够不够**。两个阈值合一的话，稍微蹭一下就翻页，用户会一直翻过头。
    private static let pageFlipDistance: CGFloat = 44

    /// 空闲态被轻点的次数，转给 `WatchBotFace` 做一次弹跳。
    @State private var pokeTick = 0
    /// 摇一摇触发的次数，转给 `WatchBotFace` 让眼睛**转圈圈**。
    ///
    /// ★ 十四改新增（用户："摇一摇眼睛会有转圈圈眩晕感"）。
    /// 计数当触发器的理由同 `pokeTick`。
    @State private var dizzyTick = 0
    /// 长按刚触发过的那一刻之前，**吃掉紧接着来的那一下轻点**。
    ///
    /// ⚠️ 这是整条交互链最容易翻车的地方：长按手势成功、用户抬手时，
    /// `Button` 那一下 tap 会跟着来（脸本身就是那个按钮），于是"长按开始录音"
    /// 当场被"抬手=停止"顶掉，用户根本录不上。用一个短暂的时间闸门把这记
    /// 抬手吃掉。
    @State private var tapGateUntil = Date.distantPast

    /// 表盘一边的可用长度：实机屏宽扣掉左右各 6pt 内边距。
    ///
    /// ⚠️ 用 `WKInterfaceDevice` 的**实机**屏宽，不写死 —— 40mm/44mm/45mm/49mm
    /// 屏宽从 162 到 205pt 不等，写死任何一边都至少在一种表上出错。
    private static var dialSide: CGFloat {
        max(132, WKInterfaceDevice.current().screenBounds.width - 6)
    }

    /// Bot 脸的边长占屏宽的比例。
    ///
    /// ⚠️ 留了余量给两样东西：脸外面那圈蓄力环（1.14 倍）、以及脸下面那行
    /// 状态字（计时/提示）。0.76 在 40mm 上是 119pt，含环 136pt，
    /// 加一行字仍在 162×194 的屏幕里。
    ///
    /// ⚠️ 八改从 0.70 提到 0.76：底板删掉之后，那 0.70 的方框里只剩两只眼睛，
    ///    按原比例整张脸会显得小而空。放大一档刚好补回"没有底板"损失的体量。
    private static let botFraction: CGFloat = 0.76

    var body: some View {
        // ★ 八改：**不用 `TabView`** 了，自己摆一条横排。理由见文件顶部"八改"那段
        //    —— watchOS 上 `.tabViewStyle(.page)` 不给横向翻页。
        //
        // 结构很直白：三页各自占满一屏宽，整条按 `page` 平移，`dragX` 负责
        // 让它在拖动过程中跟着手指走。
        GeometryReader { geo in
            HStack(spacing: 0) {
                menuPane(menuPrefs.leadingItems)
                    .frame(width: geo.size.width)
                botPane
                    .frame(width: geo.size.width)
                menuPane(menuPrefs.trailingItems)
                    .frame(width: geo.size.width)
            }
            .frame(width: geo.size.width * 3, alignment: .leading)
            .offset(x: -CGFloat(page) * geo.size.width + dragX)
        }
        // 三页并排，但只该看见一页 —— 不裁的话左右两页会压在当前页外面。
        .clipped()
        // `simultaneousGesture` 而不是 `.gesture`：翻页手势必须与子视图自己的
        // 手势**并存**。用 `.gesture` 会把 Bot 那颗 `Button` 的长按/轻点顶掉 ——
        // 那正好是这一页最要紧的交互。
        .simultaneousGesture(pageDrag)
        .overlay(alignment: .bottom) { bottomBar }
        // 隐藏的是**这一页**的导航条；推入的子页各自有自己的条与返回键。
        //
        // ⚠️ 两条都要：`.toolbar(.hidden, for: .navigationBar)` 收掉导航条本身，
        // `.persistentSystemOverlays(.hidden)` 收掉 **watchOS 系统叠在最上层
        // 的那只时钟** —— 系统时钟不属于导航条，只藏导航条它不一定跟着走。
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
        .onAppear {
            syncShakeDetector()
            // ★ 十五改：这里原来有一句 `model.prepareHeartRate()`（十一改加的，
            //   在首页出现时申请读心率）。心率那条链路本轮起不再被任何地方调用，
            //   所以这句也一起去掉 —— 否则用户会看到一张"这个录音 App 为什么要
            //   读我心率"的授权页，而它换来的是一个没人用的数字。
            //   完整理由见 `WatchHeartRate.swift` 顶部。
        }
        // 离开这一页就停采集：加速度计一直开着是电池账上的大头，
        // 而这一页是抬腕才会出现在前台的。
        .onDisappear { shake.stop() }
        .onChange(of: prefs.shakeToRecord) { _, _ in syncShakeDetector() }
    }

    // MARK: - Bot 首页

    /// Bot 那张脸。长按开始、轻点停止、双指互点开始/停止**三件事都长在它身上**
    /// （见 `WatchBotFace` 顶部那段），这里只负责接住它的两个回调。
    private var botPane: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)

            WatchBotFace(
                size: Self.dialSide * Self.botFraction,
                isRecording: model.isRecording,
                // ★ 十三改：待机摆哪个表情由 iPhone 的设置决定。
                style: faceStore.style,
                tint: styleStore.style.tint,
                meter: model.meter,
                // ★ 十一改：录音时计时贴着波显示（用户："下面附带录音时间"）。
                // ★ 十五改：`bpm:` 这个参数**删掉了** —— 那条波不再由心率驱动，
                //   理由见 `WatchVoiceWave` 顶部"十五改"那段。
                elapsedText: model.isRecording
                    ? WatchFormat.compactDuration(model.elapsed)
                    : nil,
                pokeTick: pokeTick,
                dizzyTick: dizzyTick,
                handGestureEnabled: prefs.pinchToRecord,
                onTap: handleTap,
                onHold: beginRecordingByHold,
                onToggle: handleToggle
            )
            // ⚠️ 九改把颜色接了回来，但**只接一个纯色**：`tint` 就是"外观"页选的
            //    那个颜色（用户："那个手表里的设置颜色则是眼睛 bot 的颜色，
            //    取消渐变"）。八改一度整条去掉过 —— 去掉的是**底板和渐变**，
            //    不是颜色本身；别再把 `style` 整个结构体传进来，那会让
            //    "这张脸会不会用到呼吸灯"变成一个每次都要重新确认的问题。

            caption

            // 给底部那排页点 + 待传提示留位，免得两者叠在一起。
            Spacer(minLength: 0).frame(height: 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 脸下面那行小字。空闲时是用法提示，录音时是**已写下的字节数**。
    ///
    /// ⚠️ 空闲时那行提示**不能省**。"长按 2 秒"是一个**隐形**的交互 ——
    /// 没有提示的话，第一次用的人只会戳一下、发现没反应、然后放弃。
    ///
    /// ★ 十一改：**录音计时搬到了波的下面**（见 `WatchBotFace.elapsedText`），
    /// 所以这里不再显示时间，当时换成了实测心率。
    ///
    /// ★★ 十五改：这一行从"心率 + 字节数"**退回只有字节数**。
    /// 心率不再驱动那条波之后（见 `WatchVoiceWave` 顶部"十五改"），它摆在这里的
    /// 唯一理由就消失了 —— 当初把它显示出来是为了让用户能确认"心率真的生效了"
    /// （用户看不见 72 和 75 的区别）。而它带来的一堆麻烦是真的：
    ///   · 心率读不到时要写一句"未佩戴手表"，可读不到的原因里最常见的其实是
    ///     **没给健康权限**，那句话会长期挂在一个不存在的故障上；
    ///   · 静息状态下 HealthKit 十几分钟才落一条样本，这个数字常年是旧值。
    /// ⚠️ 字节数留着：它是**唯一**一个"录音真的在往盘上写"的硬证据 ——
    ///   十五改之后那条波安静时是一条贴底的平线，光看它分不出"没声音"和"坏了"。
    @ViewBuilder
    private var caption: some View {
        if model.isRecording {
            Text(WatchFormat.bytes(model.currentBytes))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(styleStore.style.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monospacedDigit()
        } else {
            Text(L10n.Watch.holdToRecord)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// 长按满 2 秒（进度环已经由 `WatchBotFace` 自己收掉了）。
    private func beginRecordingByHold() {
        guard !model.isRecording else { return }
        // 抬手那一下会被 `Button` 当成轻点（见 `tapGateUntil` 那段）。
        tapGateUntil = Date().addingTimeInterval(0.5)
        model.toggleRecording()
    }

    /// 轻点。录音中 = 停止；空闲 = 只是戳一下。
    ///
    /// ⚠️ 空闲态**不开始录音**是刻意的："点一下就录"正是这次要改掉的毛病
    /// （抬手看表、袖口蹭一下都会录上）。要开始，请长按 2 秒、双指互点、或摇一摇。
    ///
    /// ★ 十二改之后"戳一下"的内容变了：`pokeTick` 现在会让那张脸**演一个随机
    /// 表情**（五档抽一个），不再是十改那种只有整体一弹的"单一的眼睛晃动"。
    /// 这一层不需要知道有哪些表情 —— 它只管把脉冲发出去（见 `WatchBotFace`
    /// 的 `pokeTick` 那段，那里解释了为什么不直接调方法）。
    private func handleTap() {
        guard Date() >= tapGateUntil else { return }
        if model.isRecording {
            model.toggleRecording()
        } else {
            pokeTick += 1
        }
    }

    /// 双指互点。开始 / 停止。
    ///
    /// 和轻点走同一个 `Button`，由 `WatchBotFace.handlePrimaryAction()` 按
    /// "这一下有没有伴随触摸"分出来（双指互点是隔空动作，没有触摸）。
    private func handleToggle() {
        guard Date() >= tapGateUntil else { return }
        model.toggleRecording()
    }

    // MARK: - 两侧滑动菜单

    /// 一页菜单。`items` 为空时给一句"去设置里加"，而不是一页空白 ——
    /// 空白页看起来像坏了。
    private func menuPane(_ items: [WatchHomeMenu]) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            if items.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text(L10n.Watch.quickMenuEmpty)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
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

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 一个菜单项。
    ///
    /// ★ 九改：图标颜色从"色板里循环取"改成**全用同一个颜色**
    /// （`WatchRingStyle.tint`）。原因是这一轮把"一个主题 = 一种颜色"定死了
    /// （见 `WatchRingStyle` 顶部）—— 循环取色时，三色盘（`activity`）会让
    /// 第 2 个菜单项拿到那道荧光绿，于是同一个主题下脸上是一种颜色、
    /// 菜单里是另一种颜色。那正是上一轮用户抱怨"绿色"的来源之一。
    private func menuTile(_ item: WatchHomeMenu) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(styleStore.style.tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.13)))
            Text(item.title)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.10))
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityLabel(item.title)
    }

    /// "编辑快捷菜单"入口。用虚线框和次要色，和上面那几个真菜单项区分开 ——
    /// 它不是"第 N 个菜单"，是"改菜单的地方"。
    private var editTile: some View {
        NavigationLink {
            WatchQuickMenuSettingsView()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                Text(L10n.Watch.quickMenuAdd)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(0.18),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.Watch.quickMenuAdd)
    }

    // MARK: - 横向翻页

    /// 翻页手势。**自己实现，不走 `TabView`** —— 理由见文件顶部"八改"那段。
    ///
    /// 三件事都在这里定：
    /// * 认不认（`pageDragSlop`）—— 划不到 24pt 就当抖动，不参与；
    /// * 翻不翻（`pageFlipDistance`）—— 划够 44pt 才真的换页；
    /// * 方向 —— 只认**明显偏横向**的划动（`abs(dx) > abs(dy)`）。竖直划动是
    ///   用户在蹭表冠或翻系统层，被这里吃掉会很莫名其妙。
    private var pageDrag: some Gesture {
        DragGesture(minimumDistance: Self.pageDragSlop)
            .onChanged { value in
                // ⚠️ 拖动过程必须**关掉动画**：这里是逐帧跟随手指，套上动画会
                //    变成"慢半拍的橡皮筋"。松手时那一小段归位才需要动画。
                var tx = Transaction()
                tx.disablesAnimations = true

                let raw = value.translation.width
                // 已经在头/尾还继续往外划 → 阻尼到 1/4。给一点"拉到头了"的手感，
                // 否则用户会以为卡住、然后划得更用力。
                let pastStart = page == 0 && raw > 0
                let pastEnd = page == 2 && raw < 0
                let damped = (pastStart || pastEnd) ? raw * 0.25 : raw

                withTransaction(tx) { dragX = damped }
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height

                // ★ 翻页这一下松手时，`Button` 会在**抬手那一刻**也触发一次它的
                //   action（这是 `Button` 的定义行为，不是 bug）。不挡掉的话，
                //   空闲态划一下屏幕，眼睛会莫名其妙弹一下 —— 明明什么都没点。
                //   复用长按那道的同一扇闸门，两个坑一个解法。
                tapGateUntil = Date().addingTimeInterval(0.35)

                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    if abs(dx) > abs(dy), abs(dx) > Self.pageFlipDistance {
                        page = min(2, max(0, page + (dx < 0 ? 1 : -1)))
                    }
                    // 没达标就归位 —— 这个"弹回去"本身就是"你划得不够"的反馈。
                    dragX = 0
                }
            }
    }

    // MARK: - 屏幕下沿

    /// 最下沿那一小摞：页点 + 待传提示。
    ///
    /// ⚠️ 两者**必须放在同一个 overlay 里**（而不是各挂一个 overlay）：两个
    ///    `alignment: .bottom` 的 overlay 会**叠在同一个位置**上，待传条一出现
    ///    就会盖住页点。
    private var bottomBar: some View {
        VStack(spacing: 3) {
            pageDots
            queueBar
        }
        .padding(.bottom, 1)
    }

    /// 三个小圆点，标出现在在哪一页。
    ///
    /// ★ 八改新增。用户报"左右滑不到菜单"，其中一半是功能坏（`.page` 不给横向
    /// 翻页，已修），另一半是**发现性**：屏幕上从来没有任何东西提示过这里能滑。
    /// 三个点是最省地方、也最不用解释的说法。
    ///
    /// ⚠️ 刻意**不做成可点的**：4pt 的点在 40mm 表上几乎点不中，做成按钮只会
    ///    带来"点了没反应"。它的职责是"告诉你能滑"，不是"替你滑"。
    private var pageDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(index == page ? 0.85 : 0.25))
                    .frame(width: 4, height: 4)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 待传提示条

    /// 屏幕最下沿那条细提示。**只在有待传条目时出现**，高度约一行字。
    ///
    /// 为什么不摊回一列列表：首页正中现在是 Bot，摊开会把它顶上去。
    /// 详情点进独立一页（`WatchQueueView`），两样都不冲突。
    @ViewBuilder
    private var queueBar: some View {
        if !model.pending.isEmpty {
            NavigationLink {
                WatchQueueView()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                    Text(L10n.Watch.pendingCount(model.pending.count))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(styleStore.style.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 2)
            .accessibilityLabel(L10n.Watch.pendingHeader)
        }
    }

    // MARK: - 摇一摇

    /// 按当前开关对准采集状态。**幂等** —— `onAppear` 和开关变化两处无脑调用。
    private func syncShakeDetector() {
        guard prefs.shakeToRecord else {
            shake.stop()
            return
        }
        shake.start { [model] in
            // 触发时给一记震动：这一刻人根本没在看屏幕（抬手就是晃），
            // 没有反馈就不知道到底录上了没有。用"开始/停止"两种不同手感，
            // 光靠震动能分辨出是开还是停。
            WKInterfaceDevice.current().play(model.isRecording ? .stop : .start)
            // ★ 十四改：眼睛**转圈圈**（用户："摇一摇眼睛会有转圈圈眩晕感
            //   增加交互"）。震动给手腕、眩晕给眼睛，两个通道一起才有"收到"。
            dizzyTick += 1
            // ⚠️ 真正的起停**往后挪 0.45 秒**：不挪的话录音态立刻换上那条波，
            //    眼睛刚转起来就被换掉了，"眩晕"根本看不见。
            //    0.45 秒落在转两圈的**前半段**（整段 0.9 秒）：开始录音时能看到
            //    眼睛先晕半圈、然后颜色漫上来；停止录音时波退场、眼睛带着
            //    后半圈眩晕回来。两条路都有戏份。
            //
            //    这个延迟是**加在感知上**的，但摇一摇本来就有约 0.9 秒的判定窗
            //    （`WatchShakeDetector.burstWindow`），用户对"摇一摇"的预期本来就
            //    不是即时的。再长就不行了 —— 那会读成"摇了没反应"。
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                model.toggleRecording()
            }
        }
    }
}

// MARK: - 待传页

/// 待传列表的独立页（从首页底部那条提示点进来）。
struct WatchQueueView: View {
    @EnvironmentObject private var model: WatchRecorderModel
    @EnvironmentObject private var link: WatchLink

    var body: some View {
        Group {
            if model.pending.isEmpty {
                // ★ 2026-10-16 七改：这一页现在能**从菜单直接进来**（它成了一个
                // 可添加的菜单项），所以"空"是常态，必须给空态 ——
                // 否则从菜单点进来只会看到一片黑。
                VStack(spacing: 5) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text(L10n.Watch.queueEmpty)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                List {
                    ForEach(model.pending) { clip in
                        // Queued or delivered-but-unconfirmed both read as "in flight";
                        // only a clip with neither state needs the retry affordance.
                        let isQueued = link.queuedNames.contains(clip.name)
                            || link.deliveredNames.contains(clip.name)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(clip.displayTitle)
                                .font(.caption2)
                                .lineLimit(2)
                            Text("\(isQueued ? L10n.Watch.sending : L10n.Watch.waiting) · \(WatchFormat.bytes(clip.bytes))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 10) {
                                if !isQueued {
                                    Button { model.retry(clip) } label: {
                                        Label(L10n.Common.retry, systemImage: "arrow.clockwise")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L10n.Common.retry)
                                }
                                Button(role: .destructive) { model.delete(clip) } label: {
                                    Label(L10n.Common.delete, systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L10n.Common.delete)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.Watch.pendingHeader)
    }
}

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
}
