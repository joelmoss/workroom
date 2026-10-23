import Foundation
import XCTest

@testable import SyntaxHighlighting

/// Times `SyntaxHighlighter.spans` (parse, query, resolve) on generated Swift and Python sources:
/// a typical 70 KB file and the 2 MB byte cap for Swift, and 70 KB of Python, whose query leans on
/// `#match?` predicates. The sources are generated, not read from the repo, so two runs months
/// apart time the same input.
///
/// A benchmark, not a test: it skips unless `WORKROOM_BENCH=1` reaches the test process, which
/// `make app-bench-highlighting` arranges (a release build, the one users run), and it asserts only
/// what keeps its numbers honest. Run it before and after a highlighter change and compare.
final class SyntaxHighlightingBenchmarkTests: XCTestCase {

  private static let environment = ProcessInfo.processInfo.environment
  private static let samples = 7

  private var report: [[String: Any]] = []
  private var lines: [String] = []

  override func setUpWithError() throws {
    try super.setUpWithError()
    try XCTSkipUnless(
      Self.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run it with `make app-bench-highlighting`")
  }

  // Value: protects=a comparable before/after timing of the highlighter; fails_when=a fixture
  // highlights to nothing (a broken grammar or query would time an early return); why_new=no
  // repeatable highlighter timing existed; seam=none; no_claim=any speed threshold.
  func testHighlighterTimings() throws {
    let fixtures: [(name: String, grammar: GrammarID, source: String, comment: String)] = [
      ("swift 70 KB", .swift, Self.swiftSource(bytes: 70_000), "//"),
      ("swift 1.9 MB (byte cap)", .swift, Self.swiftSource(bytes: 1_900_000), "//"),
      ("python 70 KB", .python, Self.pythonSource(bytes: 70_000), "#"),
    ]
    for fixture in fixtures {
      // The first call of a grammar pays its load and query compile; keep that out of the samples.
      _ = SyntaxHighlighter.shared.spans(for: "x", grammar: fixture.grammar)
      var elapsed: [Double] = []
      var spanCount = 0
      for sample in 0..<Self.samples {
        // A different trailing comment per sample, so none is served from the spans cache.
        let source = fixture.source + "\n\(fixture.comment) sample \(sample)\n"
        let start = DispatchTime.now()
        let spans = SyntaxHighlighter.shared.spans(for: source, grammar: fixture.grammar)
        elapsed.append(
          Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        spanCount = spans.count
      }
      XCTAssertGreaterThan(spanCount, 0, "\(fixture.name) highlighted to nothing")
      record(fixture.name, elapsed, spans: spanCount)
    }
    print("\n=== Syntax highlighting benchmark (release) ===")
    for line in lines { print(line) }
    try writeReport()
  }

  // MARK: - Fixtures

  /// Repeats a varied Swift snippet, each copy with its own names, until `bytes` is reached.
  private static func swiftSource(bytes: Int) -> String {
    var out = "import Foundation\n\n"
    var n = 0
    while out.utf8.count < bytes {
      out += """
        /// Doc comment for item \(n): the quick brown fox.
        struct Item\(n): Codable, Equatable {
          let id: Int
          var name: String = "item \(n)"
          private(set) var tags: [String] = ["a", "b"]

          // A plain comment.
          func describe(width: Int = 80) -> String {
            guard width > 0 else { return "" }
            let total = tags.reduce(0) { $0 + $1.count } * \(n)
            return "\\(name) [\\(id)] \\(total) \\(width)"
          }
        }

        enum State\(n) {
          case idle, running(progress: Double), failed(Error?)
        }

        @MainActor
        final class Store\(n): ObservableObject {
          @Published var items: [Item\(n)] = []
          static let shared = Store\(n)()
          func load() async throws {
            let data = try await URLSession.shared.data(from: URL(string: "https://example.com/\(n)")!)
            items = try JSONDecoder().decode([Item\(n)].self, from: data.0)
            if items.isEmpty { throw CocoaError(.fileNoSuchFile) }
          }
        }


        """
      n += 1
    }
    return out
  }

  /// Repeats a varied Python snippet until `bytes` is reached: constants, builtins and
  /// constructors, the captures the Python query gates with `#match?`.
  private static func pythonSource(bytes: Int) -> String {
    var out = "import os\nimport sys\n\n"
    var n = 0
    while out.utf8.count < bytes {
      out += """
        MAX_ITEMS_\(n) = \(n) * 2
        default_name_\(n) = "item \(n)"


        class Item\(n)(object):
            \"\"\"Doc string for item \(n).\"\"\"

            def __init__(self, name=default_name_\(n), tags=None):
                self.name = name
                self.tags = list(tags or [])

            def describe(self, width=80):
                # A plain comment.
                total = sum(len(tag) for tag in self.tags) * \(n)
                if width <= 0:
                    return ""
                return f"{self.name} [{total}] {width}"


        def load_\(n)(path):
            with open(path) as handle:
                return [Item\(n)(line.strip()) for line in handle if len(line) > MAX_ITEMS_\(n)]


        """
      n += 1
    }
    return out
  }

  // MARK: - Reporting

  private func record(_ fixture: String, _ values: [Double], spans: Int) {
    let sorted = values.sorted()
    let median = sorted[sorted.count / 2]
    report.append([
      "fixture": fixture, "median": Self.round(median), "min": Self.round(sorted.first!),
      "max": Self.round(sorted.last!), "samples": values.map(Self.round), "spans": spans,
    ])
    lines.append(
      String(
        format: "%@: median %.1f ms (min %.1f, max %.1f, n=%d, %d spans)", fixture, median,
        sorted.first!, sorted.last!, values.count, spans))
  }

  private func writeReport() throws {
    let url: URL
    if let path = Self.environment["WORKROOM_BENCH_OUT"], !path.isEmpty {
      url = URL(fileURLWithPath: path)
    } else {
      // macapp/DerivedData/Benchmarks: git-ignored, and found again next to the build.
      let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(
        of: ":", with: "")
      url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("DerivedData/Benchmarks/syntax-highlighting-\(stamp).json")
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let object: [String: Any] = [
      "date": ISO8601DateFormatter().string(from: Date()),
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "configuration": "Release",
      "timings_ms": report,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
    print("Benchmark JSON: \(url.path)")
  }

  private static func round(_ value: Double) -> Double {
    (value * 10).rounded() / 10
  }
}
