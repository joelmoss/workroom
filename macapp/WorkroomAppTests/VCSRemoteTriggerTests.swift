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
}

/// Counts reads and actions. Returns a usable snapshot so the model reaches `.loaded` and its derived
/// enablement (which auto-fetch depends on) is true.
private actor CountingWriter: VCSWriting {
  private(set) var stateReads = 0
  private(set) var fetches = 0

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
  ) async -> VCSRemoteActionResult { .ok(summary: "") }

  func abortRebase(path: String, projectRoot: String) async -> VCSRemoteActionResult {
    .ok(summary: "")
  }
}
