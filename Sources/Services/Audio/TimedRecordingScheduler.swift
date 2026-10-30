import Foundation
import os.log
import UserNotifications

private let log = Logger(subsystem: "com.nomily.app.ios", category: "timed-rec")

/// ★ 2026-10-29（饭耳移植 · 规格 §3.1 定时录音 · 按时间录）
/// ★ 2026-10-30 重写（用户："定时录音应该是归纳到 Apple Watch 上面，只对
/// 这个设备有效……真正在手表上录"）：
///
/// 调度器不再动手机麦克风。窗口内到点，通过 WatchConnectivity 的
/// application context 让 **手表** 开始录音；窗口结束让手表停。手表的片段
/// 走既有管线自动传回手机入库转写（`WatchLink.transferFile` → 手机
/// `recordDownload` → 自动转写），所以这里不需要保存任何文件。
///
/// 平台现实，照旧直说：
///   · **自动触发只在手机进程活着时生效**（启动 / 回前台 / 30 秒心跳时评估；
///     窗口开始时进程死了，就在下一次窗口内评估时补发 start——录个后半夜）。
///   · **手表麦克风只在 App 前台可用。** 命令经 application context 转交，
///     不需要手表此刻可达；手表把命令存着，抬腕进 App 时补开录。抬腕了但
///     始终没录上（120 秒内表端心跳仍说没在录），发本地通知提醒用户。
///   · **手机死机也有兜底**：start 命令里带着窗口结束时刻，手表到点自己停。
///   · 发出 start 后 `BackgroundKeeper(.timedRecording)` 照旧挂着——它现在的
///     职责是保住"到点能发 stop"这条命。
@MainActor
final class TimedRecordingScheduler: ObservableObject {

    static let shared = TimedRecordingScheduler()
    private init() {}

    @Published private(set) var isTimedRecording = false
    /// Last status line for the settings page (start/stop/missed notices).
    @Published var lastNotice: String?

    private var heartbeat: Timer?
    private weak var configService: ConfigService?
    private weak var watch: WatchSyncService?

    /// 已发出 start 的时刻（nil = 没发过）。持久化：手机被杀后重启不能对同
    /// 一个窗口重复发 start（手表端幂等，但重复发会把"用户手动停掉"覆盖掉）。
    private static let startIssuedKey = "timed.watch.start_issued_at"
    /// "发了 start 但表端一直没录"提醒只对同一次 start 发一次。
    private var missNotifiedFor: Date?

    private var startIssuedAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: Self.startIssuedKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.startIssuedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.startIssuedKey)
            }
        }
    }

    // MARK: - Wiring

    /// From `AppEnvironment.init` — the scheduler needs config + the watch link.
    func configure(configService: ConfigService, watch: WatchSyncService) {
        self.configService = configService
        self.watch = watch
        startHeartbeat()
    }

    /// Call from scenePhase `.active` too — the cheapest way to catch "the
    /// window started while the app sat in the task switcher".
    func evaluate() {
        guard let configService else { return }
        let cfg = configService.config
        guard cfg.timedRecordingEnabled else {
            if startIssuedAt != nil { issueStop(reason: "switch turned off") }
            isTimedRecording = false
            return
        }
        guard Self.inWindow(start: cfg.timedRecordingStart, end: cfg.timedRecordingEnd, at: Date()) else {
            if startIssuedAt != nil {
                issueStop(reason: "window ended")
            }
            isTimedRecording = false
            lastNotice = nil
            return
        }

        // 窗口内。
        if startIssuedAt == nil {
            issueStart(endsAt: Self.windowEnd(start: cfg.timedRecordingStart, end: cfg.timedRecordingEnd, now: Date()))
            return
        }

        // 已经发过 start：跟随手表心跳更新状态；2 分钟还没录上就提醒一次。
        if watch?.isWatchRecording == true {
            isTimedRecording = true
            lastNotice = L10n.TimedRecording.recording
        } else if let issued = startIssuedAt,
                  Date().timeIntervalSince(issued) > 120,
                  missNotifiedFor != issued {
            missNotifiedFor = issued
            lastNotice = L10n.TimedRecording.watchNotRecording
            notifyStartMissed()
        }
    }

    // MARK: - Commands

    private func issueStart(endsAt: Date) {
        startIssuedAt = Date()
        missNotifiedFor = nil
        isTimedRecording = true
        BackgroundKeeper.shared.acquire(.timedRecording)
        watch?.sendTimedRecordCommand(start: true, endsAt: endsAt)
        lastNotice = L10n.TimedRecording.watchCommandSent
        log.notice("timed recording: start command sent, window ends at \(endsAt, privacy: .public)")
    }

    private func issueStop(reason: String) {
        startIssuedAt = nil
        missNotifiedFor = nil
        isTimedRecording = false
        BackgroundKeeper.shared.release(.timedRecording)
        watch?.sendTimedRecordCommand(start: false, endsAt: nil)
        lastNotice = L10n.TimedRecording.watchStopped
        log.notice("timed recording: stop command sent (\(reason, privacy: .public))")
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in TimedRecordingScheduler.shared.evaluate() }
        }
    }

    // MARK: - Window math

    /// "HH:mm" window, midnight-crossing safe ("23:30"–"07:00").
    static func inWindow(start: String, end: String, at date: Date) -> Bool {
        guard let s = minutes(start), let e = minutes(end) else { return false }
        let cal = Calendar.current
        let n = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        return s <= e ? (n >= s && n < e) : (n >= s || n < e)
    }

    /// 窗口结束的绝对时刻（给手表的兜底停止时间）。调用时必在窗口内：
    /// · 不跨午夜（09:00–18:00，现在 10:00）→ 今天的结束点就是答案；
    /// · 跨午夜（23:30–07:00）→ 现在 02:00 用今天 07:00，现在 23:45 已过今晨，
    ///   结束点顺延到明天 07:00。所以唯一规则：结束点 <= 现在 就加一天。
    static func windowEnd(start: String, end: String, now: Date) -> Date {
        let cal = Calendar.current
        let e = minutes(end) ?? 7 * 60
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = e / 60
        comps.minute = e % 60
        var end = cal.date(from: comps) ?? now
        if end <= now {
            end = cal.date(byAdding: .day, value: 1, to: end) ?? end
        }
        return end
    }

    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m)
        else { return nil }
        return h * 60 + m
    }

    // MARK: - Fallback notification

    /// 手表迟迟没录上——提醒用户抬腕把手表 App 打开。无通知权限时静默。
    private func notifyStartMissed() {
        let content = UNMutableNotificationContent()
        content.title = L10n.TimedRecording.missedTitle
        content.body = L10n.TimedRecording.missedBody
        let request = UNNotificationRequest(
            identifier: "timed-recording-missed-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// ★ 2026-10-30：HealthKit 睡眠预填已移除（用户："健康功能不是我们的赛道"）。
/// 定时窗口只用手填的开始/结束时间。
