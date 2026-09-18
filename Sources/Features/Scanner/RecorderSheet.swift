import SwiftUI
import Combine
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "recorder.sheet")

/// Non D·NOTE recorder card (currently TicNote) **device page**: recording material list + download.
///
/// ## Page skeleton (2026-10-09 rearranged according to user test feedback, aligned with V05E)
/// ```
/// [Card row]           ← tap = card info (battery / SN / model / general settings / raw response / frames spoken by card)
/// [Recording status row/record button]   ← injected form has only status (button in page header); standalone form includes button
/// [Recording material list]        ← ★ main content of this page
/// [Transfer method]
/// ```
/// Previously, **card info** was placed at the top and the list at the bottom, so opening the device page showed
/// battery/serial number instead of recordings — the user said "the home page should display recording materials like V05E,
/// card info should be shown after connecting and tapping the card". V05E's `DeviceFilesView` is a pure file list,
/// card info is another separate popup (`DeviceSheet`), and we follow that shape here.
///
/// ## Why split into "embeddable page" + "thin-shell popup" two types
/// The same list / download / fast transfer logic needs to appear in two places:
///   · `RecorderSheet` — sheet that pops after tapping a card on the scan page;
///   · `RecordingsView`'s "Device" tab — user selected this card on the main page.
/// Logic exists only once (the `@State` and methods of this type), the two entry points differ only by the outer navigation shell.
/// Previously there was only the sheet form, so selecting TicNote on the main page only showed "Device not connected… scan your D·NOTE"
/// (That sentence is D·NOTE's empty-state copy).
///
/// The entire basis for this page's validity is self‑check §18: real‑device packet capture and full playback passed, even request bytes are reconciled one by one.
/// The start frame of recording control (`startRecording` / `stopRecording`) **has not been verified on a real device** ——
/// Therefore the button is labeled "experiment", and failures will display the reason as‑is.
struct RecorderDeviceView: View {

    @EnvironmentObject private var bluetooth: BluetoothCoordinator
    @EnvironmentObject private var library: Library

    /// Device ledger. **Only needed for unbinding**: after unbinding, remove this card from the user‑visible list
    /// (Same concluding step as D·NOTE's `DeviceSheet.unbindAndRemove()`).
    /// The key is the `peripheral.identifier.uuidString` written during scanning (see `ScannerSheet.connectRecorder`).
    @EnvironmentObject private var configService: ConfigService

    /// User‑assigned name for the card (app‑side alias, **keyed by card identity** — see `RecorderAliasStore`).
    ///
    /// ⚠️ Must monitor it: `recorder.displayName` is a regular computed property, SwiftUI doesn't know it needs to redraw,
    /// so after renaming, the `@Published` here pushes the whole page to refresh.
    @ObservedObject private var aliasStore = RecorderAliasStore.shared

    let recorder: DiscoveredRecorder

    /// Recording session **injected** from the outer layer.
    ///
    /// * `nil` (scan page popup form) — this page manages its own recording control (`ownSession`);
    /// * non-`nil` (main page "Recording" tab form) — recording control is in the **page header**
    ///   on `RecorderControl`, this page only shows status and does not place a second button.
    ///   Two buttons = two optimistic local states = pressing the top or bottom button still says "not recording".
    var session: RecorderSessionModel? = nil

    /// What is the **main content** of this page.
    ///
    /// ## ★ Source (2026-10-14 user quote)
    /// > "When adding a device, do not show recording time, just display device info, refer to V05E's logic
    /// >  Display device info, do not immediately show recordings upon clicking the device; need to show them in Nomily AI
    /// >  in the home page device section instead"
    ///
    /// Split into two sentences:
    ///   * **Tap device** (connect on scan page, tap top‑bar capsule) → shows **how this card is**:
    ///     Name / storage / battery / charging / model / gain / transfer preference.
    ///     This matches V05E exactly — its `DeviceSheet` is pure device info,
    ///     while recording files are in another entry (`DeviceFilesView`).
    ///   * **Home "Recording" tab's "Device" section** → shows **which recordings are on the card**.
    ///
    /// Previously both routes landed on the same "recording‑material‑first" page, so tapping a device immediately presented
    /// a list of recording times — the user wants to see the device itself first.
    ///
    /// ⚠️ **Do not change that home entry**: `RecordingsView` still passes the default `.recordings`.
    ///    The user explicitly said recordings should be shown in the home device section; fixing this place would invert the requirement.
    enum Mode {
        /// Main content = recordings on the card (home "Device" section and historical actions).
        case recordings
        /// Main content = the card's own status (device info page entered by tapping the device).
        case deviceInfo
    }

    /// By default keep historical behavior (recording‑material‑first), only the two "tap device" entry points pass `.deviceInfo`.
    var mode: Mode = .recordings

    /// Its own session model (used only when not injected).
    @StateObject private var ownSession = RecorderSessionModel()

    /// The actually effective session model.
    private var activeSession: RecorderSessionModel { session ?? ownSession }

    /// Page phase.
    ///
    /// ⚠️ **Deliberately no `failed`** (2026-10-09 change). Previously a list read failure would replace the whole page with
    /// an error line + Retry, so the user couldn't even tap the "card" row — that row is the only entry to
    /// "Card info" (battery / serial number / raw card response are inside).
    /// This issue occurred on a real device: the card was busy in a session, a list timeout caused the whole page to become
    /// "Device did not respond within the allotted time.", and the diagnostic info on that screen disappeared as well.
    /// Now failures go through `loadError`, coexisting with the list **side by side**.
    private enum Phase: Equatable {
        case connecting
        case listing
        case ready
    }

    @State private var phase: Phase = .connecting

    /// Reasons for list / connection failures. **Do not replace the page**, just add a line above the list.
    @State private var loadError: String?

    /// Card info popup (battery / serial number / model / raw card response).
    ///
    /// Collapsed by default — in `.recordings` mode the home main content is **recording materials**, and card info is only seen when expanded.
    /// In `.deviceInfo` mode this page itself is device info (same content, see `cardInfoContent`),
    /// so this popup will not be opened again (thus no "popup within popup").
    @State private var showCardInfo = false
    @State private var recordings: [RecorderRecording] = []
    @State private var downloadingID: String?
    @State private var progress: Double = 0
    @State private var errors: [String: String] = [:]
    @State private var savedNames: [String: String] = [:]
    @State private var banner: String?

    /// Whether this card has an available Wi‑Fi high‑speed channel. If not, the switch is not shown (see `fastTransferRow` for rationale).
    ///
    /// TicNote's criterion is "**SN was read**" (hotspot name and password are derived from SN,
    /// see `TicNoteLink.fastTransferCredentials`) — not "card reported credentials missing".
    @State private var fastTransferAvailable = false
    @State private var fastTransferReason: String?
    @State private var preferWifi = false
    /// The channel name displayed under the current progress bar. Default is BLE — cannot default to Wi‑Fi and forget to change.
    @State private var activeTransport = "ble"

    /// The bottom‑anchored "batch Wi‑Fi transfer" button is running.
    ///
    /// ⚠️ 2026-10-12 change of scope: **its owner changed from "that button" to "the batch on the popup page"**.
    ///    Now `prepareNextFile()` sets true, `finishBatch()` sets false,
    ///    no intermediate step flips it — so it is always the same as "this batch is still alive".
    @State private var bulkTransferring = false

    /// ★ The batch that the popup page needs to pass (**snapshot fixed before opening the page**).
    ///
    /// Why a snapshot instead of "recalculate inside the page": after batch runs, the BLE link is broken
    /// (card is in hotspot mode), we **cannot read the list on the card** — mid‑process recalculation would be guesswork.
    /// and the `item` of `.sheet(item:)` happens to be the natural container for "which items are in this batch":
    /// non‑nil = page is present, batch is present; nil = close page.
    @State private var fastTransferPlan: FastTransferPlan?

    /// Whether this batch has already taken the "suppress recorder auto‑reconnect" lock (see `prepareNextFile`).
    @State private var batchHoldsWifiLock = false

    /// ★★★ The Wi‑Fi fast‑transfer channel **shared** by the whole batch.
    ///
    /// ## Why a single instance for the whole batch is required
    /// Session (listening on 8081 + joined hotspot + WebSocket connection + cached file list) **is attached to the instance**.
    /// Previously each item called `link.fastTransfer` — which is a **computed property that creates a new object each time**
    /// (`TicNoteLink.fastTransfer`), so each item cold‑started from scratch:
    /// start listening → `OPEN_WIFI` → card drops BLE to start hotspot → join hotspot → wait for card to connect.
    /// In real‑device logs the second entry failed at this step ("after joining, the card never connected", waited the full 45 s window),
    /// the user's perception is exactly "**each segment requires reconnecting Wi‑Fi**".
    ///
    /// Now the whole batch calls `beginBatch()` once and `endBatch()` once, with each item only executing file commands in between.
    @State private var batchFastTransfer: (any RecorderFastTransfer)?

    /// This batch has attempted to "establish session" several times. **Limit 2** — see `prepareNextFile`.
    @State private var batchOpenAttempts = 0

    /// **The Wi‑Fi channel currently running**. Used by the popup page's "stop" —
    /// `cancel()` can only be accessed by whoever holds this instance (`link.fastTransfer` creates a new
    /// `TicNoteWifiLink` each time, the link itself is not a persistent object).
    @State private var activeFastTransfer: (any RecorderFastTransfer)?

    /// ★ Multi‑select mode (user request: "need to add multi‑select operation").
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []

    /// The `Identifiable` wrapper required by `.sheet(item:)`.
    ///
    /// Why not use `[RecorderRecording]?` directly as the item: an array is not `Identifiable`,
    /// and using `.sheet(isPresented:)` plus another `@State` array,
    /// "whether the page is present" and "which items are in this batch" become two independent states ——
    /// closing the page may miss clearing one, so the next popup shows the previous batch.
    private struct FastTransferPlan: Identifiable {
        let id = UUID()
        let items: [RecorderRecording]
    }

    /// ★ **When the bottom‑anchored Wi‑Fi fast‑transfer button appears** (2026-10-10 second revision, per latest user specification).
    ///
    /// ## History leading up to this point (two rounds, scope corrected by the user themselves)
    ///
    /// | Round | Action | User reaction |
    /// |---|---|---|
    /// | 1 (original) | as long as `fastTransferAvailable` it **stays** at the bottom | "Do not pop WiFi fast‑transfer on all pages" |
    /// | 2 (my change) | appears **only** when Bluetooth auto‑transfer fails/times out | "WiFi fast‑transfer disappeared again" |
    /// | 3 (current) | **appears after recording and stays until all pending downloads on the card are transferred** | —— |
    ///
    /// The second round erred by interpreting "do not pop everywhere" as "almost never appear": on a real device all five recordings
    /// were transferred via Bluetooth successfully, so that button **never appeared** (`/tmp/t4.log` contains `WIFI`
    /// tag on line 0). Yet it is actually the entry for **user‑initiated channel selection**, and should not be decided by Bluetooth success.
    ///
    /// ## Current criterion: `recorded && card has pending downloads`
    ///
    /// * **`wifiFallbackArmed`** (`@AppStorage`): after recording (`isRecording` true→false)
    ///   set to true — marks that the "user has used the recording feature", also signals "they need batch transfer";
    /// * **`wifiFallbackNeeded`** (derived, do not write directly): `armed && has pending downloads`.
    ///
    /// Thus: never recorded → never appears (satisfies "do not pop on all pages");
    /// recorded → appears and **stays**, until pending downloads on the card are cleared.
    ///
    /// ⚠️ Use `@AppStorage` instead of `@State`: the user wants "persistence". `RecorderSheet`
    ///    is rebuilt each time it opens, and `@State` would cause it to disappear when it retreats.
    @AppStorage("ticnote.wifi_fallback_armed") private var wifiFallbackArmed = false

    /// Derived value: whether it is currently shown. **Only written by `refreshWifiFallback()`**.
    @State private var wifiFallbackNeeded = false

    /// `connectAndList()` is running. **Re‑entrancy guard** (same rule as V05E's `guard !model.isLoading`).
    ///
    /// Without it, "link reconstruction" + "recording stop" + "delete‑then‑relist" would overlap in a short time and
    /// emit several rounds of `0x1A`, sharing a single command lock — resulting in **each round waiting the full 8 s before timing out**,
    /// the user repeatedly sees "Device did not answer in time".
    @State private var isReloading = false

    /// ★ The session ID of the recording that should **auto‑transfer** after stopping (taken from the `0x18` pushed by the card at start).
    /// `nil` = nothing to auto‑transfer this time (recording start failed / already transferred).
    @State private var autoTransferSessionID: UInt32?

    /// ★ Auto-delete recordings on the card after transfer (a user-requested feature controlled by the card's settings switch).
    /// Use `UserDefaults` instead of the card's settings — the card's firmware does not have this switch;
    /// This is an **App-side behavior**: send a delete command after successful download.
    @AppStorage("ticnote.delete_after_transfer") private var deleteAfterTransfer = false

    /// Pending deletion recordings (swipe to delete → confirmation dialog).
    @State private var pendingDelete: RecorderRecording?

    /// The link held after successful connection. Recording control goes through it (`startRecording` / `stopRecording`
    /// is **required by the protocol**, dynamically dispatched on `any RecorderLink` — see the lesson in self-check §21.5).
    @State private var connectedLink: (any RecorderLink)?

    // A **mirror** of the session state ─────────────────────────────────────────────────
    //
    // ⚠️ Why a mirror instead of `@ObservedObject`: `activeSession` may be injected from the outer layer,
    //    or it may be created by this view itself (`ownSession`), while `@ObservedObject` must
    //    **at compile time** bind to a specific property. Bridge it with `.onReceive(session.$x)`,
    //    and the two paths are unified, so the list logic below doesn't need a single change.
    @State private var isRecording = false
    @State private var recordNotice: String?
    @State private var recordError: String?

    /// Is it in the "injected" form (with the recording button in the header of the main page).
    private var isEmbedded: Bool { session != nil }

    /// The most recent card status read (battery level, etc.). `nil` = not read yet.
    ///
    /// Unlike `isRecording`, this is **real data**, not an optimistic state: `readDeviceInfo` only sends a read command
    /// (plus one idempotent binding frame; see `TicNoteLink.readDeviceInfo` for the rationale), so whatever we get is what we get.
    @State private var deviceInfo: RecorderDeviceInfo?
    @State private var isReadingDeviceInfo = false
    @State private var deviceInfoError: String?

    // ★ Live battery level / charging status (2026-10-14)──────────────────────────────────
    //
    // ## Why we can't just read `deviceInfo`
    // User's original comment:
    // > "The charging status is still not syncing; it needs adjustment and optimization."
    //
    // `deviceInfo` is a **snapshot read once**, only updated when "opening card info", "pull-to-refresh", or "entering the page when
    // the cache is empty". However, the card **continuously reports** these two fields — the first byte of the `0x09` response packet
    // (charging flag) and the last byte (battery level) continuously refresh `TicNoteLink.lastBatteryReading`.
    // Keep-alive heartbeats send one message every 20 seconds, and during recording, one message per second (1 Hz). Thus, "not synced" doesn't mean data hasn't arrived,
    // it means **the UI isn't fetching it**.
    //
    // ## Why use `activeSession` instead of directly subscribing to `TicNoteLink`
    // That live value is already maintained by someone:`RecorderSessionModel.cardWatchTask` reads once per second
    // Protocol layer cache (`pushedBatteryPercent` / `pushedChargingState`), **zero BLE round trips**.
    // This is exactly the same logic that allows V05E's `DeviceSheet` to update in real time ——
    // Over there, `@ObservedObject var client` is directly bound to `DnoteClient`'s `@Published`.
    // Here we don't recreate a subscription:`RecorderDeviceView` gets the session model
    // (The injected `session` or the self‑owned `ownSession`) is the sole source.
    //
    // ## Why use `onReceive` to persist into local `@State`
    // In injected mode, `session` is the outer `@StateObject`; this view **does not** observe it,
    // so reading its properties does not trigger a redraw. `onReceive` moves the published value into local state,
    // so both modes (injected / self-held) work correctly.
    @State private var liveBattery: Int?
    @State private var liveCharging: Bool?

    /// Battery display logic: **live value takes priority, snapshot is the fallback**.
    ///
    /// Why the live value is never older than the snapshot: the `0x09` response sent by `readDeviceInfo()` itself
    /// is also written into `lastBatteryReading` (see inbound handling in `TicNoteLink`),
    /// so the "live value" is always at least as new as the snapshot. The snapshot is only useful when **no response has ever been received**
    /// such as when the link has just been established or keep‑alive hasn't jumped yet.
    private var shownBatteryPercent: Int? { liveBattery ?? deviceInfo?.batteryPercent }

    /// The charging status to display on the UI. Pass through the three states as-is, **no `?? false`** —
    /// `nil` means "unknown"; coercing it to `false` would incorrectly assert "not plugged in" for the user.
    private var shownCharging: Bool? { liveCharging ?? deviceInfo?.isCharging }

    // Unbind device (2026-10-12)────────────────────────────────────────────────
    //
    // The three states are kept separate because to the user they are **three different things**:
    //   · `showUnbindConfirm` —— Not done yet, waiting for the user to confirm (destructive actions must have this step);
    //   · `isUnbinding`        —— Frame sent out, waiting for the card to acknowledge (the UI must show a spinner, and **repeat taps are forbidden**);
    //   · `unbindNotice`       —— The result (one line each for success/failure, with the cause on failure).
    // If merged into one state, "unbinding in progress" and "unbind failed" would look identical — and the user must be told about the latter,
    // otherwise they would think the card has already been handed over.
    @State private var showUnbindConfirm = false
    @State private var isUnbinding = false
    @State private var unbindNotice: String?

    var body: some View {
        content
            .task { await enterPage() }
            // ★ Card status **is only read when the card info is opened** (user's original words: "Don't read the device every time it's tapped").
            //   Previously `connectAndList` unconditionally did one read at the end —— on-device stats counted `readDeviceInfo`
            //   being called 29 times, while the flows that actually need it (start recording / download) were only 20.
            //   Now it's three rules: entering the page only consumes the cache (see `seedFromCaches`), a real read only when the dialog is opened,
            //   **plus one read right on entry in the `.deviceInfo` mode** (see the comment on `enterPage` for that one
            //   —— the entire content of that page is the card status, so not reading it would leave a hole).
            .onChange(of: showCardInfo) { open in
                guard open, deviceInfo == nil else { return }
                Task { await readCardStatus() }
            }
            .onReceive(activeSession.$isRecording) { isRecording = $0 }
            .onReceive(activeSession.$notice) { recordNotice = $0 }
            // ★ Bring in the two **continuously updating** battery / charging statuses from the session.
            //   `cardWatchTask` reads the protocol-layer cache once per second (zero I/O), so plugging or unplugging the charging cable
            //   will deliver the new value here within at most 1 second — no need for the user to tap refresh again.
            //   See the comment for `liveCharging`.
            .onReceive(activeSession.$cardBatteryPercent) { liveBattery = $0 }
            .onReceive(activeSession.$cardCharging) { liveCharging = $0 }
            // ★ Once the link is reconnected, automatically refresh the list.
            //
            // When disconnected, `connectAndList()` sets `loadError` to "Not Connected" and clears the list;
            // After the App reconnects the card in the background, if no one notifies this page, it will **forever stay on**
            // "Not Connected + Try again" —— what the user sees is "it reconnected itself but the page"
            // is still broken, I still have to tap it again", which is exactly what they complained about.
            //
            // Observe `peripheral.identifier` instead of `recorderLink` itself:
            // `any RecorderLink` is not Equatable, so we can't get the equality needed for `onChange`;
            // UUID is. And when the identifier changes, it means "a new link has been established", which is exactly the time to reload the list.
            .onChange(of: bluetooth.recorderLink?.peripheral.identifier) { newID in
                guard newID == recorder.id else { return }
                // ⚠️ **Do not re-list during fast transfer** (added 2026-10-12). In batch fast transfer, each card that finishes transmission
                //    disconnects BLE, and before the next one starts `ensureRecorderLink` reconnects it ——
                //    At that moment the `identifier` changes from nil back to its original value, triggering a list refresh here,
                //    and it immediately needs to send `OPEN_WIFI`, both competing for the **same command lock**.
                //    Stacking dozens of these causes noticeable slowdown. The finalization (`finishBatch`) already
                //    re-lists once, so skipping it won't make the list outdated.
                guard !bulkTransferring else { return }
                // ⚠️ `showsLoading: false` — During link reconstruction, the list often still holds
                //    the previous content (same card); flashing the entire page as "Reading recording..." is a pure regression.
                Task { await connectAndList(showsLoading: false) }
            }
            .onReceive(activeSession.$alert) { alert in
                // In injected mode, errors are displayed by the outer button's alert — this page no longer repeats them,
                // otherwise the same failure would trigger two alerts (one in the header, one in the page).
                guard !isEmbedded else { return }
                recordError = alert?.body
            }
            .onChange(of: isRecording) { nowRecording in
                // Recording stopped → the just-saved recording **must be reloaded** to appear
                // (same logic as V05E's `onChange(of: client.lastDeviceInfo?.isRecording)`
                // is the same: stopped → refresh).
                // Only handle true→false; the list is hidden when recording starts, so no refresh needed.
                guard !nowRecording else {
                    // When starting recording: remember this recording's session ID -- after stopping, use it to locate precisely
                    // "The just-recorded entry" automatically transferred (no longer requires user to manually tap upload).
                    // ⚠️ It may still be unavailable (when `isRecording` flips true, `0x18` may not have arrived yet),
                    //    So the stop-recording branch will fetch it again as a fallback.
                    autoTransferSessionID = connectedLink?.lastSessionID ?? autoTransferSessionID
                    return
                }
                // // Fallback: anything not captured at the start of recording has already been reported by now.
                if autoTransferSessionID == nil { autoTransferSessionID = connectedLink?.lastSessionID }
                // ★★ `showsLoading: false` —— This line is the one the user complained about:
                //
                //   Why does the "Reading recording..." page appear after recording ends?
                //
                //   After stopping recording, re-listing **should not fill the entire screen**: the user has just finished recording and is looking
                //   at that freshly created recording entry. Replacing it with "Reading recording..." at this moment is the worst possible timing.
                //   The list already has content (the old one), so an in-place update is sufficient.
                Task { await connectAndList(showsLoading: false) }
                // ★★ Recording finished → **arm** the bottom Wi-Fi fast-transfer entry (user's wording: "only appears after a recording
                //    finishes and stays"). This only sets the flag; whether it is actually shown is decided by `refreshWifiFallback()`
                //    based on "does the card still have anything not yet downloaded" -- see `wifiFallbackArmed`.
                //
                //    ⚠️ Placing it **after** `connectAndList` but **before** assignment has no effect:
                //      The value is `@AppStorage`, and `refreshWifiFallback()` will recalculate it again after listing.
                wifiFallbackArmed = true
                refreshWifiFallback()
                // ★ Auto-transfer: Users want "auto-upload after recording", not having to tap upload after recording.
                if let sid = autoTransferSessionID {
                    autoTransferSessionID = nil
                    Task { await autoTransfer(sessionID: sid) }
                }
            }
            .alert(
                L10n.DeviceFiles.deleteRecording,
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                presenting: pendingDelete
            ) { recording in
                Button(L10n.Common.delete, role: .destructive) {
                    pendingDelete = nil
                    Task { await deleteFromCard(recording) }
                }
                Button(L10n.Common.cancel, role: .cancel) { pendingDelete = nil }
            } message: { recording in
                Text(L10n.DeviceFiles.deleteRecordingMessage(recording.displayTitle))
            }
    }

    // MARK: body

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .connecting:
            status(L10n.TicNoteCard.connecting, systemImage: "antenna.radiowaves.left.and.right")
        case .listing:
            status(L10n.TicNoteCard.readingRecordings, systemImage: "list.bullet")
        case .ready:
            switch mode {
            case .recordings: list
            case .deviceInfo: deviceInfoPage
            }
        }
    }

    /// The main content of `.deviceInfo` —— **the same body** as the popup when opening the card.
    ///
    /// Why not make a copy: the five sections in `cardInfoSheet` (name / storage / battery / gain / transmission preferences)
    /// have three that depend on the link and two that consume local storage; copying would duplicate "which section depends on what" ——
    /// leading to divergence sooner or later. Here we only swap the shell (no additional `NavigationStack` and Done button,
    /// which is the responsibility of `RecorderSheet`'s thin shell); the body shares `cardInfoContent`.
    private var deviceInfoPage: some View {
        List {
            cardInfoContent
        }
        .listStyle(.insetGrouped)
        // The secondary confirmation and prompts for unbinding **must be placed on this page**: in the popup form, they are placed in
        // `cardInfoSheet`, but this form does not open that popup at all. If moved here,
        // the user would tap to unbind and nothing would happen (on a real device, it looks like "the button is broken").
        .alert(L10n.TicNoteCard.unbindConfirmTitle, isPresented: $showUnbindConfirm) {
            Button(L10n.TicNoteCard.renameCancel, role: .cancel) {}
            Button(L10n.TicNoteCard.unbindConfirmAction, role: .destructive) {
                Task { await unbindCard() }
            }
        } message: {
            Text(L10n.TicNoteCard.unbindConfirmMessage)
        }
    }

    private func status(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Label(title, systemImage: systemImage)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The **body of the Device tab = the recording materials on the card** — the same shape as V05E's `DeviceFilesView`.
    ///
    /// The card's own info (battery / serial number / raw reply / what the card said) **is not on this page**,
    /// tucked into the `cardInfoSheet` that opens after tapping `cardRow`. Same rationale as V05E:
    /// what you open this page to see is always "which recordings are on the card", while battery/serial number are **diagnostic info** ——
    /// seeing them once per connection is enough; putting them in the body would squeeze the material off screen.
    private var list: some View {
        List {
            // ① The card itself: one row, with details upon expansion.
            cardRow

            // ①b ★ Auto-reconnect progress.
            //
            // Place it **on the same row as the card**, not in the footer: these two lines refer to the same thing
            // ("What's the status of this card now"), while the main body of this page is the recording material —
            // If the reconnection prompt sinks to the bottom of the list, the first screen the user sees is still "Not connected".
            //
            // ⚠️ The pill in the top bar (`ConnectionPill`) is also showing the same thing, but that pill
            //    is squeezed into the top-left corner by the nav bar on the main page, with tiny text; the device page saying it again isn't redundant ——
            //    the user report of "having to keep tapping reconnect" happened on **this page**, and this is also the page they're staring at.
            if let state = bluetooth.recorderReconnectState {
                reconnectRow(state)
            }

            // ② Recording control: **Both states only show status + stopwatch; the record button is removed.**
            //
            // ★ 2026-10-12 Modified per user request. User's original words:
            //   "Remove the 'Record On The Card' that appears after clicking a device; the recording button on the home page is sufficient."
            //
            //   · **Home page** (the injected form of `RecordingsView`, `isEmbedded == true`): the record button is
            //     the `RecorderControl(model:)` at the top of the page (next to the Device / Library toggle),
            //     this page has always shown only the status — **unchanged**.
            //   · **The standalone page that pops up when a device is tapped** (`RecorderDeviceSheet`, `isEmbedded == false`):
            //     it used to have a big round button with the caption `Record on the card` underneath — **now removed**.
            //
            //   So the recording entry point across the whole App **is down to just the one on the home page**, and there's no longer a chance of "two places both being able to start recording"
            //   messing up the state machine.
            //
            //   The implementation of `recordSection` (the big round button) remains in the file, but **it currently has no call sites** ——
            //   It is kept to make rollback easy; see its own doc comment.
            recordingStatusRow

            // ②b ★ Transfer status ("Transferring recording…" + progress + channel).
            //
            // Placed right after the recording status row — these two lines represent **mutually exclusive states** (stuck in recording / currently transmitting),
            // so placing them together prevents users from conflating them (which is exactly what they were asking about this time).
            transferStatusRow

            // 3. Read failure adds **only one more line**, it doesn't push the whole page away — see the comment in `Phase`.
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button(L10n.Common.tryAgain) { Task { await connectAndList() } }
                }
            }

            // ④ One-time receipt (store in database, etc.).
            if let banner {
                Section { Text(banner).font(.callout) }
            }

            // ⑤ Recorded material — the true main body of this page.
            recordingsSection
        }
        .listStyle(.insetGrouped)
        // Pull-to-refresh gesture **comes with its own spinner** (the system one); stacking another "Reading recordings…" layer on the page causes two progress indicators to clash. Hence, we explicitly avoid a full-page loading state here.
        // 
        //
        // ★ This is the **only** refresh path that also reads the card status (`refreshDeviceInfo: true`) —
        //   Pull-to-refresh is an explicit user intent (he wants "the latest now"), which is completely different from "reading on page entry".
        .refreshable { await connectAndList(showsLoading: false, refreshDeviceInfo: true) }
        .sheet(isPresented: $showCardInfo) { cardInfoSheet }
        // ★ The **popup page** for Wi-Fi quick transfer (user request: "It pops up a page, then comes the Wi-Fi quick transfer").
        //
        // Use `.sheet(item:)` instead of `.sheet(isPresented:)`: `item` handles both
        // "whether the sheet is present" and "which items are in this batch" simultaneously; setting it to nil on dismissal clears both.
        // The loop and state within the sheet reside in `TicNoteTransferModel` (`@StateObject`),
        // whose lifetime equals that of the current transfer — this is the correct fix for "interrupted when switching to the library".
        .sheet(item: $fastTransferPlan, onDismiss: { fastTransferPlan = nil }) { plan in
            TicNoteFastTransferSheet(
                items: plan.items,
                cardName: recorder.displayName,
                deleteAfter: deleteAfterTransfer,
                driver: makeTransferDriver(),
                onClose: { fastTransferPlan = nil }
            )
        }
        // ⑥ Transfer method —— ★ Sticky at the bottom, no longer scrolls with the list (previously you had to scroll past all recordings to see it,
        //    so users thought the feature was gone). Also changed from a "switch" to a **button**:
        //    The old implementation was a Toggle; tapping it just flipped a bool with no UI change ——
        //    the "tapping to enable WiFi Fast Transfer does nothing" report was about this.
        .safeAreaInset(edge: .bottom) { fastTransferBar }
    }

    /// Card row. Tap to view card details (battery / serial number / model / raw response / card's spoken words).
    ///
    /// Battery level is intentionally kept on this line (not hidden in the popup): it's the only card status users glance at daily.
    private var cardRow: some View {
        Section {
            Button {
                showCardInfo = true
            } label: {
                HStack(spacing: 12) {
                    // ★ Stack a lightning bolt on the battery corner while charging. This line is the **only one you'll glance at daily**
                    //   card status (see this property's documentation). "Plugged in" and "battery depleted" are two completely different
                    //   scenarios; you shouldn't need to open the details to know which one it is.
                    //
                    // ⚠️ Only appears when charging is confirmed: `nil` (not read) adds nothing —
                    //    There's no room for "unknown" here, so don't use a symbol to imply it.
                    //    The confirmed value can be read verbatim in the detail view (`chargingText`).
                    //
                    // ★ 2026-10-14: Switched to reading `shownCharging` (live value preferred).
                    //   Previously it read `deviceInfo?.isCharging` —— a snapshot that only updates after a manual refresh,
                    //   so this lightning bolt didn't appear when plugged in, and what the user saw was "charging not synced".
                    Image(systemName: batterySymbol)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 26)
                        .overlay(alignment: .bottomTrailing) {
                            if shownCharging == true {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.green)
                                    .offset(x: 4, y: 1)
                            }
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(recorder.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(cardSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Subtitle for the card row: model + serial number. The SN is the key for deduplication (`deviceSerial`),
    /// so it is always displayed here, not as a "hidden technical detail".
    private var cardSubtitle: String {
        "\(recorder.modelName) · \(recorder.identityText)"
    }

    /// ★ Auto-reconnection progress line.
    ///
    /// The user's original complaint was "It's not smooth enough and requires constant tapping to reconnect" — the issue isn't that it "can't connect,"
    /// but that **the interface stays silent during reconnection**: a spinner running for two minutes and an unresponsive button
    /// look identical on screen, so the user just keeps tapping. The sole purpose of this line is to fill that silence,
    /// while also clarifying "where it's currently stuck," so the user knows whether to wait (a few seconds for the fast path) or to bring the card closer
    /// (the scanning path is waiting for broadcasts; in practice, broadcast intervals can reach 152 seconds).
    ///
    /// ⚠️ **No "Cancel" or "Retry" buttons here**: automatic reconnection is already performing exponential backoff retries,
    ///    adding a manual retry button would effectively codify the "keep tapping to reconnect" behavior into the feature.
    ///    If intervention is truly needed, the user can bring the card closer or short-press to wake it; this is documented in the footer.
    @ViewBuilder
    private func reconnectRow(_ state: BluetoothCoordinator.RecorderReconnectState) -> some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.attempt <= 1
                         ? L10n.TicNoteCard.reconnecting
                         : L10n.TicNoteCard.reconnectingAttempt(state.attempt))
                        .font(.callout)
                    Text(state.usingFastPath
                         ? L10n.TicNoteCard.reconnectingFastPath
                         : L10n.TicNoteCard.reconnectingScanning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text(L10n.TicNoteCard.linkDropped)
                .font(.caption2)
        }
    }

    /// The recording material on the card.
    ///
    /// ## ★ Oct 10, 2026: Revised scope: recordings **no longer push the entire page out**
    ///
    /// The first branch here used to be `if isRecording { Section { Text(recordingInProgress) } }`
    /// — The entire list disappears during recording, leaving only the message "Recording in progress; the file list can only be read after stopping the recording." on the page.
    ///
    /// User's original comment:
    /// > "Shouldn't it say the recording is being transmitted? Why does it prompt that the card is stuck recording, along with transmission progress, etc.?"
    ///
    /// He was importing at the time, but only saw this sentence (back then "stuck in recording" was a false alarm caused by downloading shards,
    /// see the root cause in `TicNoteLink.isPullingShards`). Even if it was **actually** recording, removing the whole page is still wrong:
    /// the user can't even see what's on the card, and the progress bar for the transfer disappears as well.
    ///
    /// Now changed to **list retention** (`runListPass` already returns early during recording, keeping the previous list,
    /// which is better than a blank screen). Each row is made unclickable by `.disabled(… || isRecording)` in `row(_:)`,
    /// and the phrase "Why is the list not updating" is downgraded to **footer**.
    @ViewBuilder
    private var recordingsSection: some View {
        if recordings.isEmpty, loadError == nil {
            Section {
                Text(L10n.TicNoteCard.noRecordingsYet)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(recordings) { row($0) }
                    .onDelete { offsets in
                        deleteRecordings(at: offsets)
                    }
            } header: {
                Text(L10n.TicNoteCard.recordingCount(recordings.count))
            } footer: {
                // Prioritize saying "why this list is outdated" when recording — it's far more important than "which lane to take".
                if isRecording {
                    Text(L10n.TicNoteCard.recordingInProgress)
                        .font(.caption2)
                } else {
                    Text(preferWifi
                         ? L10n.TicNoteCard.wifiFooter
                         : L10n.TicNoteCard.bleFooter)
                }
            }
        }
    }

    /// ★ Wi-Fi Quick Transfer entry at the bottom (`safeAreaInset(edge: .bottom)`).
    ///
    /// ## When does it appear? (Revised 3 times on 2026-10-10, per latest user feedback)
    ///
    /// User's original statement (two rounds): "Only pop up at the bottom after recording is complete" → "Only appear and persist after recording is complete".
    /// So the gate is `wifiFallbackNeeded`, and its definition consists of just one sentence:
    /// **Audio has been recorded (`wifiFallbackArmed`) and there are still items on the card that haven't been downloaded** (see `refreshWifiFallback()`).
    ///
    /// So the three states become:
    /// 1. **No recording yet** (the normal case, e.g. just popping in to look) → render nothing;
    /// 2. Recorded and still has pending downloads → **button**: goes to the fast transfer page; a "Select" button beside it enters multi-select;
    /// 3. Recorded, has pending downloads but fast transfer is unavailable → show the reason (e.g. SN not read);
    /// 4. **Multi-select mode** → switch to `selectionBar` (N selected / Select All / Cancel / Send Selected).
    @ViewBuilder
    private var fastTransferBar: some View {
        if isSelecting {
            selectionBar
        } else if wifiFallbackNeeded, fastTransferAvailable {
            fastTransferReadyBar
        } else if wifiFallbackNeeded, let reason = fastTransferReason {
            VStack(alignment: .leading, spacing: 2) {
                Label(L10n.TicNoteCard.fastTransferUnavailable, systemImage: "wifi.slash")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    /// "Pending" = **Not yet submitted**.
    ///
    /// ★ Failed ones **stay inside** (`errors` no longer excluded) — they are the batch users most want to retry,
    ///   removing them from the count would make the button show "0 sent" while still hanging, which is more confusing than not showing it.
    private var pendingRecordings: [RecorderRecording] {
        recordings.filter { savedNames[$0.id] == nil }
    }

    /// Checked in the multi-select. **Returned in list order** (not the hash order of `Set`) —
    /// The transmission order must match the order the user sees, otherwise "the 3rd item failed" won't correspond correctly.
    private var selectedRecordings: [RecorderRecording] {
        recordings.filter { selectedIDs.contains($0.id) }
    }

    /// Whether all items are selected. Use `>=` instead of `==`: the list is lightly polled every 3 s to refresh the batch,
    /// so `selectedIDs` may temporarily retain IDs that are no longer in the list.
    private var allRecordingsSelected: Bool {
        !recordings.isEmpty && selectedIDs.count >= recordings.count
    }

    /// Non-multi-select state: a "Select" button + a "Wi-Fi quick transfer N items" button.
    private var fastTransferReadyBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // First, **why** it appeared — otherwise users will find this button baffling
            // (if Bluetooth fails on its own, they might not notice, and the banner could already be covered by the next one).
            Text(L10n.TicNoteCard.wifiFallbackHint)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(L10n.TicNoteCard.select) {
                    // Entering multi-select **defaults to select all**: in most cases, users want to "transfer everything that hasn't downloaded yet"; making them tap "Select All" again adds an unnecessary step.
                    // Just tap to deselect any items they want to exclude.
                    // 
                    selectedIDs = Set(pendingRecordings.map(\.id))
                    isSelecting = true
                }
                .buttonStyle(.bordered)
                .disabled(bulkTransferring || pendingRecordings.isEmpty || isRecording)

                Button {
                    startTransfer(pendingRecordings)
                } label: {
                    HStack {
                        if bulkTransferring {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "wifi")
                        }
                        Text(bulkTransferring
                             ? L10n.TicNoteCard.fastTransferRunning
                             : L10n.TicNoteCard.fastTransferPending(pendingRecordings.count))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(bulkTransferring || pendingRecordings.isEmpty || isRecording)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// Multi-selection mode: selected count + select all/deselect all + cancel + "pass selected N items".
    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.TicNoteCard.selectedCount(selectedIDs.count))
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Button(allRecordingsSelected
                       ? L10n.TicNoteCard.deselectAll
                       : L10n.TicNoteCard.selectAll) {
                    if allRecordingsSelected {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(recordings.map(\.id))
                    }
                }
                .font(.caption)
            }
            HStack(spacing: 8) {
                Button(L10n.Common.cancel) {
                    isSelecting = false
                    selectedIDs.removeAll()
                }
                .buttonStyle(.bordered)

                Button {
                    startTransfer(selectedRecordings)
                } label: {
                    HStack {
                        Image(systemName: "wifi")
                        Text(L10n.TicNoteCard.fastTransferSelected(selectedRecordings.count))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .disabled(selectedRecordings.isEmpty || bulkTransferring || isRecording)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// Open the Quick Transfer page.
    ///
    /// ⚠️ This **only opens the page**, no longer directly `Task { await transferAllOverWifi(...) }`.
    ///    The entire point of the difference lies in the lifecycle: that button is attached to the **device segment**, so when the segment view is torn down,
    ///    `@State` is lost entirely (progress, pending set, which item is currently transferring) — this is exactly what users reported as
    ///    "switching to the library interrupts the transfer". The page (sheet) covers the entire TabView,
    ///    during transfer **you cannot switch segments or tabs**, so this issue structurally disappears.
    private func startTransfer(_ items: [RecorderRecording]) {
        guard !bulkTransferring, !isRecording else { return }
        let pending = items.filter { savedNames[$0.id] == nil }
        guard !pending.isEmpty else {
            TicNoteDiagLog.log("XFER",
                "Fast Transfer page: selected \(items.count) items, but recalculated pending transfers 0 (all already in the database)")
            return
        }
        fastTransferPlan = FastTransferPlan(items: pending)
    }

    private func toggleSelection(_ recording: RecorderRecording) {
        if selectedIDs.contains(recording.id) {
            selectedIDs.remove(recording.id)
        } else {
            selectedIDs.insert(recording.id)
        }
    }

    /// Card info popup. This is all **about the card itself** —— for diagnosis and reference, not needed in daily use.
    ///
    /// Why it's worth a sheet rather than being crammed into the body: for issues like “tap record and nothing happens” on real hardware,
    /// what the user needs to send back is exactly this screen (battery level / serial number / raw replies),
    /// while normally it would just push the recording list off-screen.
    ///
    /// ⚠️ **2026-10-10: The per-frame log on Bluetooth has been removed from here.**
    /// That section (`CardRepliesSection`, `0x1D`/`0x1E`/`0x18` hex values) was originally attached
    /// at the bottom of this popup, but it is pure noise to the user — when they open "Card Info" they only want
    /// battery level, serial number, model, and the raw response packets for the card's configuration queries.
    /// The per-frame log is **for our troubleshooting**; reconnect the three commented-out lines below when you need to view it.
    /// (The ... )
    ///
    /// ## ★ 2026-10-12: Added four items per user request, in the exact order they specified
    /// ```
    /// /// ① Device info (battery / SN / model / raw response)      ← existing
    /// /// ② Storage used (0x06, with progress bar)                    ← new
    /// /// ③ Mic gain (0x08 write direction, two levels)                ← new
    /// /// ④ Name (rename → App-side alias, card-keyed)            ← new
    /// /// ⑤ Card settings / transmission preferences (two existing sections)
    /// /// ⑥ Unbind device (**red**, destructive, double confirmation)          ← new
    /// /// ⑦ Experimental banner
    /// ```
    /// ⑥ Placing it last uses clear user-facing phrasing ("add red text at the bottom of device info for the unbind option") —
    /// destructive actions shouldn't be buried in the middle; users should only see it after scrolling to the end.
    ///
    /// ⚠️ Every piece of state across the full chain is **card-keyed** (alias keyed by SN, gain keyed by SN, ledger keyed by peripheral UUID):
    /// The user mentioned "ticnote cards with a non-current SN will be added later and must be supported too — don't hard-code the single current card".
    private var cardInfoSheet: some View {
        NavigationStack {
            List {
                cardInfoContent
            }
            .listStyle(.insetGrouped)
            .navigationTitle(recorder.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showCardInfo = false }
                }
            }
            .alert(L10n.TicNoteCard.unbindConfirmTitle, isPresented: $showUnbindConfirm) {
                Button(L10n.TicNoteCard.renameCancel, role: .cancel) {}
                Button(L10n.TicNoteCard.unbindConfirmAction, role: .destructive) {
                    Task { await unbindCard() }
                }
            } message: {
                Text(L10n.TicNoteCard.unbindConfirmMessage)
            }
        }
    }

    /// "How's this card" main **text**. Shared in two places:
    ///   * `cardInfoSheet` — `.recordings` mode, tapping the card row opens a popup;
    ///   * `deviceInfoPage` — `.deviceInfo` mode, the whole page body.
    ///
    /// ⚠️ Extracting is not to write fewer lines, but to ensure the "section dependency chain" is defined in **one place**.
    ///    For example, `CardMicGainSection` needs a chain (writing a frame must rewrite the card's current five settings),
    ///    `CardTransferPrefsSection` is pure `@AppStorage`; it can be changed while the card is offline ——
    ///    If duplicated, changing one instance later will cause "correct in popup, wrong in full page".
    @ViewBuilder
    private var cardInfoContent: some View {
        // ── Order scheduled per user 2026-10-12 request ──────────────────────────────────
        // User quote: "Device info first page is name, then storage, then device battery
        // info, model, gain is just a tap... then transfer preferences"
        //
        //   ① Name (pure App-side alias, no dependency chain)
        //   ② Used storage (consumes `deviceInfo?.storage`, no dependency chain)
        //   ③ Battery / Model (`deviceInfoSection`, no dependency chain)
        //   ④ Microphone gain (**requires** chain: writing a frame must rewrite the card's current five settings)
        //   ⑤ Transfer preferences (pure `@AppStorage`, no dependency chain — card can be edited offline)

        // ①
        CardNameSection(recorder: recorder, aliasStore: aliasStore)

        // ②
        CardStorageSection(storage: deviceInfo?.storage,
                           isReading: isReadingDeviceInfo)

        // ③
        deviceInfoSection

        // ④
        if let ticNote = connectedLink as? TicNoteLink {
            CardMicGainSection(link: ticNote, cardScopeKey: cardScopeKey)
        }

        // ⑤
        CardTransferPrefsSection()

        // ⚠️ Unbinding this section **is intentionally kept at the outermost level**. When the link is not established (`connectedLink == nil`,
        //    e.g., the card is lost, returned, or this firmware version cannot connect) it **still must be visible** ——
        //    "Remove this card from the App" is exactly the only action desired in that scenario.
        //    When frames cannot actually be sent, the button disables itself and explains the reason below (see `CardUnbindSection`).
        CardUnbindSection(
            isConnected: (connectedLink as? TicNoteLink)?.isConnected ?? false,
            isWorking: isUnbinding,
            request: { showUnbindConfirm = true }
        )

        if let unbindNotice {
            Section {
                Label(unbindNotice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        // ── Two sections **removed** per user request (code retained for rollback)──────────────────
        //
        // ⛔ `betaBanner` (the bottom "Experimental" section)
        //    User 2026-10-12: "The bottom Experimental can be removed"
        //    — The card's pathway has been verified on real hardware; adding another "experimental" notice only makes people think it can't be used.
        //    The definition remains in the file; to restore, put the two lines below back in place:
        //      Section { betaBanner }
        //
        // ⛔ `CardSettingsSection` (decoding of the card's generic settings `0x08`)
        //    Pure debug info (recScene / recMode / LED / rowData / dmicMode).
        //    The user didn't list it this time, but its original purpose is "when tapping record has no response, see which scene was sent"
        //    — That value is now overridden by the footer of `CardMicGainSection` and diagnostic logs.
        //    To restore: put the line below back in place.
        //      if let ticNote = connectedLink as? TicNoteLink { CardSettingsSection(link: ticNote) }
    }

    /// Key for `@AppStorage` based on **this card**.
    ///
    /// Reuse `RecorderAliasStore.key`; the advantage is that the definition of "what counts as the same card" is in one place
    /// (SN prioritized, peripheral UUID as fallback, case normalized). If you construct your own string,
    /// sooner or later you'll encounter an asymmetry like "alias identifies the same card but gain does not".
    private var cardScopeKey: String {
        let key = RecorderAliasStore.key(identityHex: recorder.identityHex,
                                         peripheralUUID: recorder.id.uuidString)
        // In theory it will never be empty (UUID is always present). If it is truly empty, fall back to the UUID literal, **never return an empty string** ——
        // An empty key would cause all cards "without identifiable identity" to share the same settings slot (the user explicitly requested not to hard‑code a single card).
        return key.isEmpty ? recorder.id.uuidString.lowercased() : key
    }

    /// Recording status row in embedded mode. **No button** — the button is in the page header.
    ///
    /// ⚠️ Standalone mode (the `RecorderDeviceSheet` that appears when clicking a device) **also** uses this row:
    /// It previously included its own button (`recordSection`), but was removed per user request on 2026-10-12.
    @ViewBuilder
    private var recordingStatusRow: some View {
        if isRecording || recordNotice != nil || recordError != nil {
            Section {
                if isRecording {
                    // The stopwatch is driven by `TimelineView` repainting every second, **not** by any @State change ——
                    // During recording nothing changes each second; if driven by state, the hand would not move
                    // (this is exactly the bug reported by the user: "recording duration does not increase").
                    TimelineView(.periodic(from: RecorderControl.tickAnchor, by: 1)) { context in
                        HStack {
                            Label(L10n.TicNoteCard.recordingOnCard, systemImage: "record.circle")
                                .foregroundStyle(.red)
                            Spacer()
                            Text(RecorderSessionModel.clock(activeSession.elapsed(at: context.date)))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(.red)
                        }
                    }
                }
                if let recordNotice {
                    Label(recordNotice, systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                // ⚠️ In standalone mode, this is the only place where recording errors can be seen.
                //    In embedded mode, the popup from the page header `RecorderControl` handles display
                //    (see the `guard !isEmbedded` in `onReceive(activeSession.$alert)`),
                //    while in embedded mode `recordError` is **always `nil`** (that guard blocks assignment) ——
                //    Therefore placing it here **won't** cause "the same failure to pop up twice".
                //    Previously this segment lived in `recordSection`; after that button was removed it was moved here,
                //    otherwise errors in standalone mode would have nowhere to be displayed.
                if let recordError {
                    Label(recordError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text(L10n.TicNoteCard.startStopHint)
                    .font(.caption2)
            }
        }
    }

    /// ★ **Page‑level status row during transfer** (added 2026-10-10).
    ///
    /// ## Why it is needed
    ///
    /// User quote:
    /// "Shouldn't it say recording is being transferred? Why does it say the card is recording, and then show transfer progress etc.?"
    ///
    /// Previously, the only indication of "transferring" was a thin progress bar on the very row itself (**the row being transferred**)
    /// (see `row(_:)`). Consequently:
    /// * The user scrolled, or that bar was out of view → the page showed **no text at all** about "what is happening";
    /// * The top row (which was mistakenly polluted at the time) "card is recording" became the sole explanation,
    ///   even though the user was actually **importing** — two completely different actions were represented by the same red row.
    ///
    /// This row lifts "what is happening" to the **page level**, placed alongside the recording status row without impersonation:
    ///
    /// | Happening | Top row | Color / Control |
    /// |---|---|---|
    /// | Card recording | `recordingOnCard` "Card is recording" + stopwatch | Red + `record.circle` |
    /// | Transferring | `transferring` "Transferring recording…" + % + channel | Gray + spinner + linear progress bar |
    ///
    /// ## The three overridden paths
    ///
    /// Manually select one / automatically transfer the just‑recorded one / batch via Wi‑Fi — they **all** go through `download()`,
    /// and `downloadingID` / `progress` / `activeTransport` are maintained there, so a single row handles everything.
    @ViewBuilder
    private var transferStatusRow: some View {
        if let id = downloadingID {
            // Include the name when available — during batch Wi‑Fi transfers the user wants to know "which one it is now".
            let title = recordings.first { $0.id == id }?.displayTitle
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.TicNoteCard.transferring)
                            .font(.callout)
                        Spacer(minLength: 8)
                        // Percentage and channel name are placed on the right side of the title — exactly the "transfer progress" the user asked for.
                        Text("\(Int((progress * 100).rounded()))% · "
                             + (activeTransport == "wifi" ? "Wi-Fi" : "Bluetooth"))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    // ⚠️ Clamped to 0…1: `progress` comes from protocol‑layer callbacks and theoretically should not exceed bounds,
                    //    but `ProgressView(value:)` will render an out‑of‑range segment if given an out‑of‑range value.
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                    if let title {
                        Text(title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Recording control (dedicated to **standalone mode** — embedded mode uses the button in the page header).
    ///
    /// # ⛔ Removed, **currently has no call sites** (2026-10-12)
    ///
    /// User request: "Delete the 'Record On The Card' that appears after clicking a device; only the recording button on the home page is needed."
    /// The recording button on the home page suffices.
    ///
    /// What was removed is this button: originally in `body` it was
    /// `isEmbedded ? recordingStatusRow : recordSection` — which is the large circular button that comes with the **standalone page** (the `RecorderDeviceSheet`) opened after clicking a device, labeled "Record on the card".
    /// Now that spot always uses `recordingStatusRow`, so the recording entry point across the entire app is limited to the one in the home page header.
    /// only the one in the home page header remains.
    /// `RecorderControl(model:)`。
    ///
    /// ⚠️ **Keeping this implementation is intentional, not a forgotten deletion**: the UI location of the recording entry point has been switched many times,
    ///   Retaining it facilitates rollback. If later we need to restore "standalone pages can also start recording", change that spot in `body` back to
    ///   `if isEmbedded { recordingStatusRow } else { recordSection }` ——
    ///   `recordError`'s two displays will not clash (the one in `recordingStatusRow`
    ///   is always `nil` in embedded mode, see the comment there).
    ///
    /// Behavior matches the red circular button on V05E: tap once to start, tap again to stop.
    /// ⚠️ The stopwatch uses `TimelineView` to repaint every second, **not** `Text(elapsed(from: started))` ——
    /// The latter only recalculates when the body is re‑evaluated, and during recording no @State changes each second,
    /// so the hand **doesn't move at all**. This is the bug reported by the user; do not revert it.
    @ViewBuilder
    private var recordSection: some View {
        Section {
            VStack(spacing: 10) {
                Button {
                    Task { await activeSession.toggle() }
                } label: {
                    ZStack {
                        Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 44, weight: .regular))
                            .foregroundColor(isRecording ? .red : .accentColor)
                            .opacity(activeSession.busy ? 0.3 : 1)
                        if activeSession.busy {
                            ProgressView().controlSize(.regular)
                        }
                    }
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // ⚠️ Using `connectedLink == nil` as a disabled condition makes the button appear tappable:
                // In the old implementation, `toggleRecording()` **silently returns** when the link is nil,
                // so the button looks normal but nothing happens when tapped — part of the user's "tap has no response" report.
                // Now the state is governed by `activeSession.canToggle`,
                // and the button is gray when it cannot be pressed.
                .disabled(!activeSession.canToggle)

                Text(recordingLabel)
                    .font(.subheadline.weight(.medium))
                if isRecording {
                    TimelineView(.periodic(from: RecorderControl.tickAnchor, by: 1)) { context in
                        Text(RecorderSessionModel.clock(activeSession.elapsed(at: context.date)))
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                }
                if let recordNotice {
                    Label(recordNotice, systemImage: "questionmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let recordError {
                    Label(recordError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        } footer: {
            Text("Recording start/stop is still being verified on this card. The command "
               + "now closes any open session first, then sends the record frame.")
                .font(.caption2)
        }
    }

    // (The footer of `recordSection` temporarily remains in English: it's a developer note for "people helping me debug", not everyday copy.)
    //   Delete the whole section once start/stop becomes fully stable.

    /// Card **read‑only** status: battery + charging state + identity + most recent response. Corresponds to the `DeviceSheet` screen on V05E.
    ///
    /// ⚠️ This section now only appears in `cardInfoSheet` — the main content of the device tab is **recording material**,
    /// and the card status is only visible after tapping (consistent with V05E).
    ///
    /// Why also expose the **raw response**: the field semantics of `0x03` / `0x06` haven't been decoded yet (see `TicNoteDeviceInfoQuery`),
    /// showing the hex is more honest than inventing a pretty name ——
    /// and when the user sent back this screen, we received **actual bytes**, no need to reconstruct from memory.
    ///
    /// **Both fields are decoded, so they are displayed as usual**:
    ///   * Battery — last byte of `0x09` (all 7 real‑device samples are `0x64`);
    ///   * Charging state — first byte of `0x09` (added 2026-10-13, criteria in `TicNoteBatteryReading`;
    ///     since it's the same frame as battery, this line requires no additional Bluetooth round‑trip).
    private var deviceInfoSection: some View {
        Section {
            HStack {
                Label(L10n.TicNoteCard.battery, systemImage: batterySymbol)
                Spacer()
                Text(batteryText)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // ★ Added 2026-10-13: **charging / not charging** (user asked: "the charging vs not-charging state…
            //   needs to be included").
            //
            // Data and battery **come from the same `0x09` frame** (first byte = charging flag, last byte = battery level),
            // so this line needs no new Bluetooth round‑trip — it simply displays the half‑response already obtained.
            // The evidence chain and confidence for the criteria are in `TicNoteBatteryReading`.
            //
            // ⚠️ Three states, cannot be collapsed into two: `nil` (card didn't answer / flag unrecognizable) displays `—`,
            //    **not** "Not charging". The user looks at this line to decide whether to plug in power,
            //    labeling "unknown" as "Not charging" would directly mislead them.
            //    This rule is the same as for the adjacent `batteryText` ("Not read" / "—" / "N%").
            HStack {
                Label(L10n.TicNoteCard.chargeState, systemImage: chargingSymbol)
                Spacer()
                Text(chargingText)
                    .foregroundStyle(shownCharging == true ? Color.green : Color.secondary)
            }
            HStack {
                Label(L10n.TicNoteCard.serialNumber, systemImage: "number")
                Spacer()
                Text(recorder.identityText)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Label(L10n.TicNoteCard.model, systemImage: "wave.3.right")
                Spacer()
                Text(recorder.modelName).foregroundStyle(.secondary)
            }

            if let info = deviceInfo, info.replyCount > 0 {
                DisclosureGroup("Raw replies (\(info.replyCount))") {
                    ForEach(Array(info.rawReplies.keys).sorted(), id: \.self) { cmd in
                        if let payload = info.rawReplies[cmd] {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.commandLabel(cmd))
                                    .font(.caption.weight(.medium))
                                Text(payload.map { String(format: "%02X", $0) }
                                        .joined(separator: " "))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    ForEach(info.notes, id: \.self) { note in
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }

            Button {
                Task { await readCardStatus() }
            } label: {
                HStack {
                    Label("Read card status", systemImage: "arrow.clockwise")
                    if isReadingDeviceInfo {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isReadingDeviceInfo || connectedLink == nil)

            if let deviceInfoError {
                Label(deviceInfoError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } header: {
            // Give this section a title — the main page lacks a navigation title (the title bar is empty),
            // without a header it would just be a floating list of rows, with no indication "this is the card's status".
            Text(recorder.displayName)
        } footer: {
            // This sentence must be updated together with the **decoded fields**: saying too little makes users think the charging state is guessed,
            // saying too much would turn the two hex groups `0x03` / `0x06` into "decoded".
            Text("Battery and the serial number come straight from the card, and the "
               + "charging flag rides along in the same battery reply. The other "
               + "replies are shown as raw bytes because their field layout is not "
               + "decoded yet.")
                .font(.caption2)
        }
    }

    /// The three states — not read / read but not obtained / obtained — must be **displayed distinctly**:
    /// "—" (card answered but this field is absent) and "Not read" (not queried yet) are two different things for the user.
    ///
    /// ★ 2026-10-14: Reading now uses `shownBatteryPercent` (live value takes precedence) —
    /// see the comment on `liveBattery` for the rationale (plugging/unplugging the charger no longer requires manual refresh).
    private var batteryText: String {
        guard deviceInfo != nil || liveBattery != nil else { return "Not read" }
        guard let percent = shownBatteryPercent else { return "—" }
        return "\(percent)%"
    }

    private var batterySymbol: String {
        guard let percent = shownBatteryPercent else { return "battery.0" }
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }

    /// Three states for charging status text. **Follows the same rule as `batteryText`**:
    /// "Not read" (card hasn't been queried yet), "—" (queried but card didn't provide a recognizable flag),
    /// and two definitive values. Merging the latter two would prevent users from distinguishing "card not powered" from "card not responding".
    ///
    /// ★ 2026-10-14: Reading now uses `shownCharging` (live value takes priority).
    private var chargingText: String {
        guard deviceInfo != nil || liveCharging != nil else { return "Not read" }
        guard let charging = shownCharging else { return "—" }
        return charging ? L10n.TicNoteCard.charging : L10n.TicNoteCard.notCharging
    }

    /// Icon for charging status. Use a question mark for unknown instead of the "disconnected" symbol — the icon's assertiveness should match the text.
    private var chargingSymbol: String {
        switch shownCharging {
        case .some(true):  return "bolt.fill"
        case .some(false): return "bolt.slash"
        case .none:        return "questionmark.circle"
        }
    }

    /// Response key (**wire command code**) → the human-readable name. Anything not mapped is printed as hex,
    /// don't do the misleading thing of "guessing a name".
    private static func commandLabel(_ cmd: UInt16) -> String {
        switch cmd {
        case TicNoteObservedCommand.deviceIdentityResponse.rawValue:
            return "Identity (0x02)"
        case TicNoteObservedCommand.getStatusInfo.rawValue:
            return "Status (0x03)"
        case TicNoteObservedCommand.getConfig.rawValue:
            return "Config (0x08)"
        case TicNoteObservedCommand.getBattery.rawValue:
            return "Battery (0x09)"
        case 0x0006:
            // ⚠️ 0x06 is a **real-world command that has actually appeared on physical devices** (both request and response use it, returning 13 bytes),
            // but it is not in `TicNoteObservedCommand` (that table is a supplementary list for "commands not in the static table, only present on physical devices").
            // We use a literal here to avoid modifying the protocol enum just for a display name.
            return "Device status (0x06)"
        default:
            return String(format: "Command 0x%04X", cmd)
        }
    }

    /// The text under that large round button.
    ///
    /// ⚠️ **Only used by the withdrawn `recordSection`** (see its doc comment) — kept for easy rollback,
    ///    `recordSection` once restored, this label comes back to life. No other call sites currently.
    private var recordingLabel: String {
        if activeSession.busy { return "…" }
        return isRecording ? "Stop recording" : "Record on the card"
    }

    private var betaBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Experimental", systemImage: "flask")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Group {
                if recorder.isVerifiedOnDevice {
                    Text("This card is supported.")
                } else if recorder.isReadingVerifiedOnDevice {
                    // Path verification on the device is complete, but the whole card hasn't been released (fast transfer playback not yet on device) —
                    // Clarify: stop claiming that a list that has already been processed is "never run on a device".
                    Text("Reading recordings over Bluetooth has been run on a device. "
                         + "Playback in the app and Wi-Fi fast transfer are still "
                         + "experimental — please report anything odd.")
                } else {
                    Text("Reading recordings off this card has been verified against a real capture, "
                       + "but it has not been run on a device yet. Please report anything odd.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// (The old `fastTransferRow` toggle has been removed — it is replaced by the bottom-attached `fastTransferBar` above.)
    ///  (The `preferWifi` state is retained: `download()` still uses it to decide which channel a single download takes.)
    ///  (Batch transfers set it to true, so the channel name under the progress bar also displays correctly.)

    @ViewBuilder
    private func row(_ recording: RecorderRecording) -> some View {
        let isDownloading = downloadingID == recording.id
        let isSelected = selectedIDs.contains(recording.id)
        Button {
            // ★ In multi-select mode, tapping a row toggles selection instead of **also** triggering a download.
            //   Combining both semantics in a single gesture causes an unintended download when the user tries to deselect.
            if isSelecting {
                toggleSelection(recording)
            } else {
                Task { _ = await download(recording) }
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .padding(.top, 1)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(recording.displayTitle)
                        .font(.body.weight(.medium))
                    Text(detail(recording))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if isDownloading {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                        Text("\(Int(progress * 100))% · \(activeTransport == "wifi" ? "Wi-Fi" : "Bluetooth")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let saved = savedNames[recording.id] {
                        Label(L10n.TicNoteCard.savedAs(saved), systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if let error = errors[recording.id] {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // `bulkTransferring` must also be disabled: the batch is occupying that channel, so tapping a single item would open a second one.
        // ⚠️ In multi-select mode, **only check `isRecording`** — the truth for that row is "can I select it",
        //    regardless of whether it's currently transferring (the selected set is only read at the moment the sheet opens).
        .disabled(isRecording || (!isSelecting && (downloadingID != nil || bulkTransferring)))
    }

    private func detail(_ recording: RecorderRecording) -> String {
        // Duration is calculated in **bytes**; don't trust the card's timestamp: `recordUnitBytes = 160` = 20 ms.
        // This conversion matches the card's reported duration on real devices (self-check §13).
        let seconds = Double(recording.sizeBytes / 160) * 0.02
        return String(format: "%@ · %.1f MB · %.0f s",
                      recording.id,
                      Double(recording.sizeBytes) / 1_048_576,
                      seconds)
    }

    // MARK: actions

    /// Record once from the card. **The only public entry point** (reentrancy protection + failure retry happen here).
    ///
    /// ## ★ Why `showsLoading` is needed (2026-10-10: two user reports pointing to the same root cause)
    ///
    /// Why does the "reading recording" page appear after recording ends?
    /// Optimization needed: reading recording on every switch
    ///
    /// Previously, the **first line** of this method was `phase = .connecting` — so regardless of the reason for re-rendering,
    /// the entire page would flash to "Connecting..." → "Reading recording...".
    /// But refreshing doesn't need to occupy the entire page: there's already content in the list; just replace it in place.
    ///
    /// This change takes its cue from V05E's `DeviceFilesModel.refresh`: on refresh there it only flips
    /// `model.isLoading` (at most disabling one button), `files` **stay untouched in place**;
    /// and its `catch is CancellationError` explicitly "does not report errors" — because switching pages/changing devices
    /// and cancelling a refresh is a normal thing; an error would instead make the user think the device is broken (its comment records the real-device reproduction date).
    ///
    /// So the gate isn't about "who called it," but rather "**is there anything to view on the screen right now**":
    /// Only when `showsLoading && recordings.isEmpty` does it actually switch to the loading state.
    ///
    /// - Parameter showsLoading: Allow showing the full-page loading state. **Pass true on first entry**;
    ///   all refresh paths (after stopping recording, link rebuild, pull-to-refresh, re-listing after deletion, re-listing after transfer) always pass false.
    /// - Parameter refreshDeviceInfo: On this pass **also** perform a real read of the card state. Default false —
    ///   see the same-named parameter in `runListPass`. Only pull-to-refresh passes true.
    private func connectAndList(showsLoading: Bool = true,
                                refreshDeviceInfo: Bool = false) async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }
        await runListPass(showsLoading: showsLoading,
                          refreshDeviceInfo: refreshDeviceInfo,
                          retriesLeft: 1)
    }

    /// The **only entry point** to the page (V05E shape: draw first, then read behind, then light polling).
    ///
    /// User's original statement:
    /// > "Every time switching, it needs to read the recording. This needs optimization. Do not use caching or other solutions.
    /// >  Do not read the device every time it is clicked, as the read may not be complete yet."
    ///
    /// Split into three rules; missing any one will revert to the original state:
    ///
    /// 1. **Render first**: `lastRecordings` / `recorderDeviceInfo` are both cached values **already published** in the pipeline,
    ///    so we use them immediately to render upon entering the page — this prevents the entire page from flashing
    ///    when switching "from the library back to the device page". Note this is **not** "only using cache": the next step will truly read.
    /// 2. **Then read**: `connectAndList` still sends a real request. Since step 1 has already filled the UI,
    ///    we pass `showsLoading: false` in this step — the UI doesn't flash, and the read results replace the content in place.
    ///    The reason the read itself can "read completely" relies on the newly added **preface + self-healing retry** in `TicNoteLink.listRecordings`
    ///    (that is the root cause, see its comments).
    /// 3. **Then light polling**: background refresh every 3 seconds (`lightPoll`). It solves two things simultaneously —
    ///    new entries recorded via physical keys on the card will appear automatically; and a single `loadError` line ("device did not respond in time"
    ///    will no longer **persistently** stay on the page; once the card recovers, it disappears on its own.
    ///
    /// ⚠️ Order matters: `connectAndList` must come before rendering the cache, otherwise the first frame still
    ///    shows "Reading recording...", and the user still sees that message.
    private func enterPage() async {
        // One-time receipts ("Saved to library xxx") belong to the **previous** visit,
        // and are cleared when re-entering the page — otherwise they'd hang around with this banner until the next full page load.
        banner = nil
        let seeded = seedFromCaches()
        // ★ Enter the page and immediately check the bottom Wi-Fi Quick Transfer using cached data (`armed` is `@AppStorage`,
        //   effective across app launches) — don't wait for the network round-trip to avoid the button appearing after a delay.
        refreshWifiFallback()
        await connectAndList(showsLoading: !seeded)
        // ★★ 2026-10-12 Added: **Refill battery on cold start**.
        //
        // User's original statement: "Battery info is only recorded after recording finishes, which needs fixing; the info should not only appear after recording ends."
        // The cause is two overlapping issues:
        //   ① The battery icon on `cardRow` reads `deviceInfo?.batteryPercent`,
        //      which only updates when "opening card details" or "pull-to-refresh";
        //   ② `readDeviceInfo` previously squeezed identity query and read commands into the same burst →
        //      If a card doesn't respond to a single read command → battery falls back to "the last cached value pushed before the card",
        //      and that cache is only written via 1 Hz polling **during recording** on real devices.
        // ② has been fixed for real-device forensics (`TicNoteLink.readDeviceInfo` sends in batches),
        // so this read can now truly get the battery level; ① adds the missing update "otherwise the UI will definitely show a gap".
        //
        // Condition is "no battery level in cache" — if there is a value, not even a single Bluetooth packet is sent.
        // This page still **should not** "read status on entry" (see the long comment in `runListPass` above for reasons),
        // Here we only handle the case where "not reading results in an empty display".
        // `retryOnEmpty: false`: do not retry; if the card does not respond — the next pull‑down or tap on the card will handle it.
        // So that ... ... ... ... ... ... ... ... ... 
        //
        // ★ 2026-10-14: `.deviceInfo` mode **must unconditionally read once** ——
        //   The entire content of that page is the card status (battery/charging/storage/model); not reading it leaves a huge gap.
        //   This does **not conflict** with the previous rule "do not read the device upon clicking it": that complaint was
        //   directed at the **recording list page** (which has no place to display card status, so reading it is pure waste);
        //   but on the page for this entry point, the card status is the very reason it exists.
        //   `retryOnEmpty: false` remains unchanged —— if the card doesn't respond this time, let the user tap "Read card status",
        //   do not make entering the page take two round trips.
        if mode == .deviceInfo || deviceInfo?.batteryPercent == nil {
            await readCardStatus(retryOnEmpty: false)
        }
        await lightPoll()
    }

    /// Fill this page first using the cache that has **already been published** on the link. Returns "whether anything was filled in".
    ///
    /// Two sources, both "data that genuinely existed on the link", not something fabricated locally:
    /// * `TicNoteLink.lastRecordings` -- the result of the last `listRecordings()`
    ///   (`@Published`, tied to the link lifecycle; a reconnect brings a new instance, so there's no cross-talk);
    /// * `BluetoothCoordinator.recorderDeviceInfo` -- the result of the last `readDeviceInfo()`
    ///   (cleared by the coordinator on disconnect, so it won't go stale across sessions).
    ///
    /// ⚠️ Only `as? TicNoteLink` is **intentional**: `lastRecordings` is specific to TicNote
    ///    "The previous list" does not belong to the generic contract of `RecorderLink` (D·NOTE's list has another source).
    ///    It is not placed on the protocol here — that would modify the protocol layer for a "pretty first frame" requirement.
    @discardableResult
    private func seedFromCaches() -> Bool {
        var seeded = false
        if recordings.isEmpty,
           let ticNote = bluetooth.recorderLink as? TicNoteLink,
           ticNote.peripheral.identifier == recorder.id,
           !ticNote.lastRecordings.isEmpty {
            recordings = ticNote.lastRecordings.sorted {
                ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
            }
            phase = .ready
            seeded = true
        }
        if deviceInfo == nil, let cached = bluetooth.recorderDeviceInfo {
            deviceInfo = cached
        }
        return seeded
    }

    /// 3s one-time background refresh (V05E's `while !Task.isCancelled { sleep(3); … }`).
    ///
    /// **Never returns** — it is cancelled by `.task` when the view disappears.
    ///
    /// Three gates must be in place, otherwise "light polling" becomes "heavy polling":
    /// * `isReloading` — the previous run hasn't finished yet (`connectAndList` has this gate itself);
    /// * `isRecording` — stuck writing to file; the list is inherently incomplete, and the 1 Hz recording polling
    ///   is occupying the command lock; inserting another list request now would cause both sides to time out;
    /// * a transfer is running — the command lock is held by the download of the entire segment (a 49-minute recording takes several minutes),
    ///   jumping the queue will only result in waiting until timeout, which is exactly what the user sees as "Device did not answer in time".
    ///
    /// ⚠️ Always set `showsLoading: false`: polling must never switch the page to a loading state.
    private func lightPoll() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: Self.lightPollInterval)
            guard !Task.isCancelled else { return }
            guard !isRecording, downloadingID == nil, !bulkTransferring, !isReloading else {
                continue
            }
            await connectAndList(showsLoading: false)
        }
    }

    /// Light polling interval. Use the same value as `DeviceFilesView` in V05E (3 s).
    private static let lightPollInterval: UInt64 = 3_000_000_000

    /// The actual run. When `retriesLeft` is greater than 0, a failure will **automatically trigger another run**.
    ///
    /// ★ Why automatic retries: on real devices, "the first attempt always fails" is common — the card was just woken up,
    /// the session from the previous command hasn't finished, or the opening remark happened to expire. The cost of one retry is only a few hundred milliseconds,
    /// without retries, the user sees a **persistent** "Device did not answer in time".
    /// This is exactly the "always there, needs optimization" reported by users.
    ///
    /// ⚠️ Retry **once** only, and don't recurse (`retriesLeft` decrements), to avoid an infinite loop when the card is genuinely broken.
    /// ⚠️ The second layer of self-healing lives at the protocol layer (`TicNoteLink.listRecordings`'s "redo the opening line before listing again") --
    ///    The two layers have a division of labor: this one handles "wait a while and retry", that one handles "retry under different conditions".
    ///
    /// - Parameter refreshDeviceInfo: Whether this pass should **also** actually read the device status once.
    ///   Defaults to false — list refreshes (3 s polling, after stopping recording, re-listing after deletions…) shouldn't also write a batch of commands,
    ///   that's where the "tap the device once, read it once" behavior comes from. Only an explicit user intent like **pull-to-refresh** passes true.
    private func runListPass(showsLoading: Bool, refreshDeviceInfo: Bool, retriesLeft: Int) async {
        let presentsLoading = showsLoading && recordings.isEmpty
        if presentsLoading { phase = .connecting }
        loadError = nil
        // ⚠️ `banner` **only cleared on first load**. If cleared on a refresh path, it will
        //    "Saved to library xxx" this receipt just given to the user gets eaten — and that banner often
        //    is exactly the reason for this refresh (re‑list after transfer).
        if presentsLoading { banner = nil }

        // The embedded recorder tab represents the already-connected card.
        // Do not start a second, potentially minutes-long BLE reconnect merely
        // because the view appeared while that card is asleep or disconnected.
        // Most importantly, do not send a list command in that state: a timeout
        // means "not connected", not "the card has no recordings".
        if isEmbedded,
           bluetooth.recorderLink?.peripheral.identifier != recorder.id {
            connectedLink = nil
            loadError = RecorderLinkError.notConnected.localizedDescription
            phase = .ready
            return
        }

        do {
            let link = try await link()
            connectedLink = link
            // Standalone mode: attach the session model to this link.
            // Injection mode **does not attach** — that model is attached to `bluetooth.recorderLink`
            // (the outer `.task(id:)` has already connected it). Attaching again here is on the same device,
            // and is a no-op by `identity`, but leaving it out is less clear.
            if !isEmbedded { ownSession.attach(.card(link)) }
            if presentsLoading { phase = .listing }
            // Recording is stuck writing the file; the list is incomplete — same as V05E, do not list yet.
            // ⚠️ Refresh path: **keep the existing list** (old is always better than an empty screen, and it will refresh again immediately after stopping recording).
            guard !isRecording else { phase = .ready; return }

            // ★★ `.deviceInfo` mode: **stop here, do not send list command**.
            //
            // // Source (2026-10-14 user statement):
            // > "Do not show recording time when adding a device; display only the device information."
            //
            // The main content of this page is the card status. The recording list is neither rendered nor consumed — sending it would be a wasted round trip (each command waits 0.8 s when the card doesn't respond). Moreover, it is the source of the old bug where "tapping a device" floods the screen with a string of recording times; missing it once causes a recurrence.
            // 
            // 
            //
            // ⚠️ Skip the two refreshes in Fast Transfer (`refreshWifiFallback` / `refreshFastTransfer`)
            //    Same logic: this mode does not render the Fast Transfer button at the bottom.
            // ⚠️ However, `connectedLink` is already assigned (above), so device info is read correctly.
            if mode == .deviceInfo {
                phase = .ready
                return
            }

            let listed = try await link.listRecordings()
            // Newer items go first. When `startedAt` is missing, they go last (instead of sorting to the front as 1970) —
            // Missing means "unknown"; treating it as "earliest" makes the list look broken.
            recordings = listed.sorted {
                ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast)
            }
            // ★ List changed → re-evaluate the Wi-Fi quick-transfer entry at the bottom (see `refreshWifiFallback` for the logic of the three revisions).
            refreshWifiFallback()
            // Ask about the high-speed channel again after listing recordings. The connection can indeed change the answer (`fastTransfer` requires
            // `isConnected`), so this step is necessary, not just 'waiting for credentials to arrive'.
            refreshFastTransfer(link)
            phase = .ready
            // ★★ Card status is **not read in the list flow** (2026-10-08 second revision, 2026-10-10 finalization).
            //
            // User's original statement: "Don't read the device immediately after clicking it; the read may be incomplete."
            //
            // Actual device log statistics (`/tmp/t3.log`): `readDeviceInfo` was called
            // **29 times** on this machine, while `provisionSession` (only runs during recording/download) is only 20 times —
            // The difference comes from this line. And "entering the device page", "switching back from the library", "link reconstruction"
            // all reach here, each batch of 4~5 commands, and when the card hangs, each takes 0.8 s to wait.
            // The user experience is "clicking once spins for ages, and still doesn't read completely".
            //
            // And this page **doesn't display card status at all** — battery/serial/model are all
            // in `cardInfoSheet` (viewed only when opened). So this read cost is 100% wasted.
            //
            // Card status now follows three paths, none of which is "read on page entry":
            //   1. Page entry **uses cache** (`seedFromCaches` reads `bluetooth.recorderDeviceInfo`, zero I/O);
            //   2. **Opening the card info** triggers a real read once (`.onChange(of: showCardInfo)`);
            //   3. Pull-to-refresh — explicit user intent, passing `refreshDeviceInfo: true`.
            // Battery level won't become stale: polled at 1 Hz during recording, and the keep-alive heartbeat sends `0x09` when not recording.
            if refreshDeviceInfo { await readCardStatus() }
        } catch {
            log.warning("list failed: \(String(describing: error), privacy: .public)")
            // Automatic retry (see the `retriesLeft` explanation above).
            if retriesLeft > 0, !Task.isCancelled {
                TicNoteDiagLog.log("LIST",
                    "Listing recordings failed (\(String(describing: error))), auto-retrying once")
                try? await Task.sleep(nanoseconds: 400_000_000)
                await runListPass(showsLoading: showsLoading,
                                  refreshDeviceInfo: refreshDeviceInfo,
                                  retriesLeft: retriesLeft - 1)
                return
            }
            // ★ Failure **does not dismiss the screen** (updated 2026-10-09): The card row must always be reachable,
            //   otherwise the user cannot even see "what the card said" — and this is precisely the information needed
            //   when the list times out. Errors are shown only as a single row above the list + Try again.
            loadError = describe(error)
            phase = .ready
        }
    }

    private func refreshFastTransfer(_ link: any RecorderLink) {
        fastTransferAvailable = link.fastTransfer != nil
        fastTransferReason = link.fastTransferUnavailableReason
        if !fastTransferAvailable { preferWifi = false }
    }

    /// Read the card's read-only status once (battery / identity / status / configuration).
    ///
    /// ## **Intentionally do not clear** the previous result on failure
    /// Battery level is "read once, old for one second" information; erasing it would display as "card has no data",
    /// while the real reason is "this query failed". So errors only follow the `deviceInfoError` hint path.
    ///
    /// ## ★ Why retries are needed (reason corrected on 2026-10-12)
    /// The previous version explained "empty battery" as "the card was still booting when first connected, so all four batches missed".
    /// **That wasn't the real cause**; instead, `readDeviceInfo` packed the identity query and the read command into the same burst,
    /// the card only ever replied with identity frames (6/6 on real devices). That has already been fixed (send in batches, see
    /// `TicNoteLink.readDeviceInfo`）。
    ///
    /// Retry remains: the card occasionally only answers half (when sending `0x09` alone it sometimes only returns `0x0B`),
    /// Resending once costs a few hundred milliseconds, and the benefit is that the user doesn't have to manually tap "Read card status".
    /// If it still fails, display the reason (the user will send this line together with the original response packets from the card information).
    private func readCardStatus(retryOnEmpty: Bool = true) async {
        guard let link = connectedLink, !isReadingDeviceInfo else { return }
        isReadingDeviceInfo = true
        deviceInfoError = nil
        defer { isReadingDeviceInfo = false }
        do {
            let info = try await link.readDeviceInfo()
            var bestInfo = info
            // If no responses were received, it's highly likely the "card hasn't woken up"; resend the entire batch once.
            // ⚠️ Retry only once, and **do not recurse** — when the card truly doesn't support it, it must not become an infinite loop.
            if info.batteryPercent == nil, retryOnEmpty {
                try? await Task.sleep(nanoseconds: 400_000_000)
                let second = try await link.readDeviceInfo()
                if second.replyCount > info.replyCount || second.batteryPercent != nil {
                    bestInfo = second
                }
            }
            deviceInfo = bestInfo
            bluetooth.updateRecorderDeviceInfo(bestInfo, for: link)
        } catch {
            log.warning("device info failed: \(String(describing: error), privacy: .public)")
            deviceInfoError = describe(error)
        }
    }

    /// Reuse if already connected to the same device; otherwise, connect to a new one.
    private func link() async throws -> any RecorderLink {
        if let existing = bluetooth.recorderLink,
           existing.peripheral.identifier == recorder.id {
            return existing
        }
        // ⚠️★ During bulk fast transfer, **never** create a new BLE connection here.
        //
        //   During that period, the card was acting as a hotspot, **BLE was intentionally disconnected** (it dropped on its own after `OPEN_WIFI`),
        //   and the timeout for `connectRecorder` is `[90, 150]` seconds — once it reaches that point, the entire batch
        //   silently hangs for two minutes, and the user sees it as "frozen". It's better to fail fast with `notConnected` right away.
        //
        //   The normal path never reaches this line: the batch holds `batchFastTransfer`,
        //   and `bluetooth.recorderLink` remains active throughout the entire session
        //   (in real device logs, three consecutive `link()` calls hit this branch in 1~6 ms).
        //   It is a **fallback gate** to guard against accidents like "the object being cleared elsewhere".
        if batchHoldsWifiLock {
            TicNoteDiagLog.log("XFER",
                "No new BLE connections during the batch fast transfer (stuck in hotspot mode, BLE is intentionally disconnected)")
            throw RecorderLinkError.notConnected
        }
        return try await bluetooth.connectRecorder(recorder)
    }

    /// Download one record and insert it into the database. Returns **structured results** — single record / auto-transfer / quick-transfer page uses these to decide the next step.
    ///
    /// ## What `inBatch` changed (2026-10-12, fixes for two real-device bugs)
    ///
    /// **① No longer use `downloadingID` as a re‑entrancy lock in batch.**
    /// It is **UI state** (inline spinner / progress bar / button disabled), using it as a gate results in:
    /// From the third item in a batch onward, all hit the `guard` below and silently `return false` — no logs,
    /// No error rows, the loop still processes all 57 items, but the user sees "only 1 item was transferred and then nothing happened".
    /// The batch already has its own gate (`bulkTransferring`), so only **single-item** downloads go through the UI gate;
    /// Moreover, the single-item path now **logs even when skipped**, so the same silent failure won't appear a second time.
    ///
    /// **② No longer re-list once per item after transferring.**
    /// Previously, with `deleteAfterTransfer` enabled, this would call `connectAndList()` once per item;
    /// in a batch that meant 57 full reconnects + re-lists (real-device measured at 3 s or more per round). Re-listing is now the caller's responsibility:
    /// a single download lists once itself, and a batch lists once after the loop ends.
    ///
    /// **③ (This round) the ownership of the suppression lock follows `inBatch`.**
    /// `beginRecorderWifiTransfer` / `endRecorderWifiTransfer` used to be **one pair per item**,
    /// and `endRecorderWifiTransfer()` will **start an automatic reconnection task** when the count reaches zero,
    /// mutually with the next `link()`'s `connectRecorder` (timeout [90, 150] seconds)
    /// `teardownRecorderForReconnect` —— both paths are waiting, and neither connects.
    /// On a real device, it behaves as "after transferring 1~2 items, the next one never moves". Now batch **only begin/end once for the whole batch**
    /// (see `prepareNextFile` / `finishBatch`), the reconnection between the two is handled by
    /// `bluetooth.ensureRecorderLink` performed explicitly and single‑threadedly.
    ///
    /// - Parameter inBatch: Whether driven by the fast transfer page (caller holds a suppression lock, and will uniformly re‑list).
    /// - Parameter onProgress: Additional progress callback (used for the fast transfer page's per‑line progress bar).
    ///   Coexists with `progress` this `@State` **coexist**: one is the page‑level status line, the other is each line in the page.
    @discardableResult
    private func download(_ recording: RecorderRecording,
                          inBatch: Bool = false,
                          onProgress: (@MainActor (Double) -> Void)? = nil) async -> TicNoteTransferOutcome {
        if !inBatch {
            // When a batch is running, the inline download button is visually disabled,
            // but the "disabled" state only takes effect after rendering — add an extra guard here to prevent both channels from opening simultaneously.
            guard !bulkTransferring else {
                TicNoteDiagLog.log("XFER",
                    "Skipping id=\(recording.id): batch transfer in progress, single download does not jump the queue")
                return .stopped
            }
            guard downloadingID == nil else {
                TicNoteDiagLog.log("XFER",
                    "Skip id=\(recording.id): a download is already in progress (\(downloadingID ?? "-"))")
                return .stopped
            }
        }
        errors[recording.id] = nil
        savedNames[recording.id] = nil
        // ★ The channel name is **preset** here, rather than being decided after `link()`.
        //   Two reasons:
        //   ① `transferStatusRow` / the inline progress bar can render the moment `downloadingID != nil`,
        //      and presetting keeps the "· Bluetooth" half correct from the first frame;
        //   ② the real value (including "Wi-Fi unavailable → fall back to Bluetooth") is written at the `fast == nil ? …` below,
        //      which overrides it without changing the semantics.
        activeTransport = preferWifi ? "wifi" : "ble"
        downloadingID = recording.id
        progress = 0
        defer { downloadingID = nil }

        // The page-level status line and the inline progress bar in the page share the same callback -- write it once, and both UIs update together.
        let report: @MainActor (Double) -> Void = { value in
            progress = value
            onProgress?(value)
        }

        // ★ Result of deleting from the card: `nil` means no deletion this time (switch is off); `true`/`false` see below
        //   `deleteAfterTransfer` section. **The Wi-Fi path result is in the return value** ——
        //   because deletion can only happen in the short window where "data is collected and the session hasn't closed yet", which only the channel internals can access.
        var removedFromCard: Bool?
        var usedWiFi = false

        do {
            // ★★★ When the batch holds a shared Wi-Fi session, **BLE is not touched for the entire duration**.
            //
            //   During the session, the hotspot is stuck; BLE disconnects **on its own** (about 1.8s after `OPEN_WIFI`);
            //   At this point, if `link()` falls into the `connectRecorder` branch, it results in a
            //   silent wait of `[90, 150]` seconds —— the entire batch will hang there, with no error lines in the logs.
            //
            //   Batches don't need it anyway: without BLE downloads, batches don't perform BLE deletions
            //   (use `cmder 14` in the Wi-Fi session, see the `deleteAfterTransfer` section below).
            //   So here we **explicitly avoid `link()`**, rather than hoping it happens to hit the "reuse existing link" branch.
            let bleLink: (any RecorderLink)?
            if inBatch, batchFastTransfer != nil {
                bleLink = nil
            } else {
                bleLink = try await link()
            }
            // Decide the channel **once here**, then stick with it.
            // Don't "silently fall back to BLE when Wi-Fi fails": users will think they're using Wi-Fi,
            // and a 49-minute recording will quietly start transferring 45 minutes of data.
            // Fail openly, and let the user decide whether to switch to Bluetooth.
            //
            // ★★★ Batch transfers must use **the single shared instance** (`batchFastTransfer`):
            //   The session (listening + hotspot + WebSocket + cached list) is tied to the instance;
            //   Fetching a new instance for each item = cold-starting the hotspot for each item —— exactly what users reported
            //   as "having to reconnect to WiFi for every segment." Single-item transfers still fetch fresh each time (send-and-receive, no session involved).
            let fast = preferWifi
                ? (inBatch ? (batchFastTransfer ?? bleLink?.fastTransfer) : bleLink?.fastTransfer)
                : nil
            activeTransport = fast == nil ? "ble" : "wifi"
            usedWiFi = fast != nil
            // ★ Record which "item the user selected" and which channel we finally used.
            //   The logs look **completely different** when both paths fail (BLE is a frame stream, Wi‑Fi is the WIFI tag string), and without recording this line you can't tell which segment to examine later.
            //   If you don't log this line first, you can't determine which part to look at when reviewing the logs.
            TicNoteDiagLog.log("XFER",
                "Starting download id=\(recording.id) size=\(recording.sizeBytes)B"
                + " expected transport=\(preferWifi ? "wifi" : "ble") actual=\(activeTransport)"
                + (inBatch ? " (in batch, auto-delete after transfer=\(deleteAfterTransfer ? "on" : "off"))" : ""))
            if preferWifi && fast == nil {
                // The switch was originally displayed according to the snapshot, and the credentials may become invalid (disconnected) only after scanning.
                if let bleLink { refreshFastTransfer(bleLink) }
                banner = "Fast transfer became unavailable; fell back to Bluetooth."
            }

            let clip: RecorderClip
            if let fast {
                // ★ During fast transfer, **suppress the recorder card's automatic reconnection**: the card, upon receiving OPEN_WIFI, will proactively disconnect BLE
                //   to start a hotspot (about 1.8 s later), that disconnection is part of the process,
                //   It should not be treated as a "disconnection" and aggressively retried in the background (see `beginRecorderWifiTransfer`).
                //   `defer` ensures that the failure path also releases the lock, otherwise reconnection will be permanently suppressed.
                //
                //   ⚠️ In batch mode (`inBatch`) **this pair is not handled here** — the whole batch begins/ends only once,
                //      held by `prepareNextFile` / `finishBatch`. See the rationale
                //      in `download` point ③ and `BluetoothCoordinator.ensureRecorderLink`.
                if !inBatch {
                    bluetooth.beginRecorderWifiTransfer(recordID: recorder.id.uuidString)
                }
                defer { if !inBatch { bluetooth.endRecorderWifiTransfer() } }
                // ★ Record which channel is currently running — the "Stop" on the fast transfer page relies on it to obtain
                //   `cancel()` (the channel instance has no other entry point: single items use `link.fastTransfer`,
                //   batch items use `batchFastTransfer` — both create a new instance for each item/batch).
                activeFastTransfer = fast
                defer { activeFastTransfer = nil }
                // ★ "Delete after transfer" on the Wi‑Fi path **is completed inside the channel**:
                //   Only there can reach the short period of "data collected but the session not yet closed",
                //   and the delete command (cmder 14) can only go through the still‑open WebSocket.
                let outcome = try await fast.fastFetch(recording,
                                                       deleteAfter: deleteAfterTransfer) { value in
                    // The protocol is @MainActor, so this callback already runs on the main thread; write @State directly.
                    report(value)
                }
                clip = outcome.clip
                removedFromCard = outcome.removedFromCard
            } else {
                // In batch mode, `bleLink` can be nil (the above **deliberately** avoids BLE) — which indicates that this item
                // doesn't even have a Wi‑Fi session, truly has no way forward, should fail fast instead of attempting BLE.
                guard let bleLink else { throw RecorderLinkError.notConnected }
                clip = try await bleLink.fetchClip(recording) { value in
                    report(value)
                }
            }
            let name = RecorderClipStore.suggestedName(
                protocolID: recorder.protocolID,
                startedAt: recording.startedAt,
                sessionID: recording.sessionID,
                fileExtension: clip.fileExtension
            )
            try RecorderClipStore.store(clip, name: name)
            // `deviceSerial` uses SN instead of iOS's peripheral UUID ——
            // The latter changes when the phone is swapped or the app reinstalled, causing the "already downloaded" check to fail (as noted in `Library`'s comments
            // that records this pitfall). Identical filename conflicts are therefore scoped by **SN**.
            library.recordDownload(
                name: name,
                size: clip.byteCount,
                transport: activeTransport,
                deviceSerial: recorder.identityText,
                // ★ 2026-10-15: Store the "human‑readable name" together, so the source identifier in the list
                //   can be displayed (if unavailable, fall back to "Recorder‑card SN last 4 digits").
                deviceName: recorder.displayName
            )
            savedNames[recording.id] = name
            // ★ Once stored → the bottom "N items pending transfer" counter should decrement, and hide itself when all transfers are complete.
            refreshWifiFallback()
            var message = L10n.TicNoteCard.savedToLibrary(name)
            log.info("downloaded \(recording.id, privacy: .public) as \(name, privacy: .public) over \(self.activeTransport, privacy: .public)")
            TicNoteDiagLog.log("XFER",
                "✅ Stored \(name) \(clip.byteCount)B channel=\(activeTransport)")
            // ★ After transfer, automatically delete the recording on the card (option enabled by the user in card settings).
            //
            //   The division of labor between the two channels was determined after on‑device testing on 2026‑10‑12, not a preference issue:
            //   · **Wi‑Fi transfer** → the `fastFetch(deleteAfter:)` above already deletes within the session
            //     (`cmder 14`, the only deletion path verified by official code).
            //     Here **do not fall back** to BLE `0x1E`: it finishes after 1.3 s and then cuts the BLE connection
            //     (device log `LINK disconnected … Code=6 "timed out unexpectedly"`),
            //     and the next recording in the batch relies on this BLE to send `OPEN_WIFI`.
            //     More importantly, `false` may include a "card no acknowledgment" case — at that moment the card is likely
            //     **already deleted**, switching channels and retransmitting only wastes a link.
            //   · **Bluetooth transfer** → no Wi‑Fi session is available, so BLE `0x1E` must be used.
            //     It has never received an acknowledgment on a device, and it will cut the BLE connection; the batch uses
            //     Wi‑Fi, so this path is not taken, and the cost is limited to single‑item downloads.
            if deleteAfterTransfer {
                if usedWiFi {
                    message += " " + (removedFromCard == true
                        ? L10n.TicNoteCard.deletedFromCard
                        : L10n.TicNoteCard.deleteFailedFromCard)
                    if removedFromCard != true {
                        log.warning("Wi-Fi delete-after-transfer not confirmed for \(recording.id, privacy: .public)")
                    }
                } else if let link = connectedLink {
                    do {
                        try await link.deleteRecording(recording)
                        removedFromCard = true
                        message += " " + L10n.TicNoteCard.deletedFromCard
                        log.info("deleted \(recording.id, privacy: .public) from the card over BLE")
                    } catch {
                        removedFromCard = false
                        message += " " + L10n.TicNoteCard.deleteFailedFromCard
                        log.warning("BLE delete-after-transfer failed: \(String(describing: error), privacy: .public)")
                    }
                }
            }
            banner = message
            // Delete and then refresh the list once, so the list will not show a recording that no longer exists.
            // ⚠️ Do not load the entire page: a "Saved to library" banner was just shown to the user,
            //    and immediately replacing the whole page with "Loading recordings…" will cover it up (`banner` is cleared only on the first load, exactly for this banner).
            //    only cleared on the first load, precisely for this banner.
            // ⚠️ Do not list within the batch — the fast transfer page lists once uniformly in `finishBatch()`.
            //    Listing each item individually on a device adds about 3 s per item, and that moment often coincides with
            //    the card switching from hotspot back to BLE (inevitably fails + triggers an automatic retry).
            if deleteAfterTransfer, !inBatch { await connectAndList(showsLoading: false) }
            return TicNoteTransferOutcome(savedName: name,
                                          failureReason: nil,
                                          cancelled: false,
                                          deletedFromCard: removedFromCard == true)
        } catch let error as RecorderLinkError {
            // ★ Being interrupted by "Stop" is not a failure — the user pressed it, and the list should not show a red line.
            //   This branch must be first: `.cancelled` is also a kind of `RecorderLinkError`.
            if case .cancelled = error {
                TicNoteDiagLog.log("XFER", "⊘ Stopped id=\(recording.id) channel=\(activeTransport)")
                errors[recording.id] = nil
                return .stopped
            }
            // The concrete manifestation of fail‑closed: **no disk write**, and convey the reason to the user as‑is.
            // Especially `.corrupted` — a gap/conflict means the obtained bytes are unreliable,
            // saving them would become "a recording that cannot be played", which is harder to troubleshoot than not saving.
            TicNoteDiagLog.log("XFER",
                "✗ Download failed channel=\(activeTransport) \(String(describing: error))")
            let reason = shortReason(error) + wifiFailureHint
            errors[recording.id] = reason
            return .failed(reason)
        } catch is CancellationError {
            // Backgrounding / page being dismissed — handled the same as "Stop": not a failure.
            TicNoteDiagLog.log("XFER", "⊘ Task cancelled id=\(recording.id) channel=\(activeTransport)")
            errors[recording.id] = nil
            return .stopped
        } catch {
            TicNoteDiagLog.log("XFER",
                "✗ Download failed channel=\(activeTransport) \(String(describing: error))")
            let reason = error.localizedDescription + wifiFailureHint
            errors[recording.id] = reason
            return .failed(reason)
        }
    }

    /// ★ When Wi‑Fi fails, **provide an additional actionable suggestion**.
    ///
    /// On a device, the most common failure on this path looks like this: iOS reports "Joined hotspot", then nothing happens ——
    /// The TCP connection from the card is blocked by the system. In this case `RecorderLinkError` only reports "timeout",
    /// and the correct response to a "timeout" is **not to retry**, but to check **local network permissions**:
    /// If that switch is off (the user denied the first prompt, or the system reset privacy settings),
    /// the card can never connect, and the UI appears identical to "card unresponsive".
    ///
    /// ⚠️ Do **not** add this sentence for BLE failures — Bluetooth is unrelated to local network permissions,
    ///    adding it would misdirect the user.
    private var wifiFailureHint: String {
        guard activeTransport == "wifi" else { return "" }
        return " " + L10n.TicNoteCard.wifiFailedHint
    }

    private func describe(_ error: Error) -> String {
        if let link = error as? RecorderLinkError { return link.localizedDescription }
        return error.localizedDescription
    }

    // MARK: - Unbind device

    /// ★ After the user taps "Unbind device" **and confirms**, execution reaches here (the confirmation step is in `cardInfoSheet`
    /// within the `.alert`, `showUnbindConfirm` → this button).
    ///
    /// ## Four-step cleanup, following the same rule as D·NOTE's `DeviceSheet.unbindAndRemove()`
    /// ```
    /// ① Unbind on the card side          link.unbindDevice()   → 01 05 00 00
    /// ② Forget the card's name on this device  aliasStore.forget(...)  (the card has been handed over, keeping a name is meaningless)
    /// ③ Remove from the device ledger      configService.config.devices.removeValue(forKey:)
    ///                        + scheduleSave(), otherwise the list will still contain an unreachable gray card
    /// ④ Disconnect the link             bluetooth.disconnect() (maintaining a now‑obsolete link is pointless)
    /// ```
    ///
    /// ## ⚠️ The key is `recorder.id.uuidString`, not SN
    /// The ledger (`ConfigService.devices`) uses as key **the peripheral UUID written during scanning**
    /// (see `ScannerSheet.connectRecorder`) — this is **not the same** as aliasing by SN.
    /// If both are mixed, unbinding will fail to delete the entry that was just written.
    ///
    /// ## Why not `dismiss()`
    /// This page can be presented in **two ways**: as a sheet from the scan page, or as content within the main "Recording" tab.
    /// `@Environment(\.dismiss)` points to different targets in those two contexts, and after tapping unbind the layer to close is
    /// **the card‑info layer** — controlled by `showCardInfo`. Therefore we simply set it back to false,
    /// independent of "where it was entered from".
    private func unbindCard() async {
        guard let ticNote = connectedLink as? TicNoteLink else {
            unbindNotice = L10n.TicNoteCard.unbindOffline
            return
        }
        guard !isUnbinding else { return }
        isUnbinding = true
        defer { isUnbinding = false }

        do {
            try await ticNote.unbindDevice()
        } catch {
            // On failure **do not close the page**: the user must see the reason and be able to retry directly.
            log.warning("unbind failed: \(String(describing: error), privacy: .public)")
            unbindNotice = "\(L10n.TicNoteCard.unbindFailed) \(describe(error))"
            return
        }

        aliasStore.forget(identityHex: recorder.identityHex,
                          peripheralUUID: recorder.id.uuidString)
        configService.config.devices.removeValue(forKey: recorder.id.uuidString)
        configService.scheduleSave()
        bluetooth.disconnect()
        unbindNotice = L10n.TicNoteCard.unbindSuccess
        TicNoteDiagLog.log("LINK", "Unbound \(recorder.displayName) (SN \(recorder.identityText))")

        // Let the user **see** that message before closing the page. Closing immediately would leave nothing on the screen ——
        // and "whether the card was actually unbound" is the most pressing question on this screen.
        try? await Task.sleep(nanoseconds: 1_400_000_000)
        showCardInfo = false
    }

    private func shortReason(_ error: RecorderLinkError) -> String {
        switch error {
        case .corrupted(let detail): return L10n.TicNoteCard.transferIncomplete(detail)
        case .malformed(let detail): return L10n.TicNoteCard.unexpectedData(detail)
        case .unsupported(let detail): return L10n.TicNoteCard.notSupported(detail)
        case .notConnected: return L10n.TicNoteCard.disconnected
        case .timeout: return L10n.TicNoteCard.notResponding
        case .cancelled: return L10n.TicNoteCard.cancelled
        }
    }

    // MARK: Automatic transfer / Batch transfer / Deletion

    /// ★ Automatic transfer after recording. Users want "automatic output after recording" rather than "having to tap upload after recording".
    ///
    /// Identifying "the just‑recorded item" uses the **session ID** (the sid carried in the card's `0x18` when recording starts),
    /// not "the first item in the list" — if the user also records a track with the card's physical button outside the app,
    /// the latest fetch would pick the wrong one.
    ///
    /// `connectAndList()` runs concurrently via `onChange(of: isRecording)`, here we wait for it to refresh the
    /// new list (up to 15 s); if not found, quietly give up — automatic actions should not show an alert.
    private func autoTransfer(sessionID: UInt32) async {
        guard !isRecording else { return }

        var target: RecorderRecording?
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let match = recordings.first(where: { $0.sessionID == sessionID }) {
                // If already transferred (e.g., after reconnection and re‑entering the page), do not transfer again.
                if savedNames[match.id] != nil { return }
                target = match
                break
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let recording = target else {
            log.warning("auto-transfer: session \(sessionID, privacy: .public) not in the list")
            return
        }
        // If the user has already manually downloaded this item, do not transfer it again.
        guard savedNames[recording.id] == nil else { return }
        banner = L10n.TicNoteCard.autoTransferring
        // ★ Automatic transfer **is forced to use Bluetooth**, leaving the choice to fallback after a failure.
        //
        // User's exact words: "Only auto‑transfer via Bluetooth after the transfer completes; if a long file hasn't finished, prompt Wi‑Fi fast transfer".
        // Therefore we do not change the user's channel preference (they may have selected Wi‑Fi elsewhere), but **for this transfer**
        // force Bluetooth:
        //   · After recording, the user expects "it handles it in the background" rather than "ask me which channel to use";
        //   · Wi‑Fi fast transfer requires sending OPEN_WIFI, making the card drop BLE, starting a hotspot, and iOS joining the hotspot ——
        //     doing all this at the moment recording finishes would cause the UI to shake (disconnection notice + reconnection).
        let savedPreferWifi = preferWifi
        preferWifi = false
        let transferred = await download(recording)
        preferWifi = savedPreferWifi
        // ★ Automatic transfer **does not affect the bottom Wi‑Fi fast‑transfer button** (third revision on 2026‑10‑10):
        //   Its visibility condition is "recorded audio + undownloaded items on the card", not "Bluetooth failed".
        //   See `wifiFallbackArmed` — the previous round tied the two together, resulting in "all five paths succeeded via Bluetooth → the button never appeared", leading users to ask "where did the Wi‑Fi fast transfer go?".
        //   and the button never showed up, so users directly asked "where did the Wi‑Fi fast transfer disappear?".
        if !transferred.isSuccess {
            TicNoteDiagLog.log("XFER",
                "Bluetooth auto‑transfer not completed (sid=\(sessionID)) — Wi‑Fi fast‑transfer entry remains available")
        }
        refreshWifiFallback()
    }

    /// ★ **The only** place that writes `wifiFallbackNeeded` (as defined after the third revision).
    ///
    /// In short: **recorded audio && undownloaded items on the card** → show, otherwise hide.
    ///
    /// * `wifiFallbackArmed` is set to true at the moment recording stops (see `onChange(of: isRecording)`),
    ///   stored with `@AppStorage` — users expect it to be "retained", and it should not disappear after leaving and returning;
    /// * "Undownloaded" = `savedNames[id] == nil`. **Failed items count as well**: they are precisely the batch that most needs retrying.
    ///
    /// ⚠️ All call sites that can modify these two values must be covered: after listing, after downloading an item,
    ///    after batch transfer, and after automatic transfer. Missing any will cause the "transfer complete" button to remain visible.
    private func refreshWifiFallback() {
        let pending = recordings.filter { savedNames[$0.id] == nil }
        let shouldShow = wifiFallbackArmed && !pending.isEmpty
        if shouldShow != wifiFallbackNeeded { wifiFallbackNeeded = shouldShow }
    }

    // MARK: Fast‑transfer page driver (changed on 2026‑10‑12 from "bottom‑button self‑started Task" to "page‑driven")
    //
    // The queue and state machine reside in `TicNoteTransferModel` (the sheet's `@StateObject`),
    // this page offers four actions: prepare the next item / transfer one / stop the current one / wrap up.
    // The rationale for the division of labor is documented in the comments of `TicNoteTransferDriver`.

    /// Wrap the four actions from the device page into a driver required by the sheet.
    ///
    /// ⚠️ The closure body must reference `self.` — for a struct, capturing `self` in an escaping closure (along with its `@State` storage boxes) is **intentional**:
    ///    the content closure of `.sheet(item:)` is created during `body` evaluation, capturing that view instance with its storage boxes. This is not a newly introduced pattern,
    ///    this is not a newly introduced pattern,
    ///    the original button's `Task { await transferAllOverWifi(...) }` has always been like this.
    private func makeTransferDriver() -> TicNoteTransferDriver {
        TicNoteTransferDriver(
            prepare: { [self] in await self.prepareNextFile() },
            transfer: { [self] recording, report in
                let outcome = await self.download(recording, inBatch: true, onProgress: report)
                // ★ This one actually downloaded → indicating that the "create session" path is viable in this environment,
                //   resetting the failure budget to zero (see "limit 2" in `prepareNextFile`).
                //   If we don't do this, when the 30th item in a batch of 57 encounters a stuck restart,
                //   the remaining 27 items would be doomed together by that limit —— even though they could have been transferred.
                if outcome.isSuccess { self.batchOpenAttempts = 0 }
                return outcome
            },
            cancelCurrent: { [self] in
                // Only the holder of the instance can reach `cancel()` — it sets the flag and (on the single-item path)
                // immediately wraps up: sends `WIFI_CLOSE` + removes the hotspot config, and the card side will also turn off the hotspot.
                if let active = self.activeFastTransfer {
                    active.cancel()
                } else {
                    // ★ When a session **is being established** (the 45-second join window in `beginBatch`)
                    //   there is no "transmission in flight"; the above reference must be nil.
                    //   If we don't cancel it here, "stop" must wait for the window to expire —
                    //   the user presses stop but still has to wait a minute; that's not a stop (same reason as `cancel()`).
                    self.batchFastTransfer?.cancel()
                }
            },
            finished: { [self] in await self.finishBatch() }
        )
    }

    /// Before each item starts.
    ///
    /// ## Three steps, in this order
    ///
    /// **① Take the suppression lock only once per batch.** `beginRecorderWifiTransfer` will inform
    /// "Card disconnection BLE is part of the process" to `BluetoothCoordinator`, so it won't try to reconnect.
    /// Previously it was **one pair per item** begin/end, and `endRecorderWifiTransfer()` would
    /// `scheduleRecorderReconnect()` to start an automatic reconnection task — that task and the next
    /// `link()`'s `connectRecorder` (timeout [90, 150] seconds) will both first
    /// `teardownRecorderForReconnect()`（`central.cancelPeripheralConnection`），
    /// **Each side kills the other's in-progress connect**. The behavior on a real device is exactly what the user reported:
    /// "After transferring 1~2 items, the next one never moves again" — both sides were just quietly waiting.
    ///
    /// **② Create only one Wi-Fi session for the whole batch.** This is the second root cause dug out of the 2026-10-12 device logs,
    /// i.e. what the user described as "**having to tap connect to WiFi again after each recording transfer**".
    /// Before that, each item called `link.fastTransfer` —— that's a computed property, **it creates a new object each time**
    /// (`TicNoteLink.fastTransfer:1932`), so each item cold-starts from zero: start listening → `OPEN_WIFI`
    /// → the card drops BLE to bring up the hotspot → `NEHotspotConfiguration.apply` to join → wait for the card to connect.
    /// On a real device this sequence is extremely unreliable, and it failed on the 2nd item:
    /// ```
    /// 14:10:55.918 WIFI Fast transfer started sid=…190611 ← second entry, starting from scratch again
    /// 14:11:04.927 WIFI First iOS report "joined" ← took 6.2 s to join
    /// 14:11:24.940 WIFI After the first join, the card never connected — rejoining
    /// 14:11:55.688 WIFI ✗ Join hotspot aborted: tried 2 times ← ... ... ...
    /// ```
    /// Now changed to: the entire batch uses **one** instance (`batchFastTransfer`), `beginBatch()` cold-starts once,
    /// each intermediate line only goes through `cmder 12 / 13` (+ `14`), and `endBatch()` handles cleanup uniformly.
    ///
    /// **③ No longer reconnect BLE between the two.** During the session, the device stays on the hotspot, and **BLE is intentionally disconnected**;
    /// after reusing a single Wi-Fi session for the entire batch, BLE is completely unnecessary in between. The previous step
    /// `ensureRecorderLink(20s)` is now only kept in `finishBatch` (to rebuild the list at the end, which uses BLE).
    ///
    /// ## Idempotency + Self-healing
    /// `beginBatch()` checks itself: if the session is still alive, it returns immediately. So here **every call triggers it**:
    /// Alive = zero-overhead reuse; disconnected = restart once on the spot. This allows self-healing for issues like stuck restarts or hotspots being turned off,
    /// instead of making all remaining calls waste 30s timeouts.
    ///
    /// ## `batchOpenAttempts` limit 2 — and it counts **consecutive** failures
    /// The cost of failing to establish a session is **minute-level** (45 s join window × 2 times). If unlimited,
    /// A single environmental issue makes each of the 57 queued items wait a minute — the user sees it as "stuck".
    /// After the limit of 2, the remaining items immediately fail with the same reason, and the user instantly knows "WiFi is not connected".
    ///
    /// But **success resets the counter** (done in `transfer` of `makeTransferDriver`):
    /// If the 30th item in a batch of 57 hits a restart, it shouldn't cause 31~57 to all fail —
    /// the previous 29 successes already prove "this environment is connectable". So this counter tracks
    /// "**consecutive** failed session builds".
    ///
    /// - Returns: `nil` = can continue; a string = this item fails directly, with the reason displayed on this line as-is.
    private func prepareNextFile() async -> String? {
        if !batchHoldsWifiLock {
            batchHoldsWifiLock = true
            bulkTransferring = true
            preferWifi = true
            batchOpenAttempts = 0
            bluetooth.beginRecorderWifiTransfer(recordID: recorder.id.uuidString)
            TicNoteDiagLog.log("XFER",
                "Fast transfer started: holding the recorder card's auto-reconnect suppression lock"
                + " (taken once per batch; auto-delete after transfer=\(deleteAfterTransfer ? "on" : "off"))")
        }

        // ── The single instance shared by the whole batch ──
        // **Only fetch when needed**: swapping instances = losing the session, so once created, always keep using the same one.
        if batchFastTransfer == nil {
            // ① Bring BLE back up first. Do this only at this one moment —
            //    after the session is established, that middle link **never touches BLE again** (the card is acting as the hotspot, and BLE dropped on its own).
            //    This step serves both cases at once: the first record of the batch (the link is already up, so this is a zero-cost
            //    idempotent call), as well as "the previous session setup failed" (at that point the card has just been released back by our `WIFI_CLOSE`,
            //    and we need to wait for it to switch back to BLE — the 20 s window of `ensureRecorderLink` is exactly for waiting on this).
            _ = try? await bluetooth.ensureRecorderLink(recordID: recorder.id.uuidString, timeout: 20)
            // ② Get the fast-transfer channel on the **current** link.
            //    ⚠️ Deliberately not using `connectedLink` (the snapshot taken when entering the page): if the card drops and reconnects, it gets a
            //    new `TicNoteLink` object, and the one captured in the snapshot already has `isConnected` as false,
            //    and fetching `fastTransfer` from it will only yield nil.
            guard let shared = bluetooth.recorderLink?.fastTransfer else {
                TicNoteDiagLog.log("XFER",
                    "✗ Fast transfer channel unavailable (card not connected via BLE, or SN unreadable so hotspot credentials can't be computed)")
                return L10n.TicNoteCard.fastTransferUnavailable
            }
            batchFastTransfer = shared
        }

        // If it has failed consecutively twice, **do not retry establishing the session** — see "Limit 2" above.
        if batchOpenAttempts >= 2 {
            return L10n.TicNoteCard.fastTransferUnavailable
        }
        batchOpenAttempts += 1

        do {
            try await batchFastTransfer?.beginBatch()
            return nil
        } catch {
            let reason = describe(error)
            // ★ Session failed to establish → **discard this instance**. The next `prepare` will re-fetch
            //   `ensureRecorderLink` + a new one from (possibly already swapped) `bluetooth.recorderLink`
            //   — this is why "self-healing" can actually occur:
            //   The `TicNoteLink` pointed to by the `weak var ble` in the old instance has been invalidated after the card reconnection.
            batchFastTransfer = nil
            TicNoteDiagLog.log("XFER",
                "✗ Failed to open fast-transfer session (\(reason)) -- this item is marked failed"
                + " (tried \(batchOpenAttempts)/2 times; after two failures the remaining items no longer wait a minute each)")
            return reason
        }
    }

    /// Finish the entire batch. **Success, failure, and cancellation must all run** (called unconditionally once after the loop in `TicNoteTransferModel.run`).
    /// 
    ///
    /// ⚠️ Forgetting to suppress the lock is the most expensive mistake in this file: after a hang, the card will be **permanently** treated as "transferring fast",
    ///    and when it disconnects on its own, it will no longer auto-reconnect — the UI shows "Not Connected", and the user will think the transfer damaged the card.
    private func finishBatch() async {
        // 1. Close Wi-Fi session (send `WIFI_CLOSE`, disconnect hotspot, stop listening).
        //    This step must be done **before** releasing the lock and reconnecting BLE — otherwise the phone remains attached to the card's hotspot without internet access,
        //    `ensureRecorderLink`'s BLE connection cannot be re-established.
        if let shared = batchFastTransfer {
            await shared.endBatch()
            batchFastTransfer = nil
        }
        if batchHoldsWifiLock {
            bluetooth.endRecorderWifiTransfer()
            batchHoldsWifiLock = false
        }
        bulkTransferring = false
        batchOpenAttempts = 0
        // Reconnect the link — the list below is reloaded, and the list is only readable over BLE.
        // Fast path, 20 s window; failure to reconnect does not affect the fact that "the file is already on the phone".
        _ = try? await bluetooth.ensureRecorderLink(recordID: recorder.id.uuidString, timeout: 20)
        // ⚠️ Do **not** show loading (`showsLoading: false`) when refreshing: right after a batch transfer,
        //    the user is watching the rows of checkmarks/errors; flashing the whole page as "Reading recordings..." would
        //    cover up the feedback they want to see most — this is exactly the "always reading recordings on every switch" complaint.
        await connectAndList(showsLoading: false)
        // ★ After transfer, re-evaluate: if this batch is fully committed, **auto-collapse** the bottom
        //   (the `pending.isEmpty` case in `refreshWifiFallback`); leave any failures as is.
        refreshWifiFallback()
    }

    /// Swipe to delete → show confirmation (actual deletion happens in `deleteFromCard`).
    private func deleteRecordings(at offsets: IndexSet) {
        guard let index = offsets.first, recordings.indices.contains(index) else { return }
        pendingDelete = recordings[index]
    }

    /// /// Delete a recording from the card (swipe → confirm).
    ///
    /// ## ⚠️ The delete command for this path is BLE `0x1E`, which **breaks the Bluetooth connection**
    /// The real-device log from 2026-10-12 11:23:48 confirms its side effects:
    /// ```
    /// 11:23:48.123 → WC 01 1E 00 ED 3C CC 6A 00      ← Send delete frame
    /// 11:23:49.429 LINK disconnected error=CBErrorDomain Code=6
    ///              "The connection has timed out unexpectedly."   ← Link dropped 1.3 s later
    /// ```
    /// And it **has never received any acknowledgment on a real device**. So:
    /// * "Delete after transfer"**does not follow this**(Wi-Fi session uses `cmder 14`, see `download`);
    /// * Manual deletion can only use it (Wi-Fi session is not persistent, there is no other channel here),
    ///   After sending, the link dropping is **expected behavior**, `BluetoothCoordinator` will automatically reconnect;
    /// * Failure only shows a prompt, does not clear the list: the list reflects the actual values on the card.
    private func deleteFromCard(_ recording: RecorderRecording) async {
        do {
            let link = try await link()
            try await link.deleteRecording(recording)
            // Re-list after deletion: likewise **don't show loading** (the list updates in place, and the deleted row disappears on its own).
            await connectAndList(showsLoading: false)
            if !recordings.contains(where: { $0.id == recording.id }) {
                banner = L10n.TicNoteCard.deletedFromCard
            } else {
                banner = L10n.TicNoteCard.deleteFailedFromCard
            }
        } catch {
            errors[recording.id] = shortReason(error as? RecorderLinkError ?? .timeout)
        }
    }
}

// MARK: - Shell Popup

/// // MARK: - Shell Modal
/// // Appears as a sheet after tapping a card on the scan page. **Shell only** — list / download / quick transfer / recording controls
struct RecorderSheet: View {

    @Environment(\.dismiss) private var dismiss

    let recorder: DiscoveredRecorder

    /// The main content of this page. See `RecorderDeviceView.Mode` ——
    /// "Both entry points that "tap device" (from the scan page connection and the top bar capsule) pass `.deviceInfo`.
    var mode: RecorderDeviceView.Mode = .recordings

    var body: some View {
        NavigationStack {
            RecorderDeviceView(recorder: recorder, mode: mode)
                .navigationTitle(recorder.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

// MARK: - Used Storage (cmd 0x06)

/// "Used Storage" — the card's own reported capacity and usage.
///
/// ## Where the data comes from
/// Read the response from command `01 06 00` (`WriteCmd::getStorageVolume`), 13 bytes, fixed length:
/// ```
/// 01 06 00 | 00 e2 a3 03 | 00 0d a2 03 | 40 9c 00 00 | 00
///            └─ totalKB ─┘  └─ freeKB ──┘  └  semantics unresolved ┘   └ state
/// ```
/// Real device sample: total = 61,071,872 KB (58.24 GiB), free = 60,951,808 KB (58.13 GiB),
/// The two differ by **117.25 MB** —— both matching the "117 MB / 58.2 GB" shown on that screen of the official App.
/// This is the verification criterion for this byte layout (units are KB, see `TicNoteStorageInfo`).
///
/// ## ⚠️ Do not draw a 0% progress bar
/// A 0% progress bar looks like "the card is full", while the truth is "unknown".
/// So if not read, only show a gray text line (`storageNotRead`); while reading, show a spinner.
///
/// ## ⚠️ Do not hardcode any card
/// This section only consumes `RecorderDeviceInfo.storage` (decoded from the current card's response),
/// and maintains no state of its own — switch to a different card or SN, and it will display that card's capacity.
private struct CardStorageSection: View {

    /// Card-reported usage. `nil` = not yet read ( **not** "0 bytes", see type documentation).
    let storage: RecorderStorageInfo?
    /// Reading card status (the "Read card status" button in the row above).
    let isReading: Bool

    var body: some View {
        Section {
            if let storage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("\(storage.usedText) / \(storage.totalText)")
                            .font(.callout.monospacedDigit())
                        Spacer(minLength: 8)
                        // Percentage is only meaningful below one decimal place —— 117 MB / 58 GB is 0%.
                        // That's not a display error; the card is genuinely nearly empty.
                        Text(percentText(storage.usedFraction))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    // Clamped to 0…1: `ProgressView(value:)` draws an out-of-bounds segment when given a value outside the range.
                    ProgressView(value: min(max(storage.usedFraction, 0), 1))
                        .progressViewStyle(.linear)
                    HStack {
                        Text(L10n.TicNoteCard.storageFree)
                        Spacer()
                        Text(storage.freeText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else if isReading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.TicNoteCard.storageNotRead)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.TicNoteCard.storageNotRead)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.TicNoteCard.storage)
        } footer: {
            Text(L10n.TicNoteCard.storageFooter)
                .font(.caption2)
        }
    }

    /// `"0.2%"`. When usage is extremely low, `0.0%` is displayed — showing the actual value without rounding up to a false number.
    private func percentText(_ fraction: Double) -> String {
        let pct = fraction * 100
        if pct >= 10 { return String(format: "%.0f%%", pct) }
        return String(format: "%.1f%%", pct)
    }
}

// MARK: - Microphone Gain (cmd 0x08 write direction)

/// "Microphone Gain" — the item on the official card device page (l10n keys `myNewDevice_Mic` / `myDevice_mkfeng`).
///
/// ## This is not the text command family from `nveasy`
/// The previous version judged it as "gain goes through `nveasy`'s `*APP#micgain#`", **that judgment was wrong**:
/// `nveasy`'s UUID is `06068d0c-…`, while the probe on a real device only saw two services, `1910` and `180F`,
/// no `06068d0c` at all; within `blutter_out/asm/ticnote/`, `nveasy` is only referenced by the **headset**
/// (TicNote Pods), those three files. The real channel is **the write direction of the generic settings `0x08`**:
/// ```
/// App→Card  01 08 00 | 02 <rec_led_status> <rec_scene> <rec_mode> <row_data> <micCode>
/// Card→App  01 08 00 | 00 02 00 01 7f 00 00     ← Reply once upon receipt, i.e., "write success"
/// ```
/// Two levels are hardcoded by the official `field_97 = [214, 254]`: index 0 → `0xD6` (UI writes `24 db`),
/// index 1 → `0xFE` (`36 db`). See `TicNoteMicrophoneGain` / `writePayload(gain:)` for the byte origin.
///
/// ## ★ Why the UI displays "the value the card reports"
/// On a real device the card self-reports `dmic_mode` as **`0x7F` (127)**, **not among `[0xD6, 0xFE]`** —
/// in other words, **no single reply packet can tell us which gain step is actually in effect right now**.
/// (The official App likewise falls back to index 0 on the same card, so the `24 db` it shows is also a default,
/// not a value read back.) This section therefore states it honestly in two parts:
/// * Which step you set last time (stored locally per card, see the `@AppStorage` key below);
/// * What the card itself reports (`micGainCardReports`, shown only when the value is "not one of the two steps").
/// No pretending we read the real value back, and no papering over it with "set to 24 dB".
///
/// ## ⚠️ Why not hardcode the current card's value
/// The setting is stored under **`ticnote.mic_gain.<key for this card>`**, where the key is computed and passed down from the upper layer
/// (`RecorderDeviceView.cardScopeKey`, prioritizing SN, falling back to peripheral UUID, and normalizing case).
/// Swapping to a different card means a separate setting — the 36 dB chosen for Card A won't overwrite Card B's setting.
private struct CardMicGainSection: View {

    @ObservedObject var link: TicNoteLink

    /// Storage key keyed by **this card** (see end of type docs).
    let cardScopeKey: String

    /// Which tier the user last set. Using `@AppStorage` instead of `@State`:
    /// Each time the popup opens, this page is rebuilt; `@State` would be lost on dismiss/reappear.
    ///
    /// ⚠️ This uses a **dynamic-key** `@AppStorage` (built in `init` from `cardScopeKey`),
    ///    not a hardcoded string constant -- which is exactly where "not hardcoding a single card" lands.
    @AppStorage private var stored: Int

    @State private var notice: String?
    @State private var isApplying = false

    init(link: TicNoteLink, cardScopeKey: String) {
        self.link = link
        self.cardScopeKey = cardScopeKey
        _stored = AppStorage(wrappedValue: TicNoteMicrophoneGain.db24.rawValue,
                             "ticnote.mic_gain." + cardScopeKey)
    }

    /// The pickup mode value reported by the card itself, returned only when it does not fall within the two ranges (real device always `0x7F`).
    /// If it falls within the two ranges, that digit is the gain itself and requires no further explanation.
    private var cardReportedOutsideTable: Int? {
        guard let s = link.lastGeneralSetting,
              TicNoteMicrophoneGain.fromCode(s.dmicMode) == nil
        else { return nil }
        return Int(s.dmicMode)
    }

    /// Whether it can be written. Writing a frame must **write back the card's current 5 settings as-is**, so `0x08` must be read first.
    /// If it can't be read, don't allow tapping —— this isn't "one less feature", it's "a missing precondition"
    /// (one of the three constraints of `TicNoteGeneralSetting.writePayload`).
    private var canApply: Bool {
        link.isConnected && link.lastGeneralSetting != nil && !isApplying
    }

    var body: some View {
        Section {
            // ★ **Tap once to write** — no two-step "select then write".
            //   User 2026-10-12: "The gain should be directly clickable, not requiring selection followed by a write click."
            //
            //   Why use two `Button`s instead of `Picker(.segmented)` + `onChange`:
            //   Writing may fail (must wait for a `0x08` card response to count as success), and on failure the selected state must revert to the original file;
            //   Changing the `Picker` binding triggers `onChange` again → self‑loop.
            //   The button makes the selected state driven unidirectionally by `stored`: it only moves there when `apply` succeeds.
            HStack(spacing: 10) {
                ForEach(TicNoteMicrophoneGain.allCases) { gain in
                    micGainButton(gain)
                }
            }

            if isApplying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.TicNoteCard.micGainApplying)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let reported = cardReportedOutsideTable {
                Label(L10n.TicNoteCard.micGainCardReports(reported),
                      systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Clearly explain **why** the preconditions aren't met, instead of just graying out the button.
            if link.lastGeneralSetting == nil {
                Label(L10n.TicNoteCard.micGainNotRead, systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.TicNoteCard.micGain)
        } footer: {
            Text(L10n.TicNoteCard.micGainFooter)
                .font(.caption2)
        }
    }

    /// One button per slot, tapping it **immediately** sends a `0x08` write frame.
    ///
    /// Selection state is **unidirectionally driven** by `stored` — it is only moved to the new tier when `apply` succeeds.
    /// On write failure, it remains unchanged, so the UI stays on the current tier and **does not** display a tier that did not actually take effect.
    private func micGainButton(_ gain: TicNoteMicrophoneGain) -> some View {
        let isSelected = gain.rawValue == stored
        return Button {
            // Clicking the already-active gain is a no-op, skipping a meaningless write.
            guard !isSelected else { return }
            Task { await apply(gain) }
        } label: {
            Text(gain.label)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.16)
                                         : Color.secondary.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear,
                                      lineWidth: 1.5)
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!canApply)
        // When writing isn't possible (`0x08` not yet read, or a write in progress), reduce the opacity so it doesn't look tappable.
        .opacity(canApply ? 1 : 0.5)
    }

    /// Write one frame of `0x08`, wait for the card to echo back one `0x08` (criteria see `TicNoteLink.setMicrophoneGain`).
    ///
    /// ★ Directly invoked by **clicking the gear button** — only moves the selected state to this gear on success.
    private func apply(_ gain: TicNoteMicrophoneGain) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }
        // Clear out the previous result first —— otherwise the "success" message will keep hanging there,
        // and the user will think this attempt succeeded too.
        notice = nil
        do {
            try await link.setMicrophoneGain(gain)
            // ⚠️ **Only move the selection state on success**. On write failure, it stays put, leaving the UI at the original file —
            //    This pairs with "tap to write": without a "Write" button as a fallback, the selection state itself is a promise,
            //    If the promise isn't fulfilled, it must not be rendered.
            stored = gain.rawValue
            notice = L10n.TicNoteCard.micGainSaved
            TicNoteDiagLog.log("SET", "Microphone gain write \(gain.label) (code 0x\(String(format: "%02X", gain.code)))")
        } catch {
            // `RecorderLinkError` conforms to `LocalizedError`, and `localizedDescription` is the message intended for the user.
            notice = "\(L10n.TicNoteCard.micGainFailed) \(error.localizedDescription)"
            TicNoteDiagLog.log("SET", "Microphone gain write failed \(String(describing: error))")
        }
    }
}

// MARK: - Name (App-side alias, mapped to card key)

/// "Name" — changes the name displayed in **this App**, not the name broadcasted by the card.
///
/// ## Why an alias instead of a Bluetooth command
/// Three arguments are written at the top of `RecorderAliasStore` (the official path uses cloud REST, and the card's command table has 27 functions that
/// do not include setName, and the Android SDK path falls into a heavily obfuscated layer and is a public SDK shared across multiple device families).
/// This section only handles the UI; all rules are in the store.
///
/// ## ⛔ 2026-10-12: The old form **never succeeded even once**, switched to an inline input field
///
/// User reported "Failed to modify name". Went to a real device for evidence: this App only writes to `UserDefaults.standard`
/// writes 4 keys (3 from `@AppStorage` + `RecorderIdentityStore`'s
/// `ticnote.recorder_identity.v1`), pulled them down and took a look —— the other 3 are all there,
/// **only `ticnote.recorder_alias.v1` is completely missing**. That is to say
/// `RecorderAliasStore.setAlias` was never called, `persist()` never ran once.
/// (The store itself is fine: the self-check group in §22 has nailed down key naming / over-length rejection / cross-card isolation.)
///
/// The old behavior was "tap a row → present a small sheet", which had three potential failure points that could all result in **silent inaction**.
/// Moreover, there is no way to distinguish which one it is from the UI:
/// ```
///   ① Popping another sheet from the already-present "Card Info" sheet (nested presentation)
///      —— no prompt appears when the presentation fails;
///   ② `save()` returns immediately on "empty / too long", and the keyboard Done button (`.onSubmit`) follows the same path
///      —— pressing it is equivalent to not pressing it at all;
///   ③ when the save button is `disabled`, users only perceive it as "unresponsive".
/// ```
/// Inline input eliminates all three issues: no popup, persistence on every keystroke, real-time red highlighting for over-length with a character count.
///
/// ## When to persist: **write on every character change**
/// No debouncing, and no waiting for a "Save" button either. The reasoning is the same as in the microphone gain section (the user explicitly asked for
/// "tapping directly, rather than selecting first and then tapping write"): the most expensive failure on this path is
/// **"I thought I'd changed it, but it wasn't actually saved"**, not "writing UserDefaults a few extra times" (a dictionary assignment).
/// The cost is that quitting midway leaves behind a half-finished name — the user can always restore it to the card's own name with the line below.
///
/// ## ⚠️ The 20-character limit comes from the official copy pool
/// That `"Name too long (up to 20 characters)"` line in `pp.txt` is the card's own limit.
/// If it's overlong, **don't write** it (keep the last valid value), and turn the inline counter red — don't silently truncate,
/// otherwise the user will think their input went through.
private struct CardNameSection: View {

    let recorder: DiscoveredRecorder

    /// Observe it; the entire page only redraws after renaming (`recorder.displayName` is just a regular computed property).
    @ObservedObject var aliasStore: RecorderAliasStore

    @State private var draft: String

    init(recorder: DiscoveredRecorder, aliasStore: RecorderAliasStore) {
        self.recorder = recorder
        self.aliasStore = aliasStore
        // Pre-fill the **currently displayed name** (if there's an alias, use the alias) — if pre-filled with an empty string,
        // the user would have to type everything from scratch each time, making it impossible to "change just one character".
        _draft = State(initialValue: recorder.displayName)
    }

    /// The trimmed draft —— used for persistence checks and the "too long" warning.
    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var isTooLong: Bool { trimmedDraft.count > RecorderAliasStore.maxLength }

    var body: some View {
        Section {
            // The entire row is the input field (the standard approach in iOS forms): no need to tap to open first, and no sheet pops up.
            TextField(L10n.TicNoteCard.renamePlaceholder, text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .foregroundStyle(isTooLong ? Color.orange : Color.primary)
                .onChange(of: draft) { _ in commit() }
                .onSubmit { commit() }

            if recorder.hasAlias {
                Button {
                    aliasStore.setAlias(nil, for: recorder)
                    draft = recorder.name
                } label: {
                    Label(L10n.TicNoteCard.renameRestore, systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text(L10n.TicNoteCard.deviceName)
        } footer: {
            if isTooLong {
                // Display "Why didn't it take effect?" explicitly: count + limit text.
                // The old state is silent here; users will only conclude "Rename failed".
                Text("\(trimmedDraft.count) / \(RecorderAliasStore.maxLength) · "
                     + L10n.TicNoteCard.renameTooLong)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else {
                Text(L10n.TicNoteCard.renameFooter + " " + L10n.TicNoteCard.renameLimit)
                    .font(.caption2)
            }
        }
    }

    /// Write the current draft into the alias table. **Called on every keystroke** (see type documentation "Persistence Timing").
    ///
    /// Deliberately **no** "success notification": the name appears immediately in the title of this page and in the scanning list row,
    /// The feedback is right in front of you. Adding a notice would cause it to flash with every keystroke.
    private func commit() {
        let name = trimmedDraft

        // ① Too long → skip writing, keep the previous valid value (the counter is already highlighted in red inline).
        guard name.count <= RecorderAliasStore.maxLength else { return }

        // ② Empty / exactly matches **the card's own broadcast name** → means "no alias was ever set".
        //    Otherwise, it would save an extra record that shares the card's name and looks like an alias,
        //    and the "Use the card's own name" row would inexplicably appear.
        if name.isEmpty || name == recorder.name {
            guard recorder.hasAlias else { return }          // It doesn't exist anyway, so no need to write it.
            aliasStore.setAlias(nil, for: recorder)
        } else {
            guard aliasStore.alias(for: recorder) != name else { return }   // No change, don't write pointlessly
            aliasStore.setAlias(name, for: recorder)
        }

        // ③ Leave a log. On a real device, `UserDefaults` can only prove whether it was written,
        //    It cannot prove whether it was attempted — this log adds the second half (tag `ALIAS`).
        TicNoteDiagLog.log("ALIAS",
            "Rename record \(recorder.identityText) input=[\(draft)] saved=[\(name.isEmpty ? "<restore card name>" : name)]")
    }
}

// MARK: - Unbind device (cmd 0x05, red, placed at the bottom)

/// "Unbind Device" — **red**, destructive, with a second confirmation.
///
/// ## The user's exact words are about position and color
/// > "Add a red-font 'Unbind Device' option at the bottom of the device information"
/// So: the position should be at the very end of this screen (destructive actions shouldn't be placed in the middle; users should scroll down to the bottom to see it),
/// Color **explicitly** written as red (role: .destructive usually appears red in List,
/// But if the user explicitly wants this color, we shouldn't rely on the system's default coloring).
///
/// ## ⚠️ Do not hide when disconnected, only disable
/// Lost card / Returned / This firmware version cannot connect — these are exactly the scenarios of "want to remove it from the App".
/// Hiding the button would give the user no way out. While disabling, use `unbindOffline` to explain the reason,
/// and lower the color (red but unclickable, looking broken).
///
/// ## What the copy says and doesn't say
/// The official text is "Unbinding will clear all device data", but that describes its **entire cloud process**:
/// In our frame (`01 05 00 00`) we don't include the clear-data parameter; clearing data on the card is **a separate command**.
/// Thus `unbindConfirmMessage` explicitly states "Recordings on the card will not be deleted" — the copy must reflect what we actually do.
private struct CardUnbindSection: View {

    /// Whether the link is available (`TicNoteLink.isConnected`). false → disabled + explanation.
    let isConnected: Bool
    /// Frame sent, waiting for result (UI shows spinner, and **prevent duplicate taps**).
    let isWorking: Bool
    /// Tap → upper layer shows a secondary confirmation (`showUnbindConfirm = true`), **not** immediate unbind.
    let request: () -> Void

    var body: some View {
        Section {
            Button(role: .destructive) {
                request()
            } label: {
                HStack(spacing: 8) {
                    Label(L10n.TicNoteCard.unbind, systemImage: "link.slash")
                        .foregroundStyle(.red)
                    if isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!isConnected || isWorking)
            // Red but not tappable = looks broken. When disabled, lower the color.
            .opacity(isConnected && !isWorking ? 1 : 0.45)

            if !isConnected {
                Label(L10n.TicNoteCard.unbindOffline, systemImage: "wifi.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isWorking {
                Text(L10n.TicNoteCard.unbinding)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.Device.dangerZone)
        }
    }
}

// MARK: - Card's generic self-report settings

/// Card generic settings (`0x08` response) **decoding result**.
///
/// ## Why this deserves its own section
/// In the start‑recording frame `02 28 00 | 02 <scene> 00 00 00 00`, that **scene byte is the `recScene`**
/// (Official `beginRec`: read settings first, then use it to start recording). So when users report "tap record no response",
/// this section can immediately answer one question: **which scene we actually sent**.
/// Previously this value could only be obtained by inspecting packets, now it’s displayed on screen.
///
/// ⚠️ Field layout is determined by cross‑referencing two sources (real‑device log map + packet bytes), see `TicNoteGeneralSetting`.
/// Only the 5 decoded fields are shown — the last 2 bytes have no sample, so no name is given.
private struct CardSettingsSection: View {

    @ObservedObject var link: TicNoteLink

    var body: some View {
        Section {
            if let s = link.lastGeneralSetting {
                LabeledContent(L10n.TicNoteCard.recordScene, value: "\(s.recScene)")
                LabeledContent(L10n.TicNoteCard.recordMode, value: "\(s.recMode)")
                LabeledContent(L10n.TicNoteCard.recordingLED,
                               value: s.ledStatus == 0 ? L10n.TicNoteCard.ledOff : L10n.TicNoteCard.ledOn(Int(s.ledStatus)))
                LabeledContent(L10n.TicNoteCard.rowData, value: "\(s.rawData)")
                LabeledContent(L10n.TicNoteCard.micMode, value: "\(s.dmicMode)")
            } else {
                Text(L10n.TicNoteCard.notReadYet)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.TicNoteCard.cardSettings)
        } footer: {
            Text("Decoded from the card's own settings reply (0x08). The record scene "
               + "is the byte the record command carries — if recording does nothing, "
               + "this is the scene we sent.")
                .font(.caption2)
        }
    }
}

// MARK: - Transfer preferences (App side, card firmware has no such switches)

/// Switch to automatically delete the recording on the card after transfer.
///
/// Why placed in **this** popup: the user said "need to add an option in the ticnote device" ,
/// and the card info popup is the "TicNote device's own settings" screen
/// (card firmware's 0x08 settings + App-side behavior preferences for this card, only found when combined).
private struct CardTransferPrefsSection: View {

    /// `@AppStorage` maps directly to UserDefaults — the card firmware lacks this switch,
    /// this is **App-side behavior**: after a successful download, it conveniently sends a delete command (see `download(_:)`).
    @AppStorage("ticnote.delete_after_transfer") private var deleteAfterTransfer = false

    var body: some View {
        Section {
            Toggle(isOn: $deleteAfterTransfer) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.TicNoteCard.deleteAfterTransfer)
                    Text(L10n.TicNoteCard.deleteAfterTransferFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L10n.TicNoteCard.transferPrefs)
        } footer: {
            Text(L10n.TicNoteCard.transferPrefsFooter)
                .font(.caption2)
        }
    }
}

// MARK: - Every frame the card has sent (currently not attached to UI)

/// Card→App **control frame stream**.
///
/// # ⚠️ Current state: **not in any UI**
///
/// 2026-10-10 removed from the "Card Info" popup per user request (the call site left three commented‑out lines,
/// see `cardInfoSheet`). The reason isn’t that it’s useless, but **placed in the wrong location**:
/// It provides the raw frame stream for our troubleshooting, while "Card Info" is what users open to view,
/// it should contain battery level, serial number, model, and the card’s responses to its own queries.
/// A full‑screen hex list placed there would push the three truly useful lines out of view.
///
/// When needed, retrieving it costs **one line** (just uncomment in `cardInfoSheet`) —
/// The implementation below does **not modify at all** the collection in `TicNoteLink.inboundLog`,
/// so historical frames have been accumulating, and once retrieved they appear immediately.
///
/// ## Why this originally deserved a full screen
/// On a real device, the issue "tapping the record button yields no response" cannot be judged from the App side alone **(indeterminate)**:
/// The command was sent, `writeValue` succeeded, then what? Did the card actually make a sound or not?
/// Real‑device logs are unavailable to the user, so we stitch every frame the card sent into a timeline —
/// When the user captures a screenshot, we can determine:
///
/// * Card **responded** with `0x14`/`0x17` → recording actually started; it’s an App display issue;
/// * Card **didn’t respond at all** → it doesn’t recognize this frame code (`0x14` only appears in captures as card→App,
///   App→Card direction was originally inferred), need to change code and retry;
/// * Card responded with another code → we can instantly tell what it’s saying.
///
/// ⚠️ Consecutive frames with identical content are collapsed into `×N` (see `TicNoteInboundLogEntry.repeatCount`) —
/// At a 1 Hz poll, two identical frames per second would, without collapsing, flood the useful rows in 20 seconds.
private struct CardRepliesSection: View {

    @ObservedObject var link: TicNoteLink

    var body: some View {
        Section {
            if link.inboundLog.isEmpty {
                Text("Nothing back from the card yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(link.inboundLog) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.label)
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text(entry.byteCountLabel)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.hex)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text("Card replies")
        } footer: {
            Text("Everything the card has said on Bluetooth, newest first. "
               + "Repeated lines are collapsed with a count. If you report a problem, "
               + "a screenshot of this list is the most useful thing you can send.")
                .font(.caption2)
        }
    }
}
