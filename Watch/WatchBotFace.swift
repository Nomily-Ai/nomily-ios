import SwiftUI

// MARK: - 首页正中那张"脸"
//
// ★ 2026-10-16 七改（用户原话："类似 Grok Bot 一样，两个眼睛然后你参考一下他会
// 自然眨眼做的哪些动画……把当前首页的录音按钮去掉改成 bot 一样生动的，通过长按
// 点击它的眼睛 2s 才开始录音或者之前的手势交互跟摇一摇才开始录音跟停止录音"）：
//
// 首页正中原来是一只圆环按钮，点一下就开始录音。问题是"点一下就开始录"放在
// 手腕上太容易误触 —— 抬手看时间、袖口蹭一下都会录上。现在换成一个拟人的
// 小机器人：**长按它 2 秒**才开始，录音中轻点一下停。
//
// ─────────────────────────────────────────────────────────────────────────
// ## 这张脸的构成（四次改动之后的结论）
//
// ★ 八改：删掉了**圆角方底板**。用户的原话是"不要绿色，边框直接就 2 个眼睛"
// —— 有那块板子时它是一块彩色方块，把眼睛框在里面，像个 App 图标而不像一张脸。
// 从 Grok 那边也能印证这一条：他们的机器人是**黑底上两条白杠**，基本结构就是
// "简单几何形状 + 一双有表情的眼睛"（他们官方设计文里的说法），没有脸框。
//
// ★ 九改：**颜色回到眼睛上，但只回一半** —— 取值仍然是"外观"页选的色板，
// 然而只取**纯色**（`palette.solid`），不再有渐变（用户："那个手表里的设置颜色
// 则是眼睛 bot 的颜色，取消渐变"）。所以这一份现在收一个 `tint: Color`，
// 而不是整个 `WatchRingStyle`：这张脸只需要一个颜色，给它一整个样式结构体
// 反而会让"它到底会不会用到渐变/呼吸灯"变成一个每次都要重新确认的问题。
//
// ★★ 十改（八改/九改两次放慢都没解决的那个问题）：
// > `他的那个眼睛不是一直眨眼的，不需要一直眨眼，
// >  https://github.com/sam70361/aora-bot 你参考这个仓库里面的表情管理，
// >  只看眼睛就好，两个眼睛不要一直眨眼，手表里面`
//
// 于是去读了那个仓库（`mood-mates/` 与 `emotion-ball/` 两套同源引擎，纯 SVG +
// 原生 JS），把它的待机（`02 待机放空`）拆开看：
//
// ```js
// pool: [0, 8], poolMs: [9000, 16000], blinkMs: [6000, 14000], antics: true,
// body: { breathe: 0.012 },
// anims: [
//   { target: 'eyes', prop: 'lookX', type: 'glance', amp: 10, period: 4800 },
//   { target: 'eyes', prop: 'lookY', type: 'sine',   amp: 2,  period: 4100, phase: 1.1 }
// ]
// ```
//
// **★ 这一读把问题整个换了个方向。** 九改的思路是"把眨眼周期越拉越长"，
// 那条路已经走到头了 —— 因为根因不是**频率**，是下面这四条：
//
// 1. **节拍器**。九改是**固定 19.12 秒**一轮。固定周期是人眼最擅长抓的规律，
//    一旦被抓到，每一次眨眼都变成"它又按点眨了"，再慢也还是机械感。
//    参考实现的 `blinkMs: [6000, 14000]` 是**每次眨完重新抽一个区间内的随机
//    等待**（`this._blinkNext = now + rand(...)`），永远没有节拍。
// 2. **每轮必连眨**。九改是"两下里夹一次连眨"—— 一个周期里**必然**有两次开合。
//    参考实现是 `if (Math.random() < 0.14)` —— **只有 14% 概率**补第二下。
//    所以参考实现的绝大多数眨眼是**单下、300ms 的一闪**，视觉重量比九改轻一半。
// 3. **眨眼是唯一的动作**。九改里那 ±1.8% 的呼吸肉眼根本看不见，于是
//    19 秒里这张脸**完全静止**，然后突然"啪-啪"两下 —— 既死板又吵。
//    参考实现待机的主体动作是**目光游移**（`lookX` 左右各停留片刻、`lookY`
//    缓慢起伏），眨眼只是点缀。眼睛**从不静止**，所以"眨眼"根本不会被注意到。
// 4. **慢**。九改一次开合 0.45 秒（140+90+220）。参考实现总共 300ms，
//    而且睁眼时**过冲到 1.08 再落回 1** —— 那一下轻快的"弹开"正是"活着"的来源。
//
// ⚠️ 顺带算出一件反直觉的事：**两边眨眼的总频率其实差不多**。
//    九改 = 每 19.12 秒 2 次开合 = **1 次 / 9.6 秒**；
//    参考实现 = 1 次 / 6~14 秒、其中 14% 补一下 ≈ **1 次 / 9 秒**。
//    ⇒ 所以十改**不需要**再往慢里调，要换的是**规律性**和**动作构成**。
//    （十改仍然把区间抬到 9~20 秒，比参考实现更静 —— 用户连着两轮说"不要
//    一直眨"，在"参考机制"与"用户约束"冲突时以用户为准：机制照抄、数值从严。）
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 十三改（用户原话："需要在 Nomily AI APP 里面的设置里面增加一个
//    就是设置手表的首页眼睛的表情，把之前的 github 里面 gork bot 的表情放入到
//    Nomily ai 的设置里面支持放入他们的表情"）：
//
// 十二改那五个表情是**只读**的：轻点一下随机抽一个演一遍，用户挑不了。
// 这一轮把"表情"从**行为**提成**设置**：
//
//   · 表情库（九档）搬到了 `Sources/Services/Watch/BotFaceStyle.swift` ——
//     一个**两端共用**的文件，于是 iPhone 上那个选择器的预览和表上真正画出来的
//     那张脸**必然是同一套代码**，不会漂移。
//   · 这张脸多收一个 `style`：**常驻**的那一档，由用户在 iPhone 上选，
//     经 `WatchConnectivity` 推过来（见 `WatchFaceStore` / `WatchLink`）。
//   · 轻点时的池子从"写死的五档"改成"库里除了常驻那档之外的八档"——
//     抽到和常驻一样的那档等于"点了没反应"，那正是十二改要修掉的那个抱怨。
//
// ⚠️ **`EyeMood` 与 `EyeCurve` 两个私有类型整个删掉了**（前者是十二改的只读
//    表情池，后者是那段弧的形状）。它们的内容现在都在共用文件里，名字分别是
//    `BotFaceStyle` 与 `BotFaceEyeCurve`。留着旧的那份，就等于允许"表上画的"
//    和"手机上预览的"各走各的 —— 而两边各写一份几何，那种漂移是最难被发现、
//    也最伤人的一种（用户在手机上挑了个笑眼，抬腕发现是垂眼）。
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 十五改（用户原话：
//    "当前点击眼睛不是直接白屏，是那两个眼睛直接扩散全屏"）：
// 说的就是长按那两秒的画面。十四改画的是一个从眼睛位置长出去的实心圆，
// 用户读成"两个眼睛在扩散"，他要的是**整块屏幕一起变色**。改成整屏纯色
// 用透明度当进度。
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 十六改（用户原话：
//    "我要的是两个眼睛根据我按压下去然后自动根据我按压的地方两个眼睛融在一起，
//     然后再慢慢扩散整个屏幕然后跳转到录音那边"）：
// 十五改那片"整屏渐亮"被否了 —— 干净，但**没有来路**：颜色凭空从整块屏幕上
// 浮起来，和那两只眼睛没有关系。这一轮把顺序补上，长按拆成两段几何：
// **先融（前 32%）、再扩散（后 68%）**，融的目标点是**手指按下的地方**。
// 实现全在 `holdLayer`，参数怎么定的写在它上面那段。
// ─────────────────────────────────────────────────────────────────────────
// ## 让这张脸"活着"的几件事（十二改之后）
//
//   · **目光游移**（`runGazeLoop`，**这是待机的主体动作**）—— 两只眼睛**整体**
//     轻轻地左右看，到每一边**停留片刻**再换边，周期 4.8 秒。参考实现用
//     `tanh(2.8·sin)` 的平滑方波表达"停留久、过渡快"，这里用
//     `withAnimation(.easeInOut(0.9))` + 睡满半个周期等效实现。
//     ⚠️ 是**整对眼睛一起平移**，不是左右眼各看各的 —— 各看各的就成了斜视。
//   · **偶尔眨一下眼**（`runBlinkLoop`）—— 快闭（70ms）→ 停 70ms →
//     睁到 1.08 过冲（80ms）→ 150ms 落回 1。总共 **300ms**，单下为主，
//     14% 概率在 70ms 后再补一下。间隔走**两档**随机（3.5~6.5 秒为主、
//     22% 概率插一段 10~18 秒），见 `nextBlinkGap()`。
//   · **待机长什么样由用户定**（`style`，★ 十三改）—— 九档表情在 iPhone 的
//     设置里挑（`BotFaceStyle`），选中的那一档常驻在这张脸上。
//   · **轻点给一个表情**（`BotFaceStyle.tapPool`）—— 从库里抽一档演一遍，
//     抽完收回常驻档。这是**唯一**一个"眼睛形状真的变了"的动作；
//     参考实现那 20 个槽位里还有一大半搬不过来，理由写在
//     `Sources/Services/Watch/BotFaceStyle.swift` 顶部
//     （简单说：一只圆头竖条能表达的维度只有四个）。
//   · **呼吸** —— 整对眼睛极缓慢地缩胀（±1.8%，一次 3.6 秒）。幅度必须小：
//     大了像在跳动；小到"说不上来哪里在动、但它就是活的"才对。
//   · **录音时换一条音波**（`WatchVoiceWave`）—— 用户："开始录音的时候就是
//     一条音波跟心率一样的"。所以录音态**不是眼睛的变体**，是另一个形态：
//     尖峰高度是麦克风的真实电平，安静时靠一个"咚—哒"的底型维持心跳般的节律。
//   · **长按时的蓄力环** —— 按住不放时眼睛外面走一圈 2 秒进度弧。没有它，
//     用户不知道要按多久，也不知道自己那一下到底被没被识别到。
//
// ⚠️ **为什么不再用 `phaseAnimator`**（八改、九改都用它）：
//    `phaseAnimator` 的相序列会在**视图重建时重新求值**，所以给不出随机时长
//    —— 九改注释里那句"这里不能用随机数"说的就是这个限制。而这一轮的核心
//    恰恰是**随机**（每次眨完重新抽等待时间），所以整条改为 `Task` 循环 +
//    `withAnimation` 驱动。那个限制是真的、绕不过去，只能换机制。
//
// ⚠️ **参考实现里没跟过来的两件事**（有意，不是漏）：
//   · `lookY` 那条独立的正弦（振幅 2 / 画布 240 = 0.83%，相对眼心距只有 6.7%）
//     —— 换算到表盘上是 **±1.7pt**，肉眼看不出来。它的作用只是"别让目光是一条
//     完美的水平滑轨"，所以折成 `runGazeLoop` 里那个很小的纵向分量就够了，
//     不值得为它再养一个独立的相位。
//   · 眼形池轮换（`calm` / `calm2` 每 9~16 秒换一次）。那两者的差别是
//     宽 ×0.96、高 ×1.05 —— 也就是**4% / 5%**，比这里的呼吸还小，
//     却要多养一层缩放。本文件里叠的缩放已经有呼吸 × 被戳两层了，
//     再加一层没人算得清总幅度（`figureScale` 那段注释说过这件事）。
//
// ⚠️ 上面第二条**被十二改推翻了** —— 但推翻的方式和参考实现不一样：不是
//    "每 9~16 秒换一个 4% 的差别"（那种换法没人看得见，还要多养一个循环），
//    而是**轻点的那一下给一个整档、一眼能分辨的表情**，演完就回待机。
//    所以这里依旧没有"轮换循环"，只有一次性的 `mood`（见 `EyeMood`）。
//
// ─────────────────────────────────────────────────────────────────────────
// ★★ 2026-10-16 十二改（用户原话："当前颜色里面呢没有白色吗手表，然后录音时候
//    心率起伏需要波动幅度大且占比屏幕大，还有眼睛需轻触它会有各种表情而不是
//    单一的眼睛晃动，随机眨眼睛频率跟正常人眼渣样一样"）：
//
// 四条里跟这张脸有关的是两条：
//
// **1. 轻点要出表情，不只是弹一下。** 十改的 `pokeOnce()` 只做一件事：
//    整张脸弹 5%。用户把这句读成了"单一的眼睛晃动"—— 是对的，那一下
//    确实只是一个"我收到了"，没有任何**表情**可言。
//    现在轻点会**随机抽一个表情演一遍**（`EyeMood`，五档：∩拱笑眼 / ∪垂眼 /
//    圆睁 / 眯眼 / 斜瞪），进场弹、停约 0.8 秒、松着收回。整体的那一弹留着，
//    但收到 3% —— 它降级成"贴身的回应"，表情才是主角。
//
// **2. 眨眼频率改回"正常人"。** 十改按用户连着两轮的"不要一直眨眼"从严取了
//    9~20 秒，均值约 1 次 / 15 秒。用户这一轮明确要"跟正常人一样"，于是换成
//    **两档**分布（`blinkGapNear` / `blinkGapFar`）—— 理由和算术写在
//    `nextBlinkGap()` 那边，一句话：人眨眼不是均匀随机的，是"密的里面偶尔
//    插一段长的"。均值约 1 次 / 7 秒（≈ 8.6 次/分），正好是**人盯着屏幕时**
//    的那一档，也正是此刻用户看这块表的姿势。
//    ⚠️ 十改"别再回头调固定周期"那条约束**没有**被违反：改的是区间，机制
//       仍然是"每次眨完重新抽"，没有任何固定周期。
//
// ## 手势为什么全在这个类型里，而不是散在首页
// 长按开始、轻点停止、双指互点开始/停止 —— 三件事的**落点都是这张脸**。
// 拆成"首页挂长按、脸里管动画"会让"按下时脸该有什么反应"这个问题横跨两个
// 文件；而且双指互点要求落点是一个真正的 `Button`（`handGestureShortcut`
// 只对按钮类控件生效），所以这里干脆用 `Button` 把眼睛包起来，
// 长按挂在同一个 `Button` 上 —— 三件事于是只有一个真相源。
//
// ⚠️ **always-on（`isLuminanceReduced`）时必须全部停掉**：降亮度的表盘上
// 动画既看不清也费电，而"循环动画"恰好是最费电的那一类。停下时给一张**静态
// 的睁眼脸** —— 不是藏起来，表盘上还得看得出这是什么。
//
// ⚠️ 八改去掉了底板，所以**可点区域必须自己补**（`.contentShape`，见 `body`）。
//    不补的话命中区会缩到那两只胶囊上 —— 一个"要按住 2 秒"的交互配一个小
//    命中区，用户会得出"我按住了但没反应"的结论。
struct WatchBotFace: View {
    /// 这张脸的**名义**边长（不含外面的蓄力环）。
    ///
    /// ⚠️ 八改之后它不再是"底板边长"（底板没了），而是眼睛/音波的**外接尺寸
    /// 基准** —— 所有比例仍然按它取，换表不用重算。
    let size: CGFloat
    let isRecording: Bool
    /// 首页**常驻**的那个表情。用户在 iPhone 的设置里挑，经 WatchConnectivity
    /// 推过来（★ 十三改新增，见文件顶部那段）。
    ///
    /// ⚠️ 它是"待机长什么样"，**不是**"轻点演什么" —— 后者仍然是一次性的
    ///    `mood`，见 `playRandomMood()`。
    let style: BotFaceStyle
    /// 眼睛（以及录音时那条音波）的颜色。
    ///
    /// 来源是"外观"页选的色板**纯色**（`WatchRingStyle.palette.solid`）。
    /// ⚠️ 只传一个颜色、不传整个 `WatchRingStyle`：见文件顶部"九改"那段。
    let tint: Color
    /// 录音时的实时电平，转给 `WatchVoiceWave`。
    ///
    /// ⚠️ 空闲态用不上它 —— 它会一路传到 `WatchVoiceWave`，而那个视图只在录音态
    /// 存在，所以空闲时电平的变化不会拖着这张脸重绘。
    let meter: WatchAudioMeter
    /// 录音中显示在音波**正下方**的计时（`mm:ss`）。空闲态传 `nil`。
    ///
    /// ★ 十一改新增（用户："下面附带录音时间如果启动录音了的"）。
    ///
    /// ⚠️ 为什么由外面传字符串进来、而不是把 `TimeInterval` 传进来自己格式化：
    ///    格式化的规则（小时要不要出现、补不补零）属于首页那份 `WatchFormat`，
    ///    这里只负责摆位置。传字符串，脸上就仍然不懂"时间"这个概念。
    let elapsedText: String?
    /// 空闲态被轻点的次数。首页 +1，这里做一次"弹一下"。
    ///
    /// ⚠️ 为什么不直接暴露一个 `poke()` 方法给首页调：`WatchBotFace` 是值类型，
    /// 首页在 `body` 里内联构造它，拿不到那个实例的引用。用一个单调递增的
    /// 计数当触发器，是 SwiftUI 里"外部给子视图发一次脉冲"的标准做法。
    let pokeTick: Int
    /// 摇一摇触发的次数。首页 +1，这里让眼睛**转圈圈**（见 `playDizzy()`）。
    ///
    /// ★ 十四改新增（用户："手表的摇一摇改成摇一摇眼睛会有转圈圈眩晕感
    /// 增加交互"）。用计数当触发器的理由同 `pokeTick` —— 这张脸是值类型，
    /// 首页在 `body` 里内联构造它，拿不到实例引用。
    let dizzyTick: Int
    /// 双指互点能不能开/关录音。由 `WatchRecordingPrefs.pinchToRecord` 拨过来。
    let handGestureEnabled: Bool
    /// 轻点（手指真的碰到了脸）。录音中 = 停止；空闲 = 首页决定要不要只是戳一下。
    let onTap: () -> Void
    /// 长按满 2 秒。
    let onHold: () -> Void
    /// **双指互点**。开始 / 停止。
    ///
    /// ⚠️ 为什么必须和 `onTap` 分开：双指互点（食指拇指捏合）和手指轻点会
    /// 落到**同一个** `Button` 的 action 上 —— `handGestureShortcut` 的定义
    /// 就是"把双指互点绑到这个控件的 primary action"（见 `PrimaryHandGesture`）。
    /// 也就是说这一层拿不到"这次到底是哪种输入"这个事实，只能自己推。
    /// 推法见 `handlePrimaryAction()`。
    let onToggle: () -> Void

    /// always-on 降亮度。见文件顶部那段。
    @Environment(\.isLuminanceReduced) private var dimmed

    /// 呼吸用。一次 `false → true` 翻转 + `repeatForever`，插值交给渲染服务器。
    @State private var breathe = false
    /// 眨眼开合度。1 = 全睁，0.05 = 闭合，可以短暂超过 1（过冲）。
    ///
    /// ★ 十改新增。八改/九改用的是 `phaseAnimator` 逐相位驱动，这里改成
    /// **普通状态 + `Task` 循环里逐个 `withAnimation` 赋值** —— 理由见文件顶部
    /// "为什么不再用 `phaseAnimator`"（它给不出随机时长）。
    @State private var openness: CGFloat = 1
    /// 空闲态的目光偏移。整对眼睛一起平移，**不是**左右眼各看各的。
    @State private var gaze = CGSize.zero
    /// 待机那两条循环的把手（眨眼 + 目光），各一个。
    ///
    /// ⚠️ 为什么是**两个** `Task` 而不是一个 `withTaskGroup`：`addTask` 的闭包是
    ///    `@Sendable`，捕获 `self`（一个含若干闭包的视图结构体）会踩并发检查，
    ///    这个工程是零告警的，不给自己找这个麻烦。
    ///
    /// ⚠️ 为什么不用 `.task(id:)`：同理 —— 那个 modifier 的闭包也是 `@Sendable`。
    ///    这里的 `Task {}` 带 `_inheritActorContext`（本文件 `pokeOnce()` 已在用），
    ///    捕获 `self` 是继承主 actor 的，顺带也就能主动取消。
    @State private var idleLoop: Task<Void, Never>?
    @State private var gazeLoop: Task<Void, Never>?
    /// 被戳一下时的弹起量。0 = 原状。
    ///
    /// ⚠️ 十二改把幅度收到 **3%**（原来 5%）：它不再是"被戳"的**全部**表现 ——
    ///    主戏换成了那个随机表情（`mood`），它只负责给一下贴身的回应。
    ///    留在 5% 就又会读成用户说的那种"单一的眼睛晃动"（见 `figureScale`）。
    @State private var poke: CGFloat = 0
    /// 轻点抽到的那个表情。`nil` = 待机（画 `style` 那一档）。
    ///
    /// ★ 十二改新增（用户："眼睛需轻触它会有各种表情而不是单一的眼睛晃动"）。
    /// ★ 十三改：类型从私有的 `EyeMood` 换成共用的 `BotFaceStyle` —— 直接读
    ///   让它和"设置里选的那一档"是同一个枚举，于是池子可以是"库里除常驻之外
    ///   的其余几档"，而不是一份要跟着库一起维护的独立名单。
    @State private var mood: BotFaceStyle?
    /// 表情那条 `Task` 的把手。
    ///
    /// ⚠️ 连点两下时必须**先取消上一条**：两条 `Task` 各自睡 0.8 秒再退场、
    ///    互不知情，先醒来的那条会把**刚刚进场的新表情**一起抹掉 ——
    ///    表现为"连点两下反而什么都没出来"。
    @State private var moodTask: Task<Void, Never>?
    /// 眼睛**转圈圈**转到多少度了。0 = 没在转。
    ///
    /// ★ 十四改新增，见 `playDizzy()`。
    @State private var dizzyAngle: Double = 0
    /// 眩晕那条 `Task` 的把手。连摇两次必须先取消上一条，理由同 `moodTask`。
    @State private var dizzyTask: Task<Void, Never>?
    /// 长按进度 0...1。
    ///
    /// ★ 十四改：它驱动的不再是那圈"2 秒进度弧"，而是一片铺满屏幕的颜色。
    /// ★ 十五改：那片颜色的**透明度**就是它。
    /// ★★ 十六改：它现在驱动的是**两段几何**（见 `holdLayer`）——
    ///   前 32% 把两只眼睛揉成一团，后 68% 把那一团扩散到铺满全屏。
    @State private var holdProgress: CGFloat = 0
    /// 手指按下的位置（**这张脸的局部坐标**）。`nil` = 还没按过。
    ///
    /// ★★ 十六改新增（用户："两个眼睛自动根据我按压的地方两个眼睛融在一起"）。
    /// 它只回答"往哪儿融"，不参与任何判断 —— 长按计时仍然完全归
    /// `LongPressGesture` 管。
    ///
    /// ⚠️ 抬手**不清空**：`holdProgress` 回退的那 0.16 秒里，两只眼睛还要按这个
    ///    点往回走。清空会让它们在回程中途改道去脸中心。下一次按下时覆盖它。
    @State private var pressPoint: CGPoint?
    /// 长按走满、录音已经开始之后，那片颜色**淡出**用的开关。
    ///
    /// ⚠️ 不能把 `holdProgress` 直接归零：那一刻用户刚松手、画面正要切到
    ///    录音态，一片已经铺满屏幕的颜色"啪"地消失会闪一下。让它**先铺满、
    ///    再淡出**（0.5 秒），波就在它淡出的同时接上来 —— 这正是用户要的
    ///    "占满全屏**然后**显示心率时间波纹"。
    ///    ⚠️ 十五改把 `holdProgress` 改成了那片颜色的**透明度**；十六改又把它
    ///    改成**两段几何的进度**，所以"铺满"与"淡出"现在分别由
    ///    `holdLayer` 的绘制内容和这一层的 `sweepFading` 各管各的。
    @State private var sweepFading = false
    /// 手指是否正按在眼睛上。由 `LongPressGesture.updating` 驱动。
    @GestureState private var holding = false
    /// 最近一次"手指真的碰到了脸"的时刻（按下或抬起都会更新）。
    ///
    /// ★ 这是区分**手指轻点**和**双指互点**的唯一依据 —— 见
    /// `handlePrimaryAction()`。双指互点是**隔空**动作，整个过程不会产生任何
    /// 触摸事件，所以"刚刚有过触摸"就等于"这是手指点的"。
    @State private var lastTouchAt = Date.distantPast

    /// 长按多久才开始录音。
    ///
    /// 2 秒是用户点名的数字。它也正好落在"不容易误触"和"不觉得在等"之间：
    /// 抬手看表那一下通常 1 秒内就结束了，够不着 2 秒。
    static let holdSeconds: TimeInterval = 2.0
    /// 长按期间允许的手指抖动（pt）。超过就判定为"在滑页"而不是"在按住"。
    ///
    /// ⚠️ 八改从 26 调到 **34**：首页现在是自己实现的横向翻页（见
    /// `WatchRecorderView.pageDrag`），它要划出 24pt 才认。两个阈值必须**分开**
    /// —— 24 到 34 这一段是"既不算翻页、也不算取消长按"的缓冲带。
    /// 如果两个数撞一起，手一抖就会在"开始录音"和"翻页"之间二选一。
    private static let holdSlop: CGFloat = 34

    // MARK: 待机的节奏（十二改）
    //
    // 数值来源见文件顶部"十改"与"十二改"那两段：机制照抄 `aora-bot` 的待机，
    // 数值按用户的实际反馈走 —— 十改从严（"不要一直眨眼"），
    // 十二改回到"正常人"（"随机眨眼睛频率跟正常人一样"）。
    //
    // ⚠️ 为什么是"**每次重新抽**"而不是一个固定周期：见顶部第 1 条。
    //    固定周期=节拍器，再长也会被读出来。这里 `Task.sleep` 睡一个随机值，
    //    醒过来眨一下、再抽下一个 —— 结构上就没有节拍可言。
    /// 两次眨眼之间的间隔（秒）—— **两档**，不是一档。
    ///
    /// ★ 十二改：原来只有一档 `9 ... 20`，现在拆成"近"和"远"两档
    /// （用户："随机眨眼睛频率跟正常人眼渣样一样"）。
    ///
    /// ## 为什么必须是两档
    /// 人眨眼**不是均匀随机**的：绝大多数间隔挤在几秒内，但会时不时插进一段
    /// 十几秒的长间隔（走神、专注、思考时眨眼会明显变少）。用一个均匀区间去
    /// 拟合这种分布，无论把区间调到哪儿都只能命中一半 ——
    /// 调密了像在用秒表，调疏了像死鱼眼。两档正好把"密的多数"和"疏的少数"
    /// 分开表达。
    ///
    /// ## 数值怎么来的
    /// | 状态 | 次数/分 | 间隔 |
    /// |---|---|---|
    /// | 放松交谈 | 15~20 | 3.0~4.0s |
    /// | **盯着屏幕 / 专注** | **5~7** | **8.6~12s** |
    /// | 静息均值 | 12~15 | 4.0~5.0s |
    ///
    /// ⇒ 近档取 **3.5~6.5**（≈ 人的静息那一档）、远档取 **10~18**
    ///   （≈ 盯着屏幕那一档）、22% 概率走远档。
    ///   加权均值 ≈ 0.78 × 5 + 0.22 × 14 ≈ **7.0 秒 ≈ 8.6 次/分**。
    ///
    /// ⚠️ 十改那条"别再回头去调那个固定周期"的约束**没有被违反**：改的是
    ///    **随机的区间与其分布**，机制仍然是"每次眨完重新抽一个值"，
    ///    结构上不存在任何固定周期。任何"固定时长 + `repeatForever`"都仍然是
    ///    禁的（那正是八改变成节拍器的原因）。
    /// ⚠️ 两档在视觉上各有一件别干的事：近档**不要**压到 2 秒以内（那就成了
    ///    抖动，而不是眨眼），远档**不要**拉到 20 秒以上（那就退回十改那种
    ///    "死鱼眼"观感了 —— 十改收到的就是这条反馈）。
    private static let blinkGapNear: ClosedRange<Double> = 3.5 ... 6.5
    private static let blinkGapFar: ClosedRange<Double> = 10 ... 18
    /// 走"远"档的概率。22% ≈ 平均每四五次眨眼插一段长的。
    private static let blinkGapFarChance: Double = 0.22
    /// 眨完之后再补一下的概率。参考实现的 `Math.random() < 0.14`。
    ///
    /// ⚠️ 这个数**不要往上调**。九改是"每轮必连眨"（= 100%），那正是
    ///    "一直在眨眼"观感的一半来源 —— 连眨应该是例外，不是节拍。
    private static let doubleBlinkChance: Double = 0.14
    /// 目光在一边停多久、换边用多久（秒）。参考实现 `lookX` 周期 4800ms，
    /// 其中约 1.4 秒停在一边、约 1.0 秒过渡 —— 这里 1.5 + 0.9，基本一致。
    private static let gazeHold: Double = 2.4
    private static let gazeShift: Double = 0.9
    /// 目光左右能走多远（相对 `size`）。
    ///
    /// 参考实现 `amp 10` / 眼心距中线 `30` = **1/3**。本文件眼心距是
    /// `0.235 × size`，照搬会到 ±0.078 × size（40mm 上约 ±9pt），
    /// 在表盘上太晃。取它 **约 55%**：40mm 上 ±5.3pt、49mm 上 ±6.8pt，
    /// 看得出在"看来看去"、又不会像在找东西。
    private var gazeAmpX: CGFloat { size * 0.045 }
    /// 目光的纵向分量。只为了让移动不是一条**完美的水平滑轨** ——
    /// 这么小是看不出来的，见文件顶部"参考实现里没跟过来的两件事"。
    private var gazeAmpY: CGFloat { size * 0.011 }

    // MARK: 比例
    //
    // ★ 十三改：眼睛的尺寸与间距**搬去了 `BotFaceMetrics`**（共用文件
    // `Sources/Services/Watch/BotFaceStyle.swift`）。
    //
    // ⚠️ 搬家的理由不是整理，是**必须**：iPhone 上那个表情选择器要摆预览，
    //    而"预览里那只眼睛多大"和"表上那只眼睛多大"必须是**同一个算式** ——
    //    各写一份的话，用户挑的表情和真机看到的就不成比例，而这种不一致
    //    在两张不同尺寸的屏幕上极难被发现。
    //
    // ℹ️ 八改曾经把眼睛整体放大过一档（宽 0.185 → 0.235、高 0.285 → 0.375）：
    //    原来那组尺寸是配着圆角方底板算的，底板一去掉，眼睛就是这张脸的全部，
    //    按原尺寸会显得又小又空。那组数现在是 `BotFaceMetrics` 的默认值。

    var body: some View {
        // 用 `Button` 而不是裸视图：`handGestureShortcut`（双指互点）
        // 只对按钮类控件生效 —— 见文件顶部那段。
        //
        // ⚠️ 这一个 action **同时**收两种输入：手指轻点、以及双指互点。
        //    所以得靠 `handlePrimaryAction()` 再分一次 —— 不能直接把某一种
        //    的行为写在这儿。
        Button(action: handlePrimaryAction) {
            ZStack {
                figure
                    .scaleEffect(figureScale)
                    // 长按期间把位置让给 `holdLayer` 里那两只（见 `figureOpacity`）。
                    .opacity(figureOpacity)
                    .animation(.spring(response: 0.34, dampingFraction: 0.62), value: isRecording)
                // ★ 十五改：那片颜色画在**最上层**（十四改它在最下层）。
                // ★★ 十六改：它同时负责"把两只眼睛揉成一团"和"扩散满屏"，
                //    所以从按住的第一帧就要接管眼睛 —— 于是 `figure` 那两只
                //    必须让位（`figureOpacity`）。
                holdLayer
            }
            // 外层这个 frame 就是这张脸的**名义**边界（`BotFaceMetrics` 都按它取比例）。
            // ⚠️ 它**不裁**内容 —— 长按那片颜色要漫到屏幕边缘，靠的就是这一点。
            .frame(width: size * 1.14, height: size * 1.14)
            // ★ 八改新增，**不能省**：底板没了之后，`Button` 默认只把画出来的
            //   形状当命中区，也就是那两只胶囊（录音时则是那条波）。
            //   长按 2 秒本来就要按稳，命中区缩成这样，用户会觉得
            //   "明明按住了却没反应"。
            //   补一个方形命中区，把整个 `frame` 都变成可点。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 长按与"轻点"**同时**识别：轻点要求快速抬起，长按要求按住不动，
        // 两者本来就不会撞在同一串动作上。用 `simultaneousGesture` 而不是
        // `.gesture`，免得长按把 `Button` 自己的 tap 顶掉（那会让"轻点停止"
        // 在长按识别期间失效 —— 正好是用户最需要它的时候）。
        .simultaneousGesture(holdGesture)
        // ★★ 十六改：只用来回答"手指按在哪儿"。
        // ⚠️ 必须和长按**并列**（`simultaneousGesture`），不能串进 `holdGesture`
        //    里：`LongPressGesture` 不给坐标，而"按下去的那一刻手指在哪儿"
        //    只有拖拽手势知道 —— 串起来就得等长按结束才拿得到，那时眼睛
        //    早就该融完了。
        .simultaneousGesture(pressLocation)
        // ★ 双指互点（食指拇指捏合）= 开/关录音。
        //
        // ⚠️ 关掉开关时必须**显式** `isEnabled: false`，不能"不管" ——
        //    watchOS 11 上系统仍会把双指互点派给主按钮，用户关了也照触发。
        //    10.1~10.x 上系统自己派发、没有 API 可关（见 `PrimaryHandGesture`）。
        .modifier(PrimaryHandGesture(enabled: handGestureEnabled))
        .accessibilityLabel(isRecording ? L10n.Watch.stop : L10n.Watch.record)
        .accessibilityValue(isRecording ? L10n.Watch.recordingBusy : L10n.Watch.holdToRecord)
        .onAppear { startIdleMotion() }
        .onChange(of: pokeTick) { _, _ in pokeOnce() }
        .onChange(of: dizzyTick) { _, _ in playDizzy() }
        .onChange(of: holding) { _, pressing in
            // ★ 无论按下还是抬起都记一笔：Button 的 action 是在**抬起**那一刻
            //   才触发的，只记按下的话，"按住一会儿再松手"这串动作会因为
            //   时间差过大而被误判成双指互点（那会让"按 1 秒又放弃"变成
            //   "开始录音"）。
            lastTouchAt = Date()

            // 录音中长按不点亮进度 —— 否则用户会以为"再按两秒能再开始一次"。
            guard !isRecording else { return }
            if pressing {
                // ★ 十四改：先把上一轮的残留清掉（**不带动画**），再从头长出来。
                //    上一次长按结束时 `holdProgress` 停在 1、`sweepFading` 是 true
                //    （那片颜色只是淡出了、尺寸没变）。不清的话，这一按就直接从
                //    "铺满全屏"开始 —— 用户看到的不是"颜色在长"，而是一闪。
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) {
                    holdProgress = 0
                    sweepFading = false
                }
                // 进度走满正好是 2 秒，和手势的 minimumDuration 对齐。
                // 两者一旦不一致，就会出现"颜色还没铺满就开录"或者
                // "铺满了却不开录"—— 两种都会让用户不再信任这个动作。
                withAnimation(.linear(duration: Self.holdSeconds)) { holdProgress = 1 }
            } else {
                // ⚠️ 长按**成功**那一路不要在这里收：`onEnded` 已经用 0.5 秒的
                //    淡出接过了这件事。这里再收一遍（0.16 秒）会把那片颜色在
                //    0.16 秒里抽掉 —— 用户要的"铺满全屏**然后**再看波"就变成
                //    "闪一下白"。
                //    残留的 `holdProgress` / `sweepFading` 不用管：下一次按下时
                //    那个 `if pressing` 分支会**不带动画**地把它们清零。
                guard !sweepFading else { return }
                withAnimation(.easeOut(duration: 0.16)) { holdProgress = 0 }
            }
        }
        .onChange(of: isRecording) { _, _ in
            // ⚠️ 十改：两个分支都调 `startIdleMotion()`，不再各写各的。
            //    因为"录音时要做什么"已经不只是"把呼吸停平"—— 现在还有两条
            //    `Task` 循环要收。让唯一的开关去判断，比在这里复制一份判断条件安全
            //    （复制的那份迟早会漏掉新加的那条循环）。
            //
            //    顺带：录音态那条音波有自己的节律（心跳），再叠一层缓慢缩胀
            //    就成了两种周期打架 —— `startIdleMotion()` 会把 `breathe` 停平。
            //
            // ⚠️ 九改之前这里还起了一个 `sway`（眼睛左右错相位浮动）。录音态
            //    现在整条换成音波，眼睛根本不在场，那个状态跟着一起删了。
            startIdleMotion()
        }
        .onChange(of: dimmed) { _, _ in
            // 降亮度：全部停到静止位。见文件顶部那段。同样的理由 —— 交给唯一的开关。
            startIdleMotion()
        }
        .onDisappear {
            // 离开首页时把循环收掉。不收的话这一对 `Task` 会一直挂着，
            // 而它们每一轮都在写一个已经没人看的 `@State`。
            idleLoop?.cancel()
            gazeLoop?.cancel()
            // ★ 十二改：表情那条也要收 —— 同上。
            moodTask?.cancel()
            // ★ 十四改：眩晕那条同样要收。
            dizzyTask?.cancel()
        }
    }

    // MARK: - 手势

    /// 那个 `Button` 的 action。**一次收两种输入，这里再分一次**。
    ///
    /// * **手指轻点** —— 刚刚一定有按下/抬起，`lastTouchAt` 就在几毫秒前。
    ///   走 `onTap`（录音中 = 停止；空闲 = 戳一下）。
    /// * **双指互点** —— 食指与拇指在**空中**捏合，整个过程不产生任何触摸事件，
    ///   `lastTouchAt` 停在很久以前。走 `onToggle`（开始/停止）。
    ///
    /// ## 为什么用时间窗而不是别的判据
    /// 没有别的判据可用：两种输入在 SwiftUI 这一层就是同一个闭包，系统不给
    /// 来源信息。"最近 0.4 秒内有没有触摸过"是唯一可靠的区分 ——
    /// 双指互点是隔空动作，这一点是**物理事实**，不是启发式猜测。
    ///
    /// ⚠️ 阈值不能太小：手指抬起与 action 触发之间隔着一两帧。0.4 秒对这两者
    ///    都足够宽（正常间隔 < 50ms），又远小于"用户隔空捏一下再点屏幕"的最短
    ///    间隔（人做不到 0.4 秒内先捏再点）。
    private func handlePrimaryAction() {
        let touched = Date().timeIntervalSince(lastTouchAt) < 0.4
        if touched {
            onTap()
        } else {
            onToggle()
        }
    }

    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: Self.holdSeconds, maximumDistance: Self.holdSlop)
            .updating($holding) { current, state, _ in state = current }
            .onEnded { _ in
                // ★ 十四改：颜色**先铺满、再淡出**，而不是"环收掉"。
                //    十三改之前这里把进度弧在 0.12 秒里收掉，因为一圈"已走满"的弧
                //    留着会和录音态的辉光打架。现在换成整片颜色：它淡出的那 0.5 秒
                //    正好盖住"眼睛 → 波"这个切换，读起来就是
                //    "颜色漫过屏幕 → 波在颜色退去后亮起来"。
                withAnimation(.easeOut(duration: 0.5)) { sweepFading = true }
                onHold()
            }
    }

    /// 只负责回答"手指按在哪儿"。不做判断、不参与计时。
    ///
    /// ★★ 十六改新增（用户："两个眼睛自动根据我按压的地方两个眼睛融在一起"）。
    ///
    /// ## 为什么是 `minimumDistance: 0` 的拖拽
    /// * 轻点（`SpatialTapGesture`）要等**抬手**才给坐标，而我们要的是
    ///   "按下去的那一刻手指在哪儿"；
    /// * `LongPressGesture` 压根不给坐标。
    ///
    /// ## 为什么只在第一帧记一次
    /// 手指按住 2 秒不可能完全不动。每一帧都更新的话，那两只眼睛会跟着手指
    /// 一点点漂 —— 看起来像黏手，而不是"朝按下的地方融过去"。
    private var pressLocation: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard pressPoint == nil else { return }
                pressPoint = value.startLocation
            }
    }

    /// 起停**全部**空闲动作：呼吸 + 目光游移 + 眨眼 + 表情。
    ///
    /// ★ 十改之前这里只管呼吸，眨眼由 `phaseAnimator` 自己跑（视图在就一直在眨）。
    /// 现在眨眼和目光都是 `Task` 循环，必须有人**显式起、显式停** —— 于是这里
    /// 成了唯一的开关：降亮度、录音中、离开页面，都从这里收。
    /// ★ 十二改之后又多了一个被管的对象：表情（`moodTask`）。它**不是**循环，
    /// 是一次性的 `Task`；但"录音一开始就作废"这件事和那两个循环完全一样，
    /// 所以照样挂在这个开关上 —— 与其在 `onChange(of: isRecording)` 里再补一句
    /// 取消，不如让唯一的开关统一收（复制的那份迟早会漏掉新加的东西）。
    ///
    /// ⚠️ 每一次进来都**先取消旧的**再决定要不要起新的。不取消就会叠：
    ///    `isRecording` 与 `dimmed` 都可能连着变两次，而每个循环都是
    ///    "睡一会儿 → 眨一下"的死循环，叠起来的观感是眨眼频率翻倍。
    ///
    /// ⚠️ 八改把一次"吸—呼"从 2.6 秒放慢到 **3.6 秒**（用户："节奏慢点"）。
    ///    十改之后呼吸**不再是**这张脸最持续的动作了（最持续的是目光），
    ///    但快一点照样会被读成"在喘"，而且会和目光、眨眼叠起来显得很忙。
    private func startIdleMotion() {
        idleLoop?.cancel()
        idleLoop = nil
        gazeLoop?.cancel()
        gazeLoop = nil
        // ★ 十二改：表情那条 `Task` 也归这里管。录音开始 / 降亮度时要把正在演的
        //   表情当场收掉 —— 它改的是眼睛的尺寸和形状，而录音态眼睛根本不在场，
        //   挂着它会等录音结束之后突然蹦出来一个上上个动作的表情。
        moodTask?.cancel()
        moodTask = nil

        guard !dimmed, !isRecording else {
            // 回到静止位。降亮度要一张静态睁眼脸，录音态眼睛根本不在场 ——
            // 两种都靠这四行把状态摆平，不留半路停住的目光、也不留半路演完的表情。
            withAnimation(.linear(duration: 0.2)) {
                breathe = false
                openness = 1
                gaze = .zero
                mood = nil
            }
            return
        }

        withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
            breathe = true
        }
        // ★ 眼睛一进场就从"正在往右看"的位置开始，而不是从正中起步 ——
        //   从正中起步的话，用户抬腕看到的第一秒是一段"眼睛从中间滑出去"，
        //   像是刚刚被唤醒。参考实现的 lookX 也是常驻的、没有起始位。
        gaze = CGSize(width: gazeAmpX, height: gazeAmpY)
        idleLoop = Task { await runBlinkLoop() }
        gazeLoop = Task { await runGazeLoop() }
    }

    // MARK: - 待机循环
    //
    // 两条循环并排跑，互不干涉：
    //   · `runGazeLoop`  每 4.8 秒换一次边（眼睛的**持续**动作）
    //   · `runBlinkLoop` 睡一个随机间隔（近档 3.5~6.5s / 远档 10~18s）→ 眨一下 → 再抽
    //
    // ⚠️ 两个周期**刻意不相等**（4.8 vs 两档随机），这样它们的相对相位永远
    //    在变 —— 两条等周期的动作会锁相，锁相之后整张脸会开始"打拍子"，
    //    比单一的节拍器更明显。参考实现里 lookX(4.8s) / lookY(4.1s) 也是
    //    刻意取了不同的周期。

    /// 目光：在左右两边各停留片刻，快速换边。参考实现的 `glance`（`tanh(2.8·sin)`）。
    private func runGazeLoop() async {
        var rightSide = true
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.gazeHold * 1_000_000_000))
            guard !Task.isCancelled else { return }
            rightSide.toggle()
            // 纵向只走很小一段，而且是**跟着横向前后**的 —— 见 `gazeAmpY`。
            withAnimation(.easeInOut(duration: Self.gazeShift)) {
                gaze = CGSize(
                    width: rightSide ? gazeAmpX : -gazeAmpX,
                    height: rightSide ? gazeAmpY : -gazeAmpY
                )
            }
        }
    }

    /// 眨眼。**等待时间是每次重新抽的**，这是十改的核心 —— 见文件顶部第 1 条。
    ///
    /// ⚠️ 参考实现是从"这一下眨眼的**开始**时刻"往后排下一次
    ///    （`this._blinkNext = now + rand(...)`）。这里是从**眨完之后**往后排。
    ///    差别只在连眨那一下（约 0.8 秒），量级上无所谓，但有意选"眨完之后"
    ///    —— 这样"两次眨眼之间"的口径是干净的：用户感知的间隔本来也不包含
    ///    眨眼本身占掉的那 300ms。
    ///
    /// ★ 十二改只换了一件事：`Double.random(in: blinkWait)` → `nextBlinkGap()`。
    ///    循环结构、连眨概率、`blinkOnce()` 的关键帧**一格没动**。
    private func runBlinkLoop() async {
        while !Task.isCancelled {
            let wait = Self.nextBlinkGap()
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await blinkOnce()

            if Double.random(in: 0 ..< 1) < Self.doubleBlinkChance {
                // 70ms 后补一下。参考实现是 `{at: t+370}`，而这边的第一下
                // 300ms 就结束了 —— 所以间隔同样是 70ms。
                try? await Task.sleep(nanoseconds: 70_000_000)
                guard !Task.isCancelled else { return }
                await blinkOnce()
            }
        }
    }

    /// 眨一次。关键帧照抄参考实现的 `_blinkNow`：
    /// `合上 → 停 70ms → 睁到 1.08 过冲 → 300ms 落回 1`。
    ///
    /// ⚠️ **总时长 300ms，不要拉长。** 九改那次开合是 450ms（140+90+220），
    ///    在表上停留得越久越容易被注意到 —— "一直在眨眼"里有它一份。
    ///    真人闭眼 100~150ms、整个眨眼 200~400ms，300ms 正是自然那一档。
    ///
    /// ⚠️ **过冲 1.08 那一下是灵魂**：睁到底之后再多开一点点再落回来，
    ///    眼睛就有了"弹开"的劲。少了它，纯三段式的开合看着像机械闸门。
    private func blinkOnce() async {
        withAnimation(.easeIn(duration: 0.07)) { openness = 0.05 }
        try? await Task.sleep(nanoseconds: 70_000_000)
        guard !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: 0.08)) { openness = 1.08 }
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard !Task.isCancelled else { return }

        withAnimation(.easeOut(duration: 0.15)) { openness = 1 }
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    /// 抽下一个"两次眨眼之间的间隔"。
    ///
    /// ★ 十二改新增。这就是"跟正常人一样"的全部实现 —— 先按概率决定这一轮
    /// 属于"密"还是"疏"，再在那一档里随机。两段的数值依据写在常量那边。
    ///
    /// ⚠️ 为什么抽**两次**而不是"一个偏斜分布"：`Double.random` 只有均匀分布，
    ///    要在它上面凑一个偏斜分布就得写个逆变换，为了两个数不值得。两档写法
    ///    反而把意图摆在明面上 —— 读代码的人一眼看到"主流是几秒、偶尔十几秒"。
    private static func nextBlinkGap() -> Double {
        let far = Double.random(in: 0 ..< 1) < blinkGapFarChance
        return Double.random(in: far ? blinkGapFar : blinkGapNear)
    }

    /// 三层缩放的乘积：呼吸 × 被戳 × 录音。
    ///
    /// 乘起来而不是叠三个 `.scaleEffect` —— 叠三层时改任何一层都要同时改
    /// 另外两层的量级才能对上观感，很快就没人算得清总幅度了。
    ///
    /// ⚠️ 呼吸的幅度八改收到 ±1.8%（原来 ±3.5%）。周期放慢之后，同样的幅度
    ///    在一秒里走过的距离变短、但停留时间长，观感上反而更"胀"；两个一起
    ///    调才是"慢而稳"，只放慢周期会变成"慢慢鼓起来"。
    ///
    /// ⚠️ 录音态是 1（不缩不放）。七改那版录音时会再放大 1.06，那是为了
    ///    "眼睛睁大一号"；九改录音态换成音波之后，那条波的高度**就是电平本身**，
    ///    再乘一个系数会让"看到的幅度"和"真实音量"不再是一回事。
    ///
    /// ⚠️ 被戳那一下十二改从 5% 收到 **3%**：它现在只是配菜（主戏是 `mood`）。
    ///    这里仍然只有**三层**，表情的变形不在这个乘积里 —— 表情改的是眼睛
    ///    自己的尺寸与形状（`eye(mirrored:)`），跟整张脸的缩胀是两码事，
    ///    混进这个乘积就会变成"表情多大取决于当时呼吸到哪儿了"。
    private var figureScale: CGFloat {
        var s: CGFloat = (dimmed || isRecording) ? 1 : (breathe ? 1.028 : 0.992)
        s *= 1 + poke * 0.03
        return s
    }

    /// 空闲态被轻点：**弹一下 + 演一个随机表情**。
    ///
    /// ⚠️ 开始录音仍然不是它 —— 开始录音是长按 2 秒、双指互点、或摇一摇。
    ///
    /// 为什么要有反馈：点了完全没动静，用户会以为"是不是得要长按才行"于是
    /// 开始乱试。所以这一下必须"我收到了"。
    ///
    /// ★ 十二改（用户："眼睛需轻触它会有各种表情而不是单一的眼睛晃动"）：
    /// 十改之前这里只有整体的那一弹，用户把那一弹形容成"单一的眼睛晃动"
    /// —— 准确。现在弹只是**回应**，**表情**才是内容：
    /// 五档随机抽一个（∩拱笑眼 / ∪垂眼 / 圆睁 / 眯眼 / 斜瞪），演一遍收回。
    ///
    /// ⚠️ 两者**同时**发生是有意的（不是顺手叠的）：纯表情变化没有"点到了"
    ///    这个物理感，纯弹跳又没有表情 —— 用户抱怨的正是"只有后者"。
    private func pokeOnce() {
        guard !isRecording, !dimmed else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) { poke = 1 }
        Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { poke = 0 }
        }
        playRandomMood()
    }

    /// 摇一摇的"眩晕"：整对眼睛绕自己的中心**转两圈**，然后停回原位。
    ///
    /// ★★ 十四改新增（用户："手表的摇一摇改成摇一摇眼睛会有转圈圈眩晕感
    /// 增加交互"）。摇一摇原来的反馈只有一下震动 —— 身体感受到的、
    /// 眼睛没参与。现在眼睛跟着"晕"一下，摇这个动作才算被**这张脸**收到。
    ///
    /// ## 节奏怎么定的
    /// * **0.9 秒转 720°**（两圈）。一圈太快像在扇风，三圈以上在 40mm 的
    ///   小屏上会糊成一团。0.9 秒也正好是 `WatchShakeDetector` 那个
    ///   "0.9 秒窗内两次撞击"的判定窗 —— 眼睛转完，判定也刚落地。
    /// * **`timingCurve(0.3, 0, 0.4, 1)`**：慢起 → 中段最快 → 收尾放缓。
    ///   "越转越快然后停住"才有"晕"的感觉；匀速转两圈是电风扇，不是眩晕。
    /// * **之后必须把角度归零，且不带动画**：带着 720° 的角度停在那里，
    ///   下一次转就要从 720° 出发；而带动画归零会让眼睛在停下之后
    ///   又倒转两圈回去 —— 那是"倒带"，不是"晕完"。
    ///
    /// ⚠️ **只在眼睛可见时有意义**。首页在摇一摇触发后约 0.45 秒才真正
    ///    起停录音（见 `WatchRecorderView.syncShakeDetector`），所以开始录音
    ///    时前半段眩晕看得见；停止录音时眼睛在 0.45 秒后回来，
    ///    正好接上后半段。两条路都有戏份，不是白转。
    private func playDizzy() {
        dizzyTask?.cancel()
        guard !dimmed else { return }
        dizzyTask = Task {
            withAnimation(.timingCurve(0.3, 0.0, 0.4, 1.0, duration: 0.9)) {
                dizzyAngle = 720
            }
            try? await Task.sleep(nanoseconds: 950_000_000)
            guard !Task.isCancelled else { return }
            var settle = Transaction()
            settle.disablesAnimations = true
            withTransaction(settle) { dizzyAngle = 0 }
        }
    }

    /// 抽一个表情演一遍：进场 0.26 秒 → 停约 0.8 秒 → 退场 0.34 秒。
    ///
    /// ⚠️ 每次都**先取消上一条** `Task`（见 `moodTask` 那段）：连点两下时，
    ///    先醒来的那条会把刚进场的新表情一起抹掉。
    ///
    /// ⚠️ 退场用 `easeOut` 而不是 `spring`：进场要弹一下（"被逗了"），
    ///    退场要**松**着回去。两头都用 spring 会让"收回表情"看起来像被弹回去。
    ///
    /// ⚠️ 0.8 秒是"看得清"和"不挡事"之间的那档。低于 0.5 秒会像闪了一下，
    ///    高于 1.2 秒用户会开始等它回去（这张脸随时可能被长按，不能长时间
    ///    挂着一个表情）。
    private func playRandomMood() {
        moodTask?.cancel()
        // ★ 十三改：池子 = **表情库减去常驻那一档**（`BotFaceStyle.tapPool`）。
        //
        // ⚠️ 十二改那份名单是写死的五档；现在库变成九档、而且用户能自己选常驻
        //    哪一档，写死的名单会立刻出问题：用户选了 `shy` 常驻，池子里却仍然
        //    只有那五档 —— 于是 `shy` 永远演不出来，而"抽到和常驻一样的那档"
        //    （那一下看起来就是没反应）反而有可能。从库里算就不会有这两种毛病。
        let pool = BotFaceStyle.tapPool(excluding: style)
        guard let next = pool.randomElement() else { return }
        moodTask = Task {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.72)) { mood = next }
            try? await Task.sleep(nanoseconds: 820_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.34)) { mood = nil }
        }
    }

    // MARK: - 脸

    /// 这张脸**当前是哪个形态**。
    ///
    /// 只有两个分支、而且互斥 —— 这正是 Grok 那套"一个形象、几种状态，
    /// 不给状态另做指示灯"的做法：待命是眼睛，录音是一条音波。
    /// 表盘上没有地方再摆一行"录音中"，这个切换本身就是那行字。
    ///
    /// ★ 十一改：录音态从"光一条波"变成"波 + 正下方一行计时"。用户要的是
    /// "下面附带录音时间" —— 计时必须**贴着波**，而不是隔着半张脸落在首页
    /// 那行小字里。所以它归到这里来渲染，不再是首页 `caption` 的一部分。
    ///
    /// ⚠️ 用 `VStack` 会让整组在脸框里重新居中，也就是波比原来**略高一点点**
    /// （多出来的那行字占了约 8pt）。这个位移只在"眼睛 → 波"这个切换的**同时**
    /// 发生，而那一刻画面本来就在整个换掉，所以看不出来。不要为了抹掉它去
    /// 写一堆 offset —— 那会让"波到底在哪儿"变成一个要算的问题。
    @ViewBuilder
    private var figure: some View {
        if isRecording {
            VStack(spacing: 6) {
                WatchVoiceWave(meter: meter, size: size, tint: tint)

                if let elapsedText {
                    Text(elapsedText)
                        // 等宽数字：不然秒数从 9 跳到 10 时整行会左右抖一下。
                        .monospacedDigit()
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
        } else {
            eyes
        }
    }

    /// 两只眼睛。
    ///
    /// ★ 十改：这一对眼睛**整体**会轻轻地游移（`gaze`）—— 这是待机时的**主体
    /// 动作**，也是"不要一直眨眼"真正成立的原因：眼睛从不静止，眨眼就退化成
    /// 一个偶尔的点缀，而不是唯一在发生的事（见文件顶部第 3 条）。
    ///
    /// ⚠️ 是**整对一起平移**，不是左右眼各看各的。各看各的就不是"在看"，
    ///    是"斜视"—— 参考实现 `_blinkNow` 外面的 `lookX` 也是加到两只眼上的
    ///    同一个值。
    ///
    /// ⚠️ 八改删掉了"录音时错相位浮动"那套（那时录音态还是眼睛的变体）。
    ///    九改录音态整条换成音波，眼睛根本不在场，`sway` 那个状态跟着一起删了
    ///    —— 不是忘了接。
    ///
    /// ★★ 十三改：对眼睛的**画法**整个搬进了 `BotFacePair`（共用文件）。
    ///    这里只剩两件"这张脸自己才知道"的事：抬高一点（`eyeRise`），
    ///    以及往目光方向平移（`gaze`）。
    ///    ⚠️ 画法搬走是必须的 —— iPhone 上那个选择器要用同一段代码摆预览。
    ///      两边各写一份的话，"手机上挑的笑眼"和"表上画的笑眼"迟早会不一样。
    private var eyes: some View {
        BotFacePair(
            // 轻点演的那一档优先，没有就回落用户选的常驻档。
            style: mood ?? style,
            size: size,
            tint: tint,
            openness: openness
        )
            // ★ 十四改：摇一摇的"眩晕"。整对眼睛绕自己的中心转两圈。
            .rotationEffect(.degrees(dizzyAngle), anchor: .center)
        // 眼睛整体略高于几何中心。正好居中会显得"低着头"——
        // 人脸的眼睛本来就在中线之上。
        .offset(y: BotFaceMetrics.eyeRise(size))
        // 目光。叠加在上面那行的"抬高"之上（两个 `offset` 是相加的）。
        .offset(x: gaze.width, y: gaze.height)
    }

    /// 待机、以及"不换形状"那几种表情的眼睛：一只圆头竖条。
    ///
    /// ⚠️ 十三改：这一对方法（`eyeShape` / `eyeArc`）**整个搬去了
    ///    `BotFaceEye`**（共用文件 `Sources/Services/Watch/BotFaceStyle.swift`），
    ///    连同"用 `opacity` 交叉淡化而不是 `if/else` 二选一"那个决定。
    ///    搬家的理由见 `eyes` 那段 —— iPhone 上的选择器要用同一段代码摆预览。

    // MARK: - 长按：眼睛融合 → 扩散满屏

    /// ★★ 2026-10-16 十六改（用户原话：
    ///   "我要的是两个眼睛根据我按压下去然后自动根据我按压的地方两个眼睛融在一起，
    ///    然后再慢慢扩散整个屏幕然后跳转到录音那边"）。
    ///
    /// ## 两版都被否掉了，这一版要的是"有来路"
    /// * 十四改：从眼睛外接圆长出去的实心圆 → 用户读成"两个眼睛在扩散"；
    /// * 十五改：整屏纯色用透明度渐显 → 干净了，但**没有来路** ——
    ///   颜色凭空从整块屏幕上浮起来，和那两只眼睛没有关系。
    /// 用户这次把顺序讲清楚了：**先融，再扩散**。所以这一版是两段几何，
    /// 前一段的主角是那两只眼睛，后一段才是满屏。
    ///
    /// ## 两段（`holdProgress` 0 → 1）
    /// | 段 | 占比 | 在做什么 |
    /// |---|---|---|
    /// | 融合 | 前 **32%** | 两只眼睛各自朝**手指按下的那个点**滑过去，同时从"竖条"长成"圆"，最后在按点重叠成一团 |
    /// | 扩散 | 后 **68%** | 那一团从按点开始长圆，一直长到盖住整块屏幕 |
    ///
    /// * 融合段的终点尺寸取 **`0.47 × size` 的圆**：这个数不是拍的 ——
    ///   两只眼睛的面积是 `2 × 0.235 × 0.375 ≈ 0.176 size²`，而直径 `d` 的圆
    ///   面积是 `0.785 d²`，令两者相等得 `d ≈ 0.47`。也就是**融完之后那团东西
    ///   和融之前一样大**，看起来是"合并"，不是"缩小"或"膨胀"。
    /// * 两段都过一遍 `smoothstep`（`3x² − 2x³`）：线性插值在起点和终点各有一个
    ///   折角，眼睛会像被硬拽一下。平滑之后是"起步轻、中间快、收尾轻"。
    /// * 扩散段终点半径 **`2.0 × size`**：按点最远只可能在脸的方框的角上
    ///   （离脸心 `0.57√2 ≈ 0.81 size`），屏幕最远角离脸心约 `1.06 size`，
    ///   所以从按点到最远角最多 `1.87 size`。2.0 留了一点余量。
    ///
    /// ## 为什么用 `Canvas` 自己画，而不是 `Rectangle` + 两个 `Capsule`
    /// 融合段要的是"眼睛**一边移动一边变圆**"，而 `BotFaceEye` 画的是胶囊
    /// （宽高比固定、还带着 `BotFaceStyle` 的 `arc` 分支）。要在 SwiftUI 里把
    /// 那个形状连续变形到圆，得把 `BotFaceStyle` 那条几何重写一遍 —— 而
    /// 那一份正是两端共用的、绝不能分叉的东西。`Canvas` 里画**圆角矩形**
    /// 就不用碰它：宽=高时圆角矩形**就是**圆，变形是同一个 `Path` 的两个参数
    /// 在插值，没有第二套几何。
    ///
    /// ## 三个必须
    /// * `allowsHitTesting(false)` —— 它盖在整块屏幕上，能点的话这一页就没法用了。
    /// * 画布 `4.2 × size`：`Canvas` **只在它自己的边界内绘制**，所以它必须比
    ///   屏幕大得多（40mm 上 500pt 见方，屏幕只有 162×194）。
    ///   那把圆裁掉的那一圈落在屏幕之外，看不见。
    /// * 淡出交给 `sweepFading`，**不动 `holdProgress`** —— 几何与退场是两件事，
    ///   混在一个状态里，"先铺满再退场"就写不出来了。
    @ViewBuilder
    private var holdLayer: some View {
        if holdProgress > 0.002 {
            Canvas { context, canvasSize in
                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

                // 按压点从"脸的局部坐标"换到"画布坐标"：两个视图同心
                // （都在同一个 ZStack 里居中），所以只差一个平移。
                let faceSide = size * 1.14
                let press = pressPoint ?? CGPoint(x: faceSide / 2, y: faceSide / 2)
                let target = CGPoint(
                    x: center.x + (press.x - faceSide / 2),
                    y: center.y + (press.y - faceSide / 2)
                )

                let merge = Self.smoothstep(min(1, holdProgress / Self.mergeShare))
                let spread = Self.smoothstep(
                    max(0, (holdProgress - Self.mergeShare) / (1 - Self.mergeShare))
                )

                // 起点：和待机那两只眼睛**逐项对齐**（同一套 `BotFaceMetrics`、
                // 同一个 `style` 的形变）。差一点就会在按住的第一帧看到眼睛跳一下。
                let geo = style.geometry
                let restW = BotFaceMetrics.eyeWidth(size) * geo.scaleX
                let restH = BotFaceMetrics.eyeHeight(size) * geo.scaleY
                let restGap = (BotFaceMetrics.eyeWidth(size) + BotFaceMetrics.eyeGap(size)) / 2
                let restY = BotFaceMetrics.eyeRise(size)
                let blobD = size * 0.47

                for side in [CGFloat(-1), 1] {
                    let rest = CGPoint(x: center.x + side * restGap, y: center.y + restY)
                    let eye = CGPoint(
                        x: rest.x + (target.x - rest.x) * merge,
                        y: rest.y + (target.y - rest.y) * merge
                    )
                    let w = restW + (blobD - restW) * merge
                    let h = restH + (blobD - restH) * merge
                    let rect = CGRect(x: eye.x - w / 2, y: eye.y - h / 2, width: w, height: h)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: min(w, h) / 2),
                        with: .color(tint)
                    )
                }

                if spread > 0 {
                    let from = blobD / 2
                    let r = from + (size * 2.0 - from) * spread
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: target.x - r, y: target.y - r, width: r * 2, height: r * 2
                        )),
                        with: .color(tint)
                    )
                }
            }
            .frame(width: size * 4.2, height: size * 4.2)
            // 一点点模糊。融合和扩散都是"液体"的事，硬边会读成"两个几何图形
            // 叠在一起"。半径跟着 `size` 走，40mm 上约 5pt。
            .blur(radius: size * 0.045)
            .opacity(sweepFading ? 0 : 1)
            .animation(.easeOut(duration: 0.5), value: sweepFading)
            .allowsHitTesting(false)
        }
    }

    /// 融合段占 `holdProgress` 的比例。剩下的都给扩散段。
    ///
    /// ⚠️ 0.32 是有配比的：融合太快（<0.2）会像"眼睛闪了一下就没了"，
    ///    太慢（>0.45）则扩散只有一半时间，会长得很仓促 —— 用户要的是
    ///    "**慢慢**扩散整个屏幕"。
    private static let mergeShare: CGFloat = 0.32

    /// 平滑插值：`3x² − 2x³`。两端导数为 0，所以眼睛起步和收尾都不是"被拽一下"。
    private static func smoothstep(_ x: CGFloat) -> CGFloat {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }

    /// 按住期间，`figure` 那两只眼睛让位的程度。
    ///
    /// ⚠️ **必须有这一段交接**：`holdLayer` 在 ZStack 里是上层，从按住的第一帧
    ///    就画着两只眼睛（用的是同一套几何）。不让 `figure` 退场，就是两对眼睛
    ///    重叠 —— 基础档（纯胶囊）看不出来，但 `BotFaceStyle` 里带 `arc` 的
    ///    那几档（`happy` / `sad`）会露出来：底下是弧、上面是直条。
    ///    0.06 个进度 ≈ 0.12 秒，快到看不出这是一个"换手"。
    private var figureOpacity: Double {
        guard holdProgress > 0.002 else { return 1 }
        return Double(max(0, 1 - holdProgress / 0.06))
    }
}

// MARK: - 表情（★ 2026-10-16 十二改新增，十三改搬走）
//
// 十二改的五个表情（`EyeMood`）和那段弧的形状（`EyeCurve`）都**搬到共用文件**
// `Sources/Services/Watch/BotFaceStyle.swift` 里去了，现在叫 `BotFaceStyle`
// 与 `BotFaceEyeCurve`，而且从五档扩到九档。
//
// ⚠️ 搬家的理由不是整理，是**必须**：iPhone 的设置里多了一个表情选择器，
//    它要摆预览；预览和真机必须是**同一段代码**。各写一份的话，用户会在
//    手机上看到一个笑眼、抬腕发现是垂眼 —— 而这种漂移最难被发现。
//    素材来源、为什么只搬得动九个、以及挑的时候守的三条，全部写在那个文件里。

// MARK: - 双指互点
//
// ★ 2026-10-16 七改：从 `WatchRingControl.swift` 搬过来的（那边留了说明）。
// 搬家的原因不是它变了，而是**落点**变了：首页正中不再是圆环按钮，
// 而是上面这张 Bot 脸。这个 modifier 本来就是"把手势绑到当前页的主控件上"，
// 属于**控件**的事，不属于**环**的事。
//
/// 把**双指互点**（食指与拇指捏合，Apple 叫 Double Tap）绑到页面的主按钮上。
///
/// ## 为什么单独一个 `ViewModifier`
/// `.handGestureShortcut(_:isEnabled:)` 是 **watchOS 11.0** 才有的 API，而本
/// 工程的 `WATCHOS_DEPLOYMENT_TARGET` 是 **10.0**。拆成 modifier 就能在
/// 一个明确的 `#available` 分支里说清两件事：
///
/// * **11 及以上**：显式声明这个按钮就是手势的落点，并且**受开关控制**
///   （`isEnabled`）。这里必须显式写 `isEnabled: false` 而不是"不管" ——
///   只把开关读进来却不动 modifier 的话，系统仍然会把双指互点派给这一页的
///   主按钮，用户关了开关照样触发。
/// * **10.x**：什么都不做。watchOS 10.1 起系统就会把双指互点自行派给页面上
///   那个唯一的主按钮（首页正中只有这张眼睛一个 `Button`；两侧菜单是
///   `NavigationLink`，不参与 primary action 的判定），所以那个版本上手势
///   本来就能用 —— 没有 API 也就**没有开关**，这是系统限制，不是漏做。
struct PrimaryHandGesture: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(watchOS 11.0, *) {
            content.handGestureShortcut(.primaryAction, isEnabled: enabled)
        } else {
            content
        }
    }
}

// MARK: - 眨眼的节奏（五个版本，账目留在这里）
//
// | 版本 | 眨眼节奏 | 用户反馈 |
// |---|---|---|
// | 七改 | 固定 4.63s，每轮必连眨两下 | 初版 |
// | 八改 | 固定 8.12s，每轮必连眨 | "眨眼太快，节奏慢点" |
// | 九改 | 固定 19.12s，每轮必连眨 | "眼睛不要一直眨眼"…"**不是不眨眼**" |
// | 十改 | 9~20s 随机、每次重抽；单下为主，14% 补一下 | "**不需要一直眨眼**" |
// | **十二改** | **两档随机：3.5~6.5s 为主、22% 概率 10~18s；单下为主，14% 补一下** | "**随机眨眼睛频率跟正常人眼渣样一样**" |
//
// ★ 七改到九改是**同一条路走了三步：把固定周期越拉越长**。走到 19 秒的时候
// 用户还在说"不需要一直眨眼"—— 这就说明这条路本身是错的。
//
// 真正的问题有三个，前三个版本一个都没碰：
//
// 1. **固定周期 = 节拍器。** 人眼抓规律的能耐远超直觉：19 秒的周期照样会被
//    抓住，抓住之后每次眨眼都读成"它又按点眨了"。**慢不等于自然**。
//    十改改成每次眨完重新抽一个区间内的随机值，结构上就没有周期可言。
// 2. **每轮必连眨。** 七/八/九改都是 `100%` 连眨 —— 每个周期里必然两次开合。
//    真人不是这样：参考实现（`aora-bot`）是 `Math.random() < 0.14`。
//    十改照抄 0.14 ⇒ 绝大多数眨眼成了单下、300ms 的一闪。
// 3. **眨眼是唯一在动的东西。** 九改那 ±1.8% 的呼吸肉眼看不见，于是 19 秒里
//    这张脸完全静止，然后突然"啪-啪"。十改把**目光游移**提成待机的主体动作
//    （`runGazeLoop`），眼睛从不静止 —— 眨眼于是降级成点缀，不再是被注意到
//    的那件事。这一条才是"不需要一直眨眼"真正的解法。
//
// ★★ 十二改是**这条线第一次往反方向走**（更密）。十改把区间从严取到 9~20，
// 依据是用户连着两轮的"不要一直眨眼"；用户这一轮明确改口要"跟正常人一样"，
// 于是按人的实测频率重新取了一遍，并且从**一档均匀**换成**两档**：
// 人眨眼是"密的里面偶尔插一段长的"，不是均匀分布 —— 算术见 `nextBlinkGap()`
// 上面那张表和 `blinkGapNear` / `blinkGapFar` 的注释。加权均值 ≈ 1 次 / 7 秒
// （≈ 8.6 次/分），落在"人盯着屏幕"那一档。
//
// ⚠️ 这条线上唯一**从来没被推翻过**的是：不能有固定周期。
//    · 想更静 → 调 `blinkGapFar`（远档上限）；
//    · 想更密 → 调 `blinkGapNear` / 降 `blinkGapFarChance`。
//    任何"固定时长 + `repeatForever`"的组合都会退回节拍器（八改就是那么翻车的）。
//
// ⚠️ 三个不变量，别在改数值的时候顺手破坏：
//    · 眨眼总时长 **300ms**（九改是 450ms —— 停留越久越显眼）；
//    · 睁眼**过冲到 1.08** 再落回 1（少了它像机械闸门）；
//    · 闭合停在 **0.05**，不写 0（写到 0 再放大回来时，`scaleEffect` 在极薄
//      的尺寸上会露一条比线宽还细的缝，看起来像"眼睛掉了一下"）。
//
// ⚠️ 目光的周期（4.8s）和眨眼的间隔（两档随机）**刻意不等**，见
//    `startIdleMotion` 下面那段"待机循环"的注释：两条等周期的动作会锁相。
//
// ⚠️ 实现已经不在这个文件末尾了 —— 十改把逐相位的 `BlinkPhase` 整条删掉，
//    换成了 `runBlinkLoop()` / `blinkOnce()`（在 `startIdleMotion()` 下面）。
//    原因见文件顶部"为什么不再用 `phaseAnimator`"。
//    十二改只改了"抽间隔"那一步（`nextBlinkGap()`），循环结构一格没动。
