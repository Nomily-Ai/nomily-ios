import SwiftUI

struct SummarizeSheet: View {
    /// The transcript body of this recording.
    ///
    /// ⚠️ After the twelfth revision **it no longer feeds the model** — the job is read from disk by `JobRunners`
    ///    (see its `transcriptText(for:)`; the text both paths feed in comes from the same source, verbatim).
    ///    It's kept because it still has one real use: call sites rely on it to decide "does this recording actually have
    ///    a transcript", and `use(_:)` uses it to block "empty transcript" before enqueueing.
    let transcriptText: String
    let audioName: String
    /// Which **note page** this sheet writes (`NotePage.id`).
    ///
    /// ★ 2026-10-23 ("页面模板", Plaud parity): defaults to the classic single
    /// summary — every call site that doesn't care keeps compiling unchanged.
    /// The detail page passes an existing id to re-generate a page ("更换模板")
    /// or a fresh one when adding a page (the "+" chip).
    var pageID: String = NotePage.primaryID
    let onComplete: (String) -> Void

    @EnvironmentObject private var env: AppEnvironment
    /// The summary persistence queue. See the same-named field in `ClipDetailView` for why it's injected separately.
    @EnvironmentObject private var jobs: JobQueue
    @Environment(\.dismiss) private var dismiss
    @StateObject private var templateStore = SummarizeTemplateStore()
    @StateObject private var languages = LanguageService()
    @State private var search = ""
    @State private var selected: SummarizeTemplate?
    /// ★ Seventh revision, 2026-10-15: the template currently being viewed in the **overview**.
    ///
    /// When non-nil, the picker page shows the overview (name / category / description / full prompt / one primary button)
    /// instead of the grid — matching the user's "tapping in gives an overall overview".
    ///
    /// Why not push in with a `NavigationLink`: this page swaps wholesale via
    /// `Group { switch summarizeState }`, so the layer pushed on top would
    /// be **swapped out along with it** the moment the state moves to `.running`, leaving an unpredictable stack. Switching within the same layer
    /// has none of these problems; entering and leaving stay under control.
    @State private var previewing: SummarizeTemplate?
    @State private var summarizeState: SummarizeState = .picking
    @State private var result = ""
    @State private var outputLangCode: String = ""
    @State private var showLangPicker = false
    /// ★ Twelfth revision, 2026-10-16: this job's id in that queue (`summarize:<audioName>`).
    /// Non-nil = already enqueued; from then on the UI only **observes** it and never runs it itself.
    ///
    /// The previous version's three `@State` properties — `pendingTitle` / `summarizeTask` / `workingProvider` —
    /// are all gone: persisting the summary and title moved into `JobRunners.summarize`,
    /// and "which channel actually did the work" is persisted along with `Job.notes`. Every piece of in-memory state left here
    /// is something that gets lost when the app is killed — and lies while it lasts.
    @State private var jobID: String?
    /// ★ 2026-10-23 ("还支持…自动化生成根据里面内容进行选择合适模板", Plaud 4033):
    /// the sheet opens on a **two-mode panel** instead of the template grid —
    /// 自动生成 (app picks the matching template from the transcript) or
    /// 自定义生成 (template / output language / model, then 立即生成).
    @State private var generateMode: GenerateMode = .auto
    @State private var showTemplateList = false
    /// Which of the picker's three spaces is showing (★ 2026-10-23).
    @State private var space: TemplateSpace = .mine
    @State private var showCreateTemplate = false
    /// A custom template being edited from 我的空间 (same editor the settings
    /// page uses — see `TemplateEditorView`).
    @State private var editingTemplate: SummarizeTemplate?

    private enum GenerateMode { case auto, custom }
    /// The provider said it stopped because it hit the output cap. The text
    /// is real but cut off — say so instead of presenting it as finished.
    /// This one is **read back from the ledger** (`Job.wasTruncated`), no longer maintained by a local variable.
    @State private var wasTruncated = false
    /// The user-facing note: fallback took over / chunking was used. **Must be shown** —
    /// the user set A but B generated the result; without an explanation it becomes "is it even using my configuration?"
    /// Also read back from the ledger (`Job.notes`).
    @State private var notices: [String] = []
    /// Chunk progress. `(completed, total chunks)`; nil for a single chunk.
    @State private var chunkProgress: (done: Int, total: Int)?
    /// The primary channel is unusable but a fallback is available — spell it out on the page before the work starts.
    @State private var preflightWarning: String?

    private enum SummarizeState {
        case picking
        case running
        case done
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch summarizeState {
                case .picking:
                    generatePanel
                case .running:
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text(L10n.Summarize.summarizingWith(activeProviderLabel))
                            .foregroundStyle(.secondary)
                        // Show "which chunk" while chunking. A long transcription runs for several minutes,
                        // and an endlessly spinning spinner vs. a number that changes feel completely different.
                        if let chunkProgress {
                            Text(L10n.Summarize.chunkProgress(chunkProgress.done, chunkProgress.total))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if let t = selected {
                            Text(t.localizedName)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        // ★ Twelfth revision, 2026-10-16: this page can now be **dismissed**, and dismissing it
                        //   doesn't stop the run. This must be spelled out — the previous version's
                        //   "Cancel" button made people think closing would kill the job, so all they could do was wait.
                        Divider().padding(.horizontal, 48)
                        Text(L10n.Jobs.canLeaveHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button(L10n.Common.close) { dismiss() }
                            .buttonStyle(.bordered)
                        // ★ Thirteenth revision, 2026-10-20: a real cancel lives here again — the user's exact
                        //   words: "生成摘要不能中途取消". Close (above) only leaves the page; this one stops the
                        //   job via `JobQueue.cancel(id:)`, which interrupts the runner's Task (URLSession
                        //   requests break with it) and marks the ledger "finished with no error" — the same
                        //   entry point TaskCenterView has always had, one tap away instead of a detour.
                        //   After cancelling, dismiss too: there's nothing left to wait on. If the summary file
                        //   somehow exists, `observeJob → adoptResult` still reads it back; if it doesn't
                        //   (the normal case), the detail page simply shows no summary and the user can rerun.
                        Button(L10n.Common.cancel, role: .destructive) {
                            if let jobID { jobs.cancel(id: jobID) }
                            dismiss()
                        }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .done:
                    VStack(spacing: 0) {
                        if wasTruncated {
                            Label(L10n.Summarize.truncatedWarning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                .background(Color.orange.opacity(0.12))
                        }
                        // ★ Fallback / chunking note. Non-blocking, but **must be shown**:
                        //   the user set Open Router, but the result was actually produced by the local Ollama
                        //   grinding away — not saying so amounts to hiding the configuration state from the user.
                        if !notices.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(notices, id: \.self) { note in
                                    Label(note, systemImage: "info.circle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.12))
                        }
                        MarkdownView(markdown: result)
                    }
                case .failed(let msg):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(msg)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button(L10n.Common.tryAgain) { summarizeState = .picking }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // ★ Twelfth revision: this button **does not cancel the job**.
                    //
                    // The user's exact request was "exit to the background first and check when it's done" —
                    // so "leave this page" and "don't want this job" have to be two separate things.
                    // The former is this button (and the swipe-down gesture); the latter used to live only on the
                    // background tasks page (`TaskCenterView`) — since the thirteenth revision the running page
                    // also carries a destructive Cancel next to Close, but this button still only *leaves*.
                    //
                    // The cost of conflating them was concrete: the old button said "Cancel", so users wanting to leave feared
                    // tapping would stop everything and just sat there watching the spinner — and the whole reason this feature exists
                    // is so they never have to.
                    Button(closeLabel) { dismiss() }
                }
                if case .done = summarizeState {
                    ToolbarItem(placement: .confirmationAction) {
                        // The output is already persisted inside the runner (that's the key of the twelfth revision: a job
                        // must land on its own, otherwise "come back after it finished" has nothing to look at). Here it's just
                        // "I've seen it, we're done".
                        Button(L10n.Common.done) { dismiss() }
                    }
                }
            }
            .task {
                languages.fetchTargetLanguagesIfNeeded()
                if let saved = env.config.config.lastSummaryLang {
                    outputLangCode = saved
                }
            }
            .sheet(isPresented: $showLangPicker) {
                LanguagePickerSheet(
                    title: L10n.Summarize.outputLanguage,
                    languages: languages.targetLanguages,
                    defaultOption: L10n.Summarize.sameAsTranscript
                ) { lang in
                    showLangPicker = false
                    outputLangCode = lang.code
                    env.config.config.lastSummaryLang = lang.code
                    env.config.scheduleSave()
                }
            }
        }
        // ★ Twelfth revision: this used to carry `.interactiveDismissDisabled(dismissGuard)`
        //   — blocking the swipe-down dismissal while running (else one swipe cancels it, w6estkf),
        //   and also once generated but unsaved (else swiping away silently discards it, g17h5nk).
        //
        // Both of those reasons **no longer hold under this model**:
        //   · swiping away while it runs, the job keeps running (it's queued in that persisted queue);
        //   · the generated output is already on disk — there is no "unsaved" state.
        // So the blocking is removed entirely, replaced with watching the queue to see where this job has gotten to.
        .onChange(of: jobs.jobs) { _ in observeJob() }
        .onAppear { observeJob() }
    }

    /// What the close button says.
    ///
    /// "Cancel" on the template-picking page (nothing has actually happened yet); "Close" once the run has started
    /// — by then "Cancel" would be a lie; tapping it doesn't stop the job.
    private var closeLabel: String {
        if case .running = summarizeState { return L10n.Common.close }
        return L10n.Common.cancel
    }

    private var navTitle: String {
        switch summarizeState {
        case .picking: return L10n.Summarize.generateNotes
        case .running: return L10n.Summarize.summarizing
        case .done: return L10n.ClipDetail.summary
        case .failed: return L10n.Summarize.error
        }
    }

    // MARK: - Generate panel (★ 2026-10-23, Plaud 4033)

    /// 自动生成 / 自定义生成, then 立即生成 — Plaud's sheet, same order.
    private var generatePanel: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let preflightWarning { preflightBanner(preflightWarning) }

                modeCard(
                    title: L10n.Summarize.autoGenerate,
                    subtitle: L10n.Summarize.autoGenerateDesc,
                    icon: "sparkles",
                    tint: Color(red: 0.45, green: 0.45, blue: 0.95),
                    titleIsPlain: false,
                    selected: generateMode == .auto
                ) { generateMode = .auto }

                modeCard(
                    title: L10n.Summarize.customGenerate,
                    subtitle: nil,
                    icon: "wand.and.stars",
                    tint: .primary,
                    titleIsPlain: true,
                    selected: generateMode == .custom
                ) { generateMode = .custom }

                if generateMode == .custom { customOptions }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) { generateBar }
        .sheet(isPresented: $showTemplateList) {
            NavigationStack {
                templatePicker
                    .navigationTitle(L10n.Summarize.chooseTemplate)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.Common.cancel) { showTemplateList = false }
                        }
                    }
            }
        }
    }

    private func modeCard(
        title: String,
        subtitle: String?,
        icon: String,
        tint: Color,
        titleIsPlain: Bool,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(selected ? .semibold : .regular))
                        // `Color` equality needs iOS 17; a flag keeps this on 16.
                        .foregroundStyle(titleIsPlain ? Color.primary : tint)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(selected ? Color.primary : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The 自定义生成 rows: 模板 / 输出语言 / AI 模型. Only rows that do
    /// something appear — there is no speaker-diarization switch in this app,
    /// so Plaud's "自动标注说话人 Beta" is deliberately absent rather than faked.
    private var customOptions: some View {
        VStack(spacing: 0) {
            optionRow(
                L10n.Summarize.templateRow,
                value: selected?.localizedName ?? L10n.Summarize.chooseTemplate,
                chevron: true
            ) { showTemplateList = true }

            Divider().padding(.leading, 16)

            optionRow(L10n.Summarize.outputLanguage, value: currentLangName, chevron: true) {
                showLangPicker = true
            }

            Divider().padding(.leading, 16)

            // ★ 2026-10-23 ("自定义生成里面的 ai 模型支持修改"): the row is a real
            // picker now — one tap per configured channel, checkmark on the
            // current primary. Changing it here is the same act as changing it
            // in Settings (same `llmProviders.primary` field), and this run
            // immediately uses it.
            Menu {
                ForEach(env.config.config.llmProviders.configuredProviders, id: \.key) { provider in
                    Button {
                        env.config.config.llmProviders.primary = provider.key
                        env.config.scheduleSave()
                    } label: {
                        if provider.key == env.config.config.llmProviders.primary {
                            Label(provider.label, systemImage: "checkmark")
                        } else {
                            Text(provider.label)
                        }
                    }
                }
            } label: {
                optionRow(L10n.Summarize.aiModel, value: activeProviderLabel, chevron: true) {}
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private func optionRow(
        _ title: String,
        value: String,
        chevron: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!chevron && value.isEmpty)
    }

    private var generateBar: some View {
        Button {
            generateNow()
        } label: {
            Text(L10n.Summarize.generateNow)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// 自动 = let `AutoTemplatePicker` read the transcript; 自定义 = the chosen
    /// template, or open the list when nothing is chosen yet.
    private func generateNow() {
        switch generateMode {
        case .auto:
            guard let picked = AutoTemplatePicker.pick(
                transcript: transcriptText,
                from: templateStore.templates
            ) else {
                summarizeState = .failed(L10n.Summarize.noMatchingTemplates)
                return
            }
            selected = picked
            use(picked)
        case .custom:
            if let selected {
                use(selected)
            } else {
                showTemplateList = true
            }
        }
    }

    private func preflightBanner(_ warning: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            if let fix = LLMCompletionService.suggestedPrimary(env.config.config) {
                Button {
                    adoptFallbackAsPrimary(fix)
                } label: {
                    Text(L10n.LLM.adoptAsPrimary(LLMCompletionService.providerLabel(fix)))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Template picker

    private var currentLangName: String {
        if outputLangCode.isEmpty { return L10n.Summarize.sameAsTranscript }
        return languages.targetLanguages.first { $0.code == outputLangCode }?.name ?? outputLangCode
    }

    // MARK: - Template spaces (★ 2026-10-23, Plaud 4039 / 4040 / 4041)
    //
    // Plaud splits "选择模板" into three spaces and the user asked for the same:
    //   我的空间 — templates you made (+ create), language and model rows
    //   推荐     — a curated two-block shelf ("他人常用" / "灵感推荐")
    //   探索     — the full library, grouped by category
    //
    // Honest difference from Plaud's screens: their 推荐 cards carry other
    // people's names and usage counts. We have no such telemetry, so every
    // card credits "Nomily" instead of inventing authors or counts.

    private enum TemplateSpace: String, CaseIterable, Identifiable {
        case mine
        case recommended
        case explore

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mine: return L10n.Summarize.spaceMine
            case .recommended: return L10n.Summarize.spaceRecommended
            case .explore: return L10n.Summarize.spaceExplore
            }
        }
    }

    private var templatePicker: some View {
        Group {
            if let previewing {
                TemplateOverviewView(
                    template: previewing,
                    onUse: { use(previewing) },
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.18)) { self.previewing = nil }
                    }
                )
            } else {
                VStack(spacing: 0) {
                    // ★ Pre-flight health check. **Shown only on this page**, because it's only useful at the
                    //   "pick a template" moment: telling the user now that "the primary has no key and Ollama will serve as fallback"
                    //   lets them decide whether to go fix the key first or just run as-is.
                    //   Previously this situation only blew up as an English error message **after the run finished**.
                    if let preflightWarning { preflightBanner(preflightWarning) }
                    spaceBar
                    spaceContent
                }
                // Filtering applies to whichever space is on screen — the same
                // search bar Plaud puts over 探索.
                .searchable(text: $search, prompt: L10n.Summarize.searchTemplates)
                .safeAreaInset(edge: .bottom) { pickerGenerateBar }
            }
        }
        .onAppear {
            refreshPreflight()
            // ★ 2026-10-19 "Set as default": opening the sheet pre-selects the user's default template
            // instead of starting from scratch. If it is gone (deleted / language changed), stay silent on nil — no alert.
            if selected == nil,
               let key = env.config.config.summaryTemplateKey,
               let stored = templateStore.templates.first(where: { $0.storeKey == key }) {
                selected = stored
                // Land on the space that actually holds it, so the pre-selection
                // isn't invisible: a custom default lives in 我的空间, a built-in
                // one in 探索.
                space = stored.isBuiltIn ? .explore : .mine
            }
        }
        .sheet(isPresented: $showCreateTemplate) {
            TemplateEditorView(
                template: SummarizeTemplate(
                    category: templateStore.categories.first ?? "Custom",
                    name: "",
                    prompt: "",
                    isBuiltIn: false
                ),
                existingCategories: templateStore.categories
            ) { newTemplate in
                templateStore.templates.append(newTemplate)
                templateStore.save()
                selected = newTemplate
                space = .mine
            }
        }
        .sheet(item: $editingTemplate) { template in
            TemplateEditorView(
                template: template,
                existingCategories: templateStore.categories
            ) { updated in
                if let idx = templateStore.templates.firstIndex(where: { $0.id == updated.id }) {
                    templateStore.templates[idx] = updated
                    templateStore.save()
                    if selected?.id == updated.id { selected = updated }
                }
            }
        }
    }

    /// The three spaces, underlined like the detail page's 来源 | 笔记 tabs so
    /// the two pickers in the app feel like one product.
    private var spaceBar: some View {
        HStack(spacing: 0) {
            ForEach(TemplateSpace.allCases) { item in
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { space = item }
                } label: {
                    VStack(spacing: 5) {
                        Text(item.title)
                            .font(.system(size: 14, weight: space == item ? .semibold : .regular))
                            .foregroundStyle(space == item ? Color.primary : Color.secondary)
                        Capsule()
                            .fill(space == item ? Color.primary : Color.clear)
                            .frame(width: 18, height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(space == item ? [.isSelected] : [])
            }
        }
        .padding(.bottom, 2)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    @ViewBuilder
    private var spaceContent: some View {
        switch space {
        case .mine: mineSpace
        case .recommended: recommendedSpace
        case .explore: exploreSpace
        }
    }

    // MARK: 我的空间

    private var mineSpace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(L10n.Summarize.myTemplates, count: myTemplates.count)
                LazyVGrid(columns: spaceColumns, spacing: 10) {
                    ForEach(myTemplates) { template in
                        spaceCard(template)
                    }
                    // Plaud's dashed "创建模板" card — always present, even with
                    // zero templates, because it is the whole point of the space.
                    createTemplateCard
                }
                spaceOptions
                Text(L10n.Summarize.mineSpaceFooter)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    /// 语言 / AI 模型 — the same two bindings the 自定义生成 panel edits
    /// (output language and the global primary provider), repeated here because
    /// this is where the user is actually choosing *how* to generate.
    private var spaceOptions: some View {
        VStack(spacing: 0) {
            optionRow(L10n.Summarize.outputLanguage, value: currentLangName, chevron: true) {
                showLangPicker = true
            }
            Divider().padding(.leading, 16)
            Menu {
                ForEach(env.config.config.llmProviders.configuredProviders, id: \.key) { provider in
                    Button {
                        env.config.config.llmProviders.primary = provider.key
                        env.config.scheduleSave()
                    } label: {
                        if provider.key == env.config.config.llmProviders.primary {
                            Label(provider.label, systemImage: "checkmark")
                        } else {
                            Text(provider.label)
                        }
                    }
                }
            } label: {
                optionRow(L10n.Summarize.aiModel, value: activeProviderLabel, chevron: true) {}
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    // MARK: 推荐 / 探索

    private var recommendedSpace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                cardSection(L10n.Summarize.editorsPicks, templates: editorPicks)
                cardSection(L10n.Summarize.inspiration, templates: inspirationPicks)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var exploreSpace: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(exploreCategories, id: \.self) { category in
                    cardSection(
                        SummarizeTemplate.localizedCategoryName(category),
                        templates: exploreTemplates(in: category)
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func cardSection(_ title: String, templates: [SummarizeTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title, count: nil)
            LazyVGrid(columns: spaceColumns, spacing: 10) {
                ForEach(templates) { template in
                    spaceCard(template)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.title3.weight(.semibold))
            if let count {
                Text("\(count)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var spaceColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    // MARK: - Space content sources

    private var myTemplates: [SummarizeTemplate] {
        templateStore.templates.filter { !$0.isBuiltIn && matchesSearch($0) }
    }

    /// 编辑精选 — the short shelf we actually stand behind: the four Plaud-style
    /// daily drivers plus the formats most recordings fall into.
    private static let editorPickNames: [String] = [
        "Quick Summary", "Meeting Minutes", "Key Points", "To-Do List",
        "Formal Meeting Minutes", "BANT Customer Analysis", "Interview Summary", "Lecture Notes",
    ]

    /// 灵感推荐 — "you wouldn't think to look for these": formats that turn a
    /// recording into something other than prose.
    private static let inspirationNames: [String] = [
        "Key Data Points", "Q&A Format", "Brainstorm Synthesis",
        "Decision Log", "Daily Log", "Long Article to Slide Deck Outline",
    ]

    private var editorPicks: [SummarizeTemplate] {
        Self.editorPickNames.compactMap(template(named:)).filter(matchesSearch)
    }

    private var inspirationPicks: [SummarizeTemplate] {
        Self.inspirationNames.compactMap(template(named:)).filter(matchesSearch)
    }

    private func template(named name: String) -> SummarizeTemplate? {
        templateStore.templates.first { $0.name == name && $0.isBuiltIn }
    }

    /// Categories in the library's own order, empty ones dropped after search.
    private var exploreCategories: [String] {
        templateStore.categories.filter { !exploreTemplates(in: $0).isEmpty }
    }

    private func exploreTemplates(in category: String) -> [SummarizeTemplate] {
        templateStore.templates(in: category).filter(matchesSearch)
    }

    private func matchesSearch(_ template: SummarizeTemplate) -> Bool {
        guard !search.isEmpty else { return true }
        let q = search.lowercased()
        return template.name.lowercased().contains(q)
            || template.category.lowercased().contains(q)
            || (template.localizedSummary?.lowercased().contains(q) ?? false)
    }

    // MARK: - Cards

    /// One template card: icon block, name, one-line "what this is for", and the
    /// corner expand affordance that opens the full prompt (Plaud's ↗).
    ///
    /// Tap = select (the bottom bar then generates with it) — not "run
    /// immediately": the user is still choosing, and generating is a billable
    /// act that deserves its own tap.
    private func spaceCard(_ template: SummarizeTemplate) -> some View {
        let isSelected = selected?.storeKey == template.storeKey
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) { selected = template }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: template.effectiveIcon)
                        .font(.body)
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.appAccent.opacity(0.12))
                        )
                    Spacer(minLength: 0)
                    Button {
                        previewing = template
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                }
                Text(template.localizedName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                Text(template.pickerSubtitle(limit: 56))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(minHeight: 28, alignment: .top)
                HStack(spacing: 4) {
                    if !template.isBuiltIn {
                        Text(L10n.Summarize.customBadge)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.appAccent.opacity(0.16)))
                            .foregroundStyle(Color.appAccent)
                    }
                    Spacer(minLength: 0)
                    // Plaud prints the author here. We have no marketplace, so
                    // the honest answer is the product's own name.
                    Text("Nomily")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.appAccent : Color.primary.opacity(0.07),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !template.isBuiltIn {
                Button {
                    editingTemplate = template
                } label: {
                    Label(L10n.Common.edit, systemImage: "pencil")
                }
                Button(role: .destructive) {
                    templateStore.templates.removeAll { $0.id == template.id }
                    templateStore.save()
                    if selected?.id == template.id { selected = nil }
                } label: {
                    Label(L10n.Common.delete, systemImage: "trash")
                }
            }
        }
    }

    /// The dashed "+" card, Plaud style.
    private var createTemplateCard: some View {
        Button {
            showCreateTemplate = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
                    .foregroundStyle(Color.appAccent)
                Text(L10n.Summarize.createTemplate)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(0.18),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            )
        }
        .buttonStyle(.plain)
    }

    /// 生成笔记 — enabled once a card is selected. Uses `use(_:)` directly
    /// rather than `generateNow()`: the space picker *is* the custom path, so
    /// the auto-mode branch doesn't apply here.
    private var pickerGenerateBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                guard let selected else { return }
                showTemplateList = false
                use(selected)
            } label: {
                Text(L10n.Summarize.generateNotes)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selected == nil)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }


    /// Kick off the run. **Called only from the overview page** — the tile itself only handles "open the overview".
    ///
    /// Clear `previewing` in the same frame: if this run fails and the user taps "Retry" back into
    /// the picker page, they see the grid rather than the **previous template's overview**.
    ///
    /// ★ Twelfth revision, 2026-10-16: this no longer spawns its own `Task { await runSummarize }` — the job is handed to
    ///   `JobQueue`. The difference isn't "one extra hop"; it's **who holds it**: an in-memory
    ///   `Task` dies the moment the system ends the app, while a persisted job is still sitting in the queue the next day
    ///   waiting to be picked up by `resume()`.
    ///
    /// ⚠️ The prompt is finalized **at enqueue time** (`withLanguageInstruction` applied before storing),
    ///    not computed at run time. See `Job.prompt`: the job may only be picked up days later,
    ///    by which time the template may have been edited or deleted. A job's content must be frozen at the moment the user pressed
    ///    the button — including the output language they chose then.
    private func use(_ template: SummarizeTemplate) {
        selected = template
        previewing = nil
        // The previous run's result must be cleared: after a failure, going back to the picker and tapping again would first
        // flash the old summary if not cleared — looking like "the new run didn't take".
        result = ""
        wasTruncated = false
        notices = []
        chunkProgress = nil

        // An empty transcript is blocked before enqueueing. Letting it into the queue would waste a whole round (the runner can't find the source file,
        // throws `JobSourceMissing`, and the queue wipes it) — same outcome, but for those seconds
        // the UI spins and the user gets their hopes up.
        guard !transcriptText.isEmpty else {
            summarizeState = .failed(L10n.Jobs.sourceMissing(L10n.Jobs.sourceTranscript))
            return
        }

        let job = Job.summarize(
            clip: audioName,
            prompt: withLanguageInstruction(template.localizedPrompt),
            templateName: template.name,
            pageID: pageID
        )
        jobID = job.id
        summarizeState = .running
        jobs.enqueue(job)
    }

    // MARK: - Observing the queue

    private var isWaitingOnJob: Bool {
        if case .running = summarizeState { return true }
        return false
    }

    /// Check on this job's progress whenever the queue changes.
    ///
    /// ⚠️ Uses `.onChange(of: jobs.jobs)` instead of having the runner call back into this view: the job
    ///    will often finish while this page **doesn't even exist** (the user dismissed it long ago) —
    ///    there'd be nowhere for the callback to go. Reading state solely from the ledger covers both cases.
    private func observeJob() {
        guard isWaitingOnJob, let jobID else { return }
        guard let job = jobs.job(id: jobID) else {
            // The entry is gone from the ledger. Only one thing causes that: the source is gone (transcript cleared /
            // recording deleted), the queue judged it can never succeed, and wiped it instead of wasting three attempts.
            summarizeState = .failed(L10n.Jobs.sourceMissing(L10n.Jobs.sourceTranscript))
            return
        }
        if let done = job.progressDone, let total = job.progressTotal {
            chunkProgress = (done, total)
        } else {
            chunkProgress = nil
        }
        switch jobs.state(of: job) {
        case .waiting, .running:
            break
        case .done:
            adoptResult(of: job)
        case .gaveUp:
            chunkProgress = nil
            summarizeState = .failed(job.lastError ?? L10n.Summarize.error)
        }
    }

    /// The job dequeued, and as a success — read the result back from **disk**.
    ///
    /// Read from disk rather than stuffing the text into the job: the output *is* that file (`{base}.summary.md`),
    /// and the detail page, full-text page, and mind map all read it. Keeping an extra in-memory copy only adds one more truth
    /// that can drift out of sync.
    private func adoptResult(of job: Job) {
        // ★ 2026-10-23: read back the **page** this sheet was opened for — the
        //   output *is* that page's file, nothing else.
        let url = StorageLocations.notePageURL(for: audioName, pageID: pageID)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            // The file is missing, yet the ledger says "success". Only one possibility: the user just cancelled this job on the
            // background tasks page — cancellation is also a form of "dequeue", and in the ledger it looks identical to success
            // (`lastError == nil`; see `JobQueue.cancel(id:)`). They no longer want it,
            // so this page should quietly close out — not pop an error they can't make sense of.
            dismiss()
            return
        }
        result = text
        wasTruncated = job.wasTruncated == true
        notices = job.notes ?? []
        chunkProgress = nil
        summarizeState = .done
        // ★ Tell the detail page immediately, don't wait for the user to tap "Done".
        //
        // The output is on disk whether they tap or not; the detail page has no reason to keep showing the old one
        // (or the "Generate summary" button at all).
        onComplete(text)
    }

    /// Promote the fallback channel to primary. Re-run the health check immediately afterwards — the warning banner must vanish on the spot,
    /// or the user will think the button did nothing.
    private func adoptFallbackAsPrimary(_ key: String) {
        env.config.config.llmProviders.primary = key
        env.config.scheduleSave()
        refreshPreflight()
    }

    /// The pre-run notice when the primary is unavailable. With a fallback ⇒ say "who will serve as fallback";
    /// none left ⇒ say "it can't run", rather than letting the user tap and then read an error.
    private func refreshPreflight() {
        let config = env.config.config
        guard let gap = LLMCompletionService.primaryGapWithFallback(config) else {
            preflightWarning = LLMCompletionService.candidateChain(config).isEmpty
                ? L10n.LLM.errorNoProvider
                : nil
            return
        }
        preflightWarning = gap.fallback.map {
            L10n.Summarize.preflightFallback(gap.gap, $0)
        } ?? gap.gap
    }

    // MARK: - Summarize

    /// Returns the chosen output language's English name (e.g. "Spanish
    /// (Spain)") when the user picked a non-default language, otherwise
    /// nil. The English name beats the BCP-47 code as a prompt hint —
    /// most LLMs respond better to "Spanish" than "es-ES".
    private var outputLangName: String? {
        guard !outputLangCode.isEmpty else { return nil }
        return languages.targetLanguages.first { $0.code == outputLangCode }?.name ?? outputLangCode
    }

    /// ★ The only "working" logic left in this file, and it does one thing: prepend the output-language instruction
    ///   to the template's prompt.
    ///
    /// Why it stays in the view rather than moving into `JobRunners`: it depends on `outputLangName`, which is
    /// **the language the user is choosing on this page right now** (it falls back to the language code while
    /// `languages.targetLanguages` hasn't finished loading). The finished product is stored into `Job.prompt` by `use(_:)` —
    /// meaning it runs exactly once, **at enqueue time**, and never touches this page again.
    private func withLanguageInstruction(_ prompt: String) -> String {
        if let name = outputLangName {
            return "Write your ENTIRE response in \(name) — including all section headers, labels, and body text.\n\n" + prompt
        }
        // "Same as transcript" — the template body is in English, so the
        // language directive must come FIRST and be emphatic, otherwise
        // the model follows the English context and ignores a trailing
        // "reply in the same language" hint.
        return "IMPORTANT: Detect the language of the user's content and write your ENTIRE response in that same language — including all section headers, labels, and body text. Only use English if the user's content is in English.\n\n" + prompt
    }

    /// The "generating with X" reported while running.
    ///
    /// ⚠️ Only the **entry** (primary channel) can be reported here, not the one actually doing the work —
    /// `completeResilient` tries channels one by one internally, and which one succeeds is only known once it returns.
    /// Which one actually did the work is stated by the "fell back to X" line in `JobRunners.notices(for:config:)`,
    /// and that's the accurate one. The previous version tracked it once in `workingProvider`, but that only had a value
    /// **after the first round finished** — during the run it displayed the primary channel all along.
    private var activeProviderLabel: String {
        let key = env.config.config.llmProviders.primary ?? ""
        return LLMCompletionService.providerLabel(key)
    }
}

// MARK: - Template overview page (★ new in the seventh revision, 2026-10-15)
//
// After tapping a tile the user wants **not** to run immediately, but to "first see clearly what kind of output this
// template produces": the name, category, a one-line description, and the **full prompt**.
//
// Deliberately **not** stuffing a prompt preview back into the tile: the moment that text gets squeezed in, the grid reverts to the old
// unreadable checklist — the whole point of the overview page is to separate "scanning" from "reading".
//
// The description's `localizedSummary` is an optional legacy field (early built-in templates lack it). When absent, the whole section
// is hidden rather than faked from the prompt's first 80 characters: the full prompt sits right below, so
// a "preview" would be pure duplication.
private struct TemplateOverviewView: View {
    let template: SummarizeTemplate
    let onUse: () -> Void
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let summary = template.localizedSummary, !summary.isEmpty {
                    labelledBlock(L10n.Summarize.templateAbout, text: summary, monospaced: false)
                }
                labelledBlock(
                    L10n.Summarize.templatePromptLabel,
                    text: template.localizedPrompt,
                    monospaced: true
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) { useBar }
        .navigationTitle(template.localizedName.isEmpty
                         ? L10n.Summarize.templateOverviewTitle
                         : template.localizedName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // This page isn't pushed (see the `previewing` note), so the system won't
            // supply a back chevron — one must be placed manually, otherwise the only way out is swiping down to close the entire
            // picker, which looks like "quitting".
            ToolbarItem(placement: .navigationBarLeading) {
                Button { onBack() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.footnote.weight(.semibold))
                        Text(L10n.Summarize.backToTemplates)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: template.isBuiltIn ? "doc.text" : "pencil.and.outline")
                .font(.title3)
                .foregroundStyle(template.isBuiltIn ? Color.secondary : Color.appAccent)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color(uiColor: .secondarySystemBackground)))
            VStack(alignment: .leading, spacing: 6) {
                Text(template.localizedName)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    chip(
                        SummarizeTemplate.localizedCategoryName(template.category),
                        tint: .secondary
                    )
                    chip(
                        template.isBuiltIn ? L10n.Summarize.builtInBadge : L10n.Summarize.customBadge,
                        tint: template.isBuiltIn ? .secondary : .accentColor
                    )
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .foregroundStyle(tint)
    }

    /// A body block with a small heading. `monospaced` is for the prompt — it contains indentation and
    /// table rules, and only a monospaced face shows the structure.
    private func labelledBlock(_ label: String, text: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .footnote)
                .foregroundStyle(.primary)
                // Allow long-press selection and copy: wanting to take this prompt elsewhere to tweak it is perfectly natural.
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
        }
    }

    private var useBar: some View {
        Button { onUse() } label: {
            Label(L10n.Summarize.useTemplate, systemImage: "sparkles")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
