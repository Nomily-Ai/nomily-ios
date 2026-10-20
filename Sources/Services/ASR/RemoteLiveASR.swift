import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr.remote-live")

/// Live streaming adapter for the **remote secure** faster-whisper service:
/// the same `/v1/listen` + raw-Opus wire protocol as the LAN server
/// (`LiveStreamASR`), but over **WSS with API-key auth**.
///
/// ★ 2026-10-20. Why a separate adapter instead of teaching `LiveStreamASR`
/// about URLs: the two services have opposite security postures, and the
/// settings UI enforces exactly one shape per field —
///
/// | | LAN local (`LiveStreamASR`) | Remote (`RemoteLiveASR`) |
/// |---|---|---|
/// | scheme | `ws://` only | `wss://` only (explicit `ws://` rejected) |
/// | auth | none (trusted LAN / Tailscale) | `Authorization: Bearer <key>` + `X-API-Key` |
/// | TLS | n/a | **default URLSession validation, never disabled** |
/// | key storage | — | Keychain (`SecretStore.Slot.asrRemoteLiveKey`) |
///
/// The key is sent **in handshake headers only** — never in the URL query,
/// which would leak it into server logs and `NSException` dumps. Both
/// `Authorization: Bearer` and `X-API-Key` ride the same handshake: the
/// former is the primary, the latter covers servers whose WS layer can't
/// read `Authorization`.
///
/// ## Error semantics (user asked for more than "连接失败")
/// Connect-time config errors **throw** from `connect()` (bad scheme, missing
/// key). Handshake/transport failures surface as `.closed(error)` events, and
/// a failed WebSocket handshake is **disambiguated by an HTTPS `/health`
/// probe** against the same host: 401/403 → "key invalid", reachable →
/// "path/protocol mismatch", unreachable → "server down". WS handshakes
/// don't expose HTTP status codes, so the probe is the only honest way to
/// tell "wrong key" from "wrong address".
@MainActor
final class RemoteLiveASR {
    /// Same event shape as the LAN adapter — the two servers speak the identical
    /// `/v1/listen` protocol, so the consumer (`LiveModel.runEventLoop`) handles
    /// both with one code path. Deliberately a typealias, not a copy: two structurally
    /// identical enums would drift the moment one side grows a case.
    typealias Event = LiveStreamASR.Event

    /// Classified failures. `LocalizedError` so the live page and the settings
    /// probe can show the real reason without extra mapping.
    enum LiveError: LocalizedError {
        /// Explicit `ws://` (plaintext) or garbage — the remote field is `wss://` only.
        case invalidEndpoint
        /// Remote service requires a key; none configured.
        case missingAPIKey
        /// `/health` answered 401/403 — the key is wrong or missing a scope.
        case unauthorized
        /// Server reachable over HTTPS but the WS upgrade failed (path/protocol).
        case handshakeFailed(String?)
        /// No answer within the request timeout.
        case timeout
        /// Server closed the stream after it was up (overload, restart, idle kick).
        case serverClosed(String?)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:      return L10n.ASR.remoteErrInvalidScheme
            case .missingAPIKey:        return L10n.ASR.remoteErrMissingKey
            case .unauthorized:         return L10n.ASR.remoteErrAuth
            case .handshakeFailed(let detail):
                let base = L10n.ASR.remoteErrHandshake(nil)
                return detail.map { "\(base) (\($0))" } ?? base
            case .timeout:              return L10n.ASR.remoteErrTimeout
            case .serverClosed(let detail):
                let base = L10n.ASR.remoteErrServer
                return detail.map { "\(base) (\($0))" } ?? base
            }
        }
    }

    /// Base endpoint as entered, e.g. `wss://asr.example.com` (may include `/v1/listen`).
    let endpoint: String
    /// Sent in both handshake headers. Never logged — every log line in this
    /// class prints the URL host only.
    let apiKey: String
    /// Same packetization contract as `LiveStreamASR`: the server expects
    /// equal-length raw Opus packets, so the client must send whole packets only.
    let profile: OpusOgg.Profile

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var continuation: AsyncStream<Event>.Continuation?
    private var closed = false
    private var pendingTail = Data()

    init(endpoint: String, apiKey: String, profile: OpusOgg.Profile = .dnote) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.profile = profile
        let cfg = URLSessionConfiguration.default
        // Same posture as LiveStreamASR: long speech pauses must not kill the
        // socket; the handshake phase gets its own shorter watch below.
        cfg.timeoutIntervalForRequest = 180
        cfg.timeoutIntervalForResource = 0
        // TLS certificate validation is URLSession's default and is deliberately
        // left on — no delegate, no `serverTrust` bypass, ever.
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - URL normalization

    /// Accepts the shapes a user pastes and lands on the listen path:
    ///
    /// | pasted | produced |
    /// |---|---|
    /// | `wss://h` | `wss://h/v1/listen` |
    /// | `wss://h/` | same |
    /// | `wss://h/v1/listen` | unchanged |
    /// | `https://h` | `wss://h/v1/listen` (scheme upgraded, never downgraded) |
    /// | `h` | `wss://h/v1/listen` (scheme defaulted to wss) |
    /// | `ws://h` | **nil** — plaintext WebSocket is a LAN-only shape |
    ///
    /// Returns nil for anything that would end up non-`wss`.
    static func listenURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("ws://") { return nil }          // plaintext: reject outright
        if lower.hasPrefix("wss://") {
            // keep as-is
        } else if lower.hasPrefix("https://") {
            s = "wss://" + s.dropFirst("https://".count)
        } else {
            s = "wss://" + s
        }
        if !s.lowercased().hasSuffix("/listen") {
            s += "/v1/listen"
        }
        return URL(string: s)
    }

    /// `wss://h/v1/listen` → `https://h/health` — the diagnostic probe target.
    static func healthURL(_ raw: String) -> URL? {
        guard let listen = listenURL(raw), var comps = URLComponents(url: listen, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = "https"
        comps.path = "/health"
        comps.query = nil
        return comps.url
    }

    // MARK: - Connect

    /// Opens the WSS stream and returns the event stream.
    ///
    /// Throws for **configuration** mistakes (bad scheme, missing key) — those the
    /// provider-chain can't fix by retrying another link *with the same config*…
    /// actually it can, and `LiveModel` marks the provider dead and moves on either
    /// way; throwing early just keeps the log honest about *why*.
    func connect() throws -> AsyncStream<Event> {
        guard let url = Self.listenURL(endpoint) else {
            throw LiveError.invalidEndpoint
        }
        guard !apiKey.isEmpty else {
            throw LiveError.missingAPIKey
        }
        closed = false
        pendingTail = Data()

        // Headers on the handshake request — the key never touches the URL.
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")

        let wsTask = session.webSocketTask(with: request)
        self.task = wsTask
        wsTask.resume()
        log.info("remote live connecting \(url.host ?? "-", privacy: .public) path=\(url.path, privacy: .public) auth=bearer")

        var capturedContinuation: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event>(bufferingPolicy: .unbounded) { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
        startReceiveLoop()
        return stream
    }

    /// Send one Opus packet batch — **whole packets only**, identical framing to
    /// `LiveStreamASR.send` (raw bytes, fixed packet length, tail buffering).
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
                if let error {
                    log.warning("remote ws send failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            offset += packetBytes
        }
        if offset < buf.endIndex {
            pendingTail = Data(buf[offset..<buf.endIndex])
        }
    }

    /// Flush and close. Safe to call multiple times.
    func close() {
        guard !closed else { return }
        closed = true
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

    // MARK: - receive loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let task = self.task else { break }
                do {
                    let message = try await task.receive()
                    self.handle(message)
                } catch {
                    if self.closed { return }
                    let classified = await self.classify(error)
                    log.error("remote live failed: \(classified.localizedDescription, privacy: .public)")
                    self.reportClosed(classified)
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        receivedFrames += 1
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
            break // server replies JSON text only
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

    // MARK: - error classification

    /// Frames successfully received before the failure. The single most reliable
    /// handshake/mid-stream discriminator: URLSessionWebSocketTask doesn't expose
    /// the handshake's HTTP status, but "zero frames in" vs "stream died after
    /// flowing" is fully observable on our side.
    private var receivedFrames = 0

    /// Map a transport failure to a *reason the user can act on*.
    ///
    /// A failure before any frame arrived is treated as **handshake-shaped** and
    /// disambiguated by asking the server's HTTPS `/health` directly: 401/403 ⇒
    /// key wrong; reachable ⇒ wrong path/protocol; nothing ⇒ server down. A
    /// failure after frames flowed is a mid-stream drop — reported as-is, no
    /// probe needed (the answer wouldn't change what the user does).
    private func classify(_ error: Error) async -> Error {
        if error is CancellationError { return CancellationError() }
        guard let urlError = error as? URLError else {
            return LiveError.serverClosed(error.localizedDescription)
        }
        switch urlError.code {
        case .timedOut:
            return receivedFrames == 0 ? await withHealthVerdict() : LiveError.timeout
        case .cancelled:
            return CancellationError()
        default:
            if receivedFrames == 0 {
                return await withHealthVerdict()
            }
            return LiveError.serverClosed(urlError.localizedDescription)
        }
    }

    /// Ask `/health`; fall back to the plain handshake error when the probe
    /// itself can't add information.
    private func withHealthVerdict() async -> Error {
        if let verdict = await Self.probeHealth(endpoint: endpoint, apiKey: apiKey) {
            return verdict
        }
        return LiveError.handshakeFailed(nil)
    }

    /// One HTTPS `/health` call. Returns the classified verdict, or nil when the
    /// caller should fall back to the raw transport error.
    static func probeHealth(endpoint: String, apiKey: String) async -> LiveError? {
        guard let url = healthURL(endpoint) else { return LiveError.invalidEndpoint }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                // Server alive and key accepted — the WS layer is the problem.
                return .handshakeFailed(nil)
            case 401, 403:
                return .unauthorized
            default:
                return .handshakeFailed("HTTP \(status)")
            }
        } catch let e as URLError where e.code == .timedOut {
            return .timeout
        } catch {
            return nil // transport layer said more than the probe did — keep the original
        }
    }

    // MARK: - Settings probe

    struct ProbeResult {
        var ok: Bool
        var detail: String?
        var error: String?
    }

    /// Settings-page "verify": scheme check, then HTTPS `/health` with the key.
    /// 200 proves reachability **and** the key; 401/403 is reported distinctly
    /// because that is a different fix (fix the key, not the network).
    static func probe(endpoint: String, apiKey: String) async -> ProbeResult {
        guard listenURL(endpoint) != nil else {
            return ProbeResult(ok: false, detail: nil, error: L10n.ASR.remoteErrInvalidScheme)
        }
        guard !apiKey.isEmpty else {
            return ProbeResult(ok: false, detail: nil, error: L10n.ASR.remoteErrMissingKey)
        }
        guard let url = healthURL(endpoint) else {
            return ProbeResult(ok: false, detail: nil, error: L10n.ASR.remoteErrInvalidScheme)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return ProbeResult(ok: true, detail: "\(url.host ?? "") · \(status)", error: nil)
            case 401, 403:
                return ProbeResult(ok: false, detail: nil, error: L10n.ASR.remoteErrAuth)
            default:
                return ProbeResult(ok: false, detail: nil, error: L10n.ASR.remoteErrHandshake("HTTP \(status)"))
            }
        } catch let e as URLError where e.code == .timedOut {
            return ProbeResult(ok: false, detail: nil, error: L10n.ASR.remoteErrTimeout)
        } catch {
            return ProbeResult(ok: false, detail: nil, error: L10n.ASR.remoteErrHandshake(error.localizedDescription))
        }
    }
}
