import Foundation

/// What the Quick Terminal's footer shows: its shell's folder, that folder's branch and the coding
/// agent running in it. A pane gets these from `TerminalSessions`; the Quick Terminal has no tab,
/// so it follows its own surface the same way (`TerminalSessions.updateCwd`, `updateTitle`,
/// `handleCommandFinished`).
@MainActor
final class QuickTerminalStatus: ObservableObject {
  @Published private(set) var cwd: String
  /// Nil outside a git repository and on a detached HEAD.
  @Published private(set) var branch: String?
  @Published private(set) var backend: CodingAgentBackend?
  /// Which Claude login the running `claude` bills, so the footer shows that account's usage.
  @Published private(set) var claudeProfile: PaneClaudeProfile?

  private let resolveBranch: @Sendable (String) async -> String?
  private var branchLookup: Task<Void, Never>?
  private var lastTitle: String?

  init(
    cwd: String,
    resolveBranch: @escaping @Sendable (String) async -> String? = {
      await WorkroomStatusResolver().localBranch(path: $0, branch: nil)
    }
  ) {
    self.cwd = cwd
    self.resolveBranch = resolveBranch
    refreshBranch()
  }

  /// Follow `surface`'s shell. Wired once, when the window is made.
  func follow(_ surface: GhosttySurfaceView) {
    surface.onCwdChange = { [weak self] in self?.cwdChanged($0) }
    surface.onTitleChange = { [weak self, weak surface] title in
      guard let surface else { return }
      self?.titleChanged(title, on: surface)
    }
    surface.onCommandFinished = { [weak self] _ in self?.commandFinished() }
  }

  func cwdChanged(_ cwd: String) {
    guard cwd != self.cwd else { return }
    self.cwd = cwd
    refreshBranch()
  }

  /// A program's title: recognise a coding agent starting, as a pane does. The foreground process is
  /// read only for a new title; programs resend theirs on every redraw.
  func titleChanged(_ title: String, on surface: GhosttySurfaceView) {
    guard backend == nil, title != lastTitle else { return }
    lastTitle = title
    let byProcess = CodingAgentProcessRecognition.backend(
      forProcessName: surface.foregroundExecutableName)
    guard let found = byProcess ?? CodingAgentTitleRecognition.backend(for: title) else { return }
    backend = found
    guard found == .claude else { return }
    // As workroomd reads it: only a confirmed `claude` process's environment, unset meaning the
    // default login. A title alone names no account.
    claudeProfile =
      byProcess == .claude
      ? .reported(
        surface.foregroundPID.flatMap { ProcessEnvironment.value("CLAUDE_CONFIG_DIR", pid: $0) }
          ?? "")
      : .notReported
  }

  /// Back at the prompt: the agent is gone, and the command may have switched branches.
  func commandFinished() {
    backend = nil
    claudeProfile = nil
    lastTitle = nil
    refreshBranch()
  }

  /// The latest lookup wins: one for an older folder must not land after a newer one's.
  private func refreshBranch() {
    branchLookup?.cancel()
    let path = cwd
    let resolveBranch = resolveBranch
    branchLookup = Task { [weak self] in
      let branch = await resolveBranch(path)
      guard !Task.isCancelled else { return }
      self?.branch = branch
    }
  }

  /// For tests: wait for the branch lookup in flight.
  func branchLookupFinished() async { await branchLookup?.value }
}
