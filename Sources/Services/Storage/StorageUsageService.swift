import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "storage-usage")

/// ★ 2026-10-30（用户："录音文件大小在本地占用多少，nas 占用多少，iCloud
/// 占用多少大小需要显示出来"）
///
/// 三处占用全部**实测**，不靠估算：
///   · 本地 —— 递归统计 `audio_clips/`（加密原件 + 解密副本 + 转写文本）；
///   · NAS —— 对 WebDAV 服务器发 PROPFIND，按服务器回报的字节数累加
///     （`transcripts/` + `audio/`；服务器不配合时给出失败原因）；
///   · iCloud / 文件夹 —— 用已保存的安全作用域书签进到所选文件夹，
///     统计 `transcripts/` + `audio/` 的实际磁盘占用。
@MainActor
final class StorageUsageService: ObservableObject {

    static let shared = StorageUsageService()
    private init() {}

    struct Usage: Equatable {
        var bytes: Int64
        var files: Int
        /// 拿不到时的原因（"服务器不支持列目录"之类）；nil = 成功。
        var failure: String?
    }

    /// ★ 2026-10-30（用户："设备与资料库，显示统计那个设备记录时长，还有手表的，
    /// 按照储存统计方式"）：按**来源**切一块的统计。
    ///
    /// 数据全部来自本机实盘：解密目录里每个录音文件的实际字节数 + 录音列表
    /// 同一个时长缓存（`.durations.json`，按 size+mtime 命中，不重新探测）。
    /// 来源判定用 downloads 清单里那条记录的 `transport`：
    ///   · `ble` / `wifi` → 录音豆（按设备别名分组）
    ///   · `watch` → Apple Watch
    ///   · 其余（`import` / `stream` / 无记录）→ 导入与实时
    struct SourceStats: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable {
            case device, watch, imported
        }
        var kind: Kind
        /// 卡片标题：设备别名 / "Apple Watch" / "导入与实时"。
        var label: String
        var bytes: Int64
        /// 录音条数（音频文件数，不含转写文本等附属文件）。
        var files: Int
        /// 累计录音时长（秒）。缓存里没有时长的文件按 0 计。
        var seconds: Double
        var lastRecording: Date?

        var id: String { "\(kind.rawValue)#\(label)" }
    }

    @Published var isLoading = false
    @Published var local = Usage(bytes: 0, files: 0, failure: nil)
    @Published var webdav = Usage(bytes: 0, files: 0, failure: nil)
    @Published var folder = Usage(bytes: 0, files: 0, failure: nil)
    /// ★ 2026-10-30：设备与资料库的来源分布（录音豆 / 手表 / 导入）。
    @Published var sources: [SourceStats] = []
    /// 目的地是否各自配置着（未配置时页面显示"未配置"而不是 0）。
    @Published var webdavConfigured = false
    @Published var folderConfigured = false

    func refresh(config: AppConfig) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // ── 本地 ──────────────────────────────────────────────
        let localSize = Self.directorySize(StorageLocations.audioDir)
        local = Usage(bytes: localSize.bytes, files: localSize.files, failure: nil)

        // ── 来源分布（设备 / 手表 / 导入）─────────────────────
        // 扫目录 + 读清单 + 读时长缓存，都是磁盘 IO，放后台。
        sources = await Task.detached(priority: .utility) { Self.sourceBreakdown() }.value

        // ── WebDAV（远端 PROPFIND）────────────────────────────
        webdavConfigured = config.webdav?.isConfigured == true
        if let client = WebDAVSyncService.client(from: config) {
            webdav = await Self.webdavUsage(client: client)
        } else {
            webdav = Usage(bytes: 0, files: 0, failure: "not_configured")
        }

        // ── 文件夹 / iCloud（书签实测）────────────────────────
        folderConfigured = FolderExportService.shared.hasFolder
        folder = FolderExportService.shared.usage()
    }

    // MARK: - Local

    static func directorySize(_ dir: URL) -> (bytes: Int64, files: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else { return (0, 0) }
        var bytes: Int64 = 0
        var files = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            bytes += Int64(size)
            files += 1
        }
        return (bytes, files)
    }

    // MARK: - Source breakdown (★ 2026-10-30)

    /// 录音列表那份时长缓存（`.durations.json`）的镜像结构。
    /// 字段与 `LibraryView` 的 `DurationEntry` 一一对应——那边决定缓存是否仍然有效
    /// （size + mtime），这里只读，不写、不探测。
    private struct DurationCacheEntry: Codable {
        let size: Int64
        let modified: Date
        let duration: Double?
    }

    /// 下载清单里我们关心的那几个字段（`.manifest.json` → `downloaded`）。
    private struct ManifestEntry: Codable {
        var transport: String?
        var localName: String?
        var deviceName: String?
        var deviceSerial: String?

        enum CodingKeys: String, CodingKey {
            case transport
            case localName = "local_name"
            case deviceName = "device_name"
            case deviceSerial = "device_serial"
        }
    }

    private struct Manifest: Codable {
        var downloaded: [String: ManifestEntry]
    }

    /// 扫解密目录，按来源归并字节数 / 条数 / 时长。纯 IO，调用方放后台。
    nonisolated static func sourceBreakdown() -> [SourceStats] {
        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }

        let durations = loadDurationCache()
        let manifest = loadManifest()

        // 清单的 key 形如 `serial::name`，值里带 `local_name`；统一按本地文件名索引，
        // 这样目录里扫到的文件能直接对上"它是谁录的"。
        var byLocalName: [String: ManifestEntry] = [:]
        for (key, entry) in manifest {
            let local = entry.localName ?? key.components(separatedBy: "::").last ?? key
            byLocalName[local] = entry
        }

        var acc: [String: SourceStats] = [:]
        let audioExts = AudioImporter.acceptedExtensions

        for name in names where audioExts.contains((name as NSString).pathExtension.lowercased()) {
            let url = dir.appendingPathComponent(name)
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(attrs?.fileSize ?? 0)
            let entry = byLocalName[name]

            let kind: SourceStats.Kind
            let label: String
            switch entry?.transport ?? "" {
            case "watch":
                kind = .watch
                label = "Apple Watch"
            case "ble", "wifi":
                kind = .device
                // 多台豆子分别成一卡；没别名就留一个通用名。
                label = (entry?.deviceName).flatMap { $0.isEmpty ? nil : $0 } ?? "Nomily"
            default:
                kind = .imported
                label = "—"
            }

            let key = "\(kind.rawValue)#\(label)"
            var stats = acc[key] ?? SourceStats(
                kind: kind, label: label, bytes: 0, files: 0, seconds: 0, lastRecording: nil)
            stats.bytes += size
            stats.files += 1
            stats.seconds += durations[name]?.duration ?? 0
            if let date = RecordingName.date(from: name) {
                if let last = stats.lastRecording {
                    if date > last { stats.lastRecording = date }
                } else {
                    stats.lastRecording = date
                }
            }
            acc[key] = stats
        }

        // 手表排最后、设备按字节倒序、导入收尾——和"谁录的东西更占地方"的直觉一致。
        return acc.values
            .filter { $0.files > 0 }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    if lhs.kind == .watch { return false }
                    if rhs.kind == .watch { return true }
                    if lhs.kind == .imported { return false }
                    if rhs.kind == .imported { return true }
                }
                return lhs.bytes > rhs.bytes
            }
    }

    nonisolated private static func loadDurationCache() -> [String: DurationCacheEntry] {
        let url = StorageLocations.audioDir.appendingPathComponent(".durations.json")
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: DurationCacheEntry].self, from: data) else {
            return [:]
        }
        return map
    }

    nonisolated private static func loadManifest() -> [String: ManifestEntry] {
        let url = StorageLocations.audioDir.appendingPathComponent(".manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return [:]
        }
        return manifest.downloaded
    }

    // MARK: - WebDAV

    /// PROPFIND 两个子目录（transcripts/、audio/），把服务器回报的
    /// `getcontentlength` 累加。目录不存在（404）当作 0 —— 还没传过东西。
    private static func webdavUsage(client: WebDAVClient) async -> Usage {
        let propfind = #"<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getcontentlength/></d:prop></d:propfind>"#
        var total: Int64 = 0
        var count = 0
        for sub in ["transcripts", "audio"] {
            guard var req = client.request(publicMethod: "PROPFIND", path: "\(client.basePath)/\(sub)") else {
                return Usage(bytes: 0, files: 0, failure: "bad_request")
            }
            req.httpBody = Data(propfind.utf8)
            req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            req.setValue("1", forHTTPHeaderField: "Depth")
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 404 { continue } // 子目录还没创建 = 还没传过
                guard (200..<300).contains(status) else {
                    return Usage(bytes: 0, files: 0, failure: "http_\(status)")
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                let ns = body as NSString
                let full = NSRange(location: 0, length: ns.length)
                for match in Self.lengthRegex.matches(in: body, range: full) {
                    let range = match.range(at: 1)
                    guard range.location != NSNotFound, range.location + range.length <= ns.length,
                          let n = Int64(ns.substring(with: range)) else { continue }
                    total += n
                    count += 1
                }
            } catch {
                log.warning("PROPFIND \(sub, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return Usage(bytes: 0, files: 0, failure: error.localizedDescription)
            }
        }
        return Usage(bytes: total, files: count, failure: nil)
    }

    private static let lengthRegex = try! NSRegularExpression(
        pattern: #"getcontentlength[^>]*>\s*(\d+)"#,
        options: [.caseInsensitive]
    )
}

/// 文件夹/iCloud 目的地的占用统计——挂在 FolderExportService 上是因为
/// 书签解析 + 作用域访问的规则都住在那里。
extension FolderExportService {

    /// 统计所选文件夹里 transcripts/ + audio/ 的实际占用。没选过文件夹
    /// 返回 not_configured；书签失效返回解不开的原因。
    func usage() -> StorageUsageService.Usage {
        guard let folder = resolve() else {
            return StorageUsageService.Usage(bytes: 0, files: 0, failure: "not_configured")
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        var bytes: Int64 = 0
        var files = 0
        for sub in ["transcripts", "audio"] {
            let size = StorageUsageService.directorySize(
                folder.appendingPathComponent(sub, isDirectory: true))
            bytes += size.bytes
            files += size.files
        }
        return StorageUsageService.Usage(bytes: bytes, files: files, failure: nil)
    }
}
