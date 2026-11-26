import AppKit

/// The Rename… prompt for a terminal: a window-modal sheet with one text field, prefilled with the
/// terminal's current name. OK sets the name; an empty name clears it, which brings the program's
/// live title back (glossary: Terminal name). Cancel leaves it alone.
@MainActor
enum TabRenamePrompt {
  static func present(
    currentName: String, onRename: @escaping @MainActor (String) -> Void
  ) {
    TextFieldPrompt.present(
      title: "Rename Terminal",
      message: "Leave the name empty to show the title the program sets.",
      value: currentName, placeholder: "Terminal name", fieldID: "terminal.rename.field",
      fieldHelp: "The name shown on this terminal's tab, pane title and sidebar row",
      confirm: "Rename", onConfirm: onRename)
  }
}

/// An alert with one text field, as a sheet on the key (else main) window, else app-modal: the
/// field's text goes to `onConfirm` when the first button is chosen, and `onCancel` runs on Cancel.
/// Shared by the terminal's Rename… and New Terminal Group… prompts.
@MainActor
enum TextFieldPrompt {
  static func present(
    title: String, message: String, value: String = "", placeholder: String, fieldID: String,
    fieldHelp: String, confirm: String, onConfirm: @escaping @MainActor (String) -> Void,
    onCancel: @escaping @MainActor () -> Void = {}
  ) {
    // One tick, so the menu's or button's own event has unwound before the sheet drops (as the
    // close confirm does, `TabCloseFlow`).
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.messageText = title
      alert.informativeText = message
      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
      field.stringValue = value
      field.placeholderString = placeholder
      field.setAccessibilityIdentifier(fieldID)
      field.toolTip = fieldHelp
      alert.accessoryView = field
      alert.addButton(withTitle: confirm)
      alert.addButton(withTitle: "Cancel")
      alert.window.initialFirstResponder = field
      let resolve: (NSApplication.ModalResponse) -> Void = { response in
        if response == .alertFirstButtonReturn { onConfirm(field.stringValue) } else { onCancel() }
      }
      if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        alert.beginSheetModal(for: window, completionHandler: resolve)
      } else {
        resolve(alert.runModal())
      }
    }
  }
}
