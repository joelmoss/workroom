import DesignSystem
import XCTest

@testable import Workroom

/// What a Settings Light theme or Dark theme row says while its side has fallen back (#733). The UI
/// fixture can only seed bundled themes, so the missing-theme case is covered here.
final class ThemeFallbackNoteTests: XCTestCase {
  func testAStoredThemeThatIsShowingNeedsNoNote() {
    XCTAssertNil(
      ThemeFallbackNote(
        side: .light, stored: "Light Owl", showing: "Light Owl", storedSide: .light))
  }

  func testAMissingThemeSaysItWasNotFound() throws {
    let note = try XCTUnwrap(
      ThemeFallbackNote(side: .dark, stored: "Gone", showing: "Workroom", storedSide: nil))
    XCTAssertEqual(note.text, "Not found: showing Workroom")
    XCTAssertEqual(
      note.help,
      "Workroom can't find a theme called “Gone”, so Workroom shows Workroom while the appearance "
        + "is dark. Your choice is kept, and comes back when the theme does.")
  }

  func testAThemeOnTheWrongSideSaysWhichSideItIsOn() throws {
    let note = try XCTUnwrap(
      ThemeFallbackNote(
        side: .light, stored: "Ayu Light", showing: "Workroom Light", storedSide: .dark))
    XCTAssertEqual(note.text, "Not a light theme: showing Workroom Light")
    XCTAssertEqual(
      note.help,
      "“Ayu Light” is a dark theme, so Workroom shows Workroom Light while the appearance is "
        + "light. Your choice is kept, and comes back when the theme does.")
  }
}
