import Foundation

/// 把一条录音的"成品三件套"打成 **一个 .zip**，交给系统分享面板。
///
/// ★ 2026-11-04（用户："把我当前总结、思维导图、待办都进行分享出去打包方式"）：
/// 之前只有单项分享——导图一张图、摘要一个 md、待办只能截屏。发给同事时得来回翻。
/// 这里按一条录音一个包做齐：
///
/// ```
/// 2026-11-04 周会讨论.zip
///   摘要.md        标题 / 日期 / 摘要 / 章节时间轴（与 Nextcloud 上的同源）
///   思维导图.png    和 App 里看到的那张图一致（同一套布局 + Core Graphics 渲染）
///   待办.md        复选框清单，已完成的打 [x]
///   转写.txt       完整转写（有才给）
///   录音.m4a       可选，默认不带（体积大，按需勾）
/// ```
///
/// 只读本地文件、只写 tmp，不改任何状态；包里没有的东西（比如没生成摘要）就跳过，
/// 不会留空文件占位。
enum ShareBundle {

    struct Options {
        /// 是否把音频一起打包。默认不带——一条一小时的录音能把包撑到几十 MB。
        var includeAudio = false
        /// 包内文件的时间戳。`nil` = 当前时间（分享场景）。
        ///
        /// ★ 2026-11-04（NC 上传复用本类）：上传侧靠 SHA256 判"内容变没变"，
        /// 而 ZIP 头里带 DOS 时间戳——每次现取 `Date()` 会让**字节每次都不同**，
        /// 判重永远失效、每轮都重传。上传时传录音日期，字节就稳定了。
        var modified: Date?
        /// 调用方**已经渲染好**的导图 PNG。上传路径上导图刚为 `思维导图.png`
        /// 渲染过一次，这里直接复用——否则整轮同步每条录音都要多渲染一遍
        /// （一次 Core Graphics 布局，几十到几百毫秒，录音多的账号叠起来很可观）。
        var mindMapPNG: Data?

        init(includeAudio: Bool = false, modified: Date? = nil, mindMapPNG: Data? = nil) {
            self.includeAudio = includeAudio
            self.modified = modified
            self.mindMapPNG = mindMapPNG
        }
    }

    /// 生成 zip 并返回文件 URL（在 tmp 里）。调用方直接丢给 `ShareSheet`。
    ///
    /// `async` 只为一件事：勾了「连录音一起」而 m4a 还没转好时，要现场跑一次
    /// `AVAssetExportSession`。其余路径都是同步文件读写，不会真的挂起。
    @MainActor
    static func makeZip(for clipName: String, options: Options = Options()) async throws -> URL {
        let fm = FileManager.default
        let dir = StorageLocations.decryptedDir
        let base = (clipName as NSString).deletingPathExtension
        let title = WebDAVSyncService.readableTitle(base: base, in: dir)
        let safeTitle = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "_")
        let stamp = options.modified ?? Date()

        var zip = ZipWriter()
        var added = 0

        // 1) 摘要.md —— 与上传到 Nextcloud 的那份同源
        if let note = WebDAVSyncService.noteMarkdown(base: base) {
            zip.add("摘要.md", text: note, modified: stamp)
            added += 1
        }

        // 2) 思维导图.png —— 和屏幕上同一套管线渲染
        let mindMap: Data? = options.mindMapPNG ?? {
            guard let summary = summaryText(base: base, in: dir) else { return nil }
            return MindMapSnapshot.pngData(markdown: summary, title: title)
        }()
        if let png = mindMap, !png.isEmpty {
            zip.add("思维导图.png", data: png, modified: stamp)
            added += 1
        }

        // 3) 待办.md —— 摘要里的行动项 + 用户手写的，已完成的按勾选状态标 [x]
        if let todos = todoMarkdown(base: base, title: title, in: dir) {
            zip.add("待办.md", text: todos, modified: stamp)
            added += 1
        }

        // 4) 转写.txt
        let transcript = StorageLocations.transcriptURLs(for: clipName).txt
        if let data = fm.contents(atPath: transcript.path), !data.isEmpty {
            zip.add("转写.txt", data: data, modified: stamp)
            added += 1
        }

        // 5) 录音（可选）：优先用已转好的 m4a，没有就现转一次
        if options.includeAudio {
            let source = dir.appendingPathComponent(clipName)
            let playable = dir.appendingPathComponent("\(base).m4a")
            if let data = fm.contents(atPath: playable.path) {
                zip.add("录音.m4a", data: data, modified: stamp)
                added += 1
            } else if let converted = try? await AudioExporter.exportAsM4A(source: source, suggestedName: base),
                      let data = fm.contents(atPath: converted.path) {
                zip.add("录音.m4a", data: data, modified: stamp)
                try? fm.removeItem(at: converted)
                added += 1
            } else if let data = fm.contents(atPath: source.path) {
                // ★ 兜底：iOS 16 没有 Ogg-Opus 解码器，转码这一步会失败。
                //   用户既然勾了「连录音一起」，就不能悄悄给一个没有录音的包——
                //   原样带走容器（微信/macOS/安卓都能放 Opus），只是 iPhone 上
                //   自带播放器打不开，比"东西不见了"好解释。
                zip.add("录音.\(source.pathExtension)", data: data, modified: stamp)
                added += 1
            }
        }

        guard added > 0 else { throw BundleError.empty }

        let out = fm.temporaryDirectory
            .appendingPathComponent("\(safeTitle.isEmpty ? base : safeTitle).zip")
        try? fm.removeItem(at: out)
        try zip.finish().write(to: out, options: .atomic)
        return out
    }

    enum BundleError: LocalizedError {
        case empty
        var errorDescription: String? {
            switch self {
            case .empty: return L10n.ClipDetail.bundleEmpty
            }
        }
    }

    // MARK: - Pieces

    private static func summaryText(base: String, in dir: URL) -> String? {
        let path = dir.appendingPathComponent("\(base).summary.md").path
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// 待办清单：摘要里识别出的行动项 + 手动添加项，按勾选状态输出 markdown 复选框。
    /// 已完成的排在后面——收件人先看还没做的。
    /// 待办清单 markdown（复选框、已完成的排后面）。
    /// ★ 2026-11-09：从 private 放开为 internal——WebDAVSyncService 的 待办.md
    /// 与 FolderExportService 的每录音文件夹布局都直接复用这一份，避免三处
    /// 输出悄悄分叉。
    static func todoMarkdown(base: String, title: String, in dir: URL) -> String? {
        guard let summary = summaryText(base: base, in: dir) else { return nil }
        let recording = base
        let manual = UserDefaults.standard.stringArray(forKey: "todo.manual.\(recording)") ?? []
        let checked = Set(UserDefaults.standard.stringArray(forKey: "todo.checked.\(recording)") ?? [])

        var seen = Set<String>()
        var items: [(text: String, done: Bool)] = []
        for block in TodoExtract.fromSummary(summary) {
            if case .heading = block.kind { continue }
            let text = TodoExtract.normalize(block.text)
            guard text.count >= 4, seen.insert(text).inserted else { continue }
            items.append((text, checked.contains(text)))
        }
        for text in manual {
            let normalized = TodoExtract.normalize(text)
            guard seen.insert(normalized).inserted else { continue }
            items.append((normalized, checked.contains(normalized)))
        }
        guard !items.isEmpty else { return nil }

        let open = items.filter { !$0.done }
        let done = items.filter { $0.done }
        var md = "# \(title) · \(L10n.ClipDetail.todosTitle)\n\n"
        for item in open { md += "- [ ] \(item.text)\n" }
        if !done.isEmpty {
            md += "\n## \(L10n.ClipDetail.todosCompleted(done.count))\n\n"
            for item in done { md += "- [x] \(item.text)\n" }
        }
        return md
    }
}
