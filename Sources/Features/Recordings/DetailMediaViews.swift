import SwiftUI

// MARK: - Inline audio player
//
// ★ (2026-10-19) The detail page used to show a "tap to open the player sheet" row. The user's
// complaint: "the summary / audio / transcript views are all poor" — reading a recording meant repeatedly opening and
// closing a modal, and the transcript never pointed at where you were in the audio.
//
// So the player now lives **in the page**: scrub, ±15 s, speed, and the transcript below reacts
// to it. Same `AudioPlaybackController` the sheet used — this is a presentation change only.

struct InlineAudioPlayer: View {

    @ObservedObject var player: AudioPlaybackController
    /// Duration from the database (Ogg page scan); the player's own duration can be a second off.
    let totalDuration: TimeInterval?
    /// The file the waveform is read from. `nil` = keep the plain slider.
    /// ★ 2026-10-23 (Plaud's layout): the envelope comes from the audio itself.
    var fileURL: URL? = nil

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var peaks: [Float]?

    private static let speeds: [Float] = [0.75, 1, 1.25, 1.5, 2]

    private var shownTime: TimeInterval { isScrubbing ? scrubTime : player.currentTime }
    private var shownTotal: TimeInterval { totalDuration ?? player.duration }

    /// Plaud's player, structurally:
    /// `00:07:55 / 00:16:34` → waveform → one row of evenly spaced controls
    /// (play, −15 s, +15 s, speed). The old version scattered the two times on
    /// opposite edges of a slider, which is what made the block read as three
    /// unrelated pieces.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = player.loadError {
                Label(error, systemImage: "play.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack {
                    Text("\(ClockLabel.mmss(shownTime)) / \(ClockLabel.mmss(shownTotal))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(isScrubbing ? Color.primary : Color.secondary)
                    Spacer()
                }

                scrubber

                controls
            }
        }
        .padding(.vertical, 6)
        .task(id: fileURL) {
            guard let fileURL, peaks == nil else { return }
            peaks = await AudioEnvelope.load(for: fileURL)
        }
    }

    /// Waveform when the file decodes, the old slider when it does not. Both go
    /// through the controller's scrub API, so playback behaviour is identical.
    @ViewBuilder
    private var scrubber: some View {
        if let peaks, peaks.count > 1 {
            WaveformScrubber(
                peaks: peaks,
                progress: shownTotal > 0 ? min(1, max(0, shownTime / shownTotal)) : 0,
                onScrub: { fraction in
                    if !isScrubbing {
                        isScrubbing = true
                        player.beginScrub()
                    }
                    scrubTime = fraction * max(player.duration, 0.01)
                },
                onScrubBegan: {
                    if !isScrubbing {
                        isScrubbing = true
                        player.beginScrub()
                    }
                },
                onScrubEnded: { fraction in
                    player.endScrub(at: fraction * max(player.duration, 0.01))
                    isScrubbing = false
                }
            )
        } else {
            Slider(
                value: Binding(
                    get: { shownTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(player.duration, 0.01),
                onEditingChanged: { editing in
                    if editing {
                        scrubTime = player.currentTime
                        isScrubbing = true
                        player.beginScrub()
                    } else {
                        player.endScrub(at: scrubTime)
                        isScrubbing = false
                    }
                }
            )
        }
    }

    /// Five equal slots, monochrome — Plaud's row. Each item owns one fifth of
    /// the width so the icons keep their rhythm at any text size.
    private var controls: some View {
        HStack(spacing: 0) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
                    .overlay(Circle().stroke(Color.primary.opacity(0.7), lineWidth: 1.2))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            // Skip back 15 s — the gesture people actually use when they missed a word.
            Button {
                player.seek(to: max(0, player.currentTime - 15))
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Button {
                player.seek(to: min(player.currentTime + 15, player.duration))
            } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 20))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Menu {
                ForEach(Self.speeds, id: \.self) { speed in
                    Button {
                        player.setRate(speed)
                    } label: {
                        if abs(player.rate - speed) < 0.01 {
                            Label(speedLabel(speed), systemImage: "checkmark")
                        } else {
                            Text(speedLabel(speed))
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(speedLabel(player.rate))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                    Image(systemName: "sparkles")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func speedLabel(_ value: Float) -> String {
        // 1× not 1.0×; 1.25× keeps two decimals but drops a trailing zero.
        let formatted = value == rounded(value) ? String(Int(value)) : String(format: "%g", value)
        return "\(formatted)×"
    }

    private func rounded(_ value: Float) -> Float { (value).rounded() }
}

// MARK: - Transcript rows

/// One transcript line. The time chip is a real button: tapping it jumps the audio there, which
/// is the single most useful interaction on a transcript page and was missing entirely.
struct TranscriptSegmentRow: View {

    let segment: AsrSegment
    let isActive: Bool
    /// When searching, this needle is highlighted inside the line (DingTalk's search
    /// highlights matches in place). `nil`/empty = render plain text.
    var highlight: String? = nil
    /// User-renamed speakers (`SpeakerNameStore`), raw id → name.
    ///
    /// ★ 2026-10-22 ("还要支持修改说话人的名称"): passed in rather than read from the
    /// singleton so this row stays a pure function of its inputs — it is also used
    /// by the full-screen transcript, which gets the map from the same page.
    var speakerNames: [String: String] = [:]
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            // ★ 2026-10-23 ("参考一下页面布局跟结构", Plaud 4029/4030): Plaud's
            // transcript line is `00:00:10  Eva` in one small grey row, then
            // the sentence at reading size — no time chip, no card, no
            // speaker label stacked above. The row only tints while it is the
            // line being spoken, which is the follow-along cue.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(ClockLabel.mmss(segment.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    if let speaker = segment.speaker, !speaker.isEmpty {
                        Text(speakerNames[speaker].flatMap { $0.isEmpty ? nil : $0 }
                             ?? L10n.ClipDetail.speaker(speaker))
                            .font(.caption)
                            .foregroundStyle(isActive ? Color.accentColor.opacity(0.85) : .secondary)
                    }
                }
                Text(Self.highlighted(segment.text, needle: highlight))
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                    .lineSpacing(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isActive ? Color.appAccent.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Case-insensitive needle highlight over an otherwise plain line.
    static func highlighted(_ text: String, needle: String?) -> AttributedString {
        var attributed = AttributedString(text)
        guard let needle, !needle.isEmpty else { return attributed }
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(of: needle, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow.opacity(0.45)
            searchStart = range.upperBound
        }
        return attributed
    }
}

// MARK: - Action items (to-dos)

/// Lifts the action-item section out of a summary's markdown — the data source for the
/// detail page's to-dos tab (DingTalk's third tab).
///
/// Heuristic by design: our summary templates emit action items under a heading whose text
/// contains the localized words for to-do / action / follow-up, plus Action / TODO. Everything
/// from such a heading until the next heading **of the same or higher level** counts as a to-do
/// block — sub-headings inside it (`### 张伟`) stay part of it, which they did not before, so a
/// grouped to-do list used to vanish on regeneration. A summary with no such heading has no
/// to-dos; that is an honest empty state, not an error.
enum TodoExtract {
    /// ★ 2026-10-23 ("重新生成摘要后待办不显示"): the list used to be
    /// `待办 / 行动 / 后续 / action / todo`, which missed the headings the
    /// templates themselves produce — `行动项`, `后续事项`, `跟进`, `下一步`,
    /// `任务清单`, `To-Do List`, `Next steps`. When a regeneration happened to
    /// pick a different title, the tab went empty and the to-dos looked lost.
    static let keywords = [
        // Chinese
        "待办", "行动", "后续", "跟进", "下一步", "任务",
        // English
        "action", "todo", "to-do", "to do", "follow-up", "follow up", "followup",
        "next step", "next-step", "assignment",
        // Japanese / Korean
        "やること", "アクション", "ネクスト", "할 일", "액션",
    ]

    /// Headings that contain one of the words above but are **not** a to-do list.
    /// `## 待确认事项` and `## 风险与未决问题` are the two our own templates emit —
    /// without this they would show up as to-dos, which is worse than an empty tab.
    static let blockers = [
        "待确认", "待定", "未决", "风险", "背景", "说明", "概述", "议程", "总结", "结论",
    ]

    static func fromSummary(_ markdown: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        /// Level of the heading that opened the to-do block; `nil` = not collecting.
        var openLevel: Int?
        for block in MarkdownBlocks.parse(markdown) {
            if case .heading(let level) = block.kind {
                if let open = openLevel, level > open {
                    // A sub-heading inside the block is content, not the end.
                    result.append(block)
                    continue
                }
                let blocked = blockers.contains { block.text.localizedCaseInsensitiveContains($0) }
                let matches = keywords.contains { block.text.localizedCaseInsensitiveContains($0) }
                openLevel = (matches && !blocked) ? level : nil
                continue
            }
            if openLevel != nil { result.append(block) }
        }
        return result
    }
}

// MARK: - Native Markdown blocks
//
// The full summary page renders through `MarkdownView` (a WKWebView). That is fine on its own
// page but wrong inside the detail list: a web view cannot size itself inside a Form row without
// fighting the scroll container. This parser covers what our templates actually emit —
// headings, bullets, numbered items, quotes, rules, paragraphs.

struct MarkdownBlock: Identifiable {
    enum Kind: Equatable {
        case heading(Int)
        case bullet
        case ordered(Int)
        case quote
        case rule
        case paragraph
    }

    let id = UUID()
    let kind: Kind
    let text: String
}

enum MarkdownBlocks {

    static func parse(_ markdown: String, limit: Int? = nil) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(MarkdownBlock(kind: .paragraph, text: paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .rule, text: ""))
                continue
            }
            if let match = line.range(of: #"^#{1,6}\s*"#, options: .regularExpression) {
                flushParagraph()
                let level = line[match].filter { $0 == "#" }.count
                blocks.append(MarkdownBlock(kind: .heading(level), text: String(line[match.upperBound...])))
                continue
            }
            if let match = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .bullet, text: String(line[match.upperBound...])))
                continue
            }
            if let match = line.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                let number = Int(line[match].prefix(while: \.isNumber)) ?? 1
                blocks.append(MarkdownBlock(kind: .ordered(number), text: String(line[match.upperBound...])))
                continue
            }
            if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .quote, text: String(line.dropFirst(2))))
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()

        if let limit, blocks.count > limit {
            return Array(blocks.prefix(limit))
        }
        return blocks
    }
}

struct MarkdownBlocksView: View {

    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block.kind {
                case .heading(let level):
                    Text(inline(block.text))
                        .font(level <= 1 ? .headline : (level == 2 ? .subheadline.weight(.semibold) : .footnote.weight(.semibold)))
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)

                case .bullet:
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(.body).foregroundStyle(.secondary)
                        Text(inline(block.text)).font(.callout)
                    }

                case .ordered(let number):
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(number).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Text(inline(block.text)).font(.callout)
                    }

                case .quote:
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 3)
                        Text(inline(block.text))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                case .rule:
                    Divider()

                case .paragraph:
                    Text(inline(block.text))
                        .font(.callout)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Renders `**bold**` / `*italic*` / `` `code` `` without pulling in a Markdown engine.
    /// Returns plain text when the string has no markers, so odd input can't break the row.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

/// ★ 2026-10-23 ("待办需要有一个前面点击的框，点击了就直接画一条横线"):
/// the to-do section rendered through `MarkdownBlocksView` was read-only text.
/// Now every item row carries a tap-to-check circle; checking strikes the row
/// through. Checked state persists **per recording** (UserDefaults keyed by the
/// recording name, values are the row texts), so it survives leaving the page
/// and app restarts — but re-generating the summary rewrites the rows and a
/// changed text starts unchecked again, which is the honest behaviour.
struct TodoChecklistView: View {

    let blocks: [MarkdownBlock]
    /// Namespace for the persisted checks: the recording's name.
    let recordingName: String

    @State private var done: Set<String> = []

    private var defaultsKey: String { "todo.checked.\(recordingName)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block.kind {
                case .bullet, .ordered, .paragraph:
                    row(block)
                case .heading, .quote, .rule:
                    // Headings/quotes/rules keep the plain rendering — only
                    // actual to-do rows get a checkbox.
                    MarkdownBlocksView(blocks: [block])
                }
            }
        }
        .onAppear { load() }
    }

    private func row(_ block: MarkdownBlock) -> some View {
        let checked = done.contains(block.text)
        return Button {
            if checked { done.remove(block.text) } else { done.insert(block.text) }
            save()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(checked ? Color.green : Color.secondary)
                Text(block.text)
                    .font(.callout)
                    .strikethrough(checked, color: .secondary)
                    .foregroundStyle(checked ? Color.secondary : Color.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() {
        let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        done = Set(stored)
    }

    private func save() {
        UserDefaults.standard.set(Array(done), forKey: defaultsKey)
    }
}
