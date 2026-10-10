import Foundation

/// Enrols a new remote workroom's agent with the credential broker (#251, design doc OQ20): the
/// Mac asks the broker for a one-time code bound to this workroom and repository, and hands it to
/// the agent through the driver's exec, on stdin so it never shows in a process list. The agent
/// makes its own key on the instance and registers it (`wr-agent enrol`); from then on it mints
/// its own tokens and the Mac is not involved.
///
/// Runs once the workroom's host exists and before its clone (OQ10), so git clones with the agent's
/// own credentials.
enum AgentEnrolment {
  /// Silence allowed on the exec. `wr-agent enrol` is one broker request and at most one
  /// stale-proof retry, each bounded by the agent's own 15 s `TIMEOUT` (`broker.rs`), so this keeps
  /// headroom over both; change them together.
  static let execTimeout: TimeInterval = 60
  /// The lines `wr-agent enrol` writes on failure (`run_enrol` in `wr-agent/src/main.rs`).
  static let errorPrefix = "error: "
  static let refusalPrefix = "refusal: "

  /// The broker URL the agent is given, and how to let go of whatever made it reachable.
  struct AgentBroker: Sendable {
    var url:
      @Sendable (_ client: BrokerClient, _ workroom: UUID, _ host: HostID) async throws -> URL
    var release: @Sendable (_ workroom: UUID) async -> Void

    /// Release and Nightly: the Mac's own broker, codaset.dev, which the agent reaches itself. Debug:
    /// a listener on the agent's box carried back to this Mac's development Codaset
    /// (`BrokerReverseForwards`), because there the Mac's own URL names the remote host itself.
    static let standard: AgentBroker = {
      #if DEBUG
        return AgentBroker(
          url: { _, workroom, host in
            try await BrokerReverseForwards.shared.open(workroom: workroom, host: host)
          },
          release: { workroom in await BrokerReverseForwards.shared.close(workroom: workroom) })
      #else
        return AgentBroker(url: { client, _, _ in client.baseURL }, release: { _ in })
      #endif
    }()
  }

  /// Returns the grant's ID, which destroying the workroom cancels (`BrokerClient.cancelGrant`).
  /// A failed enrolment cancels the grant it created, so nothing is left minting for it, and lets go
  /// of the agent's route to the broker.
  static func enrol(
    client: BrokerClient, driver: any HostDriver, host: HostID, agentBinary: String,
    workroomID: UUID, repository: String, agentBroker: AgentBroker = .standard
  ) async throws -> String {
    // Before the grant: an agent that could never reach the broker must not cost one. A route
    // half made (a Debug listener registered, then refused) is let go too, or every later
    // connection to the host would reopen it for a workroom that never enrolled.
    let broker: URL
    do {
      broker = try await agentBroker.url(client, workroomID, host)
    } catch {
      await agentBroker.release(workroomID)
      throw error
    }
    let grant: BrokerClient.Grant
    do {
      grant = try await client.createGrant(repository: repository, workroomID: workroomID)
    } catch {
      await agentBroker.release(workroomID)
      throw error
    }
    do {
      let command = [
        PosixShell.quoted(agentBinary), "enrol",
        "--workroom", PosixShell.quoted(workroomID.uuidString.lowercased()),
        "--broker", PosixShell.quoted(broker.absoluteString),
      ].joined(separator: " ")
      let stream = try await driver.exec(command, on: host)
      let (status, output) = try await stream.communicate(
        Data((grant.enrolmentCode + "\n").utf8), timeout: execTimeout)
      guard status == 0 else { throw failure(output) }
      return grant.grantId
    } catch {
      // In its own task: a cancelled enrolment's task would cancel this request too, and leave a
      // grant live that the agent may already have enrolled against.
      let cancelFailure = await Task { () -> String? in
        do {
          try await client.cancelGrant(grant.grantId)
          return nil
        } catch { return error.localizedDescription }
      }.value
      await agentBroker.release(workroomID)
      if let cancelFailure {
        throw GrantStillLive(grantID: grant.grantId, cause: error, cancelFailure: cancelFailure)
      }
      throw error
    }
  }

  /// An enrolment failed with `cause`, and its grant could not be cancelled either: `grantID` is
  /// still live, and the caller is the only one left who knows it.
  struct GrantStillLive: Error, LocalizedError {
    let grantID: String
    let cause: any Error
    let cancelFailure: String

    var errorDescription: String? {
      "\(cause.localizedDescription) Its grant could not be cancelled: \(cancelFailure)"
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
