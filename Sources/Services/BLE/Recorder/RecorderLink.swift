import CoreBluetooth
import Foundation

// MARK: - Protocol-independent "Connected Recording Card"
//
// The purpose of this layer: to let the upper layers (scan page / recording library / download flow) depend only on **semantics**,
// without caring whether the underlying implementation is D·NOTE's `[PID][CMD][LEN]` + JSON, or TicNote's
// `[type][cmd u16 LE]` + binary little-endian fields.
//
// The division of labor with `RecorderProtocolSpec`:
//   · `RecorderProtocolSpec` answers "what this card **is**, **how to recognize** it, and **how it communicates**" (static constants);
//   · `RecorderLink` answers "**how to use it** after connecting" (stateful, connection-based).
//
// This file **contains no specific protocol constants** and imports no specific implementations.
// Adapters are in `DnoteLink.swift` / `TicNoteLink.swift`.

// MARK: A recording on the card

/// A recording on the device. Fields are deliberately conservative: the two protocols' metadata differs greatly,
/// only "identifier / size / time" can be aligned; the rest goes into `raw` for the upper layer to fetch as needed.
struct RecorderRecording: Identifiable, Equatable {
    /// Stable identifier within the protocol. D·NOTE uses the filename; TicNote uses the decimal string of the sessionId.
    let id: String
    /// A directly displayable name (the caller provides a fallback based on time when the protocol does not supply a name)
    let displayTitle: String
    let sizeBytes: Int
    /// Recording start time; nil if not provided by the protocol
    let startedAt: Date?
    /// Device-side session ID. TicNote uses it to send `0x1C`; D·NOTE is nil.
    let sessionID: UInt32?
    /// Protocol raw fields are preserved as-is
    let raw: [String: AnyHashable]

    static func == (lhs: RecorderRecording, rhs: RecorderRecording) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: A deliverable recording

/// Bytes that have been retrieved from the card and **are already consumable by the system player**.
///
/// ⚠️ It's called `data` + `fileExtension` here instead of `fileURL` / `raw` to force the caller
/// to explicitly pick the on-disk extension — because the two protocols produce completely different output:
///
/// Protocol | What `data` is | Extension |
/// |---|---|---|
/// || D·NOTE || Device-side is WAV, as-is || `wav` ||
/// || TicNote || Plaintext Opus **raw packet stream**, wrapped in Ogg first || `opus` ||
///
/// ⚠️ TicNote uses `.opus` instead of `.ogg`, **not** arbitrarily: the container is the same standard Ogg Opus,
/// but `.opus` is the suffix that has been fully validated across the entire pipeline in the D·NOTE path —— the library's extension whitelist
/// (`AudioImporter.acceptedExtensions`), duration probing (`LibraryScanner.probeDuration`
/// → `OpusOgg.duration`), playback (`AudioPlaybackController`), and pre-transcription transcoding all dispatch based on it.
/// The consequence of using `.ogg` (real-device test on 2026-10-09): the whitelist rejects it → the file **does not appear in the library at all**.
///
/// If someone writes TicNote's **raw stream** (unwrapped in Ogg) directly with a `.opus` extension, most players (including
/// `AVAudioFile`) will treat it as an unrecognized file —— this is why `containerize` exists:
/// It ensures that the bytes written to `.opus` are always a valid Ogg Opus container.
struct RecorderClip {
    let data: Data
    /// File extension for disk storage, **without the dot**. Example: "wav" / "ogg"
    let fileExtension: String
    /// Duration (provided when calculable)
    let duration: TimeInterval?
    /// Human‑readable format description, written to logs and detail pages. e.g. "Opus 48 kHz stereo 64 kbps"
    let formatNote: String

    var byteCount: Int { data.count }
}

// // Storage usage snapshot

/// A card's "used / total" — at the same level as `RecorderDeviceInfo`,
/// only placing the two quantities that **align across protocols**: total and available.
///
/// ## Why a separate type, rather than stuffing `TicNoteStorageInfo` into `RecorderDeviceInfo`
/// The comment on `RecorderDeviceInfo` says "only fields that can be aligned across protocols", and **capacity is exactly alignable**:
/// The `DeviceInfo` on the D·NOTE side already has `freeMB` / `totalMB`, while TicNote uses the `0x06` response packet.
/// Attaching `TicNoteStorageInfo` directly would make the "protocol-agnostic layer" aware of TicNote's private fields
/// (`thirdField` / `freeState`) — fields that **only make sense for TicNote**, so they stay in
/// `TicNoteStorageInfo`, and only the two generic numbers are carried over here.
///
/// ## Formatting caliber (`formatBytes`)
/// Copy the official app's display on the same card: **MB without decimals, GB with one decimal**
/// (On the same time in the real device it’s "117 MB / 58.2 GB").
/// Placed in this layer instead of in a SwiftUI view, so ... ...  …  … … … … … … … … … … … 
/// This layer is the only ... … …… …
struct RecorderStorageInfo: Equatable {

    /// Total capacity (bytes).
    let totalBytes: Int64
    /// /// Available capacity (bytes).
    let freeBytes: Int64

    /// Used = Total - Free. Clamp with `max(0,)`: in case one side swaps the two fields,
    /// better to show 0 than let `ProgressView(value:)` receive a negative number.
    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }

    /// Used ratio 0…1. When total is 0 (frame not decoded) give 0 — **no division by zero**.
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    var usedText: String { Self.formatBytes(usedBytes) }
    var totalText: String { Self.formatBytes(totalBytes) }
    var freeText: String { Self.formatBytes(freeBytes) }

    /// Human-readable capacity. Base-1024, unit auto-selects by magnitude.
    static func formatBytes(_ bytes: Int64) -> String {
        let v = Double(max(0, bytes))
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        if v < kb { return String(format: "%.0f B", v) }
        if v < mb { return String(format: "%.0f KB", v / kb) }
        if v < gb { return String(format: "%.0f MB", v / mb) }
        return String(format: "%.1f GB", v / gb)
    }
}

// MARK: Device Info Snapshot

/// A snapshot of a card's "current status" — at the same level as `RecorderRecording`: only include fields that **align across protocols**,
/// leave the rest as-is in `rawReplies` for upper layers to display on demand.
///
/// Why not make it "one field one named property": only **battery** and **storage** truly align across the two protocols.
/// We have the raw bytes for TicNote's status / configuration / identity replies, but **the field semantics haven't been resolved**
/// (`0x03` returns 9 B, `0x08` returns 7 B, see `protocol-notes.md` §6.2).
/// Hard‑coding as named properties = guesswork; leaving it in `rawReplies` + UI hex view = searchable, reproducible.
struct RecorderDeviceInfo: Equatable {
    /// Battery percentage 0…100. **If it can't be read it's `nil`, not 0** — the entire abstraction layer upholds this rule
    /// (the comment on `RecorderProtocolSpec.supports(_:)` explains why).
    let batteryPercent: Int?

    /// Is the card **currently charging** (externally powered). Three states:
    ///   * `true`  —— The card explicitly reports "charging";
    ///   * `false` —— The card explicitly reports "not charging";
    ///   * `nil`   —— The card did not respond / the flag could not be recognized.
    ///
    /// ## ★ `nil` is **not** `false` (stricter than the rule for `batteryPercent`)
    /// "No read" and "not charging" must look different on the UI: the former displays `—`, while only the latter can say "not charging".
    /// Treating `nil` as `false` amounts to asserting something we don't know on behalf of the user ——
    /// and the user looks at this line precisely to decide "whether to plug in the charger".
    ///
    /// ## Source and confidence level of the criterion
    /// TicNote has no vendor documentation; this bit is decoded from the **first byte** of the `0x09` reply packet,
    /// the evidence being that on real devices it changes **in the same batch at the same time** as the `0x2000` bit of the `0x03` status frame
    /// (see `TicNoteDeviceInfoQuery.TicNoteBatteryReading` for the full evidence chain).
    /// There are only 10 samples, so the parsing layer always returns `nil` for values it cannot recognize, and the UI displays them faithfully.
    let isCharging: Bool?

    /// Storage usage. `nil` = card did not report (or this firmware version does not support it), **not "0 bytes"**.
    ///
    /// ⚠️ Same rule as `batteryPercent`: this field **used to** not exist,
    /// and even now that it does, don't show a 0% progress bar just because it's missing — that would look like "the card is full".
    let storage: RecorderStorageInfo?

    /// Command code → the **raw reply payload** for that command (undecoded; UI can display hex directly).
    /// Use the **live command code** as the key (TicNote uses the value of `TicNoteObservedCommand`).
    /// Avoid static reverse-engineered values — so you don't have to maintain separate mappings for both directions.
    let rawReplies: [UInt16: Data]

    /// Human-readable supplementary notes (e.g., "Identity reply 61 B, field semantics unresolved").
    /// These are **explanations for users**, not logs: they should answer "why is there a block of hex here".
    let notes: [String]

    init(batteryPercent: Int? = nil,
         isCharging: Bool? = nil,
         storage: RecorderStorageInfo? = nil,
         rawReplies: [UInt16: Data] = [:],
         notes: [String] = []) {
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.storage = storage
        self.rawReplies = rawReplies
        self.notes = notes
    }

    /// The card didn't answer with a single item. The UI uses this to distinguish "read 0 items" from "the card stayed silent" —
    /// These two cases mean completely different things to the user (the former means the card genuinely has no data, the latter means a link/timing problem).
    ///
    /// ⚠️ `isCharging` **does not participate** in this check: it comes from the same `0x09` frame as `batteryPercent`,
    ///    when the battery level is unavailable it is necessarily `nil` too, so writing it in would just say the same thing twice.
    var isEmpty: Bool { batteryPercent == nil && storage == nil && rawReplies.isEmpty }

    /// Number of reply packets (UI displays "Raw replies (N)").
    var replyCount: Int { rawReplies.count }
}

// MARK: Recording Status Snapshot

/// A snapshot of "is the card recording?" and "how long has it been recording" —— the **cross-protocol minimal intersection** at the same level as `RecorderDeviceInfo`.
///
/// ## Why `isRecording` / `deviceElapsed` are `Optional`
/// "Card says not recording" and "Card didn't say" are **two things**:
///   * `false` —— the card explicitly reports idle;
///   * `nil`   —— this item does not exist on the card at all (or this protocol has no resolvable field).
/// The upper layer decides based on this whether to "trust the device" or "fallback to local anchor", rather than treating `nil` as `false`
/// (`RecorderDeviceInfo.batteryPercent` follows the same rule).
///
/// ## Correspondence with V05E (★ This determines whether TicNote can copy V05E's duration logic)
/// V05E's `DnoteClient.getRecordingStatus()` returns JSON, with `recd` (milliseconds) and `isRecording`
/// both present —— so on that side **all** durations come from the device; the client does not calculate them itself.
///
/// TicNote **was once** considered unable to copy —— the basis at the time was that in the real-device packet capture, `0x17` (with the total session byte count)
/// of that line) only appeared twice, getting stuck during recording without speaking.
///
/// ## ★ 2026-10-10: That conclusion was overturned
/// After reviewing the capture with **real recording** (`bug2-20261008.att.txt`, 13.8 MB), we confirm:
/// During recording it kept sending `0x02` voice frames — about ~100 frames/s, total 7,398 frames,
/// and the frame stream's start‑end boundaries exactly match the recording window (1050 frames in a 10 s bucket, 0 outside the window).
///
/// So TicNote now has three **device ground truths**, no longer "no decodable fields":
///   · Continuous signal: **voice frame rate** → `TicNoteLink.streamingVoice` (no polling needed at all);
///   · Event signal: `0x14` recording start / `0x17` recording end (one-shot, the two frames' layouts are **different**);
///   · Quantitative signal: `0x17`'s `fileSize` ÷ 8000 B/s, and `sessionId` = start Unix second
///     (can serve directly as an anchor, closer to the card's true start point than local `Date()`).
///
/// The abstraction layer still exposes "device value" and "local anchor" side by side (D·NOTE uses the former, falls back to the latter when the card is silent),
/// But TicNote is no longer on the "rely only on local clock" side.
struct RecorderRecordingStatus: Equatable {

    /// The card's self-reported "currently recording" status. `nil` = the card didn't say.
    ///
    /// TicNote now fills this value (voice frame stream + `0x14`/`0x17`, see this type's doc comments);
    /// D·NOTE uses the `rec` field. When `nil`, callers **must not** treat it as "not recording" — that would reset the clock to zero.
    let isRecording: Bool?

    /// The card's self-reported **written byte count**. `nil` = card didn't say. The last 4 bytes of TicNote's `0x17` are exactly this.
    let totalBytes: Int?

    /// Duration (seconds) converted from the **device byte count**. `nil` = cannot be computed.
    /// ⚠️ The conversion constant is supplied by the protocol itself (TicNote = 8000 B/s, see `TicNoteRecordingState.bytesPerSecond`),
    /// so this value is computed in the protocol layer and handed to upper layers; they never need to know any byte rate.
    let deviceElapsed: TimeInterval?

    /// Whether the card has **proactively pushed** a recording start/end frame (TicNote's `0x14` / `0x17`) since the last query.
    ///
    /// Ask again after `startRecording()`; `true` = the card did something after we sent the command.
    ///
    /// ⚠️ **`false` ≠ "the card is not recording", and `true` ≠ "the card accepted the record command"**.
    /// The card may push these two frames whenever **any session is touched** (listing and file reads also produce samples) --
    /// the `0x17` in real-device #47766 showed up in the middle of a file transfer.
    /// What should really be trusted is `isRecording` (derived from the **voice-frame stream + event frames** together, see this type's doc comment);
    /// this item is only corroborating evidence of "whether the card is doing anything", and UI wording must respect that.
    let sawSessionNotice: Bool

    /// Raw reply (undecoded). Lets the UI print hex, and is the evidence for reconciling against the next packet capture.
    let rawReplies: [UInt16: Data]

    init(isRecording: Bool? = nil,
         totalBytes: Int? = nil,
         deviceElapsed: TimeInterval? = nil,
         sawSessionNotice: Bool = false,
         rawReplies: [UInt16: Data] = [:]) {
        self.isRecording = isRecording
        self.totalBytes = totalBytes
        self.deviceElapsed = deviceElapsed
        self.sawSessionNotice = sawSessionNotice
        self.rawReplies = rawReplies
    }

    /// The card provided nothing at all (not even one reply). The UI uses this to tell "the card says idle" from "the card said nothing".
    var isEmpty: Bool { isRecording == nil && totalBytes == nil && rawReplies.isEmpty }

    /// Placeholder where everything is unknown. This is **not** "not recording" -- see this type's doc comment.
    static let unknown = RecorderRecordingStatus()
}

// MARK: Errors

enum RecorderLinkError: LocalizedError {
    /// The protocol does not support this operation (as distinct from "not yet reverse-engineered")
    case unsupported(String)
    /// The transfer had gaps/conflicts; delivery is refused fail-closed
    case corrupted(String)
    /// The peer returned a structurally invalid frame
    case malformed(String)
    case notConnected
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupported(let s): return "This device does not support that: \(s)"
        case .corrupted(let s):   return "Transfer corrupted, refusing to save: \(s)"
        case .malformed(let s):   return "Malformed reply from device: \(s)"
        case .notConnected:       return "Device is not connected."
        case .timeout:            return "Device did not answer in time."
        case .cancelled:          return "Transfer was cancelled."
        }
    }

    /// Stable classification key for the UI (localization / analytics both rely on it; do not parse `errorDescription`)
    var kind: String {
        switch self {
        case .unsupported: return "unsupported"
        case .corrupted:   return "corrupted"
        case .malformed:   return "malformed"
        case .notConnected: return "notConnected"
        case .timeout:     return "timeout"
        case .cancelled:   return "cancelled"
        }
    }
}

// MARK: Interface

/// The semantic interface of a **connected** recorder card.
///
/// Implementation constraints:
/// * All methods must be "serializable" -- the card firmware accepts only a single in-flight command,
///   so implementations must lock internally (`DnoteClient` already has `runExclusive`; TicNote uses the same idea).
/// * `handleDisconnect` may be called during `fetchRecording`; the implementation must make in-flight operations
///   **fail as soon as possible** rather than wait for their own timeout (otherwise the user sees "stuck" instead of "disconnected").
///
/// ⚠️ The whole protocol is marked `@MainActor`, **deliberately**: CoreBluetooth callbacks, `CBPeripheral`
/// properties, and all consumers (scan page / recording library / download flow) are on the main thread anyway.
/// Without the annotation, a `@MainActor` implementation class could not satisfy the **non-async** requirements
/// such as `peripheral` / `displayName` (an actor-isolated stored property cannot witness a nonisolated requirement),
/// and we would have to add a pile of `nonisolated(unsafe)` to the implementation to tear the isolation down -- not worth it.
@MainActor
protocol RecorderLink: AnyObject {
    /// Corresponds to `RecorderProtocolSpec.identifier`
    static var protocolID: String { get }

    var peripheral: CBPeripheral { get }
    var displayName: String { get }
    var isConnected: Bool { get }
    var negotiatedMTU: Int { get }

    /// After connecting, get service discovery / characteristic discovery / notification enabling / MTU all sorted out.
    /// Returning means "the first application-layer command can now be sent".
    func completeHandshake() async throws

    /// The link is down: make all in-flight operations fail immediately.
    func handleDisconnect(error: Error?)

    /// Time sync. Implementations with `RecorderCommandSet.syncTime == nil` throw `.unsupported` directly.
    func syncTime(to date: Date) async throws

    /// List recordings. Order of the result is not guaranteed; callers sort it themselves.
    func listRecordings() async throws -> [RecorderRecording]

    /// Fetch the complete bytes of one recording (protocol-layer scaffolding already stripped).
    ///
    /// `progress` receives 0…1; pass nil if you don't care.
    ///
    /// ⚠️ `progress` is marked `@MainActor` (so is the protocol itself). This is not decoration:
    /// the callback's consumer is SwiftUI `@State`; without the annotation the caller would have to write
    /// `Task { @MainActor in … }` every time to go around, and during a download this callback is invoked **hundreds of times**
    /// (TicNote does once per chunk, 353 times); the extra Tasks are pure waste and can reorder.
    func fetchRecording(_ recording: RecorderRecording,
                        progress: (@MainActor (Double) -> Void)?) async throws -> Data

    /// Wrap the product of `fetchRecording` into something "the system can play directly".
    ///
    /// This is a protocol **requirement**, not an optional optimization: TicNote's bare Opus packet stream
    /// is an unopenable file unless wrapped in Ogg, see the comment on `RecorderClip`.
    func containerize(_ raw: Data, for recording: RecorderRecording) throws -> RecorderClip

    /// Delete one recording. Throws `.unsupported` when not supported.
    func deleteRecording(_ recording: RecorderRecording) async throws

    /// The recording session ID that the card **most recently reported by itself** (the one carried in `0x14` / `0x17` / `0x18`).
    ///
    /// Purpose: **auto transfer**. After recording starts the card pushes `0x18`, from which we get this recording's sid;
    /// after recording stops, use it to match against the result of `listRecordings()` and pinpoint "the one just recorded"
    /// -- no need to guess "is the first list entry it" (if the user also recorded one using the card's physical key outside the App,
    /// "take the newest" would pick the wrong one).
    ///
    /// ⚠️ Same rule as `fastTransfer`: it **must** be listed in the protocol requirements.
    /// If only in an extension, dispatch on `any RecorderLink` is static, and what the implementation class writes doesn't count
    /// (the shape of this pitfall is in the long comment above `fastTransfer`). The default implementation returns `nil`.
    var lastSessionID: UInt32? { get }

    // MARK: Optional capability: fast channel
    //
    // ⚠️ These two **must** be listed here (protocol requirements), not only in the extension below.
    //
    // Extension-only = that default implementation is **statically dispatched** on `any RecorderLink`, so
    // `link.fastTransfer` is always the extension's `nil` -- whatever the implementation class writes doesn't count.
    // The shape of this pitfall is extremely subtle: **it compiles, zero warnings, and in the UI the "fast transfer switch never appears"**,
    // and it looks exactly like "the card gave no credentials". `RecorderSheet` calls precisely through `any RecorderLink`
    // (`refreshFastTransfer(_ link: any RecorderLink)`).
    //
    // Once promoted to a protocol requirement, existential types go through the witness table and the implementation's version takes effect;
    // the default implementation in the extension is kept, so devices that don't implement these two need no changes.

    /// Optional fast channel (Wi-Fi fast transfer). The default implementation returns `nil` (see extension).
    var fastTransfer: (any RecorderFastTransfer)? { get }

    /// Reason there is no fast channel (shown in the UI). The default implementation returns `nil` (see extension).
    var fastTransferUnavailableReason: String? { get }

    /// Make the **card itself** start recording ("linked recording"). Throws `.unsupported` when not supported.
    ///
    /// ⚠️ Same rule as `deleteRecording`: listed in the **protocol requirements** rather than the extension:
    /// if only implemented in the extension, dispatch on `any RecorderLink` is static and what the implementation class writes doesn't count
    /// (the shape of this pitfall is in the long comment above `fastTransfer`). The default implementation throws `.unsupported`.
    func startRecording() async throws

    /// Make the card stop recording. Throws `.unsupported` when not supported.
    func stopRecording() async throws

    /// Set the card's **microphone gain** (the "Microphone Gain" item on the official card's device page). Throws `.unsupported` when not supported.
    ///
    /// ⚠️ The **same rule** as `startRecording` / `deleteRecording` / `fastTransfer`:
    /// it must be listed in the protocol **requirements**, not only in the extension below. If extension-only,
    /// dispatch on `any RecorderLink` is **static** and whatever the implementation class writes doesn't count --
    /// the symptom is "compiles, zero warnings, tapping does nothing", and it looks exactly like "the card doesn't recognize this setting"
    /// (the shape of this pitfall is in the long comment above `fastTransfer`).
    ///
    /// Semantic conventions:
    /// * The value range of the parameter is defined by the **protocol itself** (TicNote has the two levels of `TicNoteMicrophoneGain`,
    ///   see the argument for "why not a slider" in that enum);
    /// * It is a **write** operation, so the implementation must truly confirm the write before returning; when the "current settings" cannot be obtained,
    ///   prefer throwing over assembling an incomplete settings frame from defaults (this is what TicNote's implementation does).
    func setMicrophoneGain(_ gain: TicNoteMicrophoneGain) async throws

    /// **Unbind the device**: return this card to a state where "it can be bound by another phone/account".
    /// Throws `.unsupported` when not supported.
    ///
    /// ⚠️ Same as above, must be in the protocol requirements (reason in `setMicrophoneGain`).
    ///
    /// Semantic conventions:
    /// * This is a **destructive operation** (with respect to the "binding relationship"); the caller must do a second confirmation first;
    /// * It **does not** delete recordings on the card (TicNote's `clearData` is a separate command,
    ///   see the comment on `TicNoteUnbind`), and **does not** clean up the local cache either --
    ///   the local copy is handled by the caller according to its own ledger.
    func unbindDevice() async throws

    /// Read device info once (battery etc.). Throws `.unsupported` when not supported.
    ///
    /// ⚠️ The **same rule** as `startRecording` / `fastTransfer`: it must be listed in the protocol **requirements**,
    /// not only in the extension below. If extension-only, dispatch on `any RecorderLink` is **static**,
    /// whatever the implementation class writes doesn't count -- the symptom is "compiles, zero warnings, the UI never reads the battery",
    /// and it looks exactly like "the card doesn't provide this data" (the shape of this pitfall is in the long comment above `fastTransfer`).
    ///
    /// Semantic conventions:
    /// * **Read-only** -- the implementation must not "incidentally change card state" (even harmlessly);
    /// * If the card answered part of it, return that part; **do not** fail wholesale because one item is missing;
    /// * Throw only if the card answered nothing at all (`.timeout`).
    func readDeviceInfo() async throws -> RecorderDeviceInfo

    /// Read once "is the card recording, and for how long". Throws `.unsupported` when not supported.
    ///
    /// ⚠️ The **same rule** as `readDeviceInfo` / `startRecording` / `fastTransfer`:
    /// it must be listed in the protocol **requirements**, not only in the extension below. If extension-only,
    /// dispatch on `any RecorderLink` is **static** and whatever the implementation class writes doesn't count --
    /// the symptom is "compiles, zero warnings, the recording duration is stuck at 0:00 forever"
    /// (the shape of this pitfall is in the long comment above `fastTransfer`).
    ///
    /// Semantic conventions (same as `readDeviceInfo`, **with only one difference**):
    /// * **Read-only** -- the implementation must not "incidentally change card state";
    /// * If the card answered part of it, return that part; **do not** fail wholesale because one item is missing;
    /// * **No answer from the card does not throw**; just return a state whose `rawReplies` is empty --
    ///   the caller polls at 1 Hz and needs the information "the card said nothing" in order to keep running,
    ///   rather than reporting an error every second. Throw only when the link is truly down (`.notConnected`).
    func readRecordingStatus() async throws -> RecorderRecordingStatus

    /// Whether "it is recording", **proactively pushed** by the card; **reads the cache, does no I/O**.
    ///
    /// ## Why this must be separate from `readRecordingStatus()`
    /// Some cards push their state up **by themselves** (TicNote does: whenever the card has voice/events it sends them,
    /// and it also pushes when the user starts recording with the physical key on the card). This information should not wait to be asked --
    /// 1 Hz polling is at most 1 second late, whereas without polling you would never get it.
    /// Making "what was pushed" a **pure cache-reading** getter lets the caller ask once at zero cost **on every UI refresh**
    /// (see `RecorderSessionModel.stateSyncTick`).
    ///
    /// * `nil` = the card doesn't provide this capability, or hasn't said anything yet (D·NOTE polls → default implementation returns `nil`);
    /// * `true` = the card is recording; `false` = the card explicitly says it is not recording.
    ///
    /// ⚠️ Like `isRecording`, listed in the protocol **requirements** -- implementing it only in the extension means static dispatch.
    var pushedRecordingState: Bool? { get }

    /// The most recent battery percentage **proactively pushed** by the card (or just read from it), **reads the cache, does no I/O**.
    /// `nil` = unknown. The default implementation returns `nil` (see extension).
    var pushedBatteryPercent: Int? { get }

    /// The most recent **charging state** **proactively pushed** by the card (or just read from it), **reads the cache, does no I/O**.
    ///
    /// ## ★ Why this one had to be added (2026-10-14)
    /// The user's own words:
    /// > "Charging still isn't synced here, needs adjusting and optimizing"
    ///
    /// Troubleshooting conclusion: **the data chain and parsing are both fine**. In the real-device log (`Documents/ticnote-ble.log`)
    /// the **first byte** of the `0x09` reply faithfully flips with plugging/unplugging:
    /// ```
    /// 11:45:57.278 BATT battery 85% · not charging (0x09 first byte=0x00)
    /// 11:47:20.006 BATT battery 85% · charging (0x09 first byte=0x01)
    /// ```
    /// And across the full sample set the first byte **only ever took the two values `00` (×153) / `01` (×27)**,
    /// not a single unrecognized value -- so it is neither "the card doesn't report" nor "the parser guessed wrong".
    ///
    /// The real problem is that **the UI reads a snapshot that never updates itself**:
    /// `RecorderDeviceView.deviceInfo` is only written on "tap to open card info" and "pull to refresh".
    /// So after plugging in power, the lightning bolt on the page doesn't appear until the user refreshes manually, which looks like "not synced".
    ///
    /// The battery half was solved long ago (`RecorderSessionModel.cardWatchTask` reads the
    /// `pushedBatteryPercent` cache once per second, zero I/O), but **charging state had no matching half**.
    /// This requirement fills that in -- afterwards the UI follows exactly the same logic as V05E:
    /// the view binds to a **continuously updated** published value instead of storing its own copy.
    ///
    /// ⚠️ The three-state semantics are **verbatim identical** to `RecorderDeviceInfo.isCharging` (`nil` ≠ `false`):
    /// `nil` = not read yet / the flag the card gave is unrecognized; the UI shows `—`.
    /// It must never be collapsed to "not charging" -- the user looks at this item precisely to decide whether to plug in power.
    var pushedChargingState: Bool? { get }

    // MARK: Keep-alive

    /// Keep the link **from going idle** -- send a read-only command at low frequency so the device's idle sleep doesn't cut the link.
    ///
    /// ## Why the protocol layer must do this, rather than letting a UI timer send it incidentally
    /// User field feedback: *"it goes to sleep instead of staying connected; the recorder card needs to stay connected"*.
    /// The cause is that **after the connection is established nothing is talking** -- the list has been read, the download hasn't started,
    /// so the card enters power-saving sleep (the same card's advertising interval was measured up to 152 seconds, see the long comment on
    /// `BluetoothCoordinator.connectRecorder`), and the link goes down with it.
    ///
    /// Having the UI send it doesn't work, for three concrete reasons:
    ///   · The UI only lives while some page exists (it's gone once `RecorderSheet` closes), whereas "stay connected"
    ///     must hold for the whole App lifetime;
    ///   · Which frame to send is **protocol knowledge** (0x09 is a read-only battery query), which the UI layer shouldn't know;
    ///   · Sending a frame must **share the same command lock** with list/download (`TicNoteLink.runExclusive`);
    ///     two independent send paths would collide on the single-consumer constraint of `inbox`.
    ///
    /// Semantic conventions:
    /// * **Read-only** -- keep-alive must not be used to change card state (same rule as `readDeviceInfo`);
    /// * Send only when **truly idle** (the implementation looks at "how long since the last frame received/sent"),
    ///   and it must not speak up even once during download/polling;
    /// * Idempotent -- repeated calls are a no-op and never start a second heartbeat task.
    ///
    /// ⚠️ The **same rule** as `fastTransfer` / `lastSessionID` / `readDeviceInfo`:
    /// it must be listed in the protocol **requirements**, not only in the extension below. If extension-only,
    /// dispatch on `any RecorderLink` is **static** and whatever the implementation class writes doesn't count --
    /// the symptom is "compiles, zero warnings, the link still dies asleep", and it looks exactly like "the card just disconnects".
    func startKeepAlive()

    /// Stop keep-alive. Must be called on disconnect / active disconnect, otherwise the task leaks along with the old link.
    func stopKeepAlive()
}

// MARK: Default implementations (centralizing the "optional capability" checks in one place)

extension RecorderLink {
    /// Whether the protocol claims to support a command; `nil` is always treated as "not supported".
    /// ⚠️ `nil` must never be used as 0 -- the entire abstraction layer guards this rule.
    static func supports(_ cmd: UInt8?) -> Bool { cmd != nil }

    /// No fast channel by default. This is an **intentional default**: if a device doesn't implement Wi-Fi,
    /// upper layers shouldn't assume there's a choice just because it "inherited the default implementation".
    ///
    /// Note this is **only the default implementation** -- this member is also a protocol requirement (see the declaration above),
    /// so the implementation class's version is also dispatched to on `any RecorderLink`.
    var fastTransfer: (any RecorderFastTransfer)? { nil }

    /// When there is no fast channel, give the UI a one-line explanation of why.
    /// Default nil (= "this device simply doesn't have one"), not "has one but unusable" -- the two mean different things to the user.
    var fastTransferUnavailableReason: String? { nil }

    /// **Not supported** by default for linked recording. Same reasoning as `fastTransfer`:
    /// when a device doesn't implement this capability, upper layers should get an explicit `.unsupported`,
    /// rather than "looks present, tapping does nothing".
    func startRecording() async throws {
        throw RecorderLinkError.unsupported("startRecording not implemented for this device")
    }

    func stopRecording() async throws {
        throw RecorderLinkError.unsupported("stopRecording not implemented for this device")
    }

    /// **Not supported** by default for setting microphone gain. Same reasoning as `startRecording`: upper layers get an explicit
    /// `.unsupported`, rather than "looks present, tapping does nothing".
    func setMicrophoneGain(_ gain: TicNoteMicrophoneGain) async throws {
        throw RecorderLinkError.unsupported("setMicrophoneGain not implemented for this device")
    }

    /// **Not supported** by default for unbinding. Same as above.
    ///
    /// ⚠️ This one in particular must not have a "looks successful" default: unbinding is destructive,
    /// and a silently-succeeding fake implementation would make the user think the card has been handed over -- when it hasn't moved at all.
    func unbindDevice() async throws {
        throw RecorderLinkError.unsupported("unbindDevice not implemented for this device")
    }

    /// **Not supported** by default for reading device info. Same reasoning as `startRecording`: upper layers get an explicit
    /// `.unsupported`, rather than "looks present, tapping does nothing".
    func readDeviceInfo() async throws -> RecorderDeviceInfo {
        throw RecorderLinkError.unsupported("readDeviceInfo not implemented for this device")
    }

    /// **Not supported** by default for reading recording state. Same reasoning as `readDeviceInfo`.
    func readRecordingStatus() async throws -> RecorderRecordingStatus {
        throw RecorderLinkError.unsupported("readRecordingStatus not implemented for this device")
    }

    /// **No** pushed recording state by default. This is an **intentional default**, not "the card isn't recording" --
    /// `nil` = "unknown", and is never treated as `false` (the whole abstraction layer guards this rule).
    /// D·NOTE obtains state by polling `getRecordingStatus()`, so it lands on this default.
    var pushedRecordingState: Bool? { nil }

    /// No pushed battery by default. Same as above: `nil` means "unknown", not "0%".
    var pushedBatteryPercent: Int? { nil }

    /// No pushed charging state by default. Same as above: `nil` means "unknown", **not** "not charging".
    ///
    /// ⚠️ Same rule as `pushedBatteryPercent` -- must be listed in the protocol **requirements**.
    /// If written only in the extension, dispatch on `any RecorderLink` is static: whatever the implementation class writes doesn't count,
    /// and the symptom is again "compiles, zero warnings, the UI always shows `—`",
    /// looking identical to "this card simply doesn't report charging state" (the shape of this pitfall is in the long comment above `fastTransfer`).
    var pushedChargingState: Bool? { nil }

    /// **No** session ID by default (if the device doesn't report one it really is nil, not 0).
    var lastSessionID: UInt32? { nil }

    /// **No keep-alive** by default. This is an intentional default: the D·NOTE side's link is resident anyway
    /// (it has its own 30 s slow poll), and shouldn't gain a gratuitous periodic write just because it "inherited the default implementation".
    /// Protocols that need keep-alive (currently only TicNote) override it themselves.
    func startKeepAlive() {}

    func stopKeepAlive() {}
}

// MARK: - Fast channel (optional capability)

/// The device's hotspot/Wi-Fi fast channel.
///
/// **Why a separate protocol instead of stuffing it into `RecorderLink`**: `RecorderLink` requires
/// `peripheral: CBPeripheral` -- a pure Wi-Fi channel can't produce a `CBPeripheral`,
/// and forcing it in would mean supplying a fake value or tearing `RecorderLink` apart. And the **lifecycles of the two channels
/// also differ**: the BLE one is "always there while connected", while the Wi-Fi one is "opened once per transfer, closed after use".
///
/// So the relationship is: `RecorderLink` (resident, BLE) **optionally** provides `RecorderFastTransfer` (one-shot, Wi-Fi).
@MainActor
protocol RecorderFastTransfer: AnyObject {
    /// Corresponds to `RecorderProtocolSpec.identifier`
    static var protocolID: String { get }

    /// Fetch a recording over the fast channel, returning a **playable container** directly.
    ///
    /// Division of labor with `RecorderLink.fetchClip`: that one is "protocol-layer scaffolding stripped, may still need wrapping",
    /// this one is end-to-end (joins the hotspot, handshakes, and wraps up by itself).
    func fastFetch(_ recording: RecorderRecording,
                   progress: (@MainActor (Double) -> Void)?) async throws -> RecorderClip

    /// Same path, but **delete the copy on the card after fetching** (the "auto-delete after transfer" switch).
    ///
    /// ## Why a separate method, rather than adding a default parameter to the one above
    /// Deletion **can only happen during the short window while the fast session is still alive** (once the session closes, there is nowhere to send the delete command).
    /// So it isn't a step the caller can incidentally do after getting the clip -- it must be slotted in by the **channel internals** before wrap-up.
    /// And "can delete within the session" is this channel's capability, not something every `RecorderFastTransfer` has,
    /// so the protocol gives a default implementation here: **ignore `deleteAfter`** and just say "not deleted" (`nil`).
    func fastFetch(_ recording: RecorderRecording,
                   deleteAfter: Bool,
                   progress: (@MainActor (Double) -> Void)?) async throws -> RecorderFastFetchResult

    /// Abort the fast file fetch **in progress** (best effort).
    ///
    /// ## Why it is a protocol **requirement** rather than only in the extension
    /// The caller holds an `any RecorderFastTransfer`; only a **requirement** goes through the witness table to reach
    /// the implementation class's own version (`TicNoteWifiLink.cancel()`: set a flag + wrap up and leave the hotspot).
    /// If extension-only, an existential gets the empty implementation in the extension -- pressing "stop" would make nothing happen.
    /// This repo has stepped on this pitfall once (see §21.5: `startRecording` / `stopRecording`).
    ///
    /// ## Why it is worth adding a requirement for it
    /// Without it, "stop" can only degrade to "don't continue after the current one finishes". And a 49-minute recording
    /// takes 45 minutes to move over Bluetooth -- the user pressed stop yet still has to wait for it; that isn't stopping.
    func cancel()

    /// ★★★ **Session-lifetime switches** for whole-batch fast transfer (added after real-device forensics on 2026-10-12).
    ///
    /// ## What happens without them -- this is the user-reported "I have to reconnect Wi-Fi for every single transfer"
    ///
    /// Before this, every `fastFetch` was a **full cold start**:
    /// start listener → send `OPEN_WIFI` → the card drops BLE to bring up the hotspot → `NEHotspotConfiguration.apply`
    /// to join -> wait for the card to connect in -> transfer the file -> `teardown()` (`WIFI_CLOSE` + **leave the hotspot** + stop listener).
    ///
    /// The real-device log (`14:10~14:12`) pins down the cost -- the 2nd one tripped precisely on "the card never connected in after joining",
    /// and waited the full 45 s window in vain before giving up:
    /// ```
    /// 14:10:54.187 WIFI ✅ card connected to the listening port and finished the upgrade (1st join)   ← 1st one, ready in 167 ms
    /// 14:10:55.918 WIFI fast transfer started sid=…190611                        ← 2nd one cold-starts again
    /// 14:11:04.927 WIFI 1st iOS report "joined"                     ← only joined after 6.2 s
    /// 14:11:24.940 WIFI the card never connected in after the 1st join -- rejoining      ← 20 s wasted
    /// 14:11:55.688 WIFI ✗ gave up joining the hotspot: tried 2 times                    ← another 30 s wasted
    /// ```
    /// What the user sees is "every segment transferred requires tapping to connect Wi-Fi again".
    ///
    /// ## Why this cost **should never have been paid once per file in the first place**
    /// As long as the card's hotspot stays on, the phone just stays attached to it — "re-OPEN_WIFI + rejoin the hotspot"
    /// has no causal relationship with "sending the next file". `beginBatch()` does the cold start once,
    /// each file in between only goes through `cmder 12 / 13` (+ `14`), and `endBatch()` wraps everything up.
    /// **This isn't about saving a few seconds — it compresses that extremely unreliable window from N occurrences down to 1.**
    ///
    /// ⚠️ Same rule as `cancel()`: it must be listed in the protocol **requirements**, not just written into an extension —
    /// the caller is holding an `any RecorderFastTransfer`; writing it only in an extension means static dispatch to the
    /// empty implementation below, and the whole batch silently degrades into "one cold start per file" — exactly the behavior this section aims to eliminate.
    ///
    /// ⚠️ Implementations must be **idempotent**: return immediately if the session is still alive, reopen once if it's dead.
    /// The caller (`RecorderSheet.prepareNextFile`) invokes it once before every file,
    /// relying on this semantics to achieve "reuse while alive, self-heal when broken".
    func beginBatch() async throws

    /// The fast transfer of the whole batch has ended. **Must be called on success, failure, and cancellation alike**.
    ///
    /// It handles three cleanup tasks (none can be skipped, see `TicNoteWifiLink.teardown`):
    /// send `WIFI_CLOSE`, remove the hotspot configuration, stop monitoring and disconnect.
    func endBatch() async
}

extension RecorderFastTransfer {
    /// Default implementation: **does nothing**.
    ///
    /// Not laziness — channels that can't "interrupt mid-way" (e.g. the pure BLE one: once the command lock is taken it spans the whole segment)
    /// can only work this way. The caller checks `cancelRequested` itself to decide whether to continue.
    func cancel() {}

    /// Default implementation: **does nothing**.
    ///
    /// Channels that can't "reuse a single session for the whole batch" (the pure BLE one has no session to speak of) don't need this switch in the first place;
    /// their `fastFetch` is self-consistent per file, so the default empty implementation is the correct semantics.
    func beginBatch() async throws {}

    func endBatch() async {}
}

/// The complete result of one high-speed file fetch.
///
/// The reason it doesn't return `RecorderClip` directly: "fetched" and "whether the copy on the card was deleted" are two separate things,
/// and the latter carries an ambiguity that **must be conveyed to the caller** (see `removedFromCard`).
struct RecorderFastFetchResult {
    let clip: RecorderClip

    /// The result of deleting the copy on the card.
    ///
    /// * `nil` — **deletion was not requested this time** (or this channel has no in-session delete capability);
    /// * `true` — the card explicitly returned a receipt confirming deletion;
    /// * `false` — the card explicitly refused, **or** timed out without a receipt.
    ///
    /// ⚠️ `false` **does not mean "the copy is still on the card"**: no answer ≠ not deleted. So the caller
    /// must **not** switch to another channel and delete again on `false` — that fallback channel (BLE `0x1E`)
    /// kills the link after sending on real hardware (verified 2026-10-12 11:23:48).
    let removedFromCard: Bool?
}

extension RecorderFastTransfer {
    /// Default implementation: ignores `deleteAfter`.
    ///
    /// Not laziness — channels that can't access the "inside the session" timing **cannot** do this,
    /// and hard-coding a "deleted" return value would be lying to the caller. So it honestly returns `nil` (not deleted),
    /// letting the caller decide whether to take its own fallback deletion path.
    func fastFetch(_ recording: RecorderRecording,
                   deleteAfter: Bool,
                   progress: (@MainActor (Double) -> Void)?) async throws -> RecorderFastFetchResult {
        RecorderFastFetchResult(
            clip: try await fastFetch(recording, progress: progress),
            removedFromCard: nil
        )
    }
}

// MARK: - Convenience combinations

extension RecorderLink {
    /// One step to done: fetch + wrap. Callers basically only use this.
    func fetchClip(_ recording: RecorderRecording,
                   progress: (@MainActor (Double) -> Void)?) async throws -> RecorderClip {
        let raw = try await fetchRecording(recording, progress: progress)
        return try containerize(raw, for: recording)
    }
}
