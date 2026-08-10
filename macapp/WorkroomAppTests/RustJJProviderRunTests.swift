import XCTest

@testable import Workroom

/// `RustJJProvider.run` — the CLI shell-out helper a few native-provider methods fall back to.
private struct StubRunner: StatusCommandRunning {
  let result: CommandResult
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  { result }
}

final class RustJJProviderRunTests: XCTestCase {
  /// A signalled result must throw a distinct "was interrupted" error, never the generic
  /// exit-code message — `result.exitCode` on a signalled result is the SIGNAL number, not a real
  /// CLI exit status, so "jj exited 9" is exactly the nonsense class the gh-flap fix ended
  /// elsewhere.
  func testSignaledResultThrowsInterruptedNotExitCode() async {
    let runner = StubRunner(
      result: CommandResult(stdout: "", stderr: "", exitCode: 9, timedOut: false, signaled: true))
    do {
      _ = try await RustJJProvider.run(
        "jj", ["log"], cwd: URL(fileURLWithPath: "/tmp"), runner: runner)
      XCTFail("expected a throw")
    } catch let error as VCSError {
      guard case .io(let message) = error else { return XCTFail("expected .io, got \(error)") }
      XCTAssertEqual(message, "jj was interrupted")
      XCTAssertFalse(
        message.contains("exited 9"), "must not read the signal number as an exit code")
    } catch {
      XCTFail("expected VCSError.io, got \(error)")
    }
  }

  /// The un-signalled path is unchanged: a real non-zero exit still reports its exit code.
  func testOrdinaryNonZeroExitStillReportsExitCode() async {
    let runner = StubRunner(
      result: CommandResult(
        stdout: "", stderr: "boom", exitCode: 1, timedOut: false, signaled: false))
    do {
      _ = try await RustJJProvider.run(
        "jj", ["log"], cwd: URL(fileURLWithPath: "/tmp"), runner: runner)
      XCTFail("expected a throw")
    } catch let error as VCSError {
      guard case .io(let message) = error else { return XCTFail("expected .io, got \(error)") }
      XCTAssertEqual(message, "jj exited 1: boom")
    } catch {
      XCTFail("expected VCSError.io, got \(error)")
    }
  }
}
