import HostDrivers
import XCTest

@testable import Workroom

/// What the daemon bootstrap finds in this app's bundle: the far-side scripts and the Linux
/// daemons. The bootstrap itself is HostDrivers' (`DaemonBootstrapTests` there, under `swift test`).
final class DaemonBootstrapBundleTests: XCTestCase {
  /// The bundled binary's digest is the one `sha256sum` prints (the SHA-256 of "abc", FIPS 180-2),
  /// and an architecture this build has no daemon for finds none.
  func testTheDigestIsSha256sumsAndAnUnknownArchitectureHasNoAgent() throws {
    let abc = FileManager.default.temporaryDirectory.appendingPathComponent(
      "abc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: abc) }
    try Data("abc".utf8).write(to: abc)
    XCTAssertEqual(
      try DaemonBootstrap.digest(of: abc),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    XCTAssertNil(PersistentSessionPaths.linuxDaemonURL(architecture: "riscv64"))
  }

  /// The scripts ship in the bundle, and parse.
  func testTheFarSideScriptsAreBundledAndParse() throws {
    for name in ["probe", "install", "placed", "resources", "start"] {
      let script = try DaemonBootstrap.script(named: name)
      XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"), name)
      let (status, output) = try SessionBackendProbe.run(
        URL(fileURLWithPath: "/bin/sh"), arguments: ["-n", "-c", script], timeout: 5)
      XCTAssertEqual(status, 0, "\(name): \(output)")
    }
  }
}
