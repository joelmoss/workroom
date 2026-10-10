import Foundation
import SwiftTreeSitter
import TreeSitter  // the C runtime's `TSInputEncodingUTF8` (not re-exported by SwiftTreeSitter)

/// Parses whole-new-file content with a bundled tree-sitter grammar and resolves the `highlights.scm`
/// query into non-overlapping `HighlightSpan`s (UTF-8 byte ranges + capture names). Pure transform,
/// no UI, no theme — it returns *captures*, which is what the diff caches (theme-independent, so a
/// theme switch recolours without re-parsing).
///
/// Robustness is load-bearing: highlighting must never block or break the diff. Every failure
/// (grammar/query load fails, parse fails, no captures) degrades to `[]` ⇒ the caller renders plain.
/// Run off-main — the parse + query are CPU-bound and the byte arrays are bounded by
/// `SyntaxLanguage.byteCap`.
public final class SyntaxHighlighter: @unchecked Sendable {
  public static let shared = SyntaxHighlighter()

  /// A grammar loaded once: its parsed `Language` + compiled `highlights` query.
  private struct Loaded {
    let language: Language
    let highlights: Query
  }

  /// Bumped if the resolver's capture semantics change, so cached spans from an older build are
  /// never reused. Part of the spans-cache key.
  public static let queryVersion = 1

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

  private func computeSpans(for content: String, grammar: GrammarID) -> [HighlightSpan] {
    guard let loaded = load(grammar) else { return [] }

    // Parse as UTF-8 (the read-block variant) so `Node.byteRange` is in UTF-8 byte offsets — the
    // String-based `parse(_:)` uses UTF-16LE, which would make every offset wrong for our line
    // mapping. The read block hands tree-sitter bounded chunks of the file's UTF-8 bytes.
    let bytes = Array(content.utf8)
    guard !bytes.isEmpty else { return [] }

    let parser = Parser()
    do { try parser.setLanguage(loaded.language) } catch { return [] }

    let tree = parser.parse(tree: nil as Tree?, encoding: TSInputEncodingUTF8) { byteOffset, _ in
      guard byteOffset < bytes.count else { return Data() }
      let end = min(byteOffset + (1 << 16), bytes.count)
      return Data(bytes[byteOffset..<end])
    }
    guard let tree, let root = tree.rootNode else { return [] }

    return Self.resolve(query: loaded.highlights, root: root, in: tree, byteCount: bytes.count)
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
    let language = Language(grammar.tsLanguage)
    // Locate the grammar's `highlights.scm` and compile it ourselves rather than via
    // `LanguageConfiguration(_:name:)`: that initialiser's bundle search uses an `isXCTestRunner`
    // heuristic that misfires for a host-based unit test (it looks in `Contents/PlugIns/`, but a
    // hosted test's grammar bundle lives in the app's `Contents/Resources/`). Searching the
    // candidate containers ourselves works in both the real app and under test.
    guard let scm = highlightsQueryData(forBundleNamed: grammar.queryBundleName),
      let highlights = try? Query(language: language, data: scm)
    else { return nil }
    return Loaded(language: language, highlights: highlights)
  }

  /// Find a grammar's `queries/highlights.scm` inside its SPM resource bundle (named
  /// `<package>_<target>`, e.g. `TreeSitterJSON_TreeSitterJSON`) and return its bytes. Searches
  /// `Bundle.main` (the app — also the test host), the bundle that owns this class, and every
  /// loaded bundle, so it resolves whether running as the app or under XCTest. `nil` ⇒ render plain.
  private static func highlightsQueryData(forBundleNamed bundleName: String) -> Data? {
    var containers: [URL] = []
    if let u = Bundle.main.resourceURL { containers.append(u) }
    containers.append(Bundle.main.bundleURL)
    let own = Bundle(for: SyntaxHighlighter.self)
    if let u = own.resourceURL { containers.append(u) }
    containers.append(contentsOf: Bundle.allBundles.compactMap(\.resourceURL))

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
  private static func resolve(query: Query, root: Node, in tree: MutableTree, byteCount: Int)
    -> [HighlightSpan]
  {
    struct Cap {
      let lo: Int
      let hi: Int
      let pattern: Int
      let name: String
    }

    var caps: [Cap] = []
    for match in query.execute(node: root, in: tree) {
      for capture in match.captures {
        guard let name = capture.name else { continue }
        let r = capture.node.byteRange
        let lo = Int(r.lowerBound)
        let hi = min(Int(r.upperBound), byteCount)
        if lo < hi { caps.append(Cap(lo: lo, hi: hi, pattern: capture.patternIndex, name: name)) }
      }
    }
    guard !caps.isEmpty else { return [] }

    // Winner painted last: lower pattern first, and within a pattern the shorter range first so the
    // longer one overwrites it.
    caps.sort { a, b in
      a.pattern != b.pattern ? a.pattern < b.pattern : (a.hi - a.lo) < (b.hi - b.lo)
    }

    var names: [String] = []
    var nameID: [String: UInt16] = [:]
    // Per-byte capture id: 0 = no capture; otherwise an index into `names` + 1.
    var paint = [UInt16](repeating: 0, count: byteCount)
    for c in caps {
      let id: UInt16
      if let existing = nameID[c.name] {
        id = existing
      } else {
        names.append(c.name)
        id = UInt16(names.count)
        nameID[c.name] = id
      }
      for i in c.lo..<c.hi { paint[i] = id }
    }

    var spans: [HighlightSpan] = []
    var i = 0
    while i < byteCount {
      let id = paint[i]
      if id == 0 {
        i += 1
        continue
      }
      var j = i + 1
      while j < byteCount, paint[j] == id { j += 1 }
      spans.append(HighlightSpan(byteRange: i..<j, capture: names[Int(id) - 1]))
      i = j
    }
    return spans
  }
}
