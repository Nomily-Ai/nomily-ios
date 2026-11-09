import SwiftUI
import WatchKit
import os.log

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

// MARK: - ★ 2026-11-06 后台刷新排程（不点开 App 也能收发数据）
//
// 用户："不点开 App 手表就跟手机连不上，希望 App 启动后保持链接——这策略可行吗？"
//
// ## 结论（按 Apple 文档核实）
// **实时连接（`isReachable`）不可能常驻**：它要求两端 App 都在前台，手表 App 一进
// 后台就被挂起——系统设计，无 API 可绕。但**数据不依赖实时连接**：
// `applicationContext` / `transferUserInfo` / 文件传输都是"投递到收件箱"，App 被
// 唤醒的瞬间由 WCSession 激活回调自动送达。
//
// ## 这套排程做什么
// 给自己排 `WKApplicationRefreshBackgroundTask`（预算制，约每小时 1-2 次，系统可能
// 推迟）：被叫醒 → App init 里 `link.activate()` 幂等激活会话 → 手机的收件箱
// （设置/表情/待传回执等）自动收完 → `runOnce` 把链条续上（排下一次）。
// 录音中不依赖这个：workout 会话本来就全程保活常显。
//
// ⚠️ `runOnce` 里**不要碰录音模型**：后台唤醒时 `@StateObject` 的 wrappedValue
//    还没执行（首帧才创建），模型可能不存在。

enum WatchBackgroundRefresher {
    static let taskID = "com.nomily.watch.refresh"
    private static let lastScheduledKey = "watch.bgrefresh.last.v1"
    private static let log = Logger(subsystem: "com.nomily.app.watch", category: "bgrefresh")

    /// 排下一次（1 小时后）。**4 小时内已有排程就不叠加**——回前台、后台任务结束
    /// 都会调这里，无脑排会把队列堆满（系统对重复排程的预算惩罚最狠）。
    static func scheduleNext() {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: lastScheduledKey)
        if last > 0, Date().timeIntervalSince1970 - last < 4 * 3600 { return }
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: Date().addingTimeInterval(3600),
            userInfo: nil
        ) { error in
            log.error("schedule failed: \(String(describing: error), privacy: .public)")
        }
        defaults.set(Date().timeIntervalSince1970, forKey: lastScheduledKey)
        log.info("background refresh scheduled (+1h)")
    }

    /// 后台任务到达。收件由 WCSession 激活自动完成，这里只续链条。
    static func runOnce() async {
        log.info("background refresh fired")
        scheduleNext()
    }
}

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
                // ★ 2026-11-06（全天候语义，用户："全天候录音打开的就不存在说不录音
                // 这么一说"）：全天候开着时远程 stop 无效——只撤掉到点兜底停的定时器，
                // 录音不动。重放的旧 stop 已在 WatchLink 按 issuedAt 挡掉，这里是
                // 第二道保险（新鲜 stop 命令 vs 全天候开关，开关说了算）。
                if WatchRecordingPrefs.shared.allDayRecording {
                    recorder?.cancelRemoteStop()
                } else {
                    recorder?.stop()
                    recorder?.cancelRemoteStop()
                }
            default:
                break
            }
        }
        // ★ 2026-11-05（全天候录音开关双端同步）：手机上翻的开关落到这里——
        // 只在值真的变了时写偏好 + 推模型（setPowerSaver 幂等，但别白动采样器）。
        // ★ 第四轮（用户："点击了全天候录音的开关则需要自动就开启了录音"）：
        // 手机上翻开开关，手表**当场自动开录**——autoStartForAllDayIfNeeded 幂等，
        // 与表上设置页那条路共用一个收口，同时触发也只会开一场。
        link.onAllDaySetting = { [weak recorder] on in
            guard WatchRecordingPrefs.shared.allDayRecording != on else { return }
            WatchRecordingPrefs.shared.allDayRecording = on
            recorder?.setPowerSaver(on)
            if on {
                recorder?.autoStartForAllDayIfNeeded()
            } else {
                // ★ 2026-11-06（全天候语义，用户："手机的开关设置全天候录音的开关
                // 也要跟随一样"）：手机上关开关 = 唯一的停止方式。此刻偏好已是
                // false，stop 末尾的自动续录不会触发；没在录则幂等空操作。
                recorder?.stop()
            }
        }
        // ★ 2026-11-06（表情常亮开关）：手机上翻的开关落到手表偏好。
        // 只影响暗显时首页画不画表情，不碰录音模型，无需其他动作。
        link.onAlwaysOnFaceSetting = { on in
            guard WatchRecordingPrefs.shared.alwaysOnFace != on else { return }
            WatchRecordingPrefs.shared.alwaysOnFace = on
        }
        // ★ 2026-11-06（声纹注册回执）：手机注册完成（成败都回）→ 落到共享状态，
        // 声纹页据此把"已发送"换成"已更新/失败"，并把开始按钮换掉。
        // 状态单例是 MainActor，这里跳一跳（回调源头是 WCSession 的任务链）。
        link.onVoiceprintResult = { id, ok in
            Task { @MainActor in
                WatchVoiceprintEnrollState.shared.apply(resultID: id, ok: ok)
            }
        }
        // ★ 2026-11-06 二轮（"让脸活起来"四设置）：手机上改 → 落手表偏好。
        // 只在值真的变了时写，避免无谓的UserDefaults写入与页面重绘。
        link.onEyeShapeSetting = { raw in
            guard WatchRecordingPrefs.shared.eyeShapeRaw != raw else { return }
            WatchRecordingPrefs.shared.eyeShapeRaw = raw
        }
        link.onDrowsySetting = { enabled, after in
            guard WatchRecordingPrefs.shared.drowsyEnabled != enabled
                    || WatchRecordingPrefs.shared.drowsyAfter != after else { return }
            WatchRecordingPrefs.shared.drowsyEnabled = enabled
            WatchRecordingPrefs.shared.drowsyAfter = after
        }
        link.onPupilFollowSetting = { on in
            guard WatchRecordingPrefs.shared.pupilFollow != on else { return }
            WatchRecordingPrefs.shared.pupilFollow = on
        }
    }

    var body: some Scene {
        WindowGroup {
            LocalizedWatchRoot()
                .environmentObject(language)
                .environmentObject(link)
                .environmentObject(recorder)
                // ★ 2026-11-03 八轮：电量采样从**启动**就开始，不等用户打开电量页。
                //   旧算法要十分钟起步，等打开页面才采等于每次进去都是「Collecting…」；
                //   九轮换成回归 + 累计掉电后门槛降了，但**样本越多越准**这条没变。
                //   `start()` 幂等，抬腕回前台再补一条（后台期间定时器是停的）。
                // ★ 2026-11-04 九轮：顺手把录音状态对一次——App 被系统杀掉后靠
                //   workout 恢复录音时，`isRecording` 的 didSet 不会重放，不对的话
                //   这一整段录音的样本会被记成"待机"。
                .onAppear {
                    WatchBatteryMonitor.shared.isRecording = recorder.isRecording
                    WatchBatteryMonitor.shared.start()
                    // ★ 2026-11-06：App 一启动就给自己排下一次后台刷新——
                    // 之后由每次后台任务醒来续链（见 WatchBackgroundRefresher）。
                    WatchBackgroundRefresher.scheduleNext()
                }
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    recorder.consumePendingToggle()
                    link.retryUnconfirmedTimedCommand { recorder.remoteStartPending }
                    WatchBatteryMonitor.shared.refresh()
                }
        }
        // ★ 2026-11-06：系统按排程唤醒 App 时走这里。收件（applicationContext /
        // userInfo / 待传回执）由 App init 里的 `link.activate()` 幂等激活会话后
        // 经 WCSession 回调自动完成；这里只负责续排下一次。
        .backgroundTask(.appRefresh(WatchBackgroundRefresher.taskID)) {
            await WatchBackgroundRefresher.runOnce()
        }
    }
}
