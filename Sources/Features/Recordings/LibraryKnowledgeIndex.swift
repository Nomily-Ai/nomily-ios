import Foundation

/// 「知识库检索」的正文索引：把每条录音的**转录 / 译文 / 摘要**读成纯文本
/// 放在内存里，供列表搜索用。
///
/// ## 为什么必须是 `actor`
/// 一次检索要读几十上百个 `.txt` / `.md`，每个几十到几百 KB。放在主线程上
/// 就是"每敲一个字卡一下"。检索整条链路都在这个 actor 上跑，主线程只拿结果。
///
/// ## ★ 缓存怎么失效（这里的关键取舍）
/// 调用方把 `LibraryScanner.Signature`（目录里最新的 mtime + 条目数）
/// 当作**整块失效键**。目录里任何一个文件被写它都会变 —— 于是
/// "重新转录一次""重新生成摘要"这类**覆盖写**也会让缓存作废。
///
/// 代价是任何无关的新文件也会把缓存丢掉（重建一次，可接受），换来的是
/// "永远不会拿旧正文去匹配"。
///
/// ## 内存
/// 缓存的是**有正文的那些**条目的纯文本，量级 = 条数 × 单条转录大小
/// （10 分钟会议≈10 KB，一小时的≈60 KB）。几百条就是几 MB 到几十 MB，
/// 换掉了"每敲一个字重读一遍盘"。刻意不做 LRU / 字节上限：真正的上限来自
/// 用户转过的条目数，而为一个"整块失效"的缓存加淘汰逻辑只会让
/// "这次搜得到、下次搜不到"变成随机故障。真要收敛，该在**存转录**那一侧
/// 定大小上限，不是在这里。
///
/// 刻意**不**逐文件比对大小 / mtime：那要给每条 clip 多打 2~4 次 `stat`，
/// 省下的那点重建远不抵这些 syscall —— 而且漏判的后果是搜出来一段
/// 已经不存在的正文。
actor LibraryKnowledgeIndex {
    static let shared = LibraryKnowledgeIndex()

    /// 失效键与正文**同进同退**：键变了必须整块清掉，不能只换键。
    private var stamp: LibraryScanner.Signature?
    private var docs: [String: String] = [:]

    /// 在 `bases` 这些条目里找 `query`。
    ///
    /// - Returns: `base -> 命中片段`，**只含命中**的条目。
    ///
    /// 匹配对大小写与变音符都不敏感：用户转写里的 `Café` 应当能被
    /// `cafe` 找到，`Ç` 也能被 `c` 找到。
    func search(
        _ query: String,
        bases: [String],
        stamp: LibraryScanner.Signature?
    ) async -> [String: String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [:] }

        if stamp != self.stamp {
            docs.removeAll(keepingCapacity: true)
            self.stamp = stamp
        }

        var hits: [String: String] = [:]
        for base in bases {
            // 打字很快时上层会把上一次整条取消掉；读盘循环里必须真的看这个标志，
            // 否则取消只是"上层不等结果"，盘照读（库里 1900 条时差别很大）。
            if Task.isCancelled { return hits }
            guard let text = text(for: base), !text.isEmpty else { continue }
            guard let match = text.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) else { continue }
            hits[base] = Self.snippet(in: text, match: match)
        }
        return hits
    }

    /// 取一条 clip 的正文（首次读盘，之后走缓存）。真的没有正文时返回 nil。
    private func text(for base: String) -> String? {
        // 空串也是**有意义的缓存值**：表示"这条确认没有正文"，
        // 不加这个哨兵就会每次检索都为同一批空条目重新读盘。
        if let cached = docs[base] { return cached.isEmpty ? nil : cached }

        // 顺序即优先级：转录在最前，摘要垫后。
        let names = [
            "\(base).txt",
            "\(base).translated.txt",
            "\(base).summary.md",
            "\(base).summary.translated.md",
        ]
        var parts: [String] = []
        for name in names {
            let url = StorageLocations.decryptedDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let body = String(data: data, encoding: .utf8) else { continue }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            parts.append(trimmed)
        }
        let joined = parts.joined(separator: "\n")
        docs[base] = joined
        return joined.isEmpty ? nil : joined
    }

    /// 命中点前后各取一段，并**压平所有空白**。
    ///
    /// 为什么必须压平换行：转录是一行一句，原文里的 `\n` 直接塞进列表行，
    /// 一段片段会把行撑成十几行高，整个列表就毁了。
    private static func snippet(
        in text: String,
        match: Range<String.Index>,
        before: Int = 36,
        after: Int = 56
    ) -> String {
        let start = text.index(match.lowerBound, offsetBy: -before, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: after, limitedBy: text.endIndex)
            ?? text.endIndex
        var s = String(text[start..<end])
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\r", with: " ")
        s = s.replacingOccurrences(of: "\t", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespaces)
        // 两端截断处补省略号，读片段的人才知道这不是完整句子。
        if start != text.startIndex { s = "…" + s }
        if end != text.endIndex { s += "…" }
        return s
    }
}

/// 资料库搜索的作用域。
///
/// 默认 `.knowledge` —— 用户要的是"方便**知识库**检索"：只在他已经转录成文本
/// 或已经生成摘要的那些条目**正文**里找。`.all` 是逃生口：
/// 按文件名 / 自定义标题找一条还没转录的录音时用它。
enum LibrarySearchScope: String, CaseIterable, Identifiable {
    case knowledge
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .knowledge: return L10n.Library.searchScopeKnowledge
        case .all:       return L10n.Library.searchScopeAll
        }
    }
}
