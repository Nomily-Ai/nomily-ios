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
    // ★ 2026-10-16 十三改：这是**第一次**由手机主动把手表的外观设置推过去。
    // 在此之前手机→手表只有一条 `stored`（`transferUserInfo`，一次性事件），
    // 而"手表首页长什么样"一直是手表**本地**偏好（颜色、快捷菜单、语言）。
    // 用户这一轮明确要求把"首页眼睛的表情"摆在 **iPhone 的设置**里，
    // 所以它必须过这条线。

    /// 首页那张脸摆哪个表情。值是 `BotFaceStyle.rawValue`。
    ///
    /// ⚠️ 走 `updateApplicationContext` 而不是 `transferUserInfo`：这推的是
    ///    "**当前值**"，不是"发生了一件事"。晚到的旧值没有意义，
    ///    而 `updateApplicationContext` 的定义正是"新的一版**替换**掉
    ///    还没送出去的那一版" —— 用户连点三下换个表情，手表只该看到最后那个。
    ///
    /// ℹ️ 两个方向的 application context 是**各自独立**的槽位，所以手表那条
    ///    "录音状态"的推送（也是 `updateApplicationContext`）不会被这条挤掉。
    static let faceStyleKey = "faceStyle"
}
