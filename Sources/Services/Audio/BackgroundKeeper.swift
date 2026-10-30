import AVFoundation
import Foundation
import os.log
import UIKit

private let log = Logger(subsystem: "com.nomily.app.ios", category: "background")

/// Keeps the App from being suspended by the system while **jobs are in flight**.
///
/// Why this class exists: transcription and summary are jobs lasting tens of seconds to over ten minutes, and the moment the user switches away
/// (a glance at WeChat, locking the screen), the App enters `.suspended`, the URLSession request is cut off,
/// and you come back to a failure — that's the bulk of "transcription fails several times".
///
/// Two layers stacked:
///
/// 1. `UIApplication.beginBackgroundTask` — buys only about 30 seconds of grace.
///    Costs nothing, needs no permissions, and is correct at any time. It's the layer that's always on.
/// 2. A **looping silent** `AVAudioPlayer` running on a `.playback` session.
///    Together with the `audio` background mode already declared in Info.plist, the process can stay alive.
///    `LiveModel` was already using this trick while recording (from line 1544 there); here it's just
///    **lifted into one place to manage** — otherwise two independent silent players would fight over the same
///    `AVAudioSession`, and whoever calls `setActive(false)` first cuts off the other.
///
/// Counting with **tokens** rather than a raw count: the recording path's lifetime is "recording && in the background",
/// the transcription path's is "the job isn't done yet", the two overlap, and each must be able to release independently without hurting the other.
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    /// Who's holding it. Add a case here for a new scenario; don't start a whole new mechanism.
    enum Token: String, CaseIterable {
        /// Live recording — held by `LiveModel` when "recording && switched to the background".
        case recording
        /// Batch transcription (ASR).
        case transcription
        /// Summary / translation and other long LLM jobs.
        case summary
        /// Exporting audio (copying / re-encoding large files).
        ///
        /// ★ 2026-10-15 revision six: the user's own words were "exporting audio takes a very long time for large files
        /// and it needs to run in the background". Export and transcription are **the same kind** of problem (suspended half-way),
        /// so they share this one setup rather than starting another.
        case export
        /// ★ 2026-10-29 (饭耳移植 · 规格 §3.1): timed overnight recording — held by
        /// `TimedRecordingScheduler` for the whole scheduled window so the mic
        /// engine survives suspension without any screen in the foreground.
        case timedRecording
    }

    /// Mirrors `config.backgroundKeepAliveEnabled`. When off, only the ~30 seconds of
    /// `beginBackgroundTask` grace remains — short recordings still finish in the background, long ones get cut off.
    /// Why there's a toggle: layer 2 is "fool the background with silent audio", and users who don't want to be fooled by that
    /// should have the right to turn it off.
    var audioKeepAliveEnabled = true {
        didSet {
            guard audioKeepAliveEnabled != oldValue else { return }
            if audioKeepAliveEnabled {
                if !active.isEmpty { startAudio() }
            } else {
                stopAudio()
            }
        }
    }

    private(set) var active: Set<Token> = []

    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Tokens

    func isHeld(_ token: Token) -> Bool { active.contains(token) }

    func acquire(_ token: Token) {
        guard active.insert(token).inserted else { return }
        log.info("acquire \(token.rawValue, privacy: .public) → \(self.active.count) held")
        beginAssertion()
        if audioKeepAliveEnabled { startAudio() }
    }

    func release(_ token: Token) {
        guard active.remove(token) != nil else { return }
        log.info("release \(token.rawValue, privacy: .public) → \(self.active.count) held")
        guard active.isEmpty else { return }
        stopAudio()
        endAssertion()
    }

    /// Give a clean wrap-up before exit (also helps a self-check script reconcile).
    func releaseAll() {
        active.removeAll()
        stopAudio()
        endAssertion()
    }

    // MARK: - Layer 1: the background task assertion

    private func beginAssertion() {
        guard taskID == .invalid else { return }
        taskID = UIApplication.shared.beginBackgroundTask(withName: "com.nomily.work") { [weak self] in
            // Reaching here means the 30-second grace ran out. With silent audio holding it up that shouldn't happen;
            // if it really does (the user turned audio keep-alive off) the token must be returned immediately, otherwise
            // the system will simply kill the process (and a kill leaves no log at all).
            Task { @MainActor [weak self] in
                guard let self else { return }
                log.warning("background assertion expired with \(self.active.count) token(s) held")
                self.endAssertion()
            }
        }
        log.info("background assertion \(self.taskID.rawValue) started")
    }

    private func endAssertion() {
        guard taskID != .invalid else { return }
        let id = taskID
        taskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
        log.info("background assertion \(id.rawValue) ended")
    }

    // MARK: - Layer 2: silent-audio keep-alive

    private func startAudio() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // `.mixWithOthers`: the user's own music/podcasts shouldn't be cut off by us.
            // What we play is pure silence, so mixing in can't be heard.
            try session.setCategory(.playback, options: .mixWithOthers)
            try session.setActive(true)
            let p = try AVAudioPlayer(data: Self.silentWavData(), fileTypeHint: AVFileType.wav.rawValue)
            p.numberOfLoops = -1
            p.volume = 0
            p.play()
            player = p
            observeInterruptions()
            log.info("silent audio started")
        } catch {
            // Failing to get the session doesn't mean the job can't run — the 30-second assertion still covers it, and short jobs still finish.
            log.warning("silent audio failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopAudio() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        log.info("silent audio stopped")
    }

    /// An incoming call/alarm interrupts our silent player, and after the interruption it **won't come back on its own**.
    /// Without this patch-up, the user finishes the call and finds transcription already cut off halfway.
    private func observeInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.ended.rawValue else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.active.isEmpty, self.player == nil else { return }
                self.startAudio()
            }
        }
    }

    /// 1 second of silence: 8 kHz mono 16-bit PCM WAV (16 044 bytes).
    /// Small enough to live in memory, and looping means it never stops.
    /// (Byte-for-byte identical to `LiveModel`'s original one, keeping the two in line.)
    private static func silentWavData() -> Data {
        let sampleRate: UInt32 = 8000
        let numSamples: UInt32 = sampleRate
        let dataSize = numSamples * 2
        var d = Data()
        func u32le(_ v: UInt32) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func u16le(_ v: UInt16) { d.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        d.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        u32le(36 + dataSize)
        d.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        d.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        u32le(16)
        u16le(1)                    // PCM
        u16le(1)                    // mono
        u32le(sampleRate)
        u32le(sampleRate * 2)       // byte rate
        u16le(2)                    // block align
        u16le(16)                   // bits per sample
        d.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        u32le(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
