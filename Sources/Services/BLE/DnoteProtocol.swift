import CoreBluetooth
import Foundation

/// BLE protocol constants for D·NOTE (Card / Clip) recorders.
enum DnoteProtocol {
    static let serviceUUID = CBUUID(string: "00006001-0000-1000-8000-00805F9B34FB")
    /// 16-bit Bluetooth SIG alias of `serviceUUID`. The device sometimes
    /// advertises only the short form, which CoreBluetooth surfaces as a
    /// distinct CBUUID — we accept both.
    static let serviceUUIDShort = CBUUID(string: "6001")
    static let rxCharUUID  = CBUUID(string: "00006002-0000-1000-8000-00805F9B34FB")
    static let txCharUUID  = CBUUID(string: "00006003-0000-1000-8000-00805F9B34FB")

    /// CID value (0x22A3). The BLE SIG mandates Company ID be transmitted
    /// little-endian, so the wire bytes at the start of the manufacturer-data
    /// payload are `A3 22`.
    static let advCIDByte0: UInt8 = 0xA3  // low byte (first on wire)
    static let advCIDByte1: UInt8 = 0x22  // high byte

    /// Packet identifier byte at the head of every frame.
    static let pid: UInt8 = 0xA0

    enum Cmd {
        static let stopRec:        UInt8 = 0x50
        static let startRec:       UInt8 = 0x51
        static let recStatus:      UInt8 = 0x56
        static let recStarted:     UInt8 = 0x54
        static let recStopped:     UInt8 = 0x55
        static let stream:         UInt8 = 0x68
        static let xfer:           UInt8 = 0x70
        static let deviceInfo:     UInt8 = 0x80
        static let switchInfo:     UInt8 = 0x81
        static let massStorage:    UInt8 = 0x82
        static let led:            UInt8 = 0x83
        // Do not swap these two: the readback keys off the names, so a swap
        // drives the wrong peripheral while the readback still looks correct.
        static let motor:          UInt8 = 0x84
        static let noiseCancel:    UInt8 = 0x85
        static let btNameShort:    UInt8 = 0x86
        static let syncTime:       UInt8 = 0x87
        static let wifiAP:         UInt8 = 0x88
        static let saveWAV:        UInt8 = 0x8A
        static let vad:            UInt8 = 0x8B
        static let micGain:        UInt8 = 0x8C
        static let nrLevel:        UInt8 = 0x8D
        static let btNameLong:     UInt8 = 0x8E
        static let idleOff:        UInt8 = 0x8F
        static let fileList:       UInt8 = 0x90
        static let fileDelete:     UInt8 = 0x91
        static let factoryReset:   UInt8 = 0x93
        static let formatDisk:     UInt8 = 0x94
        static let shutdown:       UInt8 = 0x95
        // v1.47: binding — device refuses recording until an app has bound.
        static let bind:           UInt8 = 0xA0
        static let queryBond:      UInt8 = 0xA1
        // v1.47: ChaCha20 encryption of the on-device audio files. Turning it
        // off requires the key currently stored on the device.
        static let encryptSet:     UInt8 = 0xA2
        static let encryptQuery:   UInt8 = 0xA3
    }

    /// Longest Bluetooth name the firmware accepts, in UTF-8 bytes. Anything
    /// longer is left unacknowledged, so clients clamp before sending.
    static let btNameMaxBytes = 24

    /// Drops trailing characters until `text` fits `btNameMaxBytes`, never
    /// splitting a multi-byte character.
    static func clampBluetoothName(_ text: String) -> String {
        var out = text
        while out.utf8.count > btNameMaxBytes { out.removeLast() }
        return out
    }

    /// Length of the app-chosen binding identifier. The firmware stores it
    /// verbatim; any 16 random bytes will do.
    static let bondIDLength = 16

    /// ChaCha20 key length accepted by the firmware for `encryptSet`.
    static let chachaKeyLength = 32

    /// Status nibbles (upper nibble of the START byte) for file transfers.
    enum Xfer {
        static let start:      UInt8 = 0x00
        static let inProgress: UInt8 = 0x10
        static let eof:        UInt8 = 0x20
        static let cancel:     UInt8 = 0x30
        static let error:      UInt8 = 0x40
        static let notFound:   UInt8 = 0xF0
    }

    /// Status nibbles for the live OPUS stream.
    enum Stream {
        static let start:      UInt8 = 0x00
        static let inProgress: UInt8 = 0x10
        static let stop:       UInt8 = 0x20
        static let error:      UInt8 = 0x40
    }

    /// Sentinel passed to `set_idle_off` to disable auto-power-off.
    static let idleOffNever: UInt32 = 0x0036_EE80
}

/// Product family + variant identified by (BID, PID) in the manufacturer
/// advertisement. Peripherals whose (BID, PID) isn't in this catalog are
/// filtered out of scan results — there is no fallback by local-name string.
struct DnoteProduct: Equatable, Hashable {
    let bid: UInt16
    let pid: UInt16
    let family: String
    let modelName: String

    var displayName: String { "\(family) \(modelName)" }

    static let catalog: [DnoteProduct] = [
        // BID 0x6868 — D·NOTE
        .init(bid: 0x6868, pid: 0x0000, family: "D·NOTE", modelName: "Standard"),
        .init(bid: 0x6868, pid: 0x0001, family: "D·NOTE", modelName: "Flagship"),
        .init(bid: 0x6868, pid: 0x0002, family: "D·NOTE", modelName: "Luxury"),
        .init(bid: 0x6869, pid: 0x0000, family: "D·NOTE", modelName: "R101 (Ring)"),
        .init(bid: 0x6869, pid: 0x0001, family: "D·NOTE", modelName: "P101 (Pendant)"),
        .init(bid: 0x6869, pid: 0x0002, family: "D·NOTE", modelName: "V05 (2+1 MIC Card)"),
        .init(bid: 0x6869, pid: 0x0003, family: "D·NOTE", modelName: "V03 (4+1 MIC Card)"),
    ]

    static func match(bid: UInt16, pid: UInt16) -> DnoteProduct? {
        catalog.first { $0.bid == bid && $0.pid == pid }
    }
}

/// Decoded view of a D·NOTE manufacturer-specific advertisement. The
/// CoreBluetooth manufacturer-data blob drops the AD length and type bytes.
struct DnoteAdvertisement {
    let bid: UInt16
    let pid: UInt16
    let firmware: UInt16
    let hardware: UInt16
    let battery: UInt8
    let powerState: UInt8
    /// 3-byte static device identity.
    let deviceSID: Data

    /// Parse the manufacturer-data blob from `CBAdvertisementDataManufacturerDataKey`.
    /// Returns nil unless the blob is at least 15 bytes and starts with the
    /// D·NOTE CID (`22 A3`).
    static func parse(_ data: Data) -> DnoteAdvertisement? {
        guard data.count >= 15 else { return nil }
        let base = data.startIndex
        guard data[base] == DnoteProtocol.advCIDByte0,
              data[base + 1] == DnoteProtocol.advCIDByte1 else { return nil }
        let bid = (UInt16(data[base + 2]) << 8) | UInt16(data[base + 3])
        let pid = (UInt16(data[base + 4]) << 8) | UInt16(data[base + 5])
        let firmware = (UInt16(data[base + 6]) << 8) | UInt16(data[base + 7])
        let hardware = (UInt16(data[base + 8]) << 8) | UInt16(data[base + 9])
        let batt = data[base + 10]
        let power = data[base + 11]
        let sid = data.subdata(in: (base + 12)..<(base + 15))
        return DnoteAdvertisement(
            bid: bid, pid: pid,
            firmware: firmware, hardware: hardware,
            battery: batt, powerState: power,
            deviceSID: sid
        )
    }
}

extension Data {
    /// Lowercase hex dump (no separators). Persisted in `config.json` for
    /// bond_id round-trip.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Parse a hex string back into raw bytes. Whitespace is tolerated;
    /// any other non-hex character (or odd length) returns nil.
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let byte = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        self = bytes
    }
}
