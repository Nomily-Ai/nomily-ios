import AVFoundation
import Combine
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "playback")

/// AVPlayer-backed playback for the Clip-detail screen. Supports
/// Ogg-Opus (iOS 17+, system-provided decoder) and WAV (any iOS).
///
/// `AVAudioPlayer.currentTime = X` silently fails to seek inside an
/// Ogg container — iOS 17 added Opus *decode* but AVAudioPlayer has no
/// granule-position seek index, so a mid-playback seek was resetting
/// the stream. AVPlayer's `seek(to:CMTime,tolerance…)` uses AVAsset's
/// proper seek pipeline (Ogg page walk) and lands on the requested
/// frame. On iOS 16 the item transitions to `.failed` and the UI
/// surfaces the error instead of silently looping the first second.
@MainActor
final class AudioPlaybackController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var loadError: String?

    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    private var loadedURL: URL?
    /// True between `seek(to:)` and its completion — the periodic time
    /// observer still reports the *old* position during that window and
    /// would snap the slider back to it.
    private var isSeeking = false
    /// True while the user drags the slider. Playback is paused for the
    /// duration so the UI and the audio can't disagree.
    private var resumeAfterScrub = false

    func load(_ url: URL) {
        if loadedURL == url { return }
        loadedURL = url

        // iOS 16 has no Ogg-Opus decoder. Don't spin up a doomed AVPlayer
        // (which would leave a dead play button with no explanation) —
        // surface a clear prompt and skip playback. Only playback is
        // affected; transcription (async/live) doesn't decode locally.
        if url.pathExtension.lowercased() == "opus", #unavailable(iOS 17.0) {
            cleanupObservers()
            player = nil
            item = nil
            isPlaying = false
            currentTime = 0
            duration = 0
            loadError = L10n.ClipDetail.opusPlaybackUnsupported
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.warning("audio session activate failed: \(String(describing: error), privacy: .public)")
        }

        cleanupObservers()

        let newItem = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: newItem)
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        self.item = newItem
        self.player = newPlayer
        self.isPlaying = false
        self.currentTime = 0
        self.duration = 0
        self.loadError = nil

        statusObserver = newItem.observe(\.status, options: [.new, .initial]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self else { return }
                switch observedItem.status {
                case .readyToPlay:
                    let d = observedItem.duration.seconds
                    if d.isFinite && d > 0 {
                        self.duration = d
                    }
                case .failed:
                    log.error("playback load failed url=\(url.lastPathComponent, privacy: .public) err=\(String(describing: observedItem.error), privacy: .public)")
                    self.player = nil
                    self.item = nil
                    self.duration = 0
                    self.currentTime = 0
                    self.loadError = L10n.ClipDetail.opusPlaybackUnsupported
                default:
                    break
                }
            }
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                // Ignore ticks in flight around a seek: they still carry the
                // pre-seek position and make the slider jump backwards.
                guard !self.isSeeking else { return }
                let t = time.seconds
                if t.isFinite { self.currentTime = t }
            }
        }

        // Anything that stops the audio without going through `pause()` —
        // another app taking the audio session, a route change, a stall —
        // must be reflected in `isPlaying`, otherwise the UI keeps showing
        // a pause button for audio that is no longer playing.
        rateObserver = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.player === observed else { return }
                let playing = observed.timeControlStatus != .paused
                if self.isPlaying != playing { self.isPlaying = playing }
            }
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                // Don't auto-resume: the user switched to another audio app
                // on purpose. Just stop claiming we're still playing.
                if type == .began { self.isPlaying = false }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.seek(to: 0)
            }
        }
    }

    func play() {
        guard let player else { return }
        // Parked at the end (played through, or scrubbed there before ever
        // pressing play): start over instead of pressing play on a player
        // that has nothing left to decode and never moves.
        if duration > 0, currentTime >= duration - 0.15 {
            seek(to: 0) { [weak self] in self?.player?.play() }
        } else {
            player.play()
        }
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to time: TimeInterval, completion: (() -> Void)? = nil) {
        guard let player else { completion?(); return }
        let target = max(0, min(time, duration))
        let cm = CMTime(seconds: target, preferredTimescale: 600)
        isSeeking = true
        currentTime = target
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                completion?()
            }
        }
    }

    /// User grabbed the slider. Pause while dragging so the frozen progress
    /// bar and the audio agree — previously the bar stopped where the finger
    /// went down while the audio kept playing underneath.
    func beginScrub() {
        guard let player else { return }
        resumeAfterScrub = isPlaying
        if isPlaying {
            player.pause()
            isPlaying = false
        }
    }

    /// User let go: land on the requested position, then resume if we were
    /// playing when the drag started.
    func endScrub(at time: TimeInterval) {
        let shouldResume = resumeAfterScrub
        resumeAfterScrub = false
        seek(to: time) { [weak self] in
            guard let self, shouldResume, let player = self.player else { return }
            // Deliberately not `play()`: dropping the thumb at the very end
            // should leave it there, not restart the clip.
            player.play()
            self.isPlaying = true
        }
    }

    func stop() {
        player?.pause()
        cleanupObservers()
        player = nil
        item = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        isSeeking = false
        resumeAfterScrub = false
        loadedURL = nil
    }

    private func cleanupObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        rateObserver?.invalidate()
        rateObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
    }
}
