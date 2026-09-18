import SwiftUI

/// Per-transcription locale picker for Azure Fast Transcription.
///
/// Presented from the Transcribe menu in Clip Detail. The user's selection
/// is handed to `TranscriptionService.transcribe(locales:)` for **this
/// invocation only** — there is no persistence. Omitting locales (cancel
/// or empty selection) is the default; Azure auto-detects across its
/// 15-locale multi-language set in that case.
///
/// Catalog is restricted to `LanguageService.azureMultiLanguageLocales`
/// (the 15 codes Azure's auto-detect model supports). Cap at 4 keeps the
/// picker manageable while Azure itself accepts up to 10.
struct AzureLocalesPickerSheet: View {
    let initial: [String]
    let onCommit: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var working: Set<String> = []
    @State private var search = ""
    @State private var showCapHint = false

    static let maxSelections = 4

    private var catalog: [LanguageService.Language] {
        LanguageService.azureMultiLanguageLocales
    }

    private var filtered: [LanguageService.Language] {
        if search.isEmpty { return catalog }
        let q = search.lowercased()
        return catalog.filter {
            $0.name.lowercased().contains(q)
                || $0.nativeName.lowercased().contains(q)
                || $0.code.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(filtered) { lang in
                        Button { toggle(lang.code) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lang.name)
                                        .foregroundColor(.primary)
                                    Text(lang.code)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if working.contains(lang.code) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                } footer: {
                    Text(footerText)
                        .foregroundStyle(working.count >= 2 ? Color.orange : Color.secondary)
                }
            }
            .searchable(text: $search, prompt: L10n.Live.searchLanguages)
            .navigationTitle(L10n.ASR.specifyLanguages)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Common.done) { commit() }
                        .disabled(working.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            working = Set(initial.filter { code in catalog.contains { $0.code == code } })
        }
    }

    private var footerText: String {
        if showCapHint {
            return L10n.ASR.maxLanguagesHint(Self.maxSelections)
        }
        // Azure decides the language phrase-by-phrase. On a clip that is
        // actually monolingual, handing it several candidates is what
        // produces the garbled output QA saw on Chinese audio — some
        // phrases get tagged as a neighbouring language and transcribed
        // with the wrong model. Say so at the moment the second language
        // is picked, not in the generic footer.
        if working.count >= 2 {
            return L10n.ASR.multiLanguageWarning
        }
        return L10n.ASR.languagesFooter
    }

    private func toggle(_ code: String) {
        if working.contains(code) {
            working.remove(code)
            showCapHint = false
            return
        }
        if working.count >= Self.maxSelections {
            withAnimation { showCapHint = true }
            return
        }
        working.insert(code)
        showCapHint = false
    }

    private func commit() {
        let ordered = catalog.map(\.code).filter { working.contains($0) }
        onCommit(ordered)
        dismiss()
    }
}
