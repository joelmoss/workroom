import AppKit

// The only place a unit test puts a window on screen (`make app-lint` refuses `orderFront`,
// `orderFrontRegardless` and `makeKeyAndOrderFront` anywhere else under WorkroomAppTests).
//
// A test window has to be on screen for most of what these suites check: SwiftUI lays out and
// draws only in a shown window, and a terminal surface renders only while its window reports
// itself visible (`occlusionState`). The run hides every window it shows from the developer
// (`TestWindowCloak`), and these say which way a test wants its own.

/// Shows `window` for a test, in front and out of the developer's way: `TestWindowCloak` makes it
/// transparent and click-through, and it still renders and reports itself visible. `makeKey` also
/// makes it its app's key window, as `makeKeyAndOrderFront` would.
@MainActor
func showTestWindow(_ window: NSWindow, makeKey: Bool = false) {
  window.orderFrontRegardless()
  if makeKey { window.makeKey() }
}

/// Shows `window` for a test as the user would see it: opaque, in front, taking clicks. Only for a
/// test that needs the window server to treat it as an ordinary window, which a cloaked one is
/// not: the occlusion it causes or suffers, say, since only opaque coverage occludes. `reason` says
/// which, at the call site.
@MainActor
func showTestWindowVisibly(_ window: NSWindow, because reason: String) {
  precondition(!reason.isEmpty, "say why this window must be seen")
  TestWindowCloak.exempt(window)
  window.orderFrontRegardless()
}
