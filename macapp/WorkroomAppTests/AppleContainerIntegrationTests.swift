import XCTest

@testable import Workroom

/// `ContainerHostDriver` on Apple's real `container` runtime (#309): two workroom hosts, a restart,
/// the sweep, and teardown. Opt-in: Apple's runtime needs Apple silicon and a
/// VM per container, which CI's macOS runners can't give it, so these run on a Mac by hand before
/// a release. Skipped unless `TEST_RUNNER_WR_APPLE_CONTAINER_TESTS=1`, with
/// `TEST_RUNNER_WR_APPLE_HOST_IMAGE` naming a `workroom-host` image the runtime already has, e.g.
///
///   docker build --platform linux/arm64 -t workroom-host vcs/scripts/ssh-fixture
///   docker save workroom-host -o /tmp/host.tar && container image load -i /tmp/host.tar
///   TEST_RUNNER_WR_APPLE_CONTAINER_TESTS=1 \
///   TEST_RUNNER_WR_APPLE_HOST_IMAGE=docker.io/library/workroom-host:latest \
///     make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/AppleContainerIntegrationTests
///
/// with `container system start` run first.
final class AppleContainerIntegrationTests: XCTestCase {
  private var directory: URL!
  private var runtime: URL!
  private var label: String!

  override func setUpWithError() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["WR_APPLE_CONTAINER_TESTS"] == "1" else {
      throw XCTSkip("set TEST_RUNNER_WR_APPLE_CONTAINER_TESTS=1 to run Apple container tests")
    }
    guard let found = RemoteHosts.executable(for: .apple) else {
      throw XCTSkip("Apple's container CLI isn't installed")
    }
    runtime = URL(fileURLWithPath: found)
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-apple-\(UUID().uuidString)")
    label = "workroom.provisioner=apple-test-\(UUID().uuidString.lowercased())"
  }

  override func tearDown() async throws {
    // Whatever a failed test left, by this run's label.
    if runtime != nil {
      let containers = (try? AppleContainerCLI.objects(cli(["list", "--all", "--format", "json"])))
      for container in containers ?? [] where carries(AppleContainerCLI.labels(of: container)) {
        if let id = AppleContainerCLI.id(of: container) { _ = try? cli(["delete", "--force", id]) }
      }
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  /// This run's own, never another run's: two runs at once would otherwise delete each other's.
  private func carries(_ labels: [String: String]) -> Bool {
    labels["workroom.provisioner"] == label.split(separator: "=")[1].description
  }

  /// The real CLI, run from here rather than through the driver, so a check is never the driver
  /// checking itself.
  @discardableResult
  private func cli(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = runtime
    process.arguments = arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func ours() throws -> [String] {
    try AppleContainerCLI.objects(cli(["list", "--all", "--format", "json"])).filter {
      carries(AppleContainerCLI.labels(of: $0))
    }.compactMap(AppleContainerCLI.id)
  }

  private func provisioning() throws -> ContainerHostDriver.Provisioning {
    guard let image = ProcessInfo.processInfo.environment["WR_APPLE_HOST_IMAGE"] else {
      throw XCTSkip("set TEST_RUNNER_WR_APPLE_HOST_IMAGE to a workroom-host image")
    }
    let key = try RemoteHosts.clientKey(in: directory)
    return ContainerHostDriver.Provisioning(
      runtime: runtime, image: image, user: RemoteWorkrooms.user, identityFile: key.path,
      publicKey: try String(contentsOf: key.appendingPathExtension("pub"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      agentSocket: RemoteWorkrooms.agentSocket, labels: [label], dialect: .apple)
  }

  private func onHost(_ driver: ContainerHostDriver, _ host: HostID, _ command: String)
    async throws -> String
  {
    let (status, output) = try await driver.exec(command, on: host).communicate(nil, timeout: 20)
    XCTAssertEqual(status, 0, "on the host, \(command) failed: \(output)")
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func testFreshHostsAreRestartableAndTeardownLeavesNothing() async throws {
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: try provisioning())

    let first = try await driver.create()
    let second = try await driver.create()
    var keys: [String] = []
    for host in [first, second] {
      keys.append(try await onHost(driver, host, "cut -d' ' -f2 /etc/ssh/ssh_host_ed25519_key.pub"))
    }
    XCTAssertNotEqual(keys[0], keys[1], "two hosts share a host key")

    // Apple keeps nothing running across a restart: opening starts it again, on its port.
    guard case .remote(let id) = first, case .remote(let secondID) = second else {
      return XCTFail("not remote hosts")
    }
    try cli(["stop", ContainerHostDriver.containerName(id)])
    try await driver.startIfStopped(first)
    let up = try await onHost(driver, first, "echo up")
    XCTAssertEqual(up, "up")

    // Both are recorded hosts: the sweep takes neither, however old.
    let failures = await driver.sweep(keeping: [id, secondID], grace: 0)
    XCTAssertEqual(failures, [])
    XCTAssertEqual(try ours().count, 2)

    for host in [first, second] { try await driver.destroy(host) }
    XCTAssertEqual(try ours(), [])
  }
}
