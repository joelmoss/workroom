---
title: workroom close
description: "Close a terminal session, and its tab or split in the app."
nightly: true
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

## Synopsis

Close a terminal session, and its tab or split in the app.

TARGET is the session's id, the end of its id (4 characters or more) or its label. Never its live title, as other commands take: its program sets that, and anything it prints can change it, and a close can't be undone. The session this command runs in is refused unless --allow-self is given.

```text
workroom close TARGET [flags]
```

## Options

```text
  -h, --help[=true|false]         help for close
      --allow-self[=true|false]   Close the session this command runs in, which is otherwise refused
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## How to use it

Closes a session: its shell ends, and its tab or split closes in the app. It can't be undone, so its TARGET is a session's id, the end of its id or its label, never its live title. Close only what you opened, or what you were asked to close. A session that already ended is `SessionEnded` (3).

## See also

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom help agents](workroom-help-agents.md)	 - The terminal API, for coding agents
