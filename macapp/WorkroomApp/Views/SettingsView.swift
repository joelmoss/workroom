import Defaults
import SwiftUI

/// The app's Settings window (⌘,). Consolidates the preferences that previously lived in the
/// Edit and View menus. Each control binds the *same* `Defaults` key its old menu item used,
/// so the stored value — and everything observing it (appearance application in `RootView`,
/// copy-on-select, ⌘-click file opening) — is unchanged; only the surface moves here.
struct SettingsView: View {
  @Default(.theme) private var theme
  @Default(.copyOnSelect) private var copyOnSelect
  @Default(.confirmOnQuit) private var confirmOnQuit
  @Default(.confirmOnCloseTerminal) private var confirmOnCloseTerminal
  @Default(.openTerminalOnCreate) private var openTerminalOnCreate
  @Default(.globalHotkey) private var globalHotkey
  @Default(.showMenuBarItem) private var showMenuBarItem
  // Bundle id of the editor for ⌘-clicked file paths; "" = the file's default app.
  @Default(.filePathEditor) private var pathEditor
  @Default(.themeFamily) private var themeFamily
  @EnvironmentObject private var updater: Updater
  @State private var showThemePopover = false

  var body: some View {
    Form {
      Picker("Appearance", selection: $theme) {
        ForEach(ThemePreference.allCases, id: \.self) { pref in
          Text(pref.label).tag(pref)
        }
      }

      // Theme family (issue #36): a family bundles a light + dark variant; the active one follows
      // Appearance above. The button opens the swatch picker (also reachable via ⌘⇧K).
      LabeledContent("Theme") {
        Button {
          showThemePopover = true
        } label: {
          HStack(spacing: 6) {
            Text(themeFamily).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
          }
          // Fixed width so the button (and the popover anchored to it) doesn't shift left/right as
          // the selected family name changes length.
          .frame(width: 160, alignment: .trailing)
        }
        .popover(isPresented: $showThemePopover, arrowEdge: .bottom) {
          ThemePicker()
        }
      }

      Toggle("Copy on select", isOn: $copyOnSelect)

      Toggle("Confirm before quitting", isOn: $confirmOnQuit)

      Toggle("Confirm before closing a terminal", isOn: $confirmOnCloseTerminal)

      Toggle("Open a terminal in new workrooms", isOn: $openTerminalOnCreate)

      Toggle("Global show/hide hotkey (⌘§)", isOn: $globalHotkey)

      Toggle("Show notifications in the menu bar", isOn: $showMenuBarItem)

      Picker("Open file paths in", selection: $pathEditor) {
        Text("Default App").tag("")
        ForEach(ExternalEditor.installed) { editor in
          Text(editor.name).tag(editor.id)
        }
      }

      // Drives Sparkle's scheduled background checks (persisted as SUEnableAutomaticChecks).
      Toggle(
        "Automatically check for updates",
        isOn: Binding(
          get: { updater.automaticallyChecksForUpdates },
          set: { updater.automaticallyChecksForUpdates = $0 }))
    }
    .formStyle(.grouped)
    .frame(width: 440)
  }
}
