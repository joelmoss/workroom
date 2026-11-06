import Combine
import HostDrivers
import WorkroomDomain
import XCTest

@testable import Workroom

/// How a host option's choices read and what each saves (#575): the same rules in Settings and
/// Project Settings, so Inherit and Provider default never read as two ways to the same thing.
final class HostOptionChoicesTests: XCTestCase {
  typealias Choices = HostOptionChoices<Int>

  /// Value: protects=the provider's default reads "(default)" and, at Settings, saves nothing;
  /// fails_when=it is listed twice or saved as a value; why_new=new rules; seam=none;
  /// no_claim=the picker's rendering
  func testAtSettingsTheDefaultIsItsOwnRowAndSavesNothing() {
    let choices = Choices(providerDefault: 2, below: nil)
    XCTAssertEqual(choices.mark(for: 2), "default")
    XCTAssertNil(choices.mark(for: 4))
    XCTAssertEqual(choices.stored(for: 2), .inherit)
    XCTAssertEqual(choices.stored(for: 4), .value(4))
    XCTAssertFalse(choices.needsProviderDefaultRow(among: [1, 2, 4]))
  }

  /// A project that Settings leaves alone gets the provider's default: one "(default)" row, which
  /// saves nothing, and no second Provider default choice.
  func testWithNothingInSettingsTheDefaultRowFollowsSettings() {
    let choices = Choices(providerDefault: 2, below: .init(value: nil, source: nil))
    XCTAssertEqual(choices.mark(for: 2), "default")
    XCTAssertEqual(choices.stored(for: 2), .inherit)
    XCTAssertEqual(choices.selection(of: .providerDefault), .inherit)
  }

  /// Settings' own value reads "(app)" and saves nothing, so the project follows Settings; the
  /// provider's default is then a real choice of its own.
  func testSettingsValueReadsAppAndTheDefaultIsAChoice() {
    let choices = Choices(providerDefault: 2, below: .init(value: 4, source: .settings))
    XCTAssertEqual(choices.mark(for: 4), "app")
    XCTAssertEqual(choices.stored(for: 4), .inherit)
    XCTAssertEqual(choices.mark(for: 2), "default")
    XCTAssertEqual(choices.stored(for: 2), .providerDefault)
    XCTAssertEqual(choices.selection(of: .providerDefault), .providerDefault)
    XCTAssertEqual(choices.selection(of: .value(4)), .inherit)
  }

  /// A Settings value that is also the provider's default reads only "(default)".
  func testASettingsValueThatIsTheDefaultReadsOnlyDefault() {
    let choices = Choices(providerDefault: 2, below: .init(value: 2, source: .settings))
    XCTAssertEqual(choices.mark(for: 2), "default")
    XCTAssertEqual(choices.stored(for: 2), .inherit)
  }

  /// A default the provider doesn't say (exe.dev memory) keeps a Provider default row: saving
  /// nothing when nothing is inherited, and Provider default when Settings names a value.
  func testAnUnknownDefaultKeepsItsOwnRow() {
    XCTAssertTrue(Choices(providerDefault: nil, below: nil).needsProviderDefaultRow(among: [4]))
    XCTAssertEqual(
      Choices(providerDefault: nil, below: .init(value: nil, source: nil)).providerDefaultStored,
      .inherit)
    let choices = Choices(providerDefault: nil, below: .init(value: 4, source: .project))
    XCTAssertEqual(choices.providerDefaultStored, .providerDefault)
    XCTAssertEqual(choices.mark(for: 4), "project")
  }
}

/// A project's saved host options, read and written in one place (#575).
final class ProjectHostOptionsTests: XCTestCase {
  /// Value: protects=empty options are never saved, and a project with none left has no entry;
  /// fails_when=an empty provider or project entry stays in the map; why_new=shared helper;
  /// seam=none; no_claim=Defaults' storage
  func testEmptyOptionsLeaveNoEntryBehind() {
    var saved: [String: [String: HostOptions]] = [:]
    saved[project: "/a", provider: .boxd] = HostOptions(cpu: .value(2))
    saved[project: "/a", provider: .exeDev] = HostOptions(disk: .value("50GB"))
    XCTAssertEqual(saved[project: "/a", provider: .boxd], HostOptions(cpu: .value(2)))

    saved[project: "/a", provider: .boxd] = HostOptions()
    XCTAssertEqual(saved["/a"]?.keys.sorted(), ["exeDev"], "empty boxd options were kept")
    saved[project: "/a", provider: .exeDev] = nil
    XCTAssertNil(saved["/a"], "a project with no options left kept its entry")
  }
}

/// The host option catalog every Settings pane and the Configure… panel share (#575).
@MainActor
final class HostOptionsCatalogTests: XCTestCase {
  /// Value: protects=moving between Remote Hosts, Projects and Configure… reuses a read under two
  /// minutes old, a failed read is retried, and Settings opening reads afresh; fails_when=a fresh
  /// read is repeated, an old or failed one kept, Settings opening reads nothing itself, or the
  /// next read after it is skipped; why_new=shared catalog;
  /// seam=the catalog's clock and fetch; no_claim=the providers' own reads
  func testAGoodReadIsReusedForTwoMinutesAndAFailedOneIsRetried() async {
    let catalog = HostOptionsCatalog()
    var clock = Date(timeIntervalSince1970: 0)
    var reads: [HostKind] = []
    var works = true
    catalog.now = { clock }
    catalog.fetch = { provider in
      reads.append(provider)
      return works ? .boxd(snapshots: ["base"], size: nil) : .failed("unreachable")
    }

    await catalog.load(.boxd)
    await catalog.load(.boxd)
    XCTAssertEqual(reads, [.boxd], "a fresh read was repeated")
    XCTAssertTrue(catalog.finished.contains(.boxd))
    XCTAssertEqual(catalog.snapshots, ["base"])

    clock += HostOptionsCatalog.freshFor + 1
    await catalog.load(.boxd)
    XCTAssertEqual(reads.count, 2, "a read over two minutes old was kept")

    catalog.markStale()
    XCTAssertEqual(reads.count, 2, "Settings opening read a provider no section asked for")
    await catalog.load(.boxd)
    await catalog.load(.exeDev)
    XCTAssertEqual(reads.count, 4, "a section after Settings opened didn't read afresh")

    works = false
    clock += HostOptionsCatalog.freshFor + 1
    await catalog.load(.exeDev)
    await catalog.load(.exeDev)
    XCTAssertEqual(reads.filter { $0 == .exeDev }.count, 3, "a failed read was kept")
    XCTAssertEqual(catalog.failure[.exeDev], "unreachable")
  }

  /// Value: protects=leaving the screen that started a read neither cuts it short (a false
  /// "isn't set up") nor strands another screen waiting on it; fails_when=the read is the asking
  /// screen's task, so its cancel fails the read or a second screen returns before it lands;
  /// why_new=review findings (Claude adversarial, Red Team); seam=the catalog's fetch;
  /// no_claim=the drivers' own cancellation
  func testAReadOutlivesTheScreenThatStartedItAndOthersWaitOnIt() async {
    let catalog = HostOptionsCatalog()
    let state = ReadState()
    catalog.fetch = { _ in
      state.reads += 1
      while !state.released { await Task.yield() }
      return Task.isCancelled
        ? .failed("boxd isn't set up, or couldn't be reached: cancelled.")
        : .boxd(snapshots: ["base"], size: nil)
    }

    // A screen starts the read, then goes away.
    let leaving = Task { await catalog.load(.boxd) }
    while state.reads == 0 { await Task.yield() }
    leaving.cancel()
    // Another screen asks while it's under way.
    let waiting = Task {
      await catalog.load(.boxd)
      state.waiterReturned = true
    }
    for _ in 0..<20 { await Task.yield() }
    XCTAssertFalse(state.waiterReturned, "the waiting screen returned before the read landed")

    state.released = true
    await waiting.value
    await leaving.value
    XCTAssertEqual(state.reads, 1, "the waiting screen started its own read")
    XCTAssertNil(catalog.failure[.boxd], "the leaving screen's cancel failed the read")
    XCTAssertEqual(catalog.snapshots, ["base"])
    XCTAssertTrue(catalog.finished.contains(.boxd))
  }

  @MainActor private final class ReadState {
    var reads = 0
    var released = false
    var waiterReturned = false
  }

  /// Value: protects=a failed boxd read is retried and an exe.dev plan is kept two minutes then
  /// read again; fails_when=boxd's failure is kept or the plan is re-read early or kept late;
  /// why_new=review finding (state machines); seam=the catalog's clock and fetch;
  /// no_claim=the providers' own reads
  func testEachProvidersReadIsRetriedOrKeptOnItsOwn() async {
    let catalog = HostOptionsCatalog()
    var clock = Date(timeIntervalSince1970: 0)
    var reads: [HostKind] = []
    let plan = ExeDevHostDriver.PlanLimits(
      maxCPUs: 4, maxMemoryGB: 16, defaultDiskGB: 25, maxDiskGB: 100)
    catalog.now = { clock }
    catalog.fetch = { provider in
      reads.append(provider)
      return provider == .boxd ? .failed("boxd isn't installed yet.") : .exeDev(plan)
    }

    await catalog.load(.boxd)
    await catalog.load(.boxd)
    XCTAssertEqual(reads.filter { $0 == .boxd }.count, 2, "a failed boxd read was kept")
    XCTAssertEqual(catalog.failure[.boxd], "boxd isn't installed yet.")

    await catalog.load(.exeDev)
    await catalog.load(.exeDev)
    XCTAssertEqual(catalog.plan, plan)
    XCTAssertEqual(reads.filter { $0 == .exeDev }.count, 1, "a fresh plan was read again")
    clock += HostOptionsCatalog.freshFor + 1
    await catalog.load(.exeDev)
    XCTAssertEqual(reads.filter { $0 == .exeDev }.count, 2, "an old plan was kept")
  }

  /// Value: protects=a read's findings land together, so its sections redraw once rather than
  /// mid-way with half the values; fails_when=the catalog changes more than once per read;
  /// why_new=batched updates; seam=the catalog's fetch; no_claim=SwiftUI's own coalescing
  func testAReadChangesTheCatalogOnce() async {
    let catalog = HostOptionsCatalog()
    catalog.fetch = { _ in .boxd(snapshots: ["base"], size: nil) }
    var changes = 0
    let watch = catalog.objectWillChange.sink { changes += 1 }
    defer { watch.cancel() }

    await catalog.load(.boxd)

    XCTAssertEqual(changes, 1, "a read changed the catalog \(changes) times")
  }
}
