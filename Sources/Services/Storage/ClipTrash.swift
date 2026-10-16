import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "trash")

/// 回收站：删掉的录音先在这里躺 30 天，之后自动清掉。
///
/// ## 为什么是"搬家"而不是"记一笔再删"
/// 真把文件挪到 `.trash/<id>/` 里，好处是**删除立刻释放了"当前资料库"的
/// 空间语义**（列表、扫描、统计都看不见它了），恢复时又能一个字节不差地
/// 放回来。反过来"打个标记留着原地"会让 `LibraryScanner` 仍然把它扫出来，
/// 于是每一条删除都要在扫描器里补一个例外 —— 那种例外漏一个，回收站里
/// 的东西就漏进列表了。
///
/// ## 目录为什么在 `audioDir/.trash` 而不是 `decryptedDir`
/// `decryptedDir` 是扫描器要遍历的目录，往里塞东西就得靠"跳过隐藏文件"
/// 这种隐式约定。放成它的**兄弟目录**，扫描器天生看不见，索引文件也和
/// `.durations.json` / `.manifest.json` 挨在一起。
///
/// ## 30 天怎么落地
/// 没有后台任务可挂，所以 `purgeExpired()` 在**App 启动**和**打开回收站**
/// 时各跑一次。只要用户还会打开这个 App，过期的东西就不会一直躺着 ——
/// 这是"30 天后自动删除"在没有 BGTaskScheduler 的情况下能给出的最强承诺。
@MainActor
final class ClipTrash: ObservableObject {
    static let shared = ClipTrash()

    /// 保护期。用户要的 30 天。
    ///
    /// ⚠️ **必须是 `nonisolated`**：`TrashedItem.expiry` 是嵌在里面的普通
    /// struct 上的计算属性，它不在 main actor 上，直接读这个 `@MainActor`
    /// 类的静态量会报"main actor-isolated static property can not be
    /// referenced from a nonisolated context"。常量而已，不隔离更准确。
    nonisolated static let retentionDays = 30

    @Published private(set) var items: [TrashedItem] = []

    // MARK: - 模型

    struct TrashedItem: Codable, Identifiable, Equatable {
        /// 目录名，同时也是 `.trash/<id>/`。
        var id: String
        /// 原来的落盘 base（不带扩展名）。恢复时按它拼回原名。
        var base: String
        /// 目录里的文件名（都是原名），恢复时原样放回。
        var files: [String]
        var deletedAt: Date
        /// 删除那一刻的显示标题。用户改过的名字也在这里 —— 恢复之后
        /// `.title` 旁车文件会一起回来，所以只是给回收站列表看的。
        var title: String
        var bytes: Int64
        /// 这条素材"已从设备下过"的凭据。非 nil ⇒ 这次删掉了音频，
        /// 恢复时要把 manifest 那条补回去。
        var download: Download?

        /// 删除那一刻的**来源显示名**（"录音卡-3N9H" / "Apple Watch" /
        /// "本机导入"…）。
        ///
        /// ★ 2026-10-15：用户在回收站里问"这条是从哪来的，怎么只有删除"。
        /// 光靠上面那条 `download` 答不全 —— 它只在**设备下载**的条目上非空
        /// （手表 / 实时流 / 导入的从来都是 nil，因为它们本来就没有"再下载
        /// 一次"这回事）。所以来源必须在**删除那一刻**定死：晚一步就问不到了，
        /// 那时 manifest 里的记录已经被注销。
        ///
        /// 可选是有意的：老版本的 `index.json` 里没有这个键，`decodeIfPresent`
        /// 解出来就是 nil，界面回落到"不显示来源"，而不是整份索引解不开。
        var source: String?

        /// 设备那边的原始记录。字段与 `Library.Entry` 一一对应，
        /// 刻意**不**直接复用那个类型：回收站要能独立解码（那个类型在
        /// `Library` 里，改它的 `CodingKeys` 会连带把已入回收站的数据读不出来）。
        struct Download: Codable, Equatable {
            var name: String
            var size: Int
            var transport: String
            var deviceSerial: String?
            var deviceName: String?
            var localName: String
        }

        var expiry: Date {
            deletedAt.addingTimeInterval(TimeInterval(ClipTrash.retentionDays) * 24 * 3600)
        }

        /// 还剩几天。向上取整 —— 剩 3 小时也显示"还剩 1 天"，
        /// 显示 0 天却还在，比多报一天更让人困惑。
        var daysLeft: Int {
            max(0, Int(ceil(expiry.timeIntervalSinceNow / (24 * 3600))))
        }

        var hasAudio: Bool {
            files.contains { ClipArtefact.of(fileNamed: $0) == .audio }
        }
        var hasTranscript: Bool {
            files.contains { ClipArtefact.of(fileNamed: $0) == .transcript }
        }
        var hasSummary: Bool {
            files.contains { ClipArtefact.of(fileNamed: $0) == .summary }
        }
    }

    /// 一次删除要保护的东西。
    struct Payload {
        /// 落盘文件名。`StorageLocations` 那一套旁车路径都以它为基准。
        var localName: String
        /// 列表里的显示标题（用户改过的优先）。
        var title: String
        /// 这次要搬走的文件。**不存在的会被跳过** —— "只删转录"时音频
        /// 本来就不在列表里。
        var urls: [URL]
        /// 见 `TrashedItem.download`。
        var download: TrashedItem.Download?
        /// 见 `TrashedItem.source`。**删除前**就要填好（删除会把 manifest
        /// 记录注销，之后就查不出来了）。
        var source: String?
    }

    // MARK: - 位置

    private static var trashDir: URL {
        StorageLocations.audioDir.appendingPathComponent(".trash", isDirectory: true)
    }

    private static var indexURL: URL {
        trashDir.appendingPathComponent("index.json")
    }

    private init() {
        load()
    }

    // MARK: - 入站

    /// 搬进回收站。返回真的搬走了几组。
    ///
    /// - Parameter library: 只用来注销"已从设备下过"的凭据。删掉音频之后
    ///   **必须**注销，否则同一条录音再也下载不回来（`isDownloaded` 一直为真）。
    ///   恢复时 `restore` 会凭 `download` 把它补回去。
    @discardableResult
    func move(_ payloads: [Payload], library: Library) -> Int {
        let fm = FileManager.default
        var added: [TrashedItem] = []

        for payload in payloads {
            let present = payload.urls.filter { fm.fileExists(atPath: $0.path) }
            guard !present.isEmpty else { continue }

            let id = UUID().uuidString
            let dir = Self.trashDir.appendingPathComponent(id, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                var names: [String] = []
                var bytes: Int64 = 0
                for url in present {
                    let dest = dir.appendingPathComponent(url.lastPathComponent)
                    try fm.moveItem(at: url, to: dest)
                    names.append(url.lastPathComponent)
                    bytes += Self.fileSize(dest)
                }
                added.append(TrashedItem(
                    id: id,
                    // 组里所有文件都共用这个 base 前缀（旁车命名规则如此），
                    // 所以从落盘名推一次就够，不用去猜每个文件的。
                    base: (payload.localName as NSString).deletingPathExtension,
                    files: names,
                    deletedAt: Date(),
                    title: payload.title,
                    bytes: bytes,
                    download: payload.download,
                    source: payload.source
                ))
                // ⚠️ **文件搬完了才注销 manifest**：反过来的话中途出错会留下
                // "记录没了、文件还在"的孤儿 —— 那条录音既下载不回来，
                // 又不在回收站里。同 `LibraryView.runBatchDelete` 的顺序理由。
                if payload.download != nil {
                    library.forget(localName: payload.localName)
                }
            } catch {
                // 出错就把已经搬进临时目录的文件**搬回去**，不留半条。
                Self.rollback(dir: dir)
                log.error("trash move failed for \(payload.localName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if !added.isEmpty {
            items.append(contentsOf: added)
            save()
        }
        // 顺手清一次过期的：删除本来就要写盘，搭个顺风车不额外花钱。
        purgeExpired()
        return added.count
    }

    // MARK: - 出站

    /// 放回去。返回是否成功。
    ///
    /// 名字撞车时**整组一起顺延**到 `base-2`：旁车文件全靠 base 前缀和音频
    /// 配对，只给音频改名会让 `.txt` / `.summary.md` 全部变成孤儿。
    @discardableResult
    func restore(_ item: TrashedItem, library: Library) -> Bool {
        let fm = FileManager.default
        let dir = Self.trashDir.appendingPathComponent(item.id, isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else {
            // 目录已经没了（被外部清掉过）—— 把它从索引里摘掉，别留一条
            // 点了没反应的记录。
            forget(item)
            return false
        }

        // 每个文件相对 base 的那截后缀（`.opus` / `.txt` / `.summary.md` / `.title`）。
        // 理论上每个文件都带这个前缀；万一不带（手改过目录），就保持原名不动，
        // 而不是拼出一个四不像。
        let suffixes: [String?] = item.files.map {
            $0.hasPrefix(item.base) ? String($0.dropFirst(item.base.count)) : nil
        }
        let targetBase = Self.availableBase(item.base, suffixes: suffixes.compactMap { $0 })
        let target = StorageLocations.decryptedDir

        var movedBack: [String] = []
        var audioName: String?
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for (index, name) in item.files.enumerated() {
                let newName = suffixes[index].map { targetBase + $0 } ?? name
                try fm.moveItem(
                    at: dir.appendingPathComponent(name),
                    to: target.appendingPathComponent(newName)
                )
                movedBack.append(newName)
                if ClipArtefact.of(fileNamed: newName) == .audio { audioName = newName }
            }
        } catch {
            // 放一半最糟 —— 列表里会出现"有转录没音频"的残缺条目。全部退回。
            for (index, name) in movedBack.enumerated() {
                try? fm.moveItem(
                    at: target.appendingPathComponent(name),
                    to: dir.appendingPathComponent(item.files[index])
                )
            }
            log.error("trash restore failed for \(item.base, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }

        // 凭据补回去。`localName` 用**新的**落盘名：名字顺延过的话 manifest
        // 里那条也得跟着改，否则下次进列表，来源标识会查不到（索引按落盘名）。
        if let download = item.download {
            library.recordDownload(
                name: download.name,
                size: download.size,
                transport: download.transport,
                deviceSerial: download.deviceSerial,
                deviceName: download.deviceName,
                localName: audioName ?? download.localName
            )
        }

        // 恢复出来的不算"新到的"。
        //
        // 文件的 `modifiedAt` 会变成此刻 —— 刚好越过未读账本里那个 `origin`
        // 时间戳，不记一笔的话，用户亲手捞回来 5 条就会看到 5 颗红点，像是
        // 又来了 5 条新录音。名字用**顺延后**的那个（重名时是 `base-2.opus`）；
        // 组里没有音频（只删过转录）时，列表用的是扫描器合成的 `base.opus`。
        ClipReadStore.shared.markSeen(name: audioName ?? "\(item.base).opus")

        try? fm.removeItem(at: dir)
        forget(item)
        return true
    }

    /// 从索引里摘掉一条（不碰文件）。
    private func forget(_ item: TrashedItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    // MARK: - 清理

    /// 永久删除一条。**不可撤销** —— 调用方负责二次确认。
    func purge(_ item: TrashedItem) {
        Self.deleteFiles(of: item)
        forget(item)
    }

    /// 清空。
    func purgeAll() {
        for item in items { Self.deleteFiles(of: item) }
        items.removeAll()
        save()
    }

    /// 清掉过期的。返回清掉了几条。
    @discardableResult
    func purgeExpired() -> Int {
        let now = Date()
        let expired = items.filter { $0.expiry <= now }
        guard !expired.isEmpty else { return 0 }
        for item in expired { Self.deleteFiles(of: item) }
        items.removeAll { $0.expiry <= now }
        save()
        log.notice("purged \(expired.count, privacy: .public) expired trash item(s)")
        return expired.count
    }

    private static func deleteFiles(of item: TrashedItem) {
        try? FileManager.default.removeItem(
            at: trashDir.appendingPathComponent(item.id, isDirectory: true)
        )
    }

    // MARK: - 工具

    /// 找一个不撞的 base：原 base 没被占用就用它，否则 `base-2`、`base-3`…
    private static func availableBase(_ base: String, suffixes: [String]) -> String {
        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        func taken(_ candidate: String) -> Bool {
            suffixes.contains { fm.fileExists(atPath: dir.appendingPathComponent(candidate + $0).path) }
        }
        guard taken(base) else { return base }
        var n = 2
        while taken("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// 把已经搬进 `.trash/<id>/` 的文件原样搬回 `decryptedDir`。
    private static func rollback(dir: URL) {
        let fm = FileManager.default
        let back = StorageLocations.decryptedDir
        let entries = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in entries {
            try? fm.moveItem(
                at: url,
                to: back.appendingPathComponent(url.lastPathComponent)
            )
        }
        try? fm.removeItem(at: dir)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return Int64(size)
    }

    // MARK: - 磁盘

    private struct Index: Codable {
        var items: [TrashedItem]
    }

    private func load() {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: Self.indexURL),
           let index = try? JSONDecoder().decode(Index.self, from: data) {
            // 索引里有、目录里没有 ⇒ 这条已经没文件了，摘掉（否则点恢复
            // 只会得到一句"失败"）。
            items = index.items.filter {
                fm.fileExists(atPath: Self.trashDir.appendingPathComponent($0.id).path)
            }
        }
        // 目录里有、索引里没有 ⇒ 孤立目录（索引写盘失败时留下的）。
        // 它们在磁盘上永远占着空间，且没有任何界面能碰到，直接清掉。
        let known = Set(items.map(\.id))
        let dirs = (try? fm.contentsOfDirectory(at: Self.trashDir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where dir.hasDirectoryPath && !known.contains(dir.lastPathComponent) {
            try? fm.removeItem(at: dir)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.trashDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Index(items: items))
            try data.write(to: Self.indexURL, options: .atomic)
        } catch {
            log.error("trash index save failed: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - 从 Library 取下载凭据

extension ClipTrash {

    /// 该不该把 `.title` 旁车**一起**带进回收站。
    ///
    /// 只在"这条除了正在删的那部分，就再没有别的 artefact 了"时返回 URL。
    /// 原因是 `ClipArtefact.sweepOrphanTitles()`：`.title` 不算三种可删
    /// artefact 之一，一旦它成了唯一残留物，扫描器会照它重建出一条既没音频
    /// 也没正文的幽灵条目，所以孤儿标题必须清掉。可"清掉"对回收站来说太绝了 ——
    /// 恢复了音频而标题回不来。搬进来同进同出，才是"删除可撤销"该有的样子。
    ///
    /// - Parameter hasOtherArtefacts: **这次删除之后**这条还剩不剩别的
    ///   artefact（音频 / 转录 / 摘要任一）。调用方按"没在删的那些"判断。
    static func titleSidecar(forLocalName localName: String, hasOtherArtefacts: Bool) -> URL? {
        guard !hasOtherArtefacts else { return nil }
        let url = StorageLocations.titleURL(for: localName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 这条素材的来源显示名（"录音卡-3N9H" / "Apple Watch" / …）。
    ///
    /// 复用 `Library.ClipSource.displayName` 而不是在这里另写一套：那一份
    /// 已经处理了"用户别名 → 落库名 → 兜底词 + SN 末 4 位"的全部回落，
    /// 回收站里另写一遍迟早和资料库列表显示得不一样 —— 而用户会拿两边对照。
    ///
    /// ⚠️ **必须在删除动作发起之前调**。`ClipTrash.move` 会顺手把 manifest
    /// 里那条记录注销掉，之后就再也查不到来源了（查不到会回落成"导入"，
    /// 于是卡上的录音被标成用户自己导进来的）。
    static func sourceLabel(forLocalName localName: String, in library: Library) -> String? {
        let name = library.source(forLocalName: localName).displayName
        return name.isEmpty ? nil : name
    }

    /// 这条素材"已从设备下过"的凭据（没有就 nil）。
    ///
    /// 只有**设备下载**（键形如 `serial::name`）才需要记账：手表 / 实时流 /
    /// 导入的条目本来就没有"再下载一次"这回事，给它们记一条只会在恢复时
    /// 往 manifest 里塞脏数据。
    ///
    /// 名字取的是键里 `::` **后面**那段（设备那边的原始文件名），而不是落盘名：
    /// 两者只有在重名时才不同，而恢复时要用前者+serial 才能拼回同一条键。
    static func downloadRecord(
        forLocalName localName: String, in library: Library
    ) -> TrashedItem.Download? {
        guard let raw = library.rawEntry(forLocalName: localName),
              let serial = raw.entry.deviceSerial else { return nil }
        return TrashedItem.Download(
            name: String(raw.key.dropFirst(serial.count + 2)),
            size: raw.entry.size,
            transport: raw.entry.transport,
            deviceSerial: serial,
            deviceName: raw.entry.deviceName,
            localName: raw.entry.localName ?? localName
        )
    }
}
