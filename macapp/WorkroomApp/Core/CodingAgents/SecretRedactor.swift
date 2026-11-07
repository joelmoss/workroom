import Foundation

/// Best-effort masking of obvious secret shapes before terminal output is sent to the agent
/// (issue #49, Stage 5 / X4). This is a reduction, NOT a guarantee — it can't catch
/// non-secret-shaped sensitive data (source, proprietary logs, customer data); the Settings caption
/// says so, and it's paired with the CLI's `--no-session-persistence` / telemetry-off flags.
enum SecretRedactor {
  static let placeholder = "«redacted»"

  /// (pattern, replacement-template) pairs. Templates keep a harmless prefix and mask the value, so
  /// redacted output still reads naturally. Conservative on purpose — over-masking normal output
  /// would degrade the diagnosis.
  private static let rules: [(NSRegularExpression, String)] = {
    let specs: [(String, String)] = [
      // KEY=VALUE / KEY: VALUE where the key name looks secret. Keep the key, mask the value.
      (
        #"(?i)\b([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API[_-]?KEY|ACCESS[_-]?KEY|PRIVATE[_-]?KEY))\b\s*[:=]\s*\S+"#,
        "$1=\(placeholder)"
      ),
      // Authorization: Bearer/Basic <token>
      (#"(?i)\bAuthorization\s*:\s*(?:Bearer|Basic)\s+\S+"#, "Authorization: \(placeholder)"),
      // Connection-string credentials scheme://user:pass@  (scheme precedes the match, preserved).
      (#"://[^\s:@/]+:[^\s:@/]+@"#, "://\(placeholder)@"),
      // Well-known provider key prefixes.
      (
        #"\b(?:sk-[A-Za-z0-9]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AKIA[A-Z0-9]{12,}|AIza[A-Za-z0-9_\-]{20,})\b"#,
        placeholder
      ),
    ]
    return specs.compactMap { pattern, template in
      (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }
  }()

  static func redact(_ text: String) -> String {
    var output = text
    for (regex, template) in rules {
      let range = NSRange(output.startIndex..<output.endIndex, in: output)
      output = regex.stringByReplacingMatches(in: output, range: range, withTemplate: template)
    }
    return output
  }
}

/// Flags shell commands that are destructive or fetch-and-execute, so the banner requires an extra
/// explicit confirmation before inserting an AI-suggested fix (issue #49, X4). A poisoned log could
/// steer the model toward `rm -rf` or `curl … | sh`; this is the guard before such text reaches a
/// live terminal.
enum DestructiveCommandDetector {
  private static let needles = [
    "rm -rf", "rm -fr", "rm -r ", "rm --recursive", "rmdir ", "mkfs", "dd if=", "dd of=",
    "shred ", "sudo ", "doas ", "chmod -r 777", "chmod 777", "chown -r", "> /dev/sd", "of=/dev/sd",
    "git push --force", "git push -f", "git reset --hard", "git clean -fd", "git clean -xfd",
    "drop table", "drop database", "truncate table", ":(){:|:&};:",
  ]

  static func isDestructive(_ command: String) -> Bool {
    let normalized = command.lowercased()
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    if needles.contains(where: { normalized.contains($0) }) { return true }
    // fetch-and-execute: curl/wget … piped into a shell
    let fetches = normalized.contains("curl ") || normalized.contains("wget ")
    let pipesToShell = ["| sh", "|sh", "| bash", "|bash", "| zsh", "|zsh"].contains {
      normalized.contains($0)
    }
    return fetches && pipesToShell
  }
}
