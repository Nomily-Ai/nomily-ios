import SwiftUI

struct SummarizeTemplatesView: View {
    @StateObject private var store = SummarizeTemplateStore()
    @State private var viewingTemplate: SummarizeTemplate?
    @State private var editingTemplate: SummarizeTemplate?
    @State private var showAddSheet = false
    @State private var showResetConfirm = false
    @State private var pendingDelete: SummarizeTemplate?
    /// ★ 2026-10-15 七改：模板一多（内置 20 + 采用库 65），块状网格比列表更长，
    /// 没有搜索就只能靠一屏屏滚。这里和"选模板"那一页用同一套口径。
    @State private var search = ""

    var body: some View {
        // ★ 2026-10-15 七改：`List + 一行 = 图标 + 名字 + 100 字预览` 改成块状网格。
        //
        // 和 `SummarizeSheet` 的选择页改的是同一件事（用户原话："摘要模板里面
        // 不要直接文字，建议按照块显示当前结构，然后点击进去就是一个总体的
        // 概览"）。两处必须一起改 —— 只在一边改，用户会看到"同一个模板"
        // 在两个入口长得完全不一样。
        //
        // 点块进去仍是原有的只读预览页（`TemplatePreviewView`），它已经就是
        // 那个"总体的概览"：分类 + Markdown 渲染 + 原文切换 + 克隆/编辑入口。
        templateGrid
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

    // MARK: - 块状网格（★ 七改）

    @ViewBuilder
    private var templateGrid: some View {
        if visibleCategories.isEmpty {
            // 搜不到东西时**必须**说话：网格搜空之后整页是白的，
            // 用户第一反应是"页面坏了"，而不是"我搜的词不对"。
            EmptyStateView(
                L10n.Summarize.noMatchingTemplates,
                systemImage: "magnifyingglass",
                message: L10n.Summarize.searchTemplates
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(visibleCategories, id: \.self) { category in
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

    /// 保持 `store.categories` 的既有顺序（自定义分类在前），只是把搜空的分类去掉。
    private var visibleCategories: [String] {
        store.categories.filter { !templatesIn($0).isEmpty }
    }

    private func templatesIn(_ category: String) -> [SummarizeTemplate] {
        let all = store.templates(in: category)
        guard !search.isEmpty else { return all }
        let q = search.lowercased()
        return all.filter {
            $0.name.lowercased().contains(q)
            || $0.category.lowercased().contains(q)
            || ($0.localizedSummary?.lowercased().contains(q) ?? false)
        }
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

    /// 一个模板块。块上**只放名字**：说明与提示词都在点进去的概览页里。
    ///
    /// ⚠️ 从 `List` 搬到网格之后，原来的 `.swipeActions` 没了 —— 网格里的 item
    /// 没有左滑这回事。自定义模板的删除改用长按菜单，二次确认照旧（删除不可
    /// 撤销，绝不能变成"点一下就没了"）。
    private func templateCard(_ template: SummarizeTemplate) -> some View {
        Button {
            // Custom templates also start with a read‑only preview
            // (Markdown / source toggle), with the edit entry on the
            // preview page: opening straight into a plain‑text editor
            // hides how the template’s formatting will actually look.
            viewingTemplate = template
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
        .contextMenu {
            if !template.isBuiltIn {
                Button(role: .destructive) {
                    pendingDelete = template
                } label: {
                    Label(L10n.Common.delete, systemImage: "trash")
                }
            }
        }
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
