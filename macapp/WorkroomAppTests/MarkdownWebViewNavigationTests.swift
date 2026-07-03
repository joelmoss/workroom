import Foundation
import WebKit
import XCTest

@testable import Workroom

/// Pure-rule tests for `MarkdownWebView`'s navigation gate — the security boundary for links inside an
/// UNTRUSTED rendered Markdown file. The gate must keep the frame on our own bundled assets, open only
/// web/mail links externally, and drop everything else (`file:`, `javascript:`, custom schemes). The
/// decision is factored into a side-effect-free `navigationDecision`, so no live `WKWebView` is needed.
final class MarkdownWebViewNavigationTests: XCTestCase {

  typealias Coord = MarkdownWebView.Coordinator
  typealias Decision = Coord.NavigationDecision

  // Synthetic bundle paths (never touched on disk) — the space mirrors the real "Workroom Dev.app".
  private let assetDir = URL(
    fileURLWithPath: "/Applications/Workroom Dev.app/Contents/Resources/markdown", isDirectory: true
  )
  private var template: URL { assetDir.appendingPathComponent("template.html") }

  private func decide(_ url: URL?, link: Bool) -> Decision {
    Coord.navigationDecision(
      url: url, isLinkActivated: link, templateURL: template, assetDirectory: assetDir)
  }

  // MARK: - Template load / subresource (non-link) navigations

  func testTemplateLoadAllowed() {
    XCTAssertEqual(decide(template, link: false), .allow)
  }

  func testBundledSiblingAssetsAllowed() {
    XCTAssertEqual(decide(assetDir.appendingPathComponent("styles.css"), link: false), .allow)
    XCTAssertEqual(decide(assetDir.appendingPathComponent("mermaid.min.js"), link: false), .allow)
  }

  func testFileOutsideAssetDirBlocked() {
    XCTAssertEqual(decide(URL(fileURLWithPath: "/etc/passwd"), link: false), .cancel)
  }

  func testSiblingDirPrefixTrickBlocked() {
    // "/…/markdown-evil/x" shares the "/…/markdown" string prefix but is NOT inside the asset dir.
    let sneaky = URL(
      fileURLWithPath: "/Applications/Workroom Dev.app/Contents/Resources/markdown-evil/x.html")
    XCTAssertEqual(decide(sneaky, link: false), .cancel)
  }

  func testNonFileNonLinkNavigationBlocked() {
    XCTAssertEqual(decide(URL(string: "https://example.com")!, link: false), .cancel)
  }

  func testNilURLBlocked() {
    XCTAssertEqual(decide(nil, link: false), .cancel)
    XCTAssertEqual(decide(nil, link: true), .cancel)
  }

  func testNilAssetDirBlocksBundledCheck() {
    let decision = Coord.navigationDecision(
      url: template, isLinkActivated: false, templateURL: template, assetDirectory: nil)
    XCTAssertEqual(decision, .cancel)
  }

  // MARK: - Link activations

  func testInPageFragmentAllowed() {
    let anchor = URL(string: template.absoluteString + "#section")!
    XCTAssertEqual(decide(anchor, link: true), .allow)
  }

  func testHttpLinkOpensExternally() {
    let url = URL(string: "https://example.com/x")!
    XCTAssertEqual(decide(url, link: true), .openExternally(url))
  }

  func testHttpsAndMailtoOpenExternally() {
    let mail = URL(string: "mailto:a@b.com")!
    XCTAssertEqual(decide(mail, link: true), .openExternally(mail))
  }

  func testSchemeMatchIsCaseInsensitive() {
    let url = URL(string: "HTTP://example.com")!
    XCTAssertEqual(decide(url, link: true), .openExternally(url))
  }

  func testJavascriptLinkBlocked() {
    XCTAssertEqual(decide(URL(string: "javascript:alert(1)")!, link: true), .cancel)
  }

  func testFileLinkToOtherFileBlocked() {
    // A clicked file:// link that isn't the template (differing by more than a fragment) is dropped.
    XCTAssertEqual(decide(URL(fileURLWithPath: "/etc/passwd"), link: true), .cancel)
  }

  func testCustomSchemeLinkBlocked() {
    XCTAssertEqual(decide(URL(string: "workroom://open?x=1")!, link: true), .cancel)
  }

  // MARK: - Building blocks

  func testIsBundledAssetPrefixBoundary() {
    XCTAssertTrue(Coord.isBundledAsset(template, assetDirectory: assetDir))
    XCTAssertTrue(Coord.isBundledAsset(assetDir, assetDirectory: assetDir))
    XCTAssertFalse(
      Coord.isBundledAsset(URL(fileURLWithPath: "/somewhere/else"), assetDirectory: assetDir))
    XCTAssertFalse(Coord.isBundledAsset(template, assetDirectory: nil))
  }

  func testOpenableSchemesAreWebAndMailOnly() {
    XCTAssertEqual(Coord.openableSchemes, ["http", "https", "mailto"])
  }
}
