import AppKit
import DesignSystem
import SwiftUI
import WebKit
import XCTest

@testable import Workroom

/// Under Glass (#729) the AppKit text views frost like the rest of the main window: they draw no
/// fill, so the window base (the theme background at the Glass opacity, #725) is the one tint under the
/// text. Opaque, they draw the theme background exactly as before.
@MainActor final class GlassTextViewTests: XCTestCase {
  /// The code view in a window of `glass`, read from the environment as the main window sets it.
  private func codeView(glass: GlassAppearance) -> some View {
    let tokens = ThemeService.shared.tokens
    let attributed = FileHighlightMapper.nsAttributedString(
      content: "let a = 1\nlet b = 2", spans: [], tokens: tokens, font: PlainFileViewer.font)
    return CodeTextView(
      attributed: attributed, version: 1, tokens: tokens, find: FileFindModel(), isFocused: false
    )
    .environment(\.glassAppearance, glass)
  }

  /// Hosts `view` in a window and lays it out now.
  private func mounted<V: View>(
    _ view: V, size: NSSize = NSSize(width: 300, height: 120)
  ) -> (window: NSWindow, view: NSHostingView<V>) {
    let hosted = hostInWindow(view, size: size)
    hosted.view.layoutSubtreeIfNeeded()
    return hosted
  }

  private struct Fills {
    let textView: NSTextView
    let scrolls: [NSScrollView]
  }

  private func fills(in host: NSView) throws -> Fills {
    Fills(
      textView: try XCTUnwrap(Self.all(NSTextView.self, in: host).first),
      scrolls: Self.all(NSScrollView.self, in: host))
  }

  private func assertGlass(
    _ fills: Fills, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertFalse(
      fills.textView.drawsBackground, "the text view stacks a second tint", file: file, line: line)
    XCTAssertFalse(fills.textView.isOpaque, file: file, line: line)
    XCTAssertEqual(
      fills.scrolls.count, 2, "the text's and the gutter's scroll views", file: file, line: line)
    for scroll in fills.scrolls {
      XCTAssertFalse(
        scroll.drawsBackground, "the window base is the tint", file: file, line: line)
      XCTAssertFalse(
        scroll.contentView.isOpaque, "a scroll view stayed opaque", file: file, line: line)
    }
  }

  private func assertOpaque(_ fills: Fills, file: StaticString = #filePath, line: UInt = #line) {
    let bg = NSColor(ThemeService.shared.tokens.bg)
    XCTAssertTrue(fills.textView.drawsBackground, file: file, line: line)
    XCTAssertEqual(fills.textView.backgroundColor, bg, file: file, line: line)
    for scroll in fills.scrolls {
      XCTAssertTrue(scroll.drawsBackground, file: file, line: line)
      XCTAssertEqual(scroll.backgroundColor, bg, file: file, line: line)
    }
  }

  /// Value: protects=the code view draws no fill under glass, over the window base, and is exactly
  /// its old opaque self otherwise, live across a switch; fails_when=a text or scroll view keeps an
  /// opaque fill under glass, the text view stacks its own tint, or switching back leaves it
  /// translucent; why_new=nothing tested the text views' fills; seam=CodeTextView;
  /// no_claim=what the window's blur shows through (#728)
  func testTheCodeViewDrawsNoFillUnderGlassAndIsOpaqueOtherwise() throws {
    let (window, host) = mounted(codeView(glass: .glass(opacity: 0.9)))
    defer { window.close() }
    assertGlass(try fills(in: host))

    host.rootView = codeView(glass: .opaque)
    host.layoutSubtreeIfNeeded()
    assertOpaque(try fills(in: host))

    host.rootView = codeView(glass: .glass(opacity: 0.9))
    host.layoutSubtreeIfNeeded()
    assertGlass(try fills(in: host))
  }

  func testTheCodeViewIsOpaqueByDefault() throws {
    let tokens = ThemeService.shared.tokens
    let (window, host) = mounted(
      CodeTextView(
        attributed: NSAttributedString(string: "a"), version: 1, tokens: tokens,
        find: FileFindModel(), isFocused: false))
    defer { window.close() }
    assertOpaque(try fills(in: host))
  }

  /// Value: protects=the script approval sheet's code stays opaque in a glass window, as the sheet
  /// does; fails_when=`ScriptCodeView` stops pinning `\.glassAppearance` to opaque, so the script
  /// frosts; why_new=the code view now reads the appearance from the environment, not a parameter;
  /// seam=ScriptCodeView; no_claim=the sheet's own background
  func testTheScriptApprovalCodeStaysOpaqueUnderGlass() throws {
    let (window, host) = mounted(
      ScriptCodeView(text: "echo hi\n", name: "setup.sh")
        .environment(\.glassAppearance, .glass(opacity: 0.9))
        .themeTokensRoot())
    defer { window.close() }
    assertOpaque(try fills(in: host))
  }

  // MARK: Inspector

  private struct GlassProbe: View {
    static var seen: GlassAppearance?
    @Environment(\.glassAppearance) private var glass

    var body: some View {
      Self.seen = glass
      return Color.clear.frame(width: 10, height: 10)
    }
  }

  private func inspector(glass: GlassAppearance) -> some View {
    InspectorSplitView(
      headers: [AnyView(Text("H"))], bodies: [AnyView(GlassProbe())], collapsed: [false],
      fills: [true], sectionKey: "s", workroomKey: "w", weights: [1], onWeightsChanged: { _ in }
    )
    .environment(\.glassAppearance, glass)
  }

  /// Value: protects=the inspector's hosted sections see the window's Glass appearance, and a change
  /// reaches them; fails_when=the hosting views drop `\.glassAppearance` (it does not cross an
  /// NSHostingController), so inspector content draws opaque under glass; why_new=the hand-off's
  /// known gap; seam=InspectorSplitView; no_claim=how the inspector's own chrome draws (#730)
  func testTheInspectorForwardsTheGlassAppearanceToItsSections() {
    GlassProbe.seen = nil
    let (window, host) = mounted(AnyView(inspector(glass: .glass(opacity: 0.9))))
    defer { window.close() }
    settle(host, seconds: 3, until: { GlassProbe.seen == .glass(opacity: 0.9) })
    XCTAssertEqual(
      GlassProbe.seen, .glass(opacity: 0.9), "a section saw glass within 3 s of mounting")

    host.rootView = AnyView(inspector(glass: .opaque))
    settle(host, seconds: 3, until: { GlassProbe.seen == .opaque })
    XCTAssertEqual(GlassProbe.seen, .opaque, "a section saw opaque within 3 s of the change")
  }

  // MARK: Creation log

  private func logView(_ controller: LogTextController, glass: GlassAppearance) -> some View {
    LogTextView(controller: controller, tokens: ThemeService.shared.tokens)
      .environment(\.glassAppearance, glass)
  }

  /// Value: protects=the creation pane's log lays one wash over the frosted pane under glass, and is
  /// its old self (the `surface` wash on both AppKit views) opaque, live across a switch;
  /// fails_when=the text or scroll view still draws under glass, stacking washes, or switching back
  /// leaves them undrawn; why_new=the log was not wired to Glass (review S3); seam=LogTextView;
  /// no_claim=the SwiftUI wash around it
  func testTheCreationLogDrawsNoFillOfItsOwnUnderGlassAndItsOldOneOtherwise() {
    let log = LogTextController(padding: 10)
    let (window, host) = mounted(logView(log, glass: .glass(opacity: 0.9)))
    defer { window.close() }
    assertLogDrawsNothing(log)

    host.rootView = logView(log, glass: .opaque)
    host.layoutSubtreeIfNeeded()
    let surface = NSColor(ThemeService.shared.tokens.surface)
    XCTAssertTrue(log.textView.drawsBackground)
    XCTAssertTrue(log.scrollView.drawsBackground)
    XCTAssertEqual(log.textView.backgroundColor, surface)
    XCTAssertEqual(log.scrollView.backgroundColor, surface)

    host.rootView = logView(log, glass: .glass(opacity: 0.9))
    host.layoutSubtreeIfNeeded()
    assertLogDrawsNothing(log)
  }

  private func assertLogDrawsNothing(
    _ log: LogTextController, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertFalse(
      log.textView.drawsBackground, "the text view stacks a wash", file: file, line: line)
    XCTAssertFalse(log.textView.isOpaque, file: file, line: line)
    XCTAssertFalse(
      log.scrollView.drawsBackground, "the scroll view stacks a wash", file: file, line: line)
    XCTAssertFalse(log.scrollView.contentView.isOpaque, file: file, line: line)
  }

  // MARK: Markdown preview

  private func preview(
    glass: GlassAppearance, onFirstRender: @escaping () -> Void = {}
  ) -> some View {
    MarkdownWebView(
      markdown: "# Glass\n\nBODY\n", tokens: ThemeService.shared.tokens, generation: 0,
      onFirstRender: onFirstRender
    )
    .environment(\.glassAppearance, glass)
  }

  /// Value: protects=the Markdown preview's page paints no background of its own, so the viewer's
  /// one fill shows through (frosted under glass), and WebKit's under-page colour is clear under
  /// glass and the theme background opaque, live across a switch; fails_when=the stylesheet paints
  /// `html`/`body`, or the under-page colour stays opaque under glass; why_new=the preview was opaque
  /// under glass (review S4); seam=MarkdownWebView; no_claim=the viewer's own fill
  func testTheMarkdownPreviewPaintsNoPageBackgroundAndClearsUnderPageUnderGlass() async throws {
    let painted = expectation(description: "first render painted")
    let (window, host) = mounted(
      preview(glass: .glass(opacity: 0.9)) { painted.fulfill() },
      size: NSSize(width: 500, height: 300))
    defer { window.close() }
    await fulfillment(of: [painted], timeout: 30)
    let web = try XCTUnwrap(Self.all(WKWebView.self, in: host).first)

    XCTAssertEqual(web.underPageBackgroundColor.alphaComponent, 0, "under-page stays opaque")
    for element in ["document.documentElement", "document.body"] {
      let color = try await web.evaluateJavaScript("getComputedStyle(\(element)).backgroundColor")
      XCTAssertEqual(color as? String, "rgba(0, 0, 0, 0)", "\(element) paints a background")
    }

    host.rootView = preview(glass: .opaque)
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(web.underPageBackgroundColor, ThemeService.shared.tokens.nsBg)
  }

  private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
  }
}
