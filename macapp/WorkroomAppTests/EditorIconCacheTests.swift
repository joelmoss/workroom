import AppKit
import XCTest

@testable import Workroom

@MainActor
final class EditorIconCacheTests: XCTestCase {
  private actor Renderer {
    private var continuations: [CheckedContinuation<CGImage?, Never>] = []
    private let started: XCTestExpectation
    private(set) var calls = 0

    init(started: XCTestExpectation) { self.started = started }

    func render(_ url: URL) async -> CGImage? {
      calls += 1
      return await withCheckedContinuation { continuation in
        continuations.append(continuation)
        if calls == 1 { started.fulfill() }
      }
    }

    func complete(_ image: CGImage?) { continuations.removeFirst().resume(returning: image) }
  }

  private let url = URL(fileURLWithPath: "/editor-icon-test/Editor.app")

  private func bitmap() throws -> CGImage {
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
    return try XCTUnwrap(context.makeImage())
  }

  private func readyImage(_ cache: EditorIconCache, at url: URL) async throws -> NSImage {
    for _ in 0..<200 {
      if let image = cache.image(for: url) { return image }
      try await Task.sleep(for: .milliseconds(5))
    }
    return try XCTUnwrap(cache.image(for: url), "prepared pixels must be published to the pane")
  }

  func testConcurrentPanesShareOneRequestAndReadyBitmap() async throws {
    let started = expectation(description: "one shared render")
    started.assertForOverFulfill = true
    let renderer = Renderer(started: started)
    let cache = EditorIconCache(render: { await renderer.render($0) })
    for _ in 0..<3 { XCTAssertNil(cache.image(for: url)) }
    await fulfillment(of: [started], timeout: 2)
    await renderer.complete(try bitmap())
    let image = try await readyImage(cache, at: url)
    XCTAssertEqual(image.size, NSSize(width: 20, height: 20))
    XCTAssertTrue(image === cache.image(for: url))
    XCTAssertFalse(image.representations.contains { $0 is NSCustomImageRep })
    let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertEqual(pixels.width, 40)
    XCTAssertEqual(pixels.height, 40)
    let color = try XCTUnwrap(NSBitmapImageRep(cgImage: pixels).colorAt(x: 20, y: 20))
    // CoreGraphics may convert the fixture's sRGB color to the device RGB profile.
    XCTAssertGreaterThan(color.blueComponent, color.redComponent)
    XCTAssertGreaterThan(color.blueComponent, color.greenComponent)
    XCTAssertGreaterThan(color.alphaComponent, 0.9)
    let calls = await renderer.calls
    XCTAssertEqual(calls, 1)
  }

  func testOnlyTheChangedApplicationInvalidatesItsIcon() async throws {
    let started = expectation(description: "render")
    let renderer = Renderer(started: started)
    let cache = EditorIconCache(render: { await renderer.render($0) })
    XCTAssertNil(cache.image(for: url))
    await fulfillment(of: [started], timeout: 2)
    await renderer.complete(try bitmap())
    let image = try await readyImage(cache, at: url)
    cache.invalidate(URL(fileURLWithPath: "/unrelated-app.app"))
    XCTAssertTrue(image === cache.image(for: url))
    cache.invalidate(url)
    XCTAssertNil(cache.image(for: url))
    // Wait for the next request before releasing its controlled renderer.
    for _ in 0..<200 {
      if await renderer.calls == 2 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let calls = await renderer.calls
    guard calls == 2 else {
      XCTFail("only the changed editor should start a replacement request; got \(calls)")
      return
    }
    await renderer.complete(try bitmap())
    let replacement = try await readyImage(cache, at: url)
    XCTAssertFalse(image === replacement)
  }

  func testProductionPreparationProducesOnlyBitmapRepresentations() async throws {
    let pixels = await EditorIconCache.rasterize(at: Bundle.main.bundleURL)
    let image = NSImage(cgImage: try XCTUnwrap(pixels), size: NSSize(width: 20, height: 20))
    XCTAssertFalse(image.representations.contains { $0 is NSCustomImageRep })
    let displayed = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    XCTAssertEqual(displayed.width, 40)
    XCTAssertEqual(displayed.height, 40)
    XCTAssertNotNil(displayed.dataProvider?.data)
  }
}
