import Foundation

/// One chapter of a recording's outline (大纲) — Plaud's "来源 → 大纲" block.
///
/// ★ 2026-10-23, user request: "他这个里面分录音来源里面还有大纲总结".
///
/// ## Why it is stored, not computed on the fly
/// A chapter list is a *result*, not a view of the transcript: it needs one LLM
/// pass over the timestamped segments, costs real tokens, and must survive the
/// app being killed mid-browse. So it lands on disk next to the other per-clip
/// artifacts (`<base>.chapters.json`) and the detail page just reads it.
///
/// ## Why `start` is the identity
/// Two chapters never begin at the same second in a sane outline, and this makes
/// `ForEach` keys stable without inventing a UUID that would change on every
/// regeneration (which would make the list flash on refresh).
struct ClipChapter: Codable, Equatable, Identifiable {
    /// Seconds from the start of the recording.
    var start: Double
    var title: String

    var id: Double { start }
}

// MARK: - Disk

enum ClipChapterStore {
    static func load(for audioName: String) -> [ClipChapter] {
        guard let data = try? Data(contentsOf: StorageLocations.chaptersURL(for: audioName)),
              let chapters = try? JSONDecoder().decode([ClipChapter].self, from: data)
        else { return [] }
        return chapters.sorted { $0.start < $1.start }
    }

    static func save(_ chapters: [ClipChapter], for audioName: String) {
        let sorted = chapters.sorted { $0.start < $1.start }
        guard let data = try? JSONEncoder().encode(sorted) else { return }
        try? data.write(to: StorageLocations.chaptersURL(for: audioName), options: .atomic)
    }

    /// Called when a transcript is re-run: the old outline's timestamps belong to
    /// the old ASR output and would point at the wrong words from now on.
    static func delete(for audioName: String) {
        try? FileManager.default.removeItem(at: StorageLocations.chaptersURL(for: audioName))
    }
}

// MARK: - Parsing the model's reply

extension ClipChapter {
    /// Turn the model's JSON-ish reply into chapters. **Deliberately lenient** —
    /// different channels (and the same channel on different days) wrap JSON in
    /// code fences, add a sentence before it, or emit `{"time": "1:20"}` instead
    /// of `{"t": "00:01:20"}`. A strict decoder would fail on all of those and the
    /// user would see "couldn't generate an outline" for a perfectly good answer.
    ///
    /// Accepts: `[{"t": "mm:ss", "title": "…"}]`, `[{"start": 72.5, "title": "…"}]`,
    /// `{"time": "0:12:03", "chapter": "…"}`, and an object wrapping the array in
    /// `chapters` / `outline` / `items`.
    static func parse(_ reply: String) -> [ClipChapter] {
        guard let array = Self.jsonArray(in: reply) else { return [] }
        var out: [ClipChapter] = []
        for item in array {
            guard let dict = item as? [String: Any] else { continue }
            let title = Self.string(in: dict, keys: ["title", "chapter", "name", "heading", "text"])
            guard let title, !title.isEmpty else { continue }
            guard let start = Self.startSeconds(in: dict) else { continue }
            out.append(ClipChapter(start: start, title: title))
        }
        // Same-second duplicates are meaningless in an outline and would collide
        // as `ForEach` ids; keep the first, which is the one the model led with.
        var seen = Set<Double>()
        return out
            .sorted { $0.start < $1.start }
            .filter { seen.insert($0.start).inserted }
    }

    /// Pull the first JSON array out of the reply, whatever it's wrapped in.
    private static func jsonArray(in reply: String) -> [Any]? {
        // Fast path: the whole reply is the array (after stripping fences).
        if let data = Self.trimmedJSON(reply).data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return array
        }
        // Wrapped in an object under a known key.
        if let data = Self.trimmedJSON(reply).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["chapters", "outline", "items", "data", "result"] {
                if let array = object[key] as? [Any] { return array }
            }
        }
        // Last resort: slice between the outermost brackets — catches "Here is
        // the outline:" preambles and trailing explanations.
        guard let open = reply.firstIndex(of: "["), let close = reply.lastIndex(of: "]"),
              open < close else { return nil }
        let slice = String(reply[open...close])
        guard let data = slice.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [Any]
    }

    private static func trimmedJSON(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            // Drop the opening fence (with its optional language tag) and the
            // closing one, if present.
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let range = s.range(of: "```", options: .backwards) {
                s = String(s[..<range.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func string(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Seconds from either a clock string (`mm:ss` / `hh:mm:ss`, also `1:2:3`)
    /// or a raw number.
    private static func startSeconds(in dict: [String: Any]) -> Double? {
        for key in ["t", "start", "time", "timestamp", "from", "begin"] {
            if let number = dict[key] as? NSNumber { return number.doubleValue }
            if let text = dict[key] as? String, let seconds = Self.seconds(from: text) {
                return seconds
            }
        }
        return nil
    }

    /// "00:01:15" → 75, "1:15" → 75, "75" → 75, "75.5s" → 75.5.
    static func seconds(from text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces)
        // Strip brackets/parentheses and a trailing "s" ("[00:12]" / "12s").
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
        if s.hasSuffix("s") { s.removeLast() }
        if s.contains(":") {
            let parts = s.split(separator: ":").compactMap { Double($0) }
            guard !parts.isEmpty else { return nil }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        return Double(s)
    }
}

// MARK: - Errors

enum ClipChapterError: LocalizedError {
    /// The recording has a transcript but no per-segment timings (an imported
    /// `.txt`, or an ASR provider that only returned flat text). An outline needs
    /// the timeline; without it every chapter would start at zero.
    case noTimeline
    /// The model answered, but nothing in the answer looked like chapters.
    case unparsable

    var errorDescription: String? {
        switch self {
        case .noTimeline:
            return NSLocalizedString(
                "outline.no_timeline",
                value: "This transcript has no timestamps, so an outline can't be built. Re-run the transcription to add them.",
                comment: "Outline generation: transcript has no per-segment timings"
            )
        case .unparsable:
            return NSLocalizedString(
                "outline.unparsable",
                value: "The model's reply didn't contain a usable outline. Try again.",
                comment: "Outline generation: model reply could not be parsed"
            )
        }
    }
}
