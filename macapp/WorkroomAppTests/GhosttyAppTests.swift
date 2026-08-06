import XCTest

@testable import Workroom

/// IT2 verification: the libghostty runtime actually comes up inside the app bundle (ghostty_init
/// + ghostty_app_new succeed and the bundled GHOSTTY_RESOURCES_DIR resolves). Runs in the
/// Workroom.app test host, so Bundle.main.resourceURL is the app's Resources (where ghostty/ lives).
@MainActor
final class GhosttyAppTests: XCTestCase {
  func testEngineInitializes() {
    XCTAssertTrue(
      GhosttyApp.shared.isReady,
      "libghostty failed to initialize — check bundled ghostty resources and the pinned C API")
  }
}

/// T2: the pure notification mapper that replaces the deleted OSCParserTests coverage.
final class TerminalActivityMapperTests: XCTestCase {
  func testEmptyTitleIsKeptEmpty() {
    // No placeholder: a titleless notification stays titleless (the UI leads with the body).
    guard
      case .osc(let title, let body) = GhosttyRuntimeAdapter.terminalActivity(title: "", body: nil)
    else { return XCTFail("expected .osc") }
    XCTAssertEqual(title, "")
    XCTAssertNil(body)
  }

  func testTitleAndBodyPassThrough() {
    guard
      case .osc(let title, let body) = GhosttyRuntimeAdapter.terminalActivity(
        title: "Build done", body: "3 targets")
    else { return XCTFail("expected .osc") }
    XCTAssertEqual(title, "Build done")
    XCTAssertEqual(body, "3 targets")
  }

  func testEmptyBodyNormalizesToNil() {
    guard
      case .osc(_, let body) = GhosttyRuntimeAdapter.terminalActivity(title: "Hi", body: "")
    else { return XCTFail("expected .osc") }
    XCTAssertNil(body)
  }
}
