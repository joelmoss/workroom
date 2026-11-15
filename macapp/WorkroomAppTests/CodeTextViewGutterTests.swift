import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// The line-number gutter follows the text when a resize re-wraps it.
@MainActor final class CodeTextViewGutterTests: XCTestCase {
  func testGutterFollowsTextHeightWhenAResizeRewrapsIt() throws {
    let tokens = ThemeService.shared.tokens
    let longLine = String(repeating: "word ", count: 60)
    let content = (0..<6).map { "\($0) \(longLine)" }.joined(separator: "\n")
    let attributed = FileHighlightMapper.nsAttributedString(
      content: content, spans: [], tokens: tokens, font: PlainFileViewer.font)
    let host = NSHostingView(
      rootView: CodeTextView(
        attributed: attributed, version: 1, tokens: tokens, find: FileFindModel(),
        isFocused: false))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()

    let textView = try XCTUnwrap(Self.first(NSTextView.self, in: host))
    let gutter = try XCTUnwrap(Self.first(GutterView.self, in: host))
    let narrowHeight = textView.frame.height
    XCTAssertEqual(gutter.frame.height, narrowHeight, accuracy: 0.5)

    // Wider: the long lines wrap to fewer rows, so the text gets shorter, and the gutter with it.
    window.setContentSize(NSSize(width: 2400, height: 80))
    host.layoutSubtreeIfNeeded()
    // Drawing lays the text out again in the app, which is what resizes the text view.
    let container = try XCTUnwrap(textView.textContainer)
    textView.layoutManager?.ensureLayout(for: container)
    textView.sizeToFit()
    let wideHeight = textView.frame.height
    XCTAssertLessThan(wideHeight, narrowHeight - 20, "widening re-wrapped the text")
    XCTAssertEqual(gutter.frame.height, max(80, wideHeight), accuracy: 0.5)
    window.close()
  }

  private static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
    if let match = view as? T { return match }
    for subview in view.subviews {
      if let match = first(type, in: subview) { return match }
    }
    return nil
  }
}

/// The approval sheet's script box opens as tall as the script, wrapped lines included.
@MainActor final class ScriptCodeViewHeightTests: XCTestCase {
  /// Value: protects=a script of a few long lines is estimated by the rows it wraps to, not its
  /// line count, and a wider box never estimates taller; fails_when=the estimate reverts to one row
  /// per line (the sheet opens on a clipped script); why_new=nothing tests the estimate; seam=none;
  /// no_claim=pixel-exact height (an estimate; the box scrolls if short)
  func testTheHeightCountsWrappedRows() {
    let long = String(repeating: "echo word ", count: 30)
    let longScript = ["#!/bin/sh", long, long].joined(separator: "\n")
    let shortScript = ["#!/bin/sh", "echo a", "echo b"].joined(separator: "\n")

    let narrow = ScriptCodeView.contentHeight(of: longScript, width: 400)
    let wide = ScriptCodeView.contentHeight(of: longScript, width: 2400)
    let short = ScriptCodeView.contentHeight(of: shortScript, width: 400)

    XCTAssertGreaterThan(narrow, short * 2, "the long lines' wrapped rows weren't counted")
    XCTAssertEqual(wide, short, accuracy: 0.5, "unwrapped, three lines are three rows")
    XCTAssertLessThanOrEqual(ScriptCodeView.contentHeight(of: longScript, width: 800), narrow)
  }
}
