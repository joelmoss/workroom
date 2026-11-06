import Foundation
import WorkroomDomain
import WorkroomSystem
import WorkroomVCS
import WorkroomWire

/// What one window's terminals report about themselves while they run, written onto their tabs: the
/// title (issue #2) and the coding agent and tool it names, the Claude profile that agent runs with
/// (#480), the cwd (issue #49), the branch of a Quick Terminal pane's folder, a remote pane's cwd on
/// its host (#239) and OSC 9;4 progress. `TerminalSessions` hands it each surface event as it is
/// raised, synchronously, inside the runtime callback that raised it.
///
/// One object per window, not one per tab: the reads it starts are keyed by tab, and `forget`
/// cancels a tab's when the tab leaves the window, by any route (close, reap, hand-off).
@MainActor
final class PaneLiveState {
  private let access: TerminalTabAccess
  private let codingAgentManager: TerminalCodingAgentManager

  /// The sessions' `PersistentSessionService`, kept in step by `TerminalSessions`.
  var sessionService: PersistentSessionService
  /// Where a remote pane's host-side working directory is asked for (#239). Settable for tests.
  var hostConnections: HostConnectionManager = .shared
  /// True for the Quick Terminal's sessions: its panes can each be in a different repository and no
  /// workroom knows their branch, so each reads its own (`TerminalState.liveBranch`).
  var readsPaneBranches = false
  /// How a pane's live branch is read (`TerminalState.liveBranch`). Settable for tests.
  var resolveBranch: @Sendable (String) async -> String? = {
    await GitRepositoryProbe().localBranch(path: $0, branch: nil)
  }

  /// How a foreground command not in the curated `ToolLogoRegistry` gets tallied (issue #141
  /// follow-up). Overridable in tests so exercising `titleChanged` never writes the developer's own
  /// `Application Support` file as a side effect — same reasoning as `makeView`.
  ///
  /// Two things the production default must do, found by review:
  /// - **Hop off the main thread.** `titleChanged` runs synchronously inside `ghostty_app_tick`
  ///   (`GhosttyApp.swift`'s render/IO pump, confirmed `DispatchQueue.main`-bound), and the dedup
  ///   gate here is a title-STRING change, not a per-executable-per-session memo — every distinct
  ///   command line typed in an uncurated shell (which is most ordinary commands) does a blocking
  ///   read-decode-encode-atomic-write if this ran inline. This app has two prior documented
  ///   AppHang incidents of exactly this shape (unbounded synchronous work in a main-thread runtime
  ///   callback) — this must not be a third.
  /// - **Skip under `AppEnvironment.current.isFixture`.** Every other side-effecting path added around this
  ///   era of the codebase gates on it; without it, any XCUITest run (or an ordinary `⌘R`/`make
  ///   app-run` Dev session) writes real entries into the same file the developer inspects for
  ///   curation signal, defeating the feature's own purpose.
  var recordUnrecognizedTool: (String) -> Void = { name in
    #if DEBUG
      if AppEnvironment.current.isFixture { return }
    #endif
    DispatchQueue.global(qos: .utility).async {
      UnrecognizedToolUsage.recordUnrecognized(name)
    }
  }

  /// Each remote tab's latest host cwd query. An entry also marks a tab whose first prompt has
  /// already asked, so after that only `command_finished` asks again.
  private var hostCwdQueries: [TerminalTab.ID: Task<Void, Never>] = [:]
  /// Each tab's in-flight Claude profile read (`readClaudeProfile`).
  private var claudeProfileQueries: [TerminalTab.ID: Task<Void, Never>] = [:]
  /// Each pane's in-flight branch read: a newer folder's must win over an older one's.
  private var branchQueries: [TerminalTab.ID: Task<Void, Never>] = [:]

  init(
    access: TerminalTabAccess, codingAgentManager: TerminalCodingAgentManager,
    sessionService: PersistentSessionService
  ) {
    self.access = access
    self.codingAgentManager = codingAgentManager
    self.sessionService = sessionService
  }

  /// Cancel `tabID`'s host cwd, Claude profile and branch reads in flight, and forget that its first
  /// prompt asked: every way a tab leaves the window (close, reap, hand-off) does this.
  func forget(_ tabID: TerminalTab.ID) {
    hostCwdQueries.removeValue(forKey: tabID)?.cancel()
    claudeProfileQueries.removeValue(forKey: tabID)?.cancel()
    branchQueries.removeValue(forKey: tabID)?.cancel()
  }

  // MARK: Surface reports

  /// A surface-reported title. The first one is the first prompt, which `command_finished` never
  /// marks, so it is also when a remote pane first asks its host where its shell is.
  func titleChanged(_ title: String, tab tabID: TerminalTab.ID, target: TerminalTarget.ID) {
    updateTitle(title, forTab: tabID, target: target)
    if hostCwdQueries[tabID] == nil {
      refreshHostCwd(forTab: tabID, target: target)
    }
  }

  /// The one writer of `TerminalState.cwd`: the surface's report, written to the tab in the call
  /// that records it on the surface (`handlePwd` raises `.cwdChanged` synchronously), so the status
  /// bar tracks it live (issue #49), a split starts in it and a saved layout keeps it.
  func cwdChanged(_ cwd: String, tab tabID: TerminalTab.ID, target: TerminalTarget.ID) {
    guard let s = access.state(tabID, target), s.cwd != cwd else { return }
    access.mutate(tabID, target) { $0.cwd = cwd }
    refreshBranch(forTab: tabID, target: target)
  }

  /// The shell returned to its prompt (OSC 133 D): drop the finished command's title back to the default
  /// (issue #2) and clear any OSC 9;4 progress, so the indicator stops the moment the command exits.
  func commandFinished(tab tabID: TerminalTab.ID, target: TerminalTarget.ID, exitCode: Int32?) {
    notifyCodingAgentOfCommandFinish(tabID: tabID, target: target, exitCode: exitCode)
    access.mutate(tabID, target) {
      $0.commandFinishGeneration += 1
      $0.liveTitle = nil
      $0.activeCodingAgentBackend = nil
      $0.claudeProfile = nil
      $0.activeTool = nil
      $0.progressActive = nil
      $0.progressFailed = false
    }
    refreshHostCwd(forTab: tabID, target: target)
    refreshBranch(forTab: tabID, target: target)
  }

  /// Apply an OSC 9;4 progress report (issue #28 follow-up). `active` is false only for the REMOVE state
  /// (the program declared itself idle/done) and true for any live progress (SET / INDETERMINATE / PAUSE
  /// / ERROR). This is the sole driver of `isRunning` — the spinner follows the program's own signal.
  /// `failed` (ERROR) drives `isProgressFailed`.
  func progressReported(
    _ active: Bool, failed: Bool, tab tabID: TerminalTab.ID, target: TerminalTarget.ID
  ) {
    guard let s = access.state(tabID, target),
      s.progressActive != active || s.progressFailed != failed
    else { return }
    access.mutate(tabID, target) {
      $0.progressActive = active
      $0.progressFailed = failed
    }
  }

  // MARK: Title, agent and tool

  /// Show a surface-reported command title on its tab; directory/prompt titles are ignored so the
  /// command sticks until `command_finished` clears it.
  private func updateTitle(_ title: String, forTab tabID: TerminalTab.ID, target: TerminalTarget.ID)
  {
    guard let s = access.state(tabID, target) else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !Self.isDirectoryTitle(trimmed, cwd: s.cwd) else {
      return
    }
    // Read once, for the agent and the tool alike: a second live PID read is a TOCTOU gap where the
    // foreground process could differ between the two reads (review finding). Not read at all for
    // a title the pane already shows: programs resend their title on every redraw, and the read
    // takes the engine's render lock and a `proc_name` call each time. A program recognised only
    // by its process name, under a title it did not change, is picked up at its next title.
    let foregroundExecutableName =
      s.liveTitle == trimmed ? nil : access.surface(tabID)?.foregroundExecutableName
    let detectedCodingAgent =
      CodingAgentProcessRecognition.backend(forProcessName: foregroundExecutableName)
      ?? CodingAgentTitleRecognition.backend(for: trimmed)
    let detectedTool =
      ToolLogoRegistry.tool(forExecutableName: foregroundExecutableName)
      ?? ToolLogoRegistry.tool(forTitle: trimmed)
    guard
      s.liveTitle != trimmed || (s.activeCodingAgentBackend == nil && detectedCodingAgent != nil)
        || (s.activeTool == nil && detectedTool != nil)
    else {
      return
    }
    // Usage tracking for issue #141: a genuinely new foreground command that ISN'T in the curated
    // registry at all (not merely missing its fetched asset — `matchingEntry` is the ungated check)
    // gets tallied, so a periodic look at the file shows which non-curated tools are worth adding
    // next. Gated on `s.liveTitle != trimmed` (a real title change, not a repaint of the same still-
    // unrecognized command) so a long-running unmatched program is counted once, not per repaint.
    if s.liveTitle != trimmed, detectedTool == nil,
      let rawName = foregroundExecutableName,
      ToolLogoRegistry.matchingEntry(forExecutableName: rawName) == nil
    {
      recordUnrecognizedTool(rawName)
    }
    let claudeStarted = s.activeCodingAgentBackend == nil && detectedCodingAgent == .claude
    // The title goes to its own observable; the tab map is republished only for a newly
    // recognised agent or tool, which other views show.
    s.liveTitle = trimmed
    let newAgent = s.activeCodingAgentBackend == nil ? detectedCodingAgent : nil
    let newTool = s.activeTool == nil ? detectedTool : nil
    if newAgent != nil || newTool != nil {
      access.mutate(tabID, target) {
        if $0.activeCodingAgentBackend == nil { $0.activeCodingAgentBackend = newAgent }
        if $0.activeTool == nil { $0.activeTool = newTool }
      }
    }
    if claudeStarted { readClaudeProfile(forTab: tabID, target: target) }
  }

  /// `NSHomeDirectory()` resolved once per process. It used to be `isDirectoryTitle`'s default
  /// argument, so it re-ran on every terminal title change, allocating through
  /// `NSHomeDirectoryForUser` → `-[NSURL path]` → `CFURLCopyFileSystemPath`. A process's home
  /// directory cannot change while it runs, so resolving it per title is waste.
  ///
  /// **Unmeasured.** WORKROOM-3P sampled the main thread here, which is how the call site was
  /// found, but one sample is not evidence this is hot — that is the whole point of
  /// `SentryConfig.appHangFingerprint`'s "the leaf is where the sample landed, not where the time
  /// went". This removes a per-title allocation; it does not explain 3P, and 3P stays open.
  static let cachedHomeDirectory = NSHomeDirectory()

  /// Whether `title` is just the working directory (the idle title the shell/prompt sets) rather than a
  /// running command — so the tab strip can ignore it (issue #2). Pure for testability.
  ///
  /// This MUST recognise every form a prompt emits for the cwd: a directory title that slips through is
  /// latched as a `liveTitle` and read as a running command (issue #28), but — being no real command — it
  /// never gets the `command_finished` that would clear it, so the sidebar spinner spins forever. The
  /// shipped zsh integration abbreviates deep paths (`%(4~|…/%3~|%~)` → "…/dir/dir/dir"), and bash's
  /// `PROMPT_DIRTRIM` truncates with ".../", so the full-path match alone isn't enough.
  static func isDirectoryTitle(_ title: String, cwd: String?, home: String = cachedHomeDirectory)
    -> Bool
  {
    guard let cwd, !cwd.isEmpty else { return false }
    var path = title
    if let colon = title.firstIndex(of: ":") {
      let prefix = title[..<colon]
      if prefix.contains("@"), !prefix.contains(" ") {
        path = String(title[title.index(after: colon)...])
      }
    }
    let tilde = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd

    // Full directory title (bash `\w`, zsh `%~` when the path is shallow enough to fit untruncated).
    if path == cwd || path == tilde { return true }

    // Truncated directory title: a shell abbreviates a deep path to an ellipsis marker plus a trailing
    // run of the path's own components (zsh "…/macapp/WorkroomApp", bash PROMPT_DIRTRIM ".../a/b"). It's
    // a directory title when, after the marker, it's a path-component suffix of the cwd (or its ~-form).
    for marker in ["…/", ".../"] where path.hasPrefix(marker) {
      let tail = path.dropFirst(marker.count)
      guard !tail.isEmpty else { return false }
      return cwd.hasSuffix("/" + tail) || tilde.hasSuffix("/" + tail)
    }
    return false
  }

  /// Build the failed-command context from the surface and hand it to the inline agent (issue #49).
  /// Captures synchronously — we're in the runtime callback before the next prompt renders, so
  /// `readCommandRegion()` returns the just-finished command's output (the A4 race fix, Swift-side).
  /// Gated on the feature flag so the screen read never runs when the agent is off.
  private func notifyCodingAgentOfCommandFinish(
    tabID: TerminalTab.ID, target: TerminalTarget.ID, exitCode: Int32?
  ) {
    guard codingAgentManager.isEnabled, let s = access.state(tabID, target) else { return }
    // Success and interrupts classify as `.skip` whatever was captured, so don't read the screen
    // for them: it is the whole scrollback, on the main thread, on every command (WORKROOM-3S).
    guard let exitCode, !FailureClassifier.boringExitCodes.contains(exitCode) else {
      codingAgentManager.commandFinished(tab: tabID, target: target, failure: nil)
      return
    }
    let view = access.surface(tabID)
    let failure = FailedCommand(
      command: s.liveTitle,
      cwd: s.cwd,
      exitCode: exitCode,
      shell: (ShellEnvironment.loginShell() as NSString).lastPathComponent,
      output: view?.readCommandRegion() ?? "",
      isRunTab: view?.isRunCommandSurface ?? false,
      isRemote: s.sessionID.map(sessionService.isRemote) ?? false)
    codingAgentManager.commandFinished(tab: tabID, target: target, failure: failure)
  }

  // MARK: Claude profile (#480)

  /// Ask workroomd which Claude profile the pane's new `claude` runs with (#480), so the pane footer
  /// can show that account's usage. Its session list is otherwise read only at launch, so this is
  /// the one moment it is asked again. Only a local daemon-backed pane can be asked: a remote one
  /// runs on a host whose login cannot be matched to a local account, and a fallback pane has no
  /// session.
  private func readClaudeProfile(forTab tabID: TerminalTab.ID, target: TerminalTarget.ID) {
    guard let s = access.state(tabID, target) else { return }
    guard let session = s.sessionID else {
      // No background session to ask (a Quick Terminal pane, or a shell opened while the helper
      // was down): the shell is this app's own child, so read it as workroomd would.
      let profile = access.surface(tabID).map(Self.localClaudeProfile(of:)) ?? .notReported
      access.mutate(tabID, target) {
        if $0.activeCodingAgentBackend == .claude { $0.claudeProfile = profile }
      }
      return
    }
    guard !sessionService.isRemote(session) else { return }
    let generation = s.commandFinishGeneration
    let service = sessionService
    claudeProfileQueries[tabID]?.cancel()
    claudeProfileQueries[tabID] = Task { [weak self] in
      let live = await service.liveSessions()
      guard let self, !Task.isCancelled else { return }
      let descriptor = live.first { $0.identifier.uuid == session }
      self.access.mutate(tabID, target) {
        // The command may have ended, or another started, while the list was in flight.
        guard $0.commandFinishGeneration == generation, $0.activeCodingAgentBackend == .claude
        else {
          return
        }
        $0.claudeProfile = Self.claudeProfile(from: descriptor)
      }
    }
  }

  /// A local pane's Claude profile from its foreground process, as workroomd reads it: only a
  /// confirmed `claude`'s environment, unset meaning the default login. A title alone names no
  /// account.
  static func localClaudeProfile(of view: GhosttySurfaceView) -> PaneClaudeProfile {
    guard
      CodingAgentProcessRecognition.backend(forProcessName: view.foregroundExecutableName)
        == .claude
    else { return .notReported }
    return .reported(
      view.foregroundPID.flatMap { ProcessEnvironment.value("CLAUDE_CONFIG_DIR", pid: $0) } ?? "")
  }

  /// The profile entry from a session descriptor; no entry means the daemon cannot say (too old, or
  /// the foreground is not a confirmed `claude`).
  nonisolated static func claudeProfile(from descriptor: SessionDescriptor?) -> PaneClaudeProfile {
    descriptor?.value(forMetadataKey: "claude_profile").map(PaneClaudeProfile.reported)
      ?? .notReported
  }

  // MARK: Host cwd (#239)

  /// Ask a remote pane's host where its shell is now (#239), and show it in the status bar.
  ///
  /// Asked when the shell is back at its prompt (a `cd` is a command, so it ends in
  /// `command_finished`), which is when a local pane's OSC 7 arrives too. Not on every title: a TUI
  /// that animates its title, such as an agent's spinner, would send a request per frame. A newer
  /// query replaces an older one, so a slow answer never lands on top of a fresh one. A no-op for a
  /// local pane. For a remote one whose host has no connection yet, it waits for one: nothing
  /// connects to a host to answer this.
  private func refreshHostCwd(forTab tabID: TerminalTab.ID, target: TerminalTarget.ID) {
    guard let s = access.state(tabID, target), let session = s.sessionID,
      let host = sessionService.remoteHost(of: session)
    else { return }
    hostCwdQueries[tabID]?.cancel()
    let connections = hostConnections
    hostCwdQueries[tabID] = Task { [weak self] in
      // Asked once the host has a service connection, which a restored pane's first prompt can
      // come before. Waited for here, in the query's own task, so a newer query still replaces
      // this one and closing the pane still ends the wait; nothing here connects the host.
      for await snapshot in await connections.updates(for: host)
      where snapshot.status == .connected {
        // A failed query keeps what the footer shows; an answer of "no such session" or "could not
        // read it" clears it, rather than leaving a directory the shell may have left.
        let cwd: String?
        do {
          cwd = try await connections.workingDirectory(of: session, on: host)
        } catch RepositoryRoutingError.unavailable {
          continue  // Lost again between the snapshot and the ask: wait for the next one.
        } catch { return }
        guard !Task.isCancelled else { return }
        self?.access.mutate(tabID, target) { $0.hostCwd = cwd }
        return
      }
    }
  }

  // MARK: Branch

  /// Re-read the branch of a Quick Terminal pane's folder: when it opens, changes folder, and after
  /// each command (a `git switch` changes it in place). Workroom panes read theirs from the
  /// workroom, so nothing runs for them.
  func refreshBranch(forTab tabID: TerminalTab.ID, target: TerminalTarget.ID) {
    guard readsPaneBranches, let state = access.state(tabID, target) else { return }
    let path = state.cwd ?? state.launchDirectory
    let resolveBranch = resolveBranch
    branchQueries[tabID]?.cancel()
    branchQueries[tabID] = Task { [weak self] in
      let branch = await resolveBranch(path)
      guard let self, !Task.isCancelled else { return }
      self.access.mutate(tabID, target) { $0.liveBranch = branch }
    }
  }

  /// Wait for a pane's branch read in flight. For tests.
  func branchRead(forTab tabID: TerminalTab.ID) async { await branchQueries[tabID]?.value }
}
