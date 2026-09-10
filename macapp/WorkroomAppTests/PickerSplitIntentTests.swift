import SwiftUI
import XCTest

@testable import Workroom

/// The one shared decision behind ⌥⏎ / ⌥-click in both workroom pickers (issue #163). Pinned here
/// because the two dialogs are structural twins with no compiler link between them: if the
/// modifier or the mode-aware strings ever drift, they drift silently in the UI.
@MainActor
final class PickerSplitIntentTests: XCTestCase {

  /// Whether ⌥⏎ survives the focused search field's field editor is an AppKit question. If it
  /// doesn't, changing this constant is the whole fix — so pin it, and make the change deliberate.
  func testTheSplitModifierIsOption() {
    XCTAssertEqual(PickerSplitIntent.modifier, .option)
  }

  func testRequestedReadsTheModifierOffTheKeyPress() {
    XCTAssertTrue(PickerSplitIntent.requested(.option))
    XCTAssertFalse(PickerSplitIntent.requested([]))
    XCTAssertFalse(PickerSplitIntent.requested(.shift), "only the split modifier counts")
    XCTAssertTrue(
      PickerSplitIntent.requested([.option, .shift]), "extra modifiers don't cancel the intent")
  }

  // MARK: mode-aware labelling

  /// A picker raised by ⌥⌘O splits on a PLAIN ⏎ — the modifier was pressed before the dialog
  /// existed and is invisible by then. So the title and hint must state the effective mode, or the
  /// dialog tells the user it will do something it won't.
  func testTitleNamesTheEffectiveMode() {
    XCTAssertEqual(PickerSplitIntent.title(open: true, split: false), "Open Workroom")
    XCTAssertEqual(
      PickerSplitIntent.title(open: true, split: true), "Open Workroom (split right)")
    XCTAssertEqual(PickerSplitIntent.title(open: false, split: false), "New Workroom")
    XCTAssertEqual(
      PickerSplitIntent.title(open: false, split: true), "New Workroom (split right)")
  }

  func testHintNamesTheEffectiveAction() {
    XCTAssertEqual(PickerSplitIntent.hint(open: true, split: false), "⏎ open · ⌥⏎ split")
    XCTAssertEqual(PickerSplitIntent.hint(open: false, split: false), "⏎ create · ⌥⏎ split")
    // In split mode plain ⏎ already splits, so offering "⌥⏎ split" would be noise at best.
    XCTAssertEqual(PickerSplitIntent.hint(open: true, split: true), "⏎ split")
    XCTAssertEqual(PickerSplitIntent.hint(open: false, split: true), "⏎ split")
  }

}
