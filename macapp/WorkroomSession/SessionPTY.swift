import Darwin
import WorkroomSessionProtocol

struct SessionProcess {
  let masterDescriptor: Int32
  let processID: pid_t
  let ttyDevice: UInt64
}

enum SessionPTY {
  private static let resetSignals: [Int32] = [
    SIGPIPE, SIGCHLD, SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU,
  ]
  private static let terminationPollMicroseconds: useconds_t = 10000
  private static let gracefulTerminationAttempts = 20
  private static let forcedTerminationAttempts = 50

  static func spawn(
    invocation: SessionShellInvocation,
    workingDirectory: String,
    columns: UInt16,
    rows: UInt16
  ) -> SessionProcess? {
    let argumentList = SessionCStringArray(invocation.arguments)
    let environmentList = SessionCStringArray(
      invocation.environment.map { "\($0.key)=\($0.value)" })
    guard let executable = strdup(invocation.executable) else { return nil }
    let directory = strdup(workingDirectory)
    defer {
      free(executable)
      free(directory)
    }

    // The classic self-pipe trick for synchronous fork/exec error reporting: both ends are
    // close-on-exec, so a SUCCESSFUL execve closes the child's copy of the write end as part of
    // the exec syscall itself, and the parent's blocking read below observes that as EOF. A
    // FAILED execve never reaches that closure — the child is still running our Swift code, so it
    // writes its errno first. Without this, `forkpty` returning a pid tells the parent only that
    // fork succeeded, not that the child ever reached its shell; a bad shell path or resources
    // directory would ack the attach as created, then close moments later with no explanation.
    var execErrorPipe: [Int32] = [-1, -1]
    guard pipe(&execErrorPipe) == 0 else {
      SessionLog.write("pipe failed: \(String(cString: strerror(errno)))")
      return nil
    }
    let execErrorReadDescriptor = execErrorPipe[0]
    let execErrorWriteDescriptor = execErrorPipe[1]
    SessionIO.setCloseOnExec(execErrorReadDescriptor)
    SessionIO.setCloseOnExec(execErrorWriteDescriptor)

    var size = winsize(
      ws_row: rows == 0 ? 24 : rows,
      ws_col: columns == 0 ? 80 : columns,
      ws_xpixel: 0,
      ws_ypixel: 0)
    var master: Int32 = -1
    var name = [CChar](repeating: 0, count: Int(PATH_MAX))

    let processID = forkpty(&master, &name, nil, &size)
    if processID < 0 {
      SessionLog.write("forkpty failed: \(String(cString: strerror(errno)))")
      SessionIO.close(execErrorReadDescriptor)
      SessionIO.close(execErrorWriteDescriptor)
      return nil
    }

    if processID == 0 {
      SessionIO.close(execErrorReadDescriptor)
      var empty = sigset_t()
      sigemptyset(&empty)
      sigprocmask(SIG_SETMASK, &empty, nil)
      for number in resetSignals {
        signal(number, SIG_DFL)
      }
      if let directory, chdir(directory) != 0 {
        if let home = getenv("HOME") {
          _ = chdir(home)
        } else {
          _ = chdir("/")
        }
      }
      execve(executable, argumentList.pointer, environmentList.pointer)
      var failureErrno = errno
      withUnsafeBytes(of: &failureErrno) { bytes in
        _ = Darwin.write(execErrorWriteDescriptor, bytes.baseAddress, bytes.count)
      }
      _exit(127)
    }

    // Parent must close its own copy of the write end before reading — otherwise the pipe never
    // fully closes on a successful exec (the child's copy closes, but ours would still hold it
    // open), and the read below would block forever instead of observing EOF.
    SessionIO.close(execErrorWriteDescriptor)
    var execFailureErrno: Int32 = 0
    let errorByteCount = withUnsafeMutableBytes(of: &execFailureErrno) { buffer -> Int in
      var total = 0
      while total < buffer.count {
        let result = Darwin.read(
          execErrorReadDescriptor, buffer.baseAddress!.advanced(by: total), buffer.count - total)
        if result > 0 {
          total += result
          continue
        }
        if result < 0, errno == EINTR { continue }
        break
      }
      return total
    }
    SessionIO.close(execErrorReadDescriptor)
    guard errorByteCount == 0 else {
      SessionLog.write("execve failed: \(String(cString: strerror(execFailureErrno)))")
      SessionIO.close(master)
      return nil
    }

    SessionIO.setNonBlocking(master)
    SessionIO.setCloseOnExec(master)

    var status = stat()
    let device: UInt64 =
      stat(&name, &status) == 0
      ? UInt64(UInt32(bitPattern: status.st_rdev))
      : 0

    return SessionProcess(masterDescriptor: master, processID: processID, ttyDevice: device)
  }

  static func resize(masterDescriptor: Int32, columns: UInt16, rows: UInt16) {
    var size = winsize(
      ws_row: rows == 0 ? 24 : rows,
      ws_col: columns == 0 ? 80 : columns,
      ws_xpixel: 0,
      ws_ypixel: 0)
    _ = ioctl(masterDescriptor, TIOCSWINSZ, &size)
  }

  static func windowSize(descriptor: Int32) -> (columns: UInt16, rows: UInt16)? {
    var size = winsize()
    guard ioctl(descriptor, TIOCGWINSZ, &size) == 0 else { return nil }
    return (size.ws_col, size.ws_row)
  }

  static func foregroundProcessGroup(masterDescriptor: Int32) -> pid_t? {
    let group = tcgetpgrp(masterDescriptor)
    return group > 0 ? group : nil
  }

  /// The basename of `argv[0]` as the process was originally exec'd (e.g. `claude`, `vim`), or nil
  /// if it can't be resolved. Deliberately NOT `proc_name`/`p_comm`: some CLIs (Claude Code among
  /// them, observed in the wild) rename their own process title after launch — `p_comm` then reads
  /// as their version string ("2.1.232"), not the command a user typed. `KERN_PROCARGS2` returns
  /// the ORIGINAL exec-time argv snapshot, unaffected by any later self-renaming, and matches what
  /// the shell's own preexec title-report already uses for a live (non-reattached) pane.
  static func executableName(processID: pid_t) -> String? {
    guard processID > 0 else { return nil }
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, processID]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }

    let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    guard argc > 0 else { return nil }

    // Layout: argc, then the exec path (NUL-terminated), then NUL padding, then argv[0..argc-1]
    // each NUL-terminated. Skip the exec path and padding to reach argv[0].
    var offset = 4
    while offset < size, buffer[offset] != 0 { offset += 1 }
    while offset < size, buffer[offset] == 0 { offset += 1 }
    guard offset < size else { return nil }

    let start = offset
    while offset < size, buffer[offset] != 0 { offset += 1 }
    guard offset > start else { return nil }
    let argv0 = String(decoding: buffer[start..<offset], as: UTF8.self)
    guard let lastSlash = argv0.lastIndex(of: "/") else { return argv0 }
    // A trailing slash (argv0 == "foo/") makes this slice empty — nil, not "", so a caller's
    // `if let name` doesn't pass through and synthesize a blank title.
    let basename = argv0[argv0.index(after: lastSlash)...]
    return basename.isEmpty ? nil : String(basename)
  }

  /// A process's current working directory, or nil if it can't be resolved.
  static func workingDirectory(processID: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = proc_pidinfo(
      processID, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
    guard size == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
    return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
      raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) }
    }
  }

  /// Row count to bump a pty to, transiently, to force an observable size delta.
  ///
  /// A bare `SIGWINCH` is not enough to make a full-screen program repaint on reattach: the pty's
  /// real size is already correct (it never changed while the session sat alive in the
  /// background), so a program that checks "did the terminal size actually change" before
  /// repainting — observed with Claude Code; Codex repaints regardless — silently ignores it,
  /// leaving the new client showing stale primary-screen content underneath the (unpainted)
  /// alternate screen until a genuine later resize forces a real delta.
  ///
  /// Bumping the row count down (or up, at the 1-row floor) then back — the same trick tmux/screen
  /// use to force a client redraw on attach — guarantees the child observes an actual size
  /// transition either way. Pure arithmetic only: the daemon owns *when* to resize back and signal
  /// (`SessionDaemon`'s deferred redraw scheduling), since giving the child time to actually observe
  /// the transient size before reverting it needs a real delay — and this single-threaded daemon
  /// serves every session across every open project, so that delay must not block its poll loop.
  static func bumpedRowCount(_ rows: UInt16) -> UInt16 {
    rows > 1 ? rows - 1 : rows + 1
  }

  static func requestRedraw(masterDescriptor: Int32, fallbackProcessID: pid_t) {
    let group = foregroundProcessGroup(masterDescriptor: masterDescriptor) ?? fallbackProcessID
    guard group > 0 else { return }
    _ = killpg(group, SIGWINCH)
  }

  static func terminate(processID: pid_t) {
    guard processID > 0 else { return }
    if killpg(processID, SIGHUP) != 0 {
      _ = kill(processID, SIGHUP)
    }
    _ = killpg(processID, SIGCONT)
  }

  static func forceTerminate(processID: pid_t) -> Bool {
    forceTerminate(processIDs: [processID]).isEmpty
  }

  static func forceTerminate(processIDs: [pid_t]) -> Set<pid_t> {
    let roots = Set(processIDs.filter { $0 > 0 })
    guard !roots.isEmpty else { return [] }
    // A shell can `setsid()` a descendant into its OWN new session (a deliberate double fork, rare
    // but not impossible from inside a persisted shell) — at that point it's escaped both `killpg`
    // (process-group scoping) and the `getsid`-based matching below (session scoping), since it is
    // now the leader of a session nothing here is tracking. Snapshotting the process tree by
    // PARENT pid, once, up front, finds it anyway: whatever session it has since made itself
    // leader of, its ppid still chains back to a root here (unless an intermediate ancestor has
    // ALREADY exited and it's been reparented to launchd — a real but much narrower race than the
    // one this closes, and not one `pkill`-style tooling solves without pid namespaces either).
    // Each descendant is tracked as its own additional target, so the existing per-session
    // signal/wait loop below needs no other change to reach it.
    let targets = roots.union(descendantProcessIDs(of: roots))

    signalSessions(targets, signal: SIGTERM)
    let resistant = waitForSessionsExit(targets, attempts: gracefulTerminationAttempts)
    guard !resistant.isEmpty else { return [] }

    signalSessions(resistant, signal: SIGKILL)
    return waitForSessionsExit(
      resistant, attempts: forcedTerminationAttempts, repeatedSignal: SIGKILL)
  }

  private static func signalSessions(_ sessionIDs: Set<pid_t>, signal: Int32) {
    guard let members = sessionProcessIDs(sessionIDs: sessionIDs) else {
      for sessionID in sessionIDs {
        _ = killpg(sessionID, signal)
        _ = kill(sessionID, signal)
      }
      return
    }
    signalSessions(sessionIDs, members: members, signal: signal)
  }

  private static func signalSessions(
    _ sessionIDs: Set<pid_t>, members: [pid_t: [pid_t]], signal: Int32
  ) {
    for sessionID in sessionIDs {
      let memberProcessIDs = members[sessionID] ?? []
      if memberProcessIDs.isEmpty {
        _ = kill(sessionID, signal)
        continue
      }
      for memberProcessID in memberProcessIDs {
        _ = kill(memberProcessID, signal)
      }
    }
  }

  private static func waitForSessionsExit(
    _ sessionIDs: Set<pid_t>,
    attempts: Int,
    repeatedSignal: Int32? = nil
  ) -> Set<pid_t> {
    var remaining = sessionIDs
    for _ in 0..<attempts {
      reap(processIDs: remaining)
      guard let members = sessionProcessIDs(sessionIDs: remaining) else {
        usleep(terminationPollMicroseconds)
        continue
      }
      remaining = activeSessionIDs(remaining, members: members)
      guard !remaining.isEmpty else { return [] }
      if let repeatedSignal {
        signalSessions(remaining, members: members, signal: repeatedSignal)
      }
      usleep(terminationPollMicroseconds)
    }

    reap(processIDs: remaining)
    guard let members = sessionProcessIDs(sessionIDs: remaining) else { return remaining }
    return activeSessionIDs(remaining, members: members)
  }

  private static func activeSessionIDs(_ sessionIDs: Set<pid_t>, members: [pid_t: [pid_t]])
    -> Set<pid_t>
  {
    sessionIDs.filter { processExists($0) || !(members[$0] ?? []).isEmpty }
  }

  private static func reap(processIDs: Set<pid_t>) {
    for processID in processIDs {
      var status: Int32 = 0
      while waitpid(processID, &status, WNOHANG) < 0, errno == EINTR {}
    }
  }

  private static func processExists(_ processID: pid_t) -> Bool {
    guard kill(processID, 0) != 0 else { return true }
    return errno == EPERM
  }

  private static func sessionProcessIDs(sessionIDs: Set<pid_t>) -> [pid_t: [pid_t]]? {
    guard let records = snapshotProcesses() else { return nil }
    var members: [pid_t: [pid_t]] = [:]
    for record in records {
      let processID = record.kp_proc.p_pid
      guard processID > 0 else { continue }
      let sessionID = getsid(processID)
      guard sessionIDs.contains(sessionID) else { continue }
      members[sessionID, default: []].append(processID)
    }
    return members
  }

  /// Every transitive descendant of `roots`, found by walking parent-pid links rather than
  /// session/group membership — the only way to still find a descendant that has `setsid()`'d
  /// itself into its own session. Returns an empty set (never `nil`) on a scan failure: the caller
  /// already falls back to signaling `roots` alone, exactly as it did before this existed.
  private static func descendantProcessIDs(of roots: Set<pid_t>) -> Set<pid_t> {
    guard let records = snapshotProcesses() else { return [] }
    var childrenByParent: [pid_t: [pid_t]] = [:]
    for record in records {
      let processID = record.kp_proc.p_pid
      guard processID > 0 else { continue }
      childrenByParent[record.kp_eproc.e_ppid, default: []].append(processID)
    }

    var descendants: Set<pid_t> = []
    var frontier = Array(roots)
    while !frontier.isEmpty {
      var next: [pid_t] = []
      for parent in frontier {
        for child in childrenByParent[parent] ?? []
        where !descendants.contains(child) && !roots.contains(child) {
          descendants.insert(child)
          next.append(child)
        }
      }
      frontier = next
    }
    return descendants
  }

  private static func snapshotProcesses() -> [kinfo_proc]? {
    let stride = MemoryLayout<kinfo_proc>.stride
    for _ in 0..<3 {
      var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
      var size = 0
      guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

      var records = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
      size = records.count * stride
      if sysctl(&name, 3, &records, &size, nil, 0) != 0 {
        guard errno == ENOMEM else { return nil }
        continue
      }
      return Array(records.prefix(size / stride))
    }
    return nil
  }
}
