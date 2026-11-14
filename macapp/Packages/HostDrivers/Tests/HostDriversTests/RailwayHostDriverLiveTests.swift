import DaemonConnection
import Foundation
import WorkroomDomain
import WorkroomSystem
import XCTest

@testable import HostDrivers

/// Railway hosts end to end, against the real API and relay (#634): the acceptance checks of ADRs
/// 0074 and 0075, and the Railway half of the spec's live suite. Opt-in and run by hand, never in
/// CI; the runbook is `docs/designs/railway-live-checks.md`. Build the Dev app first
/// (`make app-build`), whose bundled daemons and Ghostty resources the suite uses, then
///
///   WR_RAILWAY_LIVE_TESTS=1 WR_RAILWAY_TOKEN=<account token> WR_RAILWAY_WORKSPACE=<id> \
///     WR_RAILWAY_PUSH_REPO=<owner>/<throwaway repo> \
///     swift test --package-path macapp/Packages/HostDrivers --filter RailwayHostDriverLiveTests
///
/// (or `WR_RAILWAY_SIGN_IN=1` in place of the token, to sign in with the browser as the app does).
///
/// It never touches the user's own config or projects: it makes a project of its own
/// (`workroom-live-<run>`), an environment in it, a fresh ssh key it registers and removes, and a
/// fresh relay pin, all in a temporary folder, and destroys every one of them afterwards, failed
/// run or not. No token is ever printed, put in a command line, or left in the environment of
/// anything it starts.
final class RailwayHostDriverLiveTests: XCTestCase {
  // Value: protects=ADRs 0074 and 0075's live acceptance on Railway; fails_when=the relay writes a
  // banner, takes a key, drops resize or reattach, refuses logins once many were made, or keeps a
  // stale client's login; why_new=only the real relay and API can show these; seam=none
  func testARailwayHostWorksEndToEndAndLeavesNothingBehind() async throws {
    let settings = try LiveSettings.read()
    // A pane's driver that already ended must not take the suite down with SIGPIPE.
    signal(SIGPIPE, SIG_IGN)
    let run = LiveRun(settings: settings)
    addTeardownBlock { await run.cleanUp() }
    try await run.go()
    for failure in await run.failures { XCTFail(failure) }
  }
}

/// What the suite was given, read from the environment, with each token taken out of it at once.
struct LiveSettings: Sendable {
  enum Railway: Sendable {
    case token(String)
    case signIn(clientID: String)
  }

  let railway: Railway
  let workspaceID: String
  let pushRepository: String
  let app: URL
  let logins: Int
  let region: String?

  /// The Dev app the suite's daemons come from: `WR_WORKROOM_APP`, or this checkout's build.
  static let checkoutApp = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("DerivedData/Build/Products/Debug/Workroom Dev.app")

  static let info = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("WorkroomApp/Info.plist")

  static func read() throws -> LiveSettings {
    let environment = ProcessInfo.processInfo.environment
    let token = environment["WR_RAILWAY_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
    // Out of the environment before anything starts, so no child inherits it.
    unsetenv("WR_RAILWAY_TOKEN")
    guard environment["WR_RAILWAY_LIVE_TESTS"] == "1" else {
      throw XCTSkip("set WR_RAILWAY_LIVE_TESTS=1 to run (docs/designs/railway-live-checks.md)")
    }
    let railway: Railway
    if let token {
      railway = .token(token)
    } else if environment["WR_RAILWAY_SIGN_IN"] == "1" {
      guard let clientID = environment["WR_RAILWAY_OAUTH_CLIENT_ID"] ?? infoClientID() else {
        throw XCTSkip("no RailwayOAuthClientID in \(info.path); set WR_RAILWAY_OAUTH_CLIENT_ID")
      }
      railway = .signIn(clientID: clientID)
    } else {
      throw XCTSkip("set WR_RAILWAY_TOKEN, or WR_RAILWAY_SIGN_IN=1, to run")
    }
    guard let workspace = environment["WR_RAILWAY_WORKSPACE"], !workspace.isEmpty else {
      throw XCTSkip("set WR_RAILWAY_WORKSPACE to the id of a Hobby or Pro workspace to run")
    }
    guard let repository = environment["WR_RAILWAY_PUSH_REPO"],
      LivePane.matches("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", in: repository)
    else {
      throw XCTSkip("set WR_RAILWAY_PUSH_REPO to <owner>/<repo>, a repository to push to, to run")
    }
    let app = environment["WR_WORKROOM_APP"].map(URL.init(fileURLWithPath:)) ?? checkoutApp
    guard
      FileManager.default.isExecutableFile(
        atPath: app.appendingPathComponent("Contents/MacOS/workroomd").path)
    else {
      throw XCTSkip("no built Dev app at \(app.path): run `make app-build`, or set WR_WORKROOM_APP")
    }
    return LiveSettings(
      railway: railway, workspaceID: workspace, pushRepository: repository, app: app,
      logins: environment["WR_RAILWAY_LOGINS"].flatMap(Int.init) ?? 300,
      region: environment["WR_RAILWAY_REGION"])
  }

  private static func infoClientID() -> String? {
    guard let data = try? Data(contentsOf: info),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    return (plist["RailwayOAuthClientID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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

/// A token that never changes, for an account token.
private struct FixedToken: RailwayAccessTokenProviding {
  let token: String
  func accessToken() async throws -> String { token }
  func accessTokenRejected(_ token: String) async {}
}

/// One run of the suite: the steps, what each found wrong, and everything it made, so cleanup can
/// take it all away whatever happened.
actor LiveRun {
  let settings: LiveSettings
  let suffix = RailwayPlacementStore.randomSuffix()
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("wr-railway-live-\(UUID().uuidString.prefix(8))")
  private(set) var failures: [String] = []
  /// Values never to appear in anything reported.
  private var secrets: [String] = []

  // What this run made, for cleanup.
  private var api: RailwayAPI?
  private var projectID: String?
  private var environmentID: String?
  private var publicKey: String?
  private var branch: String?
  private var gitHubToken: String?
  private var panes: [LivePane] = []
  private var stopped: [Int32] = []
  private var clients: [DaemonClient] = []

  // The host under test.
  private var driver: RailwayHostDriver?
  private var host: HostID?
  private let session = UUID()

  init(settings: LiveSettings) { self.settings = settings }

  private var projectName: String { "workroom-live-\(suffix)" }

  // MARK: Reporting

  private func log(_ text: String) { print("railway live: \(redacted(text))") }

  private func fail(_ text: String) {
    let text = redacted(text)
    print("railway live: FAILED: \(text)")
    failures.append(text)
  }

  private func check(_ condition: Bool, _ text: @autoclosure () -> String) {
    if !condition { fail(text()) }
  }

  private func redacted(_ text: String) -> String {
    secrets.filter { !$0.isEmpty }.reduce(text) {
      $0.replacingOccurrences(of: $1, with: "<redacted>")
    }
  }

  /// Runs one step, keeping its failure and going on to the next, so one run reports them all.
  private func step(_ name: String, _ body: () async throws -> Void) async {
    log("— \(name)")
    do { try await body() } catch { fail("\(name): \(error.localizedDescription)") }
  }

  // MARK: The run

  func go() async throws {
    log("run \(suffix), files in \(directory.path)")
    let api = try await signIn()
    self.api = api
    try await checkWorkspace(api)
    gitHubToken = try macGitHubToken()
    secrets.append(gitHubToken ?? "")

    // Each is named in the log and kept for cleanup as soon as Railway answers: a run killed part
    // way still says what to remove.
    log("making project \(projectName) in workspace \(settings.workspaceID)")
    let project = try await api.createProject(name: projectName, workspaceID: settings.workspaceID)
    projectID = project
    log("project \(project): delete it by hand if this run is killed")
    let environment = try await api.createEnvironment(name: "live-\(suffix)", projectID: project)
    environmentID = environment

    let token = gitHubToken
    let driver = RailwayHostDriver(
      configuration: .init(
        environmentID: environment, projectID: project, workspaceID: settings.workspaceID,
        keys: directory.appendingPathComponent("keys"),
        keyName: "Workroom live suite \(suffix)", hostSetup: .checkout,
        gitHubToken: token.map { token in { @Sendable in token } }),
      api: api, directory: directory.appendingPathComponent("hosts"))
    self.driver = driver

    await step("lifecycle: create with idle timeout 0") { try await lifecycleCreate(driver, api) }
    guard let host else { return }
    await step("daemon bootstrap") { try await bootstrap(driver, host) }
    await step("attach, resize, no banner, Ctrl+\\ then d") { try await attach(driver, host) }
    await step("reattach with no banner") { try await reattach(driver, host) }
    await step("a lost link retries") { try await lostLink(driver, host) }
    await step("a changed relay key is refused") { try await refusedLink(driver, host) }
    await step("clone and push in the user's name") { try await clonePush(driver, host) }
    await step("stale pane and service stream closed") { try await stale(driver, host, api) }
    await step("\(settings.logins) short logins") { try await manyLogins(driver, host, api) }
    await step("lifecycle: destroy") { try await lifecycleDestroy(driver, host, api) }
  }

  private func signIn() async throws -> RailwayAPI {
    let transport = URLSessionRailwayTransport()
    switch settings.railway {
    case .token(let token):
      secrets.append(token)
      return RailwayAPI(transport: transport, tokens: FixedToken(token: token))
    case .signIn(let clientID):
      let client = RailwayOAuthClient(clientID: clientID, transport: transport)
      log("opening Railway's consent page in the browser: approve the workspace to use")
      let tokens = try await RailwaySignIn(client: client).run { url in
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url.absoluteString]
        try? open.run()
      }
      secrets += [tokens.accessToken, tokens.refreshToken ?? ""]
      let session = RailwaySession(
        client: client, store: MemoryTokenStore(), lock: InProcessRefreshLock())
      try await session.signIn(with: tokens)
      return RailwayAPI(transport: transport, tokens: session)
    }
  }

  private func checkWorkspace(_ api: RailwayAPI) async throws {
    let workspaces = try await api.grantedWorkspaces()
    guard let workspace = workspaces.first(where: { $0.id == settings.workspaceID }) else {
      throw LiveError("workspace \(settings.workspaceID) isn't among the ones this sign-in sees")
    }
    if let refusal = workspace.refusal(
      trialing: try? await api.isTrialing(workspaceID: workspace.id))
    {
      throw LiveError(refusal.reason)
    }
    log("workspace \(workspace.name), plan \(workspace.plan.displayName)")
  }

  /// The Mac's `gh` token, which the host's git uses in the user's name (ADR 0072).
  private func macGitHubToken() throws -> String {
    let result = try Self.run(["gh", "auth", "token", "--hostname", "github.com"])
    let token = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.status == 0, !token.isEmpty else {
      throw LiveError("`gh auth token` gave no token: run `gh auth login`")
    }
    return token
  }

  // MARK: Steps

  private func lifecycleCreate(_ driver: RailwayHostDriver, _ api: RailwayAPI) async throws {
    var options = ResolvedHostOptions()
    options.region = settings.region
    let made = try await driver.create(options: options)
    host = made
    let (_, record) = try driver.record(of: made)
    log("sandbox \(record.sandboxID) in environment \(record.environmentID)")
    let presence = await driver.presence(made)
    check(presence == .awake, "a new host's presence is \(String(describing: presence))")
    let sandbox = try await api.liveSandbox(record.sandboxID, environmentID: record.environmentID)
    check(sandbox?.status == "RUNNING", "a new sandbox is \(sandbox?.status ?? "missing")")
    check(
      sandbox?.idleTimeoutMinutes == 0,
      "the sandbox's idle timeout is \(sandbox?.idleTimeoutMinutes.map(String.init) ?? "null")"
        + ", not 0")
    // The setup's logins went through with only the shipped key trusted: the relay presents it.
    check(
      record.hostKey == RailwayHostDriver.relayHostKey,
      "the host is recorded with \(record.hostKey), not the shipped relay key")
    log("relay key: the one Workroom ships, which the relay presented")
    let mode = try Self.mode(of: driver.configuration.keys.appendingPathComponent("id_ed25519"))
    check(mode == 0o600, "the Mac's Railway key is mode \(String(mode, radix: 8))")
    publicKey = try String(
      contentsOf: driver.configuration.keys.appendingPathComponent("id_ed25519.pub"),
      encoding: .utf8)
  }

  private func bootstrap(_ driver: RailwayHostDriver, _ host: HostID) async throws {
    let settings = settings
    let outcome = try await DaemonBootstrap.ensure(
      host: host, driver: driver, socket: driver.daemonSocket,
      daemon: { @Sendable in settings.linuxDaemon($0) }, resources: settings.ghosttyResources,
      scripts: checkoutScripts(in: "daemon-bootstrap"))
    log("bootstrap: \(outcome)")
    let client = try await connect(driver, host)
    _ = try await client.sessions()
    await client.close()
    // What every connect does (ADR 0072): the token is already there, so it is left alone.
    try await driver.refreshGitHubToken(on: host)
  }

  private func attach(_ driver: RailwayHostDriver, _ host: HostID) async throws {
    let pane = try openPane(driver, host, restored: false)
    // The prompt's form is the image's; what is typed meanwhile waits in the pty anyway.
    _ = await pane.wait(for: "root@", timeout: 30)
    pane.type("echo MARK-$((40+2)) TERM=$TERM TTY=${SSH_TTY:-none}\r")
    check(
      await pane.wait(for: "MARK-42 TERM=xterm-", timeout: 60),
      "the pane ran nothing: \(tail(pane))")
    if settings.ghosttyResources != nil {
      check(pane.screen.contains("TERM=xterm-ghostty"), "TERM isn't xterm-ghostty: \(tail(pane))")
    }
    check(pane.screen.contains("TTY=none"), "SSH_TTY is set: \(tail(pane))")

    // Resize: the client polls the pane's size and sends it as a Resize frame.
    var mark = pane.screen.count
    pane.type("stty size\r")
    check(await pane.wait(for: "\\b30 100\\b", after: mark), "size isn't 30 100: \(tail(pane))")
    pane.resize(rows: 40, columns: 120)
    try await Task.sleep(for: .seconds(1))
    mark = pane.screen.count
    pane.type("stty size\r")
    check(
      await pane.wait(for: "\\b40 120\\b", after: mark, timeout: 5),
      "a resize didn't reach the session: \(tail(pane))")

    // Ctrl+\ then d: the relay takes it on a host terminal; here it must reach the program.
    mark = pane.screen.count
    pane.type("stty raw -echo; od -An -c -N 2; stty sane; echo OD-$((1+1))-DONE\r")
    try await Task.sleep(for: .seconds(2))
    pane.send(bytes: [0x1c, UInt8(ascii: "d")])
    check(
      await pane.wait(for: "034 +d", after: mark, timeout: 15),
      "Ctrl+\\ then d didn't reach the program: \(tail(pane))")
    check(await pane.wait(for: "OD-2-DONE", after: mark), "the pane stopped: \(tail(pane))")
    pane.type("echo ALIVE-$((2+3))\r")
    check(await pane.wait(for: "ALIVE-5", after: mark), "the pane is gone: \(tail(pane))")
    checkNoBanner(pane)
    pane.close()
  }

  private func reattach(_ driver: RailwayHostDriver, _ host: HostID) async throws {
    let pane = try openPane(driver, host, restored: true)
    // The daemon restores the screen: the mark printed before is there without typing it again.
    check(
      await pane.wait(for: "MARK-42", timeout: 30), "the reattach restored nothing: \(tail(pane))")
    let mark = pane.screen.count
    pane.type("echo BACK-$((3+4))\r")
    check(await pane.wait(for: "BACK-7", after: mark), "the reattached pane is dead: \(tail(pane))")
    checkNoBanner(pane)
    pane.close()
  }

  private func lostLink(_ driver: RailwayHostDriver, _ host: HostID) async throws {
    let pane = try openPane(driver, host, restored: true)
    check(await pane.wait(for: "MARK-42"), "the pane didn't attach: \(tail(pane))")
    guard let ssh = sshPID(of: session) else { throw LiveError("no ssh under the pane") }
    Darwin.kill(ssh, SIGKILL)
    let status = await pane.waitForExit(timeout: 30)
    check(status == 255, "a killed link ended the pane with \(String(describing: status))")
    check(
      driver.lastAttach(of: session, on: host) == .lostLink,
      "a killed link reads as \(driver.lastAttach(of: session, on: host))")
    check(!driver.hostRefusedLastAttach(of: session, on: host), "a killed link reads as refused")
    check(
      pane.screen.contains(SSHTransport.retryNotice), "no retry notice: \(tail(pane))")
    pane.close()
  }

  private func refusedLink(_ driver: RailwayHostDriver, _ host: HostID) async throws {
    let (id, record) = try driver.record(of: host)
    let real = driver.target(
      record, identity: driver.configuration.keys.appendingPathComponent("id_ed25519").path)
    // Another real key, as a relay that changed its key, or an interceptor, would present.
    let other = directory.appendingPathComponent("other_host_key")
    _ = try Self.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", other.path])
    let otherKey = RailwayHostDriver.keyBody(
      try String(contentsOf: other.appendingPathExtension("pub"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines))
    let wrong = SSHTransport.Host(
      address: real.address, port: real.port, user: real.user, identityFile: real.identityFile,
      hostKey: otherKey, daemonSocket: real.daemonSocket)
    let command = try SSHTransport.attachCommand(
      to: wrong, in: driver.hostDirectory(id), session: session, workingDirectory: "/root",
      restored: true, client: settings.macDaemon.path)
    let pane = try open(command)
    let status = await pane.waitForExit(timeout: 30)
    check(status == 255, "a refused link ended with \(String(describing: status))")
    check(
      driver.hostRefusedLastAttach(of: session, on: host), "a changed key didn't read as refused")
    check(
      pane.screen.lowercased().contains("host key verification failed"),
      "the pane doesn't say why: \(tail(pane))")
    check(!pane.screen.contains(SSHTransport.retryNotice), "a refusal says it will keep trying")
    pane.close()
    // The real pin back, for the steps after.
    _ = try driver.attachCommand(
      to: host, session: session, workingDirectory: "/root", restored: true, metadata: [],
      runCommand: nil)
  }

  private func clonePush(_ driver: RailwayHostDriver, _ host: HostID) async throws {
    let branch = "workroom-live-\(suffix)"
    self.branch = branch
    let repository = settings.pushRepository
    let (status, said) = try await driver.exec(
      "stat -c %a \(PosixShell.quoted(RailwayHostDriver.gitHubTokenPath)); set -e; d=$(mktemp -d); "
        + "git clone -q git@github.com:\(repository).git \"$d/r\"; cd \"$d/r\"; "
        + "git checkout -q -b \(branch); git -c user.name='Workroom live suite' "
        + "-c user.email=workroom-live@users.noreply.github.com commit -q --allow-empty "
        + "-m 'Workroom live suite: push check'; git push -q origin \(branch); echo PUSHED; "
        + "cd /; rm -rf \"$d\"", on: host
    ).communicate(nil, timeout: 120)
    check(
      LivePane.matches("(^|\n)600\n", in: said),
      "the token file isn't readable by its owner only: \(said)")
    guard status == 0, said.contains("PUSHED") else {
      throw LiveError("clone and push failed (\(status)): \(said)")
    }
    guard let token = gitHubToken else { return }
    let login = try await GitHub.login(token: token)
    var actor: String?
    for _ in 0..<15 where actor == nil {
      actor = try await GitHub.pusher(of: branch, in: repository, token: token)
      if actor == nil { try await Task.sleep(for: .seconds(2)) }
    }
    check(actor == login, "GitHub says \(actor ?? "nobody") pushed \(branch), not \(login)")
    log("pushed \(branch) to \(repository) as \(actor ?? "?")")
  }

  /// ADR 0075: a pane and a service stream whose Mac went away are closed in about a minute, and
  /// their `relay` and Railway durable session end with them; the session survives.
  private func stale(_ driver: RailwayHostDriver, _ host: HostID, _ api: RailwayAPI) async throws {
    let (_, record) = try driver.record(of: host)
    // What runs before this step's two logins: the earlier steps' logins, some of which Railway
    // keeps running after their ssh was killed until the daemon closes them. Only this step's
    // are watched.
    let relaysBefore = Set(try await hostLines(driver, host, Self.relays))
    let railwayBefore = Set(
      try await api.liveSessions(record.sandboxID, environmentID: record.environmentID)
        .filter(\.runState.running).map(\.name))
    let pane = try openPane(driver, host, restored: true)
    check(await pane.wait(for: "MARK-42"), "the pane didn't attach: \(tail(pane))")
    let stream = try await driver.openStream(to: host)
    let service = try await DaemonClient.connect(host: host, stream: stream)
    clients.append(service)
    try await service.announcePinging()
    // Time for both logins to show up in the host's process list and Railway's session list.
    try await Task.sleep(for: .seconds(5))

    let relays = try await hostLines(driver, host, Self.relays).filter {
      !relaysBefore.contains($0)
    }
    check(!relays.isEmpty, "no relay of this step's logins runs on the host before the cut")
    let running = Set(
      try await api.liveSessions(record.sandboxID, environmentID: record.environmentID)
        .filter { $0.runState.running && !railwayBefore.contains($0.name) }.map(\.name))
    log("before the cut: relay processes \(relays), Railway sessions: \(running.count)")
    check(running.count >= 2, "Railway lists \(running.count) running sessions for two logins")

    // The cut: nothing more from the Mac on either login, as with a Mac asleep or offline.
    guard let paneSSH = sshPID(of: session) else { throw LiveError("no ssh under the pane") }
    pane.stopAnswering()
    for pid in [paneSSH, stream.processIdentifier] {
      Darwin.kill(pid, SIGSTOP)
      stopped.append(pid)
    }
    let cut = Date()
    var alive = relays
    while !alive.isEmpty, Date().timeIntervalSince(cut) < 150 {
      try await Task.sleep(for: .seconds(5))
      let probe = relays.map { "kill -0 \($0) 2>/dev/null && echo \($0)" }.joined(separator: "; ")
      alive = try await hostLines(driver, host, probe + "; true")
    }
    let took = Int(Date().timeIntervalSince(cut))
    check(alive.isEmpty, "relays \(alive) still run \(took) s after the cut")
    check(took <= 100, "the stale logins took \(took) s to close, not about a minute")
    log("relays closed \(took) s after the cut")

    var stillRunning = running
    for _ in 0..<6 where !stillRunning.isEmpty {
      let after = try await api.liveSessions(record.sandboxID, environmentID: record.environmentID)
      stillRunning = running.intersection(after.filter(\.runState.running).map(\.name))
      if !stillRunning.isEmpty { try await Task.sleep(for: .seconds(5)) }
    }
    check(stillRunning.isEmpty, "Railway still runs durable sessions \(stillRunning.sorted())")

    let observer = try await connect(driver, host)
    let sessions = try await observer.sessions()
    await observer.close()
    let bytes = withUnsafeBytes(of: session.uuid) { Array($0) }
    let ours = sessions.first { $0.identifier.bytes == bytes }
    check(ours != nil, "the session ended with its stale client")
    check(ours?.isAttached == false, "the session still reads attached")

    releaseStopped()
    pane.close()
    let back = try openPane(driver, host, restored: true)
    check(await back.wait(for: "MARK-42"), "the session didn't reattach: \(tail(back))")
    back.close()
  }

  /// ADR 0074's accepted risk: Railway keeps every login as a session; a few hundred must not stop
  /// it taking new ones.
  private func manyLogins(_ driver: RailwayHostDriver, _ host: HostID, _ api: RailwayAPI)
    async throws
  {
    let (_, record) = try driver.record(of: host)
    let before = try await api.liveSessions(record.sandboxID, environmentID: record.environmentID)
    let total = settings.logins
    let started = Date()
    let tally = LoginTally()
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<4 {
        group.addTask {
          while let index = tally.take(below: total) {
            do {
              let (status, said) = try await driver.exec("true", on: host)
                .communicate(nil, timeout: 60)
              if status != 0 { tally.failed("login \(index): \(status) \(said)") }
            } catch {
              tally.failed("login \(index): \(error.localizedDescription)")
            }
          }
        }
      }
    }
    let failures = tally.failures
    log(
      "\(total) logins in \(Int(Date().timeIntervalSince(started))) s, \(failures.count) failed")
    check(failures.isEmpty, "\(failures.count) logins failed, first: \(failures.prefix(3))")

    let (status, said) = try await driver.exec("echo STILL-OK", on: host)
      .communicate(nil, timeout: 60)
    check(status == 0 && said.contains("STILL-OK"), "a new login was refused: \(status) \(said)")
    let pane = try openPane(driver, host, restored: true)
    check(await pane.wait(for: "MARK-42"), "a new attach was refused: \(tail(pane))")
    pane.close()
    let after = try await api.liveSessions(record.sandboxID, environmentID: record.environmentID)
    log(
      "Railway's session list: \(before.count) before, \(after.count) after"
        + " (\(after.filter(\.runState.running).count) running)")
  }

  private func lifecycleDestroy(_ driver: RailwayHostDriver, _ host: HostID, _ api: RailwayAPI)
    async throws
  {
    let (_, record) = try driver.record(of: host)
    try await driver.destroy(host)
    self.host = nil
    var status = try await api.sandboxStatus(record.sandboxID, environmentID: record.environmentID)
    for _ in 0..<30 where !(status.map(RailwayHostDriver.isGone) ?? true) || status == "DESTROYING"
    {
      try await Task.sleep(for: .seconds(2))
      status = try await api.sandboxStatus(record.sandboxID, environmentID: record.environmentID)
    }
    check(status == nil || status == "DESTROYED", "a destroyed sandbox is \(status ?? "-")")
  }

  // MARK: Panes and the host

  private func openPane(_ driver: RailwayHostDriver, _ host: HostID, restored: Bool) throws
    -> LivePane
  {
    let (id, record) = try driver.record(of: host)
    let target = driver.target(
      record, identity: driver.configuration.keys.appendingPathComponent("id_ed25519").path)
    return try open(
      SSHTransport.attachCommand(
        to: target, in: driver.hostDirectory(id), session: session, workingDirectory: "/root",
        restored: restored, metadata: [("workroom", "live-\(suffix)"), ("title", "live")],
        client: settings.macDaemon.path))
  }

  private func open(_ command: String) throws -> LivePane {
    let home = directory.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let pane = try LivePane(
      command, in: directory.appendingPathComponent("panes"),
      environment: [
        "HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
        "TERM": "xterm-256color", "TMPDIR": directory.path,
      ])
    panes.append(pane)
    return pane
  }

  private func connect(_ driver: RailwayHostDriver, _ host: HostID) async throws -> DaemonClient {
    try await DaemonClient.connect(host: host, stream: try await driver.openStream(to: host))
  }

  /// The host's `relay` processes, and the shells Railway wraps them in (`[w]` keeps the probe's
  /// own shell out).
  static let relays = "pgrep -f '[w]orkroomd relay' || true"

  private func hostLines(_ driver: RailwayHostDriver, _ host: HostID, _ command: String)
    async throws -> [String]
  {
    let (status, said) = try await driver.exec(command, on: host).communicate(nil, timeout: 60)
    guard status == 0 else { throw LiveError("`\(command)` on the host: \(status) \(said)") }
    return said.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  }

  /// The pane's ssh, the attach client's child: every process of the attach has the session's
  /// log path in its arguments, and only ssh is `/usr/bin/ssh`.
  private func sshPID(of session: UUID) -> Int32? {
    let found = try? Self.run(["pgrep", "-n", "-f", "^/usr/bin/ssh .*attach-\(session.uuidString)"])
    return found?.output.split(separator: "\n").first.flatMap { Int32($0) }
  }

  private func releaseStopped() {
    for pid in stopped {
      Darwin.kill(pid, SIGKILL)
      Darwin.kill(pid, SIGCONT)
    }
    stopped = []
  }

  private func checkNoBanner(_ pane: LivePane) {
    for word in ["Railway durable session", "CTRL + \\", "[detached]"] {
      check(!pane.screen.contains(word), "the relay wrote \"\(word)\" into the pane")
    }
  }

  private func tail(_ pane: LivePane) -> String {
    String(String(pane.screen.suffix(600)).debugDescription)
  }

  // MARK: Cleanup

  /// Takes away everything the run made, whatever happened: the panes, the sandboxes in its
  /// environment, its project, its ssh key and its branch. What it couldn't is a failure that
  /// says what is left.
  func cleanUp() async {
    for pane in panes { pane.close() }
    releaseStopped()
    for client in clients { await client.close() }
    var left: [String] = []
    if let api, let environmentID {
      do {
        for sandbox in try await api.sandboxes(environmentID: environmentID)
        where !["DESTROYED", "DESTROYING"].contains(sandbox.status) {
          do {
            try await api.destroySandbox(sandbox.id, environmentID: environmentID)
          } catch {
            left.append("sandbox \(sandbox.id): \(error.localizedDescription)")
          }
        }
        // Gone before the project goes, as the spike removed them.
        for _ in 0..<30 {
          let live = try await api.sandboxes(environmentID: environmentID)
            .filter { $0.status != "DESTROYED" }
          if live.isEmpty { break }
          try await Task.sleep(for: .seconds(2))
        }
      } catch {
        left.append("the sandboxes of environment \(environmentID): \(error.localizedDescription)")
      }
    }
    if let api, let projectID {
      do {
        try await api.deleteProject(projectID)
        log("deleted project \(projectID)")
      } catch {
        left.append("project \(projectName) (\(projectID)): \(error.localizedDescription)")
      }
    }
    // From disk too: a create that failed after registering the key never handed it back.
    let keyFile = directory.appendingPathComponent("keys/id_ed25519.pub")
    if let api, let publicKey = publicKey ?? (try? String(contentsOf: keyFile, encoding: .utf8)) {
      do {
        try await api.deleteSSHPublicKey(matching: publicKey)
      } catch {
        left.append("ssh key \"Workroom live suite \(suffix)\": \(error.localizedDescription)")
      }
    }
    if let branch, let gitHubToken {
      do {
        try await GitHub.deleteBranch(branch, in: settings.pushRepository, token: gitHubToken)
      } catch {
        left.append("branch \(branch) of \(settings.pushRepository): \(error)")
      }
    }
    // A failed run keeps its pane output and attach logs to read, but never its key.
    if failures.isEmpty && left.isEmpty {
      try? FileManager.default.removeItem(at: directory)
    } else {
      for folder in ["keys", "home"] {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(folder))
      }
      log("kept \(directory.path) for its pane output and attach logs")
    }
    // Reported straight to XCTest: the run's own failures were reported already.
    for item in left {
      log("LEFT BEHIND: \(item)")
      XCTFail(redacted("left behind: \(item)"))
    }
    if left.isEmpty { log("cleaned up: nothing left behind") }
  }

  // MARK: Helpers

  /// Runs a tool on this Mac, found on the test's PATH with the usual Homebrew folders added.
  static func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] =
      "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
    process.environment = environment
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  static func mode(of file: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }
}

/// The short logins' shared count and failures.
private final class LoginTally: @unchecked Sendable {
  private let lock = NSLock()
  private var next = 0
  private var _failures: [String] = []

  var failures: [String] { lock.withLock { _failures } }

  /// The next login's index, or nil once `total` were taken.
  func take(below total: Int) -> Int? {
    lock.withLock {
      guard next < total else { return nil }
      defer { next += 1 }
      return next
    }
  }

  func failed(_ text: String) { lock.withLock { _failures.append(text) } }
}

struct LiveError: Error, LocalizedError {
  let errorDescription: String?
  init(_ text: String) { errorDescription = text }
}

// MARK: The API calls only the live suite makes

/// A sandbox's status and idle timeout, as `sandbox` reads them.
struct LiveSandbox: Decodable {
  let status: String
  let idleTimeoutMinutes: Int?
}

/// One of Railway's durable sessions on a sandbox (`sandboxSessions`), one per login.
struct LiveSandboxSession: Decodable {
  struct RunState: Decodable { let running: Bool }
  let name: String
  let kind: String
  let command: String
  let runState: RunState
}

extension RailwayAPI {
  func liveSandbox(_ id: String, environmentID: String) async throws -> LiveSandbox? {
    struct Answer: Decodable { let sandbox: LiveSandbox? }
    return try await query(
      "query sandbox($environmentId: String!, $id: String!) { sandbox(environmentId: "
        + "$environmentId, id: $id) { id status idleTimeoutMinutes } }",
      variables: ["environmentId": .string(environmentID), "id": .string(id)], as: Answer.self
    ).sandbox
  }

  /// Every session Railway lists for the sandbox, page by page. Railway answers null when the
  /// sandbox can't report them, which is a failure here.
  func liveSessions(_ id: String, environmentID: String) async throws -> [LiveSandboxSession] {
    struct Answer: Decodable {
      struct Connection: Decodable {
        struct Edge: Decodable { let node: LiveSandboxSession }
        struct PageInfo: Decodable {
          let hasNextPage: Bool
          let endCursor: String?
        }
        let edges: [Edge]
        let pageInfo: PageInfo
      }
      let sandboxSessions: Connection?
    }
    var all: [LiveSandboxSession] = []
    var after: String?
    repeat {
      var variables: [String: RailwayJSON] = [
        "environmentId": .string(environmentID), "id": .string(id), "first": 100,
      ]
      if let after { variables["after"] = .string(after) }
      guard
        let page = try await query(
          "query sandboxSessions($environmentId: String!, $id: String!, $first: Int, $after: "
            + "String) { sandboxSessions(environmentId: $environmentId, id: $id, first: $first, "
            + "after: $after) { edges { node { name kind command runState { running } } } "
            + "pageInfo { hasNextPage endCursor } } }",
          variables: variables, as: Answer.self
        ).sandboxSessions
      else { throw LiveError("Railway couldn't report the sandbox's sessions (null)") }
      all += page.edges.map(\.node)
      after = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : nil
    } while after != nil
    return all
  }

  func deleteProject(_ id: String) async throws {
    struct Answer: Decodable { let projectDelete: Bool }
    let deleted = try await query(
      "mutation projectDelete($id: String!) { projectDelete(id: $id) }",
      variables: ["id": .string(id)], as: Answer.self
    ).projectDelete
    if !deleted { throw LiveError("Railway answered false") }
  }

  /// Removes the account's key whose body is `publicKey`'s; none is no failure.
  func deleteSSHPublicKey(matching publicKey: String) async throws {
    struct Keys: Decodable {
      struct Connection: Decodable {
        struct Edge: Decodable {
          struct Node: Decodable {
            let id: String
            let publicKey: String
          }
          let node: Node
        }
        let edges: [Edge]
      }
      let sshPublicKeys: Connection
    }
    struct Answer: Decodable { let sshPublicKeyDelete: Bool }
    let body = RailwayHostDriver.keyBody(publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
    let keys = try await query(
      "query sshPublicKeys { sshPublicKeys { edges { node { id publicKey } } } }", as: Keys.self)
    for key in keys.sshPublicKeys.edges.map(\.node)
    where RailwayHostDriver.keyBody(key.publicKey) == body {
      _ = try await query(
        "mutation sshPublicKeyDelete($id: String!) { sshPublicKeyDelete(id: $id) }",
        variables: ["id": .string(key.id)], as: Answer.self)
    }
  }
}

// MARK: GitHub, with the Mac's gh token

/// The few GitHub REST calls the push check makes, from the Mac.
enum GitHub {
  static func request(_ path: String, method: String = "GET", token: String) async throws
    -> (Int, Data)
  {
    var request = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
    request.httpMethod = method
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
  }

  /// The login the token belongs to.
  static func login(token: String) async throws -> String {
    struct User: Decodable { let login: String }
    let (status, data) = try await request("/user", token: token)
    guard status == 200 else { throw LiveError("GitHub's /user answered \(status)") }
    return try JSONDecoder().decode(User.self, from: data).login
  }

  /// Who GitHub says created or pushed `branch`, or nil while it hasn't recorded it.
  static func pusher(of branch: String, in repository: String, token: String) async throws
    -> String?
  {
    struct Activity: Decodable {
      struct Actor: Decodable { let login: String }
      let activityType: String
      let actor: Actor?

      enum CodingKeys: String, CodingKey {
        case actor
        case activityType = "activity_type"
      }
    }
    let (status, data) = try await request(
      "/repos/\(repository)/activity?ref=refs/heads/\(branch)&per_page=10", token: token)
    guard status == 200 else { return nil }
    return try JSONDecoder().decode([Activity].self, from: data)
      .first { ["branch_creation", "push"].contains($0.activityType) }?.actor?.login
  }

  static func deleteBranch(_ branch: String, in repository: String, token: String) async throws {
    let (status, _) = try await request(
      "/repos/\(repository)/git/refs/heads/\(branch)", method: "DELETE", token: token)
    // 422: there is no such branch, as when the push never happened.
    guard [204, 422].contains(status) else { throw LiveError("GitHub answered \(status)") }
  }
}
