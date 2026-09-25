import Foundation
import WorkroomSessionProtocol
import os

enum PersistentSessionLookup {
  case live(SessionDescriptor)
  case missing
  case unreachable
}

@MainActor
final class PersistentSessionService {
  static let shared = PersistentSessionService()

  private let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "PersistentSession")

  /// One socket path per backend. They deliberately differ, so these must never be conflated —
  /// the daemon's sessions and the agent's are reached through different files.
  private var resolvedSocketPaths: [SessionBackend: String] = [:]
  /// Where new sessions go, once resolved. Cached because resolving it RUNS the agent to check it
  /// works, and that answer does not change within a launch.
  ///
  /// **Nil has two meanings here and `lastProbeAt` is what separates them.** `preferred()` returns
  /// an Optional, so nil is a legitimate answer ("no backend can take a new session"), not merely
  /// "not asked yet". Using nil for both — as this did while `preferred()` was non-Optional —
  /// silently un-caches exactly the case that most needs caching: the probe is a `Process()` with a
  /// 2-second deadline run SYNCHRONOUSLY ON THE MAIN ACTOR during terminal creation
  /// (`SessionBackendProbe.runProtocolCommand`), so a hung agent costs 2s per access, and `backend`
  /// is read once or more per pane. An eight-pane restore would freeze for ~16s.
  private var cachedPreferred: SessionBackend?
  /// When the last probe ran, or nil if it never has. A SUCCESSFUL answer is cached for the launch
  /// — the agent does not become unavailable once it has answered — but a nil answer is retried
  /// after `probeRetryInterval`.
  ///
  /// Latching nil forever was worse than what it replaced. Before this change a failed probe cached
  /// `.swiftDaemon`, and the daemon could still be STARTED, so a transient failure degraded to
  /// daemon-backed persistence; now it degrades to no persistence at all, for the rest of the
  /// launch, with no way back short of quitting. The probe is a `Process()` with a 2-second
  /// watchdog, so load, resource exhaustion or a slow first exec of a freshly-updated binary are
  /// all enough to trip it once. Re-probing on a cooldown keeps the fix for the real problem — the
  /// per-access re-probe that froze the main actor for ~2s a time — while leaving a way out.
  private var lastProbeAt: Double?
  /// One background re-probe at a time; a burst of panes must not spawn one each.
  private var isReprobing = false
  /// When a helper last failed to ANSWER, per backend.
  ///
  /// `ownership` has its own 2-second deadline and, unlike the agent probe, it is asked once per
  /// SESSION with no shared answer — so a helper that accepts and then stalls cost N x 2s for N
  /// panes, serially, on the main actor. That is the same arithmetic the probe cooldown exists to
  /// stop, applied to the query the probe cooldown does not cover. A helper that could not answer
  /// a moment ago is not worth asking again for every remaining pane in the window.
  private var lastUnreachableAt: [SessionBackend: Double] = [:]
  /// Long enough that a burst of pane creation pays one probe, short enough that a user who waits
  /// a moment and opens another terminal gets another chance.
  static let probeRetryInterval: Double = 30
  /// Which helper owns each session, resolved once. See `backend(forSession:)` for why one answer
  /// per session rather than one per call — a pane asks twice and the two must agree.
  private var owners: [UUID: SessionBackend] = [:]
  /// Sessions on a remote host, and the driver that reaches it (#229). Checked before any local
  /// owner: a remote session's owner is known by construction, and no local socket can answer for
  /// it. Registered by whoever makes a pane for a remote workroom; nothing persists it yet, so a
  /// relaunch re-registers it (Phase 4).
  private var remoteSessions: [UUID: RemoteSession] = [:]

  private struct RemoteSession {
    let host: HostID
    let driver: any HostTerminalDriver
    let workingDirectory: String
  }

  /// How the agent's health is measured. Injected so a test can drive the unhealthy path without
  /// a real `wr-agent` to break.
  private let probe: (SessionBackend) -> SessionBackendAvailability
  /// What the shipped daemon says about a session, or nil to ask a real one over its socket.
  /// Injected for the same reason, and separately: the two answers combine, and the case that
  /// matters most (unhealthy agent, daemon-owned session) needs both driven at once.
  private let ownershipOverride: ((UUID) -> SessionOwnership)?
  /// Monotonic seconds, for the probe cooldown. `systemUptime` rather than `Date()` so a clock
  /// adjustment cannot make the cooldown never expire.
  private let now: () -> Double

  private init() {
    self.probe = { SessionBackendProbe.probe($0) }
    self.ownershipOverride = nil
    self.now = { ProcessInfo.processInfo.systemUptime }
  }

  /// Test seam. `shared` never uses it; every other behaviour is identical.
  init(
    probe: @escaping (SessionBackend) -> SessionBackendAvailability,
    ownership: @escaping (UUID) -> SessionOwnership,
    now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
  ) {
    self.probe = probe
    self.ownershipOverride = ownership
    self.now = now
  }

  /// Where a NEW session would be created, or **nil when nowhere can take one**. Existing sessions
  /// are resolved individually — see `backend(forSession:)`.
  /// **The first probe is synchronous; every retry is not.** That split is the whole design.
  ///
  /// The probe is a `Process()` with a 2-second watchdog, and this runs on the main actor during
  /// terminal creation. Making the FIRST one async would cost the common case its persistence —
  /// the healthy agent answers in milliseconds, and a pane that opened before the answer arrived
  /// would be a plain shell for no reason. Making the RETRIES synchronous costs a broken agent a
  /// >=2s frozen main actor once per cooldown window, for the life of the launch, which is Sentry's
  /// AppHang threshold in a repo that has spent this month fixing AppHangs.
  ///
  /// So: answer nil immediately and re-probe in the background. The worst case degrades from "the
  /// app freezes every 30 seconds" to "this pane has no persistence, the next one does".
  var backend: SessionBackend? {
    if let cachedPreferred { return cachedPreferred }
    let currentTime = now()
    guard let lastProbeAt else {
      self.lastProbeAt = currentTime
      cachedPreferred = SessionBackend.preferred(probe: probe)
      return cachedPreferred
    }
    guard currentTime - lastProbeAt >= Self.probeRetryInterval else { return nil }
    self.lastProbeAt = currentTime
    reprobeInBackground()
    return nil
  }

  /// Re-probe off the main actor and publish the answer back onto it.
  ///
  /// `probe` is called on a detached task, so a hung agent burns its 2 seconds somewhere nobody is
  /// waiting. Only a SUCCESS is written back: a second nil would just re-arm the same cooldown that
  /// `backend` already set before starting this.
  private func reprobeInBackground() {
    guard !isReprobing else { return }
    isReprobing = true
    let probe = self.probe
    Task.detached(priority: .utility) {
      let resolved = SessionBackend.preferred(probe: probe)
      await MainActor.run { [weak self] in
        guard let self else { return }
        self.isReprobing = false
        if let resolved { self.cachedPreferred = resolved }
      }
    }
  }

  /// Which helper owns an EXISTING session, or where a new one should go.
  ///
  /// This is the whole migration. A session the Swift daemon is already holding stays with the
  /// daemon — it owns that pty and cannot hand it over — so it keeps running until the user closes
  /// it. Everything new goes to the agent. Nobody has to choose, and nothing is taken away
  /// mid-use.
  ///
  /// **Resolved once per session and remembered.** It used to re-probe on every call, and one pane
  /// asks twice — `attachCommand` for the binary, `launchEnvironment` for the socket. A daemon that
  /// answered the first inside its 2-second deadline and missed the second handed libghostty
  /// `workroom-session attach` pointed at `agent.sock`: the Swift daemon then binds the agent's
  /// socket, which `SessionBackend` says cannot happen by construction, and every agent session
  /// becomes unlistable. One answer per session is what makes the pair consistent.
  ///
  /// Returns **nil when the owner is genuinely unknown** — see `owner(preferred:daemon:)`. Nil is
  /// not cached, so a later reattach re-probes rather than being stuck with a transient answer.
  func backend(forSession sessionID: UUID) -> SessionBackend? {
    if let known = owners[sessionID] { return known }
    let resolved = resolveOwner(sessionID)
    // An UNKNOWN answer is deliberately not cached: it is a transient condition (a daemon that
    // was mid-shutdown, briefly wedged, or losing a race), and remembering it would pin the pane
    // to a plain shell for the rest of the launch. A later reattach re-probes and can succeed.
    if let resolved { owners[sessionID] = resolved }
    return resolved
  }

  /// The ambiguity branch this used to carry is gone, because the state it guarded is now
  /// unreachable. It fired when new sessions were routed at the DAEMON — the old fallback for a
  /// failed agent probe — and answered nil rather than send `workroom-session attach` at an id the
  /// daemon had never held, which the daemon creates rather than refuses. `preferred()` no longer
  /// names the daemon under any condition, so a failed probe now yields nil directly and the same
  /// safety falls out of `owner(preferred:daemon:)` with nothing special to say.
  private func resolveOwner(_ sessionID: UUID) -> SessionBackend? {
    let daemon = daemonOwnership(sessionID)
    // **A wedged retired daemon must not veto a session the live agent holds.** `.unreachable`
    // resolves to nil, and nil blocks `endSession` — which `reap` gates deleting a workroom
    // directory on (issue #7) — so a v2.0.0 daemon that accepts and then stalls made healthy
    // AGENT sessions unkillable and their workrooms undeletable. The daemon's opinion only needs
    // to win for ids the agent does not hold, so ask the agent before accepting the veto.
    if case .unreachable = daemon, case .owned = ownership(of: sessionID, in: .rustAgent) {
      return .rustAgent
    }
    return Self.owner(preferred: backend, daemon: daemon)
  }

  /// Which helper a session belongs to, given where new sessions go and what the daemon said —
  /// or **nil when the answer is genuinely unknown**.
  ///
  /// An earlier version of this resolved `unreachable` to the daemon, on the reasoning that
  /// guessing wrong toward the daemon merely fails loudly ("no such session") while guessing wrong
  /// toward the agent forks a duplicate pty. **That premise was false.** The Swift daemon creates
  /// on attach exactly as the agent does — `SessionDaemon.handleAttach` ends
  /// `create(request: request, connection: connection)` for an id it does not hold — so BOTH
  /// directions silently fork a second shell and orphan the first. There is no loud direction, so
  /// there is no safe guess.
  ///
  /// Answering nil instead means the pane opens a plain shell (`GhosttySurfaceView` already logs
  /// and falls back when no attach command is available). That loses session persistence for that
  /// pane until something re-probes — a visible, recoverable degradation, against a duplicate pty
  /// and an orphaned shell, which is neither.
  ///
  /// `nonisolated` because it touches no state — the probe is the caller's job, and a pure rule
  /// should not need the main actor to evaluate.
  /// `preferred` is itself Optional now: nil means no backend can take a NEW session. It only
  /// reaches the answer through `.notOwned`, so a daemon that CLAIMS the session still resolves to
  /// the daemon even when nothing else can run — which is the whole point of keeping the attach
  /// client, and the case an earlier draft of this change broke.
  nonisolated static func owner(preferred: SessionBackend?, daemon: SessionOwnership)
    -> SessionBackend?
  {
    switch daemon {
    case .owned: return .swiftDaemon
    case .notOwned: return preferred
    case .unreachable: return nil
    }
  }

  /// What the shipped daemon says about this session.
  ///
  /// `notOwned` — not merely "no answer" — when there is no daemon socket at all: that is the
  /// steady state once the migration has drained, and it must not push every session at a daemon
  /// that is not running.
  private func daemonOwnership(_ sessionID: UUID) -> SessionOwnership {
    ownership(of: sessionID, in: .swiftDaemon)
  }

  /// What a specific helper says about a session.
  ///
  /// No socket file at all is `.notOwned` rather than `.unreachable`, for both backends and for the
  /// same reason: a helper that is not running holds nothing. Its sessions are its children and
  /// died with it.
  private func ownership(of sessionID: UUID, in backend: SessionBackend) -> SessionOwnership {
    // A helper that just failed to answer is not asked again for every remaining pane. The answer
    // is the same `.unreachable` it would have given, arrived at without a second 2-second wait —
    // which is what a window of panes opening against one wedged daemon would otherwise cost,
    // serially, on the main actor.
    //
    // **Above the test override on purpose.** The override replaces the round trip, not the policy
    // about how often to make one; with it on top, no test could reach this cooldown at all, and
    // the first version of it shipped with nothing measuring it.
    let currentTime = now()
    if let failedAt = lastUnreachableAt[backend],
      currentTime - failedAt < Self.probeRetryInterval
    {
      return .unreachable
    }

    let answer: SessionOwnership
    if let ownershipOverride {
      answer = ownershipOverride(sessionID)
    } else {
      guard
        let identifier = SessionIdentifier(uuidString: sessionID.uuidString),
        let socketPath = existingSocketPath(for: backend)
      else { return .notOwned }
      answer = controlPlane(socketPath: socketPath, backend: backend)
        .ownership(identifier: identifier)
    }
    // Only the failure is recorded. Clearing this on a real answer looks like the matching half
    // and is not: `now()` is monotonic, so an entry can only be READ while it is still inside the
    // cooldown — and a helper that answered had already outlived it. The clearing branch could
    // never change what the next caller sees.
    if case .unreachable = answer { lastUnreachableAt[backend] = currentTime }
    return answer
  }

  func socketPath(for backend: SessionBackend) -> String? {
    if let cached = resolvedSocketPaths[backend] { return cached }
    do {
      let path = try PersistentSessionPaths.resolveSocketPath(backend: backend)
      resolvedSocketPaths[backend] = path
      return path
    } catch {
      logger.error("unable to resolve the session socket path: \(String(describing: error))")
      return nil
    }
  }

  var socketPath: String? { backend.flatMap { socketPath(for: $0) } }

  func existingSocketPath(for backend: SessionBackend) -> String? {
    let candidates = [
      try? PersistentSessionPaths.preferredSocketPath(backend: backend),
      try? PersistentSessionPaths.fallbackSocketPath(backend: backend),
    ]
    return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
  }

  func binaryPath(for backend: SessionBackend) -> String? {
    PersistentSessionPaths.binaryURL(for: backend)?.path
  }

  var binaryPath: String? { backend.flatMap { binaryPath(for: $0) } }

  /// Whether a NEW session could be created. **Not whether an existing one can be reached** — that
  /// is `attachCommand(forSession:)`, which routes per session. The distinction is the bug this
  /// change was written around twice: gating a RESTORED pane on this answer discards its id before
  /// anything asks who owns it (`TerminalPersistentSessionPolicy`), and gating the attach itself on
  /// it strands every daemon-owned pane whenever the agent is unhealthy.
  var isAvailable: Bool { socketPath != nil && binaryPath != nil }

  /// Whether a session is still there to attach TO, asked immediately before attaching.
  enum DaemonSessionState: Equatable {
    case attachable
    /// The daemon answered, and it does not hold this session. Attaching would make it CREATE one.
    case gone
  }

  /// Re-ask the retired daemon whether it still holds this session, right before we attach to it.
  ///
  /// **The failure this prevents is the one that looks like success.** `SessionDaemon.handleAttach`
  /// — in the shipped v2.0.0 binary, which cannot be changed — ends in
  /// `create(request:connection:)` for an id it does not hold. So when a session's shell has exited
  /// but this launch still has `.swiftDaemon` cached for it, attaching does not fail: the daemon
  /// silently forks a brand new shell and hands it over. The user sees a fresh prompt where their
  /// build was running, with nothing to distinguish it from a successful reattach.
  ///
  /// Asking again is what closes it. Ownership is otherwise resolved once per session and cached
  /// for the launch (a pane asks twice and the two answers must agree), and that cache is correct
  /// for routing — but it long outlives the session it describes.
  ///
  /// **`.unreachable` proceeds, deliberately.** It means we could not ask, not that the session is
  /// gone, and the substitution needs the daemon to be RESPONSIVE enough to answer "not mine" and
  /// then create. A daemon too wedged to reply is also too wedged to fork anything, so attaching
  /// cannot produce the wrong result — and refusing would throw away a session that is probably
  /// still there.
  ///
  /// What it does not close: the daemon can still answer `.owned` here and lose the session before
  /// the attach lands. That race is narrow and cannot be closed from this side of the socket.
  func confirmBeforeAttach(sessionID: UUID, wasRestored: Bool) -> DaemonSessionState {
    // A freshly minted id has never existed anywhere, so create-on-attach is the WANTED behaviour
    // and asking would refuse every new pane. Only an id carried over from a previous launch can
    // name a session that has since died.
    guard wasRestored else { return .attachable }
    // Asked of the host's agent in the attach itself (`--no-create`): one request, so the answer
    // cannot go stale between the question and the attach.
    if isRemote(sessionID) { return .attachable }
    guard let owner = backend(forSession: sessionID) else { return .attachable }
    switch ownership(of: sessionID, in: owner) {
    case .owned, .unreachable:
      return .attachable
    case .notOwned:
      // The cached answer described a session that no longer exists. Drop it so a later reattach
      // resolves afresh rather than walking back into this.
      owners.removeValue(forKey: sessionID)
      logger.error(
        """
        session \(sessionID.uuidString, privacy: .public) is no longer held by the daemon; \
        not attaching, because the shipped daemon would create a new shell instead
        """)
      return .gone
    }
  }

  /// The command libghostty forks for this session, from the helper that owns it.
  ///
  /// Requires the same three things `launchEnvironment` does — owner, binary AND socket — because
  /// the two are consumed as a pair and disagreeing is worse than either refusing. It used to check
  /// only owner and binary, so an unresolvable socket path produced a non-nil command beside an
  /// empty environment: `workroom-session attach` then started with no `WORKROOM_SESSION_ID` or
  /// `_SOCKET` and exited 2 immediately, and because the plain-shell fallback is decided BEFORE the
  /// command is spawned, the pane died rather than degrading. Refusing here degrades properly.
  /// Points `sessionID` at `host`: its pane attaches there, through `driver`, starting in
  /// `workingDirectory` (a path on that host) if the session is new.
  func registerRemoteSession(
    _ sessionID: UUID, on host: HostID, via driver: any HostTerminalDriver,
    workingDirectory: String
  ) {
    remoteSessions[sessionID] = RemoteSession(
      host: host, driver: driver, workingDirectory: workingDirectory)
  }

  func isRemote(_ sessionID: UUID) -> Bool { remoteSessions[sessionID] != nil }

  /// Whether a remote session's last attach was refused by its host for good (#241).
  func remoteHostRefusedLastAttach(_ sessionID: UUID) -> Bool {
    guard let remote = remoteSessions[sessionID] else { return false }
    return remote.driver.hostRefusedLastAttach(of: sessionID, on: remote.host)
  }

  func attachCommand(forSession sessionID: UUID, restored: Bool = false) -> String? {
    if let remote = remoteSessions[sessionID] {
      do {
        return try remote.driver.attachCommand(
          to: remote.host, session: sessionID, workingDirectory: remote.workingDirectory,
          restored: restored)
      } catch {
        logger.error(
          "no attach command for remote session \(sessionID.uuidString, privacy: .public): \(error)"
        )
        // Not nil: nil opens a plain shell, which for this pane would run on the Mac while it
        // reads as the remote workroom's. A pane that says why it could not reach the host is
        // honest; one on the wrong machine is not.
        let notice = "Could not reach this terminal's host: \(error.localizedDescription)"
        return "/bin/sh -c "
          + ContainerHostDriver.shellQuoted(
            "printf '%s\\n' " + ContainerHostDriver.shellQuoted(notice))
      }
    }
    // Nil owner ⇒ nil command ⇒ the caller opens a plain shell rather than guessing a helper.
    guard let owner = backend(forSession: sessionID),
      let path = binaryPath(for: owner),
      socketPath(for: owner) != nil
    else { return nil }
    return path.replacingOccurrences(of: " ", with: "\\ ") + " attach"
  }

  func launchEnvironment(
    sessionID: UUID,
    workingDirectory: String,
    metadata: [(key: String, value: String)] = [],
    shell: String = ProcessInfo.processInfo.environment["SHELL"]
      ?? SessionShellIntegration
      .defaultShell,
    resourcesDirectory: String? = GhosttyResources.bundledURL?.path
  ) -> [(key: String, value: String)] {
    // None for a pane on a remote host: its command carries the session's variables to the host
    // itself (`HostTerminalDriver.attachCommand`), and a `WORKROOM_SESSION_*` left in this pane's
    // environment would point a local `wr-agent` typed there at a session it cannot reach.
    if isRemote(sessionID) { return [] }
    // Socket and binary must both come from the helper that owns THIS session, or the relay is
    // pointed at one implementation while being told to use the other's socket.
    // `WORKROOM_SESSION_BINARY` used to be set here. Its only reader was the attach client's
    // `executablePath()`, which existed only to re-exec itself as `workroom-session daemon` when no
    // daemon answered — a path this build no longer has. The Rust agent's env contract never read
    // it (`WORKROOM_SESSION_{ID,SOCKET,SHELL,CWD,COMMAND,RESOURCES}` only), so it was left written
    // by the app and read by nothing.
    guard
      let backend = backend(forSession: sessionID),
      let socketPath = socketPath(for: backend),
      binaryPath(for: backend) != nil
    else { return [] }
    var entries: [(key: String, value: String)] = [
      ("WORKROOM_SESSION_ID", sessionID.uuidString),
      ("WORKROOM_SESSION_SOCKET", socketPath),
      ("WORKROOM_SESSION_SHELL", shell),
      ("WORKROOM_SESSION_CWD", workingDirectory),
      ("WORKROOM_SESSION_COMMAND", ""),
    ]
    if let resourcesDirectory {
      entries.append(("WORKROOM_SESSION_RESOURCES", resourcesDirectory))
    }
    // Under the `WORKROOM_SESSION_` prefix, like everything else here: the agent scrubs that prefix
    // from the shell it spawns, so these reach the `serve` that `attach` self-spawns and never the
    // user's `env`.
    if backend == .rustAgent {
      entries.append(contentsOf: AgentWakefulnessSettings.current.serveEnvironment)
    }
    let variables = Dictionary(
      uniqueKeysWithValues: SessionMetadataKey.environmentVariables)
    for entry in metadata {
      guard let variable = variables[entry.key], !entry.value.isEmpty else { continue }
      entries.append((variable, entry.value))
    }
    return entries
  }

  private func controlPlane(
    socketPath: String, backend: SessionBackend
  ) -> any SessionControlPlane & Sendable {
    switch backend {
    case .swiftDaemon: return PersistentSessionControlClient(socketPath: socketPath)
    case .rustAgent: return AgentControlClient(socketPath: socketPath)
    }
  }

  /// A client for each helper that is actually running.
  ///
  /// Used wherever an operation spans every session rather than one — listing, and killing
  /// everything — because during the migration sessions genuinely live in both, and a caller that
  /// saw only one would orphan whatever it could not see.
  private func liveControlPlanes() -> [any SessionControlPlane & Sendable] {
    SessionBackend.allCases.compactMap { backend in
      guard let socketPath = existingSocketPath(for: backend) else { return nil }
      return controlPlane(socketPath: socketPath, backend: backend)
    }
  }

  /// The client for whichever helper owns this session.
  private func controlPlane(forSession sessionID: UUID) -> (any SessionControlPlane & Sendable)? {
    guard let backend = backend(forSession: sessionID),
      let socketPath = existingSocketPath(for: backend)
    else { return nil }
    return controlPlane(socketPath: socketPath, backend: backend)
  }

  /// Every live session, from both helpers.
  ///
  /// Merged rather than taken from one: during the migration the daemon still holds the sessions
  /// it created and the agent holds the new ones, and a caller deciding what to tear down must see
  /// all of them or it will orphan whatever it could not see.
  func liveSessions() async -> [SessionDescriptor] {
    let clients = liveControlPlanes()
    guard !clients.isEmpty else { return [] }
    return await Task.detached(priority: .utility) {
      clients.flatMap { $0.list() }
    }.value
  }

  func lookup(sessionID: UUID) async -> PersistentSessionLookup {
    // A remote session is not on any local helper, and asking one would probe (and wait on) a
    // socket that cannot know it. Its host answers for it; this build has no channel for that yet.
    if isRemote(sessionID) { return .unreachable }
    // Routed by OWNER, with no gate on the preferred backend's socket. That gate was left over
    // from before per-session routing and inverted the drain: with the agent preferred but no
    // `agent.sock` yet, every session the daemon still owned reported `.unreachable` — and the
    // close, delete and quit paths built on this then returned without killing them.
    // `controlPlane(forSession:)` already resolves an EXISTING socket for the owning backend.
    guard let identifier = SessionIdentifier(uuidString: sessionID.uuidString),
      let client = controlPlane(forSession: sessionID)
    else { return .unreachable }
    return await Task.detached(priority: .utility) {
      if let descriptor = client.info(identifier: identifier) { return .live(descriptor) }
      return .missing
    }.value
  }

  func isLive(sessionID: UUID) async -> Bool {
    if case .live = await lookup(sessionID: sessionID) { return true }
    return false
  }

  @discardableResult
  func endSession(sessionID: UUID) async -> Bool {
    // Never routed to a local helper, which would be asked to kill an id it does not hold. Ending
    // a session on its host belongs to that host's lifecycle (Phase 4); until then it is reported
    // as not killed, which is true, and nothing that gates on this deletes a local directory for
    // it. The registration STAYS: the session is still running there, and without it a retry
    // would ask the local agent (which "kills" an id it never held) and a reattach would open a
    // new session on this Mac.
    if isRemote(sessionID) {
      logger.error(
        "remote session \(sessionID.uuidString, privacy: .public) left running on its host")
      return false
    }
    // An UNKNOWN owner must report failure, not success. `reap` gates deleting the workroom's
    // directory on this (issue #7), so answering "killed" for a session we could not even route to
    // would delete a worktree out from under a live shell. A malformed id or a missing socket is
    // still "nothing to kill" — only the unresolved case is a failure.
    guard let identifier = SessionIdentifier(uuidString: sessionID.uuidString) else {
      owners.removeValue(forKey: sessionID)
      return true
    }
    // Resolved ONCE. Going through `controlPlane(forSession:)` as well would re-enter
    // `backend(forSession:)`, and an unknown owner is deliberately not cached — so a silent daemon
    // cost two full 2-second probes back to back, on the main actor, during teardown. That is the
    // same double-resolution this change exists to remove, reintroduced one layer up.
    guard let owner = backend(forSession: sessionID) else {
      owners.removeValue(forKey: sessionID)
      logger.error(
        "unresolved owner for session \(sessionID.uuidString, privacy: .public); not killed")
      return false
    }
    guard let socketPath = existingSocketPath(for: owner) else {
      owners.removeValue(forKey: sessionID)
      return true
    }
    let client = controlPlane(socketPath: socketPath, backend: owner)
    // Resolved above, via `backend(forSession:)`, then forgotten: this session is over, and
    // holding its owner would outlive the thing it describes.
    defer { owners.removeValue(forKey: sessionID) }
    let killed = await Task.detached(priority: .utility) { client.kill(identifier: identifier) }
      .value
    if !killed {
      logger.error("failed to kill persistent session \(sessionID.uuidString, privacy: .public)")
    }
    return killed
  }

  /// Awaits every kill before returning so a caller can safely delete the workroom's directory
  /// afterward — a persisted shell that's still exiting must not be racing the teardown (issue #7).
  func endSessions(matchingWorkroom workroomID: String) async {
    let sessions = await liveSessions()
    for session in sessions
    where session.value(forMetadataKey: SessionMetadataKey.workroom) == workroomID {
      if let uuid = session.identifier.uuid { await endSession(sessionID: uuid) }
    }
  }

  /// Kills every live daemon session except those in `attachedSessionIDs` — a session still owned
  /// by an open tab in some window is left running rather than yanked out from under whoever is
  /// looking at it right now. Pass an empty set (the default) to kill everything.
  func endAllSessions(excluding attachedSessionIDs: Set<UUID> = []) async {
    guard !attachedSessionIDs.isEmpty else {
      // Owners go with them: these session ids are dead, and a tab reopened later reuses its
      // persisted id (`TerminalSessions.assignedSessionID`) — a surviving entry would pin it to
      // the helper that held the session just killed.
      owners.removeAll()
      // Every helper, and NOT gated on the preferred backend's socket: during the migration the
      // daemon may still hold sessions the agent knows nothing about, and "stop everything" has to
      // mean everything. `liveControlPlanes()` is already the enumeration of what is running.
      let clients = liveControlPlanes()
      _ = await Task.detached(priority: .utility) { clients.map { $0.killAll() } }.value
      return
    }
    let sessions = await liveSessions()
    for session in sessions {
      guard let uuid = session.identifier.uuid, !attachedSessionIDs.contains(uuid) else { continue }
      await endSession(sessionID: uuid)
    }
  }
}
