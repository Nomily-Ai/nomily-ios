import SwiftUI
import UIKit

// MARK: - Branch palette

/// Branch colours, ported from Vobot Recorder's mind-map palette
/// (`BRANCH_PALETTE`) so an exported map — or a map a user has already seen
/// in that app — reads the same way here.
///
/// Stored as components rather than `Color`s because the dark-mode variant
/// has to be *computed*: the palette is tuned for a near-white canvas, and
/// on a near-black one the same values turn muddy. Lifting each channel
/// toward white keeps the hue while restoring contrast.
private struct BranchColor {
    let r: Double
    let g: Double
    let b: Double

    func resolve(_ scheme: ColorScheme) -> Color {
        guard scheme == .dark else { return Color(red: r, green: g, blue: b) }
        let lift = 0.38
        return Color(red: r + (1 - r) * lift, green: g + (1 - g) * lift, blue: b + (1 - b) * lift)
    }

    /// The colour a **filled** chip uses (★ 2026-10-23, "增加一点模块色彩").
    ///
    /// A filled shape needs the opposite treatment from text on paper: on the
    /// light theme the base hue is already dark enough for white glyphs, while
    /// on the dark theme the lifted version turns pastel and white text would
    /// wash out. So the fill deepens toward the dark canvas instead of away
    /// from it — same hue, the side of it that can carry white text.
    func fill(_ scheme: ColorScheme) -> Color {
        guard scheme == .dark else { return Color(red: r, green: g, blue: b) }
        let sink = 0.34
        return Color(red: r * (1 - sink), green: g * (1 - sink), blue: b * (1 - sink))
    }
}

private let branchPalette: [BranchColor] = [
    BranchColor(r: 0.20, g: 0.20, b: 0.20),   // #333334 — index 0 is reserved for the root
    BranchColor(r: 0.29, g: 0.49, b: 0.35),   // #4a7c59 — moss
    BranchColor(r: 0.78, g: 0.42, b: 0.31),   // #c66b4e — terracotta
    BranchColor(r: 0.23, g: 0.42, b: 0.54),   // #3a6a8a — slate blue
    BranchColor(r: 0.55, g: 0.36, b: 0.62),   // #8d5b9e — plum
    BranchColor(r: 0.72, g: 0.53, b: 0.23),   // #b8863a — ochre
    // ★ 2026-10-23: three more hues so a summary with six or seven sections
    // never has to repeat a colour inside one map — repeated hues would say
    // "these two branches are the same module", which is the opposite of what
    // the colour is here to say.
    BranchColor(r: 0.18, g: 0.55, b: 0.55),   // #2e8c8c — teal
    BranchColor(r: 0.36, g: 0.38, b: 0.66),   // #5c61a8 — indigo
    BranchColor(r: 0.68, g: 0.32, b: 0.45),   // #ad5273 — rose
    BranchColor(r: 0.45, g: 0.50, b: 0.22),   // #738038 — olive
]

// MARK: - Layout engine

/// Pure geometry for a left-to-right mind map. No SwiftUI views here — the
/// engine only measures text and produces rectangles, which keeps it cheap
/// to re-run whenever the expand level changes and makes the layout
/// inspectable on its own.
struct MindMapLayout {

    struct Item: Identifiable {
        let id: Int
        let parentID: Int?
        let depth: Int
        let title: String
        let kind: OutlineNode.Kind
        let frame: CGRect
        /// Which top-level branch this node belongs to — the colour index.
        let branchIndex: Int
        /// Direct children in the *full* tree, whether or not they are being
        /// drawn right now. Non-zero is what makes a node worth tapping, and
        /// it's the number the collapsed badge shows.
        let childCount: Int
        /// Whether those children are currently drawn. `false` on a node with
        /// `childCount > 0` means there is more behind it.
        let isExpanded: Bool
    }

    struct Edge {
        let from: CGPoint
        let to: CGPoint
        let branchIndex: Int
        let depth: Int
    }

    let items: [Item]
    let edges: [Edge]
    let size: CGSize

    // Layout constants. Sizes step down with depth so the eye can tell a
    // section from a sub-point without reading either.
    //
    // ★ 2026-10-23 ("最左边的目录看不清被遮挡了"): the left margin went 24 → 34
    // and the root became a filled pill (see `MindMapNodeView`). Two things were
    // clipping the leftmost node in the screenshot: a 24 pt margin is under what
    // a rounded chip needs once its own padding and corner radius are counted,
    // and the zoomed-out scroll view kept whatever offset the previous pan left —
    // with the root hard against x = 24 there was nothing to keep it visible.
    // 34 pt is the pill's own padding + a full corner radius of breathing room.
    private static let margin: CGFloat = 34
    private static let horizontalGap: CGFloat = 32
    private static let verticalGap: CGFloat = 11
    private static let deepVerticalGap: CGFloat = 7

    static func font(for depth: Int) -> UIFont {
        switch depth {
        case 0: return .systemFont(ofSize: 17, weight: .semibold)
        case 1: return .systemFont(ofSize: 15, weight: .semibold)
        default: return .systemFont(ofSize: 13.5, weight: .regular)
        }
    }

    /// Matches `font(for:)` above — both must agree or the measured
    /// rectangle won't match what SwiftUI actually draws.
    static func weight(for depth: Int) -> Font.Weight { depth <= 1 ? .semibold : .regular }

    static func maxLines(for depth: Int) -> Int {
        switch depth {
        case 0: return 3
        case 1: return 4
        default: return 6
        }
    }

    static func horizontalPadding(for depth: Int) -> CGFloat { depth == 0 ? 14 : (depth == 1 ? 13 : 11) }
    static func verticalPadding(for depth: Int) -> CGFloat { depth == 0 ? 9 : (depth == 1 ? 8 : 7) }
    private static func maxNodeWidth(for depth: Int) -> CGFloat {
        switch depth {
        case 0: return 220
        case 1: return 210
        default: return 200
        }
    }

    /// ★ 2026-10-23: leaves carry a 3 pt colour rule on their leading edge (the
    /// "which module is this" cue now that the map is not all text). The rule and
    /// its gap have to come out of the measurable width, exactly like the fold
    /// badge does — otherwise a wide label wraps to a line the height was never
    /// measured for.
    static func accentWidth(for depth: Int) -> CGFloat { depth >= 2 ? 8 : 0 }

    /// Width held back beside a label that has children, for the fold
    /// chevron and its count. The two states of the badge are different
    /// widths, so the box reserves the wider one and never resizes while
    /// the user opens and closes branches.
    private static let foldedBadgeReserve: CGFloat = 26

    private static func nodeSize(title: String, depth: Int, hasChildren: Bool) -> CGSize {
        let font = font(for: depth)
        let padH = horizontalPadding(for: depth)
        let padV = verticalPadding(for: depth)
        // The badge sits *beside* the text, so the measurement has to hand
        // that width over to it — measuring at the full cap and then adding
        // a badge on top would wrap a long label onto a line the height was
        // never computed for.
        let badge: CGFloat = hasChildren ? foldedBadgeReserve : 0
        let accent = accentWidth(for: depth)
        let textCap = maxNodeWidth(for: depth) - padH * 2 - accent

        let measured = (title as NSString).boundingRect(
            with: CGSize(width: textCap, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        // Core Text returns the tight width, but laying the same text out at
        // exactly that width rounds a glyph onto the next line — CJK via the
        // PingFang fallback is the common case. Two points of slack on each
        // axis keeps the box the text was measured for from clipping it.
        let textWidth = ceil(measured.width) + 2
        let textHeight = min(ceil(measured.height) + 2, ceil(font.lineHeight) * CGFloat(maxLines(for: depth)))
        let width = min(textCap + badge, textWidth + badge) + accent + padH * 2
        let height = max(30, textHeight + padV * 2)
        // A two-character label would otherwise collapse into a dot.
        return CGSize(width: max(56, width), height: height)
    }

    /// Builds the map, drawing every branch the user has not folded away.
    ///
    /// Folding is per-node and lives entirely in `collapsed`: a node in that
    /// set is still drawn, its children are not. There is no global depth
    /// cutoff any more — an opening level is just an initial `collapsed` set
    /// (see `foldPoints(in:showingLevels:)`). That's what lets one heavy
    /// branch stay folded while the rest of the map is open, and what lets a
    /// tap open exactly the branch that was tapped.
    static func build(tree: OutlineNode, collapsed: Set<Int> = []) -> MindMapLayout {
        // ---- 1. Flatten the tree, stopping at folded nodes --------------
        struct Visible {
            let node: OutlineNode
            let parentID: Int?
            let branch: Int
            /// Whether this node's children are drawn. Not the same as
            /// "has no children" — a leaf and a folded branch both stop
            /// here, but only the latter is worth tapping.
            let isExpanded: Bool
        }
        var visible: [Visible] = []
        func walk(_ node: OutlineNode, parentID: Int?, branch: Int) {
            let expanded = !collapsed.contains(node.id)
            visible.append(Visible(node: node, parentID: parentID, branch: branch, isExpanded: expanded))
            guard expanded else { return }
            for (index, child) in node.children.enumerated() {
                // ★ +1: palette[0] is the root's near-black, so the first
                // section has to start at the first real hue — otherwise every
                // map's top branch came out grey.
                walk(child, parentID: node.id, branch: node.depth == 0 ? index + 1 : branch)
            }
        }
        walk(tree, parentID: nil, branch: 0)

        // ---- 2. Measure, and index children ----------------------------
        var sizes: [Int: CGSize] = [:]
        var childrenOf: [Int: [Int]] = [:]
        var byID: [Int: Visible] = [:]
        for entry in visible {
            sizes[entry.node.id] = nodeSize(
                title: entry.node.title,
                depth: entry.node.depth,
                hasChildren: !entry.node.children.isEmpty
            )
            byID[entry.node.id] = entry
            if let parentID = entry.parentID {
                childrenOf[parentID, default: []].append(entry.node.id)
            }
        }

        // ---- 3. Column geometry ---------------------------------------
        // Every node at a given depth shares an x; the column is as wide as
        // its widest member so nothing overlaps.
        let depths = visible.map(\.node.depth)
        let deepest = depths.max() ?? 0
        var columnWidth = [CGFloat](repeating: 0, count: deepest + 1)
        for entry in visible {
            let width = sizes[entry.node.id]?.width ?? 0
            columnWidth[entry.node.depth] = max(columnWidth[entry.node.depth], width)
        }
        var columnX = [CGFloat](repeating: margin, count: deepest + 1)
        // ★ (2026-10-18) `stride`, not `1...max(0, deepest)`.
        //
        // Collapsing every branch leaves only the root visible, so `deepest == 0` and
        // `1...max(0, 0)` becomes `1...0` — an invalid range, which Swift traps on with
        // `_assertionFailure` (crash report: `EXC_BREAKPOINT / SIGTRAP` inside
        // `MindMapLayout.build(tree:collapsed:)`, triggered by `MindMapScreen.toggle`).
        // `stride(from: 1, through: 0, by: 1)` is simply empty, which is the correct geometry.
        for depth in stride(from: 1, through: deepest, by: 1) {
            columnX[depth] = columnX[depth - 1] + columnWidth[depth - 1] + horizontalGap
        }

        // ---- 4. Vertical stacking (post-order) -------------------------
        // A subtree is as tall as the sum of its children; the parent is
        // centred against that span, which is what makes the tree read as a
        // fan rather than a staircase.
        var subtreeHeight: [Int: CGFloat] = [:]
        func measureHeight(_ id: Int) -> CGFloat {
            let kids = childrenOf[id] ?? []
            let own = sizes[id]?.height ?? 0
            guard !kids.isEmpty else {
                subtreeHeight[id] = own
                return own
            }
            let gap = (byID[id]?.node.depth ?? 0) >= 1 ? deepVerticalGap : verticalGap
            let total = kids.reduce(0) { $0 + measureHeight($1) } + gap * CGFloat(kids.count - 1)
            let height = max(own, total)
            subtreeHeight[id] = height
            return height
        }
        let rootHeight = measureHeight(tree.id)

        var frames: [Int: CGRect] = [:]
        func place(_ id: Int, top: CGFloat) {
            let own = sizes[id] ?? .zero
            let total = subtreeHeight[id] ?? own.height
            let kids = childrenOf[id] ?? []
            let myTop = top + (total - own.height) / 2
            frames[id] = CGRect(x: columnX[byID[id]?.node.depth ?? 0], y: myTop, width: own.width, height: own.height)

            guard !kids.isEmpty else { return }
            let gap = (byID[id]?.node.depth ?? 0) >= 1 ? deepVerticalGap : verticalGap
            let childrenTotal = kids.reduce(0) { $0 + (subtreeHeight[$1] ?? 0) } + gap * CGFloat(kids.count - 1)
            var cursor = top + (total - childrenTotal) / 2
            for child in kids {
                place(child, top: cursor)
                cursor += (subtreeHeight[child] ?? 0) + gap
            }
        }
        place(tree.id, top: margin)

        // ---- 5. Emit ----------------------------------------------------
        var items: [Item] = []
        var edges: [Edge] = []
        for entry in visible {
            guard let frame = frames[entry.node.id] else { continue }
            items.append(Item(
                id: entry.node.id,
                parentID: entry.parentID,
                depth: entry.node.depth,
                title: entry.node.title.isEmpty ? "" : entry.node.title,
                kind: entry.node.kind,
                frame: frame,
                branchIndex: entry.branch,
                childCount: entry.node.children.count,
                isExpanded: entry.isExpanded
            ))
            guard let parentFrame = entry.parentID.flatMap({ frames[$0] }) else { continue }
            edges.append(Edge(
                from: CGPoint(x: parentFrame.maxX, y: parentFrame.midY),
                to: CGPoint(x: frame.minX, y: frame.midY),
                branchIndex: entry.branch,
                depth: entry.node.depth
            ))
        }

        let width = columnX[deepest] + columnWidth[deepest] + margin
        let height = rootHeight + margin * 2
        return MindMapLayout(items: items, edges: edges, size: CGSize(width: ceil(width), height: ceil(height)))
    }

    /// The ids to fold so that only the first `levels` tiers are open — the
    /// fold set the "Branches" menu hands to `build`.
    ///
    /// A node *shallower* than the cut is deliberately left out: folding it
    /// would hide tiers the user just asked to see. Deeper nodes do go in,
    /// which is what makes a single tap open exactly one more tier — the
    /// children that appear are themselves already folded.
    static func foldPoints(in tree: OutlineNode, showingLevels levels: Int) -> Set<Int> {
        var folded: Set<Int> = []
        func walk(_ node: OutlineNode) {
            if node.depth >= levels, !node.children.isEmpty { folded.insert(node.id) }
            node.children.forEach(walk)
        }
        walk(tree)
        return folded
    }
}

// MARK: - Canvas

/// Draws a laid-out mind map at 1:1. Used twice: inside the zoomable
/// screen, and as the content handed to `ImageRenderer` for PNG export.
struct MindMapCanvas: View {
    let layout: MindMapLayout
    /// Supplied by the caller when drawing off-screen so the export matches
    /// the appearance the user is looking at.
    var labelForRoot: String = ""
    /// Called when a node that has children is tapped. The off-screen
    /// rendering used for PNG export leaves this alone — a picture has no
    /// branches left to open.
    var onToggle: (Int) -> Void = { _ in }
    /// ★ 2026-10-23: the preview card paints its own card background, so the
    /// canvas's beige fill would read as a mismatched inner rectangle. The
    /// zoomable screen and the PNG export keep the fill.
    var showsBackground: Bool = true

    @Environment(\.colorScheme) private var scheme

    private var canvasFill: Color {
        scheme == .dark ? Color(white: 0.07) : Color(red: 0.980, green: 0.980, blue: 0.969)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsBackground {
                canvasFill
            }

            ForEach(Array(layout.edges.enumerated()), id: \.offset) { _, edge in
                // ★ 2026-10-23 ("增加一点模块色彩之类的突出"): one count per branch
                // colour again. The previous pass went all-neutral to match a
                // reference screenshot, but with text-only nodes the map read as
                // one undifferentiated grey nest — colour is now the only thing
                // that says "these five lines are the same module", so each edge
                // inherits its branch's hue (softer than the chips, so the ink
                // still belongs to the words).
                EdgeShape(edge: edge)
                    .stroke(
                        ink(edge.branchIndex).opacity(edge.depth <= 1 ? 0.55 : 0.34),
                        style: StrokeStyle(
                            lineWidth: edge.depth <= 1 ? 1.5 : 1,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            }

            ForEach(layout.items) { item in
                MindMapNodeView(
                    item: item,
                    colour: fill(item.branchIndex),
                    rootLabel: labelForRoot,
                    onTap: { onToggle(item.id) }
                )
                .frame(width: item.frame.width, height: item.frame.height)
                .position(x: item.frame.midX, y: item.frame.midY)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    /// The colour a **filled chip** uses (root excluded — see `MindMapNodeView`).
    private func fill(_ index: Int) -> Color {
        branchPalette[index % branchPalette.count].fill(scheme)
    }

    /// The colour an **edge** uses: the readable-on-paper variant, so a link
    /// stays visible on the canvas without competing with the chips it connects.
    private func ink(_ index: Int) -> Color {
        branchPalette[index % branchPalette.count].resolve(scheme)
    }

    private struct EdgeShape: Shape {
        let edge: MindMapLayout.Edge

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let dx = max(12, (edge.to.x - edge.from.x) * 0.45)
            path.move(to: edge.from)
            path.addCurve(
                to: edge.to,
                control1: CGPoint(x: edge.from.x + dx, y: edge.from.y),
                control2: CGPoint(x: edge.to.x - dx, y: edge.to.y)
            )
            return path
        }
    }
}

// MARK: - Node

private struct MindMapNodeView: View {
    let item: MindMapLayout.Item
    /// The branch colour, already resolved for the current scheme (a **fill**
    /// colour — see `BranchColor.fill`).
    let colour: Color
    let rootLabel: String
    let onTap: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var isRoot: Bool { item.depth == 0 }
    private var isSection: Bool { item.depth == 1 }
    private var isLeaf: Bool { item.depth >= 2 }
    /// Only a node with something behind it is a control.
    private var isTappable: Bool { item.childCount > 0 }

    private var text: String {
        if item.title.isEmpty, isRoot, !rootLabel.isEmpty { return rootLabel }
        return item.title
    }

    private var cornerRadius: CGFloat { isRoot ? 13 : (isSection ? 11 : 9) }

    // MARK: Inks — the chips carry the colour, so the text has to follow it.

    private var textColour: Color {
        // The root chip **inverts** with the theme (near-black on paper,
        // near-white on the dark canvas), so its text has to invert with it —
        // white-on-white would erase the very node the user said was clipped.
        if isRoot { return scheme == .dark ? Color(white: 0.10) : .white }
        if isSection { return .white }
        return scheme == .dark ? Color(white: 0.93) : Color(white: 0.12)
    }

    /// The chip behind the words. This is the "模块色彩" the user asked for:
    ///
    /// * **root** — near-black (light theme) / near-white (dark theme): the
    ///   anchor of the map, deliberately **not** one of the branch hues;
    /// * **section (depth 1)** — a solid fill in the branch hue, white text:
    ///   each outline section reads as one coloured module at a glance;
    /// * **leaf (depth 2+)** — a 12%-tinted card of the same hue plus a 3 pt
    ///   rule on its leading edge, so it belongs to the module without shouting.
    private var chipFill: Color {
        if isRoot {
            return scheme == .dark ? Color(white: 0.90) : Color(red: 0.16, green: 0.16, blue: 0.17)
        }
        if isSection { return colour }
        return colour.opacity(scheme == .dark ? 0.24 : 0.12)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            if isLeaf {
                // The module rule. Height follows the text block rather than the
                // chip so a two-line leaf doesn't get a stubby tick.
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(colour)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, 1)
            }

            Text(text)
                .font(.system(size: MindMapLayout.font(for: item.depth).pointSize,
                              weight: MindMapLayout.weight(for: item.depth)))
                .foregroundStyle(textColour)
                .lineLimit(MindMapLayout.maxLines(for: item.depth))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            if isTappable { foldBadge }
        }
        .padding(.horizontal, MindMapLayout.horizontalPadding(for: item.depth))
        .padding(.vertical, MindMapLayout.verticalPadding(for: item.depth))
        .frame(width: item.frame.width, height: item.frame.height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(chipFill)
        )
        .overlay(
            // Sections and leaves get a hairline of their own hue: on a busy map
            // two adjacent chips of similar tint would otherwise melt together.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    (isRoot ? Color.clear : colour.opacity(isSection ? 0 : 0.28)),
                    lineWidth: 1
                )
        )
        .shadow(
            color: isRoot ? Color.black.opacity(scheme == .dark ? 0.4 : 0.18) : .clear,
            radius: 6, x: 0, y: 2
        )
        // The whole box is the target, not just the glyphs, so a branch is
        // as easy to hit as it is to read.
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture { if isTappable { onTap() } }
    }

    /// The chevron that says "there is more here". It sits on the first text
    /// line rather than the box's centre — on a six-line node a centred
    /// chevron reads as belonging to the wrong thing.
    ///
    /// The count shows only while folded; once the branch is open, its
    /// children are on screen and the number would just be noise.
    /// Badge ink follows the chip it sits on (white on a filled chip, the
    /// branch hue on a leaf) — and on the root that means inverting with the
    /// theme, exactly like `textColour`.
    private var badgeColour: Color {
        if isRoot {
            return (scheme == .dark ? Color(white: 0.10) : Color.white).opacity(0.72)
        }
        if isSection { return Color.white.opacity(0.72) }
        return colour.opacity(0.95)
    }

    private var foldBadge: some View {
        HStack(spacing: 1.5) {
            Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
            if !item.isExpanded {
                Text(verbatim: "\(item.childCount)")
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(badgeColour)
        .padding(.top, isRoot ? 4 : 2)
        .fixedSize()
    }
}

// MARK: - Screen

/// Full-screen mind map for one summary, with pan, pinch-zoom, per-branch
/// folding, a branch-level preset and PNG export.
///
/// PNG export renders the map **as it currently stands** — a branch the user
/// has folded away is not in the picture. That's the point: folding is how
/// you decide what the shot should contain.
struct MindMapScreen: View {
    /// Used as the root node's label when the summary has no single
    /// top-level heading of its own.
    let fallbackTitle: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private let tree: OutlineNode?

    /// The opening level, kept as the "Branches" menu's selection. Picking a
    /// level re-folds the whole map to it; folding a branch by hand does not
    /// move the menu, because the two are different questions — "where
    /// should this start" versus "what am I looking at now".
    @State private var expandLevel: Int
    /// Branches the user has closed, by node id. This is the whole fold
    /// state: `build` reads nothing else.
    @State private var collapsed: Set<Int>
    /// Cached rather than computed in `body`. Laying the map out measures
    /// every label with Core Text; recomputing that on each pinch frame
    /// would make zooming stutter on a long summary.
    @State private var layout: MindMapLayout?
    @State private var scale: CGFloat = 1
    @State private var gestureScale: CGFloat = 1
    @State private var exportedPNG: URL?
    @State private var showShareSheet = false
    @State private var exportError: String?

    init(markdown: String, fallbackTitle: String) {
        self.fallbackTitle = fallbackTitle
        // The summary never changes while the screen is open, so parse and
        // lay out exactly once, here — from the same fold set the screen
        // starts with.
        let parsed = MarkdownOutline.parse(markdown)
        let level = min(3, max(1, parsed?.maxDepth ?? 1))
        let folded = parsed.map { MindMapLayout.foldPoints(in: $0, showingLevels: level) } ?? []
        self.tree = parsed
        _expandLevel = State(initialValue: level)
        _collapsed = State(initialValue: folded)
        _layout = State(initialValue: parsed.map { MindMapLayout.build(tree: $0, collapsed: folded) })
    }

    var body: some View {
        NavigationStack {
            Group {
                if let layout {
                    map(layout)
                } else {
                    emptyState
                }
            }
            .navigationTitle(L10n.ClipDetail.mindMap)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .sheet(isPresented: $showShareSheet) {
            if let exportedPNG { ShareSheet(items: [exportedPNG]) }
        }
        .alert(
            L10n.ClipDetail.mindMapExportFailed,
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button(L10n.Common.ok, role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: map

    private func map(_ layout: MindMapLayout) -> some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                MindMapCanvas(layout: layout, labelForRoot: fallbackTitle, onToggle: toggle)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: layout.size.width * scale, height: layout.size.height * scale, alignment: .topLeading)
                    .padding(4)
            }
            .background(scheme == .dark ? Color(white: 0.07) : Color(red: 0.980, green: 0.980, blue: 0.969))
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(3, max(0.25, gestureScale * value))
                    }
                    .onEnded { _ in gestureScale = scale }
            )
            .onAppear { gestureScale = scale }
            .overlay(alignment: .bottom) { legend(layout: layout, viewport: geo.size) }
        }
        .onChange(of: expandLevel) { level in
            guard let tree else { return }
            collapsed = MindMapLayout.foldPoints(in: tree, showingLevels: level)
            rebuildLayout()
            // A user who zoomed out to read a deep map should not stay
            // zoomed out once the map collapses back to a shallow one.
            withAnimation(.easeOut(duration: 0.18)) { resetZoom() }
        }
    }

    /// Opens or closes one branch. Deliberately does *not* touch the zoom —
    /// folding is a statement about what the user wants to look at, and
    /// resetting their zoom on top of it would undo a decision they made.
    private func toggle(_ id: Int) {
        if collapsed.contains(id) {
            collapsed.remove(id)
        } else {
            collapsed.insert(id)
        }
        withAnimation(.easeInOut(duration: 0.22)) { rebuildLayout() }
    }

    /// The one button that has to mean two things. Nothing folded means the
    /// whole tree is already on screen, so its job flips to folding the map
    /// back to a single tier of branches; anything else means there is
    /// something to open, so it opens everything.
    private func toggleAll() {
        guard let tree else { return }
        collapsed = collapsed.isEmpty
            ? MindMapLayout.foldPoints(in: tree, showingLevels: 1)
            : []
        withAnimation(.easeInOut(duration: 0.24)) { rebuildLayout() }
    }

    private func rebuildLayout() {
        guard let tree else { return }
        layout = MindMapLayout.build(tree: tree, collapsed: collapsed)
    }

    /// Floating zoom / fit controls, kept over the map's bottom edge so the
    /// navigation bar stays free for the expand-level picker and export.
    @ViewBuilder
    private func legend(layout: MindMapLayout, viewport: CGSize) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { zoom(by: -0.25) }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(scale <= 0.26)

            Text("\(Int((scale * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)

            Button {
                withAnimation(.easeOut(duration: 0.18)) { zoom(by: 0.25) }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(scale >= 3)

            Divider().frame(height: 18)

            Button {
                withAnimation(.easeOut(duration: 0.2)) { fit(layout: layout, viewport: viewport) }
            } label: {
                Label(L10n.ClipDetail.mindMapFit, systemImage: "arrow.up.left.and.arrow.down.right")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.thinMaterial, in: Capsule())
        .padding(.bottom, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(L10n.ClipDetail.mindMapEmpty)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(L10n.Common.close) { dismiss() }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 14) {
                if let tree {
                    Menu {
                        Picker(L10n.ClipDetail.mindMapLevel, selection: $expandLevel) {
                            ForEach(1...max(1, tree.maxDepth), id: \.self) { level in
                                Text(verbatim: "\(level)").tag(level)
                            }
                        }
                    } label: {
                        Label(L10n.ClipDetail.mindMapLevel, systemImage: "list.bullet.indent")
                    }
                    .disabled(tree.maxDepth <= 1)
                }

                if let tree, tree.maxDepth > 1 {
                    Button {
                        toggleAll()
                    } label: {
                        Image(systemName: collapsed.isEmpty
                              ? "rectangle.compress.vertical"
                              : "rectangle.expand.vertical")
                    }
                    .accessibilityLabel(collapsed.isEmpty
                                        ? L10n.ClipDetail.mindMapCollapseAll
                                        : L10n.ClipDetail.mindMapExpandAll)
                }

                Button {
                    exportPNG()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(layout == nil)
            }
        }
    }

    // MARK: zoom helpers

    private func resetZoom() {
        scale = 1
        gestureScale = 1
    }

    private func zoom(by delta: CGFloat) {
        scale = min(3, max(0.25, scale + delta))
        gestureScale = scale
    }

    private func fit(layout: MindMapLayout, viewport: CGSize) {
        guard viewport.width > 0, layout.size.width > 0 else { return }
        let horizontal = (viewport.width - 16) / layout.size.width
        let vertical = (viewport.height - 60) / layout.size.height
        let target = min(horizontal, vertical, 1)
        // Never shrink past the point where the 13.5 pt labels stop being
        // readable; below that, scrolling beats squinting.
        scale = min(1, max(0.42, target))
        gestureScale = scale
    }

    // MARK: export

    @MainActor
    private func exportPNG() {
        guard let layout else { return }
        // ★ (2026-10-19) Drawn with Core Graphics instead of `ImageRenderer`.
        //
        // `ImageRenderer` on this canvas came back as a **blank page** on device: the SwiftUI
        // tree renders fine on screen, but off-screen it produced an empty bitmap, so the share
        // sheet previewed (and shared) nothing. The exporter below draws the same layout —
        // background, edges, node cards, labels — straight into a bitmap context, with no view
        // hierarchy in the loop at all, which cannot come out blank.
        let scale: CGFloat
        let points = layout.size.width * layout.size.height
        if points > 8_000_000 {
            scale = 1
        } else if points > 2_000_000 {
            scale = 2
        } else {
            scale = 3
        }

        guard let image = MindMapExporter.image(
            layout: layout, rootLabel: fallbackTitle, dark: scheme == .dark, scale: scale
        ), let data = image.pngData() else {
            exportError = L10n.ClipDetail.mindMapExportFailed
            return
        }
        let stem = fallbackTitle.isEmpty ? "mindmap" : fallbackTitle
        let safe = stem.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).png")
        do {
            try data.write(to: url, options: .atomic)
            exportedPNG = url
            showShareSheet = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - Core Graphics export

/// Draws a laid-out mind map straight into a bitmap. Deliberately separate from the SwiftUI
/// canvas: the export has to be reproducible off-screen, and it is the only copy of this
/// drawing that runs without a window.
enum MindMapExporter {

    @MainActor
    static func image(layout: MindMapLayout, rootLabel: String, dark: Bool, scale: CGFloat) -> UIImage? {
        let size = layout.size
        guard size.width > 1, size.height > 1,
              size.width.isFinite, size.height.isFinite,
              size.width * size.height < 60_000_000 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = min(max(scale, 1), 3)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            let background = dark
                ? UIColor(white: 0.07, alpha: 1)
                : UIColor(red: 0.980, green: 0.980, blue: 0.969, alpha: 1)
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Edges first, same curve as `EdgeShape`.
            for edge in layout.edges {
                let dx = max(12, (edge.to.x - edge.from.x) * 0.45)
                let path = UIBezierPath()
                path.move(to: edge.from)
                path.addCurve(
                    to: edge.to,
                    controlPoint1: CGPoint(x: edge.from.x + dx, y: edge.from.y),
                    controlPoint2: CGPoint(x: edge.to.x - dx, y: edge.to.y)
                )
                path.lineWidth = edge.depth <= 1 ? 2 : 1.4
                path.lineCapStyle = .round
                UIColor(branchPalette[edge.branchIndex % branchPalette.count]
                    .resolve(dark ? .dark : .light))
                    .withAlphaComponent(edge.depth <= 1 ? 0.75 : 0.5)
                    .setStroke()
                path.stroke()
            }

            for item in layout.items {
                drawNode(item, rootLabel: rootLabel, dark: dark)
            }
        }
    }

    private static func drawNode(_ item: MindMapLayout.Item, rootLabel: String, dark: Bool) {
        let rect = item.frame
        let radius: CGFloat = item.depth == 0 ? 13 : (item.depth == 1 ? 11 : 9)
        let scheme: ColorScheme = dark ? .dark : .light
        let branch = branchPalette[item.branchIndex % branchPalette.count]

        // ★ 2026-10-23: the export follows the on-screen chips exactly — root
        // near-black, section solid in its branch hue, leaf a 12% tint with a
        // 3 pt rule on the leading edge. An export that disagreed with the
        // screen was the reason this function used to be "close but not quite".
        let fill: UIColor
        if item.depth == 0 {
            fill = dark ? UIColor(white: 0.90, alpha: 1) : UIColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)
        } else if item.depth == 1 {
            fill = UIColor(branch.fill(scheme))
        } else {
            fill = UIColor(branch.fill(scheme)).withAlphaComponent(dark ? 0.24 : 0.12)
        }
        fill.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()

        if item.depth >= 2 {
            // The module rule. Drawn inside the chip so the rounded corner can't
            // clip it into a half-moon.
            let rule = CGRect(x: rect.minX + 5, y: rect.minY + 6, width: 3, height: max(2, rect.height - 12))
            UIColor(branch.fill(scheme)).setFill()
            UIBezierPath(roundedRect: rule, cornerRadius: 1.5).fill()
        }

        if item.depth == 1 {
            // A slightly darker edge in the chip's own hue keeps two sections of
            // similar tint from melting together at export scale.
            UIColor(branch.fill(scheme)).withAlphaComponent(0.9).setStroke()
            let outline = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: radius)
            outline.lineWidth = 1
            outline.stroke()
        }

        let title = (item.title.isEmpty && item.depth == 0 && !rootLabel.isEmpty) ? rootLabel : item.title
        guard !title.isEmpty else { return }

        let textColor: UIColor
        if item.depth == 0 {
            // Same inversion as the on-screen chip: dark chip on paper, light
            // chip on the dark canvas.
            textColor = dark ? UIColor(white: 0.10, alpha: 1) : .white
        } else if item.depth == 1 {
            textColor = .white
        } else {
            textColor = dark ? UIColor(white: 0.93, alpha: 1) : UIColor(white: 0.12, alpha: 1)
        }
        let font = UIFont.systemFont(
            ofSize: item.depth == 0 ? 15 : 13.5,
            weight: item.depth == 0 ? .semibold : (item.depth == 1 ? .semibold : .regular)
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        // Leaves indent past their colour rule; sections and the root do not
        // carry one.
        let inset: CGFloat = item.depth >= 2 ? 13 : 10
        let available = CGSize(width: max(1, rect.width - inset * 2), height: max(1, rect.height - 4))
        let bounding = (title as NSString).boundingRect(
            with: available, options: [.usesLineFragmentOrigin], attributes: attributes, context: nil
        )
        let textRect = CGRect(
            x: rect.minX + inset,
            y: rect.midY - bounding.height / 2,
            width: available.width,
            height: min(bounding.height, available.height)
        )
        (title as NSString).draw(in: textRect, withAttributes: attributes)
    }
}

// MARK: - Preview card

/// The mind map as it appears **inside the note page** — Plaud's white card with
/// the map drawn small and one tap opening the zoomable screen.
///
/// ★ 2026-10-23 ("参考一下页面布局跟结构"): the note page used to offer a plain
/// "思维导图" row. A row says nothing about what is in the map; a thumbnail does,
/// and it is what Plaud shows between the last section and the ask box.
///
/// The layout is built once in `init` at two levels deep — the card is a
/// thumbnail, not a reading surface, and laying out the full tree for a
/// 200 pt-tall box would only produce unreadable overlaps.
struct MindMapPreviewCard: View {

    let title: String
    var onTap: () -> Void

    private let layout: MindMapLayout?
    private static let previewHeight: CGFloat = 190

    init(markdown: String, title: String, onTap: @escaping () -> Void) {
        self.title = title
        self.onTap = onTap
        guard let tree = MarkdownOutline.parse(markdown) else {
            self.layout = nil
            return
        }
        // ★ 2026-10-23 ("思维导图展示有问题"): a busy map folded to two levels
        // scales down to unreadable dots inside a 190 pt card. The preview
        // adapts: few sections keep their sub-points, many sections collapse
        // to the section row only — the same picture Plaud's card shows.
        let topSections = tree.children.count
        let levels = topSections > 8 ? 1 : min(2, max(1, tree.maxDepth))
        let folded = MindMapLayout.foldPoints(in: tree, showingLevels: levels)
        self.layout = MindMapLayout.build(tree: tree, collapsed: folded)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.ClipDetail.mindMap)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)

                GeometryReader { geo in
                    if let layout {
                        let fit = min(
                            1,
                            min(geo.size.width / max(layout.size.width, 1),
                                Self.previewHeight / max(layout.size.height, 1))
                        )
                        MindMapCanvas(layout: layout, labelForRoot: title, showsBackground: false)
                            .scaleEffect(fit, anchor: .topLeading)
                            .frame(
                                width: layout.size.width * fit,
                                height: layout.size.height * fit,
                                alignment: .topLeading
                            )
                    }
                }
                .frame(height: Self.previewHeight)
                .clipped()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.ClipDetail.mindMap)
    }
}
