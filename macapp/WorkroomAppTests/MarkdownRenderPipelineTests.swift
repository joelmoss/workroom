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

  /// Render `markdown` through the bundled pipeline and return the resulting rendered text, once the
  /// whole document is in the page (a long one opened into an empty page goes in a slice at a time).
  private func renderedText(_ markdown: String) async throws -> String {
    let text = try await webView.callAsyncJavaScript(
      """
      window.__render(source);
      await window.__renderComplete;
      return document.getElementById('content').textContent;
      """, arguments: ["source": markdown], contentWorld: .page)
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

  // MARK: - Lazy diagram engine

  /// Pele, the diagram engine, is most of the bundled script, and is injected on demand, so a document
  /// with no diagram must never fetch it — that absence IS the performance fix, and nothing else in
  /// the app would notice if it regressed.
  func testMermaidIsNotLoadedForADocumentWithoutDiagrams() async throws {
    _ = try await renderedText(
      "# Heading\n\nJust prose, no diagrams.\n\n```swift\nlet x = 1\n```\n")
    let type = try await webView.evaluateJavaScript("typeof window.pele")
    XCTAssertEqual(
      type as? String, "undefined",
      "the diagram engine must not be loaded for a document with no ```mermaid fence")
  }

  /// The other half: a document that does contain a fence loads the engine and renders a real diagram.
  /// Asserted via an `<svg>` in the DOM — the fence's source text stays put when Pele never arrives,
  /// so only the SVG proves the on-demand load actually completed.
  func testMermaidLoadsOnDemandAndRendersDiagram() async throws {
    _ = try await renderedText(
      """
      # Diagram

      ```mermaid
      graph TD
        A[Start] --> B[End]
      ```
      """)

    // The load + render is asynchronous by design (it must not block the first paint), so poll.
    var renderedSVG = false
    for _ in 0..<100 {
      if try await renderedHas("svg") {
        renderedSVG = true
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(renderedSVG, "a ```mermaid fence should load Pele and render an <svg>")

    let type = try await webView.evaluateJavaScript("typeof window.pele")
    XCTAssertEqual(type as? String, "object", "Pele should be loaded once a diagram needs it")
  }

  // Value: protects=pie percentages stay black, readable on every slice colour in light and dark
  // themes; fails_when=the styles.css override goes and Pele inks them in the page background
  // (dark-on-colour in dark themes, 1.6:1 white on yellow in light); why_new=the override is new;
  // seam=none; no_claim=labels drawn beside small slices.
  func testPieSliceLabelsAreBlackWhateverTheTheme() async throws {
    _ = try await renderedText("```mermaid\npie\n  \"A\" : 60\n  \"B\" : 40\n```\n")
    _ = try await webView.evaluateJavaScript(
      "window.__applyTheme({ bg: 'rgba(30, 31, 36, 1)', fg: 'rgba(216, 218, 224, 1)' }); 'ok'")
    var fill: String?
    for _ in 0..<100 {
      fill =
        try await webView.evaluateJavaScript(
          """
          (() => {
            const label = document.querySelector('.pele-slice-labels[fill] text');
            return label ? getComputedStyle(label).fill : '';
          })()
          """) as? String
      if fill?.isEmpty == false { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(fill, "rgb(0, 0, 0)")
  }

  // MARK: - Progressive first render

  /// 400 sections of ~60 characters: well past the first slice.
  private static let longDocument =
    (1...400).map { "## Section \($0)\n\nBody text for section \($0), long enough to count.\n" }
    .joined(separator: "\n")

  // Value: protects=a long file opened into an empty page shows its head at once and still ends up
  // whole; fails_when=slicing stops (head waits for the whole) or a later slice is lost;
  // why_new=progressive rendering is new; seam=__renderComplete; no_claim=paint timing.
  func testALongDocumentOpenedIntoAnEmptyPageArrivesHeadFirstThenWhole() async throws {
    let counts = try await webView.callAsyncJavaScript(
      """
      window.__render(source);
      const first = document.querySelectorAll('#content h2').length;
      await window.__renderComplete;
      return [first, document.querySelectorAll('#content h2').length];
      """, arguments: ["source": Self.longDocument], contentWorld: .page)
    let headings = try XCTUnwrap(counts as? [Int])
    XCTAssertGreaterThan(headings[0], 0, "the head of the document was not put in straight away")
    XCTAssertLessThan(headings[0], 400, "the long document was not sliced")
    XCTAssertEqual(headings[1], 400, "a later slice never arrived")
  }

  // Value: protects=a re-render of an open file replaces it in one go, so the reader's scroll
  // position never meets a half-built page; fails_when=re-renders slice too; why_new=progressive
  // rendering is new; seam=none; no_claim=scroll restoration.
  func testAReRenderReplacesTheDocumentInOneGo() async throws {
    _ = try await renderedText("# Open file\n")
    let count = try await webView.callAsyncJavaScript(
      """
      window.__render(source);
      return document.querySelectorAll('#content h2').length;
      """, arguments: ["source": Self.longDocument], contentWorld: .page)
    XCTAssertEqual(count as? Int, 400)
  }

  // Value: protects=opening another version of the file while a long one is still going in leaves
  // only the newer one on screen; fails_when=the generation check goes and the older render's
  // remaining slices are appended under the newer document; why_new=slices and generations are new;
  // seam=__renderComplete; no_claim=paint timing.
  func testANewerRenderStopsTheOlderOnesRemainingSlices() async throws {
    let headings = try await webView.callAsyncJavaScript(
      """
      window.__render(source);
      const older = window.__renderComplete;
      window.__render(newer);
      await older;
      return document.querySelectorAll('#content h2').length;
      """, arguments: ["source": Self.longDocument, "newer": "# Newer file\n\nNEWER\n"],
      contentWorld: .page)
    XCTAssertEqual(headings as? Int, 0, "the older document's later slices were added to the newer")
  }

  // MARK: - Diagrams in the progressive and failing cases

  /// Waits for a diagram to be drawn in the page, which happens after the render returns.
  private func waitForDiagramCount(_ expected: Int) async throws -> Int {
    var count = 0
    for _ in 0..<100 {
      count =
        try await webView.evaluateJavaScript(
          "document.querySelectorAll('#content pre.mermaid svg').length") as? Int ?? 0
      if count >= expected { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    return count
  }

  // Value: protects=a diagram lower down a long file is drawn, not left as a code block;
  // fails_when=diagrams are only promoted in the first slice; why_new=slices are new, and a design
  // doc's diagram sits past the first screens; seam=none; no_claim=paint timing.
  func testADiagramPastTheFirstSliceIsDrawn() async throws {
    let filler = (1...300).map { "Filler paragraph number \($0), with a little text.\n" }
      .joined(separator: "\n")
    _ = try await renderedText("\(filler)\n```mermaid\ngraph TD\n  A[Start] --> B[End]\n```\n")
    let drawn = try await waitForDiagramCount(1)
    XCTAssertEqual(drawn, 1, "a diagram past the first slice was not drawn")
  }

  // Value: protects=one bad diagram leaves its source text and the rest of the document, diagrams
  // after it included, intact; fails_when=a diagram's failure escapes its own try/catch and stops
  // the ones after it; why_new=the render call and its error handling were rewritten (pele.render);
  // seam=none; no_claim=what the bad diagram looks like.
  func testABadDiagramLeavesItsSourceAndDoesNotStopTheNextOne() async throws {
    let text = try await renderedText(
      """
      ```mermaid
      this is not a diagram
      ```

      ```mermaid
      graph TD
        A[Start] --> B[End]
      ```

      TAIL
      """)
    XCTAssertTrue(text.contains("TAIL"))
    let drawn = try await waitForDiagramCount(1)
    XCTAssertEqual(drawn, 1, "the diagram after the bad one was not drawn")
    let source = try await webView.evaluateJavaScript(
      "document.querySelector('#content pre.mermaid').textContent")
    XCTAssertEqual(source as? String, "this is not a diagram\n", "the bad diagram lost its source")
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
