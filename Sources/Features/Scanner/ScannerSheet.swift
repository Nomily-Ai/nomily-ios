import SwiftUI

struct ScannerSheet: View {
    @EnvironmentObject private var bluetooth: BluetoothCoordinator
    @EnvironmentObject private var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    let onConnected: () -> Void

    @State private var connecting: DiscoveredPeripheral?
    @State private var connectError: String?
    /// Recording cards that are currently connecting (non D·NOTE). Separate from `connecting` because after connecting it goes into
    /// another flow (`RecorderSheet`), not the D·NOTE device page.
    @State private var connectingRecorder: DiscoveredRecorder?
    @State private var openedRecorder: DiscoveredRecorder?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L10n.Scanner.scan)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(L10n.Common.done) { dismiss() }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        if bluetooth.isScanning {
                            ProgressView()
                        } else {
                            Button(L10n.Scanner.scanAgain) { bluetooth.startScan() }
                                .disabled(bluetooth.adapter != .poweredOn)
                        }
                    }
                }
                .alert(L10n.Scanner.connectionFailed, isPresented: errorBinding, actions: {
                    Button(L10n.Common.ok, role: .cancel) { connectError = nil }
                }, message: { Text(connectError ?? "") })
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
            bluetooth.startScan()
        }
        .onDisappear {
            bluetooth.stopScan()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let message = bluetooth.adapter.userMessage {
            EmptyStateView(
                L10n.Scanner.bluetoothUnavailable,
                systemImage: "wifi.slash",
                message: message
            )
        } else if newAvailable.isEmpty && newRecorders.isEmpty {
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
                    L10n.Scanner.noNewDevices,
                    systemImage: "checkmark.seal",
                    message: L10n.Scanner.lookingMessage
                )
            }
        } else {
            List {
                if !newAvailable.isEmpty {
                    Section(L10n.Scanner.sectionAvailable) {
                        ForEach(newAvailable) { row($0) }
                    }
                }
                // ★ 2026-10-20 (user: "已经添加的设备不要出现在扫描列表里面防止多次添加"):
                // added devices no longer render **anywhere** in the scan list — not as a
                // labelled section, not in the recorder section. The old "Added" section
                // existed as a reconnection fallback for D·NOTE, but tapping a known card
                // is exactly the "adds a second time" path the user wants closed; the
                // device list on the home page is the single management entry now.
                // (`rememberDevice` still overwrites by peripheral ID, so a re-add can
                // never actually duplicate a ledger entry.)
                if !newRecorders.isEmpty {
                    Section("Recorders") {
                        ForEach(newRecorders) { recorderRow($0) }
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
