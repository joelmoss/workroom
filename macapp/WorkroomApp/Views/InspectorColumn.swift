import AppKit
import Defaults
import SwiftUI

/// The docked inspector as a custom card laid out *beside* the detail (in `RootView`'s detail HStack),
/// so it pushes the detail narrower — like the native inspector did — but renders as our own clean
/// `sidebarCard` with no native split-view separator line. Built from the exact same `sidebarCard`
/// the edge-reveal panel uses, so the pinned and unpinned inspector are identical.
///
/// A grab strip on the leading edge drag-resizes it, persisting the width to `dockedInspectorWidth`
/// (and `Defaults.inspectorWidth`) — the same value the reveal reads.
struct InspectorColumn: View {
  @EnvironmentObject var store: AppStore

  /// Live width while dragging — non-`nil` only during a drag. Held in local `@State` so each
  /// mouse-moved tick re-renders just this view; publishing to the store every tick would re-render
  /// the whole RootView tree (sidebar, detail, terminals). Committed to the store + Defaults once, on
  /// drag end, so `@Published dockedInspectorWidth` fires a single time.
  @State private var liveWidth: CGFloat?

  // Matches the former `.inspectorColumnWidth(min:max:)` bounds.
  private let minWidth: CGFloat = 260
  private let maxWidth: CGFloat = 520

  private var width: CGFloat {
    let base = liveWidth ?? store.dockedInspectorWidth ?? CGFloat(Defaults[.inspectorWidth])
    return min(max(base, minWidth), maxWidth)
  }

  var body: some View {
    RightInspector()
      .frame(width: width)
      .frame(maxHeight: .infinity)
      .sidebarCard(topMargin: 0)
      // AppKit drag handle over the leading edge (a SwiftUI gesture doesn't get events over the
      // AppKit inspector). 12pt hit area with a resize cursor.
      .overlay(alignment: .leading) {
        InspectorResizeHandle(
          onDrag: { dx in
            // Handle is on the leading edge: dragging left (dx < 0) widens. Track in local @State so
            // the live drag re-renders only the inspector, not every AppStore observer.
            liveWidth = min(max(width - dx, minWidth), maxWidth)
          },
          onEnd: {
            // Commit once: the only @Published write, so the tree re-renders a single time.
            if let final = liveWidth {
              store.dockedInspectorWidth = final
              Defaults[.inspectorWidth] = Double(final)
              liveWidth = nil
            }
          }
        )
        .frame(width: 12)
        .frame(maxHeight: .infinity)
      }
  }
}
