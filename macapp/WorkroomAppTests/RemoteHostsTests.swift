import CryptoKit
import Defaults
import XCTest

@testable import Workroom

/// Guards on remote workrooms that need no Docker (#253): connecting a host once for every caller,
/// backing off a dead one, the image IDs `destroy` removes with `--force`, a base reused only for
/// its own repository, the client key's repair, the create guard, and re-reading a remote tree.
final class RemoteHostsTests: XCTestCase {
  /// Counts connects, fails them or not, and holds each until released, for
  /// `RemoteHosts.ensureConnected`.
  private final class Connects: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var failing = false
    private var held = true
    private var asked = 0
    private var instant = ContinuousClock.now
    var calls: Int { lock.withLock { count } }
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func fail(_ on: Bool) { lock.withLock { failing = on } }
    func advance(_ by: Duration) { lock.withLock { instant += by } }
    func hold(_ on: Bool) { lock.withLock { held = on } }
    /// Callers that have reached `ensureConnected`'s connected check.
    var arrived: Int { lock.withLock { asked } }
    func ask() { lock.withLock { asked += 1 } }

    func connect(_ host: HostID) async throws {
      lock.withLock { count += 1 }
      while lock.withLock({ held }) { try await Task.sleep(for: .milliseconds(1)) }
      if lock.withLock({ failing }) { throw HostDriverError.unknownHost(host) }
    }
  }

  private func hosts(_ connects: Connects) -> RemoteHosts {
    RemoteHosts(
      connectHost: { try await connects.connect($0) },
      isConnected: { _ in
        connects.ask()
        return false
      },
      startHost: { _ in }, now: { connects.now })
  }

  /// The inspector's panels ask together when a remote workroom is selected: one connect serves
  /// them all, where a second would be refused while the first is running.
  func testCallersAtOnceShareOneConnect() async throws {
    let connects = Connects()
    let remote = hosts(connects)
    let host = HostID.remote(UUID())

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<5 { group.addTask { try await remote.ensureConnected(host) } }
      // Every caller is in before the one connect finishes: it is held until all five have asked
      // whether the host is up, past which each joins the running connect without suspending.
      while connects.arrived < 5 { try await Task.sleep(for: .milliseconds(1)) }
      try await Task.sleep(for: .milliseconds(20))
      connects.hold(false)
      try await group.waitForAll()
    }
    XCTAssertEqual(connects.calls, 1)
  }

  /// A host that is down answers for `retryAfter` without another connect, each of which would wait
  /// out ssh's timeout, and is tried again after it.
  func testADeadHostIsRetriedOnlyAfterItsWindow() async throws {
    let connects = Connects()
    let remote = hosts(connects)
    let host = HostID.remote(UUID())
    connects.fail(true)
    connects.hold(false)

    for _ in 0..<2 {
      do {
        try await remote.ensureConnected(host)
        XCTFail("a dead host connected")
      } catch {
        XCTAssertEqual(error as? RepositoryRoutingError, .unavailable(host))
      }
    }
    XCTAssertEqual(connects.calls, 1, "a dead host was tried again inside its window")

    connects.fail(false)
    connects.advance(RemoteHosts.retryAfter)
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 2)
  }

  /// A background read never connects to a boxd box boxd says is asleep: the ssh login would wake
  /// it, and every status sweep would keep every box awake and billing (#356). boxd is asked once a
  /// `retryAfter`; opening the workroom connects and wakes it; when boxd can't say, the read leaves
  /// the box be too, so a broken CLI cannot wake every box, and asks again only after a
  /// `retryAfter`; and when it says it's awake, the read goes ahead as before.
  func testABackgroundReadLeavesAnAsleepBoxdBoxAsleep() async throws {
    let connects = Connects()
    connects.hold(false)
    let asked = Asleep()
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in }, now: { connects.now },
      presence: { _ in asked.answer() })
    let id = UUID()
    let host = HostID.remote(id)
    remote.adopt([
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "w", path: "/home/boxd/r", vcsName: "workroom/w", warnings: [],
            host: HostDescriptor(
              driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner, id: id,
              account: "usr_1"))
        ])
    ])

    asked.set(true)
    for _ in 0..<2 {
      do {
        try await remote.ensureConnected(host)
        XCTFail("a background read connected to an asleep box")
      } catch {
        XCTAssertEqual(error as? RepositoryRoutingError, .asleep(host))
      }
    }
    XCTAssertEqual(connects.calls, 0)
    XCTAssertEqual(asked.calls, 1, "boxd was asked again inside the window")

    // Opening the workroom wakes it.
    remote.activate(host)
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 1)

    // boxd can't say: the read leaves the box be, and boxd isn't asked again inside the window.
    asked.set(nil)
    connects.advance(RemoteHosts.retryAfter)
    let unsure = asked.calls
    for _ in 0..<2 {
      do {
        try await remote.ensureConnected(host)
        XCTFail("a background read connected to a box boxd could not say about")
      } catch {
        XCTAssertEqual(error as? RepositoryRoutingError, .asleep(host))
      }
    }
    XCTAssertEqual(connects.calls, 1)
    XCTAssertEqual(
      asked.calls, unsure + 1, "boxd was asked again inside the window after no answer")
    // boxd says it's running: the read connects as it always did.
    asked.set(false)
    connects.advance(RemoteHosts.retryAfter)
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 2)

    // A machine boxd says is gone is reported as gone, not asleep, and then left for the window.
    asked.setGone()
    connects.advance(RemoteHosts.retryAfter)
    let before = asked.calls
    for expected in [RepositoryRoutingError.gone(host), .unavailable(host)] {
      do {
        try await remote.ensureConnected(host)
        XCTFail("a gone machine was connected to")
      } catch {
        XCTAssertEqual(error as? RepositoryRoutingError, expected)
      }
    }
    XCTAssertEqual(asked.calls, before + 1, "boxd was asked again inside the window")
    XCTAssertEqual(connects.calls, 2)
  }

  /// boxd counts inbound traffic as activity, so a connection's keepalives and the badge's polls
  /// held an idle box awake for good (measured live, #356). A boxd host that reports IDLE while
  /// not selected is let go of, and a background read then never reconnects it; selecting or
  /// opening its workroom does. A busy, selected or container host is kept.
  @MainActor
  func testAnIdleBoxdHostThatIsNotSelectedIsLetGoOf() async throws {
    let connects = Connects()
    connects.hold(false)
    let asked = Asleep()
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in }, now: { connects.now }, presence: { _ in asked.answer() })
    let (boxd, container) = (UUID(), UUID())
    remote.adopt(
      [
        Project(
          path: "/proj", vcs: "git",
          workrooms: [
            Workroom(
              name: "b", path: "/home/boxd/r", vcsName: "workroom/b", warnings: [],
              host: HostDescriptor(
                driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner,
                id: boxd, account: "usr_1")),
            Workroom(
              name: "c", path: "/home/workroom/r", vcsName: "workroom/c", warnings: [],
              host: HostDescriptor(
                driver: RemoteWorkrooms.containerDriver, provisioner: RemoteWorkrooms.provisioner,
                id: container)),
          ])
      ], sweep: false)
    let host = HostID.remote(boxd)

    let busyKept = await remote.observed(host, busy: true)
    XCTAssertFalse(busyKept, "a busy box was let go of")
    let containerKept = await remote.observed(.remote(container), busy: false)
    XCTAssertFalse(containerKept, "a container was let go of")
    remote.select(host)
    let selectedKept = await remote.observed(host, busy: false)
    XCTAssertFalse(selectedKept, "the selected workroom's box was let go of")

    remote.select(nil)
    // Value: protects=a workroom whose pane attached keeps its status, as that pane's ssh holds the
    // box awake, while a restored pane that never attached does not; fails_when=observed() stops
    // checking panes, or counts a registration as attached; why_new=no test opens a pane; seam=none
    let session = UUID()
    let sessions = PersistentSessionService.shared
    sessions.registerRemoteSession(
      session, on: host, via: DerivingDriver(derived: boxd), workingDirectory: "/home/boxd/r")
    // A restored pane registers its session but spawns nothing until it enters a window.
    XCTAssertFalse(sessions.hasAttachedPane(on: host), "a pane that never attached holds the box")
    // An attach no pane runs (a probe, a test's own call) holds nothing.
    XCTAssertNotNil(sessions.attachCommand(forSession: session))
    XCTAssertFalse(sessions.hasAttachedPane(on: host), "an attach no pane runs holds the box")
    // Value: protects=each pane clears only its own attach, so a pane freed late cannot clear a
    // live pane's of the same session; fails_when=attaches are kept by session alone; why_new=the
    // detach tests use one pane per session; seam=none
    let (first, second) = (UUID(), UUID())
    XCTAssertNotNil(sessions.attachCommand(forSession: session, by: first))
    XCTAssertNotNil(sessions.attachCommand(forSession: session, by: second))
    sessions.paneDetached(session, by: first)
    XCTAssertTrue(sessions.hasAttachedPane(on: host), "one pane's detach cleared another's attach")
    let paneKept = await remote.observed(host, busy: false)
    sessions.forgetRemoteSession(session)
    XCTAssertFalse(paneKept, "a host with a pane attached was let go of")
    // A forgotten pane holds nothing, even if its id is registered again; nor does one whose host
    // the driver can't reach, whose pane only says why.
    sessions.registerRemoteSession(
      session, on: host, via: DerivingDriver(derived: boxd), workingDirectory: "/home/boxd/r")
    XCTAssertFalse(sessions.hasAttachedPane(on: host), "a forgotten pane still holds the box")
    sessions.forgetRemoteSession(session)
    sessions.registerRemoteSession(
      session, on: host, via: ContainerHostDriver(hosts: [:], directory: RemoteHosts.directory),
      workingDirectory: "/home/boxd/r")
    XCTAssertNotNil(sessions.attachCommand(forSession: session, by: UUID()))
    XCTAssertFalse(sessions.hasAttachedPane(on: host), "a pane that can't reach its host holds it")
    sessions.forgetRemoteSession(session)

    let letGo = await remote.observed(host, busy: false)
    XCTAssertTrue(letGo)
    XCTAssertTrue(remote.isLetGo(host))
    do {
      try await remote.ensureConnected(host)
      XCTFail("a background read reconnected a box let go of as idle")
    } catch {
      XCTAssertEqual(error as? RepositoryRoutingError, .idle(host))
    }
    XCTAssertEqual(connects.calls, 0)
    XCTAssertEqual(asked.calls, 0, "boxd was asked about a box already let go of")

    // Selecting its workroom takes it back.
    remote.select(host)
    XCTAssertFalse(remote.isLetGo(host))
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 1)
  }

  /// A click reaches a boxd host a background read would leave alone (#356): closing a pane (to
  /// end its session there) and "Keep awake" wake a box let go of as idle, or asleep, where a
  /// status read is refused.
  @MainActor
  func testAClickWakesABoxdHostABackgroundReadLeavesAlone() async throws {
    let connects = Connects()
    connects.hold(false)
    let asked = Asleep()
    asked.set(true)
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in }, now: { connects.now }, presence: { _ in asked.answer() })
    let id = UUID()
    let host = HostID.remote(id)
    remote.adopt(
      [
        Project(
          path: "/proj", vcs: "git",
          workrooms: [
            Workroom(
              name: "b", path: "/home/boxd/r", vcsName: "workroom/b", warnings: [],
              host: HostDescriptor(
                driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner,
                id: id, account: "usr_1"))
          ])
      ], sweep: false)

    // Asleep: a read is refused, a click connects.
    do {
      try await remote.ensureConnected(host)
      XCTFail("a background read woke an asleep box")
    } catch {
      XCTAssertEqual(error as? RepositoryRoutingError, .asleep(host))
    }
    try await remote.ensureConnected(host, wake: true)
    XCTAssertEqual(connects.calls, 1)

    // Let go of as idle: the same, and the click takes it back.
    asked.set(false)
    // Not within the grace after its connect, so the read that connected it is answered first.
    let tooSoon = await remote.observed(host, busy: false)
    XCTAssertFalse(tooSoon, "a host was let go of straight after its connect")
    // The grace is one poll: a reading just inside it is refused, the next poll's may let it go.
    connects.advance(RemoteHosts.letGoGrace - .seconds(1))
    let stillTooSoon = await remote.observed(host, busy: false)
    XCTAssertFalse(stillTooSoon, "a host was let go of within its grace")
    connects.advance(.seconds(1))
    let letGo = await remote.observed(host, busy: false)
    XCTAssertTrue(letGo)
    try await remote.ensureConnected(host, wake: true)
    XCTAssertEqual(connects.calls, 2)
    XCTAssertFalse(remote.isLetGo(host), "a click left the host let go of")

    // A click right after one that failed is still tried: waking a box can fail once while it
    // resumes, and the retry must not wait out the failure window.
    connects.fail(true)
    do {
      try await remote.ensureConnected(host, wake: true)
      XCTFail("the failing connect succeeded")
    } catch {}
    connects.fail(false)
    try await remote.ensureConnected(host, wake: true)
    XCTAssertEqual(connects.calls, 4, "a second click inside the window was refused")
  }

  /// A box let go of as idle is asked about again once its idle window has passed (#356): boxd
  /// sleeps a box nothing holds by then, so one still awake has work holding it, and is connected
  /// again so its ceiling prompts are heard. Inside the window boxd is not asked.
  @MainActor
  func testABoxLetGoOfIsAskedAboutAgainOnceItsIdleWindowHasPassed() async throws {
    let connects = Connects()
    connects.hold(false)
    let asked = Asleep()
    asked.set(false)
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in }, now: { connects.now }, presence: { _ in asked.answer() })
    let id = UUID()
    let host = HostID.remote(id)
    remote.adopt(
      [
        Project(
          path: "/proj", vcs: "git",
          workrooms: [
            Workroom(
              name: "b", path: "/home/boxd/r", vcsName: "workroom/b", warnings: [],
              host: HostDescriptor(
                driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner,
                id: id, account: "usr_1"))
          ])
      ], sweep: false)
    let letGo = await remote.observed(host, busy: false)
    XCTAssertTrue(letGo)

    connects.advance(remote.revisitAfter(host) - .seconds(1))
    do {
      try await remote.ensureConnected(host)
      XCTFail("a box let go of was reconnected inside its idle window")
    } catch {
      XCTAssertEqual(error as? RepositoryRoutingError, .idle(host))
    }
    XCTAssertEqual(asked.calls, 0)

    // Value: protects=a box let go of that boxd says is asleep past its idle window is not woken by a read;
    // fails_when=the revisit connects without asking boxd, or keeps asking it inside retryAfter;
    // why_new=the revisit was only tested with boxd answering awake; seam=none
    asked.set(true)
    connects.advance(.seconds(1))
    for _ in 0..<2 {
      do {
        try await remote.ensureConnected(host)
        XCTFail("a read past the idle window woke a box boxd says is asleep")
      } catch {
        XCTAssertEqual(error as? RepositoryRoutingError, .asleep(host))
      }
    }
    XCTAssertEqual(asked.calls, 1, "boxd was asked again inside retryAfter")
    XCTAssertEqual(connects.calls, 0)

    asked.set(false)
    connects.advance(RemoteHosts.retryAfter)
    try await remote.ensureConnected(host)
    XCTAssertEqual(asked.calls, 2)
    XCTAssertEqual(connects.calls, 1, "a box still awake past its idle window was left alone")
    XCTAssertFalse(remote.isLetGo(host))
  }

  /// A selected workroom's box is reached by a background read, asleep or let go of (#356): after
  /// the Mac sleeps, the open workroom must not read as asleep until it is selected again.
  @MainActor
  func testASelectedWorkroomsBoxIsReachedEvenAsleep() async throws {
    let connects = Connects()
    connects.hold(false)
    let asked = Asleep()
    asked.set(true)
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in }, now: { connects.now }, presence: { _ in asked.answer() })
    let id = UUID()
    let host = HostID.remote(id)
    remote.adopt(
      [
        Project(
          path: "/proj", vcs: "git",
          workrooms: [
            Workroom(
              name: "b", path: "/home/boxd/r", vcsName: "workroom/b", warnings: [],
              host: HostDescriptor(
                driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner,
                id: id, account: "usr_1"))
          ])
      ], sweep: false)
    remote.select(host, in: "window")
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 1)
    XCTAssertEqual(asked.calls, 0, "boxd was asked about the selected workroom's box")
  }

  /// Each window has its own selection (one AppStore per window): a host selected in any window
  /// is kept, whatever another window selects, and a closed window lets it go (#356).
  @MainActor
  func testAHostSelectedInAnyWindowIsKept() async throws {
    let remote = RemoteHosts()
    let id = UUID()
    let host = HostID.remote(id)
    remote.adopt(
      [
        Project(
          path: "/proj", vcs: "git",
          workrooms: [
            Workroom(
              name: "b", path: "/home/boxd/r", vcsName: "workroom/b", warnings: [],
              host: HostDescriptor(
                driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner,
                id: id, account: "usr_1"))
          ])
      ], sweep: false)
    remote.select(host, in: "window A")
    remote.select(nil, in: "window B")
    let keptAcrossWindows = await remote.observed(host, busy: false)
    XCTAssertFalse(keptAcrossWindows, "another window's selection let go of window A's host")
    remote.select(nil, in: "window A")
    let letGoOnceUnselected = await remote.observed(host, busy: false)
    XCTAssertTrue(letGoOnceUnselected)
  }

  private final class Asleep: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BoxdHostDriver.Presence?
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func set(_ asleep: Bool?) { lock.withLock { value = asleep.map { $0 ? .asleep : .awake } } }
    func setGone() { lock.withLock { value = .gone } }
    func answer() -> BoxdHostDriver.Presence? {
      lock.withLock {
        count += 1
        return value
      }
    }
  }

  /// Only a host whose workroom the user opened has its container started before connecting: the
  /// status sweep connects to every remote workroom, and must not start them all (#309).
  func testOnlyAnOpenedHostIsStartedBeforeItsConnect() async throws {
    let connects = Connects()
    connects.hold(false)
    let started = Swept()
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { host in
        guard case .remote(let id) = host else { return }
        started.add(nil, [id])
      })
    let (probed, opened) = (UUID(), UUID())

    try await remote.ensureConnected(.remote(probed))
    XCTAssertTrue(started.calls.isEmpty, "a probe of an unopened host started it")

    remote.activate(.remote(opened))
    try await remote.ensureConnected(.remote(opened))
    XCTAssertEqual(started.calls.map(\.known), [[opened]])
    XCTAssertEqual(connects.calls, 2)
  }

  /// Opening a workroom whose host just failed a probe tries it again at once, starting it: the
  /// probe's failure was the container being stopped, which opening is about to fix.
  func testOpeningAHostLiftsItsRetryWindow() async throws {
    let connects = Connects()
    connects.hold(false)
    connects.fail(true)
    let remote = hosts(connects)
    let host = HostID.remote(UUID())
    do { try await remote.ensureConnected(host) } catch {}
    connects.fail(false)
    remote.activate(host)
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 2)
  }

  /// Opening a workroom while a status probe of its stopped container is under way starts it: joined,
  /// the probe would fail and hold the workroom back for `retryAfter`.
  func testOpeningDuringAProbeStartsTheHost() async throws {
    let connects = Connects()
    connects.fail(true)
    let started = Swept()
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) },
      isConnected: { _ in
        connects.ask()
        return false
      },
      startHost: { host in
        guard case .remote(let id) = host else { return }
        started.add(nil, [id])
        connects.fail(false)
      }, now: { connects.now })
    let id = UUID()

    let probe = Task { try await remote.ensureConnected(.remote(id)) }
    while connects.calls < 1 { try await Task.sleep(for: .milliseconds(1)) }
    remote.activate(.remote(id))
    let opened = Task { try await remote.ensureConnected(.remote(id)) }
    while connects.arrived < 2 { try await Task.sleep(for: .milliseconds(1)) }
    try await Task.sleep(for: .milliseconds(20))
    connects.hold(false)
    _ = try? await probe.value
    try await opened.value
    XCTAssertEqual(started.calls.map(\.known), [[id]], "the opened workroom's host wasn't started")
  }

  /// Opening starts a container once: one the user stops afterwards is not started again by the
  /// status sweep's next probe.
  func testOpeningStartsTheHostOnce() async throws {
    let connects = Connects()
    connects.hold(false)
    let started = Swept()
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { host in
        guard case .remote(let id) = host else { return }
        started.add(nil, [id])
      })
    let id = UUID()
    remote.activate(.remote(id))
    try await remote.ensureConnected(.remote(id))
    try await remote.ensureConnected(.remote(id))
    XCTAssertEqual(started.calls.count, 1, "a later probe started the container again")
    remote.activate(.remote(id))
    try await remote.ensureConnected(.remote(id))
    XCTAssertEqual(started.calls.count, 2, "opening it again didn't start it")
  }

  /// An opening whose start fails is spent too: the status sweep's later probes neither start the
  /// container again nor skip its backoff.
  func testAFailedOpeningIsSpent() async throws {
    let connects = Connects()
    connects.hold(false)
    let starts = Connects()
    starts.hold(false)
    starts.fail(true)
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { try await starts.connect($0) }, now: { connects.now })
    let host = HostID.remote(UUID())
    remote.activate(host)
    do { try await remote.ensureConnected(host) } catch {}
    XCTAssertEqual(starts.calls, 1)
    do { try await remote.ensureConnected(host) } catch {}
    XCTAssertEqual(starts.calls, 1, "a probe started the container again")
    XCTAssertEqual(connects.calls, 0, "a probe skipped the backoff")
  }

  /// A workroom opened while its container runs has nothing to start, and the opening is spent:
  /// stopped later, the status sweep's probe doesn't start it.
  func testOpeningARunningHostLeavesItStoppedLater() async throws {
    let connects = Connects()
    connects.hold(false)
    let running = Connects()
    let started = Swept()
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) },
      isConnected: { _ in
        // Up the first time it's asked, stopped after.
        defer { running.ask() }
        return running.arrived == 0
      },
      startHost: { host in
        guard case .remote(let id) = host else { return }
        started.add(nil, [id])
      })
    let id = UUID()
    remote.activate(.remote(id))
    try await remote.ensureConnected(.remote(id))
    try await remote.ensureConnected(.remote(id))
    XCTAssertTrue(started.calls.isEmpty, "a probe started a container opened while it ran")
  }

  /// A probe of the stopped container that fails after the workroom was opened doesn't hold it back:
  /// the opened workroom's next connect starts it at once.
  func testAProbeFailingAfterTheOpeningDoesNotHoldItBack() async throws {
    let connects = Connects()
    connects.fail(true)
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in connects.fail(false) }, now: { connects.now })
    let host = HostID.remote(UUID())
    let probe = Task { try await remote.ensureConnected(host) }
    while connects.calls < 1 { try await Task.sleep(for: .milliseconds(1)) }
    remote.activate(host)
    connects.hold(false)
    _ = try? await probe.value
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 2)
  }

  /// A relay that didn't take on a connection is tried again by a later connection check, at most
  /// once a `retryAfter`, until it does; nothing else would try before a reconnect.
  func testARelayThatDidNotTakeIsTriedAgain() async throws {
    let connects = Connects()
    connects.fail(true)
    let relays = Connects()
    relays.hold(false)
    relays.fail(true)
    let remote = RemoteHosts(
      connectHost: { _ in }, isConnected: { _ in true }, startHost: { _ in },
      now: { connects.now }, relayHost: { try await relays.connect($0) })
    let host = HostID.remote(UUID())

    await remote.installRelay(host, attempts: 1)
    XCTAssertEqual(relays.calls, 1)
    try await remote.ensureConnected(host)
    XCTAssertEqual(relays.calls, 1, "tried again inside its window")

    relays.fail(false)
    connects.advance(RemoteHosts.retryAfter)
    try await remote.ensureConnected(host)
    XCTAssertEqual(relays.calls, 2, "a later check didn't try again")
    connects.advance(RemoteHosts.retryAfter)
    try await remote.ensureConnected(host)
    XCTAssertEqual(relays.calls, 2, "tried again once it had taken")
  }

  /// `destroy` removes a host's image with `--force`, so a record's image must be a commit's ID.
  func testOnlyAWholeLowercaseSHA256IsAnImageID() {
    let hex = String(repeating: "a1", count: 32)
    XCTAssertTrue(ContainerHostDriver.isImageID("sha256:" + hex))
    for bad in [
      "", "debian:bookworm", hex, "sha256:" + hex.uppercased(), "sha256:" + hex.dropLast(),
      "sha256:" + hex + "a", "sha256:" + String(repeating: "g", count: 64),
    ] {
      XCTAssertFalse(ContainerHostDriver.isImageID(bad), bad)
    }
  }

  /// A project whose origin changed since its base was cloned is refused before anything is made:
  /// reusing the base would give it workrooms of the old repository, with credentials for that.
  func testABaseOfAnotherRepositoryIsNotReused() async throws {
    let driver = ContainerHostDriver(hosts: [:], directory: FileManager.default.temporaryDirectory)
    let environment = RemoteProvisioning.Environment(
      driver: driver, agentSocket: RemoteWorkrooms.agentSocket,
      client: BrokerClient(
        baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey())))
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { _, _ in
        XCTFail("a name was taken")
        return "x"
      },
      record: { _, _ in XCTFail("something was recorded") },
      forget: { _ in XCTFail("something was forgotten") })

    do {
      _ = try await RemoteWorkrooms.create(
        repository: try XCTUnwrap(GitHubRepository(host: "github.com", owner: "fork", name: "r")),
        cloneURL: "https://github.com/fork/r.git",
        base: HostDescriptor(
          provisioner: RemoteWorkrooms.provisioner, id: UUID(), repository: "upstream/r",
          cloneURL: "https://github.com/upstream/r.git", path: "/home/workroom/r"),
        driver: driver, environment: environment, recorder: recorder)
      XCTFail("a base of another repository was reused")
    } catch RemoteWorkrooms.Failure.baseRepositoryChanged(let base, let origin) {
      XCTAssertEqual(base, "upstream/r")
      XCTAssertEqual(origin, "fork/r")
    }
  }

  /// A keygen cut short leaves the private half alone: the public half is derived from it again,
  /// rather than every later create failing to read it. A private half that isn't a key says so.
  func testAMissingPublicKeyIsDerivedFromThePrivateOne() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-key-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = try RemoteHosts.clientKey(in: directory)
    let pub = key.appendingPathExtension("pub")
    let original = try String(contentsOf: pub, encoding: .utf8)
    XCTAssertTrue(original.hasPrefix("ssh-ed25519 "), original)

    try FileManager.default.removeItem(at: pub)
    XCTAssertEqual(try RemoteHosts.clientKey(in: directory), key)
    // `-y` prints no comment, so compare the key itself.
    XCTAssertEqual(
      try String(contentsOf: pub, encoding: .utf8).split(separator: " ").prefix(2),
      original.split(separator: " ").prefix(2))

    try FileManager.default.removeItem(at: pub)
    try Data("not a key".utf8).write(to: key)
    XCTAssertThrowsError(try RemoteHosts.clientKey(in: directory))
  }

  /// The launch's one sweep waits out a delete (#296): a call that isn't allowed leaves it for the
  /// next, and only one call ever runs it.
  func testTheSweepIsHeldUntilAllowedThenRunsOnce() {
    let remote = RemoteHosts()
    XCTAssertFalse(remote.sweepHeld, "nothing has reached the sweep, so nothing is owed")
    XCTAssertFalse(remote.claimSweep(allowed: false))
    XCTAssertTrue(remote.sweepHeld, "a held sweep is still owed")
    XCTAssertTrue(remote.claimSweep(allowed: true))
    XCTAssertFalse(remote.sweepHeld)
    XCTAssertFalse(remote.claimSweep(allowed: true))
  }

  /// A container workroom's create is off while its project is busy: a second create would build a second
  /// base.
  @MainActor
  func testARemoteCreateIsOffWhileItsProjectIsBusy() {
    RemoteWorkrooms.enabledForTesting = true
    defer { RemoteWorkrooms.enabledForTesting = nil }
    let store = AppStore()
    let project = Project(path: "/proj", vcs: "git", workrooms: [])
    XCTAssertTrue(store.canCreateRemoteWorkroom(in: project))
    store.busyProjects["/proj"] = 1
    XCTAssertFalse(store.canCreateRemoteWorkroom(in: project))
  }

  /// A workroom on a host, a container or a remote provider, wears the network glyph on its tab and
  /// pane in place of the cube, with what kind of host it is as the tooltip; one on this Mac keeps
  /// the cube (#309).
  func testAWorkroomOnAHostWearsTheNetworkGlyph() {
    let local = Workroom(name: "w", path: "/tmp/w", vcsName: "workroom/w", warnings: [])
      .target(inProject: "/proj")
    XCTAssertEqual(local.workroomGlyph, "cube")
    XCTAssertNil(local.hostKind)
    let docker = Workroom(
      name: "d", path: "/home/workroom/r", vcsName: "workroom/d", warnings: [],
      host: HostDescriptor(
        driver: "container", provisioner: RemoteWorkrooms.provisioner, id: UUID(),
        container: Self.record(context: "orbstack"))
    ).target(inProject: "/proj")
    XCTAssertEqual(docker.workroomGlyph, "network")
    XCTAssertEqual(docker.hostKind, "Docker container (orbstack) on this Mac")
    let destroyed = Workroom(
      name: "x", path: "/home/workroom/r", vcsName: "workroom/x", warnings: [],
      host: HostDescriptor(state: "destroyed", driver: "apple-container")
    ).target(inProject: "/proj")
    XCTAssertEqual(destroyed.workroomGlyph, "network")
  }

  /// A workroom's icon says what kind of host it is on (#309).
  func testAHostSaysWhatKindItIs() {
    let host = { (driver: String?, context: String?) in
      HostDescriptor(driver: driver, container: Self.record(context: context))
    }
    XCTAssertEqual(host("container", nil).kindDescription, "Docker container on this Mac")
    XCTAssertEqual(
      host("container", "orbstack").kindDescription, "Docker container (orbstack) on this Mac")
    XCTAssertEqual(host("apple-container", nil).kindDescription, "Apple container on this Mac")
    XCTAssertEqual(host("boxd", nil).kindDescription, "Remote workroom on boxd")
    XCTAssertEqual(host(nil, nil).kindDescription, "Remote workroom")
  }

  /// The New Workroom menu says why its entries are off while a create holds the project, or a
  /// delete is taking it (#309).
  @MainActor
  func testACreateBlockedProjectSaysWhy() {
    let store = AppStore()
    let project = Project(path: "/proj", vcs: "git", workrooms: [])
    XCTAssertNil(store.createBlockedReason(in: project))
    store.busyProjects["/proj"] = 1
    XCTAssertEqual(store.createBlockedReason(in: project), "a workroom is already being created")
    store.deletingProjects.insert("/proj")
    XCTAssertEqual(store.createBlockedReason(in: project), "the project is being deleted")
  }

  /// No watcher refreshes a remote tree, so coming back to it reads it again; the same local path
  /// would be a no-op.
  @MainActor
  func testReactivatingARemoteTreeListsItAgain() async throws {
    RemoteWorkrooms.enabledForTesting = true
    defer { RemoteWorkrooms.enabledForTesting = nil }
    let lists = Connects()
    lists.fail(true)
    lists.hold(false)
    // Counts each listing at the connect it starts with, and connects nothing.
    let router = RepositoryRouter(connectRemote: { try await lists.connect($0) })
    let model = FileTreeModel(router: router)
    let target = Workroom(
      name: "r", path: "/home/workroom/r", vcsName: "workroom/r", warnings: [],
      host: HostDescriptor(provisioner: RemoteWorkrooms.provisioner, id: UUID())
    ).target(inProject: "/proj")

    for expected in 1...2 {
      model.activate(target: target)
      for _ in 0..<500 where lists.calls < expected { try await Task.sleep(for: .milliseconds(2)) }
      XCTAssertEqual(lists.calls, expected)
    }
  }

  /// A remote workroom this app can't reach (previews off, here) reads nothing on this Mac: its
  /// path names a directory on its host, not here.
  @MainActor
  func testAnUnreachableRemoteWorkroomReadsNothingHere() {
    RemoteWorkrooms.enabledForTesting = false
    defer { RemoteWorkrooms.enabledForTesting = nil }
    let target = Workroom(
      name: "r", path: NSTemporaryDirectory(), vcsName: "workroom/r", warnings: [],
      host: HostDescriptor(provisioner: RemoteWorkrooms.provisioner, id: UUID())
    ).target(inProject: "/proj")
    XCTAssertNil(target.remoteHost)

    let history = HistoryModel()
    history.focus(target: target)
    XCTAssertNil(history.root, "History read the remote path on this Mac")
    XCTAssertEqual(history.state, .idle)

    let files = FileTreeModel(router: RepositoryRouter())
    files.activate(target: target)
    XCTAssertEqual(files.state, .idle, "Files listed the remote path on this Mac")
  }

  // MARK: Docker contexts (#309)

  /// A stand-in runtime CLI: a script that appends its arguments to `log`, one call per line, and
  /// prints `output`.
  private func stubRuntime(output: String = "") throws -> (runtime: URL, log: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "wr-runtime-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let runtime = directory.appendingPathComponent("docker")
    let log = directory.appendingPathComponent("calls")
    try """
    #!/bin/sh
    printf '%s\\n' "$*" >> \(ContainerHostDriver.shellQuoted(log.path))
    printf '%s' \(ContainerHostDriver.shellQuoted(output))
    """.write(to: runtime, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
    return (runtime, log)
  }

  /// A stand-in runtime CLI that logs every call and fails `image inspect` (the image is missing),
  /// `run`, and `pull` when `pullFails`, so `create` stops at its first container.
  private func failingRuntime(pullFails: Bool, said: String = "denied") throws -> (
    runtime: URL, log: URL
  ) {
    let (runtime, log) = try stubRuntime()
    let script = try String(contentsOf: runtime, encoding: .utf8)
    try
      (script + """

        case "$1 $2" in "image inspect") exit 1 ;; esac
        case "$1" in run) exit 1 ;; pull) \(pullFails ? "echo '\(said)' >&2; exit 1" : "exit 0") ;; esac
        """).write(to: runtime, atomically: true, encoding: .utf8)
    return (runtime, log)
  }

  /// A missing host image is pulled, by itself, before the base's container runs, and `run` never
  /// pulls: left to it, a missing image was looked for on Docker Hub (#309).
  func testAMissingHostImageIsPulledBeforeRunAndRunNeverPulls() async throws {
    let (runtime, log) = try failingRuntime(pullFails: false)
    do {
      _ = try await Self.driver(runtime: runtime, context: nil).create()
      XCTFail("run was meant to fail")
    } catch {}
    let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
      $0.split(separator: " ").prefix(2).joined(separator: " ")
    }
    XCTAssertEqual(
      Array(calls.prefix(3)), ["image inspect", "pull workroom-host", "run --pull=never"])
  }

  private final class Fractions: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [Double?] = []
    var all: [Double?] { lock.withLock { heard } }
    func add(_ fraction: Double?) { lock.withLock { heard.append(fraction) } }
  }

  /// A pull's progress reaches the create that asked for it as it goes, rising to the whole, then
  /// says it is done (#309). How many steps arrive between depends on how the pipe's reads fall, so
  /// only their order and ends are pinned (`ImagePullProgressTests` pins the parsing).
  func testAPullsProgressReachesItsCreate() async throws {
    let (runtime, _) = try scriptedRuntime(
      """
      "image inspect --format {{.Id}} workroom-host") exit 1 ;;
      "pull workroom-host")
        printf 'aaaaaaaaaaaa: Pulling fs layer\nbbbbbbbbbbbb: Pulling fs layer\n'
        sleep 0.2; printf 'aaaaaaaaaaaa: Pull complete\n'
        sleep 0.2; printf 'bbbbbbbbbbbb: Pull complete\n' ;;
      run*) exit 1 ;;
      """)
    let heard = Fractions()
    let report: @Sendable (Double?) -> Void = { heard.add($0) }
    // The scripted `run` fails, after the pull.
    try? await ContainerHostDriver.$pullProgress.withValue(report) {
      _ = try await Self.driver(runtime: runtime, context: nil).create()
    }
    let all = heard.all
    XCTAssertEqual(all.last, .some(nil), "the pull never said it was done: \(all)")
    let fractions = all.dropLast().compactMap { $0 }
    XCTAssertEqual(fractions.count, all.count - 1, "done before the end: \(all)")
    XCTAssertEqual(fractions.last, 1, "\(all)")
    XCTAssertEqual(fractions, fractions.sorted(), "\(all)")
    XCTAssertTrue(fractions.allSatisfy { (0...1).contains($0) }, "\(all)")
  }

  /// A pull that fails says why, by cause, and runs nothing: a registry that refused the image, a
  /// runtime that isn't running, or else the network.
  func testAFailedPullSaysWhy() async throws {
    for (said, expected) in [
      ("denied", "the registry refused the workroom host image"),
      (
        "Cannot connect to the Docker daemon at unix:///x. Is the docker daemon running?",
        "Docker didn't answer"
      ),
      (
        "Got permission denied while trying to connect to the Docker daemon socket at unix:///x",
        "Docker didn't answer"
      ),
      ("manifest unknown", "the registry refused the workroom host image"),
      ("read: connection reset by peer", "couldn't download the workroom host image"),
    ] {
      let (runtime, log) = try failingRuntime(pullFails: true, said: said)
      do {
        _ = try await Self.driver(runtime: runtime, context: nil).create()
        XCTFail("a failed pull created a host")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
      }
      XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains("run "))
    }
  }

  /// A runtime that isn't running says so at its first command, rather than pulling: its inspect
  /// failing is not a missing image.
  func testARuntimeThatIsNotRunningSaysSo() async throws {
    for (dialect, said, expected) in [
      (
        ContainerHostDriver.Dialect.docker,
        "Cannot connect to the Docker daemon at unix:///x. Is the docker daemon running?",
        "Docker didn't answer"
      ),
      (
        .apple,
        "Error: interrupted: \"XPC connection error: Connection invalid\"\nEnsure container "
          + "system service has been started with `container system start`.",
        "container system start"
      ),
    ] {
      let (runtime, log) = try stubRuntime()
      let script = try String(contentsOf: runtime, encoding: .utf8)
      try (script + "\nprintf '%s\\n' \(ContainerHostDriver.shellQuoted(said)) >&2; exit 1\n")
        .write(to: runtime, atomically: true, encoding: .utf8)
      do {
        _ = try await Self.driver(runtime: runtime, context: nil, dialect: dialect).create()
        XCTFail("created without a runtime")
      } catch {
        XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
      }
      XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains("pull"), "it pulled")
    }
  }

  /// The image a new base runs: the hidden override, else the build's pinned digest, else a local
  /// `workroom-host`. Empty values, as an unset build setting leaves `WorkroomHostImage`, don't count.
  func testTheHostImageIsTheOverrideThenThePinThenLocal() {
    let pinned = "ghcr.io/joelmoss/workroom-host@sha256:" + String(repeating: "a", count: 64)
    XCTAssertEqual(RemoteWorkrooms.hostImage(override: "mine", pinned: pinned), "mine")
    XCTAssertEqual(RemoteWorkrooms.hostImage(override: nil, pinned: pinned), pinned)
    XCTAssertEqual(RemoteWorkrooms.hostImage(override: " ", pinned: ""), "workroom-host")
    XCTAssertEqual(RemoteWorkrooms.hostImage(override: nil, pinned: nil), "workroom-host")
  }

  private static func driver(
    runtime: URL, context: String?, dialect: ContainerHostDriver.Dialect = .docker
  ) -> ContainerHostDriver {
    ContainerHostDriver(
      hosts: [:], directory: FileManager.default.temporaryDirectory,
      provisioning: ContainerHostDriver.Provisioning(
        runtime: runtime, image: "workroom-host", user: RemoteWorkrooms.user,
        identityFile: "/dev/null", publicKey: "ssh-ed25519 AAAA",
        agentSocket: RemoteWorkrooms.agentSocket, labels: ["workroom.provisioner=test"],
        context: context, dialect: dialect))
  }

  private static func record(context: String?) -> ContainerHostDriver.Record {
    ContainerHostDriver.Record(
      address: "127.0.0.1", port: 2222, user: RemoteWorkrooms.user, hostKey: "ssh-ed25519 AAAA",
      image: nil, context: context)
  }

  // Value: protects=a boxd box with a provider idle timer shorter than the heartbeat is flagged on its badge;
  // fails_when=connect stops reading the machine's idle timers into its wakefulness model, or reads them wrongly;
  // why_new=idleWindow parsing and the badge copy are unit-tested but nothing sets the model on connect; seam=none
  /// Connecting a boxd host reads its idle timers into its wakefulness model (#356), so the badge
  /// can say a 60 s timer sleeps the box under a job the once-a-minute heartbeat cannot hold.
  @MainActor
  func testConnectingABoxdHostGivesItsBadgeTheMachinesIdleWindow() async throws {
    let fake = try FakeAgent(version: 4, status: true)
    defer { fake.stop() }
    let id = UUID()
    let host = HostID.remote(id)
    defer { WakefulnessModel.forgetHost(id) }
    let remote = RemoteHosts(connectAgent: { host, _ in
      try await AgentVCSConnection.connect(host: host, socketPath: fake.socketPath)
    })
    let driver = BoxdHostDriver(
      configuration: .init(cli: URL(fileURLWithPath: "/nonexistent/boxd")),
      directory: FileManager.default.temporaryDirectory,
      runner: MachineGet(#"{"source":"standalone","auto_suspend":60}"#))

    try await remote.connect(host, driver: driver)
    let snapshot = await HostConnectionManager.shared.snapshot(for: host)
    let lease = try XCTUnwrap(snapshot.lease)
    addTeardownBlock { await HostConnectionManager.shared.disconnect(lease) }

    let model = try XCTUnwrap(WakefulnessModel.Hosts.shared.models[id])
    XCTAssertTrue(model.hostSleeps)
    let deadline = ContinuousClock.now + .seconds(5)
    while model.idleWindow == nil, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(model.idleWindow, 60)
    // Value: protects=a connected boxd box is polled off screen, revisited by its own idle window, and a deleted one stops polling;
    // fails_when=connect stops starting the poll or recording the window, or forgetHost leaves the poll running;
    // why_new=the poll test starts it by hand and the revisit test only reaches the unknown-window fallback; seam=none
    XCTAssertTrue(model.isPollingWhileConnected, "a connected boxd host isn't polled")
    XCTAssertEqual(remote.revisitAfter(host), .seconds(60) + RemoteHosts.retryAfter)

    // Value: protects=a reconnect whose idle-window read fails keeps the window last read, while
    // one that finds no timer set clears it; fails_when=connect treats a failed read as "no
    // timer", or "no timer" as a failure; why_new=only a successful read is connected here;
    // seam=none
    let reconnect = { (runner: MachineGet) in
      if let current = await HostConnectionManager.shared.snapshot(for: host).lease {
        await HostConnectionManager.shared.disconnect(current)
      }
      try await remote.connect(
        host,
        driver: BoxdHostDriver(
          configuration: .init(cli: URL(fileURLWithPath: "/nonexistent/boxd")),
          directory: FileManager.default.temporaryDirectory, runner: runner))
    }
    let failing = MachineGet("", fails: true)
    try await reconnect(failing)
    let asked = ContinuousClock.now + .seconds(5)
    while failing.answered.calls == 0, ContinuousClock.now < asked {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(failing.answered.calls, 1, "the reconnect never read the idle window")
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(remote.revisitAfter(host), .seconds(60) + RemoteHosts.retryAfter)
    XCTAssertEqual(model.idleWindow, 60, "a failed read forgot the badge's idle window")

    try await reconnect(MachineGet(#"{"source":"standalone"}"#))
    let cleared = ContinuousClock.now + .seconds(5)
    while model.idleWindow != nil, ContinuousClock.now < cleared {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(model.idleWindow, "turning the timers off left the badge's idle window")
    XCTAssertEqual(
      remote.revisitAfter(host), .seconds(RemoteHosts.unknownIdleWindow) + RemoteHosts.retryAfter)
    if let last = await HostConnectionManager.shared.snapshot(for: host).lease {
      addTeardownBlock { await HostConnectionManager.shared.disconnect(last) }
    }
    WakefulnessModel.forgetHost(id)
    XCTAssertFalse(model.isPollingWhileConnected, "a forgotten host is still polled")
  }

  // Value: protects=a boxd workroom deleted while its connect reads the idle timers stays deleted;
  // fails_when=the late read looks the host's model up with the accessor that makes one;
  // why_new=the idle-window test never deletes across the read; seam=none
  /// A delete that lands while the connect is still reading the machine's idle timers forgets the
  /// host's model, and the late answer does not make it anew, watching for prompts for good (#356).
  @MainActor
  func testADeleteAcrossTheIdleWindowReadDoesNotBringTheHostsModelBack() async throws {
    let fake = try FakeAgent(version: 4, status: true)
    defer { fake.stop() }
    let id = UUID()
    let host = HostID.remote(id)
    defer { WakefulnessModel.forgetHost(id) }
    let remote = RemoteHosts(connectAgent: { host, _ in
      try await AgentVCSConnection.connect(host: host, socketPath: fake.socketPath)
    })
    let (opened, open) = AsyncStream<Void>.makeStream()
    let read = MachineGet(#"{"source":"standalone","auto_suspend":60}"#, until: opened)
    try await remote.connect(
      host,
      driver: BoxdHostDriver(
        configuration: .init(cli: URL(fileURLWithPath: "/nonexistent/boxd")),
        directory: FileManager.default.temporaryDirectory, runner: read))
    if let lease = await HostConnectionManager.shared.snapshot(for: host).lease {
      addTeardownBlock { await HostConnectionManager.shared.disconnect(lease) }
    }
    XCTAssertNotNil(WakefulnessModel.Hosts.shared.models[id])

    WakefulnessModel.forgetHost(id)
    open.yield()
    open.finish()
    // The window is recorded just before the hop that would give it to a model.
    let deadline = ContinuousClock.now + .seconds(5)
    while remote.revisitAfter(host) != .seconds(60) + RemoteHosts.retryAfter,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(read.answered.calls, 1, "the connect never read the idle window")
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertNil(
      WakefulnessModel.Hosts.shared.models[id], "a late read brought a deleted host back")
  }

  // Value: protects=a boxd host carrying a port forward stays connected when idle, so the user's dev server still answers;
  // fails_when=observed() lets go of an idle boxd host without asking PortForwardingModel.hasForwards;
  // why_new=pass-1 covers the idle release, not its one exception; no test pairs a live forward with observed; seam=none
  /// An idle boxd host is let go of (#356) unless it is carrying a forward: closing its connection
  /// would close the listener the user's browser is pointed at.
  @MainActor
  func testAnIdleBoxdHostWithAPortForwardIsKept() async throws {
    let fake = try FakeAgent(version: 5, forward: true)
    defer { fake.stop() }
    let id = UUID()
    let host = HostID.remote(id)
    let clock = Connects()
    let remote = RemoteHosts(
      now: { clock.now },
      connectAgent: { host, _ in
        try await AgentVCSConnection.connect(host: host, socketPath: fake.socketPath)
      })
    remote.adopt(
      [
        Project(
          path: "/proj", vcs: "git",
          workrooms: [
            Workroom(
              name: "w", path: "/home/boxd/r", vcsName: "workroom/w", warnings: [],
              host: HostDescriptor(
                driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner,
                id: id, org: "acme", account: "usr_1"))
          ])
      ], sweep: false)
    let driver = BoxdHostDriver(
      configuration: .init(cli: URL(fileURLWithPath: "/nonexistent/boxd")),
      directory: FileManager.default.temporaryDirectory,
      runner: MachineGet(#"{"source":"standalone","auto_suspend":60}"#))
    try await remote.connect(host, driver: driver)
    let snapshot = await HostConnectionManager.shared.snapshot(for: host)
    let lease = try XCTUnwrap(snapshot.lease)
    addTeardownBlock { await HostConnectionManager.shared.disconnect(lease) }
    defer { WakefulnessModel.forgetHost(id) }
    let forwards = PortForwardingModel.model(for: host)
    forwards.draft = "8080"
    await forwards.add()
    let forward = try XCTUnwrap(forwards.forwards.first, forwards.message ?? "no forward was made")
    clock.advance(RemoteHosts.letGoGrace)

    let whileForwarding = await remote.observed(host, busy: false)

    XCTAssertFalse(whileForwarding, "an idle host carrying a forward was let go of")
    XCTAssertFalse(remote.isLetGo(host))
    forwards.remove(forward.id)
    // Value: protects=a boxd host let go of as idle stops being polled, so the poll can't hold it awake;
    // fails_when=observed() closes the connection but leaves the connection poll running;
    // why_new=no test lets go of a host whose connect started the poll; seam=none
    let model = try XCTUnwrap(WakefulnessModel.Hosts.shared.models[id])
    XCTAssertTrue(model.isPollingWhileConnected)
    let afterwards = await remote.observed(host, busy: false)
    XCTAssertTrue(afterwards, "the host was never eligible, so the forward proved nothing")
    XCTAssertFalse(model.isPollingWhileConnected, "a host let go of is still polled")
  }

  /// A boxd CLI that answers every `machine get` with `json`.
  private struct MachineGet: StatusCommandRunning {
    let json: String
    var fails = false
    /// How many times it has answered, so a test can wait for a read it can't otherwise see.
    let answered = Asleep()
    /// Holds each answer back until it yields, for a test that acts across a read.
    let until: AsyncStream<Void>?
    init(_ json: String, fails: Bool = false, until: AsyncStream<Void>? = nil) {
      self.json = json
      self.fails = fails
      self.until = until
    }
    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      if let until { for await _ in until { break } }
      _ = answered.answer()
      return fails
        ? CommandResult(stdout: "", stderr: "error: unreachable", exitCode: 1, timedOut: false)
        : CommandResult(stdout: json, stderr: "", exitCode: 0, timedOut: false)
    }
  }

  /// A host's ceiling prompts are watched from its connect (#257): the connect hands its agent this
  /// Mac's ask-at-ceiling setting, so a prompt that reached no card would let the box sleep under a
  /// running job. The model is made, watching, and a prompt the agent raises shows on it.
  @MainActor
  func testConnectingAHostWatchesForItsCeilingPrompts() async throws {
    let fake = try FakeAgent(version: 4, status: true)
    defer { fake.stop() }
    let id = UUID()
    let host = HostID.remote(id)
    defer { WakefulnessModel.forgetHost(id) }
    XCTAssertNil(WakefulnessModel.Hosts.shared.models[id])
    let remote = RemoteHosts(connectAgent: { host, _ in
      try await AgentVCSConnection.connect(host: host, socketPath: fake.socketPath)
    })
    try await remote.connect(
      host, driver: Self.driver(runtime: URL(fileURLWithPath: "/usr/bin/false"), context: nil))
    let snapshot = await HostConnectionManager.shared.snapshot(for: host)
    let lease = try XCTUnwrap(snapshot.lease)
    addTeardownBlock { await HostConnectionManager.shared.disconnect(lease) }

    let model = try XCTUnwrap(WakefulnessModel.Hosts.shared.models[id])
    XCTAssertTrue(model.isWatchingPrompts)
    XCTAssertFalse(model.hostSleeps, "a container is never slept, so its badge never says so")
    // The watch subscribes with a `status`; then a prompt the agent pushes is the host's card.
    let deadline = ContinuousClock.now + .seconds(5)
    while fake.receivedStatusRequests.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(fake.receivedStatusRequests.isEmpty, "the watch never subscribed")
    fake.pushCeilingPrompt()
    while !model.prompt.isShowing, ContinuousClock.now < deadline + .seconds(5) {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(model.prompt.isShowing, "the host's prompt never reached its model")
    // And the toast stack, which takes clicks only while a card it knows of is up, knows of it.
    XCTAssertTrue(WakefulnessModel.Hosts.shared.showing.contains(id))
    XCTAssertFalse(WakefulnessModel.shared.prompt.isShowing, "not this Mac's card")
  }

  /// A record written before #309 has no context: it reads as nil, which names no context on any
  /// command, as every command did then. A pinned one keeps its context through config.
  func testARecordWithoutAContextReadsAsTheUnpinnedOne() throws {
    let old = Data(
      #"{"address":"127.0.0.1","port":2222,"user":"workroom","host_key":"ssh-ed25519 AAAA"}"#.utf8)
    let decoded = try JSONDecoder().decode(ContainerHostDriver.Record.self, from: old)
    XCTAssertNil(decoded.context)
    XCTAssertEqual(decoded, Self.record(context: nil))

    // Written back with no `context` key at all, so an old record's bytes don't change.
    let written = try JSONSerialization.jsonObject(
      with: try JSONEncoder().encode(Self.record(context: nil)))
    XCTAssertNil((written as? [String: Any])?["context"])

    let pinned = Self.record(context: "orbstack")
    XCTAssertEqual(
      try JSONDecoder().decode(
        ContainerHostDriver.Record.self, from: try JSONEncoder().encode(pinned)), pinned)
  }

  /// Every runtime command names a pinned context, ahead of the command (Docker refuses it after),
  /// and an unpinned driver's commands are exactly what they were before #309.
  func testRuntimeCommandsNameTheContextAheadOfTheCommand() async throws {
    for context in [nil, "orbstack"] as [String?] {
      let (runtime, log) = try stubRuntime()
      _ = await Self.driver(runtime: runtime, context: context).sweep(keeping: [])
      let calls = try self.calls(log)
      let prefix = context.map { "--context \($0) " } ?? ""
      XCTAssertEqual(
        calls,
        [
          "\(prefix)ps -a --filter label=workroom.provisioner=test --format "
            + "{{.Names}}\t{{.Label \"workroom.created\"}}",
          "\(prefix)images -aq --filter label=workroom.provisioner=test",
        ], "context \(context ?? "nil")")
    }
  }

  /// A new Docker workroom wants the context the CLI uses now, except `default`, which is whatever
  /// `DOCKER_HOST` says and so pins nothing. Apple's runtime has no contexts and asks nothing.
  func testANewWorkroomWantsTheCurrentDockerContext() async throws {
    for (current, expected) in [("orbstack", "orbstack"), ("default", nil)] as [(String, String?)] {
      let (runtime, log) = try stubRuntime(output: current + "\n")
      let remote = RemoteHosts(makeDriver: { Self.driver(runtime: runtime, context: $0.context) })
      let key = try await remote.key(for: .docker)
      XCTAssertEqual(key, RemoteHosts.DriverKey(runtime: .docker, context: expected), current)
      XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "context show\n")
    }
    let remote = RemoteHosts(makeDriver: { _ in
      XCTFail("Apple's key asked a runtime")
      throw RemoteWorkrooms.Failure.noDocker
    })
    let apple = try await remote.key(for: .apple)
    XCTAssertEqual(apple, RemoteHosts.DriverKey(runtime: .apple))
  }

  /// A project keeps a base per runtime and Docker context (#309): a workroom derives from the one
  /// where it is asked for, a base made before #309 (no context) still serves Docker, and recording
  /// or removing one keeps the others.
  func testAProjectKeepsABasePerRuntimeAndContext() throws {
    let base = { (runtime: RemoteWorkrooms.Runtime, context: String?) in
      HostDescriptor(
        driver: runtime.rawValue, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
        container: Self.record(context: context))
    }
    let old = base(.docker, nil)
    let key = { (runtime: RemoteWorkrooms.Runtime, context: String?) in
      RemoteHosts.DriverKey(runtime: runtime, context: context)
    }
    // The one-base form a project before #309 has serves Docker on any context, and not Apple.
    XCTAssertEqual(RemoteWorkrooms.base(in: old, for: key(.docker, "orbstack"))?.id, old.id)
    XCTAssertNil(RemoteWorkrooms.base(in: old, for: key(.apple, nil)))

    let apple = base(.apple, nil)
    let both = RemoteWorkrooms.recording(apple, in: old)
    XCTAssertEqual(both.allBases.map(\.id), [old.id, apple.id])
    XCTAssertEqual(RemoteWorkrooms.base(in: both, for: key(.apple, nil))?.id, apple.id)
    // An exact match wins over the context-less one.
    let pinned = base(.docker, "orbstack")
    let three = RemoteWorkrooms.recording(pinned, in: both)
    XCTAssertEqual(RemoteWorkrooms.base(in: three, for: key(.docker, "orbstack"))?.id, pinned.id)
    XCTAssertEqual(RemoteWorkrooms.base(in: three, for: key(.docker, "desktop-linux"))?.id, old.id)
    // Round-trips through config, and comes apart again base by base.
    let decoded = try JSONDecoder().decode(
      HostDescriptor.self, from: try JSONEncoder().encode(three))
    XCTAssertEqual(decoded, three)
    let fewer = RemoteWorkrooms.removing(try XCTUnwrap(old.id), from: three)
    XCTAssertEqual(fewer?.allBases.map(\.id), [apple.id, pinned.id])
    let one = RemoteWorkrooms.removing(try XCTUnwrap(apple.id), from: fewer)
    XCTAssertEqual(one, pinned, "one base left goes back to the one-base form")
    XCTAssertNil(RemoteWorkrooms.removing(try XCTUnwrap(pinned.id), from: one))
  }

  /// Each recorded host is adopted into its own context's driver, and every driver's sweep keeps
  /// every recorded host: two contexts can name one daemon, and a sweep that kept only its own
  /// driver's hosts would remove the other's.
  func testHostsAreAdoptedByContextAndEverySweepKeepsThemAll() async throws {
    let (runtime, _) = try stubRuntime()
    let swept = Swept()
    let remote = RemoteHosts(
      makeDriver: { Self.driver(runtime: runtime, context: $0.context) },
      sweepDriver: { driver, known, _ in
        swept.add(driver.provisioning?.context, known)
        return []
      })
    let (base, pinned) = (UUID(), UUID())
    let descriptor = { (id: UUID, context: String?) in
      HostDescriptor(
        driver: RemoteWorkrooms.containerDriver, provisioner: RemoteWorkrooms.provisioner, id: id,
        container: Self.record(context: context))
    }
    let project = Project(
      path: "/proj", vcs: "git",
      workrooms: [
        Workroom(
          name: "w", path: "/home/workroom/r", vcsName: "workroom/w", warnings: [],
          host: descriptor(pinned, "orbstack"))
      ], host: descriptor(base, nil))

    remote.adopt([project])

    XCTAssertNil(
      try XCTUnwrap(remote.existingDriver(holding: base) as? ContainerHostDriver).provisioning?
        .context)
    XCTAssertEqual(
      (remote.existingDriver(holding: pinned) as? ContainerHostDriver)?.provisioning?.context,
      "orbstack")
    for _ in 0..<500 where swept.calls.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(Set(swept.calls.map(\.context)), [nil, "orbstack"])
    for call in swept.calls { XCTAssertEqual(call.known, [base, pinned], call.context ?? "nil") }
  }

  /// A boxd host (#356) is its own driver key, never Docker's: before boxd had a key, a delete of
  /// one fell back to Docker (`DriverKey(host) ?? DriverKey()`), and a descriptor naming a driver
  /// this build doesn't know is refused rather than taken down with another.
  func testABoxdHostIsItsOwnDriverKeyNeverDockers() throws {
    let boxd = HostDescriptor(
      driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
      org: "acme", account: "usr_1")
    let key = RemoteHosts.DriverKey(boxd)
    XCTAssertEqual(key, .boxd(org: "acme", account: "usr_1"))
    XCTAssertNil(key?.runtime)
    XCTAssertEqual(key?.place, .boxd)
    // A boxd machine logs in as `boxd`, so the clone goes in its home, not the container user's.
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    XCTAssertEqual(
      RemoteWorkrooms.clonePath(for: repository, on: try XCTUnwrap(key)), "/home/boxd/r")
    XCTAssertEqual(RemoteWorkrooms.clonePath(for: repository), "/home/workroom/r")
    XCTAssertEqual(try RemoteHosts.deletionKey(boxd), .boxd(org: "acme", account: "usr_1"))
    // A descriptor from before the `driver` field is Docker's, as it always was.
    XCTAssertEqual(try RemoteHosts.deletionKey(HostDescriptor(id: UUID())), RemoteHosts.DriverKey())
    XCTAssertThrowsError(try RemoteHosts.deletionKey(HostDescriptor(driver: "exe.dev", id: UUID())))
    // A boxd base serves only its own org and account; there is no unpinned form to fall back to.
    XCTAssertEqual(
      RemoteWorkrooms.base(in: boxd, for: .boxd(org: "acme", account: "usr_1"))?.id, boxd.id)
    XCTAssertNil(RemoteWorkrooms.base(in: boxd, for: .boxd(org: nil, account: "usr_1")))
    XCTAssertNil(RemoteWorkrooms.base(in: boxd, for: RemoteHosts.DriverKey()))
    // And the descriptor round-trips through config with its org and account.
    XCTAssertEqual(
      try JSONDecoder().decode(HostDescriptor.self, from: try JSONEncoder().encode(boxd)), boxd)
  }

  /// A delete of a boxd host asks for boxd's driver and environment, never Docker's.
  @MainActor
  func testDeletingABoxdHostUsesTheBoxdDriver() throws {
    let asked = Asked()
    let remote = RemoteHosts(makeDriver: { key in
      asked.add(key)
      return BoxdHostDriver(
        configuration: .init(cli: URL(fileURLWithPath: "/nonexistent/boxd")),
        directory: FileManager.default.temporaryDirectory)
    })
    let host = HostDescriptor(
      driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
      org: "acme", account: "usr_1")
    let deletion = try XCTUnwrap(try remote.environment(toDelete: [host]))
    XCTAssertEqual(asked.keys, [.boxd(org: "acme", account: "usr_1")])
    let environment = try XCTUnwrap(deletion.environment(for: host))
    XCTAssertTrue(environment.driver is BoxdHostDriver)
    XCTAssertEqual(
      environment.agentSocket,
      BoxdHostDriver.Configuration(cli: URL(fileURLWithPath: "/boxd")).agentSocket)
    XCTAssertNil(environment.gitHubToken, "a remote host's git never borrows the Mac's gh")
  }

  /// After a relaunch a boxd workroom is reached without Docker: its driver is made by name, with
  /// the org and account its record holds, and a missing container runtime never reads as its host
  /// being gone, which would report a closed pane's session ended while it runs on (#356).
  func testABoxdWorkroomIsReachedAfterARelaunchWithoutDocker() throws {
    let remote = RemoteHosts()
    let id = UUID()
    let project = Project(
      path: "/proj", vcs: "git",
      workrooms: [
        Workroom(
          name: "w", path: "/home/boxd/r", vcsName: "workroom/w", warnings: [],
          host: HostDescriptor(
            driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner, id: id,
            org: "acme", account: "usr_1"))
      ])

    remote.adopt([project])

    let driver = try XCTUnwrap(remote.existingDriver(holding: id) as? BoxdHostDriver)
    XCTAssertEqual(driver.configuration.org, "acme")
    XCTAssertEqual(driver.configuration.account, "usr_1")
    // Discriminates only where no container runtime is installed (CI's runners): on a Mac with
    // Docker, `runtimeIsMissing` is false for any host, and no seam-free way picks the runtime
    // lookup (`RemoteHosts.executable`, fixed paths). Kept for CI; eng review D6.
    XCTAssertFalse(remote.runtimeIsMissing(for: .remote(id)))
  }

  /// A workroom created on boxd records `driver: "boxd"` with its org and account, and no
  /// container record, from the moment its machine exists; a base of another place is refused.
  func testABoxdWorkroomRecordsItsOrgAndAccount() async throws {
    let made = UUID()
    let driver = DerivingDriver(derived: made)
    let key = RemoteHosts.DriverKey.boxd(org: "acme", account: "usr_1")
    let environment = RemoteProvisioning.Environment(
      driver: driver,
      agentSocket: BoxdHostDriver.Configuration(cli: URL(fileURLWithPath: "/boxd")).agentSocket,
      client: BrokerClient(
        baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey())),
      connect: { _ in throw HostDriverError.provisioning("stop after the checkpoint") })
    let base = { (driver: String, org: String?, account: String?) in
      HostDescriptor(
        driver: driver, provisioner: RemoteWorkrooms.provisioner, id: UUID(), repository: "o/r",
        cloneURL: "https://github.com/o/r.git", path: "/home/boxd/r", org: org, account: account)
    }
    let recorded = Recorded()
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { _, descriptor in
        recorded.add(descriptor)
        return "x"
      }, record: { _, descriptor in recorded.add(descriptor) }, forget: { _ in })
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    do {
      _ = try await RemoteWorkrooms.create(
        repository: repository, cloneURL: "https://github.com/o/r.git",
        base: base(RemoteWorkrooms.boxdDriver, "acme", "usr_1"), key: key, driver: driver,
        environment: environment, recorder: recorder)
      XCTFail("the connect was meant to fail")
    } catch {}
    let live = try XCTUnwrap(recorded.all.last { $0.id == made })
    XCTAssertEqual(live.driver, RemoteWorkrooms.boxdDriver)
    XCTAssertEqual(live.org, "acme")
    XCTAssertEqual(live.account, "usr_1")
    XCTAssertNil(live.container)
    XCTAssertTrue(
      recorded.all.allSatisfy { $0.driver == RemoteWorkrooms.boxdDriver && $0.account == "usr_1" })

    for (place, other, said) in [
      (key, base(RemoteWorkrooms.containerDriver, nil, nil), "Docker"),
      (RemoteHosts.DriverKey(), base(RemoteWorkrooms.boxdDriver, "acme", "usr_1"), "boxd"),
    ] {
      do {
        _ = try await RemoteWorkrooms.create(
          repository: repository, cloneURL: "https://github.com/o/r.git", base: other, key: place,
          driver: driver, environment: environment,
          recorder: RemoteWorkrooms.Recorder(
            reserve: { _, _ in "x" }, record: { _, _ in XCTFail("recorded") }, forget: { _ in }))
        XCTFail("a workroom went on another place than its base")
      } catch RemoteWorkrooms.Failure.baseOnOtherRuntime(let name) {
        XCTAssertEqual(name, said)
      }
    }
  }

  // Value: protects=a derive that fails and cannot remove its machine keeps the workroom's entry,
  // failed, naming the machine, so a delete can take the paid machine down; fails_when=the
  // catch-all forgets the entry on leftBehind; why_new=no test fails a derive's rollback; seam=none
  /// A derive whose rollback leaves its machine running keeps the workroom's entry, `failed`,
  /// naming the machine, rather than forgetting it: otherwise a paid machine runs on with nothing
  /// in the app to find it (#356).
  func testADeriveThatLeavesItsMachineBehindKeepsItsEntry() async throws {
    let made = UUID()
    let driver = DerivingDriver(derived: made, leavesItBehind: true)
    let key = RemoteHosts.DriverKey.boxd(org: "acme", account: "usr_1")
    let environment = RemoteProvisioning.Environment(
      driver: driver,
      agentSocket: BoxdHostDriver.Configuration(cli: URL(fileURLWithPath: "/boxd")).agentSocket,
      client: BrokerClient(
        baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey())))
    let recorded = Recorded()
    let forgot = Recorded()
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { _, descriptor in
        recorded.add(descriptor)
        return "x"
      }, record: { name, descriptor in recorded.add(descriptor, as: name) },
      forget: { _ in forgot.add(HostDescriptor()) })
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    do {
      _ = try await RemoteWorkrooms.create(
        repository: repository, cloneURL: "https://github.com/o/r.git",
        base: HostDescriptor(
          driver: RemoteWorkrooms.boxdDriver, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
          repository: "o/r", cloneURL: "https://github.com/o/r.git", path: "/home/boxd/r",
          org: "acme", account: "usr_1"),
        key: key, driver: driver, environment: environment, recorder: recorder)
      XCTFail("a derive that left its machine behind succeeded")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, _, let cleanup) {
      XCTAssertEqual(host, .remote(made))
      XCTAssertEqual(cleanup, ["machine x"])
    }
    XCTAssertTrue(forgot.all.isEmpty, "the entry naming a live machine was forgotten")
    let kept = try XCTUnwrap(recorded.all.last)
    XCTAssertEqual(kept.id, made)
    XCTAssertEqual(kept.state, "failed")
    XCTAssertNil(kept.grantID)
    // Over the entry reserved for it, not beside it: the `creating` placeholder would dangle.
    XCTAssertEqual(recorded.names.last, "x")
  }

  // Value: protects=a base create whose rollback fails records the base machine failed on the
  // project, so the project knows it and a delete takes it down; fails_when=the leftBehind catch is
  // dropped or its record is not written; why_new=the derive test passes a base and only covers the
  // derive catch; seam=none
  /// A project's first boxd create whose rollback leaves its machine running records that base on
  /// the project, `failed`, rather than forgetting a paid machine (#356, #370).
  func testABaseCreateThatLeavesItsMachineBehindIsRecorded() async throws {
    let made = UUID()
    let driver = DerivingDriver(derived: made, createLeavesItBehind: true)
    let key = RemoteHosts.DriverKey.boxd(org: "acme", account: "usr_1")
    let environment = RemoteProvisioning.Environment(
      driver: driver,
      agentSocket: BoxdHostDriver.Configuration(cli: URL(fileURLWithPath: "/boxd")).agentSocket,
      client: BrokerClient(
        baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey())))
    let recorded = Recorded()
    let forgot = Recorded()
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { _, descriptor in
        recorded.add(descriptor)
        return "x"
      }, record: { _, descriptor in recorded.add(descriptor) },
      forget: { _ in forgot.add(HostDescriptor()) })
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    do {
      _ = try await RemoteWorkrooms.create(
        repository: repository, cloneURL: "https://github.com/o/r.git", base: nil, key: key,
        driver: driver, environment: environment, recorder: recorder)
      XCTFail("a base create that left its machine behind succeeded")
    } catch HostDriverError.leftBehind(_, let left, let host) {
      XCTAssertEqual(host, .remote(made))
      XCTAssertEqual(left, ["machine x"])
    }
    XCTAssertTrue(forgot.all.isEmpty)
    let failed = try XCTUnwrap(
      recorded.all.flatMap { [$0] + ($0.bases ?? []) }.last { $0.id == made },
      "the base machine left behind was not recorded")
    XCTAssertEqual(failed.state, "failed")
    XCTAssertEqual(failed.driver, RemoteWorkrooms.boxdDriver)
    XCTAssertEqual(failed.account, "usr_1")
  }

  // Value: protects=a base whose build fails after its machine exists, and whose rollback cannot
  // destroy it, is recorded failed on the project; fails_when=only the driver's own leftBehind is
  // recorded; why_new=the other base test fails inside create(); seam=none
  /// A base build that fails after its machine exists (here its first connect), with a destroy that
  /// fails too, records the machine on the project, `failed`, as a create's own undo does (#356).
  func testABaseBuildWhoseRollbackFailsIsRecorded() async throws {
    let made = UUID()
    let driver = DerivingDriver(derived: made, createMakes: true, destroyFails: true)
    let environment = RemoteProvisioning.Environment(
      driver: driver,
      agentSocket: BoxdHostDriver.Configuration(cli: URL(fileURLWithPath: "/boxd")).agentSocket,
      client: BrokerClient(
        baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey())),
      connect: { _ in throw HostDriverError.provisioning("no agent") })
    let recorded = Recorded()
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { _, _ in "x" }, record: { _, descriptor in recorded.add(descriptor) },
      forget: { _ in })
    let repository = try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r"))
    do {
      _ = try await RemoteWorkrooms.create(
        repository: repository, cloneURL: "https://github.com/o/r.git", base: nil,
        key: .boxd(org: "acme", account: "usr_1"), driver: driver, environment: environment,
        recorder: recorder)
      XCTFail("a base build whose rollback failed succeeded")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, _, _) {
      XCTAssertEqual(host, .remote(made))
    }
    let failed = try XCTUnwrap(
      recorded.all.flatMap { [$0] + ($0.bases ?? []) }.last { $0.id == made },
      "the base machine left running was not recorded")
    XCTAssertEqual(failed.state, "failed")

    // A record that fails too leaves the caller the original failure, not the record's.
    do {
      _ = try await RemoteWorkrooms.create(
        repository: repository, cloneURL: "https://github.com/o/r.git", base: nil,
        key: .boxd(org: "acme", account: "usr_1"), driver: driver, environment: environment,
        recorder: RemoteWorkrooms.Recorder(
          reserve: { _, _ in "x" },
          record: { _, _ in throw HostDriverError.provisioning("no record") },
          forget: { _ in }))
      XCTFail("a base build whose rollback failed succeeded")
    } catch RemoteProvisioning.Failure.rollbackIncomplete(_, let host, _, _) {
      XCTAssertEqual(host, .remote(made))
    }
  }

  /// A driver whose derive makes `derived` and whose destroy succeeds unless told otherwise;
  /// `create` fails, leaving `derived` behind or not, unless `createMakes`.
  private struct DerivingDriver: HostTerminalDriver {
    let derived: UUID
    /// The derive fails and cannot remove the machine it made.
    var leavesItBehind = false
    /// The create fails and cannot remove the machine it made.
    var createLeavesItBehind = false
    /// The create makes `derived`, and a destroy of it fails.
    var createMakes = false
    var destroyFails = false
    var traits: HostDriverTraits {
      HostDriverTraits(
        transport: .sshStdio, deriveSpeed: nil, deriveCarriesLiveProcesses: false,
        durableDisk: true, maxLifetime: nil, keepAwakeHoldsCredential: false,
        sleepsWhenIdle: true)
    }
    func create() async throws -> HostID {
      if createMakes { return .remote(derived) }
      guard createLeavesItBehind else { throw HostDriverError.provisioning("no create") }
      throw HostDriverError.leftBehind(
        cause: "setup timed out", leftover: ["machine x"], host: .remote(derived))
    }
    func deriveFromBase(_ base: HostID) async throws -> HostID {
      guard leavesItBehind else { return .remote(derived) }
      throw HostDriverError.leftBehind(
        cause: "reboot timed out", leftover: ["machine x"], host: .remote(derived))
    }
    func destroy(_ host: HostID) async throws {
      if destroyFails { throw HostDriverError.provisioning("remove failed") }
    }
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.provisioning("no stream")
    }
    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      throw HostDriverError.provisioning("no exec")
    }
    func attachCommand(
      to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
      metadata: [(key: String, value: String)]
    ) throws -> String { "" }
    func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool { false }
  }

  private final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [HostDescriptor] = []
    private var under: [String?] = []
    var all: [HostDescriptor] { lock.withLock { made } }
    /// The entry name each descriptor was recorded under, in step with `all`.
    var names: [String?] { lock.withLock { under } }
    func add(_ descriptor: HostDescriptor, as name: String? = nil) {
      lock.withLock {
        made.append(descriptor)
        under.append(name)
      }
    }
  }

  private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [RemoteHosts.DriverKey] = []
    var keys: [RemoteHosts.DriverKey] { lock.withLock { made } }
    func add(_ key: RemoteHosts.DriverKey) { lock.withLock { made.append(key) } }
  }

  private final class Swept: @unchecked Sendable {
    private let lock = NSLock()
    private var made: [(context: String?, known: Set<UUID>)] = []
    var calls: [(context: String?, known: Set<UUID>)] { lock.withLock { made } }
    func add(_ context: String?, _ known: Set<UUID>) {
      lock.withLock { made.append((context, known)) }
    }
  }

  /// A sweep keeps an image another context's host was run from: both contexts can name one daemon,
  /// where that image is labelled as this build's and old enough to go.
  func testASweepKeepsImagesOtherContextsHostsRunFrom() async throws {
    let image = "sha256:" + String(repeating: "b", count: 64)
    for kept in [true, false] {
      let (runtime, log) = try stubRuntime()
      let script = try String(contentsOf: runtime, encoding: .utf8)
      try
        (script + """

          case "$1 $2" in "images -aq") echo \(image.dropFirst(7).prefix(12)) ;; "image inspect") echo 0 ;; esac
          """).write(to: runtime, atomically: true, encoding: .utf8)
      _ = await Self.driver(runtime: runtime, context: nil).sweep(
        keeping: [], images: kept ? [image] : [])
      let removed = try String(contentsOf: log, encoding: .utf8).contains("rmi ")
      XCTAssertEqual(removed, !kept, kept ? "a recorded image was removed" : "the control kept it")
    }
  }

  // MARK: Apple's container runtime (#309)

  /// A stand-in CLI that answers each command by the shell `cases` given (a `case "$*" in` body),
  /// and logs every call.
  private func scriptedRuntime(_ cases: String) throws -> (runtime: URL, log: URL) {
    let (runtime, log) = try stubRuntime()
    let script = try String(contentsOf: runtime, encoding: .utf8)
    try (script + "\ncase \"$*\" in\n\(cases)\nesac\n").write(
      to: runtime, atomically: true, encoding: .utf8)
    return (runtime, log)
  }

  private func calls(_ log: URL) throws -> [String] {
    try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
  }

  /// Apple's runtime has no `--restart` or `--pull`, and pulls every platform of an image unless
  /// told its architecture: a missing image is pulled for arm64, and run with neither flag.
  func testAppleRunsAndPullsInItsOwnDialect() async throws {
    let (runtime, log) = try scriptedRuntime(
      """
      "image inspect workroom-host") exit 1 ;;
      run*) exit 1 ;;
      """)
    do {
      _ = try await Self.driver(runtime: runtime, context: nil, dialect: .apple).create()
      XCTFail("run was meant to fail")
    } catch {}
    let made = try calls(log)
    XCTAssertEqual(
      Array(made.prefix(2)),
      ["image inspect workroom-host", "image pull --arch arm64 workroom-host"])
    let run = try XCTUnwrap(made.first { $0.hasPrefix("run ") })
    XCTAssertTrue(run.hasPrefix("run --detach --init --arch arm64 --name workroom-"), run)
    XCTAssertFalse(run.contains("--restart") || run.contains("--pull"), run)
    XCTAssertTrue(made.contains { $0.hasPrefix("delete --force workroom-") }, "\(made)")
  }

  /// Apple's sweep: containers and images labelled as this build's and old enough go, unless a
  /// recorded host is theirs; an image any container was run from stays, since Apple removes an
  /// image that is in use where Docker refuses.
  func testAppleSweepsByJSONAndKeepsImagesInUse() async throws {
    let (kept, swept) = (UUID(), UUID())
    func container(_ id: String, labels: [String: String], image: String) -> [String: Any] {
      [
        "id": id, "status": ["state": "running"],
        "configuration": ["labels": labels, "image": ["reference": image]],
      ]
    }
    func image(_ name: String, labels: [String: String]) -> [String: Any] {
      [
        "configuration": ["name": name],
        "variants": [
          ["platform": ["architecture": "arm64"], "config": ["config": ["Labels": labels]]]
        ],
      ]
    }
    let ours = ["workroom.provisioner": "test", "workroom.created": "1"]
    let list = [
      container(ContainerHostDriver.containerName(kept), labels: ours, image: "in-use:1"),
      container(ContainerHostDriver.containerName(swept), labels: ours, image: "other:1"),
      container(
        "theirs", labels: ["workroom.provisioner": "other", "workroom.created": "1"], image: "x"),
      container(
        "fresh",
        labels: [
          "workroom.provisioner": "test",
          "workroom.created": "\(Int(Date().timeIntervalSince1970))",
        ], image: "y"),
    ]
    let images = [
      image("in-use:1", labels: ours), image("leftover:1", labels: ours),
      image("recorded:1", labels: ours), image("user:1", labels: [:]),
    ]
    let json = { (o: Any) in
      String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }
    let (runtime, log) = try scriptedRuntime(
      """
      "list --all --format json") printf '%s' \(ContainerHostDriver.shellQuoted(try json(list))) ;;
      "image list --format json") printf '%s' \(ContainerHostDriver.shellQuoted(try json(images))) ;;
      """)
    let failures = await Self.driver(runtime: runtime, context: nil, dialect: .apple).sweep(
      keeping: [kept], images: ["recorded:1"])
    XCTAssertEqual(failures, [])
    let removed = try calls(log).filter { $0.hasPrefix("delete ") || $0.hasPrefix("image delete ") }
    XCTAssertEqual(
      removed,
      ["delete --force \(ContainerHostDriver.containerName(swept))", "image delete leftover:1"])
  }

  /// A derive's snapshot image whose delete failed goes with the next sweep, though its workroom's
  /// container was run from it: Apple's container runs without its image, and the snapshot is a
  /// whole disk.
  func testAppleSweepRemovesALeftoverSnapshotItsContainerRanFrom() async throws {
    let workroom = UUID()
    let snapshot = ContainerHostDriver.deriveDirectoryPrefix + "abc:latest"
    let ours = ["workroom.provisioner": "test", "workroom.created": "1"]
    let list: [[String: Any]] = [
      [
        "id": ContainerHostDriver.containerName(workroom), "status": ["state": "running"],
        "configuration": ["labels": ours, "image": ["reference": snapshot]],
      ]
    ]
    let images: [[String: Any]] = [
      [
        "configuration": ["name": snapshot],
        "variants": [
          ["platform": ["architecture": "arm64"], "config": ["config": ["Labels": ours]]]
        ],
      ]
    ]
    let json = { (o: Any) in
      String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }
    let (runtime, log) = try scriptedRuntime(
      """
      "list --all --format json") printf '%s' \(ContainerHostDriver.shellQuoted(try json(list))) ;;
      "image list --format json") printf '%s' \(ContainerHostDriver.shellQuoted(try json(images))) ;;
      """)
    let failures = await Self.driver(runtime: runtime, context: nil, dialect: .apple).sweep(
      keeping: [workroom], images: [])
    XCTAssertEqual(failures, [])
    let removed = try calls(log).filter { $0.hasPrefix("delete ") || $0.hasPrefix("image delete ") }
    XCTAssertEqual(removed, ["image delete \(snapshot)"])
  }

  /// A derived image is rebuilt from the exported disk with the host image's own process: its
  /// entrypoint, command and environment, not the run-time ones a container carries.
  func testAppleDerivesWithTheImagesOwnProcess() throws {
    let image: [String: Any] = [
      "variants": [
        [
          "platform": ["architecture": "amd64"],
          "config": ["config": ["Entrypoint": ["/wrong"]]],
        ],
        [
          "platform": ["architecture": "arm64"],
          "config": [
            "config": [
              "Entrypoint": ["/usr/local/bin/entrypoint.sh"], "Cmd": ["serve", "a b"],
              "Env": ["PATH=/usr/bin:/bin", #"QUOTED=say "hi" \ $HOME"#], "WorkingDir": "/srv/$x",
              "User": "",
            ]
          ],
        ],
      ]
    ]
    let process = try XCTUnwrap(
      AppleContainerCLI.processConfig(ofImage: image, architecture: "arm64"))
    XCTAssertEqual(
      try AppleContainerCLI.dockerfile(process),
      """
      FROM scratch
      ADD rootfs.tar /
      ENV PATH="/usr/bin:/bin"
      ENV QUOTED="say \\"hi\\" \\\\ \\$HOME"
      WORKDIR /srv/\\$x
      ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
      CMD ["serve","a b"]

      """)
    var broken = process
    broken.env.append("BAD=line\nbreak")
    XCTAssertThrowsError(try AppleContainerCLI.dockerfile(broken))
  }

  /// What each container gets: Apple's own default is a 1 GB VM, too small for a compiler or an
  /// agent, so it gets half the cores and a quarter of the memory, between 2 and 8 GB, unless set.
  /// Docker's containers share Docker's VM and get nothing unless set.
  func testContainerResourcesDefaultForAppleOnly() {
    let gb: UInt64 = 1_073_741_824
    let apple = { (cores: Int, memory: UInt64) in
      RemoteHosts.resources(
        for: .apple, cpus: nil, memory: nil, cores: cores, physicalMemory: memory)
    }
    XCTAssertTrue(apple(10, 32 * gb) == (5, "8G"))
    XCTAssertTrue(apple(8, 16 * gb) == (4, "4G"))
    XCTAssertTrue(apple(2, 4 * gb) == (2, "2G"))
    XCTAssertTrue(
      RemoteHosts.resources(
        for: .apple, cpus: 6, memory: "12G", cores: 8, physicalMemory: 16 * gb) == (6, "12G"))
    XCTAssertTrue(
      RemoteHosts.resources(for: .docker, cpus: nil, memory: nil, cores: 8, physicalMemory: 16 * gb)
        == (nil, nil))
  }

  /// A derive a crash cut short leaves its staged disk in the temporary folder; the sweep removes
  /// one gone quiet, and leaves one still being written.
  func testAppleSweepRemovesStaleDeriveFolders() async throws {
    let temp = FileManager.default.temporaryDirectory
    let stale = temp.appendingPathComponent(
      ContainerHostDriver.deriveDirectoryPrefix + "stale-\(UUID())")
    let live = temp.appendingPathComponent(
      ContainerHostDriver.deriveDirectoryPrefix + "live-\(UUID())")
    for directory in [stale, live] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data("disk".utf8).write(to: directory.appendingPathComponent("rootfs.tar"))
    }
    defer { for d in [stale, live] { try? FileManager.default.removeItem(at: d) } }
    let old = Date(timeIntervalSinceNow: -3600)
    for url in [stale, stale.appendingPathComponent("rootfs.tar"), live] {
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }
    let (runtime, _) = try scriptedRuntime(
      """
      "list --all --format json") printf '[]' ;;
      "image list --format json") printf '[]' ;;
      """)
    _ = await Self.driver(runtime: runtime, context: nil, dialect: .apple).sweep(keeping: [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "a stale folder stayed")
    XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "a live derive's was taken")
  }

  /// A derive whose stop of the base fails, as a cancelled create's does, starts the base again:
  /// the stop may have taken effect all the same, and the base must not be left down.
  func testAnAppleDeriveCutOffMidStopStartsTheBaseAgain() async throws {
    let base = UUID()
    let container = ContainerHostDriver.containerName(base)
    let inspected: [[String: Any]] = [
      [
        "id": container, "status": ["state": "running"],
        "configuration": ["image": ["reference": "host:1"]],
      ]
    ]
    let image: [[String: Any]] = [
      [
        "variants": [
          [
            "platform": ["architecture": "arm64"],
            "config": ["config": ["Entrypoint": ["/usr/local/bin/entrypoint.sh"]]],
          ]
        ]
      ]
    ]
    let json = { (o: Any) in
      String(decoding: try JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }
    let (runtime, log) = try scriptedRuntime(
      """
      "inspect \(container)") printf '%s' \(ContainerHostDriver.shellQuoted(try json(inspected))) ;;
      "image inspect host:1") printf '%s' \(ContainerHostDriver.shellQuoted(try json(image))) ;;
      "stop \(container)") exit 1 ;;
      """)
    let driver = Self.driver(runtime: runtime, context: nil, dialect: .apple)
    try driver.adopt(base, Self.record(context: nil), isBase: true)
    do {
      _ = try await driver.deriveFromBase(.remote(base))
      XCTFail("derived through a failed stop")
    } catch {}
    let made = try calls(log)
    XCTAssertTrue(made.contains("stop \(container)"), "\(made)")
    XCTAssertTrue(made.contains("start \(container)"), "the base was left stopped: \(made)")
  }

  /// Only a base is derived from. An Apple instance records no image, as a base doesn't, so a
  /// host is a base only when its adopter says so; deriving from an instance would copy its
  /// enrolment.
  func testAnAppleInstanceIsNeverDerivedFrom() async throws {
    let (runtime, log) = try stubRuntime()
    let driver = Self.driver(runtime: runtime, context: nil, dialect: .apple)
    let instance = UUID()
    try driver.adopt(instance, Self.record(context: nil), isBase: false)
    do {
      _ = try await driver.deriveFromBase(.remote(instance))
      XCTFail("derived from an instance")
    } catch HostDriverError.invalidConfiguration {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "the instance was touched")
  }

  /// A recorded Apple host is adopted into Apple's driver, and a Docker one beside it into
  /// Docker's, by the descriptor's `driver`.
  func testHostsAreAdoptedIntoTheirRuntimesDrivers() throws {
    let (runtime, _) = try stubRuntime()
    let remote = RemoteHosts(
      makeDriver: { key in
        Self.driver(
          runtime: runtime, context: key.context, dialect: key.runtime == .apple ? .apple : .docker)
      }, sweepDriver: { _, _, _ in [] })
    let (docker, apple) = (UUID(), UUID())
    let host = { (id: UUID, runtime: RemoteWorkrooms.Runtime) in
      HostDescriptor(
        driver: runtime.rawValue, provisioner: RemoteWorkrooms.provisioner, id: id,
        container: Self.record(context: nil))
    }
    let project = Project(
      path: "/proj", vcs: "git",
      workrooms: [
        Workroom(
          name: "w", path: "/home/workroom/r", vcsName: "workroom/w", warnings: [],
          host: host(apple, .apple))
      ], host: host(docker, .docker))
    remote.adopt([project])
    XCTAssertEqual(
      (remote.existingDriver(holding: docker) as? ContainerHostDriver)?.provisioning?.dialect,
      .docker)
    XCTAssertEqual(
      (remote.existingDriver(holding: apple) as? ContainerHostDriver)?.provisioning?.dialect,
      .apple)
  }

  /// A project's workrooms are derived from its base, so they go on the base's runtime: asking
  /// for another is refused before anything is made.
  func testAWorkroomOnAnotherRuntimeThanItsBaseIsRefused() async throws {
    let (runtime, _) = try stubRuntime()
    let driver = Self.driver(runtime: runtime, context: nil, dialect: .apple)
    let environment = RemoteProvisioning.Environment(
      driver: driver, agentSocket: RemoteWorkrooms.agentSocket,
      client: BrokerClient(
        baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey())))
    do {
      _ = try await RemoteWorkrooms.create(
        repository: try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r")),
        cloneURL: "https://github.com/o/r.git",
        base: HostDescriptor(
          driver: RemoteWorkrooms.Runtime.docker.rawValue, provisioner: RemoteWorkrooms.provisioner,
          id: UUID(), repository: "o/r", cloneURL: "https://github.com/o/r.git",
          path: "/home/workroom/r"),
        key: RemoteHosts.DriverKey(runtime: .apple), driver: driver, environment: environment,
        recorder: RemoteWorkrooms.Recorder(
          reserve: { _, _ in "x" }, record: { _, _ in XCTFail("recorded") },
          forget: { _ in }))
      XCTFail("a workroom went on another runtime than its base")
    } catch RemoteWorkrooms.Failure.baseOnOtherRuntime(let runtime) {
      XCTAssertEqual(runtime, "Docker")
    }
  }

  /// Why a container runtime's New Workroom entry is off, in the order a user has to fix it:
  /// Apple's needs Apple silicon and macOS 26 before installing it means anything (#309).
  func testARuntimeEntrySaysWhyItIsOff() {
    let ready = { (runtime: RemoteWorkrooms.Runtime) in
      RemoteWorkrooms.unavailability(
        of: runtime, installed: true, appleSilicon: true, macOS26: true, signedIn: true)
    }
    XCTAssertNil(ready(.docker))
    XCTAssertNil(ready(.apple))
    XCTAssertEqual(
      RemoteWorkrooms.unavailability(
        of: .apple, installed: false, appleSilicon: false, macOS26: false, signedIn: false),
      "needs Apple silicon")
    XCTAssertEqual(
      RemoteWorkrooms.unavailability(
        of: .apple, installed: false, appleSilicon: true, macOS26: false, signedIn: true),
      "needs macOS 26")
    // Docker runs on an Intel Mac and on macOS 15.
    XCTAssertNil(
      RemoteWorkrooms.unavailability(
        of: .docker, installed: true, appleSilicon: false, macOS26: false, signedIn: true))
    XCTAssertEqual(
      RemoteWorkrooms.unavailability(
        of: .docker, installed: false, appleSilicon: true, macOS26: true, signedIn: true),
      "not installed")
    XCTAssertEqual(
      RemoteWorkrooms.unavailability(
        of: .docker, installed: true, appleSilicon: true, macOS26: true, signedIn: false),
      "sign in to Codaset or run gh auth login")
  }

  /// A boxd create's row shows the step it is on as a fraction of the steps it takes: all eight
  /// when it builds the project's base first, the five of a derive when the base exists (#356).
  func testABoxdCreateShowsItsStepOfTheStepsItTakes() {
    XCTAssertEqual(
      AppStore.createStep(.machine, buildsBase: true),
      .init(fraction: 0, label: "Creating the base machine (step 1 of 8)"))
    XCTAssertEqual(AppStore.createStep(.snapshot, buildsBase: true)?.fraction, 3.0 / 8)
    XCTAssertEqual(
      AppStore.createStep(.snapshot, buildsBase: false),
      .init(fraction: 0, label: "Copying the base machine (step 1 of 5)"))
    XCTAssertEqual(AppStore.createStep(.checkout, buildsBase: false)?.fraction, 4.0 / 5)
    XCTAssertNil(AppStore.createStep(.clone, buildsBase: false), "a derive clones nothing")
  }

  /// boxd's entry is off without its CLI, and without Codaset: a boxd workroom takes the broker's
  /// tokens only, never the Mac's gh, so `gh auth login` is no way in (OQ20, #356). Whether boxd
  /// itself is signed in is a CLI call, which a create makes rather than the menu.
  func testTheBoxdEntrySaysWhyItIsOff() {
    XCTAssertNil(RemoteWorkrooms.unavailability(ofBoxdInstalled: true, codasetSignedIn: true))
    XCTAssertEqual(
      RemoteWorkrooms.unavailability(ofBoxdInstalled: false, codasetSignedIn: false),
      "not installed")
    XCTAssertEqual(
      RemoteWorkrooms.unavailability(ofBoxdInstalled: true, codasetSignedIn: false),
      "sign in to Codaset")
  }

  /// A driver takes on only a host of its own context: its commands would not reach another's.
  func testADriverRefusesAHostOfAnotherContext() throws {
    let (runtime, _) = try stubRuntime()
    XCTAssertThrowsError(
      try Self.driver(runtime: runtime, context: "orbstack").adopt(
        UUID(), Self.record(context: nil)))
    XCTAssertNoThrow(
      try Self.driver(runtime: runtime, context: "orbstack").adopt(
        UUID(), Self.record(context: "orbstack")))
  }

  /// A delete takes each host down with the environment of its own runtime and context (#309).
  func testADeleteRoutesEachHostToItsRuntimesEnvironment() throws {
    let (runtime, _) = try stubRuntime()
    let environment = { (key: RemoteHosts.DriverKey) in
      RemoteProvisioning.Environment(
        driver: Self.driver(
          runtime: runtime, context: key.context, dialect: key.runtime == .apple ? .apple : .docker),
        agentSocket: RemoteWorkrooms.agentSocket,
        client: BrokerClient(
          baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey())))
    }
    let keys = [
      RemoteHosts.DriverKey(runtime: .docker),
      RemoteHosts.DriverKey(runtime: .docker, context: "orbstack"),
      RemoteHosts.DriverKey(runtime: .apple),
    ]
    let deletion = RemoteHosts.Deletion(
      environments: Dictionary(uniqueKeysWithValues: keys.map { ($0, environment($0)) }))
    for key in keys {
      let host = HostDescriptor(
        driver: key.runtime?.rawValue, provisioner: RemoteWorkrooms.provisioner, id: UUID(),
        container: Self.record(context: key.context))
      let driver = try XCTUnwrap(deletion.environment(for: host)?.driver as? ContainerHostDriver)
      XCTAssertEqual(driver.provisioning?.context, key.context)
      XCTAssertEqual(driver.provisioning?.dialect, key.runtime == .apple ? .apple : .docker)
    }
  }

  /// A base record that names a host but not enough to derive from is refused: building another
  /// would leave the recorded one running with nothing pointing at it.
  func testAnIncompleteBaseIsNotReplaced() async throws {
    let driver = ContainerHostDriver(hosts: [:], directory: FileManager.default.temporaryDirectory)
    let environment = RemoteProvisioning.Environment(
      driver: driver, agentSocket: RemoteWorkrooms.agentSocket,
      client: BrokerClient(
        baseURL: BrokerEndpoint.development, key: .software(P256.Signing.PrivateKey())))
    let recorder = RemoteWorkrooms.Recorder(
      reserve: { _, _ in
        XCTFail("a name was taken")
        return "x"
      },
      record: { _, _ in XCTFail("something was recorded") },
      forget: { _ in XCTFail("something was forgotten") })

    do {
      _ = try await RemoteWorkrooms.create(
        repository: try XCTUnwrap(GitHubRepository(host: "github.com", owner: "o", name: "r")),
        cloneURL: "https://github.com/o/r.git",
        base: HostDescriptor(provisioner: RemoteWorkrooms.provisioner, id: UUID()),
        driver: driver, environment: environment, recorder: recorder)
      XCTFail("an incomplete base was replaced")
    } catch RemoteWorkrooms.Failure.incompleteBase {}
  }
}
