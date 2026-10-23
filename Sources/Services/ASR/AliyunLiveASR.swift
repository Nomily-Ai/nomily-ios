import AVFoundation
import Foundation
import os

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
            case .partial(let text):
                self.continuation?.yield(.partial(text))
            case .final(let text):
                self.continuation?.yield(.final(text))
            case .failed(let why):
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
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("live-aliyun-\(UUID().uuidString).opus")
                try ogg.write(to: url, options: .atomic)
                defer { try? FileManager.default.removeItem(at: url) }
                for try await buffer in OnDeviceASR.decode(url: url) {
                    if let channel = buffer.int16ChannelData?[0] {
                        pcm.append(Data(bytes: channel, count: Int(buffer.frameLength) * 2))
                    }
                }
            } catch {
                self?.log.warning("aliyun live decode failed: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run {
                guard let self else { return }
                self.decoding = false
                if !pcm.isEmpty { self.client?.send(pcm: pcm) }
                self.decodeNext()
            }
        }
    }
}
