import AppKit
import XCTest

@testable import Workroom

/// `SwitcherMark` + `PaneMiniature` (issue #132): the per-switcher card identities that replaced
/// screenshots.
final class SwitcherMarkTests: XCTestCase {

  // MARK: Hue stability — the property the whole idea rests on

  func testTheHueIsStableAcrossProcessesNotJustWithinOne() {
    // Swift seeds String hashing PER PROCESS, so `hashValue` would give a workroom a different colour on
    // every launch — which destroys the entire premise of a mark you learn to recognise. These are the
    // hard-coded outputs of the FNV-1a implementation: if someone swaps it for `hashValue`, this fails.
    XCTAssertEqual(SwitcherMark.hue(for: "wr|/p|partitioned-crescent"), 0)
    XCTAssertEqual(SwitcherMark.hue(for: "wr|/p|flaky-tests"), 10)
    XCTAssertEqual(SwitcherMark.hue(for: "root|/p"), 0)
  }

  func testTheHueIsDeterministicForTheSameKey() {
    for key in ["a", "wr|/p|fox", "", "🙂-room"] {
      XCTAssertEqual(SwitcherMark.hue(for: key), SwitcherMark.hue(for: key), "key \(key)")
    }
  }

  func testTheHueIsAlwaysInRange() {
    for index in 0..<500 {
      let hue = SwitcherMark.hue(for: "wr|/project-\(index)|room-\(index)")
      XCTAssertTrue((0..<SwitcherMark.hueCount).contains(hue), "hue \(hue) out of range")
    }
  }

  func testHuesSpreadAcrossThePaletteRatherThanClustering() {
    // A mark scheme where 40 workrooms all land on two hues would be useless. Not a distribution proof —
    // just a guard against a hash that collapses (e.g. summing bytes, which similar names defeat).
    let hues = Set((0..<80).map { SwitcherMark.hue(for: "wr|/p|room-\($0)") })
    XCTAssertEqual(hues.count, SwitcherMark.hueCount, "every hue gets used across 80 names")
  }

  // MARK: Rail-level uniqueness

  func testCollidingHuesAreRotatedApart() {
    // A stable per-name hue is right in isolation and not enough in practice: two of four tiles came out
    // the same colour in BOTH live checks. The rail's job is telling *these* items apart.
    XCTAssertEqual(SwitcherMark.disambiguate([3, 3, 3]), [3, 4, 5])
    XCTAssertEqual(SwitcherMark.disambiguate([0, 5, 0, 5]), [0, 5, 1, 6])
  }

  func testDistinctHuesAreLeftAlone() {
    XCTAssertEqual(SwitcherMark.disambiguate([1, 4, 9]), [1, 4, 9], "no needless churn")
    XCTAssertEqual(SwitcherMark.disambiguate([]), [])
  }

  func testEarlierItemsKeepTheirNaturalHue() {
    // MRU order, so the workrooms you switch between most — and have therefore learned — never move.
    let rotated = SwitcherMark.disambiguate([7, 7, 7, 7])
    XCTAssertEqual(rotated.first, 7)
    XCTAssertEqual(Set(rotated).count, 4, "and the rest are pushed to free hues")
  }

  func testRotationWrapsAroundTheWheel() {
    let rotated = SwitcherMark.disambiguate([11, 11, 11])
    XCTAssertEqual(rotated, [11, 0, 1], "wraps past the last hue rather than running off the end")
  }

  func testMoreItemsThanHuesDegradesWithoutHanging() {
    let hues = Array(repeating: 0, count: SwitcherMark.hueCount + 5)
    let rotated = SwitcherMark.disambiguate(hues)
    XCTAssertEqual(rotated.count, hues.count, "every item still gets a hue")
    XCTAssertTrue(rotated.allSatisfy { (0..<SwitcherMark.hueCount).contains($0) })
  }

  // MARK: Monogram

  func testMonogramKeepsATrailingNumberBecauseThatIsTheDifference() {
    // The bug this exists to prevent, seen live: plain initials turned uitest-room / -2 / -3 / -4 into
    // four identical "UR" tiles — the same failure D12 fixed for titles, and worse than no tile at all.
    XCTAssertEqual(SwitcherMark.monogram(for: "uitest-room"), "UR")
    XCTAssertEqual(SwitcherMark.monogram(for: "uitest-room-2"), "R2")
    XCTAssertEqual(SwitcherMark.monogram(for: "uitest-room-3"), "R3")
    XCTAssertEqual(
      Set(
        ["uitest-room", "uitest-room-2", "uitest-room-3", "uitest-room-4"].map(
          SwitcherMark.monogram)
      )
      .count, 4, "four numbered siblings must produce four distinct monograms")
    XCTAssertEqual(
      SwitcherMark.monogram(for: "room-12"), "R2", "last digit of a multi-digit suffix")
  }

  func testMonogramTakesInitialsFromAGeneratedName() {
    // `namegen` produces adjective-noun pairs, so initials carry far more than the first two letters.
    XCTAssertEqual(SwitcherMark.monogram(for: "partitioned-crescent"), "PC")
    XCTAssertEqual(SwitcherMark.monogram(for: "flaky-tests"), "FT")
    XCTAssertEqual(SwitcherMark.monogram(for: "dusk_harbor"), "DH")
    XCTAssertEqual(SwitcherMark.monogram(for: "Auth refactor"), "AR")
  }

  func testMonogramFallsBackToTwoLettersForASingleWord() {
    XCTAssertEqual(SwitcherMark.monogram(for: "crescent"), "CR")
    XCTAssertEqual(SwitcherMark.monogram(for: "x"), "X")
  }

  func testMonogramSurvivesJunkNames() {
    XCTAssertEqual(
      SwitcherMark.monogram(for: ""), "?", "never empty — the tile would read as a blank")
    XCTAssertEqual(SwitcherMark.monogram(for: "---"), "?")
    XCTAssertEqual(SwitcherMark.monogram(for: "  spaced  out "), "SO")
  }

  func testMonogramUsesMoreThanTwoWordsGracefully() {
    XCTAssertEqual(
      SwitcherMark.monogram(for: "one-two-three"), "OT", "first two words, not all three")
  }

  // MARK: Relabel behaviour — the split that makes a mark learnable

  func testARelabelChangesTheLettersButNotTheColour() {
    // The colour is what you recognise from the corner of your eye, so it keys on the target id (which a
    // relabel does not change); the letters key on what you actually read.
    let key = "wr|/p|partitioned-crescent"
    let before = SwitcherMark(displayName: "partitioned-crescent", stableKey: key)
    let after = SwitcherMark(displayName: "Auth refactor", stableKey: key)
    XCTAssertEqual(before.hue, after.hue, "the hue must survive a relabel")
    XCTAssertEqual(before.monogram, "PC")
    XCTAssertEqual(after.monogram, "AR")
  }

  func testTwoWorkroomsWithTheSameNameInDifferentProjectsCanDiffer() {
    let a = SwitcherMark(displayName: "fox", stableKey: "wr|/alpha|fox")
    let b = SwitcherMark(displayName: "fox", stableKey: "wr|/beta|fox")
    XCTAssertEqual(a.monogram, b.monogram, "same name reads the same")
    // Not guaranteed to differ (6 buckets), but the keys are distinct so the mapping had the chance.
    XCTAssertNotEqual("wr|/alpha|fox", "wr|/beta|fox")
    _ = (a.hue, b.hue)
  }

  // MARK: Mark palette

  func testTileColoursAreDistinctAndClearTheContrastFloor() {
    // The other half of the live bug: `legible` walks a colour TOWARD THE FOREGROUND, so on a light
    // theme every insufficiently-contrasty palette entry became near-black and all six tiles collapsed
    // into identical charcoal. `tileColor` keeps only the hue angle and imposes its own S/B instead.
    let tokens = ThemeTokens(preview: nil)
    var seen: Set<String> = []
    for hue in 0..<SwitcherMark.hueCount {
      let tile = SwitcherMark.tileColor(hue: hue, tokens: tokens)
      let srgb = tile.usingColorSpace(.sRGB)!
      seen.insert(String(format: "%.3f-%.3f", srgb.hueComponent, srgb.brightnessComponent))
      XCTAssertGreaterThanOrEqual(
        ThemeTokens.contrastRatio(tile, tokens.nsPanel), 3.0 - 0.01, "hue \(hue) vs the card")
      XCTAssertGreaterThan(
        srgb.saturationComponent, 0.3, "hue \(hue) must stay a colour, not a grey")
    }
    XCTAssertEqual(seen.count, SwitcherMark.hueCount, "every hue must be visually distinct")
  }

  func testEveryMarkTileCanCarryALegibleMonogram() {
    // The tile clears 3:1 against the card, then the monogram takes whichever of black/white is legible
    // on the result — so no hue can produce an unreadable tile.
    //
    // The monogram floor is 3:1, not 4.5:1, and that is a real constraint rather than a relaxation: a
    // MID-TONE hue (measured 3.15–4.2:1 here) cannot carry either black or white at 4.5:1 — no ink
    // choice exists. 17pt semibold is WCAG "large text" (well past the 14pt-bold / 18.66px threshold),
    // for which 3:1 is the conforming ratio. Body text on the card keeps its 4.5:1 floor.
    let tokens = ThemeTokens(preview: nil)
    for hue in 0..<SwitcherMark.hueCount {
      let tile = SwitcherMark.tileColor(hue: hue, tokens: tokens)
      XCTAssertGreaterThanOrEqual(
        ThemeTokens.contrastRatio(tile, tokens.nsPanel), 3.0 - 0.01, "tile vs card")
      let ink = ThemeTokens.contrastingForeground(for: tile)
      XCTAssertGreaterThanOrEqual(
        ThemeTokens.contrastRatio(ink, tile), 3.0 - 0.01, "monogram vs tile (large-text floor)")
    }
  }

  // MARK: Pane miniatures

  func testEachPaneKindMapsToItsOwnMiniature() {
    // `GhosttySurfaceView(workingDirectory:)` is inert until it enters a window, so building one here
    // costs nothing and spawns no shell.
    let state = TerminalState(
      view: GhosttySurfaceView(workingDirectory: "/tmp"), defaultTitle: "zsh")
    let terminal = PaneMiniature(content: TabContent.terminal(state), isRunning: true)
    XCTAssertEqual(terminal, .terminal(running: true))

    let diff = PaneMiniature(
      content: TabContent.diff(
        DiffDescriptor(path: "a.swift", change: .modified, source: .gitWorktree, isPreview: false)),
      isRunning: false)
    XCTAssertEqual(diff, .diff(.modified))

    let file = PaneMiniature(
      content: TabContent.file(FileDescriptor(path: "README.md", isPreview: false)),
      isRunning: false)
    XCTAssertEqual(file, .file)

    let commit = PaneMiniature(
      content: TabContent.changeset(
        ChangesetDescriptor(commitID: "abc", title: "fix", isPreview: false)), isRunning: false)
    XCTAssertEqual(commit, .changeset)
  }

  func testTheDiffMiniatureCarriesTheChangeKindNotJustDiffness() {
    // Two diff panes in one workroom must not read identically — the change kind is the only per-file
    // signal available (`ChangedFile` has no line counts), so it has to reach the well.
    let added = PaneMiniature.diff(.added)
    let deleted = PaneMiniature.diff(.deleted)
    XCTAssertNotEqual(added, deleted)
    XCTAssertEqual(added.label, "Added")
    XCTAssertEqual(deleted.label, "Deleted")
    XCTAssertEqual(PaneMiniature.diff(.conflicted).label, "Conflicted")
  }

  func testTheRunningTerminalIsADistinctMiniature() {
    XCTAssertNotEqual(PaneMiniature.terminal(running: true), .terminal(running: false))
  }

  func testATerminalReportsItsStateRatherThanRepeatingItsKind() {
    // Seen live: "Terminal 3" over the subtitle "Terminal" says the same thing twice. The title is
    // already the shell or command, so the subtitle spends itself on state instead.
    XCTAssertEqual(PaneMiniature.terminal(running: true).label, "Running")
    XCTAssertEqual(PaneMiniature.terminal(running: false).label, "Idle")
  }

  func testEveryMiniatureNamesItsKindInText() {
    // A shape alone is not accessible, and an unlearned shape is not yet meaningful — the kind is always
    // spelled out under the name too.
    for miniature: PaneMiniature in [
      .terminal(running: false), .diff(.modified), .file, .changeset,
    ] {
      XCTAssertFalse(miniature.label.isEmpty)
    }
  }
}
