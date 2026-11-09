import SwiftUI

// MARK: - 摘要阅读版式（★ 2026-11-03 九轮）
//
// 用户原话：「笔记里面的摘要显示，根据内容能否自动生成合适的模板。当前这个摘要显示的
// 不是很能够让人清楚地看到这个页面，还是不够美观简洁，再优化一下」。
//
// ## 为什么不是"再换一套 Markdown 主题"
// 上一版把每个块平铺在同一个 8pt 的 VStack 里：`## 标题` 只比正文粗一点、`- 要点` 前面
// 一颗灰点、段与段之间没有呼吸。读起来是"一坨文字"，看不出**结构**——而摘要的价值恰恰
// 在结构（结论 / 要点 / 待办 / 风险）。所以这里做的不是换皮，是**先把块重新分组**：
//
// | 分组 | 依据 | 渲染 |
// |---|---|---|
// | 导语 | 第一个 `##` 之前的段落 | 15pt、比正文重一档，当"摘要的摘要" |
// | 章节 | 每个 `##` 一卡 | 3pt 主题色竖条 + 15pt 半粗标题，章节之间 20pt |
// | 小节 | `###` 留在章节内 | 13pt 半粗、次要色 |
// | 要点 | `-` / `1.` | 去符号换小圆点/序号列，行距放松 |
//
// ## 自动模板（用户："根据内容形成不同的模板"）
// 版式不是猜的：从**已经生成好的摘要结构**里读信号（标题里有没有"参会/议程/决议"、
// 有没有"问题/回答"、待办条数占比），得到四种版式之一。这与生成阶段的
// `AutoTemplatePicker`（按转写关键词选提示词）是两件事、互不冲突：
// 那边决定"让模型写什么"，这边决定"已经写出来的东西怎么排"。
enum SummaryLayout: String {
    /// 会议纪要：会议总结 / 参会 / 议程 / 决议 —— 章节卡 + 竖条。
    case minutes
    /// 访谈问答：问题 / 回答 —— 问答块，问句加粗、答句缩进。
    case qa
    /// 行动清单：待办占了大部分内容 —— 待办置顶、要点紧随。
    case checklist
    /// 通用笔记：没有明显信号时的干净文档版式。
    case notes

    var label: String {
        switch self {
        case .minutes:   return L10n.ClipDetail.layoutMinutes
        case .qa:        return L10n.ClipDetail.layoutQA
        case .checklist: return L10n.ClipDetail.layoutChecklist
        case .notes:     return L10n.ClipDetail.layoutNotes
        }
    }

    var symbol: String {
        switch self {
        case .minutes:   return "person.2"
        case .qa:        return "bubble.left.and.bubble.right"
        case .checklist: return "checklist"
        case .notes:     return "doc.text"
        }
    }

    /// 从摘要的标题结构里认出这一篇是什么体裁。
    ///
    /// ⚠️ 只在**标题**里找信号，不扫正文：正文里出现"问题"两个字太常见
    ///    （"问题是成本太高"），按正文判定会把绝大多数会议记成问答。
    static func detect(_ blocks: [MarkdownBlock]) -> SummaryLayout {
        let headings = blocks.compactMap { block -> String? in
            if case .heading(let level) = block.kind, level >= 2 { return block.text }
            return nil
        }
        let joined = headings.joined(separator: "|").lowercased()

        func any(_ needles: [String]) -> Bool { needles.contains { joined.contains($0) } }

        if any(["问答", "提问", "问题与回答", "q&a", "qa", "interview question"]) { return .qa }

        // 待办占比：待办章节里的条目数 ÷ 全部条目数 ≥ 45% 就算"以行动为主"。
        let bulletCount = blocks.filter {
            if case .bullet = $0.kind { return true }
            if case .ordered = $0.kind { return true }
            return false
        }.count
        let todoCount = MarkdownBlocks.splitIntoSections(blocks)
            .filter { $0.isTodoSection }
            .reduce(0) { $0 + $1.blocks.filter { $0.kind == .bullet || isOrdered($0.kind) }.count }
        if bulletCount > 0, Double(todoCount) / Double(bulletCount) >= 0.45 { return .checklist }

        if any(["参会", "议程", "决议", "会议总结", "讨论详情", "出席", "attendee", "agenda",
                "decision", "minutes"]) { return .minutes }

        return .notes
    }

    private static func isOrdered(_ kind: MarkdownBlock.Kind) -> Bool {
        if case .ordered = kind { return true }
        return false
    }
}

// MARK: - 分节

extension MarkdownBlocks {
    /// 摘要按 `##` 切段后的样子。`title == nil` 的那一段是"导语"（第一个标题之前的正文）。
    struct Section: Identifiable {
        let id = UUID()
        let title: String?
        let headingLevel: Int
        let blocks: [MarkdownBlock]

        /// 这一节是不是"待办/行动项"——`TodoChecklistView` 与置顶逻辑都靠它。
        var isTodoSection: Bool {
            guard let title else { return false }
            let t = title.lowercased()
            return t.contains("待办") || t.contains("行动") || t.contains("跟进")
                || t.contains("to-do") || t.contains("todo") || t.contains("action item")
                || t.contains("next step") || t.contains("follow-up")
        }
    }

    static func splitIntoSections(_ blocks: [MarkdownBlock]) -> [Section] {
        var sections: [Section] = []
        var title: String?
        var level = 2
        var bucket: [MarkdownBlock] = []

        func flush() {
            guard title != nil || !bucket.isEmpty else { return }
            sections.append(Section(title: title, headingLevel: level, blocks: bucket))
            bucket = []
        }

        for block in blocks {
            if case .heading(let l) = block.kind {
                // H1 当作文档标题，不进正文（页面顶栏已经有标题了）。
                if l <= 1 { continue }
                if l == 2 {
                    flush()
                    title = block.text
                    level = l
                    continue
                }
            }
            bucket.append(block)
        }
        flush()
        return sections
    }
}

// MARK: - 渲染

/// 摘要正文的阅读版式。取代 `MarkdownBlocksView` 在笔记详情页里的位置。
struct SummaryDocView: View {

    let blocks: [MarkdownBlock]
    /// 「跳到原文」小按钮；传 nil 不显示（如导语、思维导图卡片里的预览）。
    var onTrace: ((String) -> Void)? = nil

    private var layout: SummaryLayout { .detect(blocks) }

    /// 章节顺序：行动清单版式把「待办」提到最前——那一页的全部意义就是"现在要做什么"。
    private var sections: [MarkdownBlocks.Section] {
        let all = MarkdownBlocks.splitIntoSections(blocks)
        guard layout == .checklist else { return all }
        let todos = all.filter(\.isTodoSection)
        let rest = all.filter { !$0.isTodoSection }
        return todos + rest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            layoutBadge

            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                sectionView(section, isFirst: index == 0)
            }
        }
    }

    /// 顶部一枚体裁标签。它回答"这篇是按什么模子排的"，
    /// 也是用户能看出"自动模板真的生效了"的唯一凭据。
    private var layoutBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: layout.symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(layout.label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Color.appAccent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.appAccent.opacity(0.12)))
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func sectionView(_ section: MarkdownBlocks.Section, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title = section.title {
                HStack(alignment: .center, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.appAccent.opacity(0.85))
                        .frame(width: 3, height: 15)
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(section.blocks) { block in
                blockView(block, isLead: section.title == nil && isFirst)
            }
        }
        .padding(.top, isFirst ? 0 : 20)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, isLead: Bool) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(inline(block.text))
                .font(.system(size: level <= 3 ? 13 : 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullet:
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 4, height: 4)
                    // 4pt 的点要和第一行文字的中线对齐，靠 padding 而不是 offset——offset 不参与布局。
                    .padding(.top, 8)
                // ★ 2026-11-04：来源时间不再当正文读——它被摘到行尾做成可点的胶囊
                //   （见 `trace`），正文里只留内容。
                Text(inline(StampRef.stripping(block.text)))
                    .font(.system(size: 14.5))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trace(block)
            }

        case .ordered(let number):
            HStack(alignment: .top, spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 16, alignment: .trailing)
                    .padding(.top, 2)
                Text(inline(StampRef.stripping(block.text)))
                    .font(.system(size: 14.5))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trace(block)
            }

        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Text(inline(StampRef.stripping(block.text)))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trace(block)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.07))
            )

        case .rule:
            // 分隔线在分节之后已经多余了——留白本身就够了，画一根线只是噪音。
            EmptyView()

        case .paragraph:
            HStack(alignment: .top, spacing: 9) {
                Text(inline(StampRef.stripping(block.text)))
                    // 导语（第一个标题之前的正文）读起来要像"摘要的摘要"，
                    // 比正文重一档、亮一档；正文段落回到普通字重。
                    .font(.system(size: isLead ? 15.5 : 14.5,
                                  weight: isLead ? .medium : .regular))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trace(block)
            }
        }
    }

    @ViewBuilder
    private func trace(_ block: MarkdownBlock) -> some View {
        if let onTrace {
            if let seconds = StampRef.parse(block.text) {
                // ★ 2026-11-04（摘要优化 C）：有来源时间就直接把时间做成按钮。
                //   比一枚"跳到原文"的箭头好两件事：**先告诉用户这条来自第几分钟**
                //   （可信度），点下去也是精确跳转，不再靠字符重合度猜。
                Button {
                    onTrace(block.text)
                } label: {
                    Text(StampRef.format(seconds))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.appAccent.opacity(0.9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.appAccent.opacity(0.1)))
                        .padding(.top, 3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.ClipDetail.traceSource))
            } else {
                Button {
                    onTrace(block.text)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.45))
                        .padding(.top, 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.ClipDetail.traceSource))
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
