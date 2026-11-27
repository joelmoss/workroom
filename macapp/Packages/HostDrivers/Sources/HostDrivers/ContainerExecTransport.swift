import DaemonConnection
import Foundation
import WorkroomDomain
import WorkroomSystem

/// How the container driver reaches its containers (#308): the runtime's own `exec` (Docker's, or
/// Apple's `container`), not ssh, so any image will do. The container needs no sshd, no host key and
/// no published port; anyone who can reach the runtime's socket already has a root shell in every
/// container on it, which is at least the shell login ADR 0028 asks a driver's link to be.
///
/// Forwards and the git credential relay already ride the daemon connection, so what crosses here
/// is the three things ssh carried: a one-off shell line (`exec`), the daemon's relay (`openStream`),
/// and a pane's attach (`attachCommand`), whose in-container half is the ssh hosts' own
/// (`SSHTransport.remoteAttachCommand`). A pane's last attach is recorded the same way, beside its
/// log, so `lastAttach` reads both kinds.
public enum ContainerExecTransport {
  /// One container, as `exec` reaches it.
  public struct Target: Sendable {
    public let runtime: URL
    public let dialect: ContainerRuntime
    /// The Docker context every command names, or nil (Apple's runtime has none).
    public let context: String?
    public let container: String
    /// The user every command runs as (the container's remote user); nil for the image's own.
    public let user: String?
    public let daemonSocket: String
    /// The daemon's binary in the container: beside the socket unless the driver put it elsewhere.
    public let daemonBinary: String

    public init(
      runtime: URL, dialect: ContainerRuntime, context: String?, container: String,
      user: String?, daemonSocket: String, daemonBinary: String? = nil
    ) {
      self.runtime = runtime
      self.dialect = dialect
      self.context = context
      self.container = container
      self.user = user
      self.daemonSocket = daemonSocket
      self.daemonBinary = daemonBinary ?? DaemonInstall.binary(besideSocket: daemonSocket)
    }
  }

  /// The runtime's arguments to run `command` in `target` (both runtimes spell `exec` the same).
  /// `--context` is global, so it goes before `exec`.
  static func arguments(_ target: Target, tty: Bool, command: [String]) -> [String] {
    ContainerHostDriver.runtimeArguments(
      ["exec", "-i"] + (tty ? ["-t"] : []) + (target.user.map { ["-u", $0] } ?? [])
        + [target.container] + command,
      context: target.dialect == .docker ? target.context : nil)
  }

  /// The environment `target`'s runtime runs with (`ContainerHostDriver.runtimeEnvironment`).
  static func environment(_ target: Target) -> [String: String] {
    ContainerHostDriver.runtimeEnvironment(
      ProcessInfo.processInfo.environment, runtime: target.runtime)
  }

  /// Runs `command`, a line for the container's `sh`, as the remote user. The container's shell is
  /// the one thing this asks of an image beyond git, as the panes need it too.
  public static func exec(_ command: String, on target: Target, purpose: HostStream.Purpose) throws
    -> HostStream
  {
    try HostStream.spawn(
      target.runtime, arguments(target, tty: false, command: ["sh", "-c", ownHome + command]),
      environment: environment(target), handshakeTimeout: 20, purpose: purpose)
  }

  /// Sets `HOME` to the remote user's, from the container's passwd file, ahead of a command: Docker's
  /// `exec -u` sets it, Apple's doesn't (1.5.0 gives a non-root user `/`, measured), and the
  /// lifecycle commands, the scripts and `~` in a path need it. Shell builtins and `id` only.
  static let ownHome = """
    me=$(id -u); while IFS=: read -r _ _ uid _ _ dir _; do \
    [ "$uid" = "$me" ] && { HOME=$dir; export HOME; break; }; done < /etc/passwd 2>/dev/null;
    """

  /// The daemon's relay, by path: the service stream.
  public static func openStream(on target: Target) throws -> HostStream {
    try HostStream.spawn(
      target.runtime, relayArguments(target), environment: environment(target),
      handshakeTimeout: 20, purpose: .connection)
  }

  /// The runtime's arguments for `openStream`: the relay, with no shell in between.
  static func relayArguments(_ target: Target) -> [String] {
    arguments(
      target, tty: false, command: [target.daemonBinary, "relay", "--socket", target.daemonSocket])
  }

  /// The command a pane runs to attach to `session` in `target`: the runtime's `exec -it`, which
  /// gives the attach a terminal and passes the pane's resizes on, around the ssh hosts' own
  /// in-container attach (the old-layout check, the terminfo choice, the "no daemon yet" exit 255),
  /// inside `attachWrapper`, keeping the runtime's own messages in `hostDirectory`.
  public static func attachCommand(
    on target: Target, in hostDirectory: URL, session: UUID, workingDirectory: String,
    restored: Bool, metadata: [(key: String, value: String)], runCommand: String?
  ) -> String {
    try? FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
    let script = SSHTransport.remoteAttachCommand(
      binary: target.daemonBinary, session: session, socket: target.daemonSocket,
      resources: DaemonInstall.resources(besideSocket: target.daemonSocket),
      workingDirectory: workingDirectory, restored: restored, metadata: metadata,
      runCommand: runCommand)
    let log = SSHTransport.attachLog(session, in: hostDirectory).path
    let exec =
      [target.runtime.path]
      + arguments(
        target, tty: true,
        command: [
          "sh", "-c",
          ownHome + ContainerHostDriver.postStartWait + "; "
            + stagedResume(session: session, socket: target.daemonSocket) + script,
        ])
    let stage = arguments(
      target, tty: false,
      command: ["sh", "-c", stageResume(session: session, socket: target.daemonSocket), "stage"])
    return
      (["/bin/sh", "-c", attachWrapper, "workroom-attach", log]
      + [([target.runtime.path] + stage).map(PosixShell.quoted).joined(separator: " ")] + exec)
      .map(PosixShell.quoted).joined(separator: " ")
  }

  /// The folder in the container a pane's resume record is copied into (#826), as this Mac's is
  /// beside its own daemon's socket (`ResumeLaunchFile.directory`): only this code writes it.
  static func resumeFolder(besideSocket socket: String) -> String {
    (socket as NSString).deletingLastPathComponent + "/resume-launch"
  }

  /// What the container's `sh` runs, as the remote user, to copy in a remote pane's resume record
  /// (#826), its bytes on stdin and its file's name (`ResumeLaunchFile.name`) as `$1`: into a new
  /// `0600` file in the `0700` `resumeFolder`, where the pane's attach finds it (`stagedResume`),
  /// whose client claims and removes it. The record's arguments can hold secrets, so they never
  /// travel on a command line, which a process listing shows. First, this session's files a copy
  /// left that no attach claimed (an attach that never started), which only this code names so:
  /// regular files alone, judged without following a link.
  static func stageResume(session: UUID, socket: String) -> String {
    let folder = resumeFolder(besideSocket: socket)
    let mine = "resume-\(session.uuidString.lowercased())-"
    return "dir=\(PosixShell.quoted(folder)); case $1 in \(mine)*.json) ;; *) exit 1;; esac; "
      + "umask 077; mkdir -p \"$dir\" && test -d \"$dir\" && ! test -L \"$dir\" "
      + "&& chmod 700 \"$dir\" || exit 1; "
      + "for f in \"$dir\"/\(mine)*.json; do test -f \"$f\" && ! test -L \"$f\" && rm -f \"$f\"; "
      + "done; cat > \"$dir/$1\""
  }

  /// The in-container half of a pane's attach that hands its client the record `stageResume`
  /// copied in for its session, by path (#826), and nothing when there is none.
  static func stagedResume(session: UUID, socket: String) -> String {
    let mine = "resume-\(session.uuidString.lowercased())-"
    return "for f in \(PosixShell.quoted(resumeFolder(besideSocket: socket)))/\(mine)*.json; do "
      + "if test -f \"$f\"; then WORKROOM_SESSION_RESUME=$f; export WORKROOM_SESSION_RESUME; fi; "
      + "done; "
  }

  /// What a pane runs around its `exec`, as
  /// `sh -c <this> workroom-attach <log> <stage line> <exec argv>`.
  ///
  /// A restored pane's resume record (#826), in the file this Mac's `WORKROOM_SESSION_RESUME`
  /// names, is first copied into the container over the stdin of `stage line`'s own `exec`
  /// (`stageResume`), never its command line, and the Mac's file removed whatever came of it.
  ///
  /// With a terminal, everything the container prints comes through the terminal, so the runtime's
  /// own stderr holds only its own messages: they go to the log. One saying the container isn't
  /// running, or the runtime didn't answer, is a link that comes back (opening the workroom starts
  /// a stopped container; a runtime restarts), so it is recorded as ssh's lost-link status, 255,
  /// and the pane says it keeps trying (`SSHTransport.retryNotice`). Any other message is shown, as
  /// the runtime said it. The status goes beside the log, as the ssh wrapper's does (#392), removed
  /// before the attach starts so a killed wrapper leaves none.
  public static let attachWrapper = """
    log=$1; stage=$2; shift 2; : > "$log"; rm -f "${log%.log}.status"; \
    if [ -n "${WORKROOM_SESSION_RESUME-}" ] && [ -f "$WORKROOM_SESSION_RESUME" ]; then \
    name=${WORKROOM_SESSION_RESUME##*/}; eval "$stage \\"\\$name\\"" \
    < "$WORKROOM_SESSION_RESUME" > /dev/null 2>&1; rm -f "$WORKROOM_SESSION_RESUME"; fi; \
    unset WORKROOM_SESSION_RESUME; \
    "$@" 2>"$log"; status=$?; \
    if [ "$status" != 0 ] && grep -qiF \(lostLinkPatterns) "$log"; then status=255; \
    printf '\\r\\n%s\\r\\n' \(PosixShell.quoted(SSHTransport.retryNotice)) >&2; \
    elif [ -s "$log" ]; then printf '\\r\\n'; cat "$log" >&2; fi; \
    echo "$status" > "${log%.log}.status"; exit "$status"
    """

  /// The runtimes' words for a container that isn't running and a runtime that didn't answer
  /// (Docker 29 and Apple's 1.5.0), lowercase.
  static let lostLinks = [
    "is not running", "cannot connect", "failed to connect", "error during connect",
    "xpc connection", "container system start",
  ]

  private static let lostLinkPatterns = lostLinks.map { "-e " + PosixShell.quoted($0) }.joined(
    separator: " ")

  /// The runtimes' words for a container that is gone, which won't come back.
  static let refusals = ["no such container", "notfound"]

  /// How the last attach of `session` ended, as the wrapper recorded it.
  public static func lastAttach(of session: UUID, in hostDirectory: URL) -> LastAttach {
    SSHTransport.lastAttach(of: session, in: hostDirectory)
  }

  /// Whether the last attach of `session` found its container gone.
  public static func refusedLastAttach(of session: UUID, in hostDirectory: URL) -> Bool {
    let log =
      (try? String(
        contentsOf: SSHTransport.attachLog(session, in: hostDirectory), encoding: .utf8))?
      .lowercased() ?? ""
    return refusals.contains { log.contains($0) }
  }
}
