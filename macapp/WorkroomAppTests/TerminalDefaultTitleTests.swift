import WorkroomWire
import XCTest

@testable import Workroom

/// A terminal's default title (glossary: Terminal name): its program and folder, `<program> <folder>`, shown when the
/// user named it nothing and its program set no title, in every kind of terminal, never numbered.
@MainActor
final class TerminalDefaultTitleTests: XCTestCase {
  private let target = TerminalTarget(
    id: .workroom(project: "/p", name: "foo"), title: "foo", path: "/tmp", isMissing: false)

  private func makeSessions() -> TerminalPanes {
    let sessions = TerminalPanes()
    sessions.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    sessions.recency = SwitcherRecency()
    return sessions
  }

  private func title(_ sessions: TerminalPanes, _ tab: TerminalTab) -> String? {
    sessions.tab(tab.id, for: target)?.title
  }

  private var shell: String { TerminalState.shellName }

  // MARK: The name's shape

  func testTheFolderIsInFullWithTheHomeFolderAsATilde() {
    let home = "/Users/joel"
    func folder(_ path: String) -> String? {
      TerminalState.programAndFolder(program: "zsh", folder: path, home: home).folder
    }
    XCTAssertEqual(folder(home), "~")
    XCTAssertEqual(folder("/Users/joel/"), "~")
    XCTAssertEqual(folder("/Users/joel/dev/workroom/macapp"), "~/dev/workroom/macapp")
    XCTAssertEqual(
      folder("/Users/joely/dev"), "/Users/joely/dev", "only a whole folder is the home folder")
    XCTAssertEqual(folder("/etc"), "/etc")
  }

  func testTheProgramAndFolderAreTwoPartsJoinedByASpaceInPlainText() {
    let title = TerminalState.programAndFolder(
      program: "vim", folder: "/Users/joel/dev/workroom", home: "/Users/joel")
    XCTAssertEqual(title, TerminalTitle(name: "vim", folder: "~/dev/workroom"))
    XCTAssertEqual(title.text, "vim ~/dev/workroom", "no separator but a space")
    XCTAssertEqual(TerminalTitle(name: "Notes").text, "Notes")
  }

  func testOnlyTheDefaultTitleHasAFolderPart() throws {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    let surface = try XCTUnwrap(sessions.surface(tab))
    func parts() -> TerminalTitle? { sessions.tab(tab.id, for: target)?.content.titleParts }
    XCTAssertEqual(parts(), TerminalTitle(name: shell, folder: "/tmp"), "the default, in parts")
    surface.handleTitleChange("vim notes.txt")
    XCTAssertEqual(parts(), TerminalTitle(name: "vim notes.txt"), "a program's title is whole")
    sessions.setUserTitle("Notes", forTab: tab.id, in: target)
    XCTAssertEqual(parts(), TerminalTitle(name: "Notes"), "the user's name is whole")
    XCTAssertEqual(
      sessions.terminalTitles(forTargetID: target.id), [TerminalTitle(name: "Notes")],
      "what a standalone terminal's row draws")
  }

  func testAProgramIsNamedShort() {
    XCTAssertEqual(TerminalState.programName("-zsh"), "zsh", "a login shell's argv[0]")
    XCTAssertEqual(TerminalState.programName("/opt/homebrew/bin/nvim"), "nvim")
    XCTAssertEqual(TerminalState.programName("claude"), "claude")
    XCTAssertNil(TerminalState.programName(""))
    XCTAssertEqual(
      ProcessEnvironment.command(fromArgv: ["node", "--no-warnings", "/usr/local/bin/claude"]),
      "/usr/local/bin/claude", "an interpreter's script is the program")
    XCTAssertEqual(ProcessEnvironment.command(fromArgv: ["-zsh"]), "-zsh")
    XCTAssertEqual(ProcessEnvironment.command(fromArgv: ["vim", "notes.txt"]), "vim")
  }

  func testADaemonBackedPanesProgramIsItsSessionsCommand() {
    let descriptor = SessionDescriptor(
      identifier: SessionIdentifier(UUID()), shellProcessID: 1, ttyDevice: 0,
      workingDirectory: "/tmp", isAttached: true,
      metadata: [SessionEnvironmentEntry(key: "command", value: "-zsh")])
    XCTAssertEqual(PaneLiveState.program(from: descriptor), "zsh")
    XCTAssertNil(PaneLiveState.program(from: nil))
  }

  // MARK: Precedence and what it follows

  func testANewTerminalIsTitledByItsShellAndFolderNotNumbered() {
    let sessions = makeSessions()
    let first = sessions.addTab(for: target)
    let second = sessions.addTab(for: target)
    XCTAssertEqual(title(sessions, first), "\(shell) /tmp")
    XCTAssertEqual(title(sessions, second), "\(shell) /tmp", "no number keeps them apart")
    XCTAssertEqual(sessions.defaultTitle(ofTab: first.id, inTarget: target.id), "\(shell) /tmp")
  }

  func testTheTitleFollowsTheFolderAndTheForegroundProgram() async throws {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    let surface = try XCTUnwrap(sessions.surface(tab))

    surface.handlePwd("/tmp/sub")
    XCTAssertEqual(title(sessions, tab), "\(shell) /tmp/sub")

    // Read again when a command finishes: the program at the prompt may be another shell now.
    surface.foregroundProcessNameForTesting = "fish"
    surface.handleCommandFinished(rawExitCode: 0)
    try await waitFor { self.title(sessions, tab) == "fish /tmp/sub" }
  }

  func testTheFirstPromptReadsTheProgram() async throws {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    let surface = try XCTUnwrap(sessions.surface(tab))
    surface.foregroundProcessNameForTesting = "bash"
    surface.handlePwd("/tmp")
    surface.handleTitleChange("/tmp")  // the prompt's directory title, which shows nothing
    try await waitFor { self.title(sessions, tab) == "bash /tmp" }
  }

  func testTheProgramsTitleAndTheUsersNameOutrankIt() throws {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    let surface = try XCTUnwrap(sessions.surface(tab))
    surface.handleTitleChange("vim notes.txt")
    XCTAssertEqual(title(sessions, tab), "vim notes.txt")
    sessions.setUserTitle("Notes", forTab: tab.id, in: target)
    XCTAssertEqual(title(sessions, tab), "Notes")
    sessions.setUserTitle("", forTab: tab.id, in: target)
    surface.handleCommandFinished(rawExitCode: 0)
    XCTAssertEqual(title(sessions, tab), "\(shell) /tmp", "the default once both are gone")
  }

  func testAnOldNumberedNameIsNeverShownButARunTabKeepsItsName() {
    XCTAssertTrue(TerminalState.isNumberedName("Terminal 2"))
    XCTAssertTrue(TerminalState.isNumberedName("Terminal"))
    XCTAssertFalse(TerminalState.isNumberedName("Run"))
    XCTAssertFalse(TerminalState.isNumberedName("Terminal two"))
    let restored = TerminalState(
      defaultTitle: "Terminal 4", launch: .shell, launchDirectory: "/tmp")
    XCTAssertEqual(TabContent.terminal(restored).title, "\(shell) /tmp")
    let run = TerminalState(defaultTitle: "Run", launch: .shell, launchDirectory: "/tmp")
    XCTAssertEqual(TabContent.terminal(run).title, "Run")
  }

  private func waitFor(
    _ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    for _ in 0..<200 where !condition() {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), "timed out", file: file, line: line)
  }
}
