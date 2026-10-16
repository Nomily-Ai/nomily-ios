import SwiftUI

/// 回收站页（设置 → 回收站）。
///
/// ## 为什么这个功能在手机上
/// 用户原话是"需要在设置里面增加一个回收站的功能防止误删，30 天的保护期"。
/// 删除动作本来就发生在手机上（资料库多选删整条、详情页删音频/转录/摘要），
/// 只有把回收站放在这一侧才盖得住所有入口。手表那边能删的只有录音卡上的
/// 文件，"保护"不了手机上已经收下来的那一份。
///
/// ## 这里有三个动作，别混
/// * **恢复** —— 文件搬回资料库，设备下载的那条凭据也补回去（否则列表里
///   来源标识会变成"导入"）。
/// * **永久删除** —— 只删这一条。
/// * **清空** —— 全删。两个删除都带二次确认，恢复不需要（它是无损的）。
///
/// ★ 2026-10-15 二改：三个动作现在都**在行里摆着按钮**，滑动只是捷径。
/// 一改时恢复只有左滑、永久删除只有右滑，用户进来看到的是一行行"删得掉"
/// 的记录，于是反馈"怎么只有删除"。同一行还补上了**来源**。
///
/// ★★ 2026-10-16 十四改（用户："回收站支持多选全选选择恢复或者是删除"）：
///
/// 多选模式是**一颗按钮显式进出的**，不是"长按进入" —— 资料库那边长按进多选
/// 是因为它的行**短**、长按不冲突；回收站每一行都摆着两颗按钮，长按的手势
/// 识别会和按钮抢，而且这一页的行**高**（四行内容），误按成本也更高。
///
/// * 工具栏：非多选时是"选择"（左）+ "清空"（右）；多选时是
///   "全选 / 全不选"（左）+ "完成"（右）——"清空"在多选里**收起来**，
///   它和多选的功能重叠，而且两个破坏性入口同时摆着只会互相干扰。
/// * 底部：恢复（无损，不做二次确认）+ 删除（**带**二次确认，条数写进弹窗）。
/// * 行：多选时**整行可点**（切换勾选），行内那两颗按钮与滑动动作都收起来 ——
///   在多选里还摆着"恢复这一条"会让人误以为勾选没生效。
struct TrashView: View {
    @EnvironmentObject private var env: AppEnvironment
    @ObservedObject private var trash = ClipTrash.shared

    /// 待确认的操作。用一个可选值承载"哪一条"，而不是 `Bool` + 另外一个
    /// 存 item 的 `@State` —— 后者在弹窗出现到点确认之间可以被改写。
    @State private var pendingPurge: ClipTrash.TrashedItem?
    @State private var showPurgeAll = false
    @State private var restoreFailed = false

    // MARK: 多选状态（★ 十四改）

    /// 是否处于多选模式。
    @State private var isSelecting = false
    /// 勾选了哪些。存 `TrashedItem.id`（就是被删那条的文件名），不存对象 ——
    /// 列表会因 `purgeExpired()` / 别的入口随时变，存对象会拿到一份过期快照。
    @State private var selected: Set<String> = []
    /// 批量永久删除的二次确认。
    @State private var showPurgeSelected = false

    /// 勾选的那几条，**按列表顺序**（不是勾选顺序）。
    ///
    /// ⚠️ 必须过滤一遍：`selected` 里可能留着已经被清掉的 id（比如刚点了
    /// "清空"，或者 30 天保护期到了自动清了）。不滤的话批量操作会拿到
    /// 不存在的条目，`purge` 那边虽然安全，但"恢复 3 条"实际只恢复 2 条
    /// 这种账就对不上了。
    private var selectedItems: [ClipTrash.TrashedItem] {
        trash.items.filter { selected.contains($0.id) }
    }

    /// 是不是"全选了"。空列表不算全选 —— 那颗按钮此时应该显示"全选"。
    private var allSelected: Bool {
        !trash.items.isEmpty && selected.count == trash.items.count
    }

    /// ★ 2026-10-16 十三改：跟着 **App 语言**走（`AppLocale`），不是设备语言。
    /// 原来是个 `static let`，locale 默认取 `Locale.current` —— 在 App 里选英文
    /// 之后这一列时间仍然是中文（"语音的年月日"那条反馈的另一处来源）。
    private static var dateFormatter: DateFormatter {
        AppLocale.formatter("trash.row_date") { f in
            f.dateStyle = .medium
            f.timeStyle = .short
        }
    }

    var body: some View {
        Group {
            if trash.items.isEmpty {
                EmptyStateView(
                    L10n.Trash.emptyTitle,
                    systemImage: "trash.slash",
                    message: L10n.Trash.emptyMessage
                )
            } else {
                List {
                    Section {
                        ForEach(trash.items) { item in
                            if isSelecting {
                                selectableRow(item)
                            } else {
                                row(item)
                            }
                        }
                    } footer: {
                        Text(L10n.Trash.retentionFooter(ClipTrash.retentionDays))
                    }
                }
            }
        }
        .navigationTitle(L10n.Trash.title)
        .navigationBarTitleDisplayMode(.inline)
        // ★ 十四改：多选模式的底部操作条。
        .safeAreaInset(edge: .bottom) { selectionBar }
        .toolbar { toolbarContent }
        // 进这一页就清一次过期的 —— 这是"30 天后自动删除"的第二个触发点
        // （第一个在 App 启动时）。没有后台任务可挂，只能靠用户还会打开它。
        //
        // ⚠️ 它会**改** `trash.items`，所以勾选集里可能从此留下孤儿 id ——
        //    `selectedItems` 已经按"先过滤"处理了，这里不用额外收。
        .onAppear { trash.purgeExpired() }
        // 离开这一页就把多选收掉：回来时看到的应该是普通列表，
        // 而不是一个"勾了一半、又不知道勾了什么"的多选模式。
        .onDisappear {
            isSelecting = false
            selected.removeAll()
        }
        .onChange(of: trash.items) { items in
            // ★ 十四改：列表变了就同步勾选集（`purgeExpired` / 别的入口清掉条目时）。
            //    直接用"交集"赋值，顺带把孤儿 id 清掉。
            let live = Set(items.map(\.id))
            selected.formIntersection(live)
            // 一条不剩时退出多选 —— 留在一个空的多选模式里只会让人困惑。
            if isSelecting, items.isEmpty { isSelecting = false }
        }
        .alert(
            L10n.Trash.deleteForeverTitle,
            isPresented: Binding(
                get: { pendingPurge != nil },
                set: { if !$0 { pendingPurge = nil } }
            ),
            presenting: pendingPurge
        ) { item in
            Button(L10n.Trash.deleteForever, role: .destructive) {
                trash.purge(item)
                selected.remove(item.id)
            }
            Button(L10n.Common.cancel, role: .cancel) { pendingPurge = nil }
        } message: { item in
            Text("\(item.title)\n\n\(L10n.Trash.deleteForeverMessage)")
        }
        .alert(L10n.Trash.emptyAllTitle, isPresented: $showPurgeAll) {
            Button(L10n.Trash.emptyAll, role: .destructive) { trash.purgeAll() }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Trash.emptyAllMessage(trash.items.count))
        }
        // ★ 十四改：批量永久删除的确认。条数必须写进弹窗 —— 删除是不可逆的，
        //   用户得在点下去之前知道"到底删几条"。
        .alert(L10n.Trash.deleteSelectedTitle, isPresented: $showPurgeSelected) {
            Button(L10n.Trash.deleteSelected(selectedItems.count), role: .destructive) {
                purgeSelected()
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Trash.deleteSelectedMessage(selectedItems.count))
        }
        .alert(L10n.Trash.restoreFailedTitle, isPresented: $restoreFailed) {
            Button(L10n.Common.ok, role: .cancel) {}
        } message: {
            Text(L10n.Trash.restoreFailedMessage)
        }
    }

    // MARK: - 工具栏（★ 十四改）

    /// 两种形态：普通 = 选择 + 清空；多选 = 全选/全不选 + 完成。
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !trash.items.isEmpty {
            if isSelecting {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(allSelected ? L10n.Trash.deselectAll : L10n.Trash.selectAll) {
                        if allSelected {
                            selected.removeAll()
                        } else {
                            selected = Set(trash.items.map(\.id))
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Common.done) {
                        isSelecting = false
                        selected.removeAll()
                    }
                }
            } else {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(L10n.Trash.select) {
                        isSelecting = true
                        selected.removeAll()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(L10n.Trash.emptyAll, role: .destructive) { showPurgeAll = true }
                }
            }
        }
    }

    // MARK: - 多选的底部操作条（★ 十四改）

    /// 只在多选模式**且确实勾了东西**时出现。
    ///
    /// ⚠️ 用 `safeAreaInset` 而不是 `overlay(alignment: .bottom)`：前者会把
    ///   列表的可用高度**让出来**，最后一行不会被这条挡住（`overlay` 会盖上去）。
    @ViewBuilder
    private var selectionBar: some View {
        if isSelecting, !selectedItems.isEmpty {
            HStack(spacing: 12) {
                Button {
                    restoreSelected()
                } label: {
                    Label(L10n.Trash.restoreSelected(selectedItems.count),
                          systemImage: "arrow.uturn.backward")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.green)

                Button(role: .destructive) {
                    showPurgeSelected = true
                } label: {
                    Label(L10n.Trash.deleteSelected(selectedItems.count),
                          systemImage: "trash")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    // MARK: - 一行

    /// 一行。
    ///
    /// ★ 2026-10-15 二改（用户："回收站里面怎么只有删除，还需要增加这音频的
    /// 来源，还需要增加恢复当前录音"）：
    ///
    /// * **来源** —— 加在标题下面一行小字。数据是**删除那一刻**记下来的
    ///   （`TrashedItem.source`），因为 `move` 一执行就把 manifest 里那条
    ///   记录注销了，之后再问 `Library` 只会得到"导入"。
    /// * **恢复做成显式按钮**。原来只有**左滑**才有恢复，右滑是永久删除 ——
    ///   两边的滑动方向还只有一句注释知道。用户只看到一行行"删得掉"的记录，
    ///   自然觉得"这里怎么只有删除"。现在两个动作都在行里摆着：
    ///   恢复（绿、描边）在外侧、永久删除（红）在最右，滑动照旧保留。
    private func row(_ item: ClipTrash.TrashedItem) -> some View {
        rowContent(item)
            // 滑动动作照旧保留 —— 手势是给熟手的捷径，按钮是给所有人的入口，
            // 两者不冲突。（多选模式用的是 `selectableRow`，不挂这套。）
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    restore(item)
                } label: {
                    Label(L10n.Trash.restore, systemImage: "arrow.uturn.backward")
                }
                .tint(.green)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { pendingPurge = item } label: {
                    Label(L10n.Trash.deleteForever, systemImage: "trash")
                }
            }
    }

    /// 一行的**内容**（不带滑动动作）。
    ///
    /// ★ 十四改拆出来的：多选模式要复用这份排版（`selectableRow`），
    /// 但**不能**带滑动动作 —— 滑动手势会和"整行可点"的勾选抢，
    /// 而且多选里已经有批量入口了。
    ///
    /// ★ 2026-10-15 二改（用户："回收站里面怎么只有删除，还需要增加这音频的
    /// 来源，还需要增加恢复当前录音"）：
    ///
    /// * **来源** —— 加在标题下面一行小字。数据是**删除那一刻**记下来的
    ///   （`TrashedItem.source`），因为 `move` 一执行就把 manifest 里那条
    ///   记录注销了，之后再问 `Library` 只会得到"导入"。
    /// * **恢复做成显式按钮**。原来只有**左滑**才有恢复，右滑是永久删除 ——
    ///   两边的滑动方向还只有一句注释知道。用户只看到一行行"删得掉"的记录，
    ///   自然觉得"这里怎么只有删除"。现在两个动作都在行里摆着：
    ///   恢复（绿、描边）在外侧、永久删除（红）在最右，滑动照旧保留。
    private func rowContent(_ item: ClipTrash.TrashedItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.body)
                .lineLimit(2)

            // 来源。老索引里没有这个字段（`decodeIfPresent` 给到 nil）时整行不显示，
            // 而不是补一句"未知来源" —— 那对用户没有任何信息量。
            if let source = item.source, !source.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .imageScale(.small)
                    Text(source)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            // 里面还剩什么。**必须显示**：回收站里可能躺着一条"只删了转录"
            // 的记录，光看标题会以为整条都没了。
            HStack(spacing: 6) {
                if item.hasAudio { chip(L10n.Trash.artefactAudio, "waveform") }
                if item.hasTranscript { chip(L10n.Trash.artefactTranscript, "text.bubble") }
                if item.hasSummary { chip(L10n.Trash.artefactSummary, "doc.plaintext") }
            }

            HStack(spacing: 8) {
                Text("\(L10n.Trash.deletedOn) \(Self.dateFormatter.string(from: item.deletedAt))")
                if item.bytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                }
                Spacer(minLength: 4)
                Text(L10n.Trash.daysLeft(item.daysLeft))
                    .foregroundStyle(item.daysLeft <= 3 ? Color.orange : Color.secondary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            // 两个动作都摆出来。恢复放在前面（主操作），永久删除退到后面 ——
            // 恢复是无损的，永久删除不是。
            HStack(spacing: 8) {
                Button {
                    restore(item)
                } label: {
                    Label(L10n.Trash.restore, systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.green)

                Button(role: .destructive) {
                    pendingPurge = item
                } label: {
                    Label(L10n.Trash.deleteForever, systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
            .padding(.vertical, 4)
    }

    /// 恢复一条。
    ///
    /// 抽成函数是因为现在有**两个**入口（行内按钮 + 左滑）—— 两处各写一遍
    /// 迟早会漏掉其中一处该发的通知。那句 `libraryDidChange` 是必须的：
    /// `LibraryView` 的 `.task` 只在从详情页返回时重跑，回收站是另一条路径。
    private func restore(_ item: ClipTrash.TrashedItem) {
        if !trash.restore(item, library: env.library) { restoreFailed = true }
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    // MARK: - 多选（★ 十四改）

    /// 多选模式下的一行：**整行可点**，左边一枚勾选圈，行内的按钮与滑动全部收起。
    ///
    /// ⚠️ 用的还是 `row` 的**内容**（标题 / 来源 / 徽标 / 时间），只是外面套了一层
    ///   按钮。复制一份排版的话，两边迟早会长得不一样 —— 而这一页的行本来就
    ///   四层内容，是最不该复制的那种。
    private func selectableRow(_ item: ClipTrash.TrashedItem) -> some View {
        Button {
            toggle(item)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected.contains(item.id)
                        ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(selected.contains(item.id) ? Color.accentColor : Color.secondary)
                    // 勾选圈贴着首行，不贴整行 —— 行有四层内容，居中会漂。
                    .padding(.top, 2)

                row(item)
                    // 行内那两颗按钮在多选里没有意义（下面有批量入口），
                    // 整行都变成"切换勾选"的了。
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected.contains(item.id) ? [.isSelected] : [])
    }

    private func toggle(_ item: ClipTrash.TrashedItem) {
        if selected.contains(item.id) {
            selected.remove(item.id)
        } else {
            selected.insert(item.id)
        }
    }

    /// 批量恢复。**没有二次确认** —— 恢复是无损的（文件搬回资料库），
    /// 弹一个"确定要恢复吗"只会让人觉得这一页在防备一件好事。
    ///
    /// 通知只在**整批做完之后**发一次：`LibraryView` 重跑一次 `.task` 就够，
    /// 每条发一次只会让它重跑 N 遍。
    private func restoreSelected() {
        var anyFailed = false
        for item in selectedItems {
            if !trash.restore(item, library: env.library) { anyFailed = true }
        }
        if anyFailed { restoreFailed = true }
        selected.removeAll()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    /// 批量永久删除。弹窗在 `body` 里（条数要写进确认文案）。
    ///
    /// ⚠️ 遍历的是 `selectedItems` —— 那是**过滤过、按列表顺序**的一份快照，
    ///   循环里 `trash.items` 怎么变都不影响它。
    private func purgeSelected() {
        for item in selectedItems {
            trash.purge(item)
        }
        selected.removeAll()
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).imageScale(.small)
            Text(text)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}
