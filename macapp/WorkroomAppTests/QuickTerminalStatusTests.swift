import XCTest

@testable import Workroom

/// The Quick Terminal's footer state: the shell's folder, its branch and the running agent, which
/// a pane gets from `TerminalSessions`.
@MainActor
final class QuickTerminalStatusTests: XCTestCase {
  private func makeStatus(cwd: String = "/a") -> QuickTerminalStatus {
    QuickTerminalStatus(cwd: cwd) { path in
      if path == "/slow" { try? await Task.sleep(for: .milliseconds(300)) }
      return path == "/not-a-repo" ? nil : "branch\(path)"
    }
  }

  private func surface(running process: String?) -> GhosttySurfaceView {
    let surface = GhosttySurfaceView(workingDirectory: "/tmp", command: nil, spawnsSurface: false)
    surface.foregroundProcessNameForTesting = process
    return surface
  }

  func testBranchFollowsTheFolder() async {
    let status = makeStatus()
    await status.branchLookupFinished()
    XCTAssertEqual(status.branch, "branch/a")

    status.cwdChanged("/not-a-repo")
    await status.branchLookupFinished()
    XCTAssertNil(status.branch, "no branch outside a repository")
  }

  func testANewerFolderWinsOverASlowLookup() async throws {
    let status = makeStatus(cwd: "/slow")
    status.cwdChanged("/b")
    await status.branchLookupFinished()
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(status.branch, "branch/b", "the stale /slow answer never lands")
  }

  /// The checked-out branch, as a `git switch` in the shell would change it.
  private final class Checkout: @unchecked Sendable {
    var branch = "main"
  }

  func testCommandFinishedRereadsTheBranch() async {
    let checkout = Checkout()
    let status = QuickTerminalStatus(cwd: "/a") { _ in checkout.branch }
    await status.branchLookupFinished()
    XCTAssertEqual(status.branch, "main")

    checkout.branch = "feature"
    status.commandFinished()
    await status.branchLookupFinished()
    XCTAssertEqual(status.branch, "feature", "same folder, new branch after `git switch`")
  }

  func testClaudeByProcessReadsItsProfile() {
    let status = makeStatus()
    status.titleChanged("claude", on: surface(running: "claude"))
    XCTAssertEqual(status.backend, .claude)
    // No live process in a test surface, so no environment to read: the default login, as
    // workroomd reports an unreadable one.
    XCTAssertEqual(status.claudeProfile, .reported(""))
  }

  func testClaudeByTitleAloneNamesNoAccount() {
    let status = makeStatus()
    status.titleChanged("claude", on: surface(running: "zsh"))
    XCTAssertEqual(status.backend, .claude)
    XCTAssertEqual(status.claudeProfile, .notReported)
  }

  func testCodexHasNoProfileAndFinishingClearsTheAgent() {
    let status = makeStatus()
    status.titleChanged("codex", on: surface(running: "codex"))
    XCTAssertEqual(status.backend, .codex)
    XCTAssertNil(status.claudeProfile)

    status.commandFinished()
    XCTAssertNil(status.backend)
    status.titleChanged("vim notes.md", on: surface(running: "vim"))
    XCTAssertNil(status.backend, "an ordinary program is no agent")
  }
}

final class ProcessEnvironmentTests: XCTestCase {
  /// argc 2, exec path + padding, two argv strings, then the environment and trailing padding.
  private func procargs(_ argv: [String], environment: [String]) -> [UInt8] {
    var argc = Int32(argv.count)
    var buffer = withUnsafeBytes(of: &argc) { Array($0) }
    buffer += Array("/bin/exec".utf8) + [0, 0, 0]
    for string in argv + environment { buffer += Array(string.utf8) + [0] }
    return buffer + [0, 0]
  }

  func testFindsTheKeyAfterArgv() {
    let buffer = procargs(
      ["claude", "CLAUDE_CONFIG_DIR=/argv-not-env"],
      environment: ["PATH=/bin", "CLAUDE_CONFIG_DIR=/x/sessions/2-a@b.c", "CLAUDE=no"])
    XCTAssertEqual(
      ProcessEnvironment.value("CLAUDE_CONFIG_DIR", inProcargs: buffer), "/x/sessions/2-a@b.c",
      "argv that looks like an entry is skipped")
    XCTAssertNil(ProcessEnvironment.value("CLAUDE_CONFIG", inProcargs: buffer), "whole key only")
    XCTAssertEqual(
      ProcessEnvironment.value(
        "CLAUDE_CONFIG_DIR", inProcargs: procargs(["claude"], environment: ["CLAUDE_CONFIG_DIR="])),
      "", "set empty is not unset")
    XCTAssertNil(ProcessEnvironment.value("PATH", inProcargs: [1, 0]), "a short buffer")
  }

  func testReadsALiveProcess() {
    XCTAssertEqual(
      ProcessEnvironment.value("HOME", pid: getpid()), ProcessInfo.processInfo.environment["HOME"])
    XCTAssertNil(ProcessEnvironment.value("HOME", pid: 0))
  }
}
