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
                    if isStale {
                        // The wrist stopped beating: it is out of range or
                        // asleep. Claiming "transferring…" with a spinner here
                        // was the "一直卡在 Apple Watch 传输上" report.
                        Image(systemName: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Text(L10n.Watch.transferStalled)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.orange)
                    } else {
                        ProgressView().controlSize(.mini)
                        Text(L10n.Watch.statusTransferring)
                            .font(.footnote.weight(.medium))
                    }
                    Spacer()
                    // Elapsed seconds: a spinner with no number is
                    // indistinguishable from a frozen one.
                    Text(transferElapsed)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                // ★ 2026-10-21: a way out. The strip is driven by the wrist's
                // own queue; if that queue wedged, only this button can clear it.
                Button {
                    watch.dismissTransferNotice()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.Watch.hideTransferStatus)
            }
            .padding(.horizontal)
            .padding(.vertical, 7)
            .background(Color(uiColor: .secondarySystemBackground))
            .onReceive(tick) { now = $0 }
        } else if let notice = watch.watchTransferNotice {
            // The watchdog gave up (or the wrist went quiet): say so once, with
            // the same dismiss affordance, instead of dropping the row silently.
            HStack(spacing: 8) {
                Image(systemName: "applewatch.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    watch.dismissTransferNotice()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.Watch.hideTransferStatus)
            }
            .padding(.horizontal)
            .padding(.vertical, 7)
            .background(Color(uiColor: .secondarySystemBackground))
        }
    }

    /// "0:42" from the moment the wrist said a transfer was pending.
    private var transferElapsed: String {
        guard let since = watch.watchTransferSince else { return "" }
        let total = max(0, Int(now.timeIntervalSince(since)))
        return total >= 60
            ? String(format: "%d:%02d", total / 60, total % 60)
            : String(format: "%ds", total)
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
