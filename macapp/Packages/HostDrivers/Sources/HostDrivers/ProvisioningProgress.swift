import Foundation
import WorkroomSystem

/// What a remote create tells the user while it runs (#356): the drivers report their machine work,
/// `RemoteProvisioning` (in the app) its git, and the app shows each step on the project row and in
/// the creation pane (#483).
public enum ProvisioningProgress {
  /// A step of a remote create that takes long enough to say (#356): the drivers' machine work
  /// and the sequence's own git and checks. The raw value is the step's id in the app's creation
  /// checklist (#483).
  public enum Step: String, CaseIterable, Sendable {
    case repository, account, image, machine, boot, setup, connect, clone, checkout
  }

  /// Told each `Step` as it starts, for a create's progress on its project row. Set with
  /// `ProvisioningProgress.$reportStep.withValue`: a task-local, so the driver's methods keep their
  /// shape, as `ContainerHostDriver.$pullProgress` does for an image pull.
  @TaskLocal public static var reportStep: (@Sendable (Step) -> Void)?

  /// Told each line of a create's log, with the step it belongs to (#483): a command as
  /// `$ <command line>`, then its output. The step travels with the line, so a line is never filed
  /// under the next step when the app hops to the main actor. Never carries an environment
  /// variable, a script fed on stdin or a token: see `commandLine`.
  @TaskLocal public static var log: (@Sendable (Step, String) -> Void)?

  /// The step the work running now belongs to, set by `step(_:report:_:)`.
  @TaskLocal static var current: Step?

  /// Runs `body` as `step`: its log lines name the step, and the step is announced to `reportStep`
  /// unless `report` is false, for work inside a step that is already announced (or one the app
  /// announces itself).
  public static func step<T>(
    _ step: Step, report: Bool = true, _ body: () async throws -> T
  ) async rethrows -> T {
    if report { reportStep?(step) }
    return try await $current.withValue(step) { try await body() }
  }

  /// Logs `text`, line by line, under the current step. Nothing when there is no sink or no step.
  static func record(_ text: String) {
    guard let log, let current else { return }
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      log(current, String(line))
    }
  }

  /// One command's exchange, logged: `shown` before it runs and its output after, unless
  /// `logOutput` says not to for the status it exited with. `shown` is the caller's to make safe: a
  /// command line (`commandLine`, or `$ ` and a shell line), never its environment, a script fed on
  /// its stdin or a token. Nil logs nothing.
  static func logged(
    _ shown: String?, logOutput: (Int32) -> Bool = { _ in true },
    _ exchange: () async throws -> (status: Int32, output: String)
  ) async rethrows -> (status: Int32, output: String) {
    if let shown { record(shown) }
    let result = try await exchange()
    if shown != nil, logOutput(result.status) { record(result.output) }
    return result
  }

  /// Logs a command as it starts.
  static func record(command program: String, _ arguments: [String]) {
    guard log != nil else { return }
    record(commandLine(program, arguments))
  }

  /// `$ <program> <arguments>` for the log, as a person would type it. A value is replaced by `…`
  /// where it can carry a credential: an environment variable's (`--env`, `-e`, a bare `NAME=value`
  /// in capitals), and the value of any option named for a token, password or secret.
  static func commandLine(_ program: String, _ arguments: [String]) -> String {
    var parts = [(program as NSString).lastPathComponent]
    var hideNext = false
    for argument in arguments {
      parts.append(hideNext ? hidden(argument) : redacted(argument))
      hideNext =
        !hideNext && argument.hasPrefix("-") && !argument.contains("=")
        && takesSecret(argument)
    }
    return "$ " + parts.map(display).joined(separator: " ")
  }

  private static func takesSecret(_ flag: String) -> Bool {
    if ["--env", "-e", "--env-file"].contains(flag) { return true }
    let name = flag.lowercased()
    return ["token", "password", "passwd", "secret", "credential"].contains { name.contains($0) }
  }

  /// An option's value, or a bare variable assignment.
  private static func redacted(_ argument: String) -> String {
    if argument.hasPrefix("-"), let equals = argument.firstIndex(of: "=") {
      let flag = String(argument[..<equals])
      let value = String(argument[argument.index(after: equals)...])
      return flag + "=" + (takesSecret(flag) ? hidden(value) : value)
    }
    if let equals = argument.firstIndex(of: "="),
      argument[..<equals].range(of: #"^[A-Z][A-Z0-9_]*$"#, options: .regularExpression) != nil
    {
      return String(argument[...equals]) + "…"
    }
    return argument
  }

  /// A value that is not shown: an assignment keeps its name (`NAME=…`), anything else goes.
  private static func hidden(_ value: String) -> String {
    guard let equals = value.firstIndex(of: "="), !value[..<equals].contains(where: \.isWhitespace)
    else { return "…" }
    return String(value[...equals]) + "…"
  }

  private static func display(_ part: String) -> String {
    part.isEmpty || part.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "\"" })
      ? PosixShell.quoted(part) : part
  }
}
