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
    @Published private(set) var lastWatchHeartbeat: Date?

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

    /// Applies a state push from the wrist.
    private func apply(watchState context: [String: Any]) {
        guard let beat = context[WatchLinkMessage.heartbeatKey] as? Double else { return }
        isWatchRecording = context[WatchLinkMessage.recordingKey] as? Bool ?? false
        isWatchTransferring = context[WatchLinkMessage.transferPendingKey] as? Bool ?? false
        watchRecordingSince = (context[WatchLinkMessage.recordingSinceKey] as? Double)
            .map(Date.init(timeIntervalSince1970:))
        lastWatchHeartbeat = Date(timeIntervalSince1970: beat)
    }

    /// Called with the file already copied out of the WatchConnectivity inbox.
    private func didImport(_ url: URL, size: Int) {
        library.recordDownload(name: url.lastPathComponent, size: size, transport: "watch")
        // The clip landing is proof the transfer finished, whether or not the
        // watch's own push about it ever arrives. Recording state is left
        // alone: the wrist may already be on to the next take.
        isWatchTransferring = false
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        NotificationCenter.default.post(name: .watchClipDidArrive, object: nil)
        log.info("watch clip stored: \(url.lastPathComponent, privacy: .public) (\(size) bytes)")

        guard config.config.autoTranscribeAfterDownload else { return }
        // Same opt-in gate the device-download path uses; `tooShort` is
        // swallowed because the user accepted the duration floor when they
        // turned the toggle on.
        Task.detached { @MainActor in
            _ = try? await self.transcription.transcribe(fileURL: url, enforceMinDuration: true)
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
