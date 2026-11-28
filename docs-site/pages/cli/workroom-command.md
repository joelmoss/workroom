---
title: workroom command
description: "Run a shell command in a terminal session and exit with its code."
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

## Synopsis

Run a shell command in a terminal session and exit with its code.

The command is typed at the session's shell prompt and Enter pressed, and workroom waits for the shell's integration to say it has ended. What it printed is written to stdout, as the pane shows it (or as printed, with --vt), and workroom exits with the command's own exit code.

When workroom command itself fails (no such session, no shell integration, a shell busy with another command, the timeout, no daemon), it prints an Error: line on stderr and nothing on stdout, and exits with its own code, which a command can exit with too. With --json, the envelope is the reliable way to tell the two apart: exit_code beside ok: true for the command's, error.kind for workroom's.

```text
workroom command TARGET [flags] -- COMMAND...
```

## Options

```text
  -h, --help[=true|false]         help for command
      --allow-self[=true|false]   Run it in the session this command runs in, which is otherwise refused
      --vt[=true|false]           Print the output as the command printed it, escape codes and all, not read back as the screen shows it
      --timeout string            Give up after this long (such as 30s or 10m), exiting 8 and leaving the command running; no limit when not given
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## How to use it

Runs one shell command in a session's shell and exits with its exit code, printing what it printed, as the pane shows it (`--vt`: as printed, escape codes and all). The words after `--` are joined with spaces into one line, which the session's shell reads, so quote for that shell; join several commands with `;` or `&&`. It needs the shell's integration marks to see the command end: a session without them is `NoShellIntegration` (exit 3) and nothing is typed. A shell that is busy with a command, or has text already at its prompt, is `Busy` (3), nothing typed: retry once it is free, or use `capture` to see why. A full-screen program up, or one the command opens, is `AlternateScreen` (3), the program left running. `--timeout` is `WaitTimeout` (8) and leaves the command running in the pane. The last 1 MiB of output is kept; `truncated` says when it was cut. A command can exit with any code, including workroom's own, so read the result with `--json`: `ok: true` with `exit_code` is the command's, `ok: false` with `error.kind` is workroom's.

## See also

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom help agents](workroom-help-agents.md)	 - The terminal API, for coding agents
* [Terminal API reference](../reference/terminal-api.md)	 - Every method, event and error of the terminal API
