import Foundation
import XCTest

@testable import Workroom

/// `cswap list --json` decoding (#480). Fixtures follow the payload claude-swap 0.26.0 prints,
/// including its microsecond, `+00:00` timestamps.
final class CswapUsageTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_792_180_000)  // 2026-10-16T20:26:40Z

  private func decode(_ json: String) -> CswapUsage.Read {
    CswapUsage.decode(Data(json.utf8), now: now)
  }

  private func accounts(_ read: CswapUsage.Read, file: StaticString = #filePath, line: UInt = #line)
    -> [ClaudeAccountUsage]
  {
    guard case .accounts(let accounts, _) = read else {
      XCTFail("expected accounts, got \(read)", file: file, line: line)
      return []
    }
    return accounts
  }

  func testDecodesEachAccountsWindowsInSlotOrder() {
    let read = decode(
      """
      {"schemaVersion":1,"activeAccountNumber":2,"accounts":[
        {"number":2,"email":"j@example.com","organizationName":"Harley Therapy","alias":"ht",
         "active":true,"usageStatus":"ok","usageFetchedAt":"2026-10-16T20:25:00Z",
         "usage":{"fiveHour":{"pct":0.0,"resetsAt":"2026-10-16T23:40:00.217636+00:00"},
                  "sevenDay":{"pct":92.0,"resetsAt":"2026-10-18T00:00:00.217655+00:00"}}},
        {"number":1,"email":"j@example.com","organizationName":"Personal","active":false,
         "usageStatus":"ok","usageFetchedAt":"2026-10-16T20:24:00Z",
         "usage":{"fiveHour":{"pct":9.0,"resetsAt":"2026-10-16T22:40:00.062114+00:00"},
                  "sevenDay":{"pct":63.0,"resetsAt":"2026-10-18T14:00:00.062133+00:00"}}}
      ]}
      """)

    guard case .accounts(let accounts, let activeSlot) = read else {
      return XCTFail("expected accounts, got \(read)")
    }
    XCTAssertEqual(activeSlot, 2)
    XCTAssertEqual(accounts.map(\.account.slot), [1, 2])
    XCTAssertEqual(accounts[1].account.alias, "ht")
    XCTAssertEqual(accounts[1].account.organizationName, "Harley Therapy")

    let personal = accounts[0].snapshot
    XCTAssertEqual(personal?.backend, .claude)
    XCTAssertEqual(personal?.windows.map(\.kind), [.fiveHour, .weekly])
    XCTAssertEqual(personal?.windows.map(\.usedPercentage), [9, 63])
    XCTAssertEqual(
      personal?.windows.first?.resetsAt.timeIntervalSince1970 ?? 0, 1_792_190_400.062114,
      accuracy: 0.001)
    XCTAssertEqual(
      personal?.capturedAt, ISO8601DateFormatter().date(from: "2026-10-16T20:24:00Z"))
    XCTAssertNil(accounts[0].unavailableReason)
  }

  func testIgnoresFieldsItDoesNotKnow() {
    let read = decode(
      """
      {"schemaVersion":1,"activeAccountNumber":1,"newTopLevel":{"x":1},"accounts":[
        {"number":1,"email":"a@example.com","usageStatus":"ok","somethingNew":true,
         "usage":{"fiveHour":{"pct":5,"resetsAt":"2026-10-16T22:00:00Z","countdown":"1h"},
                  "spend":{"used":1},"scoped":[{"name":"Fable","pct":3}]}}
      ]}
      """)
    XCTAssertEqual(accounts(read).first?.snapshot?.windows.map(\.usedPercentage), [5])
  }

  func testLeavesOutDisabledAndApiKeyAccounts() {
    let read = decode(
      """
      {"schemaVersion":1,"activeAccountNumber":1,"accounts":[
        {"number":1,"email":"a@example.com","usageStatus":"ok",
         "usage":{"fiveHour":{"pct":5,"resetsAt":"2026-10-16T22:00:00Z"}}},
        {"number":2,"email":"b@example.com","usageStatus":"ok","disabled":true,
         "usage":{"fiveHour":{"pct":5,"resetsAt":"2026-10-16T22:00:00Z"}}},
        {"number":3,"email":"api-key-3@token.local","usageStatus":"api_key","usage":null}
      ]}
      """)
    XCTAssertEqual(accounts(read).map(\.account.slot), [1])
  }

  func testAnExpiredLoginKeepsItsLastReadingAndSaysWhatToDo() {
    let read = decode(
      """
      {"schemaVersion":1,"activeAccountNumber":1,"accounts":[
        {"number":1,"email":"a@example.com","usageStatus":"token_expired","usage":null,
         "lastGoodFetchedAt":"2026-10-16T18:00:00Z",
         "lastGoodUsage":{"fiveHour":{"pct":40,"resetsAt":"2026-10-16T22:00:00Z"}}},
        {"number":2,"email":"b@example.com","usageStatus":"keychain_unavailable","usage":null}
      ]}
      """)
    let decoded = accounts(read)
    XCTAssertEqual(decoded[0].snapshot?.windows.map(\.usedPercentage), [40])
    XCTAssertEqual(
      decoded[0].snapshot?.capturedAt, ISO8601DateFormatter().date(from: "2026-10-16T18:00:00Z"))
    XCTAssertEqual(decoded[0].unavailableReason, "Sign in to this account again with cswap.")
    XCTAssertNil(decoded[1].snapshot)
    XCTAssertEqual(
      decoded[1].unavailableReason, "Your keychain is locked. Unlock it, then refresh.")
  }

  func testAnUnknownSchemaOrUnreadableOutputFallsBack() {
    XCTAssertEqual(
      decode(#"{"schemaVersion":2,"accounts":[]}"#),
      .incompatible("cswap reports schema version 2; Workroom reads version 1."))
    XCTAssertEqual(decode("not json"), .incompatible("cswap's output couldn't be read."))
    XCTAssertEqual(
      decode(#"{"schemaVersion":1,"error":{"type":"LockError","message":"busy"}}"#),
      .failed("cswap failed: busy"))
  }
}
