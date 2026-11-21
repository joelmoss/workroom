import AppKit

/// The Rename… prompt for a terminal: a window-modal sheet with one text field, prefilled with the
/// terminal's current name. OK sets the name; an empty name clears it, which brings the program's
/// live title back (glossary: Terminal name). Cancel leaves it alone.
@MainActor
enum TabRenamePrompt {
  static func present(
    currentName: String, onRename: @escaping @MainActor (String) -> Void
  ) {
    // One tick, so the context menu's own event has unwound before the sheet drops (as the close
    // confirm does, `TabCloseFlow`).
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.messageText = "Rename Terminal"
      alert.informativeText = "Leave the name empty to show the title the program sets."
      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
      field.stringValue = currentName
      field.placeholderString = "Terminal name"
      field.setAccessibilityIdentifier("terminal.rename.field")
      field.toolTip = "The name shown on this terminal's tab, pane title and sidebar row"
      alert.accessoryView = field
      alert.addButton(withTitle: "Rename")
      alert.addButton(withTitle: "Cancel")
      alert.window.initialFirstResponder = field
      let resolve: (NSApplication.ModalResponse) -> Void = { response in
        if response == .alertFirstButtonReturn { onRename(field.stringValue) }
      }
      if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        alert.beginSheetModal(for: window, completionHandler: resolve)
      } else {
        resolve(alert.runModal())
      }
    }
  }
}
