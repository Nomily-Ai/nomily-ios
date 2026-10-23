import CommonCrypto
import CoreBluetooth
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "ble.dingtalka1")

// MARK: - DingTalk A1 wire protocol
//
// Everything in this file was measured on a real card (`SN 2010A1K262001N000655`,
// firmware `V1.6.98-202608262232`) and is written down in
// the A1 reverse-engineering notes §2 / §14. Nothing here is a guess;
// the two places where an assumption remains are called out explicitly
// (`DingTalkA1FileIndex`, `DingTalkA1Audio.recordPrefixLength`).
//
// ## Shape of the link
//
//     advertisement: name "DingTalk A1", service 0xFE3C (short form!), mfg 30 36 35 35 = "0655"
//     service   FE3C
//     write     FE1C  [read, write, writeWithoutResponse]      App → card
//     notify    FE1B  [read, notify]                            card → App
//
// ## Frame
//
//     [0]      type      0x13 request · 0x31 response · 0x14 card-initiated event
//     [1..2]   cmd       u16 **big endian**
//     [3]      seq       echoed back by the card when it answers a response
//     [4..7]   length    u32 big endian, payload length only
//     [8...]   payload
//
// Unlike TicNote (whose control frames have no length field and rely on
// "one notification = one frame"), the A1 **does** carry a length, so frames must be
// reassembled from a byte buffer — a large file block arrives split across several
// notifications at MTU 23.
//
// ## Why `commands` can't describe this card
//
// `RecorderCommandSet` is a `UInt8` table. Every A1 command is 16-bit with a non-zero
// high byte (`0x0110`, `0x0133`…), so the table physically cannot hold them. That is why
// `DingTalkA1Spec.commands` returns `.unknown`: it is the honest value, and capability
// decisions are made by `DingTalkA1Link`'s methods (each of which throws `.unsupported`
// if it really cannot deliver), never by looking at the byte table.

// MARK: GATT

enum DingTalkA1GATT {
    static let service = CBUUID(string: "0000FE3C-0000-1000-8000-00805F9B34FB")
    /// App → card.
    static let commandCharacteristic = CBUUID(string: "0000FE1C-0000-1000-8000-00805F9B34FB")
    /// Card → App.
    static let notifyCharacteristic = CBUUID(string: "0000FE1B-0000-1000-8000-00805F9B34FB")

    /// `type | cmd u16 | seq | len u32`
    static let headerBytes = 8

    /// The advertising name. Used **only** to recognise the family when the service UUID
    /// is missing from the advertisement — never for identity (the user can rename it).
    static let advertisedName = "DingTalk A1"
}

enum DingTalkA1PacketType: UInt8 {
    /// App → card command.
    case request = 0x13
    /// Card → App reply (and App → card reply to a card request).
    case response = 0x31
    /// Card-initiated push (battery / recording state). Observed once as `0x000C`.
    case event = 0x14
}

enum DingTalkA1Cmd: UInt16 {
    /// `{did, corp_id}` → `{code, random}`. **The only command that needs no credential.**
    case getRandom = 0x0008
    /// `{did, action, params}` → `{code}`. `action:"start"/"stop"` drives the card's own
    /// recorder; `action:"set"` with `params:[{key,val}]` sets device options —
    /// **`{"key":"upload_stream","val":1}` is the real‑time stream switch** (the card then
    /// pushes `0x0117` frames; `0x0137`'s `stream_record` is NOT the switch — upstream notes
    /// §11.6: sending it returns 200 but the card never pushes a frame).
    case audioRecordOpt = 0x0100
    /// `{did, s_fid, recently, e_fid}` → binary index (see `DingTalkA1FileIndex`).
    case fileIndex = 0x0110
    /// `{did, fid, offset, progress}` → `{code}` (200 accepted / 202 already running).
    case fetchFile = 0x0111
    /// `{did}` → `{code}`. Cancels an in‑progress file sync.
    case fileSyncCancel = 0x0112
    /// `{did, fid}` → `{code}`. Deletes one recording **on the card**.
    case fileDelete = 0x0113
    /// Card → App: file attributes (JSON when it has them, raw bytes otherwise).
    case fileAttributes = 0x0114
    /// Card → App: one file block.
    case fileBlock = 0x0115
    /// Card → App: stream attributes (JSON; carries `stream_type` etc.). Pushed when the
    /// real‑time stream opens. Requires the same `0x31 {"code":200}` ack as the other pushes.
    case streamAttributes = 0x0116
    /// Card → App: one real‑time audio frame (see `DingTalkA1LiveFrame`).
    case streamData = 0x0117
    /// `{did}` → `{code, audio_status, duration, fid, storage_total_size, storage_remain, battery_percent, version}`
    case deviceStatus = 0x0132
    /// `{did, model, sdk_ver, corp_id, token, timestamp}` → `{code}`. 200 = authenticated.
    case connectDevice = 0x0133
    /// `{did}` → `{code}`. Leaves the card free for the next central.
    case disconnectDevice = 0x0134
    /// ★ (2026-10-19) **Unverified** battery query. Upstream notes disagree on the number
    /// (`0x013F` vs `0x0136`) and on the body (`{did, key:"battery_key"}` vs plain `{did}`).
    /// Read-only probe: we send it, log the reply verbatim, and only trust what comes back.
    /// Never used for anything the user asked for — see `DingTalkA1Link.probeBattery()`.
    case batteryQuery = 0x013F
    /// The other candidate number for the same query (see `batteryQuery`).
    case batteryQueryAlt = 0x0136
}

// MARK: Frame codec

enum DingTalkA1FrameCodec {

    /// Build one frame. `seq` is echoed by the card on responses, so a caller that needs to
    /// match a specific reply keeps its own numbering (we use a monotonically increasing byte,
    /// which is what the PC client does).
    static func frame(type: DingTalkA1PacketType = .request,
                      cmd: DingTalkA1Cmd,
                      seq: UInt8,
                      payload: Data = Data()) -> Data {
        var out = Data(capacity: DingTalkA1GATT.headerBytes + payload.count)
        out.append(type.rawValue)
        out.append(UInt8((cmd.rawValue >> 8) & 0xFF))
        out.append(UInt8(cmd.rawValue & 0xFF))
        out.append(seq)
        let length = UInt32(payload.count)
        out.append(UInt8((length >> 24) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(payload)
        return out
    }

    /// Same, with a JSON body. Compact separators, UTF-8 — the PC client's exact encoding,
    /// and `0x0110`'s `fid` fields must be **strings** or the card answers `400`.
    static func frame(type: DingTalkA1PacketType = .request,
                      cmd: DingTalkA1Cmd,
                      seq: UInt8,
                      json: [String: Any]) -> Data {
        let payload = (try? JSONSerialization.data(withJSONObject: json, options: [])) ?? Data()
        return frame(type: type, cmd: cmd, seq: seq, payload: payload)
    }

    /// Parse the 8-byte header out of a complete frame. Returns nil for a short/garbled buffer.
    static func decode(_ data: Data) -> RecorderFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= DingTalkA1GATT.headerBytes else { return nil }
        guard DingTalkA1PacketType(rawValue: bytes[0]) != nil else { return nil }
        let cmd = (UInt16(bytes[1]) << 8) | UInt16(bytes[2])
        let length = (UInt32(bytes[4]) << 24) | (UInt32(bytes[5]) << 16)
            | (UInt32(bytes[6]) << 8) | UInt32(bytes[7])
        guard Int(length) <= bytes.count - DingTalkA1GATT.headerBytes else { return nil }
        return RecorderFrame(
            type: bytes[0],
            cmd: cmd,
            length: nil,
            payload: Data(bytes[DingTalkA1GATT.headerBytes..<(DingTalkA1GATT.headerBytes + Int(length))])
        )
    }

    /// Full header including `seq`, which `RecorderFrame` deliberately does not model
    /// (the abstraction layer has no notion of request ids).
    static func decodeWithSequence(_ data: Data) -> (frame: RecorderFrame, seq: UInt8)? {
        guard let frame = decode(data) else { return nil }
        return (frame, [UInt8](data)[3])
    }
}

/// Reassembles frames from the notification byte stream.
///
/// Stateless w.r.t. the protocol: it only honours the length field. A frame that declares a
/// length we never receive in full just sits in the buffer, which is the correct behaviour —
/// truncating it would hand the caller a half payload that looks complete.
struct DingTalkA1Framer {
    private var buffer = Data()

    mutating func reset() { buffer.removeAll(keepingCapacity: false) }

    /// Feed one notification; returns every **complete** frame it completed, in order.
    mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var out: [Data] = []
        // Convert once per call: `Data`'s indices shift after slicing, and mixing
        // `Data` subscripts with `count`-based bounds is how an out-of-range trap happens.
        var bytes = [UInt8](buffer)
        while bytes.count >= DingTalkA1GATT.headerBytes {
            guard DingTalkA1PacketType(rawValue: bytes[0]) != nil else {
                // Not a frame boundary. Slide forward one byte rather than dropping
                // everything: a resync is cheaper than losing the next good frame.
                bytes.removeFirst()
                continue
            }
            let length = (UInt32(bytes[4]) << 24) | (UInt32(bytes[5]) << 16)
                | (UInt32(bytes[6]) << 8) | UInt32(bytes[7])
            // A sane ceiling: the largest block the card sends is 48 KB, and a bogus length
            // must not make us wait forever for bytes that will never come.
            guard length <= 256 * 1024 else {
                bytes.removeFirst()
                continue
            }
            let total = DingTalkA1GATT.headerBytes + Int(length)
            guard bytes.count >= total else { break }
            out.append(Data(bytes[0..<total]))
            bytes.removeFirst(total)
        }
        buffer = Data(bytes)
        return out
    }
}

// MARK: Authentication

enum DingTalkA1Auth {

    /// `token = lowercase_hex(AES-128-CBC(key = ASCII(secret[0..16]), iv = key,
    ///                                  pt = ASCII(random32), no padding))`
    ///
    /// ⚠️ The key is the **ASCII bytes of the first 16 characters** of the secret string, not
    /// the first 8 bytes of its hex decoding. Getting that wrong is not a "slightly off" token;
    /// it is a stable `501`.
    ///
    /// Returns nil when the inputs cannot possibly produce a token (short secret, challenge not
    /// a multiple of the AES block size) — the caller turns that into `.unsupported` rather than
    /// sending garbage. **Never** pad with zeros to "make it work": a zero key is exactly the
    /// mistake that produced weeks of `501`s in the tooling.
    static func token(secret: String, challenge: String) -> String? {
        let keyBytes = Array(secret.prefix(16).utf8)
        let plain = Array(challenge.utf8)
        guard keyBytes.count == 16, !plain.isEmpty, plain.count % kCCBlockSizeAES128 == 0 else {
            return nil
        }
        var output = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let status = keyBytes.withUnsafeBufferPointer { key in
            plain.withUnsafeBufferPointer { input in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(0),                     // no PKCS#7 — the plaintext is already aligned
                    key.baseAddress, key.count,
                    key.baseAddress,                  // iv == key
                    input.baseAddress, input.count,
                    &output, output.count,
                    &written
                )
            }
        }
        guard status == kCCSuccess, written == plain.count else { return nil }
        return output.prefix(written).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Status (0x0132)

/// The `0x0132` reply. Field names are the card's own (`audio_status`, `battery_percent`…).
struct DingTalkA1Status: Equatable {
    let batteryPercent: Int?
    /// The card's own word: `idle` / `recording` (only the two observed).
    let audioStatus: String?
    /// Length of the recording in progress — **milliseconds**, despite the field being called
    /// `duration` in the card's JSON.
    ///
    /// ★ (2026-10-19) Measured, not assumed: two `0x0132` replies 3.1 s apart read
    ///   `"duration":1056` and `"duration":4185`. The old code named this `durationSeconds` and
    ///   fed it straight into a `TimeInterval`, which is why anything derived from the card's
    ///   clock looked 1000× off (and why the on-screen timer never matched DingTalk's).
    let durationMilliseconds: Int?
    /// Cursor: the fid (start timestamp) of the most recent recording.
    let lastFileID: UInt32?
    let storageTotalBytes: Int64?
    let storageFreeBytes: Int64?
    let firmware: String?

    var isRecording: Bool? {
        guard let audioStatus else { return nil }
        return audioStatus.lowercased() == "recording"
    }

    static func parse(_ payload: Data) -> DingTalkA1Status? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        // `code` is on every reply; a non-200 here means the card is not authenticated
        // (405) or rejected the credential (501) — both make the rest meaningless.
        if let code = intValue(object["code"]), code != 200 { return nil }

        return DingTalkA1Status(
            batteryPercent: intValue(object["battery_percent"]),
            audioStatus: object["audio_status"] as? String,
            durationMilliseconds: intValue(object["duration"]),
            lastFileID: intValue(object["fid"]).flatMap { UInt32(clamping: $0) },
            storageTotalBytes: int64Value(object["storage_total_size"]),
            storageFreeBytes: int64Value(object["storage_remain"]),
            firmware: object["version"] as? String
        )
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String { return Int(s) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private static func int64Value(_ any: Any?) -> Int64? {
        if let n = any as? Int64 { return n }
        if let n = any as? Int { return Int64(n) }
        if let s = any as? String { return Int64(s) }
        if let n = any as? NSNumber { return n.int64Value }
        return nil
    }
}

// MARK: File index (0x0110)

/// The `0x0110` reply — **binary, not JSON**.
///
/// Empty index observed on the real card:
/// ```
/// 00 c8 | 00 00 | 00 00 00 00 | 5a 5a 5a 5a
/// code    count?  …             sentinel
/// ```
///
/// Record layout (upstream notes §11.3, decoded from a real capture): header is
/// **`[0:2] code` + `[2:4] record count`**, then **8 bytes per record**:
///
/// ```
/// [0:2]  flag     (meaning unresolved)
/// [2:6]  fid      big‑endian Unix timestamp of the recording's start
/// [6:8]  status   (meaning unresolved)
/// ```
/// trailing `0x5A` padding.
///
/// ⚠️ **There is no size in the index.** The first version of this parser read the second
/// word as a size — with this layout that word is `fid`'s low half plus the status bytes, i.e.
/// pure garbage, and every list row would have shown a wrong "size". The authoritative size
/// arrives in `0x0114` during the download, which never depended on the index anyway.
enum DingTalkA1FileIndex {

    struct Entry: Equatable {
        let fid: UInt32
        let startedAt: Date
    }

    static func parse(_ payload: Data) -> [Entry] {
        let bytes = [UInt8](payload)
        guard bytes.count >= 8 else { return [] }
        let code = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
        guard code == 200 else {
            log.warning("file index code=\(code, privacy: .public)")
            return []
        }
        let declared = Int((UInt16(bytes[2]) << 8) | UInt16(bytes[3]))

        // Drop the trailing 0x5A padding. Records are 8 bytes and start at [4].
        var end = bytes.count
        while end > 4, bytes[end - 1] == 0x5A { end -= 1 }
        // The count field is the layout's own cross‑check; trust the arithmetic over it when
        // they disagree (the empty capture has four zero bytes after the count, which would
        // otherwise read as one record with fid 0).
        var available = (end - 4) / 8
        if declared > 0, declared <= available { available = declared }

        var entries: [Entry] = []
        var offset = 4
        for _ in 0..<available {
            let fid = be32(bytes, offset + 2)
            // fid 0 = padding/placeholder, not a real recording.
            if fid > 0 {
                entries.append(Entry(fid: fid,
                                     startedAt: Date(timeIntervalSince1970: TimeInterval(fid))))
            }
            offset += 8
        }
        return entries
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
}

// MARK: Real-time stream frame (0x0117)

/// One `0x0117` push — the card's **live audio** while `upload_stream=1` (see
/// `DingTalkA1Cmd.audioRecordOpt`).
///
/// Layout in **frame** coordinates — verified against a real capture (524 frames, 2026-10-18):
/// a 124-byte frame is 8 header + 116 payload, a 208-byte frame is the same header plus **two**
/// packets batched together.
///
/// ```
/// [0:8]     13 01 17 <seq> 00 00 00 74     header, payload = 116
/// [8:12]    ?                              unresolved (always 00 00 00 00 so far)
/// [12:16]   fid                            big-endian; equals `"fid"` in the 0x0132 JSON
/// [16:20]   ?                              unresolved
/// [20:24]   running counter                grows ~+50/s (sample offset of this packet)
/// [24:28]   block number
/// [28:32]   00 00 00 54                    audio length: 84 (one packet) or 168 (two)
/// [32:36]   00 00 40 A9                    constant on this firmware
/// [36:+n]   Opus packet(s)                 n = 84 × packets, contiguous, no separator
/// [36+n:]   5a 5a 5a 5a                    sentinel
/// ```
struct DingTalkA1LiveFrame: Equatable {
    let fid: UInt32
    /// One frame can carry **more than one** Opus packet: the card batches two 20 ms packets
    /// into a 208-byte frame when the link is busy (18 of 524 frames in the capture above).
    /// Handing them out one packet at a time keeps every downstream consumer — 3 s batching,
    /// duration, Ogg muxing — dealing with the single 84-byte shape it was built for.
    let packets: [Data]

    static func parse(_ frame: Data) -> DingTalkA1LiveFrame? {
        let bytes = [UInt8](frame)
        // 8-byte frame header + 32-byte packet header + at least one packet + 4-byte sentinel.
        guard bytes.count >= 36 + 4 + 1 else { return nil }
        func be32(_ offset: Int) -> UInt32 {
            (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        }
        let packetBytes = OpusOgg.Profile.dingTalkA1.packetBytes
        let length = Int(be32(28))
        // ★ The old guard was `bytes.count >= 120 + length`, which demanded 204 bytes for a
        //   124-byte frame — so **every** real frame was rejected as malformed, the live
        //   session never produced a single sample, and the 10 s first-frame watchdog then
        //   tore the stream down. The sentinel starts where the audio ends: 36 + length.
        guard length > 0,
              length % packetBytes == 0,
              bytes.count >= 36 + length + 4
        else { return nil }
        let sentinel = 36 + length
        guard bytes[sentinel] == 0x5A, bytes[sentinel + 1] == 0x5A,
              bytes[sentinel + 2] == 0x5A, bytes[sentinel + 3] == 0x5A
        else { return nil }
        var packets: [Data] = []
        packets.reserveCapacity(length / packetBytes)
        var offset = 36
        while offset + packetBytes <= 36 + length {
            packets.append(Data(bytes[offset..<(offset + packetBytes)]))
            offset += packetBytes
        }
        return DingTalkA1LiveFrame(fid: be32(12), packets: packets)
    }
}

// MARK: File blocks (0x0115)

/// One `0x0115` payload: `[?2][fid u32][?2][blockNo u32][len u32][bytes…]`.
///
/// The two leading and two in-between bytes are unaccounted for in every capture we have;
/// they are skipped exactly the way the PC client skips them (offsets 2/8/12/16), not guessed at.
struct DingTalkA1Block {
    let fid: UInt32
    let number: UInt32
    let payload: Data

    static func parse(_ data: Data) -> DingTalkA1Block? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16 else { return nil }
        func be32(_ offset: Int) -> UInt32 {
            (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        }
        let fid = be32(2)
        let number = be32(8)
        let length = Int(be32(12))
        guard length > 0, bytes.count >= 16 + length else { return nil }
        return DingTalkA1Block(fid: fid, number: number, payload: Data(bytes[16..<(16 + length)]))
    }
}

// MARK: - UT report (0x000C) — the card's own event log
//
// ## What `0x000C` actually is (was "unresolved binary" until 2026-10-18)
//
// It is **not** an opaque status broadcast: it is a structured diagnostics report the card
// emits on every connect and whenever something happens (`ParseNotifyUtReport` in the official
// native library). Decoding it is what makes three things possible at once:
//
// * **a timer that matches the card** — `AUDIO_RECORD_START/STOP` carry the card's own clock;
// * **the charging state** — `SYSTEM_CHARGING_CHANGED` (the `0x0132` JSON has no charging field);
// * **the "remark" the user makes by pressing the button mid-recording** —
//   `AUDIO_CONTROL_REMARK_BUTTON_CLICK`, the thing DingTalk shows as a marked segment.
//
// ## Wire format (upstream native-flow notes §5)
//
// ```
// [0:2]      5A 5A                      magic
// [2:4]      u16 BE = N                 byte length of the record area
// [4:4+N]    records                   N / count bytes each, count taken from the trailer
// [4+N:8+N]  4 B metadata              **lowest byte** = record count
// [8+N:10+N] 5A 5A                      magic
// ```
// Each record (≥ 20 bytes; the stride is `N / count`, extra bytes are reserved):
//
// ```
// [0:2]   seq       u16 BE
// [2:8]   device time u48 BE            Unix seconds (verified: 0x6AD47504 ≈ 2026-10-18)
// [8:12]  event id  u32 BE              module in the HIGH byte (see `DingTalkA1EventID`)
// [12:20] value     u64 BE              semantics depend on the event
// ```
//
// ⚠️ Do **not** read the high byte of the id as a "key code" — that is the module
// (`0x05` AUDIO, `0x0A` HAL, `0x0B` AUDIO_CONTROL, `0x0C` AUDIO_INSTANCE …), and the first
// version of these notes made exactly that mistake (`0x01000003` is `SYSTEM_UPTIME`, not a key).

/// Event ids we act on. Names are the official SDK's (`dt_ut_event_to_string`).
enum DingTalkA1EventID {
    // SYSTEM
    static let battery: UInt32 = 0x0100_0006
    static let chargingChanged: UInt32 = 0x0100_000C
    static let outputChargingChanged: UInt32 = 0x0100_000D
    // AUDIO
    static let recordStart: UInt32 = 0x0500_0002
    static let recordStop: UInt32 = 0x0500_0003
    static let recordPause: UInt32 = 0x0500_0004
    static let recordResume: UInt32 = 0x0500_0005
    // HAL — physical keys
    static let aiClick: UInt32 = 0x0A00_0001
    static let recordClick: UInt32 = 0x0A00_0006
    static let recordLongPress: UInt32 = 0x0A00_0008
    // AUDIO_CONTROL — what the firmware decided to do
    /// ★ The "mark this moment" press. This is the button that makes DingTalk put a marker
    /// into the recording; we mirror it as a timed mark.
    static let remarkButtonClick: UInt32 = 0x0B00_0001
    static let controlStartRecording: UInt32 = 0x0B00_0002
    static let controlStopRecording: UInt32 = 0x0B00_0003
    static let controlPauseRecording: UInt32 = 0x0B00_0004
    static let controlResumeRecording: UInt32 = 0x0B00_0005
    // AUDIO_INSTANCE — session boundaries
    static let instanceStart: UInt32 = 0x0C00_0005
    static let instanceStop: UInt32 = 0x0C00_0006

    static func name(_ id: UInt32) -> String {
        switch id {
        case battery: return "SYSTEM_BATTERY"
        case chargingChanged: return "SYSTEM_CHARGING_CHANGED"
        case outputChargingChanged: return "SYSTEM_OUTPUT_CHARGING_CHANGED"
        case recordStart: return "AUDIO_RECORD_START"
        case recordStop: return "AUDIO_RECORD_STOP"
        case recordPause: return "AUDIO_RECORD_PAUSE"
        case recordResume: return "AUDIO_RECORD_RESUME"
        case aiClick: return "HAL_AI_CLICK"
        case recordClick: return "HAL_RECORD_CLICK"
        case recordLongPress: return "HAL_RECORD_LONGPRESS"
        case remarkButtonClick: return "AUDIO_CONTROL_REMARK_BUTTON_CLICK"
        case controlStartRecording: return "AUDIO_CONTROL_START_RECORDING"
        case controlStopRecording: return "AUDIO_CONTROL_STOP_RECORDING"
        case controlPauseRecording: return "AUDIO_CONTROL_PAUSE_RECORDING"
        case controlResumeRecording: return "AUDIO_CONTROL_RESUME_RECORDING"
        case instanceStart: return "AUDIO_INSTANCE_START"
        case instanceStop: return "AUDIO_INSTANCE_STOP"
        default: return String(format: "0x%08X", id)
        }
    }

    /// "Recording is now running" — any of the three layers may be the one we see first.
    static func startsRecording(_ id: UInt32) -> Bool {
        id == recordStart || id == controlStartRecording || id == instanceStart
    }

    static func stopsRecording(_ id: UInt32) -> Bool {
        id == recordStop || id == controlStopRecording || id == instanceStop
    }
}

struct DingTalkA1UtEvent: Equatable {
    let sequence: UInt16
    /// The **card's** clock, Unix seconds. Used for offsets, never compared to the phone's clock.
    let timestamp: Date
    let id: UInt32
    let value: UInt64

    var name: String { DingTalkA1EventID.name(id) }
}

enum DingTalkA1UtReport {

    static func parse(_ payload: Data) -> [DingTalkA1UtEvent] {
        let bytes = [UInt8](payload)
        guard bytes.count >= 10, bytes[0] == 0x5A, bytes[1] == 0x5A else { return [] }
        let areaLength = Int((UInt16(bytes[2]) << 8) | UInt16(bytes[3]))
        guard areaLength > 0,
              bytes.count >= 4 + areaLength + 6,
              bytes[4 + areaLength + 4] == 0x5A,
              bytes[4 + areaLength + 5] == 0x5A
        else { return [] }

        // The record count lives in the **lowest byte** of the 4-byte trailer before the magic.
        let count = Int(bytes[4 + areaLength + 3])
        guard count > 0 else { return [] }
        let stride = areaLength / count
        guard stride >= 20, areaLength % count == 0 else {
            // Not the "N records of equal size" shape — refuse rather than slice at a wrong stride.
            return []
        }

        var events: [DingTalkA1UtEvent] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            let base = 4 + index * stride
            guard base + 20 <= bytes.count else { break }
            let sequence = (UInt16(bytes[base]) << 8) | UInt16(bytes[base + 1])
            // u48 big endian: the card's clock (Unix seconds — verified against real reports).
            var seconds: UInt64 = 0
            for offset in 2..<8 {
                seconds = (seconds << 8) | UInt64(bytes[base + offset])
            }
            let id = (UInt32(bytes[base + 8]) << 24) | (UInt32(bytes[base + 9]) << 16)
                | (UInt32(bytes[base + 10]) << 8) | UInt32(bytes[base + 11])
            var value: UInt64 = 0
            for offset in 12..<20 {
                value = (value << 8) | UInt64(bytes[base + offset])
            }
            events.append(
                DingTalkA1UtEvent(
                    sequence: sequence,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(seconds)),
                    id: id,
                    value: value
                )
            )
        }
        return events
    }
}
