import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "plaud.live-asr.azure")

/// Azure Speech **raw-PCM** live transcription for the PLAUD card.
///
/// ## Why a second Azure client instead of `AzureLiveASR`
/// `AzureLiveASR` wraps the card's Opus packets into Ogg pages and declares
/// `audio/ogg;codecs=opus`. The PLAUD card never gives us Opus — the SDK's
/// sync-file channel hands over decoded 16 kHz mono PCM, and this platform has
/// no PCM→Opus encoder (`AudioConverter` + `kAudioFormatOpus` is broken, see the
/// A1 notes). Azure accepts PCM directly, so the fix is a variant of the same
/// WebSocket protocol that declares
/// `audio/wav; codecs=audio/pcm; samplerate=16000` and opens the stream with a
/// 44-byte WAV header.
///
/// ## Protocol (same shape as `AzureLiveASR`)
/// * `wss://{region}.stt.speech.microsoft.com/speech/recognition/conversation/
///   cognitiveservices/v1?language={lang}&format=detailed`
/// * `speech.config` text frame, then binary audio frames
///   (`[2-byte header length][headers][payload]`)
/// * replies: `speech.hypothesis` (partial text) and `speech.phrase` (final,
///   with `Offset`/`Duration` in 100-ns ticks — real timestamps, which the
///   on-device engine cannot give us).
final class PlaudAzureLiveTranscriber: PlaudLiveASR {

    private(set) var segments: [PlaudLiveSegment] = []
    private(set) var partial = ""
    private(set) var unavailable: PlaudLiveASRUnavailable?
    let providerName = "azure"
    var onTextChange: (() -> Void)?
    var onFailure: ((PlaudLiveASRUnavailable) -> Void)?

    private let key: String
    private let region: String
    private let lang: String
    private let requestId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    /// PCM waiting to be sent. Flushed in ~100 ms batches: one WebSocket message
    /// per 20 ms block would be 50 messages/s of pure overhead.
    ///
    /// Guarded by `lock`: `append` runs on the SDK's BLE queue while `stop` and
    /// `reset` run on the main thread.
    private let lock = NSLock()
    private var pending = Data()
    private var sentHeader = false
    private var closed = false
    /// Card clock at the first block — Azure's `Offset` is measured from the
    /// start of the stream, so this is what turns it into a take timestamp.
    private var clockOrigin: TimeInterval?

    private static let flushBytes = 3_200        // ≈100 ms of 16 kHz/16-bit mono
    private static let sampleRate: UInt32 = 16_000
    /// How long to keep the socket open after the take stops, so the last phrase
    /// can still come back.
    private static let drainSeconds: TimeInterval = 0.8

    init(key: String, region: String, lang: String) {
        self.key = key
        self.region = region
        self.lang = lang
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 0
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Lifecycle

    func start() {
        guard !key.isEmpty, !region.isEmpty else {
            unavailable = .azureMissing
            log.info("plaud azure live: missing key/region")
            return
        }
        let urlString = "wss://\(region).stt.speech.microsoft.com"
            + "/speech/recognition/conversation/cognitiveservices/v1"
            + "?language=\(lang)&format=detailed"
        guard let url = URL(string: urlString) else {
            unavailable = .azureFailed("invalid region")
            return
        }
        closed = false
        log.info("plaud azure live connecting \(url.absoluteString, privacy: .public)")
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()

        socket.send(.string(textMessage(path: "speech.config", body: [
            "context": [
                "system": ["name": "nomily", "version": "1.0"],
                "os": ["platform": "iOS", "name": "ARM"],
                "audio": ["source": ["connectivity": "Bluetooth"]]
            ]
        ]))) { error in
            if let error {
                log.warning("plaud azure live: speech.config failed \(error.localizedDescription, privacy: .public)")
            }
        }
        startReceiveLoop()
    }

    func stop() {
        lock.lock()
        let alreadyClosed = closed
        lock.unlock()
        guard !alreadyClosed else { return }
        flush(force: true)
        // Wait briefly before closing: Azure answers the trailing phrase a few
        // hundred milliseconds after the last audio, and cutting the socket now
        // drops exactly the sentence the user just finished saying.
        let socket = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.drainSeconds) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let wasClosed = self.closed
            self.closed = true
            self.lock.unlock()
            guard !wasClosed else { return }
            socket?.cancel(with: .goingAway, reason: nil)
            self.task = nil
            self.receiveTask?.cancel()
            self.receiveTask = nil
            self.session.invalidateAndCancel()
            log.info("plaud azure live closed")
        }
    }

    func reset() {
        segments = []
        partial = ""
        lock.lock()
        clockOrigin = nil
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        publish()
    }

    func append(_ pcm: Data, elapsed: TimeInterval) {
        lock.lock()
        guard !closed, !pcm.isEmpty else { lock.unlock(); return }
        if clockOrigin == nil { clockOrigin = elapsed }
        pending.append(pcm)
        let shouldFlush = pending.count >= Self.flushBytes
        lock.unlock()
        if shouldFlush { flush(force: false) }
    }

    // MARK: - Sending

    private func flush(force: Bool) {
        lock.lock()
        guard let socket = task, !closed, !pending.isEmpty else { lock.unlock(); return }
        guard force || pending.count >= Self.flushBytes else { lock.unlock(); return }
        let chunk = pending
        pending.removeAll(keepingCapacity: true)
        var payload = chunk
        if !sentHeader {
            // Azure needs the WAV header on the first audio frame; the length
            // fields stay 0xFFFFFFFF because the take has no known end yet.
            payload = Self.wavHeader() + chunk
            sentHeader = true
        }
        lock.unlock()
        socket.send(.data(audioMessage(payload))) { error in
            if let error {
                log.warning("plaud azure live: audio send failed \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Receiving

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            while let self, !Task.isCancelled, let socket = self.task {
                do {
                    let message = try await socket.receive()
                    self.handle(message)
                } catch {
                    if !self.closed {
                        log.info("plaud azure live recv ended: \(error.localizedDescription, privacy: .public)")
                        self.unavailable = .azureFailed(error.localizedDescription)
                        self.onFailure?(.azureFailed(error.localizedDescription))
                    }
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message else { return }
        let parts = text.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 2 else { return }
        let headers = parts[0]
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if headers.contains("speech.hypothesis") {
            if let text = json["Text"] as? String, !text.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.partial != text else { return }
                    self.partial = text
                    self.publish()
                }
            }
        } else if headers.contains("speech.phrase") {
            guard (json["RecognitionStatus"] as? String) == "Success" else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.partial.isEmpty else { return }
                    self.partial = ""
                    self.publish()
                }
                return
            }
            let text = (json["DisplayText"] as? String)
                ?? (json["NBest"] as? [[String: Any]])?.first?["Display"] as? String
                ?? ""
            guard !text.isEmpty else { return }
            // Azure reports `Offset`/`Duration` in 100-ns ticks from the stream
            // start; add the card clock we saw on the first block.
            let offsetTicks = (json["Offset"] as? Double) ?? 0
            lock.lock()
            let origin = clockOrigin
            lock.unlock()
            let at = (origin ?? 0) + offsetTicks / 10_000_000
            let line = PlaudLiveSegment(text: text, at: at)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.segments.last?.text != text { self.segments.append(line) }
                self.partial = ""
                self.publish()
            }
        }
    }

    private func publish() {
        onTextChange?()
    }

    // MARK: - Framing

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
            + "Content-Type: application/json; charset=utf-8\r\n"
            + "\r\n"
            + json
    }

    private func audioMessage(_ audio: Data) -> Data {
        let header = "Path: audio\r\n"
            + "X-RequestId: \(requestId)\r\n"
            + "X-Timestamp: \(timestamp())\r\n"
            // ★ This is what makes Azure interpret the bytes as 16 kHz PCM
            // instead of Ogg/Opus (the whole reason this class exists).
            + "Content-Type: audio/wav; codecs=audio/pcm; samplerate=16000"
        let headerBytes = Data(header.utf8)
        var msg = Data(capacity: headerBytes.count + audio.count + 2)
        msg.append(UInt8((headerBytes.count >> 8) & 0xFF))
        msg.append(UInt8(headerBytes.count & 0xFF))
        msg.append(headerBytes)
        msg.append(audio)
        return msg
    }

    /// 44-byte RIFF/WAVE header for 16 kHz mono 16-bit, unknown length.
    private static func wavHeader() -> Data {
        let byteRate = sampleRate * 2
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(le32(0xFFFF_FFFF))
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        header.append(le32(16))          // fmt chunk size
        header.append(le16(1))           // PCM
        header.append(le16(1))           // mono
        header.append(le32(sampleRate))
        header.append(le32(byteRate))
        header.append(le16(2))           // block align
        header.append(le16(16))          // bits per sample
        header.append(contentsOf: Array("data".utf8))
        header.append(le32(0xFFFF_FFFF))
        return header
    }

    private static func le16(_ value: UInt16) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 2)
    }

    private static func le32(_ value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }
}
