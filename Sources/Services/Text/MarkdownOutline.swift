import Foundation

/// A node in the outline derived from a Markdown summary.
///
/// A summary is not flat prose — its structure carries meaning. `###`
/// headings are the sections ("Key conclusions", "Key discussion topics", …) and the lists
/// beneath them are the points belonging to each section. This turns that
/// structure into a tree so the mind map can draw it and an outline can
/// indent it.
///
/// The parser is deliberately forgiving, because the input is LLM output:
/// heading levels can skip (`##` straight to `####`), list indentation can
/// be 2 or 4 spaces, and bullets can be `-`, `*`, `+` or `1.`. Anything
/// unrecognised becomes a plain child node rather than being dropped, and
/// if the document has no structure at all the parser returns `nil` so
/// callers can fall back to plain Markdown rendering.
struct OutlineNode: Identifiable, Hashable {
    let id: Int
    let title: String
    /// Resolved tree depth — root is 0, and every level below is exactly
    /// `parent.depth + 1`. Source heading levels are normalised away so a
    /// `##` → `####` jump doesn't leave a phantom empty level.
    let depth: Int
    let kind: Kind
    let children: [OutlineNode]

    enum Kind: Hashable {
        /// A `#`…`######` heading.
        case heading
        /// A `-` / `*` / `+` / `1.` list item.
        case bullet
        /// A `- [ ]` / `- [x]` task item.
        case task
        /// A `>` blockquote.
        case quote
        /// Free-standing paragraph text (continuation lines are merged).
        case text
    }

    /// `true` when the node carries no sub-points — leaf nodes are what
    /// make a mind map wide, so the layout engine wants to know.
    var isLeaf: Bool { children.isEmpty }

    /// Total number of nodes below this one, at any depth.
    var descendantCount: Int {
        children.reduce(children.count) { $0 + $1.descendantCount }
    }

    /// Depth-first walk that stops descending once `maxDepth` is reached.
    /// `maxDepth` is inclusive: `1` yields the root plus its direct
    /// children.
    func flattened(maxDepth: Int = .max) -> [OutlineNode] {
        var out: [OutlineNode] = [self]
        guard depth < maxDepth else { return out }
        for child in children { out.append(contentsOf: child.flattened(maxDepth: maxDepth)) }
        return out
    }

    /// The deepest node in the tree — drives the "expand level" slider's
    /// upper bound.
    var maxDepth: Int {
        children.reduce(depth) { max($0, $1.maxDepth) }
    }
}

enum MarkdownOutline {

    // MARK: - Public API

    /// Parses `markdown` into a tree, or returns `nil` when the document has
    /// no heading and no list — i.e. nothing worth drawing as a mind map.
    static func parse(_ markdown: String) -> OutlineNode? {
        let top = TreeBuilder.build(from: markdown)
        guard !top.isEmpty else { return nil }

        let root: Builder
        if top.count == 1 {
            root = top[0]
        } else {
            // Several top-level sections and no single wrapper heading —
            // synthesise one. An empty title signals the caller to supply a
            // localised label of its own.
            root = Builder(title: "", depth: 0, kind: .heading)
            root.children = top
        }

        // A single childless paragraph is flat prose — there is no structure
        // to draw, so report "no outline" and let the caller keep using the
        // ordinary Markdown renderer.
        if root.kind == .text, root.children.isEmpty { return nil }

        var nextID = 0
        return convert(root, depth: 0, nextID: &nextID)
    }

    /// Strips inline Markdown so a title can be shown as plain text in a
    /// mind-map node, a list row, or a share sheet.
    static func inline(_ raw: String) -> String { cleanInline(raw) }

    // MARK: - Builder

    private final class Builder {
        var title: String
        var depth: Int
        var kind: OutlineNode.Kind
        var children: [Builder] = []

        init(title: String, depth: Int, kind: OutlineNode.Kind) {
            self.title = title
            self.depth = depth
            self.kind = kind
        }
    }

    private static func convert(_ node: Builder, depth: Int, nextID: inout Int) -> OutlineNode {
        // Depth is re-derived from the tree shape rather than trusted from
        // the source, which fixes `##` → `####` skips and list items that
        // sat at an indentation the document never opened.
        let me = nextID
        nextID += 1
        var kids: [OutlineNode] = []
        kids.reserveCapacity(node.children.count)
        for child in node.children {
            kids.append(convert(child, depth: depth + 1, nextID: &nextID))
        }
        return OutlineNode(id: me, title: node.title, depth: depth, kind: node.kind, children: kids)
    }

    // MARK: - Line classification

    private enum TreeBuilder {

        static func build(from markdown: String) -> [Builder] {
            var paragraphs: [String] = []
            let root = Builder(title: "", depth: -1, kind: .heading)
            // Open heading chain, shallowest first. `headingLevels` is kept
            // alongside so a new heading can pop everything at or below its
            // own level.
            var headings: [Builder] = []
            var headingLevels: [Int] = []
            // Open list items inside the current heading, with their raw
            // source indentation.
            var bullets: [(indent: Int, node: Builder)] = []

            func parent() -> Builder { headings.last ?? root }

            func flushParagraph() {
                guard !paragraphs.isEmpty else { return }
                let merged = TreeBuilder.joinLines(paragraphs)
                paragraphs.removeAll()
                let text = MarkdownOutline.cleanInline(merged)
                guard !text.isEmpty else { return }
                let host = parent()
                host.children.append(Builder(title: text, depth: host.depth + 1, kind: .text))
            }

            for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty || Self.isThematicBreak(trimmed) {
                    flushParagraph()
                    continue
                }
                // Tables read as noise in a mind map, and their `|` rows are
                // never structural. Skip them whole.
                if trimmed.hasPrefix("|") {
                    flushParagraph()
                    continue
                }
                if let heading = Self.parseHeading(trimmed) {
                    flushParagraph()
                    bullets.removeAll()
                    while let last = headingLevels.last, last >= heading.level {
                        headingLevels.removeLast()
                        headings.removeLast()
                    }
                    let node = Builder(title: MarkdownOutline.cleanInline(heading.text), depth: heading.level, kind: .heading)
                    guard !node.title.isEmpty else { continue }
                    parent().children.append(node)
                    headings.append(node)
                    headingLevels.append(heading.level)
                    continue
                }
                if let bullet = Self.parseBullet(line) {
                    flushParagraph()
                    while let last = bullets.last, last.indent >= bullet.indent {
                        bullets.removeLast()
                    }
                    let host = bullets.last?.node ?? parent()
                    let node = Builder(
                        title: MarkdownOutline.cleanInline(bullet.text),
                        depth: host.depth + 1,
                        kind: bullet.task ? .task : .bullet
                    )
                    host.children.append(node)
                    bullets.append((bullet.indent, node))
                    continue
                }
                if trimmed.hasPrefix(">") {
                    flushParagraph()
                    let text = MarkdownOutline.cleanInline(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                    guard !text.isEmpty else { continue }
                    let host = parent()
                    host.children.append(Builder(title: text, depth: host.depth + 1, kind: .quote))
                    continue
                }
                paragraphs.append(trimmed)
            }

            flushParagraph()
            return root.children
        }

        /// Joins the wrapped lines of one paragraph. CJK has no inter-word
        /// space, so gluing two lines with a space would inject a stray gap
        /// mid-sentence; Latin lines need the space. Decide per boundary.
        private static func joinLines(_ lines: [String]) -> String {
            guard var out = lines.first else { return "" }
            for next in lines.dropFirst() {
                let glue = (out.last.map(MarkdownOutline.isCJK) ?? false)
                    || (next.first.map(MarkdownOutline.isCJK) ?? false) ? "" : " "
                out += glue + next
            }
            return out
        }

        /// `#`…`######` followed by optional text. A bare `###` with nothing
        /// after it is not a heading (the LLM sometimes emits a stray one).
        private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
            let hashes = line.prefix { $0 == "#" }
            let level = hashes.count
            guard (1...6).contains(level) else { return nil }
            var rest = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
            while rest.hasSuffix("#") { rest.removeLast() }
            rest = rest.trimmingCharacters(in: .whitespaces)
            guard !rest.isEmpty else { return nil }
            return (level, rest)
        }

        /// `-` / `*` / `+` / `1.` / `1)` markers, with the leading
        /// whitespace measured as indentation (tab = 4). The marker must be
        /// followed by a space, which is what keeps a line that merely
        /// *starts* with `*emphasis*` from being read as a bullet.
        private static func parseBullet(_ line: String) -> (indent: Int, text: String, task: Bool)? {
            var indent = 0
            for ch in line {
                if ch == " " { indent += 1 }
                else if ch == "\t" { indent += 4 }
                else { break }
            }
            guard indent < line.count else { return nil }
            var rest = line.dropFirst(indent)

            let markerLength: Int
            if let first = rest.first, first == "-" || first == "*" || first == "+" {
                markerLength = 1
            } else {
                let digits = rest.prefix { $0.isNumber }
                guard !digits.isEmpty, digits.count <= 3 else { return nil }
                let after = rest.dropFirst(digits.count)
                guard let delim = after.first, delim == "." || delim == ")" else { return nil }
                markerLength = digits.count + 1
            }
            rest = rest.dropFirst(markerLength)
            guard rest.first == " " else { return nil }

            var text = rest.trimmingCharacters(in: .whitespaces)
            var task = false
            for box in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(box) {
                task = true
                text = String(text.dropFirst(box.count))
                break
            }
            if !task, text == "[ ]" || text == "[x]" || text == "[X]" {
                task = true
                text = ""
            }
            guard !text.isEmpty else { return nil }
            return (indent, text, task)
        }

        private static func isThematicBreak(_ line: String) -> Bool {
            let stripped = line.filter { !$0.isWhitespace }
            guard stripped.count >= 3 else { return false }
            return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
        }
    }

    // MARK: - Inline cleanup

    /// Compiled once. `cleanInline` runs for every node, and `parse` is
    /// called from view bodies — recompiling these per call was the
    /// difference between a sub-millisecond parse and a visible hitch.
    private enum Pattern {
        static let imageOrLink = try? NSRegularExpression(pattern: #"!?\[([^\]\[]*)\]\([^)]*\)"#)
        static let referenceLink = try? NSRegularExpression(pattern: #"\[([^\]\[]*)\]\[[^\]\[]*\]"#)
        static let emphasisStar = try? NSRegularExpression(pattern: #"(?<![\w*])\*(?!\s)([^*]*?)(?<!\s)\*(?![\w*])"#)
        static let emphasisUnderscore = try? NSRegularExpression(pattern: #"(?<![\w_])_(?!\s)([^_]*?)(?<!\s)_(?![\w_])"#)
        static let lineBreak = try? NSRegularExpression(pattern: #"<br\s*/?>"#, options: [.caseInsensitive])
        static let htmlTag = try? NSRegularExpression(pattern: #"</?[a-zA-Z][^>]*>"#)
    }

    /// Removes inline Markdown from a fragment: emphasis markers, inline
    /// code, link syntax and HTML. Returns text safe to drop into a
    /// `Text` view or a mind-map node.
    private static func cleanInline(_ raw: String) -> String {
        var s = raw

        // Images and links collapse to their label.
        s = replace(Pattern.imageOrLink, in: s, with: "$1")
        // Reference-style links: keep the label, drop the tag.
        s = replace(Pattern.referenceLink, in: s, with: "$1")
        // Emphasis. `**`/`__` first, so the single-marker pass that follows
        // can't eat one half of a pair.
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "~~", with: "")
        s = replace(Pattern.emphasisStar, in: s, with: "$1")
        s = replace(Pattern.emphasisUnderscore, in: s, with: "$1")
        // Inline code.
        s = s.replacingOccurrences(of: "`", with: "")
        // <br> is a real line break; other tags just disappear.
        s = replace(Pattern.lineBreak, in: s, with: " ")
        s = replace(Pattern.htmlTag, in: s, with: "")
        // HTML entities the LLM emits by hand.
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&amp;", with: "&")
        s = s.replacingOccurrences(of: "&lt;", with: "<")
        s = s.replacingOccurrences(of: "&gt;", with: ">")

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Lead-in glyphs ("▲" for the one-line takeaway, "▶"/"•" for
        // highlights) are decoration in prose but noise in a tree node.
        while let first = s.first, "▲▶◀▼●○•·※★☆".contains(first) {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        // A trailing colon only ever introduced the text that followed it;
        // once the node stands alone it just dangles.
        while let last = s.last, last == ":" || last == "：" {
            s.removeLast()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    private static func replace(_ regex: NSRegularExpression?, in source: String, with template: String) -> String {
        guard let regex else { return source }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return regex.stringByReplacingMatches(in: source, options: [], range: range, withTemplate: template)
    }

    /// Cheap East-Asian test — used only to decide whether two wrapped
    /// lines should be glued with a space or not.
    private static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x1100...0x11FF,   // Hangul Jamo
             0x2E80...0x2FFF,   // CJK radicals / Kangxi
             0x3000...0x303F,   // CJK punctuation
             0x3040...0x30FF,   // Hiragana / Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xA960...0xA97F,   // Hangul Jamo Extended-A
             0xAC00...0xD7AF,   // Hangul syllables
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF00...0xFFEF:   // Full-width forms
            return true
        default:
            return false
        }
    }
}
