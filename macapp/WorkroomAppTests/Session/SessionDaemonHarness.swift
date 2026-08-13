import Foundation

@testable import WorkroomSessionProtocol

/// Launches a throwaway `workroom-session daemon` against a temp socket.
final class SessionDaemonHarness {
  let socketPath: String
  private let process: Process
  private let directory: URL

  static func start() throws -> SessionDaemonHarness {
    // sun_path is 104 bytes; NSTemporaryDirectory() + a UUID overflows it.
    let directory = URL(
      fileURLWithPath: "/tmp/wr-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let socketPath = directory.appendingPathComponent("s.sock").path
    let binary = try binaryURL()
    let process = Process()
    process.executableURL = binary
    process.arguments = ["daemon", "--socket", socketPath, "--idle-timeout", "5000"]
    process.standardOutput = FileHandle.nullDevice
    let errURL = directory.appendingPathComponent("daemon.err")
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    process.standardError = FileHandle(forWritingAtPath: errURL.path)
    try process.run()

    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: socketPath) { break }
      if !process.isRunning { break }
      Thread.sleep(forTimeInterval: 0.02)
    }
    guard FileManager.default.fileExists(atPath: socketPath) else {
      let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
      let status = process.isRunning ? "running" : "exited \(process.terminationStatus)"
      process.terminate()
      throw NSError(
        domain: "SessionDaemonHarness", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "daemon socket never appeared at \(socketPath) (\(status), binary=\(binary.path), stderr=\(err))"
        ])
    }
    return SessionDaemonHarness(socketPath: socketPath, process: process, directory: directory)
  }

  private init(socketPath: String, process: Process, directory: URL) {
    self.socketPath = socketPath
    self.process = process
    self.directory = directory
  }

  func stop() {
    process.terminate()
    process.waitUntilExit()
    try? FileManager.default.removeItem(at: directory)
  }

  static func binaryURL() throws -> URL {
    let names = ["BUILT_PRODUCTS_DIR", "TARGET_BUILD_DIR"]
    for name in names {
      if let dir = ProcessInfo.processInfo.environment[name] {
        let url = URL(fileURLWithPath: dir).appendingPathComponent("workroom-session")
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
      }
    }
    // Logic-test host: the helper sits next to xctest in BUILT_PRODUCTS_DIR, which
    // XCTest does not always export. Walk up from this test bundle.
    let embedded = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/workroom-session")
    if FileManager.default.isExecutableFile(atPath: embedded.path) {
      return embedded
    }
    var candidate = Bundle(for: SessionDaemonHarness.self).bundleURL
    for _ in 0..<6 {
      let url = candidate.appendingPathComponent("workroom-session")
      if FileManager.default.isExecutableFile(atPath: url.path) { return url }
      candidate.deleteLastPathComponent()
    }
    throw NSError(
      domain: "SessionDaemonHarness", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "workroom-session binary not found"])
  }
}
