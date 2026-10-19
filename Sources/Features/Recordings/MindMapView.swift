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
}

private let branchPalette: [BranchColor] = [
    BranchColor(r: 0.20, g: 0.20, b: 0.20),   // #333334 — root
    BranchColor(r: 0.29, g: 0.49, b: 0.35),   // #4a7c59
    BranchColor(r: 0.78, g: 0.42, b: 0.31),   // #c66b4e
    BranchColor(r: 0.23, g: 0.42, b: 0.54),   // #3a6a8a
    BranchColor(r: 0.55, g: 0.36, b: 0.62),   // #8d5b9e
    BranchColor(r: 0.72, g: 0.53, b: 0.23),   // #b8863a
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
    private static let margin: CGFloat = 24
    private static let horizontalGap: CGFloat = 34
    private static let verticalGap: CGFloat = 9
    private static let deepVerticalGap: CGFloat = 6

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

    static func horizontalPadding(for depth: Int) -> CGFloat { depth == 0 ? 14 : 11 }
    static func verticalPadding(for depth: Int) -> CGFloat { depth == 0 ? 9 : 7 }
    private static func maxNodeWidth(for depth: Int) -> CGFloat {
        switch depth {
        case 0: return 210
        case 1: return 200
        default: return 190
        }
    }

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
        let textCap = maxNodeWidth(for: depth) - padH * 2

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
        let width = min(textCap + badge, textWidth + badge) + padH * 2
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
                walk(child, parentID: node.id, branch: node.depth == 0 ? index : branch)
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

    @Environment(\.colorScheme) private var scheme

    private var canvasFill: Color {
        scheme == .dark ? Color(white: 0.07) : Color(red: 0.980, green: 0.980, blue: 0.969)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            canvasFill

            ForEach(Array(layout.edges.enumerated()), id: \.offset) { _, edge in
                EdgeShape(edge: edge)
                    .stroke(
                        color(edge.branchIndex).opacity(edge.depth <= 1 ? 0.75 : 0.5),
                        style: StrokeStyle(lineWidth: edge.depth <= 1 ? 2 : 1.4, lineCap: .round)
                    )
            }

            ForEach(layout.items) { item in
                MindMapNodeView(
                    item: item,
                    colour: color(item.branchIndex),
                    rootLabel: labelForRoot,
                    onTap: { onToggle(item.id) }
                )
                .frame(width: item.frame.width, height: item.frame.height)
                .position(x: item.frame.midX, y: item.frame.midY)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private func color(_ index: Int) -> Color {
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
    let colour: Color
    let rootLabel: String
    let onTap: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var isRoot: Bool { item.depth == 0 }
    private var isSection: Bool { item.depth == 1 }
    /// Only a node with something behind it is a control.
    private var isTappable: Bool { item.childCount > 0 }

    private var text: String {
        if item.title.isEmpty, isRoot, !rootLabel.isEmpty { return rootLabel }
        return item.title
    }

    private var cornerRadius: CGFloat { isRoot ? 10 : (isSection ? 9 : 7) }

    private var rootFill: Color {
        scheme == .dark ? Color(white: 0.92) : Color(red: 0.20, green: 0.20, blue: 0.20)
    }

    private var surfaceFill: Color {
        scheme == .dark ? Color(white: 1, opacity: 0.07) : .white
    }

    private var bodyFill: Color {
        if isRoot { return rootFill }
        if isSection { return colour.opacity(scheme == .dark ? 0.20 : 0.13) }
        return surfaceFill
    }

    private var textColour: Color {
        if isRoot { return scheme == .dark ? Color(white: 0.1) : .white }
        if isSection { return colour }
        return .primary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Text(text)
                .font(.system(size: MindMapLayout.font(for: item.depth).pointSize,
                              weight: MindMapLayout.weight(for: item.depth)))
                .foregroundStyle(textColour)
                .lineLimit(MindMapLayout.maxLines(for: item.depth))
                .multilineTextAlignment(.leading)

            if isTappable { foldBadge }
        }
        .padding(.horizontal, MindMapLayout.horizontalPadding(for: item.depth))
        .padding(.vertical, MindMapLayout.verticalPadding(for: item.depth))
        .frame(width: item.frame.width, height: item.frame.height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(bodyFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(isSection ? colour.opacity(0.45) : .clear, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            // Deep leaves get a slim colour tick instead of an outline,
            // which keeps dense areas from turning into a grid of boxes.
            if item.depth >= 2 {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(colour.opacity(0.8))
                    .frame(width: 3, height: max(6, item.frame.height - 10))
                    .padding(.leading, 4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.07), radius: isRoot ? 4 : 1.5, y: 1)
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
    private var foldBadge: some View {
        HStack(spacing: 1.5) {
            Image(systemName: item.isExpanded ? "chevron.down" : "chevron.right")
            if !item.isExpanded {
                Text(verbatim: "\(item.childCount)")
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(isRoot || isSection ? textColour.opacity(0.6) : colour.opacity(0.85))
        .padding(.top, isRoot ? 5 : 3)
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
        let content = MindMapCanvas(layout: layout, labelForRoot: fallbackTitle)
            .padding(20)
            .background(scheme == .dark ? Color(white: 0.07) : Color(red: 0.980, green: 0.980, blue: 0.969))
            .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: content)
        // Pick the scale from the pixel budget rather than a fixed 2×: a
        // deep map is already thousands of points across, and at 3× it
        // would try to allocate a bitmap large enough to fail outright.
        let points = layout.size.width * layout.size.height
        if points > 8_000_000 {
            renderer.scale = 1
        } else if points > 2_000_000 {
            renderer.scale = 2
        } else {
            renderer.scale = 3
        }

        guard let image = renderer.uiImage, let data = image.pngData() else {
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
