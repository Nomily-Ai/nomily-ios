import CryptoKit
import Foundation
import os

/// Aliyun NLS **实时语音识别** (real-time speech recognition over WebSocket).
///
/// ## Why this exists
/// Until 2026-10-23 live captions could only run on Azure / the whisper servers /
/// on-device: every Aliyun-class vendor we support was file-only. Aliyun *does*
/// have a streaming endpoint — it is just a separate product from 录音文件识别 —
/// and the user already holds the credentials (same AccessKey + project Appkey),
/// so it is the shortest path to a domestic live engine.
///
/// ## Protocol (verified against the current docs, 2026-10-23)
/// * Token: `CreateToken` on `nls-meta` (RPC/HMAC-SHA1). **`SignatureVersion=1.0`
///   is mandatory** — the same trap that broke the file-transcription probe.
/// * `wss://nls-gateway-<region>.aliyuncs.com/ws/v1?token=<token>`
/// * Text frame `StartTranscription`, header =
///   `{appkey, message_id, task_id, namespace:"SpeechTranscriber",
///   name:"StartTranscription"}`; payload =
///   `{format:"pcm", sample_rate:16000, enable_intermediate_result:true, …}`.
///   `message_id` / `task_id` must be 32 **hex** chars — a dashed UUID is
///   rejected with `40000002 Gateway:MESSAGE_INVALID`.
/// * Binary frames carry **16 kHz mono 16-bit LE PCM** in ~100 ms chunks
///   (3 200 B) — what the PLAUD SDK hands over directly, and what our Opus
///   decoder produces for TicNote.
/// * Text events: `TranscriptionStarted`, `SentenceBegin`,
///   `TranscriptionResultChanged` (partial), `SentenceEnd` (final),
///   `TranscriptionCompleted`, `TaskFailed`. `StopTranscription` also needs
///   `appkey` in its header.
///
/// End-to-end verified against the live gateway on 2026-10-23 (synthesised
/// Chinese speech → partials → `SentenceEnd` → `TranscriptionCompleted`).
///
/// The language is **not** a request parameter — it is fixed by the project's
/// model in the NLS console.
final class AliyunRealtimeClient {

    enum Event {
        case ready
        case partial(String)
        case final(String)
        case failed(String)
        case closed
    }

    private let accessKeyId: String
    private let accessKeySecret: String
    private let appKey: String
    private let region: String

    /// Serialises socket writes and the pending-buffer bookkeeping: `send` is
    /// called from the BLE/decode queues, `stop` from the main thread.
    private let queue = DispatchQueue(label: "com.nomily.aliyun.rt", qos: .userInitiated)
    private let log = Logger(subsystem: "com.nomily.app", category: "ASR-Aliyun-RT")

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveLoop: Task<Void, Never>?
    private var ready = false
    private var closed = false
    private var pending = Data()
    private var batchesSent = 0
    private var token: String?
    /// `stop()` was called and we are waiting for `TranscriptionCompleted`.
    private var awaitingCompletion = false
    private var emittedClosed = false
    /// Last time audio (real or keep-alive silence) went out — see `startKeepAlive`.
    private var lastAudioAt = Date()
    private var keepAlive: DispatchSourceTimer?

    /// Stable for the whole session — NLS requires every instruction of one
    /// recognition task to reuse the same `task_id`, and rejects a missing one
    /// with `Gateway:MESSAGE_INVALID:Invalid task id 'null'!`.
    private let taskID = AliyunRealtimeClient.hexID()

    var onEvent: ((Event) -> Void)?

    /// 100 ms of 16 kHz/16-bit mono — Aliyun's documented frame granularity.
    private static let flushBytes = 3_200
    private static let sampleRate = 16_000
    /// 30 s of audio — a ceiling for the "socket not ready yet" buffer so a dead
    /// network cannot grow it without bound.
    private static let maxBufferedBytes = 960_000

    /// NLS wants **32 hex chars, no hyphens**, for both `message_id` and
    /// `task_id` (anything else → `40000002 … Invalid message id`).
    /// Verified against the live gateway on 2026-10-23.
    private static func hexID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The `region` field in the Aliyun credential sheet is used by the **file**
    /// path to build the OSS host (`bucket.<region>.aliyuncs.com`), where
    /// `cn-hangzhou` is perfectly valid — but the NLS realtime gateway only
    /// exists in a few regions. Rather than fail on `nls-gateway-cn-hangzhou`,
    /// anything outside the gateway list is served from Shanghai (the token
    /// endpoint is Shanghai-only anyway).
    private static let gatewayRegions: Set<String> = [
        "cn-shanghai", "cn-beijing", "cn-shenzhen",
    ]

    init(accessKeyId: String, accessKeySecret: String, appKey: String, region: String) {
        self.accessKeyId = accessKeyId
        self.accessKeySecret = accessKeySecret
        self.appKey = appKey
        let raw = region.trimmingCharacters(in: .whitespaces).lowercased()
        self.region = Self.gatewayRegions.contains(raw) ? raw : "cn-shanghai"
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            Task {
                do {
                    let token = try await Self.createToken(
                        accessKeyId: self.accessKeyId, accessKeySecret: self.accessKeySecret)
                    self.queue.async { self.openSocket(token: token) }
                } catch {
                    self.log.error("token failed: \(error.localizedDescription, privacy: .public)")
                    // ★ 2026-10-26: the #1 "实时没文字" suspect lands in the diag
                    // log now — a token refusal means NO engine, silently.
                    TicNoteDiagLog.log("XLATE", "aliyun CreateToken FAILED: \(error.localizedDescription)")
                    self.onEvent?(.failed(error.localizedDescription))
                }
            }
        }
    }

    func send(pcm: Data) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            // Buffer first, socket second: the token round-trip takes a moment,
            // and the audio captured during it is the start of the meeting —
            // dropping it made every take lose its first second.
            self.pending.append(pcm)
            if self.pending.count > Self.maxBufferedBytes {
                self.pending.removeFirst(self.pending.count - Self.maxBufferedBytes)
            }
            guard self.ready, let task = self.task else { return }  // until TranscriptionStarted
            while self.pending.count >= Self.flushBytes {
                let chunk = self.pending.prefix(Self.flushBytes)
                self.pending.removeFirst(Self.flushBytes)
                task.send(.data(Data(chunk))) { [weak self] error in
                    if let error { self?.fail("send: \(error.localizedDescription)") }
                }
                self.batchesSent += 1
                self.lastAudioAt = Date()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            guard let task = self.task else {
                self.session?.invalidateAndCancel()
                self.emitClosed()
                return
            }
            task.send(.string(self.instruction("StopTranscription"))) { _ in }
            // `SentenceEnd` + `TranscriptionCompleted` only land *after*
            // StopTranscription, so closing on a fixed timer risks clipping the
            // last sentence. Close as soon as the server says it is done, with a
            // 3 s ceiling in case the event never comes.
            self.awaitingCompletion = true
            self.queue.asyncAfter(deadline: .now() + 3.0) {
                self.awaitingCompletion = false
                self.emitClosed()
                self.closeSocket()
            }
        }
    }

    private func closeSocket() {
        guard let task = self.task else {
            session?.invalidateAndCancel()
            return
        }
        log.notice("closing ws (batches=\(self.batchesSent))")
        keepAlive?.cancel()
        keepAlive = nil
        task.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        self.task = nil
        receiveLoop?.cancel()
    }

    /// At most one `.closed` per session — the UI uses it to stop the spinner.
    private func emitClosed() {
        guard !emittedClosed else { return }
        emittedClosed = true
        onEvent?(.closed)
    }

    // MARK: - Socket

    private func openSocket(token: String) {
        guard !closed, let url = URL(string:
            "wss://nls-gateway-\(region).aliyuncs.com/ws/v1?token=\(token)") else {
            onEvent?(.failed("bad Aliyun endpoint for region \(region)"))
            return
        }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 0
        let session = URLSession(configuration: cfg)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        log.notice("ws opened region=\(self.region, privacy: .public)")

        receiveLoop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text): self.handle(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                    @unknown default: break
                    }
                } catch {
                    self.queue.async {
                        guard !self.closed else { return }
                        self.log.error("ws closed: \(error.localizedDescription, privacy: .public)")
                        self.onEvent?(.closed)
                    }
                    return
                }
            }
        }

        // StartTranscription after the socket exists; audio is buffered until
        // `TranscriptionStarted` arrives.
        //
        // ★ 2026-10-26 (user: "语音转录的准确性也要优化"): `max_sentence_silence`
        // 500 ms (official range 200–2000, default 800) closes sentences sooner —
        // finals land faster and corrections apply to a shorter span, which both
        // reads as more accurate and shortens the "text rewrites itself" window.
        // Punctuation + ITN were already on; they are what makes output look
        // polished, keep them.
        let start = instruction("StartTranscription", payload: """
        {"format":"pcm","sample_rate":\(Self.sampleRate),\
        "enable_intermediate_result":true,"enable_punctuation_prediction":true,\
        "enable_inverse_text_normalization":true,"max_sentence_silence":500}
        """)
        log.notice("StartTranscription task_id=\(self.taskID, privacy: .public)")
        task.send(.string(start)) { [weak self] error in
            if let error { self?.fail("start: \(error.localizedDescription)") }
        }
    }

    // MARK: - Keep-alive

    /// NLS drops a socket after **10 s without audio**
    /// (`Gateway:IDLE_TIMEOUT … the last directive is 'StartTranscription'`).
    /// With the PLAUD card that window is real: the SDK has to fetch 640 bytes of
    /// header, do its E2EE key exchange and only then emits PCM, and a take can
    /// legitimately pause. Silence keeps the session alive at a negligible cost
    /// (16 kHz mono 16-bit ≈ 32 KB/s *only while it is actually idle*).
    private func startKeepAlive() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 4, repeating: 4)
        timer.setEventHandler { [weak self] in
            guard let self, self.ready, !self.closed, let task = self.task else { return }
            // Real audio already went out recently → nothing to do.
            guard Date().timeIntervalSince(self.lastAudioAt) >= 4 else { return }
            let silence = Data(count: Self.flushBytes)
            task.send(.data(silence)) { [weak self] error in
                if let error { self?.fail("keepalive: \(error.localizedDescription)") }
            }
            self.lastAudioAt = Date()
            self.log.debug("keep-alive silence sent")
        }
        timer.resume()
        keepAlive = timer
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = json["header"] as? [String: Any] else { return }
        let name = header["name"] as? String ?? ""
        let payload = json["payload"] as? [String: Any] ?? [:]
        let result = payload["result"] as? String ?? ""

        switch name {
        case "TranscriptionStarted":
            queue.async { [weak self] in
                guard let self else { return }
                self.ready = true
                self.log.notice("TranscriptionStarted — flushing buffered audio")
                TicNoteDiagLog.log("XLATE", "aliyun TranscriptionStarted (buffered \(self.pending.count)B)")
                self.onEvent?(.ready)
                self.startKeepAlive()
                // Flush anything captured while the handshake was in flight.
                guard let task = self.task else { return }
                while self.pending.count >= Self.flushBytes {
                    let chunk = self.pending.prefix(Self.flushBytes)
                    self.pending.removeFirst(Self.flushBytes)
                    task.send(.data(Data(chunk))) { _ in }
                    self.batchesSent += 1
                    self.lastAudioAt = Date()
                }
            }
        case "TranscriptionResultChanged":
            if !result.isEmpty { onEvent?(.partial(result)) }
        case "SentenceEnd":
            if !result.isEmpty { onEvent?(.final(result)) }
        case "TranscriptionCompleted":
            queue.async { [weak self] in
                guard let self else { return }
                self.emitClosed()
                if self.awaitingCompletion {
                    self.awaitingCompletion = false
                    self.closeSocket()
                }
            }
        case "TaskFailed":
            let why = (header["status_text"] as? String)
                ?? (header["status"] as? String) ?? "TaskFailed"
            // ★ 2026-10-26: gateway refusals (wrong appkey, quota, bad region…)
            // used to vanish between "engine open" and "no text".
            TicNoteDiagLog.log("XLATE", "aliyun TaskFailed: \(why) (batchesSent=\(batchesSent))")
            fail(why)
        default:
            log.debug("unhandled event \(name, privacy: .public)")
        }
    }

    /// Every instruction shares one shape: `appkey`, a fresh `message_id`, the
    /// session `task_id`, `namespace`, and the instruction `name`.
    /// (There is **no** `task:"transcriber"` field — that belongs to a different
    /// vendor's protocol and made the gateway answer `Invalid task id 'null'`.)
    private func instruction(_ name: String, payload: String? = nil) -> String {
        let header = """
        "header":{"appkey":"\(appKey)","message_id":"\(Self.hexID())",\
        "task_id":"\(taskID)","namespace":"SpeechTranscriber","name":"\(name)"}
        """
        guard let payload else { return "{\(header)}" }
        return "{\(header),\"payload\":\(payload)}"
    }

    private func fail(_ why: String) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            // A dead socket must not keep a keep-alive timer firing into it.
            self.closed = true
            self.keepAlive?.cancel()
            self.keepAlive = nil
            self.log.error("aliyun rt failed: \(why, privacy: .public)")
            self.onEvent?(.failed(why))
        }
    }

    // MARK: - Token

    /// `CreateToken` on nls-meta — RPC style HMAC-SHA1, `SignatureVersion=1.0`
    /// (mandatory since Aliyun tightened the API; without it: HTTP 400
    /// "SignatureVersion is mandatory for this action").
    static func createToken(accessKeyId: String, accessKeySecret: String) async throws -> String {
        guard !accessKeyId.isEmpty, !accessKeySecret.isEmpty else {
            throw NSError(domain: "AliyunRT", code: 401, userInfo: [
                NSLocalizedDescriptionKey: L10n.ASRCloud.missingField("AccessKey")])
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"

        let params: [(String, String)] = [
            ("Action", "CreateToken"),
            ("AccessKeyId", accessKeyId),
            ("Format", "JSON"),
            ("SignatureMethod", "HMAC-SHA1"),
            ("SignatureNonce", UUID().uuidString),
            ("SignatureVersion", "1.0"),
            ("Timestamp", formatter.string(from: Date())),
            ("Version", "2019-02-28"),
        ].sorted { $0.0 < $1.0 }

        let canonical = params
            .map { "\(ASRCloudService.aliyunEncode($0.0))=\(ASRCloudService.aliyunEncode($0.1))" }
            .joined(separator: "&")
        let stringToSign = "GET&\(ASRCloudService.aliyunEncode("/"))&\(ASRCloudService.aliyunEncode(canonical))"
        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: Data("\(accessKeySecret)&".utf8)))
        let signature = Data(mac).base64EncodedString()

        guard let url = ASRCloudService.aliyunSignedURL(
            host: "nls-meta.cn-shanghai.aliyuncs.com",
            params: params, signature: signature) else {
            throw NSError(domain: "AliyunRT", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "cannot build the Aliyun token URL"])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (json["Token"] as? [String: Any])?["Id"] as? String,
              !token.isEmpty else {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw NSError(domain: "AliyunRT", code: code, userInfo: [
                NSLocalizedDescriptionKey: "Aliyun token HTTP \(code): \(body)"])
        }
        return token
    }
}
