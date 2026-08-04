import AppKit
import ScreenCaptureKit

/// One window capture: the pixels plus the two things every crop taken from them depends on.
struct WindowCapture {
  let image: CGImage
  /// `SCContentFilter.contentRect` — the crop reference. **Not** the window frame; see
  /// `SnapshotGeometry`.
  let contentRect: CGRect
  /// `SCContentFilter.pointPixelScale`.
  let scale: CGFloat
}

/// How a window's pixels are obtained. A protocol so the service is testable with no windows, no
/// ScreenCaptureKit and no timing.
protocol SnapshotCapturing: Sendable {
  func capture(window: NSWindow, maxLongEdge: CGFloat) async throws -> WindowCapture?
}

/// The real capturer.
///
/// Needs **no Screen Recording permission**: `SCShareableContent.currentProcess` (macOS 14.4+) returns
/// content capturable "without user consent via TCC", and the T1 spike confirmed the *capture* also
/// returns real pixels — `CGPreflightScreenCaptureAccess() == false`, no prompt, and a
/// never-activated background window captured fine. So there is no permission flow, no Info.plist key
/// and no entitlement here by design.
struct ScreenCaptureKitCapturer: SnapshotCapturing {
  func capture(window: NSWindow, maxLongEdge: CGFloat) async throws -> WindowCapture? {
    let number = CGWindowID(window.windowNumber)
    let content = try await SCShareableContent.currentProcess
    // Match on `windowID` alone: `currentProcess` content is REDACTED, so `title` and
    // `owningApplication` may both be nil.
    guard let scWindow = content.windows.first(where: { $0.windowID == number }) else { return nil }

    let filter = SCContentFilter(desktopIndependentWindow: scWindow)
    let config = SCStreamConfiguration()
    let size = SnapshotGeometry.capturePixelSize(
      contentRect: filter.contentRect, scale: CGFloat(filter.pointPixelScale),
      maxLongEdge: maxLongEdge)
    guard size.width >= 1, size.height >= 1 else { return nil }
    config.width = Int(size.width)
    config.height = Int(size.height)
    config.showsCursor = false
    config.ignoreShadowsSingleWindow = true
    config.ignoreGlobalClipSingleWindow = true
    config.captureResolution = .best

    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: config)
    // The delivered image is `contentRect × pointPixelScale`, possibly downscaled by the long-edge cap.
    // Report the ACTUAL scale so crops stay aligned when the cap kicked in.
    let effectiveScale = CGFloat(image.width) / filter.contentRect.width
    return WindowCapture(
      image: image, contentRect: filter.contentRect, scale: effectiveScale)
  }
}

/// Captures nothing. Used by tests and by the `railPreviews` opt-out.
struct StubSnapshotCapturer: SnapshotCapturing {
  func capture(window: NSWindow, maxLongEdge: CGFloat) async throws -> WindowCapture? { nil }
}

/// Plans window captures, crops them into per-region thumbnails, and caches the result.
///
/// The ordering that makes a *mislabelled* card structurally impossible:
///
/// ```
///  request                                  resume
///  ───────                                  ──────
///  read epoch, window.frame, and every  ──▶ await capture ──▶ epoch changed? ──yes──▶ DISCARD shot
///  visible region's screen rect                              frame changed? ──yes──▶ DISCARD shot
///  (all synchronously, one runloop turn)             │no
///                                                   ▼
///                                    crop planned rects → downscale → cache
/// ```
///
/// Worst case is therefore a *stale* card, never a wrong one.
@MainActor
final class SnapshotService {
  static let shared = SnapshotService()

  private let cache: SnapshotCache
  private var capturer: SnapshotCapturing
  private let registry: SnapshotRegistry
  /// Bumped by anything that invalidates in-flight work: a resize, a theme change, a layout change.
  private(set) var epoch = 0
  private var inFlight: Set<CGWindowID> = []
  private var warmed = false

  /// Long-edge cap on a window capture. Above this, a 6K window costs far more to crop than the
  /// 72×56 wells can use.
  static let maxLongEdge: CGFloat = 1440

  init(
    cache: SnapshotCache = SnapshotCache(),
    capturer: SnapshotCapturing = ScreenCaptureKitCapturer(),
    registry: SnapshotRegistry = .shared
  ) {
    self.cache = cache
    self.capturer = capturer
    self.registry = registry
  }

  /// Swap the capturer (the `railPreviews` opt-out, and tests).
  func setCapturer(_ capturer: SnapshotCapturing) {
    self.capturer = capturer
  }

  func snapshot(for key: SnapshotKey, themeGeneration: Int) -> CGImage? {
    cache.snapshot(for: key, themeGeneration: themeGeneration)?.image
  }

  /// Invalidate in-flight work. A resize doesn't get its own capture trigger: it bumps the epoch, so
  /// nothing stale lands, and the next natural trigger fixes the card.
  func invalidate() {
    epoch += 1
  }

  func forgetPanes(_ ids: [TerminalTab.ID]) {
    cache.forgetPanes(ids)
  }

  /// Drop every cached picture — a theme change makes all of them stale at once.
  func invalidateAll() {
    epoch += 1
    cache.removeAll()
  }

  /// Pay ScreenCaptureKit's one-time subsystem initialization (hundreds of ms) at idle, so the first
  /// hold doesn't lose the 250 ms reveal race to it.
  func warm(window: NSWindow) {
    guard !warmed else { return }
    warmed = true
    capture(window: window, themeGeneration: -1)
  }

  /// Capture `window` and refresh every region it currently shows.
  func capture(window: NSWindow, themeGeneration: Int) {
    // A window on an inactive Space can return an all-black *successful* image, which "keep the old
    // entry on failure" would happily cache as the new truth.
    guard window.isVisible, !window.isMiniaturized, window.isOnActiveSpace else { return }
    let id = CGWindowID(window.windowNumber)
    guard !inFlight.contains(id) else { return }

    // Everything below is read synchronously, before any await.
    let plannedEpoch = epoch
    let plannedFrame = window.frame
    let planned = registry.regions(in: window)
    guard !planned.isEmpty else { return }
    let screenHeight = NSScreen.screens.first?.frame.height ?? window.frame.maxY

    inFlight.insert(id)
    Task { @MainActor [weak self] in
      defer { self?.inFlight.remove(id) }
      guard let self else { return }
      let capture: WindowCapture?
      do {
        capture = try await self.capturer.capture(window: window, maxLongEdge: Self.maxLongEdge)
      } catch {
        return  // keep whatever was cached; a failed shot must not blank a card
      }
      guard let capture else { return }
      // The two guards that make a mislabelled card impossible rather than unlikely.
      guard self.epoch == plannedEpoch, window.frame == plannedFrame else { return }
      self.store(
        capture, regions: planned, screenHeight: screenHeight, themeGeneration: themeGeneration)
    }
  }

  private func store(
    _ capture: WindowCapture, regions: [(key: SnapshotKey, rect: CGRect)], screenHeight: CGFloat,
    themeGeneration: Int
  ) {
    for region in regions {
      guard
        let crop = SnapshotGeometry.cropRect(
          regionOnScreen: region.rect, windowContentRect: capture.contentRect,
          mainScreenHeight: screenHeight, scale: capture.scale),
        let cropped = capture.image.cropping(to: crop)
      else { continue }
      guard let thumbnail = Self.downscale(cropped) else { continue }
      cache.store(thumbnail, for: region.key, themeGeneration: themeGeneration)
    }
  }

  /// Aspect-fit down to the well's pixel size. Storing full-resolution crops would blow the cache's
  /// byte cap after a handful of panes for pictures drawn at 72×56.
  static func downscale(_ image: CGImage) -> CGImage? {
    let target = SnapshotGeometry.thumbnailPixelSize(
      source: CGSize(width: image.width, height: image.height),
      maxPointSize: SwitcherRailLayout.wellSize, scale: 2)
    guard target.width >= 1, target.height >= 1 else { return nil }
    guard Int(target.width) < image.width || Int(target.height) < image.height else { return image }
    guard
      let context = CGContext(
        data: nil, width: Int(target.width), height: Int(target.height), bitsPerComponent: 8,
        bytesPerRow: 0, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(origin: .zero, size: target))
    return context.makeImage()
  }
}
