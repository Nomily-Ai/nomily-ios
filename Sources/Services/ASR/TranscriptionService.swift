import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr")

/// Drives the `primary → fallbacks` chain from `config.defaults.asr` for one
/// audio file at a time. Writes `{name}.txt` + `{name}.asr.json` next to the
/// decrypted audio so the artefacts travel together.
///
/// Since 2026-10-15 there are three more things, all for "transcription keeps failing / dies the moment you switch to the background":
/// - **Keep-alive**: holds `BackgroundKeeper` for the whole transcription so switching to the background doesn't suspend it;
/// - **Backoff retries**: **temporary** failures like network flakiness, 429s and timeouts are retried automatically,
///   while **inevitable** failures like 401s / format errors are not retried (retrying only wastes quota);
/// - **Persistent queue**: jobs that come in through auto-transcription are written to disk, so after the app is killed
///   they carry on at the next launch / on returning to the foreground.
@MainActor
final class TranscriptionService: ObservableObject {
    private let config: ConfigService

    /// Filenames currently being transcribed. Observed by views so they can
    /// render a spinner + hide the "Transcribe" button while an auto-path
    /// transcription is running in the background (otherwise the user lands
    /// on Clip detail right after a download and sees the manual button even
    /// though the pipeline is already doing the work).
    @Published private(set) var inFlight: Set<String> = []

    /// Jobs queued up / waiting to be retried after a failure (not the same concept as `inFlight`: that is "running
    /// right now", while this is "not finished yet"). Persisted, so it survives across launches.
    @Published private(set) var pending: [PendingJob] = []

    /// Per-file task handles for cancellation. Duplicate calls for the same
    /// key re-use the existing task so two UI surfaces asking for the same
    /// clip don't double up on ASR credits.
    private var tasks: [String: Task<AsrResult, Error>] = [:]

    /// Per-clip provider fallback notices — keyed by audio filename (same
    /// space as `inFlight`). Populated when a provider fails and the chain
    /// falls through to the next one. Cleared when a new transcription for
    /// that clip starts. Observed by ClipDetailView for a non-blocking notice.
    @Published private(set) var fallbackWarnings: [String: [String]] = [:]

    /// The queue's serial pump, preventing two `resumePending()` calls running at once from running the same job twice.
    private var drainTask: Task<Void, Never>?

    /// Fired on the main actor after a transcript has been **written**, with the audio's file name
    /// (`clip.m4a`), which is the same key the summary job uses for `clipName`. Wired up in
    /// `AppEnvironment`; `TranscriptionService` deliberately doesn't know about `JobQueue` (this
    /// file is about speech, not about scheduling work).
    var onTranscribed: ((String) -> Void)?

    init(config: ConfigService) {
        self.config = config
        self.pending = Self.loadQueue()
        // ★ Strip out entries whose "audio is already gone" at load time.
        //
        // Relying only on the `fileExists` check inside `runDrainLoop` isn't enough: an entry that has used up all `maxAttempts`
        // is kept outside by `resumePending`'s gate, so drain never runs,
        // and "the user deleted that recording, but its failure record is still in the queue" hangs forever on
        // that line on the settings page, never clearing however you tap.
        //
        // Done once at launch only (one `fileExists` per entry, on the order of tens), not on any hot path
        // other than `forget`.
        let before = pending.count
        pending.removeAll { job in
            let url = StorageLocations.decryptedDir.appendingPathComponent(job.name)
            return !FileManager.default.fileExists(atPath: url.path)
        }
        if pending.count != before {
            log.info("queue: pruned \(before - self.pending.count) orphaned job(s) on load")
            saveQueue()
        }
        // Mirror the switch onto the keeper. The keeper is a singleton and config isn't, so it's refreshed
        // every time config is written to disk (`syncBackgroundKeeper`).
        syncBackgroundKeeper()
    }

    // MARK: - Keep-alive switch

    /// Mirrors `config.backgroundKeepAliveEnabled` onto `BackgroundKeeper`.
    /// The settings page calls it after changing the switch; `init` calls it too, so that "it was already off last time"
    /// takes effect immediately on a cold start (otherwise the first recording needlessly occupies a session for a few seconds).
    func syncBackgroundKeeper() {
        BackgroundKeeper.shared.audioKeepAliveEnabled = config.config.backgroundKeepAliveEnabled
    }

    // MARK: - Queue (persistent)

    /// One job that isn't finished yet.
    struct PendingJob: Codable, Identifiable, Equatable {
        /// The audio file name — the same key space as `inFlight` / `fallbackWarnings`.
        var name: String
        var locales: [String]?
        var enforceMinDuration: Bool
        /// How many rounds have been tried (including the one running now).
        var attempts: Int
        /// The reason the last round failed, for the UI to show.
        var lastError: String?
        var enqueuedAt: Date
        var id: String { name }
    }

    /// At most how many rounds one transcription tries: 1 first attempt + 2 retries.
    /// More would be pointless — with something like local Ollama at minutes per round, 5 attempts would make the user think it's frozen.
    static let maxAttempts = 3

    /// The wait after round `attempt` fails. Exponential backoff (2/8/30 seconds), **not capped up to the minute scale**,
    /// because the user is most likely watching that spinner; waiting too long is worse than erroring early and letting them retry.
    private static func backoff(afterAttempt attempt: Int) -> Duration {
        switch attempt {
        case 1: return .seconds(2)
        case 2: return .seconds(8)
        default: return .seconds(30)
        }
    }

    /// The two shapes of cancellation: Swift Concurrency's `CancellationError`, and `URLError.cancelled`
    /// that URLSession throws when cancelled. **Both must be recognised** — recognising only the former,
    /// the job would still be treated as a "temporary failure" and retried twice after the user taps "Cancel".
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// Whether this error is worth another round.
    ///
    /// The test is "**could another attempt be different**", not "how serious is the error":
    /// - cancelled → don't retry (the user doesn't want it to run);
    /// - no provider configured / missing key / no endpoint configured → don't retry (config won't change on its own);
    /// - too short → don't retry (the file won't grow on its own);
    /// - the rest (HTTP, transport, decoding, empty) → retry them all. A 429 wants backoff,
    ///   5xx is server flakiness, a timeout is network flakiness, and decoding/empty is occasionally a truncated response.
    private static func isRetriable(_ error: Error) -> Bool {
        if isCancellation(error) { return false }
        guard let asr = error as? AsrError else { return true }
        switch asr {
        case .missingCredentials, .noProviderConfigured, .tooShort,
             .azureRequiredForTranslation:
            return false
        case .allProvidersUnreachable, .http, .transport, .decoding, .empty:
            return true
        }
    }

    /// Enqueue a job (the auto-transcription paths come through here).
    ///
    /// The difference from calling `transcribe(...)` directly: **persist first, run second**. The difference only shows
    /// in the one case of "the app getting killed midway" — in that case the job that ran directly
    /// vanishes into thin air, and coming back the next day the user sees only an untranscribed recording with no idea
    /// an attempt was ever made.
    func enqueue(fileURL: URL, locales: [String]? = nil, enforceMinDuration: Bool = false) {
        let key = fileURL.lastPathComponent
        if let idx = pending.firstIndex(where: { $0.name == key }) {
            // Already in the queue: don't add a duplicate, but **reset** the retry count (the user asked for it again
            // on purpose, which means the previous give-up doesn't count).
            pending[idx].attempts = 0
            pending[idx].lastError = nil
        } else {
            pending.append(PendingJob(
                name: key,
                locales: locales,
                enforceMinDuration: enforceMinDuration,
                attempts: 0,
                lastError: nil,
                enqueuedAt: Date()
            ))
        }
        saveQueue()
        startDrainIfNeeded()
    }

    /// Enqueue and **wait for it to leave the queue** (success, giving up after exhausting attempts, or the audio being gone).
    ///
    /// For callers that "wait for a result before refreshing the UI" — currently only the watch-arrival path: it used
    /// to `await transcribe` and then post `libraryDidChange`, so the library list would immediately
    /// bring up the transcription text. Note what's awaited is "**this job leaving the queue**", not "one particular `transcribe`
    /// returning": during retries it stays on the queue the whole time.
    func enqueueAndWait(fileURL: URL, locales: [String]? = nil, enforceMinDuration: Bool = false) async {
        enqueue(fileURL: fileURL, locales: locales, enforceMinDuration: enforceMinDuration)
        // Synchronous assignment and synchronous read on the same main actor, so there's no "hasn't started yet" window.
        await drainTask?.value
    }

    /// Remove one from the queue (the user deleted that recording by hand, or the transcription succeeded).
    func forget(name: String) {
        guard pending.contains(where: { $0.name == name }) else { return }
        pending.removeAll { $0.name == name }
        saveQueue()
    }

    /// Restart jobs that aren't finished yet. Hooked in at two points: **app launch** (`NomilyApp.init`) and
    /// **returning to the foreground** (`RootView`'s scenePhase becoming .active).
    ///
    /// Only with this can it be called "background transcription" — `BackgroundKeeper` alone only survives "switching away for a bit",
    /// not "the system snuffing out the process under memory pressure". In that case the only way to recover
    /// is to start over from this list at the next launch.
    func resumePending() {
        guard pending.contains(where: { $0.attempts < Self.maxAttempts }) else { return }
        startDrainIfNeeded()
    }

    /// Whether this clip is still queued for transcription (or mid-run).
    /// ★ (2026-10-22) `AiTaskCenter`'s launch recovery reads this to tell
    /// "the queue replay will finish it" from "it died with the process".
    func hasPending(clipName: String) -> Bool {
        pending.contains { $0.name == clipName } || inFlight.contains(clipName)
    }

    /// The queue's serial pump. Synchronous assignment on `@MainActor` ⇒ the `drainTask?.value`
    /// right after is guaranteed to see it, with no "task hasn't started" race.
    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDrainLoop()
            self.drainTask = nil
        }
    }

    /// Runs through the queued jobs serially. Only one runs at a time: the ASR side has quota as it is,
    /// and submitting concurrently would only lengthen the local single card's queue.
    private func runDrainLoop() async {
        // Uses `first(where:)` rather than `first`: a job that has exhausted `maxAttempts` **stays
        // in the queue** (the UI must be able to say "this one never succeeded"), but must not be picked up to run again —
        // with `first` it would sit at the head of the queue forever and waste a round every launch.
        while let job = pending.first(where: { $0.attempts < Self.maxAttempts }) {
            let url = StorageLocations.decryptedDir.appendingPathComponent(job.name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                // The audio is already gone (the user deleted the recording, or it hasn't been downloaded yet) —
                // keeping it would only waste a round on every launch.
                log.info("queue: dropping \(job.name, privacy: .public) — audio gone")
                forget(name: job.name)
                continue
            }
            do {
                _ = try await transcribe(
                    fileURL: url,
                    locales: job.locales,
                    enforceMinDuration: job.enforceMinDuration,
                    viaQueue: true
                )
                forget(name: job.name)
            } catch where Self.isCancellation(error) {
                // The user cancelled deliberately: not treated as a failure, and not retried automatically either.
                forget(name: job.name)
            } catch {
                guard let idx = pending.firstIndex(where: { $0.name == job.name }) else { continue }
                pending[idx].attempts += 1
                pending[idx].lastError = error.localizedDescription
                let attempts = pending[idx].attempts
                saveQueue()
                if attempts >= Self.maxAttempts {
                    log.warning("queue: \(job.name, privacy: .public) gave up after \(attempts) attempts")
                    // Attempts exhausted. Kept on record rather than deleted — so the UI can show "this one never succeeded",
                    // rather than letting the user think it was never tried. The user tapping transcribe once more by hand
                    // (`enqueue`) resets the count and grants it 3 more chances.
                    continue
                }
                try? await Task.sleep(for: Self.backoff(afterAttempt: attempts))
            }
        }
    }

    private static func loadQueue() -> [PendingJob] {
        guard let data = try? Data(contentsOf: StorageLocations.transcriptionQueueURL),
              let jobs = try? JSONDecoder().decode([PendingJob].self, from: data) else {
            return []
        }
        return jobs
    }

    private func saveQueue() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(pending) else { return }
        try? FileManager.default.createDirectory(
            at: StorageLocations.root, withIntermediateDirectories: true
        )
        try? data.write(to: StorageLocations.transcriptionQueueURL, options: .atomic)
    }

    /// Cancel the in-flight transcription for `name`, if any. The awaiting
    /// call will throw `CancellationError` (or `URLError.cancelled` from
    /// an underlying URLSession call) — both get swallowed by callers that
    /// surface "user cancelled" as idle.
    func cancel(name: String) {
        tasks[name]?.cancel()
        forget(name: name)
    }

    /// One item in the retry queue (tapped by the user from the background jobs page / the detail page).
    ///
    /// ★ Added in the twelfth revision, 2026-10-16. It exists so that **callers don't have to assemble the path themselves**:
    /// `enqueue` identifies things by `fileURL.lastPathComponent`, so a caller would have to know
    /// the whole convention of "the audio is in `decryptedDir` and the job's name is the file name" — that is this class's
    /// internal knowledge, and scattering it into the UI would sooner or later produce one wrong path (say, using `root` instead of
    /// `decryptedDir`, showing up as "tapping retry does nothing").
    ///
    /// Goes through `enqueue` rather than opening another path: for an **existing** entry `enqueue` only clears
    /// `attempts` and `lastError`, leaving `locales` / `enforceMinDuration` alone —
    /// that is, "retry" retries **the original job**, including the recognition language the user specified originally.
    /// This is exactly the semantics of `JobQueue.retry(id:)`, kept consistent on both sides.
    func retry(name: String) {
        guard pending.contains(where: { $0.name == name }) else { return }
        enqueue(fileURL: StorageLocations.decryptedDir.appendingPathComponent(name))
    }

    /// Transcribe `fileURL` using the configured provider chain.
    /// Returns the first successful provider's `AsrResult` and writes
    /// the transcript pair to disk; throws the last provider's error if
    /// every provider fails (or `AsrError.empty` when no provider is wired).
    ///
    /// `enforceMinDuration` gates `min_transcribe_duration` to the
    /// auto-transcribe-after-download path. Explicit taps on a Transcribe
    /// button always bypass the gate — user intent overrides the
    /// threshold, which otherwise surfaces a confusing error right after
    /// the user just asked to transcribe a short clip.
    ///
    /// `viaQueue` is an internal switch for the queue itself; don't pass it from outside: it decides whether a failure
    /// goes back to the queue for another go, and whether to try a few more rounds on the backoff schedule.
    func transcribe(
        fileURL: URL,
        locales: [String]? = nil,
        enforceMinDuration: Bool = false,
        viaQueue: Bool = false
    ) async throws -> AsrResult {
        let key = fileURL.lastPathComponent

        // Dedupe: a concurrent call for the same clip (e.g., user taps
        // Transcribe while the auto path is already running) waits on the
        // existing task instead of starting a duplicate network round-trip.
        if let existing = tasks[key] {
            return try await existing.value
        }

        // ★ The keep-alive starts at this instant and holds until this job leaves.
        //
        // The placement matters: it must be taken **outside** the `Task`. Put it inside and, since `Task` starts
        // asynchronously, there's a window between "the user taps transcribe" and "the task actually runs"; if the user
        // switches away in that window, no one is holding the process up — and that's precisely the easiest moment to switch away.
        BackgroundKeeper.shared.acquire(.transcription)

        let task = Task<AsrResult, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.runWithRetry(
                fileURL: fileURL,
                locales: locales,
                enforceMinDuration: enforceMinDuration,
                viaQueue: viaQueue
            )
        }
        tasks[key] = task
        inFlight.insert(key)

        defer {
            tasks.removeValue(forKey: key)
            inFlight.remove(key)
            BackgroundKeeper.shared.release(.transcription)
        }

        return try await task.value
    }

    /// The backoff-retry shell. **It wraps the pipeline only, not deduplication** — dedup has to be outside,
    /// otherwise the second retry round would hit its own already-registered task and return straight away.
    private func runWithRetry(
        fileURL: URL,
        locales: [String]?,
        enforceMinDuration: Bool,
        viaQueue: Bool
    ) async throws -> AsrResult {
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await runPipeline(
                    fileURL: fileURL,
                    locales: locales,
                    enforceMinDuration: enforceMinDuration
                )
            } catch {
                try Task.checkCancellation()
                // The queue path manages retries itself (it needs to survive launches and persist a count), so this
                // throws straight out; don't back off on both sides.
                guard !viaQueue,
                      attempt < Self.maxAttempts,
                      Self.isRetriable(error) else { throw error }
                log.warning("""
                    transcribe \(fileURL.lastPathComponent, privacy: .public) \
                    attempt \(attempt)/\(Self.maxAttempts) failed, retrying: \
                    \(String(describing: error), privacy: .public)
                    """)
                try await Task.sleep(for: Self.backoff(afterAttempt: attempt))
            }
        }
    }

    private func runPipeline(
        fileURL: URL,
        locales: [String]?,
        enforceMinDuration: Bool
    ) async throws -> AsrResult {
        let key = fileURL.lastPathComponent

        if enforceMinDuration {
            let minDuration = config.config.minTranscribeDuration
            if minDuration > 0,
               let duration = OpusOgg.duration(ofOggOpusAt: fileURL),
               duration < Double(minDuration) {
                log.info("skipping \(key, privacy: .public): duration=\(duration)s < min=\(minDuration)s")
                throw AsrError.tooShort(duration: duration, minimum: Double(minDuration))
            }
        }

        // Only include providers that actually have credentials configured.
        // Without this filter, an unconfigured Local provider would always
        // silently shadow the real Azure error (the chain falls through and
        // the last error wins — which is "Local server not configured").
        let chain = providerChain()
        guard !chain.isEmpty else { throw AsrError.noProviderConfigured }

        fallbackWarnings[key] = []

        // Run local VAD before the provider chain so we stop shipping
        // long stretches of silence. VAD returns nil when there's
        // nothing worth trimming (decode failed, no speech detected,
        // savings < 10 %) and the chain falls back to the original
        // file. The trimmed file lives in `tmp/` and is deleted after
        // the chain resolves one way or the other.
        var uploadURL = fileURL
        var tmpVAD: URL?
        var vadRanges: [VADReport.SpeechRange] = []
        if config.config.localVADEnabled {
            if let trimmed = await LocalVAD.processForUpload(source: fileURL) {
                uploadURL = trimmed.url
                tmpVAD = trimmed.url
                vadRanges = trimmed.ranges
            }
        }
        defer {
            if let tmpVAD { try? FileManager.default.removeItem(at: tmpVAD) }
        }

        // Re-encoded copy, from either the up-front conversion or the retry
        // path below. Cleaned up with the VAD temp file when the chain
        // resolves.
        var tmpTranscode: URL?
        defer {
            if let tmpTranscode { try? FileManager.default.removeItem(at: tmpTranscode) }
        }

        // Containers no provider in the chain can decode. CAF is the one QA
        // hit: AVFoundation reads it happily, Azure Fast Transcription does
        // not accept it at all, so it can only ever fail. Transcode before
        // the first attempt rather than burning a round-trip to learn that.
        if Self.alwaysTranscode.contains(uploadURL.pathExtension.lowercased()),
           let converted = await Self.transcodeForUpload(uploadURL) {
            tmpTranscode = converted
            uploadURL = converted
        }

        var lastError: Error?
        for (index, name) in chain.enumerated() {
            try Task.checkCancellation()
            do {
                var result: AsrResult
                do {
                    result = try await runProvider(name, fileURL: uploadURL, locales: locales)
                } catch {
                    // One rescue attempt per chain: when the provider
                    // rejected the *format* (as opposed to failing for
                    // credentials, quota or network reasons), re-encode to
                    // AAC/M4A — which every provider here accepts — and try
                    // the same provider again. This is what makes .opus
                    // variants Azure won't demux transcribe instead of
                    // dead-ending on 422 InvalidAudioFormat.
                    guard Self.isFormatRejection(error),
                          tmpTranscode == nil,
                          let converted = await Self.transcodeForUpload(uploadURL)
                    else { throw error }
                    log.info("provider \(name, privacy: .public) rejected the format; retrying as m4a")
                    tmpTranscode = converted
                    uploadURL = converted
                    result = try await runProvider(name, fileURL: uploadURL, locales: locales)
                }
                if !vadRanges.isEmpty {
                    // Provider timestamps are on the trimmed timeline;
                    // remap them back to the original clip so segment
                    // chips + future seek-to-time land where the user
                    // expects on the on-disk audio.
                    result = Self.remapTimestamps(result, ranges: vadRanges)
                }
                try writeArtefacts(result, audioName: key)
                // ★ "Summarize right after transcribing" (2026-10-18). The hook lives here rather than in every
                //   caller: manual, auto-after-download and the resumed queue all funnel through
                //   this line, so one call covers all three — and a summary can only be generated
                //   once the `.asr.json` is actually on disk, which is exactly this moment.
                onTranscribed?(key)
                return result
            } catch {
                // Any flavour of cancellation (CancellationError or
                // URLError.cancelled from URLSession) aborts the chain —
                // don't fall through to the next provider and re-spend ASR
                // credits on a run the user already stopped.
                if Task.isCancelled { throw CancellationError() }
                log.warning("provider \(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                lastError = error
                // If there is a next provider, record this failure so the UI
                // can surface it non-intrusively while the fallback runs.
                if index < chain.count - 1 {
                    fallbackWarnings[key, default: []].append(
                        "\(name): \(error.localizedDescription)"
                    )
                }
            }
        }
        throw lastError ?? AsrError.empty
    }

    // MARK: - format rescue

    /// Extensions that are worth transcoding before the first upload because
    /// no configured provider accepts them. Everything else goes up as-is and
    /// only gets converted if the provider actually complains — the device's
    /// own Ogg-Opus is accepted today and must not pay for a needless
    /// re-encode.
    private static let alwaysTranscode: Set<String> = ["caf"]

    /// True when the failure reads as "I can't decode this audio" rather than
    /// "I couldn't do the work". Azure answers 400/415/422 for unsupported or
    /// undecodable payloads; anything else (401, 429, 5xx, transport) must not
    /// trigger a re-encode.
    private static func isFormatRejection(_ error: Error) -> Bool {
        guard case let AsrError.http(status, _) = error else { return false }
        return status == 400 || status == 415 || status == 422
    }

    /// Re-encode to AAC in an M4A container. Returns nil when the platform
    /// can't read the source either — the caller then surfaces the provider's
    /// original error, which is more informative than a transcode failure.
    private static func transcodeForUpload(_ source: URL) async -> URL? {
        let stem = source.deletingPathExtension().lastPathComponent
        do {
            return try await AudioExporter.exportAsM4A(
                source: source,
                suggestedName: "asr-\(stem)-\(UUID().uuidString.prefix(8))"
            )
        } catch {
            log.warning("transcode for ASR failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - chain

    private func providerChain() -> [String] {
        let defaults = config.config.defaults.asr
        var chain = [defaults.primary]
        for fallback in defaults.fallbacks where fallback != defaults.primary {
            chain.append(fallback)
        }
        // On-device goes last, for the same reason as in `LiveModel.openASR`: a configured
        // service wins on quality, but the chain must never come back empty when the phone can
        // do the job itself. Without this line "On-device recognition" would be a switch that never runs.
        if config.config.onDeviceASREnabled, !chain.contains("ondevice") {
            chain.append("ondevice")
        }
        return chain.filter { !$0.isEmpty && hasCredentials($0) }
    }

    private func hasCredentials(_ name: String) -> Bool {
        switch name.lowercased() {
        case "azure":
            guard let a = config.config.asrProviders.azure else { return false }
            // If this credential set was verified on the settings page and rejected, don’t use it for transcription — that round would inevitably return 401, and the user would see an unexplained failure.
            // Unverified ones can proceed.
            return !a.key.isEmpty && !a.region.isEmpty && a.verification != false
        case "local":
            guard let l = config.config.asrProviders.local else { return false }
            return !l.host.isEmpty && l.port > 0
        case "ondevice":
            // No credentials to check — only the switch, plus the honest question of whether
            // this phone actually has an offline model for the language we'd ask it for.
            return config.config.onDeviceASREnabled
        case "custom":
            guard let c = config.config.asrProviders.custom else { return false }
            return !c.endpoint.isEmpty
        default:
            return false
        }
    }

    private func runProvider(_ name: String, fileURL: URL, locales: [String]?) async throws -> AsrResult {
        switch name.lowercased() {
        case "azure":
            guard let azure = config.config.asrProviders.azure,
                  !azure.key.isEmpty, !azure.region.isEmpty else {
                throw AsrError.missingCredentials("Azure")
            }
            // nil/empty → auto-detect (AzureASR omits the key from the
            // request). Non-empty → candidate set, Azure tags each phrase.
            let client = AzureASR(key: azure.key, region: azure.region, locales: locales)
            return try await client.transcribe(fileURL: fileURL)
        case "local":
            guard let local = config.config.asrProviders.local,
                  !local.host.isEmpty, local.port > 0 else {
                throw AsrError.missingCredentials("Local server")
            }
            let client = LocalASR(host: local.host, port: local.port)
            return try await client.transcribe(fileURL: fileURL)
        case "ondevice":
            // ★ Belt and braces: `hasCredentials` already filters this out when the switch is
            //   off, but a queued job can name a provider from an older config — reaching
            //   `Speech` after the user disabled it is exactly what used to crash on launch.
            guard config.config.onDeviceASREnabled else {
                throw AsrError.missingCredentials("On-device speech")
            }
            // ★ Offline, on the phone, no key. The locale has to be *named* — Apple has no
            // auto-detect — so an explicitly chosen source language wins, otherwise the UI
            // language is the best guess (a zh-Hans user recording Chinese needs no setup).
            let locale = locales?.first
                ?? config.config.lastSourceLang
                ?? (config.config.appLanguage ?? Locale.current.identifier)
            return try await OnDeviceASR.transcribeFile(url: fileURL, localeID: locale)
        case "custom":
            guard let custom = config.config.asrProviders.custom,
                  !custom.endpoint.isEmpty else {
                throw AsrError.missingCredentials("Custom server")
            }
            let client = CustomASR(
                endpoint: custom.endpoint,
                apiKey: custom.apiKey ?? "",
                model: custom.model ?? "",
                language: custom.language ?? ""
            )
            return try await client.transcribe(fileURL: fileURL, locales: locales)
        default:
            throw AsrError.missingCredentials(name)
        }
    }

    // MARK: - VAD timestamp remap

    /// Remaps every segment's `start`/`end` from the trimmed upload
    /// timeline to the original clip timeline, and recomputes
    /// `duration` as the post-remap span. Segments that straddle a
    /// silence gap will have a wider duration than the provider
    /// reported (the gap becomes part of the segment's wall-clock
    /// coverage), which is the right behavior for display and for
    /// tap-to-seek — landing just past the sentence's end on the
    /// original audio matches the chip.
    private static func remapTimestamps(
        _ result: AsrResult, ranges: [VADReport.SpeechRange]
    ) -> AsrResult {
        let mapped = result.segments.map { seg -> AsrSegment in
            let s = LocalVAD.remapToOriginal(seg.start, ranges: ranges)
            let e = LocalVAD.remapToOriginal(seg.end, ranges: ranges)
            return AsrSegment(
                speaker: seg.speaker,
                text: seg.text,
                start: s,
                end: e,
                duration: max(0, e - s)
            )
        }
        return AsrResult(
            text: result.text,
            segments: mapped,
            provider: result.provider,
            locale: result.locale
        )
    }

    // MARK: - artefacts

    private func writeArtefacts(_ result: AsrResult, audioName: String) throws {
        let urls = StorageLocations.transcriptURLs(for: audioName)
        try FileManager.default.createDirectory(
            at: StorageLocations.decryptedDir,
            withIntermediateDirectories: true
        )

        let body = formatTranscript(result)
        try body.data(using: .utf8)?.write(to: urls.txt, options: .atomic)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(result)
        try json.write(to: urls.json, options: .atomic)
        log.info("wrote transcript txt=\(urls.txt.lastPathComponent, privacy: .public) json=\(urls.json.lastPathComponent, privacy: .public)")
    }

    private func formatTranscript(_ result: AsrResult) -> String {
        if result.segments.isEmpty { return result.text }
        return result.segments.map { $0.formatted() }.joined(separator: "\n")
    }
}
