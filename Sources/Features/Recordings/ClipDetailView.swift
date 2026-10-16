import SwiftUI

struct ClipDetailView: View {
    let item: LibraryItem
    var onChanged: () -> Void = {}

    @EnvironmentObject private var env: AppEnvironment
    @EnvironmentObject private var transcription: TranscriptionService
    /// The persistence queue for summary / translation / format conversion.
    ///
    /// ⚠️ Must be **injected separately**, not fetched via `env.jobs`: a nested `ObservableObject`'s
    ///    `@Published` changes won't invalidate a view that only observes the parent object (same as the
    ///    `watch` comment in `NomilyApp`). Going through `env.jobs`, the page would never update when a job finishes —
    ///    precisely the failure this change can least afford.
    @EnvironmentObject private var jobs: JobQueue
    @EnvironmentObject private var configService: ConfigService
    @Environment(\.dismiss) private var dismiss
    @StateObject private var player = AudioPlaybackController()
    @StateObject private var languages = LanguageService()
    @State private var transcript: TranscriptDocument?
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
    // ★ Twelfth revision, 2026-10-16: the three `@State` busy flags — `translatingTranscript` / `translatingSummary` /
    // `isExporting` — are **all deleted**, replaced by values derived from `jobs`
    // (see the `activeJob(_:target:)` section below).
    //
    // The reason is the very motivation of this change: in-memory flags leave nothing behind once the system ends the app,
    // while jobs are still queued on disk. In that state the UI would show "not running" — worse than showing nothing at all,
    // — users would think the job was lost, tap again, and end up with two queued.
    //
    // The two `@State` properties `translateError` / `exportError` and their two alerts are deleted along with them:
    // jobs can now fail **while the user isn't looking**, and an alert's "pop up on the spot" form simply
    // can't cover that; they now show in place within their own sections (`failedRow`) — visible and retryable.
    @State private var exportShareURL: URL?
    /// If the user **doesn't leave this page** after tapping export, push the share sheet straight out when it finishes (same as
    /// before the twelfth revision). If they leave, the `exportReady` row covers it — it was already there.
    /// The flag disappears together with the view, which fits the semantics exactly.
    @State private var pendingExportShare = false
    @State private var showVADPreview = false
    @State private var showMindMap = false
    @State private var showExportChoice = false

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
        // ★ 2026-10-15: The detail page counts as "opened" the moment it appears, and the red dot on the list row goes away with it.
        //
        // Hooked here rather than in the list's tap callback: the detail page has several entry points (library,
        // recording list, live page), and a tap callback would only cover one of them —
        // users opening it from elsewhere would find the dot still there, as if nothing happened. This is the single spot, and it will never
        // miss a new entry point.
        .onAppear { ClipReadStore.shared.markSeen(name: item.name) }
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
        .fullScreenCover(isPresented: $showMindMap) {
            // Re-read from state rather than capture: the summary can be
            // regenerated while the sheet is closed.
            MindMapScreen(markdown: summary ?? "", fallbackTitle: item.displayTitle)
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
                runTranscribe(locales: codes)
            }
        }
        .confirmationDialog(L10n.ClipDetail.transcribe, isPresented: $showTranscribeChoice, titleVisibility: .hidden) {
            Button(L10n.ASR.transcribeAuto) { triggerTranscribe(locales: nil) }
            Button(L10n.ASR.specifyLanguages) { showLocalesPicker = true }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
        .confirmationDialog(L10n.ClipDetail.exportAudio, isPresented: $showExportChoice, titleVisibility: .visible) {
            Button(L10n.ClipDetail.exportAsM4A) { enqueueExport(.m4a) }
            Button(L10n.ClipDetail.exportAsWAV) { enqueueExport(.wav) }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
        .confirmationDialog(L10n.ClipDetail.retranscribe, isPresented: $showRetranscribeChoice, titleVisibility: .hidden) {
            Button(L10n.ASR.transcribeAuto) { runTranscribe(locales: nil) }
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
                enqueueTranslate(target: translateTarget, languageName: lang.name)
            }
        }
        // ★ Twelfth revision: these two alerts (translation failed / export failed) are gone.
        //
        // Jobs can now fail **while the user isn't looking**, and alerts can only fire "right then and there";
        // worse, they'd **fire repeatedly** — the `lastError` in the ledger sticks around,
        // retriggering on every UI refresh. Replaced with in-place display in each section
        // (`failedRow`): visible, retryable, and never popping up on its own.
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
        // Follow along whenever the queue changes: when a job on this recording finishes / gives up, the summary, translation,
        // and share entry all have to update.
        .onChange(of: jobs.jobs) { _ in jobsChanged() }
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

    /// This recording's entry in the transcription queue that gave up after max attempts.
    ///
    /// The criterion is identical to the `asr.queue_stuck` row on the settings page (`attempts >= maxAttempts`);
    /// deliberately not inventing a second standard — if the same fact reads differently in two places, users won't know which to believe.
    private var stuckTranscription: TranscriptionService.PendingJob? {
        transcription.pending.first {
            $0.name == item.name && $0.attempts >= TranscriptionService.maxAttempts
        }
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
            } else if let stuck = stuckTranscription {
                // Transcription used its three attempts and gave up.
                //
                // This state used to be visible only in the settings page row (`asr.queue_stuck_detail`),
                // but the user pressed the button **on this recording** — all they'd feel is "nothing happened".
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.Jobs.statusGaveUp, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    if let reason = stuck.lastError {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Retrying is just enqueueing again — `enqueue` resets the attempt counter,
                    // the same semantics as `JobQueue.retry(id:)`.
                    Button(L10n.Jobs.retry) { runTranscribe(locales: stuck.locales) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            // Transcript translation: shown in place here whether running or given up.
            //
            // This row used to hang off the in-memory `translatingTranscript`; switch away and back and it
            // was gone — users couldn't tell whether the job was still alive and would most likely tap translate again.
            if let job = activeJob(.translate, target: "transcript") {
                runningRow(job, L10n.ClipDetail.translating)
            } else if let job = failedJob(.translate, target: "transcript") {
                failedRow(job)
            }
            if let job = lastFinishedJob(.translate, target: "transcript") { notesRow(job) }

            if let doc = transcript {
                Text(transcriptPreview(doc))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                NavigationLink(L10n.ClipDetail.viewFullTranscript) {
                    TranscriptFullView(document: doc)
                }
            } else if item.hasAudio, !isTranscribing {
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
                if transcript != nil, !isTranscribing {
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
            runTranscribe(locales: locales)
        } else {
            showNoASR = true
        }
    }

    /// Forwards to `JobRunners.summarizableText` — **keep exactly one implementation**.
    ///
    /// After the twelfth revision summarizing gained a second entry point (the `JobQueue` runner, which reads the transcript from disk),
    /// and that path must be fed the exact same text. Written separately in two places they will eventually drift, manifesting as
    /// "the same template producing summaries with different structures a day apart" — a problem no one can debug.
    private static func textForSummarization(_ doc: TranscriptDocument) -> String {
        JobRunners.summarizableText(text: doc.text, segments: doc.segments)
    }

    private func transcriptPreview(_ doc: TranscriptDocument) -> String {
        if doc.segments.isEmpty { return String(doc.text.prefix(200)) }
        return String(doc.segments.map(\.text).joined(separator: " ").prefix(200))
    }

    /// Start a transcription.
    ///
    /// ★ Twelfth revision, 2026-10-16: switched to `enqueue` **instead of** `transcribe`.
    ///
    /// The difference only shows in the one case of "app killed midway": a directly-run job vanishes into thin air
    /// the moment the process is gone; the user comes back the next day to an untranscribed recording, with no way of knowing an attempt
    /// was ever made. `enqueue` persists first, runs second, and `resumePending()` picks it up on next launch —
    /// exactly what the user's "exit to the background first and check when it's done" asked for.
    ///
    /// No longer `async`: enqueueing is synchronous, and the real waiting is driven into the UI by `transcription.inFlight`
    /// / `pending` (see `isTranscribing` and `stuckTranscription`).
    /// Keeping `async` would make every call site warn "no 'async' operations occur within
    /// 'await' expression", and this project builds with zero warnings.
    private func runTranscribe(locales: [String]? = nil) {
        guard let fileURL = item.url else { return }
        env.transcription.enqueue(fileURL: fileURL, locales: locales)
    }

    // MARK: - Job queue integration (★ twelfth revision 2026-10-16)

    /// The running job of this kind on this recording (the UI uses it for the button's busy state).
    private func activeJob(_ kind: JobKind, target: String? = nil) -> Job? {
        jobs.activeJobs(for: item.name).first { job in
            job.kind == kind && (target == nil || job.translateTarget == target)
        }
    }

    /// The job of this kind on this recording that **gave up after max attempts**.
    ///
    /// "Has `finishedAt` and a `lastError`" means gave up — on success `lastError` is
    /// nil, and so it is on cancellation; the three states separate on these two fields alone (see `JobQueue.State`).
    /// Once the user starts again (`enqueue` clears `lastError`) or taps retry, this row disappears on its own.
    private func failedJob(_ kind: JobKind, target: String? = nil) -> Job? {
        jobs.jobs.first { job in
            job.clipName == item.name && job.kind == kind
                && job.finishedAt != nil && job.lastError != nil
                && (target == nil || job.translateTarget == target)
        }
    }

    /// The most recently **finished successfully** job of a given kind (used to show the result note).
    ///
    /// Only "success" counts (`finishedAt` set and `lastError` nil): the reason for failure has already been
    /// stated once in `failedRow`; repeating it here would only make people think there are two problems.
    /// "Most recent" rather than any entry: one recording can be translated into several languages in turn, and the note
    /// (say, "truncated") must match **the content the user is looking at now**.
    private func lastFinishedJob(_ kind: JobKind, target: String? = nil) -> Job? {
        jobs.jobs
            .filter {
                $0.clipName == item.name && $0.kind == kind
                    && $0.finishedAt != nil && $0.lastError == nil
                    && (target == nil || $0.translateTarget == target)
            }
            .max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
    }

    /// The little result-note block (fallback channel / chunked / body truncated).
    ///
    /// Draws nothing when there's no content. **Why it must exist**: the note is "part of the result",
    /// and such jobs usually finish while the user isn't looking — without keeping it here, the question "I set
    /// Open Router, so why was this generated by Ollama?" goes unanswered forever; and a truncated
    /// body reads exactly like a complete one.
    @ViewBuilder
    private func notesRow(_ job: Job) -> some View {
        if job.wasTruncated == true {
            Label(L10n.Summarize.truncatedWarning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        ForEach(job.notes ?? [], id: \.self) { note in
            Label(note, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The "in progress" row.
    ///
    /// When the user starts it here, switches away, and comes back, this is the only place they can see "it's still running"
    /// — the row used to exist only while the `await` hadn't returned (in-memory flag), vanishing after a switch away and back.
    @ViewBuilder
    private func runningRow(_ job: Job, _ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .foregroundStyle(.secondary)
                if let done = job.progressDone, let total = job.progressTotal {
                    Text(L10n.Jobs.progress(done, total))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                } else if let detail = job.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The "gave up after max attempts" row + retry in place.
    ///
    /// **Must be shown**: coming back after switching away, if the content still looks old, users will think it's still running
    /// (or that the button is broken), and will most likely tap again — queueing a second job.
    @ViewBuilder
    private func failedRow(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.Jobs.statusGaveUp, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
            if let error = job.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(L10n.Jobs.retry) { jobs.retry(id: job.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    /// Follow along whenever the queue changes.
    ///
    /// ⚠️ Hooked on `.onChange(of: jobs.jobs)` rather than waiting for the runner to call back into the view: jobs very often
    ///    finish while this page **doesn't even exist** (exactly the scenario the twelfth revision set out to support).
    ///    So the only thing to do here is re-read the output from **disk**.
    ///
    /// The cost is one re-read per chunk-progress tick (a few dozen small file reads); the payoff is an implementation needing
    /// no extra state synchronization at all. Worth it.
    private func jobsChanged() {
        loadSummary()
        loadTranslation()
        loadTranslatedSummary()

        // Export finished → share sheet (same "pop up when done" behavior as before the twelfth revision).
        //
        // Pops only if the user **didn't leave this page** after tapping export: the flag disappears with the view,
        // and if they left, the `exportReady` row covers it — it was already there; nothing new to add.
        if pendingExportShare, activeJob(.export) == nil, failedJob(.export) == nil,
           let staged = ExportCenter.shared.ready(forOrigin: item.name) {
            pendingExportShare = false
            exportShareURL = ExportCenter.shared.url(for: staged)
        }
    }

    // MARK: - translation (Live-produced or on-demand via tapTranslate(.transcript))

    /// The transcript translation is running.
    ///
    /// Computed instead of an `@State` — see the comment at the top of the file. All three flags follow the same pattern, so
    /// "the UI says it's running when it stopped long ago" (the state after the app is killed) becomes structurally impossible.
    private var translatingTranscript: Bool { activeJob(.translate, target: "transcript") != nil }
    private var translatingSummary: Bool { activeJob(.translate, target: "summary") != nil }


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

    /// Enqueue a translation. **No longer awaits itself** — see the note at the top of `JobQueue`:
    /// an in-memory `Task` disappears when the system ends the app; a persisted job doesn't.
    ///
    /// The keep-alive token (`BackgroundKeeper.acquire(.summary)`) moved into
    /// `JobRunners.translate` — whoever does the work holds the token; all four runners follow the same pattern.
    private func enqueueTranslate(target: TranslateTarget, languageName: String) {
        // `TranslateTarget` → the job's `translateTarget` string. A `String` rather than
        // moving this private enum into `Job`: the enum belongs to the **UI** (it decides which
        // button is tapped), while the job needs only the fact "transcript or summary is being translated"; the two don't need to share a type.
        let t = target == .summary ? "summary" : "transcript"
        jobs.enqueue(Job.translate(clip: item.name, target: t, languageName: languageName))
    }

    // MARK: - summary

    @ViewBuilder
    private var summarySection: some View {
        Section {
            // The summary itself plus its translation — both kinds produce "summary section content", so they sit together.
            //
            // ★ The most important case here: the user **picked a template in the summary sheet and then
            //   swiped it away** (exactly the usage the twelfth revision set out to support). Without these two lines,
            //   they'd return to the detail page to find only the "Generate summary" button, with no sign a job is running.
            if let job = activeJob(.summarize) {
                runningRow(job, L10n.Summarize.summarizing)
            } else if let job = failedJob(.summarize) {
                failedRow(job)
            }
            if let job = activeJob(.translate, target: "summary") {
                runningRow(job, L10n.ClipDetail.translating)
            } else if let job = failedJob(.translate, target: "summary") {
                failedRow(job)
            }
            if let summary {
                Text(String(summary.prefix(200)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                NavigationLink(L10n.ClipDetail.viewFullSummary) {
                    SummaryFullView(text: summary)
                }

                // Only offered when the summary actually has section
                // structure to plot — a flat block of prose has no map.
                if MarkdownOutline.parse(summary) != nil {
                    Button {
                        showMindMap = true
                    } label: {
                        Label(L10n.ClipDetail.mindMap, systemImage: "arrow.triangle.branch")
                    }
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

            // Result note (fallback channel / chunked / truncated). Placed after the content — it describes
            // the content above.
            if let job = lastFinishedJob(.summarize) { notesRow(job) }
            if let job = lastFinishedJob(.translate, target: "summary") { notesRow(job) }
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
                showExportChoice = true
            } label: {
                HStack {
                    Label(L10n.ClipDetail.exportAudio, systemImage: "square.and.arrow.up.on.square")
                    Spacer()
                    if activeJob(.export) != nil {
                        ProgressView()
                    }
                }
            }
            .disabled(activeJob(.export) != nil)

            // Converting / conversion failed (max attempts used). Both shown in place here — after switching away and
            // coming back, this row is the only place they can tell "the transcode is still running" or "it actually failed".
            if let job = activeJob(.export) {
                runningRow(job, L10n.ClipDetail.exporting)
            } else if let job = failedJob(.export) {
                failedRow(job)
            }

            // ★ Sixth revision, 2026-10-15: if **the previously exported copy is still there**, offer the share entry directly.
            //
            // This row answers the user's words "so leaving doesn't mean waiting all over again": transcoding a large file takes
            // a long time and users switch away before it's done — if all they find on return is that "Export audio"
            // button, it means waiting all over again from scratch. This tells them "it's ready — tap here to send
            // it out", along with the size (that's how they decide whether to clear it first).
            //
            // ⚠️ Only accept `origin == item.name`: the copy prepared by a batch export belongs to another item,
            //    and offering a share entry for it on this recording's detail page would imply "this is what's being shared".
            if activeJob(.export) == nil, let staged = ExportCenter.shared.ready(forOrigin: item.name) {
                HStack(spacing: 8) {
                    Button {
                        // Reuse the share sheet above driven by `exportShareURL` —
                        // attaching another `.sheet` for this entry would only add one more piece of state to keep in sync.
                        exportShareURL = ExportCenter.shared.url(for: staged)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(L10n.ClipDetail.exportReady)
                                Text(Self.readyDetail(staged))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        ExportCenter.shared.discard()
                    } label: {
                        Label(L10n.ClipDetail.clearExportStaging, systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.ClipDetail.clearExportStaging)
                }
            }
        } header: {
            Text(L10n.ClipDetail.export)
        } footer: {
            Text(L10n.ClipDetail.exportFormatFooter)
        }
    }

    /// "1 file · 42 MB". The size matters — it's how the user decides whether to clear it first.
    private static func readyDetail(_ item: ExportCenter.Ready) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        return "\(L10n.ClipDetail.exportReadyFiles(item.itemCount)) · \(size)"
    }

    /// Enqueue a format conversion. **No longer awaits itself** (same reason as `enqueueTranslate`).
    ///
    /// `ExportCenter.publish` also moved into `JobRunners.export` — writing the output to disk and registering it in the ledger
    /// must be the same stretch of code, otherwise an app kill leaves "file converted but absent from the ledger".
    private func enqueueExport(_ format: AudioExportFormat) {
        pendingExportShare = true
        jobs.enqueue(Job.export(clip: item.name, format: format))
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
    ///
    /// ★ 2026-10-15: Audio is no longer removed via `removeItem` outright — it's **moved to the trash** (protected for 30 days).
    /// The on-disk name and path stay exactly the same, so once restored the scanner sees the very same item as before.
    private func deleteAudio() {
        player.stop()
        var urls: [URL] = []
        if let url = item.url { urls.append(url) }
        // When the audio is this item's last remaining piece, `.title` instantly becomes an "orphaned title" — the scanner
        // would use it to rebuild a ghost entry with neither audio nor body text. So it moves together with the audio.
        if let title = ClipTrash.titleSidecar(
            forLocalName: item.name,
            hasOtherArtefacts: item.hasTranscript || item.hasSummary
        ) {
            urls.append(title)
        }
        ClipTrash.shared.move(
            [ClipTrash.Payload(
                localName: item.name,
                title: item.displayTitle,
                urls: urls,
                // With the audio copy gone, the "already downloaded from the device" credentials must be revoked — otherwise
                // the device list would show it as "downloaded" forever, never downloadable again. Restored back on recovery.
                download: ClipTrash.downloadRecord(forLocalName: item.name, in: env.library),
                // The source is fixed at the moment of deletion; see `TrashedItem.source`.
                source: ClipTrash.sourceLabel(forLocalName: item.name, in: env.library)
            )],
            library: env.library
        )
        dismiss()
    }

    /// Removes the transcript and the translation derived from it. Audio and
    /// summary are untouched.
    private func deleteTranscript() {
        let t = StorageLocations.transcriptURLs(for: item.name)
        let tr = StorageLocations.translationURLs(for: item.name)
        var urls = [t.txt, t.json, tr.txt, tr.json]
        if let title = ClipTrash.titleSidecar(
            forLocalName: item.name,
            hasOtherArtefacts: item.hasAudio || item.hasSummary
        ) {
            urls.append(title)
        }
        ClipTrash.shared.move(
            [ClipTrash.Payload(
                localName: item.name,
                title: item.displayTitle,
                urls: urls,
                // ⚠️ `download` **must not** be included here: the audio is still present, and revoking the credentials would amount to
                // erasing a still-existing asset from the manifest.
                download: nil,
                source: ClipTrash.sourceLabel(forLocalName: item.name, in: env.library)
            )],
            library: env.library
        )
        transcript = nil
        translation = nil
    }

    /// Removes the summary and its translation. Audio and transcript are
    /// untouched.
    private func deleteSummary() {
        var urls = [
            StorageLocations.summaryURL(for: item.name),
            StorageLocations.summaryTranslatedURL(for: item.name),
        ]
        if let title = ClipTrash.titleSidecar(
            forLocalName: item.name,
            hasOtherArtefacts: item.hasAudio || item.hasTranscript
        ) {
            urls.append(title)
        }
        ClipTrash.shared.move(
            [ClipTrash.Payload(
                localName: item.name,
                title: item.displayTitle,
                urls: urls,
                download: nil,    // Ditto: the audio is untouched, credentials kept.
                source: ClipTrash.sourceLabel(forLocalName: item.name, in: env.library)
            )],
            library: env.library
        )
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
    @State private var showMindMap = false

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
                    if MarkdownOutline.parse(text) != nil {
                        Button {
                            showMindMap = true
                        } label: {
                            Image(systemName: "arrow.triangle.branch")
                        }
                        .accessibilityLabel(L10n.ClipDetail.mindMap)
                    }
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
        .fullScreenCover(isPresented: $showMindMap) {
            MindMapScreen(markdown: text, fallbackTitle: L10n.ClipDetail.summary)
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
