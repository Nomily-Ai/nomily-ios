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

        /// ★ 2026-10-15: **which card** recorded this clip.
        ///
        /// Previously the SN was encoded only in the **key** (`serial::name`), not in the value —— so the list
        /// couldn't get "who recorded this one". This also explains why the old `isFromWatch` only recognized
        /// transport: when `entry(for:)` is called without a serial it only looks up the bare key, so not a single
        /// device-downloaded item could be hit.
        var deviceSerial: String?
        /// The **human-recognizable name** readable at the time of recording to the library (the card's displayName / etc.).
        ///
        /// Deliberately separate from `deviceSerial`: the SN is the **identity** (stable, can be reverse-looked-up to the user's alias,
        /// survives a device switch), while the name is only for **display**. Mixing the two into one field would make "if the user renames the alias,
        /// do old records follow" an ill-defined question —— the current answer is "they follow",
        /// because at display time the SN is first looked up once in `RecorderAliasStore`.
        var deviceName: String?

        /// ★ (2026-10-19) How this clip came into being: `"memo"` = the card's **voice key**
        /// started the recording (an AI voice memo), `nil` = a regular recording. The library
        /// uses it to badge and filter memos separately from recordings — the two gestures mean
        /// different things to the user, so they must not land in one undifferentiated pile.
        var source: String?

        enum CodingKeys: String, CodingKey {
            case size
            case downloadedAt = "downloaded_at"
            case transport
            case localName = "local_name"
            case deviceSerial = "device_serial"
            case deviceName = "device_name"
            case source
        }
    }

    private struct Manifest: Codable {
        var downloaded: [String: Entry]
    }

    init() {
        self.entries = Self.loadFromDisk()
        rebuildSourceIndex()
        migrateExtensionlessLiveClips()
    }

    /// ★ 2026-10-28 一次性自愈：早期实时转录保存时用了"纯 fileId"当文件名，
    /// 没有扩展名 —— `PostDownload` 认不出格式，文件被丢在 `audioDir` 根目录，
    /// 录音列表（读 `decryptedDir`）里永远看不到。这里把这一类文件
    /// （根目录 + 纯数字名 + OggS 头）复制成 `decryptedDir/<name>.opus` 并补进
    /// 清单，用户之前"消失"的实时录音就能回来了。幂等：迁移后根目录不再有
    /// 无点号文件，重复执行是空操作。
    private func migrateExtensionlessLiveClips() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: StorageLocations.audioDir.path) else { return }
        var changed = false
        for name in names where !name.contains(".") && UInt32(name) != nil {
            let src = StorageLocations.audioDir.appendingPathComponent(name)
            guard let head = try? FileHandle(forReadingFrom: src),
                  let prefix = try? head.read(upToCount: 4),
                  prefix == Data("OggS".utf8) else { continue }
            try? head.close()
            guard let size = (try? fm.attributesOfItem(atPath: src.path))?[.size] as? Int else { continue }
            let newName = "\(name).opus"
            let dst = StorageLocations.decryptedDir.appendingPathComponent(newName)
            do {
                try fm.createDirectory(at: StorageLocations.decryptedDir, withIntermediateDirectories: true)
                if !fm.fileExists(atPath: dst.path) {
                    try fm.copyItem(at: src, to: dst)
                }
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                entries[Self.key(name: newName, deviceSerial: nil)] = Entry(
                    size: size,
                    downloadedAt: iso.string(from: Date()),
                    transport: "stream",
                    localName: newName,
                    deviceSerial: nil,
                    deviceName: nil,
                    source: nil
                )
                changed = true
            } catch {
                continue
            }
        }
        if changed {
            rebuildSourceIndex()
            saveNow()
        }
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

    /// Fetch the raw record (key + value) by **on-disk file name**.
    ///
    /// Why it's needed: restoring from the trash has to put the "already downloaded from the device" evidence back **verbatim**,
    /// and `source(forLocalName:)` only yields "which device", not `transport` /
    /// `size`, nor the original file name on the device — miss any one of the three,
    /// and `recordDownload(size:transport:…)` can't restore the same key.
    ///
    /// It's an O(n) linear scan: called only once on the next delete/restore, and iterating a 1900-entry dictionary
    /// costs microseconds; to give `localName` a reverse index instead would mean keeping another copy
    /// that can drift.
    func rawEntry(forLocalName localName: String) -> (key: String, entry: Entry)? {
        for (key, entry) in entries where (entry.localName ?? key) == localName {
            return (key, entry)
        }
        return nil
    }

    // MARK: mutations

    /// Record a successful transfer. The raw bytes should already be on disk
    /// under `StorageLocations.audioDir`.
    func recordDownload(
        name: String,
        size: Int,
        transport: String = "ble",
        deviceSerial: String? = nil,
        deviceName: String? = nil,
        localName: String? = nil,
        source: String? = nil
    ) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let k = Self.key(name: name, deviceSerial: deviceSerial)
        // Source fields are **set-only, never cleared**: the same clip may first be recorded via BLE and
        // then recorded again via the Wi-Fi path, and that path doesn't necessarily carry the SN / name. If we don't keep them,
        // the second record would wipe the source —— showing up as "the badge vanished halfway through the transfer".
        let previous = entries[k]
        entries[k] = Entry(
            size: size,
            downloadedAt: iso.string(from: Date()),
            transport: transport,
            localName: localName ?? name,
            deviceSerial: deviceSerial ?? previous?.deviceSerial,
            deviceName: deviceName ?? previous?.deviceName,
            source: source ?? previous?.source
        )
        rebuildSourceIndex()
        saveNow()
    }

    /// Forget a file. Caller is responsible for deleting the on-disk payload
    /// if they also want the bytes gone.
    func forget(_ name: String) {
        entries.removeValue(forKey: name)
        entries = entries.filter { $0.value.localName != name }
        rebuildSourceIndex()
        saveNow()
    }

    /// Forget an entry by its **on-disk file name**.
    ///
    /// The only difference from `forget(_:)` is the shape of the key: a device download's record key is
    /// `serial::name`, while the list gets the on-disk name (`entry.localName`) — the two
    /// are **not** the same string; using the first overload only deletes correctly by way of "incidentally filtering by localName once more"
    /// and happening to match. Batch deletion goes through this one: the semantics are plain and it doesn't lean on that coincidence.
    ///
    /// ⚠️ Batch deletion **must** call it: this table is the only evidence that "this clip has already been downloaded from the device",
    /// and leaving residue means the same recording can never be downloaded again (`isDownloaded` stays true forever).
    func forget(localName: String) {
        entries = entries.filter {
            ($0.value.localName ?? $0.key) != localName
        }
        rebuildSourceIndex()
        saveNow()
    }

    func clearAll() {
        entries = [:]
        rebuildSourceIndex()
        saveNow()
    }

    // MARK: Source —— "who recorded this one" in the list

    /// The source of a clip. List rows render that badge based on it.
    struct ClipSource: Equatable {
        enum Kind: String {
            /// Came down from a recorder card (TicNote / D·NOTE, both `ble` and `wifi` count).
            case card
            /// Apple Watch。
            case watch
            /// Fragments left by on-device live transcription.
            case phone
            /// A file imported by the user —— no record at all in the manifest.
            case imported
            /// A clip whose text came from **live transcription** rather than the
            /// post-recording pass (`Entry.source == "live"`).
            ///
            /// ★ 2026-10-22 on request: the library must be able to tell "this one
            /// was transcribed while it was being recorded" from "a plain
            /// recording that was transcribed later" — the row badge says
            /// 实时转录 instead of the card's name.
            case live
        }

        var kind: Kind
        /// The card's identity (TicNote = the ASCII SN in the advertisement). Empty when not `.card`.
        var serial: String?
        /// The readable name recorded at library time (may be nil; fall back at display time).
        var storedName: String?
    }

    /// `on-disk file name -> ClipSource`. **Must be prebuilt**: the list has reached ~1900 entries on a real device,
    /// and scanning `entries` per row would degrade to O(n²).
    @Published private(set) var sourcesByLocalName: [String: ClipSource] = [:]

    /// Look up the source by **on-disk file name**; not found ⇒ treat as an imported file.
    ///
    /// Why not just query `entry(for:)`: manifest keys have two shapes ——
    /// device downloads are `serial::name`, watch / live streams are bare `name`, while the list has only one
    /// on-disk name. The reverse index pulls the two shapes into the same coordinate system.
    /// ★ (2026-10-19) `true` when this clip was recorded by the card's **voice key**
    /// (an AI voice memo, `Entry.source == "memo"`) — the library row badges it.
    func isVoiceMemo(forLocalName name: String) -> Bool {
        rawEntry(forLocalName: name)?.entry.source == "memo"
    }

    func source(forLocalName localName: String) -> ClipSource {
        sourcesByLocalName[localName]
            ?? ClipSource(kind: .imported, serial: nil, storedName: nil)
    }

    private func rebuildSourceIndex() {
        var index: [String: ClipSource] = [:]
        index.reserveCapacity(entries.count)
        for entry in entries.values {
            // Go by `localName` rather than the manifest key: when file names collide,
            // `localNameForDeviceFile` appends an `_SN` suffix to the on-disk name, and then
            // the key and the on-disk name are **not** the same string, while the list gets the latter.
            let diskName = entry.localName ?? ""
            guard !diskName.isEmpty else { continue }
            index[diskName] = Self.classify(entry)
        }
        sourcesByLocalName = index
    }

    private static func classify(_ entry: Entry) -> ClipSource {
        // The live-transcript mark wins over the transport: the bytes still came
        // down over BLE, but what makes this clip different is that its text was
        // produced while recording.
        if entry.source == "live" {
            return ClipSource(kind: .live, serial: entry.deviceSerial, storedName: entry.deviceName)
        }
        switch entry.transport {
        case "watch":
            return ClipSource(kind: .watch, serial: nil, storedName: entry.deviceName)
        case "stream":
            return ClipSource(kind: .phone, serial: nil, storedName: entry.deviceName)
        default:
            // ble / wifi: both came down from a recorder card, only the link differs.
            return ClipSource(kind: .card, serial: entry.deviceSerial, storedName: entry.deviceName)
        }
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
