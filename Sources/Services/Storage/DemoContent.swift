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
/// （进回收站/彻底删除）之后**不会**复活（标记只在全部缺件时重新播一遍）。
///
/// ★ 2026-11-02（用户："会展示三条示例介绍需要跟随当前语言切换进行切换"）：
/// 三条示例的**标题 / 摘要 / 大纲**现在有中英两套资源，随界面语言落盘——
/// 中文界面用原资源，其它语言用 `.en` 变体（产品只备了中英两套示例文案，
/// 其余语言按 L10n 的 fallback 走英文）。切换语言时**重写**已存在的示例文本
/// （用户在资料库看到的三条介绍立刻变成新语言），而音频与逐句转写保持不动：
/// 转写必须和音频内容一致，翻译它就成了假数据。
enum DemoContent {

    /// 版本号：以后改示例内容就 bump，缺件的老用户会拿到新版。
    private static let seededKey = "demo.seeded.v1"

    /// 与语言无关的产物：示例音频本体 + 逐句转写（必须和音频一致，不翻译）。
    private static let fixedFiles: [(resource: String, target: String)] = [
        ("sample-meeting.m4a", "sample-meeting.m4a"),
        ("sample-meeting.txt", "sample-meeting.txt"),
        ("sample-meeting.asr.json", "sample-meeting.asr.json"),
    ]

    /// 随界面语言切换的文本产物。
    ///
    /// `zhHans` / `english` 是 **bundle 里的资源名**，`target` 是落盘文件名（资料库的 base）。
    /// 标题文件（`*.title`）没有扩展名，资源名到落盘名是一一对应的重命名。
    private struct LocalizedFile {
        let zhHans: String
        let english: String
        let target: String
    }

    private static let localizedFiles: [LocalizedFile] = [
        .init(zhHans: "demo-guide.title", english: "demo-guide.title.en",
              target: "demo-guide.title"),
        .init(zhHans: "demo-guide.summary.md", english: "demo-guide.summary.en.md",
              target: "demo-guide.summary.md"),
        .init(zhHans: "demo-welcome.title", english: "demo-welcome.title.en",
              target: "demo-welcome.title"),
        .init(zhHans: "demo-welcome.summary.md", english: "demo-welcome.summary.en.md",
              target: "demo-welcome.summary.md"),
        .init(zhHans: "sample-meeting.title", english: "sample-meeting.title.en",
              target: "sample-meeting.title"),
        .init(zhHans: "sample-meeting.summary.md", english: "sample-meeting.summary.en.md",
              target: "sample-meeting.summary.md"),
        .init(zhHans: "sample-meeting.chapters.json", english: "sample-meeting.chapters.en.json",
              target: "sample-meeting.chapters.json"),
    ]

    /// 界面语言是否用中文示例文案。只认 `zh*`；`nil`（未选语言、跟随系统但取不到）
    /// 按中文处理——与 `AppLanguage.resolve(nil)` 落到英文不同是有意的：首装当日
    /// 的中文用户占绝大多数，示例文案中文最不容易闹笑话。
    private static func prefersChinese(_ language: String?) -> Bool {
        guard let language, !language.isEmpty else { return true }
        return language.lowercased().hasPrefix("zh")
    }

    /// 启动 / 语言变化时调用。`NomilyApp` 首启播示例，`LocalizedRoot` 在语言
    /// 切换时再调一次做文本替换。整个函数幂等，重复调用只写有变化的文件。
    ///
    /// - Parameter language: 当前界面语言 tag（`LocalizationService.effective`）。
    static func apply(language: String?) {
        let defaults = UserDefaults.standard
        let firstRun = !defaults.bool(forKey: seededKey)

        let dir = StorageLocations.decryptedDir
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log.error("demo seed: cannot create dir \(error.localizedDescription, privacy: .public)")
            // 目录建不出来就撤标记，下次启动再试。
            defaults.set(false, forKey: seededKey)
            return
        }

        var written = 0
        written += copyFixedFiles(into: dir, seedMissing: firstRun)
        written += syncLocalizedFiles(into: dir, language: language, seedMissing: firstRun)

        if firstRun {
            defaults.set(true, forKey: seededKey)
            log.info("demo seed: first run, \(written) files written")
        } else if written > 0 {
            log.info("demo sync: \(written) file(s) rewritten for language \(language ?? "system", privacy: .public)")
        }
    }

    // MARK: - seams

    private static func copyFixedFiles(into dir: URL, seedMissing: Bool) -> Int {
        guard seedMissing else { return 0 }
        var written = 0
        for file in fixedFiles {
            let dst = dir.appendingPathComponent(file.target)
            // 已存在（用户删过音频但留了文档 / 上一版装过）不覆盖——示例内容
            // 永远不打架用户数据。
            guard !FileManager.default.fileExists(atPath: dst.path),
                  let url = Bundle.main.url(forResource: file.resource, withExtension: nil)
            else { continue }
            do {
                try FileManager.default.copyItem(at: url, to: dst)
                written += 1
            } catch {
                log.notice("demo seed: skip \(file.target, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return written
    }

    private static func syncLocalizedFiles(into dir: URL, language: String?, seedMissing: Bool) -> Int {
        let useChinese = prefersChinese(language)
        var written = 0
        for file in localizedFiles {
            let target = dir.appendingPathComponent(file.target)
            let exists = FileManager.default.fileExists(atPath: target.path)
            // 用户删掉的那条示例不复活：只有首播（缺件补齐）才允许"新建"。
            guard exists || seedMissing else { continue }

            let resource = useChinese ? file.zhHans : file.english
            guard let url = Bundle.main.url(forResource: resource, withExtension: nil),
                  let data = try? Data(contentsOf: url) else {
                log.notice("demo sync: missing bundle resource \(resource, privacy: .public)")
                continue
            }
            // 内容没变就不写——避免每次启动刷新 mtime，资料库白重排一次。
            if exists, let current = try? Data(contentsOf: target), current == data { continue }
            do {
                try data.write(to: target, options: .atomic)
                written += 1
            } catch {
                log.notice("demo sync: write \(file.target, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return written
    }
}
