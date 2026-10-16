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
        // ★ 记账。大小在这里取（文件还在），`didFinish` 那一步就取不到了。
        WatchTransferLog.shared.noteQueued(name: name, bytes: Self.fileSize(of: url))
        log.info("queued \(name, privacy: .public) for the iPhone")
        #endif
    }

    /// 文件字节数。取不到就 0 —— 记录里显示 0 KB 好过整条不出现。
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

    /// 收下手机推来的"首页表情"。
    ///
    /// ★ 十三改新增。这是手机上**唯一**会主动推给手表的外观设置，
    /// 理由与选型（为什么走 `updateApplicationContext`）写在
    /// `WatchLinkMessage.faceStyleKey` 那段。
    ///
    /// ⚠️ 不认识的值会被 `WatchFaceStore.apply` 静默丢掉（两端版本可以不一致），
    ///    所以这里不判合法性、也不报错 —— 那是 store 的事，这里只管搬运。
    private func apply(remoteContext context: [String: Any]) {
        WatchFaceStore.shared.apply(context[WatchLinkMessage.faceStyleKey] as? String)
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let activated = activationState == .activated
        // ★ 十三改：手机最后推来的那份 context 就躺在 `receivedApplicationContext`
        //   里等着 —— 冷启动时先把它读一遍，否则表上的脸会先画默认表情、
        //   一直等到手机下一次推送才跳成用户选的那一档。
        //   （手机侧同样在激活时读 `receivedApplicationContext` 拿录音状态，
        //    见 `WatchSyncService`。）
        let pending = session.receivedApplicationContext
        Task { @MainActor in
            self.refreshQueue()
            self.apply(remoteContext: pending)
            if activated { self.onActivated?() }
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

    /// 手机推来的"当前值"（★ 十三改：现在是首页表情）。
    ///
    /// ⚠️ 和手表自己那条 `updateApplicationContext`（录音状态）**不会**打架：
    ///    application context 是**按方向各有一个槽位**的，手表发出去的不会
    ///    被手机发进来的覆盖。
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
            // ★ 失败也要记账。这是**唯一**能看到失败原因的时机 ——
            //    `didFinish` 的 `error` 以前只写进 os_log，而手表上读不到日志，
            //    用户看到的只是"那条一直卡在待传里"。
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
