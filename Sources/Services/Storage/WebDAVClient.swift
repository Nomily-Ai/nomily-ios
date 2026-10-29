import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "webdav")

/// ★ 2026-10-29（饭耳移植 · 规格 §2.3 存储分层 · WebDAV 目的地）
///
/// A minimal WebDAV client — just what backup needs: `PUT` a file,
/// `MKCOL` the directories along the way, `PROPFIND Depth: 0` to test the
/// server. Basic auth only (every NAS package the spec lists — 群晖/威联通/
/// 绿联/飞牛/极空间/Nextcloud/坚果云 — speaks it; that's the point of picking
/// WebDAV as the one protocol).
///
/// Uploads run on a plain `URLSession.shared` data task: the payloads are
/// small text transcripts plus (optionally) audio, and the spec's background
/// `URLSession` daemon path is a separate upgrade if users report big audio
/// being killed mid-upload. Synchronous simplicity first; queue persistence
/// comes free from "re-run the sync".
struct WebDAVClient {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let host: String
    let port: Int
    let useHTTPS: Bool
    let username: String
    let password: String
    /// Server-side directory everything lands under, e.g. `/nomily`.
    let basePath: String

    // MARK: - URL building

    /// Server root URL, percent-encoded per path component.
    var rootURL: URL? {
        var comps = URLComponents()
        comps.scheme = useHTTPS ? "https" : "http"
        comps.host = host
        comps.port = port
        return comps.url
    }

    /// Full URL for a remote path like `/nomily/transcripts/clip.txt`.
    /// Leading slashes are stripped entirely (the caller may pass `//a/b`
    /// when basePath is `/`); URLComponents keeps the host clean either way.
    func url(forPath path: String) -> URL? {
        guard let root = rootURL else { return nil }
        var trimmed = path
        while trimmed.hasPrefix("/") { trimmed.removeFirst() }
        guard !trimmed.isEmpty else { return root }
        return root.appendingPathComponent(trimmed)
    }

    private func request(method: String, path: String, depth: String? = nil) -> URLRequest? {
        guard let url = url(forPath: path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 60
        if let depth { req.setValue(depth, forHTTPHeaderField: "Depth") }
        let credential = Data("\(username):\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: - Operations

    /// `MKCOL` every missing directory component of `path` (e.g. `/nomily`,
    /// `/nomily/transcripts`). Servers return 405 when it already exists —
    /// treated as success.
    func ensureDirectories(forPath path: String) async throws {
        let parts = path.split(separator: "/").map(String.init)
        var current = ""
        for part in parts {
            current += "/\(part)"
            guard let req = request(method: "MKCOL", path: current) else {
                throw Failure(message: "bad path")
            }
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 201 created · 405 exists · 301/409 = parent weirdness, let the
            // next PUT surface a real error rather than guessing here.
            if status == 201 || status == 405 { continue }
            log.notice("MKCOL \(current, privacy: .public) → \(status)")
        }
    }

    /// Upload `localURL` to `remotePath`, creating directories as needed.
    func upload(fileAt localURL: URL, to remotePath: String) async throws {
        try await ensureDirectories(forPath: (remotePath as NSString).deletingLastPathComponent)
        guard let req = request(method: "PUT", path: remotePath) else {
            throw Failure(message: "bad path")
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.upload(for: req, fromFile: localURL)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            log.error("PUT \(remotePath, privacy: .public) → \(status): \(body, privacy: .public)")
            throw Failure(message: "HTTP \(status)")
        }
    }

    /// PROPFIND Depth:0 against the base path — the "can I talk to this
    /// server at all" probe. Returns elapsed milliseconds on success.
    func testConnection() async throws -> Int {
        guard let req = request(method: "PROPFIND", path: basePath, depth: "0") else {
            throw Failure(message: "bad path")
        }
        let startedAt = Date()
        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 207 Multi-Status is WebDAV's happy answer; 200 is fine too.
        guard status == 207 || status == 200 else {
            if status == 401 {
                throw Failure(message: "401 用户名或密码不对")
            }
            throw Failure(message: "HTTP \(status)")
        }
        return Int(Date().timeIntervalSince(startedAt) * 1000)
    }
}
