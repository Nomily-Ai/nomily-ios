import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr.live")

/// Live streaming adapter for the local faster-whisper server:
///
/// * Opens `ws://{host}:{port}/v1/listen` — **not** `port+1`, which is the
///   HTTP batch endpoint that `LocalASR` uses.
/// * Pushes raw OPUS frames as binary WebSocket messages; server
///   reassembles them into 5 s segments.
/// * Receives `{"text": "...", "is_final": bool}` text messages back.
/// * Sends `{"type": "CloseStream"}` as a text frame to finalize; the
///   server flushes any remaining audio and emits a final transcript.
///
/// The server does **not** require an init handshake — audio starts flowing
/// as soon as `URLSessionWebSocketTask.resume()` succeeds.
@MainActor
final class LiveStreamASR {
    enum Event {
        /// Interim transcript, overwrite the "current partial" line.
        case partial(String)
        /// Server committed a segment (5 s boundary or end-of-stream).
        case final(String)
        /// Server closed or transport errored.
        case closed(Error?)
    }

    let host: String
    let port: Int

    /// ★★★ This device's Opus packetization method (added on 2026-10-12).
    ///
    /// ## ⚠️ This is the basis for "sending entire packets only" on this path, not the encapsulation parameters
    /// The local service receives **raw bytes** (without an Ogg container), so packet boundaries can only be inferred by
    /// **fixed packet length** — that is: **the server's expected packet length must match this value**.
    ///
    /// D·NOTE is 40 B (consistent with the existing server, zero behavioral change); TicNote is 160 B,
    /// **not verified on real devices** (server code is not in this repository). Therefore, for TicNote real-time transcription,
    /// prioritize using Azure (that path encapsulates Ogg itself, with packet length written in OggHead/page tables, not relying on server guessing);
    /// if garbled output occurs when using the local service, the root cause is likely here, not the audio itself.
    let profile: OpusOgg.Profile

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<Event>.Continuation?
    private var closed = false
    /// The tail that doesn't fill a complete packet is left to be concatenated with the next batch (reason above: raw byte streams cannot send half-packets).
    private var pendingTail = Data()

    init(host: String, port: Int, profile: OpusOgg.Profile = .dnote) {
        self.host = host
        self.port = port
        self.profile = profile
        let cfg = URLSessionConfiguration.default
        // Streaming receive: tolerate long speech pauses without the
        // socket timing out (30s dropped mid-silence — ddxrq1r). A real
        // drop still surfaces as a close and LiveModel reconnects.
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 0  // indefinite — streaming
        self.session = URLSession(configuration: cfg)
    }

    /// Open the WebSocket and return an event stream.
    func connect() throws -> AsyncStream<Event> {
        guard !host.isEmpty, port > 0 else {
            throw AsrError.missingCredentials("Local server")
        }
        guard let url = URL(string: "ws://\(host):\(port)/v1/listen") else {
            throw AsrError.missingCredentials("Local server (invalid host)")
        }
        log.info("connecting \(url.absoluteString, privacy: .public)")
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        var capturedContinuation: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event>(bufferingPolicy: .unbounded) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
        startReceiveLoop()
        return stream
    }

    /// Send one OPUS chunk. Fire-and-forget — errors surface through
    /// the event stream from the receive side.
    ///
    /// ★ 2026-10-12: Changed to **send only complete packets**. Raw byte streams have no container, so the server can only cut frames by
    /// fixed packet length — sending half-packets would misalign all subsequent packets.
    /// Accumulate tails that don't fill a packet, concatenate them with the next batch before sending (behavior remains unchanged when data is already aligned).
    func send(_ data: Data) {
        guard let task = task, !closed else { return }
        var buf = pendingTail
        pendingTail = Data()
        buf.append(data)
        let packetBytes = profile.packetBytes
        var offset = buf.startIndex
        while offset + packetBytes <= buf.endIndex {
            let packet = Data(buf[offset..<(offset + packetBytes)])
            task.send(.data(packet)) { error in
                if let error = error {
                    log.warning("ws send failed: \(String(describing: error), privacy: .public)")
                }
            }
            offset += packetBytes
        }
        if offset < buf.endIndex {
            pendingTail = Data(buf[offset..<buf.endIndex])
        }
    }

    /// Tell the server to flush the remaining audio and close. Safe to call
    /// multiple times / from error paths — subsequent calls are no-ops.
    func close() {
        guard !closed else { return }
        closed = true
        log.info("closing stream")
        if let task = task {
            task.send(.string("{\"type\":\"CloseStream\"}")) { _ in
                task.cancel(with: .goingAway, reason: nil)
            }
        }
        receiveTask?.cancel()
        continuation?.yield(.closed(nil))
        continuation?.finish()
        continuation = nil
    }

    // MARK: - recv loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let task = self.task else { break }
                do {
                    let message = try await task.receive()
                    self.handle(message)
                } catch {
                    if !self.closed {
                        log.info("ws recv ended: \(String(describing: error), privacy: .public)")
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
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                log.warning("dropping non-JSON text frame")
                return
            }
            let text = (json["text"] as? String) ?? ""
            guard !text.isEmpty else { return }
            let isFinal = (json["is_final"] as? Bool) ?? false
            continuation?.yield(isFinal ? .final(text) : .partial(text))
        case .data:
            // Server only sends JSON text back — ignore any binary echoes.
            break
        @unknown default:
            break
        }
    }

    private func reportClosed(_ error: Error?) {
        guard !closed else { return }
        closed = true
        continuation?.yield(.closed(error))
        continuation?.finish()
        continuation = nil
    }
}
