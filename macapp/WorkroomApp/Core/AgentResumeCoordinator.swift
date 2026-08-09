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
  /// spent. Never pruned: it is bounded by the number of tabs a launch restores, and forgetting an
  /// entry would let a late scan re-offer a pane the user already resumed.
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
      offered += 1
    }
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
  func consume(tab: TerminalTab.ID, backend: AgentBackend) -> AgentInvocation? {
    guard let backends = offers[tab], backends.contains(backend) else { return nil }
    offers[tab] = nil
    abandoned.insert(tab)
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
    abandoned.insert(tab)
  }

  /// The pane went away: drop its offer and make sure an in-flight scan cannot resurrect it.
  func tabClosed(_ tab: TerminalTab.ID) {
    offers[tab] = nil
    abandoned.insert(tab)
  }

  /// Cancel any scan still running — the offers it would publish are for panes nobody is waiting on.
  func cancelDiscovery() {
    discovery?.cancel()
    discovery = nil
  }
}
