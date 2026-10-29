import Foundation
import PlaudBleSDK

// MARK: - D3200 实时字幕专用流式解码器
//
// ★ 2026-10-28「实时转录没字幕」根因（真机 diag 日志 XLATE 实锤）：
//
//   live 链路把 500 ms 的 160 B 帧序列包成 Ogg 再交 AVAssetReader 解码——
//   iOS 解不了我们自封装的 Ogg/Opus 组合，**每个 batch 都抛
//   「这项操作无法完成」**；兜底的 `Mp3Convert.convertOgg` 又是 PLAUD
//   16 kHz / 80 B 帧口径，喂 48 kHz / 160 B 解出来的 PCM 又少又错
//   （21 s 音频只解出 2.9 s，阿里云端一个字都出不来）。
//
//   而文件播放链路（`SoundcoreTranscoder`）真机已验证可用：JXOpusDecoder
//   按 80 B × 声道数切包 → `channels: 2` 整帧吃下 160 B 单声道 → 降混。
//   这里把同一条链做成流式（喂帧、出 PCM），并补齐 live 需要的两步：
//
//   1. OpusHead preskip（3840 @48 kHz，整段会话开头只丢一次）；
//   2. 48 kHz → 16 kHz 重采样（阿里云实时引擎 / 端上识别都只吃 16 kHz）。
//
// 线程约定：同一实例必须串行使用（调用方按 batch 顺序逐个解码）。
final class SoundcoreLiveDecoder {

    private let decoder = JXOpusDecoder(channels: 2)
    /// 还需丢弃的 preskip 样本数（解码器原始采样率的单声道样本）；-1 = 尚未探测。
    private var preskipRemaining = -1
    /// 探测到的解码器输出采样率；0 = 未探测。
    private var rate = 0

    /// 喂一段整 160 B 帧（1 个或多个 packetBytes 对齐的 batch），返回
    /// 16 kHz mono 16-bit LE PCM。解不出的帧按坏帧跳过；坏帧超过三成时
    /// 返回空（避免把垃圾音频喂给识别引擎）。
    func decode(_ raw: Data) -> Data {
        let bytes = [UInt8](raw)
        let frameSize = SoundcoreOgg.frameSize
        guard bytes.count >= frameSize else { return Data() }

        var mono: [Int16] = []
        mono.reserveCapacity(bytes.count / frameSize * 960)
        var decodedFrames = 0
        var totalFrames = 0
        var o = 0
        while o + frameSize <= bytes.count {
            autoreleasepool {
                totalFrames += 1
                if let block = decoder.decode(Data(bytes[o..<(o + frameSize)])), block.count >= 4 {
                    block.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                        let s = p.bindMemory(to: Int16.self)
                        let pairs = s.count / 2
                        for i in 0..<pairs {
                            // 交织立体声 → 单声道（左右平均，Int32 防溢出）。
                            mono.append(Int16((Int32(s[i * 2]) + Int32(s[i * 2 + 1])) / 2))
                        }
                    }
                    decodedFrames += 1
                }
                o += frameSize
            }
        }
        guard decodedFrames > 0, Double(totalFrames - decodedFrames) <= Double(totalFrames) * 0.3 else {
            return Data()
        }

        // 探测输出采样率（仅一次）：每帧样本数 × 50（帧长恒为 20 ms）= Hz。
        // 只认 Opus 合法输出档位，解坏的字节不计入。
        if rate == 0 {
            let spf = mono.count / max(1, decodedFrames)
            let probed = spf * 50
            let known: [Int] = [8_000, 12_000, 16_000, 24_000, 48_000]
            guard known.contains(where: { abs($0 - probed) < 1 }) else { return Data() }
            rate = probed
            preskipRemaining = Int((Double(SoundcoreOgg.preskip)
                * Double(rate) / Double(SoundcoreOgg.sampleRate)).rounded())
        }

        // preskip：整段会话开头丢一次（等比换算到实际输出率）。
        var samples = mono
        if preskipRemaining > 0 {
            if samples.count <= preskipRemaining {
                preskipRemaining -= samples.count
                return Data()
            }
            samples.removeFirst(preskipRemaining)
            preskipRemaining = 0
        }

        if rate == 16_000 {
            return samples.withUnsafeBytes { Data($0) }
        }
        // 整数倍降采样到 16 kHz：N 点取平均做简易抗混叠（48 kHz → 3 点）。
        guard rate % 16_000 == 0, rate > 16_000 else { return Data() }
        let factor = rate / 16_000
        var out: [Int16] = []
        out.reserveCapacity(samples.count / factor)
        var i = 0
        while i + factor <= samples.count {
            var acc = 0
            for k in 0..<factor { acc += Int(samples[i + k]) }
            out.append(Int16(acc / factor))
            i += factor
        }
        return out.withUnsafeBytes { Data($0) }
    }
}
