import DaemonConnection
import HostDrivers
import WorkroomVCS
import XCTest

@testable import Workroom

/// A devcontainer.json made into a container on Apple's real `container` runtime (#308): its image
/// and remote user, `containerEnv` and `remoteEnv`, its lifecycle commands in order, and its
/// postStartCommand run again after the container restarts. Opt-in, by hand on a Mac:
/// `container system start` first, then
///
///   TEST_RUNNER_WR_APPLE_CONTAINER_TESTS=1 TEST_RUNNER_WR_LINUX_DAEMON=<workroomd-linux-aarch64> \
///     make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/ContainerCreateLiveTests
final class ContainerCreateLiveTests: XCTestCase {
  func testADevcontainerBecomesAContainerOnApplesRuntime() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["WR_APPLE_CONTAINER_TESTS"] == "1",
      let daemon = environment["WR_LINUX_DAEMON"].map(URL.init(fileURLWithPath:))
    else {
      throw XCTSkip("set WR_APPLE_CONTAINER_TESTS=1 and WR_LINUX_DAEMON to run")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = URL(fileURLWithPath: "/opt/homebrew/bin/container")
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("hosts"),
      provisioning: ContainerHostDriver.Provisioning(
        runtime: runtime, image: "unused", user: "",
        daemonSocket: DaemonInstall.defaultSocket, labels: ["workroom.provisioner=live-test"],
        dialect: .apple, daemon: { _ in daemon },
        daemonFolder: directory.appendingPathComponent("daemon")))
    let json = Data(
      #"""
      {
        // JSONC, as the spec allows.
        "image": "node:22", "remoteUser": "node",
        "containerEnv": {"BASE": "/opt"},
        "remoteEnv": {"GREETING": "hi ${containerEnv:BASE}"},
        "onCreateCommand": "echo \"created $GREETING in $HOME\" > /tmp/created",
        "postStartCommand": ["sh", "-c", "date +%s%N >> /tmp/started"],
      }
      """#.utf8)
    let file = ContainerCreate.File(
      path: ".devcontainer/devcontainer.json", data: json,
      config: try DevContainerConfig.parse(json))

    let prepared = try await ContainerCreate.prepare(
      file, project: directory.path, repository: "app", start: "HEAD", runtime: .apple,
      driver: driver, defaultImage: "unused",
      featureCache: directory.appendingPathComponent("features"))
    XCTAssertEqual(prepared.workspaceFolder, "/workspaces/app")
    XCTAssertEqual(prepared.hooks.map(\.hook), [.onCreate, .postStart])
    let host = try await driver.create(spec: prepared.spec)
    do {
      let daemonBinary = try XCTUnwrap(driver.daemonPath(on: host))
      for (hook, script) in prepared.hooks {
        let failure = await ContainerCreate.runHook(
          hook, script: script, on: host, driver: driver, daemonBinary: daemonBinary,
          onLine: { _ in })
        XCTAssertNil(failure)
      }
      let (status, said) = try await driver.exec(
        "cat /tmp/created; wc -l < /tmp/started; test -e /dev/shm/workroom-poststart && echo marked;"
          + " echo \"$GREETING\"; id -un",
        on: host
      ).communicate(nil, timeout: 30)
      XCTAssertEqual(status, 0, said)
      XCTAssertEqual(
        said.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) },
        ["created hi /opt in /home/node", "1", "marked", "hi /opt", "node"])
      // Nothing to do again until the container starts again.
      let again = try await driver.runPostStartIfNeeded(on: host)
      XCTAssertNil(again)

      // A restart is a new start: postStartCommand runs once more on the next connect.
      guard case .remote(let id) = host else { return XCTFail("not a remote host") }
      let stop = Process()
      stop.executableURL = runtime
      stop.arguments = ["stop", ContainerHostDriver.containerName(id)]
      try stop.run()
      stop.waitUntilExit()
      try await driver.startIfStopped(host)
      let rerun = try await driver.runPostStartIfNeeded(on: host)
      XCTAssertEqual(rerun?.status, 0, rerun?.output ?? "")
      let (_, count) = try await driver.exec("wc -l < /tmp/started", on: host).communicate(
        nil, timeout: 30)
      XCTAssertEqual(count.trimmingCharacters(in: .whitespacesAndNewlines), "2")
    } catch {
      try? await driver.destroy(host)
      throw error
    }
    try await driver.destroy(host)
  }

  /// No devcontainer.json: the pinned default image, run as the `vscode` user its devcontainer
  /// metadata names (its config says root), with its git (eng review D8).
  func testNoDevcontainerIsTheDefaultImageAsItsVscodeUser() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["WR_APPLE_CONTAINER_TESTS"] == "1",
      let daemon = environment["WR_LINUX_DAEMON"].map(URL.init(fileURLWithPath:))
    else {
      throw XCTSkip("set WR_APPLE_CONTAINER_TESTS=1 and WR_LINUX_DAEMON to run")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("hosts"),
      provisioning: ContainerHostDriver.Provisioning(
        runtime: URL(fileURLWithPath: "/opt/homebrew/bin/container"), image: "unused", user: "",
        daemonSocket: DaemonInstall.defaultSocket,
        labels: ["workroom.provisioner=live-test"], dialect: .apple, daemon: { _ in daemon },
        daemonFolder: directory.appendingPathComponent("daemon")))
    let prepared = try await ContainerCreate.prepare(
      nil, project: directory.path, repository: "app", start: "HEAD", runtime: .apple,
      driver: driver, defaultImage: DevContainerSetup.pinnedDefaultImage,
      featureCache: directory.appendingPathComponent("features"))
    XCTAssertTrue(prepared.hooks.isEmpty)
    XCTAssertEqual(prepared.configDigest, "image:\(DevContainerSetup.pinnedDefaultImage)")
    let host = try await driver.create(spec: prepared.spec)
    do {
      XCTAssertEqual(driver.record(of: host)?.user, "vscode")
      let (status, said) = try await driver.exec(
        "id -un; git --version >/dev/null && echo git; stat -c %U /workspaces/app", on: host
      ).communicate(nil, timeout: 30)
      XCTAssertEqual(status, 0, said)
      XCTAssertEqual(said, "vscode\ngit\nvscode\n")
    } catch {
      try? await driver.destroy(host)
      throw error
    }
    try await driver.destroy(host)
  }
}
