import Darwin
import Foundation
import GhosttyKit

// Explicit entry point instead of `@main` on `WorkroomApp`, so Ghostty's `+action` CLI can
// dispatch before AppKit touches anything.
//
// `Contents/MacOS/ghostty` is a relative symlink to this binary (created by the "Symlink ghostty"
// build phase in project.yml). Ghostty's bundled shell integration calls
// `"$GHOSTTY_BIN_DIR/ghostty" +ssh-cache` — and the engine sets `GHOSTTY_BIN_DIR` itself, to the
// directory of the running executable, which is exactly where the symlink lives. libghostty
// carries the whole action implementation set, so the actions we expose are always precisely the
// pinned engine's. See Resources/ghostty/SOURCE.md.
//
// Dispatch is a TWO-call sequence: `ghostty_init` parses and *stores* the action, and
// `ghostty_cli_try_action` runs it and exits. Calling only the first (which is what the app did
// before this file existed) never runs anything.
//
// The two paths below are mutually exclusive *processes*, which is why the GUI path is left
// exactly as it was: it must keep running `SentryConfig.start()` and the one `setenv("PATH", …)`
// inside `WorkroomApp.init()` **before** anything calls `ghostty_init`, because the engine
// captures the environment at init and the terminals inherit that copy. Hoisting the init up here
// for both paths would hand every terminal the un-enriched Finder PATH.

/// True when we were invoked through the `ghostty` symlink rather than as the app.
let invokedAsGhosttyCLI =
  (CommandLine.arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
  == "ghostty"

if invokedAsGhosttyCLI {
  // CLI path: no Sentry, no PATH enrichment, no AppKit. Short-lived — the shell integration runs
  // this once per `ssh`.
  GhosttyResources.exportResourcesDir()

  guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
    // A non-zero init means an invalid or ambiguous action (`+bogus`, or two `+actions`).
    FileHandle.standardError.write(Data("ghostty: invalid action — try `ghostty +help`\n".utf8))
    exit(1)
  }

  // Runs the action and exits the process. Returns only when there was no `+action` at all.
  ghostty_cli_try_action()

  // Someone typed a bare `ghostty` in a pane. The engine puts `Contents/MacOS` on every pane's
  // PATH, so we shadow a real Ghostty.app in here — say so rather than launching a second Workroom.
  FileHandle.standardError.write(
    Data(
      """
      ghostty: this is Workroom's bundled libghostty helper, not Ghostty.app.
      It runs +actions only (try `ghostty +help`). Your Ghostty install is unaffected \
      outside Workroom.

      """.utf8))
  exit(1)
}

WorkroomApp.main()
