import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "asr")

/// Drives the `primary → fallbacks` chain from `config.defaults.asr` for one
/// audio file at a time. Writes `{name}.txt` + `{name}.asr.json` next to the
/// decrypted audio so the artefacts travel together.
///
/// 2026-10-15 起多三件事，都是为了"转录老是失败 / 切到后台就断"：
/// - **保活**：整段转录期间占住 `BackgroundKeeper`，切后台不挂起；
/// - **退避重试**：网络抖动、429、超时这类**临时**失败自动再试，
///   401/格式错这类**必然**失败不重试（重试只是白花额度）；
/// - **持久化队列**：自动转录进来的活落盘一份，App 被杀掉后
///   下次启动 / 回到前台接着跑。
@MainActor
final class TranscriptionService: ObservableObject {
    private let config: ConfigService

    /// Filenames currently being transcribed. Observed by views so they can
    /// render a spinner + hide the "Transcribe" button while an auto-path
    /// transcription is running in the background (otherwise the user lands
    /// on Clip detail right after a download and sees the manual button even
    /// though the pipeline is already doing the work).
    @Published private(set) var inFlight: Set<String> = []

    /// 排着队 / 失败等着重试的活（跟 `inFlight` 不是一个概念：那个是"此刻
    /// 正在跑"，这个是"还没干完"）。持久化，所以跨启动还在。
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

    /// 队列的串行泵，防止两次 `resumePending()` 同时开跑把同一条活跑两遍。
    private var drainTask: Task<Void, Never>?

    init(config: ConfigService) {
        self.config = config
        self.pending = Self.loadQueue()
        // ★ 载入时就把"音频已经不在了"的条目剔掉。
        //
        // 光靠 `runDrainLoop` 里那道 `fileExists` 不够：试满 `maxAttempts`
        // 的条目会被 `resumePending` 的 gate 挡在门外，drain 根本不跑，
        // 于是"用户删掉了那条录音、但队列里还留着它的失败记录"会永久挂在
        // 设置页那一行上，怎么点都消不掉。
        //
        // 只在启动做一次（每条一次 `fileExists`，量级是几十），不在
        // `forget` 之外的热路径上加。
        let before = pending.count
        pending.removeAll { job in
            let url = StorageLocations.decryptedDir.appendingPathComponent(job.name)
            return !FileManager.default.fileExists(atPath: url.path)
        }
        if pending.count != before {
            log.info("queue: pruned \(before - self.pending.count) orphaned job(s) on load")
            saveQueue()
        }
        // 把开关镜像到 keeper。keeper 是个单例、config 不是，所以每次
        // config 落盘都刷新一次（`syncBackgroundKeeper`）。
        syncBackgroundKeeper()
    }

    // MARK: - 保活开关

    /// 把 `config.backgroundKeepAliveEnabled` 镜像给 `BackgroundKeeper`。
    /// 设置页改完开关调它；`init` 也调一次，好让"上次就关着"的状态
    /// 在冷启动时立刻生效（否则第一条录音会白占用几秒会话）。
    func syncBackgroundKeeper() {
        BackgroundKeeper.shared.audioKeepAliveEnabled = config.config.backgroundKeepAliveEnabled
    }

    // MARK: - 队列（持久化）

    /// 一条还没干完的活。
    struct PendingJob: Codable, Identifiable, Equatable {
        /// 音频文件名 —— 与 `inFlight` / `fallbackWarnings` 同一个键空间。
        var name: String
        var locales: [String]?
        var enforceMinDuration: Bool
        /// 已经试过几轮（含正在跑的那一轮）。
        var attempts: Int
        /// 最后一轮失败的原因，给界面显示。
        var lastError: String?
        var enqueuedAt: Date
        var id: String { name }
    }

    /// 一次转录最多试几轮：1 次首发 + 2 次重试。
    /// 再多就没意义了 —— 本机 Ollama 那种几分钟一轮的，试 5 次用户会以为卡死。
    static let maxAttempts = 3

    /// 第 `attempt` 轮失败后的等待。指数退避（2/8/30 秒），**不封顶到分钟级**
    /// 是因为用户多半就在看着这个菊花；等太久还不如早点报错让人重按。
    private static func backoff(afterAttempt attempt: Int) -> Duration {
        switch attempt {
        case 1: return .seconds(2)
        case 2: return .seconds(8)
        default: return .seconds(30)
        }
    }

    /// 取消的两种表现：Swift 并发的 `CancellationError`，以及 URLSession
    /// 被取消时抛的 `URLError.cancelled`。**必须都认** —— 只认前者的话，
    /// 用户按"取消"之后那条活还会被当成"临时失败"重试两次。
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// 这个错误值不值得再试一轮。
    ///
    /// 判定口径是"**再试一次有没有可能不一样**"，不是"错误严不严重"：
    /// - 取消 → 不试（用户不想跑了）；
    /// - 没配对 provider / 缺密钥 / 没配端点 → 不试（配置不会自己变）；
    /// - 时长不够 → 不试（文件不会自己变长）；
    /// - 剩下的（HTTP、transport、decoding、empty）→ 都试。429 要退避、
    ///   5xx 是服务端抖、超时是网络抖、decoding/empty 偶尔是半截响应。
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

    /// 把一条活排进队列（自动转录那几条路走这里）。
    ///
    /// 与直接 `transcribe(...)` 的区别：**先落盘再开跑**。区别只在
    /// "App 中途被杀"这一种情况下才看得出来 —— 那种情况下直接跑的那条
    /// 活就凭空消失了，用户第二天回来只看到一条没转录的录音，也不会知道
    /// 曾经试过。
    func enqueue(fileURL: URL, locales: [String]? = nil, enforceMinDuration: Bool = false) {
        let key = fileURL.lastPathComponent
        if let idx = pending.firstIndex(where: { $0.name == key }) {
            // 已经在队列里：不重复加，但把重试计数**清零**（用户又主动
            // 要了一次，说明上一次的放弃不算数）。
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

    /// 排进队列并**等它出队**（成功、试满放弃、或音频已不在）。
    ///
    /// 给"要等结果再刷新界面"的调用方用 —— 目前只有手表到货那条：它原本
    /// `await transcribe` 完再发 `libraryDidChange`，好让资料库列表立刻
    /// 带出转录文本。注意等的是"**这条活出队**"，不是"某一次 `transcribe`
    /// 返回"：重试期间它一直挂在队列上。
    func enqueueAndWait(fileURL: URL, locales: [String]? = nil, enforceMinDuration: Bool = false) async {
        enqueue(fileURL: fileURL, locales: locales, enforceMinDuration: enforceMinDuration)
        // 同一个 main actor 上同步赋值 / 同步读取，不存在"还没起来"的窗口。
        await drainTask?.value
    }

    /// 从队列里拿掉一条（用户手动删了那条录音、或转录成了）。
    func forget(name: String) {
        guard pending.contains(where: { $0.name == name }) else { return }
        pending.removeAll { $0.name == name }
        saveQueue()
    }

    /// 重启那些还没干完的活。挂两个点：**App 启动**（`NomilyApp.init`）和
    /// **回到前台**（`RootView` 的 scenePhase 变 .active）。
    ///
    /// 有这个才能叫"后台转录" —— 光靠 `BackgroundKeeper` 只顶得住"切走一会儿"，
    /// 顶不住"系统在内存紧张时把进程咔嚓掉"。那种情况下唯一能救回来的办法
    /// 就是下次启动时照着这份清单重来。
    func resumePending() {
        guard pending.contains(where: { $0.attempts < Self.maxAttempts }) else { return }
        startDrainIfNeeded()
    }

    /// 队列的串行泵。`@MainActor` 上同步赋值 ⇒ 紧跟其后的 `drainTask?.value`
    /// 一定能看到它，没有"任务还没起步"的竞态。
    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDrainLoop()
            self.drainTask = nil
        }
    }

    /// 串行地把队列里的活跑一遍。同一时间只跑一条：ASR 侧本来就有额度，
    /// 并发提交只会让本机那张单卡的队列排得更长。
    private func runDrainLoop() async {
        // 用 `first(where:)` 而不是 `first`：试满 `maxAttempts` 的活会**留在
        // 队列里**（界面要能说"这条一直没成功"），但不能再被挑出来跑 ——
        // 用 `first` 的话它会永远排在队首，每次启动都白试一轮。
        while let job = pending.first(where: { $0.attempts < Self.maxAttempts }) {
            let url = StorageLocations.decryptedDir.appendingPathComponent(job.name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                // 音频已经不在了（用户删了录音，或还没下载下来）——
                // 留着它只会每次启动都白试一轮。
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
                // 用户主动取消：不当失败，也不再自动重来。
                forget(name: job.name)
            } catch {
                guard let idx = pending.firstIndex(where: { $0.name == job.name }) else { continue }
                pending[idx].attempts += 1
                pending[idx].lastError = error.localizedDescription
                let attempts = pending[idx].attempts
                saveQueue()
                if attempts >= Self.maxAttempts {
                    log.warning("queue: \(job.name, privacy: .public) gave up after \(attempts) attempts")
                    // 试到头了。留档不删 —— 让界面能显示"这条一直没成功"，
                    // 而不是让用户以为从没试过。用户手动再按一次转录
                    // （`enqueue`）会把计数清零，重新获得 3 次机会。
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

    /// 重试队列里的一条（用户从后台任务页 / 详情页点的）。
    ///
    /// ★ 2026-10-16 十二改新增。存在的理由是**别让调用方自己拼路径**：
    /// `enqueue` 是按 `fileURL.lastPathComponent` 认人的，调用方就得知道
    /// "音频在 `decryptedDir` 里、活的名字就是文件名"这套约定 —— 那是这个类的
    /// 内部知识，散到界面上去迟早会有一处拼错（比如用了 `root` 而不是
    /// `decryptedDir`，然后表现为"点了重试没反应"）。
    ///
    /// 走 `enqueue` 而不是另开一条路：`enqueue` 对**已存在**的条目只清
    /// `attempts` 与 `lastError`，不动 `locales` / `enforceMinDuration` ——
    /// 也就是说"重试"重试的是**原来那条活**，包括用户当初指定的识别语言。
    /// 这正是 `JobQueue.retry(id:)` 的语义，两边保持一致。
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
    /// `viaQueue` 是给队列自己用的内部开关，外部别传：它决定失败时要不要
    /// 退回队列等下一次，以及要不要按退避节奏多试几轮。
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

        // ★ 保活从这个瞬间开始，一直占到这条活出去为止。
        //
        // 位置很讲究：必须在 `Task` **外面**占。放进去的话，`Task` 是异步
        // 起步的，从"用户点转录"到"任务真正开跑"之间有个窗口，用户正好
        // 在这个窗口切走就没人顶着进程了 —— 而那恰恰是最容易切走的时刻。
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

    /// 退避重试外壳。**只包管线，不包去重** —— 去重必须在外面，
    /// 否则第二轮重试会撞上自己那条已经登记好的 task 而直接返回。
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
                // 队列那条路自己管重试（它要跨启动、要落盘计数），这里
                // 直接抛出，别两边各退避一次。
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
