import Foundation
import Network
import os
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "wifi")

/// TCP fast-transfer client for firmware v1.47+.
///
/// Wire format (the device's TCP file-transfer protocol): every
/// response frame is `[0xAA][type(1)][msg(1)][len_hi(1)][len_lo(1)][payload]`.
/// Unlike v1.39's UDP variant, frames arrive on a byte stream and may be
/// fragmented across receives — this client buffers and re-assembles.
///
/// Multi-byte integers are **little-endian** everywhere in the payload,
/// except the file-data chunk's 2-byte checksum, which is big-endian.
///
/// Commands (plain-ASCII, no terminator):
///
///   "list"                  → stream of type=0 frames, sentinel name=="0"
///   "get {filename}"        → stream of type=1 frames (full download)
///   "pull {name} {offset}"  → stream of type=4 frames (resumable download)
///   "delete {filename}"     → type=3 ack (msg=0 success, 1 not found)
///   "quit"                  → type=5 ack; server tears down the AP
///
/// The public API mirrors the UDP client this replaced so existing callers
/// (FastTransferSheet and parity tests) don't need rewrites.
final class WifiClient: @unchecked Sendable {
    struct RemoteFile: Equatable, Hashable, Sendable {
        let index: Int
        let total: Int
        let size: Int
        let name: String
    }

    /// Response type bytes. v1.47 uses `pull` (type=4) even for full
    /// downloads from offset 0; we keep `get` (type=1) support because
    /// older firmware emits it.
    enum TypeCode: UInt8 {
        case list   = 0
        case get    = 1
        case delete = 3
        case pull   = 4
        case quit   = 5
    }

    static let headerMagic: UInt8 = 0xAA

    let host: String
    let port: Int
    private let connectTimeout: TimeInterval
    private let readTimeout: TimeInterval

    private let queue = DispatchQueue(label: "com.nomily.app.ios.wifi", qos: .userInitiated)
    private var conn: NWConnection?

    /// Inbox of parsed frames + bytes waiting to be re-assembled. The
    /// receive loop appends raw bytes to `rxBuffer` and extracts as many
    /// complete frames as possible into `inbox`. `nextFrame(timeout:)`
    /// awaits the next inbox entry — one waiter at a time, which matches
    /// how the existing call sites serialize request/response traffic.
    private struct ReceiveState {
        var rxBuffer = Data()
        var inbox: [ParsedFrame] = []
        var waiter: CheckedContinuation<ParsedFrame, Error>?
        var waiterToken: UInt64 = 0
        var streamError: Error?
    }
    private let recvState = OSAllocatedUnfairLock<ReceiveState>(initialState: ReceiveState())

    init(host: String = "192.168.88.1",
         port: Int = 6718,
         connectTimeout: TimeInterval = 5.0,
         readTimeout: TimeInterval = 10.0) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
    }

    deinit { conn?.cancel() }

    // MARK: - lifecycle

    /// Open a TCP connection to the device and wait for `.ready` (or bail
    /// after `connectTimeout` seconds). Starts the receive pump.
    func connect() async throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(self.port)) else {
            throw WifiError.deviceError("Invalid port \(self.port)")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        // Lower latency for the chunked file-data protocol — the device
        // emits lots of small chunks and Nagle would batch them.
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOpts)
        let conn = NWConnection(to: endpoint, using: params)
        self.conn = conn

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @Sendable in
                try await self.waitForReady(conn)
            }
            group.addTask { @Sendable [connectTimeout] in
                try await Task.sleep(nanoseconds: UInt64(connectTimeout * 1_000_000_000))
                throw WifiError.timeout
            }
            do {
                _ = try await group.next()!
                group.cancelAll()
            } catch {
                group.cancelAll()
                conn.cancel()
                self.conn = nil
                throw error is WifiError ? error : WifiError.noResponse(host: self.host, port: self.port)
            }
        }
        startReceiveLoop(on: conn)
        log.info("TCP connected \(self.host, privacy: .public):\(self.port, privacy: .public)")
    }

    private func waitForReady(_ conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OSAllocatedUnfairLock<Bool>(initialState: false)
            let fireOnce: @Sendable (Result<Void, Error>) -> Void = { result in
                let shouldFire = once.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard shouldFire else { return }
                switch result {
                case .success:        cont.resume()
                case .failure(let e): cont.resume(throwing: e)
                }
            }
            conn.stateUpdateHandler = { state in
                log.debug("nwc state=\(String(describing: state), privacy: .public)")
                switch state {
                case .ready:         fireOnce(.success(()))
                case .failed(let e): fireOnce(.failure(e))
                case .cancelled:     fireOnce(.failure(WifiError.cancelled))
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    /// Best-effort teardown. Sends `quit` so the device drops its AP, then
    /// cancels the socket. Resolves any outstanding waiter with `cancelled`
    /// so awaiters don't hang.
    func close() {
        if let conn = conn, conn.state == .ready {
            conn.send(content: Data("quit".utf8), completion: .idempotent)
        }
        conn?.cancel()
        conn = nil
        let toResume = recvState.withLock { state -> CheckedContinuation<ParsedFrame, Error>? in
            state.rxBuffer.removeAll()
            state.inbox.removeAll()
            state.streamError = WifiError.cancelled
            let w = state.waiter
            state.waiter = nil
            return w
        }
        toResume?.resume(throwing: WifiError.cancelled)
    }

    // MARK: - list

    func listFiles() async throws -> [RemoteFile] {
        try await sendCommand("list")
        var files: [RemoteFile] = []
        while true {
            let frame = try await nextFrame(timeout: readTimeout)
            guard frame.type == TypeCode.list.rawValue else {
                log.debug("listFiles: skipping unexpected type=\(frame.type, privacy: .public)")
                continue
            }
            guard frame.msg == 0, frame.payload.count >= 12 else {
                throw WifiError.deviceError("list frame malformed (msg=\(frame.msg), len=\(frame.payload.count))")
            }
            let payload = frame.payload
            let index = Int(readU32LE(payload, offset: 0))
            let total = Int(readU32LE(payload, offset: 4))
            let size  = Int(readU32LE(payload, offset: 8))
            let nameBytes = payload.subdata(in: 12..<payload.count)
            let trimmed = Array(nameBytes).prefix(while: { $0 != 0 })
            let name = String(bytes: trimmed, encoding: .utf8) ?? ""
            // Firmware signals end-of-list with filename == "0" and index == total.
            if name == "0" || name.isEmpty {
                break
            }
            files.append(RemoteFile(index: index, total: total, size: size, name: name))
            // Defensive end: some firmware ships the last real entry with
            // `index == total` and no separate sentinel.
            if total > 0 && index >= total { break }
        }
        return files
    }

    // MARK: - download

    /// Download `name` fully. Sends `pull {name} 0`; the server streams
    /// one or more file-data chunks until `total_size` bytes have been
    /// delivered. Failures mid-stream surface to the caller and leave the
    /// connection in an indeterminate state — the caller should `close()`
    /// and reconnect to recover (matching the v1.39 UDP client's
    /// semantics).
    /// `expectedSize` is the size the `list` response declared for this
    /// file. When non-zero it is enforced against what actually arrived —
    /// a truncated transfer must not be reported as success, because the
    /// caller deletes the device's original on success.
    func downloadFile(
        _ name: String,
        expectedSize: Int = 0,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> Data {
        try await sendCommand("pull \(name) 0")
        var buf = Data()
        var totalSize: Int = 0
        var checksumVerified = 0
        var checksumSkipped = 0
        // First chunk reveals total_size. Subsequent chunks share the
        // same total. Stop once we've accumulated at least total_size
        // bytes — the device matches that terminator.
        while true {
            try Task.checkCancellation()
            let frame = try await nextFrame(timeout: readTimeout)
            guard frame.type == TypeCode.pull.rawValue || frame.type == TypeCode.get.rawValue else {
                log.debug("download: skipping unexpected type=\(frame.type, privacy: .public)")
                continue
            }
            if frame.msg != 0 {
                throw WifiError.deviceError("pull \(name) failed (msg=\(frame.msg))")
            }
            guard frame.payload.count >= 14 else {
                throw WifiError.malformed
            }
            let payload = frame.payload
            let chunkTotal = Int(readU32LE(payload, offset: 0))
            let chunkOffset = Int(readU32LE(payload, offset: 4))
            let chunkSize = Int(readU32LE(payload, offset: 8))
            guard chunkSize <= payload.count - 14 else { throw WifiError.malformed }
            let declaredChecksum = (UInt16(payload[payload.startIndex + 12]) << 8)
                | UInt16(payload[payload.startIndex + 13])
            let body = payload.subdata(in: 14..<(14 + chunkSize))
            if totalSize == 0 { totalSize = chunkTotal }

            // Per-chunk integrity. The chunk header carries a 16-bit one's-
            // complement sum over big-endian words. This client used not to
            // verify it, so a corrupted chunk was accepted and — with
            // "delete after transfer" on — the device's original got deleted
            // right after.
            //
            // A zero checksum means "not populated" (older/partial firmware);
            // enforcing it there would break every transfer, so those chunks
            // are counted and the length checks below carry the load instead.
            if declaredChecksum == 0 {
                checksumSkipped += 1
            } else {
                let actual = Self.internetChecksum(body)
                guard actual == declaredChecksum else {
                    log.error("download \(name, privacy: .public): checksum mismatch at offset \(chunkOffset, privacy: .public) declared=\(declaredChecksum, privacy: .public) actual=\(actual, privacy: .public)")
                    throw WifiError.integrity("\(name): a chunk failed its checksum at offset \(chunkOffset). Nothing was deleted from the device.")
                }
                checksumVerified += 1
            }
            // Gap detection — log and throw so the caller can retry.
            // The firmware advances `offset` linearly, so buf.count should
            // match the incoming offset at the start of every chunk.
            if chunkOffset != buf.count {
                log.warning("download \(name, privacy: .public): offset gap local=\(buf.count, privacy: .public) device=\(chunkOffset, privacy: .public)")
                throw WifiError.deviceError("Offset gap at \(chunkOffset); expected \(buf.count)")
            }
            buf.append(body)
            progress?(buf.count, totalSize)
            if totalSize > 0 && buf.count >= totalSize { break }
            if body.isEmpty { break }
        }

        // Length checks. `body.isEmpty` above can end the loop early, and a
        // dropped connection surfaces as a timeout mid-stream — both used to
        // return whatever had arrived so far as if it were the whole file.
        if totalSize > 0 && buf.count != totalSize {
            throw WifiError.integrity("\(name): got \(buf.count) bytes but the device announced \(totalSize). Nothing was deleted from the device.")
        }
        if expectedSize > 0 && buf.count != expectedSize {
            throw WifiError.integrity("\(name): got \(buf.count) bytes but the file list said \(expectedSize). Nothing was deleted from the device.")
        }
        log.info("download \(name, privacy: .public) ok bytes=\(buf.count, privacy: .public) chunksVerified=\(checksumVerified, privacy: .public) chunksWithoutChecksum=\(checksumSkipped, privacy: .public)")
        return buf
    }

    /// 16-bit one's-complement sum over big-endian words, as carried in the
    /// file-data chunk header.
    static func internetChecksum(_ data: Data) -> UInt16 {
        var sum: UInt32 = 0
        var index = data.startIndex
        let end = data.endIndex
        while index + 1 < end {
            sum &+= (UInt32(data[index]) << 8) | UInt32(data[index + 1])
            index += 2
        }
        if index < end {
            sum &+= UInt32(data[index]) << 8
        }
        while (sum >> 16) > 0 {
            sum = (sum & 0xFFFF) &+ (sum >> 16)
        }
        return UInt16(~sum & 0xFFFF)
    }

    // MARK: - delete

    func deleteFile(_ name: String) async throws {
        try await sendCommand("delete \(name)")
        let frame = try await nextFrame(timeout: readTimeout)
        guard frame.type == TypeCode.delete.rawValue else {
            throw WifiError.deviceError("delete \(name) unexpected type=\(frame.type)")
        }
        // msg==0 delete ok, msg==1 "not found" (treat as success), other → error.
        if frame.msg == 0 || frame.msg == 1 { return }
        throw WifiError.deviceError("delete \(name) failed (msg=\(frame.msg))")
    }

    // MARK: - send

    private func sendCommand(_ cmd: String) async throws {
        guard let conn = conn else { throw WifiError.notConnected }
        log.debug("→ \(cmd, privacy: .public)")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: Data(cmd.utf8), completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    // MARK: - receive loop

    private struct ParsedFrame {
        let type: UInt8
        let msg: UInt8
        let payload: Data
    }

    private func startReceiveLoop(on conn: NWConnection) {
        scheduleReceive(on: conn)
    }

    private func scheduleReceive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.ingest(data)
            }
            if let error = error {
                log.warning("tcp receive error: \(String(describing: error), privacy: .public)")
                self.failWaiter(with: error)
                return
            }
            if isComplete {
                log.info("tcp receive: peer closed")
                self.failWaiter(with: WifiError.cancelled)
                return
            }
            self.scheduleReceive(on: conn)
        }
    }

    /// Append freshly-received bytes to the buffer and extract as many
    /// complete `[0xAA][type][msg][len][payload]` frames as possible into
    /// `inbox`; any trailing partial frame stays in `rxBuffer` for the
    /// next receive. After parsing, if a caller is awaiting, hand them
    /// the oldest inbox entry.
    private func ingest(_ chunk: Data) {
        let waiterPayload: (CheckedContinuation<ParsedFrame, Error>, ParsedFrame)? = recvState.withLock { state in
            state.rxBuffer.append(chunk)
            while true {
                guard state.rxBuffer.count >= 5 else { break }
                let start = state.rxBuffer.startIndex
                guard state.rxBuffer[start] == Self.headerMagic else {
                    // Protocol desync — surface to caller and drain.
                    state.rxBuffer.removeAll()
                    state.streamError = WifiError.malformed
                    break
                }
                let type = state.rxBuffer[start + 1]
                let msg  = state.rxBuffer[start + 2]
                let len  = (Int(state.rxBuffer[start + 3]) << 8) | Int(state.rxBuffer[start + 4])
                let needed = 5 + len
                guard state.rxBuffer.count >= needed else { break }
                let payload = Data(state.rxBuffer[(start + 5)..<(start + needed)])
                state.inbox.append(ParsedFrame(type: type, msg: msg, payload: payload))
                state.rxBuffer.removeFirst(needed)
            }
            if let w = state.waiter, !state.inbox.isEmpty {
                state.waiter = nil
                let first = state.inbox.removeFirst()
                return (w, first)
            }
            return nil
        }
        if let (waiter, frame) = waiterPayload {
            waiter.resume(returning: frame)
        }
    }

    private func failWaiter(with error: Error) {
        let toResume = recvState.withLock { state -> CheckedContinuation<ParsedFrame, Error>? in
            state.streamError = error
            let w = state.waiter
            state.waiter = nil
            return w
        }
        toResume?.resume(throwing: error)
    }

    private func nextFrame(timeout: TimeInterval) async throws -> ParsedFrame {
        // Fast path: consume a buffered frame if one is already in the inbox.
        let fastPath: Result<ParsedFrame, Error>? = recvState.withLock { state in
            if let err = state.streamError, state.inbox.isEmpty { return .failure(err) }
            guard !state.inbox.isEmpty else { return nil }
            return .success(state.inbox.removeFirst())
        }
        if let fast = fastPath {
            switch fast {
            case .success(let f): return f
            case .failure(let e): throw e
            }
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ParsedFrame, Error>) in
            let myToken = recvState.withLock { state -> UInt64 in
                state.waiterToken &+= 1
                state.waiter = cont
                return state.waiterToken
            }
            // Timeout via the shared queue so we don't need Task.sleep
            // (which would keep the continuation pinned to an async task).
            self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self else { return }
                let toResume = self.recvState.withLock { state -> CheckedContinuation<ParsedFrame, Error>? in
                    guard state.waiter != nil, state.waiterToken == myToken else { return nil }
                    let w = state.waiter
                    state.waiter = nil
                    return w
                }
                toResume?.resume(throwing: WifiError.timeout)
            }
        }
    }

    // MARK: - endian helpers

    private func readU32LE(_ data: Data, offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        let b0 = UInt32(data[start])
        let b1 = UInt32(data[start + 1])
        let b2 = UInt32(data[start + 2])
        let b3 = UInt32(data[start + 3])
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }
}

enum WifiError: LocalizedError {
    case notConnected
    case timeout
    case malformed
    case noResponse(host: String, port: Int)
    case deviceError(String)
    case cancelled
    /// The bytes that arrived don't match what the device announced
    /// (checksum or length). Never treat this as a completed transfer.
    case integrity(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return NSLocalizedString(
                "wifi_error.not_connected",
                value: "Not connected to the device's Wi-Fi hotspot.",
                comment: "Fast transfer: the phone is not on the recorder's AP"
            )
        case .timeout:
            return NSLocalizedString(
                "wifi_error.timeout",
                value: "Wi-Fi transfer timed out.",
                comment: "Fast transfer got no data from the device in time"
            )
        case .malformed:
            return NSLocalizedString(
                "wifi_error.malformed",
                value: "The device sent a response the app couldn't read.",
                comment: "Fast transfer: malformed TCP frame"
            )
        case .noResponse(let h, let p):
            return String(
                format: NSLocalizedString(
                    "wifi_error.no_response",
                    value: "No response from the device at %1$@:%2$d.",
                    comment: "Fast transfer: TCP host and port unreachable"
                ),
                h, p
            )
        case .deviceError(let msg): return msg
        case .cancelled:
            return NSLocalizedString(
                "wifi_error.cancelled",
                value: "Fast Transfer was cancelled.",
                comment: "Fast transfer: the session was cancelled"
            )
        case .integrity(let msg):   return msg
        }
    }
}
