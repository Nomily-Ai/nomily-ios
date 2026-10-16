import SwiftUI

// MARK: - 菜单通向的独立页面
//
// ★ 2026-10-16 七改：下面这些页面**没变**，变的是它们怎么被进去 ——
// 原来从首页四角的角标点进去，现在从首页往左/往右滑出来的菜单点进去
// （见 `WatchHomeMenu` / `WatchMenuPreferences`）。页面本身一行没动。
//
// ★ 2026-10-15 二改：这四页原来是"在主页上就地展开一小条菜单"，用户明确
// 否掉了 —— "4 个菜单点击应该是出独立一页"。改成分页之后：
//
//   · 主页腾干净了，只剩"时间 + 圆环 + 4 个角标"，跟健康 App 的活动圆环页
//     同一个结构（用户的原话就是"直接按照苹果健康的布局去"）；
//   · 原来单独占一个角标的**渐变**并进了颜色页 —— 渐变本来就是"颜色怎么用"，
//     不该跟颜色平起平坐占一个位置；
//   · 原来挂在主页底部的**语言**文字链接搬进来，占了空出来的那个角标；
//   · **版本 + 恢复默认**合成"设置"页 —— 这两项都是偶尔才碰的低频操作。
//
// ★ 2026-10-15 五改：呼吸灯也并进了左上那一页（它和颜色/渐变同属"环长什么样"），
// 右上角让给了**传输记录**（`WatchTransferHistoryView`）——
// 那是状态，不是外观，本来也不该跟调色挤在一起。
//
// 语言页复用 `WatchLanguageView`（那边还兼着 `LocalizedWatchRoot` 的重建），
// 不在这里重复一份。

// MARK: - 外观（颜色 + 呼吸灯）

/// 外观页：颜色 + 呼吸灯速率。
///
/// ★ 2026-10-16 十二改：色板**补了白色**（用户："当前颜色里面呢没有白色吗手表"）。
/// 这一页因此长出一件别处没有的麻烦事 —— 一块"自己就是白"的色块需要一个不靠
/// 白色也看得见的选中框，一颗"底色是白"的胶囊需要不靠白色也看得见的字。
/// 两处都改成了跟着色板反色（`WatchRingPalette.selectionRing` / `.onSolid`）。
/// ⚠️ 色板那一格是 5 列，11 个颜色 ⇒ 第三行只剩白色一个。**故意不为了凑整**
///    去动列数：4 列会让每颗色块间距变大、整页变长，而多出来的空白只是丑一点。
///
/// ★ 2026-10-16 九改：**渐变没了**（用户："取消渐变"），所以这一页少了一行。
/// 剩下的"颜色"现在管的地方比原来明确得多 —— 它就是**首页那只眼睛的颜色**
/// （连带录音时那条音波、两侧菜单的图标、录音计时那行字）。用户原话：
/// "那个手表里的设置颜色则是眼睛 bot 的颜色"。
///
/// ★ 2026-10-15 五改：呼吸灯**并进来了**（用户："把右上角呼吸灯速率放到
/// 左上角的菜单里面"）。三样都属于"环长什么样"，分成两个角标只会让用户在
/// 两页之间来回跳着调 —— 而且呼吸灯只有四档，单独占一个角标太奢侈，
/// 右上那一格腾给真正需要独立一页的**传输记录**更值。
///
/// 顶部一个小圆环预览。**刻意不用 `WatchRingControl`** —— 那个是按钮，
/// 带彗星、波纹、计时，点一下还会开始录音；这里只要"看一眼配色对不对"。
struct WatchColorStyleView: View {
    @ObservedObject private var store = WatchRingStyleStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                WatchRingPreview(style: store.style)
                    .frame(width: 68, height: 68)
                    .accessibilityHidden(true)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5),
                    spacing: 8
                ) {
                    ForEach(WatchRingPalette.allCases) { palette in
                        Button {
                            store.style.palette = palette
                        } label: {
                            // ★ 九改：色块改成**纯色**圆点（原来是上下两色的线性渐变）。
                            // 一是"渐变"这个维度已经被取消了（见 `WatchRingStyle`），
                            // 二是这个色块现在要回答的问题变简单了 ——
                            // "选它的话，首页那只眼睛是什么颜色"，一个颜色就说明白。
                            //
                            // ⚠️ 十二改：描边颜色不能写死白了。这套色板里现在有
                            //    `white`，白描边画在白块的内侧等于没画 ——
                            //    用户点进去会以为"白色这个选项坏了、点了没反应"。
                            //    取 `palette.selectionRing`（= 该色块自己的反色）。
                            Circle()
                                .fill(palette.solid)
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle().strokeBorder(
                                        palette.selectionRing,
                                        lineWidth: store.style.palette == palette ? 2 : 0
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(palette.rawValue)
                    }
                }

                // ★ 九改：「渐变」那一行（纯色 / 渐变 两枚胶囊）整个删掉了 ——
                // 用户："取消渐变"。原先那行占的位置现在让给呼吸灯，配色也更干净：
                // 一页里只剩"选哪个颜色"和"呼吸灯多快"两件事。

                // ★ 呼吸灯速率。**必须有那行小标题**：`关/慢/中/快` 四个字
                // 自己说明不了它管的是什么（渐变那行的"纯色/渐变"能自证，
                // 这行不能）。小标题只在中文里占两个字，比让用户猜划算得多。
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.Watch.styleBreathing)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    pillRow(WatchBreathing.allCases.map { option in
                        (label: option.label,
                         selected: store.style.breathing == option,
                         action: { store.style.breathing = option })
                    })
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(L10n.Watch.styleAppearance)
    }

    /// 一行等宽胶囊选择器。
    ///
    /// ★ 九改之后它只剩**呼吸灯**这一个调用方（渐变的调用方被删了）。
    /// 之所以没有顺手内联掉：这行胶囊的形状（等宽、圆角、选中时填主题色）
    /// 是这个页面上"选择器"这个概念的唯一样板，留着当一个有名字的构件，
    /// 比揉进 `body` 里更好认。
    private func pillRow(
        _ options: [(label: String, selected: Bool, action: () -> Void)]
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(action: option.action) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        // ★ 十二改：选中那颗胶囊的底就是这个色板的 `solid`，
                        // 文字颜色必须跟着它反色 —— 否则选到 `white` 时会变成
                        // 白底白字（在这之前默认色恰好是白，一直没暴露这个问题）。
                        .foregroundStyle(
                            option.selected
                                ? store.style.palette.onSolid
                                : Color.white
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule().fill(
                                option.selected
                                    ? store.style.palette.solid.opacity(0.9)
                                    : Color.white.opacity(0.12)
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 传输记录

/// 传输记录页（原右上角"呼吸灯"的位置）。
///
/// ★ 2026-10-15 五改新增（用户："右上角就是手表的传输记录"）。
///
/// 一屏能装下的信息只有"这条是谁、传成没传成、什么时候"，所以只放三行：
/// 标题 / 状态 + 大小 / 时间。失败原因折进状态行 —— 那是用户点进这一页
/// **唯一真正想知道**的东西（"为什么没传上去"）。
struct WatchTransferHistoryView: View {
    @ObservedObject private var log = WatchTransferLog.shared

    var body: some View {
        Group {
            if log.records.isEmpty {
                // 空态。这一页最常被打开的时刻恰恰是"刚装完/刚重启"，
                // 什么都不显示会让人以为这个功能坏了。
                VStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text(L10n.Watch.transferEmpty)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                List {
                    ForEach(log.records) { record in
                        row(record)
                    }
                }
            }
        }
        .navigationTitle(L10n.Watch.transferHistory)
        .toolbar {
            if !log.records.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        log.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(L10n.Watch.transferClear)
                }
            }
        }
    }

    private func row(_ record: WatchTransferRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.displayTitle)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)

            HStack(spacing: 4) {
                Image(systemName: symbol(record.state))
                    .font(.system(size: 10, weight: .bold))
                Text(label(record.state))
                    .font(.system(size: 11, weight: .semibold))
                if record.bytes > 0 {
                    Text(WatchFormat.bytes(record.bytes))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(tint(record.state))

            if let detail = record.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Text(Self.stamp.string(from: record.updatedAt))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func label(_ state: WatchTransferRecord.State) -> String {
        switch state {
        case .queued:    return L10n.Watch.transferQueued
        case .delivered: return L10n.Watch.transferDelivered
        case .stored:    return L10n.Watch.transferStored
        case .failed:    return L10n.Watch.transferFailed
        }
    }

    private func symbol(_ state: WatchTransferRecord.State) -> String {
        switch state {
        case .queued:    return "clock"
        case .delivered: return "paperplane"
        case .stored:    return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ state: WatchTransferRecord.State) -> Color {
        switch state {
        case .queued:    return .secondary
        case .delivered: return .orange
        case .stored:    return .green
        case .failed:    return .red
        }
    }

    /// 时间是**绝对**的。用相对时间（"5 分钟前"）在这页没有意义 ——
    /// 用户来这儿问的是"我早上那条什么时候传的"。
    ///
    /// ★ 2026-10-16 十三改：locale 从 `AppLocale` 取。手表上也能选语言
    /// （`WatchLanguageStore`），这一页的时间以前跟着**手表系统语言**走，
    /// 于是"表上选英文"之后菜单全英文、这一页的时间还是中文。
    private static var stamp: DateFormatter {
        AppLocale.formatter("watch.transfer_stamp") { f in
            f.dateStyle = .short
            f.timeStyle = .short
        }
    }
}

// MARK: - 设置

/// 设置页：版本 + 摇一摇开关 + 恢复默认外观。
///
/// 版本号仍然兼着"我刚编的那个包到底到表上了没有"—— 手表的更新由 iPhone
/// 择机推送，比 iPhone 换包晚好几分钟（见 `WatchAboutView` 顶部那段）。
struct WatchSettingsView: View {
    @ObservedObject private var store = WatchRingStyleStore.shared
    @ObservedObject private var prefs = WatchRecordingPrefs.shared

    var body: some View {
        List {
            HStack {
                Text(L10n.Settings.version)
                Spacer(minLength: 4)
                Text(WatchAboutView.appVersion)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // ★ 摇一摇。开关拨动会通过 `WatchRecordingPrefs` 通知首页
            // 开始/停止采集（首页把它挂成 `@ObservedObject`）——
            // 不用在这里碰任何 CoreMotion 的东西。
            Toggle(isOn: $prefs.shakeToRecord) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Watch.shakeToRecord)
                    Text(L10n.Watch.shakeToRecordHint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            // ★ 六改：双指互点（食指拇指捏合）。
            //
            // ⚠️ **只在 watchOS 11+ 显示**。10.1~10.x 上系统自己就把双指互点
            //   派给页面的主按钮，没有 API 能拦 —— 在那种表上摆一个"关不掉
            //   手势"的开关比不摆更糟（用户拨了、没生效、就会以为整个手势
            //   功能坏了）。
            if #available(watchOS 11.0, *) {
                Toggle(isOn: $prefs.pinchToRecord) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.Watch.pinchToRecord)
                        Text(L10n.Watch.pinchToRecordHint)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // ★ 2026-10-16 七改：快捷菜单。
            //
            // 用户原话："需要在手表的快捷录音的手表的菜单栏里面出现可以添加快捷的
            // 菜单设置，这个设置是在手表的 wifi 那个菜单栏里面进行点击添加的组件"。
            // 用户把这一页比作"系统设置里 WiFi 那种列表"—— 那就把"添加快捷菜单"
            // 做成这一页里的一行，点进去勾选。
            //
            // ⚠️ 这一行**不能**只在设置页里有：首页两侧菜单页底部也摆了一个同样的
            //    入口（`WatchRecorderView.editTile`）。用户在首页滑到空页时，
            //    第一反应是"在这儿加"，而不是"先滑回中间、再进设置、再翻到这里"。
            NavigationLink {
                WatchQuickMenuSettingsView()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Watch.quickMenu)
                    Text(L10n.Watch.quickMenuHint)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                store.reset()
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text(L10n.Watch.styleReset)
                }
                .foregroundStyle(store.style.palette.solid)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 只重置外观（颜色 / 渐变 / 呼吸灯），不碰语言、不碰录音 ——
            // 所以不需要二次确认，按错了再挑一次颜色就行。
            // （摇一摇开关因此也刻意不在这个 store 里，见 `WatchRecordingPrefs`。）
        }
        .navigationTitle(L10n.Watch.menuSettings)
    }
}

// MARK: - 快捷菜单（★ 2026-10-16 七改新增）

/// 「首页两侧放哪几个菜单」。
///
/// 用户原话："需要在手表的快捷录音的手表的菜单栏里面出现可以添加快捷的菜单设置，
/// 这个设置是在手表的 wifi 那个菜单栏里面进行点击添加的组件"。
///
/// 一行一个开关，勾上的就出现在首页两侧的滑动菜单里（见 `WatchHomeMenu`、
/// `WatchMenuPreferences`）。
///
/// ## 为什么**不给**排顺序
/// 顺序固定按 `WatchHomeMenu.allCases` 走。让用户拖着排的话，取消勾选再勾回来
/// 就会跑到队尾 —— 菜单项会在左右两页之间乱跳，用户下次找同一个功能得重新找一遍。
/// 表盘上拖拽本身也难点准，为一个"能用"的功能换来"容易排乱"不划算。
struct WatchQuickMenuSettingsView: View {
    @ObservedObject private var prefs = WatchMenuPreferences.shared

    var body: some View {
        List {
            Section {
                ForEach(WatchHomeMenu.allCases) { item in
                    Toggle(isOn: binding(for: item)) {
                        HStack(spacing: 6) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .lineLimit(1)
                                // 小字说明"点进去能看到什么"。表上光一个"外观"
                                // 看不出是调什么的（同一个理由见 `L10n.Watch.styleBreathing`）。
                                Text(item.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            } footer: {
                // 说清"勾了之后它去哪儿了"。用户在这一页勾完，回到首页是要**往
                // 旁边滑**才看得到的 —— 不讲这一句，他会以为勾了没生效。
                Text(L10n.Watch.quickMenuFooter)
                    .font(.system(size: 10))
            }
        }
        .navigationTitle(L10n.Watch.quickMenu)
    }

    private func binding(for item: WatchHomeMenu) -> Binding<Bool> {
        Binding(
            get: { prefs.isOn(item) },
            set: { prefs.set(item, on: $0) }
        )
    }
}

// MARK: - 预览

/// 颜色页顶部的小圆环预览：外环走当前渐变取色，中心走当前填充。
///
/// 与主环共用 `WatchRingStyle.ringAngularGradient` —— 两处各写一遍取色逻辑
/// 迟早会漂（尤其是三色盘和"渐变关掉"那两条分支）。
private struct WatchRingPreview: View {
    let style: WatchRingStyle

    var body: some View {
        ZStack {
            Circle()
                .inset(by: 5)
                .stroke(style.ringAngularGradient,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))

            Circle()
                .inset(by: 17)
                .fill(Color(white: 0.10))

            Circle()
                .inset(by: 17)
                .fill(style.centerFill)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
