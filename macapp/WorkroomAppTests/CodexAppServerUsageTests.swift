import Foundation
import XCTest

@testable import Workroom

/// Codex usage read from `codex app-server` (#480): the JSON-RPC exchange, its failures, and the
/// real process transport's lifetime.
final class CodexAppServerUsageTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_792_180_000)

  private let reply = Data(
    #"""
    {"id":2,"result":{"accountId":"x","rateLimits":{"limitId":"codex","planType":"plus",
     "primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1792188450},
     "secondary":{"usedPercent":38,"windowDurationMins":10080,"resetsAt":1792654967}}}}
    """#.replacingOccurrences(of: "\n", with: "").utf8)

  func testSendsInitializeThenTheRateLimitsRead() async {
    let sent = Recorder<[String]>()
    _ = await CodexAppServerUsage.read(
      transport: { requests, _ in
        await sent.set(requests.map { String(decoding: $0, as: UTF8.self) })
        return self.reply
      }, now: now)
    let methods = await sent.value?.compactMap {
      (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["method"]
        as? String
    }
    XCTAssertEqual(methods, ["initialize", "initialized", "account/rateLimits/read"])
  }

  func testDecodesBothWindowsFromTheReply() async {
    let read = await CodexAppServerUsage.read(transport: { _, _ in self.reply }, now: now)
    guard case .snapshot(let snapshot) = read else { return XCTFail("got \(read)") }
    XCTAssertEqual(snapshot.backend, .codex)
    XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .weekly])
    XCTAssertEqual(snapshot.windows.map(\.usedPercentage), [20, 38])
    XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_792_188_450))
    XCTAssertEqual(snapshot.capturedAt, now)
  }

  /// The server sends other messages first (`initialize`'s reply, a `remoteControl` notification);
  /// only the read's own reply ends the exchange.
  func testOnlyTheRateLimitsReplyEndsTheExchange() async {
    let seen = Recorder<[Bool]>()
    _ = await CodexAppServerUsage.read(
      transport: { _, isReply in
        let lines = [
          #"{"id":1,"result":{}}"#, #"{"method":"remoteControl/status/changed","params":{}}"#,
          String(decoding: self.reply, as: UTF8.self),
        ]
        await seen.set(lines.map { isReply(Data($0.utf8)) })
        return self.reply
      }, now: now)
    let matches = await seen.value
    XCTAssertEqual(matches, [false, false, true])
  }

  func testAnErrorReplyOrAFailedExchangeIsAFailure() async {
    let rejected = await CodexAppServerUsage.read(
      transport: { _, _ in
        Data(#"{"id":2,"error":{"code":-32603,"message":"internal error"}}"#.utf8)
      }, now: now)
    XCTAssertEqual(rejected, .failed("The Codex app server couldn't read usage: internal error"))

    let timedOut = await CodexAppServerUsage.read(
      transport: { _, _ in throw CodexAppServerUsage.ExchangeError.timedOut }, now: now)
    XCTAssertEqual(timedOut, .failed("The Codex app server didn't answer in time."))

    let missing = await CodexAppServerUsage.read(
      transport: { _, _ in throw CodexAppServerUsage.ExchangeError.notInstalled }, now: now)
    XCTAssertEqual(missing, .notInstalled)
  }

  /// The real transport against a stand-in server: it answers once stdin carries the read, then
  /// would run forever. The exchange must return the reply AND leave no process behind.
  func testTheProcessTransportReturnsTheReplyAndEndsTheServer() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-app-server-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    let server = directory.appendingPathComponent("codex")
    try """
    #!/bin/sh
    echo $$ > '\(pidFile.path)'
    while IFS= read -r line; do
      case "$line" in
        *rateLimits*) printf '%s\\n' '{"method":"remoteControl/status/changed"}' '\(String(decoding: reply, as: UTF8.self))' ;;
      esac
    done
    exec sleep 600
    """.write(to: server, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)

    let transport = CodexAppServerUsage.processTransport(executable: server, timeout: 10)
    let read = await CodexAppServerUsage.read(transport: transport, now: now)
    guard case .snapshot = read else { return XCTFail("got \(read)") }

    let pid = try XCTUnwrap(
      Int32(
        String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespaces)
          .trimmingCharacters(in: .newlines)))
    // Termination is asynchronous; give it a moment before calling it a leak.
    var alive = true
    for _ in 0..<50 where alive {
      alive = kill(pid, 0) == 0
      if alive { try await Task.sleep(nanoseconds: 50_000_000) }
    }
    XCTAssertFalse(alive, "the app server outlived the poll")
  }

  func testTheProcessTransportGivesUpOnASilentServer() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("codex-app-server-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = directory.appendingPathComponent("codex")
    try "#!/bin/sh\nexec sleep 600\n".write(to: server, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)

    let read = await CodexAppServerUsage.read(
      transport: CodexAppServerUsage.processTransport(executable: server, timeout: 0.5), now: now)
    XCTAssertEqual(read, .failed("The Codex app server didn't answer in time."))
  }
}

/// A box an async closure can write into and the test can read back.
private actor Recorder<Value> {
  private(set) var value: Value?
  func set(_ value: Value) { self.value = value }
}
