import CryptoKit
import XCTest

@testable import Workroom

/// One real provider, as the parity cases need it (#259): its driver and key, and what the cases
/// do on its machines through its own control plane, never over the Mac's link to the agent.
struct LiveProvider {
  let driver: any HostTerminalDriver
  /// The key a workroom made the way the app does it records.
  let key: RemoteHosts.DriverKey
  /// The user its machines log in as.
  let user: String
  /// The public half of the host key its machines' sshd presents on the machine itself.
  let sshHostKey: String
  /// The machine's name on the provider.
  let name: (HostID) -> String
  /// One shell line on the machine as `user`, run by the provider, not over the Mac's link: its
  /// output, then `exit=<status>`.
  let onBox: (HostID, String) throws -> String
  /// Stops and starts the machine, or restarts it where the provider has no stop.
  let restart: (HostID) throws -> Void
  /// The names of the machines this test made that the provider still has.
  let leftovers: () throws -> [String]
  /// Asserted on a workroom whose git the broker's helper serves, for a provider that installs a
  /// helper of its own (boxd's), showing that the agent's wins over it.
  var providerHelperCheck: ((HostID) throws -> Void)?
  /// Whether the machine's sshd host key survives `restart`, as boxd's (on the disk) does.
  var restartKeepsHostKey = true

  var home: String { "/home/\(user)" }
  var socket: String { driver.agentSocket }
}

/// The cases every real provider must pass alike, apart from how long creation takes (#259's
/// parity criterion). A provider's suite subclasses this, makes its `LiveProvider`, and calls each
/// case from a `test…` method of its own; none of these is a test by itself.
class ProviderParityTestCase: XCTestCase {
  var connections: [AgentVCSConnection] = []

  override func tearDown() async throws {
    for connection in connections { await connection.close() }
    connections.removeAll()
    try await super.tearDown()
  }

  @discardableResult
  func onHost(_ driver: any HostDriver, _ host: HostID, _ command: String)
    async throws -> String
  {
    let (status, output) = try await driver.exec(command, on: host).communicate(nil, timeout: 30)
    XCTAssertEqual(status, 0, "on the host, \(command) failed: \(output)")
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The machine identity open question 9 lists (Phase 0, item 6): the sshd host key the machine
  /// presents, its machine-id, and its boot_id.
  func identity(_ provider: LiveProvider, _ host: HostID) async throws -> [String] {
    [
      try await onHost(provider.driver, host, "cut -d' ' -f1,2 \(provider.sshHostKey)"),
      try await onHost(provider.driver, host, "cat /etc/machine-id"),
      try await onHost(provider.driver, host, "cat /proc/sys/kernel/random/boot_id"),
    ]
  }

  func connect(_ provider: LiveProvider, _ host: HostID) async throws -> AgentVCSConnection {
    let connection = try await AgentBootstrap.connect(
      host: host, driver: provider.driver, socket: provider.socket, handOff: false)
    connections.append(connection)
    return connection
  }

  // MARK: The driver

  /// AC 3, for the machine: each derived workroom keeps its base's disk, and has an sshd host
  /// key, a machine-id and a kernel of its own. The supervisor serves the agent on every one, and
  /// destroying them leaves nothing.
  func instancesCarryTheBaseDiskButNotItsIdentity(_ provider: LiveProvider) async throws {
    let driver = provider.driver
    let base = try await driver.create()
    try await onHost(driver, base, "echo from-the-base > ~/template")
    _ = try await connect(provider, base)
    let baseIdentity = try await identity(provider, base)

    let first = try await driver.deriveFromBase(base)
    let second = try await driver.deriveFromBase(base)

    for instance in [first, second] {
      let template = try await onHost(driver, instance, "cat ~/template")
      XCTAssertEqual(template, "from-the-base")
      // The agent the base was given, started by the instance's own supervisor.
      _ = try await connect(provider, instance)
    }
    let firstIdentity = try await identity(provider, first)
    let secondIdentity = try await identity(provider, second)
    for (name, index) in [("ssh host key", 0), ("machine-id", 1), ("boot_id", 2)] {
      XCTAssertNotEqual(
        firstIdentity[index], secondIdentity[index], "two instances share a \(name)")
      XCTAssertNotEqual(
        firstIdentity[index], baseIdentity[index], "an instance kept its base's \(name)")
      XCTAssertNotEqual(
        secondIdentity[index], baseIdentity[index], "an instance kept its base's \(name)")
    }

    for host in [first, second] { try await driver.destroy(host) }
    XCTAssertEqual(try provider.leftovers(), [provider.name(base)])
    try await driver.destroy(base)
    try await driver.destroy(base)  // Gone already: still a success.
    XCTAssertEqual(try provider.leftovers(), [])
  }

  /// A derive returns once its agent answers, not merely once its identity is minted: the
  /// supervisor starts the agent after the identity unit, so a connection made at once could find
  /// nothing listening. The base's supervisor is made slow to show it.
  func aDerivedWorkroomServesAsSoonAsItsDeriveReturns(_ provider: LiveProvider) async throws {
    let driver = provider.driver
    let base = try await driver.create()
    _ = try await connect(provider, base)
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

  // MARK: Workrooms, through the derivation sequence

  /// A provider's driver whose bases also run the ssh fixture's GitHub and broker
  /// (`vcs/scripts/ssh-fixture/fake-github.py`), as systemd units so every workroom derived from
  /// them runs its own: https for github.com on the machine's loopback, trusted for that host
  /// only, behind a token check. git reaches it through `http.curloptResolve`, not `/etc/hosts`,
  /// and both settings are in the user's global config, not the system's: boxd rewrites
  /// `/etc/hosts` and `/etc/gitconfig` at every boot (measured).
  struct WithFakeGitHub: HostTerminalDriver {
    let driver: any HostTerminalDriver
    let user: String
    static let cloneToken = "ghs_fixture_clone_token_0123456789"

    var traits: HostDriverTraits { driver.traits }
    var agentSocket: String { driver.agentSocket }
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
    func lastAttachLostLink(of session: UUID, on host: HostID) -> Bool {
      driver.lastAttachLostLink(of: session, on: host)
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
        chown \(user):\(user) /etc/workroom-fixture/github.key
        echo \(Self.cloneToken) > /etc/workroom-fixture/clone-token
        sudo -u \(user) -H git config --global \
          http.https://github.com/.sslCAInfo /etc/workroom-fixture/github.pem
        sudo -u \(user) -H git config --global http.curloptResolve github.com:443:127.0.0.1
        seed=$(mktemp -d)
        git init -q -b main "$seed"
        echo origin > "$seed/README"
        git -C "$seed" add README
        git -C "$seed" -c user.name=F -c user.email=f@example.com commit -qm initial
        git clone -q --bare "$seed" /srv/origin.git
        chown -R \(user):\(user) /srv/origin.git
        cat > /etc/systemd/system/workroom-fake-github.service <<'UNIT'
        [Service]
        User=\(user)
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

  static let cloneToken = BrokerStub.Answer(
    body: #"{"token":"\#(WithFakeGitHub.cloneToken)","expires_at":"2026-10-01T18:00:00Z"}"#)
  static let grant = BrokerStub.Answer(
    status: 201,
    body: #"{"grant_id":"g1","enrolment_code":"one-time","repository_id":1,"expires_at":"x"}"#)
  static let cancelled = BrokerStub.Answer(body: #"{"grant_id":"g1","state":"cancelled"}"#)

  var grantsCancelled: Int {
    BrokerStub.requests.filter {
      $0.request.httpMethod == "DELETE" && $0.request.url?.path == "/broker/grants/g1"
    }.count
  }

  /// The derivation sequence over `driver`. The Mac's broker calls go to `BrokerStub`; each
  /// agent enrols with the fake broker on its own machine, `brokerURL` (or one that refuses).
  func environment(
    _ driver: any HostDriver, brokerURL: String = "http://127.0.0.1:8081"
  ) -> RemoteProvisioning.Environment {
    let socket = driver.agentSocket
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

  /// AC 1 (through the sequence the app runs, `RemoteProvisioning`), AC 2 and AC 3 for enrolment,
  /// and AC 4.
  ///
  /// Two workrooms are derived from one base, each on its own branch with its own enrolment key.
  /// git on a workroom gets its token from the agent's helper, which the broker minted, and with
  /// the Mac's link gone it fetches and pushes. After its machine restarts, a pane comes back to
  /// its last screen and git still mints: the enrolment is on the home disk.
  @MainActor
  func workroomsPushWithTheMacDisconnectedAndSurviveARestart(_ provider: LiveProvider)
    async throws
  {
    let path = "\(provider.home)/project"
    let driver = WithFakeGitHub(driver: provider.driver, user: provider.user)
    let environment = environment(driver)
    BrokerStub.reset([Self.cloneToken])
    let base = try await RemoteProvisioning.buildBase(
      repository: "o/r", cloneURL: "https://github.com/origin.git", path: path,
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
    let onBox = { (line: String) in try provider.onBox(first.host, "cd \(path) && { \(line); }") }
    let fill = try onBox("printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill")
    XCTAssertTrue(fill.contains("password=ghs_minted_"), fill)
    try provider.providerHelperCheck?(first.host)

    let commit = try onBox(
      "git -c user.name=W -c user.email=w@example.com commit -q --allow-empty -m pushed"
        + " && git rev-parse HEAD")
    let pushed = try XCTUnwrap(commit.split(separator: "\n").first.map(String.init), commit)
    // The fake GitHub refuses a push with no token, so the one below is the helper's doing.
    let refused = try onBox("git -c credential.https://github.com.helper= push -q origin HEAD 2>&1")
    XCTAssertFalse(refused.hasSuffix("exit=0"), "the fake GitHub took a push with no token")
    XCTAssertTrue(try onBox("git fetch -q origin").hasSuffix("exit=0"))
    let push = try onBox("git push -q origin HEAD 2>&1")
    XCTAssertTrue(push.hasSuffix("exit=0"), push)
    XCTAssertEqual(
      try onBox("git -C /srv/origin.git rev-parse refs/heads/wr-one"), "\(pushed)\nexit=0")

    // AC 4: a pane's last screen, after a restart.
    let session = UUID()
    let pane = try RemoteHostIntegrationTests.Pane(
      command: driver.attachCommand(
        to: first.host, session: session, workingDirectory: path, restored: false))
    defer { pane.dropLink() }
    try await Task.sleep(for: .seconds(1))
    pane.type("echo LAST-SC\"\"REEN\n")
    XCTAssertTrue(pane.read(until: "LAST-SCREEN").contains("LAST-SCREEN"))
    // The restart kills the agent outright, so only what it has already written survives.
    let record = "~/.local/state/workroom/screens/\(session.uuidString.lowercased()).vt"
    var written = false
    for _ in 0..<100 where !written {
      written = try onBox("grep -q LAST-SCREEN \(record)").hasSuffix("exit=0")
      if !written { try await Task.sleep(for: .milliseconds(200)) }
    }
    XCTAssertTrue(written, "the screen was never written to \(record)")
    pane.dropLink()
    let before = try await identity(provider, first.host)
    try provider.restart(first.host)

    // The restart returns while the machine boots, so the first attaches can find no agent yet:
    // they exit 255, and the app attaches again with backoff, as this does.
    var seen = ""
    for _ in 0..<30 where !seen.contains("host restarted") {
      let again = try RemoteHostIntegrationTests.Pane(
        command: driver.attachCommand(
          to: first.host, session: session, workingDirectory: path, restored: true))
      seen = again.read(until: "host restarted", within: 10)
      if !seen.contains("host restarted") {
        XCTAssertEqual(again.exitCode(within: 10), 255, "an attach failed for good: \(seen)")
        try await Task.sleep(for: .seconds(2))
      }
      again.dropLink()
    }
    XCTAssertTrue(seen.contains("LAST-SCREEN"), seen)
    XCTAssertTrue(seen.contains("ended when its host restarted"), seen)
    let after = try await identity(provider, first.host)
    XCTAssertEqual(before[1], after[1], "a restart minted a new machine-id")
    if provider.restartKeepsHostKey {
      XCTAssertEqual(before[0], after[0], "a restart minted a new ssh host key")
    }
    let refill = try onBox("printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill")
    XCTAssertTrue(refill.contains("password=ghs_minted_"), "the enrolment was lost: \(refill)")

    for (instance, workroom) in instances {
      BrokerStub.reset([Self.cancelled])
      try await RemoteProvisioning.destroy(instance, workroom: workroom, in: environment)
      XCTAssertEqual(grantsCancelled, 1, "destroying a workroom left its grant live")
    }
    XCTAssertEqual(try provider.leftovers(), [provider.name(.remote(base.host))])
    try await RemoteProvisioning.destroyBase(base.host, in: environment, forget: {})
    XCTAssertEqual(try provider.leftovers(), [])
  }

  /// AC 5, for the steps after the provider's: a workroom whose enrolment or checkout fails is
  /// removed with its grant cancelled.
  @MainActor
  func aWorkroomThatFailsAfterItsDeriveLeavesNothing(_ provider: LiveProvider) async throws {
    let driver = WithFakeGitHub(driver: provider.driver, user: provider.user)
    BrokerStub.reset([Self.cloneToken])
    let base = try await RemoteProvisioning.buildBase(
      repository: "o/r", cloneURL: "https://github.com/origin.git",
      path: "\(provider.home)/project",
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
        try provider.leftovers(), [provider.name(.remote(base.host))],
        "a failure at \(step) left a machine")
      XCTAssertEqual(grantsCancelled, 1, "a failure at \(step) left its grant live")
    }
    try await RemoteProvisioning.destroyBase(base.host, in: environment(driver), forget: {})
  }

  // MARK: In the app

  /// A remote workroom made and taken down the way the app does it (`RemoteWorkrooms.create` and
  /// `delete` on the provider's driver key): the base is built in the provider user's home, the
  /// workroom's record names the provider with its account, and deleting the workroom, then the
  /// base, leaves no machine and no live grant.
  @MainActor
  func aRemoteWorkroomIsMadeAndTakenDownAsTheAppDoesIt(_ provider: LiveProvider) async throws {
    let driver = WithFakeGitHub(driver: provider.driver, user: provider.user)
    let environment = environment(driver)
    let key = provider.key
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
    XCTAssertEqual(base.path, "\(provider.home)/r")
    for descriptor in [base, workroom] {
      XCTAssertEqual(descriptor.driver, RemoteWorkrooms.driverName(key))
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
    XCTAssertEqual(try provider.leftovers(), [])
  }

  final class Records: @unchecked Sendable {
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
}
