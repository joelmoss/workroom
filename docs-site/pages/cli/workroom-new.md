---
title: workroom new
description: "Open a new terminal beside this one, as a tab or a split in the app."
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

```text
workroom new [flags]
```

## Options

```text
  -h, --help[=true|false]   help for new
      --title string        Its name: the session's label, and its tab's name in the app
      --run string          A command to run in it under a run supervisor, as the Run tab runs one, so run-control restarts and stops it; a shell when not given
      --cwd string          The folder it starts in; this command's folder when not given
      --split string        Open it as a split beside this pane, right or down, when the pane is on screen; a tab otherwise
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## How to use it

Opens a new terminal beside yours, as a tab, or as a split with `--split right` or `--split down`, and prints its id (with `--json`, the new `session`). It starts as your pane was made, with your pane's PATH and shell integration, in this command's folder or `--cwd`. `--title` names it. `--run CMD` makes it a run tab: the command runs under a supervisor, so `run-control` restarts and stops it and `wait --run` waits on it. Follow it with `command` or `wait` on the id it printed. A `--cwd` that is no folder is `NotADirectory` (3).

## See also

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom help agents](workroom-help-agents.md)	 - The terminal API, for coding agents
* [Terminal API reference](../reference/terminal-api.md)	 - Every method, event and error of the terminal API
