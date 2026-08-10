import Foundation

/// Whether the `git` / `jj` binaries on PATH are new enough for the VCS remote actions
/// (fetch/push/pull) to work at all.
///
/// **Why a declared floor rather than best-effort.** The remote commands fail *atomically* on an old
/// tool: `git for-each-ref --format='%(unknownatom)'` exits with `fatal: unknown field name` and
/// produces **no partial output**, and `jj bookmark` did not exist before ~0.18 (it was `jj branch`),
/// with the `tracking_*_count()` template functions newer still. The app bundles neither binary —
/// `ShellEnvironment.path()` takes whatever is on PATH — so without a floor a user on an old tool gets
/// raw stderr in place of every remote feature, with nothing telling them why.
///
/// **git is required; jj is optional.** No `git` is a broken install: the bundled Go CLI shells
/// `git worktree add` to create a workroom at all. No `jj` is the ordinary state for a git-only user
/// and must be completely silent — no warning, and not even a `jj --version` spawned.
///
/// **Scoping is per project VCS, not global.** An old `jj` must not disable a git project's toolbar.
/// An old `git` disables both, because a colocated jj repo drives git underneath (jj shells real `git`
/// for its network operations).
///
/// ```
///                    git ok        git belowFloor/absent
///   git project      enabled       disabled
///   jj  project      needs jj ok   disabled
/// ```
enum VCSToolVersions {
  /// The floors are anchored to something already true rather than picked.
  ///
  /// **git 2.41** is the minimum *jj itself* enforces for its git subprocess
  /// (`jj-lib`'s `MINIMUM_GIT_VERSION`), so it excludes nobody a jj user isn't already excluded by.
  /// Everything this app issues needs far less (`%(symref)` wants 2.8, `pull --autostash` wants 2.9),
  /// so the headroom is deliberate.
  static let gitFloor = SemanticVersion("2.41.0")!
  /// **jj 0.43** matches the `jj-lib` the Rust VCS core links. That matters beyond flags: an older CLI
  /// may not understand the repo format the linked library writes.
  static let jjFloor = SemanticVersion("0.43.0")!

  /// A tool's usability. `.unknown` is deliberately NOT a failure — see `isUsable`.
  enum Status: Equatable, Sendable {
    /// Found and at or above the floor. Carries the version string as printed, for copy.
    case ok(String)
    /// Found but too old. Carries the version string as printed.
    case belowFloor(String)
    /// Not on PATH (`/usr/bin/env` exits `CommandResult.commandNotFound`).
    case notInstalled
    /// The probe timed out, or its output didn't contain a parseable version.
    case unknown
  }

  /// A user-facing warning about one tool.
  ///
  /// Rendered as a standing toast by `ToastStack` (see `ToolWarningToastView`), never a modal alert: a
  /// too-old tool must not stop the app being useful for terminals and diffs, which issue none of
  /// these commands. Deliberately NOT routed through `NotificationCenterStore` — every entry there is
  /// keyed `(targetID, tabID)` and a click routes back to a live terminal, which a machine-wide tool
  /// problem has none of.
  struct ToolWarning: Equatable, Sendable, Identifiable {
    let tool: String
    let title: String
    let detail: String
    var id: String { tool }
  }

  struct Report: Equatable, Sendable {
    /// Required.
    let git: Status
    /// Optional — `.notInstalled` is not a problem on its own.
    let jj: Status

    /// Everything except `.belowFloor`/`.notInstalled` counts as usable.
    ///
    /// `.unknown` passes on purpose: a probe that timed out or printed something we couldn't parse is
    /// not evidence of an old tool, and disabling a working feature on a failed *guess* is worse than
    /// letting the command itself report a real error. Same never-cry-wolf rule
    /// `WorkroomStatusResolver.classifyGitHubCLI` follows for `gh`.
    static func isUsable(_ status: Status) -> Bool {
      switch status {
      case .ok, .unknown: return true
      case .belowFloor, .notInstalled: return false
      }
    }

    /// Whether remote actions are permitted for a project of this VCS (`"git"` / `"jj"`).
    func allowsRemoteActions(vcs: String) -> Bool {
      guard Self.isUsable(git) else { return false }
      return vcs == "jj" ? Self.isUsable(jj) : true
    }

    /// Warnings to publish. jj is only ever mentioned when a jj project is actually registered.
    func warnings(hasJJProject: Bool) -> [ToolWarning] {
      var out: [ToolWarning] = []
      switch git {
      case .notInstalled:
        out.append(
          ToolWarning(
            tool: "git", title: "Git isn’t installed",
            detail:
              "Workroom needs Git to manage workrooms. Install it with `xcode-select --install`, "
              + "or from Homebrew, then restart Workroom."))
      case .belowFloor(let found):
        out.append(
          ToolWarning(
            tool: "git", title: "Git \(gitFloor.shortDescription) or newer is required",
            detail:
              "Found Git \(found). Fetch, push and pull are disabled until you upgrade — the commands "
              + "they use don’t exist in this version."))
      case .ok, .unknown:
        break
      }
      guard hasJJProject else { return out }
      switch jj {
      case .notInstalled:
        out.append(
          ToolWarning(
            tool: "jj", title: "Jujutsu isn’t installed",
            detail:
              "One or more of your projects uses Jujutsu. Fetch, push and pull are disabled for them "
              + "until `jj` is on your PATH."))
      case .belowFloor(let found):
        out.append(
          ToolWarning(
            tool: "jj", title: "Jujutsu \(jjFloor.shortDescription) or newer is required",
            detail:
              "Found jj \(found). Fetch, push and pull are disabled for your Jujutsu projects until "
              + "you upgrade."))
      case .ok, .unknown:
        break
      }
      return out
    }
  }

  /// The first whitespace-separated token that parses as a version.
  ///
  /// Handles every form these tools print: `git version 2.55.0`, Apple's
  /// `git version 2.39.5 (Apple Git-154)`, and `jj 0.43.0`. Non-numeric tokens (`git`, `version`,
  /// `(Apple`, `Git-154)`) can't parse — `SemanticVersion` requires a numeric core — so no allowlist
  /// of leading words is needed, and a future rewording of the prefix won't break this.
  static func firstVersion(in output: String) -> (raw: String, parsed: SemanticVersion)? {
    for token in output.split(whereSeparator: { $0.isWhitespace }) {
      let raw = String(token)
      if let parsed = SemanticVersion(raw) { return (raw, parsed) }
    }
    return nil
  }

  /// Classify one `--version` result against a floor.
  static func status(_ result: CommandResult, floor: SemanticVersion) -> Status {
    if result.exitCode == CommandResult.commandNotFound { return .notInstalled }
    if result.timedOut { return .unknown }
    // Some tools print `--version` to stderr; check both rather than assuming.
    guard let found = firstVersion(in: result.stdout + " " + result.stderr) else { return .unknown }
    return found.parsed < floor ? .belowFloor(found.raw) : .ok(found.raw)
  }

  /// Probe both tools. `probeJJ` false ⇒ `jj` is not run at all and reports `.notInstalled`, which
  /// `warnings(hasJJProject:)` then ignores.
  ///
  /// Local reads, so `run` not `runNetwork`. Called in the background at app start, never blocking
  /// launch — and only *after* `ShellEnvironment` has set the PATH floor, since the probe needs PATH
  /// to find the binaries in the first place.
  static func probe(
    runner: StatusCommandRunning = StatusCommandRunner(), probeJJ: Bool,
    timeout: TimeInterval = 5, directory: String = NSTemporaryDirectory()
  ) async -> Report {
    let gitResult = await runner.run("git", ["--version"], in: directory, timeout: timeout)
    let gitStatus = status(gitResult, floor: gitFloor)
    guard probeJJ else { return Report(git: gitStatus, jj: .notInstalled) }
    let jjResult = await runner.run("jj", ["--version"], in: directory, timeout: timeout)
    return Report(git: gitStatus, jj: status(jjResult, floor: jjFloor))
  }
}

/// Cache for the version probe — the `GitHubAuthCache` shape (freshness lease, generation-stamped
/// in-flight, instance ownership) applied to git and jj as TWO INDEPENDENT slots, not one combined
/// `Report`.
///
/// **Why two slots, not one.** The previous single-slot design cached one `(Report, probedJJ)` pair.
/// A `probeJJ: false` caller and a `probeJJ: true` caller racing meant whichever's completion landed
/// LAST won the shared slot unconditionally — so a jj-blind result (which reports `jj: .notInstalled`
/// outright, without running anything) could overwrite a jj-aware one that had already cached a real
/// verdict. `GitHubAuthCache`'s generation stamp alone doesn't fix this: it orders by RECENCY, and it
/// has no analogous "coverage" axis to protect, because it only ever answers one question. Splitting
/// git and jj into their own slots removes the shared state those two kinds of caller could race
/// over in the first place — a jj-blind caller never touches the jj slot at all.
///
/// **Why instance-owned, not `static let shared`.** `AppStore.init` documents that "tests build an
/// isolated `AppStore()` (own fresh `ProjectStore`)", and `make app-test` runs classes in PARALLEL —
/// with `static let shared` one test's injected fake runner could serve another's probe, and the
/// tests-only `reset()` couldn't stop an already-in-flight task from repopulating the cache
/// afterwards. Same reasoning `GitHubAuthCache` documents; owned on `ProjectStore` the same way.
///
/// The tool versions are a fact about the machine, not about a window, but `AppStore` is per-window
/// (`WorkroomApp.swift` mints one per `WindowSeed`) while this lives on the shared `ProjectStore`, so
/// concurrent callers across windows still share one probe per tool rather than racing two.
///
/// `probedJJ` is still remembered at the `report(probeJJ:)` call boundary (see below): a first probe
/// taken before any jj project was registered legitimately skips `jj` outright, and reporting a
/// cached `.notInstalled` once a jj project appears would warn about a tool nobody ever looked for.
/// Needing jj after skipping it re-probes — but that re-probe now only ever touches the jj slot.
actor VCSToolVersionCache {
  /// Flat, per-tool stored properties rather than a shared `Slot` struct passed by `inout`:
  /// mutating a stored property through an `inout` binding held across an `await` is an actor
  /// reentrancy hazard (a second call landing on the same actor while the first is suspended would
  /// be a simultaneous exclusive access to the same property, a runtime crash) — the exact class of
  /// bug this type exists to get away from. `GitHubAuthCache` avoids it the same way: read/write
  /// `self.<property>` directly inside each `await`-separated step, never borrow it across one.
  ///
  /// `belowFloor` gets a short TTL lease — an upgrade is the expected repair, and the whole point of
  /// warning about it is that it should be noticed once fixed — while `ok` gets a long one, since an
  /// installed tool's version is effectively static for a session. TTLs match `GitHubAuthCache`'s
  /// exact numbers (60s / 10s): a tool's version changes far less than GitHub auth state, but the
  /// cost of a redundant local `--version` is cheap enough that a bespoke, longer TTL isn't worth
  /// its own tuning surface.
  private let clock = ContinuousClock()
  private let ttl: Duration
  private let belowFloorTTL: Duration

  private var gitCached: (status: VCSToolVersions.Status, at: ContinuousClock.Instant)?
  private var gitInFlight: Task<VCSToolVersions.Status, Never>?
  /// Generation-stamped like `GitHubAuthCache`, so a superseded probe can't clear a newer flight or
  /// overwrite a newer verdict when it finally lands.
  private var gitGeneration = 0

  private var jjCached: (status: VCSToolVersions.Status, at: ContinuousClock.Instant)?
  private var jjInFlight: Task<VCSToolVersions.Status, Never>?
  private var jjGeneration = 0

  /// TTLs are injectable so tests can age a verdict in milliseconds instead of sleeping for a minute.
  init(ttl: Duration = .seconds(60), belowFloorTTL: Duration = .seconds(10)) {
    self.ttl = ttl
    self.belowFloorTTL = belowFloorTTL
  }

  /// `probeJJ: false` ⇒ the jj slot is never touched at all — jj reports `.notInstalled` without a
  /// process ever spawning, exactly as `VCSToolVersions.probe` itself behaves, and nothing about that
  /// non-answer is cached (there is nothing to age out of a slot that was never written).
  func report(probeJJ: Bool, runner: StatusCommandRunning = StatusCommandRunner()) async
    -> VCSToolVersions.Report
  {
    let gitStatus = await gitStatus(runner: runner)
    guard probeJJ else { return VCSToolVersions.Report(git: gitStatus, jj: .notInstalled) }
    let jjStatus = await jjStatus(runner: runner)
    return VCSToolVersions.Report(git: gitStatus, jj: jjStatus)
  }

  private func gitStatus(runner: StatusCommandRunning) async -> VCSToolVersions.Status {
    if let gitCached, isFresh(gitCached) { return gitCached.status }
    if let gitInFlight { return await gitInFlight.value }
    gitGeneration += 1
    let gen = gitGeneration
    let task = Task { [self] () -> VCSToolVersions.Status in
      let result = await runner.run("git", ["--version"], in: NSTemporaryDirectory(), timeout: 5)
      let status = VCSToolVersions.status(result, floor: VCSToolVersions.gitFloor)
      return await recordGit(status, gen: gen)
    }
    gitInFlight = task
    return await task.value
  }

  private func jjStatus(runner: StatusCommandRunning) async -> VCSToolVersions.Status {
    if let jjCached, isFresh(jjCached) { return jjCached.status }
    if let jjInFlight { return await jjInFlight.value }
    jjGeneration += 1
    let gen = jjGeneration
    let task = Task { [self] () -> VCSToolVersions.Status in
      let result = await runner.run("jj", ["--version"], in: NSTemporaryDirectory(), timeout: 5)
      let status = VCSToolVersions.status(result, floor: VCSToolVersions.jjFloor)
      return await recordJJ(status, gen: gen)
    }
    jjInFlight = task
    return await task.value
  }

  /// Fold a finished git probe into the git slot. Never caches `.notInstalled` — see the type doc on
  /// the original single-slot design for why: at launch the PATH may still be the deterministic
  /// floor, because `ShellEnvironment.path()` returns the floor until the detached interactive-shell
  /// probe lands, so an absence can be an artefact of WHEN we probed rather than what is installed.
  /// `.unknown` is safe to cache by contrast: `warnings(hasJJProject:)` ignores it.
  private func recordGit(_ status: VCSToolVersions.Status, gen: Int) -> VCSToolVersions.Status {
    if gen == gitGeneration {
      gitInFlight = nil
      if status != .notInstalled { gitCached = (status, clock.now) }
    }
    return status
  }

  /// The jj-slot counterpart of `recordGit` — kept as its own method rather than sharing one
  /// parameterized by tool, because that would need `inout` access to whichever property the
  /// caller means, the exact hazard this design avoids (see the type doc above).
  private func recordJJ(_ status: VCSToolVersions.Status, gen: Int) -> VCSToolVersions.Status {
    if gen == jjGeneration {
      jjInFlight = nil
      if status != .notInstalled { jjCached = (status, clock.now) }
    }
    return status
  }

  private func isFresh(_ entry: (status: VCSToolVersions.Status, at: ContinuousClock.Instant))
    -> Bool
  {
    entry.at.duration(to: clock.now) < effectiveTTL(for: entry.status)
  }

  private func effectiveTTL(for status: VCSToolVersions.Status) -> Duration {
    if case .belowFloor = status { return belowFloorTTL }
    return ttl
  }

  /// Tests only — clears both slots.
  func reset() {
    gitCached = nil
    gitInFlight = nil
    jjCached = nil
    jjInFlight = nil
  }
}

extension SemanticVersion {
  /// `"2.41"` for a zero patch, else `"2.41.1"` — how a required version reads in prose.
  var shortDescription: String {
    let padded = core + Array(repeating: 0, count: max(0, 3 - core.count))
    let base =
      padded[2] == 0 ? "\(padded[0]).\(padded[1])" : "\(padded[0]).\(padded[1]).\(padded[2])"
    return prerelease.isEmpty ? base : base + "-" + prerelease.joined(separator: ".")
  }
}
