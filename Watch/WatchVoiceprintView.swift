import AVFoundation
import SwiftUI

/// 手表端：录一段自己的声音，传回 iPhone 注册声纹。
///
/// ★ 2026-11-04（用户："需要在 Apple Watch 里面加入一个声纹，录制声纹说话这样你能
/// 区分是谁说话"）。
///
/// ## 为什么在手表上录，却不在手表上算
/// 手表没有余量跑 MFCC + 逐帧 FFT（一条一分钟的样本就是几万帧），而这件事对实时性
/// 没有任何要求——录完传回手机，手机在后台算完存起来就行。
///
/// ## 为什么用和录音**完全一样**的参数
/// 声纹的全部依据是"这个人的声道特征"。采样率、码率、麦克风换了任何一个，特征都会
/// 系统性地漂一点——注册样本和真实录音之间的这种漂移，正是轻量声纹最容易失败的地方。
/// 所以这里的 `AVAudioRecorder` 参数**抄的是 `WatchRecorderModel.makeRecorder`**：
/// 24 kHz / 单声道 / 48 kbps AAC。两边必须同时改，否则识别率会无缘无故掉下去。
/// 手表端声纹注册的共享状态（页级单例）。
///
/// 为什么不放在 View 的 `@State`：手机回执到达时声纹页可能根本没开着
/// （用户录完就退出了），`@State` 随页面销毁；回执需要落到一个**常驻**的地方，
/// 下次进页面才显示得出来。`NomilyWatchApp` 把 `WatchLink.onVoiceprintResult`
/// 接到 `apply` 上。
///
/// `pending` 与 `lastResultID` 落 UserDefaults：手表 App 被系统杀掉再打开，
/// 不应该从"已发送"退回"开始录音"——样本其实已经在路上/已被注册。
@MainActor
final class WatchVoiceprintEnrollState: ObservableObject {
    static let shared = WatchVoiceprintEnrollState()

    /// 样本已发出、还没收到手机回执。
    @Published private(set) var pending: Bool {
        didSet { UserDefaults.standard.set(pending, forKey: "voiceprint.pending.v1") }
    }
    /// 最近一次已消费的回执 ID（注册发起时的时间戳），去重用——上下文是
    /// "最新值"语义，同一条回执会随每次心跳重复送达。
    @Published private(set) var lastResultID: Int {
        didSet { UserDefaults.standard.set(lastResultID, forKey: "voiceprint.result_id.v1") }
    }
    /// nil = 还没有回执；true = 注册成功；false = 注册失败。
    @Published private(set) var resultOK: Bool?

    private init() {
        pending = UserDefaults.standard.bool(forKey: "voiceprint.pending.v1")
        lastResultID = UserDefaults.standard.integer(forKey: "voiceprint.result_id.v1")
    }

    /// 手机回执到达。ID 不比已消费的新（重放/乱序）就丢掉。
    func apply(resultID id: Int, ok: Bool) {
        guard id > lastResultID else { return }
        lastResultID = id
        resultOK = ok
        pending = false
    }

    /// 手表开始录新样本时调用：清掉上一轮的结果显示。
    func markRecording() {
        resultOK = nil
        status = nil
    }

    /// 「重新录制」小按钮：清空回执与在途状态，回到"开始录音"。
    func reset() {
        pending = false
        resultOK = nil
        status = nil
    }

    /// 样本已发出。
    func markSent() {
        pending = true
    }

    /// 页面上的临时提示行（"已发送…"），不属于状态机本体，放这里只为单例统一管。
    @Published var status: String?
}

struct WatchVoiceprintView: View {

    @EnvironmentObject private var link: WatchLink
    @ObservedObject private var enroll = WatchVoiceprintEnrollState.shared

    @State private var recorder: AVAudioRecorder?
    @State private var isRecording = false
    @State private var elapsed: Double = 0
    @State private var errorText: String?

    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    /// 超过这个长度自动停——手表屏幕小，用户盯着读一段就够了。
    private static let maximumSeconds: Double = 20
    /// 手机端至少要 3 秒才肯拿去算特征（`VoiceprintEngine.minimumSeconds` 的镜像）。
    /// 手表 target 里没有声纹引擎（它跑在手机上），所以这里单独写一份——
    /// 两边都只是"至少三秒"这一个数，改的时候一起改。
    private static let minimumSeconds: Double = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.Voiceprint.enrollHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(L10n.Voiceprint.enrollScript)
                    .font(.system(size: 15, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)

                actionArea

                if isRecording {
                    Text(String(format: "%.1fs", elapsed))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                if let errorText {
                    Text(errorText)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(L10n.Voiceprint.title)
        // ★ 2026-11-06（用户："重新录制了声纹，但他下面还有声纹"）：进页面先清
        // 上一轮的提示残留——旧文案挂在页面底部，读起来像"还有一条旧声纹"。
        .onAppear {
            enroll.status = nil
            errorText = nil
        }
        .onReceive(timer) { _ in
            guard isRecording, let recorder else { return }
            elapsed = recorder.currentTime
            if elapsed >= Self.maximumSeconds { finish() }
        }
        .onDisappear { if isRecording { finish() } }
    }

    // MARK: 按钮区（状态机）

    /// ★ 2026-11-06（用户："录制完毕……不要展示开始录制的按钮"）：
    ///
    /// | 状态 | 显示 |
    /// |---|---|
    /// | 录制中 | 红色「完成」（唯一能提前结束的方式） |
    /// | 已发送、等回执 | **大的开始按钮消失**，绿色"已发送"+ 小号「重新录制」 |
    /// | 手机回执成功 | 绿色"声纹已更新" + 小号「重新录制」 |
    /// | 手机回执失败 | 橙色失败提示 + 大的开始按钮（直接重录） |
    /// | 太短/没声（未发出） | 错误提示 + 大的开始按钮 |
    /// | 从未录过 | 大的开始按钮 |
    ///
    /// 关键语义：**样本已发出之后，大的"开始录音"不再回来**——它只会让人以为
    /// 还要再录一条。想重录走小号「重新录制」（显式动作，清状态重新开始）。
    @ViewBuilder
    private var actionArea: some View {
        if isRecording {
            Button {
                finish()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.circle.fill")
                    Text(L10n.Voiceprint.enrollStop)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else if enroll.pending {
            // 样本在路上：不提供"开始录音"（会让人再录一条冗余样本），
            // 只给一个小出口允许显式重录。
            Label(L10n.Voiceprint.sent, systemImage: "checkmark.icloud")
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
            rerecordButton
        } else if enroll.resultOK == true {
            Label(L10n.Voiceprint.done, systemImage: "checkmark.seal.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
            rerecordButton
        } else if enroll.resultOK == false {
            Text(L10n.Voiceprint.failed)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            startButton
        } else {
            startButton
        }
    }

    private var startButton: some View {
        Button {
            start()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text(L10n.Voiceprint.enrollStart)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    /// 小号、次要样式——重录是**可选项**，不该和"开始录音"一样抢眼。
    private var rerecordButton: some View {
        Button {
            enroll.reset()
            errorText = nil
        } label: {
            Label(L10n.Voiceprint.rerecord, systemImage: "arrow.clockwise")
                .font(.system(size: 12))
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: 录制

    private func start() {
        enroll.markRecording()
        errorText = nil
        #if os(watchOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            errorText = error.localizedDescription
            return
        }
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voiceprint.m4a")
        try? FileManager.default.removeItem(at: url)
        do {
            let newRecorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ])
            guard newRecorder.record() else { throw RecorderFailure.couldNotStart }
            recorder = newRecorder
            isRecording = true
            elapsed = 0
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func finish() {
        guard let recorder else { return }
        // ⚠️ `AVAudioRecorder.currentTime` 在 `stop()` 之后**归零**：必须在停之前读。
        //    写在 `stop()` 后面会让"至少 3 秒"这个判断永远不成立——样本永远传不出去，
        //    用户只看到一句"太短了"。`elapsed` 是 0.2 s 一跳的镜像，取大值兜住边界。
        let recorded = max(recorder.currentTime, elapsed)
        recorder.stop()
        let url = recorder.url
        self.recorder = nil
        isRecording = false
        // 太短的样本算不出稳定特征，手机端也会拒绝——这里先拦一道，少一次无效传输。
        guard recorded >= Self.minimumSeconds else {
            errorText = L10n.Voiceprint.tooShort
            return
        }
        link.transferVoiceprint(url)
        enroll.markSent()
    }
}

/// 手表端的最小错误类型——手表 target 里不编 `VoiceprintError`（那是手机侧的类型）。
private enum RecorderFailure: LocalizedError {
    case couldNotStart
    var errorDescription: String? { L10n.Voiceprint.unreadable }
}
