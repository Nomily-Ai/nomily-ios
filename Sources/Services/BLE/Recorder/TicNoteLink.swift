import CoreBluetooth
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "ble.ticnote")

// MARK: - TicNote CoreBluetooth transport layer
//
// Division of responsibilities (**the only important design decision in this file**):
//
//   ┌─ TicNoteLink (this file)   Handles raw bytes: discover services / enable notifications / write characteristic / frame slicing
//   └─ TicNoteSession (already built)   Handles protocol: file listing, fragment requests, sentinel, assembly, Ogg encapsulation
//
// Why this separation is required: `CBPeripheral` cannot be instantiated from the command line, so the protocol logic
// must be written in this file, and that logic can only be tested on real hardware. After clean separation, the protocol part can be exercised on real devices
// packet capture full replay (see `tools/selfcheck/main.swift` §18: 353 requests / 7044 data frames
// byte-by-byte verification + 563,520-byte reconstruction + Ogg byte-wise match). The remaining part of this file is thin enough,
// thin enough that copying from DnoteClient is trustworthy.
//
// This file **does not introduce any new protocol constants** — all are taken from `TicNoteGATT` / `TicNoteFrameCodec` /
// `TicNoteFileList` / `TicNoteSyncRequest`. A single byte error will break the §18 replay.

/// Implementation of the transport layer for TicNote (NE-79) recording card.
///
/// Differences from `DnoteClient` (determined by the protocol, not implementation quirks):
/// | | D·NOTE | TicNote |
/// |---|---|---|
/// | Write type | `.withResponse` (acknowledged write) | **`.withoutResponse`** (real device 14/14 uses `0x52`) |
/// | Inbound framing | Frames include length bytes `[PID][CMD][LEN]` | **Control frames lack length field**, rely on "one notification = one full frame" |
/// | Voice frame | none | `0x02` + fixed 90 bytes (the length byte `[9]` is redundant checksum) |
/// | File read | One command per file | **Fragment polling**: `0x1C` → wait sentinel → another `0x1C` (353 rounds) |
/// | Storage format | Device side is WAV | Plain Opus raw stream, **must be wrapped in Ogg** |
@MainActor
final class TicNoteLink: NSObject, ObservableObject, RecorderLink {

    static var protocolID: String { TicNoteRecorderSpec.identifier }

    let peripheral: CBPeripheral
    private weak var central: CBCentralManager?

    /// Card SN (the ASCII segment in advertising manufacturer data, e.g., `S02510YCY36W3N9H`).
    ///
    /// **This is the sole source of fast-transfer credentials**: hotspot name = `"TicNote-" + last 4 digits of SN`,
    /// WPA2 password = last 8 digits of SN (verified on real device by official app, see `TicNoteWifiCredentials.from(sn:)`
    /// as in `protocol-notes.md` §18.1). Without SN, fast transfer is unavailable — see `fastTransfer`.
    ///
    /// Provided by `BluetoothCoordinator` from scan results when establishing the link. The only way it can be `nil`
    /// is when advertising lacks manufacturer data (e.g., peripherals obtained via `retrievePeripherals` without a full scan).
    private(set) var serialNumber: String?

    /// Write characteristic (App → Card): `00002bb1-…`. Reusing DnoteClient's `rx/tx` naming can be confusing,
    /// so we name by **direction**: `writeChar` for outbound, `notifyChar` for inbound.
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    @Published private(set) var negotiatedMTU: Int = 0
    /// Result of the most recent file listing (for Device page / debugging)
    @Published private(set) var lastRecordings: [RecorderRecording] = []
    /// Completion of the most recent download
    @Published private(set) var transferProgress: Double = 0
    @Published private(set) var disconnectError: Error?

    /// Most recent inbound control frame read (provides incidental info such as status/battery).
    /// TicNote responses lack request IDs, so replies cannot be matched to requests; therefore we store only the "latest" one here,
    /// Determine type by **cmd code** instead of by "which response packet".
    private(set) var lastControlFrame: Data?

    /// Wi-Fi credentials **actively reported** by the card over BLE (if any).
    ///
    /// ⚠️ This **is not** the required path for fast transfer. In round 15, real devices confirmed the credentials are fully derived from the SN
    /// (see `fastTransferCredentials`), this field now only serves as **cross-validation**:
    /// If future firmware stops deriving from SN, the card-reported value may differ from the locally computed one; in that case, trust the card's value.
    ///
    /// On real devices this is most likely always `nil` — the shape has no sample, and parsing is tolerant
    /// (`TicNoteWifiCredentials.parseBLEFrame`), if unrecognizable nothing happens.
    @Published private(set) var wifiCredentials: TicNoteWifiCredentials?

    /// Archive inbound control frames for use by `TicNoteWifiProbe`.
    /// Capped at 512 entries (a real session typically has a few dozen control frames), preventing unbounded growth.
    private(set) var inboundControlFrames: [Data] = []

    // MARK: Passive archiving (for the UI, and for reconciling against the next capture)

    /// The card's **active push** of the latest session/recording-state notification (`0x14` / `0x17`).
    ///
    /// ⚠️ This is a **passive** observation: copy it in `didUpdateValueFor`, **not inserting into `inbox`**.
    /// See `inbox`'s "single-consumer" constraint — enqueuing it would compete with list/download frame acquisition.
    @Published private(set) var lastSessionNotice: TicNoteRecordingState.SessionNotice?

    /// **Cumulative count** of received session/recording-state frames (monotonically increasing), for logging.
    private(set) var sessionNoticeSequence = 0

    /// Marker for "card-pushed session frames" that have **not yet been fetched by `readRecordingStatus()`**.
    ///
    /// ★ This boolean indicates whether the card acknowledged the recording button press:
    /// The call order of `RecorderSessionModel` is
    /// `startRecording()` → immediately `readRecordingStatus()`, 
    /// If the card accepts the command, it will push a `0x14` / `0x17` between those two steps
    /// (real devices #14818 / #14848 showed this during start recording).
    /// Fetching clears it — thus it always reflects "whether the card spoke after the last query",
    /// not "whether the card has ever spoken in this connection" (the latter is always true, i.e., no information).
    private var pendingSessionNotice = false

    /// Arrival time of the most recent session event (`0x14`/`0x17`). Used to compare "our stop-recording command" with
    /// "the card pushes the event itself", whichever is later — see `pushedRecordingState`.
    private var lastSessionNoticeAt: Date?

    /// Timestamp when we **sent a stop-recording command** (`nil` = never sent, or recording restarted afterwards).
    ///
    /// Reason for separate tracking: the card does not guarantee a `0x17` response for every stop command. Without it,
    /// an earlier `0x14` (session start) would keep the state stuck on "recording" —
    /// resulting in "stop pressed, red dot stays on, timer keeps running".
    private var stopRequestedAt: Date?

    /// Whether the "opening handshake" (identity query + bind frame) has been sent in this connection.
    /// See `provisionSession(force:)` — the 1 Hz poll relies on this to avoid writing the card twice per second.
    private var didProvisionSession = false

    /// **Multiple consecutive status queries receive no response** (see the backoff in `readRecordingStatus`).
    ///
    /// ★ 2026-10-10 added: this counter implements the "Device did not answer in time continuously" solution.
    ///
    /// Real device log (`/tmp/t3.log`): 1 Hz polling sends 4 commands in each burst (`0x03`/`0x06`/`0x09`/`0x1A`).
    /// The window is `recordingStatusWindow` = **1.5 s**, per-frame timeout 0.8 s. If the device stops responding
    /// (during download, just connected, session not opened), this 1.5 s is **pure command-lock occupancy waiting**:
    ///
    /// ```
    ///   16:36:46.262 → WC 0x03 0x06 0x09 0x1A     ← four commands burst
    ///   16:36:47.114 STATUS … received response=[]          ← gave up after 1.5 s, no inbound frames in between
    /// ```
    ///
    /// `listRecordings`, `readDeviceInfo`, and `fetchRecording` all contend for the same lock,
    /// and they are queued FIFO (`cmdWaiters`, **no priority, no timeout**) —
    /// Consequently, a "device not answering" consumes **other** operations' timeout budget as well:
    /// The user sees the list never loading and gets an "device did not respond in time" error.
    ///
    /// Countermeasure: after `statusSilentBackoffAfter` consecutive empty attempts, **skip the entire batch write**,
    /// and return the cached status directly — the function becomes zero I/O, releasing the lock instantly.
    /// When the device replies (pushes a session frame) the counter resets immediately, so "it recovered" is not blocked by this backoff.
    private var statusSilentStreak = 0

    /// After several consecutive empty attempts backoff starts. With a threshold of 3, a 1 Hz poll can hold the lock up to 4.5 s,
    /// whereas when the device is truly recording it answers within the first second (real device ~50 ms), never reaching this threshold.
    private static let statusSilentBackoffAfter = 3

    // MARK: "Is the device actually recording?" — incremental criterion (★ correct answer to user report "after transfer, an extra recording appears")

    /// The most recent `0x18` (recording status report) contains the **bytes written**.
    ///
    /// `0x18` fields are `<u8 len=0x0a> <u32 sid> <u32 recordedBytes> <u8 status>`
    /// (see `TicNoteRecordingState.parse`), so it indicates more than "recording?", namely
    /// **"how many bytes have been written"** — and "still writing" defines "recording".
    private var lastRecordStateBytes: Int?

    /// The most recent moment when **bytes increased** was observed. See `pushedRecordingState`.
    private var recordStateGrowthAt: Date?

    /// How long the "bytes are increasing" condition can hold without reaching a conclusion.
    ///
    /// Real device (`/tmp/t3.log` 16:36:24–28) recording `0x18` byte counts are
    /// `7680 → 16800 → 25440 → 34080 → 42720`, **increasing roughly every 1.08 s** (≈8 KB/s).
    /// Therefore a 6 s window tolerates up to 5 missed polls without concluding — whereas the "session has ended" case
    /// has a stagnant value (real device stays at constant `49920`) that never increments; after 6 s it will be judged as ended.
    ///
    /// ⚠️ This constant is the toggle for the user's complaint:
    /// > "After tapping record, Bluetooth finishes transfer and then automatically starts another recording"
    /// Previously the criterion was "if `0x14` seen within the last 2 hours, consider recording" (`sessionOpenTrustWindow`).
    /// Consequently, the **post-session residual notification** causes the UI to re-enter recording mode and the stopwatch to keep counting,
    /// The user can only tap stop once — and the next residual will light it again.
    private static let recordStateTrustWindow: TimeInterval = 6

    // MARK: Keep-alive (★ Correct answer to users reporting "link goes to sleep")

    /// Keep-alive heartbeat task. `nil` = not keeping alive.
    private var keepAliveTask: Task<Void, Never>?

    /// Timestamp of the **most recent byte transfer** on the link (outbound write / inbound control frame / inbound voice frame all count).
    ///
    /// Purpose: send heartbeats **only when truly idle**. Lists, downloads, 1 Hz polling
    /// When speaking, no extra chatter should be sent — the card firmware accepts only a single in-flight command
    /// (see `runExclusive`), blind periodic sending would just contend for the lock with legitimate work.
    private var lastActivityAt = Date()

    /// Send a heartbeat after each period of inactivity.
    ///
    /// The 20 s basis: the official app speaks at 1 Hz during **recording** (`0x1C` pull-stream + 1 Hz status),
    /// but it does not keep alive periodically when idle — thus the firmware’s self-disconnect timeout **has no measured value**.
    /// 20 s is clearly shorter than the "user perceives disconnection" threshold, yet 20× less frequent than 1 Hz polling;
    /// To adjust, change this single constant. **Do not** set it to 1 s — that would turn it into a continuous stream.
    static let keepAliveIdleInterval: TimeInterval = 20

    /// Minimum heartbeat interval (must be at least this long between heartbeats to prevent `lastActivityAt` from
    /// being repeatedly refreshed by other paths, causing overly frequent heartbeats). Also the check period.
    static let keepAliveTickInterval: TimeInterval = 5

    // MARK: Voice stream — ★ The only **continuous** "card recording" signal

    /// The card is pushing the Opus payload for this recording.
    ///
    /// ## Basis (`bug2-20261008.att.txt`, the 72-second real recording segment)
    /// The previous version claimed "the card is silent during recording", which was derived from statistics on **control frames** —
    /// After including `0x02` voice frames, the reality is the opposite:
    ///
    /// ```
    ///   · 7,398 `0x02` voice frames, each **exactly 90 bytes** = MTU 93 − 3;
    ///   · Layout [0x02][sid u32][offset u32][len u8][80 B Opus payload],
    ///     adjacent frame offsets step by **80**, strictly consecutive with no overlap;
    ///   · Frame rate **~100 fps** (stable 1050 frames in a 10-second bucket);
    ///   · **7,044 × 80 = 563,520 B exactly matches** the fileSize reported by 0x17;
    ///   · The **start/end boundaries of the frame stream exactly align** with the recording window:
    ///     t<5774 contains only a few frames, 5774–5846 maintains 1050 frames per 10 s, then drops to zero after 5846.
    /// ```
    ///
    /// ## Therefore, "whether there are voice frames in the last 1.2 s" indicates "if the card is currently recording"
    /// Much more reliable than `0x14`/`0x17` (those two are one-shot, pushing only four frames total).
    ///
    /// ## ⛔⛔ **However, this signal alone is insufficient — real-device testing on 2026-10-10 invalidated half the assumptions**
    /// The above statement "no polling needed: the card pushes on its own" is **incorrect**.
    /// In round 19, after starting recording with `tools/bleprobe rec`, **silently observe for 8 seconds**, the result is
    /// **0 spontaneous voice frames**; however, in the same round when we actively sent a `0x1C` fragment request, the card immediately responded with
    /// `01 1c 00 <u32 sid> <u8 status>` (we just guessed the wrong sid at the time, so no payload was retrieved).
    /// Retrospectively, the 72-second recording for `bug2` matches: the official app sent **351 `0x1C` requests** throughout the recording.
    /// — the voice stream is **pulled**, not pushed (see §20.7).
    ///
    /// **Consequence (this is the bug I introduced in the previous version)**: `streamingVoice` in
    /// the "recording page open, no active pull" scenario **never becomes `true`** —
    /// resulting in a dark red dot, stopwatch stuck at 0:00, while the card is actually recording.
    /// The true criterion now resides in the second entry of `pushedRecordingState` (`0x18` recording status report)
    /// plus the 1 Hz `0x1A` refresh in `readRecordingStatus`.
    /// **`streamingVoice` is downgraded to "nice-to-have"**: it is true only when we are actually pulling data.
    ///
    /// ## ⚠️ Intentionally implemented as a **computed property**, not a stored `@Published` property
    /// Two reasons, both based on past pitfalls:
    ///   * When the card stops recording, **no frames arrive**, so a "saved true" never gets overridden
    ///     (the `refreshVoiceLiveness` version required the caller to refresh — forgetting once locks it permanently);
    ///   * During recording the frame rate is ~100 Hz; publishing per frame would rebuild the UI 100 times per second.
    /// A computed property yields fresh data on each read with zero notifications, matching its consumers perfectly
    /// (`RecorderSessionModel.cardWatchTask` at 1 Hz, `startRecording` verification loop at 10 Hz).
    var streamingVoice: Bool {
        guard let last = lastVoiceFrameAt else { return false }
        return Date().timeIntervalSince(last) <= Self.voiceLivenessWindow
    }

    /// Arrival time of the most recent voice frame. **Intentionally not `@Published`** — see `streamingVoice`.
    private var lastVoiceFrameAt: Date?

    /// Currently **pulling fragment download** for a recording. `0x02` frames arriving during download **do not count** as "card pushing audio".
    ///
    /// ## ★★ 2026-10-10 on-device evidence: root cause of "imported recording but card reports recording"
    ///
    /// The `0x1C` fragment response used for download **is the `0x02` voice frame** (same frame format, same
    /// `noteVoiceFrame` entry). Thus retrieving a **completed** file was logged as
    /// "card writing to disk". In `/tmp/t4.log` five downloads each immediately mis-reported after completion:
    ///
    /// ```
    /// 20:12:39.989 FETCH  ✅ Assembly complete bytes=126720/126720 fragments=80
    /// 20:12:40.002 XFER   ✅ Stored …
    /// 20:12:40.858 STATUS isRecording=true bytes=126720   ← 0.87 s before last fragment < 1.2 s window
    /// 20:12:41.948 STATUS isRecording=nil  bytes=126720   ← Exceeded 1.2 s window, immediately fell back
    /// 20:13:05.686 XFER   ✅ Stored … 19200B
    /// 20:13:06.700 STATUS isRecording=true bytes=19200
    /// ```
    ///
    /// Two polluted variables, exactly matching the two issues reported by the user:
    ///   · `streamingVoice` stays true for 1.2 s after the last chunk is downloaded
    ///     → `pushedRecordingState` first branch returns true directly
    ///     → `RecorderSessionModel` starts a timer and shows a red dot
    ///     = **"Importing a recording starts the recording hint timer"**;
    ///   · `voiceStreamBytes` is written as **the file size**
    ///     → `readRecordingStatus` reports it as `totalBytes`
    ///     = **"When I import a recording, it indicates the card is recording"** (the `recordingInProgress` message).
    ///
    /// Criterion in one sentence: **the retrieved bytes are not part of "currently writing"**, so during chunk pulling
    /// `noteVoiceFrame` only records diagnostic counts and does not participate in any "recording?" inference.
    ///
    /// ⚠️ Downloads are serialized (`runExclusive`), so a single `Bool` suffices; no counter needed.
    private var isPullingShards = false

    /// Total number of voice frames received in this connection (monotonically increasing, for diagnostics).
    private(set) var voiceFrameCount = 0

    /// The sessionId carried in voice frames — **the start Unix timestamp of the active recording**.
    /// Also serves as the "filename" for this recording (`0x1A` list and `0x1C` request use it as the key).
    private(set) var streamingSessionID: UInt32?

    /// Max offset in the voice stream plus this frame's payload ≈ bytes written for this recording (**device truth**).
    /// `nil` = no voice frames have been seen in this connection yet.
    private(set) var voiceStreamBytes: Int?

    /// Determination window for "still pushing voice".
    ///
    /// Real device frame rate ~100 fps, so ~120 frames are expected in 1.2 s; using 1.2 s instead of 0.2 s,
    /// to tolerate BLE connection interval jitter and occasional packet loss. No new frames within the window → assume the card stopped.
    static let voiceLivenessWindow: TimeInterval = 1.2

    /// The most recent battery reply the card **actively pushed** (battery level + charging flag).
    ///
    /// ★ Reason for this cache: the card **immediately after connection** pushes a `0x09`
    /// (the first frame of the real ATT stream is `#14790 CARD->APP 0x0009 00 64`),
    /// and at that moment our `readDeviceInfo()` hasn't started reading — that frame would be
    /// discarded by `inbox.drain()`, resulting in "battery empty".
    /// A retry usually retrieves it, but this cache provides a zero-cost safety net:
    /// **Information the card proactively sent should not become invalid just because we queried late**.
    ///
    /// ★ 2026-10-13: expanded from "percentage only" to "full reply parsing". The extra half is
    /// **charging flag** (first byte of the reply) — device details need to show "charging / not charging",
    /// and it comes from the **same frame** as the battery level, so there is no reason to cache them separately.
    /// Parsing rule source: `TicNoteDeviceInfoQuery.batteryReading(fromReplyPayload:)`.
    ///
    /// ★ 2026-10-10 changed to `@Published`: `readRecordingStatus()`'s 1 Hz polling now
    /// also sends a `0x09`, so battery level is **refreshed every second** during recording — UI must update accordingly.
    @Published private(set) var lastBatteryReading: TicNoteBatteryReading?

    /// Latest battery **percentage** (projection of `lastBatteryReading`).
    ///
    /// Define a separate name instead of having every call site use `.lastBatteryReading?.percent`:
    /// The contract (`pushedBatteryPercent`) and the 1 Hz poll care only about the "battery value".
    /// It should not be forced to interpret the charging flag.
    var lastBatteryPercent: Int? { lastBatteryReading?.percent }

    /// Latest **charging state** (projection of `lastBatteryReading`).
    ///
    /// Same purpose as `lastBatteryPercent`: the contract (`pushedChargingState`) and
    /// `RecorderSessionModel.cardWatchTask` care only about the "charging/not charging/unknown" three-state value,
    /// It should not be forced to understand the full response structure.
    ///
    /// ⚠️ Direct three-state transmission, **no `?? false` fallback** — `nil` means "unknown", coercing to `false`
    /// would cause the UI to show an "unplugged" state without basis (see `RecorderLink.pushedChargingState`).
    var lastChargingState: Bool? { lastBatteryReading?.isCharging }

    /// Decoded result of the card **general settings** (`0x08` response). `nil` = not read yet / frame length invalid.
    ///
    /// ★ Starting a recording uses its `recScene` — the official `beginRec` is "read settings first, then fetch
    /// the scene value for `recordStart`". If unavailable, fall back to `TicNoteRecordingScene.defaultScene`.
    /// Field layout and cross-validation of two sources are in `TicNoteGeneralSetting`.
    ///
    /// `@Published`: the device page shows a line with the decoded settings, letting the user instantly see
    /// "what scene the card reports" — the recording frame uses this number.
    @Published private(set) var lastGeneralSetting: TicNoteGeneralSetting?

    /// Decoded result of the card **storage usage** (`0x06` response). `nil` = not read yet / frame length invalid.
    ///
    /// ★ Why also keep a copy on the link (instead of only in `RecorderDeviceInfo`):
    /// The UI under the "storage" line needs to display raw metrics like **free / total**,
    /// while `RecorderDeviceInfo.storage` only carries two generic numbers (see `RecorderStorageInfo`).
    /// Here we retain TicNote's full decode (including `thirdField` / `freeState`),
    /// following the same approach as `lastGeneralSetting`.
    @Published private(set) var lastStorage: TicNoteStorageInfo?

    /// Readable inbound control-frame log (circular, up to `inboundLogLimit` entries), newest first.
    ///
    /// Only collect **control frames** (type `0x01`): a download contains 7000+ audio frames,
    /// incoming frames will discard everything except the few useful lines.
    @Published private(set) var inboundLog: [TicNoteInboundLogEntry] = []
    private static let inboundLogLimit = 40
    private var inboundFrameCount = 0

    /// Protocol state machine. **Switch per download** (see `fetchRecording`).
    private(set) var session = TicNoteSession()

    // MARK: State for live transcription (pull while recording)
    //
    // This group is **only used by the `LiveAudioSource` section**, but must be declared in the class body ——
    // Swift extensions cannot add stored properties. See the end of the file
    // `// MARK: - LiveAudioSource`。

    /// The **full 32-bit** sid when the card pushes `0x14`/`0x17`.
    ///
    /// ★ The difference from `lastSessionID` is whether it **can be sent directly as `0x1C`**:
    /// `lastSessionID` captures the "last session frame"; if that frame happens to be `0x18`,
    /// the result is a **truncated 26-bit** erroneous value (§21.4). This is written only on the full value.
    /// Real-device packet capture byte-by-byte reference: `captures/hci-all/bug2-20261008.att.txt` line 38087
    /// (`01 14 00 77 43 c7 6a …`) → line 38103's `0x1C` uses exactly these four bytes.
    private var liveFullSessionID: UInt32?
    /// ⚠️ **No longer writable** (as of 2026-10-12). The retained field exists only to avoid affecting
    /// the candidate ladder of `liveSessionIDCandidates()`.
    ///
    /// It originally held the "truncated sid reported by `0x18` (low 26 bits)". That "truncation" actually is
    /// a product of a one-byte offset error in parsing (see `TicNoteRecordingState.parse`),
    /// after fixing, `0x18` provides the full sid, routed through `liveFullSessionID`.
    private var liveTruncatedSID: UInt32?

    /// The **session number** for live streaming. Incremented by +1 for each new stream.
    ///
    /// ## Why it is required (real-device decision as of 2026-10-12)
    /// In `liveAudio()`, the `onTermination` callback runs **after the stream has ended**,
    /// and it sets `liveStopping` to true and cancels `liveTask`.
    /// Without a session number, the **cleanup of the previous round will immediately abort the pump created for the next round**:
    /// ```
    /// 18:13:17.584 start streaming sid=…
    /// 18:13:17.585 receive stream: fragment=0 received=0B …      ← 1 ms apart
    /// ```
    /// In real-device logs, this 1 ms termination occurs five times in a row, which the user experiences as
    /// "tapping record closes immediately". The session number ensures cleanup only affects **its own round**.
    private var liveGeneration = 0
    /// The active live streaming pump (`nil` = no live session).
    private var livePump: TicNoteLivePump?
    /// The output of the live audio stream. `finish` indicates "the card stopped / we are done".
    private var liveSink: AsyncThrowingStream<Data, Error>.Continuation?
    /// The `Task` that drives the pump (synchronization loop).
    private var liveTask: Task<Void, Never>?
    /// User pressed stop / disconnected — causes the pump to exit on its own in the next loop iteration.
    /// ⚠️ It is **only set to true in `liveStop()`**, and
    /// reset to false when `liveAudio()` starts a new stream. Missing this reset causes it to "stick", making each subsequent stream exit within 1 ms.
    private var liveStopping = false

    private var handshakeContinuation: CheckedContinuation<Void, Error>?
    private var notifyEnabledContinuation: CheckedContinuation<Void, Error>?
    private let inbox = NotifyQueue()

    /// Buffer for inbound byte packet aggregation. See the framing rules in `absorb(_:)`.
    private var inbound = Data()

    // Command serialization: the card firmware accepts only a single in-flight command (the `TicNoteGATT.busyLatchTimeoutMillis` one
    // The lock in the official SDK does exactly this). Here we use the same "queue + exclusive" implementation.
    private var cmdBusy = false
    private var cmdWaiters: [CheckedContinuation<Void, Never>] = []

    /// Incrementing `flag` sequence for list files — on real devices it's 1→2→3→4, the card seems not to verify it, but keeping it consistent is safer.
    private var listFlag: UInt32 = 0

    init(peripheral: CBPeripheral, central: CBCentralManager, serialNumber: String? = nil) {
        self.peripheral = peripheral
        self.central = central
        self.serialNumber = serialNumber
        super.init()
        peripheral.delegate = self
    }

    var displayName: String { peripheral.name ?? TicNoteRecorderSpec.family }

    var isConnected: Bool { peripheral.state == .connected && writeChar != nil && notifyChar != nil }

    // MARK: Handshake

    /// After connection: discover services → discover characteristics → enable notifications → record negotiated MTU.
    ///
    /// ⚠️ Difference from D·NOTE: the official SDK would `requestMtu` here, but **iOS does not allow peripheral/central to initiate
    /// MTU request** (`CBPeripheral` lacks this API). In reality, **the card initiates** MTU exchange
    /// (Real device tests request 93), so on iOS we can only read `maximumWriteValueLength`.
    /// Real device MTU 93 → 90-byte payload per packet, while our frames are at most 16 bytes (`0x1C` request),
    /// Even the minimum 23-byte MTU fits — so we don't perform any application-layer fragmentation, just write one frame at a time.
    func completeHandshake() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.handshakeContinuation = cont
            peripheral.discoverServices([TicNoteGATT.clipService])
        }
        // Application commands use `.withoutResponse`, so we take the no-response write limit as the "actual usable payload".
        negotiatedMTU = peripheral.maximumWriteValueLength(for: .withoutResponse)
            + TicNoteGATT.writePayloadOverhead
        log.info("handshake done mtu=\(self.negotiatedMTU, privacy: .public)")
        TicNoteDiagLog.log("LINK", "GATT handshake completed mtu=\(self.negotiatedMTU) name=\(displayName) sn=\(serialNumber ?? "nil")")
    }

    func handleDisconnect(error: Error?) {
        TicNoteDiagLog.log("LINK", "Disconnected error=\(String(describing: error))"
            + "(this connection received total control frames \(inboundFrameCount), voice frames \(voiceFrameCount))")
        // ★ Keepalive must stop when the link drops: the link is gone, heartbeat would only log repeated failures,
        //   and tasks from the old link would remain pending (reconnect creates a **new** `TicNoteLink`).
        stopKeepAlive()
        writeChar = nil
        notifyChar = nil
        disconnectError = error
        inbox.failAll(with: error ?? RecorderLinkError.notConnected)
        inbound.removeAll()
        // After disconnection, the "card acknowledged recording command" must be cleared: keeping it would cause the first
        // `readRecordingStatus()` to report a false "card confirmed".
        // ⚠️ But `inboundLog` **is not cleared** — disconnection is precisely when that log is most needed
        // (the user wants to capture "what the card said before the drop").
        pendingSessionNotice = false
        // ★ Backoff counter must also reset on disconnection: keeping it would cause the first few polls after reconnect
        //   to back off immediately under the assumption "the previous connection was silent" — while a new connection might respond immediately.
        statusSilentStreak = 0
        // ★ Incremental criteria also need resetting: retaining the previous connection's "byte count increasing" would cause after reconnect
        //   the first 6 s to report a false "recording".
        lastRecordStateBytes = nil
        recordStateGrowthAt = nil
        // Session events, voice stream accounting, and the "stop recording command we sent" must all be cleared on disconnection:
        // Keeping them would cause the first status read after reconnect to report the **previous connection**'s recording state.
        lastSessionNotice = nil
        lastSessionNoticeAt = nil
        stopRequestedAt = nil
        lastVoiceFrameAt = nil
        streamingSessionID = nil
        voiceStreamBytes = nil
        // ★ "Fetching fragments" must also reset on disconnection: if the link drops mid-process, `runExclusive`'s
        //   `defer` may not execute (the link object is replaced), keeping it would cause on the **new link**
        //   all voice frames to be treated as "downloading fragments" and never marked alive — the red dot never lights again.
        isPullingShards = false
        // When the connection drops, the "intro" also becomes invalid — it must be resent on the next connection.
        didProvisionSession = false
        // `streamingVoice` is a computed property; after `lastVoiceFrameAt = nil` it automatically becomes false.
        if let cont = handshakeContinuation {
            handshakeContinuation = nil
            cont.resume(throwing: error ?? RecorderLinkError.notConnected)
        }
        if let cont = notifyEnabledContinuation {
            notifyEnabledContinuation = nil
            cont.resume(throwing: error ?? RecorderLinkError.notConnected)
        }
    }

    // MARK: Command Serialization

    private func acquireCmdLock() async {
        if !cmdBusy {
            cmdBusy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            cmdWaiters.append(cont)
        }
        // When awakened, the previous holder has already set cmdBusy to true for us (see releaseCmdLock).
    }

    private func releaseCmdLock() {
        if cmdWaiters.isEmpty {
            cmdBusy = false
        } else {
            let next = cmdWaiters.removeFirst()
            next.resume()
        }
    }

    private func runExclusive<T>(_ op: () async throws -> T) async throws -> T {
        await acquireCmdLock()
        defer { releaseCmdLock() }
        return try await op()
    }

    // MARK: Keep-alive

    /// Start keep-alive. Repeated calls are no-op (won’t start a second heartbeat task).
    ///
    /// ⚠️ Must be callable via `any RecorderLink` — it’s also a **protocol requirement**,
    /// Placing it only in an extension would be statically dispatched away (see the protocol note).
    func startKeepAlive() {
        guard keepAliveTask == nil else { return }
        guard isConnected else {
            TicNoteDiagLog.log("KEEPALIVE", "Not started: isConnected=false")
            return
        }
        lastActivityAt = Date()
        TicNoteDiagLog.log("KEEPALIVE",
            "Start idle threshold=\(Int(Self.keepAliveIdleInterval))s"
            + " check interval=\(Int(Self.keepAliveTickInterval))s")
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.keepAliveTickInterval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.keepAliveTick()
            }
        }
    }

    /// Stop keep-alive. **Must be called on disconnect** — otherwise the task hangs with the old link.
    func stopKeepAlive() {
        guard keepAliveTask != nil else { return }
        keepAliveTask?.cancel()
        keepAliveTask = nil
        TicNoteDiagLog.log("KEEPALIVE", "Stopped")
    }

    /// One tick: if idle long enough, send a **read-only** heartbeat.
    ///
    /// Three constraints; missing any turns it into a burden:
    ///   1. **Use `runExclusive`** — shares the same command lock with list/download/1 Hz polling,
    ///      If lock not acquired, skip this tick (try next); never compete with main tasks.
    ///   2. **Re-check idle inside lock** — waiting for lock may be long; the device could have spoken meanwhile;
    ///   3. **Read-only, idempotent** — see why `0x09` is chosen below.
    ///
    /// ## Why the heartbeat frame uses `0x09` (battery) instead of `0x03` (status) or `0x08` (config)
    ///   • It’s the **shortest** of the three read-only commands: request empty payload, response 2 bytes (`01 09 00 <pct>`),
    ///     A heartbeat costs 3 + 2 bytes on the wire;
    ///   • Its response also updates `lastBatteryPercent` — so “real-time battery sync”
    ///     doesn’t stale when the user has no UI open, effectively a free feature;
    ///   • In `readDeviceInfo` it’s already validated on real hardware on the same read-only path (`01 09 00` → `00 64`),
    ///     not a newly risky command.
    /// ⛔ **Do not** replace with frames that change card state (`0x0C`/`0x0E` etc.) — heartbeat must be repeatable indefinitely.
    private func keepAliveTick() async {
        guard isConnected else { return }
        guard Date().timeIntervalSince(lastActivityAt) >= Self.keepAliveIdleInterval else { return }
        do {
            _ = try await runExclusive { () -> Bool in
                guard Date().timeIntervalSince(self.lastActivityAt) >= Self.keepAliveIdleInterval
                else { return false }
                return try self.write(
                    TicNoteFrameCodec.frame(rawCmd: TicNoteObservedCommand.getBattery.rawValue)
                )
            }
        } catch {
            // Heartbeat failure **not reported**: its sole purpose is "keep the link alive",
            // Failure should not generate a phantom UI error (real failures are reported via the main path).
            TicNoteDiagLog.log("KEEPALIVE", "Heartbeat failed error=\(String(describing: error))")
        }
    }

    // MARK: Write

    /// Write a full frame. **No fragmentation** — this card’s link has no application-layer framing (`TicNoteGATT.usesSubPacketFraming`).
    ///
    /// `response: true` uses **write with response** (ATT Write Request). Defaults to write without response:
    /// The read-command/chunk-request main path is verified on a real device; leave it alone.
    ///
    /// But two frame types officially go through write with response (the App log in `captures/bug` shows
    /// `writeCharacteristicWithResponse` right after the "stop sync" line):
    /// · `0x1D` (stop sync) —— see `stopBLEsync()`
    /// · the cleanup action before recording starts
    /// A write with response gets an ATT-layer confirmation, which means **the card truly accepted this frame**.
    /// ⚠️ The characteristic must declare `.write` support, otherwise `writeValue(type: .withResponse)`
    /// throws an ObjC exception (not a Swift error, can't be caught). So here we check `properties` first;
    /// if unsupported, **fall back** to write without response — never take the risk.
    @discardableResult
    private func write(_ frame: Data, response: Bool = false) throws -> Bool {
        guard isConnected, let ch = writeChar else {
            throw RecorderLinkError.notConnected
        }
        let withResponse = response && ch.properties.contains(.write)
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        let limit = peripheral.maximumWriteValueLength(for: type)
        guard frame.count <= limit else {
            // Hitting this means the MTU is smaller than expected (or someone adds long frames later). **Never** silently truncate ——
            // the peer would treat the truncated frame as a new command; the symptom is "card going crazy", not "can't send".
            TicNoteDiagLog.log("!REJECT", "outbound \(frame.count) B > MTU payload \(limit) B")
            throw RecorderLinkError.malformed("outbound frame \(frame.count) B > MTU payload \(limit) B")
        }
        // Persisted diagnostics: log every outbound command frame, **and log the ATT write type along with it** (`WR`/`WC`).
        // Why these two must appear as a pair: "command sent, card seems deaf" is nine times out of ten
        // the wrong write type used here —— the frame bytes are all correct, yet the card just won't accept it. See the table in `stopSynchronization`.
        TicNoteDiagLog.frame(withResponse ? "→ WR" : "→ WC", frame)
        // ★ Outbound also counts as "activity on the link" —— keep-alive uses this to decide "whether to send a top-up".
        lastActivityAt = Date()
        peripheral.writeValue(frame, for: ch, type: type)
        return withResponse
    }

    // MARK: inbound frame splitting

    /// Merges the bytes of one notify into the buffer, and splits out **complete frames** per TicNote's frame format.
    ///
    /// Framing rules (two of them, neither guessed):
    ///
    /// 1. **`0x02` voice frames**: `10 + buf[9]` is the full frame length. On the real device, 7397/7397 frames had `buf[9] == 0x50`
    ///    → 90 bytes. If a frame isn't complete, leave it in the buffer and wait for the next notify (with MTU squeezed to 23 it genuinely arrives in two parts).
    ///
    /// 2. **`0x01` control frames**: **no length field in the frame** (nothing follows `[type][cmd u16 LE][payload]` as a
    ///    len), so boundaries **cannot** be recovered from the byte stream. What this relies on is a measured fact:
    ///    one ATT notification = one whole frame (largest real-device control frame is 71 bytes < MTU 93 − 3 = 90,
    ///    so there is no need to span packets at all). So treat **all bytes currently in the buffer** as one frame.
    ///
    ///    ⚠️ Boundary of this rule: if control frames > 90 bytes ever appear (e.g. long-text replies 0x40/0x42,
    ///    officially truncated to 230 bytes, **will span packets**), this code would dispatch a half-frame as a whole frame.
    ///    At that point it must be changed to "look up fixed length by cmd" or have the peer send the length first. Not implemented now because
    ///    the read-recording path **never** receives that kind of frame.
    private func absorb(_ chunk: Data) {
        inbound.append(chunk)
        while true {
            let bytes = [UInt8](inbound)
            guard let first = bytes.first else { return }

            if first == TicNotePacketType.voiceData.rawValue {
                guard bytes.count >= 10 else { return }          // not even the length byte has arrived yet
                let declared = Int(bytes[9])
                // The length byte is only a hint: on real hardware it's always 80; on any anomaly fall back to splitting by the frame-length constant,
                // and let `TicNoteVoiceChunk.isWellFormed` report "length byte mismatch".
                let need = (declared > 0 && 10 + declared <= TicNoteGATT.voiceFrameBytes)
                    ? 10 + declared
                    : TicNoteGATT.voiceFrameBytes
                guard bytes.count >= need else { return }
                inbound = Data(bytes[need...])
                let frame = Data(bytes[0..<need])
                // ★ Bookkeep first (timestamp/sid/offset), then enqueue — see `streamingVoice`.
                //   Order is intentional: once enqueued, the frame belongs to the consumer and must not be snooped again.
                noteVoiceFrame(frame)
                inbox.push(frame)
                continue
            }

            if first == TicNotePacketType.commandResponse.rawValue {
                // Rule 2: the entire buffer is one frame.
                inbound.removeAll()
                inbox.push(Data(bytes))
                continue
            }

            // Unknown packet type (e.g. 0x03 live audio stream): not supported on this path, **discard the whole buffer** and log it.
            // Cannot "skip the first byte and keep searching" — that would create spurious frame boundaries in the voice stream.
            log.warning("unsupported packet type 0x\(String(format: "%02X", first), privacy: .public), dropping \(bytes.count, privacy: .public) B")
            inbound.removeAll()
            return
        }
    }

    /// Wait for the next **complete inbound frame**.
    ///
    /// ⚠️ Errors **must be translated**: on timeout the underlying queue (`NotifyQueue`, shared with D·NOTE) throws
    /// `DnoteError.timeout`, whose localized message is **"The device did not respond within the time limit."** —
    /// that's D·NOTE's wording. Without translation, a list timeout on the TicNote card would make the whole page display
    /// this message that has nothing to do with the card (it already happened once on real hardware).
    private func nextFrame(timeout: TimeInterval = 5) async throws -> Data {
        do {
            return try await inbox.pop(timeout: timeout)
        } catch {
            throw TicNoteInboundError.map(error)
        }
    }

    // MARK: Passive observation (never enters the queue, purely a copy)

    /// Copies inbound control frames: feed the UI log, and incidentally recognize session/recording state.
    ///
    /// ⚠️ **Read-only**. Never send commands here, and never consume anything from `inbox` —
    /// this is a bypass on the `didUpdateValueFor` path; any "doing something on the side" would
    /// steal frames from the list/download/read-device-info consumers (see the single-consumer constraint on `inbox`).
    private func observeControlFrame(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { return }
        let cmd = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        let payload = Data(bytes[3...])

        inboundFrameCount += 1
        // ★ Inbound traffic also counts as "activity on the link" — while the card is pushing voice/sending replies the link is alive anyway.
        lastActivityAt = Date()
        // Diagnostics to disk: log all inbound control frames (control frame rate is on the order of 1 Hz, won't flood).
        // Paired with the outbound `→` lines, this restores the full timeline of "what we sent → what the card answered" —
        // which is the only useful thing when diagnosing an "operation failed".
        TicNoteDiagLog.frame("← CTL", data)
        let now = Date()
        // Consecutive frames with identical content are collapsed into one line (`repeatCount`) — rationale:
        // `TicNoteInboundLogEntry.repeatCount`: 1 Hz polling returns two identical
        // `0x03`/`0x06` per second; without collapsing, the log fills with repeats within 20 seconds.
        if var head = inboundLog.first, head.cmd == cmd, head.payload == payload {
            head.repeatCount += 1
            head.lastAt = now
            inboundLog[0] = head
        } else {
            let entry = TicNoteInboundLogEntry(id: inboundFrameCount,
                                               cmd: cmd,
                                               payload: payload,
                                               at: now)
            // Newest first, ring-buffer truncation.
            inboundLog.insert(entry, at: 0)
            if inboundLog.count > Self.inboundLogLimit {
                inboundLog.removeLast(inboundLog.count - Self.inboundLogLimit)
            }
        }

        if TicNoteRecordingState.isSessionNotice(cmd),
           let notice = TicNoteRecordingState.parse(cmd: cmd, payload: payload) {
            lastSessionNotice = notice
            lastSessionNoticeAt = Date()
            sessionNoticeSequence += 1
            pendingSessionNotice = true
            // ★★★ The sid to use for live streaming.
            //
            // ⚠️ 2026-10-12 correction: this originally branched on "the two session frames' sid having different reliability" —
            //   `0x14` / `0x17` → full 32 bits; `0x18` → "truncated to 26 bits".
            //   **That "truncation" was an artifact caused by a parsing offset that was off by one byte**
            //   (see the docs on `TicNoteRecordingState.parse`: on real hardware the `0x18` payload is
            //   `B5 B2 CC 6A 02 …`, sid taken from b[0]; old code took from b[1],
            //   resulting in a seemingly reasonable but wrong value `0x026ACCB2`).
            //
            //   The consequence is not "slightly less precision", but **the entire real-time stream will inevitably fail**:
            //   Sending the wrong value `0x1C` causes the card to reply `02` (rejection), all four candidates are rejected,
            //   abort after 0.13 s — the UI shows a red dot that lights briefly then disappears.
            //
            //   Now the three session frames have sid **from the same source, same confidence, and are full 32-bit**
            //   (On a real device during the same recording: `0x18` reports `0x6ACCB2B5`, followed by `0x17`
            //   also reports `0x6ACCB2B5`), so we always write it into `liveFullSessionID`.
            //   `liveTruncatedSID` is kept only to avoid affecting `liveSessionIDCandidates()`
            //   candidate ladder, but **there is no longer any write point** (it stays nil forever).
            liveFullSessionID = notice.sessionID
            // ★ Incremental criteria only make sense for `0x18` (only it carries "bytes written").
            //   When it increases, record the timestamp; when it doesn't, **do nothing** (neither record "no increase", nor immediately deem dead) —
            //   see `pushedRecordingState` for rationale: a single sample cannot explain the issue.
            if notice.isRecordStateEvent, let bytes = notice.fileSize {
                if let previous = lastRecordStateBytes, bytes > previous {
                    recordStateGrowthAt = Date()
                }
                lastRecordStateBytes = bytes
            }
            // ⚠️ An interpolated string cannot be concatenated with `+` — `OSLogMessage` is not a String (compilation will fail).
            log.info("session event 0x\(String(format: "%04X", cmd), privacy: .public) sid=\(notice.sessionID, privacy: .public) scene=\(notice.scene.map(String.init) ?? "—", privacy: .public) size=\(notice.fileSize.map(String.init) ?? "—", privacy: .public)")
        }

        // Card-pushed battery level (including charging flag) — cache it, see `lastBatteryReading` for rationale.
        if cmd == TicNoteObservedCommand.getBattery.rawValue,
           let reading = TicNoteDeviceInfoQuery.batteryReading(fromReplyPayload: payload) {
            let previous = lastBatteryReading
            lastBatteryReading = reading
            // ★ Log a diagnostic only when the **charging state flips** (or on first read).
            //   Battery level updates every second; logging each would fill the log — see constraints in `TicNoteDiagLog`.
            //   "Power plugged / unplugged" is exactly when users ask, so a trace must be left:
            //   It also serves as a **new sample** for this byte criterion (first byte = charging) on a real device,
            //   allowing direct verification on the next packet capture (see confidence notes in `TicNoteBatteryReading`).
            if previous == nil || previous?.isCharging != reading.isCharging {
                let chargeText = reading.isCharging.map { $0 ? "Charging" : "Not charging" }
                    ?? "Charging flag unknown"
                TicNoteDiagLog.log("BATT",
                    "Battery \(reading.percent)% · \(chargeText) (0x09 first byte=0x\(String(format: "%02X", reading.flag)))")
            }
        }
    }

    /// Log when a **complete voice frame** is received (`absorb` called on frame cut, **does not consume the queue**).
    ///
    /// This is the sole data source for `streamingVoice`. Performs three zero-overhead tasks:
    /// Record timestamp, accumulate frame count, extract sid and offset — no extra reads per frame.
    private func noteVoiceFrame(_ frame: Data) {
        let b = [UInt8](frame)
        guard b.count >= 10 else { return }
        voiceFrameCount += 1
        // ★ Voice frames also count as activity (at 100 fps the heartbeat path is bypassed, `lastActivityAt` gets refreshed automatically).
        lastActivityAt = Date()

        // ★★ Downloading shards **is not** "card stuck pushing audio" — see `isPullingShards`.
        //    Must early-exit here: once `lastVoiceFrameAt` or `voiceStreamBytes` become dirty,
        //    the UI shows "recording + timer", but the card is merely delivering an old file.
        guard !isPullingShards else {
            if voiceFrameCount == 1 || voiceFrameCount % 100 == 0 {
                TicNoteDiagLog.log("VOICE",
                    "#\(voiceFrameCount) fragment reply (downloading, not counted as \"recording\" evidence)")
            }
            return
        }

        lastVoiceFrameAt = Date()
        let sid = UInt32(b[1]) | (UInt32(b[2]) << 8) | (UInt32(b[3]) << 16) | (UInt32(b[4]) << 24)
        let offset = UInt32(b[5]) | (UInt32(b[6]) << 8) | (UInt32(b[7]) << 16) | (UInt32(b[8]) << 24)
        streamingSessionID = sid
        // Disk write diagnostic: real device voice frames ~100 frames/s, only record **the first** and **every 100th**
        // (see constraint 2 of `TicNoteDiagLog`). The arrival time of the first entry is "card actually pushing audio"
        // the earliest evidence — if it doesn't arrive promptly after recording starts, it indicates the start wasn't accepted by the card.
        if voiceFrameCount == 1 || voiceFrameCount % 100 == 0 {
            TicNoteDiagLog.log("VOICE", "#\(voiceFrameCount) sid=\(sid) off=\(offset) len=\(b[9])")
        }
        // offset is **the internal write position of this recording** (real device 0,80,160,…), so
        // "max offset + this frame payload" equals the number of bytes the card has written to the file up to this point.
        //
        // ⚠️ Real device has seen a `offset = 0xFFFFFFFF` **trailer sentinel frame** (the one near `#14790`
        //    all-zero frame), it is a "flush buffer to disk" signal, not audio. Do not discard it,
        //    `voiceStreamBytes` can spike to the 4 GB range instantly (measured to compute as 4,294,967,375).
        if offset != 0xFFFF_FFFF {
            let payloadBytes = Int(b[9])
            let end = Int(offset) + payloadBytes
            if end > (voiceStreamBytes ?? 0) { voiceStreamBytes = end }
        }
    }

    /// Enter "pull shard" state. See `isPullingShards`.
    ///
    /// ★ Also clear **the trace left by the previous pull**, both items required:
    ///   * `lastVoiceFrameAt = nil` — otherwise "the just-finished fragment" can still occupy a 1.2 s survival window,
    ///     causing the download to report "card stuck pushing audio" at start;
    ///   * `voiceStreamBytes = nil` — otherwise the stopwatch on the UI will **continue from the previous file's**
    ///     byte count **downward** (real device `bytes=126720` came from this).
    ///
    /// ⚠️ Clearing `voiceStreamBytes` does not cause data loss in the "actually recording" scenario: in that case
    ///    `lastSessionNotice.fileSize` can immediately take over (`readRecordingStatus`'s
    ///    `cachedBytes` is a choice between the two).
    private func beginShardPull() {
        isPullingShards = true
        lastVoiceFrameAt = nil
        voiceStreamBytes = nil
    }

    /// Exit "pull shard" state. **Must be paired with `beginShardPull`** (use `defer` at the call site).
    private func endShardPull() {
        isPullingShards = false
    }

    // MARK: RecorderLink — state pushed by the card (read-only cache)

    /// "Recording?" pushed **actively by the card**. **No I/O performed** — see protocol documentation.
    ///
    /// Determination order (earlier takes precedence):
    ///   1. **Voice frame stream still alive** → `true`. This is the strongest evidence: the card only pushes
    ///      `0x02` stream, and real-device measurements show the frame stream boundaries exactly match the recording window.
    ///      ⚠️ However, real devices have confirmed the voice stream is **extracted by `0x1C`**, not pushed spontaneously by the card
    ///      (§20.7 / §21.4), so this condition **never holds** in the "view-only-recording-page" scenario.
    ///      The real fallback is condition 2 below.
    ///   2. Most recent session event:
    ///      · **`0x18` (recording status report) → `true`**. ★ This was added in the 19th round of real-device testing,
    ///        and is **the only signal the card actively returns that reflects recording progress in real time** —
    ///        The card returns this after receiving the start-recording command (not `0x14`). Missing this,
    ///        The card clearly recorded, but the UI reports "recording not started".
    ///      · `0x14` (session start) → `true`; `0x17` (session end) → `false`.
    ///        ⚠️ `0x14` is trusted only within **2 hours from the card's own start timestamp** — beyond that indicates
    ///        that this `0x14` has already expired (a single recording on the card lasts at most ~49 minutes).
    ///   3. No events seen → `nil` ("unknown", **not** `false`).
    /// ## ★★ 2026-10-10 Rewrite criteria: **"byte count still increasing" means recording**
    ///
    /// User quote:
    /// > "After tapping record, Bluetooth finishes transfer and then automatically starts another recording"
    ///
    /// Old criteria (`0x18`/`0x14` → `true`, with `0x14` trust window = `sessionOpenTrustWindow`
    /// = **2 hours**) had a fatal flaw: **the notification after session end still counted**.
    /// So after "one recording transferred", the UI shows another "recording in progress",
    /// the timer keeps incrementing second by second (the user’s "recording increase"), forcing another stop tap;
    /// and if the card pushes another residual notification, it lights again — cannot finish tapping.
    ///
    /// Now switched to an **incremental criterion**, because "writing to storage" defines "recording".
    ///
    /// | Latest event | Criterion | Basis |
    /// |---|---|---|
    /// | Voice frame stream alive | `true` | Frame stream boundary aligns with recording window |
    /// | `0x18` and **byte count increasing** | `true` (`recordStateGrowthAt` within 6 s) | Real device 7680→16800→25440→42720, ~1.08 s per increment |
    /// | `0x18` but byte count **stagnant** | `true` for first 6 s, then **`false`** | Residual value after session end stays at 49920, no growth per second |
    /// | `0x14` (session start) | `true` for 6 s, then **`false`** | Physical start button yields only this; 1 Hz polling will receive `0x18` within 1 s |
    /// | `0x17` (session end) | `false` | Device ground truth |
    ///
    /// ⚠️ The 6 s "guidance window" is **required**, not conservative: the first `0x18` right after start
    /// reports **0 bytes** (real device `… 02 00 00 00 00 00`), showing no increment on its own.
    /// 6 s allows polling to make 5–6 cycles, confirming the "increasing" condition.
    ///
    /// ⚠️ Here we prefer **under-reporting** to over-reporting: mis-detecting "recording" forces the user to tap stop (as in this case
    /// complaint), mis-detecting "not recording" only delays the red indicator by a few seconds. The direction must not reverse.
    ///
    /// ## ★★ 2026-10-10 Add clause 2: **once a session event is seen, `nil` no longer appears**
    ///
    /// The cost of `nil` is not "under-reporting" but **stuck state**: `RecorderSessionModel.noteDeviceRecordingState`
    /// contains a `guard let deviceSays` that returns immediately on `nil`, doing nothing.
    /// Thus a false `true` can never drop back — real device `/tmp/t4.log` capture:
    ///
    /// ```
    /// 20:12:40.858 isRecording=true    ← false positive (source already blocked by isPullingShards)
    /// 20:12:41.948 isRecording=nil     ← cannot clear
    /// 20:12:43.105 isRecording=nil     ← cannot clear
    /// 20:12:44.054 STOP command sent      ← user must press stop manually
    /// ```
    ///
    /// Therefore: `lastSessionNotice == nil` (**this connection** has never heard the device speak) is the only
    /// valid "unknown"; once heard, each branch must return an explicit `Bool`.
    var pushedRecordingState: Bool? {
        if streamingVoice { return true }
        // We sent a stop command later than the device's last event → even if the device doesn't reply `0x17`, it's considered stopped.
        if let requested = stopRequestedAt,
           requested > (lastSessionNoticeAt ?? .distantPast) {
            return false
        }
        // ⚠️ This is the **only** valid `nil`: this connection has never heard any session event from the device
        //    (`handleDisconnect` clears `lastSessionNotice`, so "this connection" is accurate).
        guard let notice = lastSessionNotice else { return nil }
        // Time since the device's last utterance — used as the guide window for both commands.
        let silence = Date().timeIntervalSince(lastSessionNoticeAt ?? .distantPast)

        // ★ `0x18` only appears after a "start recording" command is accepted, so its presence ≠ recording —
        //   also check **whether byte count is still increasing** (the core of this change).
        //   Note that its `recordedBytes` starts at 0, **cannot** use "bytes > 0" as a criterion,
        //   otherwise the first 1.6 s of recording would be judged as "not recording".
        if notice.isRecordStateEvent {
            if let grew = recordStateGrowthAt {
                return Date().timeIntervalSince(grew) < Self.recordStateTrustWindow
            }
            // Seen `0x18` but **never increased**: either just started recording (await next packet),
            // or it's a leftover after session end. Outside the guide window always evaluate to `false`.
            return silence < Self.recordStateTrustWindow
        }

        guard notice.isStartEvent else { return false }   // Last event was 0x17 → already ended
        if let startedAt = notice.startedAt,
           Date().timeIntervalSince(startedAt) > Self.sessionOpenTrustWindow {
            // ★ Change from `nil` to `false`: a `0x14` older than 2 h **cannot prove anything**,
            //   and "cannot prove recording" equals "based on current evidence, it's not recording".
            //   Returning `nil` would permanently pin the above false positive `true` on the UI (see real log in function header).
            //   ⚠️ Saying it "doesn't mean not recording" is also valid, but the cost is asymmetric: with `false` the worst case is a delayed red dot
            //   by a few seconds (1 Hz poll will soon deliver `0x18` to correct it), while `nil` freezes the UI.
            return false
        }
        // `0x14`: when the device starts recording via its physical button, it only sends this packet (the App-initiated start follows
        // `RecorderSessionModel`'s optimistic state, not relying on this). Trust only the guide window —
        // Afterwards the criterion is "byte count increasing", see the table above.
        return silence < Self.recordStateTrustWindow
    }


    /// Device **pushes** (or we just read) battery level. Read-only cache, no I/O.
    var pushedBatteryPercent: Int? { lastBatteryPercent }

    /// Device **pushes** (or we just read) charging state. Read-only cache, no I/O.
    ///
    /// Same frame as `pushedBatteryPercent` (`0x09`), two fields extracted —
    /// So this line adds no extra BLE round-trip; it merely exposes the other half of the received packet.
    /// Contract and usage see `RecorderLink.pushedChargingState`.
    var pushedChargingState: Bool? { lastChargingState }

    /// The `0x14` “session still open” can be trusted for at most 2 hours. The longest real-device recording on the card is
    /// 49 minutes (23.6 MB, see `TicNoteFileEntry`); a single entry cannot exceed 2 hours,
    /// Hence we use this upper bound to cover the case where the connection stays alive and an old `0x14` never expires.
    private static let sessionOpenTrustWindow: TimeInterval = 2 * 3600

    // MARK: RecorderLink – List recordings

    /// List recordings.
    ///
    /// Real-device exchange: `01 1A 00 <u32 flag> <u32 since> <u8>` → card response
    /// `01 1A 00 <u32 flag> <u32 count> count × [u32 startSec][u32 byteCount][u16 type]`.
    ///
    /// Sending **0** for `since`: the official app sends a fixed early timestamp
    /// (`0x69D9EAF5` = 2026-04-11, while all 5 recordings on the card are after 2026-07),
    /// It serves to “only include recordings after this time”. Sending 0 means **full set**.
    /// ⚠️ Do not send “current device time − N days”: the card’s RTC is about six months behind real time
    /// (this is why `0x04` time-sync is required); otherwise **all** recordings get filtered out.
    ///
    /// ## ★★★ 2026-10-10 Real-device decision: **send an opening handshake before listing files**
    ///
    /// This is the root cause of “Device did not answer in time **continuously**”, discovered empirically, not guessed.
    ///
    /// Real-device log (`/tmp/t3.log`, the **fresh connection** at 16:36:00):
    ///
    /// ```
    ///   16:36:00.656 LINK GATT handshake completed            ← just connected
    ///   16:36:00.728 → 0x1A flag=1                 ┐
    ///   16:36:05.961 → 0x1A flag=2                 │ three zero-response sends,
    ///   16:36:11.212 → 0x1A flag=3                 ┘ each waited full 5 s before giving up
    ///   16:36:22.156 ← 0x14 (card finally responds)
    ///   16:36:23.741 PROV opening handshake start force=false    ← ★ first opening handshake sent here
    ///   16:36:23.957 → binding frame
    ///   16:36:24.162 → 0x1A flag=1                 → card replies immediately per entry
    /// ```
    ///
    /// The three 15 s “card ignores us” periods **all occurred before the opening handshake**.
    /// Previously the handshake was sent only via two paths: before recording starts (`force: true`) and in the 1 Hz poll
    /// (`readRecordingStatus` → `provisionSession(force: false)`) – the latter
    /// **runs only when `isRecording == true`**. Thus in the "just connected, recording not started" scenario
    /// the most common case, the handshake **has never been sent**, and the first task on this page is precisely to list recordings.
    ///
    /// Therefore we now place the handshake **at the start of this method**, together with `fetchRecording`'s
    /// `0x1D` pre-step, same idea: **if the card hasn't been formally introduced on this connection, introduce it once first.**
    /// - `force: false` → skip if already sent on this connection, so it **does not** write two frames for every listing.
    ///   Normally only the first round of the current connection is actually sent;
    /// - After sending, must `inbox.drain()`: the handshake makes the card **dump a complete list along with it**
    ///   (real device 16:36:23.99 → 9 `0x1A` notifications); if not cleared, they mix with the one we're waiting for.
    ///
    /// ## Self-healing retry round
    ///
    /// Even if the handshake wasn't missed, the card may still go silent — on the real device, after sending `01 1E 00 <sid> 00` once at 16:40:46
    /// (delete), **none of the subsequent 4 `0x1A` got any reply** (while at the same time `0x09` kept replying,
    /// showing the card was alive, just refusing to list files):
    ///
    /// ```
    ///   16:40:46.272 → WC 01 1E 00 CF F9 C9 6A 00     ← delete
    ///   16:40:46.273 → WC 01 1A 00 12 …                ← zero reply
    ///   16:40:57.029 → WC 01 1A 00 13 …                ← zero reply
    ///   16:41:07.643 → WC 01 1A 00 14 …                ← zero reply
    ///   16:41:15.406 → WC 01 1A 00 15 …                ← zero reply
    ///   (meanwhile 16:41:08.507 ← 0x0B / 16:41:08.508 ← 0x09 were normal)
    /// ```
    ///
    /// This is externally identical to the "stale handshake" symptom (frame bytes all correct, yet the card stays silent),
    /// so the remedy follows the `fetchRecording` one: **do a full handshake again (`force: true`), then list one more round**.
    ///
    /// ⚠️ Retry only **one round**: when the card is truly dead, retrying just turns the 8 s budget into 16 s,
    /// which isn't self-healing. Failures are thrown as-is, and the UI displays the reason.
    func listRecordings() async throws -> [RecorderRecording] {
        try await runExclusive {
            guard self.isConnected else {
                TicNoteDiagLog.log("LIST", "✗ Called before the card was connected (isConnected=false)")
                throw RecorderLinkError.notConnected
            }
            TicNoteDiagLog.log("LIST", "Starting recording list")

            var attempt = 0
            while true {
                attempt += 1
                self.listFlag &+= 1
                let flag = self.listFlag
                self.inbox.drain()

                // ★ Handshake first (reason in this method's doc). Failure doesn't block — better to try once more
                //   than to let a handshake that "merely failed to send" seal off the only listing path.
                await self.provisionSession(force: false)
                self.inbox.drain()

                self.session = TicNoteSession()
                do {
                    try self.write(self.session.beginListing(flag: flag, since: 0))
                } catch {
                    TicNoteDiagLog.log("LIST",
                        "✗ Failed to write list request (round \(attempt)): \(String(describing: error))")
                    throw error
                }

                // Wait for the `0x1A` response. The card's status pushes may be interleaved in the meantime (0x06/0x17/0x1C…),
                // feed them all into the state machine to ignore — **never** "take the next notification directly as the list".
                //
                // ⚠️ Frame timeouts **must be caught locally**: when `nextFrame` throws `.timeout`, the meaning is
                //    "the card went silent", exactly the kind of failure to retry. The previous version let it propagate straight out,
                //    so every failure burned a fixed 5 s (all three sends at 16:36 on the real device took 5.2 s each),
                //    and the retry branch never got a chance to run.
                var failure: RecorderLinkError?
                let deadline = Date().addingTimeInterval(Self.listWindow)
                while !self.session.phase.isTerminal {
                    if Date() > deadline { failure = .timeout; break }
                    guard let frame = try? await self.nextFrame(timeout: Self.listFrameTimeout) else {
                        failure = .timeout
                        break
                    }
                    _ = self.session.ingest(frame)
                }
                if failure == nil, case .failed(let reason) = self.session.phase {
                    failure = .malformed("list failed: \(reason)")
                }

                if let failure {
                    guard attempt < Self.listMaxAttempts, !Task.isCancelled else {
                        TicNoteDiagLog.log("LIST",
                            "✗ List failed (round \(attempt), flag=\(flag)):"
                            + "\(String(describing: failure))")
                        throw failure
                    }
                    TicNoteDiagLog.log("LIST",
                        "⚠️ List got no reply (round \(attempt), flag=\(flag))"
                        + "→ send the opening line once more, then list again")
                    await self.provisionSession(force: true)
                    self.inbox.drain()
                    continue
                }

                self.lastRecordings = self.session.recordings
                log.info("listed \(self.session.fileEntries.count, privacy: .public) recordings")
                TicNoteDiagLog.log("LIST",
                    "✅ Listed \(self.session.recordings.count) recordings"
                    + "(file entries \(self.session.fileEntries.count), round \(attempt), flag=\(flag))")
                return self.session.recordings
            }
        }
    }

    /// Overall window for listing files.
    ///
    /// ⚠️ Not the same thing as `recordingStatusWindow`: that one is the 1 Hz poll's "read a small sip",
    /// this one is "get a complete list". On the real device the card splits the list into 9 notifications (7 per page,
    /// see `TicNoteFileList.parse`), and normally all of them arrive **within 10 ms** —
    /// 8 s is headroom for "a card that was just woken up", not the typical duration.
    private static let listWindow: TimeInterval = 8

    /// Per-frame wait limit. A card that stalls mid-list = this round is already dead; retrying early beats waiting it out.
    private static let listFrameTimeout: TimeInterval = 2

    /// Maximum number of list rounds (including the first). **2 = the original round + one self-healing round**, see `listRecordings` for the rationale.
    private static let listMaxAttempts = 2

    // MARK: RecorderLink — read one recording

    /// Fetches one recording in slices and returns the **raw Opus packet stream** (not wrapped in Ogg; hand it to `containerize`).
    ///
    /// The loop in this method is exactly the R→D×20→E rhythm seen on the real device: write one `0x1C`, receive 20 data frames
    /// and 1 sentinel; as soon as the sentinel arrives, write the next `0x1C`, until `TicNoteSession` says everything is collected.
    ///
    /// ⚠️ **The timeout scales with size, it is not a fixed value**: on the real device 563,520 bytes took 71.9 s (≈8.8 KB/s average wall-clock),
    /// but the largest recording on the card is 23.6 MB (a 49-minute recording), which at the same rate needs **45 minutes**.
    /// A fixed timeout either kills large files by mistake, or is set so loosely for large files that it means nothing.
    /// Here we use a conservative 3 KB/s estimate (one third of the real device's 8.8 KB/s) plus 30 s of headroom.
    /// — The real answer for large files is Wi-Fi fast transfer (see §0quinquies), not a bigger BLE timeout.
    func fetchRecording(_ recording: RecorderRecording,
                        progress: (@MainActor (Double) -> Void)?) async throws -> Data {
        guard let sid = recording.sessionID else {
            throw RecorderLinkError.unsupported("recording has no sessionID")
        }
        guard recording.sizeBytes > 0 else {
            throw RecorderLinkError.malformed("recording size is 0")
        }
        let size = UInt32(recording.sizeBytes)
        let budget = 30 + Double(size) / 3000

        return try await runExclusive {
            guard self.isConnected else {
                TicNoteDiagLog.log("FETCH", "✗ Called before the card was connected (isConnected=false)")
                throw RecorderLinkError.notConnected
            }
            self.inbox.drain()

            // ★★ From this line until the end of this download (**including every throwing path**) we count as "pulling shards":
            //    any `0x02` frame arriving in this period is **bytes of an older file**, not "the card is writing to disk".
            //    Without suppression, every finished download would falsely light up "recording + stopwatch" once
            //    — see the real-device forensics in `isPullingShards`.
            self.beginShardPull()
            defer { self.endShardPull() }

            // Use a fresh state machine for every download: `session` carries the previous run's shards and statistics,
            // and reusing it would mix the old recording's chunks in (`assemble` would count them as a "conflict" and refuse to deliver).
            self.session = TicNoteSession()
            self.transferProgress = 0
            guard let first = self.session.beginDownload(sessionID: sid, sizeBytes: size) else {
                TicNoteDiagLog.log("FETCH", "✗ Cannot plan shards: size=\(size)B")
                throw RecorderLinkError.malformed("cannot plan download for \(size) B")
            }
            // At the start, log one line with "how many slices this recording should take" — the final line (`✅ Assembly complete` / `✗ Timeout abort`)
            // can only tell "the whole file was pulled" from "it stopped halfway" when paired with this denominator.
            // Denominator = ⌈size ÷ 1600⌉, exactly the same split as `TicNoteSyncRequest.plan`.
            let plannedSlices = (Int(size) + TicNoteGATT.syncChunkBytes - 1) / TicNoteGATT.syncChunkBytes
            TicNoteDiagLog.log("FETCH",
                "Download started sid=\(sid) target=\(size)B planned=\(plannedSlices) slices")

            // ★★ Send `0x1C` after first performing `0x1D → 0x1E` (official app does this before each segment pull).
            //
            // Based on (`captures/bug2-20261008.att.txt` full packet frame-by-frame stats, each of two download sessions once):
            //
            // ```
            //   5774.351 ← 0x14 <sid> 02 00 00 00 00 00   Card announces "record exists" (11 B)
            //   5774.368 → 0x1D                           ATT **Write Request**
            //   5774.396 ← 0x13 (Write Response)          Card receives at ATT layer
            //   5774.492 ← 0x1E                           ACK (124 ms later)
            //   5774.713 → 0x1C first slice                     status 00, data streams in
            // ```
            //
            // ★★★ 2026-10-10 Completed **full count** (this version has the complete shape):
            //
            // | Frame | Direction | Count | Description |
            // |---|---|---|---|
            // | `0x1D` | App→Card | **2** | Sent **once per download session**, this is the pre-frame |
            // | `0x1E` | Card→App | **2** | 1:1 with the above |
            // | `0x1C` | App→Card | **355** | One per slice in the loop |
            // | `01 1c 00 <sid> <status>` | Card→App | **355** | 1:1 with above, no missing replies |
            // | `01 1d 00 <sid> ff ff` | Card→App | **354** | 9 B, card sends a status report **per slice** |
            //
            // All three conclusions changed the approach:
            // · `0x1D` is a **session-level** pre-frame, not per slice — sending it repeatedly in the loop is pointless;
            // · Card **must** acknowledge `0x1C` (355/355), so "sent with no response" means the pre-frame failed,
            //   cannot be a "frame byte error" (byte error would cause card to return status `0x02` reject, see NAK below);
            // · The card's 354 `0x1D` frames **do not require a response** (official never replies, `0x1E` always twice).
            //
            // Previously our app **directly** sent 0x1C → card **remained completely silent**
            // (app-diag-2026-10-10-1502.log 15:01:42 / 15:02:40, two runs, 0 frames in 60 s).
            //
            // ⚠️ The meaning of 0x1D here is **not** "stop sync": it toggles the card into a state that will **respond with 0x1C**
            //    switch (named after the static reverse-engineered table `syncFileStop`, behavior matches real device).
            //    If 0x1E is not received, **do not abort** the download — better to retry than let a single
            //    undefined pre-frame block the sole download path.
            // ⚠️ In the capture the official `0x1D` is a **Write Request**, but **our card only accepts**
            //    Write Command** (verified on real device, see mapping table in `stopSynchronization()`).
            //    Do not change the write type just because the capture shows it.
            // ★★★ 2026-10-10 Real-device log conclusion: this `0x1D` **must be preceded by a full handshake**
            //      (identity query `01 01 00 02 01 00` → binding frame), otherwise the card never replies with `0x1E`,
            //      The subsequent `0x1C` just disappears.
            //
            // Based on (`/tmp/ticnote-ble.log`, 15 outbound `0x1D` occurrences in one install verification):
            //
            // ```
            //   `0x1D` sent right after the greeting → 10 / 10 all received ← `0x1E`
            //     └ All 10 of these come from startRecording
            //       `provisionSession(force: true)` → `stopSynchronization()`
            //   `0x1D` not immediately after greeting → 0 / 5 never received
            //     └ All 5 of these are this line in the current method
            // ```
            //
            // Moreover, **13 outbound `0x1C` got no response** — not a byte error in `0x1C`,
            // It's because the preceding `0x1D` wasn't accepted by the device, which never entered a state that would reply `0x1C`.
            //
            // ⚠️ Why `force: true` instead of `false`: `false` would skip when "already sent in this connection"
            //    and the greeting would **expire** (in failure samples the last greeting is separated from `0x1D` by
            //    2.3 s / 11.8 s / 281 s). Download is low-frequency, a 0.4 s retransmission cost is negligible.
            // ⚠️ Order must not be reversed: the device's criterion is "**identity query first, bind frame later**".
            //    In failure samples it was reversed (bind frame first, identity query 2.3 s later), also no `0x1E` response.
            //    Retransmitting once corrects it.
            await self.provisionSession(force: true)

            self.inbox.drain()
            try self.write(TicNoteFrameCodec.frame(rawCmd: TicNoteCommand.syncFileStop.wireValue))
            let syncAckDeadline = Date().addingTimeInterval(2)
            var sawSyncAck = false
            while Date() < syncAckDeadline {
                guard let frame = try? await self.nextFrame(timeout: 0.5),
                      let decoded = TicNoteFrameCodec().decode(frame),
                      decoded.type == TicNotePacketType.commandResponse.rawValue,
                      decoded.cmd == 0x001E
                else { continue }
                sawSyncAck = true
                TicNoteDiagLog.log("FETCH", "0x1D confirmed by device (0x1E), start fetching fragments")
                break
            }
            // ⚠️ Not receiving it does **not abort** (see above), but must **remain**.
            //    "Send 0x1C without waiting for ACK" is the only empirically observed precursor on the failure path
            //    (In 15 real-device `0x1D` attempts, the 5 that weren't received were all silent afterwards).
            //    If silence continues here, the log shows "timeout" indistinguishable from "device unresponsive", requiring re-location.
            if !sawSyncAck {
                TicNoteDiagLog.log("FETCH",
                    "⚠️ No `0x1E` within 2 s (`0x1D` not confirmed) — still continue sending `0x1C`,"
                    + "if the device then goes silent, the root cause lies here")
            }

            try self.write(first)

            let deadline = Date().addingTimeInterval(budget)
            while !self.session.phase.isTerminal {
                if Task.isCancelled { throw RecorderLinkError.cancelled }
                if Date() > deadline {
                    // ★ The outcome must be logged to **file** (see the long comment in the `assembly` section below).
                    TicNoteDiagLog.log("FETCH",
                        "✗ Timeout abort: fragments=\(self.session.sentSyncCount) "
                        + "progress=\(self.session.progress) budget=\(Int(budget))s")
                    throw RecorderLinkError.timeout
                }
                // Wait 5 s per frame: normally frames arrive continuously (20 frames/fragment); no activity for 5 s means stopped.
                let frame = try await self.nextFrame(timeout: 5)
                let outbound = self.session.ingest(frame)
                for f in outbound { try self.write(f) }
                self.transferProgress = self.session.progress
                progress?(self.session.progress)
            }
            if case .failed(let reason) = self.session.phase {
                TicNoteDiagLog.log("FETCH", "✗ State machine judged failure: \(reason)")
                throw RecorderLinkError.malformed(reason)
            }

            let assembled = self.session.assembled()
            // ★★★ The outcome must be written to **file** log, not just `log.info`.
            //
            // Why this change is mandatory (real-device lesson 2026-10-10): `log.info` goes to os_log, while this device
            // `log stream --device-udid` is blocked by sandbox, and `idevicesyslog` cannot capture this App's
            // subsystem — therefore **"download succeeded" leaves no trace in the logs**.
            // The 16:06 on-device download: `0x1C` requested 32 chunks, received 32 chunks, `end` exactly equals the file
            // total byte count, all correct; but **whether it actually landed in the library**, no trace found in logs afterwards,
            // could only be inferred indirectly from "no further round followed". This "all evidence correct but conclusion unknown" situation must not happen again.
            //
            // This line goes through `TicNoteDiagLog` → `Documents/ticnote-ble.log`, retrievable in one device pull.
            // The `bytes` denominator is the **file size reported in the listing**; a mismatch means the byte count from the card itself is wrong.
            if assembled.gaps != 0 || assembled.conflicts != 0 || assembled.malformed != 0 {
                TicNoteDiagLog.log("FETCH",
                    "✗ assembly failed validation: gaps=\(assembled.gaps) conflicts=\(assembled.conflicts) "
                    + "malformed=\(assembled.malformed) chunks=\(self.session.sentSyncCount) "
                    + "bytes=\(assembled.data.count)/\(size)")
            } else {
                TicNoteDiagLog.log("FETCH",
                    "✅ assembly complete bytes=\(assembled.data.count)/\(size) "
                    + "chunks=\(self.session.sentSyncCount)")
            }
            guard assembled.gaps == 0, assembled.conflicts == 0, assembled.malformed == 0 else {
                // fail-closed: gaps/conflicts/malformed are always refused delivery, never writing an unopenable file.
                throw RecorderLinkError.corrupted(
                    "gaps=\(assembled.gaps) conflicts=\(assembled.conflicts) "
                    + "malformed=\(assembled.malformed) sent=\(self.session.sentSyncCount)"
                )
            }
            self.transferProgress = 1
            progress?(1)
            log.info("fetched \(assembled.data.count, privacy: .public) B in \(self.session.sentSyncCount, privacy: .public) slices")
            return assembled.data
        }
    }

    // MARK: RecorderLink —— packaging

    /// Raw Opus packet stream → Ogg Opus. **This step is mandatory**, not an optional optimization:
    /// `AVAudioFile` / `AVPlayer` cannot open a raw Opus stream without a container.
    func containerize(_ raw: Data, for recording: RecorderRecording) throws -> RecorderClip {
        guard TicNoteOpusStream.looksLikeOpus(raw) else {
            throw RecorderLinkError.malformed(
                "not a plaintext Opus stream (\(raw.count) B) — TOC is not constant 0xBC"
            )
        }
        guard let ogg = TicNoteOpusStream.oggOpus(from: raw) else {
            throw RecorderLinkError.malformed("Ogg muxing failed")
        }
        let duration = TicNoteOpusStream.estimatedDuration(raw)
        return RecorderClip(
            data: ogg,
            // ★ Use the `.opus` suffix (rationale in `TicNoteWifiSession.deliverable`):
            //   the container is already standard Ogg Opus, and `.opus` is the suffix verified end-to-end on D·NOTE;
            //   the library whitelist / duration probe / playback / transcription all recognize it. Using `.ogg` would
            //   make the file disappear from the library.
            fileExtension: "opus",
            duration: duration,
            formatNote: String(
                format: "Opus %d Hz %@ %d kbps · %.1f s",
                TicNoteGATT.opusSampleRate,
                TicNoteGATT.opusChannels == 2 ? "stereo" : "mono",
                TicNoteGATT.opusBitrate / 1000,
                duration
            )
        )
    }

    // MARK: RecorderLink —— time sync

    /// Time sync: `01 04 00 <u32 timestamp LE> <u8 timezone hours>`.
    ///
    /// The purpose is not "making the displayed time look nice": in the `0x1A` listing, `startTime` **is the sessionId**,
    /// if the card RTC drifts by half a year, the App-side time will not match the actual recording time.
    ///
    /// Does not wait for a response (the card replies with the same code + two bytes; this card has no request ID, and waiting could instead swallow
    /// a response meant for elsewhere). Failure is handled by the caller as best-effort.
    func syncTime(to date: Date) async throws {
        try await runExclusive {
            guard isConnected else { throw RecorderLinkError.notConnected }
            try write(TicNoteFrameCodec.syncTime(date))
        }
    }

    // MARK: RecorderLink —— delete

    /// Delete one recording: `01 1E 00 <sessionId u32> <u8>` (wire code `0x1E` = static table `0x3C >> 1`).
    ///
    /// ⚠️ **Never executed on a real device** (in captures 0x1E only appeared as a card notification, direction card→App).
    /// so here we send without waiting for a reply, and **failures must be swallowed by the caller** (failure to delete is just that — not deleted,
    /// the UI should not error out, and it certainly should not affect already-downloaded files).
    func deleteRecording(_ recording: RecorderRecording) async throws {
        guard let sid = recording.sessionID else {
            throw RecorderLinkError.unsupported("recording has no sessionID")
        }
        try await runExclusive {
            guard isConnected else { throw RecorderLinkError.notConnected }
            try write(TicNoteFrameCodec.deleteRecord(sessionId: sid))
        }
    }

    // MARK: RecorderLink — Recording control (linked recording, ★ not yet on device)

    /// Let **the card itself** start recording — equivalent to pressing the record button on the card.
    ///
    /// ## ★ Sequence copied from the official `beginRec`, not custom-ordered
    /// Disassembled `BluetoothManager::beginRec` (in `blutter_out/asm/…/ble.dart`).
    /// There are only three Dart calls, **order equals execution order**:
    ///
    /// ```
    /// 1. BluetoothManager::stopBleSync     ← ★ first stop sync / file-read session
    /// 2. BluetoothManager::generalSetting  ← **reload** general settings, extract rec_scene
    /// 3. WriteCmd::recordStart(rec_scene)  ← this is the actual start-record frame
    /// ```
    ///
    /// Step 1 is **added in this round**, filling a missing link: on a real device, "tap record no response,
    /// but the card flashes briefly — likely because it was in an **unfinished session**
    /// (the list / file-read path leaves a session), so firmware rejects the start-record.
    /// The official puts "stop sync" as the **first step** of start-record, indicating mutual exclusion on the card.
    ///
    /// ## Online frame (★ 2026-10-10 corrected one byte after byte-wise review)
    /// `01 14 00 | 01 <scene> 00 00 00 00`
    ///
    /// The previous version used `01 14 00 **02** <scene> …`, error in `payload[0]`:
    /// In the disassembly this element is a **marker byte** `0x02`; after removing the marker it becomes `0x01`
    /// (the same line's `0x28` correctly `>>1` to `0x14`, only this spot was missed).
    /// Derivation and calibration are in `TicNoteFrameCodec.recordStartFrame`.
    ///
    // MARK: Session pre-handshake (★ 2026-10-10 root cause of "operation failed" on real device)

    /// Make the card treat this connection as a valid session: first send identity query (`0x01`), then send bind frame.
    ///
    /// ## Why it is required — this is the root cause of "tap record → operation failed"
    /// The connection layer's `completeHandshake()` **only performs GATT discovery and enables notify,
    /// does not send any application-layer command**. Real-device tests (`tools/bleprobe rec`) show:
    /// **The card ignores all proprietary commands until it receives this frame set.**
    ///
    /// | Experiment | Result |
    /// |---|---|
    /// | `rec … noinit`: send `01 1d 00` → `01 08 00 01` → `01 14 00 …` | entire connection **0 inbound frames** (not even a `0x08` config response) |
    /// | `rec …` (default, includes identity query + bind frame) | Card **responds stepwise**, start-record succeeds and reports byte count |
    ///
    /// Hence the failure chain: start-record frame sent → card sees nothing → start-record self-check never receives `0x18`
    /// → after 5 s throws `.timeout` → UI shows "operation failed".
    /// **All frame bytes are correct; missing the "opening handshake".**
    ///
    /// ## Why retransmission is safe (idempotent)
    /// * The identity query `01 01 00 02 01 00` is a **read-only** frame;
    /// * The binding frame's payload is **derived entirely from the SN** (SSID = `TicNote-` + last 4 digits of the SN,
    ///   see `TicNoteWifiCredentials.hotspotSSID(fromSN:)`), so sending it the Nth time
    ///   writes exactly the same bytes as the 1st time.
    ///
    /// ⚠️ When the SN can't be read, **send only the identity query** — never write the card with a name that can't be computed.
    /// Leave 0.2 s between the two frames: the card must register the previous frame before it accepts the next one (the same
    /// 0.2 s used by `sendOpenWifi` / `readDeviceInfo`).
    ///
    /// - Parameter force: `true` = resend unconditionally (used before starting a recording, since the card's session may have expired);
    ///   `false` = skip if already sent in this connection (used by the 1 Hz poll, to avoid writing the card twice per second).
    private func provisionSession(force: Bool) async {
        if !force, didProvisionSession { return }
        TicNoteDiagLog.log("PROV", "Prologue start force=\(force) sn=\(serialNumber ?? "nil")")
        do {
            try write(TicNoteFrameCodec.frame(
                rawCmd: TicNoteObservedCommand.setDeviceIdentity.rawValue,
                payload: Data([0x02, 0x01, 0x00])
            ))
            try? await Task.sleep(nanoseconds: 200_000_000)

            if let sn = serialNumber,
               let ssid = TicNoteWifiCredentials.hotspotSSID(fromSN: sn),
               let bind = TicNoteWifiProvisioning.sendTokenFrame(ssid: ssid) {
                try write(bind)
                try? await Task.sleep(nanoseconds: 200_000_000)
                didProvisionSession = true
                log.info("provision: identity + bind sent (ssid=\(ssid, privacy: .public))")
                TicNoteDiagLog.log("PROV", "Done: identity query + binding frame (ssid=\(ssid))")
            } else {
                // Only the identity query was sent. That's usually enough for "whether the card answers at all", just missing the hotspot-name binding frame.
                log.warning("provision: SN unreadable, skipping binding frame (identity query only)")
                // ⚠️ This entry is logged as **danger** — it's one possible leftover branch of "tapped record but the operation failed".
                //    The card's precondition for that decision is "write type + prologue", and the prologue includes the binding frame.
                TicNoteDiagLog.log("PROV", "⚠️ Skipping binding frame: SN unreadable (identity query only)")
            }
        } catch {
            log.warning("provision failed: \(String(describing: error), privacy: .public)")
            TicNoteDiagLog.log("PROV", "Failed: \(String(describing: error))")
        }
    }

    // MARK: Start recording / stop recording

    /// ## ★ This step **verifies itself on the spot** — no more guessing via the UI
    /// The previous version's comment read "still never verified successfully on a real device, so the caller must display the result".
    /// That's no longer needed — the card will definitely speak up after accepting this command; either of two independent signals suffices,
    /// see "step 4" below. If neither arrives, `.timeout` is thrown and the UI accordingly says "the card did not start recording",
    /// so the false success of "App counting time while the card isn't actually recording" **will not** happen again.
    func startRecording() async throws {
        try await runExclusive {
            guard isConnected else { throw RecorderLinkError.notConnected }
            // Zero out the "did the card accept it" criteria: without clearing, an entry left over from before the last poll would
            // report "the card ignored us" as "the card confirmed".
            pendingSessionNotice = false
            // A new start-recording invalidates the fact that "we sent a stop command" — otherwise `pushedRecordingState`
            // would keep reporting false (see `stopRequestedAt`).
            stopRequestedAt = nil

            // ★★ Step 0 (**without it everything after is wasted**): make the card accept this connection.
            //    The connection-layer handshake only does GATT discovery and sends no application-layer frames; and real-device comparison proved
            //    the card ignores all private commands until it has received the "identity query + binding frame"
            //    → symptom is exactly "tap Record → operation failed". See `provisionSession(force:)`.
            //    Resend unconditionally with `force: true`: the card's session may have long expired.
            await provisionSession(force: true)

            // ★ Step 1: close any in-flight sync/file-read session (the official beginRec's first step).
            // failure does **not block** the recording start — if the card had no session to begin with, the "close" action has nothing to do anyway,
            // and raising an error would only block the one useful step. On failure, just log.
            await stopSynchronization()

            // ★ Step 2: read 0x08 general settings to get `rec_scene` (the official beginRec's 2nd call).
            //
            // ⚠️ Key difference from the previous version: **a failed read no longer aborts the recording start**.
            //   The previous version did `throw .timeout` right away when no response arrived — the result was "if the card was a bit slower,
            //   not a single record-start frame could be sent", yet whether the card answers 0x08 has no causal link to whether it can accept a record-start frame
            //   (the official app just "reads it in passing"; our fallback scene value
            //   is confirmed as 2 both in real-device logs and in the 0x08 response). So downgrade to "recording the source".
            inbox.drain()
            try write(TicNoteFrameCodec.frame(
                rawCmd: TicNoteObservedCommand.getConfig.rawValue,
                payload: Data([0x01])
            ))
            let deadline = Date().addingTimeInterval(2)
            var setting: TicNoteGeneralSetting?
            while Date() < deadline {
                guard let reply = try? await nextFrame(timeout: 0.5),
                      let decoded = TicNoteFrameCodec().decode(reply)
                else { continue }
                guard decoded.type == TicNotePacketType.commandResponse.rawValue,
                      decoded.cmd == TicNoteObservedCommand.getConfig.rawValue
                else { continue }
                setting = TicNoteGeneralSetting.parse(decoded.payload)
                break
            }

            let scene: UInt8
            let sceneSource: String
            if let setting {
                scene = setting.recScene
                lastGeneralSetting = setting
                sceneSource = "card 0x08"
            } else if let cached = lastGeneralSetting {
                scene = cached.recScene
                sceneSource = "cached 0x08"
            } else {
                scene = TicNoteRecordingScene.defaultScene
                sceneSource = "default"
            }
            try? await Task.sleep(nanoseconds: 200_000_000)

            // ★ Step 3: send the byte-by-byte verified record-start frame.
            try write(TicNoteFrameCodec.recordStartFrame(scene: scene))
            TicNoteDiagLog.log("START", "record-start frame sent scene=\(scene) source=\(sceneSource)")

            // ★ Step 4: **verify on the spot**. If the card accepted the command it will speak; any one of three independent signals suffices:
            //   · **`0x18` record state report** (★ verified on a real device this is the one — after accepting the record start the card replies with
            //     it, not `0x14`; delay is about 1.6 s, see `notifyRecordState`);
            //   · `0x14` session-start event (pushed when the card starts recording from its own physical key, or by some firmware versions);
            //   · the first `0x02` voice frame (only arrives when we actively pull via `0x1C`).
            // If none of the three arrives → throw `.timeout`, so the UI clearly says "the card did not start recording".
            // ⚠️ Conversely: **as long as the card replied with `0x18`, we must never report failure** — that's the hardest-to-debug kind of false negative where "the feature works but
            //    the UI says it's broken".
            let noticesBefore = sessionNoticeSequence
            let verifyUntil = Date().addingTimeInterval(Self.startVerificationWindow)
            while Date() < verifyUntil {
                if streamingVoice || sessionNoticeSequence != noticesBefore {
                    log.info("recordStart accepted scene=\(scene, privacy: .public) from \(sceneSource, privacy: .public)")
                    TicNoteDiagLog.log("START", "✅ card accepted (voice stream=\(streamingVoice) session frame seq \(noticesBefore)→\(sessionNoticeSequence))")
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            log.warning("recordStart scene=\(scene, privacy: .public) from \(sceneSource, privacy: .public): card stayed silent")
            // ⚠️ This is the "operation failed" the user sees. Also log **how many frames actually arrived within the wait window**:
            //    0 frames = the card never answered at all (write type / opening exchange problem);
            //    >0 but no session frame = the card is answering something else (the card is alive; the problem is in the record-start frame semantics).
            //    The two require completely different fixes, so the log must distinguish them.
            TicNoteDiagLog.log("START", "❌ card silent for the entire \(Self.startVerificationWindow) s, throwing timeout"
                + " (inbound control frames within wait window #\(inboundFrameCount), session frame seq still \(sessionNoticeSequence))")
            throw RecorderLinkError.timeout
        }
    }

    /// Window after starting the recording to wait for the "card to speak".
    ///
    /// Real-device measurement: about **1.6 s** after accepting the record-start command the card replies with the first `0x18` (`tools/bleprobe rec`,
    /// 2026-10-10: send frame 14:30:22.824 → receive `0x18` 14:30:24.432). Giving 5 s because
    /// The card's response latency varies with link quality, and here **prefer waiting a bit longer rather than falsely reporting failure** —
    /// The cost of a false alarm is the user seeing "card hasn't started recording", while the card is actually recording.
    private static let startVerificationWindow: TimeInterval = 5

    /// Close any ongoing sync/read-file session on the card: **`0x1D`, using a write with response**.
    ///
    /// Basis (two independent locations):
    /// · The official `beginRec` first call is `stopBleSync`;
    /// · In the real device App log, "stop sync …" is immediately followed by `writeCharacteristicWithResponse`,
    ///   while the packet capture at the same moment shows `WriteReq handle=0x000d 01 1d 00` (`0x1D`).
    ///
    /// ⚠️ After sending, wait one interval before proceeding (same 0.2 s reason as the supplemental bind frame for `readDeviceInfo`):
    /// the card must finish processing this frame before the next command makes sense). **Do not consume `inbox`** —
    /// Any response from the card to `0x1D` will be left in the stream by `observeControlFrame` for the user to see.
    /// ★★ **Write type correction (real-device test 2026-10-10)**: this frame originally used `response: true`
    /// (ATT Write **Request**), based on "only `0x1D` appears as a write with response in the official capture".
    /// In the 19th round, using `tools/bleprobe rec` on a real device, both write types were tested, and the conclusion was reversed:
    ///
    /// | Write type | Card response |
    /// |---|---|
    /// | Write Request (`0x12`) | **Silent throughout**; sending identity query `01 01 00 02 01 00` leads to **immediate disconnection** |
    /// | Write Command (`0x52`) | **Per-packet response**: `01 1d 00` → **`01 1e 00`** |
    ///
    /// Hence the card's proprietary protocol **recognizes only Write Command**. This also explains why "sending a command makes the card seem unheard"
    /// This hardest-to-diagnose symptom appears — frame bytes are correct, but the ATT layer used the wrong write type.
    /// Revert to the default `.withoutResponse` (the default for `write`), and keep this evidence.
    private func stopSynchronization() async {
        do {
            let withResponse = try write(
                TicNoteFrameCodec.frame(rawCmd: TicNoteCommand.syncFileStop.wireValue)
            )
            log.info("stop-sync (0x1D) written, withResponse=\(withResponse, privacy: .public)")
            try? await Task.sleep(nanoseconds: 200_000_000)
        } catch {
            log.warning("stop-sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Instruct the card to stop recording.
    ///
    /// ⚠️ The previous version claimed the online frame was "confirmed by real-device ATT capture" — **inaccurate**. In the capture
    /// **there is no `0x17` from App→card** (checked across 10 full captures: outbound only contains
    /// `01 03 04 06 08 09 0C 1A 1C 1D`), because the official App's start/stop recording actions were never captured.
    /// The real basis is disassembly + full-table calibration: the list for `WriteCmd::recordEnd` is
    /// `[0x02, 0x2E, 0x00]` (Smi marker) → `>>1` → **`01 17 00`**;
    /// All 10 known commands in the same table, after `>>1`, match the capture byte-by-byte (see `TicNoteCommand` comment).
    ///
    /// After sending, record a `stopRequestedAt`: the card **does not guarantee** a `0x17` response, relying only on the earlier
    /// `0x14` which keeps the status showing "recording" (red dot stays on, timer continues).
    func stopRecording() async throws {
        let frame = TicNoteFrameCodec.recordStopFrame
        try await runExclusive {
            guard isConnected else { throw RecorderLinkError.notConnected }
            stopRequestedAt = Date()
            try write(frame)
            TicNoteDiagLog.log("STOP", "Sent stop recording frame 01 17 00")
        }
    }

    // MARK: RecorderLink —— Device Info (read-only)

    /// Read the card's read-only status once: identity / status / configuration / **battery** / **storage usage**.
    ///
    /// ## ★ 2026-10-12 (second round): `0x06` (storage) added to the read batch
    /// On a real device `/tmp/t5.log` has already seen `[0x03, 0x06, 0x09, 0x1A]` four-packet burst and
    /// **All packets get responses**, so attaching a read-only `0x06` to the end of the read batch is safe.
    /// The reason for attaching it to the **tail** rather than inserting in the middle is explained in `TicNoteDeviceInfoQuery.readSteps`
    /// (In short: the first three packets are byte-for-byte identical to the verified online sequence).
    ///
    /// ## ★★★ 2026-10-12 Rewrite: **split into two bursts**, no longer "send everything at once"
    ///
    /// The previous version claimed "the official firmware sends several read commands in one go, so we copy that here".
    /// That "copy" also packed the **identity query** into the same instantaneous burst, which on a real device is exactly
    /// **the direct cause of unreadable battery** (user's original words: *"battery info is only recorded after recording finishes"*).
    ///
    /// ### Evidence (`/tmp/t5.log`, outbound split into bursts by "interval > 12 ms", then examine inbound within 2.5 s)
    /// ```
    /// Send [0x01 (identity), 0x03, 0x08, 0x09]  → Receive [0x02]                    ✗ 6/6 times all empty
    /// Send [0x03, 0x06, 0x09, 0x1A]        → Receive [0x03, 0x06, 0x09, …]      ✓
    /// Send [0x08]                          → Receive [0x08]                    ✓
    /// Send [0x09]                          → Receive [0x09]                    ✓
    /// ```
    /// All six failures look like this: `20:35:09.056`/`20:35:14.145` (two trips on the same connection),
    /// `09:40:09.475`… outbound four packets squeezed into 1 ms, inbound only one packet `01 02 00 …`.
    /// Whereas the four packets from `readRecordingStatus` (excluding `0x01`) **always receive full responses** —
    /// Thus the difference is that identity query: `0x01` causes the card to drop subsequent frames in the same burst.
    ///
    /// ### Failure chain (what the user observes)
    /// Three read commands all empty → `replies["battery"] == nil` → fall back to the "cache pushed by the card itself" section
    /// → and that `lastBatteryPercent` **is only written during recording by a 1 Hz poll**
    /// → thus "**you must record once before the battery level becomes visible**".
    /// After batching, the battery can be read directly at any time (real device sample: `01 09 00 00 56` = 86%).
    ///
    /// ### Current timing
    /// ```
    /// ① Opening: identity query 0x01 → pause 0.2 s → bind frame        (each occupies a separate write, never combined with reads in the same burst)
    /// ② Pause 0.12 s
    /// ③ Read-only commands 0x03 / 0x08 00 01 / 0x09 / 0x06, **single burst**
    /// ```
    /// `provisionSession(force: false)` handles ① — skips if already sent in the same connection,
    /// Therefore, "open card info" path normally only sends ②③, saving more than before (previously a binding frame was added each time).
    ///
    /// ## Why the binding frame step is still kept
    /// Real-device comparison from `protocol-notes.md` §17.1: after init **without a binding frame**, the card only returns a single identity frame
    /// It stays silent. This is a prerequisite for "card may not respond". Moreover, this frame is **idempotent**
    /// (payload is fully derived from SN, see `TicNoteWifiProvisioning`), repeated transmissions are byte-identical.
    ///
    /// ## Concurrency and failure semantics
    /// * `runExclusive` + `inbox.drain()`: during reading we are the **sole** consumer,
    ///   so we won't consume frames needed for list/download (see the background in `RecorderDeviceView`
    ///   `isRecording` comment).
    /// * Card replies partially → return that part (**not** a total failure due to a missing frame).
    /// * Card gives no reply → throw `.timeout`. **Distinguishing these two cases is important**:
    ///   "Read 0 items" vs. "card silent" convey completely different information to the user.
    /// * Frames actively pushed by the card (`0x17` / `0x14` / `0x18` / `0x1D` …) are always skipped, not treated as responses.
    ///   ⚠️ `0x06` **used to be** mentioned here — that was before it entered the read batch.
    ///   Now it is **actively queried by us**, so it appears in `expected`, and the whitelist below will allow it
    ///   (When changing the read batch, **won't** encounter the half-baked state of "request sent but treated as noise and dropped":),
    ///   the whitelist is taken directly from `readSteps`).
    func readDeviceInfo() async throws -> RecorderDeviceInfo {
        try await runExclusive {
            guard isConnected else { throw RecorderLinkError.notConnected }
            inbox.drain()

            // ① Opening handshake (identity query + bind frame, each sent independently, 0.2 s interval).
            //    ⚠️ **Cannot** merge it with the read commands below — that was the bug fixed this time.
            await provisionSession(force: false)
            inbox.drain()

            // ② Give the card a tap to finish the opening handshake. Sending it too tightly squeezes the two segments together.
            try await Task.sleep(nanoseconds: 120_000_000)

            // ③ Three read-only commands, one spontaneous. **`0x01` must never appear here.**
            for step in TicNoteDeviceInfoQuery.readSteps {
                try write(TicNoteFrameCodec.frame(rawCmd: step.cmd, payload: step.payload))
            }

            var replies: [UInt16: Data] = [:]
            var notes: [String] = []
            let expected = Set(TicNoteDeviceInfoQuery.readSteps.map(\.reply))
            let deadline = Date().addingTimeInterval(Self.deviceInfoWindow)

            while !expected.subtracting(replies.keys).isEmpty {
                if Date() > deadline { break }
                // ⚠️ `nextFrame` throws timeout = **normal exit** (the card stops speaking after answering), must `break`
                //    instead of `continue` — the latter would spin until the overall window is exhausted when the card is silent.
                guard let frame = try? await nextFrame(timeout: Self.deviceInfoFrameTimeout) else {
                    break
                }
                guard let decoded = TicNoteFrameCodec().decode(frame),
                      decoded.type == TicNotePacketType.commandResponse.rawValue,
                      expected.contains(decoded.cmd),
                      replies[decoded.cmd] == nil
                else { continue }   // Skip any proactive pushes of 0x17/0x14/0x18/0x1D from the card (0x06 is already in the read batch).

                replies[decoded.cmd] = decoded.payload
                if let step = TicNoteDeviceInfoQuery.readSteps.first(where: { $0.reply == decoded.cmd }),
                   let note = TicNoteDeviceInfoQuery.note(forLabel: step.label,
                                                          payload: decoded.payload) {
                    notes.append(note)
                }
            }

            guard !replies.isEmpty else { throw RecorderLinkError.timeout }

            let batteryPayload = TicNoteDeviceInfoQuery.readSteps
                .first { $0.label == "battery" }
                .flatMap { replies[$0.reply] }
            // ★ Parse **two items** at once: battery level and charging flag. They appear together in a `0x09` frame,
            //   splitting into two parses can cause mismatches between “charging / not charging” and the battery level.
            var batteryReading = batteryPayload.flatMap {
                TicNoteDeviceInfoQuery.batteryReading(fromReplyPayload: $0)
            }
            if batteryPayload != nil, batteryReading == nil {
                // If a response is received but battery level cannot be decoded — log it, don't silently show “—” and make it look like nothing was read.
                notes.append("A battery reply arrived but its value is out of range "
                             + "(expected 0…100).")
            }
            // ★ This time not queried, but a copy exists in the cache → use that cache (fallback, not the primary path).
            //
            // ⛔ The previous version claimed “the real device pushes a `0x09` as soon as the card connects” — **incorrect**.
            //    `/tmp/t5.log` full statistics: `0x09` response **first appears at the start-recording moment**
            //    (`20:35:31.937`), after that 21 entries all fall within the recording window or immediately adjacent
            //    `20:41–20:43` segment (those intervals are from 1 Hz polling/keep-alive queries).
            //    Thus this cache **is only written during recording** —
            //    which is the other half of the reason why “battery shows after recording finishes”.
            //    After batch sending, the primary path (the three read commands above) can obtain the battery itself,
            //    leaving this branch only as a fallback for “card did not answer this time”.
            //
            // ★ 2026-10-13: fallback **entire line** moved over (including charging flag), no longer only moving the percentage —
            //   otherwise a contradictory line appears: “battery from cache, charging status shown as not read”.
            if batteryReading == nil, let cached = lastBatteryReading {
                batteryReading = cached
                notes.append("Battery came from an earlier reading (this read came back empty).")
            }
            let battery = batteryReading?.percent

            // ★ Also extract **general settings** (`0x08`) — the start-recording frame needs the `rec_scene` inside.
            //   If it cannot be decoded, keep the old value (when firmware or frame length changes, prefer lag over writing a wrong scene
            //   into the start-recording frame — that would turn “tap record, no response” into “tap and record a different scene”).
            if let configPayload = replies[TicNoteObservedCommand.getConfig.rawValue],
               let setting = TicNoteGeneralSetting.parse(configPayload) {
                lastGeneralSetting = setting
            }

            // ★ Storage usage (`0x06`, 13 bytes). If it cannot be decoded, set to `nil` — **not 0**:
            //   The UI then shows “—” instead of a fake progress bar saying “used 0 %”.
            var storage: RecorderStorageInfo?
            if let storagePayload = replies[TicNoteObservedCommand.queryStorage.rawValue] {
                if let parsed = TicNoteStorageInfo.parse(storagePayload) {
                    storage = parsed.recorderStorage
                    lastStorage = parsed
                }
            }

            // ⚠️ This must be a **single** interpolated string, not concatenated with `+` — `OSLogMessage` is not a String,
            //    concatenation would cause a compile error (`referencing operator function '+' on 'FloatingPoint'`).
            log.info("device info: \(replies.count, privacy: .public) replies, battery=\(battery.map(String.init) ?? "—", privacy: .public)")
            return RecorderDeviceInfo(batteryPercent: battery,
                                      isCharging: batteryReading?.isCharging,
                                      storage: storage,
                                      rawReplies: replies,
                                      notes: notes)
        }
    }

    // MARK: RecorderLink — microphone gain (the official “Microphone Gain” item)

    /// Set the card's microphone gain — using the **write** direction of `0x08`:
    ///
    /// ```
    /// 01 08 00 | 02 <rec_led_status> <rec_scene> <rec_mode> <row_data> <micCode>
    /// ```
    ///
    /// Byte-by-byte derivation can be found in `TicNoteGeneralSetting.writePayload` and `TicNoteMicrophoneGain`
    /// (two levels: official UI `24 db` = `0xD6`, `36 db` = `0xFE`).
    ///
    /// ## Why the current settings must be read before writing
    /// This frame is not a “new setting”, but **the current settings on the card with the gain slot replaced**.
    /// If you construct it with default values, you inadvertently change the user's recording scene / indicator light to our guessed values
    /// (the real device now is `led=0, scene=2, mode=0, row_data=1`; guessing wrong means **modifying the user's card**).
    /// Therefore:
    /// * If `lastGeneralSetting` is unavailable → read a `0x08` first;
    /// * If still unreadable → **throw an error, send nothing**.
    ///
    /// ## Why a `0x08` response from the card indicates success
    /// The official logic does this: `changeVolume` registers a callback on `reviceApi.on("8")`,
    /// and that callback **shows “Settings saved` (`myDevice_setdbsucc`) and dismisses the overlay**
    /// — meaning the official side also waits for the card’s reply to consider the write successful.
    /// If no response is received = the card didn’t acknowledge, throw `.timeout` so the UI reports it truthfully (**no fake success**).
    ///
    /// ## ⚠️ Consequence note (written in the implementation to prevent future assumptions of a bug)
    /// After writing, **reading back `0x08` cannot verify the gain**: the card reports the 5th byte (`dmic_mode`)
    /// on the real device as `0x7F`, which is unrelated to `0xD6`/`0xFE` (the official app also falls back to index 0 on this card).
    /// Therefore updating `lastGeneralSetting` here only refreshes the “other four fields” to match the card’s report,
    /// the UI does not promise a “read-back confirmation”.
    func setMicrophoneGain(_ gain: TicNoteMicrophoneGain) async throws {
        try await runExclusive {
            guard isConnected else { throw RecorderLinkError.notConnected }

            // ① Obtain the “card’s current settings” — this frame’s five current values depend entirely on it.
            var current = lastGeneralSetting
            if current == nil {
                inbox.drain()
                try write(TicNoteFrameCodec.frame(
                    rawCmd: TicNoteObservedCommand.getConfig.rawValue,
                    payload: Data([TicNoteGeneralSetting.readFlag])
                ))
                let deadline = Date().addingTimeInterval(Self.deviceInfoWindow)
                while Date() < deadline {
                    guard let frame = try? await nextFrame(timeout: Self.deviceInfoFrameTimeout) else {
                        break
                    }
                    guard let decoded = TicNoteFrameCodec().decode(frame),
                          decoded.type == TicNotePacketType.commandResponse.rawValue,
                          decoded.cmd == TicNoteObservedCommand.getConfig.rawValue,
                          let parsed = TicNoteGeneralSetting.parse(decoded.payload)
                    else { continue }
                    lastGeneralSetting = parsed
                    current = parsed
                    break
                }
            }
            guard let setting = current else {
                // If unreadable, do not send — constructing the frame with default values would alter other user settings, which is worse than “not set this time”.
                throw RecorderLinkError.malformed(
                    "cannot set microphone gain without the card's current settings"
                )
            }

            // ② Write. payload = current settings echoed back + target gain code.
            let payload = setting.writePayload(gain: gain)
            try write(TicNoteFrameCodec.frame(rawCmd: TicNoteObservedCommand.getConfig.rawValue,
                                             payload: payload))

            // ③ Wait for the card to acknowledge (criterion described in the above “why” section).
            let deadline = Date().addingTimeInterval(Self.deviceInfoWindow)
            while Date() < deadline {
                guard let frame = try? await nextFrame(timeout: Self.deviceInfoFrameTimeout) else {
                    break
                }
                guard let decoded = TicNoteFrameCodec().decode(frame),
                      decoded.type == TicNotePacketType.commandResponse.rawValue,
                      decoded.cmd == TicNoteObservedCommand.getConfig.rawValue
                else { continue }
                // If the response can be decoded, update the “card’s statement” (if not, it’s fine: the card did reply).
                if let updated = TicNoteGeneralSetting.parse(decoded.payload) {
                    lastGeneralSetting = updated
                }
                log.info("mic gain write acknowledged: \(gain.label, privacy: .public)")
                return
            }
            throw RecorderLinkError.timeout
        }
    }

    // MARK: RecorderLink — unbind device

    /// Unbind: `01 05 00 00` (no parameters, byte source see `TicNoteUnbind`).
    ///
    /// ## Why **send only, no wait for reply** (same rule as `deleteRecording`)
    /// This frame never appeared in any of the four real-device captures, so there is no sample to determine whether the card replies after receiving it
    /// Waiting for a possibly never-coming response would occupy the command lock for an entire timeout window
    /// — and the user would just feel “stuck” before the next operation. Sending itself is the entire action of this operation.
    ///
    /// ## This frame **does not delete recordings on the card**
    /// In the card’s command table, “clear data” is **a separate command** (`WriteCmd::clearData` = `01 68 00`),
    /// the official statement “unbinding will clear all device data” refers to the entire cloud process.
    /// Our button is labeled “Unbind Device”, which only performs unbinding — deleting recordings has a different entry (auto-delete after upload).
    ///
    /// ## After unbinding, this connection is invalidated on the card side
    /// `didProvisionSession` is cleared: thus the next operation will redo the opening handshake (identity query + bind frame),
    /// instead of using a session that the card no longer recognizes to continue sending commands.
    func unbindDevice() async throws {
        try await runExclusive {
            guard isConnected else { throw RecorderLinkError.notConnected }
            try write(TicNoteUnbind.frame)
            didProvisionSession = false
            log.info("unbind frame sent (01 05 00 00)")
        }
    }

    // MARK: RecorderLink — recording status

    /// Read once whether the card is recording and for how long.
    ///
    /// ## ★ 2026-10-10 rewrite: this entry **now returns the actual `isRecording`**
    ///
    /// The previous version said “the card has no decodable ‘is recording’ field, so it deliberately returns nil and the local stopwatch fills in”.
    /// That logic only counted **control frames**, ignoring the `0x02` voice stream — after including the voice stream,
    /// the card actually **continuously** informs the App that it is recording (~100 frames/s, see `streamingVoice`).
    ///
    /// Now `isRecording` is provided based on three criteria (order = priority):
    ///   1. Voice frame stream is still alive → `true`;
    ///   2. Session events: most recent `0x14` → `true`, `0x17` → `false`;
    ///   3. Neither seen → `nil` (“unknown”, **not** `false`).
    ///
    /// ## `0x03` / `0x06` remain “undecodable”
    /// Across the full set of 10 captures, the `0x03` payload **has only two variants**, and neither changes with recording.
    /// ```
    /// 01 03 00 | 01 00 00 00 00 00 00 01 00   ×9   ← state = 0x00000001
    /// 01 03 00 | 01 20 00 00 00 00 00 01 00   ×1   ← state = 0x00002001
    /// ```
    /// That sole “anomalous” sample occurred **immediately after connection**, and within the same batch of responses
    /// `0x09` battery reading is `01 64` (first byte `0x01` = charging), while the other nine samples are `00 64`.
    /// Thus the `0x2000` bit in `state` more likely indicates “**external power/charging**”, **unrelated to recording**.
    /// Conclusion unchanged: **do not** use `0x03` to determine recording status.
    ///
    /// ## Concurrency and failure semantics
    /// * `runExclusive` + `inbox.drain()`: during the read we are the **sole** consumer.
    /// * If the card does not answer any packet → **return an empty state, no error** (protocol-level contract,
    ///   see the semantic contract of `RecorderLink.readRecordingStatus`) —
    ///   the caller performs 1 Hz polling and needs the “card silent” information to continue.
    /// * **After `statusSilentBackoffAfter` consecutive no-answers → backoff**: skip the entire batch of writes,
    ///   return the cache directly (see `statusSilentStreak`). This is the key step that prevents a “silent card” from dragging down
    ///   the command lock.
    /// * Only a broken link triggers `.notConnected`.
    func readRecordingStatus() async throws -> RecorderRecordingStatus {
        try await runExclusive {
            guard isConnected else { throw RecorderLinkError.notConnected }

            // “Has the card spoken since the last query” — here we **retrieve and reset** it,
            // instead of comparing counters: the caller sequence is `startRecording()` → immediately
            // `readRecordingStatus()`, and if the card acknowledges it will push a `0x14`/`0x17` between these two steps.
            // Counter comparison cannot achieve this (the count before start-recording is unavailable).
            let sawSessionNotice = pendingSessionNotice
            pendingSessionNotice = false

            // ★ As soon as the card speaks, it shows it’s alive — immediately clear the backoff.
            //   If we don’t do this, “the card ignored us several times just now” will cause the poller to stay silent,
            //   even though the card has already started responding (e.g., recording just began, `0x18` has been pushed).
            if sawSessionNotice { statusSilentStreak = 0 }

            // ★★ Backoff: if the card returns no characters for several consecutive attempts, **stop writing**.
            //
            // Why not “write fewer commands” but “write none”: among these four commands, `0x1A` is
            // the only one that can still provide information (it makes the card return a `0x18` with **real-time byte count**,
            // see the section below), while the other three disappear into the void when the card is silent. Keeping `0x1A` merely
            // reduces lock occupancy from 1.5 s to 0.8 s — at the cost of injecting a **full file list** into `inbox` each second
            // (the real device at 16:40:09 had 9 notifications and 58 recordings),
            // which is exactly what we want to discard.
            //
            // ⚠️ The return is a **cache** (`lastSessionNotice` / `streamingVoice` are both updated in real time on the `didUpdateValueFor` side path,
            //    bypassing the command lock and unaffected),
            //    so the UI’s stopwatch/red dot will not freeze due to this backoff.
            if statusSilentStreak >= Self.statusSilentBackoffAfter {
                let cachedNotice = lastSessionNotice
                let cachedBytes: Int? = cachedNotice?.isEndEvent == true
                    ? cachedNotice?.fileSize
                    : (voiceStreamBytes ?? cachedNotice?.fileSize)
                TicNoteDiagLog.log("STATUS",
                    "Backing off (consecutive \(statusSilentStreak) zero-response times) → no command sent, return cache")
                return RecorderRecordingStatus(
                    isRecording: pushedRecordingState,
                    totalBytes: cachedBytes,
                    deviceElapsed: cachedBytes.map {
                        Double($0) / TicNoteRecordingState.bytesPerSecond
                    },
                    sawSessionNotice: sawSessionNotice,
                    rawReplies: [:]
                )
            }

            inbox.drain()
            // ★ This connection has not yet sent an opening handshake, so pre-emptively send one (`force: false` → send only once,
            //   instead of writing to the card twice per second). The reason is identical to the pre-recording case, see `provisionSession`.
            await provisionSession(force: false)
            inbox.drain()
            // Three read-only queries. On the real device, #32137–#32163 were sent consecutively
            // (APP sends 0x09/0x06/0x08 → card replies 0x0B/0x09/0x06/0x08).
            // ★ 2026-10-10 re-add `0x09` (battery): it was already part of the official “continuous read”,
            //   but we only read it manually on the device page — resulting in a static battery level during recording. Adding it back
            //   makes this 1 Hz poll also refresh the battery (`lastBatteryReading` is @Published,
            //   and the charging flag updates with the same frame).
            try write(TicNoteFrameCodec.frame(
                rawCmd: TicNoteObservedCommand.getStatusInfo.rawValue, payload: Data()
            ))
            try write(TicNoteFrameCodec.frame(rawCmd: Self.deviceStatusCommand, payload: Data()))
            try write(TicNoteFrameCodec.frame(
                rawCmd: TicNoteObservedCommand.getBattery.rawValue, payload: Data()
            ))
            // ★★ 2026-10-10 correction: the purpose of that `0x1A` here **is not** “list files”,
            //   but “request a `0x18` with real-time byte count”.
            //
            // The previous version reasoned: "card won't spontaneously push voice frames, no `0x1A` means no `recordedBytes`",
            // The direction is correct, but the response shape was misdescribed. Real-device frame-by-frame verification (`/tmp/t3.log` 16:36:24–28):
            //
            // ```
            //   16:36:24.162 → WC 01 1A 00 01 00 00 00 00 00 00 00 00
            //   16:36:24.187 ← CTL 01 18 00 06 F9 C9 6A 02 00 1E 00 00 00   ← 10 B
            //   16:36:25.244 → WC 01 1A … (same flag=1)
            //   16:36:25.300 ← CTL 01 18 00 06 F9 C9 6A 02 A0 41 00 00 00   ← byte count increasing
            // ```
            //   10-byte `0x18` (`sid(4) + 0x02 + u32 written byte count + 0x00`),
            //   not a file list — this part matches the old comment, **kept**.
            //
            // ⚠️ However, real devices have also seen it **output a full file list** (the two batches at 16:36:30 / 16:40:09,
            //    9 notifications, 58 recordings, with total `0x3A`) — same request yields two response types,
            //    criteria not resolved (flag is 1, unrelated to recording state).
            //    Here **we leave it unchanged**, for two reasons:
            //      1. It is the sole source of "real-time byte count during recording" (`0x18`); removing it reverts
            //         the user-reported bug where the stopwatch is stuck at 0:00;
            //      2. Even if it dumps a list, it will be discarded by this function's `continue`,
            //         Won't pollute the state machine (state machine only parses `0x1A` in `.listing`).
            //    Excess traffic is caught by the above **backoff**: when the card doesn't respond, the whole batch is suppressed.
            try write(TicNoteFrameCodec.getSessionList(a: 1, b: 0, flags: 0))

            var replies: [UInt16: Data] = [:]
            let expected: Set<UInt16> = [
                TicNoteObservedCommand.getStatusInfo.rawValue,
                Self.deviceStatusCommand,
                TicNoteObservedCommand.getBattery.rawValue,
            ]
            let deadline = Date().addingTimeInterval(Self.recordingStatusWindow)

            while !expected.subtracting(replies.keys).isEmpty {
                if Date() > deadline { break }
                // `nextFrame` throws timeout = card finished responding (normal exit), must `break`.
                guard let frame = try? await nextFrame(timeout: Self.recordingStatusFrameTimeout) else {
                    break
                }
                guard let decoded = TicNoteFrameCodec().decode(frame),
                      decoded.type == TicNotePacketType.commandResponse.rawValue,
                      expected.contains(decoded.cmd),
                      replies[decoded.cmd] == nil
                else { continue }   // Card-initiated frames are always skipped (they have separate logs)
                replies[decoded.cmd] = decoded.payload
            }

            // ★ Backoff count (see `statusSilentStreak`): whether anything was received this pass.
            //   Reset to zero upon receiving any item — the card is slow, not silent; ask again next time.
            if replies.isEmpty {
                statusSilentStreak += 1
            } else {
                statusSilentStreak = 0
            }

            // Session/recording status is **pushed** by the card (`0x14` / `0x17`); we don't query here, just read the cache.
            // (`streamingVoice` is a computed property, no need to "refresh" here—it reflects the current state.)
            let notice = lastSessionNotice
            let isRecording = pushedRecordingState

            // ── Byte count: take the "more reliable" one────────────────────────────────────
            //   · Session end frame (0x17) reported a non-zero final size → use it (cross-validated by three parties);
            //   · Otherwise use the **written byte count** from the live voice stream (real-time, grows with each fragment);
            //   · If neither, fall back to the original value in the session frame (may be 0).
            let bytes: Int?
            if let notice, notice.isEndEvent, let finalSize = notice.fileSize, finalSize > 0 {
                bytes = finalSize
            } else if let streamed = voiceStreamBytes {
                bytes = streamed
            } else {
                bytes = notice?.fileSize
            }

            // ── Duration: two independent estimates; only trust the clock estimate when they **agree** ──────────
            // Byte-based conversion (8000 B/s) reflects the device's true value; using `sessionId` (= start Unix seconds)
            // Subtracting the current time is also a device truth, but it depends on the card's RTC — real devices have seen RTC drift up to half a year.
            // Therefore we only trust it when the clock estimate is **greater than** the byte estimate and the difference is < 2 minutes
            // (Huge discrepancy = RTC unsynced, discard). This is more robust than any unilateral assumption.
            var elapsed: TimeInterval? = bytes.map {
                Double($0) / TicNoteRecordingState.bytesPerSecond
            }
            if isRecording == true,
               let start = notice?.startedAt,
               let byBytes = elapsed {
                let byClock = Date().timeIntervalSince(start)
                if byClock > byBytes, byClock - byBytes < 120 {
                    elapsed = byClock
                }
            }

            TicNoteDiagLog.log("STATUS", "isRecording=\(isRecording.map(String.init) ?? "nil")"
                + " bytes=\(bytes.map(String.init) ?? "nil")"
                + " card spoke before query=\(sawSessionNotice)"
                + " backoff count=\(statusSilentStreak)"
                + " replies received=[\(replies.keys.sorted().map { String(format: "0x%02X", $0) }.joined(separator: ","))]")

            return RecorderRecordingStatus(
                isRecording: isRecording,
                totalBytes: bytes,
                deviceElapsed: elapsed,
                sawSessionNotice: sawSessionNotice,
                rawReplies: replies
            )
        }
    }

    /// `0x06` online code. ⚠️ It **is not** in `TicNoteObservedCommand` (that table records
    /// "supplemental codes not in static tables but present on real devices", but it does exist on real hardware and is used bidirectionally
    /// (`att-decoded.txt` #32138 outbound / #32162 inbound, inbound direction 13 bytes).
    /// Use a literal instead of modifying the protocol enum — a display name isn’t worth changing the protocol layer.
    private static let deviceStatusCommand: UInt16 = 0x0006

    /// Overall window for reading recording status. On real devices these two responses are returned within a second; 1.5 s is already generous.
    /// ⚠️ Much shorter than `deviceInfoWindow` **by design**: this is polled at 1 Hz,
    /// If the window exceeds 1 s, two consecutive polls will overlap.
    private static let recordingStatusWindow: TimeInterval = 1.5

    /// Upper bound for single-frame wait. Same order as the window; expiration means the card has finished responding.
    private static let recordingStatusFrameTimeout: TimeInterval = 0.8

    /// Overall window for reading device info. On real devices the card replies in seconds (after #29960 sends 5 read commands,
    /// #29998 all 5 responses arrived before then), so 4 s is already generous —
    /// Give a generous timeout because the card may still be running its own boot process right after connection.
    private static let deviceInfoWindow: TimeInterval = 4

    /// Single-frame wait limit. When it expires, consider the card's response complete (normal termination, not an error).
    private static let deviceInfoFrameTimeout: TimeInterval = 2

    // MARK: RecorderLink — Wi-Fi high-speed channel

    /// Wi-Fi high-speed channel. **Credentials are derived locally from the SN; the card does not need to report anything.**
    ///
    /// ⚠️ Here **not** "return a channel if connection succeeds", but "return nil if credentials cannot be computed":
    /// Returning a channel without an SSID will cause the user to wait 20 seconds after selecting Wi-Fi before timing out,
    /// then receive a "connection timeout"— that error is unrelated to the actual cause (missing SN).
    /// The card's most recent self-reported recording session ID (present in `0x14`/`0x17`/`0x18`).
    ///
    /// ★ This is the **full 32-bit** sid — on a real device: `0x14` reports `77 43 C7 6A`,
    /// The official app's subsequent `0x1C` request uses exactly these four bytes (`captures/bug2-20261008.att.txt`
    /// lines 38087 / 38103). The value in `0x18` was once recorded as "truncated to 26 bits"
    /// (§21.4), **do not use it to fetch files** — that `0x1C` failure (status 0x02)
    /// was likely caused by using the truncated value.
    var lastSessionID: UInt32? { lastSessionNotice?.sessionID }

    var fastTransfer: (any RecorderFastTransfer)? {
        guard isConnected, let credentials = fastTransferCredentials else { return nil }
        return TicNoteWifiLink(ble: self, credentials: credentials)
    }

    /// Credentials for fast transfer. Retrieval **prefers the card-reported value, falling back to SN-derived**:
    ///
    ///   1. `wifiCredentials` — value actively reported by the card over BLE (almost always nil on real devices,
    ///      retained for cross-validation when firmware rules change);
    ///   2. `serialNumber` — **default path**. `TicNoteWifiCredentials.from(sn:)`
    ///      directly computes `SSID = "TicNote-" + last 4 digits of SN`, `password = last 8 digits of SN`
    ///      (confirmed by official app logcat on real device, `protocol-notes.md` §18.1).
    ///
    /// Both unavailable yields `nil` (fast transfer unavailable). This block is extracted because
    /// `fastTransfer` and `fastTransferUnavailableReason` must use **the same criterion**—
    /// duplicating the logic on both sides inevitably leads to "button lit but times out immediately".
    private var fastTransferCredentials: TicNoteWifiCredentials? {
        if let reported = wifiCredentials { return reported }
        guard let sn = serialNumber else { return nil }
        return TicNoteWifiCredentials.from(sn: sn)
    }

    var fastTransferUnavailableReason: String? {
        if !isConnected { return "The card is not connected over Bluetooth." }
        // Clarify "what's missing" instead of a vague "not ready".
        //
        // Fast-transfer SSID and password are derived from SN, so only one possibility remains here:
        // We didn't read this card's SN (no manufacturer data in the advertisement). The previous "wait for card password" wording
        // is now obsolete — see `fastTransferCredentials`.
        if fastTransferCredentials == nil {
            return "Fast transfer needs the card's serial number, which Nomily reads "
                 + "from the Bluetooth advertisement. It was not seen for this card, "
                 + "so the hotspot name and password cannot be derived. Try moving "
                 + "closer and reconnecting. Bluetooth transfer works now."
        }
        return nil
    }

    /// Instruct the card to start a hotspot: **send a bind frame first, then `01 0A 00`**. `0x0A` = static table `0x14 >> 1`.
    ///
    /// ## ⚠️ The order is strict; the first frame cannot be omitted (validated on real device in round 15, `protocol-notes.md` §17.1).
    /// Sending `01 0a 00` without a bind frame causes the card to reply with a single identity frame, **neither ACK nor chaining**, 
    /// and the hotspot never starts (symptom: "command sent but nothing happens", very hard to diagnose).
    /// Include the binding frame; the device replies `01 0a 00 00`, and after about 1.8 s it proactively disconnects BLE to start AP.
    /// Therefore the binding frame is not "only part of the binding process"; it is a **prerequisite** for `OPEN_WIFI`.
    ///
    /// The SSID in the binding frame uses the **fast-transfer hotspot name derived from the SN**, not the official binding-period name
    /// `"clip c1 pro"`: if the device actually accepts the name in this frame, it also matches `fastTransfer`
    /// The subsequent SSID to join will be exactly the same, so there will be no "sent name and connected name mismatch".
    ///
    /// Send only, no response expected (same convention as `syncTime` / `deleteRecording`) — the device will not send anything beyond ACK
    /// useful information; waiting for it would instead block the command lock.
    func sendOpenWifi() async throws {
        try await runExclusive {
            guard isConnected else { throw RecorderLinkError.notConnected }

            // Without an SN the correct hotspot name cannot be generated. In this case **prefer failure** over skipping the binding frame and forcing a send
            // `01 0a 00` — that would only receive an identity frame, then wait for a full timeout and report an error unrelated to the real cause.
            guard let sn = serialNumber,
                  let ssid = TicNoteWifiCredentials.hotspotSSID(fromSN: sn),
                  let bind = TicNoteWifiProvisioning.sendTokenFrame(ssid: ssid)
            else {
                throw RecorderLinkError.unsupported(
                    "TicNote fast transfer needs the card's serial number to build the "
                    + "provisioning frame that precedes OPEN_WIFI"
                )
            }
            try write(bind)
            // Leave a beat between two commands: the device must record this frame before recognizing the next one.
            // Empirically, 0.2 s is sufficient (the official implementation also sends them back-to-back in the same session).
            try await Task.sleep(nanoseconds: 200_000_000)

            guard isConnected else { throw RecorderLinkError.notConnected }
            try write(TicNoteFrameCodec.frame(.openWifi))
        }
    }
}

// MARK: - CBPeripheralDelegate

extension TicNoteLink: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                self.failHandshake(error)
                return
            }
            guard let svc = peripheral.services?.first(where: { $0.uuid == TicNoteGATT.clipService }) else {
                self.failHandshake(RecorderLinkError.malformed("TicNote service 1910 not found"))
                return
            }
            peripheral.discoverCharacteristics(
                [TicNoteGATT.writeCharacteristic, TicNoteGATT.notifyCharacteristic],
                for: svc
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.failHandshake(error)
                return
            }
            for ch in service.characteristics ?? [] {
                if ch.uuid == TicNoteGATT.writeCharacteristic { self.writeChar = ch }
                if ch.uuid == TicNoteGATT.notifyCharacteristic { self.notifyChar = ch }
            }
            guard let notify = self.notifyChar, self.writeChar != nil else {
                self.failHandshake(RecorderLinkError.malformed("2BB0/2BB1 missing"))
                return
            }
            peripheral.setNotifyValue(true, for: notify)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.failHandshake(error)
                return
            }
            if characteristic.uuid == TicNoteGATT.notifyCharacteristic, characteristic.isNotifying {
                if let cont = self.handshakeContinuation {
                    self.handshakeContinuation = nil
                    cont.resume()
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        Task { @MainActor in
            let isControl = [UInt8](data).first == TicNotePacketType.commandResponse.rawValue
            if isControl {
                self.lastControlFrame = data
                TicNoteWifiProbe.record(data, into: &self.inboundControlFrames)
                // ★ Passively copy a copy for UI + session state. **Place before `absorb`**, 
                //   so regardless of who consumes this frame later (list/download/device info read),
                //   the user can see on the UI what the device said.
                self.observeControlFrame(data)
                // Opportunistically try to recognize Wi-Fi credentials. If unrecognizable, do nothing —
                // Must not mistake "device sent another control frame" for "device provided credentials".
                if self.wifiCredentials == nil,
                   let creds = TicNoteWifiCredentials.parseBLEFrame(data) {
                    self.wifiCredentials = creds
                    log.info("card reported Wi-Fi ssid=\(creds.ssid, privacy: .public)")
                }
            }
            self.absorb(data)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Writes with `.withoutResponse` never trigger this callback; it is kept in case we switch to a response-required write in the future
        // (the official `0x1D getSessionState` uses a response write) so failures become immediately visible.
        if let error {
            log.warning("write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func failHandshake(_ error: Error) {
        if let cont = handshakeContinuation {
            handshakeContinuation = nil
            cont.resume(throwing: error)
        }
    }
}

// MARK: - LiveAudioSource (real-time transcription: pull while recording)
//
// ## Why this section is in this file instead of a new `TicNoteLiveSource.swift`
// The lockstep loop must **directly consume** `inbox` (via `nextFrame`) and **directly write** GATT (via `write`),
// Both are `private`, and Swift's `private` is **file-level** scope —
// Moving to another file would cause a compile error. Extracting it would require relaxing the single-consumer constraint on `inbox` to `internal`,
// which is the only guarantee that "list / download / read-status" do not compete for frames (already caused a false timeout on real hardware
// due to frame contention). **Not worth sacrificing file line count.**
//
// ## How this path was decided
// Real-time transcription needs to capture audio while the device is **still recording**; TicNote firmware has two possible paths:
//
// | Path | Basis | Conclusion |
// |---|---|---|
// | `0x03` real-time audio stream | In 13 captures, `0x03` frame count is **all zero**; the two official parsers contradict each other | Discard |
// | **Pull while recording** (`0x1C` chunked polling of growing file) | The official app does this throughout recording | **Take this path** |
//
// Full capture is in `captures/hci-all/bug2-20261008.att.txt` session `0x6AC74377` (72.15 s):
//
// ```
//   0x14 (session start, with full sid)        5774.351
//   0x1D → 0x1E (prelude)                5774.368 → 5774.492
//   0x1C × 353                         5774.713 → 5848.276
//     start strictly consecutive 0 → 1600 → … → 563520 (last chunk 320 B)
//   0x17 (session end, fileSize=563520)   5846.503
// ```
//
// ★ The most important point: **the card throttles itself in real time**. In steady state, every 25 chunks take exactly 5.0 s = 5 chunks/s,
// and each chunk 1600 B = 0.2 s of audio — exactly 1 second of audio per second. The first 25 chunks are faster than real time
// (the card is filling the unwritten beginning part), indicating **the card waits until it finishes writing before sending**.
// Hence the algorithm can be simple enough to not need to ask "how much has been written now":
//
// ```
//   Request [pulled, pulled+1600) → wait for 20 0x02 packets → wait for chunk tail → pulled += 1600 → request again
// ```
//
// ## Two lines you must not cross
// 1. **Must stay in lockstep**: the card's firmware only accepts a single in-flight command; premature sends are dropped or return a non-zero status.
// 2. **`0x1D` is not an optional optimization**: it is the switch that "makes the card respond with `0x1C`" (without it, real device
//    0 frames within 60 s). Moreover, it must **immediately follow a complete opening sequence** to receive `0x1E`.
extension TicNoteLink: LiveAudioSource {

    // MARK: Identity / Capability

    /// ★ TicNote is a **160-byte stereo 48 kHz** Opus packet (TOC always `0xBC`),
    /// not the same as D·NOTE's 40-byte mono **thing**. Wrong transmission does not error,
    /// will only decode noise / duration 4× off — see `OpusOgg.Profile`.
    var opusProfile: OpusOgg.Profile { .ticNote }

    /// TicNote's recording files are plain Opus raw streams, with no encryption on the device side.
    var liveClipKey: Data? { nil }

    var isAvailable: Bool { isConnected }

    var liveLastSessionKey: String? {
        (liveFullSessionID ?? livePump?.sessionID).map { String($0) }
    }

    // MARK: Probe State

    /// ★★ 2026-10-12: TicNote's "is recording" criterion is **not the same** as D·NOTE's.
    ///
    /// D·NOTE has a query that returns a clear `Bool`, so "cannot query" is **abnormal**,
    /// worth pausing to show a dialog to the user — the three-state branch in `LiveModel.start()` was written for this.
    ///
    /// TicNote lacks such a query:
    /// * When the card **is recording**, the `0x1A` we send is answered with a `0x18` containing **real-time byte count**
    ///   (the `readRecordingStatus` comment includes per-frame samples) → `pushedRecordingState` has a value;
    /// * When the card **is not recording**, these read-only queries yield no session events — real-device capture
    ///   (the `pushedRecordingState` function signature) three consecutive `isRecording=nil` indicate this state.
    ///
    /// In other words, **`nil` on TicNote is normal, not an "exception"**. Upload it as-is,
    /// `LiveModel.start()` **every time** will pop "cannot confirm whether the recording device is recording" —
    /// Users must tap an extra time each time they start live transcription; a mistap appears as "no response".
    ///
    /// ## Narrowing rules (three stages, descending reliability)
    /// 1. Cache contains a value → trust it directly (the card in this segment has already spoken).
    /// 2. Actively probe once: `readRecordingStatus()`'s `0x1A` retrieves the "recording" card.
    /// 3. After probing, no session event, **but the card answered our read-only query** (`rawReplies` non-empty)
    ///    → Card is alive, link is up, but not recording → `false`.
    ///    This clause separates this function from the legacy implementation: the old code treated this **explicit card response**
    ///    as "unknown", triggering a dialog.
    /// 4. Card does not answer any read-only query (back-off / disconnected) → `nil`, keep the dialog — this is the true "unknown".
    ///
    /// ⚠️ Remaining uncertainty (noted here for reference): rule 3 assumes a "recording" card always pushes `0x18`.
    ///    All real-device samples satisfy this (`0x18` is the sole source of `recordedBytes`),
    ///    but if a "recording" card answers read-only queries yet does not push `0x18`, this will be mis-judged as
    ///    `false` and emit `0x14` to start recording. This is the sole risk exposure of the rule.
    func liveIsRecording() async -> Bool? {
        if let cached = pushedRecordingState { return cached }
        guard let probed = try? await readRecordingStatus() else { return nil }
        if let known = pushedRecordingState { return known }
        if !probed.rawReplies.isEmpty {
            log.info("liveIsRecording: card answered the read batch but pushed no session event — not recording")
            return false
        }
        log.warning("liveIsRecording: card answered nothing at all — recording state genuinely unknown")
        return nil
    }

    func liveListFiles() async -> [LiveDeviceFile]? {
        guard let list = try? await listRecordings() else { return nil }
        return list.map {
            LiveDeviceFile(name: Self.liveFileName(sessionID: $0.sessionID,
                                                  fallback: $0.displayTitle),
                           size: $0.sizeBytes,
                           sessionID: $0.sessionID)
        }
    }

    // MARK: Start

    func liveStartNew() async throws {
        // The session ID from the previous round (or last connection) must be cleared first; if retained,
        // `liveSessionIDCandidates()` will place the **previous recording's sid** at the top,
        // causing us to request a new recording with the old sid — the card responds with "accept" (that sid actually exists,
        // just not for this segment), resulting in retrieving the entire **previous recording's audio**.
        liveFullSessionID = nil
        liveTruncatedSID = nil
        try await startRecording()
        await liveAwaitSessionID(timeout: 2.5)
    }

    func liveAttach() async throws {
        // ⚠️ Cannot write as `pushedRecordingState ?? (try? await …)` —
        //    because the right side of `??` is an autoclosure, and Swift forbids `await` in a non-concurrent closure
        //    (error: `'async' call in a function that does not support concurrency`).
        let recording: Bool?
        if let pushed = pushedRecordingState {
            recording = pushed
        } else {
            recording = (try? await readRecordingStatus())?.isRecording
        }
        // `nil` = cannot query — must not be treated as "not recording" (that would present a false statement to the user),
        // but **must not** allow it: taking over a non-existent recording would cause `firstFrameTimeout` to wait indefinitely.
        guard recording == true else { throw LiveStartError.deviceNotRecording }
        await liveAwaitSessionID(timeout: 2.5)
        guard !liveSessionIDCandidates().isEmpty else { throw LiveStartError.noSessionID }
    }

    // MARK: Audio pipeline

    func liveAudio(firstFrameTimeout: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        // ★★ Two cleanup steps for "starting a new session" are both required (2026-10-12):
        //   ① `liveGeneration` +1 — lets the previous round's `onTermination` recognize
        //      that "the termination belongs to a different round" and exit itself, preventing it from killing the new pump;
        //   ② `liveStopping = false` — it is only set true inside `liveStop()`,
        //      and `liveStop()` definitely ran in the previous round. Not resetting causes a "stuck" state,
        //      causing the new streaming loop to exit immediately on its first `while !liveStopping` check.
        // (real device: `18:13:17.584 start streaming` → `18:13:17.585 stop streaming`, 1 ms).
        liveGeneration &+= 1
        let generation = liveGeneration
        liveStopping = false

        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .unbounded) { c in
            cont = c
        }
        cont.onTermination = { [weak self] _ in
            // Consumer (`LiveModel`) stopped — let the pump exit itself in the next loop iteration.
            // Only set the flag, **do not touch GATT here**: `onTermination` may be called on any queue,
            // while `write` must be serialized on the main actor.
            //
            // ⚠️ Must pass the `liveGeneration` check: this closure was registered in the previous session,
            //    When it runs, `liveTask` may already point to **next round** pump.
            //    (No ordering guarantee between `onTermination` and `liveAudio()`).
            //    Without sequence check, "receive previous round" equals "kill next round".
            Task { @MainActor in
                guard let self, self.liveGeneration == generation else { return }
                self.liveStopping = true
                self.liveTask?.cancel()
            }
        }
        liveSink = cont
        liveTask = Task { @MainActor [weak self] in
            await self?.runLiveLoop(firstFrameTimeout: firstFrameTimeout)
        }
        return stream
    }

    /// Synchronized streaming loop. **The entire live session is this single while**.
    ///
    /// It handles three tasks simultaneously, because these three must share the same frame stream (`inbox` allows only one consumer):
    /// ① Send `0x1C`; ② Accumulate `0x02` frames into a 160 B full packet for ASR; ③ Use chunk tail to advance synchronization.
    private func runLiveLoop(firstFrameTimeout: TimeInterval) async {
        defer {
            let summary = livePump?.diagnosticSummary ?? "(no pump)"
            TicNoteDiagLog.log("LIVE", "Receiving: \(summary)")
            liveTask = nil
            livePump = nil
            liveSink?.finish()
            liveSink = nil
        }

        guard isConnected else {
            liveSink?.finish(throwing: RecorderLinkError.notConnected)
            return
        }

        // ── ① Official fixed pre-streaming step for each segment (identical byte-for-byte to `fetchRecording`)
        await provisionSession(force: true)
        inbox.drain()
        _ = try? write(TicNoteFrameCodec.frame(rawCmd: TicNoteCommand.syncFileStop.wireValue))
        let ackDeadline = Date().addingTimeInterval(2)
        var sawSyncAck = false
        while Date() < ackDeadline {
            guard let f = try? await nextFrame(timeout: 0.5),
                  let d = TicNoteFrameCodec().decode(f),
                  d.type == TicNotePacketType.commandResponse.rawValue,
                  d.cmd == TicNoteObservedCommand.sessionStateResponse.rawValue
            else { continue }
            sawSyncAck = true
            break
        }
        // ⚠️ If not received, **do not abort**, but must be retained: on real device, 5 of 15 `0x1D` attempts were missed
        //    The rest are silent. If silence continues, "timeout" and "card unrecognized" appear identical in logs.
        TicNoteDiagLog.log("LIVE", sawSyncAck
            ? "0x1D confirmed by card (`0x1E`), start recording while streaming"
            : "⚠️ Did not receive 0x1E within 2 s (`0x1D` unconfirmed) — continue, the root cause may be card silence")

        // ── ② sid candidate ladder
        let candidates = liveSessionIDCandidates()
        guard !candidates.isEmpty else {
            TicNoteDiagLog.log("LIVE", "✗ No sid candidates (card did not report session ID)")
            liveSink?.finish(throwing: LiveStartError.noSessionID)
            return
        }

        var attempt = 0
        var pump = TicNoteLivePump(sessionID: candidates[0])
        livePump = pump
        TicNoteDiagLog.log("LIVE",
            "Start streaming sid=\(candidates[0]) (\(candidates.count) candidates: "
            + candidates.map { String(format: "0x%08X", $0) }.joined(separator: " → ") + "）")

        var sawFirstPacket = false
        let firstDeadline = Date().addingTimeInterval(firstFrameTimeout)
        var nextWriteAt = Date()

        while !liveStopping, !Task.isCancelled {
            // ── ⓪ Stall recovery: chunk tail lost / card silent, this chunk passed deadline ⇒ discard and resend
            //
            // ⚠️ Must be before `nextRequest()` **(i.e., before)**. Once `phase` is stuck in `.awaitingChunk`,
            //    `nextRequest()` will always return nil — the next chunk can never be sent.
            //    On the real device at `18:43:03` this happened: the first 17 chunks total 27200 B exactly, no missing bytes,
            //    The tail of the 17th chunk was lost; thereafter no chunk was requested for 20 s, yet the UI still showed "recording".
            //    This is what users describe as "cannot transcribe after 3 s".
            if pump.reclaimIfStalled() {
                TicNoteDiagLog.log("LIVE",
                    "⚠️ This chunk \(TicNoteLivePump.chunkTimeout) s no response ⇒ discard and resend:"
                    + pump.diagnosticSummary)
            }

            // ── ① Irrecoverable ⇒ propagate error to the stream (**must check each round**)
            //
            // Why it must be placed here: after `.failed` the pump will no longer produce any frames, and the two places below
            // `finish(throwing:)` both require obtaining a frame before execution ⇒ if not checked here it becomes
            // a dead loop "waiting forever for the next frame" — exactly the situation we must avoid for the user:
            // **UI stuck on "Recording", audio never progresses**.
            if case .failed(let why) = pump.phase {
                TicNoteDiagLog.log("LIVE", "✗ Live stream unrecoverable: \(why)")
                liveSink?.finish(throwing: RecorderLinkError.corrupted(why))
                return
            }

            if Date() >= nextWriteAt, let request = pump.nextRequest() {
                // The `_ =` is for the compiler: this branch is best-effort anyway (the pull-stream's
                // write failures surface as the next `nextFrame` timeout; there's nowhere to report them here),
                // but discarding the result of `try?` would leave a "result of 'try?' is unused" warning.
                _ = try? write(request)
            }

            guard let frame = try? await nextFrame(timeout: 1.0) else {
                // Single-frame timeout 1 s: on real device stable ~200 ms (≈20 frames).
                if !sawFirstPacket, Date() > firstDeadline {
                    TicNoteDiagLog.log("LIVE",
                        "✗ No frame arrived within \(Int(firstFrameTimeout)) s (first-frame timeout)")
                    liveSink?.finish(throwing: RecorderLinkError.timeout)
                    return
                }
                continue
            }

            let result = pump.ingest(frame)
            if !result.packets.isEmpty {
                if !sawFirstPacket {
                    sawFirstPacket = true
                    TicNoteDiagLog.log("LIVE", "✅ First 160 B Opus packet arrived")
                }
                for packet in result.packets { liveSink?.yield(packet) }
            }

            guard result.chunkCompleted || result.retryAfterBackoff else { continue }

            // ── ③ This segment finished (or encountered trouble), decide next step
            //
            // "Unrecoverable" has already been checked at the loop top — earlier, and **does not depend on receiving another frame**, 
            // therefore `.failed` (known total length but consecutive empty chunks / stalls) won't be missed.
            //
            // The **only** condition to switch SID: no bytes have been pulled yet, and the card gave a clear signal.
            // Deliberately split into two tiers because the certainty of these two cases differs completely:
            //   · `refusals > 0` — the card response explicitly reports status != 0. This is **hard evidence**, a single vote suffices;
            //   · `emptyChunks >= 3` — only "nothing at offset 0". When recording just started
            //     the file may genuinely not be written enough yet, so allow three attempts before deciding.
            // Conversely: as soon as any byte has been pulled, **never switch SID** —
            // at that point an empty chunk means "caught up to the write pointer", switching SID would discard good data.
            let firstAttemptFailed = pump.pulled == 0
                && (pump.refusals > 0 || pump.emptyChunks >= 3)
            if firstAttemptFailed {
                attempt += 1
                guard attempt < candidates.count else {
                    TicNoteDiagLog.log("LIVE",
                        "✗ All \(candidates.count) sid candidates rejected / empty slices — giving up live streaming")
                    liveSink?.finish(throwing: RecorderLinkError.malformed(
                        "no session id accepted by the card (\(candidates.count) tried)"))
                    return
                }
                pump = TicNoteLivePump(sessionID: candidates[attempt])
                livePump = pump
                TicNoteDiagLog.log("LIVE",
                    "↻ switching sid candidate → \(String(format: "0x%08X", candidates[attempt]))")
                nextWriteAt = Date()
                continue
            }

            // Normal progress; empty/short chunks trigger back-off — the card is ahead, wait for it to write.
            nextWriteAt = Date().addingTimeInterval(result.retryAfterBackoff ? 0.35 : 0)
        }
        // `defer` handles bookkeeping + stream receipt.
    }

    // MARK: Stop

    func liveStop() async -> LiveStopOutcome {
        let sid = livePump?.sessionID ?? liveFullSessionID
        let pulled = livePump?.pulled ?? 0

        liveStopping = true
        livePump?.stopRequesting()
        liveTask?.cancel()
        liveTask = nil
        liveSink?.finish()
        liveSink = nil

        try? await stopRecording()
        // After stopping recording the card pushes `0x17` (with final fileSize), which can also be found in the list — try both.
        try? await Task.sleep(nanoseconds: 600_000_000)

        var size = pulled
        if let notice = lastSessionNotice, notice.isEndEvent,
           let final = notice.fileSize, final > 0, sid == nil || notice.sessionID == sid {
            size = final
        } else if let sid, let list = try? await listRecordings(),
                  let found = list.first(where: { $0.sessionID == sid }) {
            size = found.sizeBytes
        }

        let file = sid.map {
            LiveDeviceFile(name: Self.liveFileName(sessionID: $0, fallback: "\($0)"),
                           size: size,
                           sessionID: $0)
        }
        TicNoteDiagLog.log("LIVE",
            "Stream stopped: sid=\(sid.map(String.init) ?? "—") pulled \(pulled) B / on card \(size) B")
        // Reaching here means we initiated the stop; a card-initiated stop follows the `liveAudio` stream-end branch.
        return LiveStopOutcome(file: file, deviceInitiated: false)
    }

    // MARK: Post-process (save / repair / cleanup)

    func liveFetch(file: LiveDeviceFile,
                   progress: @escaping @MainActor (Int, Int) -> Void) async throws -> Data {
        let recording = try liveRecording(for: file)
        return try await fetchRecording(recording) { fraction in
            progress(Int(Double(file.size) * fraction), file.size)
        }
    }

    func liveDelete(file: LiveDeviceFile) async throws {
        try await deleteRecording(try liveRecording(for: file))
    }

    /// Bytes accumulated in real-time → writeable Ogg Opus.
    ///
    /// ★ **This step cannot be omitted** (unlike D·NOTE which returns raw data):
    /// TicNote provides a **160 B raw packet stream**, whereas `PostDownload.process` has a fallback branch
    /// Sliced by **40 B** — a 160-byte stream will be cut into 4 fake frames,
    /// Page table completely wrong but **no error reported**, resulting in an unopenable file.
    func liveContainerize(_ raw: Data, name: String) throws -> Data {
        guard !raw.isEmpty else {
            throw RecorderLinkError.malformed("live audio is empty")
        }
        guard TicNoteOpusStream.looksLikeOpus(raw) else {
            throw RecorderLinkError.malformed(
                "live audio is not a plaintext 160 B Opus stream (\(raw.count) B)")
        }
        guard let ogg = TicNoteOpusStream.oggOpus(from: raw) else {
            throw RecorderLinkError.malformed("Ogg muxing failed (\(raw.count) B)")
        }
        return ogg
    }

    // MARK: Internal

    /// The sid reported by `0x18` has only **lower 26 bits**, this is the mask.
    ///
    /// According to (§21.4): `0x6AC9DB7B & 0x03FFFFFF == 0x02C9DB7B`,
    /// The sample delta `0xAF` between two points 175 s apart matches the wall clock exactly — so the lower 26 bits are correct,
    /// The only missing piece is "which 2^26-second epoch we are in".
    private static let sidLowMask: UInt32 = 0x03FF_FFFF

    /// Candidate sids usable for streaming, ordered by confidence high to low.
    ///
    /// | # | Source | Why Trusted |
    /// |---|---|---|
    /// | ① | sid in card-pushed `0x14`/`0x17` | **full 32-bit**; official capture lines 38087 → 38103 confirm that the subsequent `0x1C` uses these 4 bytes |
    /// | ② | lower 26 bits of `0x18` + **host clock** to fill high 6 bits | sid definition is "timestamp of this recording" |
    /// | ③ | current host Unix seconds (±1) | recording started just now, worst case off by a few seconds |
    ///
    /// Why provide **a list** instead of a single choice: card rejection is **immediate**
    /// (`0x1C` response status != 0). Hence "try each, eliminate by response" is better than "guess correctly once"
    /// Much cheaper — the cost of a candidate is just a single 16-byte write.
    ///
    /// ## ⚠️ Candidate 2 **do not** add the gate "how many seconds differ from host clock"
    /// Previously considered adding "restored value must fall within host clock ±120 s". **That premise is wrong**:
    /// `captures/hci-all/bug2-20261008.att.txt` contains two sessions' `0x14` reports
    /// `0x6AC738F1` / `0x6AC74377`, converted to Unix seconds roughly **2026-09-22**, while the capture is at
    /// **2026-10-08** — the card's own clock **lags about 16 days** (that round didn't send the correct timing frame `0x04`).
    /// Adding the gate will filter out this **completely correct** restored value, then fall back to candidate 3 (off by 16 days,
    /// inevitably wrong) — use an incorrect sid to send a series of `0x1C`, disguising "card not returning" as "protocol mismatch",
    /// That is exactly the most costly type of false clue.
    ///
    /// The guard's boundary is **whether the high 6 bits are correct** (an error occurs only after a half 2^26 cycle ≈ 398 days).
    /// Therefore candidate 2 unconditionally proceeds; correctness is judged by **acknowledgments** (`refusals` / consecutive empty frames),
    /// Not judged by the clock.
    private func liveSessionIDCandidates() -> [UInt32] {
        var out: [UInt32] = []
        if let full = liveFullSessionID, full != 0 { out.append(full) }
        if let truncated = liveTruncatedSID {
            let now = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
            let restored = (now & ~Self.sidLowMask) | (truncated & Self.sidLowMask)
            out.append(restored)
        }
        let now = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
        out.append(now)
        out.append(now &- 1)
        out.append(now &+ 1)
        var seen = Set<UInt32>()
        return out.filter { $0 != 0 && seen.insert($0).inserted }
    }

    /// Wait for the card to report the session ID (`0x14` / `0x17` / `0x18` any). Timeout **does not throw error** —
    /// The candidate ladder also has the "host clock" fallback, so it's unnecessary for the whole segment to fail just because it wasn't received.
    ///
    /// ⚠️ Here we read the **bypass** of `observeControlFrame` (it updates in real time on the `didUpdateValueFor`
    /// path, updates in real time, does not consume `inbox`), therefore during the wait **does not seize frames**.
    private func liveAwaitSessionID(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if liveFullSessionID != nil || liveTruncatedSID != nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func liveRecording(for file: LiveDeviceFile) throws -> RecorderRecording {
        guard let sid = file.sessionID else {
            throw RecorderLinkError.unsupported("live file has no sessionID")
        }
        return RecorderRecording(id: String(sid),
                                 displayTitle: file.name,
                                 sizeBytes: file.size,
                                 startedAt: nil,
                                 sessionID: sid,
                                 raw: [:])
    }

    /// The filename for real-time recording on the iOS side. Use sid instead of the name on the card:
    /// The TicNote entry on the card has no name at all (`0x1A` only provides sid + size + scenario),
    /// Whereas sid is **stable and unique**, using it as a key when "delete the card's copy after saving" will not cause errors.
    static func liveFileName(sessionID: UInt32?, fallback: String) -> String {
        guard let sessionID else { return fallback }
        return "\(sessionID).opus"
    }
}
