import AppKit
import Darwin
import SwiftUI
import WorkroomDomain
import XCTest

@testable import Workroom

/// Real pane tree and tab strip, with an inert surface: isolates title chrome from PTY/rendering.
@MainActor
final class TitleLayoutBenchmarkTests: XCTestCase {
  private struct Fixture {
    let store: AppStore
    let surface: GhosttySurfaceView
    let target: TerminalTarget
    let hosting: NSView
    let window: NSWindow
  }

  private func processCPU() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000
  }

  private func fixture() throws -> Fixture {
    let store = AppStore()
    store.terminals.sessionService = PersistentSessionService(
      probe: { _ in .unhealthy(reason: "no sessions in layout fixture") },
      ownership: { _ in .notOwned })
    store.terminals.makeView = { _, cwd, command in
      GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    let project = Project(path: NSTemporaryDirectory(), vcs: "git", workrooms: [])
    store.projects = [project]
    let target = try XCTUnwrap(store.target(for: .root(project: project.path)))
    let tab = store.terminals.addTab(for: target)
    let surface = try XCTUnwrap(tab.surface)
    let hosting = NSHostingView(
      rootView: WorkroomTerminalsView(target: target, sessions: store.terminals)
        .environmentObject(store)
        .environmentObject(store.notifications)
        .environmentObject(store.terminals)
        .environmentObject(store.terminals.codingAgentManager)
        .frame(width: 1_100, height: 700))
    hosting.frame = NSRect(x: 100, y: 100, width: 1_100, height: 700)
    let window = NSWindow(
      contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Title layout benchmark"
    window.contentView = hosting
    window.makeKeyAndOrderFront(nil)
    return Fixture(store: store, surface: surface, target: target, hosting: hosting, window: window)
  }

  private func chromePixels(_ fixture: Fixture) throws -> Data {
    let view = fixture.hosting
    let surface = fixture.surface.convert(fixture.surface.bounds, to: view)
    XCTAssertGreaterThan(surface.height, 0)
    let height = PaneTitleBarMetrics.height
    let y = view.isFlipped ? surface.minY - height : surface.maxY
    // Only the pane title, excluding the independently updating tab chip and trailing controls.
    let rect = NSRect(x: surface.minX, y: y, width: min(400, surface.width), height: height)
    let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: rect))
    let bytes = try XCTUnwrap(image.bitmapData)
    let count = image.bytesPerRow * image.pixelsHigh
    bytes.initialize(repeating: 0, count: count)
    view.cacheDisplay(in: rect, to: image)
    return Data(bytes: bytes, count: count)
  }

  func testTitleChangesDoNotRebuildPaneToolbar() async throws {
    let f = try fixture()
    defer {
      f.window.close()
      Task { await f.store.terminals.reapAll() }
    }
    f.surface.handleTitleChange("✳ Working")
    f.hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(200))
    let before = try chromePixels(f)
    PaneTitleBar.bodyPasses = 0
    TerminalTabStrip.bodyPasses = 0
    let frames = ["✻", "✶", "✷", "✸", "✹", "✺", "✻", "✶", "✷", "✸"]
    for frame in frames {
      f.surface.handleTitleChange("\(frame) Planning a much longer terminal task")
      try await Task.sleep(for: .milliseconds(50))
    }
    f.hosting.layoutSubtreeIfNeeded()
    // Not zero: the pane's `withTabTitle` hands SwiftUI the bar again on every title, and it
    // sometimes rebuilds what it was given, for reasons not pinned down (2 of 5 at worst seen). A
    // body that read the title would rebuild for all of them.
    XCTAssertLessThan(
      PaneTitleBar.bodyPasses, frames.count / 2, "a spinner must not rebuild the adaptive toolbar")
    XCTAssertEqual(TerminalTabStrip.bodyPasses, 0, "title widths must not update idle drag state")
    XCTAssertNotEqual(try chromePixels(f), before, "the rendered title must still update")
  }

  func testTenTitleChangesPerSecond() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run make app-bench-title")
    let duration = max(
      2, Double(ProcessInfo.processInfo.environment["WORKROOM_BENCH_SECONDS"] ?? "") ?? 60)
    let output = BenchmarkFixtures.reportURL(named: "title-layout")
    let f = try fixture()
    let (store, surface, target, hosting) = (f.store, f.surface, f.target, f.hosting)
    defer {
      f.window.close()
      Task { await store.terminals.reapAll() }
    }
    let activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiated, reason: "Measuring visible terminal title layout")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    let titles = ["✳ Working", "✻ Working", "✽ Working", "✶ Working"]
    surface.handleTitleChange(titles[0])
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .seconds(2))
    var results: [[String: Any]] = []
    for changes in [false, true] {
      let phase = changes ? "changing" : "idle"
      PaneTitleBar.bodyPasses = 0
      TerminalTabStrip.bodyPasses = 0
      try BenchmarkFixtures.write(
        ["pid": ProcessInfo.processInfo.processIdentifier, "phase": phase],
        to: output.appendingPathExtension("phase.json"))
      let wall = DispatchTime.now().uptimeNanoseconds
      let main = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      let process = processCPU()
      let start = ContinuousClock.now
      let updates = Int(duration * 10)
      for index in 0..<updates {
        if changes { surface.handleTitleChange(titles[index % titles.count]) }
        try await Task.sleep(
          until: start.advanced(by: .milliseconds((index + 1) * 100)), clock: .continuous)
      }
      hosting.layoutSubtreeIfNeeded()
      hosting.displayIfNeeded()
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - wall) / 1_000_000
      let mainCPU = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - main) / 1_000_000
      let allCPU = processCPU() - process
      results.append([
        "phase": phase, "updates": changes ? updates : 0, "elapsed_ms": elapsed,
        "main_cpu_ms": mainCPU, "process_cpu_ms": allCPU,
        "main_core_percent": mainCPU / elapsed * 100,
        "process_core_percent": allCPU / elapsed * 100,
        "pane_toolbar_passes": PaneTitleBar.bodyPasses,
        "tab_strip_passes": TerminalTabStrip.bodyPasses,
      ])
    }
    XCTAssertEqual(
      store.terminals.tabs(for: target).first?.title, titles[(Int(duration * 10) - 1) % 4])
    try BenchmarkFixtures.write(
      ["configuration": "Debug", "width": 1_100, "results": results], to: output)
  }
}
