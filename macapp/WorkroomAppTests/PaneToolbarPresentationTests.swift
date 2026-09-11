import XCTest

@testable import Workroom

/// The detail-panel title bar's trailing-control matrix and its title/truncation mapping (issue #150),
/// kept pure and tested away from SwiftUI for the same reason `WorkroomPaneToolbarPresentation` is: a
/// view can't be instantiated in a unit test, and both rules are easy to state and easy to get subtly
/// wrong in a view body.
///
/// `PaneTitleBar` itself takes no store and no `@ObservedObject`, which is what lets these run with
/// nothing constructed but a `TabContent`.
final class PaneToolbarPresentationTests: XCTestCase {

  // MARK: Controls

  private func diff(_ path: String = "a/b.swift", change: ChangedFile.Change = .modified)
    -> TabContent
  {
    .diff(DiffDescriptor(path: path, change: change, source: .gitWorktree, isPreview: false))
  }

  private func file(_ path: String) -> TabContent {
    .file(FileDescriptor(path: path, isPreview: false))
  }

  private func changeset() -> TabContent {
    .changeset(
      ChangesetDescriptor(commitID: "abc123", title: "Add the thing", isPreview: false))
  }

  /// A `GhosttySurfaceView` is inert until it enters a window, so building one costs nothing and
  /// spawns no shell (same construction `SwitcherMarkTests` uses).
  private func terminal() -> TabContent {
    .terminal(
      TerminalState(view: GhosttySurfaceView(workingDirectory: "/tmp"), defaultTitle: "zsh"))
  }

  /// A diff pane is the fully-dressed case: the view-mode switch, "Open File", and therefore the rule
  /// separating them from split/close.
  func testDiffPaneShowsBothOptionalControlsAndTheDivider() {
    XCTAssertEqual(
      PaneToolbarPresentation.controls(for: diff()),
      .init(diffMode: true, openFile: true, markdownMode: false))
  }

  /// Only a markdown file has a rendered form to switch to. Every other file shows source either way,
  /// so it gets no switch — and, with nothing before the split/close group, no divider.
  func testOnlyMarkdownFilesGetTheModeSwitch() {
    let markdown = PaneToolbarPresentation.controls(for: file("docs/README.md"))
    XCTAssertTrue(markdown.markdownMode)
    XCTAssertTrue(markdown.hasOptional)

    let plain = PaneToolbarPresentation.controls(for: file("src/main.swift"))
    XCTAssertFalse(plain.markdownMode)
    XCTAssertFalse(plain.hasOptional)
  }

  /// "Open File" is diff-only: it opens the working copy of the file being *diffed*. A file pane is
  /// already showing that file, and a terminal has none.
  func testOpenFileIsDiffOnly() {
    XCTAssertTrue(PaneToolbarPresentation.controls(for: diff()).openFile)
    XCTAssertFalse(PaneToolbarPresentation.controls(for: file("a/b.md")).openFile)
    XCTAssertFalse(PaneToolbarPresentation.controls(for: terminal()).openFile)
    XCTAssertFalse(PaneToolbarPresentation.controls(for: changeset()).openFile)
  }

  /// A terminal and a changeset carry only the unconditional split/close group. The changeset case is
  /// deliberate rather than an oversight: its own `DiffViewer` header switches the mode for whichever
  /// file is selected inside it, so a second switch on the pane would fight it.
  func testTerminalAndChangesetShowNoOptionalControls() {
    for content in [terminal(), changeset()] {
      let c = PaneToolbarPresentation.controls(for: content)
      XCTAssertFalse(c.hasOptional)
      // `hasOptional` also gates the rule between the groups: with nothing on its leading side it
      // would be a stray mark.
      XCTAssertFalse(c.hasOptional)
    }
  }

  // MARK: Title + truncation

  /// A file path's informative end is the file NAME, so it head-truncates — keeping `…/PaneTreeView.swift`
  /// rather than `macapp/Wor…View.swift`. This is the same choice `TerminalStatusBar` made for this exact
  /// string before issue #150 moved it into the title bar, and `.middle` (the first instinct) is wrong
  /// precisely because it eats the name.
  func testFilePathsHeadTruncateAndSplitAtTheFileName() {
    let title = PaneTitlePresentation.title(
      for: diff("macapp/WorkroomApp/Views/PaneTreeView.swift"), tabTitle: "PaneTreeView.swift")
    XCTAssertEqual(title.truncation, .head)
    XCTAssertEqual(title.prefix, "macapp/WorkroomApp/Views/")
    XCTAssertEqual(title.name, "PaneTreeView.swift")
    XCTAssertEqual(title.plain, "macapp/WorkroomApp/Views/PaneTreeView.swift")
  }

  /// A file at the repo root has no directories to dim — the prefix is empty rather than "/" or ".".
  func testRootLevelFileHasNoDimmedPrefix() {
    let title = PaneTitlePresentation.title(for: file("README.md"), tabTitle: "README.md")
    XCTAssertEqual(title.prefix, "")
    XCTAssertEqual(title.name, "README.md")
  }

  /// A shell-set terminal title is front-loaded (`npm run dev — building…`), so it tail-truncates. It
  /// is also shown whole, not split: there is no path to dim.
  func testTerminalTitlesTailTruncate() {
    let title = PaneTitlePresentation.title(
      for: terminal(), tabTitle: "npm run dev — building")
    XCTAssertEqual(title.truncation, .tail)
    XCTAssertEqual(title.prefix, "")
    XCTAssertEqual(title.name, "npm run dev — building")
  }

  /// A changeset has no `filePath` (its inner diff names the file), so it takes the terminal treatment:
  /// the commit subject, tail-truncated.
  func testChangesetUsesTheTabTitleTailTruncated() {
    let title = PaneTitlePresentation.title(for: changeset(), tabTitle: "Add the thing")
    XCTAssertEqual(title.truncation, .tail)
    XCTAssertEqual(title.name, "Add the thing")
  }
}
