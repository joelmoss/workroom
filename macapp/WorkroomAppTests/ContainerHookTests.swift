import DaemonConnection
import DevContainer
import HostDrivers
import WorkroomDomain
import XCTest

@testable import Workroom

/// A lifecycle command run in the container (#308), against this Mac's own shell standing in for
/// the container and a stand-in `workroomd run-script`: written to the hooks folder, run, its
/// output streamed, and a postStartCommand marked done whether or not it passed.
final class ContainerHookTests: XCTestCase {
  private struct ShellHost: HostDriver {
    func create() async throws -> HostID { .local }
    func destroy(_ host: HostID) async throws {}
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.notImplemented("stream")
    }
    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      try HostStream.spawn(
        URL(fileURLWithPath: "/bin/sh"), ["-c", command], environment: [:],
        handshakeTimeout: 5, purpose: .exchange)
    }
  }

  private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: [String] { lock.withLock { lines } }
    func add(_ line: String) { lock.withLock { lines.append(line) } }
  }

  func testAHookIsWrittenRunAndAPostStartMarkedDoneEitherWay() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hook-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // `run-script --dir <dir> --timeout <secs> -- <script>`, as the daemon takes it.
    let daemon = root.appendingPathComponent("workroomd")
    try "#!/bin/sh\ncd \"$3\" && exec \"$7\"\n".write(to: daemon, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemon.path)
    let folder = root.appendingPathComponent("hooks").path
    let done = root.appendingPathComponent("done")
    func run(_ hook: DevContainerConfig.Hook, _ command: String, _ lines: Lines) async -> String? {
      await ContainerCreate.runHook(
        hook,
        script: DevContainerSetup.hookScript(
          hook, commands: [.shell(command)], checkout: root.path, environment: [:]),
        on: .local, driver: ShellHost(), daemonBinary: daemon.path, folder: folder,
        done: done.path, onLine: { lines.add($0) })
    }

    let said = Lines()
    let passed = await run(.postCreate, "echo one; echo two >&2", said)
    XCTAssertNil(passed)
    XCTAssertEqual(Set(said.all), ["one", "two"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/postCreateCommand"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: done.path), "only postStart marks done")

    let failed = await run(.postStart, "exit 4", Lines())
    XCTAssertEqual(failed, "The dev container's postStartCommand failed: it exited 4.")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: done.path), "a failed postStart held panes")
  }
}
