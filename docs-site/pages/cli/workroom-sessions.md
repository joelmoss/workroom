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
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## How to use it

Start here. It lists the terminals in your pane's workroom, one row each, or with `--json` a `sessions` array: each session's `id`, `label` (its tab's name), `title` (what its program last set), `scope` (the workroom it belongs to), `run` (whether it is a run tab), `cwd` and `coding_agent` (the program status a coding agent last reported: `state` idle, working, done, blocked or error, `app`, `message` and `waiting_on_user`), and `caller`, the id of the pane the daemon took you for. `workroom sessions TARGET` shows the one session a target names, so you can check a target before you act on it. `--clients` adds who is attached to each session: `kind` (pane, app or cli), `hostname`, `attached_at_ms`, `size`, `owns_size` and `keepalive`.

A session's `label` is its tab's name, one name on every Mac: the name the user gave the tab, or `new --title`'s. Label a session with `workroom api call session.label '{"target": "TARGET", "label": "tests"}'`, and clear it with `"label": null`: every Mac showing it renames its tab at once, and a cleared one shows its default name again. Control and format characters (escapes, line breaks, bidi and zero-width characters) are stripped, and it is cut to 256 bytes; the reply's `changed` says whether it was new. Labelling your own pane is allowed. A label is a target, ahead of the live title, so label the terminals you open to name them again later.

## See also

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom help agents](workroom-help-agents.md)	 - The terminal API, for coding agents
