import SwiftUI

/// The expression that permanently resides on the watch home screen.
///
/// ★ added in 2026-10-16 revision thirteen (user: "the Nomily AI app's settings need one more
///    to set the watch's home-screen eye expression").
///
/// ## This one and `WatchMenuPreferences` / `WatchRingStyleStore` are **the same kind of thing**
/// Stored locally on the watch, a single `UserDefaults` key, an `ObservableObject` so the home screen redraws at once.
/// The approach copies those two (single key + unreadable counts as never stored); it doesn't start its own.
///
/// ## The `private(set)` is deliberate: **the author is the phone, not the watch**
/// Unlike the other two preferences, the **only** writer of this one is the iPhone —
/// the user picks in the phone's Settings and it's pushed over via `WatchConnectivity` (see `WatchLink`).
/// The watch itself doesn't show a picker (that little bit of space is left for other things), so it exposes only `apply(_:)` outward,
/// with no `select(_:)`.
///
/// ⚠️ But it **must** keep a local copy on the watch: `updateApplicationContext` is "the newest version replaces
///    the version not yet sent out", so it guarantees neither that the phone is online nor that delivery happens while the watch is alive.
///    If a cold-starting watch leans only on what's in memory, the first frame on wrist-raise draws the default expression first and
///    jumps only when the phone remembers to push. Once it's stored, the first frame is the one the user last chose.
final class WatchFaceStore: ObservableObject {
    static let shared = WatchFaceStore()

    private static let key = "watch.face_style.v1"

    /// The style currently resident.
    ///
    /// **Never stored = `calm`** (what the face looked like before the thirteenth revision) — the default must equal
    /// "the behaviour when this feature doesn't exist", otherwise long-time users upgrading will find the face on their watch changed for no reason.
    @Published private(set) var style: BotFaceStyle

    // MARK: ★ 2026-10-20 face settings pushed from the phone
    //
    // Same pattern as `style`: the **phone is the only writer** (pushed via
    // `WatchConnectivity`), the watch keeps a local copy so a cold start draws
    // the user's last choice on the first frame, and a missing/unreadable
    // value means "keep what's here" — never a silent revert to default.

    /// The eye colour the phone picked, as `RRGGBB` hex. **`nil` = follow the
    /// watch's own "Appearance" palette** (the pre-existing watch-local choice).
    @Published private(set) var colorHex: String?
    /// Blink pace. Missing key = keep the current one (never regress to default).
    @Published private(set) var blinkSpeed: BotBlinkSpeed = .normal
    /// Whether the idle expression auto-cycles inside the square frame.
    @Published private(set) var autoCycle: Bool = true
    /// Whether the rounded-square frame is drawn around the face.
    @Published private(set) var frameVisible: Bool = true

    private let defaults: UserDefaults

    /// Keys for the persisted copies — versioned the same way as `key` above.
    private static let colorKey = "watch.face_color.v1"
    private static let speedKey = "watch.blink_speed.v1"
    private static let autoCycleKey = "watch.face_auto_cycle.v1"
    private static let frameKey = "watch.face_frame.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style = BotFaceStyle.decode(defaults.string(forKey: Self.key)) ?? .calm
        colorHex = defaults.string(forKey: Self.colorKey)
        blinkSpeed = BotBlinkSpeed(rawValue: defaults.string(forKey: Self.speedKey) ?? "") ?? .normal
        // `object(forKey:)` returns nil when never stored — that must read as the
        // default (true), while an explicit `false` survives. Hence the tri-state dance.
        if defaults.object(forKey: Self.autoCycleKey) != nil {
            autoCycle = defaults.bool(forKey: Self.autoCycleKey)
        }
        if defaults.object(forKey: Self.frameKey) != nil {
            frameVisible = defaults.bool(forKey: Self.frameKey)
        }
    }

    /// The choice pushed from the phone. **Idempotent** — every handshake the phone re-pushes the same value,
    /// and writing to disk every time is pointless.
    ///
    /// ⚠️ **An unrecognised value is ignored outright; it does not fall back to the default.** The phone's and watch's app versions may differ
    ///    (the watch's update is pushed by the iPhone at its discretion, often a restart cycle late). When a new phone pushes a
    ///    tag the old watch doesn't have, reverting to `calm` would leave the user "having changed the expression only to see it back at default",
    ///    whereas keeping it as-is is just "this one didn't take effect" — of two evils, choose the lesser.
    func apply(_ tag: String?) {
        guard let next = BotFaceStyle.decode(tag), next != style else { return }
        style = next
        defaults.set(next.rawValue, forKey: Self.key)
    }

    /// The full face-settings bundle pushed from the phone (★ 2026-10-20).
    /// Called with the whole `receivedApplicationContext`; every key is optional —
    /// an absent key simply leaves that setting untouched (old phone → new watch).
    func applySettings(_ context: [String: Any]) {
        if let hex = context[WatchLinkMessage.faceColorKey] as? String {
            // Validate the shape: exactly 6 hex digits, else ignore (a garbled
            // string must not blank the eyes — `Color(hex:)` would fall back
            // to white, which on a light watch face is invisible).
            if isValidFaceHex(hex) {
                if hex != colorHex {
                    colorHex = hex
                    defaults.set(hex, forKey: Self.colorKey)
                }
            }
        }
        if let raw = context[WatchLinkMessage.blinkSpeedKey] as? String,
           let speed = BotBlinkSpeed(rawValue: raw), speed != blinkSpeed {
            blinkSpeed = speed
            defaults.set(raw, forKey: Self.speedKey)
        }
        if let auto = context[WatchLinkMessage.faceAutoCycleKey] as? Bool, auto != autoCycle {
            autoCycle = auto
            defaults.set(auto, forKey: Self.autoCycleKey)
        }
        if let frame = context[WatchLinkMessage.faceFrameKey] as? Bool, frame != frameVisible {
            frameVisible = frame
            defaults.set(frame, forKey: Self.frameKey)
        }
    }
}
