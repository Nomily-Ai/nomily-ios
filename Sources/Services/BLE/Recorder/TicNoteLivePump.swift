import Foundation

// MARK: - Pure logic core for "pull while recording" (no CoreBluetooth dependency)
//
// ## What problem it solves
// Real-time transcription needs the audio of **the recording in progress**. TicNote firmware has two possible routes:
//   · `0x03` real-time audio stream (`TicNotePacketType.realtimeAudio`) -- but there is **not a single sample**
//     (the `0x03` frame count is 0 in all 13 captures), and the two official parsers contradict each other;
//   · **Pull while recording** -- this is what the official App itself does during recording.
// This type takes the second route. The basis is the **full per-frame statistics** of that 72.15 s of
// session `0x6AC74377` in `captures/hci-all/bug2-20261008.att.txt`:
//
// ```
//   0x14 (session start)            5774.351
//   0x1D → 0x1E (prelude, see below)    5774.368 → 5774.492
//   0x1C × 353                 5774.713 → 5848.276
//     start strictly contiguous: 0 → 1600 → 3200 → … → 563520 (last chunk 320 B)
//   0x17 (session end, fileSize=563520)  5846.503
// ```
//
// ## The most important point: **the card throttles to real time by itself; we just ask for chunk after chunk**
// 353 chunks / 73.6 s ≈ **4.8 chunks/s**, and each 1600 B chunk = 0.2 s of audio --
// which is **exactly 1 second of audio per second**. Looking closer at steady state (every 25 chunks is exactly 5.0 s):
//
// ```
//   0x1C #26  5780.810     0x1C #51  5785.825     0x1C #76  5790.848
//        ↑ 5.015 s apart / 25 chunks = 200 ms/chunk = 5 chunks/s
// ```
//
// The first 25 chunks are **faster than real time** (25 chunks in 6.10 s, 41600 B = 5.2 s of audio) --
// at that point the card is catching up on the part at the start that wasn't yet written, which shows **the card waits until it has written before giving it**, and won't
// error out or give wrong bytes because we "asked too far". So the algorithm can be simple enough not to ask "how much has been written so far":
//
// ```
//   ask [pulled, pulled+1600)  →  wait for 20 x 0x02  →  wait for chunk end  →  pulled += 1600  →  ask again
// ```
//
// ⚠️ **Do not** change it to "first schedule a 353-chunk plan from the known total length". During recording the total length is **unknown**
// (`0x17` only arrives when recording stops); scheduling ahead would ask past the write pointer, turning the throttling
// dependency above into a hard constraint.
//
// ## Shape within a chunk (the complete round trip of one request, real device, frame by frame)
// ```
//   → 01 1c 00 <sid u32> <start u32> <end u32> 00      write command (APP→CARD)
//   ← 01 1c 00 <sid u32> 00                            ack, status 0 = accepted
//   ← 02 <sid> <offset u32> 50 <80 B>  × 20            audio, offset steps by 80
//   ← 02 <sid> ffffffff 50 01 00 00…                   chunk end (offset all F)
//   ← 01 1d 00 <sid u32> ff ff                         the card itself reports "this chunk is done"
// ```
// Chunk end is judged by that `0x02` (it **arrives first**, and is already recognized by `TicNoteVoiceChunk.isEnd`;
// the 353 sentinels in §18's offline-replay firmware are exactly this).
//
// ## ★ 2026-10-12: consequences of three "chunk end lost" cases, all now plugged
// The real-device session at `18:43:03` hit all three -- what the user saw was "**it can't transcribe after only 3 s**":
// ```
//   ① phase only returns to .idle on receiving the chunk end ⇒ nextRequest() is nil forever after
//      → permanently silent after 17 chunks (from +3.69 s no chunk was requested for 20 seconds), UI still shows "recording"
//   ② the card's `01 1d 00 <sid> ff ff` (one per chunk, official capture 354/355) was ignored as "other"
//   ③ with zero bytes the whole way, one failure is just "silence"; nothing could terminate the pull loop
// ```
// Countermeasures: `chunkDeadline` (1.5 s wall-clock deadline per chunk) + `reclaimIfStalled(now:)`
// (invalidate when due, back off to the last whole-packet boundary and resend) + recognizing `0x1D` as "chunk finished"
// + `consecutiveStalls` reaching 8 chunks ⇒ `.failed` (turning a silent stall into an explicit error).
//
// ## 80 B frames → 160 B Opus packets
// Every **160 B** in the file is one Opus packet (TOC always `0xBC`, see `TicNoteGATT.opusPacketBytes`),
// while one `0x02` carries only **80 B** -- i.e. **one packet spans two frames**.
// So here we accumulate by offset until 160 B before emitting a packet to ASR; half packets are not emitted.
// ⚠️ This is exactly where "we can't just copy V05E": V05E's frames **are themselves packets** (40 B),
// whereas here we must re-cut at packet boundaries.
final class TicNoteLivePump {

    enum Phase: Equatable {
        case idle
        /// `[pulled, pulled+chunk)` has been sent, waiting for this chunk
        case awaitingChunk(start: Int, end: Int)
        /// Received everything up to the final size the card reported
        case finished
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .finished, .failed: return true
            default: return false
            }
        }
    }

    /// Result of `ingest(_:)`.
    struct IngestResult {
        /// Newly accumulated **whole** Opus packets (each `packetBytes` bytes, TOC always `0xBC`)
        var packets: [Data] = []
        /// This chunk is fully received (chunk end has arrived).
        var chunkCompleted = false
        /// The chunk finished but **not a single byte was given**, or **less than a full chunk** was given --
        /// meaning we may have asked past the write pointer (or recording has stopped).
        /// The caller should **back off a bit** before continuing, so as not to overwhelm the card.
        var retryAfterBackoff = false
    }

    // MARK: Configuration

    let sessionID: UInt32
    /// Bytes per chunk. On the real device 354/355 times were exactly 1600 (the final one 320).
    let chunkBytes: Int
    /// Bytes per Opus packet (TicNote is always 160)
    let packetBytes: Int

    // MARK: Externally readable state

    private(set) var phase: Phase = .idle
    /// Number of bytes received **contiguously** -- i.e. the start of the next request.
    private(set) var pulled = 0
    /// Number of `0x1C` sent (353 over a whole real-device session).
    private(set) var sentRequests = 0
    /// The card's reported **final** file size (`0x17` fileSize). `nil` = still recording, total length unknown.
    private(set) var totalBytes: UInt32?
    /// Gap count. **0** on the real device. When non-zero, the upper layer must fail-closed and reject this audio.
    private(set) var gaps = 0
    /// Duplicate chunk count (the same offset arriving again). 0 on the real device. Duplicate bytes are dropped and not counted in `pulled`.
    private(set) var duplicates = 0
    /// Malformed frame count (length byte doesn't match actual byte count). 0 on the real device.
    private(set) var malformed = 0
    /// Empty chunk count (chunk end arrived with zero bytes).
    private(set) var emptyChunks = 0
    /// How many times the card explicitly refused (`0x1C` ack status != 0).
    private(set) var refusals = 0
    /// ★ 2026-10-12: cumulative count of invalidate-and-resend caused by **lost chunk end / card stuck**.
    ///
    /// Recorded from the real-device session at `18:43:03`: after 17 chunks the pull stopped completely while the UI still showed "recording",
    /// yet nothing flowed any more -- **and silently** (`sawFirstPacket` was already set, so the first-frame timeout wouldn't fire).
    /// Cause and countermeasures: see `abandonStalledChunk()` / `reclaimIfStalled(now:)`.
    private(set) var stalledChunks = 0

    // MARK: Internal

    /// Data bytes received so far in this chunk
    private var chunkReceived = 0
    /// Tail that doesn't fill a packet
    private var pending = Data()
    /// Whether the last request "asked past the write pointer" (empty chunk / refused, and total length still unknown).
    ///
    /// **For diagnostics only, does not participate in gating** -- why it can't be used to block `nextRequest()` is explained there.
    /// It is cleared when "the next real data arrives" or "the card reports the final length".
    private var overranWithoutSize = false

    /// Number of **consecutive** empty chunks since the total length became known.
    ///
    /// With the total length known, an empty chunk is a **contradiction**: the card says the file has N bytes, yet gives not one byte of `[pulled, N)`.
    /// Retrying is pointless in this situation (unlike the unknown-length case where "the card hasn't written that far yet, wait and it will be there"), so after a limited
    /// number of chances we declare `.failed` -- otherwise the real-time loop would **spin forever** while looking like "recording",
    /// and the caller, having already received data (`sawFirstPacket`), would never trigger the first-frame timeout.
    private var emptyChunksAfterSize = 0

    /// Consecutive empty chunks allowed once the total length is known. 3 tries tolerate the window where "the card just finished writing the last small piece".
    static let maxEmptyChunksAfterSize = 3

    /// ★ 2026-10-12: **this chunk's wall-clock deadline**. `nil` = not currently waiting for any chunk.
    ///
    /// This type **does not own a clock** (so `nextRequest()` can only express lockstep through `phase`),
    /// so the deadline must be queried by the caller (`TicNoteLink.runLiveLoop`):
    /// it calls `reclaimIfStalled(now:)` once per loop iteration.
    private var chunkDeadline: Date?

    /// The longest to wait for one chunk.
    ///
    /// Real-device steady state is **200 ms/chunk** (5 chunks/s, each 1600 B = 0.2 s of audio),
    /// and when "chasing the write pointer" the card **waits until it has written before giving**, at worst waiting one more chunk's write time.
    /// 1.5 s = 7.5x margin; anything longer can only mean the chunk end was lost / the card is stuck.
    static let chunkTimeout: TimeInterval = 1.5

    /// Number of consecutive **zero-byte** invalidated chunks (**reset to zero on receiving real bytes**, unlike the cumulative `stalledChunks`).
    ///
    /// It has a single purpose: turn "the card no longer responds" from **endless silence** into an explicit failure.
    /// Why it is needed -- when the total length is unknown (recording in progress) the `emptyChunksAfterSize` gate
    /// never takes effect, so nothing could terminate a pull loop that has already died.
    ///
    /// ⚠️ **Only +1 when "this chunk had zero bytes"**, and this is required: losing the chunk end **while**
    ///    all data arrives is the norm (the 17 chunks at `18:43:03` on the real device were exactly that), and the right reaction there is to advance one chunk as usual.
    ///    Counting by "number of invalidations" would misjudge it as "card hung" as soon as every one of the 353 chunks lost its chunk end.
    private(set) var consecutiveStalls = 0

    /// How many consecutive **zero-byte** invalidations to judge `.failed`. 8 × 1.5 s ≈ 12 s with not one byte --
    /// enough to confirm the card isn't responding (normally a chunk should arrive every 200 ms).
    ///
    /// ⚠️ Setting it **slightly larger** than the first-frame timeout (10 s) is deliberate: when `sawFirstPacket == false`
    ///    the first-frame timeout fires first (that error message is more accurate); this only covers the situation where
    ///    "data was pulled at some point, then the card went completely silent".
    static let maxConsecutiveStalls = 8

    init(sessionID: UInt32,
         chunkBytes: Int = TicNoteGATT.syncChunkBytes,
         packetBytes: Int = TicNoteGATT.opusPacketBytes) {
        self.sessionID = sessionID
        self.chunkBytes = chunkBytes
        self.packetBytes = packetBytes
        phase = .idle
    }

    /// How many bytes to request for this chunk.
    ///
    /// * Once the total length is known, close out by the remainder (the real device's final one was `0x140 = 320`);
    /// * **Even when the total length is unknown, align to the `chunkBytes` grid** (see ★ below).
    ///
    /// ## ★ 2026-10-12: why we can't always return `chunkBytes` when the total length is unknown
    /// Ledger of the 3rd real-device session: `chunks=214 received=328000B gaps=5 empty chunks=8`.
    /// Here is how the gaps arose -- after a **short chunk** (the card gave only the part it had already written + chunk end)
    /// `pulled` stops mid-chunk, while the next request still asks for a whole chunk:
    /// ```
    ///   pulled = 1040 (chunk start 0, the card only wrote up to 1040)
    ///   → old: request [1040, 2640)      ← the start is in the middle of the card's 1600-byte grid cell
    ///   ←  the card starts giving from **its own next boundary** 1600
    ///   → offset(1600) > pulled(1040) ⇒ record one "gap", leaving 560 B in between as a hole
    /// ```
    /// After changing to "**fill up to the end of this cell**":
    /// ```
    ///   → new: request [1040, 1600)      ← only the 560 B that are missing
    ///   ←  the card gives 1040…1520 ⇒ fills it exactly, `pulled` returns to 1600 (on the grid)
    /// ```
    /// The card's `0x1C` can already take an arbitrary range (the official last request was `563200 → 563520`,
    /// only 320 B), so this isn't "inventing a protocol" but **reusing the freedom it already has**.
    ///
    /// ⚠️ A gap does not cause real-time audio to be discarded (`pump.gaps` has no fail-closed consumer --
    ///    those `guard gaps == 0` are all on the assembly path of **one-shot downloads**),
    ///    it is just a small hole in the audio ⇒ "instability" in listening/transcription.
    ///    So this change is a **quality** change, not an **availability** change.
    private var nextRequestLength: Int {
        if let total = totalBytes {
            let remaining = Int(total) - pulled
            return Swift.max(0, Swift.min(chunkBytes, remaining))
        }
        let into = pulled % chunkBytes
        return into == 0 ? chunkBytes : (chunkBytes - into)
    }

    // MARK: Driving (lockstep)

    /// Whether to send the next chunk. Returns the `0x1C` frame to write to GATT.
    ///
    /// `nil` has only two meanings, both "don't send now" rather than "error":
    ///   · the previous chunk hasn't been fully received (**lockstep**: the card firmware accepts only one in-flight command);
    ///   · already fully received / manually stopped (`phase` is terminal).
    ///
    /// ⚠️ **"The card gives no bytes" (empty chunk / refused) is deliberately not blocked here.**
    /// The solution for this situation is **waiting for time** -- ask again after the card has written new audio. But this type
    /// **does not own a clock**, so "stop first" could only be expressed as "return `nil` forever", and `overranWithoutSize`
    /// can only be cleared by "the next real data" or "the card reports the final length" -- both require us to **send
    /// the next chunk first**. That forms a deadlock: a single empty chunk pins real-time pulling forever, the UI stays on
    /// "recording", and the audio no longer flows (and **silently** -- the log merely shows no new frames).
    ///
    /// So throttling is left to the **caller to back off by wall clock**: `IngestResult.retryAfterBackoff` already truthfully
    /// reports "this time should back off", and the caller pushes `nextWriteAt` back accordingly (see
    /// `TicNoteLink.runLiveLoop`). When asking past the write pointer, backoff recurs, so this
    /// flag is only used for bookkeeping/diagnostics and no longer takes part in the gating decision.
    ///
    /// ★ 2026-10-12 addendum: the `case .awaitingChunk: return nil` branch was originally **unbounded** --
    /// once the chunk end was lost it would keep the next chunk out forever (the other half of the root cause of "silent stall").
    /// It now carries a wall-clock deadline (`chunkDeadline`), which the caller invalidates when due via `reclaimIfStalled(now:)`.
    func nextRequest() -> Data? {
        switch phase {
        case .finished, .failed:
            return nil
        case .awaitingChunk:
            return nil
        case .idle:
            break
        }

        let len = nextRequestLength
        guard len > 0 else {
            phase = .finished
            return nil
        }
        let start = UInt32(pulled)
        let end = start &+ UInt32(len)
        phase = .awaitingChunk(start: pulled, end: Int(end))
        chunkReceived = 0
        sentRequests += 1
        chunkDeadline = Date().addingTimeInterval(Self.chunkTimeout)
        return TicNoteSyncRequest.frame(sessionId: sessionID, start: start, end: end)
    }

    /// Feed one **complete** inbound frame; returns the Opus packets newly accumulated.
    ///
    /// Branch order matches `TicNoteSession.ingest`; criteria come from the real device:
    ///   1. `0x02` voice frame → lay into `pulled` by `offset`, emit a packet once 160 B accumulate;
    ///   2. `0x02` chunk end (`offset == 0xFFFFFFFF`) → this chunk is done;
    ///   3. `0x1D` (`01 1d 00 <sid> ff ff`) → **the card itself reports "this chunk is done"** → this chunk is done;
    ///   4. `0x1C` ack status != 0 → record one `refusals` (**do not** declare dead on the spot:
    ///      real-time pulling meets recoverable refusals like "asked too far"; just back off and retry);
    ///   5. anything else (card state pushes etc.) → ignore.
    ///
    /// ★ Branch 3 was added on 2026-10-12: it used to fall into branch 5, "ignore".
    /// Both "done" signals funnel into `completeChunk(into:)` and go through **exactly the same bookkeeping**.
    func ingest(_ frame: Data) -> IngestResult {
        var result = IngestResult()
        if case .finished = phase { return result }
        if case .failed = phase { return result }

        if let chunk = TicNoteFrameCodec.voiceChunk(from: frame) {
            if chunk.isEnd {
                completeChunk(into: &result)
                return result
            }

            guard chunk.isWellFormed else {
                // The length byte doesn't match the actual byte count = the frame was truncated (MTU not negotiated, or the peer changed format).
                // 100 % consistent on the real device; if inconsistent, **don't use it as data** -- otherwise everything after is misaligned.
                malformed += 1
                return result
            }

            let offset = Int(chunk.offset)
            if offset < pulled {
                // Duplicate chunk (card resend). 0 times on the real device. Drop it, **don't** count it in pulled.
                duplicates += 1
                return result
            }
            if offset > pulled {
                // Gap. 0 times on the real device. **Accept and advance anyway** (so later data can still be stitched),
                // but `gaps > 0` makes the upper layer fail-closed and reject this audio -- we must not
                // pass off zero filler as real data (same rule in `TicNoteSyncRequest.assemble`).
                gaps += 1
                pending.removeAll(keepingCapacity: true)
                pulled = offset
            }

            chunkReceived += chunk.audio.count
            pending.append(chunk.audio)
            pulled += chunk.audio.count

            while pending.count >= packetBytes {
                // Deliberately copy with `Data(...)` rather than take a slice: a slice's `startIndex`
                // is not 0, and downstream code such as `pkt[0]` / `[UInt8](…)` would trip on it;
                // each packet is 160 B, so the copy cost is negligible.
                result.packets.append(Data(pending.prefix(packetBytes)))
                pending.removeFirst(packetBytes)
            }
            return result
        }

        // ── 3. The card itself reports "this chunk is done": `01 1d 00 <sid> ff ff`
        //
        // ⚠️ **Only counts in `.awaitingChunk` (still waiting for this chunk).** This precondition is not insurance, it is required:
        //    after the chunk end arrives `phase` returns to `.idle` immediately, and the next request is only sent on the caller's next loop iteration
        //    (up to 0.35 s on empty-chunk backoff). In that window the previous chunk's `0x1D` has just arrived --
        //    without checking `phase` we would count **the same completion twice** (`emptyChunks` +1 out of nowhere,
        //    and in bad cases misjudged as "asked past the write pointer").
        if case .awaitingChunk = phase,
           let noticeSID = TicNoteFrameCodec.chunkCompleteNotice(from: frame) {
            // Ignore if sid doesn't match: when probing candidate sids the tail of the previous session drifts in.
            if noticeSID == sessionID { completeChunk(into: &result) }
            return result
        }

        if let receipt = TicNoteFrameCodec.syncFileReceipt(from: frame), !receipt.isOK {
            // In real-time pulling, status != 0 is **recoverable** ("asked too far"/"this range isn't available yet"),
            // unlike the one-shot download semantics -- there a refusal is a real failure, here just back off and retry.
            refusals += 1
            if case .awaitingChunk = phase { phase = .idle }
            chunkDeadline = nil
            overranWithoutSize = (totalBytes == nil)
            result.retryAfterBackoff = true
            return result
        }

        return result
    }

    /// One chunk finished. **Both the chunk-end `0x02` and the card's `0x1D` funnel here**, going through the same bookkeeping.
    ///
    /// (This function was extracted because "previously there was only the chunk-end branch", so losing the chunk end left "permanent silence" as the only outcome.)
    private func completeChunk(into result: inout IngestResult) {
        result.chunkCompleted = true
        if chunkReceived == 0 {
            emptyChunks += 1
            // Past the write pointer (or recording has stopped): only bookkeeping + request backoff, **don't** block the next chunk here
            // (why blocking it would deadlock: see `nextRequest()`).
            overranWithoutSize = (totalBytes == nil)
            result.retryAfterBackoff = true
            if let total = totalBytes {
                // Total length known yet an empty chunk = contradiction. Retrying can't help; after a limited number of chances declare failure,
                // so the caller doesn't spin forever while looking like "recording".
                emptyChunksAfterSize += 1
                if emptyChunksAfterSize >= Self.maxEmptyChunksAfterSize {
                    phase = .failed(
                        "with known total length \(total) the card gave \(emptyChunksAfterSize) consecutive empty chunks"
                        + " (\(pulled) B received)")
                    result.retryAfterBackoff = false
                    return
                }
            }
        } else {
            overranWithoutSize = false
            emptyChunksAfterSize = 0
            consecutiveStalls = 0
        }
        if case .awaitingChunk(_, let end) = phase, pulled < end {
            // Chunk was short (less than the requested amount) -- on the real device this only happens at the end of the file.
            // Not treated as failure: leave `pulled` where the received data stopped and let the upper layer decide.
            result.retryAfterBackoff = true
        }
        chunkDeadline = nil
        phase = .idle
        if let total = totalBytes, pulled >= Int(total) {
            phase = .finished
            result.retryAfterBackoff = false
        }
    }

    // MARK: Stall recovery (chunk end lost)

    /// Is the deadline reached? If so, **invalidate** this chunk, go back to `idle`, and have the caller immediately resend the same range.
    ///
    /// Returns `true` = a chunk was just invalidated (the caller **must** immediately ask again, otherwise this stretch of audio is lost);
    /// returns `false` = not waiting for a chunk, or the deadline hasn't been reached.
    ///
    /// ⚠️ Why the caller does the asking: this type **does not own a clock** (see the note on `chunkDeadline`).
    /// `TicNoteLink.runLiveLoop` calls it once per loop iteration, and `nextFrame(timeout: 1.0)`
    /// guarantees that interval is no more than 1 s ⇒ the deadline is noticed within `chunkTimeout + 1` seconds at the latest.
    ///
    /// ⚠️ Invalidation may directly escalate to `.failed` (too many in a row: the card is dead, not slow) --
    ///    so the caller **must check `phase` right after**, not just `continue`.
    func reclaimIfStalled(now: Date = Date()) -> Bool {
        guard case .awaitingChunk = phase else { return false }
        guard let deadline = chunkDeadline, now >= deadline else { return false }
        abandonStalledChunk()
        return true
    }

    /// Invalidate the current chunk and return to `.idle`, so the next iteration resends.
    ///
    /// ## Where `pulled` backs off to -- getting this wrong would **quietly corrupt the audio**
    /// Not back to `start`, but to **the last whole Opus packet boundary**:
    /// whole packets already emitted from this chunk (`result.packets` → ASR) **must not be requested a second time**,
    /// otherwise the transcript would gain a stretch of duplicated speech. So:
    /// ```
    ///   pulled ← start + (bytes received in this chunk / packetBytes) * packetBytes
    ///   tail that doesn't fill a packet → discard, redo
    /// ```
    ///
    /// This formula incidentally handles the most common case: **all 20 `0x02` arrived, only the chunk end was lost**.
    /// Then "received" is exactly 1600, and backing off gives `start + 1600` -- which correctly advances one chunk,
    /// without even needing a resend. The first 17 chunks of the real-device session at `18:43:03` were exactly like this: 27200 B, not a byte missing,
    /// yet the request for chunk 18 was never sent (`phase` stuck forever in `.awaitingChunk`).
    ///
    /// ## How the card will answer (why a whole-chunk resend is safe here)
    /// The pump is **strictly lockstep** (only one `0x1C` in flight at a time), so invalidation doesn't pile up requests.
    /// If the new range crosses the card's write pointer, the card replies with an empty chunk → `completeChunk` records `emptyChunks`
    /// and requests a 0.35 s backoff -- the same semantics as the normal path, no special case needed.
    ///
    /// ⚠️ A known narrow window (acceptable, on record): after invalidation we immediately resend the next chunk,
    ///    and **the previous chunk's late `0x1D`** may only arrive at that moment -- it ends the new chunk
    ///    with "zero bytes" (costing one extra round + 0.35 s backoff). Not fatal, and doesn't affect audio correctness.
    private func abandonStalledChunk() {
        guard case .awaitingChunk(let start, _) = phase else { return }
        let received = pulled - start
        let wholePackets = Swift.max(0, received / packetBytes)
        pulled = start + wholePackets * packetBytes
        pending.removeAll(keepingCapacity: true)
        chunkReceived = 0
        stalledChunks += 1
        // ★ The criterion is "this chunk had **zero bytes**", not "was invalidated".
        //   Losing the chunk end while all data arrives (`received == 1600`) is the norm, and in that case the line below resets to zero --
        //   otherwise the normal scene of "every chunk loses its chunk end" would be treated as "card hung".
        if received > 0 {
            consecutiveStalls = 0
        } else {
            consecutiveStalls += 1
        }
        chunkDeadline = nil
        if consecutiveStalls >= Self.maxConsecutiveStalls {
            phase = .failed(
                "card had zero bytes for \(consecutiveStalls) consecutive chunks (waiting \(Self.chunkTimeout) s per chunk,"
                + " about \(Int(Self.chunkTimeout * Double(consecutiveStalls))) s without receiving anything); "
                + "\(pulled) B received")
            return
        }
        phase = .idle
    }

    // MARK: Wrap-up

    /// The card reported the **final** size of the whole recording (`fileSize` of `0x17`).
    ///
    /// After that `nextRequest()` closes out by the remainder; once `pulled` reaches `total` it is `finished`.
    /// This is also the only moment it can be certain the pull is complete -- during recording the total length is not known.
    func noteFinalSize(_ bytes: UInt32) {
        if case .failed = phase { return }
        totalBytes = bytes
        overranWithoutSize = false
        if pulled >= Int(bytes) {
            phase = .finished
        } else if case .awaitingChunk = phase {
            // The previous chunk is still in flight: wait for it to return before continuing, don't jump the gun (the card accepts only one in-flight command).
        } else {
            phase = .idle
        }
    }

    /// Manual wrap-up (user pressed stop / the upper layer wants to end the session).
    ///
    /// ⚠️ Unlike `noteFinalSize`: this does **not** claim the total length is known, only "stop requesting new ones".
    /// Bytes already obtained remain valid (`assembledBytes` can be delivered).
    func stopRequesting() {
        if case .finished = phase { return }
        if case .failed = phase { return }
        phase = .finished
    }

    /// Number of bytes still held, **not filling a packet**.
    ///
    /// Normally 0 (chunk length 1600 is an integer multiple of 160), or the 80 B left over at wrap-up.
    /// It is **not** audio: the upper layer only ever receives whole packets. This number is kept for diagnostics
    /// ("missing a packet" and "missing half a packet" are two different things).
    var pendingTailBytes: Int { pending.count }

    /// One diagnostic line (written to `Documents/ticnote-ble.log`).
    ///
    /// `chasing write pointer=yes` is the first handle for investigating "real-time transcription goes silent midway": it means the last request landed
    /// outside the card's write pointer (the card is recording normally, it just hasn't written that far yet), in which case the caller should back off and retry,
    /// rather than declare it dead.
    var diagnosticSummary: String {
        "chunks=\(sentRequests) received=\(pulled)B total=\(totalBytes.map(String.init) ?? "?") "
        + "half-packet tail=\(pending.count) chasing-write-pointer=\(overranWithoutSize ? "yes" : "no") "
        + "gaps=\(gaps) duplicates=\(duplicates) empty chunks=\(emptyChunks) malformed=\(malformed) refused=\(refusals) "
        + "stalls=\(stalledChunks)"
    }
}
