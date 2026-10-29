import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "vocab")

/// ★ 2026-10-28（饭耳逆向规格 §1.4「常用词」）：用户维护的专名提示表。
///
/// 用途（与饭耳的语义约定一致，原文：「只是提示，不会把别的词强行换成它」）：
/// 整理/摘要 prompt 里附上这份词表，让大模型认识产品名、人名、内部术语——
/// 转写里常见的专有名词被听错时，模型能按词表纠正表达。
///
/// 设计要点：
/// - **上限 2000**（对齐饭耳）；超出后 `add`/`importText` 拒绝并返回失败数；
/// - 存 `StorageLocations.vocabularyURL`（App Group JSON），跨 launch、跨设备页共享；
/// - `promptHint()` 只取前 N 条拼一行，避免长词表把 prompt 撑爆。
///
/// ★ 2026-10-29（用户："常用词汇里面从历史的文档里面提取，还有出现频率跟来源"）：
/// 条目从纯字符串升级为 `VocabEntry`（词 + 出现次数 + 来源录音 + 是否自动挖出），
/// 存储向后兼容旧 `[String]` JSON；新增 n-gram 频次挖掘器（`mineTranscripts`），
/// 从已转写的 .txt 里把反复出现的 2–4 字词提上来标"自动加入"，来源可查。
struct VocabEntry: Codable, Equatable, Identifiable {
    var word: String
    /// 在全部转写文本里出现的次数（挖掘时统计；手填词为 0）。
    var count: Int = 0
    /// 来源录音（base 名，最多记 3 条）。
    var sources: [String] = []
    /// 自动挖掘加入的（对比手动添加，编辑页分组显示）。
    var auto: Bool = false
    var addedAt: Date = Date()

    var id: String { word }
}

final class VocabularyStore: ObservableObject {

    static let limit = 2_000
    /// prompt 里最多带多少条——词表是提示不是词典，塞几百条反而稀释注意力。
    static let promptHintLimit = 80

    static let shared = VocabularyStore()

    @Published private(set) var entries: [VocabEntry] = []
    /// 最近 7 天自动挖入的条数（编辑页「近 7 天自动加了 N 个」行）。
    @Published private(set) var recentAutoCount = 0

    private let queue = DispatchQueue(label: "com.nomily.app.vocabulary", qos: .utility)
    private static let lastMinedKey = "vocabulary.last_mined_at"

    private init() {
        load()
    }

    /// 兼容旧 API 的词序视图。
    var words: [String] { entries.map(\.word) }
    var count: Int { entries.count }

    /// 添加一个词。返回 `false` = 已存在或超出上限。
    @discardableResult
    func add(_ raw: String, auto: Bool = false, count: Int = 0, sources: [String] = []) -> Bool {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 100 else { return false }
        guard !entries.contains(where: { $0.word == word }) else { return false }
        guard entries.count < Self.limit else { return false }
        // 新词放最前：编辑页最近加的在上头，promptHint 也优先带新词。
        entries.insert(
            VocabEntry(word: word, count: count, sources: Array(sources.prefix(3)), auto: auto),
            at: 0
        )
        persist()
        return true
    }

    func remove(_ word: String) {
        entries.removeAll { $0.word == word }
        persist()
    }

    /// 批量导入：按换行/逗号/顿号/分号切分。返回实际新增数。
    @discardableResult
    func importText(_ text: String) -> Int {
        let separators = CharacterSet(charactersIn: "\n\r,，、;；\t")
        var added = 0
        for piece in text.components(separatedBy: separators) {
            if add(piece) { added += 1 }
        }
        return added
    }

    /// 导出为每行一个词（粘贴/分享给别的设备再导入）。
    func exportText() -> String {
        words.joined(separator: "\n")
    }

    /// 给 prompt 的一行提示；空词表返回 `nil`（调用方就不用拼上下文段）。
    func promptHint() -> String? {
        let picked = words.prefix(Self.promptHintLimit)
        guard !picked.isEmpty else { return nil }
        return picked.joined(separator: "、")
    }

    // MARK: - ★ 2026-10-29 历史转写挖掘（出现频率 + 来源）

    /// 从全部已转写的 .txt 挖高频 2–4 字词并自动加入（标 auto）。
    /// IO/统计部分在调用线程执行——**重活请走 `mineOffMain`**，本方法适合
    /// 已在后台的调用方直接用。返回本次新挖入的条目数。
    @discardableResult
    func mineTranscripts(top: Int = 40) -> Int {
        let candidates = Self.mineTranscripts(existing: Set(words))
        return applyMined(candidates, top: top)
    }

    /// 挖掘的**后台编排**入口：重 IO 在 `utility` 队列，入表回主线程。
    /// 供 AppEnvironment 启动钩子与编辑页按钮共用。
    static func mineOffMain(top: Int = 40) {
        Task.detached(priority: .utility) {
            let existing = await Set(VocabularyStore.shared.words)
            let candidates = mineTranscripts(existing: existing)
            guard !candidates.isEmpty else { return }
            await MainActor.run {
                VocabularyStore.shared.applyMined(candidates, top: top)
            }
        }
    }

    /// 把挖出的候选写进词表（主线程调用）。
    @discardableResult
    func applyMined(_ candidates: [MinedCandidate], top: Int = 40) -> Int {
        var added = 0
        for candidate in candidates.prefix(top) where entries.count < Self.limit {
            if add(candidate.word, auto: true, count: candidate.count, sources: candidate.sources) {
                added += 1
            }
        }
        if added > 0 {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastMinedKey)
            recentAutoCount = recentAutoAddedCount()
        }
        return added
    }

    /// 是否值得自动跑一次（首次启动 + 每周一次）。
    func shouldAutoMine() -> Bool {
        let last = UserDefaults.standard.double(forKey: Self.lastMinedKey)
        guard last > 0 else { return true }
        return Date().timeIntervalSince1970 - last > 7 * 86_400
    }

    func refreshRecentAutoCount() {
        recentAutoCount = recentAutoAddedCount()
    }

    private func recentAutoAddedCount() -> Int {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        return entries.filter { $0.auto && $0.addedAt > cutoff }.count
    }

    struct MinedCandidate {
        let word: String
        let count: Int
        let sources: [String]
    }

    /// n-gram 频次挖掘。朴素但有效：转写里反复出现 ≥3 次的 2–4 字连续片段，
    /// 滤掉含标点/数字/空白和常见虚词的，按频次排序。来源取该词出现最多的前 3 篇。
    static func mineTranscripts(existing: Set<String>) -> [MinedCandidate] {
        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        let transcripts = names
            .filter { $0.hasSuffix(".txt") && !$0.hasSuffix(".translated.txt") }
            .sorted()

        // (ngram → 总次数)，(ngram → 文档次数)（来源排序用），(ngram → 文档名)
        var freq: [String: Int] = [:]
        var docFreq: [String: Int] = [:]
        var docsOf: [String: [String]] = [:]

        for name in transcripts {
            let url = dir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let base = (name as NSString).deletingPathExtension
            // 每篇文档内去重计数（文档频次），同一篇里出现 100 次只算 1 次来源。
            var seenInDoc = Set<String>()
            let chars = Array(text)
            for n in 2...4 {
                guard chars.count >= n else { continue }
                for i in 0...(chars.count - n) {
                    let gram = String(chars[i..<(i + n)])
                    // 过滤：含空白/标点/数字的片段不是专名。
                    let ok = gram.unicodeScalars.allSatisfy { scalar in
                        !scalar.properties.isWhitespace
                            && !(CharacterSet.punctuationCharacters.contains(scalar))
                            && !(CharacterSet.symbols.contains(scalar))
                    }
                    guard ok else { continue }
                    guard gram.rangeOfCharacter(from: .decimalDigits) == nil else { continue }
                    // 常见虚词/高频组合直接排除，省得词表全是"的时候"。
                    if Self.stopGrams.contains(gram) { continue }
                    guard !existing.contains(gram) else { continue }
                    freq[gram, default: 0] += 1
                    if seenInDoc.insert(gram).inserted {
                        docFreq[gram, default: 0] += 1
                        docsOf[gram, default: []].append(base)
                    }
                }
            }
        }

        // 子串折叠：如果一个 2-gram 的两个相邻 3-gram 都比它高频，它多半是长词的碎片。
        return freq
            .filter { $0.value >= 3 && docFreq[$0.key] ?? 0 >= 2 }
            .compactMap { word, count -> MinedCandidate? in
                // 长词包含短词时优先长词：该词若是某个更高频 4-gram 的子串则丢弃。
                for (other, otherCount) in freq where other.count > word.count && otherCount >= count && other.contains(word) {
                    return nil
                }
                return MinedCandidate(word: word, count: count, sources: Array(docsOf[word]?.prefix(3) ?? []))
            }
            .sorted { $0.count > $1.count }
    }

    /// 高频虚词/口语组合黑名单——挖掘器只看这个表，不做分词。
    private static let stopGrams: Set<String> = [
        "的时候", "然后", "所以", "但是", "如果", "就是", "这个", "那个", "我们",
        "你们", "他们", "自己", "什么", "怎么", "可以", "现在", "因为", "还是",
        "没有", "不是", "一个", "一下", "这样", "那样", "来说", "的话", "其实",
        "应该", "可能", "觉得", "知道", "已经", "出来", "开始", "时候", "今天",
        "明天", "昨天", "大家", "一点", "有些", "这里", "那里", "这些", "那些",
        "这个", "问题", "东西", "地方", "内容", "方面", "情况", "对于", "关于",
    ]

    // MARK: - persistence

    private func load() {
        let url = StorageLocations.vocabularyURL
        guard let data = try? Data(contentsOf: url) else {
            refreshRecentAutoCount()
            return
        }
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([VocabEntry].self, from: data) {
            entries = Array(list.prefix(Self.limit))
        } else if let list = try? decoder.decode([String].self, from: data) {
            // 旧格式（纯 [String]）无损迁移。
            entries = list.prefix(Self.limit).map { VocabEntry(word: $0) }
            persist()
        }
        refreshRecentAutoCount()
    }

    private func persist() {
        let snapshot = entries
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: StorageLocations.vocabularyURL, options: .atomic)
        }
    }
}
