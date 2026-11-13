import DaemonConnection
import DaemonConnectionTestSupport
import HostDrivers
import Synchronization
import WorkroomDomain
import WorkroomVCS
import XCTest

@testable import Workroom

/// Guards on reaching a remote host (`HostReachability`): connecting a host once for every caller,
/// backing off a dead one, leaving an asleep box asleep for a background read, starting only an
/// opened container, the links a wake asks, and the credential relay.
final class HostReachabilityTests: XCTestCase {
  private typealias Swept = RemoteHostsTests.Swept

  /// Counts connects, fails them or not, and holds each until released, for
  /// `HostReachability.ensureConnected`.
  final class Connects: Sendable {
    private struct State {
      var count = 0
      var failing = false
      var held = true
      var asked = 0
      var instant = ContinuousClock.now
    }
    private let state = Mutex(State())
    var calls: Int { state.withLock { $0.count } }
    var now: ContinuousClock.Instant { state.withLock { $0.instant } }
    func fail(_ on: Bool) { state.withLock { $0.failing = on } }
    func advance(_ by: Duration) { state.withLock { $0.instant += by } }
    func hold(_ on: Bool) { state.withLock { $0.held = on } }
    /// Callers that have reached `ensureConnected`'s connected check.
    var arrived: Int { state.withLock { $0.asked } }
    func ask() { state.withLock { $0.asked += 1 } }

    func connect(_ host: HostID) async throws {
      state.withLock { $0.count += 1 }
      while state.withLock({ $0.held }) { try await Task.sleep(for: .milliseconds(1)) }
      if state.withLock({ $0.failing }) { throw HostDriverError.unknownHost(host) }
    }
  }

  private func hosts(_ connects: Connects) -> HostReachability {
    RemoteHosts(
      connectHost: { try await connects.connect($0) },
      isConnected: { _ in
        connects.ask()
        return false
      },
      startHost: { _ in }, now: { connects.now }
    ).reachability
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
    connects.advance(HostReachability.retryAfter)
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 2)
  }

  /// A host an older Nightly made before the daemon was renamed (#525) is refused by the bootstrap,
  /// and the refusal keeps its words through the connect, so the workroom says to recreate it
  /// rather than "Repository service unavailable" (eng review D3), and the status sweep's reads
  /// inside the backoff keep saying so rather than flip to "unavailable" between probes.
  func testAnOldLayoutHostSaysToRecreateTheWorkroom() async throws {
    let host = HostID.remote(UUID())
    let instant = ContinuousClock.now
    let remote = RemoteHosts(
      connectHost: { _ in throw DaemonBootstrap.Error.olderLayout }, isConnected: { _ in false },
      startHost: { _ in }, now: { instant }
    ).reachability
    for attempt in ["the probe", "a read inside the backoff"] {
      do {
        try await remote.ensureConnected(host)
        XCTFail("an old-layout host connected (\(attempt))")
      } catch {
        XCTAssertEqual(error as? RepositoryRoutingError, .olderLayout(host), attempt)
        XCTAssertEqual(
          (error as? LocalizedError)?.errorDescription, DaemonInstall.formerLayoutMessage, attempt)
      }
    }
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
    let remoteHosts = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in }, now: { connects.now },
      presence: { _ in asked.answer() })
    let remote = remoteHosts.reachability
    let id = UUID()
    let host = HostID.remote(id)
    remoteHosts.reachability.adopt([
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "w", path: "/home/boxd/r", vcsName: "workroom/w", warnings: [],
            host: HostDescriptor(
              driver: HostKind.boxd.driver, provisioner: RemoteWorkrooms.provisioner, id: id,
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
    connects.advance(HostReachability.retryAfter)
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
    connects.advance(HostReachability.retryAfter)
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 2)

    // A machine boxd says is gone is reported as gone, not asleep, and then left for the window.
    asked.setGone()
    connects.advance(HostReachability.retryAfter)
    let before = asked.calls
    // Still gone inside the window, so the status keeps saying so (#629).
    for expected in [RepositoryRoutingError.gone(host), .gone(host)] {
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

  // Value: protects=a wake or network change asks the boxd and exe.dev hosts only, and a host it
  // can't ask counts as silent; fails_when=the provider filter is dropped (a container's loopback
  // link is asked too) or a host with no link reads as answering; why_new=new behaviour;
  // seam=none
  /// `RemoteLinkMonitor`'s question goes to a recorded provider host, not a container's, and one
  /// with no link to ask is among those that didn't answer.
  func testOnlyAProviderHostIsAskedAfterANetworkChange() async {
    let boxd = UUID()
    let container = UUID()
    func workroom(_ name: String, _ host: HostDescriptor) -> Workroom {
      Workroom(
        name: name, path: "/home/w/\(name)", vcsName: "workroom/\(name)", warnings: [], host: host)
    }
    let remote = RemoteHosts()
    remote.reachability.adopt(
      [
        Project(
          path: "/proj", vcs: "git",
          workrooms: [
            workroom(
              "b",
              HostDescriptor(
                driver: HostKind.boxd.driver, provisioner: RemoteWorkrooms.provisioner,
                id: boxd, account: "usr_1")),
            workroom(
              "c",
              HostDescriptor(
                driver: ContainerRuntime.docker.rawValue,
                provisioner: RemoteWorkrooms.provisioner, id: container)),
          ])
      ], sweep: false)

    let unanswering = await remote.reachability.unansweringProviderHosts()
    XCTAssertEqual(unanswering, [.remote(boxd)])
  }

  /// A click reaches a boxd host a background read would leave alone (#356): closing a pane (to
  /// end its session there) wakes a box that is asleep, where a status read is refused.
  @MainActor
  func testAClickWakesABoxdHostABackgroundReadLeavesAlone() async throws {
    let connects = Connects()
    connects.hold(false)
    let asked = Asleep()
    asked.set(true)
    let remoteHosts = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in }, now: { connects.now }, presence: { _ in asked.answer() })
    let remote = remoteHosts.reachability
    let id = UUID()
    let host = HostID.remote(id)
    remoteHosts.reachability.adopt(
      [
        Project(
          path: "/proj", vcs: "git",
          workrooms: [
            Workroom(
              name: "b", path: "/home/boxd/r", vcsName: "workroom/b", warnings: [],
              host: HostDescriptor(
                driver: HostKind.boxd.driver, provisioner: RemoteWorkrooms.provisioner,
                id: id, account: "usr_1"))
          ])
      ], sweep: false)

    do {
      try await remote.ensureConnected(host)
      XCTFail("a background read woke an asleep box")
    } catch {
      XCTAssertEqual(error as? RepositoryRoutingError, .asleep(host))
    }
    try await remote.ensureConnected(host, wake: true)
    XCTAssertEqual(connects.calls, 1)

    // A click right after one that failed is still tried: waking a box can fail once while it
    // resumes, and the retry must not wait out the failure window.
    connects.fail(true)
    do {
      try await remote.ensureConnected(host, wake: true)
      XCTFail("the failing connect succeeded")
    } catch {}
    connects.fail(false)
    try await remote.ensureConnected(host, wake: true)
    XCTAssertEqual(connects.calls, 3, "a second click inside the window was refused")
  }

  /// A selected workroom's box is reached by a background read, even asleep (#356): after
  /// the Mac sleeps, the open workroom must not read as asleep until it is selected again.
  @MainActor
  func testASelectedWorkroomsBoxIsReachedEvenAsleep() async throws {
    let connects = Connects()
    connects.hold(false)
    let asked = Asleep()
    asked.set(true)
    let remoteHosts = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in }, now: { connects.now }, presence: { _ in asked.answer() })
    let remote = remoteHosts.reachability
    let id = UUID()
    let host = HostID.remote(id)
    remoteHosts.reachability.adopt(
      [
        Project(
          path: "/proj", vcs: "git",
          workrooms: [
            Workroom(
              name: "b", path: "/home/boxd/r", vcsName: "workroom/b", warnings: [],
              host: HostDescriptor(
                driver: HostKind.boxd.driver, provisioner: RemoteWorkrooms.provisioner,
                id: id, account: "usr_1"))
          ])
      ], sweep: false)
    remote.select(host, in: "window")
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 1)
    XCTAssertEqual(asked.calls, 0, "boxd was asked about the selected workroom's box")
  }

  /// Each window has its own selection (one AppStore per window): a host selected in any window is
  /// reconnected by a background read, even one boxd says is asleep, whatever another window
  /// selects.
  @MainActor
  func testAHostSelectedInAnyWindowIsReconnected() async throws {
    let connects = Connects()
    connects.hold(false)
    let asked = Asleep()
    asked.set(false)
    let remoteHosts = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in }, now: { connects.now }, presence: { _ in asked.answer() })
    let remote = remoteHosts.reachability
    let id = UUID()
    let host = HostID.remote(id)
    remoteHosts.reachability.adopt(
      [
        Project(
          path: "/proj", vcs: "git",
          workrooms: [
            Workroom(
              name: "b", path: "/home/boxd/r", vcsName: "workroom/b", warnings: [],
              host: HostDescriptor(
                driver: HostKind.boxd.driver, provisioner: RemoteWorkrooms.provisioner,
                id: id, account: "usr_1"))
          ])
      ], sweep: false)

    asked.set(true)
    remote.select(host, in: "window A")
    remote.select(nil, in: "window B")
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 1, "another window's selection left window A's host alone")
    remote.select(nil, in: "window A")
    do {
      try await remote.ensureConnected(host)
      XCTFail("an unselected asleep host was reconnected")
    } catch {
      XCTAssertEqual(error as? RepositoryRoutingError, .asleep(host))
    }
  }

  private final class Asleep: Sendable {
    private struct State {
      var value: HostPresence?
      var count = 0
    }
    private let state = Mutex(State())
    var calls: Int { state.withLock { $0.count } }
    func set(_ asleep: Bool?) {
      state.withLock { $0.value = asleep.map { $0 ? .asleep : .awake } }
    }
    func setGone() { state.withLock { $0.value = .gone } }
    func set(presence: HostPresence?) { state.withLock { $0.value = presence } }
    func answer() -> HostPresence? {
      state.withLock {
        $0.count += 1
        return $0.value
      }
    }
  }

  /// Value: protects=a Railway workroom destroyed on Railway shows gone even while it is on screen,
  /// a revoked sign-in shows signed out without blocking what the user asked for, and a Railway
  /// that can't answer never reads as asleep (#629); fails_when=presence is asked only on
  /// background reads, signed-out blocks an opened workroom, or nil reads as asleep;
  /// seam=HostReachability over the real Railway driver's `hostsSleep`, presence stubbed
  func testARailwayHostIsAskedOnEveryReadAndASignOutHoldsOnlyBackgroundReads() async throws {
    let connects = Connects()
    connects.hold(false)
    let asked = Asleep()
    let remoteHosts = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in }, now: { connects.now }, presence: { _ in asked.answer() })
    let remote = remoteHosts.reachability
    let id = UUID()
    let host = HostID.remote(id)
    remote.adopt([
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "w", path: "/root/r", vcsName: "workroom/w", warnings: [],
            host: HostDescriptor(
              driver: HostKind.railway.driver, provisioner: RemoteWorkrooms.provisioner, id: id,
              railway: RailwayHostRecord(
                projectID: "prj", environmentID: "env", sandboxID: "sbx",
                hostKey: "ssh-ed25519 AAAA")))
        ])
    ])

    // Railway couldn't say: a sandbox never sleeps, so the read connects.
    asked.set(presence: nil)
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 1)

    // Signed out: a background read says so, and connects nothing; the opened workroom connects.
    asked.set(presence: .signedOut)
    do {
      try await remote.ensureConnected(host)
      XCTFail("a background read went ahead signed out")
    } catch {
      XCTAssertEqual(error as? RepositoryRoutingError, .signedOut(host))
    }
    remote.activate(host)
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 2)

    // Destroyed on Railway: gone, even while selected.
    asked.set(presence: .gone)
    remote.select(host)
    for _ in 0..<2 {
      do {
        try await remote.ensureConnected(host)
        XCTFail("a gone sandbox was connected to")
      } catch {
        XCTAssertEqual(error as? RepositoryRoutingError, .gone(host), "gone decayed")
      }
    }
    XCTAssertEqual(connects.calls, 2)
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
      }
    ).reachability
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
      }, now: { connects.now }
    ).reachability
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
      }
    ).reachability
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
      startHost: { try await starts.connect($0) }, now: { connects.now }
    ).reachability
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
      }
    ).reachability
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
      startHost: { _ in connects.fail(false) }, now: { connects.now }
    ).reachability
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
      now: { connects.now }, relayHost: { try await relays.connect($0) }
    ).reachability
    let host = HostID.remote(UUID())

    await remote.installRelay(host, attempts: 1)
    XCTAssertEqual(relays.calls, 1)
    try await remote.ensureConnected(host)
    XCTAssertEqual(relays.calls, 1, "tried again inside its window")

    relays.fail(false)
    connects.advance(HostReachability.retryAfter)
    try await remote.ensureConnected(host)
    XCTAssertEqual(relays.calls, 2, "a later check didn't try again")
    connects.advance(HostReachability.retryAfter)
    try await remote.ensureConnected(host)
    XCTAssertEqual(relays.calls, 2, "tried again once it had taken")
  }

  // Value: protects=a workroom first recorded as relayed while its connection is up (its create
  // opened the connection before it was recorded) gets its relay at the next check;
  // fails_when=adopt marks the host relayed with no pending relay; why_new=the retry test starts
  // from a failed install, never from adopt; seam=none
  /// A workroom first recorded as relayed while its host is connected already gets its relay at
  /// the next connection check: nothing else would install it before a reconnect.
  func testARelayedWorkroomAdoptedWhileConnectedGetsItsRelay() async throws {
    let clock = Connects()
    let relays = Connects()
    relays.hold(false)
    let remoteHosts = RemoteHosts(
      connectHost: { _ in }, isConnected: { _ in true }, startHost: { _ in },
      now: { clock.now }, relayHost: { try await relays.connect($0) })
    let remote = remoteHosts.reachability
    let id = UUID()
    remoteHosts.reachability.adopt([
      Project(
        path: "/proj", vcs: "git",
        workrooms: [
          Workroom(
            name: "w", path: "/home/exedev/r", vcsName: "workroom/w", warnings: [],
            host: HostDescriptor(
              driver: HostKind.exeDev.driver, provisioner: RemoteWorkrooms.provisioner,
              id: id, credentials: "relay", account: "me@x.dev"))
        ])
    ])

    try await remote.ensureConnected(.remote(id))
    XCTAssertEqual(relays.calls, 1, "the relay was never installed")
    clock.advance(HostReachability.retryAfter)
    try await remote.ensureConnected(.remote(id))
    XCTAssertEqual(relays.calls, 1, "installed again once it had taken")
  }

  // MARK: The gh token on a host (ADR 0072)

  /// A driver whose hosts carry the Mac's gh token: records each refresh, and fails them or not.
  private final class TokenCarrier: HostTerminalDriver, GitHubTokenCarrying, Sendable {
    private let state = Mutex((refreshes: [HostID](), failing: false))
    var refreshes: [HostID] { state.withLock { $0.refreshes } }
    func fail(_ on: Bool) { state.withLock { $0.failing = on } }
    func refreshGitHubToken(on host: HostID) async throws {
      let failing = state.withLock {
        $0.refreshes.append(host)
        return $0.failing
      }
      if failing { throw HostDriverError.provisioning("the relay dropped the login") }
    }
    func openStream(to host: HostID) async throws -> HostStream {
      throw HostDriverError.provisioning("no stream")
    }
    func exec(_ command: String, on host: HostID) async throws -> HostStream {
      throw HostDriverError.provisioning("no exec")
    }
    func attachCommand(
      to host: HostID, session: UUID, workingDirectory: String, restored: Bool,
      metadata: [(key: String, value: String)], runCommand: String?
    ) throws -> String { "" }
    func hostRefusedLastAttach(of session: UUID, on host: HostID) -> Bool { false }
    func lastAttach(of session: UUID, on host: HostID) -> LastAttach { .finished }
  }

  // Value: protects=a gh token the user rotated or revoked doesn't live on in a Railway host
  // (ADR 0072, #631); fails_when=a connect skips the host's token, or a token write that fails
  // takes the workroom's connection down with it; seam=HostReachability.connect over a FakeDaemon
  /// Every connect to a host whose git carries the Mac's gh token refreshes it there; a refresh
  /// that fails leaves the connection up.
  func testEveryConnectRefreshesTheHostsGitHubToken() async throws {
    let fake = try FakeDaemon(version: 4)
    defer { fake.stop() }
    let remote = RemoteHosts(
      connectDaemon: { host, _ in
        try await DaemonClient.connect(host: host, socketPath: fake.socketPath)
      }, pendingIn: nil
    ).reachability
    let driver = TokenCarrier()
    let host = HostID.remote(UUID())

    try await remote.connect(host, driver: driver)
    XCTAssertEqual(driver.refreshes, [host])
    await remote.disconnect(host)

    driver.fail(true)
    try await remote.connect(host, driver: driver)
    XCTAssertEqual(driver.refreshes, [host, host], "a reconnect didn't refresh the token")
    let snapshot = await HostConnectionManager.shared.snapshot(for: host)
    XCTAssertEqual(snapshot.status, .connected, "a failed refresh dropped the connection")
    await remote.disconnect(host)
  }
}
