import Foundation
import os.log
import UniformTypeIdentifiers

private let log = Logger(subsystem: "com.nomily.app.ios", category: "library.import")

enum AudioImportError: LocalizedError {
    case unsupportedType(String)
    case accessDenied
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let ext):
            return "This file type (.\(ext)) isn't supported for import."
        case .accessDenied:
            return "Couldn't read the selected file."
        case .copyFailed(let msg):
            return msg
        }
    }
}

enum AudioImporter {
    /// Extensions the Library can list + the platform can read. Anything
    /// else we reject up-front rather than drop a dead file into the
    /// clips directory. Keep in sync with `LibraryListModel.refresh()`'s
    /// filter.
    static let acceptedExtensions: Set<String> = [
        "opus", "wav", "m4a", "mp3", "aac", "caf", "flac"
    ]

    /// Copies the document-picker URL into `decryptedDir`, keeping the
    /// original filename and resolving collisions with a `-1`, `-2`, …
    /// suffix. Caller is responsible for `startAccessingSecurityScopedResource`
    /// around this call — the URLs that arrive from SwiftUI's
    /// `.fileImporter` are security-scoped and the resource lock must
    /// outlive the copy.
    @discardableResult
    static func importFile(from source: URL) throws -> URL {
        let ext = source.pathExtension.lowercased()
        guard acceptedExtensions.contains(ext) else {
            throw AudioImportError.unsupportedType(ext)
        }

        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let target = uniqueDestination(in: dir, originalName: source.lastPathComponent)
        do {
            try fm.copyItem(at: source, to: target)
        } catch {
            log.error("import copy failed: \(String(describing: error), privacy: .public)")
            throw AudioImportError.copyFailed(error.localizedDescription)
        }
        log.info("imported \(source.lastPathComponent, privacy: .public) -> \(target.lastPathComponent, privacy: .public)")
        return target
    }

    static func uniqueDestination(in dir: URL, originalName: String) -> URL {
        let first = dir.appendingPathComponent(originalName)
        if !FileManager.default.fileExists(atPath: first.path) { return first }

        let ns = originalName as NSString
        let stem = ns.deletingPathExtension
        let ext = ns.pathExtension
        var n = 1
        while true {
            let candidate = "\(stem)-\(n)" + (ext.isEmpty ? "" : ".\(ext)")
            let url = dir.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}
