import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "plaud.cloud")

/// PLAUD consumer-account cloud sync — pulls **original audio** (Opus) from the
/// recordings the official app uploaded, so the user keeps using the official
/// PLAUD app untouched while Nomily re-transcribes with its own ASR/LLM keys.
///
/// ★ 2026-10-21, user's decision: dual-mode coexistence. This service is the
/// **cloud mode** (BLE-free, zero impact on the official app). The SDK takeover
/// mode is a later addition behind the same settings page.
///
/// ## Endpoint map (verified against Riffado's working sync code, AGPL — we
/// re-implemented, no code copied):
///   · `POST {api}/auth/otp-send-code` `{username}` → `data.token`
///     (region redirect: `status:-302` + `data.domains.api`, e.g. → api.plaud.cn; follow up to 3×)
///   · `POST {api}/auth/otp-login` `{code, token}` → `access_token`
///   · `GET /user/me` — account sanity check
///   · `GET /file/simple/web?skip&limit&is_trash&sort_by&is_desc` — recording list
///   · `GET /file/temp-url/{id}?is_opus=1` → presigned `temp_url_opus` (Opus) / `temp_url` (mp3)
///
/// ⚠️ Requests must carry a browser-like User-Agent or the edge rejects them.
/// ⚠️ Never request transcript/summary content here: Nomily's policy is
/// "audio in, our own keys transcribe" — the official AI output stays untouched.
@MainActor
final class PlaudCloudService: ObservableObject {
    static let shared = PlaudCloudService()

    struct CloudFile: Identifiable, Equatable {
        let id: String
        let name: String
        let size: Int64
        let editedAt: Date
    }

    enum PlaudError: LocalizedError {
        case badResponse(String)
        case notSignedIn
        case audioNotReady

        var errorDescription: String? {
            switch self {
            case .badResponse(let m): return m
            case .notSignedIn: return "Not signed in to PLAUD."
            case .audioNotReady: return "This recording has no audio in the cloud yet (upload happens while charging)."
            }
        }
    }

    private static let defaultsBase = "https://api.plaud.ai"
    /// Browser-like UA: the consumer endpoints sit behind an edge that
    /// rejects non-browser clients (Riffado carries one for the same reason).
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    @Published private(set) var email: String?
    @Published private(set) var accessToken: String?
    private(set) var apiBase: String

    private let session: URLSession

    init() {
        let d = UserDefaults.standard
        email = d.string(forKey: "plaud.email")
        accessToken = d.string(forKey: "plaud.token")
        apiBase = d.string(forKey: "plaud.api_base") ?? Self.defaultsBase
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        session = URLSession(configuration: cfg)
    }

    var isSignedIn: Bool { accessToken != nil }

    // MARK: - Auth (OTP)

    /// Step 1: email → verification code sent by PLAUD. Persists the OTP token
    /// (held only in memory by the caller) and follows region redirects.
    func sendCode(to emailAddress: String) async throws {
        let base = try await resolveRegion(email: emailAddress)
        apiBase = base
        UserDefaults.standard.set(base, forKey: "plaud.api_base")
        otpToken = try await postOTP(
            path: "/auth/otp-send-code",
            body: ["username": emailAddress],
            base: base
        ).token
    }

    private var otpToken: String?

    /// Step 2: the code the user received → User Token (persisted).
    func verify(_ code: String, email emailAddress: String) async throws {
        guard let otp = otpToken else { throw PlaudError.badResponse("Request a code first.") }
        let body: [String: String] = ["code": code, "token": otp]
        let (data, _) = try await postForData(
            path: "/auth/otp-login", body: body, bearer: nil, base: apiBase
        )
        let unwrapped = try Self.unwrap(data)
        let token = (unwrapped["access_token"] as? String)
            ?? ((unwrapped["data"] as? [String: Any])?["access_token"] as? String)
        guard let token, !token.isEmpty else {
            throw PlaudError.badResponse("Login rejected by PLAUD.")
        }
        accessToken = token
        email = emailAddress
        let d = UserDefaults.standard
        d.set(token, forKey: "plaud.token")
        d.set(emailAddress, forKey: "plaud.email")
        log.info("plaud cloud sign-in ok")
    }

    func signOut() {
        accessToken = nil
        email = nil
        otpToken = nil
        let d = UserDefaults.standard
        d.removeObject(forKey: "plaud.token")
        d.removeObject(forKey: "plaud.email")
    }

    /// Region probe + code request in one: a CN account gets `status:-302`
    /// with the regional API host, which every later call must reuse.
    private func resolveRegion(email: String) async throws -> String {
        let result = try await postOTP(
            path: "/auth/otp-send-code", body: ["username": email], base: apiBase
        )
        return result.base
    }

    private struct OTPResult { let token: String?; let base: String }

    private func postOTP(path: String, body: [String: String], base: String) async throws -> OTPResult {
        var currentBase = base
        for _ in 0...3 {
            let (data, _) = try await postForData(path: path, body: body, bearer: nil, base: currentBase)
            let json = try Self.unwrap(data)
            let status = (json["status"] as? Int) ?? 0
            if status == -302, let domains = json["data"] as? [String: Any],
               let regional = (domains["api"] as? String), !regional.isEmpty {
                currentBase = regional
                continue
            }
            guard status == 0 else {
                throw PlaudError.badResponse((json["msg"] as? String) ?? "PLAUD rejected the request.")
            }
            return OTPResult(token: json["token"] as? String, base: currentBase)
        }
        throw PlaudError.badResponse("PLAUD region redirect loop.")
    }

    // MARK: - Recordings

    /// The cloud recording list (non-trash, newest first).
    func listFiles() async throws -> [CloudFile] {
        guard accessToken != nil else { throw PlaudError.notSignedIn }
        let query = "skip=0&limit=200&is_trash=0&sort_by=edit_time&is_desc=true"
        let (data, _) = try await get("/file/simple/web?\(query)")
        let json = try Self.unwrap(data)
        guard let list = (json["data"] as? [[String: Any]]) ?? (json["data"] as? [String: Any]).flatMap({ $0["data"] as? [[String: Any]] }) else {
            return []
        }
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let name = (item["fullname"] as? String) ?? (item["filename"] as? String) ?? id
            let size = (item["filesize"] as? NSNumber)?.int64Value ?? 0
            let edited = (item["edit_time"] as? NSNumber)?.doubleValue ?? 0
            return CloudFile(id: id, name: name, size: size, editedAt: Date(timeIntervalSince1970: edited / 1000))
        }
    }

    /// Download one recording's **original audio** (Opus preferred, mp3
    /// fallback) into the library directory so it becomes a normal Nomily
    /// clip — transcription, summary, export all treat it like any other.
    /// Returns the on-disk URL, or nil when the audio isn't uploaded yet.
    func downloadAudio(of file: CloudFile) async throws -> URL? {
        guard let token = accessToken else { throw PlaudError.notSignedIn }
        let (data, _) = try await get("/file/temp-url/\(file.id)?is_opus=1")
        let json = try Self.unwrap(data)
        let payload = (json["data"] as? [String: Any]) ?? json
        let urlString = (payload["temp_url_opus"] as? String) ?? (payload["temp_url"] as? String)
        guard let urlString else { return nil }
        guard let url = URL(string: urlString) else { throw PlaudError.badResponse("Bad audio link.") }
        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (audio, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw PlaudError.badResponse("Audio download failed.") }
        // Extension from the actual link (Opus vs mp3); the library scanner
        // recognises both. Name = the cloud title, sanitized for the filesystem.
        let ext = url.pathExtension.lowercased().isEmpty ? "opus" : url.pathExtension.lowercased()
        let base = file.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = "\(base).\(ext)"
        let dir = StorageLocations.decryptedDir
        var n = 2
        while dir.appendingPathComponent(candidate).pathExists {
            candidate = "\(base) (\(n)).\(ext)"
            n += 1
        }
        let dest = dir.appendingPathComponent(candidate)
        try audio.write(to: dest, options: .atomic)
        log.info("plaud cloud audio downloaded: \(candidate, privacy: .public) (\(audio.count) B)")
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        return dest
    }

    /// Sync pass: list → download everything not already on disk (by name).
    /// Returns `(downloaded, skipped)` counts for the UI.
    func syncAll(progress: @escaping (Int, Int, String) -> Void) async throws -> (Int, Int) {
        let files = try await listFiles()
        let dir = StorageLocations.decryptedDir
        var downloaded = 0
        var skipped = 0
        for (index, file) in files.enumerated() {
            progress(index, files.count, file.name)
            let exists = ["opus", "mp3"].contains { dir.appendingPathComponent("\(file.name).\($0)").pathExists }
            if exists {
                skipped += 1
                continue
            }
            if try await downloadAudio(of: file) != nil { downloaded += 1 } else { skipped += 1 }
        }
        return (downloaded, skipped)
    }

    // MARK: - Plumbing

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse?) {
        guard let token = accessToken else { throw PlaudError.notSignedIn }
        guard let url = URL(string: apiBase + path) else { throw PlaudError.badResponse("Bad URL.") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            throw PlaudError.badResponse("PLAUD API error \(http?.statusCode ?? -1).")
        }
        return (data, http)
    }

    private func postForData(path: String, body: [String: String], bearer: String?, base: String) async throws -> (Data, HTTPURLResponse?) {
        guard let url = URL(string: base + path) else { throw PlaudError.badResponse("Bad URL.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        return (data, resp as? HTTPURLResponse)
    }

    /// PLAUD consumer endpoints wrap results as `{status, msg, data?}`.
    private static func unwrap(_ data: Data) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let obj = json as? [String: Any] else {
            throw PlaudError.badResponse("Unexpected PLAUD response.")
        }
        if let status = obj["status"] as? Int, status != 0, status != -302 {
            throw PlaudError.badResponse((obj["msg"] as? String) ?? "PLAUD error \(status).")
        }
        return obj
    }
}

private extension URL {
    var pathExists: Bool { FileManager.default.fileExists(atPath: path) }
}
