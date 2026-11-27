import DesignSystem
import SwiftUI
import WorkroomDomain

/// A project's header in the Open Tabs view's project groupings (`OpenTabsGrouping`): a folder
/// glyph that turns into the disclosure chevron on hover, as a workroom row's glyph does, and the
/// project's name. A click anywhere on it folds or unfolds it, and never selects anything, so it is
/// never highlighted. Folded, it says how many of its terminals wait on you, as a collapsed
/// project in the Projects view does.
struct SidebarOpenProjectRow: View, Equatable {
  let model: OpenTabsProjectRowModel
  let hovered: Bool
  let store: AppStore

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.store === rhs.store && lhs.hovered == rhs.hovered && lhs.model == rhs.model
  }

  private var foldLabel: String { model.isFolded ? "Expand" : "Collapse" }

  var body: some View {
    #if DEBUG
      SidebarRowPasses.openRows[.project(model.path), default: 0] += 1
    #endif
    return HStack(spacing: Spacing.s) {
      leadingSlot
      Text(model.name)
        .font(FontRole.body)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
      if model.isFolded, model.waitingCount > 0 {
        NeedsYouButton(count: model.waitingCount, stale: model.waitingStale) {
          store.showWaiting(inOpenProject: model.path)
        }
        .accessibilityIdentifier("sidebar.open.project.needsYou.\(model.name)")
      }
    }
    .padding(.trailing, SidebarRowMetrics.iconColumnInset)
    .sidebarRowFrame(ProjectSidebar.sectionRowInsets)
    .contentShape(Rectangle())
    .onTapGesture { store.toggleOpenProjectFold(model.path) }
    .contextMenu {
      Button(foldLabel) { store.toggleOpenProjectFold(model.path) }
      Divider()
      Button("Show in Projects") { store.showOpenProjectInProjects(model.path) }
    }
    .help("\(model.name)\n\(model.path)")
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isHeader)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAction { store.toggleOpenProjectFold(model.path) }
    .accessibilityActions {
      Button(foldLabel) { store.toggleOpenProjectFold(model.path) }
      Button("Show in Projects") { store.showOpenProjectInProjects(model.path) }
    }
    .accessibilityIdentifier("sidebar.open.project.\(model.name)")
  }

  /// A folder, swapped for the disclosure chevron on hover.
  private var leadingSlot: some View {
    SidebarAnimated(target: hovered) { chevron in
      ZStack {
        Image(systemName: "folder")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .frame(width: SidebarRowMetrics.caretWidth, height: 18, alignment: .center)
          .accessibilityHidden(true)
          .opacity(1 - chevron)
        TerminalDisclosureButton(
          expanded: !model.isFolded, width: SidebarRowMetrics.caretWidth,
          help: model.isFolded ? "Show its tabs" : "Hide its tabs",
          label: model.isFolded ? "Show tabs" : "Hide tabs"
        ) { store.toggleOpenProjectFold(model.path) }
        .opacity(chevron)
        .allowsHitTesting(hovered)
        .accessibilityIdentifier("sidebar.open.project.fold.\(model.name)")
      }
    }
  }

  private var accessibilityLabel: String {
    var parts = ["project \(model.name)"]
    parts.append(model.targetCount == 1 ? "1 workroom" : "\(model.targetCount) workrooms")
    if model.isFolded { parts.append("folded") }
    if model.isFolded, model.waitingCount > 0 {
      parts.append(
        ProgramStatusPresentation.waitingLabel(
          count: model.waitingCount, stale: model.waitingStale))
    }
    return parts.joined(separator: ", ")
  }
}

/// A tab row's workroom after its title, in a grouping with no workroom rows
/// (`OpenTabsTabContext`): secondary, smaller, and the first to truncate. A root is named by the
/// branch it is on, as the Projects view's root row is, read here so a checkout repaints only this.
struct OpenTabContextLabel: View {
  let context: OpenTabsTabContext
  @EnvironmentObject private var vcsStatus: VCSStatusService

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      // In full, as drawn: a root's branch, which the row's own tooltip can't read.
      .help(text)
      .accessibilityHidden(true)
  }

  private var text: String {
    let name =
      switch context.name {
      case .text(let text): text
      case .root(let path): vcsStatus.rootPresentation(for: path).label
      }
    return context.project.map { "\($0) / \(name)" } ?? name
  }
}
