import Foundation

// MARK: - Application layer of TicNote Wi-Fi fast transfer (pure logic, no dependency on Network / CoreBluetooth)
//
// ## Sources of evidence
// All from `ticnote-re/decompiled/classes6/sources/com/mobvoi/wifi_plugin/`:
//   · `socket/WifiProtocol.java`   —— port and cmder constant table
//   · `socket/WifiDataVo.java`     —— **byte-level frame layout (this file's implementation follows it line by line)**
//   · `WifiPlugin.java`            —— JSON field names of each cmder and where they are actually built
//   · `socket/ConnectWifiUtils.java` —— how the phone joins the AP
// Cross-checked against the Dart-side log strings (`blutter_out/pp.txt`):
//   `" Start opening WebSocket: port=8081, uuid="` / `"token"` / `"1234567890000000"` / `"old"`
//
// ## ⛔ The direction call in round 7 was wrong; corrected here
// `protocol-notes.md` §0quinquies said "card-side server (the one we connect to)" ——
// **that is backwards**. The real direction:
//
//   ```
//   Phone = WebSocket **server** (WifiPlugin.openSocket → org.java_websocket.server.WebSocketServer)
//   Card = WebSocket **client** (connects in, sends cmder=2 SAY_HELLO first)
//   ```
//
// Three consistent pieces of evidence:
//   1. `WifiPlugin.openSocket` uses `WebSocketServer` + `new InetSocketAddress(port)` + `start()`;
//      `sendDataToWifi` sends to `socketListener.getClientConn()` (**the connection the server accepted**).
//   2. `closeDevice` logs `"---client closeSocket ---"` and checks `getClientConn() == null`
//      → only "not connected" when no client has connected in.
//   3. On `cmder == 2`, `WifiPlugin`'s `onMessage` prints **`"received devices request hand!"`**
//      ("device requests handshake") and replies with `cmder = 1`. The device = the card.
//
// This correction is not wordplay; it decides what the iOS side must do:
// **iOS must start a listener itself** (Foundation only has a client, so the handshake / framing must be written by hand,
//   see `Sources/Services/Net/WebSocketFraming.swift`), rather than "connecting to the card's 8081".
//
// ## Another correction: the card is the AP, the phone is the joiner
// `ConnectWifiUtils.connectWifi` goes through `addNetwork` / `WifiNetworkSpecifier` /
// `WifiNetworkSuggestion` —— all of which **join** a network. So the SSID / password belong to **the card's hotspot**,
// and are delivered by the card over BLE (`WifiStatusEvent`). The §0quinquies note that "host must be an empty string, waiting for the BLE override"
// is still right, but should be read as "the empty string is because that is **someone else's** address, and the direction is card connecting to us".

// MARK: - cmder table

/// Merged table of `WifiProtocol.WifiRequest` / `WifiResponse`.
///
/// ⚠️ This uses `static let` rather than a Swift enum for two reasons, neither of them taste:
///   1. **`3` and `12` have different directions but the same number** (`3` is called PONG on the request side and PING on the response side;
///      `12` is called FILE_SYNC on the request side and FILE_SYNC_STATUS on the response side). Swift enums do not allow duplicate rawValues.
///   2. `0x11 / 0x13 / 0x14` (16/18/19/20) are **not in the interface constant table**,
///      and are only built in `WifiPlugin` —— an enum would give the false impression that "this is everything".
enum TicNoteWifiCmder {

    // ── Same name and number in both directions (semantics differ by direction) ─────────────────────────
    /// Card → phone: error
    static let universalError: UInt16 = 0
    /// Phone → card: handshake reply (answers the card's SAY_HELLO)
    static let handshake: UInt16 = 1
    /// Card → phone: **the first message the card sends after connecting** (`"received devices request hand!"`)
    static let sayHello: UInt16 = 2
    /// Card → phone = PING; phone → card = PONG. **The direction is reversed**, don't mix them up.
    static let heartbeat: UInt16 = 3
    /// Phone → card: turn off Wi-Fi (`{"status":1}`); card → phone is likewise a wrap-up notification
    static let wifiClose: UInt16 = 4
    /// Card → phone: notice
    static let tips: UInt16 = 5
    /// Phone → card: fetch file list; card → phone: list reply (json + bin)
    static let getFileList: UInt16 = 11
    /// Phone → card: start sync (V1); card → phone: sync status (`{"status":…}`)
    static let fileSync: UInt16 = 12
    /// Card → phone: file content chunk (json + bin) —— **the backbone of downloading**
    static let fileSyncContent: UInt16 = 13
    /// Phone → card: delete file (`{"session","scene"}`)
    static let fileDelete: UInt16 = 14
    /// Phone → card: stop sync; card → phone: stop receipt (`{"status":0}` means resuming may continue)
    static let fileSyncStop: UInt16 = 15
    /// Phone → card: OTA push (`{"uid","from","to","size","crc"}`)
    static let otaFile: UInt16 = 16
    /// Phone → card: OTA data chunk (`{"offset","length"}` + bin)
    static let otaData: UInt16 = 18

    // ── ★★★ V2 (19 / 20): the official App **never calls it even once**, and the card explicitly rejects it on real hardware ────
    //
    // 2026-10-12 conclusion from both sides (real device + Dart reverse-engineering cross-check), **changed the main flow**:
    //
    // [Real device] The first request we sent after a successful fast-transfer handshake was cmder 20, and the card sent back two frames:
    //   `← cmder=1 {"status":0}` (handshake accepted) +
    //   `← cmder=0 {"cmd":20,"code":3}` (**explicitly rejects cmd 20**).
    //   After that, 11 heartbeats were still sent and the list got no reply in 30 s. The 4 attempts had exactly the same shape
    //   (20:35:36 / 20:36:23 / 20:38:26 / 09:37:08).
    //
    // [Dart] In the official App snapshot, both entry points go through V1:
    //   · `wifi_logic.dart::_handShakeReturn`(0x107b66c)  → `WifiPlugin::getFileList` (cmder 11)
    //   · `recording_logic.dart::handShakeReturn`(0x1045764) → the same `getFileList`
    //   · `wifi_logic.dart::_downloadFile`(0x1043b7c)     → `WifiPlugin::downFileList` (cmder 12)
    //   while the **method names** `getFileListV2` / `downFileListV2` **never appear even once
    //   in the entire Dart snapshot** —— V2 is only registered on the Java side, and this build of the App never reaches it.
    //   The log literal in recording_logic states the intent plainly:
    //   `"🤝 WiFi fast transfer unified to legacy path, sending getFileList request: "` ("unified to the legacy path").
    //
    // So the main flow now uses **V1 (11 / 12)**. The two constants below are kept for two reasons only:
    // ① if some future firmware drops V1, there is a named place to land;
    // ② when 19 / 20 show up in logs / packet captures they can be recognised.
    /// Phone → card: start download (V2, one more `fileType` than 12)
    static let downFileListV2: UInt16 = 19
    /// Phone → card: fetch file list (V2)
    static let getFileListV2: UInt16 = 20
    static let speedTest: UInt16 = 100
    static let getLog: UInt16 = 101

    /// A few that are not in the interface constant table and only appear in `WifiPlugin`.
    /// They are listed here to make "values outside the table" **visible** —— when you see them in logs, don't assume you misread.
    static let declaredOnlyInPlugin: Set<UInt16> = [16, 18, 19, 20]
}

// MARK: - Frame (a line-by-line implementation of `com.mobvoi.wifi_plugin.socket.WifiDataVo`)

/// A value type corresponding one-to-one with `WifiDataVo`.
///
/// Wire layout (identical in both directions, **no magic number, no CRC**):
/// ```
/// [0..2]  totalLen  u24 LE   ← includes these 3 bytes themselves
/// [3]     version   = 1
/// [4..5]  cmder     u16 LE
/// [6..7]  jsonLen   u16 LE   ← ⚠️ present only when json is non-empty
/// [8..]   json      (jsonLen bytes)
/// [...]   bin       (the rest = totalLen − 8 − jsonLen)
/// ```
///
/// ## ⚠️ Two quirks that must be copied verbatim + one deliberate deviation
/// 1. **When json is empty the `jsonLen` field is not written at all** (`toWriteData` writes it only when `jsonStr` is non-empty),
///    so a pure control frame has `totalLen` of only `3 + 3 = 6`. The decoder uses `length >= 8` to decide whether the field exists,
///    so the two sides are self-consistent. The heartbeat PONG is exactly such a frame —— **6 bytes** (self-check §20 pins it down).
///    A corroborating side note: `init`'s entry check reports "init data too short" on `bArr.length < 6` ——
///    **6 is exactly the minimum legal length of this format**; two independent pieces of information line up.
/// 2. **When decoding, each of the two cmder bytes is ANDed with `kotlin.UByte.MAX_VALUE` (= `0x7F`, not `0xFF`)**.
///    This is an asymmetry in the official implementation (the encoder writes all 8 bits, the decoder drops the top bit).
///    All existing cmders are ≤ 101 and the high byte is always 0, so the difference is invisible; but we **copy** it,
///    rather than "fixing" it —— because if the peer ever sends a cmder ≥ 128,
///    a "spec-compliant" implementation would decode a different number from the official App.
/// 3. ★ **One deliberate deviation**: on a frame "with bin but without json", the official decoder misreads the first two payload bytes
///    as jsonLen and then drops the whole bin (it can encode it itself but cannot decode it back).
///    At that one spot we give the correct result, and **for every frame the official decoder can decode we are byte-for-byte identical to it**.
///    The full argument is in the comments of `decode(_:)`.
struct TicNoteWifiFrame: Equatable {

    var version: UInt8
    var cmder: UInt16
    /// nil and the empty string are equivalent (officially it is `jsonStr == null` or `trim().isEmpty()`)
    var json: String?
    var bin: Data?

    init(cmder: UInt16, json: String? = nil, bin: Data? = nil, version: UInt8 = 1) {
        self.version = version
        self.cmder = cmder
        self.json = json
        self.bin = bin
    }

    /// Hand-written `==`: **deliberately does not compare `declaredLength`**.
    /// It is the "length the peer claims", which is diagnostic information and plays no part in deciding "are these two the same frame" ——
    /// otherwise "construct a frame vs decode a frame" in the self-check would never be equal (the former never went through the decode path).
    static func == (lhs: TicNoteWifiFrame, rhs: TicNoteWifiFrame) -> Bool {
        lhs.version == rhs.version && lhs.cmder == rhs.cmder
            && lhs.json == rhs.json && lhs.bin == rhs.bin
    }

    // MARK: Encoding

    func encoded() -> Data {
        var body = Data()
        body.append(version)
        body.append(UInt8(cmder & 0xFF))
        body.append(UInt8((cmder >> 8) & 0xFF))

        // See quirk 1 in the type comment: with empty json even the length field is not written.
        let jsonBytes = (json?.isEmpty == false) ? Data(json!.utf8) : nil
        if let jb = jsonBytes {
            body.append(UInt8(jb.count & 0xFF))
            body.append(UInt8((jb.count >> 8) & 0xFF))
            body.append(jb)
        }
        if let bin, !bin.isEmpty {
            body.append(bin)
        }

        let total = body.count + 3
        var out = Data()
        out.append(UInt8(total & 0xFF))
        out.append(UInt8((total >> 8) & 0xFF))
        out.append(UInt8((total >> 16) & 0xFF))
        out.append(body)
        return out
    }

    // MARK: Decoding

    /// Equivalent to `WifiDataVo.init(byte[])` —— **but with one deliberate deviation**, see below.
    ///
    /// It **does not validate** whether `totalLen` matches the actual length (the official code doesn't either),
    /// but records the mismatch in `declaredLength`, so callers can see "the peer miscounted" in logs.
    ///
    /// ## ⚠️ Deliberate deviation: the official decoder drops the bin on a frame "with bin but without json"
    ///
    /// The official bin length is `(totalLen - 8) - jsonLen`. That `8` assumes
    /// **the header is always 8 bytes** (including the jsonLen field). But when json is empty `toWriteData`
    /// **does not write the jsonLen field at all**, and the header is then only 6 bytes. As a result:
    ///
    /// ```
    /// Encoded:  09 00 00 01 0D 00 AA BB CC        (cmder 13, bin = AA BB CC, no json)
    /// Official decode: jsonLen = u16(bytes[6..7]) = 0xBBAA = 48042   ← what it read is the first two payload bytes
    ///         binLen = (9 - 8) - 48042 = negative → the whole bin is dropped
    /// ```
    /// That is, **the official code can encode it but cannot decode it back**. This is not our guess: in self-check §20
    /// there is a reference implementation (`officialDecode`) copied line by line from the official `init`,
    /// which gives `bin == nil` for this frame while ours gives the correct 3 bytes —— the difference is pinned by an assertion.
    ///
    /// **Why we dare to deviate**: the deviation only takes effect on inputs where "the official code necessarily loses data".
    /// The criterion is "is the jsonLen field trustworthy" (`jsonLen>0 && jsonLen+8 <= actual length && jsonLen <= totalLen-8`);
    /// every frame that passes this check takes a path **byte-for-byte identical** to the official one.
    /// In other words: for frames the official code can decode, we agree with it exactly (the self-check compared 5 frames field by field);
    /// for frames it cannot decode, we give the correct result instead of silently dropping data.
    ///
    /// Real-world impact: the frames the card sends with a bin (11/20 list, 13 content, 18 OTA) **all carry json too**,
    /// so this deviation does not change any real behavior under the current protocol —— it guards against "some future firmware
    /// sending a bin-only frame". In that case, copying the official code would produce the symptom "the file comes out as 0 bytes,
    /// but the state machine says the transfer succeeded", which is very hard to track down.
    static func decode(_ data: Data) throws -> TicNoteWifiFrame {
        let b = [UInt8](data)
        guard b.count >= 6 else {
            throw RecorderLinkError.malformed("WifiDataVo needs ≥ 6 B, got \(b.count)")
        }
        let declared = Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16)
        let version = b[3]
        // Quirk 2: low 7 bits. Copies `(bArr[5] & UByte.MAX_VALUE) << 8) + (bArr[4] & UByte.MAX_VALUE)`.
        let cmder = UInt16(b[5] & 0x7F) << 8 | UInt16(b[4] & 0x7F)

        // Whether the jsonLen field itself is trustworthy (see the method comment). Untrustworthy = this frame has no json segment.
        var jsonLen = 0
        var json: String?
        if b.count >= 8 {
            let candidate = Int(b[6]) | (Int(b[7]) << 8)
            let room = declared - 8            // how much json + bin can occupy in total per the declaration
            if candidate > 0, candidate + 8 <= b.count, candidate <= room {
                jsonLen = candidate
                json = String(decoding: b[8..<(8 + candidate)], as: UTF8.self)
            }
        }

        // The header length depends on **whether the jsonLen field exists**: 8 = yes, 6 = no.
        // The official code hard-codes this 6/8 difference as 8, which is the source of the bug above.
        let headerLen = json != nil ? 8 : 6
        let payloadLen = min(declared - headerLen - jsonLen, b.count - headerLen - jsonLen)

        var bin: Data?
        if payloadLen > 0 {
            let start = headerLen + jsonLen
            bin = Data(b[start..<(start + payloadLen)])
        }

        var frame = TicNoteWifiFrame(cmder: cmder, json: json, bin: bin, version: version)
        frame.declaredLength = declared
        return frame
    }

    /// The total length the peer claims. For diagnostics only (see the `decode` comment).
    private(set) var declaredLength: Int = 0

    var bodyByteCount: Int { encoded().count }
}

// MARK: - JSON

/// A minimal JSON generator.
///
/// ## Why hand-written instead of `JSONSerialization`
/// `JSONSerialization` does not guarantee key order. And this project's self-check is **byte-by-byte**
/// (the 353 requests in §18 are pinned that way), so with unstable key order bytes cannot be asserted.
///
/// ## Key order follows fastjson's default behavior
/// The official code uses `com.alibaba.fastjson.JSONObject`, whose `MapSerializer` by default carries
/// `SerializerFeature.MapSortField` → keys are output in alphabetical order.
///
/// ⚠️ **But key order actually doesn't matter**: the peer also parses with fastjson, and dictionary semantics ignore order.
/// Sorting here is purely to make the output **reproducible**, so the self-check can assert whole-frame bytes.
/// That is, if it turns out the official code doesn't sort, change this one spot; correctness is unaffected —— this is also noted in the self-check comments.
enum TicNoteWifiJSON {

    enum Value: Equatable {
        case int(Int64)
        case text(String)
        case flag(Bool)
    }

    static func object(_ fields: [String: Value]) -> String {
        let body = fields.keys.sorted().map { key in
            "\"\(escape(key))\":\(literal(fields[key]!))"
        }.joined(separator: ",")
        return "{\(body)}"
    }

    static func array(_ items: [String]) -> String {
        "[" + items.joined(separator: ",") + "]"
    }

    private static func literal(_ v: Value) -> String {
        switch v {
        case .int(let n):   return String(n)
        case .flag(let b):  return b ? "true" : "false"
        case .text(let s):  return "\"\(escape(s))\""
        }
    }

    /// Only handles the escapes JSON requires. Quotes/backslashes may appear in credentials; everything else goes through as-is.
    /// Control characters are emitted as `\u00XX`, consistent with fastjson.
    private static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"":  out += "\\\""
            case "\\":  out += "\\\\"
            case "\n":  out += "\\n"
            case "\r":  out += "\\r"
            case "\t":  out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

// MARK: - Outbound: frame builders
//
// Each one can be pointed to a specific line in `WifiPlugin.java`. The line numbers in the comments are those of the decompiled output,
// so the next person can jump straight to the original without searching again.

enum TicNoteWifiOutbound {

    /// Handshake reply (`WifiPlugin.java:1045-1053`, sent on receiving `cmder == 2`).
    ///
    /// `stamp` is `System.currentTimeMillis() / 1000` officially (**seconds**, not milliseconds ——
    /// in the official code it is `/ MSG_ON_MESSAGE` with `MSG_ON_MESSAGE = 1000`; that constant name is a trap).
    static func handshake(token: String, stamp: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.handshake,
            json: TicNoteWifiJSON.object(["token": .text(token), "stamp": .int(stamp)])
        )
    }

    /// Heartbeat PONG. **No json, no bin** → the whole frame is `3 + 3 = 6` bytes
    /// (which is this format's **minimum legal length**; the check at the official decode entry is an error on `< 6`).
    /// Officially the same reused `WifiDataVo(3)` is sent repeatedly (`WifiPlugin.java:1055-1060`).
    static func heartbeatPong() -> TicNoteWifiFrame {
        TicNoteWifiFrame(cmder: TicNoteWifiCmder.heartbeat)
    }

    /// Fetch file list V1 (`WifiPlugin.java:442-459`). ★★ **This is the one the main flow uses.**
    ///
    /// ⚠️ The **semantics** of the three fields `uid` / `single` / `start` are still unconfirmed (the Java side just stuffs
    /// the three `Integer`s passed in from Dart into the JSON as-is). So no defaults are given here either ——
    /// the caller must always supply the values explicitly, and the **only evidence-backed values** are
    /// `TicNoteWifiListRequest.official*` (that one spot has a disassembly source).
    /// That is the temptation of defaults: they disguise "don't know" as "know".
    static func getFileList(uid: Int64, start: Int64, single: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.getFileList,
            json: TicNoteWifiJSON.object([
                "uid": .int(uid), "start": .int(start), "single": .int(single),
            ])
        )
    }

    /// Fetch file list V2 (`WifiPlugin.java:461-478`): fields identical to V1, only the cmder is 20.
    ///
    /// ⛔ **The official App never calls it**, and on real hardware the card rejects it outright (see the top of `TicNoteWifiCmder`).
    /// Kept only for regression assertions and "future firmware".
    static func getFileListV2(uid: Int64, start: Int64, single: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.getFileListV2,
            json: TicNoteWifiJSON.object([
                "uid": .int(uid), "start": .int(start), "single": .int(single),
            ])
        )
    }

    /// Start sync V1 (`WifiPlugin.java:864-870`). **Resuming also uses it** (`sendResumeDownloadRequest`).
    /// No `fileType`.
    static func fileSync(session: Int64, scene: Int64, start: Int64, end: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.fileSync,
            json: TicNoteWifiJSON.object([
                "session": .int(session), "scene": .int(scene),
                "start": .int(start), "end": .int(end),
            ])
        )
    }

    /// Start download V2 (`WifiPlugin.java:518-525`): one more `fileType` than V1.
    ///
    /// The newer official version uses this one (`downFileListV2`); V1 (`downFileList`) is kept for older firmware.
    static func downFileListV2(session: Int64, scene: Int64, start: Int64,
                              end: Int64, fileType: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.downFileListV2,
            json: TicNoteWifiJSON.object([
                "session": .int(session), "scene": .int(scene), "start": .int(start),
                "end": .int(end), "fileType": .int(fileType),
            ])
        )
    }

    /// Delete file (`WifiPlugin.java:892-896`).
    static func fileDelete(session: Int64, scene: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.fileDelete,
            json: TicNoteWifiJSON.object(["session": .int(session), "scene": .int(scene)])
        )
    }

    /// Turn off Wi-Fi (`WifiPlugin.java:911-913`, `{"status":1}`).
    ///
    /// Unlike the BLE path's "stop-charging-style wrap-up", here it is **mandatory to send** ——
    /// if not sent, the card's hotspot stays on and drains power (the official code only calls `releaseWifi()` after receiving `cmder == 4`).
    static func wifiClose() -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.wifiClose,
            json: TicNoteWifiJSON.object(["status": .int(1)])
        )
    }

    /// Stop sync.
    ///
    /// ⚠️ **Inferred value**: `WifiProtocol.WifiRequest.FILE_SYNC_STOP = 15` is definite,
    /// but `WifiPlugin` has **no place that builds 15** (the Dart side should go through another method-channel branch,
    /// which was not left in the decompiled output). So the payload field names are inferred from the shape of `fileDelete`,
    /// marked as not measured —— used only on the "user tapped cancel" path where resuming is not intended.
    static func fileSyncStop(session: Int64, scene: Int64) -> TicNoteWifiFrame {
        TicNoteWifiFrame(
            cmder: TicNoteWifiCmder.fileSyncStop,
            json: TicNoteWifiJSON.object(["session": .int(session), "scene": .int(scene)])
        )
    }
}

// MARK: - Inbound: parsing

/// One file record in the reply to `cmder == 11 / 20`.
///
/// ## The layout is **not guessed** —— read byte by byte from the official Dart disassembly and verified on real hardware
///
/// Real-device sample (2026-10-12): `← cmder=11 json={"uid":0,"status":0,"count":57,"offset":0} bin=570B`
/// → 570 ÷ 57 = **exactly 10 bytes per record**.
///
/// Loop body of `WifiLogic::_parseFileItems`(0x1044904):
/// ```
/// x2  = i * 10                     ; record base address
/// ldrsw  x9,  [data + x5 + x2]     ; ★ i32 @ +0  → sessionId (log string "] sessionId=")
/// ldrsw  x11, [data + x5 + x2+4]   ; ★ i32 @ +4  → fileSize (log string ", fileSize=")
/// ldrsh  x13, [data + x5 + x2+8]   ; ★ i16 @ +8  → prop
/// cmp x13, #2 ; "mp3" else "opus"  ; prop == 2 → mp3
/// ```
/// AArch64 is little-endian, so all three fields are **little-endian**. `ldrsw/ldrsh` sign-extend,
/// but `sessionId` is Unix seconds (< 2^31) and `fileSize` is a byte count, so both are normally positive.
///
/// The JSON segment (`{"uid":0,"status":0,"count":N,"offset":0}`) is **only metadata**;
/// the official code just logs it, and the list itself is entirely in `bin`.
struct TicNoteWifiFileEntry: Equatable {
    let sessionId: UInt32
    let sizeBytes: UInt32
    /// 2 = mp3, any other value = opus (the official code has only this one dichotomy; no further semantics are guessed).
    let prop: Int

    /// The raw value of the official `FileItem`'s `prop` field.
    var fileType: UInt16? { UInt16(truncatingIfNeeded: prop) }
    var isMP3: Bool { prop == 2 }
    /// Start time (seconds) self-reported by the card. `sessionId` is this (same source as the BLE channel).
    var startSeconds: UInt32? { sessionId == 0 ? nil : sessionId }
    var startedAt: Date? {
        startSeconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

enum TicNoteWifiFileList {

    /// Bytes per record (see the comments of `TicNoteWifiFileEntry`).
    static let recordBytes = 10
    /// `prop == 2` means mp3 (the official `cmp x13, #2` in `_parseFileItems`).
    static let propMP3 = 2

    /// Parses the file list out of `bin` (an array of little-endian 10-byte records); the `json` header is used only for **cross-checking**.
    ///
    /// - Returns: the entry array on success (possibly empty —— meaning "no files on the card");
    ///            `nil` when the shape is not recognised (**not the same thing as an empty array**).
    static func parse(frame: TicNoteWifiFrame) -> [TicNoteWifiFileEntry]? {
        // Official path: the list itself is in bin. When bin is missing/empty, look at count in the JSON header:
        //   count == 0 → really no files (legal, return an empty array)
        //   count != 0 → claims files exist but gives no bin → wrong shape, fail
        guard let bin = frame.bin, !bin.isEmpty else {
            if let count = jsonCount(in: frame.json), count == 0 { return [] }
            return nil
        }

        // ★ The bin length must be a multiple of 10. A remainder means this is not the record format we recognise ——
        //   better to fail than to read misaligned (a misaligned sessionId would request a nonexistent file,
        //   with the symptom "the transfer ends immediately but the file is empty").
        guard bin.count % recordBytes == 0 else { return nil }

        let entries: [TicNoteWifiFileEntry] = stride(from: 0, to: bin.count, by: recordBytes).map {
            TicNoteWifiFileEntry(
                sessionId: bin.subdata(in: $0 ..< $0 + 4).withUnsafeBytes {
                    $0.loadUnaligned(as: UInt32.self)   // little-endian (AArch64 / ARM are both LE)
                },
                sizeBytes: bin.subdata(in: $0 + 4 ..< $0 + 8).withUnsafeBytes {
                    $0.loadUnaligned(as: UInt32.self)
                },
                prop: bin.subdata(in: $0 + 8 ..< $0 + 10).withUnsafeBytes {
                    Int(Int16(truncatingIfNeeded: $0.loadUnaligned(as: Int16.self)))
                }
            )
        }

        // Cross-check: count in the JSON header should equal the record count (both are 57 in the real-device sample).
        // A mismatch is **not** treated as failure —— the official code doesn't look at this number at all; we only put the difference in the log.
        if let count = jsonCount(in: frame.json), count != entries.count {
            TicNoteDiagLog.log(
                "WIFI",
                "List entry count mismatch: json.count=\(count) but bin decoded \(entries.count) entries"
                + " (bin \(bin.count)B). Continuing with bin as the source of truth.")
        }
        return entries
    }

    /// `count` in the JSON header (nil if unreadable; no guessing).
    static func jsonCount(in json: String?) -> Int? {
        guard let json, !json.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let n = object["count"] as? NSNumber
        else { return nil }
        return n.intValue
    }

    /// For diagnostics: lay out the first few records as hex (for real-device comparison; don't dump it all on a long list).
    static func hexDumpPrefix(_ bin: Data, records: Int = 4) -> String {
        let n = min(bin.count, records * recordBytes)
        guard n > 0 else { return "(empty)" }
        return bin.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ")
            + (bin.count > n ? " …(\(bin.count)B)" : "")
    }
}

/// The `{"status": n}` carried in `cmder == 12 / 15 / 19`. `0` = success.
struct TicNoteWifiStatus: Equatable {
    let raw: Int

    static func parse(frame: TicNoteWifiFrame) -> TicNoteWifiStatus? {
        guard let json = frame.json, !json.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let n = object["status"] as? NSNumber
        else { return nil }
        return TicNoteWifiStatus(raw: n.intValue)
    }

    var isOK: Bool { raw == 0 }
}

/// The `cmder == 0` error frame the card sends back: `{"cmd":N,"code":M}`.
///
/// ## The semantics are **not guessed**; they were derived by comparing two real-device samples
/// ```
/// We send  → cmder 20  {"single":1,"start":0,"uid":0}      (fetch list V2)
/// Card connects back  ← cmder 1   {"status":0}                        (handshake accepted)
/// Card connects back  ← cmder 0   {"cmd":20,"code":3}                 (explicitly says cmd 20 was not accepted)
/// ```
/// `cmd` is **the cmder of the rejected request** (20 is exactly the one just sent),
/// and `code` is the card-side reason code. All 4 fast-transfer attempts gave the same pair of numbers.
///
/// ⚠️ The value table of `code` has **not been decoded** (the official Java side has no case at all for `cmder == 0` ——
/// it falls into `default: return`, i.e. when the official App receives this frame it **does nothing**
/// and keeps waiting for the list). So here the raw values are just laid out for people and logs, and **no** name is invented for them.
struct TicNoteWifiUniversalError: Equatable {
    /// Command code of the rejected request
    let cmd: UInt16
    /// Card-side reason code (semantics unresolved, passed through only)
    let code: Int

    static func parse(frame: TicNoteWifiFrame) -> TicNoteWifiUniversalError? {
        guard frame.cmder == TicNoteWifiCmder.universalError,
              let json = frame.json, !json.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                                as? [String: Any],
              let cmd = (object["cmd"] as? NSNumber)?.intValue
        else { return nil }
        return TicNoteWifiUniversalError(
            cmd: UInt16(truncatingIfNeeded: cmd),
            code: (object["code"] as? NSNumber)?.intValue ?? -1
        )
    }

    /// One-line summary for logs/errors.
    var description: String { "card refused cmd \(cmd) (code \(code))" }
}

/// Content chunk of `cmder == 13`. `json` may carry an offset, and `bin` is the data itself.
///
/// The official code writes to disk by **appending in order** (`FileOutputStream(path, true)` + `getChannel().size()`),
/// and the completion criterion is `bytes written >= fileSize` (the branch `if (r12 >= r3.longValue())`
/// decompiled from `saveFileData`). So whether there is an offset is actually optional:
/// if there is, place by offset (gaps can be detected); if not, append in order.
struct TicNoteWifiContentChunk {
    let json: String?
    let offset: Int?
    let length: Int?
    let data: Data

    static func parse(frame: TicNoteWifiFrame) -> TicNoteWifiContentChunk? {
        guard let data = frame.bin, !data.isEmpty else { return nil }
        var offset: Int?
        var length: Int?
        if let json = frame.json, !json.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
            offset = (object["offset"] as? NSNumber)?.intValue
            length = (object["length"] as? NSNumber)?.intValue
        }
        return TicNoteWifiContentChunk(json: frame.json, offset: offset, length: length, data: data)
    }
}

/// **Parameters** for fetching the file list (the values of the three fields `uid` / `start` / `single`).
///
/// ## Why it is a separate type
/// The semantics of these three fields are **still unresolved** (`WifiPlugin.getFileList` just stuffs the three
/// `Integer`s passed in from Dart into the JSON as-is). Since they cannot be decoded, the only responsible approach is
/// to **copy that official call site byte for byte**, and state clearly "which line was copied".
/// Before that, we filled in values that merely "looked reasonable" (`start: 0` / `single: 1`),
/// which amounted to writing "don't know" as "know".
///
/// ## Disassembly of that official call site (both entry points are byte-identical)
/// ```
/// wifi_logic.dart      _handShakeReturn   0x107b66c
/// recording_logic.dart handShakeReturn    0x1045764
///
///   r16 = "uid"    → StoreField r2->field_f  = this.field_2b
///   r16 = "single" → StoreField r2->field_1b = rZR        ← zero register = 0
///   r16 = "start"  → StoreField r2->field_23 = [pp+0x2cf18] Mint: 0x66350a00
/// ```
/// * `single = 0`: `rZR` is ARM64's zero register, and `stur wzr, [x2, #0x1b]` writes 0.
///   We previously filled in 1 (inferred from the comment "probably only wants one entry"), which had **no basis**.
/// * `start = 0x66350A00 = 1714752000` (measured: at that spot it is a `Mint` constant,
///   not `DateTime.now()`): it is neither the current time nor "the previous entry's sid",
///   so "start from the beginning, so fill in 0" likewise has no basis. **Copy the constant.**
/// * `uid`: initialised to **0** in `WifiLogic`'s constructor via `StoreField r1->field_2b = rZR`,
///   and written nowhere else afterwards → always 0. (The line at `0xe2d62c`.)
enum TicNoteWifiListRequest {

    /// The official hard-coded `start`. `0x66350A00` = 2024-05-03T16:00:00Z.
    static let officialStart: Int64 = 1_714_752_000

    /// The official hard-coded `single` (zero register).
    static let officialSingle: Int64 = 0

    /// The official hard-coded `uid` (set to 0 at construction, never written again).
    static let officialUID: Int64 = 0
}

// MARK: - Connection parameters (delivered by the BLE side; none may be hard-coded)

/// Network endpoint constants. Placed in the protocol layer rather than the transport layer so that **they can be asserted in the command-line self-check**
/// (`TicNoteWifiLink` depends on `NWListener`, which is not in the self-check's compilable set).
enum TicNoteWifiEndpoint {
    /// The official Dart `" Start opening WebSocket: port=8081, uuid="` and Java's
    /// `WifiProtocol.WEB_SOCKET_PORT` both point to 8081.
    ///
    /// ⚠️ After the direction correction, it means **the port we ourselves listen on**, not "the port to connect to" ——
    /// the phone is the server. See the top of this file.
    static let port: UInt16 = 8081
}

/// Wi-Fi parameters the card pushes over BLE.
///
/// ## The key names now have a **source**; they are no longer guesses
/// The official plugin's **event dispatch table** reads all 8 keys in one go, and consecutively:
/// the section of `blutter_out/asm/nveasy_ble_plugin/nveasy_ble_plugin.dart`
/// `0xdb6f48 → 0xdb72b8`, read in order
/// `wifiStatus` → `wifiOpened` → `wifiServerIp` → `wifiServerPort`
/// → `wifiClientIp` → `wifiClientPort` → `wifiSsid` → `wifiSsidPassword`
/// (the string pool `[pp+0x15d88] … [pp+0x15de0]` also forms one contiguous block).
/// So this set is the complete field table of the Wi-Fi status event.
///
/// ## ★★★ The credentials are actually **computed locally**, not reported by the card (confirmed on a real device with the official App, 2026-10-09)
/// This overturns the core assumption this type previously held. Original on-device logcat of the official App:
/// ```
/// Received WIFI info: {ssid: TicNote-3N9H, passwd: Y36W3N9H}
/// 🌐 Start connecting to recorder WiFi: SSID=TicNote-3N9H, first 4 chars of password=Y36W***
/// ```
/// And this card's SN is `S02510YCY36W3N9H` —— so:
/// ```
/// SSID = "TicNote-" + SN[-4:]  →  TicNote-3N9H
/// Password =             SN[-8:]   →  Y36W3N9H
/// ```
/// **Both values are determined purely by the SN.** Just compute them directly with `hotspotSSID(fromSN:)` / `hotspotPSK(fromSN:)`
/// (see `from(sn:)`); there is **no need** to wait for a `wifiSsidPassword` event over BLE any more.
/// The full evidence chain and measured timings are in `ticnote-re/protocol-notes.md` §18.
///
/// Why the official code looks like "the card reported the password": `WifiPlugin.connectWifi` (Java, from `0x582`) does indeed
/// take it from `call.argument("ssid"/"passWord")`, and `wifiBean.setCapabilities("PSK")` hard-codes WPA2.
/// But those two arguments are **computed/assembled by the App itself on the Dart side**,
/// and `wifiSsid`/`wifiSsidPassword` are merely field names of its internal event channel, not "raw bytes given by the card".
/// This is also why the "deadlock" of §17 —— "the card doesn't send the password until the hotspot is on, and once the hotspot is on it doesn't send over BLE" —— **never actually existed**:
/// we had been treating it as "an external input that must be captured".
///
/// ## Why BLE frame parsing is still kept
/// `parse(_:)` / `parseBLEFrame(_:)` are kept for **cross-checking**: if future firmware changes the rule (e.g. no longer derived from the SN),
/// the card-reported values will disagree with the locally computed ones, and then the card-reported ones win. The naming layer is uncertain
/// (Dart's `"ssid"`/`"passwd"` vs the transport layer's `wifiSsid`/`wifiSsidPassword`), so **both layers are accepted**.
struct TicNoteWifiCredentials: Equatable {
    let ssid: String
    /// The `WIFI_CIPHER_NO_PASS` case **exists** (see the three encryption capabilities of `ConnectWifiUtils`),
    /// so an empty password is a legal value and must not be treated as "not obtained".
    let passphrase: String
    /// Card-side server address. **Its meaning changed after the direction correction**: the phone is the server,
    /// so this field is "which address the card tells us can be used to interconnect", not "the address we should connect to".
    /// Kept only for logging and future cross-verification.
    let serverHint: String?
    let serverPort: UInt16?
    let clientHint: String?
    let clientPort: UInt16?

    static let ssidKeys = ["ssid", "wifiSsid", "wifi_ssid", "SSID"]
    static let passKeys = ["passwd", "password", "passWord", "wifiSsidPassword", "psk"]
    static let serverIPKeys = ["serverIp", "wifiServerIp", "ip"]
    static let serverPortKeys = ["serverPort", "wifiServerPort", "port"]
    static let clientIPKeys = ["clientIp", "wifiClientIp"]
    static let clientPortKeys = ["clientPort", "wifiClientPort"]

    /// Decodes the credentials from a BLE event map.
    ///
    /// - Returns: `nil` = **no ssid** (= the card has not opened its hotspot yet / this event is not a Wi-Fi status event).
    ///            An empty ssid also counts as none —— passing an empty SSID to `NEHotspotConfiguration` only yields
    ///            a vague system error.
    static func parse(_ map: [String: Any]) -> TicNoteWifiCredentials? {
        func str(_ keys: [String]) -> String? {
            for key in keys {
                if let s = map[key] as? String { return s }
            }
            return nil
        }
        func port(_ keys: [String]) -> UInt16? {
            for key in keys {
                if let n = map[key] as? NSNumber { return UInt16(truncatingIfNeeded: n.intValue) }
                if let s = map[key] as? String, let n = UInt16(s) { return n }
            }
            return nil
        }
        guard let ssid = str(ssidKeys), !ssid.isEmpty else { return nil }
        return TicNoteWifiCredentials(
            ssid: ssid,
            passphrase: str(passKeys) ?? "",
            serverHint: str(serverIPKeys),
            serverPort: port(serverPortKeys),
            clientHint: str(clientIPKeys),
            clientPort: port(clientPortKeys)
        )
    }

    /// Tries to decode Wi-Fi credentials from a **BLE control frame**.
    ///
    /// The frame is `[type 0x01][cmd u16 LE][payload]`, so skip the 3-byte header
    /// and try to treat the rest as a JSON object. Return `nil` if it can't be decoded —— **do not** search
    /// the whole payload for substrings like `ssid=`: that would treat "the card mentioned an SSID somewhere else" as "the card gave credentials",
    /// then join the hotspot with a made-up password, and finally report an error unrelated to the real cause.
    ///
    /// ⚠️ This path has **no measured sample yet** (see `TicNoteWifiProbe`).
    /// It is "lenient": use it if the shape matches, treat it as not received if not —— it causes no wrong behavior,
    /// it only leaves Wi-Fi fast transfer in the unavailable state.
    static func parseBLEFrame(_ frame: Data) -> TicNoteWifiCredentials? {
        guard frame.count > 3, frame.first == TicNotePacketType.commandResponse.rawValue else {
            return nil
        }
        let payload = frame.dropFirst(3)
        guard !payload.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any]
        else { return nil }
        return parse(object)
    }

    // MARK: ★★★ Derived from the SN (confirmed on a real device with the official App, 2026-10-09, see protocol-notes.md §18.1)

    /// Fixed prefix of the fast-transfer hotspot name. The official App also assembles it this way (`TicNote-3N9H`).
    static let hotspotSSIDPrefix = "TicNote-"

    /// SSID = `"TicNote-"` + **last 4 characters of the SN**.
    ///
    /// - Parameter sn: the ASCII SN decoded from the advertised manufacturer data (`TicNoteAdvertisementParser`),
    ///                 real-device sample `S02510YCY36W3N9H`.
    /// - Returns: `nil` = the SN is shorter than 4 characters. **No guessing**: rather than assembling a wrong name and having the system report
    ///            "network not found", keep fast transfer unavailable and state the reason clearly.
    static func hotspotSSID(fromSN sn: String) -> String? {
        guard sn.count >= 4 else { return nil }
        return hotspotSSIDPrefix + String(sn.suffix(4))
    }

    /// WPA2 password = **last 8 characters of the SN**.
    ///
    /// Note this is the **plaintext passphrase** (not a derived PSK) —— `ConnectWifiUtils`'s
    /// `setWpa2Passphrase` takes plaintext, and so does `NEHotspotConfiguration(passphrase:)`.
    static func hotspotPSK(fromSN sn: String) -> String? {
        guard sn.count >= 8 else { return nil }
        return String(sn.suffix(8))
    }

    /// Builds the credentials directly from the SN. **This is the default for fast transfer**, since both values are uniquely determined by the SN.
    ///
    /// Address fields are left empty: after the direction correction (the phone is the server) they are only log hints,
    /// and not having them affects no step of the operation.
    static func from(sn: String) -> TicNoteWifiCredentials? {
        guard let ssid = hotspotSSID(fromSN: sn),
              let psk = hotspotPSK(fromSN: sn)
        else { return nil }
        return TicNoteWifiCredentials(
            ssid: ssid,
            passphrase: psk,
            serverHint: nil,
            serverPort: nil,
            clientHint: nil,
            clientPort: nil
        )
    }
}

// MARK: - Sent at binding time: token and hotspot name (BLE control frame, goes over BLE, not Wi-Fi)

/// A `cmd = 0x0001` frame the official App sends when **binding** the card, carrying both the
/// **WebSocket token** and the **card hotspot name**.
///
/// ## ⚠️ Correction: the "hotspot name" in this frame is **not the fast-transfer hotspot name** (real device, 2026-10-09)
/// At the end of round 9, both "what the card's hotspot is called" and "where the password comes from" could only be guessed, so the
/// `"Back-clip c1 pro"` in this frame was taken as the answer. **Half wrong.** The real device confirmed the fast-transfer hotspot name is
/// `"TicNote-" + last 4 characters of the SN` (see `TicNoteWifiCredentials.hotspotSSID(fromSN:)`);
/// `"Back-clip c1 pro"` is merely a field the official App writes into the card **at the moment of binding**,
/// and the card does not use it when opening its hotspot. This distinction is critical —— using `"Back-clip c1 pro"` with
/// `NEHotspotConfiguration` will never find the network.
///
/// The **real** value of this frame lies elsewhere: it is a **precondition** of `OPEN_WIFI`.
/// Measured in round 15 (`protocol-notes.md` §17.1): sending `01 0a 00` directly without this frame,
/// the card replies with only an identity frame, neither ACKing nor dropping the link; with it, the card immediately replies `01 0a 00 00`,
/// then about 1.8 s later drops BLE to open its hotspot. **That is why it belongs in the main flow.**
///
/// ## Evidence chain (verifiable)
/// 1. **Dart-side frame assembly**: `WriteCmd::sendToken` in `blutter_out/asm/ticnote/util/tools/dartBle/writeBle.dart`
///    (`addr 0x100ee1c, size 0x4e8`).
///    In the function body, items are `add`ed in order into a `GrowableList<int>`, among them:
///    - `r1 = "1234567890000000"` → `getUTF8Bytes()`
///    - `r1 = "Back-clip c1 pro"` (`[pp+0x2e3c8]`) → `getUTF8Bytes()`
///      → take `field_b` (the length) → `and w3, w2, #0xff` → yields a **u8 length byte**
/// 2. **Call site**: `ble.dart :: BluetoothManager::bindDevice` (`0x100edb0` calls
///    `sendToken()`, right after `setDeviceInfo()`). So it belongs to the **binding flow**,
///    not the fast-transfer flow —— the card records the hotspot name as a "binding parameter".
/// 3. **Real-device bytes**: frame 29969 of `captures/att-stream2.txt`
///    (ATT opcode `0x52` = Write Command, handle `0x000d`), which **appears only once** in the whole capture:
///    ```
///    01 01 00 | 02 01 01 | "1234567890000000" | 00×9 | 0d | "Back-clip c1 pro"
///    ```
///    The lengths are self-consistent: `3 + 16 + 9 + 1 + 13 = 42` bytes of payload, 45 bytes for the whole frame.
/// 4. **String pool**: in `blutter_out/pp.txt`, `[pp+0x2e3c8] String: "Back-clip c1 pro"`,
///    with neighbours `sendToken error/success`, `Field <::.platformType>` and `"sendToken "`,
///    showing it is the literal at this spot. Note that in the snapshot it is **UTF-16**, so searching the APK
///    directly as UTF-8 finds nothing (I fell into this trap).
///
/// ## The one byte that is not pinned down
/// `payload[1]`. Besides the two literal `2`s, the `sendToken` assembly also `add`s `platformType` (`static late final int`) and `4`
/// into the same list, and the count does not match the 3-byte prefix captured by hand —— which suggests the earlier
/// `_growToNextCapacity()` calls belong to **another** list.
/// So I froze the whole prefix as the **observed constant** `[0x02, 0x01, 0x01]`,
/// and assert against the real-device bytes in the self-check. If a future capture on iOS shows the second byte is not `0x01`,
/// just change this one spot (`provisionPrefix`).
///
/// ## ⚠️ Deliberately **not wired in**
/// This is a **write-to-card** operation. Until there is a second sample (ideally a card never bound by the official App),
/// the main flow will not send it proactively —— an already-bound card has long had its hotspot name fixed,
/// and we need not change it. The value of this type now is: turning the real-device bytes of this frame into a permanent regression assertion,
/// and providing a byte-by-byte checkable starting point for when "Nomily provisions a new card itself" is needed.
enum TicNoteWifiProvisioning {

    /// ⚠️ **"Value written at binding time", not the fast-transfer hotspot name —— don't use it to connect for fast transfer.**
    ///
    /// When binding the card, the official App writes `"Back-clip c1 pro"` into the card (it is in this frame's payload),
    /// but the hotspot the card actually opens on real hardware is called `"TicNote-" + last 4 characters of the SN`
    /// (see `TicNoteWifiCredentials.hotspotSSID(fromSN:)` and `protocol-notes.md` §18.1).
    /// The original is kept only to **compare against the real-device bytes of the official binding frame** (for regression assertions); its lifecycle ends there.
    static let officialHotspotSSID = "背夹 c1 pro"

    /// Binding token. The same constant as the token used in the WebSocket handshake
    /// (the default value of `TicNoteWifiLink.Config.token` in `RecorderProtocol`).
    static let bindToken = "1234567890000000"

    /// Payload prefix. The origin of `[1]` is undetermined, see the type comment.
    static let provisionPrefix: [UInt8] = [0x02, 0x01, 0x01]

    /// Number of bytes the token field occupies. In the capture the token is exactly 16 bytes, followed by 9 `0x00`s.
    static let tokenFieldBytes = 16
    /// Padding length after the token and before the SSID length byte.
    static let reservedBytes = 9

    /// Builds the `sendToken` frame: `[0x01][0x01 0x00]` + the payload above.
    ///
    /// The SSID length is taken with `& 0xFF`, the same algorithm as on the Dart side; more than 255 bytes is rejected outright
    /// (rather than build a frame with a mismatched length, refuse here —— the card side has no length check).
    ///
    /// - Parameters:
    ///   - token: defaults to `bindToken`. The fast-transfer flow doesn't need to change it.
    ///   - ssid: **for the fast-transfer flow pass `TicNoteWifiCredentials.hotspotSSID(fromSN:)` explicitly**,
    ///           so the name in this frame matches the hotspot to be joined next (in case the card really does trust it, the two sides won't diverge).
    ///           The default `"Back-clip c1 pro"` is the **real-device original value of the official binding frame**, kept only for regression assertions.
    static func sendTokenFrame(token: String = bindToken,
                               ssid: String = officialHotspotSSID) -> Data? {
        let tokenBytes = Array(token.utf8)
        let ssidBytes = Array(ssid.utf8)
        guard tokenBytes.count <= tokenFieldBytes,
              ssidBytes.count > 0,
              ssidBytes.count <= 0xFF
        else { return nil }

        var payload = Data(provisionPrefix)
        payload.append(contentsOf: tokenBytes)
        // Right-pad the 16-byte token field with zeros, then add `reservedBytes` more zeros.
        payload.append(contentsOf: [UInt8](repeating: 0, count: tokenFieldBytes - tokenBytes.count))
        payload.append(contentsOf: [UInt8](repeating: 0, count: reservedBytes))
        payload.append(UInt8(ssidBytes.count & 0xFF))
        payload.append(contentsOf: ssidBytes)

        var out = Data(capacity: 3 + payload.count)
        out.append(TicNotePacketType.commandResponse.rawValue)   // 0x01
        out.append(UInt8(TicNoteWifiCmder.handshake & 0xFF))     // cmd u16 LE = 0x0001
        out.append(UInt8((TicNoteWifiCmder.handshake >> 8) & 0xFF))
        out.append(payload)
        return out
    }
}
