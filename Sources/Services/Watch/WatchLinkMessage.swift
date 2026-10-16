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
}
