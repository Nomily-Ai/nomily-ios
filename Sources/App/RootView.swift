import SwiftUI

extension Notification.Name {
    static let navigateToSettings = Notification.Name("navigateToSettings")
}

/// App chrome: 3-tab layout with a persistent connection pill anchored to the
/// top-left of every tab. The pill adapts to three states: onboarding (no known
/// devices), single device, or multi-device dropdown.
struct RootView: View {
    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var bluetooth: BluetoothCoordinator
    @EnvironmentObject private var configService: ConfigService
    @Environment(\.scenePhase) private var scenePhase
    @State private var showScanner = false
    @State private var showDevice = false
    @State private var selectedTab: Tab = .recordings
    @State private var streamingTab: Tab?
    @State private var pendingTab: Tab?
    /// Device the user picked in the pill while a BLE transfer was running;
    /// connected only after they confirm cancelling the transfer.
    @State private var pendingDeviceSwitch: String?
    @State private var showCancelTransferAlert = false
    @State private var isReconnecting = false
    @State private var showCloudConsent = false
    @State private var manualConnectFailure: ManualConnectFailure?
    @State private var passphraseSetup: PassphraseSetupPrompt?
    @State private var passphraseError: String?

    /// Bind succeeded, device encryption is on, and this device has no key yet—this step must be completed before navigating to the home page.
    struct PassphraseSetupPrompt: Identifiable {
        let sn: String
        var id: String { sn }
    }

    private struct ManualConnectFailure: Identifiable {
        let deviceID: String
        let message: String
        var id: String { deviceID }
    }

    /// A cloud provider is configured but the user hasn't yet acknowledged
    /// that it sends their data off-device.
    private var cloudConsentPending: Bool {
        configService.config.usesCloudService && !configService.config.cloudEgressConsented
    }

    enum Tab: Hashable {
        case recordings, live, settings
    }

    /// Changes whenever we need to kick/cancel the device-info poll loop —
    /// on connect/disconnect or foreground/background. Bundled into the
    /// `.task(id:)` so SwiftUI handles teardown for us.
    private var devicePollKey: String {
        let id = bluetooth.client?.peripheral.identifier.uuidString ?? "none"
        return "\(id)-\(String(describing: scenePhase))"
    }

    private var knownDevices: [KnownDevice] {
        configService.config.devices
            .sorted { ($0.value.lastConnected ?? "") > ($1.value.lastConnected ?? "") }
            .map { KnownDevice(id: $0.key, name: $0.value.name) }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            tabContent(L10n.Tab.recordings, RecordingsView())
                .tabItem { Label(L10n.Tab.recordings, systemImage: "waveform") }
                .tag(Tab.recordings)

            tabContent(L10n.Tab.live, LiveView())
                .tabItem { Label(L10n.Tab.live, systemImage: "waveform.badge.mic") }
                .tag(Tab.live)

            tabContent(L10n.Tab.settings, SettingsView())
                .tabItem { Label(L10n.Tab.settings, systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .sheet(isPresented: $showScanner) {
            ScannerSheet(onConnected: { showScanner = false })
        }
        .sheet(isPresented: $showDevice) {
            if let client = bluetooth.client {
                DeviceSheet(client: client)
            }
        }
        .sheet(item: $passphraseSetup) { prompt in
            PassphraseEntrySheet(
                mode: .set,
                sn: prompt.sn,
                client: bluetooth.client,
                onError: { passphraseError = $0 },
                firstBind: true
            )
        }
        .alert(
            L10n.Device.couldntUpdate,
            isPresented: Binding(
                get: { passphraseError != nil },
                set: { if !$0 { passphraseError = nil } }
            )
        ) {
            Button(L10n.Common.ok, role: .cancel) { passphraseError = nil }
        } message: {
            Text(passphraseError ?? "")
        }
        .onChange(of: bluetooth.adapter) { newState in
            if newState == .poweredOn && bluetooth.client == nil && !isReconnecting {
                Task { await autoReconnect() }
            }
        }
        .onChange(of: bluetooth.unexpectedDisconnects) { _ in
            Task { await autoReconnectAfterDrop() }
        }
        .onChange(of: cloudConsentPending) { pending in
            if pending { showCloudConsent = true }
        }
        .onChange(of: env.openDeviceSheetForPairing) { shouldOpen in
            guard shouldOpen else { return }
            env.openDeviceSheetForPairing = false
            selectedTab = .recordings
            if bluetooth.client != nil { showDevice = true }
        }
        .task {
            if cloudConsentPending { showCloudConsent = true }
        }
        .alert(item: $manualConnectFailure) { failure in
            Alert(
                title: Text(L10n.Scanner.connectionFailed),
                message: Text(failure.message),
                primaryButton: .default(Text(L10n.Common.retry)) {
                    Task { await connectToDevice(id: failure.deviceID) }
                },
                secondaryButton: .cancel(Text(L10n.Common.cancel))
            )
        }
        .alert(L10n.Privacy.cloudTitle, isPresented: $showCloudConsent) {
            Button(L10n.Privacy.cloudAgree) {
                configService.config.cloudEgressConsented = true
                configService.scheduleSave()
            }
            Button(L10n.Privacy.cloudGoLocal) {
                selectedTab = .settings
                env.navigateToASRProviders = true
            }
        } message: {
            Text(L10n.Privacy.cloudMessage)
        }
        .onChange(of: env.isStreaming) { streaming in
            streamingTab = streaming ? selectedTab : nil
        }
        .onChange(of: selectedTab) { newTab in
            if let locked = streamingTab, newTab != locked {
                selectedTab = locked
                return
            }
            if env.isBLETransferring, newTab != .recordings {
                selectedTab = .recordings
                pendingTab = newTab
                showCancelTransferAlert = true
            }
        }
        .alert(
            L10n.DeviceFiles.transferInProgress,
            isPresented: $showCancelTransferAlert
        ) {
            Button(L10n.DeviceFiles.cancelAndSwitch, role: .destructive) {
                env.cancelBLETransfers?()
                if let tab = pendingTab { selectedTab = tab }
                if let id = pendingDeviceSwitch {
                    Task { await connectToDevice(id: id) }
                }
                pendingTab = nil
                pendingDeviceSwitch = nil
            }
            Button(L10n.Common.cancel, role: .cancel) {
                pendingTab = nil
                pendingDeviceSwitch = nil
            }
        } message: {
            Text(L10n.DeviceFiles.cancelTransferToSwitch)
        }
        .alert(
            L10n.Pairing.title,
            isPresented: Binding(
                get: { bluetooth.pendingPairing != nil },
                set: { if !$0 { bluetooth.pendingPairing = nil } }
            ),
            presenting: bluetooth.pendingPairing
        ) { pending in
            Button(L10n.Pairing.pair) {
                Task { await confirmPairing(pending) }
            }
            Button(L10n.Common.cancel, role: .cancel) {
                bluetooth.pendingPairing = nil
            }
        } message: { pending in
            Text(L10n.Pairing.message(pending.displayName))
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSettings)) { _ in
            selectedTab = .settings
        }
        .task(id: devicePollKey) {
            // Keep the pill (and anything reading `lastDeviceInfo`) in sync
            // with the device without waiting for the user to open the
            // Device sheet. The firmware has no "recording started"
            // notification for the physical button, so this is the only
            // way a button-press start shows up in the UI.
            await pollDeviceInfo()
        }
    }

    private func pollDeviceInfo() async {
        guard scenePhase == .active, let client = bluetooth.client else { return }
        // Immediate refresh so entering the app / switching to active lights
        // up the pill without any delay.
        _ = try? await client.getDeviceInfo()
        // Recording-state transitions are event-driven now (0x54 start /
        // 0x55 stop), so this loop only catches slow drift — battery,
        // free storage, Wi-Fi AP state — which doesn't need aggressive
        // polling. 30 s keeps the pill believable without burning BLE
        // traffic when nothing is happening.
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { break }
            guard let client = bluetooth.client else { return }
            _ = try? await client.getDeviceInfo()
        }
    }

    @ViewBuilder
    private func tabContent<Content: View>(_ title: String, _ content: Content) -> some View {
        NavigationStack {
            content
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        ConnectionPill(
                            client: bluetooth.client,
                            adapter: bluetooth.adapter,
                            knownDevices: knownDevices,
                            isReconnecting: isReconnecting,
                            onTapDevice: handlePillTap,
                            onAddDevice: { showScanner = true },
                            onSelectDevice: handleSelectDevice
                        )
                        .disabled(env.isStreaming)
                        .opacity(env.isStreaming ? 0.4 : 1)
                    }
                    ToolbarItem(placement: .principal) {
                        HStack {
                            Spacer()
                            Text(title).font(.headline)
                        }
                    }
                }
        }
    }

    private func handlePillTap() {
        if bluetooth.client != nil {
            showDevice = true
        } else if let first = knownDevices.first {
            // A connect attempt is already in flight (spinner showing) —
            // tapping again would start a second scan on the same device and
            // the two would race to set/clear `isReconnecting` (3op2cmn).
            guard !isReconnecting else { return }
            Task { await connectToDevice(id: first.id) }
        }
    }

    private func handleSelectDevice(_ id: String) {
        if bluetooth.client?.peripheral.identifier.uuidString == id {
            showDevice = true
        } else {
            guard !isReconnecting else { return }
            // Same guard the tab bar and the Recordings segment already
            // have. Without it `connectToDevice` queues behind the
            // transfer's command lock with no spinner and no prompt —
            // the tap looks ignored until the download finishes.
            if env.isBLETransferring {
                pendingDeviceSwitch = id
                showCancelTransferAlert = true
                return
            }
            Task { await connectToDevice(id: id) }
        }
    }

    private func connectToDevice(id: String) async {
        // Spinner from the first await: the recording-state check below
        // waits on the command lock, and that wait is the user's only
        // feedback until the old link is torn down.
        isReconnecting = true
        defer { isReconnecting = false }
        if let current = bluetooth.client {
            let info = (try? await current.getDeviceInfo()) ?? current.lastDeviceInfo
            if info?.isRecording == true {
                manualConnectFailure = .init(
                    deviceID: id,
                    message: DnoteError.operationUnavailableWhileRecording.localizedDescription
                )
                return
            }
        }
        bluetooth.disconnect()
        do {
            let client = try await reconnectByPreferredIdentity(recordID: id)
            configService.rememberDevice(
                id: id,
                name: client.displayName
            )
            _ = try? await client.getDeviceInfo()
            _ = try? await client.getSwitchInfo()
            try? await client.syncTime()
        } catch {
            // Manual connects must end with an actionable result. Automatic
            // reconnect paths below stay intentionally quiet.
            let message: String
            if bluetooth.adapter != .poweredOn {
                message = bluetooth.adapter.userMessage ?? error.localizedDescription
            } else if let dnoteError = error as? DnoteError,
                      case .timeout = dnoteError {
                message = L10n.Scanner.wakeAndRetry
            } else {
                message = error.localizedDescription
            }
            manualConnectFailure = .init(deviceID: id, message: message)
        }
    }

    private func reconnectByPreferredIdentity(recordID: String) async throws -> DnoteClient {
        try await PreferredDevice.reconnect(
            recordID: recordID,
            bluetooth: bluetooth,
            config: configService
        )
    }

    /// Run the bind command with the coordinator's suggested bond_id, then
    /// persist the hex form next to the device record so future connects
    /// can inspect (or re-send) the same ID. On failure the pairing alert
    /// is left cleared — the user can open Device sheet and re-try manually.
    private func confirmPairing(_ pending: BluetoothCoordinator.PendingPairing) async {
        defer { bluetooth.pendingPairing = nil }
        guard let client = bluetooth.client,
              client.peripheral.identifier.uuidString == pending.peripheralID else { return }
        do {
            try await client.bindDevice(bondID: pending.suggestedBondID)
            configService.setBondID(
                for: pending.peripheralID,
                name: pending.displayName,
                bondID: pending.suggestedBondID.hexString
            )
            await promptPassphraseIfNeeded(client)
        } catch {
            // Logged in the client; user can retry from Device sheet.
        }
    }

    /// Firmware v1.50 automatically enables encryption upon pairing, so the first step after pairing is to read back the encryption status.
    /// If the device is encrypted but this phone lacks the key, directly proceed to the PIN setup—do not navigate to the home screen where recording is possible,
    /// as any recordings made during that interval will be permanently unopenable on this phone (rv7my090).
    ///
    /// Users can dismiss this sheet and set it up later: the recording entry point remains disabled until setup is complete.
    /// The banner at the top of the library serves as the entry point to return to this step.
    private func promptPassphraseIfNeeded(_ client: DnoteClient) async {
        _ = try? await client.getEncryptionState()
        if (client.lastDeviceInfo?.serial ?? "").isEmpty {
            _ = try? await client.getDeviceInfo()
        }
        guard KeyResolver.setupIncomplete(for: client),
              let sn = client.lastDeviceInfo?.serial, !sn.isEmpty else { return }
        passphraseSetup = .init(sn: sn)
    }

    /// Retry schedule (seconds) after an unexpected drop. A device that was
    /// just power-cycled needs a few seconds before it advertises again, so a
    /// single immediate attempt usually misses it. Bounded on purpose — if the
    /// device stays off we stop rather than scan forever and drain the battery;
    /// the pill goes grey and the user can tap to retry.
    private static let dropReconnectBackoff: [UInt64] = [1, 3, 5]

    /// Auto-reconnect after the link dropped on its own.
    ///
    /// Toggle ON  → walk the backoff, re-acquiring the most recent device.
    /// Toggle OFF → do nothing; the app stays disconnected until the user taps
    ///              the connection pill (the behaviour before this setting).
    private func autoReconnectAfterDrop() async {
        guard configService.config.autoReconnectEnabled else { return }
        guard !isReconnecting, bluetooth.client == nil else { return }
        guard let target = knownDevices.first else { return }

        isReconnecting = true
        defer { isReconnecting = false }

        for delay in Self.dropReconnectBackoff {
            // Bail out if the adapter went down, the user reconnected by hand,
            // or they deliberately disconnected while we were retrying.
            guard bluetooth.adapter == .poweredOn, bluetooth.client == nil else { return }
            do {
                let client = try await reconnectByPreferredIdentity(recordID: target.id)
                configService.rememberDevice(id: target.id, name: client.displayName)
                _ = try? await client.getDeviceInfo()
                _ = try? await client.getSwitchInfo()
                try? await client.syncTime()
                return
            } catch {
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }

    private func autoReconnect() async {
        guard bluetooth.client == nil,
              bluetooth.adapter == .poweredOn,
              let first = knownDevices.first else { return }
        isReconnecting = true
        defer { isReconnecting = false }
        do {
            let client = try await reconnectByPreferredIdentity(recordID: first.id)
            configService.rememberDevice(id: first.id, name: client.displayName)
            _ = try? await client.getDeviceInfo()
            _ = try? await client.getSwitchInfo()
            try? await client.syncTime()
        } catch {
            // Silent fail — pill shows grayed state
        }
    }
}
