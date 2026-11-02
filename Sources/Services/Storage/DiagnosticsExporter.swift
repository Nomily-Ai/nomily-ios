import Foundation
import os.log
import UIKit

private let log = Logger(subsystem: "com.nomily.app.ios", category: "diagnostics")

/// ★ 2026-10-30（用户："诊断报告导出…用户方便导出日志反馈给我们"）
///
/// 一键把「诊断日志 + 设备/版本信息」打包成一个文本文件，走系统分享面板
/// 发给开发者（邮件 / AirDrop / 微信都行）。
///
/// 内容边界（写进文件头，用户看得见）：
///   · **包含**：`Documents/ticnote-ble.log`（+ 滚动出来的 `.1`）——蓝牙帧、
///     Wi‑Fi 传输、ASR/LLM 调用的错误流水；设备型号 / 系统版本 / App 版本。
///   · **不包含**：录音音频、转写正文、API 密钥、定位等隐私（日志只记控制
///     帧与错误行，语音帧在 `TicNoteDiagLog` 里本就只记首帧计数）。
enum DiagnosticsExporter {

    /// 生成报告文件（Documents 下，用户可在文件 App 里直接看到），返回 URL。
    ///
    /// ★ 2026-11-02（用户："设置页加一个日志反馈的入口，方便导出日志给我们分析，
    /// 以及配合对应截图"）：支持可选的**用户问题描述**（写进文件头）与
    /// `includeLogs` 开关；反馈页用 `Nomily-Feedback-…` 前缀，关于页的
    /// 诊断导出保持默认调用不变。
    static func export(description: String? = nil, includeLogs: Bool = true,
                       fileNamePrefix: String = "Nomily-Diagnostics") -> URL? {
        let fm = FileManager.default
        let stamp = Self.stampFormatter.string(from: Date())
        let out = StorageLocations.documentsDir
            .appendingPathComponent("\(fileNamePrefix)-\(stamp).txt")

        var text = header(description: description, includeLogs: includeLogs)
        if includeLogs {
            text += "\n===== 诊断日志（ticnote-ble.log）=====\n"
            text += readFile(StorageLocations.diagLogURL)
            let rolled = URL(fileURLWithPath: StorageLocations.diagLogURL.path + ".1")
            if fm.fileExists(atPath: rolled.path) {
                text += "\n===== 上一段日志（ticnote-ble.log.1）=====\n"
                text += readFile(rolled)
            }
        } else {
            text += "\n（本次未附运行日志）\n"
        }

        do {
            try text.data(using: .utf8)?.write(to: out)
            log.notice("diagnostics exported: \(out.lastPathComponent, privacy: .public) (\(text.count) chars)")
            return out
        } catch {
            log.error("diagnostics write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Pieces

    private static func header(description: String? = nil, includeLogs: Bool = true) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let device = UIDevice.current
        var text = """
        Nomily 诊断报告
        生成时间：\(Self.fullFormatter.string(from: Date()))
        ────────────────────────────────
        App 版本：\(version) (\(build))
        系统版本：iOS \(device.systemVersion)
        设备型号：\(device.model)（\(device.name)）
        诊断日志开关：\(TicNoteDiagLog.isEnabled ? "开" : "关（本次可能没有日志）")
        ────────────────────────────────
        说明：本报告只包含运行日志与设备信息，不包含录音、转写内容和任何密钥。
        可以直接通过邮件发给支持邮箱 nomily@geekis.com。

        """
        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n===== 用户描述的问题 =====\n\(description)\n"
        }
        return text
    }

    private static func readFile(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return "（空或不可读）\n" }
        return text
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()
}
