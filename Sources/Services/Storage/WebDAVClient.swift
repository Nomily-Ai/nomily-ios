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
    /// ★ 2026-10-30（用户接极空间 Z4Pro）：信任服务器自签证书。默认 false，
    /// 由 `WebDAVConfig.allowSelfSigned` 驱动。
    var allowSelfSigned: Bool = false

    /// ★ 2026-10-30（极空间 401 排障第二轮）：归一化放在**网络层**，不是在表单里。
    /// 只要是发往服务器的账号/密码，就必须走同一条清洗——表单、Keychain 恢复、
    /// 自动同步三条路都进这个 init，谁也别想绕过。
    init(host: String,
         port: Int,
         useHTTPS: Bool,
         username: String,
         password: String,
         basePath: String,
         allowSelfSigned: Bool = false) {
        self.host = host.trimmingCharacters(in: .whitespaces)
        self.port = port
        self.useHTTPS = useHTTPS
        self.username = username.credentialNormalized
        self.password = password.credentialNormalized
        self.basePath = basePath
        self.allowSelfSigned = allowSelfSigned
    }

    /// 唯一一处拼 `Authorization: Basic`。两个调用方（探测 / 上传）共用，
    /// 免得再出现"探测能过、同步还是 401"这种两套实现各错各的。
    var authorizationHeader: String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    /// 进诊断日志的凭据形状——账号明文（本来就显示在界面上）、密码只报位数。
    /// 排障时"位数对不对"一眼就能看出有没有多带不可见字符，又不泄露密码本身。
    var credentialShape: String {
        "user=\(username) pwLen=\(password.count) ascii=\(password.allSatisfy(\.isASCII))"
    }

    // MARK: - Session

    /// 「允许自签」专用的会话：server-trust 质询一律放行。静态缓存一份，
    /// 不给每次 PUT 都新建 session（连接池也省了）。
    private static let trustAllSession: URLSession = {
        let delegate = TrustAllServerTrustDelegate()
        return URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    }()

    /// 所有请求统一走这个会话：开了自签信任就用放行版，否则系统默认。
    var session: URLSession {
        allowSelfSigned ? Self.trustAllSession : .shared
    }

    /// 只放行 server-trust 质询（HTTPS 证书），其余质询照默认处理。
    private final class TrustAllServerTrustDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }

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
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        TicNoteDiagLog.log("WEBDAV", "\(method) \(url.absoluteString) · \(credentialShape)")
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
            let (_, response) = try await session.data(for: req)
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
            (data, response) = try await session.upload(for: req, fromFile: localURL)
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
    ///
    /// ★ 2026-10-30（用户接极空间实测踩到的坑）：极空间对**不存在/不可写的路径**
    /// 也回 401，跟"密码错"一个样子——只看状态码会把"目录填错了"误报成
    /// "用户名或密码不对"。所以 401 时再探一次服务器根：根能通过认证 = 密码是对的，
    /// 是目录的问题，提示话术完全不同。
    func testConnection() async throws -> Int {
        guard let req = request(method: "PROPFIND", path: basePath, depth: "0") else {
            throw Failure(message: "bad path")
        }
        let startedAt = Date()
        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await session.data(for: req)
        } catch {
            throw Failure(message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // ★ 2026-10-30：失败一律带上实际请求的 URL 和状态码——远程排障时
        // "到底连到了哪、服务器回了什么"是第一手证据（截图直接可读）。
        let where_ = req.url?.absoluteString ?? "?"
        TicNoteDiagLog.log("WEBDAV", "probe \(where_) → HTTP \(status)")
        // 207 Multi-Status is WebDAV's happy answer; 200 is fine too.
        guard status == 207 || status == 200 else {
            if status == 401 {
                if await rootAuthorized() {
                    throw Failure(message: "\(L10n.WebDAV.pathDenied)（\(where_)）")
                }
                // ★ 2026-10-30：把**实际发出去的**账号和密码位数写进提示。服务器
                //   认的是一串字节，密码多带一个看不见的字符就是 401，而界面上
                //   什么都看不出来——位数是最快的一手证据（9 位 vs 10 位）。
                throw Failure(message: "401 用户名或密码不对（账号 \(username)，密码 \(password.count) 位）（\(where_)）")
            }
            if status == 404 {
                throw Failure(message: "\(L10n.WebDAV.pathMissing)（\(where_)）")
            }
            throw Failure(message: "HTTP \(status)（\(where_)）")
        }
        return Int(Date().timeIntervalSince(startedAt) * 1000)
    }

    /// 服务器根（`/`）能否通过认证——区分"密码错"与"路径不可访问"。
    private func rootAuthorized() async -> Bool {
        guard let req = request(method: "PROPFIND", path: "/", depth: "0") else { return false }
        guard let (_, resp) = try? await session.data(for: req) else { return false }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return status == 200 || status == 207
    }

    /// ★ 2026-10-30（极空间专属）：个人空间目录名是 `/sata<卷>-<账号>/`
    /// （实测形如 `sata11-<登录账号>`），用户根本猜不出来。扫一遍服务器根目录
    /// （Depth 1），找到包含账号名的那一项返回 `/sata11-…`。其他 NAS / 域名
    /// 服务器上不会命中，自然返回 nil，零副作用。
    func discoverPersonalSpace(username: String) async -> String? {
        guard !username.isEmpty,
              let req = request(method: "PROPFIND", path: "/", depth: "1") else { return nil }
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 207 else { return nil }
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        let account = NSRegularExpression.escapedPattern(for: username)
        guard let regex = try? NSRegularExpression(pattern: "/(sata\\d+-[^\n/<]*\(account)[^\n/<]*)/") else { return nil }
        let range = NSRange(body.startIndex..., in: body)
        guard let match = regex.firstMatch(in: body, range: range),
              let nameRange = Range(match.range(at: 1), in: body) else { return nil }
        return "/\(body[nameRange])"
    }
}
