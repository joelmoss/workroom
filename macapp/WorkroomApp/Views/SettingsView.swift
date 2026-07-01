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
  @Default(.globalHotkey) private var globalHotkey
  @Default(.showMenuBarItem) private var showMenuBarItem
  // Bundle id of the editor for ⌘-clicked file paths; "" = the file's default app.
  @Default(.filePathEditor) private var pathEditor
  @Default(.themeFamily) private var themeFamily
  @Default(.diffViewMode) private var diffViewMode
  @Default(.terminalAgentEnabled) private var agentEnabled
  @Default(.terminalAgentAutoDiagnose) private var agentAutoDiagnose
  @Default(.terminalAgentRedactSecrets) private var agentRedactSecrets
  @Default(.terminalAgentBackend) private var agentBackend
  @Default(.terminalAgentPresentation) private var agentPresentation
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

      // Diff viewer layout (issue #66): unified (default) or side-by-side. Applies to newly opened
      // diff tabs; a narrow diff pane falls back to unified regardless.
      Picker("Diff view", selection: $diffViewMode) {
        ForEach(DiffViewMode.allCases, id: \.self) { mode in
          Text(mode.label).tag(mode)
        }
      }

      Toggle("Copy on select", isOn: $copyOnSelect)

      Toggle("Confirm before quitting", isOn: $confirmOnQuit)

      Toggle("Confirm before closing a terminal", isOn: $confirmOnCloseTerminal)

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

      // Inline terminal agent (issue #49). Opt-in: the sub-options appear only when it's on.
      Toggle("Suggest fixes for failed commands", isOn: $agentEnabled)
        .help("When a command fails, offer an AI diagnosis and a suggested fix below the terminal.")
      if agentEnabled {
        Picker("Agent", selection: $agentBackend) {
          Text("Auto (Claude, else Codex)").tag("auto")
          Text("Claude").tag("claude")
          Text("Codex").tag("codex")
        }
        Toggle("Diagnose automatically", isOn: $agentAutoDiagnose)
          .help("Run the diagnosis as soon as a command fails, instead of waiting for a click.")
        Picker("Show diagnosis", selection: $agentPresentation) {
          Text("As a banner below the pane").tag("banner")
          Text("Inline in the terminal").tag("inline")
        }
        .help(
          "Inline writes a dim diagnosis into the terminal output and puts the actions in a popover "
            + "on the tab, so nothing covers the terminal.")
        Toggle("Redact obvious secrets before sending", isOn: $agentRedactSecrets)
        Text(
          "A failed command's text and output are sent to the local "
            + "\(agentBackend == "codex" ? "codex" : "claude") CLI for a suggested fix. "
            + "Secret redaction is best-effort, not a guarantee — Codex is used only for the "
            + "interactive “Investigate” action, never the automatic diagnosis."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(width: 440)
  }
}
