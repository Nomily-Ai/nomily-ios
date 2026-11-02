import Foundation
import os.log

/// ★ 2026-10-29（饭耳移植 · 规格 §2.3 存储分层 · 上传编排）
///
/// Decides *what* goes to the WebDAV destination and in which layout:
///
/// ```text
/// /<basePath>/<yyyy-MM-dd> <主题>/<clip>.txt           ← always (text syncs by default)
/// /<basePath>/<yyyy-MM-dd> <主题>/<clip>.asr.json      ← always (timing/speaker metadata)
/// /<basePath>/<yyyy-MM-dd> <主题>/<clip>.summary.md    ← when present (网页端可直接读)
/// /<basePath>/<yyyy-MM-dd> <主题>/<clip>.chapters.json ← when present
/// /<basePath>/<yyyy-MM-dd> <主题>/<clip>.<ext>         ← only when 同步录音 is on
/// ```
///
/// ★ 2026-11-02（用户："上传…还需要根据时间跟当前的录音转写的主题进行设置
/// 作为文件夹名称"）：不再按 transcripts/、audio/ 平铺——机器名文件在网盘里
/// 根本认不出哪条是哪条（用户实测 142 个文件躺在服务器上却"没看到上传"）。
/// 每条录音一个文件夹：日期取文件名时间戳（取不到用 mtime），主题取
/// `<base>.title`（没有就用录音文件名）。
///
/// Text-first is the spec's stance ("转写文本默认同步，音频可选"): a clip's
/// readable value is its transcript; audio is the bulky half. Hooks:
///   · `TranscriptionService.onTranscribed` → `sync(clip:)` per new transcript;
///   · "立即同步" button → `syncAll()` sweeps every clip that has a transcript.
///
/// No upload queue of our own: re-running the sweep is the recovery path, and
/// each pass is idempotent (PUT overwrites).
@MainActor
final class WebDAVSyncService: ObservableObject {

    static let shared = WebDAVSyncService()
    private init() {}

    @Published var isRunning = false
    /// Last pass's outcome for the settings page ("已同步 12 · 失败 1：HTTP 413").
    @Published var lastReport: String?
    /// Last per-clip sync result for the post-transcription path (banner-less;
    /// surfaced only in the settings page log).
    @Published private(set) var uploadedCount = 0

    struct SyncOutcome {
        var uploaded = 0
        var skipped = 0
        var failures: [String] = []
    }

    /// Sync one clip's artefacts (called after transcription).
    func sync(clipName: String, config: AppConfig) async {
        guard let client = Self.client(from: config) else { return }
        _ = try? await syncClip(clipName, client: client, syncAudio: config.webdav?.syncAudio ?? false)
    }

    /// Sweep every clip in the library that has a transcript.
    func syncAll(config: AppConfig) async {
        guard let cfg = config.webdav, cfg.isConfigured,
              let client = Self.client(from: config) else {
            lastReport = L10n.WebDAV.notConfigured
            return
        }
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        let audioExtensions: Set<String> = ["m4a", "aac", "wav", "caf", "mp3", "aif", "aiff", "flac", "opus"]
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }

        // Only clips with a transcript — text is the thing being backed up.
        let clips = names
            .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .filter { name in
                let base = (name as NSString).deletingPathExtension
                return fm.fileExists(atPath: dir.appendingPathComponent("\(base).txt").path)
            }
            .sorted()

        var outcome = SyncOutcome()
        for clip in clips {
            do {
                if try await syncClip(clip, client: client, syncAudio: cfg.syncAudio) {
                    outcome.uploaded += 1
                } else {
                    outcome.skipped += 1
                }
            } catch {
                outcome.failures.append("\(clip): \(error.localizedDescription)")
            }
        }
        uploadedCount = outcome.uploaded
        lastReport = Self.report(outcome)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    // MARK: - Per-clip

    /// Uploads the transcript pair (and audio when asked). Returns true if
    /// anything was uploaded, false when the server already has it (HEAD 200)
    /// — keeps repeated sweeps cheap.
    private func syncClip(_ clipName: String, client: WebDAVClient, syncAudio: Bool) async throws -> Bool {
        var uploaded = false
        let urls = StorageLocations.transcriptURLs(for: clipName)
        let base = (clipName as NSString).deletingPathExtension
        let dir = StorageLocations.decryptedDir
        let folder = remoteFolder(base: base, in: dir)

        // ★ 2026-11-02：每条录音一个「日期 主题」文件夹。总结/章节有就顺带传——
        //   在网盘网页端不用下载就能读，这才叫备份。
        var artefacts: [(local: URL, remote: String)] = [
            (urls.txt, "\(base).txt"),
            (urls.json, "\(base).asr.json"),
        ]
        let summary = dir.appendingPathComponent("\(base).summary.md")
        if FileManager.default.fileExists(atPath: summary.path) {
            artefacts.append((summary, "\(base).summary.md"))
        }
        let chapters = dir.appendingPathComponent("\(base).chapters.json")
        if FileManager.default.fileExists(atPath: chapters.path) {
            artefacts.append((chapters, "\(base).chapters.json"))
        }
        for (local, remote) in artefacts {
            guard FileManager.default.fileExists(atPath: local.path) else { continue }
            if try await needsUpload(local: local, remote: "\(folder)/\(remote)", client: client) {
                try await client.upload(fileAt: local, to: "\(client.basePath)/\(folder)/\(remote)")
                uploaded = true
            }
        }

        if syncAudio {
            let remote = "\(folder)/\(clipName)"
            let local = StorageLocations.decryptedDir.appendingPathComponent(clipName)
            if FileManager.default.fileExists(atPath: local.path),
               try await needsUpload(local: local, remote: remote, client: client) {
                // ★ 2026-10-29 (饭耳移植 · 规格 §2.3): audio goes through the
                // background session — a 30MB clip outlives any foreground
                // grace period, and the daemon keeps uploading after the app
                // is suspended. Directories first, in the foreground.
                try await client.ensureDirectories(forPath: "\(client.basePath)/\(folder)")
                WebDAVBackgroundUploader.shared.enqueue(fileAt: local, to: "\(client.basePath)/\(remote)", client: client)
                uploaded = true
            }
        }
        return uploaded
    }

    // MARK: - 每录音文件夹名（★ 2026-11-02）

    /// `20261014161945` 这样的录音文件名时间戳 → `2026-10-14`。
    private static let clipStampParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    private static let folderDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 服务器上的每录音文件夹名：`2026-10-14 产品评审会`。
    ///
    /// 日期：录音文件名前 14 位是 `yyyyMMddHHmmss` 时间戳就用它；不是这个形状
    /// （导入的音频等）退回转写文件的 mtime。主题：`<base>.title`——转写完成时
    /// 生成的那份；没有就用录音文件名兜底。服务器路径不能有 `/` 等捣乱字符，
    /// 统一清洗；超长截到 60 字符（中文标题足够，且不吃 URL 长度限制）。
    private func remoteFolder(base: String, in dir: URL) -> String {
        let fm = FileManager.default

        var datePart = ""
        let stamp = base.prefix(14)
        if stamp.count == 14, stamp.allSatisfy(\.isNumber),
           let recorded = Self.clipStampParser.date(from: String(stamp)) {
            datePart = Self.folderDayFormatter.string(from: recorded)
        } else if let attr = try? fm.attributesOfItem(atPath: dir.appendingPathComponent("\(base).txt").path),
                  let mtime = attr[.modificationDate] as? Date {
            datePart = Self.folderDayFormatter.string(from: mtime)
        } else {
            datePart = Self.folderDayFormatter.string(from: Date())
        }

        var title = ""
        if let data = fm.contents(atPath: dir.appendingPathComponent("\(base).title").path),
           let raw = String(data: data, encoding: .utf8) {
            title = Self.sanitizeFolderTitle(raw)
        }
        if title.isEmpty { title = Self.sanitizeFolderTitle(base) }
        if title.isEmpty { title = "未命名" }

        let folder = "\(datePart) \(title)"
        return Self.sanitizeFolderTitle(folder)
    }

    /// 文件夹名清洗：服务器路径的非法字符换空格、压平连续空格、去首尾、限长。
    static func sanitizeFolderTitle(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var cleaned = raw.components(separatedBy: illegal).joined(separator: " ")
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 60 {
            cleaned = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }

    /// HEAD check: 200 = server already has it, anything else = upload.
    private func needsUpload(local: URL, remote: String, client: WebDAVClient) async throws -> Bool {
        guard let req = client.request(publicMethod: "HEAD", path: "\(client.basePath)/\(remote)") else {
            return true
        }
        // `try?` on a throwing tuple-returning call yields an optional tuple —
        // unwrap via `result?.1`; any failure (network, TLS, non-2xx) means upload.
        // ★ 2026-10-30：走 client.session —— 「允许自签」的配置这里是放行版会话。
        let result = try? await client.session.data(for: req)
        let status = (result?.1 as? HTTPURLResponse)?.statusCode ?? 0
        return status != 200
    }

    // MARK: - Helpers

    /// Build a client from config + the Keychain-held password.
    static func client(from config: AppConfig) -> WebDAVClient? {
        guard let cfg = config.webdav, cfg.isConfigured else { return nil }
        return WebDAVClient(
            host: cfg.host,
            port: cfg.port,
            useHTTPS: cfg.useHTTPS,
            username: cfg.username,
            password: cfg.password ?? "",
            basePath: cfg.basePath,
            allowSelfSigned: cfg.allowSelfSigned
        )
    }

    private static func report(_ outcome: SyncOutcome) -> String {
        if outcome.failures.isEmpty {
            return L10n.WebDAV.reportAll(outcome.uploaded, outcome.skipped)
        }
        let first = outcome.failures.first ?? ""
        return L10n.WebDAV.reportFailures(outcome.uploaded, outcome.skipped, outcome.failures.count, first)
    }
}

extension WebDAVClient {
    /// Exposed for the sync service's HEAD probe (the base `request` is private).
    func request(publicMethod method: String, path: String) -> URLRequest? {
        guard let url = url(forPath: path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        return req
    }
}
