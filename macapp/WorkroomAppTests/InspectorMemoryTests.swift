import AppKit
import SwiftUI
import WorkroomDomain
import WorkroomSystem
import XCTest

@testable import Workroom

/// Each repository and folder a terminal's inspector follows remembers its own inspector state
/// (#810): Files its expanded folders and scroll per folder, Changes and History their scroll per
/// repository root. Returning to one restores it, and no switch moves the inspector to another
/// section. Real throwaway folders and repositories on disk; the folder arrives through the
/// surface's pwd handler, as a shell's does.
@MainActor
final class InspectorMemoryTests: XCTestCase {
  private let projects = ProjectStore()
  private let section = TerminalsSection()
  private var scratch: URL!

  override func setUp() async throws {
    try await super.setUp()
    try XCTSkipIf(
      sh("command -v git", in: NSTemporaryDirectory()) != 0, "git is not installed")
    projects.projects = [
      Project(
        path: "/p", vcs: "git",
        workrooms: [Workroom(name: "a", path: "/p/a", vcsName: "workroom/a", warnings: [])])
    ]
    // Canonical (`/private/var/...`), as git names a repository's root.
    let made = FileManager.default.temporaryDirectory
      .appendingPathComponent("inspector-memory-\(UUID().uuidString)")
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

  private func makeStore() -> AppStore {
    let store = AppStore(projectStore: projects, terminalsSection: section)
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
    store.activeInspectorSection = .files
    return store
  }

  private func openTerminal(_ store: AppStore) async throws -> TerminalTab {
    store.newTerminalInSelectedTarget()
    let target = try XCTUnwrap(store.selectedTarget)
    guard case .standalone = target.id else { throw XCTSkip("not a standalone terminal") }
    await store.followedFolderResolved()
    return try XCTUnwrap(store.terminals.tabs(for: target).first)
  }

  /// The shell in `tab` reports `folder`; wait for it to resolve and for Files to list it, as the
  /// panel's activation does.
  private func cd(_ store: AppStore, _ tab: TerminalTab, _ folder: String) async throws {
    try XCTUnwrap(store.terminals.surface(tab)).handlePwd(folder)
    await store.followedFolderResolved()
    store.activateFileTree()
    await listed(store)
  }

  /// Wait until the tree has settled on a listing.
  private func listed(_ store: AppStore, file: StaticString = #filePath, line: UInt = #line) async {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if store.fileTree.state != .loading { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("Files never listed", file: file, line: line)
  }

  /// Wait until `condition` holds.
  private func eventually(
    _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("never happened", file: file, line: line)
  }

  /// The tree's visible rows, by path.
  private func rows(_ store: AppStore) -> [String] { store.fileTree.rows.map(\.node.path) }

  /// Expand the directory row at `path`.
  private func expand(_ store: AppStore, _ path: String) throws {
    let row = try XCTUnwrap(store.fileTree.rows.first { $0.node.path == path }, "no row \(path)")
    store.fileTree.toggle(row.node)
  }

  // MARK: Disk

  @discardableResult
  private func sh(_ cmd: String, in dir: String) -> Int32 {
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
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
  }

  private func write(_ path: String) {
    try? FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? "x\n".write(toFile: path, atomically: true, encoding: .utf8)
  }

  /// A repository with `README.md`, `src/main.swift`, `src/lib/a.txt` and `docs/guide.md`.
  private func repo(_ name: String) -> String {
    let dir = scratch.appendingPathComponent(name).path
    for file in ["README.md", "src/main.swift", "src/lib/a.txt", "docs/guide.md"] {
      write(dir + "/" + file)
    }
    sh("git init -q -b main . && git add -A && git commit -qm base", in: dir)
    return dir
  }

  // MARK: Files expansion

  /// Value: protects=Files' expanded folders restored on returning to a folder (AC 2);
  /// fails_when=a cd away and back collapses the tree, or one repository's expansion leaks into
  /// another; why_new=#810; seam=AppStore + FileTreeModel; no_claim=the rows' rendering
  func testFilesRestoresAFoldersExpansionOnReturn() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let app = repo("app")
    let other = repo("other")

    try await cd(store, tab, app)
    try expand(store, "src")
    XCTAssertEqual(rows(store), ["docs", "src", "src/lib", "src/main.swift", "README.md"])

    try await cd(store, tab, other)
    XCTAssertEqual(
      rows(store), ["docs", "src", "README.md"], "another repository starts collapsed")

    try await cd(store, tab, app)
    XCTAssertEqual(rows(store), ["docs", "src", "src/lib", "src/main.swift", "README.md"])
  }

  /// Value: protects=expansion kept per folder within one repository (AC 2); fails_when=a cd
  /// between a repository's folders keeps one expansion for all of them, or drops it;
  /// why_new=#810; seam=AppStore + FileTreeModel; no_claim=—
  func testEachFolderOfARepositoryKeepsItsOwnExpansion() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let app = repo("app")

    try await cd(store, tab, app)
    try expand(store, "src")
    try await cd(store, tab, app + "/src")
    XCTAssertEqual(rows(store), ["src/lib", "src/main.swift"], "src starts collapsed")
    try expand(store, "src/lib")

    try await cd(store, tab, app)
    XCTAssertEqual(
      rows(store), ["docs", "src", "src/lib", "src/main.swift", "README.md"],
      "the root keeps its own expansion, not src's")
    try await cd(store, tab, app + "/src")
    XCTAssertEqual(rows(store), ["src/lib", "src/lib/a.txt", "src/main.swift"])
  }

  /// Value: protects=a plain folder's expansion restored with its opened folders read again (AC 2);
  /// fails_when=a returning plain folder shows an expanded directory with no children;
  /// why_new=#810; seam=AppStore + FileTreeModel; no_claim=—
  func testAPlainFolderRestoresItsExpansionAndReadsTheOpenFolders() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let plain = scratch.appendingPathComponent("plain").path
    write(plain + "/inner/file.txt")
    let app = repo("app")

    try await cd(store, tab, plain)
    try expand(store, "inner")
    await eventually { rows(store) == ["inner", "inner/file.txt"] }

    try await cd(store, tab, app)
    try await cd(store, tab, plain)
    await eventually { rows(store) == ["inner", "inner/file.txt"] }
  }

  /// Value: protects=a workroom's tree unchanged (out of scope); fails_when=a workroom's Files
  /// restores an expansion it never had before #810; why_new=#810; seam=FileTreeModel;
  /// no_claim=—
  func testAWorkroomsTreeStillStartsCollapsed() async throws {
    let model = FileTreeModel()
    let app = repo("app")
    let other = repo("other")
    model.activate(path: app)
    await eventually { model.state == .loaded }
    model.expanded = ["src"]
    model.activate(path: other)
    model.activate(path: app)
    XCTAssertEqual(model.expanded, [])
  }

  // MARK: Scroll

  /// Value: protects=Changes and History scroll remembered per repository root, Files per folder
  /// (AC 1, 2); fails_when=a repository switch shows the last repository's offset, a cd within
  /// one repository loses Changes' offset, or a return forgets it; why_new=#810; seam=AppStore;
  /// no_claim=the scroll views' restore (view-level)
  func testScrollIsRememberedPerRepositoryAndPerFolder() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let app = repo("app")
    let other = repo("other")
    let memory = store.inspectorScrollMemory

    try await cd(store, tab, app)
    let changesA = try XCTUnwrap(store.inspectorMemoryKey(for: .changes))
    let historyA = try XCTUnwrap(store.inspectorMemoryKey(for: .history))
    let filesA = try XCTUnwrap(store.inspectorMemoryKey(for: .files))
    XCTAssertEqual(Set([changesA, historyA, filesA]).count, 3, "each section its own")
    memory.remember(120, under: changesA)
    memory.remember(80, under: historyA)
    memory.remember(40, under: filesA)

    try await cd(store, tab, app + "/src")
    XCTAssertEqual(store.inspectorMemoryKey(for: .changes), changesA, "same repository")
    XCTAssertEqual(store.inspectorMemoryKey(for: .history), historyA)
    let filesSrc = try XCTUnwrap(store.inspectorMemoryKey(for: .files))
    XCTAssertNotEqual(filesSrc, filesA, "Files remembers per folder")
    XCTAssertNil(memory.offset(under: filesSrc))

    try await cd(store, tab, other)
    let changesB = try XCTUnwrap(store.inspectorMemoryKey(for: .changes))
    XCTAssertNotEqual(changesB, changesA)
    XCTAssertNil(memory.offset(under: changesB))

    try await cd(store, tab, app)
    XCTAssertEqual(store.inspectorMemoryKey(for: .changes).flatMap(memory.offset), 120)
    XCTAssertEqual(store.inspectorMemoryKey(for: .history).flatMap(memory.offset), 80)
    XCTAssertEqual(store.inspectorMemoryKey(for: .files).flatMap(memory.offset), 40)
  }

  /// Value: protects=a breadcrumb browse remembering the browsed folder's scroll apart from the
  /// terminal's (AC 2); fails_when=a browsed folder shares the terminal folder's offset;
  /// why_new=#810; seam=AppStore; no_claim=—
  func testABrowsedFolderHasItsOwnFilesMemory() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let app = repo("app")
    try await cd(store, tab, app + "/src")
    let src = try XCTUnwrap(store.inspectorMemoryKey(for: .files))

    store.browseFiles(toSegment: 0)
    let browsed = try XCTUnwrap(store.inspectorMemoryKey(for: .files))
    XCTAssertNotEqual(browsed, src)
    let repoRoot = try XCTUnwrap(store.followedFilesRoot)
    try await cd(store, tab, app)
    XCTAssertEqual(store.followedFilesRoot, repoRoot)
    XCTAssertEqual(
      store.inspectorMemoryKey(for: .files), browsed, "the same folder, however reached")
  }

  /// Value: protects=workroom inspectors unchanged (out of scope); fails_when=a workroom gets
  /// per-target scroll memory; why_new=#810; seam=AppStore; no_claim=—
  func testAWorkroomRemembersNothing() {
    let store = makeStore()
    store.selectedTargetID = .workroom(project: "/p", name: "a")
    store.selectionStatusTask?.cancel()
    store.newTerminalInSelectedTarget()
    XCTAssertEqual(store.inspectorSubject, .target(.workroom(project: "/p", name: "a")))
    XCTAssertNil(store.inspectorMemoryKey(for: .changes))
    XCTAssertNil(store.inspectorMemoryKey(for: .files))
  }

  /// Value: protects=a Changes or Pull Request pane restoring its repository's scroll when that
  /// repository's content arrives after the switch (AC 1); fails_when=a briefly short body
  /// clamps the clip view and that clamp is kept as the repository's offset, or another
  /// repository opens at the last one's offset; why_new=#810; seam=InspectorPaneViewController;
  /// no_claim=a real trackpad scroll (posted as the live-scroll notification it raises)
  func testAScrollPaneRestoresItsOffsetWhenTheContentArrivesLate() throws {
    let memory = InspectorScrollMemory()
    let pane = InspectorPaneViewController()
    pane.view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    let scroll = try XCTUnwrap(pane.view.subviews.compactMap { $0 as? NSScrollView }.first)
    func show(_ height: CGFloat, under key: String) {
      pane.setContent(
        header: AnyView(EmptyView()),
        body: AnyView(Color.clear.frame(width: 300, height: height)), collapsed: false)
      pane.remembersScroll(under: key, in: memory)
      pane.view.layoutSubtreeIfNeeded()
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      pane.view.layoutSubtreeIfNeeded()
    }
    var offset: CGFloat { scroll.contentView.bounds.origin.y }

    show(2000, under: "a")
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
    scroll.reflectScrolledClipView(scroll.contentView)
    NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
    XCTAssertEqual(memory.offset(under: "a"), 300)

    show(2000, under: "b")
    XCTAssertEqual(offset, 0, "another repository opens at its top")

    show(50, under: "a")
    XCTAssertEqual(memory.offset(under: "a"), 300, "a short body's clamp is not remembered")
    show(2000, under: "a")
    XCTAssertEqual(offset, 300, "restored once the content is there")
  }

  /// Value: protects=Changes' and History's selection surviving a round trip between
  /// repositories (AC 1); fails_when=a repository switch drops or replaces the focused content
  /// tab the selected row is read from; why_new=#810; seam=AppStore; no_claim=row highlighting
  func testSelectionSurvivesARoundTripBetweenRepositories() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let app = repo("app")
    let other = repo("other")
    try await cd(store, tab, app)
    store.openChangesetPersistent(commitID: "abc", title: "base")
    let selected = FocusedTabSelection.current(store: store)
    XCTAssertEqual(selected, .changeset(commitID: "abc"))

    try await cd(store, tab, other)
    try await cd(store, tab, app)
    XCTAssertEqual(FocusedTabSelection.current(store: store), selected)
  }

  // MARK: Section

  /// Value: protects=the chosen inspector section through every switch (AC 3); fails_when=a
  /// repository, folder or not-a-repository switch moves the inspector to another section;
  /// why_new=#810; seam=AppStore; no_claim=—
  func testNoSwitchChangesTheActiveSection() async throws {
    for chosen in [ActivitySection.details, .changes, .files] {
      let store = makeStore()
      store.activeInspectorSection = chosen
      let tab = try await openTerminal(store)
      let app = repo("app-\(chosen)")
      let other = repo("other-\(chosen)")
      let plain = scratch.appendingPathComponent("plain-\(chosen)").path
      write(plain + "/notes.txt")
      for folder in [app, app + "/src", other, plain, app] {
        try await cd(store, tab, folder)
        XCTAssertEqual(store.activeInspectorSection, chosen, "after cd \(folder)")
      }
    }
  }
}
