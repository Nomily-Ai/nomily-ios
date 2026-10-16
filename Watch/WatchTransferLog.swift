import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.watch", category: "transfer-log")

/// 一条传输记录。
///
/// ★ 2026-10-15（用户："右上角就是手表的传输记录"）：右上角那个角标从
/// 「呼吸灯速率」换成这一页 —— 呼吸灯并进了左上的外观页（它本来就是外观的
/// 一部分），空出来的位置给了一个**真正需要单独一页**的东西。
///
/// ## 为什么值得记
/// 手表的录音是"先落在表上、再传给手机、最后由手机确认入库"，中间任何一步
/// 都可能停住。以前这三步的证据只存在于 `WatchLink` 的两个内存 `Set` 里 ——
/// 表一重启就没了，而"我早上录的那条到底传上去没有"恰恰是重启之后才会问的
/// 问题。落一份盘，这个问题才有答案。
struct WatchTransferRecord: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        /// 交给 WatchConnectivity 排队了，还没出门。
        case queued
        /// 系统已经把它投给了手机那侧的守护进程 —— 但**手机 App 还没确认写盘**。
        /// 这个中间态必须单独显示：这一步卡住是"看着像成功、其实没入库"。
        case delivered
        /// 手机 App 确认已入库。只有到这一步，手表上的本地副本才会删掉。
        case stored
        case failed

        /// 排序用：越"完成"越靠后。仅用于同一时刻的稳定排序，不参与展示。
        var rank: Int {
            switch self {
            case .failed:    return 0
            case .queued:    return 1
            case .delivered: return 2
            case .stored:    return 3
            }
        }
    }

    var name: String
    var bytes: Int64
    /// 最近一次状态变化的时刻。列表按它倒序。
    var updatedAt: Date
    var state: State
    /// 失败原因；成功入库时记送达时刻的文案由视图自己拼。
    var detail: String?

    var id: String { name }
    var displayTitle: String { RecordingName.displayTitle(for: name) }
}

/// 传输记录的落盘账本。**只增不删**（除了用户主动清空 + 容量上限）。
///
/// ## 为什么放在手表自己的 Documents
/// 这份记录是**手表视角**的：同一条录音在手表上可能"已入库"，而手机那边
/// 用户已经把它删了。两边语义不同，混在一份账里迟早对不上。手表这份只回答
/// "我发出去的东西有没有着落"。
@MainActor
final class WatchTransferLog: ObservableObject {
    static let shared = WatchTransferLog()

    /// 上限。手表磁盘小，而且"上周那条传没传上去"没人会翻到第 200 条之后。
    /// 记满就砍最老的 —— 砍的是**记录**，不是录音文件。
    static let maxEntries = 200

    @Published private(set) var records: [WatchTransferRecord] = []

    private let url: URL

    private struct Payload: Codable { var records: [WatchTransferRecord] }

    private init() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = root.appendingPathComponent("transfer-log.json")
        load()
    }

    // MARK: - 记账

    /// 排队成功。同名重复调用会被忽略（`WatchLink` 自己也会去重，
    /// 但保留文件被重新排队时要能刷新 —— 所以这里允许"更新已存在的失败条目"）。
    func noteQueued(name: String, bytes: Int64) {
        upsert(name: name, bytes: bytes, state: .queued, detail: nil)
    }

    /// `didFinish` 回来了。`error == nil` ⇒ 已交给手机守护进程（`.delivered`），
    /// 非 nil ⇒ `.failed` 并把原因记下来 —— 这个原因在表上原本**完全看不到**，
    /// 用户只能看到"一直转圈"。
    func noteFinished(name: String, error: Error?) {
        if let error {
            // `URLError` 的 `localizedDescription` 是系统腔的英文，
            // 但它是唯一能区分"对方没应答"和"没连上"的东西，比一句
            // "传输失败"有用得多，留着。
            upsert(
                name: name,
                bytes: nil,
                state: .failed,
                detail: (error as NSError).localizedDescription
            )
        } else {
            upsert(name: name, bytes: nil, state: .delivered, detail: nil)
        }
    }

    /// 手机确认入库。
    func noteStored(name: String) {
        upsert(name: name, bytes: nil, state: .stored, detail: nil)
    }

    func clear() {
        guard !records.isEmpty else { return }
        records.removeAll()
        save()
    }

    // MARK: - 内部

    /// 有则改、无则加。**不改 `name` 之外的旧字段**（`bytes` 传 nil 就保留原值）：
    /// `didFinish` 回调里拿不到文件大小（文件可能已经被删了），
    /// 若在那里写成 0，列表上就会出现"0 KB 已入库"这种假信息。
    private func upsert(name: String, bytes: Int64?, state: WatchTransferRecord.State, detail: String?) {
        if let index = records.firstIndex(where: { $0.name == name }) {
            records[index].state = state
            records[index].updatedAt = Date()
            records[index].detail = detail
            if let bytes { records[index].bytes = bytes }
        } else {
            records.append(WatchTransferRecord(
                name: name,
                bytes: bytes ?? 0,
                updatedAt: Date(),
                state: state,
                detail: detail
            ))
        }
        // 新的排前面。同一时刻（比如"排队 → 立刻送出"）靠 `rank` 稳定排序。
        records.sort { ($0.updatedAt, $0.state.rank) > ($1.updatedAt, $1.state.rank) }
        if records.count > Self.maxEntries {
            records.removeLast(records.count - Self.maxEntries)
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        records = payload.records.sorted {
            ($0.updatedAt, $0.state.rank) > ($1.updatedAt, $1.state.rank)
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(Payload(records: records))
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("transfer log save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
