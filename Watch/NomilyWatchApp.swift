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
    @StateObject private var language: WatchLanguageStore
    @StateObject private var link: WatchLink
    @StateObject private var recorder: WatchRecorderModel
    /// 定时录音补执行需要感知「App 回到前台」。
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Built first: its `init` swaps the string bundle, and every `L10n` read
        // below it depends on that already being in place.
        _language = StateObject(wrappedValue: WatchLanguageStore())
        let link = WatchLink()
        link.activate()
        _link = StateObject(wrappedValue: link)
        let recorder = WatchRecorderModel(link: link)
        _recorder = StateObject(wrappedValue: recorder)
        // ★ 2026-10-30：定时录音（手机 → 手表）。见 WatchLinkMessage.timedRecordCommandKey。
        // start/stop 都幂等（模型里各自有 guard），重复派发无害。
        link.onTimedRecordCommand = { [weak recorder] command, _, endsAt in
            switch command {
            case "start":
                recorder?.startRemotely()
                if let endsAt { recorder?.scheduleRemoteStop(at: endsAt) }
            case "stop":
                recorder?.stop()
                recorder?.cancelRemoteStop()
            default:
                break
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            LocalizedWatchRoot()
                .environmentObject(language)
                .environmentObject(link)
                .environmentObject(recorder)
                // ★ 抬腕回前台时补执行没落实的定时开录命令（后台送达时麦克风
                // 不可用，只能等回到前台）。start/stop 都幂等。
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    recorder.consumePendingToggle()
                    link.retryUnconfirmedTimedCommand { recorder.remoteStartPending }
                }
        }
    }
}
