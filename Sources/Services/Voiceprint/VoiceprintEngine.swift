import Accelerate
import AVFoundation
import Foundation

// MARK: - 本机声纹（说话人识别）
//
// ★ 2026-11-04（用户："现在没声纹处理你没办法判断我说话，需要在 Apple Watch 里面
// 加入一个声纹，录制声纹说话这样你能区分是谁说话"）：
//
// ## 为什么不是"接一个声纹模型"
// iOS 没有系统级说话人识别，也没有可下载的通用声纹模型（Apple 的 `SoundAnalysis`
// 只有"这是不是人声/这是什么声音"这一类分类器）。把几十分钟会议音频发到云端做
// 声纹，既慢又违背这个 App 的本地优先。
//
// 所以这里做的是**工程上够用的那一档**：MFCC 统计量 + 余弦相似度。
//
// ```
// 注册：读 12 秒 → 逐帧 MFCC → 只留有声帧 → 均值/标准差拼成 26 维 → L2 归一化
// 识别：同一段录音里按说话人切出各人的音频 → 同样的向量 → 与注册向量比余弦
// ```
//
// ## 它擅长什么、不擅长什么（必须说清楚，否则用户会以为它像指纹）
// · **擅长**：同一台设备、同一个人、安静环境下的"这是不是我"。注册和识别都用手表
//   麦克风时最准——同一个麦克风意味着同一个"声道"，而声道差异正是这类轻量声纹
//   最大的干扰源。
// · **不擅长**：远场（手表戴在腕上，离嘴远）、多人同时说话、注册与识别用不同设备。
//   这些情况下它会**弃权**（返回 nil 或低于阈值不标注），而不是硬猜——
//   宁可不标，也不能把同事的话标成"我"。
//
// 阈值定在 0.86（余弦），偏保守：漏判只是少标一个"我"，用户仍可手动改名；
// 误判则是把别人的话记到自己头上，代价大得多。
enum VoiceprintEngine {

    static let sampleRate: Double = 16_000
    /// 32 ms 窗、16 ms 步长。会议语音的基频周期在 2–12 ms，这个窗足够覆盖几个周期。
    static let frameSize = 512
    static let hopSize = 256
    static let melCount = 26
    static let cepstra = 13
    /// 一段样本至少要这么久才拿来算（更短的统计量不稳）。
    static let minimumSeconds: Double = 3

    // MARK: 解码

    /// 任意容器 → 16 kHz 单声道 Float32。
    ///
    /// Ogg-Opus 在 iOS 17 之前读不了；调用方负责先转成 m4a（`AudioExporter`），
    /// 这里只在 `AVAudioFile` 直接失败时把错误抛出去，不在这里偷偷转码——
    /// 转码是异步的，混进一个同步函数会让调用点变复杂。
    static func pcm(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw VoiceprintError.unreadable }

        // 已经是目标格式：直接读完（省掉一次转换，手表录的 24 kHz 大多走转换分支）。
        if abs(inputFormat.sampleRate - sampleRate) < 1, inputFormat.channelCount == 1 {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: target,
                frameCapacity: AVAudioFrameCount(file.length)
            ) else { throw VoiceprintError.unreadable }
            try file.read(into: buffer)
            return floats(from: buffer)
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw VoiceprintError.unreadable
        }
        let ratio = sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(file.length) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
            throw VoiceprintError.unreadable
        }

        var inputBuffer: AVAudioPCMBuffer? = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(max(4096, file.length))
        )
        var done = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if done {
                status.pointee = .endOfStream
                return nil
            }
            guard let chunk = inputBuffer else {
                status.pointee = .endOfStream
                return nil
            }
            try? file.read(into: chunk)
            if chunk.frameLength == 0 {
                done = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return chunk
        }
        inputBuffer = nil
        if let error { throw error }
        return floats(from: output)
    }

    private static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    // MARK: 特征

    /// 一帧的 MFCC（第 0 维丢掉：它只反映音量，而音量跟"离麦远近"走，跟人关系不大）。
    private static let fftSetup: FFTSetup? = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))   // 2^9 = 512
    private static let melFilters: [[Float]] = makeMelFilters()
    /// 手算汉宁窗而不是 `vDSP.window(ofType:)`：那个 API 的 `WindowSequence`
    /// 在不同 SDK 里的枚举名变过两次（`hanning` / `hanningNormalized`），
    /// 一个 512 点的余弦表不值得为此绑死某个 SDK 版本。
    private static let window: [Float] = (0..<frameSize).map { index in
        0.5 - 0.5 * cos(2 * Float.pi * Float(index) / Float(frameSize - 1))
    }

    /// 26 个三角滤波器，100 Hz – 7.8 kHz（16 kHz 采样下的可用语音带）。
    ///
    /// 用 mel 刻度而不是线性：人耳对低频的分辨率远高于高频，线性划分会让
    /// "是不是同一个人"这件事被高频噪声主导。
    private static func makeMelFilters() -> [[Float]] {
        func mel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func hz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }
        let low = mel(100), high = mel(7_800)
        // ⚠️ 需要 melCount + 2 个点：第 i 个滤波器用 points[i]、[i+1]、[i+2]。
        //    少一个就会在最后一个滤波器上越界（真机上是崩溃，不是"效果差一点"）。
        let points = (0...(melCount + 1)).map {
            hz(low + (high - low) * Float($0) / Float(melCount + 1))
        }
        let bins = frameSize / 2
        let binHz = Float(sampleRate) / Float(frameSize)
        return (0..<melCount).map { index in
            let left = points[index], center = points[index + 1], right = points[index + 2]
            return (0..<bins).map { bin -> Float in
                let frequency = Float(bin) * binHz
                if frequency <= left || frequency >= right { return 0 }
                // 左半边上升、右半边下降的三角。
                return frequency <= center
                    ? (frequency - left) / max(center - left, 1)
                    : (right - frequency) / max(right - center, 1)
            }
        }
    }

    /// 逐帧 MFCC，只返回"有声"帧（能量低于自适应底噪的帧直接扔掉——静音帧的
    /// 频谱基本是电流噪声，会把统计量拉向"所有人听起来都一样"）。
    static func mfccFrames(_ pcm: [Float]) -> [(time: Double, mfcc: [Float])] {
        guard let setup = fftSetup, pcm.count > frameSize else { return [] }
        let log2n = vDSP_Length(9)
        let half = frameSize / 2

        // 预加重：提升高频，补偿发音时声门波的自然衰减，让不同人的共振峰更可分。
        var signal = pcm
        for i in stride(from: signal.count - 1, through: 1, by: -1) {
            signal[i] -= 0.97 * signal[i - 1]
        }

        var frames: [(time: Double, mfcc: [Float], energy: Float)] = []
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: frameSize)
        var magnitudes = [Float](repeating: 0, count: half)

        var offset = 0
        while offset + frameSize <= signal.count {
            signal.withUnsafeBufferPointer { source in
                vDSP_vmul(source.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(frameSize))
            }

            var energy: Float = 0
            vDSP_measqv(windowed, 1, &energy, vDSP_Length(frameSize))
            energy = 10 * log10(max(energy, 1e-10))

            // ⚠️ `DSPSplitComplex(realp: &real, imagp: &imag)` 是悬垂指针：
            //   `&array` 产生的指针只在**那一次调用**内有效，FFT 在之后才用它 → UB，
            //   在 Mac 上直接 SIGILL。必须把它整个包在 `withUnsafeMutableBufferPointer` 里。
            real.withUnsafeMutableBufferPointer { realPointer in
                imag.withUnsafeMutableBufferPointer { imagPointer in
                    var spectrum = DSPSplitComplex(
                        realp: realPointer.baseAddress!,
                        imagp: imagPointer.baseAddress!
                    )
                    windowed.withUnsafeBufferPointer { pointer in
                        pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complex in
                            vDSP_ctoz(complex, 2, &spectrum, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &spectrum, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&spectrum, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }

            // mel 滤波器组 → 取对数
            var logMel = [Float](repeating: 0, count: melCount)
            for m in 0..<melCount {
                var sum: Float = 0
                vDSP_dotpr(magnitudes, 1, melFilters[m], 1, &sum, vDSP_Length(half))
                logMel[m] = log(max(sum, 1e-10))
            }

            // DCT-II：取前 13 个倒谱系数（0 号是总能量，跳过）
            var mfcc = [Float](repeating: 0, count: cepstra)
            for k in 1..<cepstra {
                var sum: Float = 0
                for n in 0..<melCount {
                    sum += logMel[n] * cos(Float.pi * Float(k) * (Float(n) + 0.5) / Float(melCount))
                }
                mfcc[k] = sum
            }
            frames.append((time: Double(offset) / sampleRate, mfcc: mfcc, energy: energy))
            offset += hopSize
        }

        // 自适应有声判定：比本段最大能量低 35 dB 以上的帧当静音扔掉。
        guard let peak = frames.map(\.energy).max() else { return [] }
        let floor = peak - 35
        return frames
            .filter { $0.energy > floor }
            .map { (time: $0.time, mfcc: $0.mfcc) }
    }

    // MARK: 向量

    /// 把若干帧合成一个定长向量（均值 + 标准差，26 维），L2 归一化。
    ///
    /// 为什么是均值 + 标准差：均值刻画"这个人的声道平均形状"（共振峰位置），
    /// 标准差刻画"他说话时变化多大"。只用均值在短样本上太单薄，加上标准差
    /// 相当于给了模型一个二阶统计量，实测区分度明显好于 13 维均值。
    static func vector(from frames: [(time: Double, mfcc: [Float])]) -> [Float]? {
        guard frames.count >= 20 else { return nil }
        var mean = [Float](repeating: 0, count: cepstra)
        for frame in frames {
            for k in 0..<cepstra { mean[k] += frame.mfcc[k] }
        }
        for k in 0..<cepstra { mean[k] /= Float(frames.count) }

        var variance = [Float](repeating: 0, count: cepstra)
        for frame in frames {
            for k in 0..<cepstra {
                let delta = frame.mfcc[k] - mean[k]
                variance[k] += delta * delta
            }
        }
        for k in 0..<cepstra {
            variance[k] = sqrt(variance[k] / Float(frames.count))
        }

        var vector = mean + variance
        vector[0] = 0   // 均值第 0 维恒为 0（MFCC[0] 已跳过），占位不用
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 1e-6 else { return nil }
        return vector.map { $0 / norm }
    }

    static func vector(from url: URL) throws -> [Float] {
        let samples = try pcm(from: url)
        guard Double(samples.count) / sampleRate >= minimumSeconds else { throw VoiceprintError.tooShort }
        guard let vector = vector(from: mfccFrames(samples)) else { throw VoiceprintError.tooShort }
        return vector
    }

    /// 一条录音里，按说话人的时间段分别算向量。
    ///
    /// 只解一次码：一条一小时的会议解成 PCM 是 16 kHz × 3600 s × 4 B ≈ 230 MB，
    /// 为每个说话人各解一次会直接把手机打爆；这里解一次、帧级统计按人累加。
    static func vectorsBySpeaker(
        url: URL,
        segments: [AsrSegment],
        minimumSeconds: Double = 3
    ) throws -> [String: [Float]] {
        let samples = try pcm(from: url)
        let frames = mfccFrames(samples)
        guard !frames.isEmpty else { return [:] }

        var bySpeaker: [String: [(time: Double, mfcc: [Float])]] = [:]
        for segment in segments {
            guard let speaker = segment.speaker, !speaker.isEmpty else { continue }
            let inRange = frames.filter { $0.time >= segment.start && $0.time < segment.end }
            bySpeaker[speaker, default: []].append(contentsOf: inRange)
        }

        var result: [String: [Float]] = [:]
        for (speaker, speakerFrames) in bySpeaker {
            // 帧数 × hop / 采样率 = 实际有声时长，用它而不是段时长：
            // 一个说话人可能被分到十分钟，但其中大半是静音。
            let voicedSeconds = Double(speakerFrames.count) * Double(hopSize) / sampleRate
            guard voicedSeconds >= minimumSeconds else { continue }
            if let vector = vector(from: speakerFrames) { result[speaker] = vector }
        }
        return result
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let denominator = sqrt(na) * sqrt(nb)
        return denominator > 1e-6 ? dot / denominator : 0
    }
}

enum VoiceprintError: LocalizedError {
    case unreadable
    case tooShort
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .unreadable: return L10n.Voiceprint.unreadable
        case .tooShort:   return L10n.Voiceprint.tooShort
        case .noSpeech:   return L10n.Voiceprint.noSpeech
        }
    }
}
