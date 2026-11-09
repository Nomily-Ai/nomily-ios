import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "voiceprint")

// MARK: - 声纹档案
//
// 注册一次，之后每条录音转写完自动问一句"这些人里哪个是我"。
//
// 只存**一个**声纹（用户本人）。为什么不支持多个人：这个功能的目的是把"我"
// 从"说话人 1/2/3"里挑出来，其他人的身份靠手动改名——一个一次性的
// 多人声纹库，采集成本远高于它能省的事。
struct VoiceprintProfile: Codable, Equatable {
    /// L2 归一化的 26 维向量（见 `VoiceprintEngine.vector`）。
    var vector: [Float]
    var createdAt: Date
    /// `watch` / `phone` —— 只用于界面说明"这条声纹是在哪台设备上录的"。
    var source: String
    /// 参与计算的有声时长（秒），让用户知道样本够不够。
    var seconds: Double
}

@MainActor
final class VoiceprintService: ObservableObject {

    static let shared = VoiceprintService()

    /// 判定为"本人"的余弦下限。
    ///
    /// **偏保守是故意的**：漏判只是少标一个"我"，用户改一下名字就行；误判会把
    /// 同事说的话记到用户头上，而用户通常是事后才看摘要——那时已经信了。
    static let threshold: Float = 0.86
    /// 第一名与第二名至少要拉开这么多，否则算"分不清"，不标。
    static let margin: Float = 0.03

    @Published private(set) var profile: VoiceprintProfile?

    private init() {
        profile = Self.loadFromDisk()
    }

    // MARK: 存取

    nonisolated private static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Voiceprint", isDirectory: true)
    }

    nonisolated private static var profileURL: URL {
        directory.appendingPathComponent("profile.json")
    }

    /// 收上来的原始样本（手表录的那 12 秒）。留着是为了"重新训练"时不必再录。
    nonisolated static func sampleURL(name: String) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    nonisolated static func loadFromDisk() -> VoiceprintProfile? {
        guard let data = try? Data(contentsOf: profileURL),
              let decoded = try? JSONDecoder().decode(VoiceprintProfile.self, from: data),
              !decoded.vector.isEmpty else { return nil }
        return decoded
    }

    var hasProfile: Bool { profile != nil }

    // MARK: 注册

    /// 用一段录音注册（或覆盖）声纹。
    ///
    /// 同步执行：12 秒的样本，MFCC 计算是毫秒级的；放到后台反而要为 `@MainActor`
    /// 的调用方绕一圈 `await`。
    func enroll(from url: URL, source: String) throws {
        let samples = try VoiceprintEngine.pcm(from: url)
        let seconds = Double(samples.count) / VoiceprintEngine.sampleRate
        guard seconds >= VoiceprintEngine.minimumSeconds else { throw VoiceprintError.tooShort }
        let frames = VoiceprintEngine.mfccFrames(samples)
        guard let vector = VoiceprintEngine.vector(from: frames) else { throw VoiceprintError.noSpeech }

        let profile = VoiceprintProfile(
            vector: vector,
            createdAt: Date(),
            source: source,
            seconds: Double(frames.count) * Double(VoiceprintEngine.hopSize) / VoiceprintEngine.sampleRate
        )
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profile)
        try data.write(to: Self.profileURL, options: .atomic)
        self.profile = profile
        Self.pruneSamples(keeping: url.lastPathComponent)
        log.info("voiceprint enrolled source=\(source, privacy: .public) voiced=\(profile.seconds, format: .fixed(precision: 1))s")
    }

    /// 只留最新那一份原始样本。
    ///
    /// 每注册一次都会落一个新 `sample-<时间戳>.m4a`；旧样本没有任何地方再读，
    /// 留着只会让"Documents/Voiceprint"越堆越大——而这个目录会随 iCloud 备份走。
    nonisolated private static func pruneSamples(keeping name: String) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.lastPathComponent != name
            && file.lastPathComponent.hasPrefix("sample-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func forget() {
        try? FileManager.default.removeItem(at: Self.profileURL)
        profile = nil
        log.info("voiceprint removed")
    }

    // MARK: 识别

    /// 转写完成后调用：把"最像本人"的那个说话人改成用户的名字。
    ///
    /// 什么时候**不**做：
    /// · 没有声纹；
    /// · 转写没有说话人标签（一人独白/纯文本），改了也没地方显示；
    /// · 已经有人被标成这个名字（用户自己改过，尊重他的选择）；
    /// · 所有人都低于阈值，或前两名分不开。
    ///
    /// - Returns: 被标注的原始说话人 id（没有改任何东西时为 nil）。
    @discardableResult
    func identify(clip: String, userName: String?) async -> String? {
        guard let profile else { return nil }
        guard let document = TranscriptDocument.load(for: clip), !document.segments.isEmpty else { return nil }
        guard document.segments.contains(where: { !($0.speaker ?? "").isEmpty }) else { return nil }

        let label = (userName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? L10n.Voiceprint.selfLabel

        let existing = SpeakerNameStore.namesOnDisk(for: clip)
        guard !existing.values.contains(label) else { return nil }

        // 音频可能是 Ogg-Opus（iOS 17 前读不了），先转一份能读的。
        let original = StorageLocations.decryptedDir.appendingPathComponent(clip)
        var temporary: URL?
        let readable: URL
        if ["opus", "ogg"].contains(original.pathExtension.lowercased()) {
            guard let converted = try? await AudioExporter.exportAsM4A(
                source: original,
                suggestedName: (clip as NSString).deletingPathExtension
            ) else {
                log.info("voiceprint skipped: cannot decode \(clip, privacy: .public)")
                return nil
            }
            temporary = converted
            readable = converted
        } else {
            readable = original
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        guard let vectors = try? VoiceprintEngine.vectorsBySpeaker(url: readable, segments: document.segments),
              !vectors.isEmpty else { return nil }

        let scored = vectors
            .map { (speaker: $0.key, score: VoiceprintEngine.cosine($0.value, profile.vector)) }
            .sorted { $0.score > $1.score }
        guard let best = scored.first, best.score >= Self.threshold else {
            log.info("voiceprint: no match in \(clip, privacy: .public) best=\(scored.first?.score ?? 0, format: .fixed(precision: 3))")
            return nil
        }
        if scored.count > 1, best.score - scored[1].score < Self.margin {
            log.info("voiceprint: ambiguous in \(clip, privacy: .public) gap too small")
            return nil
        }

        SpeakerNameStore.shared.rename(label, speaker: best.speaker, clip: clip)
        log.info("voiceprint matched \(best.speaker, privacy: .public) in \(clip, privacy: .public) score=\(best.score, format: .fixed(precision: 3))")
        return best.speaker
    }

    /// 当前声纹与一段音频的相似度（调试/自检用，界面不上）。
    func similarity(to url: URL) -> Float? {
        guard let profile, let vector = try? VoiceprintEngine.vector(from: url) else { return nil }
        return VoiceprintEngine.cosine(vector, profile.vector)
    }
}
