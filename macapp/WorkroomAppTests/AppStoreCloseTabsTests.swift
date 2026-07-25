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
}
