import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr.sensevoice")

// MARK: - SenseVoice 本机转写（★ 2026-11-02 用户："增加一个下载使用 SenseVoice
// 的语音转文字的下载，用户自行点击下载这个功能"）
//
// ## 是什么
//
// SenseVoice Small（阿里 FunAudioLLM 开源）经 sherpa-onnx 转成的 onnx 版本：
// 一个模型覆盖 **中 / 英 / 日 / 韩 / 粤**，int8 量化约 230 MB，**完全离线**
// 跑在手机上——没有 API Key、没有账户、没有流量。与苹果自带的
// `OnDeviceASR`（SFSpeechRecognizer）互补：苹果那条不用下载但语种覆盖和
// 标点质量看系统，这条下载一次后质量更稳、语种更多。
//
// ## 组成
//
//   · `SenseVoiceModelStore` —— 模型下载/删除/进度（ModelScope 主源 +
//     huggingface.co 备源，国内直连优先）；
//   · `SenseVoiceASR` —— 推理：复用 `OnDeviceASR.decode`（AVAssetReader
//     解 Opus/m4a/wav → 16 kHz 单声道 PCM），按 30 秒切片喂
//     sherpa-onnx 的 OfflineRecognizer，时间戳按切片偏移回填。
//
// 运行时二进制来自 SPM 包 `sherpa-onnx`（静态链接，见 project.yml）。

/// 模型文件的落盘与下载状态。
@MainActor
final class SenseVoiceModelStore: ObservableObject {

    static let shared = SenseVoiceModelStore()
    private init() {
        phase = Self.isDownloadedStatic ? .ready : .idle
    }

    // MARK: paths & sources

    /// 模型目录：Application Support/SenseVoice（不进 iCloud 备份的白名单问题
    /// 先不纠结——用户删了能重下，体积也就 230 MB）。
    nonisolated static var modelDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SenseVoice", isDirectory: true)
    }

    nonisolated static var modelFile: URL { modelDir.appendingPathComponent("model.int8.onnx") }
    nonisolated static var tokensFile: URL { modelDir.appendingPathComponent("tokens.txt") }

    /// 下载源，按序尝试：
    /// 1. ModelScope（国内直连，实测 200）。hf-mirror 的 LFS resolve 会 302 到
    ///    `cas-bridge.xethub.hf.co`（Xet CDN），国内 URLSession TLS 直连失败——
    ///    这就是 2026-11-02 真机上「TLS 错误导致链接失败」的根因；
    /// 2. hf-mirror（仍然挂着，限流 429 时也拿不到）；
    /// 3. huggingface.co 官方（国内基本不可达，最后兜底）。
    private static let sources: [(url: URL, label: String)] = [
        (
            URL(string: "https://modelscope.cn/models/pengzhendong/sherpa-onnx-sense-voice-zh-en-ja-ko-yue/resolve/master/")!,
            "modelscope"
        ),
        (
            URL(string: "https://hf-mirror.com/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/")!,
            "hf-mirror"
        ),
        (
            URL(string: "https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/")!,
            "huggingface"
        ),
    ]

    // MARK: state

    enum Phase: Equatable {
        case idle
        case downloading(Double)   // 0…1
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase

    var isDownloaded: Bool { Self.isDownloadedStatic }

    /// nonisolated：`TranscriptionService.hasCredentials`（非主 actor）也要查。
    nonisolated static var isDownloadedStatic: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: modelFile.path) && fm.fileExists(atPath: tokensFile.path)
    }

    /// 已下载体积（展示用）。
    static var downloadedSizeText: String? {
        guard isDownloadedStatic else { return nil }
        let size = ((try? FileManager.default.attributesOfItem(atPath: modelFile.path))?[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    func refresh() {
        phase = Self.isDownloadedStatic ? .ready : .idle
    }

    func delete() {
        try? FileManager.default.removeItem(at: Self.modelDir)
        phase = .idle
        log.notice("SenseVoice model deleted")
    }

    /// 从「文件」App / 隔空投送导入模型（★ 2026-11-02）。
    ///
    /// 为什么要留这条手工通道：模型托管在第三方（ModelScope/HF），任何一个域名
    /// 在国内被挡、被限流，用户就彻底装不上。允许把电脑上下好的两个文件传进手机，
    /// 这条路径不依赖任何服务器。按扩展名认领：`.onnx` → 模型，`.txt` → 词表。
    ///
    /// - Returns: 是否两个文件都已就位。
    @discardableResult
    func importModels(from urls: [URL]) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.modelDir, withIntermediateDirectories: true)
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let ext = url.pathExtension.lowercased()
            let target: URL
            if ext == "onnx" {
                target = Self.modelFile
            } else if ext == "txt" {
                target = Self.tokensFile
            } else {
                continue
            }
            do {
                try? fm.removeItem(at: target)
                try fm.copyItem(at: url, to: target)
                log.notice("SenseVoice model imported: \(target.lastPathComponent, privacy: .public)")
            } catch {
                log.error("SenseVoice import failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        refresh()
        return Self.isDownloadedStatic
    }

    // MARK: download

    private var downloadTask: Task<Void, Never>?

    func download() {
        guard downloadTask == nil, !Self.isDownloadedStatic else { return }
        phase = .downloading(0)
        downloadTask = Task { [weak self] in
            await self?.runDownload()
            self?.downloadTask = nil
        }
    }

    private func runDownload() async {
        try? FileManager.default.createDirectory(at: Self.modelDir, withIntermediateDirectories: true)
        // tokens.txt 很小，先行；模型文件占进度的 99%。
        for (index, file) in ["tokens.txt", "model.int8.onnx"].enumerated() {
            do {
                try await fetch(file: file,
                                baseProgress: index == 0 ? 0 : 0.01,
                                span: index == 0 ? 0.01 : 0.99)
            } catch is CancellationError {
                phase = .idle
                return
            } catch {
                // 两个源都试过仍失败 → 报错；已下好的文件留在原地，重试续传
                // 是重新整个文件（v1 不做断点续传）。
                if Task.isCancelled { phase = .idle; return }
                phase = .failed(error.localizedDescription)
                log.error("SenseVoice download failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        phase = .ready
        log.notice("SenseVoice model ready")
    }

    /// 依次试所有源，谁先给全量 200 就用谁。
    ///
    /// ★ 2026-11-02：每个源失败的原因都记下来，最后一起抛给 UI——
    /// 「下载失败」四个字对排查毫无用处，而设备上的诊断日志又不一定拉得到；
    /// 让用户在设置页一眼看到「modelscope: HTTP 403 / huggingface: TLS」才是可行动的。
    private func fetch(file: String, baseProgress: Double, span: Double) async throws {
        var reasons: [String] = []
        for (base, label) in Self.sources {
            let url = base.appendingPathComponent(file)
            do {
                try await fetchOne(url: url, dest: Self.modelDir.appendingPathComponent(file),
                                   baseProgress: baseProgress, span: span)
                log.notice("SenseVoice \(file, privacy: .public) downloaded from \(label, privacy: .public)")
                TicNoteDiagLog.log("SenseVoice", "ok \(file) via \(label)")
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reasons.append("\(label): \(error.localizedDescription)")
                log.warning("source \(label, privacy: .public) failed for \(file, privacy: .public): \(error.localizedDescription, privacy: .public)")
                TicNoteDiagLog.log("SenseVoice", "fail \(file) via \(label): \(error.localizedDescription)")
            }
        }
        throw SenseVoiceDownloadError.allSourcesFailed(reasons)
    }

    private func fetchOne(url: URL, dest: URL, baseProgress: Double, span: Double) async throws {
        // 显式标注返回 Void——单表达式闭包会被推断成返回 Task 导致类型不符。
        let progressSink: (Double, Int64) -> Void = { [weak self] fraction, _ in
            Task { @MainActor in
                self?.phase = .downloading(min(0.999, baseProgress + fraction * span))
            }
        }
        // ⚠️ 落盘必须在 `didFinishDownloadingTo` **里面**完成——见 `HTTPDownload` 的说明。
        try await HTTPDownload.fetch(url: url, dest: dest, onProgress: progressSink)
        // 下完再校验一下体积：服务端给了一张错误页也能"下载成功"。
        let size = ((try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int) ?? 0
        let minSize = url.lastPathComponent.hasSuffix(".onnx") ? 50_000_000 : 1_000
        guard size >= minSize else {
            try? FileManager.default.removeItem(at: dest)
            throw SenseVoiceDownloadError.incomplete(file: url.lastPathComponent, bytes: size)
        }
    }
}

/// 下载阶段的错误。文案要能直接放进设置页给用户看（也写进诊断日志）。
enum SenseVoiceDownloadError: LocalizedError {
    case http(status: Int, host: String)
    case incomplete(file: String, bytes: Int)
    case allSourcesFailed([String])

    var errorDescription: String? {
        switch self {
        case .http(let status, let host):
            return "HTTP \(status)（\(host)）"
        case .incomplete(let file, let bytes):
            return "\(file) 只下到 \(bytes) 字节，不完整"
        case .allSourcesFailed(let reasons):
            // 一行一个源，用户截图就能定位是哪一个源被挡。
            return reasons.joined(separator: "\n")
        }
    }
}

// MARK: - URLSession download with progress

/// 一次性下载会话：进度回调 + async 完成。
///
/// ⚠️ **落盘必须在 delegate 回调内完成**（★ 2026-11-02 真机修复）：
/// `didFinishDownloadingTo` 给的临时文件在**该方法返回后立刻被系统删除**。
/// 旧实现只把 `location` 传给 `await` 之后的代码去 move —— 下载明明成功了，
/// `moveItem` 却报 "file doesn't exist"，用户看到的就是"下载失败"。
/// 现在 `dest` 直接传进来，在回调里 move 完再返回。
///
/// ⚠️ 另外两处：`session` 必须**强引用**到任务结束（旧代码 weak 持有，靠系统偶然
/// 保活）；UA 用浏览器的形状，部分 CDN 对陌生的 UA 直接 403。
private enum HTTPDownload {

    /// 正在跑的 session 强引用。`URLSession` 只被它的 delegate 弱引用，
    /// 一旦本地变量出了作用域就可能被释放、任务静默消失。
    private static let lock = NSLock()
    private static var active: [URLSession] = []

    private static func retain(_ session: URLSession) {
        lock.lock(); active.append(session); lock.unlock()
    }

    private static func release(_ session: URLSession) {
        lock.lock(); active.removeAll { $0 === session }; lock.unlock()
    }

    static func fetch(url: URL, dest: URL, onProgress: @escaping (Double, Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let delegate = Delegate(dest: dest, onProgress: onProgress, continuation: cont)
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 60
            cfg.timeoutIntervalForResource = 3600
            cfg.httpMaximumConnectionsPerHost = 4
            let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            retain(session)
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                forHTTPHeaderField: "User-Agent"
            )
            session.downloadTask(with: request).resume()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate {
        let dest: URL
        let onProgress: (Double, Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
        weak var session: URLSession?
        private var resumed = false
        private let lock = NSLock()

        init(dest: URL, onProgress: @escaping (Double, Int64) -> Void,
             continuation: CheckedContinuation<Void, Error>) {
            self.dest = dest
            self.onProgress = onProgress
            self.continuation = continuation
        }

        private func resumeOnce(_ result: Result<Void, Error>) {
            lock.lock()
            guard !resumed else { lock.unlock(); return }
            resumed = true
            lock.unlock()
            if let session {
                HTTPDownload.release(session)
                session.finishTasksAndInvalidate()
            }
            continuation.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // ⚠️ 404/403 也会走到这里（body 是错误页）——必须看状态码，
            // 否则镜像回退会把"下载成功"错判在第一个 404 上。
            if let http = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(http.statusCode) {
                TicNoteDiagLog.log("SenseVoice", "HTTP \(http.statusCode) from \(http.url?.host ?? "?")")
                resumeOnce(.failure(SenseVoiceDownloadError.http(
                    status: http.statusCode, host: http.url?.host ?? "?")))
                return
            }
            // ★ 就在这个回调里落盘：临时文件出了回调就没了。
            do {
                let fm = FileManager.default
                try? fm.removeItem(at: dest)
                try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.moveItem(at: location, to: dest)
                resumeOnce(.success(()))
            } catch {
                resumeOnce(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                TicNoteDiagLog.log("SenseVoice", "transport error \(task.currentRequest?.url?.host ?? "?") — \(error.localizedDescription)")
                resumeOnce(.failure(error))
            }
        }
    }
}

// MARK: - 推理

enum SenseVoiceAsrError: LocalizedError {
    case notDownloaded
    case empty

    var errorDescription: String? {
        switch self {
        case .notDownloaded: return L10n.SenseVoice.notDownloaded
        case .empty: return L10n.ASR.transcriptEmpty
        }
    }
}

enum SenseVoiceASR {

    /// 切片时长：SenseVoice 一次吃 30 s 内的音频最稳（官方 VAD 建议值附近），
    /// 长录音按 30 s 硬切，时间戳按切片偏移回填。
    private static let chunkSeconds = 30.0
    private static let sampleRate = 16_000.0

    /// 文件转写入口（`TranscriptionService` 的 provider `"sensevoice"`）。
    static func transcribe(fileURL: URL, locales: [String]?) async throws -> AsrResult {
        guard SenseVoiceModelStore.isDownloadedStatic else {
            throw SenseVoiceAsrError.notDownloaded
        }
        let segments = try await run(fileURL: fileURL)
        guard !segments.isEmpty else { throw SenseVoiceAsrError.empty }
        let text = segments.map(\.text).joined(separator: "\n")
        return AsrResult(
            text: text,
            segments: segments,
            provider: "sensevoice",
            locale: locales?.first ?? "zh"
        )
    }

    /// 解码 → 切片 → 逐片识别。全部重活都在 detached 任务里，
    /// OfflineRecognizer 不是 Sendable，串行使用。
    private static func run(fileURL: URL) async throws -> [AsrSegment] {
        let modelPath = SenseVoiceModelStore.modelFile.path
        let tokensPath = SenseVoiceModelStore.tokensFile.path

        return try await Task.detached(priority: .userInitiated) {
            let engine = SenseVoiceEngine(modelPath: modelPath, tokensPath: tokensPath)
            var segments: [AsrSegment] = []
            var chunk: [Float] = []
            var chunkStart = 0.0

            func flushChunk() {
                guard !chunk.isEmpty else { return }
                let duration = Double(chunk.count) / sampleRate
                let text = engine.transcribe(chunk)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    segments.append(AsrSegment(speaker: nil, text: trimmed,
                                               start: chunkStart, end: chunkStart + duration,
                                               duration: duration))
                }
                chunkStart += duration
                chunk.removeAll(keepingCapacity: true)
            }

            for try await buffer in OnDeviceASR.decode(url: fileURL) {
                // OnDeviceASR.decode 产出 **Int16** 16 kHz 单声道（pcmFormat 是
                // .pcmFormatInt16）——必须走 int16ChannelData，再归一到 [-1, 1]。
                guard let channel = buffer.int16ChannelData?[0] else { continue }
                let frames = Int(buffer.frameLength)
                let pcm = UnsafeBufferPointer(start: channel, count: frames)
                for s in pcm { chunk.append(Float(s) / 32768.0) }
                if Double(chunk.count) / sampleRate >= chunkSeconds {
                    flushChunk()
                }
            }
            flushChunk()
            return segments
        }.value
    }
}

// MARK: - sherpa-onnx 绑定（唯一 import SherpaOnnx 的文件）

#if canImport(SherpaOnnx)
import SherpaOnnx

/// sherpa-onnx OfflineRecognizer 的最小封装。单独一个类型，把第三方 API
/// 面收窄成 `init + transcribe([Float]) -> String`。
/// 构造方式照抄上游示例 `decode-file-sense-voice-with-hr.swift`（v1.13.8）。
final class SenseVoiceEngine: @unchecked Sendable {

    private let recognizer: SherpaOnnxOfflineRecognizer

    init(modelPath: String, tokensPath: String) {
        // language 留空 = 自动识别（模型本身支持 zh/en/ja/ko/yue）。
        let senseVoice = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: modelPath, language: "", useInverseTextNormalization: true)
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensPath,
            numThreads: 2,
            senseVoice: senseVoice)
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig, modelConfig: modelConfig)
        self.recognizer = SherpaOnnxOfflineRecognizer(config: &config)
    }

    /// 一段 16 kHz 单声道 PCM（[-1, 1]）的识别文本。
    func transcribe(_ samples: [Float]) -> String {
        guard !samples.isEmpty else { return "" }
        return recognizer.decode(samples: samples, sampleRate: 16000).text
    }
}
#endif
