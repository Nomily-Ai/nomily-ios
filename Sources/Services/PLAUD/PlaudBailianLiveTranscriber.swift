import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "plaud.live.custom")

/// 自定义（OpenAI 兼容 / 百炼）端点的实时引擎——喂 **16 kHz mono PCM** 的那一路。
///
/// 卡片直连（`PlaudDirectService`）和手机麦克风字幕（`LiveCaptionController`）
/// 拿到的都是裸 PCM，不需要 Opus 解码，所以这里直接接到 `BailianChunker`
/// 上做 5 s 切片准实时；`BailianLiveASR` 是同一套切片逻辑的 Opus 版本。
///
/// ★ 2026-11-04：这两个路径原来都把 `custom` 归到
/// `default: // local / remote / custom: Opus-only` 里 `continue` 掉了，
/// 于是用户选了自定义服务器，实时字幕却还是 Azure。
final class PlaudBailianLiveTranscriber: PlaudLiveASR {

    private(set) var segments: [PlaudLiveSegment] = []
    private(set) var partial = ""
    private(set) var unavailable: PlaudLiveASRUnavailable?
    let providerName = "custom"
    var onTextChange: (() -> Void)?
    var onFailure: ((PlaudLiveASRUnavailable) -> Void)?

    private let endpoint: String
    private let language: String
    private let chunker: BailianChunker
    private let lock = NSLock()
    private var stopped = false
    private var producedResult = false

    init(endpoint: String, apiKey: String, model: String, language: String,
         chunkSeconds: Double = 5) {
        self.endpoint = endpoint
        self.language = language
        self.chunker = BailianChunker(endpoint: endpoint, apiKey: apiKey,
                                      model: model, language: language,
                                      chunkSeconds: chunkSeconds)
        chunker.onText = { [weak self] text, _, end in
            guard let self else { return }
            self.producedResult = true
            DispatchQueue.main.async {
                if self.segments.last?.text != text {
                    self.segments.append(PlaudLiveSegment(text: text, at: max(0, end)))
                }
                self.publish()
            }
        }
        chunker.onFailure = { [weak self] error in
            guard let self else { return }
            TicNoteDiagLog.log("PLAUD-Custom", "chunk failed: \(error.localizedDescription)")
            // 第一段就失败 = 链路不通（地址/key/模型名）。报给上层让它换引擎；
            // 中途偶发失败只丢这一段，整场不该因此报废。
            guard !self.producedResult else { return }
            let why = error.localizedDescription
            self.unavailable = .customFailed(why)
            DispatchQueue.main.async { self.onFailure?(.customFailed(why)) }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            unavailable = .customMissing
            log.notice("custom live engine missing endpoint")
            return
        }
        TicNoteDiagLog.log("PLAUD-Custom", "engine started (chunked 5s) lang=\(language)")
    }

    func stop() {
        lock.lock()
        let already = stopped
        stopped = true
        lock.unlock()
        guard !already else { return }
        chunker.finish()
    }

    func reset() {
        segments = []
        partial = ""
        unavailable = nil
        producedResult = false
        stop()
    }

    func append(_ pcm: Data, elapsed: TimeInterval) {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        guard !isStopped else { return }
        chunker.append(pcm)
    }

    private func publish() {
        onTextChange?()
    }
}
