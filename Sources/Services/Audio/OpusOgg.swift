import Foundation

/// Wraps the device's raw OPUS frame stream into a standard Ogg-Opus
/// container — no libopus, no libogg, no decoding. Each device frame is
/// 40 bytes (TOC `0x4b`,
/// SILK WB 16 kHz mono, 20 ms = 960 samples after 48 kHz declaration);
/// we just emit OpusHead + OpusTags + 50-frame audio pages with the
/// OGG CRC-32. The output plays in any media player that knows
/// Ogg-Opus and is what Azure's Fast Transcription expects when the
/// upload is `audio/ogg`.
enum OpusOgg {
    static let frameSize = 40            // bytes per device frame
    static let samplesPerFrame = 960     // 20 ms at 48 kHz
    static let sampleRate: UInt32 = 48000
    static let channels: UInt8 = 1
    static let preSkip: UInt16 = 312
    static let framesPerPage = 50        // ≈1 s per page
    static let defaultSerial: UInt32 = 0x444E_4F54   // 'DNOT'

    /// Wrap `raw` (concatenated 40-byte OPUS frames) into Ogg-Opus bytes.
    /// Returns an empty `Data` when `raw.count < frameSize` so callers can
    /// short-circuit without special-casing the empty file.
    static func wrap(rawFrames raw: Data, serial: UInt32 = defaultSerial) -> Data {
        let numFrames = raw.count / frameSize
        guard numFrames > 0 else { return Data() }

        var out = Data()
        var pageSeq: UInt32 = 0

        // OpusHead page (BOS).
        var head = Data()
        head.append(contentsOf: Array("OpusHead".utf8))
        head.append(1)                                          // version
        head.append(channels)
        head.appendLE(preSkip)
        head.appendLE(sampleRate)
        head.appendLE(Int16(0))                                 // output gain
        head.append(0)                                          // channel mapping family
        out.append(makePage(serial: serial, pageSeq: pageSeq, granule: 0, segments: [head], bos: true))
        pageSeq &+= 1

        // OpusTags page.
        let vendor = Data("dnote".utf8)
        var tags = Data()
        tags.append(contentsOf: Array("OpusTags".utf8))
        tags.appendLE(UInt32(vendor.count))
        tags.append(vendor)
        tags.appendLE(UInt32(0))                                // 0 user comments
        out.append(makePage(serial: serial, pageSeq: pageSeq, granule: 0, segments: [tags]))
        pageSeq &+= 1

        // Audio pages: pack `framesPerPage` frames per page (≈1 s each).
        var granule: Int64 = Int64(preSkip)
        var frameIdx = 0
        while frameIdx < numFrames {
            let upper = min(frameIdx + framesPerPage, numFrames)
            var batch: [Data] = []
            batch.reserveCapacity(upper - frameIdx)
            for j in frameIdx..<upper {
                let start = j * frameSize
                batch.append(raw.subdata(in: start..<(start + frameSize)))
                granule &+= Int64(samplesPerFrame)
            }
            let isLast = upper >= numFrames
            out.append(makePage(serial: serial, pageSeq: pageSeq, granule: granule, segments: batch, eos: isLast))
            pageSeq &+= 1
            frameIdx = upper
        }
        return out
    }

    /// Estimate the duration (seconds) of an Ogg-Opus file by scanning
    /// pages and reading the last page's granule position (in 48 kHz
    /// samples). Returns `nil` for non-Ogg or malformed files so callers
    /// can fall back to "skip the duration check" rather than blocking
    /// transcription on a parse error.
    static func duration(ofOggOpusAt url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var lastGranule: Int64 = -1
        var offset = 0
        // Page header is 27 bytes + segment table; segment bodies follow.
        while offset + 27 <= data.count {
            // Verify capture pattern "OggS".
            guard data[offset] == 0x4F, data[offset + 1] == 0x67,
                  data[offset + 2] == 0x67, data[offset + 3] == 0x53 else {
                return lastGranule >= 0 ? Double(lastGranule) / Double(sampleRate) : nil
            }
            let granule = data.readLE(Int64.self, at: offset + 6)
            let segCount = Int(data[offset + 26])
            let segTableStart = offset + 27
            guard segTableStart + segCount <= data.count else { return nil }
            var bodyLen = 0
            for i in 0..<segCount {
                bodyLen += Int(data[segTableStart + i])
            }
            let next = segTableStart + segCount + bodyLen
            if next > data.count { return nil }
            lastGranule = granule
            offset = next
        }
        guard lastGranule > 0 else { return nil }
        // Subtract preSkip per the Opus spec — that's the encoder's
        // padding, not real audio.
        let samples = max(0, lastGranule - Int64(preSkip))
        return Double(samples) / Double(sampleRate)
    }

    // MARK: - streaming helpers

    /// Build OGG header pages (OpusHead + OpusTags) for streaming use.
    /// Returns the two pages concatenated; callers should send audio
    /// pages starting at `pageSeq = 2`.
    static func oggHeaders(serial: UInt32 = defaultSerial) -> Data {
        var out = Data()
        var head = Data()
        head.append(contentsOf: Array("OpusHead".utf8))
        head.append(1)
        head.append(channels)
        head.appendLE(preSkip)
        head.appendLE(sampleRate)
        head.appendLE(Int16(0))
        head.append(0)
        out.append(makePage(serial: serial, pageSeq: 0, granule: 0, segments: [head], bos: true))

        let vendor = Data("dnote".utf8)
        var tags = Data()
        tags.append(contentsOf: Array("OpusTags".utf8))
        tags.appendLE(UInt32(vendor.count))
        tags.append(vendor)
        tags.appendLE(UInt32(0))
        out.append(makePage(serial: serial, pageSeq: 1, granule: 0, segments: [tags]))
        return out
    }

    /// Build a single OGG audio page from OPUS frames for streaming.
    static func audioPage(
        serial: UInt32,
        pageSeq: UInt32,
        granule: Int64,
        frames: [Data],
        eos: Bool = false
    ) -> Data {
        makePage(serial: serial, pageSeq: pageSeq, granule: granule, segments: frames, eos: eos)
    }

    // MARK: - private

    /// Build a single OGG page containing `segments`. Each segment must be
    /// ≤ 255 bytes; our 40-byte OPUS frames are well within that, so we
    /// don't bother with the 255-continuation rule that "real" muxers need.
    private static func makePage(
        serial: UInt32,
        pageSeq: UInt32,
        granule: Int64,
        segments: [Data],
        bos: Bool = false,
        eos: Bool = false
    ) -> Data {
        var flag: UInt8 = 0
        if bos { flag |= 0x02 }
        if eos { flag |= 0x04 }

        var page = Data()
        page.append(contentsOf: Array("OggS".utf8))             // capture pattern
        page.append(0)                                          // stream version
        page.append(flag)
        page.appendLE(granule)                                  // granule (q, 8 bytes)
        page.appendLE(serial)
        page.appendLE(pageSeq)
        page.appendLE(UInt32(0))                                // CRC placeholder
        page.append(UInt8(segments.count))                      // number of segments
        for s in segments { page.append(UInt8(s.count)) }       // segment lengths
        for s in segments { page.append(s) }                    // segment bodies

        let crc = oggCRC(page)
        // Patch the CRC into bytes 22…25 (4-byte little-endian).
        page.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
        return page
    }

    /// OGG CRC-32: polynomial `0x04C11DB7`, no bit reversal, init=0,
    /// final XOR=0.
    private static func oggCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for b in data {
            crc ^= UInt32(b) &<< 24
            for _ in 0..<8 {
                if crc & 0x8000_0000 != 0 {
                    crc = (crc &<< 1) ^ 0x04C1_1DB7
                } else {
                    crc = crc &<< 1
                }
            }
        }
        return crc
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian
        }
    }
}
