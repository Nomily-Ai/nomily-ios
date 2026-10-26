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
    /// ★ 2026-10-23 ("录音来源里面还有大纲总结"): chapters of the recording, read
    /// from `<base>.chapters.json`. Loaded here (not in the outline section)
    /// so switching tabs back and forth doesn't hit the disk each time.
    @State private var chapters: [ClipChapter] = []
    @State private var deleteAudioAlert = false
    @State private var deleteTranscriptAlert = false
    @State private var deleteSummaryAlert = false
    @State private var summary: String?
    /// ★ 2026-10-23 ("页面模板", Plaud parity): a recording carries **several note
    /// pages**, each generated from its own template. `summary` stays the text of
    /// the *primary* page (id `NotePage.primaryID`) so the translate/export/menu
    /// paths around it don't move; `pages` + `selectedPageID` + `pageText` drive
    /// the chip row — Plaud's 「总结 ▾ | 权力动态 | +」.
    @State private var pages: [NotePage] = []
    @State private var selectedPageID: String = NotePage.primaryID
    /// Body of the selected **non-primary** page (the primary one lives in `summary`).
    @State private var pageText: String?
    /// The page the open summarize sheet writes to (regenerate vs. add).
    @State private var summarizePageID: String = NotePage.primaryID
    @State private var showAddPage = false
    @State private var addPageID = ""
    @State private var deletePageAlert: NotePage?
    /// The text of whichever page is on screen — the one surface mind map / full
    /// view / Q&A should all follow.
    private var currentPageText: String? {
        selectedPageID == NotePage.primaryID ? summary : pageText
    }
    @State private var showSummarize = false
    @State private var showNoProvider = false
    @State private var showNoASR = false
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
    /// ★ 任务二 (2026-10-22): email-with-attachments sheet.
    @State private var showMailExport = false
    /// "Marks" pushed by a recorder card while it was recording.
    ///
    /// ★ Read once on appear from `<base>.marks.json` and never re-read: a sidecar only ever appears
    /// **together with** the download that produced this clip, so it cannot change while the page is
    /// open. Keeping it in `@State` (rather than computing it inside `body`) also avoids decoding the
    /// JSON on every redraw — `body` re-evaluates once a second while audio plays.
    @State private var marks: [A1Mark] = []

    private enum TranslateTarget { case transcript, summary }

    /// ★ 2026-10-23 ("照 Plaud 的样式", vivo 取证): exactly two tabs, Plaud's
    /// 「来源 | 笔记」. 来源 = playback + the timestamped, speaker-labelled
    /// transcript (the *source*); 笔记 = the generated note pages, mind map and
    /// the note chat (the *product*). The old third To-dos tab is gone, Plaud
    /// style — to-dos live as a note page (the 待办清单（Plaud） template), and
    /// TodoExtract's aggregation over all pages remains available there.
    private enum DetailTab: CaseIterable, Identifiable {
        case source, notes
        var id: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        var title: String {
            switch self {
            case .source: L10n.ClipDetail.tabTranscript
            case .notes: L10n.ClipDetail.tabSummary
            }
        }
    }
    @State private var detailTab: DetailTab = .source
    @State private var transcriptQuery = ""
    @State private var speakerFilter: String?
    /// ★ 2026-10-22 ("还要支持修改说话人的名称"): the user's names for this clip's
    /// diarized speakers. Observed (not read once) so a rename in the sheet
    /// repaints every row and chip behind it.
    @ObservedObject private var speakerStore = SpeakerNameStore.shared
    @State private var showSpeakerEditor = false
    /// Q&A state lives in the page, not in the section: the input bar is pinned to the bottom
    /// while the answers stay in the scrolling list.
    @StateObject private var aiChat = AIChatModel()
    /// The Q&A conversation is a sheet, not an in-page panel (17:04 screenshot:
    /// the panel covered the player and left a void above the keyboard).
    @State private var showAskSheet = false
    /// ★ 2026-10-23 ("生成的摘要需要能够支持编辑点击能够写入修改"): tap 编辑 on a
    /// note page and the markdown becomes a `TextEditor`; 保存 writes straight
    /// back to the page's file — the same file the reader, share poster and
    /// mind map all read, so there is exactly one copy of the truth.
    @State private var isEditingSummary = false
    @State private var editedSummary = ""

    /// Plaud's wording, per tab.
    private var askPlaceholder: String {
        detailTab == .notes ? L10n.ClipDetail.aiAskPlaceholderNote : L10n.ClipDetail.aiAskPlaceholder
    }

    /// ★ 2026-10-23 ("参考一下页面布局跟结构", Plaud 截图 4029/4028): Plaud puts
    /// 来源 | 笔记 **in the navigation bar itself**, centred, with a short
    /// underline under the active one. That is why their content starts
    /// immediately below the title — there is no second strip eating 40 pt.
    /// Same shape here: `principal` toolbar item, ~22 pt tall.
    private var navTabs: some View {
        HStack(spacing: 22) {
            ForEach(DetailTab.allCases) { tab in
                Button {
                    guard detailTab != tab else { return }
                    withAnimation(.easeOut(duration: 0.16)) { detailTab = tab }
                } label: {
                    VStack(spacing: 3) {
                        Text(tab.title)
                            .font(.system(size: 15, weight: detailTab == tab ? .semibold : .regular))
                            .foregroundStyle(detailTab == tab ? Color.primary : Color.secondary)
                        Capsule(style: .continuous)
                            .fill(detailTab == tab ? Color.primary : Color.clear)
                            .frame(width: 18, height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(detailTab == tab ? [.isSelected] : [])
            }
        }
    }

    var body: some View {
        // ★ 2026-10-23 ("参考一下页面布局跟结构"): the tabs moved INTO the nav bar
        // (`navTabs`, a `principal` toolbar item) — Plaud's layout. The old
        // separate strip below the title is gone entirely, so the page starts
        // right under the navigation bar.
        VStack(spacing: 0) {
            Form {
            switch detailTab {
            case .source:
                // The player belongs to 来源, like Plaud's: playback and the
                // timestamped transcript (who said what, when) are one surface.
                if item.hasAudio { heroCard }
                if !marks.isEmpty { marksSection }
                // ★ 2026-10-23: Plaud's order — player, then the outline (a
                //   clickable table of contents), then the transcript itself.
                //   Only when there is a transcript: an outline is derived from
                //   its timings, so without one there is nothing to navigate.
                if transcript != nil { outlineSection }
                transcriptSection
                if translation != nil { translationSection }
            case .notes:
                summarySection
                if translatedSummary != nil { translatedSummarySection }
                // ★ 2026-10-23 ("待办清单在底部即可"): the to-do list comes back as
                //   a plain section at the bottom of the 笔记 tab — not its own tab
                //   (user reverted 136's removal), aggregated over ALL note pages.
                todoListSection
                // ★ 2026-10-23 ("ai 问答是直接一个聊条框不要直接全部占满底部"):
                //   the inline Q&A section is GONE. The whole conversation now
                //   lives in the pinned bottom bar (bubbles above the input) —
                //   the page body stays content-only.
            }
            // Export/delete moved into the top-right menu (Plaud / DingTalk detail-page shape).
            // Only a *running or failed* export still gets an inline row — progress needs to be
            // visible without opening a menu.
            if activeJob(.export) != nil || failedJob(.export) != nil {
                exportStatusSection
            }
            }
            // ★ 2026-10-23 ("这个布局排版都是有问题的"): the −16 that used to pull
            // the Form up under the tab strip also clipped the top of the player
            // card — visible in the 17:04 screenshot. The tab strip now carries
            // its own divider, so the Form keeps its normal inset.
        }
        .navigationTitle(item.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        // ★ (2026-10-19) The three tabs belong to the app's home shell. Keeping them on a
        // recording detail page wastes the bottom strip on navigation the user has already
        // made a decision about — and the Q&A bar needs that strip.
        .toolbar(.hidden, for: .tabBar)
        // Answers live in their own sheet, the bar does not. Both tabs ask —
        // the context has always carried SUMMARY + TRANSCRIPT, so a question on
        // 来源 is answered from the transcript.
        // ★ 2026-10-23 ("这个布局排版都是有问题的需要优化"): the bar no longer
        //  expands into the page. It is one short row; tapping it opens
        //  `AIChatSheet`. Wording follows Plaud per tab (笔记 = their exact
        //  "对此笔记提问").
        .safeAreaInset(edge: .bottom) {
            if aiChat.isAvailable {
                AIChatAskBar(placeholder: askPlaceholder) { showAskSheet = true }
            }
        }
        .sheet(isPresented: $showAskSheet) {
            AIChatSheet(model: aiChat, placeholder: askPlaceholder)
        }
        // ★ 2026-10-15: The detail page counts as "opened" the moment it appears, and the red dot on the list row goes away with it.
        //
        // Hooked here rather than in the list's tap callback: the detail page has several entry points (library,
        // recording list, live page), and a tap callback would only cover one of them —
        // users opening it from elsewhere would find the dot still there, as if nothing happened. This is the single spot, and it will never
        // miss a new entry point.
        .onAppear { ClipReadStore.shared.markSeen(name: item.name) }
        // ★ 2026-10-23 ("参考一下页面布局跟结构"): 来源 | 笔记 sit in the centre of
        // the navigation bar, Plaud's way — no separate strip under the title.
        .toolbar {
            ToolbarItem(placement: .principal) { navTabs }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // ★ (2026-10-19) Export + delete live here, not as two sections at the bottom of
                // the page. Plaud / DingTalk both keep per-recording actions in a single overflow
                // menu — the old layout pushed them below an arbitrarily long summary, so users
                // scrolled past every section looking for "delete".
                Menu {
                    if item.hasAudio {
                        Button {
                            showExportChoice = true
                        } label: {
                            Label(L10n.ClipDetail.exportAudio, systemImage: "square.and.arrow.up.on.square")
                        }
                        .disabled(activeJob(.export) != nil)
                    }
                    // ★ 2026-10-22 (任务二): document export — txt / md / pdf,
                    // plus the mail-with-attachments entry Plaud's
                    // `Workflow_send_email_attachments_*` proves out.
                    if transcript != nil || summary != nil {
                        Menu {
                            Button(L10n.ClipDetail.exportAsTXT) { enqueueDocumentExport("txt") }
                            Button(L10n.ClipDetail.exportAsMarkdown) { enqueueDocumentExport("md") }
                            Button(L10n.ClipDetail.exportAsPDF) { enqueueDocumentExport("pdf") }
                        } label: {
                            Label(L10n.ClipDetail.exportDocument, systemImage: "doc.badge.arrow.up")
                        }
                        .disabled(activeJob(.export) != nil)
                        Button {
                            showMailExport = true
                        } label: {
                            Label(L10n.ClipDetail.emailTitle, systemImage: "envelope")
                        }
                    }
                    if activeJob(.export) == nil, let staged = ExportCenter.shared.ready(forOrigin: item.name) {
                        Button {
                            exportShareURL = ExportCenter.shared.url(for: staged)
                        } label: {
                            Label(L10n.ClipDetail.exportReady, systemImage: "checkmark.circle")
                        }
                    }
                    if item.hasAudio || transcript != nil || summary != nil {
                        Divider()
                    }
                    // ★ 2026-10-23 ("还支持重新转写…" Plaud 4031): Plaud's page
                    //   menu carries 重新转写 and 为说话人命名 next to the
                    //   destructive items. Both existed here already — the
                    //   re-transcribe one only as a small icon in the transcript
                    //   header, which is not where anyone looks for it.
                    if item.hasAudio {
                        Button {
                            retranscribeAlert = true
                        } label: {
                            Label(L10n.ClipDetail.retranscribe,
                                  systemImage: "arrow.trianglehead.2.counterclockwise")
                        }
                        .disabled(isTranscribing)
                    }
                    if transcript != nil {
                        Button {
                            showSpeakerEditor = true
                        } label: {
                            Label(L10n.ClipDetail.editSpeakerNames, systemImage: "person.wave.2")
                        }
                    }
                    if item.hasAudio || transcript != nil {
                        Divider()
                    }
                    if item.hasAudio {
                        Button(role: .destructive) {
                            deleteAudioAlert = true
                        } label: {
                            Label(L10n.ClipDetail.deleteAudio, systemImage: "trash")
                        }
                    }
                    if transcript != nil {
                        Button(role: .destructive) {
                            deleteTranscriptAlert = true
                        } label: {
                            Label(L10n.ClipDetail.deleteTranscript, systemImage: "text.badge.xmark")
                        }
                    }
                    if summary != nil {
                        Button(role: .destructive) {
                            deleteSummaryAlert = true
                        } label: {
                            Label(L10n.ClipDetail.deleteSummary, systemImage: "doc.badge.ellipsis")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(L10n.ClipDetail.moreActions)
            }
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
        // ★ 2026-10-22 ("还要支持修改说话人的名称").
        .sheet(isPresented: $showSpeakerEditor) {
            SpeakerRenameSheet(clip: item.name,
                               speakers: speakerRoster(transcript?.segments ?? []))
        }
        .fullScreenCover(isPresented: $showMindMap) {
            // Re-read from state rather than capture: the summary can be
            // regenerated while the sheet is closed. Follows the **selected page**.
            MindMapScreen(markdown: currentPageText ?? "", fallbackTitle: item.displayTitle)
        }
        .task {
            if let url = item.url { player.load(url) }
            languages.fetchTargetLanguagesIfNeeded()
            transcript = TranscriptDocument.load(for: item.name)
            chapters = ClipChapterStore.load(for: item.name)
            // Speaker names are a sidecar of this clip; load once per visit.
            speakerStore.load(clip: item.name)
            marks = A1MarkStore.sidecar(forClipBase: item.base)
            loadTranslation()
            loadSummary()
            loadTranslatedSummary()
            // ★ 2026-10-23 ("页面模板"): load the page manifest; a clip from before
            //   the feature falls back to "just the primary page" inside `NotePages.load`.
            pages = NotePages.load(for: item.name)
            if !pages.contains(where: { $0.id == selectedPageID }) {
                selectedPageID = pages.first?.id ?? NotePage.primaryID
            }
            loadSelectedPageText()
            aiChat.context = aiContext ?? ""
        }
        .onDisappear { player.stop() }
        .onChange(of: jobs.jobs) { _ in
            // A summarize job can finish while this page is open (or after the sheet
            // was dismissed) — the manifest gains the page on disk, so re-read it
            // here. Guarded by equality so it stays a no-op most of the time.
            let loaded = NotePages.load(for: item.name)
            if loaded != pages {
                pages = loaded
                if !loaded.contains(where: { $0.id == selectedPageID }) {
                    selectedPageID = loaded.first?.id ?? NotePage.primaryID
                }
                loadSelectedPageText()
            }
            // ★ 2026-10-23: same reasoning for the outline — it's written by a
            // queued job (`outline:<clip>`), which usually finishes while the
            // user is looking at exactly this page. Equality-guarded, so the
            // frequent unrelated job-list updates stay free.
            let loadedChapters = ClipChapterStore.load(for: item.name)
            if loadedChapters != chapters { chapters = loadedChapters }
        }
        // A rename must reach the Q&A context as well, or answers keep using the
        // old labels until the page is reopened (2026-10-22).
        .onChange(of: speakerStore.maps) { _ in
            aiChat.context = aiContext ?? ""
        }
        .onChange(of: transcription.inFlight.contains(item.name)) { isRunning in
            // Auto-transcribe landing: the service flips `inFlight` off as
            // soon as the write completes, so this is where the newly-
            // produced `{name}.txt` + `.asr.json` become readable. Manual
            // runTranscribe also benefits — it no longer has to reload
            // the doc itself.
            if !isRunning { transcript = TranscriptDocument.load(for: item.name) }
        }
        .sheet(isPresented: $showSummarize) {
            if let doc = transcript {
                SummarizeSheet(
                    transcriptText: Self.textForSummarization(doc, speakerNames: speakerMap),
                    audioName: item.name,
                    // ★ 2026-10-23 ("页面模板"): the page the action came from — the
                    //   primary page when the plain "generate" was tapped, the selected
                    //   page when "更换模板" was.
                    pageID: summarizePageID
                ) { text in
                    if summarizePageID == NotePage.primaryID { summary = text }
                    pages = NotePages.load(for: item.name)
                    loadSelectedPageText()
                }
            }
        }
        .sheet(isPresented: $showAddPage) {
            if let doc = transcript {
                SummarizeSheet(
                    transcriptText: Self.textForSummarization(doc, speakerNames: speakerMap),
                    audioName: item.name,
                    pageID: addPageID
                ) { _ in
                    // The manifest entry is written by the runner when the artifact
                    // lands; here we only re-read what it wrote.
                    pages = NotePages.load(for: item.name)
                    selectedPageID = addPageID
                    loadSelectedPageText()
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
        .sheet(isPresented: $showMailExport) {
            MailExportSheet(clipName: item.name)
        }
        // ★ 2026-10-23 ("页面模板"): deleting a note page — the chip's context menu
        //   hands the page over here. The primary page is excluded in the menu: its
        //   deletion goes through "删除摘要" (trash flow + translation sidecar).
        .alert(L10n.ClipDetail.noteDeletePage, isPresented: Binding(
            get: { deletePageAlert != nil },
            set: { if !$0 { deletePageAlert = nil } }
        )) {
            Button(L10n.Common.delete, role: .destructive) {
                if let page = deletePageAlert { deletePage(page) }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.ClipDetail.noteDeletePageMessage)
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
            // ★ (2026-10-19) Inline player instead of "tap → sheet".
            //   The sheet was the only way to control playback, so reading a transcript meant
            //   opening and closing a modal for every re-listen; the detail page now owns the
            //   transport and the transcript below reacts to it.
            InlineAudioPlayer(player: player, totalDuration: item.duration, fileURL: item.url)

            HStack(spacing: 6) {
                Text(item.name)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                Text("·").font(.caption2).foregroundStyle(.tertiary)
                // Locale comes from `AppLocale` — `.formatted(date:time:)` reads
                // `Locale.current`, not the SwiftUI environment (thirteenth revision note).
                Text(AppLocale.string(from: item.recordedAt, dateStyle: .medium, timeStyle: .short))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
    }

    // MARK: - remarks (marks)

    /// The marks the card registered with **its own button** while it was recording.
    ///
    /// ★ These are not transcription output and not an invention on our side: mid-recording the A1
    /// emits `AUDIO_CONTROL_REMARK_BUTTON_CLICK` (`0x0B000001`) stamped with the **card's own clock**,
    /// so the offset from `AUDIO_RECORD_START` survives even when the report is delivered in a batch
    /// seconds later. It is downloaded as `<base>.marks.json` next to the clip, which is what this reads.
    ///
    /// Hidden entirely when there are no marks — an empty "Remarks" header would advertise a feature the
    /// recording never used, and the user would wonder what they were supposed to have pressed.
    @ViewBuilder
    private var marksSection: some View {
        Section {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                Button {
                    guard let url = item.url else { return }
                    // `load` is a no-op on the same URL, so this is safe even mid-playback.
                    player.load(url)
                    player.seek(to: mark.offset)
                    player.play()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(ClockLabel.mmss(mark.offset))
                            .font(.callout.monospacedDigit())
                        Spacer()
                        Image(systemName: "play.circle")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text(L10n.ClipDetail.remarks)
                Spacer()
                Text(L10n.ClipDetail.remarksCount(marks.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text(L10n.ClipDetail.remarksFooter)
        }
    }

    // MARK: - outline (★ 2026-10-23, "录音来源里面还有大纲总结")

    /// Plaud's 大纲 block: a timestamped table of contents above the transcript.
    /// Tapping a chapter seeks the player there; the chapter under the playhead
    /// is tinted, so "where am I in this recording" reads at a glance.
    @ViewBuilder
    private var outlineSection: some View {
        Section {
            if let job = activeJob(.outline) {
                runningRow(job, L10n.ClipDetail.outlineGenerating)
            } else if chapters.isEmpty {
                if let job = failedJob(.outline) {
                    failedRow(job)
                } else if hasTimeline {
                    Button { generateOutline() } label: {
                        Label(L10n.ClipDetail.outlineGenerate, systemImage: "sparkles")
                    }
                } else {
                    // A flat `.txt` transcript (import, or an ASR provider with
                    // no segment timings) can't support chapters — every one
                    // would start at zero. Say that instead of offering a
                    // button that can only fail.
                    Text(L10n.ClipDetail.outlineNoTimeline)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(chapters) { chapter in
                    chapterRow(chapter)
                }
            }
        } header: {
            HStack {
                Text(L10n.ClipDetail.outline)
                Spacer()
                if !chapters.isEmpty, activeJob(.outline) == nil {
                    Button { generateOutline() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.ClipDetail.outlineRegenerate)
                }
            }
        } footer: {
            if chapters.isEmpty, hasTimeline {
                Text(L10n.ClipDetail.outlineHint)
            }
        }
    }

    /// Per-segment timings exist — the precondition for a chapter list.
    private var hasTimeline: Bool {
        !(transcript?.segments.isEmpty ?? true)
    }

    /// The chapter the playhead is currently inside. `nil` while stopped at 0,
    /// so nothing looks "current" before playback starts.
    private var activeChapterStart: Double? {
        guard player.currentTime > 0 else { return nil }
        return chapters.last { $0.start <= player.currentTime }?.start
    }

    private func chapterRow(_ chapter: ClipChapter) -> some View {
        let isActive = activeChapterStart == chapter.start
        return Button {
            guard let url = item.url else { return }
            // `load` is a no-op on the same URL (see `marksSection`).
            player.load(url)
            player.seek(to: chapter.start)
            player.play()
        } label: {
            HStack(spacing: 12) {
                Text(ClockLabel.mmss(chapter.start))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(isActive ? Color.appAccent : Color.secondary)
                    .frame(minWidth: 44, alignment: .leading)
                Text(chapter.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func generateOutline() {
        guard hasTimeline else { return }
        jobs.enqueue(Job.outline(clip: item.name))
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
                if doc.segments.isEmpty {
                    Text(transcriptPreview(doc))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else {
                    transcriptSearchBar(doc)
                    // ★ 2026-10-23 ("查看完整转录不要收纳直接在当前那个页面就可以"):
                    //   the whole transcript, right here. The playback window
                    //   (four rows around the playhead) and the separate
                    //   full-transcript push are gone — a Form row list is lazy,
                    //   so an hour of speech costs nothing to show.
                    transcriptRows(doc)
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

    /// Index of the segment playing right now (`nil` before playback starts).
    private func activeSegmentIndex(_ segments: [AsrSegment]) -> Int? {
        guard !segments.isEmpty, player.currentTime > 0 else { return nil }
        return segments.lastIndex { $0.start <= player.currentTime }
    }

    // MARK: transcript search & speaker filter (★ 2026-10-19, DingTalk parity)

    /// Search field + speaker chips. Hidden for single-speaker short transcripts where
    /// there is nothing to find faster than reading.
    @ViewBuilder
    private func transcriptSearchBar(_ doc: TranscriptDocument) -> some View {
        if doc.segments.count > 1 {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.ClipDetail.searchTranscript, text: $transcriptQuery)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .autocorrectionDisabled()
                if !transcriptQuery.isEmpty {
                    Button {
                        transcriptQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if distinctSpeakers(doc.segments).count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        speakerChip(nil, L10n.ClipDetail.speakerAll)
                        ForEach(distinctSpeakers(doc.segments), id: \.self) { speaker in
                            speakerChip(speaker, nil)
                        }
                        // ★ 2026-10-22 ("还要支持修改说话人的名称"): the chips are the
                        // only place speakers are named, so the rename entry belongs
                        // at the end of them — right where the user notices "说话人 2"
                        // is not a person's name.
                        Button {
                            showSpeakerEditor = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "pencil").font(.caption2)
                                Text(L10n.ClipDetail.editSpeakerNames).font(.caption)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.appAccent.opacity(0.12)))
                            .foregroundStyle(Color.appAccent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// While searching or filtering: all matching lines (highlighted, capped) with tap-to-seek;
    /// otherwise the playback-following window.
    @ViewBuilder
    private func transcriptRows(_ doc: TranscriptDocument) -> some View {
        let isSearching = !transcriptQuery.isEmpty || speakerFilter != nil
        if isSearching {
            let matches = doc.segments.filter { segment in
                (speakerFilter == nil || segment.speaker == speakerFilter)
                    && (transcriptQuery.isEmpty || segment.text.localizedCaseInsensitiveContains(transcriptQuery))
            }
            if matches.isEmpty {
                Text(L10n.ClipDetail.noTranscriptMatch)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matches.prefix(40), id: \.start) { seg in
                    TranscriptSegmentRow(
                        segment: seg,
                        isActive: activeSegmentIndex(doc.segments).map { doc.segments[$0].start == seg.start } ?? false,
                        highlight: transcriptQuery.isEmpty ? nil : transcriptQuery,
                        speakerNames: speakerMap
                    ) {
                        player.seek(to: max(0, seg.start - 0.3))
                        if !player.isPlaying { player.play() }
                    }
                }
                if matches.count > 40 {
                    Text("+\(matches.count - 40)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            // ★ 2026-10-23 ("查看完整转录不要收纳…"): the full list now lives on
            // this page (the window + push-in page are gone), so this is every
            // segment, in order. Still tap-to-seek.
            ForEach(doc.segments, id: \.start) { seg in
                TranscriptSegmentRow(
                    segment: seg,
                    isActive: activeSegmentIndex(doc.segments).map { doc.segments[$0].start == seg.start } ?? false,
                    speakerNames: speakerMap
                ) {
                    player.seek(to: max(0, seg.start - 0.3))
                    if !player.isPlaying { player.play() }
                }
            }
        }
    }

    private func distinctSpeakers(_ segments: [AsrSegment]) -> [String] {
        var seen: [String] = []
        for segment in segments {
            // ★ 2026-10-26: `mark` rows are bookmarks, not a speaker — they
            // must not appear in the speaker chips / rename sheet.
            guard let speaker = segment.speaker, !speaker.isEmpty, speaker != "mark" else { continue }
            if !seen.contains(speaker) { seen.append(speaker) }
        }
        return seen
    }

    private func speakerChip(_ value: String?, _ label: String?) -> some View {
        let selected = speakerFilter == value
        // Renamed speakers keep their **id** as the filter key (the segment field
        // never changes) and only the visible text is the user's name.
        let resolved = label
            ?? value.map { speakerStore.display($0, clip: item.name) }
        return Button {
            speakerFilter = value
        } label: {
            Text(resolved ?? L10n.ClipDetail.speakerAll)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(selected ? Color.appAccent.opacity(0.18) : Color(uiColor: .secondarySystemBackground))
                )
                .foregroundStyle(selected ? Color.appAccent : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    /// Distinct speaker ids in first-appearance order, with their line counts —
    /// the rename sheet shows the counts because "which one is speaker 2?" is the
    /// actual question when four people were in the room.
    private func speakerRoster(_ segments: [AsrSegment]) -> [(id: String, lines: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for segment in segments {
            // ★ 2026-10-26: `mark` rows are bookmarks, not a speaker (see
            // `distinctSpeakers`).
            guard let speaker = segment.speaker, !speaker.isEmpty, speaker != "mark" else { continue }
            if counts[speaker] == nil { order.append(speaker) }
            counts[speaker, default: 0] += 1
        }
        return order.map { (id: $0, lines: counts[$0] ?? 0) }
    }

    /// Raw id → display name, for the rows / export / AI context.
    private var speakerMap: [String: String] {
        speakerStore.names(for: item.name)
    }

    /// Everything the in-page AI Q&A may read: the summary plus the timestamped transcript.
    /// Capped so a three-hour recording still fits one request — the tail of a long meeting is
    /// the part a summary already covers best.
    private var aiContext: String? {
        var parts: [String] = []
        if let summary, !summary.isEmpty {
            parts.append("SUMMARY\n" + String(summary.prefix(6_000)))
        }
        if let transcript {
            let body: String
            if transcript.segments.isEmpty {
                body = transcript.text
            } else {
                body = transcript.segments
                    .map { seg in
                        // Renamed speakers go into the AI context too — otherwise the
                        // answers keep saying "说话人 1" right after the user fixed it.
                        let who = seg.speaker.flatMap { id -> String? in
                            guard !id.isEmpty else { return nil }
                            let named = speakerMap[id].flatMap { $0.isEmpty ? nil : $0 } ?? id
                            return "\(named): "
                        }
                        return "[\(ClockLabel.mmss(seg.start))] " + (who ?? "") + seg.text
                    }
                    .joined(separator: "\n")
            }
            parts.append("TRANSCRIPT\n" + String(body.prefix(12_000)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: To-do list (bottom of the 笔记 tab)

    /// ★ 2026-10-23 ("待办清单在底部即可"): the to-do list lives at the **bottom of
    /// the 笔记 tab** — not its own tab (that was 136's removal, reverted on user
    /// feedback), and not Plaud-strict either. Action items lifted from the
    /// markdown of **all** note pages, so a 待办清单（Plaud） generated page lands
    /// here too. An honest empty state when no page has such a section.
    @ViewBuilder
    private var todoListSection: some View {
        Section {
            let todos = pages
                .compactMap { NotePages.text(of: $0, for: item.name) }
                .flatMap { TodoExtract.fromSummary($0) }
            if !todos.isEmpty {
                // ★ 2026-10-23: checklist rows with a tap-to-strike circle.
                TodoChecklistView(blocks: todos, recordingName: item.name)
            } else if !pages.isEmpty {
                Text(L10n.ClipDetail.todosEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if transcript != nil {
                Text(L10n.ClipDetail.todosNeedSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.ClipDetail.transcribeFirst)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(L10n.ClipDetail.tabTodos)
        }
    }

    private func triggerTranscribe(locales: [String]?) {
        // ★ 2026-10-23: a re-run invalidates the outline — its timestamps were
        // derived from the *previous* ASR output, and after this run they point
        // at the wrong words. Dropping it means the user sees "生成大纲" again
        // instead of a chapter list that silently lies.
        ClipChapterStore.delete(for: item.name)
        chapters = []
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
    private static func textForSummarization(_ doc: TranscriptDocument,
                                             speakerNames: [String: String] = [:]) -> String {
        JobRunners.summarizableText(text: doc.text,
                                    segments: doc.segments,
                                    speakerNames: speakerNames)
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
                SummaryFullView(
                    text: translatedSummary!,
                    posterTitle: item.customTitle ?? item.name,
                    posterDate: item.modifiedAt,
                    posterDuration: item.duration
                )
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

    /// The summarize job running / failed / finished for the **selected page** —
    /// pages run independently, so the status rows must follow the chip, not the clip.
    private func summarizeJob(_ pick: (Job) -> Bool) -> Job? {
        jobs.jobs.first {
            $0.clipName == item.name && $0.kind == .summarize
                && ($0.pageID ?? NotePage.primaryID) == selectedPageID
                && pick($0)
        }
    }

    /// Plaud's 「总结 ▾ | 权力动态 | +」 row: one chip per note page, long-press for
    /// 更换模板 / 删除此页, "+" to generate another page from any template.
    private var pageChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pages) { page in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedPageID = page.id
                        }
                        loadSelectedPageText()
                    } label: {
                        // ★ 2026-10-23 ("顶部摘要标签需要跟随当前设置的语言"):
                        //   the manifest stores the template's canonical (English)
                        //   name, but the chip must speak the UI's language —
                        //   "Quick Summary" reads as 总结 here, exactly like the
                        //   picker does. Custom templates keep their own name.
                        Text(SummarizeTemplate.localizedTemplateName(page.title))
                            .font(.footnote.weight(page.id == selectedPageID ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(page.id == selectedPageID
                                               ? Color.accentColor.opacity(0.16)
                                               : Color.secondary.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            tapSummarize(pageID: page.id)
                        } label: {
                            Label(L10n.ClipDetail.noteChangeTemplate,
                                  systemImage: "arrow.trianglehead.2.counterclockwise")
                        }
                        if page.id != NotePage.primaryID {
                            Button(role: .destructive) {
                                deletePageAlert = page
                            } label: {
                                Label(L10n.ClipDetail.noteDeletePage, systemImage: "trash")
                            }
                        }
                    }
                }
                if transcript != nil {
                    Button {
                        addPage()
                    } label: {
                        Image(systemName: "plus")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.ClipDetail.noteAddPage)
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
    }

    @ViewBuilder
    private var summarySection: some View {
        Section {
            // ★ 2026-10-23 ("页面模板"): the chip row always shows once a transcript
            //   exists — even with zero pages it offers "+", Plaud's way into a second
            //   note without leaving the recording.
            if transcript != nil { pageChips }
            // The summary itself plus its translation — both kinds produce "summary section content", so they sit together.
            //
            // ★ The most important case here: the user **picked a template in the summary sheet and then
            //   swiped it away** (exactly the usage the twelfth revision set out to support). Without these two lines,
            //   they'd return to the detail page to find only the "Generate summary" button, with no sign a job is running.
            if let job = summarizeJob({ $0.finishedAt == nil }) {
                runningRow(job, L10n.Summarize.summarizing)
            } else if let job = summarizeJob({ $0.finishedAt != nil && $0.lastError != nil }) {
                failedRow(job)
            }
            // Summary translation is a primary-page feature (the job reads the
            // classic `.summary.md` file) — offered only while that page is shown.
            if selectedPageID == NotePage.primaryID,
               let job = activeJob(.translate, target: "summary") {
                runningRow(job, L10n.ClipDetail.translating)
            } else if selectedPageID == NotePage.primaryID,
                      let job = failedJob(.translate, target: "summary") {
                failedRow(job)
            }
            if let text = currentPageText {
                // ★ 2026-10-23 ("参考一下页面布局跟结构", Plaud 4027): their note
                //   page opens with a centred "内容由 AI 生成，仅供参考" line.
                Text(L10n.ClipDetail.aiGeneratedNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)

                if isEditingSummary {
                    summaryEditor
                } else {
                    // ★ (2026-10-19) The summary tab is the "AI minutes" reading surface, so the
                    //   whole document renders inline (headings / bullets, no truncation) instead of
                    //   a 14-block teaser behind a link.
                    // ★ 2026-10-23 ("笔记也是，无需收纳"): the "view full summary"
                    //   push is gone — this page IS the full document.
                    MarkdownBlocksView(blocks: MarkdownBlocks.parse(text))
                }

                // ★ 2026-10-23 ("参考一下页面布局跟结构", Plaud 4028/4025): the mind
                //   map is an embedded preview card above the ask box — a white
                //   card with the map drawn small, one tap opens the real thing.
                //   It used to be a plain "思维导图" row, which gave no hint of
                //   what was inside.
                if !isEditingSummary, MarkdownOutline.parse(text) != nil {
                    MindMapPreviewCard(
                        markdown: text,
                        title: item.customTitle ?? item.name
                    ) {
                        showMindMap = true
                    }
                }
            } else if transcript != nil {
                Button {
                    tapSummarize(pageID: selectedPageID)
                } label: {
                    Label(L10n.ClipDetail.summarize, systemImage: "sparkles")
                }
            } else {
                Text(L10n.ClipDetail.transcribeFirst)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            // Result note (fallback channel / chunked / truncated). Placed after the content — it describes
            // the content above. Scoped to the selected page for the same reason as the status rows.
            if let job = summarizeJob({ $0.finishedAt != nil && $0.lastError == nil }) { notesRow(job) }
            if selectedPageID == NotePage.primaryID,
               let job = lastFinishedJob(.translate, target: "summary") { notesRow(job) }
        } header: {
            HStack {
                Text(L10n.ClipDetail.summary)
                Spacer()
                if currentPageText != nil {
                    // ★ 2026-10-23 ("生成的摘要需要能够支持编辑"): one pencil next
                    // to 重新生成 — tap to edit, save writes the file back.
                    Button {
                        editedSummary = currentPageText ?? ""
                        isEditingSummary = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .disabled(isEditingSummary)
                    if selectedPageID == NotePage.primaryID {
                        Button { tapTranslate(.summary) } label: {
                            Image(systemName: "character.bubble")
                                .font(.caption)
                        }
                        .disabled(translatingSummary)
                    }
                    if transcript != nil {
                        Button { tapSummarize(pageID: selectedPageID) } label: {
                            Image(systemName: "arrow.trianglehead.2.counterclockwise")
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }

    /// The in-place markdown editor. Plain `TextEditor` on purpose — the text
    /// is markdown, and users edit what the note actually is. Saved to the
    /// page's own file; nothing else needs notifying because every reader
    /// (detail page, poster, mind map, export) reads that same file.
    private var summaryEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextEditor(text: $editedSummary)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 320)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
            HStack {
                Button(L10n.Common.cancel) {
                    isEditingSummary = false
                    editedSummary = ""
                }
                Spacer()
                Button {
                    saveSummaryEdit()
                } label: {
                    Label(L10n.Common.done, systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func saveSummaryEdit() {
        let text = editedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let url = StorageLocations.notePageURL(for: item.name, pageID: selectedPageID)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return
        }
        isEditingSummary = false
        editedSummary = ""
        if selectedPageID == NotePage.primaryID {
            loadSummary()
        } else {
            loadSelectedPageText()
        }
    }

    /// Open the template sheet for a **note page** (default: the primary page —
    /// every pre-existing call path lands here).
    private func tapSummarize(pageID: String = NotePage.primaryID) {
        let providers = env.config.config.llmProviders
        if providers.primary == nil || providers.primary!.isEmpty || providers.configuredProviders.isEmpty {
            showNoProvider = true
        } else {
            summarizePageID = pageID
            showSummarize = true
        }
    }

    /// The "+" chip: generate one more note page from a fresh id. The template
    /// (and language) are picked in the sheet; the manifest entry appears when
    /// the job's artifact lands — never before there is something to show.
    private func addPage() {
        let providers = env.config.config.llmProviders
        guard providers.primary != nil, !(providers.primary ?? "").isEmpty,
              !providers.configuredProviders.isEmpty else {
            showNoProvider = true
            return
        }
        addPageID = UUID().uuidString
        summarizePageID = addPageID
        showAddPage = true
    }

    /// Remove a note page (manifest + body file) and keep the selection valid.
    private func deletePage(_ page: NotePage) {
        pages = NotePages.remove(id: page.id, for: item.name)
        if selectedPageID == page.id {
            selectedPageID = pages.first?.id ?? NotePage.primaryID
        }
        loadSelectedPageText()
    }

    /// Refresh the on-screen page body after any manifest/selection change.
    private func loadSelectedPageText() {
        if selectedPageID == NotePage.primaryID {
            loadSummary()
        } else if let page = pages.first(where: { $0.id == selectedPageID }) {
            pageText = NotePages.text(of: page, for: item.name)
        } else {
            pageText = nil
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

    /// Inline progress for a running / failed export. Every other export action now lives in
    /// the top-right menu; this row stays so progress is visible without opening it.
    @ViewBuilder
    private var exportStatusSection: some View {
        Section {
            if let job = activeJob(.export) {
                runningRow(job, L10n.ClipDetail.exporting)
            } else if let job = failedJob(.export) {
                failedRow(job)
            }
        } header: {
            Text(L10n.ClipDetail.export)
        }
    }

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

    /// ★ 任务二 (2026-10-22): document formats ride the same export job id
    /// ("export:<clip>") — only the last-picked format is kept, matching the
    /// audio behaviour and the single-slot staging directory.
    private func enqueueDocumentExport(_ format: String) {
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
        // The "mark" dots belong to the audio timeline — a marker pointing at a deleted recording is
        // noise. `move` skips non-existent paths, so this needs no existence check, and putting it in
        // the same group is what makes restore bring the marks back with the clip.
        urls.append(A1MarkStore.sidecarURLForTrash(clipBase: item.base))
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
        // ★ 2026-10-23 ("页面模板"): the primary page also leaves the manifest —
        //   other pages are untouched (they have their own chips and delete path).
        pages = NotePages.remove(id: NotePage.primaryID, for: item.name)
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
                            .fill(Color.appAccent.opacity(0.1))
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
    /// The detail page's controller — shared so a tap here keeps one playback session
    /// (★ 2026-10-19: this page used to be a dead wall of text).
    @ObservedObject var player: AudioPlaybackController
    /// ★ 2026-10-22: the user's speaker names (see `SpeakerNameStore`), so the
    /// full-screen page and the text it shares say the same names as the rows behind it.
    var speakerNames: [String: String] = [:]
    @State private var showShareSheet = false

    private var plainText: String {
        if document.segments.isEmpty { return document.text }
        return document.segments.map { seg in
            var line = ""
            if let speaker = seg.speaker, !speaker.isEmpty {
                let name = speakerNames[speaker].flatMap { $0.isEmpty ? nil : $0 }
                    ?? L10n.ClipDetail.speaker(speaker)
                line += "[\(name)] "
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(document.segments.enumerated()), id: \.offset) { index, seg in
                                TranscriptSegmentRow(segment: seg,
                                                     isActive: activeIndex == index,
                                                     speakerNames: speakerNames) {
                                    player.seek(to: max(0, seg.start - 0.3))
                                    if !player.isPlaying { player.play() }
                                }
                                .id(index)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    // Follow the audio while it plays, so the page never drifts away from what
                    // the user is hearing.
                    .onChange(of: activeIndex) { newValue in
                        guard let newValue, player.isPlaying else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
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

    /// The segment under the playhead, driving both the highlight and the auto-scroll.
    private var activeIndex: Int? {
        guard player.currentTime > 0, !document.segments.isEmpty else { return nil }
        return document.segments.lastIndex { $0.start <= player.currentTime }
    }
}

// MARK: - Full-screen summary view

struct SummaryFullView: View {
    let text: String
    /// Poster header metadata (image-text share). Optional — the poster
    /// collapses missing rows, so the translated-summary entry can skip them.
    var posterTitle: String? = nil
    var posterDate: Date? = nil
    var posterDuration: Double? = nil
    @State private var showRaw = false
    @State private var showShareSheet = false
    @State private var showMindMap = false
    @State private var showPoster = false

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
                        showPoster = true
                    } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                    }
                    .accessibilityLabel(L10n.ClipDetail.shareAsImage)
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
        .sheet(isPresented: $showPoster) {
            SummaryPosterView(
                markdown: text,
                title: posterTitle,
                date: posterDate,
                duration: posterDuration
            )
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
