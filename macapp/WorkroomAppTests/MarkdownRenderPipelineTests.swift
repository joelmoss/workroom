import Foundation
import WebKit
import XCTest

@testable import Workroom

/// End-to-end tests for the rendered-Markdown *content* pipeline — the real bundled
/// `template.html` + `marked` + `DOMPurify` + `render.js`, driven exactly as `MarkdownWebView` drives
/// it (`window.__render(source)`), then read back out of the live DOM.
///
/// These exist because the pipeline can lose content **silently**: raw HTML in a Markdown file is
/// passed through to the parser, and a handful of tags (`<title>`, `<textarea>`, `<script>`,
/// `<style>`, `<xmp>`, `<plaintext>`…) hold raw/escapable-raw text, so an unclosed one swallows the
/// entire rest of the document as its own content — which DOMPurify then deletes outright, since all
/// of them are in its `FORBID_CONTENTS` set. A prose mention of `<title>` in a design note made
/// everything after that line disappear from the preview while the source view showed the whole file.
/// Nothing in the Swift layer can catch that, hence a real WebKit test over the vendored assets.
///
/// The `TAIL` marker in each fixture is the assertion that the document survived to its end.
@MainActor
final class MarkdownRenderPipelineTests: XCTestCase {

  private var webView: WKWebView!
  private var loader: TemplateLoader!

  override func setUp() async throws {
    try await super.setUp()
    let assetDirectory = try XCTUnwrap(
      Bundle.main.url(forResource: "markdown", withExtension: nil),
      "bundled markdown assets missing from the app bundle")
    let template = assetDirectory.appendingPathComponent("template.html")

    loader = TemplateLoader()
    webView = WKWebView(frame: .zero)
    webView.navigationDelegate = loader
    webView.loadFileURL(template, allowingReadAccessTo: assetDirectory)
    try await loader.waitForLoad()
  }

  override func tearDown() async throws {
    webView?.navigationDelegate = nil
    webView = nil
    loader = nil
    try await super.tearDown()
  }

  // MARK: - Helpers

  /// Render `markdown` through the bundled pipeline and return the resulting rendered text.
  private func renderedText(_ markdown: String) async throws -> String {
    let json = try XCTUnwrap(String(data: try JSONEncoder().encode(markdown), encoding: .utf8))
    // Trailing expression on purpose: `__render` returns undefined, and the async
    // `evaluateJavaScript` throws `javaScriptResultTypeIsUnsupported` on an undefined result.
    _ = try await webView.evaluateJavaScript("window.__render(\(json)); 'ok'")
    let text = try await webView.evaluateJavaScript(
      "document.getElementById('content').textContent")
    return try XCTUnwrap(text as? String)
  }

  /// Whether the rendered DOM contains an element matching `selector` — proves a raw-HTML chunk was
  /// passed through as real markup rather than escaped to text.
  private func renderedHas(_ selector: String) async throws -> Bool {
    let result = try await webView.evaluateJavaScript(
      "!!document.getElementById('content').querySelector('\(selector)')")
    return (result as? NSNumber)?.boolValue ?? false
  }

  /// A document whose body sits *between* a raw-HTML mention and the `TAIL` marker, so anything that
  /// eats the remainder of the parse is caught by the marker assertion.
  private func document(mentioning raw: String) -> String {
    """
    # Heading

    A line that mentions \(raw) in prose.

    ## Later section

    Body text that must survive.

    TAIL
    """
  }

  // MARK: - Raw-text tags must not swallow the rest of the document

  func testTitleMentionDoesNotTruncateDocument() async throws {
    let text = try await renderedText(
      document(mentioning: "a label (\"Terminal <title>, pane N of M\")"))
    XCTAssertTrue(text.contains("TAIL"), "content after a <title> mention was dropped: \(text)")
    XCTAssertTrue(text.contains("Later section"))
    XCTAssertTrue(text.contains("<title>"), "the mention should render as visible text")
  }

  func testRawTextTagMentionsDoNotTruncateDocument() async throws {
    for tag in [
      "<script>", "<style>", "<textarea>", "<xmp>", "<plaintext>", "<noscript>", "<iframe>",
      "<template>", "<noembed>", "<noframes>",
    ] {
      let text = try await renderedText(document(mentioning: tag))
      XCTAssertTrue(text.contains("TAIL"), "\(tag) truncated the document")
      XCTAssertTrue(text.contains(tag), "\(tag) should render as visible text")
    }
  }

  func testUnbalancedCommentDoesNotTruncateDocument() async throws {
    let text = try await renderedText(
      """
      # Heading

      <!-- an opening comment that is never closed

      Body text that must survive.

      TAIL
      """)
    XCTAssertTrue(text.contains("TAIL"), "an unterminated HTML comment ate the document: \(text)")
  }

  func testScriptBlockIsInertAndDocumentSurvives() async throws {
    let text = try await renderedText(
      """
      # Heading

      <script>window.__pwned = 1;</script>

      TAIL
      """)
    XCTAssertTrue(text.contains("TAIL"))
    let executed = try await webView.evaluateJavaScript("typeof window.__pwned")
    XCTAssertEqual(executed as? String, "undefined", "embedded script must never run")
    let hasScript = try await renderedHas("script")
    XCTAssertFalse(hasScript, "no <script> element may reach the DOM")
  }

  // MARK: - Legitimate raw HTML still renders as markup

  func testBalancedCommentIsStrippedWithoutLoss() async throws {
    let text = try await renderedText(
      """
      # Heading

      <!-- a normal, closed comment -->

      TAIL
      """)
    XCTAssertTrue(text.contains("TAIL"))
    XCTAssertFalse(text.contains("a normal, closed comment"), "comments should not be shown")
  }

  func testDetailsBlockRendersAsMarkup() async throws {
    let text = try await renderedText(
      """
      <details>
      <summary>Show more</summary>

      Hidden body.

      </details>

      TAIL
      """)
    XCTAssertTrue(text.contains("TAIL"))
    XCTAssertTrue(text.contains("Show more"))
    let hasSummary = try await renderedHas("details > summary")
    XCTAssertTrue(hasSummary, "<details> must stay real markup")
  }

  func testInlineHTMLRendersAsMarkup() async throws {
    let text = try await renderedText("Press <kbd>⌘K</kbd> for H<sub>2</sub>O.\n\nTAIL")
    XCTAssertTrue(text.contains("TAIL"))
    let hasKbd = try await renderedHas("kbd")
    let hasSub = try await renderedHas("sub")
    XCTAssertTrue(hasKbd, "<kbd> must stay real markup")
    XCTAssertTrue(hasSub, "<sub> must stay real markup")
  }

  func testRawTableRendersAsMarkup() async throws {
    let text = try await renderedText(
      "<table><thead><tr><th>H</th></tr></thead><tbody><tr><td>C</td></tr></tbody></table>\n\nTAIL")
    XCTAssertTrue(text.contains("TAIL"))
    let hasCell = try await renderedHas("table tbody td")
    XCTAssertTrue(hasCell, "a raw <table> must stay real markup")
  }

  // MARK: - Whole-document sanity

  /// A long document with a mid-file `<title>` mention must render essentially all of its blocks —
  /// the shape of the original bug, where only the head of a long file made it through.
  func testLongDocumentWithMidFileRawTagRendersEveryHeading() async throws {
    var lines: [String] = []
    for index in 1...200 {
      lines.append("## Section \(index)")
      lines.append("")
      lines.append(
        index == 100
          ? "A pane label (\"Terminal <title>, pane N of M\") is mentioned here."
          : "Body for section \(index).")
      lines.append("")
    }
    lines.append("TAIL")
    let text = try await renderedText(lines.joined(separator: "\n"))
    XCTAssertTrue(text.contains("TAIL"))
    for index in [1, 99, 100, 101, 200] {
      XCTAssertTrue(text.contains("Section \(index)"), "section \(index) missing from the render")
    }
  }
}

/// Awaits the template's first `didFinish` — JS isn't callable before then (the same gate
/// `MarkdownWebView.Coordinator` uses in production).
private final class TemplateLoader: NSObject, WKNavigationDelegate {
  private var continuation: CheckedContinuation<Void, Error>?
  private var outcome: Result<Void, Error>?

  func waitForLoad() async throws {
    if let outcome { return try outcome.get() }
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
    }
  }

  private func finish(_ result: Result<Void, Error>) {
    outcome = result
    continuation?.resume(with: result)
    continuation = nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    finish(.success(()))
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    finish(.failure(error))
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    finish(.failure(error))
  }
}
