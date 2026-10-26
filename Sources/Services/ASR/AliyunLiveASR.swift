import AVFoundation
import Foundation
import os
import PlaudBleSDK

/// Aliyun real-time recognition fed with the recorder card's **Opus packets**.
///
/// The card gives 160 B CELT packets; Aliyun wants 16 kHz mono 16-bit PCM. The
/// decode step reuses the one path this app already proves on device (the same
/// machinery behind on-device live captions): wrap each batch into an Ogg
/// stream and read it back through `AVAssetReader`. `AudioConverter` +
/// `kAudioFormatOpus` is still off-limits — it deadlocks (A1 notes, 2026-10).
///
/// Batch size is 25 packets = **500 ms**: shorter batches would spend more time
/// on reader start-up than on audio, longer ones add visible caption lag.
final class AliyunLiveASR {

    enum Event {
        case partial(String)
        case final(String)
        case closed(Error?)
    }

    private let profile: OpusOgg.Profile
    private let accessKeyId: String
    private let accessKeySecret: String
    private let appKey: String
    private let region: String

    private let batchPackets = 25
    private var batchBytes: Int { profile.packetBytes * batchPackets }

    private var pending = Data()
    private var decodeQueue: [Data] = []
    private var decoding = false
    private var closed = false
    private var continuation: AsyncStream<Event>.Continuation?
    private var client: AliyunRealtimeClient?
    /// ★ 2026-10-26: "V05E + 阿里云没任何效果" needs numbers to read: packets in,
    /// batches decoded, PCM bytes out. Written once per 10th batch so a long
    /// take does not flood the diag log.
    private var packetsIn = 0
    private var batchesDecoded = 0
    private var pcmBytesOut = 0
    /// ★ 2026-10-26: how many failed batches were kept as on-disk samples
    /// (`diag-aliyun-batch-*.opus` in Documents) — capped at 3.
    private var dumpedFailures = 0

    private let log = Logger(subsystem: "com.nomily.app", category: "asr.aliyun.live")

    init(profile: OpusOgg.Profile, accessKeyId: String, accessKeySecret: String,
         appKey: String, region: String) {
        self.profile = profile
        self.accessKeyId = accessKeyId
        self.accessKeySecret = accessKeySecret
        self.appKey = appKey
        self.region = region
    }

    func connect() throws -> AsyncStream<Event> {
        guard !accessKeyId.isEmpty, !accessKeySecret.isEmpty, !appKey.isEmpty else {
            throw AsrError.missingCredentials(L10n.ASR.aliyun)
        }
        var captured: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event>(bufferingPolicy: .unbounded) { c in captured = c }
        continuation = captured

        let client = AliyunRealtimeClient(
            accessKeyId: accessKeyId,
            accessKeySecret: accessKeySecret,
            appKey: appKey,
            region: region)
        self.client = client
        client.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .ready:
                self.log.notice("aliyun rt ready")
                TicNoteDiagLog.log("XLATE", "aliyun rt ready (engine open)")
            case .partial(let text):
                self.continuation?.yield(.partial(text))
            case .final(let text):
                self.continuation?.yield(.final(text))
            case .failed(let why):
                // ★ 2026-10-26: a dead Aliyun engine used to be invisible — the
                // diag log had nothing between "openASR provider=aliyun" and
                // "no text". Token failures and gateway TaskFailed now land here.
                TicNoteDiagLog.log("XLATE", "aliyun rt FAILED: \(why)")
                self.finish(NSError(domain: "AliyunRT", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: why]))
            case .closed:
                self.finish(nil)
            }
        }
        client.start()
        return stream
    }

    /// One full Opus packet (or an aligned slice of them).
    func send(_ data: Data) {
        guard !closed else { return }
        pending.append(data)
        packetsIn += data.count / max(1, profile.packetBytes)
        while pending.count >= batchBytes {
            let batch = pending.prefix(batchBytes)
            pending.removeFirst(batchBytes)
            decodeQueue.append(Data(batch))
        }
        decodeNext()
    }

    /// Stops feeding audio; the stream **stays open** until the gateway reports
    /// done, because `SentenceEnd`/`TranscriptionCompleted` only arrive after
    /// `StopTranscription`. `AliyunRealtimeClient` guarantees `.closed` within
    /// 3 s, so this cannot hang the session teardown.
    func close() {
        guard !closed else { return }
        closed = true
        decodeQueue.removeAll()
        pending.removeAll()
        if client == nil { finish(nil) } else { client?.stop() }
    }

    private func finish(_ error: Error?) {
        guard continuation != nil else { return }
        continuation?.yield(.closed(error))
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Opus → PCM

    private func decodeNext() {
        guard !decoding, !decodeQueue.isEmpty, !closed else { return }
        decoding = true
        let batch = decodeQueue.removeFirst()
        let ogg = OpusOgg.wrap(rawFrames: batch, serial: 0xA11A_0002, profile: profile)
        guard !ogg.isEmpty else {
            decoding = false
            decodeNext()
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            var pcm = Data()
            var decodeFailed = false
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("live-aliyun-\(UUID().uuidString).opus")
            do {
                try ogg.write(to: url, options: .atomic)
                for try await buffer in OnDeviceASR.decode(url: url) {
                    if let channel = buffer.int16ChannelData?[0] {
                        pcm.append(Data(bytes: channel, count: Int(buffer.frameLength) * 2))
                    }
                }
            } catch {
                decodeFailed = true
                self?.log.warning("aliyun live decode failed: \(error.localizedDescription, privacy: .public)")
                TicNoteDiagLog.log("XLATE", "aliyun live decode FAILED: \(error.localizedDescription) (profile \(self?.profile.packetBytes ?? 0)B)")
            }
            // ★ 2026-10-26 (user: "V05E 实时转录还是没文字"): the device log shows
            // EVERY 500 ms batch failing inside AVAssetReader ("这项操作无法完成")
            // while the same machinery decodes TicNote's whole files fine. Root
            // cause of the per-batch refusal is still open — so fall back to the
            // SDK's own Ogg→PCM converter, which is the path the PLAUD live
            // pipeline proves daily on 16 kHz mono Opus (exactly what V05E is).
            // Order matters: AVAssetReader first (it handles every profile),
            // SDK converter only when it produced nothing.
            if pcm.isEmpty {
                pcm = Self.convertViaSDK(ogg: ogg) ?? Data()
                if !pcm.isEmpty {
                    TicNoteDiagLog.log("XLATE", "aliyun decode via SDK converter: \(pcm.count)B (AVAssetReader path failed\(decodeFailed ? " (threw)" : " (silent)"))")
                }
            }
            // ★ Keep the first three failed batches on disk — the wrap layout
            // vs packet content question ("is it our Ogg or their SILK?") is
            // answerable in one minute from a real sample, and impossible from
            // a log line.
            if decodeFailed, pcm.isEmpty, let self, self.dumpedFailures < 3 {
                self.dumpedFailures += 1
                let dst = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("diag-aliyun-batch-\(self.dumpedFailures)-\(self.profile.packetBytes)B.opus")
                try? ogg.write(to: dst, options: .atomic)
                TicNoteDiagLog.log("XLATE", "decode failure sample kept: \(dst.lastPathComponent)")
            }
            try? FileManager.default.removeItem(at: url)
            await MainActor.run {
                guard let self else { return }
                self.decoding = false
                if !pcm.isEmpty {
                    self.pcmBytesOut += pcm.count
                    self.batchesDecoded += 1
                    if self.batchesDecoded % 10 == 1 {
                        TicNoteDiagLog.log("XLATE", "aliyun decode progress: batches=\(self.batchesDecoded) pcmOut=\(self.pcmBytesOut)B packetsIn=\(self.packetsIn)")
                    }
                }
                if !pcm.isEmpty { self.client?.send(pcm: pcm) }
                self.decodeNext()
            }
        }
    }

    /// The PLAUD stack's proven Ogg→PCM converter (`Mp3Convert`, 16 kHz mono —
    /// the same shape as V05E's packets). Synchronous, writes a `.pcm` sidecar.
    /// Runs off-main; the PLAUD decryptor already calls it from a queue thread.
    private static func convertViaSDK(ogg: Data) -> Data? {
        guard !ogg.isEmpty else { return nil }
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-aliyun-sdk-\(UUID().uuidString).opus")
        let dst = src.path + ".pcm"
        defer {
            try? FileManager.default.removeItem(atPath: src.path)
            try? FileManager.default.removeItem(atPath: dst)
        }
        guard (try? ogg.write(to: src, options: .atomic)) != nil else { return nil }
        Mp3Convert.shared().convertOgg(src.path, toPcm: dst, channels: 1, ns_agc: false, callback: { _ in })
        // The converter writes asynchronously; poll briefly like the live
        // decryptor does. A 500 ms batch converts in well under a second.
        let deadline = Date().addingTimeInterval(3.0)
        var lastSize = -1
        var stable = 0
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            let size = ((try? FileManager.default.attributesOfItem(atPath: dst))?[.size] as? Int) ?? 0
            if size > 0, size == lastSize { stable += 1; if stable >= 2 { break } }
            else { stable = 0 }
            lastSize = size
        }
        guard let data = FileManager.default.contents(atPath: dst), !data.isEmpty else { return nil }
        // The converter may pad to even samples — trim to 16-bit frames.
        return data.prefix(data.count - data.count % 2)
    }
}
