import Synchronization
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import XCTest

@testable import Workroom

/// The Files section of a followed folder (#809, ADR 0081): rooted at the terminal's folder,
/// re-rooted on every `cd`, with a breadcrumb from the repository's root (or `~`, else `/`) whose
/// segments browse Files alone until the next `cd` snaps it back. Real throwaway folders and
/// repositories on disk; the folder arrives through the surface's pwd handler, as a shell's does.
@MainActor
final class FollowedFilesTests: XCTestCase {
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
      .appendingPathComponent("followed-files-\(UUID().uuidString)")
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

  /// The names of the tree's top-level rows.
  private func names(_ store: AppStore) -> [String] { store.fileTree.roots.map(\.name) }

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

  // MARK: Re-rooting

  /// Value: protects=Files rooted at the shell's folder and following every cd (AC 1);
  /// fails_when=Files lists the repository's root, or keeps a folder the shell left;
  /// why_new=#809; seam=AppStore + FileTreeModel; no_claim=the rows' rendering
  func testFilesIsRootedAtTheFolderAndReRootsOnEveryCd() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")

    try await cd(store, tab, root + "/src")
    XCTAssertEqual(names(store), ["lib", "main.swift"])
    XCTAssertEqual(
      store.fileTree.roots.last?.path, "src/main.swift",
      "a file stays relative to the repository's root")

    try await cd(store, tab, root + "/docs")
    XCTAssertEqual(names(store), ["guide.md"])

    try await cd(store, tab, root)
    XCTAssertEqual(names(store), ["docs", "src", "README.md"])
  }

  /// Value: protects=Files re-rooting when the followed folder becomes its own repository (Codex
  /// on #812); fails_when=a `git init` in a followed subfolder leaves Files' activation key alone
  /// (same folder, same path shown), so the tree stays rooted in the parent repository while file
  /// opens use the new root; why_new=review; seam=AppStore.filesActivationKey + FileTreeModel;
  /// no_claim=SwiftUI's `.task` re-run
  func testAGitInitInTheFollowedFolderReRootsFiles() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    let src = root + "/src"
    try await cd(store, tab, src)
    XCTAssertEqual(store.fileTree.roots.last?.path, "src/main.swift")
    let before = store.filesActivationKey

    sh("git init -q -b main .", in: src)
    try XCTUnwrap(store.terminals.surface(tab)).onEvent?(.commandFinished(0))
    await eventually {
      guard case .followed(let followed) = store.inspectorSubject else { return false }
      return followed.repository?.root == src
    }

    XCTAssertNotEqual(store.filesActivationKey, before, "Files re-activates on the new root")
    store.activateFileTree()
    await listed(store)
    XCTAssertEqual(names(store), ["lib", "main.swift"])
    XCTAssertEqual(
      store.fileTree.roots.last?.path, "main.swift", "paths are relative to the new repository")
  }

  /// Value: protects=a file opened from a followed tree reading the followed repository (parent
  /// decision); fails_when=the file tab resolves against the terminal's own folder;
  /// why_new=#809; seam=AppStore; no_claim=the viewer's read
  func testAFileOpenedFromAFollowedTreeReadsItsRepository() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root + "/src")

    store.openFilePreview(path: "src/main.swift")

    let target = try XCTUnwrap(store.selectedTarget)
    let opened = store.terminals.tabs(for: target).compactMap { tab -> FileDescriptor? in
      if case .file(let descriptor) = tab.content { return descriptor }
      return nil
    }
    XCTAssertEqual(opened.map(\.path), ["src/main.swift"])
    XCTAssertEqual(opened.first?.root, root)

    // A restored session reads the same root.
    let fileTab = try XCTUnwrap(
      store.terminals.tabs(for: target).first { if case .file = $0.content { true } else { false } }
    )
    let saved = try XCTUnwrap(TabSession(key: "k", tab: fileTab))
    guard case .file(let restored)? = saved.restoredContent else {
      return XCTFail("the file tab did not restore")
    }
    XCTAssertEqual(restored.root, root)

    // And the viewer's read accepts that root, for a repository and for a plain folder.
    let read = await FileContentLoader.loadOutcome(
      directory: try XCTUnwrap(opened.first?.root), relative: "src/main.swift")
    XCTAssertEqual(read, .text("x\n"))
    let plain = scratch.appendingPathComponent("plain").path
    write(plain + "/notes.txt")
    let plainRead = await FileContentLoader.loadOutcome(directory: plain, relative: "notes.txt")
    XCTAssertEqual(plainRead, .text("x\n"))
  }

  /// The followed target's open file tabs.
  private func fileTabs(_ store: AppStore) throws -> [FileDescriptor] {
    let target = try XCTUnwrap(store.selectedTarget)
    return store.terminals.tabs(for: target).compactMap { tab -> FileDescriptor? in
      if case .file(let descriptor) = tab.content { return descriptor }
      return nil
    }
  }

  /// Value: protects=a changed file opened in the app reading the repository Changes lists
  /// (final pass of #803); fails_when=it reads Files' root, which a browse kept across a re-resolve
  /// (`reresolveFollowedFolder` keeps `filesBrowse`) can leave on another folder, so the tab shows
  /// another file or none; why_new=#807 handoff; seam=AppStore; no_claim=the viewer's read
  func testAChangedFileOpenedInTheAppReadsTheFollowedRepository() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root + "/src")
    guard case .followed(let followed) = store.inspectorSubject else {
      return XCTFail("the inspector follows the terminal's folder")
    }
    let folder = followed.folder
    let target = try XCTUnwrap(store.selectedTargetID?.targetID)
    store.filesBrowse = FilesBrowse(
      target: target, folder: folder, root: .folder(scratch.appendingPathComponent("other").path))

    store.openChangedFileInApp(ChangedFile(path: "src/main.swift", change: .modified))

    XCTAssertEqual(try fileTabs(store).map(\.root), [root])
  }

  /// Value: protects=Changes' "Open File in …" for a followed repository (Codex on #812);
  /// fails_when=the row is disabled because a followed folder has no sidebar target, though the
  /// open reads the repository's root; why_new=review; seam=ChangesPanelAdapter.inputs(store:);
  /// no_claim=the editor launch
  func testAFollowedRepositorysChangedFileCanOpenInTheEditor() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    try await cd(store, tab, repo("app") + "/src")

    XCTAssertFalse(ChangesPanelAdapter.inputs(store: store).fileTargetIsMissing)
    XCTAssertNotNil(store.inspectorHistoryTarget, "what the open reads")

    let plain = scratch.appendingPathComponent("plain").path
    try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
    try await cd(store, tab, plain)
    XCTAssertTrue(
      ChangesPanelAdapter.inputs(store: store).fileTargetIsMissing, "no repository, no open")
  }

  /// Value: protects=a followed repository's diff pane opening its working file from that
  /// repository (final pass of #803); fails_when=the pane's "Open File" drops the diff's root, so
  /// the file tab reads the terminal's own folder; why_new=#807 handoff; seam=AppStore +
  /// `TabContent.fileRoot`, what the pane's toolbar and chip menu pass; no_claim=the button itself
  func testADiffPanesOpenFileKeepsItsRepository() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root + "/src")
    let target = try XCTUnwrap(store.selectedTarget)
    let diff = TabContent.diff(
      DiffDescriptor(
        path: "src/main.swift", change: .modified, source: .gitWorktree, isPreview: true,
        repositoryRoot: root))

    store.openFilePreview(path: try XCTUnwrap(diff.filePath), root: diff.fileRoot, for: target)
    await eventually { (try? self.fileTabs(store).isEmpty) == false }

    XCTAssertEqual(try fileTabs(store).map(\.root), [root])
  }

  /// Value: protects=an ignored folder inside a repository listing its files (review finding);
  /// fails_when=`cd build` says the folder is empty; why_new=#809; seam=AppStore + FileTreeModel;
  /// no_claim=—
  func testAnIgnoredFolderInARepositoryListsItsFilesFromDisk() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    try "build/\n".write(toFile: root + "/.gitignore", atomically: true, encoding: .utf8)
    write(root + "/build/out.o")
    write(root + "/build/gen/x.c")

    try await cd(store, tab, root + "/build")
    await eventually { store.fileTree.state == .loaded && !store.fileTree.roots.isEmpty }

    XCTAssertEqual(names(store), ["gen", "out.o"])
    XCTAssertEqual(
      store.fileTree.roots.last?.path, "build/out.o", "paths stay relative to the repository")
    let gen = try XCTUnwrap(store.fileTree.roots.first)
    store.fileTree.toggle(gen)
    await eventually { store.fileTree.roots.first?.children?.isEmpty == false }
    XCTAssertEqual(
      store.fileTree.rows.map(\.node.path), ["build/gen", "build/gen/x.c", "build/out.o"])

    try await cd(store, tab, root + "/src")
    XCTAssertEqual(names(store), ["lib", "main.swift"], "back to what git lists")
  }

  /// Value: protects=a plain folder's watch re-reading only for its listed directories (review
  /// finding); fails_when=a hidden write in `~` re-reads it, a `/` root never matches, or the
  /// `/private` spelling of a change is missed; why_new=#809; seam=FileTreeModel; no_claim=FSEvents
  func testAPlainFoldersWatchReReadsOnlyForListedDirectories() {
    let listed: Set<String> = ["", "inner"]
    XCTAssertTrue(FileTreeModel.touchesListed(["/h/new.txt"], root: "/h", listed: listed))
    XCTAssertTrue(FileTreeModel.touchesListed(["/h/inner/a"], root: "/h", listed: listed))
    XCTAssertFalse(FileTreeModel.touchesListed(["/h/other/a"], root: "/h", listed: listed))
    XCTAssertFalse(
      FileTreeModel.touchesListed(["/h/.zsh_history"], root: "/h", listed: listed),
      "hidden entries are never listed")
    XCTAssertFalse(FileTreeModel.touchesListed(["/h/.cache/x"], root: "/h", listed: listed))
    XCTAssertTrue(FileTreeModel.touchesListed(["/private/var/x/y"], root: "/var/x", listed: listed))
    XCTAssertTrue(FileTreeModel.touchesListed(["/etc"], root: "/", listed: listed))
    XCTAssertFalse(FileTreeModel.touchesListed(["/usr/lib/x"], root: "/", listed: listed))
    XCTAssertFalse(FileTreeModel.touchesListed(["/hx/a"], root: "/h", listed: listed))
  }

  /// Value: protects=a repository at the home folder (dotfiles) not re-listing on every change
  /// under `~` (review of #807, finding 3); fails_when=a `~/Library` write re-lists it, or an
  /// ordinary repository stops re-listing on a save; why_new=review; seam=FileTreeModel's watch
  /// filter; no_claim=FSEvents
  func testARepositoryAtTheHomeFolderReListsOnlyForShownDirectories() {
    let shown: Set<String> = ["", "src"]
    func reloads(_ path: String, root: String) -> Bool {
      FileTreeModel.shouldReload(
        [path], overflow: false, root: root, plain: false, listed: shown, home: "/Users/me")
    }
    XCTAssertFalse(reloads("/Users/me/Library/Caches/x", root: "/Users/me"))
    XCTAssertFalse(reloads("/Users/me/Downloads/big.zip", root: "/Users/me"))
    XCTAssertTrue(reloads("/Users/me/src/a.swift", root: "/Users/me"))
    XCTAssertTrue(reloads("/Users/me/dev/app/Downloads/x", root: "/Users/me/dev/app"))
    XCTAssertFalse(reloads("/Users/me/dev/app/.git/index", root: "/Users/me/dev/app"))
  }

  // MARK: Breadcrumb

  /// Value: protects=the breadcrumb's base and trail (AC 2); fails_when=it starts anywhere but
  /// the repository's root, or misses a folder on the way down; why_new=#809; seam=AppStore;
  /// no_claim=its rendering
  func testTheBreadcrumbRunsFromTheRepositoryRootToTheFolder() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")

    try await cd(store, tab, root + "/src/lib")

    let breadcrumb = try XCTUnwrap(store.filesBreadcrumb)
    XCTAssertEqual(breadcrumb.base, .repository)
    XCTAssertEqual(breadcrumb.segments.map(\.name), ["app", "src", "lib"])
    XCTAssertEqual(breadcrumb.segments.map(\.path), [root, root + "/src", root + "/src/lib"])
    XCTAssertFalse(breadcrumb.isBrowsedAway)
  }

  /// Value: protects=the breadcrumb comparing canonical paths and showing the shell's spelling
  /// (parent decision; #805 review finding 4); fails_when=a `/var` or symlinked spelling of the
  /// folder loses its trail, or the root shows as its real path; why_new=#809; seam=AppStore;
  /// no_claim=the header's rendering
  func testASymlinkedSpellingKeepsItsTrailAndItsSpelling() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    let link = scratch.appendingPathComponent("link").path
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root)

    try await cd(store, tab, link + "/src")

    guard case .followed(let followed) = store.inspectorSubject else {
      return XCTFail("subject is \(store.inspectorSubject)")
    }
    XCTAssertEqual(followed.repository?.root, root, "the identity stays the real root")
    XCTAssertEqual(followed.repository?.displayRoot, link, "shown as the shell spells it")
    let breadcrumb = try XCTUnwrap(store.filesBreadcrumb)
    XCTAssertEqual(breadcrumb.segments.map(\.name), ["link", "src"])
    XCTAssertEqual(breadcrumb.segments.map(\.path), [link, link + "/src"])
    XCTAssertEqual(names(store), ["lib", "main.swift"])
  }

  /// Value: protects=the `~` and `/` bases outside a repository (AC 2); fails_when=a plain folder
  /// under home starts at `/`, or one outside home claims `~`; why_new=#809; seam=FilesBreadcrumb;
  /// no_claim=a real home (a throwaway one stands in)
  func testOutsideARepositoryTheBreadcrumbStartsAtHomeElseTheRoot() {
    let home = scratch.appendingPathComponent("home").path

    let inHome = FilesBreadcrumb.make(folder: home + "/a/b", repository: nil, home: home)
    XCTAssertEqual(inHome.base, .home)
    XCTAssertEqual(inHome.segments.map(\.name), ["~", "a", "b"])
    XCTAssertEqual(inHome.segments.map(\.path), [home, home + "/a", home + "/a/b"])

    let atHome = FilesBreadcrumb.make(folder: home, repository: nil, home: home + "/")
    XCTAssertEqual(atHome.segments.map(\.name), ["~"])

    let elsewhere = FilesBreadcrumb.make(folder: "/opt/tools", repository: nil, home: home)
    XCTAssertEqual(elsewhere.base, .fileSystem)
    XCTAssertEqual(elsewhere.segments.map(\.name), ["/", "opt", "tools"])
    XCTAssertEqual(elsewhere.segments.map(\.path), ["/", "/opt", "/opt/tools"])
    XCTAssertEqual(
      FilesBreadcrumb.make(folder: home + "-other", repository: nil, home: home).base,
      .fileSystem, "a sibling sharing home's prefix is not in it")
  }

  /// Value: protects=the breadcrumb showing only for a followed folder (AC 2); fails_when=a
  /// workroom's Files grows one; why_new=#809; seam=AppStore; no_claim=—
  func testAWorkroomsFilesHasNoBreadcrumb() async throws {
    let store = makeStore()
    let sid = SidebarID.workroom(project: "/p", name: "a")
    let target = try XCTUnwrap(store.target(for: sid))
    _ = store.terminals.addTab(for: target)
    store.selectedTargetID = sid
    store.refreshSelectionHasTabs()

    XCTAssertEqual(store.inspectorSubject, .target(sid))
    XCTAssertNil(store.filesBreadcrumb)
    XCTAssertNil(store.followedFilesRoot)
    XCTAssertNil(store.filesFileRoot)
  }

  // MARK: Browse and snap back

  /// Value: protects=browsing a segment in Files alone, its visible state, and the snap-back
  /// (AC 3); fails_when=a click moves the terminal or the subject, the leaf hides that Files shows
  /// another folder, or the next cd leaves Files browsed away; why_new=#809; seam=AppStore;
  /// no_claim=the leaf's rendering
  func testABreadcrumbClickBrowsesFilesAloneAndTheNextCdSnapsBack() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root + "/src/lib")
    let subject = store.inspectorSubject

    store.browseFiles(toSegment: 0)
    await listed(store)

    XCTAssertEqual(names(store), ["docs", "src", "README.md"], "Files shows the root")
    let browsed = try XCTUnwrap(store.filesBreadcrumb)
    XCTAssertTrue(browsed.isBrowsedAway)
    XCTAssertEqual(browsed.shownIndex, 0)
    XCTAssertEqual(browsed.segments.count, 3, "the trail still runs to the terminal's folder")
    XCTAssertEqual(store.inspectorSubject, subject, "the subject stays the terminal's folder")
    let target = try XCTUnwrap(store.selectedTarget)
    let state = try XCTUnwrap(
      store.terminals.tabs(for: target).first.flatMap { tab -> TerminalState? in
        if case .terminal(let state) = tab.content { return state }
        return nil
      })
    XCTAssertEqual(state.cwd, root + "/src/lib", "the terminal never moved")

    try await cd(store, tab, root + "/docs")

    XCTAssertEqual(names(store), ["guide.md"], "the next cd snaps Files back")
    XCTAssertEqual(store.filesBreadcrumb?.isBrowsedAway, false)
  }

  /// Value: protects=the leaf returning Files to the terminal's folder; fails_when=clicking the
  /// leaf keeps the browsed folder; why_new=#809; seam=AppStore; no_claim=—
  func testClickingTheLeafReturnsToTheTerminalsFolder() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    try await cd(store, tab, root + "/src")
    store.browseFiles(toSegment: 0)
    await listed(store)

    store.browseFiles(toSegment: 1)
    await listed(store)

    XCTAssertEqual(store.filesBreadcrumb?.isBrowsedAway, false)
    XCTAssertEqual(names(store), ["lib", "main.swift"])
  }

  // MARK: Outside a repository

  /// Value: protects=a plain folder listing from disk, one level at a time (AC 4); fails_when=a
  /// folder outside any repository says "Not a repository", lists hidden files, or reads a whole
  /// subtree before it opens; why_new=#809; seam=AppStore + FileTreeModel; no_claim=git markers
  /// (the rows draw none for any tree)
  func testAFolderOutsideARepositoryListsItsEntriesLazily() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let plain = scratch.appendingPathComponent("plain").path
    write(plain + "/notes.txt")
    write(plain + "/.hidden")
    write(plain + "/inner/deep/file.txt")

    try await cd(store, tab, plain)

    XCTAssertEqual(store.fileTree.state, .loaded)
    XCTAssertEqual(names(store), ["inner", "notes.txt"])
    let inner = try XCTUnwrap(store.fileTree.roots.first)
    XCTAssertTrue(inner.isDirectory)
    XCTAssertEqual(inner.children, [], "not read until it opens")
    XCTAssertEqual(store.filesBreadcrumb?.base, .fileSystem)

    store.fileTree.toggle(inner)
    await eventually { store.fileTree.roots.first?.children?.isEmpty == false }

    XCTAssertEqual(store.fileTree.rows.map(\.node.path), ["inner", "inner/deep", "notes.txt"])
    XCTAssertEqual(store.filesFileRoot, plain, "its files read from the folder")
  }

  /// Value: protects=moving from a plain folder into a repository and back (the listing modes
  /// switching); fails_when=a mode switch leaves the old listing or a stale state;
  /// why_new=#809; seam=AppStore + FileTreeModel; no_claim=—
  func testMovingBetweenAPlainFolderAndARepositorySwitchesTheListing() async throws {
    let store = makeStore()
    let tab = try await openTerminal(store)
    let root = repo("app")
    let plain = scratch.appendingPathComponent("plain").path
    write(plain + "/notes.txt")

    try await cd(store, tab, plain)
    XCTAssertEqual(names(store), ["notes.txt"])

    try await cd(store, tab, root + "/docs")
    XCTAssertEqual(names(store), ["guide.md"])

    try await cd(store, tab, plain)
    XCTAssertEqual(names(store), ["notes.txt"])
  }

  // MARK: A wedged mount

  /// Value: protects=a wedged mount costing one blocked read of a plain folder, not one per watch
  /// event, and the tree not spinning for good (final pass); fails_when=the disk read has no
  /// timeout, so every re-read blocks another GCD thread and Files stays "loading";
  /// why_new=#803 final pass; seam=FileTreeModel with a disk read that blocks; no_claim=the
  /// existence check (its own test)
  func testAStuckPlainFolderReadTimesOutAndBlocksOneRead() async throws {
    let plain = scratch.appendingPathComponent("stuck-\(UUID().uuidString)").path
    write(plain + "/notes.txt")
    let gate = DispatchSemaphore(value: 0)
    let blocks = Mutex(true)
    let reads = Mutex(0)
    let model = FileTreeModel(
      diskReadTimeout: 0.1,
      readDirectories: { directories, root in
        reads.withLock { $0 += 1 }
        if blocks.withLock({ $0 }) { gate.wait() }
        return FileTreeModel.readPlain(directories, under: root)
      })
    defer {
      blocks.withLock { $0 = false }
      gate.signal()
    }

    model.activate(root: .folder(plain))
    await eventually { model.state == .unavailable }
    for _ in 0..<4 { model.reload() }
    try await Task.sleep(for: .milliseconds(800))

    XCTAssertEqual(reads.withLock { $0 }, 1, "one blocked read, joined by every re-read")
    XCTAssertEqual(model.state, .unavailable)

    blocks.withLock { $0 = false }
    gate.signal()
    // The blocked read's entry clears once it returns, so a later re-read lists the folder.
    for _ in 0..<100 where model.state != .loaded {
      model.reload()
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(model.state, .loaded)
    XCTAssertEqual(model.roots.map(\.name), ["notes.txt"])
  }

  /// Value: protects=a folder whose existence check never returns showing as unavailable
  /// (final pass); fails_when=the check runs with no timeout, so Files says "loading" for as long
  /// as the mount is wedged; why_new=#803 final pass; seam=FileTreeModel with a stat that blocks;
  /// no_claim=the disk read (its own test)
  func testAStuckExistenceCheckTimesOut() async throws {
    let plain = scratch.appendingPathComponent("stuck-\(UUID().uuidString)").path
    write(plain + "/notes.txt")
    let gate = DispatchSemaphore(value: 0)
    let model = FileTreeModel(
      diskReadTimeout: 0.1,
      isFolder: { _ in
        gate.wait()
        return true
      })
    defer { gate.signal() }

    model.activate(root: .folder(plain))

    await eventually { model.state == .unavailable }
  }
}
