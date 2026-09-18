import Foundation

/// Shared filesystem roots. The app-group container is preferred so a future
/// share/notification/audio extension can read the same config + library;
/// when the capability isn't provisioned (free developer profile),
/// fall back to the app sandbox so the app still works.
enum StorageLocations {
    static let appGroupID = "group.com.nomily.app"

    static var root: URL {
        if let group = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            return group
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var configURL: URL {
        root.appendingPathComponent("config.json", isDirectory: false)
    }

    static var audioDir: URL {
        root.appendingPathComponent("audio_clips", isDirectory: true)
    }

    /// Decrypted audio lands here so the raw, still-encrypted blob in
    /// `audioDir` stays untouched.
    static var decryptedDir: URL {
        audioDir.appendingPathComponent("decrypted", isDirectory: true)
    }

    static var manifestURL: URL {
        audioDir.appendingPathComponent(".manifest.json", isDirectory: false)
    }

    /// Transcript text + JSON sit next to the decrypted audio so each clip's
    /// artefacts travel together.
    static func transcriptURLs(for audioName: String) -> (txt: URL, json: URL) {
        let base = (audioName as NSString).deletingPathExtension
        return (
            decryptedDir.appendingPathComponent("\(base).txt"),
            decryptedDir.appendingPathComponent("\(base).asr.json")
        )
    }

    static func translationURLs(for audioName: String) -> (txt: URL, json: URL) {
        let base = (audioName as NSString).deletingPathExtension
        return (
            decryptedDir.appendingPathComponent("\(base).translated.txt"),
            decryptedDir.appendingPathComponent("\(base).translated.json")
        )
    }

    static func summaryURL(for audioName: String) -> URL {
        let base = (audioName as NSString).deletingPathExtension
        return decryptedDir.appendingPathComponent("\(base).summary.md")
    }

    static func summaryTranslatedURL(for audioName: String) -> URL {
        let base = (audioName as NSString).deletingPathExtension
        return decryptedDir.appendingPathComponent("\(base).summary.translated.md")
    }

    static func titleURL(for audioName: String) -> URL {
        let base = (audioName as NSString).deletingPathExtension
        return decryptedDir.appendingPathComponent("\(base).title")
    }

    static var templatesURL: URL {
        root.appendingPathComponent("summarize_templates.json", isDirectory: false)
    }
}
