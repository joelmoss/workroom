import CryptoKit
import XCTest

@testable import Workroom

/// `BoxdHostDriver` on real boxd machines (#256): bases, workrooms derived from them through the
/// portable path, and what each failure leaves. These make and remove real machines on the
/// signed-in boxd account, so they run only when asked for, with the sandbox off (the CLI's gRPC
/// does not go through the sandbox's proxy):
///
///   TEST_RUNNER_WR_BOXD_TESTS=1 \
///     make app-test APP_TEST_FLAGS=-only-testing:WorkroomAppTests/BoxdIntegrationTests
///
/// `TEST_RUNNER_WR_BOXD_CLI` names the CLI if it is not `~/.local/bin/boxd`. Every machine and
/// snapshot a test makes carries its own prefix, and `tearDown` removes whatever is left by it.
final class BoxdIntegrationTests: XCTestCase {
  private var directory: URL!
  private var prefix: String!
  private var cli: URL!
  private var connections: [AgentVCSConnection] = []

  override func setUp() async throws {
    try await super.setUp()
    let environment = ProcessInfo.processInfo.environment
    guard environment["WR_BOXD_TESTS"] == "1" else {
      throw XCTSkip("set TEST_RUNNER_WR_BOXD_TESTS=1 to run these on boxd")
    }
    guard PersistentSessionPaths.linuxAgentURL(architecture: "x86_64") != nil else {
      throw XCTSkip("this build bundles no Linux agent")
    }
    cli = URL(
      fileURLWithPath: environment["WR_BOXD_CLI"]
        ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/boxd").path)
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-boxd-\(UUID().uuidString.prefix(8))")
    prefix = "wrtest-\(UUID().uuidString.prefix(8).lowercased())"
  }

  override func tearDown() async throws {
    for connection in connections { await connection.close() }
    connections.removeAll()
    for host in attached {
      // `connect` starts the host's model's watch, which would otherwise outlive the test.
      if case .remote(let id) = host { await MainActor.run { WakefulnessModel.forgetHost(id) } }
      if let lease = await HostConnectionManager.shared.snapshot(for: host).lease {
        await HostConnectionManager.shared.disconnect(lease)
      }
    }
    attached.removeAll()
    if cli != nil, prefix != nil {
      for name in (try? leftovers("machine")) ?? [] {
        _ = try? boxd(["machine", "remove", name, "-y"])
      }
      for name in (try? leftovers("snapshots")) ?? [] {
        _ = try? boxd(["snapshots", "remove", name, "-y"])
      }
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
    try await super.tearDown()
  }

  // MARK: Helpers

  private func driver(cli override: URL? = nil) -> BoxdHostDriver {
    BoxdHostDriver(
      configuration: .init(cli: override ?? cli, prefix: prefix), directory: directory)
  }

  /// The real CLI, run from here rather than through the driver, so a check is never the thing
  /// under test. Its stdout; a failure throws with its stderr.
  @discardableResult
  private func boxd(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = cli
    process.arguments = arguments + ["--json"]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let said = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw HostDriverError.provisioning(String(decoding: said, as: UTF8.self))
    }
    return String(decoding: data, as: UTF8.self)
  }

  /// This test's machines (`machine`) or snapshots (`snapshots`), by name.
  private func leftovers(_ kind: String) throws -> [String] {
    let listed = try boxd([kind, "list"])
    let rows = try JSONSerialization.jsonObject(with: Data(listed.utf8)) as? [[String: Any]] ?? []
    return rows.compactMap { $0["name"] as? String }.filter { $0.hasPrefix(prefix + "-") }.sorted()
  }

  private func name(_ host: HostID) -> String {
    guard case .remote(let id) = host else { return "" }
    return "\(prefix!)-\(id.uuidString.lowercased())"
  }

  @discardableResult
  private func onHost(_ driver: any HostDriver, _ host: HostID, _ command: String)
    async throws -> String
  {
    let (status, output) = try await driver.exec(command, on: host).communicate(nil, timeout: 30)
    XCTAssertEqual(status, 0, "on the host, \(command) failed: \(output)")
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The machine identity open question 9 lists, as measured on boxd (Phase 0, item 6).
  private func identity(_ driver: any HostDriver, _ host: HostID) async throws -> [String] {
    [
      try await onHost(driver, host, "cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub"),
      try await onHost(driver, host, "cat /etc/machine-id"),
      try await onHost(driver, host, "cat /proc/sys/kernel/random/boot_id"),
    ]
  }

  private func connect(_ driver: any HostDriver, _ host: HostID) async throws
    -> AgentVCSConnection
  {
    let connection = try await AgentBootstrap.connect(
      host: host, driver: driver, socket: BoxdHostDriver.Configuration(cli: cli).agentSocket,
      handOff: false)
    connections.append(connection)
    return connection
  }

  // MARK: The driver

  /// AC 3, for the machine: each derived workroom keeps its base's disk, and mints its own ssh
  /// host key and machine-id, and boots its own kernel (which goes red without the derive's
  /// reboot). The supervisor serves the agent on every
  /// one, and destroying them leaves nothing.
  func testInstancesDerivedFromOneBaseCarryItsDiskButMintTheirOwnIdentity() async throws {
    let driver = driver()
    let base = try await driver.create()
    try await onHost(driver, base, "echo from-the-base > ~/template")
    _ = try await connect(driver, base)
    let baseIdentity = try await identity(driver, base)

    let first = try await driver.deriveFromBase(base)
    let second = try await driver.deriveFromBase(base)

    for instance in [first, second] {
      let template = try await onHost(driver, instance, "cat ~/template")
      XCTAssertEqual(template, "from-the-base")
      // The agent the base was given, started by the instance's own supervisor after its reboot.
      _ = try await connect(driver, instance)
    }
    let firstIdentity = try await identity(driver, first)
    let secondIdentity = try await identity(driver, second)
    // A boot_id of its own is a kernel of its own: the reboot ran, so none of the processes a
    // restored snapshot carries over survived. Every fresh boxd machine shares one boot_id
    // (measured), so only the reboot can make it differ.
    for (name, index) in [("ssh host key", 0), ("machine-id", 1), ("boot_id", 2)] {
      XCTAssertNotEqual(
        firstIdentity[index], secondIdentity[index], "two instances share a \(name)")
      XCTAssertNotEqual(
        firstIdentity[index], baseIdentity[index], "an instance kept its base's \(name)")
      XCTAssertNotEqual(
        secondIdentity[index], baseIdentity[index], "an instance kept its base's \(name)")
    }

    for host in [first, second] { try await driver.destroy(host) }
    XCTAssertEqual(try leftovers("machine"), [name(base)])
    XCTAssertEqual(try leftovers("snapshots"), [], "a derive left its snapshot")
    try await driver.destroy(base)
    try await driver.destroy(base)  // Gone already: still a success.
    XCTAssertEqual(try leftovers("machine"), [])
  }

  /// A derive returns once its agent answers, not merely once its identity is minted: the
  /// supervisor starts the agent after the identity unit, so a connection made at once could find
  /// nothing listening. The base's supervisor is made slow to show it.
  func testADerivedWorkroomServesAsSoonAsItsDeriveReturns() async throws {
    let driver = driver()
    let base = try await driver.create()
    _ = try await connect(driver, base)
    try await onHost(
      driver, base,
      "sudo mkdir -p /etc/systemd/system/workroom-agent.service.d"
        + " && printf '[Service]\\nExecStartPre=/bin/sleep 8\\n'"
        + " | sudo tee /etc/systemd/system/workroom-agent.service.d/slow.conf > /dev/null"
        + " && sudo systemctl daemon-reload")

    let instance = try await driver.deriveFromBase(base)
    // No bootstrap: straight to the agent, as a caller would once the derive has returned.
    let connection = try await AgentVCSConnection.connect(
      host: instance, stream: try await driver.openStream(to: instance))
    connections.append(connection)

    for host in [instance, base] { try await driver.destroy(host) }
  }

  /// AC 5, for the provider's steps: a derive that fails at each CLI step, or after it ran (`+`:
  /// the machine or snapshot exists and the CLI said otherwise), leaves no machine or snapshot.
  func testADeriveThatFailsAtEachStepLeavesNoMachineOrSnapshot() async throws {
    let (script, failing) = try failingCLI()
    let driver = driver(cli: script)
    let base = try await driver.create()

    for step in [
      "snapshots save", "snapshots save+", "machine new", "machine new+", "snapshots remove",
      "machine reboot",
    ] {
      try step.write(to: failing, atomically: true, encoding: .utf8)
      do {
        _ = try await driver.deriveFromBase(base)
        XCTFail("a derive that failed at \(step) succeeded")
      } catch HostDriverError.provisioning(let detail) {
        XCTAssertTrue(detail.contains("injected failure"), "\(step): \(detail)")
      }
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: failing.path), "the derive never reached \(step)")
      XCTAssertEqual(
        try leftovers("machine"), [name(base)], "a derive that failed at \(step) left a machine")
      XCTAssertEqual(
        try leftovers("snapshots"), [], "a derive that failed at \(step) left a snapshot")
    }
    try await driver.destroy(base)
  }

  /// The CLI, except that the command (`machine new`, `snapshots save`, …) named in `failing`
  /// fails once, and the file goes. Named with a `+`, the command runs and THEN fails, as a CLI
  /// killed after the API took the request does. Once, so the rollback's own `remove` goes
  /// through.
  private func failingCLI() throws -> (cli: URL, failing: URL) {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let failing = directory.appendingPathComponent("failing")
    let script = directory.appendingPathComponent("boxd")
    try """
    #!/bin/sh
    step=$(cat \(PosixShell.quoted(failing.path)) 2>/dev/null)
    if [ "$step" = "$1 $2" ]; then
      rm -f \(PosixShell.quoted(failing.path)); echo "error: injected failure" >&2; exit 1
    fi
    if [ "$step" = "$1 $2+" ]; then
      rm -f \(PosixShell.quoted(failing.path))
      \(PosixShell.quoted(cli.path)) "$@" >/dev/null; echo "error: injected failure" >&2; exit 1
    fi
    exec \(PosixShell.quoted(cli.path)) "$@"

    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (script, failing)
  }

  // MARK: Workrooms, through the derivation sequence

  /// A `BoxdHostDriver` whose bases also run the ssh fixture's GitHub and broker
  /// (`vcs/scripts/ssh-fixture/fake-github.py`), as systemd units so every workroom derived from
  /// them runs its own: https for github.com on the machine's loopback, trusted for that host
  /// only, behind a token check. git reaches it through `http.curloptResolve`, not `/etc/hosts`,
  /// and both settings are in the user's global config, not the system's: boxd rewrites
  /// `/etc/hosts` and `/etc/gitconfig` at every boot (measured).
  private struct WithFakeGitHub: HostTerminalDriver {
    let driver: BoxdHostDriver
    static let cloneToken = "ghs_fixture_clone_token_0123456789"

    var traits: HostDriverTraits { driver.traits }
    func deriveFromBase(_ base: HostID) async throws -> HostID {
      try await driver.deriveFromBase(base)
    }
    func destroy(_ host: HostID) async throws { try await driver.destroy(host) }
    func openStream(to host: HostID) async throws -> HostStream {
      try await driver.openStream(to: host)
    }
    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      try await driver.exec(command, on: host)
    }
    func attachCommand(
      to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
      metadata: [(key: String, value: String)]
    ) throws -> String {
      try driver.attachCommand(
        to: host, session: session, workingDirectory: workingDirectory, restored: restored,
        metadata: metadata)
    }
    func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool {
      driver.hostRefusedLastAttach(of: session, on: host)
    }

    func create() async throws -> HostID {
      let host = try await driver.create()
      let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../vcs/scripts/ssh-fixture/fake-github.py")
      let program = try String(contentsOf: fake, encoding: .utf8)
      let setup = """
        set -eu
        mkdir -p /etc/workroom-fixture
        cat > /usr/local/bin/fake-github.py <<'PY'
        \(program)
        PY
        openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=github.com \
          -addext subjectAltName=DNS:github.com \
          -keyout /etc/workroom-fixture/github.key -out /etc/workroom-fixture/github.pem 2>/dev/null
        chown boxd:boxd /etc/workroom-fixture/github.key
        echo \(Self.cloneToken) > /etc/workroom-fixture/clone-token
        sudo -u boxd -H git config --global \
          http.https://github.com/.sslCAInfo /etc/workroom-fixture/github.pem
        sudo -u boxd -H git config --global http.curloptResolve github.com:443:127.0.0.1
        seed=$(mktemp -d)
        git init -q -b main "$seed"
        echo origin > "$seed/README"
        git -C "$seed" add README
        git -C "$seed" -c user.name=F -c user.email=f@example.com commit -qm initial
        git clone -q --bare "$seed" /srv/origin.git
        chown -R boxd:boxd /srv/origin.git
        cat > /etc/systemd/system/workroom-fake-github.service <<'UNIT'
        [Service]
        User=boxd
        AmbientCapabilities=CAP_NET_BIND_SERVICE
        ExecStart=/usr/bin/python3 /usr/local/bin/fake-github.py
        Restart=always
        [Install]
        WantedBy=multi-user.target
        UNIT
        systemctl daemon-reload
        systemctl enable --now workroom-fake-github.service
        """
      let (status, output) = try await driver.exec("sudo sh -s", on: host).communicate(
        Data(setup.utf8), timeout: 120)
      guard status == 0 else {
        try? await driver.destroy(host)
        throw HostDriverError.provisioning("the fake GitHub did not install: \(output)")
      }
      return host
    }
  }

  private static let path = "/home/boxd/project"
  private static let cloneToken = BrokerStub.Answer(
    body: #"{"token":"\#(WithFakeGitHub.cloneToken)","expires_at":"2026-10-01T18:00:00Z"}"#)
  private static let grant = BrokerStub.Answer(
    status: 201,
    body: #"{"grant_id":"g1","enrolment_code":"one-time","repository_id":1,"expires_at":"x"}"#)
  private static let cancelled = BrokerStub.Answer(body: #"{"grant_id":"g1","state":"cancelled"}"#)

  private var grantsCancelled: Int {
    BrokerStub.requests.filter {
      $0.request.httpMethod == "DELETE" && $0.request.url?.path == "/broker/grants/g1"
    }.count
  }

  /// The derivation sequence over `driver`. The Mac's broker calls go to `BrokerStub`; each
  /// agent enrols with the fake broker on its own machine, `brokerURL` (or one that refuses).
  private func environment(_ driver: any HostDriver, brokerURL: String = "http://127.0.0.1:8081")
    -> RemoteProvisioning.Environment
  {
    let socket = BoxdHostDriver.Configuration(cli: cli).agentSocket
    return RemoteProvisioning.Environment(
      driver: driver, agentSocket: socket,
      client: BrokerClient(
        baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey()),
        session: BrokerStub.session),
      agentBroker: .init(url: { _, _, _ in URL(string: brokerURL)! }, release: { _ in }),
      connect: { host in
        try await AgentBootstrap.connect(
          host: host, driver: driver, socket: socket, handOff: false)
      },
      revoke: { _ in })
  }

  /// One shell line run through boxd's own exec, the provider's control plane, rather than over
  /// the Mac's link: as the ssh user, from the workroom's clone. Its output and status.
  private func onBox(_ host: HostID, _ line: String) throws -> String {
    let process = Process()
    process.executableURL = cli
    process.arguments = [
      "machine", "exec", name(host), "--", "cd \(Self.path) && { \(line); }; echo exit=$?",
    ]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n")
      .filter { !$0.contains("new version of boxd") && !$0.contains("downloads/install.sh") }
      .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// AC 1 (through the sequence the app runs, `RemoteProvisioning`; the app's own UI is #253's),
  /// AC 2 and AC 3 for enrolment, and AC 4.
  ///
  /// Two workrooms are derived from one base, each on its own branch with its own enrolment key.
  /// git on a workroom gets its token from the agent's helper, which the broker minted, not from
  /// boxd's own helper (boxd installs one in system config), and with the Mac's link gone it
  /// fetches and pushes. After its machine is stopped and started, a pane comes back to its last
  /// screen and git still mints: the enrolment is on the home disk.
  @MainActor
  func testWorkroomsDerivedOnBoxdPushWithTheMacDisconnectedAndSurviveAStop() async throws {
    let driver = WithFakeGitHub(driver: driver())
    let environment = environment(driver)
    BrokerStub.reset([Self.cloneToken])
    let base = try await RemoteProvisioning.buildBase(
      repository: "o/r", cloneURL: "https://github.com/origin.git", path: Self.path,
      in: environment, record: { _ in })

    var instances: [(RemoteProvisioning.Instance, UUID)] = []
    var keys: [String] = []
    for branch in ["wr-one", "wr-two"] {
      BrokerStub.reset([Self.grant])
      let workroom = UUID()
      let instance = try await RemoteProvisioning.derive(
        from: base, workroom: workroom, branch: branch, in: environment)
      instances.append((instance, workroom))
      let head = try await RemoteProvisioning.git(
        ["rev-parse", "--abbrev-ref", "HEAD"], in: instance.path, on: instance.connection)
      XCTAssertEqual(head.trimmingCharacters(in: .whitespacesAndNewlines), branch)
      let state = try await onHost(
        driver, instance.host, "cat ~/.local/state/workroom/agent/broker.json")
      let enrolment = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(state.utf8)) as? [String: Any])
      XCTAssertEqual(enrolment["workroom_id"] as? String, workroom.uuidString.lowercased())
      keys.append(try XCTUnwrap(enrolment["key"] as? String))
    }
    XCTAssertNotEqual(keys[0], keys[1], "two workrooms share an enrolment key")

    let (first, _) = instances[0]
    await first.connection.close()
    // boxd's helper is still in system config, and the agent's comes after an empty entry that
    // resets the list, so the password git is given is the broker's.
    let fill = try onBox(
      first.host, "printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill")
    XCTAssertTrue(fill.contains("password=ghs_minted_"), fill)
    XCTAssertTrue(
      try onBox(first.host, "git config --system --get credential.https://github.com.helper")
        .contains("boxd"),
      "boxd's own helper is gone, so this shows nothing about which one wins")

    let commit = try onBox(
      first.host,
      "git -c user.name=W -c user.email=w@example.com commit -q --allow-empty -m pushed"
        + " && git rev-parse HEAD")
    let pushed = try XCTUnwrap(commit.split(separator: "\n").first.map(String.init), commit)
    // The fake GitHub refuses a push with no token, so the one below is the helper's doing.
    let refused = try onBox(
      first.host, "git -c credential.https://github.com.helper= push -q origin HEAD 2>&1")
    XCTAssertFalse(refused.hasSuffix("exit=0"), "the fake GitHub took a push with no token")
    XCTAssertTrue(try onBox(first.host, "git fetch -q origin").hasSuffix("exit=0"))
    let push = try onBox(first.host, "git push -q origin HEAD 2>&1")
    XCTAssertTrue(push.hasSuffix("exit=0"), push)
    XCTAssertEqual(
      try onBox(first.host, "git -C /srv/origin.git rev-parse refs/heads/wr-one"),
      "\(pushed)\nexit=0")

    // AC 4: a pane's last screen, after a stop and start.
    let session = UUID()
    let pane = try RemoteHostIntegrationTests.Pane(
      command: driver.attachCommand(
        to: first.host, session: session, workingDirectory: Self.path, restored: false))
    defer { pane.dropLink() }
    try await Task.sleep(for: .seconds(1))
    pane.type("echo LAST-SC\"\"REEN\n")
    XCTAssertTrue(pane.read(until: "LAST-SCREEN").contains("LAST-SCREEN"))
    // The stop kills the agent outright, so only what it has already written survives.
    let record = "~/.local/state/workroom/screens/\(session.uuidString.lowercased()).vt"
    var written = false
    for _ in 0..<100 where !written {
      written = try onBox(first.host, "grep -q LAST-SCREEN \(record)").hasSuffix("exit=0")
      if !written { try await Task.sleep(for: .milliseconds(200)) }
    }
    XCTAssertTrue(written, "the screen was never written to \(record)")
    pane.dropLink()
    let before = try await identity(driver, first.host)
    try boxd(["machine", "stop", name(first.host)])
    try boxd(["machine", "start", name(first.host)])

    // `start` returns while the machine boots, so the first attaches can find no agent yet: they
    // exit 255, and the app attaches again with backoff, as this does.
    var seen = ""
    for _ in 0..<30 where !seen.contains("host restarted") {
      let again = try RemoteHostIntegrationTests.Pane(
        command: driver.attachCommand(
          to: first.host, session: session, workingDirectory: Self.path, restored: true))
      seen = again.read(until: "host restarted", within: 10)
      if !seen.contains("host restarted") {
        XCTAssertEqual(again.exitCode(within: 10), 255, "an attach failed for good: \(seen)")
        try await Task.sleep(for: .seconds(2))
      }
      again.dropLink()
    }
    XCTAssertTrue(seen.contains("LAST-SCREEN"), seen)
    XCTAssertTrue(seen.contains("ended when its host restarted"), seen)
    let after = try await identity(driver, first.host)
    XCTAssertEqual(before[0...1], after[0...1], "a stop and start minted a new identity")
    let refill = try onBox(
      first.host, "printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill")
    XCTAssertTrue(refill.contains("password=ghs_minted_"), "the enrolment was lost: \(refill)")

    for (instance, workroom) in instances {
      BrokerStub.reset([Self.cancelled])
      try await RemoteProvisioning.destroy(instance, workroom: workroom, in: environment)
      XCTAssertEqual(grantsCancelled, 1, "destroying a workroom left its grant live")
    }
    XCTAssertEqual(try leftovers("machine"), [name(.remote(base.host))])
    try await RemoteProvisioning.destroyBase(base.host, in: environment, forget: {})
    XCTAssertEqual(try leftovers("machine"), [])
  }

  /// AC 5, for the steps after the provider's: a workroom whose enrolment or checkout fails is
  /// removed with its grant cancelled.
  @MainActor
  func testAWorkroomThatFailsAfterItsDeriveLeavesNoMachineAndNoGrant() async throws {
    let driver = WithFakeGitHub(driver: driver())
    BrokerStub.reset([Self.cloneToken])
    let base = try await RemoteProvisioning.buildBase(
      repository: "o/r", cloneURL: "https://github.com/origin.git", path: Self.path,
      in: environment(driver), record: { _ in })

    // Nothing listens there, so the agent's enrolment fails after the grant is made; and git
    // refuses the branch name only once the instance is enrolled.
    for (step, environment, branch) in [
      ("enrol", environment(driver, brokerURL: "http://127.0.0.1:9"), "wr-enrol"),
      ("checkout", environment(driver), "bad..name"),
    ] {
      BrokerStub.reset([Self.grant, Self.cancelled])
      do {
        _ = try await RemoteProvisioning.derive(
          from: base, workroom: UUID(), branch: branch, in: environment)
        XCTFail("a workroom that failed at \(step) was made")
      } catch {
        switch (step, error) {
        case ("enrol", BrokerError.agent),
          ("checkout", RemoteProvisioning.Failure.git("switch", _)):
          break
        default: XCTFail("\(step) failed for another reason: \(error)")
        }
      }
      XCTAssertEqual(
        try leftovers("machine"), [name(.remote(base.host))],
        "a failure at \(step) left a machine")
      XCTAssertEqual(try leftovers("snapshots"), [], "a failure at \(step) left a snapshot")
      XCTAssertEqual(grantsCancelled, 1, "a failure at \(step) left its grant live")
    }
    try await RemoteProvisioning.destroyBase(base.host, in: environment(driver), forget: {})
  }

  // MARK: In the app (#356)

  /// A remote workroom made and taken down the way the app does it (`RemoteWorkrooms.create` and
  /// `delete` on a boxd driver key): the base is built in the boxd user's home, the workroom's
  /// record names boxd with its org and account, and deleting the workroom, then the base, leaves
  /// no machine and no live grant.
  @MainActor
  func testARemoteWorkroomIsMadeAndTakenDownOnBoxdAsTheAppDoesIt() async throws {
    let driver = WithFakeGitHub(driver: driver())
    let environment = environment(driver)
    let account =
      try JSONSerialization.jsonObject(with: Data(try boxd(["auth"]).utf8))
      as? [String: Any]
    let key = RemoteHosts.DriverKey.boxd(
      org: account?["active_org"] as? String, account: account?["user_id"] as? String)
    let records = Records()
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { _, descriptor in
        records.set(nil, descriptor, as: "w")
        return "w"
      }, record: { name, descriptor in records.set(name, descriptor) },
      forget: { name in records.forget(name) })
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))

    BrokerStub.reset([Self.cloneToken, Self.grant])
    let created = try await RemoteWorkrooms.create(
      repository: repository, cloneURL: "https://github.com/origin.git", base: nil, key: key,
      driver: driver, environment: environment, recorder: recorder)
    await created.instance.connection.close()
    let base = try XCTUnwrap(records.project)
    let workroom = try XCTUnwrap(records.workrooms["w"])
    XCTAssertEqual(base.path, "/home/boxd/r")
    for descriptor in [base, workroom] {
      XCTAssertEqual(descriptor.driver, RemoteWorkrooms.boxdDriver)
      XCTAssertEqual(descriptor.org, key.org)
      XCTAssertEqual(descriptor.account, key.account)
      XCTAssertNil(descriptor.container)
    }
    XCTAssertEqual(RemoteHosts.DriverKey(workroom), key)

    BrokerStub.reset([Self.cancelled])
    try await RemoteWorkrooms.delete(
      "w", host: workroom, environment: environment, recorder: recorder)
    XCTAssertNil(records.workrooms["w"], "the workroom's entry was kept")
    XCTAssertEqual(grantsCancelled, 1, "deleting the workroom left its grant live")
    try await RemoteWorkrooms.deleteBase(base, environment: environment, clear: {})
    XCTAssertEqual(try leftovers("machine"), [])
  }

  private final class Records: @unchecked Sendable {
    private let lock = NSLock()
    private var base: HostDescriptor?
    private var named: [String: HostDescriptor] = [:]
    var project: HostDescriptor? { lock.withLock { base } }
    var workrooms: [String: HostDescriptor] { lock.withLock { named } }
    func set(_ name: String?, _ descriptor: HostDescriptor, as reserved: String? = nil) {
      lock.withLock {
        if let name = name ?? reserved { named[name] = descriptor } else { base = descriptor }
      }
    }
    func forget(_ name: String) { _ = lock.withLock { named.removeValue(forKey: name) } }
  }

  // MARK: Sleep (#257, #356)

  /// boxd's own record of whether a machine is asleep, from its control plane, which never
  /// reaches the machine and so never wakes it.
  private func status(_ host: HostID) throws -> String {
    let got = try JSONSerialization.jsonObject(
      with: Data(try boxd(["machine", "get", name(host)]).utf8))
    return (got as? [String: Any])?["status"] as? String ?? "?"
  }

  private func asleep(_ host: HostID) -> Bool {
    BoxdHostDriver.asleepStatuses.contains((try? status(host)) ?? "")
  }

  /// Suspend and hibernate after `seconds` idle on the network.
  private func idleTimers(_ host: HostID, _ seconds: Int) throws {
    for setting in ["auto-suspend.timeout", "auto-hibernate.timeout"] {
      try boxd(["machine", "config", "set", name(host), setting, String(seconds)])
    }
  }

  /// A job of `seconds` that burns a core and uses no network, writing one line a second to
  /// `~/ticks`, detached so it outlives the exec. A box that sleeps stops its clock, and the ticks.
  private func startJob(_ driver: any HostDriver, _ host: HostID, seconds: Int) async throws {
    try await onHost(
      driver, host,
      "rm -f ~/ticks; nohup sh -c 'i=0; while [ $i -lt \(seconds) ]; do i=$((i+1)); echo $i >> ~/ticks;"
        + " t=$(date +%s); while [ $(date +%s) -eq $t ]; do :; done; done' > /dev/null 2>&1 &")
  }

  /// The ticks the job logged. Reading them wakes the box.
  private func ticks(_ driver: any HostDriver, _ host: HostID) async throws -> Int {
    Int(try await onHost(driver, host, "wc -l < ~/ticks")) ?? 0
  }

  /// Polls boxd every 20 s until `host` is asleep or `limit` passes; when it fell asleep, measured
  /// from `since`, or nil.
  private func sleeps(_ host: HostID, since: ContinuousClock.Instant, within limit: Duration)
    async throws -> Duration?
  {
    while ContinuousClock.now - since < limit {
      if asleep(host) { return ContinuousClock.now - since }
      try await Task.sleep(for: .seconds(20))
    }
    return nil
  }

  /// The app attached to `host` as it is to a workroom that is not selected: its `RemoteHosts`
  /// holds the host's service connection (ssh, with keepalives) through `HostConnectionManager`,
  /// and the host's `WakefulnessModel` watches its verdict (#380), as the sidebar's badge does.
  private func attach(_ driver: BoxdHostDriver, _ host: HostID) async throws -> RemoteHosts {
    guard case .remote(let id) = host else { throw HostDriverError.unknownHost(host) }
    let socket = driver.configuration.agentSocket
    let remote = RemoteHosts(
      makeDriver: { _ in driver },
      connectAgent: { host, driver in
        try await AgentBootstrap.connect(
          host: host, driver: driver, socket: socket, handOff: false)
      })
    remote.adopt(
      [
        Project(
          path: "/proj", vcs: "git",
          workrooms: [
            Workroom(
              name: "w", path: Self.path, vcsName: "workroom/w", warnings: [],
              host: HostDescriptor(
                driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner,
                id: id))
          ])
      ], sweep: false)
    try await remote.connect(host, driver: driver)
    attached.append(host)
    return remote
  }

  private var attached: [HostID] = []

  /// #257's acceptance, rerunnable (#356; it was a TODO). Two machines with 120 s timers run the same 6-minute job with no
  /// network use and no client attached. The control, with no agent, sleeps mid-job, which is
  /// what lets the other result mean anything; the agent's machine logs every tick, then sleeps
  /// once the job has ended. About 10 minutes.
  func testTheHeartbeatKeepsABusyBoxAwakeAndABoxWithoutOneSleeps() async throws {
    let driver = driver()
    let control = HostID.remote(UUID())
    try boxd([
      "machine", "new", name(control), "--auto-suspend-timeout=120", "--auto-hibernate-timeout=120",
    ])
    let kept = try await driver.create()
    try idleTimers(kept, 120)
    // Connected once, to push the agent, then let go: no client is attached for the run.
    let pushed = try await connect(driver, kept)
    await pushed.close()
    let start = ContinuousClock.now
    try await startJob(driver, control, seconds: 360)
    try await startJob(driver, kept, seconds: 360)

    let controlSlept = try await sleeps(control, since: start, within: .seconds(330))
    XCTAssertNotNil(controlSlept, "the control never slept mid-job, so the run proves nothing")
    let keptSlept = try await sleeps(kept, since: start, within: .seconds(600))
    XCTAssertNotNil(keptSlept, "the agent's machine never slept after its job")
    if let keptSlept { XCTAssertGreaterThan(keptSlept, .seconds(360), "it slept under its job") }
    let controlTicks = try await ticks(driver, control)
    let keptTicks = try await ticks(driver, kept)
    XCTAssertLessThan(controlTicks, 360)
    XCTAssertEqual(keptTicks, 360, "the agent's machine missed ticks")
  }

  /// Whether `host` has a service connection in the app.
  private func connected(_ host: HostID) async -> Bool {
    await HostConnectionManager.shared.snapshot(for: host).status == .connected
  }

  /// #380's acceptance: with the app attached as it really is (pushed verdicts, no poll, no
  /// app-side let-go), an idle box must still sleep, or every open workroom would keep its box
  /// awake and billing. Its agent closes the app's idle connection itself, and the app takes that as
  /// the box idle, not an error. Then the user comes back: a port forward kept across the closed
  /// connection wakes the box when used, and selecting the workroom reconnects it. A fresh
  /// machine's start-up traffic holds its timer for about 290 s (#257's acceptance), so it has 7
  /// minutes to sleep. About 8 minutes.
  func testAnIdleBoxStillSleepsWithTheAppAttached() async throws {
    let driver = driver()
    let host = try await driver.create()
    try idleTimers(host, 120)
    let remote = try await attach(driver, host)
    let connection = try await HostConnectionManager.shared.forwarding(host: host).1.connection
    // A forward kept across the connection the agent will close, reconnecting through this test's
    // `RemoteHosts` as the Ports panel's does through the app's: to the box's own sshd, which
    // speaks first.
    let reconnect: PortForward.Reconnect = {
      try? await remote.ensureConnected(host, wake: true)
      return try? await HostConnectionManager.shared.forwarding(host: host).1.connection
    }
    let forward = try AgentForwardService(connection: connection).listen(
      remotePort: 22, reconnect: reconnect, onEvent: { _ in })
    defer { forward.stop() }
    let start = ContinuousClock.now
    while await connected(host), ContinuousClock.now - start < .seconds(300) {
      try await Task.sleep(for: .seconds(5))
    }
    let connectedNow = await connected(host)
    XCTAssertFalse(connectedNow, "the agent never let go of the app's idle connection")
    XCTAssertTrue(
      RemoteHosts.shared.isReleased(host), "the app took the closed connection for an error")
    let slept = try await sleeps(host, since: start, within: .seconds(420))
    XCTAssertNotNil(slept, "an idle box with the app attached never slept")
    guard slept != nil else { return }

    // A connection on the forward wakes the box, and the browser waits rather than failing.
    let client = try TCPClient(port: forward.localPort)
    defer { client.close() }
    let banner = String(decoding: try client.read(8, timeout: 60), as: UTF8.self)
    XCTAssertEqual(banner, "SSH-2.0-", "a forward used after the let-go never reached the box")

    // Selecting the workroom reconnects a box its agent let go of, and its services answer.
    remote.select(host)
    defer { remote.select(nil) }
    try await remote.ensureConnected(host)
    let status = try await HostConnectionManager.shared.wakefulness(host: host).status()
    XCTAssertTrue(status.running)
  }

  /// #380's acceptance, the other half: with the app attached, a busy box stays awake through its
  /// job, the agent keeping its connection while the job runs, and sleeps once it has ended. A
  /// 6-minute job with no network use, timers 120 s, 10 minutes to sleep. About 10 minutes.
  func testABusyBoxWithTheAppAttachedStaysAwakeThroughItsJob() async throws {
    let driver = driver()
    let host = try await driver.create()
    try idleTimers(host, 120)
    _ = try await attach(driver, host)
    let start = ContinuousClock.now
    try await startJob(driver, host, seconds: 360)
    var droppedAt: Duration?
    while ContinuousClock.now - start < .seconds(330) {
      if await !connected(host), droppedAt == nil { droppedAt = ContinuousClock.now - start }
      try await Task.sleep(for: .seconds(10))
    }
    XCTAssertNil(droppedAt, "the agent let go of a busy box's connection")
    let slept = try await sleeps(host, since: start, within: .seconds(600))
    XCTAssertNotNil(slept, "the box never slept after its job")
    if let slept { XCTAssertGreaterThan(slept, .seconds(360), "it slept under its job") }
    let logged = try await ticks(driver, host)
    XCTAssertEqual(logged, 360, "the box missed ticks")
  }
}
