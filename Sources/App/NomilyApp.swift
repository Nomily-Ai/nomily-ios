import SwiftUI
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "launch")

@main
struct NomilyApp: App {
    /// Stamped the moment this app's own code first runs, and compared against
    /// the first frame below. A launch-screen hang is then attributable: a
    /// small number here with a long wait on screen means the time went to
    /// system-side work around us (dyld, bundle validation, handing the
    /// embedded watch app to the paired watch), not to our code.
    static let appInitAt = Date()

    @StateObject private var environment = AppEnvironment()

    init() {
        _ = Self.appInitAt  // `static let` is lazy; touch it so it stamps now
        // ★ 未读账本必须在**启动时**就建出来，不能等资料库被打开。
        //
        // `origin`（"本功能上线的那一刻"）是懒加载时取的 —— 如果等到用户
        // 第一次进资料库才建，那么"App 已经跑着、卡刚传完一条、然后才点进
        // 资料库"这条最常见的路径上，到货时间会早于 `origin`，那条新录音
        // 就**永远等不到红点**。启动时摸一下，origin 就落在任何一次传输之前。
        _ = ClipReadStore.shared
        // ★ 回收站的"30 天后自动删除"靠这里跑第一趟。
        //
        // 没有 `BGTaskScheduler` 可挂（那需要额外的后台模式声明，而且系统
        // 什么时候给调度完全不受我们控制），所以过期清理只能挂在两个用户
        // 一定会经过的点上：**启动**（这里）和**打开回收站**（`TrashView`）。
        // 启动时跑还有个额外好处 —— 清理发生在任何界面读磁盘之前，过期条目
        // 不会先被设置页那个条数徽标数进去、再"自己少一个"。
        _ = ClipTrash.shared.purgeExpired()
        // 落盘诊断的**会话分隔行**。两个作用：
        //   1. 让 `Documents/ticnote-ble.log` 一定存在 —— 否则"用户没连过卡"
        //      与"诊断器没生效"看起来一模一样（都是没有这个文件），分不开；
        //   2. 多次启动的日志会追加在同一份文件里，靠这行切段，
        //      才能回答"这条记录是哪一次启动里的"。
        TicNoteDiagLog.log("DIAG", "App 启动 —— ticnote 诊断开始")
    }

    var body: some Scene {
        WindowGroup {
            LocalizedRoot()
                .environmentObject(environment)
                .environmentObject(environment.bluetooth)
                .environmentObject(environment.config)
                .environmentObject(environment.library)
                .environmentObject(environment.transcription)
                // ★ 2026-10-16 十二改：后台任务队列（摘要 / 翻译 / 格式转换）。
                // 与 `watch` 同一条理由 —— 嵌套 ObservableObject 的 `@Published`
                // 变化不会让只观察父对象的视图失效，不单独注入的话详情页与
                // 后台任务页会一直停在旧状态上（"活跑完了但界面不更新"）。
                .environmentObject(environment.jobs)
                .environmentObject(environment.localization)
                // Injected in its own right, not reached through `environment`:
                // a nested ObservableObject's @Published changes don't
                // invalidate views observing only the parent.
                .environmentObject(environment.watch)
                .onAppear {
                    let ms = Int(Date().timeIntervalSince(Self.appInitAt) * 1000)
                    log.notice("first frame \(ms) ms after app init")
                }
        }
    }
}

/// Re-renders the whole UI when the language changes.
///
/// `L10n` reads are plain function calls, so a view that doesn't observe
/// `LocalizationService` has no reason to re-evaluate its body and would keep
/// showing the old language. The `.id` forces a fresh subtree — a wholesale
/// redraw that also lands back on the root screen.
private struct LocalizedRoot: View {
    @EnvironmentObject private var localization: LocalizationService

    var body: some View {
        RootView()
            // Dates, numbers and RTL follow the chosen language too — otherwise
            // the text switches to Arabic while the layout stays left-to-right.
            .environment(\.locale, Locale(identifier: localization.effective))
            .environment(\.layoutDirection, localization.layoutDirection)
            .id(localization.selected ?? "system")
    }
}
