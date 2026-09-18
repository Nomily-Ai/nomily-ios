import SwiftUI

struct KnownDevice: Identifiable {
    let id: String
    let name: String
}

/// Persistent top-left chrome. Three modes:
///  1. No known devices → "Add Device" onboarding CTA
///  2. Known device(s) → split pill: left tap → DeviceSheet, right tap → device picker menu
///  3. BT unavailable → orange warning
struct ConnectionPill: View {
    let client: DnoteClient?
    let adapter: BluetoothCoordinator.AdapterState
    let knownDevices: [KnownDevice]
    let isReconnecting: Bool
    let onTapDevice: () -> Void
    let onAddDevice: () -> Void
    let onSelectDevice: (String) -> Void

    private var isConnected: Bool { client != nil }

    private var activeName: String {
        if let client { return client.displayName }
        return knownDevices.first?.name ?? "DNOTE"
    }

    var body: some View {
        if knownDevices.isEmpty {
            if adapter != .poweredOn, let msg = adapter.userMessage {
                warningPill(msg)
            } else {
                addDevicePill
            }
        } else {
            splitPill
        }
    }

    // MARK: - onboarding

    private var addDevicePill: some View {
        Button(action: onAddDevice) {
            pillChrome {
                Image(systemName: "plus.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(L10n.Pill.addDevice)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - BT warning

    private func warningPill(_ message: String) -> some View {
        Button(action: onAddDevice) {
            pillChrome {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - split pill (left = device tap, right = picker menu)

    private var splitPill: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if isReconnecting {
                    ProgressView().controlSize(.mini)
                }

                Text(activeName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .foregroundColor(isConnected ? .primary : .secondary)

                if let client, let battery = client.lastDeviceInfo?.battery {
                    Text("\(battery)%")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundColor(.secondary)
                }

                if client?.lastDeviceInfo?.isRecording == true {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle().stroke(.red.opacity(0.4), lineWidth: 4)
                                .scaleEffect(1.4)
                        )
                        .accessibilityLabel(L10n.Common.recording)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTapDevice)

            Rectangle()
                .fill(Color(.separator))
                .frame(width: 0.5)
                .padding(.vertical, 5)

            Menu {
                ForEach(knownDevices) { device in
                    Button { onSelectDevice(device.id) } label: {
                        Label {
                            Text(device.name)
                        } icon: {
                            if client?.peripheral.identifier.uuidString == device.id {
                                Image(systemName: "checkmark.circle.fill")
                            } else {
                                Image(systemName: "circle")
                            }
                        }
                    }
                }
                Divider()
                Button(action: onAddDevice) {
                    Label(L10n.Pill.addDevice, systemImage: "plus")
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
                    .padding(.trailing, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
        }
        .fixedSize()
        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
    }

    // MARK: - shared chrome

    private func pillChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
    }
}
