import SwiftUI

// MARK: - The expressions the watch home screen face can wear
//
// ★★ 2026-10-16 revision thirteen (user's words: "the Nomily AI app's settings need one more
//    namely a setting for the watch home screen eyes' expression, bringing the expressions of the gork bot on github into
//    the Nomily ai settings so their expressions can be brought in").
//
// The five expressions from the twelfth revision (`EyeMood`) are **read-only**: the user taps once and one is drawn at random and played.
// This round wants **selectable**: turn it into a library, put it in the iPhone settings, and have the chosen one
// **stay permanently** on the watch home screen.
//
// ─────────────────────────────────────────────────────────────────────────
// ## Why this file is in `Sources/Services/Watch/` (shared by both sides)
//
// Because it **must** be visible to both sides at once, and the reason isn't saving code:
//
//   · **iPhone** uses it to render that picker's preview ("what does what I picked actually look like");
//   · **watch** uses it to decide how the two eyes on the home screen are drawn.
//
// Write a copy on each side and the preview and the real device will **drift** — and that drift is precisely the hardest to spot
// and the most damaging kind: the user sees a smiling eye on the phone, raises their wrist and finds a drooping one. The same enum
// and the same geometry keep the two sides permanently in agreement. Same approach as `WatchLinkMessage` / `RecordingName`
// (both listed under `nomily_watch.sources` in `project.yml`).
//
// ─────────────────────────────────────────────────────────────────────────
// ## The material comes from `aora-bot`, but **only nine survive the move**
//
// The reference repo (`sam70361/aora-bot`, `mood-mates/src/core/geometry.js`) has **20
// eye-shape slots**: `calm / calm2 / happy / happy2 / wide / wide2 / closed / closed2 /
// sleepy / squint / squint2 / angry / angry2 / scan / scan2 / scan3 /
// listen / listen2 / shy / sad`. Each slot is a set of parameters
// `{ w, h, bend, taper, slope, shift }`。
//
// ⚠️ There the eye is a **bendable path**, and `bend` (how it curves) and `taper` (how the two ends
//    narrow) are its two main dimensions. The eye here is "a rounded vertical bar + an optional arc",
//    and cannot draw an arbitrary curve. So the dimensions it can truly express are just four:
//
//      · **height** (`scaleY`) — wide open / narrowed
//      · **width** (`scaleX`)
//      · **tilt** (`tilt`) — slanted
//      · **straight / curved** (`arc`) — the two curved ones switch to the stroked `BotFaceEyeCurve`
//
//    so the nine tiers below are **hand-picked**, not taken wholesale.
//
// ## ⚠️ Three rules kept while picking
//
// 1. **Distinguishable at a glance.** In the reference implementation `calm` and `calm2` differ by width ×0.96 and height ×1.05
//    — 4% / 5%, not much more than the idle breathing (±1.8%). Put that in this picker and the user will pick two
//    of the nine cells that "look no different", then conclude "this feature is just for show".
//    ⇒ the nine tiers must **read as different expressions from half a metre away**.
// 2. **No "eyes closed" tier.** The reference implementation's `closed` / `sleepy` (fully shut) was **not**
//    carried over — a permanently closed-eye expression collides with **blinking**: the user can't tell "it's blinking at me"
//    from "this is what I picked". For quiet, pick `squint` (open a crack) — that's "narrowed", not "asleep".
// 3. **No tier "almost the same as idle".** `calm` is the idle state itself, so it is both the default
//    and the tier **excluded from tapping** (see `tapPool(excluding:)`).
enum BotFaceStyle: String, CaseIterable, Codable, Identifiable {
    /// Calm. The default — a rounded vertical bar with nothing added.
    case calm
    /// Smiling eyes. The ∩ arc bowing upward.
    case happy
    /// Drooping eyes. The ∪ arc sagging downward — "deflated".
    case sad
    /// Wide open. The whole eye scaled up a notch.
    case wide
    /// Squint. Height squashed to a third, width opened up slightly.
    case squint
    /// Glare. The lower ends of the two eyes draw in toward the midline, a "∧" at the brow.
    case angry
    /// Shy. Flat and wide, the upper ends pulled inward — the "∨" tier.
    case shy
    /// Listening. A tall thin one, as if waiting for the other person to finish speaking.
    case listen
    /// Scanning. A narrow tall slit, as if sweeping back and forth.
    case scan
    // ★ 2026-10-20: six more tiers (user: "add more expressions, Grok-bot style"). All
    // stay inside the four expressible dimensions — height / width / tilt / arc — and each
    // must still read as a different expression from half a metre away (rule 1 above).
    /// Grinning. The ∩ arc, wider — a bigger smile.
    case grin
    /// Blissful. Flat and very wide, height squashed — "relaxed, eyes closed happy".
    case blissful
    /// Surprised. Narrow and tall — the "O" mouth of the eye world.
    case surprised
    /// Focused. Small and tense — a pin-point stare.
    case focus
    /// Sly. A strong slant on a narrowed eye — a knowing squint.
    case sly
    /// Curious. A raised brow: tall, slightly narrower, tilted.
    case curious
    // ★ 2026-11-06：借鉴 agent-avatars（jamesalmeida/agent-avatars）表情库的两档。
    // ⚠️ 只加"静态形状档"：那个项目里 thinking / listening / drowsy 之类是**行为**
    //   （视线上抬、垂眼、打瞌睡），在 Nomily 里由 `WatchBotFace.runGazeLoop`
    //   的姿态抽签实现，不占表情库的位——静态档要能被手机选成"常驻表情"，
    //   行为档不该被钉死。
    /// Wink. One eye closed — borrowed from agent-avatars' one-shot `wink` gesture.
    case wink
    /// Love. Heart-shaped pupils — borrowed from agent-avatars' `love` mood.
    case love
    // ★ 2026-11-06 二轮（用户："表情库很丰富他们里面我们没有就加入进来"）：
    // 把 agent-avatars 库里还缺的静态档补齐。thinking / listening / searching /
    // reading / writing 是**行为**（视线姿态 / 扫视），由 `runGazeLoop` 的姿态
    // 抽签承担，不进静态库（理由见上面 wink 处的段落）；working 的转圈眼睛
    // 在手表上是持续动画，常驻太闹，同样不进。
    /// Sorry（借鉴 `sorry` mood）：眼皮下垂、眉心内收——任务失败时那张脸。
    case sorry
    /// Confused（借鉴 `confused` mood）：两眼一高一矮、同向倾斜——"歪头"。
    /// 原项目里两眼还会持续交换大小；静态档先取它的"歪斜不对称"姿态，
    /// 动态交换交给自动轮换（轮到下一档时脸整个换掉，效果等价）。
    case confused

    var id: String { rawValue }

    /// The name in the picker. **Follows the app language** (`L10n` is entirely computed properties).
    var title: String {
        switch self {
        case .calm:   return L10n.Face.calm
        case .happy:  return L10n.Face.happy
        case .sad:    return L10n.Face.sad
        case .wide:   return L10n.Face.wide
        case .squint: return L10n.Face.squint
        case .angry:  return L10n.Face.angry
        case .shy:    return L10n.Face.shy
        case .listen: return L10n.Face.listen
        case .scan:   return L10n.Face.scan
        case .grin:     return L10n.Face.grin
        case .blissful: return L10n.Face.blissful
        case .surprised: return L10n.Face.surprised
        case .focus:    return L10n.Face.focus
        case .sly:      return L10n.Face.sly
        case .curious:  return L10n.Face.curious
        case .wink:     return L10n.Face.wink
        case .love:     return L10n.Face.love
        case .sorry:    return L10n.Face.sorry
        case .confused: return L10n.Face.confused
        }
    }

    /// All the geometry parameters of one expression tier.
    ///
    /// ## Why "one switch returning one struct" rather than five computed properties each with its own switch
    /// Five properties means `9 × 5 = 45` numbers scattered across five different switches. To check
    /// "what shape `shy` really is" you'd have to jump back and forth five times, and adding a tier means editing five places at once —
    /// miss one and there's no compile error, just a silent inheritance of some dimension from another tier.
    /// One struct, one line, and it reads like a table.
    var geometry: BotFaceGeometry {
        switch self {
        //                          scaleX  scaleY  tilt   arc
        case .calm:   return BotFaceGeometry()
        case .happy:  return BotFaceGeometry(scaleX: 1.06, arc: .up)
        case .sad:    return BotFaceGeometry(arc: .down)
        case .wide:   return BotFaceGeometry(scaleX: 1.06, scaleY: 1.24)
        case .squint: return BotFaceGeometry(scaleX: 1.04, scaleY: 0.34)
        case .angry:  return BotFaceGeometry(scaleY: 0.80, tilt: -12)
        case .shy:    return BotFaceGeometry(scaleX: 1.08, scaleY: 0.58, tilt: 10)
        case .listen: return BotFaceGeometry(scaleX: 0.86, scaleY: 1.18)
        case .scan:   return BotFaceGeometry(scaleX: 0.72, scaleY: 1.15)
        case .grin:      return BotFaceGeometry(scaleX: 1.22, arc: .up)
        case .blissful:  return BotFaceGeometry(scaleX: 1.30, scaleY: 0.42)
        case .surprised: return BotFaceGeometry(scaleX: 0.82, scaleY: 1.45)
        case .focus:     return BotFaceGeometry(scaleX: 0.80, scaleY: 0.66)
        case .sly:       return BotFaceGeometry(scaleY: 0.55, tilt: 17)
        case .curious:   return BotFaceGeometry(scaleX: 0.90, scaleY: 1.28, tilt: 9)
        // ★ 2026-11-06（借鉴 agent-avatars）：wink = 右眼闭（`oneEyeClosed` 的
        //   压扁在 `BotFaceEye` 里做，镜像的那只）；love = 爱心瞳（第三种画法）。
        case .wink:      return BotFaceGeometry(oneEyeClosed: true)
        case .love:      return BotFaceGeometry(heart: true)
        // ★ 2026-11-06 二轮：补齐 agent-avatars 缺的两档静态形状。
        case .sorry:     return BotFaceGeometry(scaleX: 0.94, scaleY: 0.52, tilt: -6)
        case .confused:  return BotFaceGeometry(scaleY: 1.0, tilt: 10, sameTilt: true, asym: true)
        }
    }

    /// Whether this tier `can be parsed back after being encoded` — the tag pushed over from the phone has to pass this gate.
    ///
    /// The phone and watch app versions can be **out of step** (watch updates are pushed by the iPhone when it sees fit,
    /// often several minutes late or even a whole restart cycle later). When a new phone pushes a
    /// tag the old watch doesn't recognise, `init(rawValue:)` returns `nil` and the watch **stays as it is** rather than crashing or
    /// falling back to the default — see `WatchFaceStore.apply(_:)`.
    static func decode(_ tag: String?) -> BotFaceStyle? {
        guard let tag else { return nil }
        return BotFaceStyle(rawValue: tag)
    }

    /// The tiers that can be drawn when the face is tapped.
    ///
    /// ⚠️ Excludes `rest` (the tier currently pinned). Without that exclusion, a user with smiling eyes picked would tap once
    ///    and draw smiling eyes again — which looks like "tapping does nothing", and that is exactly the
    ///    complaint the twelfth revision set out to fix (user's words: "the eyes need to show various expressions on a light tap instead of a single eye wobble").
    ///
    /// ⚠️ Also always excludes `calm`: it is the idle state itself, so drawing it likewise amounts to no reaction.
    static func tapPool(excluding rest: BotFaceStyle) -> [BotFaceStyle] {
        allCases.filter { $0 != .calm && $0 != rest }
    }
}

/// Geometry parameters of one expression tier. Default = **idle** (a 1:1 rounded vertical bar, neither curved nor tilted).
struct BotFaceGeometry {
    /// Width multiplier.
    var scaleX: CGFloat = 1
    /// Height multiplier. ⚠️ The curved tiers **ignore** this value — see `BotFaceEye`.
    var scaleY: CGFloat = 1
    /// How many degrees the **left eye** rotates; the right eye takes the negative.
    ///
    /// ⚠️ Screen coordinates have y pointing down, so **a positive angle = clockwise**. Left eye −12° (counter-clockwise) ⇒
    ///    the top of this bar leans **outward** (farther from the midline) and the bottom leans **inward** —
    ///    so the two eyes **converge toward the midline at the bottom** and the brow forms a "∧". That is what "angry" is.
    ///    A positive value is the other way round, "∨" = aggrieved / shy (`shy` uses +10).
    ///
    /// ⚠️ More important still is the "the two eyes are **opposite**" fact itself: both eyes rotating the same way (`///`)
    ///    isn't anger, it's a squint. So only the left eye's number is written here; negating it for the right eye happens in `BotFaceEye`.
    var tilt: Double = 0
    /// `nil` = straight (rounded vertical bar); a value = switch to a stroked arc.
    var arc: BotFaceArc?
    /// ★ 2026-11-06（借鉴 agent-avatars 的 `wink`）：`true` = **右**眼闭合——
    /// `BotFaceEye` 里对 `mirrored == true` 的那只把高度压到一条线。
    /// 两只对称的几何体系里唯一的"不对称"档位，所以单独一个开关。
    var oneEyeClosed: Bool = false
    /// ★ 2026-11-06（借鉴 agent-avatars 的 `love`）：`true` = 切换到**爱心**画法
    /// （第三种眼睛形态，见 `BotFaceEye`）。沿用 `tint`，随眨眼一起开合。
    var heart: Bool = false
    /// ★ 2026-11-06 二轮（借鉴 agent-avatars 的 `confused`）：`true` = 两眼**同向**
    /// 倾斜（`mirrored` 不再取负，读作"歪头"而不是"对眉"）。
    var sameTilt: Bool = false
    /// ★ 2026-11-06 二轮（借鉴 agent-avatars 的 `confused`）：`true` = 两眼**一高一矮**
    /// （左眼 ×1.25、右眼 ×0.78），配合同向倾斜就是那张"没听懂"的脸。
    var asym: Bool = false
}

// MARK: - ★ 2026-11-06 二轮：眼睛形状（借鉴 agent-avatars 的 4 种 eye styles）

/// 眼睛的**形状轴**——与表情轴（`BotFaceStyle`）正交：形状管"眼睛的高宽比"，
/// 表情管"这只眼在做什么"。agent-avatars 一侧是 `"round" | "tall" | "calm" | "curious"`。
enum BotEyeShape: String, CaseIterable, Codable, Identifiable {
    /// 竖长条（现状默认，Grok bot 风格）。
    case tall
    /// 圆眼——睁得又圆又大。
    case round
    /// 平静——宽而矮的一条，柔和。
    case calm
    /// 好奇——更窄更高，always 在"瞪大了看"。
    case curious

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tall:    return L10n.Face.shapeTall
        case .round:   return L10n.Face.shapeRound
        case .calm:    return L10n.Face.shapeCalm
        case .curious: return L10n.Face.shapeCurious
        }
    }

    /// 相对基准（`BotFaceMetrics` 的 0.30 × 0.62）的宽度倍率。
    var widthMul: CGFloat {
        switch self {
        case .tall:    return 1.00
        case .round:   return 1.16
        case .calm:    return 1.26
        case .curious: return 0.86
        }
    }

    /// 相对基准的高度倍率。⚠️ 弧形档（`arc != nil`）不乘高度——弧高由
    /// `BotFaceMetrics.arcHeight` 单独管（见那里的说明）。
    var heightMul: CGFloat {
        switch self {
        case .tall:    return 1.00
        case .round:   return 0.55
        case .calm:    return 0.74
        case .curious: return 1.16
        }
    }
}

/// Which way the arc bows.
enum BotFaceArc {
    /// ∩ — apex pointing up (smiling eyes).
    case up
    /// ∪ — apex pointing down (drooping eyes).
    case down
}

// MARK: - Proportions (the single place)

/// The size proportions of this face. The **single place** that defines "how big the eyes are, how far apart they sit".
///
/// ⚠️ Everything is scaled from `size`, never hard-coded — watch screens from 40mm to 49mm differ by 40pt in width,
///    so hard-coding any one number would misalign on at least one watch.
///
/// ★ Moved here from `WatchBotFace` in the thirteenth revision: the picker has to render a preview on the phone, and "how big
///   the eye is in the preview" must be **the same formula** as "how big it is on the watch", otherwise
///   what the user picks and what they see on the device would be out of proportion.
enum BotFaceMetrics {
    /// Width of the idle eye.
    ///
    /// ★ 2026-11-03（用户："首页的眼睛部分变得很小"）：对齐 V4 原型
    /// `54px / 226px = 0.239`。旧值 0.235 本来就贴着原型，问题不在宽。
    /// ★★ 2026-11-03 七轮（用户："眼睛这个优化有问题，没有按照之前那种大一点的比例"）：
    ///   0.26 → **0.30**，眼高 0.55 → **0.62**。原型（0.239/0.496）在这个尺寸的表上
    ///   偏保守，用户明显要"更大一号"，这里按 1.25 倍放大原型比例。
    static func eyeWidth(_ size: CGFloat) -> CGFloat { size * 0.30 }
    /// Height of the idle eye.
    ///
    /// ★ 2026-11-03（用户："首页的眼睛部分变得很小"）：**这里是主要病灶**——
    /// 旧值 0.375 只有原型（`112px / 226px = 0.496`）的四分之三，眼睛是一对"矮墩"。
    /// 对齐到 0.50：眼从扁圆变回原型那对竖长的白条（Grok bot 的比例）。
    /// ★★ 2026-11-03 五轮：0.50 → **0.55**（用户仍嫌小）；七轮再 → **0.62**。
    /// ⚠️ 表情库的弧形（`arcHeight/arcWidth`）都从眼高派生，会一起等比长高——
    ///   手机预览与手表共用本文件，两端同步变化，不会漂。
    static func eyeHeight(_ size: CGFloat) -> CGFloat { size * 0.62 }
    /// The gap **between** the two eyes (not the centre-to-centre distance).
    ///
    /// ★ 2026-11-03 八轮（用户："眼睛太近了，不够生动"）：0.11 → **0.17**。
    ///   两眼总宽 2×0.30 + 0.17 = 0.77 × size，仍留在 1.14 的框内。
    ///   ⚠️ 间距是"生不生动"的一半：Grok bot 那对眼睛之间明显留白，
    ///   挨太近会读成一张"眯着的脸"。
    static func eyeGap(_ size: CGFloat) -> CGFloat { size * 0.17 }
    /// How much the pair of eyes is raised above the geometric centre. Dead centre makes it look like "head down" —
    /// a human face's eyes sit above the midpoint anyway.
    static func eyeRise(_ size: CGFloat) -> CGFloat { -size * 0.03 }
    /// Arc height of the curved tiers (relative to the idle eye's height).
    ///
    /// ⚠️ The arc does **not** apply `geometry.scaleY`: "taking a 20pt arc and multiplying by 0.5" would turn it
    ///    into an almost invisible thin line rather than "narrowed". So the two curved tiers are given
    ///    `scaleY = 1`, and the height is set separately here.
    static func arcHeight(_ size: CGFloat) -> CGFloat { eyeHeight(size) * 0.44 }
    /// Thickness of the arc.
    ///
    /// ⚠️ **It must not be drawn thin**: a thin arc on the watch face reads as an eyebrow, or as a scratch;
    ///    only something thick enough to approach a closed eye's thickness reads as "this is an eye".
    ///    That's also why the arc is "stroked" rather than "filled" — the thickness has to be adjustable on its own.
    static func arcWidth(_ size: CGFloat) -> CGFloat { eyeHeight(size) * 0.20 }
}

// MARK: - One eye (the single place)

/// Draws **one** eye in a given expression tier.
///
/// ⚠️ This is the **only** implementation of "what an expression looks like": the home screen face and the phone's picker
///    both go through it. Draw a copy each and the two will drift sooner or later.
///
/// ## Why the two drawing modes **cross-fade on top of each other** rather than picking one with `if/else`
/// `if/else` swaps the **view identity**, and the frame it swaps on just hard-cuts (the old view is removed,
/// the new one inserted). But "capsule → arc" precisely needs a smooth transition — what the user should see is
/// "the eye narrowing into an arc", not "a flash".
struct BotFaceEye: View {
    let style: BotFaceStyle
    /// The **nominal** side length of this face, on the same basis as `WatchBotFace.size`.
    let size: CGFloat
    let tint: Color
    /// `true` = right eye. Only the tilted tiers care (negated, so the two eyes are automatically symmetric).
    let mirrored: Bool
    /// Openness. 1 = fully open, 0.05 = closed, and it may briefly exceed 1 (blink overshoot).
    var openness: CGFloat = 1
    /// ★ 2026-11-06 二轮：眼睛形状轴（`BotEyeShape`）。默认 tall = 现状不变。
    var shape: BotEyeShape = .tall

    private var geo: BotFaceGeometry { style.geometry }
    private var w: CGFloat { BotFaceMetrics.eyeWidth(size) * shape.widthMul }
    private var h: CGFloat { BotFaceMetrics.eyeHeight(size) * shape.heightMul }

    var body: some View {
        ZStack {
            Capsule()
                .fill(tint)
                .frame(width: w * geo.scaleX, height: h * geo.scaleY)
                .opacity(geo.arc == nil && !geo.heart ? 1 : 0)

            BotFaceEyeCurve(up: geo.arc == .up)
                .stroke(tint, style: StrokeStyle(lineWidth: BotFaceMetrics.arcWidth(size), lineCap: .round))
                .frame(width: w * geo.scaleX, height: BotFaceMetrics.arcHeight(size))
                .opacity(geo.arc == nil ? 0 : 1)

            // ★ 2026-11-06（借鉴 agent-avatars 的 `love`）：爱心瞳。SF Symbol 自带
            //   两瓣一尖的形状，比手写贝塞尔稳；大小从眼宽派生，与档位的 scaleX 联动。
            //   ⚠️ 也常驻在 ZStack 里靠 opacity 淡入淡出——三种画法互相过渡都是
            //   渐变而不是硬切（见下方"为什么交叉淡化"的段落）。
            Image(systemName: "heart.fill")
                .font(.system(size: w * 0.72 * geo.scaleX))
                .foregroundStyle(tint)
                .opacity(geo.heart ? 1 : 0)
        }
        // ⚠️ The outer `frame` is **fixed** (`eyeWidth × eyeHeight`) and does not follow the expression.
        //    Being fixed: the `HStack` spacing doesn't change with the expression (a sudden widening of the eye gap is more noticeable than the expression
        //    itself), and the two drawing modes share one alignment baseline.
        //    Anything outside the box is not clipped — `frame` doesn't clip, only `.clipped()` does.
        //    ★ 2026-11-06 二轮：外框随形状轴等比缩放（round 眼矮、curious 眼高），
        //    两只眼仍共用同一基线。
        .frame(width: w, height: h)
        // ★ 2026-11-06 二轮（借鉴 agent-avatars 的 `confused`）：`sameTilt` 时右眼
        //   **不**取负——两只眼倒向同一边，读作"歪头"。
        .rotationEffect(.degrees(mirrored && !geo.sameTilt ? -geo.tilt : geo.tilt))
        // Open/close squashes from the centre with `scaleEffect(y:)` rather than changing `frame(height:)` —
        // changing the height would make the eye "grow from the bottom up", whereas a real eyelid comes down **from top and bottom at once**.
        // ★ 2026-11-06（借鉴 agent-avatars 的 `wink`）：右眼常闭——压到 0.08 的一条线，
        //   仍随眨眼一起开合（眨眼叠在 wink 上读作"又眨了一下"，不冲突）。
        // ★ 2026-11-06 二轮（`confused`）：两眼一高一矮——左眼 ×1.25、右眼 ×0.78。
        .scaleEffect(
            y: openness
                * (geo.oneEyeClosed && mirrored ? 0.08 : 1)
                * (geo.asym ? (mirrored ? 0.78 : 1.25) : 1),
            anchor: .center
        )
    }
}

/// A pair of eyes — that is what the home screen face looks like when idle.
struct BotFacePair: View {
    let style: BotFaceStyle
    let size: CGFloat
    let tint: Color
    var openness: CGFloat = 1
    /// ★ 2026-11-06 二轮：眼睛形状轴，从手机设置一路推下来。
    var shape: BotEyeShape = .tall

    var body: some View {
        HStack(spacing: BotFaceMetrics.eyeGap(size)) {
            BotFaceEye(style: style, size: size, tint: tint, mirrored: false, openness: openness, shape: shape)
            BotFaceEye(style: style, size: size, tint: tint, mirrored: true, openness: openness, shape: shape)
        }
    }
}

/// An arc bowing up (∩) or down (∪).
///
/// ⚠️ Use a quadratic Bézier rather than `Circle().trim(from:to:)`: `trim`'s start position and drawing
///    direction hang on SwiftUI's "y axis down, angles clockwise" convention, which is the easiest place to
///    go wrong and the hardest to read when changing the drawing. Writing "both ends on the midline, the apex raised to the edge" with control points is
///    **self-evident** — the two formulas below can be checked directly.
struct BotFaceEyeCurve: Shape {
    /// `true` = ∩ (smile), `false` = ∪ (droop).
    let up: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // The midpoint of a quadratic Bézier is B(0.5) = ¼P₀ + ½P₁ + ¼P₂. To have the midpoint land exactly on the edge
        // (the `minY` when bowing up), the control point must sit one more height **outside the box**:
        //   0.5·maxY + 0.5·P₁.y = minY  ⇒  P₁.y = 2·minY − maxY
        // the two ends are pinned to the other edge, so the arc exactly fills the whole `rect`.
        let anchor = up ? rect.maxY : rect.minY
        let controlY = up ? rect.minY - rect.height : rect.maxY + rect.height
        path.move(to: CGPoint(x: rect.minX, y: anchor))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: anchor),
            control: CGPoint(x: rect.midX, y: controlY)
        )
        return path
    }
}

// MARK: - The square frame (★ 2026-10-20, shared by watch face + phone preview)

/// The rounded-square **stroke** around the face ("按照方框动态显示变动").
///
/// Lives in this shared file for the same reason as `BotFacePair`: the picker on the
/// phone must show *exactly* what the watch draws — one private copy per side is how
/// "looks right in the preview, wrong on the wrist" happens.
///
/// ## Geometry contract (both sides must keep these in sync)
/// * Side = `1.02 × size`, centred inside the face's nominal `1.14 × size` box;
/// * corner radius `0.30 × size`, stroke `max(3, 0.045 × size)`, `strokeBorder`
///   (draws **inside** the bounds, so the shape never grows past its frame);
/// * the recording waveform must fit **within** this frame when the frame is on —
///   the wave canvas is `1.10 × waveSize` wide, so the wave's size has to be capped
///   (`WatchBotFace` passes `size * 0.85` ⇒ 0.94 × size < the frame's inner width),
///   otherwise the wave crosses the stroke and reads as "the frame is being covered".
struct BotFaceFrame: View {
    /// The face's nominal side length (same basis as `WatchBotFace.size`).
    let size: CGFloat
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
            .strokeBorder(tint.opacity(0.85), lineWidth: max(3, size * 0.045))
            .frame(width: size * 1.02, height: size * 1.02)
    }
}

// MARK: - Blink pace + auto-express (★ 2026-10-20, settable on the iPhone)
/// How fast the face blinks — and how often the auto-express cycle swaps the expression.
///
/// Lives in this shared file for the same reason as `BotFaceStyle`: the iPhone pushes the raw tag,
/// both sides must agree on what it means, and the *preview* of "what lively looks like" is a lie
/// unless the watch multiplies the same numbers.
///
/// ## What the multiplier touches (and what it must not)
/// Only the **wait between** blinks scales (`WatchBotFace.nextBlinkGap()`). The 300 ms blink
/// keyframes do **not**: a human eyelid's closing speed doesn't change just because blinks come
/// more often — stretch those and "lively" turns into "sleepy with extra steps".
enum BotBlinkSpeed: String, CaseIterable, Codable, Identifiable {
    /// Long gaps — quieter than the "normal person" default.
    case slow
    /// The resting-human distribution shipped in revision twelve (the default).
    case normal
    /// Short gaps — noticeably awake. The near tier bottoms out around 2 s (below that
    /// reads as jitter, see `WatchBotFace.blinkGapNear`), so the multiplier stops there.
    case lively

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slow:   return L10n.Face.blinkSlow
        case .normal: return L10n.Face.blinkNormal
        case .lively: return L10n.Face.blinkLively
        }
    }

    /// Multiplies both blink-gap tiers. Kept inside the bounds the comments there document:
    /// slow 1.6× ⇒ far tier tops out at 28.8 s (a "dozing" look the user asked *for* when
    /// picking slow), lively 0.55× ⇒ near tier bottoms out at 1.93 s, just above the 2 s jitter floor.
    var gapMultiplier: Double {
        switch self {
        case .slow:   return 1.6
        case .normal: return 1.0
        case .lively: return 0.55
        }
    }

    /// How often the **auto-express cycle** swaps the idle expression (the "square frame
    /// dynamically cycling" behaviour). Drawn fresh from this range each swap — same
    /// "no metronome" rule as the blink gaps.
    var expressCycle: ClosedRange<Double> {
        switch self {
        case .slow:   return 7.0 ... 11.0
        case .normal: return 4.5 ... 7.5
        case .lively: return 2.8 ... 4.8
        }
    }
}

// MARK: - Hex validation (shared)

/// True when `hex` is exactly 6 hex digits (`RRGGBB`). CharacterSet-based
/// because `Character.isHexadecimal` doesn't exist on watchOS (the iOS build
/// took it from a Foundation overlay the watch SDK doesn't ship — measured
/// error in `WatchFaceStore.applySettings`).
func isValidFaceHex(_ hex: String) -> Bool {
    guard hex.count == 6 else { return false }
    return CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        .isSuperset(of: CharacterSet(charactersIn: hex))
}

// MARK: - Hex → Color (shared)

extension Color {
    /// `RRGGBB` (no `#`) → `Color`. Invalid input yields **white** — callers
    /// must gate on the hex being a valid shape (it is, by construction:
    /// `WatchFaceStore.applySettings` and `WatchFacePickerView.validHex`
    /// only accept 6 hex digits).
    ///
    /// Lives in the **shared** file so both targets compile exactly one copy:
    /// the picker on the phone tints its previews with the chosen colour, and
    /// the watch draws with it — two private copies would be two chances to drift.
    init(botHex hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

