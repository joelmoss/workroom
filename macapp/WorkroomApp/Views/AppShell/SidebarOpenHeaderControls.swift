import SwiftUI

/// The switcher's controls while it shows the Open Tabs view, before its "+": Expand All /
/// Collapse All, then Group by. The first is hidden in None, which has nothing to fold, and
/// disabled where nothing folds yet, so the "+" keeps its place.
struct SidebarOpenHeaderControls: View {
  let store: AppStore

  var body: some View {
    let grouping = store.openTabsGrouping
    HStack(spacing: 0) {
      if grouping != .ungrouped {
        SidebarFoldAllButton(
          action: store.openTabsFoldAll(grouping: grouping), id: "sidebar.open.foldAll"
        ) { store.foldAllOpenRows($0, grouping: grouping) }
      }
      SidebarOpenGroupByMenu(store: store, grouping: grouping)
    }
  }
}

/// The Projects view's Expand All / Collapse All: every project, and every workroom's terminals.
struct SidebarProjectsFoldAllButton: View {
  let store: AppStore

  var body: some View {
    SidebarFoldAllButton(action: store.projectsFoldAll(), id: "sidebar.projects.foldAll") {
      store.foldAllProjects($0)
    }
  }
}

/// Expand All / Collapse All in a sidebar view's header: folds every row that folds, at every
/// level, while any is unfolded (`action` `.collapse`), else unfolds them all. Disabled with
/// nothing to fold (`action` nil).
struct SidebarFoldAllButton: View {
  let action: SidebarFoldAll?
  let id: String
  let perform: (SidebarFoldAll) -> Void
  @State private var hovering = false

  var body: some View {
    let collapses = action != .expand
    let title = collapses ? "Collapse All" : "Expand All"
    Button {
      guard let action else { return }
      perform(action)
    } label: {
      SidebarIconGlyph(
        systemImage: collapses ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
        hovering: hovering && action != nil)
    }
    .buttonStyle(.plain)
    .disabled(action == nil)
    .opacity(action == nil ? 0.4 : 1)
    .onHover { hovering = $0 }
    .help(action == nil ? "Nothing to expand or collapse" : title)
    .accessibilityLabel(title)
    .accessibilityIdentifier(id)
  }
}

/// Group by: a menu of the groupings, the current one checked.
private struct SidebarOpenGroupByMenu: View {
  let store: AppStore
  let grouping: OpenTabsGrouping
  @State private var hovering = false

  var body: some View {
    Menu {
      Section("Group by") {
        ForEach(OpenTabsGrouping.allCases, id: \.self) { option in
          Toggle(
            option.title,
            isOn: Binding(
              get: { grouping == option },
              set: { if $0 { store.openTabsGrouping = option } })
          )
          .accessibilityIdentifier("sidebar.open.groupBy.\(option.rawValue)")
        }
      }
    } label: {
      SidebarIconGlyph(systemImage: "list.bullet.indent", hovering: hovering)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .onHover { hovering = $0 }
    .help("Group by: \(grouping.title)")
    .accessibilityLabel("Group by: \(grouping.title)")
    .accessibilityIdentifier("sidebar.open.groupBy")
  }
}
