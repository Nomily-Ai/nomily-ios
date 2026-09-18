import SwiftUI

/// Modal device sheet — connection, identity, audio, behavior, danger zone.
struct DeviceSheet: View {
    @ObservedObject var client: DnoteClient
    @EnvironmentObject private var bluetooth: BluetoothCoordinator
    @EnvironmentObject private var configService: ConfigService
    @Environment(\.dismiss) private var dismiss

    @State private var refreshError: String?
    @State private var refreshing = false
    @State private var busyMessage: String?
    @State private var showFormat = false
    @State private var showFactoryReset = false
    @State private var showShutdown = false
    @State private var showUnpair = false
    @State private var showUnbindRemove = false
    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            Form {
                hero
                if client.lastBondState?.bound == false {
                    pairingBanner
                        .disabled(isRecording)
                }
                if let info = client.lastDeviceInfo {
                    identitySection(info)
                        .disabled(isRecording)
                }
                if let switches = client.lastSwitchInfo {
                    audioSection(switches)
                        .disabled(isRecording)
                }
                if let switches = client.lastSwitchInfo {
                    behaviorSection(switches)
                        .disabled(isRecording)
                }
                dangerZone
                    .disabled(isRecording)
                disconnectSection
                    .disabled(isRecording)
            }
            .navigationTitle(client.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Common.done) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        if refreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(refreshing)
                }
            }
            .overlay(alignment: .bottom) { busyOverlay }
            .alert(L10n.Device.couldntUpdate, isPresented: errorBinding) {
                Button(L10n.Common.ok, role: .cancel) { refreshError = nil }
            } message: { Text(refreshError ?? "") }
            .confirmationDialog(
                L10n.Device.eraseAllRecordings,
                isPresented: $showFormat,
                titleVisibility: .visible
            ) {
                Button(L10n.Device.formatStorage, role: .destructive) { run(L10n.Device.formatting) { try await client.formatDisk() } }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Device.eraseMessage)
            }
            .confirmationDialog(
                L10n.Device.restoreFactory,
                isPresented: $showFactoryReset,
                titleVisibility: .visible
            ) {
                Button(L10n.Device.factoryReset, role: .destructive) {
                    run(L10n.Device.resetting) {
                        try await client.factoryReset()
                        _ = try? await client.getSwitchInfo()
                        _ = try? await client.getDeviceInfo()
                    }
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Device.restoreMessage)
            }
            .confirmationDialog(
                L10n.Device.powerOff,
                isPresented: $showShutdown,
                titleVisibility: .visible
            ) {
                Button(L10n.Device.shutDown, role: .destructive) {
                    run(L10n.Device.shuttingDown) { try await client.shutdown() }
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Device.powerOffMessage)
            }
            .confirmationDialog(
                L10n.Pairing.unpair,
                isPresented: $showUnpair,
                titleVisibility: .visible
            ) {
                Button(L10n.Pairing.unpair, role: .destructive) {
                    run(L10n.Pairing.unpairing) {
                        try await client.unbindDevice()
                    }
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Pairing.unpairMessage)
            }
            .confirmationDialog(
                L10n.Device.unbindAndRemove,
                isPresented: $showUnbindRemove,
                titleVisibility: .visible
            ) {
                Button(L10n.Device.unbindAndRemove, role: .destructive) {
                    run(L10n.Device.unbindingAndRemoving) { try await unbindAndRemove() }
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Device.unbindAndRemoveMessage)
            }
            .alert(L10n.Device.bluetoothName, isPresented: $showRename) {
                TextField(L10n.Device.bluetoothName, text: $renameText)
                    .onChange(of: renameText) { newValue in
                        renameText = DnoteProtocol.clampBluetoothName(newValue)
                    }
                Button(L10n.Common.save) {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    run(L10n.Device.savingName) {
                        try await client.setBluetoothName(name)
                        _ = try? await client.getDeviceInfo()
                    }
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            }
        }
        .task {
            await refresh()
        }
    }

    // MARK: sections

    private var isRecording: Bool {
        client.lastDeviceInfo?.isRecording == true
    }

    private var hero: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(client.displayName).font(.title3.weight(.semibold))
                    Spacer()
                    if let battery = client.lastDeviceInfo?.battery {
                        Label("\(battery)%", systemImage: batteryIcon(battery))
                            .font(.callout.weight(.medium))
                    }
                }

                if client.lastDeviceInfo?.isRecording == true {
                    Label(L10n.Common.recording, systemImage: "record.circle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline.weight(.semibold))
                    // Everything below is greyed out while recording. Say why —
                    // a whole panel of dead controls otherwise reads as a bug
                    // (hzhmmgff). Same sentence the command layer throws.
                    Text(DnoteError.operationUnavailableWhileRecording.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if client.negotiatedMTU > 0 {
                    Text(L10n.Device.connectedMTU(client.negotiatedMTU))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let info = client.lastDeviceInfo,
                   let free = info.freeMB,
                   let total = info.totalMB,
                   total > 0 {
                    let frac = Double(total - free) / Double(total)
                    ProgressView(value: frac) {
                        Text(L10n.Device.storageUsed(formatMB(total - free), formatMB(total)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func identitySection(_ info: DeviceInfo) -> some View {
        Section(L10n.Device.identity) {
            Button {
                renameText = info.bluetoothName ?? client.displayName
                showRename = true
            } label: {
                HStack {
                    Text(L10n.Device.bluetoothName).foregroundStyle(.primary)
                    Spacer()
                    Text(info.bluetoothName ?? client.displayName).foregroundStyle(.secondary)
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
                }
            }
            row(L10n.Device.serial, info.serial ?? "—")
            row(L10n.Device.firmware, info.firmware ?? "—")
            row(L10n.Device.btMAC, Self.formatMAC(info.bluetoothMAC) ?? "—")
            row(L10n.Device.deviceTime, info.deviceTime ?? "—")
            if let bond = client.lastBondState {
                row(L10n.Pairing.pairStatus, bond.bound ? L10n.Pairing.paired : L10n.Pairing.notPaired)
            }
        }
    }

    @ViewBuilder
    private func audioSection(_ switches: SwitchInfo) -> some View {
        // Each item includes a hint: the name alone doesn't indicate "what happens if enabled" or "the cost of increasing/decreasing the value".
        // "Noise reduction" and "noise suppression" appear to be the same thing based on their names.
        Section(L10n.Device.audio) {
            switchToggle(.nc,  label: L10n.Device.noiseCancel, hint: L10n.Device.noiseCancelHint, isOn: switches.noiseCancel)
            switchToggle(.wav, label: L10n.Device.saveRawWAV, hint: L10n.Device.saveRawWAVHint, isOn: switches.saveWAV)
            switchToggle(.vad, label: L10n.Device.vad, hint: L10n.Device.vadHint, isOn: switches.vad)
            gainSlider(
                label: L10n.Device.micGain,
                hint: L10n.Device.micGainHint,
                value: switches.micGain == 0 ? 3 : switches.micGain,
                apply: { try await client.setMicGain($0) }
            )
            gainSlider(
                label: L10n.Device.noiseReduction,
                hint: L10n.Device.noiseReductionHint,
                value: switches.noiseReduction == 0 ? 3 : switches.noiseReduction,
                apply: { try await client.setNRLevel($0) }
            )
        }
    }

    @ViewBuilder
    private func behaviorSection(_ switches: SwitchInfo) -> some View {
        Section(L10n.Device.behavior) {
            switchToggle(.led,   label: L10n.Device.ledIndicator, isOn: switches.led)
            switchToggle(.motor, label: L10n.Device.vibration,     isOn: switches.motor)
            switchToggle(.ms, label: L10n.Device.usbDriveMode, hint: L10n.Device.usbDriveModeHint, isOn: switches.massStorage)
            IdleOffPicker(
                current: switches.idleOff,
                onSelect: { seconds in
                    run(L10n.Device.savingIdleOff) {
                        try await client.setIdleOff(seconds: seconds)
                        _ = try? await client.getSwitchInfo()
                    }
                }
            )
        }
    }

    /// Shown when the device reports itself as unbound. Primary action =
    /// pair now (no alert; user is already in the sheet). Matches the
    /// RootView `.alert` flow but lets the user re-pair after they
    /// dismissed the auto-prompt or explicitly unpaired earlier.
    @ViewBuilder
    private var pairingBanner: some View {
        Section {
            Button {
                Task { await pairFromSheet() }
            } label: {
                Label(L10n.Pairing.pair, systemImage: "link.badge.plus")
            }
        } footer: {
            Text(L10n.Pairing.message(client.displayName))
        }
    }

    private func pairFromSheet() async {
        let bondID = Data((0..<DnoteProtocol.bondIDLength).map { _ in UInt8.random(in: 0...255) })
        busyMessage = L10n.Pairing.pairingNow
        defer { busyMessage = nil }
        do {
            try await client.bindDevice(bondID: bondID)
            configService.setBondID(
                for: client.peripheral.identifier.uuidString,
                name: client.displayName,
                bondID: bondID.hexString
            )
        } catch {
            refreshError = error.localizedDescription
        }
    }

    /// Unbind the device and erase this binding's footprint. Turning
    /// encryption off is best-effort (`try?`) — a device that won't drop its
    /// key shouldn't block the removal — but the on-device wipe is not: if
    /// any recording survives we abort instead of releasing a device that
    /// still holds this user's audio.
    ///
    /// The wipe runs *before* the unbind deliberately. The erase command
    /// doesn't require a bond today (only recording/streaming do), but
    /// wiping while the device is still bound removes any doubt that it
    /// could be refused — and a failed erase leaves everything else
    /// untouched, so the user can simply retry.
    private func unbindAndRemove() async throws {
        // 1. If an encryption key is in play, try to turn device encryption
        //    off, then drop the locally-held key for this SN.
        if let key = KeyResolver.key(for: client) {
            try? await client.setEncryption(on: false, key: key)
        }
        if let sn = client.lastDeviceInfo?.serial, !sn.isEmpty {
            _ = PassphraseStore.clear(sn: sn)
        }

        // 2. Erase the recordings held on the device so this binding's audio
        //    can't leak to whoever pairs next. formatDisk clears them all in
        //    one command (switch settings + Bluetooth name survive), which
        //    beats a per-file delete loop: no partial-failure window, and a
        //    throw here aborts before we unbind so the user can retry.
        try await client.formatDisk()

        // 3. Drop the binding on the device.
        try await client.unbindDevice()

        // 4. Forget the device in the app's paired-device list, then drop
        //    the link — staying connected to a removed device makes no sense.
        configService.config.devices.removeValue(
            forKey: client.peripheral.identifier.uuidString
        )
        configService.scheduleSave()
        bluetooth.disconnect()

        dismiss()
    }

    private var dangerZone: some View {
        Section {
            Button(role: .destructive) { showFormat = true } label: {
                Label(L10n.Device.formatStorage, systemImage: "externaldrive.badge.xmark")
            }
            Button(role: .destructive) { showFactoryReset = true } label: {
                Label(L10n.Device.factoryReset, systemImage: "arrow.counterclockwise.circle")
            }
            Button(role: .destructive) { showShutdown = true } label: {
                Label(L10n.Device.shutDown, systemImage: "power.circle")
            }
            if client.lastBondState?.bound == true {
                Button(role: .destructive) { showUnpair = true } label: {
                    Label(L10n.Pairing.unpair, systemImage: "xmark.circle")
                }
            }
            // Always available: removing the device from the app shouldn't
            // require it to still be bound.
            Button(role: .destructive) { showUnbindRemove = true } label: {
                Label(L10n.Device.unbindAndRemove, systemImage: "trash.slash")
            }
        } header: {
            Text(L10n.Device.dangerZone)
        } footer: {
            Text(L10n.Device.dangerZoneFooter)
        }
    }

    private var disconnectSection: some View {
        Section(L10n.Device.connection) {
            Button(role: .destructive) {
                bluetooth.disconnect()
                dismiss()
            } label: {
                Label(L10n.Device.disconnect, systemImage: "bolt.slash")
            }
        }
    }

    // MARK: helpers

    @ViewBuilder
    private var busyOverlay: some View {
        if let msg = busyMessage {
            HStack(spacing: 10) {
                ProgressView()
                Text(msg).font(.subheadline)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 16)
            .transition(.opacity)
        }
    }

    private func switchToggle(_ s: DnoteClient.Switch, label: String, hint: String? = nil, isOn: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in
                Task {
                    do {
                        try await client.setSwitch(s, on: newValue)
                        _ = try? await client.getSwitchInfo()
                    } catch {
                        refreshError = error.localizedDescription
                    }
                }
            }
        )) {
            HStack(spacing: 4) {
                Text(label)
                if let hint { InfoTip(text: hint) }
            }
        }
    }

    private func gainSlider(
        label: String,
        hint: String? = nil,
        value: Int,
        apply: @escaping (Int) async throws -> Void
    ) -> some View {
        GainSlider(label: label, hint: hint, committedValue: value) { level in
            try await apply(level)
            _ = try? await client.getSwitchInfo()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case ..<10:  return "battery.0"
        case ..<35:  return "battery.25"
        case ..<60:  return "battery.50"
        case ..<85:  return "battery.75"
        default:     return "battery.100"
        }
    }

    /// Normalise a BT MAC into "00:00:AB:CD:EF:12" form.
    /// Handles raw hex ("0000ABCDEF12") and already-separated variants.
    static func formatMAC(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let hex = raw.uppercased().filter { $0.isHexDigit }
        guard hex.count == 12 else { return raw }
        return stride(from: 0, to: 12, by: 2).map { i in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 2)
            return String(hex[start..<end])
        }.joined(separator: ":")
    }

    private func formatMB(_ mb: Int) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", Double(mb) / 1024.0)
        } else {
            return "\(mb) MB"
        }
    }

    private func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            try await client.getDeviceInfo()
            try await client.getSwitchInfo()
            _ = try? await client.queryBondState()
        } catch {
            refreshError = error.localizedDescription
        }
    }

    /// Run an async command while showing a bottom pill. Errors surface in
    /// the shared alert.
    private func run(_ message: String, _ op: @escaping () async throws -> Void) {
        guard busyMessage == nil else { return }
        busyMessage = message
        Task {
            defer { busyMessage = nil }
            do {
                try await op()
            } catch {
                refreshError = error.localizedDescription
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { refreshError != nil },
            set: { if !$0 { refreshError = nil } }
        )
    }
}

// MARK: - Idle-off picker

private struct IdleOffPicker: View {
    let current: UInt32
    let onSelect: (UInt32) -> Void

    private let presets: [(String, UInt32)] = [
        ("30 s",  30),
        ("1 m",   60),
        ("5 m",   5 * 60),
        ("15 m",  15 * 60),
        ("1 h",   60 * 60),
        (L10n.Device.never, DnoteProtocol.idleOffNever),
    ]

    var body: some View {
        Picker(L10n.Device.autoPowerOff, selection: Binding(
            get: { current },
            set: { onSelect($0) }
        )) {
            ForEach(presets, id: \.1) { label, value in
                Text(label).tag(value)
            }
            // If the firmware reported a custom value we don't have a preset
            // for, show it as-is so we don't silently rewrite the user's choice.
            if !presets.contains(where: { $0.1 == current }) && current > 0 {
                Text(L10n.Device.customIdleOff(current)).tag(current)
            }
        }
    }
}

// MARK: - GainSlider

/// Slider for mic-gain / NR-level (1–9). Keeps a local draft value while
/// dragging so the label stays responsive; sends the BLE command only once
/// when the user lifts their finger (onEditingChanged: false).
private struct GainSlider: View {
    let label: String
    let hint: String?
    let committedValue: Int
    let onCommit: (Int) async throws -> Void

    @State private var draft: Double

    init(label: String, hint: String? = nil, committedValue: Int, onCommit: @escaping (Int) async throws -> Void) {
        self.label = label
        self.hint = hint
        self.committedValue = committedValue
        self.onCommit = onCommit
        self._draft = State(initialValue: Double(committedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                if let hint { InfoTip(text: hint) }
                Spacer()
                Text("\(Int(draft.rounded())) / 9")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $draft, in: 1...9, step: 1) { editing in
                guard !editing else { return }
                let level = Int(draft.rounded())
                Task { try? await onCommit(level) }
            }
        }
        .onChange(of: committedValue) { draft = Double($0) }
    }
}
