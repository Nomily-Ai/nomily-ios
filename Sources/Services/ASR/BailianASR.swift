import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr.bailian")

/// 阿里云百炼（Model Studio）的 `qwen3-asr-flash`，走它的 **OpenAI 兼容端点**。
///
/// ★ 2026-11-04（用户："要的就是这个百炼的兼容当前这个语音识别服务的问题"）：
/// 百炼并不提供 OpenAI 的 `/audio/transcriptions`——那个路径在专属端点和主站都是 404
/// （实测 qwen3-asr-flash / fun-asr / whisper-1 全部如此）。它的兼容模式把语音识别
/// 放在 **chat/completions** 里，用 `input_audio` 传音频：
///
/// ```json
/// { "model": "qwen3-asr-flash",
///   "messages": [{"role":"user","content":[{"type":"input_audio",
///                 "input_audio":{"data":"data:audio/mpeg;base64,…"}}]}],
///   "stream": false, "asr_options": {"enable_itn": true} }
/// ```
///
/// 三条硬限制决定了这个文件里的切片逻辑：
/// * 单次音频 ≤ **10 MB**；
/// * 单次时长 ≤ **5 分钟**；
/// * 只传 base64，没有 multipart 上传通道。
///
/// 所以超过 4.5 分钟（留余量）的录音要先用 AVFoundation 按时间切段，逐段识别再拼回去——
/// 片段时间戳会按原始时间轴回填，剪辑片段上的跳转才不会错位。
struct BailianASR {

    var endpoint: String
    var apiKey: String
    var model: String
    var language: String

    static let defaultModel = "qwen3-asr-flash"
    /// 4.5 min per request — the API allows 5, the margin covers container/rounding.
    static let maxSeconds: Double = 270
    /// 10 MB is the documented cap for the base64 payload; leave headroom for the `data:` prefix.
    static let maxBytes = 9_500_000

    init(endpoint: String, apiKey: String = "", model: String = "", language: String = "") {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model.isEmpty ? Self.defaultModel : model
        self.language = language
    }

    // MARK: - Endpoint

    /// `…/compatible-mode/v1` → `…/compatible-mode/v1/chat/completions`
    /// （`LLMEndpoint` 负责判断地址里是否已经带版本段，避免 `/v1/v1`）。
    static func chatURL(_ endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/chat/completions") { return trimmed }
        return LLMEndpoint.chatURL(trimmed)
    }

    // MARK: ★ 2026-11-05 MAAS 专属端点的路径兜底

    /// 阿里云**业务空间专属端点**（主机 `*.maas.aliyuncs.com`）在控制台同时给出
    /// `…/compatible-mode/v1`（OpenAI 兼容）与 `…/api/v1`（DashScope 原生）两个
    /// base；网关只认其中一个，另一个回 **400 + 空错误体**，界面上一行报错完全
    /// 看不出是路径错了。这里把两条路径互换出一个"备胎 URL"，第一次失败时把
    /// 同一段音频换路径再试一次（见 `transcribe` 的 catch 分支）。
    static func alternateCompatibleURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              host.hasSuffix(".maas.aliyuncs.com"),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = comps.path
        if path.contains("/compatible-mode/") {
            comps.path = path.replacingOccurrences(of: "/compatible-mode", with: "")
            return comps.url
        }
        if path.contains("/api/v") {
            comps.path = path.replacingOccurrences(of: "/api/", with: "/compatible-mode/")
            return comps.url
        }
        // 用户只贴了裸主机：chatURL 拼出 `/v1/…`——MAAS 网关的正确前缀是
        // `/compatible-mode/v1`。
        if path == "/v1" || path.hasPrefix("/v1/") {
            comps.path = "/compatible-mode" + path
            return comps.url
        }
        return nil
    }

    /// 空错误体的 400 才值得换路径重试；带错误说明的失败是业务层的问题
    /// （模型名、参数），换路径没有意义。
    private static func statusWantsPathRetry(_ error: Error) -> Bool {
        guard case AsrError.http(let status, let message) = error else { return false }
        return status == 400 && message.contains("端点返回空错误体")
    }

    // MARK: - Transcribe

    func transcribe(fileURL: URL, locales: [String]?) async throws -> AsrResult {
        let chat = Self.chatURL(endpoint)
        guard let url = URL(string: chat) else {
            throw AsrError.missingCredentials("Bailian ASR (invalid endpoint)")
        }
        let hint = language.isEmpty ? (locales?.first.flatMap(Self.shortCode)) : Self.shortCode(language)

        let size = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int) ?? 0
        let duration = await Self.duration(of: fileURL)

        // ★ 2026-11-05（用户截图：HTTP 400 空错误体 + 来源页"无法打开"）：m4a/mp3/wav
        // 这类带头部的容器**连时长都读不出来**时，文件本身极可能已经损坏
        // （录制被强制中断时的截断写——同一份文件播放器也打不开）。服务器端同样
        // 解不了这种文件，与其发上去收一句"端点返回空错误体"，不如就地说明白。
        // ogg 不在此列：它的时长走专门的页扫描，扫不出来不代表文件坏。
        if duration == nil, Self.mimeType(for: fileURL) != "audio/ogg" {
            log.error("bailian transcribe: \(fileURL.lastPathComponent, privacy: .public) has no readable duration — refusing to upload a likely-corrupt file")
            throw AsrError.http(0, "这段录音在本地就无法解码——文件疑似损坏（多半是录制被系统中断），转写和播放都会失败；已跳过上传")
        }

        var slices: [Slice] = []
        var temporaries: [URL] = []
        defer { temporaries.forEach { try? FileManager.default.removeItem(at: $0) } }

        let tooLong = (duration ?? 0) > Self.maxSeconds
        if tooLong, let duration {
            slices = try await Self.slice(fileURL, duration: duration)
            temporaries = slices.map(\.url)
        } else if size > Self.maxBytes {
            // No duration but oversized, or a single slice that is still too big:
            // slicing is the only way through, so retry with the decoded asset.
            if let duration {
                slices = try await Self.slice(fileURL, duration: duration)
                temporaries = slices.map(\.url)
            } else {
                throw AsrError.http(413, "音频超过 10 MB 且无法读取时长，不能切片")
            }
        } else {
            slices = [Slice(url: fileURL, start: 0, end: duration ?? 0)]
        }

        log.info("""
            bailian transcribe \(fileURL.lastPathComponent, privacy: .public) \
            bytes=\(size) duration=\(duration ?? -1, privacy: .public) \
            slices=\(slices.count) model=\(model, privacy: .public) hint=\(hint ?? "-", privacy: .public)
            """)

        var segments: [AsrSegment] = []
        for (index, slice) in slices.enumerated() {
            try Task.checkCancellation()
            let text: String
            do {
                text = try await send(slice, to: url, hint: hint, index: index, total: slices.count)
            } catch let error as AsrError {
                // ★ 2026-11-05：MAAS 专属端点对路径不对的请求只回 400 空错误体
                //（看不出是路径还是音频的问题）。第一次失败且 URL 里没有
                // `compatible-mode` 时，换官方兼容路径（…/compatible-mode/v1）把
                // **同一段**再试一次——两条路径哪个是这家网关的正确入口，试一次就知道。
                guard Self.statusWantsPathRetry(error), let alt = Self.alternateCompatibleURL(url) else {
                    throw error
                }
                log.warning("bailian: empty-body 400 — retrying same slice via \(alt.absoluteString, privacy: .public)")
                text = try await send(slice, to: alt, hint: hint, index: index, total: slices.count)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let span = max(0, slice.end - slice.start)
            segments.append(AsrSegment(
                speaker: nil,
                text: trimmed,
                start: slice.start,
                end: slice.end,
                duration: span
            ))
        }

        guard !segments.isEmpty else { throw AsrError.empty }
        let joined = segments.map(\.text).joined(separator: "\n")
        return AsrResult(
            text: joined,
            segments: segments,
            provider: "bailian",
            locale: hint ?? "auto"
        )
    }

    private func send(_ slice: Slice, to url: URL, hint: String?, index: Int, total: Int) async throws -> String {
        let data = try Data(contentsOf: slice.url)
        guard data.count <= Self.maxBytes else {
            throw AsrError.http(413, "第 \(index + 1) 段超过 10 MB，无法上传")
        }
        let dataURI = "data:\(Self.mimeType(for: slice.url));base64,\(data.base64EncodedString())"

        var body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "user", "content": [["type": "input_audio", "input_audio": ["data": dataURI]]]]
            ],
            "asr_options": ["enable_itn": true],
        ]
        if let hint {
            // 语言是可选提示；放错位置只会在服务端被忽略，不会 400。
            body["asr_options"] = ["enable_itn": true, "language": hint]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // 一段 4.5 分钟音频的识别通常 3–15 s；给足 180 s 以免慢队列被判超时。
        req.timeoutInterval = 180
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let respData: Data
        let response: URLResponse
        do {
            (respData, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AsrError.transport(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        LLMRequestLog.record(req, code: status, millis: 0, note: "bailian-asr \(index + 1)/\(total)")
        guard 200..<300 ~= status else {
            // ★ 2026-11-04: 这台专属部署（`ws-….maas.aliyuncs.com`）对错误只回
            // `{}`，日志里每条都是 `HTTP 400: {}`，看不出该改哪里。把**发出去的
            // 关键字段**拼进来：模型名、主机、音频大小/时长。
            let raw = (String(data: respData.prefix(400), encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // ★ 2026-11-05：把**完整路径**也拼进来——MAAS 专属端点 /v1 与
            // /compatible-mode/v1 只有一个是对的，光看主机名分不出来。
            let hostPart = (url.host ?? "-") + url.path
            let context = "model=\(model) url=\(hostPart) audio=\(data.count / 1024)KB \(slice.url.pathExtension)"
            if raw.isEmpty || raw == "{}" || raw == "[]" {
                throw AsrError.http(status, "端点返回空错误体（多半是模型名/部署不支持这段音频），已发送：\(context)")
            }
            throw AsrError.http(status, "\(raw)（已发送：\(context)）")
        }
        return try Self.parseText(respData)
    }

    // MARK: - Response

    /// `choices[0].message.content` is a plain string for qwen3-asr, but some
    /// compatible gateways hand back `[{"text": …}]`. Both are accepted.
    static func parseText(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AsrError.decoding(NSError(domain: "bailian", code: 0,
                                            userInfo: [NSLocalizedDescriptionKey: "响应不是 JSON"]))
        }
        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any] {
            if let text = message["content"] as? String { return text }
            if let parts = message["content"] as? [[String: Any]] {
                return parts.compactMap { $0["text"] as? String }.joined()
            }
        }
        // Some deployments put the transcript at the top level.
        if let text = json["text"] as? String { return text }
        throw AsrError.empty
    }

    // MARK: - Slicing

    struct Slice {
        var url: URL
        var start: Double
        var end: Double
    }

    /// Exports `source` as time-bounded m4a pieces. Returns temp files the caller
    /// deletes; `start`/`end` stay on the original timeline so segments line up.
    static func slice(_ source: URL, duration: Double) async throws -> [Slice] {
        let asset = AVURLAsset(url: source)
        var out: [Slice] = []
        var cursor: Double = 0
        while cursor < duration - 0.2 {
            let end = min(duration, cursor + maxSeconds)
            let piece = FileManager.default.temporaryDirectory
                .appendingPathComponent("bailian-\(UUID().uuidString.prefix(8)).m4a")
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw AsrError.http(500, "无法创建音频导出会话（格式不受支持）")
            }
            session.outputURL = piece
            session.outputFileType = .m4a
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: cursor, preferredTimescale: 600),
                duration: CMTime(seconds: end - cursor, preferredTimescale: 600)
            )
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { cont.resume() }
            }
            guard session.status == .completed else {
                try? FileManager.default.removeItem(at: piece)
                throw AsrError.http(500, "音频切片失败（\(session.status.rawValue)）")
            }
            out.append(Slice(url: piece, start: cursor, end: end))
            cursor = end
        }
        return out
    }

    static func duration(of url: URL) async -> Double? {
        if let d = OpusOgg.duration(ofOggOpusAt: url), d > 0 { return d }
        let asset = AVURLAsset(url: url)
        if let loaded = try? await asset.load(.duration), loaded.isValid {
            let seconds = loaded.seconds
            if seconds.isFinite, seconds > 0 { return seconds }
        }
        return nil
    }

    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav":  return "audio/wav"
        case "mp3":  return "audio/mpeg"
        case "m4a":  return "audio/mp4"
        case "flac": return "audio/flac"
        case "amr":  return "audio/amr"
        case "aac":  return "audio/aac"
        default:     return "audio/ogg"   // opus/ogg 都是这种；文档支持 ogg/opus
        }
    }

    static func shortCode(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value != "auto" else { return nil }
        // `zh-Hans` → `zh`, `yue-Hant` → `yue`
        return value.split(separator: "-").first.map(String.init)
    }

    // MARK: - Model list + probe（设置页那两个按钮）

    /// `GET {base}/models`，只留能识别音频的型号（`qwen3-asr-flash` / `fun-asr-*` /
    /// `paraformer-*` …）。走 `modelsURL` 而不是"从路径退一级"，因为这里填的是
    /// `…/compatible-mode/v1`，退一级会变成 `…/compatible-mode/models`（404）。
    static func listModels(endpoint: String, apiKey: String, timeout: TimeInterval = 12) async -> CustomASR.ModelListResult? {
        guard let url = URL(string: LLMEndpoint.modelsURL(endpoint)) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return nil }
        let all = list.compactMap { $0["id"] as? String }.sorted()
        guard !all.isEmpty else { return nil }
        let capable = all.filter { CustomASR.isTranscriptionCapable($0) }
        return CustomASR.ModelListResult(models: capable.isEmpty ? all : capable, total: all.count)
    }

    static func probe(endpoint: String, apiKey: String, timeout: TimeInterval = 10) async -> CustomASR.ProbeResult? {
        guard let url = URL(string: LLMEndpoint.modelsURL(endpoint)) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["data"] as? [[String: Any]] {
            let count = list.count
            return CustomASR.ProbeResult(ok: true, detail: "\(count) models", error: nil)
        }
        return CustomASR.ProbeResult(ok: false, detail: nil, error: "HTTP \(status)")
    }
}
