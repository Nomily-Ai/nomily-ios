import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Library segment of the Recordings tab. Lists every playable clip in
/// `audio_clips/decrypted/` (the dir `RecordingsView.writeAndDecrypt`
/// drops files into) sorted newest-first, with a transcript-ready
/// badge derived from the side-by-side `{name}.txt` produced by
/// `TranscriptionService`.
struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @StateObject private var model = LibraryListModel()
    /// Solely so that "after a card is renamed, the source badge in the list follows along."
    ///
    /// Why the store must be hooked up as observed: the source badge takes the SN to
    /// `RecorderAliasStore` to look up the alias, and that is a **plain dictionary lookup** — SwiftUI doesn't know
    /// it needs to redraw — the comment at the top of `RecorderAliasStore` records the same pitfall
    /// (that's exactly how `DiscoveredRecorder.displayName` fell into it).
    @ObservedObject private var recorderAliases = RecorderAliasStore.shared
    /// 未读红点靠它。必须挂成被观察的：`isUnread` 是一次**字典查询**，
    /// 打开详情把名字写进去之后，SwiftUI 不会自己知道要重绘（同一个坑见
    /// 上面 `recorderAliases` 那段注释）。
    @ObservedObject private var readStore = ClipReadStore.shared
    /// 「上一份导出已经备好、还没分享」的那本账。挂成被观察的：
    /// 导出是在一个 detached 的 `Task` 里完成的，SwiftUI 不会自己知道
    /// 要重绘横幅（同上面 `readStore` 那个坑）。
    @ObservedObject private var exportCenter = ExportCenter.shared
    @State private var showImportConfirm = false
    @State private var showImporter = false
    @State private var importError: String?
    @State private var pendingMerge: MergePair?

    /// 忙的时候显示的那层遮罩上的文案；`nil` = 不显示。
    ///
    /// 合并 / 导出暂存 / 批量删除三件事共用一层遮罩 —— 它们都短则几百毫秒、
    /// 长则几十秒（导出要逐个 copy 音频），期间**必须挡住点击**：
    /// 不然用户能在删除进行到一半时又点一次导出。
    @State private var busyMessage: String?
    @State private var mergeError: String?
    /// 批量导出失败的详情（标题固定是 `L10n.Library.exportFailed`）。
    ///
    /// 和 `mergeError` / `importError` 一样是"一个字符串就是一个弹窗"的写法：
    /// 弹窗标题在 `.alert(_:isPresented:)` 上是固定的，所以**导出和删除必须
    /// 分开两个状态**，不然失败理由会顶着另一个动作的标题弹出来。
    @State private var exportError: String?
    @State private var deleteError: String?

    // MARK: 多选（★ 2026-10-15，用户要求"长按选择 + 批量导出/删除"）
    //
    // 结构与 `RecorderSheet` 的那套**刻意一致**（`isSelecting` + `selectedIDs`
    // + 底部 selectionBar），差别只在：那边是"传选中"，这边是"导出/删除选中"。
    // 表盘/手机上同一个动作长得一样，用户不用重新学。
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showBatchDeleteConfirm = false
    /// 程序化导航的目标。**不用 `NavigationLink`** 的原因见 `row(_:)`。
    @State private var detailItem: LibraryItem?

    // MARK: 知识库检索
    @State private var query = ""
    @State private var scope: LibrarySearchScope = .knowledge
    /// `base -> 命中片段`。空 = 没在搜，或者这条正文没命中。
    @State private var snippets: [String: String] = [:]
    @State private var isSearching = false
    /// 导出暂存的顶层目录（交给系统分享面板的那个）。
    @State private var exportURL: URL?
    @State private var showExportSheet = false

    /// 只看某台设备。`nil` = 全部。值是 `deviceKey(_:)` 给出的那把键。
    @State private var deviceFilter: String?

    private struct MergePair: Identifiable {
        let older: LibraryItem
        let newer: LibraryItem
        var id: String { "\(older.id)|\(newer.id)" }
    }

    /// Max gap between the older clip's *end* (its `modifiedAt`,
    /// which is when the file finalised on disk) and the newer
    /// clip's *start* (`modifiedAt - duration`). Wide enough to
    /// cover an accidental stop+restart mid-meeting but tight
    /// enough that unrelated clips don't get the swipe action.
    private static let adjacentThreshold: TimeInterval = 10 * 60

    var body: some View {
        content
        // ★ 2026-10-15 七改：设备筛选条**钉在列表顶上**，不再藏进工具栏菜单。
        //
        // 用 `safeAreaInset` 而不是把它塞进 `List` 的第一个 section：塞进去会跟着
        // 列表一起滚走 —— 而"现在筛的是哪台设备"恰恰是滚动时最需要一直看得见的信息。
        //
        // 放在 `.searchable` 下面一层：搜索栏归搜索，筛选条归筛选，两个都在顶上，
        // 互不遮挡。
        .safeAreaInset(edge: .top, spacing: 0) {
            deviceFilterBar
        }
        .task {
            await model.refresh()
            dropStaleDeviceFilter()
        }
        // A watch recording can land while this list is on screen; the file
        // arrives outside any SwiftUI lifecycle, so it has to say so.
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in
            Task {
                await model.refresh()
                dropStaleDeviceFilter()
            }
        }
        // 知识库检索。`.task(id:)` 是关键：查询或作用域一变，SwiftUI 会把
        // **上一次整条取消**，于是打字很快时也不会同时跑好几轮读盘。
        .task(id: searchKey) { await runSearch() }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(L10n.Library.searchPrompt)
        )
        .searchScopes($scope) {
            ForEach(LibrarySearchScope.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting { selectionBar }
        }
        .navigationDestination(isPresented: Binding(
            get: { detailItem != nil },
            set: { if !$0 { detailItem = nil } }
        )) {
            if let detailItem { ClipDetailView(item: detailItem) }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSelecting {
                    Button(L10n.Common.cancel) { exitSelection() }
                } else {
                    HStack(spacing: 16) {
                        Button(L10n.Library.select) {
                            selectedIDs = []
                            isSelecting = true
                        }
                        // 搜索期间不给进多选：结果集会随输入变化，
                        // 已经勾上的条目可能在你敲下一个字时从屏幕上消失，
                        // 而选中集合还留着它 —— 那时"已选 3 条"和屏幕对不上。
                        .disabled(model.items.isEmpty || isSearchActive)

                        Button { showImportConfirm = true } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .accessibilityLabel(L10n.Library.importAudio)
                    }
                }
            }
        }
        .alert(L10n.Library.importConfirmTitle, isPresented: $showImportConfirm) {
            Button(L10n.Library.importChooseFile) { showImporter = true }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Library.importConfirmMessage)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result: result)
        }
        .alert(
            L10n.Library.importFailed,
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            ),
            presenting: importError
        ) { _ in
            Button(L10n.Common.ok, role: .cancel) { importError = nil }
        } message: { msg in
            Text(msg)
        }
        .alert(
            L10n.Library.mergeConfirmTitle,
            isPresented: Binding(
                get: { pendingMerge != nil },
                set: { if !$0 { pendingMerge = nil } }
            ),
            presenting: pendingMerge
        ) { pair in
            Button(L10n.Library.merge, role: .destructive) {
                let captured = pair
                Task { await runMerge(older: captured.older, newer: captured.newer) }
            }
            Button(L10n.Common.cancel, role: .cancel) { pendingMerge = nil }
        } message: { pair in
            Text(L10n.Library.mergeConfirmMessage(pair.older.displayTitle, pair.newer.displayTitle))
        }
        .alert(
            L10n.Library.mergeFailed,
            isPresented: Binding(
                get: { mergeError != nil },
                set: { if !$0 { mergeError = nil } }
            ),
            presenting: mergeError
        ) { _ in
            Button(L10n.Common.ok, role: .cancel) { mergeError = nil }
        } message: { msg in
            Text(msg)
        }
        // 批量删除的二次确认。用的是 `.alert` 而不是 `.confirmationDialog`：
        // 它要带一句说清"会连带删掉转录和摘要、不可撤销"的副文案。
        .alert(L10n.Library.deleteSelectedTitle, isPresented: $showBatchDeleteConfirm) {
            Button(L10n.Common.delete, role: .destructive) {
                Task { await runBatchDelete() }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Library.deleteSelectedMessage(selectedIDs.count))
        }
        .alert(
            L10n.Library.exportFailed,
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ),
            presenting: exportError
        ) { _ in
            Button(L10n.Common.ok, role: .cancel) { exportError = nil }
        } message: { msg in
            Text(msg)
        }
        .alert(
            L10n.Library.deleteFailed,
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            ),
            presenting: deleteError
        ) { _ in
            Button(L10n.Common.ok, role: .cancel) { deleteError = nil }
        } message: { msg in
            Text(msg)
        }
        // 导出走系统分享面板：存到"文件"、AirDrop、发给别人都是它。
        // 给的是**目录**（每条一个子目录），不是压缩包 —— 见 `runBatchExport`。
        .sheet(isPresented: $showExportSheet, onDismiss: { exportURL = nil }) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .overlay {
            if let busyMessage {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(busyMessage)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    /// Returns the older clip immediately following `item` in the
    /// time-sorted list, if the gap between the two is short enough
    /// to count as "the user stopped + restarted the device".
    /// `items` is sorted newest-first, so the older peer lives at
    /// `index + 1`.
    ///
    /// Gap = (newer's start) − (older's end). For device clips the
    /// filename (`yyyyMMddHHmmss.opus`) gives us the recording start
    /// directly, so older's end = parsed start + duration. For imports
    /// we fall back to the legacy mtime proxy (mtime ≈ end, start ≈
    /// mtime − duration); this is lossy on iPhone-copied files but
    /// it's the only signal we have. If we can't derive a duration we
    /// hide the action rather than guess — better to miss a real
    /// adjacency than offer to merge unrelated clips.
    private func adjacentOlder(at index: Int) -> LibraryItem? {
        guard index + 1 < model.items.count else { return nil }
        let newer = model.items[index]
        let older = model.items[index + 1]
        guard newer.hasAudio, older.hasAudio else { return nil }
        let newerStart: Date
        if let t = RecordingName.date(from: newer.name) {
            newerStart = t
        } else if let d = newer.duration {
            newerStart = newer.modifiedAt.addingTimeInterval(-d)
        } else {
            return nil
        }
        let olderEnd: Date
        if let t = RecordingName.date(from: older.name) {
            guard let d = older.duration else { return nil }
            olderEnd = t.addingTimeInterval(d)
        } else {
            olderEnd = older.modifiedAt
        }
        let gap = newerStart.timeIntervalSince(olderEnd)
        // Allow a touch of negative jitter — filename timestamps round
        // to the second, so two truly back-to-back clips can land a
        // fraction overlapping.
        guard gap >= -2, gap <= Self.adjacentThreshold else { return nil }
        return older
    }

    private func runMerge(older: LibraryItem, newer: LibraryItem) async {
        busyMessage = L10n.Library.merging
        defer { busyMessage = nil }
        do {
            _ = try await AudioMerger.merge(older: older, newer: newer)
            deleteSourceArtefacts(for: older)
            deleteSourceArtefacts(for: newer)
            await model.refresh(force: true)
        } catch {
            mergeError = error.localizedDescription
        }
    }

    /// Mirrors the cleanup list in `deleteURLs(for:)`, minus the in-memory
    /// player stop (we're operating from the Library, not Detail). Kept in
    /// sync deliberately — that's why it now just calls `deleteURLs(for:)`
    /// instead of listing the suffixes a second time: forgetting an artefact
    /// in one of the two copies leaves orphan files after a merge.
    ///
    /// ★ 2026-10-15：合并时被顶替掉的两条源录音也**进回收站**。合并出来的
    /// M4A 要是听着不对（串了、缺了一半），两条源录音还能原样捞回来 ——
    /// 而这一步恰恰是"用户看不见文件、却真的没了"的典型场景。
    ///
    /// ⚠️ **不带 download 凭据**：注销 manifest 会让这两条在设备列表里
    /// 重新变回"未下载"，而它们其实就在用户手机上（现在还在回收站里）。
    /// 合并本来也不改 manifest，这里保持一致。
    private func deleteSourceArtefacts(for item: LibraryItem) {
        ClipTrash.shared.move(
            [ClipTrash.Payload(
                localName: item.name,
                title: item.displayTitle,
                urls: Self.deleteURLs(for: item),
                download: nil,
                source: ClipTrash.sourceLabel(forLocalName: item.name, in: library)
            )],
            library: library
        )
    }

    private func handleImport(result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            var failures: [String] = []
            for source in urls {
                let granted = source.startAccessingSecurityScopedResource()
                defer { if granted { source.stopAccessingSecurityScopedResource() } }
                do {
                    _ = try AudioImporter.importFile(from: source)
                } catch {
                    failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            Task { await model.refresh(force: true) }
            if !failures.isEmpty {
                importError = failures.joined(separator: "\n")
            }
        } catch {
            importError = error.localizedDescription
        }
    }

    // MARK: - 列表 / 空态

    /// 四选一：空库 / 检索中 / 筛完没命中 / 正片。
    ///
    /// 单独拆出来不是为了好看：`body` 上挂着 `.searchable` + 作用域 + 5 个
    /// `.alert` + sheet + overlay，再把这四层分支塞进去，类型检查器就要
    /// 超时（实测 "unable to type-check this expression in reasonable time"）。
    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            EmptyStateView(
                L10n.Recordings.noClipsYet,
                systemImage: "tray",
                message: L10n.Recordings.noClipsMessage
            )
        } else if isSearchActive, sections.isEmpty, isSearching {
            // 第一次检索要先读盘建索引（库里几百条有正文时会有一小会儿）。
            // 这期间**不能**报"没找到" —— 那是假话，而且用户会以为搜错了。
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sections.isEmpty {
            // 走到这里只可能是"筛/搜完没命中"（库本身非空，见上面两个分支）。
            EmptyStateView(
                L10n.Library.searchEmptyTitle,
                systemImage: "magnifyingglass",
                message: L10n.Library.searchEmptyMessage
            )
        } else {
            listContent
        }
    }

    /// 一个 `Section` = 一个（时间 × 设备）。桶标题只在同桶的第一个分节头上
    /// 出现（见 `LibrarySection.showsBucketTitle`），于是读下来就是
    /// "今天 → 三台设备 → 昨天 → ……"的两层结构，而不是给每个设备都重复
    /// 一遍"今天"。
    private var listContent: some View {
        List {
            // ★ 2026-10-15 六改：导出已就绪的横幅，**放在最上面**。
            //
            // 用户原话："导出音频对于大文件音频需要等待很久这个需要挂在后台，
            // 也支持等 App 完成后来点击传输，防止退出需要重新等待"。
            // 大文件导出能等到用户去干别的事甚至切出 App；回来时如果页面上
            // 没有任何线索，用户唯一能想到的就是**再导一次**，于是又等一遍。
            if let staged = exportCenter.ready {
                exportReadySection(staged)
            }
            ForEach(sections) { section in
                Section {
                    rows(of: section)
                } header: {
                    sectionHeader(section)
                }
            }
        }
        .environment(\.defaultMinListHeaderHeight, 0)
    }

    /// 上一份导出已经备好、还没分享出去。
    ///
    /// 两个动作：整行点一下 = 分享（唯一的正向动作，所以让整行都可点），
    /// 右侧垃圾桶 = 清掉这份中转文件释放空间（**不动**用户的资料库，
    /// 删的只是导出时复制出来的那一份副本）。
    private func exportReadySection(_ item: ExportCenter.Ready) -> some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    exportURL = ExportCenter.shared.url(for: item)
                    showExportSheet = exportURL != nil
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.Library.exportReady)
                                .foregroundStyle(.primary)
                            Text(Self.exportReadyDetail(item))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    ExportCenter.shared.discard()
                } label: {
                    Label(L10n.Library.clearExportStaging, systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Library.clearExportStaging)
            }
            .padding(.vertical, 2)
        } footer: {
            Text(L10n.Library.exportReadyFooter)
        }
    }

    private static func exportReadyDetail(_ item: ExportCenter.Ready) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
        return "\(item.title) · \(L10n.Library.exportReadyFiles(item.itemCount)) · \(size)"
    }

    @ViewBuilder
    private func rows(of section: LibrarySection) -> some View {
        ForEach(section.entries) { entry in
            row(entry.item, at: entry.modelIndex, unread: entry.unread)
        }
    }

    // MARK: - 列表行

    /// 一行。点开详情、长按进多选、右滑合并。
    ///
    /// 用 `LongPressGesture.exclusively(before: TapGesture())` 而不是
    /// "Button + onLongPressGesture"：后者两个手势是**各自独立**识别的，
    /// 长按松手时 Button 的 action 有可能照样触发一次 —— 表现就是"长按选了，
    /// 顺带还跳进了详情页"。`exclusively` 把优先级写死：长按成立，点按就不认。
    ///
    /// `unread` 由分节时**一并算好**传进来，行里不再回头查账本：
    /// 一次 `isUnread` 是一次字典查询，1900 行每次重绘都查一遍没必要。
    private func row(_ item: LibraryItem, at index: Int, unread: Bool) -> some View {
        let isSelected = selectedIDs.contains(item.name)
        return HStack(spacing: 10) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .transition(.scale.combined(with: .opacity))
            }
            LibraryRow(
                item: item,
                source: library.source(forLocalName: item.name),
                snippet: snippets[item.base],
                isUnread: unread
            )
            if !isSelecting {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        // 没有 Button 之后，命中区域不再自动铺满整行 —— 只有文字能点。
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .gesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    guard !isSelecting else { return }
                    enterSelection(with: item)
                }
                .exclusively(
                    before: TapGesture().onEnded {
                        if isSelecting {
                            toggleSelection(item)
                        } else {
                            detailItem = item
                        }
                    }
                )
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // 搜索态下不给合并：屏幕上只有命中的那几条，而"相邻"是按**整库**
            // 的时间序算的 —— 那条邻居此刻根本不在列表里，合并完会让人以为
            // "把别的东西吃掉了"。
            if !isSelecting, !isSearchActive, let older = adjacentOlder(at: index) {
                Button {
                    pendingMerge = MergePair(older: older, newer: item)
                } label: {
                    Label(L10n.Library.merge, systemImage: "arrow.triangle.merge")
                }
                .tint(.indigo)
            }
        }
    }

    /// 分节头：第一行是时间桶，第二行是设备。
    ///
    /// 桶标题只在同桶的第一个分节上出现一次（同桶后面几台设备不再重复写
    /// "今天"）—— 这就是两层归类的样子。桶那一行右侧挂的是**整桶**的
    /// 条数与大小，不是单个分节的，否则"今天"下面三台设备各写一遍数字，
    /// 反而看不出今天一共多少。
    @ViewBuilder
    private func sectionHeader(_ section: LibrarySection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if section.showsBucketTitle {
                HStack(alignment: .firstTextBaseline) {
                    Text(section.bucketTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(L10n.Library.shortCount(section.bucketCount)) · \(formatBytes(section.bucketBytes))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                Text(section.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if section.unreadCount > 0 {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    Text(L10n.Library.unreadCount(section.unreadCount))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        // 列表默认会把这些字转成大写、染成灰色；我们要自己的层级。
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }

    // MARK: - 派生状态

    private var isSearchActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 列表上真实可见的条目（已过设备筛选 + 搜索），分节之前的样子。
    /// 全选、条数这类"整屏"判断用它，而不是 `model.items`。
    private var visibleEntries: [LibraryEntry] {
        sections.flatMap(\.entries)
    }

    /// 把当前可见条目按 **时间 → 设备** 两层归类。
    ///
    /// 一次遍历同时干三件事：过筛（设备 + 搜索）、记下每条在**整库**里的下标
    /// （`adjacentOlder` 要按整库的时间序找邻居）、按桶和设备归位。
    /// 分开写会变成三次 1900 条的遍历，而且 "显示的是什么" 会散在两处，
    /// 将来加一个筛选项必定漏改一处。
    private var sections: [LibrarySection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = !needle.isEmpty
        let filter = effectiveDeviceFilter

        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        // 「本周」= 本自然周的第一天。用 `dateInterval` 而不是"减 7 天"：
        // 这样跟随系统区域的周首日（中文一般是周一），而且"本周"就该是
        // 本周，不是"最近七天"。
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? startOfToday

        func bucket(of date: Date) -> LibraryTimeBucket {
            // 设备 RTC 没对表时可能给出**未来**时间；那种一律并进"今天"，
            // 否则列表最上面会冒出一个谁也没见过的月份。
            if date >= startOfToday { return .today }
            if date >= startOfYesterday { return .yesterday }
            if date >= weekStart { return .thisWeek }
            if date >= monthStart { return .thisMonth }
            let c = cal.dateComponents([.year, .month], from: date)
            return .month((c.year ?? 1970) * 100 + (c.month ?? 1))
        }

        // 1) 过筛 + 归位。`model.items` 本身是时间倒序，所以按顺序往每个
        //    (桶, 设备) 里追加，桶内和组内天然就是倒序；设备组的先后 = 该设备
        //    最新一条的先后，也不用额外排序。
        var perBucket: [LibraryTimeBucket: [String: [LibraryEntry]]] = [:]
        var deviceOrder: [LibraryTimeBucket: [String]] = [:]
        var deviceNames: [String: String] = [:]

        for (index, item) in model.items.enumerated() {
            let key = deviceKey(for: item)
            if let filter, key != filter { continue }
            if searching {
                let inBody = snippets[item.base] != nil
                switch scope {
                case .knowledge:
                    if !inBody { continue }
                case .all:
                    // 「全部」比「知识库」多的就是这条：还没转录、只有名字的录音。
                    if !inBody, !item.matchesName(needle) { continue }
                }
            }
            let b = bucket(of: item.recordedAt)
            if perBucket[b]?[key] == nil {
                deviceNames[key] = deviceName(for: item)
                deviceOrder[b, default: []].append(key)
            }
            perBucket[b, default: [:]][key, default: []].append(LibraryEntry(
                item: item,
                modelIndex: index,
                unread: readStore.isUnread(name: item.name, arrivedAt: item.modifiedAt)
            ))
        }

        // 2) 按时间倒序输出（今天 → 昨天 → 本周 → 本月 → 各月从新到旧）。
        var monthCache: [Int: String] = [:]
        func title(of b: LibraryTimeBucket) -> String {
            switch b {
            case .today: return L10n.Library.bucketToday
            case .yesterday: return L10n.Library.bucketYesterday
            case .thisWeek: return L10n.Library.bucketThisWeek
            case .thisMonth: return L10n.Library.bucketThisMonth
            case let .month(key):
                if let cached = monthCache[key] { return cached }
                let comps = DateComponents(year: key / 100, month: key % 100, day: 1)
                let text = Self.monthFormatter.string(from: cal.date(from: comps) ?? now)
                monthCache[key] = text
                return text
            }
        }

        let ordered = perBucket.keys.sorted {
            ($0.rank, $0.tiebreak) < ($1.rank, $1.tiebreak)
        }

        var out: [LibrarySection] = []
        for b in ordered {
            let groups = deviceOrder[b] ?? []
            let all = groups.flatMap { perBucket[b]?[$0] ?? [] }
            let bucketBytes = all.reduce(Int64(0)) { $0 + $1.item.size }
            for (i, key) in groups.enumerated() {
                let entries = perBucket[b]?[key] ?? []
                out.append(LibrarySection(
                    id: "\(b.id)|\(key)",
                    showsBucketTitle: i == 0,
                    bucketTitle: title(of: b),
                    deviceName: deviceNames[key] ?? key,
                    bucketCount: all.count,
                    bucketBytes: bucketBytes,
                    unreadCount: entries.reduce(0) { $0 + ($1.unread ? 1 : 0) },
                    entries: entries
                ))
            }
        }
        return out
    }

    /// 「2026年8月」/「August 2026」。用系统的模板化格式按区域拼，
    /// 自己接"年""月"两个字在另外 10 种语言里全是错的。
    ///
    /// ★ 2026-10-16 十三改：locale 从 `AppLocale` 取（**先设 locale 再调模板**）。
    ///
    /// ⚠️ 这里原来是个 `static let`，有两个独立的问题叠在一起：
    ///    ① locale 默认是 `Locale.current`（设备语言），App 里选英文不管用；
    ///    ② `setLocalizedDateFormatFromTemplate` 会在**调用那一刻**用
    ///       formatter 当时的 locale 把模板**烘死**成具体格式串 ——
    ///       所以即使后来把 locale 改了，模板也不会重算。必须重建 formatter，
    ///       这正是 `AppLocale.formatter(_:_:)` 按语言代次缓存要做的事。
    private static var monthFormatter: DateFormatter {
        AppLocale.formatter("library.bucket_month") { $0.setLocalizedDateFormatFromTemplate("yMMMM") }
    }

    // MARK: - 设备筛选

    /// 分组 / 筛选用的设备键。**两张卡必须是两组**，所以 SN 进键；
    /// 而展示名可以是用户改过的别名 —— 两者绝不能混用（别名会变，
    /// 一变分组就散架）。
    private func deviceKey(for item: LibraryItem) -> String {
        let source = library.source(forLocalName: item.name)
        switch source.kind {
        case .card: return "card|\(source.serial ?? "")"
        default: return source.kind.rawValue
        }
    }

    private func deviceName(for item: LibraryItem) -> String {
        library.source(forLocalName: item.name).displayName
    }

    /// 库里出现过的设备，按条数从多到少。给筛选项用。
    private var availableDevices: [(key: String, name: String, count: Int, bytes: Int64)] {
        var order: [String] = []
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        var sizes: [String: Int64] = [:]
        for item in model.items {
            let key = deviceKey(for: item)
            if counts[key] == nil {
                order.append(key)
                names[key] = deviceName(for: item)
            }
            counts[key, default: 0] += 1
            sizes[key, default: 0] += item.size
        }
        return order
            .map { (key: $0, name: names[$0] ?? $0, count: counts[$0] ?? 0, bytes: sizes[$0] ?? 0) }
            .sorted { $0.count > $1.count }
    }

    /// 选中的设备**此刻还在不在库里**。不在就当作"全部"。
    ///
    /// 为什么要这一层而不是在刷新后清 `deviceFilter`：把最后一条某设备的
    /// 录音删掉之后，列表必须立刻回到"全部"，而不是卡在一个空列表上等
    /// 用户自己去菜单里改回来。
    private var effectiveDeviceFilter: String? {
        guard let deviceFilter else { return nil }
        return availableDevices.contains { $0.key == deviceFilter } ? deviceFilter : nil
    }

    /// 库里没有这台设备了就清掉选择。纯计算层已经兜住了显示，这里只是
    /// 让菜单里的勾也跟着消失。
    private func dropStaleDeviceFilter() {
        guard let deviceFilter else { return }
        if !availableDevices.contains(where: { $0.key == deviceFilter }) {
            self.deviceFilter = nil
        }
    }

    // MARK: - 设备筛选条（★ 2026-10-15 七改）
    //
    // 原来是工具栏上的一个 `Menu`。用户原话："那个设备筛选做的不够让人理解，
    // 全部勾选不方便人选择，优化一下"。老写法有三个具体问题：
    //   1. 不进菜单就**看不见有哪些设备**，也看不见**现在筛的是哪台**；
    //   2. 菜单里"全部设备"和各台设备并排摆着，读起来像一组复选框
    //      （"全部"看着像"全被勾上了"）—— 而它其实是**单选**；
    //   3. 每项后面拖着"· 12 条 · 2.3 GB"，一行太长，被系统截断。
    // 改成横向胶囊条后三件事一次摊开：有哪些、各多少条、现在选的是哪个。

    /// 只有一台设备时不显示筛选条 —— 没什么可筛的，多一条只会挤占列表。
    ///
    /// 库里通常只有 TicNote 卡和手机两来源，`availableDevices` 为 1 意味着
    /// 所有录音都来自同一处，此时筛选是**空操作**。
    private var showsDeviceBar: Bool { availableDevices.count > 1 }

    @ViewBuilder
    private var deviceFilterBar: some View {
        if showsDeviceBar {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    deviceFilterChip(
                        title: L10n.Library.filterAllDevices,
                        count: model.items.count,
                        selected: effectiveDeviceFilter == nil
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) { deviceFilter = nil }
                    }
                    ForEach(availableDevices, id: \.key) { device in
                        deviceFilterChip(
                            title: device.name,
                            count: device.count,
                            selected: effectiveDeviceFilter == device.key
                        ) {
                            withAnimation(.easeInOut(duration: 0.18)) { deviceFilter = device.key }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.bar)
            .accessibilityLabel(L10n.Library.filterDevices)
        }
    }

    /// 一颗筛选胶囊。选中态是**实心 accent**，未选中是浅灰底 —— 对比足够强，
    /// 扫一眼就知道筛的是哪台（老菜单里那条勾只有 14pt，几乎看不见）。
    ///
    /// 条数做成胶囊里的小圆角标签而不是跟在名字后面的灰字：设备名长短不一
    /// （"TicNote Card · 3F2A" 能占满半屏），跟字的话条数会飘到看不见的地方。
    private func deviceFilterChip(
        title: String, count: Int, selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(selected
                                       ? Color.white.opacity(0.28)
                                       : Color.primary.opacity(0.08))
                    )
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(selected ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                Capsule().stroke(selected ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: - 全选 / 派生

    /// `.task(id:)` 的键：作用域 + 目录指纹 + 查询词。
    ///
    /// 带上指纹是必要的：库里"有什么"变了（新录一条、刚给某条生成摘要）之后
    /// 检索必须重跑。而且指纹正是 `LibraryKnowledgeIndex` 的缓存失效键 ——
    /// 同一个值同时管着"要不要重搜"和"正文缓存还算不算数"，不会出现
    /// "索引刷新了但屏幕上还是旧结果"。
    private var searchKey: String {
        let stamp = model.signature
            .map { "\($0.entryCount)@\($0.newestEntry.timeIntervalSince1970)" } ?? "-"
        return "\(scope.rawValue)|\(stamp)|\(query)"
    }

    /// 勾选出来的条目，按**列表顺序**（时间倒序）给出。
    ///
    /// 按 `model.items` 的顺序而不是 `selectedIDs` 的哈希序：导出目录里的
    /// 排序、删除失败时的报错顺序都跟着屏幕走，出问题时能一眼对上。
    /// 也不按 `visibleEntries`：勾完再改筛选条件不该把已勾的悄悄丢掉。
    private var selectedItems: [LibraryItem] {
        model.items.filter { selectedIDs.contains($0.name) }
    }

    /// 「全选」= 选中**屏幕上这一屏**（可能是搜出来的子集、也可能是筛过的
    /// 单台设备），不是整个库。
    private var allItemsSelected: Bool {
        let names = Set(visibleEntries.map(\.item.name))
        return !names.isEmpty && names.isSubset(of: selectedIDs)
    }

    private func selectAllVisible() {
        selectedIDs = Set(visibleEntries.map(\.item.name))
    }

    // MARK: - 多选

    private func enterSelection(with item: LibraryItem) {
        selectedIDs = [item.name]
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.2)) { isSelecting = true }
    }

    private func toggleSelection(_ item: LibraryItem) {
        if selectedIDs.contains(item.name) {
            selectedIDs.remove(item.name)
        } else {
            selectedIDs.insert(item.name)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func exitSelection() {
        selectedIDs.removeAll()
        withAnimation(.easeInOut(duration: 0.2)) { isSelecting = false }
    }

    private var selectionBar: some View {
        VStack(spacing: 10) {
            HStack {
                // ★ 七改：按钮上直接写"会勾上几条"。
                //
                // 用户原话"全部勾选不方便人选择"。原来的按钮只说"全选"，而全选的范围
                // 是**屏幕上这一屏**（可能已经按设备筛过、按词搜过），用户点之前完全
                // 不知道会勾多少条；点完才在下面看到"已选 12 条"。把数字搬到按钮上，
                // 点与不点的后果一眼可见。
                Button {
                    if allItemsSelected {
                        selectedIDs.removeAll()
                    } else {
                        selectAllVisible()
                    }
                } label: {
                    Text(allItemsSelected
                         ? L10n.Library.deselectAll
                         : L10n.Library.selectAllWithCount(visibleEntries.count))
                        .font(.subheadline)
                }
                .disabled(visibleEntries.isEmpty)

                Spacer()

                Text(L10n.Library.selectedCount(selectedIDs.count))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await runBatchExport() }
                } label: {
                    Label(L10n.Library.export, systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    showBatchDeleteConfirm = true
                } label: {
                    Label(L10n.Common.delete, systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            // 一条都没勾时两个动作都无从下手（导出空目录、删 0 条）——
            // 一起置灰，而不是等点了才弹一句"请先选择"。
            .disabled(selectedItems.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 知识库检索

    private func runSearch() async {
        guard isSearchActive else {
            // 退格到空 = 退出搜索，命中集合必须一起清掉，
            // 否则重新打一个字时会先闪一下**上一次**的结果。
            snippets = [:]
            isSearching = false
            return
        }
        // 只有带正文的条目才值得读盘（`hasText` 由扫描器在目录列举里判定，
        // 零额外 syscall）。「全部」也多读不了几个 —— 菜单/标题是内存里的比对。
        let bases = model.items.filter(\.hasText).map(\.base)
        isSearching = true
        let hits = await LibraryKnowledgeIndex.shared.search(
            query, bases: bases, stamp: model.signature
        )
        // 打字快的时候上一次会被 `.task(id:)` 整条取消；取消的那次别再写
        // `snippets` —— 否则旧结果会盖掉新一轮的。
        guard !Task.isCancelled else { return }
        snippets = hits
        isSearching = false
    }

    // MARK: - 批量导出

    // ⚠️ 暂存目录**已经不在这里了**。原先是一个固定的
    // `FileManager.default.temporaryDirectory/nomily-export`，2026-10-15
    // 六改时整个搬到了 `ExportCenter`，两个原因：
    //   1. `tmp` 会被 iOS 随时清掉，而"导完切走、回来再分享"正是要支持的路径；
    //   2. 需要一个地方记住"上一份备好了什么"，否则用户回来只有"从头再等"。
    // 取目录请用 `ExportCenter.shared.beginNewStaging()`。

    /// 一条录音在导出目录里的文件夹名：用**显示标题**（用户改过的名字）而不是
    /// 文件名 —— 导出是给人看的。
    ///
    /// 去 `:` 是必须的：iOS 上冒号是 HFS 的老分隔符，写路径时会被**悄悄**换成
    /// `/`，于是"记录 10:30"这种标题会凭空多出一层目录。
    /// 重名（两条都叫"会议"）按 `会议 (2)` 顺延，绝不覆盖。
    private static func exportFolderName(
        for item: LibraryItem, taken: inout Set<String>
    ) -> String {
        var base = item.displayTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = item.base }
        if base.count > 80 { base = String(base.prefix(80)) }
        var candidate = base
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(base) (\(n))"
            n += 1
        }
        taken.insert(candidate)
        return candidate
    }

    /// 一条录音的**文本**旁车：`(磁盘位置, 导出时的名字)`。
    ///
    /// 刻意**不含** `.asr.json` / `.translated.json`：那是给 App 自己回读的中间
    /// 格式（带时间轴、置信度、说话人），导出去对人没用。用户要的是
    /// "音频 + 转录/摘要**文本**"。
    ///
    /// 导出名写成能直读的英文（`Transcript.txt`）而不是落盘名
    /// （`20240101010101.txt`）：文件夹已经用标题命名了，里面再放一串时间戳
    /// 就白取了。一个文件夹只装一条录音，所以这几个名字不会撞。
    private static func textArtefacts(for item: LibraryItem) -> [(source: URL, name: String)] {
        let dir = StorageLocations.decryptedDir
        func url(_ suffix: String) -> URL {
            dir.appendingPathComponent(item.base + suffix)
        }
        return [
            (url(".txt"), "Transcript.txt"),
            (url(".translated.txt"), "Transcript (translated).txt"),
            (url(".summary.md"), "Summary.md"),
            (url(".summary.translated.md"), "Summary (translated).md"),
        ]
    }

    /// 把勾选的条目**原样复制**到一个临时目录，然后交给系统分享面板。
    ///
    /// 为什么不做 zip：`UIActivityViewController` 拿目录一样能"存储到文件"和
    /// AirDrop，省掉一次把几十 GB 再写一遍的复制 —— 导出 20 条会议录音时
    /// 那一下要几十秒，而且期间设备空间会翻倍占用。
    private func runBatchExport() async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        busyMessage = L10n.Library.exportPreparing
        defer { busyMessage = nil }
        // ★ 2026-10-15 六改：导出（大文件时的复制 / 重编码）整段占住后台保活。
        // 用户原话是"导出音频对于大文件音频需要等待很久这个需要挂在后台"。
        // 与转录、摘要共用同一套机制，不另起一份。
        BackgroundKeeper.shared.acquire(.export)
        defer { BackgroundKeeper.shared.release(.export) }

        let fm = FileManager.default
        // ⚠️ 暂存目录**不再写 `tmp`**。`tmp` 会被 iOS 随时清掉，而"导完切走、
        //    回来再分享"恰恰是本轮要支持的路径 —— 存在 App 容器里，并把
        //    "备好了哪一份"落盘（`ExportCenter`）。开新的会顺手删掉上一份。
        let root: URL
        do {
            root = try ExportCenter.shared.beginNewStaging()
        } catch {
            exportError = error.localizedDescription
            return
        }

        var failures: [String] = []
        var staged = 0
        var bytes: Int64 = 0
        var taken = Set<String>()
        do {
            for item in items {
                let dir = root.appendingPathComponent(
                    Self.exportFolderName(for: item, taken: &taken), isDirectory: true
                )
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)

                // 音频保留**原始文件名**（扩展名 .opus / .m4a / .mp3 是播放器
                // 认它的唯一依据，改不得）。
                if let url = item.url, fm.fileExists(atPath: url.path) {
                    do {
                        let dest = dir.appendingPathComponent(item.name)
                        try fm.copyItem(at: url, to: dest)
                        bytes += Self.fileSize(dest)
                        staged += 1
                    } catch {
                        failures.append("\(item.displayTitle): \(error.localizedDescription)")
                    }
                }
                for artefact in Self.textArtefacts(for: item)
                where fm.fileExists(atPath: artefact.source.path) {
                    do {
                        let dest = dir.appendingPathComponent(artefact.name)
                        try fm.copyItem(at: artefact.source, to: dest)
                        bytes += Self.fileSize(dest)
                        staged += 1
                    } catch {
                        failures.append("\(item.displayTitle): \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            exportError = error.localizedDescription
            return
        }

        // 有真的 I/O 报错就如实说，不弹分享面板：让用户对着一个缺了内容的
        // 目录去"存储到文件"，比直接告诉他哪几条没导出更糟。
        // （没音频的纯文本条目**不算失败** —— 它本来就没有音频可导。）
        if !failures.isEmpty {
            exportError = failures.joined(separator: "\n")
            return
        }
        guard staged > 0 else {
            exportError = L10n.Library.exportEmpty
            return
        }
        ExportCenter.shared.publish(
            id: root.lastPathComponent,
            title: L10n.Library.exportReadyTitle(items.count),
            itemCount: items.count,
            bytes: bytes,
            origin: nil
        )
        exportURL = root
        showExportSheet = true
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    // MARK: - 批量删除

    /// 整条删掉：音频 + 转录 + 摘要 + 译文 + 自定义标题，外加在 `Library` 里
    /// 注销掉这条记录。
    ///
    /// ★ 2026-10-15：文件**不再真删**，而是整组搬进回收站（`ClipTrash`），
    /// 保护 30 天。所以这一趟只负责"把该带走的东西列全"，搬家和记账都在
    /// `ClipTrash.move` 里做 —— 那里也是"先搬文件、再注销 manifest"的顺序，
    /// 理由同下。
    ///
    /// ⚠️ **顺序不能反** —— 必须"先删文件、再清 manifest"。反过来的话
    /// `LibraryScanner` 会在"manifest 已清、文件还在"的那个窗口里把这条按
    /// **导入文件**重新建出来（manifest 里没记录 = 用户自己导的），
    /// 用户看到的就是"删了没删掉"。
    private func runBatchDelete() async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        busyMessage = L10n.Library.deleting
        defer { busyMessage = nil }

        let payloads = items.map { item in
            ClipTrash.Payload(
                localName: item.name,
                title: item.displayTitle,
                urls: Self.deleteURLs(for: item),
                // 整条都走，所以"已从设备下过"的凭据必须一起注销 —— 漏了它，
                // 同一条录音再也下载不回来（设备列表里它永远是"已下载"）。
                download: ClipTrash.downloadRecord(forLocalName: item.name, in: library),
                // ★ 2026-10-15：来源在**删除这一刻**定死。`move` 会顺手注销
                // manifest 里那条记录，之后就再也查不出这条录音是从哪来的了。
                source: ClipTrash.sourceLabel(forLocalName: item.name, in: library)
            )
        }
        let moved = ClipTrash.shared.move(payloads, library: library)
        // 清理这个动作**自己报不报错**由这里判定：搬成功的组一定能移走全部
        // 文件，搬失败的组已经被 `move` 原样退回。所以看"哪个还剩文件"最准。
        let stuck = moved < payloads.count
            ? payloads.filter { $0.urls.contains { FileManager.default.fileExists(atPath: $0.path) } }
            : []
        let failures = stuck.map(\.title)

        // 已读账本里也要清 —— 不清的话表会随着"删了又下"无限长，而且同名
        // 文件重新下载回来会莫名带着"已读"，用户再也等不到那颗红点。
        readStore.forget(names: items.map(\.name))
        exitSelection()
        await model.refresh(force: true)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        if !failures.isEmpty {
            deleteError = failures.joined(separator: "\n")
        }
    }

    /// 整条删除要搬走的全部文件。
    ///
    /// 从 `LibraryItem` 反推路径而不是走通用目录扫描：`item` 已经带着
    /// `url` / `base`，拼后缀是 O(1)；扫一遍目录要几百个 syscall，而这是
    /// 可以在主线程上被点出来的动作。
    ///
    /// 含 `.asr.json` / `.translated.json` 这两个**旁车 JSON** —— 老的
    /// `textArtefacts(for:)` 只管四份给人看的文本，把它们落下了；而
    /// `ClipArtefact.of(fileNamed:)` 是把 `.asr.json` 当 `.transcript` 认的，
    /// 于是残留一个 JSON 足以让扫描器重建出"有转录、点开却读不出东西"的条目。
    private static func deleteURLs(for item: LibraryItem) -> [URL] {
        let t = StorageLocations.transcriptURLs(for: item.name)
        let tr = StorageLocations.translationURLs(for: item.name)
        var urls: [URL] = []
        if let url = item.url { urls.append(url) }
        urls.append(contentsOf: [
            t.txt, t.json, tr.txt, tr.json,
            StorageLocations.summaryURL(for: item.name),
            StorageLocations.summaryTranslatedURL(for: item.name),
            StorageLocations.titleURL(for: item.name),
        ])
        return urls
    }

    private func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: - 归类的三个模型

/// 时间桶。**`rank` 就是展示顺序**：今天 → 昨天 → 本周 → 本月 → 各月从新到旧。
///
/// 为什么分两个排序键而不是揉成一个整数：月份之间的先后要按年月比，而它跟
/// 前四档之间只差"谁在上面"。分开写，排序就是一句元组比较，读的人也一眼
/// 看得出月份是"垫在最后面、内部倒序"。
private enum LibraryTimeBucket: Hashable {
    case today
    case yesterday
    case thisWeek
    case thisMonth
    /// 更早的，按月。值是 `yyyyMM` —— 能排序，能当 id，也直接是"年 / 月"。
    case month(Int)

    var rank: Int {
        switch self {
        case .today: return 0
        case .yesterday: return 1
        case .thisWeek: return 2
        case .thisMonth: return 3
        case .month: return 4
        }
    }

    /// 同档内再排：月份越新越靠上（所以取负）。
    var tiebreak: Int {
        if case let .month(key) = self { return -key }
        return 0
    }

    var id: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "week"
        case .thisMonth: return "month"
        case let .month(key): return "m\(key)"
        }
    }
}

/// 列表里的一行：条目 + 它在**整库**（`model.items`）里的下标。
///
/// 下标是给 `adjacentOlder(at:)` 用的 —— 它按整库的时间序找相邻的上一条。
/// 拿筛过之后的下标去查会指到别人身上，右滑合并就合出两条毫不相干的录音。
///
/// `unread` 在**归类那一趟**就算好：一次 `isUnread` 是一次账本查询，
/// 1900 行每次重绘都各查一遍没必要，而且分节头还要数"这节几条未读"。
private struct LibraryEntry: Identifiable {
    let item: LibraryItem
    let modelIndex: Int
    let unread: Bool
    var id: String { item.id }
}

/// 一个（时间 × 设备）分节。
private struct LibrarySection: Identifiable {
    let id: String
    /// 同一个时间桶的第一个分节 —— 桶标题只在它头上写一次，同桶后面几台
    /// 设备不再重复写"今天"。
    let showsBucketTitle: Bool
    let bucketTitle: String
    let deviceName: String
    /// **整桶**的合计（不是本分节的）：否则"今天"下面三台设备各写一遍数字，
    /// 反而看不出今天一共多少。
    let bucketCount: Int
    let bucketBytes: Int64
    let unreadCount: Int
    let entries: [LibraryEntry]
}

private struct LibraryRow: View {
    let item: LibraryItem
    let source: Library.ClipSource
    /// 知识库检索命中的那一段正文（`nil` = 没在搜，或这条正文没命中）。
    ///
    /// 由调用方从 `snippets` 里取好传进来，行本身不碰检索 —— 列表要滚动，
    /// 一行不该有"自己去查一下"的成本。
    var snippet: String? = nil
    /// 还没打开过 —— 标题前面挂一颗红点。
    var isUnread: Bool = false

    /// 自定义过标题的那几条，日期补在来源徽标后面。
    ///
    /// ★ 2026-10-16 十三改：原来是**硬编码**的 `"MM-dd HH:mm"`。
    /// 硬编码的模板在别的语言里就是错的（德语要"17.04."、日语要"4月17日"），
    /// 而且它是全 App 最后一处"日期不跟 App 语言"的地方。
    /// 换成系统模板 `yMMMd jm` —— `j` 是"locale 偏好的小时制"，
    /// 于是英/阿走 12 小时、中日德走 24 小时，不用自己判。
    private static var shortDate: DateFormatter {
        AppLocale.formatter("library.row_date") { $0.setLocalizedDateFormatFromTemplate("yMMMd jm") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isUnread {
                    // 红点放在标题**前面**而不是右端：右端已经被转录/摘要徽标
                    // 和各种状态占了，"有没有新的"要在扫列表的第一眼就看见。
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(L10n.Library.unread)
                }
                Text(item.displayTitle)
                    .font(.body)
                    .lineLimit(2)
                Spacer()
                if !item.hasAudio {
                    Image(systemName: "waveform.slash")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                }
                if item.hasTranscript {
                    Image(systemName: "text.bubble.fill")
                        .foregroundColor(.green)
                        .imageScale(.small)
                        .accessibilityLabel(L10n.Library.hasTranscript)
                }
                if item.hasSummary {
                    Image(systemName: "doc.plaintext.fill")
                        .foregroundColor(.orange)
                        .imageScale(.small)
                        .accessibilityLabel(L10n.Library.hasSummary)
                }
            }
            if let snippet {
                // 命中片段。压平过换行（见 `LibraryKnowledgeIndex.snippet`），
                // 这里再 `lineLimit(2)` 兜一层 —— 转录里偶尔有整段没标点的话。
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                // ★ 2026-10-15: the source badge goes **first**. In a pile of recordings with nearly identical
                //   filenames, "who recorded this" is the first criterion for picking one, more useful than the byte count.
                SourceBadge(source: source)
                if item.hasCustomTitle {
                    Text(Self.shortDate.string(from: item.recordedAt))
                }
                if item.hasAudio {
                    Text(formatBytes(item.size))
                }
                if let dur = item.durationLabel {
                    Text("\u{00B7}")
                    Text(dur)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

/// "Who recorded this": a symbol + one line of small text.
///
/// Of the form `TicNote-3N9H`, `My Meeting Card-3N9H`, `Apple Watch`, `This Device`, `Imported`.
private struct SourceBadge: View {
    let source: Library.ClipSource

    var body: some View {
        let text = source.displayName
        HStack(spacing: 3) {
            Image(systemName: Self.symbol(for: source.kind))
                .imageScale(.small)
            Text(text)
        }
        .accessibilityLabel(L10n.Library.sourceAccessibility(text))
    }

    private static func symbol(for kind: Library.ClipSource.Kind) -> String {
        switch kind {
        case .card: return "creditcard"
        case .watch: return "applewatch"
        case .phone: return "iphone"
        case .imported: return "square.and.arrow.down"
        }
    }
}

extension Library.ClipSource {
    /// 这台设备的展示名。列表行那枚徽标和分节头用的是**同一份** ——
    /// 两处各写一遍的话，改了别名的规则就会出现"行里叫新名字、
    /// 分组标题还是旧名字"。
    ///
    /// The card naming order is deliberately **user alias → name recorded at persistence → fallback word**,
    /// with the **last 4 digits of the SN** uniformly appended: two cards of the same model both labeled "Recorder Card" are indistinguishable,
    /// while the SN's last 4 digits happen to match the Wi-Fi hotspot naming convention (`TicNote-3N9H`),
    /// so users can match them up directly (see `protocol-notes.md` §18.1).
    ///
    /// 别名是**显示时**查、不是落库时固化 —— 所以用户之后给卡改名，
    /// 老记录上的标识和分组标题都跟着变，不会留下一堆旧名字。
    var displayName: String {
        switch kind {
        case .watch:
            return L10n.Library.sourceWatch
        case .phone:
            return L10n.Library.sourcePhone
        case .imported:
            return L10n.Library.sourceImported
        case .card:
            let alias = serial.flatMap {
                RecorderAliasStore.shared.alias(identityHex: $0)
            }
            let unit = alias ?? storedName ?? L10n.Library.sourceCard
            guard let suffix = Self.serialSuffix(serial) else { return unit }
            return "\(unit)-\(suffix)"
        }
    }

    /// Last 4 digits of the SN. Returns nil when the SN is too short — better to display only the name
    /// than to splice together something half-done like `-09H`.
    private static func serialSuffix(_ serial: String?) -> String? {
        guard let serial else { return nil }
        let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4 else { return nil }
        return String(trimmed.suffix(4))
    }
}

// MARK: - Model

struct LibraryItem: Identifiable, Equatable {
    let name: String
    /// `nil` when the audio file has been cleared but text artifacts
    /// (transcript / summary) still exist on disk.
    let url: URL?
    let size: Int64
    let modifiedAt: Date
    let duration: Double?
    let hasTranscript: Bool
    /// ★ 2026-10-15：已生成摘要（`{base}.summary.md` 存在）。
    ///
    /// 与 `hasTranscript` 一样由扫描器在**已有的目录列举**里直接判定，
    /// 零额外 syscall。知识库检索靠它和 `hasTranscript` 决定"这条有没有正文"，
    /// 列表里也据此挂徽标。
    let hasSummary: Bool
    /// 有译文：整篇转录的翻译，或摘要的翻译。
    let hasTranslation: Bool
    let customTitle: String?

    var id: String { name }

    /// 文件名去掉扩展名。**所有旁车文件**（转录 / 摘要 / 翻译 / 标题）
    /// 都以它为前缀 —— 检索索引拿它拼路径，不要各自再 `deletingPathExtension`
    /// 一遍（`LibraryScanner` 给纯文本条目合成的 `.opus` 名字也靠这条对齐）。
    var base: String { (name as NSString).deletingPathExtension }

    /// 这条有没有**可检索的正文** —— 也就是"算不算知识库里的一条"。
    var hasText: Bool { hasTranscript || hasSummary }

    var hasAudio: Bool { url != nil }
    var displayTitle: String {
        if let customTitle { return customTitle }
        // Text-only entries carry a synthetic ".opus" name — LibraryListModel
        // appends it so the StorageLocations helpers' deletingPathExtension
        // still yields the right base even for dotted names. Never surface
        // that fabricated extension: an imported "meeting.mp3" whose audio was
        // cleared must not come back reading as "meeting.opus" (omkn6rf).
        // Timestamped device names still render as a date, so only the
        // unparseable (imported) case needs the raw base.
        if url == nil, RecordingName.date(from: name) == nil {
            return (name as NSString).deletingPathExtension
        }
        return RecordingName.displayTitle(for: name)
    }
    var hasCustomTitle: Bool { customTitle != nil }

    /// 这个条目是否**按名字**命中关键词（落盘名 / 显示标题）。
    ///
    /// 只服务于「全部」作用域：还没转录的录音正文是空的，只有名字能搜。
    /// 匹配对大小写与变音符不敏感 —— 与 `LibraryKnowledgeIndex` 保持同一套
    /// 判据，不然同一个词在两种作用域下会得到不一样的结果。
    func matchesName(_ needle: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if name.range(of: needle, options: options) != nil { return true }
        return displayTitle.range(of: needle, options: options) != nil
    }

    /// 单条现查盘：把磁盘上一个**已存在的音频文件**读成一条 `LibraryItem`。
    ///
    /// 全库那条路径走 `LibraryScanner`（拿一次目录列举批量判定，见
    /// `textFlags`）；这里是"刚录完""刚点过来"的单条路径，手上只有文件名，
    /// 只能逐个 `fileExists`。**判定逻辑必须只有这一份** —— 这两条路（还有
    /// 实时页那个入口）以前各写了一遍，加 `hasSummary` 时就是三处一起漏。
    ///
    /// `duration` 由调用方给：两处算时长的路子本来就不同（实时页只看 Opus，
    /// 录音页对非 Opus 还要异步问 `AVURLAsset`），硬并到一起只会多一层分支。
    static func readFromDisk(name: String, duration: Double?) -> LibraryItem? {
        let dir = StorageLocations.decryptedDir
        let url = dir.appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let base = (name as NSString).deletingPathExtension
        func artefact(_ suffix: String) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent(base + suffix).path)
        }
        let titleURL = StorageLocations.titleURL(for: name)
        let title = (try? String(contentsOf: titleURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return LibraryItem(
            name: name,
            url: url,
            size: Int64(attrs?.fileSize ?? 0),
            modifiedAt: attrs?.contentModificationDate ?? Date(),
            duration: duration,
            hasTranscript: artefact(".txt"),
            hasSummary: artefact(".summary.md"),
            hasTranslation: artefact(".translated.txt") || artefact(".summary.translated.md"),
            customTitle: (title?.isEmpty ?? true) ? nil : title
        )
    }
    /// The recording's real timestamp: parsed from the device filename
    /// (device RTC at record time) when present, else the file mtime for
    /// imported clips that carry no timestamped name. Display should use
    /// this, not `modifiedAt` (which is the download-to-phone time) — the
    /// filename is the authoritative recording time (l7jwpnd).
    var recordedAt: Date { RecordingName.date(from: name) ?? modifiedAt }

    var durationLabel: String? {
        guard let duration else { return nil }
        return ClockLabel.mmss(duration)
    }
}

/// The sole formatting point for duration: shared by list cards, detail page header, and the right side of the player progress bar.
/// Always round to the nearest second—letting each place truncate individually would cause a 5.6 s audio to show as 0:05 in one place and 0:06 in another,
// and the merged file would almost never be an exact number of seconds, leading to collisions.
enum ClockLabel {
    static func mmss(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded()))
        if t >= 3600 {
            return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
        }
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

@MainActor
final class LibraryListModel: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []

    /// Summed once per scan instead of on every body evaluation — with ~1900
    /// items the old computed property re-reduced the whole array each time
    /// SwiftUI asked for it. Now feeds the "all devices" row of the filter
    /// menu (the old bottom-of-list footer was removed in favour of
    /// per-section totals).
    private(set) var totalBytes: Int64 = 0

    /// Coalesces overlapping refreshes. `.task` on appear and the pop-back
    /// re-appear can both fire within a frame of each other; without this the
    /// second one starts a whole duplicate scan.
    private var inFlight: Task<Void, Never>?

    /// Signature of the last completed scan (directory mtime + entry count).
    /// Popping back from Clip Detail is by far the most common refresh and
    /// almost never changes the directory, so it can return immediately.
    ///
    /// ★ 2026-10-15：对外只读开放。知识库检索拿它当**缓存失效键** ——
    /// 目录里任何一个文件被写（重新转录、生成摘要）它都会变，于是正文缓存
    /// 整块作废。比逐文件比对 mtime 便宜，而且不会漏判。
    private(set) var signature: LibraryScanner.Signature?

    private let scanner = LibraryScanner()

    func refresh(force: Bool = false) async {
        inFlight?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let previous = force ? nil : self.signature
            let scanner = self.scanner
            // The whole scan is filesystem work: 1900 files means thousands of
            // stat calls plus a duration probe each. Running it on the main
            // actor is what froze the list for seconds on every appear.
            // ⚠️ Detached tasks **do not inherit cancellation**: a simple `guard !Task.isCancelled` here is insufficient —
            // If the outer task is cancelled (e.g., switching tabs or triggering a refresh), this scan will still stat and probe the duration of thousands of files.
            // Repeatedly entering and leaving the library causes multiple full scans to run concurrently,
            // which amplifies the “a few seconds of lag when there are many files” issue.
            // Use `withTaskCancellationHandler` to manually forward cancellation (as in `LocalVAD.analyze`).
            let scanTask = Task.detached(priority: .userInitiated) {
                await scanner.scan(skippingIfUnchangedFrom: previous)
            }
            let outcome = await withTaskCancellationHandler {
                await scanTask.value
            } onCancel: {
                scanTask.cancel()
            }
            guard !Task.isCancelled else { return }
            switch outcome {
            case .unchanged:
                break
            case let .scanned(items, signature, totalBytes):
                self.items = items
                self.totalBytes = totalBytes
                self.signature = signature
            }
        }
        inFlight = task
        await task.value
    }
}

/// Filesystem side of the Library list. Lives off the main actor and owns the
/// duration cache, which is the expensive part: `OpusOgg.duration` page-walks
/// the file and `AVURLAsset.load(.duration)` opens a demuxer, so recomputing
/// either for every clip on every appear does not scale — QA measured a 14 s
/// cold start and multi-second stalls at ~1900 clips / 25 GB.
actor LibraryScanner {

    /// Fingerprint of the directory listing. Deliberately **not** the
    /// directory's own mtime: that misses an in-place overwrite, and renaming
    /// a clip rewrites an existing `.title` without touching the directory —
    /// the rename would then not show up until something else changed.
    /// The newest entry mtime catches those; the count catches add/remove.
    /// Both come from the batch the enumerator already prefetched.
    struct Signature: Equatable {
        let newestEntry: Date
        let entryCount: Int
    }

    enum Outcome {
        case unchanged
        case scanned(items: [LibraryItem], signature: Signature, totalBytes: Int64)
    }

    /// name → duration, valid only while the file's size and mtime match.
    /// Persisted so a cold start doesn't have to re-probe the whole library.
    private struct DurationEntry: Codable {
        let size: Int64
        let modified: Date
        let duration: Double?
    }
    private var durations: [String: DurationEntry] = [:]
    private var durationsLoaded = false

    private var cacheURL: URL {
        StorageLocations.audioDir.appendingPathComponent(".durations.json", isDirectory: false)
    }

    func scan(skippingIfUnchangedFrom previous: Signature?) async -> Outcome {
        let dir = StorageLocations.decryptedDir
        let fm = FileManager.default

        guard let allEntries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .scanned(items: [], signature: Signature(newestEntry: .distantPast, entryCount: 0), totalBytes: 0)
        }

        var newest = Date.distantPast
        for url in allEntries {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            if m > newest { newest = m }
        }
        let signature = Signature(newestEntry: newest, entryCount: allEntries.count)
        if let previous, previous == signature { return .unchanged }

        loadDurationCacheIfNeeded()

        // Every artefact lives in this same directory, so membership questions
        // ("does this clip have a transcript?") are answered from the listing
        // we already have rather than a `fileExists` syscall per clip.
        let presentNames = Set(allEntries.map(\.lastPathComponent))

        let audioExts = AudioImporter.acceptedExtensions
        let audioFiles = allEntries.filter { audioExts.contains($0.pathExtension.lowercased()) }
        var audioBases = Set<String>()
        audioBases.reserveCapacity(audioFiles.count)
        for url in audioFiles {
            audioBases.insert((url.lastPathComponent as NSString).deletingPathExtension)
        }

        // Artifact files whose audio is gone (text survived a "Clear Media"
        // wipe). Longer suffixes first so "foo.asr.json" matches ".asr.json"
        // before ".json".
        let artifactSuffixes = [".asr.json", ".translated.txt", ".translated.json",
                                ".summary.translated.md", ".summary.md", ".title", ".txt"]
        var orphanMtimes: [String: Date] = [:]
        for url in allEntries where !audioExts.contains(url.pathExtension.lowercased()) {
            let fname = url.lastPathComponent
            guard let suffix = artifactSuffixes.first(where: { fname.hasSuffix($0) }) else { continue }
            let base = String(fname.dropLast(suffix.count))
            guard !audioBases.contains(base) else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            orphanMtimes[base] = max(orphanMtimes[base] ?? Date.distantPast, mtime)
        }

        var built: [LibraryItem] = []
        built.reserveCapacity(audioFiles.count + orphanMtimes.count)
        var totalBytes: Int64 = 0
        var cacheDirty = false

        for url in audioFiles {
            // The forwarded cancellation must take effect **here**, otherwise the upper layer just forwards it uselessly:
            // Scanning 1,900 files, each potentially requiring a page‑wise Ogg duration probe, is the most expensive part of the whole scan.
            if Task.isCancelled { return .unchanged }
            let name = url.lastPathComponent
            let base = (name as NSString).deletingPathExtension
            let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(attrs?.fileSize ?? 0)
            let mtime = attrs?.contentModificationDate ?? Date.distantPast
            totalBytes += size

            let duration: Double?
            if let cached = durations[name], cached.size == size, cached.modified == mtime {
                duration = cached.duration
            } else {
                duration = await Self.probeDuration(url)
                durations[name] = DurationEntry(size: size, modified: mtime, duration: duration)
                cacheDirty = true
            }

            let text = Self.textFlags(base: base, presentNames: presentNames)
            built.append(LibraryItem(
                name: name,
                url: url,
                size: size,
                modifiedAt: mtime,
                duration: duration,
                hasTranscript: text.transcript,
                hasSummary: text.summary,
                hasTranslation: text.translation,
                customTitle: Self.readTitle(base: base, presentNames: presentNames)
            ))
        }

        for (base, mtime) in orphanMtimes {
            // Synthetic ".opus" so deletingPathExtension in the StorageLocations
            // helpers still yields `base` for these text-only entries.
            let text = Self.textFlags(base: base, presentNames: presentNames)
            built.append(LibraryItem(
                name: "\(base).opus",
                url: nil,
                size: 0,
                modifiedAt: mtime,
                duration: nil,
                hasTranscript: text.transcript,
                hasSummary: text.summary,
                hasTranslation: text.translation,
                customTitle: Self.readTitle(base: base, presentNames: presentNames)
            ))
        }

        // Drop cache rows for clips that no longer exist, so the file doesn't
        // grow forever across deletes.
        let liveNames = Set(audioFiles.map(\.lastPathComponent))
        if durations.keys.contains(where: { !liveNames.contains($0) }) {
            durations = durations.filter { liveNames.contains($0.key) }
            cacheDirty = true
        }
        if cacheDirty { saveDurationCache() }

        let sorted = built.sorted { lhs, rhs in
            let l = RecordingName.date(from: lhs.name) ?? lhs.modifiedAt
            let r = RecordingName.date(from: rhs.name) ?? rhs.modifiedAt
            return l > r
        }
        return .scanned(items: sorted, signature: signature, totalBytes: totalBytes)
    }

    /// 一条 clip 的文本状态：转录 / 摘要 / 译文。
    ///
    /// 三条全部**在已经列举出来的目录名里查** —— 扫描器手上就有
    /// `presentNames`，再各来一次 `fileExists` 就是 1900 条 × 3 次白跑。
    private static func textFlags(
        base: String, presentNames: Set<String>
    ) -> (transcript: Bool, summary: Bool, translation: Bool) {
        (
            transcript: presentNames.contains("\(base).txt"),
            summary: presentNames.contains("\(base).summary.md"),
            translation: presentNames.contains("\(base).translated.txt")
                || presentNames.contains("\(base).summary.translated.md")
        )
    }

    /// Only opens the `.title` file when the listing says there is one —
    /// otherwise this was a failed `Data(contentsOf:)` per clip.
    private static func readTitle(base: String, presentNames: Set<String>) -> String? {
        guard presentNames.contains("\(base).title") else { return nil }
        let url = StorageLocations.decryptedDir.appendingPathComponent("\(base).title")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func probeDuration(_ url: URL) async -> Double? {
        if url.pathExtension.lowercased() == "opus" {
            return OpusOgg.duration(ofOggOpusAt: url)
        }
        let seconds = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
        return (seconds.isFinite && seconds > 0) ? seconds : nil
    }

    private func loadDurationCacheIfNeeded() {
        guard !durationsLoaded else { return }
        durationsLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: DurationEntry].self, from: data)
        else { return }
        durations = decoded
    }

    private func saveDurationCache() {
        guard let data = try? JSONEncoder().encode(durations) else { return }
        try? FileManager.default.createDirectory(
            at: StorageLocations.audioDir, withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
    }
}
