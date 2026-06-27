import Defaults
import SwiftUI

/// The docked Projects sidebar as a custom card laid out *beside* the detail in `RootView`'s split
/// `HStack` — the mirror of `InspectorColumn` on the leading edge. We render our own `sidebarCard`
/// rather than relying on `NavigationSplitView`'s native column so we own the card's exact position:
/// the native column kept a ~30pt top inset (a toolbar reserve) that left an empty gap under the
/// custom title bar. Built from the same `sidebarCard` the edge-reveal panel uses, so pinned and
/// unpinned match.
///
/// A grab strip on the trailing edge drag-resizes it, persisting the width to `dockedSidebarWidth`
/// (and `Defaults.sidebarWidth`) — the same value the reveal reads.
struct SidebarColumn: View {
  @EnvironmentObject var store: AppStore

  /// Drag-to-split plumbing forwarded to `ProjectSidebar` so a row can be dragged into the detail to
  /// form a workroom split (issue #101) — the same three the title-bar tab bar receives from `RootView`.
  var paneDrag: Binding<WorkroomPaneDrag?> = .constant(nil)
  var localize: (CGPoint) -> CGPoint? = { _ in nil }
  var dropTarget: (CGPoint) -> (sid: SidebarID, edge: PaneEdge)? = { _ in nil }

  /// Live width while dragging — non-`nil` only during a drag. Local `@State` so each mouse-moved
  /// tick re-renders just this column, not the whole RootView tree. Committed once, on drag end.
  @State private var liveWidth: CGFloat?

  // Matches the former `navigationSplitViewColumnWidth(min:max:)` bounds.
  private let minWidth: CGFloat = 240
  private let maxWidth: CGFloat = 360

  private var width: CGFloat {
    let base = liveWidth ?? store.dockedSidebarWidth ?? CGFloat(Defaults[.sidebarWidth])
    return min(max(base, minWidth), maxWidth)
  }

  var body: some View {
    ProjectSidebar(paneDrag: paneDrag, localize: localize, dropTarget: dropTarget)
      .frame(width: width)
      .frame(maxHeight: .infinity)
      // Tighten the gap to the detail panel: 2pt trailing vs the default 8 (mirrors the inspector's
      // leading 2). `topMargin: 0` sits the card flush below the title bar. `vibrant` matches the
      // right inspector's frosted `.sidebar` material so both sidebars read as the same surface.
      .sidebarCard(topMargin: 0, trailingMargin: 2, vibrant: true)
      // AppKit drag handle over the trailing edge (a SwiftUI gesture doesn't get events over the
      // List reliably). 12pt hit area with a resize cursor.
      .overlay(alignment: .trailing) {
        InspectorResizeHandle(
          onDrag: { dx in
            // Handle is on the trailing edge: dragging right (dx > 0) widens. Track in local @State so
            // the live drag re-renders only the sidebar, not every AppStore observer.
            liveWidth = min(max(width + dx, minWidth), maxWidth)
          },
          onEnd: {
            // Commit once: write the chosen width and clear the live state (which re-renders the
            // column to read the committed value).
            if let final = liveWidth {
              store.dockedSidebarWidth = final
              Defaults[.sidebarWidth] = Double(final)
              liveWidth = nil
            }
          }
        )
        .frame(width: 12)
        .frame(maxHeight: .infinity)
      }
  }
}
