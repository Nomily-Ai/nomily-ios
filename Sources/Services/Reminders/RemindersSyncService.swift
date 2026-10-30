import EventKit
import Foundation
import os.log

/// ★ 2026-10-29（用户："待办支持同步到 iPhone 里面的待办，需要打开这个开关"）：
/// 把录音摘要里的待办行写进系统「提醒事项」App（EventKit Reminders）。
///
/// 设计要点：
/// · **幂等**——每条录音维护一份「待办文本 → calendarItemIdentifier」映射
///   （UserDefaults），文本没变过的行绝不重复创建；摘要重新生成后新增的行
///   会补建，被删掉的行**不会**去删用户提醒事项里的条目（删用户的提醒越权了，
///   页脚里说明这一点）。
/// · **勾选双向走单向镜像**——App 内勾选/取消勾选会把对应提醒的 `isCompleted`
///   同步过去；提醒事项 App 里打的勾不会回流（那是用户的私人清单，App 不去抢）。
/// · 权限：iOS 17+ 走 `requestFullAccessToReminders`，iOS 16 走老的
///   `requestAccess(to: .reminder)`；Info.plist 两条 usage description 都要。
final class RemindersSyncService {
    static let shared = RemindersSyncService()

    private let store = EKEventStore()
    private let log = Logger(subsystem: "com.nomily.app", category: "reminders")

    /// 每条录音的「待办文本 → 提醒事项条目标识」映射的 UserDefaults 键。
    private static func mapKey(recordingName: String) -> String {
        "reminders.map.\(recordingName)"
    }

    // MARK: authorization

    static func status() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    /// 弹系统授权框（未决定时）。已授权直接 true，被拒绝 false。
    func requestAccess() async -> Bool {
        if #available(iOS 17.0, *) {
            return (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            return await withCheckedContinuation { continuation in
                store.requestAccess(to: .reminder) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func ensureAccess() async -> Bool {
        switch RemindersSyncService.status() {
        case .authorized: return true
        case .notDetermined: return await requestAccess()
        default: return false
        }
    }

    // MARK: sync

    /// 把一份录音的待办行同步进默认提醒列表。返回**新建**的提醒条数（0 = 没有新东西）。
    @discardableResult
    func sync(blocks: [MarkdownBlock], recordingName: String) async -> Int {
        let todos = blocks.compactMap { block -> String? in
            switch block.kind {
            case .bullet, .ordered, .paragraph: return Self.stripMarkdown(block.text)
            case .heading, .quote, .rule: return nil
            }
        }
        .filter { !$0.isEmpty }
        guard !todos.isEmpty else { return 0 }

        guard await ensureAccess() else { return 0 }
        guard let list = store.defaultCalendarForNewReminders() else {
            log.error("no default reminders calendar")
            return 0
        }

        var map = Self.loadMap(recordingName: recordingName)
        var created = 0
        for text in todos where map[text] == nil {
            let reminder = EKReminder(eventStore: store)
            reminder.title = text
            reminder.calendar = list
            reminder.notes = String(format: L10n.Reminders.sourceNote, recordingName)
            do {
                try store.save(reminder, commit: true)
                map[text] = reminder.calendarItemIdentifier
                created += 1
            } catch {
                log.error("reminder save failed: \(String(describing: error), privacy: .public)")
                break
            }
        }
        Self.storeMap(map, recordingName: recordingName)

        // 打开开关那一刻，把 App 里已经勾过的行也同步成「已完成」。
        let checked = Set(
            (UserDefaults.standard.stringArray(forKey: "todo.checked.\(recordingName)") ?? [])
                .map(Self.stripMarkdown))
        for (text, id) in map where checked.contains(text) {
            setCompleted(id: id, completed: true)
        }
        return created
    }

    /// App 内勾选状态变化时镜像到提醒事项。
    func updateCompletion(text: String, recordingName: String, isCompleted: Bool) {
        let key = Self.stripMarkdown(text)
        guard let id = Self.loadMap(recordingName: recordingName)[key] else { return }
        setCompleted(id: id, completed: isCompleted)
    }

    // MARK: - 手表发来的一条待办（★ 2026-10-30）

    /// 手表 Recap 详情里点了一条待办 → 手机把它写进默认提醒列表。
    ///
    /// 与 `sync(blocks:recordingName:)` 的区别：这里是**单条、用户显式点击**，
    /// 所以不看「待办同步」总开关（那是批量自动同步的开关）；幂等性靠
    /// `manualCreatedTitles` 这份 UserDefaults 标题表保证——同一条要点两次
    /// 不会建出两条提醒。
    @discardableResult
    func createReminder(title: String, source: String) async -> Bool {
        let text = Self.stripMarkdown(title)
        guard !text.isEmpty else { return false }
        guard await ensureAccess() else { return false }
        guard let list = store.defaultCalendarForNewReminders() else {
            log.error("no default reminders calendar")
            return false
        }
        var created = Set(UserDefaults.standard.stringArray(forKey: Self.manualTitlesKey) ?? [])
        guard !created.contains(text) else { return true }

        let reminder = EKReminder(eventStore: store)
        reminder.title = text
        reminder.calendar = list
        if !source.isEmpty {
            reminder.notes = String(format: L10n.Reminders.sourceNote, source)
        }
        do {
            try store.save(reminder, commit: true)
            created.insert(text)
            UserDefaults.standard.set(Array(created), forKey: Self.manualTitlesKey)
            return true
        } catch {
            log.error("watch reminder save failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// 手表手动加入过的待办标题（去重用，见 `createReminder`）。
    private static let manualTitlesKey = "reminders.manual.titles"

    private func setCompleted(id: String, completed: Bool) {
        // iOS 17 起标记 deprecated（新写法在 EKEventStore 上没有单条查询的
        // 非 optional 版本），但依旧可用且只产生警告。
        let item = store.calendarItem(withIdentifier: id)
        guard let reminder = item as? EKReminder, reminder.isCompleted != completed else { return }
        reminder.isCompleted = completed
        do {
            try store.save(reminder, commit: true)
        } catch {
            log.error("reminder completion save failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: mapping persistence

    private static func loadMap(recordingName: String) -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: mapKey(recordingName: recordingName)) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private static func storeMap(_ map: [String: String], recordingName: String) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: mapKey(recordingName: recordingName))
    }

    // MARK: text cleanup

    /// 待办行里可能有 `**加粗**` / `` `代码` `` 之类的行内标记——提醒事项标题
    /// 是纯文本，把这几个记号剥掉。
    static func stripMarkdown(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\*\*|__|[*_`]"#,
            with: "",
            options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
