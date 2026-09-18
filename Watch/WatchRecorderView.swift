import SwiftUI

/// Wrist recorder page: one big button, the running duration, and whatever is
/// still waiting to reach the iPhone.
struct WatchRecorderView: View {
    @EnvironmentObject private var model: WatchRecorderModel
    /// Transfer state is read straight off the link rather than snapshotted
    /// into `PendingClip`, so a queue that drains (or a transfer that fails)
    /// re-renders the row without the model having to notice.
    @EnvironmentObject private var link: WatchLink

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                status
                recordButton
                if !model.pending.isEmpty { pendingList }
                versionLink
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle(L10n.Watch.recorderTitle)
        .alert(
            L10n.Watch.recorderTitle,
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button(L10n.Common.ok) { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    private var status: some View {
        VStack(spacing: 3) {
            Text(model.isRecording ? WatchFormat.duration(model.elapsed) : L10n.Watch.ready)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
            if model.isRecording {
                Text(WatchFormat.bytes(model.currentBytes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordButton: some View {
        Button(action: model.toggleRecording) {
            Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                .font(.title2)
                .frame(maxWidth: .infinity, minHeight: 46)
                .foregroundStyle(.white)
                .background(model.isRecording ? Color.gray : Color.red, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isRecording ? L10n.Watch.stop : L10n.Watch.record)
    }

    private var versionLink: some View {
        NavigationLink {
            WatchAboutView()
        } label: {
            Text(L10n.Settings.version)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private var pendingList: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.Watch.pendingHeader)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.pending) { clip in
                // Queued or delivered-but-unconfirmed both read as "in flight";
                // only a clip with neither state needs the retry affordance.
                let isQueued = link.queuedNames.contains(clip.name)
                    || link.deliveredNames.contains(clip.name)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(clip.displayTitle)
                                .font(.caption2)
                                .lineLimit(1)
                            Text("\(isQueued ? L10n.Watch.sending : L10n.Watch.waiting) · \(WatchFormat.bytes(clip.bytes))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !isQueued {
                            Button { model.retry(clip) } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.Common.retry)
                        }
                        Button(role: .destructive) { model.delete(clip) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.Common.delete)
                    }
                    Divider()
                }
            }
        }
    }
}

enum WatchFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
