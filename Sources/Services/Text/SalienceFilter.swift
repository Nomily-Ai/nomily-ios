import Foundation

// MARK: - 重要片段筛选（★ 2026-11-03 十轮）
//
// 用户原话：「对于这种全天候录音，那种无关紧要的话…他们对于这种摘要是如何做的，
// 所以就是按照他们的策略进行优化，而不是把所有的话进行转写摘要，只在选出重要的部分」。
//
// ## 业界是怎么做的（这就是被抄的那套策略）
// Plaud / Limitless / Rewind 这类"戴一整天"的产品，摘要都不是"把转写整篇丢给模型"：
// ① **先切句**（ASR 已经是逐句的），② **按信息量打分**（谁承诺了什么、定了什么、
// 出现数字/时间/人名/风险），③ **只把高分句喂给摘要模型**，④ 低分句留在转写里可查、
// 但不进摘要。它们的公开说法叫 "highlight / key moments extraction"。
//
// 直接全量喂模型在长时间录音上有三个具体毛病，这也正是我们要解决的：
// · 模型会被"嗯、对、然后呢"稀释，摘要开始复述寒暄；
// · 一小时录音要分块（`LLMCompletionService` 的 chunk 合并），块与块之间的重复更多；
// · 待办抽取被淹没在闲聊里，宁可漏也不滥的那条纪律守不住。
//
// ## 为什么是本地启发式，不是先跑一次模型挑句子
// 挑句子本身就是一次全量输入——为了省 token 先烧一遍 token 不划算；而且它必须
// **可解释**：用户看到"少了几句话"时，得能指着规则说出为什么（见下面每一档的注释）。
// 真正需要语义判断的（"这句话是不是重点"）留给摘要模型，它拿到的已经是被压过的材料。
//
// ⚠️ 只在**长转写**上启用（`minCharacters`）。十分钟的语音备忘全量喂进去正好，
//    剪一刀只会丢信息——这也是 Plaud 默认只对长录音做 highlight 的原因。
enum SalienceFilter {

    /// 低于这个字数不筛。6000 字 ≈ 40~50 分钟中文对话。
    static let minCharacters = 6000

    struct Result {
        let text: String
        /// 保留下来的行数 / 原始行数 / 压缩掉的字数占比。
        let keptLines: Int
        let totalLines: Int
        let droppedRatio: Double

        var didReduce: Bool { keptLines < totalLines }
    }

    /// 纯语气词/应答行：整行只有这些内容时权重极低。
    private static let fillerWords: Set<String> = [
        "嗯", "啊", "哦", "噢", "呃", "唉", "好", "好的", "行", "可以", "对", "对的",
        "是的", "没错", "然后", "那个", "这个", "就是", "所以", "OK", "ok", "okay",
        "yeah", "yes", "right", "hmm", "mm", "uh", "um", "sure", "alright",
    ]

    /// 决策/结论：一条摘要最该保住的就是这些。
    private static let decisionWords = [
        "决定", "定了", "确定", "结论", "达成", "同意", "通过", "批准", "拍板", "敲定",
        "最终", "统一意见", "decided", "agreed", "conclusion", "approved", "settled",
    ]

    /// 行动/承诺：直接进待办。
    private static let actionWords = [
        "负责", "跟进", "安排", "对接", "提交", "交付", "截止", "deadline", "by ",
        "明天", "后天", "下周", "下月", "周五", "周一", "月底", "月底前", "之前完成",
        "我来", "你去", "记得", "别忘", "action item", "todo", "owner", "follow up",
    ]

    /// 风险/分歧/未决：会议纪要里最容易被漏掉、又最值钱的一段。
    private static let riskWords = [
        "风险", "问题", "担心", "阻塞", "卡住", "分歧", "争议", "不确定", "待确认",
        "risk", "issue", "blocker", "concern", "unclear", "open question",
    ]

    /// 寒暄/客套：整行是这些内容时直接判为噪音。
    private static let smallTalkWords = [
        "你好", "您好", "早上好", "下午好", "晚上好", "辛苦了", "谢谢", "感谢", "不客气",
        "再见", "拜拜", "hello", "hi ", "good morning", "thanks", "thank you", "bye",
    ]

    /// 把长转写压成"只含重要片段"的文本。
    ///
    /// - Parameter targetRatio: 目标保留比例（字数口径）。0.55 = 最多留一半多一点。
    /// - Returns: 过滤后的文本 + 统计。**任何异常情况都退回原文**（宁可多喂，不可少喂）。
    static func reduce(_ text: String, targetRatio: Double = 0.55) -> Result {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let total = lines.count
        guard text.count >= minCharacters, total >= 20 else {
            return Result(text: text, keptLines: total, totalLines: total, droppedRatio: 0)
        }

        let scored = lines.map { (line: $0, score: score($0)) }
        let budget = Int(Double(text.count) * max(0.2, min(1, targetRatio)))

        // 全部保留也超预算时：按分数从高到低取，再按原始顺序还原。
        // 保留原文顺序很重要——摘要是按时间线讲的，打乱顺序模型会编出因果。
        var keep = Set<Int>()
        var used = 0
        for (index, item) in scored.enumerated().sorted(by: { $0.element.score > $1.element.score }) {
            // 分数为负的一律不取（寒暄/语气词），除非预算还剩一大截。
            if item.score < 0 && Double(used) > Double(budget) * 0.8 { continue }
            keep.insert(index)
            used += item.line.count
            if used >= budget { break }
        }

        // 前两行永远保留：开场往往决定了这场对话在讲什么（"今天主要过三件事"）。
        keep.insert(0)
        if total > 1 { keep.insert(1) }

        let kept = keep.sorted().map { lines[$0] }
        guard kept.count < total else {
            return Result(text: text, keptLines: total, totalLines: total, droppedRatio: 0)
        }
        let droppedChars = Double(text.count - kept.joined(separator: "\n").count)
        return Result(
            text: kept.joined(separator: "\n"),
            keptLines: kept.count,
            totalLines: total,
            droppedRatio: max(0, droppedChars / Double(max(1, text.count)))
        )
    }

    // MARK: - 打分

    /// 一句一行地打分。**正分 = 值得进摘要**，负分 = 噪音。
    ///
    /// 权重不是拍脑袋：一条"决定/承诺"必须压过三五句寒暄，否则长会里
    /// 闲聊的绝对数量会把真正的结论挤掉（这正是全量喂模型时的老毛病）。
    private static func score(_ line: String) -> Int {
        let compact = line.replacingOccurrences(of: " ", with: "").lowercased()
        guard !compact.isEmpty else { return -5 }

        // 整行就是"嗯/对/OK"这种：直接判噪音，不管多长。
        if compact.count <= 6, fillerWords.contains(compact) { return -6 }
        if compact.count <= 10, smallTalkWords.contains(where: { compact.contains($0.trimmingCharacters(in: .whitespaces)) }),
           compact.count <= 12 {
            return -3
        }

        var score = 0
        if decisionWords.contains(where: { compact.contains($0) }) { score += 4 }
        if actionWords.contains(where: { compact.contains($0) }) { score += 3 }
        if riskWords.contains(where: { compact.contains($0) }) { score += 2 }

        // 数字/时间/金额：具体信息的硬指标（"15%"、"周三"、"30 万"）。
        if line.range(of: #"\d"#, options: .regularExpression) != nil { score += 2 }

        // 有内容的长句至少不算噪音；太短又没关键词的多半是应答。
        if compact.count >= 16 { score += 1 }
        if compact.count <= 8, score == 0 { score -= 2 }

        // 语气词开头（"嗯，那我们就……"）扣一点，但不否掉后半句的信息。
        if let first = compact.first, "嗯啊哦呃唉".contains(first) { score -= 1 }

        return score
    }
}
