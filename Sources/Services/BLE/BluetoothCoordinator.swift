import Combine
import CoreBluetooth
import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "ble")

/// Owns the singleton `CBCentralManager`, surfaces scanning state to SwiftUI,
/// and brokers connection requests by handing the live peripheral to a
/// fresh `DnoteClient` once `centralManager(_:didConnect:)` fires.
@MainActor
final class BluetoothCoordinator: NSObject, ObservableObject {
    enum AdapterState: Equatable {
        case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn

        init(_ raw: CBManagerState) {
            switch raw {
            case .unknown:      self = .unknown
            case .resetting:    self = .resetting
            case .unsupported:  self = .unsupported
            case .unauthorized: self = .unauthorized
            case .poweredOff:   self = .poweredOff
            case .poweredOn:    self = .poweredOn
            @unknown default:   self = .unknown
            }
        }

        var userMessage: String? {
            switch self {
            case .poweredOn:    return nil
            case .poweredOff:   return "Bluetooth is off. Turn it on in Settings."
            case .unauthorized: return "Bluetooth permission was denied. Enable it in Settings → Nomily AI."
            case .unsupported:  return "This device does not support Bluetooth Low Energy."
            case .resetting:    return "Bluetooth is restarting…"
            case .unknown:      return "Initialising Bluetooth…"
            }
        }
    }

    @Published private(set) var adapter: AdapterState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var discovered: [DiscoveredPeripheral] = []
    @Published private(set) var client: DnoteClient? {
        didSet {
            clientSink?.cancel()
            clientSink = client?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    /// **Registry-driven scan results** — only install non‑D·NOTE recorder cards (TicNote is now here).
    ///
    /// ⚠️ Why not merge into the above `discovered`: `DiscoveredPeripheral` carries
    /// `DnoteProduct` / `deviceSID` / firmware battery level and other D·NOTE‑specific fields, and is
    /// `ConfigService` persisted by `deviceSIDHex`. Changing it to optional/generic would affect
    /// scan rows, device page, binding flow extensively — but this round's goal is precisely **to keep D·NOTE completely unchanged**.
    /// Two lists are displayed categorically on the scan page, making semantics clearer: one "D·NOTE device", one "recorder card".
    @Published private(set) var discoveredRecorders: [DiscoveredRecorder] = []

    /// Connected **non‑D·NOTE** recorder card. Mutually exclusive with `client` (only one can be connected at a time).
    ///
    /// ⚠️ **Deliberately not forwarding the publisher**: `RecorderLink` is an existential type (`any`),
    /// cannot obtain a concrete value for the associated type `ObjectWillChangePublisher`; forced forwarding would either fail to compile,
    /// or require a slew of constraints on the protocol. Moreover, observation is unnecessary here —
    /// The "in‑progress download" state is provided by the **callback** of `fetchRecording(_:progress:)`,
    /// held by the caller's own `@State`. The UI only depends on the coordinator's `@Published`.
    @Published private(set) var recorderLink: (any RecorderLink)?
    /// The most recent read‑only state from the connected recorder card. Keep `nil` when battery level is unavailable,
    /// so the top bar can display the name; do not fake it as 0%.
    @Published private(set) var recorderDeviceInfo: RecorderDeviceInfo?
    /// The most recent card hit by `reconnectRecorder` scan (see method comment).
    /// `connectRecorder` also includes it on a normal connection (the scan page already holds this value).
    @Published private(set) var matchedRecorder: DiscoveredRecorder?

    /// Automatic reconnection progress of the recorder card, for UI display. `nil` = not reconnecting.
    ///
    /// Why have this instead of a simple `Bool`: the user reported verbatim
    /// "Current experience is not smooth, requiring repeated reconnection clicks" — the issue is not just "cannot connect",
    /// but **the UI says nothing during reconnection**, forcing the user to keep tapping. With this field,
    /// the UI can show "attempt number / what is being waited for", turning the correct user action from "tap again"
    /// to "wait", which is the smooth experience.
    @Published private(set) var recorderReconnectState: RecorderReconnectState?

    /// Snapshot of the recorder card reconnection state.
    struct RecorderReconnectState: Equatable {
        /// Attempt count (starting from 1).
        var attempt: Int
        /// The name of this card. Used by the UI — the top‑bar capsule cannot obtain `recorderLink` after disconnection,
        /// so relying solely on it would display the name as "Unknown Device".
        var deviceName: String
        /// Which path to use in this stage: `true` = scan‑free fast path (`retrievePeripherals`),
        /// `false` = fall back to scanning and waiting for advertisements. The UI presents different wording accordingly —
        /// Fast path usually takes a few seconds; scanning path may wait up to a full advertisement cycle (measured up to 152 s).
        var usingFastPath: Bool
        /// Who triggered it: `true` = user‑initiated, `false` = automatic after disconnection.
        /// Automatic reconnection failures **should not show a dialog** (user did nothing), while manual failures must present a result.
        var userInitiated: Bool
        var startedAt: Date
    }

    /// DEVICE_SID of whatever `client` is currently connected to, when we
    /// learned it from the advertisement. Needed because `DnoteClient` only
    /// carries the iOS-assigned peripheral UUID — without this,
    /// `reconnect(deviceSID:)` cannot tell "already connected to the device
    /// you asked for" from "already connected to the *other* device".
    private(set) var connectedDeviceSID: Data?

    /// Set to a non-nil value right after a successful connect/reconnect
    /// when the device reports itself as unbound (v1.47). RootView binds to
    /// this with `.alert(item:)` and asks the user to confirm pairing; it
    /// clears the value either way. Read-write so the alert can dismiss.
    @Published var pendingPairing: PendingPairing?

    /// Bumped every time the active device drops without the user asking for
    /// it (powered off, out of range, link lost). Observers use it as the
    /// trigger for auto-reconnect; a deliberate `disconnect()` never bumps it.
    @Published private(set) var unexpectedDisconnects = 0

    /// Captured for RootView's pairing alert. The suggested bond_id is
    /// generated once per connect so tapping "Pair" doesn't roll a new
    /// value if the dialog gets re-rendered.
    struct PendingPairing: Identifiable, Equatable {
        let id = UUID()
        let peripheralID: String
        let displayName: String
        let suggestedBondID: Data
    }

    private var central: CBCentralManager!
    private var clientSink: AnyCancellable?
    private var scanStopTask: Task<Void, Never>?
    /// Set by `disconnect()` and consumed by the disconnect delegate so a
    /// deliberate teardown isn't mistaken for a dropped link.
    private var userInitiatedDisconnect = false

    /// Pending connection contexts keyed by peripheral identifier so the
    /// `centralManager(_:didConnect:)` / `…didFailToConnect:` callbacks can
    /// route events to the right `DnoteClient` instance.
    private var pendingConnections: [UUID: PendingConnection] = [:]

    private struct PendingConnection {
        let client: DnoteClient
        let continuation: CheckedContinuation<DnoteClient, Error>
    }

    /// Pending connection for a non‑D·NOTE recorder card (TicNote follows this path).
    ///
    /// Separated from `pendingConnections` into two tables because their continuation **return types differ**
    /// (`DnoteClient` vs `any RecorderLink`), and the `didConnect` callback only provides the peripheral —
    /// After splitting, whichever table contains the UUID determines which handshake path to take.
    /// The benefit is that the D·NOTE path **remains byte‑for‑byte unchanged**.
    private var pendingRecorders: [UUID: PendingRecorderConnection] = [:]

    private struct PendingRecorderConnection {
        let link: any RecorderLink
        let continuation: CheckedContinuation<any RecorderLink, Error>
    }

    /// Automatic reconnection task after disconnection. Only one allowed at a time (new cancels the old).
    private var recorderReconnectTask: Task<Void, Never>?

    /// Reconnection "round" counter. Used to prevent **replaced old tasks** from refreshing the state for a new round:
    /// An old task, after cancellation, may still emerge from a `catch` block and reach the final statement,
    /// Comparing integers is sufficient; no need to compare `Task` objects for identity.
    private var recorderReconnectGeneration = 0

    /// Set to true when the user manually initiates reconnection, to decide whether to surface failures to the user.
    /// Like `userInitiatedDisconnect`, it is **single‑use**: the consuming path clears it.
    private var recorderReconnectWasUserInitiated = false

    /// Back‑off interval for automatic reconnection (seconds).
    ///
    /// Why not a fixed interval: after a disconnection the card often **reconnects immediately** (brief interference, moving in/out of range),
    /// so the first few attempts should be fast; if the card is truly asleep (advertisement interval up to 152 s),
    /// dense retries just waste power, so spacing them out is more reasonable.
    /// The final step **repeats indefinitely** (not "give up after trying" ) — the user said
    /// "Need to maintain a continuous connection state", so we should keep trying to bring it back,
    /// and the UI state will indicate success or failure.
    private static let recorderReconnectBackoff: [TimeInterval] = [1, 2, 4, 8, 15, 30]

    /// Number of ongoing "recorder card Wi‑Fi fast transfer" attempts.
    ///
    /// ## Why this counter is needed
    /// The first step of fast transfer is to make the card enable its hotspot, and the card **immediately drops BLE** once the hotspot is on (measured about 1.8 s later,
    /// see `TicNoteLink.sendOpenWifi`). This disconnection is part of the flow, not a fault —
    /// but `didDisconnectPeripheral` cannot distinguish "card broken" from "card opened hotspot",
    /// so it immediately starts automatic reconnection: during the entire 45‑second hotspot‑join window, the background keeps scanning + connecting, and the top bar shows "Reconnecting",
    /// while the user is waiting for the fast‑transfer progress.
    ///
    /// Use a **counter** instead of a Boolean: if multiple recordings are allowed to fast‑transfer concurrently in the future,
    /// the first to finish must not release the suppression for the others. Currently it's 0/1, but the semantics are correct from the start.
    private var recorderWifiTransferCount = 0

    /// Which card this fast transfer corresponds to (`peripheral.identifier.uuidString`).
    /// After the fast transfer ends, it triggers a reconnection using this info — the card then re‑enables BLE.
    private var recorderWifiTransferRecordID: String?

    /// Fast transfer start. Must be **paired** with `endRecorderWifiTransfer()` (use `defer`).
    func beginRecorderWifiTransfer(recordID: String) {
        recorderWifiTransferCount += 1
        recorderWifiTransferRecordID = recordID
        log.info("wifi transfer begin, suppressing recorder auto-reconnect")
    }

    /// Fast transfer end (counts as both success or failure).
    ///
    /// ★ Need to **perform a reconnection** here: the "planned disconnect" during suppression was skipped,
    /// without it, the fast‑transfer link remains dead after completion — the UI shows "Not connected",
    /// the user may think the fast transfer damaged the card. At this point the card has just re‑enabled BLE,
    /// and the reconnection loop (including the scan‑free fast path) will bring it back.
    func endRecorderWifiTransfer() {
        recorderWifiTransferCount = max(0, recorderWifiTransferCount - 1)
        guard recorderWifiTransferCount == 0 else { return }
        let id = recorderWifiTransferRecordID
        recorderWifiTransferRecordID = nil
        log.info("wifi transfer end, resuming recorder auto-reconnect")
        guard recorderLink == nil, recorderReconnectTask == nil, let id else { return }
        scheduleRecorderReconnect(recordID: id, userInitiated: false)
    }

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil,                                 // main queue
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    // MARK: scanning

    func startScan(duration: TimeInterval = 10) {
        guard adapter == .poweredOn else {
            log.info("startScan skipped: adapter=\(String(describing: self.adapter), privacy: .public)")
            return
        }
        guard !isScanning else {
            log.info("startScan skipped: already scanning")
            return
        }

        discovered.removeAll()
        discoveredRecorders.removeAll()
        isScanning = true
        log.info("scan start, duration=\(Int(duration), privacy: .public)s")

        // Unfiltered scan — the device sometimes advertises only by name (no
        // service UUID), and we want to surface every peripheral so the user
        // can debug. Matching against name prefixes + service UUID happens
        // when the advertisement arrives.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        scanStopTask?.cancel()
        scanStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            // Task inherits the @MainActor context from `BluetoothCoordinator`,
            // so `stopScan()` is a synchronous call here.
            self?.stopScan()
        }
    }

    func stopScan() {
        scanStopTask?.cancel()
        scanStopTask = nil
        guard isScanning else { return }
        central.stopScan()
        isScanning = false
        log.info("scan stop, found=\(self.discovered.count, privacy: .public)")
    }

    // MARK: connect

    /// Connect with an escalating timeout (15 → 25 → 40s).
    func connect(_ peripheral: DiscoveredPeripheral) async throws -> DnoteClient {
        stopScan()

        // Before connecting another device, **first disconnect the current link**. The card firmware accepts only one central:
// If the old connection remains, the new device’s connection will time out (15→25→40 s), and the user sees “after pairing the second device, it can’t connect from the device list”, and rebooting the second device doesn’t help — because the first device is still holding the connection.
        if let existing = client, existing.peripheral.identifier != peripheral.id {
            log.info("switching device: dropping \(existing.peripheral.identifier.uuidString, privacy: .public) first")
            disconnect()
        }

        log.info("connect start id=\(peripheral.id.uuidString, privacy: .public) product=\(peripheral.product.displayName, privacy: .public) sid=\(peripheral.deviceSIDHex, privacy: .public) rssi=\(peripheral.rssi)")

        let timeouts: [TimeInterval] = [15, 25, 40]
        var lastError: Error?

        for (index, timeout) in timeouts.enumerated() {
            log.info("connect attempt \(index + 1, privacy: .public)/\(timeouts.count, privacy: .public) timeout=\(Int(timeout), privacy: .public)s")
            do {
                let connected = try await attemptConnect(
                    peripheral: peripheral.peripheral,
                    timeout: timeout
                )
                self.client = connected
                self.connectedDeviceSID = peripheral.deviceSID
                log.info("connect success id=\(peripheral.id.uuidString, privacy: .public) mtu=\(connected.negotiatedMTU, privacy: .public)")
                await refreshBondStateAndPrompt(client: connected)
                return connected
            } catch {
                log.warning("connect attempt \(index + 1, privacy: .public)/\(timeouts.count, privacy: .public) (timeout=\(Int(timeout))s) failed: \(String(describing: error), privacy: .public)")
                lastError = error
                if index + 1 < timeouts.count {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        throw lastError ?? DnoteError.timeout
    }

    /// Connect a **non‑D·NOTE** recorder card (those identified by the registry; TicNote now follows this path).
    ///
    /// Intentionally keep external behavior consistent with D·NOTE's `connect(_:)` (timeout escalation, disconnect old link first),
    /// but **do not reuse its implementation** — the part in `connect(_:)`
    /// `refreshBondStateAndPrompt` (bond state query + pairing alert in v1.47) is D·NOTE‑specific,
    /// TicNote lacks a bonding concept (`TicNoteRecorderSpec.bondIDLength == nil`), so applying it would
    /// result in "connected but a pairing dialog appears".
    func connectRecorder(_ recorder: DiscoveredRecorder) async throws -> any RecorderLink {
        stopScan()

        // Only one link allowed at a time: drop the old one before connecting a new one (same handling as `connect(_:)`,
        // for the same reason — these cards' firmware accepts only one central; a lingering old link causes new connection timeouts).
        //
        // ⚠️ Tear down the old link using `teardownRecorderForReconnect()` **instead of** `disconnect()`:
        //   The latter cancels any ongoing automatic reconnection task, and the path invoking this method is often
        //   the automatic reconnection loop itself (it already tears down once before each attempt, so this is usually a no‑op) —
        //   Using `disconnect()` would result in "the task cancels itself".
        //   When the user manually connects from the scan page, this cleanup is also unnecessary: after a successful connection `adoptRecorderLink`
        //   clears the reconnection task.
        if recorderLink != nil {
            teardownRecorderForReconnect()
        }
        if client != nil {
            disconnect()
        }

        // ⚠️ **Deliberately not inheriting D·NOTE's [15, 25, 40]**
        //
        // Recorder cards (TicNote NE‑79) broadcast in a **low‑power** mode: measured intervals between two advertisements can reach
        // **152 seconds** (2026‑10‑09 14:22:33 → 14:25:05, measured with a Mac probe).
        // CoreBluetooth's `connect` is **wait‑based** — the connection is established when the card next advertises,
        // so the timeout must span a full advertisement cycle. Using 15 seconds would **always fail**,
        // the user would see "Device did not respond within the allotted time", while the protocol never transmitted a single line.
        //
        // Provide "a long period + a fallback": when the card is awake it connects within seconds; when asleep, it may wait up to one cycle.
        // Corresponding guidance is in `ScannerSheet.connectRecorder` (after timeout, prompt the user to briefly press the record button to wake the card).
        let timeouts: [TimeInterval] = [90, 150]
        var lastError: Error?
        for (index, timeout) in timeouts.enumerated() {
            do {
                let link = try await attemptConnectRecorder(
                    recorder: recorder, timeout: timeout
                )
                self.adoptRecorderLink(link, matched: recorder)
                log.info("recorder connect success proto=\(recorder.protocolID, privacy: .public) id=\(recorder.id.uuidString, privacy: .public) mtu=\(link.negotiatedMTU, privacy: .public) verified=\(recorder.isVerifiedOnDevice, privacy: .public)")
                // Time synchronization is **best‑effort**: failures do not affect file listing or downloads (times in the list may be off,
                // but `TicNoteSession` duration is calculated by byte count, not relying on the card's RTC).
                try? await link.syncTime(to: Date())
                return link
            } catch {
                log.warning("recorder connect attempt \(index + 1, privacy: .public)/\(timeouts.count, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                lastError = error
                if index + 1 < timeouts.count {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        throw lastError ?? RecorderLinkError.timeout
    }

    /// Reconnect a **registered** recorder card (record with `is_recorder = true` in the ledger).
    ///
    /// ## ★ 2026‑10‑10 change: try the "scan‑free fast path" first, fall back to scanning.
    ///
    /// Originally this path had only one approach: **scan → wait for advertisements → match by peripheral UUID → connect**.
    /// It relies on the card actively advertising, and this card is low‑power (advertisement interval up to **152 seconds**,
    /// see the long comment in `connectRecorder`). The user said
    /// "It goes to sleep when not continuously connected… current experience is not smooth, requiring repeated reconnection clicks" —
    /// the symptom is exactly "tap does nothing, can only keep tapping".
    ///
    /// The current order is:
    ///   1. **Already connected to the same one** → reuse directly (the connected card does not advertise, so scanning would never succeed);
    ///   2. **Fast path** (`fastReconnectRecorder`): retrieve the previously connected `CBPeripheral` using `retrievePeripherals`
    ///      the `CBPeripheral` from the last connection **and connect directly**. This path **does not require us to capture an advertisement** —
    ///      CoreBluetooth will wait at the controller level, and the connection succeeds when the card next advertises,
    ///      and after the previous connection iOS already knows its address, usually returning within a few seconds;
    ///      Required SN / protocol / model are filled from the cache in `RecorderIdentityStore`
    ///      (Why the cache must include identity bytes is explained at the top of that file);
    ///   3. **Scanning fallback**: only scan when the fast path is unavailable (no cache / peripheral invalidated).
    ///
    /// ⚠️ Step 1 cannot be omitted: when the card is connected it **does not advertise**, so scanning would wait until timeout,
    /// while the link is actually fine — that would cause the "reconnect" action to break a good link.
    ///
    /// When matched, `matchedRecorder` contains the assembled scan result, which the caller (RootView) uses
    /// to open `RecorderSheet`; in fast or early‑exit paths it is `nil` (no advertisement to assemble),
    /// the caller must tolerate that — now the fast path also **reconstructs this shape from the cache**, see
    /// the comment in `fastReconnectRecorder`.
    func reconnectRecorder(recordID: String, timeout: TimeInterval = 100) async throws -> any RecorderLink {
        matchedRecorder = nil
        // If the already connected card is this one, do nothing.
        if let link = recorderLink, link.isConnected,
           link.peripheral.identifier.uuidString == recordID {
            return link
        }
        // ★ Fast path: no scanning, directly connect using the stored identity.
        if let identity = RecorderIdentityStore.shared.identity(peripheralUUID: recordID) {
            do {
                return try await fastReconnectRecorder(identity: identity, timeout: min(timeout, 30))
            } catch {
                log.warning("recorder fast reconnect failed, falling back to scan: \(String(describing: error), privacy: .public)")
            }
        }
        return try await scanAndConnectRecorder(recordID: recordID, timeout: timeout)
    }

    /// Pure scanning legacy path (fallback when fast path is unavailable). Behavior is **identical word‑for‑word** to the pre‑change version.
    private func scanAndConnectRecorder(recordID: String, timeout: TimeInterval) async throws -> any RecorderLink {
        startScan(duration: timeout)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = discoveredRecorders.first(where: { $0.id.uuidString == recordID }) {
                stopScan()
                matchedRecorder = match
                return try await connectRecorder(match)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        stopScan()
        throw RecorderLinkError.timeout
    }

    /// ★ **Between two batch fast transfers**, restore the BLE link. Idempotent.
    ///
    /// ## Why a separate method is required (2026‑10‑12, user reported "Wi‑Fi fast transfer not continuous" as a positive fix)
    ///
    /// TicNote's fast transfer is "send `OPEN_WIFI` → **card actively drops BLE** → card starts a hotspot → phone joins →
    /// transfer → card shuts the hotspot and reopens BLE". So **after each transfer BLE is always down**,
    /// and the next one must first send `OPEN_WIFI` over BLE again before it can start ——
    /// that "reconnect the link" step in between is the **single critical point** for whether a whole batch can run through.
    ///
    /// This step used to happen **by accident**: in `RecorderDeviceView.download()` each
    /// `defer { endRecorderWifiTransfer() }` → `scheduleRecorderReconnect()` starts an
    /// auto-reconnect task; the next item's `link()` then calls `connectRecorder()` (timeout [90, 150]).
    /// Both paths first run `teardownRecorderForReconnect()` (`central.cancelPeripheralConnection`),
    /// **killing each other's in-flight connect** —— on real devices this showed up as "after 1~2 items transferred,
    /// the next one never moves", with no error at all (both sides are just "waiting").
    ///
    /// Now the batch owns this itself, in a deterministic order:
    ///   1. Already connected to the same card → **reuse directly** (the first item takes this path);
    ///   2. First **stop the auto-reconnect task** —— otherwise `teardownRecorderForReconnect` below
    ///      fights it for the same peripheral;
    ///   3. Fast path (`fastReconnectRecorder`): connect directly to the remembered peripheral,
    ///      **no scan**. The card's advertising interval was measured at up to 152 s (see the comment on `connectRecorder`),
    ///      and scanning would stall the whole batch;
    ///   4. Only if the handle can't be retrieved, fall back to scanning, with the window being the **caller-provided `timeout`**
    ///      (20 s in a batch, not `connectRecorder`'s 90/150 —— that is designed for
    ///      "user tapped by hand, card asleep"; between two fast transfers it would make the user think the app froze).
    ///
    /// ⚠️ Key difference from `reconnectRecorder`: **does not touch `matchedRecorder`**.
    ///    The first line of `reconnectRecorder` (the user-tap path) clears it to `nil`,
    ///    and that is exactly the condition `RecordingsView` uses to decide whether to draw the device page ——
    ///    clearing it would tear down and rebuild the device page (along with the transfer running on it).
    @discardableResult
    func ensureRecorderLink(recordID: String, timeout: TimeInterval = 20) async throws -> any RecorderLink {
        // 1) If it's alive, just use it.
        if let link = recorderLink, link.isConnected,
           link.peripheral.identifier.uuidString == recordID {
            return link
        }
        // 2) Stop the auto-reconnect —— it would fight the code below for the same peripheral.
        recorderReconnectTask?.cancel()
        recorderReconnectTask = nil
        recorderReconnectGeneration &+= 1
        recorderReconnectState = nil
        teardownRecorderForReconnect()
        // 3) Fast path.
        if let identity = RecorderIdentityStore.shared.identity(peripheralUUID: recordID) {
            do {
                return try await fastReconnectRecorder(identity: identity, timeout: timeout)
            } catch {
                log.warning("ensureRecorderLink fast path miss: \(String(describing: error), privacy: .public)")
            }
        }
        // 4) Fallback scan (window equals `timeout`).
        return try await scanAndConnectRecorder(recordID: recordID, timeout: timeout)
    }

    /// Scan-free reconnect: `retrievePeripherals` → `connect` directly.
    ///
    /// ## Why this path is faster
    /// `central.connect(_:)` on a **known peripheral** is "pending-style": the controller records "I want to connect to it",
    /// and on the card's next advertisement the link is established **at the hardware level**, without the app side first getting `didDiscover` for it.
    /// `scanAndConnectRecorder`, on the other hand, must wait until we **scan that advertisement ourselves** before initiating a connection,
    /// so the worst case waits a full advertising period (measured 152 s).
    ///
    /// ## Why `DiscoveredRecorder` can be reassembled
    /// The fields of the scanned struct (protocol / model / identity bytes / advertised name) all come from the advertisement,
    /// and they were already recorded by `RecorderIdentityStore` at the **last successful connection**.
    /// Once rebuilt into the same shape, downstream (`rawConnectRecorder` choosing the implementation, `TicNoteLink` taking the SN
    /// to derive Wi-Fi credentials, `RootView` using it to open `RecorderSheet`) needs **not a single line changed**.
    ///
    /// ## ⚠️ Why only one attempt, instead of reusing `connectRecorder`'s [90, 150] escalation
    /// That escalation is designed for "card asleep, we can only wait for its advertisement". The whole point of the fast path is to **be fast**:
    /// if it can't connect, it should fall back to scanning right away (the scan side's window is long enough),
    /// rather than burning 90 seconds and then 150 seconds here —— which would be slower than not changing anything.
    ///
    /// ⚠️ The one honest gap: `rssi` is the **previous** value, not live signal strength.
    /// It is only used for display, never for any decision.
    func fastReconnectRecorder(identity: RecorderIdentity, timeout: TimeInterval = 30) async throws -> any RecorderLink {
        guard let uuid = UUID(uuidString: identity.peripheralUUID) else {
            throw RecorderLinkError.unsupported("cached peripheral id is not a UUID")
        }
        // First ask "is it already connected" (common when the app is suspended and comes back), then ask "can the handle be retrieved".
        let candidates = central.retrieveConnectedPeripherals(withServices: TicNoteRecorderSpec.serviceUUIDs)
            + central.retrievePeripherals(withIdentifiers: [uuid])
        guard let peripheral = candidates.first(where: { $0.identifier == uuid }) else {
            // Failing to retrieve it usually means "switched phones / reinstalled / the system cleared peripheral records" —— honestly fall back to scanning.
            throw RecorderLinkError.notConnected
        }
        let recorder = DiscoveredRecorder(
            id: peripheral.identifier,
            peripheral: peripheral,
            protocolID: identity.protocolID,
            advertisement: RecorderAdvertisement(
                protocolID: identity.protocolID,
                family: identity.family,
                modelName: identity.modelName,
                firmware: nil,
                hardware: nil,
                battery: nil,
                powerState: nil,
                identity: identity.identity,
                raw: [:]
            ),
            localName: identity.localName.isEmpty ? nil : identity.localName,
            rssi: identity.rssi,
            lastSeen: identity.lastConnectedAt
        )
        stopScan()
        // Only one link at a time (these cards accept just one central; if the old link isn't dropped the new connection times out).
        // ⚠️ We **must not** call `disconnect()` here: it cancels the running auto-reconnect task,
        //   and this method is very likely being called by that very task —— it would end up "cancelling itself".
        teardownRecorderForReconnect()
        matchedRecorder = recorder
        let link = try await attemptConnectRecorder(recorder: recorder, timeout: timeout)
        adoptRecorderLink(link, matched: recorder)
        try? await link.syncTime(to: Date())
        return link
    }

    /// Common wrap-up after connecting (shared by the normal connect / fast path / auto-reconnect paths).
    ///
    /// Three things, all of which should happen "only once while a link is alive":
    ///   1. Record "who this card is" → so the next reconnect can skip scanning (`RecorderIdentityStore`);
    ///   2. **Start keep-alive** → the proper fix for the user-reported "link goes to sleep" (see `RecorderLink.startKeepAlive`);
    ///   3. Clear the reconnect state, cancel the running reconnect task, and clear the "this time was a user tap" flag.
    private func adoptRecorderLink(_ link: any RecorderLink, matched: DiscoveredRecorder?) {
        recorderLink = link
        recorderDeviceInfo = nil
        if let matched { matchedRecorder = matched }
        // ⚠️ Identity must be "update if present, keep otherwise". When `matched == nil` the advertised identity is unavailable,
        //    and if we wrote a record with `identityHex = ""` anyway, it would wipe the SN recorded last time ——
        //    and the SN is the only source of Wi-Fi fast-transfer credentials, so the result is "the fast-transfer button suddenly doesn't light up after reconnecting".
        //    So when a field is missing, fill it in from the existing cache.
        //
        // ⚠️ `protocolID` deliberately does **not** use `type(of: link).protocolID`: that takes a static member on an existential type
        //    (`any RecorderLink`), and whether it can be dispatched dynamically is up to the compiler,
        //    not worth betting on —— and both `matched` and the cache paths hold this string.
        let uuid = link.peripheral.identifier.uuidString
        let cached = RecorderIdentityStore.shared.identity(peripheralUUID: uuid)
        RecorderIdentityStore.shared.remember(
            RecorderIdentity(
                peripheralUUID: uuid,
                protocolID: matched?.protocolID ?? cached?.protocolID ?? TicNoteRecorderSpec.identifier,
                identityHex: matched?.identityHex ?? cached?.identityHex ?? "",
                family: matched?.advertisement.family ?? cached?.family ?? TicNoteRecorderSpec.family,
                modelName: matched?.advertisement.modelName ?? cached?.modelName ?? "",
                localName: matched?.localName ?? cached?.localName ?? "",
                rssi: matched?.rssi ?? cached?.rssi ?? 0,
                lastConnectedAt: Date()
            )
        )
        link.startKeepAlive()
        recorderReconnectTask?.cancel()
        recorderReconnectTask = nil
        recorderReconnectGeneration &+= 1
        recorderReconnectState = nil
        recorderReconnectWasUserInitiated = false
    }

    /// Single connection attempt + timeout.
    ///
    /// ⚠️ This deliberately does **not** reuse D·NOTE's `withThrowingTaskGroup(of: DnoteClient.self)` approach,
    /// for a type-level reason: `withThrowingTaskGroup(of:)` requires the child task's result type to be
    /// `Sendable`, and `any RecorderLink` is an **existential type** —— even if every implementation
    /// (`TicNoteLink` is a `@MainActor final class`, implicitly Sendable) conforms,
    /// the existential itself does not automatically become Sendable. So we use "continuation + a timeout task" instead,
    /// with the same semantics as before (whoever arrives first wins, the other becomes a no-op).
    private func attemptConnectRecorder(
        recorder: DiscoveredRecorder,
        timeout: TimeInterval
    ) async throws -> any RecorderLink {
        let target = recorder.peripheral
        let watchdog = Task { @MainActor in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            // Only counts as a timeout if it's still pending; otherwise the connection has already succeeded/failed, so leave it alone.
            guard self.pendingRecorders[target.identifier] != nil else { return }
            self.resolvePendingRecorder(for: target, with: .failure(RecorderLinkError.timeout))
            self.central.cancelPeripheralConnection(target)
        }
        defer { watchdog.cancel() }
        return try await rawConnectRecorder(recorder)
    }

    private func rawConnectRecorder(_ recorder: DiscoveredRecorder) async throws -> any RecorderLink {
        let link: any RecorderLink
        switch recorder.protocolID {
        case TicNoteRecorderSpec.identifier:
            // The SN must be passed in here: the Wi-Fi fast-transfer hotspot name and password are **derived entirely from it**
            // (`SSID = "TicNote-"+last 4 of SN`, `password = last 8 of SN`, see `protocol-notes.md` §18.1),
            // and the advertisement in the scan result is the only place the SN can be obtained. Once the link is up there is no other
            // way to fill it in —— this is exactly the switch for "whether the fast-transfer button lights up".
            link = TicNoteLink(
                peripheral: recorder.peripheral,
                central: central,
                serialNumber: recorder.identityText
            )
        default:
            // A protocol was added to the registry but not wired up here —— the symptom would be "can scan, can't connect", the hardest to track down.
            // Better to throw an error that names the culprit than to silently take the wrong implementation.
            throw RecorderLinkError.unsupported(
                "no RecorderLink implementation for protocol \(recorder.protocolID)"
            )
        }
        return try await withCheckedThrowingContinuation { cont in
            pendingRecorders[recorder.peripheral.identifier] = PendingRecorderConnection(
                link: link, continuation: cont
            )
            central.connect(recorder.peripheral, options: nil)
        }
    }

    private func resolvePendingRecorder(
        for peripheral: CBPeripheral,
        with result: Result<any RecorderLink, Error>
    ) {
        guard let pending = pendingRecorders.removeValue(forKey: peripheral.identifier) else {
            return
        }
        switch result {
        case .success(let link): pending.continuation.resume(returning: link)
        case .failure(let error): pending.continuation.resume(throwing: error)
        }
    }

    func disconnect() {
        // ★ Active disconnect = "stop reconnecting this card". The auto-reconnect task must be stopped here,
        //   otherwise a few seconds after the user taps "Disconnect" it would reconnect the link.
        //
        // ⚠️ This does not hurt "connections initiated by auto-reconnect itself": before each attempt the auto-reconnect loop
        //   first clears `recorderLink` to nil via `teardownRecorderForReconnect()`,
        //   and **does not call** `disconnect()` (which also disconnects D·NOTE as a side effect, see below),
        //   so the loop itself never steps on this `cancel()`. This is deliberate:
        //   if "tear down the old link" and "cancel the reconnect" were bound into one action, the auto-reconnect task would
        //   cancel itself on its very first attempt —— the symptom is "reconnects once, and after a failure never tries again".
        recorderReconnectTask?.cancel()
        recorderReconnectTask = nil
        recorderReconnectGeneration &+= 1
        recorderReconnectState = nil
        // Also disconnect non-D·NOTE recorder cards (TicNote). The two are mutually exclusive:
        // `connectRecorder` calls `disconnect()` first, so this must be cleaned out here,
        // otherwise when switching cards the old link stays in `recorderLink`, and the UI shows "connected" with a dead handle
        // —— the same pitfall as the "retained client is not a live link" note in `reconnect(deviceID:)`.
        teardownRecorderForReconnect()
        // ★ 2026-10-12: root cause of "device still appears on the home page after unbinding".
        //   The display condition for the home-page device card is
        //   `else if let matched = bluetooth.matchedRecorder` in `RecordingsView` ("matched but not connected still shows a gray card"
        //   is intentional —— after disconnecting the user can still see the card and tap it to reconnect).
        //   But `teardownRecorderForReconnect()` only clears `recorderLink` / `recorderDeviceInfo`,
        //   **not `matchedRecorder`** —— so after all four unbind steps finished and the ledger entry was deleted,
        //   the card on the home page was still hanging on `matchedRecorder`.
        //   ⚠️ Why not put it inside `teardownRecorderForReconnect()`: it is called by the **auto-reconnect loop**
        //      before every attempt, and during reconnect the "gray card" must keep showing (clearing it would flicker),
        //      and after the loop scans the card it sets `matchedRecorder` again itself.
        //   The semantics of `disconnect()` is "user-initiated disconnect = invalidate this match", so clearing it there is right;
        //   clearing it in the `disconnect()` before a card-switch connection is also fine (the new one is set immediately).
        matchedRecorder = nil
        // The D·NOTE link. Mutually exclusive with the recorder card, so disconnect it too (semantics unchanged from before the change).
        guard let active = client else { return }
        log.info("disconnect id=\(active.peripheral.identifier.uuidString, privacy: .public)")
        // Mark this as deliberate so the disconnect delegate doesn't report it
        // as an unexpected drop and trigger an auto-reconnect the user just
        // asked us to undo.
        userInitiatedDisconnect = true
        central.cancelPeripheralConnection(active.peripheral)
        client = nil
        connectedDeviceSID = nil
        pendingPairing = nil
    }

    // MARK: Recorder auto-reconnect

    /// After the recorder card drops unexpectedly, **reconnect it by itself**.
    ///
    /// ## Why this is necessary
    /// Before this change, the recorder branch in `didDisconnectPeripheral` only did three things:
    /// `handleDisconnect` / `recorderLink = nil` / `recorderDeviceInfo = nil` ——
    /// **no reconnect at all**. So the user's only correct action was "go back to the home page and tap the card again",
    /// which is exactly what they described as *"currently not smooth enough, I have to keep tapping reconnect"*.
    ///
    /// ## Why "infinite backoff" rather than "give up after N tries"
    /// The user's exact words were *"the recorder card needs to stay connected continuously"*. The card sleeps by itself (advertising interval measured
    /// up to 152 s), so "stop after a few tries" inevitably leaves a session that never reconnects.
    /// After backing off to 30 s it keeps retrying every 30 s; the cost is a nearly traffic-free timer;
    /// the benefit is that when the user picks up the card and presses a key, the link comes back on its own.
    ///
    /// ## What it does not do
    /// * **No popups** —— the user did nothing, so they shouldn't be interrupted. State only goes through `recorderReconnectState`,
    ///   and the UI decides by its own position whether to show it as a line of small text or not at all;
    /// * **Does not preempt D·NOTE**: only triggers when this link is a recorder card (`recorderLink`).
    private func scheduleRecorderReconnect(recordID: String, userInitiated: Bool) {
        recorderReconnectTask?.cancel()
        recorderReconnectGeneration &+= 1
        let generation = recorderReconnectGeneration
        recorderReconnectWasUserInitiated = userInitiated
        let startedAt = Date()
        let name = RecorderIdentityStore.shared.identity(peripheralUUID: recordID)?.displayName ?? ""
        recorderReconnectState = RecorderReconnectState(
            attempt: 0, deviceName: name, usingFastPath: true,
            userInitiated: userInitiated, startedAt: startedAt
        )
        recorderReconnectTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                // ⚠️ Backoff comes **before the attempt**: retrying immediately after a failure just hits the same wall three times in a row
                //   (right after the card drops it usually hasn't returned to a connectable state yet).
                let delay = attempt == 0
                    ? 0
                    : Self.recorderReconnectBackoff[min(attempt - 1, Self.recorderReconnectBackoff.count - 1)]
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    if Task.isCancelled { return }
                }
                attempt += 1
                let identity = RecorderIdentityStore.shared.identity(peripheralUUID: recordID)
                self.recorderReconnectState = RecorderReconnectState(
                    attempt: attempt,
                    deviceName: identity?.displayName ?? name,
                    usingFastPath: identity != nil,
                    userInitiated: userInitiated,
                    startedAt: startedAt
                )
                do {
                    // First clean up the old handle (**do not** call `disconnect()`, see the comment of that method).
                    // After the device disconnects, `recorderLink` is usually cleared by `didDisconnectPeripheral`,
                    // This step serves as a fallback for the "half-dead link" case (`isConnected == false` but the object still exists).
                    self.teardownRecorderForReconnect()
                    if let identity {
                        do {
                            let link = try await self.fastReconnectRecorder(identity: identity, timeout: 20)
                            log.info("recorder auto-reconnect ok (fast path) attempt=\(attempt, privacy: .public)")
                            _ = link
                            return
                        } catch {
                            // Fast path is not given → this round falls back to scanning (the line below), so **no return** here.
                            log.info("recorder auto-reconnect fast path miss: \(String(describing: error), privacy: .public)")
                        }
                    }
                    _ = try await self.scanAndConnectRecorder(recordID: recordID, timeout: 30)
                    log.info("recorder auto-reconnect ok (scan) attempt=\(attempt, privacy: .public)")
                    return
                } catch {
                    // A single failure **does not clear the state**, the next round continues — this is the meaning of "persistent connection".
                    log.info("recorder auto-reconnect attempt \(attempt, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    // The scanning path already stopped the scan internally; confirm again here to avoid overlapping scan tasks.
                    self.stopScan()
                }
            }
            // Cancelled = user manually disconnects / swaps card / already connected to another card.
            // ⚠️ Clear the state only **if still in the same round**: the superseded old task may also reach here,
            //   Without this gate, it would erase the newly written "Attempt N" of the new round.
            // ⚠️ Need to re‑enter `guard let self` here: the `guard let self` inside the loop body
            //   only masks `self` for that iteration; after the loop it reverts to the weak optional value.
            guard let self else { return }
            if self.recorderReconnectGeneration == generation {
                self.recorderReconnectState = nil
            }
        }
    }

    /// Clean up the old handle before automatic reconnection.
    ///
    /// Why not let `disconnect()` in `connectRecorder` do the work: that would cancel
    /// **the ongoing automatic reconnection task** (`disconnect()` now cancels it).
    /// First clean it up yourself, the condition inside `connectRecorder` no longer holds, so self‑destruction won't occur.
    private func teardownRecorderForReconnect() {
        guard let recorder = recorderLink else { return }
        recorder.handleDisconnect(error: nil)
        central.cancelPeripheralConnection(recorder.peripheral)
        recorderLink = nil
        recorderDeviceInfo = nil
    }

    /// Receive the read‑only card status from the device page that has completed; only accept results for the current card, preventing old tasks from
    /// writing the battery level onto the new card's top bar after a card swap.
    func updateRecorderDeviceInfo(_ info: RecorderDeviceInfo, for link: any RecorderLink) {
        guard recorderLink?.peripheral.identifier == link.peripheral.identifier else { return }
        recorderDeviceInfo = info
    }

    /// Reconnect to a previously paired device by UUID, without scanning.
    /// Uses `retrievePeripherals(withIdentifiers:)` to obtain a peripheral
    /// reference, then connects with a single 10-second timeout.
    func reconnect(deviceID: UUID) async throws -> DnoteClient {
        if let existing = client, existing.peripheral.identifier == deviceID {
            // A retained DnoteClient is not proof of a live GATT link. Wi-Fi
            // fast transfer and adapter interruptions can leave this object in
            // place after CoreBluetooth has disconnected the peripheral. Reuse
            // only a genuinely connected peripheral; otherwise every retry
            // keeps returning the same dead handle.
            if existing.peripheral.state == .connected { return existing }
            existing.handleDisconnect(error: DnoteError.notConnected)
            client = nil
            connectedDeviceSID = nil
        }
        let alreadyConnected = central.retrieveConnectedPeripherals(
            withServices: [DnoteProtocol.serviceUUID]
        )
        if let match = alreadyConnected.first(where: { $0.identifier == deviceID }) {
            let result = try await attemptConnect(peripheral: match, timeout: 10)
            self.client = result
            self.connectedDeviceSID = discovered.first(where: { $0.id == deviceID })?.deviceSID
            log.info("reconnect (already-connected) id=\(deviceID.uuidString, privacy: .public)")
            await refreshBondStateAndPrompt(client: result)
            return result
        }
        let peripherals = central.retrievePeripherals(withIdentifiers: [deviceID])
        guard let peripheral = peripherals.first else {
            throw DnoteError.notConnected
        }
        let result = try await attemptConnect(peripheral: peripheral, timeout: 10)
        self.client = result
        self.connectedDeviceSID = discovered.first(where: { $0.id == deviceID })?.deviceSID
        log.info("reconnect success id=\(deviceID.uuidString, privacy: .public)")
        await refreshBondStateAndPrompt(client: result)
        return result
    }

    /// Reconnect by scanning for a peripheral whose manufacturer-data DEVICE_SID
    /// matches the previously-stored record. SID is device-derived (MAC ⊕ BID ⊕
    /// PID), so it survives app reinstalls and new phones — unlike the
    /// iOS-assigned `peripheral.identifier` used by `reconnect(deviceID:)`.
    func reconnect(deviceSID: Data, timeout: TimeInterval = 10) async throws -> DnoteClient {
        // **Identity must be verified before reusing a client.** Returning any
        // existing connection unchecked hands back the client for whichever
        // device connected first: the UI shows “connected” while operating on
        // the wrong device. `reconnect(deviceID:)` checks the identifier for
        // the same reason.
        if let existing = client {
            if connectedDeviceSID == deviceSID { return existing }
            log.info("reconnect(sid): connected to a different device, dropping it first")
            disconnect()
        }
        if let match = discovered.first(where: { $0.deviceSID == deviceSID }) {
            return try await connectToDiscovered(match)
        }
        startScan(duration: timeout + 1)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
            if Task.isCancelled {
                stopScan()
                throw CancellationError()
            }
            if let match = discovered.first(where: { $0.deviceSID == deviceSID }) {
                return try await connectToDiscovered(match)
            }
        }
        stopScan()
        throw DnoteError.timeout
    }

    /// Single-shot connect against a peripheral already surfaced by the scan
    /// filter. Used by `reconnect(deviceSID:)`; the 10-second timeout matches
    /// the UUID-based reconnect path so the two feel identical to the user.
    private func connectToDiscovered(_ match: DiscoveredPeripheral) async throws -> DnoteClient {
        stopScan()
        let result = try await attemptConnect(peripheral: match.peripheral, timeout: 10)
        self.client = result
        self.connectedDeviceSID = match.deviceSID
        log.info("reconnect (sid) success sid=\(match.deviceSIDHex, privacy: .public) iosID=\(match.id.uuidString, privacy: .public)")
        await refreshBondStateAndPrompt(client: result)
        return result
    }

    /// Query the v1.47 state (bond + encryption) right after a successful
    /// connect. If the device reports unbound, raise a `pendingPairing`
    /// prompt so RootView can ask the user to confirm pairing — the user
    /// wanted explicit, not silent, pairing. A query failure is logged and
    /// ignored (non-fatal; the user will hit the not-bound error later if
    /// they try to record).
    private func refreshBondStateAndPrompt(client: DnoteClient) async {
        do {
            let state = try await client.queryBondState()
            if state.bound {
                pendingPairing = nil
            } else {
                let suggested = Data((0..<DnoteProtocol.bondIDLength).map { _ in UInt8.random(in: 0...255) })
                pendingPairing = PendingPairing(
                    peripheralID: client.peripheral.identifier.uuidString,
                    displayName: client.displayName,
                    suggestedBondID: suggested
                )
            }
        } catch {
            log.warning("queryBondState after connect failed: \(String(describing: error), privacy: .public)")
        }
        // Cache encryption state so download paths gate correctly. Failure
        // is non-fatal; downloads fall back to the "decrypt if key set"
        // heuristic when `deviceEncryptionOn` stays nil.
        _ = try? await client.getEncryptionState()
    }

    private func attemptConnect(peripheral: CBPeripheral, timeout: TimeInterval) async throws -> DnoteClient {
        try await withThrowingTaskGroup(of: DnoteClient.self) { group in
            group.addTask { @MainActor in
                try await self.rawConnect(peripheral: peripheral)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw DnoteError.timeout
            }

            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                // Resume the continuation BEFORE cancelling the task
                // group — otherwise the runtime flags a leaked continuation.
                self.resolvePending(for: peripheral, with: .failure(error))
                group.cancelAll()
                self.central.cancelPeripheralConnection(peripheral)
                throw error
            }
        }
    }

    private func rawConnect(peripheral: CBPeripheral) async throws -> DnoteClient {
        try await withCheckedThrowingContinuation { cont in
            let client = DnoteClient(peripheral: peripheral, central: central)
            pendingConnections[peripheral.identifier] = PendingConnection(
                client: client, continuation: cont
            )
            central.connect(peripheral, options: nil)
        }
    }

    fileprivate func resolvePending(for peripheral: CBPeripheral, with result: Result<DnoteClient, Error>) {
        guard let pending = pendingConnections.removeValue(forKey: peripheral.identifier) else {
            return
        }
        switch result {
        case .success(let client):
            pending.continuation.resume(returning: client)
        case .failure(let error):
            pending.continuation.resume(throwing: error)
        }
    }

    /// Tear down every connection-shaped bit of state because the adapter left
    /// `.poweredOn` (user flipped Bluetooth off, airplane mode, …).
    ///
    /// Without this, turning Bluetooth off mid-transfer left `client` pointing
    /// at a peripheral that can never work again, and — because `RootView`'s
    /// auto-reconnect is gated on `client == nil` — turning Bluetooth back on
    /// did *not* reconnect. Every subsequent download then failed against the
    /// dead handle, which is the "re‑open Bluetooth, retry still fails" report.
    ///
    /// Written to be idempotent on purpose: whether or not CoreBluetooth also
    /// delivers `didDisconnectPeripheral` for an adapter power-off is not
    /// something to rely on. If it does arrive, `client` is already nil by then
    /// and the handler skips.
    fileprivate func handleAdapterUnavailable() {
        for (_, pending) in pendingConnections {
            pending.continuation.resume(throwing: DnoteError.notConnected)
        }
        pendingConnections.removeAll()
        for (_, pending) in pendingRecorders {
            pending.continuation.resume(throwing: RecorderLinkError.notConnected)
        }
        pendingRecorders.removeAll()

        // ★ Bluetooth turned off = reconnection is meaningless (no adapter), the loop must stop.
        //   Otherwise the screen will keep showing "Attempt 7" while the user only turned off Bluetooth.
        recorderReconnectTask?.cancel()
        recorderReconnectTask = nil
        recorderReconnectGeneration &+= 1
        recorderReconnectState = nil

        if let recorder = recorderLink {
            log.info("adapter left poweredOn — dropping recorder id=\(recorder.peripheral.identifier.uuidString, privacy: .public)")
            recorder.handleDisconnect(error: RecorderLinkError.notConnected)
            recorderLink = nil
            recorderDeviceInfo = nil
        }

        guard let active = client else { return }
        log.info("adapter left poweredOn — dropping client id=\(active.peripheral.identifier.uuidString, privacy: .public)")
        // Fails every in-flight command and transfer, so a download that was
        // running stops waiting instead of hanging until its own timeout.
        active.handleDisconnect(error: DnoteError.notConnected)
        client = nil
        connectedDeviceSID = nil
        pendingPairing = nil
        // Deliberately *not* counted as an unexpected drop: reconnecting is
        // impossible while the adapter is off. The adapter-state observer in
        // RootView picks it up when Bluetooth comes back, and that path now
        // works because `client` is nil.
        userInitiatedDisconnect = false
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothCoordinator: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = AdapterState(central.state)
        log.info("adapter state=\(String(describing: state), privacy: .public)")
        Task { @MainActor in
            self.adapter = state
            if state != .poweredOn {
                self.stopScan()
                self.handleAdapterUnavailable()
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Scan filtering — three **direction‑independent** preconditions, then delegate identity verification to the registry:
        //   1. Must broadcast a non‑empty local name (devices without a name are usually irrelevant or paired but silent)
        //   2. Must be connectable
        //   3. Must be recognized by some protocol in `RecorderProtocolRegistry`
        //
        // ⚠️ **Never match protocols by device name**. Users can rename the device name of both card types.
        //    (D·NOTE has `btNameShort`/`btNameLong`; TicNote has `setDeviceIdentity`),
        //    Names can only be used for "display", not for "identification".
        guard let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
              !localName.isEmpty else { return }
        guard (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue == true else { return }
        let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let advServiceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]

        // The registry order defines priority; take the first recognized one.
        var winner: (any RecorderProtocolSpec.Type)?
        var advertisement: RecorderAdvertisement?
        for spec in RecorderProtocolRegistry.all {
            if let adv = spec.parseAdvertisement(
                manufacturerData: mfgData,
                localName: localName,
                serviceUUIDs: advServiceUUIDs
            ) {
                winner = spec
                advertisement = adv
                break
            }
        }
        guard let spec = winner, let adv = advertisement else { return }

        // ── D·NOTE: **identical word‑for‑word to the pre‑refactor version** ──────────────────────────
        // Note that this **moves the original four guards unchanged** here, rather than
        // reverse‑engineering from the result of `spec.parseAdvertisement` (even though it does exactly the same internally).
        // Reason: D·NOTE is the only protocol that has run long‑term on real devices, so the correctness of this branch cannot rely on
        // "two implementations happening to be equivalent" to guarantee — reverse‑engineering also requires the keys and types of the `raw` dictionary to match,
        // Each additional coupling adds another point that may break in the future. Parsing the manufacturer data once more is worth the cost.
        if spec.identifier == DnoteRecorderSpec.identifier {
            guard let mfgData = mfgData,
                  let parsed = DnoteAdvertisement.parse(mfgData) else { return }
            guard let product = DnoteProduct.match(bid: parsed.bid, pid: parsed.pid) else { return }

            let entry = DiscoveredPeripheral(
                id: peripheral.identifier,
                peripheral: peripheral,
                localName: localName,
                rssi: RSSI.intValue,
                product: product,
                deviceSID: parsed.deviceSID,
                firmware: parsed.firmware,
                hardware: parsed.hardware,
                battery: parsed.battery,
                powerState: parsed.powerState,
                lastSeen: Date()
            )
            Task { @MainActor in
                let isNew = !self.discovered.contains(where: { $0.id == entry.id })
                if isNew {
                    log.info("discovered product=\(product.displayName, privacy: .public) sid=\(entry.deviceSIDHex, privacy: .public) local=\(localName, privacy: .public) rssi=\(RSSI.intValue, privacy: .public)")
                }
                if let idx = self.discovered.firstIndex(where: { $0.id == entry.id }) {
                    self.discovered[idx] = entry
                } else {
                    self.discovered.append(entry)
                }
            }
            return
        }

        // ── Other recorder cards (TicNote): new branch in the registry, completely decoupled from the above ──
        let recorder = DiscoveredRecorder(
            id: peripheral.identifier,
            peripheral: peripheral,
            protocolID: spec.identifier,
            advertisement: adv,
            localName: localName,
            rssi: RSSI.intValue,
            lastSeen: Date()
        )
        Task { @MainActor in
            if !self.discoveredRecorders.contains(where: { $0.id == recorder.id }) {
                log.info("discovered recorder proto=\(recorder.protocolID, privacy: .public) sn=\(recorder.identityText, privacy: .public) rssi=\(recorder.rssi, privacy: .public)")
            }
            if let idx = self.discoveredRecorders.firstIndex(where: { $0.id == recorder.id }) {
                self.discoveredRecorders[idx] = recorder
            } else {
                self.discoveredRecorders.append(recorder)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.info("didConnect id=\(peripheral.identifier.uuidString, privacy: .public) — starting handshake")
        Task { @MainActor in
            // Recorder cards (e.g., TicNote) use their own continuation table for the handshake.
            if let pending = self.pendingRecorders[peripheral.identifier] {
                do {
                    try await pending.link.completeHandshake()
                    self.resolvePendingRecorder(for: peripheral, with: .success(pending.link))
                } catch {
                    log.error("recorder handshake failed: \(String(describing: error), privacy: .public)")
                    central.cancelPeripheralConnection(peripheral)
                    self.resolvePendingRecorder(for: peripheral, with: .failure(error))
                }
                return
            }
            guard let pending = self.pendingConnections[peripheral.identifier] else {
                log.warning("didConnect but no pending connection for \(peripheral.identifier.uuidString, privacy: .public)")
                return
            }
            do {
                try await pending.client.completeHandshake()
                self.resolvePending(for: peripheral, with: .success(pending.client))
            } catch {
                log.error("handshake failed: \(String(describing: error), privacy: .public)")
                central.cancelPeripheralConnection(peripheral)
                self.resolvePending(for: peripheral, with: .failure(error))
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        log.warning("didFailToConnect id=\(peripheral.identifier.uuidString, privacy: .public) err=\(String(describing: error), privacy: .public)")
        Task { @MainActor in
            if self.pendingRecorders[peripheral.identifier] != nil {
                self.resolvePendingRecorder(for: peripheral, with: .failure(error ?? RecorderLinkError.timeout))
                return
            }
            self.resolvePending(for: peripheral, with: .failure(error ?? DnoteError.timeout))
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        log.info("didDisconnect id=\(peripheral.identifier.uuidString, privacy: .public) err=\(String(describing: error), privacy: .public)")
        Task { @MainActor in
            // Resolve any in-flight connect (covers the case where the device
            // hangs up partway through service discovery).
            if self.pendingConnections[peripheral.identifier] != nil {
                self.resolvePending(
                    for: peripheral,
                    with: .failure(error ?? DnoteError.notConnected)
                )
            }
            if self.pendingRecorders[peripheral.identifier] != nil {
                self.resolvePendingRecorder(
                    for: peripheral,
                    with: .failure(error ?? RecorderLinkError.notConnected)
                )
            }
            if let recorder = self.recorderLink,
               recorder.peripheral.identifier == peripheral.identifier {
                // Recorder card disconnect: make any in‑flight download fail immediately (`handleDisconnect` will
                // wake all waiters in `NotifyQueue` with an error), instead of waiting for its own timeout to
                // trap the user in a "spinning" state. **Not counted in `unexpectedDisconnects`** ——
                // That counter triggers automatic reconnection for D·NOTE.
                let recordID = recorder.peripheral.identifier.uuidString
                recorder.handleDisconnect(error: error)
                self.recorderLink = nil
                self.recorderDeviceInfo = nil
                // ★ Modified: **reconnect it yourself**.
                //
                // Before the change, this ended here — the correct user action was only "return to the home page and tap the card once",
                // which is exactly what they said: "the current flow isn’t smooth, requiring repeated reconnection taps".
                //
                // ⚠️ Reconnect only when "not disconnected by us". The criterion is `error == nil`
                //   **does not hold** (`cancelPeripheralConnection` can also yield nil),
                //   so the real criterion is "whether `recorderReconnectTask` is running at this moment" —
                //   Both an explicit `disconnect()` and automatic reconnection that tears the link will first cancel/clear the task,
                //   therefore this will not be triggered again by a self‑initiated disconnect.
                //
                // ⚠️ There is a third "self‑disconnected" case: **Wi‑Fi fast transfer**. The card receives `OPEN_WIFI`
                //   then it actively disconnects BLE to start a hotspot (about 1.8 s later), and that disconnection is part of the process.
                //   If we don’t exclude it, during the entire fast transfer (the hotspot window lasts up to 45 s) the background will continuously
                //   scan + `central.connect`, and the status bar will keep showing "Reconnecting",
                //   while the user is waiting for the fast‑transfer progress — the two things clash.
                //   When the fast transfer ends, `endRecorderWifiTransfer()` performs a reconnection (the card re‑enables BLE at that point).
                if self.recorderReconnectTask == nil, self.recorderWifiTransferCount == 0 {
                    self.scheduleRecorderReconnect(recordID: recordID, userInitiated: false)
                }
                return
            }
            if self.client?.peripheral.identifier == peripheral.identifier {
                self.client?.handleDisconnect(error: error)
                self.client = nil
                self.connectedDeviceSID = nil
                self.pendingPairing = nil
                // Only an unasked-for drop is a reconnect trigger. Powering the
                // device off/on doesn't change the phone's adapter state, so
                // this is the only signal that the link died.
                if self.userInitiatedDisconnect {
                    self.userInitiatedDisconnect = false
                } else {
                    self.unexpectedDisconnects += 1
                }
            }
        }
    }
}
