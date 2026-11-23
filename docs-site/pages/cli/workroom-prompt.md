---
title: workroom prompt
description: "Give the coding agent in a terminal session a prompt."
nightly: true
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

```text
workroom prompt TARGET [TEXT] [flags]
```

## Options

```text
  -h, --help[=true|false]         help for prompt
      --allow-self[=true|false]   Prompt the session this command runs in, which is otherwise refused
      --stdin[=true|false]        Prompt with stdin's text, exactly as it comes, in place of TEXT
      --timeout string            With --wait, give up after this long (such as 30s or 10m), exiting 8; no limit when not given
      --wait[=true|false]         Return once the turn the prompt starts has ended, printing the status it ended in: done, blocked, idle or error
```

## Options inherited from parent commands

```text
      --json[=true|false]      Emit machine-readable JSON (exactly one object on stdout)
  -v, --verbose[=true|false]   Print detailed and verbose output
```

## How to use it

Gives the coding agent (Claude Code or Codex) in a session a prompt: the text as a paste, then Enter, in one step. Text the user already left in the agent's input box, a draft, is submitted with it, your text after the draft: `capture` first if that matters. With `--wait` it returns once the turn the prompt started has ended, printing `status: <state>` (done, blocked, idle or error); give it a `--timeout`. It refuses rather than interrupt: `NotAnAgent` (3) when no coding agent runs there (and with `--wait`, for an agent that has never reported a status), `AgentBusy` (3) while the agent is working or blocked on a question, or not ready for a prompt. When the agent started working between the paste and the Enter, `AgentBusy` says `error.details.typed: true, submitted: false`: the text is in its input box, not submitted. A prompt is never typed twice. An agent that is `blocked` is asking the user something, often permission to run a command: never press Enter or type an answer into it on the user's behalf. Tell the user what it asks, and wait (`wait TARGET --status working`, or `--turn current`) until they have answered.

## See also

* [workroom](workroom.md)	 - Manage development workrooms
* [workroom help agents](workroom-help-agents.md)	 - The terminal API, for coding agents
* [Terminal API reference](../reference/terminal-api.md)	 - Every method, event and error of the terminal API
