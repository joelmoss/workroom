import CryptoKit
import DaemonConnection
import Foundation
import HostDrivers
import WorkroomSystem
import WorkroomVCS
import os

/// Puts the Linux daemon this app bundles on a remote host, and replaces the one running there
/// with it, before any service connects (#231; design doc, "Daemon bootstrap over the transport").
/// Workroom.app is the one source of the daemon: no provider image carries it, so a host with none
/// gets it on first connect, and a host running an older one is handed off to this one (#230),
/// keeping every shell. `connect` is the way to a remote host's services; nothing else should
/// open a service stream to one.
///
/// The far side of this is two shell scripts (`Resources/daemon-bootstrap`, run through
/// `HostDriver.exec`), which also say where the binary goes: **beside the socket**
/// (`DaemonInstall.binary(besideSocket:)`), in the socket's 0700 directory, which is the trust boundary already
/// (a client of the socket can type into every session). The supervisor starts the daemon from
/// there, and the relay and the attach run it from there. The scripts stage a pushed binary, run it
/// once (`protocol`), offer it to the running daemon (`hand-off`, which checks that the new program
/// can restore every session), and rename it into place only when nothing refused it: relay,
/// attach and the supervisor execute the on-disk file, so an unchecked one there would break them
/// even while the old daemon lives. A refusal leaves the old daemon running, and the app connects to
/// it over the versioned envelope.
///
/// Two hashes answer two questions. The app hashes its bundled binary (SHA-256) and the probe
/// hashes the installed one, which decides whether to push at all: the same build pushes nothing.
/// The daemon hashes its own program at startup (`handoff.rs`, a process-local hash) and answers
/// `current` when the file it is offered is that program, which decides whether to hand off. The
/// probe asks for a hand-off only when the installed file IS the bundled one, so the app never
/// hands off to a binary it does not recognise: a different one is replaced by the install first,
/// which does its own hand-off.
enum DaemonBootstrap {
  struct Outcome: Equatable, Sendable {
    enum Daemon: Equatable, Sendable {
      /// The daemon runs this app's binary.
      case current
      /// Nothing was running, and this app's binary is the installed one: after a push, the
      /// install waited for the supervisor to start it; for a file already there, that start is
      /// the supervisor's (as after a reboot), and the connect that follows may find it not yet
      /// up.
      case installed
      /// The running daemon replaced its program with this app's, keeping every session.
      case handedOff
      /// What is there was left as it is, with why: the daemon predates hand-off, or refused
      /// (busy, or this binary cannot restore its sessions), or hand-off is off, or this build
      /// has no daemon for the host, or the host cannot hash, or the install did not go through.
      /// The app connects to whatever runs, over the versioned envelope.
      case keptOlder(String)
      /// The host runs a daemon built after this app's, which is never replaced with an older one
      /// (#255, D13): two Macs on different builds would otherwise swap the host's daemon on every
      /// connect. The app connects to it over the versioned envelope.
      case keptNewer(String)
    }
    /// Ghostty's terminfo and shell integration beside the daemon (#239), for the host's panes.
    enum Resources: Equatable, Sendable {
      /// The host holds this build's set; nothing crossed.
      case current
      case pushed
      /// The host has no set from this build, with why. Its panes run as `xterm-256color`, without
      /// the integration: the remote attach checks for the set when it starts.
      case notPushed(String)
    }
    let architecture: String
    /// Whether the binary crossed the transport. False for a host already holding this build.
    let pushed: Bool
    let daemon: Daemon
    /// Nil when this build had no set to push (a test's).
    var resources: Resources? = nil
  }

  enum Error: Swift.Error, Equatable, LocalizedError {
    /// The probe said `uname -s -m`, and it is not a Linux this app has a daemon for.
    case unsupportedHost(String)
    /// The host has no daemon, and this build bundles none for its architecture.
    case noBundledDaemon(String)
    /// An exchange with the host that did not go through: ssh refused it, the link died or went
    /// silent, or a script's report was cut short. Either script's.
    case transportFailed(String)
    /// The script itself said no (the bundled daemon does not run there, say), on a host with
    /// nothing else to connect to.
    case installFailed(String)
    /// This build is missing a script: a packaging bug, never a host's condition.
    case missingScript(String)
    /// The host was made by an older Nightly or Dev build, before the daemon was renamed (#525):
    /// its supervisor only starts `wr-agent`, which this build can't change, so the workroom has
    /// to be made again (eng review D3).
    case olderLayout

    var errorDescription: String? {
      switch self {
      case .unsupportedHost(let host): return "No daemon for this host: \(host)."
      case .noBundledDaemon(let arch):
        return "The host has no daemon, and this build bundles none for \(arch)."
      case .transportFailed(let detail): return "Could not reach the host's daemon: \(detail)"
      case .installFailed(let detail): return "Could not install the daemon: \(detail)"
      case .missingScript(let name): return "This build has no daemon-bootstrap/\(name).sh."
      case .olderLayout: return DaemonInstall.formerLayoutMessage
      }
    }
  }

  /// How long an exchange may go with nothing sent or received before it is given up on: a bound
  /// on silence, never on the whole transfer, which would make it a throughput floor for the 11 MB
  /// push (the `WRITE_TIMEOUT` lesson in macapp/AGENTS.md). The longest silence is the hand-off
  /// CLI's own waits: ssh connecting (10 s), the daemon's bounds (5.7 s), its read of the answer
  /// (30 s) and its greeting from the new program (10 s).
  static let timeout: TimeInterval = 60
  static let architectures = ["aarch64", "x86_64"]

  private static let logger = Logger(
    subsystem: "com.developwithstyle.workroom", category: "PersistentSession")

  /// The bootstrap, then the connection: the one way to a remote host's services.
  static func connect(
    host: HostID, driver: any HostDriver, socket: String,
    daemon: (String) -> URL? = PersistentSessionPaths.linuxDaemonURL(architecture:),
    handOff: Bool = true, resources: URL? = GhosttyResources.bundledURL
  ) async throws -> DaemonVCSConnection {
    let outcome = try await ensure(
      host: host, driver: driver, socket: socket, daemon: daemon, handOff: handOff,
      resources: resources)
    logger.notice("daemon bootstrap: \(String(describing: outcome), privacy: .public)")
    return try await DaemonVCSConnection.connect(
      host: host, stream: try await driver.openStream(to: host))
  }

  /// Makes sure the host runs this app's daemon, as far as the policy above allows, and says what
  /// it found. Safe to run on every connect: a host already holding this build costs one probe.
  ///
  /// `daemon` finds the bundled binary for an architecture (the bundle's, or a test's), and
  /// `resources` is the bundled Ghostty tree whose terminfo and shell integration go beside it.
  /// `handOff` is on in every build, as the local hand-off (`DaemonHandOff`) is: off, a
  /// remote host keeps its first daemon until the box restarts, since its supervisor never lets it
  /// idle out, and so never gets a newer build's services.
  static func ensure(
    host: HostID, driver: any HostDriver, socket: String,
    daemon: (String) -> URL? = PersistentSessionPaths.linuxDaemonURL(architecture:),
    handOff: Bool = true, resources: URL? = GhosttyResources.bundledURL
  ) async throws -> Outcome {
    let binary = DaemonInstall.binary(besideSocket: socket)
    let urls = architectures.compactMap { architecture in
      daemon(architecture).map { (architecture, $0) }
    }
    // Reading and hashing two 11 MB files is blocking work, off the cooperative pool.
    let bundled: [String: (url: URL, digest: String, build: UInt64)] = try await runBlocking {
      try Dictionary(
        uniqueKeysWithValues: urls.map { architecture, url in
          let data = try Data(contentsOf: url)
          return (architecture, (url, digest(of: data), buildNumber(in: data)))
        })
    }
    let probe = try await run(
      script: "probe", on: host, driver: driver, input: nil,
      arguments: [binary, socket, handOff ? "1" : "0"]
        + architectures.map { bundled[$0]?.digest ?? "-" } + [
          DaemonInstall.resources(besideSocket: socket),
          DaemonInstall.formerBinary(besideSocket: socket),
        ])
    let report = try parseProbe(probe.output)
    if report.former { throw Error.olderLayout }
    // A probe cut off part way (its hand-off is the long step) would read as "not asked".
    guard probe.status == 0 else {
      throw Error.transportFailed("the probe did not finish (exit \(probe.status))")
    }
    guard report.system == "Linux", architectures.contains(report.architecture) else {
      throw Error.unsupportedHost("\(report.system) \(report.architecture)")
    }
    let architecture = report.architecture
    // Never an older daemon over a newer one (#255, D13), nor its terminfo and shell integration:
    // one set serves every pane on the host, and the newer daemon's clients expect their own.
    let hostIsNewer: Bool = {
      guard let theirs = report.build, let ours = bundled[architecture]?.build, ours > 0 else {
        return false
      }
      return theirs > ours
    }()
    let set =
      hostIsNewer
      ? resources.map { _ in .notPushed("the host runs a newer build") }
      : await ensureResources(
        resources, installed: report.resources,
        directory: DaemonInstall.resources(besideSocket: socket),
        on: host, driver: driver)
    guard
      let (url, digest, build) = bundled[architecture].map({ ($0.url, $0.digest, $0.build) })
    else {
      guard report.installed != nil else { throw Error.noBundledDaemon(architecture) }
      return Outcome(
        architecture: architecture, pushed: false,
        daemon: .keptOlder("this build has no daemon for \(architecture)"), resources: set)
    }
    // Nothing to compare against, and the install would refuse the push for the same reason.
    if report.installed == "unknown" {
      return Outcome(
        architecture: architecture, pushed: false,
        daemon: .keptOlder("the host has no sha256sum"), resources: set)
    }
    if report.installed == digest {
      let daemon: Outcome.Daemon
      switch report.handOff {
      case .off: daemon = .keptOlder("hand-off is off")
      // The file is there and nothing listens: the supervisor's to start, as after a reboot.
      case .noSocket: daemon = .installed
      case .notAsked, .answered(0, "current"): daemon = .current
      case .answered(0, _): daemon = .handedOff
      case .answered(3, _): daemon = .keptOlder("the daemon predates hand-off")
      case .answered(92, let said):
        daemon =
          said.contains("no daemon listening") ? .installed : .keptOlder("the daemon did not greet")
      case .answered(_, let said):
        daemon = .keptOlder(said.isEmpty ? "the hand-off was refused" : said)
      }
      return Outcome(architecture: architecture, pushed: false, daemon: daemon, resources: set)
    }

    // Never an older daemon over a newer one (#255, D13). A host daemon that predates build numbers
    // reports none, and is replaced; so is everything when this build has no number (0).
    if let theirs = report.build, build > 0, theirs > build {
      return Outcome(
        architecture: architecture, pushed: false,
        daemon: .keptNewer("the host runs build \(theirs), newer than this app's \(build)"),
        resources: set)
    }

    let elf = try await runBlocking { try Data(contentsOf: url) }
    let install: (status: Int32, output: String)
    do {
      install = try await run(
        script: "install", on: host, driver: driver, input: elf,
        arguments: [binary, socket, handOff ? "1" : "0", digest])
    } catch Error.transportFailed(let detail) {
      // Refuse rather than kill, at the transport too: an install that could not be carried out
      // (a link that dropped mid-push, or went silent) leaves whatever daemon is there, and the
      // app connects to it. Only a host with nothing to connect to fails.
      guard report.installed != nil else { throw Error.transportFailed(detail) }
      return Outcome(
        architecture: architecture, pushed: true,
        daemon: .keptOlder("the install failed: \(detail)"), resources: set)
    }
    let (outcome, serving) = parseInstall(install.output)
    let daemon: Outcome.Daemon
    switch outcome.first {
    case "installed":
      // `serving` is always printed after `installed`; its absence is an install cut short.
      guard let serving else { throw Error.installFailed("the install did not finish") }
      guard serving else {
        throw Error.installFailed("installed, but the supervisor did not start it within 10s")
      }
      daemon = .installed
    case "handed-off": daemon = .handedOff
    case "current": daemon = .current
    case "kept-older": daemon = .keptOlder(outcome.dropFirst().joined(separator: " "))
    case "refused": daemon = .keptOlder("refused: " + outcome.dropFirst().joined(separator: " "))
    case .some:
      // The script said no before anything was replaced. A daemon already there is still a
      // daemon, and the app connects to it; a host with none has nothing to run.
      let why = describe(outcome)
      guard report.installed != nil else { throw Error.installFailed(why) }
      daemon = .keptOlder("the install failed: \(why)")
    case nil:
      // A report cut short (`received` but no outcome: the link went mid-check): as above.
      let said = install.output.trimmingCharacters(in: .whitespacesAndNewlines)
      let why = said.isEmpty ? "the install said nothing (exit \(install.status))" : said
      guard report.installed != nil else { throw Error.installFailed(why) }
      daemon = .keptOlder("the install did not finish: \(why)")
    }
    return Outcome(architecture: architecture, pushed: true, daemon: daemon, resources: set)
  }

  /// Puts `bundle`'s terminfo and shell integration at `directory` on the host, unless the probe
  /// found this build's set there already (#239). A failure here is logged in the outcome and
  /// never fails the connect: the host's panes run without the integration, as they did before.
  ///
  /// The set is what `CHECKSUMS` lists, plus `CHECKSUMS` itself, and its hash is the set's key: it
  /// changes with the files, so a Ghostty pin bump that changes them pushes them again.
  private static func ensureResources(
    _ bundle: URL?, installed: String?, directory: String, on host: HostID,
    driver: any HostDriver
  ) async -> Outcome.Resources? {
    guard let bundle else { return nil }
    if installed == "unknown" { return .notPushed("the host has no sha256sum") }
    do {
      let (digest, files) = try await runBlocking { () throws -> (String, [(String, Data)]) in
        let manifest = bundle.appendingPathComponent("CHECKSUMS")
        let paths = try String(contentsOf: manifest, encoding: .utf8)
          .split(whereSeparator: \.isNewline)
          .compactMap { line in line.range(of: "  ").map { String(line[$0.upperBound...]) } }
        let files = try (paths + ["CHECKSUMS"]).map { path in
          (path, try Data(contentsOf: bundle.appendingPathComponent(path)))
        }
        return (try Self.digest(of: manifest), files)
      }
      if installed == digest { return .current }
      let result = try await run(
        script: "resources", on: host, driver: driver,
        input: files.reduce(into: Data()) { $0 += $1.1 },
        arguments: [directory] + files.flatMap { [String($0.1.count), $0.0] })
      let outcome = parseInstall(result.output).outcome
      guard outcome.first == "installed" else {
        return .notPushed(
          outcome.isEmpty
            ? "the push said nothing (exit \(result.status))"
            : outcome.joined(separator: " "))
      }
      return .pushed
    } catch {
      return .notPushed(error.localizedDescription)
    }
  }

  /// An install outcome the script ended on, in words a person can act on; the raw words are in
  /// the log line either way.
  private static func describe(_ outcome: [String]) -> String {
    switch outcome.first {
    case "does-not-run": return "the bundled daemon does not run on this host"
    case "truncated": return "the push arrived incomplete"
    case "no-sha256sum": return "the host has no sha256sum"
    case "write-failed": return "could not write beside the socket"
    default: return outcome.joined(separator: " ")
    }
  }

  // MARK: - The far side

  struct ProbeReport: Equatable {
    enum HandOff: Equatable {
      case off
      case noSocket
      /// The installed binary is not this build, so the install decides.
      case notAsked
      /// `workroomd hand-off`'s exit status and first line.
      case answered(Int32, String)
    }
    let system: String
    let architecture: String
    /// SHA-256 of the installed binary, `unknown` for a host without `sha256sum`, or nil for
    /// none. A host that cannot hash is not pushed to (`ensure` keeps what is there): the install
    /// would refuse the push for the same reason.
    let installed: String?
    /// The hash of the Ghostty resource set there, `unknown`, or nil for none (#239).
    var resources: String? = nil
    let handOff: HandOff
    /// The installed daemon's build number (`workroomd protocol`'s `build-number`), or nil when there
    /// is none, it predates build numbers, or it would not run (#255).
    var build: UInt64? = nil
    /// No daemon there, but a pre-#525 `wr-agent` is: an older Nightly's host (`olderLayout`).
    var former = false
  }

  /// The probe's six lines. Anything not prefixed `WRB ` is whatever the host's shell startup
  /// printed, and skipped.
  static func parseProbe(_ output: String) throws -> ProbeReport {
    let fields = reports(in: output)
    guard let host = fields["host"], host.count >= 2 else {
      throw Error.transportFailed(
        "no report from the host: "
          + output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let installed = fields["installed"]?.first
    let handOff: ProbeReport.HandOff
    let answer = fields["hand-off"] ?? []
    switch answer.first {
    case "off": handOff = .off
    case "no-socket": handOff = .noSocket
    // No line at all: a probe cut short before its last line, which `ensure` fails on its status.
    case "none", nil: handOff = .notAsked
    case let word?:
      guard let status = Int32(word) else {
        throw Error.transportFailed("the probe's hand-off line was cut short: \(word)")
      }
      handOff = .answered(status, answer.dropFirst().joined(separator: " "))
    }
    let resources = fields["resources"]?.first
    return ProbeReport(
      system: host[0], architecture: host[1],
      installed: installed == nil || installed == "none" ? nil : installed,
      resources: resources == "none" ? nil : resources, handOff: handOff,
      build: fields["build"]?.first.flatMap { UInt64($0) },
      former: fields["former"]?.first == "yes")
  }

  /// The install's outcome words, and whether the supervisor started the daemon (nil when that was
  /// not in question).
  static func parseInstall(_ output: String) -> (outcome: [String], serving: Bool?) {
    let fields = reports(in: output)
    let serving: Bool? = fields["serving"].map { $0.first == "yes" }
    return (fields["outcome"] ?? [], serving)
  }

  private static func reports(in output: String) -> [String: [String]] {
    var fields: [String: [String]] = [:]
    for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("WRB ") {
      let words = line.dropFirst(4).split(separator: " ").map(String.init)
      guard let key = words.first else { continue }
      fields[key] = Array(words.dropFirst())
    }
    return fields
  }

  /// Runs a bundled script on the host through the driver, as `sh -c '<script>' <name> <args>`.
  private static func run(
    script name: String, on host: HostID, driver: any HostDriver, input: Data?,
    arguments: [String]
  ) async throws -> (status: Int32, output: String) {
    let command = (["sh", "-c", try script(named: name), name] + arguments)
      .map(PosixShell.quoted).joined(separator: " ")
    let stream = try await driver.exec(command, on: host)
    let result: (status: Int32, output: String)
    do {
      result = try await stream.communicate(input, timeout: timeout)
    } catch HostConnectionError.serviceUnavailable(let detail) {
      throw Error.transportFailed(detail)
    }
    // No report at all is the transport's failure, not the script's (the scripts print one before
    // anything else can go wrong): ssh refused the host key, or the link died mid-exchange. Its
    // stderr says which. One failure, classified one way, however far the exchange got.
    guard result.output.contains("WRB ") else {
      let said = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      throw Error.transportFailed(
        said.isEmpty ? "\(name) got no answer from the host (exit \(result.status))" : said)
    }
    return result
  }

  static func script(named name: String) throws -> String {
    guard
      let url = Bundle.main.url(
        forResource: name, withExtension: "sh", subdirectory: "daemon-bootstrap")
    else { throw Error.missingScript(name) }
    return try String(contentsOf: url, encoding: .utf8)
  }

  /// SHA-256 of a bundled binary, as the host's `sha256sum` prints it. Not cached: an update
  /// swaps the bundle under a running app, and 11 MB hashes in a few milliseconds.
  static func digest(of url: URL) throws -> String {
    digest(of: try Data(contentsOf: url))
  }

  static func digest(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// The build number a bundled daemon was built with, read out of its bytes rather than by running
  /// it: the bundled daemons are Linux binaries the Mac cannot run. The daemon keeps it as the
  /// marker `WORKROOMD-BUILD:<number>;` (`handoff::BUILD_MARKER`). 0 when there is none, which orders
  /// below every numbered build.
  static func buildNumber(in data: Data) -> UInt64 {
    let marker = Data("WORKROOMD-BUILD:".utf8)
    guard let start = data.range(of: marker)?.upperBound else { return 0 }
    let digits = data[start...].prefix { (0x30...0x39).contains($0) }
    guard data.index(start, offsetBy: digits.count) < data.endIndex,
      data[data.index(start, offsetBy: digits.count)] == UInt8(ascii: ";")
    else { return 0 }
    return UInt64(String(decoding: digits, as: UTF8.self)) ?? 0
  }
}
