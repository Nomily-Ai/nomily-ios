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
        let stem = (filename as NSString).deletingPathExtension
        guard let date = parser.date(from: stem) else { return filename }
        return display.string(from: date)
    }

    static func date(from filename: String) -> Date? {
        let stem = (filename as NSString).deletingPathExtension
        return parser.date(from: stem)
    }

    /// Builds a name this same type can parse back.
    static func filename(for date: Date, extension ext: String) -> String {
        "\(parser.string(from: date)).\(ext)"
    }
}
