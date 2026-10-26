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
    @ObservedObject private var plaudDirect = PlaudDirectService.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showScanner = false
    @State private var showDevice = false
    @State private var pendingDeviceRemoval: KnownDevice?
    /// The recorder card detail page (`RecorderSheet`) to open after successful reconnection.
    /// It shares the same responsibility as the same-named state inside the Scan page, but the entry point is on the main interface.
    @State private var openedRecorder: DiscoveredRecorder?
    /// PLAUD device-info sheet (2026-10-21, 3rd round): the card's SN / battery /
    /// storage / unbind actions live here, reached by tapping the pill — the home
    /// page only lists what is ON the card.
    @State private var showPlaudInfo = false
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

    /// ★ Top-left pill identity for a PLAUD card (2026-10-21).
    ///
    /// Only offered when no other device is live: D·NOTE and the recorder cards
    /// own the pill while they are connected, and PLAUD must never steal the
    /// label from them. When nothing else is up, the card we paired with **last**
    /// is the honest answer to "which device did I use before" — that is exactly
    /// the user's "顶部设备显示应该是上一次链接过的设备名称".
    private var plaudPill: PlaudPillState? {
        guard let sn = plaudDirect.pairedSN else { return nil }
        let ledgerID = "plaud-\(sn)"
        // A live PLAUD link **is** the current card — it wins even if a recorder
        // handle is still winding down, otherwise the pill keeps the old name
        // right after a successful switch ("切换了但没有同步过去" again).
        if !plaudDirect.phase.isConnected {
            guard bluetooth.client == nil, bluetooth.recorderLink == nil else { return nil }
            // A card whose ledger row was removed stays silent in the pill — unless it
            // is actually connected, where pretending otherwise would be a lie.
            guard configService.config.devices[ledgerID] != nil else { return nil }
            // …and only when it really is the **last** device used. Otherwise a
            // remembered PLAUD would hijack the label from the TicNote the user
            // actually unplugged a minute ago.
            if let newest = knownDevices.first, newest.id != ledgerID { return nil }
        }
        return PlaudPillState(
            name: plaudDirect.displayName,
            sn: sn,
            isConnected: plaudDirect.phase.isConnected,
            isRecording: plaudDirect.isRecording,
            isBusy: plaudDirect.phase.isBusy
        )
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
        // ★ Theme: one place, whole app.
        //
        // `.tint()` writes `EnvironmentValues.tint`, and since iOS 16 that is the
        // **same key** `Color.appAccent` resolves through (`accentColor(_:)` is
        // only its deprecated spelling). So the ~20 call sites that already say
        // `Color.appAccent` follow along without being touched — including the
        // ones in sheets, because a presented sheet inherits the environment of
        // the view that presented it.
        //
        // ⚠️ Do not turn this into a hard-coded `Color` anywhere else "just this
        // once": the next palette then leaves a patch of the old red behind.
        .tint(AppTheme.resolve(configService.config.appTheme).accent)
        // ★ 2026-10-20: the "transcript ready" toast, user's words: "有消息转录完成则弹出
        //   顶部导航栏提示告知转录完成". Top-aligned overlay on the whole TabView (not per
        //   tab) so it appears wherever the user happens to be, right under the status bar
        //   — over the navigation bar, which is what "顶部导航栏" names. Tapping deep-opens
        //   the clip through `openClipFromBanner`.
        .overlay(alignment: .top) {
            TranscriptionBannerView { clipName in
                openClipFromBanner(clipName)
            }
            .padding(.horizontal, 16)
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
        // PLAUD's own device page — same shape as the recorder cards' device
        // sheet, which is why the pill opens it for both device families.
        .sheet(isPresented: $showPlaudInfo) {
            PlaudDeviceInfoSheet()
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
            // ★ 2026-10-22 ("卡片断开时候通知我，包含手机蓝牙直接关闭"): the PLAUD
            // SDK owns its own central, so `BluetoothCoordinator`'s teardown — the
            // place that now alerts for the other cards — cannot see it. Turning
            // the radio off kills that link without a disconnect callback, so the
            // state has to be settled (and the user told) from here.
            //
            // `.poweredOff` only: `.resetting` is a transient restart during which
            // the link usually comes straight back, and alerting on it would train
            // the user to ignore the one alert that matters.
            if newState == .poweredOff {
                plaudDirect.handleAdapterOff()
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
        // ★ 2026-10-15: on returning to the foreground, resume the transcription that didn't finish last time.
        //
        // Why this point (with `AppEnvironment.init` having already hung it once): when the process is
        // killed by the system in the background, the `init` path **never gets a chance to run** — because that's "the next
        // cold launch". But there's a more common case: the process **isn't dead**, it's just that the task was
        // cut off by URLSession during suspension, and when the user switches back, `init` won't run again.
        // Hanging it on `scenePhase` covers both cases, and depends on no persistence flag.
        //
        // Re-entry is guarded by `TranscriptionService.startDrainIfNeeded`, so repeated calls are safe.
        //
        // ★ 2026-10-16 twelfth revision: here we also resume the summary / translation / format conversion queue
        // (`env.jobs.resume()`). The reasoning for both resumes is perfectly symmetric:
        // hanging only off `init` misses the "process alive, task cut off" half; hanging only off here misses
        // the "process killed, user cold-starts again" half. Both re-entries are guarded by their own
        // `startDrainIfNeeded`.
        .onChange(of: scenePhase) { phase in
            handleScenePhase(phase)
        }
    }

    /// Foreground/background side effects, kept out of `body` — inlining them
    /// pushed the view builder past the type-checker's time budget.
    private func handleScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            env.transcription.resumePending()
            env.jobs.resume()
            // A toast that finished queuing in the background must not pop up
            // minutes after unlock — drop anything past its shelf life.
            TranscriptionBannerCenter.shared.dropStale()
            // ★ 2026-10-26: "打开就要持续连接状态" — re-arm the PLAUD keeper on
            // every foreground so a card that slept in a pocket comes back on
            // its own instead of waiting for a tap.
            plaudDirect.startConnectionKeeper()
        } else if phase == .background {
            // Nothing to keep alive while suspended; the next foreground start
            // reconnects anyway.
            plaudDirect.stopConnectionKeeper()
        }
    }

    /// Deep-open the clip the "transcript ready" banner was tapped for.
    ///
    /// The path is three layers (tab → library segment → `detailItem`), and each layer owns
    /// its own lock: the tab switch is blocked by the transfer alert while a BLE transfer
    /// runs, and `RecordingsView` guards the segment switch the same way. So this only
    /// **sets the intent** (`env.pendingClipOpen`); the library consumes it whenever the
    /// user actually reaches it. While transferring, the toast is informational — tapping
    /// it lands on the recordings tab and nothing more, which beats fighting the locks.
    private func openClipFromBanner(_ clipName: String) {
        selectedTab = .recordings
        guard !env.isBLETransferring else { return }
        env.pendingClipOpen = clipName
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
                            plaud: plaudPill,
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
        // ★ 2026-10-22: PLAUD is checked **first**. It has no `DnoteClient` and no
        // `RecorderLink`, so the branches below can't recognise it, and while any
        // other card's handle lingered the tap opened *that* card's sheet while
        // the pill label already said PLAUD — one tap, two answers.
        if plaudDirect.phase.isConnected {
            showPlaudInfo = true
            return
        }
        if bluetooth.client != nil {
            showDevice = true
        } else if bluetooth.recorderLink?.isConnected == true,
                  let recorder = bluetooth.matchedRecorder {
            openedRecorder = recorder
        } else if plaudDirect.pairedSN != nil {
            // ★ 2026-10-21 user report: "tapping the PLAUD pill in the top-left
            // does not connect or wake the device", then (2nd round) "the device
            // info should only appear when I tap the device in the top-left".
            //
            // So the pill now *is* the way into the card's own page: it opens the
            // device info sheet (SN / firmware / battery / storage / unbind /
            // transfer prefs), and if the link is down it also kicks a wake +
            // bind so the page fills in.
            if !plaudDirect.phase.isConnected, !plaudDirect.phase.isBusy {
                plaudDirect.reconnect()
            }
            showPlaudInfo = true
        } else if let first = knownDevices.first {
            // A connect attempt is already in flight (spinner showing) —
            // tapping again would start a second scan on the same device and
            // the two would race to set/clear `isReconnecting` (3op2cmn).
            guard !isReconnecting else { return }
            if first.id.hasPrefix("plaud-") {
                openPlaud(ledgerID: first.id)
            } else {
                Task { await connectToDevice(id: first.id) }
            }
        }
    }

    /// Wake / bind a PLAUD card identified by its ledger id (`plaud-<SN>`),
    /// then land the user on the page that shows what is on it.
    ///
    /// Kept in one place because three entries hit the same path: the pill, the
    /// pill's device picker, and (defensively) `connectToDevice`.
    ///
    /// ★ 2026-10-22 ("切换卡片的时候选择 PLAUD 无法切换，但是选择其他的卡片可以"):
    /// switching **to** a PLAUD card never went through `connectToDevice` — the
    /// only path that tears the previous card down — so the TicNote/A1/D·NOTE
    /// link stayed live, kept owning the pill (see `plaudPill`), and the switch
    /// looked like it never happened even when the card did bind. The other
    /// direction worked precisely because it *did* go through `connectToDevice`.
    /// One card at a time, both ways.
    private func openPlaud(ledgerID: String) {
        let sn = String(ledgerID.dropFirst("plaud-".count))
        guard !sn.isEmpty else { return }
        releaseOtherCardsForPlaud()
        // `switchCard` is the single entry now: it handles "connected to another
        // PLAUD card", "idle", and "stuck mid-scan" the same way (`connectKnown`
        // used to return silently in two of those three cases).
        plaudDirect.switchCard(to: sn)
        selectedTab = .recordings
        showPlaudInfo = true
    }

    /// Drop whatever card is holding the BLE link so a PLAUD card can take it.
    ///
    /// `userInitiated` semantics matter: this is a deliberate card change, so the
    /// old link must not be reconnected by the recorder watchdog, and it must not
    /// fire a "card left behind" alert either.
    private func releaseOtherCardsForPlaud() {
        guard bluetooth.client != nil || bluetooth.recorderLink != nil else { return }
        bluetooth.disconnect()
    }

    private func handleSelectDevice(_ id: String) {
        // PLAUD rows in the picker are ledger ids (`plaud-<SN>`) — they have no
        // `RecorderLink` to connect through, so route them to the card service.
        if id.hasPrefix("plaud-") {
            openPlaud(ledgerID: id)
            return
        }
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
        // PLAUD: "remove" drops the ledger row (so it no longer sits next to the
        // other cards) and closes the link. The BLE credential/binding is NOT
        // erased here — that is the explicit "unbind card" action on the card's
        // own settings page, and wiping it from a menu tap would be a nasty
        // surprise. Reconnecting later re-creates the row automatically.
        if device.id.hasPrefix("plaud-") {
            plaudDirect.disconnect()
            configService.config.devices.removeValue(forKey: device.id)
            configService.scheduleSave()
            return
        }
        if bluetooth.client?.peripheral.identifier.uuidString == device.id ||
            bluetooth.recorderLink?.peripheral.identifier.uuidString == device.id {
            bluetooth.disconnect()
        }
        configService.config.devices.removeValue(forKey: device.id)
        configService.scheduleSave()
    }

    private func connectToDevice(id: String) async {
        // Defensive: a PLAUD ledger id must never reach the recorder-card scan
        // (it has no advertisement to match, so the scan would just time out).
        if id.hasPrefix("plaud-") {
            openPlaud(ledgerID: id)
            return
        }
        // ★ 2026-10-22: the same "one card at a time" rule in reverse. Switching
        // from a PLAUD card to a TicNote/A1/D·NOTE used to leave the PLAUD link
        // up (it is not a `RecorderLink`, so `bluetooth.disconnect()` cannot see
        // it), and the two then competed for the same radio.
        if plaudDirect.phase.isConnected || plaudDirect.phase.isBusy {
            plaudDirect.disconnect()
        }
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
