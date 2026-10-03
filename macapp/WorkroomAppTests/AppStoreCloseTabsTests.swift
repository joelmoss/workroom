import XCTest

@testable import Workroom

/// Bulk-close behavior for the tab toolbar / context menu / File menu (issue #72):
/// `requestCloseAllTerminalTabs` and `requestCloseOtherTerminalTabs`. Runs with the close-confirm
/// **off** so the synchronous teardown path is exercised without the AppKit modal (which isn't
/// unit-testable). One test keeps confirm **on** to prove a diff-only batch never prompts (a content
/// tab has no live process to lose), so it still closes synchronously here with no modal.
///
/// The confirm state is pinned per store (`confirmOnCloseOverrideForTesting`), never by writing
/// `Defaults[.confirmOnCloseTerminal]` — see that seam for why the shared key raced the other close
/// classes under parallel workers.
@MainActor
final class AppStoreCloseTabsTests: XCTestCase {
  private let target = TerminalTarget(id: "wr|/p|foo", title: "foo", path: "/tmp", isMissing: false)

  private func makeStore(confirmOnClose: Bool = false) -> AppStore {
    let store = AppStore()
    store.confirmOnCloseOverrideForTesting = confirmOnClose
    // Factory seam: a GhosttySurfaceView only spawns its PTY on entering a window, so this is inert.
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    return store
  }

  private func persistentDiff(_ path: String) -> DiffDescriptor {
    DiffDescriptor(path: path, change: .modified, source: .gitWorktree, isPreview: false)
  }

  func testCloseAllEmptiesTheTarget() {
    let store = makeStore()
    store.terminals.addTab(for: target)
    store.terminals.addTab(for: target)
    store.terminals.addTab(for: target)
    store.requestCloseAllTerminalTabs(for: target)
    XCTAssertTrue(store.terminals.tabs(for: target).isEmpty)
    XCTAssertNil(store.terminals.activeTab(for: target))
  }

  func testCloseOthersKeepsExactlyTheKeptTabAndSelectsIt() {
    let store = makeStore()
    store.terminals.addTab(for: target)
    let keep = store.terminals.addTab(for: target).id
    store.terminals.addTab(for: target)
    store.requestCloseOtherTerminalTabs(keep, for: target)
    XCTAssertEqual(store.terminals.tabs(for: target).map(\.id), [keep])
    XCTAssertEqual(store.terminals.activeTab(for: target)?.id, keep)  // focus lands on the kept tab
  }

  /// Close Others collapses a split down to the single kept survivor.
  func testCloseOthersCollapsesASplit() {
    let store = makeStore()
    store.terminals.addTab(for: target)
    let keep = store.terminals.activeTab(for: target)!.id
    store.terminals.splitFocusedPane(for: target, orientation: .horizontal)  // [keep, B]
    store.terminals.addTab(for: target)  // a third solo tab
    store.requestCloseOtherTerminalTabs(keep, for: target)
    XCTAssertEqual(store.terminals.tabs(for: target).map(\.id), [keep])
    XCTAssertNil(store.terminals.split(for: target))  // split dissolved with its members
  }

  func testCloseOthersWithSingleTabIsNoOp() {
    let store = makeStore()
    let only = store.terminals.addTab(for: target).id
    store.requestCloseOtherTerminalTabs(only, for: target)
    XCTAssertEqual(store.terminals.tabs(for: target).map(\.id), [only])
  }

  func testCloseAllOnEmptyTargetIsNoOp() {
    let store = makeStore()
    store.requestCloseAllTerminalTabs(for: target)  // no tabs → no crash, still empty
    XCTAssertTrue(store.terminals.tabs(for: target).isEmpty)
  }

  /// A batch of only diff/content tabs never prompts — even with confirm ON — because a content tab
  /// has no live process to lose, so the modal gate is skipped and it closes synchronously here.
  func testDiffOnlyBatchClosesWithoutPromptEvenWhenConfirmOn() {
    let store = makeStore(confirmOnClose: true)
    store.terminals.openDiffPersistent(persistentDiff("a.swift"), for: target)
    store.terminals.openDiffPersistent(persistentDiff("b.swift"), for: target)
    store.requestCloseAllTerminalTabs(for: target)
    XCTAssertTrue(store.terminals.tabs(for: target).isEmpty)
  }

  /// Value: protects=a closed remote pane whose host kept its session shows an alert naming the workroom, but not once a quit has begun; fails_when=AppStore drops the handler or ignores isTerminating; why_new=RemotePaneCloseTests stops at TerminalSessions.onRemoteCloseFailed; seam=none
  func testAFailedRemoteCloseAlertsUnlessTheAppIsQuitting() {
    let store = makeStore()
    store.terminals.onRemoteCloseFailed?("remote")
    XCTAssertEqual(store.errorTitle, "Couldn't stop the terminal in remote")
    XCTAssertTrue(store.errorMessage?.contains("may still be running") == true)

    store.errorTitle = nil
    store.errorMessage = nil
    WindowRegistry.shared.isTerminating = true
    defer { WindowRegistry.shared.isTerminating = false }
    store.terminals.onRemoteCloseFailed?("remote")
    XCTAssertNil(store.errorTitle, "a quit has stopped waiting; an alert would hold it up")
    XCTAssertNil(store.errorMessage)
  }

  /// Value: protects=a failed remote close never replaces an error already on screen, and is shown once that error is dismissed; fails_when=the notice overwrites errorMessage or the queue is not drained by clearError; why_new=the test above starts with no error showing; seam=none
  func testAFailedRemoteCloseWaitsBehindAnErrorAlreadyShowing() async throws {
    let store = makeStore()
    store.errorTitle = "Couldn't delete it"
    store.errorMessage = "The teardown failed."
    store.terminals.onRemoteCloseFailed?("first")
    store.terminals.onRemoteCloseFailed?("second")
    XCTAssertEqual(store.errorTitle, "Couldn't delete it", "the error being read is kept")
    XCTAssertEqual(store.errorMessage, "The teardown failed.")

    store.clearError()
    for _ in 0..<100 where store.errorTitle == nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(store.errorTitle, "Couldn't stop the terminal in first")
    XCTAssertTrue(store.errorMessage?.contains("Deleting the workroom stops it") == true)

    store.clearError()
    for _ in 0..<100 where store.errorTitle == nil { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(store.errorTitle, "Couldn't stop the terminal in second")

    store.clearError()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertNil(store.errorTitle, "the queue is empty")
  }
}
