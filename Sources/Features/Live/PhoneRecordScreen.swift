import SwiftUI

/// Phone-microphone recording screen with live captions (★ 2026-10-22, 任务一).
///
/// Lives in the bottom「实时」tab next to the device paths (Plaud card / A1 /
/// D·NOTE). Design follows Plaud's record card: big clock, level bars, one
/// record button, and a **caption area** that shows the last committed
/// sentences with the in-flight hypothesis in grey — the full transcript is
/// right there scrolling, because hiding history behind a 3-line window was
/// exactly the "跟不上/看不到" complaint that build 98 fixed for the card.
///
/// Save path on stop: the WAV goes straight into the library (`transport:
/// "stream"` → `ClipSource.Kind.phone` badge), the live caption text is
/// written as the clip's transcript (`{name}.txt` + minimal `.asr.json`), and
/// the normal auto-transcribe / auto-summarize chain takes over from there.
struct PhoneRecordScreen: View {
    @EnvironmentObject private var env: AppEnvironment
    @StateObject private var recorder = PhoneMicRecorder()
    @StateObject private var captions = LiveCaptionController()
    @State private var savedName: String?
    /// ★ 2026-10-26: set when the user came here **from a card's live screen**
    /// (the mic button on `PlaudLiveScreen`). Non-nil → a "back to card" button
    /// renders in the header; without it there was no way back while a card was
    /// paired, which is how the phone mic felt like a trap.
    var onExit: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let err = recorder.error {
                errorBanner(err)
            }
            captionBody
            Divider()
            controlBar
        }
        .onChange(of: recorder.isRunning) { running in
            UIApplication.shared.isIdleTimerDisabled = running
            if running { env.isStreaming = true } else { env.isStreaming = false }
        }
        .onDisappear {
            if recorder.isRunning {
                finishRecording()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            if let onExit {
                HStack {
                    Button(action: onExit) {
                        Label(L10n.Live.backToCard, systemImage: "chevron.left")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            Text(clockText)
                .font(.system(size: 44, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(.linear(duration: 0.2), value: clockText)

            HStack(spacing: 8) {
                Circle()
                    .fill(recorder.isRunning ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(recorder.isRunning ? L10n.Live.streaming : L10n.Phone.idle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !captions.providerName.isEmpty {
                    Text(captions.providerName.capitalized)
                        .font(.caption2.bold())
                        .foregroundColor(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                }
            }

            PhoneLevelBar(level: recorder.isRunning ? recorder.level : 0)
                .frame(height: 26)
                .padding(.horizontal, 48)

            if recorder.isRunning, let notice = captions.notice {
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var clockText: String {
        let total = max(0, Int(recorder.elapsed))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    // MARK: - Caption body

    @ViewBuilder
    private var captionBody: some View {
        if !captions.hasText {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "captions.bubble")
                    .font(.system(size: 36))
                    .foregroundStyle(.quaternary)
                Text(captionPlaceholder)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(captions.segments.enumerated()), id: \.element.id) { _, seg in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(PlaudClock.text(seg.at))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(minWidth: 42, alignment: .leading)
                                Text(seg.text)
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(seg.id)
                        }
                        if !captions.partial.isEmpty {
                            Text(captions.partial)
                                .font(.body)
                                .italic()
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("phonePartial")
                        }
                    }
                    .padding()
                }
                .onChange(of: captions.segments.count) { _ in
                    withAnimation { proxy.scrollTo(lastAnchor, anchor: .bottom) }
                }
                .onChange(of: captions.partial) { _ in
                    withAnimation { proxy.scrollTo("phonePartial", anchor: .bottom) }
                }
            }
        }
    }

    private var lastAnchor: some Hashable { captions.segments.last?.id ?? UUID() }

    private var captionPlaceholder: String {
        if recorder.isRunning {
            // Honest states instead of a blank area (weak-network placeholder
            // is the notice the engine already publishes).
            return captions.notice ?? L10n.Phone.listening
        }
        return L10n.Phone.idleCaption
    }

    // MARK: - Control bar

    private var controlBar: some View {
        VStack(spacing: 10) {
            Button {
                recorder.isRunning ? finishRecording() : startRecording()
            } label: {
                ZStack {
                    Circle()
                        .fill(recorder.isRunning ? Color.red : Color.accentColor)
                        .frame(width: 72, height: 72)
                    Image(systemName: recorder.isRunning ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(recorder.isRunning ? L10n.Phone.stop : L10n.Phone.record)

            if let name = savedName {
                Label(L10n.Live.savedToLibrary, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onTapGesture { savedName = name } // keep the row visible; no-op tap
            }
        }
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private func startRecording() {
        savedName = nil
        captions.reset()
        captions.start(config: env.config.config)
        recorder.pcmSink = { [weak captions] pcm, elapsed in
            captions?.append(pcm, elapsed: elapsed)
        }
        do {
            try recorder.start()
        } catch {
            recorder.error = error.localizedDescription
        }
    }

    private func finishRecording() {
        guard let url = recorder.stop() else {
            captions.stop()
            return
        }
        captions.stop()
        let name = url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        env.library.recordDownload(name: name, size: size, transport: "stream")
        savedName = name
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)

        // Persist the live captions as this clip's transcript so the detail
        // page has text immediately (acceptance: "字幕文本可直接用于转写比对").
        if captions.hasText {
            saveTranscript(clipName: name)
            Task { @MainActor in
                AppEnvironment.shared?.maybeAutoSummarize(clipName: name)
            }
        } else if env.config.config.autoTranscribeAfterDownload {
            Task { @MainActor in
                await env.autoTranscribeAfterImport(fileURL: url)
            }
        }
    }

    /// `{name}.txt` + minimal `{name}.asr.json`, same shapes the device paths write.
    private func saveTranscript(clipName: String) {
        let urls = StorageLocations.transcriptURLs(for: clipName)
        let segments = captions.segments
        let text = captions.joinedText()
        do {
            try text.data(using: .utf8)?.write(to: urls.txt, options: .atomic)
            let asr = AsrResult(
                text: text,
                segments: segments.map {
                    AsrSegment(speaker: nil, text: $0.text,
                               start: $0.at, end: $0.at,
                               duration: 0)
                },
                provider: "live-captions",
                locale: env.config.config.lastSourceLang ?? "en"
            )
            try JSONEncoder().encode(asr).write(to: urls.json, options: .atomic)
        } catch {
            TicNoteDiagLog.log("PHONE-CAPTION", "transcript save failed: \(error.localizedDescription)")
        }
    }
}

/// Slim level bar for the phone screen (the card page's `LevelBars` is
/// history-driven; here one live RMS value is enough).
private struct PhoneLevelBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.15))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(8, geo.size.width * level))
                    .animation(.easeOut(duration: 0.12), value: level)
            }
        }
    }
}
