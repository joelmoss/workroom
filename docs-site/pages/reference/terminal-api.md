---
title: Terminal API
description: "Every method of the terminal API, with its parameters, result, errors and an example, every event it streams, and how its requests and replies are shaped."
nightly: true
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

The terminal API is the daemon's public JSON service: what the `workroom` commands that drive terminals call, and what a script or coding agent can call itself with `workroom api call`. This page is generated from the methods and schemas the daemon serves, the ones `workroom api describe` shows. It describes revision 1.

The API is a stable contract: a release only ever adds methods and fields, and never removes, renames or changes the meaning of one. `revision`, in every reply, counts the additions, so check it when you need one. Every method and field on this page arrived in revision 1, the first. The daemon serves the same API on your Mac and on every remote host.

To see how to use it, read [Drive terminals from agents and scripts](../guides/drive-terminals-from-agents-and-scripts.md). For the kinds a failure can have, read [JSON output and exit codes](json-output.md#the-terminal-apis-kinds). The Mac app also uses [internal APIs](internal-apis.md), which carry no such promise.

## Calling it

From a Workroom terminal, `workroom api call METHOD PARAMS` sends one request and prints its replies. PARAMS is a JSON object inline, `@FILE` or `-` for stdin, and `{}` when left out. `workroom api list` lists the methods the daemon you reach has, and `workroom api describe METHOD` prints one's schemas, as on this page.

The daemon is the one `WORKROOM_DAEMON` names, which every Workroom terminal sets. On the wire, the API is service `0x08` of the daemon's socket, from protocol 12, one request per stream; the [internal APIs](internal-apis.md#the-socket) page shows the framing.

Any method can fail with [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1): a request the daemon can't read, a request or a reply over the limit, or a method that broke off.

## Requests and replies

A request:

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `method` | string | yes | A method's name, such as `session.list`. |
| `caller` | string |  | The id of the session the request comes from: the caller's `WORKROOM_PANE`. The daemon finds the caller from the connecting process first, and uses this only when that process descends from none of its sessions' shells (a daemonized tmux server's, say). |
| `params` | object |  | The method's parameters; `{}` when left out. |

A reply is one of:

| Field | Type | Description |
| ----- | ---- | ----------- |
| `revision` | integer | The API's revision, in every reply. |
| `result` | object | What the method answers, as its section below says. Not in a failed reply. |
| `error` | object | Why it failed, below. Only in a failed reply. |
| `more` | boolean | `true` when another reply follows on the stream, `false` on the last. A reply without it is the last. |

Read replies until `more` is false, whatever the method: any method may answer in several parts. An error is always a stream's last reply. `workroom api call` prints each reply as it comes, one envelope per line with `--json`.

### The error

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `kind` | string | yes | A stable code from the `workroom` registry. |
| `message` | string | yes |  |
| `details` | object |  | What some kinds say beside the message, for a script to read: `ExitCodeMismatch`'s `exit_code`, the code the run exited with (null when it is unknown); a prompt's `AgentBusy` once its text was pasted, `typed` and `submitted`: the agent went busy before its Enter, which was not pressed, so the text is in its input box. |
| `details.exit_code` | integer or null |  |  |
| `details.submitted` | boolean |  |  |
| `details.typed` | boolean |  |  |
| `matches` | array of [session](#the-session-object) |  | The sessions an ambiguous target matched. |

Branch on `kind`, never on `message`. For example:

```json
{"kind":"TargetNotFound","message":"no session matches \"dev\""}
```

```json
{"kind":"TargetAmbiguous","matches":[{"coding_agent":{"app":"claude","message":"Allow `npm test`?","state":"blocked","waiting_on_user":true},"cwd":"/Users/you/workrooms/swift-meadow","id":"5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11","label":"tests","resume":{"cwd":"/Users/you/workrooms/swift-meadow","program":"claude","reported_at":1795543200000},"run":false,"scope":{"id":"4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e","kind":"workroom"},"title":"Fix the login test"},{"coding_agent":null,"cwd":"/Users/you/workrooms/swift-meadow","id":"c0ffee00-1111-4222-8333-44445555beef","label":"tests","resume":null,"run":true,"scope":{"id":"4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e","kind":"workroom"},"title":null}],"message":"\"tests\" matches 2 sessions; name one by its id"}
```

```json
{"details":{"exit_code":1},"kind":"ExitCodeMismatch","message":"session c0ffee00-1111-4222-8333-44445555beef's run exited with code 1, not 0"}
```

```json
{"details":{"submitted":false,"typed":true},"kind":"AgentBusy","message":"the coding agent in session 5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11 started working after the prompt's text was pasted, so Enter was not pressed: the text is in its input box, unsubmitted"}
```

### Targets and the caller

A `target` names one session: by its full id, then an id suffix of at least 4 characters, then its label, then its live title. At the first of those with any match, more than one match is `TargetAmbiguous`, which lists them in `matches`, and nothing happens. `session.close` never takes a live title.

The caller is the session a request comes from: the one whose shell the connecting process descends from, else the session the request's `caller` names. Results that depend on it say which they found, as `caller`. `session.list` and `events.subscribe` keep to the caller's scope (its workroom) by default.

## Methods

### `api.describe`

This API's revision and every method's parameter and result schemas, or one method's when `method` names it.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `method` | string |  | One method to describe; every method when left out. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `error_schema` | object | yes | The JSON Schema of a failed reply's `error`, for every method, with errors under `examples`. Named `error_schema`, since an `error` is only ever a failure. |
| `methods` | array of object | yes |  |
| `methods[].errors` | array of string | yes | Error kinds beyond those any method can reply with: InvalidRequest, TooLarge, InternalError. |
| `methods[].input` | object | yes | The JSON Schema of `params`, with a `params` it accepts under `examples`. |
| `methods[].name` | string | yes |  |
| `methods[].output` | object | yes | The JSON Schema of `result`, with a `result` it replies with under `examples`. |
| `methods[].summary` | string | yes |  |
| `request` | object | yes | The JSON Schema of a request, for every method. |
| `revision` | integer | yes | Raised by each release that adds a method or a field. |

**Errors**: [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call api.describe '{"method":"session.list"}'
```

The same request as a command:

```sh
workroom api describe session.list
```

Its `result`, with the schemas it holds left out (`…`): they are what this page shows for each method, for the error and for a request.

```json
{
  "error_schema": "…",
  "methods": [
    {
      "errors": [],
      "input": "…",
      "name": "session.list",
      "output": "…",
      "summary": "The sessions that share the caller's scope, oldest first, or with `all: true` every session the daemon holds."
    }
  ],
  "request": "…",
  "revision": 1
}
```

### `session.list`

The sessions that share the caller's scope, oldest first, or with `all: true` every session the daemon holds.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `all` | boolean |  | `true` lists every session. `false`, the default, lists the sessions that share the caller's scope: every session when the request comes from no session, or from one with no scope. Default `false`. |
| `clients` | boolean |  | `true` adds each session's `clients`: every client attached to it, with its kind, hostname, when it attached, size, whether it owns the size and its keepalive. Default `false`. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `caller` | string or null | yes | The id of the session the request comes from: the session whose shell the connecting process descends from, else the request's `caller` when it names one of this daemon's sessions. Null for neither. |
| `sessions` | array of [session](#the-session-object) | yes |  |

**Errors**: [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call session.list '{"all":false,"clients":true}'
```

The same request as a command:

```sh
workroom sessions --clients
```

Its `result`:

```json
{
  "caller": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
  "sessions": [
    {
      "clients": [
        {
          "attached_at_ms": 1763700000000,
          "hostname": "joels-macbook.local",
          "id": 7,
          "keepalive": "answering",
          "kind": "pane",
          "owns_size": true,
          "size": {
            "columns": 120,
            "rows": 40
          }
        }
      ],
      "coding_agent": {
        "app": "claude",
        "message": "Allow `npm test`?",
        "state": "blocked",
        "waiting_on_user": true
      },
      "cwd": "/Users/you/workrooms/swift-meadow",
      "id": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
      "label": "claude",
      "resume": {
        "cwd": "/Users/you/workrooms/swift-meadow",
        "program": "claude",
        "reported_at": 1795543200000
      },
      "run": false,
      "scope": {
        "id": "4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e",
        "kind": "workroom"
      },
      "title": "Fix the login test"
    },
    {
      "clients": [],
      "coding_agent": null,
      "cwd": "/Users/you/workrooms/swift-meadow",
      "id": "c0ffee00-1111-4222-8333-44445555beef",
      "label": "dev server",
      "resume": null,
      "run": true,
      "scope": {
        "id": "4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e",
        "kind": "workroom"
      },
      "title": null
    }
  ]
}
```

### `session.resolve`

The one session a target names: by full id, then an id suffix of at least 4 characters, then label, then live title. Several matches at the first step that has any is `TargetAmbiguous`, listing them.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `target` | string | yes | A session's id or id suffix, its label, or its live title. |
| `clients` | boolean |  | `true` adds each session's `clients`: every client attached to it, with its kind, hostname, when it attached, size, whether it owns the size and its keepalive. Default `false`. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `caller` | string or null | yes | The id of the session the request comes from: the session whose shell the connecting process descends from, else the request's `caller` when it names one of this daemon's sessions. Null for neither. |
| `session` | [session](#the-session-object) | yes |  |

**Errors**: [`TargetNotFound`](json-output.md#the-terminal-apis-kinds) (3), [`TargetAmbiguous`](json-output.md#the-terminal-apis-kinds) (3), and [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call session.resolve '{"target":"dev server"}'
```

The same request as a command:

```sh
workroom sessions "dev server"
```

Its `result`:

```json
{
  "caller": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
  "session": {
    "coding_agent": null,
    "cwd": "/Users/you/workrooms/swift-meadow",
    "id": "c0ffee00-1111-4222-8333-44445555beef",
    "label": "dev server",
    "resume": null,
    "run": true,
    "scope": {
      "id": "4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e",
      "kind": "workroom"
    },
    "title": null
  }
}
```

### `terminal.capture`

A session's screen as text: the visible screen, trimmed, by default; with `lines`, that many rows of history above it too; with `all`, the whole scrollback, as several replies on the request's stream, each a chunk of whole lines (`chunk` counts from 0, and each reply's `more` says whether another follows). `unwrap` joins lines the pane soft-wrapped and `vt` keeps escape codes. Every reply also has the cursor, the size, whether the alternate screen is up and the live title. The visible screen is the alternate screen while a program has it up, and the history is the primary screen's, the only history there is: under a full-screen program, the shell's lines down to its last. `lines` past what one reply holds at the pane's width is `TooLarge`; a few captures of history run at once, and one past them is `Busy`, which a retry once one has finished can get past.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `target` | string | yes | A session's id or id suffix, its label, or its live title. |
| `all` | boolean |  | The whole scrollback, streamed in chunks. Not with `lines`. |
| `lines` | integer |  | Rows of history above the visible screen to include. At least 0. |
| `unwrap` | boolean |  | Join lines the pane soft-wrapped. |
| `vt` | boolean |  | Keep escape codes (colours, styles) instead of plain text. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `alternate_screen` | boolean | yes | Whether a full-screen program has the alternate screen up. |
| `chunk` | integer | yes | This reply's place among a capture's chunks, from 0; 0 without `all`. The reply's `more` says whether another follows. |
| `cursor` | object | yes | On the visible screen, from 0 at its top left. |
| `cursor.column` | integer | yes | From the left. |
| `cursor.row` | integer | yes | From the top. |
| `session` | string | yes | The id of the session read. |
| `size` | object | yes |  |
| `size.columns` | integer | yes | Its width. |
| `size.rows` | integer | yes | Its height. |
| `text` | string | yes | The rows, one line each (one per wrapped line with `unwrap`), without a final newline. With `all`, this reply's chunk: whole lines, which joined are the text. |
| `title` | string or null | yes | The live title its program last set (OSC 0 or 2). |

**Errors**: [`TargetNotFound`](json-output.md#the-terminal-apis-kinds) (3), [`TargetAmbiguous`](json-output.md#the-terminal-apis-kinds) (3), [`SessionEnded`](json-output.md#the-terminal-apis-kinds) (3), [`Busy`](json-output.md#the-terminal-apis-kinds) (3), and [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call terminal.capture '{"lines":100,"target":"dev server","unwrap":true}'
```

The same request as a command:

```sh
workroom capture "dev server" --lines 100 --unwrap
```

Its `result`:

```json
{
  "alternate_screen": false,
  "chunk": 0,
  "cursor": {
    "column": 0,
    "row": 6
  },
  "session": "c0ffee00-1111-4222-8333-44445555beef",
  "size": {
    "columns": 80,
    "rows": 24
  },
  "text": "$ npm run dev\n\n> vite\n\n  VITE ready in 312 ms\n  Local: http://localhost:5173/",
  "title": null
}
```

### `terminal.send`

Types into a session without attaching to it: `text` as it is (as a bracketed paste when the program has turned that on), then `keys`, each encoded for the session's keyboard modes, then Enter with `enter`. It takes no size, counts as nobody attached and gets no probes. More than 1 MiB is `TooLarge`; the caller's own session is `RefusedSelf` without `allow_self`. Each send is told as a `session.input` event naming the session it came from.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `target` | string | yes | A session's id or id suffix, its label, or its live title. |
| `allow_self` | boolean |  | Type into the caller's own session, which is otherwise refused with `RefusedSelf`. Default `false`. |
| `enter` | boolean |  | Enter last, after the text and the keys. Default `false`. |
| `keys` | array of string |  | Named keys, typed after the text in order, each encoded for the session's keyboard modes (kitty keyboard flags, application cursor keys): Enter, Tab, Escape (or Esc), Backspace, Space, Up, Down, Left, Right, Home, End, Insert, Delete, PageUp, PageDown, F1 to F12 or one character, after any of Ctrl+, Alt+, Shift+ and Super+, in any case (`Ctrl+C`, `Shift+Tab`). |
| `text` | string |  | Typed as it is, first: as a bracketed paste when the session's program has turned that on. It may not hold the paste's end (ESC [ 2 0 1 ~, or its C1 form, U+009B 2 0 1 ~), which would end the paste early. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `bytes` | integer | yes | How many bytes were typed, a bracketed paste's markers included. |
| `caller` | string or null | yes | The id of the session the request comes from: the session whose shell the connecting process descends from, else the request's `caller` when it names one of this daemon's sessions. Null for neither. |
| `modes` | object or null | yes | The session's modes what was typed was encoded for. Null when the daemon can't read them (built without terminal-state, or its shadow terminal failed): the text then went as it is, never as a paste, and keys are refused. |
| `modes.application_cursor_keys` | boolean | yes | DECCKM: cursor keys as SS3. |
| `modes.bracketed_paste` | boolean | yes | Bracketed paste (`CSI ? 2004 h`): the text went as a paste. |
| `modes.kitty_keyboard_flags` | integer | yes | The kitty keyboard protocol's flags its program pushed; 0 for none, the legacy encoding. |
| `session` | string | yes | The id of the session typed into. |

**Errors**: [`TargetNotFound`](json-output.md#the-terminal-apis-kinds) (3), [`TargetAmbiguous`](json-output.md#the-terminal-apis-kinds) (3), [`RefusedSelf`](json-output.md#the-terminal-apis-kinds) (3), [`SessionEnded`](json-output.md#the-terminal-apis-kinds) (3), [`Busy`](json-output.md#the-terminal-apis-kinds) (3), and [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call terminal.send '{"enter":true,"target":"dev server","text":"npm test"}'
```

The same request as a command:

```sh
workroom send "dev server" "npm test" --enter
```

Its `result`:

```json
{
  "bytes": 21,
  "caller": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
  "modes": {
    "application_cursor_keys": false,
    "bracketed_paste": true,
    "kitty_keyboard_flags": 0
  },
  "session": "c0ffee00-1111-4222-8333-44445555beef"
}
```

### `terminal.command`

Runs one shell command in a session and answers once it has ended, with its exit code and what it printed between the shell's OSC 133 marks, as plain text. It is typed at the shell's prompt as `terminal.send` types (and told as `session.input`), then Enter. A session whose shell sends no marks is `NoShellIntegration`; one running a command is `Busy`, and one with a full-screen program up `AlternateScreen`. `timeout_ms` ends the wait with `WaitTimeout`, leaving the command running.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `command` | string | yes | One line for the session's shell to run, typed at its prompt (as a bracketed paste when the shell has turned that on) and Enter pressed. Not empty, and no control characters: a line end is refused, so join commands with `;` or `&&`. At most 1 MiB. |
| `target` | string | yes | The session, as `session.resolve` takes it: its shell runs the command. |
| `allow_self` | boolean |  | Run it in the caller's own session, which is otherwise refused with `RefusedSelf`. Default `false`. |
| `timeout_ms` | integer |  | Fail with `WaitTimeout` after this many milliseconds, leaving the command running; no limit when left out. At least 0. |
| `vt` | boolean |  | `output` as the command printed it, escape codes and all, rather than read back as a screen: the bytes between its marks, bounded as the text is. Default `false`. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `caller` | string or null | yes | The id of the session the request comes from: the session whose shell the connecting process descends from, else the request's `caller` when it names one of this daemon's sessions. Null for neither. |
| `exit_code` | integer or null | yes | The command's exit code, as its shell's command-end mark (OSC 133 D) gave it; null when it gave none, or when a prompt ended it with no D (`exec zsh`: a shell that replaced the one that ran it). |
| `output` | string | yes | What the command printed, between its shell's OSC 133 marks: not the command line the shell echoed, nor the prompt after it. As `terminal.capture` reads a screen with `unwrap`: plain text, a line the pane wrapped one line, a line redrawn as it last stood, trailing blanks trimmed and no final newline; with `vt`, the bytes as printed. zsh's PROMPT_SP mark (`%` after output with no final newline) is the shell's, and is left out. Its last 1 MiB, from a line's start. |
| `session` | string | yes | The id of the session it ran in. |
| `truncated` | boolean | yes | Whether the command printed more than `output` holds, which is then its end. |

**Errors**: [`TargetNotFound`](json-output.md#the-terminal-apis-kinds) (3), [`TargetAmbiguous`](json-output.md#the-terminal-apis-kinds) (3), [`RefusedSelf`](json-output.md#the-terminal-apis-kinds) (3), [`NoShellIntegration`](json-output.md#the-terminal-apis-kinds) (3), [`AlternateScreen`](json-output.md#the-terminal-apis-kinds) (3), [`Busy`](json-output.md#the-terminal-apis-kinds) (3), [`WaitTimeout`](json-output.md#the-terminal-apis-kinds) (8), [`WaitInterrupted`](json-output.md#the-terminal-apis-kinds) (3), [`SessionEnded`](json-output.md#the-terminal-apis-kinds) (3), and [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call terminal.command '{"command":"npm test","target":"tests","timeout_ms":600000}'
```

The same request as a command:

```sh
workroom command tests --timeout 10m -- npm test
```

Its `result`:

```json
{
  "caller": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
  "exit_code": 1,
  "output": "> test\n> vitest run\n\n FAIL  src/login.test.ts > logs in\n\n Tests  1 failed | 41 passed (42)",
  "session": "c0ffee00-1111-4222-8333-44445555beef",
  "truncated": false
}
```

### `terminal.wait`

Waits for one thing to happen in a session: a program status, a run state, output matching a regex, the session ending, the next command to finish, or a coding agent's turn to end. Answered when it happens, or with `WaitTimeout` once `timeout_ms` passes. A session, a connection and the daemon each hold a few dozen or hundred waits at once, and one past them is `Busy`, which a retry once one has ended can get past.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `target` | string | yes | The session, as `session.resolve` takes it. |
| `command_finished` | boolean |  | `true`: wait for the next command to finish (the shell's OSC 133 command-end mark): the first to end after the wait starts, whether it was running then or starts later. A session whose shell has sent no marks fails with `NoShellIntegration`. |
| `ended` | boolean |  | `true`: wait for the session to end; already ended counts. |
| `exit_code` | integer |  | With `run: exited`, the code the run should exit with. The wait still answers when the run exits, whatever its code: with this one, as any met wait does; with another, `ExitCodeMismatch`, whose message says which. |
| `include_screen` | boolean |  | With `regex`, also match the screen as it is when the wait starts. |
| `regex` | string |  | Wait for output matching this regex (Rust `regex` syntax), with escape sequences stripped. Only output after the wait starts counts; `^` and `$` match at line ends, `\r\n` included, and `$` needs the line's end, or the output's once it stops. The match is the first one a search of the whole output finds, however it was read, answered once more output can't change it, or once the output goes quiet or the session ends, as the output so far gives it. A match is at most 16 KiB. A wait that falls behind output printed faster than it matches is `WaitInterrupted`, since what it dropped unmatched may have held one. |
| `run` | string |  | Wait for a run session's run to be in this state; now counts. One of `starting`, `running`, `stopping`, `stopped`, `exited`. |
| `status` | string |  | Wait for the session's coding agent to have this program status, as `session.list` reports it; now counts. One of `idle`, `working`, `done`, `blocked`, `error`. |
| `timeout_ms` | integer |  | Fail with `WaitTimeout` after this many milliseconds; no limit when left out. |
| `turn` | string |  | Wait for the coding agent's turn to end: the first program status other than `working` after a `working`, which the result's `status` gives (null when its report went: it exited). `next`: the turn a `working` reported now or later starts, so a `done` left from the turn before is no end of it; on an agent already working, that is the turn under way, and the wait ends with it (`terminal.prompt` refuses a working agent, so its wait is the turn after its prompt). `current`: the turn under way, which any status but `working` ends, now counting. One of `next`, `current`. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `condition` | string | yes | One of `status`, `run`, `regex`, `ended`, `command_finished`, `turn`. |
| `exit_code` | integer or null | yes | The run's exit code (`run: exited`), the command's (`command_finished`), or the session's shell's (`ended`), when there is one. |
| `match` | object or null | yes | What the regex matched, for `regex`. |
| `match.text` | string | yes | The matched text, escape sequences stripped. |
| `run_state` | string or null | yes | The run state reached, for `run`: a state, not the session listing's `run`, which says whether it is a run session. One of `starting`, `running`, `stopping`, `stopped`, `exited`, `null`. |
| `session` | string | yes | The session's id. |
| `status` | string or null | yes | The program status reached, for `status`; for `turn`, the one the turn ended in, null when the agent's report went. One of `idle`, `working`, `done`, `blocked`, `error`, `null`. |

**Errors**: [`TargetNotFound`](json-output.md#the-terminal-apis-kinds) (3), [`TargetAmbiguous`](json-output.md#the-terminal-apis-kinds) (3), [`WaitTimeout`](json-output.md#the-terminal-apis-kinds) (8), [`WaitInterrupted`](json-output.md#the-terminal-apis-kinds) (3), [`SessionEnded`](json-output.md#the-terminal-apis-kinds) (3), [`NoShellIntegration`](json-output.md#the-terminal-apis-kinds) (3), [`ExitCodeMismatch`](json-output.md#the-terminal-apis-kinds) (3), [`Busy`](json-output.md#the-terminal-apis-kinds) (3), and [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call terminal.wait '{"regex":"ready in \\d+ ms","target":"dev server","timeout_ms":30000}'
```

The same request as a command:

```sh
workroom wait "dev server" --regex 'ready in \d+ ms' --timeout 30s
```

Its `result`:

```json
{
  "condition": "regex",
  "exit_code": null,
  "match": {
    "text": "ready in 312 ms"
  },
  "run_state": null,
  "session": "c0ffee00-1111-4222-8333-44445555beef",
  "status": null
}
```

### `terminal.prompt`

Gives the coding agent in a session a prompt in one step: `text` as a bracketed paste, then Enter, typed as `terminal.send` types (and told as `session.input`). A session whose foreground program is no coding agent (`claude`, `codex`, or one that reported program status) is `NotAnAgent`; an agent working, waiting on the user or with no prompt up is `AgentBusy`. With `wait`, replies as the prompt is typed and as its turn starts (`more`), and last when that turn has ended, with the status it ended in; a `done` left from the turn before never counts.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `target` | string | yes | A session's id or id suffix, its label, or its live title. |
| `text` | string | yes | The prompt, typed as a bracketed paste and then Enter. It may not hold the paste's end (ESC [ 2 0 1 ~, or its C1 form), and is at most 1 MiB. Text already in the agent's input box is submitted with it, after it. A last word starting `@` or `$` gets a space after it, so Enter submits rather than pick a completion; a bare `/name` is the agent's own command, which Enter runs. |
| `allow_self` | boolean |  | Prompt the caller's own session, which is otherwise refused with `RefusedSelf`. Default `false`. |
| `timeout_ms` | integer |  | With `wait`, fail with `WaitTimeout` after this many milliseconds, counted from the request; no limit when left out. The prompt stays typed. |
| `wait` | boolean |  | Answer once the turn the prompt starts has ended: after a `working` reported since the prompt's Enter, the first status other than `working`, in the last reply's `status`. Earlier replies say the prompt was typed and the turn started. An agent that has never reported a status is `NotAnAgent`: its turn's end can't be heard. Default `false`. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `bytes` | integer | yes | How many bytes were typed: the paste, its markers included, and Enter. |
| `caller` | string or null | yes | The id of the session the request comes from: the session whose shell the connecting process descends from, else the request's `caller` when it names one of this daemon's sessions. Null for neither. |
| `modes` | object or null | yes | The session's modes the prompt was encoded for. |
| `modes.application_cursor_keys` | boolean | yes | DECCKM: cursor keys as SS3. |
| `modes.bracketed_paste` | boolean | yes | Bracketed paste (`CSI ? 2004 h`): the text went as a paste. |
| `modes.kitty_keyboard_flags` | integer | yes | The kitty keyboard protocol's flags its program pushed; 0 for none, the legacy encoding. |
| `session` | string | yes | The id of the session prompted. |
| `status` | string or null | yes | Without `wait`, null. With it, null in the reply that says the prompt was typed, `working` in the one that says its turn has started, and in the last (`more` false) the status its turn ended in: `done`, `blocked`, `idle` or `error`, or null when the agent's report went (it exited). One of `idle`, `working`, `done`, `blocked`, `error`, `null`. |

**Errors**: [`TargetNotFound`](json-output.md#the-terminal-apis-kinds) (3), [`TargetAmbiguous`](json-output.md#the-terminal-apis-kinds) (3), [`NotAnAgent`](json-output.md#the-terminal-apis-kinds) (3), [`AgentBusy`](json-output.md#the-terminal-apis-kinds) (3), [`RefusedSelf`](json-output.md#the-terminal-apis-kinds) (3), [`SessionEnded`](json-output.md#the-terminal-apis-kinds) (3), [`WaitTimeout`](json-output.md#the-terminal-apis-kinds) (8), [`Busy`](json-output.md#the-terminal-apis-kinds) (3), and [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call terminal.prompt '{"target":"claude","text":"Run the tests and fix what fails","timeout_ms":600000,"wait":true}'
```

The same request as a command:

```sh
workroom prompt claude "Run the tests and fix what fails" --wait --timeout 10m
```

Its `result`:

```json
{
  "bytes": 45,
  "caller": "0b9d33c1-7a44-4e1b-8f00-6c2a1d0abeef",
  "modes": {
    "application_cursor_keys": false,
    "bracketed_paste": true,
    "kitty_keyboard_flags": 0
  },
  "session": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
  "status": "done"
}
```

### `session.new`

Opens a new terminal: a session made as the caller's was, tagged with its scope, running a login shell, or `run`'s command under a run supervisor, in `cwd`, then shown by the app. The Mac showing the caller's pane opens it, as a split beside that pane when `split` asks and the pane is on screen, else as a tab; every other Mac lists it with the detached sessions, as every Mac does when no pane shows the caller. `opened`, here and in its `session.created`, says what the app was asked.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `cwd` | string |  | The absolute path of the folder it starts in; the caller's folder when left out, or the home folder from no pane. `workroom new` sends its own. |
| `run` | string |  | A command to run in it, under a run supervisor as the app's Run tab runs one, so `session.run_control` restarts and stops it and `terminal.wait` waits on its run state. Without it, a login shell. |
| `split` | string |  | Show it as a split beside the caller's pane, on its right or below it, when the Mac showing that pane has it on screen; a tab otherwise. One of `right`, `down`. |
| `title` | string |  | Its label, and the name of its tab in the app, kept as `session.label` keeps one: control and format characters left out, cut to 256 bytes and trimmed. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `caller` | string or null | yes | The id of the session the request comes from: the session whose shell the connecting process descends from, else the request's `caller` when it names one of this daemon's sessions. Null for neither. |
| `opened` | object or null | yes | `session.created`, and `session.new`'s result: what `session.new` asked of the app, null for a session made any other way. The Mac `hostname` names shows it, beside the pane of the session `by` names, as a split when `split` asks for one and that pane is on screen, else as a tab; every other Mac lists it with the detached sessions. With `hostname` null, no Mac shows the caller's pane, and every one lists it as detached. |
| `opened.by` | string or null | yes | The id of the session that asked for it; null from no pane. |
| `opened.hostname` | string or null | yes | The Mac to show it, as its pane's attach named it: the caller's pane client that owns its size, else the one that attached last, of those still answering. Null when none. |
| `opened.split` | string or null | yes | The split asked for, or null for a tab. One of `right`, `down`, `null`. |
| `session` | [session](#the-session-object) | yes |  |

**Errors**: [`NotADirectory`](json-output.md#error-kinds) (3), [`SessionEnded`](json-output.md#the-terminal-apis-kinds) (3), [`Busy`](json-output.md#the-terminal-apis-kinds) (3), and [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call session.new '{"run":"npm run dev","split":"right","title":"dev server"}'
```

The same request as a command:

```sh
workroom new --title "dev server" --run "npm run dev" --split right
```

Its `result`:

```json
{
  "caller": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
  "opened": {
    "by": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
    "hostname": "joels-macbook.local",
    "split": "right"
  },
  "session": {
    "coding_agent": null,
    "cwd": "/Users/you/workrooms/swift-meadow",
    "id": "c0ffee00-1111-4222-8333-44445555beef",
    "label": "dev server",
    "resume": null,
    "run": true,
    "scope": {
      "id": "4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e",
      "kind": "workroom"
    },
    "title": null
  }
}
```

### `session.run_control`

Restarts or stops a run session's command through its supervisor, as the app's Run tab does: `restart` stops it and starts it again in place, `stop` stops it and keeps the pane. A session that is no run is `NotARun`.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `action` | string | yes | `restart`: stop the run's command and start it again in place. `stop`: stop it and keep the pane. One of `restart`, `stop`. |
| `target` | string | yes | A session's id or id suffix, its label, or its live title. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `action` | string | yes | One of `restart`, `stop`. |
| `caller` | string or null | yes | The id of the session the request comes from: the session whose shell the connecting process descends from, else the request's `caller` when it names one of this daemon's sessions. Null for neither. |
| `session` | string | yes | The id of the run session. |

**Errors**: [`TargetNotFound`](json-output.md#the-terminal-apis-kinds) (3), [`TargetAmbiguous`](json-output.md#the-terminal-apis-kinds) (3), [`NotARun`](json-output.md#the-terminal-apis-kinds) (3), [`SessionEnded`](json-output.md#the-terminal-apis-kinds) (3), and [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call session.run_control '{"action":"restart","target":"dev server"}'
```

The same request as a command:

```sh
workroom run-control "dev server" restart
```

Its `result`:

```json
{
  "action": "restart",
  "caller": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
  "session": "c0ffee00-1111-4222-8333-44445555beef"
}
```

### `session.close`

Closes a terminal: ends its session (a run's supervisor asked to quit first), and the app closes its tab or split, since its `session.ended` says `closed`. Answered once its shell has gone. The caller's own session is `RefusedSelf` without `allow_self`.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `target` | string | yes | A session's id or id suffix, or its label: never its live title, which its program sets and anything it prints can change, since a close can't be undone. |
| `allow_self` | boolean |  | Close the session this request comes from, which is otherwise refused as `RefusedSelf`. Default `false`. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `caller` | string or null | yes | The id of the session the request comes from: the session whose shell the connecting process descends from, else the request's `caller` when it names one of this daemon's sessions. Null for neither. |
| `session` | string | yes | The id of the session closed. |

**Errors**: [`TargetNotFound`](json-output.md#the-terminal-apis-kinds) (3), [`TargetAmbiguous`](json-output.md#the-terminal-apis-kinds) (3), [`RefusedSelf`](json-output.md#the-terminal-apis-kinds) (3), [`SessionEnded`](json-output.md#the-terminal-apis-kinds) (3), [`Busy`](json-output.md#the-terminal-apis-kinds) (3), and [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call session.close '{"target":"dev server"}'
```

The same request as a command:

```sh
workroom close "dev server"
```

Its `result`:

```json
{
  "caller": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
  "session": "c0ffee00-1111-4222-8333-44445555beef"
}
```

### `session.label`

Gives a session another label, the name of its tab in the app, or clears it with null or an empty label: one name, which renaming the tab in the app sets too. Every Mac renames its tabs of the session, told by `session.labelled`; a label the session already has is told nothing.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `label` | string or null | yes | Its label, and the name of its tab in the app on every Mac, with its control and format characters (escapes, line breaks, bidi overrides, zero-width characters) left out, cut to 256 bytes and trimmed. Null or empty clears it, and the tab shows the name it shows unnamed: the title its program sets, else its program and folder. |
| `target` | string | yes | A session's id or id suffix, its label, or its live title. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `caller` | string or null | yes | The id of the session the request comes from: the session whose shell the connecting process descends from, else the request's `caller` when it names one of this daemon's sessions. Null for neither. |
| `changed` | boolean | yes | Whether its label changed: false when it already had this one, and no `session.labelled` was told. |
| `session` | [session](#the-session-object) | yes |  |

**Errors**: [`TargetNotFound`](json-output.md#the-terminal-apis-kinds) (3), [`TargetAmbiguous`](json-output.md#the-terminal-apis-kinds) (3), [`SessionEnded`](json-output.md#the-terminal-apis-kinds) (3), [`Busy`](json-output.md#the-terminal-apis-kinds) (3), and [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call session.label '{"label":"web","target":"dev server"}'
```

Its `result`:

```json
{
  "caller": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
  "changed": true,
  "session": {
    "coding_agent": null,
    "cwd": "/Users/you/workrooms/swift-meadow",
    "id": "c0ffee00-1111-4222-8333-44445555beef",
    "label": "web",
    "resume": null,
    "run": true,
    "scope": {
      "id": "4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e",
      "kind": "workroom"
    },
    "title": null
  }
}
```

### `events.subscribe`

The daemon's events, streamed: the sessions as they are (one `session` event each, then `snapshot-complete`), then each session created, ended and moved to another workroom, each change of its coding agent's program status, each run state, each client attaching and detaching, each send typed into it and each label it is given, as they happen, every one with the `boot` and `revision` a caller resumes from with `since`. By default the caller's scope's; `workroom`, `all`, `session` and `types` say whose and which. The stream goes on until the caller hangs up. A connection and the daemon each hold a few subscriptions at once, and one past them is `Busy`.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `all` | boolean |  | `true`: every session's events, whatever the caller's scope. Default `false`. |
| `session` | string |  | Only this session's events: a target, as `session.resolve` takes it, resolved once as the subscription starts. |
| `since` | object |  | Resume after the last event the caller had: its `boot` and `revision`. Answered `resumed`, then every event after it that the filters pass, when this daemon still holds them (a hand-off keeps them); else a snapshot whose `snapshot-complete` says `gap`. |
| `since.boot` | string | yes |  |
| `since.revision` | integer | yes | At least 0. |
| `types` | array of string |  | Only live events of these types; every type when left out. A snapshot's sessions, `snapshot-complete` and `resumed` are always sent. |
| `workroom` | string |  | Only the sessions of this workroom (a session's `scope.id`). By default, the caller's scope: the caller's workroom's sessions, or every session when the request comes from no session, or from one with no scope. Not with `all`. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `boot` | string | yes | Names this daemon's numbering of events: kept across a hand-off, new when the daemon starts afresh. |
| `event` | string | yes | `session`: one session as it is, in a snapshot. `snapshot-complete`: the snapshot's end; live events follow. `resumed`: the subscription went on after `since`; live events follow. `place`: where a filtered stream stands, once the events its filters skip have moved it on, at most once a second; a caller resumes from it, and `workroom events` never prints it. `session.created`, `session.ended`, `session.program_status` (its coding agent's state, program or waiting on the user changed, or its message did while it isn't working), `session.run_state` (each transition of a run, passing ones included), `session.moved` (tagged with another scope, sent to the subscribers of both), `client.attached` and `client.detached` (a client attached to the session, or left it; a session's end is its clients' too, with no `client.detached` each), `session.input` (`terminal.send` typed into it, from the session `sender` names) and `session.labelled` (given another label, by `session.label` or by a tab renamed in the app): live events. One of `session`, `snapshot-complete`, `resumed`, `place`, `session.created`, `session.ended`, `session.program_status`, `session.run_state`, `session.moved`, `client.attached`, `client.detached`, `session.input`, `session.labelled`. |
| `revision` | integer | yes | The event's place in its boot's numbering, daemon-wide, from 1: each live event's is higher than any before it, but a filtered stream skips those it doesn't pass, so it is not consecutive. A snapshot's sessions and its `snapshot-complete` have the revision the snapshot was taken at, `resumed` the one it resumed after, `place` the one the stream has reached. Not the reply's `revision`, the API's own, which it sits inside. |
| `bytes` | integer |  | `session.input`: how many bytes the send typed, its bracketed paste's markers included. Never the text. |
| `client` | object |  | `client.attached` and `client.detached`: the client, as it attached. |
| `client.attached_at_ms` | integer | yes | When it attached, in milliseconds since the Unix epoch. |
| `client.hostname` | string or null | yes | The machine the client is on, as it said: for a pane, the Mac showing it. Null when it didn't say. |
| `client.id` | integer | yes | Names this attachment among the daemon's clients; a client that attaches again is another. |
| `client.kind` | string or null | yes | `pane`: a pane of the app, on this machine or another. `app`: the app's own connection. `cli`: a `workroom attach` someone ran. Null for a client that didn't say, an older one. One of `pane`, `app`, `cli`, `null`. |
| `clients` | array of object |  | `session` and `session.created`: the clients attached to it, in the order they attached, as `client.attached` gave each. Their size, size owner and keepalive change with no event, so only `session.list` with `clients` has them. |
| `clients[].attached_at_ms` | integer | yes | When it attached, in milliseconds since the Unix epoch. |
| `clients[].hostname` | string or null | yes | The machine the client is on, as it said: for a pane, the Mac showing it. Null when it didn't say. |
| `clients[].id` | integer | yes | Names this attachment among the daemon's clients; a client that attaches again is another. |
| `clients[].kind` | string or null | yes | `pane`: a pane of the app, on this machine or another. `app`: the app's own connection. `cli`: a `workroom attach` someone ran. Null for a client that didn't say, an older one. One of `pane`, `app`, `cli`, `null`. |
| `closed` | boolean |  | `session.ended`: whether `session.close` (`workroom close`) ended it, so the app closes its tab or split; false for a session that ended any other way, whose pane stays. |
| `coding_agent` | object or null |  | `session`, `session.created` and `session.program_status`: as `session.list` gives it. |
| `coding_agent.app` | string |  | The program, such as `claude`. |
| `coding_agent.message` | string |  |  |
| `coding_agent.state` | string |  | One of `idle`, `working`, `done`, `blocked`, `error`. |
| `coding_agent.waiting_on_user` | boolean |  | Whether a report is blocked on the user. |
| `cwd` | string or null |  | `session` and `session.created`: as `session.list` gives it. |
| `exit_code` | integer or null |  | `session` and `session.run_state`: the run's exit code, when it exited; `session.ended`: the shell's, when the daemon saw it. |
| `label` | string or null |  | `session` and `session.created`: as `session.list` gives it; `session.labelled`: the label it was given, null when it was cleared. |
| `opened` | object or null |  | `session.created`, and `session.new`'s result: what `session.new` asked of the app, null for a session made any other way. The Mac `hostname` names shows it, beside the pane of the session `by` names, as a split when `split` asks for one and that pane is on screen, else as a tab; every other Mac lists it with the detached sessions. With `hostname` null, no Mac shows the caller's pane, and every one lists it as detached. |
| `opened.by` | string or null | yes | The id of the session that asked for it; null from no pane. |
| `opened.hostname` | string or null | yes | The Mac to show it, as its pane's attach named it: the caller's pane client that owns its size, else the one that attached last, of those still answering. Null when none. |
| `opened.split` | string or null | yes | The split asked for, or null for a tab. One of `right`, `down`, `null`. |
| `previous_scope` | object or null |  | `session.moved`: the scope it moved from. |
| `reason` | string |  | `snapshot-complete`: why the snapshot was sent. `subscribed`: the subscription started. `lagged`: the caller fell further behind than the daemon keeps, and events it was never sent were dropped. `gap`: `since` named a place this daemon doesn't hold (another boot's, or older than it keeps). After either of the last two, the snapshot replaces what the caller knew. One of `subscribed`, `lagged`, `gap`. |
| `run` | boolean |  | `session` and `session.created`: whether it is a run session. |
| `run_state` | string or null |  | `session` and `session.created`: the run's state, null before its first or for a session that isn't a run; `session.run_state`: the state it moved to. One of `starting`, `running`, `stopping`, `stopped`, `exited`, `null`. |
| `scope` | object or null |  | The session's scope, as `session.list` gives it; for `session.moved`, the one it moved to. |
| `sender` | string or null |  | `session.input`: the id of the session the send came from, the caller as `terminal.send` found it; null for a send from no session. The session itself when it was sent to with `allow_self`. |
| `session` | string |  | The session's id: every event but `snapshot-complete`, `resumed` and `place`. |
| `sessions` | array of string |  | `snapshot-complete`: the ids of the snapshot's sessions. |
| `title` | string or null |  | `session` and `session.created`: as `session.list` gives it. |

**Errors**: [`TargetNotFound`](json-output.md#the-terminal-apis-kinds) (3), [`TargetAmbiguous`](json-output.md#the-terminal-apis-kinds) (3), [`Busy`](json-output.md#the-terminal-apis-kinds) (3), and [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call events.subscribe '{"types":["session.program_status","session.run_state"]}'
```

The same request as a command:

```sh
workroom events --type session.program_status,session.run_state
```

Its `result`:

```json
{
  "boot": "9b2f6c1e-3d4a-4f5b-8c6d-7e8f9a0b1c2d",
  "coding_agent": {
    "app": "claude",
    "message": "Allow `npm test`?",
    "state": "blocked",
    "waiting_on_user": true
  },
  "event": "session.program_status",
  "revision": 42,
  "scope": {
    "id": "4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e",
    "kind": "workroom"
  },
  "session": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11"
}
```

### `events.unsubscribe`

Ends one of this connection's `events.subscribe` subscriptions, named by the stream it was asked on, before the connection does, and frees its place. `ended` says whether one was still held there.

**Parameters**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `stream` | integer | yes | The stream this connection sent the `events.subscribe` on, whose replies it reads. At least 1. |

**Result**

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `ended` | boolean | yes | `true`: this ended the subscription on it. `false`: the connection held none there, as for one that had already ended. |
| `stream` | integer | yes | The stream asked about. |

**Errors**: [`InvalidRequest`](json-output.md#the-terminal-apis-kinds) (2), [`TooLarge`](json-output.md#the-terminal-apis-kinds) (2), [`InternalError`](json-output.md#error-kinds) (1), which any method can return.

**Example**

```sh
workroom api call events.unsubscribe '{"stream":7}'
```

Its `result`:

```json
{
  "ended": true,
  "stream": 7
}
```

## Events

`events.subscribe` streams the daemon's events, one per reply, each reply's `more` true: the sessions as they are (a `session` event each, then `snapshot-complete`), or `resumed` when its `since` names a place the daemon still holds, then live events as they happen. `types` keeps to some live events. Every event has `event`, `boot` and `revision`. Ignore an `event` you don't know: later revisions add more.

### Event types

| `event` | Live | What it says | Fields |
| ------- | ---- | ------------ | ------ |
| `session` |  | One session as it is, in a snapshot. | `session`, `scope`, `label`, `title`, `run`, `cwd`, `coding_agent`, `run_state`, `exit_code`, `clients` |
| `snapshot-complete` |  | The snapshot's end. Live events follow. | `sessions`, `reason` |
| `resumed` |  | The subscription went on after its `since`. Live events follow. | none beside the three |
| `place` |  | Where a filtered stream stands, once events its filters skipped have moved it on, at most once a second. Resume from it as from any event; `workroom events` never prints it. | none beside the three |
| `session.created` | yes | A session was created. | `session`, `scope`, `label`, `title`, `run`, `cwd`, `coding_agent`, `run_state`, `exit_code`, `clients`, `opened` |
| `session.ended` | yes | A session ended. | `session`, `scope`, `exit_code`, `closed` |
| `session.program_status` | yes | Its coding agent's state, program or waiting on the user changed, or its message did while it isn't working. | `session`, `scope`, `coding_agent` |
| `session.run_state` | yes | Its run moved to another state, passing ones included. | `session`, `scope`, `run_state`, `exit_code` |
| `session.moved` | yes | It was tagged with another scope. Sent to the subscribers of both. | `session`, `scope`, `previous_scope` |
| `client.attached` | yes | A client attached to it. | `session`, `scope`, `client` |
| `client.detached` | yes | A client left it. A session's end is its clients' too, with no `client.detached` each. | `session`, `scope`, `client` |
| `session.input` | yes | `terminal.send` typed into it, or a command or prompt did. Never the text. | `session`, `scope`, `sender`, `bytes` |
| `session.labelled` | yes | It was given another label, by `session.label` or by its tab renamed in the app. | `session`, `scope`, `label` |

### Event fields

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `boot` | string | yes | Names this daemon's numbering of events: kept across a hand-off, new when the daemon starts afresh. |
| `event` | string | yes | `session`: one session as it is, in a snapshot. `snapshot-complete`: the snapshot's end; live events follow. `resumed`: the subscription went on after `since`; live events follow. `place`: where a filtered stream stands, once the events its filters skip have moved it on, at most once a second; a caller resumes from it, and `workroom events` never prints it. `session.created`, `session.ended`, `session.program_status` (its coding agent's state, program or waiting on the user changed, or its message did while it isn't working), `session.run_state` (each transition of a run, passing ones included), `session.moved` (tagged with another scope, sent to the subscribers of both), `client.attached` and `client.detached` (a client attached to the session, or left it; a session's end is its clients' too, with no `client.detached` each), `session.input` (`terminal.send` typed into it, from the session `sender` names) and `session.labelled` (given another label, by `session.label` or by a tab renamed in the app): live events. One of `session`, `snapshot-complete`, `resumed`, `place`, `session.created`, `session.ended`, `session.program_status`, `session.run_state`, `session.moved`, `client.attached`, `client.detached`, `session.input`, `session.labelled`. |
| `revision` | integer | yes | The event's place in its boot's numbering, daemon-wide, from 1: each live event's is higher than any before it, but a filtered stream skips those it doesn't pass, so it is not consecutive. A snapshot's sessions and its `snapshot-complete` have the revision the snapshot was taken at, `resumed` the one it resumed after, `place` the one the stream has reached. Not the reply's `revision`, the API's own, which it sits inside. |
| `bytes` | integer |  | `session.input`: how many bytes the send typed, its bracketed paste's markers included. Never the text. |
| `client` | object |  | `client.attached` and `client.detached`: the client, as it attached. |
| `client.attached_at_ms` | integer | yes | When it attached, in milliseconds since the Unix epoch. |
| `client.hostname` | string or null | yes | The machine the client is on, as it said: for a pane, the Mac showing it. Null when it didn't say. |
| `client.id` | integer | yes | Names this attachment among the daemon's clients; a client that attaches again is another. |
| `client.kind` | string or null | yes | `pane`: a pane of the app, on this machine or another. `app`: the app's own connection. `cli`: a `workroom attach` someone ran. Null for a client that didn't say, an older one. One of `pane`, `app`, `cli`, `null`. |
| `clients` | array of object |  | `session` and `session.created`: the clients attached to it, in the order they attached, as `client.attached` gave each. Their size, size owner and keepalive change with no event, so only `session.list` with `clients` has them. |
| `clients[].attached_at_ms` | integer | yes | When it attached, in milliseconds since the Unix epoch. |
| `clients[].hostname` | string or null | yes | The machine the client is on, as it said: for a pane, the Mac showing it. Null when it didn't say. |
| `clients[].id` | integer | yes | Names this attachment among the daemon's clients; a client that attaches again is another. |
| `clients[].kind` | string or null | yes | `pane`: a pane of the app, on this machine or another. `app`: the app's own connection. `cli`: a `workroom attach` someone ran. Null for a client that didn't say, an older one. One of `pane`, `app`, `cli`, `null`. |
| `closed` | boolean |  | `session.ended`: whether `session.close` (`workroom close`) ended it, so the app closes its tab or split; false for a session that ended any other way, whose pane stays. |
| `coding_agent` | object or null |  | `session`, `session.created` and `session.program_status`: as `session.list` gives it. |
| `coding_agent.app` | string |  | The program, such as `claude`. |
| `coding_agent.message` | string |  |  |
| `coding_agent.state` | string |  | One of `idle`, `working`, `done`, `blocked`, `error`. |
| `coding_agent.waiting_on_user` | boolean |  | Whether a report is blocked on the user. |
| `cwd` | string or null |  | `session` and `session.created`: as `session.list` gives it. |
| `exit_code` | integer or null |  | `session` and `session.run_state`: the run's exit code, when it exited; `session.ended`: the shell's, when the daemon saw it. |
| `label` | string or null |  | `session` and `session.created`: as `session.list` gives it; `session.labelled`: the label it was given, null when it was cleared. |
| `opened` | object or null |  | `session.created`, and `session.new`'s result: what `session.new` asked of the app, null for a session made any other way. The Mac `hostname` names shows it, beside the pane of the session `by` names, as a split when `split` asks for one and that pane is on screen, else as a tab; every other Mac lists it with the detached sessions. With `hostname` null, no Mac shows the caller's pane, and every one lists it as detached. |
| `opened.by` | string or null | yes | The id of the session that asked for it; null from no pane. |
| `opened.hostname` | string or null | yes | The Mac to show it, as its pane's attach named it: the caller's pane client that owns its size, else the one that attached last, of those still answering. Null when none. |
| `opened.split` | string or null | yes | The split asked for, or null for a tab. One of `right`, `down`, `null`. |
| `previous_scope` | object or null |  | `session.moved`: the scope it moved from. |
| `reason` | string |  | `snapshot-complete`: why the snapshot was sent. `subscribed`: the subscription started. `lagged`: the caller fell further behind than the daemon keeps, and events it was never sent were dropped. `gap`: `since` named a place this daemon doesn't hold (another boot's, or older than it keeps). After either of the last two, the snapshot replaces what the caller knew. One of `subscribed`, `lagged`, `gap`. |
| `run` | boolean |  | `session` and `session.created`: whether it is a run session. |
| `run_state` | string or null |  | `session` and `session.created`: the run's state, null before its first or for a session that isn't a run; `session.run_state`: the state it moved to. One of `starting`, `running`, `stopping`, `stopped`, `exited`, `null`. |
| `scope` | object or null |  | The session's scope, as `session.list` gives it; for `session.moved`, the one it moved to. |
| `sender` | string or null |  | `session.input`: the id of the session the send came from, the caller as `terminal.send` found it; null for a send from no session. The session itself when it was sent to with `allow_self`. |
| `session` | string |  | The session's id: every event but `snapshot-complete`, `resumed` and `place`. |
| `sessions` | array of string |  | `snapshot-complete`: the ids of the snapshot's sessions. |
| `title` | string or null |  | `session` and `session.created`: as `session.list` gives it. |

Some events, as the daemon's schema gives them:

```json
{"boot":"9b2f6c1e-3d4a-4f5b-8c6d-7e8f9a0b1c2d","coding_agent":{"app":"claude","message":"Allow `npm test`?","state":"blocked","waiting_on_user":true},"event":"session.program_status","revision":42,"scope":{"id":"4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e","kind":"workroom"},"session":"5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11"}
```

```json
{"boot":"9b2f6c1e-3d4a-4f5b-8c6d-7e8f9a0b1c2d","event":"place","revision":1800}
```

```json
{"boot":"9b2f6c1e-3d4a-4f5b-8c6d-7e8f9a0b1c2d","event":"session.moved","previous_scope":{"id":"4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e","kind":"workroom"},"revision":43,"scope":{"id":"7d1e2f3a-4b5c-4d6e-8f70-8192a3b4c5d6","kind":"workroom"},"session":"5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11"}
```

```json
{"boot":"9b2f6c1e-3d4a-4f5b-8c6d-7e8f9a0b1c2d","client":{"attached_at_ms":1763700000000,"hostname":"joels-macbook.local","id":7,"kind":"pane"},"event":"client.attached","revision":44,"scope":{"id":"4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e","kind":"workroom"},"session":"5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11"}
```

```json
{"boot":"9b2f6c1e-3d4a-4f5b-8c6d-7e8f9a0b1c2d","bytes":14,"event":"session.input","revision":45,"scope":{"id":"4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e","kind":"workroom"},"sender":"5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11","session":"c0ffee00-1111-4222-8333-44445555beef"}
```

```json
{"boot":"9b2f6c1e-3d4a-4f5b-8c6d-7e8f9a0b1c2d","event":"session.labelled","label":"dev server","revision":46,"scope":{"id":"4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e","kind":"workroom"},"session":"c0ffee00-1111-4222-8333-44445555beef"}
```

### Resuming, gaps and lagging

Each live event takes the next `revision` of the daemon's events under its `boot`, which a hand-off keeps and a daemon started afresh replaces. Keep the `boot` and `revision` of the last event you read (a live event's, a `place`'s, or a snapshot's end) and subscribe again with `since: {boot, revision}`. When the daemon still holds every event after it, it answers `resumed` and sends them: nothing missed, nothing twice. When it can't, because it is another boot or the place is older than it keeps, it sends the sessions afresh, with `snapshot-complete`'s `reason` `gap`. A subscriber that falls further behind than the daemon keeps is sent the sessions afresh too, `reason` `lagged`, and goes on live. After either, the snapshot replaces what you knew.

## Shared objects

### The session object

How every reply that lists sessions gives one.

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `coding_agent` | object or null | yes | What its program last said through program status (OSC 7501): the newest report waiting on the user, else the newest. Null with none. |
| `coding_agent.app` | string | yes | The program, such as `claude`. |
| `coding_agent.message` | string | yes |  |
| `coding_agent.state` | string | yes | One of `idle`, `working`, `done`, `blocked`, `error`. |
| `coding_agent.waiting_on_user` | boolean | yes | Whether a report is blocked on the user. |
| `cwd` | string or null | yes | The working directory of its foreground program. |
| `id` | string | yes | The session's id, a hyphenated UUID. |
| `label` | string or null | yes | The session's name, its tab's name in the app: the one the user gave its tab, `session.new`'s `title` or `session.label`'s, which are one name. Null when it has none. |
| `resume` | object or null | yes | What its program last reported, over the Program Resume Protocol (OSC 7577), about how to start it again should the session be lost: its resume record. Never the command's arguments, which can hold secrets. Null when no program has reported one. |
| `resume.cwd` | string or null | yes | Where it would start: the folder it reported, else its own when it reported. |
| `resume.program` | string | yes | The program the record starts, such as `claude`. |
| `resume.reported_at` | integer | yes | When it reported, in milliseconds since the Unix epoch. |
| `run` | boolean | yes | Whether it is a run session. |
| `scope` | object or null | yes | What the session belongs to; null for none. `kind` is `workroom` today, and others may be added. |
| `scope.id` | string | yes | The workroom, as the app tags it. |
| `scope.kind` | string | yes |  |
| `title` | string or null | yes | The live title its program last set (OSC 0 or 2). |
| `clients` | array of [client](#the-client-object) |  | Every client attached to it, in the order they attached. Only when the request asks for `clients`, and then always, `[]` for none: a session without it is from a daemon too old to list clients. |

### The client object

A client attached to a session, as `session.list` and `session.resolve` give it with `clients: true`.

| Field | Type | Required | Description |
| ----- | ---- | -------- | ----------- |
| `attached_at_ms` | integer | yes | When it attached, in milliseconds since the Unix epoch. |
| `hostname` | string or null | yes | The machine the client is on, as it said: for a pane, the Mac showing it. Null when it didn't say. |
| `id` | integer | yes | Names this attachment among the daemon's clients; a client that attaches again is another. |
| `keepalive` | string | yes | Whether its terminal answers the daemon's probes, which a remote pane asks for. `off`: it didn't ask. `answering`: it asked, and has missed no probe, which includes one not sent its first yet. `late`: it missed one or more in a row. `stale`: it missed enough that it no longer counts as attached, and its connection is being closed. One of `off`, `answering`, `late`, `stale`. |
| `kind` | string or null | yes | `pane`: a pane of the app, on this machine or another. `app`: the app's own connection. `cli`: a `workroom attach` someone ran. Null for a client that didn't say, an older one. One of `pane`, `app`, `cli`, `null`. |
| `owns_size` | boolean | yes | Whether the session's pty follows this client's size: the client that last typed or clicked, or the one left when the others went. |
| `size` | object | yes | The size its window last had, 0 by 0 when it has none yet. |
| `size.columns` | integer | yes | At least 0. |
| `size.rows` | integer | yes | At least 0. |
