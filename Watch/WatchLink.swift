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
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        let name = url.lastPathComponent
        guard !queuedNames.contains(name) else { return }
        WCSession.default.transferFile(url, metadata: [WatchLinkMessage.fileNameKey: name])
        refreshQueue()
        log.info("queued \(name, privacy: .public) for the iPhone")
    }

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
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let activated = activationState == .activated
        Task { @MainActor in
            self.refreshQueue()
            if activated { self.onActivated?() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let name = userInfo[WatchLinkMessage.storedKey] as? String else { return }
        Task { @MainActor in
            log.info("iPhone stored \(name, privacy: .public)")
            self.deliveredNames.remove(name)
            self.onStored?(name)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: (any Error)?
    ) {
        let name = fileTransfer.file.fileURL.lastPathComponent
        Task { @MainActor in
            self.refreshQueue()
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
