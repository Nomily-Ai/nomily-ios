import Foundation

/// Wire contract between the iPhone app and the watch app. Both targets
/// compile this file (see `project.yml`), so the keys can't drift apart.
///
/// Deliberately small: clips go one way, a store-confirmation comes back. An
/// earlier version also carried device status and start/stop commands for a
/// Nomi remote on the wrist; that was removed, since the watch has no BLE link
/// of its own and the phone can only answer when it happens to be connected.
enum WatchLinkMessage {
    /// Attached to `transferFile` so the phone keeps the watch-side filename,
    /// which is already in `RecordingName`'s `yyyyMMddHHmmss` form.
    static let fileNameKey = "name"

    /// Sent back by the phone (via `transferUserInfo`, so it survives an app
    /// restart) once the clip is on disk in the Library. Only then may the
    /// watch delete its copy: WatchConnectivity reports a transfer "finished"
    /// once the *daemon* has the file, which is one crash away from the app
    /// never storing it — and the wrist copy is the only other one.
    static let storedKey = "stored"

    // MARK: - Recorder state (watch → phone)
    //
    // Pushed with `updateApplicationContext`, which suits a heartbeat better
    // than `sendMessage`: it needs no reachability, a new push *replaces* an
    // undelivered one instead of queueing behind it, and the latest value is
    // waiting in `receivedApplicationContext` when the phone app next launches.

    /// Whether a take is running on the wrist right now.
    static let recordingKey = "recording"
    /// When it started, as epoch seconds — the phone renders the elapsed time
    /// itself rather than being fed a duration that goes stale between pushes.
    static let recordingSinceKey = "recordingSince"
    /// Clips recorded and waiting to reach the phone.
    static let transferPendingKey = "transferPending"
    /// Epoch seconds, refreshed on every push including the idle 10 s beats.
    /// Without it two identical payloads are indistinguishable, and the phone
    /// can't tell a watch that's still recording from one that stopped talking
    /// mid-take — which is the whole difference between a live status and a
    /// lie.
    static let heartbeatKey = "heartbeat"

    // MARK: - Face style (phone → watch)
    //
    // ★ 2026-10-16 thirteenth revision: this is the **first time** the phone actively pushes an appearance setting to the watch.
    // Before this, phone→watch had only one message, `stored` (`transferUserInfo`, a one-shot event),
    // and "what the watch home screen looks like" had always been a **local** watch preference (colour, quick menu, language).
    // This round the user explicitly asked for the "home-screen eye expression" to sit **in the iPhone's Settings**,
    // so it has to cross this link.

    /// Which expression the home-screen face shows. The value is `BotFaceStyle.rawValue`.
    ///
    /// ⚠️ Goes through `updateApplicationContext` rather than `transferUserInfo`: this pushes
    ///    the "**current value**", not "something happened". A late-arriving old value means nothing,
    ///    and the definition of `updateApplicationContext` is precisely "the new version **replaces**
    ///    the version not yet sent" — when the user taps three times to change the expression, the watch should see only the last one.
    ///
    /// ℹ️ The two directions' application contexts are **separate** slots, so the watch's
    ///    "recording state" push (also `updateApplicationContext`) won't be crowded out by this one.
    static let faceStyleKey = "faceStyle"

    // MARK: - Face settings (phone → watch, ★ 2026-10-20)
    //
    // The user asked to drive the face's colour, blink pace and the "square frame with
    // auto-cycling expressions" from the phone. Same channel and same caveats as
    // `faceStyleKey`: one `updateApplicationContext` per push, "newest value wins",
    // watch-local defaults apply when a key is missing (old phone → new watch).

    /// The eye colour as `RRGGBB` hex (no `#`). Absent = follow the watch's own
    /// "Appearance" palette — the pre-existing watch-local preference stays authoritative
    /// until the user actually picks a colour on the phone.
    static let faceColorKey = "faceColor"
    /// `BotBlinkSpeed.rawValue` — scales the blink-gap tiers. Absent = `normal`.
    static let blinkSpeedKey = "blinkSpeed"
    /// Whether the idle expression auto-cycles inside the square frame. Absent = `true`
    /// (the dynamic behaviour the user asked for is the default).
    static let faceAutoCycleKey = "faceAutoCycle"
    /// Whether the rounded-square frame is drawn around the face. Absent = `true`.
    static let faceFrameKey = "faceFrame"

    // MARK: - Recaps (phone → watch, ★ 2026-10-23)
    //
    // The user asked: "watch 那边能否靠 Siri Recap 的看齐" — Apple's Siri Recap
    // (watchOS 26/27, S11) shows a wrist digest of your day, but it is opt-in,
    // beta, and not offered in China. Our answer is a Nomily recap: every time
    // the phone finishes a summary job, it extracts a tiny digest (title +
    // ≤3 key points) and pushes it here. The watch keeps the last 7 days and
    // shows them from a home-menu page.

    /// The value is JSON-encoded `Data` of `[WatchRecap]` — `applicationContext`
    /// only takes property-list values, so the array travels as an opaque blob
    /// and both ends decode with this same shared struct (this file is compiled
    /// into both targets, so the wire format can't drift).
    static let recapsKey = "recaps"

    // MARK: - Timed recording command (phone → watch, ★ 2026-10-30)
    //
    // 用户："定时录音应该是归纳到 Apple Watch 上面，只对这个设备有效"——
    // 定时窗口到点后，手机不再用麦克风录，而是让**手表**开始录（手表是贴身
    // 设备，整夜在腕上；手机进程死了也没有替代品）。命令走
    // `updateApplicationContext`：不需要可达性，"最新值胜出"，手表 App 下次
    // 运行时一定拿到。watchOS 的麦克风只在 App 前台可用，所以手表端把命令
    // 存下来、抬腕进 App 时补执行（见 `WatchLink.retryUnconfirmedTimedCommand`）。

    /// `"start"` = 让手表开始录音；`"stop"` = 停止。手表端对 start 幂等
    /// （已在录就忽略），对 stop 幂等（没在录就忽略）。
    static let timedRecordCommandKey = "timedRecordCommand"
    /// 手机签发命令的时刻（epoch 秒）。手表用去重：applicationContext 会被
    /// 后续的任何推送（表情/Recap）原样重发，同一个命令只能生效一次。
    static let timedRecordIssuedAtKey = "timedRecordIssuedAt"
    /// 录音窗口结束时刻（epoch 秒）。手表据此自己兜底停止——手机进程在窗口
    /// 结束前死了也停得下来。
    static let timedRecordEndsAtKey = "timedRecordEndsAt"

    // MARK: - Reminder request (watch → phone, ★ 2026-10-30)
    //
    // 用户："支持在手表里面点击可以同步到手机的待办里面"。
    // 手表 Recap 详情里的待办行可点，点了就把"这一条"发回手机，手机写进系统
    // 「提醒事项」。走 `transferUserInfo`：这是一次**事件**（不能丢），不是
    // "最新值"，而 transferUserInfo 会排队重发直到送达。

    /// 要加进提醒事项的待办文本（纯文本）。
    static let reminderTitleKey = "reminderTitle"
    /// 来源录音名，写进提醒的备注里（"来自 Nomily 录音《…》"）。
    static let reminderSourceKey = "reminderSource"
}

/// One recap entry on the wire. Small by design — the watch shows it on one screen.
///
/// `id` is the clip's `yyyyMMddHHmmss` name: re-summarising the same clip
/// **replaces** its recap instead of stacking a duplicate (same id semantics
/// the phone's Library uses for clips).
/// `recordedAt` is when the take was made (parsed from the name); `createdAt`
/// is when the digest was generated — the 7-day retention clock runs on
/// `createdAt`, so a re-summary refreshes the entry instead of letting an old
/// recording's recap expire the moment it lands.
struct WatchRecap: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let points: [String]
    /// ★ 2026-10-30（用户："在里面可以查看到待办，支持在手表里面点击可以同步到
    /// 手机的待办里面"）：这条摘要里明确承诺的待办（最多 5 条）。手表详情页把它们
    /// 列成可点的行，点一下 → 手机写进「提醒事项」。
    let todos: [String]
    let recordedAt: Date
    let createdAt: Date

    init(
        id: String,
        title: String,
        points: [String],
        todos: [String] = [],
        recordedAt: Date,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.points = points
        self.todos = todos
        self.recordedAt = recordedAt
        self.createdAt = createdAt
    }

    /// 手写解码：`todos` 是后加的字段，旧版本推上来的 JSON 里没有它——
    /// 合成解码会因此整条失败，手表上一条回顾都读不出来。缺省当空数组。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        points = try c.decode([String].self, forKey: .points)
        todos = try c.decodeIfPresent([String].self, forKey: .todos) ?? []
        recordedAt = try c.decode(Date.self, forKey: .recordedAt)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    /// Both ends keep at most this many recaps (phone outbox / watch store).
    static let limit = 8
    /// Recaps older than this (by `createdAt`) drop off, on the phone as well
    /// as the watch — an outbox entry no watch will ever see is just clutter,
    /// and a wrist entry nothing refreshes any more is a lie about the past.
    static let retention: TimeInterval = 7 * 24 * 3600
}
