import SwiftUI

struct SummarizeTemplatesView: View {
    @StateObject private var store = SummarizeTemplateStore()
    @State private var viewingTemplate: SummarizeTemplate?
    @State private var editingTemplate: SummarizeTemplate?
    @State private var showAddSheet = false
    @State private var showResetConfirm = false
    @State private var pendingDelete: SummarizeTemplate?

    var body: some View {
        List {
            ForEach(store.categories, id: \.self) { category in
                Section(SummarizeTemplate.localizedCategoryName(category)) {
                    ForEach(store.templates(in: category)) { template in
                        Button {
                            // Custom templates also start with a read‑only preview
                            // (Markdown / source toggle), with the edit entry on the
                            // preview page: opening straight into a plain‑text editor
                            // hides how the template’s formatting will actually look.
                            viewingTemplate = template
                        } label: {
                            templateRow(template)
                        }
                        .swipeActions(edge: .trailing) {
                            if !template.isBuiltIn {
                                // Deletion is irreversible; a swipe deletes instantly, which is easy to trigger accidentally: ask for confirmation first.
                                Button(role: .destructive) {
                                    pendingDelete = template
                                } label: {
                                    Label(L10n.Common.delete, systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }

        }
        .navigationTitle(L10n.Settings.summarizeTemplates)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // "Add" lives in the navigation bar, not at the bottom of the list:
            // with a dozen templates the old entry was a full scroll away
            // (izbbpcq). Only one entry — no duplicate at the bottom.
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Label(L10n.Summarize.addTemplate, systemImage: "plus")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label(L10n.Summarize.restoreDefaults, systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert(
            L10n.Summarize.deleteTitle,
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button(L10n.Common.delete, role: .destructive) {
                if let t = pendingDelete {
                    store.templates.removeAll { $0.id == t.id }
                    store.save()
                }
                pendingDelete = nil
            }
            Button(L10n.Common.cancel, role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L10n.Summarize.deleteMessage(pendingDelete?.localizedName ?? ""))
        }
        .alert(L10n.Summarize.restoreDefaultsTitle, isPresented: $showResetConfirm) {
            Button(L10n.Summarize.restoreDefaults, role: .destructive) {
                store.resetToDefaults()
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Summarize.restoreDefaultsMessage)
        }
        .sheet(item: $viewingTemplate) { template in
            TemplatePreviewView(
                template: template,
                onClone: { clone in
                    store.templates.append(clone)
                    store.save()
                    viewingTemplate = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        editingTemplate = clone
                    }
                },
                onEdit: {
                    viewingTemplate = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        editingTemplate = template
                    }
                }
            )
        }
        .sheet(item: $editingTemplate) { template in
            TemplateEditorView(
                template: template,
                existingCategories: store.categories
            ) { updated in
                if let idx = store.templates.firstIndex(where: { $0.id == updated.id }) {
                    store.templates[idx] = updated
                    store.save()
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            TemplateEditorView(
                template: SummarizeTemplate(
                    category: store.categories.first ?? "Custom",
                    name: "",
                    prompt: "",
                    isBuiltIn: false
                ),
                existingCategories: store.categories
            ) { newTemplate in
                store.templates.append(newTemplate)
                store.save()
            }
        }
    }

    private func templateRow(_ template: SummarizeTemplate) -> some View {
        HStack(spacing: 8) {
            Image(systemName: template.isBuiltIn ? "doc.text" : "pencil.and.outline")
                .font(.caption)
                .foregroundColor(template.isBuiltIn ? .secondary : .accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(template.localizedName)
                    .font(.body)
                    .foregroundColor(.primary)
                Text(template.localizedPrompt.prefix(100) + "...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Read-only preview (both built-in and custom templates)

private struct TemplatePreviewView: View {
    let template: SummarizeTemplate
    let onClone: (SummarizeTemplate) -> Void
    /// Edit entry for custom templates. Built‑in templates are not editable; the top‑right remains a “Clone” button.
    let onEdit: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// Prompts are Markdown (headings, tables, bold), so the preview renders
    /// them like the summary view does and keeps a raw toggle for copying the
    /// prompt itself (j2092e6). Cloning always takes the raw text.
    @State private var showRaw = false

    var body: some View {
        NavigationStack {
            Group {
                if showRaw {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            LabeledContent(L10n.Summarize.category, value: template.localizedCategory)
                            Divider()
                            Text(template.localizedPrompt)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding()
                    }
                } else {
                    MarkdownView(markdown: template.localizedPrompt)
                }
            }
            .navigationTitle(template.localizedName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showRaw.toggle()
                    } label: {
                        Image(systemName: showRaw ? "doc.richtext" : "doc.plaintext")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if template.isBuiltIn {
                        Button(L10n.Summarize.clone) {
                            let clone = SummarizeTemplate(
                                category: template.category,
                                name: L10n.Summarize.copyName(template.localizedName),
                                prompt: template.localizedPrompt,
                                isBuiltIn: false
                            )
                            onClone(clone)
                        }
                    } else {
                        Button(L10n.Common.edit) { onEdit() }
                    }
                }
            }
        }
    }
}

// MARK: - Template editor

private struct TemplateEditorView: View {
    @State var template: SummarizeTemplate
    let existingCategories: [String]
    let onSave: (SummarizeTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var customCategory = ""
    @State private var useCustomCategory = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if useCustomCategory {
                        TextField(L10n.Summarize.newCategoryName, text: $customCategory)
                    } else {
                        Picker(L10n.Summarize.category, selection: $template.category) {
                            ForEach(existingCategories, id: \.self) {
                                Text(SummarizeTemplate.localizedCategoryName($0)).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                } header: {
                    HStack {
                        Text(L10n.Summarize.category)
                        Spacer()
                        Button(useCustomCategory ? L10n.Summarize.pickExisting : L10n.Summarize.new) {
                            if useCustomCategory {
                                useCustomCategory = false
                                if !existingCategories.contains(template.category) {
                                    template.category = existingCategories.first ?? "Custom"
                                }
                            } else {
                                useCustomCategory = true
                                customCategory = ""
                            }
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }
                Section(L10n.Summarize.name) {
                    TextField(L10n.Summarize.templateName, text: $template.name)
                }
                Section {
                    TextEditor(text: Binding(
                        get: { template.prompt },
                        set: { template.prompt = String($0.prefix(SummarizeTemplate.promptMaxCharacters)) }
                    ))
                    .font(.body.monospaced())
                    .frame(minHeight: 200)

                    Text(String(
                        format: NSLocalizedString("summarize.prompt_count", comment: ""),
                        template.prompt.count,
                        SummarizeTemplate.promptMaxCharacters
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                } header: {
                    Text(L10n.Summarize.prompt)
                } footer: {
                    Text(NSLocalizedString("summarize.prompt_context_hint", comment: ""))
                }
            }
            .navigationTitle(template.name.isEmpty ? L10n.Summarize.newTemplate : L10n.Summarize.editTemplate)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.save) {
                        if useCustomCategory, !customCategory.isEmpty {
                            template.category = customCategory
                        }
                        onSave(template)
                        dismiss()
                    }
                    .disabled(
                        template.name.isEmpty || template.prompt.isEmpty ||
                        template.prompt.count > SummarizeTemplate.promptMaxCharacters
                    )
                }
            }
        }
    }
}
