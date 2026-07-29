import Foundation
import Sentry
import os

/// The environment the app hands to the processes it spawns.
///
/// A Finder-launched `.app` inherits a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) — no
/// Homebrew, nothing from `/etc/paths.d`, nothing a dotfile exports. Two layers fix that, and they
/// are deliberately **unequal in reliability**:
///
/// - **The floor** — `floorPath()` reads `/etc/paths` + `/etc/paths.d/*`, the same inputs
///   `/usr/libexec/path_helper` reads, and unions a few well-known tool directories. No process, no
///   shell: it cannot hang, prompt, or `exec` into a multiplexer. This is what makes Postgres.app's
///   `psql` (contributed by `/etc/paths.d/postgresapp`) resolvable at all, and it is why the app
///   never has a *wrong* PATH, only ever a less complete one.
/// - **The probe** — `refresh()` runs one `$SHELL -ilc` and reads back the user's whole
///   environment, picking up what only an interactive login shell knows: `.zshrc`-exported PATH
///   entries, version-manager shims, `$PNPM_HOME`. Strictly **best-effort**. Every failure mode
///   (timeout, a `.zshrc` that ends `exec tmux`, an rc that prompts on stdin, an unsupported shell)
///   degrades to the floor, which is already correct — so a broken rc costs enrichment and can
///   never reintroduce the bug this file exists to fix.
///
/// Two views over one cache: `environment()` for user-initiated work (setup/teardown scripts get
/// the user's real environment), `path()` for the automatic status sweep, which runs unattended
/// and has no reason to be widened.
enum ShellEnvironment {
  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "ShellEnvironment")

  // MARK: Shell

  static func loginShell() -> String {
    ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
  }

  /// Shells whose `-lic` we trust to mean "login + interactive". Anything else (fish, nushell,
  /// csh) falls back to a login `/bin/sh -lc`, whose interactive rc won't load — a documented
  /// limitation (issue #7, fold #7). That fallback still sources `/etc/profile`, so `path_helper`
  /// runs and those users get the same floor everyone else does.
  private static let posixShells: Set<String> = ["zsh", "bash", "sh", "dash", "ksh"]

  /// The shell we'll actually exec: `$SHELL` when we recognise it, `/bin/sh` otherwise.
  static func loginShellExecutable(shell: String = loginShell()) -> String {
    posixShells.contains((shell as NSString).lastPathComponent) ? shell : "/bin/sh"
  }

  /// How to run `script` through the user's login+interactive shell.
  ///
  /// Two forms because there are two kinds of caller. `argv` is for `Process`, which wants an
  /// executable and an argument list. `commandString` is for libghostty's `config.command`, which
  /// is a single shell string — `AppStore.runCommandLine` embeds the shell word mid-string and
  /// cannot use an argv. Both share one allowlist so the two paths can't drift.
  static func loginShellInvocation(script: String, shell: String = loginShell())
    -> (argv: (executable: String, args: [String]), commandString: String)
  {
    let isPOSIX = posixShells.contains((shell as NSString).lastPathComponent)
    let executable = loginShellExecutable(shell: shell)
    let flag = isPOSIX ? "-lic" : "-lc"
    let q = CommandLineInstaller.shellQuoted
    return (
      argv: (executable: executable, args: [flag, script]),
      commandString: "\(q(executable)) \(flag) \(q(script))"
    )
  }

  // MARK: The floor

  /// Tool directories a Mac dev box almost always has but that no system file lists: both
  /// Homebrew prefixes, `/usr/local/bin`, and `~/.local/bin` — where the `claude` installer (and
  /// pipx, and many user CLIs) put binaries (issue #49).
  private static var wellKnownExtras: [String] {
    [
      "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
      "\(NSHomeDirectory())/.local/bin",
    ]
  }

  /// PATH built the way `path_helper` builds it: `/etc/paths` first, then every file in
  /// `/etc/paths.d` (sorted, as `path_helper` reads the directory in order), then our well-known
  /// extras, then whatever the process already had. Deduped, first occurrence winning.
  ///
  /// Deterministic and synchronous — no shell, no subprocess. This is the answer before the probe
  /// has run and after any probe failure, and it is on its own sufficient to resolve `psql`.
  static func floorPath(
    etcPaths: String = "/etc/paths", etcPathsD: String = "/etc/paths.d",
    inherited: String? = ProcessInfo.processInfo.environment["PATH"]
  ) -> String {
    var parts: [String] = []
    var seen = Set<String>()
    func append(_ entries: [String]) {
      for entry in entries {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
        seen.insert(trimmed)
        parts.append(trimmed)
      }
    }

    append(readPathFile(etcPaths))
    let fm = FileManager.default
    let fragments = (try? fm.contentsOfDirectory(atPath: etcPathsD))?.sorted() ?? []
    for fragment in fragments {
      append(readPathFile((etcPathsD as NSString).appendingPathComponent(fragment)))
    }
    append(wellKnownExtras)
    append((inherited ?? "").split(separator: ":").map(String.init))

    // A path_helper-shaped read that somehow found nothing still has to return something usable.
    if parts.isEmpty { append(["/usr/bin", "/bin", "/usr/sbin", "/sbin"]) }
    return parts.joined(separator: ":")
  }

  /// One directory per line; blank lines and `#` comments ignored (path_helper skips them too).
  private static func readPathFile(_ path: String) -> [String] {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return contents.split(separator: "\n").map(String.init).filter {
      let t = $0.trimmingCharacters(in: .whitespaces)
      return !t.isEmpty && !t.hasPrefix("#")
    }
  }

  // MARK: The probe

  /// Why a probe didn't produce an environment. Carried so the fallback is diagnosable — a silent
  /// degradation is indistinguishable from the bug this file fixes, which is the single most
  /// expensive failure shape available here.
  enum ProbeFailure: String, Error {
    case spawnFailed
    case timedOut
    case nonZeroExit
    case noMarkers
    case noPath
  }

  /// Variables that describe the *probe shell's own* state, or that we injected ourselves, and so
  /// must not be transplanted into a child. `WORKROOM_SHELL_PROBE` is the subtle one: we set it so
  /// users can guard expensive rc blocks, and `env` faithfully reports it straight back to us — so
  /// without this every setup script would run with the flag set, and a script that itself starts
  /// a login shell would see it and skip the very rc blocks it was meant to guard.
  private static let denylist: Set<String> = [
    "PWD", "OLDPWD", "SHLVL", "_", "WORKROOM_SHELL_PROBE",
  ]

  /// Applied *after* the probed environment, so a dotfile can never revoke them. Git must not
  /// prompt for credentials with nobody watching, and must not take a lock during a read.
  private static let appOverrides = [
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_OPTIONAL_LOCKS": "0",
  ]

  /// The minimal PATH the probe is spawned with.
  ///
  /// This matters more than it looks. `path_helper` **appends** whatever PATH it is handed after
  /// `/etc/paths` + `/etc/paths.d`, so handing it the app's own already-augmented PATH pushes
  /// Homebrew to the *tail* — a position it never occupies in a real terminal — and the dedupe
  /// below would then lock `/usr/bin/git` in ahead of `/opt/homebrew/bin/git`. Starting from the
  /// system minimum makes the probe compose exactly what a login shell composes.
  private static let probeSpawnPath = "/usr/bin:/bin:/usr/sbin:/sbin"

  /// Cap on retained probe output. A pathological rc that prints megabytes before the marker can't
  /// blow memory; the reader keeps draining past the cap so the child never blocks on a full pipe.
  private static let maxBytes = 1 * 1024 * 1024

  /// Ask the user's login+interactive shell for its whole environment.
  ///
  /// The payload is a **raw NUL-separated `env -0` stream** written between two copies of a
  /// per-probe UUID. Deliberately not `"$(env -0)"`: command substitution strips NUL bytes, which
  /// silently welds every variable into one. Deliberately not base64 either — `base64` resolves
  /// through the *user's* PATH, and GNU coreutils' wraps at 76 columns, which
  /// `Data(base64Encoded:)` rejects. A raw stream between markers needs neither.
  ///
  /// Blocking: call it through `runBlocking`, never on the cooperative pool. The deadline is a
  /// `DispatchWorkItem` **inside** this function rather than a `withTimeout` wrapper, because
  /// `withTimeout` cannot cancel a blocking call mid-flight (see `Timeout.swift`) — the caller
  /// would resume while the wedged shell kept running, leaking a process and a thread per call.
  static func probe(shell: String = loginShell(), timeout: TimeInterval = 3)
    -> Result<[String: String], ProbeFailure>
  {
    let uuid = UUID().uuidString
    let script =
      "printf '%s' \(CommandLineInstaller.shellQuoted(uuid)); env -0; "
      + "printf '%s' \(CommandLineInstaller.shellQuoted(uuid))"
    let invocation = loginShellInvocation(script: script, shell: shell).argv

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: invocation.executable)
    proc.arguments = invocation.args
    // Home, not the app's cwd and never a workroom: an interactive rc can read directory-local
    // tool config (`.mise.toml`, `.nvmrc`, `.envrc`), and a workroom may be a clone we haven't read.
    proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

    var env = ProcessInfo.processInfo.environment
    env["PATH"] = probeSpawnPath
    env["WORKROOM_SHELL_PROBE"] = "1"
    proc.environment = env

    let outPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = FileHandle.nullDevice
    // An rc that reads stdin (compinit's insecure-directories prompt, oh-my-zsh's auto-update)
    // gets EOF instead of blocking forever.
    proc.standardInput = FileHandle.nullDevice

    do { try proc.run() } catch { return .failure(.spawnFailed) }

    let timedOut = Locked(false)
    let deadline = DispatchWorkItem {
      guard proc.isRunning else { return }
      timedOut.set(true)
      proc.terminate()
      DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
      }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

    var buf = Data()
    let handle = outPipe.fileHandleForReading
    while true {
      let chunk = handle.availableData
      if chunk.isEmpty { break }
      if buf.count < maxBytes { buf.append(chunk.prefix(maxBytes - buf.count)) }
    }
    proc.waitUntilExit()
    deadline.cancel()

    if timedOut.get() { return .failure(.timedOut) }
    guard proc.terminationStatus == 0 else { return .failure(.nonZeroExit) }
    guard let parsed = parseProbeOutput(buf, uuid: uuid) else { return .failure(.noMarkers) }
    guard parsed["PATH"] != nil else { return .failure(.noPath) }
    return .success(parsed)
  }

  /// Pull the `env -0` payload out from between the two UUID markers and split it.
  ///
  /// Anchored on the **first** marker and the **next** one after it, not on the last pair: rc noise
  /// arrives on both sides (powerlevel10k's instant prompt before, `~/.zlogout`'s `clear` after),
  /// and last-pair matching would take the closing marker plus trailing junk as the payload.
  static func parseProbeOutput(_ data: Data, uuid: String) -> [String: String]? {
    guard let marker = uuid.data(using: .utf8),
      let open = data.range(of: marker),
      let close = data.range(of: marker, in: open.upperBound..<data.endIndex)
    else { return nil }

    let payload = data[open.upperBound..<close.lowerBound]
    guard !payload.isEmpty else { return nil }

    var result: [String: String] = [:]
    for entry in payload.split(separator: 0, omittingEmptySubsequences: true) {
      guard let text = String(data: Data(entry), encoding: .utf8),
        let split = text.firstIndex(of: "=")
      else { continue }  // no '=' → not a variable; '=' inside the value is preserved
      result[String(text[text.startIndex..<split])] = String(text[text.index(after: split)...])
    }
    return result.isEmpty ? nil : result
  }

  // MARK: Merge

  /// Layer the probed environment into the one we'll hand to children. Order is load-bearing:
  /// probed values form the base, our own bookkeeping comes out, and the app's overrides go on
  /// **last** so no dotfile can revoke them. PATH is unioned with the floor rather than replaced,
  /// so a probe that somehow returns less than the floor can't make things worse.
  static func merge(probed: [String: String], floor: String = floorPath()) -> [String: String] {
    var merged = probed
    for key in denylist { merged.removeValue(forKey: key) }
    for (key, value) in appOverrides { merged[key] = value }

    var parts: [String] = []
    var seen = Set<String>()
    for entry in ((probed["PATH"] ?? "") + ":" + floor).split(separator: ":").map(String.init) {
      guard !entry.isEmpty, !seen.contains(entry) else { continue }
      seen.insert(entry)
      parts.append(entry)
    }
    merged["PATH"] = parts.joined(separator: ":")
    return merged
  }

  // MARK: Cache

  private static let state = ProbeState()

  /// PATH for callers that need nothing else — the automatic status sweep, VCS reads, `list`.
  static func path() -> String {
    state.cached()?["PATH"] ?? floorPath()
  }

  /// The full environment, for user-initiated work whose children are the user's own code:
  /// setup and teardown scripts. Before the first successful probe this is the app's own
  /// environment with the floor's PATH.
  static func environment() -> [String: String] {
    if let cached = state.cached() { return cached }
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = floorPath()
    for (key, value) in appOverrides { env[key] = value }
    return env
  }

  /// Re-read the environment from the user's shell, replacing the cache on success.
  ///
  /// **Single-flight**: concurrent callers (the New Workroom dialog warming it, then Create
  /// awaiting it) share one probe rather than racing two shells. A generation counter means a slow
  /// probe that finishes after a newer one cannot overwrite the newer result.
  ///
  /// Never throws and never clears a good cache — on failure the previous value (or the floor)
  /// stands, and the reason is logged plus breadcrumbed.
  @discardableResult
  static func refresh(shell: String = loginShell()) async -> [String: String] {
    // Look-up and registration happen under ONE lock. Checking for an in-flight task and then
    // registering our own as two steps is a race the warm/await pair hits routinely: the dialog's
    // warm and Create's await both look before either has registered, and two login shells start.
    let task = state.existingOrRegister { generation in
      Task<[String: String], Never> {
        let result: Result<[String: String], ProbeFailure>
        do {
          result = try await runBlocking { probe(shell: shell) }
        } catch {
          result = .failure(.spawnFailed)
        }

        switch result {
        case .success(let probed):
          let merged = merge(probed: probed)
          state.store(merged, generation: generation)
          return merged
        case .failure(let reason):
          report(reason)
          return environment()
        }
      }
    }
    let value = await task.value
    state.clearInFlight(task)
    return value
  }

  /// Log the reason a probe failed. The *case* only — never the payload or the merged environment,
  /// which carry whatever the user's shell exports.
  private static func report(_ reason: ProbeFailure) {
    logger.warning(
      "shell environment probe failed (\(reason.rawValue, privacy: .public)); using the PATH floor")
    let crumb = Breadcrumb(level: .warning, category: "shell-env")
    crumb.message = "probe failed: \(reason.rawValue)"
    SentrySDK.addBreadcrumb(crumb)
  }

  /// Test seam: drop the cache and any in-flight probe.
  static func resetForTesting() { state.reset() }
}

/// The cache behind `ShellEnvironment`, plus the single-flight bookkeeping.
///
/// A lock rather than an actor because `path()` is read synchronously from the main thread (window
/// setup, terminal creation) and from background queues, and neither can await.
private final class ProbeState: @unchecked Sendable {
  private let lock = NSLock()
  private var value: [String: String]?
  private var generation = 0
  private var stored = -1
  private var task: Task<[String: String], Never>?

  func cached() -> [String: String]? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  /// The in-flight probe, or a newly registered one — decided under a single lock so two callers
  /// can never both conclude they're first. `make` receives the generation to stamp its result
  /// with; creating a `Task` here only schedules it, so nothing runs while the lock is held.
  func existingOrRegister(_ make: (Int) -> Task<[String: String], Never>)
    -> Task<[String: String], Never>
  {
    lock.lock()
    defer { lock.unlock() }
    if let task { return task }
    generation += 1
    let created = make(generation)
    task = created
    return created
  }

  /// Ignores a result from a probe older than one we've already stored — the late-writer case.
  func store(_ env: [String: String], generation gen: Int) {
    lock.lock()
    defer { lock.unlock() }
    guard gen > stored else { return }
    stored = gen
    value = env
  }

  func clearInFlight(_ finished: Task<[String: String], Never>) {
    lock.lock()
    defer { lock.unlock() }
    if task == finished { task = nil }
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    value = nil
    generation = 0
    stored = -1
    task = nil
  }
}

/// Minimal lock-guarded box, for sharing a flag with a `DispatchWorkItem`.
private final class Locked<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: T
  init(_ value: T) { self.value = value }
  func get() -> T {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func set(_ new: T) {
    lock.lock()
    defer { lock.unlock() }
    value = new
  }
}
