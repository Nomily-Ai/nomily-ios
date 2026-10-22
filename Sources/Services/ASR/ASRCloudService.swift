import CryptoKit
import Foundation
import os

/// Credential check + latency for the cloud ASR vendors.
///
/// Same principle as the LLM probe: hit the vendor's **real authenticated
/// endpoint** once and time it, instead of declaring success because a string is
/// non-empty. Each vendor authenticates differently — Bearer, a bare key, a
/// custom header, HTTP Basic, or AWS SigV4 — and a probe that didn't match what
/// the transcription call will send would prove nothing.
///
/// The calls are the cheapest authenticated read each vendor offers (list / probe
/// endpoints), so a test costs no audio quota.
enum ASRCloudService {

    struct Result: Equatable {
        var ok: Bool
        var millis: Int
        /// `HTTP 200 · 12 models` on success.
        var detail: String?
        var error: String?
        /// Model names, when the probe happened to return them (Watson, Deepgram).
        var models: [String] = []

        static func failure(_ error: String) -> Result {
            Result(ok: false, millis: 0, detail: nil, error: error)
        }
    }

    private static let log = Logger(subsystem: "com.nomily.app", category: "ASR-Cloud")
    private static let timeout: TimeInterval = 20

    // MARK: - Probe

    static func test(
        spec: ASRCloudSpec, endpoint: String, values: [String: String], secrets: [String: String]
    ) async -> Result {
        for field in spec.fields where field.required {
            let value = field.kind == .secret ? (secrets[field.id] ?? "") : (values[field.id] ?? "")
            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                return .failure(L10n.ASRCloud.missingField(field.label))
            }
        }
        let base = endpoint.isEmpty ? spec.endpoint(values: values) : endpoint
        guard let request = build(spec: spec, base: base, values: values, secrets: secrets) else {
            return .failure(L10n.ASRCloud.badEndpoint)
        }

        let started = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // 讯飞's recognition entry is a WebSocket: a *correct* signature is
            // answered with 101 (upgrade accepted), a wrong one with 401 + JSON.
            let accepted = (200..<300).contains(code) || (spec.id == "xfyun" && code == 101)
            if accepted, let bodyError = bodyError(spec: spec, data: data) {
                log.notice("probe \(spec.id, privacy: .public) → rejected by body: \(bodyError, privacy: .public)")
                return Result(ok: false, millis: millis, detail: "HTTP \(code)", error: bodyError)
            }
            guard accepted else {
                let reason = message(in: data) ?? L10n.ASRCloud.http(code)
                log.notice("probe \(spec.id, privacy: .public) → HTTP \(code, privacy: .public)")
                return Result(ok: false, millis: millis, detail: "HTTP \(code)", error: reason)
            }
            log.notice("probe \(spec.id, privacy: .public) ok in \(millis, privacy: .public) ms")
            let models = parseModels(data, spec: spec)
            let suffix = models.isEmpty ? "" : " · \(L10n.ASRCloud.modelCount(models.count))"
            return Result(ok: true, millis: millis, detail: "HTTP \(code)\(suffix)",
                          error: nil, models: models)
        } catch {
            let ns = error as NSError
            log.error("probe \(spec.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorTimedOut {
                return .failure(L10n.ASRCloud.timeout)
            }
            if ns.domain == NSURLErrorDomain,
               ns.code == NSURLErrorCannotFindHost || ns.code == NSURLErrorCannotConnectToHost {
                return .failure(L10n.ASRCloud.unreachable)
            }
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Per-vendor requests

    private static func build(
        spec: ASRCloudSpec, base: String, values: [String: String], secrets: [String: String]
    ) -> URLRequest? {
        let key = secrets["apiKey"] ?? ""

        /// GET helper with one extra header.
        func get(_ url: String, header: (String, String)?) -> URLRequest? {
            guard let u = URL(string: url) else { return nil }
            var req = URLRequest(url: u)
            req.timeoutInterval = timeout
            if let (name, value) = header { req.setValue(value, forHTTPHeaderField: name) }
            return req
        }

        switch spec.id {
        // ---- 国内四家（2026-10-22）----

        case "aliyun":
            // RPC-style AccessKey signature against nls-meta's CreateToken: the
            // token this returns is exactly what their transcription calls use,
            // so a pass here proves the pair, not just reachability.
            return aliyunSigned(
                accessKeyId: secrets["accessKeyId"] ?? "",
                accessKeySecret: secrets["accessKeySecret"] ?? "")

        case "baidu":
            // OAuth2 client-credentials: AK/SK → access_token. Wrong keys still
            // answer HTTP 200, so `bodyError` catches that case below.
            var parts = URLComponents(string: "https://aip.baidubce.com/oauth/2.0/token")
            parts?.queryItems = [
                URLQueryItem(name: "grant_type", value: "client_credentials"),
                URLQueryItem(name: "client_id", value: secrets["apiKey"] ?? ""),
                URLQueryItem(name: "client_secret", value: secrets["secretKey"] ?? ""),
            ]
            guard let url = parts?.url else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            return req

        case "xfyun":
            // host + date HMAC-SHA256, per their auth doc. The date must be
            // RFC1123 GMT and within 5 minutes of the server's clock.
            return xfyunSigned(
                apiKey: secrets["apiKey"] ?? "",
                apiSecret: secrets["apiSecret"] ?? "")

        case "tencent":
            // TC3-HMAC-SHA256 against the cheapest authenticated read
            // (DescribeVocabList). Region is a header, not part of the host.
            return tencentSigned(
                secretId: secrets["secretId"] ?? "",
                secretKey: secrets["tencentSecretKey"] ?? "",
                region: values["region"] ?? "ap-shanghai")

        case "google":
            // Listing operations is the cheapest call that authenticates: a bad
            // key is 403, a good key is `{}` with 200. No audio, no quota.
            return get("https://speech.googleapis.com/v1/operations?key=\(key)", header: nil)

        case "aws":
            return awsSigned(
                region: values["region"] ?? "us-east-1",
                accessKey: secrets["accessKey"] ?? "",
                secretKey: secrets["secretKey"] ?? ""
            )

        case "deepgram":
            // Deepgram's scheme is `Token`, not `Bearer` — the one header that
            // would silently 401 if it were guessed.
            return get("https://api.deepgram.com/v1/projects", header: ("Authorization", "Token \(key)"))

        case "assemblyai":
            // And this one wants the key with no scheme at all.
            return get("https://api.assemblyai.com/v2/transcript?limit=1", header: ("Authorization", key))

        case "gladia":
            return get("https://api.gladia.io/v2/transcription?limit=1", header: ("x-gladia-key", key))

        case "watson":
            // Basic auth with the literal username `apikey`; the API key is the
            // password. `/v1/models` doubles as the real model list.
            let credential = Data("apikey:\(key)".utf8).base64EncodedString()
            return get("\(base)/v1/models", header: ("Authorization", "Basic \(credential)"))

        default:
            return nil
        }
    }

    // MARK: - 阿里云 RPC signature (HMAC-SHA1)

    /// Aliyun "RPC style" signing, the shape every non-STS Aliyun API uses:
    /// sorted query, percent-encode, `GET&%2F&<encoded query>`, HMAC-SHA1 over
    /// `secret + "&"`. `CreateToken` (nls-meta) is the call because its result
    /// — the token — is the credential the transcription itself will use.
    private static func aliyunSigned(accessKeyId: String, accessKeySecret: String) -> URLRequest? {
        guard !accessKeyId.isEmpty, !accessKeySecret.isEmpty,
              let url = URL(string: "https://nls-meta.cn-shanghai.aliyuncs.com/")
        else { return nil }

        let params: [(String, String)] = [
            ("Action", "CreateToken"),
            ("AccessKeyId", accessKeyId),
            ("Format", "JSON"),
            ("SignatureMethod", "HMAC-SHA1"),
            ("SignatureNonce", UUID().uuidString),
            // ★ Verified live 2026-10-22: nls-meta now rejects the request
            // without this ("SignatureVersion is mandatory for this action").
            ("SignatureVersion", "1.0"),
            ("Timestamp", iso8601Basic()),
            ("Version", "2019-02-28"),
        ].sorted { $0.0 < $1.0 }

        let canonical = params
            .map { "\(aliyunEncode($0.0))=\(aliyunEncode($0.1))" }
            .joined(separator: "&")
        let stringToSign = "GET&\(aliyunEncode("/"))&\(aliyunEncode(canonical))"
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: Data("\(accessKeySecret)&".utf8)))
        let signature = Data(mac).base64EncodedString()

        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
            + [URLQueryItem(name: "Signature", value: signature)]
        var req = URLRequest(url: parts.url!)
        req.timeoutInterval = timeout
        return req
    }

    /// RFC3986 encode with the two Aliyun quirks: `+` → `%20`, `*` → `%2A`,
    /// and `%7E` back to `~`.
    /// Internal (not private): `AliyunFileASR` signs its OSS presigned-URL query
    /// with the exact same rules.
    static func aliyunEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        let encoded = s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        return encoded
            .replacingOccurrences(of: "+", with: "%20")
            .replacingOccurrences(of: "*", with: "%2A")
    }

    /// Aliyun's `Timestamp` is ISO8601 **basic** (no dashes/colons) in GMT.
    private static func iso8601Basic() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date())
    }

    // MARK: - 讯飞 signature (HMAC-SHA256 over host/date/request-line)

    /// Per iFlytek's auth doc: signature = base64(HMAC-SHA256(origin, secret))
    /// where origin is `host: <host>\ndate: <rfc1123>\nGET <path> HTTP/1.1`,
    /// then the whole authorization string is base64'd again. The recognition
    /// endpoint is a WebSocket, so success shows up as HTTP 101.
    private static func xfyunSigned(apiKey: String, apiSecret: String) -> URLRequest? {
        guard !apiKey.isEmpty, !apiSecret.isEmpty,
              let url = URL(string: "https://iat-api.xfyun.cn/v2/iat")
        else { return nil }
        let host = "iat-api.xfyun.cn"
        let path = "/v2/iat"

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let date = f.string(from: Date())

        let origin = "host: \(host)\ndate: \(date)\nGET \(path) HTTP/1.1"
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(origin.utf8), using: SymmetricKey(data: Data(apiSecret.utf8)))
        let signature = Data(mac).base64EncodedString()

        let authorizationOrigin = "api_key=\"\(apiKey)\", algorithm=\"hmac-sha256\", " +
            "headers=\"host date request-line\", signature=\"\(signature)\""
        let authorization = Data(authorizationOrigin.utf8).base64EncodedString()

        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue(date, forHTTPHeaderField: "Date")
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: - 腾讯云 TC3 signature (HMAC-SHA256 chain)

    /// Tencent Cloud's TC3 scheme: three HMAC rounds (date → service →
    /// "tc3_request") over the canonical request hash. `DescribeVocabList` is
    /// the cheapest authenticated read; a business error still comes back as
    /// HTTP 200 with `Response.Error`, which `bodyError` turns into a failure.
    private static func tencentSigned(secretId: String, secretKey: String, region: String) -> URLRequest? {
        guard !secretId.isEmpty, !secretKey.isEmpty,
              let url = URL(string: "https://asr.tencentcloudapi.com")
        else { return nil }
        let host = "asr.tencentcloudapi.com"
        let service = "asr"
        let action = "DescribeVocabList"
        let body = Data("{\"Limit\":1}".utf8)

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        let fullDate = String(f.string(from: Date()).replacingOccurrences(of: "-", with: "").prefix(8))
        let timestamp = String(Int(Date().timeIntervalSince1970))

        let canonicalRequest = """
        POST
        /

        content-type:application/json; charset=utf-8
        host:\(host)
        x-tc-action:\(action.lowercased())

        content-type;host;x-tc-action
        \(sha256Hex(body))
        """
        let scope = "\(fullDate)/\(service)/tc3_request"
        let stringToSign = """
        TC3-HMAC-SHA256
        \(timestamp)
        \(scope)
        \(sha256Hex(Data(canonicalRequest.utf8)))
        """

        func tcHmac(_ key: Data, _ data: Data) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
        }
        var signingKey = Data("TC3\(secretKey)".utf8)
        for part in [fullDate, service, "tc3_request"] {
            signingKey = tcHmac(signingKey, Data(part.utf8))
        }
        let signature = tcHmac(signingKey, Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.httpBody = body
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue(action, forHTTPHeaderField: "X-TC-Action")
        req.setValue("2019-06-14", forHTTPHeaderField: "X-TC-Version")
        req.setValue(region, forHTTPHeaderField: "X-TC-Region")
        req.setValue(timestamp, forHTTPHeaderField: "X-TC-Timestamp")
        req.setValue(
            "TC3-HMAC-SHA256 Credential=\(secretId)/\(scope), SignedHeaders=content-type;host;x-tc-action, Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
        return req
    }

    // MARK: - AWS SigV4

    /// Transcribe (like every AWS service) has no API-key auth: the request must
    /// be signed with HMAC-SHA256 over a canonical form. This is the minimum
    /// viable signer for a `POST /` with the `x-amz-target` header — enough to
    /// answer "are these credentials valid, and how far away is the region".
    private static func awsSigned(region: String, accessKey: String, secretKey: String) -> URLRequest? {
        guard !accessKey.isEmpty, !secretKey.isEmpty,
              let url = URL(string: "https://transcribe.\(region.isEmpty ? "us-east-1" : region).amazonaws.com/")
        else { return nil }
        let host = url.host ?? "transcribe.amazonaws.com"
        let body = Data("{}".utf8)
        let amzDate = timestamp()
        let dateStamp = String(amzDate.prefix(8))
        let target = "Transcribe.ListTranscriptionJobs"

        let canonicalHeaders = """
        content-type:application/x-amz-json-1.1
        host:\(host)
        x-amz-date:\(amzDate)
        x-amz-target:\(target)

        """
        let signedHeaders = "content-type;host;x-amz-date;x-amz-target"
        let payloadHash = sha256Hex(body)

        let canonicalRequest = """
        POST
        /

        \(canonicalHeaders)
        \(signedHeaders)
        \(payloadHash)
        """
        let scope = "\(dateStamp)/\(region)/transcribe/aws4_request"
        let stringToSign = """
        AWS4-HMAC-SHA256
        \(amzDate)
        \(scope)
        \(sha256Hex(Data(canonicalRequest.utf8)))
        """

        var key = Data("AWS4\(secretKey)".utf8)
        for part in [dateStamp, region, "transcribe", "aws4_request"] {
            key = hmac(key, Data(part.utf8))
        }
        let signature = hmac(key, Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.httpBody = body
        req.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        req.setValue(target, forHTTPHeaderField: "X-Amz-Target")
        req.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        req.setValue(
            "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return req
    }

    private static func hmac(_ key: Data, _ data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }

    // MARK: - Response reading

    /// Some vendors answer **HTTP 200** with an error object — for those, a
    /// status check alone would report success on a rejected credential.
    private static func bodyError(spec: ASRCloudSpec, data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        switch spec.id {
        case "baidu":
            // OAuth2 keeps the status at 200 and puts the verdict in the body.
            if json["access_token"] as? String != nil { return nil }
            if let desc = json["error_description"] as? String, !desc.isEmpty { return desc }
            if let code = json["error"] as? String, !code.isEmpty { return code }
            return L10n.ASRCloud.badCredentials
        case "tencent":
            // TC3 services wrap everything in Response; business errors ride
            // along at 200.
            if let err = (json["Response"] as? [String: Any])?["Error"] as? [String: Any] {
                return (err["Message"] as? String) ?? (err["Code"] as? String)
                    ?? L10n.ASRCloud.badCredentials
            }
            return nil
        default:
            return nil
        }
    }

    private static func parseModels(_ data: Data, spec: ASRCloudSpec) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        switch spec.id {
        case "watson":
            let list = json["models"] as? [[String: Any]] ?? []
            return list.compactMap { $0["name"] as? String }.sorted()
        case "deepgram":
            let list = json["stt"] as? [[String: Any]] ?? []
            return list.compactMap { $0["canonical_name"] as? String ?? $0["name"] as? String }.sorted()
        default:
            return []
        }
    }

    private static func message(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let raw = String(data: data.prefix(180), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw : nil
        }
        if let err = json["error"] as? [String: Any] {
            for key in ["message", "Message", "msg", "detail"] {
                if let text = err[key] as? String, !text.isEmpty { return text }
            }
            if let text = err["error"] as? String, !text.isEmpty { return text }
        }
        // AWS answers with `{"__type":"...","message":"..."}` at the top level.
        for key in ["message", "Message", "error", "__type"] {
            if let text = json[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }
}
