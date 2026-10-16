import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Control Center quick-record control (watchOS 26+)
//
// ★ 2026-10-16 revision eight. User's words:
//
//   "even away from the Nomily watch app, add a component in the watch's control menu bar so the user can
//    add a shortcut to the Control Centre brought up by the button under the watch's Digital Crown,
//    so the user can reach recording quickly instead of hunting for Nomily on the watch"
//
// In other words: **no need to go find the App first** — press the side button (the one below the Digital Crown) to pull up Control Center, which has
// a Nomily record button; one press starts recording.
//
// ─────────────────────────────────────────────────────────────────────────
// ## ★ Why this target starts at watchOS 26 rather than following the watch App's 10.0
//
// The Control Widget API set **only exists on the watch as of watchOS 26**. The local SDK
// (WatchOS26.5) interface files say it plainly:
//
//     SwiftUI.ControlWidget                @available(iOS 18.0, macOS 26.0, watchOS 26.0, *)
//     SwiftUI.ControlWidgetConfiguration   @available(iOS 18.0, macOS 26.0, watchOS 26.0, *)
//     SwiftUI.ControlWidgetTemplate        @available(iOS 18.0, macOS 26.0, watchOS 26.0, *)
//     WidgetKit.ControlWidgetButton        @available(iOS 18.0, macOS 26.0, watchOS 26.0, *)
//     WidgetKit.StaticControlConfiguration @available(iOS 18.0, macOS 26.0, watchOS 26.0, *)
//
// Note the iOS side says 18.0 while the watchOS side says 26.0 — the same API is a full
// major version later on the watch. So this one's `WATCHOS_DEPLOYMENT_TARGET` must be set to 26.0 on its own:
// following `nomily_watch`'s 10.0 would fail `ControlWidget`'s availability check at compile time,
// and even forced through, the control wouldn't appear on 10.0~25.x watches — a case of "it compiles but there's no feature".
//
// ─────────────────────────────────────────────────────────────────────────
// ## ★ Why the control must come from the watch side, not just be written on the iPhone side
//
// Apple's docs (WidgetKit → Controls → Overview) verbatim:
//
//   "On Apple Watch, people place controls from your watchOS app or from a paired
//    iPhone in Control Center or the Smart Stack. **If you offer a watchOS app in
//    addition to an iPhone app and both apps offer controls, people can only place
//    controls from your watchOS app in Control Center or the Smart Stack.**"
//
// We have an App on both ends, so **only this one** is recognised by Control Center. Writing an
// identical control on the iPhone side as well is pure waste — the system just ignores it.
//
// ─────────────────────────────────────────────────────────────────────────
// ## ★ Why the action reuses `ToggleRecordingIntent` directly
//
// That intent was originally written for the Ultra's Action Button (`openAppWhenRun = true`, and once back in the App
// process it's dispatched to `WatchRecorderModel` by `RecordingIntentBus`). Control Center's path has
// **exactly the same** shape: one tap → bring up the App → start/stop recording.
// Writing another intent would only give "what counts as one record toggle" a second answer.
//
// ⚠️ `openAppWhenRun = true` here is **intended**, not a compromise: recording needs microphone permission, an audio
//    session and the ring timer UI, all of which live in the App. A version that secretly starts recording in the extension process
//    is neither visible nor stoppable (this pitfall is recorded at the top of `RecordingIntent.swift`).

/// That record button in Control Center.
///
/// ⚠️ Exists only on watchOS 26+ (for the reason see the top of the file). This one's deployment target is 26.0,
///    so there's **no need** to write `@available` here — writing it would only get you tripped up by the fact that "this target only runs on
///    26 and up", turning it into noise with no information.
struct NomilyRecordingControl: ControlWidget {
    /// The system keeps accounts by this string (multiple controls of one App are told apart by it). The prefix follows the extension's
    /// bundle id, not the App's — the two may diverge later.
    private static let kind = "com.nomily.app.watchkitapp.control.record"

    var body: some ControlWidgetConfiguration {
        // `StaticControlConfiguration` rather than `AppIntentControlConfiguration`:
        // this control **has no configurable options**. What the user wants is "press to start recording", and giving them a config page
        // just adds a step.
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: ToggleRecordingIntent()) {
                Label {
                    // ⚠️ The copy **deliberately reuses the Action Button's three keys**
                    //    （`watch.intent_toggle_short_title` / `_title` / `_description`）。
                    //    They're already translated into 11 languages and describe the same thing anyway
                    //    — "toggle recording once". Inventing new keys would only give the same sentence two sources,
                    //    and a future copy change is bound to miss one.
                    Text(LocalizedStringResource(
                        "watch.intent_toggle_short_title",
                        defaultValue: "Record"
                    ))
                } icon: {
                    Image(systemName: "mic.fill")
                }
            }
        }
        // The name shown in the "Control Center → Edit → Add" list.
        // Uses the **full name** rather than "Record": that list lines up several controls of the same App side by side,
        // and a two-character name is unrecognisable there.
        .displayName(LocalizedStringResource(
            "watch.intent_toggle_title",
            defaultValue: "Start or Stop Recording"
        ))
        // The description line under the name.
        .description(LocalizedStringResource(
            "watch.intent_toggle_description",
            defaultValue: "Starts a voice note on your Apple Watch, or stops the one that's running."
        ))
    }
}

/// This extension's entry point.
///
/// Only a control, no regular widget: what the user wants is "one press in Control Center", not
/// one more card in the Smart Stack. One less thing means one less refresh logic to maintain.
@main
struct NomilyWatchControlsBundle: WidgetBundle {
    var body: some Widget {
        NomilyRecordingControl()
    }
}
