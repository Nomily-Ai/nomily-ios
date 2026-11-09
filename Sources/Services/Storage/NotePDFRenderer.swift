import Foundation
import UIKit

/// 把一条录音的「标题 + 日期 + 总结 + 章节时间轴」排版成一份 PDF。
///
/// ★ 2026-11-03（用户："上传到 NC 的那个摘要这里面没有，如果是笔记的话这个
/// 排版也不行"）：服务器上的摘要文件从 `笔记.md`（NC 按纯文本显示，`##` 全是
/// 裸符号）换成 `摘要.pdf`——NC 对 PDF 有内置预览，点开就是排好版的文档。
///
/// ## 为什么不用 UIMarkupTextPrintFormatter（踩过的坑）
/// 第一版走 打印排版器 + HTML，实测产出的 PDF xref 里登记的对象没写出来
/// （6/8/10 号对象缺失，PDFKit 报 "failed to find start of cross-reference
/// table"）——WebKit 的排版是异步的，同步 drawPage 拿不到完整结果。现在改为
/// **CoreText 确定性排版**：markdown → NSAttributedString → CTFramesetter
/// 逐页分帧 → `UIGraphicsPDFRenderer` 落盘，全程同步、无外部依赖、页数可控。
///
/// ## Markdown 子集
/// 总结是自家模板产的：`#`–`####` 标题、`-`/`*` 无序列表、`1.` 有序、`>` 引用、
/// `**粗**`/`*斜*`/`` `码` ``。没覆盖的语法按普通段落兜底。
enum NotePDFRenderer {

    struct Note {
        var title: String
        var dateText: String
        /// 元信息行（日期 · 出品方），如 "2026-10-23 · Nomily 智能转写"。
        var meta: String
        /// `.summary.md` 原文，一字不改。
        var summaryMarkdown: String
        var chapters: [ClipChapter]
        var chaptersHeading: String
        /// 完整笔记的 Markdown 源（标题 + 元信息 + 正文 + 章节）——不进 PDF，
        /// 由调用方算 SHA256 做去重。
        var markdown: String
    }

    // MARK: - 版式常量

    /// A4 @ 72dpi。
    private static let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
    private static let inset: CGFloat = 48

    private static var printableWidth: CGFloat { pageRect.width - inset * 2 }

    // MARK: - 入口

    /// 渲染成 PDF（A4，自动分页）。失败返回 nil（调用方记日志跳过，不阻塞同步）。
    static func render(_ note: Note) -> Data? {
        let text = body(note)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: UIGraphicsPDFRendererFormat())
        return renderer.pdfData { context in
            // CTFramesetter 负责断行；逐页创建 frame，直到消费完全部字符。
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            let path = CGPath(rect: CGRect(x: 0, y: 0,
                                           width: printableWidth,
                                           height: pageRect.height - inset * 2),
                              transform: nil)
            var location = 0
            let total = text.length
            while location < total {
                context.beginPage()
                let cg = context.cgContext
                cg.saveGState()
                // CoreText 坐标系原点在左上：平移到版心左上角后把 y 翻转朝下。
                cg.translateBy(x: inset, y: pageRect.height - inset)
                cg.scaleBy(x: 1, y: -1)
                let frame = CTFramesetterCreateFrame(
                    framesetter,
                    CFRange(location: location, length: 0),
                    path,
                    nil
                )
                CTFrameDraw(frame, cg)
                cg.restoreGState()

                let visible = CTFrameGetVisibleStringRange(frame)
                // 一页一个字都放不下（防御）：跳出避免死循环。
                guard visible.length > 0 else { break }
                location = visible.location + visible.length
            }
        }
    }

    // MARK: - Markdown → NSAttributedString

    private static func font(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
        .systemFont(ofSize: size, weight: weight)
    }

    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }

    private static let ink = color(0x1D1D1F)
    private static let secondary = color(0x86868B)
    private static let body_ = color(0x2C2C2E)

    private static func paragraphStyle(lineSpacing: CGFloat, before: CGFloat = 0, after: CGFloat = 0,
                                       headIndent: CGFloat = 0, firstLineHead: CGFloat = 0,
                                       tabAt: CGFloat? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.headIndent = headIndent
        style.firstLineHeadIndent = firstLineHead
        if let tabAt {
            style.tabStops = [NSTextTab(textAlignment: .left, location: tabAt)]
        }
        return style
    }

    /// 整篇的排版：标题区 + 总结正文 + 章节时间轴。
    private static func body(_ note: Note) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            out.append(NSAttributedString(string: text, attributes: attributes))
        }

        // 标题 + 元信息行
        add(note.title + "\n", [
            .font: font(19, .semibold), .foregroundColor: ink,
            .paragraphStyle: paragraphStyle(lineSpacing: 2, after: 2),
        ])
        add(note.meta + "\n", [
            .font: font(9), .foregroundColor: secondary,
            .paragraphStyle: paragraphStyle(lineSpacing: 1, after: 12),
        ])

        // 总结正文
        out.append(richText(note.summaryMarkdown))

        // 章节时间轴
        if !note.chapters.isEmpty {
            add(note.chaptersHeading + "\n", [
                .font: font(13.5, .semibold), .foregroundColor: ink,
                .paragraphStyle: paragraphStyle(lineSpacing: 2, before: 14, after: 5),
            ])
            for (index, chapter) in note.chapters.sorted(by: { $0.start < $1.start }).enumerated() {
                let style = paragraphStyle(lineSpacing: 2.5, after: 2.5, headIndent: 20, firstLineHead: 0, tabAt: 20)
                add("\(index + 1).\t", [.font: font(10.5), .foregroundColor: secondary, .paragraphStyle: style])
                add(chapterStamp(chapter.start), [.font: font(10.5), .foregroundColor: secondary, .paragraphStyle: style])
                add("  " + chapter.title + "\n", [.font: font(10.5), .foregroundColor: body_, .paragraphStyle: style])
            }
        }
        return out
    }

    /// 总结正文：逐行解析 Markdown 子集，行内再拆 **粗** / *斜* / `码`。
    private static func richText(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()

        func bodyStyle(lineSpacing: CGFloat = 3.4, before: CGFloat = 0, after: CGFloat = 5,
                       headIndent: CGFloat = 0, firstLineHead: CGFloat = 0, tabAt: CGFloat? = nil)
            -> NSParagraphStyle {
            paragraphStyle(lineSpacing: lineSpacing, before: before, after: after,
                           headIndent: headIndent, firstLineHead: firstLineHead, tabAt: tabAt)
        }

        var paragraph: [NSAttributedString] = []
        var listItems: [NSAttributedString] = []
        var listOrdered = false
        var quote: [NSAttributedString] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = NSMutableAttributedString()
            for (index, piece) in paragraph.enumerated() {
                if index > 0 { joined.append(NSAttributedString(string: "\n")) }
                joined.append(piece)
            }
            out.append(joined)
            paragraph = []
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            let items = NSMutableAttributedString()
            for item in listItems { items.append(item) }
            out.append(items)
            listItems = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            let joined = NSMutableAttributedString()
            for (index, piece) in quote.enumerated() {
                if index > 0 { joined.append(NSAttributedString(string: "\n")) }
                joined.append(piece)
            }
            out.append(joined)
            quote = []
        }
        func flushAll() { flushParagraph(); flushList(); flushQuote() }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty { flushAll(); continue }
            if line == "---" || line == "***" { flushAll(); continue }  // 分隔线：留白即可

            if let heading = Self.heading(levelAndText: line) {
                flushAll()
                let (size, weight, tint, before, after): (CGFloat, UIFont.Weight, UIColor, CGFloat, CGFloat)
                switch heading.level {
                case 1:  (size, weight, tint, before, after) = (16, .semibold, ink, 12, 5)
                case 2:  (size, weight, tint, before, after) = (13.5, .semibold, ink, 13, 5)
                case 3:  (size, weight, tint, before, after) = (11.5, .semibold, ink, 10, 4)
                default: (size, weight, tint, before, after) = (10.5, .semibold, color(0x3A3A3C), 9, 3)
                }
                out.append(NSAttributedString(
                    string: heading.text + "\n",
                    attributes: [
                        .font: font(size, weight), .foregroundColor: tint,
                        .paragraphStyle: bodyStyle(lineSpacing: 2, before: before, after: after),
                    ]
                ))
                continue
            }
            if line.hasPrefix(">") {
                flushParagraph(); flushList()
                let text = String(line.dropFirst(line.hasPrefix("> ") ? 2 : 1))
                quote.append(NSAttributedString(string: text, attributes: [
                    .font: font(10), .foregroundColor: color(0x6E6E73),
                    .paragraphStyle: bodyStyle(lineSpacing: 3, after: 6, headIndent: 12),
                ]))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph(); flushQuote()
                if listOrdered { flushList() }
                listOrdered = false
                listItems.append(bulletItem(String(line.dropFirst(2)), marker: "•"))
                continue
            }
            if let ordered = Self.orderedItem(line) {
                flushParagraph(); flushQuote()
                if !listOrdered { flushList() }
                listOrdered = true
                listItems.append(bulletItem(ordered.content, marker: ordered.marker))
                continue
            }
            flushList(); flushQuote()
            paragraph.append(inline(line, font: font(10.5), color: body_))
        }
        flushAll()
        return out
    }

    /// 一个列表项：标记 + tab + 行内内容，悬挂缩进（换行后对齐到文字起点）。
    private static func bulletItem(_ content: String, marker: String?) -> NSAttributedString {
        let style = paragraphStyle(lineSpacing: 3, after: 2.5, headIndent: 13, firstLineHead: 0, tabAt: 13)
        let item = NSMutableAttributedString()
        item.append(NSAttributedString(
            string: (marker ?? "·") + "\t",
            attributes: [.font: font(10.5), .foregroundColor: secondary, .paragraphStyle: style]
        ))
        item.append(inline(content, font: font(10.5), color: body_, paragraphStyle: style))
        item.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
        return item
    }

    // MARK: - 行内样式

    private static func heading(levelAndText line: String) -> (level: Int, text: String)? {
        var level = 0
        while level < line.count, line[line.index(line.startIndex, offsetBy: level)] == "#" { level += 1 }
        guard (1...4).contains(level),
              level < line.count,
              line[line.index(line.startIndex, offsetBy: level)] == " " else { return nil }
        return (level, String(line.dropFirst(level + 1)))
    }

    /// `12. 内容` → (marker: "12.", content: "内容")——编号保留，列表样式统一。
    private static func orderedItem(_ line: String) -> (marker: String, content: String)? {
        guard let dot = line.firstIndex(of: "."),
              line.distance(from: line.startIndex, to: dot) <= 3,
              let num = Int(line[line.startIndex..<dot]),
              num > 0,
              line.index(after: dot) < line.endIndex else { return nil }
        let rest = line[line.index(after: dot)...]
        guard rest.hasPrefix(" ") else { return nil }
        return (String(line[line.startIndex..<dot]) + ".", String(rest.dropFirst()))
    }

    /// 行内拆分：`**粗**` / `*斜*` / `` `码` ``。
    private static func inline(_ raw: String, font base: UIFont, color tint: UIColor,
                               paragraphStyle style: NSParagraphStyle? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let pattern = "\\*\\*([^*]+)\\*\\*|\\*([^*]+)\\*|`([^`]+)`"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            result.append(NSAttributedString(string: raw, attributes: [.font: base, .foregroundColor: tint]))
            return result
        }
        let ns = raw as NSString
        var cursor = 0
        for match in regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result.append(NSAttributedString(string: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), attributes: [.font: base, .foregroundColor: tint]))
            }
            // 组 1 = 粗，组 2 = 斜，组 3 = 码
            let bold = match.range(at: 1)
            let italic = match.range(at: 2)
            let code = match.range(at: 3)
            if bold.location != NSNotFound {
                result.append(NSAttributedString(string: ns.substring(with: bold), attributes: [
                    .font: font(base.pointSize, .semibold), .foregroundColor: tint,
                ]))
            } else if italic.location != NSNotFound {
                result.append(NSAttributedString(string: ns.substring(with: italic), attributes: [
                    .font: UIFont.italicSystemFont(ofSize: base.pointSize), .foregroundColor: tint,
                ]))
            } else if code.location != NSNotFound {
                result.append(NSAttributedString(string: ns.substring(with: code), attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular),
                    .foregroundColor: tint,
                ]))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result.append(NSAttributedString(string: ns.substring(from: cursor), attributes: [.font: base, .foregroundColor: tint]))
        }
        if let style {
            result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        }
        return result
    }

    // MARK: - 时间戳

    /// `75.5` → `01:15`，`3725` → `1:02:05`。
    static func chapterStamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
