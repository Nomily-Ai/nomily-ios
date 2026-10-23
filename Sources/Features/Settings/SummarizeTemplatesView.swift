import SwiftUI

/// Summary template management, rebuilt 2026-10-19 to match DingTalk's Minutes template picker:
///
/// * **Top chip row filters the grid** — Recommended / Custom / one chip per category. Before this the
///   page was "one section header per category, stacked"; with 20+ templates finding one meant
///   scrolling through every category (the user: "filter from the top so the list below matches and I can find it fast").
/// * **Cards carry an icon, name and one-line "what is this for"** — the description used to live
///   only behind a tap.
/// * **Set as default** — the summary picker pre-selects the template marked here (see
///   `AppConfig.summaryTemplateKey` and the preselect in `SummarizeSheet`).
struct SummarizeTemplatesView: View {
    @StateObject private var store = SummarizeTemplateStore()
    @EnvironmentObject private var env: AppEnvironment
    @State private var viewingTemplate: SummarizeTemplate?
    @State private var editingTemplate: SummarizeTemplate?
    @State private var showAddSheet = false
    @State private var showResetConfirm = false
    @State private var pendingDelete: SummarizeTemplate?
    /// The card the user tapped — the "Set as default" button applies to it.
    @State private var selectedKey: String?
    @State private var defaultJustSet = false
    /// ★ 2026-10-15 seventh revision: once templates pile up (20 built-in + 65 adopted from the library), a block grid runs longer than a list,
    /// and without search you can only scroll screen by screen. This and the "select a template" page use the same approach.
    @State private var search = ""

    /// Chip = one filter. `.recommended` is the curated built-in set; `.custom` is everything
    /// the user made or adopted; `.category` is one exact category.
    private enum Filter: Hashable {
        case recommended
        case custom
        case category(String)
    }

    @State private var filter: Filter = .recommended

    var body: some View {
        VStack(spacing: 0) {
            filterChips
            templateGrid
            defaultBar
        }
        .navigationTitle(L10n.Settings.summarizeTemplates)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: L10n.Summarize.searchTemplates)
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
                    if selectedKey == t.storeKey { selectedKey = nil }
                    if env.config.config.summaryTemplateKey == t.storeKey {
                        env.config.config.summaryTemplateKey = nil
                        env.config.scheduleSave()
                    }
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
                selectedKey = nil
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
                filter = .custom
            }
        }
    }

    // MARK: - Chip row (top filter)

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(.recommended, L10n.Summarize.chipRecommended)
                chip(.custom, L10n.Summarize.chipCustom)
                ForEach(store.categories, id: \.self) { category in
                    chip(.category(category), SummarizeTemplate.localizedCategoryName(category))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func chip(_ value: Filter, _ title: String) -> some View {
        let isOn = filter == value
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { filter = value }
        } label: {
            Text(title)
                .font(.subheadline.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(isOn ? Color.appAccent : Color(uiColor: .secondarySystemBackground)))
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grid

    private var visibleTemplates: [SummarizeTemplate] {
        let base: [SummarizeTemplate]
        switch filter {
        case .recommended:
            // Curated in the order the defaults declare — that order *is* the curation.
            base = store.templates.filter(\.isBuiltIn)
        case .custom:
            base = store.templates.filter { !$0.isBuiltIn }
        case .category(let category):
            base = store.templates(in: category)
        }
        guard !search.isEmpty else { return base }
        let q = search.lowercased()
        return base.filter {
            $0.name.lowercased().contains(q)
            || $0.category.lowercased().contains(q)
            || ($0.localizedSummary?.lowercased().contains(q) ?? false)
        }
    }

    private var sectionTitle: String? {
        if !search.isEmpty { return nil }
        switch filter {
        case .recommended: return L10n.Summarize.chipRecommended
        case .custom: return L10n.Summarize.chipCustom
        case .category(let c): return SummarizeTemplate.localizedCategoryName(c)
        }
    }

    @ViewBuilder
    private var templateGrid: some View {
        if visibleTemplates.isEmpty {
            // When a search/filter finds nothing it **must** say so: once the grid empties out the whole page is blank,
            // and the user's first reaction is "the page is broken", not "my filter was wrong".
            EmptyStateView(
                L10n.Summarize.noMatchingTemplates,
                systemImage: "magnifyingglass",
                message: L10n.Summarize.searchTemplates
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let sectionTitle {
                        Text(sectionTitle)
                            .font(.subheadline.weight(.semibold))
                            .padding(.top, 12)
                    }
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(visibleTemplates) { template in
                            templateCard(template)
                        }
                        if filter == .custom {
                            newTemplateCard
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }

    /// A template card, DingTalk-style: icon top-left, expand affordance top-right,
    /// name + one-line description, and a checkmark when it *is* the default.
    ///
    /// Tap = **select** (the bottom bar acts on the selection); the corner arrow opens the
    /// read-only preview. The old behaviour (tap = preview) made "set as default" impossible
    /// without a modal round-trip per template.
    private func templateCard(_ template: SummarizeTemplate) -> some View {
        let isSelected = selectedKey == template.storeKey
        let isDefault = env.config.config.summaryTemplateKey == template.storeKey
        return Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                selectedKey = (selectedKey == template.storeKey) ? nil : template.storeKey
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: template.effectiveIcon)
                        .font(.body)
                        .foregroundStyle(template.isBuiltIn ? Color.appAccent : Color.secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.appAccent.opacity(0.12))
                        )
                    Spacer(minLength: 0)
                    // Corner affordance: opens the preview without losing the selection.
                    Button {
                        viewingTemplate = template
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
                    .lineLimit(1)
                Text(template.pickerSubtitle(limit: 60))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(minHeight: 30, alignment: .top)
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
                    if isDefault {
                        Label(L10n.Summarize.defaultBadge, systemImage: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.appAccent)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
            Button {
                setDefault(template)
            } label: {
                Label(L10n.Summarize.setDefault, systemImage: "star")
            }
            if !template.isBuiltIn {
                Button(role: .destructive) {
                    pendingDelete = template
                } label: {
                    Label(L10n.Common.delete, systemImage: "trash")
                }
            }
        }
    }

    /// The ＋ card at the end of Custom — same placement as DingTalk's picker.
    private var newTemplateCard: some View {
        Button {
            showAddSheet = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.title2)
                    .foregroundStyle(Color.appAccent)
                Text(L10n.Summarize.addTemplate)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Default bar (bottom)

    private var defaultBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    guard let key = selectedKey,
                          let template = store.templates.first(where: { $0.storeKey == key }) else { return }
                    setDefault(template)
                } label: {
                    Text(L10n.Summarize.setDefault)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            Capsule().fill(Color.appAccent.opacity(defaultJustSet ? 1 : 0.14))
                        )
                        .foregroundStyle(defaultJustSet ? Color.white : Color.appAccent)
                }
                .buttonStyle(.plain)
                .disabled(selectedKey == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func setDefault(_ template: SummarizeTemplate) {
        let key = template.storeKey
        // Tapping the default's card again clears it — the same toggle DingTalk's checkmark has.
        let next = (env.config.config.summaryTemplateKey == key) ? nil : key
        env.config.config.summaryTemplateKey = next
        env.config.scheduleSave()
        selectedKey = next
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        defaultJustSet = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { defaultJustSet = false }
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
