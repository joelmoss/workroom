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
  /// beside its own daemon's socket (`ResumeLaunchFile.directory`). Only `stageResume` writes
  /// launch files there, and it sweeps only a folder it made, by its `resumeMarker`.
  static func resumeFolder(besideSocket socket: String) -> String {
    (socket as NSString).deletingLastPathComponent + "/resume-launch"
  }

  /// The file `resumeFolder` holds when `stageResume` made it, and only then: its proof that the
  /// launch files in it are this code's to remove. The app's and the daemon's launch folders hold
  /// the same one, with the same contents (`ResumeLaunchFile.marker`, `resume::launch::MARKER`).
  static let resumeMarker = ".workroom-resume-launch-folder"
  /// What `resumeMarker` holds, which nothing else writes, without its final newline.
  static let resumeMarkerText =
    "Workroom made this folder for its resume launch files (ADR 0082), and removes only those."

  /// How old, in minutes, an unclaimed launch file in a marked `resumeFolder` must be before a
  /// later copy removes it, as the app's own (`ResumeLaunchFile.abandoned`): no attach waits that
  /// long, so another attach's fresh record is never touched. `find -mmin +60`, which GNU's,
  /// BSD's and busybox's `find` all hold true from an hour on.
  static let resumeAbandonedMinutes = 60

  /// A `case` pattern for the names `ResumeLaunchFile.name` makes, any session's:
  /// `resume-<session id, lowercase and hyphenated>-<32 hex>.json`, as `isLaunchName` checks.
  static let resumeLaunchNamePattern: String = {
    let hex = "[0123456789abcdef]"
    let run = { (count: Int) in String(repeating: hex, count: count) }
    return "resume-\(run(8))-\(run(4))-\(run(4))-\(run(4))-\(run(12))-\(run(32)).json"
  }()

  /// What the container's `sh` runs, as the remote user, to copy in a remote pane's resume record
  /// (#826), its bytes on stdin and its file's name (`ResumeLaunchFile.name`) as `$1`: into a new
  /// `0600` file in the `0700` `resumeFolder`, where the pane's attach finds it (`stagedResume`),
  /// whose client claims and removes it. The record's arguments can hold secrets, so they never
  /// travel on a command line, which a process listing shows.
  ///
  /// **Whose files these are**, by the rule the app's and the daemon's launch folders follow. The
  /// folder is made by a plain `mkdir`, which fails when it is already there, and only the copy
  /// whose `mkdir` made it writes `resumeMarker` in it, new (`set -C`) and `0600`. A folder found
  /// already there must be a real one this user owns (a link is refused, and `chmod` refuses one of
  /// another user's), and is never marked: one another build or the user made takes launch files
  /// but is never swept. In a marked folder (its marker a regular file this user owns, not a link,
  /// holding `resumeMarkerText`), launch files of any session (`resumeLaunchNamePattern`) are
  /// removed once they are at least `resumeAbandonedMinutes` old: an attach that never started
  /// left them, and none is waited for that long. Each is judged by `find -prune`, which follows no
  /// link, so only a regular file this user owns is removed; a link or a FIFO with such a name
  /// stays. A `find` that fails, or an image with none, removes nothing, and the record is still
  /// copied in.
  static func stageResume(session: UUID, socket: String) -> String {
    let folder = resumeFolder(besideSocket: socket)
    let parent = (folder as NSString).deletingLastPathComponent
    let mine = "resume-\(session.uuidString.lowercased())-"
    let own = { (path: String, type: String, test: String) in
      "test -n \"$(find \"\(path)\" -prune -type \(type) -user \"$u\"\(test) 2>/dev/null)\""
    }
    return "dir=\(PosixShell.quoted(folder)); case $1 in \(mine)*.json) ;; *) exit 1;; esac; "
      + "umask 077; u=$(id -u) || exit 1; m=\"$dir\"/\(resumeMarker); "
      + "t=\(PosixShell.quoted(resumeMarkerText)); "
      + "mkdir -p \(PosixShell.quoted(parent)) || exit 1; "
      + "if mkdir \"$dir\" 2>/dev/null; then made=1; else made=; fi; "
      + "test -d \"$dir\" && ! test -L \"$dir\" && chmod 700 \"$dir\" || exit 1; "
      + "if test -n \"$made\"; then (set -C; printf '%s\\n' \"$t\" > \"$m\") 2>/dev/null; fi; "
      + "if " + own("$m", "f", " -size -1024c")
      + " && test \"$(cat \"$m\"; echo x)\" = \"$(printf '%s\\nx' \"$t\")\"; then "
      + "for f in \"$dir\"/resume-*.json; do case ${f##*/} in \(resumeLaunchNamePattern)) ;; "
      + "*) continue;; esac; "
      + own("$f", "f", " -mmin +\(resumeAbandonedMinutes)") + " && rm -f \"$f\"; done; fi; "
      + "(set -C; cat > \"$dir/$1\")"
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
