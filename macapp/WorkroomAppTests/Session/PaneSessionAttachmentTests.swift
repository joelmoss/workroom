import Foundation
import HostDrivers
import WorkroomDomain
import XCTest

@testable import Workroom

/// When a remote pane reattaches after its ssh exits 255 (#241).
final class RemoteReconnectBackoffTests: XCTestCase {
  /// A host rebooting for two minutes, whatever it answers meanwhile (refused, timed out, closed
  /// before its banner, or sshd up before the daemon): the pane backs off to the ceiling and never
  /// gives up on it.
  func testAHostThatIsGoneForMinutesIsWaitedFor() throws {
    var backoff = RemoteReconnectBackoff()
    // The link drops out of an attach that had been up a while.
    XCTAssertEqual(backoff.next(attachedFor: 3600, refused: false), 1)
    var waited: TimeInterval = 1
    var delays: [TimeInterval] = []
    while waited < 600 {
      let delay = try XCTUnwrap(backoff.next(attachedFor: 10, refused: false))
      delays.append(delay)
      waited += delay
    }
    XCTAssertEqual(Array(delays.prefix(6)), [2, 4, 8, 16, 30, 30])
    XCTAssertEqual(delays.last, 30)
  }

  /// A host that refuses for good (a changed host key) stops the pane after the same budget as
  /// before: five quick refusals, which leaves ssh's message on screen.
  func testARefusalStopsAfterFive() {
    var backoff = RemoteReconnectBackoff()
    XCTAssertEqual(backoff.next(attachedFor: .infinity, refused: false), 1)
    XCTAssertEqual(backoff.next(attachedFor: 1, refused: true), 2)
    XCTAssertEqual(backoff.next(attachedFor: 1, refused: true), 4)
    XCTAssertEqual(backoff.next(attachedFor: 1, refused: true), 8)
    XCTAssertEqual(backoff.next(attachedFor: 1, refused: true), 16)
    XCTAssertNil(backoff.next(attachedFor: 1, refused: true))
  }

  /// Failures that heal, in between, do not restart the count: a refusal alternating with a host
  /// that is briefly unreachable still stops.
  func testARefusalBetweenFailuresThatHealStillStops() {
    var backoff = RemoteReconnectBackoff()
    for _ in 1..<RemoteReconnectBackoff.maxRefusals {
      XCTAssertNotNil(backoff.next(attachedFor: 1, refused: true))
      XCTAssertNotNil(backoff.next(attachedFor: 1, refused: false))
    }
    XCTAssertNil(backoff.next(attachedFor: 1, refused: true))
  }

  /// Value: protects=a pane whose host its provider no longer has stops attaching, rather than
  /// retrying a host that will never come back (#629); fails_when=a gone host is retried, even
  /// after a link that was up; seam=RemoteReconnectBackoff.next
  func testAGoneHostStopsAtOnce() {
    var backoff = RemoteReconnectBackoff()
    XCTAssertNil(backoff.next(attachedFor: 3600, refused: false, gone: true))
    XCTAssertNil(backoff.next(attachedFor: 1, refused: false, gone: true))
  }

  /// An attach that stayed up past the ceiling was a working link: its drop starts over.
  func testALinkThatWasUpStartsTheBackoffAgain() {
    var backoff = RemoteReconnectBackoff()
    for _ in 1..<RemoteReconnectBackoff.maxRefusals {
      _ = backoff.next(attachedFor: 1, refused: true)
    }
    XCTAssertEqual(backoff.next(attachedFor: 60, refused: false), 1)
    XCTAssertEqual(backoff.refusals, 0)
  }
}

/// A surface for a `PaneSessionAttachment` to attach, with no libghostty behind it.
@MainActor
final class FakePaneSurface: PaneSessionSurface {
  var isTornDown = false
  var hasLiveProcess = false
  private(set) var respawns = 0
  private(set) var notices: [String] = []
  func showPaneNotice(_ message: String) { notices.append(message) }
  func respawnSurface() { respawns += 1 }
}

extension XCTestCase {
  /// Registers a session on `service` on a host whose last attach left `log` behind, and `status`
  /// as the attach wrapper's record of ssh's exit status (none when nil). Returns the session and
  /// where that record lives.
  /// `provider`: on an exe.dev host, whose ssh leaves the Mac, rather than a container's loopback.
  @MainActor
  func registerRemoteSession(
    on service: PersistentSessionService, log: String, status: String? = nil,
    provider: Bool = false
  ) throws -> (session: UUID, statusFile: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-reconnect-\(UUID().uuidString.prefix(8))")
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let host = UUID()
    let session = UUID()
    let driver: any HostTerminalDriver =
      provider
      ? ExeDevHostDriver(
        configuration: .init(account: nil, sshAgent: "/agent.sock", hostSetup: .bundled),
        directory: directory)
      : ContainerHostDriver(
        hosts: [
          host: .init(
            address: "127.0.0.1", port: 1, user: "workroom", identityFile: "/keys/id",
            hostKey: "ssh-ed25519 AAAA", daemonSocket: "/s")
        ], directory: directory)
    let hostDirectory = directory.appendingPathComponent(host.uuidString)
    try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
    try log.write(
      to: SSHTransport.attachLog(session, in: hostDirectory), atomically: true,
      encoding: .utf8)
    if let status {
      try status.write(
        to: SSHTransport.attachStatus(session, in: hostDirectory), atomically: true,
        encoding: .utf8)
    }
    service.registerRemoteSession(
      session, on: .remote(host), via: driver, workingDirectory: "/home/w")
    return (session, SSHTransport.attachStatus(session, in: hostDirectory))
  }
}

/// The pane's side of #241: a remote pane whose ssh exits 255 schedules a restored reattach. The
/// backoff's decisions are `RemoteReconnectBackoffTests`; what the attach itself does is the
/// fixture's (`RemoteHostIntegrationTests`); the surface's wiring to its attachment (close, exit,
/// teardown) is `RemotePaneReconnectTests`.
@MainActor
final class PaneSessionAttachmentTests: XCTestCase {
  private let service = isolatedPaneSessionService()
  /// The surfaces the attachments made here attach, kept alive: an attachment holds its weakly.
  private var surfaces: [FakePaneSurface] = []
  /// Each `remotePane`'s record of ssh's status, by session.
  private var statusFiles: [UUID: URL] = [:]

  /// An attachment on a fake surface, pointed at nothing yet.
  private func attachment() -> PaneSessionAttachment {
    let surface = FakePaneSurface()
    surfaces.append(surface)
    let attachment = PaneSessionAttachment(service: service)
    attachment.surface = surface
    addTeardownBlock { attachment.close() }
    return attachment
  }

  /// A pane for a session on a host whose last attach left `log` behind, and `status` as the
  /// attach wrapper's record of ssh's exit status (none when nil).
  private func remotePane(
    log: String, status: String? = nil, provider: Bool = false
  ) throws -> PaneSessionAttachment {
    let remote = try registerRemoteSession(
      on: service, log: log, status: status, provider: provider)
    statusFiles[remote.session] = remote.statusFile
    let pane = attachment()
    pane.tabSessionID = { remote.session }
    return pane
  }

  private func surface(of pane: PaneSessionAttachment) throws -> FakePaneSurface {
    try XCTUnwrap(pane.surface as? FakePaneSurface)
  }

  /// The pane's attach ends with no status recorded: its wrapper removed the last one and was
  /// killed before ssh exited, as by a Ctrl-C typed while ssh was still connecting (#507).
  private func exitBeforeSshRecords(_ pane: PaneSessionAttachment) throws {
    let status = try XCTUnwrap(statusFiles[XCTUnwrap(pane.sessionID)])
    try? FileManager.default.removeItem(at: status)
    pane.childExited()
  }

  // Value: protects=a remote pane the app is reconnecting coming back after a Ctrl-C lands in the
  // second before its ssh connects; fails_when=a missing status on the app's own reconnect reads
  // as a finished attach again; why_new=#507, which #506's reattach on wake made easy to hit;
  // seam=none
  /// A Ctrl-C typed while the app's own reconnect is still connecting kills it, as it would kill
  /// any ssh, before the wrapper records a status (#507). The pane reads that as the lost link it
  /// was reconnecting and keeps trying, again and again if the next attempts are killed too, after
  /// a backoff or a network change alike.
  func testAReconnectKilledBeforeSshConnectsKeepsTrying() throws {
    let view = try remotePane(log: "", status: "255\n")
    view.childExited()
    try XCTUnwrap(view.pendingReconnect).perform()
    for attempt in 1...2 {
      try exitBeforeSshRecords(view)
      let retry = try XCTUnwrap(view.pendingReconnect, "attempt \(attempt) was left stopped")
      retry.perform()
    }
    XCTAssertTrue(view.isRestored)
    // A status the reconnect did record is its answer: a session that ended there stays ended.
    try "0\n".write(
      to: XCTUnwrap(statusFiles[XCTUnwrap(view.sessionID)]), atomically: true,
      encoding: .utf8)
    view.childExited()
    XCTAssertNil(view.pendingReconnect, "a reconnect that ended its session was tried again")

    let live = try remotePane(log: "", provider: true)
    try surface(of: live).hasLiveProcess = true
    let host = try XCTUnwrap(service.remoteHost(of: XCTUnwrap(live.sessionID)))
    postLinksStale([host])
    XCTAssertTrue(live.isRestored, "the network change did not reattach")
    try exitBeforeSshRecords(live)
    XCTAssertNotNil(live.pendingReconnect, "a reattach after a network change was left stopped")
  }

  // Value: protects=Ctrl-C stopping an attach the user started, as it stops any ssh;
  // fails_when=every missing status reads as a lost link, or the app's reconnect outlives an
  // attach the user chose; why_new=#507 reads a missing status as lost only on the app's own
  // reconnect; seam=none
  /// An attach the user chose (from the detached-sessions list) that a Ctrl-C kills stays stopped,
  /// even on a pane the app was reconnecting a moment before.
  func testAnAttachTheUserChoseStaysStoppedWhenKilled() throws {
    let view = try remotePane(log: "", status: "255\n")
    view.childExited()
    try XCTUnwrap(view.pendingReconnect).perform()
    view.reattach()
    try exitBeforeSshRecords(view)
    XCTAssertNil(view.pendingReconnect)
  }

  // Value: protects=a pane restored at launch whose host was unreachable keeping the retry
  // notice's promise when a Ctrl-C kills one of its retries; fails_when=only a link that was up in
  // this run keeps trying again; why_new=a #507 review found restored sessions' retries left out;
  // seam=none
  /// A pane restored at launch is a session the host already has, though its link was never up in
  /// this run: a Ctrl-C that kills one of the app's retries leaves it trying, as the notice on
  /// screen promised.
  func testARestoredPanesRetryKilledBeforeSshConnectsKeepsTrying() throws {
    let view = try remotePane(log: "", status: "255\n")
    view.isRestored = true  // as launch restore marks it
    view.reattach()  // its first attach, which just failed, began now
    view.childExited()
    try XCTUnwrap(view.pendingReconnect).perform()
    try exitBeforeSshRecords(view)
    XCTAssertNotNil(view.pendingReconnect, "a restored pane's killed retry was left stopped")
  }

  // Value: protects=a remote pane reattaching after its host restarts; fails_when=the reconnect is
  // gated on the pane's exit status again, which macOS `login` always reports as 0;
  // why_new=the old test passed 255 straight in, which no real pane ever sees (#392); seam=none
  /// The pane's exit status is `login`'s 0 (#392): the wrapper's record of ssh's 255 is what says
  /// the link dropped.
  func testALostLinkReattachesAsARestoredPane() throws {
    let view = try remotePane(
      log: "ssh: connect to host 127.0.0.1 port 1: Connection refused\n", status: "255\n")
    view.childExited()
    XCTAssertNotNil(view.pendingReconnect)
    XCTAssertFalse(view.isRestored)
    settle(1.5)
    XCTAssertNil(view.pendingReconnect, "the reconnect did not run")
    XCTAssertTrue(view.isRestored)
  }

  // Value: protects=a new remote pane opened offline (or before its daemon is installed) getting a
  // working shell once its host answers, and a Ctrl-C still stopping its retries; fails_when=every
  // reconnect is marked restored again, so its retry carries `--no-create` and the never-created
  // session reads as ended, or a new pane's killed retry keeps trying too (#507);
  // why_new=the reconnect only started firing with #392, which exposed it (Codex review); seam=none
  /// A pane whose first attach never came up retries as a fresh attach: it has no session on the
  /// host yet, and a restored attach (`--no-create`) would show it ended instead of creating it.
  /// Its link was never up, so a Ctrl-C that kills the retry stops it, as it stops any ssh.
  func testAPaneThatNeverConnectedRetriesAsAFreshAttach() throws {
    let view = try remotePane(log: "", status: "255\n")
    view.reattach()  // the attach that just failed began now
    view.childExited()
    XCTAssertNotNil(view.pendingReconnect)
    settle(1.5)
    XCTAssertNil(view.pendingReconnect, "the reconnect did not run")
    XCTAssertFalse(view.isRestored)
    try exitBeforeSshRecords(view)
    XCTAssertNil(view.pendingReconnect, "a Ctrl-C did not stop a link that was never up")
  }

  /// Only ssh's own failure is a lost link: a session that ended with any other status is left
  /// alone, as is a pane with no record of one (an exit status alone never decides, #392), and a
  /// pane whose session is not remote.
  func testOnlyARemotePanesLostLinkReconnects() throws {
    let remote = try remotePane(log: "", status: "1\n")
    remote.childExited()
    XCTAssertNil(remote.pendingReconnect)
    let unrecorded = try remotePane(log: "")
    unrecorded.childExited()
    XCTAssertNil(unrecorded.pendingReconnect)
    let local = attachment()
    let localSession = UUID()
    local.tabSessionID = { localSession }
    local.childExited()
    XCTAssertNil(local.pendingReconnect)
  }

  private func postLinksStale(_ stale: Set<HostID> = []) {
    NotificationCenter.default.post(
      name: RemoteLinkMonitor.linksStale, object: nil,
      userInfo: [RemoteLinkMonitor.staleHostsKey: stale])
    settle(0.05)
  }

  // Value: protects=a remote pane coming back within a second of the Mac waking or changing
  // networks, not after ssh's ~57 s keepalive or a 30 s backoff; fails_when=the pane stops
  // observing the monitor, runs its waiting reconnect without the restored mark, or treats a
  // container's loopback link as one a network change breaks; why_new=new behaviour; seam=none
  /// A pane waiting out its backoff attaches at once, as the restored pane its reconnect would
  /// have made. A container's pane is left to its backoff: its ssh never leaves the Mac.
  func testAWaitingPaneAttachesAtOnceWhenTheNetworkChanges() throws {
    let provider = try remotePane(log: "", status: "255\n", provider: true)
    provider.childExited()
    let container = try remotePane(log: "", status: "255\n")
    container.childExited()
    let waiting = try XCTUnwrap(container.pendingReconnect)
    XCTAssertNotNil(provider.pendingReconnect)

    postLinksStale()
    XCTAssertNil(provider.pendingReconnect, "the waiting reconnect did not run")
    XCTAssertTrue(provider.isRestored)
    XCTAssertTrue(container.pendingReconnect === waiting)
    XCTAssertFalse(container.isRestored)
  }

  // Value: protects=a live link whose host still answers keeping its screen after a wake, and one
  // whose host went silent reattaching; fails_when=every live pane blinks on every wake again, or
  // a pane stays on a link its host no longer answers on; why_new=new behaviour;
  // seam=FakePaneSurface.hasLiveProcess (non-test caller: the surface's libghostty read)
  /// A pane whose ssh still runs attaches again only when its own host didn't answer.
  func testALivePaneAttachesAgainOnlyWhenItsHostDidNotAnswer() throws {
    let view = try remotePane(log: "", provider: true)
    try surface(of: view).hasLiveProcess = true
    let session = try XCTUnwrap(view.sessionID)
    let host = try XCTUnwrap(service.remoteHost(of: session))
    postLinksStale([.remote(UUID())])
    XCTAssertFalse(view.isRestored, "a live link was replaced though its host answered")
    // A pane that stopped (no live ssh, nothing waiting) stays stopped, whatever its host did.
    let stopped = try remotePane(log: "", provider: true)
    let stoppedHost = try XCTUnwrap(service.remoteHost(of: XCTUnwrap(stopped.sessionID)))
    postLinksStale([host, stoppedHost])
    XCTAssertTrue(view.isRestored, "a live link was kept though its host was silent")
    XCTAssertFalse(stopped.isRestored, "a stopped pane was attached again")
  }

  // Value: protects=a pane with no session (an Investigate tab, or no helper) launching its own
  // shell, and a closed pane never attaching again (issue #7 phantom respawn); fails_when=the
  // attachment launches, reconnects or respawns for a pane that has no session or was torn down;
  // why_new=negative control for the attach decision moving out of the view; seam=FakePaneSurface
  /// A pane with no session asks nothing and attaches nothing, however its child exits or the
  /// network moves; a torn-down pane whose lost link would otherwise reconnect stays down.
  func testAPaneWithNoSessionOrThatClosedNeverAttaches() throws {
    let none = attachment()
    XCTAssertNil(
      none.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false),
      "a pane with no session launched an attach")
    none.childExited()
    none.reattach()
    postLinksStale()
    XCTAssertNil(none.pendingReconnect)
    XCTAssertEqual(try surface(of: none).respawns, 0, "a pane with no session respawned")

    let closed = try remotePane(log: "", status: "255\n", provider: true)
    let surface = try surface(of: closed)
    surface.hasLiveProcess = true
    surface.isTornDown = true
    closed.childExited()
    XCTAssertNil(closed.pendingReconnect, "a closed pane scheduled a reconnect")
    postLinksStale([try XCTUnwrap(service.remoteHost(of: XCTUnwrap(closed.sessionID)))])
    closed.reattach()
    XCTAssertEqual(surface.respawns, 0, "a closed pane respawned")
    XCTAssertFalse(closed.isRestored)
  }

  // Value: protects=a remote pane attaching through the service its window registered it on, and
  // holding its host while it does (#356); fails_when=the attachment asks another service (the
  // singleton the view used to read) or drops its token; why_new=the view ignored
  // `TerminalPanes.sessionService` until the attachment was injected; seam=none
  /// The positive side: a remote session's pane launches the host driver's attach, carries none of
  /// this Mac's session variables, and counts as attached to its host until its surface goes.
  func testARemotePaneLaunchesItsHostsAttachThroughItsService() throws {
    let pane = try remotePane(log: "")
    let session = try XCTUnwrap(pane.sessionID)
    let host = try XCTUnwrap(service.remoteHost(of: session))
    XCTAssertFalse(service.hasAttachedPane(on: host), "fixture: nothing attached yet")

    let launch = try XCTUnwrap(
      pane.launch(workingDirectory: "/Users/me", runCommand: nil, isRunSession: false))
    // The probe form (no pane) records nothing, so it does not change what is asserted below.
    XCTAssertEqual(launch.command, service.attachCommand(forSession: session, restored: false))
    XCTAssertTrue(launch.environment.isEmpty, "a remote pane got this Mac's session variables")
    XCTAssertTrue(service.hasAttachedPane(on: host))
    XCTAssertTrue(try surface(of: pane).notices.isEmpty, "a remote session was said replaced")

    pane.surfaceGone()
    XCTAssertFalse(service.hasAttachedPane(on: host), "a pane whose surface went holds its host")
  }

  /// A restored pane on a service whose daemon holds no session: its session is gone. Each pane's
  /// record forgets count in `forgets`, and its confirmation wait never runs out on its own.
  private func goneSessionPanes() -> (
    pane: (ResumeRecord?) -> (PaneSessionAttachment, FakePaneSurface), forgets: () -> Int
  ) {
    let gone = PersistentSessionService(
      probe: { _ in .ready(version: "protocol 1") }, ownership: { _ in .notOwned })
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("wr-resume-pane-\(UUID().uuidString.prefix(8))")
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    gone.resumeLaunchDirectory = folder
    var forgets = 0
    let pane = { (record: ResumeRecord?) -> (PaneSessionAttachment, FakePaneSurface) in
      let surface = FakePaneSurface()
      self.surfaces.append(surface)
      let pane = PaneSessionAttachment(service: gone)
      pane.surface = surface
      self.addTeardownBlock { pane.close() }
      let session = UUID()
      pane.tabSessionID = { session }
      pane.tabResume = { record }
      pane.forgetTabResume = { forgets += 1 }
      pane.resumeConfirmationWait = 3600
      pane.isRestored = true
      return (pane, surface)
    }
    return (pane, { forgets })
  }

  private let claude = ResumeRecord(
    argv: ["claude", "--resume", "a"], cwd: NSTemporaryDirectory(), reportedAt: 1, boot: "b")

  /// Value: protects=a restored local pane whose session is gone handing its tab's resume record
  /// to its relay in a file named in `WORKROOM_SESSION_RESUME`, saying "Resumed …" only once the
  /// daemon says the program started, and "Couldn't resume …" once when it says it failed, which
  /// forgets the record; and a tab with no record, one whose folder is gone, and a run tab keeping
  /// today's behaviour; fails_when=the file or the variable goes missing, "Resumed" shows before
  /// anything confirms it, the toast is wrong, a failure is said twice or for a pane that resumed
  /// nothing; why_new=new (#825); seam=the service's launch folder
  func testARestoredPaneWhoseSessionIsGoneResumesItsTabsRecord() throws {
    let (pane, forgets) = goneSessionPanes()
    let (resuming, toasts) = pane(claude)
    let launch = resuming.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false)
    let launched = try XCTUnwrap(launch, "no daemon command in this test host")
    let file = try XCTUnwrap(
      launched.environment.first { $0.key == ResumeLaunchFile.variable }?.value)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file))
    XCTAssertEqual(toasts.notices, [], "nothing has said the program started yet")
    resuming.resumeStarted()
    resuming.resumeStarted()
    XCTAssertEqual(toasts.notices, ["Resumed Claude Code"])
    resuming.resumeFailed()
    resuming.resumeFailed()
    XCTAssertEqual(toasts.notices, ["Resumed Claude Code", "Couldn't resume Claude Code"])
    XCTAssertEqual(forgets(), 1, "a failed resume forgets its record")

    var away = claude
    away.cwd = "/definitely/not/a/folder"
    for (record, isRun, said) in [
      (nil, false, [PaneNoticeToast.sessionReplaced]),
      (away, false, [PaneNoticeToast.sessionReplaced]),
      (claude, true, []),
    ] as [(ResumeRecord?, Bool, [String])] {
      let (plain, notices) = pane(record)
      let launch = plain.launch(workingDirectory: "/tmp", runCommand: "x", isRunSession: isRun)
      XCTAssertNil(launch?.environment.first { $0.key == ResumeLaunchFile.variable })
      XCTAssertEqual(notices.notices, said)
      plain.resumeStarted()
      plain.resumeFailed()
      plain.resumeUnconfirmed()
      XCTAssertEqual(notices.notices, said, "a pane that resumed nothing says nothing more")
    }
    XCTAssertEqual(forgets(), 1)
  }

  /// Value: protects=a resume nothing confirms within the wait (a shell whose Workroom hook loaded
  /// and is still starting, one whose startup files keep the hook from running, a dropped link)
  /// saying the pane got a new shell but keeping the record, which only the daemon's decline
  /// forgets, and a start or failure heard after that, however late, still correcting the toast;
  /// fails_when=an unconfirmed resume says "Resumed", forgets its record by itself, toasts twice,
  /// loses a late start or failure past `resumeFailureWindow`, or a later decline keeps the record;
  /// why_new=#825's third review (the fallback forgot records a hooked shell would have resumed);
  /// seam=the wait, run out by the test; the state, checked past the window
  func testAResumeNothingConfirmsKeepsItsRecordAndALateWordCorrectsIt() throws {
    let (pane, forgets) = goneSessionPanes()
    let (late, toasts) = pane(claude)
    XCTAssertNotNil(late.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false))
    late.resumeUnconfirmed()
    late.resumeUnconfirmed()
    XCTAssertEqual(toasts.notices, [PaneNoticeToast.sessionReplaced])
    XCTAssertEqual(forgets(), 0, "only the daemon's decline forgets the record")
    XCTAssertEqual(late.resumeState, .unconfirmed(program: "Claude Code"), "with no clock")
    late.resumeStarted()
    XCTAssertEqual(toasts.notices, [PaneNoticeToast.sessionReplaced, "Resumed Claude Code"])
    late.resumeUnconfirmed()
    late.resumeDeclined()
    XCTAssertEqual(toasts.notices.count, 2, "a started resume is never declined")
    XCTAssertEqual(forgets(), 0)

    let (failing, failed) = pane(claude)
    XCTAssertNotNil(failing.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false))
    failing.resumeUnconfirmed()
    failing.resumeFailed()
    XCTAssertEqual(
      failed.notices, [PaneNoticeToast.sessionReplaced, "Couldn't resume Claude Code"])
    XCTAssertEqual(forgets(), 1, "a failure forgets the record")

    let (declined, said) = pane(claude)
    XCTAssertNotNil(declined.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false))
    declined.resumeUnconfirmed()
    declined.resumeDeclined()
    declined.resumeDeclined()
    XCTAssertEqual(said.notices, [PaneNoticeToast.sessionReplaced], "said once")
    XCTAssertEqual(forgets(), 2, "the daemon's decline after the fallback forgets it, once")
  }

  /// Value: protects=a resume the daemon declined (#825: its shell never ran Workroom's hook)
  /// saying at once that the pane got a new shell and forgetting the record, once, with no wait,
  /// and a decline never undoing a resume that started or failed; fails_when=the pane waits out
  /// its fallback instead, keeps the record, says it twice, or a decline after a start toasts;
  /// why_new=#825's second review (`resumeDeclined`); seam=the service's launch folder
  func testAResumeTheDaemonDeclinedSaysSoAtOnceAndForgetsItsRecord() throws {
    let (pane, forgets) = goneSessionPanes()
    let (declined, toasts) = pane(claude)
    XCTAssertNotNil(declined.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false))
    declined.sessionReported()
    declined.resumeDeclined()
    declined.resumeDeclined()
    declined.resumeUnconfirmed()
    XCTAssertEqual(toasts.notices, [PaneNoticeToast.sessionReplaced])
    XCTAssertEqual(forgets(), 1, "a declined resume forgets its record")

    let (started, said) = pane(claude)
    XCTAssertNotNil(started.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false))
    started.resumeStarted()
    started.resumeDeclined()
    XCTAssertEqual(said.notices, ["Resumed Claude Code"], "a started resume is never declined")
    XCTAssertEqual(forgets(), 1)
  }

  /// Value: protects=the fallback wait starting only once the session's daemon has said anything
  /// of it, not at launch (#825: hidden tabs restored together on a cold disk start their login
  /// shells slowly), and running out by itself from there; fails_when=the timer starts at launch,
  /// is never scheduled, or fires after a start; why_new=#825's second review (the wait's clock);
  /// seam=a short wait, waited on for 3 s+
  func testTheConfirmationWaitRunsOutOnItsOwn() throws {
    let (pane, _) = goneSessionPanes()
    let (silent, unheard) = pane(claude)
    silent.resumeConfirmationWait = 0.05
    XCTAssertNotNil(silent.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false))
    let (unconfirmed, toasts) = pane(claude)
    unconfirmed.resumeConfirmationWait = 0.05
    XCTAssertNotNil(
      unconfirmed.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false))
    unconfirmed.sessionReported()
    let (confirmed, quiet) = pane(claude)
    confirmed.resumeConfirmationWait = 0.05
    XCTAssertNotNil(
      confirmed.launch(workingDirectory: "/tmp", runCommand: nil, isRunSession: false))
    confirmed.sessionReported()
    confirmed.resumeStarted()
    let declined = expectation(description: "the wait ran out")
    let deadline = Date().addingTimeInterval(5)
    func check() {
      if toasts.notices == [PaneNoticeToast.sessionReplaced] || Date() > deadline {
        declined.fulfill()
      } else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check)
      }
    }
    check()
    wait(for: [declined], timeout: 6)
    XCTAssertEqual(toasts.notices, [PaneNoticeToast.sessionReplaced], "the unconfirmed resume")
    XCTAssertEqual(quiet.notices, ["Resumed Claude Code"], "a started one's wait was cancelled")
    XCTAssertEqual(unheard.notices, [], "no wait before the daemon has said anything")
  }

  /// Value: protects=a restored remote pane (#826) handing its tab's record to its client at every
  /// launch, since only the host knows whether its session is gone, with its host folder unchecked
  /// here; saying nothing for a session its record's own daemon still holds, however sticky its
  /// last resume's flags, nor before the daemon has said anything; and awaiting, then toasting
  /// "Resumed …", once a new daemon (a host restart) made it again; and no record for a new pane
  /// or a run tab; fails_when=a live reattach toasts "Resumed" or "created a new one", a resumed
  /// session is never toasted, or a remote pane never gets the file; why_new=new (#826); seam=the
  /// service's launch folder
  func testARestoredRemotePaneOffersItsRecordAndToastsOnlyWhatItsHostResumed() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("wr-resume-remote-\(UUID().uuidString.prefix(8))")
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    service.resumeLaunchDirectory = folder
    let record = ResumeRecord(
      argv: ["claude", "--resume", "a"], cwd: "/home/w/not-on-this-mac", reportedAt: 1, boot: "b")
    func launched(restored: Bool = true, run: Bool = false) throws -> (
      PaneSessionAttachment, FakePaneSurface, String?
    ) {
      let pane = try remotePane(log: "", provider: true)
      pane.tabResume = { record }
      pane.resumeConfirmationWait = 3600
      pane.isRestored = restored
      let launch = pane.launch(workingDirectory: "/home/w", runCommand: "x", isRunSession: run)
      let file = try XCTUnwrap(launch).environment.first {
        $0.key == ResumeLaunchFile.variable
      }?.value
      return (pane, try surface(of: pane), file)
    }

    let (live, quiet, file) = try launched()
    let path = try XCTUnwrap(file, "a restored remote pane hands its client the record")
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    XCTAssertEqual(live.resumeState, .offered(program: "Claude Code", boot: "b"))
    live.sessionHeard(boot: nil)
    live.resumeStarted()
    live.resumeDeclined()
    XCTAssertEqual(quiet.notices, [], "nothing said before its daemon says anything")
    live.sessionHeard(boot: "b")
    live.resumeStarted()
    live.sessionReported()
    XCTAssertEqual(
      live.resumeState, .offered(program: "Claude Code", boot: "b"),
      "its record's daemon held it live: the offer stays inert")
    XCTAssertEqual(quiet.notices, [], "a live reattach says nothing, however sticky the flags")

    let (resumed, toasts, _) = try launched()
    resumed.sessionHeard(boot: "after the restart")
    XCTAssertEqual(resumed.resumeState, .awaiting(program: "Claude Code"))
    resumed.resumeStarted()
    resumed.sessionHeard(boot: "after the restart")
    XCTAssertEqual(toasts.notices, ["Resumed Claude Code"])

    for (restored, run) in [(false, false), (true, true)] {
      let (pane, notices, file) = try launched(restored: restored, run: run)
      XCTAssertNil(file, "restored \(restored), run \(run)")
      XCTAssertNil(pane.resumeState)
      XCTAssertEqual(notices.notices, [])
    }
  }

  /// A tab's surface attaches through the service its window holds, whichever factory made the
  /// surface.
  func testATabsSurfaceAttachesThroughItsWindowsService() throws {
    let sessions = makeIsolatedPanes(service: service)
    let target = TerminalTarget(
      id: .workroom(project: "/p", name: "foo"), title: "foo", path: "/tmp", isMissing: false)
    let tab = sessions.addTab(for: target)
    XCTAssertTrue(try XCTUnwrap(sessions.surface(tab)).attachment.service === service)
  }
}
