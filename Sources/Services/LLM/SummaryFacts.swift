import Foundation

// MARK: - 两段式摘要：第一段只出事实
//
// ★ 2026-11-04（用户："摘要还是要优化，是否有摘要做得比较好的产品"）：
//
// 旧管道是**一步成文**：转写（长的话先切块）→ 直接按模板写纪要。问题在模板
// 是"填空骨架"（0. 基本信息 / 1. 核心结论 / … / 7. 总结），模型为了把表格填满
// 只能注水或者编——`SummaryPolicy` 那七条 house rules 全在事后打补丁就是这个原因。
//
// 改法照通义听悟/Plaud 的做法：**先事实、后成文**。
//
// ```
// 转写 ──①事实层──> 事实清单（话题 / 一行一条 / 带 mm:ss 与发言人）
//                       └──②成文层──> 按模板写成纪要
// ```
//
// 事实层不写"讨论了…"，只写"定了什么、谁说的、多少、什么时候"；成文层拿到的是
// 一份已经压干净的事实表，模板里那些空槽位要么有事实可填，要么被整节删掉——
// 没有第三种可能，注水的空间就没了。
//
// 为什么不是所有录音都走两段：一句话的语音备忘，事实层只会把它磨成半句，
// 而且多一次调用就多一次失败机会。见 `minimumSource`。
enum SummaryFacts {

    /// 低于这个字数直接一步成文。约等于 3–4 分钟的对话。
    ///
    /// 实测依据：`SalienceFilter` 之后的短转写（几百字）本来就没有压缩空间，
    /// 事实层产出常常比原文还长，纯属浪费一次往返。
    static let minimumSource = 600

    static func shouldBuild(source: String) -> Bool {
        source.count >= minimumSource
    }

    // MARK: - ① 事实层

    static var instruction: String {
        NSLocalizedString("summary.facts.prompt", value: """
        You are a meticulous note-taker extracting FACTS from a transcript. You are NOT writing a summary yet — \
        a later pass will turn your output into the final document.

        The transcript is one line per turn, each line starting with `[start - end seconds]` and, when known, a speaker name.

        Output a FACT SHEET in Markdown and nothing else:

        ### <topic — two to six words, in the transcript's language>
        - [mm:ss] <speaker if known>: <one plain fact, at most 40 words>

        Rules
        1. Keep only what carries information: decisions, commitments, numbers (money, percentages, dates, counts), \
        named people / companies / tools / products, risks, disagreements, next steps, and anything a speaker \
        stressed or repeated.
        2. One fact per line. When a turn is long, split it into several lines instead of compressing it — \
        every line must still make sense when read on its own.
        3. Never write "discussed X" or "talked about Y". Write what was actually decided, claimed, asked or promised.
        4. No introduction, no conclusion, no "summary" section, no recommendations, no evaluation words \
        ("important", "interesting", "key"). The reader decides what matters.
        5. Never invent a timestamp. Use the second where that fact starts, as `mm:ss` (or `h:mm:ss` past one hour).
        6. Aim for 3–6 topics and 3–8 facts per topic. A short meeting has fewer topics, not fewer facts per topic.
        7. Write in the transcript's language. Keep names, numbers and technical terms exactly as spoken.
        """, comment: "Stage 1 of the two-pass summary: extract a fact sheet from the transcript")
    }

    /// 事实层的 system prompt：指令 + 用户标记（有的话）。
    static func instruction(marks: String?) -> String {
        guard let marks, !marks.isEmpty else { return instruction }
        return instruction + "\n\n" + marks
    }

    // MARK: - ② 成文层

    /// 拼在模板提示词后面的规则。与 `SummaryPolicy.rules` 并存：那份管"不要写什么"，
    /// 这份管"怎样用事实清单"。
    static func finalizePolicy(hasMarks: Bool) -> String {
        var rules = NSLocalizedString("summary.finalize.prompt", value: """
        INPUT FORMAT — read this before anything else:
        The user's content is a FACT SHEET, not a raw transcript. Every line is one verified fact with its start \
        time. Write the document the instructions above ask for, using ONLY these facts.

        1. Do not re-summarise the fact sheet into vaguer language. Its job was compression; yours is structure. \
        If a fact fits the template, it goes in as-is (only lightly reworded for grammar).
        2. Every bullet that states a fact ends with that fact's source time in square brackets, e.g. `[12:24]`. \
        Never invent a time that is not in the fact sheet.
        3. Action items are a TABLE whose columns are, in this exact order: Item, Owner, Due, Source \
        — translate the four header cells into the document's language (Chinese: 事项 / 责任人 / 截止 / 来源). \
        Do not add, drop, reorder or merge columns, even when the template above draws its own to-do table; \
        this shape is what the app parses.
        — Owner: only a name that appears in the fact sheet; leave the cell empty when nobody was named.
        — Due: the date or deadline as spoken; leave empty when none was said.
        — Source: the `mm:ss` of that fact.
        Never write "TBD", "unknown" or "—" in those cells; an empty cell already says it.
        4. A fact with no matching section in the template is NOT deleted. Put it under the closest existing \
        heading, or open one more heading for it. Losing a decision is far worse than an extra heading.
        5. Keep the fact sheet's numbers, names and quotes. Do not round, do not generalise, do not translate proper nouns.
        """, comment: "Stage 2 of the two-pass summary: how to turn the fact sheet into the final document")
        if hasMarks {
            rules += "\n\n" + NSLocalizedString("summary.finalize.marks", value: """
            6. The fact sheet opens with a USER-MARKED MOMENTS block. Right after the document title, add one section \
            (heading translated into the transcript's language, meaning "Marked highlights") listing every marked \
            moment in one line each, keeping its `[mm:ss]`. These are the moments the user personally flagged while \
            listening — they must never be missing from the document.
            """, comment: "Extra stage-2 rule when the user pressed the mark button during recording")
        }
        return rules
    }

    // MARK: - 一步成文时的标记规则

    /// 短转写不走事实层，但标记照样要生效——否则"我按了标记，摘要里却没有"
    /// 在短录音上永远复现不了，也就永远修不好。
    static var marksOnlyRule: String {
        NSLocalizedString("summary.marks_only", value: """
        The input opens with a USER-MARKED MOMENTS block: moments the user personally flagged while listening. \
        Cover every one of them in the document and keep its `[mm:ss]`. Put them under the heading they belong to, \
        or in a short "Marked highlights" section right after the title when no section fits.
        """, comment: "Rule appended when the user marked moments but the source is too short for the two-pass pipeline")
    }

    // MARK: - 用户标记 → 原文

    /// 把「录音时按下的标记键」还原成具体的转写句子，供上面两处 prompt 使用。
    ///
    /// ★ 这是 Granola 那套"人的判断决定摘要重点"的最小可用版：标记是用户在当时
    /// 现场做的判断，比模型事后猜"什么重要"可靠得多。此前这些打点只用于界面高亮，
    /// 摘要生成完全没读——白扔掉的信号。
    ///
    /// - Returns: 没有标记、或转写没有时间轴（没法定位）时为 `nil`。
    static func marksBlock(clipName: String) -> String? {
        let base = (clipName as NSString).deletingPathExtension
        let marks = A1MarkStore.sidecar(forClipBase: base)
        guard !marks.isEmpty else { return nil }
        guard let doc = TranscriptDocument.load(for: clipName), !doc.segments.isEmpty else { return nil }

        let names = SpeakerNameStore.namesOnDisk(for: clipName)
        var lines: [String] = []
        var seen = Set<Int>()
        for mark in marks {
            // 标记落在某一段的区间里 → 那一段就是"他当时在听的那句"。
            // 落在两段之间（静音、换人）→ 取其后第一段，宁可多带一句也不要漏。
            guard let seg = doc.segments.first(where: { mark.offset >= $0.start && mark.offset < $0.end })
                    ?? doc.segments.first(where: { $0.start >= mark.offset }) else { continue }
            let key = Int(seg.start)
            guard seen.insert(key).inserted else { continue }
            let speaker = seg.speaker.flatMap { names[$0] ?? $0 } ?? ""
            let stamp = StampRef.format(seg.start)
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(speaker.isEmpty ? "- [\(stamp)] \(text)" : "- [\(stamp)] \(speaker): \(text)")
        }
        guard !lines.isEmpty else { return nil }
        let header = NSLocalizedString("summary.facts.marks_header", value: """
        USER-MARKED MOMENTS
        While listening, the user pressed the mark button on the recorder at these points. By definition these are \
        the moments that mattered to the person who was there — every one of them must appear in your fact sheet, \
        and in the final document:
        """, comment: "Header of the marked-moments block injected into the fact-extraction prompt")
        return header + "\n" + lines.joined(separator: "\n")
    }
}

// MARK: - 时间戳（摘要里的 [mm:ss]）

/// 摘要正文里的时间引用：`[12:24]` / `[1:02:03]` / `[12.4s]` / `[12.4s - 18.9s]`。
///
/// 存在的理由有两个：
/// * 生成侧要求模型给每条要点标来源时间，摘要因此**可核对**；
/// * 渲染侧点「跳到原文」时直接按秒定位，不再靠字符二元组去猜——猜的那套
///   （`ClipDetailView.bestMatchingSegment`）对改写过的句子经常落空。
enum StampRef {

    /// 从一段文字里取第一个时间引用（秒）。
    static func parse(_ text: String) -> TimeInterval? {
        var result: TimeInterval?
        scan(text) { seconds, _, _ in
            if result == nil { result = seconds }
            return result == nil
        }
        return result
    }

    /// `mm:ss`（超过一小时给 `h:mm:ss`）。
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// 把正文里的 `[mm:ss]` 去掉，得到"纯内容"——搜索转写、分享文件名都用它。
    static func stripping(_ text: String) -> String {
        var output = ""
        var last = text.startIndex
        var consumed = false
        scanWithRanges(text) { _, range in
            output += text[last..<range.lowerBound]
            last = range.upperBound
            consumed = true
        }
        guard consumed else { return text }
        output += text[last...]
        // 时间戳常常挂在行尾（`… 11-08 · [12:24]`），摘掉之后会留下一个孤零零的
        // 分隔符；顺便把因此产生的双空格合掉。
        let pieces = output
            .components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return pieces.joined(separator: " · ").replacingOccurrences(of: "  ", with: " ")
    }

    /// 宽松解析：没有方括号也认（`12:24` / `1:02:03`）。
    /// 表格单元格里模型通常不会加方括号，而待办表的「来源」列正是这种形状。
    static func parseLoose(_ text: String) -> TimeInterval? {
        if let strict = parse(text) { return strict }
        return parseInner(Substring(text.trimmingCharacters(in: .whitespaces)))
    }

    // 手写扫描而不是正则：格式只有四种（`[mm:ss]` / `[h:mm:ss]` / `[12.4s]` /
    // 喂给模型的原生 `[12.4s - 18.9s]`），扫描器比一个四段可选的 `Regex` 更好读，
    // 也不会因为某个捕获组可选而在 `AnyRegexOutput` 下标上出错。
    private static func parseInner(_ raw: Substring) -> TimeInterval? {
        var body = raw.trimmingCharacters(in: .whitespaces)
        // 原生格式是区间，只取起点。
        if let dash = body.firstIndex(of: "-") {
            body = String(body[body.startIndex..<dash]).trimmingCharacters(in: .whitespaces)
        }
        if body.hasSuffix("s") || body.hasSuffix("S") {
            return Double(body.dropLast())
        }
        let parts = body.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count else { return nil }
        if numbers.count == 3 {
            return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        }
        return numbers[0] * 60 + numbers[1]
    }

    /// 找到文本里每一个 `[...]`；回调返回 `false` 表示不再继续。
    ///
    /// ⚠️ 不能"看到不是 `[` 就收工"（第一版就是这么写的）：时间戳常常在句子中间
    /// （`先说别的 [03:07] 再往后`），那样只有"整行以时间戳开头"的情况能识别，
    /// 而这恰好是最少见的形状。非 `[` 字符逐个跳过，只有解析失败才继续往后找。
    private static func scan(_ text: String, _ body: (TimeInterval, Substring, Range<String.Index>) -> Bool) {
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "[", let close = text[index...].firstIndex(of: "]") else {
                index = text.index(after: index)
                continue
            }
            let inner = text[text.index(after: index)..<close]
            if let seconds = parseInner(inner) {
                let range = index..<text.index(after: close)
                if !body(seconds, inner, range) { return }
            }
            index = text.index(after: close)
        }
    }

    private static func scanWithRanges(_ text: String, _ body: (TimeInterval, Range<String.Index>) -> Void) {
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "[", let close = text[index...].firstIndex(of: "]") else {
                index = text.index(after: index)
                continue
            }
            let inner = text[text.index(after: index)..<close]
            if let seconds = parseInner(inner) {
                body(seconds, index..<text.index(after: close))
            }
            index = text.index(after: close)
        }
    }
}
