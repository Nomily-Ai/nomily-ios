import SwiftUI
import WebKit

/// Renders Markdown (summaries, translated summaries) with the app's own
/// stylesheet and post-processing pass.
///
/// `marked`, the stylesheet and the enhancement script are all vendored into
/// the bundle and inlined into the HTML — the renderer makes no network
/// request. Loading any of them from a CDN would send a request off-device
/// for a purely local feature (and break offline), which conflicts with the
/// "data never leaves the device" principle.
struct MarkdownView: UIViewRepresentable {
    let markdown: String

    private static let markedJS = bundledText("marked.min", "js")
    private static let summaryJS = bundledText("summary", "js")
    private static let summaryCSS = bundledText("summary", "css")

    private static func bundledText(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Re-loading identical HTML throws away the reader's scroll
        // position, and SwiftUI re-runs `updateUIView` for every unrelated
        // state change in the parent. Only reload when the text differs.
        guard context.coordinator.loadedMarkdown != markdown else { return }
        context.coordinator.loadedMarkdown = markdown
        webView.loadHTMLString(wrapHTML(markdown), baseURL: nil)
    }

    final class Coordinator {
        var loadedMarkdown: String?
    }

    /// Insert the space CommonMark requires after a leading `#` run. LLMs
    /// (especially for CJK output) frequently emit `#Heading` with no space,
    /// which marked treats as plain text, so the summary's level-1 heading is
    /// not rendered as a heading. `# Heading` parses correctly.
    private func normalizeHeadings(_ md: String) -> String {
        md.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let m = line.range(of: #"^\s{0,3}#{1,6}"#, options: .regularExpression) else {
                return String(line)
            }
            let after = line[m.upperBound...]
            // Already spaced, or a bare "###" with nothing after — leave it.
            guard let first = after.first, first != " " else { return String(line) }
            return line[..<m.upperBound] + " " + after
        }.joined(separator: "\n")
    }

    /// Escapes the source so it can sit inside a JavaScript template literal
    /// in the generated page. `\`, backtick and `$` would otherwise end the
    /// literal; `</` is escaped because the HTML tokenizer ends a `<script>`
    /// element on the literal text `</script` regardless of JS context.
    private func escapeForScript(_ md: String) -> String {
        md.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }

    private func wrapHTML(_ md: String) -> String {
        let escaped = escapeForScript(normalizeHeadings(md))

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>\(Self.summaryCSS)</style>
        <script>\(Self.markedJS)</script>
        <script>\(Self.summaryJS)</script>
        </head>
        <body>
        <div id="content"></div>
        <script>
          (function () {
            var source = `\(escaped)`;
            var html;
            try {
              html = (window.marked && marked.parse) ? marked.parse(source) : null;
            } catch (e) {
              html = null;
            }
            if (html === null || html === undefined) {
              var pre = document.createElement('pre');
              pre.textContent = source;
              html = pre.outerHTML;
            }
            document.getElementById('content').innerHTML = html;
            if (window.__nomilyEnhanceSummary) { window.__nomilyEnhanceSummary(); }
          })();
        </script>
        </body>
        </html>
        """
    }
}
