import DaemonConnection
import Foundation
import WorkroomDomain
import WorkroomSystem
import XCTest

@testable import HostDrivers

/// ADR 0074's attach path live on an exe.dev VM, a boxd machine and an SSH host (#628): a pane runs
/// the Mac's own `workroomd attach --dial ssh -T … relay`, through each real driver's route, with the
/// Dev app's daemons on the host. Part 2 of `docs/designs/railway-live-checks.md`, which is the
/// runbook. Opt-in and run by hand, never in CI. Build the Dev app first (`make app-build`), then
///
///   WR_SSH_FAMILY_LIVE_TESTS=1 WR_SSH_HOST=<ssh alias> \
///     swift test --package-path macapp/Packages/HostDrivers --filter SSHFamilyHostsLiveTests
///
/// It makes a fresh exe.dev VM and a fresh boxd machine, named `wrlive-<run>-<id>`, and
/// destroys both afterwards, failed run or not. On the SSH host it uses a state directory of its
/// own, `~/.local/state/workroom-live-<run>`, and removes it, its daemon and anything else it
/// added afterwards. It edits nothing of a host's login (`authorized_keys`, sshd): the refused
/// link is a `known_hosts` on this Mac with another host's key. It never reads or writes the
/// user's Workroom config.
final class SSHFamilyHostsLiveTests: XCTestCase {
  // Value: protects=ADR 0074's live acceptance on exe.dev, boxd and SSH hosts; fails_when=the Mac's
  // client doesn't attach, resize, reattach, or report a refused or lost link through a real
  // driver's route, or a session gets the Mac's environment; why_new=only real hosts can show it;
  // seam=none
  func testExeDevBoxdAndSSHHostsAttachThroughTheMacsClient() async throws {
    let settings = try FamilySettings.read()
    // A pane's driver that already ended must not take the suite down with SIGPIPE.
    signal(SIGPIPE, SIG_IGN)
    let run = FamilyRun(settings: settings)
    addTeardownBlock { await run.cleanUp() }
    await run.go()
    for failure in await run.failures { XCTFail(failure) }
  }
}

/// What the suite was given, read from the environment.
struct FamilySettings: Sendable {
  enum Kind: String, CaseIterable, Sendable {
    case exeDev = "exedev"
    case boxd
    case ssh
  }

  let kinds: [Kind]
  let sshDestination: String?
  let boxdCLI: URL
  let app: URL

  static func read() throws -> FamilySettings {
    let environment = ProcessInfo.processInfo.environment
    guard environment["WR_SSH_FAMILY_LIVE_TESTS"] == "1" else {
      throw XCTSkip("set WR_SSH_FAMILY_LIVE_TESTS=1 to run (docs/designs/railway-live-checks.md)")
    }
    let names = (environment["WR_SSH_FAMILY_HOSTS"] ?? "exedev,boxd,ssh")
      .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    var kinds: [Kind] = []
    for name in names where !name.isEmpty {
      guard let kind = Kind(rawValue: name) else {
        throw XCTSkip("WR_SSH_FAMILY_HOSTS names \(name); use exedev, boxd and ssh")
      }
      kinds.append(kind)
    }
    let destination = environment["WR_SSH_HOST"].flatMap { $0.isEmpty ? nil : $0 }
    if kinds.contains(.ssh) {
      guard let destination, (try? SSHHostDriver.validateDestination(destination)) != nil else {
        throw XCTSkip(
          "set WR_SSH_HOST to the ssh alias of a host to use, or leave ssh out of"
            + " WR_SSH_FAMILY_HOSTS")
      }
    }
    let boxd =
      environment["WR_BOXD_CLI"].map(URL.init(fileURLWithPath:))
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/boxd")
    if kinds.contains(.boxd), !FileManager.default.isExecutableFile(atPath: boxd.path) {
      throw XCTSkip("no boxd CLI at \(boxd.path): install it, or set WR_BOXD_CLI")
    }
    let app =
      environment["WR_WORKROOM_APP"].map(URL.init(fileURLWithPath:))
      ?? LiveSettings.checkoutApp
    guard
      FileManager.default.isExecutableFile(
        atPath: app.appendingPathComponent("Contents/MacOS/workroomd").path)
    else {
      throw XCTSkip("no built Dev app at \(app.path): run `make app-build`, or set WR_WORKROOM_APP")
    }
    return FamilySettings(kinds: kinds, sshDestination: destination, boxdCLI: boxd, app: app)
  }

  /// The Mac's own attach client, as a pane runs it.
  var macDaemon: URL { app.appendingPathComponent("Contents/MacOS/workroomd") }

  /// The Linux daemon the bootstrap pushes, for an architecture `uname -m` names.
  func linuxDaemon(_ architecture: String) -> URL? {
    let url = app.appendingPathComponent("Contents/Resources/workroomd-linux-\(architecture)")
    return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
  }

  /// Ghostty's terminfo and shell integration, which the bootstrap puts beside the daemon.
  var ghosttyResources: URL? {
    let url = app.appendingPathComponent("Contents/Resources/ghostty")
    return FileManager.default.fileExists(
      atPath: url.appendingPathComponent("shell-integration").path) ? url : nil
  }
}

/// One host under test, whatever its driver: how a pane reaches it, as the driver's own
/// `attachCommand` does but with this build's Mac client, and how to make that route meet another
/// host's key.
struct FamilyHost: Sendable {
  let label: String
  let driver: any HostTerminalDriver
  let host: HostID
  /// The driver's folder for this host: the attach logs and status files it reads.
  let logs: URL
  let socket: String
  /// The host account's home and shell, as the host's account services give them.
  var home = ""
  var shell = ""
  /// Whether an ssh login on the host has `SSH_CONNECTION`, which a session takes from the login
  /// its relay runs in (ADR 0074). exe.dev's gateway may give a VM's login none.
  var loginHasSSHConnection = true
  let route: @Sendable () throws -> SSHTransport.Route
  /// The same route with `otherKey` (`<type> <base64>`) the only key ssh accepts.
  let refusedRoute: @Sendable (_ otherKey: String) throws -> SSHTransport.Route

  var binary: String { DaemonInstall.binary(besideSocket: socket) }
}

/// One run of the suite: each host's steps, what each found wrong, and everything it made, so
/// cleanup can take it all away whatever happened.
actor FamilyRun {
  let settings: FamilySettings
  let suffix = RailwayPlacementStore.randomSuffix()
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("wr-family-live-\(UUID().uuidString.prefix(8))")
  private(set) var failures: [String] = []

  private var panes: [LivePane] = []
  private var label = ""

  // What this run made, for cleanup.
  private var exeDev: ExeDevHostDriver?
  private var boxd: BoxdHostDriver?
  private var made: [String: FamilyHost] = [:]
  private var sessions: [String: [UUID]] = [:]
  /// The SSH host: its driver, the folders under its home that the run found already there, its
  /// home's listing before the run, and a daemon moved aside by the no-daemon step.
  private var sshDriver: SSHHostDriver?
  private var sshExisting: Set<String> = []
  private var sshHomeBefore: [String] = []
  private var movedDaemon: (host: FamilyHost, from: String, to: String)?

  init(settings: FamilySettings) { self.settings = settings }

  /// What every VM and machine of this run is named after: short, as exe.dev takes 52 characters
  /// and the name is `<prefix>-<uuid>`.
  private var prefix: String { "wrlive-\(suffix)" }
  /// The SSH host's state directory name: the driver's usual `~/.local/state/<name>`, its own.
  private var sshStateName: String { "workroom-live-\(suffix)" }
  /// A folder on this Mac's PATH that no host has: a host session's PATH with it came from the Mac.
  private static let macPathMarker = "/wr-live-mac-path"

  // MARK: Reporting

  private func log(_ text: String) {
    print("family live: \(label.isEmpty ? "" : "[\(label)] ")\(text)")
  }

  private func fail(_ text: String) {
    let text = label.isEmpty ? text : "[\(label)] \(text)"
    print("family live: FAILED: \(text)")
    failures.append(text)
  }

  private func check(_ condition: Bool, _ text: @autoclosure () -> String) {
    if !condition { fail(text()) }
  }

  /// Runs one step, keeping its failure and going on to the next, so one run reports them all.
  private func step(_ name: String, _ body: () async throws -> Void) async -> Bool {
    log("— \(name)")
    let before = failures.count
    do { try await body() } catch { fail("\(name): \(error.localizedDescription)") }
    return failures.count == before
  }

  // MARK: The run

  func go() async {
    log("run \(suffix), files in \(directory.path)")
    log("hosts: \(settings.kinds.map(\.rawValue).joined(separator: ", "))")
    for kind in settings.kinds {
      label = kind == .ssh ? "ssh \(settings.sshDestination ?? "")" : kind.rawValue
      var host: FamilyHost?
      let ready = await step("set up the host") { host = try await setUp(kind) }
      guard ready, var host else {
        label = ""
        continue
      }
      guard await step("daemon bootstrap", { host = try await bootstrap(host) }) else {
        label = ""
        continue
      }
      made[host.label] = host
      let main = UUID()
      sessions[host.label, default: []].append(main)
      _ = await step("A. attach") { try await attach(host, main) }
      _ = await step("B. resize") { try await resize(host, main) }
      _ = await step("C. reattach, and a killed ssh retries") { try await reattach(host, main) }
      _ = await step("D. run command") { try await runCommand(host) }
      _ = await step("E. refused link") { try await refused(host, main) }
      _ = await step("F. lost link: the host's relay killed") { try await lostLink(host, main) }
      _ = await step("G. no daemon yet") { try await noDaemon(host) }
      for pane in panes { pane.close() }
      panes = []
      label = ""
    }
  }

  // MARK: Hosts

  private func setUp(_ kind: FamilySettings.Kind) async throws -> FamilyHost {
    switch kind {
    case .exeDev: return try await setUpExeDev()
    case .boxd: return try await setUpBoxd()
    case .ssh: return try await setUpSSH()
    }
  }

  private func setUpExeDev() async throws -> FamilyHost {
    let directory = directory.appendingPathComponent("hosts-exedev")
    let driver = ExeDevHostDriver(
      configuration: .init(prefix: prefix, hostSetup: .checkout), directory: directory)
    exeDev = driver
    log("making an exe.dev VM \(prefix)-<id>: `ssh exe.dev rm` it by hand if this run is killed")
    let host = try await driver.create()
    guard case .remote(let id) = host else { throw LiveError("exe.dev made \(host)") }
    log("made VM \(driver.name(of: id))")
    let logs = directory.appendingPathComponent(id.uuidString)
    return FamilyHost(
      label: "exedev", driver: driver, host: host, logs: logs, socket: driver.daemonSocket,
      route: { driver.route(id, spawned: false) },
      refusedRoute: { [directory = self.directory] key in
        let base = driver.route(id, spawned: false)
        return SSHTransport.Route(
          options: try Self.otherKnownHosts(key, in: directory) + base.options,
          destination: base.destination, environment: base.environment)
      })
  }

  private func setUpBoxd() async throws -> FamilyHost {
    let directory = directory.appendingPathComponent("hosts-boxd")
    let driver = BoxdHostDriver(
      configuration: .init(cli: settings.boxdCLI, prefix: prefix, hostSetup: .checkout),
      directory: directory)
    boxd = driver
    log("making a boxd machine \(prefix)-<id>: `boxd machine rm` it by hand if this run is killed")
    let host = try await driver.create()
    guard case .remote(let id) = host else { throw LiveError("boxd made \(host)") }
    log("made machine \(driver.name(of: id))")
    let logs = directory.appendingPathComponent(id.uuidString)
    return FamilyHost(
      label: "boxd", driver: driver, host: host, logs: logs, socket: driver.daemonSocket,
      route: { try SSHTransport.route(to: try Self.boxdTarget(driver, id), in: logs) },
      refusedRoute: { key in
        // The driver's own ssh_config, with its known_hosts holding another key in place of the
        // gateway's. The next `route` writes the real one back.
        try SSHTransport.route(to: try Self.boxdTarget(driver, id, hostKey: key), in: logs)
      })
  }

  /// A boxd machine as the driver reaches it (`BoxdHostDriver.ssh`): from the CLI's blocks in the
  /// user's ssh files.
  private static func boxdTarget(_ driver: BoxdHostDriver, _ id: UUID, hostKey: String? = nil)
    throws -> SSHTransport.Host
  {
    let name = driver.name(of: id)
    let config = (try? String(contentsOf: driver.configuration.sshConfig, encoding: .utf8)) ?? ""
    let known = (try? String(contentsOf: driver.configuration.knownHosts, encoding: .utf8)) ?? ""
    guard let details = SSHDetails(machine: name, sshConfig: config, knownHosts: known) else {
      throw LiveError("boxd wrote no ssh details for \(name)")
    }
    return SSHTransport.Host(
      address: details.hostName, port: details.port, user: details.user,
      identityFile: details.identityFile, hostKey: hostKey ?? details.hostKey,
      daemonSocket: driver.daemonSocket)
  }

  private func setUpSSH() async throws -> FamilyHost {
    guard let destination = settings.sshDestination else { throw LiveError("no WR_SSH_HOST") }
    let directory = directory.appendingPathComponent("hosts-ssh")
    let driver = SSHHostDriver(
      configuration: .init(destination: destination, stateDirectoryName: sshStateName),
      directory: directory)
    let info = try await driver.checkHost()
    log("\(info.architecture), home \(info.home), state \(driver.stateDirectory)")
    // What is already there, so cleanup removes only what this run adds.
    let q = PosixShell.quoted
    let found = try await lines(
      driver, driver.hostID,
      [driver.home + "/.local", driver.home + "/.local/state", driver.stateDirectory]
        .map { "test -e \(q($0)) && echo \(q($0))" }.joined(separator: "; ") + "; true")
    guard !found.contains(driver.stateDirectory) else {
      throw LiveError("\(driver.stateDirectory) is already there; this run won't touch it")
    }
    sshExisting = Set(found)
    sshHomeBefore = try await homeListing(driver)
    sshDriver = driver
    let logs = directory.appendingPathComponent(SSHHostDriver.id(for: destination).uuidString)
    return FamilyHost(
      label: "ssh", driver: driver, host: driver.hostID, logs: logs, socket: driver.daemonSocket,
      route: { try driver.route(spawned: false) },
      refusedRoute: { [directory = self.directory] key in
        let base = try driver.route(spawned: false)
        return SSHTransport.Route(
          options: try Self.otherKnownHosts(key, in: directory) + base.options,
          destination: base.destination, environment: base.environment)
      })
  }

  /// ssh options that make `key` the only host key ssh knows, for any host name. Ahead of a
  /// route's own options, which they then override (ssh takes an option's first value).
  private static func otherKnownHosts(_ key: String, in directory: URL) throws -> [String] {
    let file = directory.appendingPathComponent("other_known_hosts")
    try "* \(key)\n".write(to: file, atomically: true, encoding: .utf8)
    return [
      "-o", "UserKnownHostsFile=\(file.path)", "-o", "GlobalKnownHostsFile=/dev/null",
      "-o", "StrictHostKeyChecking=yes",
    ]
  }

  /// The SSH host's home folder, less its own entry (whose time any file made in it changes).
  private func homeListing(_ driver: SSHHostDriver) async throws -> [String] {
    try await lines(
      driver, driver.hostID, "ls -la --time-style=+%s \"$HOME\" | grep -v ' \\.$' | sed 1d")
  }

  private func bootstrap(_ host: FamilyHost) async throws -> FamilyHost {
    let settings = settings
    let outcome = try await DaemonBootstrap.ensure(
      host: host.host, driver: host.driver, socket: host.socket,
      daemon: { @Sendable in settings.linuxDaemon($0) }, resources: settings.ghosttyResources,
      scripts: checkoutScripts(in: "daemon-bootstrap"))
    log("bootstrap: \(outcome)")
    // A supervised daemon starts once its binary is there: give it a moment.
    var connected = false
    for _ in 0..<15 where !connected {
      if let client = try? await connect(host) {
        _ = try await client.sessions()
        await client.close()
        connected = true
      } else {
        try await Task.sleep(for: .seconds(2))
      }
    }
    guard connected else { throw LiveError("no daemon answered after the bootstrap") }
    let account = try await lines(
      host.driver, host.host,
      "getent passwd \"$(id -un)\" | cut -d: -f6,7; echo \"SSH_CONNECTION=${SSH_CONNECTION:+set}\"")
    let fields = account.first?.split(separator: ":").map(String.init) ?? []
    guard fields.count == 2 else { throw LiveError("the host's account entry: \(account)") }
    var host = host
    host.home = fields[0]
    host.shell = fields[1]
    host.loginHasSSHConnection = account.contains("SSH_CONNECTION=set")
    log(
      "account home \(host.home), shell \(host.shell); an ssh login has "
        + (host.loginHasSSHConnection ? "SSH_CONNECTION" : "no SSH_CONNECTION"))
    return host
  }

  // MARK: Steps

  /// A: the waiting line goes, and the session has the host login's environment, not the Mac's.
  private func attach(_ host: FamilyHost, _ session: UUID) async throws {
    let pane = try openPane(host, session, restored: false)
    pane.type(" unset HISTFILE; echo MARK-$((40+2))\r")
    guard await pane.wait(for: "MARK-42", timeout: 60) else {
      throw LiveError("the pane ran nothing: \(tail(pane))")
    }
    let screen = pane.screen
    if let waiting = screen.range(of: "workroom: waiting for this terminal's host...") {
      let after = screen[waiting.upperBound...]
      check(
        after.contains("\u{1B}8\u{1B}[J"),
        "the waiting line was never erased (no DECRC ED after it): \(tail(pane))")
    } else {
      fail("the pane never said it was waiting: \(tail(pane))")
    }

    let mark = pane.screen.count
    pane.type(
      "echo \"P1 TTY=$(tty) TERM=$TERM CONN=${SSH_CONNECTION:+set} SSHTTY=${SSH_TTY:-none}\"; "
        + "echo \"P2 HOME=$HOME SHELL=$SHELL\"; echo \"P3 PATH=$PATH\"; "
        + "env | grep '^WORKROOM_SESSION_' | sort | sed 's/^/P4 /'; echo PROBE-$((1+1))-END\r")
    guard await pane.wait(for: "PROBE-2-END", after: mark, timeout: 30) else {
      throw LiveError("the probe didn't finish: \(tail(pane))")
    }
    let said = String(pane.screen.dropFirst(mark))
    let term = settings.ghosttyResources != nil ? "xterm-ghostty" : "xterm-256color"
    let connection = host.loginHasSSHConnection ? "set" : ""
    check(
      LivePane.matches(
        "P1 TTY=/dev/pts/[0-9]+ TERM=\(term) CONN=\(connection) SSHTTY=none", in: said),
      "want a daemon pty, TERM \(term), SSH_CONNECTION "
        + (host.loginHasSSHConnection ? "set, as the login's is," : "unset, as the login's is,")
        + " and SSH_TTY unset: \(tail(pane))")
    check(
      said.contains("P2 HOME=\(host.home) SHELL=\(host.shell)"),
      "HOME and SHELL aren't the host account's (\(host.home), \(host.shell)): \(tail(pane))")
    let path = said.range(of: "P3 PATH=/[^\r\n]*", options: .regularExpression).map {
      String(said[$0].dropFirst("P3 PATH=".count))
    }
    check(path != nil, "the session has no PATH: \(tail(pane))")
    check(
      path.map { !$0.contains(Self.macPathMarker) } ?? true,
      "the session has the Mac's PATH: \(path ?? "")")
    // The tab's metadata is the session's, kept by the daemon; the shell never sees it, and the
    // Mac's project path never crosses (#255, ADR 0074).
    check(!said.contains("P4 WORKROOM_SESSION_"), "the shell has session metadata: \(tail(pane))")
    let client = try await connect(host)
    let listed = try await client.sessions()
    await client.close()
    let bytes = withUnsafeBytes(of: session.uuid) { Array($0) }
    let metadata = Dictionary(
      (listed.first { $0.identifier.bytes == bytes }?.metadata ?? []).map { ($0.key, $0.value) },
      uniquingKeysWith: { first, _ in first })
    check(
      metadata["workroom"] == "live-\(suffix)" && metadata["title"] == "live-\(host.label)",
      "the daemon didn't keep the tab's workroom and title: \(metadata)")
    check(metadata["project"] == nil, "the Mac's project path reached the host: \(metadata)")
    log("session PATH: \(path ?? "-")")

    // On the host: this pane's relay, and no attach process.
    var processes = try await hostProcesses(host)
    for _ in 0..<10 where processes.relays.count != 1 {
      try await Task.sleep(for: .seconds(1))
      processes = try await hostProcesses(host)
    }
    check(
      processes.relays.count == 1,
      "want one `workroomd relay` for one pane on the host, found \(processes.relays)")
    check(
      processes.attaches.isEmpty, "a `workroomd attach` runs on the host: \(processes.attaches)")
    log("on the host: \(processes.relays.count) relay, \(processes.attaches.count) attach")
    pane.close()
  }

  /// B: `stty size` follows the pane's pty.
  private func resize(_ host: FamilyHost, _ session: UUID) async throws {
    let pane = try openPane(host, session, restored: true)
    guard await pane.wait(for: "MARK-42", timeout: 30) else {
      throw LiveError("the pane didn't attach: \(tail(pane))")
    }
    for (rows, columns) in [(30, 100), (40, 120), (24, 80)] {
      if rows != 30 { pane.resize(rows: rows, columns: columns) }
      try await Task.sleep(for: .seconds(1))
      let mark = pane.screen.count
      pane.type("stty size\r")
      check(
        await pane.wait(for: "\\b\(rows) \(columns)\\b", after: mark, timeout: 10),
        "the session's size isn't \(rows) \(columns): \(tail(pane))")
    }
    pane.close()
  }

  /// C: a reattach restores the screen; a killed ssh is a lost link the pane says it retries.
  private func reattach(_ host: FamilyHost, _ session: UUID) async throws {
    let pane = try openPane(host, session, restored: true)
    check(
      await pane.wait(for: "MARK-42", timeout: 30), "the reattach restored nothing: \(tail(pane))")
    var mark = pane.screen.count
    pane.type("echo BACK-$((3+4))\r")
    check(
      await pane.wait(for: "BACK-7", after: mark), "the reattached pane is dead: \(tail(pane))")
    guard let ssh = sshPID(of: session) else { throw LiveError("no ssh under the pane") }
    mark = pane.screen.count
    Darwin.kill(ssh, SIGKILL)
    let status = await pane.waitForExit(timeout: 30)
    check(status == 255, "a killed ssh ended the pane with \(String(describing: status))")
    checkLostLink(host, session, pane, after: mark)
    pane.close()
  }

  /// D: a run session runs its command on the host under the run supervisor, which restarts and
  /// quits it.
  private func runCommand(_ host: FamilyHost) async throws {
    let session = UUID()
    sessions[host.label, default: []].append(session)
    let pane = try openPane(
      host, session, restored: false, runCommand: "echo RUN-OUT-$((6*7)); sleep 600")
    guard await pane.wait(for: "RUN-OUT-42", timeout: 60) else {
      throw LiveError("the run command didn't run: \(tail(pane))")
    }
    let client = try await connect(host)
    let restart = try await client.signalSession(session, .restart)
    check(restart == .delivered, "restart: \(restart)")
    let deadline = Date().addingTimeInterval(30)
    while pane.screen.components(separatedBy: "RUN-OUT-42").count < 3, Date() < deadline {
      try await Task.sleep(for: .milliseconds(300))
    }
    check(
      pane.screen.components(separatedBy: "RUN-OUT-42").count >= 3,
      "the restart didn't run the command again: \(tail(pane))")
    let quit = try await client.signalSession(session, .quit)
    check(quit == .delivered, "quit: \(quit)")
    await client.close()
    let status = await pane.waitForExit(timeout: 30)
    check(status != nil, "the run session didn't end on quit: \(tail(pane))")
    log("run pane ended with \(status.map(String.init) ?? "-")")
    pane.close()
  }

  /// E: a host key that isn't the host's is refused: ssh's reason on the screen, refused, and no
  /// retry notice.
  private func refused(_ host: FamilyHost, _ session: UUID) async throws {
    let other = directory.appendingPathComponent("other_host_key")
    if !FileManager.default.fileExists(atPath: other.path) {
      _ = try LiveRun.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", other.path])
    }
    let key = RailwayHostDriver.keyBody(
      try String(contentsOf: other.appendingPathExtension("pub"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines))
    let pane = try open(
      host,
      SSHTransport.attachCommand(
        via: try host.refusedRoute(key), in: host.logs, daemonSocket: host.socket,
        session: session, workingDirectory: host.home, restored: true,
        client: settings.macDaemon.path))
    let status = await pane.waitForExit(timeout: 30)
    check(status == 255, "a refused link ended with \(String(describing: status))")
    check(
      host.driver.hostRefusedLastAttach(of: session, on: host.host),
      "another host's key didn't read as refused")
    check(
      pane.screen.lowercased().contains("host key verification failed"),
      "the pane doesn't say why: \(tail(pane))")
    check(
      !pane.screen.contains(SSHTransport.retryNotice), "a refusal says it will keep trying")
    pane.close()
    // The real route again, with the host's own key.
    let back = try openPane(host, session, restored: true)
    check(await back.wait(for: "MARK-42", timeout: 30), "no attach after: \(tail(back))")
    back.close()
  }

  /// F: the host's relay for the pane killed: the pane says it retries, and the next attach
  /// restores the session.
  private func lostLink(_ host: FamilyHost, _ session: UUID) async throws {
    let pane = try openPane(host, session, restored: true)
    guard await pane.wait(for: "MARK-42", timeout: 30) else {
      throw LiveError("the pane didn't attach: \(tail(pane))")
    }
    var relays = try await hostProcesses(host).relays
    for _ in 0..<10 where relays.isEmpty {
      try await Task.sleep(for: .seconds(1))
      relays = try await hostProcesses(host).relays
    }
    guard !relays.isEmpty else { throw LiveError("no relay on the host to kill") }
    let mark = pane.screen.count
    log("killing relay \(relays) on the host")
    _ = try await lines(
      host.driver, host.host, "kill \(relays.map(String.init).joined(separator: " ")); true")
    let status = await pane.waitForExit(timeout: 60)
    check(status == 255, "a killed relay ended the pane with \(String(describing: status))")
    checkLostLink(host, session, pane, after: mark)
    pane.close()
    let back = try openPane(host, session, restored: true)
    check(await back.wait(for: "MARK-42", timeout: 30), "no reattach: \(tail(back))")
    let again = back.screen.count
    back.type("echo AGAIN-$((4+5))\r")
    check(await back.wait(for: "AGAIN-9", after: again), "the reattach is dead: \(tail(back))")
    back.close()
  }

  /// G: a host with no daemon binary says so and retries; once the binary is back, it attaches.
  private func noDaemon(_ host: FamilyHost) async throws {
    let session = UUID()
    sessions[host.label, default: []].append(session)
    let aside = host.binary + ".live-\(suffix)"
    let q = PosixShell.quoted
    _ = try await lines(host.driver, host.host, "mv -- \(q(host.binary)) \(q(aside))")
    movedDaemon = (host, host.binary, aside)
    let pane = try openPane(host, session, restored: false)
    let status = await pane.waitForExit(timeout: 60)
    check(status == 255, "no daemon ended the pane with \(String(describing: status))")
    check(
      pane.screen.contains("workroom: no daemon is installed at \(host.binary) yet"),
      "the pane doesn't say there's no daemon: \(tail(pane))")
    checkLostLink(host, session, pane, after: 0)
    pane.close()
    try await restoreDaemon()
    let outcome = try await DaemonBootstrap.ensure(
      host: host.host, driver: host.driver, socket: host.socket,
      daemon: { @Sendable [settings] in settings.linuxDaemon($0) },
      resources: settings.ghosttyResources, scripts: checkoutScripts(in: "daemon-bootstrap"))
    log("bootstrap after the restore: \(outcome)")
    let back = try openPane(host, session, restored: false)
    back.type(" unset HISTFILE; echo G-OK-$((2*4))\r")
    check(await back.wait(for: "G-OK-8", timeout: 60), "no attach once restored: \(tail(back))")
    back.close()
  }

  private func restoreDaemon() async throws {
    guard let (host, from, to) = movedDaemon else { return }
    let q = PosixShell.quoted
    _ = try await lines(host.driver, host.host, "mv -- \(q(to)) \(q(from))")
    movedDaemon = nil
  }

  private func checkLostLink(_ host: FamilyHost, _ session: UUID, _ pane: LivePane, after: Int) {
    let last = host.driver.lastAttach(of: session, on: host.host)
    check(last == .lostLink, "the attach reads as \(last), not a lost link")
    check(
      !host.driver.hostRefusedLastAttach(of: session, on: host.host), "a lost link reads as refused"
    )
    check(
      String(pane.screen.dropFirst(after)).contains(SSHTransport.retryNotice),
      "no retry notice: \(tail(pane))")
  }

  // MARK: Panes and the host

  private func openPane(
    _ host: FamilyHost, _ session: UUID, restored: Bool, runCommand: String? = nil
  ) throws -> LivePane {
    try open(
      host,
      SSHTransport.attachCommand(
        via: try host.route(), in: host.logs, daemonSocket: host.socket, session: session,
        workingDirectory: host.home, restored: restored,
        metadata: [
          ("project", "/Users/wr-live-mac/project"), ("workroom", "live-\(suffix)"),
          ("title", "live-\(host.label)"),
        ],
        runCommand: runCommand, client: settings.macDaemon.path))
  }

  private func open(_ host: FamilyHost, _ command: String) throws -> LivePane {
    try FileManager.default.createDirectory(at: host.logs, withIntermediateDirectories: true)
    let home = directory.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let pane = try LivePane(
      command, in: directory.appendingPathComponent("panes"),
      environment: [
        "HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:\(Self.macPathMarker)",
        "LANG": "en_US.UTF-8", "TERM": "xterm-256color", "TMPDIR": directory.path,
        "SHELL": "/bin/zsh",
      ])
    panes.append(pane)
    return pane
  }

  private func connect(_ host: FamilyHost) async throws -> DaemonClient {
    try await DaemonClient.connect(
      host: host.host, stream: try await host.driver.openStream(to: host.host))
  }

  /// The host's `relay` and `attach` processes of this run's daemon, by their exact program and
  /// socket: other daemons on a shared host are none of the suite's.
  private func hostProcesses(_ host: FamilyHost) async throws
    -> (relays: [Int32], attaches: [Int32])
  {
    let all = try await lines(host.driver, host.host, "ps -eo pid=,args=")
    var relays: [Int32] = []
    var attaches: [Int32] = []
    for line in all {
      let parts = line.trimmingCharacters(in: .whitespaces).split(
        separator: " ", maxSplits: 1)
      guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
      let args = String(parts[1])
      if args == "\(host.binary) relay --socket \(host.socket)" { relays.append(pid) }
      if args.hasPrefix("\(host.binary) attach") { attaches.append(pid) }
    }
    return (relays, attaches)
  }

  private func lines(_ driver: any HostDriver, _ host: HostID, _ command: String)
    async throws -> [String]
  {
    let (status, said) = try await driver.exec(command, on: host).communicate(nil, timeout: 60)
    guard status == 0 else { throw LiveError("`\(command)` on the host: \(status) \(said)") }
    return said.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  }

  /// The pane's ssh, the attach client's child: every process of the attach has the session's
  /// log path in its arguments, and only ssh is `/usr/bin/ssh`.
  private func sshPID(of session: UUID) -> Int32? {
    let found = try? LiveRun.run([
      "pgrep", "-n", "-f", "^/usr/bin/ssh .*attach-\(session.uuidString)",
    ])
    return found?.output.split(separator: "\n").first.flatMap { Int32($0) }
  }

  private func tail(_ pane: LivePane) -> String {
    String(String(pane.screen.suffix(600)).debugDescription)
  }

  // MARK: Cleanup

  /// Takes away everything the run made, whatever happened: the panes, the sessions, the exe.dev
  /// VM and boxd machine (every one named after the run, so one a create left half made goes
  /// too), and on the SSH host the daemon, its state directory and the folders made for it.
  /// What it couldn't is a failure that says what is left.
  func cleanUp() async {
    label = ""
    for pane in panes { pane.close() }
    panes = []
    var left: [String] = []
    for (name, host) in made {
      guard let client = try? await connect(host) else { continue }
      for session in sessions[name] ?? [] { _ = try? await client.endSession(session) }
      await client.close()
    }
    do { try await restoreDaemon() } catch { left.append("the moved daemon: \(error)") }

    if let driver = exeDev {
      left += await removeMachines(
        "exe.dev VM", list: { [prefix] in try Self.exeDevNames(prefix) },
        destroy: { try await driver.destroy($0) })
    }
    if let driver = boxd {
      left += await removeMachines(
        "boxd machine", list: { [prefix] in try Self.boxdNames(driver.configuration.cli, prefix) },
        destroy: { try await driver.destroy($0) })
      let config = (try? String(contentsOf: driver.configuration.sshConfig, encoding: .utf8)) ?? ""
      if config.contains(prefix) { left.append("boxd's stanza for \(prefix) in ~/.ssh/config") }
    }
    if let driver = sshDriver { left += await cleanSSHHost(driver) }

    if failures.isEmpty && left.isEmpty {
      try? FileManager.default.removeItem(at: directory)
    } else {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent("home"))
      print("family live: kept \(directory.path) for its pane output and attach logs")
    }
    for item in left {
      print("family live: LEFT BEHIND: \(item)")
      XCTFail("left behind: \(item)")
    }
    if left.isEmpty { print("family live: cleaned up: nothing left behind") }
  }

  /// Destroys every machine named after this run, then checks the provider lists none.
  private func removeMachines(
    _ kind: String, list: @Sendable () throws -> [String],
    destroy: (HostID) async throws -> Void
  ) async -> [String] {
    var left: [String] = []
    do {
      for name in try list() {
        guard let id = UUID(uuidString: String(name.dropFirst(prefix.count + 1))) else { continue }
        do {
          try await destroy(.remote(id))
          print("family live: destroyed \(kind) \(name)")
        } catch {
          left.append("\(kind) \(name): \(error.localizedDescription)")
        }
      }
      let still = try list()
      if still.isEmpty {
        print("family live: no \(kind) named \(prefix)-* is left")
      } else {
        left.append("\(kind)s \(still)")
      }
    } catch {
      left.append("listing \(kind)s: \(error.localizedDescription)")
    }
    return left
  }

  /// The run's VMs, as `ssh exe.dev ls` lists them.
  private static func exeDevNames(_ prefix: String) throws -> [String] {
    try names(
      prefix,
      in: ["/usr/bin/ssh"] + ExeDevHostDriver.sshOptions + [ExeDevHostDriver.lobby, "ls", "--json"])
  }

  /// The run's machines, as `boxd machine list` lists them.
  private static func boxdNames(_ cli: URL, _ prefix: String) throws -> [String] {
    try names(prefix, in: [cli.path, "machine", "list", "--json"])
  }

  /// Every `<prefix>-<uuid>` that `command` prints, once each.
  private static func names(_ prefix: String, in command: [String]) throws -> [String] {
    let result = try LiveRun.run(command)
    guard result.status == 0 else {
      throw LiveError("`\(command.first ?? "")` exited \(result.status): \(result.output)")
    }
    let pattern = try NSRegularExpression(
      pattern: NSRegularExpression.escapedPattern(for: prefix) + "-[0-9a-f-]{36}")
    let text = result.output as NSString
    let found = pattern.matches(in: result.output, range: NSRange(location: 0, length: text.length))
      .map { text.substring(with: $0.range) }
    return Array(Set(found)).sorted()
  }

  /// The SSH host as the run found it: its sessions ended, its daemon stopped, its state directory
  /// and the folders made for it gone, and its home's listing as before.
  private func cleanSSHHost(_ driver: SSHHostDriver) async -> [String] {
    var left: [String] = []
    let state = driver.stateDirectory
    let q = PosixShell.quoted
    do {
      let pids = try await ownProcesses(driver)
      if !pids.isEmpty {
        let list = pids.map(String.init).joined(separator: " ")
        _ = try await lines(
          driver, driver.hostID,
          "kill \(list) 2>/dev/null; sleep 2; kill -9 \(list) 2>/dev/null; true")
      }
      var remove = "rm -rf -- \(q(state))"
      for folder in [driver.home + "/.local/state", driver.home + "/.local"]
      where !sshExisting.contains(folder) {
        remove += "; rmdir -- \(q(folder)) 2>/dev/null"
      }
      _ = try await lines(driver, driver.hostID, remove + "; true")
      let still = try await ownProcesses(driver)
      if !still.isEmpty { left.append("processes of \(state) on the SSH host: \(still)") }
      let there = try await lines(
        driver, driver.hostID, "test -e \(q(state)) && echo there; true")
      if !there.isEmpty { left.append("\(state) on the SSH host") }
      let after = try await homeListing(driver)
      if after != sshHomeBefore {
        left.append(
          "the SSH host's home changed: before \(Set(sshHomeBefore).subtracting(after).sorted()),"
            + " after \(Set(after).subtracting(sshHomeBefore).sorted())")
      } else {
        print("family live: the SSH host's home is as it was")
      }
    } catch {
      left.append("cleaning the SSH host: \(error.localizedDescription)")
    }
    await driver.invalidateConnection()
    return left
  }

  /// This run's processes on the SSH host: those whose program is in its state directory.
  private func ownProcesses(_ driver: SSHHostDriver) async throws -> [Int32] {
    let state = driver.stateDirectory + "/"
    return try await lines(driver, driver.hostID, "ps -eo pid=,args=").compactMap { line in
      let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
      guard parts.count == 2, parts[1].hasPrefix(state) else { return nil }
      return Int32(parts[0])
    }
  }
}
