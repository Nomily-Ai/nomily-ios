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
    ///
    /// ★ 2026-10-30（用户："常用词需要是那种网络热词……『不要』『不能』『这个』
    /// 我这种词汇也算作归纳为常用词……结合一下相关行业的词汇进来，可以分析
    /// 一下其他相关的项目常用词的逻辑"）：两路改动——
    /// ① **虚词黑名单大幅扩容**（见 `stopGrams`：代词/助词/能愿动词/口语填充
    ///    全部拉黑），挖出来的不再有「不要」「不能」「这个」这类废词；
    /// ② **词库直查**（`hotwordLexicon` + `industryLexicon`）：参照讯飞听见/
    ///    讯飞 ASR 的个性化热词分层思路（个人热词 / 行业词 / 热词库导入，
    ///    命中即提升权重），把网络热词与科技/互联网/职场行业词建成内置词库，
    ///    在转写里**出现过哪怕一次**就收进词表并标注来源——词库里放着的就是
    ///    「该认识的词」，出现即值得提示，不需要凑满 n-gram 的频次门槛。
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
        // 词库直查：词 → (总次数, 文档名列表)
        var lexCount: [String: Int] = [:]
        var lexDocs: [String: [String]] = [:]

        for name in transcripts {
            let url = dir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let base = (name as NSString).deletingPathExtension

            // ── 词库直查（一次 contains 扫描，便宜）─────────────────────────
            for word in Self.hotwordLexicon.union(Self.industryLexicon) where !existing.contains(word) {
                var searchRange = text.startIndex..<text.endIndex
                var hits = 0
                while let found = text.range(of: word, range: searchRange) {
                    hits += 1
                    searchRange = found.upperBound..<text.endIndex
                }
                if hits > 0 {
                    lexCount[word, default: 0] += hits
                    lexDocs[word, default: []].append(base)
                }
            }

            // ── n-gram 统计 ────────────────────────────────────────────────
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
                    // ★ 2026-10-30: 英文/混排片段不做 n-gram——裸字母连英语虚词
                    // （the/and/ing）都会凑满频次进词表。英文术语交给上面的
                    // 词库直查（industryLexicon 含 API/SaaS 等），出现的照样收。
                    guard !gram.contains(where: \.isASCII) else { continue }
                    // 常见虚词/高频组合直接排除，省得词表全是"的时候"。
                    if Self.stopGrams.contains(gram) { continue }
                    // ★ 2026-10-30: 子串/单字级过滤——「能够个」「不能算」
                    // 这类包含虚词大片段的候选整段扔掉（见 stopSubstrings 注释）。
                    if Self.stopSubstrings.contains(where: gram.contains) { continue }
                    if gram.contains(where: { Self.stopCharacters.contains($0) }) { continue }
                    guard !existing.contains(gram) else { continue }
                    freq[gram, default: 0] += 1
                    if seenInDoc.insert(gram).inserted {
                        docFreq[gram, default: 0] += 1
                        docsOf[gram, default: []].append(base)
                    }
                }
            }
        }

        // 词库候选：命中即收（≥1 次），按命中次数排序。
        var results: [MinedCandidate] = lexCount
            .map { word, count in
                MinedCandidate(word: word, count: count, sources: Array(lexDocs[word]?.prefix(3) ?? []))
            }
            .sorted { $0.count > $1.count }

        // n-gram 候选：子串折叠后按频次取（沿用原门槛 ≥3 次 + ≥2 篇）。
        let mined: [MinedCandidate] = freq
            .filter { $0.value >= 3 && docFreq[$0.key] ?? 0 >= 2 }
            .compactMap { word, count -> MinedCandidate? in
                // 长词包含短词时优先长词：该词若是某个更高频 4-gram 的子串则丢弃。
                for (other, otherCount) in freq where other.count > word.count && otherCount >= count && other.contains(word) {
                    return nil
                }
                return MinedCandidate(word: word, count: count, sources: Array(docsOf[word]?.prefix(3) ?? []))
            }
            .sorted { $0.count > $1.count }
        results.append(contentsOf: mined)
        return results
    }

    /// 高频虚词/口语组合黑名单——挖掘器只看这个表，不做分词。
    ///
    /// ★ 2026-10-30 大幅扩容（用户点名「不要」「不能」这类也混了进来）：
    /// 代词、能愿动词、否定/程度副词、量词组合、口语填充全拉黑。宁可错杀
    /// （真专名撞上这些组合的概率极低），不可放过一个废词——词表混进
    /// 「这个」「不能」会直接稀释 prompt 里的提示价值。
    private static let stopGrams: Set<String> = [
        // 代词 / 指代
        "这个", "那个", "我们", "你们", "他们", "她们", "咱们", "自己", "大家",
        "这里", "那里", "这些", "那些", "这样", "那样", "这样子", "什么样",
        "什么", "怎么", "怎样", "怎么样", "为什么", "谁", "哪里", "哪些",
        "这种", "那种", "哪种", "这么", "那么", "多么", "如何", "为何",
        // 系词 / 助词 / 结构
        "的话", "来说", "来讲", "而言", "对于", "关于", "由于", "通过", "按照",
        "根据", "接着", "然后", "所以", "但是", "可是", "不过", "如果", "虽然",
        "因为", "而且", "并且", "或者", "还是", "就是", "只是", "也是", "也是的",
        "一下", "一些", "一点", "一样", "一直", "一定", "一般", "一起", "上来",
        "出来", "出来吧", "起来", "过去", "回来", "出来后", "开始", "结束",
        "时候", "的时候", "时间", "时候吧", "现在", "以前", "以后", "之后",
        "之前", "刚才", "刚刚", "突然", "其实", "确实", "真的", "好像", "感觉",
        "觉得", "认为", "知道", "明白", "理解", "记得", "忘了", "忘记",
        "首先", "其次", "最后", "第一", "第二", "第三",
        // 能愿 / 否定 / 程度（用户点名的「不要」「不能」在这一组）
        "不要", "不能", "不会", "不可以", "不能吧", "没能", "不用", "不必",
        "需要", "应该", "可能", "也许", "大概", "肯定", "必须", "可以", "能够",
        "能够个", "个这类", "这类", "不能够", "想要", "打算", "准备", "没有",
        "不是", "没有啊", "有点", "有些",
        "非常", "特别", "比较", "更加", "非常地", "太多", "太少", "很多",
        "非常快", "慢慢", "慢慢来", "快一点", "稍微", "略微",
        // 口语填充 / 寒暄 / 时间词
        "我们吧", "咱们俩", "今天", "明天", "昨天", "后天", "前天", "早上",
        "中午", "下午", "晚上", "上午", "白天", "晚上好", "早上好", "谢谢",
        "不好意思", "麻烦", "对不起", "没关系", "再见", "你好", "您好",
        "反正", "总之", "另外", "还有", "以及", "比如", "例如", "也就是说",
        "意思", "意思是", "为什么吧", "东西", "地方", "问题", "情况", "方面",
        "内容", "事情", "事儿", "工作啊", "这个吧", "那个吧", "是不是",
        "对不对", "好不好", "行不行", "可以吗", "对吧", "是吧", "好吗",
    ]

    /// ★ 2026-10-30（用户："常用词汇是那种比较专业的……『能够个』这类不能算"）：
    /// **子串级**过滤——候选 n-gram 只要*包含*下面的虚词组合就直接扔掉。
    ///
    /// 上一版只做整词匹配，「能够个」「不能算」这类因为不等于黑名单词条而漏网。
    /// 这里收录的都是"出现在任何更长片段里都足以判废"的虚词大片段
    /// （代词、能愿、连词、指代），真专名几乎不可能包含它们。
    private static let stopSubstrings: Set<String> = [
        "能够", "不能", "不会", "不要", "不得", "没能", "不用",
        "这个", "那个", "这种", "那种", "哪种", "这么", "那么",
        "我们", "你们", "他们", "她们", "咱们", "自己",
        "什么", "怎么", "怎样", "为什么", "如何",
        "就是", "还是", "但是", "可是", "不过", "如果", "虽然", "因为",
        "而且", "并且", "或者", "所以", "因此", "然后", "接着",
        "时候", "的话", "来说", "对于", "关于", "由于", "通过", "按照", "根据",
        "需要", "应该", "可能", "可以", "必须", "已经", "曾经",
        "没有", "不是", "其实", "确实", "真的", "感觉", "觉得", "知道",
        "比如", "例如", "还有", "以及", "首先", "其次",
        "一下", "一些", "一样", "这样", "那样", "这些", "那些",
        "准备", "打算", "想要", "比较", "非常", "特别", "很多", "有点", "有些", "好像",
    ]

    /// ★ 2026-10-30：**单字级**过滤——候选里出现这些字基本就是虚词尾巴
    /// （「的时候」「 able 」类）。助词/语气/代词字，专名里极罕见；
    /// 宁可错杀（「标的物」这类法律词会陪葬），也不让「能够个」进词表。
    private static let stopCharacters: Set<Character> = [
        "的", "了", "着", "吗", "呢", "吧", "啊", "嘛", "呗", "哦", "嗯",
        "呀", "啦", "哟", "喽", "之", "乎", "者",
        "我", "你", "您", "他", "她", "它", "咱", "谁", "们",
        "这", "那", "哪", "什", "怎",
    ]

    /// ★ 2026-10-30：网络热词词库——在转写里出现就收进词表（讯飞听见
    /// 「自定义热词」同款思路：命中即加权提示）。
    private static let hotwordLexicon: Set<String> = [
        "内卷", "躺平", "破防", "社死", "社恐", "社牛", "emo", "卷王", "摸鱼",
        "打工人", "干饭", "干饭人", "躺赢", "摆烂", "开摆", "绝绝子", "yyds",
        "上岸", "斜杠", "佛系", "柠檬精", "凡尔赛", "断舍离", "极简主义",
        "搭子", "饭搭子", "旅游搭子", "特种兵旅游", "CityWalk", "多巴胺",
        "情绪价值", "松弛感", "显眼包", "泼天富贵", "尊嘟假嘟", "泰裤辣",
        "氛围感", "天花板", "顶流", "出圈", "破圈", "翻车", "塌房", "吃瓜",
        "官宣", "带货", "种草", "拔草", "割韭菜", "白嫖", "真香", "上头",
        "下头", "离谱", "无语子", "栓Q", "芭比Q", "拿捏", "格局", "格局打开",
        "降维打击", "弯道超车", "开挂", "整活", "玩梗", "梗王", "爆梗",
    ]

    /// ★ 2026-10-30：行业词词库（科技 / 互联网 / 职场 / 商业）——会议与访谈
    /// 转写里最常见的专名层。出现即收。
    private static let industryLexicon: Set<String> = [
        // AI / 大模型
        "大模型", "人工智能", "生成式", "AIGC", "AGI", "GPT", "提示词", "多模态",
        "智能体", "Agent", "微调", "预训练", "推理成本", "算力", "GPU", "推理引擎",
        "开源模型", "闭源", "对齐", "幻觉", "上下文窗口", "向量数据库", "RAG",
        // 互联网 / 产品 / 研发
        "需求评审", "产品经理", "项目经理", "迭代", "灰度", "上线", "发布",
        "用户画像", "转化率", "留存率", "日活", "月活", "GMV", "私域", "公域",
        "引流", "变现", "闭环", "赋能", "抓手", "对齐颗粒度", "颗粒度", "复盘",
        "痛点", "痒点", "爆点", "赛道", "风口", "跨界", "生态位", "护城河",
        "SaaS", "API", "SDK", "前端", "后端", "全栈", "架构", "部署", "容器",
        "微服务", "数据库", "云服务", "云计算", "边缘计算", "数据中台",
        // 职场 / 管理 / 商业
        "KPI", "OKR", "ROI", "PMP", "Sprint", "站会", "周会", "复盘会",
        "晋升", "述职", "绩效", "年终奖", "期权", "股权", "融资", "估值",
        "天使轮", "风投", "VC", "IPO", "现金流", "毛利率", "净利率",
        "供应链", "渠道商", "经销商", "代理商", "品牌方", "甲方", "乙方",
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
