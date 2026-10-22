import Foundation
import UIKit
import os.log

private let log = Logger(subsystem: "com.nomily.app.ios", category: "doc-export")

/// Text / Markdown / PDF / mind-map-PNG generation for the export chain
/// (★ 2026-10-22, 任务二).
///
/// ## Scope (from the task book)
/// Plaud's evidence: `export_share_telemetry.dart` + the workflow action
/// `Workflow_send_email_attachments_{summary|transcription|mindmap}` — the
/// email-with-attachments trio is their proven high-frequency need. The
/// document formats here feed both the export queue (`JobRunners.export`)
/// and the mail composer's attachment picker.
///
/// ## File locations
/// The audio runner already stages exports inside `ExportCenter`'s staging
/// dir; this file only produces `Data`/files **on request** — staging and
/// the "ready to share" ledger stay in `ExportCenter`.
@MainActor
enum DocumentExporter {

    enum ExportError: LocalizedError {
        case missing(String)
        case renderFailed(String)
        var errorDescription: String? {
            switch self {
            case .missing(let what): return L10n.Jobs.sourceMissing(what)
            case .renderFailed(let why): return why
            }
        }
    }

    // MARK: - Source readers (same rules as JobRunners — see its comment)

    static func transcriptText(for clipName: String) throws -> String {
        let urls = StorageLocations.transcriptURLs(for: clipName)
        if let data = try? Data(contentsOf: urls.json),
           let result = try? JSONDecoder().decode(AsrResult.self, from: data) {
            return JobRunners.summarizableText(text: result.text, segments: result.segments)
        }
        guard let text = try? String(contentsOf: urls.txt, encoding: .utf8) else {
            throw ExportError.missing(L10n.Jobs.sourceTranscript)
        }
        return text
    }

    static func summaryText(for clipName: String) throws -> String {
        let url = StorageLocations.summaryURL(for: clipName)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            throw ExportError.missing(L10n.Jobs.sourceSummary)
        }
        return text
    }

    static func hasSummary(_ clipName: String) -> Bool {
        (try? summaryText(for: clipName)) != nil
    }

    // MARK: - Format entry

    /// Generate one export artefact into `directory`. `format` mirrors the
    /// job's `exportFormat` string: `txt` / `md` / `pdf` / `png` (mind map).
    @discardableResult
    static func export(_ format: String, clipName: String, into directory: URL) throws -> URL {
        let stem = (clipName as NSString).deletingPathExtension
        switch format {
        case "txt":
            let url = directory.appendingPathComponent("\(stem).txt")
            try transcriptText(for: clipName).data(using: .utf8)?
                .write(to: url, options: .atomic)
            return url

        case "md":
            let url = directory.appendingPathComponent("\(stem).md")
            try markdown(for: clipName, stem: stem).data(using: .utf8)?
                .write(to: url, options: .atomic)
            return url

        case "pdf":
            let url = directory.appendingPathComponent("\(stem).pdf")
            let html = htmlDocument(for: clipName, stem: stem)
            guard let data = Self.renderPDF(html: html) else {
                throw ExportError.renderFailed(L10n.ClipDetail.exportPDFRenderFailed)
            }
            try data.write(to: url, options: .atomic)
            return url

        case "png":
            let summary = try summaryText(for: clipName)
            guard let tree = MarkdownOutline.parse(summary) else {
                throw ExportError.missing(L10n.Jobs.sourceSummary)
            }
            let layout = MindMapLayout.build(tree: tree)
            guard let image = MindMapExporter.image(
                layout: layout, rootLabel: stem, dark: false, scale: 2
            ), let data = image.pngData() else {
                throw ExportError.renderFailed(L10n.ClipDetail.mindMapExportFailed)
            }
            let url = directory.appendingPathComponent("\(stem)-mindmap.png")
            try data.write(to: url, options: .atomic)
            return url

        default:
            throw ExportError.missing(L10n.Jobs.sourceFormat)
        }
    }

    // MARK: - Markdown

    private static func markdown(for clipName: String, stem: String) throws -> String {
        var out = "# \(stem)\n\n"
        if let summary = try? summaryText(for: clipName) {
            out += "## \(L10n.ClipDetail.tabSummary)\n\n\(summary)\n\n"
        }
        out += "## \(L10n.ClipDetail.tabTranscript)\n\n\(try transcriptText(for: clipName))\n"
        return out
    }

    // MARK: - PDF (HTML → UIMarkupTextPrintFormatter → UIGraphicsPDFRenderer)

    private static func htmlDocument(for clipName: String, stem: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var body = "<h1>\(esc(stem))</h1>"
        if let summary = try? summaryText(for: clipName) {
            body += "<h2>\(esc(L10n.ClipDetail.tabSummary))</h2>"
            // Summaries are Markdown; a line-break-only rendering stays readable.
            body += "<pre style=\"font-family:-apple-system;font-size:11pt;white-space:pre-wrap\">\(esc(summary))</pre>"
        }
        if let transcript = try? transcriptText(for: clipName) {
            body += "<h2>\(esc(L10n.ClipDetail.tabTranscript))</h2>"
            body += "<pre style=\"font-family:-apple-system;font-size:10.5pt;white-space:pre-wrap\">\(esc(transcript))</pre>"
        }
        return """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system; margin: 0; }
        h1 { font-size: 17pt; } h2 { font-size: 13pt; margin-top: 14pt; }
        pre { margin: 0; }
        </style></head><body>\(body)</body></html>
        """
    }

    /// A4 pages via the system print pipeline — pagination for free.
    static func renderPDF(html: String) -> Data? {
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842) // A4 @72dpi
        let printable = pageRect.insetBy(dx: 36, dy: 40)
        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        formatter.perPageContentInsets = .zero
        let pageRenderer = UIPrintPageRenderer()
        pageRenderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        pageRenderer.setValue(NSValue(cgRect: pageRect), forKey: "paperRect")
        pageRenderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return try? renderer.pdfData { ctx in
            for page in 0..<pageRenderer.numberOfPages {
                ctx.beginPage()
                pageRenderer.drawPage(at: page, in: ctx.pdfContextBounds)
            }
        }
    }
}
