import AppKit
import SwiftUI
import XCTest

/// Hosts `rootView` in a window of its own, on screen but not key, for the invalidation suites,
/// which count the views a change re-runs. The hosting view fills the window, at `origin`.
@MainActor
func hostInWindow<Content: View>(
  _ rootView: Content, size: NSSize, origin: NSPoint = .zero,
  styleMask: NSWindow.StyleMask = [.titled]
) -> (window: NSWindow, view: NSHostingView<Content>) {
  let hosting = NSHostingView(rootView: rootView)
  hosting.frame = NSRect(origin: origin, size: size)
  let window = NSWindow(
    contentRect: hosting.frame, styleMask: styleMask, backing: .buffered, defer: false)
  // A programmatic NSWindow defaults `isReleasedWhenClosed` to true, which would over-release on
  // top of ARC — same reasoning as `PaneRenderingTests.host`.
  window.isReleasedWhenClosed = false
  window.contentView = hosting
  window.orderFront(nil)
  return (window, hosting)
}

extension XCTestCase {
  /// Lets SwiftUI run any update a change scheduled in `view`'s window, and draw it.
  @MainActor
  func render(_ view: NSView) async throws {
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    view.layoutSubtreeIfNeeded()
    view.window?.displayIfNeeded()
    settle(view, seconds: 0.2)
  }
}
