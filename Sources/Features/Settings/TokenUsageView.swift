import SwiftUI

/// ★ 2026-10-28（饭耳逆向规格 §1.2「每日 token 用量热力图」）：
/// GitHub 贡献图式的用量日历——颜色深浅 = 当天大模型消耗，点格子看当天明细。
///
/// 数据来自 `TokenUsageStore`（字符 × 0.62 的**估算** token，用于看趋势；
/// footer 把这条口径如实写给用户，不假装是账单）。
///
/// ★ 2026-10-29（用户："AI 用量统计放到大语言模型服务里面去不要单独做一个"）：
/// 内容拆成 `TokenUsageContent`（可嵌进任意 Form Section / VStack），
/// 独立整页视图保留但不再挂载——热力图现在住在大模型页顶部。
struct TokenUsageView: View {
    var body: some View {
        ScrollView {
            TokenUsageContent()
                .padding(16)
        }
        .navigationTitle(L10n.TokenUsage.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The heatmap itself, embeddable. All state is local.
struct TokenUsageContent: View {
    @ObservedObject private var store = TokenUsageStore.shared
    @State private var selected: (date: Date, tokens: Int, calls: Int)?

    /// 26 周 ≈ 半年，和 GitHub 默认视图一致；格子 12pt + 3pt 间距，正好横滚一屏。
    private static let weeks = 26
    private static let cell: CGFloat = 12
    private static let gap: CGFloat = 3

    private var days: [(date: Date, tokens: Int, calls: Int)] {
        store.recent(days: Self.weeks * 7)
    }

    private var maxTokens: Int { days.map(\.tokens).max() ?? 0 }

    private var todayTotal: Int { days.last?.tokens ?? 0 }
    private var monthTotal: Int {
        let calendar = Calendar.current
        let now = Date()
        return days.filter {
            calendar.isDate($0.date, equalTo: now, toGranularity: .month)
        }.map(\.tokens).reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryCard
            heatmap
            legend
            if let selected {
                detailCard(selected)
            }
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 20) {
            stat(L10n.TokenUsage.today, value: Self.format(todayTotal))
            stat(L10n.TokenUsage.thisMonth, value: Self.format(monthTotal))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }

    private var heatmap: some View {
        // 按周分列：先按「周一..周日」补齐，再切成列。
        let calendar = Calendar.current
        let chunks = stride(from: 0, to: days.count, by: 7).map { Array(days[$0..<min($0 + 7, days.count)]) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(Array(chunks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: Self.gap) {
                        ForEach(week, id: \.date) { day in
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(color(for: day.tokens))
                                .frame(width: Self.cell, height: Self.cell)
                                .overlay {
                                    if let selected,
                                       calendar.isDate(selected.date, inSameDayAs: day.date) {
                                        RoundedRectangle(cornerRadius: 2.5)
                                            .strokeBorder(Color.primary, lineWidth: 1.5)
                                    }
                                }
                                .onTapGesture { selected = day }
                        }
                        // 最后一周可能不满 7 天，补齐占位保持列对齐。
                        if week.count < 7 {
                            ForEach(0..<(7 - week.count), id: \.self) { _ in
                                Color.clear.frame(width: Self.cell, height: Self.cell)
                            }
                        }
                    }
                }
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L10n.TokenUsage.less).font(.caption2).foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: level == 0 ? 0 : maxTokens * level / 4))
                        .frame(width: 10, height: 10)
                }
                Text(L10n.TokenUsage.more).font(.caption2).foregroundStyle(.secondary)
            }
            Text(L10n.TokenUsage.footer)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func detailCard(_ day: (date: Date, tokens: Int, calls: Int)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.dayFormatter.string(from: day.date))
                .font(.subheadline.weight(.semibold))
            if day.tokens == 0 {
                Text(L10n.TokenUsage.noUse).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.TokenUsage.detail(Self.format(day.tokens), day.calls))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func color(for tokens: Int) -> Color {
        guard maxTokens > 0, tokens > 0 else { return Color(.tertiarySystemFill) }
        let ratio = Double(tokens) / Double(maxTokens)
        // 四档：<25% / <50% / <75% / 其余。
        let opacity = ratio < 0.25 ? 0.25 : ratio < 0.5 ? 0.45 : ratio < 0.75 ? 0.7 : 1.0
        return Color.appAccent.opacity(opacity)
    }

    private static func format(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
        return "\(tokens)"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()
}
