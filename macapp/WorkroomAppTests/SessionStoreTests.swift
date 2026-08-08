import XCTest

@testable import Workroom

/// File-level tests for the saved-session store (issue #46).
///
/// Every test injects a temp URL, so none of this touches the real session file, the developer's own
/// Dev-bundle state, or any shared `Defaults` key — which is also what keeps it clear of the
/// single-writer rule parallel test workers impose on the UserDefaults domain.
final class SessionStoreTests: XCTestCase {
  private var directory: URL!
  private var url: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-store-tests-\(UUID().uuidString)", isDirectory: true)
    // Deliberately NOT created here — the store has to create its own parent directory.
    url = directory.appendingPathComponent("nested").appendingPathComponent("session.json")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func makeFile(windowKey: String = "W1", schemaVersion: Int? = nil) -> SessionFile {
    let window = WindowSession(
      windowKey: windowKey, frame: "{{0, 0}, {1200, 780}}", isKey: true,
      selectedTargetID: "wr|/p|calm-otter",
      targets: [
        TargetSession(
          targetID: "wr|/p|calm-otter",
          tabs: [
            TabSession(
              key: "t1", kind: TabSession.terminalKind,
              terminal: TerminalPayload(defaultTitle: "Terminal 1", cwd: "/p/calm-otter"))
          ],
          terminalCounter: 1)
      ])
    return SessionFile(
      schemaVersion: schemaVersion ?? SessionFile.currentSchemaVersion,
      savedAt: Date(timeIntervalSince1970: 1_000_000), appVersion: "2.0.0", windows: [window])
  }

  // MARK: Round trip

  func testWriteThenReadRoundTrips() throws {
    let store = SessionStore(url: url)
    store.writeSynchronously(makeFile())

    guard case .restored(let file, let report) = SessionStore(url: url).read() else {
      return XCTFail("expected a restored session")
    }
    XCTAssertTrue(report.isEmpty)
    XCTAssertEqual(file.windows.count, 1)
    XCTAssertEqual(file.windows[0].windowKey, "W1")
    XCTAssertEqual(file.windows[0].selectedTargetID, "wr|/p|calm-otter")
    XCTAssertEqual(file.windows[0].targets[0].tabs[0].terminal?.cwd, "/p/calm-otter")
    XCTAssertEqual(file.windows[0].targets[0].terminalCounter, 1)
  }

  /// `Data.write(.atomic)` does not create intermediate directories, and the bundle-id subdirectory
  /// never exists on a first run — without an explicit create, every write fails silently.
  func testWriteCreatesTheParentDirectory() throws {
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    SessionStore(url: url).writeSynchronously(makeFile())
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }

  func testWriteSynchronouslyCompletesBeforeReturning() throws {
    SessionStore(url: url).writeSynchronously(makeFile())
    // No waiting, no polling: the file must already be on disk. This is what the quit path needs,
    // where the process may not survive long enough for an async write to land.
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertFalse(try Data(contentsOf: url).isEmpty)
  }

  /// An atomic replace is all-or-nothing: a second write never leaves a half-written document.
  func testOverwriteLeavesNoPartialFile() throws {
    let store = SessionStore(url: url)
    store.writeSynchronously(makeFile(windowKey: "W1"))
    store.writeSynchronously(makeFile(windowKey: "W2"))

    guard case .restored(let file, _) = SessionStore(url: url).read() else {
      return XCTFail("expected a restored session")
    }
    XCTAssertEqual(file.windows.map(\.windowKey), ["W2"])
  }

  func testClearRemovesTheFile() {
    let store = SessionStore(url: url)
    store.writeSynchronously(makeFile())
    store.clear()
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertEqual(SessionStore(url: url).read(), .none)
  }

  // MARK: Degradation

  func testMissingFileReadsAsNone() {
    XCTAssertEqual(SessionStore(url: url).read(), .none)
  }

  func testEmptyFileReadsAsNone() throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: url)
    XCTAssertEqual(SessionStore(url: url).read(), .none)
  }

  /// Corrupt input must not crash the launch, and the evidence is moved aside rather than deleted so
  /// a bug report has something to attach.
  func testCorruptFileIsQuarantinedOnce() throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("this is not json".utf8).write(to: url)

    let store = SessionStore(url: url)
    XCTAssertEqual(store.read(), .none)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.quarantineURL.path))

    // A second corrupt file replaces the quarantine rather than accumulating copies.
    try Data("still not json".utf8).write(to: url)
    XCTAssertEqual(store.read(), .none)
    XCTAssertEqual(
      String(decoding: try Data(contentsOf: store.quarantineURL), as: UTF8.self),
      "still not json")
  }

  func testOversizedFileIsRefusedBeforeDecoding() throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let padding = String(repeating: "x", count: SessionLimits.maxFileBytes + 1024)
    try Data("{\"pad\":\"\(padding)\"}".utf8).write(to: url)

    let store = SessionStore(url: url)
    XCTAssertEqual(store.read(), .none)
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.quarantineURL.path))
  }

  /// A valid envelope whose windows all dropped is not a usable session — saying so is what lets the
  /// caller take its cold-start fallback instead of launching emptier than deleting the file would.
  func testFileWithNoSurvivingWindowsReadsAsNone() throws {
    let file = SessionFile(
      savedAt: Date(timeIntervalSince1970: 0),
      windows: [
        WindowSession(
          windowKey: "W1",
          targets: [TargetSession(targetID: "root|/p", tabs: [TabSession(key: "t", kind: "??")])])
      ])
    // The window survives sanitisation (an empty window is legal); an all-empty FILE does not.
    SessionStore(url: url).writeSynchronously(
      SessionFile(savedAt: Date(timeIntervalSince1970: 0), windows: []))
    XCTAssertEqual(SessionStore(url: url).read(), .none)

    SessionStore(url: url).writeSynchronously(file)
    guard case .restored(let restored, let report) = SessionStore(url: url).read() else {
      return XCTFail("a window with no targets is still a window")
    }
    XCTAssertTrue(restored.windows[0].targets.isEmpty)
    XCTAssertEqual(report.droppedTargets, 1)
  }

  // MARK: Newer schema is read-only

  /// Three build identities ship side by side, so a rollback is a real path: an older build must not
  /// overwrite a session written by a newer one.
  func testNewerSchemaDisablesWrites() throws {
    SessionStore(url: url).writeSynchronously(
      makeFile(windowKey: "FUTURE", schemaVersion: SessionFile.currentSchemaVersion + 1))
    let before = try Data(contentsOf: url)

    let store = SessionStore(url: url)
    XCTAssertEqual(store.read(), .newerSchema)
    XCTAssertTrue(store.writesDisabled)

    store.writeSynchronously(makeFile(windowKey: "OLD"))
    store.write(makeFile(windowKey: "OLD"))
    XCTAssertEqual(try Data(contentsOf: url), before, "the newer session must be left intact")
  }

  // MARK: Path scoping

  /// Without bundle-id scoping, a Dev run's fixture temp-dir workrooms would be restored into the
  /// release build — both already share `Application Support/Workroom/`.
  func testDefaultURLIsScopedByBundleID() {
    let dev = SessionStore.defaultURL(bundleID: "com.developwithstyle.workroom.dev")
    let release = SessionStore.defaultURL(bundleID: "com.developwithstyle.workroom")
    XCTAssertNotEqual(dev, release)
    XCTAssertEqual(dev.lastPathComponent, "session.json")
    XCTAssertEqual(
      dev.deletingLastPathComponent().lastPathComponent, "com.developwithstyle.workroom.dev")
    XCTAssertEqual(
      dev.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Workroom")
    XCTAssertTrue(release.path.contains("Application Support"))
  }
}
