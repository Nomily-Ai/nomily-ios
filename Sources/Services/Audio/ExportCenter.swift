import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "export")

/// 「导出已经备好、等着你去分享」这件事的账本 + 暂存区。
///
/// ## 为什么需要它
/// 用户的原话：**"导出音频对于大文件音频需要等待很久……需要挂在后台，也支持
/// 等 App 完成后来点击传输，防止退出需要重新等待"**。
///
/// 拆成两半看：
///
/// 1. **挂在后台** —— 那半边是 `BackgroundKeeper.acquire(.export)` 的事，
///    让复制 / 重编码在用户切走时不被挂起。
/// 2. **退出后回来还能点传输** —— 就是这里。原来的暂存目录固定在
///    `FileManager.default.temporaryDirectory/nomily-export`，两个问题：
///    * iOS 会在**任何时候**清理 `tmp/`（尤其 App 不在前台时），导出好了
///      但还没分享，一觉醒来文件没了 —— 用户点了分享却什么都没有；
///    * 没有任何记录说明"上次导出成功过"，所以回来只看得到一个空列表，
///      唯一的选择是**从头再等一遍**。
///
///    于是把暂存挪到 App 容器里（`root`，不进 `tmp`），并把"备好了哪一份"
///    落盘。回来就能直接点分享，不用重来。
///
/// ## 只留一份（**故意**）
/// 每次开新导出都会把上一份整个删掉。理由：这是**中转站**，不是用户数据 ——
/// 用户真正想要的东西会在分享面板里被存到"文件"/AirDrop 出去。留多份只会
/// 把手机塞满（二十条会议录音轻松几个 GB），而"上一份"对用户而言也没有
/// 任何用处：他要的永远是刚勾的那一批。
@MainActor
final class ExportCenter: ObservableObject {
    static let shared = ExportCenter()

    /// 一份**已经备好、等着分享**的导出。
    struct Ready: Codable, Equatable, Identifiable {
        /// 暂存目录名（同时是身份）。分享的是 `stagingRoot/<id>`。
        var id: String
        /// 界面上给这份导出起的名字（"3 条录音" / "会议记录"）。
        var title: String
        var itemCount: Int
        var bytes: Int64
        var createdAt: Date
        /// 这条导出**来自哪条录音**（单条导出填 `LibraryItem.name`，
        /// 批量导出为 nil）。
        ///
        /// 为什么要区分：详情页只想在"这一份就是这条录音导出来的"时候
        /// 露出分享入口。不区分的话，用户在详情页会看到一个"分享 3 条录音"
        /// 的按钮 —— 那批东西和他眼前这条毫无关系。
        var origin: String?

        var isBatch: Bool { origin == nil }
    }

    /// 备好但还没被分享出去的那一份。`nil` = 没有。
    @Published private(set) var ready: Ready?

    /// 超过这个时长还没被分享就自动清掉。
    ///
    /// 72 小时（三天）：短到不至于让几 GB 的中转文件长期占着空间，长到能盖住
    /// "周五下班前导的，周一回来接着发"这种最常见的跨度。真正的空间管理还是
    /// 靠界面上那个显式"清理"按钮 —— 这一条只是保险丝。
    nonisolated static let retention: TimeInterval = 72 * 3600

    private init() {
        // `loadReady` 会顺手校验目录还在不在、有没有过期（见那边的注释）。
        self.ready = Self.loadReady()
    }

    // MARK: - 位置

    /// 暂存根目录。**在 App 容器里、不在 `tmp`** —— 见类型头部第 2 点。
    ///
    /// 目录名带前导点：`UIFileSharingEnabled` 打开时"文件"App 里看不见它，
    /// 资料库扫描器也不会把它当素材扫出来。
    private static var stagingRoot: URL {
        StorageLocations.root.appendingPathComponent(".export-staging", isDirectory: true)
    }

    private static var indexURL: URL {
        stagingRoot.appendingPathComponent("ready.json")
    }

    // MARK: - 开一份新的

    /// 开一个新的暂存目录并返回它。**会顺手删掉上一份**（见类型头部的说明）。
    func beginNewStaging() throws -> URL {
        let fm = FileManager.default
        // 清掉上一份（连同它的记录）。用户既然点了新的导出，
        // 上一份就不是他要的东西了。
        try? fm.removeItem(at: Self.stagingRoot)
        let dir = Self.stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        ready = nil
        return dir
    }

    /// 登记"这一份备好了"。
    func publish(id: String, title: String, itemCount: Int, bytes: Int64, origin: String?) {
        let item = Ready(
            id: id,
            title: title,
            itemCount: itemCount,
            bytes: bytes,
            createdAt: Date(),
            origin: origin
        )
        ready = item
        Self.save(item)
        log.info("export ready: \(title, privacy: .public) (\(itemCount) item(s), \(bytes) bytes)")
    }

    // MARK: - 取用 / 丢弃

    /// 这份东西现在在磁盘上的路径（还在才返回）。
    func url(for item: Ready) -> URL? {
        let url = Self.stagingRoot.appendingPathComponent(item.id, isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 这一份属于某条录音吗？详情页用它决定要不要显示分享入口。
    func ready(forOrigin origin: String) -> Ready? {
        guard let ready, ready.origin == origin else { return nil }
        return url(for: ready) == nil ? nil : ready
    }

    /// 用户分享完了 / 主动清理。释放空间。
    func discard() {
        guard let item = ready else { return }
        try? FileManager.default.removeItem(
            at: Self.stagingRoot.appendingPathComponent(item.id, isDirectory: true)
        )
        ready = nil
        Self.save(nil)
        log.info("export staging discarded: \(item.title, privacy: .public)")
    }

    /// 磁盘上还剩多少中转文件（给界面显示"点清理能腾出多少"）。
    var stagedBytes: Int64 { ready?.bytes ?? 0 }

    // MARK: - 磁盘

    private static func loadReady() -> Ready? {
        guard let data = try? Data(contentsOf: indexURL),
              let item = try? JSONDecoder().decode(Ready.self, from: data) else {
            // 有索引就读索引；索引坏了/没有，但目录里还有东西 —— 那是上一版
            // 留下的孤儿，清掉。它们没有任何界面能碰到，只会占着空间。
            try? FileManager.default.removeItem(at: stagingRoot)
            return nil
        }
        // 目录还在不在？（被 iOS 清过 / 被用户从"文件"里删过）
        let url = stagingRoot.appendingPathComponent(item.id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else {
            log.notice("export staging gone from disk; dropping record")
            save(nil)
            return nil
        }
        // 过期保险丝。见 `retention`。
        guard Date().timeIntervalSince(item.createdAt) < retention else {
            log.info("export staging expired; purging")
            try? FileManager.default.removeItem(at: url)
            save(nil)
            return nil
        }
        return item
    }

    private static func save(_ item: Ready?) {
        let fm = FileManager.default
        guard let item else {
            try? fm.removeItem(at: indexURL)
            return
        }
        do {
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(item)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            log.error("export index save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
