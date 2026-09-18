import SwiftUI

struct ClipDetailView: View {
    let item: LibraryItem
    var onChanged: () -> Void = {}

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var transcription: TranscriptionService
    @EnvironmentObject private var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AudioPlaybackController()
    @StateObject private var languages = LanguageService()
    @State private var transcript: TranscriptDocument?
    @State private var transcribeState: TranscribeUIState = .idle
    @State private var deleteAudioAlert = false
    @State private var deleteTranscriptAlert = false
    @State private var deleteSummaryAlert = false
    @State private var summary: String?
    @State private var showSummarize = false
    @State private var showNoProvider = false
    @State private var showNoASR = false
    @State private var showPlayer = false
    @State private var retranscribeAlert = false
    @State private var translation: String?
    @State private var translatedSummary: String?
    @State private var showLocalesPicker = false
    @State private var lastLocalesPicked: [String] = []
    @State private var showTranscribeChoice = false
    @State private var showRetranscribeChoice = false
    @State private var showTranslatePicker = false
    @State private var translateTarget: TranslateTarget = .transcript
    @State private var translatingTranscript = false
    @State private var translatingSummary = false
    @State private var translateError: String?
    @State private var isExporting = false
    @State private var exportShareURL: URL?
    @State private var exportError: String?
    @State private var showVADPreview = false

    private enum TranslateTarget { case transcript, summary }

    var body: some View {
        Form {
            if item.hasAudio { heroCard }
            transcriptSection
            if translation != nil { translationSection }
            summarySection
            if translatedSummary != nil { translatedSummarySection }
            if item.hasAudio { exportSection }
            destructiveSection
        }
        .padding(.top, -20)
        .navigationTitle(item.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if configService.config.isDeveloperMode {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showVADPreview = true
                    } label: {
                        Image(systemName: "waveform.and.magnifyingglass")
                    }
                    .accessibilityLabel("Preview VAD")
                }
            }
        }
        .sheet(isPresented: $showVADPreview) {
            VADPreviewView(item: item)
        }
        .task {
            if let url = item.url { player.load(url) }
            languages.fetchTargetLanguagesIfNeeded()
            transcript = TranscriptDocument.load(for: item.name)
            loadTranslation()
            loadSummary()
            loadTranslatedSummary()
        }
        .onDisappear { player.stop() }
        .onChange(of: transcription.inFlight.contains(item.name)) { isRunning in
            // Auto-transcribe landing: the service flips `inFlight` off as
            // soon as the write completes, so this is where the newly-
            // produced `{name}.txt` + `.asr.json` become readable. Manual
            // runTranscribe also benefits — it no longer has to reload
            // the doc itself.
            if !isRunning { transcript = TranscriptDocument.load(for: item.name) }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerSheet(player: player, title: item.displayTitle, totalDuration: item.duration)
        }
        .sheet(isPresented: $showSummarize) {
            if let doc = transcript {
                SummarizeSheet(
                    transcriptText: Self.textForSummarization(doc),
                    audioName: item.name
                ) { text in
                    summary = text
                }
            }
        }
        .alert(L10n.LLM.noProvider, isPresented: $showNoProvider) {
            Button(L10n.Common.openSettings) {
                dismiss()
                env.navigateToLLMProviders = true
                NotificationCenter.default.post(name: .navigateToSettings, object: nil)
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.LLM.noProviderMessage)
        }
        .alert(L10n.ClipDetail.retranscribe, isPresented: $retranscribeAlert) {
            Button(L10n.ClipDetail.retranscribe, role: .destructive) {
                showRetranscribeChoice = true
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.ClipDetail.retranscribeMessage)
        }
        .sheet(isPresented: $showLocalesPicker) {
            AzureLocalesPickerSheet(initial: lastLocalesPicked) { codes in
                lastLocalesPicked = codes
                Task { await runTranscribe(locales: codes) }
            }
        }
        .confirmationDialog(L10n.ClipDetail.transcribe, isPresented: $showTranscribeChoice, titleVisibility: .hidden) {
            Button(L10n.ASR.transcribeAuto) { triggerTranscribe(locales: nil) }
            Button(L10n.ASR.specifyLanguages) { showLocalesPicker = true }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
        .confirmationDialog(L10n.ClipDetail.retranscribe, isPresented: $showRetranscribeChoice, titleVisibility: .hidden) {
            Button(L10n.ASR.transcribeAuto) { Task { await runTranscribe(locales: nil) } }
            Button(L10n.ASR.specifyLanguages) { showLocalesPicker = true }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
        .alert(L10n.ASR.noProvider, isPresented: $showNoASR) {
            Button(L10n.Common.openSettings) {
                dismiss()
                env.navigateToASRProviders = true
                NotificationCenter.default.post(name: .navigateToSettings, object: nil)
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.ASR.noProviderMessage)
        }
        .alert(L10n.ClipDetail.deleteAudio, isPresented: $deleteAudioAlert) {
            Button(L10n.Common.delete, role: .destructive, action: deleteAudio)
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.ClipDetail.deleteAudioMessage)
        }
        .alert(L10n.ClipDetail.deleteTranscript, isPresented: $deleteTranscriptAlert) {
            Button(L10n.Common.delete, role: .destructive, action: deleteTranscript)
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.ClipDetail.deleteTranscriptMessage)
        }
        .alert(L10n.ClipDetail.deleteSummary, isPresented: $deleteSummaryAlert) {
            Button(L10n.Common.delete, role: .destructive, action: deleteSummary)
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.ClipDetail.deleteSummaryMessage)
        }
        .sheet(isPresented: $showTranslatePicker) {
            LanguagePickerSheet(
                title: L10n.ClipDetail.translate,
                languages: languages.targetLanguages,
                defaultOption: nil
            ) { lang in
                showTranslatePicker = false
                guard !lang.code.isEmpty else { return }
                env.config.config.lastTargetLang = lang.code
                env.config.scheduleSave()
                Task { await runTranslate(target: translateTarget, languageName: lang.name) }
            }
        }
        .alert(
            L10n.Summarize.error,
            isPresented: Binding(
                get: { translateError != nil },
                set: { if !$0 { translateError = nil } }
            ),
            presenting: translateError
        ) { _ in
            Button(L10n.Common.ok, role: .cancel) { translateError = nil }
        } message: { msg in
            Text(msg)
        }
        .sheet(
            isPresented: Binding(
                get: { exportShareURL != nil },
                set: { if !$0 { exportShareURL = nil } }
            ),
            onDismiss: { exportShareURL = nil }
        ) {
            if let url = exportShareURL {
                ShareSheet(items: [url])
            }
        }
        .alert(
            L10n.Summarize.error,
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ),
            presenting: exportError
        ) { _ in
            Button(L10n.Common.ok, role: .cancel) { exportError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - hero card

    private var heroCard: some View {
        Section {
            Button { showPlayer = true } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 48, height: 48)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .foregroundColor(.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            if let dur = item.durationLabel {
                                Text(dur)
                                    .font(.callout.weight(.medium).monospacedDigit())
                                    .fixedSize()
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        Text(item.recordedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                        Text(item.name)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.vertical, 4)
                // `.buttonStyle(.plain)` only takes hits on drawn pixels, so
                // the gaps between the icon and the labels were dead — the
                // card looked tappable everywhere but only responded on the
                // artwork and text.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - transcript

    private var isTranscribing: Bool {
        transcription.inFlight.contains(item.name)
    }

    @ViewBuilder
    private var transcriptSection: some View {
        Section {
            if isTranscribing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.ClipDetail.transcribing)
                    Spacer()
                    Button(L10n.Common.cancel) {
                        transcription.cancel(name: item.name)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if case .failed(let msg) = transcribeState {
                Label(msg, systemImage: "exclamationmark.bubble")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Button(L10n.Common.tryAgain) { Task { await runTranscribe() } }
            }

            if translatingTranscript {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.ClipDetail.translating)
                        .foregroundStyle(.secondary)
                }
            }

            if let doc = transcript {
                Text(transcriptPreview(doc))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                NavigationLink(L10n.ClipDetail.viewFullTranscript) {
                    TranscriptFullView(document: doc)
                }
            } else if item.hasAudio, !isTranscribing, case .idle = transcribeState {
                Button {
                    if env.config.config.asrProviders.hasConfiguredProvider {
                        showTranscribeChoice = true
                    } else {
                        showNoASR = true
                    }
                } label: {
                    Label(L10n.ClipDetail.transcribe, systemImage: "text.bubble")
                }
            }

            // Provider-fallback is silent on success: if the fallback chain
            // ultimately produced a transcript, the user doesn't need a
            // degrade warning (6tddu, pwtlfr). Failures still surface via the
            // transcribe error state.
        } header: {
            HStack {
                Text(L10n.ClipDetail.transcript)
                Spacer()
                if transcript != nil, !isTranscribing, case .idle = transcribeState {
                    Button { tapTranslate(.transcript) } label: {
                        Image(systemName: "character.bubble")
                            .font(.caption)
                    }
                    .disabled(translatingTranscript)
                    if item.hasAudio {
                        Button { retranscribeAlert = true } label: {
                            Image(systemName: "arrow.trianglehead.2.counterclockwise")
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func triggerTranscribe(locales: [String]?) {
        if env.config.config.asrProviders.hasConfiguredProvider {
            Task { await runTranscribe(locales: locales) }
        } else {
            showNoASR = true
        }
    }

    private static func textForSummarization(_ doc: TranscriptDocument) -> String {
        if !doc.segments.isEmpty, doc.segments.contains(where: { $0.speaker != nil && !$0.speaker!.isEmpty }) {
            return doc.segments.map { $0.formatted() }.joined(separator: "\n")
        }
        if !doc.segments.isEmpty {
            return doc.segments.map(\.text).joined(separator: "\n")
        }
        return doc.text
    }

    private func transcriptPreview(_ doc: TranscriptDocument) -> String {
        if doc.segments.isEmpty { return String(doc.text.prefix(200)) }
        return String(doc.segments.map(\.text).joined(separator: " ").prefix(200))
    }

    private func runTranscribe(locales: [String]? = nil) async {
        guard let fileURL = item.url else { return }
        transcribeState = .idle
        do {
            _ = try await env.transcription.transcribe(fileURL: fileURL, locales: locales)
        } catch is CancellationError {
            // User hit Cancel — fall back to the idle state without a scary
            // error banner.
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Same story, but as surfaced by URLSession's cancellation path.
        } catch {
            transcribeState = .failed(error.localizedDescription)
        }
    }

    // MARK: - translation (Live-produced or on-demand via tapTranslate(.transcript))

    @ViewBuilder
    private var translationSection: some View {
        Section {
            Text(String(translation!.prefix(200)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            NavigationLink(L10n.ClipDetail.viewFullTranslation) {
                TranslationFullView(text: translation!)
            }
        } header: {
            Text(L10n.ClipDetail.translation)
        }
    }

    private func loadTranslation() {
        let url = StorageLocations.translationURLs(for: item.name).txt
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            translation = text
        }
    }

    // MARK: - translated summary

    @ViewBuilder
    private var translatedSummarySection: some View {
        Section {
            Text(String(translatedSummary!.prefix(200)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            NavigationLink(L10n.ClipDetail.viewFullTranslatedSummary) {
                SummaryFullView(text: translatedSummary!)
            }
        } header: {
            Text(L10n.ClipDetail.translatedSummary)
        }
    }

    private func loadTranslatedSummary() {
        let url = StorageLocations.summaryTranslatedURL(for: item.name)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            translatedSummary = text
        }
    }

    // MARK: - translate action

    private func tapTranslate(_ target: TranslateTarget) {
        let providers = env.config.config.llmProviders
        if providers.primary == nil || providers.primary!.isEmpty || providers.configuredProviders.isEmpty {
            showNoProvider = true
            return
        }
        translateTarget = target
        showTranslatePicker = true
    }

    private func runTranslate(target: TranslateTarget, languageName: String) async {
        switch target {
        case .transcript:
            guard let doc = transcript else { return }
            let source = Self.textForSummarization(doc)
            translatingTranscript = true
            defer { translatingTranscript = false }
            do {
                let output = try await LLMCompletionService.translate(
                    text: source,
                    targetLanguage: languageName,
                    config: env.config.config
                )
                if output.truncated { translateError = L10n.Summarize.truncatedWarning }
                let urls = StorageLocations.translationURLs(for: item.name)
                try? output.text.data(using: .utf8)?.write(to: urls.txt, options: .atomic)
                // The Live-produced `.translated.json` carries word-level
                // timestamps for a specific target language; once the user
                // re-translates on-demand to a different language, that JSON
                // is stale, so wipe it rather than let it drift out of sync
                // with the displayed text.
                try? FileManager.default.removeItem(at: urls.json)
                translation = output.text
            } catch {
                translateError = error.localizedDescription
            }

        case .summary:
            guard let src = summary else { return }
            translatingSummary = true
            defer { translatingSummary = false }
            do {
                let output = try await LLMCompletionService.translate(
                    text: src,
                    targetLanguage: languageName,
                    config: env.config.config
                )
                if output.truncated { translateError = L10n.Summarize.truncatedWarning }
                let url = StorageLocations.summaryTranslatedURL(for: item.name)
                try? output.text.data(using: .utf8)?.write(to: url, options: .atomic)
                translatedSummary = output.text
            } catch {
                translateError = error.localizedDescription
            }
        }
    }

    // MARK: - summary

    @ViewBuilder
    private var summarySection: some View {
        Section {
            if translatingSummary {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.ClipDetail.translating)
                        .foregroundStyle(.secondary)
                }
            }
            if let summary {
                Text(String(summary.prefix(200)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                NavigationLink(L10n.ClipDetail.viewFullSummary) {
                    SummaryFullView(text: summary)
                }
            } else if transcript != nil {
                Button {
                    tapSummarize()
                } label: {
                    Label(L10n.ClipDetail.summarize, systemImage: "sparkles")
                }
            } else {
                Text(L10n.ClipDetail.transcribeFirst)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        } header: {
            HStack {
                Text(L10n.ClipDetail.summary)
                Spacer()
                if summary != nil {
                    Button { tapTranslate(.summary) } label: {
                        Image(systemName: "character.bubble")
                            .font(.caption)
                    }
                    .disabled(translatingSummary)
                    if transcript != nil {
                        Button { tapSummarize() } label: {
                            Image(systemName: "arrow.trianglehead.2.counterclockwise")
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    private func tapSummarize() {
        let providers = env.config.config.llmProviders
        if providers.primary == nil || providers.primary!.isEmpty || providers.configuredProviders.isEmpty {
            showNoProvider = true
        } else {
            showSummarize = true
        }
    }

    private func loadSummary() {
        let url = StorageLocations.summaryURL(for: item.name)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            summary = text
        }
    }

    // MARK: - export

    @ViewBuilder
    private var exportSection: some View {
        Section {
            Button {
                Task { await runExport() }
            } label: {
                HStack {
                    Label(L10n.ClipDetail.exportAsM4A, systemImage: "square.and.arrow.up.on.square")
                    Spacer()
                    if isExporting {
                        ProgressView()
                    }
                }
            }
            .disabled(isExporting)
        } header: {
            Text(L10n.ClipDetail.export)
        }
    }

    private func runExport() async {
        guard let source = item.url else { return }
        isExporting = true
        defer { isExporting = false }
        do {
            let stem = (item.name as NSString).deletingPathExtension
            let url = try await AudioExporter.exportAsM4A(source: source, suggestedName: stem)
            exportShareURL = url
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - delete

    /// Audio, transcript and summary delete independently — nothing cascades.
    /// Each entry only appears when that artefact actually exists, so the
    /// section empties out as the user removes things.
    @ViewBuilder
    private var destructiveSection: some View {
        Section {
            if item.hasAudio {
                Button(role: .destructive) { deleteAudioAlert = true } label: {
                    Label(L10n.ClipDetail.deleteAudio, systemImage: "trash")
                }
            }
            if transcript != nil {
                Button(role: .destructive) { deleteTranscriptAlert = true } label: {
                    Label(L10n.ClipDetail.deleteTranscript, systemImage: "text.badge.xmark")
                }
            }
            if summary != nil {
                Button(role: .destructive) { deleteSummaryAlert = true } label: {
                    Label(L10n.ClipDetail.deleteSummary, systemImage: "doc.badge.ellipsis")
                }
            }
        } footer: {
            Text(L10n.ClipDetail.deleteIndependentFooter)
        }
    }

    /// Removes only the audio payload. The transcript / translation / summary
    /// / title stay on disk and the clip lives on as a text-only Library entry.
    private func deleteAudio() {
        player.stop()
        if let url = item.url { try? FileManager.default.removeItem(at: url) }
        ClipArtefact.sweepOrphanTitles()
        dismiss()
    }

    /// Removes the transcript and the translation derived from it. Audio and
    /// summary are untouched.
    private func deleteTranscript() {
        let fm = FileManager.default
        let t = StorageLocations.transcriptURLs(for: item.name)
        try? fm.removeItem(at: t.txt)
        try? fm.removeItem(at: t.json)
        let tr = StorageLocations.translationURLs(for: item.name)
        try? fm.removeItem(at: tr.txt)
        try? fm.removeItem(at: tr.json)
        ClipArtefact.sweepOrphanTitles()
        transcript = nil
        translation = nil
    }

    /// Removes the summary and its translation. Audio and transcript are
    /// untouched.
    private func deleteSummary() {
        let fm = FileManager.default
        try? fm.removeItem(at: StorageLocations.summaryURL(for: item.name))
        try? fm.removeItem(at: StorageLocations.summaryTranslatedURL(for: item.name))
        ClipArtefact.sweepOrphanTitles()
        summary = nil
        translatedSummary = nil
    }
}

// MARK: - Player sheet

struct PlayerSheet: View {
    @ObservedObject var player: AudioPlaybackController
    let title: String
    /// Duration calculated by the database (Ogg page scanning). `AVAudioPlayer.duration` is the decoded length,
    /// which can differ by nearly a second—this is why the list shows 0:27 while the player shows 0:28.
    /// Total duration always uses the database value; the player's duration is only used to set the progress bar range.
    let totalDuration: TimeInterval?
    @Environment(\.dismiss) private var dismiss
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                if let err = player.loadError {
                    // Playback unavailable (e.g. Opus on iOS 16). Show the
                    // reason instead of a dead play button.
                    VStack(spacing: 12) {
                        Image(systemName: "play.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                    }
                } else {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.1))
                            .frame(width: 120, height: 120)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.accentColor)
                    }
                    // The hit area must be larger than the drawn circle, or the
                    // padding around it swallows taps. An explicit 140pt area and
                    // a real button trait also make it reachable by VoiceOver and
                    // Switch Control.
                    .frame(width: 140, height: 140)
                    .contentShape(Circle())
                    .onTapGesture { player.toggle() }
                    .accessibilityAddTraits(.isButton)
                }

                if player.loadError == nil, player.duration > 0 {
                    VStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { isScrubbing ? scrubTime : player.currentTime },
                                set: { scrubTime = $0 }
                            ),
                            in: 0...max(player.duration, 0.01),
                            onEditingChanged: { editing in
                                if editing {
                                    scrubTime = player.currentTime
                                    isScrubbing = true
                                    // Hold the audio while the thumb is held:
                                    // the bar freezes at the finger, so the
                                    // audio must freeze with it.
                                    player.beginScrub()
                                } else {
                                    // endScrub first: it sets currentTime to
                                    // the target synchronously, so dropping
                                    // isScrubbing can't show a stale frame.
                                    player.endScrub(at: scrubTime)
                                    isScrubbing = false
                                }
                            }
                        )
                        .padding(.horizontal)

                        HStack {
                            Text(formatTime(isScrubbing ? scrubTime : player.currentTime))
                            Spacer()
                            Text(formatTime(totalDuration ?? player.duration))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    }
                }

                Spacer()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        ClockLabel.mmss(seconds)
    }
}

// MARK: - Full-screen transcript view

struct TranscriptFullView: View {
    let document: TranscriptDocument
    @State private var showShareSheet = false

    private var plainText: String {
        if document.segments.isEmpty { return document.text }
        return document.segments.map { seg in
            var line = ""
            if let speaker = seg.speaker, !speaker.isEmpty {
                line += "[\(speaker)] "
            }
            let s = Int(seg.start)
            let e = Int(seg.end)
            line += "(\(s / 60):\(String(format: "%02d", s % 60))\u{2013}\(e / 60):\(String(format: "%02d", e % 60))) "
            line += seg.text
            return line
        }.joined(separator: "\n\n")
    }

    var body: some View {
        Group {
            if document.segments.isEmpty {
                LongTextScroll(text: document.text)
            } else {
                // Lazy: a multi-hour clip is thousands of segments, and an
                // eager VStack lays every one of them out before the push
                // animation can start.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(document.segments.enumerated()), id: \.offset) { _, seg in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    if let speaker = seg.speaker, !speaker.isEmpty {
                                        Text(L10n.ClipDetail.speaker(speaker))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(stampLabel(seg))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(seg.text)
                                    .font(.body)
                                    .lineSpacing(6)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(L10n.ClipDetail.transcript)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showShareSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [plainText])
        }
    }

    private func stampLabel(_ seg: AsrSegment) -> String {
        let s = Int(seg.start)
        let e = Int(seg.end)
        return String(format: "%d:%02d\u{2013}%d:%02d", s / 60, s % 60, e / 60, e % 60)
    }
}

// MARK: - Full-screen summary view

struct SummaryFullView: View {
    let text: String
    @State private var showRaw = false
    @State private var showShareSheet = false

    var body: some View {
        Group {
            if showRaw {
                LongTextScroll(text: text, font: .body.monospaced())
            } else {
                MarkdownView(markdown: text)
            }
        }
        .navigationTitle(L10n.ClipDetail.summary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        showRaw.toggle()
                    } label: {
                        Image(systemName: showRaw ? "doc.richtext" : "doc.plaintext")
                    }
                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [text])
        }
    }
}

// MARK: - Full-screen translation view

struct TranslationFullView: View {
    let text: String
    @State private var showShareSheet = false

    var body: some View {
        LongTextScroll(text: text)
            .navigationTitle(L10n.ClipDetail.translation)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: [text])
            }
    }
}

// MARK: - Long-text reader

/// Scrolling reader for transcripts, translations and raw summaries.
///
/// Two things it fixes over a plain `ScrollView { Text(whole) }`:
///
/// 1. **Latency.** One `Text` holding a whole transcript is laid out in a
///    single synchronous pass when the destination is pushed, which is what
///    made the translation entry take ~2 s on long clips. Splitting into
///    paragraphs inside a `LazyVStack` lets SwiftUI lay out only what's on
///    screen, so the push is immediate regardless of length.
/// 2. **Density.** CJK — Japanese especially — has no inter-word spaces, so
///    default `.body` line spacing reads as a solid block. The extra line
///    and paragraph spacing below is what makes translated output legible;
///    it is deliberate, not padding for its own sake.
struct LongTextScroll: View {
    let text: String
    var font: Font = .body

    /// Blank-line-separated blocks, falling back to single lines when the
    /// source has no blank lines (ASR transcripts are one line per phrase).
    private var paragraphs: [Substring] {
        let byBlankLine = text.split(separator: "\n", omittingEmptySubsequences: true)
        return byBlankLine.isEmpty ? [text[...]] : byBlankLine
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, para in
                    Text(para)
                        .font(font)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Share sheet (UIActivityViewController wrapper)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - helpers

private enum TranscribeUIState {
    case idle
    case failed(String)
}

struct TranscriptDocument {
    let text: String
    let segments: [AsrSegment]

    static func load(for audioName: String) -> TranscriptDocument? {
        let urls = StorageLocations.transcriptURLs(for: audioName)
        let fm = FileManager.default
        if fm.fileExists(atPath: urls.json.path),
           let data = try? Data(contentsOf: urls.json),
           let result = try? JSONDecoder().decode(AsrResult.self, from: data) {
            return TranscriptDocument(text: result.text, segments: result.segments)
        }
        if fm.fileExists(atPath: urls.txt.path),
           let data = try? Data(contentsOf: urls.txt),
           let text = String(data: data, encoding: .utf8) {
            return TranscriptDocument(text: text, segments: [])
        }
        return nil
    }
}
