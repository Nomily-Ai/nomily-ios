import AVFoundation
import Foundation
import Speech
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "plaud.live-asr")

/// On-device live transcript for the PLAUD card.
///
/// ## Where the audio comes from
/// The PLAUD SDK only emits audio through the **sync-file channel**: once a
/// recording is live (started by the app or attached by us) we call
/// `syncFile(sessionId:start:end:)` and the card pushes decoded PCM blocks via
/// `blePcmData`. `PlaudDirectService` meters those blocks and forwards every
/// one of them to this class through `PlaudDirectService.liveAudioSink`.
///
/// ## Why on-device speech and not the ASR provider chain
/// The provider chain (Azure / whisper server) is Opus-packet based — it takes
/// whole Opus frames and decodes them itself. PLAUD hands us **raw PCM**, which
/// no provider entry point accepts. Feeding PCM into `SFSpeech` directly is the
/// one path that works with no extra codec and no network, and it is the same
/// engine the A1's `ondevice` fallback uses, so behaviour is consistent.
/// A cloud-provider live path for PCM is a deliberate follow-up, not an
/// oversight.
///
/// ## Request lifecycle
/// `SFSpeechAudioBufferRecognitionRequest` finalizes after ~1 min of audio, so
/// after every `isFinal` result the request is rebuilt (same pattern as the A1
/// live path). Audio keeps flowing into the *new* request seamlessly.
@MainActor
final class PlaudLiveTranscriber: NSObject, ObservableObject, SFSpeechRecognizerDelegate {

    /// Growing transcript of the current recording. Finals accumulate; the
    /// in-flight hypothesis is `partial`.
    @Published private(set) var finals: [String] = []
    @Published private(set) var partial = ""
    /// Whether speech recognition actually started (permission / locale / availability).
    @Published private(set) var isActive = false

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// The card streams 16 kHz mono 16-bit PCM (same shape `exportAudio` writes).
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16_000,
                                          channels: 1,
                                          interleaved: true)

    /// Called on the main actor after every transcript mutation, so the owner
    /// can mirror the text into its own published state.
    var onTextChange: (() -> Void)?

    override private init() {
        super.init()
        recognizer = SFSpeechRecognizer()
        recognizer?.delegate = self
    }

    static func makeIfPermitted() -> PlaudLiveTranscriber? {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            log.info("plaud live asr skipped: speech not authorized")
            return nil
        }
        return PlaudLiveTranscriber()
    }

    func start() {
        guard let recognizer, recognizer.isAvailable else {
            log.info("plaud live asr unavailable (no recognizer / offline)")
            return
        }
        restartRequest()
    }

    func append(_ pcm: Data) {
        guard let request, let pcmFormat else { return }
        let frameCount = AVAudioFrameCount(pcm.count / 2)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        pcm.withUnsafeBytes { raw in
            if let dst = buffer.int16ChannelData?[0] {
                memcpy(dst, raw.baseAddress, pcm.count)
            }
        }
        request.append(buffer)
    }

    func stop() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isActive = false
    }

    private func restartRequest() {
        request?.endAudio()
        task?.cancel()
        guard let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        request = req
        isActive = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            // SFSpeech calls back on its own queue — hop to the main actor
            // instead of assuming isolation (assumeIsolated would trap).
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let result else { return }
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.finals.append(text)
                    }
                    self.partial = ""
                    // The engine finalizes on its own cadence; keep listening.
                    self.restartRequest()
                } else {
                    self.partial = text
                }
                self.onTextChange?()
            }
        }
    }

    // MARK: SFSpeechRecognizerDelegate

    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            log.info("plaud live asr availability \(available)")
            if available, self?.request == nil { self?.restartRequest() }
        }
    }
}
