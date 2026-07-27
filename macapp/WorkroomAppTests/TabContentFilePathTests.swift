import XCTest

@testable import Workroom

/// `TabContent.filePath` (issue #136) — the single source for the pane footer's path segment and the
/// tab chip's tooltip. It sits beside `TerminalTab.title`, which takes the `lastPathComponent` of the
/// *same* field; these assertions pin that the two answers stay different, which is the whole point:
/// the chip may say `user.rb`, but the footer and the tooltip must say `app/models/user.rb`.
///
/// The rendering half can't be asserted here — a unit-test process has no accessibility tree for a
/// hosted SwiftUI view, and a SwiftUI `Text` isn't an inspectable AppKit subview (see
/// `HistoryCommitCardTests`). That's `DiffViewerUITests` / `ChangesPanelUITests`.
@MainActor
final class TabContentFilePathTests: XCTestCase {

  // MARK: Kinds that HAVE a file

  func testDiffKeepsTheWholeRelativePath() {
    let content = TabContent.diff(
      DiffDescriptor(
        path: "app/models/user.rb", change: .modified, source: .gitWorktree, isPreview: false))
    XCTAssertEqual(
      content.filePath, "app/models/user.rb",
      "the footer needs the full path — the basename is what issue #136 says isn't enough")
  }

  func testFileKeepsTheWholeRelativePath() {
    let content = TabContent.file(FileDescriptor(path: "config/routes.rb", isPreview: false))
    XCTAssertEqual(content.filePath, "config/routes.rb")
  }

  /// A root-level file has no directory, so the path IS the basename and the footer repeats the chip.
  /// Not a bug — just the degenerate case, pinned so nobody "fixes" it into nil.
  func testRootLevelFileIsItsOwnPath() {
    let content = TabContent.file(FileDescriptor(path: "Gemfile", isPreview: false))
    XCTAssertEqual(content.filePath, "Gemfile")
  }

  /// The preview flag is presentation, not identity — a previewed file names the same path.
  func testPreviewFlagDoesNotChangeThePath() {
    let content = TabContent.file(FileDescriptor(path: "config/routes.rb", isPreview: true))
    XCTAssertEqual(content.filePath, "config/routes.rb")
  }

  /// The path is the file's, not the revision's: the same file from a commit reports the same path.
  func testCommitSourcedDiffReportsTheSamePath() {
    let content = TabContent.diff(
      DiffDescriptor(
        path: "app/models/user.rb", change: .modified, source: .commit("7d74470b"),
        isPreview: false))
    XCTAssertEqual(content.filePath, "app/models/user.rb")
  }

  // MARK: Kinds that have NO file

  /// A changeset's in-pane `DiffViewer` header already names the selected file, so the footer stays
  /// out of it — even though the descriptor does carry a `selectedPath`.
  func testChangesetHasNoFooterPath() {
    let content = TabContent.changeset(
      ChangesetDescriptor(
        commitID: "7d74470b", title: "feat: add session login", isPreview: false,
        selectedPath: "app/models/user.rb"))
    XCTAssertNil(
      content.filePath,
      "a changeset's own file header owns the path — the footer would duplicate it")
  }

  func testTerminalHasNoFooterPath() {
    let content = TabContent.terminal(
      TerminalState(
        view: GhosttySurfaceView(workingDirectory: "/tmp", spawnsSurface: false),
        defaultTitle: "zsh"))
    XCTAssertNil(content.filePath, "a terminal's footer shows its cwd, not a file")
  }

  // MARK: The divergence issue #136 is about

  /// The chip and the footer must disagree: same descriptor, basename vs whole path. If these ever
  /// return the same thing for a nested file, the footer has stopped adding information.
  func testTitleIsTheBasenameWhileFilePathIsWhole() {
    let tab = TerminalTab.diff(
      DiffDescriptor(
        path: "app/models/user.rb", change: .modified, source: .gitWorktree, isPreview: false))
    XCTAssertEqual(tab.title, "user.rb")
    XCTAssertEqual(tab.filePath, "app/models/user.rb")
  }

  /// `TerminalTab.filePath` is a forward to the content's — a terminal tab has none.
  func testTerminalTabForwardsNoPath() {
    let tab = TerminalTab.terminal(
      view: GhosttySurfaceView(workingDirectory: "/tmp", spawnsSurface: false),
      defaultTitle: "zsh")
    XCTAssertNil(tab.filePath)
  }
}
