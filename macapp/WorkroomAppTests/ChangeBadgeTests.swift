import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// `ChangeBadge` is the Changes panel's change-kind badge mapping (letter + themed colour + spelled
/// word). It exists as a testable unit because it drifted once: `.conflicted` rendered as `"C"` in
/// `diffRemoveFg` — deletion's colour — so a file needing resolution read as a removal, and it
/// disagreed with the orange `!` that `DiffViewer`/`ChangesetDetailView` show for the same state.
/// These tests pin every case so the next kind added can't quietly reuse another's identity.
@MainActor
final class ChangeBadgeTests: XCTestCase {
  private func ns(_ hex: String) -> NSColor { ThemeService.parseHex(hex)! }

  /// A theme with a known palette: red at 1, green at 2, yellow at 3 (the slots the badge colours
  /// derive from).
  private func tokens() -> ThemeTokens {
    var pal = Array(repeating: "#808080", count: 16)
    pal[1] = "#ff0000"
    pal[2] = "#00ff00"
    pal[3] = "#ffff00"
    pal[4] = "#3b9ec4"
    return ThemeTokens(
      preview: ThemePreview(
        name: "T", background: ns("#1c1c1e"), foreground: ns("#d8d8dc"), palette: pal.map(ns)))
  }

  /// A comparable sRGB signature for a `Color` — rounded to 2dp so equality survives colour-space
  /// round-tripping (a tuple of components would not be `Equatable`).
  private func rgb(_ color: Color) -> String {
    let c = NSColor(color).usingColorSpace(.sRGB)!
    return String(format: "%.2f,%.2f,%.2f", c.redComponent, c.greenComponent, c.blueComponent)
  }

  /// Individual sRGB channels, for the palette-derivation check.
  private func channels(_ color: Color) -> (CGFloat, CGFloat, CGFloat) {
    let c = NSColor(color).usingColorSpace(.sRGB)!
    return (c.redComponent, c.greenComponent, c.blueComponent)
  }

  func testEveryChangeKindHasItsOwnLetter() {
    XCTAssertEqual(ChangeBadge.letter(.modified), "M")
    XCTAssertEqual(ChangeBadge.letter(.added), "A")
    XCTAssertEqual(ChangeBadge.letter(.deleted), "D")
    XCTAssertEqual(ChangeBadge.letter(.renamed), "R")
    XCTAssertEqual(ChangeBadge.letter(.untracked), "?")
    XCTAssertEqual(ChangeBadge.letter(.conflicted), "!")
    XCTAssertEqual(ChangeBadge.letter(.other), "\u{2022}")
  }

  func testEveryChangeKindHasItsOwnWord() {
    XCTAssertEqual(ChangeBadge.word(.modified), "modified")
    XCTAssertEqual(ChangeBadge.word(.added), "added")
    XCTAssertEqual(ChangeBadge.word(.deleted), "deleted")
    XCTAssertEqual(ChangeBadge.word(.renamed), "renamed")
    XCTAssertEqual(ChangeBadge.word(.untracked), "untracked")
    XCTAssertEqual(ChangeBadge.word(.conflicted), "conflicted")
    XCTAssertEqual(ChangeBadge.word(.other), "changed")
  }

  /// Added/deleted/modified take the theme's diff + warning tokens.
  func testColorsComeFromTheThemeTokens() {
    let t = tokens()
    XCTAssertEqual(rgb(ChangeBadge.color(.added, t)), rgb(t.diffAddFg))
    XCTAssertEqual(rgb(ChangeBadge.color(.deleted, t)), rgb(t.diffRemoveFg))
    XCTAssertEqual(rgb(ChangeBadge.color(.modified, t)), rgb(t.warning))
    XCTAssertEqual(rgb(ChangeBadge.color(.renamed, t)), rgb(t.warning))
    XCTAssertEqual(rgb(ChangeBadge.color(.untracked, t)), rgb(t.fgMuted))
    XCTAssertEqual(rgb(ChangeBadge.color(.other, t)), rgb(t.fgMuted))
  }

  /// The regression this mapping was extracted for: a conflict must not borrow deletion's colour
  /// (nor modification's) — it gets the dedicated `conflict` token.
  func testConflictedIsVisuallyDistinctFromDeletedAndModified() {
    let t = tokens()
    let conflicted = rgb(ChangeBadge.color(.conflicted, t))
    XCTAssertEqual(conflicted, rgb(t.conflict))
    XCTAssertNotEqual(conflicted, rgb(ChangeBadge.color(.deleted, t)), "not deletion's red")
    XCTAssertNotEqual(conflicted, rgb(ChangeBadge.color(.modified, t)), "not modification's yellow")
    XCTAssertNotEqual(ChangeBadge.letter(.conflicted), ChangeBadge.letter(.deleted))
  }

  /// The conflict colour is orange mixed from the palette (red halfway toward yellow), so it tracks
  /// the theme instead of being a hardcoded SwiftUI `.orange`. Asserted as the invariant rather than
  /// an exact value: `NSColor.blended(withFraction:)` is not linear in sRGB, so the green channel
  /// lands *somewhere* between red's 0 and yellow's 1 — what matters is that it's strictly between
  /// (a real mix, not one endpoint) with red full on and blue off.
  func testConflictTokenIsPaletteDerivedOrange() {
    let c = channels(tokens().conflict)
    XCTAssertEqual(c.0, 1.0, accuracy: 0.02, "red channel full")
    XCTAssertGreaterThan(c.1, 0.2, "green channel mixed in — not pure red")
    XCTAssertLessThan(c.1, 0.9, "green channel not saturated — not pure yellow")
    XCTAssertEqual(c.2, 0.0, accuracy: 0.02, "blue channel off")
  }

  /// With no theme palette at all, the conflict colour still resolves (system orange) rather than
  /// falling back to a diff/warning token and re-conflating states.
  func testConflictColorFallsBackWithoutAPalette() {
    let t = ThemeTokens(preview: nil)
    XCTAssertEqual(rgb(ChangeBadge.color(.conflicted, t)), rgb(t.conflict))
    XCTAssertNotEqual(rgb(ChangeBadge.color(.conflicted, t)), rgb(t.diffRemoveFg))
  }

  /// A moved file is ONE row, so its old path has nowhere to live except this line — `old → new`.
  func testPathLineShowsWhereAMovedFileCameFrom() {
    XCTAssertEqual(
      ChangeBadge.pathLine(path: "lib/moved.rb", oldPath: "src/moved.rb"),
      "src/moved.rb \u{2192} lib/moved.rb")
  }

  /// Everything that didn't move renders as the bare path — including the degenerate inputs a backend
  /// can hand us: no old path (every non-rename kind), an empty one, or one equal to the new path
  /// (libgit2 populates `oldFile` for plain modifications too, so this is a real shape, not a
  /// hypothetical). None of them may produce a bogus "x → x" arrow.
  func testPathLineFallsBackToTheBarePath() {
    XCTAssertEqual(ChangeBadge.pathLine(path: "a/b.txt", oldPath: nil), "a/b.txt")
    XCTAssertEqual(ChangeBadge.pathLine(path: "a/b.txt", oldPath: ""), "a/b.txt")
    XCTAssertEqual(ChangeBadge.pathLine(path: "a/b.txt", oldPath: "a/b.txt"), "a/b.txt")
  }
}
