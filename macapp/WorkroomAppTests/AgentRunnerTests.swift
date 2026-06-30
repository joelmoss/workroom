import XCTest

@testable import Workroom

/// The inline-agent runner (issue #49, T4): exact argv for the no-tools claude diagnosis, backend
/// capability/selection, and the raw process-result → outcome mapping. The argv was verified to run
/// and return a JSON envelope on the installed claude; here we pin it and the pure classification.
final class AgentRunnerTests: XCTestCase {

  // MARK: argv

  func testClaudeInlineArgvIsNoTools() {
    let inv = AgentInvocationBuilder.claudeInline(prompt: "diagnose this")
    XCTAssertEqual(inv.executable, "claude")
    XCTAssertEqual(
      inv.arguments,
      [
        "--print",
        "--output-format", "json",
        "--permission-mode", "plan",
        "--allowed-tools", "none",
        "--no-session-persistence",
        "diagnose this",
      ])
  }

  func testClaudeInlinePromptIsTrailingPositional() {
    let inv = AgentInvocationBuilder.claudeInline(prompt: "the prompt")
    XCTAssertEqual(inv.arguments.last, "the prompt")
    // No flag may follow the prompt (it must be the final positional).
    XCTAssertFalse(inv.arguments.dropLast().contains("the prompt"))
  }

  func testClaudeInlineInjectsSystemPrompt() {
    let inv = AgentInvocationBuilder.claudeInline(systemPrompt: "be terse", prompt: "p")
    // --system-prompt <value> appears immediately before the trailing prompt positional.
    let idx = inv.arguments.firstIndex(of: "--system-prompt")
    XCTAssertNotNil(idx)
    XCTAssertEqual(inv.arguments[idx! + 1], "be terse")
    XCTAssertEqual(inv.arguments.last, "p")
  }

  func testClaudeInlineOmitsSystemPromptWhenNilOrEmpty() {
    XCTAssertFalse(
      AgentInvocationBuilder.claudeInline(prompt: "p").arguments.contains("--system-prompt"))
    XCTAssertFalse(
      AgentInvocationBuilder.claudeInline(systemPrompt: "", prompt: "p").arguments.contains(
        "--system-prompt"))
  }

  // MARK: backend capabilities + selection

  func testOnlyClaudeSupportsInlineDiagnosis() {
    XCTAssertTrue(AgentBackend.claude.supportsInlineDiagnosis)
    XCTAssertFalse(AgentBackend.codex.supportsInlineDiagnosis)
  }

  func testInlineBackendRequiresClaude() {
    XCTAssertEqual(AgentBackend.inlineBackend(installed: [.claude]), .claude)
    XCTAssertEqual(AgentBackend.inlineBackend(installed: [.claude, .codex]), .claude)
    XCTAssertNil(AgentBackend.inlineBackend(installed: [.codex]))
    XCTAssertNil(AgentBackend.inlineBackend(installed: []))
  }

  func testPreferredFallsBackToCodex() {
    XCTAssertEqual(AgentBackend.preferred(installed: [.claude, .codex]), .claude)
    XCTAssertEqual(AgentBackend.preferred(installed: [.codex]), .codex)
    XCTAssertNil(AgentBackend.preferred(installed: []))
  }

  // MARK: classify

  private func result(_ stdout: String, _ stderr: String, _ code: Int32, timedOut: Bool = false)
    -> CommandResult
  {
    CommandResult(stdout: stdout, stderr: stderr, exitCode: code, timedOut: timedOut)
  }

  func testClassifyTimeoutWinsOverEverything() {
    XCTAssertEqual(AgentRunner.classify(result("partial", "", 0, timedOut: true)), .timedOut)
  }

  func testClassifyExit127IsCliNotFound() {
    XCTAssertEqual(AgentRunner.classify(result("", "env: claude: No such file", 127)), .cliNotFound)
  }

  func testClassifyAuthFailure() {
    XCTAssertEqual(
      AgentRunner.classify(result("", "Invalid API key · Please run `claude login`", 1)),
      .notAuthenticated)
  }

  func testClassifyOtherNonZeroFails() {
    let out = AgentRunner.classify(result("", "boom", 2))
    XCTAssertEqual(out, .failed(exitCode: 2, stderr: "boom"))
  }

  func testClassifyEmptyStdoutIsEmptyOutput() {
    XCTAssertEqual(AgentRunner.classify(result("   \n", "", 0)), .emptyOutput)
  }

  func testClassifySuccessKeepsRawStdout() {
    let json = #"{"type":"result","result":"port in use"}"#
    XCTAssertEqual(
      AgentRunner.classify(result(json, "some warning on stderr", 0)), .success(stdout: json))
  }

  func testAuthFailureHeuristic() {
    XCTAssertTrue(AgentRunner.isAuthFailure("Error: Unauthorized"))
    XCTAssertTrue(AgentRunner.isAuthFailure("you must authentication first"))
    XCTAssertFalse(AgentRunner.isAuthFailure("ls: no such file or directory"))
  }

  // MARK: composition through the executor seam

  func testDiagnoseInlineRunsClaudeArgvAndMapsResult() async {
    let fake = FakeExecutor(
      stub: CommandResult(
        stdout: #"{"result":"diagnosis"}"#, stderr: "", exitCode: 0, timedOut: false))
    let runner = AgentRunner(executor: fake)

    let outcome = await runner.diagnoseInline(
      prompt: "why did it fail", cwd: "/tmp/proj", timeout: 30)

    XCTAssertEqual(outcome, .success(stdout: #"{"result":"diagnosis"}"#))
    // Composition: the runner ran the no-tools claude argv in the given cwd via the injected executor.
    XCTAssertEqual(fake.lastExecutable, "claude")
    XCTAssertEqual(fake.lastArgs?.first, "--print")
    XCTAssertEqual(fake.lastArgs?.last, "why did it fail")
    XCTAssertTrue(fake.lastArgs?.contains("none") ?? false)
    XCTAssertEqual(fake.lastDirectory, "/tmp/proj")
    XCTAssertEqual(fake.lastTimeout, 30)
  }

  func testDiagnoseInlineMapsTimeout() async {
    let fake = FakeExecutor(
      stub: CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: true))
    let outcome = await AgentRunner(executor: fake).diagnoseInline(
      prompt: "p", cwd: "/tmp", timeout: 1)
    XCTAssertEqual(outcome, .timedOut)
  }
}

/// Records the last invocation and returns a canned result — proves `AgentRunner` composes the
/// executor seam without spawning a real CLI.
private final class FakeExecutor: StatusCommandRunning, @unchecked Sendable {
  let stub: CommandResult
  private(set) var lastExecutable: String?
  private(set) var lastArgs: [String]?
  private(set) var lastDirectory: String?
  private(set) var lastTimeout: TimeInterval?

  init(stub: CommandResult) { self.stub = stub }

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    lastExecutable = executable
    lastArgs = args
    lastDirectory = directory
    lastTimeout = timeout
    return stub
  }
}
