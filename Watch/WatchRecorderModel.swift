import AVFoundation
import Foundation
import WatchKit
import os.log

private let log = Logger(subsystem: "com.nomily.app.watch", category: "recorder")

/// A clip on the watch that hasn't been confirmed by the iPhone yet.
struct PendingClip: Identifiable {
    let url: URL
    let bytes: Int64

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var displayTitle: String { RecordingName.displayTitle(for: name) }
}

/// 录音时那条音波要用的实时电平。
///
/// ★ 2026-10-16 九改新增（用户："开始录音的时候就是一条音波跟心率一样的"）。
///
/// ## 为什么不是两个独立的值
/// 本来可以拆成 `level: Float` + `tick: Int` 两个 `@Published`，但那样每滴答一次
/// 会发两轮对象变更。合成一个 `Equatable` 结构体，视图侧一句
/// `onChange(of: meter)` 就够了。
///
/// ## ⚠️ `tick` 不是多余的
/// **安静的时候 `level` 恒等于 0，`onChange(of: level)` 一次都不会触发** ——
/// 于是那条波会冻在那里，"心跳"也就没了。带上单调递增的 `tick`，波形每收到
/// 一次滴答就前进一格，安静时照样在走。
struct WatchAudioMeter: Equatable {
    /// 归一化到 0...1 的瞬时电平。
    var level: Float = 0
    /// 单调递增的采样序号。见上面那段 —— 它存在的唯一理由就是让安静时也"有变化"。
    var tick: Int = 0
}

/// Wrist recorder. AAC-in-M4A at 24 kHz mono / 48 kbps — roughly 21 MB/hour,
/// which is the balance the Ultra prototype settled on between speech clarity
/// and multi-hour sessions.
///
/// Clips are named `yyyyMMddHHmmss.m4a` so they parse through `RecordingName`
/// exactly like device clips do and sort into the phone's Library by recording
/// time. The watch-side copy is deleted once WatchConnectivity confirms the
/// phone has it; until then the clip stays here and is re-queued on launch.
@MainActor
final class WatchRecorderModel: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var currentBytes: Int64 = 0
    /// 录音时的实时电平，给首页那条音波用。**只有录音中才在变** ——
    /// 停止时会清零，所以空闲态不会每秒推着视图重绘十几次。
    @Published private(set) var meter = WatchAudioMeter()
    @Published private(set) var pending: [PendingClip] = []
    @Published var errorMessage: String?

    private let link: WatchLink
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var intentObserver: NSObjectProtocol?
    private var startedAt: Date?
    private var lastPush = Date.distantPast

    /// How often the phone is re-told a take is still running. Slow enough to
    /// be free, frequent enough that the phone can call the state stale after
    /// three missed beats and still be talking about seconds, not minutes.
    private static let heartbeatInterval: TimeInterval = 10

    /// 电平表的采样间隔 —— 12.5Hz。
    ///
    /// ★ 2026-10-16 九改：原来这个表是 **1 秒**一跳（只为刷计时）。1 秒的刷新率
    /// 画不出音波：那条波每格才动一次，看起来是幻灯片不是声音。
    ///
    /// ⚠️ 12.5Hz 是权衡过的：再快（30Hz）在 40mm 表上肉眼分辨不出，却把重绘
    /// 开销翻一倍还多；再慢就开始有"一格一格跳"的顿挫感。
    private static let meterInterval: TimeInterval = 0.08

    /// `meterInterval` 的倒数。用来把"每秒一次"那部分活儿（计时、字节数）
    /// 从 12.5Hz 的滴答里择出来。
    private static let meterTicksPerSecond = 12

    /// Felt, not heard. `.start` / `.stop` are the workout-style haptics, and
    /// those drive the speaker as well as the Taptic Engine — an audible beep
    /// at the top and tail of a take, which lands in the recording of the very
    /// meeting you're trying to capture. `.click` is the tactile-only tick the
    /// Digital Crown uses.
    private static let confirmation: WKHapticType = .click

    init(link: WatchLink) {
        self.link = link
        super.init()
        intentObserver = NotificationCenter.default.addObserver(
            forName: RecordingIntentBus.didRequestToggle,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.consumePendingToggle() }
        }
        // Covers the other order: the Action Button's intent ran before this
        // model existed.
        consumePendingToggle()
        link.onStored = { [weak self] name in self?.discard(named: name) }
        #if targetEnvironment(simulator)
        // Simulator-only delivery has no transferUserInfo ack path; once the file lands in the shared inbox
        // it counts as delivered (see `WatchLink.transferViaSimulatorSharedInbox`).
        // Reuse `discard`: it already does reloadPending + pushState, so the pending list
        // and the phone-side state are cleared together.
        link.onSimulatorDelivered = { [weak self] name in self?.discard(named: name) }
        #endif
        // Anything an earlier launch left behind — a transfer that was never
        // queued because the session wasn't live yet, or one the app died
        // before delivering — gets another shot as soon as the link is up.
        link.onActivated = { [weak self] in self?.resendPending() }
        reloadPending()
    }

    deinit {
        if let intentObserver {
            NotificationCenter.default.removeObserver(intentObserver)
        }
    }

    // MARK: - recording

    func toggleRecording() {
        // ★ Diagnostic log added 2026-10-14 -- do not delete, see the comment on `consumePendingToggle`.
        //
        // Origin: on the watchOS simulator the app starts recording by itself right after `launch`
        // (real-device log shape: `14:11:15.565 [recorder] recording to <stamp>.m4a`
        // appears less than 1 second after launch, and 1.1 seconds later `queued` is sent out).
        // Yet the line `toggling from the Action Button intent` in `consumePendingToggle`
        // **never appeared even once** -- meaning `RecordingIntentBus.pendingToggle` was false,
        // i.e. it was **not** the Action Button path. The only remaining entry point is this function.
        // This line answers "how many times was it called, and what state was it in each time".
        log.info("toggleRecording: isRecording=\(self.isRecording, privacy: .public)")
        isRecording ? stop() : requestPermissionAndStart()
    }

    /// Runs the Action Button's request, once, whenever the recorder gets to it.
    func consumePendingToggle() {
        guard RecordingIntentBus.pendingToggle else { return }
        RecordingIntentBus.pendingToggle = false
        log.info("toggling from the Action Button intent")
        toggleRecording()
    }

    private func requestPermissionAndStart() {
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            Task { @MainActor in
                guard let self else { return }
                if allowed {
                    self.start()
                } else {
                    self.errorMessage = L10n.Watch.micDenied
                }
            }
        }
    }

    private func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            // `.spokenAudio` is a playback mode and returns paramErr (-50)
            // against the record-only category on watch hardware.
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            fail(error)
            return
        }

        do {
            let url = makeClipURL()
            let newRecorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ])
            // ★ 2026-10-16 九改：开电平表。不开的话 `averagePower` 恒返回 -160，
            //   首页那条音波就是一条死线 —— 而它唯一的用处恰恰是证明"在录"。
            newRecorder.isMeteringEnabled = true
            guard newRecorder.record() else { throw RecorderError.couldNotStart }
            recorder = newRecorder
            elapsed = 0
            currentBytes = 0
            meter = WatchAudioMeter()
            isRecording = true
            startedAt = Date()
            // ★ 十一改：跟着录音起停心率采集。放在这里（录音**已经真的开始**之后）
            //   而不是更早：`record()` 失败时不该白开一路采集。
            //
            // ⚠️ 起停必须成对，且和 `isRecording` 同一处 —— 落在别处的话，
            //    出现"录完还在轮询 HealthKit"这种看不见的电量泄漏。
            // ★ 十五改：这里原来还有一句 `heart.follow()`（十一改加的，让心率
            //   采集跟着录音起停）。心率不再驱动那条波之后它就没有消费者了，
            //   整条链路连同 `prepareHeartRate()` 一起停用 —— 见
            //   `WatchHeartRate.swift` 顶部那段。
            WKInterfaceDevice.current().play(Self.confirmation)
            startTimer()
            pushState()
            log.info("recording to \(url.lastPathComponent, privacy: .public)")
        } catch {
            try? session.setActive(false)
            fail(error)
        }
    }

    private func stop() {
        guard let recorder else { return }
        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        // 归零而不是留着最后一格：停止之后首页要立刻切回眼睛，
        // 留着一个电平值会让那条波在消失前闪一下。
        meter = WatchAudioMeter()
        // ★ 十五改：原来这里还有 `heart.unfollow()` 与 `heartRate = nil`。
        //   心率那条链路停用之后两句一起去掉（理由同 `start()` 里那句）。
        startedAt = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        WKInterfaceDevice.current().play(Self.confirmation)
        link.transfer(url)
        reloadPending()
        // After `reloadPending`, so the phone hears "not recording, one clip on
        // the way" in a single push rather than flickering through "idle".
        pushState()
    }

    /// Re-states the whole recorder in one payload. Cheap enough to call from
    /// every transition; `pushState` is what the phone's status row is made of.
    private func pushState() {
        lastPush = Date()
        link.pushState(
            isRecording: isRecording,
            since: startedAt,
            transferPending: !pending.isEmpty
        )
    }

    private func startTimer() {
        timer?.invalidate()
        // ⚠️ 这个计数是**给闭包用的**：滴答频率是 12.5Hz，但计时和字节数
        //    只需要 1 秒一次（`size(of:)` 要 stat 一次文件，白跑 12 次很浪费，
        //    而且显示的粒度本来就是秒）。
        var ticks = 0
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.meterInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                ticks += 1
                self.sampleMeter(recorder, tick: ticks)
                guard ticks % Self.meterTicksPerSecond == 0 else { return }
                self.elapsed = recorder.currentTime
                self.currentBytes = Self.size(of: recorder.url)
                if Date().timeIntervalSince(self.lastPush) >= Self.heartbeatInterval {
                    self.pushState()
                }
            }
        }
    }

    /// 读一次电平，写进 `meter`。
    ///
    /// ## 为什么 dBFS 要砍在 -50
    /// `averagePower` 给的是 **dBFS**（0 = 满量程，负得越多越轻）。表盘上离嘴
    /// 几十厘米的轻声说话大约落在 -50dB 附近，而安静房间的底噪在 -65dB 以下。
    /// 把地板放在 -50，底噪就画不出波 —— 否则这条线会一直在抖，用户会以为
    /// 麦克风在收到什么。
    ///
    /// ## 为什么上升快、下降慢
    /// 说话的第一个字必须**立刻**顶上去（不然用户会怀疑没录上），但如果在
    /// 80ms 内就掉回去，一个音节会被撕成好几段噪点。所以上升直接跟，下降按
    /// 固定速度滑 —— 每格 0.14，从满量程滑回底约 0.6 秒。
    private func sampleMeter(_ recorder: AVAudioRecorder, tick: Int) {
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        let floorDb: Float = -50
        let raw = max(0, min(1, (db - floorDb) / -floorDb))
        let next = raw > meter.level ? raw : max(raw, meter.level - 0.14)
        meter = WatchAudioMeter(level: next, tick: tick)
    }

    private func fail(_ error: Error) {
        let nsError = error as NSError
        log.error("recording failed: \(String(describing: error), privacy: .public)")
        errorMessage = L10n.Watch.recordFailed("\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
    }

    // MARK: - pending clips

    /// Re-send a clip the user is tired of waiting on. Harmless while the
    /// transfer is already queued — `WatchLink` de-dupes.
    func retry(_ clip: PendingClip) {
        link.transfer(clip.url)
    }

    private func resendPending() {
        reloadPending()
        // Clips the phone's daemon already took are still pending here (the
        // wrist copy only goes after the app's ack), and re-offering those
        // sends the same bytes twice.
        for clip in pending where !link.deliveredNames.contains(clip.name) {
            link.transfer(clip.url)
        }
        // The link just came up, so the phone's copy of our state is whatever
        // it had before the session died. Re-state it.
        pushState()
    }

    func delete(_ clip: PendingClip) {
        discard(clip.url)
    }

    private func discard(named name: String) {
        discard(Self.clipsDirectory.appendingPathComponent(name))
    }

    private func discard(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        reloadPending()
        // Clears the phone's "transferring" state the moment the queue empties.
        pushState()
    }

    private func reloadPending() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.clipsDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let recordingURL = recorder?.url
        pending = urls
            .filter { $0.pathExtension == "m4a" && $0 != recordingURL }
            .map { PendingClip(url: $0, bytes: Self.size(of: $0)) }
            .sorted { $0.name > $1.name }
    }

    // MARK: - files

    private static var clipsDirectory: URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = root.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `yyyyMMddHHmmss.m4a`, matching the device's naming so the phone's
    /// `RecordingName` parses it. On the rare same-second collision the
    /// timestamp is walked forward rather than suffixed, which would break
    /// that parse.
    private func makeClipURL() -> URL {
        var stamp = Date()
        var url = Self.clipsDirectory
            .appendingPathComponent(RecordingName.filename(for: stamp, extension: "m4a"))
        while FileManager.default.fileExists(atPath: url.path) {
            stamp = stamp.addingTimeInterval(1)
            url = Self.clipsDirectory
                .appendingPathComponent(RecordingName.filename(for: stamp, extension: "m4a"))
        }
        return url
    }

    private static func size(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }
}

private enum RecorderError: LocalizedError {
    case couldNotStart
    var errorDescription: String? { "AVAudioRecorder refused to start" }
}
