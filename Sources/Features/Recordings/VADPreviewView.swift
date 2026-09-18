import SwiftUI

/// Debug preview that runs `LocalVAD.analyze` on a clip and renders
/// the RMS waveform with detected speech regions highlighted. Lets
/// you live-tune the threshold multiplier and hangover to feel out
/// whether the VAD heuristic is picking the right regions before we
/// promote those knobs into the user-facing Settings.
struct VADPreviewView: View {
    let item: LibraryItem
    @Environment(\.dismiss) private var dismiss

    @State private var thresholdMultiplier: Double = LocalVAD.defaultThresholdMultiplier
    @State private var hangoverSec: Double = LocalVAD.defaultHangoverSec
    @State private var report: VADReport?
    @State private var analyzing = false
    @State private var errorMessage: String?
    @State private var reanalyzeTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    waveformCard
                    thresholdsCard
                    tuningCard
                }
                .padding()
            }
            .navigationTitle("VAD Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await scheduleReanalyze(immediate: true) }
            .onChange(of: thresholdMultiplier) { _ in
                Task { await scheduleReanalyze(immediate: false) }
            }
            .onChange(of: hangoverSec) { _ in
                Task { await scheduleReanalyze(immediate: false) }
            }
            // Closing the page stops the decoding — `scheduleReanalyze` launches a detached Task,
            // unlike `.task` which automatically cancels with the view lifecycle.
            .onDisappear { reanalyzeTask?.cancel() }
        }
    }

    // MARK: - Sections

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.displayTitle)
                .font(.headline)
                .lineLimit(2)
            Text(item.name)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var waveformCard: some View {
        if let report {
            VStack(alignment: .leading, spacing: 8) {
                // There should be visual feedback during recomputation: if only the report is drawn, after dragging the slider the UI shows no indication for those dozens of seconds,
                // (the old waveform remains, giving no clue that recomputation is happening).
                if analyzing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                statsRow(report)
                VADWaveform(report: report)
                    .frame(height: 160)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                legend
            }
        } else if analyzing {
            ProgressView("Analyzing…")
                .frame(maxWidth: .infinity, minHeight: 160)
        } else if let errorMessage {
            Text(errorMessage)
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendDot(.blue.opacity(0.6), "RMS")
            legendDot(.green.opacity(0.25), "Speech")
            legendDash(.red, "Threshold")
            legendDash(.gray, "Noise floor")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    private func legendDash(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Rectangle().fill(color).frame(width: 12, height: 1)
            Text(label)
        }
    }

    @ViewBuilder
    private var thresholdsCard: some View {
        if let report {
            GroupBox("Detection") {
                VStack(alignment: .leading, spacing: 4) {
                    kv("Noise floor", String(format: "%.0f RMS", report.noiseFloor))
                    kv("Threshold", String(format: "%.0f RMS (× %.2f)",
                                           report.threshold, report.thresholdMultiplier))
                    kv("Speech regions", "\(report.ranges.count)")
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tuningCard: some View {
        GroupBox("Tuning") {
            VStack(alignment: .leading, spacing: 12) {
                sliderRow(
                    label: "Threshold × noise floor",
                    value: $thresholdMultiplier,
                    range: 1.0...10.0, step: 0.25,
                    display: String(format: "%.2f", thresholdMultiplier)
                )
                sliderRow(
                    label: "Hangover",
                    value: $hangoverSec,
                    range: 0.0...1.0, step: 0.05,
                    display: String(format: "%.2f s", hangoverSec)
                )
                Button("Reset to defaults") {
                    thresholdMultiplier = LocalVAD.defaultThresholdMultiplier
                    hangoverSec = LocalVAD.defaultHangoverSec
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private func statsRow(_ r: VADReport) -> some View {
        let savedPct = r.totalDuration > 0
            ? (r.savedDuration / r.totalDuration) * 100
            : 0
        return HStack(alignment: .top, spacing: 16) {
            stat("Total", String(format: "%.1fs", r.totalDuration))
            stat("Speech", String(format: "%.1fs", r.speechDuration))
            stat("Saved", String(format: "%.1fs (%.0f%%)", r.savedDuration, savedPct))
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit())
        }
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).monospacedDigit()
        }
    }

    private func sliderRow(
        label: String, value: Binding<Double>,
        range: ClosedRange<Double>, step: Double, display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(display).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
        .font(.footnote)
    }

    /// Debounced re-analyze. Slider drags fire dozens of change
    /// events; we cancel any pending analyze and start a fresh one
    /// so only the settled value runs the expensive decode pass.
    private func scheduleReanalyze(immediate: Bool) async {
        reanalyzeTask?.cancel()
        let task = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
            }
            await runAnalyze()
        }
        reanalyzeTask = task
    }

    @MainActor
    private func runAnalyze() async {
        guard let source = item.url else { return }
        analyzing = true
        errorMessage = nil
        do {
            let r = try await LocalVAD.analyze(
                source: source,
                thresholdMultiplier: thresholdMultiplier,
                hangoverSec: hangoverSec
            )
            self.report = r
            analyzing = false
        } catch is CancellationError {
            // If the user drags the slider again or closes the page — not an error, no red alert;
            // also **do not** set `analyzing` back to false: the analysis that took over is still running,
            // turning off the spinner would make the UI appear stuck on a blank screen.
        } catch {
            self.errorMessage = "Couldn't analyze: \(error.localizedDescription)"
            analyzing = false
        }
    }
}

// MARK: - Waveform

private struct VADWaveform: View {
    let report: VADReport

    var body: some View {
        Canvas { ctx, size in
            guard !report.rms.isEmpty, report.totalDuration > 0 else { return }

            // Normalise RMS heights against the loudest bar or the
            // threshold, whichever is larger, so the threshold line
            // stays inside the frame on very quiet clips.
            let maxRMS = max(report.rms.max() ?? 1, report.threshold * 1.2, 1)

            // Speech regions: translucent green bands painted under
            // the bars so the bars overlay reveals *which* windows
            // crossed threshold vs. which ones were added by hangover.
            for r in report.ranges {
                let x0 = CGFloat(r.start / report.totalDuration) * size.width
                let x1 = CGFloat(r.end / report.totalDuration) * size.width
                let rect = CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height)
                ctx.fill(Path(rect), with: .color(.green.opacity(0.22)))
            }

            // RMS bars — **one pixel column per bar**, taking the maximum value within the interval for each column.
            // Previously it was one bar per window: 30 ms per window, so a 3‑hour recording produced 360 k bars,
            // resulting in 360 k fills per frame — impossible to render, causing device heating and top toolbar frame drops.
            // Using the maximum (instead of the average) preserves short speech peaks.
            let cols = max(Int(size.width), 1)
            let windows = report.rms.count
            for x in 0..<cols {
                let from = windows * x / cols
                let to = min(windows * (x + 1) / cols, windows)
                guard to > from else { continue }
                var peak = 0.0
                for i in from..<to { peak = max(peak, report.rms[i]) }
                let h = CGFloat(peak / maxRMS) * size.height
                let rect = CGRect(
                    x: CGFloat(x), y: size.height - h,
                    width: 1, height: max(h, 0.5)
                )
                ctx.fill(Path(rect), with: .color(.blue.opacity(0.65)))
            }

            // Threshold line (red dashed).
            let ty = size.height * (1 - CGFloat(report.threshold / maxRMS))
            var thrPath = Path()
            thrPath.move(to: CGPoint(x: 0, y: ty))
            thrPath.addLine(to: CGPoint(x: size.width, y: ty))
            ctx.stroke(
                thrPath, with: .color(.red),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )

            // Noise-floor line (gray dashed).
            let ny = size.height * (1 - CGFloat(report.noiseFloor / maxRMS))
            var floorPath = Path()
            floorPath.move(to: CGPoint(x: 0, y: ny))
            floorPath.addLine(to: CGPoint(x: size.width, y: ny))
            ctx.stroke(
                floorPath, with: .color(.gray),
                style: StrokeStyle(lineWidth: 1, dash: [2, 3])
            )
        }
    }
}
