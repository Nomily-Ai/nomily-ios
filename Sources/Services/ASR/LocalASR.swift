import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr.local")

/// Local ASR server adapter.
/// POSTs the raw audio bytes as `application/octet-stream` to
/// `http://{host}:{port+1}/v1/transcribe`. The server
/// runs faster-whisper and returns `{"segments": [...], "text": "..."}`.
///
/// Note the **port+1** offset: `config.asr_providers.local.port` is the
/// streaming WebSocket port (12300 by default). The batch-file HTTP endpoint
/// listens on the port immediately after it (12301). Keep that convention —
/// the server bakes it in.
struct LocalASR {
    var host: String
    var port: Int
    var locale: String

    init(host: String, port: Int, locale: String = "en-US") {
        self.host = host
        self.port = port
        self.locale = locale
    }

    func transcribe(fileURL: URL) async throws -> AsrResult {
        guard !host.isEmpty, port > 0 else {
            throw AsrError.missingCredentials("Local server")
        }
        let data = try Data(contentsOf: fileURL)
        // Duration is used only for timeout calculation; if it cannot be determined, fall back to the lower bound below, without affecting the upload itself.
        let duration = await Self.probeDuration(of: fileURL)
        return try await transcribe(
            data: data,
            filename: fileURL.lastPathComponent,
            expectedDuration: duration
        )
    }

    func transcribe(
        data: Data,
        filename: String,
        expectedDuration: TimeInterval? = nil
    ) async throws -> AsrResult {
        guard let endpoint = URL(string: "http://\(host):\(port + 1)/v1/transcribe") else {
            throw AsrError.missingCredentials("Local server (invalid host)")
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // ★ Timeout **must not be hard‑coded** (fixed 2026-10-15).
        //
        // The previous value is fixed at 600 s. Real‑device test (Intel Mac / faster-whisper small / int8 / 12 threads /
        // device=cpu) 16 min 38 s (998.9 s) audio: single run 522.2 s, when throttled by the server’s serial queue
        // Wall‑clock reaches 885.6 s ⇒ **once 600 s passes, URLError.timedOut is thrown**, the user sees
        // "Network error: request timed out." (`AsrError.transport`).
        // Empirical factor: wall‑clock ≈ audio duration × 0.7~1.0; server `app.py`'s
        // `_infer_sem = asyncio.Semaphore(1)` also makes concurrent requests queue serially, **queue time is also counted in
        // each request**, so we leave additional multiplier margin. See `uploadTimeout(for:)`.
        req.timeoutInterval = Self.uploadTimeout(for: expectedDuration)

        log.info("transcribe start filename=\(filename, privacy: .public) bytes=\(data.count) durationS=\(expectedDuration ?? -1, privacy: .public) timeoutS=\(req.timeoutInterval, privacy: .public) host=\(self.host, privacy: .public):\(self.port + 1, privacy: .public)")

        let (respData, response): (Data, URLResponse)
        do {
            (respData, response) = try await URLSession.shared.upload(for: req, from: data)
        } catch {
            log.error("transport error: \(String(describing: error), privacy: .public)")
            throw AsrError.transport(error)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= status else {
            let snippet = String(data: respData.prefix(400), encoding: .utf8) ?? ""
            log.error("HTTP \(status, privacy: .public): \(snippet, privacy: .public)")
            // ★ 2026-10-22 (后台任务里的 HTTP 422 "Field required"): the "local"
            // slot is documented as our own octet-stream contract, but nothing
            // stops a user from pointing it at a **generic FastAPI whisper
            // server**, which answers a raw-body POST with
            // `{"detail":[{"type":"missing","loc":["body","file"],…}]}`.
            // That JSON is exactly "I wanted a multipart upload named file".
            // Speak its language once before giving up — the retry is free and
            // the alternative is a chain of abandoned jobs.
            if status == 422, Self.serverWantsMultipartFile(snippet) {
                log.info("local server wants multipart 'file' — retrying as multipart")
                return try await transcribeMultipart(
                    data: data, filename: filename, expectedDuration: expectedDuration)
            }
            throw AsrError.http(status, snippet)
        }

        let result: AsrResult
        do {
            result = try parse(respData)
        } catch let asrError as AsrError {
            // Parse re‑throws AsrError thrown by itself (e.g., .empty when there is no speech) unchanged:
            // Wrapping it as .decoding would cause “No speech detected” to appear as “Response parsing failed”.
            throw asrError
        } catch {
            throw AsrError.decoding(error)
        }
        log.info("transcribe done segments=\(result.segments.count) chars=\(result.text.count)")
        return result
    }

    // MARK: - Multipart fallback

    /// FastAPI's validation error for a missing `UploadFile` named `file`.
    /// Matching the structured shape (`"loc":["body","file"]`) rather than the
    /// word "file" keeps unrelated 422s (bad parameters, quota) from triggering
    /// a pointless retry.
    private static func serverWantsMultipartFile(_ body: String) -> Bool {
        body.contains("\"body\",\"file\"")
            || (body.contains("\"type\"") && body.contains("\"missing\"") && body.contains("file"))
    }

    /// The same endpoint, spoken as `multipart/form-data` with a `file` field —
    /// the shape every FastAPI whisper server (and the whole OpenAI-compatible
    /// family) expects. `model` is included because servers that validate it
    /// would otherwise 422 a second time; anything that ignores extra fields is
    /// unaffected.
    private func transcribeMultipart(
        data: Data, filename: String, expectedDuration: TimeInterval?
    ) async throws -> AsrResult {
        guard let endpoint = URL(string: "http://\(host):\(port + 1)/v1/transcribe") else {
            throw AsrError.missingCredentials("Local server (invalid host)")
        }
        var form = CustomASR.MultipartForm()
        form.addField(name: "model", value: "whisper-1")
        form.addField(name: "response_format", value: "verbose_json")
        form.addFile(name: "file", filename: filename,
                     mimeType: Self.mimeType(for: filename), data: data)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.uploadTimeout(for: expectedDuration)
        req.setValue("multipart/form-data; boundary=\(form.boundary)",
                     forHTTPHeaderField: "Content-Type")
        let (respData, response): (Data, URLResponse)
        do {
            (respData, response) = try await URLSession.shared.upload(for: req, from: form.body)
        } catch {
            throw AsrError.transport(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= status else {
            let snippet = String(data: respData.prefix(400), encoding: .utf8) ?? ""
            log.error("multipart fallback HTTP \(status, privacy: .public): \(snippet, privacy: .public)")
            throw AsrError.http(status, snippet)
        }
        log.info("multipart fallback ok bytes=\(data.count)")
        let result: AsrResult
        do {
            result = try parse(respData)
        } catch let asrError as AsrError {
            throw asrError
        } catch {
            throw AsrError.decoding(error)
        }
        return result
    }

    /// Best-effort MIME from the filename; the server that cares about this is
    /// the same one that already told us it wants multipart, so a sensible
    /// default covers the rest.
    private static func mimeType(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "flac": return "audio/flac"
        default: return "audio/ogg"
        }
    }

    // MARK: - Timeout estimation

    /// Upload timeout = audio duration × 3, **minimum 600 s**.
    ///
    /// Rationale for factor 3 (measured 2026-10-15, see `transcribe(data:filename:expectedDuration:)`):
    /// Local CPU inference is about 0.7~1.0× real‑time; after adding server serial queuing, the worst observed
    /// 885.6 s / 998.9 s ≈ 0.89× real‑time — a factor of 3 provides roughly 3.4× margin.
    /// Minimum 600 s: short clips on a LAN should not wait only a few seconds just because duration cannot be detected.
    ///
    /// ⚠️ Why not "bigger is better": the real concern is **users thinking the app is frozen**. After giving a sufficient timeout,
    /// cancelling a long recording still goes through `TranscriptionService.cancel(name:)`,
    /// so users don’t have to rely on timeout to escape. Therefore, prefer a looser setting.
    static func uploadTimeout(for duration: TimeInterval?) -> TimeInterval {
        guard let duration, duration.isFinite, duration > 0 else { return 600 }
        return max(600, duration * 3)
    }

    /// Probe the audio duration of the upload payload. **Used only for timeout calculation**, returns nil if undetectable (falls back to 600 s minimum).
    ///
    /// First try `OpusOgg.duration` (scans Ogg pages directly), then fall back to AVFoundation:
    /// Ogg‑Opus duration is not stored in the container header, so AVFoundation returns 0/NaN
    /// (same conclusion as `AudioMerger.reliableDuration`).
    private static func probeDuration(of url: URL) async -> TimeInterval? {
        if let probed = OpusOgg.duration(ofOggOpusAt: url), probed > 0 {
            return probed
        }
        let asset = AVURLAsset(url: url)
        if let loaded = try? await asset.load(.duration), loaded.isValid {
            let seconds = loaded.seconds
            if seconds.isFinite, seconds > 0 { return seconds }
        }
        // ★ 2026-10-27: SDK Mp3Convert 产出的 mp3（VBR 无 Xing 头）AVAsset 可能
        // 探不到时长——AVAudioFile 逐帧解析兜底（与 LibraryView.probeDuration 同款）。
        if let file = try? AVAudioFile(forReading: url) {
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            if seconds.isFinite, seconds > 0 { return seconds }
        }
        return nil
    }

    // MARK: - parsing

    private struct Envelope: Decodable {
        var segments: [Segment]?
        var text: String?
        /// The language code **actually detected by the server** (e.g., "zh"). Our own server always returns
        /// (`language` + `language_probability` in the `/v1/transcribe` response),
        /// while third‑party implementations may omit it, so it is optional.
        var language: String?
    }
    private struct Segment: Decodable {
        var text: String?
        var start: Double?
        var end: Double?
        var duration: Double?
    }

    // MARK: - Connectivity probing

    /// "Is this server reachable?" read‑only criterion — used for the Settings page’s “Test connectivity” button.
    ///
    /// ### Why it is needed
    /// `LocalASR` only sends a request when **actually uploading audio**. Therefore, a wrong host, a service not started,
    /// or the phone not being on the same subnet as the server — these are invisible before the user taps “Transcribe”, and transcription failures only appear on the segment detail page, making attribution difficult.
    /// The Settings page needs a probe that can be **actively tapped**.
    /// The Azure section already has the `verifyButton` interaction pattern, and the local section copies it for consistency.
    ///
    /// ### Why probe two ports
    /// The header comment of this file defines the division of labor: `port` runs the real‑time WebSocket, `port + 1` runs batch HTTP.
    /// Probing only one would produce a false‑positive “connected” status while actual transcription fails, so both are probed, and the
    /// **missing one** is reported explicitly — this is the most easily overlooked failure mode.
    ///
    /// ### The criterion deliberately does not rely on `/health`
    /// Receiving **any** HTTP response counts as connectivity. Nomily’s own server provides `/health` (which also returns model name,
    /// precision, thread count), but users may point to third‑party implementations like whisper.cpp / whisper‑live,
    /// which lack this endpoint. Therefore `/health` is used only to **enrich** the result, not to determine success.
    struct ProbeResult {
        var ok: Bool
        /// Detail line on success: `small · int8 · 12 threads · 23 ms`.
        var detail: String?
        /// Failure reason (localized into a short user‑readable sentence).
        var error: String?
        /// Port‑level warning. When non‑nil, it **still counts as connected** (but half the capability is unavailable).
        var warning: String?
    }

    /// Response body of our own server’s `/health`. All fields are optional: third‑party implementations may only return
    /// `{"status":"ok"}`, or even a different JSON — if it can’t be parsed, treat it as having no details.
    private struct HealthPayload: Decodable {
        var status: String?
        var model: String?
        var modelState: String?
        var device: String?
        var computeType: String?
        var cpuThreads: Int?

        enum CodingKeys: String, CodingKey {
            case status, model, device
            case modelState = "model_state"
            case computeType = "compute_type"
            case cpuThreads = "cpu_threads"
        }
    }

    private struct PortProbe {
        var responded: Bool
        var payload: HealthPayload?
        var latencyMS: Int?
        var error: Error?
    }

    /// Probe once. `timeout` defaults to 6 s — on a LAN, anything longer is essentially unreachable,
    /// and waiting longer would just make the user think the button is broken.
    static func probe(host: String, port: Int, timeout: TimeInterval = 6) async -> ProbeResult {
        let bare = normalizedHost(host)
        guard !bare.isEmpty, (1...65535).contains(port) else {
            return ProbeResult(ok: false, detail: nil, error: L10n.ASR.localProbeNoHost, warning: nil)
        }

        let live = await hitHealth(host: bare, port: port, timeout: timeout)
        let batchPort = port + 1
        let batch: PortProbe
        if (1...65535).contains(batchPort) {
            batch = await hitHealth(host: bare, port: batchPort, timeout: timeout)
        } else {
            // port == 65535: there is no “next port”, so this should not be considered a failure.
            batch = PortProbe(responded: true, payload: nil, latencyMS: nil, error: nil)
        }

        guard live.responded || batch.responded else {
            return ProbeResult(ok: false, detail: nil, error: describe(live.error), warning: nil)
        }

        // Prefer the real‑time port (primary) for details; if it doesn’t respond, fall back to the batch one.
        let primary = live.responded ? live : batch
        var parts: [String] = []
        if let p = primary.payload {
            if let model = p.model, !model.isEmpty { parts.append(model) }
            if let compute = p.computeType, !compute.isEmpty { parts.append(compute) }
            if let threads = p.cpuThreads { parts.append(L10n.ASR.localProbeThreads(threads)) }
            if let state = p.modelState, !state.isEmpty, state != "ready" {
                parts.append(L10n.ASR.localProbeModelLoading)
            }
        }
        if let ms = primary.latencyMS { parts.append("\(ms) ms") }

        var warning: String?
        if !batch.responded {
            warning = L10n.ASR.localProbeWarnBatch(batchPort)
        } else if !live.responded {
            warning = L10n.ASR.localProbeWarnLive(port)
        }

        return ProbeResult(
            ok: true,
            detail: parts.isEmpty ? nil : parts.joined(separator: " · "),
            error: nil,
            warning: warning
        )
    }

    /// Allow users to paste the full URL: `http://1.2.3.4:12300/` → `1.2.3.4`.
    ///
    /// Skipping this step would construct a guaranteed‑failure URL like `http://http://1.2.3.4:12300/health`,
    /// and the user would only see “cannot connect”, with no clue that they pasted extra characters.
    private static func normalizedHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["http://", "https://"] where host.lowercased().hasPrefix(scheme) {
            host = String(host.dropFirst(scheme.count))
        }
        while host.hasSuffix("/") { host.removeLast() }
        // When the user includes a port in the host (`1.2.3.4:12300`), strip the trailing port.
        // Only act when there is **exactly one colon** — IPv6 addresses contain multiple colons and must not be split arbitrarily.
        if host.filter({ $0 == ":" }).count == 1,
           let colon = host.lastIndex(of: ":"),
           !host[host.index(after: colon)...].isEmpty,
           host[host.index(after: colon)...].allSatisfy(\.isNumber) {
            host = String(host[..<colon])
        }
        return host
    }

    private static func hitHealth(host: String, port: Int, timeout: TimeInterval) async -> PortProbe {
        guard let url = URL(string: "http://\(host):\(port)/health") else {
            return PortProbe(responded: false, payload: nil, latencyMS: nil, error: nil)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        // The probe result must reflect the current reality: hitting a URL cache could make a “service down” appear as “connected”.
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // The probe must not leave a keep‑alive connection on the server, otherwise the connection pool would be counted as “service alive”.
        req.setValue("close", forHTTPHeaderField: "Connection")

        let started = Date()
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return PortProbe(
                responded: true,
                payload: try? JSONDecoder().decode(HealthPayload.self, from: data),
                latencyMS: ms,
                error: nil
            )
        } catch {
            return PortProbe(responded: false, payload: nil, latencyMS: nil, error: error)
        }
    }

    /// Translate `URLError` into a single sentence that tells the user what to do.
    /// Throwing `localizedDescription` directly yields a system‑style English message that doesn’t indicate the next step.
    private static func describe(_ error: Error?) -> String {
        guard let urlError = error as? URLError else {
            return error?.localizedDescription ?? L10n.ASR.verifyFailed
        }
        switch urlError.code {
        case .timedOut:
            return L10n.ASR.localProbeTimeout
        case .cannotConnectToHost:
            return L10n.ASR.localProbeRefused
        case .cannotFindHost, .dnsLookupFailed:
            return L10n.ASR.localProbeBadHost
        case .notConnectedToInternet, .networkConnectionLost, .cannotLoadFromNetwork:
            return L10n.ASR.localProbeOffline
        default:
            return urlError.localizedDescription
        }
    }

    // MARK: - parsing

    private func parse(_ data: Data) throws -> AsrResult {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        var segments: [AsrSegment] = []
        for s in envelope.segments ?? [] {
            let start = s.start ?? 0
            let end = s.end ?? start
            segments.append(AsrSegment(
                speaker: nil,
                text: s.text ?? "",
                start: start,
                end: end,
                duration: s.duration ?? max(0, end - start)
            ))
        }
        let full = envelope.text
            ?? segments.map(\.text).joined(separator: " ")
        if segments.isEmpty && full.isEmpty { throw AsrError.empty }
        // Use the language **detected by the server**, not the locale used during construction.
        // Previously this fell back to `locale` (the initializer’s default is "en-US"), and
        // `TranscriptionProvider` calling `LocalASR(host:port:)` does not pass a locale —
        // so a purely Chinese recording ended up with `"locale": "en-US"` in the output.
        // Azure’s path uses `locales?.first ?? "auto"`; the local implementation should behave the same.
        let detected = envelope.language.flatMap { $0.isEmpty ? nil : $0 }
        return AsrResult(text: full, segments: segments, provider: "local", locale: detected ?? locale)
    }
}
