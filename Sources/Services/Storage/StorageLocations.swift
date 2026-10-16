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

    /// 待办转录队列（跨启动存活）。
    ///
    /// 落在 `root` 而不是 `decryptedDir`：它不是某条录音的产物，而是"还没
    /// 干完的活"的清单。放在 `decryptedDir` 里会被"删录音"顺手带走，而队列
    /// 本身会自己校验对应的音频还在不在 —— 让删录音与删队列各管各的。
    static var transcriptionQueueURL: URL {
        root.appendingPathComponent("transcription-queue.json", isDirectory: false)
    }

    /// 摘要 / 翻译 / 导出三类长任务的落盘台账（跨启动存活）。
    ///
    /// ★ 2026-10-16 十二改：与 `transcriptionQueueURL` **并列**而不是合并 ——
    /// 转录那条队列有自己的 624 行管线与一套已经跑通的语义，把它并进来是拿
    /// "唯一能用的那条路"去换一个更漂亮的抽象；见 `JobQueue` 顶部那段。
    ///
    /// 落点选在 `root`（同 `transcriptionQueueURL`）：它是"还没干完的活"的
    /// 清单，不是某条录音的产物 —— 放进 `decryptedDir` 会被"删录音"顺手带走。
    static var jobsQueueURL: URL {
        root.appendingPathComponent("jobs-queue.json", isDirectory: false)
    }

    /// 落盘诊断流水的落点。
    ///
    /// ⚠️ Deliberately **not via `root`** (that is the app group container). `--domain-type` of `xcrun devicectl`
    /// separates "app sandbox" and "app group container" into two kinds; landing in the sandbox's
    /// `Documents/` lets it be pulled out with the most straightforward command:
    ///
    /// ```
    /// xcrun devicectl device copy from \
    ///   --device <UDID> --domain-type appDataContainer \
    ///   --domain-identifier com.nomily.app \
    ///   --source Documents/ticnote-ble.log --destination /tmp/
    /// ```
    ///
    /// A side benefit: `Documents/` is a user-visible directory (once `UIFileSharingEnabled` is on
    /// it can be seen directly in the Files app), so users can also send this log to others themselves.
    static var diagLogURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("ticnote-ble.log", isDirectory: false)
    }
}

/// ## On-disk diagnostic log —— writing the BLE frame sequence into the app sandbox
///
/// ### Why it exists
/// When diagnosing problems like "tap record → operation fails", `Logger` (os_log) **can't be read** locally:
/// on the macOS side `log stream --device-udid` is blocked by the sandbox (`log: Cannot run while sandboxed`),
/// and `idevicesyslog` can connect through usbmuxd but can't get the os_log subsystem.
/// Yet the card's behavior can only be seen from the **frame sequence** (who sent what, whether the card answered),
/// so we simply write the frame log to `Documents/ticnote-ble.log` and pull it out with `devicectl`.
///
/// ### Three hard constraints
/// 1. **Never affect the protocol**: append only, the caller never waits —— file writes are dispatched to a serial queue.
///    Never `await` here, or the hot path of `write()` would be held up by disk I/O.
/// 2. **Must not flood**: voice frames run at ~100 frames/s on a real device, so record only the **1st** and **every 100th**;
///    control frames are very low rate (about 1 Hz polling), record them all.
/// 3. **Self-bounded**: once `maxBytes` is exceeded, roll over as a whole (the current file moves to `.1`),
///    at most two copies, no unbounded growth. **Never deletes user recordings** —— this file is unrelated to `audio_clips/`.
///
/// ### File format
/// Each line: `[+12.345s] 14:30:22.824 <TAG> body`
/// The `+12.345s` prefix is in-process monotonic time, used to compute the interval between two frames (wall clock can
/// print a dozen lines within the same second, hiding the interval).
final class TicNoteDiagLog: @unchecked Sendable {
    static let shared = TicNoteDiagLog()

    /// Per-file cap. Enough to hold several complete "connect → start recording → stop recording" rounds (even logging every control frame is only tens of KB).
    private static let maxBytes = 512 * 1024

    /// Monotonic baseline at process start, used to print `+12.345s`.
    private let t0 = Date()
    private let queue = DispatchQueue(label: "com.nomily.app.ticnote.diag", qos: .utility)
    private var handle: FileHandle?

    private init() {}

    /// Whether to log. By default **on only in DEBUG**; when you need to capture in Release,
    /// override with `TicNoteDiagLogEnabled` in `UserDefaults` (`defaults write` or the settings page).
    static var isEnabled: Bool {
        if let forced = UserDefaults.standard.object(forKey: "TicNoteDiagLogEnabled") as? Bool {
            return forced
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Log one line. **Does not block the caller**.
    static func log(_ tag: String, _ text: String) {
        guard isEnabled else { return }
        shared.append(tag, text)
    }

    /// Log one frame (shared for outbound/inbound). Hex; outbound marked `→`, inbound marked `←`.
    static func frame(_ tag: String, _ data: Data) {
        guard isEnabled else { return }
        shared.append(tag, data.map { String(format: "%02X", $0) }.joined(separator: " "))
    }

    /// Call this first when you want to reproduce an operation from scratch (e.g. before the user taps record).
    static func reset() {
        guard isEnabled else { return }
        // Don't write a `[self]` capture list in a static method —— there `self` is a metatype, which is an easy trap.
        let sink = shared
        sink.queue.async {
            sink.rotateIfNeeded(force: true)
            sink.appendOnQueue("DIAG", "---- log reset ----")
        }
    }

    /// The current log file (for UI such as "export diagnostics").
    static var fileURL: URL { StorageLocations.diagLogURL }

    // MARK: Internal (all runs on `queue` only)

    private func append(_ tag: String, _ text: String) {
        queue.async { [self] in
            appendOnQueue(tag, text)
        }
    }

    /// Note: call **only on `queue`**.
    private func appendOnQueue(_ tag: String, _ text: String) {
        rotateIfNeeded(force: false)
        guard let handle else { return }
        let elapsed = Date().timeIntervalSince(t0)
        let wall = Self.wallFormatter.string(from: Date())
        // Single-line cap: one malformed frame should not flood the log to MB scale.
        let body = text.count > 2_000 ? String(text.prefix(2_000)) + "…(truncated)" : text
        let line = String(format: "[+%.3fs] %@ %@ %@\n", elapsed, wall, tag, body)
        if let data = line.data(using: .utf8) {
            // On failure give up this line —— the diagnostic's own errors must never bubble into the protocol path.
            try? handle.write(contentsOf: data)
        }
    }

    private func rotateIfNeeded(force: Bool) {
        let url = StorageLocations.diagLogURL
        if handle == nil {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            return
        }
        guard force || currentSize(url) > Self.maxBytes else { return }
        // Rolling over: close the current one → back it up as .1 → reopen empty.
        try? handle?.close()
        handle = nil
        let backup = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    private func currentSize(_ url: URL) -> Int {
        guard let offset = try? handle?.offset() else { return 0 }
        return Int(offset)
    }

    private static let wallFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
