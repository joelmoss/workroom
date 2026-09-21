import Defaults
import Foundation

/// `Service::Status` (`0x04`) on a wr-agent connection: the wakefulness verdict and the awake
/// ceiling (issue #208, OQ22). Everything here is the wire contract of
/// `vcs/crates/wr-agent/src/wakefulness.rs`.
///
/// **The service is advisory.** Past the ceiling the agent only *reports* that the box has been BUSY
/// too long; it never hibernates anything. With ask-at-ceiling on it raises one prompt, `keep` resets
/// the ceiling, and an unanswered prompt merely stops the agent asserting BUSY so the provider's own
/// idle timer may sleep the box. Nothing in the app sleeps a box either.
struct AgentWakefulnessService: Sendable {
  let connection: AgentVCSConnection
  /// `prompt_timeout_seconds` from the connect-time probe, or nil if the agent did not report one.
  /// The ceiling prompt event carries no clock reading, so this is what its countdown runs on.
  let negotiatedPromptTimeout: TimeInterval?

  func status() async throws -> AgentWakefulness {
    try AgentStatusReply<AgentWakefulness>.decode(
      await connection.statusRequest(AgentStatusRequest(method: "status")))
  }

  /// "Keep this box awake": the agent restarts the ceiling from now.
  func keep() async throws {
    _ = try AgentStatusReply<AgentKept>.decode(
      await connection.statusRequest(AgentStatusRequest(method: "keep")))
  }

  /// Unsolicited `awake_ceiling_prompt` events, in arrival order. Finishes when the connection does.
  var prompts: AsyncStream<AgentCeilingPrompt> { connection.ceilingPrompts }
}

/// One `{"method": "status"}` reply.
///
/// `monotonic` is the AGENT's clock (`sample::monotonic()`), not this Mac's and not wall time, so
/// `promptDeadline` is only ever meaningful relative to `monotonic` from the same reply — never
/// against `Date()`. `promptRemaining` is the one place that subtraction is allowed to happen.
struct AgentWakefulness: Decodable, Sendable, Equatable {
  /// Whether the classifier thread is running at all. False on a macOS agent: the service is Linux
  /// only, so a local agent answers `status` truthfully with `running: false` rather than not at all.
  let running: Bool
  /// What the reader sees, after the ceiling: `"BUSY"` or `"IDLE"`.
  let verdict: String
  let busy: Bool
  /// What the classifier itself decided, before the ceiling had its say.
  let classifierVerdict: String
  let monotonic: Double
  /// Seconds the box has been continuously BUSY.
  let awakeSeconds: Double
  /// BUSY for longer than the ceiling. Reported, never acted on.
  let awakeCeilingExceeded: Bool
  let promptPending: Bool
  /// On the agent's monotonic clock. Non-nil only while `promptPending`.
  let promptDeadline: Double?
  let asserting: Bool
  /// The prompt went unanswered and the agent has stopped asserting BUSY.
  let suppressed: Bool
  let ceilingSeconds: Double
  let promptTimeoutSeconds: Double
  let askAtCeiling: Bool
  let cpuFraction: Double

  /// Seconds left to answer the prompt, from the two clock readings in THIS reply. Nil when no
  /// prompt is pending.
  var promptRemaining: TimeInterval? {
    guard promptPending, let deadline = promptDeadline else { return nil }
    return max(0, deadline - monotonic)
  }

  /// What the workroom row shows. Only these three, because only these three are actionable: the
  /// classifier's raw verdict, the suppression flag and the CPU cost are diagnostics.
  enum Display: Equatable { case idle, busy, busyPastCeiling }

  var display: Display {
    if awakeCeilingExceeded { return .busyPastCeiling }
    return busy ? .busy : .idle
  }
}

/// The `{"method": "keep"}` reply. Decoded rather than ignored so a refusal surfaces as an error.
struct AgentKept: Decodable, Sendable {
  let kept: Bool
}

/// An unsolicited `awake_ceiling_prompt`: Status service, stream 0.
///
/// It carries the deadline on the agent's monotonic clock and NO reading of that clock, so the
/// deadline alone cannot be turned into a duration. The event means "the prompt starts now", and the
/// agent sets `deadline = now + prompt_timeout`, so the countdown starts from the prompt timeout —
/// see `AgentCeilingPrompt.remaining(promptTimeout:)`.
struct AgentCeilingPrompt: Decodable, Sendable, Equatable {
  let awakeSeconds: Double
  let promptDeadline: Double

  /// Last-resort fallback, matching `wakefulness::Settings::default()`. Reached only when neither the
  /// connect-time probe nor a poll reported the agent's own timeout.
  static let defaultPromptTimeout: TimeInterval = 600

  /// Deliberately ignores `promptDeadline`: it is an instant on the agent's monotonic clock and this
  /// event carries no reading of that clock, so only the duration can cross. The consequence, worth
  /// knowing, is that the countdown restarts from the full timeout and is therefore optimistic by
  /// however long the event spent in flight — milliseconds on a unix socket.
  func remaining(promptTimeout: TimeInterval?) -> TimeInterval {
    promptTimeout ?? Self.defaultPromptTimeout
  }
}

/// Seconds off the wire, as a `Duration` safe to format.
///
/// `Duration.seconds(_: Double)` traps on an out-of-range value (`Fatal error: Overflow in
/// multiplication`), and `awakeSeconds` is a non-optional `Double` straight off the socket. Nothing a
/// healthy agent reports comes close — it is bounded by uptime — but every other wire path in this
/// feature drops garbage rather than trusting it, and a formatter is no place to be the exception.
/// A century is far past any duration the UI renders meaningfully.
///
/// `min`/`max` rather than an `isFinite` gate, so an infinite value clamps to the ceiling like any
/// other too-large one instead of reading as zero — "busy longer than the UI can say" is the truer
/// answer to +∞ than "not busy". Only NaN needs its own arm, because every comparison with it is
/// false and it would otherwise fall through unclamped.
func wakefulnessDuration(_ seconds: Double) -> Duration {
  guard !seconds.isNaN else { return .zero }
  return .seconds(min(max(seconds, 0), 100 * 365 * 24 * 3600))
}

/// The three wakefulness preferences, as the agent takes them: flags on `wr-agent serve`.
///
/// Defaults match `wakefulness::Settings::default()` — 4 h and 10 min — and the agent applies its own
/// defaults for any flag the app omits, so the two cannot drift apart silently.
struct AgentWakefulnessSettings: Equatable, Sendable {
  var ceiling: TimeInterval = 4 * 3600
  var promptTimeout: TimeInterval = 600
  var ask = false

  /// Read from preferences at the moment the app spawns an agent. Not observed: the flags are fixed
  /// for an agent's whole life, because the agent is long-lived and negotiated with rather than
  /// replaced — changing a preference takes effect the next time an agent is started.
  static var current: AgentWakefulnessSettings {
    AgentWakefulnessSettings(
      ceiling: Defaults[.awakeCeilingHours] * 3600,
      promptTimeout: Defaults[.awakePromptTimeoutMinutes] * 60,
      ask: Defaults[.askAtAwakeCeiling])
  }

  /// The full `wr-agent serve` command line. One function so the mapping has something to test.
  ///
  /// `%g` rather than `%f`: the agent parses these with `f64::from_str`, and a plain integer reads
  /// the same to it while staying legible in a process listing.
  func serveArguments(socket: String) -> [String] {
    var arguments = [
      "serve", "--socket", socket,
      "--awake-ceiling", String(format: "%g", ceiling),
      "--awake-prompt-timeout", String(format: "%g", promptTimeout),
    ]
    if ask { arguments.append("--ask-at-awake-ceiling") }
    return arguments
  }
}

/// An unsolicited frame on the Status service, stream 0. The payload fields are optional so an event
/// kind this build does not know is dropped rather than failing the decode for the one it does.
struct AgentStatusEvent: Decodable {
  let event: String
  var awakeSeconds: Double?
  var promptDeadline: Double?
}

struct AgentStatusRequest: Encodable, Sendable {
  var version = 1
  let method: String
}

/// The awake-ceiling prompt as the UI holds it: pure, so the two rules worth testing — "keep" clears
/// it, and an unanswered deadline clears it — are testable without a socket or a clock.
///
/// The deadline is converted to a LOCAL `Date` the moment the prompt arrives, because the agent's
/// `prompt_deadline` is on its own monotonic clock and nothing in this process shares that clock. The
/// duration is what crosses the boundary, never the instant.
struct AwakeCeilingPromptState: Equatable {
  private(set) var awakeSeconds: Double?
  private(set) var expiresAt: Date?
  /// A `keep` left but the agent never acknowledged it. The card comes back, saying so — see
  /// `WakefulnessModel.keep()` for why this is not the same as never having asked.
  private(set) var keepFailed = false

  var isShowing: Bool { expiresAt != nil }

  /// A prompt arrived. `promptTimeout` is the agent's own configured timeout, from the connect-time
  /// probe or a `status` poll; nil falls back to the agent's default.
  mutating func raise(_ prompt: AgentCeilingPrompt, promptTimeout: TimeInterval?, now: Date) {
    awakeSeconds = prompt.awakeSeconds
    expiresAt = now.addingTimeInterval(prompt.remaining(promptTimeout: promptTimeout))
    keepFailed = false
  }

  /// The user said keep it awake. The agent restarts the ceiling and will raise a fresh prompt a
  /// whole ceiling later, so nothing is left to show — PROVIDED the agent heard it. See
  /// `restoreAfterFailedKeep`.
  mutating func keep() { clear() }

  /// Dismissed, or the deadline passed — the same outcome either way, which is the point of OQ22's
  /// "no answer lets the box sleep": the app never tells the agent anything here.
  mutating func dismiss() { clear() }

  /// The optimistic `keep` did not reach the agent. Puts the card back exactly as it was — the
  /// agent's deadline never moved — and flags why, so this is distinguishable from both a
  /// still-unanswered prompt and a dismissal.
  mutating func restoreAfterFailedKeep(_ previous: AwakeCeilingPromptState) {
    self = previous
    keepFailed = true
  }

  /// Drops the prompt once its deadline has passed. Idempotent.
  mutating func tick(now: Date) {
    guard let expiresAt, now >= expiresAt else { return }
    clear()
  }

  func remaining(now: Date) -> TimeInterval? {
    guard let expiresAt else { return nil }
    return max(0, expiresAt.timeIntervalSince(now))
  }

  private mutating func clear() {
    awakeSeconds = nil
    expiresAt = nil
    keepFailed = false
  }
}

/// What the UI reads: the local box's wakefulness, polled while it is on screen, plus the ceiling
/// prompt. One instance, because the verdict is per BOX — every workroom on this machine shares it.
@MainActor
final class WakefulnessModel: ObservableObject {
  static let shared = WakefulnessModel()

  /// Nil until a poll succeeds, and again once one fails: no agent, an agent that predates the
  /// service, or a macOS agent (which answers `running: false`) all show nothing rather than a
  /// guess.
  @Published private(set) var status: AgentWakefulness?
  @Published private(set) var prompt = AwakeCeilingPromptState()

  /// Modest on purpose. The verdict changes on a 30 s hysteresis window, so anything faster only
  /// costs round trips, and this runs only while the badge is on screen.
  static let pollInterval: Duration = .seconds(10)

  /// Polls for as long as the caller's task lives. Driven by a SwiftUI `.task`, so closing the
  /// inspector or the window ends it — there is no polling while nothing is showing the result.
  ///
  /// A cancelled poll leaves the last verdict standing rather than clearing it. Clearing on exit
  /// read as tidy and was wrong in two ways: this model is shared by every window, so one window
  /// closing its inspector blanked the others' badge; and the value is only ever rendered by a badge
  /// whose own `.task` refreshes it before its first sleep, so a stale value cannot be displayed.
  /// A FAILED poll still clears it — that assignment is the `try?` below.
  func poll() async {
    while !Task.isCancelled {
      let next = try? await LocalAgentVCS.shared.wakefulness().status()
      guard !Task.isCancelled else { return }
      status = next
      try? await Task.sleep(for: Self.pollInterval)
    }
  }

  private var watchTask: Task<Void, Never>?

  /// Starts the single ceiling-prompt watch. Idempotent, and deliberately NOT bound to the caller's
  /// task: `AsyncStream` supports exactly ONE iterator, and Workroom has N windows sharing this one
  /// model, so a per-window `for await` would be undefined behaviour. One loop, started by whichever
  /// window opens first.
  ///
  /// Unlike `poll()` this runs for the app's life, and that is the honest trade: a watch blocked on
  /// `for await` costs nothing, while a prompt missed because no inspector happened to be open is a
  /// box that sleeps under a running job.
  func startWatchingPrompts() {
    guard watchTask == nil else { return }
    watchTask = Task { [weak self] in await self?.runWatch() }
  }

  /// Retries, because the agent may not be connected yet when the app opens, and the stream ends
  /// with the connection that carried it.
  private func runWatch() async {
    while !Task.isCancelled {
      guard let service = try? await LocalAgentVCS.shared.wakefulness() else {
        try? await Task.sleep(for: Self.pollInterval)
        continue
      }
      for await raised in service.prompts {
        // The connect-time probe, not just a poll: `poll()` only runs while the Changes inspector is
        // mounted, while this watch is app-lifetime, so `status` is usually nil here and the
        // countdown would silently fall back to the hardcoded default. `negotiatedPromptTimeout` is
        // the agent's own answer and is always available on a connection that has a status service.
        let timeout = status?.promptTimeoutSeconds ?? service.negotiatedPromptTimeout
        prompt.raise(raised, promptTimeout: timeout, now: Date())
      }
    }
  }

  /// "Keep awake": tell the agent to restart the ceiling.
  ///
  /// The card clears optimistically so the click feels immediate, and comes BACK if the request did
  /// not land. That second half is not politeness — an earlier version swallowed the error on the
  /// premise that "a `keep` the agent never received leaves the ceiling where it was", and that
  /// premise is false. `Ceiling::step` moves `Prompted` to `Suppressed` at the deadline
  /// (`wakefulness.rs`), and `suppressing()` makes the published verdict IDLE, which is what lets the
  /// provider's own timer sleep the box. A successful `keep` round-trip is the ONLY other way out of
  /// `Prompted`. So a dropped request meant the card vanished, nothing retried, and the box slept
  /// under a running job after the user had asked for exactly the opposite.
  ///
  /// Re-raising is safe in the other direction too: `Ceiling::keep` just restarts from now, so a
  /// retry that duplicates a `keep` which did land costs nothing.
  func keep() {
    let raised = prompt
    prompt.keep()
    Task { [weak self] in
      do {
        try await LocalAgentVCS.shared.wakefulness().keep()
      } catch {
        self?.prompt.restoreAfterFailedKeep(raised)
      }
    }
  }

  func dismissPrompt() { prompt.dismiss() }

  func tick() { prompt.tick(now: Date()) }
}

/// The reply envelope. Shaped like `AgentFileReply`, with the Status service's single error kind:
/// `{"unsupported": "message"}`.
struct AgentStatusReply<T: Decodable>: Decodable {
  let result: T
  enum CodingKeys: CodingKey { case version, result, error }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    guard try values.decode(Int.self, forKey: .version) == 1 else {
      throw HostConnectionError.serviceUnavailable("Unsupported status response version.")
    }
    if values.contains(.error) {
      let failure = try values.decode([String: String].self, forKey: .error)
      guard failure.count == 1, let (kind, message) = failure.first else {
        throw HostConnectionError.serviceUnavailable("Malformed agent failure.")
      }
      throw HostConnectionError.serviceUnavailable("\(kind): \(message)")
    }
    result = try values.decode(T.self, forKey: .result)
  }

  static func decode(_ data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    do {
      return try decoder.decode(Self.self, from: data).result
    } catch let error as DecodingError {
      throw HostConnectionError.serviceUnavailable("Invalid status response: \(error)")
    }
  }
}
