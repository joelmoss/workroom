import AppKit
import Darwin
import DesignSystem
import SwiftUI
import WebKit
import XCTest

@testable import Workroom

/// Times the Markdown preview end to end on the real `MarkdownWebView`, hosted in a visible window
/// the way a pane hosts it: fresh opens (view created → `onFirstRender`, i.e. painted), re-renders of
/// a loaded page, mermaid diagrams, a theme switch with diagrams on screen, and WebContent memory.
///
/// A benchmark, not a test: it skips unless `WORKROOM_BENCH=1` reaches the test process, which
/// `make app-bench-markdown` arranges, and it asserts only what keeps its numbers honest. Run it
/// before and after a preview change and compare the JSON it writes. The fixtures are generated, not
/// read from the repo's docs, so two runs months apart time the same input.
///
/// It differs from a real pane only by `PlainFileViewer`'s loader overlay and the pane's layout.
@MainActor
final class MarkdownPreviewBenchmarkTests: XCTestCase {

  private static let environment = ProcessInfo.processInfo.environment
  private static let samples = 7

  private var window: NSWindow!
  private var report: [String: Any] = [:]
  private var lines: [String] = []

  override func setUp() async throws {
    try await super.setUp()
    try XCTSkipUnless(
      Self.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run it with `make app-bench-markdown`")
    // On screen and in front: WebKit runs no animation frames for a view it isn't displaying, and
    // `onFirstRender` then waits out its 250 ms fallback instead of a paint.
    window = NSWindow(
      contentRect: NSRect(x: 40, y: 40, width: 900, height: 700),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "Markdown preview benchmark"
    window.isReleasedWhenClosed = false
    window.orderFrontRegardless()
  }

  override func tearDown() async throws {
    window?.contentView = nil
    window?.close()
    window = nil
    try await super.tearDown()
  }

  // Value: protects=a comparable before/after timing of the preview; fails_when=the window isn't
  // displayed (timer, not paint), a render stops short, or diagrams never draw; why_new=no
  // end-to-end preview timing existed; seam=none; no_claim=any speed threshold.
  func testMarkdownPreviewTimings() async throws {
    let (light, dark) = try lightAndDarkTokens()
    let docs: [(name: String, source: String)] = [
      ("small", Self.document(bytes: 2_000)),
      ("mid", Self.document(bytes: 60_000)),
      ("large", Self.document(bytes: 370_000)),
    ]

    // The first preview in this process: whatever WebContent spawn and template load the app hasn't
    // done ahead of it at launch is paid here. Measured once, before any other preview opens.
    // Nobody opens a preview the instant the app starts, and right after launch the host's own
    // start-up work inflates the first open: 192 ms at once, 107 ms after 0.5 s, 130 ms after 2 s
    // (measured 2026-10-21). So the first open waits as a user would.
    try await Task.sleep(for: .seconds(2))
    let cold = try await open(docs[0].source, tokens: light)
    record("first open in process (2 s after start)", "small", [cold.elapsed])
    try await assertPaints(cold.webView)

    // How previews are usually opened: a while after the last one, with the ready page sat idle.
    let idle = Double(Self.environment["WORKROOM_BENCH_IDLE_S"] ?? "2")!
    var idleOpens: [Double] = []
    for _ in 0..<5 {
      try await Task.sleep(for: .seconds(idle))
      idleOpens.append(try await open(docs[0].source, tokens: light).elapsed)
    }
    record("open after \(idle) s idle", "small", idleOpens)

    for doc in docs {
      var opens: [Double] = []
      var wholes: [Double] = []
      var webView: WKWebView!
      for _ in 0..<Self.samples {
        let opened = try await open(doc.source, tokens: light)
        opens.append(opened.elapsed)
        // A long document paints its first screens before the rest is in the page.
        // (`__renderComplete` is undefined before progressive rendering, and awaits as done.)
        let rest = ContinuousClock.now
        _ = try await opened.webView.callAsyncJavaScript(
          "await window.__renderComplete; return 0", arguments: [:], contentWorld: .page)
        wholes.append(opened.elapsed + Self.milliseconds(since: rest))
        webView = opened.webView
      }
      try await assertRenderedWhole(webView, doc.source)
      record("open (preview created → painted)", doc.name, opens)
      record("open → whole document in page", doc.name, wholes)
      // Before the renders below pile more into the same page: what one open costs.
      memory(webView, label: doc.name)

      // A loaded page given new source, as when the file changes on disk: the production
      // `__render` plus the same double animation frame the coordinator waits on.
      var rerenders: [Double] = []
      for i in 0..<Self.samples {
        let start = ContinuousClock.now
        let how = try await webView.callAsyncJavaScript(
          """
          window.__render(source);
          return await new Promise((resolve) => {
            requestAnimationFrame(() => requestAnimationFrame(() => resolve("raf")));
            setTimeout(() => resolve("timeout"), 1000);
          });
          """, arguments: ["source": doc.source + "\n\nEdit \(i).\n"], contentWorld: .page)
        rerenders.append(Self.milliseconds(since: start))
        XCTAssertEqual(how as? String, "raf", "re-render timed on the fallback, not a paint")
      }
      record("re-render (loaded web view)", doc.name, rerenders)

      // How much of a render is parsing and sanitizing, timed inside the page: the most a faster
      // parser could save. WebKit coarsens `performance.now()` to about a millisecond.
      var parses: [Double] = []
      var sanitizes: [Double] = []
      for _ in 0..<Self.samples {
        let parts = try await webView.callAsyncJavaScript(
          """
          const a = performance.now();
          const html = marked.parse(source);
          const b = performance.now();
          DOMPurify.sanitize(html, { USE_PROFILES: { html: true }, ADD_TAGS: ["input"], ADD_ATTR: ["target"] });
          return [b - a, performance.now() - b];
          """, arguments: ["source": doc.source], contentWorld: .page)
        let times = try XCTUnwrap(parts as? [Double])
        parses.append(times[0])
        sanitizes.append(times[1])
      }
      record("marked.parse, in page", doc.name, parses)
      record("DOMPurify.sanitize, in page", doc.name, sanitizes)
    }

    // Diagrams render after the first paint, so the clock runs until every one is an <svg>.
    let diagrams = Self.mermaidDocument
    var mermaidOpens: [Double] = []
    var themeSwitches: [Double] = []
    var lastView: WKWebView!
    for _ in 0..<Self.samples {
      let start = ContinuousClock.now
      let opened = try await open(diagrams.source, tokens: light)
      try await waitForDiagrams(opened.webView, count: diagrams.count)
      mermaidOpens.append(Self.milliseconds(since: start))

      // Done when the page has the new theme, every diagram is on screen (an engine that bakes
      // colours into its SVG has redrawn them all) and that frame has painted.
      let before = try await opened.webView.evaluateJavaScript(
        "getComputedStyle(document.documentElement).getPropertyValue('--bg')")
      let switchStart = ContinuousClock.now
      opened.host.rootView = MarkdownWebView(
        markdown: diagrams.source, tokens: dark, generation: 1, onFirstRender: {})
      let switched = try await opened.webView.callAsyncJavaScript(
        """
        const ready = () =>
          getComputedStyle(document.documentElement).getPropertyValue('--bg') !== before &&
          document.querySelectorAll('pre.mermaid svg').length === count;
        const deadline = performance.now() + 20000;
        while (!ready()) {
          if (performance.now() > deadline) return false;
          await new Promise((resolve) => requestAnimationFrame(resolve));
        }
        await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        return true;
        """, arguments: ["before": before as? String ?? "", "count": diagrams.count],
        contentWorld: .page)
      XCTAssertEqual(switched as? Bool, true, "the theme switch never landed")
      themeSwitches.append(Self.milliseconds(since: switchStart))
      lastView = opened.webView
    }
    record("open with \(diagrams.count) mermaid diagrams → all drawn", "mermaid", mermaidOpens)
    record("theme switch → painted with \(diagrams.count) diagrams", "mermaid", themeSwitches)
    memory(lastView, label: "mermaid")

    // Whether separate previews share a WebContent process: what a pool of warm views would save.
    var hosts: [NSHostingView<MarkdownWebView>] = []
    var pids: [Int32] = []
    for _ in 0..<3 {
      let opened = try await open(docs[0].source, tokens: light, keep: &hosts)
      if let pid = Self.webProcessIdentifier(opened.webView) { pids.append(pid) }
    }
    report["concurrent_views_distinct_webcontent_pids"] = Set(pids).count
    lines.append("3 previews open at once → \(Set(pids).count) WebContent process(es)")
    hosts.removeAll()

    // What keeping a booted page ready costs while no preview is open.
    if let spare = MarkdownWebViewPool.shared.spare {
      memory(spare, label: "idle pooled page")
    }

    try writeReport()
  }

  // MARK: - Driving the view

  private struct Opened {
    let elapsed: Double
    let webView: WKWebView
    let host: NSHostingView<MarkdownWebView>
  }

  private func open(_ markdown: String, tokens: ThemeTokens) async throws -> Opened {
    var discard: [NSHostingView<MarkdownWebView>] = []
    return try await open(markdown, tokens: tokens, keep: &discard)
  }

  /// Puts a fresh preview in the window and waits for its first paint. With `keep`, earlier
  /// previews stay alive beside it (stacked, so each is still displayed) instead of being replaced.
  private func open(
    _ markdown: String, tokens: ThemeTokens, keep: inout [NSHostingView<MarkdownWebView>]
  ) async throws -> Opened {
    var painted: CheckedContinuation<Void, Never>?
    var didPaint = false
    let start = ContinuousClock.now
    let host = NSHostingView(
      rootView: MarkdownWebView(
        markdown: markdown, tokens: tokens, generation: 0,
        onFirstRender: {
          didPaint = true
          painted?.resume()
          painted = nil
        }))
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    keep.append(host)
    let height = 700 / CGFloat(keep.count)
    for (i, view) in keep.enumerated() {
      view.frame = NSRect(x: 0, y: CGFloat(i) * height, width: 900, height: height)
      container.addSubview(view)
    }
    window.contentView = container
    await withCheckedContinuation { continuation in
      if didPaint { continuation.resume() } else { painted = continuation }
    }
    let elapsed = Self.milliseconds(since: start)
    let webView = try XCTUnwrap(Self.webView(in: host), "no WKWebView under the preview")
    return Opened(elapsed: elapsed, webView: webView, host: host)
  }

  /// Fails the run if the window isn't really being displayed: then every "painted" time is the
  /// coordinator's 250 ms fallback and the whole report measures a timer.
  private func assertPaints(_ webView: WKWebView) async throws {
    let how = try await webView.callAsyncJavaScript(
      """
      return await new Promise((resolve) => {
        requestAnimationFrame(() => requestAnimationFrame(() => resolve("raf")));
        setTimeout(() => resolve("timeout"), 1000);
      });
      """, arguments: [:], contentWorld: .page)
    XCTAssertEqual(how as? String, "raf", "the benchmark window is not being displayed")
  }

  /// The last section reached the page, so a time is for the whole document, not a truncated one.
  private func assertRenderedWhole(_ webView: WKWebView, _ source: String) async throws {
    let lastHeading = try XCTUnwrap(
      source.components(separatedBy: "\n").last { $0.hasPrefix("## ") }?.dropFirst(3))
    let text = try await webView.evaluateJavaScript(
      "document.getElementById('content').textContent")
    XCTAssertTrue((text as? String)?.contains(lastHeading) == true, "render stopped short")
  }

  private func waitForDiagrams(_ webView: WKWebView, count: Int) async throws {
    let done = try await webView.callAsyncJavaScript(
      """
      const ready = () => document.querySelectorAll('pre.mermaid svg').length === count;
      const deadline = performance.now() + 20000;
      while (!ready()) {
        if (performance.now() > deadline) return false;
        await new Promise((resolve) => requestAnimationFrame(resolve));
      }
      return true;
      """, arguments: ["count": count], contentWorld: .page)
    XCTAssertEqual(done as? Bool, true, "mermaid diagrams never all rendered")
  }

  private static func webView(in view: NSView) -> WKWebView? {
    if let web = view as? WKWebView { return web }
    for child in view.subviews {
      if let web = webView(in: child) { return web }
    }
    return nil
  }

  // MARK: - Memory

  /// The WebContent process behind `webView`, through WebKit's private accessor; nil if it's gone.
  private static func webProcessIdentifier(_ webView: WKWebView) -> Int32? {
    let selector = NSSelectorFromString("_webProcessIdentifier")
    guard webView.responds(to: selector) else { return nil }
    return (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value
  }

  private func memory(_ webView: WKWebView, label: String) {
    guard let pid = Self.webProcessIdentifier(webView) else {
      lines.append("memory \(label): n/a (no WebContent pid)")
      return
    }
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
      }
    }
    guard status == 0 else {
      lines.append("memory \(label): n/a (proc_pid_rusage \(status))")
      return
    }
    let megabytes = Double(info.ri_phys_footprint) / 1_048_576
    var memory = report["webcontent_footprint_mb"] as? [String: Double] ?? [:]
    memory[label] = (megabytes * 10).rounded() / 10
    report["webcontent_footprint_mb"] = memory
    lines.append(String(format: "WebContent footprint after %@: %.1f MB", label, megabytes))
  }

  // MARK: - Report

  private func record(_ measure: String, _ doc: String, _ values: [Double]) {
    let sorted = values.sorted()
    let median = sorted[sorted.count / 2]
    var timings = report["timings_ms"] as? [[String: Any]] ?? []
    timings.append([
      "measure": measure, "doc": doc, "median": Self.round(median),
      "min": Self.round(sorted.first!), "max": Self.round(sorted.last!),
      "samples": values.map(Self.round),
    ])
    report["timings_ms"] = timings
    lines.append(
      String(
        format: "%@ [%@]: median %.1f ms (min %.1f, max %.1f, n=%d)", measure, doc, median,
        sorted.first!, sorted.last!, values.count))
  }

  private func writeReport() throws {
    report["date"] = ISO8601DateFormatter().string(from: Date())
    report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
    report["machine"] = Self.sysctl("hw.model")
    report["configuration"] = "Debug"
    let url: URL
    if let path = Self.environment["WORKROOM_BENCH_OUT"], !path.isEmpty {
      url = URL(fileURLWithPath: path)
    } else {
      // macapp/DerivedData/Benchmarks: git-ignored, and found again next to the build.
      let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(
        of: ":", with: "")
      url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("DerivedData/Benchmarks/markdown-preview-\(stamp).json")
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url)
    print((["Markdown preview benchmark"] + lines + ["JSON: \(url.path)"]).joined(separator: "\n"))
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let elapsed = ContinuousClock.now - start
    return Double(elapsed.components.seconds) * 1000
      + Double(elapsed.components.attoseconds) / 1e15
  }

  private static func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }

  private static func sysctl(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "unknown" }
    return String(cString: bytes)
  }

  // MARK: - Fixtures

  private func lightAndDarkTokens() throws -> (ThemeTokens, ThemeTokens) {
    let tokens = try bundledThemes().map { ThemeTokens(preview: $0) }
    let light = try XCTUnwrap(tokens.first { $0.colorScheme == .light }, "no light bundled theme")
    let dark = try XCTUnwrap(tokens.first { $0.colorScheme == .dark }, "no dark bundled theme")
    return (light, dark)
  }

  /// Representative GFM, repeated to `bytes`: headings, prose with inline marks and links, lists,
  /// task items, a table, a fenced code block, a quote and a raw `<details>`.
  static func document(bytes: Int) -> String {
    var out = "# Benchmark document\n\nGenerated fixture for the Markdown preview benchmark.\n\n"
    var section = 0
    while out.utf8.count < bytes {
      section += 1
      out += """
        ## Section \(section): remote workrooms

        A paragraph with **bold**, *italic*, `inline code`, ~~struck~~ text and a \
        [link to section \(section)](https://example.com/docs/\(section)). The agent owns the \
        session, the app attaches over ssh, and a dropped connection reattaches after wake.

        - First item with `code`
        - Second item with a [link](https://example.com/\(section))
          - Nested item
        - [ ] An open task
        - [x] A finished task

        | Host | State | Latency |
        | --- | --- | ---: |
        | local | running | 1 ms |
        | boxd-\(section) | sleeping | 48 ms |
        | exe.dev | creating | 120 ms |

        ```swift
        func reattach(_ session: Session) async throws {
          let host = try await driver.resolve(session.host)
          for attempt in 1...3 {
            if try await host.ping() { return try await host.attach(session) }
            try await Task.sleep(for: .seconds(attempt))
          }
        }
        ```

        > A quoted note about section \(section), with **emphasis**.

        <details><summary>More about section \(section)</summary>

        Hidden detail text.

        </details>


        """
    }
    return out
  }

  static let mermaidDocument: (source: String, count: Int) = (
    """
    # Diagrams

    ```mermaid
    flowchart TD
      Open([Open file]) --> IsMd{Markdown?}
      IsMd -- yes --> Parse[Parse] --> Sanitize[Sanitize] --> Paint[Paint]
      IsMd -- no --> Plain[Plain text]
      subgraph Remote
        Agent[workroomd] --> Pty[(pty)]
      end
      Paint -.-> Agent
    ```

    ```mermaid
    sequenceDiagram
      participant App
      participant Agent as workroomd
      participant Host as Remote host
      App->>Agent: attach(session)
      Agent->>Host: ssh
      Host-->>Agent: pty ready
      alt session gone
        Agent-->>App: gone
      else alive
        Agent-->>App: stream bytes
      end
    ```

    ```mermaid
    classDiagram
      class AppStore {
        +projects: [Project]
        +select(id)
      }
      class Project {
        +name: String
      }
      AppStore "1" --> "*" Project
      Project "1" *-- "*" Workroom
      Host <|-- LocalHost
      Host <|-- RemoteHost
    ```

    """, 3
  )
}
