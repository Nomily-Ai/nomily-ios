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
        return try await transcribe(data: data, filename: fileURL.lastPathComponent)
    }

    func transcribe(data: Data, filename: String) async throws -> AsrResult {
        guard let endpoint = URL(string: "http://\(host):\(port + 1)/v1/transcribe") else {
            throw AsrError.missingCredentials("Local server (invalid host)")
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600

        log.info("transcribe start filename=\(filename, privacy: .public) bytes=\(data.count) host=\(self.host, privacy: .public):\(self.port + 1, privacy: .public)")

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

    // MARK: - parsing

    private struct Envelope: Decodable {
        var segments: [Segment]?
        var text: String?
    }
    private struct Segment: Decodable {
        var text: String?
        var start: Double?
        var end: Double?
        var duration: Double?
    }

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
        return AsrResult(text: full, segments: segments, provider: "local", locale: locale)
    }
}
