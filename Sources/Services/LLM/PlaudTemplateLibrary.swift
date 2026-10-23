import Foundation

/// Templates modelled on **Plaud's own product**, captured from the vivo
/// handset on 2026-10-23 (screenshots under
/// `TicNote/03-逆向/PLAUD/android-re/screens/vivo-2026-10-23/`).
///
/// Plaud's split, in their own words: *summaries for quick overviews,
/// extraction notes for key insights like quotes or numbers, and actionable
/// outputs like to-do lists and follow-ups.* Their 会议纪要 tile says
/// "生成完整清晰的会议纪要，含行动与决策".
///
/// These four are **prepended** to `SummarizeTemplateStore.defaults`, which has
/// two consequences by design:
/// * `AppEnvironment.autoSummaryTemplate` (`defaults.first`) — the template the
///   automatic post-transcription summary uses — becomes "Plaud Summary" instead
///   of the Vobot skeleton that used to fill empty slots with 【To Be Confirmed】.
/// * They appear at the top of the picker.
///
/// The global output discipline (`SummaryPolicy.rules`, build 133) is appended
/// to every template at run time, so the prompts here stay lean and never
/// mention placeholders — the rules already forbid them.
enum PlaudTemplateLibrary {

    static let templates: [SummarizeTemplate] = [
        // MARK: 总结 — the automatic full report (auto-summary default)
        //
        // ★ 2026-10-23 ("如果没有设定模板你需要按照自动去生成，按照他这种样式"):
        // the no-template auto summary follows Vobot Recorder's automatic
        // report — a titled document whose body is numbered content sections
        // (一、二、三… in a Chinese transcript) with dense hierarchical
        // bullets, then to-dos and open questions. Reference samples:
        // `Downloads/note_20261020183641_总结.md` and the 10-23 nine-section
        // sample shared in chat. Old sections (Overview / Key Points /
        // Decisions / To-dos) forced a fixed 4-part shape and capped output;
        // this one derives its sections from the recording itself.

        SummarizeTemplate(
            category: "General Summary",
            name: "Quick Summary",
            summary: "Automatic full report: subjects and conclusions, to-dos, follow-ups.",
            prompt: """
            Produce the automatic full report — the document this app writes when no template was chosen. This is a FULL report: completeness wins over brevity, every real point the recording makes gets in.

            Structure, in this order — drop any section that ends up with no real content:

            # [A short title naming what the recording is about]

            ## [Major subject]
            Split the recording into its major subjects, one section per subject — as many sections as the recording actually has. Number the section titles in the speakers' language: 一、二、三… for a Chinese transcript, 1. 2. 3. otherwise.

            Under each subject, dense bullets that carry the facts, numbers, names, positions and outcomes as they were said; sub-points may nest one level deeper. A decision or conclusion reached gets its own bullet, stated as the decision, not as the discussion.

            ## To-dos
            One bullet per explicit commitment: task, deadline, owner. Leave owner or date blank when the transcript does not say — never invent them. Omit the section when there are none.

            ## Needs follow-up
            Open questions, unresolved issues, and anything still awaiting confirmation. Omit the section when there are none.

            The title and every heading are in the speakers' language. Reply with the report in Markdown and nothing else.
            """
        ),

        // MARK: 会议纪要 — "complete, clear minutes with actions and decisions"

        SummarizeTemplate(
            category: "Meeting Notes",
            name: "Meeting Minutes",
            summary: "Complete, clear meeting minutes with actions and decisions.",
            prompt: """
            Generate complete, clear meeting minutes with actions and decisions.

            Output exactly these sections — drop any section the transcript gives no real content for:

            ## Overview
            One short paragraph: the meeting's purpose and outcome.

            ## Attendees
            Only people who actually spoke or were named. If unknown, drop the section.

            ## Discussion & Conclusions
            One block per topic, conclusion first, at most three sentences.

            ## Decisions
            One line per decision actually made.

            ## Action Items
            A table: | Action | Owner | Deadline |. Leave a cell blank when the transcript does not say — never invent.

            ## Open Questions
            Only items left unresolved.

            Keep the whole output under a third of the transcript's length.
            """
        ),

        // MARK: 要点提取 — extraction notes (quotes / numbers)

        SummarizeTemplate(
            category: "Meeting Notes",
            name: "Key Points",
            summary: "Extraction notes: key insights, quotes with speakers, numbers and dates.",
            prompt: """
            Produce extraction notes: only the content worth keeping, nothing else.

            Output exactly these sections — drop any section the transcript gives no real content for:

            ## Key Insights
            At most 6 bullets, one sentence each.

            ## Quotes
            Short verbatim quotes that carry meaning, each with the speaker who said it.

            ## Numbers & Dates
            Every figure, deadline and date mentioned, with its context.

            ## Risks & Unknowns
            Only risks raised or questions left open.

            Do not restate the recording's metadata or structure — extract content only.
            """
        ),

        // MARK: 待办清单 — actionable outputs

        SummarizeTemplate(
            category: "Action Items",
            name: "To-Do List",
            summary: "Only explicit to-dos: task, owner, deadline. Honest empty state when none.",
            prompt: """
            Extract ONLY explicit to-dos: something someone committed to, was assigned, or that carries a deadline. Ideas, possibilities and "we could maybe" are not to-dos.

            Output a table: | To-do | Owner | Deadline |.
            Leave a cell blank when the transcript does not say — never invent.
            Group by owner when several items share one.
            If the transcript contains no to-do at all, output exactly one line saying so — do not pad the section with anything else.
            """
        ),
    ]
}
