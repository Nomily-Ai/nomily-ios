import SwiftUI
import UIKit

// MARK: - Summary poster (DingTalk-style "image-text" share)

/// Turns a Markdown summary into a shareable poster image.
///
/// ⛔ Drawn with **Core Graphics** (`UIGraphicsImageRenderer`), not
/// `ImageRenderer`: the SwiftUI offscreen renderer produced blank bitmaps for
/// this kind of canvas once (the mind-map export bug), so everything poster
/// related goes through the same CG path as `MindMapExporter`.
///
/// Share path is a plain `ShareSheet(items: [image])` — deliberately *not*
/// "save to Photos": saving needs `NSPhotoLibraryAddUsageDescription`, and
/// that key may only be set in `project.yml` (the Info.plist is generated).
struct SummaryPoster: Identifiable {
    let id: Int
    let template: PosterTemplate
    let image: UIImage
}

enum PosterTemplate: String, CaseIterable, Identifiable {
    case minimal
    case midnight
    case business

    var id: String { rawValue }

    var label: String {
        switch self {
        case .minimal: return NSLocalizedString("poster.template_minimal", value: "Minimal", comment: "Poster style: plain light card")
        case .midnight: return NSLocalizedString("poster.template_midnight", value: "Midnight", comment: "Poster style: dark card")
        case .business: return NSLocalizedString("poster.template_business", value: "Business", comment: "Poster style: header band + warm paper")
        }
    }

    var icon: String {
        switch self {
        case .minimal: return "rectangle"
        case .midnight: return "moon.fill"
        case .business: return "briefcase"
        }
    }

    struct Palette {
        let background: UIColor
        /// Header band colour (`business`); equals `background` elsewhere.
        let header: UIColor
        let headerInk: UIColor
        let ink: UIColor
        let secondary: UIColor
        let accent: UIColor
        let divider: UIColor
    }

    var palette: Palette {
        switch self {
        case .minimal:
            return Palette(
                background: UIColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
                header: UIColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
                headerInk: UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1),
                ink: UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1),
                secondary: UIColor(red: 0.45, green: 0.45, blue: 0.47, alpha: 1),
                accent: UIColor(red: 0.85, green: 0.26, blue: 0.18, alpha: 1),
                divider: UIColor(red: 0.88, green: 0.88, blue: 0.89, alpha: 1)
            )
        case .midnight:
            return Palette(
                background: UIColor(red: 0.055, green: 0.075, blue: 0.10, alpha: 1),
                header: UIColor(red: 0.055, green: 0.075, blue: 0.10, alpha: 1),
                headerInk: UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1),
                ink: UIColor(red: 0.92, green: 0.92, blue: 0.94, alpha: 1),
                secondary: UIColor(red: 0.60, green: 0.62, blue: 0.66, alpha: 1),
                accent: UIColor(red: 1.00, green: 0.45, blue: 0.34, alpha: 1),
                divider: UIColor(red: 0.22, green: 0.25, blue: 0.30, alpha: 1)
            )
        case .business:
            return Palette(
                background: UIColor(red: 0.965, green: 0.960, blue: 0.945, alpha: 1),
                header: UIColor(red: 0.12, green: 0.23, blue: 0.37, alpha: 1),
                headerInk: UIColor.white,
                ink: UIColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1),
                secondary: UIColor(red: 0.45, green: 0.46, blue: 0.48, alpha: 1),
                accent: UIColor(red: 0.12, green: 0.23, blue: 0.37, alpha: 1),
                divider: UIColor(red: 0.82, green: 0.82, blue: 0.80, alpha: 1)
            )
        }
    }
}

// MARK: - Content model

/// One drawable block of the poster body. Markdown structure is flattened:
/// headings keep their section role, list items become bullets, and a summary
/// without any structure falls back to plain paragraphs.
enum PosterBlock {
    case heading(String)
    case bullet(String)
    case paragraph(String)
}

enum SummaryPosterContent {

    /// Caps keep a sprawling 3-page summary from turning into a 12-screen
    /// poster — DingTalk's cards are teasers, not transcripts.
    static let maxSections = 9
    static let maxBulletsPerSection = 4
    static let maxBulletsTotal = 24
    static let maxParagraphs = 8
    static let maxParagraphCharacters = 1_400
    static let maxBulletCharacters = 140

    static func blocks(from markdown: String) -> [PosterBlock] {
        if let root = MarkdownOutline.parse(markdown) {
            let sections = Array(root.children.prefix(maxSections))
            var out: [PosterBlock] = []
            var bulletsTotal = 0
            for section in sections {
                if section.kind == .heading {
                    out.append(.heading(section.title))
                } else {
                    out.append(.paragraph(section.title))
                }
                var bulletsInSection = 0
                for child in section.children where bulletsTotal < maxBulletsTotal {
                    if child.kind == .heading { continue }
                    let text = truncate(child.title, to: maxBulletCharacters)
                    switch child.kind {
                    case .task: out.append(.bullet("☐ " + text))
                    default: out.append(.bullet(text))
                    }
                    bulletsTotal += 1
                    bulletsInSection += 1
                    if bulletsInSection >= maxBulletsPerSection { break }
                }
                if bulletsTotal >= maxBulletsTotal { break }
            }
            if !out.isEmpty { return out }
        }
        // Flat prose fallback.
        var paragraphs: [PosterBlock] = []
        var budget = maxParagraphCharacters
        for line in markdown.split(separator: "\n") {
            let text = MarkdownOutline.inline(String(line))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("#") else { continue }
            let piece = text.count > budget ? String(text.prefix(max(budget, 0))) : text
            guard !piece.isEmpty else { break }
            paragraphs.append(.paragraph(piece))
            budget -= piece.count
            if paragraphs.count >= maxParagraphs || budget <= 0 { break }
        }
        return paragraphs
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

// MARK: - CG exporter

@MainActor
enum SummaryPosterExporter {

    static let posterWidth: CGFloat = 1080
    private static let margin: CGFloat = 76
    private static let headerTitleFont = UIFont.systemFont(ofSize: 52, weight: .bold)
    private static let headerMetaFont = UIFont.systemFont(ofSize: 26, weight: .regular)
    private static let headingFont = UIFont.systemFont(ofSize: 34, weight: .semibold)
    private static let bodyFont = UIFont.systemFont(ofSize: 29, weight: .regular)
    private static let footerFont = UIFont.systemFont(ofSize: 23, weight: .medium)

    /// Renders the poster. Two passes: measure every block to learn the total
    /// height, then draw. `title`/`meta` may be empty — the layout collapses
    /// the missing rows instead of leaving gaps.
    static func render(
        template: PosterTemplate,
        title: String,
        meta: String,
        markdown: String
    ) -> UIImage? {
        let blocks = SummaryPosterContent.blocks(from: markdown)
        guard !blocks.isEmpty else { return nil }

        let p = template.palette
        let contentWidth = posterWidth - margin * 2
        let brand = NSLocalizedString("poster.brand", value: "Generated with Nomily AI", comment: "Poster footer watermark")

        // --- Pass 1: measure -------------------------------------------
        let titleLayout = TextRun(title, font: headerTitleFont, color: p.headerInk, maxWidth: contentWidth, maxLines: 2)
        var measured: [(PosterBlock, CGFloat)] = []
        var bodyHeight: CGFloat = 0
        var shown = 0
        for block in blocks {
            let h = measure(block, palette: p, width: contentWidth)
            bodyHeight += h
            measured.append((block, h))
            shown += 1
            // Hard pixel budget so the worst case still renders on device.
            if bodyHeight > 8200 { break }
        }

        // Divider block: 14pt above, the fill itself, 14pt below — this must
        // mirror the draw-time advance exactly, or the business header band
        // (sized from `headerHeight`) drifts into the first body line.
        let dividerFillHeight: CGFloat = template == .business ? 1.5 : 7
        let headerHeight: CGFloat = {
            var h: CGFloat = 0
            if titleLayout.height > 0 { h += titleLayout.height + 18 }
            if !meta.isEmpty { h += metaText(meta, palette: p).height + 10 }
            if h > 0 { h += 14 + dividerFillHeight + 14 }
            return h
        }()
        let footerHeight: CGFloat = 118
        let height = ceil(margin + headerHeight + bodyHeight + 44 + footerHeight)

        let size = CGSize(width: posterWidth, height: height)
        guard size.width.isFinite, size.height.isFinite, size.width * size.height < 60_000_000 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { context in
            let cg = context.cgContext
            p.background.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Business style: solid header band behind the title block.
            // Exactly `margin + headerHeight` tall — the body starts right there.
            if template == .business {
                let band = CGRect(x: 0, y: 0, width: posterWidth, height: margin + headerHeight)
                p.header.setFill()
                context.fill(band)
            }
            if template == .minimal {
                // A thin accent line on top gives the plain card an anchor.
                p.accent.setFill()
                context.fill(CGRect(x: 0, y: 0, width: posterWidth, height: 10))
            }

            var y: CGFloat = margin

            // --- Header ------------------------------------------------
            if titleLayout.height > 0 {
                titleLayout.draw(at: CGPoint(x: margin, y: y))
                y += titleLayout.height + 18
            }
            if !meta.isEmpty {
                let run = metaText(meta, palette: p)
                run.draw(at: CGPoint(x: margin, y: y))
                y += run.height + 10
            }
            if headerHeight > 0 {
                y += 14
                if template != .business {
                    p.accent.setFill()
                    // Accent underline: short, thick, left-aligned.
                    context.fill(CGRect(x: margin, y: y, width: 92, height: dividerFillHeight))
                } else {
                    p.headerInk.withAlphaComponent(0.25).setFill()
                    context.fill(CGRect(x: margin, y: y, width: posterWidth - margin * 2, height: dividerFillHeight))
                }
                y += dividerFillHeight + 14
            }

            // --- Body --------------------------------------------------
            for (block, h) in measured {
                draw(block, height: h, palette: p, width: contentWidth, cg: cg, at: &y)
            }

            // --- Footer ------------------------------------------------
            let footerY = size.height - footerHeight - 8
            p.divider.setFill()
            context.fill(CGRect(x: margin, y: footerY, width: posterWidth - margin * 2, height: 1.5))
            let footerRun = TextRun(brand, font: footerFont, color: p.secondary, maxWidth: contentWidth, maxLines: 1)
            footerRun.draw(at: CGPoint(x: margin, y: footerY + 30))
        }
    }

    // MARK: Text run helper

    /// An attributed one-paragraph run measured once and drawn many times.
    /// Wrapping is measured with `.usesLineFragmentOrigin`; when `maxLines`
    /// is set and the text exceeds it, the run re-styles with a truncating
    /// line-break mode and a fixed line height so measurement and drawing
    /// always agree.
    private final class TextRun {
        let attributed: NSAttributedString
        let height: CGFloat

        init(_ text: String, font: UIFont, color: UIColor, maxWidth: CGFloat, maxLines: Int? = nil) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.minimumLineHeight = font.lineHeight * 1.28
            paragraph.maximumLineHeight = font.lineHeight * 1.28
            let base = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ])
            let bounds = base.boundingRect(
                with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            let lineHeight = font.lineHeight * 1.28
            if let maxLines, bounds.height > lineHeight * CGFloat(maxLines) + 1 {
                paragraph.lineBreakMode = .byTruncatingTail
                let truncated = NSAttributedString(string: text, attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                ])
                attributed = truncated
                height = ceil(lineHeight * CGFloat(maxLines))
            } else {
                attributed = base
                height = ceil(bounds.height)
            }
        }

        func draw(at point: CGPoint) {
            attributed.draw(at: point)
        }
    }

    private static func metaText(_ meta: String, palette p: PosterTemplate.Palette) -> TextRun {
        TextRun(meta, font: headerMetaFont, color: p.secondary, maxWidth: posterWidth - margin * 2, maxLines: 1)
    }

    // MARK: Body blocks

    private static func measure(_ block: PosterBlock, palette p: PosterTemplate.Palette, width: CGFloat) -> CGFloat {
        switch block {
        case .heading(let text):
            let run = TextRun(text, font: headingFont, color: p.ink, maxWidth: width - 26, maxLines: 2)
            return run.height + 20
        case .bullet(let text):
            let run = TextRun(text, font: bodyFont, color: p.ink, maxWidth: width - 40, maxLines: 4)
            return run.height + 10
        case .paragraph(let text):
            let run = TextRun(text, font: bodyFont, color: p.ink, maxWidth: width, maxLines: 6)
            return run.height + 12
        }
    }

    private static func draw(
        _ block: PosterBlock,
        height h: CGFloat,
        palette p: PosterTemplate.Palette,
        width: CGFloat,
        cg: CGContext,
        at y: inout CGFloat
    ) {
        switch block {
        case .heading(let text):
            // Accent bar on the left, text beside it.
            let barHeight = min(34, max(20, h - 20))
            p.accent.setFill()
            cg.fill(CGRect(x: margin, y: y + 4, width: 7, height: barHeight))
            let run = TextRun(text, font: headingFont, color: p.ink, maxWidth: width - 26, maxLines: 2)
            run.draw(at: CGPoint(x: margin + 26, y: y))
            y += h
        case .bullet(let text):
            // Dot centred on the first text line.
            let dotY = y + bodyFont.lineHeight * 0.62
            p.accent.setFill()
            cg.fillEllipse(in: CGRect(x: margin + 2, y: dotY - 5.5, width: 11, height: 11))
            let run = TextRun(text, font: bodyFont, color: p.ink, maxWidth: width - 40, maxLines: 4)
            run.draw(at: CGPoint(x: margin + 34, y: y))
            y += h
        case .paragraph(let text):
            let run = TextRun(text, font: bodyFont, color: p.ink, maxWidth: width, maxLines: 6)
            run.draw(at: CGPoint(x: margin, y: y))
            y += h
        }
    }
}

// MARK: - Preview sheet

/// DingTalk-style poster sheet: a live preview that re-renders when the
/// template chip changes, plus share / copy actions.
struct SummaryPosterView: View {
    let markdown: String
    /// Clip display name (custom title if set, else file name).
    var title: String?
    /// Clip modified date — shown in the header meta line.
    var date: Date?
    /// Clip duration in seconds, if known.
    var duration: Double?

    @Environment(\.dismiss) private var dismiss
    @State private var template: PosterTemplate = .minimal
    @State private var poster: UIImage?
    @State private var showShareSheet = false
    @State private var copied = false

    private var displayTitle: String {
        let base = title?.trimmingCharacters(in: .whitespaces) ?? ""
        if !base.isEmpty { return base }
        return NSLocalizedString("clip_detail.summary", comment: "")
    }

    private var metaLine: String {
        var parts: [String] = []
        if let date {
            parts.append(AppLocale.string(from: date, dateStyle: .medium, timeStyle: .short))
        }
        if let duration, duration > 0 {
            let total = Int(duration)
            let h = total / 3600
            let m = (total % 3600) / 60
            let s = total % 60
            parts.append(h > 0
                ? String(format: "%d:%02d:%02d", h, m, s)
                : String(format: "%d:%02d", m, s))
        }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                templateChips
                if let poster {
                    ScrollView {
                        Image(uiImage: poster)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(14)
                            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(L10n.ClipDetail.posterEmpty)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                actionBar
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(L10n.ClipDetail.shareAsImage)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.done) { dismiss() }
                }
            }
            .onAppear(perform: rerender)
            .onChange(of: template) { _ in rerender() }
            .sheet(isPresented: $showShareSheet) {
                if let poster { ShareSheet(items: [poster]) }
            }
            .overlay {
                if copied {
                    VStack {
                        Spacer()
                        Text(L10n.ClipDetail.posterCopied)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.primary.opacity(0.85)))
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .padding(.bottom, 90)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    private var templateChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PosterTemplate.allCases) { candidate in
                    chip(candidate)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func chip(_ candidate: PosterTemplate) -> some View {
        let isOn = candidate == template
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { template = candidate }
        } label: {
            Label(candidate.label, systemImage: candidate.icon)
                .font(.subheadline.weight(isOn ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(isOn ? Color.appAccent : Color(uiColor: .secondarySystemBackground)))
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                if let poster {
                    Button {
                        UIPasteboard.general.image = poster
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            withAnimation { copied = false }
                        }
                    } label: {
                        Label(L10n.ClipDetail.posterCopy, systemImage: "doc.on.doc")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.appAccent.opacity(0.14)))
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showShareSheet = true
                    } label: {
                        Label(L10n.ClipDetail.share, systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(Color.appAccent))
                            .foregroundStyle(Color.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func rerender() {
        poster = SummaryPosterExporter.render(
            template: template,
            title: displayTitle,
            meta: metaLine,
            markdown: markdown
        )
    }
}
