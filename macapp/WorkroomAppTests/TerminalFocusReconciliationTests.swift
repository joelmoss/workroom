import AppKit
import XCTest

@testable import Workroom

/// The guard behind `WindowRegistry`'s key-gain focus reconciliation — the drift trigger the
/// `createSurface` focus re-sync cannot cover (the surface already exists; first responder moved off
/// it while the window wasn't key, so keys go nowhere until the user clicks the terminal).
///
/// Exercised against a real `NSWindow` with a real `GhosttySurfaceView` and no live libghostty
/// surface, mirroring `TerminalFocusAdoptionTests`. The point of the suite is the NEGATIVE half:
/// "no sheet is open" is not a sufficient condition, and a legitimate first responder the user chose
/// — a text field, the sidebar table, another split pane — must keep the keyboard.
@MainActor
final class TerminalFocusReconciliationTests: XCTestCase {

  private func windowedSurface() -> (NSWindow, GhosttySurfaceView) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: true)
    // Programmatic `NSWindow`s default `isReleasedWhenClosed` to true, which over-releases on top of
    // ARC — the sheet test closes its window, and without this the NEXT test in the class crashes.
    window.isReleasedWhenClosed = false
    let view = GhosttySurfaceView(
      workingDirectory: NSTemporaryDirectory(), command: nil, spawnsSurface: false)
    view.frame = window.contentView!.bounds
    window.contentView!.addSubview(view)
    return (window, view)
  }

  private func shouldRestore(_ window: NSWindow, _ surface: NSView) -> Bool {
    TerminalFocusReconciliation.shouldRestoreFirstResponder(in: window, to: surface)
  }

  // MARK: Drift — restore

  func testRestoresWhenFirstResponderIsTheWindow() {
    let (window, surface) = windowedSurface()
    // `makeFirstResponder(nil)` hands the role to the window itself — AppKit's "nobody" state, and
    // exactly what a pane torn down while the window was inactive leaves behind.
    XCTAssertTrue(window.makeFirstResponder(nil))
    XCTAssertTrue(
      shouldRestore(window, surface),
      "a window holding its own first-responder role means nothing has the keyboard")
  }

  func testRestoresWhenFirstResponderIsADetachedView() {
    let (window, surface) = windowedSurface()
    let stray = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    window.contentView!.addSubview(stray)
    XCTAssertTrue(window.makeFirstResponder(stray))
    stray.removeFromSuperview()  // AppKit keeps the resigned view as first responder
    XCTAssertTrue(
      shouldRestore(window, surface),
      "a first responder no longer in this window's hierarchy is drift, not a user choice")
  }

  // MARK: Legitimate focus — leave alone

  func testDoesNotStealFromALiveTextField() {
    let (window, surface) = windowedSurface()
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
    window.contentView!.addSubview(field)
    XCTAssertTrue(window.makeFirstResponder(field))
    XCTAssertFalse(
      shouldRestore(window, surface),
      "a focused text field is the user's own choice — the Codex caveat this guard exists for: "
        + "\"no sheet is open\" alone would have stolen the keyboard mid-typing")
  }

  func testDoesNotStealFromAnotherMountedPane() {
    let (window, surface) = windowedSurface()
    let other = GhosttySurfaceView(
      workingDirectory: NSTemporaryDirectory(), command: nil, spawnsSurface: false)
    other.frame = window.contentView!.bounds
    window.contentView!.addSubview(other)
    XCTAssertTrue(window.makeFirstResponder(other))
    XCTAssertFalse(
      shouldRestore(window, surface),
      "another live split pane holding focus is not drift")
  }

  func testNoOpWhenTheSurfaceAlreadyHoldsFocus() {
    let (window, surface) = windowedSurface()
    XCTAssertTrue(window.makeFirstResponder(surface))
    XCTAssertFalse(shouldRestore(window, surface), "nothing to restore — it is already focused")
  }

  func testDoesNotRestoreToAnUnmountedSurface() {
    let (window, surface) = windowedSurface()
    XCTAssertTrue(window.makeFirstResponder(nil))
    surface.removeFromSuperview()
    XCTAssertFalse(
      shouldRestore(window, surface),
      "a surface that is no longer in this window is not a focus target")
  }

  // MARK: The wiring — `WindowRegistry`'s key-gain handler actually calling the guard

  /// The decision function above is only half the fix: nothing proves `WindowRegistry` consults it
  /// on key-gain. This drives the real notification the app's own observer is registered for.
  private func storeWithOneTerminal() -> (AppStore, TerminalTarget, GhosttySurfaceView) {
    let store = AppStore()
    // `spawnsSurface: false` matters here (unlike the other `AppStore` suites): this test MOUNTS the
    // view in a window, and a spawning surface would launch a real PTY on attach.
    store.terminals.makeView = { _, cwd, _ in
      GhosttySurfaceView(workingDirectory: cwd, command: nil, spawnsSurface: false)
    }
    store.projects = [
      Project(
        path: "/focus-reconcile", vcs: "git",
        workrooms: [
          Workroom(
            name: "main", path: "/focus-reconcile/main", vcsName: "workroom/main", warnings: [])
        ])
    ]
    let sid = SidebarID.workroom(project: "/focus-reconcile", name: "main")
    store.selectedTargetID = sid
    store.newTerminalInSelectedTarget()
    let target = store.target(for: sid)!
    return (store, target, store.terminals.focusedTab(for: target)!.surface!)
  }

  private func registeredWindow(_ store: AppStore, _ surface: GhosttySurfaceView) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    surface.frame = window.contentView!.bounds
    window.contentView!.addSubview(surface)
    WindowRegistry.shared.register(window: window, store: store)
    return window
  }

  func testKeyGainRestoresFocusToTheFocusedPane() {
    let (store, _, surface) = storeWithOneTerminal()
    let window = registeredWindow(store, surface)
    defer { WindowRegistry.shared.unregister(window: window) }
    XCTAssertTrue(window.makeFirstResponder(nil))

    // The observer is registered with `queue: .main`, so delivery is asynchronous even from here.
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    settle(1.0, until: { window.firstResponder === surface })

    XCTAssertTrue(
      window.firstResponder === surface,
      "key-gain must hand the keyboard back to the focused pane when nothing else holds it")
  }

  func testKeyGainLeavesALiveTextFieldFocused() {
    let (store, _, surface) = storeWithOneTerminal()
    let window = registeredWindow(store, surface)
    defer { WindowRegistry.shared.unregister(window: window) }
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
    window.contentView!.addSubview(field)
    XCTAssertTrue(window.makeFirstResponder(field))

    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    settle(0.4)  // a dwell: the only way to show something did NOT happen

    XCTAssertFalse(
      window.firstResponder === surface,
      "reconciliation must never pull the keyboard out of a field the user is typing in")
  }

  func testDoesNotRestoreWhileASheetIsAttached() {
    let (window, surface) = windowedSurface()
    XCTAssertTrue(window.makeFirstResponder(nil))
    // `beginSheet` is a no-op on a window that was never ordered in.
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
      styleMask: [.titled], backing: .buffered, defer: true)
    sheet.isReleasedWhenClosed = false
    window.beginSheet(sheet)
    defer { window.endSheet(sheet) }
    // `beginSheet` attaches on a later run-loop turn — `attachedSheet` is still nil on return.
    settle(1.0, until: { window.attachedSheet != nil })
    XCTAssertNotNil(window.attachedSheet, "the fixture must actually attach the sheet")
    XCTAssertFalse(
      shouldRestore(window, surface), "a sheet owns the keyboard for as long as it is up")
  }
}
