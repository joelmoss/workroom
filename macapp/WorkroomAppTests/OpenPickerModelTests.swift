import WorkroomDomain
import XCTest

@testable import Workroom

/// The Open Workroom picker's target-building + filter core (issue #94). Roots resolve `isMissing`
/// against the real filesystem (`Project.rootTarget`), so the tests create real temp directories to
/// exercise the "hide missing targets" decision; workroom `isMissing` is driven by the CLI's
/// `DirectoryMissing` warning, so those are simulated with a warning. Mirrors `ProjectPickerModelTests`.
final class OpenPickerModelTests: XCTestCase {
  private var tmpRoot: URL!

  override func setUpWithError() throws {
    tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("openpicker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tmpRoot)
  }

  /// A project whose directory exists on disk (root will be included). `name` is its last path
  /// component (the displayName). `workrooms` are present unless listed in `missingWorkrooms`.
  private func realProject(
    _ name: String, workrooms: [String] = [], missingWorkrooms: [String] = []
  )
    throws -> Project
  {
    let dir = tmpRoot.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return Project(
      path: dir.path, vcs: "git",
      workrooms: workrooms.map { wr in
        let warnings =
          missingWorkrooms.contains(wr)
          ? [Warning(kind: "DirectoryMissing", message: "gone", path: nil, vcs: nil)] : []
        return Workroom(
          name: wr, path: "\(dir.path)/\(wr)", vcsName: "workroom/\(wr)", warnings: warnings)
      })
  }

  /// A project whose directory does NOT exist (root excluded as missing).
  private func missingProject(_ name: String, workrooms: [String] = []) -> Project {
    let path = tmpRoot.appendingPathComponent("absent-\(name)").path
    return Project(
      path: path, vcs: "git",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "workroom/\($0)", warnings: [])
      })
  }

  // MARK: targets

  func testRootFirstThenWorkroomsInOrder() throws {
    let p = try realProject("alpha", workrooms: ["one", "two"])
    let targets = OpenPickerModel.targets(from: [p])

    XCTAssertEqual(targets.map(\.title), ["alpha", "one", "two"])
    XCTAssertEqual(targets.map(\.isRoot), [true, false, false])
  }

  func testRowsCarryProjectName() throws {
    let p = try realProject("alpha", workrooms: ["one"])
    let targets = OpenPickerModel.targets(from: [p])

    XCTAssertEqual(targets[0].projectName, "alpha")  // root
    XCTAssertEqual(targets[1].projectName, "alpha")  // workroom (header/grouping key)
  }

  func testWorkroomsSortedAlphabetically() throws {
    let p = try realProject("alpha", workrooms: ["two", "Apple", "one"])
    let targets = OpenPickerModel.targets(from: [p])

    // Root first, then workrooms case-insensitively sorted (config order ignored).
    XCTAssertEqual(targets.map(\.title), ["alpha", "Apple", "one", "two"])
  }

  func testEmptyProjectYieldsRootOnly() throws {
    let p = try realProject("solo")
    let targets = OpenPickerModel.targets(from: [p])

    XCTAssertEqual(targets.map(\.title), ["solo"])
    XCTAssertTrue(targets[0].isRoot)
  }

  func testMissingRootExcluded() {
    let p = missingProject("ghost", workrooms: ["wr"])
    let targets = OpenPickerModel.targets(from: [p])

    // Root excluded (dir absent); the workroom (no warning) is still offered.
    XCTAssertEqual(targets.map(\.title), ["wr"])
    XCTAssertFalse(targets[0].isRoot)
  }

  func testMissingWorkroomExcluded() throws {
    let p = try realProject("alpha", workrooms: ["ok", "gone"], missingWorkrooms: ["gone"])
    let targets = OpenPickerModel.targets(from: [p])

    XCTAssertEqual(targets.map(\.title), ["alpha", "ok"])  // "gone" filtered out
  }

  func testAllMissingYieldsEmpty() {
    let targets = OpenPickerModel.targets(from: [missingProject("ghost")])
    XCTAssertTrue(targets.isEmpty)
  }

  func testTargetsSpanMultipleProjectsInOrder() throws {
    let a = try realProject("alpha", workrooms: ["x"])
    let b = try realProject("bravo")
    let targets = OpenPickerModel.targets(from: [a, b])

    XCTAssertEqual(targets.map(\.title), ["alpha", "x", "bravo"])
  }

  // MARK: grouped

  func testGroupedPreservesProjectOrderAndRootFirst() throws {
    let a = try realProject("alpha", workrooms: ["w"])
    let b = try realProject("bravo")
    let groups = OpenPickerModel.grouped(OpenPickerModel.targets(from: [a, b]))

    XCTAssertEqual(groups.map(\.projectName), ["alpha", "bravo"])
    XCTAssertEqual(groups[0].rows.map(\.title), ["alpha", "w"])  // root then workroom
    XCTAssertEqual(groups[1].rows.map(\.title), ["bravo"])
  }

  func testGroupedDropsProjectsWithNoMatchingRows() throws {
    let a = try realProject("platform", workrooms: ["wr"])
    let b = try realProject("other", workrooms: ["thing"])
    let filtered = OpenPickerModel.filtered(
      OpenPickerModel.targets(from: [a, b]), query: "platform")

    // Only the "platform" group survives (its root + workroom carry the project name).
    XCTAssertEqual(OpenPickerModel.grouped(filtered).map(\.projectName), ["platform"])
  }

  // MARK: filtered

  func testEmptyQueryReturnsAll() throws {
    let targets = OpenPickerModel.targets(from: [try realProject("alpha", workrooms: ["one"])])
    XCTAssertEqual(OpenPickerModel.filtered(targets, query: "").count, 2)
  }

  func testFilterMatchesWorkroomName() throws {
    let targets = OpenPickerModel.targets(from: [try realProject("alpha", workrooms: ["fix-auth"])])
    XCTAssertEqual(OpenPickerModel.filtered(targets, query: "auth").map(\.title), ["fix-auth"])
  }

  func testFilterByProjectNameSurfacesItsWorkrooms() throws {
    let a = try realProject("platform", workrooms: ["wr"])
    let b = try realProject("other")
    let targets = OpenPickerModel.targets(from: [a, b])

    // "platform" matches the root (title) and the workroom (searchText carries the project name).
    let titles = OpenPickerModel.filtered(targets, query: "platform").map(\.title)
    XCTAssertEqual(Set(titles), ["platform", "wr"])
  }

  func testFilterIsCaseInsensitiveAndTrimmed() throws {
    let targets = OpenPickerModel.targets(from: [try realProject("Alpha")])
    XCTAssertEqual(OpenPickerModel.filtered(targets, query: "  alpha ").map(\.title), ["Alpha"])
  }

  func testNoMatchReturnsEmpty() throws {
    let targets = OpenPickerModel.targets(from: [try realProject("alpha", workrooms: ["one"])])
    XCTAssertTrue(OpenPickerModel.filtered(targets, query: "zzz").isEmpty)
  }

  // MARK: fuzzy + multi-token (issue #94 follow-up)

  /// The motivating example: project "projectA" with workroom "apple" matches "proapp".
  func testFuzzyCrossFieldSingleToken() throws {
    let targets = OpenPickerModel.targets(from: [try realProject("projectA", workrooms: ["apple"])])
    XCTAssertEqual(OpenPickerModel.filtered(targets, query: "proapp").map(\.title), ["apple"])
  }

  /// The multi-phrase example: "A app" matches "projectA" / "apple" via two AND-ed tokens.
  func testFuzzyMultiTokenAcrossFields() throws {
    let targets = OpenPickerModel.targets(from: [try realProject("projectA", workrooms: ["apple"])])
    XCTAssertEqual(OpenPickerModel.filtered(targets, query: "A app").map(\.title), ["apple"])
  }

  func testFuzzyTokenOrderIndependent() throws {
    let targets = OpenPickerModel.targets(from: [try realProject("projectA", workrooms: ["apple"])])
    XCTAssertEqual(OpenPickerModel.filtered(targets, query: "app A").map(\.title), ["apple"])
  }

  func testFuzzyAllTokensMustMatch() throws {
    let targets = OpenPickerModel.targets(from: [try realProject("projectA", workrooms: ["apple"])])
    XCTAssertTrue(OpenPickerModel.filtered(targets, query: "apple zzz").isEmpty)
  }

  // Core matcher, in isolation.

  func testFuzzyMatchesSubsequenceAcrossFields() {
    XCTAssertTrue(PickerModel.fuzzyMatches("projectA apple", query: "proapp"))
    XCTAssertTrue(PickerModel.fuzzyMatches("projectA apple", query: "A app"))
  }

  func testFuzzyMatchesRequiresInOrderWithinToken() {
    XCTAssertTrue(PickerModel.fuzzyMatches("apple", query: "ale"))
    XCTAssertFalse(PickerModel.fuzzyMatches("apple", query: "lea"))  // order matters within a token
  }

  func testFuzzyMatchesIsCaseInsensitive() {
    XCTAssertTrue(PickerModel.fuzzyMatches("ProjectA", query: "pja"))
  }

  func testFuzzyMatchesEmptyQueryMatches() {
    XCTAssertTrue(PickerModel.fuzzyMatches("anything", query: "   "))
  }

  func testFuzzyMatchesFailsWhenACharIsMissing() {
    XCTAssertFalse(PickerModel.fuzzyMatches("apple", query: "appz"))
  }

  // MARK: selection guard

  func testSelectionNilOnEmpty() {
    XCTAssertNil(OpenPickerModel.selection(filtered: [], highlight: 0))
  }
}
