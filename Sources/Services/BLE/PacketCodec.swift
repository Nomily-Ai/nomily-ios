import Foundation

/// Frames written to RX_CHAR are `[PID][CMD][LEN][PAYLOAD…]`.
/// Notifications received on TX_CHAR follow the same layout, with status nibbles
/// living in payload[0] for the streaming commands (0x68 / 0x70).
enum PacketCodec {
    /// Build a request frame for a given command + raw payload.
    static func encode(cmd: UInt8, payload: Data = Data()) -> Data {
        precondition(payload.count <= 0xFF, "payload too long for one BLE frame")
        var pkt = Data(capacity: 3 + payload.count)
        pkt.append(DnoteProtocol.pid)
        pkt.append(cmd)
        pkt.append(UInt8(payload.count))
        pkt.append(payload)
        return pkt
    }

    /// Build a request frame whose payload is a JSON object.
    static func encodeJSON(cmd: UInt8, _ object: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return encode(cmd: cmd, payload: payload)
    }

    /// Decoded view of an inbound notification.
    struct Frame {
        let cmd: UInt8
        let length: UInt8
        let payload: Data           // bytes after [PID][CMD][LEN]

        /// Device replies "OK" by setting payload[0] == 0x01.
        var isAck: Bool { payload.first == 0x01 }
    }

    static func decode(_ data: Data) -> Frame? {
        guard data.count >= 3, data[data.startIndex] == DnoteProtocol.pid else { return nil }
        let cmd = data[data.startIndex + 1]
        let len = data[data.startIndex + 2]
        let payload = data.suffix(from: data.startIndex + 3)
        return Frame(cmd: cmd, length: len, payload: Data(payload))
    }

    /// Parse a JSON object from a frame's payload.
    static func decodeJSON(_ frame: Frame) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: frame.payload) as? [String: Any] else {
            throw DnoteError.malformedResponse
        }
        return obj
    }
}

enum DnoteError: Error, LocalizedError {
    case notConnected
    case timeout
    case malformedResponse
    case deviceError(String)
    case fileNotFound(String)
    case transferCancelled
    case streamEnded
    /// `startStream` was acknowledged but no OPUS frame arrived within the
    /// first-frame window. The device is not pushing audio for this
    /// recording (0x56 `upload` = 0), not a lost link.
    case streamNoAudio
    case ackFailed(cmd: UInt8)
    case notBound
    case operationUnavailableWhileRecording
    /// The firmware forces encryption, but this device hasn't set a passcode yet. Anything recorded now will be forever unreadable on this phone
    /// so the app does not start a new recording and instead directs the user to set a passcode.
    case passphraseSetupIncomplete
    /// Fewer (or differently-ordered) bytes arrived than the device
    /// announced. Callers must not treat this as a completed transfer —
    /// deleting the device's original on top of it loses the recording.
    case transferIncomplete(String)

    var errorDescription: String? {
        switch self {
        // The three below reach the user through connect / record / live
        // alerts, so they are localized. The remaining cases are developer-
        // facing today and still read English; see the follow-up card.
        case .notConnected:
            return NSLocalizedString(
                "dnote_error.not_connected",
                value: "Not connected to a device.",
                comment: "Command attempted with no device link"
            )
        case .timeout:
            return NSLocalizedString(
                "dnote_error.timeout",
                value: "The device did not reply in time.",
                comment: "Device command timed out"
            )
        case .malformedResponse:          return "The device's reply could not be parsed."
        case .deviceError(let msg):       return "Device error: \(msg)"
        case .fileNotFound(let name):     return "File not found on device: \(name)"
        case .transferCancelled:          return "Transfer was cancelled."
        case .streamEnded:                return "Device stopped recording."
        case .streamNoAudio:
            return NSLocalizedString(
                "dnote_error.stream_no_audio",
                value: "Nomi isn't sending audio for this recording. Stop the recording on the device, then start live from the app.",
                comment: "Live session got no audio frames after starting the stream"
            )
        case .ackFailed(let cmd):         return String(format: "Command 0x%02X was not acknowledged.", cmd)
        case .notBound:
            return NSLocalizedString(
                "dnote_error.not_bound",
                value: "This Nomi isn't paired with this app yet.",
                comment: "Recording or live blocked because the device is not paired"
            )
        case .operationUnavailableWhileRecording:
            return NSLocalizedString(
                "device.unavailable_while_recording",
                value: "Stop the recording before running device operations.",
                comment: "A mutating device command was blocked because recording is active"
            )
        case .passphraseSetupIncomplete:
            return NSLocalizedString(
                "dnote_error.passphrase_setup_incomplete",
                value: "Set the encryption passphrase before recording — this Nomi encrypts everything it records, and clips made without the passphrase can't be opened on this iPhone.",
                comment: "Recording blocked because the device is encrypted and this phone has no key"
            )
        case .transferIncomplete(let msg): return msg
        }
    }
}
