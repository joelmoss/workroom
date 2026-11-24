import Synchronization
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// A terminal group's inspector follows its focused terminal (#806, ADR 0081): the subject is that
/// terminal's folder and repository, a focus move to another repository switches it, and a split,
/// a move out or a dissolve leaves it on the window's new selection. Real throwaway repositories on
/// disk; folders arrive through each surface's pwd handler, as a shell's report does.
@MainActor
final class TerminalGroupFollowsFocusTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private var scratch: URL!

  override func setUp() async throws {
    try await super.setUp()
    try XCTSkipIf(
      sh("command -v git", in: NSTemporaryDirectory()).exit != 0, "git is not installed")
    // Canonical (`/private/var/...`), as git names a repository's root.
    let made = FileManager.default.temporaryDirectory
      .appendingPathComponent("group-follows-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
    let canonical = try XCTUnwrap(realpath(made.path, nil))
    defer { free(canonical) }
    scratch = URL(fileURLWithPath: String(cString: canonical))
  }

  override func tearDown() async throws {
    if let scratch { try? FileManager.default.removeItem(at: scratch) }
    try await super.tearDown()
  }

  // MARK: Store

  private final class CountingProvider: LocalVCSProviding, Sendable {
    private let roots = Mutex<[String]>([])
    /// The roots History read a log of, in order.
    var logRoots: [String] { roots.withLock { $0 } }
    func log(root: URL, limit: Int) throws -> VCSHistoryPage {
      roots.withLock { $0.append(root.path) }
      return VCSHistoryPage(commits: [], reachedEnd: true)
    }
    func changeset(root: URL, commitID: String) async throws -> VCSChangeset {
      throw VCSError.io("x")
    }
    func fileDiff(root: URL, commitID: String, path: String) async throws -> String {
      throw VCSError.io("x")
    }
    func workingFileDiff(root: URL, path: String) async throws -> String { throw VCSError.io("x") }
    func fileContent(root: URL, rev: String, path: String) async throws -> String? { nil }
    func currentRef(root: URL) async throws -> VCSRef { .none }
  }

  private let provider = CountingProvider()

  /// A window store with History showing, its log read through `provider`.
  private func makeStore() -> AppStore {
    let store = AppStore(
      projectStore: projects, terminalsSection: section,
      commitHistory: HistoryModel(resolve: { [provider] _ in provider }))
    store.confirmOnCloseOverrideForTesting = false
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.terminals.recordUnrecognizedTool = { _ in }
    store.terminals.recency = SwitcherRecency()
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "isolated") }, ownership: { _ in .notOwned },
      retag: { _, _ in true })
    store.inspectorVisibleOverrideForTesting = true
    store.isolatesInspectorSectionForTesting = true
    store.isolatesInspectorLayoutForTesting = true
    store.activeInspectorSection = .changes
    store.historySectionCollapsed = false
    return store
  }

  /// A named group in `store` with two terminals, the second focused, and its target.
  private func groupOfTwo(_ store: AppStore) async throws -> (
    TerminalTarget, TerminalTab, TerminalTab
  ) {
    let sid = try XCTUnwrap(store.newTerminalGroup(named: "Ops"))
    guard case .terminalGroup = sid else { throw XCTSkip("\(sid) is not a terminal group") }
    store.newTerminalInSelectedTarget()
    let target = try XCTUnwrap(store.target(for: sid))
    let tabs = store.terminals.tabs(for: target)
    XCTAssertEqual(tabs.count, 2)
    await settle(store)
    return (target, tabs[0], tabs[1])
  }

  /// The shell in `tab` reports `folder` (OSC 7); wait for the subject and History to settle.
  private func cd(_ store: AppStore, _ tab: TerminalTab, _ folder: String) async throws {
    try XCTUnwrap(store.terminals.surface(tab)).handlePwd(folder)
    await settle(store)
  }

  private func settle(_ store: AppStore) async {
    await section.regroupsSettled()
    await store.followedFolderResolved()
    await store.commitHistory.awaitCurrentLoad()
  }

  private func followed(
    _ store: AppStore, file: StaticString = #filePath, line: UInt = #line
  ) -> FollowedFolder? {
    guard case .followed(let followed) = store.inspectorSubject else {
      XCTFail("subject is \(store.inspectorSubject)", file: file, line: line)
      return nil
    }
    return followed
  }

  // MARK: Repositories on disk

  @discardableResult
  private func sh(_ cmd: String, in dir: String) -> (out: String, exit: Int32) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", cmd]
    p.currentDirectoryURL = URL(fileURLWithPath: dir)
    var env = ProcessInfo.processInfo.environment
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_SYSTEM"] = "/dev/null"
    env["GIT_AUTHOR_NAME"] = "T"
    env["GIT_AUTHOR_EMAIL"] = "t@e.com"
    env["GIT_COMMITTER_NAME"] = "T"
    env["GIT_COMMITTER_EMAIL"] = "t@e.com"
    env["PATH"] = ShellEnvironment.path()
    p.environment = env
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
  }

  /// A git repository with one commit, and a `src` folder inside it.
  private func repo(_ name: String) -> String {
    let dir = scratch.appendingPathComponent(name).path
    try? FileManager.default.createDirectory(
      atPath: dir + "/src", withIntermediateDirectories: true)
    sh("git init -q -b main .", in: dir)
    try? "x\n".write(toFile: dir + "/src/a.txt", atomically: true, encoding: .utf8)
    sh("git add -A && git commit -qm base", in: dir)
    return dir
  }

  // MARK: Following focus

  /// Value: protects=a group's inspector following its focused terminal, across repositories and
  /// within one (stories 5, 6); fails_when=a group still has nothing to inspect, a focus move to
  /// another repository keeps the old one, a same-repository move re-reads History, or a cd in an
  /// unfocused terminal moves the subject; why_new=#806; seam=AppStore + HistoryModel;
  /// no_claim=Changes and Pull Request (#807)
  func testAGroupFollowsItsFocusedTerminalAcrossRepositories() async throws {
    let store = makeStore()
    let (target, first, second) = try await groupOfTwo(store)
    let one = repo("one")
    let two = repo("two")
    try await cd(store, second, two)
    try await cd(store, first, one + "/src")
    XCTAssertEqual(
      followed(store)?.repository?.root, two, "an unfocused terminal's cd moves nothing")
    XCTAssertNil(store.inspectorTargetID, "a followed folder is no sidebar item")
    XCTAssertEqual(provider.logRoots.last, two)

    store.terminals.select(first.id, for: target)
    await settle(store)
    XCTAssertEqual(followed(store)?.folder, one + "/src")
    XCTAssertEqual(followed(store)?.repository?.root, one, "focus into another repository")
    XCTAssertEqual(store.inspectorHistoryTarget?.path, one)
    XCTAssertEqual(provider.logRoots.last, one)

    try await cd(store, second, one)
    let reads = provider.logRoots.count
    let key = store.inspectorSubject.repositoryKey
    store.terminals.select(second.id, for: target)
    await settle(store)
    XCTAssertEqual(followed(store)?.folder, one, "the folder follows focus")
    XCTAssertEqual(store.inspectorSubject.repositoryKey, key)
    XCTAssertEqual(provider.logRoots.count, reads, "focus within one repository reads no log")
  }

  /// Value: protects=⌘D on a standalone terminal keeping the inspector on its folder through the
  /// conversion to a group (story 7); fails_when=the new group has nothing to inspect, leaves the
  /// focused pane's folder, or empties History mid-conversion (the selection moves before the
  /// terminals do), so it re-reads the log; why_new=#806; seam=AppStore over a shared section;
  /// no_claim=the panels' rendering
  func testSplittingAStandaloneTerminalKeepsFollowingItsFolder() async throws {
    let store = makeStore()
    store.newTerminalInSelectedTarget()
    let standalone = try XCTUnwrap(store.selectedTarget)
    guard case .standalone = standalone.id else { throw XCTSkip("not a standalone terminal") }
    let tab = try XCTUnwrap(store.terminals.tabs(for: standalone).first)
    let root = repo("app")
    try await cd(store, tab, root + "/src")
    let reads = provider.logRoots.count

    store.splitFocusedRight()
    await settle(store)

    guard case .terminalGroup = store.selectedTargetID else {
      return XCTFail("\(String(describing: store.selectedTargetID)) is not a group")
    }
    let group = try XCTUnwrap(store.selectedTarget)
    XCTAssertNotEqual(store.terminals.focusedTab(for: group)?.id, tab.id, "the new pane is focused")
    XCTAssertEqual(followed(store)?.folder, root + "/src", "it opened in the split one's folder")
    XCTAssertEqual(followed(store)?.repository?.root, root)

    store.terminals.select(tab.id, for: group)
    await settle(store)
    XCTAssertEqual(followed(store)?.folder, root + "/src")
    XCTAssertEqual(provider.logRoots.count, reads, "the same repository reads no log")
  }

  /// Value: protects=the subject matching the window's selection after a terminal leaves the group
  /// (story 8); fails_when=the moved terminal's new, selected row shows another folder, or the
  /// group, selected again, still follows the terminal that left; why_new=#806;
  /// seam=AppStore; no_claim=drag routes, which end in the same move
  func testATerminalMovedOutOfTheGroupLeavesTheSubjectOnTheSelection() async throws {
    let store = makeStore()
    let (target, first, second) = try await groupOfTwo(store)
    let one = repo("one")
    let two = repo("two")
    try await cd(store, first, one)
    try await cd(store, second, two)
    XCTAssertEqual(followed(store)?.repository?.root, two)

    let moved = await store.movePaneToStandalone(
      second.id, of: target, source: store.terminals,
      notifications: NotificationCenterStore())
    await settle(store)

    XCTAssertTrue(moved)
    guard case .standalone = store.selectedTargetID else {
      return XCTFail("\(String(describing: store.selectedTargetID)): the moved terminal's row")
    }
    XCTAssertEqual(followed(store)?.repository?.root, two, "the selected, moved terminal")

    store.selectedTargetID = try XCTUnwrap(target.id.sidebarID)
    await settle(store)
    XCTAssertEqual(followed(store)?.repository?.root, one, "the group follows what stayed")
  }

  /// Value: protects=the subject following the terminal left when an unnamed group dissolves
  /// (story 8); fails_when=the standalone terminal it becomes has nothing to inspect or keeps the
  /// closed terminal's repository; why_new=#806; seam=AppStore over a shared section;
  /// no_claim=named groups, which don't dissolve
  func testADissolvingGroupLeavesTheSubjectOnTheTerminalLeft() async throws {
    let store = makeStore()
    store.newTerminalInSelectedTarget()
    let standalone = try XCTUnwrap(store.selectedTarget)
    let kept = try XCTUnwrap(store.terminals.tabs(for: standalone).first)
    let one = repo("one")
    try await cd(store, kept, one)
    store.splitFocusedRight()
    await settle(store)
    let group = try XCTUnwrap(store.selectedTarget)
    guard case .terminalGroup = group.id else { return XCTFail("\(group.id) is not a group") }
    let added = try XCTUnwrap(store.terminals.tabs(for: group).first { $0.id != kept.id })
    store.terminals.select(added.id, for: group)
    try await cd(store, added, repo("two"))
    XCTAssertEqual(followed(store)?.repository?.root, scratch.appendingPathComponent("two").path)

    store.closeCurrentTerminalTab()
    await settle(store)

    guard case .standalone = store.selectedTargetID else {
      return XCTFail("\(String(describing: store.selectedTargetID)) is not standalone")
    }
    XCTAssertEqual(followed(store)?.repository?.root, one, "the terminal that stayed")
  }

  /// Value: protects=the Quick Terminal's group feeding no window (story 30); fails_when=a cd in the
  /// panel's pane moves a window following a group; why_new=#806; seam=AppStore +
  /// QuickTerminalHost; no_claim=the panel's own status bar
  func testTheQuickTerminalsGroupMovesNoWindowsSubject() async throws {
    let store = makeStore()
    let (_, _, second) = try await groupOfTwo(store)
    let root = repo("app")
    try await cd(store, second, root)
    let subject = store.inspectorSubject
    let panel = makeQuickTerminalHost(notifications: NotificationCenterStore(), section: section)
    let quick = panel.terminals.addTab(for: panel.target)

    try XCTUnwrap(panel.terminals.surface(quick)).handlePwd(repo("other"))
    await settle(store)

    XCTAssertEqual(store.inspectorSubject, subject)
  }
}
