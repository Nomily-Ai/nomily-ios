import Foundation

// MARK: - soundcore Work / D3200（飞书录音豆）raw frames → Ogg-Opus container
//
// Faithful Swift port of Kotlin `SoundcoreOgg.kt` (which ports upstream
// `tacshi/Soundcore lib/audio/ogg_opus.dart`).
//
// The D3200 stream (offline pull and realtime alike) is a **bare concatenation
// of fixed 160-byte Opus frames** — 20 ms each @ 48 kHz mono. Parameters
// mirror the verified Android implementation byte-for-byte:
//
//  - preskip 3840, serial `'ARKR'` (0x41524B52), 50 frames per page,
//  - granule starts at 0 and accumulates 960 per frame,
//  - ★ 2026-10-28（8.3.6 反编译复核）：CBR 定长 160 B 是**精确包长**，包尾 0x00
//    是合法编码内容——不做尾部零裁剪（裁了 = 短包，libopus INVALID_PACKET）。
//    不足一帧的传输残留直接丢弃（官方 FileWriterHelper 只 append 整帧）。

enum SoundcoreOgg {
    static let frameSize = 160
    static let sampleRate = 48_000
    static let samplesPerFrame = 960 // 20 ms @ 48 kHz
    static let preskip = 3840
    static let serial: UInt32 = 0x41524B52 // 'ARKR'
    private static let framesPerPage = 50

    static func isOgg(_ bytes: Data) -> Bool {
        bytes.count >= 4 && bytes.prefix(4) == Data("OggS".utf8)
    }

    /// Mux fixed-size (or trailing partial) frames into Ogg-Opus bytes.
    /// If the payload is already a valid Ogg container, return it unchanged.
    static func muxRawFrames(_ raw: Data) throws -> Data {
        guard !raw.isEmpty else {
            throw SoundcoreError.device("无音频数据")
        }
        if isOgg(raw) { return raw }

        let bytes = [UInt8](raw)
        var frames: [Data] = []
        frames.reserveCapacity(bytes.count / frameSize)
        var o = 0
        while o + frameSize <= bytes.count {
            frames.append(Data(bytes[o..<(o + frameSize)])) // CBR 160B，原样不 trim
            o += frameSize
        }
        // 不足一帧的尾巴是传输残留，丢弃（官方同样只落整帧）。

        var out = Data()
        var seq: UInt32 = 0
        out.append(makePage([opusHead()], serial: serial, sequence: seq, granule: 0, bos: true))
        seq += 1
        out.append(makePage([opusTags()], serial: serial, sequence: seq, granule: 0))
        seq += 1

        var granule: UInt64 = 0
        var i = 0
        while i < frames.count {
            let end = min(i + framesPerPage, frames.count)
            granule += UInt64(samplesPerFrame) * UInt64(end - i)
            out.append(makePage(Array(frames[i..<end]), serial: serial, sequence: seq, granule: granule, eos: end >= frames.count))
            seq += 1
            i = end
        }
        return out
    }

    /// Duration in ms derived from the frame count (20 ms each).
    static func rawDurationMs(_ rawSize: Int) -> Int {
        rawSize / frameSize * 20
    }

    /// granule (48 kHz sample count, D3200 layout starts at 0) → milliseconds.
    static func granuleToMs(_ granule: UInt64) -> Int {
        guard granule > preskip else { return 0 }
        return Int((granule - UInt64(preskip)) / UInt64(sampleRate / 1000))
    }

    private static func le16(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    private static func le32(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    private static func opusHead() -> Data {
        var b = Data("OpusHead".utf8)
        b.append(1) // version
        b.append(1) // channels (mono)
        b.append(le16(preskip))
        b.append(le32(sampleRate))
        b.append(Data([0, 0])) // output gain
        b.append(0) // channel mapping family
        return b
    }

    private static func opusTags() -> Data {
        let vendor = Data("AnkerRecorder".utf8)
        var b = Data("OpusTags".utf8)
        b.append(le32(vendor.count))
        b.append(vendor)
        b.append(Data([0, 0, 0, 0])) // user comment count
        return b
    }

    /// Assemble one Ogg page (27-byte header + segment table + body, CRC poly 0x04C11DB7).
    private static func makePage(_ packets: [Data], serial: UInt32, sequence: UInt32, granule: UInt64, bos: Bool = false, eos: Bool = false) -> Data {
        var segs: [UInt8] = []
        segs.reserveCapacity(packets.count + 4)
        var body = Data()
        for pkt in packets {
            body.append(pkt)
            var n = pkt.count
            while n >= 255 {
                segs.append(255)
                n -= 255
            }
            segs.append(UInt8(n))
        }
        var headerType: UInt8 = 0
        if bos { headerType |= 0x02 }
        if eos { headerType |= 0x04 }

        var page = Data()
        page.append(Data("OggS".utf8))
        page.append(0) // version
        page.append(headerType)
        for k in 0..<8 { page.append(UInt8((granule >> (8 * k)) & 0xFF)) }
        for k in 0..<4 { page.append(UInt8((serial >> (8 * k)) & 0xFF)) }
        for k in 0..<4 { page.append(UInt8((sequence >> (8 * k)) & 0xFF)) }
        // CRC placeholder at 22..25 stays zero
        page.append(UInt8(segs.count))
        page.append(contentsOf: segs)
        page.append(body)
        let crc = oggCrc(page)
        page.replaceSubrange(22..<26, with: le32(Int(crc & 0xFFFFFFFF)))
        return page
    }

    // Standard Ogg CRC: reflected? No — MSB-first, poly 0x04C11DB7, init 0.
    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var r = UInt32(i) << 24
            for _ in 0..<8 {
                r = (r & 0x80000000) != 0 ? (r << 1) ^ 0x04C11DB7 : (r << 1)
            }
            return r
        }
    }()

    private static func oggCrc(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            let idx = Int((crc >> 24) ^ UInt32(byte)) & 0xFF
            crc = (crc << 8) ^ crcTable[idx]
        }
        return crc
    }
}
