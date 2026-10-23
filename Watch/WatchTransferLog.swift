import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.watch", category: "transfer-log")

/// One transfer record.
///
/// ★ 2026-10-15 (user: "the top-right corner is the watch's transfer log"): the top-right dot changed from
/// "breathing-light rate" to this page — the breathing light merged into the top-left appearance page (it was always part of
/// appearance), and the freed slot went to something that **really needs its own page**.
///
/// ## Why it's worth recording
/// A watch recording is "lands on the watch first, then transfers to the phone, finally the phone confirms it's stored", and any step in between
/// can stall. The evidence for those three steps used to exist only in `WatchLink`'s two in-memory `Set`s —
/// gone the moment the watch restarts, and "did that one I recorded this morning actually go up" is exactly the question asked after a restart.
/// Persist a copy to disk and that question has an answer.
struct WatchTransferRecord: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        /// Handed to WatchConnectivity for queueing, hasn't left yet.
        case queued
        /// The system has delivered it to the phone-side daemon — but **the phone App hasn't confirmed writing to disk**.
        /// This intermediate state must be shown separately: stalling here is "looks like success but it's not stored".
        case delivered
        /// The phone App confirms it's stored. Only at this step is the watch's local copy deleted.
        case stored
        case failed

        /// For sorting: the more "complete", the further back. Used only for stable ordering at the same instant, never shown.
        var rank: Int {
            switch self {
            case .failed:    return 0
            case .queued:    return 1
            case .delivered: return 2
            case .stored:    return 3
            }
        }
    }

    var name: String
    var bytes: Int64
    /// The time of the most recent state change. The list is in reverse order of it.
    var updatedAt: Date
    var state: State
    /// The failure reason; on successful storing, the text recording the delivery time is assembled by the view itself.
    var detail: String?

    var id: String { name }
    var displayTitle: String { RecordingName.displayTitle(for: name) }
}

/// The persisted ledger of transfer records. **Append-only** (except for the user actively clearing it + the capacity cap).
///
/// ## Why it lives in the watch's own Documents
/// This record is from the **watch's point of view**: the same recording may be "stored" on the watch while on the phone side
/// the user has already deleted it. The two sides' semantics differ, and mixing them in one ledger would eventually fail to reconcile. The watch's copy only answers
/// "did the things I sent out land".
@MainActor
final class WatchTransferLog: ObservableObject {
    static let shared = WatchTransferLog()

    /// The cap. The watch's disk is small, and nobody scrolls past entry 200 to check "did last week's one go up".
    /// Once full, the oldest is dropped — what's dropped is the **record**, not the recording file.
    static let maxEntries = 200

    @Published private(set) var records: [WatchTransferRecord] = []

    private let url: URL

    private struct Payload: Codable { var records: [WatchTransferRecord] }

    private init() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = root.appendingPathComponent("transfer-log.json")
        load()
    }

    // MARK: - Recording entries

    /// Queued successfully. Repeated calls with the same name are ignored (`WatchLink` de-dupes too,
    /// but a retained file being re-queued has to be able to refresh — so "update an existing failed entry" is allowed here).
    func noteQueued(name: String, bytes: Int64) {
        upsert(name: name, bytes: bytes, state: .queued, detail: nil)
    }

    /// `didFinish` came back. `error == nil` ⇒ handed to the phone daemon (`.delivered`),
    /// non-nil ⇒ `.failed` and the reason is recorded — a reason that was originally **completely invisible** on the watch,
    /// where the user only saw "spinning forever".
    func noteFinished(name: String, error: Error?) {
        if let error {
            // `URLError`'s `localizedDescription` is system-flavoured English,
            // but it's the only thing that distinguishes "the other side didn't answer" from "never connected", which is far more useful
            // than a bare "transfer failed", so it's kept.
            upsert(
                name: name,
                bytes: nil,
                state: .failed,
                detail: (error as NSError).localizedDescription
            )
        } else {
            upsert(name: name, bytes: nil, state: .delivered, detail: nil)
        }
    }

    /// The phone confirms it's stored.
    func noteStored(name: String) {
        upsert(name: name, bytes: nil, state: .stored, detail: nil)
    }

    func clear() {
        guard !records.isEmpty else { return }
        records.removeAll()
        save()
    }

    // MARK: - Internal

    /// Update if present, add if not. **Doesn't change old fields other than `name`** (passing nil for `bytes` keeps the original value):
    /// `didFinish`'s callback can't get the file size (the file may already be deleted),
    /// and writing 0 there would put fake information like "0 KB stored" in the list.
    private func upsert(name: String, bytes: Int64?, state: WatchTransferRecord.State, detail: String?) {
        if let index = records.firstIndex(where: { $0.name == name }) {
            records[index].state = state
            records[index].updatedAt = Date()
            records[index].detail = detail
            if let bytes { records[index].bytes = bytes }
        } else {
            records.append(WatchTransferRecord(
                name: name,
                bytes: bytes ?? 0,
                updatedAt: Date(),
                state: state,
                detail: detail
            ))
        }
        // Newer first. At the same instant (say "queued → sent immediately") `rank` provides stable ordering.
        records.sort { ($0.updatedAt, $0.state.rank) > ($1.updatedAt, $1.state.rank) }
        if records.count > Self.maxEntries {
            records.removeLast(records.count - Self.maxEntries)
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        records = payload.records.sorted {
            ($0.updatedAt, $0.state.rank) > ($1.updatedAt, $1.state.rank)
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(Payload(records: records))
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("transfer log save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
