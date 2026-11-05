import Foundation
import WorkroomDomain
import XCTest

final class HostOptionsTests: XCTestCase {
  /// Each key resolves on its own: this create, then the project, then Settings, then the
  /// provider's default. Provider default at a level stops the walk with no value.
  func testEachKeyResolvesFromTheMostSpecificLevelThatSetsIt() {
    let settings = HostOptions(
      image: .value("settings/image"), cpu: .value(2), memory: .value("4GB"), disk: .value("20GB"))
    let project = HostOptions(image: .value("project/image"), memory: .providerDefault)
    let create = HostOptions(cpu: .value(8))

    let resolved = HostOptions.resolve(
      for: .exeDev, create: create, project: project, settings: settings)

    XCTAssertEqual(resolved.image, .init(value: "project/image", source: .project))
    XCTAssertEqual(resolved.cpu, .init(value: 8, source: .create))
    XCTAssertEqual(resolved.memory, .init(value: nil, source: .project))
    XCTAssertEqual(resolved.disk, .init(value: "20GB", source: .settings))
    XCTAssertEqual(
      resolved.options, ResolvedHostOptions(image: "project/image", cpu: 8, disk: "20GB"))
  }

  func testNothingSetAnywhereIsTheProvidersDefault() {
    let resolved = HostOptions.resolve(for: .exeDev, create: nil, project: nil, settings: nil)
    XCTAssertEqual(resolved.image, .init(value: nil, source: nil))
    XCTAssertEqual(resolved.options, ResolvedHostOptions())
    XCTAssertTrue(resolved.options.isProviderDefault)
  }

  /// boxd refuses a size with a snapshot, and has no memory or disk of its own to choose.
  func testABoxdSnapshotResolvesSizeToNothing() {
    let settings = HostOptions(cpu: .value(4), memory: .value("16G"), disk: .value("50GB"))
    let project = HostOptions(image: .value("prepared"))

    let resolved = HostOptions.resolve(
      for: .boxd, create: nil, project: project, settings: settings)

    XCTAssertEqual(resolved.options, ResolvedHostOptions(image: "prepared"))
    XCTAssertEqual(resolved.cpu, .init(value: nil, source: nil))
    XCTAssertTrue(resolved.sizeTakenBySnapshot)
  }

  func testABoxdFreshMachineTakesOnlyItsSize() {
    let settings = HostOptions(cpu: .value(4), memory: .value("16G"), disk: .value("50GB"))
    let resolved = HostOptions.resolve(
      for: .boxd, create: HostOptions(image: .providerDefault), project: nil, settings: settings)
    XCTAssertEqual(resolved.options, ResolvedHostOptions(cpu: 4))
    XCTAssertFalse(resolved.sizeTakenBySnapshot)
  }

  /// Remember for this project saves only what the Options panel set; the project keeps the rest.
  func testRememberingSavesOnlyTheFieldsSet() {
    let project = HostOptions(image: .value("old"), disk: .value("50GB"))
    let panel = HostOptions(image: .providerDefault, cpu: .value(4))
    XCTAssertEqual(
      panel.overlaid(on: project),
      HostOptions(image: .providerDefault, cpu: .value(4), disk: .value("50GB")))
  }

  /// What `Defaults` stores is a contract: a saved value must read back after an upgrade.
  func testStoredOptionsDecode() throws {
    let stored = #"{"image":{"value":{"_0":"x/y"}},"cpu":{"providerDefault":{}}}"#
    let options = try JSONDecoder().decode(HostOptions.self, from: Data(stored.utf8))
    XCTAssertEqual(options, HostOptions(image: .value("x/y"), cpu: .providerDefault))
  }

  /// Story 39: a host recorded before host options decodes as it did.
  func testAHostDescriptorWithoutMadeWithDecodes() throws {
    let old = try JSONDecoder().decode(
      HostDescriptor.self, from: Data(#"{"driver":"boxd","state":"ready"}"#.utf8))
    XCTAssertEqual(old.driver, "boxd")
    XCTAssertNil(old.madeWith)

    var made = old
    made.madeWith = ResolvedHostOptions(image: "snap", cpu: 2)
    let again = try JSONDecoder().decode(HostDescriptor.self, from: JSONEncoder().encode(made))
    XCTAssertEqual(again.madeWith, ResolvedHostOptions(image: "snap", cpu: 2))
  }
}
