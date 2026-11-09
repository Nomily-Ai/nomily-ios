import SwiftUI
import WatchKit

// MARK: - 手表首页的新图形语言（★ 2026-11-02 · 采纳 v3 原型）
//
// 用户给的参考是 `nomily-watch-v3-blink.html`：「手表的整体风格朝着这个看起」。
// 那个原型和本工程以前的首页差在三件事上，全部落在下面这几个小件里：
//
// | 原型 | 以前 | 现在 |
// |---|---|---|
// | 顶栏右上角是**时钟**，页码条挂在时钟正下方 | 只有三根页码条（系统时钟被 `persistentSystemOverlays(.hidden)` 关掉了） | `WatchClockFace` + 页码条竖排 |
// | 录音中左上是**呼吸的暖点 + LISTENING** | 只有"待传"胶囊 | `WatchListeningBadge` |
// | 录音计时是**底部 38pt 细体大数字** | 贴在波形下面的 13pt 小字 | 大数字（尺寸见 `WatchRecorderView.readout`） |
//
// 另外原型多出「最近」「同步」两页，本文件实现它们的数据与视图：
//   · `WatchRecentsPane` —— 数据来自手机推下来的回顾摘要（`WatchRecapStore`），
//     不是另建一份"手表自己记的录音列表"：手表上没有转写、没有标题，
//     凭空编一个列表只会和手机上的库对不上。
//   · `WatchSyncPane` —— 待传条数、连接状态、可用空间，全部是**真实读数**
//     （`model.pending` / `link.phoneReachable` / 卷可用容量）。
//
// ⚠️ 颜色只用一支暖色（`WatchHomeStyle.amber`）。这是原型里唯一的彩色，
//    也是它"黑底 + 一条暖线"的骨架；表盘上多一个颜色，视线就先落到颜色上，而不是录音状态。

enum WatchHomeStyle {
    /// #FFB86B。录音中的 LISTENING 呼吸点、正在同步的进度条、翻页时留在顶部的细线。
    static let amber = Color(red: 1.0, green: 0.722, blue: 0.42)
    /// 列表分隔线（0.5pt，压得很淡——手表上一根实线就够抢眼了）。
    static let hairline = Color.white.opacity(0.10)
    /// 小标题（「最近」「同步到 iPhone」）：字距拉开、亮度压到 .38，读作"标签"而不是"内容"。
    static let header = Color.white.opacity(0.38)
    /// 次要正文（时间、条数、状态值）。
    static let dim = Color.white.opacity(0.45)
}

// MARK: - 顶栏时钟（已移除，2026-11-02）
//
// 这里曾经有一个 `WatchClockFace`：照 v3 原型在右上角画「时间 + 页码条」。
// 真机上它和 **watchOS 系统状态栏的时间**并排出现，屏幕上是两个一模一样的时间
// （`persistentSystemOverlays(.hidden)` 只压掉导航栏那一层，压不住状态栏）。
// 用户："顶部右上角已经有时间了，这个 bot 的右上角就不要出时间"。
//
// ⚠️ 别再把它加回来。页码条现在由 `WatchRecorderView.topBar` 单独摆放，
//    并且向下让开系统时间那一行。

// MARK: - LISTENING 呼吸点

/// 录音中左上角那盏"状态灯"。
///
/// ★ 为什么它是**灯**而不是文字：录音这件事在手表上有三种入口（长按、双指捏合、摇一摇），
///   而一旦开录，用户往往已经把手臂放下去了。一颗会呼吸的暖点是"我看见它了"最省的表达，
///   也不用把"正在录音"翻译成四种语言的句子。
///
/// ⚠️ 呼吸（1.3s 往返）**不是**装饰性的循环：它和波形一样在说"还活着"。所以它必须真的在动——
///    `repeatForever(autoreverses: true)` 在这里是允许的，别照搬文件顶部对"眨眼"的那条禁令
///    （那条禁的是用固定周期假装随机，这里本来就是心跳）。
struct WatchListeningBadge: View {
    /// ★ 2026-11-03（V4 原型）：省电模式下不换颜色、换**材质**——暖点变月牙，
    /// 标签变「MOONLIT」，呼吸放慢到 4.2s。用户要一眼看出"它不是录得更勤了，
    /// 而是在省电"，用同一个暖点只改文字做不到这件事。
    var powerSaver: Bool = false

    @State private var dim = false
    /// 降低动态：不做呼吸，只留一颗静止的暖点。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            if powerSaver {
                // 月牙：一个圆 + 一个同色挖空。用 SF Symbols 而不是自己画，
                // 是为了和系统的月亮图标（低电量、勿扰）保持同一套形状。
                Image(systemName: "moon")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(WatchHomeStyle.amber)
                    .opacity(dim ? 0.34 : 0.95)
                    .scaleEffect(dim ? 0.9 : 1)
            } else {
                Circle()
                    .fill(WatchHomeStyle.amber)
                    .frame(width: 5, height: 5)
                    .opacity(dim ? 0.34 : 0.95)
                    .scaleEffect(dim ? 0.86 : 1)
                    // 一点暖光，让这颗点在纯黑底上"亮着"而不是"贴着"。
                    .shadow(color: WatchHomeStyle.amber.opacity(0.6), radius: 3)
            }
            Text(powerSaver ? L10n.Watch.moonlit : L10n.Watch.listening)
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.55))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: powerSaver ? 4.2 : 1.3).repeatForever(autoreverses: true)) {
                dim = true
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 「最近」页

/// 最近几条**已出摘要**的录音。
///
/// ★ 为什么用回顾摘要而不是"手表自己录的片段"：手表上只有音频文件名、没有标题也没有文字，
///   把 `PendingClip.displayTitle`（"11/02 18:05"这种）排成三行，读起来是一张时间戳清单。
///   手机的摘要推送过来时已经带了标题与要点，那才是"最近发生了什么"。
///   代价是**没摘要就没有条目**——所以空状态必须说清楚"摘要在手机上生成后才会过来"。
struct WatchRecentsPane: View {
    @ObservedObject private var store = WatchRecapStore.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                header

                if store.recaps.isEmpty {
                    emptyState
                } else {
                    // ★★ 2026-11-04（用户："右滑的最近要能看到 30 条摘要，时间最新的排在最上面，
                    //   每条要有一个主题，点主题看这条摘要"）：
                    //   · 条数 6 → **30**（上限在 `WatchRecap.limit`，这里只是"全都显示"）；
                    //   · 顺序由 `WatchRecapStore.prune` 统一按 `recordedAt` 倒序排好，
                    //     这一层不再自己 sort —— 两处各排一次，早晚会排成两种顺序；
                    //   · 每行的主标题换成 `recap.topic`（一行能扫完的主题），
                    //     完整标题留在详情页。
                    ForEach(Array(store.recaps.prefix(WatchRecap.limit))) { recap in
                        NavigationLink {
                            WatchRecapDetailView(recap: recap)
                        } label: {
                            row(recap)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 10)
            // ★ 2026-11-03 二轮（用户："顶部跟底部的显示好像又没用全"）：顶部 30 → **12**。
            //   页码条在底部、右上角只有系统时间一行，30pt 的让位等于把第一行标题摁到半屏以下。
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
    }

    /// 页标题 + 条数。30 条的时候，"还有多少条"本身就是一屏信息，
    /// 没有它用户不知道自己翻到哪儿了（腕上没有滚动条刻度）。
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(L10n.Watch.recent)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(WatchHomeStyle.header)
            Spacer(minLength: 0)
            if !store.recaps.isEmpty {
                Text("\(store.recaps.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(WatchHomeStyle.dim)
            }
        }
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundStyle(WatchHomeStyle.dim)
            Text(L10n.Watch.recentEmpty)
                .font(.system(size: 11.5))
                .foregroundStyle(WatchHomeStyle.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 8)
    }

    private func row(_ recap: WatchRecap) -> some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                // ★★ 2026-11-04：**主题**（`recap.topic`）而不是完整标题。
                //   完整标题常常是一整句（"关于下季度产品路线图的讨论与结论"），
                //   在 126pt 宽的一行里只能显示前半截，30 行看下来全是"关于……"。
                //   主题是手机用 `RecapTopic` 压出来的一行话，详情页里照样有完整标题。
                Text(recap.topic)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                // ★ 2026-11-03（V4 原型）：行内改成「日期 · N 条要点 · 24:06」，
                //   时长是唯一值得暖色的信息——它回答"这条值不值得点开"。
                //   手机没推时长（老版本 / 探不到音频）时**整段省略**，不显示假数据。
                subtitle(recap)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            WatchMiniWaveMark(seed: recap.id)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(WatchHomeStyle.hairline)
                .frame(height: 0.5)
        }
        .contentShape(Rectangle())
    }

    /// 行内那行小字。用 `Text` 拼接而不是 `HStack`：只有「 · 24:06」这一段要暖色，
    /// 分开排会让三段各自按内容宽度对齐，读起来像三个字段而不是一句话。
    private func subtitle(_ recap: WatchRecap) -> Text {
        let head = "\(WatchFormat.dayTime(recap.recordedAt)) · \(L10n.Watch.pointsCount(recap.points.count))"
        var line = Text(head).foregroundColor(WatchHomeStyle.header)
        if let duration = recap.duration, duration > 0 {
            line = line + Text(" · \(WatchFormat.compactDuration(duration))")
                .foregroundColor(WatchHomeStyle.amber)
        }
        return line.font(.system(size: 10))
    }
}

/// 列表右侧那根小波形（原型里的 `mini`）。
///
/// ⚠️ **它是装饰，不是读数**：手表上并没有"这条录音的电平曲线"这种东西，
///    凭空画一根波形很容易被读成"这条很吵/很长"。所以：
///   · 线宽 1pt、透明度 .55，尺寸只有 34×14（读作分隔符，不是图表）；
///   · 形状由 `id` 的字节和决定，**同一行永远是同一根线**（否则每次重绘都在抖，像在动）；
///   · 取值范围刻意避开"很平"和"满幅"，不暗示任何量级。
struct WatchMiniWaveMark: View {
    let seed: String

    private static let shapes: [[CGFloat]] = [
        [0.30, 0.70, 0.42, 0.92, 0.50, 0.80, 0.35, 0.62, 0.86, 0.45, 0.70],
        [0.55, 0.40, 0.84, 0.32, 0.65, 0.48, 0.90, 0.38, 0.60, 0.74, 0.42],
        [0.42, 0.86, 0.30, 0.70, 0.92, 0.40, 0.66, 0.32, 0.80, 0.52, 0.68],
        [0.60, 0.36, 0.74, 0.50, 0.32, 0.84, 0.45, 0.70, 0.40, 0.88, 0.55],
    ]

    private var pattern: [CGFloat] {
        let sum = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF }
        return Self.shapes[sum % Self.shapes.count]
    }

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step = size.width / CGFloat(max(1, pattern.count - 1))
            let mid = size.height / 2
            let reach = size.height / 2 - 1
            for (index, value) in pattern.enumerated() {
                let point = CGPoint(
                    x: CGFloat(index) * step,
                    y: mid - (value - 0.5) * 2 * reach
                )
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(
                path,
                with: .color(.white.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: 34, height: 14)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 「同步」页

/// 待传 / 连接 / 存储。原型的第 3 页。
///
/// ⚠️ 数字和状态**全部来自真实读数**，没有一处是占位符：
///    `model.pending.count` 是腕上还没送走的片段数，`link.phoneReachable` 是
///    WatchConnectivity 的实时可达性，可用容量取卷的 `volumeAvailableCapacityForImportantUsage`。
///    手表上最怕的就是"看起来在同步"——那会让人以为录音已经安全了。
struct WatchSyncPane: View {
    @EnvironmentObject private var model: WatchRecorderModel
    @EnvironmentObject private var link: WatchLink

    // ★ 2026-11-03 八轮（用户："立即同步的按键橙色背景需要跟随主题颜色，进度条也是"）：
    //   「立即同步」和进度条以前写死暖色 amber——那是"系统在说话"的语义色。
    //   用户要它们跟眼睛/波形同一支主题色。这里读同一对 store（与录音页一致）。
    @ObservedObject private var styleStore = WatchRingStyleStore.shared
    @ObservedObject private var faceStore = WatchFaceStore.shared

    /// 主题色：手机端「外观」选过就用它，否则手表自己那套。
    private var accent: Color {
        faceStore.colorHex.map { Color(botHex: $0) } ?? styleStore.style.tint
    }

    /// 可用空间的字符串。`onAppear` 算一次即可：它不会在一页停留的几秒内变化。
    @State private var freeSpace: String?

    var body: some View {
        // ★ 2026-11-03（用户："手表屏幕没有把屏幕利用完全，立即同步的按钮只显示了一半"）：
        // ① 包进 `ScrollView`——之前内容一高，最底下的「立即同步」就被裁掉半截；
        // ② 顶部留白 36 → **12**（页码条在底部，顶部只剩系统时间一行，不用让那么多）；
        // ③ 大数字 44 → **36**，把竖向空间还给列表和按钮。
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.Watch.syncToPhone)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(WatchHomeStyle.header)

                HStack(alignment: .center, spacing: 7) {
                    Text("\(model.pending.count)")
                        .font(.system(size: 36, weight: .thin))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text(L10n.Watch.pendingUnit)
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(WatchHomeStyle.dim)
                        .padding(.top, 6)
                }
                .padding(.top, 2)

                WatchSyncPulseBar(active: !model.pending.isEmpty, tint: accent)
                    .padding(.top, 7)

                VStack(spacing: 4) {
                    stat(L10n.Watch.phoneLabel,
                         value: link.phoneReachable ? L10n.Watch.phoneNear : L10n.Watch.phoneFar,
                         emphasised: link.phoneReachable)
                    if let freeSpace {
                        stat(L10n.Watch.storageLabel, value: L10n.Watch.storageFree(freeSpace), emphasised: false)
                    }
                }
                .padding(.top, 8)

                // ★ 2026-11-02（全天候录音）：省电模式且没在充电时，明说"为什么不动"。
                if model.transfersDeferred, !model.pending.isEmpty {
                    Label(L10n.Watch.deferNote, systemImage: "moon")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(WatchHomeStyle.amber.opacity(0.9))
                        .labelStyle(.titleAndIcon)
                        .padding(.top, 7)
                }

                if !model.pending.isEmpty {
                    Button {
                        WKInterfaceDevice.current().play(.click)
                        for clip in model.pending where !link.deliveredNames.contains(clip.name) {
                            model.retry(clip)
                        }
                    } label: {
                        Text(L10n.Watch.syncNow)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(accent.opacity(0.92)))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 10)

                    // ★ 2026-11-03（用户："这个页面跟等待同步到 iPhone 页面重复了"）：
                    // 「待传队列」独立页删除，列表搬到这里——同步页从此是"待传"的唯一入口：
                    // 上面是量与操作，下面是每一份还没到的东西。
                    pendingList
                        .padding(.top, 8)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .onAppear { freeSpace = Self.formattedFreeSpace() }
    }

    /// 待传片段的紧凑列表（原「待传队列」页的内容）。
    ///
    /// ⚠️ 只保留"是什么 + 多大"，不再给每行放重试/删除按钮：重试有上面的「立即同步」，
    ///    删除去手机端做——在表上滑来滑去找垃圾桶，命中率远低于误触率。
    private var pendingList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.pending.prefix(8)) { clip in
                let isQueued = link.queuedNames.contains(clip.name)
                    || link.deliveredNames.contains(clip.name)
                HStack(spacing: 6) {
                    Image(systemName: isQueued ? "arrow.up.circle" : "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(isQueued ? WatchHomeStyle.amber : WatchHomeStyle.dim)
                    Text(clip.displayTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Text(WatchFormat.bytes(clip.bytes))
                        .font(.system(size: 9))
                        .foregroundStyle(WatchHomeStyle.dim)
                        .monospacedDigit()
                }
                .padding(.vertical, 5)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(WatchHomeStyle.hairline)
                        .frame(height: 0.5)
                }
            }
            if model.pending.count > 8 {
                Text(L10n.Watch.pendingMore(model.pending.count - 8))
                    .font(.system(size: 9))
                    .foregroundStyle(WatchHomeStyle.dim)
                    .padding(.vertical, 5)
            }
        }
    }

    private func stat(_ label: String, value: String, emphasised: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(WatchHomeStyle.dim)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 10, weight: emphasised ? .medium : .regular))
                .foregroundStyle(emphasised ? .white.opacity(0.75) : WatchHomeStyle.dim)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    /// 这台手表的**可用**空间（不是"已用"）。
    ///
    /// ⚠️ 走 `attributesOfFileSystem` 的 `.systemFreeSize`，不用
    ///    `volumeAvailableCapacityForImportantUsage`——后者在 **watchOS 上不可用**
    ///    （编译直接报 `unavailable in watchOS`，2026-11-02 实测）。
    /// ⚠️ 数字只保留一位小数（`ByteCountFormatter` 默认行为）：手表上一行 10pt 的小字，
    ///    "3.2 GB 可用"比"3.19 GB 可用"好读，而且这个值本来就在动，多出来的位数是假精确。
    static func formattedFreeSpace() -> String? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let free = attributes[.systemFreeSize] as? Int64,
              free > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
    }
}

/// 同步进度条：一段来回游走的暖色。
///
/// ⚠️ 它是**不确定进度**（`pending` 里有几项不代表"这一项传到哪了"——WCSession 不报这个），
///    所以刻意不做百分比、不接 `ProgressView(value:)`：一条自己在走的线读作"在忙"，
///    一根卡在 38% 的条读作"卡住了"。卡住与否由"项待传"那个数字说话。
struct WatchSyncPulseBar: View {
    let active: Bool
    /// ★ 2026-11-03 八轮：跟随主题色（默认暖色，保留给别处调用）。
    var tint: Color = WatchHomeStyle.amber
    @State private var wide = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                if active {
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: geo.size.width * (wide ? 0.72 : 0.10))
                }
            }
        }
        .frame(height: 2)
        .onAppear { start() }
        .onChange(of: active) { _, _ in start() }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func start() {
        guard active else {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { wide = false }
            return
        }
        // 降低动态：停在中段，不做来回。
        guard !reduceMotion else {
            wide = true
            return
        }
        wide = false
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            wide = true
        }
    }
}
