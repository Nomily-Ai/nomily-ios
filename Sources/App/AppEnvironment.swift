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
    /// The on-disk ledger of the three kinds of long jobs — summary / translation / format conversion (2026-10-16 twelfth revision).
    ///
    /// ⚠️ **Parallel** to `transcription`, not a replacement for it — the transcription queue has its own
    ///    620-line pipeline and a complete set of working semantics; the reasoning is in the block at the top of `JobQueue`
    ///    titled "why transcription wasn't moved in". The two are only aggregated on the overview page (`TaskCenterView`).
    let jobs: JobQueue
    /// UI language override. Built from `config.json` so the choice survives
    /// relaunches; `nil` inside means follow the system.
    let localization: LocalizationService
    let watch: WatchSyncService
    /// The template the **auto** summary uses — the first built-in one. Resolved once at
    /// init (see the comment at the assignment) rather than on every call, because the
    /// template store is main-actor-bound while callers of `maybeAutoSummarize` may not be.
    private let autoSummaryTemplate: SummarizeTemplate?
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
    /// ★ 2026-10-20: the clip the "transcript ready" banner wants to open. Set by
    /// `RootView` when the toast is tapped, consumed by `LibraryView` (after
    /// `RecordingsView` has switched to the library segment). Three layers deep, so a
    /// hand-off flag is the only way through — same pattern as `openDeviceSheetForPairing`.
    @Published var pendingClipOpen: String?

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
        // PLAUD services register pulled clips into the library manifest so
        // the library's device filter gets its own **PLAUD** group.
        PlaudDirectService.shared.library = library
        PlaudCloudService.shared.library = library
        // The card also belongs in the device ledger (`config.devices`) so it is
        // listed alongside V05E / TicNote / A1 in Settings → Devices & Library.
        PlaudDirectService.shared.configService = config
        // ★ 2026-10-26 (user: "打开 App 卡片的连接就不要断，打开就要持续连接状态"):
        // the paired card used to stay disconnected until the pill was tapped.
        // The keeper re-wakes and reconnects it for as long as the app is in
        // the foreground — but only when no other card owns the BLE link, so
        // it can never steal the radio from a TicNote/A1 recording.
        PlaudDirectService.shared.isOtherCardConnected = { [bluetooth] in
            bluetooth.client != nil || bluetooth.recorderLink?.isConnected == true
        }
        PlaudDirectService.shared.startConnectionKeeper()
        let transcription = TranscriptionService(config: config)
        let afterTranscription = Date()
        // ★ 2026-10-16 twelfth revision: the on-disk queue for summary / translation / format conversion. The initialiser has only
        // a single disk read (`load()`), no side effects, so it slots in between transcription and watch.
        let jobs = JobQueue()
        let afterJobs = Date()
        self.bluetooth = bluetooth
        self.config = config
        self.library = library
        self.transcription = transcription
        self.jobs = jobs
        // The three runners are registered here rather than written into `JobQueue` — were that to reference
        // the LLM / exporters directly, it would have to know how to construct all three services, whereas all it truly needs to know
        // is "give me a job, I'll run it, and tell me the result when I'm done".
        //
        // The closure captures `config` (`ConfigService`, a reference type, globally unique) and only **when it runs**
        // reads `config.config` (that's a value type) — so this job reads **the current**
        // config, not the snapshot from the moment it was enqueued. This is deliberate: if the user goes into Settings while it's queued and adds
        // an API key, the job ought to run with the new key — no sense making them press the button again.
        // The only thing deliberately frozen is the summary's prompt (see the comment on `Job.prompt`).
        jobs.register(.summarize) { job, reporter in
            try await JobRunners.summarize(job, config: config.config, reporter: reporter)
        }
        jobs.register(.translate) { job, reporter in
            try await JobRunners.translate(job, config: config.config, reporter: reporter)
        }
        jobs.register(.export) { job, _ in
            try await JobRunners.export(job, config: config.config)
        }
        // ★ 2026-10-23 ("录音来源里面还有大纲总结"): the timestamped chapter
        // outline at the top of 来源. Same registration shape as the rest —
        // it reads `config.config` when it runs, so a key added while the job
        // waits is picked up.
        jobs.register(.outline) { job, reporter in
            try await JobRunners.outline(job, config: config.config, reporter: reporter)
        }
        // ★ "Summarize right after transcribing" (2026-10-18): the transcript→summary hand-off.
        //
        // Two guards, both deliberate:
        //   · the switch, so the user can turn it off; and
        //   · **at least one configured LLM** — otherwise the job would be enqueued and fail
        //     with "no provider", which the queue then shows as a stuck job. "On" means "do it
        //     when there is an AI service", not "try anyway".
        //
        // The template is the first built-in one on purpose: with no user in the loop there is
        // nobody to pick one, and auto-summary's job is "make the clip readable when I open it",
        // not "guess which of 90 templates I wanted".
        // The template is resolved **now**, not inside the closure: the store is
        // main-actor-bound and this initialiser already runs there, whereas the hook may fire
        // from a background resume path. (★ 2026-10-20 it moved onto `self` so
        // `maybeAutoSummarize` can share it — resolved once, here, for the same reason.)
        autoSummaryTemplate = SummarizeTemplateStore.defaults.first
        transcription.onTranscribed = { clip in
            Task { @MainActor in
                // ★ 2026-10-22 (任务三): the unified AiTask ledger advances with
                // the real queues. Runs before auto-summary so the pipeline can
                // observe whether a summarize job was actually enqueued.
                AiTaskCenter.shared.transcribeDidFinish(clipName: clip)
                AppEnvironment.shared?.maybeAutoSummarize(clipName: clip)
                // ★ 2026-10-20: the top banner telling the user the transcript has landed.
                // Same hook as auto-summary — manual, auto-after-download and the resumed
                // queue all funnel through this one callback, so one line covers all three.
                TranscriptionBannerCenter.shared.enqueue(clipName: clip)
                // ★ 2026-10-29 (饭耳移植 · 规格 §2.3): WebDAV backup — new transcripts
                // sync to the user's server right away. No-op unless WebDAV is
                // configured (the service checks `webdav.isConfigured` itself);
                // reads the config when it runs, so edits made meanwhile are picked up.
                if let config = AppEnvironment.shared?.config {
                    let cfg = config.config
                    Task { await WebDAVSyncService.shared.sync(clipName: clip, config: cfg) }
                }
            }
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
        // ★ 2026-10-15: resume the transcription that didn't finish last time.
        //
        // This is the half that makes "background transcription" possible — `BackgroundKeeper` only holds out against
        // "switching away for a bit", not the system killing the process when memory runs tight; the queue is persisted to disk,
        // and replaying it at launch is the only way to rescue that situation.
        //
        // Hung off the composition root rather than a view's `.task`: when the view appears depends on what the user
        // taps, and this shouldn't rely on the user happening to pass through the Library. It also lets the launch-timing stats
        // count it in (it only pulls the unfinished items out and queues them; it doesn't await itself).
        transcription.resumePending()
        // ★ 2026-10-29 (饭耳移植): hand the night-shift worker its services, and
        // submit the first request right away — iOS needs a pending request even
        // for tonight's window, and re-submitting from scenePhase .background
        // refreshes it with the newest conditions. The switch itself is read
        // again at execution time (see `handle`), so turning it off later is
        // honoured even if a request is already queued with the system.
        NightlyTranscribeScheduler.shared.configure(transcription: transcription, configService: config)
        NightlyTranscribeScheduler.shared.schedule()
        // ★ 2026-10-29 (饭耳移植 · 规格 §3.1): timed overnight recording. The
        // heartbeat evaluates the window every 30s while the process lives;
        // auto-start never pops the mic dialog (granted-permission check inside).
        TimedRecordingScheduler.shared.configure(configService: config, library: library)
        TimedRecordingScheduler.shared.evaluate()
        // Same reasoning, for the other three kinds of job: resume the unfinished summary / translation / format conversion from last time.
        //
        // ⚠️ Like `transcription.resumePending()`, it's hung off the composition root: this init runs only
        //    once **on a cold launch**, and the "app was killed by the system" path can only be saved by it
        //    (the moment the user reopens the app). The "process isn't dead, just switching back" path relies on
        //    `RootView`'s scenePhase — both are needed; see the comment there.
        jobs.resume()
        // ★ 2026-10-29 (用户："常用词汇里面从历史的文档里面提取")：首次启动 +
        // 每周一次，从全部转写里挖高频专名自动进词表。后台编排，不挡启动。
        if VocabularyStore.shared.shouldAutoMine() {
            VocabularyStore.mineOffMain()
        }
        // ★ 2026-10-22 (任务三): reconcile the AiTask ledger against what the
        // two queues actually replayed — interrupted pipelines get their honest
        // verdict instead of sitting in "transcribing" forever.
        AiTaskCenter.shared.recoverAtLaunch()
        // ★ 2026-10-29 (饭耳移植 · 规格 §2.2): the cold-data downgrade pass.
        // Fire-and-forget: re-encoding runs off the main actor inside the
        // service; the switch and tier are read when it starts. No-op unless
        // the user picked a tier and turned the toggle on.
        if config.config.coldDataDowngradeEnabled,
           config.config.recordingQualityTier != nil {
            let cfg = config.config
            Task { await RecordingQualityService.shared.runDowngrade(config: cfg) }
        }
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

    // MARK: - Auto pipeline (import → transcribe → summarize)

    /// ★ 2026-10-20: the **transcription** half of auto-transcribe-on-import, shared by the
    /// import paths that didn't have their own copy yet (card transfer sheet, live-stream
    /// saves). Watch / Wi-Fi fast-transfer / device-files got theirs inline earlier and keep
    /// them — same gate, same queue, one switch (`autoTranscribeAfterDownload`).
    ///
    /// Through the **queue** (`enqueueAndWait`) rather than a bare `transcribe`: the queue
    /// persists to disk first, so if the app is killed mid-run the next launch picks the job
    /// up from the pending list. Waiting for the dequeue also means the trailing
    /// `libraryDidChange` fires only once the transcript has actually landed, so the Library
    /// list can bring the text out in one pass.
    @MainActor
    func autoTranscribeAfterImport(fileURL: URL) async {
        guard config.config.autoTranscribeAfterDownload else { return }
        // ★ 2026-10-22 (任务三): open a ledger row so the pipeline is one
        // observable unit (queued → transcribing → summarizing → done).
        AiTaskCenter.shared.transcribeQueued(clipName: fileURL.lastPathComponent)
        await transcription.enqueueAndWait(fileURL: fileURL, enforceMinDuration: true)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    /// ★ 2026-10-20: the **summary** half, callable from anywhere. Extracted from the
    /// `onTranscribed` closure it used to live in: the live-stream path writes its
    /// transcript straight to disk (`LiveModel.saveTranscript`) and never passes through
    /// `TranscriptionService`, so its clips would never get a summary without this.
    ///
    /// Guards, all deliberate (carried over verbatim from the closure):
    ///   · the switch, so the user can turn it off;
    ///   · at least one configured LLM — otherwise the job would be enqueued and fail with
    ///     "no provider", which the queue then shows as a stuck job; and
    ///   · no existing summary — never overwrite a hand-edited result with a machine one.
    @MainActor
    func maybeAutoSummarize(clipName: String) {
        let cfg = config.config
        guard cfg.autoSummarizeAfterTranscription,
              !cfg.llmProviders.configuredProviders.isEmpty,
              let template = autoSummaryTemplate
        else { return }
        // Never overwrite a summary the user already has. Transcribing the same clip twice
        // (manual retry, resumed queue, a provider switch) would otherwise silently replace
        // a hand-edited result with a fresh machine one.
        guard !FileManager.default.fileExists(atPath: StorageLocations.summaryURL(for: clipName).path)
        else { return }
        jobs.enqueue(.summarize(
            clip: clipName,
            prompt: template.localizedPrompt,
            templateName: template.name
        ))
    }
}
