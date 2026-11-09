import SwiftUI

// MARK: - Nomily 问答（★ 2026-11-03 十轮，十一轮大改）
//
// 用户原话：「APP 里面会增加一个叫 Nomily 的按钮，点击之后可以在里面询问一些说过的话、
// 录音、待办之类的，相当于询问一个个人知识库一样」。
//
// ## 为什么不是把全部录音塞给模型
// 库里几十条录音、每条几十 KB 转写，全塞进去第一是 token 不允许，第二是模型在
// 一大堆无关材料里找答案反而更容易编。所以这页的回答分两步：
// ① **检索**——用 `LibraryKnowledgeIndex`（库内搜索的同一份正文缓存）把与问题
//    最相关的几条录音找出来；
// ② **回答**——只把这几条的摘要/相关片段作为材料交给模型，并附上来源标题。
//
// ## 十一轮（用户反馈逐条）
// · 标签图标换成 **App 图标的白色剪影**（`NomilyLogo`，从 nomi-logo.png 抠出来的），
//   随选中态染色；页面里用彩色原版 `NomilyLogoColor`；
// · 名字统一 **Nomily**（上一版标签写成了 Nomi）；
// · 回答**不显示 Markdown 源码**——走 `MarkdownBlocks.parse` 的紧凑渲染；
// · 键盘三连：发送即收起、下滑收起、工具栏「完成」——上一版键盘常驻把页面钉死，
//   别的标签都点不到；输入条改 `safeAreaInset`，不再叠在键盘下面；
// · **历史提问落盘**（Documents/nomily-chat.json）：杀掉 App 重进也在；
//   空态里列出最近问过的问题，点一下直接再问；
// · 回答请求加 90s 超时——上一版请求挂住时 `busy` 一直是 true，页面像死了一样。

// MARK: - 检索

enum NomilyRetriever {

    struct Hit: Identifiable {
        let base: String
        let title: String
        let dateText: String
        let document: String
        let score: Int
        /// ★ 十三轮：短日期 / 短时间（"11-03" / "14:09"）。回答卡片左列的两行小字
        ///   就用它——模型转述日期不可靠，时间一律由客户端从文件名算出来。
        let shortDate: String?
        let shortTime: String?
        var id: String { base }
    }

    /// 取与问题最相关的录音。
    ///
    /// 评分 = 问题的**二元组**（相邻两字）在正文里出现的次数 + 整句命中的大额奖励
    /// + 最近录音的小额加权。二元组是现成套路（`ClipDetailView.characterBigrams`
    /// 用它做溯源匹配），对中文友好：问"预算定了多少"，"预算"两个字就能命中。
    static func top(query: String, items: [LibraryItem], documents: [String: String], limit: Int = 5) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let grams = Array(CharacterBigrams.of(needle))
        guard !grams.isEmpty else { return [] }

        var hits: [Hit] = []
        for item in items where item.hasText {
            guard let doc = documents[item.base], !doc.isEmpty else { continue }
            let lowered = doc.lowercased()
            var score = 0
            for gram in grams where lowered.contains(gram) { score += 1 }
            // 整句（≥4 字）直接命中正文：这是"用户问的就是这条录音"的最强信号。
            if needle.count >= 4, lowered.contains(needle.lowercased()) { score += 12 }
            // 最近 7 天的录音 +2：问"今天/刚才"时，时间近的更可能是答案。
            if let modified = Calendar.current.dateComponents([.day], from: item.modifiedAt, to: Date()).day,
               modified <= 7 { score += 2 }
            guard score > 0 else { continue }

            let short = Self.shortTimestamp(for: item.name)
            hits.append(Hit(base: item.base, title: item.displayTitle,
                            dateText: RecordingName.displayTitle(for: item.name),
                            document: doc, score: score,
                            shortDate: short?.date, shortTime: short?.time))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// 文件名（`yyyyMMddHHmmss`）→ "11-03" / "14:09"。
    private static func shortTimestamp(for filename: String) -> (date: String, time: String)? {
        guard let date = RecordingName.date(from: filename) else { return nil }
        let cal = Calendar.current
        return (String(format: "%02d-%02d", cal.component(.month, from: date), cal.component(.day, from: date)),
                String(format: "%02d:%02d", cal.component(.hour, from: date), cal.component(.minute, from: date)))
    }
}

/// 与 `ClipDetailView.characterBigrams` 同一套字符二元组，独立成小工具
/// （那一份是 private static，两处用途不同，不为此抽公共文件）。
enum CharacterBigrams {
    static func of(_ text: String) -> Set<String> {
        let chars = Array(text.lowercased())
        guard chars.count >= 2 else { return [text.lowercased()] }
        var out = Set<String>()
        for i in 0..<(chars.count - 1) { out.insert(String(chars[i...i + 1])) }
        return out
    }
}

// MARK: - 落盘

/// 会话历史。存 `Documents/nomily-chat.json`：杀 App、重启、第二天回来都在。
///
/// ⚠️ 只存必要字段（谁说的、什么内容、引用了哪些来源），不存草稿不存错误——
///    这份文件的存在意义是"我还找得回我问过什么"，不是完整恢复现场。
enum NomilyChatStore {

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var isUser: Bool
        var text: String
        var sources: [Source] = []
        // ★ 2026-11-04 十三轮：结构化回答（参考样式：卡片头 + 标题 + 逐条证据）。
        //   旧会话记录里没有这两个键，`decodeIfPresent` 自动补 nil，落盘向后兼容。
        var answer: Answer?
        var at: Date?

        /// 兼容构造：时间戳 / 结构化回答 / 覆盖数全部可缺省（用户消息只填前两个）。
        init(isUser: Bool, text: String, sources: [Source] = [], answer: Answer? = nil, at: Date? = nil) {
            self.isUser = isUser
            self.text = text
            self.sources = sources
            self.answer = answer
            self.at = at
        }

        struct Source: Codable, Equatable, Identifiable {
            let title: String
            let dateText: String
            // ★ 十三轮：短日期/时间（卡片左列的两行小字）。旧会话记录里没有 → nil。
            var shortDate: String?
            var shortTime: String?
            var id: String { title + dateText }
        }

        /// 模型按固定 JSON 回出来的结构化回答。
        ///
        /// ⚠️ 字段全部可缺省：各家模型对"只回 JSON"的服从度不一样，尾巴带一句
        ///    说明、items 里混进空条目都是常态。解析宁可宽松——缺什么就少渲染什么，
        ///    headline 都没有就整个回落到旧的 Markdown 渲染（`text` 一直在）。
        struct Answer: Codable, Equatable {
            var headline: String
            var items: [Item]
            var note: String?
            /// 参与检索的录音总数（"基于 248 条录音"）。**客户端填**，不走模型——
            /// 模型不知道库有多大，让它报只会编。
            var coverage: Int?

            struct Item: Codable, Equatable, Identifiable {
                var title: String?
                var detail: String?
                /// 材料编号（1 起），指向这条证据出自哪条录音。
                var source: Int?
                var id: String { "\(source ?? 0)|\(title ?? "")" }
            }

            init(headline: String, items: [Item], note: String?, coverage: Int? = nil) {
                self.headline = headline
                self.items = items
                self.note = note
                self.coverage = coverage
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                headline = (try? c.decode(String.self, forKey: .headline)) ?? ""
                items = (try? c.decode([Item].self, forKey: .items)) ?? []
                note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
                coverage = nil
            }

            /// 落盘前由客户端补上覆盖数。
            func with(coverage: Int) -> Answer {
                var copy = self
                copy.coverage = coverage
                return copy
            }

            private enum CodingKeys: String, CodingKey {
                case headline, items, note, coverage
            }
        }
    }

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nomily-chat.json")
    }

    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    static func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    /// 最近问过的问题（去重、倒序），空态里那排「历史提问」用它。
    static func recentQuestions(from entries: [Entry], limit: Int = 5) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for entry in entries.reversed() where entry.isUser {
            let key = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(key)
            if out.count >= limit { break }
        }
        return out
    }
}

// MARK: - 会话模型

@MainActor
final class NomilyChatModel: ObservableObject {

    typealias Entry = NomilyChatStore.Entry
    typealias Source = Entry.Source

    @Published private(set) var messages: [Entry] = []
    @Published var draft = ""
    @Published private(set) var busy = false
    @Published var errorText: String?

    /// 建议的第一问。有历史提问时被「最近问过」取代。
    ///
    /// ★ 2026-11-05 十四轮：这三条原来写死中文——英文空态下三条全漏（用户截图）。
    /// 键缺 en 时回落到这里。
    static var suggestions: [String] {
        [
            NSLocalizedString("nomily.suggest_recent", value: "我最近记了些什么？",
                              comment: "Suggested question: overview of recent recordings"),
            NSLocalizedString("nomily.suggest_todos", value: "我的待办还有哪些没做？",
                              comment: "Suggested question: open to-dos across the library"),
            NSLocalizedString("nomily.suggest_last_meeting", value: "上次开会定了什么？",
                              comment: "Suggested question: decisions from the last meeting"),
        ]
    }

    /// ★ 十四轮：库内速览（待办聚合 + 最近记录）。空态三张卡与输入条上方的
    /// 快捷提问都用它；IO 在后台，回主线程赋值。
    @Published private(set) var digest: NomilyDigestBuilder.Digest?

    func loadDigest(items: [LibraryItem]) {
        Task.detached(priority: .utility) { [weak self] in
            let digest = NomilyDigestBuilder.build(items: items)
            await MainActor.run { self?.digest = digest }
        }
    }

    init() {
        // ★ 十三轮：老记录里 `answer` 是 nil（那时还没这个字段）。如果它的 text 恰好是
        //   JSON（升级前问过、模型服从格式的那几条），这里补一次解析，省得"旧问法看不到新卡片"。
        messages = NomilyChatStore.load().map { entry in
            guard !entry.isUser, entry.answer == nil,
                  let answer = Self.parseAnswer(entry.text) else { return entry }
            var fixed = entry
            fixed.answer = answer
            return fixed
        }
    }

    /// 今天日期注入 prompt：用户问"上周定了什么"这类相对时间时模型才有锚点。
    private static var todayLine: String {
        let fmt = DateFormatter()
        // ★ 2026-11-09：跟随 App 内语言（原来跟系统 locale，中文设备的英文
        // 界面会把"2026年11月9日"塞进提示词/页面）。
        fmt.locale = AppLocale.current
        fmt.dateStyle = .long
        return "Today is \(fmt.string(from: Date()))."
    }

    private static var systemPrompt: String {
        L10n.Nomily.system + "\n" + Self.todayLine
    }

    var recentQuestions: [String] { NomilyChatStore.recentQuestions(from: messages) }

    func send(config: AppConfig, items: [LibraryItem], index: LibraryKnowledgeIndex, signature: LibraryScanner.Signature?) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        draft = ""
        errorText = nil
        append(Entry(isUser: true, text: question, at: Date()))
        busy = true

        Task { @MainActor in
            defer { busy = false }
            do {
                let bases = items.filter(\.hasText).map(\.base)
                let documents = await index.documents(for: bases)
                let hits = NomilyRetriever.top(query: question, items: items, documents: documents)

                guard !hits.isEmpty else {
                    append(Entry(isUser: false, text: L10n.Nomily.noMatch, at: Date()))
                    return
                }

                // 每条材料压到 ~1400 字（摘要优先在开头，转写细节在后），
                // 5 条 ≈ 7k 字 ≈ 4k tokens，一次请求装得下也不至于贵。
                // ★ 十三轮：材料头带上短日期/时间，模型在 JSON 里只需回 `source` 编号，
                //   时间列由客户端按编号回查——日期永远不许模型自己转述。
                let material = hits.enumerated().map { index, hit -> String in
                    let body = String(hit.document.prefix(1400))
                    let when = hit.shortDate.map { "\($0) \(hit.shortTime ?? "")" } ?? hit.dateText
                    return "[\(index + 1)] \(when) 《\(hit.title)》\n\(body)"
                }.joined(separator: "\n\n")

                let citedSources = hits.map {
                    Source(title: $0.title, dateText: $0.dateText,
                           shortDate: $0.shortDate, shortTime: $0.shortTime)
                }
                let coverage = items.filter(\.hasText).count

                // ★ 90s 超时：检索+生成正常 10~20s。请求挂住时上一版会永远转圈，
                //   用户只能杀 App；现在到点给一句明确的话，会话还能继续用。
                let outcome = try await Self.withTimeout(seconds: 90) {
                    try await LLMCompletionService.completeResilient(
                        systemPrompt: Self.systemPrompt,
                        userContent: """
                        \(Self.todayLine)

                        LIBRARY MATERIAL
                        \(material)

                        QUESTION
                        \(question)

                        OUTPUT FORMAT — reply with JSON only, no markdown fence, no text before or after:
                        {"headline": "<1-2 sentences: the direct answer>", "items": [{"title": "<=16 chars", "detail": "<one sentence of evidence>", "source": <material number>}], "note": "<one caveat sentence, or empty string>"}
                        - items: 0 to 5, the library entries that back the headline, most relevant first; "source" is the [n] number above. Use an empty array when the question needs no evidence list.
                        - note: caveats such as excerpts being incomplete go here; empty string if none.
                        - Same language as the question. Never invent recordings, dates or titles.
                        """,
                        config: config,
                        allowChunking: false
                    )
                }
                let answer = Self.parseAnswer(outcome.completion.text)?
                    .with(coverage: coverage)
                append(Entry(isUser: false, text: outcome.completion.text,
                             sources: citedSources, answer: answer, at: Date()))
            } catch is TimeoutError {
                errorText = L10n.Nomily.timeout
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func clear() {
        messages.removeAll()
        errorText = nil
        NomilyChatStore.clear()
    }

    // MARK: 私有

    /// 从模型输出里抠出结构化回答。失败返回 nil → 页面回落到 Markdown 渲染。
    ///
    /// 模型常见的三种不服从都兜住了：裹一层 ```json 围栏、JSON 前后带说明文字
    /// （取首个 `{` 到最后一个 `}`）、items 里混进没标题的空条目（直接丢）。
    static func parseAnswer(_ text: String) -> Entry.Answer? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              var answer = try? JSONDecoder().decode(Entry.Answer.self, from: data) else { return nil }
        answer.headline = answer.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.headline.isEmpty else { return nil }
        // 过滤空条目、修掉越界的 source 编号、封顶 6 条（材料只有 5 条）。
        answer.items = answer.items.compactMap { item -> Entry.Answer.Item? in
            guard let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            var fixed = item
            fixed.title = title
            fixed.detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let s = fixed.source, s < 1 { fixed.source = nil }
            return fixed
        }
        if answer.items.count > 6 { answer.items = Array(answer.items.prefix(6)) }
        let note = answer.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        answer.note = (note?.isEmpty == false) ? note : nil
        return answer
    }

    private func append(_ entry: Entry) {
        messages.append(entry)
        NomilyChatStore.save(messages)
    }

    private struct TimeoutError: Error {}

    private static func withTimeout<T: Sendable>(seconds: TimeInterval,
                                                 _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - 回答的紧凑 Markdown 渲染
//
// 用户原话："显示内容不要 md 文档"。上一版直接 `Text(answer)`，模型按提示词
// 输出的 `**加粗**`、`- 列表` 原样糊在屏幕上。这里复用库内的
// `MarkdownBlocks.parse`（摘要页同一套解析），只是排版收紧成聊天气泡的密度。

private struct ChatMarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let blocks = MarkdownBlocks.parse(text)
            if blocks.isEmpty {
                Text(text)
            } else {
                ForEach(blocks) { block in
                    switch block.kind {
                    case .heading(let level):
                        Text(inline(block.text))
                            .font(.system(size: level <= 2 ? 14 : 13, weight: .semibold))
                            .padding(.top, 3)
                    case .bullet:
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(Color.secondary.opacity(0.55))
                                .frame(width: 3.5, height: 3.5)
                                .padding(.top, 7)
                            Text(inline(block.text))
                                .font(.system(size: 14))
                                .lineSpacing(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .ordered(let number):
                        HStack(alignment: .top, spacing: 7) {
                            Text("\(number).")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.appAccent)
                                .padding(.top, 1.5)
                            Text(inline(block.text))
                                .font(.system(size: 14))
                                .lineSpacing(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    case .quote:
                        Text(inline(block.text))
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(Color.secondary.opacity(0.35))
                                    .frame(width: 2.5)
                            }
                    case .rule:
                        // 聊天气泡里分隔线只有噪音价值，吞掉。
                        EmptyView()
                    case .paragraph:
                        Text(inline(block.text))
                            .font(.system(size: 14))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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

// MARK: - 回答卡片（★ 2026-11-04 十三轮）
//
// 用户原话：「底部那个问答页面需要优化…参考他的样式，不要参考他的配色」。
// 参考稿的结构（不是配色）：品牌头（左标 + 覆盖数）→ 一句大标题直接给答案 →
// 分隔线 → 逐条证据（左列短日期/时间，右侧标题 + 一句细节 + 来源胶囊）→ 脚注。
//
// ## 为什么不让模型自己排版
// 上一版把整段 Markdown 糊进一个气泡，十条录音挤成一坨字，找"哪天说的"要逐行读。
// 卡片式的前提是**字段级**的数据（标题、日期、细节各归各位），而自由文本没有字段。
// 所以让模型只回固定 JSON（见 `NomilyChatModel.parseAnswer`），版式完全由这里决定；
// 日期/时间/覆盖数都由客户端算——模型转述日期不可靠，让它报"库有多大"只会编。
//
// ## 回落
// `Entry.answer == nil`（旧会话记录、或模型没按格式回）时走原来的 Markdown 渲染，
// `text` 里始终存着原始全文，长按复制复制的是全文。

private struct NomilyAnswerCard: View {
    let answer: NomilyChatStore.Entry.Answer
    let sources: [NomilyChatStore.Entry.Source]

    private typealias Answer = NomilyChatStore.Entry.Answer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Text(answer.headline)
                .font(.system(size: 16.5, weight: .semibold))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            if !answer.items.isEmpty {
                divider.padding(.vertical, 10)
                // ⚠️ 2026-11-04：这里 18:51 闪了三下，崩溃日志是
                //   `Array._checkSubscript` ← `NomilyAnswerCard.body`。
                //   原因：`itemRow(item, previousSource: answer.items[index - 1].source)`
                //   是**无条件求值**的实参，index == 0 时就是 `items[-1]`。
                //   `if index > 0` 只包住了分隔线，包不住实参——所以每张卡片第一条必崩。
                //   现在把越界判断放进实参表达式里（`index > 0 ? … : nil`）。
                //   顺带把 ForEach 的 id 换成 offset：`Item.id` 是 source+title，
                //   同一条录音下两个同名条目会撞 id，ForEach 会当成重复行。
                ForEach(Array(answer.items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { divider.padding(.vertical, 9) }
                    itemRow(item, previousSource: index > 0 ? answer.items[index - 1].source : nil)
                }
            }

            if let note = noteText {
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, answer.items.isEmpty ? 10 : 12)
            }
        }
    }

    // MARK: 头部

    /// 左：品牌小标（logo + NOMILY 字距拉开）；右：本次检索覆盖的录音数。
    private var header: some View {
        HStack(spacing: 5) {
            Image("NomilyLogoColor")
                .resizable()
                .frame(width: 13, height: 13)
                .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            Text(L10n.Tab.nomily.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            if let coverage = answer.coverage {
                Text(L10n.Nomily.coverage(coverage))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: 证据条目

    private func itemRow(_ item: Answer.Item, previousSource: Int?) -> some View {
        let source = resolvedSource(for: item)
        return HStack(alignment: .top, spacing: 10) {
            // 左列：短日期 / 时间两行小字。没有（旧记录、文件名解析不出）就整列让位。
            if let source, source.shortDate != nil {
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.shortDate ?? "")
                        .font(.system(size: 10))
                        .monospacedDigit()
                    Text(source.shortTime ?? " ")
                        .font(.system(size: 10))
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? "")
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // 同一条录音只挂一次胶囊：连着的两条都出自它时，第二颗是噪音。
                if let source, item.source != previousSource {
                    sourceChip(source)
                }
            }
        }
    }

    /// 来源胶囊：主题色染色的录音名。作用还是"可核对"，不是导航。
    private func sourceChip(_ source: NomilyChatStore.Entry.Source) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.system(size: 8, weight: .semibold))
            Text(source.title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(Color.appAccent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.appAccent.opacity(0.10)))
    }

    /// `source` 是 1 起的材料编号；越界（模型编的）一律按无来源处理。
    private func resolvedSource(for item: Answer.Item) -> NomilyChatStore.Entry.Source? {
        guard let index = item.source, sources.indices.contains(index - 1) else { return nil }
        return sources[index - 1]
    }

    // MARK: 脚注

    /// 模型给了一句就用它的；没给但列了证据，就上默认的那句"均来自库内录音节选"。
    private var noteText: String? {
        if let note = answer.note, !note.isEmpty { return note }
        return answer.items.isEmpty ? nil : L10n.Nomily.defaultNote
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.14))
            .frame(height: 0.5)
    }
}

// MARK: - 库内速览（★ 2026-11-05 十四轮）
//
// 用户原话："有些问题需要提前根据录制文档摘设想好会提问哪些问题，方便点击就直接提问，
// 然后当前页面添加类似这样待办，相关清单的事项…还有不同时间记录的"（参考图是竞品的
// 待办卡 / 清单 / 日历页）。
//
// 竞品那三页的**信息本质**是：把"你录过什么、欠了什么"在进问答页之前就摆出来，
// 每一项都是一条已经写好的提问。所以这里不照抄页面，把同一份信息做成空态的三张卡：
//
//   ① 待办卡 —— 全库摘要的行动项聚合（谁欠的、几条过期），点一下直接问"待办还剩哪些"；
//   ② 最近记录卡 —— 按时间列最近几条，每条就是一个"《这篇》说了什么"的提问；
//   ③ 建议提问 —— 静态三条兜底（有 ①② 时排在最后）。
//
// ## 为什么是"扫摘要文件"而不是又一个全局索引
// 待办本来就活在每条录音的 `.summary.md` 里（`TodoExtract` 是唯一权威解析器），
// 勾选状态在 UserDefaults 的 `todo.checked.<录音名>`。这里只做**只读聚合**：
// 不新建存储、不新增状态机，详情页勾掉的待办在这里自动消失——两条数据路径天然一致。
// IO 在 utility 队列（最多 120 条摘要），结果回主线程。

enum NomilyDigestBuilder {

    struct TodoEntry: Equatable, Identifiable {
        let line: String
        let owner: String?
        let due: String?
        let overdue: Bool
        let recordingTitle: String
        let dateText: String
        var id: String { line + dateText }
    }

    struct RecordingEntry: Equatable, Identifiable {
        let name: String
        let title: String
        let dateText: String
        /// 点这条卡 = 直接发出的提问。
        let question: String
        var id: String { name }
    }

    struct Digest: Equatable {
        var todos: [TodoEntry] = []
        var overdueCount = 0
        var othersCount = 0
        var recordings: [RecordingEntry] = []
        /// 待办/记录全空时 UI 整段隐藏，只留静态建议。
        var hasAnything: Bool { !todos.isEmpty || !recordings.isEmpty }
    }

    private static let maxScan = 120
    private static let maxTodos = 30

    static func build(items: [LibraryItem]) -> Digest {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        // 最近的排前面：文件名是 yyyyMMddHHmmss，字典序即时间序。
        let sorted = items
            .filter { $0.hasText && $0.hasSummary }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(maxScan)

        var todos: [TodoEntry] = []
        var recordings: [RecordingEntry] = []
        let defaults = UserDefaults.standard

        for item in sorted {
            let summary = try? String(contentsOf: StorageLocations.summaryURL(for: item.name), encoding: .utf8)
            if let summary, !summary.isEmpty {
                let checked = Set(defaults.stringArray(forKey: "todo.checked.\(item.name)") ?? [])
                let blocks = TodoExtract.fromSummary(summary)
                for block in blocks {
                    guard case .bullet = block.kind else { continue }
                    let text = block.text
                    guard !checked.contains(text) else { continue }
                    let todo = TodoItem.parse(text)
                    // 过期：只认 "MM-DD" 形状的截止；"本周五""月底"这类解析不了就放过。
                    var overdue = false
                    if let due = todo.due, let range = due.range(of: #"^\d{1,2}-\d{1,2}$"#, options: .regularExpression) {
                        let parts = due[range].split(separator: "-").compactMap { Int($0) }
                        if parts.count == 2,
                           let dueDate = calendar.date(from: DateComponents(year: calendar.component(.year, from: today),
                                                                            month: parts[0], day: parts[1])),
                           calendar.startOfDay(for: dueDate) < today {
                            overdue = true
                        }
                    }
                    todos.append(TodoEntry(line: text,
                                           owner: todo.owner,
                                           due: todo.due,
                                           overdue: overdue,
                                           recordingTitle: item.displayTitle,
                                           dateText: fmt.string(from: item.modifiedAt)))
                    if todos.count >= maxTodos { break }
                }
            }
            if recordings.count < 5 {
                recordings.append(RecordingEntry(
                    name: item.name,
                    title: item.displayTitle,
                    dateText: fmt.string(from: item.modifiedAt),
                    question: L10n.Nomily.suggestRecording(item.displayTitle)))
            }
            if todos.count >= maxTodos, recordings.count >= 5 { break }
        }

        return Digest(todos: todos,
                      overdueCount: todos.filter(\.overdue).count,
                      othersCount: todos.filter { $0.owner != nil && $0.owner != "我" }.count,
                      recordings: recordings)
    }
}

// MARK: - 页面

/// 底部第四个标签页：问自己的录音。
struct NomilyView: View {
    @EnvironmentObject private var configService: ConfigService
    @StateObject private var chat = NomilyChatModel()
    @StateObject private var library = LibraryListModel()
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if chat.messages.isEmpty {
                    emptyState
                } else {
                    transcript
                }
            }
            // ★ 输入条用 safeAreaInset 而不是塞进 VStack：它参与安全区布局，
            //   键盘弹起时自动让位，不会像上一版那样"输入条 + 键盘"两层叠住内容，
            //   也没有一条看不见的触摸层挡在正文上面。
            // ★ 十四轮：会话进行中时，输入条上方挂一排**快捷提问**——用户要点的是
            //   "不用打字直接问"，这排在空态里是大卡，进了会话就收成小胶囊。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if !chat.messages.isEmpty, let digest = chat.digest, digest.hasAnything {
                        quickChips(digest)
                    }
                    inputBar
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(L10n.Tab.nomily)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !chat.messages.isEmpty {
                        Button { chat.clear() } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .accessibilityLabel(Text(L10n.Nomily.clear))
                    }
                }
                // ★ 键盘工具栏的「完成」：用户点完输入框想看上面的历史时，
                //   得有一个明确、永远在的收键盘方式——下滑收起有 it，但很多人不知道。
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(L10n.Common.done) { inputFocused = false }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .task {
            await library.refresh()
            chat.loadDigest(items: library.items)
        }
        // 库列表异步刷新完成后重建速览（第一次 task 跑的时候 items 可能还是空的）。
        .onChange(of: library.items.count) { _ in
            chat.loadDigest(items: library.items)
        }
        // 切走标签时收键盘：上一版"卡在这个页面"的直接体感就是键盘跟着人走。
        .onDisappear { inputFocused = false }
    }

    // MARK: 空态

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 22) {
                // 品牌 logo：App 图标的彩色原版（original 渲染，不跟随主题染色）。
                Image("NomilyLogoColor")
                    .resizable()
                    .frame(width: 68, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                    .padding(.top, 30)

                Text(L10n.Nomily.tagline)
                    .font(.system(size: 16, weight: .semibold))
                    .multilineTextAlignment(.center)

                Text(L10n.Nomily.explain)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)

                // ★ 十四轮：速览卡（待办 / 最近记录）。库里有摘要才出现，
                //   全空整段隐藏——空库不给用户看两个空壳。
                if let digest = chat.digest, digest.hasAnything {
                    todoCard(digest)
                        .padding(.horizontal, 14)
                    recentCard(digest)
                        .padding(.horizontal, 14)
                }

                // 历史提问优先——用户点名的需求："即使今天刚提的问题，
                // 也可以看到历史提问记录"。没有历史才给建议问法。
                let recents = chat.recentQuestions
                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(L10n.Nomily.recentTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        ForEach(recents, id: \.self) { question in
                            Button {
                                chat.draft = question
                                send()
                            } label: {
                                suggestionRow(question, symbol: "clock.arrow.circlepath")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    VStack(spacing: 9) {
                        ForEach(NomilyChatModel.suggestions, id: \.self) { suggestion in
                            Button {
                                chat.draft = suggestion
                                send()
                            } label: {
                                suggestionRow(suggestion, symbol: "sparkles")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func suggestionRow(_ text: String, symbol: String) -> some View {
        HStack {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 6)
            Image(systemName: symbol)
                .foregroundStyle(Color.appAccent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
    }

    // MARK: ★ 十四轮：速览卡

    /// 待办卡：header（过期红字 / 等别人灰字）+ 未完成前 3 条 + 追问入口。
    /// 数据来自 `NomilyDigestBuilder`（只读聚合每条录音的 `.summary.md`），
    /// 详情页勾掉的待办在这里自动消失。
    private func todoCard(_ digest: NomilyDigestBuilder.Digest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text(L10n.Nomily.cardTodos)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 6)
                if digest.overdueCount > 0 {
                    Text(L10n.Nomily.cardOverdue(digest.overdueCount))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
                if digest.othersCount > 0 {
                    Text(L10n.Nomily.cardOthers(digest.othersCount))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(digest.todos.prefix(3)) { todo in
                let parsed = TodoItem.parse(todo.line)
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: todo.overdue ? "exclamationmark.circle" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(todo.overdue ? Color.red : Color.secondary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(parsed.title)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            if let due = todo.due {
                                Text(due)
                                    .font(.caption2.weight(todo.overdue ? .semibold : .regular))
                                    .foregroundStyle(todo.overdue ? Color.red : Color.secondary)
                            }
                            Text(todo.recordingTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Button {
                askNow(L10n.Nomily.suggestTodos)
            } label: {
                HStack {
                    Text(L10n.Nomily.suggestTodos)
                        .font(.footnote)
                        .foregroundStyle(Color.appAccent)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(Color.appAccent)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .contentShape(Rectangle())
    }

    /// 最近记录卡：最近 5 条有摘要的录音，点一条 = 直接问它讲了什么。
    private func recentCard(_ digest: NomilyDigestBuilder.Digest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
                Text(L10n.Nomily.cardRecent)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            ForEach(digest.recordings) { entry in
                Button {
                    askNow(entry.question)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(entry.dateText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(Color.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    /// 会话进行中时输入条上方的一排快捷提问：待办汇总 + 最近 3 条录音。
    private func quickChips(_ digest: NomilyDigestBuilder.Digest) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(L10n.Nomily.cardTodos, symbol: "checklist",
                     question: L10n.Nomily.suggestTodos)
                ForEach(digest.recordings.prefix(3)) { entry in
                    chip(entry.title, symbol: "waveform", question: entry.question)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    private func chip(_ text: String, symbol: String, question: String) -> some View {
        Button {
            askNow(question)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(text)
                    .font(.footnote)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color(uiColor: .secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    /// 点卡片/胶囊 = 填入问题并直接发送（用户原话："方便点击就直接提问"）。
    private func askNow(_ question: String) {
        chat.draft = question
        send()
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(uiColor: .secondarySystemGroupedBackground))
    }

    // MARK: 会话

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(chat.messages.enumerated()), id: \.element.id) { index, message in
                        // ★ 十三轮：每组提问上方一条居中的小时间戳（参考样式）。
                        //   只标在**用户消息**上：回答的时间就是"刚刚"，标了是噪音。
                        if let stamp = Self.timestampCaption(for: message,
                                                             previous: index > 0 ? chat.messages[index - 1] : nil) {
                            Text(stamp)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        bubble(message).id(message.id)
                    }
                    if chat.busy {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(L10n.Nomily.thinking)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(bubbleShape.fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    }
                    if let error = chat.errorText {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            // 下滑即收键盘（交互式：手指拖到哪收到哪）。
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat.messages.count) { _ in
                if let last = chat.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: 时间戳

    private static let stampClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let stampDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M-d"
        return f
    }()

    /// 用户消息组开头的那条时间戳。同一组里的后续提问不重复标（10 分钟内的连问算一组）。
    private static func timestampCaption(for message: NomilyChatStore.Entry,
                                         previous: NomilyChatStore.Entry?) -> String? {
        guard message.isUser, let at = message.at else { return nil }
        if let previous, previous.isUser, let prevAt = previous.at,
           at.timeIntervalSince(prevAt) < 600 { return nil }
        let cal = Calendar.current
        let time = stampClock.string(from: at)
        if cal.isDateInToday(at) { return "\(L10n.Nomily.today) \(time)" }
        if cal.isDateInYesterday(at) { return "\(L10n.Nomily.yesterday) \(time)" }
        return "\(stampDay.string(from: at)) \(time)"
    }

    @ViewBuilder
    private func bubble(_ message: NomilyChatModel.Entry) -> some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(bubbleShape.fill(Color.appAccent))
            }
        } else if let answer = message.answer {
            // ★ 十三轮：结构化回答卡片（参考样式，配色走本 App 主题）。
            NomilyAnswerCard(answer: answer, sources: message.sources)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(bubbleShape.fill(Color(uiColor: .secondarySystemGroupedBackground)))
                // 长按复制：复制的是模型的原始全文，不是卡片里那几行摘要。
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Label(L10n.Common.copyText, systemImage: "doc.on.doc")
                    }
                }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // ★ 回答走紧凑 Markdown 渲染（十一轮："显示内容不要 md 文档"），
                //   不再是满屏的 ** 星号和 - 连字符。
                ChatMarkdownText(text: message.text)
                if !message.sources.isEmpty {
                    // 来源胶囊：回答引用了哪几条录音，点开什么都不做——
                    // 它在这里的作用是**可核对性**，不是又一层导航。
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(message.sources) { source in
                                HStack(spacing: 4) {
                                    Image(systemName: "waveform")
                                        .font(.system(size: 8, weight: .semibold))
                                    Text("\(source.dateText) \(source.title)")
                                        .font(.system(size: 10))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.secondary.opacity(0.10)))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bubbleShape.fill(Color(uiColor: .secondarySystemGroupedBackground)))
            // 长按复制：回答里的原话经常要贴到别处。
            .contextMenu {
                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Label(L10n.Common.copyText, systemImage: "doc.on.doc")
                }
            }
        }
    }

    /// 气泡底：只给形状，**不在这里填色**——用户气泡要主题色、回答气泡要浅灰，
    /// 形状里写死填充就分不出来了（第一版就是这么错的：返回类型成了 some View）。
    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
    }

    // MARK: 输入条

    private var inputBar: some View {
        HStack(spacing: 9) {
            TextField(L10n.Nomily.placeholder, text: $chat.draft, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { send() }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
            Button(action: send) {
                // 发送键用品牌图标（App logo 原色）——这页的身份就是"在问 Nomily"。
                Image("NomilyLogoColor")
                    .resizable()
                    .frame(width: 19, height: 19)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .padding(7)
                    .background(Circle().fill(canSend ? Color.appAccent.opacity(0.16) : Color.secondary.opacity(0.14)))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !chat.busy && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        // ★ 发送即收键盘（十一轮："输入之后…持续是有键盘再展示页面没办法点击其他的"）：
        //   问完的人要的是看回答和往回翻历史，不是继续打字；键盘再挡半屏就是负价值。
        inputFocused = false
        chat.send(config: configService.config,
                  items: library.items,
                  index: .shared,
                  signature: library.signature)
    }
}
