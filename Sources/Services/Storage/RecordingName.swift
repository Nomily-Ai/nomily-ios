import Foundation

/// The `yyyyMMddHHmmss` clip-naming convention, shared by the device, the
/// phone and the watch app (which compiles this file into its own target so
/// wrist recordings sort and title themselves like device clips).
///
/// Parses filenames like `20260415214207.opus` into human-readable titles
/// such as "Apr 15 at 9:42 PM". Falls back to the raw filename when the name
/// doesn't match the expected timestamp pattern.
enum RecordingName {
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// The "Apr 15, 2026 at 9:42:07 PM" title.
    ///
    /// ★ 2026-10-16 十三改：**跟着 App 语言走**（`AppLocale`），不再是
    /// 设备语言。这一处是全 App 最要紧的日期格式化点 ——
    /// `LibraryItem.displayTitle` 用它，而 `displayTitle` 在十八处被引用
    /// （列表、详情页标题、玩家、思维导图、回收站、导出文件名…）。
    /// 以前它是 `static let`，locale 默认取 `Locale.current`，
    /// 于是"In-app 选英文"之后界面全英文、**录音的年月日还是中文**。
    ///
    /// ⚠️ 这是**共享文件**（ios / watch / watchControls 之外的三个 target 里的
    ///    两个都编它，见 `project.yml`），改它要保证 `AppLocale` 在两端都存在
    ///    —— 它在 `Sources/Services/Localization/AppLanguage.swift` 里，
    ///    那个文件同样列在 `nomily_watch` 的 sources 下。
    ///    下面的 `parser` 则**必须**保持 `en_US_POSIX`：它解析的是**文件名**，
    ///    跟着语言变会让同一个文件在不同语言下解析出不同的日期。
    private static var display: DateFormatter {
        AppLocale.formatter("recording.display_title") { f in
            f.dateStyle = .medium
            // .medium time style includes seconds (e.g. "9:42:07 PM"); .short
            // omits them. QA asked for the recording timestamp to show H:M:S.
            f.timeStyle = .medium
        }
    }

    static func displayTitle(for filename: String) -> String {
        guard let date = date(from: filename) else { return filename }
        return display.string(from: date)
    }

    static func date(from filename: String) -> Date? {
        let stem = (filename as NSString).deletingPathExtension
        if let exact = parser.date(from: stem) { return exact }
        // Embedded timestamp, e.g. TicNote clips: `ticnote_20261009-110934_6AC74377`.
        // Falling back to the *real* recording time — rather than the file's
        // download mtime — keeps the Library sorted by when it was recorded and
        // renders the same "date at time" title D·NOTE clips get.
        for candidate in Self.embeddedCandidates(in: stem) {
            if candidate.count == 14, let d = parser.date(from: candidate) { return d }
        }
        return nil
    }

    /// Plausible timestamp strings hiding inside `stem`:
    /// a 14-digit run, or `8 digits + '-' + 6 digits` joined back together.
    private static func embeddedCandidates(in stem: String) -> [String] {
        let chars = Array(stem)
        var out: [String] = []
        var i = 0
        while i < chars.count {
            guard chars[i].isNumber else { i += 1; continue }
            var j = i
            while j < chars.count, chars[j].isNumber { j += 1 }
            let run = chars[i..<j]
            let n = j - i
            if n == 14 {
                out.append(String(run))
            } else if n == 8, j < chars.count, chars[j] == "-" {
                let after = j + 1
                var k = after
                while k < chars.count, chars[k].isNumber { k += 1 }
                if k - after == 6 {
                    out.append(String(run) + String(chars[after..<k]))
                }
            }
            i = j
        }
        return out
    }

    /// Builds a name this same type can parse back.
    static func filename(for date: Date, extension ext: String) -> String {
        "\(parser.string(from: date)).\(ext)"
    }
}
