import Foundation

// MARK: - TicNote protocol state machine (pure logic, no CoreBluetooth dependency)
//
// Why the state machine is split from the transport layer:
//
//   1. **Verifiable**. A real-device capture (`ticnote-re/captures/att-stream2.txt`) can be fed in
//      in full, running the whole "list files → chunked read → drop sentinels → assemble → wrap Ogg" pipeline,
//      asserting the output matches the rebuilt artifact byte for byte. This is an end-to-end check that **needs no physical device**,
//      see `tools/selfcheck/main.swift` §18.
//   2. **Testable**. A CoreBluetooth `CBPeripheral` can't be constructed on the command line;
//      once the state machine is welded onto it, this logic can only ever be tested by hand on a real device.
//
// This type is **push-driven** rather than `async` polling:
// each time the caller receives a notify it calls `ingest(_:)`, which returns "which frames still need to be sent next".
// On real devices "one notify = one whole frame" (see the comment at the top of `TicNoteProtocol`),
// so no ring buffer is needed.
//
// For the transport-layer adapter see `TicNoteLink.swift`.

final class TicNoteSession {

    enum Phase: Equatable {
        case idle
        /// Sent `0x1A`, waiting for the list
        case listing
        /// Sent `0x1C`, receiving `0x02` voice frames
        case downloading
        /// List obtained / file fully received
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

    private(set) var phase: Phase = .idle
    /// List result (protocol-agnostic shape)
    private(set) var recordings: [RecorderRecording] = []
    /// Raw list entries (keeps protocol fields, for upper layers to read fileType etc.)
    private(set) var fileEntries: [TicNoteFileEntry] = []
    /// Voice chunks received so far
    private(set) var chunks: [TicNoteVoiceChunk] = []
    /// Number of `0x1C` sent so far (a complete download on a real device is 353)
    private(set) var sentSyncCount = 0
    /// Expected total bytes of this download (`0 == ` unknown)
    private(set) var expectedBytes: UInt32 = 0
    /// The `flag` of that list request (an incrementing sequence number on real devices)
    private(set) var lastListFlag: UInt32 = 0

    // MARK: Internal

    private var plan: [TicNoteSyncRequest] = []
    private var planIndex = 0
    private var sessionID: UInt32 = 0
    /// Accumulation buffer for list pages. The card splits the list into multiple pages pushed one by one (each page <= 7 entries);
    /// this holds the received entries **assembled by offset** —— see `TicNoteFileList.parse` for the protocol.
    private var listEntries: [TicNoteFileEntry] = []

    init() {}

    // MARK: Kickoff

    /// Start listing files. Returns the first frame to write to GATT.
    ///
    /// The real-device request is `01 1A 00 <u32 flag> <u32 since> <u8>`, where `flag` is an incrementing sequence number
    /// and `since` is the card's own RTC. To get everything, pass a very early `since` (what the real device passes is
    /// a trace of 2026-04-11 —— the card's RTC runs about half a year behind real time).
    @discardableResult
    func beginListing(flag: UInt32 = 1, since: UInt32 = 0) -> Data {
        phase = .listing
        lastListFlag = flag
        recordings = []
        fileEntries = []
        listEntries = []
        let payload = TicNoteFileList.requestPayload(flag: flag, since: since)
        return TicNoteFrameCodec.frame(observed: .getFileList, payload: payload)
    }

    /// Start reading one recording. Returns the first `0x1C`.
    ///
    /// The chunk planning for `0x1C` is delegated to `TicNoteSyncRequest.plan`: on a real device 563,520 bytes are cut into
    /// 352 × 1600 + 1 × 320 = **353** chunks, matching the capture count.
    @discardableResult
    func beginDownload(sessionID: UInt32, sizeBytes: UInt32) -> Data? {
        guard sizeBytes > 0 else {
            phase = .failed("size is zero")
            return nil
        }
        self.sessionID = sessionID
        self.expectedBytes = sizeBytes
        self.chunks = []
        self.sentSyncCount = 0
        self.plan = TicNoteSyncRequest.plan(sessionId: sessionID, totalBytes: sizeBytes)
        self.planIndex = 0
        guard let first = plan.first else {
            phase = .failed("empty plan")
            return nil
        }
        phase = .downloading
        planIndex = 1
        sentSyncCount = 1
        return Self.frame(for: first)
    }

    /// `TicNoteSyncRequest.frame` takes fields rather than a struct, so this unifies it in one place.
    private static func frame(for r: TicNoteSyncRequest) -> Data {
        TicNoteSyncRequest.frame(
            sessionId: r.sessionId, start: r.start, end: r.end, flags: r.flags
        )
    }

    // MARK: Advance

    /// Feed in one **complete** inbound frame; returns the frames that still need to be written next (usually 0 or 1).
    ///
    /// Branch order matters:
    ///   1. `0x1A` response → build the list, done;
    ///   2. `0x02` voice frame → accumulate; on a **sentinel** (`offset == 0xFFFFFFFF`) send the next chunk;
    ///   3. `0x1C` receipt with **status != 0** → fail on the spot (an explicit rejection by the card; don't wait for the timeout);
    ///   4. other status pushes → ignore.
    ///
    /// ⚠️ The sentinel check in step 2 **must** happen before "accumulating data". A sentinel is also 90 bytes,
    /// and `[9]` also holds `0x50`, so length and the length byte alone reveal nothing abnormal ——
    /// only `offset == 0xFFFFFFFF` gives it away. Miss it and `assemble` would use
    /// `0xFFFFFFFF` as an offset to lay out the buffer (≈4 GiB).
    func ingest(_ frame: Data) -> [Data] {
        switch phase {
        case .idle, .failed:
            return []

        case .listing:
            // **Paged accumulation** (see the comment on `TicNoteFileList.parse`): the card sends at most 7 entries per page,
            // `offset` says where the first entry of this page sits in the full table, and it is only done once `total` entries are collected.
            // This used to be "one frame is everything"; once there were more than 7 recordings every frame failed to parse → waited until timeout.
            guard let page = TicNoteFileList.parse(frame) else { return [] }
            lastListFlag = page.flag
            if listEntries.count < page.offset {
                // Skipped a page: waiting longer would only yield a misaligned table, so give up right away (fail-closed).
                phase = .failed("list page gap: have \(listEntries.count), next offset \(page.offset)")
                return []
            }
            if listEntries.count > page.offset {
                return []                       // Duplicate page (card resent), ignore
            }
            listEntries.append(contentsOf: page.entries)
            fileEntries = listEntries
            recordings = listEntries.map(Self.recording(from:))
            if listEntries.count >= page.total { phase = .finished }
            return []

        case .downloading:
            if let chunk = TicNoteFrameCodec.voiceChunk(from: frame) {
                if chunk.isEnd {
                    return advancePlan()
                }
                chunks.append(chunk)
                // Stop early once everything is collected; no need to wait for the last sentinel.
                if isByteComplete { phase = .finished }
                return []
            }
            // ★ The card's `0x1C` receipt —— **non-zero means rejection**, and we must give up on the spot.
            //
            // Previously this was ignored along with "all kinds of status pushes". Consequence: the card had already said explicitly
            // "I won't accept this chunk request", yet the app still waited out the timeout based on size
            // (a 49-minute recording means minutes), and finally reported "the device did not respond in time".
            // For real-device samples see the comment on `TicNoteFrameCodec.syncFileReceipt`.
            if let receipt = TicNoteFrameCodec.syncFileReceipt(from: frame), !receipt.isOK {
                phase = .failed(
                    "the card refused the chunk request: status \(receipt.status)"
                    + " (it answered for session \(receipt.sessionId),"
                    + " we asked for \(sessionID))"
                )
                return []
            }
            return []

        case .finished:
            return []
        }
    }

    private func advancePlan() -> [Data] {
        guard planIndex < plan.count else {
            // Sentinel after the last chunk is read —— normal wrap-up.
            if isByteComplete || !chunks.isEmpty { phase = .finished }
            return []
        }
        let req = plan[planIndex]
        planIndex += 1
        sentSyncCount += 1
        return [Self.frame(for: req)]
    }

    /// Whether all data covering `[0, expectedBytes)` has been received.
    ///
    /// The criterion is the **highest byte position received**, deliberately **not** looking at the chunk width:
    /// - Not `chunks.count * 80 == expectedBytes`: that would misjudge as soon as one chunk is out of order or duplicated
    ///   (duplicates over-count, reordering under-counts), while "highest position reaches the end" is immune to both.
    /// - Also no 80-alignment check here: that is `assemble`'s job (anything not 80-aligned is rejected,
    ///   see `TicNoteSyncRequest.assemble`). Checking in both places would make it hard to tell which layer rejected it.
    ///
    /// (There used to be a dead-code line `let width = …; _ = width` here that looked like "should validate by width"
    /// but actually did nothing —— deleted, so the next person doesn't add a wrong check based on it.)
    private var isByteComplete: Bool {
        guard expectedBytes > 0 else { return false }
        var highest: UInt32 = 0
        for c in chunks where !c.isEnd {
            highest = Swift.max(highest, c.offset &+ UInt32(c.audio.count))
        }
        return highest >= expectedBytes
    }

    // MARK: Result

    /// Assembly statistics. For the contract see `TicNoteSyncRequest.assemble`:
    /// any non-zero `gaps` / `conflicts` / `malformed` must refuse delivery.
    func assembled() -> (data: Data, gaps: Int, conflicts: Int, malformed: Int) {
        TicNoteSyncRequest.assemble(voiceFrames: chunks)
    }

    /// Turn the received bytes into an artifact "the system can play directly".
    ///
    /// **fail-closed**: if the statistics are non-zero, the shape doesn't look like Opus, or wrapping Ogg fails,
    /// always throw instead of handing out a file that can't be opened.
    func deliverable() throws -> RecorderClip {
        let r = assembled()
        guard r.gaps == 0, r.conflicts == 0, r.malformed == 0 else {
            throw RecorderLinkError.corrupted(
                "gaps=\(r.gaps) conflicts=\(r.conflicts) malformed=\(r.malformed)"
            )
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
            // ★ Use the `.opus` suffix (reason in `TicNoteWifiSession.deliverable`): the container is the same
            //   Ogg Opus, and `.opus` is the suffix D·NOTE has verified across the whole pipeline; the library whitelist /
            //   duration probing / playback / transcription all recognize it; `.ogg` would make the file vanish from the library.
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

    /// Completion 0…1, computed from the highest byte position received.
    var progress: Double {
        guard expectedBytes > 0 else { return 0 }
        var highest: UInt32 = 0
        for c in chunks where !c.isEnd {
            highest = Swift.max(highest, c.offset &+ UInt32(c.audio.count))
        }
        return min(1.0, Double(highest) / Double(expectedBytes))
    }

    // MARK: Mapping

    private static func recording(from e: TicNoteFileEntry) -> RecorderRecording {
        // `startTime` is also the sessionId —— see the comment on `TicNoteFileEntry`.
        RecorderRecording(
            id: String(e.startTime),
            displayTitle: Self.title(for: e.startDate),
            sizeBytes: Int(e.sizeBytes),
            startedAt: e.startDate,
            sessionID: e.startTime,
            raw: [
                "startTime": Int(e.startTime),
                "fileType": Int(e.fileType),
            ]
        )
    }

    private static func title(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}
