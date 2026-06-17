import SwiftUI

/// Reference sheet listing every available keyboard shortcut, grouped by area (raised by the
/// "Keyboard Shortcuts…" command via the `.showKeyboardShortcuts` notification — a menu command
/// can't anchor a sheet, so `RootView` observes it and presents this, mirroring the Theme… picker).
///
/// The catalog below is **hand-maintained**: SwiftUI exposes no API to enumerate menu shortcuts, so
/// any change to `WorkroomCommands` (`WorkroomApp.swift`) or the `AppDelegate` key monitor (⌘1–9,
/// ⌥⌘ tab cycling, ⌃⌘ arrow pane navigation) must be reflected here by hand.
///
/// Glyph legend: ⌘ command · ⇧ shift · ⌥ option · ⌃ control · ←→↑↓ arrows · § section.
struct KeyboardShortcutsView: View {
  private let theme = ThemeService.shared
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Keyboard Shortcuts").font(.headline)
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
      .padding(12)
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ForEach(Self.groups) { group in
            VStack(alignment: .leading, spacing: 6) {
              Text(group.title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(theme.tokens.fgMuted)
                .padding(.horizontal, 4)
              ForEach(group.items) { item in
                ShortcutRow(item: item)
              }
            }
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
      }
    }
    .frame(width: 460, height: 560)
  }
}

/// One label-left, keycap-right row.
private struct ShortcutRow: View {
  private let theme = ThemeService.shared
  let item: ShortcutItem

  var body: some View {
    HStack(spacing: 12) {
      Text(item.label)
        .font(.system(size: 12))
        .foregroundStyle(theme.tokens.fg)
      Spacer(minLength: 0)
      Text(item.keys)
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(theme.tokens.fg)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(theme.tokens.surface)
            .overlay(
              RoundedRectangle(cornerRadius: 6).strokeBorder(theme.tokens.border, lineWidth: 0.5))
        )
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 2)
  }
}

/// A single shortcut: a human label + its pre-rendered glyph string.
struct ShortcutItem: Identifiable {
  let id = UUID()
  let label: String
  let keys: String
}

/// A named group of related shortcuts (tabs together, splits together, …).
struct ShortcutGroup: Identifiable {
  let id = UUID()
  let title: String
  let items: [ShortcutItem]
}

extension KeyboardShortcutsView {
  /// The curated catalog. Keep in sync with `WorkroomCommands` and the `AppDelegate` key monitor.
  static let groups: [ShortcutGroup] = [
    ShortcutGroup(
      title: "Tabs & Workrooms",
      items: [
        ShortcutItem(label: "Focus terminal tab 1–9", keys: "⌘1–9"),
        ShortcutItem(label: "Switch to workroom 1–9", keys: "⌥⌘1–9"),
        ShortcutItem(label: "Next terminal tab", keys: "⌥⌘→"),
        ShortcutItem(label: "Previous terminal tab", keys: "⌥⌘←"),
        ShortcutItem(label: "Next workroom tab", keys: "⇧⌥⌘→"),
        ShortcutItem(label: "Previous workroom tab", keys: "⇧⌥⌘←"),
      ]),
    ShortcutGroup(
      title: "Splits & Panes",
      items: [
        ShortcutItem(label: "Split Right", keys: "⌘D"),
        ShortcutItem(label: "Split Down", keys: "⇧⌘D"),
        ShortcutItem(label: "Move focus left", keys: "⌃⌘←"),
        ShortcutItem(label: "Move focus right", keys: "⌃⌘→"),
        ShortcutItem(label: "Move focus up", keys: "⌃⌘↑"),
        ShortcutItem(label: "Move focus down", keys: "⌃⌘↓"),
      ]),
    ShortcutGroup(
      title: "Terminals",
      items: [
        ShortcutItem(label: "New Terminal", keys: "⌘T"),
        ShortcutItem(label: "Close Terminal", keys: "⌘W"),
        ShortcutItem(label: "Scroll to Top", keys: "⌘↑"),
        ShortcutItem(label: "Scroll to Bottom", keys: "⌘↓"),
      ]),
    ShortcutGroup(
      title: "Run",
      items: [
        ShortcutItem(label: "Run", keys: "⌘R"),
        ShortcutItem(label: "Restart", keys: "⌥⌘R"),
        ShortcutItem(label: "Stop", keys: "⇧⌘R"),
      ]),
    ShortcutGroup(
      title: "View",
      items: [
        ShortcutItem(label: "Toggle Projects sidebar", keys: "⌃⌘S"),
        ShortcutItem(label: "Changes", keys: "⌥⌘C"),
        ShortcutItem(label: "Pull Request", keys: "⌥⌘P"),
        ShortcutItem(label: "Notifications", keys: "⌥⌘N"),
        ShortcutItem(label: "Theme…", keys: "⇧⌘K"),
        ShortcutItem(label: "Toggle Light/Dark Mode", keys: "⇧⌘L"),
      ]),
    ShortcutGroup(
      title: "Navigation",
      items: [
        ShortcutItem(label: "Back", keys: "⌘["),
        ShortcutItem(label: "Forward", keys: "⌘]"),
        ShortcutItem(label: "Next Notification", keys: "⇧⌘N"),
      ]),
    ShortcutGroup(
      title: "App",
      items: [
        ShortcutItem(label: "New Project…", keys: "⌘O"),
        ShortcutItem(label: "Settings", keys: "⌘,"),
        ShortcutItem(label: "Quit", keys: "⌘Q"),
        ShortcutItem(label: "Show/Hide Workroom (global)", keys: "⌘§"),
      ]),
  ]
}

/// Posted by the "Keyboard Shortcuts…" command; `RootView` presents this view as a sheet (a menu
/// command can't anchor one — same pattern as `.showThemePicker`).
extension Notification.Name {
  static let showKeyboardShortcuts = Notification.Name("workroom.showKeyboardShortcuts")
}
