import XCTest

@testable import Workroom

/// Older builds' base machines go at launch (#395 follow-up): each this build owns is destroyed
/// and dropped from its project's record, after its workrooms have recorded its repository.
final class BaseRetirementTests: XCTestCase {
  private let mine = RemoteWorkrooms.provisioner

  /// What the effects did, in order.
  private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var all: [String] { lock.withLock { entries } }
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
  }

  private func effects(_ log: Log, failing: Set<UUID> = []) -> BaseRetirement.Effects {
    BaseRetirement.Effects(
      setHost: { project, workroom, descriptor in
        let what =
          descriptor.map { d in
            d.bases.map { "bases " + $0.compactMap(\.id).map(\.uuidString).joined(separator: ",") }
              ?? (d.repository.map { "repository \($0)" } ?? "base \(d.id?.uuidString ?? "?")")
          } ?? "nil"
        log.add("set \(workroom ?? project) \(what)")
      },
      destroy: { base in
        if let id = base.id, failing.contains(id) { throw RemoteWorkrooms.Failure.signedOut }
        log.add("destroy \(base.id?.uuidString ?? "?")")
      })
  }

  private func base(_ driver: String, repository: String? = nil, provisioner: String? = nil)
    -> HostDescriptor
  {
    HostDescriptor(
      driver: driver, provisioner: provisioner ?? mine, id: UUID(), repository: repository)
  }

  /// A project before #309 records one base as its descriptor: it goes, and so does the record.
  func testASingleBaseIsDestroyedAndItsRecordCleared() async throws {
    let log = Log()
    let only = base("container")
    let project = Project(path: "/p", vcs: "git", workrooms: [], host: only)

    let changed = await BaseRetirement.retire([project], effects: effects(log))

    XCTAssertTrue(changed)
    XCTAssertEqual(log.all, ["destroy \(only.id!.uuidString)", "set /p nil"])
  }

  /// A project with a base per runtime (#309) loses them one by one, its record rewritten each time
  /// so a failure part-way leaves only what is still live recorded.
  func testEveryBaseOfAMultiBaseProjectGoes() async throws {
    let log = Log()
    let (docker, apple) = (base("container"), base("apple-container"))
    let project = Project(
      path: "/p", vcs: "git", workrooms: [], host: HostDescriptor(bases: [docker, apple]))

    _ = await BaseRetirement.retire([project], effects: effects(log))

    XCTAssertEqual(
      log.all,
      [
        "destroy \(docker.id!.uuidString)", "set /p base \(apple.id!.uuidString)",
        "destroy \(apple.id!.uuidString)", "set /p nil",
      ])
  }

  /// A base that can't be taken down keeps its record; the project's other bases still go.
  func testABaseThatFailsKeepsItsRecordAndTheOthersGo() async throws {
    let log = Log()
    let (docker, apple) = (base("container"), base("apple-container"))
    let project = Project(
      path: "/p", vcs: "git", workrooms: [], host: HostDescriptor(bases: [docker, apple]))

    _ = await BaseRetirement.retire([project], effects: effects(log, failing: [docker.id!]))

    XCTAssertEqual(
      log.all, ["destroy \(apple.id!.uuidString)", "set /p base \(docker.id!.uuidString)"])
  }

  /// Signed out of every provider: nothing is destroyed and nothing is cleared, for the next launch.
  func testSignedOutLeavesEverythingRecorded() async throws {
    let log = Log()
    let only = base("container")
    let project = Project(path: "/p", vcs: "git", workrooms: [], host: only)

    let changed = await BaseRetirement.retire([project], effects: effects(log, failing: [only.id!]))

    XCTAssertFalse(changed)
    XCTAssertEqual(log.all, [])
  }

  /// Another build's base is that build's to retire.
  func testAnotherBuildsBaseIsLeft() async throws {
    let log = Log()
    let theirs = base("container", provisioner: "another.build")
    let project = Project(path: "/p", vcs: "git", workrooms: [], host: theirs)

    let changed = await BaseRetirement.retire([project], effects: effects(log))

    XCTAssertFalse(changed)
    XCTAssertEqual(log.all, [])
  }

  /// Before its base goes, each workroom an older build derived from it records the base's
  /// repository, which is where its PR and CI status came from; one with its own keeps it.
  func testWorkroomsRecordTheirBasesRepositoryBeforeTheBaseGoes() async throws {
    let log = Log()
    let (docker, apple) = (
      base("container", repository: "o/old"), base("apple-container", repository: "o/new")
    )
    let workroom = { (name: String, driver: String, repository: String?) in
      Workroom(
        name: name, path: "/home/workroom/r", vcsName: "workroom/\(name)", warnings: [],
        host: HostDescriptor(
          driver: driver, provisioner: self.mine, id: UUID(), repository: repository))
    }
    let project = Project(
      path: "/p", vcs: "git",
      workrooms: [
        workroom("d", "container", nil), workroom("a", "apple-container", nil),
        workroom("own", "container", "o/own"),
      ],
      host: HostDescriptor(bases: [docker, apple]))

    _ = await BaseRetirement.retire([project], effects: effects(log))

    XCTAssertEqual(
      Array(log.all.prefix(3)),
      ["set d repository o/old", "set a repository o/new", "destroy \(docker.id!.uuidString)"])
  }

  /// Descriptors from before the `driver` field are Docker's, as `deletionKey` reads them: such a
  /// workroom still records its base's repository before the base goes.
  func testADriverlessWorkroomRecordsItsDriverlessBasesRepository() async throws {
    let log = Log()
    let old = HostDescriptor(provisioner: mine, id: UUID(), repository: "o/r")
    let project = Project(
      path: "/p", vcs: "git",
      workrooms: [
        Workroom(
          name: "w", path: "/home/workroom/r", vcsName: "workroom/w", warnings: [],
          host: HostDescriptor(provisioner: mine, id: UUID()))
      ],
      host: old)

    _ = await BaseRetirement.retire([project], effects: effects(log))

    XCTAssertEqual(log.all.first, "set w repository o/r")
  }

  /// A workroom whose repository can't be recorded keeps its project's base, so its status isn't
  /// lost: the next launch tries again.
  func testAFailedStampKeepsTheBase() async throws {
    let log = Log()
    let docker = base("container", repository: "o/r")
    let project = Project(
      path: "/p", vcs: "git",
      workrooms: [
        Workroom(
          name: "w", path: "/home/workroom/r", vcsName: "workroom/w", warnings: [],
          host: HostDescriptor(driver: "container", provisioner: mine, id: UUID()))
      ],
      host: docker)
    var failing = effects(log)
    failing.setHost = { _, workroom, _ in
      if workroom != nil { throw WorkroomCLIError.timedOut }
      log.add("set project")
    }

    let changed = await BaseRetirement.retire([project], effects: failing)

    XCTAssertFalse(changed)
    XCTAssertEqual(log.all, [])
  }
}
