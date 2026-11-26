import AppKit
import DesignSystem
import SwiftUI
import WorkroomDomain

/// The Open row a drag has lifted out of its list (#819): the ghost that carries it under the
/// pointer, and the list's order while it moves (`OpenRowReflow`), which its window's
/// `SidebarOpenList` shows. One at a time, as there is one pointer.
///
/// Only `reflow` is observed, and it changes only when the gap moves: the pointer's other moves
/// move the ghost's panel and re-run no view.
@MainActor
@Observable
final class OpenRowLift {
  static let shared = OpenRowLift()

  /// Where the lifted row and its list were on screen as it lifted (y up), and where the press was.
  struct Geometry {
    let row: CGRect
    let list: CGRect
    let start: CGPoint
    /// The screen y of the top of the list's first row.
    let listTop: CGFloat
    let pitch: CGFloat
  }

  /// The lifted row's list order, the store's whose window it is in.
  private(set) var reflow: OpenRowReflow?
  @ObservationIgnored private weak var store: AppStore?
  @ObservationIgnored private(set) var geometry: Geometry?
  @ObservationIgnored let ghost = OpenRowGhost()
  /// Counts lifts, so a flight that ends after another lift leaves that one be.
  @ObservationIgnored private var generation = 0
  /// The lift is one a drag from outside the list made as it came over it (`handOver`), and it
  /// hasn't been let go: its drag's session ends it.
  @ObservationIgnored var isHandover = false

  /// The lifted row's order, when `store`'s list holds it.
  func reflow(for store: AppStore) -> OpenRowReflow? {
    guard let reflow, self.store === store else { return nil }
    return reflow
  }

  /// Lifts `reflow.dragged`'s row, drop zone `zone`, out of `store`'s list as `report`'s drag
  /// starts: the ghost, drawing `content`, takes its place under the pointer, and the row's slot
  /// becomes the gap. The drag's drop zones are hit where they were as it lifted
  /// (`TerminalDragSession.hitMap`), whatever the list's rows have slid to.
  func lift(
    _ reflow: OpenRowReflow, in store: AppStore, zone: PaneDropZone, report: OpenRowDrag.Report,
    content: AnyView
  ) {
    guard let window = store.hostWindow, let (row, list) = Self.listRow(zone, in: store)
    else { return }
    let held = CGPoint(
      x: report.screen.x - report.translation.width, y: report.screen.y + report.translation.height)
    start(reflow, in: store, window: window, content: content, row: row, list: list, held: held)
    follow(report)
  }

  /// Shows the ghost, drawing `content` over `row` (the screen rect of `reflow.anchor` in `list`),
  /// and takes the lift on, held at `start`.
  func start(
    _ reflow: OpenRowReflow, in store: AppStore, window: NSWindow, content: AnyView, row: CGRect,
    list: CGRect, held start: CGPoint
  ) {
    ghost.show(content, row: row, appearance: window.effectiveAppearance)
    begin(
      reflow, in: store,
      geometry: Geometry(
        row: row, list: list, start: start,
        offset: reflow.measured.firstIndex(of: reflow.anchor) ?? 0,
        pitch: SidebarOpenList.rowPitch))
  }

  /// Where the Open list's row marked `zone` is on screen, and the list (screen, y up): the row's
  /// in the List's table, as a group's title bar in a split marks the same zone.
  static func listRow(_ zone: PaneDropZone, in store: AppStore) -> (row: CGRect, list: CGRect)? {
    guard let window = store.hostWindow,
      let view = store.paneDropZoneViews[zone]?.lazy.compactMap(\.view).first(where: {
        $0.window === window && !$0.isHiddenOrHasHiddenAncestor
          && $0.enclosingScrollView?.documentView is NSTableView
      })
    else { return nil }
    let row = window.convertToScreen(view.convert(view.bounds, to: nil))
    let list =
      view.enclosingScrollView.map { window.convertToScreen($0.convert($0.bounds, to: nil)) }
      ?? row
    return (row, list)
  }

  /// Takes the lift on, measured at `geometry`: tests begin here, with no row on screen.
  func begin(_ reflow: OpenRowReflow, in store: AppStore, geometry: Geometry) {
    generation += 1
    self.store = store
    self.geometry = geometry
    store.terminalDrag.hitMap = { [weak self] point in
      guard let self else { return point }
      return self.liftedPoint(point)
    }
    store.terminalDrag.ownGhost = { [weak self] point in
      guard let self else { return false }
      return self.showsGhost(at: point)
    }
    self.reflow = reflow
  }

  /// Whether the ghost stands in for the drag's own image at `screen`: anywhere for a row the drag
  /// started on, over the list only for one a drag from outside it lifted (`handOver`).
  func showsGhost(at screen: CGPoint) -> Bool {
    !isHandover || isOverList(screen)
  }

  /// The pointer's place in the list's content (y down from its first row's top), nil outside
  /// the list, or once the sidebar shows its Projects view instead (a drag springs it there).
  func contentY(at screen: CGPoint) -> CGFloat? {
    guard let geometry, store?.sidebarView == .open, geometry.list.contains(screen) else {
      return nil
    }
    return geometry.listTop - screen.y
  }

  /// Whether `screen` is over the list.
  func isOverList(_ screen: CGPoint) -> Bool { contentY(at: screen) != nil }

  /// Where a drop zone measured as the row lifted is under `screen`: the same row, where it was.
  /// Nil over the gap and the lifted tab's own workroom, which are this reorder's.
  func liftedPoint(_ screen: CGPoint) -> CGPoint? {
    guard let geometry, let reflow, let y = contentY(at: screen) else { return screen }
    guard let lifted = reflow.liftedY(for: y, pitch: geometry.pitch) else { return nil }
    return CGPoint(x: screen.x, y: geometry.listTop - lifted)
  }

  /// The ghost follows the pointer, at the place on the row it was grabbed by; out of the window
  /// the window the drag would make shows instead.
  func follow(_ report: OpenRowDrag.Report) {
    if isDragOutsideWindow(report.location) { return ghost.hide() }
    follow(screen: report.screen)
  }

  /// The ghost follows the pointer at `screen`; a lift a drag from outside the list made shows it
  /// only over the list, where it stands in for the drag's own image.
  func follow(screen: CGPoint) {
    guard let geometry else { return }
    if !showsGhost(at: screen) { return ghost.hide() }
    ghost.move(
      to: CGPoint(
        x: geometry.row.minX + screen.x - geometry.start.x,
        y: geometry.row.minY + screen.y - geometry.start.y))
  }

  /// The gap follows the pointer at `screen`. `holds`: it is onto a row that takes the drop or
  /// refuses it, which shows that, and the gap stays.
  func move(to screen: CGPoint, holds: Bool) {
    guard var next = reflow, let geometry else { return }
    next.pointer(at: contentY(at: screen), pitch: geometry.pitch, holds: holds)
    if next != reflow { reflow = next }
  }

  /// Let go over its gap: the ghost settles into it, then the row shows there. The store has
  /// taken the new order already, which is the order the list shows.
  func settle() { fly(restoring: false) }

  /// Let go where nothing takes it, or Escape: the ghost flies back to its place and the list
  /// goes back to its order.
  func cancel() { fly(restoring: true) }

  /// Something else took the drop (a split, a window, a group): the ghost goes where it is.
  func drop() {
    ghost.fade()
    end()
  }

  private func fly(restoring: Bool) {
    isHandover = false
    guard var reflow, let geometry else { return end() }
    if restoring {
      reflow.restore()
      self.reflow = reflow
    }
    guard ghost.isVisible, let slot = reflow.slot else {
      ghost.clear()
      return end()
    }
    let lift = generation
    ghost.fly(to: origin(ofSlot: slot, in: geometry), animated: animates) { [weak self] in
      guard let self, self.generation == lift else { return }
      self.ghost.clear()
      self.end()
    }
  }

  /// Let go over its gap where `move` makes a new row of it (a tab let go between workrooms
  /// becomes a standalone terminal there): the ghost settles into the gap while `move` runs, and
  /// the gap holds until `move` is done, when the list shows the store's order, the new row where
  /// the gap was. When `move` fails the ghost flies back and the list goes back to its order.
  func land(_ move: @escaping @MainActor () async -> Bool) {
    isHandover = false
    let lift = generation
    let landing = Landing()
    if let reflow, let geometry, ghost.isVisible, let slot = reflow.slot {
      ghost.fly(to: origin(ofSlot: slot, in: geometry), animated: animates) { [weak self] in
        landing.flown = true
        guard let self, self.generation == lift, landing.moved == true else { return }
        self.ghost.clear()
      }
    } else {
      landing.flown = true
    }
    Task { @MainActor [weak self] in
      let moved = await move()
      landing.moved = moved
      guard let self, self.generation == lift else { return }
      guard moved else { return self.cancel() }
      self.end()
      if landing.flown { self.ghost.clear() }
    }
  }

  /// How far a `land` has got.
  @MainActor
  private final class Landing {
    var flown = false
    var moved: Bool?
  }

  private var animates: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  /// Where the ghost's row goes to sit in list row `slot` (screen).
  private func origin(ofSlot slot: Int, in geometry: Geometry) -> CGPoint {
    let midY = geometry.listTop - (CGFloat(slot) + 0.5) * geometry.pitch
    return CGPoint(x: geometry.row.minX, y: midY - geometry.row.height / 2)
  }

  private func end() {
    isHandover = false
    store?.terminalDrag.hitMap = nil
    store?.terminalDrag.ownGhost = nil
    store = nil
    geometry = nil
    if reflow != nil { reflow = nil }
  }
}

extension OpenRowLift.Geometry {
  /// Measured on `row`, the list's row `offset` rows down from its first, `pitch` apart.
  init(row: CGRect, list: CGRect, start: CGPoint, offset: Int, pitch: CGFloat) {
    self.init(
      row: row, list: list, start: start, listTop: row.midY + pitch / 2 + CGFloat(offset) * pitch,
      pitch: pitch)
  }
}

/// The lifted Open row's ghost: a borderless, non-activating, mouse-transparent panel, so it
/// follows the pointer anywhere over the window, the sidebar or not, and no drop under the pointer
/// meets it (`DragGhost.windowNumbers`).
@MainActor
final class OpenRowGhost {
  /// Room round the row for its shadow, which the panel would otherwise clip.
  static let margin: CGFloat = 16
  /// How long it takes to settle into its gap or fly back.
  static let flight: TimeInterval = 0.2

  private var panel: NSPanel?
  private var host: NSHostingView<AnyView>?
  /// Counts fades and shows, so a fade that ends after the next show leaves it on screen.
  private var fades = 0

  var windowNumber: Int? { panel?.windowNumber }
  var isVisible: Bool { panel?.isVisible == true }

  /// Shows `content` over `row` (screen).
  func show(_ content: AnyView, row: CGRect, appearance: NSAppearance) {
    fades += 1
    let panel = existingPanel()
    host?.rootView = content
    panel.appearance = appearance
    panel.alphaValue = 1
    panel.setFrame(row.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
    panel.orderFront(nil)
  }

  /// Puts the row's origin at `origin` (screen).
  func move(to origin: CGPoint) {
    guard let panel else { return }
    panel.setFrameOrigin(CGPoint(x: origin.x - Self.margin, y: origin.y - Self.margin))
    if !panel.isVisible { panel.orderFront(nil) }
  }

  /// Moves the row's origin to `origin`, eased, then calls `done`.
  func fly(to origin: CGPoint, animated: Bool, done: @escaping @MainActor () -> Void) {
    guard let panel else { return done() }
    let frame = CGRect(
      origin: CGPoint(x: origin.x - Self.margin, y: origin.y - Self.margin), size: panel.frame.size)
    guard animated else {
      panel.setFrame(frame, display: true)
      return done()
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.flight
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      panel.animator().setFrame(frame, display: true)
    } completionHandler: {
      MainActor.assumeIsolated { done() }
    }
  }

  /// Fades it out where it is.
  func fade() {
    guard let panel, panel.isVisible else { return }
    fades += 1
    let fade = fades
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      panel.animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated {
        // Not when another drag has shown it again meanwhile.
        guard self.fades == fade else { return }
        self.clear()
        panel.alphaValue = 1
      }
    }
  }

  func hide() {
    if panel?.isVisible == true { panel?.orderOut(nil) }
  }

  /// Hides it and lets its row go: the copy, though hidden, would otherwise stay drawn, and a
  /// rename asked of the row (`SidebarInlineRename`) could land on it.
  func clear() {
    hide()
    host?.rootView = AnyView(EmptyView())
  }

  private func existingPanel() -> NSPanel {
    if let panel { return panel }
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    let panel = DragGhostPanel.make(identifier: "openRowGhost", content: host)
    self.host = host
    self.panel = panel
    return panel
  }
}

/// What the ghost draws round a row: the selected row's fill on the window's background, so it
/// reads on whatever it passes over, a little translucent, with a soft shadow.
struct OpenRowGhostChrome<Content: View>: View {
  let content: Content
  @Environment(\.themeTokens) private var tokens

  var body: some View {
    content
      .background {
        ZStack {
          RoundedRectangle(cornerRadius: Radius.s)
            .fill(tokens.bg)
            .padding(.horizontal, SidebarRowMetrics.listContentInset)
            .padding(.vertical, 1)
          SidebarSelectedRowFill()
        }
      }
      .compositingGroup()
      .opacity(0.9)
      .shadow(color: .black.opacity(0.28), radius: 8, y: 4)
      .padding(OpenRowGhost.margin)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }
}
