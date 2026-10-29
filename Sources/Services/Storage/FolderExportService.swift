import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "folder-export")

/// ★ 2026-10-29（饭耳移植 · 规格 §2.3 保存位置 · 文件 App 路线）
///
/// The second destination alongside WebDAV: the user picks **any** folder via
/// the document picker (iCloud Drive, "我的 iPhone", or a provider app's
/// container — the spec names Obsidian vaults explicitly) and transcripts —
/// plus optionally audio — are copied there.
///
/// Scope mechanics (the part that bites if done wrong):
///   · The picker URL is security-scoped; we persist a **bookmark** in
///     UserDefaults and `startAccessingSecurityScopedResource` around every
///     export pass, stopping access when it ends. Holding access forever is
///     not how the API is meant to be used and iOS revokes it anyway.
///   · Idempotent like the WebDAV sweep: an identical-sized destination file
///     is skipped, so re-running is cheap and safe.
@MainActor
final class FolderExportService: ObservableObject {

    static let shared = FolderExportService()
    private init() {}

    static let bookmarkKey = "export_folder_bookmark"

    @Published var isRunning = false
    @Published var lastReport: String?

    /// True when the user picked a folder before (bookmark resolves).
    var hasFolder: Bool { bookmarkData != nil }

    /// Display name of the chosen folder, for the settings row.
    var folderName: String? {
        guard let url = resolve() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return url.lastPathComponent
    }

    private var bookmarkData: Data? {
        UserDefaults.standard.data(forKey: Self.bookmarkKey)
    }

    // MARK: - Bookmark lifecycle

    /// Called right after the document picker returns — the URL is valid only
    /// within this access window, so convert it to a bookmark immediately.
    func store(from url: URL) {
        let gotAccess = url.startAccessingSecurityScopedResource()
        defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            // ⚠️ `.withSecurityScope` is macOS-only — on iOS a plain bookmark
            // (options: []) is what a picked folder takes; the scope is opened
            // with startAccessingSecurityScopedResource at use time.
            let data = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            lastReport = nil
            log.notice("export folder stored: \(url.lastPathComponent, privacy: .public)")
        } catch {
            lastReport = L10n.FolderExport.bookmarkFailed
            log.error("bookmark failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        lastReport = nil
    }

    /// Resolve + start access. Callers MUST call `stopAccessingSecurityScopedResource`
    /// on the returned URL when done (see `exportAll`).
    private func resolve() -> URL? {
        guard let data = bookmarkData else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return url.startAccessingSecurityScopedResource() ? url : url
    }

    // MARK: - Export

    /// Copy every transcript (and optionally audio) into `<folder>/transcripts`
    /// and `<folder>/audio`. Mirrors the WebDAV layout on purpose: the two
    /// destinations stay interchangeable.
    func exportAll(syncAudio: Bool) async {
        guard !isRunning else { return }
        guard let folder = resolve() else {
            lastReport = L10n.FolderExport.notPicked
            return
        }
        isRunning = true
        defer {
            isRunning = false
            folder.stopAccessingSecurityScopedResource()
        }

        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        let audioExtensions: Set<String> = ["m4a", "aac", "wav", "caf", "mp3", "aif", "aiff", "flac", "opus"]
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }

        let clips = names
            .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .filter { name in
                let base = (name as NSString).deletingPathExtension
                return fm.fileExists(atPath: dir.appendingPathComponent("\(base).txt").path)
            }
            .sorted()

        var copied = 0
        var skipped = 0
        var failures: [String] = []

        func copyItem(_ local: URL, into subdirectory: String) {
            let destDir = folder.appendingPathComponent(subdirectory, isDirectory: true)
            let dest = destDir.appendingPathComponent(local.lastPathComponent)
            if let existingSize = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int,
               let localSize = (try? fm.attributesOfItem(atPath: local.path))?[.size] as? Int,
               existingSize == localSize {
                skipped += 1
                return
            }
            do {
                try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: local, to: dest)
                copied += 1
            } catch {
                failures.append("\(local.lastPathComponent): \(error.localizedDescription)")
            }
        }

        for clip in clips {
            let base = (clip as NSString).deletingPathExtension
            let urls = StorageLocations.transcriptURLs(for: clip)
            copyItem(urls.txt, into: "transcripts")
            if fm.fileExists(atPath: urls.json.path) {
                copyItem(urls.json, into: "transcripts")
            }
            if syncAudio {
                copyItem(dir.appendingPathComponent(clip), into: "audio")
            }
        }

        lastReport = failures.isEmpty
            ? L10n.FolderExport.reportAll(copied, skipped)
            : L10n.FolderExport.reportFailures(copied, skipped, failures.count, failures[0])
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }
}
