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
        // from a background resume path.
        let autoSummaryTemplate = SummarizeTemplateStore.defaults.first
        transcription.onTranscribed = { clip in
            let cfg = config.config
            guard cfg.autoSummarizeAfterTranscription,
                  !cfg.llmProviders.configuredProviders.isEmpty,
                  let template = autoSummaryTemplate
            else { return }
            // Never overwrite a summary the user already has. Transcribing the same clip twice
            // (manual retry, resumed queue, a provider switch) would otherwise silently replace
            // a hand-edited result with a fresh machine one.
            guard !FileManager.default.fileExists(atPath: StorageLocations.summaryURL(for: clip).path)
            else { return }
            jobs.enqueue(.summarize(
                clip: clip,
                prompt: template.localizedPrompt,
                templateName: template.name
            ))
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
        // Same reasoning, for the other three kinds of job: resume the unfinished summary / translation / format conversion from last time.
        //
        // ⚠️ Like `transcription.resumePending()`, it's hung off the composition root: this init runs only
        //    once **on a cold launch**, and the "app was killed by the system" path can only be saved by it
        //    (the moment the user reopens the app). The "process isn't dead, just switching back" path relies on
        //    `RootView`'s scenePhase — both are needed; see the comment there.
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
