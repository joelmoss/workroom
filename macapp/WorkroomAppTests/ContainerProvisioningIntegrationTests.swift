import XCTest

@testable import Workroom

/// `ContainerHostDriver`'s provisioning (#252): workroom hosts made from the ssh fixture's image
/// with the container runtime. Skipped unless run through the fixture
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

  /// The containers (`ps`) or images (`images`) carrying this test's label. `-a` for both: an
  /// untagged image is listed only with it.
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

  func testAHostIsReachableItsAgentServesAndDestroyingItLeavesNothing() async throws {
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

  func testFreshHostsHaveAnIdentityOfTheirOwn() async throws {
    let provisioning = try provisioning()
    let driver = ContainerHostDriver(hosts: [:], directory: directory, provisioning: provisioning)
    let first = try await driver.create()
    let second = try await driver.create()

    for host in [first, second] {
      let connection = try await AgentVCSConnection.connect(
        host: host, stream: try await driver.openStream(to: host))
      connections.append(connection)
    }
    let firstIdentity = try await identity(driver, first)
    let secondIdentity = try await identity(driver, second)
    for (name, index) in [("ssh host key", 0), ("machine-id", 1)] {
      XCTAssertNotEqual(firstIdentity[index], secondIdentity[index], "two hosts share a \(name)")
    }

    for host in [first, second] { try await driver.destroy(host) }
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label), [])
  }

  /// A runtime that runs the real one, except for the subcommand named in `failing` when that
  /// file exists: a provider that fails partway through a create. Named
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

  func testACreateThatFailsAtEachStepLeavesNoContainerBehind() async throws {
    let (script, failing) = try failingRuntime()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: try provisioning(runtime: script))

    // `run` makes the container; `exec` comes once it is running. A failed `exec` reads as an
    // identity never minted, so it carries no runtime message.
    for step in ["run", "run+", "exec"] {
      try step.write(to: failing, atomically: true, encoding: .utf8)
      do {
        _ = try await driver.create()
        XCTFail("a create that failed at \(step) succeeded")
      } catch HostDriverError.provisioning(let detail) {
        XCTAssertTrue(
          detail.contains(step == "exec" ? "never minted" : "injected failure"),
          "\(step): \(detail)")
      }
      XCTAssertEqual(
        try leftovers("ps", runtime: runtime, label: label), [],
        "a create that failed at \(step) left a container")
    }
    try FileManager.default.removeItem(at: failing)
  }

  /// A workroom's supervisor keeps screens on a disk that outlives a reboot (#232, #252): a pane
  /// that reattaches after the box is stopped and started is shown its last screen, ended, rather
  /// than a fresh shell. The restart keeps the host's address and its identity, so the pane's ssh
  /// gets in with the key pinned at the create.
  func testAPaneOnAWorkroomIsShownItsLastScreenAfterAReboot() async throws {
    let provisioning = try provisioning()
    let driver = ContainerHostDriver(hosts: [:], directory: directory, provisioning: provisioning)
    let instance = try await driver.create()
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

    try await driver.destroy(instance)
  }

  /// A later launch's driver takes back what an earlier one made (#253): from its record alone, it
  /// reaches the host on its pinned key, and destroys it.
  func testADriverInALaterLaunchAdoptsARecordedHost() async throws {
    let provisioning = try provisioning()
    let earlier = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("earlier"),
      provisioning: provisioning)
    let host = try await earlier.create()
    let record = try XCTUnwrap(earlier.record(of: host))
    XCTAssertNil(record.image)
    // Through the descriptor, as config holds it between launches.
    let stored = try JSONDecoder().decode(
      HostDescriptor.self,
      from: try JSONEncoder().encode(HostDescriptor(driver: "container", container: record)))
    XCTAssertEqual(stored.container, record)

    let later = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("later"), provisioning: provisioning)
    guard case .remote(let id) = host else { return XCTFail("not a remote host") }
    try later.adopt(id, try XCTUnwrap(stored.container))
    let adopted = try await identity(later, host)
    let original = try await identity(earlier, host)
    XCTAssertEqual(adopted, original, "the adopted host is another machine")

    try await later.destroy(host)
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label), [])
  }

  // Value: protects=a workroom an older build derived keeps the commit image it runs from through
  // every sweep, and deleting it removes that image; fails_when=destroy stops removing a record's
  // image or the sweep stops keeping a recorded host's; why_new=the derive tests that reached
  // these paths went with deriveFromBase; seam=none
  /// A host an older build derived from a base records the image it was run from, which only it
  /// uses: the sweep keeps that image while the host is recorded, and destroying the host takes the
  /// image with it, a whole disk's worth of storage.
  func testAnOlderBuildsDerivedHostKeepsItsImageUntilItIsDestroyed() async throws {
    let provisioning = try provisioning()
    let earlier = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("earlier"),
      provisioning: provisioning)
    let host = try await earlier.create()
    guard case .remote(let id) = host else { return XCTFail("not a remote host") }
    // As an older build's derive committed it: the driver's labels, and made long ago.
    let labels = (provisioning.labels + ["\(ContainerHostDriver.createdLabel)=0"]).flatMap {
      ["--change", "LABEL \($0)"]
    }
    let image = try docker(
      runtime, ["commit"] + labels + [ContainerHostDriver.containerName(id)])
    XCTAssertTrue(ContainerHostDriver.isImageID(image), image)
    let record = try XCTUnwrap(earlier.record(of: host))

    let later = ContainerHostDriver(
      hosts: [:], directory: directory.appendingPathComponent("later"), provisioning: provisioning)
    try later.adopt(
      id,
      ContainerHostDriver.Record(
        address: record.address, port: record.port, user: record.user, hostKey: record.hostKey,
        image: image, context: record.context))
    for _ in 0..<2 {
      let failures = await later.sweep(keeping: [id], grace: 0)
      XCTAssertEqual(failures, [])
    }
    XCTAssertEqual(
      try leftovers("images", runtime: runtime, label: label).count, 1,
      "the sweep took a recorded host's image")

    try await later.destroy(host)
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label), [])
    XCTAssertEqual(
      try leftovers("images", runtime: runtime, label: label), [],
      "destroying the host left its image")
  }

  /// A record naming an image that is not an older derive's commit is refused: `destroy` removes it
  /// by force.
  func testAdoptRefusesARecordWhoseImageIsNotAnImageID() throws {
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: try provisioning())
    let record = ContainerHostDriver.Record(
      address: "127.0.0.1", port: 2222, user: "workroom", hostKey: "ssh-ed25519 AAAA",
      image: "debian:bookworm")
    XCTAssertThrowsError(try driver.adopt(UUID(), record))
  }

  /// The sweep removes what carries the driver's labels and no record names, and leaves the
  /// recorded hosts and whatever is younger than its grace (#253).
  func testSweepRemovesOnlyUnrecordedResourcesPastTheirGrace() async throws {
    let provisioning = try provisioning()
    let driver = ContainerHostDriver(hosts: [:], directory: directory, provisioning: provisioning)
    let kept = try await driver.create()
    let orphan = try await driver.create()
    guard case .remote(let keptID) = kept, case .remote(let orphanID) = orphan else {
      return XCTFail("not remote hosts")
    }

    let young = await driver.sweep(keeping: [keptID], grace: 3600)
    XCTAssertEqual(young, [])
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label).count, 2, "young ones went")

    // The first sweep to find the orphan unknown only writes it down (#284).
    let firstSweep = await driver.sweep(keeping: [keptID], grace: 0)
    XCTAssertEqual(firstSweep, [])
    XCTAssertEqual(
      try leftovers("ps", runtime: runtime, label: label).count, 2, "one sweep took a container")

    let old = await driver.sweep(keeping: [keptID], grace: 0)
    XCTAssertEqual(old, [])
    let names = try docker(
      runtime, ["ps", "-a", "--filter", "label=\(label!)", "--format", "{{.Names}}"])
    XCTAssertEqual(
      Set(names.split(separator: "\n").map(String.init)),
      [ContainerHostDriver.containerName(keptID)])
    XCTAssertFalse(names.contains(ContainerHostDriver.containerName(orphanID)))
    try await onHost(driver, kept, "true")

    try await driver.destroy(kept)
  }

  /// Creates at once: each gets a host, port and identity of its own, and the driver's registry
  /// keeps them apart.
  func testConcurrentCreatesEachGetTheirOwnHost() async throws {
    let provisioning = try provisioning()
    let driver = ContainerHostDriver(hosts: [:], directory: directory, provisioning: provisioning)

    let hosts = try await withThrowingTaskGroup(of: HostID.self) { group in
      for _ in 0..<3 { group.addTask { try await driver.create() } }
      return try await group.reduce(into: [HostID]()) { $0.append($1) }
    }

    XCTAssertEqual(Set(hosts).count, 3)
    var keys: Set<String> = []
    for host in hosts {
      keys.insert(try await onHost(driver, host, "cut -d' ' -f2 /etc/ssh/ssh_host_ed25519_key.pub"))
    }
    XCTAssertEqual(keys.count, 3, "concurrent creates share a host key")
    for host in hosts { try await driver.destroy(host) }
    XCTAssertEqual(try leftovers("ps", runtime: runtime, label: label), [])
  }

  /// A create that fails and cannot remove what it made says what is still there (#280 review),
  /// rather than dropping the host from its registry with its container still running.
  func testACreateThatCannotRemoveItsContainerSaysWhatIsLeft() async throws {
    let (script, failing) = try failingRuntime()
    let driver = ContainerHostDriver(
      hosts: [:], directory: directory, provisioning: try provisioning(runtime: script))
    // The identity read fails, then removing the container fails too.
    try "exec rm".write(to: failing, atomically: true, encoding: .utf8)

    do {
      _ = try await driver.create()
      XCTFail("a create that failed succeeded")
    } catch HostDriverError.leftBehind(let cause, let leftover, _) {
      XCTAssertTrue(cause.contains("never minted"), cause)
      XCTAssertTrue(leftover.contains { $0.hasPrefix("container workroom-") }, "\(leftover)")
    }
    try FileManager.default.removeItem(at: failing)
    // tearDown removes what was left, by label.
  }
}
