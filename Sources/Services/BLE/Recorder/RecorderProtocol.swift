import CoreBluetooth
import Foundation

// MARK: - Protocol-agnostic recorder card abstraction
//
// Current situation: `DnoteClient` / `BluetoothCoordinator` / `DeviceModels` directly hard‑code D·NOTE's
// constant, command codes, and JSON field names welded into the business logic. To support a second card (TicNote NE-79) you must
// extract these "protocol facts", let each card implement its own specification, and have the upper layer depend only on semantics.
//
// This file only **adds**: it does not modify any existing files, thus has zero impact on current behavior.
// Wiring details are in `docs/RecorderProtocolMigration.md`.

// MARK: Broadcast recognition result

/// Protocol-agnostic description after a card is identified. Each protocol fills this structure after parsing its own broadcast format.
struct RecorderAdvertisement: Equatable {
    /// Example: "dnote" / "ticnote"
    let protocolID: String
    /// Example: "D·NOTE" / "TicNote"
    let family: String
    /// Example: "V05E (2+1 MIC Card)" / "NE-79"
    let modelName: String
    /// Human‑readable firmware version; nil when the protocol does not provide it
    let firmware: String?
    let hardware: String?
    let battery: Int?
    let powerState: Int?
    /// Stable device identifier used for reconnection across reinstallations.
    /// D·NOTE uses a 3‑byte DEVICE_SID; TicNote uses a serial number.
    let identity: Data
    /// Original protocol fields are retained as‑is (firmware may add fields, the model layer does not decide which are readable)
    let raw: [String: AnyHashable]

    var displayName: String {
        // `modelName` may be empty (the DingTalk A1 has no model string — its "model" is the
        // serial tail, which the subtitle lines already show). Guard the join so we never
        // render a trailing space like "DingTalk A1 ".
        modelName.isEmpty ? family : "\(family) \(modelName)"
    }

    static func == (lhs: RecorderAdvertisement, rhs: RecorderAdvertisement) -> Bool {
        lhs.protocolID == rhs.protocolID && lhs.identity == rhs.identity
    }
}

// MARK: Frame encoding/decoding

/// A decoded inbound frame. Field semantics are interpreted by each protocol.
///
/// The shape must accommodate two very different frame headers, so we are deliberately conservative here:
///
/// | Protocol | Header | `type` | `cmd` | `length` |
/// |---|---|---|---|---|
/// | D·NOTE | `[PID][CMD][LEN]` | always 0 (no such concept) | single byte | yes |
/// | TicNote | `[type][cmd u16 LE]` | yes (0x01/0x02/0x03) | little-endian uint16 | no |
///
/// `cmd` is taken as `UInt16` instead of `UInt8` because TicNote's command codes on the wire are
/// little-endian 16-bit (`_readShort()` yields the reversed byte order, see protocol-notes.md §4).
/// D·NOTE's single-byte command code is placed in the high byte with a constant 0, preserving semantics.
struct RecorderFrame {
    /// Message type. TicNote: 0x01 command response / 0x02 voice data / 0x03 real-time audio stream.
    /// D·NOTE lacks this layer, fill 0.
    let type: UInt8
    /// Command code. D·NOTE uses a single byte, TicNote uses little-endian uint16.
    let cmd: UInt16
    /// Length byte in the header. TicNote's header has no length field, set to nil.
    let length: UInt8?
    let payload: Data

    init(type: UInt8 = 0, cmd: UInt16, length: UInt8? = nil, payload: Data) {
        self.type = type
        self.cmd = cmd
        self.length = length
        self.payload = payload
    }

    /// Device indicates ACK with payload[0] == 0x01 (D·NOTE convention; other protocols may override)
    var isAck: Bool { payload.first == 0x01 }
}

/// Differences in protocol frame formats converge here.
protocol RecorderFrameCodec {
    func encode(cmd: UInt8, payload: Data) -> Data?
    func decode(_ data: Data) -> RecorderFrame?
    func encodeJSON(cmd: UInt8, _ object: [String: Any]) -> Data?
}

// MARK: Command set

/// Command code table given by semantics.
///
/// All optional, because "protocol does not support a capability" and "not yet reverse-engineered" should be handled the same way by the caller:
/// The upper layer grays out the corresponding feature. `nil` must never be used as 0.
struct RecorderCommandSet {
    let startRecording: UInt8?
    let stopRecording: UInt8?
    let recordingStatus: UInt8?
    let recordingStartedEvent: UInt8?
    let recordingStoppedEvent: UInt8?
    let liveStream: UInt8?
    let fileTransfer: UInt8?
    let deviceInfo: UInt8?
    let switchInfo: UInt8?
    let fileList: UInt8?
    let fileDelete: UInt8?
    let syncTime: UInt8?
    /// Protocol extension commands, keyed by semantic name (e.g., "massStorage" / "wifiAP" / "bind")
    let extended: [String: UInt8]

    /// Use this when none can be filled, indicating "command set not yet reverse-engineered".
    static let unknown = RecorderCommandSet(
        startRecording: nil, stopRecording: nil, recordingStatus: nil,
        recordingStartedEvent: nil, recordingStoppedEvent: nil, liveStream: nil,
        fileTransfer: nil, deviceInfo: nil, switchInfo: nil,
        fileList: nil, fileDelete: nil, syncTime: nil, extended: [:]
    )
}

// MARK: Wi‑Fi fast transfer

/// The **shape** of Wi‑Fi fast transfer. It answers "what this protocol looks like", not "what the port number is".
///
/// The difference between the two cases is not a detail; it's **code that almost cannot be shared on either side**:
///
/// | | `.textCommands`（D·NOTE / V05E） | `.webSocketBinaryFrames`（TicNote） |
/// |---|---|---|
/// | Transport layer | Raw TCP, **we are client** | WebSocket, **we are server** |
/// | Frame boundary | `0xAA` magic + length field | WebSocket message boundary (built-in) |
/// | Command | ASCII literal `"get {file}"` | integer `cmder` + JSON |
/// | Data | Fixed-size chunks, request by offset | Whole segment push, ending with `{"status"}` |
/// | Implementation | Existing `WifiClient.downloadFile` | New `TicNoteWifiLink` |
///
/// Therefore this enum's purpose is to **separate before dispatch**, rather than stuffing a bunch of `if`s in the implementation.
enum RecorderWifiTransport: String, Equatable {
    case textCommands
    case webSocketBinaryFrames
}

/// Large files do not use BLE; they use device hotspot + TCP. Parameters vary by protocol.
struct RecorderWifiCommands {
    /// Example: "list"
    let list: String
    /// Example: "get {file}"
    let get: String
    /// Example: "pull {file} {offset}"
    let pull: String?
    /// Example: "delete {file}"
    let delete: String?
    /// Example: "quit"
    let quit: String?
}

struct RecorderWifiProfile {
    let host: String
    let port: Int
    /// Response frame header magic number, nil indicates the protocol has no fixed magic number
    let frameMagic: UInt8?
    let commands: RecorderWifiCommands
    /// Whether the device hotspot name and password are delivered by the BLE side (D·NOTE does; TicNote pending confirmation)
    let credentialsFromBLE: Bool
    /// `true` = host/port/command literal have been verified on real devices;
    /// `false` = **default values pending verification** aligned with the same logic (`0xAA` + text command).
    /// Unverified profiles can let the UI run early, but must be logged and not treated as facts.
    let isVerified: Bool
    /// ★ Added in round eight: What is the **shape** of this Wi‑Fi fast transfer?
    ///
    /// The reason for adding this field is practical: the four `host / port / frameMagic / commands`
    /// are all designed for V05E's raw TCP + text commands, **cannot fit TicNote**
    /// (WebSocket + integer cmder + JSON payload, see `TicNoteWifiProtocol.swift`).
    /// Forcibly stuffing results in `commands` having to be filled with many empty strings, which appear to the caller as "command is an empty string"
    /// rather than "this protocol does not use command literals at all".
    /// With `transport`, the caller knows which implementation to use before accessing `commands`.
    let transport: RecorderWifiTransport

    init(host: String, port: Int, frameMagic: UInt8?,
         commands: RecorderWifiCommands, credentialsFromBLE: Bool,
         isVerified: Bool = true,
         transport: RecorderWifiTransport = .textCommands) {
        self.host = host
        self.port = port
        self.frameMagic = frameMagic
        self.commands = commands
        self.credentialsFromBLE = credentialsFromBLE
        self.isVerified = isVerified
        self.transport = transport
    }

    /// A set of text command literals, V05E measured values.
    /// `{file}` / `{offset}` are placeholders replaced by the caller (see `WifiClient.downloadFile`).
    static let dnoteStyleCommands = RecorderWifiCommands(
        list: "list",
        get: "get {file}",
        pull: "pull {file} {offset}",
        delete: "delete {file}",
        quit: "quit"
    )

    /// ⚠️ TicNote **does not use text commands**. On it, "Wi‑Fi fast transfer" is
    /// **WebSocket + binary frames**, with commands as integer cmder (see the table in `ticnote` documentation comments).
    ///
    /// Here we deliberately fill empty strings, rather than copying V05E's "list" / "get {file}":
    /// Those literals are **not valid at all** on TicNote; inserting them would cause the caller
    /// to send bytes over WebSocket that the peer cannot understand.
    static let noneTextCommands = RecorderWifiCommands(
        list: "", get: "", pull: nil, delete: nil, quit: nil
    )

    /// D·NOTE (V05E / V05 series) current firmware measured values
    static let dnote = RecorderWifiProfile(
        host: "192.168.88.1",
        port: 6718,
        frameMagic: 0xAA,
        commands: dnoteStyleCommands,
        credentialsFromBLE: true,
        isVerified: true
    )

    /// TicNote NE-79 — **WebSocket on 8081, completely different protocol from V05E**.
    ///
    /// ## ★ 2026-10-08 Round seven: Decompiled official APK, disproving the "align with V05E" assumption
    ///
    /// Old values (`192.168.88.1` / `6718` / `0xAA` / text commands) were **copied from V05E as a guess**, not measured.
    /// New evidence:
    ///   · `com/mobvoi/wifi_plugin/socket/WifiProtocol.java`：
    ///     `public static final int WEB_SOCKET_PORT = 8081;`
    ///     Moreover, the whole stack is `org.java_websocket.server.WebSocketServer` — **not raw TCP**.
    ///   · Full-text search: `8081` appears in **Java**, Dart snapshot hits 0;
    ///     while `6718` / `192.168.88.1` / `0xAA` hit 0 in both **Dart and Java** ——
    ///     proving they have never been TicNote values.
    ///
    /// ## Frame format (`com.mobvoi.wifi_plugin.socket.WifiDataVo`)
    /// ```
    /// Both directions are isomorphic:
    ///   [0..2]  totalLen  u24 LE   (includes its own 3 bytes)
    ///   [3]     version   = 1
    ///   [4..5]  cmder     u16 LE
    ///   [6..7]  jsonLen   u16 LE
    ///   [8..]   json      (jsonLen bytes)
    ///   [...]   bin       (remaining = totalLen − 8 − jsonLen)
    /// ```
    /// **No magic number, no CRC** — therefore `frameMagic` is set to `nil`.
    ///
    /// ## cmder table (`WifiProtocol.WifiRequest` / `WifiResponse`)
    /// ```
    ///   0 UNIVERSAL_ERR        1 HANDSHAKE           2 SAY_HELLO
    ///   3 HEARTBEAT(_PONG/_PING)  4 WIFI_CLOSE       5 TIPS
    ///  11 GET_FILE_LIST       12 FILE_SYNC / FILE_SYNC_STATUS
    ///  13 FILE_SYNC_CONTENT   14 FILE_DELETE        15 FILE_SYNC_STOP
    /// 100 SPEED_TEST         101 GET_LOG
    /// ```
    /// ⚠️ `12` is called `FILE_SYNC` on the request side and `FILE_SYNC_STATUS` on the response side, **the same number**,
    /// do not treat them as two commands.
    ///
    /// ## All connection parameters are delivered by the BLE side
    /// The card pushes them via BLE events (Dart `nveasy_ble_plugin` + `device_manage/wifi_logic.dart`):
    /// ```
    /// WifiStatusEvent {
    ///   wifiOpened, wifiStatus,
    ///   wifiSsid, wifiSsidPassword,      ← hotspot name + password
    ///   wifiServerIp, wifiServerPort,    ← card-side server (the one we connect to)
    ///   wifiClientIp, wifiClientPort,
    ///   wifiMac
    /// }
    /// ```
    /// `wifi_logic.dart` parses by extracting `"ssid"` / `"passwd"` from the map.
    /// Hence `credentialsFromBLE = true` is correct, but **host must never be hard‑coded**.
    ///
    /// ## Known entry barriers for "Wi-Fi Fast Transfer" in the official App (obtained via decompilation)
    ///   · It is a **standalone feature page**: `myDevice_WiFifasttransmission` → `WiFiFastConnection`
    ///     → `WiFiFastTransmission`. **Not auto-triggered**; you must manually pick a file and then tap Transfer;
    ///   · Has switches and capability flags: `open_wifi_fast_transfer` / `switchWifi` / `useWifi` /
    ///     `autoConnectWifi` / `supportWifi`；
    ///   · Low battery gets blocked (`watch_wifi_low_battery`), plus there is `wifiOperationTimeout`;
    ///   · One gate check compares device type against `"watch"`; otherwise it logs
    ///     `[WifiLogic] current device type: X, not a watch device, skipping WiFi event handling` and returns directly.
    ///     The device type enum is `watch` / `card`, and **TicNote is `card`** — so that path is skipped;
    ///     The card's WiFi fast transfer goes through `mobvoi_wifi_plugin` (`wifi_logic` and `recording_logic`
    ///     both reference it).
    ///
    ///   ⛔ Correction (real-device round fifteen): **no need to enter the "independent feature page"**. The top bar on the home page
    ///   “N audio files pending sync + enable WIFI fast transfer” bar, tap it to get the fast‑transfer confirmation dialog,
    ///   which goes through `mobvoi_wifi_plugin`. Reproduction steps are in `protocol-notes.md` §18.5.
    ///
    /// ## ✅ Round eight: The previously unfit parts have now been accommodated
    /// `transport` field makes explicit "what this protocol looks like",
    /// so empty strings in `commands` are no longer an ambiguous signal. The actual implementation can be found in:
    ///   · `TicNoteWifiProtocol.swift` — byte‑level implementation of frames and JSON (written line‑by‑line from `WifiDataVo.java`)
    ///   · `TicNoteWifiSession.swift` — state machine (pure logic, offline replayable)
    ///   · `TicNoteWifiLink.swift` — `NWListener` server + hotspot join + cleanup
    ///   · `Sources/Services/Net/WebSocketFraming.swift` — minimal server implementation of RFC 6455
    ///
    /// ## ⛔ `isVerified` remains `false`, but **the reason has been changed** (round fifteen)
    ///
    /// ~~What blocked it was "not even capturing the shape of the Wi-Fi credentials over BLE"~~ ← **Voided.**
    /// The official app ran a full fast-transfer pass on a real device (`protocol-notes.md` §18); conclusion:
    ///   · **Credentials don't need to be captured** —— `SSID = "TicNote-" + last 4 digits of SN`, `password = last 8 digits of SN`,
    ///     computable entirely locally (`TicNoteWifiCredentials.from(sn:)`);
    ///   · **The bind frame must be sent first** before `01 0a 00`; otherwise the card only replies with the identity frame and never opens the hotspot (§17.1);
    ///   · Joining the hotspot must use the peer-to-peer approach (iOS `NEHotspotConfiguration.joinOnce`),
    ///     don't use "saved networks"——it would be suppressed by a Wi-Fi with internet access.
    ///
    /// So `isVerified: false` currently means **"Nomily hasn't run it on the device yet on its side"**:
    /// The protocol, credentials, and timing are all defined, and the code is wired up (`TicNoteLink.fastTransfer` →
    /// `TicNoteWifiLink`). Running it once on the device will set it to `true`.
    ///
    /// ## ⚠️ Direction correction (round 8)
    /// This originally said "`wifiServerIp` / `wifiServerPort` = card-side server (the one we connect to)".
    /// **Reversed.** The phone is the server (`WifiPlugin.openSocket` → `WebSocketServer`),
    /// the card is the client that connects in. So `port: 8081` means **the port we listen on ourselves**,
    /// not "the port to connect to". See the top of `TicNoteWifiProtocol.swift` for details.
    static let ticnote = RecorderWifiProfile(
        host: "",                  // ← Do not hardcode. After the direction correction, the phone is the server; this field is only for logging.
        port: 8081,                // ← WifiProtocol.WEB_SOCKET_PORT (hardcoded default value)
        frameMagic: nil,           // ← No magic numbers: the frame header is a u24 length prefix.
        commands: noneTextCommands,
        credentialsFromBLE: true,
        isVerified: false,
        transport: .webSocketBinaryFrames
    )
}

// MARK: Protocol Specifications

/// All protocol facts about what a card "is", how it's recognized, and how it communicates.
/// Note: these are **protocol constants**, not runtime state, so they are all static.
protocol RecorderProtocolSpec {
    /// Stable identifier, written into configuration and logs; do not change
    static var identifier: String { get }
    static var family: String { get }

    /// The GATT service claimed by this protocol. Used for `retrieveConnectedPeripherals` and scan hints.
    static var serviceUUIDs: [CBUUID] { get }
    /// Write characteristic (App → Device)
    static var rxCharacteristic: CBUUID { get }
    /// /// Notification characteristic (Device → App)
    static var txCharacteristic: CBUUID { get }

    /// Broadcast identification. Devices not using this protocol must return nil — this is how scanning filters work.
    static func parseAdvertisement(manufacturerData: Data?, localName: String?, serviceUUIDs: [CBUUID]?) -> RecorderAdvertisement?

    static var frameCodec: RecorderFrameCodec { get }
    static var commands: RecorderCommandSet { get }
    static var wifiTransfer: RecorderWifiProfile? { get }

    /// The encryption gate that downloaded audio must pass before being written to disk.
    /// Default `nil` = this protocol performs no device-side encryption. See `RecorderClipCrypto.swift`.
    static var clipCipher: RecorderClipCipher.Type? { get }

    /// Binding identifier length; nil indicates that the protocol has no binding process
    static var bondIDLength: Int? { get }
    /// /// Device-side file encryption key length; nil indicates no device-side encryption.
    static var fileEncryptionKeyLength: Int? { get }

    /// The degree to which this card is visible to users. **Default `.hidden`** —— new protocols must explicitly declare visibility to be seen,
    /// This is fail-closed: rather than letting half-finished products slip through, require them to be explicitly written.
    static var exposure: RecorderExposure { get }

    /// Has it been verified on a real device? (This is separate from `exposure`, see `RecorderExposure`).
    static var isVerified: Bool { get }

    /// **Bluetooth read path** (discovery / list / download) whether it has been run on a real device.
    ///
    /// Why separated from `isVerified`: TicNote's read path was verified on iPhone hardware on 2026-10-09
    /// and ran successfully (17 items listed, pagination fixed), but Wi-Fi Fast Transfer still hasn't been tested on hardware — mixing both semantics
    /// in a single flag would cause the detail page banner to lie (either marking verified items as unverified,
    /// or marking unverified Fast Transfer items as verified).
    /// Defaults to match `isVerified`: protocols without separate evidence should not claim read path verification on their own.
    static var isReadingVerified: Bool { get }
}

extension RecorderProtocolSpec {
    /// Defaults to `isVerified` — only an explicit override can set it to true independently.
    static var isReadingVerified: Bool { isVerified }
}

extension RecorderProtocolSpec {
    static var exposure: RecorderExposure { .hidden }
}

extension RecorderProtocolSpec {
    static var clipCipher: RecorderClipCipher.Type? { nil }
}

/// Whether the recordings on this card **can be decrypted by this device**.
///
/// Three cases must be distinguished (do not mix the last two):
///   · `.some(cipher)` and `cipher.keyLength != nil` → a clear decryption path (V05E is this case);
///   · `.some(cipher)` and `cipher.keyLength == nil` → encryption confirmed but **cannot be decrypted** (TicNote is this case),
///     The upper layer should disable the download entry, avoiding giving users a bunch of files that cannot be opened;
///   · `nil` → the device does not encrypt, processing directly as plaintext.
///
/// Note: It must be defined at the **top level**. Swift does not allow nested type declarations inside protocol extensions,
/// placing it inside an extension will produce a "type cannot be nested in protocol extension" compile error.
enum ClipDecryptability: Equatable {
    /// Device side not encrypted
    case notEncrypted
    /// /// Has known envelope and key length, can decrypt
    case decryptable(envelope: String, keyLength: Int)
    /// Encryption confirmed, but envelope/key unknown, **cannot decrypt**
    case blocked(envelope: String)
}

extension RecorderProtocolSpec {
    static var clipDecryptability: ClipDecryptability {
        // ⚠️ Round 6 real issue removed: originally only looked at `keyLength`,
        // Thus `encryptsClips == false` (TicNote, clear Opus) but because `keyLength == nil``
        // misreported as `.blocked` → the upper layer will disable the download entry.
        // **Must first check `encryptsClips`**, "no key needed" does not equal "cannot be decrypted".
        guard let cipher = clipCipher, cipher.encryptsClips else { return .notEncrypted }
        if let len = cipher.keyLength {
            return .decryptable(envelope: cipher.envelopeName, keyLength: len)
        }
        return .blocked(envelope: cipher.envelopeName)
    }
}

// MARK: - Exposure Tiers

/// **Whether this card can appear in the scan list of regular users.**
///
/// Why not just use a single boolean `isVerified`: `isVerified` answers the
/// question of "whether there is real-device evidence", while "whether to show it to users" is a separate issue —
/// TicNote's **read path** has already been verified end-to-end at the byte level on real-device packet captures (see self-check §18),
/// but three remaining real-device steps (broadcast comparison / on-device playback / Wi-Fi fast transfer) are incomplete.
/// Expressing "both are false" with a boolean conflates "completely blocked" with "missing the last mile",
/// so it cannot be allowed through, nor can it be allowed through with differentiated handling.
///
/// The criteria for the three tiers are **falsifiable**:
/// * `.general` —— Verified on real devices over a long period; issues would directly impact active users;
/// * `.beta`    —— Has **end-to-end evidence that can be reproduced in CI** (for TicNote, this is the §18
///   353 request / 7044 data frames / 563,520 bytes of byte-by-byte playback), but lacks real-device usage records;
/// * `.hidden`  —— No such evidence exists, or it hasn't been resolved at all.
enum RecorderExposure: Equatable {
    case general
    case beta
    case hidden

    /// Whether this tier **should or should not** be tagged "experimental" in the UI.
    ///
    /// ⚠️ **2026-10-12: the UI no longer consumes this branch** (the user asked to remove the
    ///    "Beta" orange badge from the scan list). Reason for keeping it: it is the definition of "what this tier means",
    ///   and the `.hidden` / `.beta` / `.general` tiering still takes effect in `userVisible()`.
    ///   If in the future another new protocol family that has truly "never run on real hardware" appears, this criterion can be reused directly —
    ///   but **whether to display it** is the UI's concern; don't tie the two into one again.
    var needsBetaBadge: Bool { self == .beta }
}

// MARK: - Registry

/// Registry of known protocols. During scanning, `parseAdvertisement` is called one by one; the first to return non-nil wins.
///
/// Steps to add a new card:
/// 1. Create an `enum XxxProtocol: RecorderProtocolSpec`
/// 2. Register it in `all`
/// 3. After verifying with packet capture, change `isVerified` to `true`
enum RecorderProtocolRegistry {
    /// Order determines priority. Verified ones come first.
    ///
    /// ⚠️ Order has a real impact: `didDiscover` takes the **first** protocol whose `parseAdvertisement` returns non-nil.
    /// D·NOTE is identified by vendor CID `0x22A3`, TicNote by CID `0x0259`; the two are mutually exclusive, so order
    /// doesn't currently affect the result — but once "a single card resembles two protocols" ever occurs (e.g. a re-badged shell from the same vendor),
    /// order becomes the sole arbiter; at that point the reason must be written out explicitly, not left to "whoever comes first".
    static let all: [any RecorderProtocolSpec.Type] = [
        DnoteRecorderSpec.self,
        TicNoteRecorderSpec.self,
        DingTalkA1Spec.self,
    ]

    /// Protocol visible to users: `exposure != .hidden`.
    ///
    /// ⚠️ here**is no longer** `filter { $0.isVerified }`.after separating the two:
    ///  · `.beta` protocol will appear in the list(**2026-10-12 starting no longer additionally tag as "experimental"** ——
    ///    User requests to remove the "Beta" in the scan list, see `RecorderExposure.needsBetaBadge`);
    ///  · `isVerified` still only answers "whether there is real-device evidence".
    /// Thus "whether to show the user" and "whether the evidence is sufficient" can be advanced separately —— this round's
    /// The key to connecting TicNote's read path into the App without falsely claiming "verified".
    static func userVisible() -> [any RecorderProtocolSpec.Type] {
        all.filter { $0.exposure != .hidden }
    }

    /// For developer tools only: also return those with `.hidden`.
    static func includingHidden() -> [any RecorderProtocolSpec.Type] { all }

    /// Retrieves the protocol by `identifier`, used to restore from persisted configuration.
    static func spec(for identifier: String) -> (any RecorderProtocolSpec.Type)? {
        all.first { $0.identifier == identifier }
    }
}
