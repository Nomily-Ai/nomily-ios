import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "wifi.ticnote")

// MARK: - TicNote Wi-Fi fast-transfer transport layer
//
// ## Why this layer looks the way it does
// In round 7 we assumed "we connect to the card's 8081". **That is backwards** (see the top of `TicNoteWifiProtocol.swift` for the evidence):
// the phone is the WebSocket **server** and the card connects in. This direction determines the shape of this file:
//
//   · Can't use `URLSessionWebSocketTask` (it can only connect outward) → listen ourselves with `NWListener`;
//   · The handshake and framing must be written by hand → already moved down into `Sources/Services/Net/WebSocketFraming.swift`
//     (pure bytes, self-checkable on the command line, including the public RFC 6455 test vectors);
//   · The protocol state machine is also written by hand → already moved down into `TicNoteWifiSession.swift` (pure logic);
//   · **All that remains is glue**: start the listener / join the hotspot / make the card turn on Wi-Fi / the send-receive loop / timeouts / teardown.
//
// ## One complete fast transfer (order after round 15's real-device verification with the official App)
// ```
// 1. Start the listener (8081)                        ← must come first, otherwise nobody accepts when the card connects
// 2. BLE sends the binding frame + OPEN_WIFI (01 0A 00)   ← the binding frame is a precondition, see TicNoteLink.sendOpenWifi()
// 3. Compute hotspot credentials (not "wait for BLE to push them"!)         ← SSID = "TicNote-"+last 4 of SN; password = last 8 of SN
// 4. Wait for the card to bring up its hotspot, then join with NEHotspotConfiguration ← see joinHotspotAndAwaitCard()
// 5. Wait for the card to connect in + send SAY_HELLO (cmder 2)    ← the phone is the server, the card connects actively
// 6. State machine: handshake → request list → request file → receive chunks
// 7. Teardown: WIFI_CLOSE (cmder 4) + drop the hotspot + stop the listener
// ```
// Step 3 was once treated as "the only hard gap" —— because we assumed the card would report the password over BLE, yet the card stops BLE advertising
// entirely as soon as it opens its hotspot, which looked like a deadlock. **The on-device logcat of the official App in round 15 resolved it**:
// the official original `Received WIFI info: {ssid: TicNote-3N9H, passwd: Y36W3N9H}`, and this card's SN is
// `S02510YCY36W3N9H` —— both values are slices of the SN. **No frame capture needed.** See `protocol-notes.md` §18.

@MainActor
final class TicNoteWifiLink: RecorderFastTransfer {

    static var protocolID: String { TicNoteRecorderSpec.identifier }

    /// The official Dart passes exactly this port (`" Start opening WebSocket: port=8081, uuid="`),
    /// and the Java side's `WifiProtocol.WEB_SOCKET_PORT` also falls back to 8081.
    /// The constant itself lives in `TicNoteWifiEndpoint` (protocol layer), so the self-check can assert it directly.
    static var port: UInt16 { TicNoteWifiEndpoint.port }

    /// Idle timeout: if more than this long passes between two frames, the peer is considered dead.
    /// Basis for 8 s: the official `transmissionFrequency = 1500 ms` (heartbeat cadence),
    /// with a 5x margin. Too short would wrongly kill the link on Android's low-battery mode (where the official cadence is 4000 ms).
    private static let idleTimeout: TimeInterval = 8

    // MARK: Pacing of joining the hotspot (see `joinHotspotAndAwaitCard`)

    /// Between `OPEN_WIFI` being sent and the card actually bringing up the hotspot there is an **iOS-invisible gap**.
    /// Measured: the card drops BLE about 1.8 s later to start the AP (see the notes on `TicNoteLink.sendOpenWifi`),
    /// plus a little margin for the beacon to start up. This step was the direct cause of the earlier "cannot join" prompt; don't skip it.
    private static let postOpenWifiSettle: TimeInterval = 2.5

    /// How long to wait between one failed join and the next retry.
    /// Two seconds is enough for iOS to clean up the previous failed association, without missing the moment the hotspot comes up.
    private static let joinRetryDelay: TimeInterval = 2

    /// The **total** retry window for joining the hotspot.
    /// Basis for 45 s: on battery power the V05E path takes close to a minute at most to bring up a SoftAP
    /// (comment of `FastTransferSheet.pollAPReady`); TicNote is the same class of hardware, so the same order of magnitude.
    private static let joinWindow: TimeInterval = 45

    private weak var ble: TicNoteLink?
    private let credentials: TicNoteWifiCredentials
    private let config: TicNoteWifiSession.Config

    private let queue = DispatchQueue(label: "com.nomily.app.ios.wifi.ticnote", qos: .userInitiated)
    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = WebSocketFrameParser()
    private var handshakeDone = false

    /// Whether the listening port has really been bound.
    ///
    /// ★ Why it deserves its own flag: `NWListener`'s `start()` is **asynchronous**,
    /// and returning does not mean the port is usable. When the port is taken (the previous fast transfer was not cleaned up / another process holds 8081)
    /// the state is `.waiting`, the card's connection is **rejected outright**, and `newConnectionHandler`
    /// never fires —— the symptom is identical to "local network permission denied": both look like
    /// "joined the hotspot but the card never connected". Without this flag the two causes cannot be told apart.
    private var listenerReady = false

    private var session = TicNoteWifiSession()
    private var progressHandler: (@MainActor (Double) -> Void)?
    private var cancelRequested = false

    /// ★★★ The whole-batch session has already been established (listener + hotspot + WebSocket all alive).
    ///
    /// This flag is the **only switch** between "one cold start per item" and "one cold start per batch":
    /// * when `true`, `fastFetch` skips `startListener` / `sendOpenWifi` /
    ///   `joinHotspotAndAwaitCard`, and also does **not** `teardown` —— the session is left for the next item;
    /// * when `false`, everything works as before (single download, and the first item of a batch / reopening after the session dropped).
    private var batchOpen = false

    init(ble: TicNoteLink, credentials: TicNoteWifiCredentials,
         config: TicNoteWifiSession.Config = .init()) {
        self.ble = ble
        self.credentials = credentials
        self.config = config
        self.session = TicNoteWifiSession(config: config)
    }

    /// Constructed directly from the SN —— **this is the recommended entry point**.
    ///
    /// The credentials can all be computed locally (`TicNoteWifiCredentials.from(sn:)`), so the caller only needs to hold the SN,
    /// with no "wait for the card to report credentials" state machine at all. The SN is read from the advertised manufacturer data,
    /// and `BluetoothCoordinator` has already stuffed it into `TicNoteLink.serialNumber` when building the link.
    ///
    /// - Returns: `nil` = the SN is too short to compute the hotspot name/password. **No guessing**: see the notes on
    ///            `TicNoteWifiCredentials.hotspotSSID(fromSN:)`.
    convenience init?(ble: TicNoteLink, sn: String, config: TicNoteWifiSession.Config = .init()) {
        guard let credentials = TicNoteWifiCredentials.from(sn: sn) else { return nil }
        self.init(ble: ble, credentials: credentials, config: config)
    }

    // MARK: Public

    /// Fetch one recording over Wi-Fi and wrap it into a playable container.
    ///
    /// ## Every hop on this path is written to `Documents/ticnote-ble.log`
    /// Unlike the BLE path, the Wi-Fi side's `os.log` **cannot be retrieved** on a real device
    /// (`log stream --device-udid` is blocked by the sandbox, and `idevicesyslog` cannot get this App's
    /// os_log subsystem). So `TicNoteDiagLog` here is not "icing on the cake":
    /// without it, when this path fails the user and we can only see a paraphrased sentence,
    /// and the path spans so many steps — "send OPEN_WIFI → card drops BLE → brings up hotspot → iOS joins → card connects in
    /// → WebSocket upgrade → request list → request file" — that a break at any step
    /// looks like the same "cannot transfer".
    func fastFetch(_ recording: RecorderRecording,
                   progress: (@MainActor (Double) -> Void)?) async throws -> RecorderClip {
        try await fastFetch(recording, deleteAfter: false, progress: progress).clip
    }

    /// The variant that "deletes the copy on the card after fetching" (see `RecorderFastTransfer.fastFetch(_:deleteAfter:progress:)`).
    ///
    /// Deletion happens **"after the data is complete, before `teardown()`"** —— the only window in which `cmder 14`
    /// can be sent. A failed deletion / no receipt **never throws**: the file is already in hand, and failing to delete merely leaves an extra copy on the card,
    /// which must not turn a successful download into a failure. The result is handed to the caller as-is via `removedFromCard`.
    func fastFetch(_ recording: RecorderRecording,
                   deleteAfter: Bool,
                   progress: (@MainActor (Double) -> Void)?) async throws -> RecorderFastFetchResult {
        guard let sid = recording.sessionID else {
            throw RecorderLinkError.unsupported("recording has no sessionID")
        }
        // ★★★ In batch mode the session is already running (built by `beginBatch()`), and **BLE is deliberately disconnected** at this point
        //   —— the card is busy acting as a hotspot. So the "BLE must be connected" gate is guarded only on the **cold-start** path.
        //   The criterion is "connection and upgrade are both still there" rather than looking at `batchOpen` alone: card reboot, hotspot off,
        //   or the peer closing the socket all turn `batchOpen` into an empty claim
        //   (`teardown()` clears it, and it is checked again here to guard against "cleanup missed a step").
        let reuseSession = batchOpen && connection != nil && handshakeDone
        if !reuseSession {
            guard ble?.isConnected == true else {
                // The Wi-Fi path first has to wake the card over BLE, so BLE cannot be dropped first.
                throw RecorderLinkError.notConnected
            }
        }
        progressHandler = progress
        cancelRequested = false
        if reuseSession {
            // Clear the receive state of "this file" completely, **keeping** the handshake and the cached list.
            session.resetForNextFile()
        } else {
            session = TicNoteWifiSession(config: config)
        }
        TicNoteDiagLog.log("WIFI",
            "Fast transfer start sid=\(sid) target=\(recording.sizeBytes)B ssid=\(credentials.ssid)"
            + " list command=cmder \(config.useV2 ? TicNoteWifiCmder.getFileListV2 : TicNoteWifiCmder.getFileList)"
            + " (\(config.useV2 ? "V2" : "V1"))"
            + " params single=\(config.listSingle) start=\(config.listStart) uid=\(config.uid)"
            + " delete after transfer=\(deleteAfter ? "yes" : "no")"
            + (reuseSession ? " ｜ ★ reusing the batch session (**not** reconnecting the hotspot, **not** reopening the listener)" : ""))

        do {
            if !reuseSession {
                try startListener()
                try await ble?.sendOpenWifi()
                TicNoteDiagLog.log("WIFI", "OPEN_WIFI sent (the card drops BLE about 1.8 s later to bring up the hotspot)")
                try await joinHotspotAndAwaitCard()
            }
            // `drive` now also returns the matched entry —— deletion needs its sessionId,
            // which exists only in the Wi-Fi side's own list (the BLE list is the product of a different path).
            let entry = try await drive(sessionID: sid)
            let clip = try session.deliverable()
            TicNoteDiagLog.log("WIFI", "✅ Fast transfer complete \(clip.data.count)B container=\(clip.fileExtension)")
            // ★ Deletion must happen before teardown —— teardown closes the WebSocket,
            //   and `cmder 14` can only go over that connection (see `TicNoteWifiSession.planDelete`).
            var removed: Bool?
            if deleteAfter {
                removed = await requestDelete(entry: entry)
            }
            // ⚠️ In batch mode do **not** tear down the session —— the next item still needs it. `endBatch()` does the teardown once.
            if !reuseSession { await teardown() }
            return RecorderFastFetchResult(clip: clip, removedFromCard: removed)
        } catch {
            // A failure must carry `diagnosticSummary`: it lays out "how far the card actually got"
            // (phase + bytes received + how many times each cmder occurred). With only a bare error line,
            // we couldn't even tell whether the card connected in.
            TicNoteDiagLog.log("WIFI",
                "✗ Fast transfer failed \(String(describing: error)) ｜ listener ready=\(listenerReady) ｜ \(diagnosticSummary)")
            // ⚠️ In batch mode this failure does **not** necessarily mean the session is dead (most commonly it is this item's own
            //   30 s transfer timeout) —— rashly calling `teardown()` would ruin the dozens of remaining items too.
            //   Tear down only when "the peer connection is really gone": then keeping it is useless, and `beginBatch()`'s
            //   idempotent semantics will reopen it for the next item.
            if !reuseSession || connection == nil {
                await teardown()
            }
            throw error
        }
    }

    func cancel() {
        cancelRequested = true
        // ★ In batch mode **do not tear down the session here**: afterwards every remaining item would fail with `notConnected`
        //   immediately, the user would see a screenful of identical red text, unable to tell whether "I pressed stop myself"
        //   or "the card is broken". Let the in-flight item throw `.cancelled` itself
        //   (checked in `drive`'s polling), and leave the session to `endBatch()` to close uniformly.
        if !batchOpen { Task { await teardown() } }
    }

    // MARK: Batch session

    /// The **only** cold-start entry for a batch fast transfer: start listener → `OPEN_WIFI` → join hotspot → wait for the card to connect in
    /// → fetch the list once. Once this is done, each later item has only file commands left (`cmder 12 / 13` / `14`).
    ///
    /// ## Idempotent
    /// **Returns immediately** when the session is still alive —— the caller invokes it before every item, and this semantics gives
    /// "reuse if alive, self-heal if broken". So the criterion must include `connection != nil && handshakeDone`,
    /// not just `batchOpen`: after a card reboot / hotspot off / peer closing the socket, `batchOpen`
    /// becomes an empty claim, and only the connection itself is real proof.
    ///
    /// ## Why the "fetch list" is also pulled into this layer
    /// The list is **shared by the whole batch** (`drive` uses it to match up the sid, and deletion also needs its
    /// `sessionId`). Fetching it once during the cold start saves every item in between a "request list" round trip ——
    /// and that round trip is often the hop most likely to fail on a real device.
    func beginBatch() async throws {
        if batchOpen, connection != nil, handshakeDone, listener != nil {
            return
        }
        // Getting here has only two possibilities: the first item of the batch, or the previous item killed the session —— both restart from a clean state.
        // (`teardown()` closes the previous listener/connection/hotspot configuration together, and the `NWListener`
        //   port 8081 is released through it too; otherwise the new listener would sit in `.waiting`.)
        if batchOpen || listener != nil || connection != nil {
            TicNoteDiagLog.log("WIFI", "Batch session needs to be rebuilt (the previous session no longer exists)")
            await teardown()
        }
        guard ble?.isConnected == true else {
            throw RecorderLinkError.notConnected
        }
        cancelRequested = false
        session = TicNoteWifiSession(config: config)
        TicNoteDiagLog.log("WIFI",
            "★ Batch fast transfer: establishing **one** shared session ssid=\(credentials.ssid)"
            + " (start listener → OPEN_WIFI → join hotspot → wait for the card to connect in → fetch the list once)")

        do {
            try startListener()
            try await ble?.sendOpenWifi()
            TicNoteDiagLog.log("WIFI", "OPEN_WIFI sent (the card drops BLE about 1.8 s later to bring up the hotspot)")
            try await joinHotspotAndAwaitCard()
            try await awaitList()
        } catch {
            TicNoteDiagLog.log("WIFI",
                "✗ Batch session setup failed \(String(describing: error))"
                + " ｜ listener ready=\(listenerReady) ｜ \(diagnosticSummary)")
            await teardown()
            throw error
        }
        batchOpen = true
        TicNoteDiagLog.log("WIFI",
            "★★★ Batch session ready: the whole batch shares this one session, later items **no longer reconnect the hotspot**"
            + " (\(session.fileEntries.count) list entries cached)")
    }

    /// Batch teardown (success, failure and cancellation must all come through here).
    func endBatch() async {
        guard batchOpen || listener != nil || connection != nil else { return }
        TicNoteDiagLog.log("WIFI",
            "Batch fast transfer teardown: closing the session (WIFI_CLOSE + drop hotspot + stop listener) ｜ \(diagnosticSummary)")
        await teardown()
    }

    // MARK: Listening

    private func startListener() throws {
        guard let port = NWEndpoint.Port(rawValue: Self.port) else {
            throw RecorderLinkError.malformed("bad port \(Self.port)")
        }
        let tcp = NWProtocolTCP.Options()
        // Chunks are consecutive small packets; Nagle would batch them up, which shows as "progress stuttering".
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true

        let l = try NWListener(using: params, on: port)
        // ⚠️ The closure is `@Sendable`, while `Self.port` hangs off a `@MainActor` class
        //   ("main actor-isolated static property can not be referenced from a
        //   Sendable closure"). Take it into a local `UInt16` first, then enter the closure.
        let portNumber = Self.port
        // ★ Record **all** states, not just `.failed`.
        //
        // `.waiting` is the more common one on real devices: the port is held by a previous listener that wasn't cleaned up,
        // or local network permission was denied. Nothing visibly happens in the UI and the card's connection is rejected outright,
        // so the symptom degenerates into "joined the hotspot but the card never connects" —— indistinguishable from a permission problem.
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                TicNoteDiagLog.log("WIFI", "Listener \(portNumber) ready")
                Task { @MainActor in self?.listenerReady = true }
            case .waiting(let error):
                TicNoteDiagLog.log("WIFI",
                    "⚠️ Listener \(portNumber) stuck in waiting state: \(error.localizedDescription)"
                    + " (a taken port / denied local network permission both look like this)")
                log.error("listener waiting: \(String(describing: error), privacy: .public)")
            case .failed(let error):
                TicNoteDiagLog.log("WIFI", "✗ Listener \(portNumber) failed: \(error.localizedDescription)")
                log.error("listener failed: \(String(describing: error), privacy: .public)")
            case .cancelled:
                TicNoteDiagLog.log("WIFI", "Listener stopped")
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            TicNoteDiagLog.log("WIFI", "Incoming connection (assumed to be the card)")
            Task { @MainActor in self?.accept(conn) }
        }
        l.start(queue: queue)
        listener = l
        log.info("listening on \(Self.port, privacy: .public)")
    }

    private nonisolated func accept(_ conn: NWConnection) {
        Task { @MainActor in
            // Serve only the first incoming connection. The card connects only once;
            // accepting another would make two streams alternately overwrite the same file.
            guard self.connection == nil else {
                log.warning("second connection refused")
                conn.cancel()
                return
            }
            self.connection = conn
            self.parser = WebSocketFrameParser()
            self.handshakeDone = false
            // This callback **only logs** and doesn't touch `self` —— so there's no `[weak self]`
            // (which would leave an illusion of "seemingly needs self", and the compiler would also report never read),
            // and it doesn't form the cycle `self.connection → conn → handler → self`.
            conn.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .failed(let error):
                        log.error("connection failed: \(String(describing: error), privacy: .public)")
                    case .cancelled:
                        log.info("connection cancelled")
                    default:
                        break
                    }
                }
            }
            conn.start(queue: self.queue)
            self.receiveLoop(conn)
        }
    }

    /// Receive → split frames → decode `WifiDataVo` → feed the state machine → send the output frames back.
    private nonisolated func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            Task { @MainActor in
                if let data, !data.isEmpty {
                    do {
                        try self.ingestRaw(data)
                    } catch {
                        log.error("framing error: \(String(describing: error), privacy: .public)")
                        self.failInFlight(error)
                        return
                    }
                }
                if let error {
                    log.warning("receive error: \(String(describing: error), privacy: .public)")
                    self.failInFlight(error)
                    return
                }
                if isComplete {
                    log.info("peer closed")
                    return
                }
                self.receiveLoop(conn)
            }
        }
    }

    /// A chunk of bytes arrives: first treat it as an HTTP upgrade request, and once upgraded treat it as WebSocket frames.
    private func ingestRaw(_ data: Data) throws {
        var payload = data

        if !handshakeDone {
            if let result = try WebSocketHandshake.respond(to: data) {
                handshakeDone = true
                send(result.response, over: connection)
                log.info("websocket upgraded")
                TicNoteDiagLog.log("WIFI",
                    "WebSocket upgrade complete (handshake request \(data.count - result.remainder.count)B, "
                    + "first frame carried in the same packet \(result.remainder.count)B)")
                // ⚠️ The remaining bytes must not be dropped: the client may stuff the first frame and the handshake request into the same TCP segment.
                // The symptom of dropping it is "handshake succeeds but the card goes silent from then on", and because the heartbeats keep arriving normally afterwards,
                // it looks sporadic. Catch it explicitly here.
                payload = result.remainder
                if payload.isEmpty { return }
            } else {
                return          // request headers not fully received yet
            }
        }

        guard handshakeDone else { return }
        for message in try parser.feed(payload) {
            switch message {
            case .binary(let bytes):
                try handleBinary(bytes)
            case .text(let text):
                // TicNote sends binary; a text frame can only be debugging noise.
                log.warning("unexpected text frame \(text.count, privacy: .public) chars")
            case .ping(let p):
                send(WebSocketWriter.frame(.pong, payload: p), over: connection)
            case .close(let code, _):
                log.info("peer sent close code=\(code ?? 0, privacy: .public)")
                failInFlight(RecorderLinkError.notConnected)
            case .pong:
                break
            }
        }
    }

    private func handleBinary(_ bytes: Data) throws {
        let frame = try TicNoteWifiFrame.decode(bytes)
        // ★ Apart from content chunks, **every frame is written to disk as-is**.
        //
        // Why this is worth writing: the Wi-Fi side still has shapes never measured (download reply, chunk reply,
        // delete reply...). The list shape was settled on 2026-10-12 —— **the body is in bin,
        // 10-byte little-endian records** (see `TicNoteWifiFileEntry`), but the other frames may still
        // hold surprises. So the first time it runs on a real device, this line is the only answer:
        // what the card actually replied, and what the error frame actually says.
        //
        // ⚠️ Content chunks (cmder 13) are **not recorded** —— a 10 MB recording has thousands of chunks,
        //    which would flush all the other lines away (the whole log rolls once `maxBytes` is full).
        //    Heartbeats (cmder 3) are not recorded one by one either: they come every 1.5 s with identical content,
        //    and "is the card alive at all" is answered directly by the `cmder[3×N]` on the teardown line.
        if frame.cmder != TicNoteWifiCmder.fileSyncContent,
           frame.cmder != TicNoteWifiCmder.heartbeat {
            let json = frame.json ?? "(no json)"
            let shown = json.count > 600 ? String(json.prefix(600)) + "… (truncated)" : json
            TicNoteDiagLog.log("WIFI",
                "← cmder=\(frame.cmder) json=\(shown) bin=\(frame.bin?.count ?? 0)B")
        } else if frame.cmder == TicNoteWifiCmder.heartbeat {
            // ★ Added 2026-10-12: heartbeats are **no longer completely silent**.
            //
            // Why it is worth recording: otherwise the log shows only our own PONG (`→ cmder=3`),
            // which looks like "we sent 11 cmder=3 requests in a row and the card answered none" ——
            // someone really did misread it that way during troubleshooting (those 11 were all heartbeat PONGs).
            // The card pushes a PING every 2.5 s, so only the 1st and every 20th are recorded,
            // which proves "the link is alive" without flushing the log away.
            let n = session.cmderCounts[TicNoteWifiCmder.heartbeat] ?? 0
            if n == 1 || n % 20 == 0 {
                TicNoteDiagLog.log("WIFI",
                    "← cmder=3 (the card's heartbeat PING #\(n) —— link alive; "
                    + "the `→ cmder=3` lines below are our PONGs, not list retries)")
            }
        }
        let outbound = session.ingest(frame)
        for out in outbound {
            TicNoteDiagLog.log("WIFI", "→ cmder=\(out.cmder) json=\(out.json ?? "(no json)")")
            send(WebSocketWriter.frame(.binary, payload: out.encoded()), over: connection)
        }
        progressHandler?(session.progress)
    }

    private func send(_ bytes: Data, over conn: NWConnection?) {
        guard let conn else { return }
        conn.send(content: bytes, completion: .contentProcessed { error in
            if let error {
                log.warning("send failed: \(String(describing: error), privacy: .public)")
            }
        })
    }

    // MARK: Join the hotspot

    /// Wait for the card to bring up the hotspot → join → confirm the card really connected in.
    ///
    /// ## Why we can't "join immediately after sending OPEN_WIFI"
    /// `NEHotspotConfigurationManager.apply` is **one-shot**: if that SSID can't be scanned at that moment,
    /// it returns `Unable to join the network` right away, **and doesn't keep looking by itself**.
    /// And from the card receiving `01 0a 00` to the hotspot actually beaconing there are several seconds
    /// (measured: BLE drops first at ~1.8 s, and starting the AP takes even longer). So "join right after sending the command" is bound to fail ——
    /// what the user sees is the system's "Unable to join TicNote-XXXX".
    ///
    /// The V05E path stepped into the same pit long ago; the original words in `FastTransferSheet`:
    /// *"without an explicit wait the iOS NEHotspotConfigurationManager join often
    /// fails with 'Unable to join the network'"*, which it solves with `wifiap=1` polling + a fixed 3 s wait.
    ///
    /// ## Why its polling can't be copied here
    /// The card **drops BLE** as soon as it opens the hotspot, leaving no status bit to read (see `TicNoteLink.sendOpenWifi`).
    /// The only way is timed retries: spread the "waiting" over several attempts instead of betting on one.
    ///
    /// ## Why "join succeeded" still needs a second confirmation
    /// iOS sometimes reports a successful join while the phone is actually still on its original network (V05E uses a TCP connection to verify this).
    /// No separate TCP is needed here —— the card connects actively to our listening port, and that is the **real** criterion.
    /// So every round runs through (a) join → (b) wait for the card to connect in, and if either step fails, clear the configuration and start over.
    private func joinHotspotAndAwaitCard() async throws {
        // First let the card drop BLE and bring up the AP's beacon. Skipping this step was the cause of this error.
        try await settle(Self.postOpenWifiSettle)
        TicNoteDiagLog.log("WIFI",
            "Start joining hotspot \(credentials.ssid) (window \(Int(Self.joinWindow))s, retry every "
            + "\(Int(Self.joinRetryDelay))s after each failure)")

        let deadline = Date().addingTimeInterval(Self.joinWindow)
        var attempt = 0
        var lastError: Error = RecorderLinkError.timeout

        while Date() < deadline {
            if cancelRequested { throw RecorderLinkError.cancelled }
            attempt += 1

            // (a) Join the hotspot. On failure start over —— the hotspot has most likely just not come up yet.
            do {
                try await HotspotJoiner.apply(ssid: credentials.ssid, psk: credentials.passphrase)
            } catch let error as HotspotError {
                // The user tapped cancel in the system dialog. This is not a "bad timing" case; popping it up again would only annoy, so rethrow directly.
                if case .userDenied = error { throw error }
                lastError = error
                TicNoteDiagLog.log("WIFI", "Join attempt \(attempt) failed: \(error.localizedDescription)")
                log.warning("hotspot join attempt \(attempt) failed: \(String(describing: error), privacy: .public)")
                try await settle(Self.joinRetryDelay)
                continue
            } catch {
                lastError = error
                TicNoteDiagLog.log("WIFI", "Join attempt \(attempt) failed (not a HotspotError): \(String(describing: error))")
                log.warning("hotspot join attempt \(attempt) failed: \(String(describing: error), privacy: .public)")
                try await settle(Self.joinRetryDelay)
                continue
            }
            TicNoteDiagLog.log("WIFI", "Attempt \(attempt): iOS reported 'joined' (still need to wait for the card to connect before it counts)")

            // (b) Joined ≠ connected. The criterion is "did the card connect to our listening port".
            do {
                try await awaitConnection()
                TicNoteDiagLog.log("WIFI", "✅ Card connected to the listening port and completed the upgrade (join attempt \(attempt))")
                log.info("card reached the listener after \(attempt) join attempt(s)")
                return
            } catch RecorderLinkError.cancelled {
                throw RecorderLinkError.cancelled
            } catch {
                lastError = error
                // This is where **local network permission** is most suspect: iOS reports "joined",
                // but the TCP connection the card makes is blocked by the system, and `newConnectionHandler` never fires.
                TicNoteDiagLog.log("WIFI",
                    "After join attempt \(attempt) the card never connected in (listener ready=\(listenerReady)) —— rejoining")
                log.warning("joined but the card never reached the listener (attempt \(attempt)) — re-joining")
                // Clear the association left by this round, and rejoin from a clean state next round.
                HotspotJoiner.remove(ssid: credentials.ssid)
                try await settle(Self.joinRetryDelay)
            }
        }

        TicNoteDiagLog.log("WIFI",
            "✗ Giving up joining the hotspot: tried \(attempt) times, ssid=\(credentials.ssid), last error=\(String(describing: lastError))")
        log.error("hotspot join gave up after \(attempt) attempt(s), ssid=\(self.credentials.ssid, privacy: .public)")
        throw lastError
    }

    /// A cancellable timed wait.
    ///
    /// Swallows `Task.sleep`'s `CancellationError` with `try?` and re-checks `cancelRequested`
    /// itself before returning: every wait in the retry loop is a landing point for "task cancelled",
    /// and letting `Task.sleep` throw directly would skip half of `fastFetch`'s teardown (`teardown`).
    private func settle(_ seconds: TimeInterval) async throws {
        if cancelRequested { throw RecorderLinkError.cancelled }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if cancelRequested { throw RecorderLinkError.cancelled }
    }

    // MARK: Waiting and advancing

    /// Wait for the card to connect in (and complete the WebSocket upgrade).
    private func awaitConnection() async throws {
        let deadline = Date().addingTimeInterval(20)
        while connection == nil || !handshakeDone {
            if cancelRequested { throw RecorderLinkError.cancelled }
            if Date() > deadline {
                throw RecorderLinkError.timeout
            }
            try await Task.sleep(nanoseconds: 100_000_000)   // 0.1 s
        }
    }

    /// Wait until the state machine has received the whole target file. **Returns the matched entry** —— deletion (`cmder 14`) needs its
    /// `sessionId`, which exists only in the Wi-Fi side's own list (the BLE list is the product of a different path).
    @discardableResult
    private func drive(sessionID: UInt32) async throws -> TicNoteWifiFileEntry {
        // 1) Wait for the list. In batch mode the list was already fetched in `beginBatch()` and cached on `session`,
        //    so this step is **zero-cost** on that path (the `while` condition is false on the spot).
        try await awaitList()

        // 2) Find the same recording in the Wi-Fi side's list.
        //    Match by sessionId first. If there is no match, **fail explicitly** rather than "take the first one and make do" ——
        //    a wrong pick would be saved looking completely normal, and the user would never know the download was wrong.
        guard let entry = session.fileEntries.first(where: { $0.sessionId == sessionID }) else {
            // List every sid we got —— when the user reports "cannot transfer", this line can immediately answer
            // "is the card's sid different from what we thought, or did the list never come back at all".
            let got = session.fileEntries.map { String($0.sessionId) }.joined(separator: ",")
            TicNoteDiagLog.log("WIFI",
                "✗ No sid=\(sessionID) in the Wi-Fi list; sids in the list = [\(got)]")
            throw RecorderLinkError.unsupported(
                "session \(sessionID) is not in the card's Wi-Fi file list "
                + "(\(session.fileEntries.count) entries)"
            )
        }

        // 3) Start the download and wait until it is complete
        guard let first = session.beginDownload(entry) else {
            throw RecorderLinkError.malformed("cannot plan the Wi-Fi download")
        }
        send(WebSocketWriter.frame(.binary, payload: first.encoded()), over: connection)
        TicNoteDiagLog.log("WIFI",
            "Download request sent sid=\(entry.sessionId) size=\(entry.sizeBytes)B"
            + " fileType=\(entry.fileType ?? 0) timeout budget=\(Int(transferTimeout(bytes: Int(entry.sizeBytes))))s"
            + " request body=\(first.json ?? "(no json)")")

        let transferDeadline = Date().addingTimeInterval(transferTimeout(bytes: Int(entry.sizeBytes)))
        while !session.phase.isTerminal {
            if cancelRequested { throw RecorderLinkError.cancelled }
            if Date() > transferDeadline {
                throw RecorderLinkError.malformed(
                    "transfer stalled at \(session.receivedBytes)/\(session.expectedBytes) B"
                    + Self.universalErrorSuffix(session))
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if case .failed(let why) = session.phase {
            throw RecorderLinkError.malformed(why)
        }
        TicNoteDiagLog.log("WIFI",
            "Chunks complete \(session.receivedBytes)/\(session.expectedBytes) B ｜ cmder[\(cmderSummary)]")
        progressHandler?(1)
        return entry
    }

    /// Compress `cmderCounts` into one line. The first time it runs on a real device, **this line is all the evidence for "which numbers the card actually sent"** ——
    /// no need to guess the flow right before getting the log.
    private var cmderSummary: String {
        session.cmderCounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
    }

    /// Wait for "the list to arrive".
    ///
    /// Extracted from `drive`, because batch mode must call it once when **establishing the session** ——
    /// the list is shared by the whole batch (`drive` uses it to match sid, and deletion uses it to get `sessionId`),
    /// fetching once is enough, and each item in between needn't make another round trip.
    ///
    /// Idempotent: returns on the spot when the phase is already `.listed` / `.finished` (the previous item just finished).
    private func awaitList() async throws {
        let deadline = Date().addingTimeInterval(awaitingListTimeout)
        while session.phase == .awaitingHello || session.phase == .listing {
            if cancelRequested { throw RecorderLinkError.cancelled }
            if Date() > deadline { throw Self.listingTimeout(session) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if case .failed(let why) = session.phase {
            throw RecorderLinkError.malformed("wifi listing failed: \(why)")
        }
        TicNoteDiagLog.log("WIFI",
            "Wi-Fi list arrived: \(session.fileEntries.count) entries ｜ cmder[\(cmderSummary)]")
    }

    /// Error for a list timeout. If the card sent a `universalError` in the meantime, include its original text ——
    /// last round that original was dropped, leaving only a hopeless "device reported a universal error".
    private static func listingTimeout(_ session: TicNoteWifiSession) -> RecorderLinkError {
        .malformed("the card never sent its Wi-Fi file list"
            + universalErrorSuffix(session))
    }

    /// Join the original text of the card's error frame into a log/error suffix that can be appended.
    private static func universalErrorSuffix(_ session: TicNoteWifiSession) -> String {
        guard let ue = session.lastUniversalError else { return "" }
        return " — card said (×\(session.universalErrorCount)): \(ue)"
    }

    /// List timeout. More generous than the BLE path's 8 s: the Wi-Fi side has an extra DHCP + TCP connection step.
    private var awaitingListTimeout: TimeInterval { 30 }

    /// Transfer timeout. **Computed by size**, and Wi-Fi's budget is much more generous than BLE's:
    /// the official heartbeat cadence is 1.5 s, but the data is pushed as one whole, which hasn't been measured (not yet measured).
    /// Here we estimate conservatively at 200 KB/s (20x BLE's 8.8 KB/s, still very conservative) + 30 s margin.
    private func transferTimeout(bytes: Int) -> TimeInterval {
        30 + Double(bytes) / 200_000
    }

    // MARK: Teardown

    /// While the Wi-Fi session is still up, delete this item on the card (`cmder 14`).
    ///
    /// Returns "whether deletion was **confirmed**". The semantics are deliberately tightened, because **three outcomes map to three follow-up actions**:
    ///
    /// | Outcome | Meaning | What the caller should do |
    /// |---|---|---|
    /// | `true` | The card replied `{"session":N,"status":0}` | Report "deleted from the card" |
    /// | `false` and the status is **explicit rejection** | The card replied `{"cmd":14,"code":M}` or `status != 0` | May show a failure |
    /// | `false` and the status is **timeout** | No receipt at all within 3 s | **Do not retry deletion over another channel** |
    ///
    /// The reason for the last row was bought by this round's real-device forensics: the card has most likely **already deleted it and just did not answer**,
    /// and the only fallback channel (BLE `0x1E`) cut the entire BLE connection 1.3 s after sending, in the log
    /// of 2026-10-12 11:23:48. So when "uncertain", better to do nothing.
    private func requestDelete(entry: TicNoteWifiFileEntry) async -> Bool {
        guard connection != nil else {
            TicNoteDiagLog.log("WIFI",
                "⚠️ Wanted to delete sid=\(entry.sessionId), but the Wi-Fi connection is already closed —— skipping (not falling back to BLE)")
            return false
        }
        let frame = session.planDelete(entry)
        send(WebSocketWriter.frame(.binary, payload: frame.encoded()), over: connection)
        TicNoteDiagLog.log("WIFI",
            "Delete request sent sid=\(entry.sessionId) request body=\(frame.json ?? "(no json)")")

        let deadline = Date().addingTimeInterval(Self.deleteTimeout)
        while session.deleteAcknowledged == nil, !cancelRequested, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        guard let ack = session.deleteAcknowledged else {
            TicNoteDiagLog.log("WIFI",
                "⚠️ No receipt for the delete request within \(Int(Self.deleteTimeout))s sid=\(entry.sessionId)"
                + " —— the card may have deleted it but not answered, **not retrying**"
                + Self.universalErrorSuffix(session))
            return false
        }
        TicNoteDiagLog.log("WIFI",
            ack ? "✅ Card confirmed deletion sid=\(entry.sessionId)"
                : "✗ Card explicitly rejected deletion sid=\(entry.sessionId)"
                  + Self.universalErrorSuffix(session))
        return ack
    }

    /// Budget for waiting on the delete receipt. Shortness is deliberate: deletion is a **teardown action**; if it drags on, what the user waits for is the sense of an ending to
    /// "transfer complete", and failing to delete does not affect the file already being on the phone.
    private static let deleteTimeout: TimeInterval = 3

    /// Teardown has three things, **none of which may be skipped**:
    ///   1. Send `WIFI_CLOSE` —— if not sent, the card's hotspot stays on and drains power;
    ///   2. Drop the hotspot configuration —— if not dropped, the phone stays attached to the card's hotspot that has no internet;
    ///   3. Stop the listener and disconnect —— leaving it makes the next fast transfer be judged a "second connection" and rejected.
    private func teardown() async {
        progressHandler = nil
        // Teardown also leaves one line: on real devices we have seen "transfer finished but the phone is still attached to the card's no-internet hotspot",
        // and failing any of the three things here looks exactly like that.
        TicNoteDiagLog.log("WIFI",
            "Teardown: connection=\(connection == nil ? "no" : "yes") listener=\(listener == nil ? "no" : "yes") ｜ \(diagnosticSummary)")
        if connection != nil {
            send(WebSocketWriter.frame(.binary, payload: session.farewell().encoded()), over: connection)
            // Give the peer a moment to read out the close, then cancel.
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        handshakeDone = false
        listenerReady = false
        HotspotJoiner.remove(ssid: credentials.ssid)
        // ★ Session gone → the batch switch drops with it. Otherwise `fastFetch` would think "the session is still there"
        //   and skip the BLE gate (BLE is gone by then too), and the fault would show up as an inexplicable timeout
        //   instead of `notConnected`.
        batchOpen = false
    }

    /// Make all in-flight waits fail immediately (instead of each waiting out its own timeout).
    private func failInFlight(_ error: Error) {
        // Previously a **forged** universalError frame was fed back into the state machine here, which made it indistinguishable from
        // a real error from the card (the true cause was swallowed by "device reported a universal error").
        // Now the real cause is written directly into phase.
        session.fail("connection dropped: \(String(describing: error))")
        connection?.cancel()
        connection = nil
    }

    // MARK: Diagnostics

    /// One-line status for logs/UI.
    var diagnosticSummary: String {
        let counts = session.cmderCounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: " ")
        return "phase=\(session.phase) bytes=\(session.receivedBytes)/\(session.expectedBytes) cmder[\(counts)]"
    }
}

// MARK: - Gap probe

/// ⚠️ **What it was meant to capture is no longer a gap** (round 15): the card never reports the password over BLE,
/// the password is computed locally from the SN (`protocol-notes.md` §18.1). So this probe's value now boils down to two points:
///
///   1. **Cross-check** —— if future firmware changes the rule, this targeted BLE sequence "after sending `OPEN_WIFI`"
///      shows the difference at once (`TicNoteWifiCredentials.parse(_:)` also still accepts card-reported values);
///   2. **Forensic entry point when swapping cards/firmware** —— a generic capture tool makes people hunt for those few frames
///      among thousands, whereas the probe records only this segment.
///
/// The reason it is built into the App instead of asking the user to install nRF Connect: **the probe can get the targeted sequence "after sending OPEN_WIFI"**,
/// whereas a generic capture tool makes people hunt for those few frames by hand among thousands.
@MainActor
enum TicNoteWifiProbe {

    /// Record one inbound BLE control frame. `TicNoteLink` calls it on receiving a `0x01` frame.
    static func record(_ frame: Data, into storage: inout [Data], limit: Int = 512) {
        storage.append(frame)
        if storage.count > limit {
            storage.removeFirst(storage.count - limit)
        }
    }

    /// Export the accumulated frames as pasteable hex text.
    static func export(_ frames: [Data]) -> String {
        var lines: [String] = ["# TicNote BLE control frames (inbound)", "# count: \(frames.count)"]
        for (i, f) in frames.enumerated() {
            lines.append("\(String(format: "%03d", i))  \(f.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }
        return lines.joined(separator: "\n")
    }
}
