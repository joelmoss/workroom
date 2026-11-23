---
title: workroom events
description: "Stream terminal sessions' events as JSON lines: a snapshot, then live changes."
nightly: true
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

```text
workroom events
```

## Options

```text
  -h, --help[=true|false]   help for events
      --all[=true|false]    Every session's events, not only the caller's workroom's
      --session string      Only this session's events (a TARGET, as for sessions)
      --type string         Only live events of this type, repeated or comma-separated: session.created, session.ended, session.program_status, session.run_state, session.moved, client.attached, client.detached, session.input or session.labelled
      --workroom string     Only this workroom's sessions' events (its id, a session's scope id)
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## How to use it

Streams what happens to the sessions, one JSON object per line, until stopped: first a `session` event for each session as it is, then `snapshot-complete`, then live events: `session.created`, `session.ended`, `session.program_status`, `session.run_state`, `session.moved`, `client.attached`, `client.detached`, `session.input` (someone typed into a session; `sender` is who) and `session.labelled` (its tab was renamed, or `session.label` set it; `label` null when cleared). Every event has `event`, `boot` and `revision`. By default your workroom's sessions; `--all` for every session, `--workroom ID` for one workroom, `--session TARGET` for one session, `--type` for some event types only. A `snapshot-complete` with `reason` `gap` or `lagged` replaced what you knew: start from it again. Ignore event types you don't know. To wait for one thing, `wait` is simpler.

## See also

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom help agents](workroom-help-agents.md)	 - The terminal API, for coding agents
* [Terminal API reference](../reference/terminal-api.md)	 - Every method, event and error of the terminal API
