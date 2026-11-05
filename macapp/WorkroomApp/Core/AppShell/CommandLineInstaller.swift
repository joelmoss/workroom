import AppKit
import Foundation

/// Installs (and detects) a `workroom` command-line symlink in the user's PATH, pointing at the
/// CLI bundled inside the app — the macOS-app equivalent of VS Code's "Install 'code' command in
/// PATH". The app is non-sandboxed, so when the target directory needs root we escalate with a
/// single `osascript … with administrator privileges` prompt; when it's already user-writable
/// (e.g. a Homebrew-owned /usr/local on Intel) we symlink directly with no password.
enum CommandLineInstaller {
  /// The command name in PATH. The side-by-side nightly build installs as `workroom-nightly` so it
  /// coexists with a main-app `workroom` (issue #91); every other build is `workroom`.
  static var commandName: String {
    ReleaseChannel.isNightlyBuild ? "workroom-nightly" : "workroom"
  }

  /// Where the symlink goes. /usr/local/bin is on the default PATH for login shells.
  static var symlinkURL: URL { URL(fileURLWithPath: "/usr/local/bin/\(commandName)") }

  enum Status: Equatable {
    case notInstalled
    case installed  // symlink present, pointing at this app's bundled binary
    case conflict(String)  // something else occupies the path (other symlink target / real file)
  }

  enum Outcome: Sendable {
    case installed
    case cancelled  // user dismissed the admin prompt
    case failed(String)
  }

  // MARK: Status

  /// Whether `/usr/local/bin/workroom` is already a symlink to this app's bundled binary.
  static func status() -> Status {
    guard let source = try? WorkroomCLI.bundledBinaryURL() else { return .notInstalled }
    let fm = FileManager.default
    let path = symlinkURL.path
    if let dest = try? fm.destinationOfSymbolicLink(atPath: path) {
      let resolved =
        dest.hasPrefix("/")
        ? dest
        : symlinkURL.deletingLastPathComponent().appendingPathComponent(dest).path
      return resolved == source.path ? .installed : .conflict(dest)
    }
    return fm.fileExists(atPath: path) ? .conflict(path) : .notInstalled
  }

  // MARK: Install (non-interactive core)

  /// Creates/updates the symlink. Writes directly when the target dir is user-writable, otherwise
  /// escalates to an admin `osascript`. Safe to call off the main thread.
  static func install() -> Outcome {
    let source: URL
    do {
      source = try WorkroomCLI.bundledBinaryURL()
    } catch {
      return .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
    let dir = symlinkURL.deletingLastPathComponent()
    let fm = FileManager.default

    // Fast path: the directory exists and we can write it → no password prompt.
    if fm.isWritableFile(atPath: dir.path) {
      do {
        try? fm.removeItem(at: symlinkURL)  // replace any stale link/file
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: source)
        return .installed
      } catch {
        return .failed("Couldn't create the symlink: \(error.localizedDescription)")
      }
    }

    // Privileged path: create the dir if missing and force-link, behind one admin prompt.
    let shellCmd =
      "/bin/mkdir -p \(shellQuoted(dir.path)) && "
      + "/bin/ln -sf \(shellQuoted(source.path)) \(shellQuoted(symlinkURL.path))"
    let appleScript = "do shell script \(appleScriptQuoted(shellCmd)) with administrator privileges"

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", appleScript]
    let errPipe = Pipe()
    proc.standardError = errPipe
    proc.standardOutput = Pipe()
    do {
      try proc.run()
    } catch {
      return .failed("Couldn't run the installer: \(error.localizedDescription)")
    }
    proc.waitUntilExit()
    if proc.terminationStatus == 0 { return .installed }

    let stderr =
      String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    // osascript reports a user-cancelled admin prompt as error -128.
    if stderr.contains("-128") || stderr.localizedCaseInsensitiveContains("User canceled") {
      return .cancelled
    }
    let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return .failed(trimmed.isEmpty ? "The install command failed." : trimmed)
  }

  // MARK: Interactive (menu) entry point

  /// Runs the install with native UI: a no-op confirmation when already installed, the system
  /// admin prompt when needed, and a result alert. Call from the menu command.
  @MainActor static func runFromMenu() async {
    if case .installed = status() {
      presentAlert(
        style: .informational, title: "Command Already Installed",
        message:
          "The workroom command is already available in your PATH at \(symlinkURL.path).")
      return
    }
    let outcome = await Task.detached(priority: .userInitiated) { install() }.value
    switch outcome {
    case .installed:
      presentAlert(
        style: .informational, title: "Command Installed",
        message:
          "You can now run “\(commandName)” from the Terminal.\n\nLinked \(symlinkURL.path) → the "
          + "binary bundled in this app.")
    case .cancelled:
      break  // user dismissed the admin prompt — nothing to report
    case .failed(let message):
      presentAlert(style: .warning, title: "Couldn't Install Command", message: message)
    }
  }

  // MARK: Quoting helpers (internal for testing)

  /// Single-quote a string for /bin/sh, escaping any embedded single quotes (' → '\'').
  static func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// Quote a string as an AppleScript string literal (escape backslash first, then double quote).
  static func appleScriptQuoted(_ s: String) -> String {
    let escaped =
      s
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"" + escaped + "\""
  }

  @MainActor private static func presentAlert(
    style: NSAlert.Style, title: String, message: String
  ) {
    let alert = NSAlert()
    alert.alertStyle = style
    alert.messageText = title
    alert.informativeText = message
    alert.runModal()
  }
}
