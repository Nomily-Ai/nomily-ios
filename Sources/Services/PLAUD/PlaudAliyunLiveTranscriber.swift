import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "plaud.live-asr.aliyun")

/// Aliyun NLS real-time recognition for PLAUD's live PCM (2026-10-23).
///
/// The PLAUD SDK's sync-file channel already hands over **16 kHz mono 16-bit
/// PCM**, which is exactly what Aliyun wants — no decode step, unlike the
/// recorder-card path (`AliyunLiveASR` decodes Opus first). This is the engine
/// that makes "国内实时字幕" work on the PLAUD card with the credentials the user
/// already configured for file transcription.
final class PlaudAliyunLiveTranscriber: PlaudLiveASR {

    private(set) var segments: [PlaudLiveSegment] = []
    private(set) var partial = ""
    private(set) var unavailable: PlaudLiveASRUnavailable?
    let providerName = "aliyun"
    var onTextChange: (() -> Void)?
    var onFailure: ((PlaudLiveASRUnavailable) -> Void)?

    private let accessKeyId: String
    private let accessKeySecret: String
    private let appKey: String
    private let region: String

    private let lock = NSLock()
    private var pending = Data()
    private var client: AliyunRealtimeClient?
    /// Card clock at the first block, so a final line can carry a timestamp.
    private var clockOrigin: TimeInterval?
    private var lastElapsed: TimeInterval = 0
    private var batchesSent = 0
    private var closed = false

    /// 100 ms of 16 kHz/16-bit mono = 3 200 B — Aliyun's documented granularity.
    private static let flushBytes = 3_200

    init(accessKeyId: String, accessKeySecret: String, appKey: String, region: String) {
        self.accessKeyId = accessKeyId
        self.accessKeySecret = accessKeySecret
        self.appKey = appKey
        self.region = region
    }

    // MARK: - Lifecycle

    func start() {
        guard !accessKeyId.isEmpty, !accessKeySecret.isEmpty, !appKey.isEmpty else {
            unavailable = .aliyunMissing
            log.notice("aliyun live engine missing credentials")
            return
        }
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
                TicNoteDiagLog.log("PLAUD-Aliyun", "TranscriptionStarted")
            case .partial(let text):
                DispatchQueue.main.async {
                    guard self.partial != text else { return }
                    self.partial = text
                    self.publish()
                }
            case .final(let text):
                self.lock.lock()
                let origin = self.clockOrigin ?? 0
                let at = max(origin, self.lastElapsed)
                self.lock.unlock()
                TicNoteDiagLog.log("PLAUD-Aliyun", "final at=\(Int(at))s: \(text)")
                DispatchQueue.main.async {
                    if self.segments.last?.text != text {
                        self.segments.append(PlaudLiveSegment(text: text, at: at))
                    }
                    self.partial = ""
                    self.publish()
                }
            case .failed(let why):
                TicNoteDiagLog.log("PLAUD-Aliyun", "failed: \(why)")
                self.unavailable = .aliyunFailed(why)
                DispatchQueue.main.async { self.onFailure?(.aliyunFailed(why)) }
            case .closed:
                TicNoteDiagLog.log("PLAUD-Aliyun", "closed batches=\(self.batchesSent)")
            }
        }
        client.start()
    }

    func stop() {
        closed = true
        client?.stop()
    }

    func reset() {
        lock.lock()
        pending = Data()
        clockOrigin = nil
        lastElapsed = 0
        lock.unlock()
        segments = []
        partial = ""
        publish()
    }

    // MARK: - PCM input

    func append(_ pcm: Data, elapsed: TimeInterval) {
        guard !closed, client != nil else { return }
        lock.lock()
        if clockOrigin == nil { clockOrigin = elapsed }
        lastElapsed = elapsed
        pending.append(pcm)
        var outgoing = Data()
        while pending.count >= Self.flushBytes {
            outgoing.append(pending.prefix(Self.flushBytes))
            pending.removeFirst(Self.flushBytes)
        }
        lock.unlock()
        guard !outgoing.isEmpty else { return }
        batchesSent += 1
        if batchesSent == 1 {
            TicNoteDiagLog.log("PLAUD-Aliyun", "first 100 ms batch sent")
        }
        client?.send(pcm: outgoing)
    }

    private func publish() {
        onTextChange?()
    }
}
