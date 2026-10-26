import Foundation
import PlaudBleSDK
import PlaudDeviceBasicSDK
import Security

/// Near-real-time E2EE decoder for the Plaud live stream.
///
/// ★ 2026-10-23 (third pass on "实时转录没有字"): log forensics showed the card
/// **does** stream the in-progress recording over BLE (~26 KB/s, encrypted) but
/// the SDK's own live decoder never emits a single `blePcmData` block — the
/// handshake completes ("key ready, starting PCM decode") and then nothing,
/// silently, on every take ever logged. This module stops waiting for the SDK
/// and decodes the stream itself:
///
///   bleData(start, data)  →  append to a growing temp file image
///                         →  every few seconds: SDK's own
///                            `decryptE2EEAudioFile` (byte-exact with the
///                            post-stop path, so no format guesswork)
///                         →  decode the **new** 80-byte Opus frames with the
///                            SDK's `JXOpusDecoder`
///                         →  PCM → `onPCM` → the live ASR engine.
///
/// The result is chunked live captions (a few seconds of latency, driven by
/// the pump interval), not the 20 ms cadence the broken SDK path promised —
/// but real text on screen beats a perfect pipeline that never fires.
///
/// ## Why the header has to be captured
/// The encrypted image is `[0..624) E2EE header (metadata + RSA-wrapped key
/// cipher — the SDK calls it "key ready" after exactly 3 × 208 bytes) |
/// padding to 1024 | [1024…) audio`. `bleData` only receives bytes the SDK
/// does not consume itself, and the SDK's E2EE parser swallows all 624 header
/// bytes during a handshake, so the caller reads `(0, 640)` through the
/// low-level sender (raw, no decode) and this class reassembles the image by
/// the `start` offset each block carries. The gap at 640…1024 is never
/// received (the card never serves it) and does not matter: ChaCha20 is
/// position-addressed and every Opus frame stands alone.
final class PlaudLiveDecryptor {

    // MARK: State

    /// The recording this decoder is attached to. `0` = idle.
    private(set) var sessionId = 0
    /// Serialises every touch of the buffer/file; the SDK's delegate and the
    /// pump timer run on unknown/other queues.
    private let queue = DispatchQueue(label: "nomily.plaud.livedecrypt", qos: .userInitiated)

    private var fileHandle: FileHandle?
    private var filePath: String = ""
    private var decryptedPath: String = ""
    /// Next file offset a block must carry to be appended in order.
    private var expectedOffset: Int64 = 0
    /// Bytes appended since the last pump (skips pumps with no news).
    private var unflushedBytes = 0
    /// Opus frames already decoded and handed to the sink.
    private var decodedFrames = 0
    /// Cumulative decoded seconds — the `elapsed` the ASR clock runs on.
    private var decodedSeconds: TimeInterval = 0
    /// Set once the pipeline has produced PCM. The host then ignores the SDK's
    /// (broken, and if it ever wakes up, duplicate) `blePcmData`.
    private(set) var hasProducedPCM = false
    /// How far the reassembled image reaches (updated on `queue`, read from the
    /// main actor as a progress signal — the pull loop uses it as its cursor).
    private(set) var receivedEnd: Int64 = 0
    /// Frames per decode call had this many samples; set on the first frame so
    /// a 48 kHz decoder output can be detected and decimated to 16 kHz.
    private var samplesPerFrame = 0

    private var pumpTimer: DispatchSourceTimer?
    private let frameBytes = 80          // mono Opus frame size, per JXOpusDecoder docs
    private var opusDecoder: JXOpusDecoder?

    /// PCM sink — `PlaudDirectService.liveAudioSink`. Called on `queue`.
    var onPCM: ((Data, TimeInterval) -> Void)?
    /// Diagnostics sink — `TicNoteDiagLog.log`. Called on `queue`.
    var onEvent: ((String) -> Void)?

    // MARK: Lifecycle

    /// Starts (or restarts) decoding for one recording. A resume is a new
    /// session id, so the host calls this again — the old image stays behind.
    func start(sessionId: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.sessionId != sessionId else { return }
            self.teardownLocked()
            self.sessionId = sessionId
            self.expectedOffset = 0
            self.receivedEnd = 0
            self.unflushedBytes = 0
            self.decodedFrames = 0
            self.decodedSeconds = 0
            self.hasProducedPCM = false
            self.samplesPerFrame = 0

            let name = "plaud-live-\(sessionId)"
            self.filePath = NSTemporaryDirectory() + name + ".enc"
            self.decryptedPath = NSTemporaryDirectory() + name + "_dec.dat"
            FileManager.default.createFile(atPath: self.filePath, contents: nil)
            self.fileHandle = FileHandle(forWritingAtPath: self.filePath)

            self.opusDecoder = JXOpusDecoder(channels: 1)

            if Self.privateKeyPem == nil {
                Self.privateKeyPem = Self.loadPrivateKeyPem()
            }
            self.event("decryptor start sid=\(sessionId) key=\(Self.privateKeyPem != nil ? "yes" : "MISSING")")

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            // ★ 2026-10-26 (user: "提升转写文字显示速度"): 2.5/3.0 s meant up to
            // ~5 s from "the words were spoken" to "the recogniser heard them".
            // The pump decrypts the whole file each round, so a shorter period
            // costs a little redundant work but cuts first-text latency to
            // ~2–3 s — the card itself only writes every few seconds anyway.
            timer.schedule(deadline: .now() + 1.2, repeating: 2.0)
            timer.setEventHandler { [weak self] in self?.pumpLocked() }
            timer.resume()
            self.pumpTimer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.sessionId != 0 else { return }
            self.pumpLocked(final: true)
            self.teardownLocked()
        }
    }

    private func teardownLocked() {
        pumpTimer?.cancel()
        pumpTimer = nil
        try? fileHandle?.close()
        fileHandle = nil
        if !filePath.isEmpty {
            try? FileManager.default.removeItem(atPath: filePath)
        }
        try? FileManager.default.removeItem(atPath: decryptedPath)
        try? FileManager.default.removeItem(atPath: decryptedPath + ".plain")
        filePath = ""
        decryptedPath = ""
        sessionId = 0
        opusDecoder = nil
    }

    // MARK: Input

    /// One `bleData` block. Blocks carry absolute file offsets, which is what
    /// makes re-delivery (the watchdog re-opens the stream) and the interleaved
    /// header request safe: everything is written at its own offset.
    func append(start: Int, data: Data) {
        queue.async { [weak self] in
            guard let self, self.sessionId != 0, self.fileHandle != nil else { return }
            let offset = Int64(start)
            if offset + Int64(data.count) <= self.expectedOffset {
                return  // fully duplicate (a re-open replaying old ground)
            }
            if offset > self.expectedOffset {
                // A hole means a block the SDK consumed before us; nothing we
                // can do about the missing bytes, but keep going — the decrypt
                // simply has a gap and the ASR loses that instant.
                self.event("decryptor gap: have \(self.expectedOffset), block at \(offset)")
            }
            self.fileHandle?.seek(toFileOffset: UInt64(offset))
            self.fileHandle?.write(data)
            self.expectedOffset = max(self.expectedOffset, offset + Int64(data.count))
            self.receivedEnd = self.expectedOffset
            self.unflushedBytes += data.count
        }
    }

    // MARK: Pump

    /// Decrypts what is new and pushes the fresh Opus frames as PCM.
    ///
    /// `final` runs once more when the take stops, so the last seconds are not
    /// stranded in the buffer (they would still reach the ASR through the
    /// file transcription, but the live panel would end mid-sentence).
    private func pumpLocked(final: Bool = false) {
        guard sessionId != 0, fileHandle != nil else { return }
        // A complete header is 512 B metadata + 256 B keyCipher; below that
        // nothing can be decrypted, so do not bother the pump.
        guard expectedOffset >= 768 else {
            if final { event("decryptor: header never completed (\(expectedOffset)B)") }
            return
        }
        guard unflushedBytes > 0 || final else { return }
        unflushedBytes = 0

        guard let pem = Self.privateKeyPem else {
            event("decryptor: no private key — cannot decode live stream")
            return
        }

        try? fileHandle?.synchronizeFile()
        // ★★ 2026-10-26 (fifth pass, device log 10:17): `decryptE2EEAudioFile`
        // decrypts fine (header parsed, ChaCha20 test passed, 32-byte key
        // unwrapped, 5088 B of audio decrypted) and then throws it all away:
        // its last step is `OGG -> raw AVC: 0/0 frames, 0 bytes` — the live
        // prefix of the file is **not** parseable as the OGG container the
        // finished file uses. So stop asking that call to demux for us and
        // take the plaintext: `decryptAudioToOgg` only decrypts, leaving
        // whatever the card actually wrote (raw Opus packets while a take is
        // open, OGG pages once finished).
        guard let pem = Self.privateKeyPem else {
            event("decryptor: no private key — cannot decode live stream")
            return
        }
        logHeaderOnce()

        let plainPath = decryptedPath + ".plain"
        let produced: String?
        do {
            produced = try AudioFileDecryptor.decryptAudioToOgg(
                inputPath: filePath,
                privateKeyPem: pem,
                outputPath: plainPath
            )
        } catch {
            event("decryptor: decryptAudioToOgg failed \(error)")
            return
        }
        guard let path = produced,
              let blob = FileManager.default.contents(atPath: path), !blob.isEmpty else {
            event("decryptor: plaintext empty (image=\(expectedOffset)B)")
            return
        }
        if samplesPerFrame == 0 && !hasProducedPCM {
            event("decryptor: plaintext \(blob.count)B head=\(Self.hexPrefix(blob))")
        }

        // ★★ 2026-10-26 (sixth pass, device log 10:29): the plaintext **is** an
        // OGG container (`head=4F676753` = "OggS") and grows every pump, but the
        // hand-rolled demux produced no frames. Rather than guess at packet
        // framing, hand the container to the SDK's own OGG→PCM converter — the
        // same chain playback and file transcription use — and read the PCM it
        // writes. The manual demux stays as a fallback for a raw (non-OGG)
        // prefix.
        let isOgg = blob.count > 4 && blob.prefix(4).elementsEqual("OggS".utf8)
        if isOgg, let pcmData = Self.convertOggToPCM(path: path, event: event) {
            let fresh = pcmData.dropFirst(pcmConsumed)
            if !fresh.isEmpty {
                let consumedBefore = pcmConsumed
                pcmConsumed = pcmData.count
                let seconds = Double(pcmData.count / 2) / 16_000
                decodedSeconds = seconds
                if !hasProducedPCM {
                    hasProducedPCM = true
                    event("decryptor: first PCM out (ogg->pcm) — \(pcmData.count)B, \(String(format: "%.1f", seconds))s")
                }
                // ★ 2026-10-26 (device log 11:24/11:25): the converter catches
                // up after a stall by returning the whole backlog at once
                // (42.8 s / 46.1 s in a single call). The cloud engines expect
                // a *stream* — `AliyunRealtimeClient` caps its buffer at 960 KB
                // and drops the OLDEST audio when a burst overflows it, so the
                // recogniser never saw a complete sentence and the take showed
                // no live text at all. Pace it out instead.
                emitPaced(Data(fresh), baseBytes: consumedBefore)
                return
            }
            return   // converter works, nothing new this round
        }

        let frames = Self.opusFrames(from: blob)
        if !isOgg && !loggedFrames {
            loggedFrames = true
            event("decryptor: raw packets=\(frames.count) sizes=\(frames.prefix(5).map(\.count))")
        }
        let totalFrames = frames.count
        guard totalFrames > decodedFrames else { return }

        var pcm = Data()
        pcm.reserveCapacity((totalFrames - decodedFrames) * 640)
        var failedDecodes = 0
        for index in decodedFrames..<totalFrames {
            guard let block = opusDecoder?.decode(frames[index]), !block.isEmpty else {
                failedDecodes += 1
                continue
            }
            pcm.append(Self.to16k(block, samplesPerFrame: &samplesPerFrame, event: event))
        }
        if !isOgg && !hasProducedPCM && failedDecodes == totalFrames - decodedFrames && failedDecodes > 0 {
            event("decryptor: opus decode failed on all \(failedDecodes) frames")
        }
        decodedFrames = totalFrames

        guard !pcm.isEmpty else { return }
        let seconds = Double(decodedFrames) * 0.02   // one 80-byte frame = 20 ms @ 16 kHz
        decodedSeconds = seconds
        if !hasProducedPCM {
            hasProducedPCM = true
            event("decryptor: first PCM out — \(totalFrames) frames, \(pcm.count)B")
        }
        onPCM?(pcm, seconds)
    }

    /// Logs the SDK's own view of the header once per take — the one place
    /// where "did we get a complete header?" has a numeric answer
    /// (`headerSize` + 256-byte keyCipher).
    private var loggedHeader = false
    private var loggedFrames = false
    /// PCM bytes already handed to the ASR (the converter rewrites the whole
    /// file each pump, so only the tail is new).
    private var pcmConsumed = 0

    /// OGG → PCM through the SDK's own converter (`Mp3Convert`), which is the
    /// chain playback and file transcription already trust.
    ///
    /// The converter is asynchronous and has no completion callback — only a
    /// per-chunk progress tick — so this waits for the first tick and then a
    /// beat for the file to close. It runs on the decryptor's serial queue,
    /// i.e. never on main, so blocking here is free.
    /// Drain a backlog into the ASR **paced like a live stream**.
    ///
    /// 100 ms slices (3 200 B of 16 kHz mono) with a 15 ms gap ≈ 6.6× real
    /// time, so a 46 s backlog drains in ~7 s while the socket sees ordinary
    /// audio frames instead of one multi-megabyte burst. `baseBytes` is how
    /// much PCM the file had already produced before this chunk, so each
    /// slice's `seconds` stays the card's true elapsed time.
    private func emitPaced(_ fresh: Data, baseBytes: Int) {
        let slice = 3_200
        var offset = 0
        while offset < fresh.count {
            let end = min(offset + slice, fresh.count)
            let at = Double((baseBytes + offset) / 2) / 16_000
            onPCM?(fresh.subdata(in: offset..<end), at)
            offset = end
            if offset < fresh.count {
                Thread.sleep(forTimeInterval: 0.015)
            }
        }
    }

    private static func convertOggToPCM(path: String, event: (String) -> Void) -> Data? {
        let pcmPath = path + ".pcm"
        try? FileManager.default.removeItem(atPath: pcmPath)
        var ticked = false
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0
        Mp3Convert.shared().convertOgg(
            path,
            toPcm: pcmPath,
            channels: 1,
            ns_agc: false,
            callback: { _ in ticked = true }
        )
        let deadline = Date().addingTimeInterval(5.0)
        // ★ 2026-10-26: poll the PCM file until it stops *growing* instead of a
        // blind 2 s + 0.15 s. The old budget was tuned for the first ~0.7 s
        // round; once the file is bigger the conversion itself needs longer,
        // the old code read an empty file, returned nil, and the next round
        // restarted the whole conversion — which is how a take could run for
        // 45 s with the converter "producing nothing" and then hand over the
        // entire backlog in one lump.
        var lastSize = -1
        var stable = 0
        while Date() < deadline {
            if ticked, stable >= 2 { break }
            Thread.sleep(forTimeInterval: 0.1)
            let pcmSize = ((try? FileManager.default.attributesOfItem(atPath: pcmPath))?[.size] as? Int) ?? 0
            if pcmSize > 0 && pcmSize == lastSize {
                stable += 1
            } else {
                stable = 0
            }
            lastSize = pcmSize
        }
        Thread.sleep(forTimeInterval: 0.15)
        guard let pcm = FileManager.default.contents(atPath: pcmPath), !pcm.isEmpty else {
            // Only worth a log line when the input was substantial enough to
            // have produced audio.
            if size > 8 * 1024 { event("decryptor: ogg->pcm produced nothing (\(size)B in)") }
            return nil
        }
        return pcm
    }

    private func logHeaderOnce() {
        guard !loggedHeader, let header = AudioFileDecryptor.getHeader(path: filePath) else { return }
        loggedHeader = true
        event("decryptor: header ok headerSize=\(header.headerSizeValue) nonce=\(Self.hexPrefix(header.nonce)) segment=\(header.segment) counter=\(header.counter) dur=\(header.duration) keyCipher=\(header.keyCipher.count)B")
    }

    /// Minimal OGG demux, or a raw split, whichever the bytes deserve.
    ///
    /// The finished file is an OGG container ("OGG -> raw AVC: 1746/1844
    /// frames" in the SDK log for a closed take), but a take that is still
    /// being written may be a bare stream of Opus packets — the SDK's own
    /// converter yields `0/0 frames` on it. Handling both here keeps the live
    /// path from depending on which shape the card picked today.
    private static func opusFrames(from blob: Data) -> [Data] {
        let isOgg = blob.count > 4 && blob.prefix(4).elementsEqual("OggS".utf8)
        guard isOgg else {
            // Raw stream: fixed 80-byte mono frames (per JXOpusDecoder).
            let size = 80
            guard blob.count >= size else { return [] }
            return stride(from: 0, to: blob.count - size + 1, by: size).map {
                blob.subdata(in: $0..<($0 + size))
            }
        }
        var packets: [Data] = []
        var pending = Data()
        var index = blob.startIndex
        while index + 27 <= blob.endIndex {
            guard blob[index...].prefix(4).elementsEqual("OggS".utf8) else {
                index += 1
                continue
            }
            let headerType = blob[index + 5]
            let segmentCount = Int(blob[index + 26])
            guard index + 27 + segmentCount <= blob.endIndex else { break }
            let segments = blob[(index + 27)..<(index + 27 + segmentCount)]
            let payloadSize = segments.reduce(0) { $0 + Int($1) }
            let payloadStart = index + 27 + segmentCount
            guard payloadStart + payloadSize <= blob.endIndex else { break }
            let payload = blob[payloadStart..<(payloadStart + payloadSize)]
            if headerType & 0x01 == 0 && !pending.isEmpty {   // not a continuation
                packets.append(pending)
                pending = Data()
            }
            pending.append(payload)
            // A packet ends at a segment shorter than 255.
            if let last = segments.last, last < 255 {
                packets.append(pending)
                pending = Data()
            }
            index = payloadStart + payloadSize
        }
        if !pending.isEmpty { packets.append(pending) }
        return packets.filter { packet in
            !packet.prefix(8).elementsEqual("OpusHead".utf8)
                && !packet.prefix(8).elementsEqual("OpusTags".utf8)
                && packet.count >= 2
        }
    }

    private static func hexPrefix(_ data: Data, count: Int = 12) -> String {
        data.prefix(count).map { String(format: "%02X", $0) }.joined()
    }

    /// The decoder may answer in the card's native rate; the ASR wants 16 kHz
    /// mono s16. The first frame decides the branch, once.
    private static func to16k(_ block: Data, samplesPerFrame: inout Int, event: (String) -> Void) -> Data {
        let samples = block.count / 2
        if samplesPerFrame == 0 {
            samplesPerFrame = samples
            if samples != 320 {
                event("decryptor: opus frame yields \(samples) samples (expected 320 @16k)")
            }
        }
        guard samples == samplesPerFrame, samplesPerFrame != 320, samplesPerFrame % 320 == 0 else {
            return block
        }
        // Naive decimation (48k → 16k = every 3rd sample): the ASR only needs
        // intelligible speech, and the card's audio is band-limited anyway.
        var out = Data()
        out.reserveCapacity(samples / 3 * 2)
        out.withUnsafeMutableBytes { (dest: UnsafeMutablePointer<Int16>) in
            block.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                let input = src.bindMemory(to: Int16.self)
                for i in 0..<(samples / 3) {
                    dest[i] = input[i * 3]
                }
            }
        }
        return out
    }

    private func event(_ line: String) {
        onEvent?(line)
    }

    // MARK: The RSA private key

    /// Cached PEM. The SDK writes it to the keychain (`com.plaud.sdk.rsa`)
    /// when it binds the user; we read the same item back.
    static var privateKeyPem: String?

    /// Scans the app's own generic-password keychain items for a PEM body.
    /// The SDK stores the key under `com.plaud.sdk.rsa`; matching by content
    /// ("BEGIN … PRIVATE KEY") rather than by service name keeps this working
    /// if the SDK renames the item.
    private static func loadPrivateKeyPem() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return nil
        }
        var services: [String] = []
        for item in items {
            let service = item[kSecAttrService as String] as? String ?? "?"
            services.append(service)
            guard let data = item[kSecValueData as String] as? Data,
                  let text = String(data: data, encoding: .utf8),
                  text.contains("PRIVATE KEY") || text.contains("BEGIN RSA") else { continue }
            return text
        }
        _ = services  // (logged by the caller through the "MISSING" event)
        return nil
    }
}
