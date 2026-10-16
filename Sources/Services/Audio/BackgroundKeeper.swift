import AVFoundation
import Foundation
import os.log
import UIKit

private let log = Logger(subsystem: "com.nomily.app.ios", category: "background")

/// 让 App 在**有活在飞**的时候不被系统挂起。
///
/// 起这个类的原因：转录和摘要都是几十秒到十几分钟的活，用户一旦切走
/// （看一眼微信、锁个屏），App 进 `.suspended`，URLSession 的请求被掐断，
/// 回来就是一句失败 —— 这就是"转录好几次都失败"的一大半。
///
/// 两层机制叠着用：
///
/// 1. `UIApplication.beginBackgroundTask` —— 只能换来约 30 秒的宽限。
///    不花钱、不需要任何权限、任何时候都是对的。它是永远开着的那一层。
/// 2. 一个**循环播放的静音** `AVAudioPlayer`，跑在 `.playback` 会话上。
///    配合 Info.plist 里已经声明好的 `audio` 后台模式，进程就能一直活着。
///    这套把戏 `LiveModel` 录音时本来就在用（那里 1544 行起），这里只是
///    把它**提到一个地方管**——否则两个独立的静音播放器会抢同一个
///    `AVAudioSession`，谁先 `setActive(false)` 谁就把对方掐了。
///
/// 用**令牌**计数而不是裸计数：录音那条路的生命周期是"正在录 && 在后台"，
/// 转录那条路是"活还没干完"，两者会重叠，各自得能单独释放而不误伤对方。
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    /// 谁在占着。加新场景就往这里添一个 case，别新开一套机制。
    enum Token: String, CaseIterable {
        /// 实时录音 —— 由 `LiveModel` 在"录音中 && 切到后台"时持有。
        case recording
        /// 批量转录（ASR）。
        case transcription
        /// 摘要 / 翻译等 LLM 长任务。
        case summary
        /// 导出音频（大文件的复制 / 重编码）。
        ///
        /// ★ 2026-10-15 六改：用户的原话是"导出音频对于大文件音频需要等待很久
        /// 这个需要挂在后台"。导出和转录是**同一类**问题（干到一半被挂起），
        /// 所以共用这一套，不另起一份。
        case export
    }

    /// 镜像 `config.backgroundKeepAliveEnabled`。关掉时只保留那 ~30 秒的
    /// `beginBackgroundTask` 宽限 —— 短录音仍然能在后台跑完，长的就会断。
    /// 之所以给开关：第 2 层是"用静音音频骗后台"，不想被这个糊弄的用户
    /// 应该有权关掉它。
    var audioKeepAliveEnabled = true {
        didSet {
            guard audioKeepAliveEnabled != oldValue else { return }
            if audioKeepAliveEnabled {
                if !active.isEmpty { startAudio() }
            } else {
                stopAudio()
            }
        }
    }

    private(set) var active: Set<Token> = []

    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?

    private init() {}

    // MARK: - 令牌

    func isHeld(_ token: Token) -> Bool { active.contains(token) }

    func acquire(_ token: Token) {
        guard active.insert(token).inserted else { return }
        log.info("acquire \(token.rawValue, privacy: .public) → \(self.active.count) held")
        beginAssertion()
        if audioKeepAliveEnabled { startAudio() }
    }

    func release(_ token: Token) {
        guard active.remove(token) != nil else { return }
        log.info("release \(token.rawValue, privacy: .public) → \(self.active.count) held")
        guard active.isEmpty else { return }
        stopAudio()
        endAssertion()
    }

    /// 退出前给个干净的收尾（也方便自检脚本对账）。
    func releaseAll() {
        active.removeAll()
        stopAudio()
        endAssertion()
    }

    // MARK: - 第 1 层：后台任务断言

    private func beginAssertion() {
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "com.nomily.work") { [weak self] in
            // 走到这里说明 30 秒宽限用完了。有静音音频顶着时不该发生；
            // 真发生了（用户把音频保活关了）就必须立刻交还令牌，否则
            // 系统会直接把进程杀掉（而 kill 是没有任何日志的）。
            Task { @MainActor [weak self] in
                guard let self else { return }
                log.warning("background assertion expired with \(self.active.count) token(s) held")
                self.endAssertion()
            }
        }
        log.info("background assertion \(self.taskID.rawValue) started")
    }

    private func endAssertion() {
        guard taskID != .invalid else { return }
        let id = taskID
        taskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
        log.info("background assertion \(id.rawValue) ended")
    }

    // MARK: - 第 2 层：静音音频保活

    private func startAudio() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // `.mixWithOthers`：用户自己的音乐/播客不该被我们掐掉。
            // 我们放的是纯静音，混进去也听不见。
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            let p = try AVAudioPlayer(data: Self.silentWavData(), fileTypeHint: AVFileType.wav.rawValue)
            p.numberOfLoops = -1
            p.volume = 0
            p.play()
            player = p
            observeInterruptions()
            log.info("silent audio started")
        } catch {
            // 拿不到会话不代表活干不了 —— 还有 30 秒的断言兜着，短活照样跑完。
            log.warning("silent audio failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopAudio() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log.info("silent audio stopped")
    }

    /// 来个电话/闹钟会把我们的静音播放器打断，而打断结束后它**不会自己回来**。
    /// 不补这一手，用户接完电话回来转录就已经断在半路了。
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.ended.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.active.isEmpty, self.player == nil else { return }
                self.startAudio()
            }
        }
    }

    /// 1 秒静音：8 kHz 单声道 16 bit PCM WAV（16 044 字节）。
    /// 小到可以常驻内存，循环播放就永远不停。
    /// （与 `LiveModel` 原先那份逐字节相同，口径保持一致。）
    private static func silentWavData() -> Data {
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = sampleRate
        let dataSize = numSamples * 2
        var d = Data()
        func u32le(_ v: UInt32) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func u16le(_ v: UInt16) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        d.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        u32le(36 + dataSize)
        d.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        d.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        u32le(16)
        u16le(1)                    // PCM
        u16le(1)                    // mono
        u32le(sampleRate)
        u32le(sampleRate * 2)       // byte rate
        u16le(2)                    // block align
        u16le(16)                   // bits per sample
        d.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        u32le(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
