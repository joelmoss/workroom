import XCTest

@testable import Workroom

final class AgentVCSProtocolTests: XCTestCase {
  func testAbsentContentIsDifferentFromMissingResult() throws {
    let content = try AgentVCSReply<String?>.decode(Data(#"{"version":1,"result":null}"#.utf8))
    XCTAssertNil(content)
    XCTAssertThrowsError(try AgentVCSReply<String?>.decode(Data(#"{"version":1}"#.utf8))) {
      XCTAssertTrue($0 is HostConnectionError)
    }
  }

  func testMalformedAndWrongVersionRepliesAreServiceFailures() {
    for text in [
      "not JSON", #"{"version":99,"result":"text"}"#, #"{"version":1,"result":[]}"#,
      #"{"version":1,"error":"Unknown"}"#, #"{"version":1,"error":{}}"#,
      #"{"version":1,"error":{"Unknown":"failure"}}"#,
    ] {
      XCTAssertThrowsError(try AgentVCSReply<String>.decode(Data(text.utf8))) {
        XCTAssertTrue($0 is HostConnectionError)
      }
    }
  }

  func testNativeErrorMeaningsSurviveTheWire() {
    let cases: [(String, VCSError)] = [
      (#"{"version":1,"error":"LockContention"}"#, .lockContention),
      (#"{"version":1,"error":"StaleSnapshot"}"#, .staleSnapshot),
      (#"{"version":1,"error":{"UnsupportedRepo":"gone"}}"#, .unsupportedRepo("gone")),
      (#"{"version":1,"error":{"PartialData":"retry"}}"#, .partialData("retry")),
      (#"{"version":1,"error":{"Io":"gone"}}"#, .io("gone")),
    ]
    for (text, expected) in cases {
      XCTAssertThrowsError(try AgentVCSReply<String>.decode(Data(text.utf8))) {
        XCTAssertEqual($0 as? VCSError, expected)
      }
    }
  }

  /// `launchFailed` means "the command never ran", and `CLIVCSWriter.classify` checks it before
  /// everything else. A transport failure does NOT know that: there is no cancel message in the
  /// protocol, so a cancelled or disconnected `git push` runs to completion host-side. Reporting it
  /// as `launchFailed` told the user nothing had happened and invited a retry that double-applies.
  func testTransportFailureIsNotReportedAsNeverHavingRun() {
    let lost = AgentCommandRunner.outcomeUnknown(HostConnectionError.connectionLost)
    XCTAssertNotEqual(lost.exitCode, CommandResult.launchFailed)
    XCTAssertTrue(lost.signaled)
    // Not `timedOut`: that offers Retry, and nobody knows the outcome.
    XCTAssertFalse(lost.timedOut)
    // The existing error already says the right thing; it used to be discarded.
    XCTAssertTrue(lost.stderr.contains("may have completed"))

    let cancelled = AgentCommandRunner.outcomeUnknown(CancellationError())
    XCTAssertNotEqual(cancelled.exitCode, CommandResult.launchFailed)
    XCTAssertTrue(cancelled.signaled)
    XCTAssertTrue(cancelled.stderr.contains("may have completed"))

    // A request refused before it left this process genuinely never ran, and keeps the old value.
    XCTAssertEqual(
      AgentCommandRunner.neverRan("too large").exitCode, CommandResult.launchFailed)
  }

  /// Both paths must hand the child the SAME environment. Forwarding only `PATH` let the child
  /// inherit the rest from a daemon "negotiated with, never replaced", so an agent-routed commit
  /// could be authored under the identity of whichever app launch first spawned it.
  func testAgentAndNativeSendTheSameChildEnvironment() {
    for network in [false, true] {
      let env = StatusCommandRunner.childEnvironment(network: network)
      // The subprocess baseline every consumer's stderr classification depends on.
      XCTAssertEqual(env["LC_ALL"], "C")
      XCTAssertEqual(env["GIT_TERMINAL_PROMPT"], "0")
      XCTAssertEqual(env["GIT_OPTIONAL_LOCKS"], "0")
      XCTAssertNil(env["GIT_EXTERNAL_DIFF"])
      XCTAssertEqual(env["PATH"], ShellEnvironment.path())
      // Identity/config carriers reach the child on EVERY command, not just network ones.
      for key in ["HOME", "USER"] where ProcessInfo.processInfo.environment[key] != nil {
        XCTAssertEqual(env[key], ProcessInfo.processInfo.environment[key])
      }
    }
    // The fail-fast ssh invariant is still network-only.
    XCTAssertNil(StatusCommandRunner.childEnvironment(network: false)["SSH_ASKPASS_REQUIRE"])
    XCTAssertEqual(
      StatusCommandRunner.childEnvironment(network: true)["SSH_ASKPASS_REQUIRE"], "never")
  }

  /// These OUTRANK the working directory, so an inherited one silently redirects a command aimed at
  /// one repository into another — a commit requested in workroom A landing in repo B, reported as
  /// success. Every caller addresses a repository by `directory`, so inheriting them is only ever
  /// wrong. Asserted for both paths because they now share one environment: sending the app's whole
  /// environment to the agent would otherwise have carried these across too.
  func testRepositoryOverridesNeverReachTheChild() {
    let keys = [
      "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
      "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    ]
    for key in keys { setenv(key, "/tmp/some-other-repo", 1) }
    defer { for key in keys { unsetenv(key) } }
    for network in [false, true] {
      let env = StatusCommandRunner.childEnvironment(network: network)
      for key in keys {
        XCTAssertNil(env[key], "\(key) reached the child (network: \(network))")
      }
    }
  }
}
