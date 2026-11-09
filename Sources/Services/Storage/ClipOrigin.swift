import Foundation

// MARK: - 录音来源
//
// ★ 2026-11-04（用户："那个 Angel 只限于手表的转录称呼，其他的都不是"）：
//
// 之前摘要提示词无条件告诉模型"录音的主人是 Angel"，于是任何一条录音——
// 同事递过来的、会议室里录的、导入的音频——模型都会把某个说话人当成"我"，
// 甚至把别人的观点写成"用户本人认为"。名字是**事实**，不能靠猜。
//
// 现在只有**确实来自手表**的录音才带这一句（手表是贴身设备，录音的人就是戴表的人），
// 其余录音一律不提名字；如果声纹认出了本人，说话人标签里会写名字，模型自然看得到。
//
// 为什么要单独一个旁挂文件而不是写进 `.asr.json`：转写会重跑并覆盖 `.asr.json`，
// 而"这段音频是从哪来的"是音频的属性，不该跟着转写一起被洗掉。
enum ClipOrigin {

    static let watch = "watch"
    static let phone = "phone"

    private static func url(forClipName name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        return StorageLocations.decryptedDir.appendingPathComponent("\(base).origin")
    }

    static func mark(_ origin: String, forClipName name: String) {
        let target = url(forClipName: name)
        try? FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data(origin.utf8).write(to: target, options: .atomic)
    }

    static func of(_ clipName: String) -> String? {
        guard let data = try? Data(contentsOf: url(forClipName: clipName)),
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// 只有**明确记录**为手表的录音才算。老录音没有这个旁挂文件 → 不算：
    /// 宁可少标一次称呼，也不能再把 "Angel" 贴到别人的会上。
    static func isWatch(_ clipName: String) -> Bool {
        of(clipName) == watch
    }

    static func remove(forClipName name: String) {
        try? FileManager.default.removeItem(at: url(forClipName: name))
    }
}
