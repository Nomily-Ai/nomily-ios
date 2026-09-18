import SwiftUI

/// Searchable list picker over `LanguageService.Language`. When
/// `defaultOption` is non-nil, an extra row is shown above the list and
/// selecting it returns a `Language` with an empty `code` (callers
/// interpret that as "no override" — e.g. same as source / same as
/// transcript).
struct LanguagePickerSheet: View {
    let title: String
    let languages: [LanguageService.Language]
    let defaultOption: String?
    let onPick: (LanguageService.Language) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [LanguageService.Language] {
        if search.isEmpty { return languages }
        let q = search.lowercased()
        return languages.filter {
            $0.name.lowercased().contains(q) || $0.code.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let label = defaultOption {
                    Section {
                        Button {
                            onPick(LanguageService.Language(code: "", name: label, nativeName: ""))
                        } label: {
                            Text(label)
                                .foregroundColor(.primary)
                        }
                    }
                }

                Section {
                    ForEach(filtered) { lang in
                        Button {
                            onPick(lang)
                        } label: {
                            HStack {
                                Text(lang.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                Text(lang.code)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: L10n.Live.searchLanguages)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
