import SwiftUI

/// ★ 2026-10-28（饭耳逆向规格 §1.4「常用词」）：词表编辑页。
///
/// 语义与饭耳一致（原文）：「只是提示，不会把别的词强行换成它」——footer
/// 原话告诉用户这条边界。支持单条添加、滑动删除、批量导入、导出；上限 2000。
///
/// ★ 2026-10-29（用户："常用词汇里面从历史的文档里面提取，还有出现频率跟来源"，
/// 截图 5 布局）：顶部搜索框；用量卡（已用 X/2000 + 近 7 天自动加了 N 个 +
/// 看来源）；词行带出现次数与来源录音；来源详情 sheet；「从历史转写提取」
/// 手动触发挖掘（另外首次启动 + 每周会自动挖一次，见 AppEnvironment）。
struct VocabularyEditorView: View {
    @ObservedObject private var store = VocabularyStore.shared
    @State private var draft = ""
    @State private var notice: String?
    @State private var search = ""
    @State private var sourcesSheet: VocabEntry?

    /// 搜索过滤 + 保持"手填在前、自动在后"的分组序。
    private var filtered: [VocabEntry] {
        let list = search.isEmpty
            ? store.entries
            : store.entries.filter { $0.word.localizedCaseInsensitiveContains(search) }
        return list.sorted { lhs, rhs in
            if lhs.auto != rhs.auto { return !lhs.auto }
            if lhs.auto == rhs.auto { return lhs.addedAt > rhs.addedAt }
            return false
        }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.Vocabulary.searchPlaceholder, text: $search)
                        .textInputAutocapitalization(.never)
                }
            }

            usageCard

            addRowSection

            if !filtered.isEmpty {
                wordsSection
            }

            Section {
                Button {
                    pasteImport()
                } label: {
                    Label(L10n.Vocabulary.importButton, systemImage: "doc.badge.plus")
                }
                Button {
                    UIPasteboard.general.string = store.exportText()
                    notice = L10n.Vocabulary.exported
                } label: {
                    Label(L10n.Vocabulary.exportButton, systemImage: "doc.on.doc")
                }
                .disabled(store.words.isEmpty)
            } footer: {
                Text(L10n.Vocabulary.importFooter)
            }

            if let notice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(L10n.Vocabulary.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refreshRecentAutoCount() }
        .sheet(item: $sourcesSheet) { entry in
            SourcesSheet(entry: entry)
        }
    }

    /// 用量卡（截图 5 中部）：已用 X / 2000 + 口径说明 + 自动加入行。
    private var usageCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Vocabulary.usedCount(store.count, VocabularyStore.limit))
                    .font(.subheadline.weight(.semibold))
                Text(L10n.Vocabulary.usageNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.recentAutoCount > 0 {
                    HStack {
                        Label(
                            L10n.Vocabulary.autoAdded(store.recentAutoCount),
                            systemImage: "sparkles"
                        )
                        .font(.subheadline)
                        Spacer()
                        Button(L10n.Vocabulary.seeSources) {
                            // 看来源 = 打开第一条自动词的来源列表；逐词来源在词行上。
                            if let first = store.entries.first(where: { $0.auto && !$0.sources.isEmpty }) {
                                sourcesSheet = first
                            }
                        }
                        .font(.subheadline)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                Button {
                    notice = nil
                    VocabularyStore.mineOffMain()
                    notice = L10n.Vocabulary.miningStarted
                } label: {
                    Label(L10n.Vocabulary.mineButton, systemImage: "text.magnifyingglass")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var addRowSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField(L10n.Vocabulary.addField, text: $draft)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(addDraft)
                Button(action: addDraft) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var wordsSection: some View {
        Section {
            ForEach(filtered) { entry in
                Button {
                    if !entry.sources.isEmpty { sourcesSheet = entry }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.word).foregroundStyle(.primary)
                                if entry.auto {
                                    Text(L10n.Vocabulary.autoTag)
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !entry.sources.isEmpty {
                                Text(L10n.Vocabulary.sourceLine(entry.sources.joined(separator: "、")))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if entry.count > 0 {
                            Text("×\(entry.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "minus.circle")
                            .foregroundStyle(.red.opacity(0.7))
                    }
                }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    store.remove(filtered[index].word)
                }
            }
        } footer: {
            Text(L10n.Vocabulary.promptFooter)
        }
    }

    private func addDraft() {
        let word = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        if store.add(word) {
            draft = ""
            notice = nil
        } else {
            notice = store.count >= VocabularyStore.limit
                ? L10n.Vocabulary.full
                : L10n.Vocabulary.duplicate(word)
        }
    }

    private func pasteImport() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            notice = L10n.Vocabulary.pasteEmpty
            return
        }
        let added = store.importText(text)
        notice = added > 0
            ? L10n.Vocabulary.imported(added)
            : L10n.Vocabulary.importNone
    }
}

/// 词的来源明细（截图 5「看来源」）：哪几篇录音、各出现多少次。
private struct SourcesSheet: View {
    let entry: VocabEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(entry.word).font(.title3.weight(.semibold))
                }
                Section {
                    if entry.count > 0 {
                        Text(L10n.Vocabulary.sourceTotal(entry.count))
                            .font(.subheadline)
                    }
                    ForEach(entry.sources, id: \.self) { source in
                        Text(source)
                    }
                } header: {
                    Text(L10n.Vocabulary.sourcesHeader)
                }
            }
            .navigationTitle(L10n.Vocabulary.sourcesTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
        }
    }
}
