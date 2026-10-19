import Combine
import CoreBluetooth
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "ble.dingtalka1")

// ★ Voice-key linkage (2026-10-19) — DingTalk's Minutes page auto-attaches the app's live page when
// the card's own hardware key starts a recording; without this the user's "press and it
// transcribes" gesture did nothing unless they happened to be watching the live page.
extension Notification.Name {
    /// Fired **once per card-initiated recording** (the voice key, not an app-side
    /// `startRecording`). `object` is the `DingTalkA1Link`. App-initiated starts do *not*
    /// post this — otherwise the live page would try to start a session it itself began.
    static let recorderCardDidStartRecording = Notification.Name("nomily.recorderCardDidStartRecording")
    /// ★ (2026-10-19) Push-to-talk tail: the voice-key recording **ended on the card** (key
    /// released / stop event from the card, not our own `stopRecording`). The live page uses
    /// it to close the session exactly when the user lets go — "hold to record, release to stop" — and the
    /// saved clip then flows into the normal auto-transcribe → auto-summarize chain, which
    /// is what turns it into an AI voice memo.
    static let recorderCardDidStopRecording = Notification.Name("nomily.recorderCardDidStopRecording")
}

// MARK: - DingTalk A1 transport layer
//
// Same split as `TicNoteLink`: this file does the raw bytes (services, notify, write, frame
// reassembly, timeouts, command serialisation) and hands semantic results upward. Protocol
// constants live in `DingTalkA1Protocol.swift`, audio conversion in `DingTalkA1Audio.swift`.
//
// ## The four things that are easy to get wrong here
//
// 1. **Frames must be reassembled.** The A1 carries a `u32` length, and a 48 KB file block
//    spans tens of notifications at MTU 23. Reading "one notification = one frame" (the
//    TicNote shape) yields a truncated block and a file that never opens.
//
// 2. **`did` is the device id string, not the MAC.** `{"did":"1046161310"}` authenticates;
//    the MAC gets you `405`. Every command body needs it, so it is injected once from the
//    credential rather than repeated at six call sites.
//
// 3. **The token's AES key is ASCII of the secret's first 16 chars.** Not the hex bytes.
//    A wrong key is not "a bit off" — it is `501` forever.
//
// 4. **Without a credential we must not pretend.** The card is perfectly happy to be
//    discovered, and it answers `0x0008` to anyone. Every operation past that needs the
//    token, so the link fails fast with an explanation the UI can show, instead of hanging
//    on a timeout that reads as "the card is broken".

@MainActor
final class DingTalkA1Link: NSObject, ObservableObject, RecorderLink {

    static var protocolID: String { DingTalkA1Spec.identifier }

    let peripheral: CBPeripheral
    private weak var central: CBCentralManager?

    /// The credential this link authenticates with. `nil` = the card was found but never
    /// imported; the link still connects (so the UI can offer the import sheet) but every
    /// read fails with `.unsupported`.
    private(set) var credential: DingTalkA1Credential?

    /// The SN tail from the advertisement (e.g. `"0655"`), kept so `ensureAuthenticated` can
    /// **re-resolve** the credential after the user imports it mid-connection — the common
    /// path is "connect → see the error → import → tap retry" on this very link.
    private let identityHint: String?

    private var commandChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    @Published private(set) var negotiatedMTU: Int = 0
    @Published private(set) var transferProgress: Double = 0
    @Published private(set) var lastRecordings: [RecorderRecording] = []
    private(set) var disconnectError: Error?

    /// Latest status the card reported (either asked for, or pushed).
    private(set) var lastStatus: DingTalkA1Status?

    private var framer = DingTalkA1Framer()
    private let inbox = NotifyQueue()
    private var handshakeContinuation: CheckedContinuation<Void, Error>?
    private var notifyContinuation: CheckedContinuation<Void, Error>?

    /// Command lock: the card firmware accepts one in-flight command, so everything that
    /// writes goes through here (`listRecordings`, `fetchRecording`, keep-alive, auth).
    private var cmdBusy = false
    private var cmdWaiters: [CheckedContinuation<Void, Never>] = []

    /// Set once `0x0133` returned 200. Cleared on disconnect — a new connection needs a new
    /// challenge, since the previous `random` may be stale or already consumed.
    private var didAuthenticate = false

    /// Monotonic `seq` byte. The card echoes it on replies; we only use it to answer the
    /// card's own requests (`0x0114` / `0x0115`) with a matching number.
    private var sequence: UInt8 = 0x10

    private var keepAliveTask: Task<Void, Never>?
    private var lastActivityAt = Date()
    static let keepAliveIdleInterval: TimeInterval = 20
    static let keepAliveTickInterval: TimeInterval = 5

    // MARK: Live (real-time stream)

    /// Installed while a live session is active. Frames `0x0116`/`0x0117` are **routed here at
    /// push time** and never enter `inbox`: at 50 frames/s they would flood the queue and any
    /// concurrent `waitReply` would have to skip past thousands of them. This is also the only
    /// way the stream and a command can coexist — the inbox deliberately has one consumer.
    private var liveFrameSink: ((UInt16, Data, UInt8) -> Void)?
    private var liveSink: AsyncThrowingStream<Data, Error>.Continuation?
    private var liveTask: Task<Void, Never>?
    private var liveGeneration = 0
    private var liveStopping = false
    private var liveFirstFrameSeen = false
    /// Counts for the throttled diagnostics only — a systematic protocol mismatch must not
    /// write 50 log lines a second.
    private var liveMalformedFrames = 0
    private var strayStreamFrames = 0
    private var streamFramesLogged = 0

    /// Stream ACKs that could not go out because the link's transmit queue was full.
    ///
    /// ★ (2026-10-18) Why this exists. The card pushes `0x0117` at ~50 Hz and each frame must be
    ///   ACKed, so we were queueing ~50 `.withoutResponse` writes per second on top of the
    ///   notifications. `CBPeripheral.writeValue` **silently drops** writes once its queue is
    ///   full — the ACK never leaves, the card sees a gap, and the session ends with the link
    ///   reporting `CBErrorDomain Code=6 "The connection has timed out unexpectedly."`
    ///   (measured twice: ~13 s and ~18 s into a stream, both while frames were flowing).
    ///   Gating on `canSendWriteWithoutResponse` and draining from
    ///   `peripheralIsReady(toSendWriteWithoutResponse:)` is the only way to keep the ACK stream
    ///   honest without opening a second queue of our own.
    private var ackBacklog: [(cmd: DingTalkA1Cmd, seq: UInt8)] = []
    private static let ackBacklogLimit = 64
    /// Counters for the throttled diagnostics.
    private var acksDeferred = 0
    private var acksDropped = 0
    /// ★ (2026-10-19) ACK throttling — the fix for the ~30 s live-stream death spiral.
    ///
    /// Measured on device: 50 incoming frames/s each answered with its own ACK write saturated
    /// the iOS outgoing queue (`canSendWriteWithoutResponse` false for hundreds of frames in a
    /// row), the card's window filled, the stream went silent, the watchdog re-armed, and the
    /// link died with `CBErrorDomain Code=6` — every 30–60 s, for the whole session.
    ///
    /// The ACK is positional flow control, not a reliable stream: the card cares that the link
    /// keeps moving, not that every frame is individually answered. So we answer **one frame in
    /// `ackEveryN`** — ~12 writes/s instead of ~50 — and the deferred path below still answers
    /// the newest frame whenever the queue has spare room.
    private static let ackEveryN = 4
    private var acksSeen = 0

    /// Wall-clock of the last `0x0117` frame that parsed — the stall watchdog's clock.
    private var liveLastFrameAt = Date()
    /// How many times the watchdog re-armed `upload_stream` in this session.
    private var liveRearms = 0
    /// Silence that counts as "the card stopped pushing" (frames arrive every 20 ms).
    private static let liveStallSeconds: TimeInterval = 3
    /// Re-arms before giving up; each one restarts the card's push if it is still alive.
    private static let liveMaxRearms = 4
    /// The fid the card tags its live frames with — the file this session belongs to.
    private var liveFid: UInt32?
    /// Whether **this app** asked the card to record (vs. taking over a button-pressed one);
    /// decides whether `liveStop` also stops the recorder.
    private var startedRecordingThisSession = false

    // MARK: UT report (0x000C) state

    /// Latest decoded report — kept whole for diagnostics ("what did the card just say").
    private(set) var lastUtEvents: [DingTalkA1UtEvent] = []
    /// Marks pressed on the card during the current recording, in order.
    @Published private(set) var marks: [A1Mark] = []
    /// The card's own clock at the moment recording started (device domain). `nil` = not recording.
    private var cardRecordingStart: Date?
    /// When **we** sent `0x0100 start` (phone clock).
    ///
    /// Fallback for the case where the card never pushes its own `AUDIO_RECORD_START`: app-initiated
    /// recordings still need a zero point, otherwise every remark would be dropped
    /// (`guard let start` below) and the stopwatch would fall back to the coarse status value.
    /// Less exact than the device stamp — it includes the write latency — but strictly better than
    /// having no anchor at all.
    private var recordingRequestedAt: Date?
    /// `true` between a **card-initiated** start event and its stop — the window in which the
    /// stop event should tell the live page "the voice key let go". App-initiated sessions
    /// manage their own lifecycle and must not receive the echo.
    private var voiceKeySessionActive = false
    /// `phoneNow − cardNow`, learned from every report. Used to turn the card's timestamps into
    /// audio offsets without trusting that the two clocks agree.
    private var deviceClockOffset: TimeInterval?
    /// Recording state as reported by the card's event stream (more immediate than polling).
    private var eventRecordingState: Bool?
    /// `SYSTEM_CHARGING_CHANGED` — the only charging signal this card exposes (`0x0132` has none).
    ///
    /// ⚠️ (2026-10-19, real device) **Never observed.** Across every captured session the card
    /// emitted only: `0x01000002/3/6/7`, `0x03000002/4/6`, `0x0B000006`, AUDIO_* — no charging
    /// event, including while it was on the charger. So the UI's lightning bolt never appears.
    /// `probeBattery()` and the raw `0x000C` dump below exist to find the real signal.
    private(set) var chargingFromCard: Bool?
    private(set) var batteryFromCard: Int?
    /// One raw hex dump of a `0x000C` report per connection — shows record types our parser
    /// may be dropping (the only way to see what we don't know we're missing).
    private var dumpedRawUtThisSession = false

    /// How long one request may wait. `0x0133` on a cold card occasionally needs two seconds
    /// (it does an internal lookup); everything else answers in milliseconds.
    private static let commandTimeout: TimeInterval = 15

    /// Per-block wait during a transfer. 48 KB at the ~20 KB/s we measured between blocks is
    /// still under three seconds; 20 s tolerates a stalled connection interval without turning
    /// a hiccup into a failed download.
    private static let blockTimeout: TimeInterval = 20

    init(peripheral: CBPeripheral, central: CBCentralManager,
         credential: DingTalkA1Credential?, identityHint: String? = nil) {
        self.peripheral = peripheral
        self.central = central
        self.credential = credential
        self.identityHint = identityHint
        super.init()
        peripheral.delegate = self
    }

    var displayName: String {
        credential?.displayName ?? peripheral.name ?? DingTalkA1Spec.family
    }

    var isConnected: Bool {
        peripheral.state == .connected && commandChar != nil && notifyChar != nil
    }

    /// The `did` every request body must carry.
    private var did: String { credential?.deviceId ?? "" }

    // MARK: Handshake

    func completeHandshake() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.handshakeContinuation = cont
            peripheral.discoverServices([DingTalkA1GATT.service])
        }
        negotiatedMTU = peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
        log.info("handshake done mtu=\(self.negotiatedMTU, privacy: .public)")
        TicNoteDiagLog.log("A1", "GATT handshake done mtu=\(negotiatedMTU) name=\(displayName)")
    }

    func handleDisconnect(error: Error?) {
        TicNoteDiagLog.log("A1", "Disconnected error=\(String(describing: error))")
        stopKeepAlive()
        commandChar = nil
        notifyChar = nil
        framer.reset()
        didAuthenticate = false
        // The card's clock reference and "who is recording" are per-connection facts; carrying
        // them across a reconnect would make the timer count from the wrong moment.
        cardRecordingStart = nil
        recordingRequestedAt = nil
        deviceClockOffset = nil
        eventRecordingState = nil
        disconnectError = error
        inbox.failAll(with: error ?? RecorderLinkError.notConnected)
        // ★ (2026-10-18) A dead link must **end the stream explicitly**.
        //
        // Before this the continuation was simply left hanging: the card stopped pushing, no
        // frames arrived, and no error was delivered either — so the live page showed a frozen
        // timer with no text while the card happily kept recording. `LiveModel` now receives
        // `.linkLost` and can tell "link hiccup → wait for the reconnect and re-attach" apart
        // from "the device really stopped".
        ackBacklog.removeAll()
        if let sink = liveSink {
            TicNoteDiagLog.log("A1 LIVE", "link lost — failing the stream so the session can re-attach")
            liveSink = nil
            liveFrameSink = nil
            liveTask?.cancel()
            liveTask = nil
            sink.finish(throwing: RecorderLinkError.linkLost)
        }
        if let cont = handshakeContinuation {
            handshakeContinuation = nil
            cont.resume(throwing: error ?? RecorderLinkError.notConnected)
        }
        if let cont = notifyContinuation {
            notifyContinuation = nil
            cont.resume(throwing: error ?? RecorderLinkError.notConnected)
        }
    }

    // MARK: Command serialisation

    private func acquireCmdLock() async {
        if !cmdBusy {
            cmdBusy = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            cmdWaiters.append(cont)
        }
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

    // MARK: Write / read

    @discardableResult
    private func write(_ frame: Data, response: Bool = false, trace: Bool = true) throws -> Bool {
        guard isConnected, let ch = commandChar else { throw RecorderLinkError.notConnected }
        let withResponse = response && ch.properties.contains(.write)
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        let limit = peripheral.maximumWriteValueLength(for: type)
        guard frame.count <= limit else {
            // Never truncate: the card would read the remainder as a new command.
            TicNoteDiagLog.log("A1 !REJECT", "outbound \(frame.count) B > MTU payload \(limit) B")
            throw RecorderLinkError.malformed("outbound frame \(frame.count) B > MTU payload \(limit) B")
        }
        // ★ `trace: false` is for the 50 Hz stream ACK: hex-dumping those wrote ~1 KB/s into the
        //   512 KB diagnostic log and rolled it over every few minutes — losing the very history
        //   that explains why the stream died.
        if trace { TicNoteDiagLog.frame(withResponse ? "A1 → WR" : "A1 → WC", frame) }
        lastActivityAt = Date()
        peripheral.writeValue(frame, for: ch, type: type)
        return withResponse
    }

    /// ACK a pushed stream frame — the card stalls (and eventually drops the link) if these stop.
    ///
    /// Prefers a direct write and falls back to a small backlog drained by
    /// `peripheralIsReady(toSendWriteWithoutResponse:)`. The backlog is bounded: ACKs are
    /// positional, not a reliable stream, so replaying a stale window is worse than skipping it.
    private func acknowledgeStream(cmd: DingTalkA1Cmd, seq: UInt8) {
        guard isConnected, commandChar != nil else { return }
        // ★ Throttle: answer every Nth frame. Cutting the write rate is what keeps the iOS
        // outgoing queue below saturation; answering every frame is what killed the link.
        acksSeen += 1
        guard acksSeen % Self.ackEveryN == 0 else { return }
        guard peripheral.canSendWriteWithoutResponse else {
            ackBacklog.append((cmd, seq))
            if ackBacklog.count > Self.ackBacklogLimit {
                let overflow = ackBacklog.count - Self.ackBacklogLimit
                ackBacklog.removeFirst(overflow)
                acksDropped += overflow
            }
            acksDeferred += 1
            if acksDeferred % 200 == 1 {
                TicNoteDiagLog.log("A1 LIVE",
                    "ACK queue full — \(acksDeferred) deferred, \(acksDropped) dropped, backlog \(ackBacklog.count)")
            }
            return
        }
        try? write(DingTalkA1FrameCodec.frame(
            type: .response, cmd: cmd, seq: seq, json: ["code": 200]
        ), trace: false)
        drainAckBacklog()
    }

    private func drainAckBacklog() {
        guard isConnected, commandChar != nil else {
            ackBacklog.removeAll()
            return
        }
        while !ackBacklog.isEmpty, peripheral.canSendWriteWithoutResponse {
            let ack = ackBacklog.removeFirst()
            try? write(DingTalkA1FrameCodec.frame(
                type: .response, cmd: ack.cmd, seq: ack.seq, json: ["code": 200]
            ), trace: false)
        }
    }

    private func nextSeq() -> UInt8 {
        sequence &+= 1
        return sequence
    }

    /// Waits for the reply carrying `cmd`. Unrelated frames are dropped from the queue —
    /// the A1 has no request ids, so `cmd` is the only correlator available (same situation
    /// as TicNote, and the same solution: match by command code).
    private func waitReply(_ cmd: DingTalkA1Cmd,
                           timeout: TimeInterval = DingTalkA1Link.commandTimeout) async throws -> (seq: UInt8, payload: Data) {
        try await waitReplyRaw(cmd.rawValue, timeout: timeout)
    }

    /// Same as `waitReply(_:timeout:)` but keyed by the raw command number — needed by probes
    /// for commands that aren't part of the normal flow (and may not exist on this firmware).
    private func waitReplyRaw(_ rawCmd: UInt16,
                              timeout: TimeInterval = DingTalkA1Link.commandTimeout) async throws -> (seq: UInt8, payload: Data) {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw RecorderLinkError.timeout }
            let data: Data
            do {
                data = try await inbox.pop(timeout: remaining)
            } catch {
                throw RecorderLinkError.timeout
            }
            guard let decoded = DingTalkA1FrameCodec.decodeWithSequence(data) else {
                TicNoteDiagLog.log("A1 ?", "unparsable inbound \(data.count) B")
                continue
            }
            if decoded.frame.cmd == rawCmd {
                return (decoded.seq, decoded.frame.payload)
            }
            // A push event (`0x14`) may arrive at any time; keep it, it is how we learn about
            // battery/recording changes without polling.
            if decoded.frame.type == DingTalkA1PacketType.event.rawValue {
                noteEvent(decoded.frame.payload)
            } else {
                TicNoteDiagLog.log(
                    "A1 <", "unexpected cmd 0x\(String(decoded.frame.cmd, radix: 16))"
                        + " while waiting for 0x\(String(rawCmd, radix: 16))"
                )
            }
        }
    }

    private func noteEvent(_ payload: Data) {
        if let status = DingTalkA1Status.parse(payload) {
            lastStatus = status
        }
    }

    // MARK: UT report — the card's own event log (`0x000C`)
    //
    // Handled **at push time**, not inside `waitReply`: the card emits reports while idle
    // (connect snapshot, charging, key presses), and a report nobody is waiting for would
    // otherwise sit in `inbox` until the next command — which is exactly how "pressing the
    // button did nothing" would happen.

    private func handleUtReport(_ payload: Data) {
        // ★ (2026-10-19) One hex dump per connection, before parsing: if the card carries a
        // record type we don't decode (charging being the one we're looking for), this is the
        // only trace of it. Bounded so a chatty card can't flood the 512 KB ring buffer.
        if !dumpedRawUtThisSession {
            dumpedRawUtThisSession = true
            let head = payload.prefix(600).map { String(format: "%02X", $0) }.joined()
            TicNoteDiagLog.log("A1 UT RAW", "\(payload.count) B: \(head)")
        }
        let events = DingTalkA1UtReport.parse(payload)
        guard !events.isEmpty else {
            TicNoteDiagLog.log("A1 UT", "0x000C not parseable (\(payload.count) B)")
            return
        }
        lastUtEvents = events
        for event in events { applyUtEvent(event) }
        // The report is emitted at the moment of its newest record, so the arrival time minus
        // that record's device time is the clock offset. Batching only delays *delivery*, never
        // the timestamps themselves — offsets computed from device times stay exact.
        if let newest = events.max(by: { $0.timestamp < $1.timestamp }) {
            deviceClockOffset = Date().timeIntervalSince(newest.timestamp)
        }
        for event in events {
            TicNoteDiagLog.log("A1 UT", "\(event.name) @\(Int(event.timestamp.timeIntervalSince1970)) v=\(event.value)")
        }
    }

    private func applyUtEvent(_ event: DingTalkA1UtEvent) {
        switch event.id {
        case DingTalkA1EventID.chargingChanged, DingTalkA1EventID.outputChargingChanged:
            // Value is 1/0 in every sample; anything non-zero means "now charging".
            chargingFromCard = event.value != 0

        case DingTalkA1EventID.battery:
            if event.value > 0, event.value <= 100 { batteryFromCard = Int(event.value) }

        case DingTalkA1EventID.remarkButtonClick:
            // Only meaningful while a recording is running — a press at idle is the AI key's
            // own gesture, not a mark on an audio timeline.
            let offset: TimeInterval
            if let start = cardRecordingStart {
                // Card clock both sides ⇒ exact, even when the report is delivered in a later batch.
                offset = event.timestamp.timeIntervalSince(start)
            } else if let requested = recordingRequestedAt {
                // No start event from the card (app-initiated, or it never pushed one): fall back to
                // our own request time, mapped into the card's clock so the two sides are comparable.
                // `deviceClockOffset = phoneNow − cardNow`, so `cardTime = phoneTime − offset`.
                let requestedInCardClock = requested.timeIntervalSince1970 - (deviceClockOffset ?? 0)
                offset = event.timestamp.timeIntervalSince1970 - requestedInCardClock
            } else {
                return
            }
            let mark = A1Mark(offset: max(0, offset), at: Date())
            marks.append(mark)
            if let fid = lastStatus?.lastFileID ?? liveFid {
                A1MarkStore.add(mark, toFile: fid)
            }
            TicNoteDiagLog.log("A1 MARK", "＋ \(String(format: "%.0f", mark.offset))s")

        default:
            if DingTalkA1EventID.startsRecording(event.id) {
                // Card-initiated = neither we nor a previous start event asked for it. Must be
                // sampled *before* we assign `cardRecordingStart` below.
                let cardInitiated = cardRecordingStart == nil && recordingRequestedAt == nil
                if cardRecordingStart == nil {
                    cardRecordingStart = event.timestamp
                    marks.removeAll()
                }
                eventRecordingState = true
                // ★ Voice-key linkage: tell the UI layer. `start()` in LiveModel re-guards
                //   (`isRunning` / `isStarting`), so a redundant post is harmless.
                if cardInitiated {
                    voiceKeySessionActive = true
                    NotificationCenter.default.post(name: .recorderCardDidStartRecording, object: self)
                }
            } else if DingTalkA1EventID.stopsRecording(event.id) {
                cardRecordingStart = nil
                recordingRequestedAt = nil
                eventRecordingState = false
                // ★ Push-to-talk tail (2026-10-19): "hold to record, release to stop" — the voice key's
                //   release ends the live session, and the saved clip runs through the normal
                //   auto-transcribe → auto-summarize chain (the AI voice memo). Only for
                //   card-initiated sessions: our own `stopRecording` already controls the page.
                if voiceKeySessionActive {
                    voiceKeySessionActive = false
                    NotificationCenter.default.post(name: .recorderCardDidStopRecording, object: self)
                }
            }
        }
    }

    /// Recording length **from the card's own clock**, independent of our command timing.
    /// `nil` until a start event has been seen (or after it stopped).
    var cardElapsed: TimeInterval? {
        if let start = cardRecordingStart, let offset = deviceClockOffset {
            let cardNow = Date().timeIntervalSince1970 - offset
            return max(0, cardNow - start.timeIntervalSince1970)
        }
        // No start event from the card: fall back to when we asked it to record, but only while the
        // card actually says it is recording — otherwise a stale request time would keep a dead
        // stopwatch running.
        if let requested = recordingRequestedAt, eventRecordingState == true {
            return max(0, Date().timeIntervalSince(requested))
        }
        return nil
    }

    // `RecorderLink` requirements — see their doc comments for why each must be a requirement.
    var pushedElapsed: TimeInterval? { cardElapsed }

    var pushedRemarkCount: Int? {
        // Only meaningful mid-recording: a stale count from a finished run would make the UI claim
        // "3 marks so far" while nothing is recording.
        let recording = cardRecordingStart != nil
            || (recordingRequestedAt != nil && eventRecordingState == true)
        return recording ? marks.count : nil
    }

    // MARK: Authentication

    /// Runs the `0x0008` → token → `0x0133` dance once per connection.
    ///
    /// Idempotent: a second call while authenticated is a no-op, so callers can simply put it
    /// at the top of every operation without thinking about ordering.
    private func ensureAuthenticated() async throws {
        // ★ Re-resolve on **every** attempt, not only when we have nothing yet.
        //
        // Two flows write the store while a link is already alive:
        //   · "connect first → see the error → scan the key → tap retry" (the common one), and
        //   · "replace key" after a second-hand card was re-bound — the secret genuinely
        //     **changes** for the same hardware, so a cached old one can only ever answer `501`.
        //
        // The old `if credential == nil` guard covered only the first case; the second failed
        // until the user disconnected by hand, which reads as "the new key didn't work".
        //
        // Deleting a key while connected still leaves this session authenticated (`didAuthenticate`
        // is already true) — that is deliberate: the card keeps working until it disconnects, and
        // tearing down a live connection because the user tidied a row would be worse.
        if let hint = identityHint, !hint.isEmpty,
           let fresh = DingTalkA1CredentialStore.credential(matchingTail: hint) {
            credential = fresh
        } else if credential == nil {
            credential = DingTalkA1CredentialStore.single
        }
        guard let credential, credential.isValid else {
            throw RecorderLinkError.unsupported(L10n.A1.errorNoCredential)
        }
        guard isConnected else { throw RecorderLinkError.notConnected }
        if didAuthenticate { return }

        // 0x0008 — the only command that answers without a credential.
        let challengeSeq = nextSeq()
        try write(DingTalkA1FrameCodec.frame(
            cmd: .getRandom,
            seq: challengeSeq,
            json: ["did": credential.deviceId, "corp_id": credential.corpId]
        ))
        let randomPayload = try await waitReply(.getRandom).payload
        guard let object = try? JSONSerialization.jsonObject(with: randomPayload) as? [String: Any],
              let challenge = object["random"] as? String
        else {
            throw RecorderLinkError.malformed("0x0008 reply has no random")
        }

        guard let token = DingTalkA1Auth.token(secret: credential.secret, challenge: challenge) else {
            // Deliberately not "fall back to something": a placeholder key authenticates
            // nowhere and hides the real problem.
            throw RecorderLinkError.unsupported(L10n.A1.errorBadSecret)
        }

        let connectSeq = nextSeq()
        try write(DingTalkA1FrameCodec.frame(
            cmd: .connectDevice,
            seq: connectSeq,
            json: [
                "did": credential.deviceId,
                "model": credential.model,
                "sdk_ver": credential.sdkVersion,
                "corp_id": credential.corpId,
                "token": token,
                "timestamp": String(Int(Date().timeIntervalSince1970)),
            ]
        ))
        let reply = try await waitReply(.connectDevice).payload
        let code = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])
            .flatMap { $0?["code"] as? Int } ?? -1

        switch code {
        case 200:
            didAuthenticate = true
            TicNoteDiagLog.log("A1 AUTH", "✅ code=200 (did=\(credential.deviceId))")
            // ★ (2026-10-19) `startKeepAlive()` had **no call site at all** — the heartbeat was
            //   dead code. Measured consequence: after an automatic reconnect the link sat idle
            //   (no auth, no commands) and the card dropped it exactly 30 s later
            //   (`CBErrorDomain Code=7`), over and over — the "it keeps disconnecting" churn.
            //   The tick only fires when nothing else has happened for 20 s, so it costs one
            //   `0x0132` per idle interval and never competes with an active session.
            startKeepAlive()
            // ★ (2026-10-19) One-shot parameter probe. Fire-and-forget: the auth handler must
            //   not block on it, and the Task acquiring `runExclusive` just waits for *this*
            //   exclusive op to unwind — no deadlock. The reply lands verbatim in the diag log;
            //   from it we dig out the record-mode key (if the card exposes one at all).
            Task { [weak self] in await self?.dumpAllParams() }
            // Charging has no signal at all right now (`0x0132` has no field, the card never
            // posts `0x0100000C`) — ask the two candidate battery commands and log the replies.
            Task { [weak self] in await self?.probeBattery() }
        case 405:
            throw RecorderLinkError.unsupported(L10n.A1.errorNotAuthenticated)
        case 501:
            // The one failure that means "wrong card's credential", not "wrong code".
            throw RecorderLinkError.unsupported(L10n.A1.errorRejected)
        default:
            throw RecorderLinkError.malformed("0x0133 returned code \(code)")
        }
    }

    // MARK: RecorderLink — record control

    /// `0x0100 {"did", "action":"start", "params":[]}` — the card's own recorder.
    ///
    /// Command number and fields come from the official client's decompiled `sendAudioRecordOpt`
    /// (upstream notes §7.3); the exact JSON was never captured verbatim, so after sending we
    /// **verify through `0x0132`** that `audio_status` actually flipped — a `code:200` on a
    /// mis-shaped body would otherwise read as success and leave the user "recording" into air.
    func startRecording() async throws {
        try await runExclusive {
            try await self.ensureAuthenticated()
            self.inbox.drain()
            // Stamp the request **before writing**: that is the earliest the recording could possibly
            // have begun, so it is the right zero point if the card never reports its own start.
            self.recordingRequestedAt = Date()
            // Each run starts with a clean slate; the start-event branch also does this, but that
            // branch never runs if the card doesn't push one.
            self.marks.removeAll()
            try self.write(DingTalkA1FrameCodec.frame(
                cmd: .audioRecordOpt,
                seq: self.nextSeq(),
                json: ["did": self.did, "action": "start", "params": []]
            ))
            let reply = try await self.waitReply(.audioRecordOpt).payload
            try Self.requireOK(reply, command: "0x0100 start")

            // The status word is the only truth. Poll briefly: the card needs a moment to
            // spin the recorder up, and `0x0132` also refreshes the fid we'll need later.
            for _ in 0..<6 {
                try await Task.sleep(nanoseconds: 400_000_000)
                if let status = try? await self.queryStatusLocked(),
                   status.isRecording == true {
                    TicNoteDiagLog.log("A1 REC", "✅ card is recording (fid=\(status.lastFileID.map(String.init) ?? "—"))")
                    return
                }
            }
            throw RecorderLinkError.timeout
        }
    }

    func stopRecording() async throws {
        try await runExclusive {
            try await self.ensureAuthenticated()
            self.inbox.drain()
            try self.write(DingTalkA1FrameCodec.frame(
                cmd: .audioRecordOpt,
                seq: self.nextSeq(),
                json: ["did": self.did, "action": "stop", "params": []]
            ))
            let reply = try await self.waitReply(.audioRecordOpt).payload
            try Self.requireOK(reply, command: "0x0100 stop")
            // Recording is over — drop the fallback zero point so a later stray remark isn't
            // attributed to this run.
            self.recordingRequestedAt = nil
            // Best-effort settle: give the card a moment to close the file so the next
            // index read sees it.
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
    }

    /// `0x0113 {"did", "fid"}` — delete one recording **on the card**.
    func deleteRecording(_ recording: RecorderRecording) async throws {
        guard let fid = recording.sessionID else {
            throw RecorderLinkError.unsupported("recording has no fid")
        }
        try await runExclusive {
            try await self.ensureAuthenticated()
            self.inbox.drain()
            try self.write(DingTalkA1FrameCodec.frame(
                cmd: .fileDelete,
                seq: self.nextSeq(),
                json: ["did": self.did, "fid": String(fid)]
            ))
            let reply = try await self.waitReply(.fileDelete).payload
            try Self.requireOK(reply, command: "0x0113")
        }
    }

    /// Drop a mark **from the app side** (the card's own button is the other source).
    ///
    /// The offset is measured from the same zero the card's own marks use — `cardRecordingStart`
    /// (the card's clock) when we have it, otherwise `recordingRequestedAt` (the moment we asked
    /// the card to start). Both are "seconds since this recording began", which is exactly what
    /// the detail page's mark dots plot.
    ///
    /// Returns false when there is no recording in progress to mark, so the UI can hide or
    /// ignore the button instead of writing a mark that points at nothing.
    @discardableResult
    func addMarkNow() -> Bool {
        guard let fid = liveFid ?? lastStatus?.lastFileID else { return false }
        let zero = cardRecordingStart ?? recordingRequestedAt ?? Date()
        let offset = Date().timeIntervalSince(zero)
        guard offset >= 0 else { return false }
        A1MarkStore.add(A1Mark(offset: offset, at: Date()), toFile: fid)
        marks.append(A1Mark(offset: offset, at: Date()))
        return true
    }

    /// `0x0132` while already holding the command lock.
    private func queryStatusLocked() async throws -> DingTalkA1Status {
        try self.write(DingTalkA1FrameCodec.frame(
            cmd: .deviceStatus, seq: self.nextSeq(), json: ["did": self.did]
        ))
        let payload = try await self.waitReply(.deviceStatus).payload
        guard let status = DingTalkA1Status.parse(payload) else {
            throw RecorderLinkError.malformed("0x0132 reply could not be parsed")
        }
        self.lastStatus = status
        return status
    }

    /// Every JSON reply carries `code`; anything but 200 is a failure the user should see
    /// verbatim (400 = our body was wrong, 405 = session, 501 = credential).
    /// The `code` field of a JSON reply (`-1` when the body isn't JSON at all).
    private static func replyCode(_ payload: Data) -> Int {
        (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])
            .flatMap { $0?["code"] as? Int } ?? -1
    }

    /// `code` → a *speaking* error instead of "malformed reply".
    ///
    /// `405` and `501` are the two answers the card gives when the session isn't (or is no
    /// longer) authenticated, and they mean completely different things to the user:
    /// `405` = this session lost its token (a new challenge fixes it), `501` = the credential
    /// itself belongs to another card. Collapsing both into "returned code 405" is how the
    /// live stream used to fail with a message that pointed at the protocol instead of the fix.
    private static func requireOK(_ payload: Data, command: String) throws {
        let code = replyCode(payload)
        guard code == 200 else {
            switch code {
            case 405: throw RecorderLinkError.unsupported(L10n.A1.errorNotAuthenticated)
            case 501: throw RecorderLinkError.unsupported(L10n.A1.errorRejected)
            default: throw RecorderLinkError.malformed("\(command) returned code \(code)")
            }
        }
    }

    // MARK: Keep-alive

    func startKeepAlive() {
        guard keepAliveTask == nil, isConnected else { return }
        lastActivityAt = Date()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.keepAliveTickInterval * 1_000_000_000))
                if Task.isCancelled { return }
                guard let self else { return }
                await self.keepAliveTick()
            }
        }
    }

    func stopKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    /// `0x0132` is read-only and already the status query, so a heartbeat costs nothing extra
    /// and doubles as "battery is still current".
    private func keepAliveTick() async {
        guard isConnected, didAuthenticate else { return }
        guard Date().timeIntervalSince(lastActivityAt) >= Self.keepAliveIdleInterval else { return }
        _ = try? await runExclusive { () -> Bool in
            guard Date().timeIntervalSince(self.lastActivityAt) >= Self.keepAliveIdleInterval else {
                return false
            }
            try self.write(DingTalkA1FrameCodec.frame(
                cmd: .deviceStatus, seq: self.nextSeq(), json: ["did": self.did]
            ))
            if let payload = try? await self.waitReply(.deviceStatus, timeout: 8).payload,
               let status = DingTalkA1Status.parse(payload) {
                self.lastStatus = status
            }
            return true
        }
    }

    // MARK: RecorderLink — list

    func listRecordings() async throws -> [RecorderRecording] {
        try await runExclusive {
            try await self.ensureAuthenticated()
            self.inbox.drain()
            try self.write(DingTalkA1FrameCodec.frame(
                cmd: .fileIndex,
                seq: self.nextSeq(),
                json: ["did": self.did, "s_fid": "0", "recently": 100, "e_fid": "0"]
            ))
            let payload = try await self.waitReply(.fileIndex).payload
            let entries = DingTalkA1FileIndex.parse(payload)
            let recordings = entries.map { entry -> RecorderRecording in
                RecorderRecording(
                    id: String(entry.fid),
                    displayTitle: RecordingName.displayTitle(for: entry.startedAt),
                    // The index carries **no size** (flag/fid/status per record) — `0x0114`
                    // supplies the authoritative one during download. 0 renders as "size
                    // unknown" rather than a made-up number.
                    sizeBytes: 0,
                    startedAt: entry.startedAt,
                    sessionID: entry.fid,
                    raw: ["fid": AnyHashable(entry.fid)]
                )
            }
            self.lastRecordings = recordings
            TicNoteDiagLog.log("A1 LIST", "✅ \(recordings.count) recordings (payload \(payload.count) B)")
            return recordings
        }
    }

    // MARK: RecorderLink — fetch

    func fetchRecording(_ recording: RecorderRecording,
                        progress: (@MainActor (Double) -> Void)?) async throws -> Data {
        guard let fid = recording.sessionID else {
            throw RecorderLinkError.unsupported("recording has no fid")
        }
        // ★ 2026-10-18: the deadline used to be computed from `recording.sizeBytes`, which for
        // this card is **always 0** — `0x0110`'s index has no size field (see `listRecordings`).
        // `max(0, 1)` therefore produced a flat **60-second** ceiling for the whole file, so a
        // long recording died mid-transfer with `.timeout` after roughly a megabyte — which is
        // exactly the "it dropped, roughly 30% in" the user sees on a 15-minute clip.
        //
        // The authoritative size arrives in `0x0114` *after* the request is accepted, so the real
        // budget is set from it below; this first value only has to cover the handshake + first
        // block. When the card declines to describe the file, the deadline becomes a **rolling
        // idle deadline** (extended by each block) instead of a total one.
        var deadline = Date().addingTimeInterval(90)

        return try await runExclusive {
            try await self.ensureAuthenticated()
            self.inbox.drain()
            self.transferProgress = 0

            // 1) Ask for the file.
            try self.write(DingTalkA1FrameCodec.frame(
                cmd: .fetchFile,
                seq: self.nextSeq(),
                json: ["did": self.did, "fid": String(fid), "offset": 0, "progress": 65537]
            ))
            let acceptedPayload = try await self.waitReply(.fetchFile).payload
            let acceptedCode = (try? JSONSerialization.jsonObject(with: acceptedPayload) as? [String: Any])
                .flatMap { $0?["code"] as? Int } ?? -1
            // 202 = "already running", which is a success for our purposes.
            guard acceptedCode == 200 || acceptedCode == 202 else {
                throw RecorderLinkError.malformed("0x0111 rejected the download (code \(acceptedCode))")
            }

            // 2) Attributes: the authoritative size. May be JSON or raw bytes; either way it
            //    must be acknowledged or the card stops after this frame.
            var expectedSize = recording.sizeBytes
            let attributes = try await self.waitReply(.fileAttributes)
            if let size = Self.sizeFromAttributes(attributes.payload), size > 0 {
                expectedSize = size
            }
            try self.write(DingTalkA1FrameCodec.frame(
                type: .response, cmd: .fileAttributes, seq: attributes.seq,
                json: ["code": 200]
            ))
            TicNoteDiagLog.log(
                "A1 FETCH",
                "fid=\(fid) attributes \(attributes.payload.count) B, expected=\(expectedSize) B"
            )

            // 3) Blocks.
            var chunks: [UInt32: Data] = [:]
            var received = 0
            var shortBlockSeen = false
            let startedAt = Date()

            // Now that the real size is known, budget it at the slower of the two rates we have
            // measured (~20 KB/s typical, 5 KB/s worst case) plus a minute of slack. A ceiling,
            // not a wait: the loop ends on the short block or on `received == expectedSize`.
            if expectedSize > 0 {
                deadline = Date().addingTimeInterval(60 + Double(expectedSize) / 5_000)
            }

            do {
                while !shortBlockSeen {
                    guard Date() < deadline else {
                        TicNoteDiagLog.log(
                            "A1 FETCH",
                            "✗ deadline hit after \(received)/\(expectedSize) B in \(chunks.count) blocks"
                        )
                        throw RecorderLinkError.timeout
                    }
                    let (seq, payload) = try await self.waitReply(.fileBlock, timeout: Self.blockTimeout)
                    guard let block = DingTalkA1Block.parse(payload) else {
                        TicNoteDiagLog.log("A1 FETCH", "✗ malformed block (\(payload.count) B)")
                        throw RecorderLinkError.malformed("malformed file block (\(payload.count) B)")
                    }
                    if block.fid != fid {
                        throw RecorderLinkError.malformed("block fid \(block.fid) ≠ \(fid)")
                    }
                    chunks[block.number] = block.payload
                    received += block.payload.count
                    // Unknown size ⇒ treat the deadline as "no progress for 60 s" rather than a cap.
                    if expectedSize == 0 {
                        deadline = Date().addingTimeInterval(60)
                    }
                    try self.write(DingTalkA1FrameCodec.frame(
                        type: .response, cmd: .fileBlock, seq: seq, json: ["code": 200]
                    ))

                    let fraction = expectedSize > 0
                        ? min(1, Double(received) / Double(expectedSize))
                        : 0
                    self.transferProgress = fraction
                    progress?(fraction)

                    // The card closes the stream with a short block (measured 48 KB full blocks).
                    if block.payload.count < 48_000 { shortBlockSeen = true }
                    if expectedSize > 0, received >= expectedSize { break }
                }
            } catch {
                // ★ Interrupted mid-file (timeout, BLE drop, a stray frame we couldn't parse):
                // tell the card to stop pushing. Without this it keeps streaming 48 KB blocks
                // into a link nobody is reading, and the *next* command on this link receives
                // those blocks instead of its own reply — which looks like a second, unrelated
                // failure and is how one interrupted transfer poisons the following ones.
                try? self.write(DingTalkA1FrameCodec.frame(
                    cmd: .fileSyncCancel, seq: self.nextSeq(), json: ["did": self.did]
                ))
                self.inbox.drain()
                self.transferProgress = 0
                throw error
            }

            let ordered = chunks.keys.sorted().compactMap { chunks[$0] }
            let content = ordered.reduce(into: Data()) { $0.append($1) }
            guard !content.isEmpty else { throw RecorderLinkError.malformed("empty file") }
            if expectedSize > 0, content.count != expectedSize {
                // Fail closed: a short file that "looks fine" is how a recording silently
                // loses its last minutes.
                throw RecorderLinkError.corrupted(
                    "got \(content.count) B, card declared \(expectedSize) B"
                )
            }
            self.transferProgress = 1
            progress?(1)
            // Throughput is the number that decides whether a long recording is practical, and it
            // is the only way to tell an MTU-limited link (`maximumWriteValueLength` small) from a
            // card-limited one (48 KB block + ACK pacing). Log it every time; it costs one line.
            let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
            let payloadLimit = self.commandChar == nil
                ? 0
                : self.peripheral.maximumWriteValueLength(for: .withoutResponse)
            TicNoteDiagLog.log(
                "A1 FETCH",
                "✅ fid=\(fid) \(content.count) B in \(chunks.count) blocks, "
                + String(format: "%.1f KB/s (MTU payload %d B)",
                         Double(content.count) / elapsed / 1024, payloadLimit)
            )
            return content
        }
    }

    /// `0x0114`'s body: JSON when the card has attributes to describe, raw otherwise.
    /// Only the size matters to us; everything else is display material we don't have a
    /// confirmed layout for.
    private static func sizeFromAttributes(_ payload: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) else { return nil }
        func find(_ any: Any) -> Int? {
            if let dict = any as? [String: Any] {
                for key in ["size", "file_size", "fileSize", "total_size", "totalSize"] {
                    if let v = dict[key] as? Int { return v }
                    if let s = dict[key] as? String, let v = Int(s) { return v }
                }
                for value in dict.values {
                    if let hit = find(value) { return hit }
                }
            } else if let list = any as? [Any] {
                for value in list {
                    if let hit = find(value) { return hit }
                }
            }
            return nil
        }
        return find(object)
    }

    // MARK: RecorderLink — containerize

    func containerize(_ raw: Data, for recording: RecorderRecording) throws -> RecorderClip {
        let serial = recording.sessionID ?? 0xA1D1_A1D1
        let result = try DingTalkA1Audio.convert(raw, serial: serial)
        return RecorderClip(
            data: result.ogg,
            // `.opus` for the same reason TicNote uses it: the whole downstream pipeline
            // (library whitelist, duration probe, playback, ASR transcoding) dispatches on
            // this suffix. `.ogg` is not in the whitelist and the file would simply not
            // appear in the library.
            fileExtension: "opus",
            duration: result.duration,
            formatNote: result.formatNote
        )
    }

    // MARK: RecorderLink — the rest

    /// The A1 has no time-sync command in its table. Best-effort callers (`connectRecorder`
    /// does `try?`) simply skip it, and recordings still get correct timestamps because the
    /// fid **is** the start time.
    func syncTime(to date: Date) async throws {
        throw RecorderLinkError.unsupported("DingTalk A1 has no time-sync command")
    }

    /// Deleting is `0x0113` — implemented above with the other record controls.
    /// (It really does delete on the card: no soft-delete, no recycle bin.)

    func readDeviceInfo() async throws -> RecorderDeviceInfo {
        try await runExclusive {
            try await self.ensureAuthenticated()
            self.inbox.drain()
            try self.write(DingTalkA1FrameCodec.frame(
                cmd: .deviceStatus, seq: self.nextSeq(), json: ["did": self.did]
            ))
            let payload = try await self.waitReply(.deviceStatus).payload
            guard let status = DingTalkA1Status.parse(payload) else {
                throw RecorderLinkError.malformed("0x0132 reply could not be parsed")
            }
            self.lastStatus = status
            let storage: RecorderStorageInfo? = {
                guard let total = status.storageTotalBytes,
                      let free = status.storageFreeBytes else { return nil }
                // ⚠️ The card reports **megabytes**, not bytes. Cross-check: this card answers
                // `storage_total_size = 59646`; the same 58 GB flash on the TicNote sibling
                // reports `61071872 KB` for the identical hardware — 61071872 KB = 59641 MB.
                // Reading the field as bytes would render "58 KB" on a 64 GB card.
                let mega: Int64 = 1_048_576
                return RecorderStorageInfo(totalBytes: total * mega, freeBytes: free * mega)
            }()
            return RecorderDeviceInfo(
                batteryPercent: status.batteryPercent,
                isCharging: nil,     // the status reply has no charging bit we can verify
                storage: storage,
                rawReplies: [DingTalkA1Cmd.deviceStatus.rawValue: payload],
                notes: status.firmware.map { ["Firmware \($0)"] } ?? []
            )
        }
    }

    func readRecordingStatus() async throws -> RecorderRecordingStatus {
        // No answer must not throw: the caller polls at 1 Hz and needs "the card said nothing"
        // as a normal outcome (see the protocol's semantics).
        do {
            let info = try await readDeviceInfo()
            let status = lastStatus
            return RecorderRecordingStatus(
                isRecording: eventRecordingState ?? status?.isRecording,
                totalBytes: nil,        // the A1 reports duration, not a written byte count
                // ★ The card's clock wins over its own integer `duration`: the event's
                // timestamp is the same source, but anchored at the **actual** start moment
                // instead of "the second the poll happened to land on".
                deviceElapsed: cardElapsed ?? status?.durationMilliseconds.map { TimeInterval($0) / 1000 },
                sawSessionNotice: false,
                rawReplies: info.rawReplies
            )
        } catch let error as RecorderLinkError {
            if case .notConnected = error { throw error }
            return .unknown
        } catch {
            return .unknown
        }
    }

    /// ★ Recording state comes from the **event log** first (`AUDIO_RECORD_START/STOP`), which
    /// the card emits the moment the button is pressed — a poll can lag up to a second, and the
    /// user reads that lag as "the app doesn't know I stopped".
    var pushedRecordingState: Bool? { eventRecordingState ?? lastStatus?.isRecording }
    var pushedBatteryPercent: Int? { batteryFromCard ?? lastStatus?.batteryPercent }
    /// ★ Charging comes from `SYSTEM_CHARGING_CHANGED`, **never** from `0x0132` (which has no
    /// such field). `nil` until the card has actually said something — never a made-up `false`.
    var pushedChargingState: Bool? { chargingFromCard }
    /// No session id concept beyond the fid in `0x0132`, which is the *last* recording, not
    /// "the one we just started". Returning it would make auto-transfer grab the wrong file.
    var lastSessionID: UInt32? { nil }
}

// MARK: - CBPeripheralDelegate

extension DingTalkA1Link: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                self.finishHandshake(throwing: error)
                return
            }
            guard let service = peripheral.services?.first(where: {
                $0.uuid.uuidString.uppercased().contains("FE3C")
            }) else {
                self.finishHandshake(throwing: RecorderLinkError.malformed("service FE3C not found"))
                return
            }
            peripheral.discoverCharacteristics(
                [DingTalkA1GATT.commandCharacteristic, DingTalkA1GATT.notifyCharacteristic],
                for: service
            )
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                self.finishHandshake(throwing: error)
                return
            }
            for characteristic in service.characteristics ?? [] {
                let uuid = characteristic.uuid.uuidString.uppercased()
                if uuid.contains("FE1C") { self.commandChar = characteristic }
                if uuid.contains("FE1B") { self.notifyChar = characteristic }
            }
            guard let notify = self.notifyChar else {
                self.finishHandshake(throwing: RecorderLinkError.malformed("notify characteristic FE1B missing"))
                return
            }
            guard self.commandChar != nil else {
                self.finishHandshake(throwing: RecorderLinkError.malformed("write characteristic FE1C missing"))
                return
            }
            self.notifyContinuation = nil
            peripheral.setNotifyValue(true, for: notify)
            // The notification is enabled by the ATT layer asynchronously; on this card the
            // first usable read is ≥ 100 ms later anyway, and every operation re-arms its own
            // timeout, so we complete the handshake here instead of waiting for a callback
            // that some iOS versions skip when the characteristic was already notifying.
            self.finishHandshake(throwing: nil)
        }
    }

    /// The transmit queue drained — push the ACKs that were held back.
    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in self.drainAckBacklog() }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        Task { @MainActor in
            self.lastActivityAt = Date()
            for frame in self.framer.append(data) {
                guard let decoded = DingTalkA1FrameCodec.decodeWithSequence(frame) else {
                    TicNoteDiagLog.frame("A1 ← ?", frame)
                    continue
                }
                // ★ Stream frames are **not** hex-dumped (2026-10-18). At 50 frames/s that was
                //   ~6 KB of hex per second, which rotated the 512 KB diagnostic log every two
                //   minutes — destroying exactly the history needed to debug the session. Count
                //   them, print one line per 500.
                let isStreamFrame = decoded.frame.cmd == DingTalkA1Cmd.streamData.rawValue
                    || decoded.frame.cmd == DingTalkA1Cmd.streamAttributes.rawValue
                if isStreamFrame {
                    self.streamFramesLogged += 1
                    if self.streamFramesLogged % 500 == 1 {
                        TicNoteDiagLog.log("A1 LIVE", "stream frames: \(self.streamFramesLogged) (hex logging suppressed)")
                    }
                } else {
                    TicNoteDiagLog.frame("A1 ←", frame)
                }
                // The card's own event log — parsed immediately so marks/charging/timer work
                // even when no command is in flight.
                if decoded.frame.type == DingTalkA1PacketType.event.rawValue,
                   decoded.frame.cmd == 0x000C {
                    self.handleUtReport(decoded.frame.payload)
                    continue
                }
                // Real-time stream frames bypass the inbox while a live session is running —
                // they are ACKed and forwarded straight to the ASR pipeline.
                //
                // ★ Frames arriving with **no sink** (a stream that outlived its session, or one
                //   the card opened on its own) used to fall through into `inbox`. At 50 frames/s
                //   that buried every command reply: `0x0132` got lost behind thousands of
                //   `0x0117`s, so stop/pause appeared to do nothing while the card kept
                //   recording. Now they are ACKed and dropped — the card must not stall, but the
                //   command channel stays clean.
                if isStreamFrame {
                    if let sink = self.liveFrameSink {
                        sink(decoded.frame.cmd, frame, decoded.seq)
                    } else if let ackCmd = DingTalkA1Cmd(rawValue: decoded.frame.cmd) {
                        self.acknowledgeStream(cmd: ackCmd, seq: decoded.seq)
                        self.strayStreamFrames += 1
                    }
                    continue
                }
                self.inbox.push(frame)
            }
        }
    }

    private func finishHandshake(throwing error: Error?) {
        guard let cont = handshakeContinuation else { return }
        handshakeContinuation = nil
        if let error {
            cont.resume(throwing: error)
        } else {
            cont.resume()
        }
    }
}

// MARK: - LiveAudioSource (real-time transcription from the card)
//
// ## How the A1 streams live audio
//
// Unlike TicNote (pull: poll the growing file) and D·NOTE (start stream at record time), the
// A1 has a dedicated **push** channel: send `0x0100 {"action":"set","params":[{"key":
// "upload_stream","val":1}]}` once and the card starts pushing `0x0117` frames (≈50/s, each a
// whole 84-byte Opus packet) until told to stop. The stream is independent of the recorder, so
// "live" and "recording" compose in both directions:
//
// * `liveStartNew`  = open the stream **and** start the recorder → transcribe while recording;
// * `liveAttach`    = open the stream only → transcribe a button-pressed recording, or just listen.
//
// Every push must be ACKed (`0x31`, same seq, `{"code":200}`) — same rule as the file pushes;
// an unACKed stream stalls.
extension DingTalkA1Link: LiveAudioSource {

    var opusProfile: OpusOgg.Profile { .dingTalkA1 }

    /// The live stream is plaintext Opus (`0x0117` is never encrypted — upstream notes §7.5).
    var liveClipKey: Data? { nil }

    var isAvailable: Bool { isConnected }

    var liveLastSessionKey: String? {
        lastStatus?.lastFileID.map(String.init) ?? liveFid.map(String.init)
    }

    func liveIsRecording() async -> Bool? {
        guard let status = try? await readRecordingStatus() else {
            return pushedRecordingState
        }
        return status.isRecording
    }

    /// The card's own `duration` from `0x0132` (milliseconds), in seconds.
    ///
    /// This is the number the card shows on its screen and the number DingTalk's Minutes page
    /// displays, so the app's clock must be anchored to it rather than to the packets we happen
    /// to have received. A single small read per poll — no effect on the stream.
    func liveDeviceElapsed() async -> TimeInterval? {
        guard isConnected else { return cachedElapsed }
        guard let status = try? await readRecordingStatus() else { return cachedElapsed }
        return status.deviceElapsed ?? cachedElapsed
    }

    /// The last value the card reported, in seconds. `nil` (not `0`) before it has ever said
    /// anything — returning zero would reset a clock that is running.
    private var cachedElapsed: TimeInterval? {
        lastStatus?.durationMilliseconds.map { TimeInterval($0) / 1000 }
    }

    func liveListFiles() async -> [LiveDeviceFile]? {
        guard let list = try? await listRecordings() else { return nil }
        return list.map {
            LiveDeviceFile(name: $0.id, size: $0.sizeBytes, sessionID: $0.sessionID)
        }
    }

    func liveStartNew() async throws {
        liveFid = nil
        startedRecordingThisSession = false
        // Stream first, then record: if the order were reversed there'd be a window where the
        // recorder is running but the stream isn't, and the first seconds of audio would never
        // reach the ASR.
        try await setUploadStream(true)
        startedRecordingThisSession = true
        try await startRecording()
    }

    func liveAttach() async throws {
        startedRecordingThisSession = false
        try await setUploadStream(true)
    }

    func liveAudio(firstFrameTimeout: TimeInterval) -> AsyncThrowingStream<Data, Error> {
        liveGeneration &+= 1
        let generation = liveGeneration
        liveStopping = false
        liveFirstFrameSeen = false
        liveMalformedFrames = 0
        strayStreamFrames = 0
        TicNoteDiagLog.log("A1 LIVE", "stream attached — waiting for first frame")

        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .unbounded) { c in
            cont = c
        }
        cont.onTermination = { [weak self] _ in
            // Consumer stopped — tear the routing down on the main actor. The generation check
            // keeps a stale termination from killing the *next* session (same shape as TicNote).
            Task { @MainActor in
                guard let self, self.liveGeneration == generation else { return }
                self.teardownLiveRouting()
            }
        }

        liveSink = cont
        liveFrameSink = { [weak self] cmd, frame, seq in
            self?.handleLivePush(cmd: cmd, frame: frame, seq: seq)
        }

        // ★ (2026-10-19) One watchdog, two jobs: first frame, then **stalls**.
        //
        // Measured on build 36/38 (three sessions, two cards of log): the card pushes ~500–650
        // frames and then simply stops, with the link still up — six seconds later iOS reports
        // `CBErrorDomain Code=6` and the session is over. The old watchdog only covered "never
        // started", so a mid-stream stop looked identical to "the device finished recording".
        // Re-sending `upload_stream=1` is idempotent and restarts the card's push; that is the
        // one lever the protocol gives us without touching firmware.
        liveLastFrameAt = Date()
        liveRearms = 0
        liveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(firstFrameTimeout)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                guard self.liveGeneration == generation, !self.liveStopping else { return }

                if !self.liveFirstFrameSeen {
                    guard Date() >= deadline else { continue }
                    TicNoteDiagLog.log(
                        "A1 LIVE",
                        "✗ no parsable stream frame within \(Int(firstFrameTimeout)) s "
                            + "(rejected \(self.liveMalformedFrames))"
                    )
                    self.teardownLiveRouting()
                    cont.finish(throwing: RecorderLinkError.timeout)
                    // ★ Ask the card to stop pushing. Leaving `upload_stream=1` on meant the card
                    //   kept blasting frames into a dead sink — they were unACKed, the link then
                    //   timed out ("CBErrorDomain Code=6"), and every later command hung behind
                    //   the resulting reconnect. Best effort, never awaited.
                    try? await self.setUploadStream(false)
                    return
                }

                let silent = Date().timeIntervalSince(self.liveLastFrameAt)
                guard silent >= Self.liveStallSeconds else { continue }
                self.liveRearms += 1
                if self.liveRearms > Self.liveMaxRearms {
                    TicNoteDiagLog.log(
                        "A1 LIVE",
                        "✗ stream stalled \(Int(silent)) s and \(self.liveRearms - 1) re-arm(s) did not help — ending"
                    )
                    self.teardownLiveRouting()
                    cont.finish(throwing: RecorderLinkError.timeout)
                    try? await self.setUploadStream(false)
                    return
                }
                TicNoteDiagLog.log(
                    "A1 LIVE",
                    "stream silent \(Int(silent)) s — re-arming upload_stream (attempt \(self.liveRearms))"
                )
                // Resets `liveLastFrameAt` inside, so a successful re-arm gets a full window
                // before the next attempt; a failed one (dead link) falls through to the next tick.
                try? await self.setUploadStream(true)
                self.liveLastFrameAt = Date()
            }
        }
        return stream
    }

    func liveStop() async -> LiveStopOutcome {
        let fid = liveFid ?? lastStatus?.lastFileID
        teardownLiveRouting()
        if startedRecordingThisSession {
            try? await stopRecording()
        }
        startedRecordingThisSession = false
        try? await setUploadStream(false)
        // The file lands on the card when the recorder stops; the fid is known from the
        // stream/status even though the size isn't (the index carries none).
        let file = fid.map { LiveDeviceFile(name: String($0), size: 0, sessionID: $0) }
        return LiveStopOutcome(file: file, deviceInitiated: false)
    }

    func liveFetch(file: LiveDeviceFile,
                   progress: @escaping @MainActor (Int, Int) -> Void) async throws -> Data {
        guard let fid = file.sessionID else {
            throw RecorderLinkError.unsupported("live file has no fid")
        }
        let recording = RecorderRecording(
            id: String(fid),
            displayTitle: RecordingName.displayTitle(for: Date(timeIntervalSince1970: TimeInterval(fid))),
            sizeBytes: file.size,
            startedAt: Date(timeIntervalSince1970: TimeInterval(fid)),
            sessionID: fid,
            raw: ["fid": AnyHashable(fid)]
        )
        let total = max(file.size, 1)
        let dtyj = try await fetchRecording(recording) { fraction in
            progress(Int(Double(total) * fraction), total)
        }
        // ★ The card's file is a **DTYJ container**; the caller (`LiveModel.repair`) hands the
        // returned bytes straight to `PostDownload`, which only speaks Ogg / raw Opus. Convert
        // here so "repair" repairs with something playable (same reason TicNote containerizes).
        let converted = try DingTalkA1Audio.convert(dtyj, serial: fid)
        return converted.ogg
    }

    func liveDelete(file: LiveDeviceFile) async throws {
        guard let fid = file.sessionID else {
            throw RecorderLinkError.unsupported("live file has no fid")
        }
        let recording = RecorderRecording(
            id: String(fid),
            displayTitle: fid.description,
            sizeBytes: file.size,
            startedAt: Date(timeIntervalSince1970: TimeInterval(fid)),
            sessionID: fid,
            raw: [:]
        )
        try await deleteRecording(recording)
    }

    /// Accumulated 84 B packets → Ogg-Opus. Same reason as TicNote: `PostDownload`'s fallback
    /// slices at 40 B, so raw packets would produce a broken file.
    func liveContainerize(_ raw: Data, name: String) throws -> Data {
        guard !raw.isEmpty else { throw RecorderLinkError.malformed("live audio is empty") }
        let ogg = OpusOgg.wrap(rawFrames: raw, serial: 0xA1D1_A100, profile: .dingTalkA1)
        guard !ogg.isEmpty else {
            throw RecorderLinkError.malformed("Ogg muxing failed (\(raw.count) B)")
        }
        return ogg
    }

    // MARK: Live internals

    /// ★ (2026-10-19) Read-only parameter dump: `0x0100 {"action":"get","params":[]}` once per
    /// connection, full reply into the diag log. Purpose: find the card's **record-mode param
    /// key** (DingTalk's five modes) — reversed captures so far only show `incognitomode` /
    /// `aikey_option` / `cap_*`, which is why `A1RecordMode` is app-side-only for now.
    ///
    /// First real-device reply (build 44):
    /// `{"code":200,"params":[{"key":"mode","val":0},{"key":"delete_after_upload","val":0},
    ///  {"key":"aes","val":0},{"key":"incognitomode","val":0},{"key":"aikey_option","val":1000}]}`
    /// — so the record mode is **`mode`**. Never send a guessed key with `set`; read first.
    @discardableResult
    func readParams(tag: String = "A1 PARAMS") async -> [String: Int]? {
        guard isConnected else { return nil }
        do {
            return try await runExclusive {
                try await self.ensureAuthenticated()
                self.inbox.drain()
                try self.write(DingTalkA1FrameCodec.frame(
                    cmd: .audioRecordOpt,
                    seq: self.nextSeq(),
                    json: ["did": self.did, "action": "get", "params": []]
                ))
                let reply = try await self.waitReply(.audioRecordOpt).payload
                let text = String(decoding: reply, as: UTF8.self)
                TicNoteDiagLog.log(tag, "0x0100 get → \(text)")
                guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
                      let params = object["params"] as? [[String: Any]]
                else { return nil }
                var table: [String: Int] = [:]
                for entry in params {
                    if let key = entry["key"] as? String, let val = entry["val"] as? Int {
                        table[key] = val
                    }
                }
                return table
            }
        } catch {
            // Probe only — a card that refuses `get` (or answers with an error code) is not a
            // failure of anything the user asked for. The log line above is the whole point.
            TicNoteDiagLog.log(tag, "0x0100 get unavailable: \(error)")
            return nil
        }
    }

    /// Thin alias kept for the auth hook's call site (`Task { await dumpAllParams() }`).
    func dumpAllParams() async { _ = await readParams() }

    /// Applies one of the five recording modes to the card.
    ///
    /// Body: `0x0100 {"did","action":"set","params":[{"key":"mode","val":n}]}` — the key comes
    /// from the real `0x0100 get` reply, not from a guess. The **value→mode ordering** follows
    /// DingTalk's own row order (0 = General … 4 = Lossless); the card's default is `mode=0`,
    /// which is consistent with General being first, but the mapping itself is unverified — so we
    /// read the table back and report what the card actually stored.
    /// - Returns: `true` only when the card answered `200` **and** the value read back matches.
    func setRecordMode(_ mode: A1RecordMode) async -> Bool {
        guard isConnected else { return false }
        let target = mode.cardValue
        do {
            let accepted = try await runExclusive { () -> Bool in
                try await self.ensureAuthenticated()
                self.inbox.drain()
                try self.write(DingTalkA1FrameCodec.frame(
                    cmd: .audioRecordOpt,
                    seq: self.nextSeq(),
                    json: ["did": self.did,
                           "action": "set",
                           "params": [["key": "mode", "val": target]]]
                ))
                let reply = try await self.waitReply(.audioRecordOpt).payload
                TicNoteDiagLog.log("A1 MODE",
                                   "set mode=\(target) → \(String(decoding: reply, as: UTF8.self))")
                try Self.requireOK(reply, command: "0x0100 mode=\(target)")
                return true
            }
            guard accepted else { return false }
        } catch {
            TicNoteDiagLog.log("A1 MODE", "set mode=\(target) failed: \(error)")
            return false
        }
        // Verify by reading the table back — "200 accepted" is not proof the value stuck.
        let table = await readParams(tag: "A1 MODE")
        let stored = table?["mode"]
        TicNoteDiagLog.log("A1 MODE", "read back mode=\(stored.map(String.init) ?? "nil") (wanted \(target))")
        return stored == target
    }

    /// ★ (2026-10-19) Charging probe. `0x0132` has **no** charging field and this firmware has
    /// never emitted `SYSTEM_CHARGING_CHANGED` (`0x0100000C`) in any captured session, so the
    /// app has no charging signal at all — which is exactly what the user reported ("plugged
    /// the charger in, the state didn't change"). Upstream notes list two candidate battery
    /// queries that may carry the flag; send both, log the raw replies, decide nothing yet.
    func probeBattery() async {
        guard isConnected else { return }
        do {
            try await runExclusive {
                try await self.ensureAuthenticated()
                for (cmd, body) in [
                    (DingTalkA1Cmd.batteryQuery, ["did": self.did, "key": "battery_key"]),
                    (DingTalkA1Cmd.batteryQuery, ["did": self.did]),
                    (DingTalkA1Cmd.batteryQueryAlt, ["did": self.did]),
                ] as [(DingTalkA1Cmd, [String: String])] {
                    // Short timeout per attempt: an unsupported command answers nothing, and a
                    // 15 s wait × 3 would hold the exclusive lock for 45 s — the card would look
                    // frozen (record button, list refresh) while a *diagnostic* is running.
                    self.inbox.drain()
                    do {
                        try self.write(DingTalkA1FrameCodec.frame(
                            cmd: cmd, seq: self.nextSeq(), json: body))
                        let reply = try await self.waitReplyRaw(cmd.rawValue, timeout: 3).payload
                        TicNoteDiagLog.log(
                            "A1 BATT",
                            "0x\(String(cmd.rawValue, radix: 16)) \(body) → "
                                + String(decoding: reply, as: UTF8.self))
                    } catch {
                        TicNoteDiagLog.log(
                            "A1 BATT",
                            "0x\(String(cmd.rawValue, radix: 16)) \(body) → no reply (\(error))")
                    }
                }
            }
        } catch {
            TicNoteDiagLog.log("A1 BATT", "probe unavailable: \(error)")
        }
    }


    private func setUploadStream(_ on: Bool) async throws {
        try await runExclusive {
            // ★ Two things were wrong here until 2026-10-18 (real-device error
            //   `Malformed reply from device: 0x0100 upload_stream=1 returned code 405`):
            //
            //   1. **The body carried no `did`.** Every authenticated command on this card
            //      must repeat the same `did` it authenticated with — `0x0132`, `0x0110`,
            //      `0x0100 start/stop` all do. The `set` shape below was copied from an
            //      upstream capture that happened to omit it; this firmware answers `405`
            //      (not authenticated) and the live stream never opened. It is only because the 405
            //      arrived *before* `startRecording()` that the user saw "recording doesn't
            //      work" rather than "no transcript".
            //   2. **A 405 was fatal.** `405` means this *session* lost its token, which a
            //      fresh `0x0008` → `0x0133` round repairs. Retrying once after clearing
            //      `didAuthenticate` recovers that case without the user reconnecting by hand.
            var didRetryAuth = false
            while true {
                try await self.ensureAuthenticated()
                self.inbox.drain()
                try self.write(DingTalkA1FrameCodec.frame(
                    cmd: .audioRecordOpt,
                    seq: self.nextSeq(),
                    json: ["did": self.did,
                           "action": "set",
                           "params": [["key": "upload_stream", "val": on ? 1 : 0]]]
                ))
                let reply = try await self.waitReply(.audioRecordOpt).payload
                if Self.replyCode(reply) == 405, !didRetryAuth {
                    didRetryAuth = true
                    TicNoteDiagLog.log("A1 LIVE", "upload_stream=\(on ? 1 : 0) → 405, re-authenticating once")
                    self.didAuthenticate = false
                    continue
                }
                try Self.requireOK(reply, command: "0x0100 upload_stream=\(on ? 1 : 0)")
                TicNoteDiagLog.log("A1 LIVE", "upload_stream=\(on ? 1 : 0) ok")
                return
            }
        }
    }

    /// Runs on the main actor for every pushed stream frame: ACK, then forward the packet.
    private func handleLivePush(cmd: UInt16, frame: Data, seq: UInt8) {
        guard let ackCmd = DingTalkA1Cmd(rawValue: cmd) else { return }
        // An unACKed push stalls the stream (same rule as the file transfers). This goes through
        // the readiness-gated helper: at 50 frames/s a plain `writeValue` silently overflows the
        // transmit queue and the link dies with `CBErrorDomain Code=6`.
        acknowledgeStream(cmd: ackCmd, seq: seq)
        guard cmd == DingTalkA1Cmd.streamData.rawValue else { return }
        // Count *any* `0x0117` as proof of life — a malformed frame still means the card is
        // pushing, and re-arming `upload_stream` against a live card would be noise.
        liveLastFrameAt = Date()
        guard let parsed = DingTalkA1LiveFrame.parse(frame) else {
            // Throttled: a systematic parse failure would otherwise write ~50 identical lines
            // per second and roll the diagnostic log over before anyone can read it.
            liveMalformedFrames += 1
            if liveMalformedFrames <= 3 || liveMalformedFrames % 200 == 0 {
                TicNoteDiagLog.log(
                    "A1 LIVE",
                    "✗ malformed stream frame (\(frame.count) B) — total \(liveMalformedFrames)"
                )
            }
            return
        }
        liveFid = parsed.fid
        liveFirstFrameSeen = true
        // A parsable frame arrived after a stalled stretch: reset the budget so an occasional
        // hiccup never accumulates into "gave up".
        liveRearms = 0
        for packet in parsed.packets {
            liveSink?.yield(packet)
        }
    }

    private func teardownLiveRouting() {
        liveStopping = true
        liveFrameSink = nil
        liveTask?.cancel()
        liveTask = nil
        liveSink?.finish()
        liveSink = nil
    }
}
