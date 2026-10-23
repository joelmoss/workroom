import AppKit
import SyntaxHighlighting
import XCTest

@testable import Workroom

/// Times `FileHighlightMapper.nsAttributedString`, the themed string the file viewer renders, on a
/// generated Swift source at the viewer's 5000-line cap with its real highlight spans.
///
/// A benchmark, not a test: it skips unless `WORKROOM_BENCH=1` reaches the test process, which
/// `make app-bench-file-highlight` arranges (a Debug build, like every app-test run: compare runs
/// with each other, not with release numbers), and it asserts only what keeps its numbers honest.
@MainActor
final class FileHighlightBenchmarkTests: XCTestCase {

  private static let samples = 7

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run it with `make app-bench-file-highlight`")
  }

  // Value: protects=a comparable before/after timing of the mapper; fails_when=the fixture
  // highlights to nothing (the walk would then time an early return); why_new=no repeatable
  // mapper timing existed; seam=none; no_claim=any speed threshold.
  func testMapperTimings() throws {
    let content = BenchmarkFixtures.swiftSource(lines: PlainFileViewer.lineCap)
    let spans = SyntaxHighlighter.shared.spans(for: content, grammar: .swift)
    XCTAssertGreaterThan(spans.count, 0, "the fixture highlighted to nothing")
    let tokens = ThemeService.shared.tokens

    var elapsed: [Double] = []
    var length = 0
    for _ in 0..<Self.samples {
      let start = DispatchTime.now()
      let string = FileHighlightMapper.nsAttributedString(
        content: content, spans: spans, tokens: tokens, font: PlainFileViewer.font)
      elapsed.append(
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
      length = string.length
    }
    XCTAssertEqual(length, (content as NSString).length)

    let sorted = elapsed.sorted()
    let line = String(
      format: "nsAttributedString, %d lines, %d spans: median %.1f ms (min %.1f, max %.1f, n=%d)",
      PlainFileViewer.lineCap, spans.count, sorted[sorted.count / 2], sorted.first!,
      sorted.last!, elapsed.count)
    print("\n=== File highlight mapper benchmark (Debug) ===\n\(line)")
    try BenchmarkFixtures.write(
      [
        "date": ISO8601DateFormatter().string(from: Date()),
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "configuration": "Debug",
        "lines": PlainFileViewer.lineCap, "spans": spans.count,
        "median_ms": BenchmarkFixtures.round(sorted[sorted.count / 2]),
        "min_ms": BenchmarkFixtures.round(sorted.first!),
        "max_ms": BenchmarkFixtures.round(sorted.last!),
        "samples_ms": elapsed.map(BenchmarkFixtures.round),
      ], to: BenchmarkFixtures.reportURL(named: "file-highlight"))
  }
}
