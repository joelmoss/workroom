#if DEBUG
  import Foundation

  /// Keeps a hosted unit test's terminals out of this build's real session daemon.
  ///
  /// A pane with a session runs `workroomd attach` against the socket `PersistentSessionPaths`
  /// resolves, which in a hosted run (`AppEnvironment.isHostedUnitRun`) is this Debug build's own
  /// per-bundle daemon: the attach starts that daemon and creates a shell session in it, and
  /// nothing ends the session, so the daemon outlives the run. A test whose surface really spawns
  /// (a backgrounded run tab does so off-window) left one such daemon behind per `make app-test`.
  ///
  /// So in a hosted run `GhosttySurfaceView` asks here before it launches an attach to a local
  /// session, and a refusal both fails the running test and spawns nothing. A test that wants a
  /// real terminal gives it no session, and one that only wants tabs uses an inert surface
  /// (`spawnsSurface: false`). Tests of the daemon itself (`DaemonHarness`) connect to their own
  /// sockets and never come here. Debug only, and never outside a hosted run.
  enum HostedRunSessionGuard {
    /// Fails the running test. Set by the unit-test bundle's observer
    /// (`HostedRunGuardObserver`) as it loads; nil until then, when a refusal stops the process.
    nonisolated(unsafe) static var reportViolation: (@Sendable (String) -> Void)?

    /// Whether to refuse `launch`: in a hosted unit run, an attach to a local session, which
    /// carries the session socket in its environment. A remote pane's carries none.
    static func refuses(
      _ launch: PaneSessionAttachment.Launch, workingDirectory: String,
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
      guard AppEnvironment.isHostedUnitRun(environment: environment),
        let socket = launch.environment.first(where: { $0.key == "WORKROOM_SESSION_SOCKET" })?
          .value
      else { return false }
      let message = """
        A terminal in this test would have attached to this build's real session daemon \
        (\(socket)), from \(workingDirectory), leaving a session that outlives the run. It was not \
        spawned. Give the pane an inert surface (`GhosttySurfaceView(…, spawnsSurface: false)`) \
        or no session.
        """
      if let reportViolation {
        reportViolation(message)
      } else {
        preconditionFailure(message)
      }
      return true
    }
  }
#endif
