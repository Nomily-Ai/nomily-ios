import SwiftUI
import WebKit

struct MarkdownView: UIViewRepresentable {
    let markdown: String

    /// marked.js is vendored into the app bundle and inlined into the HTML —
    /// the renderer makes no network request. Loading it from a CDN would send
    /// a request off-device for a purely local feature (and break offline),
    /// which conflicts with the "data never leaves the device" principle.
    private static let markedJS: String = {
        guard let url = Bundle.main.url(forResource: "marked.min", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return js
    }()

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = wrapHTML(markdown)
        webView.loadHTMLString(html, baseURL: nil)
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

    private func wrapHTML(_ md: String) -> String {
        let escaped = normalizeHeadings(md)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <script>\(Self.markedJS)</script>
        <style>
          :root { color-scheme: light dark; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            font-size: 16px;
            line-height: 1.5;
            padding: 0 16px;
            margin: 0;
            color: var(--text);
            background: transparent;
          }
          @media (prefers-color-scheme: dark) {
            :root { --text: #e5e5e7; --code-bg: #2c2c2e; --border: #3a3a3c; }
          }
          @media (prefers-color-scheme: light) {
            :root { --text: #1c1c1e; --code-bg: #f2f2f7; --border: #d1d1d6; }
          }
          h1 { font-size: 1.7em; font-weight: 700; margin: 0.6em 0 0.35em; }
          h2 { font-size: 1.35em; font-weight: 700; margin: 0.5em 0 0.3em; }
          h3 { font-size: 1.12em; font-weight: 600; margin: 0.4em 0 0.2em; }
          p { margin: 0.4em 0; }
          ul, ol { padding-left: 1.4em; margin: 0.3em 0; }
          li { margin: 0.15em 0; }
          code {
            font-family: Menlo, monospace;
            font-size: 0.88em;
            background: var(--code-bg);
            padding: 1px 4px;
            border-radius: 3px;
          }
          pre {
            background: var(--code-bg);
            padding: 8px 10px;
            border-radius: 6px;
            overflow-x: auto;
          }
          pre code { background: none; padding: 0; }
          table {
            border-collapse: collapse;
            width: 100%;
            margin: 0.5em 0;
            font-size: 0.92em;
          }
          th, td {
            border: 1px solid var(--border);
            padding: 4px 8px;
            text-align: left;
          }
          th { font-weight: 600; }
          blockquote {
            border-left: 3px solid var(--border);
            margin: 0.4em 0;
            padding: 0.2em 0.8em;
            color: #888;
          }
          hr { border: none; border-top: 1px solid var(--border); margin: 0.8em 0; }
          strong { font-weight: 600; }
        </style>
        </head>
        <body>
        <div id="content"></div>
        <script>
          document.getElementById('content').innerHTML = marked.parse(`\(escaped)`);
        </script>
        </body>
        </html>
        """
    }
}
