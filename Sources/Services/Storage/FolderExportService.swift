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

    @Published var isRunning = false
    @Published var lastReport: String?
    /// ★ 2026-10-30（用户："增加自动上传到 iCloud 或者指定的服务器"）：
    /// 打开后每次转写完成自动把这条的文本（+可选录音）写进所选文件夹。
    /// 目标是 iCloud 云盘里的文件夹时，这就是"自动上传 iCloud"。
    @Published var autoEnabled: Bool {
        didSet { UserDefaults.standard.set(autoEnabled, forKey: Self.autoKey) }
    }
    /// 自动导出是否带录音（视图的「也导出录音」开关直接绑这份持久化状态）。
    @Published var syncAudio: Bool {
        didSet { UserDefaults.standard.set(syncAudio, forKey: Self.audioKey) }
    }

    private init() {
        autoEnabled = UserDefaults.standard.bool(forKey: Self.autoKey)
        syncAudio = UserDefaults.standard.bool(forKey: Self.audioKey)
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
        lastReport = nil
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
    private func copyItem(
        _ local: URL, into subdirectory: String,
        folder: URL, fm: FileManager, failures: inout [String]
    ) -> CopyResult {
        let destDir = folder.appendingPathComponent(subdirectory, isDirectory: true)
        let dest = destDir.appendingPathComponent(local.lastPathComponent)
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
        var failures: [String] = []
        copyItem(urls.txt, into: "transcripts", folder: folder, fm: fm, failures: &failures)
        if fm.fileExists(atPath: urls.json.path) {
            copyItem(urls.json, into: "transcripts", folder: folder, fm: fm, failures: &failures)
        }
        if syncAudio {
            let audio = dir.appendingPathComponent(clipName)
            if fm.fileExists(atPath: audio.path) {
                copyItem(audio, into: "audio", folder: folder, fm: fm, failures: &failures)
            }
        }
        if let first = failures.first {
            log.error("auto export \(clipName, privacy: .public) failed: \(first, privacy: .public)")
        }
    }

    /// Copy every transcript (and optionally audio) into `<folder>/transcripts`
    /// and `<folder>/audio`. Mirrors the WebDAV layout on purpose: the two
    /// destinations stay interchangeable.
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
            let urls = StorageLocations.transcriptURLs(for: clip)
            switch copyItem(urls.txt, into: "transcripts", folder: folder, fm: fm, failures: &failures) {
            case .copied: copied += 1
            case .skipped: skipped += 1
            case .failed: break
            }
            if fm.fileExists(atPath: urls.json.path) {
                switch copyItem(urls.json, into: "transcripts", folder: folder, fm: fm, failures: &failures) {
                case .copied: copied += 1
                case .skipped: skipped += 1
                case .failed: break
                }
            }
            if syncAudio {
                switch copyItem(dir.appendingPathComponent(clip), into: "audio", folder: folder, fm: fm, failures: &failures) {
                case .copied: copied += 1
                case .skipped: skipped += 1
                case .failed: break
                }
            }
        }

        lastReport = failures.isEmpty
            ? L10n.FolderExport.reportAll(copied, skipped)
            : L10n.FolderExport.reportFailures(copied, skipped, failures.count, failures[0])
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }
}
