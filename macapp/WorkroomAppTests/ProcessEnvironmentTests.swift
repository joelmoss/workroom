import XCTest

@testable import Workroom

/// Reading one variable from another process's exec-time environment (`KERN_PROCARGS2`), as
/// workroomd does for a pane's Claude profile.
final class ProcessEnvironmentTests: XCTestCase {
  /// argc, exec path + padding, the argv strings, then the environment and trailing padding.
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
