import Combine
import CryptoKit
import Foundation
import UserNotifications
import os.log

private let todoLog = Logger(subsystem: "com.nomily.app.ios", category: "todo")

// MARK: - 待办看板数据层（★ 2026-11-06 · 饭耳 1.0 移植 P0-1）
//
// 用户原话（引用饭耳 1.0 逆向报告）："卡片攒了很久，现在处理一下"——待办不该只是
// 摘要里的一张只读表，它得有**状态**：新抓的（等你决定）→ 要做 → 做完 / 不用做 /
// 稍后提醒。没有状态机，"今天做完 1 件""都看完了"这类话就无从谈起。
//
// ## 为什么另起一份存储，而不是给 `todo.checked.*` 加字段
// 勾选状态是按「行文本」存 UserDefaults 的，它是**存量**：用户已经勾过的几十条
// 不能作废。所以这里：
//  · 新存储 `StorageLocations.todoBoardURL`（App Group JSON，照 `VocabularyStore`）；
//  · 旧键**只读兼容**——载入和 ingest 时读到 `todo.checked.<recording>` 里有这一行，
//    就把卡片标成 `done`，旧数据不迁移、不删除；
//  · 反向保持同步——在卡片上点「做完」也会把这一行写回旧键，摘要详情页的勾选框
//    跟着变。两条路径读写同一份事实，而不是各说各话。
//
// ## id 为什么是 hash 而不是行文本
// 行文本会随着「重新生成摘要」变化（模型措辞不同），拿它当主键等于每次重生成都
// 丢一遍状态。`sha256(title|owner|due|recording)` 前 16 hex：同一件事在同一条
// 录音里稳定，措辞微调也不影响；同时旧键 `todo.checked.*` 仍按行文本读写，
// 两套 id 各管各的，互不干扰。

// MARK: - 模型

/// 一张待办卡的状态机。
enum TodoStatus: String, Codable, CaseIterable, Identifiable {
    /// 刚从摘要里抓出来，用户还没决定（对应饭耳的"清算"队列）。
    case pending
    /// 用户决定要做。
    case accepted
    /// 做完了。
    case done
    /// 用户决定不用做（"这事跟我没关系"）。
    case wont
    /// 稍后提醒（带 `remindAt`）。
    case deferred

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pending: return L10n.Todo.statusPending
        case .accepted: return L10n.Todo.statusAccepted
        case .done: return L10n.Todo.statusDone
        case .wont: return L10n.Todo.statusWont
        case .deferred: return L10n.Todo.statusDeferred
        }
    }

    var symbol: String {
        switch self {
        case .pending: return "questionmark.circle"
        case .accepted: return "circle"
        case .done: return "checkmark.circle.fill"
        case .wont: return "slash.circle"
        case .deferred: return "clock.arrow.circlepath"
        }
    }

    /// 已结束（done/wont）在清单里收进"已结束"折叠组。
    var isClosed: Bool { self == .done || self == .wont }
}

struct TodoCard: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var owner: String?
    var due: String?
    /// 摘要里的来源秒数（`[mm:ss]`）。
    var stamp: TimeInterval?
    /// 来源录音的文件名（跳播放/去重都用它）。
    var recordingName: String
    /// 来源录音的显示标题（生成时快照，录音改名不影响历史卡）。
    var recordingTitle: String?
    var status: TodoStatus
    var remindAt: Date?
    var createdAt: Date
    var updatedAt: Date

    /// 与摘要详情页共用的那一行文本 `事项 · @张伟 · 11-08 · [12:24]`。
    var composed: String {
        var pieces = [title]
        if let owner, !owner.isEmpty { pieces.append("@\(owner)") }
        if let due, !due.isEmpty { pieces.append(due) }
        if let stamp { pieces.append("[\(StampRef.format(stamp))]") }
        return pieces.joined(separator: " · ")
    }

    /// 稳定主键：同一件事在同一条录音里恒等，措辞微调不影响。
    static func makeID(title: String, owner: String?, due: String?, recording: String) -> String {
        let raw = [title, owner ?? "", due ?? "", recording].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 截止日（只认 `MM-DD` / `M-D` / `YYYY-MM-DD` 三种形状）。
    /// "本周五""月底"这类解析不了就返回 `nil`——猜一个日期比不显示更糟。
    func dueDate(reference: Date = Date()) -> Date? {
        guard let due else { return remindAt }
        let calendar = Calendar.current
        let trimmed = due.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "-").compactMap { Int($0) }
        guard !parts.isEmpty else { return remindAt }
        if parts.count == 3 {
            return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        }
        if parts.count == 2 {
            let year = calendar.component(.year, from: reference)
            if let date = calendar.date(from: DateComponents(year: year, month: parts[0], day: parts[1])) {
                // 跨年：12 月看到的 "01-05" 指明年。
                if calendar.startOfDay(for: date).timeIntervalSince(reference) < -180 * 86_400 {
                    return calendar.date(from: DateComponents(year: year + 1, month: parts[0], day: parts[1]))
                }
                return date
            }
        }
        return remindAt
    }
}

// MARK: - 看板

/// 全部待办卡的唯一存储与状态机入口。
///
/// 线程约定：`@MainActor`——卡片会被列表直接渲染，写操作也来自 UI 手势；
/// 摘要任务在后台完成时用 `await` 切过来（见 `JobRunners` 的调用点）。
@MainActor
final class TodoBoard: ObservableObject {

    static let shared = TodoBoard()

    /// 全部卡片，按 `createdAt` 倒序（最新抓的在上）。
    @Published private(set) var cards: [TodoCard] = []

    private let queue = DispatchQueue(label: "com.nomily.app.todoboard", qos: .utility)

    private init() {
        load()
    }

    // MARK: 派生视图

    /// 等你决定的（清算队列）。
    var inbox: [TodoCard] { cards.filter { $0.status == .pending } }
    /// 要做但还没做完。
    var active: [TodoCard] {
        cards.filter { $0.status == .accepted }
            .sorted { ($0.dueDate() ?? .distantFuture) < ($1.dueDate() ?? .distantFuture) }
    }
    /// 稍后提醒。
    var later: [TodoCard] {
        cards.filter { $0.status == .deferred }
            .sorted { ($0.remindAt ?? .distantFuture) < ($1.remindAt ?? .distantFuture) }
    }
    /// 已结束（做完 / 不用做），最近更新的在上。
    var closed: [TodoCard] {
        cards.filter { $0.status.isClosed }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var inboxCount: Int { cards.filter { $0.status == .pending }.count }

    /// 今天做完的件数（饭耳首页「今天做完 1 件」）。
    var doneTodayCount: Int {
        let calendar = Calendar.current
        return cards.filter {
            $0.status == .done && calendar.isDateInToday($0.updatedAt)
        }.count
    }

    /// 有截止、且已过期的未完成条数。
    var overdueCount: Int {
        let today = Calendar.current.startOfDay(for: Date())
        return cards.filter {
            ($0.status == .accepted || $0.status == .deferred)
                && ($0.dueDate().map { Calendar.current.startOfDay(for: $0) < today } ?? false)
        }.count
    }

    // MARK: 采集

    /// 把一条录音摘要里的待办灌进看板。返回**新增**的卡片数。
    ///
    /// 幂等：同一 `id` 已存在时只刷新标题/负责人/截止（模型重生成后措辞变了），
    /// **状态与提醒时间不动**——用户已经做过的决定不该被一次重新生成抹掉。
    @discardableResult
    func ingest(summary: String, recordingName: String, recordingTitle: String?) -> Int {
        let blocks = TodoExtract.fromSummary(summary)
        var parsed: [TodoItem] = []
        for block in blocks {
            switch block.kind {
            case .bullet, .ordered, .paragraph:
                let text = RemindersSyncService.stripMarkdown(block.text)
                guard text.count >= 2 else { continue }
                parsed.append(TodoItem.parse(block.text))
            case .heading, .quote, .rule:
                continue
            }
        }
        // 手写待办（`todo.manual.<recording>`）也进看板：用户自己记的事本该和
        // AI 抓的事在同一张清单上排队。
        for text in UserDefaults.standard.stringArray(forKey: "todo.manual.\(recordingName)") ?? [] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { continue }
            parsed.append(TodoItem(title: trimmed, owner: nil, due: nil, stamp: nil))
        }
        guard !parsed.isEmpty else { return 0 }

        let checked = Set(UserDefaults.standard.stringArray(forKey: "todo.checked.\(recordingName)") ?? [])
        var added = 0
        var changed = false

        for item in parsed {
            let id = TodoCard.makeID(title: item.title, owner: item.owner, due: item.due, recording: recordingName)
            let now = Date()
            if let index = cards.firstIndex(where: { $0.id == id }) {
                let old = cards[index]
                // 只更新来源字段，状态保留。
                if old.title != item.title || old.owner != item.owner
                    || old.due != item.due || old.stamp != item.stamp
                    || old.recordingTitle != recordingTitle {
                    cards[index].title = item.title
                    cards[index].owner = item.owner
                    cards[index].due = item.due
                    cards[index].stamp = item.stamp
                    cards[index].recordingTitle = recordingTitle ?? old.recordingTitle
                    cards[index].updatedAt = now
                    changed = true
                }
                continue
            }
            // 旧勾选兼容：摘要页勾过的行，进看板就是"做完"。
            let legacyDone = checked.contains(item.composed)
            cards.insert(TodoCard(
                id: id,
                title: item.title,
                owner: item.owner,
                due: item.due,
                stamp: item.stamp,
                recordingName: recordingName,
                recordingTitle: recordingTitle,
                status: legacyDone ? .done : .pending,
                remindAt: nil,
                createdAt: now,
                updatedAt: now
            ), at: 0)
            added += 1
            changed = true
        }

        guard changed else { return 0 }
        persist()
        return added
    }

    // MARK: 状态变更

    /// 改状态。`done` 会同步回旧勾选键，`accepted`/`deferred` 会排本地通知。
    func setStatus(_ id: String, _ status: TodoStatus, remindAt: Date? = nil) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        let card = cards[index]
        cards[index].status = status
        cards[index].updatedAt = Date()

        switch status {
        case .deferred:
            let when = remindAt ?? TodoNotifier.defaultRemindDate()
            cards[index].remindAt = when
            TodoNotifier.schedule(cards[index])
        case .accepted:
            // "要做"但没定时间的，默认明早 8:30 提一次——饭耳的默认就是这个。
            cards[index].remindAt = remindAt ?? TodoNotifier.defaultRemindDate()
            TodoNotifier.schedule(cards[index])
        case .done, .wont, .pending:
            cards[index].remindAt = nil
            TodoNotifier.cancel(card.id)
        }

        mirrorLegacyCheck(card, checked: status == .done)
        persist()
    }

    /// 稍后提醒（滑动手势用）：固定推迟到明早 8:30，已过期则顺延一天。
    func snooze(_ id: String) {
        setStatus(id, .deferred, remindAt: TodoNotifier.defaultRemindDate())
    }

    /// 直接删除一张卡（"这条不是我记的事"）。
    func remove(_ id: String) {
        TodoNotifier.cancel(id)
        cards.removeAll { $0.id == id }
        persist()
    }

    /// 摘要详情页勾选后回流（详情页 → 看板单向，避免两套状态打架）。
    /// 详情页写的是旧键，这里按行文本找到卡片对一下状态。
    func syncFromLegacyChecks(recordingName: String) {
        let checked = Set(UserDefaults.standard.stringArray(forKey: "todo.checked.\(recordingName)") ?? [])
        var changed = false
        for index in cards.indices where cards[index].recordingName == recordingName {
            let isChecked = checked.contains(cards[index].composed)
            if isChecked, !cards[index].status.isClosed {
                cards[index].status = .done
                cards[index].remindAt = nil
                cards[index].updatedAt = Date()
                TodoNotifier.cancel(cards[index].id)
                changed = true
            } else if !isChecked, cards[index].status == .done {
                cards[index].status = .accepted
                cards[index].updatedAt = Date()
                changed = true
            }
        }
        if changed { persist() }
    }

    // MARK: 旧勾选镜像

    private func mirrorLegacyCheck(_ card: TodoCard, checked: Bool) {
        let key = "todo.checked.\(card.recordingName)"
        var list = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let line = card.composed
        if checked {
            guard !list.contains(line) else { return }
            list.insert(line)
        } else {
            guard list.contains(line) else { return }
            list.remove(line)
        }
        UserDefaults.standard.set(Array(list), forKey: key)
    }

    // MARK: 持久化

    private func load() {
        guard let data = try? Data(contentsOf: StorageLocations.todoBoardURL) else { return }
        guard let list = try? JSONDecoder().decode([TodoCard].self, from: data) else {
            todoLog.error("todo board json unreadable")
            return
        }
        cards = list.sorted { $0.createdAt > $1.createdAt }
        // 旧勾选兜底：上次退出在摘要页勾的，启动后卡片跟上。
        var touched = false
        for index in cards.indices where !cards[index].status.isClosed {
            let key = "todo.checked.\(cards[index].recordingName)"
            let checked = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
            if checked.contains(cards[index].composed) {
                cards[index].status = .done
                touched = true
            }
        }
        if touched { persist() }
    }

    private func persist() {
        let snapshot = cards
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: StorageLocations.todoBoardURL, options: .atomic)
        }
    }
}

// MARK: - 本地通知

/// 待办提醒。文案带来源录音名——通知栏里"把成本压到 30 以内"不如
/// "《周三产品会》· 把成本压到 30 以内"有用。点开落到待办页（由
/// `AppEnvironment` 的路由处理，未做路由时至少能打开 App）。
enum TodoNotifier {

    private static let center = UNUserNotificationCenter.current()

    /// 默认提醒时间：**明早 8:30**；若现在还没到今早 8:30 就用今早。
    /// 对齐饭耳"下次 明早 8:30"，也符合"早上起来看昨天欠了什么"的作息。
    static func defaultRemindDate(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 8
        components.minute = 30
        guard var date = calendar.date(from: components) else {
            return now.addingTimeInterval(86_400)
        }
        if date <= now.addingTimeInterval(60) {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        }
        return date
    }

    static func schedule(_ card: TodoCard) {
        guard let when = card.remindAt, when > Date() else { return }
        Task {
            let granted = await ensureAuthorization()
            guard granted else {
                todoLog.info("todo notification skipped: not authorized")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = card.title
            content.body = {
                let source = card.recordingTitle ?? RecordingName.displayTitle(for: card.recordingName)
                return L10n.Todo.notifyBody(source)
            }()
            content.sound = .default
            content.userInfo = ["todoID": card.id, "recording": card.recordingName]
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: when)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: identifier(card.id), content: content, trigger: trigger)
            try? await center.add(request)
        }
    }

    static func cancel(_ id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier(id)])
    }

    private static func identifier(_ id: String) -> String { "todo.\(id)" }

    private static func ensureAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }
}
