import XCTest

@testable import Workroom

/// Pure ANSI rendering + sanitizing for the inline presentation (issue #49). The actual write to the
/// surface (`writeOutput` → `ghostty_surface_write_buffer`) needs a live surface and is covered by
/// QA/XCUITest; here we pin the bytes.
final class AgentInlineRendererTests: XCTestCase {
  private func failure() -> FailedCommand {
    FailedCommand(
      command: "rails s", cwd: "/app", exitCode: 1, shell: "zsh", output: "boom", isRunTab: false,
      isRemote: false)
  }

  private let esc = "\u{1b}"

  func testReadyIncludesSummaryFixAndFaintStyling() {
    let diag = AgentDiagnosis(
      summary: "port in use", fixCommand: "kill $(lsof -ti:3000)", detail: nil)
    let out = AgentInlineRenderer.ansi(for: .ready(failure(), diag))
    XCTAssertNotNil(out)
    XCTAssertTrue(out!.contains("✦ port in use"))
    XCTAssertTrue(out!.contains("fix: kill $(lsof -ti:3000)"))
    XCTAssertTrue(out!.contains("\(esc)[2m"), "styled faint")
    XCTAssertTrue(out!.contains("\(esc)[0m"), "reset after each line")
    XCTAssertTrue(out!.hasPrefix("\r\n"), "starts on its own line below the output")
  }

  func testReadyWithoutFixOmitsFixLine() {
    let diag = AgentDiagnosis(summary: "unclear", fixCommand: nil, detail: nil)
    let out = AgentInlineRenderer.ansi(for: .ready(failure(), diag))
    XCTAssertNotNil(out)
    XCTAssertFalse(out!.contains("fix:"))
  }

  func testFailureRendersMessage() {
    let out = AgentInlineRenderer.ansi(for: .failure(failure(), .cliNotFound))
    XCTAssertNotNil(out)
    XCTAssertTrue(out!.lowercased().contains("cli"))
  }

  func testAwaitingPromptsToDiagnose() {
    let out = AgentInlineRenderer.ansi(for: .awaitingDiagnose(failure()))
    XCTAssertTrue(out?.lowercased().contains("diagnose") ?? false)
  }

  func testTransientStatesRenderNothing() {
    XCTAssertNil(AgentInlineRenderer.ansi(for: .loading(failure())))
    XCTAssertNil(AgentInlineRenderer.ansi(for: .remoteCaveat(failure())))
  }

  func testSanitizeStripsControlAndEscapeSequences() {
    // A crafted diagnosis trying to smuggle its own colour/clear codes must be neutralised.
    let evil = "red\(esc)[31mtext\nnewline\u{7f}del"
    let clean = AgentInlineRenderer.sanitize(evil)
    XCTAssertFalse(clean.contains(esc))
    XCTAssertFalse(clean.contains("\n"))
    XCTAssertFalse(clean.contains("\u{7f}"))
    XCTAssertEqual(clean, "red[31mtextnewlinedel")
  }

  func testSanitizeKeepsUnicode() {
    XCTAssertEqual(AgentInlineRenderer.sanitize("café ✦ 日本"), "café ✦ 日本")
  }

  func testReadySanitizesModelText() {
    let diag = AgentDiagnosis(summary: "bad\(esc)[2J", fixCommand: "rm\u{7f}", detail: nil)
    let out = AgentInlineRenderer.ansi(for: .ready(failure(), diag))!
    // Only the renderer's OWN styling escapes remain; the model's injected ESC/DEL are gone.
    XCTAssertFalse(out.contains("\(esc)[2J"))
    XCTAssertFalse(out.contains("\u{7f}"))
  }
}
