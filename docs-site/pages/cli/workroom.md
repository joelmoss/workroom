---
title: workroom
description: "Manage development workrooms."
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

## Synopsis

Create and manage local development workrooms using Git worktrees.

```text
workroom [command]
```

## Options

```text
  -h, --help[=true|false]      help for workroom
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend[=true|false]   Run through the command without making changes (dry run)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## See also

* [workroom api](workroom-api.md)	 - List, describe and call the terminal API's methods (Nightly only)
* [workroom base](workroom-base.md)	 - Set or clear the branch new workrooms start from
* [workroom capture](workroom-capture.md)	 - Print a terminal session's screen, or its history, as text (Nightly only)
* [workroom close](workroom-close.md)	 - Close a terminal session, and its tab or split in the app (Nightly only)
* [workroom command](workroom-command.md)	 - Run a shell command in a terminal session and exit with its code (Nightly only)
* [workroom completion](workroom-completion.md)	 - Generate the autocompletion script for the specified shell
* [workroom create](workroom-create.md)	 - Create a new workroom
* [workroom delete](workroom-delete.md)	 - Delete an existing workroom
* [workroom events](workroom-events.md)	 - Stream terminal sessions' events as JSON lines: a snapshot, then live changes (Nightly only)
* [workroom list](workroom-list.md)	 - List all workrooms for the current project
* [workroom new](workroom-new.md)	 - Open a new terminal beside this one, as a tab or a split in the app (Nightly only)
* [workroom prompt](workroom-prompt.md)	 - Give the coding agent in a terminal session a prompt (Nightly only)
* [workroom run-control](workroom-run-control.md)	 - Restart or stop the command of a run session (Nightly only)
* [workroom send](workroom-send.md)	 - Type text and keys into a terminal session (Nightly only)
* [workroom sessions](workroom-sessions.md)	 - List the daemon's terminal sessions, or the one TARGET names (Nightly only)
* [workroom trust](workroom-trust.md)	 - Approve a project's setup and teardown scripts so Workroom runs them
* [workroom untrust](workroom-untrust.md)	 - Forget the approval of a project's setup and teardown scripts
* [workroom update](workroom-update.md)	 - Update workroom to the latest version
* [workroom version](workroom-version.md)	 - Print the version
* [workroom wait](workroom-wait.md)	 - Wait for something to happen in a terminal session (Nightly only)
* [workroom help agents](workroom-help-agents.md)	 - The terminal API, for coding agents (Nightly only)
