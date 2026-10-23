import Foundation

/// Why a live engine cannot produce text. Surfaced verbatim in the UI, because
/// "no text" has several very different causes and only some are the user's to
/// fix.
enum PlaudLiveASRUnavailable: Equatable {
    case notAuthorized
    case noRecognizer
    /// The on-device model for this language is not installed.
    case modelMissing
    /// Azure is configured as the provider but the key/region is incomplete.
    case azureMissing
    /// The Azure socket closed (bad key, quota, network).
    case azureFailed(String)
    /// ★ 2026-10-23: Aliyun real-time — credentials/Appkey incomplete.
    case aliyunMissing
    /// ★ 2026-10-23: the Aliyun socket reported a failure (token, quota, network).
    case aliyunFailed(String)
}

/// A live transcription engine fed with the PLAUD card's **raw PCM**.
///
/// ## Why this abstraction exists (2026-10-22)
/// The live transcript used to be hard-wired to Apple's on-device recogniser.
/// The user's config says **Azure**, and that is what they expect to hear from
/// the text: `SFSpeech`'s offline model is noticeably weaker (worse punctuation,
/// more misses) and depends on a model that may not even be installed for the
/// chosen language. So the card's PCM is now routed to whichever provider the
/// ASR chain names, with the on-device engine as the last resort — the same
/// order the rest of the app already uses.
///
/// Every engine:
/// * is fed 16 kHz mono 16-bit little-endian PCM with the **card's clock** for
///   that block (so lines can carry a timestamp);
/// * publishes `segments` / `partial` and calls `onTextChange` (on the main
///   queue) whenever those change;
/// * can be `reset()` for a new take — `stop()` deliberately keeps the text.
protocol PlaudLiveASR: AnyObject {
    var segments: [PlaudLiveSegment] { get }
    var partial: String { get }
    var unavailable: PlaudLiveASRUnavailable? { get }
    /// Shown in the UI / logs: "azure", "ondevice".
    var providerName: String { get }
    /// Called on the main queue after every transcript mutation.
    var onTextChange: (() -> Void)? { get set }
    /// The engine died mid-take (socket closed). The owner decides whether to
    /// fall back to another engine.
    var onFailure: ((PlaudLiveASRUnavailable) -> Void)? { get set }

    func start()
    func stop()
    func reset()
    func append(_ pcm: Data, elapsed: TimeInterval)
}

/// Shared clock formatting for line timestamps ("mm:ss" / "h:mm:ss").
enum PlaudClock {
    static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
