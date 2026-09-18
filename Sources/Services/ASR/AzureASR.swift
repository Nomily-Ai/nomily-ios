import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr.azure")

/// Azure Fast Transcription REST adapter.
/// POSTs the audio payload as multipart/form-data with a JSON `definition`
/// part (diarization on, max 10 speakers) and reads the `phrases[]`
/// response into a normalized `AsrResult`.
struct AzureASR {
    var key: String
    var region: String
    /// Candidate source locales. `nil` (or empty) omits the key from the
    /// request, which triggers Azure's multi-language auto-detect across
    /// its 15-locale auto set. When non-empty, Azure narrows detection to
    /// just the listed locales and tags each phrase with the chosen one.
    var locales: [String]?

    init(key: String, region: String, locales: [String]? = nil) {
        self.key = key
        self.region = region
        if let locales, !locales.isEmpty {
            self.locales = Array(locales.prefix(10))
        } else {
            self.locales = nil
        }
    }

    func transcribe(fileURL: URL) async throws -> AsrResult {
        guard !key.isEmpty, !region.isEmpty else {
            throw AsrError.missingCredentials("Azure")
        }
        let data = try Data(contentsOf: fileURL)
        return try await transcribe(data: data, filename: fileURL.lastPathComponent)
    }

    func transcribe(data: Data, filename: String) async throws -> AsrResult {
        let endpoint = URL(string:
            "https://\(region).api.cognitive.microsoft.com/speechtotext/transcriptions:transcribe?api-version=2025-10-15"
        )!

        let boundary = "----nomily-\(UUID().uuidString)"
        var definition: [String: Any] = [
            "profanityFilterMode": "None",
            "diarization": [
                "enabled": true,
                "maxSpeakers": 10,
            ],
        ]
        // Omit `locales` entirely when nil/empty — Azure treats that as
        // multi-language auto-detect against its 15-locale auto set. Passing
        // `locales: []` is valid per Azure docs but we prefer omission for
        // forward-compat with their examples.
        if let locales, !locales.isEmpty {
            definition["locales"] = locales
        }
        let definitionData = try JSONSerialization.data(withJSONObject: definition)

        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"definition\"\r\n")
        body.appendString("Content-Type: application/json\r\n\r\n")
        body.append(definitionData)
        body.appendString("\r\n--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(contentType(for: filename))\r\n\r\n")
        body.append(data)
        body.appendString("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600

        let localesJoined = (locales ?? []).joined(separator: ",")
        log.info("transcribe start filename=\(filename, privacy: .public) bytes=\(data.count) locales=\(localesJoined.isEmpty ? "auto" : localesJoined, privacy: .public)")

        let (respData, response): (Data, URLResponse)
        do {
            (respData, response) = try await URLSession.shared.upload(for: req, from: body)
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
        var phrases: [Phrase]?
        var combinedPhrases: [Combined]?
        var durationMilliseconds: Int?
    }
    private struct Phrase: Decodable {
        var offsetMilliseconds: Int?
        var durationMilliseconds: Int?
        var text: String?
        var speaker: Int?
    }
    private struct Combined: Decodable {
        var text: String?
        var speaker: Int?
    }

    private func parse(_ data: Data) throws -> AsrResult {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        var segments: [AsrSegment] = []
        for p in envelope.phrases ?? [] {
            let offsetMs = p.offsetMilliseconds ?? 0
            let durMs = p.durationMilliseconds ?? 0
            segments.append(AsrSegment(
                speaker: p.speaker.map(String.init),
                text: p.text ?? "",
                start: round(Double(offsetMs)) / 1000,
                end: round(Double(offsetMs + durMs)) / 1000,
                duration: round(Double(durMs)) / 1000
            ))
        }
        if segments.isEmpty {
            for cp in envelope.combinedPhrases ?? [] {
                guard let text = cp.text, !text.isEmpty else { continue }
                let dur = Double(envelope.durationMilliseconds ?? 0) / 1000
                segments.append(AsrSegment(
                    speaker: cp.speaker.map(String.init),
                    text: text,
                    start: 0, end: dur, duration: dur
                ))
            }
        }
        if segments.isEmpty { throw AsrError.empty }
        let full = segments.map(\.text).joined(separator: " ")
        return AsrResult(text: full, segments: segments, provider: "azure", locale: locales?.first ?? "auto")
    }

    private func contentType(for filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".wav") { return "audio/wav" }
        if lower.hasSuffix(".mp3") { return "audio/mpeg" }
        if lower.hasSuffix(".flac") { return "audio/flac" }
        // AAC in an MP4 container — what LocalVAD, AudioMerger and
        // AudioExporter all produce. Declaring these as audio/ogg made
        // Azure pick the Ogg demuxer and reject the upload with
        // 422 InvalidAudioFormat ("could not be decoded with the
        // provided configuration").
        if lower.hasSuffix(".m4a") || lower.hasSuffix(".mp4") { return "audio/mp4" }
        if lower.hasSuffix(".aac") { return "audio/aac" }
        if lower.hasSuffix(".caf") { return "audio/x-caf" }
        // Plain raw Opus frames — Azure also accepts audio/ogg for Ogg-Opus.
        return "audio/ogg"
    }
}

private extension Data {
    mutating func appendString(_ s: String) {
        if let d = s.data(using: .utf8) { append(d) }
    }
}
