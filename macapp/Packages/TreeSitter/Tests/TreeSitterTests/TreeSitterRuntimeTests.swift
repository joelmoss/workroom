import TreeSitter
import XCTest

final class TreeSitterRuntimeTests: XCTestCase {
  // SyntaxHighlighting's pinned grammars were generated at ABI 14 and 15. A runtime that raised its
  // minimum past 14 would still build, then refuse every ABI-14 grammar when it is set on a parser.
  func testTheRuntimeAcceptsTheGrammarABIsThePinsUse() {
    XCTAssertLessThanOrEqual(TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION, 14)
    XCTAssertGreaterThanOrEqual(TREE_SITTER_LANGUAGE_VERSION, 15)
  }

  func testANewParserHasNoLanguageAndFrees() {
    let parser = ts_parser_new()
    XCTAssertNotNil(parser)
    XCTAssertNil(ts_parser_language(parser))
    ts_parser_delete(parser)
  }
}
