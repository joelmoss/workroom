import AppKit
import CoreImage
import IOSurface
import SwiftUI

/// The borderless window a pop out or pull back flies a snapshot of the pane in (issue #172). It
/// never takes the mouse, the keyboard or a place in the window cycle, and it goes the moment its
/// transition ends.
///
/// It holds two pictures, what the pane leaves as and what it lands as, each scaled to fill the
/// card at every frame, and crossfades between them as it flies (`Pose.progress`), so its first
/// frame is the slot or window it leaves, pixel for pixel, and its last is the window or slot it
/// lands in.
///
/// Non-opaque with a clear background, so the windows behind it keep rendering (an opaque panel
/// makes every terminal it covers believe it is occluded), and it draws its own shadow, since a
/// borderless non-opaque window casts none.
@MainActor
final class PaneTransitionPanel: PaneWindowTransitionSurface {
  /// Room around the card for its shadow to land in.
  static let margin: CGFloat = 24

  /// One end of the flight: its picture, its corners and whether it casts a window's shadow.
  struct End {
    var image: CGImage?
    var cornerRadius: CGFloat
    var shadow: Bool
  }

  private let panel: NSPanel
  private let card: Card
  private let from: End
  private let to: End

  init(from: End, to: End, background: NSColor, above level: NSWindow.Level) {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
    // Over the window it leaves or lands in, whatever its level: the Quick Terminal's panel floats.
    panel.level = NSWindow.Level(
      rawValue: max(level.rawValue, NSWindow.Level.floating.rawValue) + 1)
    panel.setAccessibilityElement(false)
    let card = Card(from: from.image, to: to.image, background: background, margin: Self.margin)
    panel.contentView = card
    self.panel = panel
    self.card = card
    self.from = from
    self.to = to
  }

  /// Called once per frame: everything set outright, nothing left to Core Animation to tween.
  /// Ordered in by its first call, so it never shows before it is in place.
  func set(_ pose: PaneWindowMotion.Pose) {
    defer { if !panel.isVisible { panel.orderFrontRegardless() } }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    panel.setFrame(padded(pose.frame), display: true)
    panel.alphaValue = pose.alpha
    card.toImage.alphaValue = pose.progress
    card.setCorners(radius(pose.progress), shadow: shadow(pose.progress))
    CATransaction.commit()
  }

  func tearDown(fade: TimeInterval) {
    let panel = panel
    guard fade > 0, panel.isVisible else {
      panel.orderOut(nil)
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = fade
      panel.animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated { panel.orderOut(nil) }
    }
  }

  private func radius(_ progress: CGFloat) -> CGFloat {
    from.cornerRadius + (to.cornerRadius - from.cornerRadius) * progress
  }

  private func shadow(_ progress: CGFloat) -> Float {
    let a: Float = from.shadow ? Card.shadowOpacity : 0
    let b: Float = to.shadow ? Card.shadowOpacity : 0
    return a + (b - a) * Float(progress)
  }

  private func padded(_ frame: NSRect) -> NSRect {
    frame.insetBy(dx: -Self.margin, dy: -Self.margin)
  }

  /// The two pictures on the pane's background, rounded, with a shadow. Each is scaled to fill the
  /// card (`.resize`): aspect-fill would crop at the ends, where the picture has to be exactly the
  /// slot or the window, so the slot's shape stretches to the window's in flight instead.
  private final class Card: NSView {
    static let shadowOpacity: Float = 0.35

    let toImage: NSView
    private let card: NSView
    private let clip: NSView

    init(from: CGImage?, to: CGImage?, background: NSColor, margin: CGFloat) {
      card = NSView(frame: NSRect(x: margin, y: margin, width: 100, height: 100))
      clip = NSView(frame: card.bounds)
      toImage = NSView(frame: card.bounds)
      super.init(frame: NSRect(x: 0, y: 0, width: 100 + 2 * margin, height: 100 + 2 * margin))
      wantsLayer = true
      card.autoresizingMask = [.width, .height]
      card.wantsLayer = true
      card.layer?.backgroundColor = background.cgColor
      card.layer?.cornerCurve = .continuous
      card.layer?.shadowColor = NSColor.black.cgColor
      card.layer?.shadowRadius = 14
      card.layer?.shadowOffset = CGSize(width: 0, height: -6)
      addSubview(card)
      clip.autoresizingMask = [.width, .height]
      clip.wantsLayer = true
      clip.layer?.cornerCurve = .continuous
      clip.layer?.masksToBounds = true
      card.addSubview(clip)
      let fromImage = Self.imageView(from, frame: card.bounds)
      clip.addSubview(fromImage)
      Self.configure(toImage, image: to)
      clip.addSubview(toImage)
    }

    /// Its corners and shadow for this frame, once the card has its size. The shadow is cast from
    /// a path of the card's shape, so Core Animation never cuts it from the card's pixels as the
    /// card resizes; corners and opacity are written only when they change.
    func setCorners(_ radius: CGFloat, shadow: Float) {
      guard let layer = card.layer else { return }
      if layer.cornerRadius != radius {
        layer.cornerRadius = radius
        clip.layer?.cornerRadius = radius
      }
      if layer.shadowOpacity != shadow { layer.shadowOpacity = shadow }
      let bounds = card.bounds
      let corner = min(radius, bounds.width / 2, bounds.height / 2)
      layer.shadowPath =
        shadow > 0
        ? RoundedRectangle(cornerRadius: max(corner, 0), style: .continuous).path(in: bounds)
          .cgPath
        : nil
    }

    private static func imageView(_ image: CGImage?, frame: NSRect) -> NSView {
      let view = NSView(frame: frame)
      configure(view, image: image)
      return view
    }

    private static func configure(_ view: NSView, image: CGImage?) {
      view.autoresizingMask = [.width, .height]
      view.wantsLayer = true
      view.layer?.contents = image
      view.layer?.contentsGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  }
}

/// A reduce-motion pop out fades the real window in where it opens. Nothing to tear down: it stays.
@MainActor
final class PaneWindowFadeIn: PaneWindowTransitionSurface {
  private weak var window: NSWindow?
  init(_ window: NSWindow) { self.window = window }

  func set(_ pose: PaneWindowMotion.Pose) { window?.alphaValue = pose.alpha }

  func tearDown(fade: TimeInterval) {}
}

/// A picture of a pane, for its transition to fly (issue #172). A view's own drawing is cached,
/// then each terminal surface in it is drawn over that from the frame it last presented: the
/// renderer hands its layer an `IOSurface` (`IOSurfaceLayer`), which a view cache does not draw.
/// Nothing here touches the surface beyond reading that frame. All local drawing: no window-server
/// capture, so nothing here can ask for Screen Recording.
@MainActor
enum PaneSnapshot {
  private static let context = CIContext(options: [.cacheIntermediates: false])

  /// `region` of `root` (in its coordinates) at `root`'s backing scale, on `background`, with
  /// `surfaces` drawn over it where they sit.
  static func capture(
    _ region: NSRect, of root: NSView, surfaces: [NSView], background: NSColor? = nil
  ) -> CGImage? {
    let scale = root.window?.backingScaleFactor ?? 2
    guard let bitmap = context(size: region.size, scale: scale) else { return nil }
    let size = region.size
    if let background {
      bitmap.setFillColor(background.cgColor)
      bitmap.fill(CGRect(origin: .zero, size: size))
    }
    if let rep = root.bitmapImageRepForCachingDisplay(in: region) {
      root.cacheDisplay(in: region, to: rep)
      if let base = rep.cgImage { bitmap.draw(base, in: CGRect(origin: .zero, size: size)) }
    }
    for surface in surfaces where surface.window === root.window && surface.isDescendant(of: root) {
      guard let frame = presentedImage(of: surface.layer) else { continue }
      let rect = surface.convert(surface.bounds, to: root)
      let y = root.isFlipped ? region.maxY - rect.maxY : rect.minY - region.minY
      bitmap.draw(
        frame,
        in: CGRect(x: rect.minX - region.minX, y: y, width: rect.width, height: rect.height))
    }
    return bitmap.makeImage()
  }

  /// The whole of `window` as it shows: its title bar (traffic lights, title and toolbar, drawn by
  /// the frame view, which holds the title bar's views) over its content, its terminals included,
  /// on its background at full opacity (under Glass the title bar draws none of its own).
  static func window(_ window: NSWindow) -> CGImage? {
    guard let frameView = window.contentView?.superview else { return nil }
    return capture(
      frameView.bounds, of: frameView, surfaces: surfaces(in: frameView),
      background: (window.backgroundColor ?? .windowBackgroundColor).withAlphaComponent(1))
  }

  /// Just `window`'s title bar, the same pixels as the top of `window(_:)`'s picture, cut on the
  /// same whole pixel row (`split`): only the band is drawn. It holds no terminal.
  static func titlebar(of window: NSWindow) -> CGImage? {
    guard let frameView = window.contentView?.superview else { return nil }
    let bounds = frameView.bounds
    let scale = window.backingScaleFactor
    let pixels = (bounds.height * scale).rounded()
    guard pixels > 0 else { return nil }
    let rows = (pixels * min(max(titlebarHeight(of: window), 0), bounds.height) / bounds.height)
      .rounded()
    guard rows > 0 else { return nil }
    let height = rows / scale
    let region = NSRect(
      x: bounds.minX, y: frameView.isFlipped ? bounds.minY : bounds.maxY - height,
      width: bounds.width, height: height)
    return capture(
      region, of: frameView, surfaces: [],
      background: (window.backgroundColor ?? .windowBackgroundColor).withAlphaComponent(1))
  }

  /// How tall `window`'s title bar is: everything above its content view.
  static func titlebarHeight(of window: NSWindow) -> CGFloat {
    guard let content = window.contentView else { return 0 }
    return max(0, window.frame.height - content.frame.height)
  }

  /// `image`, `height` points tall, cut `top` points from its top: the chrome row above, the body
  /// below. Cut on a whole pixel row.
  static func split(_ image: CGImage, height: CGFloat, top: CGFloat) -> (
    top: CGImage?, body: CGImage?
  ) {
    guard height > 0 else { return (nil, nil) }
    let rows = Int((CGFloat(image.height) * min(max(top, 0), height) / height).rounded())
    let width = image.width
    return (
      rows > 0 ? image.cropping(to: CGRect(x: 0, y: 0, width: width, height: rows)) : nil,
      rows < image.height
        ? image.cropping(to: CGRect(x: 0, y: rows, width: width, height: image.height - rows))
        : nil
    )
  }

  /// A picture `size` points at `scale`: `top` filling a `topHeight` row at its top and `body`
  /// filling the rest, on `background`. What a pop out lands as (the window's title bar over the
  /// slot's body) and a pull back (the slot's title bar over the window's body).
  static func compose(
    size: NSSize, scale: CGFloat, background: NSColor, top: CGImage?, topHeight: CGFloat,
    body: CGImage?
  ) -> CGImage? {
    guard let bitmap = context(size: size, scale: scale) else { return nil }
    bitmap.setFillColor(background.cgColor)
    bitmap.fill(CGRect(origin: .zero, size: size))
    let topHeight = min(max(topHeight, 0), size.height)
    if let top {
      bitmap.draw(
        top, in: CGRect(x: 0, y: size.height - topHeight, width: size.width, height: topHeight))
    }
    if let body {
      bitmap.draw(body, in: CGRect(x: 0, y: 0, width: size.width, height: size.height - topHeight))
    }
    return bitmap.makeImage()
  }

  /// The frame a layer presents, when its contents are an `IOSurface` or an image.
  static func presentedImage(of layer: CALayer?) -> CGImage? {
    guard let contents = layer?.contents else { return nil }
    let object = contents as CFTypeRef
    if CFGetTypeID(object) == IOSurfaceGetTypeID() {
      let surface = unsafeBitCast(object, to: IOSurfaceRef.self)
      let image = CIImage(ioSurface: surface)
      return context.createCGImage(image, from: image.extent)
    }
    if CFGetTypeID(object) == CGImage.typeID { return (object as! CGImage) }
    return nil
  }

  /// Every terminal surface under `view`, for a snapshot to draw them in.
  static func surfaces(in view: NSView) -> [NSView] {
    if view is GhosttySurfaceView { return [view] }
    return view.subviews.flatMap { surfaces(in: $0) }
  }

  /// A bitmap `size` points at `scale`, drawn in points, y up.
  private static func context(size: NSSize, scale: CGFloat) -> CGContext? {
    let width = Int((size.width * scale).rounded())
    let height = Int((size.height * scale).rounded())
    guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
      let bitmap = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    bitmap.scaleBy(x: scale, y: scale)
    bitmap.interpolationQuality = .high
    return bitmap
  }
}

/// A docked pane's slot as it is now (issue #172): where it is on screen, on whole device pixels,
/// and a picture of it.
@MainActor
struct PaneSlot {
  var rect: NSRect
  var snapshot: CGImage?
  /// The snapshot's pixels per point.
  var scale: CGFloat
  /// What the slot's window draws under it, at full opacity.
  var background: NSColor
  var level: NSWindow.Level

  /// `tabID`'s slot, with `surface` drawn in it; nil when it isn't on screen.
  static func current(of tabID: TerminalTab.ID, surface: NSView?) -> PaneSlot? {
    let anchors = PaneSlotAnchors.shared
    guard let view = anchors.view(for: tabID), let window = view.window,
      let rect = anchors.screenRect(for: tabID)
    else { return nil }
    return PaneSlot(
      rect: rect, snapshot: anchors.snapshot(for: tabID, surface: surface),
      scale: window.backingScaleFactor,
      background: (window.backgroundColor ?? .windowBackgroundColor).withAlphaComponent(1),
      level: window.level)
  }
}

/// Where each docked pane's slot is on screen, for its pop out to grow from and its pull back to
/// land in (issue #172). Each pane-tree leaf registers a view the size of its slot
/// (`PaneSlotAnchor`); a slot counts only while its window is on screen and not hidden.
@MainActor
final class PaneSlotAnchors {
  static let shared = PaneSlotAnchors()

  private final class Weak {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
  }

  private var anchors: [TerminalTab.ID: Weak] = [:]

  func register(_ view: NSView, for tabID: TerminalTab.ID) { anchors[tabID] = Weak(view) }

  func unregister(_ view: NSView, for tabID: TerminalTab.ID) {
    if anchors[tabID]?.view === view { anchors[tabID] = nil }
  }

  /// The slot's view, when its window shows it.
  func view(for tabID: TerminalTab.ID) -> NSView? {
    guard let view = anchors[tabID]?.view, let window = view.window, window.isVisible,
      !window.isMiniaturized, window.occlusionState.contains(.visible),
      !view.isHiddenOrHasHiddenAncestor,
      view.bounds.width >= 1, view.bounds.height >= 1
    else { return nil }
    return view
  }

  /// The slot's rect on screen, on whole device pixels: the same pixels its snapshot covers.
  func screenRect(for tabID: TerminalTab.ID) -> NSRect? {
    guard let view = view(for: tabID), let window = view.window else { return nil }
    return PaneWindowMotion.screenRect(
      of: inWindow(view), windowFrame: window.frame)
  }

  /// A picture of the slot as it is now, `surface` included.
  func snapshot(for tabID: TerminalTab.ID, surface: NSView?) -> CGImage? {
    guard let view = view(for: tabID), let root = view.window?.contentView else { return nil }
    return PaneSnapshot.capture(
      root.convert(inWindow(view), from: nil), of: root, surfaces: surface.map { [$0] } ?? [])
  }

  /// `view`'s bounds in its window's base coordinates, snapped to its device pixels.
  private func inWindow(_ view: NSView) -> NSRect {
    PaneWindowMotion.snapped(
      view.convert(view.bounds, to: nil), scale: view.window?.backingScaleFactor ?? 2)
  }
}
