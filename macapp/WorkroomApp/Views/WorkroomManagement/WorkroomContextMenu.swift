import SwiftUI
import WorkroomDomain

/// Target-scoped run actions, shared by project, workroom and run-tab context menus.
@MainActor
@ViewBuilder
func runCommandMenuItems(host: any PaneHost, target: TerminalTarget) -> some View {
  let available = target.opensTerminals && !host.isRunBlocked(target.id)
  let configured = host.hasRunCommand(for: target)
  let running = host.isRunCommandRunning(for: target.id)
  Button {
    host.runOrFocusRunCommand(for: target)
  } label: {
    Label("Run", systemImage: "play.fill")
  }
  .disabled(!available || !configured)
  Button {
    host.restartRunCommand(for: target)
  } label: {
    Label("Restart", systemImage: "arrow.clockwise")
  }
  .disabled(!available || !running)
  Button {
    host.stopRunCommand(for: target)
  } label: {
    Label("Stop", systemImage: "stop.fill")
  }
  .disabled(!available || !running)
}

/// The shared right-click menu items for a workroom, reused by the tab chip
/// (`WorkroomTabBar`) and the split group title bar (`WorkroomSplitView`) — issue #112. One
/// source of truth so the two menus can't drift.
///
/// `closeName != nil` renders the "Close" item (close the whole workroom — all its terminal
/// tabs — the files stay) with that display name.
///
/// `onRemoveFromSplit != nil` renders a "Remove from Split" item that pops this workroom out of the
/// split (keeps it running) — the menu equivalent of the title bar's `pip.exit` ✕. Only the split
/// title bar passes it; the tab chip passes `nil` (a tab isn't a split member).
///
/// Label + Delete apply only to a real workroom (roots are never labelled or deletable), gated
/// on `store.workroomAndProject(for:)`.
///
/// Each item sets a store flag that `RootView`'s `.confirmationDialog`/`.sheet` bridge observes
/// (the store-flag → dialog pattern), except "Remove Label"/"Remove from Split" which act immediately.
///
/// `@MainActor` because it touches the main-actor `AppStore`; the callers' `.contextMenu` closures
/// are already main-actor-isolated (they live in `View.body`), so this is a no-op at the call site.
/// Whether `openInSplitMenuItem` renders anything — read by `workroomContextMenu` so its leading
/// divider tracks the item, instead of the two drifting apart.
@MainActor
func canOpenInSplit(store: AppStore, sid: SidebarID) -> Bool {
  // The store's own predicate, not a re-derived subset: it also refuses a missing directory and a
  // pane too narrow to hold two halves, so the item disappears in exactly the states where
  // choosing it could not have worked.
  store.canOpenAsSplit(sid)
}

/// "Open (split right)" — open this workroom beside the current one (issue #163), the mouse-reachable
/// equivalent of ⌥⌘O and of dragging the row onto a pane edge. Shared by `workroomContextMenu`
/// (tab chip + split pane title bar) and `ProjectSidebar`'s own inline row menu.
///
/// Hidden only when there is nothing to split beside, or when this workroom IS the selection.
/// Deliberately NOT also hidden for a workroom already in the visible group: every rendered pane
/// title bar belongs either to the selected solo workroom or to the visible group, so that guard
/// would make the item unreachable on that whole surface. Invoked on a non-focused member it moves
/// that pane to the right of the focused one — a real rearrange, and exactly what dragging the
/// same title bar already does (`insertWorkroomSplit` is "a move, not a duplicate").
@MainActor
@ViewBuilder
func openInSplitMenuItem(store: AppStore, sid: SidebarID) -> some View {
  if canOpenInSplit(store: store, sid: sid) {
    Button {
      store.openExistingAsSplit(sid)
    } label: {
      // `rectangle.trailinghalf.inset.filled` is the app's established glyph for a rightward split
      // (TerminalTabStrip's Split Right toolbar button and context item), and this action always
      // inserts on `.right` — so it wears the same icon rather than a neutral one.
      Label("Open (split right)", systemImage: "rectangle.trailinghalf.inset.filled")
    }
  }
}

/// "Move to New Window" (#444): this workroom, its terminals still running, into a window of its
/// own. Shown wherever the workroom has terminals in this window, so there is something to move;
/// disabled while a create is still setting it up, and for a window's only workroom, which would
/// leave its window empty (`AppStore.canMoveWorkroom`). Shared by `workroomContextMenu` and
/// `ProjectSidebar`'s row menu.
@MainActor
@ViewBuilder
func moveToNewWindowMenuItem(store: AppStore, sid: SidebarID) -> some View {
  if showsMoveToNewWindow(store: store, sid: sid) {
    Button {
      store.moveWorkroomToNewWindow(sid)
    } label: {
      Label("Move to New Window", systemImage: "macwindow.badge.plus")
    }
    .disabled(!store.canMoveWorkroom(sid))
  }
}

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

/// Whether `moveToNewWindowMenuItem` renders anything, for the dividers around it.
@MainActor
func showsMoveToNewWindow(store: AppStore, sid: SidebarID) -> Bool {
  store.target(for: sid).map { store.terminals.tabCount(forTargetID: $0.id) > 0 } ?? false
}

@MainActor
@ViewBuilder
func workroomContextMenu(
  store: AppStore, sid: SidebarID, target: TerminalTarget, closeName: String?,
  onRemoveFromSplit: (() -> Void)? = nil
) -> some View {
  runCommandMenuItems(host: store, target: target)
  Divider()
  if let closeName {
    // Close the whole workroom (all its tabs); the workroom's files stay. Confirmed via
    // RootView's `pendingWorkroomClose` dialog.
    Button {
      store.modals.pendingWorkroomClose = PendingWorkroomClose(target: target, name: closeName)
    } label: {
      Label("Close", systemImage: "xmark")
    }
  }
  openInSplitMenuItem(store: store, sid: sid)
  if let onRemoveFromSplit {
    // Pop this workroom out of the split (it keeps running) — same action as the title bar's ✕
    // (`pip.exit`). Acts immediately; no confirmation.
    Button {
      onRemoveFromSplit()
    } label: {
      Label("Remove from Split", systemImage: "pip.exit")
    }
  }
  moveToNewWindowMenuItem(store: store, sid: sid)
  // Label + delete only apply to a workroom (roots are never labelled or deletable). Mirrors the
  // sidebar row's context menu (issue #41 + delete).
  if let pair = store.workroomAndProject(for: sid) {
    // Leading divider only when a top item (Close / Remove from Split / Open (split right) / Move to
    // New Window) showed.
    if closeName != nil || onRemoveFromSplit != nil || canOpenInSplit(store: store, sid: sid)
      || showsMoveToNewWindow(store: store, sid: sid)
    {
      Divider()
    }
    workroomLabelMenuItems(store: store, workroom: pair.workroom, project: pair.project)
    Divider()
    deleteWorkroomMenuItem(store: store, workroom: pair.workroom, project: pair.project)
  }
}

/// "Set Label…" ("Edit Label…" once it has one) and, when labelled, "Remove Label" (issue #41). A
/// label is a display-only alias: the workroom name and its branch are unchanged. Shared by every
/// workroom menu.
@MainActor
@ViewBuilder
func workroomLabelMenuItems(store: AppStore, workroom: Workroom, project: Project) -> some View {
  Button {
    store.modals.pendingWorkroomLabel = PendingWorkroomLabel(workroom: workroom, project: project)
  } label: {
    Label(workroom.label == nil ? "Set Label…" : "Edit Label…", systemImage: "pencil")
  }
  if workroom.label != nil {
    Button {
      store.removeWorkroomLabel(workroom, in: project)
    } label: {
      Label("Remove Label", systemImage: "pencil.slash")
    }
  }
}

/// Delete, through `RootView`'s confirmation, so its title ends in an ellipsis: Apple's convention for
/// a command that asks something before it acts. Shared by every workroom menu.
@MainActor
@ViewBuilder
func deleteWorkroomMenuItem(store: AppStore, workroom: Workroom, project: Project) -> some View {
  Button(role: .destructive) {
    store.modals.pendingDeletion = PendingWorkroomDeletion(workroom: workroom, project: project)
  } label: {
    Label("Delete Workroom…", systemImage: "trash")
  }
  // Can't delete a workroom while its setup is still running against the worktree (issue #116).
  .disabled(store.lifecycle.isCreatingWorkroom(workroom, in: project))
}
