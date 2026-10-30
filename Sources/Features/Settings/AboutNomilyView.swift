import SwiftUI
import UIKit

/// ★ 2026-10-30（用户："设置下面最顶部加入一个，关于 Nomily" + "顶部一个关于，
/// 下面一个关于是否是重复了，优化一下下面那个"）：
///
/// 唯一的关于页（Plaud 式排版）：图标 + 名字 + 版本号 → 诊断导出 → 官方社交媒体 →
/// 法规。设置页底部原来的「关于」区（版本行 / 诊断 / 社交图标）已整体搬进这里，
/// 主设置页不再重复出现第二个"关于"。
///
/// 「连点版本号 7 次开开发者模式」的彩蛋一并搬来——点的是头部版本号那行。
///
/// ⚠️ 所有链接集中在文件底部的 `Links` 枚举里——换地址只改那一处。
struct AboutNomilyView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var configService: ConfigService

    // MARK: - 开发者模式彩蛋（自 SettingsView 搬入，行为不变）

    @State private var versionTapCount = 0
    @State private var versionTapResetTask: Task<Void, Never>?
    @State private var devModeToast: String?
    private static let tapsToToggle = 7
    private static let tapsBeforeHint = 3

    /// 导出的诊断报告文件（生成后出 ShareLink）。
    @State private var diagReportURL: URL?

    var body: some View {
        Form {
            // 头部：图标 + 名字 + 版本。整块可点 = 版本彩蛋的宿主。
            Section {
                VStack(spacing: 10) {
                    appIcon
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    Text("Nomily")
                        .font(.title2.weight(.semibold))
                    Text(Self.versionText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
                .onTapGesture { handleVersionTap() }
                .listRowBackground(Color.clear)

                // 彩蛋提示 / 开发者模式状态行（原设置页底部的那条）。
                if let devModeToast {
                    Text(devModeToast)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                } else if configService.config.isDeveloperMode {
                    HStack(spacing: 6) {
                        Image(systemName: "hammer.fill")
                        Text(L10n.DeveloperMode.statusOn)
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            // ★ 2026-10-30：诊断导出从设置页底部搬来——"关于"是它最自然的家。
            Section {
                Button {
                    diagReportURL = DiagnosticsExporter.export()
                } label: {
                    Label(L10n.Diagnostics.export, systemImage: "stethoscope")
                }
                if let diagReportURL {
                    ShareLink(item: diagReportURL) {
                        Label(L10n.Diagnostics.share, systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text(L10n.Diagnostics.footer)
            }

            Section {
                linkRow(.x, L10n.About.xRow, url: Links.x)
                linkRow(.xiaohongshu, L10n.About.xiaohongshuRow, url: Links.xiaohongshu)
                linkRow(.discord, L10n.About.discordRow, url: Links.discord)
                linkRow(.github, L10n.About.githubRow, url: Links.github)
                linkRow(.email, L10n.About.emailRow, url: Links.email)
            } header: {
                Text(L10n.About.socialHeader)
            }

            Section {
                linkRow(nil, L10n.About.terms, url: Links.terms)
                linkRow(nil, L10n.About.privacy, url: Links.privacy)
            } header: {
                Text(L10n.About.legalHeader)
            }
        }
        .navigationTitle(L10n.About.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Pieces

    /// 单行外链。`brand == nil`（协议/隐私这类没有品牌图标的）就不画瓦片。
    private func linkRow(_ brand: SocialMark.Brand?, _ label: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack(spacing: 12) {
                if let brand {
                    SocialMark(brand: brand, size: 28)
                }
                Text(label)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    /// 应用图标：用资产目录里的 NomiLogo（与 AppIcon 同一张 nomi-logo.png；
    /// appiconset 的名字 iOS 不一定暴露成 UIImage，所以单独放了一个 imageset）。
    /// 取不到再画"N"字瓦片兜底。
    @ViewBuilder
    private var appIcon: some View {
        if let ui = UIImage(named: "NomiLogo") {
            Image(uiImage: ui)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.appAccent.gradient)
                .overlay {
                    Text("N")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
        }
    }

    /// `v<short>(<build>)`，和 Plaud 的 `v3.29.3(741)` 同构。
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "v\(short)(\(build))"
    }

    /// Classic "tap the version seven times" easter egg. Taps reset
    /// after 2 s of inactivity so stray touches don't accumulate.
    /// When dev mode is already on, the same gesture turns it off so
    /// it's symmetric — no second hidden path needed.
    private func handleVersionTap() {
        versionTapCount += 1
        versionTapResetTask?.cancel()

        if versionTapCount >= Self.tapsToToggle {
            versionTapCount = 0
            configService.config.isDeveloperMode.toggle()
            configService.scheduleSave()
            let isOn = configService.config.isDeveloperMode
            withAnimation {
                devModeToast = isOn ? L10n.DeveloperMode.toastEnabled : L10n.DeveloperMode.toastDisabled
            }
            scheduleToastClear(after: 2)
            return
        }

        let remaining = Self.tapsToToggle - versionTapCount
        if versionTapCount >= Self.tapsBeforeHint {
            withAnimation {
                devModeToast = configService.config.isDeveloperMode
                    ? L10n.DeveloperMode.tapsToDisable(remaining)
                    : L10n.DeveloperMode.tapsToEnable(remaining)
            }
        }

        versionTapResetTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                versionTapCount = 0
                withAnimation { devModeToast = nil }
            }
        }
    }

    private func scheduleToastClear(after seconds: Double) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            await MainActor.run {
                withAnimation { devModeToast = nil }
            }
        }
    }

    /// ★ 全部外链地址集中在这里——换账号/换网址只改这一处。
    /// ⚠️ GitHub 与用户协议/隐私政策是**占位地址**，等 angel 给正式链接后替换。
    enum Links {
        static let x = URL(string: "https://x.com/nomilyai")!
        static let xiaohongshu = URL(string: "https://xhslink.cn/o/Apxk5lURufK")!
        static let discord = URL(string: "https://discord.gg/uQFj3Rfv54")!
        static let github = URL(string: "https://github.com/nomily-ai")!
        static let email = URL(string: "mailto:nomily@geekis.com")!
        static let terms = URL(string: "https://www.geekis.com/nomily/terms")!
        static let privacy = URL(string: "https://www.geekis.com/nomily/privacy")!
    }
}
