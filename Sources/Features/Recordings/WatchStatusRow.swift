import SwiftUI

/// "Your watch is recording" strip on the Recordings tab.
///
/// Every value here was pushed from the wrist — the phone never asks, because
/// it can't: WatchConnectivity gives the watch a way to wake this app but
/// offers nothing for the reverse. What makes a push-only status trustworthy is
/// the 10 s heartbeat behind it. Once three beats have been missed the row
/// stops showing a running clock and says the watch is out of range instead.
///
/// It deliberately doesn't disappear when that happens: a watch out of
/// Bluetooth range goes on recording perfectly well, and the clip will arrive
/// later, so hiding the row would be a worse lie than the frozen timer it
/// replaces.
struct WatchStatusRow: View {
    @EnvironmentObject private var watch: WatchSyncService

    /// Three missed beats plus slack.
    private static let staleAfter: TimeInterval = 35

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isStale: Bool {
        guard let last = watch.lastWatchHeartbeat else { return false }
        return now.timeIntervalSince(last) > Self.staleAfter
    }

    var body: some View {
        if watch.isWatchRecording || watch.isWatchTransferring {
            HStack(spacing: 8) {
                Image(systemName: "applewatch")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if watch.isWatchRecording {
                    if !isStale {
                        Circle()
                            .fill(.red)
                            .frame(width: 7, height: 7)
                    }
                    Text(L10n.Watch.statusRecording)
                        .font(.footnote.weight(.medium))
                    Spacer()
                    Text(trailingText)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini)
                    Text(L10n.Watch.statusTransferring)
                        .font(.footnote.weight(.medium))
                    Spacer()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 7)
            .background(Color(uiColor: .secondarySystemBackground))
            .onReceive(tick) { now = $0 }
        }
    }

    private var trailingText: String {
        guard !isStale else { return L10n.Watch.statusOutOfRange }
        guard let since = watch.watchRecordingSince else { return "" }
        return Self.duration(now.timeIntervalSince(since))
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}
