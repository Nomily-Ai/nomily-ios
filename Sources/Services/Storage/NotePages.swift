import Foundation

/// One **note page** of a recording — the Plaud model, captured from the vivo
/// handset on 2026-10-23: a recording's detail page splits into 「来源 | 笔记」,
/// and the 笔记 side holds *several* generated pages (chips 「总结 ▾ | 权力动态 |
/// +」), each produced from its own template, each regenerable ("更换模板"),
/// each deletable.
///
/// ## Why page "summary" is special
/// The classic single summary (`<base>.summary.md`) **is** the first page. Its
/// id is fixed, so every pre-existing consumer — the auto-summary guard, AiTask's
/// "wait for the summary job" (`summarize:<clip>`), the job-id scheme, document
/// export, summary translation — keeps working without knowing pages exist.
/// Extra pages only add files and manifest entries; nothing old is rewritten.
struct NotePage: Codable, Identifiable, Equatable {
    /// The classic single summary. Its body file is `<base>.summary.md`.
    static let primaryID = "summary"

    /// Stable within one clip — also the job-id suffix (`summarize:<clip>#<id>`)
    /// and the file-name component (`<base>.note.<id>.md`), so it must be file-
    /// name safe; the only producer is `UUID().uuidString` (hyphens are safe).
    let id: String
    /// Display title — the template the page was generated from.
    var title: String
    var createdAt: Date
}

/// Manifest I/O for a clip's note pages (`<base>.notes.json`).
///
/// ## Why the manifest is written by the runner, not the sheet
/// A summarize job can finish **after the app was killed** and with no sheet on
/// screen; the manifest must then appear on its own. `JobRunners.summarize`
/// upserts the entry right next to the artifact write — one synchronous block,
/// same all-or-nothing reasoning as the summary + title pairing.
enum NotePages {

    /// Pages of one clip, oldest first. Falls back to "just the classic summary"
    /// when there is no manifest but a `.summary.md` exists — a clip from before
    /// this feature must keep showing its summary without a migration step.
    static func load(for audioName: String) -> [NotePage] {
        let url = StorageLocations.notePagesURL(for: audioName)
        if let data = try? Data(contentsOf: url),
           let pages = try? JSONDecoder().decode([NotePage].self, from: data),
           !pages.isEmpty {
            return pages
        }
        let primary = StorageLocations.notePageURL(for: audioName, pageID: NotePage.primaryID)
        if (try? Data(contentsOf: primary)) != nil {
            return [NotePage(id: NotePage.primaryID,
                             title: L10n.ClipDetail.noteDefaultTitle,
                             createdAt: Date())]
        }
        return []
    }

    static func save(_ pages: [NotePage], for audioName: String) {
        guard let data = try? JSONEncoder().encode(pages) else { return }
        try? data.write(to: StorageLocations.notePagesURL(for: audioName), options: .atomic)
    }

    /// Insert or update one page's manifest entry (matched by id). Returns the
    /// resulting list so callers can hand it straight to their `@State`.
    @discardableResult
    static func upsert(id: String, title: String, for audioName: String) -> [NotePage] {
        var pages = load(for: audioName)
        if let idx = pages.firstIndex(where: { $0.id == id }) {
            pages[idx].title = title
        } else {
            pages.append(NotePage(id: id, title: title, createdAt: Date()))
        }
        save(pages, for: audioName)
        return pages
    }

    /// Drop a page: manifest entry **and** body file. The primary page's file is
    /// the classic summary — its deletion goes through the existing trash flow
    /// (`ClipDetailView.deleteSummary`), which also takes the translation along;
    /// `remove` here only updates the manifest for it.
    @discardableResult
    static func remove(id: String, for audioName: String) -> [NotePage] {
        var pages = load(for: audioName)
        pages.removeAll { $0.id == id }
        save(pages, for: audioName)
        if id != NotePage.primaryID {
            try? FileManager.default.removeItem(
                at: StorageLocations.notePageURL(for: audioName, pageID: id))
        }
        return pages
    }

    /// The page's markdown body, or nil when the file is missing/empty — a page
    /// whose job failed (or was cancelled) shows as "not generated yet".
    static func text(of page: NotePage, for audioName: String) -> String? {
        let url = StorageLocations.notePageURL(for: audioName, pageID: page.id)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }
}
