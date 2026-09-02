import AppKit

/// Whether a window becoming key should put keyboard focus back on the focused pane's terminal
/// surface.
///
/// The `createSurface` focus re-sync (`GhosttySurfaceView.adoptFocusIfFirstResponder`) covers the
/// case where a surface is CREATED while the view already holds first responder. It cannot cover the
/// other drift trigger: the surface already exists and first responder has moved off it while the
/// window was not key (⌘-Tab, Mission Control, a sheet that came and went, a pane removed from the
/// hierarchy). AppKit restores whatever first responder it had, which may be the window itself or a
/// view that is no longer mounted — and then keys go nowhere until the user clicks the terminal.
///
/// Deliberately conservative: "no sheet is open" is NOT a sufficient condition on its own, because a
/// live text field or the sidebar table is a perfectly legitimate first responder that the user
/// chose. Only three states count as drift — nobody, the window, or a detached view. Anything still
/// mounted in this window keeps the keyboard.
enum TerminalFocusReconciliation {

  /// The decision, taken against a real `NSWindow` so it is unit-testable without a live libghostty
  /// surface (the same approach `GhosttySurfaceView.holdsFirstResponder`/`canSpawnSurface` use).
  static func shouldRestoreFirstResponder(in window: NSWindow, to surface: NSView) -> Bool {
    // A sheet or an app-modal panel owns the keyboard for as long as it is up.
    guard window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
    // A surface that has been unmounted (or moved to another window) is not a focus target.
    guard surface.window === window else { return false }
    // No first responder at all — the clearest drift there is.
    guard let responder = window.firstResponder else { return true }
    // AppKit's "nobody" fallback: the window itself takes the role when a responder resigns.
    if responder === window { return true }
    // A non-view responder (the window's own delegate chain, a controller) is left alone.
    guard let view = responder as? NSView else { return false }
    if view === surface { return false }  // already focused — nothing to restore
    // A view still mounted in this window (a text field, its field editor, the sidebar table,
    // another split pane) is the user's own choice. Only a DETACHED view counts as drift.
    return view.window !== window
  }
}
