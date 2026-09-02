import AppKit
import XCTest

@testable import Workroom

/// Guards the keyboard-input regression we hit during QA: macOS reports arrows / F-keys / nav keys
/// as function-key private-use scalars (U+F700–U+F8FF), which must NOT be forwarded as text (else
/// they insert a stray glyph), while DEL (U+007F, the Backspace key) MUST be kept and forwarded so
/// the shell receives the erase byte. See `GhosttySurfaceView.filterSpecialCharacters`.
final class TerminalKeyTextFilterTests: XCTestCase {
  private func filter(_ s: String) -> String { GhosttySurfaceView.filterSpecialCharacters(s) }

  func testEmptyStringStaysEmpty() {
    XCTAssertEqual(filter(""), "")
  }

  func testPlainTextPassesThrough() {
    XCTAssertEqual(filter("a"), "a")
    XCTAssertEqual(filter("é"), "é")
    XCTAssertEqual(filter("abc"), "abc")  // first scalar decides; whole string returned
  }

  func testFunctionKeyPrivateUseRangeIsDropped() {
    // The bug: these passed the old `>= 0x20` filter and got sent as text → "weird characters".
    XCTAssertEqual(filter("\u{F700}"), "", "up-arrow sentinel must be dropped")
    XCTAssertEqual(filter("\u{F701}"), "", "down-arrow sentinel must be dropped")
    XCTAssertEqual(filter("\u{F8FF}"), "", "end of the PUA function-key range must be dropped")
  }

  func testControlCharactersAreDropped() {
    XCTAssertEqual(filter("\u{0008}"), "", "BS (^H) is a control char")
    XCTAssertEqual(filter("\u{001B}"), "", "ESC is a control char")
    XCTAssertEqual(filter("\u{000D}"), "", "CR is a control char")
  }

  func testDelIsKept() {
    // The backspace fix: DEL (0x7F) must be forwarded as text (the pinned libghostty mis-encodes the
    // backspace *keycode*, so we send the byte instead).
    XCTAssertEqual(filter("\u{007F}"), "\u{007F}")
  }
}

/// Guards the overlay-scrollbar geometry (the indicator restored after the SwiftTerm → libghostty
/// migration). Pure math over libghostty's `total`/`offset`/`len` (rows). Bottom-left origin: the
/// live position sits at the bottom of the track. See `GhosttySurfaceView.scrollbarThumbRect`.
final class ScrollbarGeometryTests: XCTestCase {
  // 200pt track: bounds height 204 minus 2*inset(2).
  private let bounds = CGRect(x: 0, y: 0, width: 100, height: 204)
  private let width: CGFloat = 7
  private let inset: CGFloat = 2
  private let minThumb: CGFloat = 28

  private func rect(total: UInt64, offset: UInt64, len: UInt64) -> CGRect? {
    GhosttySurfaceView.scrollbarThumbRect(
      total: total, offset: offset, len: len, bounds: bounds,
      width: width, inset: inset, minThumb: minThumb)
  }

  func testHiddenWhenNothingToScroll() {
    XCTAssertNil(rect(total: 200, offset: 0, len: 200), "viewport == buffer → no thumb")
    XCTAssertNil(rect(total: 100, offset: 0, len: 200), "len > total (degenerate) → no thumb")
  }

  func testThumbSizeIsProportional() throws {
    // total 400, len 200 → half the 200pt track = 100pt thumb.
    let r = try XCTUnwrap(rect(total: 400, offset: 200, len: 200))
    XCTAssertEqual(r.height, 100, accuracy: 0.001)
    XCTAssertEqual(r.width, width)
    XCTAssertEqual(r.origin.x, bounds.width - width - inset, accuracy: 0.001)  // right edge
  }

  func testLivePositionSitsAtBottom() throws {
    // offset == total - len == live: thumb at the bottom (y == inset).
    let r = try XCTUnwrap(rect(total: 400, offset: 200, len: 200))
    XCTAssertEqual(r.origin.y, inset, accuracy: 0.001)
  }

  func testScrolledToTopSitsAtTop() throws {
    // offset 0: thumb at the top (y == inset + (track - thumb)).
    let r = try XCTUnwrap(rect(total: 400, offset: 0, len: 200))
    XCTAssertEqual(r.origin.y, inset + (200 - 100), accuracy: 0.001)
  }

  func testThumbClampsToMinimumHeight() throws {
    // Huge scrollback: proportional height (200*200/10000 = 4) clamps up to minThumb.
    let r = try XCTUnwrap(rect(total: 10000, offset: 0, len: 200))
    XCTAssertEqual(r.height, minThumb, accuracy: 0.001)
  }

  func testShouldFlashOnlyWhenScrolledBack() {
    // Live (at bottom) → no flash; scrolled back → flash; nothing-to-scroll → no flash.
    XCTAssertFalse(GhosttySurfaceView.scrollbarShouldFlash(total: 400, offset: 200, len: 200))
    XCTAssertTrue(GhosttySurfaceView.scrollbarShouldFlash(total: 400, offset: 100, len: 200))
    XCTAssertTrue(GhosttySurfaceView.scrollbarShouldFlash(total: 400, offset: 0, len: 200))
    XCTAssertFalse(GhosttySurfaceView.scrollbarShouldFlash(total: 200, offset: 0, len: 200))
  }

  func testIsScrolledBackDrivesGoToBottomButton() {
    // The go-to-bottom button shows exactly while scrolled back from the live bottom (issue #42):
    // hidden at the live bottom and when there's nothing to scroll; shown anywhere above the bottom.
    XCTAssertFalse(GhosttySurfaceView.isScrolledBack(total: 400, offset: 200, len: 200))  // live
    XCTAssertTrue(GhosttySurfaceView.isScrolledBack(total: 400, offset: 199, len: 200))  // 1 row up
    XCTAssertTrue(GhosttySurfaceView.isScrolledBack(total: 400, offset: 0, len: 200))  // top
    // No scrollback (buffer == viewport) → nothing below, so the button stays hidden.
    XCTAssertFalse(GhosttySurfaceView.isScrolledBack(total: 200, offset: 0, len: 200))
  }
}

/// Guards the focus re-sync that fixes "arrows/letters do nothing when a TUI prompt appears in a
/// pane that looks focused." Root cause: a zero-bounds attach defers `createSurface`, so
/// `becomeFirstResponder` runs while `surface == nil` and its `setSurfaceFocused(true)` no-ops — the
/// surface is later created blurred while the view holds first responder, and keys are dropped. The
/// fix re-syncs the focus flag at the end of `createSurface`. These exercise the decision
/// (`holdsFirstResponder`) and the action (`adoptFocusIfFirstResponder`) against a real `NSWindow`
/// with no live surface, mirroring how `canSpawnSurface` is unit-tested.
@MainActor
final class TerminalFocusAdoptionTests: XCTestCase {
  private func windowedView() -> (NSWindow, GhosttySurfaceView) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: true)
    let view = GhosttySurfaceView(
      workingDirectory: NSTemporaryDirectory(), command: nil, spawnsSurface: false)
    view.frame = window.contentView!.bounds
    window.contentView!.addSubview(view)
    return (window, view)
  }

  func testHoldsFirstResponderReflectsWindowState() {
    let (window, view) = windowedView()
    XCTAssertTrue(window.makeFirstResponder(view), "the surface view must accept first responder")
    XCTAssertTrue(view.holdsFirstResponder)
    XCTAssertTrue(window.makeFirstResponder(nil))
    XCTAssertFalse(view.holdsFirstResponder)
  }

  func testAdoptFocusOnlyActsWhenFirstResponder() {
    let (window, view) = windowedView()
    _ = window.makeFirstResponder(nil)
    view.adoptFocusIfFirstResponder()
    XCTAssertEqual(view.focusSyncCount, 0, "must not adopt focus when not first responder")
    _ = window.makeFirstResponder(view)
    view.adoptFocusIfFirstResponder()
    XCTAssertEqual(view.focusSyncCount, 1, "adopts focus exactly once when first responder")
  }
}

/// The end-to-end ordering repro, gated on the libghostty runtime being available in the test host
/// (`XCTSkipUnless`) — a skipped test beats a flaky one. Reproduces: the view becomes first responder
/// while the surface is still nil (zero-bounds attach), then the surface is created on resize; the
/// fix must re-sync focus so `focusSyncCount` bumps during `createSurface`.
@MainActor
final class TerminalFocusAdoptionLiveSurfaceTests: XCTestCase {
  func testSurfaceCreatedAfterFirstResponderAdoptsFocus() throws {
    try XCTSkipUnless(GhosttyApp.shared.app != nil, "requires the libghostty runtime")
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: true)
    let view = GhosttySurfaceView(
      workingDirectory: NSTemporaryDirectory(), command: nil, spawnsSurface: true)
    defer { view.tearDown() }
    view.frame = .zero  // zero bounds → createSurface defers on attach
    window.contentView!.addSubview(view)
    XCTAssertTrue(window.makeFirstResponder(view))
    XCTAssertEqual(view.focusSyncCount, 0, "no surface yet — nothing to sync")
    view.setFrameSize(NSSize(width: 400, height: 300))  // deferred createSurface runs now
    XCTAssertEqual(
      view.focusSyncCount, 1, "createSurface must re-sync focus for the first-responder view")
  }
}

/// Guards the two properties that keep `GHOSTTY_ACTION_SELECTION_CHANGED` safe. libghostty emits
/// that action from inside `Surface.setSelection`, which upstream documents as "must be called with
/// the renderer mutex held" — so `handleSelectionChanged()` must do NOTHING on the calling stack
/// (any engine read re-locks a non-recursive mutex on the thread already holding it and wedges the
/// main thread), and a drag's per-mouse-move burst must collapse to one hop rather than one
/// notification per event. Both show up in `selectionChangePending`: set means the work was
/// deferred, and a second call while it is set must not queue a second hop.
@MainActor
final class TerminalSelectionChangedDeferralTests: XCTestCase {
  func testHandlerDefersInsteadOfWorkingOnTheCallbackStack() {
    let view = GhosttySurfaceView(workingDirectory: "/tmp", spawnsSurface: false)
    XCTAssertFalse(view.selectionChangePending)
    view.handleSelectionChanged()
    XCTAssertTrue(view.selectionChangePending, "must defer off the engine's stack, not act inline")
  }

  func testBurstCoalescesIntoOneHop() {
    let view = GhosttySurfaceView(workingDirectory: "/tmp", spawnsSurface: false)
    for _ in 0..<10 { view.handleSelectionChanged() }
    XCTAssertTrue(view.selectionChangePending)
    let drained = expectation(description: "queued hop ran")
    DispatchQueue.main.async { drained.fulfill() }  // FIFO: runs after the single queued hop
    wait(for: [drained], timeout: 2)
    XCTAssertFalse(
      view.selectionChangePending, "one hop for the whole burst — 10 events, 1 notification")
  }
}

/// Guards the ObjC exception that `flagsChanged` raised on every modifier press over a terminal
/// surface. `-[NSEvent charactersIgnoringModifiers]` is only legal on `.keyDown`/`.keyUp`; AppKit
/// raises `NSInternalInconsistencyException` ("Invalid message sent to event") for any other type,
/// and `flagsChanged(with:)` routes bare modifier presses through the same `buildKeyEvent` helper.
/// Observed live: nine exceptions from three ⌘-Tab round-trips, all `type=FlagsChanged keyCode=55`.
///
/// The visible cost is not the exception itself (AppKit catches it at the event-dispatch boundary)
/// but the two statements after the throwing call that never ran: libghostty was never told the
/// modifier changed, and the ⌘-hover cursor never refreshed.
@MainActor
final class GhosttyUnshiftedCodepointTests: XCTestCase {

  private func flagsChangedEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
        isARepeat: false, keyCode: keyCode))
  }

  func testFlagsChangedEventYieldsZeroWithoutRaising() throws {
    // Left Command (55) — the exact event shape seen throwing in the live app during ⌘-Tab. Reading
    // `charactersIgnoringModifiers` here is what raised; reaching the assertion at all is the test.
    let event = try flagsChangedEvent(keyCode: 55, flags: .command)
    XCTAssertEqual(
      GhosttySurfaceView.unshiftedCodepoint(for: event), 0,
      "a bare modifier has no unshifted codepoint — and must not raise reading for one")
  }

  func testEveryModifierKeyIsSafe() throws {
    // Shift/Option/Control/CapsLock, left and right, plus the release event (flags cleared) — only
    // ⌘ was exercised by hand, so pin the whole family rather than the one that was observed.
    for keyCode: UInt16 in [54, 55, 56, 57, 58, 59, 60, 61, 62] {
      for flags: NSEvent.ModifierFlags in [[], .command, .shift, .option, .control, .capsLock] {
        let event = try flagsChangedEvent(keyCode: keyCode, flags: flags)
        XCTAssertEqual(
          GhosttySurfaceView.unshiftedCodepoint(for: event), 0, "keyCode \(keyCode) must be safe")
      }
    }
  }

  func testRealKeyEventStillReportsItsCodepoint() throws {
    // The guard must not blind the path it protects: a real keyDown still yields its codepoint.
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
        keyCode: 0))
    XCTAssertEqual(
      GhosttySurfaceView.unshiftedCodepoint(for: event), UInt32(Character("a").asciiValue!))
  }
}
