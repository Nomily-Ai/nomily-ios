import SwiftUI

/// 手表首页那张脸摆哪个表情（设置 → Apple Watch → 首页表情）。
///
/// ★ 2026-10-16 十三改新增（用户："需要在 Nomily AI APP 里面的设置里面增加一个
///    就是设置手表的首页眼睛的表情，把之前的 github 里面 gork bot 的表情放入到
///    Nomily ai 的设置里面支持放入他们的表情"）。
///
/// ## 一行 = 一个表情，左边就是它**真的**长什么样
/// 每一行左边不是图标、不是文字，而是**直接画出来的一对眼睛** ——
/// 而且用的是和手表上**完全相同**的绘制代码（`BotFacePair`）。
///
/// ⚠️ 这一点是这一页唯一值得较真的地方：表情这个东西**说名字说不清**。
///    "Shy" 和 "Sad" 在中文里都得费一句话解释，而画出来一眼就分得开。
///    更重要的是，如果预览和真机各画一份，用户就会在手机上挑中一个笑眼、
///    抬腕发现是垂眼 —— 所以两边共用一个文件里的同一段代码，不是省事，
///    是**正确性**要求（理由写在 `BotFaceStyle` 顶部）。
///
/// ## 颜色为什么是前景色，不是表上那个颜色
/// 手表的颜色（"外观"那一页）是**手表本地**偏好，手机不知道它选了哪个
/// （那份偏好从来没上过 WatchConnectivity）。所以这里不假装知道 ——
/// 一律用 `.primary` 画。这一页选的是**形状**，颜色不在这儿改。
struct WatchFacePickerView: View {
    @EnvironmentObject private var configService: ConfigService
    @EnvironmentObject private var watch: WatchSyncService

    /// 当前选中的那一档。没存过 = `calm`（和手表侧的默认值必须一致，
    /// 否则手机显示的和表上画的会对不上）。
    private var chosen: BotFaceStyle {
        BotFaceStyle.decode(configService.config.watchFaceStyle) ?? .calm
    }

    var body: some View {
        Form {
            Section {
                ForEach(BotFaceStyle.allCases) { style in
                    row(style)
                }
            } footer: {
                Text(L10n.Face.footer)
            }
        }
        .navigationTitle(L10n.Face.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ style: BotFaceStyle) -> some View {
        Button {
            choose(style)
        } label: {
            HStack(spacing: 12) {
                // 预览。给一个固定宽度，九行的眼睛就都在同一条竖线上 ——
                // 每行自己撑开的话，`scan`（窄）和 `shy`（扁宽）会让文字左右横跳。
                BotFacePair(style: style, size: Self.previewSize, tint: .primary)
                    .frame(width: Self.previewBoxWidth, alignment: .center)

                Text(style.title)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                if style == chosen {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .font(.body.weight(.semibold))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(style == chosen ? [.isSelected] : [])
    }

    /// 预览那张脸的名义边长。
    ///
    /// ⚠️ 这不是表上的尺寸（表上那个是屏宽的 0.76，40mm 上约 119pt）。
    ///    这里取的是"在手机一行里放得下、又看得出形状差别"的那一档：
    ///    40pt 下待机眼睛约 9.4 × 15pt，弧形档的笔宽约 3pt ——
    ///    再小就看不出 `listen` 和 `scan` 的区别了。
    private static let previewSize: CGFloat = 40
    /// 预览那一列的宽度。比最宽的一档（眼睛群约 40pt）再宽一点。
    private static let previewBoxWidth: CGFloat = 52

    private func choose(_ style: BotFaceStyle) {
        guard style != chosen else { return }
        configService.config.watchFaceStyle = style.rawValue
        // 写盘立刻做，不等常规的防抖保存：这是一次点击，不是拖滑块；
        // 而且推给手表这件事**依赖**这份值已经落盘（手表可能几分钟后才醒）。
        configService.saveNow()
        watch.sendFaceStyle(style.rawValue)
    }
}
