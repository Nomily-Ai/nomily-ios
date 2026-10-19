import Foundation

// MARK: - DTYJ container → standard Ogg Opus
//
// The A1 does not store `.opus` or `.ogg`. It writes a RIFF-shaped private container:
//
// ```
//  0   "BABA"            4   u32 LE   bytes from offset 8 to EOF
//  8   "DTYJ"
// 12   "ver "            16  "v1.7" / "v1.6"      ← no length field, unlike a real chunk
// 20   "fmt "            24  u32 LE   written as 0 ← body is fixed 24 bytes
// 32   u32 LE  bitrate   36  u32 LE  sample rate
// 41   u8  frame ms      42  u8  channels   43  u8  bits
// 44   u16 LE record size
// 46   u8  record prefix length
// 48   u32 LE duration ms
// 52   "extr"            56  u8  ?          58  u8  encryption flag (1 = payload is AES)
// 60   8 × 0x00
// 68   "data"            72  u32 LE  payload bytes
// 76   u32 LE CRC32                          ← inserted where a chunk's length would end
// 80   payload: fixed-size records, each = prefix + one Opus packet
// ```
//
// Three variants were seen across 33 real files:
//
// | version | rate            | prefix | packet | record |
// |---|---|---|---|---|
// | v1.7 | 32 kbps / 16 kHz | 4 | 80  | 84  |
// | v1.7 | 64 kbps / 48 kHz | 4 | 160 | 164 |
// | v1.6 | 32 kbps / 16 kHz | 0 | 80  | 80  |
//
// and always `recordSize == bitrate × frameMs / 8000 + prefixLength`.
//
// Every packet is one 20 ms Opus frame (`0x4B` TOC) whatever the container's bitrate says,
// so the granule count advances by exactly 960 samples per packet regardless of the
// container's sample-rate field. That mismatch is not a bug to "fix": the field describes
// what the encoder was fed, while Opus always counts time at 48 kHz.
//
// The conversion is a straight port of the verified Python tool
// (the A1 reverse-engineering `tools/dtyj_to_ogg.py`, byte-identical output on real samples), because
// getting Ogg's CRC or lacing wrong produces a file that opens in a player and then stops
// at the first page boundary — the kind of failure that looks like "the card recorded noise".

enum DingTalkA1Audio {

    enum ConversionError: LocalizedError {
        case notContainer
        case truncated
        case invalidLayout(String)
        case encrypted
        case emptyRecording

        var errorDescription: String? {
            switch self {
            case .notContainer:
                return "This file isn't a DingTalk recording container."
            case .truncated:
                return "The recording was cut short — the container's own length doesn't match its bytes."
            case .invalidLayout(let why):
                return "Unrecognised recording layout: \(why)"
            case .encrypted:
                return "This recording is encrypted on the card. Nomily can't decode it."
            case .emptyRecording:
                return "The recording contains no audio."
            }
        }
    }

    struct Result {
        let ogg: Data
        let duration: TimeInterval
        let formatNote: String
    }

    private static let headerBytes = 80
    private static let samplesPerPacket: UInt64 = 960   // 20 ms at 48 kHz

    // MARK: Convert

    static func convert(_ data: Data, serial: UInt32) throws -> Result {
        let container = try parseContainer(data)
        if container.packets.isEmpty { throw ConversionError.emptyRecording }

        // Ciphertext check **before** writing anything: a file that plays as noise is worse
        // than an honest error (the fail-closed rule this codebase uses everywhere).
        if container.looksEncrypted { throw ConversionError.encrypted }

        var pages = Data()
        pages.append(page(packet: opusHead(sampleRate: container.inputRate, channels: container.channels),
                          headerType: 0x02, granule: 0, serial: serial, sequence: 0))
        pages.append(page(packet: opusTags(version: container.version),
                          headerType: 0x00, granule: 0, serial: serial, sequence: 1))

        var granule: UInt64 = 0
        for (index, packet) in container.packets.enumerated() {
            granule += samplesPerPacket
            let isLast = index == container.packets.count - 1
            pages.append(page(packet: packet,
                              headerType: isLast ? 0x04 : 0x00,
                              granule: granule,
                              serial: serial,
                              sequence: UInt32(index + 2)))
        }

        let duration = TimeInterval(container.packets.count) / 50.0   // 20 ms each
        let kbps = container.bitrate / 1000
        var note = "Opus \(container.channels == 1 ? "mono" : "stereo")"
            + (kbps > 0 ? " · \(kbps) kbps" : "")
            + " · \(container.inputRate / 1000) kHz source"
        if container.isPartial { note += " · partial download" }
        return Result(ogg: pages, duration: duration, formatNote: note)
    }

    // MARK: Container

    struct Container {
        let packets: [Data]
        /// OpusHead's "input sample rate" — the container's own claim about the capture rate.
        let inputRate: Int
        let channels: Int
        let bitrate: Int
        let version: String
        let looksEncrypted: Bool
        /// The header counts to the card's real EOF but we hold **fewer** bytes than that —
        /// a download interrupted mid-transfer (link drop, cancelled sync). The audio we do
        /// have is still a valid prefix, so it is converted instead of rejected.
        let isPartial: Bool
    }

    static func parseContainer(_ data: Data) throws -> Container {
        var bytes = [UInt8](data)
        guard bytes.count > headerBytes else { throw ConversionError.notContainer }
        guard bytes[0] == 0x42, bytes[1] == 0x41, bytes[2] == 0x42, bytes[3] == 0x41,  // "BABA"
              bytes[8] == 0x44, bytes[9] == 0x54, bytes[10] == 0x59, bytes[11] == 0x4A  // "DTYJ"
        else { throw ConversionError.notContainer }

        // ★ Length mismatch is **not** fatal (2026-10-19). The old guard threw
        //   `truncated` whenever `declaredTotal != bytes.count - 8`, which turned an
        //   interrupted download into "the recording was cut short" with zero audio —
        //   even though every byte we did receive decodes perfectly. Both directions
        //   are now handled by trimming/clamping, and only flagged, never fatal.
        var isPartial = false
        let availableAfterHeader = bytes.count - 8
        let declaredTotal = Int(le32(bytes, 4))
        if declaredTotal == 0 {
            // Header not finalised yet (card still writing when we read it) — trust the bytes.
        } else if declaredTotal < availableAfterHeader {
            // Bytes beyond the container's declared EOF: trailing junk, drop it.
            bytes.removeLast(availableAfterHeader - declaredTotal)
        } else if declaredTotal > availableAfterHeader {
            // We hold a prefix of the real file (interrupted download). Convert what we have.
            isPartial = true
        }

        let version = String(decoding: bytes[16..<20], as: UTF8.self)
        let fmtOffset = find(bytes, [0x66, 0x6D, 0x74, 0x20], from: 12)     // "fmt "
        guard let fmtOffset else { throw ConversionError.invalidLayout("no fmt chunk") }
        let dataOffset = find(bytes, [0x64, 0x61, 0x74, 0x61], from: fmtOffset + 4)  // "data"
        guard let dataOffset, dataOffset + 12 <= bytes.count else {
            throw ConversionError.invalidLayout("no data chunk")
        }

        // The verified Python converter reads this field as the OpusHead "input sample rate",
        // so we read the same word. Its label in the header table (bitrate vs sample rate) is
        // the one thing about this header we never confirmed, and it does not matter: Opus
        // decoders ignore OpusHead's input rate, and the real rate is pinned by the 48 kHz
        // granule clock below. Byte-identical output beats a cleverer interpretation.
        let inputRate = Int(le32(bytes, fmtOffset + 12))
        let frameMs = Int(bytes.count > 41 ? bytes[41] : 20)
        let channels = Int(bytes.count > 42 ? bytes[42] : 1)
        let recordSize = Int(le16(bytes, fmtOffset + 24))
        let declaredPrefix = Int(bytes.count > 46 ? bytes[46] : 0)
        var payloadSize = Int(le32(bytes, dataOffset + 4))
        let payloadStart = dataOffset + 12
        let headerSaysEncrypted = bytes.count > 58 && bytes[58] == 1

        // A partial download makes the declared payload larger than what we actually hold;
        // clamp to the bytes on hand (the record loop below skips the trailing stub).
        payloadSize = min(payloadSize, max(bytes.count - payloadStart, 0))
        guard recordSize > 0, payloadStart + payloadSize <= bytes.count else {
            throw ConversionError.invalidLayout("record area out of bounds")
        }

        // ⚠️ Prefix length: prefer arithmetic over the header byte.
        // `recordSize % 80` reproduces all three measured variants (84→4, 164→4, 80→0, 160→0),
        // while the header's own prefix byte is the field we have the least evidence for.
        // The header is only consulted when the arithmetic yields something implausible.
        var prefixLength = recordSize % 80
        if prefixLength > 8 { prefixLength = declaredPrefix }
        guard prefixLength >= 0, recordSize > prefixLength else {
            throw ConversionError.invalidLayout("record size \(recordSize) ≤ prefix \(prefixLength)")
        }

        var packets: [Data] = []
        var offset = payloadStart
        let end = payloadStart + payloadSize
        while offset + recordSize <= end {
            let packetStart = offset + prefixLength
            let packet = Data(bytes[packetStart..<(offset + recordSize)])
            if !packet.isEmpty { packets.append(packet) }
            offset += recordSize
        }

        return Container(
            packets: packets,
            inputRate: inputRate > 0 ? inputRate : 48_000,
            channels: (1...2).contains(channels) ? channels : 1,
            // Derived, not read: `recordSize == bitrate × frameMs / 8000 + prefix` is the one
            // relation that held across all 33 samples, so it is the more trustworthy source.
            bitrate: frameMs > 0 ? (recordSize - prefixLength) * 8_000 / frameMs : 0,
            version: version,
            looksEncrypted: headerSaysEncrypted || isCiphertext(packets),
            isPartial: isPartial
        )
    }

    /// Ciphertext detector, from the Python tool's own criterion.
    ///
    /// A real Opus stream keeps the same TOC **config** (top 5 bits of the first byte) for the
    /// whole recording — one encoder setting, one stream. AES ciphertext spreads those 5 bits
    /// uniformly, so concentration collapses to ≈ 1/32. The threshold (20 %) sits far from both
    /// observed values (plaintext ≈ 100 %, ciphertext ≈ 3 %), so it cannot be tripped by a
    /// healthy file that merely changes its frame count bits.
    private static func isCiphertext(_ packets: [Data]) -> Bool {
        let sample = packets.prefix(200).compactMap { $0.first }
        guard sample.count >= 20 else { return false }
        var counts: [UInt8: Int] = [:]
        for toc in sample { counts[toc >> 3, default: 0] += 1 }
        let top = counts.values.max() ?? 0
        return Double(top) / Double(sample.count) < 0.2
    }

    // MARK: Ogg

    private static func opusHead(sampleRate: Int, channels: Int) -> Data {
        var out = Data("OpusHead".utf8)
        out.append(contentsOf: [1, UInt8(channels)])          // version 1, channel count
        out.append(contentsOf: le16Bytes(0))                  // pre-skip
        out.append(contentsOf: le32Bytes(UInt32(sampleRate))) // input sample rate (informational)
        out.append(contentsOf: le16Bytes(0))                  // output gain
        out.append(0)                                         // mapping family 0
        return out
    }

    private static func opusTags(version: String) -> Data {
        let vendor = Data("dtyj_to_ogg/\(version)".utf8)
        var out = Data("OpusTags".utf8)
        out.append(contentsOf: le32Bytes(UInt32(vendor.count)))
        out.append(vendor)
        out.append(contentsOf: le32Bytes(0))
        return out
    }

    private static func page(packet: Data, headerType: UInt8, granule: UInt64,
                             serial: UInt32, sequence: UInt32) -> Data {
        var lacing: [UInt8] = []
        var remaining = packet.count
        while remaining >= 255 {
            lacing.append(255)
            remaining -= 255
        }
        lacing.append(UInt8(remaining))

        var out = Data("OggS".utf8)
        out.append(0)                                  // version
        out.append(headerType)
        out.append(contentsOf: le64Bytes(granule))
        out.append(contentsOf: le32Bytes(serial))
        out.append(contentsOf: le32Bytes(sequence))
        out.append(contentsOf: le32Bytes(0))           // CRC placeholder
        out.append(UInt8(lacing.count))
        out.append(contentsOf: lacing)
        out.append(packet)

        var bytes = [UInt8](out)
        let crc = oggCRC(bytes)
        bytes[22] = UInt8(crc & 0xFF)
        bytes[23] = UInt8((crc >> 8) & 0xFF)
        bytes[24] = UInt8((crc >> 16) & 0xFF)
        bytes[25] = UInt8((crc >> 24) & 0xFF)
        return Data(bytes)
    }

    /// Ogg's CRC-32: polynomial `0x04C11DB7`, **not** reflected, initial value 0, no final XOR.
    /// (This is not zlib's CRC — using that gives pages every player rejects.)
    static func oggCRC(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 0
        for byte in bytes {
            value ^= UInt32(byte) << 24
            for _ in 0..<8 {
                value = (value & 0x8000_0000) != 0
                    ? (value << 1) ^ 0x04C1_1DB7
                    : value << 1
            }
        }
        return value
    }

    // MARK: Byte helpers

    private static func find(_ bytes: [UInt8], _ needle: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
        var index = max(0, start)
        while index + needle.count <= bytes.count {
            if bytes[index] == needle[0],
               Array(bytes[index..<(index + needle.count)]) == needle {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func le16Bytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func le32Bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private static func le64Bytes(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) }
    }
}
