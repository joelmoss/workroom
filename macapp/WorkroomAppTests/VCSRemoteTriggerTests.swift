import Defaults
import XCTest

@testable import Workroom

/// The visibility gates in front of the VCS toolbar's reads.
///
/// A `focus` here is not a cheap pointer move — it spawns two or three `git`/`jj` processes. Without
/// these gates every selection change would read a repo for a toolbar nobody can see, which is the
/// shape of the recorded `history-eager-focus-is-a-full-vcs-read` starvation. And now that the toolbar
/// auto-fetches, an ungated trigger would mean automatic *network* calls behind a closed inspector.
///
/// Observed the way `HistoryLiveRefreshTests` observes History: a real model injected with a counting
/// writer, so "did a read fire?" is a call count rather than a mock expectation.
///
/// All three halves of the gate are pinned **per store** — `inspectorVisibleOverrideForTesting`,
/// `isolatesInspectorSectionForTesting`, `isolatesInspectorLayoutForTesting` — never by writing the
/// shared inspector settings: `-parallel-testing` workers share one UserDefaults domain, so writing
/// the real keys would leak this class's state into whatever runs beside it.
@MainActor
final class VCSRemoteTriggerTests: XCTestCase {

  /// This class drives real action completions for project root `/p`, and a successful `.fetch`/`.pull`
  /// makes `recordOwnFetch` write `Defaults[.vcsLastFetch]["/p"]` — a PERSISTED dictionary in the standard
  /// suite. `RemoteStateModelTests` asserts never-fetched preconditions against the same `/p`, so leaving
  /// the stamp behind defeats them from another `-parallel-testing` worker. Reset both sides.
  override func setUp() {
    super.setUp()
    Defaults.reset(.vcsLastFetch)
  }

  override func tearDown() {
    super.tearDown()
    Defaults.reset(.vcsLastFetch)
  }

  private func makeStore(visible: Bool, section: ActivitySection) -> (AppStore, CountingWriter) {
    let writer = CountingWriter()
    let model = RemoteStateModel(makeWriter: { _ in writer }, debounce: 0, ttl: 0)
    let store = AppStore(remoteState: model)
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    store.inspectorVisibleOverrideForTesting = visible
    store.isolatesInspectorSectionForTesting = true
    store.isolatesInspectorLayoutForTesting = true
    store.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "feat", path: "/p/feat", vcsName: "workroom/feat", warnings: [])]
      )
    ]
    store.activeInspectorSection = section
    return (store, writer)
  }

  /// Select a workroom, optionally giving it an open tab first — the inspector (and so the toolbar)
  /// keys on `inspectorTargetID`, which is nil until the selection has tabs.
  private func select(_ store: AppStore, _ sid: SidebarID, hasTabs: Bool = true) async {
    if hasTabs, let target = store.target(for: sid) { store.terminals.addTab(for: target) }
    store.selectedTargetID = sid
    await store.remoteState.awaitCurrentLoad()
  }

  // MARK: remoteToolbarShown

  /// The toolbar sits ABOVE the section stack rather than inside a section, so only the activity
  /// section matters — a collapsed Changes section still shows the toolbar.
  func testToolbarIsShownForTheChangesSectionOnly() {
    let (changes, _) = makeStore(visible: true, section: .changes)
    XCTAssertTrue(changes.remoteToolbarShown)
    let (files, _) = makeStore(visible: true, section: .files)
    XCTAssertFalse(files.remoteToolbarShown)
  }

  func testCollapsingTheChangesSectionStillShowsTheToolbar() {
    let (store, _) = makeStore(visible: true, section: .changes)
    store.changesSectionCollapsed = true
    XCTAssertTrue(
      store.remoteToolbarShown, "the toolbar is above the stack, not inside the section")
  }

  // MARK: Selection

  func testSelectingAWorkroomReadsWhenVisible() async {
    let (store, writer) = makeStore(visible: true, section: .changes)
    await select(store, .workroom(project: "/p", name: "feat"))
    let reads = await writer.stateReads
    XCTAssertEqual(reads, 1)
  }

  func testSelectingReadsNothingWhenTheInspectorIsClosed() async {
    let (store, writer) = makeStore(visible: false, section: .changes)
    await select(store, .workroom(project: "/p", name: "feat"))
    let reads = await writer.stateReads
    XCTAssertEqual(reads, 0, "no VCS processes for a toolbar nobody can see")
  }

  func testSelectingReadsNothingOnTheFilesSection() async {
    let (store, writer) = makeStore(visible: true, section: .files)
    await select(store, .workroom(project: "/p", name: "feat"))
    let reads = await writer.stateReads
    XCTAssertEqual(reads, 0)
  }

  /// The inspector empties when the selection has no open tabs, so the toolbar must too.
  func testNoReadWithoutOpenTabs() async {
    let (store, writer) = makeStore(visible: true, section: .changes)
    await select(store, .workroom(project: "/p", name: "feat"), hasTabs: false)
    let reads = await writer.stateReads
    XCTAssertEqual(reads, 0)
  }

  // MARK: The metadata-watcher hook

  func testMetadataChangeRefreshesWhenVisibleAndTargeted() async {
    let (store, writer) = makeStore(visible: true, section: .changes)
    await select(store, .workroom(project: "/p", name: "feat"))
    let before = await writer.stateReads
    store.handleRootBranchChange(projectID: "/p")
    await store.remoteState.awaitCurrentLoad()
    let after = await writer.stateReads
    XCTAssertEqual(after, before + 1, "a ref write in this project must repaint the toolbar")
  }

  func testMetadataChangeIsIgnoredWhenTheInspectorIsClosed() async {
    let (store, writer) = makeStore(visible: false, section: .changes)
    await select(store, .workroom(project: "/p", name: "feat"))
    store.handleRootBranchChange(projectID: "/p")
    await store.remoteState.awaitCurrentLoad()
    let reads = await writer.stateReads
    XCTAssertEqual(reads, 0)
  }

  /// A write under another project's `.git` says nothing about this workroom.
  func testMetadataChangeForAnotherProjectIsIgnored() async {
    let (store, writer) = makeStore(visible: true, section: .changes)
    store.projects.append(Project(path: "/other", vcs: "git", workrooms: []))
    await select(store, .workroom(project: "/p", name: "feat"))
    let before = await writer.stateReads
    store.handleRootBranchChange(projectID: "/other")
    await store.remoteState.awaitCurrentLoad()
    let after = await writer.stateReads
    XCTAssertEqual(after, before)
  }

  // MARK: App refocus

  func testRefocusRefreshesAndChecksAutoFetch() async {
    let (store, writer) = makeStore(visible: true, section: .changes)
    await select(store, .workroom(project: "/p", name: "feat"))
    let before = await writer.stateReads
    store.refreshRemoteStateIfActive()
    await store.remoteState.awaitCurrentLoad()
    let after = await writer.stateReads
    let fetches = await writer.fetches
    // Two extra reads, not one: the forced refresh, then the auto-fetch's own post-mutation refresh
    // (a fetch that succeeds re-reads so the new counts and timestamp land immediately).
    XCTAssertGreaterThan(after, before, "refocus must re-read")
    XCTAssertEqual(fetches, 1, "a teammate's push while backgrounded is why auto-fetch exists")
  }

  /// The gate is what stops a closed inspector making automatic network calls.
  func testRefocusDoesNothingWhenHidden() async {
    let (store, writer) = makeStore(visible: false, section: .changes)
    await select(store, .workroom(project: "/p", name: "feat"))
    store.refreshRemoteStateIfActive()
    await store.remoteState.awaitCurrentLoad()
    let reads = await writer.stateReads
    let fetches = await writer.fetches
    XCTAssertEqual(reads, 0)
    XCTAssertEqual(fetches, 0, "no automatic network calls behind a closed inspector")
  }

  // MARK: remoteTarget

  func testTargetResolvesAWorkroomWithItsProjectRoot() {
    let (store, _) = makeStore(visible: true, section: .changes)
    if let target = store.target(for: .workroom(project: "/p", name: "feat")) {
      store.terminals.addTab(for: target)
    }
    store.selectedTargetID = .workroom(project: "/p", name: "feat")
    let target = store.remoteTarget()
    XCTAssertEqual(target?.path, "/p/feat")
    XCTAssertEqual(target?.projectRoot, "/p", "fetch runs here, not in the workroom")
    XCTAssertEqual(target?.vcs, "git")
  }

  func testTargetResolvesAProjectRoot() {
    let (store, _) = makeStore(visible: true, section: .changes)
    if let target = store.target(for: .root(project: "/p")) { store.terminals.addTab(for: target) }
    store.selectedTargetID = .root(project: "/p")
    XCTAssertEqual(store.remoteTarget()?.path, "/p")
  }

  /// A `.project` row is the collapsible header, not a working copy.
  func testProjectRowIsNotStatusable() {
    let (store, _) = makeStore(visible: true, section: .changes)
    if let target = store.target(for: .project("/p")) { store.terminals.addTab(for: target) }
    store.selectedTargetID = .project("/p")
    XCTAssertNil(store.remoteTarget())
  }

  func testTargetIsNilForAVanishedWorkroom() {
    let (store, _) = makeStore(visible: true, section: .changes)
    if let target = store.target(for: .workroom(project: "/p", name: "gone")) {
      store.terminals.addTab(for: target)
    }
    store.selectedTargetID = .workroom(project: "/p", name: "gone")
    XCTAssertNil(store.remoteTarget())
  }

  // MARK: The dirty-tree confirmation gate

  private func markDirty(_ store: AppStore, _ sid: SidebarID) {
    store.workroomStatuses[sid] = WorkroomStatus(dirty: true, lastChecked: Date())
  }

  /// **The gate must live in the STORE, not the toolbar.** It used to sit in `VCSToolbar.perform`, so the
  /// Source Control menu's ⌥⇧⌘P — which calls `performRemoteAction` directly — autostashed a dirty tree
  /// with no warning while the button warned. This asserts the gate from the store's own entry point,
  /// which is the one the menu uses.
  func testPullOverADirtyTreeRaisesAConfirmationInsteadOfActing() async {
    let (store, writer) = makeStore(visible: true, section: .changes)
    let sid = SidebarID.workroom(project: "/p", name: "feat")
    await select(store, sid)
    markDirty(store, sid)

    store.performRemoteAction(.pull)
    await store.remoteState.awaitCurrentLoad()

    XCTAssertEqual(store.pendingRemoteConfirm?.action, .pull)
    XCTAssertEqual(store.pendingRemoteConfirm?.sid, sid)
    XCTAssertNil(store.remoteState.inFlight, "nothing may run until the user answers")
    let pulls = await writer.pulls
    XCTAssertEqual(pulls, 0, "the engine must not be reached before confirmation")
  }

  /// A clean tree has nothing to stash, so the confirmation would be a speed bump.
  func testPullOverACleanTreeActsWithoutConfirming() async {
    let (store, writer) = makeStore(visible: true, section: .changes)
    let sid = SidebarID.workroom(project: "/p", name: "feat")
    await select(store, sid)
    store.workroomStatuses[sid] = WorkroomStatus(dirty: false, lastChecked: Date())

    store.performRemoteAction(.pull)
    await store.remoteState.awaitCurrentLoad()

    XCTAssertNil(store.pendingRemoteConfirm)
    let pulls = await writer.pulls
    XCTAssertEqual(pulls, 1)
  }

  /// The confirmation isn't modal to the sidebar, so the selection can move while it's open. Confirming
  /// then must NOT silently redirect the pull onto whatever is selected now — the dirty-tree warning was
  /// about a specific workroom.
  func testAConfirmedPullIsRejectedIfTheSelectionMoved() async {
    let (store, writer) = makeStore(visible: true, section: .changes)
    store.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [
          Workroom(name: "feat", path: "/p/feat", vcsName: "workroom/feat", warnings: []),
          Workroom(name: "other", path: "/p/other", vcsName: "workroom/other", warnings: []),
        ])
    ]
    let first = SidebarID.workroom(project: "/p", name: "feat")
    let second = SidebarID.workroom(project: "/p", name: "other")
    await select(store, first)
    markDirty(store, first)
    store.performRemoteAction(.pull)
    let pending = try? XCTUnwrap(store.pendingRemoteConfirm)
    XCTAssertEqual(pending?.sid, first)

    await select(store, second)
    // Answer the dialog that was raised for `first` while `second` is selected.
    store.runRemoteAction(.pull, on: first)
    await store.remoteState.awaitCurrentLoad()

    let pulls = await writer.pulls
    XCTAssertEqual(pulls, 0, "a pull confirmed for one workroom must not run against another")
  }

  /// And the stale dialog is dismissed rather than left asking about a workroom nobody is looking at.
  func testChangingSelectionDismissesAPendingConfirmation() async {
    let (store, _) = makeStore(visible: true, section: .changes)
    store.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [
          Workroom(name: "feat", path: "/p/feat", vcsName: "workroom/feat", warnings: []),
          Workroom(name: "other", path: "/p/other", vcsName: "workroom/other", warnings: []),
        ])
    ]
    let first = SidebarID.workroom(project: "/p", name: "feat")
    await select(store, first)
    markDirty(store, first)
    store.performRemoteAction(.pull)
    XCTAssertNotNil(store.pendingRemoteConfirm)

    await select(store, .workroom(project: "/p", name: "other"))
    XCTAssertNil(store.pendingRemoteConfirm)
  }

  /// A confirmation up means the Source Control shortcuts must be inert, or ⌥⇧⌘P could queue a second
  /// pull behind the dialog asking about the first.
  func testAPendingConfirmationCountsAsAModalPresentation() async {
    let (store, _) = makeStore(visible: true, section: .changes)
    let sid = SidebarID.workroom(project: "/p", name: "feat")
    await select(store, sid)
    markDirty(store, sid)
    XCTAssertFalse(store.hasModalPresentation)
    store.performRemoteAction(.pull)
    XCTAssertTrue(store.hasModalPresentation)
  }
}

/// Counts reads and actions. Returns a usable snapshot so the model reaches `.loaded` and its derived
/// enablement (which auto-fetch depends on) is true.
private actor CountingWriter: VCSWriting {
  private(set) var stateReads = 0
  private(set) var fetches = 0
  private(set) var pulls = 0

  func remoteState(path: String, projectRoot: String) async -> VCSRemoteResolution {
    stateReads += 1
    return .state(
      VCSRemoteState(
        current: VCSRef(name: "main", kind: .branch),
        tracking: VCSTracking(comparedTo: "origin/main", ahead: 0, behind: 0, gone: false),
        remotes: ["origin"], primaryRemote: "origin", lastFetch: .never, resolvedAt: Date()))
  }

  func fetch(path: String, projectRoot: String, remote: String) async -> VCSRemoteActionResult {
    fetches += 1
    return .ok(summary: "fetched")
  }

  func push(
    path: String, projectRoot: String, current: VCSRef, remote: String, setUpstream: Bool,
    anonymousRevision: String
  ) async -> VCSRemoteActionResult { .ok(summary: "") }

  func pullRebase(
    path: String, projectRoot: String, current: VCSRef, remote: String, tracking: VCSTracking?
  ) async -> VCSRemoteActionResult {
    pulls += 1
    return .ok(summary: "")
  }

  func abortRebase(path: String, projectRoot: String) async -> VCSRemoteActionResult {
    .ok(summary: "")
  }

  func commit(path: String, projectRoot: String, request: VCSCommitRequest) async
    -> VCSCommitResult
  {
    .ok(summary: "", revision: nil)
  }
}
