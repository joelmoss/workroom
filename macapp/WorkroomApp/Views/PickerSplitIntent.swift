import AppKit
import SwiftUI

/// "Did the user ask for a split?" — the one place that answers it for both workroom pickers
/// (issue #163), plus the title and hint they show.
///
/// `OpenWorkroomDialog` and `NewWorkroomDialog` are deliberate structural twins, so without this
/// the same decision would be written four times (two dialogs × key and click paths) with nothing
/// to keep them agreeing. It matters more than usual here: whether ⌥⏎ survives the focused search
/// field's field editor is an AppKit question, and if it doesn't, changing `modifier` below is the
/// entire fix.
///
/// Two ways in, because the two input paths carry modifiers differently: a key press reports its
/// own, while SwiftUI's tap gesture reports none at all.
enum PickerSplitIntent {
  /// The modifier that turns a pick into a split. Pinned by `PickerSplitIntentTests` so changing
  /// it is a deliberate edit, not a drift.
  static let modifier: EventModifiers = .option

  /// Takes the modifiers rather than the `KeyPress` itself: `KeyPress` has no public initializer,
  /// so a test could not otherwise reach this decision at all. Call sites pass `press.modifiers`.
  static func requested(_ modifiers: EventModifiers) -> Bool { modifiers.contains(modifier) }

  /// The AppKit spelling of `modifier`. Derived, never a second literal: SwiftUI's `EventModifiers`
  /// and AppKit's `NSEvent.ModifierFlags` are different types, so the click path used to hardcode
  /// `.option` and would have kept checking ⌥ after `modifier` changed — silently disagreeing with
  /// the key path and making this file's "changing `modifier` is the entire fix" claim false.
  static var appKitModifier: NSEvent.ModifierFlags {
    var flags: NSEvent.ModifierFlags = []
    if modifier.contains(.option) { flags.insert(.option) }
    if modifier.contains(.shift) { flags.insert(.shift) }
    if modifier.contains(.command) { flags.insert(.command) }
    if modifier.contains(.control) { flags.insert(.control) }
    return flags
  }

  /// Click path: `.onTapGesture` hands over no modifier state, so read the live flags instead.
  static func requestedFromCurrentModifiers() -> Bool {
    // An empty flag set would make `contains` vacuously true, so an unmapped `modifier` must never
    // read as "the user asked for a split".
    guard !appKitModifier.isEmpty else { return false }
    return NSEvent.modifierFlags.contains(appKitModifier)
  }

  /// The dialog's title for how it was raised. A picker raised by ⌥⌘O splits on a *plain* ⏎ — the
  /// modifier was pressed before the dialog existed and is invisible by then — so the header is
  /// the only thing that can say which mode you are in.
  ///
  /// Split mode reads "(split right)", matching the File-menu items that raise it — the header is
  /// how someone connects the dialog back to the command they pressed.
  static func title(open: Bool, split: Bool) -> String {
    let verb = open ? "Open Workroom" : "New Workroom"
    return split ? "\(verb) (split right)" : verb
  }

  /// The footer hint, for the same reason: in split mode a fixed "⏎ open · ⌥⏎ split" would state
  /// the wrong action, and the New picker creates rather than opens.
  static func hint(open: Bool, split: Bool) -> String {
    split ? "⏎ split" : "⏎ \(open ? "open" : "create") · ⌥⏎ split"
  }
}

/// The dimmed one-line footer both pickers show. An invisible modifier nobody can see is a feature
/// nobody uses, and in split mode it is also the confirmation that plain ⏎ will split.
struct PickerHintFooter: View {
  let open: Bool
  let split: Bool

  var body: some View {
    Text(PickerSplitIntent.hint(open: open, split: split))
      .font(.system(size: 10))
      .foregroundStyle(ThemeService.shared.tokens.fgMuted)
      .frame(maxWidth: .infinity, alignment: .center)
      // Its own band, so it doesn't read as floating against the last list row — the header row
      // above the list gets `.padding(12)` + a Divider for the same reason.
      .padding(.top, 6)
      .padding(.bottom, 8)
      .accessibilityIdentifier("picker.splitHint")
  }
}
