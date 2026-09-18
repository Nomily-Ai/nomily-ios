import Foundation

struct SummarizeTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var category: String
    var name: String
    var prompt: String
    var isBuiltIn: Bool

    init(id: UUID = UUID(), category: String, name: String, prompt: String, isBuiltIn: Bool = true) {
        self.id = id
        self.category = category
        self.name = name
        self.prompt = prompt
        self.isBuiltIn = isBuiltIn
    }

    var localizedName: String {
        isBuiltIn ? Self.localizedTemplateName(name) : name
    }

    var localizedCategory: String {
        Self.localizedCategoryName(category)
    }

    var localizedPrompt: String {
        guard isBuiltIn, let key = Self.promptKeys[name] else { return prompt }
        return NSLocalizedString(key, comment: "")
    }

    static let promptMaxCharacters = 4_000

    private static let categoryKeys: [String: String] = [
        "Meeting Notes": "template_cat.meeting_notes",
        "Action Items": "template_cat.action_items",
        "General Summary": "template_cat.general_summary",
        "Professional": "template_cat.professional",
        "Academic": "template_cat.academic",
        "Creative": "template_cat.creative",
    ]

    private static let promptKeys: [String: String] = [
        "Formal Meeting Minutes": "template_prompt.formal_minutes",
        "Structured Minutes": "template_prompt.structured_minutes",
        "Executive Brief": "template_prompt.executive_brief",
        "Key Takeaways": "template_prompt.key_takeaways",
        "Task Extraction": "template_prompt.task_extraction",
        "Decision Log": "template_prompt.decision_log",
        "Concise Summary": "template_prompt.concise_summary",
        "Detailed Notes": "template_prompt.detailed_notes",
        "Q&A Format": "template_prompt.qa_format",
        "Client Meeting Recap": "template_prompt.client_meeting_recap",
        "1-on-1 Summary": "template_prompt.one_on_one_summary",
        "Status Update": "template_prompt.status_update",
        "Lecture Notes": "template_prompt.lecture_notes",
        "Research Discussion": "template_prompt.research_discussion",
        "Brainstorm Synthesis": "template_prompt.brainstorm_synthesis",
        "Interview Summary": "template_prompt.interview_summary",
    ]

    private static let nameKeys: [String: String] = [
        "Formal Meeting Minutes": "template.formal_minutes",
        "Structured Minutes": "template.structured_minutes",
        "Executive Brief": "template.executive_brief",
        "Key Takeaways": "template.key_takeaways",
        "Task Extraction": "template.task_extraction",
        "Decision Log": "template.decision_log",
        "Concise Summary": "template.concise_summary",
        "Detailed Notes": "template.detailed_notes",
        "Q&A Format": "template.qa_format",
        "Client Meeting Recap": "template.client_meeting_recap",
        "1-on-1 Summary": "template.one_on_one_summary",
        "Status Update": "template.status_update",
        "Lecture Notes": "template.lecture_notes",
        "Research Discussion": "template.research_discussion",
        "Brainstorm Synthesis": "template.brainstorm_synthesis",
        "Interview Summary": "template.interview_summary",
    ]

    static func localizedCategoryName(_ category: String) -> String {
        guard let key = categoryKeys[category] else { return category }
        return NSLocalizedString(key, comment: "")
    }

    static func localizedTemplateName(_ name: String) -> String {
        guard let key = nameKeys[name] else { return name }
        return NSLocalizedString(key, comment: "")
    }
}

// MARK: - Template store

@MainActor
final class SummarizeTemplateStore: ObservableObject {
    @Published var templates: [SummarizeTemplate]

    init() {
        if let loaded = Self.load() {
            // Merge any built-ins that the saved store predates. Identity is
            // (category, name) — a built-in already present keeps the
            // user's copy (in case future defaults tweak wording, we don't
            // want to clobber their muscle memory); any built-in missing
            // gets appended in the same order as `defaults`. User-added
            // custom templates are left untouched.
            let savedIDs: Set<String> = Set(loaded.map { "\($0.category)\u{1F}\($0.name)" })
            let missing = Self.defaults.filter { d in
                d.isBuiltIn && !savedIDs.contains("\(d.category)\u{1F}\(d.name)")
            }
            if missing.isEmpty {
                templates = loaded
            } else {
                templates = loaded + missing
                Self.saveSynchronously(templates)
            }
        } else {
            templates = Self.defaults
        }
    }

    private static func saveSynchronously(_ templates: [SummarizeTemplate]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(templates) else { return }
        try? data.write(to: StorageLocations.templatesURL, options: .atomic)
    }

    /// Custom categories are placed **before** built‑in categories. The original order is "first appearance in the template array",
    /// built‑in templates are inserted first, and new templates are always appended, so user‑created categories always end up at the bottom (j6ej5d9).
    /// Since the data structure lacks a sorting field, we only perform a global prepend here rather than per‑item sorting.
    var categories: [String] {
        var seen = Set<String>()
        let inOrder = templates.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
        let builtInCategories = Set(templates.filter(\.isBuiltIn).map(\.category))
        return inOrder.filter { !builtInCategories.contains($0) } + inOrder.filter { builtInCategories.contains($0) }
    }

    /// The same applies within a category: custom templates are placed before built‑in templates.
    func templates(in category: String) -> [SummarizeTemplate] {
        let all = templates.filter { $0.category == category }
        return all.filter { !$0.isBuiltIn } + all.filter(\.isBuiltIn)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(templates) else { return }
        try? data.write(to: StorageLocations.templatesURL, options: .atomic)
    }

    func resetToDefaults() {
        templates = Self.defaults
        save()
    }

    private static func load() -> [SummarizeTemplate]? {
        guard let data = try? Data(contentsOf: StorageLocations.templatesURL),
              let t = try? JSONDecoder().decode([SummarizeTemplate].self, from: data),
              !t.isEmpty else { return nil }
        return t
    }

    // MARK: - Built-in templates

    static let defaults: [SummarizeTemplate] = [
        // Meeting Notes
        SummarizeTemplate(
            category: "Meeting Notes",
            name: "Formal Meeting Minutes",
            prompt: """
            You convert meeting transcripts, interview records, and discussion material into formal, archive-ready meeting minutes.

            Core principles
            - Follow a McKinsey-style structure: conclusion-first, highly structured, layered decomposition, MECE (mutually exclusive, collectively exhaustive).
            - Language must be professional, clear, restrained, specific, and actionable.
            - For any missing or uncertain information that materially affects the formal minutes, mark it as [To Be Confirmed].
            - Standardize names of people, companies, tools, projects, and terminology throughout the document; carry corrections forward consistently.
            - Remove empty sections — do not keep placeholder headings with no content.
            - If the source clearly says certain information should not be included, exclude it entirely (do not move it to "pending confirmations", notes, background, or appendix).

            Workflow
            1. Read the source carefully.
            2. Extract: topic, date, time, format, participants, related company/project, key topics, core conclusions, discussion points, disputes, action items, and pending confirmations.
            3. Summarize core conclusions, discussion flow, major consensus points, action items, and only the pending confirmations that truly matter.

            Output the following structure (omit sections with no content):

            # [Meeting Title]

            ## 0. Basic Meeting Information

            | Item | Details |
            |---|---|
            | Meeting Topic |  |
            | Meeting Date |  |
            | Meeting Time |  |
            | Meeting Format |  |
            | Participants |  |
            | Meeting Purpose |  |
            | Related Company / Project |  |
            | Source Materials |  |

            ## 1. Core Meeting Conclusions
            The 3–5 most important conclusions from the meeting, conclusion-first.

            ## 2. Main Discussion Topics
            For each topic:
            ### 2.x [Topic]
            - Current Issue
            - Discussion Summary
            - Initial Direction

            ## 3. Key Consensus
            Items on which agreement was reached.

            ## 4. Follow-up Recommendations
            Organize by business / product / technology / operations / collaboration as appropriate.

            ## 5. Action Items

            | No. | Action Item | Priority | Suggested Owner |
            |---|---|---|---|

            ## 6. Pending Confirmations
            Only items that genuinely require confirmation and materially affect the formal record.

            ## 7. Summary
            A concise wrap-up of the meeting's value and next-step direction.

            If the meeting involves additional content types not covered above, add the necessary sections.
            """
        ),
        SummarizeTemplate(
            category: "Meeting Notes",
            name: "Structured Minutes",
            prompt: """
            You are an expert meeting notes assistant. Analyze this transcript and produce structured meeting minutes in Markdown:

            ## Meeting Summary
            One paragraph overview of the meeting purpose and outcome.

            ## Attendees
            List all speakers/participants mentioned.

            ## Agenda Items Discussed
            For each topic discussed:
            ### [Topic]
            - Key points raised
            - Different viewpoints expressed
            - Outcome or conclusion reached

            ## Action Items
            | Owner | Task | Deadline (if mentioned) |
            |-------|------|------------------------|

            ## Decisions Made
            Bullet list of concrete decisions.

            ## Open Questions
            Unresolved items that need follow-up.

            Be concise. Use the speakers' own words for accuracy. If something is unclear in the transcript, note it as [unclear].
            """
        ),
        SummarizeTemplate(
            category: "Meeting Notes",
            name: "Executive Brief",
            prompt: """
            Summarize this meeting transcript into a brief executive summary (3-5 paragraphs max). Focus on:
            1. Why the meeting was held
            2. The most important decisions made
            3. Critical action items and who owns them
            4. Any risks or blockers raised
            5. Next steps

            Write in professional, direct language. Skip pleasantries and filler. A busy executive should be able to read this in under 2 minutes.
            """
        ),
        SummarizeTemplate(
            category: "Meeting Notes",
            name: "Key Takeaways",
            prompt: """
            Extract the key takeaways from this meeting transcript. Format as:

            ## Key Takeaways
            - Numbered list of the 5-10 most important points from this meeting
            - Each point should be a single, self-contained sentence
            - Prioritize decisions, commitments, and new information over discussion

            ## Notable Quotes
            Include 2-3 direct quotes that capture critical moments or commitments, with speaker attribution.

            ## Sentiment
            Brief note on the overall tone — was this productive, contentious, exploratory, etc.?
            """
        ),

        // Action Items
        SummarizeTemplate(
            category: "Action Items",
            name: "Task Extraction",
            prompt: """
            Review this transcript carefully and extract ALL commitments, assignments, and follow-up tasks. For each item:

            - **Who**: The person who committed or was assigned
            - **What**: Specific task or deliverable
            - **When**: Deadline if mentioned, otherwise "TBD"
            - **Context**: One sentence on why this matters

            Format as a numbered list. Include implicit commitments (e.g., "I'll look into that" = task). Flag any tasks where ownership is ambiguous with [OWNER UNCLEAR].
            """
        ),
        SummarizeTemplate(
            category: "Action Items",
            name: "Decision Log",
            prompt: """
            Extract every decision made in this transcript. For each decision:

            1. **Decision**: What was decided
            2. **Rationale**: Why (key arguments that led to it)
            3. **Alternatives considered**: Other options discussed and why they were rejected
            4. **Impact**: Who or what is affected
            5. **Owner**: Who is responsible for execution

            If a topic was discussed but no clear decision was reached, list it under "Pending Decisions" with the current status of the discussion.
            """
        ),

        // General Summary
        SummarizeTemplate(
            category: "General Summary",
            name: "Concise Summary",
            prompt: """
            Provide a concise summary of this transcript in 3-5 paragraphs. Cover the main topics discussed, key points made, and any conclusions reached. Write in clear, professional prose. Do not use bullet points or headers — just well-organized paragraphs.
            """
        ),
        SummarizeTemplate(
            category: "General Summary",
            name: "Detailed Notes",
            prompt: """
            Create comprehensive, well-organized notes from this transcript. Use Markdown formatting:

            ## Overview
            Brief context-setting paragraph.

            ## Discussion
            Organize by topic (not chronologically). For each topic, capture:
            - The main points and arguments
            - Supporting details or data mentioned
            - Any disagreements or alternative viewpoints

            ## Conclusions
            What was resolved or agreed upon.

            ## Follow-up
            Items requiring further discussion or action.

            Preserve important nuance. When speakers disagree, represent both sides fairly.
            """
        ),
        SummarizeTemplate(
            category: "General Summary",
            name: "Q&A Format",
            prompt: """
            Restructure this transcript into a clean Q&A format. Identify questions (explicit or implicit) and pair them with the answers given. Format:

            **Q: [Question]**
            A: [Answer, synthesized from the discussion]

            Group related Q&As under topic headers. If a question was asked but not fully answered, note it as [Partially answered] or [Unanswered].
            """
        ),

        // Professional
        SummarizeTemplate(
            category: "Professional",
            name: "Client Meeting Recap",
            prompt: """
            Create a client-ready meeting recap from this transcript. Format:

            **Subject:** [Meeting topic]
            **Date:** [Extract if mentioned]
            **Participants:** [List]

            **Summary:**
            Professional overview of what was discussed and agreed upon.

            **Agreed Next Steps:**
            Numbered list of commitments from both sides.

            **Timeline:**
            Any dates or milestones discussed.

            Keep the tone professional and positive. Avoid internal jargon. Focus on mutual commitments and value delivered.
            """
        ),
        SummarizeTemplate(
            category: "Professional",
            name: "1-on-1 Summary",
            prompt: """
            Summarize this 1-on-1 conversation. Capture:

            ## Topics Discussed
            Brief list of what was covered.

            ## Feedback Given
            Any feedback exchanged (positive or constructive), with context.

            ## Blockers & Support Needed
            Issues raised that need help or escalation.

            ## Goals & Commitments
            What each person committed to before the next check-in.

            ## Career/Growth
            Any career development, learning, or growth topics discussed.

            Keep this private and constructive in tone.
            """
        ),
        SummarizeTemplate(
            category: "Professional",
            name: "Status Update",
            prompt: """
            Convert this transcript into a project status update:

            ## Status: [Green/Yellow/Red based on the discussion tone]

            ## Progress Since Last Update
            - What was accomplished

            ## Current Focus
            - What's being worked on now

            ## Blockers
            - Issues preventing progress

            ## Upcoming Milestones
            - What's next and when

            ## Risks
            - Anything that could derail the timeline

            Be factual and specific. Use dates and metrics when mentioned.
            """
        ),

        // Academic
        SummarizeTemplate(
            category: "Academic",
            name: "Lecture Notes",
            prompt: """
            Transform this lecture/talk transcript into well-organized study notes:

            ## Topic
            Main subject and context.

            ## Key Concepts
            For each major concept introduced:
            - **Term/Concept**: Clear definition or explanation
            - Supporting examples or analogies used by the speaker

            ## Important Details
            Facts, figures, dates, or formulas mentioned.

            ## Connections
            How concepts relate to each other or to broader themes.

            ## Review Questions
            Generate 3-5 questions a student could use for self-testing.

            Use clear, educational language. Highlight terms that would likely appear on an exam.
            """
        ),
        SummarizeTemplate(
            category: "Academic",
            name: "Research Discussion",
            prompt: """
            Summarize this research discussion or journal club transcript:

            ## Paper/Topic Discussed
            Title and authors if mentioned.

            ## Main Findings
            Key results or claims presented.

            ## Methodology
            How the research was conducted (if discussed).

            ## Strengths
            What the group found compelling.

            ## Criticisms & Limitations
            Concerns raised about the work.

            ## Implications
            Why this matters, applications discussed.

            ## Open Questions
            Unresolved scientific questions that emerged.
            """
        ),

        // Creative
        SummarizeTemplate(
            category: "Creative",
            name: "Brainstorm Synthesis",
            prompt: """
            Synthesize this brainstorming session into an organized output:

            ## Problem Statement
            What problem or opportunity was being explored.

            ## Ideas Generated
            Group similar ideas into themes. For each theme:
            ### [Theme]
            - Specific ideas proposed
            - Who suggested them (if identifiable)
            - Pros/cons discussed

            ## Top Candidates
            Ideas that got the most energy or support from the group.

            ## Wild Cards
            Unconventional or risky ideas worth exploring further.

            ## Recommended Next Steps
            How to evaluate or prototype the most promising ideas.
            """
        ),
        SummarizeTemplate(
            category: "Creative",
            name: "Interview Summary",
            prompt: """
            Summarize this interview transcript:

            ## Interviewee
            Name and background (if mentioned).

            ## Key Insights
            The most valuable or surprising things shared, organized by theme.

            ## Notable Quotes
            3-5 direct quotes that capture their perspective well.

            ## Themes
            Recurring ideas or concerns throughout the conversation.

            ## Follow-up Questions
            Questions that weren't asked but would be worth exploring.

            Preserve the interviewee's voice and perspective. Don't editorialize.
            """
        ),
    ]
}
