---
title: workroom wait
description: "Wait for something to happen in a terminal session."
nightly: true
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

## Synopsis

Wait for something to happen in a terminal session

```text
workroom wait TARGET [flags]
```

## Options

```text
  -h, --help[=true|false]               help for wait
      --status string                   Wait for the coding agent's program status: idle, working, done, blocked or error
      --run string                      Wait for a run session's state: starting, running, stopping, stopped or exited
      --exit-code string                With --run exited, the code to expect: answers when the run exits, exiting 3 (ExitCodeMismatch) when it exits with another
      --regex string                    Wait for output matching this regex, counting only output from now on
      --include-screen[=true|false]     With --regex, also match what is on the screen now
      --ended[=true|false]              Wait for the session to end
      --command-finished[=true|false]   Wait for the next command to finish, running now or started later (needs shell integration)
      --turn string                     Wait for the coding agent's turn to end: next (one a working from now on starts) or current (the one under way)
      --timeout string                  Give up after this long (such as 30s or 2m), exiting 8; no limit when not given
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend[=true|false]   Run through the command without making changes (dry run)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## How to use it

Waits on the daemon for one thing to happen in a session, so you never poll. Give exactly one condition, and always a `--timeout` (past it, `WaitTimeout`, exit 8):

- `--status STATE`: the coding agent's program status is that state. Already true answers at once.
- `--turn next|current`: a coding agent's turn ends. `next` is the turn a `working` from now on starts, `current` the one under way. It prints `status: <state>`, the state the turn ended in.
- `--run STATE`: a run tab's command is starting, running, stopping, stopped or exited. With `--run exited --exit-code N` it answers when the run exits and is `ExitCodeMismatch` (exit 3) when it exited with another code; `error.details.exit_code` has the code.
- `--regex RE`: output matching RE, counting only output printed from now on (escape codes stripped; `^` and `$` are line anchors). `--include-screen` also matches what is on the screen now. It prints the match.
- `--ended`: the session ends.
- `--command-finished`: the next command the shell ends, running now or started later. It needs shell integration (`NoShellIntegration` without).

A state is checked at once; output and a command's end are events, so only those after the wait starts count. Start the wait before you cause what it waits for, or use `command` or `prompt --wait`, which pair the two for you.

## See also

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom help agents](workroom-help-agents.md)	 - The terminal API, for coding agents
