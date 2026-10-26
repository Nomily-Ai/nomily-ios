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
            timer.schedule(deadline: .now() + 2.5, repeating: 3.0)
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
        guard expectedOffset >= 624 else {
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
        // Belt-and-braces: the decrypt call is an @objc category method on
        // BleAgent. If the linker ever drops the category again (it needs
        // -ObjC — see project.yml), aborting with an unhandled ObjC exception
        // on this queue took the whole app down (crash 2026-10-23 20:30);
        // fail loud in the diag log instead.
        let decryptSelector = Selector(("decryptE2EEAudioFileWithInputPath:outputPath:privateKeyPem:error:"))
        guard BleAgent.shared.responds(to: decryptSelector) else {
            event("decryptor: SDK does not respond to decryptE2EEAudioFile — static-link ObjC flag missing?")
            return
        }
        let out: String
        do {
            out = try BleAgent.shared.decryptE2EEAudioFile(
                inputPath: filePath,
                outputPath: decryptedPath,
                privateKeyPem: pem
            )
        } catch {
            event("decryptor: decrypt failed \(error)")
            return
        }
        guard out == decryptedPath else {
            event("decryptor: decrypt returned unexpected path \(out)")
            return
        }
        guard let blob = FileManager.default.contents(atPath: decryptedPath) else {
            event("decryptor: decrypted output unreadable")
            return
        }

        let totalFrames = blob.count / frameBytes
        guard totalFrames > decodedFrames else { return }

        var pcm = Data()
        pcm.reserveCapacity((totalFrames - decodedFrames) * 640)
        for index in decodedFrames..<totalFrames {
            let frame = blob.subdata(in: (index * frameBytes)..<((index + 1) * frameBytes))
            guard let block = opusDecoder?.decode(frame), !block.isEmpty else { continue }
            pcm.append(Self.to16k(block, samplesPerFrame: &samplesPerFrame, event: event))
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
