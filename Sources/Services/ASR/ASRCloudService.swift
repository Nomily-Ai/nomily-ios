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
            let models = parseModels(data, spec: spec)
            guard (200..<300).contains(code) else {
                let reason = message(in: data) ?? L10n.ASRCloud.http(code)
                log.notice("probe \(spec.id, privacy: .public) → HTTP \(code, privacy: .public)")
                return Result(ok: false, millis: millis, detail: "HTTP \(code)", error: reason)
            }
            log.notice("probe \(spec.id, privacy: .public) ok in \(millis, privacy: .public) ms")
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
