import XCTest

@testable import Workroom

/// Scrollback sidecars (issue #144): the per-pane text files that sit beside `session.json` and are
/// replayed into a restored terminal.
///
/// Every test injects a temp URL, so none of this touches the real session directory.
final class ScrollbackSidecarTests: XCTestCase {
  private var directory: URL!
  private var store: SessionStore!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("scrollback-sidecar-\(UUID().uuidString)", isDirectory: true)
    store = SessionStore(url: directory.appendingPathComponent("session.json"))
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func sidecar(_ key: String) -> URL {
    store.scrollbackDirectory.appendingPathComponent("\(key).txt")
  }

  // MARK: Round trip

  func testWriteThenReadRoundTrips() {
    store.writeScrollback("hello\nworld", forTabKey: "abc")
    XCTAssertEqual(store.readScrollback(forTabKey: "abc"), "hello\nworld")
  }

  func testWriteCreatesTheScrollbackDirectory() {
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.scrollbackDirectory.path))
    store.writeScrollback("x", forTabKey: "abc")
    XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar("abc").path))
  }

  func testEmptyCaptureWritesNothing() {
    store.writeScrollback("", forTabKey: "abc")
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar("abc").path))
    XCTAssertNil(store.readScrollback(forTabKey: "abc"))
  }

  func testMissingSidecarReadsAsNil() {
    XCTAssertNil(store.readScrollback(forTabKey: "nope"))
  }

  // MARK: Validation

  /// Deleted rather than quarantined: it would fail identically on every future launch, and unlike
  /// `session.json` a scrollback sidecar has no diagnostic value.
  func testOversizedSidecarIsDiscardedAndDeleted() throws {
    try FileManager.default.createDirectory(
      at: store.scrollbackDirectory, withIntermediateDirectories: true)
    let huge = String(repeating: "x", count: SessionLimits.maxScrollbackFileBytes + 1024)
    try Data(huge.utf8).write(to: sidecar("big"))

    XCTAssertNil(store.readScrollback(forTabKey: "big"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar("big").path))
  }

  func testNonUTF8SidecarIsDiscardedAndDeleted() throws {
    try FileManager.default.createDirectory(
      at: store.scrollbackDirectory, withIntermediateDirectories: true)
    try Data([0xFF, 0xFE, 0xFF]).write(to: sidecar("junk"))

    XCTAssertNil(store.readScrollback(forTabKey: "junk"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar("junk").path))
  }

  /// Captures are rendered text and carry no escape sequences, so this exists purely so a
  /// hand-edited sidecar cannot leave the terminal parser mid-sequence on replay.
  func testControlBytesAreStrippedOnRead() {
    let hostile = "before\u{1B}[31mafter\u{07}\u{00}end"
    store.writeScrollback(hostile, forTabKey: "abc")
    let read = try? XCTUnwrap(store.readScrollback(forTabKey: "abc"))
    XCTAssertEqual(read, "before[31mafterend")
  }

  /// CR is kept — the divider itself is CRLF, and stripping it would break the replayed layout.
  func testNewlineTabAndCarriageReturnSurvive() {
    XCTAssertEqual(
      SessionStore.strippingControlBytes("a\nb\tc\rd"), "a\nb\tc\rd")
  }

  func testSidecarOfOnlyControlBytesReadsAsNil() {
    store.writeScrollback("\u{01}\u{02}", forTabKey: "abc")
    XCTAssertNil(store.readScrollback(forTabKey: "abc"))
  }

  // MARK: Key safety

  /// **SECURITY REGRESSION.** `session.json` is a plain file the user (or anything running as them)
  /// can edit, and `URL.appendingPathComponent` does NOT normalise — measured: a key of `../../../x`
  /// yields a path that escapes on access. Since `readScrollback` DELETES a file that fails
  /// validation, an unchecked key was an arbitrary-file-delete primitive that fires at launch.
  func testKeysThatCouldEscapeTheDirectoryAreRefused() {
    for hostile in [
      "../../../evil", "a/b", "/etc/hosts", ".hidden", "", String(repeating: "x", count: 200),
    ] {
      XCTAssertFalse(
        SessionStore.isSafeScrollbackKey(hostile), "\"\(hostile)\" must not address a file")
    }
  }

  func testOrdinaryTabKeysAreAccepted() {
    XCTAssertTrue(SessionStore.isSafeScrollbackKey(UUID().uuidString))
    XCTAssertTrue(SessionStore.isSafeScrollbackKey("t0"))
  }

  func testAnUnsafeKeyNeitherReadsNorWrites() throws {
    let outside = directory.appendingPathComponent("outside.txt")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("do not touch".utf8).write(to: outside)

    store.writeScrollback("nope", forTabKey: "../outside")
    XCTAssertNil(store.readScrollback(forTabKey: "../outside"))
    XCTAssertEqual(
      try String(contentsOf: outside, encoding: .utf8), "do not touch",
      "a file outside the scrollback directory must be untouched")
  }

  // MARK: Permissions

  /// A sidecar is verbatim terminal output — whatever the shell printed, including anything secret.
  /// The default 0644 would leave that readable by every other account on the machine.
  func testSidecarsAreOwnerOnly() throws {
    store.writeScrollback("secret", forTabKey: "abc")

    let filePerms =
      try FileManager.default.attributesOfItem(atPath: sidecar("abc").path)[.posixPermissions]
      as? NSNumber
    XCTAssertEqual(filePerms?.int16Value, 0o600)
    let dirPerms =
      try FileManager.default.attributesOfItem(atPath: store.scrollbackDirectory.path)[
        .posixPermissions] as? NSNumber
    XCTAssertEqual(dirPerms?.int16Value, 0o700)
  }

  // MARK: Prune

  func testPruneRemovesOnlyUnknownKeys() {
    store.writeScrollback("keep", forTabKey: "live")
    store.writeScrollback("drop", forTabKey: "dead")

    store.pruneScrollback(keeping: ["live"])

    XCTAssertEqual(store.readScrollback(forTabKey: "live"), "keep")
    XCTAssertNil(store.readScrollback(forTabKey: "dead"))
  }

  /// A pane whose capture is now empty wrote no sidecar this quit, so its old one must go — else
  /// yesterday's output reappears under today's empty pane.
  func testPruneWithNoKeysClearsEverything() {
    store.writeScrollback("stale", forTabKey: "abc")
    store.pruneScrollback(keeping: [])
    XCTAssertNil(store.readScrollback(forTabKey: "abc"))
  }

  func testPruneOnMissingDirectoryIsHarmless() {
    store.pruneScrollback(keeping: ["anything"])
  }

  // MARK: The opt-out

  /// A sidecar is verbatim terminal output written to disk in plain text, and terminals hold tokens,
  /// `env` dumps and connection strings — which Time Machine and any folder sync then pick up. The
  /// switch exists so that is the user's call; turning it off must cost the TEXT and nothing else.
  @MainActor
  func testTurningScrollbackOffLeavesTheLayoutAlone() {
    let store = AppStore(projectStore: ProjectStore())
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command)
    }
    let target = TerminalTarget(id: "wr|/p|foo", title: "foo", path: "/tmp", isMissing: false)
    store.terminals.addTab(for: target)

    store.captureScrollback(into: self.store, isEnabled: false)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: self.store.scrollbackDirectory.path),
      "with the preference off nothing is written at all")
    XCTAssertEqual(
      store.captureWindowSession().targets.first?.tabs.count, 1,
      "the pane itself still persists — only its text is opted out")
  }

  // MARK: Disabled store

  /// Fixture mode without a named session file must not touch the developer's own scrollback.
  func testDisabledStoreNeitherWritesNorReads() {
    let disabled = SessionStore(
      url: directory.appendingPathComponent("session.json"), isDisabled: true)
    disabled.writeScrollback("nope", forTabKey: "abc")
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar("abc").path))
    XCTAssertNil(disabled.readScrollback(forTabKey: "abc"))
  }

  // MARK: Alternate-screen discrimination

  /// The whole rule, and the reason it is a change over time rather than a property.
  ///
  /// `SURFACE` returns history normally and **false** while a TUI holds the alternate screen. So a
  /// pane that produced scrollback before, reading false now, has a TUI up — and its visible frame
  /// must not be captured, because restoring a frozen vim or Claude screen as dead text looks
  /// interactive and is not.
  ///
  /// `mouse_captured` is NOT the signal: measured false for `less`, `man`, `vim` and Claude Code
  /// alike, so it caught nothing at all.
  func testViewportIsSkippedOnlyWhenHistoryVanishes() {
    XCTAssertTrue(
      GhosttySurfaceView.shouldSkipViewport(hasHistoryNow: false, everHadScrollback: true),
      "history existed before and reads false now — a TUI is up")
    XCTAssertFalse(
      GhosttySurfaceView.shouldSkipViewport(hasHistoryNow: false, everHadScrollback: false),
      "a short session that never scrolled must still capture its visible lines")
    XCTAssertFalse(
      GhosttySurfaceView.shouldSkipViewport(hasHistoryNow: true, everHadScrollback: true),
      "history is readable, so nothing is hiding it")
    XCTAssertFalse(
      GhosttySurfaceView.shouldSkipViewport(hasHistoryNow: true, everHadScrollback: false))
  }

  // MARK: Quit-time read bound

  /// `read_text` has no length parameter — it materialises the WHOLE history, and only then does
  /// `tidy` keep the last 256KB. With no `scrollback-limit` in the generated ghostty config that is
  /// bounded by the engine's own default (megabytes per surface), and it runs serially for every pane
  /// inside `applicationShouldTerminate`. A pane that logged all day would hang the quit for output
  /// that gets discarded anyway.
  func testHistoryIsReadOnlyWhileItCouldStillFitTheCap() {
    XCTAssertTrue(GhosttySurfaceView.shouldReadHistory(totalRows: 0))
    XCTAssertTrue(GhosttySurfaceView.shouldReadHistory(totalRows: nil), "no geometry yet")
    XCTAssertTrue(
      GhosttySurfaceView.shouldReadHistory(totalRows: GhosttySurfaceView.maxCaptureRows))
    XCTAssertFalse(
      GhosttySurfaceView.shouldReadHistory(totalRows: GhosttySurfaceView.maxCaptureRows + 1))
    XCTAssertFalse(GhosttySurfaceView.shouldReadHistory(totalRows: 10_000_000))
  }

  /// The row guard must sit ABOVE what the byte cap keeps, or it would throw away history that would
  /// have survived anyway — the guard exists to bound work, not to shrink the capture. Measured
  /// against a typical rendered row; this assertion is what caught the bound being set too low.
  func testTheRowBoundIsAboveWhatTheByteCapKeeps() {
    let typicalRenderedRow = 32
    XCTAssertGreaterThan(
      Int(GhosttySurfaceView.maxCaptureRows) * typicalRenderedRow,
      SessionLimits.maxScrollbackBytes)
  }

  // MARK: Replay payload

  /// **REGRESSION.** `read_text` returns lines separated by bare `\n`, and a terminal treats LF as
  /// "down one row, keep the column" — so replaying the capture unchanged staircased every line
  /// further right than the last. CR is what returns to column zero.
  func testReplayPayloadUsesCRLFLineEndings() {
    let payload = GhosttySurfaceView.replayPayload(for: "one\ntwo\nthree")
    XCTAssertTrue(payload.hasPrefix("one\r\ntwo\r\nthree"))
    XCTAssertFalse(
      payload.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
      "no bare LF may survive — each one is a staircase step")
  }

  /// Text that already had CRLF must not end up with doubled carriage returns.
  func testReplayPayloadDoesNotDoubleExistingCarriageReturns() {
    let payload = GhosttySurfaceView.replayPayload(for: "one\r\ntwo")
    XCTAssertTrue(payload.hasPrefix("one\r\ntwo"))
    XCTAssertFalse(payload.contains("\r\r"))
  }

  func testReplayPayloadEndsWithTheDivider() {
    XCTAssertTrue(
      GhosttySurfaceView.replayPayload(for: "x").hasSuffix(GhosttySurfaceView.scrollbackDivider))
  }

  // MARK: Divider

  /// The one marker in a restored pane: it separates dead history from the live shell.
  func testDividerIsPlainTextWithNoEscapeSequences() {
    let divider = GhosttySurfaceView.scrollbackDivider
    XCTAssertTrue(divider.contains("restored session"))
    XCTAssertFalse(
      divider.contains("\u{1B}"), "no SGR — the divider is content like any other byte")
    XCTAssertTrue(divider.hasPrefix("\r\n"))
    XCTAssertTrue(divider.hasSuffix("\r\n"))
  }
}
