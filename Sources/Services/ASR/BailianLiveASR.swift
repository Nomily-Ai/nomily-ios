import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr.bailian.live")

/// 自定义（OpenAI 兼容 / 百炼）端点的**分段准实时**识别器。
///
/// ## 为什么需要这一层（2026-11-04）
///
/// 用户把「识别服务」选成了自己的自定义端点（`asr_providers.custom`，
/// `protocol = bailian`，`model = qwen-audio-3.0-asr-flash`），但实时字幕却跑在
/// Azure 上。原因是三处实时引擎工厂（`LiveModel.openASR`、
/// `PlaudDirectService.makeLiveASREngine`、`LiveCaptionController.makeEngine`）
/// 的 `switch` 里根本没有 `custom` 分支，落到 `default: break` 被**静默跳过**，
/// 于是链路顺着 `fallbacks`（sensevoice → aliyun → azure → local）一路走到 Azure。
///
/// ## 为什么不是「真的流式」
///
/// 百炼兼容端点只提供 `chat/completions` + `input_audio`（base64 整段音频），
/// 没有 `audio/transcriptions`，也没有 WS 双向流——见 `BailianASR` 顶部的实测记录。
/// 所以这里的做法是**定长切片准实时**：每攒够 `chunkSeconds` 秒 PCM 就封成一个
/// 16 kHz/mono/16-bit 的 WAV，串行 POST 一次，回来的文本按原始时间轴追加成一行。
///
/// 体验上：说话 → 约 1–2 秒后出这一段的文字，整体延迟 ≈ `chunkSeconds + 1.5s`。
/// 比真正的流式慢，但**用的是用户自己配的服务器**，这比"偷偷换成 Azure"正确得多。
final class BailianChunker {

    struct Chunk {
        var pcm: Data
        var start: Double
        var end: Double
    }

    static let sampleRate = 16_000
    /// 16 kHz × 16-bit × 单声道
    static let bytesPerSecond = 32_000

    private let endpoint: String
    private let apiKey: String
    private let model: String
    private let language: String
    private let chunkSeconds: Double

    private let lock = NSLock()
    private var buffer = Data()
    private var queue: [Chunk] = []
    private var inFlight = false
    private var stopped = false
    /// 已经在时间轴上排到的位置（秒）。按样本数推进，不信外部时钟——卡片的
    /// `elapsed` 在暂停/重连时会回跳，用它算时间戳会让字幕顺序错乱。
    private var queuedSeconds: Double = 0

    /// (text, start, end) —— 在后台队列回调，调用方自己跳主线程。
    var onText: ((String, Double, Double) -> Void)?
    /// 一次切片失败（HTTP / 网络）。调用方决定是整条链路判死还是跳过这一段。
    var onFailure: ((Error) -> Void)?
    /// `finish()` 之后队列排空时回调一次。
    var onDrained: (() -> Void)?

    init(endpoint: String, apiKey: String, model: String, language: String,
         chunkSeconds: Double = 5) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model.isEmpty ? BailianASR.defaultModel : model
        self.language = language
        self.chunkSeconds = max(2, chunkSeconds)
    }

    // MARK: - Feeding

    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        buffer.append(pcm)
        let target = Int(chunkSeconds * Double(Self.bytesPerSecond))
        // ⚠️ 只切**整秒对齐**的块：一块的时长决定它在时间轴上的长短，切歪了会
        // 让后面所有行的时间戳整体漂移。
        while buffer.count >= target {
            let piece = Data(buffer.prefix(target))
            buffer.removeFirst(target)
            enqueueLocked(piece)
        }
    }

    /// 收尾：把不足一块的尾巴也送出去（短于 0.6 s 的丢掉——一段话的残音，
    /// 送过去只会换回一句幻听）。
    func finish() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        if buffer.count >= Self.bytesPerSecond * 3 / 5 {
            enqueueLocked(buffer)
        }
        buffer.removeAll()
        let idle = queue.isEmpty && !inFlight
        lock.unlock()
        if idle { onDrained?() }
    }

    private func enqueueLocked(_ pcm: Data) {
        let start = queuedSeconds
        let end = start + Double(pcm.count) / Double(Self.bytesPerSecond)
        queuedSeconds = end
        queue.append(Chunk(pcm: pcm, start: start, end: end))
        pumpLocked()
    }

    private func pumpLocked() {
        guard !inFlight, !queue.isEmpty else { return }
        inFlight = true
        let chunk = queue.removeFirst()
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.send(chunk.pcm)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self.onText?(trimmed, chunk.start, chunk.end)
                }
            } catch {
                TicNoteDiagLog.log("XLATE", "custom chunk \(Int(chunk.start))s failed: \(error.localizedDescription)")
                self.onFailure?(error)
            }
            self.lock.lock()
            self.inFlight = false
            let drained = self.stopped && self.queue.isEmpty
            self.pumpLocked()
            let stillIdle = self.stopped && self.queue.isEmpty && !self.inFlight
            self.lock.unlock()
            if drained || stillIdle { self.onDrained?() }
        }
    }

    // MARK: - HTTP

    private func send(_ pcm: Data) async throws -> String {
        guard let url = URL(string: BailianASR.chatURL(endpoint)) else {
            throw AsrError.missingCredentials("自定义识别服务（地址不合法）")
        }
        do {
            return try await sendOnce(pcm, to: url)
        } catch let error as AsrError {
            // ★ 2026-11-05：MAAS 专属端点路径不对时回 400 空错误体——换官方
            // 兼容路径（…/compatible-mode/v1）把同一切片再试一次（见 BailianASR
            // 同名逻辑；实时切片逐条走，试错成本只有一段 5 s 音频）。
            guard case AsrError.http(let status, let message) = error,
                  status == 400, message.contains("端点返回空错误体"),
                  let alt = BailianASR.alternateCompatibleURL(url) else { throw error }
            TicNoteDiagLog.log("XLATE", "custom chunk: empty-body 400 — retrying via \(alt.absoluteString)")
            return try await sendOnce(pcm, to: alt)
        }
    }

    private func sendOnce(_ pcm: Data, to url: URL) async throws -> String {
        let wav = Self.wav(pcm)
        let uri = "data:audio/wav;base64," + wav.base64EncodedString()
        var options: [String: Any] = ["enable_itn": true]
        if let hint = BailianASR.shortCode(language) { options["language"] = hint }
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "user", "content": [["type": "input_audio", "input_audio": ["data": uri]]]]
            ],
            "asr_options": options,
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // 一段 5 s 音频正常 1–3 s 内回来；20 s 是"这条链路已经不可用"的界限，
        // 卡在这里会让后面的切片全部淤积。
        req.timeoutInterval = 20
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw AsrError.transport(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        LLMRequestLog.record(req, code: status, millis: 0, note: "bailian-live-asr")
        guard 200..<300 ~= status else {
            let raw = String(data: data.prefix(600), encoding: .utf8) ?? ""
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // ★ 2026-11-04: 这个端点对错误只回 `{}`（真机日志里每条都是
            // `HTTP 400: {}`），等于什么都没说。把**我们发了什么**补进错误里：
            // 模型名、完整路径、音频大小，下一次看通知就知道该改哪一项。
            // ★ 2026-11-05：改成完整 URL 路径——/v1 与 /compatible-mode/v1
            // 光看主机名分不出来。
            let hostPart = (url.host ?? "-") + url.path
            let context = "model=\(model) url=\(hostPart) audio=\(pcm.count / 1024)KB wav"
            let meaning: String
            if text.isEmpty || text == "{}" || text == "[]" {
                meaning = "端点返回空错误体（多半是模型名/部署不支持这段音频），已发送：\(context)"
            } else {
                meaning = "\(text)（已发送：\(context)）"
            }
            throw AsrError.http(status, meaning)
        }
        return try BailianASR.parseText(data)
    }

    // MARK: - WAV

    /// 44 字节 RIFF 头 + 裸 PCM。端点按 `data:` 的 MIME 判格式，`audio/wav`
    /// 比 `audio/ogg` 更保险：PCM 是这里唯一有的东西。
    static func wav(_ pcm: Data) -> Data {
        var d = Data(capacity: pcm.count + 44)
        let byteRate = UInt32(bytesPerSecond)
        let blockAlign = UInt16(2)
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(le32(UInt32(36 + pcm.count)))
        d.append(contentsOf: Array("WAVEfmt ".utf8))
        d.append(le32(16))                       // PCM chunk size
        d.append(le16(1))                        // format = PCM
        d.append(le16(1))                        // channels
        d.append(le32(UInt32(sampleRate)))
        d.append(le32(byteRate))
        d.append(le16(blockAlign))
        d.append(le16(16))                       // bits per sample
        d.append(contentsOf: Array("data".utf8))
        d.append(le32(UInt32(pcm.count)))
        d.append(pcm)
        return d
    }

    private static func le32(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    private static func le16(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }
}

/// 录音卡片（D·NOTE / soundcore / V05E …）的 **Opus 包** → 分段准实时。
///
/// 结构照 `AliyunLiveASR` 抄：`send(_:)` 收整帧 Opus，攒够 25 帧（≈500 ms）
/// 解成 16 kHz mono PCM，再交给 `BailianChunker` 按 5 s 切片上云。
final class BailianLiveASR {

    enum Event {
        case partial(String)
        case final(String)
        case closed(Error?)
    }

    private let profile: OpusOgg.Profile
    private let chunker: BailianChunker

    private let batchPackets = 25
    private var batchBytes: Int { max(1, profile.packetBytes) * batchPackets }

    private var pending = Data()
    private var decodeQueue: [Data] = []
    private var decoding = false
    private var closed = false
    private var continuation: AsyncStream<Event>.Continuation?
    private var liveDecoder: SoundcoreLiveDecoder?
    private var producedResult = false
    private var fatalError: Error?

    private let log = Logger(subsystem: "com.nomily.app", category: "asr.bailian.live")

    init(profile: OpusOgg.Profile, endpoint: String, apiKey: String,
         model: String, language: String, chunkSeconds: Double = 5) {
        self.profile = profile
        self.chunker = BailianChunker(endpoint: endpoint, apiKey: apiKey,
                                      model: model, language: language,
                                      chunkSeconds: chunkSeconds)
        chunker.onText = { [weak self] text, _, _ in
            guard let self else { return }
            self.producedResult = true
            self.continuation?.yield(.final(text))
        }
        // ⚠️ 第一段就失败 = 这条链路根本不通（地址错、key 错、模型名错）。
        // 此时必须**主动关掉**，让 `handleASRClosed` 把 custom 判死并落到下一
        // 个 provider；否则整场录音会安静地没有字幕，用户只会觉得"又坏了"。
        chunker.onFailure = { [weak self] error in
            guard let self, !self.producedResult, self.fatalError == nil else { return }
            self.fatalError = error
            self.log.warning("custom live chunk failed: \(error.localizedDescription, privacy: .public)")
            self.finish(error)
        }
        chunker.onDrained = { [weak self] in
            guard let self, self.closed else { return }
            self.finish(self.fatalError)
        }
    }

    func connect() throws -> AsyncStream<Event> {
        guard !closed else { throw AsrError.missingCredentials(L10n.ASR.customServer) }
        var captured: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event>(bufferingPolicy: .unbounded) { c in captured = c }
        continuation = captured
        TicNoteDiagLog.log("XLATE", "custom rt ready (chunked, profile \(profile.packetBytes)B)")
        return stream
    }

    /// 一个完整的 Opus 包（或若干整包的拼接）。
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

    func close() {
        guard !closed else { return }
        closed = true
        decodeQueue.removeAll()
        // 尾巴里不足 500 ms 的包也解掉——最后半句往往就在这里。
        if !pending.isEmpty {
            let tail = pending
            pending.removeAll()
            if profile.packetBytes == SoundcoreOgg.frameSize {
                if liveDecoder == nil { liveDecoder = SoundcoreLiveDecoder() }
                let pcm = liveDecoder?.decode(tail) ?? Data()
                chunker.append(pcm)
            }
        }
        chunker.finish()
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

        // 160 B 帧：JXOpusDecoder 直解 + 降 16 kHz，与 `AliyunLiveASR` 同一条
        // 已验证的解码链（`SoundcoreLiveDecoder` 注释里有真机实测记录）。
        //
        // ★★ 2026-11-04：解码**不能在主 actor 上做**。这条链每 500 ms 解 25 帧，
        //   压在主线程上会让录音页的包计数/读数一卡一跳（用户："百炼的实时有语音，
        //   但秒数计时不是正常读秒"）。和 `AliyunLiveASR` 同一处修正。
        if profile.packetBytes == SoundcoreOgg.frameSize {
            if liveDecoder == nil { liveDecoder = SoundcoreLiveDecoder() }
            let decoder = liveDecoder!
            Task.detached(priority: .userInitiated) { [weak self] in
                let pcm = decoder.decode(batch)
                await MainActor.run {
                    guard let self else { return }
                    self.decoding = false
                    if !pcm.isEmpty { self.chunker.append(pcm) }
                    self.decodeNext()
                }
            }
            return
        }

        let ogg = OpusOgg.wrap(rawFrames: batch, serial: 0xB411_0003, profile: profile)
        guard !ogg.isEmpty else {
            decoding = false
            decodeNext()
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            var pcm = Data()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("live-custom-\(UUID().uuidString).opus")
            do {
                try ogg.write(to: url, options: .atomic)
                for try await buffer in OnDeviceASR.decode(url: url) {
                    if let channel = buffer.int16ChannelData?[0] {
                        pcm.append(Data(bytes: channel, count: Int(buffer.frameLength) * 2))
                    }
                }
            } catch {
                self?.log.warning("custom live decode failed: \(error.localizedDescription, privacy: .public)")
            }
            try? FileManager.default.removeItem(at: url)
            await MainActor.run {
                guard let self else { return }
                self.decoding = false
                if !pcm.isEmpty { self.chunker.append(pcm) }
                self.decodeNext()
            }
        }
    }
}
