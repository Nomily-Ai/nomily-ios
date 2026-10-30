import Foundation
import WatchConnectivity
import os.log

private let log = Logger(subsystem: "com.nomily.app.watch", category: "link")

/// Watch half of the link to the iPhone: recordings out, store-confirmations
/// back. Nothing else crosses — the wrist doesn't ask the phone about the Nomi.
@MainActor
final class WatchLink: NSObject, ObservableObject {
    /// Names currently sitting in WatchConnectivity's transfer queue.
    @Published private(set) var queuedNames: Set<String> = []
    /// Names WatchConnectivity says it delivered, still waiting on the phone to
    /// confirm it wrote them. Until a clip clears both, the wrist copy is the
    /// only one that definitely exists.
    @Published private(set) var deliveredNames: Set<String> = []
    /// ★ 2026-10-30（用户："录音断联需要状态弹出提醒告知"）：手机当前是否可达。
    ///
    /// ⚠️ 语义提醒：`isReachable` 要求**对端 App 在前台**——手机 App 退到后台
    /// 后这里就会变 false，哪怕蓝牙还连着、transferFile 照样能送达。所以这个
    /// 值只用于「提醒用户」场景（见 `WatchRecorderModel.handleReachability`），
    /// 不参与任何传输判断——传输走的是后台队列，从来不依赖可达性。
    @Published private(set) var phoneReachable = false
    /// 可达性变化回调（true = 手机回到前台/重新可达）。
    var onReachabilityChanged: ((Bool) -> Void)?

    /// Fired when the phone confirms the clip is stored — not merely that
    /// WatchConnectivity delivered the bytes — so the recorder can drop the
    /// watch-side copy.
    var onStored: ((String) -> Void)?
    #if targetEnvironment(simulator)
    /// Completion receipt for simulator-only delivery. On a real device the equivalent is `onStored` (the phone-side
    /// `transferUserInfo` ack); on the simulator, once the file lands in the shared inbox it counts as delivered.
    var onSimulatorDelivered: ((String) -> Void)?
    #endif
    /// Fired when the session goes live. Anything queued before that point was
    /// dropped on the floor, so the recorder re-offers whatever is still local.
    var onActivated: (() -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Queues a clip for the phone. Safe to call repeatedly — a clip already in
    /// the queue isn't sent twice, and the phone de-duplicates re-sends.
    func transfer(_ url: URL) {
        #if targetEnvironment(simulator)
        transferViaSimulatorSharedInbox(url)
        #else
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        let name = url.lastPathComponent
        guard !queuedNames.contains(name) else { return }
        WCSession.default.transferFile(url, metadata: [WatchLinkMessage.fileNameKey: name])
        refreshQueue()
        // ★ Record-keeping. The size is taken here (the file is still around); the `didFinish` step no longer can.
        WatchTransferLog.shared.noteQueued(name: name, bytes: Self.fileSize(of: url))
        log.info("queued \(name, privacy: .public) for the iPhone")
        #endif
    }

    /// File byte count. 0 if it can't be read — showing 0 KB in the record beats the whole entry not showing up.
    private static func fileSize(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

#if targetEnvironment(simulator)
    /// Simulator-only delivery. **This block does not exist in real-device builds.**
    ///
    /// ## Why (2026-10-14)
    /// Apple's official API docs state that the simulator does not support `transferFile(_:metadata:)`
    /// (original text and measured evidence in the same-named comment in `WatchSyncService` and
    /// `WATCH-SIMULATOR-FINDINGS.md`). Observed symptom: the `didFinish` callback has error=nil and
    /// `reportFileTransfer success=1` (`durationSec=0`), yet the phone **never receives** it
    /// -- a false success, the nastiest kind.
    ///
    /// ## How
    /// Both simulators run on the same Mac and can read/write `/tmp`, so the file is dropped straight into
    /// the shared spot `/tmp/nomily-watch-inbox/`; the phone-side inbox watcher (also simulator-only)
    /// picks it up and runs the **exact same** import path as a real device (`didImport`).
    ///
    /// ## Differences from real-device semantics (intentional)
    /// On a real device the local copy is deleted only after the phone's `transferUserInfo` ack (`onStored`);
    /// the simulator has no such receipt path, so the local copy is **deleted once it lands in the shared spot**, i.e. delivery is assumed.
    /// `onSimulatorDelivered` refreshes the pending list.
    private func transferViaSimulatorSharedInbox(_ url: URL) {
        let inbox = URL(fileURLWithPath: "/tmp/nomily-watch-inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let target = inbox.appendingPathComponent(url.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: url, to: target)
        } catch {
            // If delivery fails, delete nothing: the file stays in pending, and the user's retry comes through here again.
            log.error("simulator transfer failed: \(String(describing: error), privacy: .public)")
            return
        }
        log.info("simulator transfer: \(target.path, privacy: .public)")
        onSimulatorDelivered?(url.lastPathComponent)
    }
#endif

    /// Tells the phone what the recorder is doing. Fire-and-forget: a failed
    /// push is replaced by the next beat 10 s later, and the phone treats
    /// silence as staleness rather than as "stopped".
    func pushState(isRecording: Bool, since: Date?, transferPending: Bool) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        var context: [String: Any] = [
            WatchLinkMessage.recordingKey: isRecording,
            WatchLinkMessage.transferPendingKey: transferPending,
            WatchLinkMessage.heartbeatKey: Date().timeIntervalSince1970
        ]
        if let since {
            context[WatchLinkMessage.recordingSinceKey] = since.timeIntervalSince1970
        }
        do {
            try WCSession.default.updateApplicationContext(context)
        } catch {
            log.error("state push failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func refreshQueue() {
        guard WCSession.isSupported() else { return }
        queuedNames = Set(
            WCSession.default.outstandingFileTransfers.map { $0.file.fileURL.lastPathComponent }
        )
    }

    /// 把一条待办发回手机，让手机写进系统「提醒事项」（★ 2026-10-30）。
    ///
    /// 走 `transferUserInfo` 而不是 `sendMessage`：这是一次**事件**，不能因为
    /// 手机此刻不可达就丢掉——排队等手机下次醒来照样送达。手表端不等待回执，
    /// 点击时先给一个触感反馈（用户要的是"点到了"）。
    func requestReminder(title: String, source: String) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        var info: [String: Any] = [WatchLinkMessage.reminderTitleKey: title]
        if !source.isEmpty { info[WatchLinkMessage.reminderSourceKey] = source }
        WCSession.default.transferUserInfo(info)
        log.info("reminder requested: \(title, privacy: .public)")
    }

    /// Take in the face settings pushed from the phone.
    ///
    /// ★ Added in the thirteenth revision (expression), ★ extended 2026-10-20
    ///   (colour / blink pace / auto-cycle / square frame). This is the **only** appearance
    ///   setting on the phone that actively pushes to the watch; the reasoning and the choice
    ///   (why it goes through `updateApplicationContext`) are written in
    ///   the block at `WatchLinkMessage.faceStyleKey`.
    ///
    /// ⚠️ Unrecognised values are silently dropped by `WatchFaceStore` (the two ends' versions may differ),
    ///    so this validates nothing and reports nothing — that's the store's business; here we just move it along.
    private func apply(remoteContext context: [String: Any]) {
        WatchFaceStore.shared.apply(context[WatchLinkMessage.faceStyleKey] as? String)
        WatchFaceStore.shared.applySettings(context)
        // ★ 2026-10-23: recaps ride in the same context (one slot, everything
        // travels together — see `WatchLinkMessage.recapsKey`). The store is
        // indifferent to missing keys, so an old phone's context is harmless.
        WatchRecapStore.shared.apply(context)
        applyTimedRecordCommand(context)
    }

    // MARK: - Timed recording command (phone → watch, ★ 2026-10-30)

    /// 手机定时录音命令到达时回调（`"start"` / `"stop"`）。由 `NomilyWatchApp`
    /// 接到 `WatchRecorderModel` 上。
    var onTimedRecordCommand: ((_ command: String, _ issuedAt: Date, _ endsAt: Date?) -> Void)?

    /// 最近一次收到的命令。保留它（而不是用完即弃）是因为 watchOS 的麦克风
    /// 只在前台可用：命令可能在后台送达、开录失败——抬腕进 App 时
    /// `retryUnconfirmedTimedCommand` 会补执行。
    private(set) var lastTimedCommand: (command: String, issuedAt: Date, endsAt: Date?)?

    private func applyTimedRecordCommand(_ context: [String: Any]) {
        guard let command = context[WatchLinkMessage.timedRecordCommandKey] as? String,
              let issued = context[WatchLinkMessage.timedRecordIssuedAtKey] as? Double
        else { return }
        let issuedAt = Date(timeIntervalSince1970: issued)
        let endsAt = (context[WatchLinkMessage.timedRecordEndsAtKey] as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        lastTimedCommand = (command, issuedAt, endsAt)
        onTimedRecordCommand?(command, issuedAt, endsAt)
    }

    /// App 变为前台（scenePhase → active）时调用：最后一次 "start" 若还没录上
    /// （后台送达 / 麦克风权限未决），现在补开。由回调方用闭包判断要不要真的
    /// 重试——start 本身幂等，重复派发无害。
    func retryUnconfirmedTimedCommand(retryIf: () -> Bool) {
        guard let command = lastTimedCommand, command.command == "start" else { return }
        // 窗口早结束了还补什么——扔掉。
        if let endsAt = command.endsAt, Date() > endsAt.addingTimeInterval(300) {
            lastTimedCommand = nil
            return
        }
        guard retryIf() else { return }
        onTimedRecordCommand?(command.command, command.issuedAt, command.endsAt)
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let activated = activationState == .activated
        // ★ Thirteenth revision: the last context the phone pushed is lying in `receivedApplicationContext`
        //   waiting — read it once on a cold launch, otherwise the face on the watch draws the default expression first and
        //   sits there until the phone's next push, only then jumping to the style the user chose.
        //   (The phone side likewise reads `receivedApplicationContext` on activation to get the recording state,
        //    see `WatchSyncService`.)
        let pending = session.receivedApplicationContext
        Task { @MainActor in
            self.refreshQueue()
            self.phoneReachable = session.isReachable
            self.apply(remoteContext: pending)
            if activated { self.onActivated?() }
        }
    }

    /// ★ 2026-10-30: 手机进出前台/蓝牙范围时系统回调。只更新可达性状态——
    /// 传输从不依赖它（transferFile 的后台队列自己会等），消费方是录音模型
    /// 的「断联提醒」逻辑。
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.phoneReachable = reachable
            self.onReachabilityChanged?(reachable)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let name = userInfo[WatchLinkMessage.storedKey] as? String else { return }
        Task { @MainActor in
            log.info("iPhone stored \(name, privacy: .public)")
            self.deliveredNames.remove(name)
            WatchTransferLog.shared.noteStored(name: name)
            self.onStored?(name)
        }
    }

    /// The "current value" pushed from the phone (★ thirteenth revision: now the home-screen expression).
    ///
    /// ⚠️ It **won't** fight the watch's own `updateApplicationContext` (the recording state):
    ///    application context has **one slot per direction**, so what the watch sends out won't
    ///    be overwritten by what the phone sends in.
    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in self.apply(remoteContext: applicationContext) }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: (any Error)?
    ) {
        let name = fileTransfer.file.fileURL.lastPathComponent
        Task { @MainActor in
            self.refreshQueue()
            // ★ Failures get accounted too. This is the **only** moment the failure reason is visible —
            //    `didFinish`'s `error` used to go only into os_log, and logs can't be read on the watch,
            //    so all the user saw was "that one stuck in pending forever".
            WatchTransferLog.shared.noteFinished(name: name, error: error)
            guard error == nil else {
                log.error("transfer of \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return
            }
            // Delivered to the phone's daemon — not yet stored by the app. The
            // clip stays on the wrist until the ack in `didReceiveUserInfo`.
            log.info("delivered \(name, privacy: .public), awaiting store confirmation")
            self.deliveredNames.insert(name)
        }
    }
}
