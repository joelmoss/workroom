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

/// Process-wide single-flight cache for the version probe.
///
/// The tool versions are a fact about the machine, not about a window, but `AppStore` is per-window
/// (`WorkroomApp.swift` mints one per `WindowSeed`). Without this, every window would spawn its own
/// `git --version` at launch. Concurrent callers share one probe rather than racing two.
///
/// `probedJJ` is remembered: a first probe taken before any jj project was registered legitimately
/// skipped `jj`, and reporting that cached `.notInstalled` once a jj project appears would warn about
/// a tool nobody ever looked for. Needing jj after skipping it re-probes.
actor VCSToolVersionCache {
  static let shared = VCSToolVersionCache()

  private var cached: (report: VCSToolVersions.Report, probedJJ: Bool)?
  private var inFlight: (task: Task<VCSToolVersions.Report, Never>, probedJJ: Bool)?

  func report(probeJJ: Bool, runner: StatusCommandRunning = StatusCommandRunner()) async
    -> VCSToolVersions.Report
  {
    // Reuse only a result that covers what this caller needs.
    if let cached, cached.probedJJ || !probeJJ { return cached.report }
    if let inFlight, inFlight.probedJJ || !probeJJ { return await inFlight.task.value }
    let task = Task { await VCSToolVersions.probe(runner: runner, probeJJ: probeJJ) }
    inFlight = (task, probeJJ)
    let report = await task.value
    cached = (report, probeJJ)
    inFlight = nil
    return report
  }

  /// Tests only — the cache is process-wide, so a test that probed must clear it.
  func reset() {
    cached = nil
    inFlight = nil
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
