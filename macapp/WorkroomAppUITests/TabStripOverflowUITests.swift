import XCTest

/// UI tests for the tab strips' overflow behaviour (issue #129): once the chips scroll, the "+" must
/// lift out of the scroller and pin at the trailing edge — always visible, always clickable, and never
/// abutting the per-tab toolbar. While the chips fit, it must stay inline hugging the last chip.
///
/// Driven through the real app in fixture mode (`-WorkroomUITestFixture 1`) with the overflow seams
/// added for these tests: `-WorkroomUITestTerminalTabs <n>` (terminal strip) and
/// `-WorkroomUITestWorkroomCount <n>` (title-bar workroom bar). Both seed tab *models*; only the
/// selected workroom's pane mounts a real shell, so a high chip count is cheap.
///
/// Run with `make app-uitest` on a real GUI login session (XCUITest can't drive a headless run).
final class TabStripOverflowUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  /// Enough terminal tabs that the strip overflows at any sane window width (chip titles cap at 180pt,
  /// so 12 chips is ≥ 1000pt of run).
  private let overflowTabs = 12
  /// Enough workroom chips to overflow the title bar's tab area.
  private let overflowWorkrooms = 10

  private func launchedApp(
    terminalTabs: Int? = nil, workrooms: Int? = nil, longWorkroomName: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    if let terminalTabs {
      app.launchArguments += ["-WorkroomUITestTerminalTabs", "\(terminalTabs)"]
    }
    if let workrooms { app.launchArguments += ["-WorkroomUITestWorkroomCount", "\(workrooms)"] }
    if longWorkroomName { app.launchArguments += ["-WorkroomUITestLongWorkroomName", "1"] }
    app.launch()
    app.activate()
    return app
  }

  private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// One strip chip per terminal. The chip's title and close button share the `terminal.tab.<title>`
  /// identifier, so match only the title StaticText to count chips 1:1 (as `SplitPaneUITests` does).
  private func terminalChips(_ app: XCUIApplication) -> XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 10) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  // MARK: Terminal tab strip

  /// Issue #129, symptom 2: the "+" must never scroll out of view. With the strip overflowing it is
  /// pinned, so it stays on screen inside the window.
  ///
  /// Asserts geometry only — deliberately, to keep the failure specific. Hittability of this same
  /// button is asserted by `testChromeGlyphButtonsAreHittableWhenPinned` and its clickability by
  /// `testPinnedAddButtonStillAddsATab`. (An earlier version of this comment claimed `isHittable` was a
  /// false negative for this button; it isn't — see the accessibility section below.)
  func testAddTabButtonStaysVisibleWhenTabsOverflow() {
    let app = launchedApp(terminalTabs: overflowTabs)
    assertCount(terminalChips(app), reaches: overflowTabs)
    let plus = element(app, id: "NewTerminal")
    XCTAssertTrue(plus.waitForExistence(timeout: 10))
    XCTAssertFalse(plus.frame.isEmpty, "the + must have a real on-screen frame")
    XCTAssertTrue(
      app.windows.firstMatch.frame.contains(plus.frame),
      "the + scrolled out of the window — issue #129")
  }

  /// Issue #129, symptom 1: the pinned "+" sits immediately left of the per-tab toolbar with a gutter —
  /// no abutting, no overlap.
  ///
  /// The upper bound is also the witness that the strip really is in its PINNED state: an inline "+" on
  /// a row that fits would be hundreds of points from the toolbar. So if the overflow predicate never
  /// fires (e.g. the in-scroller width measurement reporting the viewport instead of the content), this
  /// fails loudly rather than silently asserting nothing.
  func testPinnedAddButtonKeepsGutterFromToolbar() {
    let app = launchedApp(terminalTabs: overflowTabs)
    let plus = element(app, id: "NewTerminal")
    let toolbar = element(app, id: "tab.toolbar.splitRight")
    XCTAssertTrue(plus.waitForExistence(timeout: 10))
    XCTAssertTrue(toolbar.waitForExistence(timeout: 10))
    let gap = toolbar.frame.minX - plus.frame.maxX
    XCTAssertGreaterThanOrEqual(gap, 4, "the + must not abut the trailing toolbar (issue #129)")
    XCTAssertLessThanOrEqual(
      gap, 28, "the + is not pinned — is the window wide enough that \(overflowTabs) tabs fit?")
  }

  /// The pinned "+" is still functional: the trailing fade is a mask, and a mask composites away hit
  /// testing in its transparent region, so this guards that the button itself never falls into it.
  func testPinnedAddButtonStillAddsATab() {
    let app = launchedApp(terminalTabs: overflowTabs)
    assertCount(terminalChips(app), reaches: overflowTabs)
    element(app, id: "NewTerminal").click()
    assertCount(terminalChips(app), reaches: overflowTabs + 1)
  }

  /// The other half of adaptive placement: while everything fits, the "+" stays INLINE hugging the last
  /// chip (today's look) and far from the toolbar. This is the regression guard against pinning
  /// unconditionally.
  ///
  /// The hug bound is measured from the chip's **title** (`terminalChips` matches the title StaticText,
  /// which is how chips are counted 1:1), so it has to clear the chip's own trailing furniture: the
  /// close button, the chip's 4pt trailing pad, the hairline, and the row spacing — ~40pt in total. The
  /// load-bearing assertion is the second one: an inline "+" is hundreds of points from the toolbar,
  /// a pinned one is within ~28pt of it.
  func testAddButtonStaysInlineWhenTabsFit() {
    let app = launchedApp()
    let chip = terminalChips(app).firstMatch
    let plus = element(app, id: "NewTerminal")
    XCTAssertTrue(chip.waitForExistence(timeout: 10))
    XCTAssertTrue(plus.waitForExistence(timeout: 10))
    XCTAssertLessThanOrEqual(
      plus.frame.minX - chip.frame.maxX, 56, "the + should hug the last tab when the row fits")
    let toolbar = element(app, id: "tab.toolbar.splitRight")
    XCTAssertTrue(toolbar.waitForExistence(timeout: 10))
    XCTAssertGreaterThan(
      toolbar.frame.minX - plus.frame.maxX, 40,
      "with one tab the + must NOT be pinned beside the toolbar")
  }

  // MARK: Accessibility geometry of the chrome glyph buttons

  /// The counter-evidence guard for the "chrome buttons report `isHittable == false`" finding raised
  /// during #129. That was an environmental XCUITest artefact, **not** an accessibility defect: probing
  /// inline and pinned, solo and batched, waited and unwaited, every one of these controls resolves to
  /// exactly ONE element of type `.button`, enabled, with a real on-screen frame, and hittable. So the
  /// property is safe to assert, and asserting it here is what keeps it that way — a genuinely
  /// degenerate or mis-placed accessibility frame (which VoiceOver would see too, these being the
  /// primary new-tab / new-workroom / open-workroom actions) fails this test.
  ///
  /// Kept as one focused test rather than sprinkled through the geometry tests above, so a
  /// hittability failure points at the accessibility layer and not at whatever else that test asserts.
  private func assertHittableButton(_ app: XCUIApplication, _ id: String, _ state: String) {
    let matches = app.descendants(matching: .any).matching(identifier: id)
    XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 10), "\(state)/\(id) never appeared")
    XCTAssertEqual(matches.count, 1, "\(state)/\(id) should resolve to exactly one AX element")
    let element = matches.firstMatch
    XCTAssertEqual(element.elementType, .button, "\(state)/\(id) should expose the button role")
    XCTAssertFalse(element.frame.isEmpty, "\(state)/\(id) has a degenerate accessibility frame")
    XCTAssertTrue(element.isEnabled, "\(state)/\(id) should be enabled")
    XCTAssertTrue(
      element.isHittable,
      "\(state)/\(id) is not hittable — AX frame \(element.frame) vs window "
        + "\(app.windows.firstMatch.frame)")

    // `isHittable` alone cannot see the failure this test is named for. It answers an
    // *accessibility* hit test, so it stays true for a control collapsed to 1×1, and for one pushed
    // clean outside the window's visible bounds by a `safeAreaInset` regression — which is precisely
    // the pinned arrangement #129 was about. `frame.isEmpty` only rejects a literally zero-area
    // frame. So assert the two things a pointer or VoiceOver user actually needs: the control is
    // inside the window, and it is big enough to aim at.
    let window = app.windows.firstMatch.frame
    XCTAssertTrue(
      window.contains(element.frame),
      "\(state)/\(id) sits outside the window — AX frame \(element.frame) vs window \(window)")
    XCTAssertGreaterThanOrEqual(
      min(element.frame.width, element.frame.height), Self.collapseFloor,
      "\(state)/\(id) has collapsed — AX frame \(element.frame)")
  }

  /// A collapse tripwire, NOT a hit-target audit — deliberately far below any real control, so this
  /// assertion keeps meaning "crushed to nothing" (which `frame.isEmpty` alone misses at 1×1) even for
  /// a control whose target is legitimately small. The real target size is audited separately by
  /// `testChromeGlyphButtonsClaimTheirWholeWell`.
  private static let collapseFloor: CGFloat = 6

  /// A glyph button's AX frame is the shape it HIT-TESTS, so it doubles as the pointer target — and a
  /// button that claims only its SF Symbol leaves the rest of its drawn hover well dead: no well fill,
  /// no `.help` tooltip, no click, in a ring several points wide around a target the user is aiming at.
  /// `TabToolbarButton` shipped that way (measured 13.0×10.0 inside a ~24×20 well) until it took a
  /// `.contentShape(Rectangle())`, which is what this locks in.
  ///
  /// The floor is the drawn well minus a point of slack — an 11pt symbol in `.padding(4)` is ~19–20pt
  /// on its short side across these glyphs — and deliberately NOT the exact measured numbers, which
  /// differ per symbol (splitRight 24×20, closeAll 21×20, the strip's "+" 20×19). A `.frame` does not
  /// satisfy it: only a content shape moves this number.
  func testChromeGlyphButtonsClaimTheirWholeWell() {
    let app = launchedApp()
    XCTAssertTrue(terminalChips(app).firstMatch.waitForExistence(timeout: 10))
    for id in [
      "NewTerminal", "tab.toolbar.splitRight", "tab.toolbar.splitDown", "tab.toolbar.closeAll",
    ] {
      let button = element(app, id: id)
      XCTAssertTrue(button.waitForExistence(timeout: 10), "\(id) never appeared")
      XCTAssertGreaterThanOrEqual(
        min(button.frame.width, button.frame.height), 18,
        "\(id) claims less than its drawn hover well — AX frame \(button.frame). Did it lose its "
          + "`.contentShape(Rectangle())`? Hover, tooltip and clicks all die in the padding ring.")
    }
  }

  /// Inline (the row fits): no pinning, no `safeAreaInset`, and the mask's ramp is fully opaque.
  func testChromeGlyphButtonsAreHittableWhenInline() {
    let app = launchedApp()
    XCTAssertTrue(terminalChips(app).firstMatch.waitForExistence(timeout: 10))
    for id in ["NewTerminal", "tab.toolbar.splitRight", "NewWorkroom", "OpenWorkroom"] {
      assertHittableButton(app, id, "inline")
    }
  }

  /// Pinned (both strips overflow): the controls now sit in a trailing `safeAreaInset` beside a masked
  /// scroller — the arrangement #129 introduced and the one the finding suspected.
  func testChromeGlyphButtonsAreHittableWhenPinned() {
    let app = launchedApp(terminalTabs: overflowTabs, workrooms: overflowWorkrooms)
    assertCount(terminalChips(app), reaches: overflowTabs)
    for id in ["NewTerminal", "tab.toolbar.splitRight", "NewWorkroom", "OpenWorkroom"] {
      assertHittableButton(app, id, "pinned")
    }
  }

  /// Every workroom tab chip carries a `workroom.tab.<target.id>` identifier and is ONE combined
  /// accessibility element (`.accessibilityElement(children: .combine)`) — unlike the terminal chips,
  /// whose identifier cascades onto the title `StaticText` and are therefore counted via
  /// `terminalChips`'s `staticTexts` query above. Match the chip itself by identifier prefix instead.
  private func workroomChips(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workroom.tab."))
  }

  // MARK: Workroom tab bar (title bar)

  /// The `WorkroomTabBar` half: both trailing controls pin as one block, so neither the "+" nor the
  /// open-workroom chevron can be scrolled out of reach.
  ///
  /// Geometry only, for the same reason as the terminal case — hittability is covered by
  /// `testChromeGlyphButtonsAreHittableWhenPinned`. Clickability of a control inside the pinned
  /// `safeAreaInset` under the trailing mask is proven by `testPinnedAddButtonStillAddsATab`, which
  /// exercises the identical mechanism in the terminal strip.
  func testWorkroomBarControlsStayVisibleWhenChipsOverflow() {
    let app = launchedApp(workrooms: overflowWorkrooms)
    let newWorkroom = element(app, id: "NewWorkroom")
    let openWorkroom = element(app, id: "OpenWorkroom")
    XCTAssertTrue(newWorkroom.waitForExistence(timeout: 10))
    XCTAssertTrue(openWorkroom.waitForExistence(timeout: 10))
    XCTAssertFalse(newWorkroom.frame.isEmpty, "the + must have a real on-screen frame")
    XCTAssertFalse(openWorkroom.frame.isEmpty, "the chevron must have a real on-screen frame")
    let window = app.windows.firstMatch.frame
    XCTAssertTrue(window.contains(newWorkroom.frame), "the + left the window — issue #129")
    XCTAssertTrue(window.contains(openWorkroom.frame), "the chevron left the window — issue #129")
    // They move as ONE block: the chevron stays immediately left of the "+".
    XCTAssertLessThanOrEqual(
      newWorkroom.frame.minX - openWorkroom.frame.maxX, 12,
      "open + new should remain adjacent when pinned")
  }

  /// The workroom chip's title is capped (`TabStripMetrics.maxChipTitle`, issue #129
  /// follow-up): a workroom whose real name is 130 characters must still render a bounded chip
  /// instead of one that stretches wider than the window. `-WorkroomUITestLongWorkroomName 1` seeds
  /// that oversized name on the fixture's sole (auto-selected) workroom, so the cap has a real long
  /// name to clip rather than relying on one existing on disk.
  ///
  /// Upper-bound arithmetic, read off `WorkroomTabChip`'s modifiers: the capped title HStack
  /// (`maxChipTitle` 180) + the chip's inner horizontal padding (10 * 2 = 20) + its outer margin
  /// horizontal padding (2 * 2 = 4) + the outer HStack's one inter-element gap between the leading
  /// cube glyph and the title group (spacing 6 — this fixture workroom has no missing-directory
  /// triangle and no run-tab icon, so the title group is the glyph's only sibling) + the cube glyph's
  /// own rendered width at font size 10 (~14pt, rounded up to 20 for slack) = 180 + 20 + 4 + 6 + 20 =
  /// 230. The 260 bound below adds ~30pt of margin for font-metric/rounding variance while staying far
  /// below what an uncapped 130-character `.subheadline` title would render (several hundred points),
  /// so the assertion still fails if the cap regresses.
  func testWorkroomChipTitleCapsALongName() {
    let app = launchedApp(longWorkroomName: true)
    let chip = workroomChips(app).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 10))
    XCTAssertLessThanOrEqual(
      chip.frame.width, 260,
      "a long workroom name must tail-truncate, not stretch the chip past the window")
    // The load-bearing half: without it this test passes vacuously whenever the fixture flag fails to
    // apply, since a SHORT name also satisfies the bound above. The oversized name must actually have
    // reached the cap, so the chip has to be wider than a short-named one — those render ~150pt
    // (`UITestProject/uitest-room-1` at `.subheadline` plus the chrome above), so 200 separates the two
    // without pinning an exact font metric.
    XCTAssertGreaterThan(
      chip.frame.width, 200,
      "the long-name fixture didn't apply — the chip is short-name width, so the cap is untested")
    let newWorkroom = element(app, id: "NewWorkroom")
    let openWorkroom = element(app, id: "OpenWorkroom")
    XCTAssertTrue(newWorkroom.waitForExistence(timeout: 10))
    XCTAssertTrue(openWorkroom.waitForExistence(timeout: 10))
    let window = app.windows.firstMatch.frame
    XCTAssertTrue(window.contains(newWorkroom.frame), "the + left the window")
    XCTAssertTrue(window.contains(openWorkroom.frame), "the chevron left the window")
  }
}
