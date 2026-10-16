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

/// The live level the waveform needs while recording.
///
/// ★ added in the 2026-10-16 ninth revision (user: "when recording starts it should be a waveform like the heart rate").
///
/// ## Why not two separate values
/// It could have been split into `level: Float` + `tick: Int` as two `@Published`s, but then every tick
/// would fire two rounds of object changes. Combining them into one `Equatable` struct means the view side needs just one
/// `onChange(of: meter)`.
///
/// ## ⚠️ `tick` isn't superfluous
/// **When quiet, `level` is always 0, so `onChange(of: level)` never fires at all** —
/// and the waveform would freeze there, killing the "heartbeat". With a monotonically increasing `tick`, the waveform advances
/// one slot per tick and keeps moving even when quiet.
struct WatchAudioMeter: Equatable {
    /// The instantaneous level normalised to 0...1.
    var level: Float = 0
    /// A monotonically increasing sample index. See the block above — its only reason to exist is so that "something changes" even when quiet.
    var tick: Int = 0
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
    /// The live level while recording, for the home screen's waveform. **It only changes while recording** —
    /// it's zeroed on stop, so the idle state doesn't push the view to redraw a dozen times a second.
    @Published private(set) var meter = WatchAudioMeter()
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

    /// The level meter's sampling interval — 12.5Hz.
    ///
    /// ★ 2026-10-16 revision nine: this meter used to tick at **1 second** (just to refresh the timer). A 1-second refresh rate
    /// can't draw a waveform: the waveform would only move one slot per tick, looking like a slideshow rather than sound.
    ///
    /// ⚠️ 12.5Hz is a considered trade-off: faster (30Hz) is indistinguishable to the eye on a 40mm watch, yet more than
    /// doubles the redraw cost; slower starts to feel juddery, "jumping a slot at a time".
    private static let meterInterval: TimeInterval = 0.08

    /// The reciprocal of `meterInterval`. Used to pick the "once a second" part of the work (timer, byte count)
    /// out of the 12.5Hz tick.
    private static let meterTicksPerSecond = 12

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
        #if targetEnvironment(simulator)
        // Simulator-only delivery has no transferUserInfo ack path; once the file lands in the shared inbox
        // it counts as delivered (see `WatchLink.transferViaSimulatorSharedInbox`).
        // Reuse `discard`: it already does reloadPending + pushState, so the pending list
        // and the phone-side state are cleared together.
        link.onSimulatorDelivered = { [weak self] name in self?.discard(named: name) }
        #endif
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
        // ★ Diagnostic log added 2026-10-14 -- do not delete, see the comment on `consumePendingToggle`.
        //
        // Origin: on the watchOS simulator the app starts recording by itself right after `launch`
        // (real-device log shape: `14:11:15.565 [recorder] recording to <stamp>.m4a`
        // appears less than 1 second after launch, and 1.1 seconds later `queued` is sent out).
        // Yet the line `toggling from the Action Button intent` in `consumePendingToggle`
        // **never appeared even once** -- meaning `RecordingIntentBus.pendingToggle` was false,
        // i.e. it was **not** the Action Button path. The only remaining entry point is this function.
        // This line answers "how many times was it called, and what state was it in each time".
        log.info("toggleRecording: isRecording=\(self.isRecording, privacy: .public)")
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
            // ★ 2026-10-16 revision nine: enable the level meter. Left off, `averagePower` always returns -160,
            //   the home screen's waveform becomes a dead line — when its one job is exactly to prove "it's recording".
            newRecorder.isMeteringEnabled = true
            guard newRecorder.record() else { throw RecorderError.couldNotStart }
            recorder = newRecorder
            elapsed = 0
            currentBytes = 0
            meter = WatchAudioMeter()
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
        // Zero it rather than leave the last slot: after stopping, the home screen must switch back to the eyes immediately,
        // and keeping a level value would make the waveform flash once before it disappears.
        meter = WatchAudioMeter()
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
        // ⚠️ This counter is **for the closure**: the tick rate is 12.5Hz, but the timer and byte count
        //    only need to be once a second (`size(of:)` does a stat on the file, and running it 12 times for nothing is wasteful,
        //    and the displayed granularity is seconds anyway).
        var ticks = 0
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.meterInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                ticks += 1
                self.sampleMeter(recorder, tick: ticks)
                guard ticks % Self.meterTicksPerSecond == 0 else { return }
                self.elapsed = recorder.currentTime
                self.currentBytes = Self.size(of: recorder.url)
                if Date().timeIntervalSince(self.lastPush) >= Self.heartbeatInterval {
                    self.pushState()
                }
            }
        }
    }

    /// Read the level once and write it into `meter`.
    ///
    /// ## Why dBFS is clamped at -50
    /// `averagePower` gives **dBFS** (0 = full scale, the more negative the quieter). On the watch, talking softly
    /// from tens of centimetres away lands around -50dB, while a quiet room's noise floor is below -65dB.
    /// Putting the floor at -50 keeps the noise floor from drawing any wave — otherwise the line would jitter constantly and the user would think
    /// the microphone is picking something up.
    ///
    /// ## Why it rises fast and falls slow
    /// The first syllable of speech must shoot up **immediately** (or the user will suspect nothing was recorded), but if it
    /// fell back within 80ms a single syllable would be torn into several fragments of noise. So the rise follows directly, and the fall slides
    /// at a fixed speed — 0.14 per slot, about 0.6 seconds to slide from full scale back to the floor.
    private func sampleMeter(_ recorder: AVAudioRecorder, tick: Int) {
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        let floorDb: Float = -50
        let raw = max(0, min(1, (db - floorDb) / -floorDb))
        let next = raw > meter.level ? raw : max(raw, meter.level - 0.14)
        meter = WatchAudioMeter(level: next, tick: tick)
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
