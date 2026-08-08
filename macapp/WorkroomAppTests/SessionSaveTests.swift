import XCTest

@testable import Workroom

/// When the saved session is written (issue #46) — coalescing, the ceiling, the restore gate, and the
/// quit freeze.
///
/// The coordinator takes an injected store URL and an injected capture closure, so none of this needs
/// a window, an `AppStore`, or any shared `Defaults` key.
@MainActor
final class SessionSaveTests: XCTestCase {
  private var directory: URL!
  private var url: URL!
  /// What the injected capture returns. Mutate it to simulate the session changing.
  private var captured: [WindowSession] = []

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-save-tests-\(UUID().uuidString)", isDirectory: true)
    url = directory.appendingPathComponent("session.json")
    captured = [window(tabCount: 1)]
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func window(tabCount: Int, key: String = "W1") -> WindowSession {
    WindowSession(
      windowKey: key, isKey: true,
      targets: [
        TargetSession(
          targetID: "wr|/p|foo",
          tabs: (0..<tabCount).map {
            TabSession(
              key: "t\($0)", kind: TabSession.terminalKind,
              terminal: TerminalPayload(defaultTitle: "Terminal \($0)", cwd: nil))
          })
      ])
  }

  private func makeCoordinator(
    debounce: TimeInterval = 0.05, ceiling: TimeInterval = 0.2
  ) -> SessionCoordinator {
    SessionCoordinator(
      store: SessionStore(url: url), debounce: debounce, ceiling: ceiling,
      capture: { [weak self] in self?.captured ?? [] })
  }

  private func readWindows() -> [WindowSession]? {
    guard case .restored(let file, _) = SessionStore(url: url).read() else { return nil }
    return file.windows
  }

  /// Spin the main run loop so scheduled work items fire, without blocking the main actor.
  private func pump(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  // MARK: Coalescing

  func testDebouncedWriteLands() {
    let coordinator = makeCoordinator()
    coordinator.markDirty()
    XCTAssertNil(readWindows(), "nothing is written before the debounce elapses")

    pump(0.3)
    XCTAssertEqual(readWindows()?.count, 1)
  }

  /// **CRITICAL REGRESSION (eng review 1A).**
  ///
  /// The dirty sources fire faster than the debounce whenever a terminal produces output —
  /// `pulsePaneActivity` bumps a `@Published` dict per activity report, and every live-title update
  /// reassigns `tabsByTarget`. A plain cancel-and-replace debounce has its deadline pushed out
  /// forever and NEVER writes, so splitting a pane beside a running dev server would never be saved.
  /// The ceiling is what bounds that.
  func testSustainedChatterStillWritesWithinTheCeiling() {
    let coordinator = makeCoordinator(debounce: 0.2, ceiling: 0.4)
    let deadline = Date().addingTimeInterval(0.9)
    // Mark dirty faster than the debounce for longer than the ceiling — the starvation scenario.
    while Date() < deadline {
      coordinator.markDirty()
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    XCTAssertNotNil(
      readWindows(),
      "a debounce with no ceiling would starve here and never write the layout")
  }

  /// Title and activity churn produce an identical document, so it costs a comparison, not a write.
  func testUnchangedSessionIsNotRewritten() throws {
    let coordinator = makeCoordinator()
    coordinator.writeIfChanged()
    // `write` hands off to the store's serial queue — only the quit path writes synchronously.
    pump(0.2)
    let firstWrite = try XCTUnwrap(try? Data(contentsOf: url))

    // A later capture that is byte-identical must not touch the file — checked via the timestamp,
    // since `savedAt` would otherwise differ on every write.
    let before =
      try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
      as? Date
    pump(0.05)
    coordinator.writeIfChanged()
    let after =
      try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
      as? Date
    XCTAssertEqual(before, after, "an unchanged session must not be rewritten")
    XCTAssertEqual(try Data(contentsOf: url), firstWrite)
  }

  func testChangedSessionIsWritten() {
    let coordinator = makeCoordinator()
    coordinator.writeIfChanged()
    pump(0.2)
    XCTAssertEqual(readWindows()?.first?.targets.first?.tabs.count, 1)

    captured = [window(tabCount: 3)]
    coordinator.writeIfChanged()
    pump(0.2)
    XCTAssertEqual(readWindows()?.first?.targets.first?.tabs.count, 3)
  }

  // MARK: Restore gate

  /// **CRITICAL REGRESSION (outside voice, finding 1).**
  ///
  /// Restoring the launch window marks the session dirty. If that write landed before the sibling
  /// windows had opened and registered, the document would be rebuilt from the ONE live window and
  /// overwrite the file — silently deleting windows 2 and 3 on the very launch meant to restore them.
  func testSavesAreSuspendedWhileRestoring() {
    // A full session is on disk, as if written at the last quit.
    SessionStore(url: url).writeSynchronously(
      SessionFile(
        savedAt: Date(timeIntervalSince1970: 0),
        windows: [window(tabCount: 2, key: "W1"), window(tabCount: 2, key: "W2")]))

    let coordinator = makeCoordinator()
    coordinator.suspendSaves()
    // Only the first window exists so far — exactly the mid-restore state.
    captured = [window(tabCount: 2, key: "W1")]
    coordinator.markDirty()
    pump(0.3)

    XCTAssertEqual(
      readWindows()?.map(\.windowKey), ["W1", "W2"],
      "a save during restore must not truncate the windows that have not opened yet")

    // Once every window is back, the pending change writes.
    captured = [window(tabCount: 2, key: "W1"), window(tabCount: 2, key: "W2")]
    coordinator.resumeSaves()
    pump(0.3)
    XCTAssertEqual(readWindows()?.map(\.windowKey), ["W1", "W2"])
  }

  /// Nested suspensions (several windows restoring) must not resume early.
  func testNestedSuspensionsResumeOnlyWhenBalanced() {
    let coordinator = makeCoordinator()
    coordinator.suspendSaves()
    coordinator.suspendSaves()
    coordinator.markDirty()
    coordinator.resumeSaves()
    pump(0.2)
    XCTAssertNil(readWindows(), "still suspended by the outer claim")

    coordinator.resumeSaves()
    pump(0.3)
    XCTAssertNotNil(readWindows())
  }

  /// A flush while a restore is still in flight would replace a good file with a partial one.
  func testFlushWhileSuspendedWritesNothing() {
    SessionStore(url: url).writeSynchronously(
      SessionFile(
        savedAt: Date(timeIntervalSince1970: 0),
        windows: [window(tabCount: 2, key: "W1"), window(tabCount: 2, key: "W2")]))

    let coordinator = makeCoordinator()
    coordinator.suspendSaves()
    captured = [window(tabCount: 1, key: "W1")]
    coordinator.flushAndFreeze()

    XCTAssertEqual(readWindows()?.map(\.windowKey), ["W1", "W2"])
  }

  // MARK: Quit

  func testFlushWritesSynchronouslyAndThenFreezes() {
    let coordinator = makeCoordinator()
    captured = [window(tabCount: 2)]
    coordinator.flushAndFreeze()
    // No pumping: the quit path may not survive long enough for an async write.
    XCTAssertEqual(readWindows()?.first?.targets.first?.tabs.count, 2)

    // Windows close one by one during a quit, and the document is rebuilt from the LIVE windows —
    // without the freeze, the last window closing would overwrite what the flush just wrote.
    captured = []
    coordinator.markDirty()
    coordinator.writeIfChanged()
    pump(0.3)
    XCTAssertEqual(
      readWindows()?.first?.targets.first?.tabs.count, 2,
      "a frozen coordinator must not let window teardown erase the session")
  }

  /// The freeze is reached only past `applicationShouldTerminate`'s cancel guard, so a coordinator
  /// that was never told to quit keeps saving. (The placement itself is the fix for the cancelled-⌘Q
  /// bug; this pins the mechanism it relies on.)
  func testCoordinatorThatWasNeverFlushedKeepsSaving() {
    let coordinator = makeCoordinator()
    coordinator.writeIfChanged()
    pump(0.2)
    XCTAssertEqual(readWindows()?.first?.targets.first?.tabs.count, 1)

    captured = [window(tabCount: 4)]
    coordinator.markDirty()
    pump(0.3)
    XCTAssertEqual(readWindows()?.first?.targets.first?.tabs.count, 4)
  }

  // MARK: Newer schema

  /// A session written by a newer build is read-only: this build restores nothing and, critically,
  /// never overwrites it.
  func testNewerSchemaOnDiskStopsAllWrites() throws {
    SessionStore(url: url).writeSynchronously(
      SessionFile(
        schemaVersion: SessionFile.currentSchemaVersion + 1,
        savedAt: Date(timeIntervalSince1970: 0), windows: [window(tabCount: 9, key: "FUTURE")]))
    let before = try Data(contentsOf: url)

    let coordinator = makeCoordinator()
    XCTAssertEqual(coordinator.read(), .newerSchema)
    XCTAssertTrue(coordinator.writesDisabled)

    captured = [window(tabCount: 1)]
    coordinator.markDirty()
    coordinator.writeIfChanged()
    coordinator.flushAndFreeze()
    pump(0.3)
    XCTAssertEqual(try Data(contentsOf: url), before)
  }
}
