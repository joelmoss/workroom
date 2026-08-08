import AppKit
import XCTest

@testable import Workroom

/// Which window adopts which saved session (issue #46, multi-window restore).
///
/// This is the part of the feature with no visible symptom when it goes subtly wrong: a window
/// silently adopts the wrong session's panels, two windows race for one, or a key is handed out twice
/// and the same window opens again. The claim logic is pure and main-actor, so the whole matrix is
/// cheap unit tests — which is exactly why it should be covered here rather than left to an
/// end-to-end test that can only see the happy path.
@MainActor
final class SessionClaimTests: XCTestCase {
  private var directory: URL!
  private var url: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-claim-\(UUID().uuidString)", isDirectory: true)
    url = directory.appendingPathComponent("session.json")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func window(key: UUID, isKey: Bool = false, selected: String? = nil) -> WindowSession {
    WindowSession(
      windowKey: key.uuidString, isKey: isKey, selectedTargetID: selected,
      targets: [
        TargetSession(
          targetID: selected ?? "wr|/p|foo",
          tabs: [
            TabSession(
              key: "t0", kind: TabSession.terminalKind,
              terminal: TerminalPayload(defaultTitle: "Terminal 1", cwd: nil))
          ])
      ])
  }

  /// A store whose session file holds `windows`, with saving driven by an injected coordinator.
  private func makeProjectStore(windows: [WindowSession]) -> ProjectStore {
    if !windows.isEmpty {
      SessionStore(url: url).writeSynchronously(
        SessionFile(savedAt: Date(timeIntervalSince1970: 0), windows: windows))
    }
    let store = ProjectStore()
    store.sessionCoordinator = SessionCoordinator(
      store: SessionStore(url: url), debounce: 0.05, ceiling: 0.2, capture: { [] })
    return store
  }

  // MARK: The matrix

  /// The launch window's seed id is freshly minted every launch, so it cannot match anything on disk
  /// — it adopts the first saved window and takes that window's key as its own.
  func testLaunchWindowAdoptsTheFirstSavedWindow() throws {
    let first = UUID()
    let second = UUID()
    let store = makeProjectStore(windows: [window(key: first), window(key: second)])

    let claimed = try XCTUnwrap(store.claimSession(for: UUID(), isLaunchWindow: true))
    XCTAssertEqual(claimed.windowKey, first.uuidString)
  }

  /// A sibling was opened FOR a key and must claim exactly that one — never another window's panels.
  func testSiblingClaimsItsOwnKey() throws {
    let first = UUID()
    let second = UUID()
    let store = makeProjectStore(windows: [window(key: first), window(key: second)])

    _ = store.claimSession(for: UUID(), isLaunchWindow: true)
    let claimed = try XCTUnwrap(store.claimSession(for: second, isLaunchWindow: false))
    XCTAssertEqual(claimed.windowKey, second.uuidString)
  }

  func testSiblingWithAnUnknownKeyClaimsNothing() {
    let store = makeProjectStore(windows: [window(key: UUID())])
    XCTAssertNil(store.claimSession(for: UUID(), isLaunchWindow: false))
  }

  /// `WindowAccessor` can resolve the same window more than once, and a repeat claim must return the
  /// SAME session rather than consume a second one.
  func testRepeatClaimIsIdempotent() throws {
    let first = UUID()
    let second = UUID()
    let store = makeProjectStore(windows: [window(key: first), window(key: second)])

    let once = try XCTUnwrap(store.claimSession(for: UUID(), isLaunchWindow: true))
    let twice = try XCTUnwrap(store.claimSession(for: first, isLaunchWindow: true))
    XCTAssertEqual(once.windowKey, twice.windowKey)
    // The second window is still up for grabs — the repeat claim consumed nothing.
    XCTAssertEqual(store.pendingSessionKeys(), [second])
  }

  /// A `.task` re-fire must not open a second copy of the same window.
  func testPendingKeysAreHandedOutOnlyOnce() {
    let first = UUID()
    let second = UUID()
    let third = UUID()
    let store = makeProjectStore(
      windows: [window(key: first), window(key: second), window(key: third)])

    _ = store.claimSession(for: UUID(), isLaunchWindow: true)
    XCTAssertEqual(Set(store.pendingSessionKeys()), [second, third])
    XCTAssertTrue(store.pendingSessionKeys().isEmpty, "a second call hands out nothing")
  }

  func testNoSessionMeansNothingToClaimOrDispatch() {
    let store = makeProjectStore(windows: [])
    XCTAssertNil(store.claimSession(for: UUID(), isLaunchWindow: true))
    XCTAssertTrue(store.pendingSessionKeys().isEmpty)
    XCTAssertFalse(store.sessionCoordinator.isSuspended)
  }

  // MARK: The save gate across several windows

  /// Saving stays suspended until EVERY window has finished — the whole point of the gate. Resuming
  /// after the first would let it write a document rebuilt from the windows that exist so far.
  func testSavingResumesOnlyWhenEveryWindowHasFinished() {
    let first = UUID()
    let second = UUID()
    let store = makeProjectStore(windows: [window(key: first), window(key: second)])
    let coordinator = store.sessionCoordinator

    _ = store.claimSession(for: UUID(), isLaunchWindow: true)
    XCTAssertTrue(coordinator.isSuspended)
    _ = store.pendingSessionKeys()
    _ = store.claimSession(for: second, isLaunchWindow: false)

    store.finishSessionRestore()
    XCTAssertTrue(coordinator.isSuspended, "one window is still restoring")

    store.finishSessionRestore()
    XCTAssertFalse(coordinator.isSuspended)
  }

  /// A dispatched window that never opens must not leave saving suspended for the rest of the run —
  /// the app would silently stop persisting anything.
  func testSavingStaysSuspendedWhileAWindowIsStillAwaited() {
    let first = UUID()
    let second = UUID()
    let store = makeProjectStore(windows: [window(key: first), window(key: second)])

    _ = store.claimSession(for: UUID(), isLaunchWindow: true)
    _ = store.pendingSessionKeys()

    // The launch window finishes, but window two was dispatched and has not claimed.
    store.finishSessionRestore()
    XCTAssertTrue(
      store.sessionCoordinator.isSuspended,
      "still awaiting a dispatched window — the watchdog is what releases this")
  }

  /// **REGRESSION.** The launch window finishes its own restore inside `bootstrap`, which returns
  /// BEFORE `pendingSessionKeys` has handed anything out. Ending the restore at that moment cleared
  /// the windows still on disk, so the fan-out found nothing to open and only one window came back —
  /// the bug the two-window XCUITest caught.
  func testLaunchWindowFinishingDoesNotDiscardUnclaimedWindows() throws {
    let first = UUID()
    let second = UUID()
    let store = makeProjectStore(windows: [window(key: first), window(key: second)])

    _ = store.claimSession(for: UUID(), isLaunchWindow: true)
    // Exactly the real order: the launch window finishes before anything is dispatched.
    store.finishSessionRestore()

    XCTAssertEqual(
      store.pendingSessionKeys(), [second],
      "the second window must still be there to open")
    XCTAssertTrue(
      store.sessionCoordinator.isSuspended, "and saving must stay suspended until it lands")

    let claimed = try XCTUnwrap(store.claimSession(for: second, isLaunchWindow: false))
    XCTAssertEqual(claimed.windowKey, second.uuidString)
    store.finishSessionRestore()
    XCTAssertFalse(store.sessionCoordinator.isSuspended)
  }

  /// Every window claimed, so nothing is awaited and saving resumes immediately.
  func testSingleWindowSessionResumesAfterItsOwnRestore() {
    let store = makeProjectStore(windows: [window(key: UUID())])
    _ = store.claimSession(for: UUID(), isLaunchWindow: true)
    XCTAssertTrue(store.pendingSessionKeys().isEmpty)
    store.finishSessionRestore()
    XCTAssertFalse(store.sessionCoordinator.isSuspended)
  }

  // MARK: What's New

  /// Sibling windows carry `restore: true` so they can claim, so gating the What's-New auto-check on
  /// that would pop the dialog once per restored window. `isLaunch` is what separates them.
  func testOnlyTheLaunchSeedIsMarkedAsTheLaunchWindow() {
    XCTAssertTrue(WindowSeed.launch.isLaunch)
    XCTAssertTrue(WindowSeed.launch.restore)

    let sibling = WindowSeed.restoring(key: UUID())
    XCTAssertFalse(sibling.isLaunch, "a restored sibling must not run the What's-New check")
    XCTAssertTrue(sibling.restore, "but it must still be allowed to claim its session")

    let newWindow = WindowSeed(id: UUID(), restore: false)
    XCTAssertFalse(newWindow.isLaunch)
    XCTAssertFalse(newWindow.restore, "⌘N always opens blank")
  }

  /// A sibling is opened keyed on the session it will claim, so the two cannot drift apart.
  func testRestoringSeedCarriesTheSessionKey() {
    let key = UUID()
    XCTAssertEqual(WindowSeed.restoring(key: key).id, key)
  }
}
