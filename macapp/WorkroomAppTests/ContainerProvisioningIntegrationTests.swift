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
    // A Docker or Mac restart brings it back, on the port its record names (#253).
    guard case .remote(let id) = base else { return XCTFail("\(base)") }
    XCTAssertEqual(
      try docker(
        runtime,
        [
          "inspect", "-f", "{{.HostConfig.RestartPolicy.Name}}",
          ContainerHostDriver.containerName(id),
        ]),
      "unless-stopped")

    try await driver.destroy(base)
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label), [])
    do {
      _ = try await driver.exec("true", on: base)
      XCTFail("a destroyed host is still known")
    } catch HostDriverError.unknownHost {}
  }

  /// A stopped container is started again, and logged in to, when its workroom is opened (#309); a
  /// running one is left as it is.
  func testAStoppedHostIsStartedAndReachableAgain() async throws {
    let provisioning = try provisioning()
    let driver = ContainerHostDriver(hosts: [:], directory: directory, provisioning: provisioning)
    let base = try await driver.create()
    guard case .remote(let id) = base else { return XCTFail("\(base)") }
    let container = ContainerHostDriver.containerName(id)

    try await driver.startIfStopped(base)
    XCTAssertEqual(try docker(runtime, ["inspect", "-f", "{{.State.Running}}", container]), "true")
    _ = try docker(runtime, ["stop", container])
    XCTAssertEqual(
      try docker(runtime, ["inspect", "-f", "{{.State.Running}}", container]), "false")

    try await driver.startIfStopped(base)
    let answer = try await onHost(driver, base, "echo up")
    XCTAssertEqual(answer, "up")
    try await driver.destroy(base)
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
  /// file exists: a provider that fails partway through a derive, once the base is made. Named
  /// with a `+`, the subcommand runs and THEN fails, as a CLI killed after the daemon took the
  /// request does: the resource exists and its ID was never printed.
  private func failingRuntime() throws -> (runtime: URL, failing: URL) {
    _ = try provisioning()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let failing = directory.appendingPathComponent("failing")
    let script = directory.appendingPathComponent("runtime")
    try """
    #!/bin/sh
    steps=" $(cat \(PosixShell.quoted(failing.path)) 2>/dev/null) "
    case "$steps" in *" $1 "*) echo "injected failure" >&2; exit 1 ;; esac
    case "$steps" in *" $1+ "*)
      \(PosixShell.quoted(runtime.path)) "$@" >/dev/null; echo "injected failure" >&2; exit 1 ;;
    esac
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

    // `commit` makes the image and `run` the container; `exec` comes once it is running. A failed
    // `exec` reads as an identity never minted, so it carries no runtime message.
    for step in ["commit", "commit+", "run", "run+", "exec"] {
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

  /// A derived workroom's supervisor keeps screens on a disk that outlives a reboot (#232, #252):
  /// a pane that reattaches after the box is stopped and started is shown its last screen, ended,
  /// rather than a fresh shell. The restart keeps the host's address and its identity, so the
  /// pane's ssh gets in with the key pinned at the derive.
  func testAPaneOnADerivedWorkroomIsShownItsLastScreenAfterAReboot() async throws {
    let provisioning = try provisioning()
    let driver = ContainerHostDriver(hosts: [:], directory: directory, provisioning: provisioning)
    let base = try await driver.create()
    let instance = try await driver.deriveFromBase(base)
    let session = UUID()

    let first = try RemoteHostIntegrationTests.Pane(
      command: driver.attachCommand(
        to: instance, session: session, workingDirectory: "/home/workroom", restored: false))
    defer { first.dropLink() }
    try await Task.sleep(for: .seconds(1))
    first.type("echo LAST-SC\"\"REEN\n")
    XCTAssertTrue(first.read(until: "LAST-SCREEN").contains("LAST-SCREEN"))
    // The reboot kills the agent outright, so only what it has already written survives.
    let record = "~/.local/state/workroom/screens/\(session.uuidString.lowercased()).vt"
    var written = false
    for _ in 0..<100 where !written {
      // Not `onHost`, which fails the test on the misses this loop waits through.
      let (status, _) = try await driver.exec("grep -q LAST-SCREEN \(record)", on: instance)
        .communicate(nil, timeout: 20)
      written = status == 0
      if !written { try await Task.sleep(for: .milliseconds(200)) }
    }
    XCTAssertTrue(written, "the screen was never written to \(record)")
    first.dropLink()

    // The driver names each container after its host.
    guard case .remote(let id) = instance else { return XCTFail("not a remote host") }
    let container = "workroom-\(id.uuidString.lowercased())"
    try docker(runtime, ["restart", "-t", "0", container])

    let second = try RemoteHostIntegrationTests.Pane(
      command: driver.attachCommand(
        to: instance, session: session, workingDirectory: "/home/workroom", restored: true))
    defer { second.dropLink() }
    let seen = second.read(until: "host restarted", within: 40)
    XCTAssertTrue(seen.contains("LAST-SCREEN"), seen)
    XCTAssertTrue(seen.contains("ended when its host restarted"), seen)

    for host in [instance, base] { try await driver.destroy(host) }
  }

  /// An instance has enrolled, so its disk holds its key and credential helper: a derive from it
  /// would hand both on.
  func testAWorkroomInstanceCannotBeDerivedFrom() async throws {
    let provisioning = try provisioning()
    let driver = ContainerHostDriver(hosts: [:], directory: directory, provisioning: provisioning)
    let base = try await driver.create()
    let instance = try await driver.deriveFromBase(base)

    do {
      _ = try await driver.deriveFromBase(instance)
      XCTFail("an instance was derived from")
    } catch HostDriverError.invalidConfiguration {}
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label).count, 2)

    for host in [instance, base] { try await driver.destroy(host) }
  }

  /// A later launch's driver takes back what an earlier one made (#253): from their records
  /// alone, it reaches both hosts on their pinned keys, derives from the base, and destroys them
  /// with their image.
  func testADriverInALaterLaunchAdoptsRecordedHosts() async throws {
    let provisioning = try provisioning()
    let earlier = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("earlier"),
      provisioning: provisioning)
    let base = try await earlier.create()
    let instance = try await earlier.deriveFromBase(base)
    let baseRecord = try XCTUnwrap(earlier.record(of: base))
    let instanceRecord = try XCTUnwrap(earlier.record(of: instance))
    XCTAssertNil(baseRecord.image)
    XCTAssertNotNil(instanceRecord.image)
    // Through the descriptor, as config holds it between launches.
    let stored = try JSONDecoder().decode(
      HostDescriptor.self,
      from: try JSONEncoder().encode(HostDescriptor(driver: "container", container: instanceRecord))
    )
    XCTAssertEqual(stored.container, instanceRecord)

    let later = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("later"), provisioning: provisioning)
    guard case .remote(let baseID) = base, case .remote(let instanceID) = instance else {
      return XCTFail("not remote hosts")
    }
    try later.adopt(baseID, baseRecord)
    try later.adopt(instanceID, try XCTUnwrap(stored.container))
    let adopted = try await identity(later, instance)
    let original = try await identity(earlier, instance)
    XCTAssertEqual(adopted, original, "the adopted host is another machine")
    let second = try await later.deriveFromBase(base)

    for host in [second, instance, base] { try await later.destroy(host) }
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label), [])
    XCTAssertEqual(try leftovers("images", runtime: runtime, label: label), [])
  }

  /// A record naming an image that is not a commit's is refused: `destroy` removes it by force.
  func testAdoptRefusesARecordWhoseImageIsNotAnImageID() throws {
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: try provisioning())
    let record = ContainerHostDriver.Record(
      address: "127.0.0.1", port: 2222, user: "workroom", hostKey: "ssh-ed25519 AAAA",
      image: "debian:bookworm")
    XCTAssertThrowsError(try driver.adopt(UUID(), record))
  }

  /// The sweep removes what carries the driver's labels and no record names, and leaves the
  /// recorded hosts, their images, and whatever is younger than its grace (#253).
  func testSweepRemovesOnlyUnrecordedResourcesPastTheirGrace() async throws {
    let provisioning = try provisioning()
    let driver = ContainerHostDriver(hosts: [:], directory: directory, provisioning: provisioning)
    let kept = try await driver.create()
    let instance = try await driver.deriveFromBase(kept)
    let orphan = try await driver.create()
    let orphanInstance = try await driver.deriveFromBase(orphan)
    guard case .remote(let keptID) = kept, case .remote(let instanceID) = instance,
      case .remote(let orphanID) = orphan
    else { return XCTFail("not remote hosts") }
    XCTAssertEqual(try leftovers("images", runtime: runtime, label: label).count, 2)

    let young = await driver.sweep(keeping: [keptID, instanceID], grace: 3600)
    XCTAssertEqual(young, [])
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label).count, 4, "young ones went")

    let old = await driver.sweep(keeping: [keptID, instanceID], grace: 0)
    XCTAssertEqual(old, [])
    let names = try docker(
      runtime, ["ps", "-a", "--filter", "label=\(label!)", "--format", "{{.Names}}"])
    XCTAssertEqual(
      Set(names.split(separator: "\n").map(String.init)),
      [ContainerHostDriver.containerName(keptID), ContainerHostDriver.containerName(instanceID)])
    XCTAssertFalse(names.contains(ContainerHostDriver.containerName(orphanID)))
    XCTAssertEqual(
      try leftovers("images", runtime: runtime, label: label).count, 1,
      "the orphaned instance's image stayed, or the recorded one's went")
    _ = orphanInstance
    try await onHost(driver, instance, "true")

    for host in [instance, kept] { try await driver.destroy(host) }
  }

  /// Derives from one base at once: each gets a host, port and identity of its own, and the
  /// driver's registry keeps them apart.
  func testConcurrentDerivesFromOneBaseEachGetTheirOwnHost() async throws {
    let provisioning = try provisioning()
    let driver = ContainerHostDriver(hosts: [:], directory: directory, provisioning: provisioning)
    let base = try await driver.create()

    let instances = try await withThrowingTaskGroup(of: HostID.self) { group in
      for _ in 0..<3 { group.addTask { try await driver.deriveFromBase(base) } }
      return try await group.reduce(into: [HostID]()) { $0.append($1) }
    }

    XCTAssertEqual(Set(instances).count, 3)
    var keys: Set<String> = []
    for instance in instances {
      keys.insert(
        try await onHost(driver, instance, "cut -d' ' -f2 /etc/ssh/ssh_host_ed25519_key.pub"))
    }
    XCTAssertEqual(keys.count, 3, "concurrent derives share a host key")
    for host in instances + [base] { try await driver.destroy(host) }
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label), [])
    XCTAssertEqual(try leftovers("images", runtime: runtime, label: label), [])
  }

  /// A derive that fails and cannot remove what it made says what is still there (#280 review),
  /// rather than dropping the host from its registry with its container still running.
  func testADeriveThatCannotRemoveItsContainerSaysWhatIsLeft() async throws {
    let (script, failing) = try failingRuntime()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: try provisioning(runtime: script))
    let base = try await driver.create()
    // The identity read fails, then removing the container fails too.
    try "exec rm".write(to: failing, atomically: true, encoding: .utf8)

    do {
      _ = try await driver.deriveFromBase(base)
      XCTFail("a derive that failed succeeded")
    } catch HostDriverError.leftBehind(let cause, let leftover) {
      XCTAssertTrue(cause.contains("never minted"), cause)
      XCTAssertTrue(leftover.contains { $0.hasPrefix("container workroom-") }, "\(leftover)")
    }
    try FileManager.default.removeItem(at: failing)
    // tearDown removes what was left, by label.
  }
}
