---
title: workroom capture
description: "Print a terminal session's screen, or its history, as text."
nightly: true
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

## Synopsis

Print a terminal session's screen, or its history, as text

```text
workroom capture TARGET
```

## Options

```text
  -h, --help[=true|false]     help for capture
      --all[=true|false]      The whole scrollback, streamed (one envelope per chunk with --json)
      --lines string          Rows of history above the visible screen to add (default "0")
      --unwrap[=true|false]   Join lines the pane wrapped
      --vt[=true|false]       Keep escape codes (colours and styles)
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend[=true|false]   Run through the command without making changes (dry run)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## How to use it

Reads a session's screen as plain text, as it shows now: what to look at before you type, and after a command whose output you need. `--lines N` adds N rows of history above the screen, `--all` streams the whole scrollback (one envelope per chunk with `--json`, each with `chunk` and `more`), `--unwrap` joins lines the pane wrapped and `--vt` keeps escape codes. Every reply has `cursor`, `size`, `alternate_screen` (a full-screen program is up) and the live `title`. A capture never types anything, and works under a full-screen program too.

## See also

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom help agents](workroom-help-agents.md)	 - The terminal API, for coding agents
