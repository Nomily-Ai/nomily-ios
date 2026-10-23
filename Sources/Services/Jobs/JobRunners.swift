import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "jobs")

// MARK: - Building jobs (the single source of id)
//
// ⚠️ `id` is always generated here; callers **must not** assemble the string themselves. Reason: `id` is at once
//    the idempotency key (enqueueing the same job again doesn't stack), the row identity in the UI, and the query key for "are this recording's jobs done"
//    — assemble it in three places and sooner or later one will drop a field (say translation forgetting the target
//    language), so that "translate the same recording again into another language" gets mistaken for re-enqueueing the same job.
extension Job {

    /// Summary: one job per **note page**. The primary page (`pageID ==
    /// NotePage.primaryID`, the default) keeps the historical id `summarize:<clip>`
    /// so AiTask's "wait for the summary job" and the auto-summary dedup keep
    /// working; an extra page appends `#<pageID>` — pages run **independently**,
    /// generating one must not cancel another.
    ///
    /// ★ 2026-10-23 ("页面模板", Plaud parity).
    static func summarize(clip: String, prompt: String, templateName: String,
                          pageID: String = NotePage.primaryID) -> Job {
        let suffix = pageID == NotePage.primaryID ? "" : "#\(pageID)"
        return Job(
            id: "summarize:\(clip)\(suffix)",
            kind: .summarize,
            clipName: clip,
            enqueuedAt: Date(),
            prompt: prompt,
            templateName: templateName,
            pageID: pageID
        )
    }

    /// Translation. `target` is `"transcript"` / `"summary"` — the two are **two independent jobs**
    /// (the user may have translated only the summary, not the full text), so both the target language and the target object go into `id`.
    static func translate(clip: String, target: String, languageName: String) -> Job {
        Job(
            id: "translate:\(target):\(clip)",
            kind: .translate,
            clipName: clip,
            enqueuedAt: Date(),
            languageName: languageName,
            translateTarget: target
        )
    }

    /// Format conversion / export. **Only the last-picked format is kept per recording at a time** — the user taps
    /// m4a then wav, and what they want is wav; running both would only make it a lottery which one ends up
    /// sitting in `ExportCenter` (which keeps only one).
    static func export(clip: String, format: AudioExportFormat) -> Job {
        Job(
            id: "export:\(clip)",
            kind: .export,
            clipName: clip,
            enqueuedAt: Date(),
            exportFormat: format.rawValue
        )
    }

    /// ★ 2026-10-22 (任务二): document export (`txt` / `md` / `pdf`). Same job id
    /// as the audio export — the two share one slot per recording on purpose.
    static func export(clip: String, format: String) -> Job {
        Job(
            id: "export:\(clip)",
            kind: .export,
            clipName: clip,
            enqueuedAt: Date(),
            exportFormat: format
        )
    }
}

// MARK: - The three runners
//
// Registered into `JobQueue` by `AppEnvironment`. Kept here rather than written into the composition root:
// each runner has twenty or thirty lines of "read source file → call service → persist the artifact", and cramming that into `init` would leave that
// file with nothing but timing bookkeeping and a closure you can't find the end of.
//
// ## The shared shape
// Each runner does three things: **① take a `BackgroundKeeper` token itself → ② read the source file,
// throwing `JobSourceMissing` if it's absent → ③ do the work and persist the artifact**.
//
// ⚠️ The token is taken by the runner itself; `JobQueue` doesn't touch it. That way all four job kinds (including the transcription one that isn't in the queue)
//    use `BackgroundKeeper` identically — the queue only handles "when to run",
//    and "don't get suspended by the system while running" is each runner's own business.
enum JobRunners {

    /// Summary. This used to live in `SummarizeSheet.runSummarize` (an in-memory `Task`),
    /// moved here in revision twelve for the sole purpose of letting it be picked up and resumed after the App is killed.
    ///
    /// ⚠️ Chunk progress and the "result note" (used the fallback channel / was chunked) **must be reported back to the queue**,
    ///    not left only in the view: this job most likely finished while the user wasn't looking.
    @MainActor
    static func summarize(
        _ job: Job, config: AppConfig, reporter: JobQueue.Reporter
    ) async throws {
        guard let prompt = job.prompt else { throw JobSourceMissing(what: L10n.Jobs.sourcePrompt) }
        let source = try transcriptText(for: job.clipName)
        // ★ 2026-10-22 ("转写只有简短一句话的话使用模板，模板文字比一句话还多"):
        // a meeting-minutes skeleton on a one-sentence voice note produces more
        // headings than content — the same failure Plaud and Vobot both avoid by
        // **not applying the full template** to a tiny source. The gate lives
        // here (the runner), not in the sheet, so the queue re-runs after an app
        // kill take exactly the same path.
        let adapted = Self.adaptedPrompt(templatePrompt: prompt, source: source)
        let effectivePrompt = adapted.text

        BackgroundKeeper.shared.acquire(.summary)
        defer { BackgroundKeeper.shared.release(.summary) }

        // ★ 2026-10-22 ("有转写但摘要生不出来"): the LLM error used to exist only
        // as the job's `lastError`, which nobody sees unless the task center is
        // open. Log the provider chain + the concrete gap into the diag file so
        // "Open Router is set up but it won't run" can be answered from one pull.
        let gap = config.llmProviders.primary.map {
            LLMCompletionService.configGap($0, config) ?? "none"
        } ?? "no-primary"
        TicNoteDiagLog.log("LLM", "summarize start clip=\(job.clipName) primary=\(config.llmProviders.primary ?? "-") gap=\(gap) chars=\(source.count)")
        let outcome: LLMCompletionService.Outcome
        do {
            outcome = try await LLMCompletionService.completeResilient(
                systemPrompt: effectivePrompt,
                userContent: source,
                config: config,
                // ★ Reuse finished chunk sections **only on a retry**. On a first
                // run there is nothing cached anyway, and on a deliberate
                // "generate again" the user expects new text — resurrecting the
                // old sections would make the button look like it did nothing.
                allowSectionReuse: job.attempts > 0,
                onChunk: { done, total in reporter.progress(done, total) }
            )
        } catch {
            TicNoteDiagLog.log("LLM", "summarize FAILED clip=\(job.clipName) primary=\(config.llmProviders.primary ?? "-") gap=\(gap) error=\(error.localizedDescription)")
            throw error
        }
        // ★ 2026-10-23 ("为啥会到模型输出上限，这个需要优化"): the cap is 4096
        //   output tokens, and a long structured report (interview BANT, formal
        //   minutes) genuinely exceeds it. Shipping the part that fit plus a
        //   warning was the old behaviour; now the run **continues** the same
        //   document from where it stopped, up to two rounds, and only reports
        //   truncation if that also fails.
        var completion = outcome.completion
        if completion.truncated, !completion.text.isEmpty {
            completion = await extend(
                completion: completion,
                providerKey: outcome.providerKey,
                config: config
            )
        }
        TicNoteDiagLog.log(
            "LLM",
            "summarize ok clip=\(job.clipName) provider=\(outcome.providerKey) chars=\(completion.text.count) truncated=\(completion.truncated)"
        )
        try Task.checkCancellation()

        // ⚠️ The summary and the title are **persisted together**, without waiting for the user to tap save.
        //
        // This is an inevitable consequence of revision twelve: a job's artifact must land on its own, otherwise "come back after it finishes
        // and look at the result" has no result to look at (the old mode was "the result is held in the sheet's memory,
        // and only written when the user taps save" — that mode leaves nothing behind in the face of "App killed").
        // It also fixes an old flaw: summary-to-disk and title-to-disk used to be two steps, and cancelling mid-way would leave
        // a "renamed but no summary" state; now both steps are in the same synchronous block, so it's all or
        // nothing.
        // ★ 2026-10-23: strip what the prompt could only discourage — fields whose
        //   value is a placeholder, sections left with nothing, items repeated
        //   under two headings. Mechanical, so the result is predictable; see
        //   `SummaryPolish`. The title is extracted from the **cleaned** text so
        //   it can never be named after a placeholder line.
        let text = SummaryPolish.clean(completion.text)
        // ★ 2026-10-23 ("页面模板"): the artifact lands on **its own page**. The
        //   primary page still is `<base>.summary.md` (nothing pre-existing moves);
        //   extra pages get `<base>.note.<id>.md` plus a manifest entry. The
        //   manifest upsert happens here, not in the sheet — a job can finish after
        //   the app was killed, and the page must then appear without any UI open.
        let pageID = job.pageID ?? NotePage.primaryID
        try? text.data(using: .utf8)?
            .write(to: StorageLocations.notePageURL(for: job.clipName, pageID: pageID), options: .atomic)
        NotePages.upsert(id: pageID,
                         title: job.templateName ?? L10n.ClipDetail.noteDefaultTitle,
                         for: job.clipName)

        // The recording's display title is derived from the **primary** page only —
        // an extra page (say, "逐字稿") must not rename the recording in the list.
        if pageID == NotePage.primaryID, let title = await extractTitle(
            from: text,
            config: config,
            // ★ Directly target the channel that actually did the work. Without specifying it, the primary channel has already proven
            //   unusable, and this step would **wait for it to time out once more** before the fallback gets its turn —
            //   that timeout is 120 seconds in the cloud, 600 seconds for local Ollama.
            preferred: outcome.providerKey
        ) {
            try? title.data(using: .utf8)?
                .write(to: StorageLocations.titleURL(for: job.clipName), options: .atomic)
        }

        // ★ 2026-10-23 ("watch 那边能否靠 Siri Recap 的看齐"): Apple's Siri Recap
        //   on the wrist is opt-in, beta, and not offered in China — so Nomily
        //   ships its own. Every finished summary extracts a tiny digest (the
        //   first heading + up to three list lines) and pushes it to the watch,
        //   which keeps the last 7 days and shows them from a home-menu page.
        //   Only the primary page pushes: an extra template page ("逐字稿")
        //   regenerating would otherwise spam the wrist with duplicates of the
        //   same recording.
        if pageID == NotePage.primaryID {
            let digest = Self.recapDigest(
                from: text,
                fallbackTitle: RecordingName.displayTitle(for: job.clipName)
            )
            if !digest.points.isEmpty {
                AppEnvironment.shared?.watch.pushRecap(
                    clipName: job.clipName,
                    title: digest.title,
                    points: digest.points,
                    // Recorded time parsed from the `yyyyMMddHHmmss` name, so
                    // the watch can say "this morning's meeting"; a name that
                    // doesn't parse falls back to now.
                    recordedAt: RecordingName.date(from: job.clipName) ?? Date()
                )
            }
        }

        // The note goes last: it's part of the **result**, and any earlier step throwing shouldn't leave behind
        // the illusion of "it finished and everything was fine".
        var notes = notices(for: outcome, config: config)
        if adapted.replacedTemplate {
            notes.append(L10n.Summarize.shortSourceNote)
        }
        reporter.notes(notes, completion.truncated)
        log.info("summary done for \(job.clipName, privacy: .public) via \(outcome.providerKey, privacy: .public)")
    }

    // MARK: - Watch recap digest (★ 2026-10-23, "watch 那边能否靠 Siri Recap 的看齐")

    /// Maximum characters of one recap point — a watch row fits roughly one
    /// line of 40 mm screen, and anything past this gets truncated with "…".
    private static let recapPointLimit = 60

    /// Mechanical extraction of a Siri-Recap-style digest from the finished
    /// summary. **No second LLM call** on purpose: the recap must be free
    /// (another round trip would double the cost of every summary) and cannot
    /// fail — a plain markdown walk always yields something.
    ///
    /// * title — the first markdown heading, markers stripped; falls back to
    ///   the clip's display title.
    /// * points — the first three markdown list items (bullets or numbers),
    ///   bold markers stripped, each capped at `recapPointLimit`. Skips the
    ///   placeholder-looking lines (`SummaryPolish` already removed most).
    static func recapDigest(from text: String, fallbackTitle: String) -> (title: String, points: [String]) {
        func strip(_ line: String) -> String {
            line
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "#*-• "))
        }
        var title: String?
        var points: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if title == nil, line.hasPrefix("#") {
                let cleaned = strip(line)
                if !cleaned.isEmpty { title = cleaned }
                continue
            }
            let isList = line.hasPrefix("- ") || line.hasPrefix("* ")
                || line.hasPrefix("• ") || line.first?.isNumber == true
            guard isList else { continue }
            let cleaned = strip(line)
            guard cleaned.count >= 4 else { continue } // "- xx" style debris
            if cleaned.count > recapPointLimit {
                points.append(String(cleaned.prefix(recapPointLimit - 1)) + "…")
            } else {
                points.append(cleaned)
            }
            if points.count == 3 { break }
        }
        return (title ?? fallbackTitle, points)
    }

    // MARK: - Continuing a truncated document

    /// Ask the same channel to **keep writing** where the cap cut it off.
    ///
    /// Why continuation rather than a bigger `max_tokens`: the cap is not ours
    /// alone — every model has its own ceiling, and several sit at 4096 exactly.
    /// Raising ours past a model's limit turns a truncation into an API error.
    /// Continuing works against any ceiling, and it degrades honestly: if two
    /// rounds still end truncated, the caller reports truncation as before.
    ///
    /// The channel is pinned to the one that produced the text: the primary may
    /// be the one that failed, and retrying it first costs a full timeout.
    private static func extend(
        completion: LLMCompletionService.Completion,
        providerKey: String,
        config: AppConfig,
        maxRounds: Int = 2
    ) async -> LLMCompletionService.Completion {
        var text = completion.text
        var truncated = completion.truncated

        var pinned = config
        pinned.llmProviders.primary = providerKey

        let instruction = NSLocalizedString("summarize.continue_prompt", value: """
        You are continuing a document that was cut off by an output limit. Continue from the \
        exact point where it stops — same language, same heading level, same list style. \
        Do not repeat anything already written, do not restate the heading above the cut, \
        do not add a preface, and do not summarise what came before. \
        If the document is in fact already complete, reply with exactly: DONE
        """, comment: "System prompt used to continue a summary that hit the output cap")

        for _ in 0..<maxRounds where truncated {
            try? Task.checkCancellation()
            let tail = String(text.suffix(1_500))
            guard let next = try? await LLMCompletionService.completeResilient(
                systemPrompt: instruction,
                userContent: "DOCUMENT SO FAR (ends at the cut):\n\(tail)",
                config: pinned,
                allowChunking: false
            ) else { break }

            let addition = next.completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if addition.isEmpty || addition.uppercased() == "DONE" {
                truncated = false
                break
            }
            // Keep markdown intact when the cut landed mid-paragraph.
            text += text.hasSuffix("\n") ? addition : "\n" + addition
            truncated = next.completion.truncated
            TicNoteDiagLog.log(
                "LLM",
                "summary continued +\(addition.count) chars, stillTruncated=\(truncated)"
            )
        }
        return LLMCompletionService.Completion(text: text, truncated: truncated)
    }

    // MARK: - Short-source adaptation (Plaud/Vobot parity)

    /// Thresholds in "content weight" (CJK characters count one each, Latin
    /// words count one each — see `contentWeight`). Below the gate the source
    /// is a sentence or two; below the compact line it is a short paragraph.
    private static let shortGateWeight = 60
    private static let compactThreshold = 500

    /// Adapt the template to the size of the source.
    ///
    /// * **Tiny** (a sentence or two): the template is replaced entirely by a
    ///   two-sentence reply prompt. No headings, no tables, no skeleton — the
    ///   output must never be longer than the thing it summarises.
    /// * **Short but real** (a short paragraph): the template stays, but with
    ///   an instruction to drop empty sections and keep the output no longer
    ///   than the source. This is the "structured minutes on a 30 s note"
    ///   case that produces three pages of `## 待确认` placeholders.
    /// * Anything else: the template verbatim.
    static func adaptedPrompt(templatePrompt: String, source: String) -> AdaptedPrompt {
        let weight = contentWeight(source)
        if weight < shortGateWeight {
            return AdaptedPrompt(
                text: NSLocalizedString("summarize.short_prompt", value: """
                The transcript below is very short — most likely a quick voice note. \
                Reply in the user's language with at most two short sentences: what was said, \
                plus any task, date or decision it contains. \
                Do NOT use headings, tables or template sections, and never write more text than the transcript itself.
                """, comment: "System prompt replacing the full template when the transcript is a sentence or two")
                    + "\n\n" + SummaryPolicy.tinyNote,
                replacedTemplate: true
            )
        }
        // ★ 2026-10-23 ("摘要里很多无关紧要的内容"): the templates are Vobot
        //   skeletons and the model used to fill every empty slot with
        //   【To Be Confirmed】, plus a restatement of the recording's metadata.
        //   The rules ride along with every template — including the chunked and
        //   merge passes, which reuse this same system prompt — so all 60+
        //   templates inherit the discipline without being rewritten.
        let rules = SummaryPolicy.rules
        if weight < compactThreshold {
            return AdaptedPrompt(
                text: templatePrompt + "\n\n" + NSLocalizedString("summarize.compact_note", value: """
                The source text is short. Keep the output shorter than the source: drop every \
                section that has nothing real to say instead of filling the template with placeholders.
                """, comment: "Appended to the template prompt when the source is a short paragraph")
                    + "\n\n" + rules,
                replacedTemplate: false
            )
        }
        return AdaptedPrompt(text: templatePrompt + "\n\n" + rules, replacedTemplate: false)
    }

    /// Result of `adaptedPrompt`. ★ 2026-10-23 ("为啥会到模型输出上限"):
    /// the old code decided "was the template replaced?" by comparing the
    /// returned string with the original — but the output rules are appended to
    /// *every* prompt, so the strings always differed and every run carried the
    /// "转写内容很短——已改用简化摘要" note, even a three-chunk interview. The
    /// flag is now explicit.
    struct AdaptedPrompt {
        let text: String
        let replacedTemplate: Bool
    }

    /// One number for "how much is actually said here": CJK characters count
    /// one each (they are the meaning-bearing unit), Latin words count one
    /// each. Timestamps and speaker labels ride along, which biases upward —
    /// fine for a threshold that is deliberately generous.
    static func contentWeight(_ text: String) -> Int {
        var cjk = 0
        var words = 0
        var inWord = false
        for ch in text {
            if isCJK(ch) {
                cjk += 1
                inWord = false
            } else if ch.isLetter {
                if !inWord { words += 1; inWord = true }
            } else {
                inWord = false
            }
        }
        return cjk + words
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }

    /// Translation. Used to be in `ClipDetailView.runTranslate`, split into a transcript branch and a summary branch.
    @MainActor
    static func translate(
        _ job: Job, config: AppConfig, reporter: JobQueue.Reporter
    ) async throws {
        guard let languageName = job.languageName else {
            throw JobSourceMissing(what: L10n.Jobs.sourceLanguage)
        }
        let target = job.translateTarget ?? "transcript"

        BackgroundKeeper.shared.acquire(.summary)
        defer { BackgroundKeeper.shared.release(.summary) }

        // The translation can also be truncated by the output cap. The previous version popped an alert on the spot; once the job runs in the background
        // that alert can't reach (the user isn't on this page), so it's now persisted alongside the artifact into
        // `Job.notes`, visible any time you come back. A half-finished translation looks exactly like a complete one.
        func report(_ output: LLMCompletionService.Completion) {
            reporter.notes(
                output.truncated ? [L10n.Summarize.truncatedWarning] : [],
                output.truncated
            )
        }

        switch target {
        case "summary":
            let url = StorageLocations.summaryTranslatedURL(for: job.clipName)
            let source = try summaryText(for: job.clipName)
            let output = try await LLMCompletionService.translate(
                text: source, targetLanguage: languageName, config: config
            )
            try Task.checkCancellation()
            try output.text.data(using: .utf8)?.write(to: url, options: .atomic)
            report(output)

        default:
            let urls = StorageLocations.translationURLs(for: job.clipName)
            let source = try transcriptText(for: job.clipName)
            let output = try await LLMCompletionService.translate(
                text: source, targetLanguage: languageName, config: config
            )
            try Task.checkCancellation()
            try output.text.data(using: .utf8)?.write(to: urls.txt, options: .atomic)
            // The Live-produced `.translated.json` carries word-level
            // timestamps for a specific target language; once the user
            // re-translates on-demand to a different language, that JSON
            // is stale, so wipe it rather than let it drift out of sync
            // with the displayed text.
            try? FileManager.default.removeItem(at: urls.json)
            report(output)
        }
        log.info("translated \(job.clipName, privacy: .public) → \(languageName, privacy: .public)")
    }

    /// Format conversion / export. Used to be in `ClipDetailView.runExport`.
    /// ★ 2026-10-22 (任务二): also handles the document formats `txt` / `md` /
    /// `pdf` (and `png` = mind-map image) alongside the two audio formats.
    @MainActor
    static func export(_ job: Job, config: AppConfig) async throws {
        guard let raw = job.exportFormat else {
            throw JobSourceMissing(what: L10n.Jobs.sourceFormat)
        }
        // ⚠️ The audio is looked up by **filename** in `decryptedDir`, and the absolute path isn't stored in the job —
        //    the sandbox container path changes after a reinstall / migration, so a saved path is stale the very next day
        //    (`TranscriptionService`'s queue makes the same trade-off here).
        let source = StorageLocations.decryptedDir.appendingPathComponent(job.clipName)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw JobSourceMissing(what: L10n.Jobs.sourceAudio)
        }

        BackgroundKeeper.shared.acquire(.export)
        defer { BackgroundKeeper.shared.release(.export) }

        // ★ Write into `ExportCenter`'s staging directory rather than `tmp`: `tmp` can be
        //   cleared by iOS at any time, and "export, switch away, come back and share" is exactly the scenario this path exists to support.
        let dir = try ExportCenter.shared.beginNewStaging()
        let stem = (job.clipName as NSString).deletingPathExtension
        do {
            let url: URL
            if raw == "txt" || raw == "md" || raw == "pdf" || raw == "png" {
                url = try DocumentExporter.export(raw, clipName: job.clipName, into: dir)
            } else {
                guard let format = AudioExportFormat(rawValue: raw) else {
                    throw JobSourceMissing(what: L10n.Jobs.sourceFormat)
                }
                url = try await AudioExporter.export(
                    format, source: source, suggestedName: stem, directory: dir
                )
            }
            try Task.checkCancellation()
            ExportCenter.shared.publish(
                id: dir.lastPathComponent,
                title: stem,
                itemCount: 1,
                bytes: fileSize(url),
                origin: job.clipName
            )
            log.info("exported \(job.clipName, privacy: .public) as \(raw, privacy: .public)")
            Telemetry.success("export_share_\(raw)", ["bytes": String(fileSize(url))])
        } catch {
            Telemetry.failed("export_share_\(raw)", reason: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Source file

    /// The transcript text fed to the model for this recording.
    ///
    /// ⚠️ **It must not read `{base}.txt` directly.** The one on disk is
    ///    written by `TranscriptionService.formatTranscript`, whose rule is
    ///    "if there are segments use `formatted()` (**with timestamps**), otherwise use the whole text";
    ///    while the detail page uses `textForSummarization` when starting a summary, whose rule is
    ///    "if there are speakers use `formatted()`, **if there are no speakers use plain text without timestamps**".
    ///    The two **differ** in the one case of "there are segments but no speakers were recognised" —
    ///    reading the file directly would produce structurally different summaries from the same transcript, and the user would just think
    ///    "this feature works sometimes and not others".
    ///
    /// ⇒ Always forward to `summarizableText`, **letter-for-letter the same source** as the detail page.
    private static func transcriptText(for clipName: String) throws -> String {
        let urls = StorageLocations.transcriptURLs(for: clipName)
        // Prefer `.asr.json`: it has the segments and speakers, which `summarizableText` needs.
        if let data = try? Data(contentsOf: urls.json),
           let result = try? JSONDecoder().decode(AsrResult.self, from: data) {
            return summarizableText(text: result.text,
                                    segments: result.segments,
                                    speakerNames: SpeakerNameStore.namesOnDisk(for: clipName))
        }
        // The case where only `.txt` is left (an old item's json was cleared): that's all the information there is.
        return try read(urls.txt, what: L10n.Jobs.sourceTranscript)
    }

    /// The actual text string fed to summary / translation.
    ///
    /// ★ This is the **single implementation**: `ClipDetailView.textForSummarization(_:)` now forwards
    ///   here too. It used to have its own copy, and after revision twelve summary gained a second entry point (the queue),
    ///   so the two copies would eventually drift apart — and the symptom would be "the same button produces summaries with a different
    ///   structure a day apart", which is very hard to trace.
    /// `speakerNames` is the user's rename map (`SpeakerNameStore`). The queue has no
    /// UI, so it reads the sidecar off disk by itself; the detail page passes the map
    /// it already has. Either way the text handed to the model says "张伟", not
    /// "Speaker 1" — ★ 2026-10-22 ("还要支持修改说话人的名称").
    static func summarizableText(text: String,
                                 segments: [AsrSegment],
                                 speakerNames: [String: String] = [:]) -> String {
        if segments.isEmpty { return text }
        if segments.contains(where: { !($0.speaker ?? "").isEmpty }) {
            return segments.map { $0.formatted(speakerNames: speakerNames) }.joined(separator: "\n")
        }
        return segments.map(\.text).joined(separator: "\n")
    }

    private static func summaryText(for clipName: String) throws -> String {
        try read(StorageLocations.summaryURL(for: clipName), what: L10n.Jobs.sourceSummary)
    }

    private static func read(_ url: URL, what: String) throws -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            throw JobSourceMissing(what: what)
        }
        return text
    }

    // MARK: - Result note

    /// Translate the `Outcome` into plain words. **Both must be spelled out**:
    /// that a non-primary channel was used (the configuration had a problem), and that the content was chunked (the result's structure differs subtly
    /// from generating the whole thing in one go, and a user seeing a missing chunk heading would think it's a bug).
    ///
    /// Moved over from `SummarizeSheet` — it is now "part of the result", persisted along with
    /// the artifact into `Job.notes`, rather than only being meaningful on the page that started it (that job most likely finished
    /// while the user wasn't looking).
    static func notices(for outcome: LLMCompletionService.Outcome, config: AppConfig) -> [String] {
        var result: [String] = []
        let primary = config.llmProviders.primary ?? ""
        if !primary.isEmpty, primary != outcome.providerKey {
            result.append(L10n.LLM.fellBack(
                LLMCompletionService.providerLabel(primary),
                LLMCompletionService.providerLabel(outcome.providerKey)
            ))
        }
        if outcome.chunked {
            result.append(L10n.LLM.chunkedNote(outcome.chunkCount))
        }
        return result
    }

    // MARK: - Title (best-effort)

    /// Ask for a short title from the summary body as well. On failure return nil — the summary itself is valid,
    /// and it shouldn't be that a title can't be generated and the whole job is judged a failure.
    @MainActor
    private static func extractTitle(
        from summary: String, config: AppConfig, preferred: String?
    ) async -> String? {
        let instruction = """
            Generate a short title (under 60 characters) for the following notes. \
            Reply with ONLY the title text, no quotes, no punctuation at the end.
            """
        do {
            let outcome = try await LLMCompletionService.completeResilient(
                systemPrompt: instruction,
                userContent: String(summary.prefix(1000)),
                config: config,
                // Title generation gets only 1000 characters of input; nothing to chunk.
                allowChunking: false,
                preferred: preferred
            )
            let clean = outcome.completion.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : clean
        } catch {
            return nil
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
