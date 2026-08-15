import XCTest

@testable import Workroom

/// Lane-A spike coverage + the highlighter's core contract: real tree-sitter parse → highlights
/// query → resolved spans, for a no-scanner grammar (JSON) and an **external-scanner** grammar
/// (Bash, whose `scanner.c` proves the grammar packaging links + runs). Also covers the
/// `SyntaxLanguage.grammar(forPath:)`/`grammar(forShebang:)` registry. Pure logic — no repo, no
/// temp files needed (the content is inline source strings).
final class SyntaxHighlighterTests: XCTestCase {

  // MARK: - Real parse + query (proves SPM grammar + query-bundle wiring)

  func testJSONProducesHighlightSpans() {
    let json = """
      {
        "name": "workroom",
        "count": 42,
        "ok": true
      }
      """
    let spans = SyntaxHighlighter.shared.spans(for: json, grammar: .json)
    XCTAssertFalse(spans.isEmpty, "JSON should produce highlight spans from its highlights.scm")
    // A string key should be captured (string/property capture names vary by grammar; assert the
    // span exists over the `"name"` key bytes rather than the exact capture name).
    XCTAssertTrue(
      spans.contains { $0.capture.contains("string") || $0.capture.contains("property") },
      "expected a string/property capture; got \(Set(spans.map(\.capture)))")
  }

  /// Bash carries an external scanner (`src/scanner.c`). A non-empty parse proves the scanner
  /// compiled, linked, and runs — the lane-A packaging de-risk.
  func testBashExternalScannerParses() {
    let script = """
      #!/usr/bin/env bash
      set -euo pipefail
      greeting="hello"
      echo "$greeting world"
      """
    let spans = SyntaxHighlighter.shared.spans(for: script, grammar: .bash)
    XCTAssertFalse(
      spans.isEmpty, "Bash (external-scanner grammar) should parse and produce highlight spans")
  }

  /// Spans are ascending and non-overlapping (the resolver's contract — the byte→AttributedString
  /// mapping depends on it).
  func testSpansAreAscendingAndNonOverlapping() {
    let spans = SyntaxHighlighter.shared.spans(
      for: "{ \"a\": 1, \"b\": [true, null] }", grammar: .json)
    XCTAssertFalse(spans.isEmpty)
    for (prev, next) in zip(spans, spans.dropFirst()) {
      XCTAssertLessThanOrEqual(
        prev.byteRange.upperBound, next.byteRange.lowerBound, "spans overlap")
    }
  }

  func testEmptyContentProducesNoSpans() {
    XCTAssertTrue(SyntaxHighlighter.shared.spans(for: "", grammar: .json).isEmpty)
  }

  /// The grammar+query "CI check": every bundled grammar must load its parser, link its external
  /// scanner, find its `highlights.scm`, and produce spans for a representative snippet. A miss here
  /// (mis-named query bundle, missing scanner symbol, absent highlights.scm) means that language
  /// silently renders plain — caught loudly instead.
  func testEveryGrammarLoadsAndHighlights() {
    let snippets: [GrammarID: String] = [
      .swift: "let answer = 42\n",
      .go: "package main\nfunc main() {}\n",
      .ruby: "def foo\n  1\nend\n",
      .javascript: "const x = 1\n",
      .typescript: "const x: number = 1\n",
      .tsx: "const e = <div className=\"a\">hi</div>\n",
      .python: "def foo():\n    return 1\n",
      .json: "{ \"a\": 1 }\n",
      .yaml: "name: workroom\nport: 42\n",
      .toml: "name = \"workroom\"\nport = 42\n",
      .markdown: "# Title\n\nSome **text**.\n",
      .bash: "set -e\necho hi\n",
      .html: "<div class=\"a\">hi</div>\n",
      .css: "a { color: red; }\n",
      .sql: "SELECT id FROM users;\n",
    ]
    // Every case must have a snippet (guards against forgetting one when a grammar is added).
    XCTAssertEqual(Set(snippets.keys), Set(GrammarID.allCases))
    for grammar in GrammarID.allCases {
      let spans = SyntaxHighlighter.shared.spans(for: snippets[grammar]!, grammar: grammar)
      XCTAssertFalse(
        spans.isEmpty,
        "grammar \(grammar.rawValue) produced no spans — query bundle \(grammar.queryBundleName) "
          + "or parser/scanner likely not wired")
    }
  }

  // MARK: - Captures cache key

  func testCacheKeyVariesByContentAndGrammarAndIsStable() {
    let a = SyntaxHighlighter.cacheKey(grammar: .json, content: "{\"a\":1}")
    let b = SyntaxHighlighter.cacheKey(grammar: .json, content: "{\"b\":2}")
    let c = SyntaxHighlighter.cacheKey(grammar: .bash, content: "{\"a\":1}")
    XCTAssertNotEqual(a, b, "different content ⇒ different key")
    XCTAssertNotEqual(
      a, c, "different grammar ⇒ different key (captures must not leak across langs)")
    XCTAssertEqual(a, SyntaxHighlighter.cacheKey(grammar: .json, content: "{\"a\":1}"), "stable")
  }

  func testRepeatedHighlightIsDeterministic() {
    // Same input twice (second served from the captures cache) must return identical spans.
    let json = "{ \"name\": \"workroom\", \"n\": 1 }"
    let first = SyntaxHighlighter.shared.spans(for: json, grammar: .json)
    let second = SyntaxHighlighter.shared.spans(for: json, grammar: .json)
    XCTAssertEqual(first, second)
  }

  // MARK: - Registry (SyntaxLanguage.grammar(forPath:))
  //
  // Retargeted from the deleted SyntaxLanguage.detect(newPath:oldPath:byteCount:), which had no
  // production call sites — the live diff-highlight path (DiffViewer.applyHighlight) reimplements
  // this same "new path, then old/renamed path" fallback inline via grammar(forPath:) directly
  // (it also needs shebang detection, which detect couldn't do since it took no content). These
  // tests now describe the code path that actually runs. The byte-cap invariant detect used to
  // gate locally is enforced upstream instead (GitProvider/RustJJProvider/DiffResolver, at fetch
  // time), outside this file's scope.

  func testGrammarForPathByExtension() {
    XCTAssertEqual(SyntaxLanguage.grammar(forPath: "config/app.json"), .json)
    XCTAssertEqual(SyntaxLanguage.grammar(forPath: "scripts/run.sh"), .bash)
  }

  func testGrammarForPathByFilename() {
    XCTAssertEqual(SyntaxLanguage.grammar(forPath: "home/.bashrc"), .bash)
  }

  func testGrammarForPathUnknownIsNil() {
    XCTAssertNil(SyntaxLanguage.grammar(forPath: "main.rs"))
  }

  func testSkipListWinsOverExtension() {
    // package-lock.json would match the json extension, but the skip-list must win → plain.
    XCTAssertNil(SyntaxLanguage.grammar(forPath: "package-lock.json"))
  }

  func testSkipMinifiedDoubleExtension() {
    XCTAssertNil(SyntaxLanguage.grammar(forPath: "dist/app.min.js"))
  }

  func testGrammarForPathFallsBackToOldPathAcrossRename() {
    // Mirrors DiffViewer.applyHighlight's real fallback composition — grammar(forPath: new) ??
    // grammar(forPath: old) — for a rename across extensions: new side unknown, old side is
    // JSON → highlight off the old path.
    let newPath = "data.unknownext"
    let oldPath = "data.json"
    XCTAssertNil(SyntaxLanguage.grammar(forPath: newPath))
    XCTAssertEqual(
      SyntaxLanguage.grammar(forPath: newPath) ?? SyntaxLanguage.grammar(forPath: oldPath), .json)
  }

  // MARK: - Shebang detection (extension-less scripts)

  func testShebangDirectInterpreter() {
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/bin/bash"), .bash)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/bin/sh"), .bash)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/zsh"), .bash)
  }

  func testShebangViaEnvAndVersionSuffix() {
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env bash"), .bash)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env python3"), .python)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/python3.11"), .python)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env ruby"), .ruby)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env node"), .javascript)
  }

  func testShebangEnvSkipsFlags() {
    // `env -S python3 -u` → the interpreter is python3, not the `-S` flag.
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env -S python3 -u"), .python)
  }

  func testShebangEnvWithNoInterpreterIsNil() {
    // `env` with nothing (or only flags) after it names no interpreter → no language.
    XCTAssertNil(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env"))
    XCTAssertNil(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env -S"))
  }

  func testShebangToleratesTrailingCR() {
    // A CRLF first line leaves a trailing `\r` on the interpreter token — must still match.
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/bin/bash\r"), .bash)
    XCTAssertEqual(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env python3\r"), .python)
  }

  func testShebangNonShebangOrUnknownIsNil() {
    XCTAssertNil(SyntaxLanguage.grammar(forShebang: "not a shebang"))
    XCTAssertNil(SyntaxLanguage.grammar(forShebang: "#!/usr/bin/env perl"))
    XCTAssertNil(SyntaxLanguage.grammar(forShebang: "#!"))
  }

  func testGrammarForPathPrefersExtensionThenShebang() {
    // A `.sh` extension wins without needing the shebang.
    XCTAssertEqual(SyntaxLanguage.grammar(forPath: "run.sh", firstLine: nil), .bash)
    // No extension, but a bash shebang → bash.
    XCTAssertEqual(
      SyntaxLanguage.grammar(forPath: "scripts/deploy", firstLine: "#!/usr/bin/env bash"), .bash)
    // No extension, no shebang → plain.
    XCTAssertNil(SyntaxLanguage.grammar(forPath: "scripts/deploy", firstLine: "echo hi"))
  }
}
