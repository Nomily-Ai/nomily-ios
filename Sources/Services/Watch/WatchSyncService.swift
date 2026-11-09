import AVFoundation
import Foundation
import WatchConnectivity
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "watch")

extension Notification.Name {
    /// Posted when something outside the Library UI adds or changes a clip —
    /// today that's a watch recording landing while the Library is on screen.
    static let libraryDidChange = Notification.Name("libraryDidChange")

    /// Posted once a watch clip is on disk in the Library, so the Recordings
    /// tab can take the user to it.
    static let watchClipDidArrive = Notification.Name("watchClipDidArrive")
}

/// iPhone half of the Apple Watch link.
///
/// A watch recording arrives as a `WCSessionFile` and is copied straight into
/// `audio_clips/decrypted/`, the same directory device downloads and file
/// imports land in. It's a plain `.m4a` (no device encryption involved), so the
/// Library, Clip detail, transcription and summarisation paths all work on it
/// unchanged. The manifest records it with `transport: "watch"` so the Library
/// row can mark its origin.
///
/// The watch keeps its copy until this side confirms the write — see
/// `acknowledge`. Nothing else crosses the link; the wrist doesn't drive the
/// Nomi.
@MainActor
final class WatchSyncService: NSObject, ObservableObject {
    /// True once WCSession has finished activating. The flags below are all
    /// `false` until then, so Settings needs this to tell "no watch paired"
    /// apart from "haven't been told yet".
    @Published private(set) var isActivated = false

    /// Watch-side state, surfaced in Settings so the user can tell "no watch"
    /// from "watch app not installed yet". Only meaningful once the session has
    /// activated.
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    /// True while the watch app is in the foreground and reachable — the
    /// closest thing this link has to "connected".
    @Published private(set) var isReachable = false

    /// Recorder state as last pushed from the wrist. The phone never asks for
    /// this — it displays what it was told, and `lastHeartbeat` is what keeps
    /// that honest: the watch re-states a running take every 10 s, so a row
    /// that stops being refreshed can be shown as stale rather than quietly
    /// continuing to claim a recording that may have ended.
    @Published private(set) var isWatchRecording = false
    @Published private(set) var watchRecordingSince: Date?
    @Published private(set) var isWatchTransferring = false

    /// ★ 2026-11-06：最近一次手表声纹注册的结果（时间戳 ID + 成败）。
    /// 随 `pushCurrentContext` 推回手表，ID 用于手表端去重（上下文是"最新值"
    /// 语义，同一条结果会被重复送达）。进程重启后为 nil——旧结果手表早已消费，
    /// 不再重放，避免把"已更新"反复盖回去。
    private(set) var lastVoiceprintResult: (id: Int, ok: Bool)?
    /// ★ 2026-11-05：手表侧"全天候录音"开关的回报值（每次状态推送都带）。
    /// `nil` = 还没收到过（旧版手表 App / 尚未激活）。手机设置页的开关在
    /// "手机从未设置过"时显示它，见 `phoneAllDay`。
    @Published private(set) var watchAllDayState: Bool?
    /// 手机上用户最后一次设置的全天候录音值；`nil` = 手机上从来没动过这个开关
    /// （此时显示跟手表走）。存 UserDefaults 而非 AppConfig：这是**手表的行为
    /// 偏好**，和录音质量档位同类，不参与摘要/转写配置。
    private static let phoneAllDayKey = "watch.all_day.phone.v1"
    var phoneAllDay: Bool? {
        UserDefaults.standard.object(forKey: Self.phoneAllDayKey) as? Bool
    }

    /// 手机设置页翻动全天候录音开关：落盘 + 立即推给手表（一次性，
    /// 见 `pushCurrentContext(allDay:)`——常态推送不带这个键，不会盖掉手表自己的值）。
    func setAllDayRecording(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.phoneAllDayKey)
        pushCurrentContext(allDay: on)
    }

    /// ★ 2026-11-06（用户："手表这边可以增加一个表情常亮…设置在 app 里面"）：
    /// 手表上次回报的常亮开关值；`nil` = 还没收到过。
    @Published private(set) var watchAlwaysOnFace: Bool?
    /// 手机上用户最后一次设置的值；`nil` = 手机上从来没动过（显示跟手表走）。
    private static let phoneAlwaysOnFaceKey = "watch.always_on_face.phone.v1"
    var phoneAlwaysOnFace: Bool? {
        UserDefaults.standard.object(forKey: Self.phoneAlwaysOnFaceKey) as? Bool
    }

    /// 手机设置页翻动「表情常亮」开关：落盘 + 立即推给手表（一次性带上键，
    /// 与 allDay 同规则——常态推送不带，不盖掉手表自己的值）。
    func setAlwaysOnFace(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.phoneAlwaysOnFaceKey)
        pushCurrentContext(alwaysOnFace: on)
    }

    // MARK: - ★ 2026-11-06 二轮："让脸活起来"的四个设置（手机端入口）
    //
    // 与 setAlwaysOnFace 完全同构：手机上改 → 落盘（`watch.<x>.phone.v1`，
    // 设置页回显用）→ 随上下文一次性把键推给手表。手表端落在
    // `WatchRecordingPrefs`，见 `NomilyWatchApp` 的接线。

    /// 手机上最后一次设置的眼睛形状；`nil` = 从没动过（设置页显示跟手表走）。
    var phoneEyeShape: String? {
        UserDefaults.standard.string(forKey: "watch.eye_shape.phone.v1")
    }
    func setEyeShape(_ raw: String) {
        UserDefaults.standard.set(raw, forKey: "watch.eye_shape.phone.v1")
        pushCurrentContext(eyeShape: raw)
    }

    /// 手机上最后一次设置的打瞌睡配置（开关 + 秒数）。
    var phoneDrowsyEnabled: Bool? {
        UserDefaults.standard.object(forKey: "watch.drowsy.phone.v1") as? Bool
    }
    var phoneDrowsyAfter: Int? {
        UserDefaults.standard.object(forKey: "watch.drowsy_after.phone.v1") as? Int
    }
    func setDrowsy(enabled: Bool, after seconds: Int) {
        UserDefaults.standard.set(enabled, forKey: "watch.drowsy.phone.v1")
        UserDefaults.standard.set(seconds, forKey: "watch.drowsy_after.phone.v1")
        pushCurrentContext(drowsyEnabled: enabled, drowsyAfter: seconds)
    }

    /// 手机上最后一次设置的"瞳孔跟随"开关。
    var phonePupilFollow: Bool? {
        UserDefaults.standard.object(forKey: "watch.pupil_follow.phone.v1") as? Bool
    }
    func setPupilFollow(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "watch.pupil_follow.phone.v1")
        pushCurrentContext(pupilFollow: on)
    }

    /// When the wrist first told us a transfer was pending — drives the elapsed
    /// counter and the give-up timer on the status strip.
    @Published private(set) var watchTransferSince: Date?
    @Published private(set) var lastWatchHeartbeat: Date?
    /// Set when a pending transfer was declared dead, so the strip can say why
    /// instead of vanishing without a word.
    @Published private(set) var watchTransferNotice: String?
    private var transferWatchdog: Timer?

    private let config: ConfigService
    private let library: Library
    private let transcription: TranscriptionService

    init(config: ConfigService, library: Library, transcription: TranscriptionService) {
        self.config = config
        self.library = library
        self.transcription = transcription
        super.init()
    }

    func activate() {
        // ★ Simulator-only delivery channel (this whole section does not exist in device builds, see the long comment below).
        #if targetEnvironment(simulator)
        startSimulatorInboxWatch()
        #endif
        // Off the main thread deliberately. The first touch of
        // `WCSession.default` opens an XPC connection to the WatchConnectivity
        // daemon; from `AppEnvironment.init` that blocks the launch screen
        // before SwiftUI can render a first frame, and it blocks for *seconds*
        // when the daemon is busy — which it is right after an install, while
        // the paired watch provisions the companion app. Activation is
        // asynchronous anyway, so nothing downstream cares who kicked it off.
        Task.detached(priority: .userInitiated) {
            guard WCSession.isSupported() else { return }
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
    }

#if targetEnvironment(simulator)
    /// Simulator-only delivery channel. **This whole section does not exist in device builds.**
    ///
    /// ## Why it is needed (2026-10-14)
    /// Apple's official API documentation explicitly states that the simulator does not support `transferFile(_:metadata:)`:
    /// > "Always test Watch Connectivity file transfers on paired devices.
    /// >  The Simulator app doesn't support the transferFile(_:metadata:) method."
    ///
    /// Observed symptoms (fully recorded in `WATCH-SIMULATOR-FINDINGS.md`): on the watch side
    /// the `didFinish fileTransfer` callback has **error = nil** and `reportFileTransfer success = 1`
    /// (but `durationSec = 0`), while on the phone side `session(_:didReceive:)` **never fires**
    /// and wcd's pending-receive queue stays at 0 —— a user verifying "watch recording reaches the phone" on the simulator
    /// is fooled by this fake success and needlessly doubts their own code. The same problem was reported on the forums and filed as a
    /// radar (FB7639842) in 2020, and is still unfixed as of 2025.
    ///
    /// ## How to work around it
    /// Both simulators' sandboxes live on the **filesystem of the same Mac**, so the watch app itself
    /// (`WatchLink.transferViaSimulatorSharedInbox`, likewise compiled for the simulator only) drops the
    /// recording straight into the shared spot `/tmp/nomily-watch-inbox/`. **No external script is needed.**
    /// This method does just one thing: **watch that shared spot**, and hand any new m4a to the **exact same**
    /// `didImport` as on a real device —— import, notification and ASR trigger all take the same path.
    ///
    /// ⚠️ Isolated by the `#if targetEnvironment(simulator)` compile condition: device builds don't contain this section,
    ///    and don't watch any device path either.
    private var simInboxTimer: Timer?

    private func startSimulatorInboxWatch() {
        let inbox = simInboxDirectory
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        // The Timer lands on the main runloop, so the callback is necessarily on the main thread —— `assumeIsolated` is safe
        // (precedent: the dnoteWatch subscription in `RecorderSession`).
        simInboxTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.drainSimulatorInbox(inbox)
            }
        }
        log.info("simulator inbox watch on \(inbox.path, privacy: .public)")
    }

    /// Shared delivery spot, placed **outside the app container** (`/tmp/nomily-watch-inbox`).
    ///
    /// ★ Why `/tmp` rather than our own container (2026-10-14): putting it in the container has two awkward points ——
    ///   ① the watch app and the phone app are two **different** containers; for the watch to write into the phone's container it would
    ///   have to know the absolute path, which could only be fed in by an external script (and the container UUID changes on every reinstall);
    ///   ② the deliverer degrades from "the watch app itself" to "someone must run a script", so the two ends no longer share a source.
    ///   Both apps can write to `/tmp` directly, so "delivery" happens entirely inside the apps.
    ///
    /// ⚠️ **Erratum (important)**: this used to say "the simulator container has namespace isolation against external writes,
    ///    so `copyItem` reports Code=4 ENOENT" —— **that judgment was wrong**. The real cause was
    ///    that `drainSimulatorInbox` below was missing the create-directory step (the error follows the code, and it shows up
    ///    just the same after switching directories, which is itself counter-evidence). At the time only the directory location was changed, so the problem never went away.
    private var simInboxDirectory: URL {
        URL(fileURLWithPath: "/tmp/nomily-watch-inbox", isDirectory: true)
    }

    private func drainSimulatorInbox(_ inbox: URL) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        guard !urls.isEmpty else { return }
        let dir = StorageLocations.decryptedDir
        // ★★ This line cannot be omitted. `AudioImporter.uniqueDestination` only builds the path and **does not create directories**,
        //    and on a fresh install with nothing recorded yet `decrypted/` doesn't exist at all ⇒ `copyItem`
        //    reports `NSCocoaErrorDomain Code=4 "The file … doesn't exist"`. The nastiest part is that the error reports the
        //    **source** path (`NSFilePath`), which looks like the source file is missing, when actually the destination directory is.
        //    On the device path, `didReceive(file:)` is guarded by the same kind of line.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for url in urls where url.pathExtension == "m4a" {
            let name = url.lastPathComponent
            let incomingSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // Same dedup as the device `didReceive(file:)`: if the watch resends one already imported,
            // just treat it as received and don't save a second copy. The simulator side has no ack path, so whichever branch is taken
            // the copy in the inbox must be deleted, otherwise the same item is reprocessed every 2 seconds.
            let storedSize = (try? dir.appendingPathComponent(name)
                .resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if storedSize == incomingSize {
                try? FileManager.default.removeItem(at: url)
                log.info("sim inbox duplicate skipped \(name, privacy: .public)")
                continue
            }
            let target = AudioImporter.uniqueDestination(in: dir, originalName: name)
            do {
                try FileManager.default.copyItem(at: url, to: target)
                try? FileManager.default.removeItem(at: url)
            } catch {
                // If the import fails, **leave** the copy in the inbox: the next tick will retry,
                // instead of silently dropping a recording.
                log.error("sim inbox copy failed: \(String(describing: error), privacy: .public)")
                continue
            }
            let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // ★ 2026-11-04：记下"这条录音来自手表"。摘要提示词只在有这个标记时才敢
        // 提用户的名字，其余录音不提——见 `ClipOrigin` 顶部的说明。
        ClipOrigin.mark(ClipOrigin.watch, forClipName: target.lastPathComponent)
            log.info("sim inbox delivered \(target.lastPathComponent, privacy: .public)")
            Task { @MainActor in self.didImport(target, size: size) }
        }
    }
#endif

    /// Applies a state push from the wrist.
    private func apply(watchState context: [String: Any]) {
        guard let beat = context[WatchLinkMessage.heartbeatKey] as? Double else { return }
        isWatchRecording = context[WatchLinkMessage.recordingKey] as? Bool ?? false
        // ★ 2026-11-05：手表回报的全天候录音状态（每次状态推送都带）。
        // 键缺省（旧版手表 App）→ 不动本地值。
        if let allDay = context[WatchLinkMessage.allDayKey] as? Bool {
            watchAllDayState = allDay
        }
        // ★ 2026-11-06：手表回报的表情常亮开关值（每次状态推送都带）。
        if let alwaysOnFace = context[WatchLinkMessage.alwaysOnFaceKey] as? Bool {
            watchAlwaysOnFace = alwaysOnFace
        }
        let transferring = context[WatchLinkMessage.transferPendingKey] as? Bool ?? false
        if transferring, !isWatchTransferring {
            watchTransferSince = Date()
            watchTransferNotice = nil
        }
        if !transferring {
            watchTransferSince = nil
        }
        isWatchTransferring = transferring
        watchRecordingSince = (context[WatchLinkMessage.recordingSinceKey] as? Double)
            .map(Date.init(timeIntervalSince1970:))
        lastWatchHeartbeat = Date(timeIntervalSince1970: beat)
        updateTransferWatchdog()
    }

    // MARK: - Transfer watchdog (2026-10-21: "一直卡在 Apple Watch 传输上")

    /// The wrist sets `transferPending` from its own WatchConnectivity queue and
    /// only clears it after the phone's store-ack. Two things can leave that
    /// flag stuck for ever: the wrist going out of range mid-transfer (its
    /// application context freezes, and a frozen `true` looks identical to a
    /// live one), or the file sitting in the daemon queue while this app is
    /// suspended. In both cases the strip used to spin forever with no way out.
    ///
    /// Two escapes:
    /// · 90 s of heartbeat silence → we stop *claiming* a live transfer and say
    ///   the watch is offline (the file itself is not lost: it lands whenever
    ///   the watch reconnects).
    /// · 5 minutes of a beating watch still saying "pending" → declare it dead
    ///   and clear, because WatchConnectivity would have moved a healthy
    ///   transfer by then.
    private func updateTransferWatchdog() {
        guard isWatchTransferring else {
            transferWatchdog?.invalidate()
            transferWatchdog = nil
            return
        }
        guard transferWatchdog == nil else { return }
        transferWatchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkTransferHealth() }
        }
    }

    private func checkTransferHealth() {
        guard isWatchTransferring else {
            transferWatchdog?.invalidate()
            transferWatchdog = nil
            return
        }
        let since = watchTransferSince ?? lastWatchHeartbeat ?? Date()
        let elapsed = Date().timeIntervalSince(since)
        let beatAge = lastWatchHeartbeat.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if beatAge > 90 || elapsed > 300 {
            // Honest, not silent: the clip is still on the wrist and will be
            // re-offered, so "gave up on the status" must not read as "lost".
            watchTransferNotice = beatAge > 90
                ? L10n.Watch.transferWatchOffline
                : L10n.Watch.transferGaveUp
            isWatchTransferring = false
            watchTransferSince = nil
            transferWatchdog?.invalidate()
            transferWatchdog = nil
        }
    }

    /// The user closed the transfer strip by hand. Only the *status* is
    /// dismissed — a file that does arrive is still imported and acked.
    func dismissTransferNotice() {
        isWatchTransferring = false
        watchTransferSince = nil
        watchTransferNotice = nil
        transferWatchdog?.invalidate()
        transferWatchdog = nil
    }

    // MARK: - Home-screen expression (★ 2026-10-16 thirteenth revision)

    /// The user changed the "watch home-screen eye expression" in Settings — push it to the watch at once.
    ///
    /// ⚠️ **Deliberately doesn't check reachability** (`session.isReachable`): when unreachable,
    ///    `updateApplicationContext` leaves this context in the daemon
    ///    and hands it over the next time the watch wakes. Checking reachability would instead treat "the watch is in the background right now" as a failure,
    ///    so the user changes the setting, raises their wrist, and finds nothing changed.
    func sendFaceStyle(_ tag: String) {
        pushFaceSettings(style: tag)
    }

    /// The user changed one of the other face settings (colour / blink pace /
    /// auto-cycle / frame) — push the whole face-settings bundle at once.
    ///
    /// ⚠️ All five keys travel in **one** `updateApplicationContext`: that call
    ///    *replaces* the previous context wholesale, so pushing only the changed
    ///    key would wipe the other four off the watch.
    func sendFaceSettings(
        style: String,
        colorHex: String?,
        blinkSpeed: String?,
        autoCycle: Bool,
        frameVisible: Bool
    ) {
        pushFaceSettings(
            style: style,
            colorHex: colorHex,
            blinkSpeed: blinkSpeed,
            autoCycle: autoCycle,
            frameVisible: frameVisible
        )
    }

    /// The style in use on the watch — re-pushed once on activation, closing the window where
    /// "what's stored on the watch differs from the phone" (the user switched phones, reinstalled the watch app, or a previous push never arrived).
    private func pushFaceSettings(
        style: String,
        colorHex: String? = nil,
        blinkSpeed: String? = nil,
        autoCycle: Bool? = nil,
        frameVisible: Bool? = nil
    ) {
        guard WCSession.isSupported() else { return }
        // Missing settings fall back to their defaults here so the context is
        // always complete — the watch then never has to distinguish "key
        // absent" from "set to default".
        let face = FaceContext(
            style: style,
            colorHex: colorHex,
            blinkSpeed: blinkSpeed,
            autoCycle: autoCycle ?? true,
            frameVisible: false  // ★ 2026-10-30：方框功能下线，恒为不显示
        )
        // ★ 2026-10-23: persisted, because `pushRecap` (which can fire after an
        // app relaunch, straight out of the job queue) must be able to rebuild
        // the *complete* context without the settings UI having been opened.
        if let data = try? JSONEncoder().encode(face) {
            UserDefaults.standard.set(data, forKey: Self.faceContextKey)
        }
        pushCurrentContext(face: face)
    }

    /// One `updateApplicationContext` push carrying **everything** the phone
    /// owns: face settings + recaps + (if any) the timed-recording command.
    ///
    /// ⚠️ Every push must be a full context — the call *replaces* the previous
    ///    one wholesale (see the block at `WatchLinkMessage.faceStyleKey`), so
    ///    pushing recaps alone would wipe the face settings off the watch and
    ///    vice versa. That is why both `pushFaceSettings` and `pushRecap`
    ///    funnel into here instead of writing the session directly.
    private func pushCurrentContext(face: FaceContext? = nil, allDay: Bool? = nil, alwaysOnFace: Bool? = nil,
                                    eyeShape: String? = nil, drowsyEnabled: Bool? = nil,
                                    drowsyAfter: Int? = nil, pupilFollow: Bool? = nil) {
        guard WCSession.isSupported() else { return }
        let resolvedFace = face ?? savedFaceContext()
        guard let resolvedFace else { return }
        var context: [String: Any] = [
            WatchLinkMessage.faceStyleKey: resolvedFace.style,
            WatchLinkMessage.faceAutoCycleKey: resolvedFace.autoCycle,
            WatchLinkMessage.faceFrameKey: resolvedFace.frameVisible,
        ]
        // ★ 2026-11-05：只在手机上翻全天候开关时才带这个键——上下文整体替换，
        // 常态带上会周期性地盖掉手表上用户自己翻的值（见 WatchLinkMessage.allDayKey）。
        if let allDay {
            context[WatchLinkMessage.allDayKey] = allDay
        }
        // ★ 2026-11-06：表情常亮开关同规则——只在翻开关时一次性带上。
        if let alwaysOnFace {
            context[WatchLinkMessage.alwaysOnFaceKey] = alwaysOnFace
        }
        // ★ 2026-11-06 二轮："让脸活起来"的四个设置，同一条一次性规则。
        if let eyeShape {
            context[WatchLinkMessage.eyeShapeKey] = eyeShape
        }
        if let drowsyEnabled {
            context[WatchLinkMessage.drowsyEnabledKey] = drowsyEnabled
        }
        if let drowsyAfter {
            context[WatchLinkMessage.drowsyAfterKey] = drowsyAfter
        }
        if let pupilFollow {
            context[WatchLinkMessage.pupilFollowKey] = pupilFollow
        }
        if let colorHex = resolvedFace.colorHex {
            context[WatchLinkMessage.faceColorKey] = colorHex
        }
        if let blinkSpeed = resolvedFace.blinkSpeed {
            context[WatchLinkMessage.blinkSpeedKey] = blinkSpeed
        }
        if let data = try? JSONEncoder().encode(loadRecapOutbox()) {
            context[WatchLinkMessage.recapsKey] = data
        }
        // ★ 2026-11-06：声纹注册回执（见 WatchLinkMessage.voiceprintResultKey）。
        if let result = lastVoiceprintResult {
            context[WatchLinkMessage.voiceprintResultIDKey] = result.id
            context[WatchLinkMessage.voiceprintResultKey] = result.ok
        }
        // ★ 2026-10-30：定时录音命令随完整上下文一起走（持久化了，所以手机
        // 重启后的任何一次推送都会带上）。
        // ★ 2026-11-06（全天候语义，用户："重新开的手机 Nomily 就中断了"）：
        // 只带**新鲜**的命令——这里持久化的是"最后一条"，可能是一条陈年的
        // "stop"，手机重启后的重放曾把手表正在录的全天候录音停掉（手表端
        // 已加 issuedAt 去重兜底，这里再把源头掐掉）。15 分钟以外的命令对
        // "定时录音窗口"早已没有意义，不再随上下文走。
        if let command = Self.loadTimedCommand(),
           Date().timeIntervalSince(command.issuedAt) < 15 * 60 {
            context[WatchLinkMessage.timedRecordCommandKey] = command.command
            context[WatchLinkMessage.timedRecordIssuedAtKey] = command.issuedAt.timeIntervalSince1970
            if let endsAt = command.endsAt {
                context[WatchLinkMessage.timedRecordEndsAtKey] = endsAt.timeIntervalSince1970
            }
        }
        do {
            try WCSession.default.updateApplicationContext(context)
            log.info("watch context pushed: style=\(resolvedFace.style, privacy: .public) recaps=\(Self.recapOutbox.count, privacy: .public)")
        } catch {
            // You reach here when the session hasn't activated yet. The activation callback pushes again, so this time
            // failing isn't fatal — a log line is enough; don't show the user anything.
            log.error("watch context push failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Timed recording command (★ 2026-10-30, "定时录音在手表上录")

    private struct TimedCommand: Codable {
        let command: String   // "start" | "stop"
        let issuedAt: Date
        let endsAt: Date?
    }

    /// 命令持久化键——pushCurrentContext 可在手机重启后被任何设置变更触发，
    /// 必须能从磁盘重建完整上下文（同 `faceContextKey` 的理由）。
    private static let timedCommandKey = "watch.timed.command"

    /// 定时录音：让手表开始/停止录音。`endsAt` = 窗口结束时刻，手表用它
    /// 自己兜底停止（手机进程死了也停得下来）。
    ///
    /// ⚠️ 不检查可达性（理由同 `sendFaceStyle`）：applicationContext 由守护
    /// 进程转交，手表 App 下次运行时一定拿到。
    func sendTimedRecordCommand(start: Bool, endsAt: Date?) {
        let command = TimedCommand(command: start ? "start" : "stop", issuedAt: Date(), endsAt: endsAt)
        if let data = try? JSONEncoder().encode(command) {
            UserDefaults.standard.set(data, forKey: Self.timedCommandKey)
        }
        pushCurrentContext()
        log.info("timed record command → \(command.command, privacy: .public) endsAt=\(command.endsAt.map { String(describing: $0) } ?? "nil", privacy: .public)")
    }

    private static func loadTimedCommand() -> TimedCommand? {
        guard let data = UserDefaults.standard.data(forKey: timedCommandKey) else { return nil }
        return try? JSONDecoder().decode(TimedCommand.self, from: data)
    }

    // MARK: - Recaps (★ 2026-10-23, "watch 那边能否靠 Siri Recap 的看齐")
    //
    // Apple's Siri Recap on the watch is opt-in, beta, and unavailable in
    // China — our own version instead: every finished summary job extracts a
    // digest and pushes it here. Kept in a small outbox so a push that goes
    // out while the watch is asleep is re-delivered with the *next* context
    // push, and so a recap survives this app being killed before WCSession
    // accepts the context.

    /// ★ 2026-10-30（用户："回顾里能看到待办这个为啥只能存 5 条？这个需要优化"）：
    /// 一条回顾最多带多少条待办。原来是硬编码 5 条，长会议（十几条行动项）会被截断，
    /// 手表上就"看不到最后那几条"——现在放到 30，够一小时的会用量，手表详情页
    /// 本身是可滚动的，多几条不影响观感。
    static let recapTodoLimit = 30

    private static let recapOutboxKey = "watch.recap.outbox.v1"
    private static let faceContextKey = "watch.face.context.v1"

    /// What the phone last pushed for the face, persisted so a recap push after
    /// relaunch can still rebuild the *complete* context (see `pushCurrentContext`).
    private struct FaceContext: Codable {
        var style: String
        var colorHex: String?
        var blinkSpeed: String?
        var autoCycle: Bool
        var frameVisible: Bool
    }

    /// Called by the summarize runner when a summary lands. Fire-and-forget.
    ///
    /// ★ 2026-10-30（用户："回顾摘要要支持在手机设置里面支持设置，在里面可以查看到
    /// 待办"）：两个变化——
    /// ① `todos`：摘要里明确承诺的待办随回顾一起推给手表（最多 5 条），手表详情页
    ///    列出来，点一下就能同步进手机的「提醒事项」；
    /// ② 设置里的开关关掉时**什么都不推**（连队列都不写），避免用户关了还在腕上看到。
    func pushRecap(
        clipName: String,
        title: String,
        points: [String],
        todos: [String] = [],
        recordedAt: Date,
        duration: TimeInterval? = nil
    ) {
        guard config.config.watchRecapEnabled else {
            log.info("recap skipped: disabled in settings")
            return
        }
        var recaps = loadRecapOutbox()
        // Re-summarising the same clip replaces its recap (id = clip name).
        recaps.removeAll { $0.id == clipName }
        recaps.insert(
            WatchRecap(
                id: clipName,
                title: title,
                points: points,
                todos: Array(todos.prefix(Self.recapTodoLimit)),
                recordedAt: recordedAt,
                createdAt: Date(),
                duration: duration
            ),
            at: 0
        )
        recaps = Self.prune(recaps)
        Self.recapOutbox = recaps
        if let data = try? JSONEncoder().encode(recaps) {
            UserDefaults.standard.set(data, forKey: Self.recapOutboxKey)
        }
        let face = savedFaceContext() ?? FaceContext(
            style: config.config.watchFaceStyle ?? BotFaceStyle.calm.rawValue,
            colorHex: config.config.watchEyeColor,
            blinkSpeed: config.config.watchBlinkSpeed,
            autoCycle: config.config.watchFaceAutoCycle ?? true,
            frameVisible: false  // ★ 2026-10-30：方框功能下线，恒为不显示
        )
        pushCurrentContext(face: face)
        log.info("recap pushed: \(clipName, privacy: .public) points=\(points.count, privacy: .public) todos=\(todos.count, privacy: .public)")
    }

    // MARK: - 历史摘要回填（★ 2026-11-04）

    /// 把**手机上已经存在的摘要**补进回顾 outbox。
    ///
    /// 为什么需要它：`pushRecap` 只在"摘要刚刚生成"那一刻推一条，outbox 也只从那时开始攒。
    /// 把上限从 8 提到 30（用户："右滑的最近要能看到 30 条"）之后，一个装了很久的
    /// 用户照样只能看到自己那 8 条——旧摘要从来没进过队列，不是被裁掉的。
    /// 于是这里从磁盘扫一遍：最近 30 天、按录音名倒序、有 `.summary.md` 的录音，
    /// 用与实时推送**完全相同**的提取链（`JobRunners.recapDigest` + `TodoExtract`）重建条目。
    ///
    /// 只做"填空"：outbox 已经满了就直接返回，所以正常情况下每次启动只是
    /// 一次目录列举 + 一个 `count` 比较，没有额外开销；而新用户先装了 App、
    /// 过几天才配对表时，那批摘要也能在激活那一刻补进来。
    func backfillRecapsIfNeeded() {
        guard config.config.watchRecapEnabled else { return }
        let current = loadRecapOutbox()
        guard current.count < WatchRecap.limit else { return }
        let known = Set(current.map(\.id))
        let need = WatchRecap.limit - current.count
        Task.detached(priority: .utility) { [weak self] in
            let built = await Self.recapsFromDisk(excluding: known, limit: need)
            guard !built.isEmpty, let self else { return }
            await MainActor.run {
                var merged = self.loadRecapOutbox()
                let have = Set(merged.map(\.id))
                merged.append(contentsOf: built.filter { !have.contains($0.id) })
                merged = Self.prune(merged)
                Self.recapOutbox = merged
                if let data = try? JSONEncoder().encode(merged) {
                    UserDefaults.standard.set(data, forKey: Self.recapOutboxKey)
                }
                self.pushCurrentContext()
                log.info("recap backfill: scanned and added \(built.count, privacy: .public), outbox=\(merged.count, privacy: .public)")
            }
        }
    }

    /// 扫磁盘重建回顾条目。**只读**：不写文件、不改摘要。
    ///
    /// 只扫最近 120 个录音名：摘要是"最近发生的事"，120 个之前的一定已经超出
    /// 30 天的保留窗口；再往里扫只是拿 IO 换不到条目。
    private static func recapsFromDisk(excluding known: Set<String>, limit: Int) async -> [WatchRecap] {
        guard limit > 0 else { return [] }
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-WatchRecap.retention)
        guard let names = try? fm.contentsOfDirectory(atPath: StorageLocations.audioDir.path) else {
            return []
        }
        // 录音名是 `yyyyMMddHHmmss.ext`，字典序就是时间序 —— 倒序即"最新优先"。
        let candidates = names
            .filter { RecordingName.date(from: $0) != nil && !known.contains($0) }
            .sorted(by: >)
            .prefix(120)

        var out: [WatchRecap] = []
        for name in candidates {
            if out.count >= limit { break }
            let summaryURL = StorageLocations.summaryURL(for: name)
            // 摘要文件的 mtime 就是"这条回顾诞生的时刻"，保留窗口按它算（与
            // `pushRecap` 里的 `createdAt: Date()` 同义）。
            guard let attrs = try? fm.attributesOfItem(atPath: summaryURL.path),
                  let createdAt = attrs[.modificationDate] as? Date,
                  createdAt > cutoff,
                  let text = try? String(contentsOf: summaryURL, encoding: .utf8),
                  !text.isEmpty else { continue }
            let digest = JobRunners.recapDigest(
                from: text,
                fallbackTitle: RecordingName.displayTitle(for: name)
            )
            guard !digest.points.isEmpty else { continue }
            let todos = TodoExtract.fromSummary(text)
                .map { RemindersSyncService.stripMarkdown($0.text) }
                .filter { !$0.isEmpty }
            let duration = await clipDuration(name)
            out.append(WatchRecap(
                id: name,
                title: digest.title,
                points: digest.points,
                todos: Array(todos.prefix(Self.recapTodoLimit)),
                recordedAt: RecordingName.date(from: name) ?? createdAt,
                createdAt: createdAt,
                duration: duration
            ))
        }
        return out
    }

    /// 这条录音有多长（秒），给「最近」那一行的暖色时长用（★ 2026-11-03 · V4 原型）。
    ///
    /// ⚠️ 只能在**手机**这边算：手表手上没有这条录音的音频文件，`WatchRecap` 里
    /// 也没有任何能推出时长的字段。探不到就返回 nil —— 腕上宁可整段省略，
    /// 也不要显示一个编出来的时长（"24:06"这种假数据比空白更糟）。
    ///
    /// 三级降级与 `LibraryView.probeDuration` 一致：Ogg 走自研页解析（AVFoundation
    /// 读不出 Opus 容器的时长），其余先试 `AVURLAsset`，再退回 `AVAudioFile` 逐帧长度
    /// （PlaudBleSDK 转出来的 VBR mp3 没有 Xing 头，`AVURLAsset` 会给不出时长）。
    static func clipDuration(_ clipName: String) async -> TimeInterval? {
        let base = (clipName as NSString).deletingPathExtension
        for ext in ["m4a", "opus", "mp3", "wav", "caf", "aac", "ogg"] {
            let url = StorageLocations.decryptedDir.appendingPathComponent("\(base).\(ext)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if ext == "opus", let seconds = OpusOgg.duration(ofOggOpusAt: url), seconds > 0 {
                return seconds
            }
            if let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
               seconds.isFinite, seconds > 0 {
                return seconds
            }
            if let file = try? AVAudioFile(forReading: url) {
                let seconds = Double(file.length) / file.processingFormat.sampleRate
                if seconds.isFinite, seconds > 0 { return seconds }
            }
        }
        return nil
    }

    /// ★ 2026-10-30：设置里的「回顾摘要」开关变化。关掉时把待发队列清空并推一次
    /// 空列表——手表收到空数组会清掉本地回顾，用户才看得出开关真的生效了。
    func setRecapEnabled(_ enabled: Bool) {
        if !enabled {
            Self.recapOutbox = []
            UserDefaults.standard.removeObject(forKey: Self.recapOutboxKey)
        }
        let face = savedFaceContext() ?? FaceContext(
            style: config.config.watchFaceStyle ?? BotFaceStyle.calm.rawValue,
            colorHex: config.config.watchEyeColor,
            blinkSpeed: config.config.watchBlinkSpeed,
            autoCycle: config.config.watchFaceAutoCycle ?? true,
            frameVisible: false  // ★ 2026-10-30：方框功能下线，恒为不显示
        )
        pushCurrentContext(face: face)
        log.info("recap enabled → \(enabled, privacy: .public)")
    }

    private static var recapOutbox: [WatchRecap] = []

    private func loadRecapOutbox() -> [WatchRecap] {
        if Self.recapOutbox.isEmpty,
           let data = UserDefaults.standard.data(forKey: Self.recapOutboxKey),
           let saved = try? JSONDecoder().decode([WatchRecap].self, from: data) {
            Self.recapOutbox = Self.prune(saved)
        }
        return Self.recapOutbox
    }

    private func savedFaceContext() -> FaceContext? {
        guard let data = UserDefaults.standard.data(forKey: Self.faceContextKey) else { return nil }
        return try? JSONDecoder().decode(FaceContext.self, from: data)
    }

    /// Cap + retention, applied identically at both ends so the two lists can't
    /// drift out of shape (numbers live on the shared `WatchRecap`).
    ///
    /// ★ 2026-11-04: 与技术表那侧同一套排序（`recordedAt` 倒序）——两端都排，
    /// 推上去的顺序才和表上显示的顺序一致，不会出现"收到推送那一下列表跳一下"。
    private static func prune(_ recaps: [WatchRecap]) -> [WatchRecap] {
        let cutoff = Date().addingTimeInterval(-WatchRecap.retention)
        return Array(
            recaps
                .filter { $0.createdAt > cutoff }
                .sorted { lhs, rhs in
                    if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt > rhs.recordedAt }
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                    return lhs.id > rhs.id
                }
                .prefix(WatchRecap.limit)
        )
    }

    /// Called with the file already copied out of the WatchConnectivity inbox.
    private func didImport(_ url: URL, size: Int) {
        library.recordDownload(name: url.lastPathComponent, size: size, transport: "watch")
        // The clip landing is proof the transfer finished, whether or not the
        // watch's own push about it ever arrives. Recording state is left
        // alone: the wrist may already be on to the next take.
        isWatchTransferring = false
        watchTransferSince = nil
        watchTransferNotice = nil
        transferWatchdog?.invalidate()
        transferWatchdog = nil
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        NotificationCenter.default.post(name: .watchClipDidArrive, object: nil)
        log.info("watch clip stored: \(url.lastPathComponent, privacy: .public) (\(size) bytes)")

        guard config.config.autoTranscribeAfterDownload else { return }
        // Same opt-in gate the device-download path uses; `tooShort` is
        // swallowed because the user accepted the duration floor when they
        // turned the toggle on.
        Task.detached { @MainActor in
            // ★ 2026-10-15: switched to going through the **queue** and waiting for it to dequeue.
            //   Going through the queue ⇒ persist to disk then start, so after the app is killed the next launch picks up from this list;
            //   waiting for dequeue ⇒ the `libraryDidChange` below still fires only after the transcription actually lands,
            //   so the Library list can bring out the transcript in one pass.
            await self.transcription.enqueueAndWait(fileURL: url, enforceMinDuration: true)
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        }
    }
}

extension WatchSyncService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        guard activationState == .activated else { return }
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        // Whatever the watch last pushed is sitting here waiting, which matters
        // on a cold launch: the app can come up mid-recording and should say so
        // immediately rather than at the next heartbeat.
        let pending = session.receivedApplicationContext
        Task { @MainActor in
            self.isActivated = true
            self.isPaired = paired
            self.isWatchAppInstalled = installed
            self.isReachable = reachable
            self.apply(watchState: pending)
            // ★ Thirteenth revision: re-push the "home-screen expression" while we're at it. This phone-side setting exists **only**
            //   on the phone side; the watch has no other way to get it, and the watch may have just been reinstalled, just switched phones,
            //   or been absent during the last push. Activation is the one moment when "the two sides are actually connected right now".
            //   ★ 2026-10-20: the other face settings (colour / blink pace / auto-cycle / frame) ride along in the same context.
            pushFaceSettings(
                style: config.config.watchFaceStyle ?? BotFaceStyle.calm.rawValue,
                colorHex: config.config.watchEyeColor,
                blinkSpeed: config.config.watchBlinkSpeed,
                autoCycle: config.config.watchFaceAutoCycle,
                frameVisible: config.config.watchFaceFrame
            )
            log.info("session activated: paired=\(paired) installed=\(installed) reachable=\(reachable)")
            // ★ 2026-11-04：激活是"两端真的连上了"的那一刻，也是补历史摘要的时机
            //   （见 `backfillRecapsIfNeeded`）。放在所有推送之后，不挡前面那几件事。
            self.backfillRecapsIfNeeded()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        Task { @MainActor in
            self.isPaired = paired
            self.isWatchAppInstalled = installed
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.isReachable = reachable }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in self.apply(watchState: applicationContext) }
    }

    /// ★ 2026-10-30（用户："支持在手表里面点击可以同步到手机的待办里面"）：
    /// 手表 Recap 详情里点了一条待办，走 `transferUserInfo` 送到这里。
    /// 写进系统「提醒事项」——权限没给就静默失败（手表端已经打了确认触感，
    /// 设置页的开关那行才是处理授权的地方）。
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let title = userInfo[WatchLinkMessage.reminderTitleKey] as? String,
              !title.isEmpty else { return }
        let source = (userInfo[WatchLinkMessage.reminderSourceKey] as? String) ?? ""
        Task { @MainActor in
            let ok = await RemindersSyncService.shared.createReminder(title: title, source: source)
            log.info("watch reminder request: \(title, privacy: .public) ok=\(ok, privacy: .public)")
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate against whichever watch is now current.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The framework deletes the inbox copy the moment this method returns,
        // so the copy has to happen here rather than on a hop to the main actor.
        let requested = (file.metadata?[WatchLinkMessage.fileNameKey] as? String)
            ?? file.fileURL.lastPathComponent
        let safeName = requested.replacingOccurrences(of: "/", with: "-")

        // ★ 2026-11-04（用户："需要在 Apple Watch 里面加入一个声纹"）：
        // 手表传上来的还有**声纹样本**——它是注册用的素材，不是一条录音，
        // 绝不能进 Library，也不能触发转写。
        if (file.metadata?[WatchLinkMessage.voiceprintKey] as? Bool) == true {
            // ★ 2026-11-06：注册完给手表一条回执（成败都回）——旧行为里手表
            // 发完样本只能停在"已发送"，没有下文。结果随下一次上下文推回。
            let resultID = Int(Date().timeIntervalSince1970)
            let sample = VoiceprintService.sampleURL(name: "sample-\(resultID).m4a")
            guard (try? FileManager.default.copyItem(at: file.fileURL, to: sample)) != nil else { return }
            Task { @MainActor in
                do {
                    try VoiceprintService.shared.enroll(from: sample, source: ClipOrigin.watch)
                    log.info("voiceprint enrolled from watch sample")
                    self.lastVoiceprintResult = (id: resultID, ok: true)
                } catch {
                    log.error("voiceprint enroll failed: \(String(describing: error), privacy: .public)")
                    self.lastVoiceprintResult = (id: resultID, ok: false)
                }
                // 立刻推而不是等下一次心跳——用户正盯着手表看。
                self.pushCurrentContext()
            }
            return
        }

        let dir = StorageLocations.decryptedDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let incomingSize = (try? file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        // A re-send of something already stored — the watch retries whenever an
        // ack goes missing — must ack again rather than land a second copy.
        let sameName = dir.appendingPathComponent(safeName)
        let storedSize = (try? sameName.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if storedSize == incomingSize {
            acknowledge(safeName)
            return
        }

        let target = AudioImporter.uniqueDestination(in: dir, originalName: safeName)
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: target)
        } catch {
            // No ack: the watch keeps its copy and offers it again, which is
            // the whole point of acking only after a successful write.
            log.error("watch clip copy failed: \(String(describing: error), privacy: .public)")
            return
        }
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // ★ 2026-11-03 八轮（手表"标记重点"）：打点随 metadata 一起到，落成 `<base>.marks.json`
        //   与转写文件同目录。写失败**不影响**入库和 ack——点丢了是小事，音频丢了是大事。
        if let marks = file.metadata?[WatchLinkMessage.marksKey] as? [Double], !marks.isEmpty {
            let url = StorageLocations.marksURL(for: target.lastPathComponent)
            if let data = try? JSONEncoder().encode(["seconds": marks]) {
                try? data.write(to: url, options: .atomic)
            }
        }
        acknowledge(safeName)
        Task { @MainActor in self.didImport(target, size: size) }
    }

    /// Queued rather than sent live so it survives both apps restarting.
    nonisolated private func acknowledge(_ name: String) {
        WCSession.default.transferUserInfo([WatchLinkMessage.storedKey: name])
    }
}
