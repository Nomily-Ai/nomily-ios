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
