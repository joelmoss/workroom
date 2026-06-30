import XCTest

@testable import Workroom

/// On-demand quality eval for the inline agent's diagnosis (issue #49, T11). SKIPPED by default so
/// `make app-test` stays hermetic — it makes REAL, paid, networked `claude` calls. Run explicitly by
/// dropping a sentinel file the test host can see (CLI env vars don't propagate to the unit-test
/// process under `xcodebuild test`):
///
///     touch /tmp/workroom-run-agent-eval
///     xcodebuild ... -only-testing:WorkroomAppTests/AgentDiagnosisEvalTests test
///     rm /tmp/workroom-run-agent-eval
///
/// (Or set `WORKROOM_RUN_AGENT_EVAL=1` in the scheme's test action when running from Xcode.)
/// It asserts the diagnosis names the right cause/fix for a few
/// canonical failures — the guard against prompt regressions, and the check that fixes land in the
/// structured `fix` field (the T8 note). Codex is Investigate-only (no headless no-tools mode), so
/// the inline eval is claude-only.
final class AgentDiagnosisEvalTests: XCTestCase {
  private struct Scenario {
    let name: String
    let command: String
    let exitCode: Int32
    let output: String
    /// The diagnosis (summary + fix + detail) must mention at least one of these (case-insensitive).
    let expectAny: [String]
    /// Whether a structured `fix` command is expected (actionable scenarios).
    let expectsFix: Bool
  }

  private let scenarios: [Scenario] = [
    Scenario(
      name: "busy-port", command: "rails server", exitCode: 1,
      output: """
        => Booting Puma
        => Rails 7.1.0 application starting in development
        Address already in use - bind(2) for "127.0.0.1" port 3000 (Errno::EADDRINUSE)
        """,
      expectAny: ["port", "3000", "in use", "lsof", "address"], expectsFix: true),
    Scenario(
      name: "failing-test", command: "npm test", exitCode: 1,
      output: """
        FAIL src/auth.test.ts
          ● login › returns a token
            expect(received).toBe(expected)
            Expected: 200
            Received: 401
        Tests: 1 failed, 4 passed, 5 total
        """,
      expectAny: ["test", "fail", "401", "assert", "expect", "auth"], expectsFix: false),
    Scenario(
      name: "missing-dep", command: "npm run dev", exitCode: 127,
      output: "sh: line 1: vite: command not found",
      expectAny: ["install", "missing", "not found", "dependency", "node_modules", "vite"],
      expectsFix: true),
  ]

  /// The on-demand gate: a fixed sentinel file (reliable across the shell ↔ test-host boundary) or
  /// the scheme env var.
  private var evalEnabled: Bool {
    FileManager.default.fileExists(atPath: "/tmp/workroom-run-agent-eval")
      || ProcessInfo.processInfo.environment["WORKROOM_RUN_AGENT_EVAL"] == "1"
  }

  func testDiagnosisQuality() async throws {
    try XCTSkipUnless(
      evalEnabled,
      "Eval skipped. Run: touch /tmp/workroom-run-agent-eval (needs an authenticated `claude`).")

    let runner = AgentRunner()
    for scenario in scenarios {
      let prompt = AgentPrompt.userMessage(
        command: scenario.command, cwd: "/tmp/project", exitCode: scenario.exitCode, shell: "zsh",
        output: scenario.output)
      let outcome = await runner.diagnoseInline(
        systemPrompt: AgentPrompt.systemPrompt, model: "claude-haiku-4-5-20251001", prompt: prompt,
        cwd: NSTemporaryDirectory(), timeout: 90)

      guard case .success(let stdout) = outcome,
        let diagnosis = AgentPrompt.parse(envelopeJSON: stdout)
      else {
        XCTFail("[\(scenario.name)] expected a parsed diagnosis, got \(outcome)")
        continue
      }

      let haystack = [diagnosis.summary, diagnosis.fixCommand ?? "", diagnosis.detail ?? ""]
        .joined(separator: " ").lowercased()
      XCTAssertTrue(
        scenario.expectAny.contains { haystack.contains($0.lowercased()) },
        "[\(scenario.name)] diagnosis should mention one of \(scenario.expectAny). "
          + "summary=\(diagnosis.summary) | fix=\(diagnosis.fixCommand ?? "nil")")
      if scenario.expectsFix {
        XCTAssertNotNil(
          diagnosis.fixCommand,
          "[\(scenario.name)] expected a structured `fix` command, not prose. "
            + "summary=\(diagnosis.summary) detail=\(diagnosis.detail ?? "nil")")
      }
      // Surface the result so an on-demand run shows what each scenario produced.
      print(
        "EVAL[\(scenario.name)] summary=\(diagnosis.summary) | fix=\(diagnosis.fixCommand ?? "nil")"
      )
    }
  }
}
