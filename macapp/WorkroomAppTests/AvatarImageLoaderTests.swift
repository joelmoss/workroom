import AppKit
import CryptoKit
import SwiftUI
import XCTest

@testable import Workroom

/// `AvatarImageLoader` (WORKROOM-2B follow-up — the status-aware replacement for `AsyncImage`, see
/// TODOS.md): reads the real HTTP status, so a genuine 404 ("no avatar for this address") and a
/// transient failure ("the network dropped") are distinguishable — only the former is cached — and
/// decoded images are cached too. A `URLProtocol` stub means no real network for any of this, exactly
/// the testability gap `AsyncImage` couldn't offer.
final class AvatarImageLoaderTests: XCTestCase {

  override func setUp() {
    super.setUp()
    StubURLProtocol.registry.reset()
  }

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

    // MARK: gating — hold a response until the test releases it, for staleness tests that need to
    // control exactly when an in-flight fetch resolves relative to a `taskKey` change.
    private var gates: [URL: DispatchSemaphore] = [:]
    func gate(_ url: URL) {
      lock.lock()
      gates[url] = DispatchSemaphore(value: 0)
      lock.unlock()
    }
    func release(_ url: URL) {
      lock.lock()
      let sem = gates.removeValue(forKey: url)
      lock.unlock()
      sem?.signal()
    }
    fileprivate func gateSemaphore(for url: URL) -> DispatchSemaphore? {
      lock.lock()
      defer { lock.unlock() }
      return gates[url]
    }

    /// `StubURLProtocol.registry` is a process-wide `static let`, shared across every test in this
    /// class with no teardown of its own — a stale response/gate left by an earlier test would
    /// otherwise silently leak into a later one. Called from `setUp()`.
    func reset() {
      lock.lock()
      responses.removeAll()
      errorURLs.removeAll()
      callCounts.removeAll()
      gates.removeAll()
      lock.unlock()
    }
  }

  private final class StubURLProtocol: URLProtocol {
    static let registry = StubRegistry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      guard let url = request.url else { return }
      Self.registry.recordCall(url)
      // Off the calling thread: a gated URL's `sem.wait()` must not block whatever thread
      // URLSession itself needs to keep making progress.
      DispatchQueue.global().async {
        Self.registry.gateSemaphore(for: url)?.wait()
        if Self.registry.hasError(for: url) {
          self.client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
          return
        }
        guard let (status, data) = Self.registry.response(for: url) else {
          self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
          return
        }
        let response = HTTPURLResponse(
          url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
      }
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

  // MARK: - AvatarView staleness (a real `.task(id:)` cancellation, not just the loader)

  /// Drives `AvatarSubject.hexString` (the same building block `gravatar(email:)` uses internally)
  /// to reconstruct the exact Gravatar URL a `VCSAuthor` will resolve to, so the stub can be keyed on
  /// it without a network call ever needing to compute a real one.
  private func gravatarURL(email: String, pixelSize: Int = 16) -> URL {
    let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let hash = AvatarSubject.hexString(Insecure.MD5.hash(data: Data(normalized.utf8)))
    return URL(string: "https://www.gravatar.com/avatar/\(hash)?s=\(pixelSize)&d=404")!
  }

  /// Lets a test mutate `AvatarView`'s `subject` from outside the hosted SwiftUI tree, at a FIXED
  /// view-tree position — reproducing `AvatarStack`'s own `ForEach(..., id: \.offset)` keying, where
  /// a slot's `subject` can change without the slot's `@State` (and therefore `AvatarView`'s
  /// in-flight `.task`) being torn down and recreated fresh.
  @MainActor
  private final class SubjectController: ObservableObject {
    @Published var subject: AvatarSubject
    init(_ subject: AvatarSubject) { self.subject = subject }
  }

  private struct HostWrapper: View {
    @ObservedObject var controller: SubjectController
    let loader: AvatarImageLoader
    let onCommit: (@MainActor (AvatarImageLoader.LoadResult?) -> Void)?
    var body: some View {
      var view = AvatarView(subject: controller.subject, loader: loader)
      view.onCommit = onCommit
      return view
    }
  }

  @MainActor
  private func host(
    _ controller: SubjectController, loader: AvatarImageLoader,
    onCommit: (@MainActor (AvatarImageLoader.LoadResult?) -> Void)? = nil
  ) -> (
    NSWindow, NSView
  ) {
    let hosting = NSHostingView(
      rootView: HostWrapper(controller: controller, loader: loader, onCommit: onCommit))
    hosting.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    return (window, hosting)
  }

  /// REGRESSION: a slot showing author A raises a fetch; before it resolves, the SAME slot is
  /// reused for author B. `AvatarImageLoader.load` neither checks nor propagates cancellation (its
  /// `fetch` keeps running on an unstructured `Task` with no link back to the view's), and — measured
  /// — SwiftUI does not actually mark this `.task`'s own `Task` as cancelled for an in-place subject
  /// swap either, so a guard on `Task.isCancelled` is dead code here. If `AvatarView` ever stops
  /// gating the commit on its own generation token (`activeTaskKey`), A's stale image lands in
  /// `result` after B has already taken over the slot — the wrong person's avatar. `onCommit` is a
  /// PER-INSTANCE observation seam (not a shared static): the macOS XCTest host runs the real,
  /// fully-live app alongside this hosted view, and a shared static was measured catching commits
  /// from unrelated `AvatarView`s already on screen elsewhere in the app.
  @MainActor
  func testStaleInFlightFetchNeverOverwritesANewerSubjectInTheSameSlot() throws {
    let emailA = "author-a@example.com"
    let emailB = "author-b@example.com"
    let urlA = gravatarURL(email: emailA)
    let urlB = gravatarURL(email: emailB)
    // A resolves to `.notFound` (a 404) and B to a real image, so the race can be told apart by
    // `LoadResult` case alone — no `NSImage` equality involved (two separately-decoded `NSImage`s
    // from identical bytes are not reliably `==` via `NSImage.isEqual`).
    StubURLProtocol.registry.setResponse(status: 404, data: Data(), for: urlA)
    StubURLProtocol.registry.setResponse(status: 200, data: try pngData(.blue), for: urlB)
    StubURLProtocol.registry.gate(urlA)  // hold A's response until this test releases it

    let loader = AvatarImageLoader(session: makeSession())
    let controller = SubjectController(
      AvatarSubject(author: VCSAuthor(name: "A", email: emailA), pixelSize: 16))
    var lastCommitted: AvatarImageLoader.LoadResult?
    let (window, view) = host(controller, loader: loader) { lastCommitted = $0 }
    defer { window.close() }

    // Let A's `.task` start and actually reach the gated request (not just get scheduled).
    settle(view, until: { StubURLProtocol.registry.callCount(for: urlA) > 0 })
    XCTAssertGreaterThan(
      StubURLProtocol.registry.callCount(for: urlA), 0,
      "fixture must actually reach A's request before swapping the subject")

    // Same slot, different person — B's `.task` starts even though A's own is left running.
    controller.subject = AvatarSubject(author: VCSAuthor(name: "B", email: emailB), pixelSize: 16)
    settle(view, until: { StubURLProtocol.registry.callCount(for: urlB) > 0 })
    settle(view, until: { lastCommitted != nil })
    guard case .image = lastCommitted else {
      return XCTFail(
        "B's own fetch must land before A's stale one arrives, to set up the real race below; "
          + "got \(String(describing: lastCommitted))")
    }

    // NOW let A's held-open 404 land, well after B has already committed its own image.
    StubURLProtocol.registry.release(urlA)
    settle(view, seconds: 0.5)

    guard case .image = lastCommitted else {
      return XCTFail(
        "A's late-arriving, stale 404 must never overwrite B's already-committed image; "
          + "got \(String(describing: lastCommitted))")
    }
  }
}
