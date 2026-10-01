import XCTest

@testable import Workroom

/// `ContainerHostDriver`'s provisioning (#252): bases and instances derived from them, made from
/// the ssh fixture's image with the container runtime. Skipped unless run through the fixture
/// script, which builds the image and says where it is:
///
///   vcs/scripts/ssh-fixture/run.sh <linux wr-agent> \
///     make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/ContainerProvisioningIntegrationTests
final class ContainerProvisioningIntegrationTests: XCTestCase {
  private var directory: URL!
  /// This test's own label, beside the run's, so what it left is told apart from other tests'.
  private var label: String!
  private var runtime: URL!
  private var connections: [AgentVCSConnection] = []

  override func setUp() {
    super.setUp()
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-provision-\(UUID().uuidString.prefix(8))")
    label = "workroom.test=\(UUID().uuidString.lowercased())"
  }

  override func tearDown() async throws {
    for connection in connections { await connection.close() }
    connections.removeAll()
    // Whatever a failed test left, so the next one starts clean. run.sh sweeps the run's label too.
    if let runtime, let label {
      for container in (try? leftovers("ps", runtime: runtime, label: label)) ?? [] {
        _ = try? docker(runtime, ["rm", "--force", "--volumes", container])
      }
      for image in (try? leftovers("images", runtime: runtime, label: label)) ?? [] {
        _ = try? docker(runtime, ["rmi", "--force", image])
      }
    }
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  private func provisioning(runtime override: URL? = nil) throws -> ContainerHostDriver.Provisioning
  {
    let environment = ProcessInfo.processInfo.environment
    func need(_ name: String) throws -> String {
      guard let value = environment[name], !value.isEmpty else {
        throw XCTSkip("\(name) is unset; run these through vcs/scripts/ssh-fixture/run.sh")
      }
      return value
    }
    runtime = URL(fileURLWithPath: try need("WR_SSH_FIXTURE_RUNTIME_PATH"))
    return ContainerHostDriver.Provisioning(
      runtime: override ?? runtime, image: try need("WR_SSH_FIXTURE_IMAGE"),
      user: try need("WR_SSH_FIXTURE_USER"), identityFile: try need("WR_SSH_FIXTURE_IDENTITY"),
      publicKey: try need("WR_SSH_FIXTURE_PUBLIC_KEY"),
      agentSocket: try need("WR_SSH_FIXTURE_SOCKET"),
      labels: [try need("WR_SSH_FIXTURE_LABEL"), label])
  }

  /// The real runtime, run from here rather than through the driver, so a check is never the
  /// thing under test.
  @discardableResult
  private func docker(_ runtime: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = runtime
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The containers (`ps`) or images (`images`) carrying this test's label. `-a` for both: a
  /// commit is untagged, and `images` lists an untagged image only with it.
  private func leftovers(_ kind: String, runtime: URL, label: String) throws -> [String] {
    try docker(runtime, [kind, "-a", "-q", "--filter", "label=\(label)"])
      .split(separator: "\n").map(String.init)
  }

  @discardableResult
  private func onHost(_ driver: ContainerHostDriver, _ host: HostID, _ command: String)
    async throws -> String
  {
    let (status, output) = try await driver.exec(command, on: host).communicate(nil, timeout: 20)
    XCTAssertEqual(status, 0, "on the host, \(command) failed: \(output)")
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The machine identity open question 9 lists: the ssh host key and `/etc/machine-id`.
  private func identity(_ driver: ContainerHostDriver, _ host: HostID) async throws -> [String] {
    [
      try await onHost(driver, host, "cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub"),
      try await onHost(driver, host, "cat /etc/machine-id"),
    ]
  }

  func testABaseIsReachableItsAgentServesAndDestroyingItLeavesNothing() async throws {
    let provisioning = try provisioning()
    let driver = ContainerHostDriver(hosts: [:], directory: directory, provisioning: provisioning)

    let base = try await driver.create()
    let connection = try await AgentVCSConnection.connect(
      host: base, stream: try await driver.openStream(to: base))
    connections.append(connection)
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label).count, 1)

    try await driver.destroy(base)
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label), [])
    do {
      _ = try await driver.exec("true", on: base)
      XCTFail("a destroyed host is still known")
    } catch HostDriverError.unknownHost {}
  }

  func testInstancesDerivedFromOneBaseCarryItsDiskButMintTheirOwnIdentity() async throws {
    let provisioning = try provisioning()
    let driver = ContainerHostDriver(hosts: [:], directory: directory, provisioning: provisioning)
    let base = try await driver.create()
    try await onHost(driver, base, "echo from-the-base > ~/template")
    let baseIdentity = try await identity(driver, base)

    let first = try await driver.deriveFromBase(base)
    let second = try await driver.deriveFromBase(base)

    for instance in [first, second] {
      let template = try await onHost(driver, instance, "cat ~/template")
      XCTAssertEqual(template, "from-the-base")
      let connection = try await AgentVCSConnection.connect(
        host: instance, stream: try await driver.openStream(to: instance))
      connections.append(connection)
    }
    let firstIdentity = try await identity(driver, first)
    let secondIdentity = try await identity(driver, second)
    for (name, index) in [("ssh host key", 0), ("machine-id", 1)] {
      XCTAssertNotEqual(
        firstIdentity[index], secondIdentity[index], "two instances share a \(name)")
      XCTAssertNotEqual(
        firstIdentity[index], baseIdentity[index], "an instance kept its base's \(name)")
      XCTAssertNotEqual(
        secondIdentity[index], baseIdentity[index], "an instance kept its base's \(name)")
    }

    for host in [first, second, base] { try await driver.destroy(host) }
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label), [])
    XCTAssertEqual(
      try leftovers("images", runtime: runtime, label: label), [], "a commit outlived its instance")
  }

  /// A runtime that runs the real one, except for the subcommand named in `failing` when that
  /// file exists: a provider that fails partway through a derive, once the base is made.
  private func failingRuntime() throws -> (runtime: URL, failing: URL) {
    _ = try provisioning()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let failing = directory.appendingPathComponent("failing")
    let script = directory.appendingPathComponent("runtime")
    try """
    #!/bin/sh
    if [ -f \(PosixShell.quoted(failing.path)) ] && \\
      [ "$1" = "$(cat \(PosixShell.quoted(failing.path)))" ]; then
      echo "injected failure" >&2; exit 1
    fi
    exec \(PosixShell.quoted(runtime.path)) "$@"

    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (script, failing)
  }

  func testADeriveThatFailsAtEachStepLeavesNoContainerOrImageBehind() async throws {
    let (script, failing) = try failingRuntime()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: try provisioning(runtime: script))
    let base = try await driver.create()
    let baseContainers = try leftovers("ps", runtime: runtime, label: label)

    // `commit` makes the image and `run` the container; `port` and `exec` come once it is running.
    // A failed `exec` reads as an identity never minted, so it carries no runtime message.
    for step in ["commit", "run", "port", "exec"] {
      try step.write(to: failing, atomically: true, encoding: .utf8)
      do {
        _ = try await driver.deriveFromBase(base)
        XCTFail("a derive that failed at \(step) succeeded")
      } catch HostDriverError.provisioning(let detail) {
        XCTAssertTrue(
          detail.contains(step == "exec" ? "never minted" : "injected failure"),
          "\(step): \(detail)")
      }
      XCTAssertEqual(
        try leftovers("ps", runtime: runtime, label: label), baseContainers,
        "a derive that failed at \(step) left a container")
      XCTAssertEqual(
        try leftovers("images", runtime: runtime, label: label), [],
        "a derive that failed at \(step) left an image")
    }
    try FileManager.default.removeItem(at: failing)
    try await driver.destroy(base)
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label), [])
  }
}
