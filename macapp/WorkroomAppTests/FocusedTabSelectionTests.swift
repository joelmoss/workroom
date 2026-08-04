import XCTest

@testable import Workroom

/// `FocusedTabSelection` is the single place that answers "what is the focused content tab showing?",
/// extracted from three copies of the same guard chain in `HistoryRow`, `DivergentSiblingRow` and
/// `ChangedFileRow` (each of which held two observed objects to run it — the WORKROOM-2B invalidation
/// storm). One place means one place to teach when a `TabContent` case is added; these tests pin the
/// mapping for every case, including the ones that must resolve to "nothing selected".
@MainActor
final class FocusedTabSelectionTests: XCTestCase {
  private let projectPath = "/focused-tab"
  private let workroomName = "solo"

  private func makeStore() -> AppStore {
    let store = AppStore()
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.projects = [
      Project(
        path: projectPath, vcs: "git",
        workrooms: [
          Workroom(
            name: workroomName, path: "\(projectPath)/\(workroomName)",
            vcsName: "workroom/\(workroomName)", warnings: [])
        ])
    ]
    return store
  }

  private func selectWorkroom(_ store: AppStore) -> TerminalTarget {
    let target = store.target(for: .workroom(project: projectPath, name: workroomName))!
    _ = store.terminals.addTab(for: target)
    store.selectedTargetID = .workroom(project: projectPath, name: workroomName)
    return target
  }

  private func current(_ store: AppStore) -> FocusedTabSelection? {
    FocusedTabSelection.current(store: store, sessions: store.terminals)
  }

  func testNoSelectionResolvesToNil() {
    let store = makeStore()
    XCTAssertNil(current(store), "nothing selected ⇒ no row can be the selected row")
  }

  func testFocusedTerminalTabResolvesToNil() {
    let store = makeStore()
    _ = selectWorkroom(store)
    XCTAssertNil(
      current(store),
      "a terminal tab corresponds to no inspector row, so it must not select one (a `default:` that "
        + "fell through to a path match would highlight arbitrary rows)")
  }

  func testFocusedChangesetTabResolvesToItsCommit() {
    let store = makeStore()
    _ = selectWorkroom(store)
    store.openChangesetPreview(commitID: "deadbeef", title: "a commit")

    XCTAssertEqual(current(store), .changeset(commitID: "deadbeef"))
    XCTAssertEqual(current(store)?.changesetCommitID, "deadbeef")
    XCTAssertFalse(
      current(store)!.selectsChangedFile(path: "a.txt", source: .gitWorktree),
      "a changeset tab must not select a Changes-panel file row")
  }

  func testFocusedDiffTabSelectsThatPathInThatGroupOnly() {
    let store = makeStore()
    _ = selectWorkroom(store)
    store.openDiffPreview(ChangedFile(path: "src/a.swift", change: .modified), source: .gitWorktree)

    let selection = current(store)
    XCTAssertEqual(selection, .diff(path: "src/a.swift", source: .gitWorktree))
    XCTAssertTrue(selection!.selectsChangedFile(path: "src/a.swift", source: .gitWorktree))
    XCTAssertFalse(
      selection!.selectsChangedFile(path: "src/a.swift", source: .jjWorkingCopy),
      "a diff keeps its source so the same path under `@` vs `@-` selects the right row")
    XCTAssertFalse(selection!.selectsChangedFile(path: "src/b.swift", source: .gitWorktree))
    XCTAssertNil(selection?.changesetCommitID)
  }

  func testFocusedFileTabSelectsThePathRegardlessOfGroup() {
    let store = makeStore()
    _ = selectWorkroom(store)
    store.openChangedFileInApp(ChangedFile(path: "src/a.swift", change: .modified))

    let selection = current(store)
    XCTAssertEqual(selection, .file(path: "src/a.swift"))
    // A file tab has no revision, so it matches on path alone — in BOTH groups.
    XCTAssertTrue(selection!.selectsChangedFile(path: "src/a.swift", source: .gitWorktree))
    XCTAssertTrue(selection!.selectsChangedFile(path: "src/a.swift", source: .jjWorkingCopy))
    XCTAssertFalse(selection!.selectsChangedFile(path: "src/other.swift", source: .gitWorktree))
  }
}
