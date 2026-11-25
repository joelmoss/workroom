import AppKit
import DesignSystem
import SwiftUI
import WorkroomDomain

/// A sidebar section's heading, the Terminals' and the Projects': the inspector's section header
/// look (`SectionHeaderLabel`, `SectionHeaderMetrics`), a leading fold chevron and the bold title,
/// which fold the section, then its buttons, the last a "+" in the trailing column every sidebar "+"
/// shares. It is its pane's sticky header, on the band (`SidebarSectionHeadingBand`), spanning the
/// sidebar as the inspector's spans its pane.
struct SidebarSectionHeading<Trailing: View>: View {
  let title: String
  @Binding var isFolded: Bool
  let id: String
  @ViewBuilder let trailing: () -> Trailing

  var body: some View {
    HStack(spacing: 0) {
      Button {
        isFolded.toggle()
      } label: {
        SectionHeaderLabel(
          title: title, collapsed: isFolded,
          leadingPadding: SectionHeaderMetrics.sidebarLeadingPadding)
      }
      .buttonStyle(.plain)
      .help(isFolded ? "Show the \(title) section" : "Hide the \(title) section")
      .accessibilityHint(
        isFolded ? "Expand \(title.lowercased())" : "Collapse \(title.lowercased())"
      )
      .accessibilityIdentifier(id)

      HStack(spacing: Spacing.s) { trailing() }
        .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    }
    .padding(.horizontal, SidebarRowMetrics.listContentInset)
    .frame(height: SectionHeaderMetrics.height)
  }
}

/// A heading's background: the section header band, edge to edge.
struct SidebarSectionHeadingBand: View {
  var body: some View { Color.clear.sectionHeaderBand() }
}

/// What the Terminals section's rows do, as `SidebarActions` is for a project's rows. Built from the
/// window's store on each pass of the section; every closure takes the ids it acts on and captures
/// only the store, so a row whose gate skipped still acts on what it shows.
struct SidebarSectionActions {
  var select: @MainActor (SidebarID) -> Void
  /// Focus the terminal in a row's target that has waited longest, in whichever window holds it.
  var showWaiting: @MainActor (TargetID) -> Void
  /// A standalone terminal's row is being dragged (`SidebarRowDrag`).
  var rowDragMoved: @MainActor (SidebarID) -> Void
  /// Fold or unfold a group's row.
  var setFolded: @MainActor (TargetID, Bool) -> Void
  var rename: @MainActor (SidebarID, String) -> Void
  /// Name a standalone terminal; an empty name gives its default back.
  var renameStandalone: @MainActor (SidebarID, String) -> Void
  /// The name the user gave a standalone terminal, if any: what its row's field starts with.
  var standaloneName: @MainActor (SidebarID) -> String?
  /// How Rename… on a row's title-bar tab reaches the row (`SidebarInlineRename`).
  var inlineRename: SidebarInlineRename
  /// New Terminal in a group: in this window with the group selected, or in the Quick Terminal's
  /// panel for its group.
  var newTerminal: @MainActor (SidebarID) -> Void
  /// Close a standalone terminal, in whichever window or panel holds it, as its menu's Close does.
  var closeStandalone: @MainActor (SidebarID) -> Void
  var setStartingFolder: @MainActor (SidebarID, String?) -> Void
  /// Whether deleting a group asks first: only when it has terminals.
  var deleteAsks: @MainActor (SidebarID) -> Bool
  var delete: @MainActor (SidebarID) -> Void

  @MainActor static func live(
    store: AppStore, select: @escaping @MainActor (SidebarID) -> Void, rowDrag: SidebarRowDrag
  ) -> SidebarSectionActions {
    SidebarSectionActions(
      select: select,
      showWaiting: { [store] id in store.showWaiting(inSectionTarget: id) },
      rowDragMoved: { [store, rowDrag] sid in rowDrag.moved(.entry(sid), in: store) },
      setFolded: { [store] id, folded in store.terminalsSection.setFolded(id, folded) },
      rename: { [store] sid, name in store.renameTerminalGroup(sid, to: name) },
      renameStandalone: { [store] sid, name in store.renameStandaloneTerminal(sid, to: name) },
      standaloneName: { [store] sid in store.standaloneTerminal(sid)?.tab.terminal?.userTitle },
      inlineRename: store.sidebarRename,
      newTerminal: { [store] sid in
        if sid.targetID == .quickTerminal { return store.revealQuickTerminal(newTerminal: true) }
        select(sid)
        guard let target = store.target(for: sid) else { return }
        store.newTerminal(in: target)
      },
      closeStandalone: { [store] sid in
        guard let (holder, target, tab) = store.standaloneTerminal(sid) else { return }
        holder.requestCloseTerminalTab(tab.id, for: target)
      },
      setStartingFolder: { [store] sid, folder in
        store.setTerminalGroupStartingFolder(sid, to: folder)
      },
      deleteAsks: { [store] sid in store.terminalGroupDeleteAsks(sid) },
      delete: { [store] sid in Task { await store.deleteTerminalGroup(sid) } })
  }
}

/// Builds a standalone terminal's row (`SidebarRowAdapters.swift` has the projects' adapters).
struct SidebarStandaloneRowAdapter: View, Equatable {
  @EnvironmentObject private var store: AppStore
  let sid: SidebarID
  var hovered = false
  let actions: SidebarSectionActions

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sid == rhs.sid && lhs.hovered == rhs.hovered
  }

  var body: some View {
    SidebarStandaloneRow(model: model, hovered: hovered, actions: actions).equatable()
  }

  private var model: SidebarStandaloneRowModel {
    SidebarStandaloneRowModel(
      sid: sid, title: title, tool: store.standaloneTerminal(sid)?.tab.recognizedTool,
      activity: sid.targetID.map { store.sectionActivity(of: $0) } ?? SidebarTargetActivity())
  }

  /// Its terminal's title, in parts so the row can fade a default title's folder.
  private var title: TerminalTitle {
    sid.targetID.flatMap { store.terminalsSection.terminalTitles(of: $0).first }
      ?? TerminalTitle(name: store.target(for: sid)?.title ?? TerminalsSection.untitled)
  }
}

struct SidebarStandaloneRowModel: Equatable {
  let sid: SidebarID
  let title: TerminalTitle
  /// The program its pane tab shows the logo of (#141), shown in its glyph's place.
  var tool: RecognizedTool? = nil
  /// What its terminal reports, in whichever window holds it, as a workroom's row shows it (#358):
  /// waiting, then a stopped error, then running, then finished.
  let activity: SidebarTargetActivity
}

/// A standalone terminal's row: a terminal glyph, its terminal's name and, while hovered, a close
/// button, as a group's terminal's row has. Selecting it shows the terminal in this window.
struct SidebarStandaloneRow: View, Equatable {
  let model: SidebarStandaloneRowModel
  var hovered = false
  let actions: SidebarSectionActions

  @State private var renaming = false
  @State private var draft = ""

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.model == rhs.model && lhs.hovered == rhs.hovered
  }

  var body: some View {
    #if DEBUG
      let _ = {
        SidebarRowPasses.section += 1
        SidebarRowPasses.byRow[model.sid, default: 0] += 1
      }()
    #endif
    let sid = model.sid
    HStack(spacing: Spacing.s) {
      SidebarTabIcon(glyph: TerminalGroup.standaloneGlyph, tool: model.tool)
        .frame(width: SidebarRowMetrics.caretWidth, height: 18, alignment: .center)
      if renaming {
        SidebarInlineNameField(
          placeholder: model.title.text, draft: $draft,
          help: "The terminal's name. Leave it empty to show the title the program sets",
          id: "sidebar.standalone.rename.\(sid.targetID?.encoded ?? "")",
          commit: {
            renaming = false
            actions.renameStandalone(sid, draft)
          },
          cancel: { renaming = false })
      } else {
        TerminalTitleLabel(title: model.title, folderFont: .subheadline)
          .font(.callout).foregroundStyle(.primary, .secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 0)
      // Its unread dot and status, sliding left on hover for its close button. The button is
      // drawn over the row (below), out of its combined accessibility element, so it stays a
      // button of its own; the slide keeps its room.
      SidebarHoverTrailing(hovered: hovered && !renaming) {
        if let id = sid.targetID { SidebarUnreadDot(source: .target(id)) }
        SidebarSectionStatusMark(
          sid: sid, activity: model.activity, actions: actions, showsDone: true)
      } buttons: {
        Color.clear.frame(width: SidebarRowMetrics.iconColumnWidth, height: 1)
      }
    }
    .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    .sidebarRowFrame(ProjectSidebar.sectionRowInsets)
    .onTapGesture { actions.select(sid) }
    // Dragged onto another standalone terminal's row, the two become a group (#659); onto a
    // group's row, or one of its terminals' rows, it joins that group (#652). Beside the
    // List's own drag, which reorders. Only its start is used: the List's drag takes the mouse,
    // and `SidebarRowDrag` follows it to the end (`SidebarRowDrag.startDistance`).
    .simultaneousGesture(
      DragGesture(minimumDistance: SidebarRowDrag.startDistance, coordinateSpace: .global)
        .onChanged { _ in actions.rowDragMoved(sid) }
    )
    .contextMenu { SidebarStandaloneRowMenu(sid: sid, rename: beginRename) }
    // Rename… on its title-bar tab edits the name here, while the row is drawn.
    .sidebarInlineRename(sid, in: actions.inlineRename, begin: beginRename)
    .help(model.title.text)
    // Its parts combine into one button, but not while its name field is up, so that stays
    // reachable on its own.
    .accessibilityElement(children: renaming ? .contain : .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("sidebar.standalone.\(sid.targetID?.encoded ?? "")")
    .overlay(alignment: .trailing) {
      CloseTerminalRowButton(
        title: model.title.text, visible: hovered && !renaming, help: "Close this terminal",
        id: "sidebar.close.\(sid.targetID?.encoded ?? "")"
      ) { actions.closeStandalone(sid) }
      .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    }
  }

  /// Shows the name field, starting from the name the user gave it (empty for none), so keeping
  /// it unchanged never pins the default name over the program's own title.
  private func beginRename() {
    draft = actions.standaloneName(model.sid) ?? ""
    renaming = true
  }
}

/// A Terminals-section row's marks, as a workroom's row shows them (#358): its unread dot, then
/// one of waiting (which focuses the terminal that has waited longest), a stopped error or running.
struct SidebarSectionActivityMarks: View {
  let sid: SidebarID
  let activity: SidebarTargetActivity
  let actions: SidebarSectionActions

  var body: some View {
    if let id = sid.targetID { SidebarUnreadDot(source: .target(id)) }
    SidebarSectionStatusMark(sid: sid, activity: activity, actions: actions)
  }
}

/// A Terminals-section row's status alone, without its unread dot: waiting (which focuses the
/// terminal that has waited longest), a stopped error, running or, on a standalone terminal's row
/// (`showsDone`), a finished program's check, as its terminal's row under a workroom shows it. A
/// standalone terminal's row shows it in its trailing column, where its close button takes its
/// place on hover.
struct SidebarSectionStatusMark: View {
  let sid: SidebarID
  let activity: SidebarTargetActivity
  let actions: SidebarSectionActions
  var showsDone = false

  var body: some View {
    if let id = sid.targetID {
      if activity.waiting > 0 {
        NeedsYouButton(count: activity.waiting, stale: activity.waitingStale) {
          actions.showWaiting(id)
        }
      } else if activity.failed || activity.running {
        RunningSpinner(failed: activity.failed)
      } else if showsDone, activity.done {
        ProgramStatusGlyph(mark: .done, stale: activity.doneStale)
          .help(ProgramStatusPresentation.turnFinished)
          .accessibilityLabel(ProgramStatusPresentation.turnFinished)
      }
    }
  }
}

/// A standalone terminal's row menu (#660): Rename… (in the row), Move to…, Pop Out and Close,
/// acting on the window that holds its terminal, which may not be the one drawing the row. A
/// menu's content is built when it opens, so it reads the store itself, as the projects' row menus
/// do.
private struct SidebarStandaloneRowMenu: View {
  @EnvironmentObject private var store: AppStore
  let sid: SidebarID
  let rename: () -> Void

  var body: some View {
    if let (holder, target, tab) = store.standaloneTerminal(sid) {
      sidebarRenameMenuItem(action: rename)
      terminalMoveMenu(
        host: holder, tabID: tab.id, target: target,
        help: "Move this terminal into a group or a workroom")
      Button {
        holder.togglePaneWindow(tab.id, targetID: target.id)
      } label: {
        Label("Pop Out", systemImage: "macwindow.badge.plus")
      }
      .disabled(holder.terminals.detachedTabIDs.contains(tab.id))
      .help("Show this terminal in a window of its own")
      Divider()
      Button(role: .destructive) {
        holder.requestCloseTerminalTab(tab.id, for: target)
      } label: {
        Label("Close", systemImage: "xmark")
      }
      .help("Close this terminal")
    }
  }
}
