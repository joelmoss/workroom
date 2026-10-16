import Foundation
import WorkroomWire
import XCTest

@testable import Workroom

/// Which cswap account a pane's `claude` bills, from the Claude profile wr-agent reports (#480).
final class ClaudeProfileResolutionTests: XCTestCase {
  private func usage(_ slot: Int) -> ClaudeAccountUsage {
    ClaudeAccountUsage(
      account: ClaudeAccount(
        slot: slot, alias: nil, email: "\(slot)@example.com", organizationName: nil),
      snapshot: nil, unavailableReason: nil)
  }

  private lazy var accounts = [usage(1), usage(2)]

  func testACswapProfileDirectoryIsItsSlot() {
    let resolved = ClaudeProfileResolution.account(
      forProfile: "/Users/u/.claude-swap-backup/sessions/2-u_example.com", accounts: accounts,
      activeSlot: 1)
    XCTAssertEqual(resolved?.account.slot, 2)
  }

  func testNoProfileIsTheDefaultLoginsAccount() {
    XCTAssertEqual(
      ClaudeProfileResolution.account(forProfile: "", accounts: accounts, activeSlot: 1)?
        .account.slot, 1)
  }

  func testAnyOtherProfileIsNoAccount() {
    for profile in [
      "/Users/u/.claude-work", "/Users/u/.claude-swap-backup/sessions/9-gone_example.com",
      "/Users/u/elsewhere/2-u_example.com", "/Users/u/.claude-swap-backup/sessions/notaslot",
    ] {
      XCTAssertNil(
        ClaudeProfileResolution.account(forProfile: profile, accounts: accounts, activeSlot: 1),
        profile)
    }
  }

  /// An agent too old to report the profile sends no entry at all: never guess an account.
  func testAMissingProfileIsNoAccount() {
    XCTAssertNil(
      ClaudeProfileResolution.account(forProfile: nil, accounts: accounts, activeSlot: 1))
  }

  /// wr-agent always sends the entry, empty when unset; its absence is what marks an old agent.
  func testTheDescriptorEntryTellsUnsetFromNotReported() {
    func descriptor(_ metadata: [SessionEnvironmentEntry]) -> SessionDescriptor {
      SessionDescriptor(
        identifier: SessionIdentifier(UUID()), shellProcessID: 1, ttyDevice: 0,
        workingDirectory: "", isAttached: false, metadata: metadata)
    }
    XCTAssertEqual(
      TerminalSessions.claudeProfile(
        from: descriptor([SessionEnvironmentEntry(key: "claude_profile", value: "")])),
      .reported(""))
    XCTAssertEqual(
      TerminalSessions.claudeProfile(
        from: descriptor([SessionEnvironmentEntry(key: "command", value: "claude")])),
      .notReported)
    XCTAssertEqual(TerminalSessions.claudeProfile(from: nil), .notReported)
  }
}
