import Foundation
import WorkroomSystem

/// Codex usage from `codex app-server`'s `account/rateLimits/read` (#480), which answers with no
/// Codex session running. The server is started for one read and ended straight after.
///
/// Measured on codex-cli 0.163.0: the server exits on stdin EOF before answering the read, so the
/// requests go down a pipe that stays open until the reply arrives.
enum CodexAppServerUsage {
  enum Read: Equatable, Sendable {
    case snapshot(CodingAgentQuotaSnapshot)
    case notInstalled
    case failed(String)
  }

  enum ExchangeError: Error, Equatable {
    case notInstalled
    case timedOut
    case exited
  }

  /// Sends `requests` and returns the first line `isReply` accepts.
  typealias Transport =
    @Sendable (_ requests: [Data], _ isReply: @escaping @Sendable (Data) -> Bool)
    async throws -> Data

  static let timeout: TimeInterval = 15
  private static let readID = 2

  static func read(transport: Transport, now: Date) async -> Read {
    let requests: [[String: Any]] = [
      [
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": ["clientInfo": ["name": "workroom", "version": AppVersion.current ?? "0"]],
      ],
      ["jsonrpc": "2.0", "method": "initialized"],
      ["jsonrpc": "2.0", "id": readID, "method": "account/rateLimits/read", "params": NSNull()],
    ]
    let encoded = requests.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
    do {
      let reply = try await transport(encoded) { line in
        (message(line)?["id"] as? NSNumber)?.intValue == readID
      }
      return decode(reply, now: now)
    } catch ExchangeError.notInstalled {
      return .notInstalled
    } catch ExchangeError.timedOut {
      return .failed("The Codex app server didn't answer in time.")
    } catch {
      return .failed("The Codex app server stopped before answering.")
    }
  }

  static func decode(_ reply: Data, now: Date) -> Read {
    guard let message = message(reply) else {
      return .failed("The Codex app server's reply couldn't be read.")
    }
    if let error = message["error"] as? [String: Any] {
      return .failed(
        "The Codex app server couldn't read usage: \(error["message"] as? String ?? "unknown")")
    }
    let limits = (message["result"] as? [String: Any])?["rateLimits"] as? [String: Any]
    let windows = ["primary", "secondary"].compactMap { key -> CodingAgentQuotaWindow? in
      guard let window = limits?[key] as? [String: Any],
        let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue, minutes > 0,
        let used = (window["usedPercent"] as? NSNumber)?.doubleValue,
        let reset = (window["resetsAt"] as? NSNumber)?.doubleValue
      else { return nil }
      return CodingAgentQuotaWindow(
        kind: CodingAgentUsageDecoding.windowKind(forMinutes: minutes), usedPercentage: used,
        duration: TimeInterval(minutes * 60), resetsAt: Date(timeIntervalSince1970: reset))
    }.sorted { $0.duration < $1.duration }
    guard !windows.isEmpty else {
      return .failed("The Codex app server reported no usage limits.")
    }
    return .snapshot(CodingAgentQuotaSnapshot(backend: .codex, windows: windows, capturedAt: now))
  }

  private static func message(_ line: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: line) as? [String: Any]
  }

  /// Runs `codex app-server` (found on the augmented PATH, or `executable` in a test) for one
  /// exchange, then terminates it whatever the outcome.
  static func processTransport(executable: URL? = nil, timeout: TimeInterval = timeout)
    -> Transport
  {
    { requests, isReply in
      try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        if let executable {
          process.executableURL = executable
          process.arguments = ["app-server"]
        } else {
          process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
          process.arguments = ["codex", "app-server"]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ShellEnvironment.path()
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let exchange = Exchange(process: process, input: input, output: output) {
          continuation.resume(with: $0)
        }
        output.fileHandleForReading.readabilityHandler = { handle in
          let chunk = handle.availableData
          if chunk.isEmpty {
            exchange.finish(.failure(ExchangeError.exited))
          } else if let reply = exchange.append(chunk, isReply: isReply) {
            exchange.finish(.success(reply))
          }
        }
        process.terminationHandler = { process in
          // `/usr/bin/env` exits 127 when `codex` is not on the PATH.
          exchange.finish(
            .failure(
              process.terminationStatus == CommandResult.commandNotFound
                ? ExchangeError.notInstalled : ExchangeError.exited))
        }
        do {
          try process.run()
        } catch {
          exchange.finish(.failure(ExchangeError.notInstalled))
          return
        }
        let lines = requests.reduce(into: Data()) { $0.append($1 + Data("\n".utf8)) }
        try? input.fileHandleForWriting.write(contentsOf: lines)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
          exchange.finish(.failure(ExchangeError.timedOut))
        }
      }
    }
  }

  /// One exchange's buffer and its single outcome. Every callback races to `finish`; the first
  /// wins, and it ends the server and closes stdin so nothing outlives the read.
  private final class Exchange: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var done = false
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let resume: (Result<Data, Error>) -> Void

    init(
      process: Process, input: Pipe, output: Pipe,
      resume: @escaping (Result<Data, Error>) -> Void
    ) {
      self.process = process
      self.input = input
      self.output = output
      self.resume = resume
    }

    /// Adds output and returns the first complete line `isReply` accepts, if any.
    func append(_ chunk: Data, isReply: (Data) -> Bool) -> Data? {
      lock.lock()
      defer { lock.unlock() }
      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<newline]
        buffer.removeSubrange(buffer.startIndex...newline)
        if isReply(Data(line)) { return Data(line) }
      }
      return nil
    }

    func finish(_ result: Result<Data, Error>) {
      lock.lock()
      guard !done else {
        lock.unlock()
        return
      }
      done = true
      lock.unlock()
      output.fileHandleForReading.readabilityHandler = nil
      if process.isRunning { process.terminate() }
      try? input.fileHandleForWriting.close()
      resume(result)
    }
  }
}
