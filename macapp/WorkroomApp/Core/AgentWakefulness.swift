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

  /// Hands the agent the app's ceiling settings (#257). The agent applies them from its next tick
  /// and keeps them for its next start, so a remote box takes the Settings pane's values on each
  /// connect rather than keeping what it was started with. An agent that predates the request
  /// answers `unsupported`, which throws like any refusal, and keeps its own.
  func apply(_ settings: AgentWakefulnessSettings) async throws {
    _ = try AgentStatusReply<AgentSettingsApplied>.decode(
      await connection.statusRequest(
        AgentStatusRequest(
          method: "settings", ceilingSeconds: settings.ceiling,
          promptTimeoutSeconds: settings.promptTimeout, askAtCeiling: settings.ask)))
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
  /// What keeps a BUSY box awake (#257): the agent's heartbeat. Nil from an agent that predates it.
  let keepAwake: KeepAwake?
  /// The agent's service has gone several ticks without finishing one, so this reply is its last
  /// tick's and the heartbeat has stopped with it (#257). Nil from an agent that predates the
  /// field.
  let stalled: Bool?
  /// What the heartbeat follows, after the ceiling: `"BUSY"` or `"IDLE"`.
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

  /// The agent's keep-awake heartbeat, as `status` reports it.
  struct KeepAwake: Decodable, Sendable, Equatable {
    /// On the agent's monotonic clock, like `monotonic`.
    let lastSent: Double?
    /// Why the last heartbeat could not be sent. Non-nil while BUSY means nothing is keeping the
    /// box awake.
    let error: String?
  }

  /// Work is running and nothing is keeping the box awake: the prompt went unanswered, the agent's
  /// service has stalled, the heartbeat is failing, or the agent predates the heartbeat (#257). The
  /// one state the badge must not soften. That last one is real, not hypothetical: a busy box can
  /// refuse the hand-off to a newer agent and keep the old one (`AgentBootstrap`'s `keptOlder`),
  /// which keeps nothing awake.
  var unprotected: Bool {
    suppressed || (busy && stalled == true) || (busy && keepAwake?.error != nil)
      || (running && busy && keepAwake == nil)
  }

  /// What the badge shows. Only these, because only these are actionable: the classifier's raw
  /// verdict and the CPU cost are diagnostics. `unknown` is a stalled service whose last reading
  /// was IDLE, on a host that sleeps (#356): that reading may be stale while work runs, and nothing
  /// is keeping the box awake either way.
  enum Display: Equatable { case idle, busy, busyPastCeiling, busyUnprotected, unknown }

  /// What the badge shows for a host that `sleeps` when idle or not. One that never sleeps (a
  /// container) cannot be slept under a job, so nothing there is "not kept awake": an old agent,
  /// a stalled one or a failing heartbeat would only be a false alarm, and its advice (restart the
  /// agent) would end the user's sessions.
  ///
  /// On a host its provider sleeps after `idleWindow` seconds idle on the network, when known
  /// (#356), a window shorter than the heartbeat can beat leaves busy work unprotected however
  /// healthy the heartbeat is.
  func display(hostSleeps sleeps: Bool, idleWindow: TimeInterval? = nil) -> Display {
    if sleeps, busy, Self.isTooShort(idleWindow) { return .busyUnprotected }
    if sleeps { return display }
    if awakeCeilingExceeded { return .busyPastCeiling }
    return busy ? .busy : .idle
  }

  /// The heartbeat sends once a minute (`heartbeat.rs`), so a provider that sleeps a box after
  /// less idle time than this can sleep it between two sends.
  static let minimumIdleWindow: TimeInterval = 90

  static func isTooShort(_ idleWindow: TimeInterval?) -> Bool {
    idleWindow.map { $0 < minimumIdleWindow } ?? false
  }

  var display: Display {
    if unprotected { return .busyUnprotected }
    if stalled == true { return .unknown }
    if awakeCeilingExceeded { return .busyPastCeiling }
    return busy ? .busy : .idle
  }

  /// The running agent's ceiling settings against the app's preferences, as one sentence, or nil
  /// when they agree (or the agent did not say). This Mac's agent takes them as flags fixed at its
  /// start, and it is persistent — it outlives the app on purpose — so "takes effect next time an
  /// agent starts" is, in practice, "not until the agent is restarted"; this is how the user finds
  /// out. A remote agent is handed them on every connect instead (`AgentBootstrap.connect`, #257).
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

  /// From the preferences' own units. A value the agent would refuse — outside 30 s to 30 days, the
  /// agent's `usable_seconds` — becomes the agent's default HERE, so a hand-edited preference
  /// (these two keys have no UI) reaches the agent as a number it accepts, not as `nan` on its
  /// command line or a settings request it refuses.
  init(ceilingHours: Double, promptTimeoutMinutes: Double, ask: Bool) {
    self.init(
      ceiling: Self.usable(ceilingHours * 3600) ?? Self.defaultCeiling,
      promptTimeout: Self.usable(promptTimeoutMinutes * 60) ?? Self.defaultPromptTimeout,
      ask: ask)
  }

  /// The agent's `usable_seconds` bounds, which it refuses a `settings` request outside of.
  static let usableSeconds: ClosedRange<TimeInterval> = 30...(30 * 24 * 3600)

  private static func usable(_ seconds: Double) -> TimeInterval? {
    usableSeconds.contains(seconds) ? seconds : nil
  }

  /// Read from preferences when the app spawns this Mac's agent, and when it connects to a remote
  /// one (#257). Not observed: this Mac's agent keeps its flags for its whole life, because it is
  /// long-lived and negotiated with rather than replaced, and a remote agent takes a changed
  /// preference on the next connect.
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
  /// `settings` only (#257).
  var ceilingSeconds: Double?
  var promptTimeoutSeconds: Double?
  var askAtCeiling: Bool?
}

/// The `{"method": "settings"}` reply: the settings the agent took, echoed back. Decoded rather
/// than ignored so a refusal surfaces as an error.
struct AgentSettingsApplied: Decodable, Sendable {
  struct Settings: Decodable, Sendable {
    let ceilingSeconds: Double
    let promptTimeoutSeconds: Double
    let askAtCeiling: Bool
  }
  let settings: Settings
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
    // The retry card is the user's, whatever the agent says about the prompt: not withdrawn, not
    // corrected, not replaced by the prompt it was a retry for. Its grace is its clock.
    if keepFailed { return }
    guard status.promptPending, let deadline = status.promptDeadline,
      let remaining = status.promptRemaining
    else {
      if isShowing { clear() }
      return
    }
    if isShowing, agentDeadline == deadline {
      expiresAt = now.addingTimeInterval(remaining)
      return
    }
    if answeredDeadline == deadline { return }
    awakeSeconds = status.awakeSeconds
    agentDeadline = deadline
    answeredDeadline = nil
    expiresAt = now.addingTimeInterval(remaining)
  }

  /// The user said keep it awake. The agent restarts the ceiling and will raise a fresh prompt a
  /// whole ceiling later, so nothing is left to show — PROVIDED the agent heard it. See
  /// `restoreAfterFailedKeep`. `answering` is the pending prompt's deadline as the last reply
  /// reported it, for a keep from the badge with no card up: the agent applies the keep on its next
  /// tick, and a reply issued in that second still says the prompt is pending.
  mutating func keep(answering deadline: Double? = nil) { answer(deadline) }

  /// Dismissed — the same outcome as the deadline passing, which is the point of OQ22's "no answer
  /// lets the box sleep": the app never tells the agent anything here. The prompt is remembered as
  /// answered so the agent's next reply does not put it back.
  mutating func dismiss(answering deadline: Double? = nil) { answer(deadline) }

  /// The card's connection is gone, or the agent says nothing is pending: cleared without being
  /// answered, so the same prompt is raised again if a later reply still reports it.
  mutating func withdraw() { clear() }

  /// The card's prompt, else the one the caller knows about, else whatever was already answered: a
  /// badge keep after a dismissal must not forget the dismissal.
  private mutating func answer(_ known: Double?) {
    let answered = agentDeadline ?? known ?? answeredDeadline
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
    // The prompt the keep was for: the card's, or (a badge keep) the one it answered.
    let identity = previous.agentDeadline ?? previous.answeredDeadline
    if isShowing, agentDeadline != identity { return }
    self = previous
    agentDeadline = identity
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

/// What the UI reads: a box's wakefulness, polled while it is on screen, plus the ceiling prompt.
/// One instance per BOX, because the verdict is per box: `shared` is this Mac's, which every local
/// workroom shares, and each remote host has its own (`model(forHost:)`, #254).
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

    /// A remote host's service in `manager` (#254). A poll and the prompt watch never connect
    /// the host: a badge is not a reason to reach it. A "keep" runs `connect` first, as the local
    /// transport spawns, because a click is the one caller for which a dropped connection is not an
    /// answer (`keep()`).
    static func on(
      _ host: HostID, manager: HostConnectionManager,
      connect: @escaping @Sendable (HostID) async throws -> Void = { _ in }
    ) -> Transport {
      Transport(
        status: { try await manager.wakefulness(host: host).status() },
        keep: {
          try await connect(host)
          try await manager.wakefulness(host: host).keep()
        },
        prompts: { try await manager.wakefulness(host: host).prompts })
    }
  }

  private let transport: Transport
  /// The remote host this model is for, or nil for this Mac's (`shared`).
  let host: UUID?
  /// Whether this model's host is put to sleep when idle (`HostDriverTraits.sleepsWhenIdle`), set
  /// from its driver on connect. Assumed until then; nothing shows before a connection anyway.
  var hostSleeps = true
  /// How long the host's provider lets it sit idle on the network before sleeping it, in seconds,
  /// read on connect where the provider says (boxd, #356); nil when unknown.
  var idleWindow: TimeInterval?

  init(transport: Transport = .live, host: UUID? = nil) {
    self.transport = transport
    self.host = host
  }

  /// Each remote host's model, made on first use and kept until its host is deleted, as
  /// `PortForwardingModel`'s are. This Mac's is `shared`, whose transport may start an agent.
  /// Published, so the toast stack shows a prompt from a host it had not seen before.
  @MainActor
  final class Hosts: ObservableObject {
    static let shared = Hosts()
    /// Not published: the sidebar makes a host's model inside a view's body, where publishing is
    /// not allowed. Nothing renders from this; the toast stack renders from `showing`.
    fileprivate(set) var models: [UUID: WakefulnessModel] = [:]
    /// The hosts whose card is up, which the toast stack renders and takes clicks for. Changed
    /// only by a model's prompt, never while a view is being drawn.
    @Published fileprivate(set) var showing: Set<UUID> = []
  }

  /// A remote host's model. Made watching for its ceiling prompts (#257): the app hands a remote
  /// agent whose box sleeps this Mac's ask-at-ceiling setting, so a prompt the app never showed
  /// would let the box sleep under a running job with the user sitting at the Mac. The watch never
  /// connects the host; it waits for a connection to be there.
  static func model(forHost id: UUID) -> WakefulnessModel {
    if let model = Hosts.shared.models[id] { return model }
    let model = WakefulnessModel(
      transport: .on(.remote(id), manager: .shared) {
        // Only "Keep awake" connects: a click, which wakes a box let go of or asleep (#356).
        try await RemoteHosts.shared.ensureConnected($0, wake: true)
      },
      host: id)
    Hosts.shared.models[id] = model
    model.startWatchingPrompts()
    return model
  }

  #if DEBUG
    /// The UI-test fixture's remote host asking to be kept awake (#257): a stand-in agent whose
    /// prompt stays pending until it is sent `keep`, so the card is testable without a host.
    static func seedUITestPrompt(host id: UUID) {
      let model = WakefulnessModel(transport: UITestPromptAgent().transport, host: id)
      Hosts.shared.models[id] = model
      model.startWatchingPrompts()
    }
  #endif

  /// The host is gone (deleted): its model, its watch and any prompt card with it.
  static func forgetHost(_ id: UUID) {
    let model = Hosts.shared.models.removeValue(forKey: id)
    model?.stopWatchingPrompts()
    model?.stopPollingWhileConnected()
    Hosts.shared.showing.remove(id)
  }

  /// Every model's in-flight "Keep awake", this Mac's and each remote host's, for quit. At once, so
  /// the quit waits for the slowest, not their sum. A remote host's badge is its only keep control.
  ///
  /// A remote keep may have to reconnect first, over ssh (`ConnectTimeout 10`), so it gets
  /// `remoteKeepDrain`, longer than this Mac's. Longer still is possible (a relayed workroom's
  /// relay install runs on that connect), and such a keep can miss the quit; the bound is what a
  /// quit is worth.
  static func drainAllKeeps() async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await shared.drainKeep() }
      for model in Hosts.shared.models.values {
        group.addTask { await model.drainKeep(timeout: remoteKeepDrain) }
      }
    }
  }

  /// How long quitting waits for a remote host's in-flight keep: ssh's 10 s connect timeout, plus
  /// the agent's greeting and the request.
  static let remoteKeepDrain: Duration = .seconds(15)

  /// Nil until a poll succeeds, and again once one fails: no agent, an agent that predates the
  /// service, or a macOS agent (which answers `running: false`) all show nothing rather than a
  /// guess.
  @Published private(set) var status: AgentWakefulness?
  @Published private(set) var prompt = AwakeCeilingPromptState() {
    didSet {
      // A forgotten host's model (a failed keep landing after the delete, say) must not put a
      // card back that the stack has no model to draw, or the stack would swallow clicks.
      guard let host, prompt.isShowing != oldValue.isShowing, Hosts.shared.models[host] === self
      else { return }
      if prompt.isShowing {
        Hosts.shared.showing.insert(host)
      } else {
        Hosts.shared.showing.remove(host)
      }
    }
  }

  /// Modest on purpose. The verdict changes on a 30 s hysteresis window, so anything faster only
  /// costs round trips, and this runs only while something is showing the result.
  nonisolated static let pollInterval: Duration = .seconds(10)

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
  /// When this host's readings stopped being ones to trust (#356): its service stopped, stalled, or
  /// its `status` failed. Such a reading holds the box for at most one ceiling from then, as nothing
  /// on the box will ask the user about it.
  private var untrustedSince: Date?
  /// The ceiling the last applied reply named, for a failed read, which names none.
  private var lastCeiling: TimeInterval?

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
  /// The reply is taken as it is. There is deliberately NO staleness rule here: the reader a
  /// staleness rule was meant for is the provider's shim, never built (#257), whose rule was "a
  /// verdict older than two ticks is BUSY" — it fails awake. A rule in the app that hid a verdict
  /// whose agent clock had not moved blanked the badge (and its "Keep awake") for every pair of
  /// replies inside one 1 s tick, which the watch's first reply and the poll's produce on every
  /// connection; and a classifier that has died says `running: false`, which the badge already
  /// hides.
  func refresh() async {
    await observe(issued: issue(), status: transport.status)
  }

  private func issue() -> (generation: Int, request: Int) {
    requestsIssued += 1
    return (promptGeneration, requestsIssued)
  }

  /// Sends one `status` and applies its reply unless a newer one has been applied meanwhile.
  /// Returns the reply whenever the request succeeded, applied or not: the watch needs to know its
  /// subscription happened, which is a property of the round trip, not of the ordering.
  ///
  /// A failed request takes no place in the ordering — it is not a newer reading, it is no reading
  /// — but it does blank the verdict when nothing newer is outstanding: no agent, no badge.
  @discardableResult
  private func observe(
    issued: (generation: Int, request: Int),
    status: @Sendable () async throws -> AgentWakefulness
  ) async -> AgentWakefulness? {
    let next = try? await status()
    guard !Task.isCancelled else { return next }
    guard let next else {
      guard issued.request == requestsIssued else { return nil }
      if self.status != nil { self.status = nil }
      // A failed read says nothing about a job, so it holds the box, for one ceiling at most.
      report(busy: holding(ceiling: lastCeiling))
      return nil
    }
    guard issued.request > newestApplied else { return next }
    newestApplied = issued.request
    if next != self.status { self.status = next }
    lastCeiling = next.ceilingSeconds ?? lastCeiling
    // A stalled service's reading may be stale while work runs (`display` shows it as unknown), so
    // it holds the box. One not running at all holds nothing awake, heartbeat included, so its box
    // is let go of too, unless its last reading was BUSY: a service that died under a job leaves
    // the connection as the one thing keeping that job's box awake. Neither reading changes and
    // nothing will ask about it, so each holds the box for one ceiling at most.
    if next.running && next.stalled != true {
      untrustedSince = nil
      report(busy: next.busy)
    } else {
      let held = holding(ceiling: next.ceilingSeconds ?? lastCeiling)
      report(busy: held && (next.running || next.busy))
    }
    if issued.generation == promptGeneration {
      prompt.reconcile(next, now: Date())
    }
    return next
  }

  /// Whether a reading the app can't trust still holds the box: for `ceiling` (the agent's default
  /// when none is known) from the first such reading.
  private func holding(ceiling: TimeInterval?) -> Bool {
    let since = untrustedSince ?? Date()
    untrustedSince = since
    return Date().timeIntervalSince(since)
      < (ceiling ?? AgentWakefulnessSettings.defaultCeiling)
  }

  /// A remote box that is not busy may be let go of, so the app's own traffic stops holding it
  /// awake (#356); `RemoteHosts` decides whether to (`observed`).
  private func report(busy: Bool) {
    guard let host else { return }
    Task { await RemoteHosts.shared.observed(.remote(host), busy: busy) }
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

  var isWatchingPrompts: Bool { watchTask != nil }

  /// A boxd host's poll while its connection is up (#356), started by `RemoteHosts.connect`. An
  /// IDLE reading is what lets the box go, and the badges poll only while they are on screen, so
  /// without this a box whose row was scrolled away stayed connected, and awake, until quit.
  /// ponytail: runs until the host is let go of or forgotten; a connection that drops otherwise
  /// leaves it failing one local request every `pollInterval` until the next connect.
  private var connectionPoll: Task<Void, Never>?

  func pollWhileConnected() {
    guard connectionPoll == nil else { return }
    connectionPoll = Task { [weak self] in await self?.poll() }
  }

  var isPollingWhileConnected: Bool { connectionPoll != nil }

  func stopPollingWhileConnected() {
    connectionPoll?.cancel()
    connectionPoll = nil
  }

  func stopWatchingPrompts() {
    watchTask?.cancel()
    watchTask = nil
    if prompt.isShowing { prompt.withdraw() }
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
      var raisedAny = false
      for await raised in prompts {
        raisedAny = true
        promptGeneration += 1
        prompt.raise(raised, promptTimeout: first.promptTimeoutSeconds, now: Date())
        // An event is a trigger, not the last word: one that sat buffered while the watch retried
        // its first reply may describe a prompt the agent has since answered (a keystroke, another
        // Workroom's keep). The reply issued now, under the new generation, settles it.
        await refresh()
      }
      // The connection that carried the prompt is gone. Its card would send `keep` to nothing: if
      // the agent is still there with the prompt still pending, the next connection's first reply
      // raises it again, with the exact time left; if the agent is gone, so is the prompt. Not
      // answered — withdrawn — so that reply CAN raise it again. A failed keep's retry card stays:
      // its `keep` reconnects on its own.
      if prompt.isShowing, !prompt.keepFailed { prompt.withdraw() }
      // A stream that ended without carrying anything (handed out already finished, the connection
      // replaced between the two acquisitions) must not spin this loop.
      if !raisedAny { try? await Task.sleep(for: Self.pollInterval) }
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
    prompt.keep(answering: status?.promptDeadline)
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

  /// Published so the buttons can show the click was taken: a second click is dropped while one is
  /// in flight, and a reconnecting keep can take seconds.
  @Published private(set) var keepInFlight: Task<Void, Never>?

  /// Waits, briefly, for a `keep` that is on its way. Quitting right after the click would
  /// otherwise exit with the card cleared and the request never sent, and the agent's deadline
  /// where it was. Bounded, at a little more than a reconnect costs (a 2 s handshake, a 2 s
  /// capabilities probe, the request itself): a `keep` that is respawning an agent as well is
  /// worth no more of a quit than that.
  func drainKeep(timeout: Duration = .seconds(6)) async {
    // Polled rather than awaited: `await task.value` cannot be given up on, and a task group
    // waits for every child before it returns, so the bound would not have been one.
    let deadline = ContinuousClock.now + timeout
    while keepInFlight != nil, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  func dismissPrompt() {
    prompt.dismiss(answering: status?.promptDeadline)
    promptGeneration += 1
  }

  func tick() { prompt.tick(now: Date()) }
}

#if DEBUG
  /// `WakefulnessModel.seedUITestPrompt`'s agent: BUSY past a 4 h ceiling with a prompt pending,
  /// raised once on its prompt stream, until a `keep` answers it.
  private final class UITestPromptAgent: @unchecked Sendable {
    private let lock = NSLock()
    private var kept = false
    /// Held so the stream stays open: a stream that ends withdraws its card.
    private var continuation: AsyncStream<AgentCeilingPrompt>.Continuation?

    var transport: WakefulnessModel.Transport {
      WakefulnessModel.Transport(
        status: { try self.status() },
        keep: { self.lock.withLock { self.kept = true } },
        prompts: {
          AsyncStream { continuation in
            self.lock.withLock { self.continuation = continuation }
            continuation.yield(AgentCeilingPrompt(awakeSeconds: 14400.5, promptDeadline: 15600))
          }
        })
    }

    private func status() throws -> AgentWakefulness {
      let pending = lock.withLock { !kept }
      let json = """
        {"running":true,"busy":true,"monotonic":15000.0,"awake_seconds":14400.5,\
        "awake_ceiling_exceeded":\(pending),"prompt_pending":\(pending),\
        "prompt_deadline":\(pending ? "15600.0" : "null"),"suppressed":false,\
        "prompt_timeout_seconds":600.0,"keep_awake":{"last_sent":14990.0,"error":null},\
        "stalled":false}
        """
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      return try decoder.decode(AgentWakefulness.self, from: Data(json.utf8))
    }
  }
#endif

/// The reply envelope. Shaped like `AgentFileReply`, with the Status service's error kinds:
/// `{"unsupported": "message"}`, and `{"invalid": "message"}` for a refused `settings` request.
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
