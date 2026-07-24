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

  /// Whether the blocks that follow the raw-HTML mention are still **top-level** children of the
  /// content root.
  ///
  /// `textContent` alone is not enough, and that blind spot hid a second instance of this very bug:
  /// `<select>`/`<dialog>`/`<object>`/`<applet>` don't delete the remainder of the document, they
  /// *adopt* it as their own children. Every word stays in `textContent` while the page renders a
  /// bare dropdown (or nothing at all, for `display: none` `<dialog>` and unrendered `<object>`
  /// fallback content) — the same "file is cut off" symptom the user reported. Only a structural
  /// assertion catches it, so `document(mentioning:)` docs are checked with this, not just for text.
  private func topLevelStructureSurvives() async throws -> Bool {
    let result = try await webView.evaluateJavaScript(
      """
      (() => {
        const root = document.getElementById('content');
        const last = root.lastElementChild;
        return root.querySelectorAll(':scope > h2').length === 1
          && !!last && last.textContent.includes('TAIL');
      })()
      """)
    return (result as? NSNumber)?.boolValue ?? false
  }

  /// Assert a raw-HTML `mention` neither loses the document's text nor its structure, and that the
  /// mention itself ends up visible as literal text.
  private func assertMentionIsHarmless(
    _ mention: String, line: UInt = #line
  ) async throws {
    let text = try await renderedText(document(mentioning: mention))
    XCTAssertTrue(
      text.contains("TAIL"), "\(mention) truncated the document", line: line)
    XCTAssertTrue(
      text.contains("Later section"), "\(mention) dropped the following section", line: line)
    XCTAssertTrue(
      text.contains(mention), "\(mention) should render as visible text", line: line)
    let structural = try await topLevelStructureSurvives()
    XCTAssertTrue(
      structural,
      "\(mention) reparented the rest of the document into itself (text kept, not rendered)",
      line: line)
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
    let structural = try await topLevelStructureSurvives()
    XCTAssertTrue(structural, "the document structure after the <title> mention was destroyed")
  }

  /// Raw-text / RCDATA tags: the remainder became the element's text content and DOMPurify deleted it
  /// (all of these are in its `FORBID_CONTENTS` set).
  func testRawTextTagMentionsDoNotTruncateDocument() async throws {
    for tag in [
      "<script>", "<style>", "<textarea>", "<xmp>", "<plaintext>", "<noscript>", "<iframe>",
      "<template>", "<noembed>", "<noframes>",
    ] {
      try await assertMentionIsHarmless(tag)
    }
  }

  /// Non-rendering containers: these keep the remainder in the DOM but adopt it as their children,
  /// and none of them renders arbitrary children — a `<select>` shows a dropdown, a `<dialog>`
  /// without `open` is `display: none`, `<object>`/`<applet>` children are unrendered fallback. Text
  /// survives, the page still looks cut off, so they get escaped like the raw-text tags above.
  func testNonRenderingContainerMentionsDoNotBreakDocument() async throws {
    for tag in ["<select>", "<dialog>", "<object>", "<applet>"] {
      try await assertMentionIsHarmless(tag)
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
///
/// Bounded by an `XCTestExpectation` rather than a bare continuation: CI runs these on a hosted
/// runner (`make app-test` in `.github/workflows/ci.yml`), and if WebKit never starts or the
/// WebContent process dies, an unbounded continuation would stall the whole test target instead of
/// failing this one test.
private final class TemplateLoader: NSObject, WKNavigationDelegate {
  private let loaded = XCTestExpectation(description: "markdown template finished loading")
  private var outcome: Result<Void, Error>?

  func waitForLoad(timeout: TimeInterval = 30) async throws {
    await XCTWaiter().fulfillment(of: [loaded], timeout: timeout)
    guard let outcome else {
      throw NSError(
        domain: "MarkdownRenderPipelineTests", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "bundled markdown template did not finish loading within \(timeout)s"
        ])
    }
    try outcome.get()
  }

  private func finish(_ result: Result<Void, Error>) {
    guard outcome == nil else { return }  // first navigation wins; later loads are no-ops
    outcome = result
    loaded.fulfill()
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
