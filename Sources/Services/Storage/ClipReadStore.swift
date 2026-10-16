import Foundation

/// 「这条录音我看过了吗」的唯一账本 —— 列表上那颗红点的全部依据。
///
/// ## 为什么不塞进 `Library` 的 manifest
/// manifest 记的是"这条已经从设备下过了"，那是**下载凭据**：清掉它是有意义
/// 的操作（清掉后同一条能重新下载）。而"已读"是**用户偏好**，清掉就是满屏
/// 红点。两者生命周期、被谁改、能不能丢，全都不一样 —— 混在一张表里，迟早
/// 有一次重构顺手把已读状态一起抹掉。
///
/// ## 为什么是单文件而不是每条一个 `.seen` 旁车
/// 1900 条就是 1900 个额外文件：每次打开详情写一次盘，`LibraryScanner` 的
/// 目录指纹（最新 mtime + 条目数）还跟着抖 —— 一抖就把知识库检索的正文缓存
/// 整块作废。整份 JSON 只有几 KB，读写都是一次 atomic 覆盖。
///
/// ## ★ "只标新到的"是怎么实现的
/// `origin` 是本功能**第一次运行**的时刻，写进去就不动了。到货时间早于
/// `origin` 的条目一律当已读 —— 于是不需要把当时已有的几千个名字搬进
/// `seen`，也不需要一次迁移扫描。代价是重装 App 会重置 `origin`，
/// 那一刻库里所有东西都"已读"（这恰恰是我们想要的方向：宁可漏标，
/// 不要满屏红点）。
@MainActor
final class ClipReadStore: ObservableObject {
    static let shared = ClipReadStore()

    /// 打开过的落盘名。**只装 `origin` 之后到货的那些** —— 老录音靠
    /// `origin` 判定，不占这里的位置。
    @Published private(set) var seen: Set<String> = []

    /// 本功能上线的那一刻。加载完成前用 `.distantFuture`：宁可先按
    /// "全都已读"渲染一帧，也不要先闪一屏红点。
    private var origin: Date = .distantFuture

    private let url: URL

    private struct Payload: Codable {
        var origin: Date
        var seen: [String]
    }

    private init() {
        url = StorageLocations.audioDir.appendingPathComponent(".seen.json")
        load()
    }

    /// 这条现在要不要挂红点。
    ///
    /// - Parameter arrivedAt: **到货时间**（`LibraryItem.modifiedAt`），
    ///   不是录音时间。判据是"新传进来的"，所以用落盘时刻；
    ///   设备 RTC 没对表时录音时间可能很离谱，拿它判会误标。
    func isUnread(name: String, arrivedAt: Date) -> Bool {
        guard arrivedAt >= origin else { return false }
        return !seen.contains(name)
    }

    /// 用户把这条打开过了（详情页出现即算，不要求停留多久）。
    func markSeen(name: String) {
        guard !seen.contains(name) else { return }
        seen.insert(name)
        save()
    }

    /// 一条被删掉时清掉它的已读记录。
    ///
    /// 不清也不会出错，但表会随着"删了又下"无限长；而且同名文件重新下载回来
    /// 会莫名其妙带着"已读"，用户就再也等不到那颗红点了。
    func forget(names: [String]) {
        let before = seen.count
        seen.subtract(names)
        if seen.count != before { save() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            // 没有文件 = 本功能第一次运行。此刻盘上的东西统统算老的。
            origin = Date()
            save()
            return
        }
        origin = payload.origin
        seen = Set(payload.seen)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Payload(origin: origin, seen: Array(seen)))
        else { return }
        try? FileManager.default.createDirectory(
            at: StorageLocations.audioDir, withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}
