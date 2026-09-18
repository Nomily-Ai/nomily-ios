import Foundation

/// Single source of truth for classifying a clip's on-disk artefacts.
///
/// Audio, transcript and summary delete independently — removing one never
/// touches the others — so the per-clip actions in Clip detail and the bulk
/// actions in Settings have to agree on exactly which files belong to which
/// artefact. Both go through this type rather than re-deriving the rules.
enum ClipArtefact {
    case audio
    case transcript
    case summary

    /// Extensions treated as playable audio. Shared with the importer and the
    /// Library scan so a file can never be importable yet unclassifiable here.
    static var audioExtensions: Set<String> { AudioImporter.acceptedExtensions }

    /// Suffix → artefact, longest first: `foo.summary.translated.md` must
    /// resolve to `.summary`, not to a shorter transcript suffix.
    private static let suffixMap: [(suffix: String, artefact: ClipArtefact)] = [
        (".summary.translated.md", .summary),
        (".summary.md",            .summary),
        (".translated.json",       .transcript),
        (".translated.txt",        .transcript),
        (".asr.json",              .transcript),
        (".txt",                   .transcript),
    ]

    /// The custom-title sidecar. Deliberately *not* one of the three deletable
    /// artefacts — it's clip metadata. It still has to be swept once nothing
    /// else remains, because the Library rebuilds an entry from any leftover
    /// sidecar and a lone `.title` would resurrect a ghost clip.
    static let titleSuffix = ".title"

    static func of(fileNamed name: String) -> ClipArtefact? {
        if audioExtensions.contains((name as NSString).pathExtension.lowercased()) {
            return .audio
        }
        return suffixMap.first { name.hasSuffix($0.suffix) }?.artefact
    }

    /// Recovers the clip base by stripping the artefact suffix (or the audio
    /// extension). Returns nil for files that aren't clip artefacts at all.
    static func base(ofFileNamed name: String) -> String? {
        if audioExtensions.contains((name as NSString).pathExtension.lowercased()) {
            return (name as NSString).deletingPathExtension
        }
        if let hit = suffixMap.first(where: { name.hasSuffix($0.suffix) }) {
            return String(name.dropLast(hit.suffix.count))
        }
        if name.hasSuffix(titleSuffix) {
            return String(name.dropLast(titleSuffix.count))
        }
        return nil
    }

    /// Deletes `.title` sidecars whose clip has no audio/transcript/summary
    /// left. Call after any partial delete so the Library doesn't keep showing
    /// an entry that has nothing behind it.
    static func sweepOrphanTitles() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: StorageLocations.decryptedDir, includingPropertiesForKeys: nil
        ) else { return }

        var basesWithContent = Set<String>()
        var titles: [(url: URL, base: String)] = []
        for url in entries {
            let name = url.lastPathComponent
            if name.hasSuffix(titleSuffix) {
                if let base = base(ofFileNamed: name) { titles.append((url, base)) }
            } else if let base = base(ofFileNamed: name), of(fileNamed: name) != nil {
                basesWithContent.insert(base)
            }
        }
        for title in titles where !basesWithContent.contains(title.base) {
            try? fm.removeItem(at: title.url)
        }
    }
}
