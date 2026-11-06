import Foundation
import WorkroomDomain
import os

/// What a `PaneSessionAttachment` needs from the surface it attaches: `GhosttySurfaceView`, or a
/// test's stand-in, so the attach and reconnect rules are tested without an `NSView`.
@MainActor
protocol PaneSessionSurface: AnyObject {
  /// Set once the pane closed: it must never attach again (issue #7 phantom respawn).
  var isTornDown: Bool { get }
  /// Whether the surface's child process, the attach, still runs.
  var hasLiveProcess: Bool { get }
  /// A toast over the pane, for news about its session (#459).
  func showPaneNotice(_ message: String)
  /// Free the surface and create it again, which attaches anew through `launch`.
  func respawnSurface()
}

/// The daemon session a terminal pane attaches to, and when it attaches again: what the surface
/// launches instead of a login shell, the remote reconnect after a lost link (#241, #392, #507), and
/// the re-attach on wake or a network change. The surface asks it; the session policy lives here.
@MainActor
final class PaneSessionAttachment {
  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "PersistentSession")

  /// What a pane attached to a session runs instead of a login shell.
  struct Launch {
    let command: String
    let environment: [(key: String, value: String)]
  }

  /// Where this pane's session is attached and ended. `TerminalSessions` sets its own
  /// `sessionService` here when it makes the pane, before the session id.
  var service: PersistentSessionService
  /// The surface it attaches. Weak: the surface owns its attachment.
  weak var surface: (any PaneSessionSurface)?

  /// Names this pane's attach (`PersistentSessionService.attachCommand(by:)`), so only this pane
  /// clears it. Not its object identity, which a later view can reuse once this one is freed.
  let token = UUID()
  /// Daemon session this pane attaches to. When set and the helper is available, the surface
  /// launches `workroom-session attach` instead of a login shell.
  var sessionID: UUID? {
    // Pointed at another session (the detached-sessions list): the old one's ssh goes with the
    // surface it is about to lose, so it no longer counts as attached to its remote host (#356).
    didSet {
      if let oldValue, oldValue != sessionID { service.paneDetached(oldValue, by: token) }
    }
  }
  /// Whether `sessionID` was carried over from a previous launch rather than minted for this pane.
  /// Only a restored id can name a session that has since died, and only a restored id is
  /// re-checked before attaching — asking about a fresh one would refuse every new pane, since no
  /// helper holds an id that has never existed.
  var isRestored = false
  /// Project / workroom / tab / title metadata sent on attach.
  var metadata: [(key: String, value: String)] = []

  /// When a remote pane reattaches after its ssh exits 255, and when it stops trying.
  private var backoff = RemoteReconnectBackoff()
  /// When this pane last attached, to tell a link that dropped after a while (start the backoff
  /// again) from one that never came up (keep backing off).
  private var lastAttachAt = Date.distantPast
  /// Whether the last attach was up long enough to count as a link that was up, so attaching again
  /// is a restored pane's (`reconnectIfTheLinkDropped`).
  private var linkWasUp: Bool {
    Date().timeIntervalSince(lastAttachAt) > RemoteReconnectBackoff.ceiling
  }
  /// Whether the app's own reconnect started the current attach, so one that brings back a
  /// restored session keeps trying when it is killed before ssh exits (#507).
  private var attachedByTheAppsReconnect = false
  /// The reconnect waiting out its delay, cancelled by any other reattach so the pane does not
  /// attach twice, and by closing the pane.
  private(set) var pendingReconnect: DispatchWorkItem?

  /// `RemoteLinkMonitor`'s, for the pane's lifetime: a hidden tab or a detached pane keeps its ssh
  /// while it is in no window. `nonisolated(unsafe)` only so `deinit` can remove it.
  nonisolated(unsafe) private var remoteLinkObserver: NSObjectProtocol?

  /// Test seam: forces `isReattachingAfterLinkLoss`.
  var reattachingOverrideForTesting: Bool?

  init(service: PersistentSessionService = .shared) {
    self.service = service
    remoteLinkObserver = NotificationCenter.default.addObserver(
      forName: RemoteLinkMonitor.linksStale, object: nil, queue: .main
    ) { [weak self] note in
      let stale = note.userInfo?[RemoteLinkMonitor.staleHostsKey] as? Set<HostID> ?? []
      MainActor.assumeIsolated { self?.reattachAfterNetworkChange(staleHosts: stale) }
    }
  }

  deinit {
    if let remoteLinkObserver { NotificationCenter.default.removeObserver(remoteLinkObserver) }
  }

  /// Whether the pane may attach: it has a surface, and that surface was not torn down.
  private var surfaceIsLive: Bool { surface.map { !$0.isTornDown } ?? false }

  /// What the surface launches for its session, asked synchronously before it creates the surface;
  /// nil for a login shell (or the surface's own command).
  ///
  /// Non-nil is not strictly "a session was attached". A restored session that has since ended gets
  /// `workroomd attach --no-create`, which tells the user so and starts a new session in its place,
  /// or a plain shell if even that fails. The surface only uses the answer to decide whether to
  /// install a run command, and a pane with a persistent session is never a run-command pane
  /// (`TerminalPersistentSessionPolicy` excludes them), so the distinction costs nothing.
  func launch(workingDirectory: String, runCommand: String?, isRunSession: Bool) -> Launch? {
    // No session was requested for this pane — not a failure, nothing to log.
    guard let sessionID else { return nil }

    // Ask the retired Swift helper once more, before committing to an attach, whether it still holds
    // this. It CREATES a session on attach for an id it does not hold, so a cached ownership answer
    // that has outlived its session would turn a reattach into a brand new shell with nothing to
    // mark it as one. A lost one drops its cached owner, so the attach below re-resolves to the
    // daemon, whose `--no-create` attach shows the session ended and starts a new one in its place.
    // See `confirmBeforeAttach`.
    service.confirmBeforeAttach(sessionID: sessionID, wasRestored: isRestored)
    // A run session that is gone is never replaced (#522, D2): its tab says the run ended.
    if !isRunSession, service.willReplaceRestoredSession(sessionID, wasRestored: isRestored) {
      surface?.showPaneNotice(PaneNoticeToast.sessionReplaced)
    }
    // Deliberately NOT gated on `PersistentSessionService.isAvailable`, and
    // `PersistentSessionAttachGateTests` fails if that is ever reintroduced. `isAvailable` answers
    // for the backend a NEW session would go to, so it goes false whenever the daemon is unhealthy
    // — which is precisely when a session the retired Swift helper still holds most needs reaching.
    // Gating here rejected those panes before `attachCommand` could route them, defeating the
    // attach-only client in its own use case. `attachCommand(forSession:)` already answers nil when
    // the owning backend has no binary, so the global check bought nothing on this path.
    guard
      let command = service.attachCommand(
        forSession: sessionID, restored: isRestored, by: token)
    else {
      // A pane that expected a persisted session fell back to a plain login shell. Whatever the
      // helper-side session was doing is now orphaned/unreachable from this pane — worth a log
      // line since the resulting terminal otherwise looks identical to a normal fresh shell.
      Self.logger.error(
        """
        persistent session \(sessionID.uuidString, privacy: .public) unavailable \
        (no owning helper resolved); falling back to a plain shell
        """)
      return nil
    }
    let environment = service.launchEnvironment(
      sessionID: sessionID,
      workingDirectory: workingDirectory,
      metadata: metadata,
      runCommand: isRunSession ? runCommand : nil)
    // A pane's first attach starts here, not in `reattach`: without this its `lastAttachAt` stays
    // `.distantPast`, and a first attach that never connected reads as a link that was up
    // (`reconnectIfTheLinkDropped`).
    lastAttachAt = Date()
    return Launch(command: command, environment: environment)
  }

  /// The surface's child exited: its ssh, for a remote pane.
  func childExited() {
    // A dead ssh no longer counts as attached, whether or not it reconnects (#356).
    surfaceGone()
    reconnectIfTheLinkDropped()
  }

  /// This pane's ssh is gone with its surface (freed, or never made): it no longer counts as
  /// attached to its remote host (#356).
  func surfaceGone() {
    if let sessionID { service.paneDetached(sessionID, by: token) }
  }

  /// The pane closed (`GhosttySurfaceView.tearDown`): a reconnect waiting out its delay never runs,
  /// and network changes no longer reach it.
  func close() {
    pendingReconnect?.cancel()
    pendingReconnect = nil
    if let remoteLinkObserver {
      NotificationCenter.default.removeObserver(remoteLinkObserver)
      self.remoteLinkObserver = nil
    }
  }

  /// A pane on a remote host whose ssh lost the link reattaches, rather than sitting on a dead
  /// process while its session runs on: 255 is ssh's own failure, as after laptop sleep, a network
  /// change or the host rebooting. It reattaches as a restored pane, so a session that ended
  /// meanwhile shows as ended. See `RemoteReconnectBackoff` for when it gives up.
  ///
  /// ssh's status comes from what the attach wrapper recorded, never from the pane's exit status:
  /// libghostty runs every command under macOS `login`, which exits 0 whatever ran under it, so
  /// gating on the exit status meant no pane ever reattached (#392).
  ///
  /// Only a pane whose attach had been up becomes a restored one. A new pane whose first attach
  /// never connected (opened offline, or before the bootstrap installed the daemon) has no session
  /// on the host yet: reattaching it with `--no-create` would show it ended instead of creating
  /// it. Up means longer than the backoff's ceiling, which already reads that as a link that was up.
  ///
  /// An attach that recorded no status was killed before ssh exited, as by a Ctrl-C typed while
  /// ssh was still connecting. Ctrl-C does there what it does to any ssh. When the app's own
  /// reconnect was bringing back a restored session (one on the host already, as after a link
  /// that was up or a launch), the pane keeps trying, as the retry notice on screen promises: what
  /// the user meant to stop was most likely the program they had been typing to (#507). A new
  /// pane's attaches, and any attach the app's reconnect did not start, stay stopped.
  private func reconnectIfTheLinkDropped() {
    let attachedFor = Date().timeIntervalSince(lastAttachAt)
    guard let session = sessionID, surfaceIsLive,
      service.isRemote(session),
      case let ended = service.remoteLastAttach(session),
      ended == .lostLink
        || (ended == .unrecorded && attachedByTheAppsReconnect && isRestored),
      let delay = backoff.next(
        attachedFor: attachedFor,
        refused: service.remoteHostRefusedLastAttach(session))
    else { return }
    let wasUp = linkWasUp
    let reconnect = DispatchWorkItem { [weak self] in
      guard let self, self.surfaceIsLive, self.sessionID == session else { return }
      if wasUp { self.isRestored = true }
      self.reattach(reconnecting: true)
    }
    pendingReconnect = reconnect
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: reconnect)
  }

  /// The Mac woke or changed networks (`RemoteLinkMonitor`): attach again now rather than wait up
  /// to a minute for ssh's keepalive to notice a dead link, or out a backoff of up to 30 s. A pane
  /// that stopped (refused for good, or its session ended) stays stopped. A pane whose ssh still
  /// runs attaches again only when its host didn't answer (`staleHosts`), since one that did most
  /// likely still carries it. A container's link is loopback, which no network change breaks.
  func reattachAfterNetworkChange(staleHosts: Set<HostID>) {
    guard let session = sessionID, surfaceIsLive,
      service.remoteLinkCrossesNetwork(session)
    else { return }
    if let pendingReconnect {
      backoff = RemoteReconnectBackoff()
      // Its own work item, which knows whether the link had been up (`reconnectIfTheLinkDropped`).
      pendingReconnect.perform()
      return
    }
    guard surface?.hasLiveProcess == true, let host = service.remoteHost(of: session),
      staleHosts.contains(host)
    else { return }
    backoff = RemoteReconnectBackoff()
    if linkWasUp { isRestored = true }
    reattach(reconnecting: true)
  }

  /// Attach again: the surface is freed and made anew. `reconnecting`: the app's own reconnect is
  /// starting this attach, not the user (#507).
  func reattach(reconnecting: Bool = false) {
    guard sessionID != nil, let surface, !surface.isTornDown else { return }
    attachedByTheAppsReconnect = reconnecting
    pendingReconnect?.cancel()
    pendingReconnect = nil
    lastAttachAt = Date()
    surface.respawnSurface()
  }

  /// Whether the app is reattaching this remote pane after its link dropped, or is about to: a run
  /// session that ended meanwhile then shows the daemon's ended notice and holds, so the run's end
  /// never reaches this pane's own exit (#522).
  var isReattachingAfterLinkLoss: Bool {
    reattachingOverrideForTesting ?? (pendingReconnect != nil || attachedByTheAppsReconnect)
  }
}

/// When a remote pane whose ssh exited 255 attaches again, and when it stops (#241).
///
/// Backs off from 1s, doubling to 30s, and keeps trying for as long as it takes: a rebooting cloud
/// VM can be gone for minutes, and its pane should come back to its last screen (#232) on its own.
/// The exception is a host that answered and refused for good (a changed host key, a refused key:
/// `HostTerminalDriver.hostRefusedLastAttach`). The fifth of those within 30s of an attach stops
/// the pane with ssh's message on screen, since retrying would only repeat it. Other failures in
/// between do not restart that count, so a refusal that alternates with a host that is briefly
/// unreachable still stops. A pane whose host is gone for good retries until it is closed.
struct RemoteReconnectBackoff {
  static let ceiling: TimeInterval = 30
  static let maxRefusals = 5
  private(set) var delay: TimeInterval = 1
  private(set) var refusals = 0

  /// The wait before the next attach, or nil to stop. `attachedFor` is how long ago the attach
  /// that just failed began; longer than the ceiling is a link that dropped after it was up.
  mutating func next(attachedFor: TimeInterval, refused: Bool) -> TimeInterval? {
    if attachedFor > Self.ceiling {
      delay = 1
      refusals = 0
    } else if refused {
      refusals += 1
      guard refusals < Self.maxRefusals else { return nil }
    }
    defer { delay = min(delay * 2, Self.ceiling) }
    return delay
  }
}
