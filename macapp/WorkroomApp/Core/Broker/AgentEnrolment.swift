import Foundation

/// Enrols a new remote workroom's agent with the credential broker (#251, design doc OQ20): the
/// Mac asks the broker for a one-time code bound to this workroom and repository, and hands it to
/// the agent through the driver's exec, on stdin so it never shows in a process list. The agent
/// makes its own key on the instance and registers it (`wr-agent enrol`); from then on it mints
/// its own tokens and the Mac is not involved.
///
/// Runs after the derive (OQ10): the base never enrols, so a fork never inherits an enrolment.
enum AgentEnrolment {
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
        Data((grant.enrolmentCode + "\n").utf8), timeout: 60)
      guard status == 0 else { throw failure(output) }
      return grant.grantId
    } catch {
      try? await client.cancelGrant(grant.grantId)
      throw error
    }
  }

  /// `wr-agent enrol` prints a broker refusal's code on a `refusal:` line; anything else is the
  /// agent's own error.
  static func failure(_ output: String) -> BrokerError {
    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    let message =
      lines.first { $0.hasPrefix("error: ") }.map { String($0.dropFirst(7)) }
      ?? output.trimmingCharacters(in: .whitespacesAndNewlines)
    if let code = lines.first(where: { $0.hasPrefix("refusal: ") })?.dropFirst(9) {
      return .refused(
        BrokerRefusal(status: 0, code: String(code), message: message, installURL: nil))
    }
    return .signIn("The remote workroom couldn't enrol: \(message)")
  }
}
