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
            log.info("sim inbox delivered \(target.lastPathComponent, privacy: .public)")
            Task { @MainActor in self.didImport(target, size: size) }
        }
    }
#endif

    /// Applies a state push from the wrist.
    private func apply(watchState context: [String: Any]) {
        guard let beat = context[WatchLinkMessage.heartbeatKey] as? Double else { return }
        isWatchRecording = context[WatchLinkMessage.recordingKey] as? Bool ?? false
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
    private func pushCurrentContext(face: FaceContext? = nil) {
        guard WCSession.isSupported() else { return }
        let resolvedFace = face ?? savedFaceContext()
        guard let resolvedFace else { return }
        var context: [String: Any] = [
            WatchLinkMessage.faceStyleKey: resolvedFace.style,
            WatchLinkMessage.faceAutoCycleKey: resolvedFace.autoCycle,
            WatchLinkMessage.faceFrameKey: resolvedFace.frameVisible,
        ]
        if let colorHex = resolvedFace.colorHex {
            context[WatchLinkMessage.faceColorKey] = colorHex
        }
        if let blinkSpeed = resolvedFace.blinkSpeed {
            context[WatchLinkMessage.blinkSpeedKey] = blinkSpeed
        }
        if let data = try? JSONEncoder().encode(loadRecapOutbox()) {
            context[WatchLinkMessage.recapsKey] = data
        }
        // ★ 2026-10-30：定时录音命令随完整上下文一起走（持久化了，所以手机
        // 重启后的任何一次推送都会带上；手表端按 issuedAt 去重，重发无害）。
        if let command = Self.loadTimedCommand() {
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
        recordedAt: Date
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
                createdAt: Date()
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
    private static func prune(_ recaps: [WatchRecap]) -> [WatchRecap] {
        let cutoff = Date().addingTimeInterval(-WatchRecap.retention)
        return Array(recaps.filter { $0.createdAt > cutoff }.prefix(WatchRecap.limit))
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
        acknowledge(safeName)
        Task { @MainActor in self.didImport(target, size: size) }
    }

    /// Queued rather than sent live so it survives both apps restarting.
    nonisolated private func acknowledge(_ name: String) {
        WCSession.default.transferUserInfo([WatchLinkMessage.storedKey: name])
    }
}
