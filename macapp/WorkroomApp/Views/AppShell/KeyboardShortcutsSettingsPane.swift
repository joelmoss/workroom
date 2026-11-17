import AppKit
import DesignSystem
import SwiftUI

/// Settings ▸ Keyboard Shortcuts (#148): every Workroom shortcut, grouped by relation with the
/// global ones first, each recordable, resettable and removable, and searchable by name,
/// description or keys.
struct KeyboardShortcutsSettingsPane: View {
  @State private var model = ShortcutRecorderModel()
  @State private var query = ""
  @State private var confirmingRestore = false
  @Environment(\.themeTokens) private var tokens

  private var shortcuts: Shortcuts { .shared }

  var body: some View {
    let table = shortcuts.table
    let groups = visibleGroups(table)
    VStack(spacing: 0) {
      searchBar
      // An edge for the list to scroll under, rather than rows meeting the field.
      Divider()
      Form {
        if groups.isEmpty {
          Text("No shortcuts match.")
            .foregroundStyle(tokens.fgMuted)
            .accessibilityIdentifier("settings.shortcuts.noMatches")
        }
        ForEach(groups, id: \.group) { entry in
          Section {
            ForEach(entry.actions) { action in
              ShortcutRow(action: action, table: table, model: model)
            }
          } header: {
            Text(entry.group.title)
          } footer: {
            #if DEBUG
              // Said once for the group, not on each of its rows.
              if entry.group == .global {
                Text(
                  "Debug builds don't register global shortcuts, so these work only while "
                    + "Workroom is in front."
                )
                .font(.caption)
                .foregroundStyle(tokens.fgMuted)
                .accessibilityIdentifier("settings.shortcuts.debugNote")
              }
            #endif
          }
        }
        Section {
          HStack {
            Spacer()
            Button("Restore Defaults…") { confirmingRestore = true }
              .disabled(shortcuts.customCount == 0)
              .help("Put every shortcut back to Workroom's default.")
              .accessibilityIdentifier("settings.shortcuts.restoreDefaults")
          }
          // A button under the list, not a card of its own.
          .listRowBackground(Color.clear)
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      // A new search starts at the top of its results, not wherever the full list was scrolled.
      .id("\(query)|\(model.searchChord?.label ?? "")")
    }
    // System Settings' App Shortcuts change outside the app.
    .onAppear { shortcuts.refreshSystemSettings() }
    .onDisappear { model.stop() }
    .alert(
      "Shortcut in use", isPresented: pendingBinding, presenting: model.pending
    ) { pending in
      Button("Cancel", role: .cancel) { model.pending = nil }
        .keyboardShortcut(.defaultAction)
        .help("Keep every shortcut as it is.")
        .accessibilityIdentifier("settings.shortcuts.conflict.cancel")
      Button("Use for \(pending.action.label)") { model.confirm(pending) }
        .help("Take the keys, leaving the actions that had them with no shortcut.")
        .accessibilityIdentifier("settings.shortcuts.conflict.use")
    } message: { pending in
      Text(
        ShortcutRecording.conflictMessage(
          for: pending.action, pending.binding, conflicts: pending.conflicts))
    }
    .confirmationDialog(
      "Restore every shortcut to its default?", isPresented: $confirmingRestore
    ) {
      Button("Restore Defaults", role: .destructive) { shortcuts.restoreDefaults() }
        .accessibilityIdentifier("settings.shortcuts.restoreDefaults.confirm")
      Button("Cancel", role: .cancel) {}
        .help("Keep your shortcuts.")
        .accessibilityIdentifier("settings.shortcuts.restoreDefaults.cancel")
    } message: {
      let count = shortcuts.customCount
      Text("This clears \(count) custom shortcut\(count == 1 ? "" : "s").")
    }
  }

  private var pendingBinding: Binding<Bool> {
    Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } })
  }

  /// Search by text, or by the keys the record button caught.
  private var searchBar: some View {
    HStack(spacing: 6) {
      TextField("Search shortcuts", text: $query)
        .textFieldStyle(.roundedBorder)
        .help("Find a shortcut by its name, what it does, or its keys (⌘T, cmd t).")
        .accessibilityIdentifier("settings.shortcuts.search")
        .onChange(of: query) { if !query.isEmpty { model.searchChord = nil } }
      let recording = model.isRecording(.search)
      Button {
        query = ""
        model.toggle(.search)
      } label: {
        Image(systemName: recording ? "keyboard.fill" : "keyboard")
          .foregroundStyle(recording ? tokens.failure : tokens.fg)
      }
      .buttonStyle(ToolbarIconButtonStyle())
      .help(
        recording
          ? "Press the keys to find, or Escape to cancel."
          : "Press keys to find the shortcut that holds them."
      )
      .accessibilityLabel(recording ? "Recording keys to find" : "Find by keys")
      .accessibilityIdentifier("settings.shortcuts.searchRecord")
      if let chord = model.searchChord {
        ShortcutKeysText(chord.label)
          .accessibilityIdentifier("settings.shortcuts.searchKeys")
        Button {
          model.searchChord = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(ToolbarIconButtonStyle())
        .help("Show every shortcut again.")
        .accessibilityLabel("Clear the keys")
        .accessibilityIdentifier("settings.shortcuts.searchKeys.clear")
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 12)
    .padding(.bottom, 10)
  }

  private func visibleGroups(_ table: ShortcutTable)
    -> [(group: ShortcutGroup, actions: [ShortcutAction])]
  {
    ShortcutGroup.allCases.compactMap { group in
      let actions = group.actions.filter { action in
        if let chord = model.searchChord {
          guard let binding = table.binding(for: action) else { return false }
          return ShortcutTable.chords(for: action, binding).contains(chord)
        }
        return Shortcuts.matches(action, query: query, table: table)
      }
      return actions.isEmpty ? nil : (group, actions)
    }
  }
}

/// One shortcut: its name and what it does, its keys, and Reset and Remove.
private struct ShortcutRow: View {
  let action: ShortcutAction
  let table: ShortcutTable
  let model: ShortcutRecorderModel
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    let resolved = table.resolved[action]
    let binding = resolved?.binding
    let fromSystem = resolved?.source == .systemSettings
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(action.label)
        Text(action.summary)
          .font(.caption)
          .foregroundStyle(tokens.fgMuted)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(notes(resolved), id: \.self) { note in
          Text(note.text)
            .font(.caption)
            .foregroundStyle(note.isProblem ? tokens.failure : tokens.fgMuted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("settings.shortcuts.\(note.kind).\(action.rawValue)")
        }
      }
      Spacer(minLength: 8)
      if fromSystem {
        ShortcutKeysText(table.label(for: action) ?? "")
          .foregroundStyle(tokens.fgMuted)
          .help("Set for this menu item in System Settings ▸ Keyboard ▸ App Shortcuts.")
          .accessibilityIdentifier("settings.shortcuts.system.\(action.rawValue)")
        Button("Open System Settings") { Self.openKeyboardSettings() }
          .help("Change or remove it in System Settings ▸ Keyboard ▸ Keyboard Shortcuts.")
          .accessibilityIdentifier("settings.shortcuts.openSystemSettings.\(action.rawValue)")
      } else {
        if resolved?.isCustom == true || resolved?.displacedBy != nil {
          Button {
            model.reset(action)
          } label: {
            Image(systemName: "arrow.uturn.backward.circle")
          }
          .buttonStyle(ToolbarIconButtonStyle())
          .help(resetHelp)
          .accessibilityLabel("Reset \(action.label)'s shortcut")
          .accessibilityIdentifier("settings.shortcuts.reset.\(action.rawValue)")
        }
        ShortcutRecorderButton(action: action, model: model, table: table)
        Button {
          model.stop()
          Shortcuts.shared.unset(action)
        } label: {
          Image(systemName: "minus.circle")
        }
        .buttonStyle(ToolbarIconButtonStyle())
        .disabled(binding == nil)
        .help("Remove this shortcut, so \(action.label) has none.")
        .accessibilityLabel("Remove \(action.label)'s shortcut")
        .accessibilityIdentifier("settings.shortcuts.remove.\(action.rawValue)")
      }
    }
    .help(action.summary)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("settings.shortcuts.row.\(action.rawValue)")
  }

  private var resetHelp: String {
    guard let binding = action.defaultBinding else { return "Go back to no shortcut." }
    return "Go back to \(ShortcutTable.label(for: action, binding))."
  }

  private struct Note: Hashable {
    let kind: String
    let text: String
    var isProblem = false
  }

  private func notes(_ resolved: ResolvedShortcut?) -> [Note] {
    var notes: [Note] = []
    if let problem = model.problems[action] {
      notes.append(Note(kind: "problem", text: problem, isProblem: true))
    }
    if let holder = resolved?.displacedBy, let keys = action.defaultBinding {
      let label = ShortcutTable.label(for: action, keys)
      let text =
        table.resolved[holder]?.source == .systemSettings
        ? "Unset: System Settings gives \(label) to \(holder.label)."
        : "Unset: conflicted with your \(label) for \(holder.label)."
      notes.append(Note(kind: "displaced", text: text))
    }
    if resolved?.source == .systemSettings {
      notes.append(Note(kind: "systemNote", text: "Set in System Settings"))
    }
    if let note = ShortcutRecording.terminalNote(for: action, resolved?.binding) {
      notes.append(Note(kind: "terminalNote", text: note))
    }
    return notes
  }

  private static func openKeyboardSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
      NSWorkspace.shared.open(url)
    }
  }
}
