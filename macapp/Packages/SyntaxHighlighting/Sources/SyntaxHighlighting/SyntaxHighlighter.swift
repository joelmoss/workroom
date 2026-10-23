import Foundation
import TreeSitter

/// Parses whole-new-file content with a bundled tree-sitter grammar and resolves the `highlights.scm`
/// query into non-overlapping `HighlightSpan`s (UTF-8 byte ranges + capture names). Pure transform,
/// no UI, no theme — it returns *captures*, which is what the diff caches (theme-independent, so a
/// theme switch recolours without re-parsing).
///
/// Robustness is load-bearing: highlighting must never block or break the diff. Every failure
/// (grammar/query load fails, parse fails, no captures) degrades to `[]` ⇒ the caller renders plain.
/// Run off-main — the parse + query are CPU-bound and the byte arrays are bounded by
/// `SyntaxLanguage.byteCap`.
///
/// Talks to the tree-sitter C runtime directly: the Swift wrapper's match iteration allocated a
/// `Node` and a name string per capture and cost four times the C cursor on a 70 KB file.
public final class SyntaxHighlighter: @unchecked Sendable {
  public static let shared = SyntaxHighlighter()

  /// A grammar loaded once and kept for the process: its language and compiled `highlights` query.
  /// A compiled query is read-only, so concurrent highlights share it; each gets its own parser and
  /// cursor.
  private struct Loaded {
    let language: OpaquePointer
    let query: OpaquePointer
    /// Capture names by capture id, in the order `highlights.scm` introduces them.
    let captureNames: [String]
    /// The predicates each pattern gates its matches with, by pattern index; mostly empty.
    let predicates: [[Predicate]]
  }

  /// One `#eq?` / `#match?` test from `highlights.scm`, parsed once at load. tree-sitter leaves
  /// predicates to the caller, so without this every `((identifier) @constant (#match? @constant
  /// "^[A-Z]"))` coloured every identifier a constant.
  private struct Predicate {
    enum Test {
      case equals(String)
      case matches(NSRegularExpression)
    }
    let capture: UInt32
    let test: Test

    /// Whether every node captured as `capture` passes the test (none captured passes).
    func allows(_ captures: UnsafeBufferPointer<TSQueryCapture>, in bytes: [UInt8]) -> Bool {
      for node in captures where node.index == capture {
        let text = Self.text(of: node, in: bytes)
        let passed =
          switch test {
          case .equals(let value): text == value
          case .matches(let regex):
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
          }
        if !passed { return false }
      }
      return true
    }

    private static func text(of capture: TSQueryCapture, in bytes: [UInt8]) -> String {
      let lo = Int(ts_node_start_byte(capture.node))
      let hi = min(Int(ts_node_end_byte(capture.node)), bytes.count)
      return lo < hi ? String(decoding: bytes[lo..<hi], as: UTF8.self) : ""
    }
  }

  /// Bumped if the resolver's capture semantics change, so cached spans from an older build are
  /// never reused. Part of the spans-cache key.
  public static let queryVersion = 2

  // Grammars + their queries are expensive to load (query compilation reads the bundle), so cache
  // per grammar. A present-but-nil entry records a load *failure* so we don't re-attempt (and
  // re-throw) on every diff. Lock-guarded — diffs can highlight concurrently.
  private let lock = NSLock()
  private var cache: [GrammarID: Loaded?] = [:]

  // Captures cache: theme-independent spans keyed by grammar + content-hash + query version. A
  // theme switch recolours from cached captures without re-parsing; a small LRU-ish cap keeps it
  // bounded (the diff viewer parses one file at a time, so a handful of entries suffices).
  private var spansCache: [Int: [HighlightSpan]] = [:]
  private var spansCacheOrder: [Int] = []
  private static let spansCacheCap = 24

  /// The spans-cache key for a (grammar, content) pair. Exposed for tests: it must vary with the
  /// grammar, the content, and the query version — so stale or cross-grammar captures never leak.
  public static func cacheKey(grammar: GrammarID, content: String) -> Int {
    var hasher = Hasher()
    hasher.combine(queryVersion)
    hasher.combine(grammar)
    hasher.combine(content)
    return hasher.finalize()
  }

  /// Resolve `content` into highlight spans for `grammar`. Returns `[]` (⇒ render plain) on any
  /// failure or when there are no captures. Never throws. Results are cached by content-hash.
  public func spans(for content: String, grammar: GrammarID) -> [HighlightSpan] {
    guard !content.isEmpty else { return [] }

    let key = Self.cacheKey(grammar: grammar, content: content)
    lock.lock()
    if let cached = spansCache[key] {
      lock.unlock()
      return cached
    }
    lock.unlock()

    let computed = computeSpans(for: content, grammar: grammar)

    lock.lock()
    if spansCache[key] == nil {
      spansCache[key] = computed
      spansCacheOrder.append(key)
      if spansCacheOrder.count > Self.spansCacheCap {
        let evict = spansCacheOrder.removeFirst()
        spansCache[evict] = nil
      }
    }
    lock.unlock()
    return computed
  }

  /// `spans` without the cache: what a miss costs. Internal for the benchmark.
  func computeSpans(for content: String, grammar: GrammarID) -> [HighlightSpan] {
    guard let loaded = load(grammar) else { return [] }

    // Parse the UTF-8 bytes so every node range is in UTF-8 byte offsets, which is what the line
    // mapping expects.
    let bytes = Array(content.utf8)
    guard !bytes.isEmpty, let parser = ts_parser_new() else { return [] }
    defer { ts_parser_delete(parser) }
    guard ts_parser_set_language(parser, loaded.language) else { return [] }
    let tree = bytes.withUnsafeBufferPointer { buffer in
      buffer.withMemoryRebound(to: CChar.self) {
        ts_parser_parse_string(parser, nil, $0.baseAddress, UInt32(bytes.count))
      }
    }
    guard let tree else { return [] }
    defer { ts_tree_delete(tree) }

    return Self.resolve(loaded, root: ts_tree_root_node(tree), bytes: bytes)
  }

  // MARK: Grammar loading (cached)

  private func load(_ grammar: GrammarID) -> Loaded? {
    lock.lock()
    defer { lock.unlock() }
    if let cached = cache[grammar] { return cached }  // present ⇒ already attempted (nil = failed)
    let result = Self.loadUncached(grammar)
    cache[grammar] = result
    return result
  }

  private static func loadUncached(_ grammar: GrammarID) -> Loaded? {
    // Locate the grammar's `highlights.scm` and compile it ourselves rather than via
    // SwiftTreeSitter's `LanguageConfiguration(_:name:)`: that initialiser's bundle search uses an
    // `isXCTestRunner` heuristic that misfires for a host-based unit test (it looks in
    // `Contents/PlugIns/`, but a hosted test's grammar bundle lives in the app's
    // `Contents/Resources/`). Searching the candidate containers ourselves works in both the real
    // app and under test.
    guard let scm = highlightsQueryData(forBundleNamed: grammar.queryBundleName) else { return nil }
    let language = grammar.tsLanguage
    var errorOffset: UInt32 = 0
    var error = TSQueryErrorNone
    let compiled = scm.withUnsafeBytes { raw -> OpaquePointer? in
      guard let base = raw.baseAddress else { return nil }
      return ts_query_new(
        language, base.assumingMemoryBound(to: CChar.self), UInt32(scm.count), &errorOffset,
        &error)
    }
    guard let query = compiled else { return nil }
    let captureNames = (0..<ts_query_capture_count(query)).map { id -> String in
      var length: UInt32 = 0
      guard let name = ts_query_capture_name_for_id(query, id, &length) else { return "" }
      return String(
        decoding: UnsafeRawBufferPointer(start: name, count: Int(length)), as: UTF8.self)
    }
    let predicates = (0..<ts_query_pattern_count(query)).map { predicates(of: query, pattern: $0) }
    return Loaded(
      language: language, query: query, captureNames: captureNames, predicates: predicates)
  }

  /// Parse one pattern's predicate steps: `name arg arg … done`, repeated. `#eq?` and `#match?`
  /// against a string are tested; anything else passes. The bundled queries only otherwise use
  /// `#is-not? local`, which needs scope tracking we do not do (every name is then "not local",
  /// the standard fallback).
  /// shortcut: the negated forms and `#eq? @a @b` are not evaluated (no pinned query uses them);
  /// add them, with a test, when a grammar bump brings one in.
  private static func predicates(of query: OpaquePointer, pattern: UInt32) -> [Predicate] {
    var count: UInt32 = 0
    let steps = UnsafeBufferPointer(
      start: ts_query_predicates_for_pattern(query, pattern, &count), count: Int(count))
    var predicates: [Predicate] = []
    var step = steps.startIndex
    while step < steps.endIndex {
      let end =
        steps[step...].firstIndex { $0.type == TSQueryPredicateStepTypeDone } ?? steps.endIndex
      defer { step = end + 1 }
      let args = Array(steps[step..<end])
      guard args.count >= 3, args[0].type == TSQueryPredicateStepTypeString,
        args[1].type == TSQueryPredicateStepTypeCapture
      else { continue }
      guard args[2].type == TSQueryPredicateStepTypeString else { continue }
      let capture = args[1].value_id
      let value = string(args[2].value_id, in: query)
      switch string(args[0].value_id, in: query) {
      case "eq?":
        predicates.append(Predicate(capture: capture, test: .equals(value)))
      case "match?":
        // tree-sitter-sql's number patterns are written with Lua's `%d`, which no regex engine
        // reads as a digit; the rewrite keeps SQL numbers coloured as the query intends.
        let pattern = value.replacingOccurrences(of: "%d", with: "\\d")
        guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
        predicates.append(Predicate(capture: capture, test: .matches(regex)))
      default:
        continue
      }
    }
    return predicates
  }

  private static func string(_ id: UInt32, in query: OpaquePointer) -> String {
    var length: UInt32 = 0
    guard let value = ts_query_string_value_for_id(query, id, &length) else { return "" }
    return String(decoding: UnsafeRawBufferPointer(start: value, count: Int(length)), as: UTF8.self)
  }

  /// Find a grammar's `queries/highlights.scm` inside its SPM resource bundle (named
  /// `<package>_<target>`, e.g. `TreeSitterJSON_TreeSitterJSON`) and return its bytes. Searches
  /// `Bundle.main` (the app — also the test host), the bundle that owns this class, every loaded
  /// bundle, and the directory beside this class's bundle, so it resolves as the app, as a hosted
  /// test, and under `swift test`. `nil` ⇒ render plain.
  private static func highlightsQueryData(forBundleNamed bundleName: String) -> Data? {
    var containers: [URL] = []
    if let u = Bundle.main.resourceURL { containers.append(u) }
    containers.append(Bundle.main.bundleURL)
    let own = Bundle(for: SyntaxHighlighter.self)
    if let u = own.resourceURL { containers.append(u) }
    containers.append(contentsOf: Bundle.allBundles.compactMap(\.resourceURL))
    // `swift test` on SwiftPM's native build system puts each dependency's resource bundle beside
    // the `.xctest`, not inside anything loaded (the CI toolchain; the newer engine differs).
    containers.append(own.bundleURL.deletingLastPathComponent())

    for container in containers {
      let bundleURL = container.appendingPathComponent("\(bundleName).bundle")
      guard let bundle = Bundle(url: bundleURL) else { continue }
      // `Bundle` resolves the platform layout (macOS `Contents/Resources/queries`) for us.
      if let url = bundle.url(
        forResource: "highlights", withExtension: "scm", subdirectory: "queries"),
        let data = try? Data(contentsOf: url)
      {
        return data
      }
    }
    return nil
  }

  // MARK: Capture-precedence resolver

  /// Run the highlights query and flatten its (overlapping) captures into ascending,
  /// non-overlapping spans.
  ///
  /// Precedence (the small resolver the plan calls for): **last-pattern-wins** — a capture from a
  /// pattern later in `highlights.scm` overrides an earlier one for the same bytes (the convention
  /// the standard query files are authored against: generic patterns first, specific later). For
  /// captures from the *same* pattern, the **longest match wins**. Implemented by painting a
  /// per-byte capture id in (patternIndex asc, length asc) order so the winner is painted last,
  /// then coalescing equal-id runs.
  private static func resolve(_ loaded: Loaded, root: TSNode, bytes: [UInt8]) -> [HighlightSpan] {
    struct Cap {
      let lo: Int
      let hi: Int
      let pattern: Int
      /// The query's capture id + 1; 0 is "no capture" in the paint below.
      let id: UInt16
    }

    guard let cursor = ts_query_cursor_new() else { return [] }
    defer { ts_query_cursor_delete(cursor) }
    ts_query_cursor_exec(cursor, loaded.query, root)

    var caps: [Cap] = []
    var match = TSQueryMatch()
    while ts_query_cursor_next_match(cursor, &match) {
      // The capture buffer is only valid until the next call; copy what we need out.
      let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
      let pattern = Int(match.pattern_index)
      guard loaded.predicates[pattern].allSatisfy({ $0.allows(captures, in: bytes) }) else {
        continue
      }
      for capture in captures {
        let lo = Int(ts_node_start_byte(capture.node))
        let hi = min(Int(ts_node_end_byte(capture.node)), bytes.count)
        if lo < hi {
          caps.append(Cap(lo: lo, hi: hi, pattern: pattern, id: UInt16(capture.index + 1)))
        }
      }
    }
    guard !caps.isEmpty else { return [] }

    // Winner painted last: lower pattern first, and within a pattern the shorter range first so the
    // longer one overwrites it.
    caps.sort { a, b in
      a.pattern != b.pattern ? a.pattern < b.pattern : (a.hi - a.lo) < (b.hi - b.lo)
    }

    var paint = [UInt16](repeating: 0, count: bytes.count)
    for c in caps {
      for i in c.lo..<c.hi { paint[i] = c.id }
    }

    var spans: [HighlightSpan] = []
    var i = 0
    while i < bytes.count {
      let id = paint[i]
      if id == 0 {
        i += 1
        continue
      }
      var j = i + 1
      while j < bytes.count, paint[j] == id { j += 1 }
      spans.append(HighlightSpan(byteRange: i..<j, capture: loaded.captureNames[Int(id) - 1]))
      i = j
    }
    return spans
  }
}
