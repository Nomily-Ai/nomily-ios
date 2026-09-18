import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "library")

/// Tracks files the app has pulled off the device. Source of truth is
/// `audio_clips/.manifest.json`; a mirror is kept
/// in-memory and @Published so the Recordings tab can render without
/// re-reading the directory on every refresh.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var entries: [String: Entry] = [:]

    struct Entry: Codable, Equatable {
        /// Raw (still-encrypted) byte count.
        var size: Int
        var downloadedAt: String
        /// `"ble"` or `"wifi"`; informational, surfaced in the UI.
        var transport: String
        /// On-disk filename. It differs from the recorder filename only when
        /// another device already owns that timestamp-based name.
        var localName: String?

        enum CodingKeys: String, CodingKey {
            case size
            case downloadedAt = "downloaded_at"
            case transport
            case localName = "local_name"
        }
    }

    private struct Manifest: Codable {
        var downloaded: [String: Entry]
    }

    init() {
        self.entries = Self.loadFromDisk()
    }

    // MARK: queries

    /// Device downloads are scoped by serial number. Recorder filenames are
    /// timestamps, so two devices can legitimately produce the same name; a
    /// global name-only key made the second device look already downloaded.
    /// Legacy/unscoped entries remain readable for local/watch/stream clips,
    /// but are deliberately not used to suppress a device download.
    func isDownloaded(_ name: String, deviceSerial: String? = nil) -> Bool {
        entries[Self.key(name: name, deviceSerial: deviceSerial)] != nil
    }

    func entry(for name: String, deviceSerial: String? = nil) -> Entry? {
        entries[Self.key(name: name, deviceSerial: deviceSerial)]
    }

    // MARK: mutations

    /// Record a successful transfer. The raw bytes should already be on disk
    /// under `StorageLocations.audioDir`.
    func recordDownload(
        name: String,
        size: Int,
        transport: String = "ble",
        deviceSerial: String? = nil,
        localName: String? = nil
    ) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        entries[Self.key(name: name, deviceSerial: deviceSerial)] = Entry(
            size: size,
            downloadedAt: iso.string(from: Date()),
            transport: transport,
            localName: localName ?? name
        )
        saveNow()
    }

    /// Forget a file. Caller is responsible for deleting the on-disk payload
    /// if they also want the bytes gone.
    func forget(_ name: String) {
        entries.removeValue(forKey: name)
        entries = entries.filter { $0.value.localName != name }
        saveNow()
    }

    func clearAll() {
        entries = [:]
        saveNow()
    }

    /// Choose a collision-safe local filename while preserving the recorder's
    /// original name for the common single-device case.
    func localNameForDeviceFile(_ name: String, deviceSerial: String?) -> String {
        if let existing = entry(for: name, deviceSerial: deviceSerial)?.localName {
            return existing
        }
        let fm = FileManager.default
        let rawExists = fm.fileExists(atPath: StorageLocations.audioDir.appendingPathComponent(name).path)
        let readyExists = fm.fileExists(atPath: StorageLocations.decryptedDir.appendingPathComponent(name).path)
        guard rawExists || readyExists else { return name }

        let serial = (deviceSerial ?? "device")
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(stem)_\(serial)" : "\(stem)_\(serial).\(ext)"
    }

    // MARK: disk

    private static func key(name: String, deviceSerial: String?) -> String {
        guard let serial = deviceSerial?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serial.isEmpty else { return name }
        return "\(serial)::\(name)"
    }

    private static func loadFromDisk() -> [String: Entry] {
        let url = StorageLocations.manifestURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        do {
            let data = try Data(contentsOf: url)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            return manifest.downloaded
        } catch {
            log.error("Manifest load failed: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private func saveNow() {
        let url = StorageLocations.manifestURL
        do {
            try FileManager.default.createDirectory(
                at: StorageLocations.audioDir,
                withIntermediateDirectories: true
            )
            let manifest = Manifest(downloaded: entries)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("Manifest save failed: \(String(describing: error), privacy: .public)")
        }
    }
}
