import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr.live")

/// Live streaming adapter for the local faster-whisper server:
///
/// * Opens `ws://{host}:{port}/v1/listen` — **not** `port+1`, which is the
///   HTTP batch endpoint that `LocalASR` uses.
/// * Pushes raw 40-byte OPUS frames as binary WebSocket messages; server
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

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<Event>.Continuation?
    private var closed = false

    init(host: String, port: Int) {
        self.host = host
        self.port = port
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

    /// Send one OPUS audio chunk. Fire-and-forget — errors surface through
    /// the event stream from the receive side.
    func send(_ data: Data) {
        guard let task = task, !closed else { return }
        task.send(.data(data)) { error in
            if let error = error {
                log.warning("ws send failed: \(String(describing: error), privacy: .public)")
            }
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
