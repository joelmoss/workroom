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

  /// Waits for `semaphore`, at most ten seconds: a synchronous wait, for a detached task.
  private static func block(on semaphore: DispatchSemaphore) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + 10)
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

  /// Value: protects=the views learn when a host goes and when it comes back, so a gone workroom
  /// offers only Remove Workroom and its panes stop attaching (#629 story 26); fails_when=a gone
  /// read isn't reported, is reported again on every read, or a host found again stays gone;
  /// seam=HostReachability's gone hook, presence stubbed
  func testAHostGoingAndComingBackIsReportedOnce() async throws {
    let connects = Connects()
    connects.hold(false)
    let asked = Asleep()
    let reported = Mutex<[Bool]>([])
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in }, now: { connects.now }, presence: { _ in asked.answer() },
      goneChanged: { _, gone, _ in reported.withLock { $0.append(gone) } }
    ).reachability
    let id = UUID()
    let host = HostID.remote(id)
    // A Railway workroom, whose driver says whether its host is there.
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

    // Background reads, each past the last one's window, so each asks the provider again.
    asked.set(presence: .gone)
    for _ in 0..<2 {
      try? await remote.ensureConnected(host)
      connects.advance(HostReachability.retryAfter + .seconds(1))
    }
    XCTAssertEqual(asked.calls, 2)
    XCTAssertEqual(reported.withLock { $0 }, [true])

    asked.set(presence: .awake)
    try await remote.ensureConnected(host)
    XCTAssertEqual(reported.withLock { $0 }, [true, false])
  }

  /// Value: protects=the two signed-out cells no test held (review 5, D2.11): inside a failed
  /// connect's backoff window a background read answers from the backoff, asking Railway nothing;
  /// past it, it asks and says signed out, connecting nothing; and an opened workroom's connect
  /// that succeeds while signed out clears the backoff, so the next background read says signed
  /// out rather than unreachable; fails_when=a read inside the window asks Railway or connects,
  /// a signed-out background read connects, or a connect that worked leaves the host backed off;
  /// seam=HostReachability with presence and the connect stubbed
  func testASignedOutRailwayHostInsideItsBackoffAndAfterAConnectThatWorks() async throws {
    let connects = Connects()
    connects.hold(false)
    let asked = Asleep()
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in }, now: { connects.now }, presence: { _ in asked.answer() }
    ).reachability
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
    func read() async -> RepositoryRoutingError? {
      do {
        try await remote.ensureConnected(host)
        return nil
      } catch {
        return error as? RepositoryRoutingError
      }
    }

    // A connect that failed starts the backoff.
    asked.set(presence: .awake)
    connects.fail(true)
    _ = await read()
    XCTAssertEqual(connects.calls, 1)
    let before = asked.calls

    // Signed out, inside the window: the backoff answers, and Railway isn't asked.
    asked.set(presence: .signedOut)
    let inside = await read()
    XCTAssertEqual(inside, .unavailable(host))
    XCTAssertEqual(asked.calls, before, "a read inside the backoff asked Railway")
    XCTAssertEqual(connects.calls, 1)

    // Past it: Railway is asked, says signed out, and nothing connects.
    connects.advance(HostReachability.retryAfter + .seconds(1))
    let past = await read()
    XCTAssertEqual(past, .signedOut(host))
    XCTAssertEqual(asked.calls, before + 1)
    XCTAssertEqual(connects.calls, 1, "a signed-out background read connected")

    // Backed off afresh, then the user opens it: its connect works though signed out, and clears
    // the backoff, still inside its window.
    asked.set(presence: .awake)
    _ = await read()
    XCTAssertEqual(connects.calls, 2)
    asked.set(presence: .signedOut)
    connects.fail(false)
    remote.activate(host)
    try await remote.ensureConnected(host)
    XCTAssertEqual(connects.calls, 3)
    let after = await read()
    XCTAssertEqual(after, .signedOut(host), "a connect that worked left the host backed off")
  }

  /// Value: protects=a gone update and a found one that race reach the views in the order the
  /// state changed, whichever callback runs first: each is numbered under the lock that orders
  /// the change (review 5, D2.8); fails_when=the change that happened last carries the lower
  /// number, so `GoneHosts` keeps the stale one; seam=HostReachability's gone hook, the gone
  /// callback held until the found one has run
  func testRacingGoneAndFoundUpdatesAreNumberedInTheOrderTheyHappened() async throws {
    let connects = Connects()
    connects.hold(false)
    let asked = Asleep()
    let reported = Mutex<[(gone: Bool, sequence: UInt64)]>([])
    let goneEntered = DispatchSemaphore(value: 0)
    let foundDone = DispatchSemaphore(value: 0)
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in false },
      startHost: { _ in }, now: { connects.now }, presence: { _ in asked.answer() },
      goneChanged: { _, gone, sequence in
        if gone {
          goneEntered.signal()
          // The found update overtakes this one's callback.
          _ = foundDone.wait(timeout: .now() + 10)
        }
        reported.withLock { $0.append((gone, sequence)) }
        if !gone { foundDone.signal() }
      }
    ).reachability
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

    asked.set(presence: .gone)
    let goneRead = Task.detached { try? await remote.ensureConnected(host) }
    let entered = await Task.detached { Self.block(on: goneEntered) }.value
    XCTAssertEqual(entered, .success, "the gone update never came")
    asked.set(presence: .awake)
    remote.activate(host)
    try await remote.ensureConnected(host, wake: true)
    await goneRead.value

    let calls = reported.withLock { $0 }
    XCTAssertEqual(calls.map(\.gone), [false, true], "the callbacks didn't race as staged")
    let last = try XCTUnwrap(calls.max { $0.sequence < $1.sequence })
    XCTAssertFalse(last.gone, "the found update, which happened last, carries the lower number")
  }

  /// Value: protects=a host that connects is not gone, whatever an earlier read said, so a boxd box
  /// read as gone in another account comes back once the user opens it (review #3);
  /// fails_when=gone is cleared only by a presence read, which a click on a box that sleeps never
  /// makes, or a host already connected keeps reading as gone; seam=HostReachability's gone hook,
  /// presence and the connect stubbed
  func testAHostThatConnectsIsNoLongerGone() async throws {
    let connects = Connects()
    connects.hold(false)
    let asked = Asleep()
    let reported = Mutex<[Bool]>([])
    let up = Mutex(false)
    let remote = RemoteHosts(
      connectHost: { try await connects.connect($0) }, isConnected: { _ in up.withLock { $0 } },
      startHost: { _ in }, now: { connects.now }, presence: { _ in asked.answer() },
      goneChanged: { _, gone, _ in reported.withLock { $0.append(gone) } }
    ).reachability
    let id = UUID()
    let host = HostID.remote(id)
    remote.adopt([
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

    asked.set(presence: .gone)
    try? await remote.ensureConnected(host)
    XCTAssertEqual(reported.withLock { $0 }, [true])

    // A click: a box that sleeps isn't asked about first, and the connect goes through.
    try await remote.ensureConnected(host, wake: true)
    XCTAssertEqual(connects.calls, 1)
    XCTAssertEqual(reported.withLock { $0 }, [true, false], "a connected host stayed gone")

    // Gone again, then found connected by another way (a pane's attach): no longer gone either.
    connects.advance(HostReachability.retryAfter + .seconds(1))
    try? await remote.ensureConnected(host)
    XCTAssertEqual(reported.withLock { $0 }, [true, false, true])
    up.withLock { $0 = true }
    try await remote.ensureConnected(host)
    XCTAssertEqual(reported.withLock { $0 }, [true, false, true, false])
  }

  /// Value: protects=a host whose daemon stayed on protocol 10 (the bootstrap kept it) is updated
  /// once it can be, so its panes stop retrying forever, and they say why they wait meanwhile
  /// (review #2); fails_when=a healthy connection to an older daemon skips the bootstrap for good,
  /// the update is tried on every read rather than backed off, the connection isn't replaced once
  /// the daemon is new, or the pane's notice never says why; seam=HostReachability with the
  /// connect, version and bootstrap stubbed
  func testAnOlderDaemonIsUpdatedWithBackoffAndThePaneSaysWhy() async throws {
    struct State {
      var up = true
      var version: UInt16 = 10
      var outcomes: [DaemonBootstrap.Outcome.Daemon] = [.keptOlder("the hand-off was refused")]
      var updates = 0
    }
    let connects = Connects()
    connects.hold(false)
    let state = Mutex(State())
    let remote = RemoteHosts(
      connectHost: { host in
        try await connects.connect(host)
        state.withLock { $0.up = true }
      }, isConnected: { _ in state.withLock { $0.up } }, startHost: { _ in },
      now: { connects.now }, presence: { _ in .awake },
      daemonVersion: { _ in state.withLock { $0.version } },
      updateDaemon: { _ in
        state.withLock {
          $0.updates += 1
          guard $0.outcomes.isEmpty else { return $0.outcomes.removeFirst() }
          // Handed off: the old connection goes (the reachability disconnects it), and the next
          // greets with the new program's version.
          $0.up = false
          $0.version = DaemonHandshake.minHostAttachVersion
          return .handedOff
        }
      }
    ).reachability
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
    func settle(_ updates: Int) async throws {
      for _ in 0..<500 where state.withLock({ $0.updates }) < updates {
        try await Task.sleep(for: .milliseconds(2))
      }
      try await Task.sleep(for: .milliseconds(20))
    }

    // Connected to protocol 10: the update is tried, the daemon is kept, and the pane says why.
    try await remote.ensureConnected(host)
    try await settle(1)
    XCTAssertEqual(state.withLock { $0.updates }, 1)
    let notice = try XCTUnwrap(remote.waitingNotice(for: host))
    XCTAssertTrue(notice.contains("the hand-off was refused"), notice)

    // Within the backoff, reads don't try again.
    try await remote.ensureConnected(host)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(state.withLock { $0.updates }, 1, "tried again inside the backoff")

    // Past it, the bootstrap updates the daemon: the connection is replaced, and once it greets
    // with a version new enough the pane's notice goes.
    connects.advance(HostReachability.olderDaemonRetry + .seconds(1))
    try await remote.ensureConnected(host)
    try await settle(2)
    for _ in 0..<500 where connects.calls < 1 { try await Task.sleep(for: .milliseconds(2)) }
    XCTAssertEqual(connects.calls, 1, "the connection to the old daemon was kept")
    XCTAssertNil(remote.waitingNotice(for: host))
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
