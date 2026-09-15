import Darwin
import WorkroomSessionProtocol

func argumentValue(_ name: String, in arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

func currentDirectory() -> String {
  guard let raw = getcwd(nil, 0) else { return "/" }
  defer { free(raw) }
  return String(cString: raw)
}

func attachConfiguration() -> SessionAttachClient.Configuration? {
  guard let rawIdentifier = SessionProcessEnvironment.value("WORKROOM_SESSION_ID"),
    let identifier = SessionIdentifier(uuidString: rawIdentifier),
    let socketPath = SessionProcessEnvironment.value("WORKROOM_SESSION_SOCKET")
  else { return nil }

  return SessionAttachClient.Configuration(
    identifier: identifier,
    socketPath: socketPath,
    command: SessionProcessEnvironment.value("WORKROOM_SESSION_COMMAND") ?? "",
    shell: SessionProcessEnvironment.value("WORKROOM_SESSION_SHELL")
      ?? SessionProcessEnvironment.value("SHELL")
      ?? SessionShellIntegration.defaultShell,
    resourcesDirectory: SessionProcessEnvironment.value("WORKROOM_SESSION_RESOURCES")
      ?? SessionProcessEnvironment.value("GHOSTTY_RESOURCES_DIR")
      ?? "",
    workingDirectory: SessionProcessEnvironment.value("WORKROOM_SESSION_CWD") ?? currentDirectory(),
    metadata: attachMetadata())
}

func attachMetadata() -> [SessionEnvironmentEntry] {
  SessionMetadataKey.environmentVariables.compactMap { key, variable in
    guard let value = SessionProcessEnvironment.value(variable) else { return nil }
    return SessionEnvironmentEntry(key: key, value: value)
  }
}

func fail(_ message: String) -> Never {
  SessionLog.write(message)
  exit(2)
}

/// `daemon` is deliberately absent. This binary is an attach-only CLIENT: it connects to a daemon
/// an app at or before v2.0.0 left running and relays a session it already holds. It cannot start
/// one, and starting one would serve no session that exists — every new session goes to `wr-agent`.
/// See `docs/designs/remote-workrooms.md`.
func usage() -> Never {
  fail(
    """
    usage: workroom-session attach
           workroom-session list --socket <path>
           workroom-session kill --socket <path> --session <id>
           workroom-session kill --socket <path> --all
    """)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else { usage() }

switch arguments[1] {
case "attach":
  guard let configuration = attachConfiguration() else {
    fail("workroom-session: WORKROOM_SESSION_ID and WORKROOM_SESSION_SOCKET are required")
  }
  exit(SessionAttachClient.run(configuration: configuration))

case "list":
  guard let socketPath = argumentValue("--socket", in: arguments) else {
    fail("usage: workroom-session list --socket <path>")
  }
  guard let sessions = SessionControlClient.list(socketPath: socketPath) else {
    fail("workroom-session: daemon is not running")
  }
  for session in sessions {
    let title = session.value(forMetadataKey: SessionMetadataKey.title) ?? ""
    let workroom = session.value(forMetadataKey: SessionMetadataKey.workroom) ?? ""
    let attached = session.isAttached ? "attached" : "detached"
    SessionLog.write(
      "\(session.identifier.uuidString)\t\(attached)\t\(session.workingDirectory)\t\(workroom)\t\(title)"
    )
  }
  exit(0)

case "kill":
  guard let socketPath = argumentValue("--socket", in: arguments) else {
    fail("usage: workroom-session kill --socket <path> (--session <id> | --all)")
  }
  if arguments.contains("--all") {
    guard SessionControlClient.killAll(socketPath: socketPath) else {
      fail("workroom-session: failed to stop sessions")
    }
    exit(0)
  }
  guard let raw = argumentValue("--session", in: arguments),
    let identifier = SessionIdentifier(uuidString: raw)
  else {
    fail("usage: workroom-session kill --socket <path> --session <id>")
  }
  guard SessionControlClient.kill(socketPath: socketPath, identifier: identifier) else {
    fail("workroom-session: failed to stop session \(raw)")
  }
  exit(0)

default:
  fail("workroom-session: unknown command \(arguments[1])")
}
