import SwiftUI
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "ticnote.fast-transfer")

// MARK: - Why this page exists
//
// User's original words (2026-10-12):
// ```
// WiFi fast transfer still has issues; refer to V05E's WiFi fast transfer, it will pop up a page, then proceed with WiFi fast transfer,
// Switching to the library now interrupts it, and WiFi fast transfer does not continuously transfer all existing recordings completely,
// Also for existing ones, multi-select operation needs to be added.
// ```
//
// Split into three tasks; this page handles the first one and also resolves the second one:
//
// | User said | Root cause | Landing point |
// |---|---|---|
// | "Need to pop up a page" (like V05E) | We use **bottom-anchored button to start directly**, progress only on that button | This file |
// | "Switching to the library interrupts" | Bottom button is attached to **device segment**, when the segment view is removed, all `@State` disappears | This file (sheet covers the entire TabView, cannot switch) + in `RecorderDeviceView.prepareNextFile` lift the Wi‑Fi suppression lock for the whole batch |
// | "Does not continuously transfer all recordings" | After each transfer, `endRecorderWifiTransfer()` triggers an automatic reconnection, which interacts with the next `connectRecorder(90s/150s)` via `teardownRecorderForReconnect` | `BluetoothCoordinator.ensureRecorderLink` + whole batch single begin/end |
//
// Shape **aligned per item** V05E's `FastTransferSheet`: `NavigationStack + List`,
// Top a stage status row, a column of per‑file progress, bottom a "keep foreground" line, toolbar with cancel/complete.
// Only two parts are not copied, both due to differing hardware on each side:
//   · V05E toggles its own hotspot (`setWifiAP(on:)`) polls `wifiap=1`, TicNote **sends `OPEN_WIFI`
//     then the card disconnects BLE to start AP**, there is no status flag to poll — therefore the stage lacks `.pollingAP`,
//     Instead, **the step of reconnecting BLE between two items** (`.relinking`) is used;
//   · V05E fixes the transfer set with a single `listFiles()`, TicNote's list is on BLE,
//     During the batch the chain is broken, so the transfer set is fixed by the caller **before opening the page** and passed in.

// MARK: - Result of a single fast transfer

/// Result of transferring **one** recording. Used by the popup page and device page to decide the next step.
///
/// ⚠️ Three fields instead of a single `Result`: `savedName` (became none) and `deletedFromCard`
///    (whether the copy on the card was deleted) are **two independent matters** — successful transfer but failure to delete is normal
///    (the card may have been deleted but not responded, see `TicNoteWifiLink.requestDelete`),
///    Combining into a `Bool` would inevitably invert one of them.
struct TicNoteTransferOutcome {
    var savedName: String?
    var failureReason: String?
    /// Interrupted by "stop". **Must be independent of `failureReason`** — the stop pressed by the user
    /// Should not leave a red‑text failure line in the list.
    var cancelled: Bool = false
    var deletedFromCard: Bool = false

    var isSuccess: Bool { savedName != nil }

    static func failed(_ reason: String) -> TicNoteTransferOutcome {
        TicNoteTransferOutcome(savedName: nil, failureReason: reason)
    }
    static let stopped = TicNoteTransferOutcome(savedName: nil, failureReason: nil, cancelled: true)
}

// MARK: - The sole interface between popup page and device page

/// Four tasks the popup page requires the device page to perform.
///
/// ## Why use closures instead of moving `download()` into the model
/// `download()` depends on a large set of `@State` from the device page (`savedNames` / `errors` / `banner` /
/// `connectedLink` / `preferWifi` / `activeFastTransfer` …), moving it away equals moving that page
/// a complete rewrite. The popup page actually only needs four things: **prepare next / transfer one / stop the current one /
/// finalize**. After extracting four closures, neither side's state ownership needs to be changed.
///
/// ## Why not a `delegate` protocol
/// A protocol would require an extra type + a `weak var`. The implementer here is **always**
/// `RecorderDeviceView`'s value (a struct), not reused elsewhere, closures are more direct.
///
/// ⚠️ This struct itself is **intentionally not marked `@MainActor`**: it is constructed in the content closure of `.sheet(item:)`
///    where the isolation context is decided by SwiftUI; adding it to the main type would become
///    "calling a main‑thread‑isolated initializer from a non‑isolated context". What truly needs the main thread are **the four closures
///    type**; therefore `@MainActor` is only applied to the closures.
struct TicNoteTransferDriver {
    /// Before transferring the next item. Return `nil` = can continue; return a string = this item is immediately marked as failed,
    /// the reason is displayed verbatim on this line.
    ///
    /// Why have it return "failure" instead of "retry": this step **reconnects BLE**
    /// (starting from the 2nd item in the batch, the card just finished the previous round and is still in hotspot mode). When it cannot be reconnected
    /// `download()` will fall back to `connectRecorder`'s [90, 150] second timeout ——
    /// which is a full two‑minute silence, the user sees it as "stuck". Here we directly mark it as dead,
    /// causing the loop to **immediately** move to the next item for another try.
    var prepare: @MainActor () async -> String?

    /// Transfer one.
    var transfer: @MainActor (RecorderRecording, @MainActor @escaping (Double) -> Void) async -> TicNoteTransferOutcome

    /// Make **the currently transferring item** stop immediately (as best as possible). Without this, the semantics of "stop" degrade to
    /// "the current item finishes and then does not continue" — while a 49‑minute recording over Bluetooth takes 45 minutes to transfer.
    var cancelCurrent: @MainActor () -> Void

    /// Batch ends (success, failure, or cancellation all count). Used to release the Wi‑Fi suppression lock and refresh the list.
    var finished: @MainActor () async -> Void
}

// MARK: - Single item state

/// The full content of a row in the popup page (same shape as V05E's `FastTransferFileState`).
///
/// ⚠️ `status` does **not include "deleted from card"** — that is an additional flag above the main state (waiting/transfer/saved/failure)
///   an **extra marker**; mixing it into the enum would produce cases where both "delete succeeded" and "save succeeded" can be terminal
///   downstream each time a check is written, you must remember to count both.
struct TicNoteTransferItem: Identifiable {
    let recording: RecorderRecording
    var status: Status = .pending
    var deletedFromCard = false

    var id: String { recording.id }
    var title: String { recording.displayTitle }
    var size: Int { recording.sizeBytes }

    enum Status {
        case pending
        /// Bytes received. Used to draw an inline progress bar.
        case transferring(got: Int)
        case saved(name: String)
        case failed(reason: String)
        /// Skipped by "stop" (not yet reached).
        case skipped
    }

    var isTerminal: Bool {
        switch status {
        case .saved, .failed, .skipped: return true
        case .pending, .transferring:   return false
        }
    }
}

// MARK: - State machine

/// Driver for the fast‑transfer popup page.
///
/// ## Why it belongs to the **popup page** rather than the device page
/// The queue's lifetime = the lifetime of this transfer. If placed in the device page, the device page gets removed (segment switch / card change /
/// `matchedRecorder` becomes nil) the queue disappears — that is exactly the "switch to library interrupts" shape.
/// Placing it in the sheet's `@StateObject`, "this transfer is still alive" and "this page is still present"
/// become the same thing, and during the sheet the user cannot switch segments or tabs.
///
/// ⚠️ **Only one entry point**: call `run()` inside `.task(id: scenePhase == .background)`
///    (copied from V05E). Re‑entry is blocked by `ran` — otherwise `scenePhase` from `.inactive`
///    back to `.active` would start another loop, with two queues writing to the same Wi‑Fi channel simultaneously.
@MainActor
final class TicNoteTransferModel: ObservableObject {

    enum Stage: Equatable {
        case preparing
        /// Between the two: the card just turned off the previous hotspot, and BLE is being reconnected.
        case relinking
        case running
        case stopping
        case done
        case partial(failed: Int)
        case cancelled
        /// Interrupted by switching to background. Separating from `cancelled` is **intentional**: the stop pressed by the user
        /// knows why; "returning to find it stopped" must be explained, otherwise it looks broken.
        case interrupted

        var isFinished: Bool {
            switch self {
            case .done, .partial, .cancelled, .interrupted: return true
            default: return false
            }
        }
        var isBusy: Bool { !isFinished && self != .preparing }

        var title: String {
            switch self {
            case .preparing:      return L10n.TicNoteCard.ftStagePreparing
            case .relinking:      return L10n.TicNoteCard.ftStageRelinking
            case .running:        return L10n.TicNoteCard.ftStageRunning
            case .stopping:       return L10n.TicNoteCard.ftStageStopping
            case .done:           return L10n.TicNoteCard.ftStageDone
            case .partial(let n): return L10n.TicNoteCard.ftStagePartial(n)
            case .cancelled:      return L10n.TicNoteCard.ftStageCancelled
            case .interrupted:    return L10n.TicNoteCard.ftStageInterrupted
            }
        }
        var icon: String {
            switch self {
            case .done:        return "checkmark.circle.fill"
            case .partial:     return "exclamationmark.triangle.fill"
            case .cancelled:   return "stop.circle"
            case .interrupted: return "exclamationmark.triangle"
            default:           return "arrow.triangle.2.circlepath"
            }
        }
        var color: Color {
            switch self {
            case .done:        return .green
            case .partial:     return .orange
            case .cancelled:   return .secondary
            case .interrupted: return .orange
            default:           return .accentColor
            }
        }
    }

    @Published private(set) var items: [TicNoteTransferItem] = []
    @Published private(set) var stage: Stage = .preparing
    /// The position of the currently transferring item in the queue (0‑based). The status line shows "item i/N".
    @Published private(set) var currentIndex = 0
    @Published private(set) var currentID: String?
    @Published private(set) var progress: Double = 0
    /// The channel name displayed under this progress bar. Default Wi‑Fi — this page is the Wi‑Fi fast‑transfer page.
    @Published private(set) var transport = "wifi"
    /// A supplemental line under the stage ("item i/N").
    @Published private(set) var detail: String?
    /// "How long this step has been waiting" timer start; `nil` = not currently waiting.
    ///
    /// ## Why it is needed
    /// `.preparing` (waiting for the card to drop BLE and start the hotspot) and `.relinking` (reconnecting BLE)
    /// Both stages **can be silent for dozens of seconds** — the hotspot activation window itself is 45 s. Before that,
    /// the UI shows only a static notice, so the user sees it as "stuck".
    ///
    /// Source (user's original words, 2026-10-14):
    /// > Wi‑Fi fast transfer "not smooth enough"… [no feedback during waiting]
    ///
    /// ## Why use `Date` instead of a custom timer
    /// Store only a start point, let the view recompute each second with `TimelineView(.periodic)` — UI refresh
    /// handed to SwiftUI, the model has no second `Task` to manage lifecycle, so it won't be cancelled,
    /// and won't leave two concurrent timers during retries.
    @Published private(set) var waitingSince: Date?
    @Published private(set) var cardName = ""
    @Published private(set) var deleteAfter = false

    /// ⚠️ Filled at the moment `run(items:…)` starts, **not** an `init` parameter ——
    ///    Same shape as V05E's `FastTransferModel` (parameter‑less `@StateObject` +
    ///    `.task(id: scenePhase == .background)` calls `run(...)`).
    ///    This is written to avoid "constructing a main‑thread‑isolated class in a non‑isolated view initializer",
    ///    and also ensures "what this page should transfer" has a single entry point.
    private var driver: TicNoteTransferDriver?

    private var cancelRequested = false
    private var interruptedByBackground = false
    /// `run(...)` runs only once. If `scenePhase` flickers, it re‑enters `.task`; without this gate
    /// starts a second queue writing to the same channel.
    private var ran = false

    var total: Int { items.count }
    var failedCount: Int {
        items.reduce(0) { if case .failed = $1.status { return $0 + 1 } else { return $0 } }
    }
    var savedCount: Int {
        items.reduce(0) { if case .saved = $1.status { return $0 + 1 } else { return $0 } }
    }
    var canRetry: Bool { stage.isFinished && failedCount > 0 && !cancelRequested }

    // MARK: Driver

    /// Run the entire queue. **Never return early voluntarily** — each item's failure is swallowed inside the loop,
    /// a bad item should not block the rest (this is exactly the positive requirement of the "not continuously transfer all" issue).
    ///
    /// - Parameter items: the batch to transfer (**snapshot at the moment the page opens**). See `RecorderDeviceView.FastTransferPlan`.
    func run(items: [RecorderRecording],
             cardName: String,
             deleteAfter: Bool,
             driver: TicNoteTransferDriver) async {
        guard !ran else { return }
        ran = true
        // ⚠️ **Only on the first** load. In the retry path, `items` already carry the correct state
        //    (already saved remain `.saved`), unconditional rebuilding would push them back to `.pending`,
        //    so "retry failed items" becomes "transfer the whole batch again".
        if self.items.isEmpty {
            self.items = items.map { TicNoteTransferItem(recording: $0) }
        }
        self.cardName = cardName
        self.deleteAfter = deleteAfter
        self.driver = driver
        stage = .preparing
        // Timing starts from this moment. `.preparing` is the longest wait in the batch:
        // the card must first drop BLE, start the AP's beacon, then we join (see `TicNoteWifiLink`).
        waitingSince = Date()

        for index in self.items.indices {
            // ⚠️ Also check `Task.isCancelled`: switching to background causes SwiftUI to cancel `.task`,
            //   and within the loop only `Task.sleep` can throw `CancellationError` ——
            //   if only `cancelRequested` is checked, this batch would **continue transferring**.
            if cancelRequested || Task.isCancelled {
                markSkipped(from: index)
                break
            }
            // Already transferred (retry path) are not moved again.
            if case .saved = self.items[index].status { continue }

            currentIndex = index
            currentID = self.items[index].id
            progress = 0
            detail = L10n.TicNoteCard.ftProgressLabel(index + 1, self.items.count)

            // From the 2nd item onward, the card just finished the previous round and is switching back to BLE mode — first reconnect it.
            // The first item doesn't need it (the chain is already connected when entering the page), so no flash.
            if index > 0 {
                stage = .relinking
                // Re‑timing: this is **another** wait, added to the first round it will display as
                // "already waited 90 seconds" — a number that scares users away.
                waitingSince = Date()
            }
            let blocked = await driver.prepare()
            if let blocked {
                set(index, .failed(reason: blocked))
                TicNoteDiagLog.log("XFER",
                    "Fast transfer [\(index + 1)/\(self.items.count)] id=\(self.items[index].id) ✗ preparation failed: \(blocked)")
                continue
            }
            stage = .running
            // Enter actual transfer: progress bar takes over, seconds are cleared.
            waitingSince = nil

            set(index, .transferring(got: 0))
            let recording = self.items[index].recording
            let outcome = await driver.transfer(recording) { [weak self] value in
                guard let self else { return }
                // ⚠️ Clamped to 0…1: `ProgressView(value:)` receiving out‑of‑range values will draw a segment outside the bar.
                let clamped = min(max(value, 0), 1)
                self.progress = clamped
                self.set(index, .transferring(got: Int(clamped * Double(max(recording.sizeBytes, 1)))))
            }

            if outcome.cancelled {
                // User pressed stop → the current item is marked as "stopped" (not "failed"), the remaining are marked as "skipped".
                set(index, .failed(reason: L10n.TicNoteCard.cancelled))
                markSkipped(from: index + 1)
                break
            }
            if let name = outcome.savedName {
                set(index, .saved(name: name), deleted: outcome.deletedFromCard)
            } else {
                set(index, .failed(reason: outcome.failureReason ?? L10n.TicNoteCard.notResponding))
            }
        }

        // Finalization must run: the Wi‑Fi suppression lock is released in `driver.finished`,
        // omitting it would cause the card to remain marked as "fast transferring" and never auto‑reconnect.
        await driver.finished()

        if interruptedByBackground {
            stage = .interrupted
        } else if cancelRequested {
            stage = .cancelled
        } else if failedCount > 0 {
            stage = .partial(failed: failedCount)
        } else {
            stage = .done
        }
        currentID = nil
        detail = nil
        // After finalization the seconds must be cleared, otherwise a running timer remains under the "completed" screen.
        waitingSince = nil
        TicNoteDiagLog.log("XFER",
            "Fast transfer summary: \(savedCount)/\(total) succeeded"
            + (failedCount > 0 ? ", \(failedCount) failed" : "")
            + ", stage=\(stage.title)")
    }

    /// Return failed / skipped items to waiting and run again. Already stored items **remain unchanged** —
    /// The purpose of retrying is to "fill in what wasn't downloaded", not to "download again what is already present".
    func retry() async {
        guard canRetry, let driver else { return }
        for index in items.indices {
            switch items[index].status {
            case .failed, .skipped:
                items[index].status = .pending
                items[index].deletedFromCard = false
            case .pending, .transferring, .saved:
                break
            }
        }
        cancelRequested = false
        interruptedByBackground = false
        ran = false
        await run(items: items.map(\.recording),
                   cardName: cardName,
                   deleteAfter: deleteAfter,
                   driver: driver)
    }

    /// When the user presses "Stop", the current item will also be interrupted as best as possible.
    func stop() {
        guard !stage.isFinished else { return }
        cancelRequested = true
        stage = .stopping
        // `.stopping` is not "waiting"; there should be no upward‑counting seconds beneath it —
        // Otherwise it would make "I already pressed Stop" appear as if "it hasn't stopped yet".
        waitingSince = nil
        driver?.cancelCurrent()
    }

    /// Switch to background (copied from V05E's `cancelForBackground`).
    ///
    /// Why we must cancel instead of "let it be": Fast Transfer is **the phone joining the card's hotspot + our own listener on 8081**,
    /// When entering background, the system cuts this off, and the foreground state would only show a pile of
    /// static progress bars. Therefore we explicitly stop and state the reason.
    func cancelForBackground() {
        guard !stage.isFinished else { return }
        interruptedByBackground = true
        stop()
    }

    // MARK: Internal

    private func set(_ index: Int, _ status: TicNoteTransferItem.Status, deleted: Bool = false) {
        guard items.indices.contains(index) else { return }
        items[index].status = status
        if deleted { items[index].deletedFromCard = true }
    }

    private func markSkipped(from index: Int) {
        guard items.indices.contains(index) else { return }
        for i in index..<items.count where !items[i].isTerminal {
            items[i].status = .skipped
        }
    }
}

// MARK: - Popup Page

/// Wi‑Fi Fast Transfer page. Shape aligned with V05E's `FastTransferSheet`.
///
/// ⚠️ As soon as the page appears it **starts automatically** (V05E does the same). When the user taps "Wi‑Fi Fast Transfer" they already express the intent to
///    "transfer now", prompting them to tap "Start" again is an unnecessary step.
struct TicNoteFastTransferSheet: View {

    /// The batch to be transferred (**snapshot at the moment the page opens**).
    let items: [RecorderRecording]
    let cardName: String
    let deleteAfter: Bool
    let driver: TicNoteTransferDriver
    /// Callback on close (clears the upper `@State`, so the next popup is a fresh batch).
    let onClose: () -> Void

    /// ⚠️ Parameterless initializer: loading occurs in `.task` (e.g., `model.run(items:…)`),
    ///    identical to V05E's `FastTransferModel`. A parameterized `init` would end up
    ///    spinning on "constructing an `@MainActor` class inside a view initializer that is not isolated to the main thread".
    @StateObject private var model = TicNoteTransferModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                statusSection
                filesSection
                noticeSection
                if model.stage.isFinished { closeSection }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.TicNoteCard.ftTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        // ⚠️ During transfer **do not allow swipe‑down to dismiss**: when dismissed the sheet is removed and the `@StateObject` goes with it —
        //    The app will quietly stop handling the transfer, and the user will think it is still running. V05E uses the two buttons "Done/Cancel" to achieve the same effect
        //    to reach the same goal; here we also block the swipe‑down gesture.
        .interactiveDismissDisabled(!model.stage.isFinished)
        // Only recognize "entering background". If `scenePhase` itself is used as the id, pulling down Control Center or an incoming call banner (triggering `.inactive`) would be treated as an interruption —
        // when `.inactive` fires, it would be considered an interruption — at that time the app is still running and the transfer hasn't stopped.
        // This implementation and rationale are copied from V05E's `FastTransferSheet`.
        .task(id: scenePhase == .background) {
            guard scenePhase != .background else {
                model.cancelForBackground()
                return
            }
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            await model.run(items: items,
                            cardName: cardName,
                            deleteAfter: deleteAfter,
                            driver: driver)
        }
    }

    // MARK: Section

    private var statusSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.stage.icon)
                    .foregroundColor(model.stage.color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.stage.title).font(.callout.weight(.medium))
                    if let detail = model.detail, !model.stage.isFinished {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    // ★ Waiting seconds. `.preparing` / `.relinking` may silently last dozens of seconds
                    //   (The hotspot‑joining window can be up to 45 s); leaving only a static message would be perceived as a freeze.
                    //   Use `TimelineView` to recompute every second — the model only stores a single start point,
                    //   so there is no second `Task` to worry about cancelling.
                    if let since = model.waitingSince, !model.stage.isFinished {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                            Text(L10n.TicNoteCard.ftWaitingElapsed(seconds))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if model.stage == .running, let id = model.currentID,
                       let item = model.items.first(where: { $0.id == id }) {
                        Text(item.title).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if !model.stage.isFinished {
                    ProgressView().controlSize(.small)
                }
            }
            if model.stage == .running {
                ProgressView(value: min(max(model.progress, 0), 1))
                    .progressViewStyle(.linear)
                Text("\(Int((model.progress * 100).rounded()))% · "
                     + (model.transport == "wifi" ? "Wi-Fi" : "Bluetooth"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(cardName)
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        if !model.items.isEmpty {
            Section(L10n.TicNoteCard.ftFilesCount(model.items.count)) {
                ForEach(model.items) { item in
                    TicNoteTransferRow(item: item)
                }
            }
        }
    }

    @ViewBuilder
    private var noticeSection: some View {
        if !model.stage.isFinished {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.TicNoteCard.ftKeepForeground, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // ★ Explain that system popup in advance.
                    //
                    // Source (user quote on 2026‑10‑14): Fast Transfer "not smooth enough"…
                    // [System popup requires manual confirmation].
                    //
                    // iOS's `NEHotspotConfigurationManager` **will inevitably** present a popup once
                    // "Whether to join the Wi‑Fi network", this popup cannot be bypassed. But "suddenly appears,
                    // not knowing what will happen if you tap" and "was previewed, so you know to tap Join" are two different sensations —
                    // In the former case, users often accidentally tap "Cancel", causing the entire link to fail immediately,
                    // making it look like the feature is broken.
                    Label(L10n.TicNoteCard.ftHotspotPromptNotice, systemImage: "wifi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.TicNoteCard.ftWifiNotice)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var closeSection: some View {
        Section {
            if model.canRetry {
                Button {
                    Task { await model.retry() }
                } label: {
                    Label(L10n.TicNoteCard.ftRetryFailed(model.failedCount),
                          systemImage: "arrow.clockwise")
                }
            }
            Button(L10n.TicNoteCard.ftClose) {
                onClose()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            if model.stage.isFinished {
                Button(L10n.TicNoteCard.ftClose) { onClose() }
            } else {
                Button(L10n.Common.cancel) { model.stop() }
                    .disabled(model.stage == .stopping)
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            if !model.stage.isFinished {
                Button(L10n.TicNoteCard.ftStop) { model.stop() }
                    .disabled(model.stage == .stopping)
            }
        }
    }
}

// MARK: - One Line

private struct TicNoteTransferRow: View {
    let item: TicNoteTransferItem

    private static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.bytes(item.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch item.status {
            case .pending:
                Label(L10n.TicNoteCard.ftStatusPending, systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .transferring(let got):
                let clamped = min(max(got, 0), item.size)
                let frac = item.size > 0 ? Double(clamped) / Double(item.size) : 0
                ProgressView(value: frac)
                    .progressViewStyle(.linear)
                Text("\(Int((frac * 100).rounded()))% · \(Self.bytes(clamped)) / \(Self.bytes(item.size))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .saved:
                HStack(spacing: 6) {
                    Label(L10n.TicNoteCard.ftStatusSaved, systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    if item.deletedFromCard {
                        Text("· " + L10n.TicNoteCard.ftStatusDeleted)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            case .skipped:
                Label(L10n.TicNoteCard.ftStatusSkipped, systemImage: "minus.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
