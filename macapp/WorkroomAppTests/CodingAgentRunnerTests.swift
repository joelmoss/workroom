import XCTest

@testable import Workroom

/// The inline-agent runner (issue #49, T4): exact argv for the no-tools claude diagnosis, backend
/// capability/selection, and the raw process-result → outcome mapping. The argv was verified to run
/// and return a JSON envelope on the installed claude; here we pin it and the pure classification.
final class CodingAgentRunnerTests: XCTestCase {

  // MARK: argv

  func testClaudeInlineArgvIsNoTools() {
    let inv = CodingAgentInvocationBuilder.claudeInline(prompt: "diagnose this")
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
    let inv = CodingAgentInvocationBuilder.claudeInline(prompt: "the prompt")
    XCTAssertEqual(inv.arguments.last, "the prompt")
    // No flag may follow the prompt (it must be the final positional).
    XCTAssertFalse(inv.arguments.dropLast().contains("the prompt"))
  }

  func testClaudeInlineInjectsSystemPrompt() {
    let inv = CodingAgentInvocationBuilder.claudeInline(systemPrompt: "be terse", prompt: "p")
    // --system-prompt <value> appears immediately before the trailing prompt positional.
    let idx = inv.arguments.firstIndex(of: "--system-prompt")
    XCTAssertNotNil(idx)
    XCTAssertEqual(inv.arguments[idx! + 1], "be terse")
    XCTAssertEqual(inv.arguments.last, "p")
  }

  func testClaudeInlineInjectsModel() {
    let inv = CodingAgentInvocationBuilder.claudeInline(
      model: "claude-haiku-4-5-20251001", prompt: "p")
    let idx = inv.arguments.firstIndex(of: "--model")
    XCTAssertNotNil(idx)
    XCTAssertEqual(inv.arguments[idx! + 1], "claude-haiku-4-5-20251001")
    XCTAssertEqual(inv.arguments.last, "p", "prompt stays the trailing positional")
  }

  func testClaudeInlineOmitsModelWhenNilOrEmpty() {
    XCTAssertFalse(
      CodingAgentInvocationBuilder.claudeInline(prompt: "p").arguments.contains("--model"))
    XCTAssertFalse(
      CodingAgentInvocationBuilder.claudeInline(model: "", prompt: "p").arguments.contains(
        "--model"))
  }

  func testClaudeInlineOmitsSystemPromptWhenNilOrEmpty() {
    XCTAssertFalse(
      CodingAgentInvocationBuilder.claudeInline(prompt: "p").arguments.contains("--system-prompt"))
    XCTAssertFalse(
      CodingAgentInvocationBuilder.claudeInline(systemPrompt: "", prompt: "p").arguments.contains(
        "--system-prompt"))
  }

  // MARK: backend capabilities + selection

  func testOnlyClaudeSupportsInlineDiagnosis() {
    XCTAssertTrue(CodingAgentBackend.claude.supportsInlineDiagnosis)
    XCTAssertFalse(CodingAgentBackend.codex.supportsInlineDiagnosis)
  }

  func testInlineBackendRequiresClaude() {
    XCTAssertEqual(CodingAgentBackend.inlineBackend(installed: [.claude]), .claude)
    XCTAssertEqual(CodingAgentBackend.inlineBackend(installed: [.claude, .codex]), .claude)
    XCTAssertNil(CodingAgentBackend.inlineBackend(installed: [.codex]))
    XCTAssertNil(CodingAgentBackend.inlineBackend(installed: []))
  }

  func testPreferredFallsBackToCodex() {
    XCTAssertEqual(CodingAgentBackend.preferred(installed: [.claude, .codex]), .claude)
    XCTAssertEqual(CodingAgentBackend.preferred(installed: [.codex]), .codex)
    XCTAssertNil(CodingAgentBackend.preferred(installed: []))
  }

  func testDisplayNamesAreSeparateFromExecutables() {
    XCTAssertEqual(CodingAgentBackend.claude.displayName, "Claude")
    XCTAssertEqual(CodingAgentBackend.claude.executable, "claude")
    XCTAssertEqual(CodingAgentBackend.codex.displayName, "Codex")
    XCTAssertEqual(CodingAgentBackend.codex.executable, "codex")
  }

  // MARK: classify

  private func result(_ stdout: String, _ stderr: String, _ code: Int32, timedOut: Bool = false)
    -> CommandResult
  {
    CommandResult(stdout: stdout, stderr: stderr, exitCode: code, timedOut: timedOut)
  }

  func testClassifyTimeoutWinsOverEverything() {
    XCTAssertEqual(CodingAgentRunner.classify(result("partial", "", 0, timedOut: true)), .timedOut)
  }

  func testClassifyExit127IsCliNotFound() {
    XCTAssertEqual(
      CodingAgentRunner.classify(result("", "env: claude: No such file", 127)), .cliNotFound)
  }

  /// A vanished cwd (the workroom deleted mid-action) must classify as `.launchFailed`, never
  /// `.failed(exitCode:)` — `CommandResult.launchFailed` (-1) is a sentinel, not a real exit code,
  /// and never `.cliNotFound` either, which would misreport a missing tool instead of a gone folder.
  func testClassifyLaunchFailedIsNotFailedOrCliNotFound() {
    let launchFailed = result("", "The file couldn't be opened.", CommandResult.launchFailed)
    XCTAssertEqual(CodingAgentRunner.classify(launchFailed), .launchFailed)
  }

  func testClassifyAuthFailure() {
    XCTAssertEqual(
      CodingAgentRunner.classify(result("", "Invalid API key · Please run `claude login`", 1)),
      .notAuthenticated)
  }

  func testClassifyOtherNonZeroFails() {
    let out = CodingAgentRunner.classify(result("", "boom", 2))
    XCTAssertEqual(out, .failed(exitCode: 2, stderr: "boom"))
  }

  /// A killed agent (our own cancellation, an OS kill under memory pressure) must classify as
  /// `.interrupted`, never `.failed(exitCode:)` — `exitCode` on a signalled result is the SIGNAL
  /// number, not a real CLI exit status, so "exit 9" is exactly the nonsense the gh-flap fix ended
  /// elsewhere.
  func testClassifySignaledIsInterruptedNotFailed() {
    let signaled = CommandResult(
      stdout: "", stderr: "", exitCode: 9, timedOut: false, signaled: true)
    XCTAssertEqual(CodingAgentRunner.classify(signaled), .interrupted)
  }

  /// `timedOut` implies `signaled` (the timeout path SIGTERMs), so timeout must win the check order.
  func testClassifyTimeoutWinsOverSignaled() {
    let timedOutAndSignaled = CommandResult(
      stdout: "", stderr: "", exitCode: 15, timedOut: true, signaled: true)
    XCTAssertEqual(CodingAgentRunner.classify(timedOutAndSignaled), .timedOut)
  }

  func testClassifyEmptyStdoutIsEmptyOutput() {
    XCTAssertEqual(CodingAgentRunner.classify(result("   \n", "", 0)), .emptyOutput)
  }

  func testClassifySuccessKeepsRawStdout() {
    let json = #"{"type":"result","result":"port in use"}"#
    XCTAssertEqual(
      CodingAgentRunner.classify(result(json, "some warning on stderr", 0)), .success(stdout: json))
  }

  func testAuthFailureHeuristic() {
    XCTAssertTrue(CodingAgentRunner.isAuthFailure("Error: Unauthorized"))
    XCTAssertTrue(CodingAgentRunner.isAuthFailure("you must authentication first"))
    XCTAssertFalse(CodingAgentRunner.isAuthFailure("ls: no such file or directory"))
  }

  // MARK: composition through the executor seam

  func testDiagnoseInlineRunsClaudeArgvAndMapsResult() async {
    let fake = FakeExecutor(
      stub: CommandResult(
        stdout: #"{"result":"diagnosis"}"#, stderr: "", exitCode: 0, timedOut: false))
    let runner = CodingAgentRunner(executor: fake)

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
    let outcome = await CodingAgentRunner(executor: fake).diagnoseInline(
      prompt: "p", cwd: "/tmp", timeout: 1)
    XCTAssertEqual(outcome, .timedOut)
  }
}

/// Records the last invocation and returns a canned result — proves `CodingAgentRunner` composes the
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
