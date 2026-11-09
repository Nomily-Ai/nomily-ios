import SwiftUI
import UIKit

// MARK: - 待办看板（★ 2026-11-06 · 饭耳 1.0 移植 P0-1）
//
// 用户原话（引用逆向报告）：「卡片攒了很久，现在处理一下」。
//
// 这一页回答两个问题：
//  ① **我欠了什么** —— 清单视图，按"等你决定 / 要做 / 稍后 / 已结束"分层；
//  ② **什么时候欠的** —— 日程视图，按月列出哪一天有截止，点一天看当天的事。
//
// 与摘要详情页的关系：详情页是"这一条录音的待办"，这里是"我全部的账"。
// 两边共用同一份事实——卡片状态变更会写回 `todo.checked.<录音>`，
// 详情页的勾选框跟着变；反过来详情页勾了，看板在采集/刷新时同步过来
//（`TodoBoard.syncFromLegacyChecks`）。
//
// 设计上刻意不抄竞品的"卡片栈瀑布流"：那套视觉在手机小屏上每屏只放得下
// 一张卡，清十张要点十次滑动；这里清单 + 滑动手势，扫一眼就能批量处理。

struct TodoBoardView: View {

    @ObservedObject private var board = TodoBoard.shared

    private enum Mode: String, CaseIterable, Identifiable {
        case list, schedule
        var id: String { rawValue }
        var title: String {
            switch self {
            case .list: return L10n.Todo.segmentList
            case .schedule: return L10n.Todo.segmentSchedule
            }
        }
    }

    @State private var mode: Mode = .list
    @State private var showClearing = false
    @State private var editing: TodoCard?
    @State private var showClosed = false
    /// 日程视图当前显示的月份（该月 1 号）。
    @State private var anchorMonth = Date()
    @State private var selectedDay: Date?

    var body: some View {
        List {
            headerSection
            if mode == .list {
                listSections
            } else {
                scheduleSections
            }
            Section {
                Text(L10n.Todo.reminderFooter)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.Todo.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshFromLegacy() }
        .sheet(isPresented: $showClearing) {
            TodoClearingSheet()
        }
        .sheet(item: $editing) { card in
            TodoCardActionsSheet(card: card)
        }
    }

    /// 进页面时把详情页勾过的行同步进来——用户从摘要页勾了"做完"，
    /// 到这里不该还挂在"要做"里。
    private func refreshFromLegacy() {
        let names = Set(board.cards.map(\.recordingName))
        for name in names { board.syncFromLegacyChecks(recordingName: name) }
    }

    // MARK: - 顶部

    @ViewBuilder
    private var headerSection: some View {
        Section {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 10) {
                Image(systemName: board.inboxCount > 0 ? "tray.full" : "checkmark.seal")
                    .foregroundStyle(board.inboxCount > 0 ? Color.orange : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    if board.inboxCount > 0 {
                        Text("\(board.inboxCount) · \(L10n.Todo.sectionInbox)")
                            .font(.callout)
                    } else {
                        Text(L10n.Todo.doneToday(board.doneTodayCount))
                            .font(.callout)
                    }
                    if board.overdueCount > 0 {
                        Text(L10n.Todo.overdue(board.overdueCount))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
            }

            if board.inboxCount > 0 {
                Button {
                    showClearing = true
                } label: {
                    Label(L10n.Todo.decideTitle, systemImage: "rectangle.stack.badge.minus")
                        .font(.callout)
                }
            }
        }
    }

    // MARK: - 清单视图

    @ViewBuilder
    private var listSections: some View {
        if board.cards.isEmpty {
            Section {
                emptyState(L10n.Todo.emptyBoard, icon: "checklist")
            }
        } else {
            if !board.inbox.isEmpty {
                Section {
                    ForEach(board.inbox) { card in row(card) }
                } header: {
                    Text(L10n.Todo.sectionInbox)
                }
            }
            if !board.active.isEmpty {
                Section {
                    ForEach(board.active) { card in row(card) }
                } header: {
                    Text(L10n.Todo.sectionActive)
                }
            }
            if !board.later.isEmpty {
                Section {
                    ForEach(board.later) { card in row(card) }
                } header: {
                    Text(L10n.Todo.sectionLater)
                }
            }
            if !board.closed.isEmpty {
                Section {
                    if showClosed {
                        ForEach(board.closed) { card in row(card) }
                    }
                } header: {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { showClosed.toggle() }
                    } label: {
                        HStack {
                            Text(L10n.Todo.sectionClosed)
                            Text("\(board.closed.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Spacer()
                            Image(systemName: showClosed ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                }
            }
        }
    }

    // MARK: - 行

    @ViewBuilder
    private func row(_ card: TodoCard) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                toggleDone(card)
            } label: {
                Image(systemName: card.status.symbol)
                    .font(.system(size: 19))
                    .foregroundStyle(card.status == .done ? Color.green
                                     : (card.status == .pending ? Color.orange : Color.secondary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(card.status.title)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.callout)
                    .strikethrough(card.status == .done, color: .secondary)
                    .foregroundStyle(card.status.isClosed ? .secondary : .primary)
                    .lineLimit(3)

                metaLine(card)
            }

            Spacer(minLength: 4)

            if let item = LibraryItem.readFromDisk(name: card.recordingName, duration: nil) {
                NavigationLink {
                    ClipDetailView(item: item)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Todo.openSource)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { editing = card }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !card.status.isClosed {
                Button {
                    board.setStatus(card.id, .done)
                } label: {
                    Label(L10n.Todo.swipeDone, systemImage: "checkmark")
                }
                .tint(.green)
            }
            Button(role: .destructive) {
                board.remove(card.id)
            } label: {
                Label(L10n.Todo.swipeDelete, systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if card.status == .pending {
                Button {
                    board.setStatus(card.id, .wont)
                } label: {
                    Label(L10n.Todo.swipeWont, systemImage: "slash.circle")
                }
                .tint(.gray)
            }
            if !card.status.isClosed {
                Button {
                    board.snooze(card.id)
                } label: {
                    Label(L10n.Todo.swipeLater, systemImage: "clock")
                }
                .tint(.orange)
            }
        }
    }

    @ViewBuilder
    private func metaLine(_ card: TodoCard) -> some View {
        HStack(spacing: 5) {
            if let owner = card.owner, !owner.isEmpty {
                Text("@\(owner)")
                    .foregroundStyle(.secondary)
            }
            if let due = card.due, !due.isEmpty {
                Text(due)
                    .foregroundStyle(isOverdue(card) ? Color.orange : Color.secondary)
            }
            if card.status == .deferred, let remindAt = card.remindAt {
                Text(shortDate(remindAt))
                    .foregroundStyle(.orange)
            }
            if card.status != .done {
                Label(sourceTitle(card), systemImage: "waveform")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text(sourceTitle(card))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .font(.caption2)
    }

    private func sourceTitle(_ card: TodoCard) -> String {
        card.recordingTitle ?? RecordingName.displayTitle(for: card.recordingName)
    }

    private func isOverdue(_ card: TodoCard) -> Bool {
        guard !card.status.isClosed, let due = card.dueDate() else { return false }
        return Calendar.current.startOfDay(for: due) < Calendar.current.startOfDay(for: Date())
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func toggleDone(_ card: TodoCard) {
        if card.status == .done {
            board.setStatus(card.id, .accepted)
        } else {
            board.setStatus(card.id, .done)
        }
    }

    private func emptyState(_ text: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    // MARK: - 日程视图

    @ViewBuilder
    private var scheduleSections: some View {
        Section {
            monthHeader
            weekdayHeader
            monthGrid
        } header: {
            Text(monthTitle(anchorMonth))
                .textCase(nil)
                .font(.headline)
        }

        Section {
            let day = selectedDay ?? Date()
            let cards = cards(on: day)
            if cards.isEmpty {
                emptyState(L10n.Todo.emptyDay, icon: "calendar")
            } else {
                ForEach(cards) { card in row(card) }
            }
        } header: {
            Text(dayTitle(selectedDay ?? Date()))
        }
    }

    private var monthHeader: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
            Spacer()
            Button {
                anchorMonth = Date()
                selectedDay = Date()
            } label: {
                Text(monthTitle(Date()))
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Spacer()
            Button {
                shiftMonth(1)
            } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
        }
        .font(.callout)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
            ForEach(Array(gridDays().enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 34)
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let calendar = Calendar.current
        let isToday = calendar.isDateInToday(day)
        let isSelected = selectedDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let count = cards(on: day).filter { !$0.status.isClosed }.count
        Button {
            selectedDay = day
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white : (isToday ? Color.accentColor : .primary))
                    .frame(width: 26, height: 26)
                    .background(
                        Circle().fill(isSelected ? Color.accentColor : Color.clear)
                    )
                Circle()
                    .fill(count > 0 ? Color.accentColor : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(height: 34)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: 日历计算

    private var weekdaySymbols: [String] {
        var calendar = Calendar.current
        calendar.locale = .current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        // 按当前地区的"一周第一天"旋转（中国是周一，美国是周日）。
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// 当前月的格子：前面补 nil 让 1 号落在正确的星期列。
    private func gridDays() -> [Date?] {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: anchorMonth),
              let firstDay = calendar.date(from: calendar.dateComponents([.year, .month], from: anchorMonth))
        else { return [] }
        let weekday = calendar.component(.weekday, from: firstDay)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        var days: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<range.count {
            days.append(calendar.date(byAdding: .day, value: offset, to: firstDay))
        }
        return days
    }

    private func cards(on day: Date) -> [TodoCard] {
        let calendar = Calendar.current
        return board.cards
            .filter { card in
                guard let due = card.dueDate() else { return false }
                return calendar.isDate(due, inSameDayAs: day)
            }
            .sorted { !$0.status.isClosed && $1.status.isClosed }
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: delta, to: anchorMonth) else { return }
        anchorMonth = next
    }

    private func monthTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMMM")
        return formatter.string(from: date)
    }

    private func dayTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return formatter.string(from: date)
    }
}

// MARK: - 单卡操作

/// 点一行 → 这张卡的全部去向。滑动手势是"快速通道"，这里给"想清楚再选"的人。
struct TodoCardActionsSheet: View {
    let card: TodoCard
    @ObservedObject private var board = TodoBoard.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(card.title)
                        .font(.headline)
                    HStack(spacing: 8) {
                        if let owner = card.owner, !owner.isEmpty { Text("@\(owner)") }
                        if let due = card.due, !due.isEmpty { Text(due) }
                        Text(card.recordingTitle ?? RecordingName.displayTitle(for: card.recordingName))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    actionRow(L10n.Todo.decideDone, symbol: "checkmark.circle", tint: .green) {
                        board.setStatus(card.id, .done)
                    }
                    actionRow(L10n.Todo.decideAccept, symbol: "circle", tint: .blue) {
                        board.setStatus(card.id, .accepted)
                    }
                    actionRow(L10n.Todo.decideLater, symbol: "clock", tint: .orange) {
                        board.snooze(card.id)
                    }
                    actionRow(L10n.Todo.decideWont, symbol: "slash.circle", tint: .gray) {
                        board.setStatus(card.id, .wont)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        board.remove(card.id)
                        dismiss()
                    } label: {
                        Label(L10n.Todo.swipeDelete, systemImage: "trash")
                    }
                }
            }
            .navigationTitle(L10n.Todo.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.ok) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func actionRow(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
        }
    }
}

// MARK: - 清算弹层

/// 「卡片攒了很久，现在处理一下」——一次只面对一张卡，滑一下就过去。
///
/// 为什么不做批量多选：待办的难点从来不是"操作效率"，是**面对**——多选让人
/// 一次看见十条欠账，滑卡让人一次只欠一条。饭耳的顺序就是这个：右滑 = 放下，
/// 左滑 = 拿起来。
struct TodoClearingSheet: View {
    @ObservedObject private var board = TodoBoard.shared
    @Environment(\.dismiss) private var dismiss

    /// 开场固定这一批：处理过程中新抓进来的不插队（否则永远清不完）。
    @State private var queue: [TodoCard] = []
    @State private var offset: CGFloat = 0
    @State private var started = false

    private var current: TodoCard? { queue.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let card = current {
                    progressLine(total: queue.count)
                    cardView(card)
                        .offset(x: offset)
                        .rotationEffect(.degrees(Double(offset / 24)))
                        .gesture(dragGesture(card))
                        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: offset)
                    quickActions(card)
                } else {
                    finished
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle(L10n.Todo.decideTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Todo.decideSkip) { dismiss() }
                }
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            queue = board.inbox
        }
        .presentationDetents([.large])
    }

    // MARK: 组成

    private func progressLine(total: Int) -> some View {
        let done = max(0, total - queue.count)
        return HStack(spacing: 8) {
            Text(L10n.Todo.decideProgress(done, total))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            ProgressView(value: Double(done), total: Double(max(total, 1)))
        }
    }

    private func cardView(_ card: TodoCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(card.status.title)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
                Spacer()
                if let due = card.due, !due.isEmpty {
                    Text(due).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(card.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let owner = card.owner, !owner.isEmpty {
                Text("@\(owner)").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                Text(card.recordingTitle ?? RecordingName.displayTitle(for: card.recordingName))
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(alignment: .leading) {
            // 右滑 = 放下（绿），左滑 = 拿起来（橙）——颜色就是决定本身。
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(offset >= 0 ? Color.green.opacity(min(abs(offset) / 260, 0.28))
                                  : Color.orange.opacity(min(abs(offset) / 260, 0.28)))
        }
    }

    private func quickActions(_ card: TodoCard) -> some View {
        VStack(spacing: 10) {
            Text(L10n.Todo.decideHint)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                smallButton(L10n.Todo.decideWont, tint: .gray) {
                    decide(card, .wont)
                }
                smallButton(L10n.Todo.decideLater, tint: .orange) {
                    decide(card, .deferred)
                }
            }
        }
    }

    private func smallButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.14)))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    private var finished: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(L10n.Todo.decideFinished)
                .font(.headline)
            Button(L10n.Common.ok) { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 40)
    }

    // MARK: 手势

    private func dragGesture(_ card: TodoCard) -> some Gesture {
        DragGesture()
            .onChanged { value in offset = value.translation.width }
            .onEnded { value in
                if value.translation.width > 90 {
                    decide(card, .done)
                } else if value.translation.width < -90 {
                    decide(card, .accepted)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { offset = 0 }
                }
            }
    }

    private func decide(_ card: TodoCard, _ status: TodoStatus) {
        board.setStatus(card.id, status)
        withAnimation(.easeOut(duration: 0.2)) {
            offset = status == .done ? 420 : -420
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            queue.removeAll { $0.id == card.id }
            offset = 0
        }
    }
}
