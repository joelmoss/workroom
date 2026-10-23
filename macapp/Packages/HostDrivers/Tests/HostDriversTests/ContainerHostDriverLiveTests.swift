import XCTest

@testable import HostDrivers

/// `create(spec:)` on Apple's real `container` runtime with a stock image (#308): the daemon placed
/// and serving as the remote user, a command through `exec`, a pane through the attach command,
/// then teardown. Opt-in, by hand on a Mac: `container system start` first, then
///
///   WR_APPLE_CONTAINER_TESTS=1 WR_LINUX_DAEMON=<a workroomd-linux-aarch64> \
///     swift test --package-path macapp/Packages/HostDrivers --filter ContainerHostDriverLiveTests
final class ContainerHostDriverLiveTests: XCTestCase {
  func testAStockImageBecomesAWorkroomOnApplesRuntime() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["WR_APPLE_CONTAINER_TESTS"] == "1",
      let daemon = environment["WR_LINUX_DAEMON"].map(URL.init(fileURLWithPath:))
    else {
      throw XCTSkip("set WR_APPLE_CONTAINER_TESTS=1 and WR_LINUX_DAEMON to run")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("hosts"),
      provisioning: ContainerHostDriver.Provisioning(
        runtime: URL(fileURLWithPath: "/opt/homebrew/bin/container"), image: "unused", user: "",
        identityFile: "", publicKey: "", daemonSocket: DaemonInstall.defaultSocket,
        labels: ["workroom.provisioner=live-test"], dialect: .apple,
        daemon: { _ in daemon }, daemonFolder: directory.appendingPathComponent("daemon")))

    let host = try await driver.create(
      spec: .init(image: "node:22", user: "node", workspaceFolder: "/workspaces/app"))
    do {
      let (status, said) = try await driver.exec(
        "id -un; stat -c %U /workspaces/app", on: host
      ).communicate(nil, timeout: 30)
      XCTAssertEqual(status, 0, said)
      XCTAssertEqual(said, "node\nnode\n")

      let session = UUID()
      let command = try driver.attachCommand(
        to: host, session: session, workingDirectory: "/workspaces/app", restored: false,
        metadata: [], runCommand: nil)
      // A terminal for the attach (`script`), typed into on a timer, its screen kept in a file and
      // read once the pane has had time to answer.
      let screenFile = directory.appendingPathComponent("screen")
      let pane = Process()
      pane.executableURL = URL(fileURLWithPath: "/bin/sh")
      pane.arguments = [
        "-c",
        "(sleep 3; printf 'echo PANE-$((6*7)) $(id -un)\\r'; sleep 2; printf 'exit\\r'; sleep 2) "
          + "| /usr/bin/script -q /dev/null /bin/sh -c \(SSHTransport.shellQuoted(command)) > "
          + SSHTransport.shellQuoted(screenFile.path) + " 2>&1",
      ]
      try pane.run()
      let deadline = Date().addingTimeInterval(60)
      while pane.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
      if pane.isRunning { pane.terminate() }
      let screen = (try? String(contentsOf: screenFile, encoding: .utf8)) ?? ""
      XCTAssertTrue(screen.contains("PANE-42 node"), screen)
      XCTAssertEqual(driver.lastAttach(of: session, on: host), .finished)
    } catch {
      try? await driver.destroy(host)
      throw error
    }
    try await driver.destroy(host)
  }
}
