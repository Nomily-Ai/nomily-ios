import Foundation
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "launch")

/// Composition root. Holds long-lived services (BLE, config, library) and is
/// injected as an `@EnvironmentObject` at the root.
@MainActor
final class AppEnvironment: ObservableObject {
    let bluetooth: BluetoothCoordinator
    let config: ConfigService
    let library: Library
    let transcription: TranscriptionService
    /// 摘要 / 翻译 / 格式转换三类长任务的落盘台账（2026-10-16 十二改）。
    ///
    /// ⚠️ 与 `transcription` **并列**而不是取代它 —— 转录那条队列有自己的
    ///    620 行管线与一整套已经跑通的语义，理由写在 `JobQueue` 顶部那段
    ///    "为什么转录没有搬进来"里。两者只在总览页（`TaskCenterView`）汇总。
    let jobs: JobQueue
    /// UI language override. Built from `config.json` so the choice survives
    /// relaunches; `nil` inside means follow the system.
    let localization: LocalizationService
    let watch: WatchSyncService
    @Published var isStreaming = false
    @Published var isBLETransferring = false
    /// Set by DeviceFilesView while the Device segment is on screen.
    /// RootView calls it when the user confirms switching away mid-transfer.
    var cancelBLETransfers: (() -> Void)?
    @Published var navigateToASRProviders = false
    @Published var navigateToLLMProviders = false
    /// Set by the device-tab encryption-onboarding banner to deep-link
    /// straight into Recordings settings with the passphrase sheet open.
    @Published var navigateToRecordingsSettings = false
    @Published var openPassphraseSheet = false
    /// Set by recording UI when an unpaired-device error needs to open the
    /// current device sheet and expose its pairing banner.
    @Published var openDeviceSheetForPairing = false

    /// The live composition root, for the one caller SwiftUI's environment
    /// can't reach: `ToggleRecordingIntent` runs in this process but outside
    /// any view hierarchy. Weak so it can't outlive the scene that owns it, and
    /// read-only so nothing else is tempted to reach for services this way
    /// instead of taking them as `@EnvironmentObject`.
    private(set) static weak var shared: AppEnvironment?

    init() {
        // This runs before SwiftUI's first frame, so anything slow in here is
        // time the user spends staring at the launch screen. Timed per service
        // rather than in total: when the launch screen hangs, "which one" is
        // the only question worth answering (see README → Logs).
        let startedAt = Date()
        let config = ConfigService()
        let afterConfig = Date()
        let bluetooth = BluetoothCoordinator()
        let afterBluetooth = Date()
        let library = Library()
        let afterLibrary = Date()
        let transcription = TranscriptionService(config: config)
        let afterTranscription = Date()
        // ★ 2026-10-16 十二改：摘要 / 翻译 / 格式转换的落盘队列。构造里只有
        // 一次读盘的 `load()`，没有副作用，所以夹在转录之后、watch 之前。
        let jobs = JobQueue()
        let afterJobs = Date()
        self.bluetooth = bluetooth
        self.config = config
        self.library = library
        self.transcription = transcription
        self.jobs = jobs
        // 三个执行体在这里注册，而不是写进 `JobQueue` —— 那里一旦直接引用
        // LLM / 导出器，就得同时知道三套服务的构造方式，而它真正需要知道的
        // 只有"给我一条活，我去跑、跑完把结果告诉我"。
        //
        // 闭包捕获 `config`（`ConfigService`，引用类型、全局唯一），**跑的时候**
        // 才去读 `config.config`（那是值类型）—— 所以这条活读到的是**当下**的
        // 配置，不是入队那一刻的快照。这是有意的：用户在排队期间去设置里补上了
        // API Key，这条活就该用上新 Key 跑，没道理让他重按一次。
        // 唯一刻意定格的是摘要的 prompt（见 `Job.prompt` 那段注释）。
        jobs.register(.summarize) { job, reporter in
            try await JobRunners.summarize(job, config: config.config, reporter: reporter)
        }
        jobs.register(.translate) { job, reporter in
            try await JobRunners.translate(job, config: config.config, reporter: reporter)
        }
        jobs.register(.export) { job, _ in
            try await JobRunners.export(job, config: config.config)
        }
        self.localization = LocalizationService(selected: config.config.appLanguage)
        self.watch = WatchSyncService(
            config: config,
            library: library,
            transcription: transcription
        )
        // Activated here rather than from a view: the watch can wake this app
        // in the background, and the session has to be live before the first
        // clip arrives. The WatchConnectivity work itself is
        // dispatched off the main thread — see `WatchSyncService.activate`.
        self.watch.activate()
        Self.shared = self
        // ★ 2026-10-15：上次没干完的转录接着跑。
        //
        // 这才是"后台转录"能成立的那一半 —— `BackgroundKeeper` 只顶得住
        // "切走一会儿"，顶不住系统在内存紧张时把进程咔嚓掉；队列是落盘的，
        // 启动时照着它重来是唯一能把那种情况救回来的办法。
        //
        // 挂在组合根而不是某个视图的 `.task`：视图什么时候出现取决于用户
        // 点什么，而这件事不该指望用户恰好路过资料库。也让启动耗时统计把它
        // 算进去（它只是把未完成项拿出来排队，本身不 await）。
        transcription.resumePending()
        // 同一条理由，给另外三类活：上次没跑完的摘要 / 翻译 / 格式转换接着跑。
        //
        // ⚠️ 与 `transcription.resumePending()` 一样挂在组合根：这个 init 只在
        //    **冷启动**跑一次，"App 被系统咔嚓掉"那条路只有靠它才救得回来
        //    （用户再打开 App 的那一刻）。"进程没死、只是切回来"那条路靠
        //    `RootView` 的 scenePhase，两处都要有 —— 见那里的注释。
        jobs.resume()
        let done = Date()
        log.notice("""
            environment ready in \(Self.ms(startedAt, done)) ms \
            (config=\(Self.ms(startedAt, afterConfig)) \
            ble=\(Self.ms(afterConfig, afterBluetooth)) \
            library=\(Self.ms(afterBluetooth, afterLibrary)) \
            asr=\(Self.ms(afterLibrary, afterTranscription)) \
            jobs=\(Self.ms(afterTranscription, afterJobs)) \
            watch=\(Self.ms(afterJobs, done)))
            """)
    }

    private static func ms(_ from: Date, _ to: Date) -> Int {
        Int(to.timeIntervalSince(from) * 1000)
    }
}
