/// The default login shell, shared by the app and the attach client.
///
/// Everything else that lived here — `SessionShellInvocation`, `invocation(...)` and the
/// per-shell integration wiring — was deleted with the daemon: its sole caller was
/// `SessionPTY.spawn`, and the only process that still spawns a session shell is the Rust agent,
/// whose `wr_agent::shell::invocation` is the live twin.
public enum SessionShellIntegration {
  public static let defaultShell = "/bin/zsh"
}
