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
        // MARK: 总结 — the quick overview (auto-summary default)

        SummarizeTemplate(
            category: "General Summary",
            name: "Plaud Summary",
            summary: "Plaud-style quick overview: one paragraph, key points, decisions, to-dos.",
            prompt: """
            Produce the quick overview: short, factual, every line carrying information.

            Output exactly these sections — drop any section the transcript gives no real content for:

            ## Overview
            One short paragraph: what this recording is and what came out of it.

            ## Key Points
            At most 6 bullets, one sentence each. Include concrete numbers, names, and short quotes where they carry meaning.

            ## Decisions
            Only decisions actually made in the recording, one per line.

            ## To-dos & Follow-ups
            Only explicit commitments, assignments, or items with a deadline. Leave owner and date blank when the transcript does not say — never invent them.

            Keep the whole output under a quarter of the transcript's length.
            """
        ),

        // MARK: 会议纪要 — "complete, clear minutes with actions and decisions"

        SummarizeTemplate(
            category: "Meeting Notes",
            name: "Plaud Meeting Minutes",
            summary: "Complete, clear meeting minutes with actions and decisions (Plaud 会议纪要).",
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
            name: "Plaud Key Points",
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
            name: "Plaud To-Do List",
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
