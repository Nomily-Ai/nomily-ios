import CryptoKit
import Foundation
import os

/// Aliyun NLS 录音文件识别 (file transcription), wired into the engine 2026-10-22.
///
/// Why this file looks the way it does — the API's shape forced every step:
///
/// - **The service takes no uploads.** `SubmitTask` wants `file_link`, a URL the
///   Aliyun servers can download over the public internet ("Local files cannot
///   be submitted directly" — their own docs). So the audio first goes to the
///   **user's own OSS bucket** via a PUT signed with the same AccessKey pair,
///   then a **presigned GET URL** (2 h validity) becomes the `file_link`.
/// - **Both OSS and the transcription API sign with HMAC-SHA1** over a canonical
///   string. OSS signs headers (`PUT\n\n<type>\n<date>\n/bucket/key`); the
///   transcription POP API signs sorted RPC query params (`GET&%2F&<query>`),
///   reusing `ASRCloudService.aliyunEncode`.
/// - **It is asynchronous**: submit returns a `TaskId`, the result only shows up
///   after polling `GetTaskResult` (free-tier tasks can legally take hours; we
///   cap the wait and report honestly instead of silently resubmitting — a
///   resubmit would bill the same audio twice).
struct AliyunFileASR {

    let accessKeyId: String
    let accessKeySecret: String
    /// The NLS *project* Appkey (nls-portal.console.aliyun.com → 项目列表) —
    /// not the AccessKey, and nothing to do with OSS. The project's configured
    /// recognition model decides the language.
    let appKey: String
    let ossBucket: String
    /// Shared by OSS (`<bucket>.oss-<region>.aliyuncs.com`) and the filetrans
    /// endpoint (`filetrans.<region>.aliyuncs.com`). Bucket and region must agree.
    let region: String

    private static let pollInterval: Duration = .seconds(4)
    private static let maxWaitSeconds: TimeInterval = 15 * 60
    private static let presignValidity: TimeInterval = 2 * 3600

    private static let log = Logger(subsystem: "com.nomily.app", category: "ASR-Aliyun")

    // MARK: - Pipeline

    func transcribe(fileURL: URL, locales: [String]?) async throws -> AsrResult {
        let started = Date()
        let data = try Data(contentsOf: fileURL)
        let ext = fileURL.pathExtension.lowercased()
        let key = "nomily-asr/\(UUID().uuidString).\(ext.isEmpty ? "bin" : ext)"

        // 1. Upload to the user's OSS bucket. The object is private; nobody can
        //    read it without a signed URL.
        let host = try await ossPut(data: data, contentType: Self.mimeType(for: ext), key: key)
        Self.log.notice("oss upload ok host=\(host, privacy: .public) key=\(key, privacy: .public) bytes=\(data.count)")

        // 2. Presigned download link — this is the `file_link` Aliyun requires.
        let link = Self.presignedGet(key: key,
                                     accessKeyId: accessKeyId,
                                     accessKeySecret: accessKeySecret,
                                     bucket: ossBucket,
                                     host: host,
                                     expiresIn: Self.presignValidity)

        // 3. Submit the recognition task (AK-signed POP RPC, POST).
        let task: [String: Any] = [
            "appkey": appKey,
            "file_link": link,
            // 4.0 is what new integrations are told to pin; enables the camel-case
            // result fields and sample-rate adaptation.
            "version": "4.0",
            "enable_words": false,
            "enable_sample_rate_adaptive": true,
            "auto_split": false,
        ]
        let taskJSON = String(data: try JSONSerialization.data(withJSONObject: task), encoding: .utf8) ?? "{}"
        let submitResult = try await Self.popCall(
            endpoint: "https://filetrans.\(region).aliyuncs.com",
            action: "SubmitTask",
            version: "2018-08-17",
            region: region,
            accessKeyId: accessKeyId,
            accessKeySecret: accessKeySecret,
            extraParams: [("Task", taskJSON)],
            method: "POST")

        guard let taskId = submitResult["TaskId"] as? String, !taskId.isEmpty else {
            let text = (submitResult["StatusText"] as? String)
                ?? (try? JSONSerialization.data(withJSONObject: submitResult))
                    .flatMap { String(data: $0, encoding: .utf8) }
                ?? "no TaskId"
            throw AsrError.taskFailed(text)
        }
        Self.log.notice("submitted task=\(taskId, privacy: .public) file=\(fileURL.lastPathComponent, privacy: .public)")

        // 4. Poll. Free-tier tasks are allowed to take up to 24 h; we hold the
        //    line for a realistic interactive window and then stop WITHOUT
        //    resubmitting — the task keeps running server-side (results are
        //    retained for 72 h), and a retry button beats double billing.
        let deadline = Date().addingTimeInterval(Self.maxWaitSeconds)
        while true {
            try Task.checkCancellation()
            let poll = try await Self.popCall(
                endpoint: "https://filetrans.\(region).aliyuncs.com",
                action: "GetTaskResult",
                version: "2018-08-17",
                region: region,
                accessKeyId: accessKeyId,
                accessKeySecret: accessKeySecret,
                extraParams: [("TaskId", taskId)],
                method: "GET")
            let statusCode = (poll["StatusCode"] as? NSNumber)?.intValue ?? 0
            let statusText = poll["StatusText"] as? String ?? ""
            switch statusCode {
            case 21000000:
                return try Self.parseResult(poll, provider: "aliyun",
                                            locale: locales?.first ?? "",
                                            elapsed: Date().timeIntervalSince(started))
            case 21050000, 21050001:   // queued / running
                if Date() > deadline {
                    throw AsrError.stillRunning(minutes: Int(Self.maxWaitSeconds / 60))
                }
                try await Task.sleep(for: Self.pollInterval)
            default:
                throw AsrError.taskFailed("StatusCode=\(statusCode) StatusText=\(statusText)")
            }
        }
    }

    // MARK: - Result parsing

    /// 4.0 result shape: `Result` is a JSON-**string** holding
    /// `bands[].sentences[]` with millisecond timings.
    private static func parseResult(
        _ poll: [String: Any], provider: String, locale: String, elapsed: TimeInterval
    ) throws -> AsrResult {
        guard let raw = poll["Result"] as? String,
              let result = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let bands = result["bands"] as? [[String: Any]]
        else { throw AsrError.empty }

        var segments: [AsrSegment] = []
        for band in bands {
            guard let sentences = band["sentences"] as? [[String: Any]] else { continue }
            for sentence in sentences {
                guard let text = sentence["text"] as? String, !text.isEmpty else { continue }
                let begin = ((sentence["begin_time"] as? NSNumber)?.doubleValue ?? 0) / 1000
                let end = ((sentence["end_time"] as? NSNumber)?.doubleValue ?? 0) / 1000
                segments.append(AsrSegment(
                    speaker: nil,
                    text: text,
                    start: begin,
                    end: max(begin, end),
                    duration: max(0, max(begin, end) - begin)))
            }
        }
        guard !segments.isEmpty else { throw AsrError.empty }
        log.notice("result ok chars=\(segments.map({ $0.text }).joined().count) segments=\(segments.count) in \(Int(elapsed))s")
        return AsrResult(
            text: segments.map(\.text).joined(),
            segments: segments,
            provider: provider,
            locale: locale)
    }

    // MARK: - Aliyun POP RPC (HMAC-SHA1)

    /// One signed RPC call to a POP-style endpoint. `GET` signs the query;
    /// `POST` sends the very same params as a form body — the signature string
    /// is identical either way (`<METHOD>&%2F&<canonical query>`), which is the
    /// whole trick of Aliyun RPC signing.
    private static func popCall(
        endpoint: String,
        action: String,
        version: String,
        region: String,
        accessKeyId: String,
        accessKeySecret: String,
        extraParams: [(String, String)],
        method: String
    ) async throws -> [String: Any] {
        var params: [(String, String)] = [
            ("Action", action),
            ("AccessKeyId", accessKeyId),
            ("Format", "JSON"),
            ("RegionId", region),
            ("SignatureMethod", "HMAC-SHA1"),
            ("SignatureNonce", UUID().uuidString),
            // Same requirement the probe hit live (2026-10-22): POP rejects
            // requests that omit it.
            ("SignatureVersion", "1.0"),
            ("Timestamp", iso8601Basic()),
            ("Version", version),
        ] + extraParams
        params.sort { $0.0 < $1.0 }

        let canonical = params
            .map { "\(ASRCloudService.aliyunEncode($0.0))=\(ASRCloudService.aliyunEncode($0.1))" }
            .joined(separator: "&")
        let stringToSign = "\(method)&\(ASRCloudService.aliyunEncode("/"))&\(ASRCloudService.aliyunEncode(canonical))"
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: Data("\(accessKeySecret)&".utf8)))
        let signature = Data(mac).base64EncodedString()

        // Hand-built query, not `URLComponents`: the latter leaves `+` in the
        // base64 signature unescaped and Aliyun reads it as a space (see
        // `ASRCloudService.aliyunSignedURL`).
        let host = URL(string: endpoint)?.host ?? ""
        guard let url = ASRCloudService.aliyunSignedURL(
            host: host, params: params, signature: signature) else {
            throw AsrError.http(0, "cannot build the Aliyun request URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if method == "POST" {
            // RFC 3986 form-encode the body by hand — URLQueryItem would encode
            // with `+` for spaces, which the canonical form above disagrees with.
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let form = params
                .map { "\(ASRCloudService.aliyunEncode($0.0))=\(ASRCloudService.aliyunEncode($0.1))" }
                .joined(separator: "&")
                + "&Signature=\(ASRCloudService.aliyunEncode(signature))"
            request.httpBody = Data(form.utf8)
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw AsrError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AsrError.decoding(NSError(domain: "AliyunFileASR", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: "response is not JSON"]))
        }
        return json
    }

    // MARK: - OSS

    /// Bucket → real host, learned from OSS's own 403 hint.
    ///
    /// The credential sheet's `region` is free text and OSS is strict about it:
    /// a bucket created in Hangzhou answers an endpoint built from `cn-shanghai`
    /// with *"The bucket you are attempting to access must be addressed using
    /// the specified endpoint"* and HTTP 403 — which is exactly what every
    /// Aliyun file transcription hit on device (2026-10-23). Making the user
    /// look up their bucket's region is a bad trade when the error itself names
    /// the right endpoint: read `<Endpoint>` out of it, retry once, remember it.
    private static var ossHostCache: [String: String] = [:]
    private static let ossHostLock = NSLock()

    private static func cachedOSSHost(bucket: String) -> String? {
        ossHostLock.lock(); defer { ossHostLock.unlock() }
        return ossHostCache[bucket]
    }

    private static func cacheOSSHost(_ host: String, bucket: String) {
        ossHostLock.lock(); ossHostCache[bucket] = host; ossHostLock.unlock()
    }

    /// `https://<bucket>.oss-cn-hangzhou.aliyuncs.com/` → `<bucket>.oss-cn-hangzhou.aliyuncs.com`
    private static func endpointHint(in data: Data) -> String? {
        guard let xml = String(data: data, encoding: .utf8),
              let open = xml.range(of: "<Endpoint>"),
              let close = xml.range(of: "</Endpoint>") else { return nil }
        let raw = String(xml[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        let host = raw.split(separator: "/").first.map(String.init) ?? ""
        return host.isEmpty ? nil : host
    }

    /// PUT with the classic OSS header signature:
    /// `base64(HMAC-SHA1(secret, "PUT\n\n<type>\n<date>\n/<bucket>/<key>"))`.
    /// Returns the host that accepted the object, so the presigned GET below is
    /// built against the same endpoint.
    private func ossPut(data: Data, contentType: String, key: String) async throws -> String {
        var host = Self.cachedOSSHost(bucket: ossBucket)
            ?? "\(ossBucket).oss-\(region).aliyuncs.com"
        for attempt in 0...1 {
            let resource = "/\(ossBucket)/\(key)"
            let date = Self.rfc1123Now()
            let stringToSign = "PUT\n\n\(contentType)\n\(date)\n\(resource)"
            let mac = HMAC<Insecure.SHA1>.authenticationCode(
                for: Data(stringToSign.utf8),
                using: SymmetricKey(data: Data(accessKeySecret.utf8)))
            let signature = Data(mac).base64EncodedString()

            guard let url = URL(string: "https://\(host)/\(key)") else {
                throw AsrError.missingCredentials(L10n.ASR.aliyun)
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 300
            request.httpMethod = "PUT"
            request.httpBody = data
            request.setValue(date, forHTTPHeaderField: "Date")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue("OSS \(accessKeyId):\(signature)", forHTTPHeaderField: "Authorization")

            let (respData, resp) = try await URLSession.shared.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                Self.cacheOSSHost(host, bucket: ossBucket)
                return host
            }
            // Wrong-endpoint 403 names the right one — follow it once.
            if attempt == 0, code == 403,
               let hint = Self.endpointHint(in: respData), hint != host {
                Self.log.notice("oss endpoint \(host, privacy: .public) → \(hint, privacy: .public)")
                host = hint
                continue
            }
            Self.log.error("oss put failed HTTP \(code): \(String(data: respData.prefix(180), encoding: .utf8) ?? "", privacy: .public)")
            throw AsrError.http(code, String(data: respData.prefix(200), encoding: .utf8) ?? "")
        }
        throw AsrError.http(403, "OSS endpoint could not be resolved")
    }

    /// Presigned GET (object stays private): the URL embeds an expiry-stamped
    /// signature over `"GET\n\n\n<expires>\n/<bucket>/<key>"`.
    private static func presignedGet(
        key: String, accessKeyId: String, accessKeySecret: String,
        bucket: String, host: String, expiresIn: TimeInterval
    ) -> String {
        let expires = String(Int(Date().timeIntervalSince1970 + expiresIn))
        let resource = "/\(bucket)/\(key)"
        let stringToSign = "GET\n\n\n\(expires)\n\(resource)"
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: Data(accessKeySecret.utf8)))
        let signature = Data(mac).base64EncodedString()
        return "https://\(host)/\(key)"
            + "?OSSAccessKeyId=\(ASRCloudService.aliyunEncode(accessKeyId))"
            + "&Expires=\(expires)"
            + "&Signature=\(ASRCloudService.aliyunEncode(signature))"
    }

    // MARK: - Small helpers

    static func mimeType(for ext: String) -> String {
        switch ext {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "ogg": return "audio/ogg"
        case "flac": return "audio/flac"
        case "amr": return "audio/amr"
        case "wma": return "audio/x-ms-wma"
        default: return "application/octet-stream"
        }
    }

    private static func iso8601Basic() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date())
    }

    private static func rfc1123Now() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: Date())
    }
}
