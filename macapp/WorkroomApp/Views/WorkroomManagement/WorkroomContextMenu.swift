import SwiftUI
import WorkroomDomain

/// What a target's Run, Restart and Stop items can do now.
struct RunMenuState: Equatable {
  /// The target opens terminals and no create holds its run back (`isRunBlocked`).
  var available: Bool
  /// Its project has a run command.
  var configured: Bool
  var running: Bool

  /// Every item off: no target to run.
  static let off = RunMenuState(available: false, configured: false, running: false)

  var canRun: Bool { available && configured }
  var canRestartOrStop: Bool { available && running }
}

extension RunMenuState {
  @MainActor
  init(host: any PaneHost, target: TerminalTarget) {
    self.init(
      available: target.opensTerminals && !host.isRunBlocked(target.id),
      configured: host.hasRunCommand(for: target), running: host.isRunCommandRunning(for: target.id)
    )
  }
}

/// Run, Restart or Stop, worded and drawn the same in every menu that offers them.
private struct RunMenuButton: View {
  enum Kind { case run, restart, stop }
  let kind: Kind
  let enabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      switch kind {
      case .run: Label("Run", systemImage: "play.fill")
      case .restart: Label("Restart", systemImage: "arrow.clockwise")
      case .stop: Label("Stop", systemImage: "stop.fill")
      }
    }
    .disabled(!enabled)
  }
}

/// Target-scoped run actions, shared by project, workroom and run-tab context menus.
@MainActor
@ViewBuilder
func runCommandMenuItems(host: any PaneHost, target: TerminalTarget) -> some View {
  let state = RunMenuState(host: host, target: target)
  RunMenuButton(kind: .run, enabled: state.canRun) { host.runOrFocusRunCommand(for: target) }
  RunMenuButton(kind: .restart, enabled: state.canRestartOrStop) {
    host.restartRunCommand(for: target)
  }
  RunMenuButton(kind: .stop, enabled: state.canRestartOrStop) { host.stopRunCommand(for: target) }
}

/// What one workroom's menu shows: its tab chip's and split title bar's right-click menu (issue
/// #112), its sidebar row's, and the inspector header's actions menu. One model so the menus
/// can't drift; `entries(for:)` says where each caller's differs.
struct WorkroomMenuModel: Equatable {
  /// The surface the menu is on.
  enum Style {
    /// The tab chip, the split title bar and the sidebar row: everything the model offers. The row,
    /// neither a tab nor a split member, offers no Close and no Remove from Split.
    case full
    /// The inspector header's actions, in Apple's order: no run, Close or split items, and the
    /// destructive one last, apart.
    case inspectorHeader
  }

  /// One item or divider, in the order it shows.
  enum Entry: Equatable {
    case run(enabled: Bool)
    case restart(enabled: Bool)
    case stop(enabled: Bool)
    case divider
    case close
    case openInSplit, removeFromSplit
    case moveToNewWindow(enabled: Bool)
    /// "Set Label…", or "Edit Label…" when the workroom has one.
    case label(exists: Bool)
    case removeLabel
    case delete(enabled: Bool)
  }

  /// What a workroom offers that a project root, never labelled or deleted, does not.
  struct WorkroomState: Equatable {
    var hasLabel = false
    /// Its setup is still running against the worktree, so it can't be deleted (issue #116).
    var isCreating = false
  }

  var run: RunMenuState
  /// "Close" (the whole workroom, all its terminal tabs; its files stay) under this display name;
  /// nil hides it.
  var closeName: String? = nil
  /// "Remove from Split": pops this workroom out of the split, still running. Only a split's real
  /// member offers it, as the menu twin of the title bar's ✕ (`pip.exit`).
  var removableFromSplit = false
  /// "Open (split right)" (issue #163), the mouse-reachable ⌥⌘O. `AppStore.canOpenAsSplit` decides,
  /// so the item disappears in exactly the states where choosing it could not have worked: nothing
  /// to split beside, this workroom IS the selection, a missing directory or a pane too narrow. Not
  /// hidden for a workroom already in the visible group, or every pane title bar would lose it; on
  /// a non-focused member it moves that pane to the right of the focused one.
  var canOpenInSplit = false
  /// "Move to New Window" (#444) shows wherever the workroom has terminals in this window, so there
  /// is something to move.
  var showsMoveToNewWindow = false
  /// …and is enabled when `AppStore.canMoveWorkroom` says so: not while a create is still setting
  /// it up, nor for a window's only workroom, which would leave its window empty.
  var canMoveWorkroom = false
  /// Nil for a project root.
  var workroom: WorkroomState? = nil

  func entries(for style: Style) -> [Entry] {
    var entries: [Entry] = []
    var top: [Entry] = []
    if style != .inspectorHeader {
      entries += [
        .run(enabled: run.canRun), .restart(enabled: run.canRestartOrStop),
        .stop(enabled: run.canRestartOrStop), .divider,
      ]
      if closeName != nil { top.append(.close) }
      if canOpenInSplit { top.append(.openInSplit) }
      if removableFromSplit { top.append(.removeFromSplit) }
    }
    if showsMoveToNewWindow { top.append(.moveToNewWindow(enabled: canMoveWorkroom)) }
    entries += top
    guard let workroom else { return entries }
    // The chip and row divide the label items from the items above only when one showed; the
    // inspector always does, so its menu starts with the divider when nothing is above.
    if style == .inspectorHeader || !top.isEmpty { entries.append(.divider) }
    entries.append(.label(exists: workroom.hasLabel))
    if workroom.hasLabel { entries.append(.removeLabel) }
    entries += [.divider, .delete(enabled: !workroom.isCreating)]
    return entries
  }
}

/// What `WorkroomMenuItems` does for each item.
struct WorkroomMenuActions {
  var run: () -> Void
  var restart: () -> Void
  var stop: () -> Void
  /// Asks first, through `RootView`'s confirmation.
  var close: () -> Void
  var openInSplit: () -> Void
  /// Acts at once, with no confirmation.
  var removeFromSplit: () -> Void
  var moveToNewWindow: () -> Void
  /// "Set Label…" or "Edit Label…", through `RootView`'s label sheet.
  var editLabel: () -> Void
  /// Acts at once.
  var removeLabel: () -> Void
  /// Asks first, through `RootView`'s confirmation.
  var delete: () -> Void

  /// Does nothing, for previews.
  static var inert: WorkroomMenuActions {
    WorkroomMenuActions(
      run: {}, restart: {}, stop: {}, close: {}, openInSplit: {}, removeFromSplit: {},
      moveToNewWindow: {}, editLabel: {}, removeLabel: {}, delete: {})
  }
}

/// A workroom's menu items, from its model alone: no store, so a preview or test can draw it.
struct WorkroomMenuItems: View {
  #if DEBUG
    /// How many times the items' body has run, read by `WorkroomMenuModelTests`.
    static var bodyPasses = 0
  #endif
  let model: WorkroomMenuModel
  let actions: WorkroomMenuActions
  let style: WorkroomMenuModel.Style

  var body: some View {
    #if DEBUG
      let _ = { Self.bodyPasses += 1 }()
    #endif
    let entries = model.entries(for: style)
    ForEach(entries.indices, id: \.self) { index in
      item(entries[index])
    }
  }

  @ViewBuilder
  private func item(_ entry: WorkroomMenuModel.Entry) -> some View {
    switch entry {
    case .run(let enabled): RunMenuButton(kind: .run, enabled: enabled, action: actions.run)
    case .restart(let enabled):
      RunMenuButton(kind: .restart, enabled: enabled, action: actions.restart)
    case .stop(let enabled): RunMenuButton(kind: .stop, enabled: enabled, action: actions.stop)
    case .divider: Divider()
    case .close:
      Button(action: actions.close) { Label("Close", systemImage: "xmark") }
    case .openInSplit:
      Button(action: actions.openInSplit) {
        // `rectangle.trailinghalf.inset.filled` is the app's established glyph for a rightward split
        // (TerminalTabStrip's Split Right toolbar button and context item), and this action always
        // inserts on `.right` — so it wears the same icon rather than a neutral one.
        Label("Open (split right)", systemImage: "rectangle.trailinghalf.inset.filled")
      }
    case .removeFromSplit:
      Button(action: actions.removeFromSplit) {
        Label("Remove from Split", systemImage: "pip.exit")
      }
    case .moveToNewWindow(let enabled):
      Button(action: actions.moveToNewWindow) {
        Label("Move to New Window", systemImage: "macwindow.badge.plus")
      }
      .disabled(!enabled)
    // A label is a display-only alias (issue #41): the workroom name and its branch are unchanged.
    case .label(let exists):
      Button(action: actions.editLabel) {
        Label(exists ? "Edit Label…" : "Set Label…", systemImage: "pencil")
      }
    case .removeLabel:
      Button(action: actions.removeLabel) { Label("Remove Label", systemImage: "pencil.slash") }
    case .delete(let enabled):
      // An ellipsis, as it asks before it acts: Apple's convention.
      Button(role: .destructive, action: actions.delete) {
        Label("Delete Workroom…", systemImage: "trash")
      }
      .disabled(!enabled)
    }
  }
}

extension WorkroomMenuModel {
  /// The model for `sid`'s menu as `store` and `lifecycle` hold it now. The run items are
  /// `target`'s; with no target they are all off.
  @MainActor
  init(
    store: AppStore, lifecycle: WorkroomLifecycle, sid: SidebarID, target: TerminalTarget?,
    closeName: String?, removableFromSplit: Bool
  ) {
    let pair = store.workroomAndProject(for: sid)
    self.init(
      run: target.map { RunMenuState(host: store, target: $0) } ?? .off,
      closeName: closeName,
      removableFromSplit: removableFromSplit, canOpenInSplit: store.canOpenAsSplit(sid),
      showsMoveToNewWindow: store.target(for: sid).map {
        store.terminals.tabCount(forTargetID: $0.id) > 0
      } ?? false,
      canMoveWorkroom: store.canMoveWorkroom(sid),
      workroom: pair.map {
        WorkroomState(
          hasLabel: $0.workroom.label != nil,
          isCreating: lifecycle.isCreatingWorkroom($0.workroom, in: $0.project))
      })
  }
}

/// Builds `WorkroomMenuItems`' model and actions for `sid` from the window's store.
///
/// The store, not `\.paneHost`, because the title bar accessory's tree, where the tab chips live,
/// injects no pane host. Main-window only: every caller is the main window's chrome.
struct WorkroomMenuAdapter: View {
  #if DEBUG
    /// How many times the adapter's body has run, read by `WorkroomMenuModelTests`.
    static var bodyPasses = 0
  #endif
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var lifecycle: WorkroomLifecycle
  let sid: SidebarID
  /// The run items' target; nil for a style that shows none.
  let target: TerminalTarget?
  /// Shows "Close" under this name; see `WorkroomMenuModel.closeName`.
  var closeName: String? = nil
  /// Shows "Remove from Split", which calls this.
  var onRemoveFromSplit: (() -> Void)? = nil
  let style: WorkroomMenuModel.Style

  var body: some View {
    #if DEBUG
      let _ = { Self.bodyPasses += 1 }()
    #endif
    WorkroomMenuItems(
      model: WorkroomMenuModel(
        store: store, lifecycle: lifecycle, sid: sid, target: target, closeName: closeName,
        removableFromSplit: onRemoveFromSplit != nil),
      actions: actions, style: style)
  }

  private var actions: WorkroomMenuActions {
    let pair = store.workroomAndProject(for: sid)
    return WorkroomMenuActions(
      run: { [store, target] in target.map { store.runOrFocusRunCommand(for: $0) } },
      restart: { [store, target] in target.map { store.restartRunCommand(for: $0) } },
      stop: { [store, target] in target.map { store.stopRunCommand(for: $0) } },
      close: { [store, target, closeName] in
        guard let target, let closeName else { return }
        store.modals.pendingWorkroomClose = PendingWorkroomClose(target: target, name: closeName)
      },
      openInSplit: { [store, sid] in store.openExistingAsSplit(sid) },
      removeFromSplit: { [onRemoveFromSplit] in onRemoveFromSplit?() },
      moveToNewWindow: { [store, sid] in store.moveWorkroomToNewWindow(sid) },
      editLabel: { [store] in
        guard let pair else { return }
        store.modals.pendingWorkroomLabel = PendingWorkroomLabel(
          workroom: pair.workroom, project: pair.project)
      },
      removeLabel: { [store] in
        guard let pair else { return }
        store.removeWorkroomLabel(pair.workroom, in: pair.project)
      },
      delete: { [store, sid] in store.requestDeleteWorkroom(sid) })
  }
}

#if DEBUG
  #Preview("Workroom menu") {
    let model = WorkroomMenuModel(
      run: RunMenuState(available: true, configured: true, running: true), closeName: "fix-auth",
      removableFromSplit: true, canOpenInSplit: true, showsMoveToNewWindow: true,
      canMoveWorkroom: true, workroom: .init(hasLabel: true))
    HStack(alignment: .top, spacing: 24) {
      ForEach(
        [WorkroomMenuModel.Style.full, .inspectorHeader], id: \.self
      ) { style in
        VStack(alignment: .leading) {
          WorkroomMenuItems(model: model, actions: .inert, style: style)
        }
        .buttonStyle(.borderless)
      }
    }
    .padding()
  }
#endif

/// A pane's "Move to New Window", or "Move Back to Main Window" once it is in a window of its own
/// (#444): the same toggle as the pane title bar's button and ⌃⌘O, for the pane the menu is on.
/// Shared by every pane menu: its tab chip and its sidebar row (the
/// terminal's own right-click menu is AppKit's, in `GhosttySurfaceView`).
@MainActor
@ViewBuilder
func paneWindowMenuItem(
  host: any PaneHost, tabID: TerminalTab.ID, targetID: TerminalTarget.ID
) -> some View {
  let detached = host.terminals.detachedTabIDs.contains(tabID)
  Button {
    host.togglePaneWindow(tabID, targetID: targetID)
  } label: {
    Label(
      detached ? "Move Back to Main Window" : "Move to New Window",
      systemImage: detached ? "arrow.down.right.and.arrow.up.left" : "macwindow.badge.plus")
  }
}

extension NSImage {
  /// "Move to Workroom"'s icon: a terminal with an arrow, since the terminal is what moves. No SF
  /// Symbol says that.
  @MainActor static let moveTerminal = badged(
    "apple.terminal", badge: "arrow.right.circle.fill", description: "Move to workroom")

  /// "Move to new window"'s icon, composed as `moveTerminal` is so the two sit alike. The symbol
  /// `macwindow.badge.plus` has its badge above the window, which puts the window off the centre
  /// its neighbours in a toolbar keep.
  @MainActor static let moveToNewWindow = badged(
    "macwindow", badge: "plus.circle.fill", description: "Move to new window")

  /// Symbol `base` at the pane title bar's glyph size with symbol `badge` small in its bottom-right
  /// corner, cut out of it so the pair reads at 11pt, as one template image. `base` stays at the
  /// image's centre, level with the plain symbols beside it.
  @MainActor static func badged(_ base: String, badge: String, description: String) -> NSImage {
    let terminal = NSImage(systemSymbolName: base, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: PaneTitleBarMetrics.glyph, weight: .regular))
    let arrow = NSImage(systemSymbolName: badge, accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 7, weight: .bold))
    guard let terminal, let arrow else { return NSImage() }
    // The same room on every side, so the base sits at the image's centre; the badge takes the
    // bottom-right corner of that room.
    let pad: CGFloat = 3
    let size = NSSize(width: terminal.size.width + 2 * pad, height: terminal.size.height + 2 * pad)
    let image = NSImage(size: size)
    // Into bitmaps of its own, so the cut-out clears only the base, never what the icon is drawn on.
    for scale in [1, 2, 3] as [CGFloat] {
      guard
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
          pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
          bitsPerPixel: 0)
      else { continue }
      // Before the context: it draws in points, scaled to this rep's pixels.
      rep.size = size
      guard let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      terminal.draw(in: NSRect(origin: NSPoint(x: pad, y: pad), size: terminal.size))
      let badge = NSRect(origin: NSPoint(x: size.width - arrow.size.width, y: 0), size: arrow.size)
      context.compositingOperation = .destinationOut
      NSColor.black.setFill()
      NSBezierPath(ovalIn: badge.insetBy(dx: -1.5, dy: -1.5)).fill()
      context.compositingOperation = .sourceOver
      arrow.draw(in: badge)
      NSGraphicsContext.restoreGraphicsState()
      image.addRepresentation(rep)
    }
    image.isTemplate = true
    image.accessibilityDescription = description
    return image
  }
}

/// "Move to Workroom" for a Quick Terminal pane: every workroom open in every Workroom window, in
/// each window's tab order and under the window's name when there is more than one
/// (`QuickTerminalHost.quickTerminalPaneWorkroomChoices`), moving the pane into the one chosen. One on a host,
/// or still being created, is listed but disabled. A submenu in the tab chip's menu, a button in the
/// pane's title bar.
struct QuickTerminalMoveToWorkroomMenu: View {
  enum Style { case menuItem, toolbar }

  /// From the environment, not an init parameter: the title bar re-creates this on every pane
  /// update, and comparable stored inputs are what let SwiftUI skip its body then.
  @Environment(\.paneHost) private var host
  let tabID: TerminalTab.ID
  let target: TerminalTarget
  let style: Style
  /// Re-read as windows open and close, which no store this reads publishes; not on every other
  /// change the registry publishes (its badge counts).
  @State private var windows = WindowRegistry.shared.allStores
  @State private var hovering = false

  init(tabID: TerminalTab.ID, target: TerminalTarget, style: Style) {
    self.tabID = tabID
    self.target = target
    self.style = style
  }

  var body: some View {
    Group {
      switch style {
      case .menuItem:
        menu {
          Label {
            Text("Move to Workroom")
          } icon: {
            Image(nsImage: .moveTerminal)
          }
        }
      case .toolbar:
        // `.button`, as the title bar's overflow menu is, so it wears the bar's hover well; the
        // glyph in its neighbours' colours, which the menu's own label styling would lighten.
        menu {
          Image(nsImage: .moveTerminal).renderingMode(.template)
            .foregroundStyle(PaneToolbarButton.tint(hovering: hovering))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Move to workroom")
        .accessibilityLabel("Move pane to workroom")
        .accessibilityIdentifier("pane.toolbar.moveToWorkroom")
      }
    }
    .onReceive(WindowRegistry.shared.$windowsChanged) { _ in
      windows = WindowRegistry.shared.allStores
    }
  }

  private func menu(@ViewBuilder label: () -> some View) -> some View {
    let groups = host.quickTerminalPaneWorkroomChoices(tabID, of: target, windows: windows)
    return Menu {
      if groups.isEmpty {
        Button("No Open Workrooms") {}.disabled(true)
      }
      ForEach(groups.indices, id: \.self) { index in
        let group = groups[index]
        if let header = group.header {
          Section(header) { items(group) }
        } else {
          items(group)
        }
      }
    } label: {
      label()
    }
  }

  private func items(_ group: PaneWorkroomGroup) -> some View {
    ForEach(group.choices.indices, id: \.self) { index in
      let choice = group.choices[index]
      Button(action: choice.move) { Label(choice.title, systemImage: choice.glyph) }
        .disabled(!choice.enabled)
    }
  }
}
