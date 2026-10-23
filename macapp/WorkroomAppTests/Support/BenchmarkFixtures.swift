import Foundation

/// Generated inputs for the benchmarks, so two runs months apart time the same text. Not read from
/// the repo, whose files change under them.
enum BenchmarkFixtures {
  /// A varied Swift snippet repeated, each copy with its own names and a non-ASCII comment (so
  /// the byte-to-UTF-16 mapping is exercised), cut to `lines` lines and ending in a newline.
  static func swiftSource(lines: Int) -> String {
    var out: [String] = ["import Foundation", ""]
    var n = 0
    while out.count < lines {
      out += """
        /// Item \(n): naïve résumé — “quoted” 🙂
        struct Item\(n): Codable, Equatable {
          let id: Int
          var name: String = "item \(n)"
          private(set) var tags: [String] = ["a", "b"]

          func describe(width: Int = 80) -> String {
            guard width > 0 else { return "" }
            let total = tags.reduce(0) { $0 + $1.count } * \(n)
            return "\\(name) [\\(id)] \\(total) \\(width)"
          }
        }

        """.components(separatedBy: "\n")
      n += 1
    }
    return out.prefix(lines).joined(separator: "\n") + "\n"
  }

  /// Where a benchmark writes its JSON: `WORKROOM_BENCH_OUT`, else a timestamped file under
  /// macapp/DerivedData/Benchmarks (git-ignored, and found again next to the build).
  static func reportURL(named name: String) -> URL {
    if let path = ProcessInfo.processInfo.environment["WORKROOM_BENCH_OUT"], !path.isEmpty {
      return URL(fileURLWithPath: path)
    }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(
        "DerivedData/Benchmarks/\(name)-\(stamp).json")
  }

  /// Write `report` as JSON to `url`, creating the folder, and say where.
  static func write(_ report: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: url)
    print("Benchmark JSON: \(url.path)")
  }

  static func round(_ value: Double) -> Double {
    (value * 10).rounded() / 10
  }
}
