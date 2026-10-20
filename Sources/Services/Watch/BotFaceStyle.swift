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
    static func eyeWidth(_ size: CGFloat) -> CGFloat { size * 0.235 }
    /// Height of the idle eye.
    static func eyeHeight(_ size: CGFloat) -> CGFloat { size * 0.375 }
    /// The gap **between** the two eyes (not the centre-to-centre distance).
    static func eyeGap(_ size: CGFloat) -> CGFloat { size * 0.235 }
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
        // ⚠️ The outer `frame` is **fixed** (`eyeWidth × eyeHeight`) and does not follow the expression.
        //    Being fixed: the `HStack` spacing doesn't change with the expression (a sudden widening of the eye gap is more noticeable than the expression
        //    itself), and the two drawing modes share one alignment baseline.
        //    Anything outside the box is not clipped — `frame` doesn't clip, only `.clipped()` does.
        .frame(width: w, height: h)
        .rotationEffect(.degrees(mirrored ? -geo.tilt : geo.tilt))
        // Open/close squashes from the centre with `scaleEffect(y:)` rather than changing `frame(height:)` —
        // changing the height would make the eye "grow from the bottom up", whereas a real eyelid comes down **from top and bottom at once**.
        .scaleEffect(y: openness, anchor: .center)
    }
}

/// A pair of eyes — that is what the home screen face looks like when idle.
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

