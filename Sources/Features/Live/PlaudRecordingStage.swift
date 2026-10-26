import SwiftUI

/// The PLAUD-style recording stage: a dark card that slides up when a take
/// starts and keeps the live transcript front and centre.
///
/// ## Why a separate stage instead of the 实时 tab
/// The official app treats recording as its own place: you press record, a
/// dark panel takes over, the clock and the words are the only things on
/// screen, and stopping drops you back. The 实时 tab was doing that job with a
/// header, a toolbar and a grouped background — fine as a page, wrong as a
/// stage. This view is that stage: one card, one clock, one transcript, three
/// controls.
///
/// ## What it reads from
/// Everything is `PlaudDirectService` state — `isRecording` / `isPaused`,
/// `liveSegments` (finals) + `livePartial` (the in-flight hypothesis),
/// `liveLevel` (0–1 loudness) and the card's own clock via `elapsedText`. The
/// stage owns no audio logic, so it cannot drift from the recording it shows.
struct PlaudRecordingStage: View {
    @ObservedObject private var direct = PlaudDirectService.shared
    @Environment(\.dismiss) private var dismiss

    /// Fixed epoch anchor — `.now` would re-phase the timeline on every body
    /// evaluation and make the seconds stutter.
    private let tickAnchor = Date(timeIntervalSince1970: 0)

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                grabber
                topBar
                clock
                WaveStrip(level: direct.liveLevel, isActive: direct.isRecording && !direct.isPaused)
                    .frame(height: 44)
                    .padding(.top, 14)
                transcriptCard
                    .padding(.top, 18)
                controls
                    .padding(.top, 18)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    private var backdrop: some View {
        LinearGradient(
            colors: [Color(red: 0.07, green: 0.07, blue: 0.09),
                     Color(red: 0.11, green: 0.11, blue: 0.14)],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .top) {
            // A soft glow behind the clock gives the card depth without a
            // second colour the brand has to approve.
            RadialGradient(colors: [Color.appAccent.opacity(0.22), .clear],
                           center: .top, startRadius: 8, endRadius: 320)
                .frame(height: 340)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private var grabber: some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 36, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 10)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(direct.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 5) {
                    Circle()
                        .fill(direct.phase.isConnected ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                    Text(direct.phase.isConnected ? L10n.Plaud.stateConnected : L10n.Plaud.stateDisconnected)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer()
            if let battery = direct.battery, direct.phase.isConnected {
                HStack(spacing: 4) {
                    Image(systemName: direct.isCharging ? "battery.100percent.bolt" : "battery.75percent")
                    Text("\(battery)%")
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
            }
            Button {
                direct.showRecordingStage = false
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Plaud.liveCollapse)
        }
    }

    // MARK: - Clock

    private var clock: some View {
        VStack(spacing: 8) {
            TimelineView(.periodic(from: tickAnchor, by: 1)) { context in
                Text(PlaudCardFilesView.elapsedText(direct, at: context.date))
                    .font(.system(size: 58, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(direct.isPaused ? Color.white.opacity(0.45) : .white)
            }
            HStack(spacing: 8) {
                if direct.isPaused {
                    Label(L10n.Plaud.pausedHint, systemImage: "pause.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                } else {
                    PulsingDot()
                    Text(L10n.Plaud.liveBadge)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.red)
                }
                if !direct.liveASRProvider.isEmpty {
                    Text(L10n.Plaud.liveEngine(direct.liveASRProvider))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Transcript

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.appAccent)
                Text(L10n.Plaud.liveTranscript)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                if direct.liveMarkCount > 0 {
                    Label("\(direct.liveMarkCount)", systemImage: "bookmark.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            transcriptScroll
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }

    private let bottomID = "stage-bottom"

    /// Lines and marks in one time-ordered list — the same merge the shared
    /// `PlaudLiveTranscriptList` does, kept local because the stage draws its
    /// own dark lines. ★ 2026-10-26: marks (card key **and** the in-app button)
    /// must appear in the live transcript while it is running, not only after
    /// the take is saved.
    private enum StageRow: Identifiable {
        case line(PlaudLiveSegment)
        case mark(TimeInterval)

        var id: String {
            switch self {
            case .line(let segment): return segment.id.uuidString
            case .mark(let at): return "mark-\(at)"
            }
        }

        var at: TimeInterval {
            switch self {
            case .line(let segment): return segment.at
            case .mark(let at): return at
            }
        }
    }

    private var stageRows: [StageRow] {
        var items = direct.liveSegmentsVisible.map(StageRow.line)
        items += direct.liveMarkers.filter { $0 > 0 }.map(StageRow.mark)
        return items.sorted { $0.at < $1.at }
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    // ★ 2026-10-26: the *visible* transcript (see
                    // `liveSegmentsVisible`) — the stage is a view onto the take
                    // that is running, and a finished take's words must not
                    // reappear on it.
                    if direct.liveSegmentsVisible.isEmpty && direct.livePartialVisible.isEmpty && direct.liveMarkers.isEmpty {
                        emptyState
                    }
                    ForEach(stageRows) { row in
                        switch row {
                        case .line(let segment):
                            line(stamp: PlaudLiveLine.stamp(segment.at), text: segment.text, partial: false)
                        case .mark(let at):
                            markRow(stamp: PlaudLiveLine.stamp(at))
                        }
                    }
                    if !direct.livePartialVisible.isEmpty {
                        line(stamp: PlaudLiveLine.stamp(direct.liveSegmentsVisible.last?.at ?? 0),
                             text: direct.livePartialVisible,
                             partial: true)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: direct.liveSegmentsVisible.count) { _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: direct.livePartialVisible) { _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: direct.liveMarkers.count) { _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    /// A bookmark pressed mid-take (card key or the in-app button), drawn in
    /// place between the lines — "打点也要有标记".
    private func markRow(stamp: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bookmark.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            Text(stamp)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.orange.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(stamp: String, text: String, partial: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(stamp)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.35))
            Text(text)
                .font(.system(size: 17, weight: partial ? .regular : .medium))
                .foregroundStyle(partial ? Color.appAccent.opacity(0.85) : .white.opacity(0.94))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.6))
                Text(direct.isRecording ? L10n.Plaud.liveWaiting : L10n.Plaud.liveIdle)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            if let notice = direct.liveASRNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.85))
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 22) {
                // ★ 2026-10-26 (user: "打标记需要也在实时转录的时候生效"):
                // the app's own bookmark — same channel as the card's key, so
                // the marker line appears in the live transcript immediately.
                Button {
                    direct.addLiveMark()
                } label: {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Color.white.opacity(0.13)))
                }
                .buttonStyle(.plain)
                .disabled(!direct.isRecording && !direct.isPaused)
                .accessibilityLabel(L10n.Plaud.liveAddMark)

                // Pause / resume — a pause keeps the take (and its words) alive.
                Button {
                    if direct.isPaused { direct.resumeRecording() } else { direct.pauseRecording() }
                } label: {
                    Image(systemName: direct.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 62, height: 62)
                        .background(Circle().fill(Color.white.opacity(0.13)))
                }
                .buttonStyle(.plain)
                .disabled(!direct.isRecording && !direct.isPaused)

                Button {
                    direct.stopRecording()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(Circle().fill(Color.red))
                        .shadow(color: Color.red.opacity(0.45), radius: 18)
                }
                .buttonStyle(.plain)
                .disabled(!direct.isRecording && !direct.isPaused)
            }
            if direct.recordSegmentCount > 1 {
                Text(L10n.Plaud.segmentHint(direct.recordSegmentCount))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            } else if let notice = direct.recordNotice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.9))
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// MARK: - Pieces

/// Scrolling loudness bars. A rolling window of samples reads as "live" in a
/// way a single pulsing bar does not, and it needs no audio work — the samples
/// are just `liveLevel` polled on a timer.
private struct WaveStrip: View {
    let level: Double
    let isActive: Bool

    @State private var samples: [Double] = Array(repeating: 0.06, count: 40)
    private let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, value in
                Capsule()
                    .fill(Color.appAccent.opacity(0.35 + 0.65 * value))
                    .frame(width: 3, height: max(3, value * 40))
                    .frame(maxHeight: .infinity, alignment: .center)
                    .opacity(index >= samples.count - 14 ? 1 : 0.55)
            }
        }
        .animation(.easeOut(duration: 0.12), value: samples)
        .onReceive(timer) { _ in push() }
    }

    private func push() {
        guard isActive else {
            samples = samples.map { $0 * 0.85 }
            return
        }
        let jitter = Double.random(in: 0.55...1.15)
        let value = min(1, max(0.05, level * jitter + Double.random(in: 0...0.06)))
        samples.removeFirst()
        samples.append(value)
    }
}

private struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 6, height: 6)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}
