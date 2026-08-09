import XCTest

@testable import Workroom

/// The command a Resume click runs (issue #145).
///
/// Small tests guarding an expensive mistake: these two argv forms are the difference between "pick
/// a conversation" and "silently reopen whichever one was last, in both panes".
final class AgentResumeInvocationTests: XCTestCase {

  func testClaudeResumesThroughThePicker() {
    let invocation = AgentInvocationBuilder.resume(.claude)
    XCTAssertEqual(invocation.executable, "claude")
    XCTAssertEqual(invocation.arguments, ["--resume"])
    XCTAssertEqual(invocation.commandLine, "claude --resume")
  }

  func testCodexResumesThroughThePicker() {
    let invocation = AgentInvocationBuilder.resume(.codex)
    XCTAssertEqual(invocation.executable, "codex")
    XCTAssertEqual(invocation.arguments, ["resume"])
    XCTAssertEqual(invocation.commandLine, "codex resume")
  }

  /// **The whole point of the feature.** `claude --continue` and `codex resume --last` both reopen
  /// the newest conversation *for the current directory*, and two agent panes in one workroom share
  /// a directory — so both panes would land in the same conversation, confidently and wrongly. The
  /// app cannot know which pane owned which session, so it asks.
  func testNeitherAgentEverSkipsThePicker() {
    for backend in AgentBackend.allCases {
      let invocation = AgentInvocationBuilder.resume(backend)
      XCTAssertFalse(
        invocation.arguments.contains("--continue"), "\(backend) must not auto-continue")
      XCTAssertFalse(invocation.arguments.contains("-c"), "\(backend) must not auto-continue")
      XCTAssertFalse(invocation.arguments.contains("--last"), "\(backend) must not auto-resume")
      XCTAssertFalse(invocation.commandLine.contains("--continue"))
      XCTAssertFalse(invocation.commandLine.contains("--last"))
    }
  }

  /// Nothing read off disk reaches the command line, but the join is the place a future caller could
  /// change that, so it is pinned.
  func testCommandLineQuotesOnlyWhatNeedsIt() {
    XCTAssertEqual(
      AgentInvocation(executable: "claude", arguments: ["--model", "sonnet"]).commandLine,
      "claude --model sonnet")
    XCTAssertEqual(
      AgentInvocation(executable: "claude", arguments: ["hello world"]).commandLine,
      "claude 'hello world'")
    XCTAssertEqual(
      AgentInvocation(executable: "claude", arguments: ["it's"]).commandLine,
      #"claude 'it'\''s'"#)
    XCTAssertEqual(
      AgentInvocation(executable: "claude", arguments: ["; rm -rf /"]).commandLine,
      "claude '; rm -rf /'")
    XCTAssertEqual(
      AgentInvocation(executable: "claude", arguments: [""]).commandLine, "claude ''")
  }

  func testDisplayNamesAreSeparateFromExecutables() {
    XCTAssertEqual(AgentBackend.claude.displayName, "Claude")
    XCTAssertEqual(AgentBackend.claude.executable, "claude")
    XCTAssertEqual(AgentBackend.codex.displayName, "Codex")
    XCTAssertEqual(AgentBackend.codex.executable, "codex")
  }
}
