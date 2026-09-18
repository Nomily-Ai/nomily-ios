import CryptoKit
import Foundation

// MARK: - Minimal RFC 6455 implementation (only the side we need)
//
// Why write it ourselves: in TicNote's Wi-Fi fast transfer, **the phone is the WebSocket server**
// (the official Android plugin `com.mobvoi.wifi_plugin.WifiPlugin.openSocket`
//   directly does `new org.java_websocket.server.WebSocketServer(port)`),
// while Foundation only offers a client (`URLSessionWebSocketTask` can only connect outward).
// iOS has no ready-made WebSocket server implementation, so the handshake and framing have to be done by hand.
//
// The split is exactly the same as on the BLE path, for the same reason:
//
//   ┌─ WebSocketFraming (this file)  pure bytes: handshake reply / frame parsing / frame building. **Testable on the command line**
//   └─ TicNoteWifiLink (another file)  NWListener / NWConnection glue, thin enough to read at a glance
//
// So mistakes like "mask off by one bit" or "extended length read as 7 bits" can be nailed down without a real device.
// Self-check §20 calibrates its inputs with **a pair of public test vectors given by RFC 6455 itself** (see `acceptKey`).

// MARK: Opcodes

enum WebSocketOpcode: UInt8 {
    case continuation = 0x0
    case text         = 0x1
    case binary       = 0x2
    case close        = 0x8
    case ping         = 0x9
    case pong         = 0xA
}

/// One complete message that was split out (fragments have been merged back into one).
enum WebSocketMessage: Equatable {
    case text(String)
    /// TicNote's `WifiDataVo` uses this one
    case binary(Data)
    case ping(Data)
    case pong(Data)
    case close(code: UInt16?, reason: String)
}

enum WebSocketError: LocalizedError, Equatable {
    case protocolViolation(String)
    case payloadTooLarge(Int)
    case notUpgradeRequest

    var errorDescription: String? {
        switch self {
        case .protocolViolation(let s): return "WebSocket protocol violation: \(s)"
        case .payloadTooLarge(let n):   return "WebSocket message of \(n) B exceeds the cap"
        case .notUpgradeRequest:        return "Not a WebSocket upgrade request"
        }
    }
}

// MARK: Handshake

enum WebSocketHandshake {

    /// The fixed GUID from RFC 6455 §1.3. Appended to the client's `Sec-WebSocket-Key`, then SHA-1 is taken.
    static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Computation of `Sec-WebSocket-Accept`.
    ///
    /// Calibration uses **the pair from the body text of RFC 6455 §1.3**:
    ///   key = `dGhlIHNhbXBsZSBub25jZQ==` → accept = `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`
    /// What this assertion means: RSA is "what I computed" matching "what the spec says", not "my implementation agreeing with my implementation".
    static func acceptKey(for clientKey: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((clientKey + magicGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    /// Find the HTTP upgrade request in a run of bytes that **may not be fully received yet**, and generate the 101 reply.
    ///
    /// - Returns: `nil` = the complete `\r\n\r\n` has not arrived yet (keep waiting);
    ///            otherwise `(reply bytes, bytes remaining after the request headers)`.
    ///
    /// ⚠️ Returning the remaining bytes can't be skipped: the client may send WebSocket frames **right behind**
    /// the handshake request in the same TCP segment. Dropping them shows up as "connected but the card never talks",
    /// and because normal data keeps arriving afterwards, it looks sporadic.
    static func respond(to buffer: Data) throws -> (response: Data, remainder: Data)? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: terminator) else { return nil }

        let headerBytes = buffer[buffer.startIndex..<range.lowerBound]
        let remainder = Data(buffer[range.upperBound...])
        let header = String(decoding: headerBytes, as: UTF8.self)

        var lines = header.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw WebSocketError.notUpgradeRequest }
        let requestLine = lines.removeFirst()
        // Shaped like "GET / HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0].uppercased() == "GET" else {
            throw WebSocketError.notUpgradeRequest
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }

        guard headers["upgrade"]?.lowercased() == "websocket" else {
            throw WebSocketError.notUpgradeRequest
        }
        // The card (a Java-WebSocket client) always sends it; without it we can't compute accept,
        // and rather than guess one it's better to fail explicitly —— a guessed accept would be judged a handshake failure by the peer.
        guard let key = headers["sec-websocket-key"], !key.isEmpty else {
            throw WebSocketError.protocolViolation("missing Sec-WebSocket-Key")
        }

        // Build it piece by piece instead of using a multi-line string: with multi-line strings, newline rules (whether the last line gets eaten)
        // are easy to misread and then a \r\n goes missing, and the peer will only report "handshake failed" without telling you which byte is off.
        let accept = acceptKey(for: key)
        var response = Data()
        response.append(contentsOf: "HTTP/1.1 101 Switching Protocols\r\n".utf8)
        response.append(contentsOf: "Upgrade: websocket\r\n".utf8)
        response.append(contentsOf: "Connection: Upgrade\r\n".utf8)
        response.append(contentsOf: "Sec-WebSocket-Accept: \(accept)\r\n".utf8)
        response.append(contentsOf: "\r\n".utf8)
        return (response, remainder)
    }
}

// MARK: Framing (server → client)

enum WebSocketWriter {

    /// Frames sent by the server are **not masked** (RFC 6455 §5.1: only clients must mask).
    /// Adding a mask out of habit makes the peer disconnect with a protocol error; this is the most common "copied the client example" pitfall.
    static func frame(_ opcode: WebSocketOpcode, payload: Data) -> Data {
        var out = Data(capacity: payload.count + 10)
        out.append(0x80 | opcode.rawValue)          // FIN = 1

        switch payload.count {
        case ..<126:
            out.append(UInt8(payload.count))
        case ..<65_536:
            out.append(126)
            out.append(UInt8((payload.count >> 8) & 0xFF))
            out.append(UInt8(payload.count & 0xFF))
        default:
            out.append(127)
            let n = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((n >> UInt64(shift)) & 0xFF))
            }
        }
        out.append(payload)
        return out
    }

    static func close(code: UInt16, reason: String = "") -> Data {
        var payload = Data([UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)])
        payload.append(contentsOf: reason.utf8.prefix(123))   // control-frame payload ≤ 125
        return frame(.close, payload: payload)
    }
}

// MARK: Deframing (client → server)

/// Incremental deframer. **Pure value type, no IO**, so the self-check can feed it fabricated bytes directly.
///
/// Implements only the half the server needs:
///   · Frames from the client **must** be masked; if not, report a protocol error (RFC 6455 §5.1);
///   · Supports the three length encodings of 7 / 16 / 64 bits;
///   · Supports fragmentation (`FIN = 0` + `continuation`), merging into one message before handing it out;
///   · Control frames (ping/pong/close) must not be fragmented.
struct WebSocketFrameParser {

    /// Per-message size cap. Guards against "the peer giving a 2^60 length field to eat all memory" ——
    /// the hole a hand-written deframer most easily misses. The card's legitimate messages are far smaller
    /// (`WifiDataVo` is ≈ 16 KB per chunk).
    var maxMessageBytes = 32 * 1024 * 1024

    private var buffer = Data()
    private var fragmentOpcode: WebSocketOpcode?
    private var fragments = Data()

    init() {}

    /// Feed in newly received bytes; returns **all complete messages that can be split out this time**.
    mutating func feed(_ data: Data) throws -> [WebSocketMessage] {
        buffer.append(data)
        var out: [WebSocketMessage] = []

        while true {
            guard let (frame, consumed) = try nextFrame() else { return out }
            buffer.removeFirst(consumed)

            if let message = try assemble(frame) {
                out.append(message)
            }
        }
    }

    /// Split out one **frame** (not a message) and return the number of bytes it occupies.
    private func nextFrame() throws -> (RawFrame, Int)? {
        let b = [UInt8](buffer)
        guard b.count >= 2 else { return nil }

        let fin = (b[0] & 0x80) != 0
        // RSV bits must be 0: we never negotiate extensions, so non-zero means the peer is speaking by some other convention.
        guard (b[0] & 0x70) == 0 else {
            throw WebSocketError.protocolViolation("RSV bits set (b0=\(String(format: "%02X", b[0])))")
        }
        guard let opcode = WebSocketOpcode(rawValue: b[0] & 0x0F) else {
            throw WebSocketError.protocolViolation("unknown opcode \(b[0] & 0x0F)")
        }
        let masked = (b[1] & 0x80) != 0
        guard masked else {
            throw WebSocketError.protocolViolation("client frame is not masked")
        }

        var cursor = 2
        let len7 = Int(b[1] & 0x7F)
        var payloadLen: Int
        if len7 < 126 {
            payloadLen = len7
        } else if len7 == 126 {
            guard b.count >= cursor + 2 else { return nil }
            payloadLen = Int(b[cursor]) << 8 | Int(b[cursor + 1])
            cursor += 2
        } else {
            guard b.count >= cursor + 8 else { return nil }
            var n: UInt64 = 0
            for i in 0..<8 { n = (n << 8) | UInt64(b[cursor + i]) }
            guard n <= UInt64(maxMessageBytes) else {
                throw WebSocketError.payloadTooLarge(Int(clamping: n))
            }
            payloadLen = Int(n)
            cursor += 8
        }

        guard payloadLen <= maxMessageBytes else {
            throw WebSocketError.payloadTooLarge(payloadLen)
        }

        guard b.count >= cursor + 4 else { return nil }
        let maskKey = Array(b[cursor..<(cursor + 4)])
        cursor += 4

        guard b.count >= cursor + payloadLen else { return nil }
        // Unmasking: plaintext byte = ciphertext byte ^ mask[i % 4].
        // Go through `[UInt8]` instead of modifying `Data` in place: the indexing semantics of `Data` around "starting from 0"
        // are easy to trip on with slices (a `Data` slice keeps the original indices); arrays have no such ambiguity.
        var raw = Array(b[cursor..<(cursor + payloadLen)])
        for i in 0..<raw.count {
            raw[i] ^= maskKey[i % 4]
        }
        let payload = Data(raw)

        let isControl = opcode.rawValue >= 0x8
        if isControl {
            guard fin else { throw WebSocketError.protocolViolation("fragmented control frame") }
            guard payloadLen <= 125 else { throw WebSocketError.protocolViolation("control frame payload > 125") }
        }

        return (RawFrame(fin: fin, opcode: opcode, payload: payload), cursor + payloadLen)
    }

    private struct RawFrame {
        let fin: Bool
        let opcode: WebSocketOpcode
        let payload: Data
    }

    /// Combine frames into messages (handles fragmentation). Returns `nil` meaning "still accumulating, don't hand it out yet".
    private mutating func assemble(_ frame: RawFrame) throws -> WebSocketMessage? {
        switch frame.opcode {
        case .ping:
            return .ping(frame.payload)
        case .pong:
            return .pong(frame.payload)
        case .close:
            let code: UInt16? = frame.payload.count >= 2
                ? UInt16(frame.payload[frame.payload.startIndex]) << 8
                    | UInt16(frame.payload[frame.payload.startIndex + 1])
                : nil
            let reason = frame.payload.count > 2
                ? String(decoding: frame.payload.dropFirst(2), as: UTF8.self)
                : ""
            return .close(code: code, reason: reason)

        case .text, .binary:
            guard fragmentOpcode == nil else {
                throw WebSocketError.protocolViolation("new data frame while a fragment is open")
            }
            if frame.fin {
                return try deliver(opcode: frame.opcode, payload: frame.payload)
            }
            fragmentOpcode = frame.opcode
            fragments = frame.payload
            return nil

        case .continuation:
            guard let opcode = fragmentOpcode else {
                throw WebSocketError.protocolViolation("continuation without a start frame")
            }
            fragments.append(frame.payload)
            guard fragments.count <= maxMessageBytes else {
                throw WebSocketError.payloadTooLarge(fragments.count)
            }
            if frame.fin {
                fragmentOpcode = nil
                let payload = fragments
                fragments = Data()
                return try deliver(opcode: opcode, payload: payload)
            }
            return nil
        }
    }

    private func deliver(opcode: WebSocketOpcode, payload: Data) throws -> WebSocketMessage {
        switch opcode {
        case .binary: return .binary(payload)
        case .text:
            guard let s = String(data: payload, encoding: .utf8) else {
                throw WebSocketError.protocolViolation("text frame is not valid UTF-8")
            }
            return .text(s)
        default:
            throw WebSocketError.protocolViolation("unexpected opcode \(opcode.rawValue)")
        }
    }
}
