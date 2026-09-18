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

    func disconnect() {
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
        // Scan filter — never compare against the local-name string:
        //   1. must advertise a non-empty local name
        //   2. must be connectable
        //   3. manufacturer-data CID must be 0x22A3 (D·NOTE)
        //   4. (BID, PID) must match a known DnoteProduct
        guard let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
              !localName.isEmpty else { return }
        guard (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue == true else { return }
        guard let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
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
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.info("didConnect id=\(peripheral.identifier.uuidString, privacy: .public) — starting handshake")
        Task { @MainActor in
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
