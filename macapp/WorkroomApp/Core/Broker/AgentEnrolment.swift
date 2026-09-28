import Foundation

/// Enrols a new remote workroom's agent with the credential broker (#251, design doc OQ20): the
/// Mac asks the broker for a one-time code bound to this workroom and repository, and hands it to
/// the agent through the driver's exec, on stdin so it never shows in a process list. The agent
/// makes its own key on the instance and registers it (`wr-agent enrol`); from then on it mints
/// its own tokens and the Mac is not involved.
///
/// Runs after the derive (OQ10): the base never enrols, so a fork never inherits an enrolment.
enum AgentEnrolment {
  /// Silence allowed on the exec. `wr-agent enrol` is one broker request and at most one
  /// stale-proof retry, each bounded by the agent's own 15 s `TIMEOUT` (`broker.rs`), so this keeps
  /// headroom over both; change them together.
  static let execTimeout: TimeInterval = 60
  /// The lines `wr-agent enrol` writes on failure (`run_enrol` in `wr-agent/src/main.rs`).
  static let errorPrefix = "error: "
  static let refusalPrefix = "refusal: "

  /// Returns the grant's ID, which destroying the workroom cancels (`BrokerClient.cancelGrant`).
  /// A failed enrolment cancels the grant it created, so nothing is left minting for it.
  static func enrol(
    client: BrokerClient, driver: any HostDriver, host: HostID, agentBinary: String,
    workroomID: UUID, repository: String
  ) async throws -> String {
    let grant = try await client.createGrant(repository: repository, workroomID: workroomID)
    do {
      let command = [
        PosixShell.quoted(agentBinary), "enrol",
        "--workroom", PosixShell.quoted(workroomID.uuidString.lowercased()),
        "--broker", PosixShell.quoted(client.baseURL.absoluteString),
      ].joined(separator: " ")
      let stream = try await driver.exec(command, on: host)
      let (status, output) = try await stream.communicate(
        Data((grant.enrolmentCode + "\n").utf8), timeout: execTimeout)
      guard status == 0 else { throw failure(output) }
      return grant.grantId
    } catch {
      // In its own task: a cancelled enrolment's task would cancel this request too, and leave a
      // grant live that the agent may already have enrolled against.
      await Task { try? await client.cancelGrant(grant.grantId) }.value
      throw error
    }
  }

  /// `wr-agent enrol` prints a broker refusal's code on a `refusal:` line; anything else is the
  /// agent's own error. Either way it is the agent's failure, never this Mac's: a remote
  /// `unknown_key` must not sign the Mac out.
  static func failure(_ output: String) -> BrokerError {
    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    let value = { (prefix: String) in
      lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
    let message = value(errorPrefix) ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
    if let code = value(refusalPrefix) {
      return .agentRefused(
        BrokerRefusal(status: 0, code: code, message: message, installURL: nil))
    }
    return .agent("The remote workroom couldn't enrol: \(message)")
  }
}
