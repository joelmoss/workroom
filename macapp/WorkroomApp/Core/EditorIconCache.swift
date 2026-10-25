import AppKit
import Observation
import os

/// Pane images contain only pixels prepared off main, never a deferred Finder-icon draw.
/// Requests are shared across panes; unrelated application activity leaves ready icons intact.
@MainActor @Observable
final class EditorIconCache {
  static let shared = EditorIconCache()

  private var images: [URL: NSImage] = [:]
  @ObservationIgnored private var requests: [URL: Task<Void, Never>] = [:]
  private let render: @Sendable (URL) async -> CGImage?

  init(
    render: @escaping @Sendable (URL) async -> CGImage? = {
      await EditorIconCache.rasterize(at: $0)
    }
  ) {
    self.render = render
  }

  func image(for url: URL) -> NSImage? {
    if let image = images[url] { return image }
    guard requests[url] == nil else { return nil }
    requests[url] = Task {
      let bitmap = await render(url)
      guard !Task.isCancelled else { return }
      if let bitmap {
        images[url] = NSImage(cgImage: bitmap, size: NSSize(width: 20, height: 20))
      }
      // Keep the completed request too: a failed load should not retry on every body evaluation.
    }
    return nil
  }

  func invalidate(_ url: URL) {
    guard let request = requests.removeValue(forKey: url) else { return }
    request.cancel()
    // Also notify a leaf displaying the placeholder after a failed or still-pending request.
    images.removeValue(forKey: url)
  }

  /// NSWorkspace supports this call on any thread. Drawing stays in the worker; only an immutable
  /// CGImage crosses back to main. Never resize or otherwise mutate NSWorkspace's shared image.
  @concurrent static func rasterize(at url: URL) async -> CGImage? {
    let signposter = OSSignposter(
      subsystem: "com.developwithstyle.workroom", category: "EditorIcon")
    let interval = signposter.beginInterval("Prepare editor icon")
    defer { signposter.endInterval("Prepare editor icon", interval) }
    return autoreleasepool {
      guard let source = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage else {
        return nil
      }
      guard
        let context = CGContext(
          data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return nil }
      context.scaleBy(x: 2, y: 2)
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      source.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20))
      return context.makeImage()
    }
  }
}
