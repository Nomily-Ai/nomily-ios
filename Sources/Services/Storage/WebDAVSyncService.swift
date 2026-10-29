import Foundation
import os.log

/// ★ 2026-10-29（饭耳移植 · 规格 §2.3 存储分层 · 上传编排）
///
/// Decides *what* goes to the WebDAV destination and in which layout:
///
/// ```text
/// /<basePath>/transcripts/<clip>.txt        ← always (text syncs by default)
/// /<basePath>/transcripts/<clip>.asr.json   ← always (timing/speaker metadata)
/// /<basePath>/audio/<clip>.<ext>            ← only when 同步录音 is on
/// ```
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

        for (local, remote) in [(urls.txt, "transcripts/\(base).txt"),
                                (urls.json, "transcripts/\(base).asr.json")] {
            guard FileManager.default.fileExists(atPath: local.path) else { continue }
            if try await needsUpload(local: local, remote: remote, client: client) {
                try await client.upload(fileAt: local, to: "\(client.basePath)/\(remote)")
                uploaded = true
            }
        }

        if syncAudio {
            let remote = "audio/\(clipName)"
            let local = StorageLocations.decryptedDir.appendingPathComponent(clipName)
            if FileManager.default.fileExists(atPath: local.path),
               try await needsUpload(local: local, remote: remote, client: client) {
                // ★ 2026-10-29 (饭耳移植 · 规格 §2.3): audio goes through the
                // background session — a 30MB clip outlives any foreground
                // grace period, and the daemon keeps uploading after the app
                // is suspended. Directories first, in the foreground.
                try await client.ensureDirectories(forPath: "\(client.basePath)/audio")
                WebDAVBackgroundUploader.shared.enqueue(fileAt: local, to: "\(client.basePath)/\(remote)", client: client)
                uploaded = true
            }
        }
        return uploaded
    }

    /// HEAD check: 200 = server already has it, anything else = upload.
    private func needsUpload(local: URL, remote: String, client: WebDAVClient) async throws -> Bool {
        guard let req = client.request(publicMethod: "HEAD", path: "\(client.basePath)/\(remote)") else {
            return true
        }
        // `try?` on a throwing tuple-returning call yields an optional tuple —
        // unwrap via `result?.1`; any failure (network, TLS, non-2xx) means upload.
        let result = try? await URLSession.shared.data(for: req)
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
            basePath: cfg.basePath
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
        let credential = Data("\(username):\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        return req
    }
}
