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

    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        // .medium time style includes seconds (e.g. "9:42:07 PM"); .short omits
        // them. QA asked for the recording timestamp to show H:M:S, not just H:M.
        f.timeStyle = .medium
        return f
    }()

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
