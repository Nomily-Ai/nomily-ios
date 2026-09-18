import Foundation

// MARK: - Adopted template library

/// Templates adopted from Vobot Recorder, so a transcript can be turned into
/// the same reports from either app.
///
/// Split out of `SummarizeTemplateStore` because it is generated — one block
/// per template, ~50 of them — and would otherwise bury the hand-written
/// originals it sits beside. Regenerate with `build/vobot_generate.py`.
///
/// The prompts are Vobot's own output skeletons with a short heading added:
/// a bare skeleton is a shape, not an instruction, and a model handed one on
/// its own tends to hand the placeholders straight back.
enum VobotTemplateLibrary {
    static let templates: [SummarizeTemplate] = [
        // ---------------------------------------------------------------
        // Adopted from Vobot Recorder's template library. The prompts are
        // output skeletons rather than prose instructions, so each one carries
        // a short header that turns it into something a model will actually
        // fill in instead of echoing back.
        // ---------------------------------------------------------------
        // Meeting Notes
        SummarizeTemplate(
            category: "Meeting Notes",
            name: "Detailed Summary",
            summary: "A detailed summary of a call or meeting",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Detailed Summary

            ## Basic Information
            - **Topic**: [Topic]
            - **Date**: [Date]
            - **Duration**: [Duration]
            - **Participants**: [Participants]

            ## Overview
            [Summarize the background, purpose, and overall conclusion of this call or meeting in 3–5 sentences]

            ## Detailed Content

            ### [Topic 1 title]
            [Summarize the detailed discussion of this topic, covering each party's viewpoints, background information, and main conclusions]

            ### [Topic 2 title]
            [Summarize the detailed discussion of this topic, covering each party's viewpoints, background information, and main conclusions]

            ### [Topic 3 title]
            [Summarize the detailed discussion of this topic, covering each party's viewpoints, background information, and main conclusions]

            ## Key Viewpoints
            - [Key viewpoint 1]
            - [Key viewpoint 2]
            - [Key viewpoint 3]

            ## Disagreements
            - [Record differing opinions or unresolved issues in the discussion; omit this section if none]

            ## Decisions & Consensus
            - [Decision or consensus 1]
            - [Decision or consensus 2]

            ## Follow-up Actions
            | Item | Owner | Due Date |
            |------|--------|----------|
            | [Action item 1] | [Owner] | [Date] |
            | [Action item 2] | [Owner] | [Date] |

            ## Additional Notes
            [Record background materials, reference information, or other notes mentioned in the meeting; omit this section if none]
            """
        ),
        SummarizeTemplate(
            category: "Meeting Notes",
            name: "Meeting Report",
            summary: "For regular meetings, team reviews, project retrospectives, and periodic reports. (Structure: progress, issues, and plans.)",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Meeting Report

            ## Basic Information

            - **Meeting Topic**: [Meeting topic]
            - **Meeting Time**: [Date and time]
            - **Meeting Location**: [Location or online platform]
            - **Attendees**: [Attendee names or roles]
            - **Host**: [Host name or role]

            ---

            ## Meeting Overview

            [Summarize the background, purpose, and overall context of this meeting in 2–4 sentences.]

            ---

            ## Current Progress

            ### Key Achievements
            - [Progress point 1]
            - [Progress point 2]
            - [Progress point 3]

            ### Key Data & Metrics
            - [Data or metric 1]
            - [Data or metric 2]

            ---

            ## Issues & Risks

            ### Current Issues
            | Issue Description | Impact Scope | Owner |
            |----------|----------|--------|
            | [Issue 1] | [Impact description] | [Owner] |
            | [Issue 2] | [Impact description] | [Owner] |

            ### Potential Risks
            - [Risk 1 and brief description]
            - [Risk 2 and brief description]

            ---

            ## Next Steps

            ### Near-Term Action Items
            | Action Item | Owner | Planned Completion Date |
            |----------|--------|--------------|
            | [Action item 1] | [Owner] | [Date] |
            | [Action item 2] | [Owner] | [Date] |

            ### Milestone Goals
            - [Goal 1]
            - [Goal 2]

            ---

            ## Resolutions & Consensus

            - [Resolution or consensus reached at this meeting 1]
            - [Resolution or consensus reached at this meeting 2]

            ---

            ## Next Meeting

            - **Expected Time**: [Date and time]
            - **Topic Direction**: [Main topics for the next meeting]
            """
        ),
        SummarizeTemplate(
            category: "Meeting Notes",
            name: "Key Points, Decisions, Tasks, Deadlines, and Actions",
            summary: "Uses a table format to highlight key points, decisions, tasks, deadlines, and follow-up actions.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Meeting Key Points & Task Tracking

            ## Basic Information

            | Item | Content |
            |------|------|
            | Meeting Topic | [Meeting topic] |
            | Meeting Date | [Date] |
            | Attendees | [Attendees] |
            | Meeting Duration | [Duration] |

            ---

            ## Key Points

            | # | Description |
            |------|----------|
            | 1 | [Point 1] |
            | 2 | [Point 2] |
            | 3 | [Point 3] |

            ---

            ## Decisions

            | # | Decision Item | Decision | Decision Maker |
            |------|----------|----------|--------|
            | 1 | [Item 1] | [Decision 1] | [Decision maker] |
            | 2 | [Item 2] | [Decision 2] | [Decision maker] |

            ---

            ## Task List

            | # | Task Description | Owner | Due Date | Priority |
            |------|----------|--------|----------|--------|
            | 1 | [Task 1] | [Owner] | [Date] | [High/Medium/Low] |
            | 2 | [Task 2] | [Owner] | [Date] | [High/Medium/Low] |
            | 3 | [Task 3] | [Owner] | [Date] | [High/Medium/Low] |

            ---

            ## Follow-up Actions

            | # | Action Item | Follow-up Owner | Expected Completion |
            |------|----------|--------|--------------|
            | 1 | [Action 1] | [Follow-up owner] | [Time] |
            | 2 | [Action 2] | [Follow-up owner] | [Time] |

            ---

            ## Open Items

            | # | Open Item | Confirmed By |
            |------|------------|--------|
            | 1 | [Open item 1] | [Confirmed by] |
            | 2 | [Open item 2] | [Confirmed by] |

            ---

            ## Additional Notes

            [Other notes or context information]
            """
        ),
        SummarizeTemplate(
            category: "Meeting Notes",
            name: "Meeting Minutes+",
            summary: "Focuses on agenda items, decisions, action items, and risks in meeting discussions.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Meeting Minutes

            ## Basic Information

            - **Meeting Topic**: [Topic]
            - **Meeting Date**: [Date]
            - **Meeting Duration**: [Duration]
            - **Attendees**: [List of names/roles]
            - **Host**: [Name]
            - **Recorder**: [Name]

            ---

            ## Agenda Items

            > List each agenda item in the actual order discussed at the meeting.

            ### Agenda Item 1: [Agenda title]

            - **Discussion Summary**: [Core discussion content]
            - **Main Disagreements**: [Differing opinions or points of contention, if any; omit if none]
            - **Discussion Conclusion**: [Consensus or conclusion reached on this agenda item]

            ### Agenda Item 2: [Agenda title]

            - **Discussion Summary**: [Core discussion content]
            - **Main Disagreements**: [Differing opinions or points of contention, if any; omit if none]
            - **Discussion Conclusion**: [Consensus or conclusion reached on this agenda item]

            ---

            ## Decision Log

            | Decision Item | Decision | Basis | Decision Maker |
            |----------|----------|----------|--------|
            | [Item]   | [Decision]   | [Basis]   | [Name] |
            | [Item]   | [Decision]   | [Basis]   | [Name] |

            ---

            ## Action Items

            | Action Item | Owner | Deadline | Notes |
            |----------|--------|----------|------|
            | [Item]   | [Name] | [Date]   | [Notes] |
            | [Item]   | [Name] | [Date]   | [Notes] |

            ---

            ## Risks & Open Issues

            | Risk/Issue Description | Impact Scope | Priority | Recommended Action |
            |---------------|----------|--------|----------|
            | [Description]        | [Scope]   | High/Medium/Low | [Recommendation]  |
            | [Description]        | [Scope]   | High/Medium/Low | [Recommendation]  |

            ---

            ## Outstanding Items

            - [Items not yet concluded that require follow-up at the next meeting]
            - [Information or resources requiring further confirmation]

            ---

            ## Next Meeting

            - **Expected Time**: [Date]
            - **Main Topics**: [Topics]
            - **Materials to Prepare**: [Materials]
            """
        ),
        // Speech
        SummarizeTemplate(
            category: "Speech",
            name: "Lecture Summary",
            summary: "For lectures, public talks, and experience-sharing sessions, highlighting the topic, key points, section content, and actionable insights.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Lecture Summary

            ## Basic Information
            - **Lecture Topic**: [Lecture topic]
            - **Lecture Date**: [Lecture date]
            - **Speaker**: [Speaker]
            - **Target Audience**: [Target audience]
            - **Lecture Background/Objective**: [Lecture background or objective]

            ## Overview
            - **Core Theme**: [Core theme of this lecture]
            - **Key Points**
              - [Point 1]
              - [Point 2]
              - [Point 3]

            ## Section Summaries

            ### Part 1: [Section name]
            - **Main Content**
              - [Content point 1]
              - [Content point 2]

            - **Key Viewpoints**
              - [Viewpoint 1]
              - [Viewpoint 2]

            - **Cases/Methods**
              - [Case, experience, or method]

            ### Part 2: [Section name]
            - **Main Content**
              - [Content point 1]
              - [Content point 2]

            - **Key Viewpoints**
              - [Viewpoint 1]
              - [Viewpoint 2]

            - **Cases/Methods**
              - [Case, experience, or method]

            ### Part 3: [Section name]
            - **Main Content**
              - [Content point 1]
              - [Content point 2]

            - **Key Viewpoints**
              - [Viewpoint 1]
              - [Viewpoint 2]

            - **Cases/Methods**
              - [Case, experience, or method]

            ## Takeaways & Insights
            - [Takeaway or insight 1]
            - [Takeaway or insight 2]
            - [Takeaway or insight 3]

            ## Recommendations & Action Items
            - **Actionable Recommendations**
              - [Recommendation 1]
              - [Recommendation 2]

            - **Follow-up Action Items**
              - [ ] **Action Item**: [Specific item]
                - **Owner**: [Owner, omit if not mentioned]
                - **Timeline**: [Timeline, omit if not mentioned]
                - **Notes**: [Additional notes]
            """
        ),
        SummarizeTemplate(
            category: "Speech",
            name: "Keynote Speech Summary",
            summary: "For keynote speeches, sharing sessions, public talks, and similar scenarios, highlighting the main thesis, structured content, key viewpoints, and actionable takeaways.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # [Speech Title]

            ## Basic Information

            - **Speaker**: [Name / Title]
            - **Speech Date**: [Date]
            - **Occasion**: [Event name / Conference name]
            - **Speech Duration**: [Duration]

            ---

            ## Core Thesis

            [Summarize the central idea and core position of this speech in 2–3 sentences]

            ---

            ## Content Structure

            ### Opening
            [How the speaker introduces the topic, including background setup, problem statement, or story lead-in]

            ### Main Body

            #### I. [First section topic]
            [Core content and reasoning logic of this section]

            #### II. [Second section topic]
            [Core content and reasoning logic of this section]

            #### III. [Third section topic]
            [Core content and reasoning logic of this section]

            ### Closing
            [The speaker's summary, call to action, or closing approach]

            ---

            ## Key Viewpoints

            - [Viewpoint 1]
            - [Viewpoint 2]
            - [Viewpoint 3]
            - [Viewpoint 4]

            ---

            ## Notable Quotes

            > [A memorable direct quote or highly condensed statement]

            > [A memorable direct quote or highly condensed statement]

            ---

            ## Data & Case Studies

            | Type | Content | Source/Background |
            |------|------|------------|
            | Data | [Data content] | [Source] |
            | Case | [Case overview] | [Background] |

            ---

            ## Actionable Takeaways

            - [ ] [Actionable recommendation based on the speech, 1]
            - [ ] [Actionable recommendation based on the speech, 2]
            - [ ] [Actionable recommendation based on the speech, 3]

            ---

            ## Further Reflection

            [Deeper questions raised by the speech, topics for further discussion, or directions worth further research]
            """
        ),
        SummarizeTemplate(
            category: "Speech",
            name: "Training Overview",
            summary: "For job training and process explanation scenarios. (Overview: key points, notes, special cases, and to-do items)",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Training Overview

            ## Basic Information

            - **Training Topic**: [Topic]
            - **Training Date**: [Date]
            - **Instructor**: [Name]
            - **Participants**: [Scope of participants]

            ---

            ## Overview

            [Briefly describe the overall content of this training, explaining its purpose and core direction]

            ---

            ## Key Points

            - [Point 1]
            - [Point 2]
            - [Point 3]

            ---

            ## Process Explanation

            1. **[Process step 1]**: [Explanation]
            2. **[Process step 2]**: [Explanation]
            3. **[Process step 3]**: [Explanation]

            ---

            ## Notes

            - [Note 1]
            - [Note 2]
            - [Note 3]

            ---

            ## Handling Special Cases

            | Case Description | Handling Method |
            |----------|----------|
            | [Case 1] | [Handling method] |
            | [Case 2] | [Handling method] |

            ---

            ## To-Do Items

            | Item | Owner | Due Date |
            |------|--------|----------|
            | [Item 1] | [Owner] | [Date] |
            | [Item 2] | [Owner] | [Date] |

            ---

            ## Additional Notes

            [Other content to record, such as reference materials, further explanations, etc.]
            """
        ),
        // Call
        SummarizeTemplate(
            category: "Call",
            name: "Phone Discussion Notes",
            summary: "For phone discussions, issue coordination, and plan confirmation calls, highlighting the topic, conclusions, rationale, and follow-up items.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Phone Discussion Notes

            ## Basic Information

            - **Call Date**: [Date]
            - **Participants**: [Name/Role]
            - **Call Duration**: [Duration]
            - **Topic**: [Topic]

            ---

            ## Background

            [Briefly describe what prompted this call and why the discussion was initiated]

            ---

            ## Key Topics

            ### Topic 1: [Topic name]

            - **Discussion**: [Main content discussed for this topic]
            - **Positions**: [Views or positions of each party]
            - **Conclusion Reached**: [Conclusion or decision on this topic]

            ### Topic 2: [Topic name]

            - **Discussion**: [Main content discussed for this topic]
            - **Positions**: [Views or positions of each party]
            - **Conclusion Reached**: [Conclusion or decision on this topic]

            ---

            ## Key Conclusions

            | Item | Conclusion | Rationale |
            |------|------|----------|
            | [Item] | [Conclusion] | [Rationale] |
            | [Item] | [Conclusion] | [Rationale] |

            ---

            ## Open Disagreements

            [Record issues not yet agreed upon or matters requiring further confirmation; omit if none]

            ---

            ## Follow-Up Actions

            | Action Item | Owner | Due Date |
            |----------|--------|----------|
            | [Action item] | [Owner] | [Date] |
            | [Action item] | [Owner] | [Date] |

            ---

            ## Additional Notes

            [Record any additional information, reference materials, or other points mentioned during the call; omit if none]
            """
        ),
        SummarizeTemplate(
            category: "Call",
            name: "Manager/Employee 1:1 Meeting",
            summary: "Ideal for manager/employee check-ins, regular check-ins, development conversations, or 1:1 meetings.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # 1:1 Meeting Summary

            ## Basic Information
            - **Meeting Date**: [Date]
            - **Participants**: [Manager name] / [Employee name]
            - **Meeting Duration**: [Duration]
            - **Meeting Type**: [Regular check-in / Development planning / Issue discussion / Other]

            ---

            ## Key Topics
            > The main topics or goals this meeting focused on

            - [Topic 1]
            - [Topic 2]
            - [Topic 3]

            ---

            ## Progress & Status
            > The employee's current work progress and goal completion status

            - **Going Well**: [Items where progress is currently good]
            - **Blockers**: [Difficulties or sticking points encountered]
            - **Support Needed**: [Resources or assistance the employee would like]

            ---

            ## Key Feedback
            > Key feedback and views raised by both sides during the meeting

            **Manager Feedback**
            - [Feedback point]

            **Employee Feedback**
            - [Feedback point]

            ---

            ## Growth & Development
            > Discussion related to career development, skill-building, or personal goals

            - **Development Direction**: [Employee's development goals or desired direction]
            - **Focus Areas**: [Capabilities or areas that need strengthening]
            - **Support Plan**: [Development support or recommendations provided by the manager]

            ---

            ## Action Items
            > Specific to-do items agreed upon in the meeting, with clear owners and deadlines

            | Item | Owner | Due Date |
            |------|--------|----------|
            | [Action item 1] | [Owner] | [Date] |
            | [Action item 2] | [Owner] | [Date] |
            | [Action item 3] | [Owner] | [Date] |

            ---

            ## Follow-Up
            - **Next Meeting Date**: [Date]
            - **Key Items to Revisit**: [Content to prioritize reviewing at the next meeting]
            - **Additional Notes**: [Other information worth recording]
            """
        ),
        SummarizeTemplate(
            category: "Call",
            name: "Customer Call Summary/Analysis",
            summary: "Summary and analysis of a customer call, with an assessment of tone and empathy toward the customer",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Customer Call Summary & Analysis

            ## Basic Information

            - **Call Date**: [Date]
            - **Call Duration**: [Duration]
            - **Agent**: [Name]
            - **Customer ID/Name**: [Customer information]
            - **Call Type**: [Inquiry / Complaint / After-sales / Follow-up / Other]

            ---

            ## Call Overview

            [Briefly describe the background, cause, and overall situation of this call in 2–3 sentences]

            ---

            ## Customer Request

            ### Main Issue
            [The core issue or need raised by the customer during this call]

            ### Emotional State
            [The customer's overall emotional presentation, e.g., calm, anxious, dissatisfied, upset, with a brief explanation of the cause]

            ---

            ## Call Summary

            ### Resolution Process
            [Outline the key communication milestones in chronological order, summarizing how the agent responded to the customer's request]

            ### Final Outcome
            [The outcome at the end of the call, e.g., issue resolved, escalated, pending follow-up]

            ---

            ## Tone & Communication Assessment

            ### Tone Appropriateness
            **Score**: [1–5]
            [Assess whether the agent's language was polite and professional, whether the tone was steady, and whether there was any inappropriate wording or emotional language]

            ### Empathy
            **Score**: [1–5]
            [Assess whether the agent actively listened, understood the customer's emotions, acknowledged the customer's feelings, and made the customer feel valued]

            ### Pacing & Control
            **Score**: [1–5]
            [Assess whether the agent effectively guided the direction of the conversation, could stabilize the situation when the customer was upset, and whether the pacing of the call was reasonable]

            ### Overall Score
            **Overall Rating**: [1–5]
            [Overall assessment of communication performance during this call]

            ---

            ## Strengths & Areas for Improvement

            ### Strengths
            - [Strength 1]
            - [Strength 2]

            ### Areas for Improvement
            - [Weakness 1]
            - [Weakness 2]

            ---

            ## Follow-Up Items

            | Follow-Up Item | Owner | Expected Completion |
            |------|------|--------|
            | [Item] | [Name] | [Date] |

            ---

            ## Summary & Recommendations

            [Based on this call, provide specific improvement suggestions or positive reinforcement for the agent, focused on communication skills and service quality]
            """
        ),
        SummarizeTemplate(
            category: "Call",
            name: "Business Call",
            summary: "Business call report",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Business Call Summary

            ## Basic Information
            - **Call Date**: [Date]
            - **Call Duration**: [Duration]
            - **Participants**: [Own name/title] · [Other party's name/title/company]
            - **Topic**: [Topic]

            ## Call Overview
            [Briefly describe the background and main purpose of the call in 2–3 sentences]

            ## Discussion Points
            ### 1. [Point 1 title]
            [Discussion content and conclusion for this topic]

            ### 2. [Point 2 title]
            [Discussion content and conclusion for this topic]

            ### 3. [Point 3 title]
            [Discussion content and conclusion for this topic]

            ## Key Agreements
            - [Agreement or confirmed item reached by both parties]
            - [Agreement or confirmed item reached by both parties]

            ## Items Pending Confirmation
            - [Unresolved issues or matters requiring further clarification]
            - [Unresolved issues or matters requiring further clarification]

            ## Follow-Up Actions
            | Action Item | Owner | Due Date |
            |--------|------|--------|
            | [Action item] | [Owner] | [Date] |
            | [Action item] | [Owner] | [Date] |

            ## Notes
            [Other supplementary information worth recording, such as special commitments or risk warnings]
            """
        ),
        // Interview
        SummarizeTemplate(
            category: "Interview",
            name: "Interview Notes",
            summary: "For research interviews, news interviews, in-depth interviews, and similar scenarios, highlighting background, core viewpoints, key Q&A, and follow-up.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Interview Notes Summary

            ## Basic Information

            - **Interview Topic**: [Topic]
            - **Interview Date**: [Date]
            - **Interview Duration**: [Duration]
            - **Format**: [Online / In-person / Phone]
            - **Interviewer**: [Name / Organization]
            - **Interviewee**: [Name]
            - **Interviewee Background**: [Brief description of role, field, or identity]

            ---

            ## Interview Overview

            [Briefly describe the core topics, overall tone, and main direction of this interview, in 100 words or fewer]

            ---

            ## Interviewee's Core Viewpoints

            > Distill the most central and representative positions and judgments expressed by the interviewee

            1. [Core viewpoint 1]
            2. [Core viewpoint 2]
            3. [Core viewpoint 3]

            ---

            ## Key Q&A Summary

            ### Question 1: [Question topic]
            - **Question**: [Question content]
            - **Response Summary**: [Core content of the interviewee's answer]

            ### Question 2: [Question topic]
            - **Question**: [Question content]
            - **Response Summary**: [Core content of the interviewee's answer]

            ### Question 3: [Question topic]
            - **Question**: [Question content]
            - **Response Summary**: [Core content of the interviewee's answer]

            ---

            ## Key Information & Data

            - [Important data, events, cases, or citations mentioned by the interviewee]
            - [Key information 2]
            - [Key information 3]

            ---

            ## Disagreements & Points of Contention

            [Record any differences of opinion, unresolved topics, or issues the interviewee avoided or was vague about; if none, write "None"]

            ---

            ## Threads for Further Exploration

            - [Topics or people mentioned but not explored in depth]
            - [Information worth further verification or follow-up questioning]

            ---

            ## Follow-Up

            | Follow-Up Item | Owner | Expected Completion |
            |--------|------|----------|
            | [Item 1] | [Owner] | [Date] |
            | [Item 2] | [Owner] | [Date] |

            ---

            ## Summary & Assessment

            [Overall assessment of this interview: informational value, the interviewee's level of cooperation, topic coverage completeness, and its reference value for subsequent work]
            """
        ),
        SummarizeTemplate(
            category: "Interview",
            name: "Panel Discussion",
            summary: "For panel discussions, seminars, webinars, or public discussions involving multiple speakers. (Overview: quick summary, background, discussion highlights, panelist insights, key points per topic)",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # [Discussion Topic] Panel Discussion Summary

            ## Basic Information

            - **Discussion Topic**: [Topic]
            - **Date**: [Date]
            - **Format**: [Format, e.g., online webinar / in-person roundtable / public discussion]
            - **Moderator**: [Name]
            - **Panelists**: [Panelist names and titles, separated by commas for multiple panelists]

            ---

            ## Quick Summary

            > [Summarize the core content and main conclusions of this discussion in 3–5 sentences for a quick overview.]

            ---

            ## Background

            [Briefly describe the background, purpose, and framing of this discussion, explaining its significance or the industry/social context it sits in.]

            ---

            ## Key Topics & Highlights

            ### Topic 1: [Topic name]

            - [Point]
            - [Point]
            - [Point]

            ### Topic 2: [Topic name]

            - [Point]
            - [Point]
            - [Point]

            ### Topic 3: [Topic name]

            - [Point]
            - [Point]
            - [Point]

            > If there are additional topics, add them following the same structure.

            ---

            ## Panelists' Core Viewpoints

            ### [Panelist name]

            - **Core Position**: [This panelist's main viewpoint or position]
            - **Key Evidence**: [Main supporting evidence or cases for their viewpoint]
            - **Representative Quote**: [Direct quote or key line]

            ### [Panelist name]

            - **Core Position**: [This panelist's main viewpoint or position]
            - **Key Evidence**: [Main supporting evidence or cases for their viewpoint]
            - **Representative Quote**: [Direct quote or key line]

            ### [Panelist name]

            - **Core Position**: [This panelist's main viewpoint or position]
            - **Key Evidence**: [Main supporting evidence or cases for their viewpoint]
            - **Representative Quote**: [Direct quote or key line]

            ---

            ## Points of Debate & Consensus

            | Topic | Point of Disagreement | Point of Consensus |
            |------|--------|--------|
            | [Topic] | [Main disagreement] | [Agreed-upon content] |
            | [Topic] | [Main disagreement] | [Agreed-upon content] |

            ---

            ## Conclusions & Takeaways

            - [Conclusion or takeaway]
            - [Conclusion or takeaway]
            - [Conclusion or takeaway]

            ---

            ## Follow-Up

            - [ ] [Follow-up item or action item]
            - [ ] [Follow-up item or action item]
            - [ ] [Follow-up item or action item]
            """
        ),
        // Medical
        SummarizeTemplate(
            category: "Medical",
            name: "Case Record",
            summary: "For medical consultations and case documentation, using the standard Subjective, Objective, Assessment, and Plan structure while avoiding placeholder-value contamination.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Case Record

            ## Basic Information

            | Item | Details |
            |------|------|
            | Visit Date | [Visit date] |
            | Patient Name | [Patient name] |
            | Gender | [Gender] |
            | Age | [Age] |
            | Department | [Department] |
            | Attending Physician | [Attending physician] |
            | Medical Record Number | [Medical record number] |

            ---

            ## Subjective

            ### Chief Complaint
            [The patient's main symptom(s) and duration]

            ### History of Present Illness
            [Onset and progression of symptoms, accompanying symptoms, triggers, and aggravating or relieving factors]

            ### Past Medical History
            [Past illnesses, surgeries, injuries, and hospitalizations]

            ### Medication History
            [Current and recent medication use, including drug names, dosages, and duration]

            ### Allergy History
            [Drug, food, or other substance allergies]

            ### Family History
            [Family history relevant to this visit]

            ---

            ## Objective

            ### Vital Signs

            | Item | Value |
            |------|------|
            | Temperature | [Temperature] |
            | Pulse | [Pulse] |
            | Respiratory Rate | [Respiratory rate] |
            | Blood Pressure | [Blood pressure] |
            | Oxygen Saturation | [Oxygen saturation] |
            | Height / Weight | [Height] / [Weight] |

            ### Physical Examination
            [Positive and relevant negative findings across body systems]

            ### Diagnostic Tests
            [Summary of laboratory results, imaging results, and other diagnostic test findings]

            ---

            ## Assessment

            ### Preliminary Diagnosis
            [Diagnosis or differential diagnosis based on subjective and objective findings]

            ### Diagnostic Rationale
            [Key subjective and objective evidence supporting the above diagnosis]

            ### Differential Diagnosis
            [Other possible diagnoses to rule out, and the key distinguishing factors]

            ---

            ## Plan

            ### Further Testing
            [Additional tests to be completed and their purpose]

            ### Treatment Plan
            [Specific plan, e.g., medication, surgery, physical therapy]

            ### Instructions & Precautions
            [Diet, activity, lifestyle adjustments, and special precautions]

            ### Follow-Up Schedule
            [Follow-up visit timing, cycle, and monitoring indicators]

            ---

            ## Additional Notes
            [Other information worth recording, such as patient compliance or key communication points]
            """
        ),
        SummarizeTemplate(
            category: "Medical",
            name: "Psychotherapy Session Record",
            summary: "A psychotherapy session record template designed for the mental health field, used to document a client's diagnosis, history, and treatment plan.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Psychotherapy Session Record

            ## Basic Information
            - **Client ID**: [Client ID]
            - **Therapist**: [Therapist name]
            - **Session Date**: [Date]
            - **Session Duration**: [Duration]
            - **Session Number**: Session [Number]
            - **Session Format**: [Individual / Group / Family / Online]

            ---

            ## Presenting Concern & Current Status
            [The client's core concerns, main issues, and current life situation raised in this session]

            ---

            ## Emotional & Psychological Status Assessment
            - **Emotional State**: [Describe the overall emotional tone the client presented during this session, e.g., anxious, low, stable]
            - **Cognitive State**: [Describe thought coherence, attention, sense of reality, etc.]
            - **Behavioral Presentation**: [Describe behavioral responses during the session, e.g., avoidance, cooperation, defensiveness]
            - **Risk Assessment**: [Whether there is risk of self-harm, suicide, or harm to others; if none, note "No concerns observed"]

            ---

            ## Session Content Summary
            [Structured summary of the main content of this session, including key events, emotional experiences, and cognitive patterns shared by the client]

            ---

            ## Key Information & Themes
            - [Theme 1]
            - [Theme 2]
            - [Theme 3]

            ---

            ## Therapeutic Intervention
            - **Techniques Used**: [e.g., cognitive restructuring, exposure therapy, empty chair technique, mindfulness exercises]
            - **Intervention Process**: [Describe the therapist's main intervention strategy in this session and the client's response]
            - **Client's Reaction**: [The client's emotional and cognitive response to the intervention]

            ---

            ## Connection to History & Background
            [Analysis of how this session's content relates to past history, childhood experiences, significant relationships, or prior trauma]

            ---

            ## Treatment Progress Assessment
            - **Progress Toward Treatment Goals**: [Current progress relative to the established treatment goals]
            - **Changes & Breakthroughs**: [Signs of growth or shifts in the client's thinking observed in this session]
            - **Resistance & Challenges**: [Resistance encountered in treatment or issues yet to be resolved]

            ---

            ## Next Steps in Treatment
            - **Focus for Next Session**: [Topics planned to be prioritized in the next session]
            - **Homework Assigned**: [Exercises or observation tasks assigned to the client; if none, note "None at this time"]
            - **Treatment Adjustment Recommendations**: [Whether adjustments to session frequency, direction, or other interventions are needed]

            ---

            ## Therapist's Notes
            [The therapist's personal observations, awareness of countertransference, or items requiring further supervision from this session]
            """
        ),
        SummarizeTemplate(
            category: "Medical",
            name: "Medical Consultation",
            summary: "For doctors or patients who want a well-organized consultation summary",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Medical Consultation Summary

            ## Basic Information
            - **Visit Date**: [Date]
            - **Visit Type**: [Outpatient / Consultation / Follow-up / Return visit]
            - **Department / Specialty**: [Department name]
            - **Attending Physician**: [Physician name and title]
            - **Patient Information**: [Basic characteristics such as age, gender]

            ---

            ## Chief Complaint & History of Present Illness
            [Description of the patient's main symptoms for this visit, including onset time, duration, progression, and accompanying symptoms]

            ---

            ## Past Medical History & Current Medications
            - **Past Illnesses**: [Previously diagnosed conditions or surgical history]
            - **Allergy History**: [Drug or other allergies]
            - **Current Medications**: [Names, dosages, and duration of medications currently being taken]

            ---

            ## Examination & Assessment for This Visit
            - **Physical Examination**: [Key findings and abnormalities]
            - **Diagnostic Tests**: [Summary of relevant lab, imaging, or other test results]
            - **Physician's Assessment**: [The physician's overall judgment and analysis of the condition]

            ---

            ## Diagnosis
            - **Preliminary Diagnosis / Confirmed Diagnosis**: [Diagnosis name]
            - **Diagnostic Rationale**: [Key information supporting the diagnosis]
            - **Differential Diagnosis**: [Other possible diagnoses ruled out or pending]

            ---

            ## Treatment Plan
            - **Medication**: [Prescribed drug names, dosages, usage, and duration]
            - **Non-Medication Treatment**: [Surgery, physical therapy, lifestyle interventions, etc.]
            - **Precautions**: [Medication contraindications, dietary restrictions, activity recommendations, etc.]

            ---

            ## Patient Questions & Physician's Answers
            | Patient Question | Physician's Answer |
            |----------|----------|
            | [Question 1] | [Answer 1] |
            | [Question 2] | [Answer 2] |

            ---

            ## Follow-Up
            - **Return Visit Schedule**: [Follow-up visit time and purpose]
            - **Pending Tests**: [Tests or exams still to be completed]
            - **Monitoring Points**: [Symptoms or indicators requiring close attention]
            - **Emergency Guidance**: [What situations require immediate medical attention or contact with the physician]

            ---

            ## Consultation Notes
            [Other supplementary information worth recording, such as multidisciplinary consultation opinions or communication with family members]
            """
        ),
        // Sales
        SummarizeTemplate(
            category: "Sales",
            name: "BANT Customer Analysis",
            summary: "Built for B2B sales teams to efficiently capture and analyze customer needs, surfacing the key information sales reps need most. (Overview: assess budget, authority, need, and timeline.)",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # BANT Customer Analysis Report

            ## Basic Information

            - **Customer Company**: [Customer company name]
            - **Contact**: [Name and title]
            - **Communication Date**: [Date]
            - **Communication Channel**: [In person / Phone / Video call]
            - **Sales Owner**: [Name]

            ---

            ## Budget

            > Assessment of the customer's willingness and ability to invest in this purchase

            - **Budget Range**: [Specific amount or range]
            - **Budget Status**: [Confirmed / Pending approval / Not yet defined]
            - **Budget Cycle**: [Current fiscal year / Next fiscal year / No constraint]
            - **Additional Notes**: [Customer's attitude toward budget, constraints, or flexibility]

            ---

            ## Authority

            > Analysis of the key people involved in this purchase decision and their influence

            - **Final Decision Maker**: [Name and title]
            - **Evaluators Involved**: [Name and title]
            - **Decision Process**: [Individual decision / Committee approval / Requires upper-management sign-off]
            - **Key Influencers**: [People with significant influence on the decision, and their stance]
            - **Additional Notes**: [Level of leadership attention or internal resistance to this purchase]

            ---

            ## Need

            > The customer's core problems and expectations for a solution

            - **Core Pain Point**: [The main problem the customer explicitly stated]
            - **Business Goal**: [What the customer hopes to achieve through this purchase]
            - **Current Solution**: [Product or approach currently in use]
            - **Dissatisfaction and Gaps**: [What the current solution fails to address]
            - **Priority Focus**: [The feature or value the customer cares about most]
            - **Additional Notes**: [Implicit needs or unstated expectations]

            ---

            ## Timeline

            > The customer's purchasing cadence and key milestones

            - **Expected Decision Date**: [Specific date or range]
            - **Expected Go-Live Date**: [Specific date or range]
            - **Urgency**: [Very urgent / Planned / No clear timeline]
            - **Key Milestones**: [Important events or deadlines affecting the purchase process]
            - **Additional Notes**: [Factors that could cause delays]

            ---

            ## Opportunity Assessment

            - **Overall Rating**: [High / Medium / Low]
            - **Win Probability**: [Estimated percentage]
            - **Key Strengths**: [Our core competitive advantages in this opportunity]
            - **Potential Risks**: [Uncertain factors that could affect closing the deal]

            ---

            ## Next Steps

            | Action Item | Owner | Deadline |
            |--------|------|--------|
            | [Action item 1] | [Owner] | [Date] |
            | [Action item 2] | [Owner] | [Date] |
            | [Action item 3] | [Owner] | [Date] |
            """
        ),
        SummarizeTemplate(
            category: "Sales",
            name: "Sales Call / Customer Outreach",
            summary: "Summarize this conversation as a sales record. Cover customer needs, possible solutions, and the products discussed.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Sales Call Record

            ## Basic Information
            - **Date**: [Date]
            - **Customer Name / Company**: [Customer name or company]
            - **Sales Rep**: [Sales rep name]
            - **Channel**: [Channel, e.g. phone / in-person / video call]
            - **Call Duration**: [Duration]

            ---

            ## Customer Background
            [Briefly describe the customer's industry background, current business situation, or general context]

            ---

            ## Customer Needs
            ### Core Need
            [The customer's clearly stated core need or main problem to solve]

            ### Potential Need
            [Deeper needs, pain points, or future expectations implied or inferred from the conversation]

            ---

            ## Products / Services Discussed
            | Product / Service | Discussion Points | Customer Reaction |
            |:-----------:|:------:|:------:|
            | [Product name] | [Key points] | [Positive / Neutral / Concerned] |
            | [Product name] | [Key points] | [Positive / Neutral / Concerned] |

            ---

            ## Potential Solutions
            [Based on the customer's needs, outline the solution directions proposed or explored during this call]

            ---

            ## Customer Concerns and Objections
            - [Concern 1]
            - [Concern 2]
            - [Concern 3]

            ---

            ## Key Agreements
            [Consensus, points of agreement, or preliminary intent reached by both parties during this call]

            ---

            ## Follow-up
            | Item | Owner | Expected Date |
            |:---:|:----:|:------:|
            | [Follow-up item] | [Owner] | [Date] |
            | [Follow-up item] | [Owner] | [Date] |

            ---

            ## Overall Assessment
            - **Purchase Intent**: [High / Medium / Low]
            - **Expected Stage**: [Stage, e.g. initial contact / solution discussion / quoting / contract preparation]
            - **Notes**: [Other information worth recording]
            """
        ),
        SummarizeTemplate(
            category: "Sales",
            name: "Sales Discovery Call",
            summary: "Sales lead generation, cold-calling at scale, calls to action, buyer personas, company research, and opportunities",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Sales Discovery Call Summary

            ## Basic Information

            - **Call Date**: [Date]
            - **Call Duration**: [Duration]
            - **Sales Rep**: [Name / Title]
            - **Customer Contact**: [Name / Title]
            - **Company**: [Company name]
            - **Call Purpose**: [Core goal of this call]

            ---

            ## Customer Profile

            - **Industry**: [Industry]
            - **Company Size**: [Number of employees / Revenue scale]
            - **Business Focus**: [Brief description of main business]
            - **Decision Role**: [Contact's role in the purchase decision, e.g. decision maker / influencer / executor]
            - **Additional Background**: [Other information useful for assessing lead quality]

            ---

            ## Needs and Pain Points

            - **Explicitly Stated Needs**: [Needs the customer raised proactively during the call]
            - **Potential Pain Points**: [Implicit problems or business challenges inferred from the conversation]
            - **Current Solution**: [Product, solution, or vendor the customer currently uses]
            - **Dissatisfaction with Current Solution**: [Pain points or switching-intent signals shared by the customer]

            ---

            ## Opportunity Assessment

            - **Intent Level**: [High / Medium / Low]
            - **Budget Status**: [Clear budget / Vague budget / No budget yet]
            - **Purchase Timeline**: [Expected decision or purchase cycle]
            - **Competitive Landscape**: [Whether comparing other vendors, and which competitors]
            - **Opportunity Summary**: [Overall assessment of this call's opportunity value and priority]

            ---

            ## Key Discussion Points

            - [Key question or concern raised by the customer]
            - [Sales rep's core response or value proposition delivered]
            - [Consensus or preliminary intent reached by both parties]

            ---

            ## Customer Objections and Handling

            | Objection | Response | Outcome |
            |--------|--------|--------|
            | [Objection 1] | [Response] | [Resolved / Pending follow-up / Unresolved] |
            | [Objection 2] | [Response] | [Resolved / Pending follow-up / Unresolved] |

            ---

            ## Action Items

            - [ ] [Action item 1, with owner and deadline]
            - [ ] [Action item 2, with owner and deadline]
            - [ ] [Action item 3, with owner and deadline]

            ---

            ## Next Follow-up Plan

            - **Planned Follow-up Date**: [Date]
            - **Follow-up Method**: [Phone / Email / Visit / Demo]
            - **Follow-up Focus**: [Key points to advance or confirm in the next conversation]

            ---

            ## Call Summary

            [Overall assessment of this call, including customer attitude, effectiveness of the conversation, sales stage, and recommendations for next steps]
            """
        ),
        // Consulting
        SummarizeTemplate(
            category: "Consulting",
            name: "Client Needs",
            summary: "A tool built for consultants to efficiently gather and analyze client information, organizing the most critical details for downstream proposal work. (Overview: assess client background, pain points, and expectations.)",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Client Needs Analysis Summary

            ## Basic Information
            - **Client Name**: [Client name]
            - **Industry**: [Industry]
            - **Company Size**: [Company size]
            - **Meeting Date**: [Date]
            - **Consultant**: [Consultant name]

            ---

            ## Client Background
            [Briefly describe the client's business background, development stage, and current operating status]

            ---

            ## Core Pain Points
            > The main problems and challenges the client currently faces

            1. [Pain point 1]
            2. [Pain point 2]
            3. [Pain point 3]

            ---

            ## Needs and Expectations
            > Requirements or goals the client stated explicitly or implied

            | Need Type | Details | Priority |
            |------|------|----|
            | [Need type] | [Specific description] | High / Medium / Low |
            | [Need type] | [Specific description] | High / Medium / Low |
            | [Need type] | [Specific description] | High / Medium / Low |

            ---

            ## Available Resources and Constraints
            - **Available Resources**: [Budget range, team setup, existing tools, etc.]
            - **Constraints**: [Timeline, policy limits, technical bottlenecks, etc.]

            ---

            ## Key Decision Information
            - **Decision Maker**: [Name or role of the final decision maker]
            - **Decision Cycle**: [Expected decision timeline]
            - **Evaluation Criteria**: [The client's core considerations when choosing a solution]

            ---

            ## Competitive and Reference Context
            [Competitors, benchmarks, or previously tried solutions the client mentioned, along with their evaluation]

            ---

            ## Consultant's Insight
            > Overall judgment based on this conversation

            - **Authenticity of Need**: [Assessment of how well the stated need matches the actual need]
            - **Partnership Intent**: [The client's willingness to partner and urgency level]
            - **Potential Risks**: [Risk factors that could affect moving forward]

            ---

            ## Follow-up Plan
            - [ ] [Action item 1] - Owner: [Name] - Deadline: [Date]
            - [ ] [Action item 2] - Owner: [Name] - Deadline: [Date]
            - [ ] [Action item 3] - Owner: [Name] - Deadline: [Date]
            """
        ),
        SummarizeTemplate(
            category: "Consulting",
            name: "Discussion with Expert",
            summary: "For meetings between experts, aimed at extracting details and unique direct quotes.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Expert Discussion Minutes

            ## Basic Information
            - **Meeting Topic**: [Topic]
            - **Meeting Date**: [Date]
            - **Experts Present**: [Expert names and affiliations]
            - **Chairperson**: [Name]
            - **Notes Compiled By**: Auto-generated by AI

            ---

            ## Topic Overview
            [Briefly describe the core topic, background, and main purpose of this discussion, 2-4 sentences]

            ---

            ## Core Viewpoints

            ### [Expert name]
            - **Main Position**: [This expert's core argument or perspective]
            - **Key Points**:
              - [Point 1]
              - [Point 2]
              - [Point 3]
            - **Direct Quote**:
              > "[Representative quote]"

            ### [Expert name]
            - **Main Position**: [This expert's core argument or perspective]
            - **Key Points**:
              - [Point 1]
              - [Point 2]
              - [Point 3]
            - **Direct Quote**:
              > "[Representative quote]"

            ---

            ## Debate and Disagreements
            | Focus Topic | Positions | Key Disagreement |
            |--------|--------|--------|
            | [Topic] | [Expert A's view] vs [Expert B's view] | [Description of core disagreement] |
            | [Topic] | [Expert A's view] vs [Expert B's view] | [Description of core disagreement] |

            ---

            ## Consensus and Conclusions
            - [Consensus or conclusion 1 reached in this discussion]
            - [Consensus or conclusion 2 reached in this discussion]
            - [Consensus or conclusion 3 reached in this discussion]

            ---

            ## Notable Quotes
            > "[Noteworthy detailed statement or professional remark]"
            > —— [Expert name]

            > "[Noteworthy detailed statement or professional remark]"
            > —— [Expert name]

            ---

            ## Issues for Further Discussion
            - [Issue 1 not fully discussed or in dispute, needing follow-up]
            - [Issue 2 not fully discussed or in dispute, needing follow-up]

            ---

            ## Next Steps
            | Action Item | Owner | Expected Date |
            |--------|--------|--------|
            | [Item description] | [Name] | [Date] |
            | [Item description] | [Name] | [Date] |
            """
        ),
        SummarizeTemplate(
            category: "Consulting",
            name: "Senior Management Consultant",
            summary: "Management consultant",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Management Consulting Summary

            ## Basic Information
            - **Consultation Date**: [Date]
            - **Consultation Topic**: [Topic]
            - **Client/Company**: [Client name]
            - **Participants**: [Participants]
            - **Consultant**: [Consultant name]

            ---

            ## Background and Agenda
            [Briefly describe the business background, core agenda, and client's requests for this consultation, 2-4 sentences]

            ---

            ## Problem Diagnosis

            ### Core Issues
            - [Core issue 1]
            - [Core issue 2]
            - [Core issue 3]

            ### Root Cause Analysis
            - [Root cause 1]
            - [Root cause 2]

            ---

            ## Strategic Recommendations

            ### Short-term Initiatives (0-3 months)
            - [Short-term recommendation 1]
            - [Short-term recommendation 2]

            ### Mid-term Plan (3-12 months)
            - [Mid-term recommendation 1]
            - [Mid-term recommendation 2]

            ### Long-term Direction (1+ years)
            - [Long-term strategic direction]

            ---

            ## Key Insights
            > [The consultant's most important judgment or industry insight from this consultation, 1-3 items]

            - [Insight 1]
            - [Insight 2]
            - [Insight 3]

            ---

            ## Risk Alerts
            | Risk Item | Risk Level | Recommended Response |
            |----------|----------|----------|
            | [Risk 1] | [High/Medium/Low] | [Response measure] |
            | [Risk 2] | [High/Medium/Low] | [Response measure] |

            ---

            ## Action Plan
            | Action Item | Owner | Deadline | Priority |
            |----------|--------|----------|--------|
            | [Action 1] | [Owner] | [Deadline] | [High/Medium/Low] |
            | [Action 2] | [Owner] | [Deadline] | [High/Medium/Low] |
            | [Action 3] | [Owner] | [Deadline] | [High/Medium/Low] |

            ---

            ## Follow-up
            - **Next Consultation Date**: [Date]
            - **Items Pending Confirmation**: [Content pending confirmation]
            - **Client Commitments**: [Client's committed actions]

            ---

            ## Consultant's Notes
            [Consultant's additional notes on this consultation, unresolved items, or special reminders]
            """
        ),
        // Education
        SummarizeTemplate(
            category: "Education",
            name: "University Lecture",
            summary: "Turn each class session into a clear, in-depth, and easy-to-study chapter.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # [Course Name] Lecture [Chapter Number]

            ## Basic Information
            - **Course**: [Course name]
            - **Instructor**: [Teacher name]
            - **Lecture Date**: [Date]
            - **Topic of This Lecture**: [Core topic of this session]

            ---

            ## Overview
            > [Summarize the core content and main goals of this session in 2-4 sentences]

            ---

            ## Knowledge Points

            ### I. [Title of first main knowledge point]
            [Detailed explanation of this knowledge point, including definitions, principles, background, or derivation process]

            **Key Concepts**:
            - [Concept 1]: [Brief explanation]
            - [Concept 2]: [Brief explanation]

            ### II. [Title of second main knowledge point]
            [Detailed explanation of this knowledge point]

            **Key Concepts**:
            - [Concept 1]: [Brief explanation]
            - [Concept 2]: [Brief explanation]

            ### III. [Title of third main knowledge point]
            [Detailed explanation of this knowledge point]

            **Key Concepts**:
            - [Concept 1]: [Brief explanation]
            - [Concept 2]: [Brief explanation]

            ---

            ## Cases and Examples
            | Case Name | Related Knowledge Point | Key Explanation |
            |--------|----------|--------|
            | [Case 1] | [Related knowledge point] | [Brief explanation] |
            | [Case 2] | [Related knowledge point] | [Brief explanation] |

            ---

            ## Key Points and Difficulties

            **Key Points of This Lecture**:
            - [Key point 1]
            - [Key point 2]

            **Difficulties of This Lecture**:
            - [Difficulty 1 with brief explanation]
            - [Difficulty 2 with brief explanation]

            ---

            ## Teacher's Emphasis
            > [Content the teacher repeatedly emphasized, specifically flagged, or explicitly noted as an exam point during class]

            ---

            ## Knowledge Extension
            - **Connection to Prior Knowledge**: [Explain how this lecture connects to previous chapters]
            - **Connection to Upcoming Content**: [Explain what future content this lecture lays the groundwork for]
            - **Recommended Further Reading**: [Related books, papers, or materials mentioned by the teacher]

            ---

            ## After-Class Tasks
            - [ ] [Homework or task 1]
            - [ ] [Homework or task 2]
            - [ ] [Content needing review or further understanding]

            ---

            ## Lecture Summary
            [Concisely summarize the core takeaways of this session, distilling the 1-3 most valuable learning insights]
            """
        ),
        SummarizeTemplate(
            category: "Education",
            name: "University Course Compilation",
            summary: "For university courses, long-form lecture recordings, and similar scenarios; emphasizes structured retention of course content, knowledge points, and examples.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # [Course Name] Class Notes

            ## Basic Information

            - **Course Name**: [Course name]
            - **Instructor**: [Teacher name]
            - **Course Date**: [Date]
            - **Session Number**: Lecture [X]
            - **Topic of This Lecture**: [Core topic of this session]

            ---

            ## Overview

            > [Summarize the overall content, teaching goals, and instructional logic of this session in 2-4 sentences]

            ---

            ## Knowledge Point Details

            ### [Knowledge point 1 title]

            **Core Concept**: [Concept definition or core statement]

            **Detailed Explanation**:
            [Detailed explanation of this knowledge point, preserving the teacher's original intent and logic]

            **Related Examples**:
            - [Example 1]
            - [Example 2]

            ---

            ### [Knowledge point 2 title]

            **Core Concept**: [Concept definition or core statement]

            **Detailed Explanation**:
            [Detailed explanation of this knowledge point, preserving the teacher's original intent and logic]

            **Related Examples**:
            - [Example 1]
            - [Example 2]

            ---

            ### [Knowledge point 3 title]

            **Core Concept**: [Concept definition or core statement]

            **Detailed Explanation**:
            [Detailed explanation of this knowledge point, preserving the teacher's original intent and logic]

            **Related Examples**:
            - [Example 1]
            - [Example 2]

            ---

            ## Key Points and Difficulties

            ### Key Points of This Lecture

            - [Key point 1]
            - [Key point 2]
            - [Key point 3]

            ### Difficulties of This Lecture

            - [Difficulty 1, with brief explanation]
            - [Difficulty 2, with brief explanation]

            ---

            ## Knowledge Extension

            **Connection to Prior Content**: [Explain how this lecture connects to previous lectures or prerequisite knowledge]

            **Connection to Upcoming Content**: [Explain what future topics this lecture lays the groundwork for]

            **Extended References**:
            - [Recommended reading, reference, or extended concept 1]
            - [Recommended reading, reference, or extended concept 2]

            ---

            ## Teacher's Emphasis

            > [Record content the teacher repeatedly emphasized, specifically flagged, or previewed as an exam point during class]

            ---

            ## After-Class Tasks

            - [ ] [Homework or practice item 1]
            - [ ] [Homework or practice item 2]
            - [ ] [Content requiring independent preview or review]

            ---

            ## Study Notes

            [Record questions, personal reflections, or points needing further confirmation that arose while attending the lecture]
            """
        ),
        SummarizeTemplate(
            category: "Education",
            name: "Seminar / Lecture: Detailed Summary and Notes",
            summary: "Complete, structured notes and summary, without any additional AI commentary.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # [Lecture/Seminar Title]

            ## Basic Information

            - **Date**: [Date]
            - **Speaker**: [Name and title/organization]
            - **Moderator**: [Name] (if any)
            - **Subject Area**: [Field or discipline]
            - **Duration**: [Duration]

            ---

            ## Overview

            [Summarize the core topic, main content, and overall framework of this lecture in 3-5 sentences]

            ---

            ## Detailed Notes

            ### I. [First section title]

            [Detailed content of this section, recorded point by point following the original logic]

            - [Point 1]
            - [Point 2]
            - [Point 3]

            ### II. [Second section title]

            [Detailed content of this section]

            - [Point 1]
            - [Point 2]
            - [Point 3]

            ### III. [Third section title]

            [Detailed content of this section]

            - [Point 1]
            - [Point 2]
            - [Point 3]

            > Add or remove sections according to the actual content

            ---

            ## Core Viewpoints

            - [Viewpoint 1]
            - [Viewpoint 2]
            - [Viewpoint 3]

            ---

            ## Important Data and Quotes

            | Type | Content | Source/Background |
            |------|------|-----------|
            | Data | [Specific figures or statistics] | [Source description] |
            | Quote | [Direct quote] | [Speaker or source] |
            | Case | [Case name or description] | [Background description] |

            ---

            ## Q&A Session

            **Question 1**: [Question content]
            **Answer**: [Answer content]

            **Question 2**: [Question content]
            **Answer**: [Answer content]

            > If there is no Q&A session, remove this section

            ---

            ## Keywords

            [Keyword 1], [Keyword 2], [Keyword 3], [Keyword 4], [Keyword 5]
            """
        ),
        // Construction
        SummarizeTemplate(
            category: "Construction",
            name: "Acceptance Checklist",
            summary: "Designed for the construction industry, this acceptance checklist template efficiently records and analyzes key project details, ensuring all issues are thoroughly resolved. (Overview: summarize key items, track tasks, and provide AI feedback.)",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Construction Project Acceptance Checklist

            ## Basic Information
            - **Project Name**: [Project name]
            - **Acceptance Date**: [Acceptance date]
            - **Acceptance Location**: [Acceptance location]
            - **Acceptance Type**: [Acceptance type, e.g.: final acceptance / partial acceptance / concealed work acceptance]
            - **Participants**: [Names and roles]

            ---

            ## Overview
            [Briefly describe the overall status of this acceptance inspection, including scope, overall conclusion, and key areas of focus, 3-5 sentences]

            ---

            ## Acceptance Item Checklist

            ### Passed Items
            | No. | Acceptance Item | Result | Notes |
            |------|----------|----------|------|
            | 1 | [Acceptance item] | Passed | [Notes] |
            | 2 | [Acceptance item] | Passed | [Notes] |

            ### Items Requiring Rectification
            | No. | Issue Description | Location | Severity | Rectification Requirement | Rectification Deadline | Responsible Party |
            |------|----------|----------|----------|----------|----------|--------|
            | 1 | [Issue description] | [Specific location] | [Minor / Moderate / Severe] | [Rectification requirement] | [Rectification deadline] | [Responsible party] |
            | 2 | [Issue description] | [Specific location] | [Minor / Moderate / Severe] | [Rectification requirement] | [Rectification deadline] | [Responsible party] |

            ### Failed Items
            | No. | Item Name | Reason for Failure | Handling Method | Responsible Party |
            |------|----------|------------|----------|--------|
            | 1 | [Item name] | [Reason for failure] | [Rework / Reinforcement / Demolition and redo] | [Responsible party] |

            ---

            ## Key Issue Analysis
            [Summarize and analyze the main issues found during this acceptance inspection, explaining their causes, potential risks, and scope of impact]

            ---

            ## Rectification Follow-up Plan
            - **Priority Rectification Items**: [High-priority issues requiring immediate action]
            - **Phased Rectification Milestones**: [Completion timeline for rectification at each stage]
            - **Re-inspection Arrangement**: [Re-inspection time and responsible person]

            ---

            ## AI Overall Assessment
            [Based on the content of this acceptance inspection, provide an overall evaluation of project quality, construction compliance, and risk points, along with targeted recommendations]

            ---

            ## Next Action Items
            - [ ] [Action item] — Owner: [Name] — Deadline: [Date]
            - [ ] [Action item] — Owner: [Name] — Deadline: [Date]
            - [ ] [Action item] — Owner: [Name] — Deadline: [Date]
            """
        ),
        SummarizeTemplate(
            category: "Construction",
            name: "Engineering Project Meeting Minutes",
            summary: "For engineering projects, property management, claims inspections, and similar scenarios — highlights project background, attendees, area-by-area issues, and corrective actions.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Engineering Project Meeting Minutes

            ## Basic Information

            - **Meeting Topic**: [Meeting topic]
            - **Meeting Time**: [Meeting date] [Start time] — [End time]
            - **Meeting Location**: [Meeting location or project site name]
            - **Project Name**: [Name of the engineering project]
            - **Minutes Prepared By**: [Preparer]

            ---

            ## Attendees

            | Name | Organization / Department | Title / Role |
            |------|------------|------------|
            | [Name] | [Organization] | [Title] |
            | [Name] | [Organization] | [Title] |

            ---

            ## Project Background

            [Briefly describe the project's current phase, the reason for this meeting, and the background of the core agenda items]

            ---

            ## Agenda Overview

            [List the main topics discussed at this meeting, 2～5 items]

            1. [Topic 1]
            2. [Topic 2]
            3. [Topic 3]

            ---

            ## Area-by-Area Issues and Corrective Actions

            ### [Area / Building / Section Name 1]

            **Existing Issues:**
            - [Issue description]
            - [Issue description]

            **Corrective Actions:**
            - [Corrective requirement and approach]
            - [Corrective requirement and approach]

            **Responsible Unit / Person**: [Responsible party]
            **Correction Deadline**: [Completion date]

            ---

            ### [Area / Building / Section Name 2]

            **Existing Issues:**
            - [Issue description]
            - [Issue description]

            **Corrective Actions:**
            - [Corrective requirement and approach]
            - [Corrective requirement and approach]

            **Responsible Unit / Person**: [Responsible party]
            **Correction Deadline**: [Completion date]

            ---

            ## Key Resolutions

            1. [Resolution confirmed and approved by all parties]
            2. [Resolution confirmed and approved by all parties]
            3. [Resolution confirmed and approved by all parties]

            ---

            ## Cost and Resource Coordination

            | Item | Amount / Resources Involved | Responsible Party | Notes |
            |------|---------------|--------|------|
            | [Item name] | [Amount or resource description] | [Responsible party] | [Notes] |

            ---

            ## Follow-Up Items

            | No. | Follow-Up Item | Responsible Person | Deadline | Current Status |
            |------|---------|--------|---------|---------|
            | 1 | [Item description] | [Responsible person] | [Date] | Pending |
            | 2 | [Item description] | [Responsible person] | [Date] | In progress |

            ---

            ## Next Meeting Schedule

            - **Expected Time**: [Next meeting date]
            - **Meeting Format**: [In person / Online / TBD]
            - **Main Topics**: [Topics planned for next meeting]
            """
        ),
        SummarizeTemplate(
            category: "Construction",
            name: "Site Inspection",
            summary: "For recording observations and action items during a site inspection.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Site Inspection Record

            ## Basic Information

            - **Inspection Date**: [Date]
            - **Inspection Location**: [Location]
            - **Inspector(s)**: [Name/Title]
            - **Inspection Type**: [Routine inspection / Special inspection / Surprise inspection]
            - **Weather/Environmental Conditions**: [Environment description]

            ---

            ## Inspection Overview

            [Briefly describe the overall situation of this inspection, including scope, areas covered, and general impression]

            ---

            ## Site Observation Details

            ### [Area/Segment 1]

            - **Site Condition**: [Description]
            - **Issues Found**: [Issue description; enter "No anomalies observed" if none]
            - **Risk Level**: [High / Medium / Low / None]

            ### [Area/Segment 2]

            - **Site Condition**: [Description]
            - **Issues Found**: [Issue description; enter "No anomalies observed" if none]
            - **Risk Level**: [High / Medium / Low / None]

            ### [Area/Segment 3]

            - **Site Condition**: [Description]
            - **Issues Found**: [Issue description; enter "No anomalies observed" if none]
            - **Risk Level**: [High / Medium / Low / None]

            ---

            ## Issue Summary

            | No. | Issue Description | Area | Risk Level | Responsible Person |
            |------|----------|----------|----------|--------|
            | 1 | [Issue description] | [Area] | [Level] | [Name] |
            | 2 | [Issue description] | [Area] | [Level] | [Name] |
            | 3 | [Issue description] | [Area] | [Level] | [Name] |

            ---

            ## Corrective Requirements

            - **Immediate Correction**: [Items requiring immediate action]
            - **Time-Bound Correction**: [Corrective item] — Deadline: [Date]
            - **Ongoing Monitoring**: [Items requiring continued attention]

            ---

            ## Action Items

            - [ ] [Action item 1] — Owner: [Name] — Deadline: [Date]
            - [ ] [Action item 2] — Owner: [Name] — Deadline: [Date]
            - [ ] [Action item 3] — Owner: [Name] — Deadline: [Date]

            ---

            ## Inspection Conclusion

            [Overall assessment of this inspection, including on-site compliance, key risk points, and general recommendations]

            ---

            ## Next Inspection Schedule

            - **Planned Date**: [Date]
            - **Focus Areas**: [Areas or items to prioritize in the next inspection]
            """
        ),
        // IT & Engineering
        SummarizeTemplate(
            category: "IT & Engineering",
            name: "Multi-Participant Project Team Meeting",
            summary: "For meetings with multiple participants in complex technical projects. Includes action items and team sentiment analysis",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Project Team Meeting Summary

            ## Basic Information

            | Project Name | [Project name] |
            |----------|------------|
            | Meeting Topic | [Meeting topic] |
            | Meeting Time | [Date] [Start time] — [End time] |
            | Meeting Location | [Online/Offline/Location] |
            | Chairperson   | [Name] |
            | Minutes Taker   | [Name] |

            ### Attendees

            | Name | Role / Responsibility |
            |------|------------|
            | [Name] | [Role] |
            | [Name] | [Role] |
            | [Name] | [Role] |

            ---

            ## Meeting Agenda

            1. [Topic 1]
            2. [Topic 2]
            3. [Topic 3]

            ---

            ## Topic Discussion Details

            ### [Topic 1]

            **Discussion Summary**
            [Brief description of the core discussion content for this topic]

            **Key Viewpoints**
            - [Participant name]: [Viewpoint content]
            - [Participant name]: [Viewpoint content]
            - [Participant name]: [Viewpoint content]

            **Conclusion / Consensus**
            [Conclusion or consensus reached on this topic]

            ---

            ### [Topic 2]

            **Discussion Summary**
            [Brief description of the core discussion content for this topic]

            **Key Viewpoints**
            - [Participant name]: [Viewpoint content]
            - [Participant name]: [Viewpoint content]

            **Conclusion / Consensus**
            [Conclusion or consensus reached on this topic]

            ---

            ## Key Decisions

            | Decision Item | Decision Outcome | Basis | Owner |
            |----------|----------|----------|--------|
            | [Item]   | [Outcome]   | [Basis]   | [Name] |
            | [Item]   | [Outcome]   | [Basis]   | [Name] |

            ---

            ## Action Item Tracking

            | No. | Action Item | Owner | Collaborator | Deadline | Priority | Status |
            |------|----------|--------|--------|----------|--------|------|
            | A1   | [Item description] | [Name] | [Name] | [Date] | High / Medium / Low | Not started |
            | A2   | [Item description] | [Name] | [Name] | [Date] | High / Medium / Low | Not started |
            | A3   | [Item description] | [Name] | [Name] | [Date] | High / Medium / Low | Not started |

            ---

            ## Risks and Blockers

            | Risk / Blocker | Scope of Impact | Response Measure | Follow-Up Owner |
            |-------------|----------|----------|--------|
            | [Description]      | [Scope]   | [Measure]   | [Name] |
            | [Description]      | [Scope]   | [Measure]   | [Name] |

            ---

            ## Team Sentiment and Atmosphere Analysis

            ### Overall Atmosphere

            [Comprehensive description of the overall atmosphere of this meeting, e.g.: positive collaboration, existing disagreements, high pressure, etc.]

            ### Individual Sentiment Status

            | Participant | Sentiment Trend | Key Signals |
            |--------|----------|----------|
            | [Name] | [Positive / Neutral / Negative] | [Summary of language or behavioral traits] |
            | [Name] | [Positive / Neutral / Negative] | [Summary of language or behavioral traits] |
            | [Name] | [Positive / Neutral / Negative] | [Summary of language or behavioral traits] |

            ### Points of Disagreement and Tension

            - [Describe segments with obvious disagreement or tension during the meeting and the reasons]
            - [If no obvious disagreement, enter "The overall atmosphere of this meeting was harmonious, with no obvious disagreements"]

            ### Team Collaboration Recommendations

            - [Collaboration improvement recommendations based on sentiment analysis]
            - [Recommendations for attending to members with low morale]

            ---

            ## Outstanding Issues

            - [Issues not resolved in this meeting that require follow-up]
            - [Items requiring further research or evaluation]

            ---

            ## Next Meeting Schedule

            | Expected Time | [Date time] |
            |----------|-------------|
            | Topic Direction | [Main direction planned for next meeting] |
            | Chairperson   | [Name] |
            """
        ),
        SummarizeTemplate(
            category: "IT & Engineering",
            name: "IT Knowledge Transfer Meeting",
            summary: "Designed for different types of meetings to enable IT knowledge transfer.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # IT Knowledge Transfer Meeting Summary

            ## Basic Information

            - **Meeting Topic**: [Meeting topic]
            - **Knowledge Transfer Type**: [System handover / Technical training / Documentation walkthrough / Process handoff / Other]
            - **Presenter**: [Presenter name and role]
            - **Attendees**: [Attendee names and roles]
            - **Meeting Date**: [Date]
            - **Meeting Duration**: [Duration]

            ---

            ## Knowledge Background

            [Briefly describe the background of this knowledge transfer, including the systems, projects, business modules, or technical areas involved, and the reason or trigger for initiating it.]

            ---

            ## Core Knowledge Points

            ### 1. [Knowledge module 1]

            [Overview of the core content of this module, including principles, logic, or technical explanation.]

            ### 2. [Knowledge module 2]

            [Overview of the core content of this module.]

            ### 3. [Knowledge module 3]

            [Overview of the core content of this module.]

            > Add additional modules as needed.

            ---

            ## Systems and Tools

            | System / Tool Name | Purpose | Access Method / Permission Requirements |
            |:-----------:|:------:|:------------:|
            | [Name] | [Purpose] | [Description] |
            | [Name] | [Purpose] | [Description] |

            ---

            ## Key Operating Procedures

            ### [Procedure name 1]

            1. [Step 1]
            2. [Step 2]
            3. [Step 3]

            ### [Procedure name 2]

            1. [Step 1]
            2. [Step 2]
            3. [Step 3]

            ---

            ## Precautions and Risk Notes

            - **[Precaution 1]**: [Specific description, including potential risks or common mistakes.]
            - **[Precaution 2]**: [Specific description.]
            - **[Precaution 3]**: [Specific description.]

            ---

            ## Outstanding Issues and Items Pending Confirmation

            | Issue Description | Owner | Estimated Resolution Time |
            |:------:|:----:|:--------:|
            | [Issue description] | [Owner] | [Date] |
            | [Issue description] | [Owner] | [Date] |

            ---

            ## Follow-Up Items

            - [ ] [Action item 1] — Owner: [Name], Deadline: [Date]
            - [ ] [Action item 2] — Owner: [Name], Deadline: [Date]
            - [ ] [Action item 3] — Owner: [Name], Deadline: [Date]

            ---

            ## Reference Documents and Resources

            - [Document name / link]
            - [Document name / link]

            ---

            ## Summary and Recommendations

            [Overall assessment of the effectiveness of this knowledge transfer, noting whether knowledge coverage is complete, the recipient's level of understanding, and recommendations for follow-up reinforcement, documentation improvement, or additional training.]
            """
        ),
        SummarizeTemplate(
            category: "IT & Engineering",
            name: "Troubleshooting Summary",
            summary: "Issue resolution and troubleshooting summary.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Troubleshooting Summary

            ## Basic Information
            - **Date**: [Date]
            - **Incident ID**: [Incident ID]
            - **Owner**: [Owner]
            - **Participants**: [Participants]
            - **Duration**: [Incident duration]

            ---

            ## Incident Overview
            [Briefly describe the core symptoms, scope of impact, and severity of the incident in 2–3 sentences]

            ---

            ## Incident Symptoms
            - **First Detected**: [Time]
            - **Detection Method**: [Alert triggered / User report / Proactive monitoring / Other]
            - **Scope of Impact**: [Affected systems, services, users, or business modules]
            - **Symptom Description**: [Specific abnormal behavior, such as error messages, service unavailability, performance degradation, etc.]

            ---

            ## Investigation Process

            ### Initial Assessment
            [Initial direction and hypothesis after the incident occurred]

            ### Investigation Steps
            1. [Investigation step 1]
            2. [Investigation step 2]
            3. [Investigation step 3]

            ### Key Findings
            - [Important clues or abnormal data found during investigation]
            - [Key logs, metrics, or symptoms]

            ---

            ## Root Cause
            [Clearly state the root cause of the incident, distinguishing between direct cause and underlying cause]

            - **Direct Cause**: [Specific factor that directly triggered the incident]
            - **Underlying Cause**: [Systemic, procedural, or configuration issue behind it]

            ---

            ## Solution

            ### Temporary Mitigation
            [Emergency measures or temporary workaround taken during the incident]

            ### Permanent Fix
            [Measures taken to fully resolve the issue]

            ---

            ## Verification Results
            - **Recovery Time**: [Time when service returned to normal]
            - **Verification Method**: [How the resolution was confirmed]
            - **Current Status**: [Fully recovered / Partially recovered / Ongoing monitoring]

            ---

            ## Follow-Up Actions
            | Action Item | Owner | Planned Completion Time |
            |--------|------|----------|
            | [Action item 1] | [Owner] | [Date] |
            | [Action item 2] | [Owner] | [Date] |

            ---

            ## Lessons Learned
            - **Lessons and Reflections**: [Issues or shortcomings exposed by this incident]
            - **Improvement Recommendations**: [Optimization suggestions for process, monitoring, architecture, or standards]
            - **Reusable Practices**: [Methods or tools worth promoting from this investigation]
            """
        ),
        // Legal
        SummarizeTemplate(
            category: "Legal",
            name: "Court Stenographer",
            summary: "Records all statements made in a courtroom setting. All dialogue is transcribed in full detail, without summarization.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Court Hearing Record

            ## Basic Information

            - **Case No.**: [Case number]
            - **Case Name**: [Case name]
            - **Hearing Date**: [Date]
            - **Session Time**: [Start time] to [End time]
            - **Court**: [Court name]
            - **Courtroom No.**: [Courtroom number]

            ## Persons Present

            - **Presiding Judge**: [Name]
            - **Judge(s) / Juror(s)**: [Name]
            - **Court Clerk**: [Name]
            - **Prosecutor / Plaintiff's Counsel**: [Name and organization]
            - **Defendant**: [Name]
            - **Defense Counsel / Representative**: [Name and organization]
            - **Witness(es) / Expert Witness(es)**: [Name]
            - **Other Persons Present**: [Name and role]

            ---

            ## Hearing Proceedings Record

            ### I. Opening of the Session

            [Verbatim record of the presiding judge announcing the opening of the session, verifying parties' identities, informing rights and obligations, and all other statements]

            ---

            ### II. Court Investigation

            #### 1. Prosecution / Statement of Claims

            [Verbatim record of the prosecutor or plaintiff reading the indictment and statement content]

            #### 2. Defendant's Response

            [Verbatim record of the defendant's full response to the charges or claims]

            #### 3. Presentation and Cross-Examination of Evidence

            [Verbatim record of all statements made during the presentation of evidence and cross-examination by all parties]

            #### 4. Witness Testimony

            [Verbatim record of witness testimony in court and all content from questioning]

            #### 5. Court Questioning

            [Verbatim record of all questions from the presiding judge and judges to the parties, witnesses, and expert witnesses, and their responses]

            ---

            ### III. Court Debate

            #### 1. Plaintiff's / Prosecution's Arguments

            [Verbatim record of all arguments presented by the plaintiff or prosecutor]

            #### 2. Defendant's Arguments

            [Verbatim record of all arguments presented by the defendant and defense counsel]

            #### 3. Rebuttals and Supplementary Statements

            [Verbatim record of supplementary statements and mutual responses among all parties during the debate phase]

            ---

            ### IV. Final Statement

            #### Defendant's Final Statement

            [Verbatim record of the defendant's complete final statement]

            ---

            ### V. Recess and Verdict

            [Verbatim record of the presiding judge announcing recess, deliberation, verdict, or postponement of verdict, and all other procedural statements]

            ---

            ## Hearing Record Notes

            - **Audio / Video Recording No.**: [Number]
            - **Transcript File No.**: [Number]
            - **Completeness Note**: [If there are missing or unclear audio segments, note the corresponding time period and reason here]
            - **This record has been verified by the court clerk**: □ Yes　□ No
            """
        ),
        SummarizeTemplate(
            category: "Legal",
            name: "Meeting Secretary (Legal)",
            summary: "For summarizing and organizing legal meetings, to facilitate internal follow-up, strategy development, and accountability tracking",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Legal Meeting Minutes

            ## Basic Information

            - **Meeting Topic**: [Meeting topic]
            - **Meeting Date**: [Date]
            - **Meeting Location**: [Location / Online platform]
            - **Chairperson**: [Name / Title]
            - **Attendees**: [List of names, titles, or affiliated organizations]
            - **Minutes Taker**: [Name]

            ---

            ## Meeting Overview

            [Briefly explain the background, purpose, and main discussion direction of this meeting, 2–4 sentences.]

            ---

            ## Topic Discussion

            ### Topic 1: [Topic name]

            - **Discussion**: [Summary of core discussion content]
            - **Legal Analysis**: [Legal basis involved, interpretation of provisions, or legal risk assessment]
            - **Points of Disagreement**: [If there are differing positions, briefly record each party's viewpoint]
            - **Preliminary Conclusion**: [Interim consensus or pending items reached on this topic]

            ### Topic 2: [Topic name]

            - **Discussion**: [Summary of core discussion content]
            - **Legal Analysis**: [Legal basis involved, interpretation of provisions, or legal risk assessment]
            - **Points of Disagreement**: [If there are differing positions, briefly record each party's viewpoint]
            - **Preliminary Conclusion**: [Interim consensus or pending items reached on this topic]

            ---

            ## Legal Risk Notes

            | Risk Item | Risk Level | Party Involved | Response Recommendation |
            |----------|----------|--------|----------|
            | [Risk description] | [High / Medium / Low] | [Related party] | [Response measure] |
            | [Risk description] | [High / Medium / Low] | [Related party] | [Response measure] |

            ---

            ## Strategic Decisions

            - [Core legal strategy or action direction determined at this meeting]
            - [Specific strategic deployment involving litigation / negotiation / compliance remediation, etc.]
            - [Priority ranking or phased arrangements]

            ---

            ## Action Items

            | No. | Task Description | Owner | Deadline | Notes |
            |------|----------|--------|----------|------|
            | 1 | [Task content] | [Name] | [Date] | [Additional notes] |
            | 2 | [Task content] | [Name] | [Date] | [Additional notes] |
            | 3 | [Task content] | [Name] | [Date] | [Additional notes] |

            ---

            ## Items Pending Confirmation

            - [Items not yet agreed upon, requiring further verification, or awaiting external information]
            - [Content requiring specialized legal opinion or awaiting feedback from judicial authorities]

            ---

            ## Next Meeting Schedule

            - **Scheduled Date**: [Date]
            - **Main Topics**: [Topic preview]
            - **Materials to Prepare**: [Documents or materials each party needs to prepare in advance]
            """
        ),
        SummarizeTemplate(
            category: "Legal",
            name: "Client Consultation",
            summary: "For client consultations, aimed at extracting relevant facts for strategic planning",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Client Consultation Summary

            ## Basic Information
            - **Consultation Date**: [Date]
            - **Client Name**: [Client name]
            - **Consultation Topic**: [Topic]
            - **Participants**: [Participants]
            - **Consultation Duration**: [Duration]

            ---

            ## Client Background
            [Briefly describe the client's industry, business scale, current status, and background information]

            ---

            ## Core Requirements
            [Extract the client's core requirements expressed explicitly or implicitly during this consultation, ranked by priority]

            - [Requirement 1]
            - [Requirement 2]
            - [Requirement 3]

            ---

            ## Key Issues
            [List the main issues or pain points raised by the client]

            | Issue Description | Urgency | Notes |
            |----------|----------|------|
            | [Issue 1] | [High/Medium/Low] | [Notes] |
            | [Issue 2] | [High/Medium/Low] | [Notes] |
            | [Issue 3] | [High/Medium/Low] | [Notes] |

            ---

            ## Important Facts and Information
            [Record key data, constraints, existing resources, and other important facts mentioned by the client during the consultation]

            - [Fact 1]
            - [Fact 2]
            - [Fact 3]

            ---

            ## Client's Expected Goals
            [Describe the client's expectations for the ideal outcome, including timeline, deliverable standards, or business objectives]

            - **Short-Term Goal**: [Short-term goal]
            - **Long-Term Goal**: [Long-term goal]
            - **Success Criteria**: [Success criteria]

            ---

            ## Potential Risks and Concerns
            [Summarize concerns, worries, or risk factors expressed by the client that could affect progress]

            - [Risk or concern 1]
            - [Risk or concern 2]

            ---

            ## Strategic Recommendations
            [Based on the information from this consultation, propose preliminary strategic direction or solution approaches]

            1. [Recommendation 1]
            2. [Recommendation 2]
            3. [Recommendation 3]

            ---

            ## Follow-Up Items
            [List the specific action items requiring follow-up, with clear owners and timelines]

            | Action Item | Owner | Deadline |
            |----------|--------|----------|
            | [Action item 1] | [Owner] | [Date] |
            | [Action item 2] | [Owner] | [Date] |

            ---

            ## Additional Notes
            [Record other information requiring attention or special background for this consultation]
            """
        ),
        // Real Estate
        SummarizeTemplate(
            category: "Real Estate",
            name: "Owners Committee General Meeting",
            summary: "For owners committee meetings",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Owners Committee General Meeting Minutes

            ## Basic Information

            - **Meeting Name**: [Meeting name]
            - **Meeting Time**: [Date] [Start time] — [End time]
            - **Meeting Location**: [Location]
            - **Chairperson**: [Name]
            - **Recorder**: [Name]
            - **Attendees**: [Number] Owners Committee members, [Number] owner representatives, [Number] property management representatives
            - **Guests**: [Guest details, or "None" if not applicable]

            ---

            ## Meeting Overview

            [Briefly describe the background, main purpose, and overall context of this meeting, in 2–4 sentences.]

            ---

            ## Agenda Items and Discussion

            ### Agenda Item 1: [Item name]

            - **Proposal Content**: [Core content and background of the item]
            - **Discussion Points**:
              - [Main opinion or point of contention 1]
              - [Main opinion or point of contention 2]
              - [Main opinion or point of contention 3]
            - **Vote Result**: [Number] in favor, [Number] against, [Number] abstained, [Passed / Not passed]

            ---

            ### Agenda Item 2: [Item name]

            - **Proposal Content**: [Core content and background of the item]
            - **Discussion Points**:
              - [Main opinion or point of contention 1]
              - [Main opinion or point of contention 2]
            - **Vote Result**: [Number] in favor, [Number] against, [Number] abstained, [Passed / Not passed]

            ---

            ### Agenda Item 3: [Item name]

            - **Proposal Content**: [Core content and background of the item]
            - **Discussion Points**:
              - [Main opinion or point of contention 1]
              - [Main opinion or point of contention 2]
            - **Vote Result**: [Number] in favor, [Number] against, [Number] abstained, [Passed / Not passed]

            ---

            ## Formal Resolutions

            | No. | Resolution Item | Vote Result | Responsible Party |
            |------|----------|----------|------------|
            | 1 | [Resolution content] | [Passed/Not passed] | [Responsible party] |
            | 2 | [Resolution content] | [Passed/Not passed] | [Responsible party] |
            | 3 | [Resolution content] | [Passed/Not passed] | [Responsible party] |

            ---

            ## Owner Feedback and Concerns

            - [Main request or opinion raised by owners 1]
            - [Main request or opinion raised by owners 2]
            - [Main request or opinion raised by owners 3]

            > For any questions that could not be answered on the spot, record the follow-up outcome in future updates.

            ---

            ## Follow-Up Items

            | No. | Follow-Up Item | Owner | Planned Completion Date |
            |------|----------|--------|--------------|
            | 1 | [To-do item] | [Owner] | [Date] |
            | 2 | [To-do item] | [Owner] | [Date] |
            | 3 | [To-do item] | [Owner] | [Date] |

            ---

            ## Next Meeting

            - **Estimated Time**: [Date]
            - **Main Agenda**: [Anticipated agenda description, or "TBD" if not yet determined]

            ---

            *These minutes were automatically generated by AI from the meeting audio transcript. Please refer to the on-site record if there are any discrepancies.*
            """
        ),
        SummarizeTemplate(
            category: "Real Estate",
            name: "Business Meeting / Real Estate Project Template",
            summary: "Business Meeting / Real Estate Project Template",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Real Estate Project Business Meeting Minutes

            ## Basic Information

            - **Meeting Topic**: [Meeting topic]
            - **Meeting Date**: [Date]
            - **Meeting Location**: [Location]
            - **Attendees**: [Attending organizations or individuals]
            - **Project Involved**: [Project name]

            ---

            ## Project Overview

            - **Project Location**: [Project location]
            - **Project Type**: [Residential / Commercial / Mixed-use / Other]
            - **Current Stage**: [Early planning / Design / Construction / Sales / Handover / Other]
            - **Meeting Background**: [Briefly describe the background or reason for this meeting]

            ---

            ## Discussion Items

            ### Item 1: [Item name]

            - **Discussion Content**: [Core discussion content]
            - **Party Positions**: [Main disagreements or consensus]
            - **Conclusion**: [Conclusion or opinion reached]

            ### Item 2: [Item name]

            - **Discussion Content**: [Core discussion content]
            - **Party Positions**: [Main disagreements or consensus]
            - **Conclusion**: [Conclusion or opinion reached]

            ### Item 3: [Item name]

            - **Discussion Content**: [Core discussion content]
            - **Party Positions**: [Main disagreements or consensus]
            - **Conclusion**: [Conclusion or opinion reached]

            ---

            ## Key Decisions

            | No. | Decision | Responsible Party | Deadline |
            |------|----------|--------|----------|
            | 1 | [Decision content] | [Responsible organization or person] | [Timeline] |
            | 2 | [Decision content] | [Responsible organization or person] | [Timeline] |
            | 3 | [Decision content] | [Responsible organization or person] | [Timeline] |

            ---

            ## Risks & Issues

            - **Current Risks**: [Main risks identified during project progress]
            - **Outstanding Issues**: [Matters not yet agreed upon or requiring further confirmation]
            - **Response Suggestions**: [Preliminary response ideas for the above risks or issues]

            ---

            ## Funding & Commercial Terms

            - **Funding Arrangement**: [Payment milestones, financing method, budget adjustments, etc.]
            - **Contract Terms**: [Discussion outcomes involving contract amendments, supplementary agreements, or key clauses]
            - **Pricing & Profit**: [Content related to pricing strategy, cost control, or profit distribution]

            ---

            ## Progress & Milestones

            - **Current Progress**: [Actual project progress]
            - **Key Milestones**: [Upcoming important milestones and targets]
            - **Delayed Items**: [Aspects at risk of delay or already behind schedule]

            ---

            ## Follow-Up Items

            - [ ] [Follow-up item] — Owner: [Responsible person] — Deadline: [Date]
            - [ ] [Follow-up item] — Owner: [Responsible person] — Deadline: [Date]
            - [ ] [Follow-up item] — Owner: [Responsible person] — Deadline: [Date]

            ---

            ## Next Meeting

            - **Estimated Time**: [Date]
            - **Meeting Agenda**: [Core topics planned for the next meeting]
            - **Attendance Requirements**: [Materials to prepare in advance or attendee requirements]
            """
        ),
        SummarizeTemplate(
            category: "Real Estate",
            name: "Real Estate Property Acquisition",
            summary: "For quickly capturing property information and breaking it down in detail by surrounding environment.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Property Acquisition Information Summary

            ## Basic Information

            - **Property Name**: [Property name]
            - **Property Address**: [Detailed address]
            - **Property Type**: [Residential / Commercial / Industrial / Mixed-use / Other]
            - **Building Area**: [Area]
            - **Land Area**: [Area]
            - **Year Built**: [Year]
            - **Current Use**: [Current use]
            - **Title Status**: [Title term and remaining years]
            - **Listing Price**: [Price]
            - **Information Source**: [Source channel]
            - **Record Date**: [Date]

            ---

            ## Property Overview

            [Brief description of the overall property condition, including building structure, floors, layout, current occupancy or vacancy status, and other core information]

            ---

            ## Surrounding Environment Analysis

            ### Transportation
            - **Public Transit**: [Nearby bus, subway, light rail, etc.]
            - **Road Access**: [Main roads, highway on/off-ramps, parking conditions, etc.]
            - **Walkability**: [Key destinations within walking distance]

            ### Education
            - **Kindergarten / Elementary School**: [Name and distance]
            - **Middle/High School**: [Name and distance]
            - **Higher Education**: [Name and distance, if applicable]

            ### Commercial Amenities
            - **Retail**: [Supermarkets, malls, convenience stores, etc.]
            - **Dining & Entertainment**: [Dining and leisure facilities]
            - **Specialty Markets**: [Nearby specialty markets or commercial streets, if applicable]

            ### Healthcare
            - **Medical Facilities**: [Hospital/clinic names and distance]
            - **Emergency Services**: [Fire station, ambulance station, etc.]

            ### Ecology & Landscape
            - **Parks & Green Space**: [Parks, greenbelts, plazas, etc.]
            - **Natural Scenery**: [Rivers, lakes, mountains, and other natural resources, if applicable]

            ### Surrounding Industry & Population
            - **Major Industries**: [Dominant nearby industries or industrial parks]
            - **Population Profile**: [Resident demographics, population density, etc.]
            - **Development Trends**: [Regional planning, new projects, favorable policies, etc.]

            ### Competing Properties
            - **Comparable Properties**: [Names, scale, and price range of nearby comparable properties]
            - **Competitive Assessment**: [Level of competition and this property's differentiating advantages]

            ---

            ## Acquisition Value Assessment

            ### Core Strengths
            - [Strength 1]
            - [Strength 2]
            - [Strength 3]

            ### Main Risks
            - [Risk 1]
            - [Risk 2]
            - [Risk 3]

            ### Preliminary Valuation Judgment
            [Preliminary judgment on acquisition value based on the surrounding environment, market conditions, and the property's current state]

            ---

            ## Key Issues & Items to Verify

            | Issue | Current Status | Follow-Up Owner |
            |--------|--------|----------|
            | [Issue 1] | [Pending confirmation / Confirmed] | [Name] |
            | [Issue 2] | [Pending confirmation / Confirmed] | [Name] |
            | [Issue 3] | [Pending confirmation / Confirmed] | [Name] |

            ---

            ## Follow-Up Action Plan

            - [ ] [Action item 1] — Deadline: [Date]
            - [ ] [Action item 2] — Deadline: [Date]
            - [ ] [Action item 3] — Deadline: [Date]

            ---

            ## Overall Recommendation

            [Based on the above analysis, an overall recommendation on whether to proceed with the acquisition, negotiation strategy, or next steps for due diligence]
            """
        ),
        // Finance
        SummarizeTemplate(
            category: "Finance",
            name: "Client Review Summary",
            summary: "For client reviews, advisor debriefs, and periodic check-ins; highlights key discussion points, conclusions, and action items.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Client Review Summary

            ## Basic Information

            - **Client Name**: [Client name]
            - **Meeting Date**: [Date]
            - **Attendees**: [Attendees]
            - **Meeting Duration**: [Duration]
            - **Meeting Topic**: [Topic]

            ---

            ## Background Overview

            [Briefly explain the background and purpose of this review, including the current stage, prior progress, or the key reason that triggered this discussion]

            ---

            ## Core Topics & Discussion Points

            ### Topic 1: [Topic name]

            - [Point]
            - [Point]
            - [Point]

            ### Topic 2: [Topic name]

            - [Point]
            - [Point]
            - [Point]

            ### Topic 3: [Topic name]

            - [Point]
            - [Point]

            ---

            ## Key Conclusions

            1. [Conclusion]
            2. [Conclusion]
            3. [Conclusion]

            ---

            ## Client Feedback & Concerns

            - **Positive Feedback**: [Aspects the client approved of or was satisfied with]
            - **Main Concerns**: [Concerns, issues, or requests raised by the client]
            - **Items Pending Confirmation**: [Matters not yet clearly answered that require further verification]

            ---

            ## Action Items

            | Item | Owner | Deadline | Notes |
            |------|--------|----------|------|
            | [Action item] | [Owner] | [Date] | [Notes] |
            | [Action item] | [Owner] | [Date] | [Notes] |
            | [Action item] | [Owner] | [Date] | [Notes] |

            ---

            ## Follow-Up Plan

            - **Next Communication Date**: [Date]
            - **Follow-Up Focus**: [Key focus areas or expected milestones for the next phase]
            - **Risk Alert**: [Potential risks or issues requiring advance attention]
            """
        ),
        SummarizeTemplate(
            category: "Finance",
            name: "Investment Consultation",
            summary: "Financial planning meetings with clients and prospects",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Investment Consultation Meeting Summary

            ## Basic Information

            - **Meeting Date**: [Date]
            - **Attendees**: [Advisor name] / [Client name]
            - **Meeting Duration**: [Duration]
            - **Meeting Format**: [Online / In-person / Phone]

            ---

            ## Client Overview

            - **Client Type**: [Existing client / Prospective client]
            - **Financial Stage**: [Asset accumulation / Wealth preservation / Retirement planning / Other]
            - **Family Structure**: [Married / Single / Children, etc.]
            - **Occupation**: [Brief description of occupation or industry]

            ---

            ## Financial Status

            - **Asset Size**: [Description of asset size]
            - **Income & Expenses**: [Brief description of income/expense structure]
            - **Current Portfolio**: [Asset classes currently held and their proportions]
            - **Liabilities**: [Loans, mortgages, or other liabilities]
            - **Risk Tolerance**: [Conservative / Moderate / Aggressive]

            ---

            ## Client Needs & Goals

            - **Core Needs**: [Main needs explicitly expressed by the client]
            - **Financial Goals**: [Short-term goal] / [Medium- to long-term goal]
            - **Key Focus**: [Returns, liquidity, tax, wealth transfer, other]
            - **Special Requirements or Concerns**: [Constraints or concerns raised by the client]

            ---

            ## Advisor Recommendations

            ### Asset Allocation Recommendation

            [Propose asset allocation direction and ratios based on the client's risk appetite and goals]

            ### Recommended Investment Products

            | Product Name | Type | Expected Return | Risk Level | Rationale |
            |----------|------|----------|----------|----------|
            | [Product 1] | [Type] | [Return] | [Level] | [Rationale] |
            | [Product 2] | [Type] | [Return] | [Level] | [Rationale] |

            ### Tax & Wealth Transfer Planning

            [If applicable, briefly describe recommendations related to tax optimization or wealth transfer]

            ### Risk Disclosure

            [Main risks and considerations associated with this recommendation]

            ---

            ## Key Meeting Consensus

            - [Important consensus or decision reached by both parties 1]
            - [Important consensus or decision reached by both parties 2]
            - [Important consensus or decision reached by both parties 3]

            ---

            ## Items Pending Client Confirmation

            - [Content the client needs to further review or verify]
            - [Supplementary materials or information the client committed to provide]

            ---

            ## Follow-Up Plan

            | Item | Owner | Expected Completion Date |
            |------|--------|--------------|
            | [Follow-up item 1] | [Owner] | [Date] |
            | [Follow-up item 2] | [Owner] | [Date] |

            - **Next Meeting Time**: [Date / TBD]
            - **Next Meeting Agenda**: [Brief agenda description]

            ---

            ## Advisor Notes

            [Notable details from the meeting, client sentiment, potential opportunities, or other supplementary notes]
            """
        ),
        SummarizeTemplate(
            category: "Finance",
            name: "Stock Market Discussion",
            summary: "PLAUD template for recording market conversations, capturing trends, stocks, price levels, strategies, and market conditions.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Stock Market Discussion Record

            ## Basic Information
            - **Date**: [Date]
            - **Discussion Topic**: [Topic]
            - **Markets Covered**: [Market, e.g., A-shares / U.S. stocks / Hong Kong stocks / Futures, etc.]
            - **Participants**: [Participants]

            ---

            ## Overall Market Conditions
            - **Index Trend**: [Overview of current index performance, e.g., index gains/losses, market sentiment, etc.]
            - **Sector Movements**: [Active or notably moving sectors]
            - **Market Sentiment**: [Bullish / Neutral / Bearish, and reasons]

            ---

            ## Individual Stock Discussion

            | Stock Name/Ticker | Current Price | Key Price Levels | Discussion Points |
            |------------|--------|--------|--------|
            | [Stock 1] | [Price] | [Support/resistance level] | [Points] |
            | [Stock 2] | [Price] | [Support/resistance level] | [Points] |
            | [Stock 3] | [Price] | [Support/resistance level] | [Points] |

            ---

            ## Key Price Levels & Signals
            - **Major Support Level**: [Price level and corresponding ticker]
            - **Major Resistance Level**: [Price level and corresponding ticker]
            - **Breakout/Breakdown Signal**: [Signal description]

            ---

            ## Trading Strategy & Views
            - **Short-Term Strategy**: [Points]
            - **Medium- to Long-Term Positioning**: [Points]
            - **Risk Alert**: [Potential risks]

            ---

            ## Macro & News
            - **Policy Developments**: [Relevant policy or regulatory news]
            - **Economic Data**: [Important economic indicators or earnings information]
            - **Market News**: [Important news affecting market conditions]

            ---

            ## Core Conclusions
            - [Conclusion 1]
            - [Conclusion 2]
            - [Conclusion 3]

            ---

            ## Items to Watch
            - [ ] [Item to watch 1]
            - [ ] [Item to watch 2]
            - [ ] [Item to watch 3]
            """
        ),
        SummarizeTemplate(
            category: "Finance",
            name: "Listed Company Research",
            summary: "Listed company research",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Listed Company Research Minutes

            ## Basic Information

            - **Company Name**: [Company name]
            - **Ticker Symbol**: [Ticker symbol]
            - **Industry**: [Industry classification]
            - **Research Date**: [Research date]
            - **Research Format**: [On-site visit / Conference call / Video call]
            - **Participants**: [Company host's title and name] / [Research institution name]

            ---

            ## Company Overview

            [Briefly introduce the company's main business, market positioning, and recent stage of development]

            ---

            ## Business Performance

            ### Financial Performance
            - [Recent changes in core financial metrics such as revenue, profit, gross margin, etc.]

            ### Core Business Progress
            - [Current operating status and interim results of each business segment]

            ### Market & Competition
            - [Market share, competitive landscape, and the company's competitive advantages]

            ---

            ## Key Q&A Points

            ### Question 1: [Question topic]
            > [Summary of the questioner's question]

            [Key points of the company's response]

            ### Question 2: [Question topic]
            > [Summary of the questioner's question]

            [Key points of the company's response]

            ### Question 3: [Question topic]
            > [Summary of the questioner's question]

            [Key points of the company's response]

            ---

            ## Strategic Planning & Outlook

            - **Short-Term Goals**: [Core operating goals for the coming year]
            - **Medium- to Long-Term Plan**: [Strategic direction and development path]
            - **Key Initiatives**: [Key actions or plans driving growth]

            ---

            ## Risk Disclosure

            - [Risk 1: Describe the potential risk and its impact]
            - [Risk 2: Describe the potential risk and its impact]
            - [Risk 3: Describe the potential risk and its impact]

            ---

            ## Research Conclusion & Investment View

            ### Core Highlights
            - [Core investment thesis or positive signals worth noting]

            ### Main Concerns
            - [Remaining concerns or key issues requiring continued tracking]

            ### Overall Assessment
            [Overall judgment and recommendation on the company's current investment value]

            ---

            ## Follow-Up Items

            - [ ] [Item requiring further verification or tracking]
            - [ ] [Plan for next discussion or items pending confirmation]
            """
        ),
        // Utility
        SummarizeTemplate(
            category: "Utility",
            name: "From Chaos to Clarity: Tagged Daily Review",
            summary: "Splits the transcript into tagged sections, labeled as Operational or Strategic, and adds action items.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Daily Review Summary

            ## Basic Information

            - **Date**: [Date]
            - **Source**: [Audio source / Meeting name / Recorder]
            - **Duration**: [Audio duration]
            - **Core Theme**: [Today's core theme, in one sentence]

            ---

            ## Content Overview

            [Summarize the overall background and main thread of this transcript in 3–5 sentences]

            ---

            ## Operational Items 🔧

            > Covers day-to-day execution, process advancement, resource coordination, issue handling, etc.

            ### Progress Update

            - [Operational progress point 1]
            - [Operational progress point 2]
            - [Operational progress point 3]

            ### Issues & Risks

            - [Current issues or potential risks]
            - [Anomalies requiring attention]

            ### Operational Action Items

            | Item | Owner | Deadline | Priority |
            |------|--------|----------|--------|
            | [Action item 1] | [Owner] | [Date] | High / Medium / Low |
            | [Action item 2] | [Owner] | [Date] | High / Medium / Low |

            ---

            ## Strategic Items 🧭

            > Covers directional judgment, goal adjustment, decision discussions, long-term planning, etc.

            ### Key Points

            - [Strategic view or judgment 1]
            - [Strategic view or judgment 2]
            - [Strategic view or judgment 3]

            ### Important Decisions

            - [Decision or consensus reached]
            - [Direction or topic pending confirmation]

            ### Strategic Action Items

            | Item | Owner | Deadline | Priority |
            |------|--------|----------|--------|
            | [Action item 1] | [Owner] | [Date] | High / Medium / Low |
            | [Action item 2] | [Owner] | [Date] | High / Medium / Low |

            ---

            ## Items to Clarify

            - [Content without a clear conclusion that requires further follow-up or confirmation]
            - [Parts with missing information or ambiguity]

            ---

            ## Today's Core Insights

            > Extract the 1–3 most important conclusions or insights from both operational and strategic perspectives

            1. [Core insight 1]
            2. [Core insight 2]
            3. [Core insight 3]
            """
        ),
        SummarizeTemplate(
            category: "Utility",
            name: "Daily Log",
            summary: "DayLog turns your daily audio into a clear, organized, and actionable report.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Daily Log

            ## Basic Information
            - **Date**: [Date]
            - **Recorder**: [Name]
            - **Core Theme**: [Today's core item or keyword]

            ---

            ## Today's Overview
            [Summarize today's overall situation, main work focus, or life priorities in 2–4 sentences]

            ---

            ## Key Items
            > Record the most noteworthy content of the day

            - [Key item 1]
            - [Key item 2]
            - [Key item 3]

            ---

            ## Detailed Record

            ### [Item 1 title]
            [Specific description, progress, or outcome of this item]

            ### [Item 2 title]
            [Specific description, progress, or outcome of this item]

            ### [Item 3 title]
            [Specific description, progress, or outcome of this item]

            ---

            ## Issues & Obstacles
            | Issue Description | Current Status | Preliminary Approach |
            |----------|----------|--------------|
            | [Issue 1] | [Unresolved / In progress / Resolved] | [Approach] |
            | [Issue 2] | [Unresolved / In progress / Resolved] | [Approach] |

            ---

            ## Decisions & Conclusions
            - [Important decision or conclusion formed today 1]
            - [Important decision or conclusion formed today 2]

            ---

            ## To-Dos & Follow-Ups
            | Item | Owner | Deadline | Priority |
            |------|--------|----------|--------|
            | [To-do 1] | [Name] | [Date] | High/Medium/Low |
            | [To-do 2] | [Name] | [Date] | High/Medium/Low |

            ---

            ## Takeaways & Reflections
            - **Today's Takeaways**: [Gains in knowledge, experience, or resources]
            - **Areas to Improve**: [Behaviors, processes, or thinking patterns that could be improved]
            - **Tomorrow's Priority**: [The top-priority item to advance tomorrow]
            """
        ),
        SummarizeTemplate(
            category: "Utility",
            name: "Key Data Points",
            summary: "Key Data Points systematically extracts all key metrics and figures from the transcript, analyzes their context and calculation logic, and organizes them into a clear, structured data table for easy review.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Key Data Extraction Report

            ## Basic Information

            | Field | Content |
            |------|------|
            | Topic | [Topic] |
            | Date | [Date] |
            | Source | [Source] |

            ---

            ## Data Overview

            > [Summarize in 2–3 sentences the core data areas and overall scale covered in this content]

            ---

            ## Key Data Details

            ### [Data Category 1]

            | Metric | Value | Unit | Context |
            |----------|------|------|------------|
            | [Metric name] | [Value] | [Unit] | [Background or meaning of this data] |
            | [Metric name] | [Value] | [Unit] | [Background or meaning of this data] |

            ### [Data Category 2]

            | Metric | Value | Unit | Context |
            |----------|------|------|------------|
            | [Metric name] | [Value] | [Unit] | [Background or meaning of this data] |
            | [Metric name] | [Value] | [Unit] | [Background or meaning of this data] |

            > Add further data categories in the same format as needed.

            ---

            ## Calculation Logic & Derivation

            - **[Metric name]**: [Calculation method or derivation process, e.g., derived from A÷B, or calculation logic explicitly stated by the speaker]
            - **[Metric name]**: [Calculation method or derivation process]

            > If there is no explicit calculation logic, this field may be marked "From direct statement."

            ---

            ## Data Comparison & Trends

            | Comparison Dimension | Value 1 | Value 2 | Change | Trend |
            |----------|--------|--------|----------|----------|
            | [Dimension] | [Value 1] | [Value 2] | [Change] | [Increase/Decrease/Flat and meaning] |
            | [Dimension] | [Value 1] | [Value 2] | [Change] | [Increase/Decrease/Flat and meaning] |

            ---

            ## Key Data Interpretation

            - **[Metric name]**: [Why this data is important, unusual, or worth noting]
            - **[Metric name]**: [Why this data is important, unusual, or worth noting]

            ---

            ## Data to Verify

            | Questionable Metric | Original Statement | Reason for Doubt |
            |----------|----------|----------|
            | [Metric name] | [Statement from the transcript] | [Ambiguous value / Unclear unit / Contradictory, etc.] |
            """
        ),
        SummarizeTemplate(
            category: "Utility",
            name: "Meeting Highlights",
            summary: "Meeting Highlights distills lengthy discussions, extracting only the most insightful and lasting-value points, presented in a structured, multi-tiered format designed for long-term reference.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Meeting Highlights

            ## Basic Information
            - **Meeting Topic**: [Meeting topic]
            - **Meeting Date**: [Date]
            - **Attendees**: [Attendees]
            - **Meeting Duration**: [Duration]

            ---

            ## Core Conclusion
            > [Summarize the most important conclusion or consensus reached in this meeting, in 2–3 sentences]

            ---

            ## Key Topics

            ### [Topic 1 title]
            - **Discussion Points**: [Core content of this topic]
            - **Main Views**: [Core positions or key arguments from each party]
            - **Consensus Reached**: [Conclusion or resolution]

            ### [Topic 2 title]
            - **Discussion Points**: [Core content of this topic]
            - **Main Views**: [Core positions or key arguments from each party]
            - **Consensus Reached**: [Conclusion or resolution]

            ### [Topic 3 title]
            - **Discussion Points**: [Core content of this topic]
            - **Main Views**: [Core positions or key arguments from each party]
            - **Consensus Reached**: [Conclusion or resolution]

            ---

            ## Key Insights
            - [Deep insight or pattern with long-term reference value]
            - [Trend judgment or risk alert worth continued attention]
            - [Strategic thinking with significant impact on the team or business]

            ---

            ## To-Do Items

            | Item | Owner | Deadline |
            |------|--------|----------|
            | [Action item 1] | [Owner] | [Date] |
            | [Action item 2] | [Owner] | [Date] |
            | [Action item 3] | [Owner] | [Date] |

            ---

            ## Open Issues
            - [Issues not yet resolved or requiring further discussion]
            - [Items requiring more information or resources to advance]

            ---

            ## Next Meeting
            - **Estimated Time**: [Date]
            - **Agenda Direction**: [Key topics planned for the next meeting]
            """
        ),
        // Workplace
        SummarizeTemplate(
            category: "Workplace",
            name: "Work Report Summary",
            summary: "For daily reports, weekly reports, and periodic reports; highlights core achievements, risks/blockers, and next steps.",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Work Report Summary

            ## Basic Information

            - **Reporter**: [Reporter's name]
            - **Report Type**: [Daily / Weekly / Periodic report]
            - **Reporting Period**: [Start date] to [End date]
            - **Team / Project**: [Team or project name]

            ---

            ## Core Achievements

            > Main work completed and key achievements during this period.

            - [Achievement 1]
            - [Achievement 2]
            - [Achievement 3]

            ---

            ## Work in Progress

            > Items currently in progress that have not yet been completed, along with their status.

            | Task | Current Progress | Expected Completion Date |
            |----------|----------|--------------|
            | [Task 1] | [Progress description] | [Date] |
            | [Task 2] | [Progress description] | [Date] |

            ---

            ## Risks & Blockers

            > Current issues, risks, or blocking factors affecting progress.

            - **[Risk/Issue 1]**: [Specific description and potential impact]
            - **[Risk/Issue 2]**: [Specific description and potential impact]

            ---

            ## Resources & Collaboration Needs

            > Items requiring support from leadership, cross-team collaboration, or additional resources.

            - [Need 1]
            - [Need 2]

            ---

            ## Next Steps

            > Key work items planned for the next reporting period.

            1. [Planned item 1]
            2. [Planned item 2]
            3. [Planned item 3]

            ---

            ## Additional Notes

            [Other content requiring special mention; leave blank if none]
            """
        ),
        SummarizeTemplate(
            category: "Workplace",
            name: "Email Thread Summary",
            summary: "Quickly organizes the origin, process, and final outcome of a multi-email exchange",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # Email Thread Summary

            ## Basic Information
            - **Subject**: [Email subject]
            - **Time Span**: [Start date] to [End date]
            - **Participants**: [Sender / Recipient / CC]
            - **Number of Emails**: [Count]

            ---

            ## Origin & Background
            [Briefly describe the origin, background, or triggering event of this email exchange, and state the purpose of the communication]

            ---

            ## Communication Process

            ### Stage 1: [Stage topic]
            - **Date**: [Date]
            - **Initiator**: [Name / Role]
            - **Main Content**: [Core statement or request]
            - **Response**: [Key points of the reply]

            ### Stage 2: [Stage topic]
            - **Date**: [Date]
            - **Initiator**: [Name / Role]
            - **Main Content**: [Core statement or request]
            - **Response**: [Key points of the reply]

            ### Stage 3: [Stage topic]
            - **Date**: [Date]
            - **Initiator**: [Name / Role]
            - **Main Content**: [Core statement or request]
            - **Response**: [Key points of the reply]

            > Add further stages as needed if there are more rounds of communication.

            ---

            ## Key Disputes & Disagreements
            | Point of Dispute | Positions | Resolution |
            |--------|----------|----------|
            | [Dispute 1] | [Positions] | [Negotiated outcome or tabled] |
            | [Dispute 2] | [Positions] | [Negotiated outcome or tabled] |

            ---

            ## Final Conclusion
            [Briefly describe the final consensus, decision, or outcome reached in this email exchange; if no consensus was reached, state the current status]

            ---

            ## To-Dos & Follow-Ups
            | Responsible Party | Item | Deadline |
            |--------|----------|----------|
            | [Responsible party] | [Item] | [Date] |
            | [Responsible party] | [Item] | [Date] |

            ---

            ## Additional Notes
            [Record attachment information, special agreements, unresolved matters, or other items requiring attention]
            """
        ),
        SummarizeTemplate(
            category: "Workplace",
            name: "Long Article to Slide Deck Outline",
            summary: "Quickly generates a presentation structure outline from a long article or report",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # [Topic] — Slide Deck Outline

            ## Basic Information

            - **Topic**: [Topic]
            - **Source**: [Source article/report/audio title]
            - **Date**: [Date]
            - **Estimated Presentation Length**: [Duration]
            - **Target Audience**: [Audience group]

            ---

            ## Core Message

            > [Summarize the article's core viewpoint or the presentation's main thesis in 1-2 sentences]

            ---

            ## Slide Structure Outline

            ### Part 1: Opening & Background
            **Suggested slide count: 1-2 slides**

            - Cover: [Main title] / [Subtitle]
            - Background: [Background explanation or problem introduction]
            - Content Preview: [Core sections this presentation will cover]

            ---

            ### Part 2: [Chapter 1 Title]
            **Suggested slide count: [Number] slides**

            - Core Viewpoint: [Chapter's main argument]
            - Point 1: [Point]
            - Point 2: [Point]
            - Point 3: [Point]
            - Supporting Data/Case: [Data or case]

            ---

            ### Part 3: [Chapter 2 Title]
            **Suggested slide count: [Number] slides**

            - Core Viewpoint: [Chapter's main argument]
            - Point 1: [Point]
            - Point 2: [Point]
            - Point 3: [Point]
            - Supporting Data/Case: [Data or case]

            ---

            ### Part 4: [Chapter 3 Title]
            **Suggested slide count: [Number] slides**

            - Core Viewpoint: [Chapter's main argument]
            - Point 1: [Point]
            - Point 2: [Point]
            - Point 3: [Point]
            - Supporting Data/Case: [Data or case]

            ---

            ### Part 5: Conclusion & Action Recommendations
            **Suggested slide count: 2-3 slides**

            - Core Conclusion: [Summary conclusion]
            - Key Insights: [The 1-3 most memorable insights]
            - Action Recommendations: [Specific action recommendations for the audience]
            - Closing Slide: [Acknowledgments/contact info/Q&A prompt]

            ---

            ## Visual Presentation Suggestions

            | Section | Suggested Chart/Visual Type | Notes |
            |------|------------------|------|
            | [Chapter 1] | [Chart type] | [Notes] |
            | [Chapter 2] | [Chart type] | [Notes] |
            | [Chapter 3] | [Chart type] | [Notes] |

            ---

            ## Keywords & Tags

            [Keyword 1] / [Keyword 2] / [Keyword 3] / [Keyword 4] / [Keyword 5]
            """
        ),
        SummarizeTemplate(
            category: "Workplace",
            name: "Turning Scattered Notes into a To-Do List",
            summary: "Organizes clear task lists from scattered, off-the-cuff notes",
            prompt: """
            Fill in this report from the transcript. Replace every [bracketed] placeholder with real content taken from it, drop the sections it gives you nothing for, and never leave a placeholder in the output. Keep the headings and their order exactly as written. Reply with the completed report in Markdown and nothing else.

            # To-Do List Organization

            ## Basic Information
            - **Record Date**: [Date]
            - **Note Source**: [Source description, e.g., voice memo / post-meeting notes / idea capture]
            - **Core Theme**: [Main subject or goal these notes revolve around]

            ---

            ## To-Do Task List

            ### 🔴 Urgent Items
            > Tasks requiring immediate action or with a clear deadline

            | Task | Deadline | Owner | Notes |
            |------|------|------|------|
            | [Task description] | [Deadline] | [Owner] | [Additional notes] |

            ---

            ### 🟡 Important Items
            > Important but not urgent tasks that need to be scheduled in the near term

            | Task | Estimated Time | Owner | Notes |
            |------|------|------|------|
            | [Task description] | [Estimated time] | [Owner] | [Additional notes] |

            ---

            ### 🟢 General Items
            > Lower-priority tasks that can be handled when convenient

            | Task | Estimated Time | Owner | Notes |
            |------|------|------|------|
            | [Task description] | [Estimated time] | [Owner] | [Additional notes] |

            ---

            ## Items to Confirm
            > Content mentioned in the notes that is incomplete and requires further confirmation before it can be acted on

            - [ ] [Item to confirm]
            - [ ] [Item to confirm]

            ---

            ## Deferred Items
            > Items not being acted on for now, to be pursued once conditions are ready

            - [Deferred item and reason]
            - [Deferred item and reason]

            ---

            ## Key Reminders
            > Important notes, cautions, or risk points that came up in the notes

            - [Reminder content]
            - [Reminder content]

            ---

            ## Summary
            [Summarize the core intent, main task direction, and priority focus of these notes in 2-4 sentences]
            """
        ),
    ]
}
