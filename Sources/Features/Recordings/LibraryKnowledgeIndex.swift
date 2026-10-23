import Foundation

/// The body-text index for "knowledge-base search": each recording's **transcript / translation / summary** is read as plain text
/// and kept in memory for list search.
///
/// ## Why it must be an `actor`
/// One search reads dozens to hundreds of `.txt` / `.md` files, each tens to hundreds of KB. On the main thread that
/// means "a hitch on every keystroke". The whole search chain runs on this actor; the main thread only takes the result.
///
/// ## ★ How the cache invalidates (the key trade-off here)
/// The caller uses `LibraryScanner.Signature` (the newest mtime in the directory + entry count)
/// as a **whole-block invalidation key**. Writing any file in the directory changes it — so
/// **overwrites** like "transcribe again" or "regenerate the summary" also invalidate the cache.
///
/// The cost is that any unrelated new file drops the cache too (one rebuild, acceptable), and what it buys is
/// "never matching against stale body text".
///
/// ## Memory
/// What's cached is the plain text of **the entries that have body text**, on the order of = entries × single-transcript size
/// (a 10-minute meeting ≈ 10 KB, an hour-long one ≈ 60 KB). A few hundred entries is a few MB to a few tens of MB,
/// traded for "re-reading the disk on every keystroke". Deliberately no LRU / byte cap: the real cap comes from
/// how many entries the user has transcribed, and adding eviction to a "whole-block invalidation" cache would only make
/// "findable this time, not next time" a random failure. If it really needs reining in, that belongs on the **storing the transcript** side,
/// capping the size there, not here.
///
/// Deliberately **doesn't** compare size / mtime per file: that would take 2~4 extra `stat`s per clip,
/// and the rebuilds saved are nowhere near worth those syscalls — and a miss would surface a snippet of body text
/// that no longer exists.
actor LibraryKnowledgeIndex {
    static let shared = LibraryKnowledgeIndex()

    /// The invalidation key and the body text **move together**: when the key changes the whole block must be cleared, not just the key swapped.
    private var stamp: LibraryScanner.Signature?
    private var docs: [String: String] = [:]

    /// Find `query` among the `bases` entries.
    ///
    /// - Returns: `base -> matched snippet`, containing **only the entries that matched**.
    ///
    /// Matching is case- and diacritic-insensitive: a `Café` in the user's transcript should be findable by
    /// `cafe`, and `Ç` should be findable by `c`.
    func search(
        _ query: String,
        bases: [String],
        stamp: LibraryScanner.Signature?
    ) async -> [String: String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [:] }

        if stamp != self.stamp {
            docs.removeAll(keepingCapacity: true)
            self.stamp = stamp
        }

        var hits: [String: String] = [:]
        for base in bases {
            // When typing fast the layer above cancels the whole previous search; the read loop must actually check this flag,
            // otherwise cancellation only means "the layer above stops waiting", and the disk is still read (a big difference at 1900 entries in the library).
            if Task.isCancelled { return hits }
            guard let text = text(for: base), !text.isEmpty else { continue }
            guard let match = text.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) else { continue }
            hits[base] = Self.snippet(in: text, match: match)
        }
        return hits
    }

    /// Get one clip's body text (reads the disk the first time, then goes through the cache). Returns nil when there really is no body text.
    private func text(for base: String) -> String? {
        // An empty string is also a **meaningful cached value**: it means "this one is confirmed to have no body text",
        // and without this sentinel every search would re-read the disk for the same batch of empty entries.
        if let cached = docs[base] { return cached.isEmpty ? nil : cached }

        // Order is priority: transcript first, summary last.
        let names = [
            "\(base).txt",
            "\(base).translated.txt",
            "\(base).summary.md",
            "\(base).summary.translated.md",
        ]
        var parts: [String] = []
        for name in names {
            let url = StorageLocations.decryptedDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let body = String(data: data, encoding: .utf8) else { continue }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            parts.append(trimmed)
        }
        let joined = parts.joined(separator: "\n")
        docs[base] = joined
        return joined.isEmpty ? nil : joined
    }

    /// Take a span around the hit and **flatten all whitespace**.
    ///
    /// Why newlines must be flattened: the transcript is one sentence per line, and dropping the `\n`s from the source straight into a list row
    /// would stretch one snippet to a dozen rows tall and wreck the whole list.
    private static func snippet(
        in text: String,
        match: Range<String.Index>,
        before: Int = 36,
        after: Int = 56
    ) -> String {
        let start = text.index(match.lowerBound, offsetBy: -before, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: after, limitedBy: text.endIndex)
            ?? text.endIndex
        var s = String(text[start..<end])
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\r", with: " ")
        s = s.replacingOccurrences(of: "\t", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.trimmingCharacters(in: .whitespaces)
        // Add an ellipsis at each truncation point so whoever reads the snippet knows it isn't a complete sentence.
        if start != text.startIndex { s = "…" + s }
        if end != text.endIndex { s += "…" }
        return s
    }
}

/// The scope of library search.
///
/// Defaults to `.knowledge` — what the user wants is "convenient **knowledge-base** search": only in the **body text** of entries
/// he has already transcribed to text or generated a summary for. `.all` is the escape hatch:
/// use it to find a not-yet-transcribed recording by filename / custom title.
enum LibrarySearchScope: String, CaseIterable, Identifiable {
    case knowledge
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .knowledge: return L10n.Library.searchScopeKnowledge
        case .all:       return L10n.Library.searchScopeAll
        }
    }
}
