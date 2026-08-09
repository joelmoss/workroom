import Foundation
import OSLog

/// Offers to reopen an agent conversation in a restored pane (issue #145).
///
/// Deliberately **not** part of `TerminalAgentManager`, which owns failure classification and
/// diagnosis. Two reasons, and the first is a bug rather than a preference:
///
/// - `AgentBannerState` is failure-shaped — every case carries a `FailedCommand`, and
///   `failureAndDiagnosis` hands back a non-optional one that `AgentPrompt.investigateCommandLine`
///   destructures. A resume offer has no failed command.
/// - `TerminalAgentManager.banners` is **one slot per tab**, so an offer and a diagnosis would evict
///   each other. Concretely: a restored pane offers Resume, the user runs a command, it fails,
///   `commandFinished` overwrites the offer and it never comes back. Discovery is async, so the
///   reverse happens too — a late offer landing on top of a live `.loading` diagnosis.
///
/// The lifecycles differ as much as the states do. A diagnosis is triggered by an event in the pane
/// and costs an API call the user asked for; an offer is triggered by launch, costs a bounded
/// filesystem scan, and its action **spends the user's money**. That last point is why `consume` is
/// the only way to read an invocation out.
@MainActor
final class AgentResumeCoordinator: ObservableObject {
  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "agent-resume")

  /// Which agents a restored pane can be resumed into. Empty entries are never stored, so
  /// `offers[tab] != nil` means there is something to show.
  ///
  /// A `Set`, not an array: two `.claude` offers are meaningless, and array order would quietly
  /// acquire semantics ("the first one is the likely one") that this feature has no basis for —
  /// the app cannot know which agent a pane was running.
  @Published private(set) var offers: [TerminalTab.ID: Set<AgentBackend>] = [:]

  /// The directory each offer was matched against, so `consume` can refuse a pane that has since
  /// moved. Kept beside `offers` rather than inside it because the view has no use for it.
  private var offerCwds: [TerminalTab.ID: String] = [:]

  /// A cancellation flag the scan can read from its own queue.
  ///
  /// `DispatchWorkItem.isCancelled` would do, but reading it means capturing the work item inside its
  /// own closure, and the obvious workaround — hopping to the main actor to ask — is a
  /// `DispatchQueue.main.sync` from a utility queue on every directory entry: slow at best, a
  /// deadlock at worst. A lock-guarded flag is readable from anywhere and cheap enough to check in a
  /// loop.
  private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
    }
  }

  private let index: AgentSessionIndex?
  private let queue = DispatchQueue(
    label: "com.developwithstyle.workroom.agent-resume", qos: .utility)
  private var discovery: CancellationFlag?
  /// Tabs whose offer must not be published, because the pane is gone or its offer was already
  /// spent.
  ///
  /// Only meaningful while a scan is in flight — its whole job is to stop `publish` re-offering a
  /// pane that was closed, typed into, or resumed while the scan ran. So it is cleared once the scan
  /// lands. An earlier version never pruned it, on the stated grounds that it was "bounded by the
  /// number of tabs a launch restores"; that was wrong, because `tabClosed` fires for EVERY tab
  /// closed in the process, restored or not, so it grew for the life of the app.
  private var abandoned: Set<TerminalTab.ID> = []

  /// `index: nil` disables discovery entirely — the fixture default, so the existing UI tests can
  /// never read the developer's real `~/.claude` (issue #46 drew the same line for the session file).
  init(index: AgentSessionIndex? = AgentSessionIndex()) {
    self.index = index
  }

  // MARK: Discovery

  /// Look for resumable conversations for the panes a restore just produced.
  ///
  /// **Fire and forget, and never awaited by the restore.** `restorePersistedSessionIfPending` ends
  /// with `finishSessionRestore()` in a `defer`, and issue #46's watchdog freezes session writes for
  /// the whole run if any window is still outstanding 15 seconds in. Blocking that on a filesystem
  /// scan would trade a nice-to-have button for the user's session persistence — the exact failure
  /// #46 built the watchdog to prevent.
  ///
  /// One scan for all panes, on a utility queue rather than a task per pane: the work is blocking
  /// file IO, which starves the cooperative pool (the bug behind the History pane's forever-spinner).
  func discover(_ restored: [TerminalSessions.RestoredTerminal], savedAt: Date) {
    guard let index, !restored.isEmpty else { return }
    discovery?.cancel()

    // Distinct directories only: a workroom with four restored panes is one directory to scan.
    let cwds = Array(Set(restored.map(\.cwd)))
    let flag = CancellationFlag()
    discovery = flag
    queue.async { [weak self] in
      let found = index.backends(
        forCwds: cwds, savedAt: savedAt, isCancelled: { flag.isCancelled })
      guard !flag.isCancelled else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.publish(found, for: restored, flag: flag) }
      }
    }
  }

  private func publish(
    _ found: [String: Set<AgentBackend>], for restored: [TerminalSessions.RestoredTerminal],
    flag: CancellationFlag
  ) {
    // A scan superseded or cancelled while it was hopping back to the main actor publishes nothing.
    guard discovery === flag, !flag.isCancelled else { return }
    discovery = nil
    var offered = 0
    for pane in restored {
      // Dropped only when the pane itself is gone or its offer was spent — NOT when it stopped being
      // the selected tab. A background pane keeps its offer; that is the point of restoring several.
      guard !abandoned.contains(pane.tabID) else { continue }
      guard let backends = found[pane.cwd], !backends.isEmpty else { continue }
      offers[pane.tabID] = backends
      offerCwds[pane.tabID] = pane.cwd
      offered += 1
    }
    // The scan has landed, so the suppression list has done its job. Clearing it is what keeps it
    // from growing for the life of the process on every tab close.
    abandoned.removeAll()
    if offered > 0 {
      Self.logger.notice("resume offers published for \(offered, privacy: .public) restored panes")
    }
  }

  // MARK: Acting

  /// Take the offer and hand back the command to run — **atomically**.
  ///
  /// The offer is removed before the invocation is returned, so this can only succeed once. That is
  /// not tidiness: the action starts a billed agent session, and a double-click, a SwiftUI re-render
  /// firing the button's action twice, or two windows racing on the same pane would otherwise each
  /// start one. Returning nil on the second call is the button being spent, not an error.
  /// `liveCwd` is the pane's CURRENT directory, when it has reported one. The offer was matched
  /// against the directory the pane was restored into, and a shell hook (`direnv`, a `cd` in
  /// `.zshrc`, a project activator) can move it before the user ever touches the keyboard — none of
  /// which trips the pristine guard. Resuming there would open a picker listing a different
  /// project's conversations, which is precisely the confident-wrong-answer this feature refuses to
  /// give. A moved pane spends the offer and returns nothing.
  func consume(tab: TerminalTab.ID, backend: AgentBackend, liveCwd: String? = nil)
    -> AgentInvocation?
  {
    guard let backends = offers[tab], backends.contains(backend) else { return nil }
    offers[tab] = nil
    abandoned.insert(tab)
    if let liveCwd, let matched = offerCwds[tab],
      !AgentSessionIndex.pathsMatch(matched, liveCwd)
    {
      offerCwds[tab] = nil
      Self.logger.notice("resume offer dropped — the pane's directory changed since discovery")
      return nil
    }
    offerCwds[tab] = nil
    return AgentInvocationBuilder.resume(backend)
  }

  /// The pane received input, so it is no longer pristine (issue #145).
  ///
  /// Discovery is async: by the time an offer lands the user may already be halfway through typing a
  /// command, and appending `claude --resume` plus Return to a dirty input line runs something
  /// nobody asked for. Dropping the offer on the first keystroke is the fix. The alternative — a
  /// `Ctrl-U` kill-line before typing — is shell-dependent and destroys whatever they had typed, so
  /// it trades a wrong command for lost work.
  func paneReceivedInput(tab: TerminalTab.ID) {
    offers[tab] = nil
    offerCwds[tab] = nil
    // Only worth remembering while a scan could still publish for it; see `abandoned`.
    if discovery != nil { abandoned.insert(tab) }
  }

  /// The pane went away: drop its offer and make sure an in-flight scan cannot resurrect it.
  func tabClosed(_ tab: TerminalTab.ID) {
    offers[tab] = nil
    offerCwds[tab] = nil
    if discovery != nil { abandoned.insert(tab) }
  }

  /// Cancel any scan still running — the offers it would publish are for panes nobody is waiting on.
  func cancelDiscovery() {
    discovery?.cancel()
    discovery = nil
    // Nothing can publish now, so the suppression list has nothing left to suppress.
    abandoned.removeAll()
  }
}
