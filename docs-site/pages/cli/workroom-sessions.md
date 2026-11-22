---
title: workroom sessions
description: "List the daemon's terminal sessions, or the one TARGET names."
nightly: true
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

## Synopsis

List the daemon's terminal sessions, or the one TARGET names

```text
workroom sessions [TARGET]
```

## Options

```text
  -h, --help[=true|false]      help for sessions
      --all[=true|false]       List every session, not just those in this pane's workroom
      --clients[=true|false]   Also list each session's attached clients: kind, hostname, when it attached, size, size owner and keepalive
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend[=true|false]   Run through the command without making changes (dry run)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## How to use it

Start here. It lists the terminals in your pane's workroom, one row each, or with `--json` a `sessions` array: each session's `id`, `label` (its tab's name), `title` (what its program last set), `scope` (the workroom it belongs to), `run` (whether it is a run tab), `cwd` and `coding_agent` (the program status a coding agent last reported: `state` idle, working, done, blocked or error, `app`, `message` and `waiting_on_user`), and `caller`, the id of the pane the daemon took you for. `workroom sessions TARGET` shows the one session a target names, so you can check a target before you act on it. `--clients` adds who is attached to each session: `kind` (pane, app or cli), `hostname`, `attached_at_ms`, `size`, `owns_size` and `keepalive`.

## See also

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom help agents](workroom-help-agents.md)	 - The terminal API, for coding agents
