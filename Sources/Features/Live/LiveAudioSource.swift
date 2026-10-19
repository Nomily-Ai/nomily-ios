import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "live-source")

// MARK: - a file on the device side (minimum intersection across protocols)
//
// Division of labor with `RecorderRecording`: that one provides the shape required by the **recording library** view (title, time, raw fields);
// This only serves two tasks for the live page — ① locate "which one this is" after saving; ② retrieve to fix an incomplete copy.
// Therefore it deliberately includes only three items: "name + size + internal protocol key".

struct LiveDeviceFile: Equatable, Hashable {
    /// Name used for storage/display. D·NOTE is the filename on the card; TicNote is `<sessionId>.opus`.
    let name: String
    let size: Int
    /// Internal protocol identifier. D·NOTE uses the name as the key (`nil`); TicNote uses it as the `0x1C` sessionId.
    let sessionID: UInt32?

    init(name: String, size: Int, sessionID: UInt32? = nil) {
        self.name = name
        self.size = size
        self.sessionID = sessionID
    }
}

// MARK: - start/end result of a live session

struct LiveBeginOutcome: Equatable {
    /// We **take over** a recording that has already started on the card (not started by us).
    /// It affects two things: the saved iOS copy is shorter than the device file; we should not "delete the card's version" for the user.
    let attachedToExisting: Bool
    /// The device-side key for this session (TicNote's sessionId / D·NOTE's filename). May be `nil`.
    let sessionKey: String?
}

struct LiveStopOutcome {
    /// The recording on the device side (only present if locatable). Used for copy/delete after saving.
    let file: LiveDeviceFile?
    /// Stopped by the device **itself** (not by our stop command). The caller decides whether to take the "device stopped" branch based on this.
    let deviceInitiated: Bool

    static let deviceStopped = LiveStopOutcome(file: nil, deviceInitiated: true)
}

// MARK: - Protocol

/// An audio source that can **record and transcribe simultaneously**.
///
/// ## Why this layer is needed
/// `LiveModel` originally took the concrete type `DnoteClient` directly (`start(client:)`), so the entire live pipeline
/// could only serve D·NOTE — TicNote would have to modify both `LiveModel` and `LiveView` to integrate,
/// while inside them **only six actions are truly device-related**, the rest (ASR event loop, partial/final two-stage,
/// transcription storage, background keep-alive, repair hints) are all device-agnostic. This protocol defines the boundary of those six actions.
///
/// ## Two rules that must be obeyed
/// * **`opusProfile` decides everything**: it determines the Ogg container (`OpusHead` channel count/sample rate,
///   how pages are segmented), and also decides the duration conversion of "bytes per second". D·NOTE is 40 B mono,
///   TicNote is 160 B stereo — sending the wrong value won't error, it will just produce noise / a duration off by 4×.
/// * **Every `Data` emitted by `liveAudio` must be a whole packet** (length = `opusProfile.packetBytes`).
///   Partial packets cause the remote side to misalign all subsequent packets, and it's also a "silent failure".
@MainActor
protocol LiveAudioSource: AnyObject {

    // MARK: Identity / Capability

    /// How the audio emitted by this source is packetized. **Must** match what `liveAudio` emits.
    var opusProfile: OpusOgg.Profile { get }

    /// Whether the device-side file needs decryption (`nil` = plaintext). Only D·NOTE's encrypted firmware provides a non-nil value.
    var liveClipKey: Data? { get }

    /// Whether a live session can be started now (connected + handshake completed).
    var isAvailable: Bool { get }

    // MARK: Probe status

    /// The device's own report of "recording?". `nil` = cannot be queried — **must never be treated as `false`**
    /// (That would reset the clock to zero and issue another start-recording command for an already recording session).
    func liveIsRecording() async -> Bool?

    /// List of existing files on the device. Failure returns `nil` — also must not be treated as an "empty list":
    /// The caller relies on the "pre/post session diff" to locate the just-recorded file; treating failure as empty set
    /// would cause **all** old files to appear as "newly appeared".
    func liveListFiles() async -> [LiveDeviceFile]?

    /// The session key **most recently reported by the device itself** (the sessionId in TicNote's `0x18`/`0x14`;
    /// D·NOTE does not provide it, returns `nil`).
    ///
    /// Purpose: after stopping recording, precisely match the "just-recorded file" — no need to guess whether the newest in the list is it
    /// (The user may have recorded a file using the device's physical button outside the app).
    var liveLastSessionKey: String? { get }

    // MARK: Start

    /// Make the device **itself** start a new recording (and open the live audio stream).
    func liveStartNew() async throws

    /// Take over the recording already in progress on the device (open the live audio stream, without starting a new recording).
    ///
    /// ⚠️ Some devices **cannot output audio at all** in this scenario (D·NOTE's `upload = 0`:
    /// Live upstream is determined at the moment recording starts; a recording that began before the connection will never have frames).
    /// In such cases an error must be thrown here so the UI can promptly say "this recording cannot be captured", instead of making the user
    /// wait on "Listening…" for a timeout.
    func liveAttach() async throws

    /// Audio stream. Stream **end** indicates "the device stopped" (not stopped by us).
    ///
    /// `firstFrameTimeout` only constrains **the first frame**: a device that never sends a frame should error early,
    /// instead of treating the whole silence as a "link failure".
    func liveAudio(firstFrameTimeout: TimeInterval) -> AsyncThrowingStream<Data, Error>

    /// The **device's own** elapsed recording time for this session, in seconds.
    ///
    /// ★ Declared as a requirement, not an extension default. `LiveModel` talks to
    ///   `any LiveAudioSource`, and a default implementation in an extension is dispatched
    ///   statically — every device would silently get the `nil` behaviour forever.
    ///
    /// Why it exists: the screen used to derive the timer from the packets *we* received, so the
    /// moment the card stopped pushing (a known A1 behaviour, see `DingTalkA1Link.liveTask`) the
    /// clock froze while the card kept counting on its own — "the number is stuck / doesn't match
    /// DingTalk". The card reports its own duration in `0x0132`; that is the number to show.
    ///
    /// - Returns: `nil` when the device cannot answer (unsupported, or the command failed) —
    ///   never `0`, which would reset a running clock.
    func liveDeviceElapsed() async -> TimeInterval?

    // MARK: Stop

    /// Stop: close the audio stream + make the device stop recording. **Idempotent**, can be invoked regardless of success or failure.
    func liveStop() async -> LiveStopOutcome

    // MARK: Post‑process (save / repair / cleanup)

    /// Retrieve a file from the device (used for "paused → incomplete iOS copy → replace with device version").
    func liveFetch(file: LiveDeviceFile,
                   progress: @escaping @MainActor (Int, Int) -> Void) async throws -> Data

    /// Delete a file from the device.
    func liveDelete(file: LiveDeviceFile) async throws

    /// Convert the raw bytes accumulated in real time into bytes that can be handed directly to `PostDownload` for storage.
    ///
    /// | Source | Return value |
    /// |---|---|
    /// | D·NOTE | **Returned as‑is** — its bytes are either already Ogg or an encrypted envelope, and `PostDownload` can distinguish them |
    /// | TicNote | **Must first encapsulate in Ogg** — it is a 160 B raw packet stream, and `PostDownload`'s fallback that slices at 40 B would split it incorrectly |
    ///
    /// This entry cannot be omitted: removing it would cause TicNote's live recording to become an **unopenable** file
    /// (`looksLikeOpus` would fail → the library whitelist/duration detection would all break).
    func liveContainerize(_ raw: Data, name: String) throws -> Data
}

// MARK: - D·NOTE (V05E) adapter

/// Wrap an existing `DnoteClient` into a `LiveAudioSource`.
///
/// **This is a pure port**: each line corresponds to the original line in `LiveModel.start/_`,
/// The sole purpose is to allow TicNote to use the same live pipeline without altering D·NOTE's behavior.
/// Therefore any "convenient improvements" here must first ask: **Has D·NOTE been verified on real hardware?**
@MainActor
final class DnoteLiveSource: LiveAudioSource {

    let client: DnoteClient

    init(client: DnoteClient) {
        self.client = client
    }

    var opusProfile: OpusOgg.Profile { .dnote }

    var liveClipKey: Data? { KeyResolver.key(for: client) }

    var isAvailable: Bool { true }

    var liveLastSessionKey: String? { nil }

    func liveIsRecording() async -> Bool? {
        if let info = try? await client.getDeviceInfo() {
            return info.isRecording
        }
        return client.lastDeviceInfo?.isRecording
    }

    func liveListFiles() async -> [LiveDeviceFile]? {
        guard let files = try? await client.getFileList() else { return nil }
        // An entry with an empty name is a list terminator, not a file (the device sends `end == 1, name == ""`).
        return files.filter { !$0.name.isEmpty }
            .map { LiveDeviceFile(name: $0.name, size: $0.size) }
    }

    func liveStartNew() async throws {
        try await client.startRecording(realTime: true)
        try await client.startStream()
    }

    func liveAttach() async throws {
        // Real-time upload is decided when the recording starts:
        // 0x51 payload 0x01, or our 0x01 ack to the 0x54 push when the
        // button is pressed while we're connected. A recording that began
        // before this connection has `upload` = 0 and the firmware will
        // never push a frame for it — say so now instead of showing
        // "Listening…" until a timeout.
        if let status = try? await client.getRecordingStatus(),
           let upload = (status["upload"] as? NSNumber)?.intValue,
           upload == 0 {
            log.warning("attach: device recording has upload=0 — live stream unavailable for this recording")
            throw LiveStartError.deviceNotUploading
        }
        try await client.startStream()
    }

    func liveAudio(firstFrameTimeout: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        client.streamAudio(firstFrameTimeout: firstFrameTimeout)
    }

    /// D·NOTE's status has no recording clock — `nil` means "keep using the packet count".
    func liveDeviceElapsed() async -> TimeInterval? { nil }

    func liveStop() async -> LiveStopOutcome {
        try? await client.stopStream()
        let stopResult = try? await client.stopRecording()
        let name = (stopResult?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let size = (stopResult?["size"] as? Int) ?? 0
        return LiveStopOutcome(
            file: name.map { LiveDeviceFile(name: $0, size: size) },
            // Reaching this point means we pressed stop ourselves — a device‑initiated stop will follow the `liveAudio` stream‑end branch.
            deviceInitiated: false
        )
    }

    func liveFetch(file: LiveDeviceFile,
                   progress: @escaping @MainActor (Int, Int) -> Void) async throws -> Data {
        try await client.downloadFile(file.name, expectedSize: file.size) { got, total in
            progress(got, total)
        }
    }

    func liveDelete(file: LiveDeviceFile) async throws {
        try await client.deleteFile(file.name)
    }

    /// D·NOTE returns as‑is: its bytes are either already an Ogg container or an `encryt` encrypted envelope,
    /// `PostDownload` recognizes both paths (see branches 1 / 2 / 3 in `PostDownload.process`).
    /// Encapsulating it here would instead **break** the encrypted‑envelope path.
    func liveContainerize(_ raw: Data, name: String) throws -> Data { raw }
}
