import SwiftUI

// MARK: - 手表首页那张脸能摆的表情
//
// ★★ 2026-10-16 十三改（用户原话："需要在 Nomily AI APP 里面的设置里面增加一个
//    就是设置手表的首页眼睛的表情，把之前的 github 里面 gork bot 的表情放入到
//    Nomily ai 的设置里面支持放入他们的表情"）。
//
// 十二改的那五个表情（`EyeMood`）是**只读的**：用户轻点一下，随机抽一个演一遍。
// 这一轮要的是**能选**：把它变成一个库，摆在 iPhone 的设置里，选中的那一档
// **常驻**在手表的首页上。
//
// ─────────────────────────────────────────────────────────────────────────
// ## 为什么这个文件在 `Sources/Services/Watch/`（两端共用）
//
// 因为它**必须**被两端同时看到，而且理由不是省代码：
//
//   · **iPhone** 要用它摆那个选择器的预览（"我选的到底长什么样"）；
//   · **watch** 要用它决定首页那两只眼睛怎么画。
//
// 两边各写一份的话，预览和真机就会**漂移** —— 而这种漂移恰恰是最难被发现、
// 也最伤人的一种：用户在手机上看到一个笑眼，抬腕发现是垂眼。同一个枚举、
// 同一套几何，两边就永远一致。做法与 `WatchLinkMessage` / `RecordingName`
// 同款（都列在 `project.yml` 的 `nomily_watch.sources` 里）。
//
// ─────────────────────────────────────────────────────────────────────────
// ## 素材来自 `aora-bot`，但**只搬得动九个**
//
// 参考仓库（`sam70361/aora-bot`，`mood-mates/src/core/geometry.js`）有 **20 个
// 眼形槽位**：`calm / calm2 / happy / happy2 / wide / wide2 / closed / closed2 /
// sleepy / squint / squint2 / angry / angry2 / scan / scan2 / scan3 /
// listen / listen2 / shy / sad`。每个槽位是一组参数
// `{ w, h, bend, taper, slope, shift }`。
//
// ⚠️ 那只眼睛在那儿是一条**可弯的路径**，`bend`（怎么弯）与 `taper`（两端怎么
//    收细）是它最主要的两个维度。这里的一只眼睛是"圆头竖条 + 可选一段弧"，
//    画不了任意曲线。所以真正能表达的维度只有四个：
//
//      · **高**（`scaleY`）—— 睁大 / 眯起
//      · **宽**（`scaleX`）
//      · **倾角**（`tilt`）—— 斜
//      · **直 / 弯**（`arc`）—— 弯的那两种换成描边的 `BotFaceEyeCurve`
//
//    于是下面九档是**选出来的**，不是照单全收。
//
// ## ⚠️ 挑的时候守的三条
//
// 1. **一眼能分辨。** 参考实现里 `calm` 与 `calm2` 的差别是宽 ×0.96、高 ×1.05
//    —— 4% / 5%，比待机的呼吸（±1.8%）大不了多少。放进这个选择器，用户会在
//    九格里挑出两格"看不出差别"的，然后得出"这个功能是摆设"的结论。
//    ⇒ 九档必须**隔着半米也能认出是不同表情**。
// 2. **不留"闭眼"档。** 参考实现里的 `closed` / `sleepy`（完全闭合）**没有**
//    搬过来 —— 一个常驻的闭眼表情会和**眨眼**撞车：用户分不清"它在对我眨眼"
//    和"我选的就是这个"。想安静请选 `squint`（睁着一条缝），那是"眯"不是"睡"。
// 3. **不留"几乎和待机一样"的档。** `calm` 就是待机本身，所以它同时是默认值，
//    也是**轻点时被排除**的那一档（见 `tapPool(excluding:)`）。
enum BotFaceStyle: String, CaseIterable, Codable, Identifiable {
    /// 平静。默认值 —— 一条圆头竖条，什么都不加。
    case calm
    /// 笑眼。∩ 拱起来的那条弧。
    case happy
    /// 垂眼。∪ 往下垮的那条弧 —— "泄了气"。
    case sad
    /// 圆睁。整只眼放大一圈。
    case wide
    /// 眯眼。高度压到三分之一，宽度略微放开。
    case squint
    /// 斜瞪。两眼下端向中线收拢，眉心的"∧"。
    case angry
    /// 害羞。扁而宽，上端向内收 —— "∨"那一档。
    case shy
    /// 聆听。细高的一只，像在等对方把话说完。
    case listen
    /// 扫视。窄而高的一条缝，像正在来回扫。
    case scan

    var id: String { rawValue }

    /// 选择器里的名字。**跟着 App 语言走**（`L10n` 全是计算属性）。
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
        }
    }

    /// 一档表情的全部几何参数。
    ///
    /// ## 为什么是"一个 switch 返回一个结构体"，而不是五个各自 switch 的计算属性
    /// 五个属性就是 `9 × 5 = 45` 个数字，散在五行不同的 switch 里。想核对
    /// "`shy` 到底是什么形状"得来回跳五次，而想加一档就得同时改五处 ——
    /// 漏一处不会编译报错，只会静默地继承另一个档位的某个维度。
    /// 一个结构体一行，读起来就是一张表。
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
        }
    }

    /// 这档`编码后能不能被解析回来` —— 手机推过来的 tag 要走这一关。
    ///
    /// 手机与手表的 App 版本可以**不一致**（手表的更新由 iPhone 择机推送，
    /// 常常晚好几分钟甚至一个重启周期）。新版手机推来一个旧版手表不认识的
    /// tag 时，`init(rawValue:)` 返回 `nil`，手表**保持原样**而不是崩掉或者
    /// 退回默认值 —— 见 `WatchFaceStore.apply(_:)`。
    static func decode(_ tag: String?) -> BotFaceStyle? {
        guard let tag else { return nil }
        return BotFaceStyle(rawValue: tag)
    }

    /// 轻点那张脸时能抽到的那几档。
    ///
    /// ⚠️ 排除 `rest`（当前常驻的那一档）。不排除的话，用户选着笑眼、点一下
    ///    又抽到笑眼 —— 表现就是"点了没反应"，而那正是十二改要修掉的那个
    ///    抱怨（用户原话："眼睛需轻触它会有各种表情而不是单一的眼睛晃动"）。
    ///
    /// ⚠️ 也永远排除 `calm`：它就是待机本身，抽到同样等于没反应。
    static func tapPool(excluding rest: BotFaceStyle) -> [BotFaceStyle] {
        allCases.filter { $0 != .calm && $0 != rest }
    }
}

/// 一档表情的几何参数。默认值 = **待机**（一条 1:1 的圆头竖条，不弯不斜）。
struct BotFaceGeometry {
    /// 宽度倍数。
    var scaleX: CGFloat = 1
    /// 高度倍数。⚠️ 弧形档位**不吃**这个值 —— 见 `BotFaceEye`。
    var scaleY: CGFloat = 1
    /// **左眼**转多少度；右眼取相反数。
    ///
    /// ⚠️ 屏幕坐标 y 轴朝下，所以**正角度 = 顺时针**。左眼 −12°（逆时针）⇒
    ///    这根竖条的上端往**外**偏（离中线更远）、下端往**内**偏 ——
    ///    两只眼于是在**下方向中线收拢**，眉心形成一个"∧"。那才是"生气"。
    ///    正值反过来是"∨" = 委屈 / 害羞（`shy` 用 +10）。
    ///
    /// ⚠️ 更要紧的是"两只眼**相反**"这件事本身：两眼看同一个方向转（`///`）
    ///    不是生气，是斜视。所以这里只写左眼的数，右眼的取反在 `BotFaceEye` 里。
    var tilt: Double = 0
    /// `nil` = 直（圆头竖条）；有值 = 换成一条描边的弧。
    var arc: BotFaceArc?
}

/// 弧往哪边拱。
enum BotFaceArc {
    /// ∩ —— 顶点朝上（笑眼）。
    case up
    /// ∪ —— 顶点朝下（垂眼）。
    case down
}

// MARK: - 比例（唯一一处）

/// 这张脸的尺寸比例。**唯一一处**定义"眼睛多大、两眼隔多远"。
///
/// ⚠️ 全部按 `size` 取比例，不写死 —— 40mm 到 49mm 的表屏宽差 40pt，
///    写死任何一个数都至少在一种表上错位。
///
/// ★ 十三改从 `WatchBotFace` 搬到这里：选择器要在手机上摆预览，而"预览里
///   那只眼睛有多大"必须和"表上那只眼睛有多大"是**同一个算式**，否则
///   用户挑的表情和真机看到的不成比例。
enum BotFaceMetrics {
    /// 待机那只眼睛的宽。
    static func eyeWidth(_ size: CGFloat) -> CGFloat { size * 0.235 }
    /// 待机那只眼睛的高。
    static func eyeHeight(_ size: CGFloat) -> CGFloat { size * 0.375 }
    /// 两眼**之间**的空隙（不是中心距）。
    static func eyeGap(_ size: CGFloat) -> CGFloat { size * 0.235 }
    /// 整对眼睛比几何中心抬高多少。正好居中会显得"低着头"——
    /// 人脸的眼睛本来就在中线之上。
    static func eyeRise(_ size: CGFloat) -> CGFloat { -size * 0.03 }
    /// 弧形档位的弧高（相对待机眼睛的高度）。
    ///
    /// ⚠️ 弧**不**吃 `geometry.scaleY`："把一条 20pt 高的弧再乘 0.5"会让它
    ///    变成一条几乎看不见的细线，而不是"眯起来"。所以弧的两档给
    ///    `scaleY = 1`，高度由这里单独定。
    static func arcHeight(_ size: CGFloat) -> CGFloat { eyeHeight(size) * 0.44 }
    /// 弧的粗细。
    ///
    /// ⚠️ **不能画细**：细弧在表盘上会被读成一根眉毛、或者一道划痕；
    ///    粗到接近闭合眼睛的厚度，才读得出"这是一只眼睛"。
    ///    这也是为什么弧是"描边"而不是"填充" —— 粗细得能单独调。
    static func arcWidth(_ size: CGFloat) -> CGFloat { eyeHeight(size) * 0.20 }
}

// MARK: - 一只眼睛（唯一一处）

/// 按某一档表情画出**一只**眼睛。
///
/// ⚠️ 这里是"一个表情长什么样"的**唯一**实现：首页那张脸和手机上的选择器
///    都走它。各画一份的话，两者迟早会漂移。
///
/// ## 为什么两种画法是**叠着淡入淡出**，而不是 `if/else` 二选一
/// `if/else` 换的是**视图身份**，换的那一帧只会硬切一下（旧视图被删掉、
/// 新视图插进来）。而"胶囊 → 弧"恰恰需要平滑过渡 —— 用户看到的应该是
/// "眼睛眯成一条弧"，而不是"闪了一下"。
struct BotFaceEye: View {
    let style: BotFaceStyle
    /// 这张脸的**名义**边长，和 `WatchBotFace.size` 同一个口径。
    let size: CGFloat
    let tint: Color
    /// `true` = 右眼。只有带倾角的档位关心它（取反，于是两只眼自动对称）。
    let mirrored: Bool
    /// 开合度。1 = 全睁，0.05 = 闭合，可以短暂超过 1（眨眼的过冲）。
    var openness: CGFloat = 1

    private var geo: BotFaceGeometry { style.geometry }
    private var w: CGFloat { BotFaceMetrics.eyeWidth(size) }
    private var h: CGFloat { BotFaceMetrics.eyeHeight(size) }

    var body: some View {
        ZStack {
            Capsule()
                .fill(tint)
                .frame(width: w * geo.scaleX, height: h * geo.scaleY)
                .opacity(geo.arc == nil ? 1 : 0)

            BotFaceEyeCurve(up: geo.arc == .up)
                .stroke(tint, style: StrokeStyle(lineWidth: BotFaceMetrics.arcWidth(size), lineCap: .round))
                .frame(width: w * geo.scaleX, height: BotFaceMetrics.arcHeight(size))
                .opacity(geo.arc == nil ? 0 : 1)
        }
        // ⚠️ 外层这个 `frame` 是**固定**的（`eyeWidth × eyeHeight`），不跟表情走。
        //    固定之后：`HStack` 的间距不会因为表情而变（两眼间距突然变宽比表情
        //    本身更显眼），两种画法也才有同一个对齐基准。
        //    超出这个框的部分不会被裁 —— `frame` 不裁，`.clipped()` 才会。
        .frame(width: w, height: h)
        .rotationEffect(.degrees(mirrored ? -geo.tilt : geo.tilt))
        // 睁/闭用 `scaleEffect(y:)` 从中心压扁，而不是改 `frame(height:)` ——
        // 改高度会让眼睛"从下往上长"，而真实的眼皮是**上下一起**盖下来的。
        .scaleEffect(y: openness, anchor: .center)
    }
}

/// 一对眼睛 —— 就是首页那张脸空闲时的样子。
struct BotFacePair: View {
    let style: BotFaceStyle
    let size: CGFloat
    let tint: Color
    var openness: CGFloat = 1

    var body: some View {
        HStack(spacing: BotFaceMetrics.eyeGap(size)) {
            BotFaceEye(style: style, size: size, tint: tint, mirrored: false, openness: openness)
            BotFaceEye(style: style, size: size, tint: tint, mirrored: true, openness: openness)
        }
    }
}

/// 一段向上（∩）或向下（∪）拱的弧。
///
/// ⚠️ 用二次贝塞尔而不是 `Circle().trim(from:to:)`：`trim` 的起点位置与绘制
///    方向挂在 SwiftUI 那套"y 轴朝下、角度顺时针"的约定上，改画法时最容易
///    出错、也最难读。而"两端落在中线上、顶点抬到边沿"用控制点写出来是
///    **自证**的 —— 下面那两行算式可以直接验算。
struct BotFaceEyeCurve: Shape {
    /// `true` = ∩（笑），`false` = ∪（垂）。
    let up: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // 二次贝塞尔的中点 B(0.5) = ¼P₀ + ½P₁ + ¼P₂。要让中点正好落在边沿
        // （上拱时的 `minY`），控制点就必须在**框外**再远一个高度：
        //   0.5·maxY + 0.5·P₁.y = minY  ⇒  P₁.y = 2·minY − maxY
        // 两端固定在另一条边沿上，于是这条弧正好铺满整个 `rect`。
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
