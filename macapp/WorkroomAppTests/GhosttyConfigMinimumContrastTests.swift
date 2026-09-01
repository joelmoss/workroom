import GhosttyKit
import XCTest

@testable import Workroom

/// Regression test for the illegible-terminal-text-on-light-themes fix: `writeThemeConfig` adds
/// `minimum-contrast = 3.0` to the generated `ghostty.conf`. Rather than rendering and sampling
/// pixels (fragile — no way to cleanly isolate the probe glyph from command echo/prompt), this
/// feeds the REAL generated config text into the actual linked engine and asserts it accepted the
/// key. Guards against a Swift-wrapper-source-ahead-of-linked-binary version skew silently dropping
/// the key as "unknown" — which would reintroduce the bug with no visible symptom until someone
/// eyeballs a light theme again.
///
/// Only asserts `ghostty_config_diagnostics_count` — NOT a `ghostty_config_get` value round-trip.
/// Empirically verified (both fail closed, deliberately, before landing this): a deliberately typo'd
/// key ("minimum-kontrast-typo") produces `diagnostics_count == 1` with message
/// `"minimum-kontrast-typo: unknown field"`, proving this is a real tripwire — but
/// `ghostty_config_get(cfg, _, "minimum-contrast", _)` and `"minimum_contrast"` (underscore) both
/// returned `false` for the correct key too. `ghostty_config_get`'s exact key-name/buffer-type ABI
/// isn't documented anywhere reachable from this repo and wasn't worth further reverse-engineering
/// for a value round-trip that's secondary to the actual failure mode this test guards against
/// (the key being silently unrecognized) — the diagnostics check alone already catches that.
@MainActor
final class GhosttyConfigMinimumContrastTests: XCTestCase {
  func testMinimumContrastIsAcceptedWithNoDiagnostics() throws {
    // Regenerates the SAME `ghostty.conf` the running app already maintains (a fully-regenerable,
    // "Do not edit" file — see `writeThemeConfig`'s doc comment). Rewriting it here has no effect on
    // any live surface: nothing calls `ghostty_app_update_config` in this test, so it's inert until
    // something else reloads config, exactly like `GhosttyAppTests.testEngineInitializes` already
    // exercises the same live `GhosttyApp.shared` singleton without disturbing it.
    GhosttyApp.shared.writeThemeConfig(dark: false)
    guard let cfg = GhosttyApp.shared.loadConfig() else {
      return XCTFail("loadConfig() failed to build a ghostty_config_t from the generated conf")
    }
    defer { ghostty_config_free(cfg) }

    let diagnosticCount = ghostty_config_diagnostics_count(cfg)
    var diagnosticMessages: [String] = []
    for i in 0..<diagnosticCount {
      let diagnostic = ghostty_config_get_diagnostic(cfg, i)
      diagnosticMessages.append(String(cString: diagnostic.message))
    }
    XCTAssertEqual(
      diagnosticCount, 0,
      "engine rejected/warned on the generated config — minimum-contrast may be an unknown key on "
        + "the pinned build: \(diagnosticMessages)")
  }
}
