import SwiftUI

/// ★ 2026-10-30（用户："录音文件大小在本地占用多少，nas 占用多少，iCloud 占用多少
/// 大小需要显示出来"）
///
/// 三处占用一页看完：本地（实测 `audio_clips/`）、WebDAV NAS（PROPFIND 实测服务器
/// 字节数）、iCloud/文件夹（书签进目录实测）。进页面自动刷，下拉也能刷。
///
/// ★★ 2026-10-30 二稿（用户："储存占用直接按照块状显示，设备与资料库，显示统计
/// 那个设备记录时长还有手表的，按照储存统计方式，不要单纯的文字显示，多一点图表
/// 动效"）：整页从「三行文字」改成**块状卡片 + 图表**：
///   ① 顶部总览块：总占用大字 + 三段堆叠条（本机 / NAS / iCloud 各占多少，条长
///      随数据 animated 长出来）；
///   ② 「设备与资料库」块阵：来源（录音豆按设备别名分区 / Apple Watch / 导入）
///      各一张卡，卡里是字节数 + **录音时长** + 条数 + 占比细条；
///   ③ 「存储位置」块阵：三个位置各一张卡，带占比条；
///   ④ 底部脚注保留"实测口径"的说明——数字要能被解释，不能只是好看。
struct StorageUsageView: View {
    @EnvironmentObject private var configService: ConfigService
    @ObservedObject private var usage = StorageUsageService.shared

    /// 首次出现/刷新后置 true，图表从 0 长到目标长度。
    @State private var appeared = false

    /// 三个位置里最大的那个——堆叠条按它归一化，读起来像"占了多少"。
    private var locations: [(key: String, title: String, icon: String, color: Color,
                             usage: StorageUsageService.Usage, configured: Bool, footer: String)] {
        [
            ("local", L10n.StorageUsage.local, "iphone", Color.appAccent,
             usage.local, true, L10n.StorageUsage.localFooter),
            ("webdav", L10n.StorageUsage.webdav, "externaldrive.badge.cloud", Color.blue,
             usage.webdav, usage.webdavConfigured, L10n.StorageUsage.webdavFooter),
            ("folder", L10n.StorageUsage.folder, "folder", Color.green,
             usage.folder, usage.folderConfigured, L10n.StorageUsage.folderFooter),
        ]
    }

    private var totalBytes: Int64 {
        locations.reduce(0) { $0 + ($1.configured && $1.usage.failure == nil ? $1.usage.bytes : 0) }
    }

    /// 来源卡片的占比基准：本机音频字节（不含转写文本等附属文件）。
    private var localAudioBytes: Int64 {
        max(1, usage.sources.reduce(0) { $0 + $1.bytes })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                overviewCard
                sourcesSection
                locationsSection
                footnote
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(L10n.StorageUsage.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: - 总览

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.sizeText(totalBytes))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if usage.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            Text(L10n.StorageUsage.totalLabel)
                .font(.footnote)
                .foregroundStyle(.secondary)

            // 堆叠条：三个位置按字节比例分段，带最小可见宽度（0 字节也留一点）。
            GeometryReader { geo in
                let usable = max(1, totalBytes)
                HStack(spacing: 3) {
                    ForEach(locations, id: \.key) { item in
                        let bytes = item.configured && item.usage.failure == nil ? item.usage.bytes : 0
                        let ratio = Double(bytes) / Double(usable)
                        Capsule()
                            .fill(item.color.opacity(bytes > 0 ? 1 : 0.18))
                            .frame(width: max(6, (geo.size.width - 6) * (appeared ? ratio : 0)))
                    }
                }
                .frame(width: geo.size.width, alignment: .leading)
            }
            .frame(height: 12)
            .animation(.spring(response: 0.6, dampingFraction: 0.85), value: appeared)

            // 图例
            HStack(spacing: 14) {
                ForEach(locations, id: \.key) { item in
                    HStack(spacing: 5) {
                        Circle().fill(item.color).frame(width: 7, height: 7)
                        Text(item.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(card)
    }

    // MARK: - 设备与资料库

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.StorageUsage.sourcesHeader)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            if usage.sources.isEmpty {
                Text(usage.isLoading ? L10n.StorageUsage.refreshing : L10n.StorageUsage.emptySources)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(card)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(usage.sources) { source in
                        sourceCard(source)
                    }
                }
            }
        }
    }

    private func sourceCard(_ source: StorageUsageService.SourceStats) -> some View {
        let share = Double(source.bytes) / Double(localAudioBytes)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon(for: source.kind))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint(for: source.kind))
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(tint(for: source.kind).opacity(0.14))
                    )
                Spacer(minLength: 0)
                Text(percentText(share))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(source.label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            Text(Self.sizeText(source.bytes))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.system(size: 9))
                Text(Self.durationText(source.seconds))
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(L10n.StorageUsage.fileCount(source.files))
                .font(.caption2)
                .foregroundStyle(.secondary)

            // 占比细条（相对最占地方的来源），动画从 0 长出来。
            GeometryReader { geo in
                Capsule()
                    .fill(tint(for: source.kind).opacity(0.85))
                    .frame(width: max(4, geo.size.width * (appeared ? share : 0)), height: 4)
            }
            .frame(height: 4)
            .animation(.spring(response: 0.55, dampingFraction: 0.85), value: appeared)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    // MARK: - 存储位置

    private var locationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.StorageUsage.locationsHeader)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            ForEach(locations, id: \.key) { item in
                locationCard(item)
            }
        }
    }

    private func locationCard(
        _ item: (key: String, title: String, icon: String, color: Color,
                 usage: StorageUsageService.Usage, configured: Bool, footer: String)
    ) -> some View {
        let ok = item.configured && item.usage.failure == nil
        let share = totalBytes > 0 ? Double(item.usage.bytes) / Double(max(1, totalBytes)) : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(item.color)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(item.color.opacity(0.14))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                    Text(item.footer)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    if !item.configured {
                        Text(L10n.StorageUsage.notConfigured)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else if let failure = item.usage.failure {
                        Text(L10n.StorageUsage.unavailable(failure))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.trailing)
                    } else {
                        Text(Self.sizeText(item.usage.bytes))
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(L10n.StorageUsage.fileCount(item.usage.files))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if ok {
                GeometryReader { geo in
                    Capsule()
                        .fill(item.color.opacity(0.85))
                        .frame(width: max(4, geo.size.width * (appeared ? share : 0)), height: 4)
                }
                .frame(height: 4)
                .animation(.spring(response: 0.55, dampingFraction: 0.85), value: appeared)
            }
        }
        .padding(13)
        .background(card)
    }

    private var footnote: some View {
        Text(L10n.StorageUsage.footnote)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - 外观

    /// 一块卡片的底：分组背景 + 大圆角 + 极轻的投影（深色模式下投影几乎不可见，不影响观感）。
    private var card: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private func icon(for kind: StorageUsageService.SourceStats.Kind) -> String {
        switch kind {
        case .device: return "dot.radiowaves.left.and.right"
        case .watch: return "applewatch"
        case .imported: return "square.and.arrow.down"
        }
    }

    private func tint(for kind: StorageUsageService.SourceStats.Kind) -> Color {
        switch kind {
        case .device: return Color.appAccent
        case .watch: return .purple
        case .imported: return .teal
        }
    }

    private func percentText(_ ratio: Double) -> String {
        guard ratio > 0 else { return "0%" }
        let pct = ratio * 100
        return pct >= 10 ? String(format: "%.0f%%", pct) : String(format: "%.1f%%", pct)
    }

    // MARK: - 数据

    private func load() async {
        appeared = false
        await usage.refresh(config: configService.config)
        withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { appeared = true }
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 时长：≥1 小时写"x 小时 y 分"，否则写分/秒；0 说明缓存里还没有这条的时长。
    static func durationText(_ seconds: Double) -> String {
        guard seconds >= 1 else { return L10n.StorageUsage.durationUnknown }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return L10n.StorageUsage.durationHM(hours, minutes) }
        if minutes > 0 { return L10n.StorageUsage.durationM(minutes) }
        return L10n.StorageUsage.durationS(total)
    }
}
