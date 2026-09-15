import Darwin
import WorkroomSessionProtocol

/// Become an ordinary shell, because this relay could not deliver the session it was sent for.
///
/// The mirror of `wr-agent`'s `fall_back_to_shell`, and it exists for exactly the same reason: the
/// app chooses session-or-plain-shell BEFORE it forks anything — `applyPersistentSession` either
/// hands libghostty this command or lets it open a shell — and `config.wait_after_command` is
/// false, so a relay that exits leaves a pane with no shell in it at all. No error is readable
/// there, because there is nothing to read it in. The last process able to turn a failed attach
/// into a working terminal is this one.
///
/// Without it the two relays behind one feature failed differently: a wedged v2.0.0 daemon
/// destroyed a pane, while the same failure against the agent degraded to a shell.
enum SessionAttachFallback {
  /// Never returns on success — `execve` replaces this process, so the shell inherits the pty, the
  /// title, and the exit status, exactly as it would in any other terminal.
  static func becomeShell(configuration: SessionAttachClient.Configuration) -> Never? {
    // The terminal is in raw mode by now if the attach got that far, and `execve` runs no
    // deferred blocks. A shell handed a raw tty has no line editing, no echo and no signal keys,
    // which is a worse terminal than the dead pane this is preventing.
    var restored = termios()
    if tcgetattr(STDIN_FILENO, &restored) == 0 {
      restored.c_lflag |= UInt(ECHO | ICANON | ISIG)
      restored.c_iflag |= UInt(ICRNL)
      restored.c_oflag |= UInt(OPOST)
      tcsetattr(STDIN_FILENO, TCSANOW, &restored)
    }

    SessionIO.writeAll(
      STDERR_FILENO,
      Array(
        ("workroom-session: this terminal will not survive quitting Workroom\r\n").utf8))

    // The same invocation the daemon would have run for this session, so the pane keeps its login
    // profile and ghostty's shell integration (OSC 133/OSC 7) rather than getting a bare shell.
    let shell =
      configuration.shell.isEmpty
      ? SessionShellIntegration.defaultShell : configuration.shell
    // Basename without Foundation: this target imports Darwin only.
    let name = shell.split(separator: "/").last.map(String.init) ?? shell
    // A leading dash on argv[0] is the only thing that makes a login shell; there is no flag.
    var argv: [String] = ["-\(name)"]
    var program = shell
    if !configuration.command.isEmpty {
      program = "/bin/sh"
      argv = ["sh", "-c", "exec \(configuration.command)"]
    }

    // Requested directory, then home, then root — whichever `chdir` will actually accept. Checking
    // `isDirectory` first is not the same test: a directory can exist and still refuse `chdir` for
    // want of the execute bit.
    for candidate in [
      configuration.workingDirectory, SessionProcessEnvironment.value("HOME") ?? "", "/",
    ] where !candidate.isEmpty {
      if chdir(candidate) == 0 { break }
    }

    // Nothing downstream should believe it is inside a session that does not exist.
    unsetenv("WORKROOM_SESSION_ID")
    unsetenv("WORKROOM_SESSION_SOCKET")
    setenv("WORKROOM_SESSION_FALLBACK", "1", 1)

    let argvPointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    _ = argvPointers.withUnsafeBufferPointer { buffer in
      execv(program, buffer.baseAddress!)
    }
    // Only reached when exec itself failed; the caller exits with the original status.
    SessionIO.writeAll(
      STDERR_FILENO, Array("workroom-session: could not start \(program)\r\n".utf8))
    return nil
  }
}
