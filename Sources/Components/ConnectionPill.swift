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
    let recorderLink: (any RecorderLink)?
    let recorderDeviceInfo: RecorderDeviceInfo?
    /// TicNote has no resolvable physical recording flag; this only shows the recording state of sessions started by the App.
    let recorderIsRecording: Bool
    let adapter: BluetoothCoordinator.AdapterState
    let knownDevices: [KnownDevice]
    let isReconnecting: Bool
    /// Progress of the recorder's **automatic reconnection**. `nil` = not reconnecting.
    ///
    /// Separated from `isReconnecting`: that one means "a connection initiated by a user tap is in progress",
    /// this one means "the link dropped and the App is reconnecting in the background". The latter can last several minutes
    /// (the card is asleep, waiting for its next broadcast), so it must be able to show **which attempt** this is,
    /// otherwise the user will think it's stuck — which is exactly why they keep tapping reconnect.
    let recorderReconnectState: BluetoothCoordinator.RecorderReconnectState?
    let onTapDevice: () -> Void
    let onAddDevice: () -> Void
    let onSelectDevice: (String) -> Void
    let onRemoveDevice: (KnownDevice) -> Void

    private var isConnected: Bool {
        client != nil || recorderLink?.isConnected == true
    }

    /// The spinning state: manual connecting, or auto-reconnecting.
    private var isBusy: Bool {
        isReconnecting || recorderReconnectState != nil
    }

    private var activeName: String {
        if let client { return client.displayName }
        if let recorderLink { return recorderLink.displayName }
        // After disconnection, `recorderLink` is already nil, so the name only comes from these sources — the reconnection
        // state carries one (fetched from the identity cache), which is more accurate than `knownDevices.first`.
        if let name = recorderReconnectState?.deviceName, !name.isEmpty { return name }
        return knownDevices.first?.name ?? "DNOTE"
    }

    /// The line of text shown on the pill. During reconnection, replaced with a progress message that includes the attempt count.
    private var connectionLabel: String {
        guard let state = recorderReconnectState else { return activeName }
        // The first attempt doesn't show a count ("attempt 1" sounds like something went wrong);
        // from the second attempt on, indicate it's "still trying" — that's when the user most needs evidence that "it's moving".
        return state.attempt <= 1
            ? L10n.TicNoteCard.reconnecting
            : L10n.TicNoteCard.reconnectingAttempt(state.attempt)
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
                if isBusy {
                    ProgressView().controlSize(.mini)
                }

                Text(connectionLabel)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .foregroundColor(isConnected ? .primary : .secondary)

                if client?.lastDeviceInfo?.isRecording == true ||
                    (recorderLink?.isConnected == true && recorderIsRecording) {
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
                            if client?.peripheral.identifier.uuidString == device.id ||
                                recorderLink?.peripheral.identifier.uuidString == device.id {
                                Image(systemName: "checkmark.circle.fill")
                            } else {
                                Image(systemName: "circle")
                            }
                        }
                    }
                }
                Divider()
                Menu {
                    ForEach(knownDevices) { device in
                        Button(role: .destructive) { onRemoveDevice(device) } label: {
                            Label("Remove \(device.name)", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("Remove device", systemImage: "trash")
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
