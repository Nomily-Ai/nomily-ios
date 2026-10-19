import Foundation

/// Wraps the device's raw OPUS frame stream into a standard Ogg-Opus
/// container — no libopus, no libogg, no decoding.
///
/// ## ★★★ 2026-10-12: changed from hard‑coding 40 bytes to **parameterizing by `Profile`**
///
/// Originally this type hard‑coded D·NOTE's frame length (40 B, TOC `0x4b`, SILK WB 16 kHz mono,
/// 20 ms = 960 samples) as a set of `static let` constants, so **only D·NOTE could use it**.
/// Now we need to handle TicNote's real‑time audio (160 B/packet, CELT 48 kHz **stereo**, also 20 ms),
/// If we keep hard‑coding 40, `send()` will split a 160 B packet into **four fake 40 B frames**,
/// The page table (lacing) becomes completely wrong — the remote side receives noise instead of an error.
/// This "looks like it works" bad approach is harder to detect than an outright failure, so this time we switch to explicitly passing a Profile.
///
/// The two profiles share **common traits** (which is why a single wrapper can be used):
/// Packet duration is **20 ms**, and the granule unit is **48 kHz** ——
/// The only differences are "bytes per packet" and "channel count".
///
/// Legacy call sites (the D·NOTE download path in `PostDownload`) still pass only `rawFrames:`,
/// defaulting to `dnoteProfile`, with no behavioral change.
enum OpusOgg {

    /// How a device segments Opus packets — all information required by the wrapper.
    ///
    /// Intentionally create a small struct instead of adding more `static let` constants:
    /// With multiple devices, **any missed update would silently produce corrupted files**,
    /// Passing a struct lets the compiler flag every call site.
    struct Profile: Equatable {
        /// The byte size of an Opus packet (**must align to packet boundaries**, not arbitrary slice lengths)
        var packetBytes: Int
        var channels: UInt8
        /// The container-declared sample rate (the denominator of the granule)
        var sampleRate: UInt32
        /// Number of samples per packet in the 48 kHz granule domain (20 ms → 960)
        var samplesPerPacket: Int
        /// `OpusHead` pre‑skip (48 kHz samples)
        var preSkip: UInt16

        /// Duration of a packet in seconds. Both profiles currently use 20 ms, but don't hard‑code this as a constant ——
        /// It is derived from `samplesPerPacket / 48000`; if the packet size changes, this must be updated accordingly.
        var packetSeconds: Double { Double(samplesPerPacket) / 48000.0 }

        // MARK: two known devices
        //
        // ⚠️ These two constants are deliberately defined inside `Profile` **(not on `OpusOgg`)**:
        // The default argument `.dnote` can only resolve to a "static member of the parameter type",
        // If placed at the outer level, you would have to write the full `OpusOgg.dnoteProfile` each time, which is easy to omit.

        /// D·NOTE (V05E): 40 B per packet, mono, declared at 48 kHz, 20 ms.
        ///
        /// ⚠️ The "SILK WB 16 kHz" in the name refers to the **encoder's internal** sample rate; the container still declares
        /// 48 kHz (granule must be counted at 48 kHz), as required by the Ogg Opus specification.
        static let dnote = Profile(
            packetBytes: 40, channels: 1, sampleRate: 48000,
            samplesPerPacket: 960, preSkip: 312)

        /// TicNote: 160 B per packet, **stereo**, 48 kHz, 20 ms (64 kbps).
        ///
        /// Based on real‑device three‑party verification (see the comment on `TicNoteGATT.opusPacketBytes`):
        /// The official `Opus2Ogg` uses 10 packets of 160 B per page, a constant TOC `0xBC` (`stereo` bit set to 1),
        /// `afinfo` reports `2 ch, 48000 Hz, packet size upper bound: 160`.
        ///
        /// ⚠️ Note that its `samplesPerPacket` matches `dnote` **exactly** (both 960 / 20 ms) ——
        /// This is why both can share the same paging logic and granule step.
        static let ticNote = Profile(
            packetBytes: 160, channels: 2, sampleRate: 48000,
            samplesPerPacket: 960, preSkip: 312)

        /// DingTalk A1: 84 B per packet, mono, 48 kHz, 20 ms.
        ///
        /// Both the live stream (`0x0117`, audio length field = 84) and the `.dtyj` v1.7/32 kbps
        /// container carry the same 84‑byte packet, TOC `0x4B`/`0x48` (config 9, SILK WB, 20 ms —
        /// see the A1 reverse-engineering notes §7.4). The 64 kbps *download* variant is 164 B, but that
        /// path goes through `DingTalkA1Audio.convert` (whole‑file DTYJ→Ogg), never through here.
        static let dingTalkA1 = Profile(
            packetBytes: 84, channels: 1, sampleRate: 48000,
            samplesPerPacket: 960, preSkip: 312)
    }

    /// Alias (for readability: `OpusOgg.dnoteProfile` reads more naturally than `OpusOgg.Profile.dnote`).
    static let dnoteProfile = Profile.dnote
    static let ticNoteProfile = Profile.ticNote

    // MARK: compatibility with legacy call sites (these pertain to D·NOTE semantics)
    //
    // They are kept to avoid rewriting all `PostDownload` / `LiveModel` call sites that **only serve D·NOTE**
    // in one sweep — but **new code should use `Profile`**.
    // Those locations in `LiveModel` have already been changed to `source.opusProfile.packetBytes` (see `LiveModel`).

    static var frameSize: Int { Profile.dnote.packetBytes }
    static var samplesPerFrame: Int { Profile.dnote.samplesPerPacket }
    static var sampleRate: UInt32 { Profile.dnote.sampleRate }
    static var channels: UInt8 { Profile.dnote.channels }
    static var preSkip: UInt16 { Profile.dnote.preSkip }
    static let framesPerPage = 50        // ≈1 s per page (used by D·NOTE's download path)
    static let defaultSerial: UInt32 = 0x444E_4F54   // 'DNOT'

    /// Wrap `raw` (concatenated OPUS packets of `profile`) into Ogg-Opus bytes.
    /// Returns an empty `Data` when `raw.count < profile.packetBytes` so callers
    /// can short-circuit without special-casing the empty file.
    static func wrap(
        rawFrames raw: Data,
        serial: UInt32 = defaultSerial,
        profile: Profile = .dnote
    ) -> Data {
        let frameSize = profile.packetBytes
        let numFrames = raw.count / frameSize
        guard numFrames > 0 else { return Data() }

        var out = Data()
        var pageSeq: UInt32 = 0

        // OpusHead page (BOS).
        var head = Data()
        head.append(contentsOf: Array("OpusHead".utf8))
        head.append(1)                                          // version
        head.append(profile.channels)
        head.appendLE(profile.preSkip)
        head.appendLE(profile.sampleRate)
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
        var granule: Int64 = Int64(profile.preSkip)
        var frameIdx = 0
        while frameIdx < numFrames {
            let upper = min(frameIdx + framesPerPage, numFrames)
            var batch: [Data] = []
            batch.reserveCapacity(upper - frameIdx)
            for j in frameIdx..<upper {
                let start = j * frameSize
                batch.append(raw.subdata(in: start..<(start + frameSize)))
                granule &+= Int64(profile.samplesPerPacket)
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
    static func duration(
        ofOggOpusAt url: URL,
        profile: Profile = .dnote
    ) -> Double? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var lastGranule: Int64 = -1
        var offset = 0
        // Page header is 27 bytes + segment table; segment bodies follow.
        while offset + 27 <= data.count {
            // Verify capture pattern "OggS".
            guard data[offset] == 0x4F, data[offset + 1] == 0x67,
                  data[offset + 2] == 0x67, data[offset + 3] == 0x53 else {
                return lastGranule >= 0
                    ? Double(lastGranule) / Double(profile.sampleRate) : nil
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
        let samples = max(0, lastGranule - Int64(profile.preSkip))
        return Double(samples) / Double(profile.sampleRate)
    }

    // MARK: - streaming helpers

    /// Build OGG header pages (OpusHead + OpusTags) for streaming use.
    /// Returns the two pages concatenated; callers should send audio
    /// pages starting at `pageSeq = 2`.
    ///
    /// ⚠️ `profile` determines the **channel count and sample rate** in `OpusHead` — the remote decoder
    /// interprets subsequent audio pages based on these fields. Supplying the wrong profile won't raise an error; it will produce noise or down‑mix to mono,
    /// so the real‑time path must match the source of the incoming packets (see `LiveAudioSource.opusProfile`).
    static func oggHeaders(
        serial: UInt32 = defaultSerial,
        profile: Profile = .dnote
    ) -> Data {
        var out = Data()
        var head = Data()
        head.append(contentsOf: Array("OpusHead".utf8))
        head.append(1)
        head.append(profile.channels)
        head.appendLE(profile.preSkip)
        head.appendLE(profile.sampleRate)
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
