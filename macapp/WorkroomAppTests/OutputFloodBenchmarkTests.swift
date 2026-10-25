import AppKit
import Darwin
import GhosttyKit
import XCTest

@testable import Workroom

/// Opt-in live engine profile. Owns its shell/yes process; never attaches to a saved session.
@MainActor
final class OutputFloodBenchmarkTests: XCTestCase {
  private struct Counters {
    let cpu: Double
    let switches: Int64
    let bsdCalls: Int64
    let machCalls: Int64
    let threads: [String: Double]

    init(pid: pid_t) throws {
      var task = proc_taskinfo()
      let size = Int32(MemoryLayout.size(ofValue: task))
      guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      var usage = rusage_info_v4()
      let status = withUnsafeMutablePointer(to: &usage) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
          proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
      }
      guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      // proc_pid_rusage reports Mach absolute-time ticks, unlike getrusage's timeval.
      var timebase = mach_timebase_info_data_t()
      guard mach_timebase_info(&timebase) == KERN_SUCCESS else {
        throw NSError(domain: "OutputFloodBenchmark", code: 1)
      }
      cpu =
        Double(usage.ri_user_time + usage.ri_system_time)
        * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
      switches = Int64(task.pti_csw)
      bsdCalls = Int64(task.pti_syscalls_unix)
      machCalls = Int64(task.pti_syscalls_mach)
      var ids = [UInt64](repeating: 0, count: 256)
      let bytes = ids.withUnsafeMutableBytes {
        proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, $0.baseAddress, Int32($0.count))
      }
      guard bytes > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      var named: [String: Double] = [:]
      for id in ids.prefix(Int(bytes) / MemoryLayout<UInt64>.size) {
        var info = proc_threadinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTHREADINFO, id, &info, size) == size else { continue }
        var name = info.pth_name
        let text = withUnsafePointer(to: &name) {
          $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
        }
        if ["io-reader", "io-gather", "io", "renderer"].contains(text) {
          // PROC_PIDTHREADINFO converts thread time to nanoseconds, unlike proc_pid_rusage.
          named[text] = Double(info.pth_user_time + info.pth_system_time) / 1_000_000
        }
      }
      threads = named
    }

    func delta(from before: Self, elapsed: Double) -> [String: Double] {
      [
        "cpu_ms": cpu - before.cpu,
        "core_percent": (cpu - before.cpu) / elapsed * 100,
        "context_switches_per_second": Double(switches - before.switches) / elapsed * 1_000,
        "bsd_syscalls_per_second": Double(bsdCalls - before.bsdCalls) / elapsed * 1_000,
        "mach_syscalls_per_second": Double(machCalls - before.machCalls) / elapsed * 1_000,
      ]
    }
  }

  private func processCPU() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000
  }

  func testLiveOutputFlood() async throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["WORKROOM_BENCH"] == "1",
      "benchmark: run make app-bench-output-flood")
    let seconds = max(
      5, Double(ProcessInfo.processInfo.environment["WORKROOM_BENCH_SECONDS"] ?? "") ?? 60)
    let output = BenchmarkFixtures.reportURL(named: "output-flood")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "workroom-output-flood-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("producer.pid")
    let script = """
      printf '%s\\n' "$$" > \(CommandLineInstaller.shellQuoted(pidFile.path))
      IFS= read -r start || exit 1
      exec /usr/bin/yes
      """
    let view = GhosttySurfaceView(
      workingDirectory: directory.path,
      command: "/bin/sh -c " + CommandLineInstaller.shellQuoted(script))
    view.frame = NSRect(x: 0, y: 0, width: 1_100, height: 700)
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Output flood benchmark"
    var producer: pid_t?
    defer {
      view.tearDown()
      window.close()
      // A failed assertion must not leave our synthetic flood running.
      if let producer, kill(producer, 0) == 0 { kill(producer, SIGTERM) }
    }
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    _ = try XCTUnwrap(view.surface, "the benchmark requires the real engine")
    for _ in 0..<100 {
      if let text = try? String(contentsOf: pidFile, encoding: .utf8),
        let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        producer = pid
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    let child = try XCTUnwrap(producer, "the gated producer must have started")
    let activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiated, reason: "Measuring live terminal output")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    try await Task.sleep(for: .seconds(2))
    var results: [[String: Any]] = []
    for phase in ["idle", "flood", "hidden", "recovered"] {
      if phase == "flood" {
        view.sendText("start\r")
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(view.readFullSurface()?.contains("y") == true, "yes must reach the terminal")
      } else if phase == "hidden" {
        view.setVisible(false)
        try await Task.sleep(for: .seconds(2))
      } else if phase == "recovered" {
        view.tearDown()
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(kill(child, 0), -1, "freeing our surface must stop its producer")
      }
      try BenchmarkFixtures.write(
        ["pid": getpid(), "producer_pid": child, "phase": phase],
        to: output.appendingPathExtension("phase.json"))
      let appBefore = try Counters(pid: getpid())
      let rusageBefore = processCPU()
      let childBefore = phase == "recovered" ? nil : try Counters(pid: child)
      let mainBefore = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
      let start = DispatchTime.now().uptimeNanoseconds
      try await Task.sleep(for: .seconds(phase == "recovered" ? 5 : seconds))
      let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
      let main = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - mainBefore) / 1_000_000
      let rusageCPU = processCPU() - rusageBefore
      let appAfter = try Counters(pid: getpid())
      let app = appAfter.delta(from: appBefore, elapsed: elapsed)
      XCTAssertEqual(
        try XCTUnwrap(app["cpu_ms"]), rusageCPU, accuracy: max(5, rusageCPU * 0.02),
        "Mach tick conversion must agree with the independent timeval counter")
      var result: [String: Any] = [
        "phase": phase, "elapsed_ms": elapsed, "main_cpu_ms": main,
        "main_core_percent": main / elapsed * 100,
        "app": app, "app_getrusage_cpu_ms": rusageCPU,
      ]
      if phase != "recovered" {
        XCTAssertNotNil(appAfter.threads["io-reader"], "the parser thread must be measurable")
        XCTAssertNotNil(appAfter.threads["io-gather"], "the gather thread must be measurable")
      }
      result["engine_thread_core_percent"] = appAfter.threads.reduce(into: [String: Double]()) {
        result, thread in
        if let before = appBefore.threads[thread.key] {
          result[thread.key] = (thread.value - before) / elapsed * 100
        }
      }
      if let childBefore {
        result["producer"] = try Counters(pid: child).delta(from: childBefore, elapsed: elapsed)
      }
      results.append(result)
    }
    let info = ghostty_info()
    try BenchmarkFixtures.write(
      [
        "configuration": "Debug", "engine_build_mode": info.build_mode.rawValue,
        "width": 1_100, "height": 700, "backing_scale": window.backingScaleFactor,
        "producer_command": "/usr/bin/yes", "results": results,
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
      ], to: output)
  }
}
