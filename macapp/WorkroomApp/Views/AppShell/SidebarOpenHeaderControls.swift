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
        SidebarOpenFoldAllButton(store: store, grouping: grouping)
      }
      SidebarOpenGroupByMenu(store: store, grouping: grouping)
    }
  }
}

/// Expand All / Collapse All: folds every row that folds, at every level, while any is unfolded,
/// else unfolds them all.
private struct SidebarOpenFoldAllButton: View {
  let store: AppStore
  let grouping: OpenTabsGrouping
  @State private var hovering = false

  var body: some View {
    let action = store.openTabsFoldAll(grouping: grouping)
    let collapses = action != .expand
    let title = collapses ? "Collapse All" : "Expand All"
    Button {
      guard let action else { return }
      store.foldAllOpenRows(action, grouping: grouping)
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
    .accessibilityIdentifier("sidebar.open.foldAll")
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
      SidebarIconGlyph(systemImage: "rectangle.3.group", hovering: hovering)
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
