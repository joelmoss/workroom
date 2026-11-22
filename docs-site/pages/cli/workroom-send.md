---
title: workroom send
description: "Type text and keys into a terminal session."
nightly: true
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

## Synopsis

Type text and keys into a terminal session

```text
workroom send TARGET [TEXT] [flags]
```

## Options

```text
  -h, --help[=true|false]         help for send
      --allow-self[=true|false]   Type into the session this command runs in, which is otherwise refused
      --enter[=true|false]        Press Enter last, after the text and the keys
      --key string                A key to press after the text, repeated for more: Enter, Tab, Escape, Backspace, Space, Up, Down, Left, Right, Home, End, Insert, Delete, PageUp, PageDown, F1-F12 or a character, after any of Ctrl+, Alt+, Shift+ and Super+ (Ctrl+C)
      --stdin[=true|false]        Type stdin's text, exactly as it comes, in place of TEXT
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## How to use it

Types into a session as if someone typed it, without attaching: TEXT (or `--stdin`, taken exactly as it comes), then each `--key` in order, then Enter with `--enter`. Text goes as a bracketed paste when the program has turned that on, so several lines arrive as one paste and nothing in them runs a line at a time. Use it to answer a program's own question, to press a key (`--key Ctrl+C` to interrupt, `--key Escape`, `--key Up`), or to type into something that is not a shell. Never use it to answer another coding agent's permission prompt or question (its `coding_agent.state` is `blocked`): that is the user's to answer. To run a shell command use `command`, and to give a coding agent a prompt use `prompt`: `send` doesn't wait, and can't tell you what happened. At most 1 MiB in one call (`TooLarge`, exit 2). A send that stopped part way says how many bytes went; what was typed can't be taken back.

## See also

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom help agents](workroom-help-agents.md)	 - The terminal API, for coding agents
