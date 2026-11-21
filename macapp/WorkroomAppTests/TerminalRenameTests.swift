import XCTest

@testable import Workroom

/// A terminal's name: the one the user gave it, else the title its program sets, else its program and folder
/// (glossary: Terminal name), kept across a quit.
@MainActor
final class TerminalRenameTests: XCTestCase {
  private let target = TerminalTarget(
    id: .workroom(project: "/p", name: "foo"), title: "foo", path: "/tmp", isMissing: false)

  private func makeSessions() -> TerminalPanes {
    let sessions = TerminalPanes()
    sessions.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    sessions.recency = SwitcherRecency()  // never write this suite's tabs into the shared MRU
    return sessions
  }

  private func title(_ sessions: TerminalPanes, _ tab: TerminalTab) -> String? {
    sessions.tab(tab.id, for: target)?.title
  }

  func testWithoutAUserNameTheDefaultTitleShows() {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    XCTAssertEqual(title(sessions, tab), "\(TerminalState.shellName) /tmp")
  }

  /// Value: protects=a name the user typed is not overwritten by the program's title; fails_when=the
  /// live title outranks the user's; seam=TerminalPanes.setUserTitle; no_claim=the prompt UI.
  func testUserNameOverridesTheLiveTitleUntilCleared() throws {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    let surface = try XCTUnwrap(sessions.surface(tab))
    surface.handleTitleChange("vim notes.txt")
    XCTAssertEqual(title(sessions, tab), "vim notes.txt")

    sessions.setUserTitle("Notes", forTab: tab.id, in: target)
    XCTAssertEqual(title(sessions, tab), "Notes")
    surface.handleTitleChange("htop")
    XCTAssertEqual(title(sessions, tab), "Notes", "a new program title does not replace the name")

    sessions.setUserTitle("", forTab: tab.id, in: target)
    XCTAssertEqual(title(sessions, tab), "htop", "clearing brings the live title back")
  }

  func testBlankNameClearsToTheDefaultTitle() {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    sessions.setUserTitle("Build", forTab: tab.id, in: target)
    sessions.setUserTitle("   ", forTab: tab.id, in: target)
    XCTAssertEqual(title(sessions, tab), "\(TerminalState.shellName) /tmp")
  }

  func testNameIsTrimmed() {
    let sessions = makeSessions()
    let tab = sessions.addTab(for: target)
    sessions.setUserTitle("  Build  ", forTab: tab.id, in: target)
    XCTAssertEqual(title(sessions, tab), "Build")
  }

  /// Value: protects=the name survives a quit; fails_when=capture or restore drops `userTitle`;
  /// seam=TabSession capture + TerminalPanes.restore.
  func testNameIsSavedWithTheTabAndComesBack() throws {
    let sessions = makeSessions()
    let named = sessions.addTab(for: target)
    let plain = sessions.addTab(for: target)
    sessions.setUserTitle("Build box", forTab: named.id, in: target)

    let captured = try XCTUnwrap(sessions.sessionCapture(forTargetID: target.id))
    let tabs = captured.tabs.compactMap { TabSession(key: $0.id.uuidString, tab: $0) }
    XCTAssertEqual(tabs.first { $0.key == named.id.uuidString }?.terminal?.userTitle, "Build box")
    XCTAssertNil(tabs.first { $0.key == plain.id.uuidString }?.terminal?.userTitle)

    let restored = makeSessions()
    restored.restore(
      TargetSession(targetID: target.id.encoded, tabs: tabs, terminalCounter: 2), for: target)
    XCTAssertEqual(
      restored.tabs(for: target).map(\.title), ["Build box", "\(TerminalState.shellName) /tmp"])
  }
}
