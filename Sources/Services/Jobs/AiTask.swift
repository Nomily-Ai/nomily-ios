import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "ai-task")

/// The stage machine of one "transcribe + summarize" pipeline (任务三).
///
/// Stages: `queued → transcribing → summarizing → done`, failure ends in
/// `failed` carrying **which stage** died. `uploading` of Plaud's model has
/// no Nomily counterpart — transcription here is a local file, nothing is
/// uploaded first — so it is deliberately absent rather than modelled as a
/// stage that never runs.
enum AiTaskStage: String, Codable, Equatable {
    case queued
    case transcribing
    case summarizing
    case done
    case failed

    var isActive: Bool { self == .queued || self == .transcribing || self == .summarizing }
}

/// One persisted AI pipeline task.
///
/// ## Why a flat struct (same trade as `Job`)
/// Every field goes straight into JSON; a Codable-enum-with-associated-values
/// would triple the file for no consumer benefit — the only reader is
/// `AiTaskCenter` and the (optional) task-center row.
///
/// ## Field mapping vs the task book
/// * `fileId` → `clipName` (Nomily works on local files; there is no upload id).
/// * 错误域 → `failedStage` + `lastError` (transcribe / summarize kept apart so
///   "transcribe failed" and "summary failed" never blur into one retry count).
/// * 重试计数 → `transcribeAttempts` / `summarizeAttempts`, independent.
struct AiTask: Codable, Identifiable, Equatable {
    /// Stable id: one pipeline per recording ("aitask:<clip>").
    var id: String { "aitask:\(clipName)" }
    let clipName: String
    var stage: AiTaskStage
    var transcribeAttempts: Int = 0
    var summarizeAttempts: Int = 0
    /// Which stage produced `lastError` ("transcribing" / "summarizing").
    var failedStage: String?
    var lastError: String?
    var createdAt: Date
    var updatedAt: Date
    var finishedAt: Date?
    /// Earliest time a retry may re-enter the pipeline (cooldown gate).
    var cooldownUntil: Date?

    static func make(clipName: String) -> AiTask {
        let now = Date()
        return AiTask(clipName: clipName, stage: .queued,
                      createdAt: now, updatedAt: now)
    }
}

/// The retry cooldown gate (任务三): exponential backoff, capped at 30 min.
///
/// Plaud's `retry_cooldown_gate` exists to stop a poisoned pipeline from
/// hot-looping against a failing cloud service. Nomily's transcription
/// already has its own 3-attempt queue, so this gate governs **whole-pipeline
/// re-entry** — auto-flow retriggering or the user tapping retry again.
enum RetryCooldownGate {
    /// 1 → 60 s, 2 → 120 s, 3 → 240 s … capped at 30 min.
    static func cooldown(afterAttempt attempt: Int) -> TimeInterval {
        let base: TimeInterval = 60
        let capped = min(attempt, 5)
        return min(base * pow(2, Double(max(0, capped - 1))), 30 * 60)
    }

    static func isBlocked(_ task: AiTask, now: Date = Date()) -> Bool {
        guard let until = task.cooldownUntil else { return false }
        return now < until
    }
}

/// The unified ledger + orchestrator for "transcribe → summarize" pipelines
/// (任务三, ★ 2026-10-22).
///
/// ## Where it sits (deliberate layering)
/// `JobQueue`'s header already rules: **what's shared is the task-overview
/// layer, not the scheduling layer** — transcription keeps
/// `TranscriptionService` (persisted queue, dedupe, ASR-specific retries) and
/// summary/translation keep `JobQueue`. Ripping those apart would lose
/// battle-tested semantics. So `AiTaskCenter` is the **orchestration +
/// observability ledger** above them:
///
/// * every pipeline gets one `AiTask` row whose stage advances with the real
///   queues (`onTranscribed` → summarizing; `JobQueue.wait` → done);
/// * re-entry is gated by `RetryCooldownGate`;
/// * the ledger is persisted (`ai-tasks.json`) and **recovered at launch**:
///   a task interrupted by a process kill is reconciled against what the
///   underlying queues actually produced.
///
/// ## Honest boundaries
/// Transcription **failures** are not signalled by `TranscriptionService`
/// today (it has only `onTranscribed`); a task whose transcription never
/// lands is therefore resolved at launch-recovery / by the next reconcile,
/// not the moment the recogniser errors. The underlying queue's own row in
/// the task center stays the source of truth for the failure text.
@MainActor
final class AiTaskCenter: ObservableObject {

    static let shared = AiTaskCenter()

    @Published private(set) var tasks: [AiTask] = []

    /// Newest first for display.
    var activeTasks: [AiTask] { tasks.filter(\.stage.isActive) }
    var finishedTasks: [AiTask] { tasks.filter { !$0.stage.isActive } }

    private init() {
        tasks = Self.load()
    }

    // MARK: - Pipeline entry points

    /// A transcription was queued for this clip (import / recording finish /
    /// manual). Creates or resets the ledger row.
    func transcribeQueued(clipName: String) {
        upsert(clipName: clipName) { task in
            var t = task
            if t.stage == .done || t.stage == .failed {
                t = AiTask.make(clipName: clipName)
            }
            t.stage = .transcribing
            t.failedStage = nil
            t.lastError = nil
            t.finishedAt = nil
            t.cooldownUntil = nil
            t.updatedAt = Date()
            return t
        }
    }

    /// Transcription landed. Advances the stage; when the summary half is
    /// actually going to run (the auto-summary conditions held), waits for
    /// that job's dequeue to finish the pipeline.
    func transcribeDidFinish(clipName: String) {
        guard let idx = index(of: clipName), tasks[idx].stage == .transcribing else { return }
        Telemetry.success("ai_task_transcribe", ["clip": clipName])
        guard let env = AppEnvironment.shared else {
            finish(idx: idx, stage: .done)
            return
        }
        // The auto-summary hook runs first (it owns all the guards: switch,
        // LLM configured, template, no-overwrite). Whether a summarize job
        // actually exists afterwards decides the pipeline's next stage.
        env.maybeAutoSummarize(clipName: clipName)
        if let job = env.jobs.job(id: "summarize:\(clipName)"), job.finishedAt == nil {
            tasks[idx].stage = .summarizing
            tasks[idx].updatedAt = Date()
            save()
            Task { @MainActor [weak self] in
                _ = await env.jobs.wait(for: "summarize:\(clipName)")
                self?.summaryDequeued(clipName: clipName)
            }
        } else {
            // No summary in flight — the pipeline is done after transcription.
            finish(idx: idx, stage: .done)
        }
    }

    /// Transcription side reported a failure (manual call sites that know).
    func transcribeFailed(clipName: String, error: String) {
        guard let idx = index(of: clipName) else { return }
        tasks[idx].transcribeAttempts += 1
        tasks[idx].failedStage = "transcribing"
        tasks[idx].lastError = error
        tasks[idx].cooldownUntil = Date().addingTimeInterval(
            RetryCooldownGate.cooldown(afterAttempt: tasks[idx].transcribeAttempts))
        tasks[idx].updatedAt = Date()
        save()
        Telemetry.failed("ai_task_transcribe", reason: error, ["clip": clipName])
    }

    private func summaryDequeued(clipName: String) {
        guard let idx = index(of: clipName), tasks[idx].stage == .summarizing else { return }
        guard let job = AppEnvironment.shared?.jobs.job(id: "summarize:\(clipName)") else {
            finish(idx: idx, stage: .done)
            return
        }
        if job.lastError == nil {
            finish(idx: idx, stage: .done)
            Telemetry.success("ai_task_summarize", ["clip": clipName])
        } else {
            tasks[idx].summarizeAttempts += 1
            tasks[idx].failedStage = "summarizing"
            tasks[idx].lastError = job.lastError
            tasks[idx].stage = .failed
            tasks[idx].cooldownUntil = Date().addingTimeInterval(
                RetryCooldownGate.cooldown(afterAttempt: tasks[idx].summarizeAttempts))
            tasks[idx].finishedAt = Date()
            tasks[idx].updatedAt = Date()
            save()
            Telemetry.failed("ai_task_summarize", reason: job.lastError ?? "unknown",
                             ["clip": clipName])
        }
    }

    // MARK: - Retry / recovery

    /// User- or auto-flow-triggered re-entry. Returns false while the
    /// cooldown gate is shut (`cooldownUntil` in the future).
    @discardableResult
    func retry(clipName: String, run: @escaping @MainActor () async -> Void) -> Bool {
        guard let idx = index(of: clipName) else { return false }
        guard !RetryCooldownGate.isBlocked(tasks[idx]) else { return false }
        tasks[idx].transcribeAttempts = 0
        tasks[idx].summarizeAttempts = 0
        tasks[idx].failedStage = nil
        tasks[idx].lastError = nil
        tasks[idx].finishedAt = nil
        tasks[idx].cooldownUntil = nil
        tasks[idx].stage = .queued
        tasks[idx].updatedAt = Date()
        save()
        Telemetry.event("ai_task_retry", ["clip": clipName])
        Task { @MainActor in await run() }
        return true
    }

    /// Launch recovery: reconcile rows against what actually survived.
    ///
    /// Called from `AppEnvironment.init` after `transcription.resumePending()`
    /// and `jobs.resume()` — at that point every persisted queue has been
    /// replayed, so "the artefact exists / the job is still queued" is a
    /// reliable verdict on where an interrupted pipeline really is.
    func recoverAtLaunch() {
        for idx in tasks.indices where tasks[idx].stage.isActive {
            let clip = tasks[idx].clipName
            let transcriptExists = FileManager.default.fileExists(
                atPath: StorageLocations.transcriptURLs(for: clip).txt.path)
            let summaryExists = FileManager.default.fileExists(
                atPath: StorageLocations.summaryURL(for: clip).path)
            let env = AppEnvironment.shared

            switch tasks[idx].stage {
            case .transcribing:
                if transcriptExists {
                    // The recogniser finished in a previous process; the
                    // onTranscribed callback was lost with it. Advance now.
                    transcribeDidFinish(clipName: clip)
                } else if env?.transcription.hasPending(clipName: clip) == true {
                    continue // the queue replay will run it; stage stays honest
                } else {
                    markInterrupted(idx: idx, stage: "transcribing")
                }
            case .summarizing:
                if summaryExists {
                    finish(idx: idx, stage: .done)
                } else if let job = env?.jobs.job(id: "summarize:\(clip)"),
                          job.finishedAt == nil {
                    continue // resumed job will finish it
                } else {
                    markInterrupted(idx: idx, stage: "summarizing")
                }
            default:
                break
            }
        }
    }

    private func markInterrupted(idx: Int, stage: String) {
        tasks[idx].failedStage = stage
        tasks[idx].lastError = L10n.Jobs.interrupted
        tasks[idx].stage = .failed
        tasks[idx].finishedAt = Date()
        tasks[idx].updatedAt = Date()
        save()
        let name = tasks[idx].clipName
        log.info("ai task \(name, privacy: .public) interrupted at \(stage, privacy: .public)")
    }

    // MARK: - Ledger plumbing

    private func finish(idx: Int, stage: AiTaskStage) {
        tasks[idx].stage = stage
        tasks[idx].finishedAt = Date()
        tasks[idx].updatedAt = Date()
        save()
    }

    private func index(of clipName: String) -> Int? {
        tasks.firstIndex { $0.clipName == clipName }
    }

    private func upsert(clipName: String, transform: (AiTask) -> AiTask) {
        if let idx = index(of: clipName) {
            tasks[idx] = transform(tasks[idx])
        } else {
            tasks.insert(transform(AiTask.make(clipName: clipName)), at: 0)
        }
        save()
    }

    // MARK: - Disk

    private static var storeURL: URL {
        StorageLocations.root.appendingPathComponent("ai-tasks.json")
    }

    private static func load() -> [AiTask] {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([AiTask].self, from: data) else {
            return []
        }
        // Keep the ledger from growing forever: done/failed older than 7 days drop.
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        return decoded.filter { task in
            task.stage.isActive || (task.finishedAt ?? task.updatedAt) > cutoff
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tasks) else { return }
        try? FileManager.default.createDirectory(at: StorageLocations.root,
                                                 withIntermediateDirectories: true)
        try? data.write(to: Self.storeURL, options: .atomic)
    }
}
