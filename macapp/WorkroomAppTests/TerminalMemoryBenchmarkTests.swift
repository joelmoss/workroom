import AppKit
import Darwin
import QuartzCore
import WorkroomSystem
import XCTest

@testable import Workroom

/// Owns three real renderers and inert children. Captures allocation summaries, never object data.
@MainActor
final class TerminalMemoryBenchmarkTests: XCTestCase {
  func testVisibleHiddenAndReleasedMemory() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run make app-bench-memory")
    let output = BenchmarkFixtures.reportURL(named: "terminal-memory")
    try FileManager.default.createDirectory(
      at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "terminal-memory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("children")
    var views: [GhosttySurfaceView] = []
    var samples: [[String: Any]] = []
    let frame = (NSScreen.main?.visibleFrame ?? NSRect(x: 50, y: 50, width: 1_400, height: 900))
      .insetBy(dx: 20, dy: 40)
    let window = NSWindow(
      contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Owned terminal memory fixture"
    defer {
      for view in views { view.tearDown() }
      window.close()
    }
    let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
    window.contentView = container
    window.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .seconds(3))
    samples.append(try await snapshot("baseline", output: output, directory: directory, heap: true))
    for index in 0..<3 {
      let script =
        "printf '%s\\n' \"$$\" >> "
        + CommandLineInstaller.shellQuoted(pidFile.path)
        + "; IFS= read -r start; printf 'memory pane \(index)\\n'; IFS= read -r wait"
      let view = GhosttySurfaceView(
        workingDirectory: directory.path,
        command: "/bin/sh -c " + CommandLineInstaller.shellQuoted(script))
      view.frame = NSRect(
        x: CGFloat(index) * frame.width / 3, y: 0, width: frame.width / 3, height: frame.height)
      views.append(view)
      container.addSubview(view)
    }
    container.layoutSubtreeIfNeeded()
    for view in views { XCTAssertNotNil(view.surface, "requires the real engine") }
    try await Task.sleep(for: .seconds(3))
    for view in views { view.sendText("paint\r") }
    try await Task.sleep(for: .seconds(1))
    for (index, view) in views.enumerated() {
      try checkText(view, index: index, phase: "visible", output: output)
    }
    var visible = try await snapshot("visible", output: output, directory: directory, heap: true)
    visible["layers"] = views.map { layerNames($0.layer) }
    visible["pane_points"] = [frame.width / 3, frame.height]
    visible["scale"] = window.backingScaleFactor
    samples.append(visible)

    let relief = await Task.detached(priority: .utility) {
      let start = DispatchTime.now().uptimeNanoseconds
      let bytes = malloc_zone_pressure_relief(nil, 0)
      return (bytes, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }.value
    try await Task.sleep(for: .seconds(3))
    var trimmed = try await snapshot("trimmed", output: output, directory: directory, heap: false)
    trimmed["relief_bytes"] = relief.0
    trimmed["relief_elapsed_ms"] = relief.1
    samples.append(trimmed)

    for view in views {
      view.setVisible(false)
      view.removeFromSuperview()
    }
    try await Task.sleep(for: .seconds(3))
    samples.append(try await snapshot("hidden", output: output, directory: directory, heap: true))

    for view in views {
      container.addSubview(view)
      view.setVisible(true)
    }
    container.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .seconds(3))
    for (index, view) in views.enumerated() {
      try checkText(view, index: index, phase: "revealed", output: output)
    }
    samples.append(
      try await snapshot("revealed", output: output, directory: directory, heap: false))
    for view in views { view.tearDown() }
    try await Task.sleep(for: .seconds(3))
    samples.append(try await snapshot("released", output: output, directory: directory, heap: true))
    let children = ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "")
      .split(separator: "\n").compactMap { pid_t($0) }
    XCTAssertEqual(children.count, 3)
    XCTAssertFalse(children.contains(where: { kill($0, 0) == 0 }), "all owned children must exit")
    try BenchmarkFixtures.write(
      [
        "configuration": "Debug", "panes": views.count, "samples": samples,
      ], to: output)
  }

  private func checkText(_ view: GhosttySurfaceView, index: Int, phase: String, output: URL) throws
  {
    let text = view.readCommandRegion(maxBytes: 65_536)
    try (text ?? "<nil>").write(
      to: output.appendingPathExtension("\(phase).pane\(index).txt"), atomically: true,
      encoding: .utf8)
    XCTAssertTrue(text?.contains("memory pane \(index)") == true, "\(phase) pane \(index)")
  }

  private func snapshot(_ phase: String, output: URL, directory: URL, heap: Bool) async throws
    -> [String: Any]
  {
    var usage = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    XCTAssertEqual(status, 0)
    var result: [String: Any] = [
      "phase": phase, "footprint_bytes": usage.ri_phys_footprint,
      "resident_bytes": usage.ri_resident_size,
    ]
    for tool in heap ? ["vmmap", "heap"] : ["vmmap"] {
      let arguments = tool == "vmmap" ? ["-summary"] : ["-s", "--noContent"]
      let capture = await StatusCommandRunner().run(
        "/usr/bin/\(tool)", arguments + [String(getpid())], in: directory.path, timeout: 20)
      let report = output.appendingPathExtension("\(phase).\(tool).txt")
      try (capture.stdout + capture.stderr).write(to: report, atomically: true, encoding: .utf8)
      result["\(tool)_exit"] = capture.exitCode
      result["\(tool)_report"] = report.path
      XCTAssertEqual(capture.exitCode, 0, "\(tool) failed; inspect \(report.path)")
      XCTAssertFalse(capture.timedOut)
    }
    return result
  }

  private func layerNames(_ layer: CALayer?) -> [String] {
    guard let layer else { return [] }
    return [NSStringFromClass(type(of: layer))] + (layer.sublayers ?? []).flatMap { layerNames($0) }
  }
}
