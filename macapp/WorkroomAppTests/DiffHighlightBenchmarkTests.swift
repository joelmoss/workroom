import AppKit
import SyntaxHighlighting
import XCTest

@testable import Workroom

/// Times `DiffHighlightMapper.attributedLines`, the per-line coloured strings the diff viewer
/// renders, on a new-file diff at the parser's 2000-line cap over a generated Swift source with its
/// real highlight spans, every fifth line carrying an intra-line emphasis range.
///
/// A benchmark, not a test: it skips unless `WORKROOM_BENCH=1` reaches the test process, which
/// `make app-bench-diff-highlight` arranges (a Debug build, like every app-test run: compare runs
/// with each other, not with release numbers), and it asserts only what keeps its numbers honest.
@MainActor
final class DiffHighlightBenchmarkTests: XCTestCase {

  private static let samples = 7
  private static let lineCount = 2000

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run it with `make app-bench-diff-highlight`")
  }

  // Value: protects=a comparable before/after timing of the diff mapper; fails_when=the fixture
  // highlights to nothing or a line goes unmapped (an early return would then be timed);
  // why_new=no repeatable diff-mapper timing existed; seam=none; no_claim=any speed threshold.
  func testDiffMapperTimings() throws {
    let content = BenchmarkFixtures.swiftSource(lines: Self.lineCount)
    // Drop the empty line after the trailing newline.
    let lines = content.components(separatedBy: "\n").dropLast()
    let diff = UnifiedDiff(
      hunks: [
        .init(
          header: "@@ -0,0 +1,\(lines.count) @@",
          lines: lines.enumerated().map {
            UnifiedDiff.Line(kind: .addition, text: $1, oldLine: nil, newLine: $0 + 1)
          })
      ], truncated: false, renamedFrom: nil)
    var emphasis: [Int: Range<Int>] = [:]
    for number in stride(from: 5, through: lines.count, by: 5)
    where lines[number - 1].utf8.count > 12 {
      emphasis[number] = 4..<12
    }
    let spans = SyntaxHighlighter.shared.spans(for: content, grammar: .swift)
    XCTAssertGreaterThan(spans.count, 0, "the fixture highlighted to nothing")
    let tokens = ThemeService.shared.tokens

    var elapsed: [Double] = []
    var mapped = 0
    for _ in 0..<Self.samples {
      let start = DispatchTime.now()
      let result = DiffHighlightMapper.attributedLines(
        diff: diff, content: content, spans: spans, tokens: tokens, additionEmphasis: emphasis)
      elapsed.append(
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
      mapped = result.count
    }
    XCTAssertEqual(
      mapped, lines.filter { !$0.isEmpty }.count, "every non-empty added line is mapped")

    let sorted = elapsed.sorted()
    let line = String(
      format:
        "attributedLines, %d added lines, %d spans: median %.1f ms (min %.1f, max %.1f, n=%d)",
      lines.count, spans.count, sorted[sorted.count / 2], sorted.first!, sorted.last!,
      elapsed.count)
    print("\n=== Diff highlight mapper benchmark (Debug) ===\n\(line)")
    try BenchmarkFixtures.write(
      [
        "date": ISO8601DateFormatter().string(from: Date()),
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "configuration": "Debug",
        "lines": lines.count, "spans": spans.count,
        "median_ms": BenchmarkFixtures.round(sorted[sorted.count / 2]),
        "min_ms": BenchmarkFixtures.round(sorted.first!),
        "max_ms": BenchmarkFixtures.round(sorted.last!),
        "samples_ms": elapsed.map(BenchmarkFixtures.round),
      ], to: BenchmarkFixtures.reportURL(named: "diff-highlight"))
  }
}
