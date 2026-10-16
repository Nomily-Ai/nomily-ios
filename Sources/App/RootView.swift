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
    @State private var pendingDeviceRemoval: KnownDevice?
    /// The recorder card detail page (`RecorderSheet`) to open after successful reconnection.
    /// It shares the same responsibility as the same-named state inside the Scan page, but the entry point is on the main interface.
    @State private var openedRecorder: DiscoveredRecorder?
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
    /// TicNote shares a recording state with D·NOTE; the top bar and the recording page must not make independent assumptions.
    @StateObject private var recorderSession = RecorderSessionModel()

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

    /// Candidate for automatic reconnection: **skip recorder card**. Reconnecting the recorder card relies on scans and other broadcasts
    /// (Power‑saving broadcasts, measured interval up to 152 seconds), keeping a 100‑second scan in the background is both power‑hungry
    /// and also unreliable (when in background, a scan with `withServices: nil` returns nothing on iOS).
    /// Reconnection entry for the recorder card: the user taps the pill or the "Add Device" page, see `connectRecorderDevice`.
    private var autoReconnectCandidates: [KnownDevice] {
        knownDevices.filter { !configService.isRecorderRecord($0.id) }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            tabContent(L10n.Tab.recordings, RecordingsView(session: recorderSession))
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
        // ★ 2026-10-14: Pass `.deviceInfo`, and `openCardInfoOnAppear` no longer exists.
        //
        // This is the path entered by tapping the top‑bar capsule: the user taps **Device** (the capsule shows the card name/battery level),
        // It should pop up the device info page — consistent with the landing point after connecting via the Scan page and with V05E's `DeviceSheet`
        // All three are consistent. Recording materials are viewed in the "Recording" tab's "Device" section on the home page (user's exact words:
        // > "It just needs to be displayed in the home page devices of Nomily AI.").
        //
        // `openCardInfoOnAppear` was removed because its sole purpose was to "automatically pop up the card info dialog after entering the page"
        // card info dialog", but now **this page itself is that content** (`deviceInfoPage` →
        // `cardInfoContent`), adding another layer of dialog results in a dialog‑in‑dialog.
        .sheet(item: $openedRecorder) { recorder in
            RecorderSheet(recorder: recorder, mode: .deviceInfo)
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
        .alert("Remove device?", isPresented: Binding(
            get: { pendingDeviceRemoval != nil },
            set: { if !$0 { pendingDeviceRemoval = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let device = pendingDeviceRemoval { removeKnownDevice(device) }
                pendingDeviceRemoval = nil
            }
            Button(L10n.Common.cancel, role: .cancel) { pendingDeviceRemoval = nil }
        } message: {
            Text("This removes the saved connection from Nomily AI. It does not erase recordings on the device.")
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
        // ★ 2026-10-15：回到前台时，把上次没干完的转录接着跑。
        //
        // 为什么要这个点（`AppEnvironment.init` 已经挂过一次了）：进程在后台
        // 被系统咔嚓掉时，`init` 那条路**根本没机会跑** —— 因为那是"下一次
        // 冷启动"。但还有更常见的一种：进程**没死**，只是任务在挂起期间
        // 被 URLSession 断掉了，此时用户切回来，`init` 不会再跑一次。
        // 挂在 `scenePhase` 上两种情况都能盖住，且不依赖任何持久化标记。
        //
        // 重入由 `TranscriptionService.startDrainIfNeeded` 挡着，重复调安全。
        //
        // ★ 2026-10-16 十二改：这里同时把摘要 / 翻译 / 格式转换那条队列也
        // resume 一下（`env.jobs.resume()`）。两处 resume 的理由完全对称：
        // 只挂 `init` 会漏掉"进程活着、任务被断掉"那半边；只挂这里会漏掉
        // "进程被杀、用户重新冷启动"那半边。两处的重入都由各自的
        // `startDrainIfNeeded` 挡着。
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                env.transcription.resumePending()
                env.jobs.resume()
            }
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
                            recorderLink: bluetooth.recorderLink,
                            recorderDeviceInfo: bluetooth.recorderDeviceInfo,
                            recorderIsRecording: recorderSession.isRecording,
                            adapter: bluetooth.adapter,
                            knownDevices: knownDevices,
                            isReconnecting: isReconnecting,
                            recorderReconnectState: bluetooth.recorderReconnectState,
                            onTapDevice: handlePillTap,
                            onAddDevice: { showScanner = true },
                            onSelectDevice: handleSelectDevice,
                            onRemoveDevice: { pendingDeviceRemoval = $0 }
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
        } else if bluetooth.recorderLink?.isConnected == true,
                  let recorder = bluetooth.matchedRecorder {
            openedRecorder = recorder
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
        } else if bluetooth.recorderLink?.isConnected == true,
                  bluetooth.recorderLink?.peripheral.identifier.uuidString == id,
                  let recorder = bluetooth.matchedRecorder {
            openedRecorder = recorder
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

    private func removeKnownDevice(_ device: KnownDevice) {
        if bluetooth.client?.peripheral.identifier.uuidString == device.id ||
            bluetooth.recorderLink?.peripheral.identifier.uuidString == device.id {
            bluetooth.disconnect()
        }
        configService.config.devices.removeValue(forKey: device.id)
        configService.scheduleSave()
    }

    private func connectToDevice(id: String) async {
        // Spinner from the first await: the recording-state check below
        // waits on the command lock, and that wait is the user's only
        // feedback until the old link is torn down.
        isReconnecting = true
        defer { isReconnecting = false }
        // ★ Recorder cards (like TicNote) use their own reconnection: the DnoteClient approach
        // getDeviceInfo/binding checks are completely inapplicable to them.
        if configService.isRecorderRecord(id) {
            await connectRecorderDevice(id: id)
            return
        }
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

    /// Manual reconnection of recorder cards (ledger `is_recorder`): scan → wait for broadcast → match by UUID → connect,
    /// After connecting, open its recording page (behaving the same as after connecting via the Scan page).
    ///
    /// Why not merge into `reconnectByPreferredIdentity`: that signature returns a `DnoteClient`,
    /// whereas the recorder‑card path is `any RecorderLink` — a forced fit would only mix the two device models together.
    private func connectRecorderDevice(id: String) async {
        bluetooth.disconnect()
        do {
            _ = try await bluetooth.reconnectRecorder(recordID: id)
            let name = configService.config.devices[id]?.name ?? bluetooth.matchedRecorder?.name
                ?? bluetooth.recorderLink?.displayName ?? "Recorder"
            configService.rememberDevice(id: id, name: name, isRecorder: true)
            if let recorder = bluetooth.matchedRecorder {
                openedRecorder = recorder
            }
        } catch {
            // Same principle as manual reconnection for D·NOTE: manual actions must yield an executable result.
            let message: String
            if bluetooth.adapter != .poweredOn {
                message = bluetooth.adapter.userMessage ?? error.localizedDescription
            } else if error is RecorderLinkError {
                // Broadcast intervals can reach 152 seconds; timeouts are usually because the card is asleep — guide it to wake up.
                message = L10n.Scanner.wakeAndRetry
            } else {
                message = error.localizedDescription
            }
            manualConnectFailure = .init(deviceID: id, message: message)
        }
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
        guard let target = autoReconnectCandidates.first else { return }

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
              let first = autoReconnectCandidates.first else { return }
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
