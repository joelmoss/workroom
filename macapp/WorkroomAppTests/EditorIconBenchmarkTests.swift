import AppKit
import SwiftUI
import XCTest

@testable import Workroom

/// Compares the former lazy icon with the production eager bitmap. Run separately from normal
/// tests: this opens transient native windows and needs the
/// installed editors' real icons. Timings include main-thread display work, not background prep.
@MainActor
final class EditorIconBenchmarkTests: XCTestCase {
  private func drawHosted(_ image: NSImage) throws -> (cpu: Double, wall: Double) {
    let hosting = NSHostingView(rootView: AnyView(Color.clear))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 160, height: 40),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderBack(nil)
    defer { window.close() }
    hosting.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    CATransaction.flush()
    let wallStart = DispatchTime.now().uptimeNanoseconds
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    hosting.rootView = AnyView(
      HStack {
        ForEach(0..<3) { _ in
          Image(nsImage: image).resizable().scaledToFit().frame(width: 18, height: 18)
        }
      }.frame(width: 160, height: 40))
    hosting.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    CATransaction.flush()
    let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    return (
      Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000,
      Double(DispatchTime.now().uptimeNanoseconds - wallStart) / 1_000_000
    )
  }

  // The exact deferred drawing path from 549df3866, retained for before/after comparisons.
  private func deferredIcon(at url: URL) -> NSImage {
    let source = NSWorkspace.shared.icon(forFile: url.path)
    return NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
      source.draw(in: rect)
      return true
    }
  }

  private func draw(_ image: NSImage) throws {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: 2, y: 2)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: 20, height: 20))
    XCTAssertNotNil(context.makeImage())
  }

  func testEditorIconFirstDraw() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run make app-bench-editor-icon")
    var results: [[String: Any]] = []
    let preparedFirst =
      ProcessInfo.processInfo.environment["WORKROOM_EDITOR_ICON_PREPARED_FIRST"] == "1"
    let editors = ExternalEditor.installed
    XCTAssertFalse(editors.isEmpty, "install a supported editor before measuring its real icon")
    for editor in editors {
      var requestCPU: [Double] = []
      var firstDrawCPU: [Double] = []
      var repeatDrawCPU: [Double] = []
      var deferredRepresentations: [Int] = []
      var hostedCPU: [Double] = []
      var preparedHostedCPU: [Double] = []
      var requestWall: [Double] = []
      var firstDrawWall: [Double] = []
      var hostedWall: [Double] = []
      var preparedHostedWall: [Double] = []
      for _ in 0..<3 {
        var preparedImage: CGImage?
        if preparedFirst {
          preparedImage = await EditorIconCache.rasterize(at: editor.appURL)
          let prepared = try XCTUnwrap(preparedImage)
          let display = try drawHosted(
            NSImage(cgImage: prepared, size: NSSize(width: 20, height: 20)))
          preparedHostedCPU.append(display.cpu)
          preparedHostedWall.append(display.wall)
        }
        // Each sample bypasses Workroom's old wrapper cache, retaining the real NSWorkspace cache.
        let requestWallStart = DispatchTime.now().uptimeNanoseconds
        let requestStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let image = deferredIcon(at: editor.appURL)
        requestCPU.append(
          Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - requestStart) / 1_000_000)
        requestWall.append(
          Double(DispatchTime.now().uptimeNanoseconds - requestWallStart) / 1_000_000)
        XCTAssertEqual(image.size, NSSize(width: 20, height: 20))
        deferredRepresentations.append(
          image.representations.filter { $0 is NSCustomImageRep }.count)
        let firstWallStart = DispatchTime.now().uptimeNanoseconds
        let firstStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        try draw(image)
        firstDrawCPU.append(
          Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - firstStart) / 1_000_000)
        firstDrawWall.append(
          Double(DispatchTime.now().uptimeNanoseconds - firstWallStart) / 1_000_000)
        let repeatStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for _ in 0..<2 { try draw(image) }
        repeatDrawCPU.append(
          Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - repeatStart) / 1_000_000)
        let existingDisplay = try drawHosted(deferredIcon(at: editor.appURL))
        hostedCPU.append(existingDisplay.cpu)
        hostedWall.append(existingDisplay.wall)
        if !preparedFirst { preparedImage = await EditorIconCache.rasterize(at: editor.appURL) }
        let prepared = try XCTUnwrap(preparedImage)
        XCTAssertEqual(prepared.width, 40)
        XCTAssertEqual(prepared.height, 40)
        if !preparedFirst {
          let display = try drawHosted(
            NSImage(cgImage: prepared, size: NSSize(width: 20, height: 20)))
          preparedHostedCPU.append(display.cpu)
          preparedHostedWall.append(display.wall)
        }
      }
      results.append([
        "editor": editor.name, "request_cpu_ms": requestCPU,
        "first_draw_cpu_ms": firstDrawCPU, "two_more_panes_cpu_ms": repeatDrawCPU,
        "deferred_representations": deferredRepresentations,
        "three_hosted_panes_cpu_ms": hostedCPU,
        "prepared_three_hosted_panes_cpu_ms": preparedHostedCPU,
        "request_wall_ms": requestWall, "first_draw_wall_ms": firstDrawWall,
        "three_hosted_panes_wall_ms": hostedWall,
        "prepared_three_hosted_panes_wall_ms": preparedHostedWall,
      ])
    }
    try BenchmarkFixtures.write(
      ["configuration": "Debug", "prepared_first": preparedFirst, "editors": results],
      to: BenchmarkFixtures.reportURL(named: "editor-icon"))
  }

}
