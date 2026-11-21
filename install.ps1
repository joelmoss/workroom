# Workroom's Windows installer, kept only to say Windows support has ended (ADR 0078, #681).
#
# The workroom CLI became one Rust binary that is also the daemon running terminal sessions, which
# has never run on Windows, so no release after the swap has a Windows build. Anyone still running
#   iwr https://raw.githubusercontent.com/joelmoss/workroom/master/install.ps1 -useb | iex
# is told so, instead of a 404 for an archive that no longer exists. A Windows CLI installed before
# keeps working; `workroom update` finds no newer Windows build. This file goes with the Go CLI (#682).

$message = @"
Workroom's command-line tool no longer has a Windows build.

It is now one Rust binary, which also runs Workroom's terminal sessions, and that part has never
run on Windows. The CLI runs on macOS and Linux:

  https://codaset.dev/workroom/docs/get-started/install

A workroom.exe installed earlier keeps working, but gets no more updates.
"@

# Run as a file (`pwsh install.ps1`), it exits 1. Piped into `iex`, `exit` would close the user's
# PowerShell window, so it throws instead: a terminating error, which fails the command just the same.
if ($MyInvocation.MyCommand.Path) {
    [Console]::Error.WriteLine($message)
    exit 1
}
throw $message
