import AppKit
import ObjectiveC
import SwiftUI

/// Makes the Terminals section's List drag its rows under the shared title chip (`DragGhostChip`),
/// as every tab and pane drag does (#652), in place of AppKit's snapshot of the row, which carried
/// the row's hover × and +.
///
/// The List's reorder drag is AppKit's own table drag (`.onMove`), and its picture is the table's.
/// Taking the drag over instead doesn't work: without `.onMove` the table's own mouse tracking
/// takes the mouse once a row is pressed, and no gesture of the row's sees the drag at all. So the
/// table keeps its drag, and this swaps only its picture: the one table instance gets a subclass of
/// its own class whose `beginDraggingSession(with:event:source:)` sets each dragged item's image to
/// the chip before AppKit starts the session. The subclass also notes each drop the table performs
/// (`drop`), which `.onMove` doesn't say (#776), and changes nothing of it. Nothing else of the
/// table changes, and no other table, so a SwiftUI that changes its tables only loses the chip and
/// the drop's point, never the drag.
enum SidebarTableDragImage {
  /// The drop the table is performing, while it does: the List's `.onMove` runs inside it.
  @MainActor private(set) static var drop: SidebarRowDrag.ListDrop?
  /// The table's drag, from its start until the next row's begins.
  @MainActor static weak var session: NSDraggingSession?
  /// When the table's latest drag was pressed.
  @MainActor private static var pressedAt: TimeInterval = 0

  /// The title of the row whose drag is starting, set by the row's own gesture (`SidebarRowDrag`),
  /// which reports a point before the table's drag starts. Nil: the table keeps its own picture.
  @MainActor static var title: String?

  private static let selector = #selector(NSView.beginDraggingSession(with:event:source:))

  /// Gives `table` the chip drag image. Idempotent.
  @MainActor static func install(on table: NSTableView) {
    let base: AnyClass = object_getClass(table)!
    let name = "WorkroomChipDrag_" + NSStringFromClass(base)
    if NSStringFromClass(base).hasPrefix("WorkroomChipDrag_") { return }
    let subclass: AnyClass
    if let existing = NSClassFromString(name) {
      subclass = existing
    } else {
      guard let made = objc_allocateClassPair(base, name, 0) else { return }
      typealias Begin =
        @convention(c) (NSView, Selector, [NSDraggingItem], NSEvent, NSDraggingSource)
        -> NSDraggingSession
      let inherited = unsafeBitCast(class_getMethodImplementation(base, selector), to: Begin.self)
      let block:
        @convention(block) (NSView, [NSDraggingItem], NSEvent, NSDraggingSource) ->
          NSDraggingSession = { view, items, event, source in
            // AppKit starts a drag on the main thread.
            nonisolated(unsafe) let given = items
            nonisolated(unsafe) var dragged = items
            MainActor.assumeIsolated {
              // The event is the press that started the drag.
              pressedAt = event.timestamp
              dragged = chipItems(given, in: view, event: event)
            }
            let begun = inherited(view, selector, dragged, event, source)
            nonisolated(unsafe) let started = begun
            MainActor.assumeIsolated { session = started }
            return begun
          }
      let types = method_getTypeEncoding(class_getInstanceMethod(base, selector)!)
      class_addMethod(made, selector, imp_implementationWithBlock(block), types)
      noteDrops(in: made, inheritedFrom: base)
      objc_registerClassPair(made)
      subclass = made
    }
    object_setClass(table, subclass)
  }

  /// Has `made`'s `performDragOperation(_:)` set `drop` around `base`'s.
  private static func noteDrops(in made: AnyClass, inheritedFrom base: AnyClass) {
    let selector = #selector(NSDraggingDestination.performDragOperation(_:))
    guard let method = class_getInstanceMethod(base, selector) else { return }
    typealias Perform = @convention(c) (NSView, Selector, NSDraggingInfo) -> Bool
    let inherited = unsafeBitCast(method_getImplementation(method), to: Perform.self)
    let block: @convention(block) (NSView, NSDraggingInfo) -> Bool = { view, info in
      // AppKit performs a drop on the main thread.
      nonisolated(unsafe) let given = info
      MainActor.assumeIsolated {
        let point = given.draggingLocation
        drop = .init(
          pressedAt: pressedAt, point: view.window?.convertPoint(toScreen: point) ?? point)
      }
      defer { MainActor.assumeIsolated { drop = nil } }
      return inherited(view, selector, info)
    }
    class_addMethod(
      made, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
  }

  /// `items` with the first carrying the chip, centred on the pointer and just above it as the
  /// floating ghost sits (`DragGhost`); the rest go, as one chip stands for the drag.
  @MainActor private static func chipItems(
    _ items: [NSDraggingItem], in view: NSView, event: NSEvent
  ) -> [NSDraggingItem] {
    guard let first = items.first, let title, let image = image(title: title, in: view.window)
    else { return items }
    let point = view.convert(event.locationInWindow, from: nil)
    // The image's bottom edge sits where the floating ghost's panel does, `DragGhost.lift` above
    // the pointer, its margin holding the shadow.
    let size = image.size
    let y = view.isFlipped ? point.y - DragGhost.lift - size.height : point.y + DragGhost.lift
    let frame = CGRect(x: point.x - size.width / 2, y: y, width: size.width, height: size.height)
    first.setDraggingFrame(frame, contents: image)
    return [first]
  }

  @MainActor private static func image(title: String, in window: NSWindow?) -> NSImage? {
    let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
    var image: NSImage?
    // The chip's colours are the system's, resolved against the window's appearance.
    appearance.performAsCurrentDrawingAppearance {
      let renderer = ImageRenderer(
        content: DragGhostChip(title: title, fillsPanel: false)
          .environment(\.colorScheme, appearance.isDark ? .dark : .light))
      renderer.scale = window?.backingScaleFactor ?? 2
      image = renderer.nsImage
    }
    return image
  }
}

extension NSAppearance {
  fileprivate var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// Finds the List's table this sits in and gives it the chip drag image
/// (`SidebarTableDragImage`). Put in any one row of the List.
struct SidebarTableDragImageHook: NSViewRepresentable {
  func makeNSView(context: Context) -> HookView { HookView() }
  func updateNSView(_ nsView: HookView, context: Context) {}

  final class HookView: NSView {
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard window != nil else { return }
      DispatchQueue.main.async { [weak self] in
        var view = self?.superview
        while let current = view, !(current is NSTableView) { view = current.superview }
        if let table = view as? NSTableView { SidebarTableDragImage.install(on: table) }
      }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}
