import AppKit
import HostDrivers
import WorkroomVCS
import XCTest

@testable import Workroom

/// Guards the keyboard-input regression we hit during QA: macOS reports arrows / F-keys / nav keys
/// as function-key private-use scalars (U+F700–U+F8FF), which must NOT be forwarded as text (else
/// they insert a stray glyph), while DEL (U+007F, the Backspace key) stays as text, matching upstream
/// (it encodes to the same `\x7f` either way). See `GhosttySurfaceView.filterSpecialCharacters`.
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
    // DEL (0x7F) stays as text, as upstream's `ghosttyCharacters` leaves it. Unlike C0 controls, it
    // is not in the range this filter drops.
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

  func testEveryModifierKeyIsSafe() throws {
    // Left Command (55) with .command is the exact event shape seen throwing in the live app during
    // ⌘-Tab: reading `charactersIgnoringModifiers` is what raised, so reaching the assertions at all
    // is part of the test. Shift/Option/Control/CapsLock, left and right, plus the release event
    // (flags cleared) — only ⌘ was exercised by hand, so pin the whole family.
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

/// When a remote pane reattaches after its ssh exits 255 (#241).
final class RemoteReconnectBackoffTests: XCTestCase {
  /// A host rebooting for two minutes, whatever it answers meanwhile (refused, timed out, closed
  /// before its banner, or sshd up before the daemon): the pane backs off to the ceiling and never
  /// gives up on it.
  func testAHostThatIsGoneForMinutesIsWaitedFor() throws {
    var backoff = RemoteReconnectBackoff()
    // The link drops out of an attach that had been up a while.
    XCTAssertEqual(backoff.next(attachedFor: 3600, refused: false), 1)
    var waited: TimeInterval = 1
    var delays: [TimeInterval] = []
    while waited < 600 {
      let delay = try XCTUnwrap(backoff.next(attachedFor: 10, refused: false))
      delays.append(delay)
      waited += delay
    }
    XCTAssertEqual(Array(delays.prefix(6)), [2, 4, 8, 16, 30, 30])
    XCTAssertEqual(delays.last, 30)
  }

  /// A host that refuses for good (a changed host key) stops the pane after the same budget as
  /// before: five quick refusals, which leaves ssh's message on screen.
  func testARefusalStopsAfterFive() {
    var backoff = RemoteReconnectBackoff()
    XCTAssertEqual(backoff.next(attachedFor: .infinity, refused: false), 1)
    XCTAssertEqual(backoff.next(attachedFor: 1, refused: true), 2)
    XCTAssertEqual(backoff.next(attachedFor: 1, refused: true), 4)
    XCTAssertEqual(backoff.next(attachedFor: 1, refused: true), 8)
    XCTAssertEqual(backoff.next(attachedFor: 1, refused: true), 16)
    XCTAssertNil(backoff.next(attachedFor: 1, refused: true))
  }

  /// Failures that heal, in between, do not restart the count: a refusal alternating with a host
  /// that is briefly unreachable still stops.
  func testARefusalBetweenFailuresThatHealStillStops() {
    var backoff = RemoteReconnectBackoff()
    for _ in 1..<RemoteReconnectBackoff.maxRefusals {
      XCTAssertNotNil(backoff.next(attachedFor: 1, refused: true))
      XCTAssertNotNil(backoff.next(attachedFor: 1, refused: false))
    }
    XCTAssertNil(backoff.next(attachedFor: 1, refused: true))
  }

  /// An attach that stayed up past the ceiling was a working link: its drop starts over.
  func testALinkThatWasUpStartsTheBackoffAgain() {
    var backoff = RemoteReconnectBackoff()
    for _ in 1..<RemoteReconnectBackoff.maxRefusals {
      _ = backoff.next(attachedFor: 1, refused: true)
    }
    XCTAssertEqual(backoff.next(attachedFor: 60, refused: false), 1)
    XCTAssertEqual(backoff.refusals, 0)
  }
}

/// The pane's side of #241: a remote pane whose ssh exits 255 schedules a restored reattach, and
/// closing it cancels one that is waiting. The backoff's decisions are `RemoteReconnectBackoffTests`;
/// what the attach itself does is the fixture's (`RemoteHostIntegrationTests`).
@MainActor
final class RemotePaneReconnectTests: XCTestCase {
  /// A pane for a session on a host whose last attach left `log` behind, and `status` as the
  /// attach wrapper's record of ssh's exit status (none when nil).
  /// `provider`: on an exe.dev host, whose ssh leaves the Mac, rather than a container's loopback.
  private func remotePane(
    log: String, status: String? = nil, provider: Bool = false
  ) throws -> GhosttySurfaceView {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-reconnect-\(UUID().uuidString.prefix(8))")
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let host = UUID()
    let session = UUID()
    let driver: any HostTerminalDriver =
      provider
      ? ExeDevHostDriver(
        configuration: .init(account: nil, sshAgent: "/agent.sock"), directory: directory)
      : ContainerHostDriver(
        hosts: [
          host: .init(
            address: "127.0.0.1", port: 1, user: "workroom", identityFile: "/keys/id",
            hostKey: "ssh-ed25519 AAAA", daemonSocket: "/s")
        ], directory: directory)
    let hostDirectory = directory.appendingPathComponent(host.uuidString)
    try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
    statusFiles[session] = SSHTransport.attachStatus(session, in: hostDirectory)
    try log.write(
      to: SSHTransport.attachLog(session, in: hostDirectory), atomically: true,
      encoding: .utf8)
    if let status {
      try status.write(
        to: SSHTransport.attachStatus(session, in: hostDirectory), atomically: true,
        encoding: .utf8)
    }
    PersistentSessionService.shared.registerRemoteSession(
      session, on: .remote(host), via: driver, workingDirectory: "/home/w")
    let view = GhosttySurfaceView(workingDirectory: "/home/w", spawnsSurface: false)
    view.persistentSessionID = session
    addTeardownBlock { view.tearDown() }
    return view
  }

  private func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  /// Each `remotePane`'s record of ssh's status, by session.
  private var statusFiles: [UUID: URL] = [:]

  /// The pane's attach ends with no status recorded: its wrapper removed the last one and was
  /// killed before ssh exited, as by a Ctrl-C typed while ssh was still connecting (#507).
  private func exitBeforeSshRecords(_ view: GhosttySurfaceView) throws {
    let status = try XCTUnwrap(statusFiles[XCTUnwrap(view.persistentSessionID)])
    try? FileManager.default.removeItem(at: status)
    view.handleChildExited(exitCode: 0)
  }

  // Value: protects=a remote pane the app is reconnecting coming back after a Ctrl-C lands in the
  // second before its ssh connects; fails_when=a missing status on the app's own reconnect reads
  // as a finished attach again; why_new=#507, which #506's reattach on wake made easy to hit;
  // seam=none
  /// A Ctrl-C typed while the app's own reconnect is still connecting kills it, as it would kill
  /// any ssh, before the wrapper records a status (#507). The pane reads that as the lost link it
  /// was reconnecting and keeps trying, again and again if the next attempts are killed too, after
  /// a backoff or a network change alike.
  func testAReconnectKilledBeforeSshConnectsKeepsTrying() throws {
    let view = try remotePane(log: "", status: "255\n")
    view.handleChildExited(exitCode: 0)
    try XCTUnwrap(view.pendingReconnect).perform()
    for attempt in 1...2 {
      try exitBeforeSshRecords(view)
      let retry = try XCTUnwrap(view.pendingReconnect, "attempt \(attempt) was left stopped")
      retry.perform()
    }
    XCTAssertTrue(view.persistentSessionIsRestored)
    // A status the reconnect did record is its answer: a session that ended there stays ended.
    try "0\n".write(
      to: XCTUnwrap(statusFiles[XCTUnwrap(view.persistentSessionID)]), atomically: true,
      encoding: .utf8)
    view.handleChildExited(exitCode: 0)
    XCTAssertNil(view.pendingReconnect, "a reconnect that ended its session was tried again")

    let live = try remotePane(log: "", provider: true)
    live.liveProcessOverrideForTesting = true
    let host = try XCTUnwrap(
      PersistentSessionService.shared.remoteHost(of: XCTUnwrap(live.persistentSessionID)))
    postLinksStale([host])
    XCTAssertTrue(live.persistentSessionIsRestored, "the network change did not reattach")
    try exitBeforeSshRecords(live)
    XCTAssertNotNil(live.pendingReconnect, "a reattach after a network change was left stopped")
  }

  // Value: protects=Ctrl-C stopping an attach the user started, as it stops any ssh;
  // fails_when=every missing status reads as a lost link, or the app's reconnect outlives an
  // attach the user chose; why_new=#507 reads a missing status as lost only on the app's own
  // reconnect; seam=none
  /// An attach the user chose (from the detached-sessions list) that a Ctrl-C kills stays stopped,
  /// even on a pane the app was reconnecting a moment before.
  func testAnAttachTheUserChoseStaysStoppedWhenKilled() throws {
    let view = try remotePane(log: "", status: "255\n")
    view.handleChildExited(exitCode: 0)
    try XCTUnwrap(view.pendingReconnect).perform()
    view.reattachPersistentSession()
    try exitBeforeSshRecords(view)
    XCTAssertNil(view.pendingReconnect)
  }

  // Value: protects=a pane restored at launch whose host was unreachable keeping the retry
  // notice's promise when a Ctrl-C kills one of its retries; fails_when=only a link that was up in
  // this run keeps trying again; why_new=a #507 review found restored sessions' retries left out;
  // seam=none
  /// A pane restored at launch is a session the host already has, though its link was never up in
  /// this run: a Ctrl-C that kills one of the app's retries leaves it trying, as the notice on
  /// screen promised.
  func testARestoredPanesRetryKilledBeforeSshConnectsKeepsTrying() throws {
    let view = try remotePane(log: "", status: "255\n")
    view.persistentSessionIsRestored = true  // as launch restore marks it
    view.reattachPersistentSession()  // its first attach, which just failed, began now
    view.handleChildExited(exitCode: 0)
    try XCTUnwrap(view.pendingReconnect).perform()
    try exitBeforeSshRecords(view)
    XCTAssertNotNil(view.pendingReconnect, "a restored pane's killed retry was left stopped")
  }

  // Value: protects=a remote pane reattaching after its host restarts; fails_when=the reconnect is
  // gated on the pane's exit status again, which macOS `login` always reports as 0;
  // why_new=the old test passed 255 straight in, which no real pane ever sees (#392); seam=none
  /// The pane's exit status is `login`'s 0 (#392): the wrapper's record of ssh's 255 is what says
  /// the link dropped.
  func testALostLinkReattachesAsARestoredPane() throws {
    let view = try remotePane(
      log: "ssh: connect to host 127.0.0.1 port 1: Connection refused\n", status: "255\n")
    view.handleChildExited(exitCode: 0)
    XCTAssertNotNil(view.pendingReconnect)
    XCTAssertFalse(view.persistentSessionIsRestored)
    spin(1.5)
    XCTAssertNil(view.pendingReconnect, "the reconnect did not run")
    XCTAssertTrue(view.persistentSessionIsRestored)
  }

  // Value: protects=a pane holds its remote host only while its ssh lives, so a dead link, a closed
  // pane or a pane pointed at another session lets an idle box go; fails_when=the surface's exit,
  // teardown or session swap stops clearing the attach; why_new=only endSession and forget were
  // covered; seam=none
  /// A pane's ssh holds its box awake, and the app keeps the host while one is attached (#356). An
  /// ssh that exits, a pane pointed at another session, or a closed pane holds nothing. Not
  /// reached here: a window freeing a live surface without a teardown (`deinit`), which needs one.
  func testAPaneHoldsItsHostOnlyWhileItsSshLives() throws {
    let view = try remotePane(log: "")
    let sessions = PersistentSessionService.shared
    let session = try XCTUnwrap(view.persistentSessionID)
    let host = try XCTUnwrap(sessions.remoteHost(of: session))
    addTeardownBlock { PersistentSessionService.shared.forgetRemoteSession(session) }
    XCTAssertNotNil(sessions.attachCommand(forSession: session, by: view.attachToken))
    XCTAssertTrue(sessions.hasAttachedPane(on: host))

    view.handleChildExited(exitCode: 1)
    XCTAssertFalse(sessions.hasAttachedPane(on: host), "a pane whose ssh exited holds its host")

    XCTAssertNotNil(sessions.attachCommand(forSession: session, by: view.attachToken))
    view.persistentSessionID = UUID()
    XCTAssertFalse(
      sessions.hasAttachedPane(on: host), "a pane pointed at another session holds the old host")
    view.persistentSessionID = session

    XCTAssertNotNil(sessions.attachCommand(forSession: session, by: view.attachToken))
    view.tearDown()
    XCTAssertFalse(sessions.hasAttachedPane(on: host), "a closed pane holds its host")
  }

  // Value: protects=a new remote pane opened offline (or before its daemon is installed) getting a
  // working shell once its host answers, and a Ctrl-C still stopping its retries; fails_when=every
  // reconnect is marked restored again, so its retry carries `--no-create` and the never-created
  // session reads as ended, or a new pane's killed retry keeps trying too (#507);
  // why_new=the reconnect only started firing with #392, which exposed it (Codex review); seam=none
  /// A pane whose first attach never came up retries as a fresh attach: it has no session on the
  /// host yet, and a restored attach (`--no-create`) would show it ended instead of creating it.
  /// Its link was never up, so a Ctrl-C that kills the retry stops it, as it stops any ssh.
  func testAPaneThatNeverConnectedRetriesAsAFreshAttach() throws {
    let view = try remotePane(log: "", status: "255\n")
    view.reattachPersistentSession()  // the attach that just failed began now
    view.handleChildExited(exitCode: 0)
    XCTAssertNotNil(view.pendingReconnect)
    spin(1.5)
    XCTAssertNil(view.pendingReconnect, "the reconnect did not run")
    XCTAssertFalse(view.persistentSessionIsRestored)
    try exitBeforeSshRecords(view)
    XCTAssertNil(view.pendingReconnect, "a Ctrl-C did not stop a link that was never up")
  }

  func testClosingThePaneCancelsAReconnectThatIsWaiting() throws {
    let view = try remotePane(log: "", status: "255\n")
    view.handleChildExited(exitCode: 0)
    let pending = try XCTUnwrap(view.pendingReconnect)
    view.tearDown()
    XCTAssertTrue(pending.isCancelled)
    spin(1.5)
    XCTAssertFalse(view.persistentSessionIsRestored)
  }

  /// Only ssh's own failure is a lost link: a session that ended with any other status is left
  /// alone, as is a pane with no record of one (an exit status alone never decides, #392), and a
  /// pane whose session is not remote.
  func testOnlyARemotePanesLostLinkReconnects() throws {
    let remote = try remotePane(log: "", status: "1\n")
    remote.handleChildExited(exitCode: 0)
    XCTAssertNil(remote.pendingReconnect)
    let unrecorded = try remotePane(log: "")
    unrecorded.handleChildExited(exitCode: 255)
    XCTAssertNil(unrecorded.pendingReconnect)
    let local = GhosttySurfaceView(workingDirectory: "/tmp", spawnsSurface: false)
    local.persistentSessionID = UUID()
    local.handleChildExited(exitCode: 255)
    XCTAssertNil(local.pendingReconnect)
  }

  private func postLinksStale(_ stale: Set<HostID> = []) {
    NotificationCenter.default.post(
      name: RemoteLinkMonitor.linksStale, object: nil,
      userInfo: [RemoteLinkMonitor.staleHostsKey: stale])
    spin(0.05)
  }

  // Value: protects=a remote pane coming back within a second of the Mac waking or changing
  // networks, not after ssh's ~57 s keepalive or a 30 s backoff; fails_when=the pane stops
  // observing the monitor, runs its waiting reconnect without the restored mark, or treats a
  // container's loopback link as one a network change breaks; why_new=new behaviour; seam=none
  /// A pane waiting out its backoff attaches at once, as the restored pane its reconnect would
  /// have made. A container's pane is left to its backoff: its ssh never leaves the Mac.
  func testAWaitingPaneAttachesAtOnceWhenTheNetworkChanges() throws {
    let provider = try remotePane(log: "", status: "255\n", provider: true)
    provider.handleChildExited(exitCode: 0)
    let container = try remotePane(log: "", status: "255\n")
    container.handleChildExited(exitCode: 0)
    let waiting = try XCTUnwrap(container.pendingReconnect)
    XCTAssertNotNil(provider.pendingReconnect)

    postLinksStale()
    XCTAssertNil(provider.pendingReconnect, "the waiting reconnect did not run")
    XCTAssertTrue(provider.persistentSessionIsRestored)
    XCTAssertTrue(container.pendingReconnect === waiting)
    XCTAssertFalse(container.persistentSessionIsRestored)
  }

  // Value: protects=a live link whose host still answers keeping its screen after a wake, and one
  // whose host went silent reattaching; fails_when=every live pane blinks on every wake again, or
  // a pane stays on a link its host no longer answers on; why_new=new behaviour;
  // seam=liveProcessOverrideForTesting (non-test caller: hasLiveProcess's libghostty read)
  /// A pane whose ssh still runs attaches again only when its own host didn't answer.
  func testALivePaneAttachesAgainOnlyWhenItsHostDidNotAnswer() throws {
    let view = try remotePane(log: "", provider: true)
    view.liveProcessOverrideForTesting = true
    let session = try XCTUnwrap(view.persistentSessionID)
    let host = try XCTUnwrap(PersistentSessionService.shared.remoteHost(of: session))
    postLinksStale([.remote(UUID())])
    XCTAssertFalse(
      view.persistentSessionIsRestored, "a live link was replaced though its host answered")
    // A pane that stopped (no live ssh, nothing waiting) stays stopped, whatever its host did.
    let stopped = try remotePane(log: "", provider: true)
    let stoppedHost = try XCTUnwrap(
      PersistentSessionService.shared.remoteHost(of: XCTUnwrap(stopped.persistentSessionID)))
    postLinksStale([host, stoppedHost])
    XCTAssertTrue(
      view.persistentSessionIsRestored, "a live link was kept though its host was silent")
    XCTAssertFalse(stopped.persistentSessionIsRestored, "a stopped pane was attached again")
  }
}

// Value: protects=hosts are asked when the Mac wakes or its network moves or comes back, and only
// then; fails_when=a Docker or VPN interface that isn't preferred, or a repeat update, asks every
// host, or a wake, a network move or a return to a same-looking network is missed; why_new=new
// behaviour; seam=none
/// When the network moved enough that a remote link may be dead (`RemoteLinkTrigger`).
final class RemoteLinkTriggerTests: XCTestCase {
  private let wifi = RemoteLinkTrigger.Path(
    satisfied: true, interface: "en0", gateways: ["192.168.1.1:0"])
  private let down = RemoteLinkTrigger.Path(satisfied: false, interface: nil, gateways: [])
  private let settle = RemoteLinkTrigger.Action.fire(after: RemoteLinkTrigger.settle)

  func testTheNetworkTheLinksWereMadeOnAsksNothing() {
    var trigger = RemoteLinkTrigger()
    XCTAssertEqual(trigger.pathChanged(to: wifi), RemoteLinkTrigger.Action.none)
    XCTAssertEqual(trigger.pathChanged(to: wifi), RemoteLinkTrigger.Action.none)
  }

  func testAnotherInterfaceOrGatewayAsksEveryHost() {
    var trigger = RemoteLinkTrigger()
    _ = trigger.pathChanged(to: wifi)
    var ethernet = wifi
    ethernet.interface = "en7"
    XCTAssertEqual(trigger.pathChanged(to: ethernet), settle)
    trigger.fired()
    var otherWiFi = ethernet
    otherWiFi.gateways = ["10.0.0.1:0"]
    XCTAssertEqual(trigger.pathChanged(to: otherWiFi), settle)
  }

  /// A network back after going down asks every host, even one that looks the same: two networks
  /// can share an interface and a router's default address.
  func testANetworkBackAfterGoingDownAsksEveryHost() {
    var trigger = RemoteLinkTrigger()
    _ = trigger.pathChanged(to: wifi)
    XCTAssertEqual(trigger.pathChanged(to: down), .hold)
    XCTAssertEqual(trigger.pathChanged(to: down), .hold)
    XCTAssertEqual(trigger.pathChanged(to: wifi), settle)
    trigger.fired()
    XCTAssertEqual(trigger.pathChanged(to: wifi), RemoteLinkTrigger.Action.none)
  }

  /// A wake fires after `wakeWait`, or at the next path update; once fired, the network it woke
  /// on asks nothing more. A second wake before the first fired still fires.
  func testAWakeAsksEveryHostOnce() {
    var trigger = RemoteLinkTrigger()
    _ = trigger.pathChanged(to: wifi)
    XCTAssertEqual(trigger.woke(), .fire(after: RemoteLinkTrigger.wakeWait))
    XCTAssertEqual(trigger.woke(), .fire(after: RemoteLinkTrigger.wakeWait))
    XCTAssertEqual(trigger.pathChanged(to: wifi), settle)
    trigger.fired()
    XCTAssertEqual(trigger.pathChanged(to: wifi), RemoteLinkTrigger.Action.none)
  }

  /// What is owed survives the network dropping again before the fire, a second wake while it is
  /// down, and a fire that lands while it is down: the return still asks every host, once.
  func testWhatIsOwedSurvivesTheNetworkDroppingAgain() {
    var trigger = RemoteLinkTrigger()
    _ = trigger.pathChanged(to: wifi)
    _ = trigger.woke()
    XCTAssertEqual(trigger.pathChanged(to: down), .hold)
    XCTAssertEqual(trigger.woke(), .hold)
    XCTAssertEqual(trigger.pathChanged(to: down), .hold)
    trigger.fired()
    XCTAssertEqual(trigger.pathChanged(to: wifi), settle)
    trigger.fired()
    XCTAssertEqual(trigger.pathChanged(to: wifi), RemoteLinkTrigger.Action.none)
  }

  /// A wake with no network yet holds, and fires once the network is back.
  func testAWakeHeldByANetworkThatIsDownFiresWhenItIsBack() {
    var trigger = RemoteLinkTrigger()
    _ = trigger.pathChanged(to: wifi)
    XCTAssertEqual(trigger.pathChanged(to: down), .hold)
    XCTAssertEqual(trigger.woke(), .hold)
    XCTAssertEqual(trigger.pathChanged(to: wifi), settle)
  }
}

// Value: protects=a terminal that is no workroom's (the exe.dev setup sheet's) offers no command
// that acts on the store's focused pane; fails_when=offersPaneCommands stops gating the menu, so
// Close Terminal there closes the workroom pane behind the sheet; why_new=the menu had no test;
// seam=contextMenu (non-test caller: presentContextMenu)
/// The context menu offers the pane commands only on a terminal that is a workroom's.
@MainActor
final class TerminalContextMenuTests: XCTestCase {
  func testOnlyAWorkroomsTerminalOffersThePaneCommands() {
    let surface = GhosttySurfaceView(workingDirectory: "/tmp", spawnsSurface: false)
    let titles = { surface.contextMenu().items.map(\.title).filter { !$0.isEmpty } }
    XCTAssertTrue(titles().contains("Close Terminal"))
    surface.offersPaneCommands = false
    XCTAssertEqual(titles(), ["Paste"])
  }
}
