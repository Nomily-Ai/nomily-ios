import SwiftUI

/// Watch companion: record on the wrist when the Nomi isn't with you. Clips
/// sync to the iPhone Library and run through the same transcription pipeline
/// as device recordings.
///
/// There was a second page here that mirrored the Nomi's state and could
/// start/stop it from the wrist. It was removed: the watch has no BLE link of
/// its own, so every answer had to come from the phone, and the phone can only
/// answer usefully when it is already connected — which it often isn't when
/// woken in the background. The page spent most of its life showing a status
/// that was stale, wrong, or "connecting", which is worse than not offering it.
@main
struct NomilyWatchApp: App {
    @StateObject private var link: WatchLink
    @StateObject private var recorder: WatchRecorderModel

    init() {
        let link = WatchLink()
        link.activate()
        _link = StateObject(wrappedValue: link)
        _recorder = StateObject(wrappedValue: WatchRecorderModel(link: link))
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchRecorderView()
            }
            .environmentObject(link)
            .environmentObject(recorder)
        }
    }
}
