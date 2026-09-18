import SwiftUI

struct ScannerSheet: View {
    @EnvironmentObject private var bluetooth: BluetoothCoordinator
    @EnvironmentObject private var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    let onConnected: () -> Void

    @State private var connecting: DiscoveredPeripheral?
    @State private var connectError: String?

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
        } else if bluetooth.discovered.isEmpty {
            EmptyStateView(
                L10n.Scanner.lookingForDevices,
                systemImage: "antenna.radiowaves.left.and.right",
                message: L10n.Scanner.lookingMessage
            )
        } else {
            List {
                if !available.isEmpty {
                    Section(L10n.Scanner.sectionAvailable) {
                        ForEach(available) { row($0) }
                    }
                }
                // Already‑added devices are listed as a separate section with a label, so users can distinguish new devices.
                // Do not hide the whole section: when `connectKnown` fails, the scan list is the only reconnection entry point.
                // Tapping it will not add duplicates — `rememberDevice` overwrites the same record based on peripheral ID.
                if !alreadyAdded.isEmpty {
                    Section(L10n.Scanner.sectionAdded) {
                        ForEach(alreadyAdded) { row($0, isAdded: true) }
                    }
                }
            }
            .listStyle(.insetGrouped)
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

    private var available: [DiscoveredPeripheral] { sortedDiscovered.filter { !isAdded($0) } }
    private var alreadyAdded: [DiscoveredPeripheral] { sortedDiscovered.filter { isAdded($0) } }

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
