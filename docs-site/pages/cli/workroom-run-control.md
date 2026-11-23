---
title: workroom run-control
description: "Restart or stop the command of a run session."
nightly: true
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

```text
workroom run-control TARGET restart|stop
```

## Options

```text
  -h, --help[=true|false]   help for run-control
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## How to use it

Restarts or stops the command of a run tab, as its Run tab's buttons do. Follow a restart with `wait TARGET --run running --timeout 1m` to know it is back up. A session that is no run tab is `NotARun` (3).

## See also

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom help agents](workroom-help-agents.md)	 - The terminal API, for coding agents
* [Terminal API reference](../reference/terminal-api.md)	 - Every method, event and error of the terminal API
