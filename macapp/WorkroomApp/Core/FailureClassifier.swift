import Foundation

/// What to do with a finished command (issue #49, decision A3). Pure — the `@MainActor` manager
/// (T6b) layers debounce/cooldown/auto-vs-manual on top.
enum FailureDisposition: Equatable {
  /// Not worth surfacing (success, user/system interrupt, or nothing captured to diagnose).
  case skip
  /// A failure, but soft-suppressed: no banner and no auto-fire by default (a program where a
  /// non-zero exit is routine), yet a manual "Diagnose last command" action still works.
  case manualOnly
  /// A real failure: show the banner, and auto-fire when the user has enabled auto-diagnose.
  case eligible
}

/// Decides whether a finished command's exit code is a real failure worth diagnosing — and filters
/// the noise (grep/diff/test exit 1, ⌃C, etc.). All pure + unit-tested (A3).
enum FailureClassifier {
  /// Exit codes that never warrant a diagnosis: success and user/system interruption.
  /// 130 = SIGINT (⌃C), 143 = SIGTERM.
  static let boringExitCodes: Set<Int32> = [0, 130, 143]

  /// Programs whose non-zero exit is routine ("no match" / "differs" / "false"), so an automatic
  /// banner would be noise. Soft-suppressed (see `.manualOnly`) rather than hard-hidden, so a real
  /// failure in one of these (e.g. `grep` with a bad pattern) is still reachable via manual Diagnose.
  static let benignNonZeroPrograms: Set<String> = [
    "grep", "egrep", "fgrep", "rg", "ag", "ack", "diff", "cmp", "test", "[", "[[",
  ]

  /// Command-line wrappers to skip when finding the real program name.
  private static let wrappers: Set<String> = [
    "sudo", "doas", "command", "env", "nice", "nohup", "time", "exec", "builtin", "stdbuf",
  ]

  /// Extract the invoked program from a command line: take the LAST pipeline segment (its exit code
  /// is the command's), drop leading `VAR=value` env assignments and known wrappers, then strip a
  /// leading path. `"FOO=bar /usr/bin/grep x"` → `"grep"`, `"cat a | sort"` → `"sort"`.
  static func programName(from command: String) -> String? {
    let segment =
      command.split(separator: "|", omittingEmptySubsequences: true).last
      .map(String.init) ?? command
    var tokens = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    while let first = tokens.first, first.contains("=") || wrappers.contains(first) {
      tokens.removeFirst()
    }
    guard let raw = tokens.first, !raw.isEmpty else { return nil }
    let name = raw.split(separator: "/").last.map(String.init) ?? raw
    return name.isEmpty ? nil : name
  }

  /// True when a non-zero exit from `command` is routine for its program (→ soft-suppress).
  static func isBenignNonZero(command: String) -> Bool {
    guard let program = programName(from: command) else { return false }
    return benignNonZeroPrograms.contains(program)
  }

  /// Classify a finished command. `isRunTab` commands (the Run feature — dev server / test suite)
  /// always qualify, since those are issue #49's headline cases. `hasCapture` is whether any output
  /// text was captured (an empty capture for an ad-hoc command has nothing to diagnose).
  static func disposition(
    exitCode: Int32, command: String?, isRunTab: Bool, hasCapture: Bool
  ) -> FailureDisposition {
    if boringExitCodes.contains(exitCode) { return .skip }
    if isRunTab { return .eligible }
    if !hasCapture { return .skip }
    if let command, isBenignNonZero(command: command) { return .manualOnly }
    return .eligible
  }
}
