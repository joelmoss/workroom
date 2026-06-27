import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// The sidebar: a collapsible tree with projects at the root and their workrooms nested
/// one level below, each of which can reveal its terminals one level deeper. Selecting a
/// workroom (or a project root) opens its terminal in the detail pane; selecting a project
/// makes it the target for "New Workroom". Projects disclose via a chevron after their name; roots
/// and workrooms carry their terminal-disclosure chevron in a shared leading column (shown only at
/// ≥2 terminals) that lines up with the terminal rows' glyphs.
struct ProjectSidebar: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @EnvironmentObject var terminals: TerminalSessions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Live drag of a root/workroom row into the detail content to form a workroom split (issue #101) —
  /// the same pipeline the title-bar tab bar uses (`WorkroomTabBar`). Bound to `RootView`'s
  /// `workroomChipDrag` so `WorkroomSplitView.externalDrag` highlights the drop edge while dragging.
  /// The defaults make the gesture an inert no-op for previews / any host that doesn't wire it.
  var paneDrag: Binding<WorkroomPaneDrag?> = .constant(nil)
  /// Maps a global drag point into detail-content-local coords, or nil when it's outside the detail
  /// area (→ not a drop). Owned by `RootView` (it knows the content frame).
  var localize: (CGPoint) -> CGPoint? = { _ in nil }
  /// Where a drop at a global point lands (workroom pane + edge), or nil if it isn't over a pane.
  var dropTarget: (CGPoint) -> (sid: SidebarID, edge: PaneEdge)? = { _ in nil }

  @State private var hovered: SidebarID?
  /// The terminal row currently under the cursor (issue #30). Keyed by the tab's UUID rather than a
  /// `SidebarID` — terminal rows aren't selectable `List` rows, so they sit outside `hovered`.
  @State private var hoveredTerminal: TerminalTab.ID?
  @State private var themeHovering = false
  @State private var addProjectHovering = false
  /// The project whose settings sheet is open (issue #7), or nil. Owned here so the trigger (the
  /// project-row context menu) and the presenter live together.
  @State private var settingsProject: Project?
  @Default(.theme) private var theme

  /// Width of the shared leading icon column on the root/workroom/terminal rows — it holds the
  /// disclosure caret (root/workroom, only at ≥2 terminals) or the terminal glyph, and is always
  /// reserved so the labels beside it line up whether or not a caret is shown.
  private let caretWidth: CGFloat = 14
  /// Height of the floating theme/add bar (top fade pad 18 + 28 button + bottom pad 6). Used to
  /// reserve a trailing list spacer so the last row scrolls clear of it.
  private let bottomBarHeight: CGFloat = 52
  /// Per-level leading indent so the tree reads as a hierarchy: projects sit at `rowInsets.leading`,
  /// their root/workroom children one `levelIndent` deeper (`childRowInsets`), and a target's terminal
  /// rows deeper again — the terminal base matches its root/workroom, then the in-row `caretWidth`
  /// glyph column carries the final step (so the terminal glyph lines up under the root/workroom
  /// label). Vertical insets are unchanged: 4 for the selectable rows, a tighter 2 for the smaller
  /// terminal rows. (`6 + 12`: the base sidebar margin plus one 12pt level step.)
  private let rowInsets = EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 0)
  private let childRowInsets = EdgeInsets(top: 4, leading: 6 + 6, bottom: 4, trailing: 0)
  private let terminalRowInsets = EdgeInsets(top: 3, leading: 6 + 6, bottom: 3, trailing: 0)

  /// Select a target (root or workroom) on tap — sets the store's selected target id and follows the
  /// New-Workroom context project. Selection is driven by tap rather than the `List`'s own
  /// `selection:` because the plain list style (needed to size the compact terminal rows) draws its
  /// own full-width selection bar that would double up with the rows' custom rounded `rowHighlight`.
  private func selectTarget(_ id: SidebarID) {
    store.selectedTargetID = id
    switch id {
    case .root(let path), .workroom(let path, _):
      store.selectedProjectID = path
    default:
      break
    }
  }

  /// The drag-to-split gesture for a root/workroom row (issue #101). Mirrors the tab-bar chip
  /// (`WorkroomTabBar`), minus the reorder math: while dragging into the detail content it previews the
  /// drop edge (driving the shared `paneDrag`), and on release over a pane it forms/extends the
  /// workroom split via the same `insertWorkroomSplit` the chip uses. Attached with
  /// `.simultaneousGesture` so it coexists with the List's vertical scroll; `minimumDistance` keeps a
  /// plain click selecting the row (a zero-translation tap never starts the drag).
  private func rowSplitDrag(_ id: SidebarID) -> some Gesture {
    DragGesture(minimumDistance: 6, coordinateSpace: .global)
      .onChanged { value in
        paneDrag.wrappedValue = localize(value.location).map {
          WorkroomPaneDrag(sid: id, location: $0)
        }
      }
      .onEnded { value in
        if let drop = dropTarget(value.location) {
          store.insertWorkroomSplit(id, beside: drop.sid, edge: drop.edge)
        }
        paneDrag.wrappedValue = nil
      }
  }

  /// Whether `id`'s row is the one currently being dragged into a split — drives a light dim cue
  /// (the primary affordance is the detail-side accent drop band via `externalDrag`).
  private func isDraggingForSplit(_ id: SidebarID) -> Bool {
    paneDrag.wrappedValue?.sid == id
  }

  var body: some View {
    Group {
      if store.projects.isEmpty {
        ContentUnavailableView {
          Label("No projects yet", systemImage: "folder.badge.plus")
        } description: {
          Text("Add a Git or Jujutsu project folder to start managing its workrooms.")
        } actions: {
          Button("Add Project…") { store.requestAddProject = true }
            .buttonStyle(.borderedProminent)
        }
      } else {
        tree
      }
    }
    // The theme/add bar floats over the list contents (issue #56 feedback) with a top-fading solid
    // background, so rows scroll under it and stay legible; the list reserves matching bottom room
    // (`contentMargins` in `tree`) so the last row can still scroll clear of it.
    .overlay(alignment: .bottom) { bottomBar }
    // Per-project run-command settings (issue #7) stays sidebar-local — it's only ever triggered
    // from a (visible) project row, so it needs no re-homing.
    .sheet(item: $settingsProject) { project in
      ProjectSettingsSheet(project: project).environmentObject(store)
    }
    // The add-project importer and the delete confirmation are re-homed to RootView (issue #23 OV1)
    // so the ⌘O / ⌘⌫ menu commands present reliably even when this sidebar is collapsed in
    // Workrooms View. Local buttons here route through `store.requestAddProject` / `pendingDeletion`.
  }

  /// Flat list of rows (project, then its root + workrooms when expanded, then their terminals). All
  /// rows are flush; the hierarchy is conveyed by each row's icons/buttons (project chevron, root
  /// house, workroom caret, terminal glyph), not indentation. A flat structure also keeps List
  /// selection and keyboard navigation simple across the levels.
  private var tree: some View {
    List {
      ForEach(store.projects) { project in
        projectRow(project)
          .listRowInsets(rowInsets)
          .listRowSeparator(.hidden)
          .listRowBackground(rowHighlight(.project(project.path), selected: false))
        if isExpanded(project.path) {
          // The root is always the first child, before any workrooms; each selectable row is
          // followed by its terminal subtree (rendered only when expanded with ≥2 terminals).
          let rid = SidebarID.root(project: project.path)
          rootRow(project)
            .listRowInsets(childRowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(rowHighlight(rid, selected: store.selectedTargetID == rid))
          terminalSubtree(for: project.rootTarget, parent: rid)
          ForEach(project.workrooms) { workroom in
            let wid = SidebarID.workroom(project: project.path, name: workroom.name)
            workroomRow(workroom, in: project)
              .listRowInsets(childRowInsets)
              .listRowSeparator(.hidden)
              .listRowBackground(rowHighlight(wid, selected: store.selectedTargetID == wid))
            terminalSubtree(for: workroom.target(inProject: project.path), parent: wid)
          }
        }
      }
      // Trailing spacer the height of the floating theme/add bar, so the last real row can always
      // scroll clear of it (issue #56 feedback).
      Color.clear
        .frame(height: bottomBarHeight)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
    // Plain style (not the NavigationSplitView sidebar default): the `.sidebar` style forces a
    // comfortable ~28pt row-height floor and ignores small `listRowInsets` + `defaultMinListRowHeight`,
    // so the compact terminal rows couldn't shrink. Plain sizes each row by its content + insets.
    // Selection/hover are already hand-rolled via `listRowBackground`, so no native sidebar styling is
    // lost; `scrollContentBackground(.hidden)` keeps the window's sidebar material showing through.
    .listStyle(.plain)
    // Hide the List's own background so the `sidebarCard` (applied at the use site, for both the
    // docked column and the edge-reveal panel) shows through — its `tokens.bg` replaces
    // NavigationSplitView's native sidebar material, so pinned and unpinned share one card style.
    .scrollContentBackground(.hidden)
    .environment(\.defaultMinListRowHeight, 1)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.collapsedProjects)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.expandedTerminalTargets)
  }

  /// The terminal rows for a target, shown only when it has ≥2 terminals and the user has expanded
  /// its disclosure (issue #30). One row per tab, in the same display order as the detail-pane strip.
  @ViewBuilder
  private func terminalSubtree(for target: TerminalTarget, parent: SidebarID) -> some View {
    let tabs = terminals.tabs(for: target)
    if tabs.count >= 2, store.isTerminalsExpanded(target.id) {
      ForEach(tabs) { tab in
        let selected =
          store.selectedTargetID == parent && terminals.focusedTab(for: target)?.id == tab.id
        terminalRow(tab, target: target, parent: parent)
          .listRowInsets(terminalRowInsets)
          .listRowSeparator(.hidden)
          .listRowBackground(terminalHighlight(tab.id, selected: selected))
      }
    }
  }

  // MARK: Rows

  @ViewBuilder
  private func projectRow(_ project: Project) -> some View {
    let id = SidebarID.project(project.path)
    let unread = projectUnread(project)
    HStack(spacing: 6) {
      // The whole caret/name area toggles expansion; clicking anywhere on it (including the
      // trailing empty space) collapses or expands the project.
      Button {
        toggle(project.path)
      } label: {
        HStack(spacing: 6) {
          // The project chevron sits to the right of the project name — projects keep their own
          // disclosure idiom, distinct from the leading caret column the root/workroom/terminal rows
          // share. Always shown (every project has at least the root as a child).
          Text(project.displayName).fontWeight(.medium)
          Image(systemName: isExpanded(project.path) ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint(isExpanded(project.path) ? "Collapse project" : "Expand project")

      // Aggregate dot so notifications are visible even when the project is collapsed.
      UnreadDot(count: unread)
      // Aggregate VCS status (worst child) when collapsed — so collapsing a project doesn't
      // hide the command-center signal (issue #24). Only when collapsed: expanded projects show
      // each row's own dot. Visually distinct from the UnreadDot above (different concern).
      if !isExpanded(project.path), let agg = store.aggregateStatus(forProject: project.path) {
        VCSAggregateDot(status: agg)
      }

      // Both buttons stay laid out while a workroom is being created so the row size never shifts
      // (issue #51) — the create spinner overlays the new-workroom button (which it replaces) rather
      // than swapping the buttons out for a smaller ProgressView.
      let busy = store.busyProjects.contains(project.path)
      // Project settings (run command, etc.), revealed on hover to the left of the new-workroom
      // button (issue #7). Laid out always (opacity-gated) so the row size is stable. Hidden while
      // busy so the spinner reads as the sole active control.
      SettingsRowButton(
        help: "Project settings for \(project.displayName)", visible: hovered == id && !busy
      ) {
        settingsProject = project
      }
      CreateRowButton(help: "New workroom in \(project.displayName)") {
        Task { await store.createWorkroom(in: project) }
      }
      .opacity(busy ? 0 : 1)
      .allowsHitTesting(!busy)
      .overlay {
        if busy { ProgressView().controlSize(.small) }
      }
    }
    .contentShape(Rectangle())
    .accessibilityIdentifier("sidebar.project.\(project.displayName)")
    .onHover { inside in
      if inside { hovered = id } else if hovered == id { hovered = nil }
    }
    .contextMenu {
      Button {
        Task { await store.createWorkroom(in: project) }
      } label: {
        Label("New Workroom", systemImage: "plus")
      }
      Divider()
      Button {
        settingsProject = project
      } label: {
        Label("Project Settings…", systemImage: "gearshape")
      }
      Divider()
      Button(role: .destructive) {
        store.pendingProjectDeletion = PendingProjectDeletion(project: project)
      } label: {
        Label("Delete Project…", systemImage: "trash")
      }
    }
  }

  /// The always-present project-root row: the first child under each project. Reads like a workroom
  /// (a leading house glyph marking it as the root, then the current branch/bookmark) — so roots and
  /// workrooms share one left edge. Selectable (opens a terminal at the project directory); never
  /// deletable.
  @ViewBuilder
  private func rootRow(_ project: Project) -> some View {
    let id = SidebarID.root(project: project.path)
    let target = project.rootTarget
    let style = RootPresentation.make(store.rootRefs[project.id] ?? .unresolved)
    let status = store.workroomStatuses[id] ?? .unresolved
    HStack(spacing: 6) {
      leadingSlot(for: target, id: id, root: true)
      Text(style.label)
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.tail)
        // A healthy root must apply NO foreground color so it inherits the sidebar's default
        // (vibrant) foreground and dims with every other row when the window goes inactive — exactly
        // like the workroom rows. Pinning a color here (even `.foregroundColor(nil)`) opts the text
        // out of that vibrancy dimming, which left roots bright on blur (issue #43). Only the
        // de-emphasized detached/none states take an explicit `.secondary`.
        .modifier(RootLabelTint(dim: style.dim))
      if style.ahead {
        Image(systemName: "arrow.up")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      // VCS status for the project root (issue #24), same placement as the workroom rows. The dirty
      // dot is dropped (`showDot: false`) — the leading house glyph's tint carries that signal — so
      // only ahead/behind remains here. No CI in the projects tree (it's in the inspector).
      VCSStatusCluster(status: status, showCI: false, showDot: false)
      Spacer(minLength: 0)
      UnreadDot(count: notifications.count(target: target.id))
      if target.isMissing {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
          .help("Project folder not found")
      }
      // OSC-9;4 spinner (any terminal's agent activity), to the LEFT of the run button — mirroring
      // the workroom rows' spinner/delete-then-run order.
      if terminals.isRunning(forTargetID: target.id) {
        RunningSpinner()
      }
      // Run/stop the project's command straight from the root row (issue #7), trailing-most — the
      // root runs it in the project directory. Shows its state (green = running). Hidden for a missing
      // directory, where the button would be a dead no-op (review #9).
      if store.canRunCommand(for: target, inProject: project.path) {
        RowRunButton(target: target)
      }
    }.contentShape(Rectangle())
      .opacity(isDraggingForSplit(id) ? 0.5 : 1)
      .onTapGesture { selectTarget(id) }
      // Drag this root onto a displayed workroom pane to split them (issue #101). Simultaneous so the
      // List still scrolls vertically; the tap above still selects.
      .simultaneousGesture(rowSplitDrag(id))
      .help(style.tooltip)
      .accessibilityElement(children: .ignore)
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel(
        [
          target.isMissing ? "\(style.accessibility), folder not found" : style.accessibility,
          VCSStatusPresentation.accessibilityLabel(status),
        ].filter { !$0.isEmpty }.joined(separator: ", ")
      )
      .onHover { inside in
        if inside { hovered = id } else if hovered == id { hovered = nil }
      }
  }

  @ViewBuilder
  private func workroomRow(_ workroom: Workroom, in project: Project) -> some View {
    let id = SidebarID.workroom(project: project.path, name: workroom.name)
    let target = workroom.target(inProject: project.path)
    let targetID = target.id
    let unread = notifications.count(target: targetID)
    HStack(spacing: 6) {
      // Leading identity glyph (a cube for a workroom), swapped for the expand/collapse chevron on
      // hover when the row has ≥2 terminals — the same left edge as the root row, so roots and
      // workrooms read as aligned siblings.
      leadingSlot(for: target, id: id, root: false)
      // lineLimit so a long name yields to the VCS badges — truncation priority: name first (#24).
      Text(workroom.name).font(.callout).lineLimit(1).truncationMode(.tail)
      // VCS status sub-cluster: after the name, before the Spacer. The dirty dot is dropped
      // (`showDot: false`) — the leading cube glyph's tint carries that signal — leaving ahead/behind.
      VCSStatusCluster(
        status: store.workroomStatuses[id] ?? .unresolved,
        showCI: false, showDot: false)
      Spacer()
      UnreadDot(count: unread)
      ForEach(workroom.warnings, id: \.kind) { warning in
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
          .help(warning.message)
      }
      // Spinner/delete slot: a progress spinner while a command runs, swapped for the delete button
      // on hover — so a workroom stays deletable even mid-run (issue #28). The delete button is
      // always laid out (it reveals via opacity), so it fixes the slot's size and the spinner,
      // which is smaller, can't shift the row.
      ZStack {
        if terminals.isRunning(forTargetID: targetID), hovered != id {
          RunningSpinner()
        }
        DeleteRowButton(name: workroom.name, visible: hovered == id) {
          store.pendingDeletion = PendingWorkroomDeletion(workroom: workroom, project: project)
        }
      }
      // Run/stop the project's command for this workroom straight from the row (issue #7), trailing-
      // most. Shows its state (green = running) and toggles on click; distinct from the OSC-9;4
      // `RunningSpinner` above (any terminal's agent activity). Hidden for a missing worktree, where
      // the button would be a dead no-op (review #9).
      if store.canRunCommand(for: target, inProject: project.path) {
        RowRunButton(target: target)
          .accessibilityIdentifier("sidebar.workroom.\(workroom.name).run")
      }
    }.contentShape(Rectangle())
      .opacity(isDraggingForSplit(id) ? 0.5 : 1)
      .onTapGesture { selectTarget(id) }
      // Drag this workroom onto a displayed pane to split them (issue #101). Simultaneous so the List
      // still scrolls vertically; the tap above still selects.
      .simultaneousGesture(rowSplitDrag(id))
      .accessibilityIdentifier("sidebar.workroom.\(workroom.name)")
      .accessibilityAddTraits(.isButton)
      .onHover { inside in
        if inside { hovered = id } else if hovered == id { hovered = nil }
      }
      .contextMenu {
        Button(role: .destructive) {
          store.pendingDeletion = PendingWorkroomDeletion(workroom: workroom, project: project)
        } label: {
          Label("Delete \(workroom.name)", systemImage: "trash")
        }
      }
  }

  /// The leading icon column for a root/workroom row (issue #30): the identity glyph — a house for the
  /// project root, a cube for a workroom. When the row owns ≥2 terminals it's expandable, and
  /// hovering the row swaps the glyph for the expand/collapse chevron — so the chevron shows only when
  /// it's both usable and the row is the pointer's focus. The chevron's own `Button` toggles expansion
  /// without selecting the row (a button inside a selectable `List` row swallows the tap). Both occupy
  /// `caretWidth` (centered), so sibling rows share one left edge and the glyph/chevron sit on the same
  /// vertical axis as the terminal-row glyph below.
  @ViewBuilder
  private func leadingSlot(for target: TerminalTarget, id: SidebarID, root: Bool) -> some View {
    if terminals.tabs(for: target).count >= 2, hovered == id {
      TerminalDisclosureButton(
        expanded: store.isTerminalsExpanded(target.id), width: caretWidth
      ) {
        store.toggleTerminals(for: target.id)
      }
    } else {
      // The glyph's tint carries the VCS dirty signal (orange) in place of a separate status dot.
      Image(systemName: root ? "house" : "cube")
        .font(.system(size: 10))
        .foregroundStyle(VCSStatusPresentation.iconTint(store.workroomStatuses[id] ?? .unresolved))
        .frame(width: caretWidth, height: 18, alignment: .center)
    }
  }

  /// One terminal in a target's expanded subtree (issue #30): a terminal glyph centered in the shared
  /// caret column (sharing the chevron's vertical axis, and keeping the title in the same column as
  /// the root/workroom labels above it), the tab's live
  /// title, a per-tab unread dot, and — swapped on hover like the workroom row — a running spinner or
  /// a close button. The row mirrors the workroom row's layout exactly (no `Button` wrapper, which
  /// would inset the title and break the shared label column); the tap is a gesture that selects the
  /// target and focuses this terminal — it never becomes the `List` selection, so `selectedTargetID`
  /// stays a root/workroom.
  @ViewBuilder
  private func terminalRow(_ tab: TerminalTab, target: TerminalTarget, parent: SidebarID)
    -> some View
  {
    // A diff (content) tab gets the same `plusminus` glyph the tab strip uses (#66), so a glance at
    // the row says "this isn't a terminal"; a terminal tab keeps the terminal glyph.
    let glyph: String = {
      if case .diff = tab.content { return "plusminus" }
      return "terminal"
    }()
    HStack(spacing: 6) {
      // Leading glyph centered in the shared caret slot, same size/weight as the root house and the
      // workroom chevron so the leading-icon column reads as one set. The fixed-width frame keeps the
      // title in the same column as the root/workroom labels regardless of the symbol's intrinsic width.
      Image(systemName: glyph)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(width: caretWidth, alignment: .center)
      Text(tab.title)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)

      UnreadDot(count: notifications.count(tab: tab.id))

      // Same swapped slot as the workroom row: a spinner while a command runs, replaced by the close
      // button on hover. The close button is always laid out (revealed via opacity) so the row size
      // is stable and the smaller spinner can't shift it.
      ZStack {
        if tab.isRunning, hoveredTerminal != tab.id {
          RunningSpinner()
        }
        CloseTerminalRowButton(title: tab.title, visible: hoveredTerminal == tab.id) {
          store.requestCloseTerminalTab(tab.id, for: target)
        }
      }
    }
    // A small indent so the expanded terminal rows read as children of their root/workroom row.
    .padding(.leading, 8)
    .contentShape(Rectangle())
    .onTapGesture { store.revealTerminal(tab.id, at: parent) }
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(tab.title)
    .accessibilityAction { store.revealTerminal(tab.id, at: parent) }
    .accessibilityIdentifier("sidebar.terminal.\(tab.title)")
    .onHover { inside in
      if inside {
        hoveredTerminal = tab.id
      } else if hoveredTerminal == tab.id {
        hoveredTerminal = nil
      }
    }
    .contextMenu {
      Button(role: .destructive) {
        store.requestCloseTerminalTab(tab.id, for: target)
      } label: {
        Label("Close \(tab.title)", systemImage: "xmark")
      }
    }
  }

  /// Total notifications for a project: its root plus every workroom. Lets the (possibly
  /// collapsed) project row surface activity from any child. Reuses `count(target:)` and the
  /// canonical id builders, so no target-id string parsing leaks in here.
  private func projectUnread(_ project: Project) -> Int {
    var total = notifications.count(target: TerminalTarget.rootID(project: project.path))
    for workroom in project.workrooms {
      total += notifications.count(
        target: TerminalTarget.workroomID(project: project.path, name: workroom.name))
    }
    return total
  }

  /// Row highlight drawn at the row-background level so hover and selection share the
  /// same (smaller, inset) geometry. Selected rows get a stronger fill; hovered rows a
  /// subtle one. Drawn ourselves so we control the size rather than the full-row system
  /// selection highlight.
  @ViewBuilder
  private func rowHighlight(_ id: SidebarID, selected: Bool) -> some View {
    let tokens = ThemeService.shared.tokens
    RoundedRectangle(cornerRadius: 6)
      .fill(selected ? tokens.surface : (hovered == id ? tokens.hover : Color.clear))
      .padding(.horizontal, 8)
      .padding(.vertical, 1)
  }

  /// Row highlight for a terminal row (issue #30) — same geometry as `rowHighlight` but keyed on the
  /// tab's UUID via `hoveredTerminal`, since terminal rows live outside the `SidebarID` selection.
  @ViewBuilder
  private func terminalHighlight(_ tabID: TerminalTab.ID, selected: Bool) -> some View {
    // Lighter than the root/workroom selection fill (0.13): the selected workroom is the primary
    // selection, the focused terminal a secondary "active within" cue — so the two don't read as two
    // equal selections when a subtree is open (issue #30 design pass).
    let tokens = ThemeService.shared.tokens
    let fill: Color =
      selected ? tokens.hover : (hoveredTerminal == tabID ? tokens.hover.opacity(0.5) : .clear)
    RoundedRectangle(cornerRadius: 6)
      .fill(fill)
      .padding(.horizontal, 8)
      .padding(.vertical, 1)
  }

  // MARK: Expansion

  private func isExpanded(_ path: String) -> Bool { !store.collapsedProjects.contains(path) }

  /// Expand or collapse a project. Mutating `store.collapsedProjects` (a `@Published` on the observed
  /// store) re-evaluates the sidebar synchronously, so the tree commits on the click — see the
  /// property's note for why a `@Default` here only updated after the pointer moved. The reveal is
  /// animated by the `List`'s `.animation(value: store.collapsedProjects)`.
  private func toggle(_ path: String) {
    if store.collapsedProjects.contains(path) {
      store.collapsedProjects.remove(path)
    } else {
      store.collapsedProjects.insert(path)
    }
  }

  // MARK: Chrome

  /// The sidebar's bottom bar: the appearance toggle on the left, "Add Project" on the right.
  private var bottomBar: some View {
    HStack {
      Button {
        theme = theme.next
      } label: {
        Image(systemName: theme.symbol)
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(ThemeService.shared.tokens.hover.opacity(themeHovering ? 1 : 0))
          )
      }
      .buttonStyle(.plain)
      .onHover { themeHovering = $0 }
      .help("Theme: \(theme.label) — click to switch to \(theme.next.label)")
      .accessibilityLabel("Theme: \(theme.label)")

      Spacer()

      // Add Project, bottom-right. No key equivalent — File ▸ New Project… lost ⌘O to Open Workroom…
      // (issue #94). Routes through the store's request flag so the importer (re-homed to RootView,
      // issue #23 OV1) can present even when this sidebar is collapsed in Workrooms View.
      Button {
        store.requestAddProject = true
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(ThemeService.shared.tokens.hover.opacity(addProjectHovering ? 1 : 0))
          )
      }
      .buttonStyle(.plain)
      .onHover { addProjectHovering = $0 }
      .help("Add a project folder")
      .accessibilityLabel("Add Project")
      .accessibilityIdentifier("AddProject")
    }
    .padding(.horizontal, 8)
    .padding(.top, 18)
    .padding(.bottom, 6)
    // Solid at the buttons, fading to transparent at the top, so list rows scroll under the bar and
    // stay legible behind it (issue #56 feedback). Click-through so only the buttons capture clicks —
    // a row scrolled under the bar is still clickable through the background. The solid colour is
    // `tokens.panel` — the tint the sidebar's vibrancy is washed with — so the fade blends into the
    // sidebar's (now frosted) background rather than reading as the darker terminal `tokens.bg`.
    .background(
      LinearGradient(
        stops: [
          .init(color: ThemeService.shared.tokens.panel.opacity(0), location: 0),
          .init(color: ThemeService.shared.tokens.panel, location: 0.65),
          .init(color: ThemeService.shared.tokens.panel, location: 1),
        ],
        startPoint: .top, endPoint: .bottom
      )
      .allowsHitTesting(false)
    )
  }
}

/// The root row's label tint (issue #43). A detached/none root takes an explicit `.secondary`; a
/// healthy root applies NO foreground color so it keeps the inherited (vibrant) foreground and dims
/// along with the rest of the sidebar when the window is inactive — pinning any color here (including
/// `.foregroundColor(nil)`) opts the text out of that dimming and leaves it bright on blur. A
/// modifier rather than an inline `if` keeps the row's other label modifiers in one chain.
private struct RootLabelTint: ViewModifier {
  let dim: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if dim { content.foregroundColor(.secondary) } else { content }
  }
}

/// The small indeterminate spinner shown on a root/workroom row while one of its terminals is
/// running a command (issue #28). Matches the project row's create/delete spinner so the sidebar
/// has one progress idiom.
private struct RunningSpinner: View {
  var body: some View {
    ProgressView()
      .controlSize(.small)
      .help("Running a command")
      .accessibilityLabel("Running a command")
  }
}

/// The always-visible "new workroom" button on a project row. Its own hover paints a
/// subtle neutral background to read as an actionable control.
private struct CreateRowButton: View {
  let help: String
  let action: () -> Void
  @State private var hovering = false
  private let theme = ThemeService.shared

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(theme.tokens.hover.opacity(hovering ? 1 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(help)
  }
}

/// Per-row run/stop toggle for a root or workroom whose project has a run command (issue #7). Reads
/// the run state off the store (green = running) and toggles start/stop on click — without selecting
/// the row. Running hovers red (the stop action); stopped hovers green (the start action).
private struct RowRunButton: View {
  let target: TerminalTarget
  @EnvironmentObject var store: AppStore
  @State private var hovering = false

  var body: some View {
    let running = store.isRunCommandRunning(for: target.id)
    // The action's color: red to stop (like delete), green to start. Drives the hover icon tint AND
    // the rounded hover background, matching the row's other buttons (new-workroom / delete).
    let tint: Color = running ? .red : .green
    Button {
      store.toggleRunCommand(for: target)
    } label: {
      Image(systemName: running ? "stop.circle.fill" : "play.circle.fill")
        .font(.system(size: 12))
        .foregroundStyle(
          running ? (hovering ? .red : .green) : (hovering ? .green : Color.secondary)
        )
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(tint.opacity(hovering ? 0.18 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(running ? "Stop run command" : "Start run command")
    .accessibilityLabel(running ? "Stop run command" : "Start run command")
  }
}

/// The gear button on a project row, revealed on hover to the left of the new-workroom button,
/// opening Project Settings (issue #7). Laid out always (so the row size is stable) and only made
/// visible via `visible`; its own hover paints a subtle neutral background like the new-workroom one.
private struct SettingsRowButton: View {
  let help: String
  let visible: Bool
  let action: () -> Void
  @State private var hovering = false
  private let theme = ThemeService.shared

  var body: some View {
    Button(action: action) {
      Image(systemName: "gearshape")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(theme.tokens.hover.opacity(hovering ? 1 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(help)
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
  }
}

/// The trash button revealed when a workroom row is hovered. It is always laid out (so
/// the row's size doesn't change on hover) and only made visible via `visible`. Its own
/// hover paints a soft pastel-red background to flag the destructive action.
private struct DeleteRowButton: View {
  let name: String
  let visible: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "trash")
        .font(.system(size: 11))
        .foregroundStyle(hovering ? Color.red : .secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(Color.red.opacity(hovering ? 0.18 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help("Delete \(name)")
    .accessibilityLabel("Delete \(name)")
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
  }
}

/// The terminal-subtree disclosure chevron on a root/workroom row (issue #30). Hover paints a subtle
/// rounded background — the same idiom as the row's other inline buttons (new-workroom, delete). The
/// chevron itself stays at the shared caret-column width, leading-aligned, so it keeps lining up with
/// the terminal rows' glyphs; the hover fill is a non-layout background that can't shift it.
private struct TerminalDisclosureButton: View {
  let expanded: Bool
  let width: CGFloat
  let action: () -> Void
  @State private var hovering = false
  private let theme = ThemeService.shared

  var body: some View {
    Button(action: action) {
      // Center the chevron in the caret slot. Centring pins its *center* to the slot center regardless
      // of which chevron is shown — so the glyph doesn't jump on toggle and the hover fill (also
      // centered on the slot) sits symmetrically around it. The terminal-row glyph centers in the same
      // slot, so the two share one vertical axis.
      Image(systemName: expanded ? "chevron.down" : "chevron.right")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .frame(width: width, height: 18, alignment: .center)
        .background {
          RoundedRectangle(cornerRadius: 5)
            .fill(theme.tokens.hover.opacity(hovering ? 1 : 0))
            .frame(width: 18, height: 18)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(expanded ? "Hide terminals" : "Show terminals")
    .accessibilityLabel(expanded ? "Hide terminals" : "Show terminals")
  }
}

/// The ✕ revealed when a terminal row is hovered (issue #30). Mirrors `DeleteRowButton`'s
/// reveal-on-hover layout, but neutral rather than red — closing a terminal is gated by the same
/// confirmation as ⌘W (`requestCloseTerminalTab`), not the harder workroom deletion.
private struct CloseTerminalRowButton: View {
  let title: String
  let visible: Bool
  let action: () -> Void
  @State private var hovering = false
  private let theme = ThemeService.shared

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(theme.tokens.hover.opacity(hovering ? 1 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help("Close \(title)")
    .accessibilityLabel("Close \(title)")
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
  }
}
