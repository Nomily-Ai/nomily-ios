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
        VStack(spacing: 0) {
            languageBar
            templateList
        }
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

    private var templateList: some View {
        List {
            ForEach(filteredCategories, id: \.self) { category in
                Section(SummarizeTemplate.localizedCategoryName(category)) {
                    ForEach(filtered.filter { $0.category == category }) { template in
                        Button {
                            selected = template
                            summarizeTask = Task { await runSummarize(template) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: template.isBuiltIn ? "doc.text" : "pencil.and.outline")
                                    .font(.caption)
                                    .foregroundColor(template.isBuiltIn ? .secondary : .accentColor)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(template.localizedName)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(template.localizedPrompt.prefix(80) + "...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: L10n.Summarize.searchTemplates)
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
        do {
            let output = try await LLMCompletionService.complete(
                systemPrompt: withLanguageInstruction(template.localizedPrompt),
                userContent: transcriptText,
                config: env.config.config
            )
            try Task.checkCancellation()
            result = output.text
            wasTruncated = output.truncated
            await extractTitle(from: output.text)
            try Task.checkCancellation()
            summarizeState = .done
        } catch is CancellationError {
            pendingTitle = nil
        } catch {
            summarizeState = .failed(error.localizedDescription)
        }
        summarizeTask = nil
    }

    private func extractTitle(from summary: String) async {
        do {
            let title = try await LLMCompletionService.complete(
                systemPrompt: withLanguageInstruction("Generate a short title (under 60 characters) for the following notes. Reply with ONLY the title text, no quotes, no punctuation at the end."),
                userContent: String(summary.prefix(1000)),
                config: env.config.config
            )
            let clean = title.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let key = env.config.config.llmProviders.primary ?? ""
        let map = ["openai": "OpenAI", "claude": "Claude", "gemini": "Gemini",
                    "openRouter": "Open Router", "ollama": "Ollama", "custom": "Custom"]
        return map[key] ?? key
    }
}
