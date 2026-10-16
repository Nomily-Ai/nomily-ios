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
        isWatchTransferring = context[WatchLinkMessage.transferPendingKey] as? Bool ?? false
        watchRecordingSince = (context[WatchLinkMessage.recordingSinceKey] as? Double)
            .map(Date.init(timeIntervalSince1970:))
        lastWatchHeartbeat = Date(timeIntervalSince1970: beat)
    }

    // MARK: - Home-screen expression (★ 2026-10-16 thirteenth revision)

    /// The user changed the "watch home-screen eye expression" in Settings — push it to the watch at once.
    ///
    /// ⚠️ **Deliberately doesn't check reachability** (`session.isReachable`): when unreachable,
    ///    `updateApplicationContext` leaves this context in the daemon
    ///    and hands it over the next time the watch wakes. Checking reachability would instead treat "the watch is in the background right now" as a failure,
    ///    so the user changes the setting, raises their wrist, and finds nothing changed.
    func sendFaceStyle(_ tag: String) {
        pushFaceStyle(tag)
    }

    /// The style in use on the watch — re-pushed once on activation, closing the window where
    /// "what's stored on the watch differs from the phone" (the user switched phones, reinstalled the watch app, or a previous push never arrived).
    private func pushFaceStyle(_ tag: String) {
        guard WCSession.isSupported() else { return }
        do {
            try WCSession.default.updateApplicationContext([WatchLinkMessage.faceStyleKey: tag])
            log.info("face style pushed: \(tag, privacy: .public)")
        } catch {
            // You reach here when the session hasn't activated yet. The activation callback pushes again, so this time
            // failing isn't fatal — a log line is enough; don't show the user anything.
            log.error("face style push failed: \(String(describing: error), privacy: .public)")
        }
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
            self.pushFaceStyle(self.config.config.watchFaceStyle ?? BotFaceStyle.calm.rawValue)
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
