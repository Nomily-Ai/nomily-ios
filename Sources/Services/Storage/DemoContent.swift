import Foundation
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "demo-content")

/// ★ 2026-10-30（用户："新人用户下载需要点击 app，需要一个介绍展示示例音频跟对应
/// 文档"）：首次启动往资料库里放三条示例——
///
/// 1. 「如何使用 Nomily AI」——使用指南（纯文档）
/// 2. 「欢迎来到 Nomily AI」——欢迎信（纯文档）
/// 3. 「产品周会（示例）」——**真音频** + 完整产物链：转写（带说话人/时间轴）、
///    会议总结、待办、思维导图（摘要标题结构）、来源（时间轴定位）、大纲（chapters）
///
/// 实现就是"把文件放进 `decryptedDir`"——资料库扫描器对示例内容和用户自己的
/// 录音一视同仁，不引入任何特殊分支。幂等：文件已存在就跳过；用户的删除
/// （进回收站/彻底删除）之后**不会**复活（v1 标记只在全部缺件时重新播一遍）。
enum DemoContent {

    /// 版本号：以后改示例内容就 bump，缺件的老用户会拿到新版。
    private static let flagKey = "demo.seeded.v1"

    /// (bundle 资源名, 目标文件名)。资源与落盘同名——文件名就是资料库的 base。
    private static let files: [(resource: String, target: String)] = [
        ("sample-meeting.m4a", "sample-meeting.m4a"),
        ("sample-meeting.txt", "sample-meeting.txt"),
        ("sample-meeting.asr.json", "sample-meeting.asr.json"),
        ("sample-meeting.summary.md", "sample-meeting.summary.md"),
        ("sample-meeting.chapters.json", "sample-meeting.chapters.json"),
        ("sample-meeting.title", "sample-meeting.title"),
        ("demo-guide.summary.md", "demo-guide.summary.md"),
        ("demo-guide.title", "demo-guide.title"),
        ("demo-welcome.summary.md", "demo-welcome.summary.md"),
        ("demo-welcome.title", "demo-welcome.title"),
    ]

    /// 启动时调用（`NomilyApp.init` 里丢进后台任务）。只跑一次；以后每次启动
    /// 只查 UserDefaults 标记，成本为零。
    static func seedIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return }
        defaults.set(true, forKey: flagKey)

        let dir = StorageLocations.decryptedDir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log.error("demo seed: cannot create dir \(error.localizedDescription, privacy: .public)")
            // 目录建不出来就撤标记，下次启动再试。
            defaults.set(false, forKey: flagKey)
            return
        }

        var seeded = 0
        for file in files {
            let dst = dir.appendingPathComponent(file.target)
            // 已存在（用户删过音频但留了文档 / 上一版装过）不覆盖——示例内容
            // 永远不打架用户数据。
            guard !FileManager.default.fileExists(atPath: dst.path),
                  let url = Bundle.main.url(forResource: file.resource, withExtension: nil) else { continue }
            do {
                try FileManager.default.copyItem(at: url, to: dst)
                seeded += 1
            } catch {
                log.notice("demo seed: skip \(file.target, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        log.info("demo seed: \(seeded) files")
    }
}
