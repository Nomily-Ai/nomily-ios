import SwiftUI

/// Add-device sheet. ★ 2026-10-21 redesign (user request): pick a **device
/// type first**, then scan — instead of one mixed BLE list. The PLAUD card
/// opens its own SDK flow and Apple Watch opens an install guide; the other
/// three start a scan filtered to that family only.
struct ScannerSheet: View {
    @EnvironmentObject private var bluetooth: BluetoothCoordinator
    @EnvironmentObject private var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    let onConnected: () -> Void

    /// Device families offered on the pick page. PLAUD is handled as its own
    /// sheet action (official SDK, separate radio session) and Apple Watch is
    /// an install guide, so neither is a scan target here.
    enum AddCategory: String, CaseIterable, Identifiable {
        case vobot
        case ticnote
        case dingtalkA1
        case soundcore
        case appleWatch

        var id: String { rawValue }

        var title: String {
            switch self {
            case .vobot: return L10n.Scanner.categoryVobot
            case .ticnote: return L10n.Scanner.categoryTicnote
            case .dingtalkA1: return L10n.Scanner.categoryA1
            // ★ 飞书录音豆（soundcore Work D3200）——与飞书 App 并行使用，
            //   App 端不做绑定（红线），仅控制/拉取录音。
            case .soundcore: return "soundcore Work · 飞书录音豆"
            case .appleWatch: return L10n.Scanner.categoryWatch
            }
        }

        var subtitle: String {
            switch self {
            case .vobot, .ticnote, .dingtalkA1, .soundcore: return L10n.Scanner.actionScan
            case .appleWatch: return L10n.Scanner.actionWatch
            }
        }

        var icon: String {
            switch self {
            case .vobot: return "hifispeaker.2"
            case .ticnote: return "waveform.circle"
            case .dingtalkA1: return "key.horizontal"
            case .soundcore: return "mic.circle"
            case .appleWatch: return "applewatch"
            }
        }
    }

    @State private var category: AddCategory?
    @State private var connecting: DiscoveredPeripheral?
    @State private var connectError: String?
    /// Recording cards that are currently connecting (non D·NOTE). Separate from `connecting` because after connecting it goes into
    /// another flow (`RecorderSheet`), not the D·NOTE device page.
    @State private var connectingRecorder: DiscoveredRecorder?
    @State private var openedRecorder: DiscoveredRecorder?
    @State private var showPlaudAdd = false
    @State private var showWatchGuide = false

    var body: some View {
        NavigationStack {
            Group {
                if category == nil {
                    categoryGrid
                } else {
                    scanContent
                }
            }
            .navigationTitle(category == nil ? L10n.Scanner.addTitle : L10n.Scanner.scan)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if category != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            category = nil
                            bluetooth.stopScan()
                        } label: {
                            Image(systemName: "chevron.backward")
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if bluetooth.isScanning {
                            ProgressView()
                        } else {
                            Button(L10n.Scanner.scanAgain) { bluetooth.startScan() }
                                .disabled(bluetooth.adapter != .poweredOn)
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
            .alert(L10n.Scanner.connectionFailed, isPresented: errorBinding, actions: {
                Button(L10n.Common.ok, role: .cancel) { connectError = nil }
            }, message: { Text(connectError ?? "") })
            .sheet(isPresented: $showPlaudAdd) {
                PlaudAddSheet()
            }
            .sheet(isPresented: $showWatchGuide) {
                WatchAddGuideSheet()
            }
        }
        // ★ 2026-10-14: Pass `.deviceInfo` — user quote
        //   > "When adding a device, do not show recording time; directly display device information,
        //   >  Reference V05E's logic to display device information; do not immediately show recordings when the device is tapped"
        //
        // This is the path of “tap a device”: on the scan page, connect a TicNote, and the popup should be
        // **How is this card** (name / storage / battery / charging / model / gain / transmission preference),
        // Isomorphic to V05E's `DeviceSheet` — its recording files are also in another entry
        // (`DeviceFilesView`), not in the device page.
        //
        // ⚠️ Do not casually change this line to the default value: it would cause users to see a flood of recording times again.
        //    The home entry (`RecordingsView`) should keep `.recordings`.
        // ★ 2026-10-20: `onFinish` — after adding a card, "Done" must land the user back
        //   on the **home page**, not leave them on the scan list where tapping the same
        //   device again looks like it would add it a second time. This mirrors the
        //   D·NOTE path, where `onConnected` already closes this sheet.
        .sheet(item: $openedRecorder) { recorder in
            RecorderSheet(recorder: recorder, mode: .deviceInfo, onFinish: {
                openedRecorder = nil
                dismiss()
            })
        }
        .onAppear {
            // Scanning starts only once a family is picked — the pick page
            // itself must not burn radio time for a type the user doesn't want.
            if category != nil { bluetooth.startScan() }
        }
        .onDisappear {
            bluetooth.stopScan()
        }
    }

    // MARK: - Category pick page

    private var categoryGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.Scanner.pickHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(AddCategory.allCases) { cat in
                        Button {
                            pick(cat)
                        } label: {
                            CategoryCard(icon: cat.icon, title: cat.title, subtitle: cat.subtitle)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        showPlaudAdd = true
                    } label: {
                        CategoryCard(
                            icon: "waveform",
                            title: L10n.Scanner.categoryPlaud,
                            subtitle: L10n.Scanner.actionSDK
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 10)
        }
    }

    private func pick(_ cat: AddCategory) {
        switch cat {
        case .appleWatch:
            showWatchGuide = true
        default:
            category = cat
            connectError = nil
            bluetooth.startScan()
        }
    }

    // MARK: - Scan (filtered by the picked category)

    /// D·NOTE units matching the picked family (only the `.vobot` family scans them).
    private var filteredAvailable: [DiscoveredPeripheral] {
        category == .vobot ? newAvailable : []
    }

    /// Recorder cards matching the picked family.
    private var filteredRecorders: [DiscoveredRecorder] {
        switch category {
        case .ticnote: return newRecorders.filter { $0.protocolID == "ticnote" }
        case .dingtalkA1: return newRecorders.filter { $0.protocolID == "dingtalk-a1" }
        case .soundcore: return newRecorders.filter { $0.protocolID == SoundcoreRecorderSpec.identifier }
        default: return []
        }
    }

    @ViewBuilder
    private var scanContent: some View {
        if let message = bluetooth.adapter.userMessage {
            EmptyStateView(
                L10n.Scanner.bluetoothUnavailable,
                systemImage: "wifi.slash",
                message: message
            )
        } else if filteredAvailable.isEmpty && filteredRecorders.isEmpty {
            // ★ 2026-10-20: the emptiness is judged on the **filtered** lists — when only
            // already-added devices are nearby the list would otherwise render as an empty
            // shell. The two messages distinguish "radio quiet" from "everything seen is
            // already added" so the screen never looks like a hung scan.
            if sortedDiscovered.isEmpty && bluetooth.discoveredRecorders.isEmpty {
                EmptyStateView(
                    L10n.Scanner.lookingForDevices,
                    systemImage: "antenna.radiowaves.left.and.right",
                    message: L10n.Scanner.lookingMessage
                )
            } else {
                EmptyStateView(
                    L10n.Scanner.noNewInCategory(category?.title ?? ""),
                    systemImage: "checkmark.seal",
                    message: L10n.Scanner.lookingMessage
                )
            }
        } else {
            List {
                if !filteredAvailable.isEmpty {
                    Section(L10n.Scanner.sectionAvailable) {
                        ForEach(filteredAvailable) { row($0) }
                    }
                }
                if !filteredRecorders.isEmpty {
                    Section("Recorders") {
                        ForEach(filteredRecorders) { recorderRow($0) }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var sortedRecorders: [DiscoveredRecorder] {
        bluetooth.discoveredRecorders.sorted(by: { $0.identityHex < $1.identityHex })
    }

    /// Recording cards that are **not** in the device ledger yet.
    private var newRecorders: [DiscoveredRecorder] {
        sortedRecorders.filter { !isRecorderAdded($0) }
    }

    /// A recorder counts as added when its peripheral UUID is in the ledger — the same
    /// key `connectRecorder` writes via `rememberDevice` (comment there for why the
    /// peripheral UUID, not the SN, is the ledger key).
    private func isRecorderAdded(_ recorder: DiscoveredRecorder) -> Bool {
        configService.config.devices[recorder.id.uuidString] != nil
    }

    @ViewBuilder
    private func recorderRow(_ recorder: DiscoveredRecorder) -> some View {
        Button { connectRecorder(recorder) } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    // ★ 2026-10-12 Remove the “Beta” badge (user quote: *"In the device scanning, delete
                    //   the Beta after scanning Ticnote"*). It originally came from `RecorderExposure.beta`
                    //   — “No real-device usage record” metadata. Now this card has passed the read path,
                    //   used daily on real devices; adding an orange experimental label in the list would only make people think it is unreliable.
                    //   `RecorderExposure` itself **remains** (the registry still uses it to determine visibility),
                    //   Only the UI no longer consumes its “tagging” part.
                    Text(recorder.displayName)
                        .font(.body.weight(.medium))
                    Text(recorder.modelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(recorder.detailLine)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if connectingRecorder?.id == recorder.id {
                    ProgressView()
                } else {
                    VStack(alignment: .trailing, spacing: 4) {
                        RSSIBars(rssi: recorder.rssi)
                        Text("\(recorder.rssi) dBm")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(connectingRecorder != nil || connecting != nil)
    }

    /// The recording card's "connection": connect first, then enter its recording page.
    ///
    /// ★ Round 17: On successful connection **it** writes `configService.rememberDevice` (with `isRecorder` flag).
    /// An earlier version deliberately omitted it, reasoning that “D·NOTE ledger uses deviceSID as the key, while the recording card’s identity is SN,”
    /// putting them in the same table might dirty it — as a result, after users connect a TicNote, it **never appears in the “Device” list**,
    /// This is the root cause of “cannot add to device”. Now they go into the same table, but with an `is_recorder` flag
    /// to separate two sets of semantics (reconnection/battery/binding are exclusive to DnoteClient, recording cards are bypassed).
    /// Key uses CBPeripheral UUID: the same hardware on the same iPhone has a stable UUID,
    /// the same stability as D·NOTE legacy records; after changing phones, “scan once and reconnect” serves as a fallback.
    private func connectRecorder(_ recorder: DiscoveredRecorder) {
        bluetooth.stopScan()
        connectingRecorder = recorder
        Task {
            do {
                _ = try await bluetooth.connectRecorder(recorder)
                connectingRecorder = nil
                configService.rememberDevice(
                    id: recorder.id.uuidString,
                    name: recorder.displayName,
                    isRecorder: true
                )
                openedRecorder = recorder
            } catch {
                connectingRecorder = nil
                // Timeouts should provide an **actionable** prompt, not a dry "timed out".
                // TicNote-type cards broadcast in power-saving mode (measured intervals up to 152 seconds),
                // connection requests will wait for the next broadcast — having the user briefly press the record button to wake it is the fastest solution,
                // so reuse the existing wake prompt (`scanner.wake_and_retry`).
                if let linkError = error as? RecorderLinkError, linkError.kind == "timeout" {
                    connectError = L10n.Scanner.wakeAndRetry
                } else {
                    connectError = error.localizedDescription
                }
            }
        }
    }

    /// Stable order by SID, NOT live RSSI. Duplicate advertisements refresh
    /// each row's RSSI continuously, and an RSSI-sorted list re-orders under
    /// the user's finger, so a tap lands on whichever row swapped in — the
    /// "needs 2-3 taps" bug. RSSI is still shown per row, just not used to
    /// sort. (deviceSIDHex is stable for a given device.)
    private var sortedDiscovered: [DiscoveredPeripheral] {
        bluetooth.discovered.sorted(by: { $0.deviceSIDHex < $1.deviceSIDHex })
    }

    private func isAdded(_ peripheral: DiscoveredPeripheral) -> Bool {
        configService.config.devices[peripheral.id.uuidString] != nil
    }

    /// ★ 2026-10-20: only **new** D·NOTE units are listed; added ones are hidden from the
    /// scan list entirely (see the section comment in `content`).
    private var newAvailable: [DiscoveredPeripheral] {
        sortedDiscovered.filter { !isAdded($0) }
    }

    @ViewBuilder
    private func row(_ peripheral: DiscoveredPeripheral, isAdded: Bool = false) -> some View {
        Button { connect(peripheral) } label: {
            ScannerRow(
                peripheral: peripheral,
                isConnecting: connecting?.id == peripheral.id,
                isAdded: isAdded
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(connecting != nil)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { connectError != nil },
            set: { if !$0 { connectError = nil } }
        )
    }

    private func connect(_ peripheral: DiscoveredPeripheral) {
        // Freeze the discovery list as soon as the finger lands. Duplicate
        // advertisements keep mutating rows while scanning; leaving that
        // stream active through the tap was enough to swallow the first tap
        // even after the list changed to stable SID ordering.
        bluetooth.stopScan()
        connecting = peripheral
        Task {
            do {
                let client = try await bluetooth.connect(peripheral)
                configService.rememberDevice(
                    id: peripheral.id.uuidString,
                    name: peripheral.name,
                    deviceSID: peripheral.deviceSIDHex
                )
                // Best-effort warm-up: populate the device-info card so the
                // hero shows real values before the user opens the Device sheet.
                _ = try? await client.getDeviceInfo()
                _ = try? await client.getSwitchInfo()
                try? await client.syncTime()
                connecting = nil
                onConnected()
            } catch {
                connecting = nil
                connectError = error.localizedDescription
            }
        }
    }
}

/// One pickable family card on the category grid.
private struct CategoryCard: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(Color.appAccent)
                .frame(height: 36)
            VStack(spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Apple Watch "add" = installing the watch app from iOS. Recordings made on
/// the wrist sync into the library automatically (watch transport).
struct WatchAddGuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(L10n.WatchAdd.step1, systemImage: "1.circle")
                    Label(L10n.WatchAdd.step2, systemImage: "2.circle")
                    Label(L10n.WatchAdd.step3, systemImage: "3.circle")
                } header: {
                    Text(L10n.WatchAdd.title)
                } footer: {
                    Text(L10n.WatchAdd.note)
                }
            }
            .navigationTitle(L10n.Scanner.categoryWatch)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
    }
}

private struct ScannerRow: View {
    let peripheral: DiscoveredPeripheral
    let isConnecting: Bool
    var isAdded: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(peripheral.name)
                        .font(.body.weight(.medium))
                    if isAdded {
                        Text(L10n.Scanner.addedBadge)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(peripheral.product.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("SID \(peripheral.deviceSIDHex) · \(peripheral.firmwareString) · \(peripheral.battery)%")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isConnecting {
                ProgressView()
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    RSSIBars(rssi: peripheral.rssi)
                    Text("\(peripheral.rssi) dBm")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
