import XCTest

@testable import Workroom

/// The pure failure-classification behind the inline agent's trigger (issue #49, A3): boring-code
/// filtering, program extraction, the benign-non-zero denylist, and the skip/manualOnly/eligible
/// disposition. Exercised with explicit command + exit-code data.
final class FailureClassifierTests: XCTestCase {

  // MARK: programName

  func testProgramNamePlain() {
    XCTAssertEqual(FailureClassifier.programName(from: "grep foo bar"), "grep")
  }

  func testProgramNameStripsEnvPrefix() {
    XCTAssertEqual(FailureClassifier.programName(from: "FOO=bar BAZ=1 grep x"), "grep")
  }

  func testProgramNameStripsLeadingPath() {
    XCTAssertEqual(FailureClassifier.programName(from: "/usr/bin/grep x"), "grep")
  }

  func testProgramNameStripsWrappers() {
    XCTAssertEqual(FailureClassifier.programName(from: "sudo rm -rf x"), "rm")
    XCTAssertEqual(FailureClassifier.programName(from: "env NODE_ENV=prod node app.js"), "node")
  }

  func testProgramNameUsesLastPipelineSegment() {
    XCTAssertEqual(FailureClassifier.programName(from: "cat log | grep error"), "grep")
    XCTAssertEqual(FailureClassifier.programName(from: "ps aux | sort | head"), "head")
  }

  func testProgramNameEmpty() {
    XCTAssertNil(FailureClassifier.programName(from: ""))
    XCTAssertNil(FailureClassifier.programName(from: "   "))
  }

  // MARK: benign non-zero

  func testBenignNonZeroPrograms() {
    XCTAssertTrue(FailureClassifier.isBenignNonZero(command: "grep needle file"))
    XCTAssertTrue(FailureClassifier.isBenignNonZero(command: "cat x | rg pattern"))
    XCTAssertTrue(FailureClassifier.isBenignNonZero(command: "diff a b"))
    XCTAssertFalse(FailureClassifier.isBenignNonZero(command: "rails server"))
    XCTAssertFalse(FailureClassifier.isBenignNonZero(command: "npm test"))
  }

  // MARK: disposition

  func testBoringExitCodesSkip() {
    for code in [Int32(0), 130, 143] {
      XCTAssertEqual(
        FailureClassifier.disposition(
          exitCode: code, command: "rails s", isRunTab: false, hasCapture: true),
        .skip)
    }
  }

  func testRealFailureIsEligible() {
    XCTAssertEqual(
      FailureClassifier.disposition(
        exitCode: 1, command: "rails server", isRunTab: false, hasCapture: true),
      .eligible)
  }

  func testBenignProgramIsManualOnly() {
    XCTAssertEqual(
      FailureClassifier.disposition(
        exitCode: 1, command: "grep foo log", isRunTab: false, hasCapture: true),
      .manualOnly)
  }

  func testRunTabAlwaysEligibleEvenBenignNameOrNoCapture() {
    // A run tab (server/tests) is the headline case — always eligible, regardless of program name
    // or whether ad-hoc capture would have been empty.
    XCTAssertEqual(
      FailureClassifier.disposition(
        exitCode: 1, command: "grep", isRunTab: true, hasCapture: false),
      .eligible)
  }

  func testAdHocWithNoCaptureSkips() {
    XCTAssertEqual(
      FailureClassifier.disposition(
        exitCode: 1, command: "rspec", isRunTab: false, hasCapture: false),
      .skip)
  }

  func testNilCommandWithCaptureIsEligible() {
    // Unknown command but real non-zero + captured output → still worth diagnosing.
    XCTAssertEqual(
      FailureClassifier.disposition(
        exitCode: 1, command: nil, isRunTab: false, hasCapture: true),
      .eligible)
  }
}
