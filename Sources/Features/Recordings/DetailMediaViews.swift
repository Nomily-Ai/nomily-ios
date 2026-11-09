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
    /// ★ 2026-10-30（纪要溯源跳转）：这一行是「摘要/待办点溯源」刚跳到的目标——
    /// 短暂黄底，几秒后由页面清掉。
    var isTraced: Bool = false
    var onTap: () -> Void

    /// ★ 2026-10-26 (user: "打点要在转录里作为重点标记，而不是文字"): live
    /// markers are saved with `speaker = "mark"` (see
    /// `PlaudDirectService.liveSnapshot`), so the detail page can render them
    /// as bookmark key-point rows instead of ordinary transcript lines.
    private var isMark: Bool { segment.speaker == "mark" }

    var body: some View {
        Button(action: onTap) {
            if isMark {
                // The key-point row: orange bookmark + the position, tap = seek.
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(ClockLabel.mmss(segment.start))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.orange)
                    Text(L10n.ClipDetail.markKeyPoint)
                        .font(.caption)
                        .foregroundStyle(.orange.opacity(0.85))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.08))
                )
                .contentShape(Rectangle())
            } else {
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
                    .fill(isTraced
                          ? Color.yellow.opacity(0.18)
                          : (isActive ? Color.appAccent.opacity(0.07) : Color.clear))
            )
            .contentShape(Rectangle())
            }
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

    /// ★ 2026-10-30（用户："待办事项需要根据摘要识别精准"）：不是待办的句子踢掉。
    /// 模板在行动项下面常跟着"备注：…""以上事项待确认""暂无"这类**说明性**行，
    /// 以前被当成待办列出来，用户勾了半天发现勾的是废话。
    static let noisePrefixes = [
        "备注", "注：", "注:", "说明：", "说明:", "提示：", "提示:",
        "以上", "以下", "暂无", "总计", "合计", "—", "-", "（", "(",
    ]

    /// 归一化：去掉行内 markdown 记号、序号前缀、多余空白——既用于去重，
    /// 也用于和手写待办比对（手抄一遍同一条不该出现两次）。
    static func normalize(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"^\s*[-*•]\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\s*\d{1,2}[.)、]\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^\s*\[[ xX]\]\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

        // ★ 2026-10-30：逐条清洗——去空、去说明行、去重（同一条只留第一次出现）。
        var seen = Set<String>()
        var cleaned: [MarkdownBlock] = []
        for block in result {
            if case .heading = block.kind {
                cleaned.append(block)
                continue
            }
            // ★ 2026-11-04（摘要优化 D）：成文层现在输出
            // `| 事项 | 责任人 | 截止 | 来源 |` 表格。表头与分隔行不是待办（直接扔掉），
            // 数据行转成「事项 · @张伟 · 11-08 · [12:24]」一行——待办页再把三段拆成徽章。
            if block.text.contains("|") {
                guard let item = TodoItem.fromTableRow(block.text) else { continue }
                let key = item.title.replacingOccurrences(of: " ", with: "").lowercased()
                guard seen.insert(key).inserted else { continue }
                cleaned.append(MarkdownBlock(kind: .bullet, text: item.composed))
                continue
            }
            let text = normalize(block.text)
            guard text.count >= 4 else { continue }
            if noisePrefixes.contains(where: { text.hasPrefix($0) }) { continue }
            let key = text.replacingOccurrences(of: " ", with: "").lowercased()
            guard seen.insert(key).inserted else { continue }
            cleaned.append(MarkdownBlock(kind: block.kind, text: text))
        }
        return cleaned
    }
}

// MARK: - Native Markdown blocks
//
// The full summary page renders through `MarkdownView` (a WKWebView). That is fine on its own
// page but wrong inside the detail list: a web view cannot size itself inside a Form row without
// fighting the scroll container. This parser covers what our templates actually emit —
// headings, bullets, numbered items, quotes, rules, paragraphs.

struct MarkdownBlock: Identifiable, Equatable {
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

    /// `id` 是每次解析都换新的 UUID，等价性看内容和类型即可——
    /// 这样 `TodoChecklistView` 能用 `onChange(of: blocks)` 在摘要重新生成后
    /// 再次触发提醒事项同步。
    static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text
    }
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
    /// ★ 2026-10-30（纪要溯源跳转）：给了回调就在每个内容块（要点/段落）行尾
    /// 显示一枚「跳到原文」小按钮——点它把这条要点在转写里定位出来。
    /// 传 nil（如待办列表里的标题行）就不显示。
    var onTrace: ((String) -> Void)? = nil

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
                        Text(inline(StampRef.stripping(block.text))).font(.callout)
                        traceButton(block)
                    }

                case .ordered(let number):
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(number).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Text(inline(StampRef.stripping(block.text))).font(.callout)
                        traceButton(block)
                    }

                case .quote:
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 3)
                        Text(inline(StampRef.stripping(block.text)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        traceButton(block)
                    }

                case .rule:
                    Divider()

                case .paragraph:
                    HStack(alignment: .top, spacing: 6) {
                        Text(inline(StampRef.stripping(block.text)))
                            .font(.callout)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        traceButton(block)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    /// 行尾的「跳到原文」小按钮。没有回调时是透明占位（不渲染）。
    @ViewBuilder
    private func traceButton(_ block: MarkdownBlock) -> some View {
        if let onTrace {
            // ★ 2026-11-04（摘要优化 C）：有来源时间时，按钮本身就是那枚时间。
            if let seconds = StampRef.parse(block.text) {
                Button {
                    onTrace(block.text)
                } label: {
                    Text(StampRef.format(seconds))
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.appAccent.opacity(0.9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.appAccent.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.ClipDetail.traceSource))
            } else {
                Button {
                    onTrace(block.text)
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.ClipDetail.traceSource))
            }
        }
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
    /// ★ 2026-10-30（纪要溯源跳转）：给了回调就在每条待办行尾显示「跳到原文」
    /// 小按钮（行主体仍是勾选/取消勾选）。
    var onTrace: ((String) -> Void)? = nil

    @EnvironmentObject private var configService: ConfigService
    @State private var done: Set<String> = []
    /// ★ 2026-10-29：本次进入页面新同步进「提醒事项」的条数（0/nil = 没有新增）。
    @State private var remindersCreated = 0
    /// ★ 2026-10-30（用户："待办支持手写待办不只是总结出来的待办"）：用户自己加的行。
    /// 存在 UserDefaults 里（key 按录音名），跟着录音走，重新生成摘要也不会丢。
    @State private var manual: [String] = []
    /// 输入框草稿。
    @State private var newTodo = ""

    private var defaultsKey: String { "todo.checked.\(recordingName)" }
    private var manualKey: String { "todo.manual.\(recordingName)" }

    /// 手写待办是否已有内容——父视图据此决定"没有摘要待办时要不要显示本视图"。
    static func hasManual(_ recordingName: String) -> Bool {
        !(UserDefaults.standard.stringArray(forKey: "todo.manual.\(recordingName)") ?? []).isEmpty
    }

    /// ★ 2026-10-29（用户："待办支持同步到 iPhone 里面的待办"）：开关打开时，
    /// 进待办列表就把行写进系统「提醒事项」（幂等：已建过的行不会重复）。
    private var remindersSyncOn: Bool { configService.config.remindersSyncEnabled }

    /// 已完成的那一组默认收起。
    @State private var showCompleted = false

    var body: some View {
        // ★ 2026-11-03 九轮（用户："APP 里面的待办展示太凌乱"）：
        //   旧版把所有东西平铺在同一个 8pt 间距的 VStack 里——标题行、未勾的、
        //   已勾的、手写的、输入框、提醒事项脚注首尾相接，视线找不到起点。
        //   现在按"进度 → 未完成 → 已完成（收起）→ 添加"分层，每层只有一件事。
        VStack(alignment: .leading, spacing: 0) {
            if totalCount > 0 { progressHeader.padding(.bottom, 10) }

            ForEach(blocks) { block in
                switch block.kind {
                case .bullet, .ordered, .paragraph:
                    if !done.contains(block.text) { row(block).padding(.bottom, 2) }
                case .heading, .quote, .rule:
                    // 标题/引用块没有"完成"的概念，照原样排在未完成组之前。
                    MarkdownBlocksView(blocks: [block])
                        .padding(.bottom, 4)
                }
            }

            // 手写待办排在摘要待办之后（"我自己记的"和"AI 提取的"混在一起会看不出边界）。
            ForEach(manual.filter { !done.contains($0) }, id: \.self) { text in
                row(MarkdownBlock(kind: .bullet, text: text), isManual: true)
                    .padding(.bottom, 2)
            }

            if totalCount == 0 {
                Text(blocks.isEmpty && manual.isEmpty
                     ? L10n.ClipDetail.todosNeedSummary
                     : L10n.ClipDetail.todosEmpty)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }

            if completedCount > 0 {
                completedHeader
                if showCompleted {
                    ForEach(completedBlocks) { block in
                        row(block, isManual: manual.contains(block.text))
                            .padding(.bottom, 2)
                    }
                }
            }

            addTodoRow.padding(.top, 10)

            if remindersSyncOn && totalCount > 0 {
                Text(L10n.Reminders.listFooter)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            } else if remindersCreated > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "checklist")
                    Text(L10n.Reminders.syncedBadge)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
            }
        }
        .onAppear {
            load()
            loadManual()
            syncToReminders()
        }
        .onChange(of: blocks) { _ in syncToReminders() }
    }

    // MARK: - 分组与进度（★ 2026-11-03 九轮）

    /// 全部行（摘要提取 + 手写），已完成的排在后面由调用处处理。
    private var allRows: [String] { blocks.map(\.text) + manual }
    private var totalCount: Int { allRows.count }
    private var completedCount: Int { allRows.filter { done.contains($0) }.count }
    private var remainingCount: Int { totalCount - completedCount }

    private var completedBlocks: [MarkdownBlock] {
        let parsed = blocks.filter { done.contains($0.text) }
        let manualDone = manual.filter { done.contains($0) }
            .map { MarkdownBlock(kind: .bullet, text: $0) }
        return parsed + manualDone
    }

    /// 「还剩 3 项 · 共 8 项」+ 一条细进度条。
    ///
    /// ★ 为什么值得占这一行：待办页最常被问的两个问题是"还有多少没做"和
    ///   "这件事我做到哪了"，一个数字 + 一根条同时回答，比让用户自己数行短得多。
    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(remainingCount)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(remainingCount == 0 ? Color.green : Color.primary)
                Text(remainingCount == 0 ? L10n.ClipDetail.todosAllDone : L10n.ClipDetail.todosRemaining)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(L10n.ClipDetail.todosTotal(totalCount))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(remainingCount == 0 ? Color.green : Color.appAccent)
                        .frame(width: geo.size.width * CGFloat(completedCount) / CGFloat(max(1, totalCount)))
                }
            }
            .frame(height: 4)
        }
    }

    private var completedHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showCompleted.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(L10n.ClipDetail.todosCompleted(completedCount))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    /// 手写一条待办：输入框 + 「+」。回车也能提交。
    ///
    /// ★ 2026-11-03 九轮：从"一颗灰加号 + 裸输入框"改成一条**淡底胶囊**——
    ///   它现在在待办列表的最末尾，没有容器就会被读成"列表多了一行空行"。
    private var addTodoRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.appAccent.opacity(0.85))
            TextField(L10n.ClipDetail.addTodoPlaceholder, text: $newTodo)
                .font(.callout)
                .submitLabel(.done)
                .onSubmit(addManualTodo)
            if !newTodo.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(L10n.Common.done) { addManualTodo() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.appAccent)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
    }

    private func row(_ block: MarkdownBlock, isManual: Bool = false) -> some View {
        let checked = done.contains(block.text)
        let item = TodoItem.parse(block.text)
        return HStack(alignment: .top, spacing: 6) {
            Button {
                if checked { done.remove(block.text) } else { done.insert(block.text) }
                save()
                // ★ 2026-10-29：勾选状态镜像到「提醒事项」（开关开着才动）。
                if remindersSyncOn {
                    RemindersSyncService.shared.updateCompletion(
                        text: block.text,
                        recordingName: recordingName,
                        isCompleted: !checked)
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    // ★ 2026-11-03 九轮：勾选框从 `.body` 收到 17pt 并吃主题色——
                    //   原来它和正文同字号同灰度，整行读起来像"一句话前面多了一个圈"。
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(checked ? Color.green.opacity(0.9) : Color.secondary.opacity(0.5))
                        .padding(.top, 0.5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 14.5))
                            .strikethrough(checked, color: .secondary)
                            .foregroundStyle(checked ? Color.secondary : Color.primary)
                            .multilineTextAlignment(.leading)
                            .lineSpacing(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if item.owner != nil || item.due != nil {
                            // ★ 2026-11-04（摘要优化 D）：责任人与截止做成两枚小徽章。
                            //   以前它们混在句子里（"…，张伟，11-08 前"），扫一眼根本分不出
                            //   "谁做"和"什么时候"——而这两件事正是待办页唯一要回答的。
                            HStack(spacing: 6) {
                                if let owner = item.owner {
                                    badge("person", owner)
                                }
                                if let due = item.due {
                                    badge("calendar", due)
                                }
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onTrace {
                Button {
                    onTrace(block.text)
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.ClipDetail.traceSource))
            }
        }
        // 只有手写的行给删除——摘要提取的行以摘要为准，重生成会自己更新。
        .contextMenu {
            if isManual {
                Button(role: .destructive) {
                    removeManual(block.text)
                } label: {
                    Label(L10n.Common.delete, systemImage: "trash")
                }
            }
        }
    }

    /// 待办行的小徽章（责任人 / 截止）。
    private func badge(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold))
            Text(text).font(.system(size: 10.5))
        }
        .foregroundStyle(Color.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }

    // MARK: - 手写待办（★ 2026-10-30）

    private func loadManual() {
        manual = UserDefaults.standard.stringArray(forKey: manualKey) ?? []
    }

    private func addManualTodo() {
        let text = newTodo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 与摘要里已有的条目去重：手抄一遍同一条不该出现两次。
        let normalized = TodoExtract.normalize(text)
        let existing = blocks.map { TodoExtract.normalize($0.text) }
        guard !existing.contains(normalized), !manual.contains(normalized) else {
            newTodo = ""
            return
        }
        manual.append(normalized)
        UserDefaults.standard.set(manual, forKey: manualKey)
        newTodo = ""
        syncToReminders()
    }

    private func removeManual(_ text: String) {
        manual.removeAll { $0 == text }
        UserDefaults.standard.set(manual, forKey: manualKey)
        if done.contains(text) {
            done.remove(text)
            save()
        }
    }

    private func load() {
        let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        done = Set(stored)
    }

    private func save() {
        UserDefaults.standard.set(Array(done), forKey: defaultsKey)
    }

    /// ★ 2026-10-29：开关打开时把待办行同步进「提醒事项」。失败/未授权静默——
    /// 设置页开关那行才是处理授权的地方，列表里不打扰。
    private func syncToReminders() {
        guard remindersSyncOn else { return }
        // ★ 2026-10-30：手写待办也一起同步——用户在 App 里写下的，正是他希望在
        // 手机「提醒事项」里看到的。
        let all = blocks + manual.map { MarkdownBlock(kind: .bullet, text: $0) }
        guard !all.isEmpty else { return }
        Task {
            let created = await RemindersSyncService.shared.sync(
                blocks: all, recordingName: recordingName)
            if created > 0 {
                await MainActor.run { remindersCreated = created }
            }
        }
    }
}
