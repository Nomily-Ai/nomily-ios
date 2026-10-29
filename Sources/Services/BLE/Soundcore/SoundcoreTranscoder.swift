import AudioToolbox
import Foundation
import PlaudBleSDK
import os.log

private let transcodeLog = Logger(subsystem: "com.nomily.app.ios", category: "ble.soundcore.transcode")

/// PCM 落盘接口（AAC 建不起来时落到 WAV）。
private protocol SoundcorePcmSink: AnyObject {
    var fileExtension: String { get }
    @discardableResult func write(_ pcm: Data) -> Bool
    func finish() -> Bool
    func readData() -> Data?
    func discard()
}

/// D3200 raw Opus frames → 可直接播放的音频文件（AAC/m4a，WAV 兜底）。
///
/// ## ★ 2026-10-27 第三次返工（用户："传输过去的录音都是 0s…里面的录音听着也有问题"）
///
/// 上一版走的是 PlaudBleSDK 的 `Mp3Convert.convertOgg:toMp3:`，两条硬伤都被真机证实：
///
///  1. **声音不对**：`Mp3Convert` 是给 PLAUD 卡的 Ogg 调的（16 kHz / 80 B 帧），
///     豆是 48 kHz / 160 B 帧，同一段容器喂进去解出来的采样率/节奏都不对；
///  2. **时长 0 s**：它输出的 mp3 是无 Xing/LAME 头的 VBR，`AVURLAsset`
///     读不出时长，`AVAudioFile` 也打不开这类畸形文件 —— 列表只能显示 0s。
///
/// 现在的做法是**彻底不走容器**：豆的离线/实时流本来就是裸的定长 Opus 帧
/// （160 B = 20 ms @48 kHz mono CBR，见 `SoundcoreOgg`），直接逐帧喂 SDK 自带的
/// `JXOpusDecoder`——注意它按 **80 B × 声道数**切包（头文件原文），所以必须
/// `channels: 2` 才能整包吃下 160 B 单声道帧，解完降混回单声道（PLAUD 实时
/// 链路天天在用这条解码链），得到 PCM 后自己封装成 **AAC/m4a**：
///
///  - m4a 有真实的时长/采样率元数据 → 列表时长正确、AVPlayer 全系统版本可播；
///  - ASR 上传接受 m4a（和 mp3 同级），转写链路不用改；
///  - 采样率**实测**得到（第一帧解出来的样本数 × 50 = 每秒帧数），不假设
///    JXOpusDecoder 内部固定输出 16 kHz 还是 48 kHz；
///  - 按 OpusHead 声明的 preskip（3840 @48 kHz，等比换算）丢掉开头样本，
///    和 `SoundcoreOgg` 的封装口径保持一致，时长 = 解码样本数 / 采样率。
///
/// 全程失败时返回 nil，调用方回落到 `.opus`（iOS 17 可播、转写不受影响）——
/// fail-open，绝不因为转码把已经拉下来的录音弄丢。
enum SoundcoreTranscoder {

    /// 转码结果：可播放字节 + 落盘后缀 + 精确时长。
    struct Output {
        let data: Data
        let fileExtension: String
        let durationSeconds: Double
        let formatNote: String
    }

    /// 单帧字节数（豆的传输切片固定 160 B，见 `SoundcoreOgg.frameSize`）。
    private static let frameSize = SoundcoreOgg.frameSize
    /// 每帧 20 ms → 每秒 50 帧（与采样率无关，Opus 帧长恒定）。
    private static let framesPerSecond = 50
    /// OpusHead 里声明的 preskip（48 kHz 基准）。
    private static let preskipAt48k = SoundcoreOgg.preskip
    /// 写文件的批次：0.5 s 一段 @48 kHz，避免长录音把 PCM 全憋在内存里。
    private static let flushSamplesAt48k = 24_000

    // MARK: - 入口

    /// 裸 Opus 帧流 → AAC m4a（首选）/ WAV（兜底）。失败返回 nil。
    static func transcode(_ raw: Data) -> Output? {
        guard raw.count >= frameSize else {
            transcodeLog.warning("transcode skipped: payload \(raw.count, privacy: .public)B < one frame")
            return nil
        }
        let frames = splitFrames(raw)
        guard !frames.isEmpty else { return nil }

        // ① 探测：一次性解码器试解几帧，拿每帧样本数 → 反推采样率。
        guard let probed = probe(frames) else {
            transcodeLog.warning("transcode aborted: JXOpusDecoder produced no PCM for probe frames")
            return nil
        }
        let sampleRate = probed.rate
        let preskipSamples = Int((Double(preskipAt48k) * sampleRate / Double(SoundcoreOgg.sampleRate)).rounded())
        let flushBytes = max(4_096, Int(Double(flushSamplesAt48k) * sampleRate / Double(SoundcoreOgg.sampleRate)) * 2)

        // ② 正式解码 → 边解边写。
        guard let sink = makeSink(sampleRate: sampleRate) else {
            transcodeLog.warning("transcode aborted: no writable container")
            return nil
        }
        let decoder = JXOpusDecoder(channels: 2)

        var pending = Data()
        var skipBytes = preskipSamples * 2
        var decodedSamples = 0
        var failed = 0

        for frame in frames {
            autoreleasepool {
                guard let block = decoder.decode(frame), block.count >= 4 else {
                    failed += 1
                    return
                }
                // 双声道解码器 + 单声道包 → 输出交织立体声，降混回单声道。
                var chunk = downmixToMono(block)
                if skipBytes > 0 {
                    if chunk.count <= skipBytes {
                        skipBytes -= chunk.count
                        return
                    }
                    chunk = chunk.subdata(in: skipBytes..<chunk.count)
                    skipBytes = 0
                }
                decodedSamples += chunk.count / 2
                pending.append(chunk)
                if pending.count >= flushBytes {
                    sink.write(pending)
                    pending.removeAll(keepingCapacity: true)
                }
            }
        }
        if !pending.isEmpty {
            sink.write(pending)
            pending.removeAll()
        }

        guard decodedSamples > 0 else {
            transcodeLog.warning("transcode failed: nothing decoded")
            sink.discard()
            return nil
        }
        // 解不出来的帧超过三成 → 数据本身就是坏的，别硬塞给用户听。
        if Double(failed) > Double(frames.count) * 0.3 {
            transcodeLog.warning("transcode rejected: \(failed, privacy: .public)/\(frames.count, privacy: .public) frames failed to decode")
            sink.discard()
            return nil
        }
        guard sink.finish(), let data = sink.readData(), data.count > 1024 else {
            transcodeLog.warning("transcode failed: sink finish/read failed")
            sink.discard()
            return nil
        }
        sink.discard()

        let duration = Double(decodedSamples) / sampleRate
        let rateLabel = Int(sampleRate) % 1000 == 0
            ? "\(Int(sampleRate) / 1000) kHz"
            : String(format: "%.1f kHz", sampleRate / 1000)
        transcodeLog.info(
            "transcoded \(frames.count, privacy: .public) frames → \(data.count, privacy: .public)B \(sink.fileExtension, privacy: .public) \(String(format: "%.1f", duration), privacy: .public)s @\(rateLabel, privacy: .public) spf=\(probed.samplesPerFrame, privacy: .public)"
        )
        return Output(
            data: data,
            fileExtension: sink.fileExtension,
            durationSeconds: duration,
            formatNote: sink.fileExtension == "m4a"
                ? "AAC mono \(rateLabel) (D3200 · Opus 转码，iOS 16 可播)"
                : "WAV mono \(rateLabel) (D3200 · Opus 解码，AAC 封装失败时兜底)"
        )
    }

    // MARK: - 帧切分 / 探测

    /// ★ 2026-10-28（8.3.6 反编译复核）：**不要 trim 尾部零**。豆的 Opus 是
    /// CBR 定长 160 B（64 kbps @48 kHz mono），包尾 `0x00` 是合法编码内容，
    /// 截掉 = 短包 → libopus `INVALID_PACKET` 或只解出部分帧 —— 这正是
    /// "杂音/解不出来"的直接原因之一。按 160 B 硬切，原样送解码器；
    /// 不足一帧的尾部是传输残留，直接丢弃（官方 FileWriterHelper 只 append 整帧）。
    private static func splitFrames(_ raw: Data) -> [Data] {
        let bytes = [UInt8](raw)
        var frames: [Data] = []
        frames.reserveCapacity(bytes.count / frameSize)
        var o = 0
        while o + frameSize <= bytes.count {
            frames.append(Data(bytes[o..<(o + frameSize)]))
            o += frameSize
        }
        return frames
    }

    /// 试解前若干帧，拿「每帧样本数」；采样率 = 每帧样本数 × 50（20 ms/帧）。
    ///
    /// ★ 解码器选型（同日复核）：`JXOpusDecoder` 按 **80 B × 声道数**切包
    /// （头文件原文："单声道包大小是80，双声道包大小是160"）。豆是 160 B
    /// 单声道 → 必须 `channels: 2` 才能整包喂进去；libopus 对"单声道包 +
    /// 双声道解码器"是宽容的（复制成双声道），解完降混回单声道。若其内部
    /// 采样率是 48 kHz 输出完全正确；若是 16 kHz，声音闷但时长/音高正确。
    private static func probe(_ frames: [Data]) -> (samplesPerFrame: Int, rate: Double)? {
        let decoder = JXOpusDecoder(channels: 2)
        let limit = min(frames.count, 24)
        for i in 0..<limit {
            if let block = decoder.decode(frames[i]), block.count >= 4 {
                let samples = block.count / 4 // 2 声道 × Int16
                let rate = Double(samples * framesPerSecond)
                // Opus 合法输出只有这几档，别把解坏的字节当成 7 kHz 之类。
                let known: [Double] = [8_000, 12_000, 16_000, 24_000, 48_000]
                guard known.contains(where: { abs($0 - rate) < 1 }) else {
                    transcodeLog.warning("probe: implausible rate \(rate, privacy: .public) Hz from \(samples, privacy: .public) samples/frame")
                    return nil
                }
                return (samples, rate)
            }
        }
        return nil
    }

    // MARK: - 降混

    /// 交织立体声 Int16 → 单声道 Int16（左右取平均，Int32 防溢出）。
    private static func downmixToMono(_ stereo: Data) -> Data {
        guard stereo.count >= 4 else { return Data() }
        var out = Data()
        out.reserveCapacity(stereo.count / 2)
        stereo.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let pairs = samples.count / 2
            var mono = [Int16](repeating: 0, count: pairs)
            for i in 0..<pairs {
                mono[i] = Int16((Int32(samples[i * 2]) + Int32(samples[i * 2 + 1])) / 2)
            }
            mono.withUnsafeBytes { out.append(contentsOf: $0) }
        }
        return out
    }

    private static func makeSink(sampleRate: Double) -> SoundcorePcmSink? {
        if let m4a = SoundcoreM4aSink(sampleRate: sampleRate) { return m4a }
        transcodeLog.warning("AAC m4a creation failed — falling back to WAV")
        return SoundcoreWavSink(sampleRate: sampleRate)
    }
}

// MARK: - AAC/m4a

/// `ExtAudioFile` 直接吃 16-bit 单声道 PCM，输出自带时长/采样率元数据
/// （这正是上一版 mp3 缺的东西：无 Xing 头 → 列表 0 s）。
private final class SoundcoreM4aSink: SoundcorePcmSink {
    let fileExtension = "m4a"
    private let url: URL
    private var file: ExtAudioFileRef?

    init?(sampleRate: Double) {
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &fileFormat) == noErr else {
            return nil
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "d3200-\(UUID().uuidString).m4a")
        var ref: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileMPEG4Type,
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &ref
        ) == noErr, let ref else { return nil }
        guard ExtAudioFileSetProperty(
            ref,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &client
        ) == noErr else {
            ExtAudioFileDispose(ref)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        self.url = url
        self.file = ref
    }

    func write(_ pcm: Data) -> Bool {
        guard let ref = file else { return false }
        guard pcm.count >= 2 else { return true }
        let frames = UInt32(pcm.count / 2)
        var ok = false
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let buffer = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(pcm.count),
                mData: UnsafeMutableRawPointer(mutating: base)
            )
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
            ok = ExtAudioFileWrite(ref, frames, &list) == noErr
        }
        return ok
    }

    func finish() -> Bool {
        guard let ref = file else { return false }
        let status = ExtAudioFileDispose(ref)
        file = nil
        return status == noErr
    }

    func readData() -> Data? {
        if file != nil { _ = finish() }
        return try? Data(contentsOf: url)
    }

    func discard() {
        if let ref = file { ExtAudioFileDispose(ref); file = nil }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - WAV 兜底

/// 44 字节 RIFF 头 + 裸 PCM，全系统可播。
private final class SoundcoreWavSink: SoundcorePcmSink {
    let fileExtension = "wav"
    private let url: URL
    private let sampleRate: Double
    private var handle: FileHandle?
    private var dataBytes = 0

    init?(sampleRate: Double) {
        self.sampleRate = sampleRate
        let url = URL(fileURLWithPath: NSTemporaryDirectory() + "d3200-\(UUID().uuidString).wav")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: url.path) else { return nil }
        handle.write(Data(repeating: 0, count: 44))
        self.url = url
        self.handle = handle
    }

    func write(_ pcm: Data) -> Bool {
        guard let handle else { return false }
        handle.write(pcm)
        dataBytes += pcm.count
        return true
    }

    func finish() -> Bool {
        guard let handle else { return false }
        let rate = Int(sampleRate)
        var header = Data("RIFF".utf8)
        header.append(le32(36 + dataBytes))
        header.append(Data("WAVEfmt ".utf8))
        header.append(le32(16))            // fmt chunk size
        header.append(le16(1))             // format = PCM
        header.append(le16(1))             // channels
        header.append(le32(rate))
        header.append(le32(rate * 2))      // byte rate = rate × blockAlign
        header.append(le16(2))             // block align
        header.append(le16(16))            // bits per sample
        header.append(Data("data".utf8))
        header.append(le32(dataBytes))
        do {
            try handle.seek(toOffset: 0)
            handle.write(header)
            try handle.close()
        } catch {
            return false
        }
        self.handle = nil
        return true
    }

    func readData() -> Data? {
        if handle != nil { _ = finish() }
        return try? Data(contentsOf: url)
    }

    func discard() {
        if let handle { try? handle.close(); self.handle = nil }
        try? FileManager.default.removeItem(at: url)
    }

    private func le16(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    private func le32(_ v: Int) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
}
