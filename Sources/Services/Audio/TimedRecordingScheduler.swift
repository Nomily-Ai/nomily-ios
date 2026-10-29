import AVFoundation
import Foundation
import HealthKit
import os.log
import UserNotifications

private let log = Logger(subsystem: "com.nomily.app.ios", category: "timed-rec")

/// ★ 2026-10-29（饭耳移植 · 规格 §3.1 定时录音 · 按时间录）
///
/// The night-shift recorder: between the configured start/end times the
/// scheduler starts the phone mic (`PhoneMicRecorder`) and keeps it running
/// until the end of the window — "开始后不会自己停" is honoured literally:
/// only the end time stops it.
///
/// Reality of the platform, stated plainly:
///   · **Auto-start only works while the process is alive.** iOS gives no
///     silent mic wake-up. We evaluate on launch, on every foreground
///     return, and on a 30-second heartbeat; if the window began while the
///     app was dead, the recording starts at the next evaluation *inside*
///     the window (partial night rather than nothing).
///   · **Mic permission must already be granted** — auto-start never pops the
///     system permission dialog at random hours. If it isn't granted (or the
///     engine throws), we fall back to a local notification asking the user
///     to open the app.
///   · While recording, `BackgroundKeeper(.timedRecording)` holds the silent
///     keep-alive so suspension doesn't cut the take.
///
/// The saved clip flows into the same library pipeline as manual phone
/// recordings: `recordDownload` + `autoTranscribeAfterImport` — transcripts,
/// summaries and (if configured) WebDAV sync all follow for free.
@MainActor
final class TimedRecordingScheduler: ObservableObject {

    static let shared = TimedRecordingScheduler()
    private init() {}

    @Published private(set) var isTimedRecording = false
    /// Last status line for the settings page. Public set: the settings page
    /// writes HealthKit prefill outcomes here too (one status line per section).
    @Published var lastNotice: String?

    private let recorder = PhoneMicRecorder()
    private var heartbeat: Timer?
    private weak var configService: ConfigService?
    private weak var library: Library?

    // MARK: - Wiring

    /// From `AppEnvironment.init` — the scheduler needs config + library; the
    /// auto-transcribe hand-off goes through `AppEnvironment.shared`.
    func configure(configService: ConfigService, library: Library) {
        self.configService = configService
        self.library = library
        startHeartbeat()
    }

    /// Call from scenePhase `.active` too — the cheapest way to catch "the
    /// window started while the app sat in the task switcher".
    func evaluate() {
        guard let configService else { return }
        let cfg = configService.config
        guard cfg.timedRecordingEnabled else {
            if isTimedRecording { finishRecording(reason: "switch turned off") }
            return
        }
        guard Self.inWindow(start: cfg.timedRecordingStart, end: cfg.timedRecordingEnd, at: Date()) else {
            if isTimedRecording {
                // End of window — this is the only thing that stops the take.
                finishRecording(reason: "window ended")
            }
            lastNotice = nil
            return
        }

        guard !isTimedRecording else { return }
        // Never pop the permission dialog on a timer: auto-start only when
        // the user already granted the mic (they did if they ever recorded).
        guard AVAudioSession.sharedInstance().recordPermission == .granted else {
            lastNotice = L10n.TimedRecording.micNotGranted
            notifyStartMissed()
            return
        }
        startRecording()
    }

    // MARK: - Recording

    private func startRecording() {
        do {
            try recorder.start()
            isTimedRecording = true
            BackgroundKeeper.shared.acquire(.timedRecording)
            lastNotice = L10n.TimedRecording.recording
            log.notice("timed recording started")
        } catch {
            lastNotice = error.localizedDescription
            log.error("timed start failed: \(error.localizedDescription, privacy: .public)")
            notifyStartMissed()
        }
    }

    /// Stop, save into the library, hand off to auto-transcribe. Mirrors
    /// `PhoneRecordScreen.finishRecording` minus the live-captions path
    /// (timed takes have no caption UI; the file pipeline is the transcript).
    private func finishRecording(reason: String) {
        guard isTimedRecording else { return }
        isTimedRecording = false
        BackgroundKeeper.shared.release(.timedRecording)
        guard let url = recorder.stop() else { return }
        let name = url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        library?.recordDownload(name: name, size: size, transport: "stream")
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        lastNotice = L10n.TimedRecording.saved(name)
        log.notice("timed recording saved \(name, privacy: .public) (\(reason, privacy: .public))")
        if configService?.config.autoTranscribeAfterDownload == true {
            Task { @MainActor in
                await AppEnvironment.shared?.autoTranscribeAfterImport(fileURL: url)
            }
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in TimedRecordingScheduler.shared.evaluate() }
        }
    }

    // MARK: - Window math

    /// "HH:mm" window, midnight-crossing safe ("23:30"–"07:00").
    static func inWindow(start: String, end: String, at date: Date) -> Bool {
        guard let s = minutes(start), let e = minutes(end) else { return false }
        let cal = Calendar.current
        let n = cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        return s <= e ? (n >= s && n < e) : (n >= s || n < e)
    }

    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), (0...23).contains(h),
              let m = Int(parts[1]), (0...59).contains(m)
        else { return nil }
        return h * 60 + m
    }

    // MARK: - Fallback notification

    /// The window began (or the engine failed) without a granted mic — ask
    /// the user to open the app. Silent no-op without notification permission.
    private func notifyStartMissed() {
        let content = UNMutableNotificationContent()
        content.title = L10n.TimedRecording.missedTitle
        content.body = L10n.TimedRecording.missedBody
        let request = UNNotificationRequest(
            identifier: "timed-recording-missed-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// ★ 2026-10-29 (饭耳移植 · 规格 §3.1): prefill the timed-recording window from
/// the most recent sleep segment in HealthKit — spec's "优先读 HealthKit 睡眠数据",
/// with the hand-filled times as the fallback the settings page shows.
enum HealthKitSleepReader {

    /// Returns "HH:mm" bed/wake times, or nil (no data / denied / unavailable) —
    /// callers then keep whatever the user hand-filled, per spec.
    static func latestSleepWindow() async -> (bed: String, wake: String)? {
        guard HKHealthStore.isHealthDataAvailable() else { return nil }
        let store = HKHealthStore()
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        do {
            try await store.requestAuthorization(toShare: [], read: [sleepType])
        } catch {
            log.error("HealthKit auth failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let predicate = HKQuery.predicateForSamples(withStart: sevenDaysAgo, end: Date())
        let samples: [HKCategorySample] = await withCheckedContinuation { cont in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: 500,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, result, _ in
                cont.resume(returning: (result as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }

        // Group samples into nights: samples whose start is within 4 hours of
        // the newest sample's start belong to the same night (Apple sometimes
        // splits a night into inBed/asleep cores).
        guard let newest = samples.first else { return nil }
        let nightSamples = samples.filter {
            abs($0.startDate.timeIntervalSince(newest.startDate)) < 4 * 3600
        }
        guard let bed = nightSamples.map(\.startDate).min(),
              let wake = nightSamples.map(\.endDate).max(),
              wake.timeIntervalSince(bed) > 0
        else { return nil }

        let cal = Calendar.current
        let bedMin = cal.component(.hour, from: bed) * 60 + cal.component(.minute, from: bed)
        let wakeMin = cal.component(.hour, from: wake) * 60 + cal.component(.minute, from: wake)
        return (hhmm(bedMin), hhmm(wakeMin))
    }

    private static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60 % 24, minutes % 60)
    }
}
