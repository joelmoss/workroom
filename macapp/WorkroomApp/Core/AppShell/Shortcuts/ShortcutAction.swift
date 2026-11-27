import Carbon.HIToolbox
import Foundation
import WorkroomDomain

/// The groups Settings ▸ Keyboard Shortcuts lists, by relation, in order: global shortcuts first
/// (#148).
enum ShortcutGroup: String, CaseIterable, Identifiable, Sendable {
  case global, workrooms, workroomTabs, terminalTabs, panes, terminal, run, versionControl
  case sidebar, navigation, windows, appearance, app

  var id: Self { self }

  var title: String {
    switch self {
    case .global: "Global"
    case .workrooms: "Projects & Workrooms"
    case .workroomTabs: "Workroom Tabs"
    case .terminalTabs: "Terminal Tabs"
    case .panes: "Panes & Splits"
    case .terminal: "In the Terminal"
    case .run: "Run Command"
    case .versionControl: "Version Control"
    case .sidebar: "Sidebar & Inspector"
    case .navigation: "Navigation & Attention"
    case .windows: "Windows"
    case .appearance: "Appearance"
    case .app: "App"
    }
  }

  /// The actions in this group, in the pane's order.
  var actions: [ShortcutAction] { ShortcutAction.allCases.filter { $0.group == self } }
}

/// What a shortcut's binding is made of.
enum ShortcutKind: Equatable, Sendable {
  /// One key with its modifiers.
  case single
  /// A quick switcher: modifiers held while Tab steps (⇧ steps back), released to commit.
  case switcher
}

/// A shortcut's binding: a chord for a single shortcut, modifiers for a switcher.
enum ShortcutBinding: Codable, Hashable, Sendable {
  case chord(KeyChord)
  case modifiers(KeyModifiers)

  /// The modifiers it holds: a chord's, or a switcher's own.
  var heldModifiers: KeyModifiers {
    switch self {
    case .chord(let chord): chord.modifiers
    case .modifiers(let modifiers): modifiers
    }
  }
}

/// Every Workroom action that can have a shortcut (#148, ADR 0076). The raw value is the stable id
/// saved changes are keyed by: never rename one.
///
/// Standard items macOS supplies (Quit, Hide, Hide Others, Settings…, Minimize and the Edit menu's
/// Undo through Select All) are not actions here; `StandardShortcut` holds their keys.
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
  // Global
  case showHideWorkroom, quickTerminal
  // Projects & Workrooms
  case newProject, newWorkroom, newWorkroomSplit, openWorkroom, openWorkroomSplit, openInEditor
  case revealInFinder, editLabel, removeLabel, moveWorkroomToNewWindow, deleteWorkroom
  // Workroom Tabs
  case switchToWorkroomTab1, switchToWorkroomTab2, switchToWorkroomTab3, switchToWorkroomTab4
  case switchToWorkroomTab5, switchToWorkroomTab6, switchToWorkroomTab7, switchToWorkroomTab8
  case switchToWorkroomTab9
  case nextWorkroomTab, previousWorkroomTab, lastUsedWorkroom
  // Terminal Tabs
  case newTerminal, newStandaloneTerminal, closeTab, closeOtherTabs, closeAllTabs
  case focusTerminalTab1, focusTerminalTab2, focusTerminalTab3, focusTerminalTab4
  case focusTerminalTab5, focusTerminalTab6, focusTerminalTab7, focusTerminalTab8
  case focusTerminalTab9
  case nextTerminalTab
  case previousTerminalTab, confirmBeforeClosingTerminal
  // Panes & Splits
  case splitRight, splitDown, splitLeft, splitUp
  case focusPaneLeft, focusPaneRight, focusPaneUp, focusPaneDown
  case lastUsedPane, movePaneWindow
  // In the Terminal
  case find, findNext, findPrevious, scrollToTop, scrollToBottom, copyOnSelect
  // Run Command
  case run, restart, stop, goToRunTerminal
  // Version Control
  case commit, fetch, push, pullWithRebase, goToPullRequest, changeDraft
  // Sidebar & Inspector
  case projects, showOpenView, showProjectsView, inspector, details, changes, history
  case pullRequestPane, files
  // Navigation & Attention
  case back, forward, nextNotification, goToWaitingTerminal
  // Windows
  case newWindow, nextWindow, previousWindow
  // Appearance
  case theme, toggleLightDark
  // App
  case keyboardShortcuts, checkForUpdates, installCommandLine, documentation
  case confirmBeforeQuitting

  var id: Self { self }

  var group: ShortcutGroup {
    switch self {
    case .showHideWorkroom, .quickTerminal: .global
    case .newProject, .newWorkroom, .newWorkroomSplit, .openWorkroom, .openWorkroomSplit,
      .openInEditor, .revealInFinder, .editLabel, .removeLabel, .moveWorkroomToNewWindow,
      .deleteWorkroom:
      .workrooms
    case .switchToWorkroomTab1, .switchToWorkroomTab2, .switchToWorkroomTab3, .switchToWorkroomTab4,
      .switchToWorkroomTab5, .switchToWorkroomTab6, .switchToWorkroomTab7, .switchToWorkroomTab8,
      .switchToWorkroomTab9, .nextWorkroomTab, .previousWorkroomTab, .lastUsedWorkroom:
      .workroomTabs
    case .newTerminal, .newStandaloneTerminal, .closeTab, .closeOtherTabs, .closeAllTabs,
      .focusTerminalTab1,
      .focusTerminalTab2, .focusTerminalTab3, .focusTerminalTab4, .focusTerminalTab5,
      .focusTerminalTab6, .focusTerminalTab7, .focusTerminalTab8, .focusTerminalTab9,
      .nextTerminalTab, .previousTerminalTab, .confirmBeforeClosingTerminal:
      .terminalTabs
    case .splitRight, .splitDown, .splitLeft, .splitUp, .focusPaneLeft, .focusPaneRight,
      .focusPaneUp, .focusPaneDown, .lastUsedPane,
      .movePaneWindow:
      .panes
    case .find, .findNext, .findPrevious, .scrollToTop, .scrollToBottom, .copyOnSelect: .terminal
    case .run, .restart, .stop, .goToRunTerminal: .run
    case .commit, .fetch, .push, .pullWithRebase, .goToPullRequest, .changeDraft: .versionControl
    case .projects, .showOpenView, .showProjectsView, .inspector, .details, .changes, .history,
      .pullRequestPane, .files:
      .sidebar
    case .back, .forward, .nextNotification, .goToWaitingTerminal: .navigation
    case .newWindow, .nextWindow, .previousWindow: .windows
    case .theme, .toggleLightDark: .appearance
    case .keyboardShortcuts, .checkForUpdates, .installCommandLine, .documentation,
      .confirmBeforeQuitting:
      .app
    }
  }

  var kind: ShortcutKind {
    switch self {
    case .lastUsedWorkroom, .lastUsedPane: .switcher
    default: .single
    }
  }

  /// A shortcut that works from any app, registered with Carbon rather than matched in the app.
  var isGlobal: Bool { self == .showHideWorkroom || self == .quickTerminal }

  /// The row's name in Settings.
  var label: String {
    switch self {
    case .showHideWorkroom: "Show/Hide Workroom"
    case .quickTerminal: "Quick Terminal"
    case .newProject: "New Project…"
    case .newWorkroom: "New Workroom…"
    case .newWorkroomSplit: "New Workroom (split right)"
    case .openWorkroom: "Open Workroom…"
    case .openWorkroomSplit: "Open Workroom (split right)"
    case .openInEditor: "Open in Editor"
    case .revealInFinder: "Reveal in Finder"
    case .editLabel: "Set or Edit Label…"
    case .removeLabel: "Remove Label"
    case .moveWorkroomToNewWindow: "Move Workroom into New Window"
    case .deleteWorkroom: "Delete Workroom…"
    case .switchToWorkroomTab1, .switchToWorkroomTab2, .switchToWorkroomTab3, .switchToWorkroomTab4,
      .switchToWorkroomTab5, .switchToWorkroomTab6, .switchToWorkroomTab7, .switchToWorkroomTab8,
      .switchToWorkroomTab9:
      "Switch to Workroom Tab \(position)"
    case .nextWorkroomTab: "Next Workroom Tab"
    case .previousWorkroomTab: "Previous Workroom Tab"
    case .lastUsedWorkroom: "Last-Used Workroom"
    case .newTerminal: "New Terminal"
    case .newStandaloneTerminal: "New Standalone Terminal"
    case .closeTab: "Close Tab"
    case .closeOtherTabs: "Close Other Tabs"
    case .closeAllTabs: "Close All Tabs"
    case .focusTerminalTab1, .focusTerminalTab2, .focusTerminalTab3, .focusTerminalTab4,
      .focusTerminalTab5, .focusTerminalTab6, .focusTerminalTab7, .focusTerminalTab8,
      .focusTerminalTab9:
      "Focus Terminal Tab \(position)"
    case .nextTerminalTab: "Next Terminal Tab"
    case .previousTerminalTab: "Previous Terminal Tab"
    case .confirmBeforeClosingTerminal: "Confirm Before Closing a Terminal"
    case .splitRight: "Split Right"
    case .splitDown: "Split Down"
    case .splitLeft: "Split Left"
    case .splitUp: "Split Up"
    case .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown:
      "Focus Pane \(paneDirectionName)"
    case .lastUsedPane: "Last-Used Pane"
    case .movePaneWindow: "Move Pane into New Window / Back"
    case .find: "Find…"
    case .findNext: "Find Next"
    case .findPrevious: "Find Previous"
    case .scrollToTop: "Scroll to Top"
    case .scrollToBottom: "Scroll to Bottom"
    case .copyOnSelect: "Copy on Select"
    case .run: "Run"
    case .restart: "Restart"
    case .stop: "Stop"
    case .goToRunTerminal: "Go to Run Terminal"
    case .commit: "Commit…"
    case .fetch: "Fetch"
    case .push: "Push"
    case .pullWithRebase: "Pull with Rebase"
    case .goToPullRequest: "Go to Pull Request"
    case .changeDraft: "Ready for Review / Convert to Draft"
    case .projects: "Show Sidebar"
    case .showOpenView: "Sidebar: Open"
    case .showProjectsView: "Sidebar: Projects"
    case .inspector: "Show Inspector"
    case .details: "Details"
    case .changes: "Changes"
    case .history: "History"
    case .pullRequestPane: "Pull Request"
    case .files: "Files"
    case .back: "Back"
    case .forward: "Forward"
    case .nextNotification: "Next Notification"
    case .goToWaitingTerminal: "Go to Terminal That Needs You"
    case .newWindow: "New Window"
    case .nextWindow: "Next Window"
    case .previousWindow: "Previous Window"
    case .theme: "Theme…"
    case .toggleLightDark: "Toggle Light/Dark Mode"
    case .keyboardShortcuts: "Keyboard Shortcuts…"
    case .checkForUpdates: "Check for Updates…"
    case .installCommandLine: "Install ‘workroom’ Command in PATH…"
    case .documentation: "Workroom Documentation"
    case .confirmBeforeQuitting: "Confirm Before Quitting"
    }
  }

  /// One line on what it does: the row's tooltip, and searched with the label.
  var summary: String {
    switch self {
    case .showHideWorkroom: "Bring Workroom to the front, or hide it, from any app."
    case .quickTerminal: "Slide the Quick Terminal in or out, from any app."
    case .newProject: "Add a git repository to Workroom."
    case .newWorkroom: "Create a workroom in one of your projects."
    case .newWorkroomSplit: "Create a workroom beside the current one."
    case .openWorkroom: "Switch to a project's root or one of its workrooms."
    case .openWorkroomSplit: "Open a workroom beside the current one."
    case .openInEditor: "Open the selected workroom in your editor."
    case .revealInFinder: "Show the selected workroom's folder in Finder."
    case .editLabel: "Give the selected workroom a label, or change it."
    case .removeLabel: "Take the selected workroom's label off."
    case .moveWorkroomToNewWindow: "Move the selected workroom and its terminals into a new window."
    case .deleteWorkroom: "Delete the selected workroom, after asking."
    case .switchToWorkroomTab1, .switchToWorkroomTab2, .switchToWorkroomTab3, .switchToWorkroomTab4,
      .switchToWorkroomTab5, .switchToWorkroomTab6, .switchToWorkroomTab7, .switchToWorkroomTab8,
      .switchToWorkroomTab9:
      "Switch to the workroom tab at position \(position)."
    case .nextWorkroomTab: "Switch to the workroom tab on the right."
    case .previousWorkroomTab: "Switch to the workroom tab on the left."
    case .lastUsedWorkroom: "Step through open workrooms, most recent first. Hold to see them all."
    case .newTerminal: "Open a terminal tab in the selected workroom."
    case .newStandaloneTerminal: "Open a terminal that belongs to no project, with its own row."
    case .closeTab: "Close the focused tab or pane."
    case .closeOtherTabs: "Close every tab but the focused one."
    case .closeAllTabs: "Close every tab in the selected workroom."
    case .focusTerminalTab1, .focusTerminalTab2, .focusTerminalTab3, .focusTerminalTab4,
      .focusTerminalTab5, .focusTerminalTab6, .focusTerminalTab7, .focusTerminalTab8,
      .focusTerminalTab9:
      "Focus the terminal tab at position \(position)."
    case .nextTerminalTab: "Focus the terminal tab on the right."
    case .previousTerminalTab: "Focus the terminal tab on the left."
    case .confirmBeforeClosingTerminal: "Turn the confirmation before closing a terminal on or off."
    case .splitRight: "Split the focused pane with a terminal on the right."
    case .splitDown: "Split the focused pane with a terminal below."
    case .splitLeft: "Split the focused pane with a terminal on the left."
    case .splitUp: "Split the focused pane with a terminal above."
    case .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown:
      "Move focus to the pane \(paneDirectionPhrase)."
    case .lastUsedPane:
      "Step through the workroom's panes, most recent first. Hold to see them all."
    case .movePaneWindow: "Pop the focused pane into its own window, or put it back."
    case .find: "Search the focused terminal's scrollback or file."
    case .findNext: "Go to the next match."
    case .findPrevious: "Go to the previous match."
    case .scrollToTop: "Scroll the focused terminal to the top of its scrollback."
    case .scrollToBottom: "Scroll the focused terminal to the bottom."
    case .copyOnSelect: "Turn copying selected terminal text on or off."
    case .run: "Run the project's run command, or go to it if it's running."
    case .restart: "Restart the running run command."
    case .stop: "Stop the running run command."
    case .goToRunTerminal: "Go to the run command's terminal."
    case .commit: "Commit the selected workroom's changes."
    case .fetch: "Fetch from the remote."
    case .push: "Push the branch to the remote."
    case .pullWithRebase: "Pull from the remote, rebasing local commits."
    case .goToPullRequest: "Open the branch's pull request in your browser."
    case .changeDraft: "Mark the pull request ready for review, or turn it back into a draft."
    case .projects: "Show or hide the Projects sidebar."
    case .showOpenView: "Show the sidebar's Open view: what this window has open."
    case .showProjectsView: "Show the sidebar's Projects view: every project and its workrooms."
    case .inspector: "Show or hide the inspector."
    case .details: "Show or hide the inspector's Details."
    case .changes: "Show or hide the inspector's Changes."
    case .history: "Show or hide the inspector's History."
    case .pullRequestPane: "Show or hide the inspector's Pull Request."
    case .files: "Show or hide the inspector's Files."
    case .back: "Go back to where you were."
    case .forward: "Go forward again."
    case .nextNotification: "Open the oldest unread notification."
    case .goToWaitingTerminal: "Go to the terminal that has waited longest for you."
    case .newWindow: "Open a new Workroom window."
    case .nextWindow: "Move focus to the next window."
    case .previousWindow: "Move focus to the previous window."
    case .theme: "Choose a theme."
    case .toggleLightDark: "Switch between light and dark."
    case .keyboardShortcuts: "Open this list."
    case .checkForUpdates: "Check for a newer version of Workroom."
    case .installCommandLine: "Put the workroom command in your PATH."
    case .documentation: "Open Workroom's documentation."
    case .confirmBeforeQuitting: "Turn the confirmation before quitting on or off."
    }
  }

  /// The binding it has until the user changes it; nil for none.
  var defaultBinding: ShortcutBinding? {
    func key(_ character: String, _ modifiers: KeyModifiers) -> ShortcutBinding {
      .chord(.key(character, modifiers))
    }
    func named(_ code: Int, _ modifiers: KeyModifiers) -> ShortcutBinding {
      .chord(.named(code, modifiers))
    }
    switch self {
    case .showHideWorkroom: return key("§", .command)
    case .quickTerminal: return key("§", .option)
    case .newWorkroom: return key("n", .command)
    case .newWorkroomSplit: return key("n", [.command, .option])
    case .openWorkroom: return key("o", .command)
    case .openWorkroomSplit: return key("o", [.command, .option])
    case .openInEditor: return key("o", [.command, .shift])
    case .switchToWorkroomTab1, .switchToWorkroomTab2, .switchToWorkroomTab3, .switchToWorkroomTab4,
      .switchToWorkroomTab5, .switchToWorkroomTab6, .switchToWorkroomTab7, .switchToWorkroomTab8,
      .switchToWorkroomTab9:
      return key("\(position)", [.command, .option])
    case .nextWorkroomTab: return named(kVK_RightArrow, [.command, .option, .shift])
    case .previousWorkroomTab: return named(kVK_LeftArrow, [.command, .option, .shift])
    case .lastUsedWorkroom: return .modifiers(.option)
    case .newTerminal: return key("t", .command)
    case .newStandaloneTerminal: return key("t", [.command, .option])
    case .closeTab: return key("w", .command)
    case .focusTerminalTab1, .focusTerminalTab2, .focusTerminalTab3, .focusTerminalTab4,
      .focusTerminalTab5, .focusTerminalTab6, .focusTerminalTab7, .focusTerminalTab8,
      .focusTerminalTab9:
      return key("\(position)", .command)
    case .nextTerminalTab: return named(kVK_RightArrow, [.command, .option])
    case .previousTerminalTab: return named(kVK_LeftArrow, [.command, .option])
    case .splitRight: return key("d", .command)
    case .splitDown: return key("d", [.command, .shift])
    case .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown:
      return named(paneArrowKeyCode, [.command, .control])
    case .lastUsedPane: return .modifiers(.control)
    case .movePaneWindow: return key("o", [.command, .control])
    case .find: return key("f", .command)
    case .findNext: return key("g", .command)
    case .findPrevious: return key("g", [.command, .shift])
    case .scrollToTop: return named(kVK_UpArrow, .command)
    case .scrollToBottom: return named(kVK_DownArrow, .command)
    case .run: return key("r", .command)
    case .restart: return key("r", [.command, .option])
    case .stop: return key("r", [.command, .shift])
    case .commit: return named(kVK_Return, [.command, .option])
    case .fetch: return key("f", [.command, .option, .shift])
    case .push: return key("p", [.command, .shift])
    case .pullWithRebase: return key("p", [.command, .option, .shift])
    case .projects: return key("s", [.command, .control])
    // Beside ⌃⌘S, Show Sidebar: ⌘1 and ⌘2, the obvious keys, are Switch to Workroom Tab 1 and 2.
    case .showOpenView: return key("t", [.command, .control])
    case .showProjectsView: return key("p", [.command, .control])
    case .inspector: return key("b", .command)
    case .details: return key("i", [.command, .option])
    case .changes: return key("c", [.command, .option])
    case .history: return key("y", [.command, .option])
    case .pullRequestPane: return key("p", [.command, .option])
    case .files: return key("f", [.command, .option])
    case .back: return key("[", .command)
    case .forward: return key("]", .command)
    case .nextNotification: return key("n", [.command, .shift])
    case .goToWaitingTerminal: return key("m", [.command, .shift])
    case .nextWindow: return key("`", .command)
    case .previousWindow: return key("`", [.command, .shift])
    case .theme: return key("k", [.command, .shift])
    case .toggleLightDark: return key("l", [.command, .shift])
    case .newProject, .revealInFinder, .editLabel, .removeLabel, .moveWorkroomToNewWindow,
      .deleteWorkroom, .closeOtherTabs, .closeAllTabs, .confirmBeforeClosingTerminal, .splitLeft,
      .splitUp, .copyOnSelect, .goToRunTerminal, .goToPullRequest, .changeDraft, .newWindow,
      .keyboardShortcuts, .checkForUpdates, .installCommandLine, .documentation,
      .confirmBeforeQuitting:
      return nil
    }
  }

  /// Whether its keys are kept from a focused terminal while bound, so the app's own handling
  /// wins over a TUI in an enhanced keyboard mode (`GhosttySurfaceView.isAppShortcut`). Off for the
  /// actions that hand their keys to the terminal when they can't act: a workroom tab that isn't
  /// there, a pane focus that can't move, a switcher with nothing to switch to (ADR 0076).
  var reservesFromTerminal: Bool {
    switch self {
    case .switchToWorkroomTab1, .switchToWorkroomTab2, .switchToWorkroomTab3, .switchToWorkroomTab4,
      .switchToWorkroomTab5, .switchToWorkroomTab6, .switchToWorkroomTab7, .switchToWorkroomTab8,
      .switchToWorkroomTab9, .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
      .lastUsedWorkroom, .lastUsedPane:
      false
    default: true
    }
  }

  /// The menu item titles it has, for System Settings' App Shortcuts, which are keyed by title.
  /// Empty for an action with no single menu item.
  var menuTitles: [String] {
    switch self {
    // Go ▸ Terminal Tab and Workroom Tab name their items after the tabs.
    case .focusTerminalTab1, .focusTerminalTab2, .focusTerminalTab3, .focusTerminalTab4,
      .focusTerminalTab5, .focusTerminalTab6, .focusTerminalTab7, .focusTerminalTab8,
      .focusTerminalTab9, .switchToWorkroomTab1, .switchToWorkroomTab2, .switchToWorkroomTab3,
      .switchToWorkroomTab4, .switchToWorkroomTab5, .switchToWorkroomTab6, .switchToWorkroomTab7,
      .switchToWorkroomTab8, .switchToWorkroomTab9:
      []
    case .editLabel: ["Set Label…", "Edit Label…"]
    case .movePaneWindow: ["Move pane into new window", "Move back to main window"]
    case .changeDraft: ["Ready for Review", "Convert to Draft"]
    case .toggleLightDark: ["Light Mode", "Dark Mode"]
    // View ▸ Sidebar's items: their labels say which submenu they are in.
    case .showOpenView: [SidebarView.open.title]
    case .showProjectsView: [SidebarView.projects.title]
    case .openInEditor: ExternalEditor.allTitles
    // The app menu names it after the app: Workroom, Workroom Dev or Workroom Nightly.
    case .showHideWorkroom: ["Show/Hide \(Self.appName)"]
    default: [label]
    }
  }

  /// The app's name as its menus write it: Workroom, Workroom Dev or Workroom Nightly.
  static let appName =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Workroom"
}

extension StandardShortcut {
  /// The standard keys kept from a focused terminal, looked up on every key press there.
  static let reserved = Set(all.filter(\.reservesFromTerminal).map(\.chord))
}

/// The keys of the standard items macOS supplies, which aren't Workroom's to rebind (#148): the
/// recorder refuses them, and the ones a terminal must never see stay reserved from it.
struct StandardShortcut: Sendable {
  let chord: KeyChord
  let name: String
  /// Kept from a focused terminal, so the menu item fires (Quit, Hide, Minimize, Settings…). The
  /// Edit menu's keys are not: the terminal handles copy and paste itself.
  let reservesFromTerminal: Bool

  static let all: [StandardShortcut] = [
    StandardShortcut(chord: .key("q", .command), name: "Quit", reservesFromTerminal: true),
    StandardShortcut(chord: .key("h", .command), name: "Hide", reservesFromTerminal: true),
    StandardShortcut(
      chord: .key("h", [.command, .option]), name: "Hide Others", reservesFromTerminal: false),
    StandardShortcut(chord: .key(",", .command), name: "Settings…", reservesFromTerminal: true),
    StandardShortcut(chord: .key("m", .command), name: "Minimize", reservesFromTerminal: true),
    StandardShortcut(chord: .key("z", .command), name: "Undo", reservesFromTerminal: false),
    StandardShortcut(
      chord: .key("z", [.command, .shift]), name: "Redo", reservesFromTerminal: false),
    StandardShortcut(chord: .key("x", .command), name: "Cut", reservesFromTerminal: false),
    StandardShortcut(chord: .key("c", .command), name: "Copy", reservesFromTerminal: false),
    StandardShortcut(chord: .key("v", .command), name: "Paste", reservesFromTerminal: false),
    StandardShortcut(chord: .key("a", .command), name: "Select All", reservesFromTerminal: false),
    // AppKit wires its own Toggle Sidebar to the native sidebar column RootView keeps for title-bar
    // layering; the key monitor catches ⌥⌘S and turns it into Projects instead (issue #128).
    StandardShortcut(
      chord: .key("s", [.command, .option]), name: "Toggle Sidebar", reservesFromTerminal: true),
    StandardShortcut(
      chord: .named(kVK_Tab, .command), name: "Switch Apps", reservesFromTerminal: false),
    StandardShortcut(
      chord: .named(kVK_Tab, [.command, .shift]), name: "Switch Apps", reservesFromTerminal: false),
    StandardShortcut(
      chord: .named(kVK_Space, .command), name: "Spotlight", reservesFromTerminal: false),
    // AppKit's own: File ▸ Close All (the alternate of Close), Edit ▸ Emoji & Symbols, and the ⌥
    // alternates of Quit and Minimize, which some macOS versions add to the menu bar.
    StandardShortcut(
      chord: .key("w", [.command, .option]), name: "Close All", reservesFromTerminal: false),
    StandardShortcut(
      chord: .key("q", [.command, .option]), name: "Quit and Keep Windows",
      reservesFromTerminal: false),
    StandardShortcut(
      chord: .key("m", [.command, .option]), name: "Minimize All", reservesFromTerminal: false),
    StandardShortcut(
      chord: .named(kVK_Space, [.command, .control]), name: "Emoji & Symbols",
      reservesFromTerminal: false),
  ]
}

extension ShortcutAction {
  /// Focus Terminal Tab 1–9, in order: the action for each tab position.
  static let terminalTabs: [ShortcutAction] = [
    .focusTerminalTab1, .focusTerminalTab2, .focusTerminalTab3, .focusTerminalTab4,
    .focusTerminalTab5, .focusTerminalTab6, .focusTerminalTab7, .focusTerminalTab8,
    .focusTerminalTab9,
  ]
  /// Switch to Workroom Tab 1–9, in order.
  static let workroomTabs: [ShortcutAction] = [
    .switchToWorkroomTab1, .switchToWorkroomTab2, .switchToWorkroomTab3, .switchToWorkroomTab4,
    .switchToWorkroomTab5, .switchToWorkroomTab6, .switchToWorkroomTab7, .switchToWorkroomTab8,
    .switchToWorkroomTab9,
  ]
  /// Focus Pane Left, Right, Up and Down.
  static let paneFocus: [ShortcutAction] = [
    .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
  ]

  /// The 0-based tab position a Focus Terminal Tab action is for.
  var terminalTabIndex: Int? { Self.terminalTabs.firstIndex(of: self) }
  /// The 0-based tab position a Switch to Workroom Tab action is for.
  var workroomTabIndex: Int? { Self.workroomTabs.firstIndex(of: self) }

  /// The direction a Focus Pane action moves.
  var paneDirection: PaneDirection? {
    switch self {
    case .focusPaneLeft: .left
    case .focusPaneRight: .right
    case .focusPaneUp: .up
    case .focusPaneDown: .down
    default: nil
    }
  }

  /// 1–9 for a tab action, in its label and default key.
  fileprivate var position: Int { (terminalTabIndex ?? workroomTabIndex ?? 0) + 1 }

  fileprivate var paneDirectionName: String {
    switch paneDirection {
    case .left: "Left"
    case .right: "Right"
    case .up: "Up"
    case .down: "Down"
    case nil: ""
    }
  }

  fileprivate var paneDirectionPhrase: String {
    switch paneDirection {
    case .left: "on the left"
    case .right: "on the right"
    case .up: "above"
    case .down: "below"
    case nil: ""
    }
  }

  fileprivate var paneArrowKeyCode: Int {
    switch paneDirection {
    case .left: kVK_LeftArrow
    case .right: kVK_RightArrow
    case .up: kVK_UpArrow
    case .down, nil: kVK_DownArrow
    }
  }
}
