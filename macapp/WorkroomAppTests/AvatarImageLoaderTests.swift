import AppKit
import XCTest

@testable import Workroom

/// `AvatarImageLoader` (WORKROOM-2B follow-up — the status-aware replacement for `AsyncImage`, see
/// TODOS.md): reads the real HTTP status, so a genuine 404 ("no avatar for this address") and a
/// transient failure ("the network dropped") are distinguishable — only the former is cached — and
/// decoded images are cached too. A `URLProtocol` stub means no real network for any of this, exactly
/// the testability gap `AsyncImage` couldn't offer.
final class AvatarImageLoaderTests: XCTestCase {

  /// Thread-safe canned-response registry `StubURLProtocol` reads from — `startLoading()` runs on a
  /// background queue URLSession owns, not the test's own thread.
  private final class StubRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: (status: Int, data: Data)] = [:]
    private var errorURLs: Set<URL> = []
    private var callCounts: [URL: Int] = [:]

    func setResponse(status: Int, data: Data, for url: URL) {
      lock.lock()
      responses[url] = (status, data)
      lock.unlock()
    }
    func setError(for url: URL) {
      lock.lock()
      errorURLs.insert(url)
      lock.unlock()
    }
    func clearError(for url: URL) {
      lock.lock()
      errorURLs.remove(url)
      lock.unlock()
    }
    func recordCall(_ url: URL) {
      lock.lock()
      callCounts[url, default: 0] += 1
      lock.unlock()
    }
    func callCount(for url: URL) -> Int {
      lock.lock()
      defer { lock.unlock() }
      return callCounts[url] ?? 0
    }
    func response(for url: URL) -> (status: Int, data: Data)? {
      lock.lock()
      defer { lock.unlock() }
      return responses[url]
    }
    func hasError(for url: URL) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return errorURLs.contains(url)
    }
  }

  private final class StubURLProtocol: URLProtocol {
    static let registry = StubRegistry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      guard let url = request.url else { return }
      Self.registry.recordCall(url)
      if Self.registry.hasError(for: url) {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        return
      }
      guard let (status, data) = Self.registry.response(for: url) else {
        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
        return
      }
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
  }

  private func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
  }

  private func pngData(_ color: NSColor) throws -> Data {
    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.lockFocus()
    color.setFill()
    NSRect(x: 0, y: 0, width: 4, height: 4).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else {
      throw NSError(domain: "AvatarImageLoaderTests", code: 1)
    }
    return png
  }

  @MainActor
  func testSuccessfulLoadDecodesAndCachesTheImage() async throws {
    let url = URL(string: "https://example.com/a.png")!
    StubURLProtocol.registry.setResponse(status: 200, data: try pngData(.red), for: url)
    let loader = AvatarImageLoader(session: makeSession())

    let first = await loader.load(url)
    guard case .image = first else {
      return XCTFail("expected .image, got \(String(describing: first))")
    }

    _ = await loader.load(url)
    XCTAssertEqual(
      StubURLProtocol.registry.callCount(for: url), 1, "a cached image must not re-request")
  }

  @MainActor
  func testGenuine404IsCachedAsNotFound() async throws {
    let url = URL(string: "https://example.com/missing.png")!
    StubURLProtocol.registry.setResponse(status: 404, data: Data(), for: url)
    let loader = AvatarImageLoader(session: makeSession())

    let first = await loader.load(url)
    XCTAssertEqual(first, .notFound)

    _ = await loader.load(url)
    XCTAssertEqual(
      StubURLProtocol.registry.callCount(for: url), 1, "a cached 404 must not re-request")
  }

  @MainActor
  func testTransientNetworkErrorIsNeverCachedAndRetries() async throws {
    let url = URL(string: "https://example.com/flaky.png")!
    StubURLProtocol.registry.setError(for: url)
    let loader = AvatarImageLoader(session: makeSession())

    let first = await loader.load(url)
    XCTAssertNil(first, "a network error must read as transient (nil), never a cached failure")

    // Fix the network: since nothing was cached, the retry must reach the stub again and succeed.
    StubURLProtocol.registry.clearError(for: url)
    StubURLProtocol.registry.setResponse(status: 200, data: try pngData(.blue), for: url)
    let second = await loader.load(url)
    guard case .image = second else { return XCTFail("expected the retry to succeed") }
    XCTAssertEqual(
      StubURLProtocol.registry.callCount(for: url), 2, "a transient failure must be retried")
  }

  @MainActor
  func testNonStandardStatusIsTransientNotCached() async throws {
    let url = URL(string: "https://example.com/ratelimited.png")!
    StubURLProtocol.registry.setResponse(status: 429, data: Data(), for: url)
    let loader = AvatarImageLoader(session: makeSession())

    let result = await loader.load(url)
    XCTAssertNil(result, "a non-200/404 status must read as transient, not a cached failure")
  }

  @MainActor
  func testUndecodableSuccessBodyIsTransientNotCached() async throws {
    let url = URL(string: "https://example.com/corrupt.png")!
    StubURLProtocol.registry.setResponse(status: 200, data: Data([0x00, 0x01, 0x02]), for: url)
    let loader = AvatarImageLoader(session: makeSession())

    let result = await loader.load(url)
    XCTAssertNil(result, "a 200 with an undecodable body must read as transient, not `.notFound`")
  }

  @MainActor
  func testConcurrentLoadsForTheSameURLShareOneRequest() async throws {
    let url = URL(string: "https://example.com/shared.png")!
    StubURLProtocol.registry.setResponse(status: 200, data: try pngData(.green), for: url)
    let loader = AvatarImageLoader(session: makeSession())

    async let a = loader.load(url)
    async let b = loader.load(url)
    let (first, second) = await (a, b)
    guard case .image = first, case .image = second else {
      return XCTFail("both concurrent loads should succeed")
    }
    XCTAssertEqual(
      StubURLProtocol.registry.callCount(for: url), 1,
      "concurrent loads for one URL must share one request")
  }

  @MainActor
  func testCacheEvictsOldestPastCapacity() async throws {
    let loader = AvatarImageLoader(session: makeSession(), capacity: 2)
    let urls = (0..<3).map { URL(string: "https://example.com/\($0).png")! }
    for url in urls {
      StubURLProtocol.registry.setResponse(status: 200, data: try pngData(.red), for: url)
      _ = await loader.load(url)
    }

    // The oldest (urls[0]) should have been evicted past a capacity of 2; loading it again must
    // re-hit the network rather than serve the (evicted) cache entry.
    _ = await loader.load(urls[0])
    XCTAssertEqual(
      StubURLProtocol.registry.callCount(for: urls[0]), 2,
      "the oldest entry should have been evicted past capacity")
  }
}
