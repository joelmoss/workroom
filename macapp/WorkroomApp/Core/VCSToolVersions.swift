import Foundation

/// Whether the `git` binary on PATH is new enough for the VCS remote actions (fetch/push/pull) to
/// work at all.
///
/// **Why a declared floor rather than best-effort.** The remote commands fail *atomically* on an old
/// tool: `git for-each-ref --format='%(unknownatom)'` exits with `fatal: unknown field name` and
/// produces **no partial output**. The app doesn't bundle git — `ShellEnvironment.path()` takes
/// whatever is on PATH — so without a floor a user on an old tool gets raw stderr in place of every
/// remote feature, with nothing telling them why.
///
/// **git is required.** No `git` is a broken install: the bundled Go CLI shells `git worktree add` to
/// create a workroom at all.
enum VCSToolVersions {
  /// **git 2.41**, inherited from when the app linked jj-lib (its `MINIMUM_GIT_VERSION`) and left as
  /// is rather than lowered without a measurement. Everything this app issues needs far less
  /// (`%(symref)` wants 2.8, `pull --autostash` wants 2.9), so the headroom is deliberate.
  static let gitFloor = SemanticVersion("2.41.0")!

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
    let git: Status

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

    /// Whether remote actions are permitted.
    var allowsRemoteActions: Bool { Self.isUsable(git) }

    /// Warnings to publish.
    var warnings: [ToolWarning] {
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
      return out
    }
  }

  /// The first whitespace-separated token that parses as a version.
  ///
  /// Handles every form git prints: `git version 2.55.0` and Apple's
  /// `git version 2.39.5 (Apple Git-154)`. Non-numeric tokens (`git`, `version`,
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

  /// Probe git.
  ///
  /// Local reads, so `run` not `runNetwork`. Called in the background at app start, never blocking
  /// launch — and only *after* `ShellEnvironment` has set the PATH floor, since the probe needs PATH
  /// to find the binaries in the first place.
  static func probe(
    runner: StatusCommandRunning = StatusCommandRunner(),
    timeout: TimeInterval = 5, directory: String = NSTemporaryDirectory()
  ) async -> Report {
    let gitResult = await runner.run("git", ["--version"], in: directory, timeout: timeout)
    return Report(git: status(gitResult, floor: gitFloor))
  }
}

/// Cache for the version probe — the `GitHubAuthCache` shape (freshness lease, generation-stamped
/// in-flight, instance ownership) applied to git.
///
/// **Why instance-owned, not `static let shared`.** `AppStore.init` documents that "tests build an
/// isolated `AppStore()` (own fresh `ProjectStore`)", and `make app-test` runs classes in PARALLEL —
/// with `static let shared` one test's injected fake runner could serve another's probe, and the
/// tests-only `reset()` couldn't stop an already-in-flight task from repopulating the cache
/// afterwards. Same reasoning `GitHubAuthCache` documents; owned on `ProjectStore` the same way.
///
/// The tool versions are a fact about the machine, not about a window, but `AppStore` is per-window
/// (`WorkroomApp.swift` mints one per `WindowSeed`) while this lives on the shared `ProjectStore`, so
/// concurrent callers across windows still share one probe rather than racing two.
actor VCSToolVersionCache {
  /// Read/write `self.<property>` directly inside each `await`-separated step, never borrow it
  /// across one through `inout`: that is an actor reentrancy hazard (a second call landing on the
  /// same actor while the first is suspended would be a simultaneous exclusive access to the same
  /// property, a runtime crash). `GitHubAuthCache` avoids it the same way.
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

  /// TTLs are injectable so tests can age a verdict in milliseconds instead of sleeping for a minute.
  init(ttl: Duration = .seconds(60), belowFloorTTL: Duration = .seconds(10)) {
    self.ttl = ttl
    self.belowFloorTTL = belowFloorTTL
  }

  func report(runner: StatusCommandRunning = StatusCommandRunner()) async -> VCSToolVersions.Report
  {
    VCSToolVersions.Report(git: await gitStatus(runner: runner))
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

  /// Fold a finished git probe into the cache. Never caches `.notInstalled`: at launch the PATH may
  /// still be the deterministic floor, because `ShellEnvironment.path()` returns the floor until the
  /// detached interactive-shell probe lands, so an absence can be an artefact of WHEN we probed
  /// rather than what is installed. `.unknown` is safe to cache by contrast: `warnings` ignores it.
  private func recordGit(_ status: VCSToolVersions.Status, gen: Int) -> VCSToolVersions.Status {
    if gen == gitGeneration {
      gitInFlight = nil
      if status != .notInstalled { gitCached = (status, clock.now) }
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

  /// Tests only — clears the cache.
  func reset() {
    gitCached = nil
    gitInFlight = nil
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
