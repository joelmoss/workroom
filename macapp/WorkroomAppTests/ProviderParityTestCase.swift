import DaemonConnection
import HostDrivers
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// One real provider, as the parity cases need it (#259): its driver and key, and what the cases
/// do on its machines through its own control plane, never over the Mac's link to the daemon.
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
  /// Whether the machine's sshd host key survives `restart`, as boxd's (on the disk) does.
  var restartKeepsHostKey = true

  var home: String { "/home/\(user)" }
  var socket: String { driver.daemonSocket }
}

/// The cases every real provider must pass alike, apart from how long creation takes (#259's
/// parity criterion). A provider's suite subclasses this, makes its `LiveProvider`, and calls each
/// case from a `test…` method of its own; none of these is a test by itself.
class ProviderParityTestCase: XCTestCase {
  var connections: [DaemonVCSConnection] = []

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

  func connect(_ provider: LiveProvider, _ host: HostID) async throws -> DaemonVCSConnection {
    let connection = try await DaemonBootstrap.connect(
      host: host, driver: provider.driver, socket: provider.socket, handOff: false)
    connections.append(connection)
    return connection
  }

  // MARK: The driver

  /// AC 3, for the machine: every fresh host has an sshd host key and a machine-id of its own,
  /// whatever its provider's image ships (boxd's ships one of each for every machine, measured
  /// 2026-10-10). The supervisor serves the daemon on each, and destroying them leaves nothing.
  func freshHostsHaveAnIdentityOfTheirOwn(_ provider: LiveProvider) async throws {
    let driver = provider.driver
    let first = try await driver.create()
    let second = try await driver.create()
    for host in [first, second] { _ = try await connect(provider, host) }
    let firstIdentity = try await identity(provider, first)
    let secondIdentity = try await identity(provider, second)
    for (name, index) in [("ssh host key", 0), ("machine-id", 1)] {
      XCTAssertNotEqual(
        firstIdentity[index], secondIdentity[index], "two hosts share a \(name)")
    }

    for host in [first, second] { try await driver.destroy(host) }
    try await driver.destroy(first)  // Gone already: still a success.
    XCTAssertEqual(try provider.leftovers(), [])
  }

  // MARK: Workrooms, through the provisioning sequence

  /// A provider's driver whose hosts also run the ssh fixture's GitHub
  /// (`vcs/scripts/ssh-fixture/fake-github.py`), as a systemd unit so every workroom runs its own:
  /// https for github.com on the machine's loopback, trusted for that host only, behind a token
  /// check. git reaches it through `http.curloptResolve`, not `/etc/hosts`, and answers it with
  /// the fixture's credential helper (`git-credential-fixture`) in place of the provider's own,
  /// which would answer the real GitHub. Every setting is in the user's global config, not the
  /// system's: boxd rewrites `/etc/hosts` and `/etc/gitconfig` at every boot (measured), and
  /// exe.dev's system rewrite to its integration host is undone here.
  struct WithFakeGitHub: HostTerminalDriver {
    let driver: any HostTerminalDriver
    let user: String
    static let cloneToken = "ghs_fixture_clone_token_0123456789"

    var daemonSocket: String { driver.daemonSocket }
    func destroy(_ host: HostID) async throws { try await driver.destroy(host) }
    func openStream(to host: HostID) async throws -> HostStream {
      try await driver.openStream(to: host)
    }
    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      try await driver.exec(command, on: host)
    }
    func attachCommand(
      to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
      metadata: [(key: String, value: String)], runCommand: String?
    ) throws -> String {
      try driver.attachCommand(
        to: host, session: session, workingDirectory: workingDirectory, restored: restored,
        metadata: metadata, runCommand: runCommand)
    }
    func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool {
      driver.hostRefusedLastAttach(of: session, on: host)
    }
    func lastAttach(of session: UUID, on host: HostID) -> LastAttach {
      driver.lastAttach(of: session, on: host)
    }

    func create() async throws -> HostID {
      let host = try await driver.create()
      let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../vcs/scripts/ssh-fixture")
      let program = try String(
        contentsOf: fixture.appendingPathComponent("fake-github.py"), encoding: .utf8)
      let helper = try String(
        contentsOf: fixture.appendingPathComponent("git-credential-fixture"), encoding: .utf8)
      let setup = """
        set -eu
        mkdir -p /etc/workroom-fixture
        cat > /usr/local/bin/fake-github.py <<'PY'
        \(program)
        PY
        cat > /usr/local/bin/git-credential-fixture <<'SH'
        \(helper)
        SH
        chmod 755 /usr/local/bin/git-credential-fixture
        git config --system --unset-all url.https://github.int.exe.xyz/.insteadOf || true
        openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj /CN=github.com \
          -addext subjectAltName=DNS:github.com \
          -keyout /etc/workroom-fixture/github.key -out /etc/workroom-fixture/github.pem 2>/dev/null
        chown \(user):\(user) /etc/workroom-fixture/github.key
        echo \(Self.cloneToken) > /etc/workroom-fixture/clone-token
        sudo -u \(user) -H git config --global \
          http.https://github.com/.sslCAInfo /etc/workroom-fixture/github.pem
        sudo -u \(user) -H git config --global http.curloptResolve github.com:443:127.0.0.1
        sudo -u \(user) -H git config --global credential.https://github.com.helper ""
        sudo -u \(user) -H git config --global --add \
          credential.https://github.com.helper /usr/local/bin/git-credential-fixture
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

  /// The provisioning sequence over `driver`, as the app runs it for a remote provider: Workroom
  /// gives the host no credential.
  func environment(_ driver: any HostDriver) -> RemoteProvisioning.Environment {
    let socket = driver.daemonSocket
    return RemoteProvisioning.Environment(
      driver: driver, daemonSocket: socket,
      connect: { host in
        try await DaemonBootstrap.connect(
          host: host, driver: driver, socket: socket, handOff: false)
      })
  }

  /// AC 1 (through the sequence the app runs, `RemoteProvisioning`), AC 2 and AC 4.
  ///
  /// Two workrooms are made, each on a host of its own, on its own branch. git on a workroom clones
  /// with the host's own credential helper, and with the Mac's link gone it fetches and pushes.
  /// After its machine restarts, a pane comes back to its last screen and git is still answered:
  /// the helper's config is on the home disk.
  @MainActor
  func workroomsPushWithTheMacDisconnectedAndSurviveARestart(_ provider: LiveProvider)
    async throws
  {
    let path = "\(provider.home)/project"
    let driver = WithFakeGitHub(driver: provider.driver, user: provider.user)
    let environment = environment(driver)

    var instances: [RemoteProvisioning.Instance] = []
    for branch in ["wr-one", "wr-two"] {
      let instance = try await RemoteProvisioning.provision(
        cloneURL: "https://github.com/origin.git", path: path, branch: branch, in: environment)
      instances.append(instance)
      XCTAssertFalse(instance.relayed)
      let head = try await RemoteProvisioning.git(
        ["rev-parse", "--abbrev-ref", "HEAD"], in: instance.path, on: instance.connection)
      XCTAssertEqual(head.trimmingCharacters(in: .whitespacesAndNewlines), branch)
    }

    let first = instances[0]
    await first.connection.close()
    let onBox = { (line: String) in try provider.onBox(first.host, "cd \(path) && { \(line); }") }
    let fill = try onBox("printf 'protocol=https\\nhost=github.com\\n\\n' | git credential fill")
    XCTAssertTrue(fill.contains("password=\(WithFakeGitHub.cloneToken)"), fill)

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
    // The restart kills the daemon outright, so only what it has already written survives.
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

    // The restart returns while the machine boots, so the first attaches can find no daemon yet:
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
    XCTAssertTrue(
      refill.contains("password=\(WithFakeGitHub.cloneToken)"), "the helper was lost: \(refill)")

    for instance in instances { try await RemoteProvisioning.destroy(instance, in: environment) }
    XCTAssertEqual(try provider.leftovers(), [])
  }

  /// AC 5, for the steps after the provider's: a workroom whose clone or checkout fails is removed.
  @MainActor
  func aWorkroomThatFailsAfterItsMachineLeavesNothing(_ provider: LiveProvider) async throws {
    let driver = WithFakeGitHub(driver: provider.driver, user: provider.user)

    // The fake GitHub has no such repository; and git refuses the branch name only once the
    // workroom is cloned.
    for (step, cloneURL, branch) in [
      ("clone", "https://github.com/no-such.git", "wr-clone"),
      ("checkout", "https://github.com/origin.git", "bad..name"),
    ] {
      do {
        _ = try await RemoteProvisioning.provision(
          cloneURL: cloneURL, path: "\(provider.home)/project", branch: branch,
          in: environment(driver))
        XCTFail("a workroom that failed at \(step) was made")
      } catch {
        switch (step, error) {
        case ("clone", RemoteProvisioning.Failure.git("clone", _)),
          ("checkout", RemoteProvisioning.Failure.git("switch", _)):
          break
        default: XCTFail("\(step) failed for another reason: \(error)")
        }
      }
      XCTAssertEqual(try provider.leftovers(), [], "a failure at \(step) left a machine")
    }
  }

  // MARK: Run sessions (#522)

  /// A remote run tab's run, on the provider's own host, as the app makes and drives it: a pane
  /// attaches with the run command, the host's daemon runs it under its run supervisor and
  /// publishes its state with the session's program status, and the app's Stop, Restart and Quit
  /// reach it by session id. It outlives a dropped link, and Quit ends its session and whatever
  /// its launcher left running in it.
  @MainActor
  func aRunRunsOnTheHostAndAnswersStopRestartAndQuit(_ provider: LiveProvider) async throws {
    let driver = provider.driver
    let host = try await driver.create()
    // Whatever fails below, the machine goes, so a broken run never leaves one billing. The
    // provider suite's own tearDown sweeps by prefix too, but only if the test gets that far.
    addTeardownBlock { try? await driver.destroy(host) }
    let connection = try await connect(provider, host)
    XCTAssertGreaterThanOrEqual(connection.helloVersion, DaemonHandshake.minRunVersion)
    let runs = RunLines()
    let session = UUID()
    let availability = try await connection.subscribeProgramStatus { event in
      if case .status(_, let reported, _, _, _, let run?) = event, reported == session {
        runs.add(run)
      }
    }
    XCTAssertEqual(availability, .available)
    // A launcher that forks a server into a process group of its own, which ignores the
    // supervisor's Ctrl-C, as a `bin/dev` does. `$((40+2))` keeps the marker out of the echo.
    let command =
      "set -m; (trap '' INT HUP TERM; exec sleep 600) & echo LEAF=$!; echo RUN-$((40+2)); wait"
    let attach = { (restored: Bool) in
      try RemoteHostIntegrationTests.Pane(
        command: driver.attachCommand(
          to: host, session: session, workingDirectory: provider.home, restored: restored,
          metadata: [], runCommand: command))
    }

    let pane = try attach(false)
    defer { pane.dropLink() }
    let seen = pane.read(until: "RUN-42", within: 60)
    let leaves = Self.numbers(after: "LEAF=", in: seen)
    guard leaves.count == 1 else {
      XCTFail("the run command never ran on the host: \(seen)")
      return
    }
    try await until("the run reports running") { runs.last?.hasPrefix("running ") == true }

    // Stop parks it in its session; Restart runs it again there.
    let stop = try await connection.signalSession(session, .stop)
    XCTAssertEqual(stop, .delivered)
    try await until("the run parks on Stop") { runs.last == "stopped 1" }
    let restart = try await connection.signalSession(session, .restart)
    XCTAssertEqual(restart, .delivered)
    try await until("the run starts again on Restart") {
      runs.last?.hasPrefix("running ") == true && runs.all.contains("stopped 1")
    }
    let restarted = pane.read(until: "RUN-42", within: 20)
    let allLeaves = Self.numbers(after: "LEAF=", in: restarted)
    let listed = try await connection.sessions()
    XCTAssertTrue(
      listed.contains { $0.identifier.uuid == session }, "the restart replaced the session")

    // The link drops and comes back: the run carried on.
    pane.dropLink()
    try await Task.sleep(for: .seconds(2))
    XCTAssertEqual(runs.last?.hasPrefix("running "), true, "the run ended with its link")
    let again = try attach(true)
    defer { again.dropLink() }
    let reattached = again.read(until: "RUN-42", within: 30)
    XCTAssertFalse(reattached.contains("has ended"), reattached)

    // Quit ends the run, its session and everything the launcher left in it.
    let quit = try await connection.signalSession(session, .quit)
    XCTAssertEqual(quit, .delivered)
    try await until("the session ends with its run's quit") {
      (try? await connection.sessions())?.contains { $0.identifier.uuid == session } == false
    }
    for leaf in Set(allLeaves + leaves) {
      try await until("the server the run left (\(leaf)) ends with it") {
        (try? provider.onBox(host, "kill -0 \(leaf) 2>/dev/null"))?.hasSuffix("exit=0") == false
      }
    }

    try await driver.destroy(host)
    XCTAssertEqual(try provider.leftovers(), [])
  }

  /// A run's state lines as its host's daemon publishes them, in order.
  final class RunLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
    var last: String? { all.last }
  }

  /// Polls `condition` for up to `seconds`, and fails the test there if it never holds: the steps
  /// after it would only wait out their own timeouts on a paid host.
  func until(
    _ what: String, within seconds: Double = 60, _ condition: () async throws -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw ParityTimeout(what: what)
  }

  struct ParityTimeout: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out: \(what)" }
  }

  /// Every number that follows `label` in `text`, in order.
  static func numbers(after label: String, in text: String) -> [Int] {
    text.components(separatedBy: label).dropFirst().compactMap { Int($0.prefix { $0.isNumber }) }
  }

  // MARK: In the app

  /// A remote workroom made and taken down the way the app does it (`RemoteWorkrooms.create` and
  /// `delete` on the provider's driver key): it clones in the provider user's home, its record
  /// names the provider with its account and its own repository, the project records nothing, and
  /// deleting the workroom leaves no machine.
  @MainActor
  func aRemoteWorkroomIsMadeAndTakenDownAsTheAppDoesIt(_ provider: LiveProvider) async throws {
    let driver = WithFakeGitHub(driver: provider.driver, user: provider.user)
    let environment = environment(driver)
    let key = provider.key
    let records = Records()
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { path, descriptor in
        records.set(nil, descriptor, as: "w")
        records.path = path
        return "w"
      }, record: { name, descriptor in records.set(name, descriptor) },
      forget: { name in records.forget(name) })
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))

    let created = try await RemoteWorkrooms.create(
      repository: repository, cloneURL: "https://github.com/origin.git", key: key,
      driver: driver, environment: environment, recorder: recorder)
    await created.instance.connection.close()
    XCTAssertNil(records.project, "the project recorded a base")
    let workroom = try XCTUnwrap(records.workrooms["w"])
    XCTAssertEqual(records.path, "\(provider.home)/r")
    XCTAssertEqual(workroom.driver, RemoteWorkrooms.driverName(key))
    XCTAssertEqual(workroom.org, key.org)
    XCTAssertEqual(workroom.account, key.account)
    XCTAssertEqual(workroom.repository, "o/r")
    XCTAssertNil(workroom.container)
    XCTAssertNil(workroom.credentials, "a provider's workroom was relayed")
    XCTAssertEqual(RemoteHosts.DriverKey(workroom), key)

    try await RemoteWorkrooms.delete(
      "w", host: workroom, environment: environment, recorder: recorder)
    XCTAssertNil(records.workrooms["w"], "the workroom's entry was kept")
    XCTAssertEqual(try provider.leftovers(), [])
  }

  final class Records: @unchecked Sendable {
    private let lock = NSLock()
    private var base: HostDescriptor?
    private var named: [String: HostDescriptor] = [:]
    private var reserved: String?
    var project: HostDescriptor? { lock.withLock { base } }
    /// Where the workroom's clone is on its host, as its entry was reserved.
    var path: String? {
      get { lock.withLock { reserved } }
      set { lock.withLock { reserved = newValue } }
    }
    var workrooms: [String: HostDescriptor] { lock.withLock { named } }
    func set(_ name: String?, _ descriptor: HostDescriptor, as reserved: String? = nil) {
      lock.withLock {
        if let name = name ?? reserved { named[name] = descriptor } else { base = descriptor }
      }
    }
    func forget(_ name: String) { _ = lock.withLock { named.removeValue(forKey: name) } }
  }
}
