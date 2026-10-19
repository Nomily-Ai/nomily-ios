import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr.custom")

/// User-defined ASR service speaking the **OpenAI-compatible**
/// `POST /v1/audio/transcriptions` API — the de-facto standard for self-hosted
/// whisper servers (faster-whisper-server, whisper.cpp `server`, speaches…) and
/// for Whisper-compatible clouds (Groq, Deepinfra, SiliconFlow…).
///
/// Why this shape and not the `local` provider's protocol: the local pair
/// (`/v1/listen` WebSocket + `/v1/transcribe` octet-stream) is Nomily's own
/// ad-hoc server contract, which nobody else implements. `/v1/audio/transcriptions`
/// is what the rest of the world speaks, so "custom" is a drop-in for an
/// existing deployment with zero server-side work.
///
/// Scope: **file transcription only**. Live transcription has no standard, so a
/// custom primary falls back to the on-device recogniser in the live page (the
/// provider chain appends `ondevice` for exactly this reason).
struct CustomASR {
    /// Base URL, e.g. `http://192.168.1.10:8000` or `https://api.groq.com/openai`.
    /// Users may paste the full transcriptions path too — `transcriptionsURL` copes.
    var endpoint: String
    /// Sent as `Authorization: Bearer <key>`; empty = no header (most self-hosted servers).
    var apiKey: String
    /// `model` form field. Defaults to `whisper-1` when unset — every compatible
    /// server accepts it or ignores it.
    var model: String
    /// Optional `language` hint (ISO-639-1, e.g. `zh`); empty = let the server detect.
    var language: String

    init(endpoint: String, apiKey: String = "", model: String = "", language: String = "") {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model.isEmpty ? "whisper-1" : model
        self.language = language
    }

    // MARK: - Transcribe

    func transcribe(fileURL: URL, locales: [String]?) async throws -> AsrResult {
        guard let url = Self.transcriptionsURL(endpoint) else {
            throw AsrError.missingCredentials("Custom server (invalid endpoint)")
        }
        let data = try Data(contentsOf: fileURL)
        let duration = await Self.probeDuration(of: fileURL)
        // Server-detected language wins; the request hint is best-effort.
        let hint = language.isEmpty ? (locales?.first.flatMap(Self.shortCode)) : Self.shortCode(language)

        var form = MultipartForm()
        form.addField(name: "model", value: model)
        form.addField(name: "response_format", value: "verbose_json")
        if let hint { form.addField(name: "language", value: hint) }
        form.addFile(name: "file", filename: fileURL.lastPathComponent,
                     mimeType: fileURL.pathExtension.lowercased() == "wav" ? "audio/wav" : "audio/ogg",
                     data: data)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.uploadTimeout(for: duration)
        req.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        log.info("custom transcribe \(url.absoluteString, privacy: .public) bytes=\(data.count) model=\(model, privacy: .public) hint=\(hint ?? "-", privacy: .public)")

        let (respData, response): (Data, URLResponse)
        do {
            (respData, response) = try await URLSession.shared.upload(for: req, from: form.body)
        } catch {
            throw AsrError.transport(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= status else {
            throw AsrError.http(status, String(data: respData.prefix(400), encoding: .utf8) ?? "")
        }
        let result = try Self.parse(respData, provider: "custom", fallbackLocale: hint ?? "auto")
        log.info("custom transcribe done segments=\(result.segments.count) chars=\(result.text.count)")
        return result
    }

    // MARK: - Endpoint normalisation

    /// Accepts every shape a user is likely to paste and lands on the transcriptions path:
    ///
    /// | pasted | produced |
    /// |---|---|
    /// | `http://h:8000` | `http://h:8000/v1/audio/transcriptions` |
    /// | `http://h:8000/` | same |
    /// | `http://h:8000/v1` | `http://h:8000/v1/audio/transcriptions` |
    /// | `http://h:8000/v1/audio/transcriptions` | unchanged |
    /// | `http://h:8000/openai/v1` | `http://h:8000/openai/v1/audio/transcriptions` |
    static func transcriptionsURL(_ raw: String) -> URL? {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        if base.lowercased().hasSuffix("/audio/transcriptions") {
            // Already the full path (user copied it from API docs).
        } else if base.lowercased().hasSuffix("/v1") {
            base += "/audio/transcriptions"
        } else {
            base += "/v1/audio/transcriptions"
        }
        return URL(string: base)
    }

    // MARK: - Response

    /// `verbose_json` from the OpenAI-compatible family. Every field optional:
    /// minimal servers return just `{"text": "…"}`.
    private struct Envelope: Decodable {
        var text: String?
        var language: String?
        var segments: [Segment]?
        struct Segment: Decodable {
            var text: String?
            var start: Double?
            var end: Double?
        }
    }

    static func parse(_ data: Data, provider: String, fallbackLocale: String) throws -> AsrResult {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw AsrError.decoding(error)
        }
        var segments: [AsrSegment] = []
        for s in envelope.segments ?? [] {
            let start = s.start ?? 0
            let end = s.end ?? start
            segments.append(AsrSegment(
                speaker: nil,
                text: s.text ?? "",
                start: start,
                end: end,
                duration: max(0, end - start)
            ))
        }
        let full = envelope.text ?? segments.map(\.text).joined(separator: " ")
        if segments.isEmpty && full.isEmpty { throw AsrError.empty }
        let detected = envelope.language.flatMap { $0.isEmpty ? nil : $0 }
        return AsrResult(text: full, segments: segments, provider: provider,
                         locale: detected ?? fallbackLocale)
    }

    // MARK: - Settings probe

    struct ProbeResult {
        var ok: Bool
        var detail: String?
        var error: String?
    }

    /// "Is this server reachable and is the key accepted?"
    ///
    /// `GET {base}/models` is part of the OpenAI-compatible surface and every
    /// implementation has it. Any HTTP response proves reachability; 200 proves the
    /// key too; 401/403 means "server fine, key wrong" — reported distinctly because
    /// that is a different fix (fix the key, not the network).
    static func probe(endpoint: String, apiKey: String, timeout: TimeInterval = 6) async -> ProbeResult {
        guard var base = normalizedBase(endpoint), let root = URL(string: base) else {
            return ProbeResult(ok: false, detail: nil, error: L10n.ASR.localProbeNoHost)
        }
        base = root.deletingLastPathComponent().appendingPathComponent("models").absoluteString
        // ^ `/v1/audio/transcriptions` → `/v1/models`; a bare host would lose nothing
        //   because `normalizedBase` guarantees a path we can walk up from.
        guard let url = URL(string: base) else {
            return ProbeResult(ok: false, detail: nil, error: L10n.ASR.localProbeNoHost)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return ProbeResult(ok: true, detail: "\(url.host ?? "") · \(status)", error: nil)
            case 401, 403:
                return ProbeResult(ok: false, detail: nil, error: L10n.ASR.customProbeAuth)
            default:
                // Reached *something* HTTP — reachable, but not an OpenAI-compatible API.
                return ProbeResult(ok: false, detail: nil,
                                   error: L10n.ASR.customProbeHTTP(status))
            }
        } catch {
            return ProbeResult(ok: false, detail: nil, error: error.localizedDescription)
        }
    }

    /// Strip scheme/path noise the way `LocalASR.normalizedHost` does, but keep the path
    /// (`https://api.groq.com/openai/v1` must stay one base).
    static func normalizedBase(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        return s
    }

    /// `zh-CN` → `zh` (the API takes ISO-639-1; passing a full locale makes strict
    /// servers 400).
    static func shortCode(_ locale: String) -> String? {
        let code = locale.split(separator: "-").first.map(String.init) ?? locale
        return code.isEmpty ? nil : code
    }

    // MARK: - Multipart

    /// Minimal `multipart/form-data` writer — URLSession has no built-in, and pulling
    /// a dependency for 30 lines is not worth it.
    struct MultipartForm {
        let boundary = "nomily-asr-\(UUID().uuidString)"
        private(set) var body = Data()

        mutating func addField(name: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }

        mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
            body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
    }

    // MARK: - Helpers shared with LocalASR

    /// Same reasoning as `LocalASR.uploadTimeout`: cloud/self-hosted whisper is
    /// roughly real-time or better, but queues happen; 3× with a 600 s floor keeps
    /// "the app looks frozen" away without hanging forever.
    static func uploadTimeout(for duration: TimeInterval?) -> TimeInterval {
        guard let duration, duration.isFinite, duration > 0 else { return 600 }
        return max(600, duration * 3)
    }

    private static func probeDuration(of url: URL) async -> TimeInterval? {
        if let probed = OpusOgg.duration(ofOggOpusAt: url), probed > 0 {
            return probed
        }
        let asset = AVURLAsset(url: url)
        if let loaded = try? await asset.load(.duration), loaded.isValid {
            let seconds = loaded.seconds
            if seconds.isFinite, seconds > 0 { return seconds }
        }
        return nil
    }
}
