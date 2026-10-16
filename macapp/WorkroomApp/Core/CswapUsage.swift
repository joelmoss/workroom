import Foundation
import WorkroomSystem

/// One Claude account as cswap (claude-swap) numbers it (#480). See `CONTEXT.md`, "Claude account".
struct ClaudeAccount: Equatable, Hashable, Sendable {
  let slot: Int
  let alias: String?
  let email: String
  let organizationName: String?
}

/// A Claude account's last reading, or why there is none.
struct ClaudeAccountUsage: Equatable, Sendable {
  let account: ClaudeAccount
  /// The newest reading cswap has, current or last-known.
  let snapshot: CodingAgentQuotaSnapshot?
  /// Set when cswap could not read this account's usage now; what the user should do about it.
  let unavailableReason: String?
}

/// Claude usage for every account cswap manages, from `cswap list --json`.
///
/// Workroom never reads Claude credentials or calls Anthropic itself: cswap does, keeps its own
/// cache (180 s before it refetches), and serves last-known numbers when a fetch fails.
enum CswapUsage {
  enum Read: Equatable, Sendable {
    case accounts([ClaudeAccountUsage], activeSlot: Int?)
    /// cswap is not on the augmented PATH.
    case notInstalled
    /// Output Workroom cannot read: another schema version, or not JSON at all.
    case incompatible(String)
    /// cswap ran but failed (a lock, a timeout, an error payload).
    case failed(String)
  }

  /// cswap's own worst case is about 0.25 s per account plus a 5 s fetch, a 10 s token refresh
  /// and 5 s per Keychain call; past this something is stuck.
  static let timeout: TimeInterval = 30

  static func read(runner: StatusCommandRunning, now: Date) async -> Read {
    let result = await runner.run(
      "cswap", ["list", "--json"],
      in: FileManager.default.homeDirectoryForCurrentUser.path, timeout: timeout,
      // Empty is unset to cswap. Without this, an app launched from a Claude session's terminal
      // passes that one profile's directory on and cswap reads only that profile.
      environment: ["CLAUDE_CONFIG_DIR": ""])
    if result.exitCode == CommandResult.commandNotFound { return .notInstalled }
    if result.timedOut { return .failed("cswap took longer than \(Int(timeout)) seconds.") }
    let read = decode(Data(result.stdout.utf8), now: now)
    if case .incompatible = read, result.exitCode != 0 {
      return .failed("cswap exited with status \(result.exitCode).")
    }
    return read
  }

  static func decode(_ data: Data, now: Date) -> Read {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return .incompatible("cswap's output couldn't be read.")
    }
    let version = (root["schemaVersion"] as? NSNumber)?.intValue
    guard version == 1 else {
      return .incompatible(
        "cswap reports schema version \(version.map(String.init) ?? "none"); Workroom reads "
          + "version 1.")
    }
    if let error = root["error"] as? [String: Any] {
      return .failed("cswap failed: \(error["message"] as? String ?? "unknown error")")
    }
    let rows = (root["accounts"] as? [[String: Any]]) ?? []
    let accounts = rows.compactMap { account(from: $0, now: now) }
      .sorted { $0.account.slot < $1.account.slot }
    return .accounts(accounts, activeSlot: (root["activeAccountNumber"] as? NSNumber)?.intValue)
  }

  private static func account(from row: [String: Any], now: Date) -> ClaudeAccountUsage? {
    guard let slot = (row["number"] as? NSNumber)?.intValue,
      row["disabled"] as? Bool != true
    else { return nil }
    let status = row["usageStatus"] as? String ?? "unavailable"
    // An API-key account has no subscription quota to show.
    guard status != "api_key" else { return nil }
    let account = ClaudeAccount(
      slot: slot, alias: row["alias"] as? String, email: row["email"] as? String ?? "",
      organizationName: row["organizationName"] as? String)

    let current = (row["usage"] as? [String: Any]).map {
      ($0, row["usageFetchedAt"] as? String)
    }
    let lastGood = (row["lastGoodUsage"] as? [String: Any]).map {
      ($0, row["lastGoodFetchedAt"] as? String)
    }
    let snapshot = (current ?? lastGood).flatMap { usage, fetchedAt in
      snapshot(
        from: usage,
        capturedAt: fetchedAt.flatMap(CodingAgentUsageDecoding.parseISO8601) ?? now)
    }
    return ClaudeAccountUsage(
      account: account, snapshot: snapshot,
      unavailableReason: status == "ok" ? nil : reason(for: status))
  }

  private static func snapshot(from usage: [String: Any], capturedAt: Date)
    -> CodingAgentQuotaSnapshot?
  {
    let spans: [(key: String, kind: CodingAgentQuotaWindowKind, duration: TimeInterval)] = [
      ("fiveHour", .fiveHour, 5 * 60 * 60), ("sevenDay", .weekly, 7 * 24 * 60 * 60),
    ]
    let windows = spans.compactMap { span -> CodingAgentQuotaWindow? in
      guard let window = usage[span.key] as? [String: Any],
        let used = (window["pct"] as? NSNumber)?.doubleValue,
        let reset = (window["resetsAt"] as? String).flatMap(CodingAgentUsageDecoding.parseISO8601)
      else { return nil }
      return CodingAgentQuotaWindow(
        kind: span.kind, usedPercentage: used, duration: span.duration, resetsAt: reset)
    }
    guard !windows.isEmpty else { return nil }
    return CodingAgentQuotaSnapshot(backend: .claude, windows: windows, capturedAt: capturedAt)
  }

  /// What the user can do, in plain words; cswap's status code stays out of the footer.
  private static func reason(for status: String) -> String {
    switch status {
    case "token_expired", "relogin_required": return "Sign in to this account again with cswap."
    case "keychain_unavailable": return "Your keychain is locked. Unlock it, then refresh."
    case "no_credentials": return "cswap has no credentials for this account."
    case "foreign_credential":
      return "This account's login belongs to another Claude install. Re-add it with cswap."
    default: return "cswap couldn't reach Claude's usage service. It will try again."
    }
  }
}
