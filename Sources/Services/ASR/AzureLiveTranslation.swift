import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr.azure.translate")

/// Real-time speech translation via Azure Speech Translation WebSocket.
///
/// Uses `wss://{region}.s2s.speech.microsoft.com/speech/translation/stts/v1`
/// with `from` (source language) and `to` (target language) parameters.
/// Audio framing is identical to `AzureLiveASR` (OGG-Opus pages).
/// Responses carry both source-language recognition and target-language
/// translation in every event.
@MainActor
final class AzureLiveTranslation {
    struct BilingualText: Equatable {
        let source: String
        let translation: String
    }

    enum Event {
        case partial(BilingualText)
        case final(BilingualText)
        case closed(Error?)
    }

    let key: String
    let region: String
    let fromLang: String
    let toLang: String

    private let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<Event>.Continuation?
    private var closed = false

    private let serial: UInt32 = OpusOgg.defaultSerial
    private var pageSeq: UInt32 = 2
    private var granule: Int64 = Int64(OpusOgg.preSkip)
    private var frameBuf: [Data] = []
    private static let framesPerPage = 10

    init(key: String, region: String, fromLang: String = "en-US", toLang: String = "en") {
        self.key = key
        self.region = region
        self.fromLang = fromLang
        self.toLang = toLang
        let cfg = URLSessionConfiguration.default
        // Streaming receive: tolerate long speech pauses without the
        // socket timing out (30s dropped mid-silence — ddxrq1r). A real
        // drop still surfaces as a close and LiveModel reconnects.
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 0
        self.session = URLSession(configuration: cfg)
    }

    func connect() throws -> AsyncStream<Event> {
        guard !key.isEmpty, !region.isEmpty else {
            throw AsrError.missingCredentials("Azure")
        }
        let urlString = "wss://\(region).stt.speech.microsoft.com"
            + "/speech/translation/cognitiveservices/v1"
            + "?from=\(fromLang)&to=\(toLang)&api-version=1.0"
        guard let url = URL(string: urlString) else {
            throw AsrError.missingCredentials("Azure (invalid region)")
        }

        log.info("connecting \(url.absoluteString, privacy: .public)")
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-ConnectionId")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()

        let configMsg = textMessage(path: "speech.config", body: [
            "context": [
                "system": ["name": "dnote", "version": "1.0"],
                "os": ["platform": "iOS", "name": "ARM"],
                "audio": ["source": ["connectivity": "Bluetooth"]],
            ]
        ])
        task.send(.string(configMsg)) { error in
            if let error {
                log.warning("speech.config send failed: \(String(describing: error), privacy: .public)")
            }
        }

        sendOggHeaders()

        var capturedContinuation: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event>(bufferingPolicy: .unbounded) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
        startReceiveLoop()
        return stream
    }

    func send(_ data: Data) {
        guard task != nil, !closed else { return }
        var offset = 0
        while offset + OpusOgg.frameSize <= data.count {
            frameBuf.append(data.subdata(in: offset..<(offset + OpusOgg.frameSize)))
            if frameBuf.count >= Self.framesPerPage {
                flushFrames()
            }
            offset += OpusOgg.frameSize
        }
        if offset < data.count {
            frameBuf.append(data.subdata(in: offset..<data.count))
            if frameBuf.count >= Self.framesPerPage {
                flushFrames()
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        log.info("closing azure translation stream")
        flushFrames()
        // Cancel the task immediately rather than dispatching cancel inside a
        // `send` completion — the async hop lets the old URLSession linger
        // past our visible teardown, and a following `connect()` on a fresh
        // instance can collide with the in-flight cancel signal and surface
        // as "socket not connected" on the new receive loop.
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        receiveTask?.cancel()
        receiveTask = nil
        continuation?.yield(.closed(nil))
        continuation?.finish()
        continuation = nil
        session.invalidateAndCancel()
    }

    // MARK: - OGG streaming

    private func sendOggHeaders() {
        let headers = OpusOgg.oggHeaders(serial: serial)
        let msg = audioMessage(headers)
        task?.send(.data(msg)) { error in
            if let error {
                log.warning("ogg header send failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func flushFrames() {
        guard !frameBuf.isEmpty, let task else { return }
        let frames = frameBuf
        frameBuf = []
        for _ in frames {
            granule &+= Int64(OpusOgg.samplesPerFrame)
        }
        let page = OpusOgg.audioPage(
            serial: serial, pageSeq: pageSeq, granule: granule, frames: frames)
        pageSeq &+= 1
        let msg = audioMessage(page)
        task.send(.data(msg)) { error in
            if let error {
                log.warning("audio page send failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Azure protocol framing

    private func timestamp() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: Date())
    }

    private func textMessage(path: String, body: [String: Any]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: body))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "Path: \(path)\r\n"
            + "X-RequestId: \(requestId)\r\n"
            + "X-Timestamp: \(timestamp())\r\n"
            + "Content-Type: application/json\r\n"
            + "\r\n"
            + json
    }

    private func audioMessage(_ audioData: Data) -> Data {
        let header = "Path: audio\r\n"
            + "X-RequestId: \(requestId)\r\n"
            + "X-Timestamp: \(timestamp())\r\n"
            + "Content-Type: audio/ogg;codecs=opus"
        let headerBytes = Data(header.utf8)
        var msg = Data()
        msg.append(UInt8((headerBytes.count >> 8) & 0xFF))
        msg.append(UInt8(headerBytes.count & 0xFF))
        msg.append(headerBytes)
        msg.append(audioData)
        return msg
    }

    // MARK: - receive loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let task = self.task else { break }
                do {
                    let message = try await task.receive()
                    self.handle(message)
                } catch {
                    if !self.closed {
                        log.info("azure translation ws recv ended: \(String(describing: error), privacy: .public)")
                    }
                    self.reportClosed(error)
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            let parts = text.components(separatedBy: "\r\n\r\n")
            guard parts.count >= 2 else { return }
            let headers = parts[0]
            let body = parts.dropFirst().joined(separator: "\r\n\r\n")

            guard let data = body.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            if headers.contains("translation.hypothesis") || headers.contains("speech.hypothesis") {
                let bilingual = parseBilingual(json)
                if !bilingual.source.isEmpty || !bilingual.translation.isEmpty {
                    continuation?.yield(.partial(bilingual))
                }
            } else if headers.contains("translation.phrase") || headers.contains("speech.phrase") {
                let status = json["RecognitionStatus"] as? String ?? ""
                if status == "Success" {
                    let bilingual = parseBilingual(json)
                    if !bilingual.source.isEmpty || !bilingual.translation.isEmpty {
                        continuation?.yield(.final(bilingual))
                    }
                }
                if status != "Success" {
                    log.info("phrase status: \(status, privacy: .public)")
                }
            } else if headers.contains("turn.end") {
                log.debug("turn.end")
            }
        case .data:
            break
        @unknown default:
            break
        }
    }

    private func parseBilingual(_ json: [String: Any]) -> BilingualText {
        let source = (json["DisplayText"] as? String)
            ?? (json["Text"] as? String)
            ?? ""
        var translated = ""
        if let translation = json["Translation"] as? [String: Any],
           let translations = translation["Translations"] as? [[String: Any]],
           let first = translations.first {
            translated = (first["DisplayText"] as? String)
                ?? (first["Text"] as? String)
                ?? ""
        }
        return BilingualText(source: source, translation: translated)
    }

    private func reportClosed(_ error: Error?) {
        guard !closed else { return }
        closed = true
        continuation?.yield(.closed(error))
        continuation?.finish()
        continuation = nil
    }
}
