---
title: workroom help agents
description: "How a coding agent drives Workroom's terminals with the terminal API's commands, as `workroom help agents` and the Workroom skill explain it."
nightly: true
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

## Synopsis

What `workroom help agents` prints, and the Workroom skill for Claude Code and Codex holds.

```text
workroom help agents
```

Workroom runs every terminal pane under a daemon, on the Mac and on remote hosts. The `workroom` commands below talk to that daemon's terminal API, so from inside one pane you can list the other terminals, read their screens, type into them, run commands in them, wait for something to happen in them, open and close them, and hand work to another coding agent.

Every pane's shell has three variables Workroom sets:

- `WORKROOM_PANE`: this pane's session id. Commands use it to know who is calling.
- `WORKROOM_DAEMON`: the daemon's socket. Commands reach the daemon without being told.
- `WORKROOM_BIN_DIR`: the folder of the `workroom` that matches that daemon, first on `PATH`. If `workroom` is missing or says `DaemonTooOld`, run `"$WORKROOM_BIN_DIR/workroom"` instead.

## Rules

- **Read results as JSON.** Add `--json` and a command prints one JSON object on stdout: `ok`, `schema_version`, `command` and the result's fields, or `ok: false` with `error.kind` and `error.message`. Streams (`events`, `capture --all`) print one object per line. Branch on `error.kind` or the exit code, never on the message, and ignore fields you don't know.
- **Look before you act.** `workroom sessions` first, then `capture` the screen you are about to type into.
- **Never type into your own pane.** `send`, `command`, `prompt` and `close` refuse the session you run in with `RefusedSelf` unless you pass `--allow-self`. Your own pane is `caller` in `sessions --json`.
- **Prefer the command that waits.** Run a shell command with `command`, not `send` and Enter: it waits for the command to end and gives you its exit code and output. Prompt a coding agent with `prompt --wait`, not `send`, and wait for a turn an agent already has under way with `workroom wait TARGET --turn current`. Use `send` for keys and answers.
- **Wait on the daemon, never poll.** `wait`, `command` and `prompt --wait` answer the moment it happens. Give each a `--timeout` (such as `30s`, `10m`).
- **Use ids.** Once you know a session, name it by the `id` from `sessions --json`.

## Targets

A TARGET names one session: its full id, else the end of its id (4 characters or more), else its label (its tab's name), else its live title (what its program last set). The first of those that matches anything decides: more than one match there is `TargetAmbiguous` and nothing happens. `close` never matches a live title.

## Scope

`sessions` and `events` keep to the sessions in your pane's workroom; `--all` widens them to every session the daemon runs. A target names any session, in any workroom. Run from no pane, every session is listed. Each daemon has its own sessions: a pane on a remote host sees that host's terminals, not the Mac's.

## Commands

### `workroom sessions`

`workroom sessions [TARGET]`: List the daemon's terminal sessions, or the one TARGET names.

Start here. It lists the terminals in your pane's workroom, one row each, or with `--json` a `sessions` array: each session's `id`, `label` (its tab's name), `title` (what its program last set), `scope` (the workroom it belongs to), `run` (whether it is a run tab), `cwd` and `coding_agent` (the program status a coding agent last reported: `state` idle, working, done, blocked or error, `app`, `message` and `waiting_on_user`), and `caller`, the id of the pane the daemon took you for. `workroom sessions TARGET` shows the one session a target names, so you can check a target before you act on it. `--clients` adds who is attached to each session: `kind` (pane, app or cli), `hostname`, `attached_at_ms`, `size`, `owns_size` and `keepalive`.

Flags:

- `--all`: List every session, not just those in this pane's workroom.
- `--clients`: Also list each session's attached clients: kind, hostname, when it attached, size, size owner and keepalive.

### `workroom capture`

`workroom capture TARGET`: Print a terminal session's screen, or its history, as text.

Reads a session's screen as plain text, as it shows now: what to look at before you type, and after a command whose output you need. `--lines N` adds N rows of history above the screen, `--all` streams the whole scrollback (one envelope per chunk with `--json`, each with `chunk` and `more`), `--unwrap` joins lines the pane wrapped and `--vt` keeps escape codes. Every reply has `cursor`, `size`, `alternate_screen` (a full-screen program is up) and the live `title`. A capture never types anything, and works under a full-screen program too.

Flags:

- `--all`: The whole scrollback, streamed (one envelope per chunk with --json).
- `--lines VALUE`: Rows of history above the visible screen to add (default 0).
- `--unwrap`: Join lines the pane wrapped.
- `--vt`: Keep escape codes (colours and styles).

### `workroom wait`

`workroom wait TARGET [flags]`: Wait for something to happen in a terminal session.

Waits on the daemon for one thing to happen in a session, so you never poll. Give exactly one condition, and always a `--timeout` (past it, `WaitTimeout`, exit 8):

- `--status STATE`: the coding agent's program status is that state. Already true answers at once.
- `--turn next|current`: a coding agent's turn ends. `next` is the turn a `working` from now on starts, `current` the one under way. It prints `status: <state>`, the state the turn ended in.
- `--run STATE`: a run tab's command is starting, running, stopping, stopped or exited. With `--run exited --exit-code N` it answers when the run exits and is `ExitCodeMismatch` (exit 3) when it exited with another code; `error.details.exit_code` has the code.
- `--regex RE`: output matching RE, counting only output printed from now on (escape codes stripped; `^` and `$` are line anchors). `--include-screen` also matches what is on the screen now. It prints the match.
- `--ended`: the session ends.
- `--command-finished`: the next command the shell ends, running now or started later. It needs shell integration (`NoShellIntegration` without).

A state is checked at once; output and a command's end are events, so only those after the wait starts count. Start the wait before you cause what it waits for, or use `command` or `prompt --wait`, which pair the two for you.

Flags:

- `--status VALUE`: Wait for the coding agent's program status: idle, working, done, blocked or error.
- `--run VALUE`: Wait for a run session's state: starting, running, stopping, stopped or exited.
- `--exit-code VALUE`: With --run exited, the code to expect: answers when the run exits, exiting 3 (ExitCodeMismatch) when it exits with another.
- `--regex VALUE`: Wait for output matching this regex, counting only output from now on.
- `--include-screen`: With --regex, also match what is on the screen now.
- `--ended`: Wait for the session to end.
- `--command-finished`: Wait for the next command to finish, running now or started later (needs shell integration).
- `--turn VALUE`: Wait for the coding agent's turn to end: next (one a working from now on starts) or current (the one under way).
- `--timeout VALUE`: Give up after this long (such as 30s or 2m), exiting 8; no limit when not given.

### `workroom send`

`workroom send TARGET [TEXT] [flags]`: Type text and keys into a terminal session.

Types into a session as if someone typed it, without attaching: TEXT (or `--stdin`, taken exactly as it comes), then each `--key` in order, then Enter with `--enter`. Text goes as a bracketed paste when the program has turned that on, so several lines arrive as one paste and nothing in them runs a line at a time. Use it to answer a program's question, to press a key (`--key Ctrl+C` to interrupt, `--key Escape`, `--key Up`), or to type into something that is not a shell. To run a shell command use `command`, and to give a coding agent a prompt use `prompt`: `send` doesn't wait, and can't tell you what happened. At most 1 MiB in one call (`TooLarge`, exit 2). A send that stopped part way says how many bytes went; what was typed can't be taken back.

Flags:

- `--allow-self`: Type into the session this command runs in, which is otherwise refused.
- `--enter`: Press Enter last, after the text and the keys.
- `--key VALUE`: A key to press after the text, repeated for more: Enter, Tab, Escape, Backspace, Space, Up, Down, Left, Right, Home, End, Insert, Delete, PageUp, PageDown, F1-F12 or a character, after any of Ctrl+, Alt+, Shift+ and Super+ (Ctrl+C).
- `--stdin`: Type stdin's text, exactly as it comes, in place of TEXT.

### `workroom command`

`workroom command TARGET [flags] -- COMMAND...`: Run a shell command in a terminal session and exit with its code.

Runs one shell command in a session's shell and exits with its exit code, printing what it printed, as the pane shows it (`--vt`: as printed, escape codes and all). The words after `--` are joined with spaces into one line, which the session's shell reads, so quote for that shell; join several commands with `;` or `&&`. It needs the shell's integration marks to see the command end: a session without them is `NoShellIntegration` (exit 3) and nothing is typed. A shell that is busy with a command, or has text already at its prompt, is `Busy` (3), nothing typed: retry once it is free, or use `capture` to see why. A full-screen program up, or one the command opens, is `AlternateScreen` (3), the program left running. `--timeout` is `WaitTimeout` (8) and leaves the command running in the pane. The last 1 MiB of output is kept; `truncated` says when it was cut. A command can exit with any code, including workroom's own, so read the result with `--json`: `ok: true` with `exit_code` is the command's, `ok: false` with `error.kind` is workroom's.

Flags:

- `--allow-self`: Run it in the session this command runs in, which is otherwise refused.
- `--vt`: Print the output as the command printed it, escape codes and all, not read back as the screen shows it.
- `--timeout VALUE`: Give up after this long (such as 30s or 10m), exiting 8 and leaving the command running; no limit when not given.

### `workroom prompt`

`workroom prompt TARGET [TEXT] [flags]`: Give the coding agent in a terminal session a prompt.

Gives the coding agent (Claude Code or Codex) in a session a prompt: the text as a paste, then Enter, in one step. With `--wait` it returns once the turn the prompt started has ended, printing `status: <state>` (done, blocked, idle or error); give it a `--timeout`. It refuses rather than interrupt: `NotAnAgent` (3) when no coding agent runs there (and with `--wait`, for an agent that has never reported a status), `AgentBusy` (3) while the agent is working or blocked on a question, or not ready for a prompt. When the agent started working between the paste and the Enter, `AgentBusy` says `error.details.typed: true, submitted: false`: the text is in its input box, not submitted. Use `send` to answer a blocked agent's question, after `capture` shows you what it asks. A prompt is never typed twice.

Flags:

- `--allow-self`: Prompt the session this command runs in, which is otherwise refused.
- `--stdin`: Prompt with stdin's text, exactly as it comes, in place of TEXT.
- `--timeout VALUE`: With --wait, give up after this long (such as 30s or 10m), exiting 8; no limit when not given.
- `--wait`: Return once the turn the prompt starts has ended, printing the status it ended in: done, blocked, idle or error.

### `workroom events`

`workroom events`: Stream terminal sessions' events as JSON lines: a snapshot, then live changes.

Streams what happens to the sessions, one JSON object per line, until stopped: first a `session` event for each session as it is, then `snapshot-complete`, then live events: `session.created`, `session.ended`, `session.program_status`, `session.run_state`, `session.moved`, `client.attached`, `client.detached` and `session.input` (someone typed into a session; `sender` is who). Every event has `event`, `boot` and `revision`. By default your workroom's sessions; `--all` for every session, `--workroom ID` for one workroom, `--session TARGET` for one session, `--type` for some event types only. A `snapshot-complete` with `reason` `gap` or `lagged` replaced what you knew: start from it again. Ignore event types you don't know. To wait for one thing, `wait` is simpler.

Flags:

- `--all`: Every session's events, not only the caller's workroom's.
- `--session VALUE`: Only this session's events (a TARGET, as for sessions).
- `--type VALUE`: Only live events of this type, repeated or comma-separated: session.created, session.ended, session.program_status, session.run_state, session.moved, client.attached, client.detached or session.input.
- `--workroom VALUE`: Only this workroom's sessions' events (its id, a session's scope id).

### `workroom new`

`workroom new [flags]`: Open a new terminal beside this one, as a tab or a split in the app.

Opens a new terminal beside yours, as a tab, or as a split with `--split right` or `--split down`, and prints its id (with `--json`, the new `session`). It starts as your pane was made, with your pane's PATH and shell integration, in this command's folder or `--cwd`. `--title` names it. `--run CMD` makes it a run tab: the command runs under a supervisor, so `run-control` restarts and stops it and `wait --run` waits on it. Follow it with `command` or `wait` on the id it printed. A `--cwd` that is no folder is `NotADirectory` (3).

Flags:

- `--title VALUE`: Its name: the session's label, and its tab's name in the app.
- `--run VALUE`: A command to run in it under a run supervisor, as the Run tab runs one, so run-control restarts and stops it; a shell when not given.
- `--cwd VALUE`: The folder it starts in; this command's folder when not given.
- `--split VALUE`: Open it as a split beside this pane, right or down, when the pane is on screen; a tab otherwise.

### `workroom close`

`workroom close TARGET [flags]`: Close a terminal session, and its tab or split in the app.

Closes a session: its shell ends, and its tab or split closes in the app. It can't be undone, so its TARGET is a session's id, the end of its id or its label, never its live title. Close only what you opened, or what you were asked to close. A session that already ended is `SessionEnded` (3).

Flags:

- `--allow-self`: Close the session this command runs in, which is otherwise refused.

### `workroom run-control`

`workroom run-control TARGET restart|stop`: Restart or stop the command of a run session.

Restarts or stops the command of a run tab, as its Run tab's buttons do. Follow a restart with `wait TARGET --run running --timeout 1m` to know it is back up. A session that is no run tab is `NotARun` (3).

### `workroom api`

`workroom api [command]`: List, describe and call the terminal API's methods.

Raw access to every terminal API method on the daemon, for what no command above covers. `api list` lists the methods, `api describe METHOD` shows the JSON Schema of its parameters, its result and its errors, with examples, and `api call METHOD [PARAMS]` calls it, PARAMS a JSON object inline, `@FILE` or `-` for stdin. A method that streams prints one reply per line until `more` is false. The API only ever adds fields and methods; `revision` counts the additions.

- `workroom api call METHOD [PARAMS]`: Call METHOD with JSON parameters: inline, @FILE, or - for stdin.
- `workroom api describe METHOD`: Show METHOD's parameter and result schemas, with examples.
- `workroom api list`: List every method the daemon has.

## Exit codes and kinds

- 0: it worked. `command` exits with the command's own code instead.
- 1: an internal error, or a malformed command line.
- 2: bad input: a request the daemon can't read, or one too large.
- 3: not now, or not found: the session can't take it as it is (busy, ended, no agent, your own pane) or the target names no one session. Retrying later, or with another target, can work.
- 7: no daemon could be used: none answers, or it is too old.
- 8: a wait timed out.

`error.kind` says which, with `error.details` for what a kind says beside its message:

- `TargetNotFound` (3): No session matches the target. List them with `workroom sessions --all`.
- `TargetAmbiguous` (3): More than one session matches; `error.matches` lists them. Use an id.
- `SessionEnded` (3): The session ended before or while it was asked.
- `RefusedSelf` (3): The target is your own pane. Pass `--allow-self` only when you mean it.
- `AgentBusy` (3): The coding agent is working or waiting on a question. Wait for its turn to end.
- `NotAnAgent` (3): No coding agent runs in that session.
- `NotARun` (3): The session is no run tab.
- `AlternateScreen` (3): A full-screen program is up. `capture` it, then `send` keys to quit it.
- `NoShellIntegration` (3): The shell sends no integration marks, so a command's end can't be seen.
- `NotADirectory` (3): `new --cwd` names something that is not a folder.
- `ExitCodeMismatch` (3): The run exited, with another code; `error.details.exit_code` has it.
- `WaitInterrupted` (3): The daemon was updated mid-wait, or the output came too fast, so the event may have gone by. Look with `capture`, then wait again.
- `Busy` (3): The session or the daemon is busy (a command running, text at the prompt, too many waits). Retry shortly.
- `InvalidRequest` (2): The daemon can't read the request: an unknown method or parameters it refuses.
- `TooLarge` (2): More than one request carries (1 MiB of text or parameters), or than one reply holds (16 MiB, as `capture --lines` can ask; `--all` streams any length).
- `DaemonUnreachable` (7): No daemon answers: outside a Workroom pane, or `WORKROOM_DAEMON` names none.
- `DaemonTooOld` (7): The daemon is older than this `workroom`. Run `"$WORKROOM_BIN_DIR/workroom"`, the one that matches it; if that says so too, the daemon needs updating, which updating the app does.
- `WaitTimeout` (8): The `--timeout` passed first. What you waited on is still going.
- `InternalError` (1): Anything else, a malformed command line included. Read the message.

## Patterns

Run a test in another terminal and read the result:

```sh
workroom command TARGET --timeout 10m --json -- npm test
```

Hand a task to the coding agent in another terminal and wait for its turn:

```sh
workroom prompt TARGET --wait --timeout 30m 'Fix the failing login test, then run it.'
workroom capture TARGET --lines 200
```

Start a dev server in a new tab and wait until it is up:

```sh
id=$(workroom new --title 'dev server' --run 'npm run dev')
workroom wait "$id" --regex 'ready in [0-9]+ ?ms' --include-screen --timeout 2m
```

Answer a coding agent that is blocked on a question:

```sh
workroom capture TARGET
workroom send TARGET --key Enter
```

Interrupt what a terminal is running:

```sh
workroom send TARGET --key Ctrl+C
```

## See also

* [workroom](workroom.md)	 - Manage development workrooms
