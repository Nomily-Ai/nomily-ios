import Foundation
import UIKit

/// 把一条录音的摘要渲染成思维导图 PNG（给 WebDAV 备份用）。
///
/// ★ 2026-11-04（用户："思维导图直接就是生成的图"）：服务器上放一张图，比放一份
/// 大纲 JSON 有用得多——手机、网页、群晖的文件管理器都能直接看。
///
/// 这条管线必须和屏幕上看到的**完全一致**，否则备份出来的图和 App 里的不是同一张：
/// `MarkdownOutline.parse → MindMapTemplate.detect/apply → fold → MindMapLayout.build
/// → MindMapExporter.image`，一步不少。折叠层级取"能显示三层"，也就是用户第一次
/// 打开导图时看到的那个样子。
///
/// 渲染器是 Core Graphics 那套（`MindMapExporter`），不是 `ImageRenderer`——
/// 后者在这个画布上离屏渲染出过空白页。
enum MindMapSnapshot {

    @MainActor
    static func pngData(markdown: String, title: String, dark: Bool = false) -> Data? {
        guard let parsed = MarkdownOutline.parse(markdown) else { return nil }
        let template = MindMapTemplate.detect(parsed)
        let tree = template.apply(to: parsed)
        let level = min(3, max(1, tree.maxDepth))
        let folded = MindMapLayout.foldPoints(in: tree, showingLevels: level)

        // 和 `MindMapScreen.exportPNG` 同一套缩放规则：大图降 scale，免得
        // 一张 3x 的长图吃掉几十 MB 内存。
        let size = MindMapLayout.build(tree: tree, collapsed: folded, rootLabel: title).size
        let points = size.width * size.height
        let scale: CGFloat = points > 8_000_000 ? 1 : (points > 2_000_000 ? 2 : 3)

        let layout = MindMapLayout.build(tree: tree, collapsed: folded, rootLabel: title)
        guard let image = MindMapExporter.image(
            layout: layout, rootLabel: title, dark: dark, scale: scale
        ) else { return nil }
        return image.pngData()
    }
}
