import Foundation
import XCTest

@testable import HostDrivers

final class SSHTransportShellTests: XCTestCase {
  /// Trust must persist the captured key; a discard device must never report a successful trust.
  func testKnownHostTrustRejectsDiscardTargetsAndKeepsRegularFileSymlinks() throws {
    let root = URL(fileURLWithPath: "/private/tmp/known-hosts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let discarded = root.appendingPathComponent("discard")
    try FileManager.default.createSymbolicLink(
      at: discarded, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
    for target in [URL(fileURLWithPath: "/dev/null"), discarded, root] {
      XCTAssertThrowsError(try SSHTransport.appendKnownHost("fixture-public-key", to: target)) {
        XCTAssertTrue($0.localizedDescription.contains("UserKnownHostsFile"))
        XCTAssertTrue($0.localizedDescription.contains("regular file"))
      }
    }
    let file = root.appendingPathComponent("known_hosts")
    try SSHTransport.appendKnownHost("first-key", to: file)
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
    try SSHTransport.appendKnownHost("second-key", to: alias)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first-key\nsecond-key\n")
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), file.path)
  }

  func testMissingAttachBinaryKeepsTheRetryableTransportStatus() throws {
    let root = "/nonexistent-workroom-\(UUID().uuidString)"
    let script = SSHTransport.remoteAttachCommand(
      binary: root + "/workroomd", session: UUID(), socket: root + "/workroomd.sock",
      resources: root + "/resources", workingDirectory: "/", restored: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", SSHTransport.loginShellCommand(script)]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 255)
    XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("no daemon is installed"))
  }

  func testLoginShellBoundaryPreservesScriptBytesAndStdin() throws {
    let value = "quote' double\" slashes\\\\ dollar$ backtick`\nsecond line"
    let script =
      "IFS= read -r line; printf '%s\\n%s' \"$line\" "
      + SSHTransport.shellQuoted(value)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", SSHTransport.loginShellCommand(script)]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data("stdin\\\\untouched\n".utf8))
    try input.fileHandleForWriting.close()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "stdin\\\\untouched\n" + value)
  }
}
