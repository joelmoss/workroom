import AppKit
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// The inspector subject (#803, #804): the one window-scoped value the inspector's header and
/// sections read. A workroom or a project root with an open tab is the subject; no selection, a
/// selection with no open tab and the Quick Terminal are nothing; a standalone terminal follows its
/// folder (#805).
@MainActor
final class InspectorSubjectTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private let registry = WindowRegistry()
  private let root = SidebarID.root(project: "/p")
  private let workroom = SidebarID.workroom(project: "/p", name: "a")
  private let builtIn = SidebarID.terminalGroup(TargetID.quickTerminalGroupID)

  override func setUp() async throws {
    try await super.setUp()
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
  }

  /// A window over the shared project list and Terminals section, with isolated panes and a
  /// hidden inspector, so selecting reads no repository.
  private func makeStore() -> AppStore {
    let store = AppStore(
      projectStore: projects, terminalsSection: section, notifications: registry.notifications)
    store.services.notifier = SilentNotifier()
    store.confirmOnCloseOverrideForTesting = false
    store.inspectorVisibleOverrideForTesting = false
    isolate(store.terminals, service: retaggingService())
    return store
  }

  /// A session service with no helper, whose retag of a moved terminal succeeds.
  private func retaggingService() -> PersistentSessionService {
    PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { _, _ in true })
  }

  /// Open a terminal in `sid` and select it, without the selection's status probe.
  private func open(
    _ sid: SidebarID, in store: AppStore, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    store.terminals.addTab(for: try XCTUnwrap(store.target(for: sid), file: file, line: line))
    store.selectedTargetID = sid
    store.selectionStatusTask?.cancel()
  }

  // MARK: A workroom or a project

  /// Value: protects=a selected workroom with an open tab is what the inspector is about, exactly
  /// as its inspector target was; fails_when=the subject is nothing, another item, or disagrees
  /// with the sidebar item and target the sections act on; why_new=#804; seam=AppStore;
  /// no_claim=the sections' rendering
  func testASelectedWorkroomWithAnOpenTabIsTheSubject() throws {
    let store = makeStore()
    try open(workroom, in: store)

    XCTAssertEqual(store.inspectorSubject, .target(workroom))
    XCTAssertEqual(store.inspectorTargetID, workroom)
    XCTAssertEqual(store.inspectorTarget?.path, "/p/a")
  }

  /// Value: protects=a selected project root with an open tab is the subject; fails_when=the
  /// subject is nothing or another item; why_new=#804; seam=AppStore; no_claim=none
  func testASelectedProjectRootWithAnOpenTabIsTheSubject() throws {
    let store = makeStore()
    try open(root, in: store)

    XCTAssertEqual(store.inspectorSubject, .target(root))
    XCTAssertEqual(store.inspectorTargetID, root)
    XCTAssertEqual(store.inspectorTarget?.path, "/p")
  }

  // MARK: Nothing

  /// Value: protects=a window with no selection inspects nothing, at launch and once a selection
  /// is cleared; fails_when=a subject survives the selection; why_new=#804; seam=AppStore;
  /// no_claim=the empty states' copy
  func testNoSelectionIsNothing() throws {
    let store = makeStore()
    XCTAssertEqual(store.inspectorSubject, .nothing)

    try open(workroom, in: store)
    store.selectedTargetID = nil

    XCTAssertEqual(store.inspectorSubject, .nothing)
    XCTAssertNil(store.inspectorTargetID)
    XCTAssertNil(store.inspectorTarget)
  }

  /// Value: protects=the inspector empties with the selection's last tab and fills with its first;
  /// fails_when=a selected workroom with no open tab is the subject; why_new=#804; seam=AppStore;
  /// no_claim=History and the toolbar re-pointing (EmptiedWorkroomSelectionTests)
  func testASelectionWithNoOpenTabIsNothing() throws {
    let store = makeStore()
    store.selectedTargetID = workroom
    store.selectionStatusTask?.cancel()
    XCTAssertEqual(store.inspectorSubject, .nothing)

    store.newTerminalInSelectedTarget()

    XCTAssertEqual(store.inspectorSubject, .target(workroom))
  }

  /// Value: protects=a standalone terminal's first visit showing its folder at once, its repository
  /// pending, never "Select a workroom…" nor "Not a git repository" while git runs (review C1);
  /// fails_when=the subject is nothing until the first resolve lands, or the pending folder reads
  /// as one outside any repository; why_new=#803 code review; seam=AppStore over a resolve held
  /// open; no_claim=the panels' rendering of the pending state
  func testAStandaloneTerminalShowsItsFolderAtOnceWhileItsRepositoryResolves() async throws {
    let store = makeStore()
    let (held, release) = AsyncStream<Void>.makeStream()
    store.resolveFollowedRepository = { _ in
      for await _ in held { break }
      return .notARepository
    }

    store.newTerminalInSelectedTarget()

    let sid = try XCTUnwrap(store.selectedTargetID)
    XCTAssertTrue(sid.isStandaloneTerminal)
    guard case .followed(let pending) = store.inspectorSubject else {
      return XCTFail("subject is \(store.inspectorSubject), before the resolve lands")
    }
    XCTAssertEqual(pending.folder, store.followedTerminalFolder())
    XCTAssertFalse(pending.folder.isEmpty)
    XCTAssertTrue(pending.repositoryPending)
    XCTAssertNil(pending.repository)
    XCTAssertFalse(pending.isOutsideRepository, "pending is not \"Not a git repository\"")
    XCTAssertFalse(pending.repositoryUndetermined)
    XCTAssertNil(store.inspectorTargetID, "a followed folder is no sidebar item")

    release.finish()
    await store.followedFolderResolved()

    guard case .followed(let resolved) = store.inspectorSubject else {
      return XCTFail("subject is \(store.inspectorSubject)")
    }
    XCTAssertEqual(resolved.folder, pending.folder)
    XCTAssertFalse(resolved.repositoryPending)
    XCTAssertTrue(resolved.isOutsideRepository)
    let before = InspectorSubject.followed(pending)
    let after = InspectorSubject.followed(resolved)
    XCTAssertNotEqual(after.repositoryKey, before.repositoryKey, "the repository sections re-key")
    XCTAssertNotEqual(after.folderKey, before.folderKey, "and Files does, on the answer")
  }

  /// Value: protects=the Quick Terminal never feeds a window's inspector (stories 28–29): its row
  /// and its panel's terminals leave the subject where it was; fails_when=clicking its row, or a
  /// terminal opening in its panel, changes a window's subject; why_new=#804; seam=AppStore over
  /// the shared section, with the panel as the group's holder; no_claim=the panel sliding in
  func testTheQuickTerminalIsNothing() throws {
    let panel = makeQuickTerminalHost(
      notifications: registry.notifications, service: retaggingService(), section: section)
    panel.onReveal = { _ in }
    panel.terminals.addTab(for: panel.target)
    let store = makeStore()

    store.selectedTargetID = builtIn
    XCTAssertEqual(store.inspectorSubject, .nothing, "its row selects nothing to inspect")

    try open(workroom, in: store)
    store.selectedTargetID = builtIn
    store.revealQuickTerminal(newTerminal: true)

    XCTAssertEqual(panel.terminals.tabCount(forTargetID: .quickTerminal), 2)
    XCTAssertEqual(store.inspectorSubject, .target(workroom), "the window keeps its own subject")
  }

  // MARK: One per window

  /// Value: protects=each window's subject comes from its own selection (story 30); fails_when=one
  /// window's selection reaches another's subject; why_new=#804; seam=two AppStores over one
  /// project list; no_claim=none
  func testEachWindowHasItsOwnSubject() throws {
    let first = makeStore()
    let second = makeStore()
    try open(workroom, in: first)
    try open(root, in: second)

    XCTAssertEqual(first.inspectorSubject, .target(workroom))
    XCTAssertEqual(second.inspectorSubject, .target(root))

    second.selectedTargetID = nil
    XCTAssertEqual(first.inspectorSubject, .target(workroom))
    XCTAssertEqual(second.inspectorSubject, .nothing)
  }

  // MARK: Something to inspect

  /// Value: protects=a selected workroom or project root can be inspected, even before its first
  /// tab opens, so the activity bar and the View menu's inspector items stay as they were for
  /// workrooms; fails_when=either reads as nothing to inspect; why_new=#803 activity bar;
  /// seam=AppStore.selectionIsInspectable; no_claim=what the panes show
  func testAWorkroomOrAProjectCanBeInspected() throws {
    let store = makeStore()
    store.selectedTargetID = workroom
    store.selectionStatusTask?.cancel()
    XCTAssertTrue(store.selectionIsInspectable, "a workroom with no tab yet")

    try open(root, in: store)
    XCTAssertTrue(store.selectionIsInspectable, "a project root")
  }

  /// Value: protects=a window with no projects, only a standalone terminal or a terminal group,
  /// can open the inspector, which follows that terminal's folder; fails_when=a terminal row reads
  /// as nothing to inspect because the app has no project; why_new=#803 activity bar;
  /// seam=AppStore.selectionIsInspectable; no_claim=the folder it follows
  func testATerminalWithNoProjectsCanBeInspected() throws {
    projects.projects = []
    let store = makeStore()
    store.newTerminalInSelectedTarget()
    XCTAssertTrue(try XCTUnwrap(store.selectedTargetID).isStandaloneTerminal)
    XCTAssertTrue(store.selectionIsInspectable, "a standalone terminal")

    let group = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))
    guard case .terminalGroup = group else { return XCTFail("\(group) is not a terminal group") }
    XCTAssertEqual(store.selectedTargetID, group)
    XCTAssertTrue(store.selectionIsInspectable, "a terminal group")
  }

  /// Value: protects=no selection and the Quick Terminal's row leave nothing to inspect, so the
  /// activity bar hides its panes and the View menu's inspector items disable; fails_when=either
  /// can be inspected; why_new=#803 activity bar; seam=AppStore.selectionIsInspectable;
  /// no_claim=the Quick Terminal panel
  func testNoSelectionOrTheQuickTerminalCannotBeInspected() throws {
    // The panel holds the group, so selecting its row opens no terminal of the window's own.
    let panel = makeQuickTerminalHost(
      notifications: registry.notifications, service: retaggingService(), section: section)
    panel.onReveal = { _ in }
    let store = makeStore()
    XCTAssertFalse(store.selectionIsInspectable, "no selection")

    store.selectedTargetID = builtIn
    XCTAssertFalse(store.selectionIsInspectable, "the Quick Terminal's row")
  }

  // MARK: Status

  /// Value: protects=Changes and Pull Request find a workroom's existing status through the
  /// subject; fails_when=the subject's lookup misses the workroom's status, or answers for
  /// nothing or for a project's header row; why_new=#804; seam=VCSStatusService.status(for:);
  /// no_claim=a followed folder's status (#807)
  func testStatusIsLookedUpThroughTheSubject() throws {
    let store = makeStore()
    let pr = PullRequestInfo(
      number: 12, title: "A change", state: .open, isDraft: false,
      url: "https://github.com/example/repo/pull/12", reviewDecision: nil, reviewers: [])
    var seeded = WorkroomStatus(dirty: true)
    seeded.pr = pr
    store.vcsStatus.workroomStatuses[workroom] = seeded
    store.vcsStatus.workroomStatuses[.project("/p")] = WorkroomStatus(dirty: true)
    XCTAssertNil(store.vcsStatus.status(for: store.inspectorSubject), "nothing has no status")

    try open(workroom, in: store)

    XCTAssertEqual(store.vcsStatus.status(for: store.inspectorSubject), seeded)
    XCTAssertNil(
      store.vcsStatus.status(for: .target(.project("/p"))),
      "a project's header row is no working copy")
  }
}
