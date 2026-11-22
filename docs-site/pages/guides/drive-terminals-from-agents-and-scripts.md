---
title: Drive terminals from agents and scripts
description: Let a coding agent or a script list Workroom's terminals, read them, run commands in them, wait on them and hand work to another agent, with the workroom command and its terminal API.
nightly: true
---

Every terminal pane in Workroom runs under a daemon, on your Mac and on each remote host. The `workroom` command in a pane talks to that daemon through its terminal API. From one pane, a coding agent or a script can list the other terminals, read their screens, run a command in one and get its exit code, wait for something to happen, type into one, give the agent in another a prompt, and open or close terminals.

This page explains how it fits together. Each command's own page in the [CLI reference](../cli/workroom-sessions.md) lists its flags.

## Teach your coding agents

Coding agents learn the commands from `workroom help agents`, which explains every one of them in plain words, with the safe ways to use them. Point an agent at it:

```sh
workroom help agents
```

Or have Workroom install it as a skill, so Claude Code and Codex find it by themselves. Turn on **Settings ▸ AI Agents ▸ Install the Workroom skill for Claude Code and Codex**. It is off by default.

Workroom puts the skill in each coding agent's own skills folder, and only for an agent that is set up:

| Agent | Where the skill goes | Set up when |
| ----- | -------------------- | ----------- |
| Claude Code | `$CLAUDE_CONFIG_DIR/skills/workroom` when `CLAUDE_CONFIG_DIR` is set, else `~/.claude/skills/workroom` | that config folder is there |
| Codex | `~/.agents/skills/workroom`, the user skills folder Codex reads. Workroom makes `~/.agents` and its `skills` folder when they aren't there, and takes them away again with the skill if they are empty | `$CODEX_HOME`, else `~/.codex`, is there |

Workroom reads `CLAUDE_CONFIG_DIR` and `CODEX_HOME` from your login shell, as a terminal would set them, and on a host from the host user's login shell.

- On your Mac, Workroom writes the skill at once.
- On each remote host, Workroom writes it after it next connects to that host, in the host user's home.
- While the setting is on, Workroom brings the skill up to date each time the app starts and each time it connects to a host, so the skill always matches the `workroom` there.
- Turn the setting off and Workroom removes the skill: from your Mac at once, and from each host it put it on after it next connects there. A host whose Workroom is too old to remove it keeps it until a later connect can. A build of Workroom that never had the setting on removes nothing.

Workroom only ever writes and removes its own skill folder, which it marks as its own, and remembers where it put it, so it finds it again even after `CLAUDE_CONFIG_DIR` changes. If you already have a skill named `workroom` that Workroom didn't make, it is left alone, and the setting says so, for a host too. If you edit Workroom's `SKILL.md`, Workroom leaves your edit as it is from then on. When the setting is turned off, it keeps your edited file and stops managing the folder. Workroom follows a `~/.claude`, `~/.agents` or `skills` folder that is a link, to your dotfiles say, and writes the skill where it points. It never follows a link where the `workroom` skill folder itself should be: that is not its own, and it leaves it alone.

## Find the right terminal

`workroom sessions` lists the terminals in your pane's workroom: each one's id, its label (the tab's name), its live title, whether it is a run tab, its folder and what its coding agent last reported. Add `--all` for every terminal the daemon runs, and `--clients` for who is attached to each.

```sh
workroom sessions
workroom sessions --all --json
```

A command names a terminal by a TARGET:

1. its full id,
2. else the end of its id, 4 characters or more,
3. else its label,
4. else its live title, which the program in it sets.

The first of those that matches anything decides. If more than one terminal matches there, the command does nothing and fails with `TargetAmbiguous`, listing the matches. `workroom sessions TARGET` shows the one terminal a target names, so you can check it first. `workroom close` never matches a live title, because a program can change its title at any time and a close can't be undone.

Each daemon has its own terminals: a pane on a remote host sees that host's terminals, not your Mac's.

### Name a terminal

A terminal's label is its tab's name, one name on every Mac: the name you give the tab with **Rename…**, or the one `workroom new --title` gives it. A script or an agent labels a terminal with the terminal API's `session.label`, and clears the label with `null`:

```sh
workroom api call session.label '{"target": "TARGET", "label": "tests"}'
workroom api call session.label '{"target": "tests", "label": null}'
```

Every Mac showing that terminal renames its tab at once, and a cleared label shows the tab's default name again. Control and format characters, such as escapes, line breaks and zero-width characters, are stripped, and a label is cut to 256 bytes. Labelling the terminal you run in is allowed. A label is a target ahead of the live title, so a terminal you name can be named again later: `workroom command tests -- npm test`. `workroom events` tells each change as `session.labelled`. See [Terminals and tabs](../app/terminals-and-tabs.md).

## Read, run and wait

- `workroom capture TARGET` prints a terminal's screen as text. `--lines N` adds history above it, and `--all` streams the whole scrollback.
- `workroom command TARGET -- npm test` runs one shell command in the terminal's shell, waits for it to end, prints what it printed and exits with its exit code. It needs [shell integration](../app/terminals-and-tabs.md#shell-integration) to see the command end. It refuses, and types nothing, when the shell is busy with another command or already has text at its prompt.
- `workroom wait TARGET` waits for one thing: output matching a regex (`--regex`), a coding agent's status (`--status`) or the end of its turn (`--turn`), a run tab's state (`--run`), the next command to finish (`--command-finished`) or the terminal ending (`--ended`). The daemon does the waiting, so nothing polls. Give every wait a `--timeout`.

## Type, prompt and open

- `workroom send TARGET 'text' --key Enter` types text and keys into a terminal, as if you typed them. Several lines go as one paste when the program supports bracketed paste.
- `workroom prompt TARGET 'Fix the failing test' --wait` gives the coding agent in a terminal a prompt and, with `--wait`, returns when the turn it started has ended. It refuses an agent that is working or waiting on a question, rather than interrupt it. Text you left typed in the agent's input box is submitted with the prompt, ahead of it.

`workroom help agents` tells agents never to answer another agent's question or permission prompt on your behalf: an agent that finds one blocked reports what it asks and waits for you to answer it.
- `workroom new` opens a terminal beside yours, as a tab or with `--split right` or `--split down` as a split, and prints its id. `--run CMD` makes it a run tab, which `workroom run-control TARGET restart` and `stop` control.
- `workroom close TARGET` closes a terminal and its tab.

`send`, `command`, `prompt` and `close` refuse the terminal they run in, with `RefusedSelf`, so an agent can't type into its own input by mistake. Pass `--allow-self` when you mean it.

The app marks a pane while another terminal types into it, naming who is typing.

## Watch events

`workroom events` streams what happens to the terminals as JSON lines: one line per terminal as it is now, then each change as it happens, such as a terminal opening or ending, a coding agent's status changing, a run tab restarting or someone typing. It reconnects by itself when the app updates the daemon, so a long-running script keeps one stream.

## JSON and exit codes

Add `--json` to any of these commands for one JSON object on stdout, as every `workroom` command gives (see [JSON output](../reference/json-output.md)). Streams print one object per line. A failure's `error.kind` says what went wrong, and the exit code says what kind of failure it was:

| Code | Meaning |
| ---- | ------- |
| `0` | It worked. `workroom command` exits with the command's own code instead. |
| `2` | The daemon couldn't read the request, or it was too large. |
| `3` | Not now, or not found: the terminal can't take it as it is, or the target names no one terminal. |
| `7` | No daemon could be used: none answers, or it is too old for the command. |
| `8` | A wait timed out. |

Because `workroom command` exits with the command's code, which can be any number, read its result with `--json`: `ok: true` with `exit_code` is the command's, and `ok: false` with `error.kind` is Workroom's.

`workroom api list`, `api describe METHOD` and `api call METHOD` give raw access to every method of the terminal API, each with the JSON Schema of its parameters and result. The API only ever adds fields and methods, so a script written today keeps working.

## When `workroom` isn't the one you expect

Every pane's shell has `WORKROOM_BIN_DIR`, the folder of the `workroom` that matches the daemon running the pane, first on its `PATH`. If your dotfiles reset `PATH`, or put another `workroom` ahead of it, a command can fail with `DaemonTooOld` or not be found. Add the folder back at the end of your profile:

```sh
[ -n "$WORKROOM_BIN_DIR" ] && export PATH="$WORKROOM_BIN_DIR:$PATH"
```

To keep your own `PATH` order instead, for example so that a `workroom` you build yourself comes first, unset the variable in a startup file:

```sh
unset WORKROOM_BIN_DIR
```

In fish, use `set -e WORKROOM_BIN_DIR` in `config.fish`. You can always run the matching one directly, whether or not the variable is set, as `"$WORKROOM_DAEMON.bin/path/workroom"`: the bin folder sits beside the daemon's socket. See [Environment variables](../reference/environment-variables.md#variables-your-terminals-receive) for `WORKROOM_PANE`, `WORKROOM_DAEMON` and how Workroom keeps the folder first.

## Who can use it

The terminal API is reached through the daemon's socket, which only your user can open. Anything that can open it can read and type into every terminal, as you can, so it adds no access your user doesn't already have. A command finds which pane it runs in from its own process: the pane whose shell it runs under. Only a process outside every pane's processes uses `WORKROOM_PANE` instead, such as a shell in a tmux server's window, whose server a pane started and left running. tmux can hand such a window another pane's `WORKROOM_PANE` (its `update-environment` option), and the command is then taken for that pane: refused as that pane's own by `send` and `close`, and named as sent from it.
