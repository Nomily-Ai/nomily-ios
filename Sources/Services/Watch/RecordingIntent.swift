import AppIntents
import Foundation

/// Action Button support.
///
/// A third-party app can't bind the Ultra's Action Button directly — there is
/// no press callback. What it can do is publish an App Shortcut, which the user
/// then assigns under Settings → Action Button → Action: Shortcut. The button
/// holds exactly one action, so start and stop have to be the same press; this
/// intent toggles, matching the on-screen button.
///
/// Compiled into *both* apps, which looks redundant and isn't. That Action
/// Button picker lists only shortcuts from the user's own Shortcuts library —
/// App Shortcuts published by an `AppShortcutsProvider` never appear in it, no
/// matter how correctly they register. The library can only be edited on the
/// iPhone, and the iPhone's Shortcuts editor only offers actions the *iOS*
/// binary declares. So the action has to exist on the phone for the shortcut to
/// be authorable at all: a shortcut carrying it runs whichever copy is local to
/// the device it fires on.
///
/// The two copies record different things, because the two devices can. On the
/// wrist it toggles the watch's own microphone. On the phone it toggles the
/// connected Nomi — the phone has no mic capture path of its own, and remotely
/// starting the *watch* from the phone isn't possible: WatchConnectivity can
/// wake the iOS app from the watch but has no API for the reverse, so a
/// phone-issued start would sit queued until the watch app next happened to
/// run.
struct ToggleRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "watch.intent_toggle_title"

    // The two platforms record different things, and the Shortcuts editor shows
    // this text to someone deciding what the action does.
    #if os(watchOS)
    static var description = IntentDescription("watch.intent_toggle_description")
    #else
    static var description = IntentDescription("watch.intent_toggle_description_ios")
    #endif

    /// Opens the app instead of recording headless. The elapsed timer and the
    /// start/stop haptic are the only signals that a take is live, and an audio
    /// session brought up with no UI attached is easy to strand — a silently
    /// failed press would cost the user the whole recording.
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if os(watchOS)
        RecordingIntentBus.requestToggle()
        #else
        try await NomiRecordingToggle.run()
        #endif
        return .result()
    }
}

#if os(iOS)

/// Phone-side implementation: start or stop the Nomi's own recording, matching
/// what the record button in the Recordings tab does.
@MainActor
enum NomiRecordingToggle {
    /// How long to let the app's own auto-reconnect finish before giving up.
    /// A cold launch has to power on the radio, find the peripheral and
    /// negotiate before any command can go out.
    private static let connectTimeout: TimeInterval = 12

    static func run() async throws {
        let client = try await awaitConnectedClient()
        // Ask rather than trust `lastDeviceInfo`: it is still nil in the first
        // moments after a connect, and guessing wrong here sends precisely the
        // opposite command — stopping a take the user meant to start.
        let info = try? await client.getDeviceInfo()
        let isRecording = (info ?? client.lastDeviceInfo)?.isRecording == true
        if isRecording {
            _ = try await client.stopRecording()
        } else {
            try await client.startRecording()
        }
    }

    /// Waits for the client `RootView.autoReconnect` is already bringing up
    /// rather than starting a second connect of its own — two reconnects racing
    /// for the same peripheral is a worse failure than waiting a beat.
    private static func awaitConnectedClient() async throws -> DnoteClient {
        let deadline = Date().addingTimeInterval(connectTimeout)
        while Date() < deadline {
            if let client = AppEnvironment.shared?.bluetooth.client { return client }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ToggleRecordingError.nomiNotConnected
    }
}

/// `CustomLocalizedStringResourceConvertible` rather than `LocalizedError` —
/// it's the conformance Shortcuts reads when it renders a failed action.
enum ToggleRecordingError: Error, CustomLocalizedStringResourceConvertible {
    case nomiNotConnected

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .nomiNotConnected: return "watch.intent_no_nomi"
        }
    }
}

#endif

#if os(watchOS)

/// Watch-only. An iPhone-side App Shortcut would publish a "Record with Nomily
/// Nomi" that opens the app and stops there — a promise the phone can't keep.
struct NomilyWatchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: ["Record with \(.applicationName)"],
            shortTitle: "watch.intent_toggle_short_title",
            systemImageName: "mic.fill"
        )
    }
}

/// Parking spot between the intent and the recorder.
///
/// `perform()` runs in the app's own process, but on a cold launch it can get
/// there before the recorder exists — so the request is left here and drained
/// from both sides: `WatchRecorderModel` takes it at init, and listens for the
/// notification while it's already alive.
@MainActor
enum RecordingIntentBus {
    static let didRequestToggle = Notification.Name("watch.recording.toggleRequested")
    static var pendingToggle = false

    static func requestToggle() {
        pendingToggle = true
        NotificationCenter.default.post(name: didRequestToggle, object: nil)
    }
}

#endif
