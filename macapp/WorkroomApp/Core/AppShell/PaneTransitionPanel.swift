import AppKit
import CoreImage
import IOSurface

/// The borderless window a pop out or pull back flies a snapshot of the pane in (issue #172). It
/// never takes the mouse, the keyboard or a place in the window cycle, and it goes the moment its
/// transition ends.
///
/// Non-opaque with a clear background, so the windows behind it keep rendering (an opaque panel
/// makes every terminal it covers believe it is occluded), and it draws its own shadow, since a
/// borderless non-opaque window casts none.
@MainActor
final class PaneTransitionPanel: PaneWindowTransitionSurface {
  /// Room around the card for its shadow to land in.
  static let margin: CGFloat = 24

  private let panel: NSPanel

  /// `scale`: the snapshot's pixels per point, its source window's backing scale.
  init(
    snapshot: CGImage?, scale: CGFloat, background: NSColor, cornerRadius: CGFloat,
    above level: NSWindow.Level
  ) {
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
    panel.contentView = Card(
      snapshot: snapshot, scale: scale, background: background, cornerRadius: cornerRadius,
      margin: Self.margin)
    self.panel = panel
  }

  /// Ordered in by its first `set`, so it never shows before it is in place.
  func set(frame: NSRect, alpha: CGFloat) {
    defer { if !panel.isVisible { panel.orderFrontRegardless() } }
    // A zero-length group replaces an animation still running on either property, so it cannot
    // carry on past the end it was cut short at.
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      panel.animator().setFrame(padded(frame), display: true)
      panel.animator().alphaValue = alpha
    }
    panel.setFrame(padded(frame), display: true)
    panel.alphaValue = alpha
  }

  func animate(to frame: NSRect, alpha: CGFloat) {
    panel.animator().setFrame(padded(frame), display: true)
    panel.animator().alphaValue = alpha
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

  private func padded(_ frame: NSRect) -> NSRect {
    frame.insetBy(dx: -Self.margin, dy: -Self.margin)
  }

  /// The snapshot on the pane's background, rounded, with its shadow. The snapshot keeps its size
  /// and sits at the top-left, as the terminal itself draws (`IOSurfaceLayer`): growing reveals
  /// background, shrinking crops, and the text never stretches.
  private final class Card: NSView {
    init(
      snapshot: CGImage?, scale: CGFloat, background: NSColor, cornerRadius: CGFloat,
      margin: CGFloat
    ) {
      super.init(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
      wantsLayer = true
      let card = NSView(frame: bounds.insetBy(dx: margin, dy: margin))
      card.autoresizingMask = [.width, .height]
      card.wantsLayer = true
      card.layer?.backgroundColor = background.cgColor
      card.layer?.cornerRadius = cornerRadius
      card.layer?.cornerCurve = .continuous
      card.layer?.shadowColor = NSColor.black.cgColor
      card.layer?.shadowOpacity = 0.35
      card.layer?.shadowRadius = 14
      card.layer?.shadowOffset = CGSize(width: 0, height: -6)
      addSubview(card)
      let image = NSView(frame: card.bounds)
      image.autoresizingMask = [.width, .height]
      image.wantsLayer = true
      image.layer?.contents = snapshot
      image.layer?.contentsGravity = .topLeft
      image.layer?.contentsScale = scale
      image.layer?.cornerRadius = cornerRadius
      image.layer?.cornerCurve = .continuous
      image.layer?.masksToBounds = true
      card.addSubview(image)
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

  func set(frame: NSRect, alpha: CGFloat) {
    guard let window else { return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0
      window.animator().alphaValue = alpha
    }
    window.alphaValue = alpha
  }

  func animate(to frame: NSRect, alpha: CGFloat) { window?.animator().alphaValue = alpha }

  func tearDown(fade: TimeInterval) {}
}

/// A picture of a pane, for its transition to fly (issue #172). A view's own drawing is cached,
/// then each terminal surface in it is drawn over that from the frame it last presented: the
/// renderer hands its layer an `IOSurface` (`IOSurfaceLayer`), which a view cache does not draw.
/// Nothing here touches the surface beyond reading that frame.
@MainActor
enum PaneSnapshot {
  private static let context = CIContext(options: [.cacheIntermediates: false])

  /// `region` of `root` (in its coordinates), with `surfaces` drawn over it where they sit.
  static func capture(_ region: NSRect, of root: NSView, surfaces: [NSView]) -> CGImage? {
    guard region.width >= 1, region.height >= 1 else { return nil }
    let scale = root.window?.backingScaleFactor ?? 2
    let width = Int((region.width * scale).rounded())
    let height = Int((region.height * scale).rounded())
    guard
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let bitmap = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    bitmap.scaleBy(x: scale, y: scale)
    let size = region.size
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

  /// The slot's rect on screen.
  func screenRect(for tabID: TerminalTab.ID) -> NSRect? {
    guard let view = view(for: tabID), let window = view.window else { return nil }
    return PaneWindowMotion.screenRect(
      of: view.convert(view.bounds, to: nil), windowFrame: window.frame)
  }

  /// A picture of the slot as it is now, `surface` included.
  func snapshot(for tabID: TerminalTab.ID, surface: NSView?) -> CGImage? {
    guard let view = view(for: tabID), let root = view.window?.contentView else { return nil }
    return PaneSnapshot.capture(
      view.convert(view.bounds, to: root), of: root, surfaces: surface.map { [$0] } ?? [])
  }
}
