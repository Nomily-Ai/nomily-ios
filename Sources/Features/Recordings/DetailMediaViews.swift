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

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    private static let speeds: [Float] = [0.75, 1, 1.25, 1.5, 2]

    private var shownTime: TimeInterval { isScrubbing ? scrubTime : player.currentTime }
    private var shownTotal: TimeInterval { totalDuration ?? player.duration }

    var body: some View {
        VStack(spacing: 10) {
            if let error = player.loadError {
                Label(error, systemImage: "play.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

                HStack(spacing: 18) {
                    Text(ClockLabel.mmss(shownTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, alignment: .leading)

                    Spacer()

                    // Skip back 15 s — the gesture people actually use when they missed a word.
                    Button {
                        player.seek(to: max(0, player.currentTime - 15))
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.appAccent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button {
                        player.seek(to: min(player.currentTime + 15, player.duration))
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)

                    Spacer()

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
                        Text(speedLabel(player.rate))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.appAccent.opacity(0.12)))
                    }
                    .frame(minWidth: 44, alignment: .trailing)
                }

                HStack {
                    Text(ClockLabel.mmss(shownTotal))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
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
            HStack(alignment: .top, spacing: 10) {
                Text(ClockLabel.mmss(segment.start))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.appAccent.opacity(isActive ? 0.20 : 0.08))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    if let speaker = segment.speaker, !speaker.isEmpty {
                        Text(speakerNames[speaker].flatMap { $0.isEmpty ? nil : $0 }
                             ?? L10n.ClipDetail.speaker(speaker))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(Self.highlighted(segment.text, needle: highlight))
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineSpacing(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isActive ? Color.appAccent.opacity(0.08) : Color.clear)
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
/// contains the localized words for to-do / action / follow-up, plus Action / TODO. Everything between such a heading and the
/// next heading (of any level) counts as a to-do block. A summary with no such heading has
/// no to-dos — that's an honest empty state, not an error.
enum TodoExtract {
    static let keywords = ["待办", "行动", "后续", "action", "todo"]

    static func fromSummary(_ markdown: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var collecting = false
        for block in MarkdownBlocks.parse(markdown) {
            if case .heading = block.kind {
                collecting = keywords.contains { block.text.localizedCaseInsensitiveContains($0) }
                continue
            }
            if collecting { result.append(block) }
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
