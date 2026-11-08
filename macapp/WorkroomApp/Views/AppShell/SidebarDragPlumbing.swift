import SwiftUI
import WorkroomDomain

/// The drag of a root or workroom row into the detail content to form a workroom split (issue
/// #101): the same pipeline the title-bar tab bar uses (`WorkroomTabBar`). `drag` is `RootView`'s
/// `workroomChipDrag`, so `WorkroomSplitView.externalDrag` highlights the drop edge while dragging;
/// `localize` maps a global point into detail-content-local coords, or nil outside the detail area
/// (not a drop); `dropTarget` says where a drop at a global point lands (workroom pane and edge),
/// or nil when it isn't over a pane. `RootView` owns all three; it knows the content frame.
///
/// Equal by `token` alone, which its sidebar mints once (`SidebarColumn`, `EdgeRevealSidebars`), so
/// the sidebar and its rows can sit behind equality gates: the closures are rebuilt on every pass of
/// the views that forward them, and a gate comparing them would never skip. A row whose gate skips
/// keeps the plumbing an earlier pass built, which does what the new one would: the closures read
/// their window's live state (`RootView`'s `@State`, its store), never a value of the pass that
/// built them.
///
/// Sendable, its closures held by a main-actor box, so a view's nonisolated `==` can compare it.
struct SidebarDragPlumbing: Equatable, Sendable {
  let token: UUID
  private let handlers: Handlers

  @MainActor private final class Handlers {
    let drag: Binding<WorkroomPaneDrag?>
    let localize: (CGPoint) -> CGPoint?
    let dropTarget: (CGPoint) -> (sid: SidebarID, edge: PaneEdge, rect: CGRect)?

    init(
      drag: Binding<WorkroomPaneDrag?>, localize: @escaping (CGPoint) -> CGPoint?,
      dropTarget: @escaping (CGPoint) -> (sid: SidebarID, edge: PaneEdge, rect: CGRect)?
    ) {
      self.drag = drag
      self.localize = localize
      self.dropTarget = dropTarget
    }
  }

  @MainActor init(
    token: UUID, drag: Binding<WorkroomPaneDrag?>, localize: @escaping (CGPoint) -> CGPoint?,
    dropTarget: @escaping (CGPoint) -> (sid: SidebarID, edge: PaneEdge, rect: CGRect)?
  ) {
    self.token = token
    handlers = Handlers(drag: drag, localize: localize, dropTarget: dropTarget)
  }

  @MainActor var drag: Binding<WorkroomPaneDrag?> { handlers.drag }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.token == rhs.token }

  /// No drag: for previews and any host that doesn't wire it.
  @MainActor static var inert: Self {
    Self(token: inertToken, drag: .constant(nil), localize: { _ in nil }, dropTarget: { _ in nil })
  }
  private static let inertToken = UUID()

  /// The drag-to-split gesture of row `id`. Mirrors the tab-bar chip (`WorkroomTabBar`), minus the
  /// reorder math: while dragging into the detail content it previews the drop edge (driving
  /// `drag`), and on release over a pane it forms or extends the workroom split, as the chip does.
  /// Attached with `.simultaneousGesture` so it coexists with the List's vertical scroll;
  /// `minimumDistance` keeps a plain click selecting the row (a zero-translation tap never starts
  /// the drag).
  @MainActor func splitGesture(_ id: SidebarID, actions: SidebarActions) -> some Gesture {
    let handlers = handlers
    return DragGesture(minimumDistance: 6, coordinateSpace: .global)
      .onChanged { value in
        handlers.drag.wrappedValue = handlers.localize(value.location).map {
          WorkroomPaneDrag(sid: id, location: $0)
        }
      }
      .onEnded { value in
        if let drop = handlers.dropTarget(value.location) {
          actions.insertSplit(id, drop.sid, drop.edge, drop.rect)
        }
        handlers.drag.wrappedValue = nil
      }
  }
}

/// The light dim on the row being dragged into a split; the primary affordance is the detail-side
/// accent drop band (`externalDrag`). A modifier of its own because every tick of a drag writes
/// the drag state, and only this reads it, so a drag re-runs no row.
struct SidebarDragDim: ViewModifier {
  let id: SidebarID
  let drag: Binding<WorkroomPaneDrag?>

  func body(content: Content) -> some View {
    #if DEBUG
      SidebarRowPasses.dragDim += 1
    #endif
    return content.opacity(drag.wrappedValue?.sid == id ? 0.5 : 1)
  }
}
