import Foundation

// MARK: - State machine for TicNote Wi-Fi fast transfer (pure logic, no dependency on Network / CoreBluetooth)
//
// Isomorphic to the BLE path (`TicNoteSession`), for the same two reasons:
//   1. **Verifiable** -- an `NWListener` can't be created on the command line, so once protocol logic is welded onto it, only manual testing on a real device is possible;
//   2. **Testable** -- the state machine is push-based: feed one `TicNoteWifiFrame`, get back "which frames to send next".
//      So self-check §20 can run the whole handshake → list → download → assemble on a machine without a network.
//
// ## Direction (the most important correction of this round, see the top of `TicNoteWifiProtocol.swift`)
// **We are the server.** So this state machine's starting point is not "I connected", but
// "**the card connected in, and it speaks first**":
//
//   card → 2 SAY_HELLO
//   me → 1 HANDSHAKE {"stamp","token"}
//   me → 11 GET_FILE_LIST {"single","start","uid"}   ← ★ 11, not 20 (see TicNoteWifiCmder)
//   card → 11 list reply (json + bin)
//   me → 12 FILE_SYNC {"end","scene","session","start"}  ← ★ 12, not 19
//   card → 13 content chunk × N (json + bin)
//   me → 14 FILE_DELETE {"scene","session"}   ← ★ only when "auto-delete after transfer" is on; **while the session is still alive**
//   me → 4 WIFI_CLOSE {"status":1}   (wrap-up; if not sent the card's hotspot stays on and drains battery)
//
// ★ Why delete comes after 13 and before 4 (decided 2026-10-12): the only delete command proven by the official code
//   is this Wi-Fi `cmder 14` (`WifiPlugin.cleanFile`). The BLE `0x1E` has never received
//   an ack, and on the real device 1.3 s after sending it the card's BLE connection timed out and dropped. Once the session closes there is nowhere to send 14,
//   so it must squeeze into the short stretch between these two numbers; `ingest` therefore also moves the 14 ack ahead of the terminal-state check.
//
// ## What is **certain** from the official code, and what is **inferred**
// Certain (`WifiPlugin.java` can point to the lines): cmder direction and semantics, the JSON field names of each request,
//   the handshake going first (the card sends 2 first), the completion criterion (bytes written ≥ fileSize), resume using the same cmder 12.
// Inferred: **⑪ the order among the three requests** has no official timing to compare with (the official side is Dart-layer scheduling,
//   and that part didn't survive in the decompiled output), so it is arranged in the "least surprise" order:
//   handshake → ask for list → ask for file. Plus the value semantics of `single` / `uid` / `scene`.
//   All three are marked separately in the comments of self-check §20.
//
// ## Why the completion criterion is "bytes ≥ fileSize", not "received some end frame"
// The decompiled official `saveFileData` has an `if (r12 >= r3.longValue())` branch
// (`r3` = `this.fileSize`), meaning **it itself judges completion by byte count**.
// This is more reliable than waiting for an end frame that may be dropped: a dropped end frame → never arrives → timeout;
// judging by byte count → proceeds as soon as the data is complete, so it can't hang.

final class TicNoteWifiSession {

    // MARK: Configuration

    struct Config: Equatable {
        /// The token returned to the card in the handshake. In the official App it is a constant `"1234567890000000"` passed in from the Dart side.
        var token: String = "1234567890000000"

        /// ⚠️ Semantics unconfirmed (see the file header). Default is 0, but **explicitly requires the caller to know what it is passing**.
        var uid: Int64 = TicNoteWifiListRequest.officialUID
        var scene: Int64 = 0

        /// The list request's `start`. **The official side writes a constant**, not a pagination cursor -- see
        /// `TicNoteWifiListRequest.officialStart` (the disassembly source is there).
        var listStart: Int64 = TicNoteWifiListRequest.officialStart

        /// The list request's `single`. **The official side passes 0** (the zero register), not 1 --
        /// same as above. The real semantics of `single` are still unsolved, so here we only guarantee byte-for-byte parity with the official one.
        var listSingle: Int64 = TicNoteWifiListRequest.officialSingle

        /// Use V2 (cmder 20 / 19) or V1 (11 / 12).
        ///
        /// ★★★ Default is **V1**, the conclusion after two corrections on 2026-10-12:
        ///   · The official App **only uses V1** (both Dart entry points call `getFileList` / `downFileList`,
        ///     while `getFileListV2` / `downFileListV2` never appear even once in the Dart snapshot);
        ///   · On the real device the card replies to cmder 20 directly with `{"cmd":20,"code":3}`, then ignores us for 30 s.
        /// Full evidence is in the passage at the top of `TicNoteWifiCmder`.
        var useV2: Bool = false

        /// Whether to automatically ask for the file list once after the handshake.
        /// The official side has the Dart layer call `getFileList` after receiving the handshake event, equivalent to automatic;
        /// this switch is kept so the self-check can separately test "handshake only, no list".
        var autoListOnHandshake: Bool = true
    }

    // MARK: Phases

    enum Phase: Equatable {
        /// Connection established, waiting for the card to send SAY_HELLO first
        case awaitingHello
        /// Handshake replied, list requested, waiting for the list reply
        case listing
        /// List in hand, waiting for the caller to pick one to start downloading
        case listed
        case downloading
        case finished
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .finished, .failed: return true
            default: return false
            }
        }
    }

    // MARK: Externally readable state

    private(set) var phase: Phase = .awaitingHello
    /// Recording list in a protocol-agnostic shape
    private(set) var recordings: [RecorderRecording] = []
    /// Raw list entries
    private(set) var fileEntries: [TicNoteWifiFileEntry] = []
    /// File bytes received so far (actual coverage after placement by offset)
    private(set) var receivedBytes: Int = 0
    /// Total bytes expected for this download (from `size` in the list)
    private(set) var expectedBytes: Int = 0
    /// Number of download requests sent (including resumes)
    private(set) var sentSyncCount = 0
    /// How many times each cmder has appeared. **This is an observation port left for the "not yet measured on a real device" situation** --
    /// the first time it runs on a real device, it shows which numbers the card actually sent and how many times each,
    /// without having to guess the flow right first to see the log.
    private(set) var cmderCounts: [UInt16: Int] = [:]
    /// Cmders received but unrecognized (excluding the known ones)
    private(set) var unexpectedCmers: [UInt16] = []

    /// Original text of the `universalError` (cmder 0) the card sent, **only recorded, not treated as a fatal error** --
    /// the reason is in the notes on those two cases in `.listing` / `.downloading`.
    /// The timeout path carries this original text, so "what exactly did the card say" is no longer lost.
    private(set) var lastUniversalError: String?
    private(set) var universalErrorCount = 0

    /// The delete request **has been sent** (true after `planDelete`). For logs and self-checks.
    private(set) var deleteRequested = false

    /// Delete ack. `nil` = **not yet received** (not "delete failed").
    ///
    /// Three states (`nil` / `true` / `false`) rather than `Bool` is deliberate: the card not answering ≠ the card refusing,
    /// and the follow-up actions for these two are **completely opposite** (see `TicNoteWifiLink.requestDelete`).
    private(set) var deleteAcknowledged: Bool?

    // MARK: Internal

    private let config: Config
    private let now: () -> Date

    private var session: Int64 = 0
    private var fileType: Int64 = 0

    /// Chunks received. `offset == nil` = the peer gave no offset, append in order.
    private var chunks: [(offset: Int?, data: Data)] = []

    /// Set of known inbound cmders (used for `unexpectedCmers`)
    private static let knownInboundCmers: Set<UInt16> = [
        TicNoteWifiCmder.universalError, TicNoteWifiCmder.handshake,
        TicNoteWifiCmder.sayHello, TicNoteWifiCmder.heartbeat,
        TicNoteWifiCmder.wifiClose, TicNoteWifiCmder.tips,
        TicNoteWifiCmder.getFileList, TicNoteWifiCmder.fileSync,
        TicNoteWifiCmder.fileSyncContent, TicNoteWifiCmder.fileDelete,
        TicNoteWifiCmder.fileSyncStop, TicNoteWifiCmder.otaFile,
        TicNoteWifiCmder.otaData, TicNoteWifiCmder.downFileListV2,
        TicNoteWifiCmder.getFileListV2, TicNoteWifiCmder.speedTest,
        TicNoteWifiCmder.getLog,
    ]

    init(config: Config = Config(), now: @escaping () -> Date = Date.init) {
        self.config = config
        self.now = now
    }

    // MARK: Kickoff

    /// The "fetch list" command code to send this time. Also used for matching a named rejection, so it is extracted as a property.
    private var listRequestCmder: UInt16 {
        config.useV2 ? TicNoteWifiCmder.getFileListV2 : TicNoteWifiCmder.getFileList
    }

    /// The "start download" command code to send this time (same as above).
    private var syncRequestCmder: UInt16 {
        config.useV2 ? TicNoteWifiCmder.downFileListV2 : TicNoteWifiCmder.fileSync
    }

    /// List request. The `flag` scheme is BLE's; the Wi-Fi side uses `single` / `start` instead.
    func beginListing() -> TicNoteWifiFrame {
        phase = .listing
        return config.useV2
            ? TicNoteWifiOutbound.getFileListV2(
                uid: config.uid, start: config.listStart, single: config.listSingle)
            : TicNoteWifiOutbound.getFileList(
                uid: config.uid, start: config.listStart, single: config.listSingle)
    }

    /// Start downloading one recording.
    ///
    /// - Parameter fromOffset: Resume start point. The official resume is `Math.max(start at request time, bytes already written locally)`
    ///   -- i.e. **the actual local on-disk state is authoritative**, preventing a too-small offset reported by the peer from overwriting already-written data.
    ///   Same scheme here: the caller passes "how many bytes exist locally", and this type takes the larger of that and the recorded value.
    func beginDownload(_ entry: TicNoteWifiFileEntry, fromOffset: Int = 0) -> TicNoteWifiFrame? {
        guard entry.sizeBytes > 0 else {
            phase = .failed("size is zero")
            return nil
        }
        session = Int64(entry.sessionId)
        fileType = Int64(entry.fileType ?? 0)
        expectedBytes = Int(entry.sizeBytes)

        // Just restarted: clear the previous round's chunks. Resume-from-breakpoint goes through `resumeAfterStop`
        // and does not enter here (otherwise already-verified chunks would be dropped, making the transfer wasted).
        if fromOffset == 0 {
            chunks = []
            receivedBytes = 0
        }

        phase = .downloading
        sentSyncCount += 1
        let start = max(0, max(fromOffset, receivedBytes))
        return config.useV2
            ? TicNoteWifiOutbound.downFileListV2(
                session: session, scene: config.scene, start: Int64(start),
                end: Int64(expectedBytes), fileType: fileType)
            : TicNoteWifiOutbound.fileSync(
                session: session, scene: config.scene, start: Int64(start),
                end: Int64(expectedBytes))
    }

    // MARK: Advancing

    /// Before starting the next file within the **same** Wi-Fi session, clean out the receive state of "this file".
    ///
    /// ## Why it is needed
    /// A whole-batch fast transfer now shares one session (see `TicNoteWifiLink.beginBatch`); when one finishes
    /// `phase` stops at `.finished` and `chunks` still holds the previous audio. If not cleared:
    /// * `deliverable()` would hand over the **previous** file's bytes as this one's (worst case:
    ///   the user gets two audio pieces stitched together, while the UI is all checkmarks);
    /// * if the previous one was `.failed`, the next one wouldn't even get past the "wait for list" step.
    ///
    /// ## Things deliberately **not** cleared
    /// * `fileEntries` -- the file list shared by the whole batch (also the source of the `sessionId`
    ///   that `cmder 14` needs). Refetching costs another round trip, and that hop is the most likely to fail on a real device;
    /// * `cmderCounts` / `unexpectedCmers` / `lastUniversalError` -- **diagnostic evidence** accumulated across files;
    ///   clearing them would erase "what exactly happened in this batch";
    /// * `sentSyncCount` -- the download request count accumulated over the whole batch; kept so we know how many were sent in total.
    func resetForNextFile() {
        chunks = []
        receivedBytes = 0
        expectedBytes = 0
        session = 0
        fileType = 0
        deleteRequested = false
        deleteAcknowledged = nil
        // `.finished` → `.listed`: the list is still in hand, wait for the caller to tap the next one.
        // `.failed` is also pulled back -- that is most likely **the previous file's own** timeout/peer error,
        // and the session itself is still alive (if the session is truly dead `TicNoteWifiLink` takes the rebuild path).
        if phase.isTerminal { phase = .listed }
    }

    /// Delete this recording on the card (`cmder 14`) while the Wi-Fi session is **still alive**.
    ///
    /// ## Why `cmder 14`, not the BLE `0x1E`
    /// Both pieces of evidence are hard:
    ///   * The official file delete uses exactly this -- `WifiPlugin.java:892-896` constructs
    ///     `{"session","scene"}` and sends it (`WifiProtocol.WifiRequest.FILE_DELETE = 14`);
    ///   * The BLE `0x1E` **has never received any ack on a real device to date**, and the real-device log of 2026-10-12
    ///     11:23:48 shows: **1.3 s after sending it the card's BLE connection timed out and dropped**
    ///     (`LINK disconnected error=CBErrorDomain Code=6 "The connection has timed out
    ///     unexpectedly"`). That is, it is not "can't delete", it **cuts the link** --
    ///     cutting the link during a batch transfer leaves the next recording without an `OPEN_WIFI` channel.
    ///
    /// ## Why it must be "while the session is still alive"
    /// This command can only travel on the Wi-Fi WebSocket, and `fastFetch`'s wrap-up
    /// (`teardown`) closes that connection. The call site must land in
    /// the short stretch "after the data is complete, before `teardown`" -- that is why this method exists.
    func planDelete(_ entry: TicNoteWifiFileEntry) -> TicNoteWifiFrame {
        deleteRequested = true
        deleteAcknowledged = nil
        return TicNoteWifiOutbound.fileDelete(
            session: Int64(entry.sessionId), scene: config.scene)
    }

    /// Feed one **complete** peer frame (one WebSocket message = one `WifiDataVo`),
    /// returns the frames to send back next (usually 0 or 1).
    func ingest(_ frame: TicNoteWifiFrame) -> [TicNoteWifiFrame] {
        cmderCounts[frame.cmder, default: 0] += 1
        if !Self.knownInboundCmers.contains(frame.cmder) {
            unexpectedCmers.append(frame.cmder)
        }

        // ★★ The delete ack **must be ordered before the terminal-state check** (2026-10-12).
        //
        //   Delete happens **after** `.finished` (the file is complete but the Wi-Fi session
        //   is still open, that short stretch), and `case .finished, .failed: return []` below
        //   would drop **all** frames of that stretch → the ack is never recorded → every delete waits until timeout.
        //   So this stretch is pulled forward separately, and **does not touch phase**: whether delete succeeds or not
        //   has no effect on the fact that "one recording was fully received this time".
        //
        //   ⚠️ Both shapes must be recognized, and they are **two different cmders**:
        //     · success ack = `cmder 14 {"session","status"}`;
        //     · named rejection = `cmder 0 {"cmd":14,"code":M}` ← that's **0**, not 14!
        //       (Recognizing only 14 would miss rejections and then wait in vain until timeout -- the self-check caught this version red-handed.)
        //   Only intercept when "actually waiting for a delete ack", so as not to steal the existing handling of `cmder 0` in other phases.
        if deleteRequested, deleteAcknowledged == nil {
            if frame.cmder == TicNoteWifiCmder.fileDelete {
                recordDeleteReply(frame)
                return []
            }
            if frame.cmder == TicNoteWifiCmder.universalError,
               let refusal = TicNoteWifiUniversalError.parse(frame: frame),
               refusal.cmd == TicNoteWifiCmder.fileDelete {
                recordDeleteReply(frame)
                return []
            }
        }

        switch phase {
        case .finished, .failed:
            return []

        case .awaitingHello:
            switch frame.cmder {
            case TicNoteWifiCmder.sayHello:
                // Official: reply 1 on receiving 2, with `stamp` in seconds. Even if the later flow isn't working yet,
                // this step must be replied -- if not, the card keeps waiting, which shows up as "connected but nothing happens".
                var out = [TicNoteWifiOutbound.handshake(
                    token: config.token,
                    stamp: Int64(now().timeIntervalSince1970))]
                if config.autoListOnHandshake {
                    out.append(beginListing())
                    // beginListing sets phase to .listing -- the result is already appended above,
                    // no need to change it again here.
                } else {
                    phase = .listed
                }
                return out

            case TicNoteWifiCmder.heartbeat:
                // Heartbeat before the handshake: the official side reuses the same `heartReceiveData`, so we reply likewise.
                return [TicNoteWifiOutbound.heartbeatPong()]

            case TicNoteWifiCmder.universalError:
                // Error frames may also arrive before the handshake -- same rule as the other phases: record, don't fail.
                recordUniversalError(frame)
                return []

            default:
                return []
            }

        case .listing:
            switch frame.cmder {
            case TicNoteWifiCmder.getFileList, TicNoteWifiCmder.getFileListV2:
                guard let entries = TicNoteWifiFileList.parse(frame: frame) else {
                    // ⚠️ A failure here is **the most informative one**: it means the shape of bin
                    // differs from the 10-byte records we recognize. Better to fail explicitly here
                    // than to read misaligned -- a guessed sessionId would request a
                    // nonexistent file, with the symptom "transfer ends immediately but the file is empty".
                    // Lay the first few records out as hex, to make comparison against the official disassembly easy.
                    phase = .failed(
                        "file list shape not recognised "
                        + "(json \(frame.json?.count ?? 0) B, bin \(frame.bin?.count ?? 0) B"
                        + "; bin%10 = \((frame.bin?.count ?? 0) % TicNoteWifiFileList.recordBytes)"
                        + " hex: \(TicNoteWifiFileList.hexDumpPrefix(frame.bin ?? Data())))"
                    )
                    return []
                }
                fileEntries = entries
                recordings = entries.map(Self.recording(from:))
                phase = .listed
                // ★ 2026-10-12: the list body is in bin (10-byte little-endian records). For the first frame, lay out the first few entries
                //   as hex + parse result, so a real-device comparison immediately shows whether it's right.
                TicNoteDiagLog.log("WIFI",
                    "✅ list parsed OK: \(entries.count) entries"
                    + " (json.count=\(TicNoteWifiFileList.jsonCount(in: frame.json).map(String.init(describing:)) ?? "?")"
                    + " bin=\(frame.bin?.count ?? 0)B) first entry: "
                    + (entries.first.map { "sid=\($0.sessionId) size=\($0.sizeBytes)B prop=\($0.prop)" } ?? "none")
                    + " ｜ raw bytes: " + TicNoteWifiFileList.hexDumpPrefix(frame.bin ?? Data()))
                return []

            case TicNoteWifiCmder.fileSync, TicNoteWifiCmder.downFileListV2:
                if let status = TicNoteWifiStatus.parse(frame: frame), !status.isOK {
                    phase = .failed("device refused: status \(status.raw)")
                }
                return []

            case TicNoteWifiCmder.heartbeat:
                return [TicNoteWifiOutbound.heartbeatPong()]

            case TicNoteWifiCmder.wifiClose:
                phase = .failed("device closed the Wi-Fi link")
                return []

            case TicNoteWifiCmder.universalError:
                // ★ The official `WifiPlugin.java` dispatch has **no case for cmder=0**:
                //   it falls straight to `default: return` -- the official App **does nothing** on receiving this frame,
                //   and keeps waiting for the list. We previously treated it as a fatal error, and the real-device symptom was
                //   "wifi listing failed: device reported a universal error".
                //   Now aligned with the official side: only record, don't fail. A genuine error goes through the timeout,
                //   and the timeout error carries this original text (see the timeout path of `TicNoteWifiLink.drive`).
                recordUniversalError(frame)
                // ★★ 2026-10-12 adds a fast-fail layer for "named rejection".
                //
                //   The official "do nothing" is right (it waits for the timeout anyway), but it is **the worst experience**:
                //   after the card replied `{"cmd":20,"code":3}` on the real device we waited 30 s doing nothing,
                //   and finally reported "the card never sent its Wi-Fi file list" --
                //   which sounds like "the card hung / the network is down", while the real cause is **the wrong command number**.
                //   The judgment is hard: the frame's `cmd` explicitly says which command it is rejecting,
                //   and we only accept it when it equals the request we just sent.
                if let refusal = TicNoteWifiUniversalError.parse(frame: frame),
                   refusal.cmd == listRequestCmder {
                    phase = .failed(refusal.description)
                }
                return []

            default:
                return []
            }

        case .listed:
            // No file chosen yet, the card shouldn't send data. Heartbeats are still replied; others are tallied (`cmderCounts`) then ignored.
            if frame.cmder == TicNoteWifiCmder.heartbeat {
                return [TicNoteWifiOutbound.heartbeatPong()]
            }
            return []

        case .downloading:
            switch frame.cmder {
            case TicNoteWifiCmder.fileSyncContent:
                guard let chunk = TicNoteWifiContentChunk.parse(frame: frame) else {
                    // For a 13 with `bin == null` the official side "logs and ignores", no failure.
                    // Same here, no failure -- but it also doesn't count toward progress, so a real problem shows up as a timeout.
                    return []
                }
                ingest(chunk)
                if receivedBytes >= expectedBytes {
                    phase = .finished
                }
                return []

            case TicNoteWifiCmder.fileSync, TicNoteWifiCmder.downFileListV2:
                guard let status = TicNoteWifiStatus.parse(frame: frame) else { return [] }
                if !status.isOK {
                    phase = .failed("device refused the transfer: status \(status.raw)")
                }
                return []

            case TicNoteWifiCmder.fileSyncStop:
                // Official: on receiving 15 with `status == 0` → **auto-resume**
                // (`sendResumeDownloadRequest` sends once more with the same cmder 12).
                guard let status = TicNoteWifiStatus.parse(frame: frame), status.isOK else {
                    phase = .failed("stop was not acknowledged")
                    return []
                }
                sentSyncCount += 1
                let start = Int64(max(0, receivedBytes))
                return [config.useV2
                    ? TicNoteWifiOutbound.downFileListV2(
                        session: session, scene: config.scene, start: start,
                        end: Int64(expectedBytes), fileType: fileType)
                    : TicNoteWifiOutbound.fileSync(
                        session: session, scene: config.scene, start: start,
                        end: Int64(expectedBytes))]

            case TicNoteWifiCmder.heartbeat:
                return [TicNoteWifiOutbound.heartbeatPong()]

            case TicNoteWifiCmder.wifiClose:
                phase = .failed("device closed the Wi-Fi link mid-transfer")
                return []

            case TicNoteWifiCmder.universalError:
                // Same as `.listing`: the official side ignores cmder=0, not fails. If something really goes wrong mid-transfer
                // it shows up as chunks stopping → timeout, and the timeout error carries this original text.
                recordUniversalError(frame)
                // Same as above: the card names and rejects the "start download" one → fail immediately, don't wait for the tens-of-seconds transfer timeout.
                if let refusal = TicNoteWifiUniversalError.parse(frame: frame),
                   refusal.cmd == syncRequestCmder {
                    phase = .failed(refusal.description)
                }
                return []

            default:
                return []
            }
        }
    }

    /// Record the original text of a card error frame (truncated, to keep an overlong JSON from flooding the log/UI).
    private func recordUniversalError(_ frame: TicNoteWifiFrame) {
        universalErrorCount += 1
        let raw = frame.json ?? "(no json, bin \(frame.bin?.count ?? 0) B)"
        lastUniversalError = raw.count > 200 ? String(raw.prefix(200)) + "…" : raw
    }

    /// Record a delete (`cmder 14`) ack.
    ///
    /// ## Recognize two shapes, **do not judge** the rest
    /// The official `WifiPlugin.java:892` branch only **sends** the request; what the ack looks like wasn't preserved on the Java side,
    /// so here we accept the two known shapes of sibling frames:
    ///   * `cmder 14 {"session":N,"status":0}` -- the same `status` field as `cmder 12`,
    ///     `status == 0` means success (`TicNoteWifiStatus`);
    ///   * `cmder 0 {"cmd":14,"code":M}` -- the card names it and says "this one isn't allowed"
    ///     (`TicNoteWifiUniversalError`, the same shape as list/download rejections).
    ///
    /// Any other shape **stays `nil` (no answer yet)** rather than being guessed as "rejected" --
    /// treating an unrecognized message as a rejection would send the caller into the BLE `0x1E` "cuts the link after sending" pitfall.
    private func recordDeleteReply(_ frame: TicNoteWifiFrame) {
        if let status = TicNoteWifiStatus.parse(frame: frame) {
            deleteAcknowledged = status.isOK
            return
        }
        if let refusal = TicNoteWifiUniversalError.parse(frame: frame),
           refusal.cmd == TicNoteWifiCmder.fileDelete {
            deleteAcknowledged = false
        }
    }

    /// Fail the state machine directly when the connection layer (not the card protocol) errors.
    ///
    /// Previously a **fabricated** `universalError` frame was fed back into the state machine -- and it looked
    /// exactly like a genuine card error, so when troubleshooting it was impossible to tell who reported it (the real-device
    /// "device reported a universal error" swallowed the real cause). Now phase is written directly and the real cause is carried.
    func fail(_ reason: String) {
        guard !phase.isTerminal else { return }
        phase = .failed(reason)
    }

    /// Wrap-up (sent on both normal end and failure). The official one is `stopWifi` → `{"status":1}`.
    func farewell() -> TicNoteWifiFrame {
        TicNoteWifiOutbound.wifiClose()
    }

    // MARK: Assembly

    private func ingest(_ chunk: TicNoteWifiContentChunk) {
        let data = chunk.data
        if let offset = chunk.offset {
            chunks.append((offset: offset, data: data))
            // Coverage is computed by "highest covered byte", not by sum -- resume resends overlapping ranges,
            // and a sum would push progress past 100%, then "looks finished but not enough bytes".
            var highest = 0
            for c in chunks {
                if let o = c.offset { highest = Swift.max(highest, o + c.data.count) }
            }
            receivedBytes = highest
        } else {
            chunks.append((offset: nil, data: data))
            receivedBytes += data.count
        }
    }

    /// Assemble into a complete file and give QC statistics.
    ///
    /// Same contract as BLE-side `TicNoteSyncRequest.assemble`:
    /// a non-zero `gaps` / `conflicts` must refuse delivery.
    func assemble() -> (data: Data, gaps: Int, conflicts: Int) {
        guard chunks.contains(where: { $0.offset != nil }) else {
            // Peer gave no offsets: can only stitch in order. Statistics are 0 -- because with "no offsets"
            // this type cannot tell "correct order" from "wrong order", and reporting a hard number would be fake.
            return (chunks.reduce(into: Data()) { $0.append($1.data) }, 0, 0)
        }

        let placed = chunks.compactMap { c -> (Int, Data)? in
            guard let o = c.offset else { return nil }
            return (o, c.data)
        }.sorted { $0.0 < $1.0 }

        guard !placed.isEmpty else { return (Data(), 0, 0) }
        let total = placed.reduce(0) { Swift.max($0, $1.0 + $1.1.count) }
        var buffer = [UInt8](repeating: 0, count: total)
        var filled = [Bool](repeating: false, count: total)
        var conflicts = 0

        for (offset, data) in placed {
            for (i, byte) in data.enumerated() {
                let at = offset + i
                guard at < total else { break }
                if filled[at] {
                    // Overlapping regions **must be byte-identical**. If not, the two reads weren't of the same data,
                    // and there is no way to judge which is right -- refuse delivery either way.
                    if buffer[at] != byte { conflicts += 1 }
                } else {
                    buffer[at] = byte
                    filled[at] = true
                }
            }
        }
        let gaps = filled.filter { !$0 }.count
        return (Data(buffer), gaps, conflicts)
    }

    /// Turn the received bytes into something playable. **fail-closed**, same rule as the BLE side.
    func deliverable() throws -> RecorderClip {
        let r = assemble()
        guard r.gaps == 0, r.conflicts == 0 else {
            throw RecorderLinkError.corrupted("gaps=\(r.gaps) conflicts=\(r.conflicts)")
        }
        guard !r.data.isEmpty else {
            throw RecorderLinkError.malformed("assembled 0 bytes")
        }
        guard TicNoteOpusStream.looksLikeOpus(r.data) else {
            throw RecorderLinkError.malformed(
                "payload is not a plaintext Opus stream (\(r.data.count) B)"
            )
        }
        guard let ogg = TicNoteOpusStream.oggOpus(from: r.data) else {
            throw RecorderLinkError.malformed("Ogg Opus muxing failed")
        }
        let duration = TicNoteOpusStream.estimatedDuration(r.data)
        return RecorderClip(
            data: ogg,
            // ★ Use the `.opus` suffix rather than `.ogg` -- the container is the same (what `TicNoteOpusStream.oggOpus`
            //   produces is standard Ogg Opus), and **`.opus` is the suffix already fully validated end to end on the D·NOTE path**:
            //   the library allowlist (`AudioImporter.acceptedExtensions`), duration probing
            //   (`LibraryScanner.probeDuration` → `OpusOgg.duration`), playback
            //   (the iOS 17 branch of `AudioPlaybackController`), and pre-transcription transcoding all recognize it.
            //   The result of using `.ogg`: the library's extension allowlist doesn't recognize it → the file **doesn't appear at all**,
            //   the download "succeeds" yet the user sees nothing (measured on a real device, 2026-10-09).
            fileExtension: "opus",
            duration: duration,
            formatNote: String(
                format: "Opus %d Hz %@ %d kbps · %.1f s (Wi-Fi)",
                TicNoteGATT.opusSampleRate,
                TicNoteGATT.opusChannels == 2 ? "stereo" : "mono",
                TicNoteGATT.opusBitrate / 1000,
                duration
            )
        )
    }

    /// Completion 0…1.
    var progress: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1.0, Double(receivedBytes) / Double(expectedBytes))
    }

    // MARK: Mapping

    private static func recording(from e: TicNoteWifiFileEntry) -> RecorderRecording {
        RecorderRecording(
            id: String(e.sessionId),
            displayTitle: Self.title(for: e.startedAt),
            sizeBytes: Int(e.sizeBytes),
            startedAt: e.startedAt,
            sessionID: e.sessionId,
            raw: [
                "sessionId": Int(e.sessionId),
                "fileType": Int(e.fileType ?? 0),
                "transport": "wifi",
            ]
        )
    }

    /// When the timestamp is missing, **do not** fall back to 1970: that is "unknown", not "earliest".
    private static func title(for date: Date?) -> String {
        guard let date else { return "Recording" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
