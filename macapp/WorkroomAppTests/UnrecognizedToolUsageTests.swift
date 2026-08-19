import XCTest

@testable import Workroom

final class UnrecognizedToolUsageTests: XCTestCase {
  private var url: URL!

  override func setUp() {
    super.setUp()
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("UnrecognizedToolUsageTests-\(UUID().uuidString).json")
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: url)
    super.tearDown()
  }

  func testRecordsAndIncrementsDistinctCounts() {
    UnrecognizedToolUsage.recordUnrecognized("foo", url: url)
    UnrecognizedToolUsage.recordUnrecognized("foo", url: url)
    UnrecognizedToolUsage.recordUnrecognized("bar", url: url)

    let data = try! Data(contentsOf: url)
    let counts = try! JSONDecoder().decode([String: Int].self, from: data)
    XCTAssertEqual(counts["foo"], 2)
    XCTAssertEqual(counts["bar"], 1)
  }

  func testCreatesIntermediateDirectories() {
    let nested = FileManager.default.temporaryDirectory
      .appendingPathComponent("UnrecognizedToolUsageTests-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("nested", isDirectory: true)
      .appendingPathComponent("usage.json")
    defer { try? FileManager.default.removeItem(at: nested) }

    UnrecognizedToolUsage.recordUnrecognized("foo", url: nested)
    XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
  }

  /// A corrupted or foreign-schema file (a crash mid-write, disk corruption, a hand edit) must not
  /// crash the next `recordUnrecognized` call — it resets to a fresh single-entry map instead.
  func testCorruptExistingFileResetsCountsRatherThanCrashing() throws {
    try "not valid json{{{".write(to: url, atomically: true, encoding: .utf8)

    UnrecognizedToolUsage.recordUnrecognized("foo", url: url)

    let data = try Data(contentsOf: url)
    let counts = try JSONDecoder().decode([String: Int].self, from: data)
    XCTAssertEqual(counts, ["foo": 1])
  }

  /// `defaultURL` is parameterized specifically so bundle-id scoping (Workroom/Workroom Dev/Workroom
  /// Nightly never mixing usage data) is verifiable without touching the real filesystem location.
  func testDefaultURLScopesByBundleIDAndFallsBackSafely() {
    let fm = FileManager.default
    let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    let scoped = UnrecognizedToolUsage.defaultURL(bundleID: "com.example.dev", fileManager: fm)
    XCTAssertEqual(
      scoped,
      appSupport.appendingPathComponent("Workroom", isDirectory: true)
        .appendingPathComponent("com.example.dev", isDirectory: true)
        .appendingPathComponent("unrecognized-tool-usage.json"))

    // A missing bundle id must NOT fall back to the real production identifier — that would
    // silently redirect into the shipped app's own usage file instead of an obviously-scoped one.
    let fallback = UnrecognizedToolUsage.defaultURL(bundleID: nil, fileManager: fm)
    XCTAssertFalse(fallback.path.contains("com.developwithstyle.workroom"))
  }
}
