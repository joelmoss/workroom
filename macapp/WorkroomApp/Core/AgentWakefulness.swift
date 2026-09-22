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

  func status() async throws -> AgentWakefulness {
    try AgentStatusReply<AgentWakefulness>.decode(
      await connection.statusRequest(AgentStatusRequest(method: "status")))
  }

  /// "Keep this box awake": the agent restarts the ceiling from now.
  ///
  /// A refusal is an error, not a reply: `WakefulnessModel.keep` clears the card on success, and the
  /// one thing worse than a `keep` that never arrived is one that arrived, was declined and reported
  /// success. The agent never declines today; the guard is for the day it does.
  func keep() async throws {
    let reply = try AgentStatusReply<AgentKept>.decode(
      await connection.statusRequest(AgentStatusRequest(method: "keep")))
    guard reply.kept else { throw HostConnectionError.serviceUnavailable("Agent declined keep.") }
  }

  /// Unsolicited `awake_ceiling_prompt` events, in arrival order. Finishes when the connection does.
  var prompts: AsyncStream<AgentCeilingPrompt> { connection.ceilingPrompts }
}

/// One `{"method": "status"}` reply.
///
/// `monotonic` is the AGENT's clock (`sample::monotonic()`), not this Mac's and not wall time, so
/// `promptDeadline` is only ever meaningful relative to `monotonic` from the same reply — never
/// against `Date()`. `promptRemaining` is the one place that subtraction is allowed to happen.
///
/// The fields the app acts on are required. The rest of the contract is decoded as optionals: they
/// are diagnostics today, and an agent that renames one must not blank the badge for a number nothing
/// displays. `AgentWakefulnessTests` pins the whole shape against the shipped binary.
struct AgentWakefulness: Decodable, Sendable, Equatable {
  /// Whether the classifier thread is running at all. False on a macOS agent: the service is Linux
  /// only, so a local agent answers `status` truthfully with `running: false` rather than not at all.
  let running: Bool
  let busy: Bool
  let monotonic: Double
  /// Seconds the box has been continuously BUSY.
  let awakeSeconds: Double
  /// BUSY for longer than the ceiling. Reported, never acted on.
  let awakeCeilingExceeded: Bool
  let promptPending: Bool
  /// On the agent's monotonic clock. Non-nil only while `promptPending`.
  let promptDeadline: Double?
  /// The prompt went unanswered and the agent has stopped asserting BUSY.
  let suppressed: Bool
  let promptTimeoutSeconds: Double
  /// Whether the last verdict reached the file the provider's shim reads. False means the box is NOT
  /// being kept awake, whatever `busy` says — a full disk is the case. Nil from an agent that predates
  /// the field.
  let verdictWritten: Bool?
  /// What the reader sees, after the ceiling: `"BUSY"` or `"IDLE"`.
  let verdict: String?
  /// What the classifier itself decided, before the ceiling had its say.
  let classifierVerdict: String?
  let asserting: Bool?
  let ceilingSeconds: Double?
  let askAtCeiling: Bool?
  let cpuFraction: Double?

  /// Seconds left to answer the prompt, from the two clock readings in THIS reply. Nil when no
  /// prompt is pending.
  var promptRemaining: TimeInterval? {
    guard promptPending, let deadline = promptDeadline else { return nil }
    return wakefulnessSeconds(deadline - monotonic)
  }

  /// Work is running and nothing is keeping the box awake: the prompt went unanswered, or the verdict
  /// never reached the file the shim reads. The one state the badge must not soften.
  var unprotected: Bool { suppressed || (busy && verdictWritten == false) }

  /// What the badge shows. Only these four, because only these four are actionable: the classifier's
  /// raw verdict and the CPU cost are diagnostics.
  enum Display: Equatable { case idle, busy, busyPastCeiling, busyUnprotected }

  var display: Display {
    if unprotected { return .busyUnprotected }
    if awakeCeilingExceeded { return .busyPastCeiling }
    return busy ? .busy : .idle
  }

  /// The running agent's ceiling settings against the app's preferences, as one sentence, or nil when
  /// they agree (or the agent did not say). The settings are flags fixed at the agent's start, and the
  /// agent is persistent — it outlives the app on purpose — so "takes effect next time an agent
  /// starts" is, in practice, "not until the agent is restarted"; this is how the user finds out.
  func settingsMismatch(against settings: AgentWakefulnessSettings) -> String? {
    var differences: [String] = []
    if let ask = askAtCeiling, ask != settings.ask {
      differences.append("ask-before-sleep \(ask ? "on" : "off")")
    }
    if let ceiling = ceilingSeconds, abs(ceiling - settings.ceiling) >= 1 {
      let hours = wakefulnessDuration(ceiling).formatted(
        .units(allowed: [.hours, .minutes], width: .narrow))
      differences.append("a \(hours) ceiling")
    }
    guard !differences.isEmpty else { return nil }
    return "The running agent was started with \(differences.joined(separator: " and ")); "
      + "the current settings apply when it next starts."
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
/// see `remaining(promptTimeout:)`. The deadline is still kept: it is the prompt's IDENTITY, the one
/// value an event and a `status` reply about the same prompt share.
struct AgentCeilingPrompt: Sendable, Equatable {
  let awakeSeconds: Double
  let promptDeadline: Double

  /// Last-resort fallback, matching `wakefulness::Settings::default()`. Reached only when no `status`
  /// reply has reported the agent's own timeout yet.
  static let defaultPromptTimeout: TimeInterval = 600

  /// Deliberately ignores `promptDeadline` as a duration: it is an instant on the agent's monotonic
  /// clock and this event carries no reading of that clock. The consequence, worth knowing, is that
  /// the countdown restarts from the full timeout and is optimistic by however long the event spent
  /// in flight — milliseconds on a unix socket; the next `status` reply corrects it exactly.
  /// Clamped: `promptTimeout` is a wire value.
  func remaining(promptTimeout: TimeInterval?) -> TimeInterval {
    wakefulnessSeconds(promptTimeout ?? Self.defaultPromptTimeout)
  }
}

/// A duration off the wire, made safe to add to a `Date` or format.
///
/// `Duration.seconds(_: Double)` traps on an out-of-range value (`Fatal error: Overflow in
/// multiplication`), and every wire duration here is a non-optional `Double` straight off the socket.
/// Nothing a healthy agent reports comes close — they are bounded by uptime — but every other wire
/// path in this feature drops garbage rather than trusting it, and neither a formatter nor a
/// deadline is a place to be the exception: a NaN deadline is one `tick` can never reach, a card
/// that never clears. A century is far past any duration the UI renders meaningfully.
///
/// `min`/`max` rather than an `isFinite` gate, so an infinite value clamps to the ceiling like any
/// other too-large one instead of reading as zero — "busy longer than the UI can say" is the truer
/// answer to +∞ than "not busy". Only NaN needs its own arm, because every comparison with it is
/// false and it would otherwise fall through unclamped.
func wakefulnessSeconds(_ seconds: Double) -> Double {
  guard !seconds.isNaN else { return 0 }
  return min(max(seconds, 0), 100 * 365 * 24 * 3600)
}

func wakefulnessDuration(_ seconds: Double) -> Duration {
  .seconds(wakefulnessSeconds(seconds))
}

/// The three wakefulness preferences, as the agent takes them: flags on `wr-agent serve`.
///
/// Defaults match `wakefulness::Settings::default()` — 4 h and 10 min — and the agent applies its own
/// defaults for any flag the app omits, so the two cannot drift apart silently.
struct AgentWakefulnessSettings: Equatable, Sendable {
  var ceiling: TimeInterval
  var promptTimeout: TimeInterval
  var ask: Bool

  static let defaultCeiling: TimeInterval = 4 * 3600
  static let defaultPromptTimeout: TimeInterval = AgentCeilingPrompt.defaultPromptTimeout

  init(
    ceiling: TimeInterval = Self.defaultCeiling,
    promptTimeout: TimeInterval = Self.defaultPromptTimeout, ask: Bool = false
  ) {
    self.ceiling = ceiling
    self.promptTimeout = promptTimeout
    self.ask = ask
  }

  /// From the preferences' own units. A value the agent would refuse — not finite, not positive —
  /// becomes the agent's default HERE, so a hand-edited preference (these two keys have no UI) reaches
  /// the agent as a number it accepts, not as `nan` on its command line.
  init(ceilingHours: Double, promptTimeoutMinutes: Double, ask: Bool) {
    self.init(
      ceiling: Self.usable(ceilingHours * 3600) ?? Self.defaultCeiling,
      promptTimeout: Self.usable(promptTimeoutMinutes * 60) ?? Self.defaultPromptTimeout,
      ask: ask)
  }

  private static func usable(_ seconds: Double) -> TimeInterval? {
    seconds.isFinite && seconds > 0 ? seconds : nil
  }

  /// Read from preferences at the moment the app spawns an agent. Not observed: the flags are fixed
  /// for an agent's whole life, because the agent is long-lived and negotiated with rather than
  /// replaced — changing a preference takes effect the next time an agent is started.
  static var current: AgentWakefulnessSettings {
    AgentWakefulnessSettings(
      ceilingHours: Defaults[.awakeCeilingHours],
      promptTimeoutMinutes: Defaults[.awakePromptTimeoutMinutes],
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

  /// The same settings as the agent's environment fallback. `wr-agent attach` self-spawns `serve`
  /// with no flags when no agent is listening, and the app reaches that spawn only through the
  /// environment it launches `attach` with (`PersistentSessionService.launchEnvironment`).
  ///
  /// Under `WORKROOM_SESSION_`, the prefix the agent scrubs from the shell it spawns: the settings
  /// reach the self-spawned `serve` and never the user's `env`.
  var serveEnvironment: [(key: String, value: String)] {
    var entries = [
      ("WORKROOM_SESSION_AWAKE_CEILING", String(format: "%g", ceiling)),
      ("WORKROOM_SESSION_AWAKE_PROMPT_TIMEOUT", String(format: "%g", promptTimeout)),
    ]
    if ask { entries.append(("WORKROOM_SESSION_ASK_AT_AWAKE_CEILING", "1")) }
    return entries
  }
}

/// An unsolicited frame on the Status service, stream 0. The payload fields are optional so an event
/// kind this build does not know is dropped rather than failing the decode for the one it does. The
/// version is checked exactly as a reply's is: an event from a newer contract is dropped, not misread.
struct AgentStatusEvent: Decodable {
  let version: Int
  let event: String
  var awakeSeconds: Double?
  var promptDeadline: Double?
}

struct AgentStatusRequest: Encodable, Sendable {
  var version = 1
  let method: String
}

/// The awake-ceiling prompt as the UI holds it: pure, so the rules worth testing — "keep" clears it,
/// an unanswered deadline clears it, a `status` reply raises, corrects or withdraws it — are testable
/// without a socket or a clock.
///
/// The deadline is converted to a LOCAL `Date` the moment the prompt arrives, because the agent's
/// `prompt_deadline` is on its own monotonic clock and nothing in this process shares that clock. The
/// duration is what crosses the boundary, never the instant. The instant IS kept as the prompt's
/// identity (`agentDeadline`): the event and every `status` reply about the same prompt carry it.
struct AwakeCeilingPromptState: Equatable {
  private(set) var awakeSeconds: Double?
  private(set) var expiresAt: Date?
  /// `prompt_deadline` on the agent's clock. Never compared with a local time; only with itself.
  private(set) var agentDeadline: Double?
  /// The prompt the user answered here (✕ or "Keep awake"), by identity. The agent keeps reporting
  /// it pending — a dismissal tells the agent nothing by design, and a `keep` is applied on the
  /// agent's next tick — so without this the next `status` reply would put the card straight back.
  /// Forgotten when a different prompt arrives.
  private(set) var answeredDeadline: Double?
  /// A `keep` left but the agent never acknowledged it. The card comes back, saying so — see
  /// `WakefulnessModel.keep()` for why this is not the same as never having asked.
  private(set) var keepFailed = false

  /// The least a failed `keep` leaves on the clock. A retry after the agent's own deadline still
  /// matters: `keep` is one of the two ways out of `Suppressed` (`Ceiling::user_acted` is the other,
  /// and it needs a keystroke on the box itself), so the card must not vanish on the next tick
  /// because the deadline it was restored with has already passed.
  static let retryGrace: TimeInterval = 60

  var isShowing: Bool { expiresAt != nil }

  /// A prompt arrived on the event stream. `promptTimeout` is the agent's own configured timeout,
  /// from a `status` reply; nil falls back to the agent's default.
  ///
  /// The same prompt twice — the event after a `status` reply that already raised it, or a stream
  /// that replayed — keeps the countdown it has: the reply's is exact, the event's is not.
  mutating func raise(_ prompt: AgentCeilingPrompt, promptTimeout: TimeInterval?, now: Date) {
    if isShowing, agentDeadline == prompt.promptDeadline { return }
    if answeredDeadline == prompt.promptDeadline { return }
    awakeSeconds = prompt.awakeSeconds
    agentDeadline = prompt.promptDeadline
    answeredDeadline = nil
    expiresAt = now.addingTimeInterval(prompt.remaining(promptTimeout: promptTimeout))
    keepFailed = false
  }

  /// A `status` reply is the agent's authoritative word on the prompt, and the only word it gives
  /// after the event: a prompt the agent has already answered on its own — the box went idle, the
  /// user typed into it (`Ceiling::user_acted`), it resumed from sleep, another Workroom sent `keep`
  /// — is withdrawn with no event. So: pending and unknown here raises the card (an app that
  /// connects mid-prompt is the common case with a 4 h ceiling); pending and known corrects the
  /// countdown to the agent's exact remaining time; not pending withdraws the card.
  ///
  /// Two exceptions. A prompt the user already answered here is not raised again (the agent keeps
  /// reporting a dismissed prompt pending, by design). And after a failed `keep` the card is the
  /// user's retry, not the agent's prompt: it keeps its own clock (the grace) and is not the agent's
  /// to withdraw — a retry into `Suppressed` still works, and a `keep` whose reply was lost is
  /// harmless to repeat.
  mutating func reconcile(_ status: AgentWakefulness, now: Date) {
    guard status.promptPending, let deadline = status.promptDeadline,
      let remaining = status.promptRemaining
    else {
      if isShowing, !keepFailed { clear() }
      return
    }
    if isShowing, agentDeadline == deadline {
      if !keepFailed { expiresAt = now.addingTimeInterval(remaining) }
      return
    }
    if answeredDeadline == deadline { return }
    awakeSeconds = status.awakeSeconds
    agentDeadline = deadline
    answeredDeadline = nil
    expiresAt = now.addingTimeInterval(remaining)
    keepFailed = false
  }

  /// The user said keep it awake. The agent restarts the ceiling and will raise a fresh prompt a
  /// whole ceiling later, so nothing is left to show — PROVIDED the agent heard it. See
  /// `restoreAfterFailedKeep`.
  mutating func keep() { answer() }

  /// Dismissed — the same outcome as the deadline passing, which is the point of OQ22's "no answer
  /// lets the box sleep": the app never tells the agent anything here. The prompt is remembered as
  /// answered so the agent's next reply does not put it back.
  mutating func dismiss() { answer() }

  /// The card's connection is gone, or the agent says nothing is pending: cleared without being
  /// answered, so the same prompt is raised again if a later reply still reports it.
  mutating func withdraw() { clear() }

  private mutating func answer() {
    let answered = agentDeadline
    clear()
    answeredDeadline = answered
  }

  /// The optimistic `keep` did not reach the agent. Puts the card back as it was — the agent's
  /// deadline never moved — and flags why, so this is distinguishable from both a still-unanswered
  /// prompt and a dismissal. Two guards: a DIFFERENT prompt raised meanwhile is newer and wins (the
  /// same one, put back by a reply that crossed the `keep`, is what this restores over); and a
  /// restored deadline already in the past (a 5 s request timeout landing after it) gets
  /// `retryGrace`, or the failure would flash for one tick and the box would sleep with no retry
  /// offered. A `keep` from the badge, with no card up, restores an empty state the same way: the
  /// grace IS the card.
  mutating func restoreAfterFailedKeep(_ previous: AwakeCeilingPromptState, now: Date) {
    if isShowing, agentDeadline != previous.agentDeadline { return }
    self = previous
    answeredDeadline = nil
    keepFailed = true
    let grace = now.addingTimeInterval(Self.retryGrace)
    if expiresAt.map({ $0 < grace }) ?? true { expiresAt = grace }
  }

  /// Drops the prompt once its deadline has passed. Idempotent. Not an answer: a later reply that
  /// still reports it pending (a retry card's grace outlived the agent's deadline, say) may raise
  /// it again.
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
    agentDeadline = nil
    answeredDeadline = nil
    keepFailed = false
  }
}

/// What the UI reads: the local box's wakefulness, polled while it is on screen, plus the ceiling
/// prompt. One instance, because the verdict is per BOX — every workroom on this machine shares it.
@MainActor
final class WakefulnessModel: ObservableObject {
  static let shared = WakefulnessModel()

  /// The three calls the model makes, so the model's rules — one poll loop, reconcile from every
  /// reply, the poll-before-event race, the staleness rule — are testable without an agent. `live`
  /// is the only production implementation.
  struct Transport {
    var status: @Sendable () async throws -> AgentWakefulness
    var keep: @Sendable () async throws -> Void
    /// The current connection's prompt stream, or throws when there is no connection.
    var prompts: @Sendable () async throws -> AsyncStream<AgentCeilingPrompt>

    /// A poll never connects (no agent, no badge); the watch reconnects to an agent that is there
    /// (its whole job is to be listening); a `keep` also spawns one (a click is not a poll).
    static let live = Transport(
      status: { try await LocalAgentVCS.shared.wakefulness(connecting: .never).status() },
      keep: { try await LocalAgentVCS.shared.wakefulness(connecting: .spawn).keep() },
      prompts: { try await LocalAgentVCS.shared.wakefulness(connecting: .reconnect).prompts })
  }

  private let transport: Transport

  init(transport: Transport = .live) {
    self.transport = transport
  }

  /// Nil until a poll succeeds, and again once one fails: no agent, an agent that predates the
  /// service, or a macOS agent (which answers `running: false`) all show nothing rather than a
  /// guess.
  @Published private(set) var status: AgentWakefulness?
  @Published private(set) var prompt = AwakeCeilingPromptState()

  /// Modest on purpose. The verdict changes on a 30 s hysteresis window, so anything faster only
  /// costs round trips, and this runs only while something is showing the result.
  static let pollInterval: Duration = .seconds(10)

  private var pollers = 0
  private var pollTask: Task<Void, Never>?
  /// Bumped whenever the card changes for a reason a reply cannot know about: a prompt arriving on
  /// the event stream, the user answering one. A `status` request that left BEFORE the event (or
  /// the click) can say `prompt_pending: false` about the prompt since raised, or `true` about the
  /// one since answered — the agent publishes its state before it sends the event, and applies a
  /// `keep` on its next tick, but a reply already on the wire is older — so a reply only reconciles
  /// against the card state it was requested under.
  private var promptGeneration = 0
  /// `status` requests are issued by the poll loop and, once per connection, by the watch, so two
  /// can be in flight at once and resume in either order. Each carries its issue number; a reply
  /// older than the newest one applied is dropped, so the verdict cannot run backwards and a stale
  /// `prompt_pending: false` cannot undo a newer reply's raise.
  private var requestsIssued = 0
  private var newestApplied = 0

  /// Polls for as long as the caller's task lives. Driven by a SwiftUI `.task`, so closing the
  /// inspector, the card or the window ends it — there is no polling while nothing is showing the
  /// result. One loop however many callers: N windows with the inspector open are N callers of a
  /// single poll, not N polls stomping one `status` (one's timeout would blank every window's badge).
  ///
  /// A cancelled poll leaves the last verdict standing rather than clearing it. Clearing on exit
  /// read as tidy and was wrong in two ways: this model is shared by every window, so one window
  /// closing its inspector blanked the others' badge; and the value is only ever rendered by a badge
  /// whose own `.task` refreshes it before its first sleep, so a stale value cannot be displayed.
  /// A FAILED poll still clears it — that assignment is the `try?` in `refresh`.
  func poll() async {
    pollers += 1
    if pollTask == nil {
      pollTask = Task { [weak self] in
        while let self, !Task.isCancelled {
          await self.refresh()
          try? await Task.sleep(for: Self.pollInterval)
        }
      }
    }
    // Parked until the caller is cancelled; the sleep throws the moment that happens.
    while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    pollers -= 1
    if pollers == 0 {
      pollTask?.cancel()
      pollTask = nil
    }
  }

  /// One `status` round trip, applied. Public for the tests; the poll loop is this on a timer.
  ///
  /// The reply is taken as it is. There is deliberately NO staleness rule here: the reader whose
  /// staleness rule matters is the provider's shim, and its rule is "a verdict older than two ticks
  /// is BUSY" — it fails awake. A rule in the app that hid a verdict whose agent clock had not moved
  /// blanked the badge (and its "Keep awake") for every pair of replies inside one 1 s tick, which
  /// the watch's first reply and the poll's produce on every connection; and a classifier that has
  /// died says `running: false`, which the badge already hides.
  func refresh() async {
    await observe(issued: issue(), status: transport.status)
  }

  private func issue() -> (generation: Int, request: Int) {
    requestsIssued += 1
    return (promptGeneration, requestsIssued)
  }

  /// Sends one `status` and applies its reply unless a newer one has been applied meanwhile.
  @discardableResult
  private func observe(
    issued: (generation: Int, request: Int),
    status: @Sendable () async throws -> AgentWakefulness
  ) async -> AgentWakefulness? {
    let next = try? await status()
    guard !Task.isCancelled, issued.request > newestApplied else { return nil }
    newestApplied = issued.request
    if next != self.status { self.status = next }
    if let next, issued.generation == promptGeneration {
      prompt.reconcile(next, now: Date())
    }
    return next
  }

  private var watchTask: Task<Void, Never>?

  /// Starts the single ceiling-prompt watch. Idempotent, and deliberately NOT bound to any view's
  /// task: `AsyncStream` supports exactly ONE iterator, and Workroom has N windows sharing this one
  /// model, so a per-window `for await` would be undefined behaviour. Started once, at app launch:
  /// a watch blocked on `for await` costs nothing, while a prompt missed because no window happened
  /// to be open is a box that sleeps under a running job.
  func startWatchingPrompts() {
    guard watchTask == nil else { return }
    watchTask = Task { [weak self] in await self?.runWatch() }
  }

  /// Retries, because the agent may not be connected yet when the app opens, and the stream ends
  /// with the connection that carried it. Reconnects to an agent that is there (never spawns one):
  /// a watch that waited for some unrelated VCS read to reconnect it was off after every drop.
  private func runWatch() async {
    while !Task.isCancelled {
      guard let prompts = try? await transport.prompts() else {
        try? await Task.sleep(for: Self.pollInterval)
        continue
      }
      // The stream first, then the reply: a prompt raised between the two is buffered by the stream
      // and raised below, and one the reply already raised is the same prompt (same deadline), so
      // `raise` keeps the reply's exact countdown. The reply is what shows a prompt that was pending
      // BEFORE this connection existed — the agent sends the event once, to whoever was listening
      // then, and with a 4 h ceiling and a persistent agent that is usually not this app. Its
      // prompt timeout is also this agent's own answer, which is what an event's countdown runs on.
      //
      // And the reply is what makes this connection a listener at all: the agent remembers a
      // connection for prompts when it first asks for `status`. A first request that never reached
      // the wire (the request pool full, say) is not retried by the agent, so a watch that sat in
      // the stream regardless was subscribed to nothing. No reply, no stream: try again.
      guard let first = await observe(issued: issue(), status: transport.status) else {
        try? await Task.sleep(for: Self.pollInterval)
        continue
      }
      for await raised in prompts {
        promptGeneration += 1
        prompt.raise(raised, promptTimeout: first.promptTimeoutSeconds, now: Date())
      }
      // The connection that carried the prompt is gone. Its card would send `keep` to nothing: if
      // the agent is still there with the prompt still pending, the next connection's first reply
      // raises it again, with the exact time left; if the agent is gone, so is the prompt. Not
      // answered — withdrawn — so that reply CAN raise it again. A failed keep's retry card stays:
      // its `keep` reconnects on its own.
      if prompt.isShowing, !prompt.keepFailed { prompt.withdraw() }
    }
  }

  /// "Keep awake": tell the agent to restart the ceiling.
  ///
  /// The card clears optimistically so the click feels immediate, and comes BACK if the request did
  /// not land. That second half is not politeness — an earlier version swallowed the error on the
  /// premise that "a `keep` the agent never received leaves the ceiling where it was", and that
  /// premise is false. `Ceiling::step` moves `Prompted` to `Suppressed` at the deadline
  /// (`wakefulness.rs`), and `suppressing()` makes the published verdict IDLE, which is what lets the
  /// provider's own timer sleep the box. A successful `keep` round-trip and a keystroke on the box
  /// are the only other ways out of `Prompted`. So a dropped request meant the card vanished,
  /// nothing retried, and the box slept under a running job after the user had asked for exactly
  /// the opposite.
  ///
  /// Re-raising is safe in the other direction too: `Ceiling::keep` just restarts from now, so a
  /// retry that duplicates a `keep` which did land costs nothing. And the request reconnects, or
  /// spawns: a click is the one caller for which a dropped connection is not an answer.
  ///
  /// One at a time: a second click while the first is in flight (the badge and the card, or two
  /// windows' cards) would capture an already-empty card, and restore THAT if it failed.
  func keep() {
    guard keepInFlight == nil else { return }
    let raised = prompt
    prompt.keep()
    promptGeneration += 1
    let transport = transport
    keepInFlight = Task { [weak self] in
      do {
        try await transport.keep()
      } catch {
        self?.prompt.restoreAfterFailedKeep(raised, now: Date())
      }
      self?.keepInFlight = nil
    }
  }

  private var keepInFlight: Task<Void, Never>?

  /// Waits, briefly, for a `keep` that is on its way. Quitting right after the click would
  /// otherwise exit with the card cleared and the request never sent, and the agent's deadline
  /// where it was. Bounded: a `keep` that is reconnecting is worth two seconds of a quit, not more.
  func drainKeep(timeout: Duration = .seconds(2)) async {
    // Polled rather than awaited: `await task.value` cannot be given up on, and a task group
    // waits for every child before it returns, so the bound would not have been one.
    let deadline = ContinuousClock.now + timeout
    while keepInFlight != nil, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  func dismissPrompt() {
    prompt.dismiss()
    promptGeneration += 1
  }

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
