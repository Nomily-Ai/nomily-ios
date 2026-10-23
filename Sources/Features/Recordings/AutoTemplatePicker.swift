import Foundation

/// Picks the template that best matches a transcript, so "自动生成" needs no
/// manual choice — Plaud's first option in their generate sheet (screenshot
/// 4033: "自动生成最匹配的转写与总结，无需手动设置").
///
/// ## Why local heuristics, not a model call
/// Choosing a template with an LLM costs a full round-trip **before** the
/// summary even starts, can fail on a flaky channel, and is unexplainable when
/// it picks something odd. Cue words are what a human reader uses anyway — a
/// transcript that keeps saying 面试/候选人 is an interview — and this returns
/// in microseconds, offline, deterministically.
///
/// When no category gathers enough signal the default auto template wins (the
/// rewritten `Quick Summary`, which already produces the Vobot-shaped full
/// report), so the fallback is never a bad fit — just a general one.
enum AutoTemplatePicker {

    private struct Rule {
        let category: String
        /// Lower-cased needles. Chinese needs no case folding but goes through
        /// the same path so one list covers both languages.
        let keywords: [String]
        /// How much one hit counts. Meetings and interviews are strong signals;
        /// "to-do" shows up inside any meeting, so it weighs less.
        let weight: Int
    }

    private static let rules: [Rule] = [
        Rule(category: "Meeting Notes",
             keywords: ["会议", "开会", "议程", "参会", "例会", "评审会", "周会", "讨论会",
                        "meeting", "standup", "sync up", "agenda"],
             weight: 3),
        Rule(category: "Interview",
             keywords: ["面试", "招聘", "候选人", "简历", "入职", "interview", "candidate", "resume"],
             weight: 4),
        Rule(category: "Sales",
             keywords: ["客户", "报价", "合同", "签单", "销售", "商机", "续费", "成交",
                        "pipeline", "quotation", "deal", "renewal"],
             weight: 3),
        Rule(category: "Medical",
             keywords: ["患者", "症状", "诊断", "处方", "就诊", "病历", "用药",
                        "patient", "symptom", "diagnosis", "prescription"],
             weight: 4),
        Rule(category: "Academic",
             keywords: ["课堂", "讲座", "课程", "论文", "实验", "同学", "老师",
                        "lecture", "seminar", "paper", "coursework"],
             weight: 3),
        Rule(category: "Finance",
             keywords: ["财报", "营收", "毛利", "估值", "股票", "投资", "融资",
                        "revenue", "earnings", "valuation", "investor"],
             weight: 3),
        Rule(category: "Professional",
             keywords: ["绩效", "一对一", "项目进度", "里程碑", "复盘", "汇报",
                        "one-on-one", "1:1", "milestone", "retrospective", "status update"],
             weight: 3),
        Rule(category: "Action Items",
             keywords: ["待办", "行动项", "截止", "任务清单", "负责人",
                        "to-do", "todo", "action item", "deadline", "owner"],
             weight: 1),
        Rule(category: "Creative",
             keywords: ["头脑风暴", "创意", "灵感", "点子", "brainstorm", "idea"],
             weight: 2),
    ]

    /// One template per recording. Never nil when `templates` is non-empty —
    /// the caller can enqueue immediately.
    static func pick(transcript: String, from templates: [SummarizeTemplate]) -> SummarizeTemplate? {
        guard !templates.isEmpty else { return nil }
        let text = transcript.lowercased()

        var scores: [String: Int] = [:]
        for rule in rules {
            let hits = rule.keywords.reduce(0) { $0 + occurrences(of: $1, in: text) }
            if hits > 0 { scores[rule.category, default: 0] += hits * rule.weight }
        }

        // A single stray "会议" in an hour of therapy notes is not a meeting.
        // Three points is one strong cue or several weak ones.
        if let best = scores.max(by: { $0.value < $1.value }), best.value >= 3,
           let match = templates.first(where: { $0.category == best.key && $0.isBuiltIn }) {
            return match
        }
        return autoDefault(in: templates)
    }

    /// The template the app itself uses when nothing is chosen — the full
    /// auto-report (`PlaudTemplateLibrary`'s "Quick Summary", Vobot-shaped).
    static func autoDefault(in templates: [SummarizeTemplate]) -> SummarizeTemplate? {
        templates.first { $0.category == "General Summary" && $0.name == "Quick Summary" }
            ?? templates.first
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            count += 1
            searchRange = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
