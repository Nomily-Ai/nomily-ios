import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "folder-export")

/// ★ 2026-10-29（饭耳移植 · 规格 §2.3 保存位置 · 文件 App 路线）
///
/// The second destination alongside WebDAV: the user picks **any** folder via
/// the document picker (iCloud Drive, "我的 iPhone", or a provider app's
/// container — the spec names Obsidian vaults explicitly) and transcripts —
/// plus optionally audio — are copied there.
///
/// Scope mechanics (the part that bites if done wrong):
///   · The picker URL is security-scoped; we persist a **bookmark** in
///     UserDefaults and `startAccessingSecurityScopedResource` around every
///     export pass, stopping access when it ends. Holding access forever is
///     not how the API is meant to be used and iOS revokes it anyway.
///   · Idempotent like the WebDAV sweep: an identical-sized destination file
///     is skipped, so re-running is cheap and safe.
@MainActor
final class FolderExportService: ObservableObject {

    static let shared = FolderExportService()

    static let bookmarkKey = "export_folder_bookmark"
    /// ★ 2026-10-30：自动备份开关（转写完成即写入所选文件夹）。
    static let autoKey = "export_folder_auto"
    /// ★ 2026-10-30：自动导出是否连录音一起。把页面上的「也导出录音」持久化
    /// 到服务里——自动路径没有 UI 在场，得自己读这份状态。
    static let audioKey = "export_folder_sync_audio"
    /// ★ 2026-11-09（用户："可以选择上传哪些"）：文件夹目的地要写哪些产物。
    /// 与 autoEnabled/syncAudio 同一套 UserDefaults 持久化模式。
    static let contentKey = "export_folder_upload_content"

    @Published var isRunning = false
    @Published var lastReport: String?
    /// ★ 2026-11-02（用户："展示占用内存"）：所选文件夹的占用统计行
    /// （递归文件数 + 总字节，异步算，iCloud 目录可能有占位文件）。
    @Published var usageText: String?
    /// ★ 2026-11-02（用户："导出到文件夹应该是 iCloud 的默认路径方便自动云备份"）：
    /// 打开后每次转写完成自动把这条的文本（+可选录音）写进所选文件夹。
    /// 目标是 iCloud 云盘里的文件夹时，这就是"自动上传 iCloud"。
    @Published var autoEnabled: Bool {
        didSet { UserDefaults.standard.set(autoEnabled, forKey: Self.autoKey) }
    }
    /// 自动导出是否带录音（视图的「也导出录音」开关直接绑这份持久化状态）。
    @Published var syncAudio: Bool {
        didSet { UserDefaults.standard.set(syncAudio, forKey: Self.audioKey) }
    }
    /// ★ 2026-11-09：要写哪些产物（转录/摘要/待办/导图/章节/转写数据/资料包）。
    @Published var uploadContent: UploadContent {
        didSet {
            if let data = try? JSONEncoder().encode(uploadContent) {
                UserDefaults.standard.set(data, forKey: Self.contentKey)
            }
        }
    }

    private init() {
        autoEnabled = UserDefaults.standard.bool(forKey: Self.autoKey)
        syncAudio = UserDefaults.standard.bool(forKey: Self.audioKey)
        if let data = UserDefaults.standard.data(forKey: Self.contentKey),
           let decoded = try? JSONDecoder().decode(UploadContent.self, from: data) {
            uploadContent = decoded
        } else {
            uploadContent = UploadContent()
        }
    }

    /// True when the user picked a folder before (bookmark resolves).
    var hasFolder: Bool { bookmarkData != nil }

    /// Display name of the chosen folder, for the settings row.
    var folderName: String? {
        guard let url = resolve() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return url.lastPathComponent
    }

    private var bookmarkData: Data? {
        UserDefaults.standard.data(forKey: Self.bookmarkKey)
    }

    // MARK: - Bookmark lifecycle

    /// Called right after the document picker returns — the URL is valid only
    /// within this access window, so convert it to a bookmark immediately.
    func store(from url: URL) {
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            // ⚠️ `.withSecurityScope` is macOS-only — on iOS a plain bookmark
            // (options: []) is what a picked folder takes; the scope is opened
            // with startAccessingSecurityScopedResource at use time.
            let data = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            lastReport = nil
            log.notice("export folder stored: \(url.lastPathComponent, privacy: .public)")
        } catch {
            lastReport = L10n.FolderExport.bookmarkFailed
            log.error("bookmark failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        usageText = nil
        lastReport = nil
    }

    // MARK: - Usage（★ 2026-11-02：占用统计）

    /// 递归统计所选文件夹的「文件数 + 总字节」。用 enumerator + 预取 key，
    /// 只碰元数据；iCloud 目录里的占位文件读的是本地缓存条目，不触发下载。
    /// 后台线程算完回主线程（目录可能很大）。
    func refreshUsage() {
        guard let folder = resolve() else {
            usageText = nil
            return
        }
        let url = folder
        Task.detached {
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                await MainActor.run { self.usageText = nil }
                return
            }
            var files = 0
            var bytes: Int64 = 0
            for case let item as URL in enumerator {
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey])
                guard values?.isRegularFile == true else { continue }
                files += 1
                bytes += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
            }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let text = files == 0
                ? L10n.FolderExport.usageEmpty
                : String(format: L10n.FolderExport.usageFormat, formatter.string(fromByteCount: bytes), files)
            await MainActor.run { self.usageText = text }
        }
    }

    /// Resolve + start access. Callers MUST call `stopAccessingSecurityScopedResource`
    /// on the returned URL when done (see `exportAll`). Internal（非 private）：
    /// 占用统计（StorageUsageService 里的扩展）也要走同一套书签解析。
    func resolve() -> URL? {
        guard let data = bookmarkData else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url.startAccessingSecurityScopedResource() ? url : url
    }

    // MARK: - Export

    private enum CopyResult {
        case copied, skipped, failed(String)
    }

    /// Idempotent copy: same-size destination file is skipped, so repeated
    /// passes (manual sweep or per-clip auto) are cheap and safe.
    /// ★ 2026-11-09：`remoteName` 覆盖目标文件名（每录音文件夹里用给人看的
    /// 名字，如 `转录全文.txt`——本地文件叫 `20261014161945.txt`）。
    private func copyItem(
        _ local: URL, as remoteName: String? = nil, into subdirectory: String,
        folder: URL, fm: FileManager, failures: inout [String]
    ) -> CopyResult {
        let destDir = folder.appendingPathComponent(subdirectory, isDirectory: true)
        let dest = destDir.appendingPathComponent(remoteName ?? local.lastPathComponent)
        if let existingSize = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int,
           let localSize = (try? fm.attributesOfItem(atPath: local.path))?[.size] as? Int,
           existingSize == localSize {
            return .skipped
        }
        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: local, to: dest)
            return .copied
        } catch {
            let text = "\(local.lastPathComponent): \(error.localizedDescription)"
            failures.append(text)
            return .failed(text)
        }
    }

    /// ★ 2026-11-09：内存数据直接落成目标文件（摘要.md / 待办.md / 思维导图.png
    /// 是现拼的，本地没有对应文件可 copy）。同样按「同尺寸跳过」幂等。
    private func writeData(
        _ data: Data, as name: String, into subdirectory: String,
        folder: URL, fm: FileManager, failures: inout [String]
    ) -> CopyResult {
        let destDir = folder.appendingPathComponent(subdirectory, isDirectory: true)
        let dest = destDir.appendingPathComponent(name)
        if let existingSize = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int,
           existingSize == data.count {
            return .skipped
        }
        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            try data.write(to: dest, options: .atomic)
            return .copied
        } catch {
            let text = "\(name): \(error.localizedDescription)"
            failures.append(text)
            return .failed(text)
        }
    }

    /// ★ 2026-11-09（用户的目标布局截图：每条录音一个「日期 标题」文件夹，
    /// 里面躺 待办.md / 录音 / 思维导图.png / 摘要.md / 转写.txt）：文件夹 App
    /// 与 iCloud 的导出从 `transcripts/`、`audio/` 平铺机器名改为**每录音
    /// 文件夹**——文件夹名与文件名直接复用 WebDAV 的命名
    /// （`WebDAVSyncService.clipFolderName` + `L10n.WebDAV.remote*`），网盘、
    /// iCloud、本地文件夹三处同一批录音长得一模一样。
    ///
    /// ★ 2026-10-30：单条自动导出——转写完成钩子调用（见 AppEnvironment）。
    /// 没开自动备份或没选文件夹时是 no-op；异常只进日志，不打扰用户。
    func export(clipName: String) async {
        guard autoEnabled, let folder = resolve() else { return }
        defer { folder.stopAccessingSecurityScopedResource() }
        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        let base = (clipName as NSString).deletingPathExtension
        let urls = StorageLocations.transcriptURLs(for: clipName)
        guard fm.fileExists(atPath: urls.txt.path) else { return }
        var copied = 0, skipped = 0
        var failures: [String] = []
        await exportClipArtifacts(
            clipName: clipName, base: base, into: folder, fm: fm,
            copied: &copied, skipped: &skipped, failures: &failures
        )
        if let first = failures.first {
            log.error("auto export \(clipName, privacy: .public) failed: \(first, privacy: .public)")
        }
    }

    /// ★ 2026-11-09：手动全量导出。每条录音写进 `<文件夹>/<yyyy-MM-dd 标题>/`，
    /// 文件名给人看（摘要.md、待办.md、转录全文.txt…），与 WebDAV 布局一致。
    func exportAll() async {
        guard !isRunning else { return }
        guard let folder = resolve() else {
            lastReport = L10n.FolderExport.notPicked
            return
        }
        isRunning = true
        defer {
            isRunning = false
            folder.stopAccessingSecurityScopedResource()
        }

        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        let audioExtensions: Set<String> = ["m4a", "aac", "wav", "caf", "mp3", "aif", "aiff", "flac", "opus"]
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }

        let clips = names
            .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .filter { name in
                let base = (name as NSString).deletingPathExtension
                return fm.fileExists(atPath: dir.appendingPathComponent("\(base).txt").path)
            }
            .sorted()

        var copied = 0
        var skipped = 0
        var failures: [String] = []

        for clip in clips {
            let base = (clip as NSString).deletingPathExtension
            await exportClipArtifacts(
                clipName: clip, base: base, into: folder, fm: fm,
                copied: &copied, skipped: &skipped, failures: &failures
            )
        }

        lastReport = failures.isEmpty
            ? L10n.FolderExport.reportAll(copied, skipped)
            : L10n.FolderExport.reportFailures(copied, skipped, failures.count, failures[0])
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    // MARK: - 每录音文件夹（★ 2026-11-09）

    /// 一条录音的全部产物 → `<文件夹>/<clipFolderName>/`。自动导出与全量
    /// 导出走同一个函数，保证两条路径写出来的东西完全一致。
    /// （async：录音转 m4a 是异步转换。）
    private func exportClipArtifacts(
        clipName: String, base: String, into folder: URL, fm: FileManager,
        copied: inout Int, skipped: inout Int, failures: inout [String]
    ) async {
        let dir = StorageLocations.decryptedDir
        let subdirectory = WebDAVSyncService.clipFolderName(base: base, in: dir)
        let urls = StorageLocations.transcriptURLs(for: clipName)

        // 文本三件套：转写 txt / 转写数据 json / 章节 json（有就带）。
        // ★ 2026-11-09：每类产物都听 uploadContent 开关的。
        if uploadContent.transcript {
            count(copyItem(urls.txt, as: L10n.WebDAV.remoteTranscript, into: subdirectory,
                           folder: folder, fm: fm, failures: &failures), &copied, &skipped)
        }
        if uploadContent.asrJSON, fm.fileExists(atPath: urls.json.path) {
            count(copyItem(urls.json, as: L10n.WebDAV.remoteASR, into: subdirectory,
                           folder: folder, fm: fm, failures: &failures), &copied, &skipped)
        }
        let chapters = dir.appendingPathComponent("\(base).chapters.json")
        if uploadContent.chapters, fm.fileExists(atPath: chapters.path) {
            count(copyItem(chapters, as: L10n.WebDAV.remoteChapters, into: subdirectory,
                           folder: folder, fm: fm, failures: &failures), &copied, &skipped)
        }

        // 摘要.md：与网盘上那份同源（readableNote 的 markdown）。
        if uploadContent.summary, let note = WebDAVSyncService.readableNote(base: base, in: dir) {
            count(writeData(Data(note.markdown.utf8), as: L10n.WebDAV.remoteNote, into: subdirectory,
                            folder: folder, fm: fm, failures: &failures), &copied, &skipped)
        }

        // 待办.md：与网盘/分享包同源（ShareBundle.todoMarkdown）。
        if uploadContent.todos,
           let todos = ShareBundle.todoMarkdown(
               base: base, title: WebDAVSyncService.readableTitle(base: base, in: dir), in: dir
           ) {
            count(writeData(Data(todos.utf8), as: L10n.WebDAV.remoteTodos, into: subdirectory,
                            folder: folder, fm: fm, failures: &failures), &copied, &skipped)
        }

        // 思维导图.png：同一条渲染管线（有摘要有大纲才有图）。
        if uploadContent.mindMap,
           let note = WebDAVSyncService.readableNote(base: base, in: dir),
           let png = MindMapSnapshot.pngData(markdown: noteBody(note), title: note.title),
           !png.isEmpty {
            count(writeData(png, as: L10n.WebDAV.remoteMindMap, into: subdirectory,
                            folder: folder, fm: fm, failures: &failures), &copied, &skipped)
        }

        // 录音：与 WebDAV 同法转成可播放的 m4a（网盘/文件 App 都能直接点开）；
        // 转换结果留在 decrypted/ 里复用，第二次导出不再转。
        if syncAudio {
            let local = dir.appendingPathComponent(clipName)
            let playable = dir.appendingPathComponent("\(base).m4a")
            var audioLocal = local
            if !fm.fileExists(atPath: playable.path),
               let converted = try? await AudioExporter.exportAsM4A(source: local, suggestedName: base) {
                try? fm.removeItem(at: playable)
                try? fm.moveItem(at: converted, to: playable)
            }
            if fm.fileExists(atPath: playable.path) { audioLocal = playable }
            count(copyItem(audioLocal, as: audioLocal == playable ? L10n.WebDAV.remoteAudio : clipName,
                           into: subdirectory, folder: folder, fm: fm, failures: &failures),
                  &copied, &skipped)
        }
    }

    /// 摘要正文（readableNote 里去掉拼装好的 markdown 头——导图渲染只要大纲）。
    private func noteBody(_ note: NotePDFRenderer.Note) -> String {
        note.summaryMarkdown
    }

    private func count(_ result: CopyResult, _ copied: inout Int, _ skipped: inout Int) {
        switch result {
        case .copied: copied += 1
        case .skipped: skipped += 1
        case .failed: break
        }
    }
}
