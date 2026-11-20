# One script runner

Status: built in #676 (part of #667, ADR 0078). Local setup and teardown still run through the Go
CLI's `internal/script` until the swap (#681); `create` and `delete`'s Rust ports (#677, #678) call
this runner.

Setup and teardown scripts ran through two runners: the Go CLI's `internal/script` for a local
workroom, and the daemon's `run-script` on a host (ADR 0053). Both read the user's login-shell
environment in the workroom, give the script its own process group, and end its tree on a
signal, but each did it its own way. They are now one runner, `crate::script` in the `workroom`
crate (`vcs/crates/workroomd/src/script.rs`). `run-script` is a thin front end over it, and a CLI
command calls it in-process.

## The runner

`script::run(&Script, Output, fallback_note) -> Outcome`:

- `Script` names the script, its directory, the variables to set on top of the login environment
  (`script::local_variables` gives a local workroom's `WORKROOM_*` contract), an optional wall clock,
  the shell, and the probe and kill bounds.
- `Output::Inherit` gives the script this process's stdout and stderr, as `run-script` always has.
  `Output::Combined(sink)` sends both through one pipe to a writer as they arrive, in the order
  printed, as the Go CLI's log panel and NDJSON stream expect.
- `fallback_note` words the one line the runner writes itself, when the login shell can't be read.
- `Outcome` is `Absent`, `NotStarted`, `Exited`, `TimedOut` or `Cancelled(signal)`. Each caller
  words it. `run-script` keeps its exit codes (the script's own, 128 plus a signal, 124, 126) and
  its `workroomd run-script: ` lines, which the app parses and ADR 0078 pins.

## Differences, and what the runner does

Each difference defaults to Rust's behaviour, which hosts already depend on. Go's is kept only
where local workrooms rely on it, and the table says why.

| # | What | Go (`internal/script`) | Rust (`run-script`) | One runner |
|---|---|---|---|---|
| 1 | Probe shell's session | A session of its own (`Setsid`) | A process group of its own | **Go's.** `workroom create` typed in a terminal relies on it: an interactive zsh in a background group of a terminal is stopped by SIGTTOU, so the read hangs until its 10 s limit and the script loses its environment. Applies to remote git's read at home too. |
| 2 | A signal while the probe runs | Kills the shell, starts no script, re-raises | Recorded. The probe runs to its end (up to 10 s), the script starts, and then its tree is ended | **Go's, without the re-raise.** The shell is killed at once, no script starts, and the outcome is `Cancelled`. `run-script` still exits 128 plus the signal. A local cancel relies on this: it must not run a script it was told to stop. |
| 3 | A signal ignored at start (nohup's SIGHUP, a background job's SIGINT) | No cancel during the probe; caught during the script | Always caught, overriding the ignore | **Go's probe rule, for the whole run:** ignored means no cancel. A local `workroom create &` in a script relies on it. The app never starts `run-script` with a signal ignored. |
| 4 | Handler lifetime | Only for the run, then restored | For the whole process | **Go's.** An in-process caller carries on after the script (delete removes the worktree), and a SIGTERM then must end it as usual. Runs may nest. |
| 5 | A missing script | Passes, and no login shell is read | The probe runs, then exit 126, "could not be started: No such file or directory" | **Go's check, Rust's report.** `Absent` comes back before any probe, so a clone with no script has none of its rc-visible config read. `run-script` reports it as before (126, the same line). |
| 6 | Wall clock | None. The app's own deadline SIGTERMs the CLI | `--timeout`, then 124 | **Optional.** `run-script` always has one. A local run has none, as in Go: a user who typed `workroom create` waits for a long setup, and the app's 600 s deadline still ends the CLI. |
| 7 | Ending the tree | SIGTERM to the group, then waits for the script. No SIGKILL, and a `setsid` escaper survives | `wr_exec::end_tree`: records the tree, SIGTERMs the group, and SIGKILLs the recorded tree and the group after 2 s | **Rust's.** `kill_grace` is a field: the app SIGKILLs the CLI 2 s after its SIGTERM (`WorkroomCLI.swift`), so a local caller should pass less, for example 1 s, to report before then. |
| 8 | Result after a signal | The script's failure (exit 5); the CLI writes its result and doesn't re-raise | Exit 128 plus the signal | **Both, by caller.** The runner returns `Cancelled`. `run-script` exits 128 plus the signal. The CLI ports report it as the script's failure, since the app relies on the result being written. |
| 9 | Exit codes | Errors (`ErrSetup`, `ErrTeardown`, exit 5) | The script's own, 128 plus a signal, 124, 126 | **`Outcome`,** mapped by each front end: `Outcome::exit_code` is `run-script`'s mapping, and `Outcome::passed` is the CLI's test. |
| 10 | Wording | The fallback note goes to the log: `workroom: couldn't read the login shell's environment (…); using the current one`. Errors are `… could not be started: <Go error>` and `… returned a non-zero exit code` | `workroomd run-script: ` lines on stderr: the fallback note, `could not be started: <io error>`, and `timed out after N s` | **Each caller's own.** The runner writes only the fallback note, worded by the caller, to stderr (`Inherit`) or the sink (`Combined`). `run-script`'s lines are unchanged. The CLI ports keep Go's note; their error messages are theirs under ADR 0013. |
| 11 | Output | One pipe for stdout and stderr, captured and streamed. It waits for EOF, so a background job holding the pipe holds `create` | Inherited stdout and stderr, two streams, no copy | **Both, by caller:** `Inherit` for `run-script`, `Combined` in-process. `Combined` reads for 1 s more once the script exits, then returns, as Rust returns when the script exits. |
| 12 | Environment when the probe fails | This process's, unchanged | This process's, less the probe's own variables, with the git pins and the standard PATH directories | **Rust's.** |
| 13 | `GIT_TERMINAL_PROMPT`, `GIT_OPTIONAL_LOCKS` | The caller's value if set, else whatever the rc set | Always `0` | **Rust's.** The app already passes `0` to the CLI, so only a create typed in a terminal changes. Its script runs with stdin at `/dev/null`, in a background group, so git couldn't have prompted anyway. |
| 14 | PATH | The login shell's, then the caller's | The login shell's, the caller's, then the standard directories | **Rust's.** |
| 15 | Which shell | `$SHELL`, else a login `/bin/sh` | `$SHELL`, else the passwd entry's, else `/bin/sh` on Linux | **Rust's.** |
| 16 | A variable that isn't UTF-8 | Kept | Dropped | **Rust's.** |
| 17 | Reason for a probe that prints nothing between the markers | `noPath` | `noMarkers` | **Rust's.** |
| 18 | Marker | 26 base32 characters | 32 hex digits | Rust's. No visible effect. |

Already the same in both: the `<shell> -lic` (or `/bin/sh -lc`) rule from `testdata/twins/login_shell.tsv`,
the 10 s probe limit, the 1 MiB cap on what's kept of the shell's output, the 1 s wait for a background
job holding the probe's pipe, the probe's `PATH` and `WORKROOM_SHELL_PROBE=1`, its stdin and stderr
at `/dev/null`, the names it drops (`PWD`, `OLDPWD`, `SHLVL`, `_`, `WORKROOM_SHELL_PROBE`), and the
script's stdin at `/dev/null` in a process group of its own in the caller's session.

## What hosts now do differently

Rows 1, 2, 3 and 5 reach `run-script`, and row 1 reaches remote git's read at home as well:

- The login shell is read in a session of its own. Without a terminal, which is how the app starts
  `run-script`, nothing visible changes.
- A SIGTERM, SIGHUP or SIGINT while the login shell is read ends `run-script` at once, with the same
  exit code (128 plus the signal), and the script never starts. Before, it waited out the read and
  briefly started the script.
- A signal `run-script` was started ignoring stays ignored. The app never starts it that way.
- A script missing when `run-script` starts still exits 126 with the same line, but no login shell
  is read first, so no fallback line comes before it. The app checks for the script first, so this
  only happens in a race.

## Tests

Go's script tests are ported in `vcs/crates/workroomd/tests/script_runner.rs`. They run in-process
through `workroom::script` for the local contract (`testdata/script-env/local.txt`), streaming,
failures, a missing script, the fallback note, a background job and the wall clock. They run
through `run-script` for what needs a process of its own: a misbehaving rc, a login `sh` for an
unknown shell, the git pins, PATH order, a signal during the probe, an ignored signal, SIGHUP and
SIGINT ending the tree, 124 and 126 with their lines, and a real terminal. The existing
`tests/run_script.rs` and `src/cli/run_script/tests.rs` pass unchanged.
