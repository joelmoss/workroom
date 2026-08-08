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

  // MARK: Disabled store

  /// Fixture mode without a named session file must not touch the developer's own scrollback.
  func testDisabledStoreNeitherWritesNorReads() {
    let disabled = SessionStore(
      url: directory.appendingPathComponent("session.json"), isDisabled: true)
    disabled.writeScrollback("nope", forTabKey: "abc")
    XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar("abc").path))
    XCTAssertNil(disabled.readScrollback(forTabKey: "abc"))
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
