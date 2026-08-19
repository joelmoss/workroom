import XCTest

@testable import Workroom

final class ToolLogoRegistryTests: XCTestCase {
  /// Case-INsensitive on purpose (review finding): a `proc_name`-resolved executable name is never
  /// prose, so there's no false-positive risk to guard against here, unlike the title-matching path
  /// below — and macOS's default case-insensitive filesystem means a real binary can genuinely be
  /// invoked with non-lowercase casing (e.g. "Docker").
  func testMatchesExecutableAliasesCaseInsensitively() {
    XCTAssertEqual(ToolLogoRegistry.matchingEntry(forExecutableName: "vim")?.id, "vim")
    XCTAssertEqual(ToolLogoRegistry.matchingEntry(forExecutableName: "vi")?.id, "vim")
    XCTAssertEqual(
      ToolLogoRegistry.matchingEntry(forExecutableName: "/opt/homebrew/bin/nvim")?.id, "nvim")
    XCTAssertEqual(ToolLogoRegistry.matchingEntry(forExecutableName: "Vim")?.id, "vim")
    XCTAssertEqual(ToolLogoRegistry.matchingEntry(forExecutableName: "DOCKER")?.id, "docker")
  }

  func testMatchesTitleFirstTokenAndRejectsProseFalsePositives() {
    XCTAssertEqual(ToolLogoRegistry.matchingEntry(forTitle: "claude --resume abc")?.id, "claude")
    XCTAssertEqual(ToolLogoRegistry.matchingEntry(forTitle: "Claude Code")?.id, "claude")
    for title in ["Go to definition", "Ruby on Rails guide", "installing docker Desktop"] {
      XCTAssertNil(ToolLogoRegistry.matchingEntry(forTitle: title), "false positive for \(title)")
    }
  }

  /// Codex's real terminal title can be the standalone provider-owned "Codex" (mirroring
  /// `AgentTitleRecognition`'s own literal `"codex"` case) — without a `titles` entry (review
  /// finding), a capitalized standalone title would miss the case-sensitive executable-token
  /// fallback too, since it isn't a command line with `codex` as its literal lowercase first token.
  func testMatchesCodexLiteralProviderTitleCaseInsensitively() {
    XCTAssertEqual(ToolLogoRegistry.matchingEntry(forTitle: "Codex")?.id, "codex")
    XCTAssertEqual(ToolLogoRegistry.matchingEntry(forTitle: "codex")?.id, "codex")
  }

  /// Shell integration can report a quoted first token (e.g. `"claude" --resume`) — the
  /// quote-stripping branch of `matchingEntry(forTitle:)` had no test.
  func testMatchesTitleWithQuotedFirstToken() {
    XCTAssertEqual(
      ToolLogoRegistry.matchingEntry(forTitle: "\"claude\" --resume abc")?.id, "claude")
    XCTAssertEqual(ToolLogoRegistry.matchingEntry(forTitle: "'vim' README.md")?.id, "vim")
  }

  func testUnrecognizedNameOrTitleReturnsNil() {
    XCTAssertNil(ToolLogoRegistry.matchingEntry(forExecutableName: "some-random-binary"))
    XCTAssertNil(ToolLogoRegistry.matchingEntry(forTitle: nil))
  }

  /// Registry data-integrity guard (X1 cross-model tension): a future copy-paste in `registry.json`
  /// could give two entries the same `id`, or the same executable/title alias to two different
  /// entries, silently making `byExecutable`/`byTitle` pick whichever was processed last. Pure data
  /// check — no imageset dependency, runs anywhere.
  func testRegistryHasNoDuplicateIdsOrAliases() {
    let entries = ToolLogoRegistry.entries
    XCTAssertFalse(entries.isEmpty, "registry.json should have decoded at least one entry")

    let ids = entries.map(\.id)
    XCTAssertEqual(Set(ids).count, ids.count, "duplicate id in registry.json")

    var seenExecutables: Set<String> = []
    for entry in entries {
      for exe in entry.executables {
        XCTAssertTrue(
          seenExecutables.insert(exe).inserted,
          "executable alias \"\(exe)\" claimed by more than one registry entry")
      }
    }

    var seenTitles: Set<String> = []
    for entry in entries {
      for title in entry.titles ?? [] {
        XCTAssertTrue(
          seenTitles.insert(title.lowercased()).inserted,
          "title alias \"\(title)\" claimed by more than one registry entry")
      }
    }
  }
}
