import SwiftUI

struct SummarizeSheet: View {
    let transcriptText: String
    let audioName: String
    let onComplete: (String) -> Void

    @EnvironmentObject private var env: AppEnvironment
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
    /// Held in memory until the user saves. Writing it as soon as the LLM
    /// answered meant Cancel still renamed the recording in the library —
    /// new title, no summary.
    @State private var pendingTitle: String?
    /// The in-flight summarize/title work, so Cancel actually stops it
    /// instead of only closing the sheet (and still burning the quota).
    @State private var summarizeTask: Task<Void, Never>?
    /// The provider said it stopped because it hit the output cap. The text
    /// is real but cut off — say so instead of presenting it as finished.
    @State private var wasTruncated = false
    /// ★ 2026-10-15: The channel that **actually does the work**. When the primary dies and the fallback takes over, the title generation afterwards
    /// must go straight to it — otherwise every generated title waits out another primary-channel timeout.
    @State private var workingProvider: String?
    /// The user-facing note: fallback took over / chunking was used. **Must be shown** —
    /// the user set A but B generated the result; without an explanation it becomes "is it even using my configuration?"
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

    private var filtered: [SummarizeTemplate] {
        if search.isEmpty { return templateStore.templates }
        let q = search.lowercased()
        return templateStore.templates.filter {
            $0.name.lowercased().contains(q) ||
            $0.category.lowercased().contains(q)
        }
    }

    private var filteredCategories: [String] {
        var seen = Set<String>()
        return filtered.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch summarizeState {
                case .picking:
                    templatePicker
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
                            Text(t.name)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
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
                    Button(L10n.Common.cancel) {
                        summarizeTask?.cancel()
                        summarizeTask = nil
                        pendingTitle = nil
                        dismiss()
                    }
                }
                if case .done = summarizeState {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.Common.save) { saveSummary() }
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
        // Block interactive swipe-to-dismiss while a summary is being
        // generated (else the swipe cancels it — w6estkf) or when a
        // generated summary hasn't been saved yet (else swiping down
        // silently discards it — g17h5nk). The user must tap Cancel or
        // Save to leave those states.
        .interactiveDismissDisabled(dismissGuard)
    }

    private var dismissGuard: Bool {
        switch summarizeState {
        case .running, .done: return true
        case .picking, .failed: return false
        }
    }

    private var navTitle: String {
        switch summarizeState {
        case .picking: return L10n.Summarize.chooseTemplate
        case .running: return L10n.Summarize.summarizing
        case .done: return L10n.ClipDetail.summary
        case .failed: return L10n.Summarize.error
        }
    }

    // MARK: - Template picker

    private var currentLangName: String {
        if outputLangCode.isEmpty { return L10n.Summarize.sameAsTranscript }
        return languages.targetLanguages.first { $0.code == outputLangCode }?.name ?? outputLangCode
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
                    if let preflightWarning {
                        // ★ 2026-10-15: The health check can't stop at "saying something" — it also needs a **one-tap fix**.
                        //
                        // What was actually observed: "the primary points at Open Router, and that entry has no
                        // api_key". With a hint alone, the user has to find their own way to Settings → LLM Providers,
                        // scroll to Open Router, and locate the primary-channel picker — when there is exactly one correct answer.
                        VStack(alignment: .leading, spacing: 6) {
                            Label(preflightWarning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            if let fix = LLMCompletionService.suggestedPrimary(env.config.config) {
                                Button {
                                    adoptFallbackAsPrimary(fix)
                                } label: {
                                    Text(L10n.LLM.adoptAsPrimary(
                                        LLMCompletionService.providerLabel(fix)
                                    ))
                                    .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color.orange.opacity(0.12))
                    }
                    languageBar
                    templateGrid
                }
            }
        }
        .onAppear { refreshPreflight() }
    }

    /// Kick off the run. **Called only from the overview page** — the tile itself only handles "open the overview".
    ///
    /// Clear `previewing` in the same frame: if this run fails and the user taps "Retry" back into
    /// the picker page, they see the grid rather than the **previous template's overview**.
    private func use(_ template: SummarizeTemplate) {
        selected = template
        previewing = nil
        summarizeState = .running
        summarizeTask = Task { await runSummarize(template) }
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

    private var languageBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(L10n.Summarize.outputLanguage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button { showLangPicker = true } label: {
                HStack(spacing: 4) {
                    Text(currentLangName)
                        .font(.subheadline)
                        .foregroundStyle(outputLangCode.isEmpty ? Color.secondary : Color.accentColor)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    // MARK: - Template grid (★ seventh revision 2026-10-15)
    //
    // It used to be `List { Section { one row = icon + name + an 80-character prompt preview } }`:
    // only three or four fit on screen, and **the names drowned in walls of text** — picking a template became line-by-line reading.
    // Now spread into tiles by category: scan the category headers, then the names on the tiles — six to eight visible per screen.
    // To see exactly "what a template will produce", tap through to its overview page.
    private var templateGrid: some View {
        Group {
            if filtered.isEmpty {
                // Say something when the search finds nothing. An emptied grid leaves the page blank, and users will think it's broken.
                EmptyStateView(
                    L10n.Summarize.noMatchingTemplates,
                    systemImage: "magnifyingglass",
                    message: L10n.Summarize.searchTemplates
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(filteredCategories, id: \.self) { category in
                            VStack(alignment: .leading, spacing: 10) {
                                categoryHeader(category)
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 148), spacing: 10)],
                                    spacing: 10
                                ) {
                                    ForEach(templatesIn(category)) { template in
                                        templateCard(template)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
        }
        // Attached outside the Group: that way the search bar is present in both the "results" and "no results" shapes,
        // so users can delete the typo they just made. Inside, it would have to be written twice (a Group
        // dispatches the modifier to its single content view).
        .searchable(text: $search, prompt: L10n.Summarize.searchTemplates)
    }

    private func templatesIn(_ category: String) -> [SummarizeTemplate] {
        filtered.filter { $0.category == category }
    }

    private func categoryHeader(_ category: String) -> some View {
        HStack(spacing: 6) {
            Text(SummarizeTemplate.localizedCategoryName(category))
                .font(.subheadline.weight(.semibold))
            Text(L10n.Summarize.templateCount(templatesIn(category).count))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    /// One template tile. **Name only** — the description and prompt live on the overview page; the goal here is "scannable".
    private func templateCard(_ template: SummarizeTemplate) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { previewing = template }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: template.isBuiltIn ? "doc.text" : "pencil.and.outline")
                        .font(.caption)
                        .foregroundStyle(template.isBuiltIn ? Color.secondary : Color.accentColor)
                    Spacer(minLength: 0)
                    if !template.isBuiltIn {
                        Text(L10n.Summarize.customBadge)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(template.localizedName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            // `maxHeight: .infinity` makes **tiles in the same row equal height** — when a one-line name sits next to
            // a three-line name, the ragged bottom edges are extremely conspicuous.
            .frame(maxWidth: .infinity, minHeight: 88, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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

    private func runSummarize(_ template: SummarizeTemplate) async {
        summarizeState = .running
        wasTruncated = false
        notices = []
        chunkProgress = nil
        // ★ 2026-10-15: Hold the background keep-alive for the duration of a long summary.
        //
        // A local 3B model takes minutes per 8000-character chunk, and the whole piece chunked takes even longer. During that window
        // the user will almost certainly switch away ("just a quick WeChat reply"); without the keep-alive the process suspends,
        // the URLSession requests break on the spot, and all that greets them on return is a failure message.
        //
        // `defer` rather than releasing before each return: there are three exits here
        // (finish / cancel / fail), and missing one would leave the silent audio playing forever.
        BackgroundKeeper.shared.acquire(.summary)
        defer { BackgroundKeeper.shared.release(.summary) }
        do {
            let outcome = try await LLMCompletionService.completeResilient(
                systemPrompt: withLanguageInstruction(template.localizedPrompt),
                userContent: transcriptText,
                config: env.config.config,
                preferred: workingProvider,
                onChunk: { done, total in
                    chunkProgress = (done, total)
                }
            )
            try Task.checkCancellation()
            workingProvider = outcome.providerKey
            notices = Self.notices(for: outcome, config: env.config.config)
            result = outcome.completion.text
            wasTruncated = outcome.completion.truncated
            await extractTitle(from: outcome.completion.text)
            try Task.checkCancellation()
            chunkProgress = nil
            summarizeState = .done
        } catch is CancellationError {
            pendingTitle = nil
        } catch {
            chunkProgress = nil
            summarizeState = .failed(error.localizedDescription)
        }
        summarizeTask = nil
    }

    /// Translate the `Outcome` into plain words. **Both must be spelled out**:
    /// the primary channel wasn't the one used (something's off in the configuration), and the content went through chunking (the result's structure
    /// differs subtly from a single-shot generation; users seeing missing chunk headers will assume it's a bug).
    private static func notices(
        for outcome: LLMCompletionService.Outcome, config: AppConfig
    ) -> [String] {
        var result: [String] = []
        let primary = config.llmProviders.primary ?? ""
        if !primary.isEmpty, primary != outcome.providerKey {
            result.append(L10n.LLM.fellBack(
                LLMCompletionService.providerLabel(primary),
                LLMCompletionService.providerLabel(outcome.providerKey)
            ))
        }
        if outcome.chunked {
            result.append(L10n.LLM.chunkedNote(outcome.chunkCount))
        }
        return result
    }

    private func extractTitle(from summary: String) async {
        do {
            let title = try await LLMCompletionService.completeResilient(
                systemPrompt: withLanguageInstruction("Generate a short title (under 60 characters) for the following notes. Reply with ONLY the title text, no quotes, no punctuation at the end."),
                userContent: String(summary.prefix(1000)),
                config: env.config.config,
                // Title generation gets only 1000 characters of input; nothing to chunk.
                allowChunking: false,
                // ★ Go straight to the channel that actually did the work. Without this, the primary has
                //   already proven unusable, and this step would **wait out another timeout** on it before the fallback gets a turn.
                preferred: workingProvider
            )
            let clean = title.completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                pendingTitle = clean
            }
        } catch {
            // Title extraction is best-effort; summary is still valid
        }
    }

    /// Title and summary land together or not at all.
    private func saveSummary() {
        let url = StorageLocations.summaryURL(for: audioName)
        try? result.data(using: .utf8)?.write(to: url, options: .atomic)
        if let pendingTitle, !pendingTitle.isEmpty {
            try? pendingTitle.data(using: .utf8)?
                .write(to: StorageLocations.titleURL(for: audioName), options: .atomic)
        }
        onComplete(result)
        dismiss()
    }

    private var activeProviderLabel: String {
        // Once a round has run, report "the one actually doing the work" — seeing "generating with Ollama" is how
        // the user knows the settings did take effect.
        let key = workingProvider ?? env.config.config.llmProviders.primary ?? ""
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
                .foregroundStyle(template.isBuiltIn ? Color.secondary : Color.accentColor)
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
