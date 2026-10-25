import AppKit
import Darwin
import Sentry

/// Invalid measurements are ordinary failures, never crash reports or native crash dialogs.
func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("Sentry benchmark: \(message)\n".utf8))
  if CommandLine.arguments.count > 2,
    let data = try? JSONSerialization.data(withJSONObject: ["error": message])
  {
    try? data.write(
      to: URL(fileURLWithPath: CommandLine.arguments[2] + ".error.json"), options: .atomic)
  }
  if SentrySDK.isEnabled { SentrySDK.close() }
  Darwin.exit(2)
}

func require(_ condition: Bool, _ message: String) {
  if !condition { fail(message) }
}

// The standalone helper has no release-channel picker or Defaults dependency. Only environment
// metadata needs this fact; all monitoring options come from the app's real SentryConfig source.
enum ReleaseChannel {
  static let isNightlyBuild = false
}

final class Evidence: @unchecked Sendable {
  private let lock = NSLock()
  private var starts = 0
  private var hangs = 0

  func profileStarted() {
    lock.lock()
    defer { lock.unlock() }
    starts += 1
  }

  func event(_ event: Event) {
    lock.lock()
    defer { lock.unlock() }
    if event.exceptions?.contains(where: { $0.type == "App Hanging" }) == true { hangs += 1 }
  }

  func snapshot() -> [String: Int] {
    lock.lock()
    defer { lock.unlock() }
    return ["profiler_starts": starts, "hang_events": hangs]
  }
}

struct Counters {
  let wall = ProcessInfo.processInfo.systemUptime
  let cpu: Double
  let footprint: UInt64
  let switches: Int

  init() {
    var usage = rusage()
    require(getrusage(RUSAGE_SELF, &usage) == 0, "Cannot read CPU counters")
    cpu =
      Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    switches = Int(usage.ru_nvcsw + usage.ru_nivcsw)
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
      }
    }
    require(status == 0, "Cannot read process footprint")
    footprint = info.ri_phys_footprint
  }

  func delta(from before: Counters) -> [String: Any] {
    let elapsed = wall - before.wall
    return [
      "elapsed_seconds": elapsed, "cpu_seconds": cpu - before.cpu,
      "core_percent": (cpu - before.cpu) / elapsed * 100,
      "footprint_bytes": footprint, "context_switches": switches - before.switches,
    ]
  }
}

@MainActor
final class Benchmark: NSObject, NSApplicationDelegate {
  let mode = CommandLine.arguments[1]
  let output = URL(fileURLWithPath: CommandLine.arguments[2])
  let seconds = Double(CommandLine.arguments[3]) ?? 0
  let tail = Double(CommandLine.arguments[4]) ?? 0
  let evidence = Evidence()
  var window: NSWindow!
  var label: NSTextField!
  var results: [[String: Any]] = []
  var startup: [String: Any] = [:]
  var observer: NSObjectProtocol?

  func start() {
    require(["off", "no-profiling", "full"].contains(mode), "Unknown comparison mode")
    require(seconds.isFinite && seconds > 0 && tail.isFinite && tail > 0, "Invalid durations")
    require(!SentryConfig.isDebugBuild, "Compile the helper without DEBUG")
    require(
      NSHomeDirectory() == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
      "The helper needs its isolated temporary home")
    do {
      try String(getpid()).write(
        to: output.appendingPathExtension("pid"), atomically: true, encoding: .utf8)
    } catch { fail("Cannot write owned PID: \(error)") }
    let before = Counters()
    observer = NotificationCenter.default.addObserver(
      forName: Notification.Name("io.sentry.notification.continuous-profile-started"),
      object: nil, queue: nil
    ) { [evidence] _ in evidence.profileStarted() }
    if mode != "off" {
      SentrySDK.start { [self] options in
        SentryConfig.configure(options)
        // No production ingest, personal caches, or persisted state participates in this probe.
        require(options.dsn?.contains("@127.0.0.1:") == true, "Use only the local collector")
        options.cacheDirectoryPath =
          output.deletingLastPathComponent()
          .appendingPathComponent("cache-\(mode)-\(getpid())").path
        options.environment = "local-performance-probe"
        options.releaseName = "workroom-sentry-benchmark@1"
        options.debug = ProcessInfo.processInfo.environment["WORKROOM_SENTRY_PROBE_DEBUG"] == "1"
        if mode == "no-profiling" {
          options.configureProfiling = {
            $0.sessionSampleRate = 0
            $0.lifecycle = .trace
          }
        }
        let original = options.beforeSend
        options.beforeSend = { [evidence] event in
          evidence.event(event)
          return original?(event) ?? event
        }
      }
      require(SentrySDK.isEnabled, "SDK did not start")
    }
    startup = Counters().delta(from: before)
    NSApplication.shared.delegate = self
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "Workroom Sentry measurement (\(mode))"
    label = NSTextField(labelWithString: "Owned SDK workload")
    label.frame = NSRect(x: 20, y: 200, width: 750, height: 80)
    window.contentView!.addSubview(label)
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    Task { @MainActor in
      await run()
    }
  }

  func pause(_ seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
  }

  func phase(_ name: String, seconds: Double, update: Bool = false) async {
    let before = Counters()
    let starts = evidence.snapshot()
    let ticks = max(1, Int(seconds * 10))
    for index in 0..<ticks {
      if update {
        label.stringValue = String(repeating: "Workroom \(index)  ", count: 10)
        label.needsDisplay = true
        window.displayIfNeeded()
      }
      let deadline = before.wall + Double(index + 1) * seconds / Double(ticks)
      await pause(max(0, deadline - ProcessInfo.processInfo.systemUptime))
    }
    var result = Counters().delta(from: before)
    result["phase"] = name
    result["ui_updates"] = update ? ticks : 0
    result["evidence_before"] = starts
    result["evidence_after"] = evidence.snapshot()
    result["app_active"] = NSApplication.shared.isActive
    require(!NSApplication.shared.isActive, "The controlled workload must stay inactive")
    results.append(result)
    print("\(mode): \(name) \(result["core_percent"]!)% of one core")
    fflush(stdout)
  }

  func run() async {
    let activity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiated, reason: "Measuring isolated Sentry SDK overhead")
    defer { ProcessInfo.processInfo.endActivity(activity) }
    // Exclude first AppKit rendering from steady-state counters in all arms.
    await pause(2)
    // Keep focus changes out of the cost comparison. The window is hidden in every arm;
    // foreground is restored separately for real hang detection below.
    NSApplication.shared.hide(nil)
    await pause(0.5)
    await phase("idle_before_trace", seconds: seconds)
    await phase("ui_without_trace", seconds: seconds, update: true)
    require(evidence.snapshot()["profiler_starts"] == 0, "Profiler started without a root span")
    let transaction =
      mode == "off"
      ? nil
      : SentrySDK.startTransaction(
        name: "owned-ui-workload", operation: "benchmark", bindToScope: true)
    await phase("active_trace", seconds: seconds, update: true)
    transaction?.finish()
    let chunkTail = min(tail, max(1, 62 - seconds))
    await phase("after_trace_tail", seconds: chunkTail)
    if tail > chunkTail { await phase("after_chunk", seconds: tail - chunkTail) }

    // Exercise actual hang detection without a debugger; blocking is outside steady-state phases.
    NSApplication.shared.unhide(nil)
    window.makeKeyAndOrderFront(nil)
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    do {
      let activated = try await NSWorkspace.shared.openApplication(
        at: Bundle.main.bundleURL, configuration: configuration)
      require(activated.processIdentifier == getpid(), "Activated a different helper instance")
    } catch { fail("Cannot restore foreground: \(error)") }
    await pause(1)
    require(NSApplication.shared.isActive, "Hang detection requires a foreground app")
    let before = Counters()
    let wasActive = NSApplication.shared.isActive
    blockMainForHang()
    await pause(4)
    var hang = Counters().delta(from: before)
    hang["phase"] = "hang_and_recovery"
    hang["app_active_before"] = wasActive
    results.append(hang)
    if mode != "off" { SentrySDK.flush(timeout: 5) }
    let report: [String: Any] = [
      "mode": mode, "compiler_optimization": "-O, no DEBUG", "sdk_enabled": SentrySDK.isEnabled,
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "startup": startup, "results": results, "evidence": evidence.snapshot(),
    ]
    do {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: output, options: .atomic)
    } catch { fail("Cannot write benchmark report: \(error)") }
    if mode != "off" { SentrySDK.close() }
    if let observer { NotificationCenter.default.removeObserver(observer) }
    window.close()
    NSApplication.shared.terminate(nil)
  }

  func blockMainForHang() {
    require(Thread.isMainThread, "Hang fixture must run on the main thread")
    Thread.sleep(forTimeInterval: 3)
  }
}

require(
  CommandLine.arguments.count == 5, "Expected mode, report path, phase seconds and tail seconds")
MainActor.assumeIsolated {
  Benchmark().start()
}
