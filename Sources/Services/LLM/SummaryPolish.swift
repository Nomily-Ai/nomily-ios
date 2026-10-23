import Foundation

// MARK: - Output discipline (shared by every template)

/// Cross-template rules that keep a summary about the *content*, not the form.
///
/// ## Why this exists
/// The built-in templates were adopted from Vobot and are **skeletons**: 基本信息 /
/// 会议日期 / 参会人员 / 风险与未决问题 / 下次会议 … On a four-minute call every
/// empty slot came back filled with `【To Be Confirmed】`, `未提及`, `无`, plus a
/// restatement of the recording's own metadata ("形式：语音转写；参与者：说话人1、2")
/// that tells the reader nothing.
///
/// Plaud's notes go the other way on purpose — in their own words they generate
/// "summaries for quick overviews, extraction notes for key insights like quotes
/// or numbers, and actionable outputs like to-do lists and follow-ups". Short,
/// and every line carries information.
///
/// The rules are appended to **every** template (and therefore inherited by the
/// chunked and merge passes, which reuse the same system prompt), so the 60+
/// templates do not have to be rewritten one by one.
enum SummaryPolicy {

    static var rules: String {
        NSLocalizedString("summarize.house_rules", value: """
        OUTPUT RULES — these override the template wherever they conflict:
        1. Write only what the transcript actually says. If a section has no real content, \
        delete the whole section. Never emit placeholders such as [To Be Confirmed], TBD, N/A, \
        "not mentioned", "unknown", "none" or 【待确认】.
        2. Do not restate metadata: how the audio was captured, speaker numbers ("Speaker 1"), \
        duration, source material or the transcription tool are not summary content.
        3. Say each thing once. If it is in the conclusions, it does not need repeating under topics.
        4. One sentence per item, at most three items per section. Keep the whole summary under a \
        quarter of the transcript's length.
        5. Action items are only things someone explicitly committed to, was assigned, or that \
        carries a deadline. Ideas, possibilities and "we could maybe" are not action items. Leave \
        owner/date blank when the transcript does not say — never invent them.
        6. Keep the template's headings, but drop every section that ends up with nothing real in it, \
        including catch-all sections like "additional notes" or "other".
        """, comment: "Appended to every summary template prompt: the output discipline")
    }

    /// One line instead of the full list — the tiny-source branch already forbids
    /// headings and tables, so only the "no placeholders" part still applies.
    static var tinyNote: String {
        NSLocalizedString("summarize.tiny_note", value: """
        Write only what was actually said; never output placeholders like TBD or 【待确认】.
        """, comment: "One-line output discipline for a one-sentence source")
    }
}

// MARK: - Deterministic clean-up

/// Removes what the model still got wrong, without asking it again.
///
/// A prompt lowers the frequency of junk; it cannot guarantee its absence — a
/// model that decides "参与者：未提及" is informative will say so no matter what
/// the instructions say. These rules are mechanical, so the result is stable:
///
/// * a **field** whose value is a placeholder (`会议日期：【To Be Confirmed】`) is dropped
/// * a **section** left with no content is dropped along with its heading
/// * an item repeated verbatim under two headings is kept once
///
/// Nothing here rewrites or summarises text — it only deletes lines that carry
/// no information, which is why it is safe to run on every generated summary.
enum SummaryPolish {

    /// Markers that mean "the model had nothing to say". Compared against a
    /// normalised value, so `【To Be Confirmed】`, `(TBD)` and `To be confirmed.`
    /// all match.
    private static let markers = [
        "tobeconfirmed", "tbd", "tbc", "na", "none", "null", "nil", "unknown",
        "notmentioned", "notavailable", "nottranscribed", "noinformation",
        "待确认", "待补充", "待定", "待核实", "未提及", "未说明", "未提供", "未知",
        "暂无", "无内容", "不详", "无", "空",
    ]

    static func clean(_ markdown: String) -> String {
        var output: [String] = []
        var sectionHeading: String?
        var sectionBody: [String] = []
        var seenItems = Set<String>()

        func flushSection() {
            defer { sectionHeading = nil; sectionBody = [] }
            // Body lines were filtered on the way in, so "empty" here really
            // means "this section has nothing to say".
            let body = sectionBody.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let heading = sectionHeading else {
                output.append(contentsOf: body)
                return
            }
            guard !body.isEmpty else { return }
            output.append(heading)
            output.append(contentsOf: body)
        }

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                flushSection()
                sectionHeading = trimmed
                continue
            }
            if !trimmed.isEmpty {
                // A field whose value is a placeholder is not information.
                if isPlaceholderLine(trimmed) { continue }
                // The same item under two headings reads as padding.
                if isListItem(trimmed) {
                    let key = normalise(trimmed)
                    if seenItems.contains(key) { continue }
                    seenItems.insert(key)
                }
            }
            sectionBody.append(trimmed)
        }
        flushSection()

        // Collapse the blank runs left behind by everything we removed.
        var compact: [String] = []
        for line in output {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if compact.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continue }
                compact.append("")
            } else {
                compact.append(line)
            }
        }
        while compact.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { compact.removeLast() }
        return compact.joined(separator: "\n")
    }

    private static func isListItem(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("|")
            || line.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) != nil
    }

    /// True when the line is a label with a placeholder value (`日期: TBD`) or a
    /// bare placeholder (`- 未提及`).
    private static func isPlaceholderLine(_ line: String) -> Bool {
        let body = stripMarkup(line)
        guard !body.isEmpty else { return true }
        // "label: value" / "| a | b |"
        if let separator = body.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            let value = String(body[body.index(after: separator)...])
            return isPlaceholderValue(value)
        }
        if body.contains("|") {
            let cells = body.split(separator: "|").map(String.init)
            return !cells.isEmpty && cells.allSatisfy { isPlaceholderValue($0) }
        }
        return isPlaceholderValue(body)
    }

    /// Whether a *value* (not a sentence) says nothing.
    ///
    /// Deliberately conservative: `无明确结论` is information, `无` is not, so the
    /// match is on the normalised value being one of the markers — not on the
    /// value merely containing one.
    private static func isPlaceholderValue(_ raw: String) -> Bool {
        let value = normalise(stripMarkup(raw))
        guard !value.isEmpty else { return true }
        return markers.contains(value)
    }

    /// Drop list markers, emphasis, table pipes, quotes and the CJK/ASCII
    /// brackets around placeholders.
    private static func stripMarkup(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: #"^[-*•]\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^\d{1,2}[.)]\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^\|"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\|$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "*", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: "【", with: "")
        text = text.replacingOccurrences(of: "】", with: "")
        text = text.replacingOccurrences(of: "[", with: "")
        text = text.replacingOccurrences(of: "]", with: "")
        text = text.replacingOccurrences(of: "（", with: "")
        text = text.replacingOccurrences(of: "）", with: "")
        text = text.replacingOccurrences(of: "(", with: "")
        text = text.replacingOccurrences(of: ")", with: "")
        text = text.replacingOccurrences(of: "\"", with: "")
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}
