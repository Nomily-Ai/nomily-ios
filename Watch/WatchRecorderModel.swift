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
            guard newRecorder.record() else { throw RecorderError.couldNotStart }
            recorder = newRecorder
            elapsed = 0
            currentBytes = 0
            isRecording = true
            startedAt = Date()
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
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                self.elapsed = recorder.currentTime
                self.currentBytes = Self.size(of: recorder.url)
                if Date().timeIntervalSince(self.lastPush) >= Self.heartbeatInterval {
                    self.pushState()
                }
            }
        }
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
