import Defaults
import Foundation

/// A captured failed command, ready to diagnose (issue #49). The host builds this from the surface
/// view (command + cwd from shell integration, exit code from `command_finished`, `output` from
/// `readCommandRegion`); passing a value type keeps `TerminalAgentManager` testable without a live
/// terminal. `output` is the tidied capture; the manager applies redaction before sending.
struct FailedCommand: Equatable, Sendable {
  var command: String?
  var cwd: String?
  var exitCode: Int32
  var shell: String?
  var output: String
  var isRunTab: Bool
  var isRemote: Bool
}

/// Distinct error states so the banner can show actionable guidance.
enum AgentErrorKind: Equatable, Sendable {
  case cliNotFound
  case notAuthenticated
  case timedOut
  case emptyOutput
  case malformed
  case other(String)
}

/// What the banner shows for a tab (issue #49). Absent (no entry) means no banner.
enum AgentBannerState: Equatable, Sendable {
  /// An eligible failure that hasn't been diagnosed yet — shows a "Diagnose" button.
  case awaitingDiagnose(FailedCommand)
  /// A diagnosis is running.
  case loading(FailedCommand)
  /// A diagnosis came back.
  case ready(FailedCommand, AgentDiagnosis)
  /// The run failed (CLI missing, auth, timeout, …).
  case failure(FailedCommand, AgentErrorKind)
  /// A remote/ssh/tmux session — the local agent can't see the real host, so we caveat and disable
  /// Investigate rather than give a confidently-wrong local diagnosis (X5).
  case remoteCaveat(FailedCommand)

  /// The captured failure every state carries, plus the diagnosis when one is ready — for building
  /// the interactive Investigate seed prompt (issue #49).
  var failureAndDiagnosis: (FailedCommand, AgentDiagnosis?) {
    switch self {
    case .awaitingDiagnose(let failure), .loading(let failure), .failure(let failure, _),
      .remoteCaveat(let failure):
      return (failure, nil)
    case .ready(let failure, let diagnosis):
      return (failure, diagnosis)
    }
  }
}

/// Orchestrates the inline terminal agent (issue #49, T6): classify a finished command, decide
/// manual vs automatic, run the diagnosis (debounced, cooldown-bounded, cancel-superseding), guard
/// the pane lifecycle, and publish per-tab banner state. `@MainActor` + `ObservableObject` to match
/// `AppStore`/`TerminalSessions`. Pure decision logic lives in `FailureClassifier`; the runner and
/// the feature gates are injected so the state machine is seam-tested with a fake.
@MainActor
final class TerminalAgentManager: ObservableObject {
  @Published private(set) var banners: [TerminalTab.ID: AgentBannerState] = [:]

  /// Cheap gate so the host can skip the (screen-reading) capture work entirely when the feature is
  /// off — checked before `readCommandRegion()` runs on every command finish.
  var isEnabled: Bool { featureEnabled() }

  /// The tab whose banner should show the one-time "auto-diagnose from now on?" prompt — set after
  /// the user's FIRST manual Diagnose (when auto is off and they haven't been asked yet). nil = no
  /// prompt. The banner for this tab presents it; the answer persists the choice.
  @Published private(set) var autoOptInPromptTab: TerminalTab.ID?

  private let runner: AgentRunning
  private let featureEnabled: () -> Bool
  private let autoDiagnoseEnabled: () -> Bool
  private let redactSecrets: () -> Bool
  /// The model for the inline diagnosis (cheap/fast by default; nil = the CLI's own default).
  private let model: () -> String?
  /// Whether the one-time auto-diagnose opt-in prompt has already been shown.
  private let hasPromptedAutoOptIn: () -> Bool
  /// Persist the opt-in answer: always mark prompted; enable auto-diagnose when accepted.
  private let persistAutoOptIn: (_ enable: Bool) -> Void
  private let now: () -> Date
  private let cooldown: TimeInterval
  /// Where the inline (no-tools) claude call runs. A NEUTRAL dir, not the project, so `CLAUDE.md`
  /// doesn't auto-load and inflate cost (token opt, task #15); the real cwd is in the prompt text.
  private let inlineCwd: String
  private let timeout: TimeInterval

  /// The in-flight diagnosis per tab — cancelling it SIGKILLs the agent process via the runner's
  /// cancellation handler (T3), so a superseding failure doesn't leave a stale agent running.
  private(set) var inFlight: [TerminalTab.ID: Task<Void, Never>] = [:]
  /// Last auto-fire per target, for the cooldown (P1).
  private var lastAutoFire: [TerminalTarget.ID: Date] = [:]
  /// The latest failure per tab, retained even when soft-suppressed so a manual Diagnose still works.
  private var lastFailure: [TerminalTab.ID: FailedCommand] = [:]

  init(
    runner: AgentRunning = AgentRunner(),
    featureEnabled: @escaping () -> Bool = { true },
    autoDiagnoseEnabled: @escaping () -> Bool = { Defaults[.terminalAgentAutoDiagnose] },
    redactSecrets: @escaping () -> Bool = { Defaults[.terminalAgentRedactSecrets] },
    model: @escaping () -> String? = {
      let value = Defaults[.terminalAgentModel]
      return value.isEmpty ? nil : value
    },
    hasPromptedAutoOptIn: @escaping () -> Bool = { Defaults[.terminalAgentAutoDiagnosePrompted] },
    persistAutoOptIn: @escaping (Bool) -> Void = { enable in
      Defaults[.terminalAgentAutoDiagnosePrompted] = true
      if enable { Defaults[.terminalAgentAutoDiagnose] = true }
    },
    now: @escaping () -> Date = Date.init,
    cooldown: TimeInterval = 20,
    inlineCwd: String = NSTemporaryDirectory(),
    timeout: TimeInterval = 60
  ) {
    self.runner = runner
    self.featureEnabled = featureEnabled
    self.autoDiagnoseEnabled = autoDiagnoseEnabled
    self.redactSecrets = redactSecrets
    self.model = model
    self.hasPromptedAutoOptIn = hasPromptedAutoOptIn
    self.persistAutoOptIn = persistAutoOptIn
    self.now = now
    self.cooldown = cooldown
    self.inlineCwd = inlineCwd
    self.timeout = timeout
  }

  // MARK: Events

  /// A command finished in `tab`. `failure` is nil when the exit code is unknown / not a failure the
  /// host bothered to capture. Decides skip / soft-suppress / show-banner / auto-fire.
  func commandFinished(
    tab: TerminalTab.ID, target: TerminalTarget.ID, failure: FailedCommand?
  ) {
    guard featureEnabled() else { return }
    guard let failure else {
      clear(tab: tab)
      return
    }

    let disposition = FailureClassifier.disposition(
      exitCode: failure.exitCode, command: failure.command, isRunTab: failure.isRunTab,
      hasCapture: !failure.output.isEmpty)

    switch disposition {
    case .skip:
      clear(tab: tab)
    case .manualOnly:
      // Soft-suppress: no banner, but keep the context so a manual "Diagnose last command" works.
      lastFailure[tab] = failure
      setBanner(nil, tab: tab)
    case .eligible:
      lastFailure[tab] = failure
      if failure.isRemote {
        setBanner(.remoteCaveat(failure), tab: tab)
      } else if autoDiagnoseEnabled() && cooldownElapsed(target: target) {
        start(tab: tab, target: target, failure: failure, auto: true)
      } else {
        setBanner(.awaitingDiagnose(failure), tab: tab)
      }
    }
  }

  /// Explicit Diagnose (banner button or the "Diagnose last command" menu action). Works for an
  /// awaiting banner and for a soft-suppressed failure.
  func diagnose(tab: TerminalTab.ID, target: TerminalTarget.ID) {
    guard let failure = currentFailure(tab: tab), !failure.isRemote else { return }
    start(tab: tab, target: target, failure: failure, auto: false)
    // First manual Diagnose (auto off, never asked) → offer to make it automatic from now on.
    if !autoDiagnoseEnabled() && !hasPromptedAutoOptIn() {
      autoOptInPromptTab = tab
    }
  }

  /// Answer the one-time "auto-diagnose from now on?" prompt. `enable` turns auto-diagnose on;
  /// either way the prompt is marked shown so it never re-asks.
  func respondToAutoOptIn(enable: Bool) {
    persistAutoOptIn(enable)
    autoOptInPromptTab = nil
  }

  /// Dismiss the banner (cancels any in-flight run).
  func dismiss(tab: TerminalTab.ID) {
    if autoOptInPromptTab == tab { autoOptInPromptTab = nil }
    clear(tab: tab)
  }

  /// The pane/tab went away (A6): cancel in-flight, drop all state for it.
  func tabClosed(_ tab: TerminalTab.ID) {
    if autoOptInPromptTab == tab { autoOptInPromptTab = nil }
    clear(tab: tab)
    lastFailure[tab] = nil
  }

  // MARK: Diagnosis

  private func start(
    tab: TerminalTab.ID, target: TerminalTarget.ID, failure: FailedCommand, auto: Bool
  ) {
    inFlight[tab]?.cancel()  // cancel-supersede
    if auto { lastAutoFire[target] = now() }
    setBanner(.loading(failure), tab: tab)

    let output = redactSecrets() ? SecretRedactor.redact(failure.output) : failure.output
    let prompt = AgentPrompt.userMessage(
      command: failure.command, cwd: failure.cwd, exitCode: failure.exitCode, shell: failure.shell,
      output: output)
    let systemPrompt = AgentPrompt.systemPrompt
    let runner = self.runner
    let cwd = inlineCwd
    let timeout = self.timeout
    let model = self.model()

    inFlight[tab] = Task { [weak self] in
      let outcome = await runner.diagnoseInline(
        systemPrompt: systemPrompt, model: model, prompt: prompt, cwd: cwd, timeout: timeout)
      if Task.isCancelled { return }
      self?.apply(outcome: outcome, tab: tab, failure: failure)
    }
  }

  private func apply(outcome: AgentRunOutcome, tab: TerminalTab.ID, failure: FailedCommand) {
    // Ignore a result whose banner was superseded or dismissed while it ran.
    guard case .loading(let pending)? = banners[tab], pending == failure else { return }
    inFlight[tab] = nil

    let resolved: AgentBannerState
    switch outcome {
    case .success(let stdout):
      resolved =
        AgentPrompt.parse(envelopeJSON: stdout).map { .ready(failure, $0) }
        ?? .failure(failure, .malformed)
    case .cliNotFound: resolved = .failure(failure, .cliNotFound)
    case .notAuthenticated: resolved = .failure(failure, .notAuthenticated)
    case .timedOut: resolved = .failure(failure, .timedOut)
    // The workroom's folder is gone, not a real exit code — see `AgentRunOutcome.launchFailed`.
    case .launchFailed: resolved = .failure(failure, .other("workroom folder is gone"))
    // Not `.other("exit \(code)")`: `result.exitCode` on a signalled outcome is the SIGNAL number,
    // not a real CLI exit status — showing "exit 9" for a killed agent is the nonsense the gh-flap
    // fix ended elsewhere. Same `.other` case as `.failed` below, distinct copy.
    case .interrupted: resolved = .failure(failure, .other("interrupted"))
    case .emptyOutput: resolved = .failure(failure, .emptyOutput)
    case .failed(let code, _): resolved = .failure(failure, .other("exit \(code)"))
    }

    setBanner(resolved, tab: tab)
  }

  // MARK: Helpers

  private func clear(tab: TerminalTab.ID) {
    inFlight[tab]?.cancel()
    inFlight[tab] = nil
    setBanner(nil, tab: tab)
  }

  private func setBanner(_ state: AgentBannerState?, tab: TerminalTab.ID) {
    banners[tab] = state
  }

  private func cooldownElapsed(target: TerminalTarget.ID) -> Bool {
    guard let last = lastAutoFire[target] else { return true }
    return now().timeIntervalSince(last) >= cooldown
  }

  private func currentFailure(tab: TerminalTab.ID) -> FailedCommand? {
    if case .awaitingDiagnose(let failure)? = banners[tab] { return failure }
    return lastFailure[tab]
  }
}
