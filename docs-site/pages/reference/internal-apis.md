---
title: Internal APIs
description: "The daemon services, frames, subcommands and hidden commands the Workroom app uses beyond the terminal API, documented for anyone who finds them useful, with no promise that they stay the same."
nightly: true
---

<!-- Generated from the workroom binary's commands by `make docs-cli`. Don't edit by hand. -->

> [!WARNING]
> These are what the Workroom app uses to talk to its daemons and its CLI. They are documented for anyone who finds them useful, but they are not covered by the terminal API's compatibility promise, and may change in any release, without notice. For anything a script or a coding agent relies on, use the [terminal API](terminal-api.md), which only ever adds.

To notice a change, compare the daemon's protocol version (`workroom protocol` prints it) and `workroom --version` with the ones you built against, and the terminal API's `revision`, which `workroom api describe` shows. This page is generated from the `workroom` binary's source, so it describes the build it came with.

## The socket

Every daemon listens on one Unix socket: on the Mac, the one the app starts in its Application Support folder; on a host, the one its supervisor starts. A Workroom terminal names it in `WORKROOM_DAEMON`. The socket is the only security boundary: anything that can reach it can do what its user can.

Both sides first send a greeting, then every message is an envelope that names its service and stream:

```text
Hello:     "WRA1" | protocol_version: u16 | build_len: u8 | build: [u8]
Envelope:  service: u8 | stream: u32 | length: u32 | payload: [u8]
```

Integers are big-endian, and a payload is at most 1048576 bytes. Both sides speak the lower of their two versions, and a client checks the daemon's own version before it uses a service that arrived later, since an older daemon drops what it doesn't know. This build speaks protocol 12. Each request opens a stream of its own; a service's events, where it has any, come on stream 0.

## Services

| Byte | Service | Since protocol | What it is for |
| ---- | ------- | -------------- | -------------- |
| `0x00` | Control | 1 | Session control not tied to one attach: list, kill, hand off, signal a run, retag, and say the connection pings. Its frames are the Terminal service's framing. |
| `0x01` | Terminal | 1 | One attach to a session's pty: the session's output, and the client's typing and size. `workroom attach`, which every pane runs, speaks it. |
| `0x02` | VCS | 2 | A remote workroom's repository: Git reads (history, changes, diffs, file contents), `git` runs for writes, and file stats. |
| `0x03` | File | 3 | A remote workroom's files: listing, reading, resolving paths and watching for changes. |
| `0x04` | Status | 4, retired | Retired. Every request is answered `{"unsupported": …}` for apps that still ask. |
| `0x05` | Forward | 5 | Port forwarding: one loopback TCP connection on the daemon's machine per stream, or a listener whose connections the client claims. |
| `0x06` | Layout | 7 | Each remote workroom's tabs and splits, kept on its host so every Mac opens the same ones. |
| `0x07` | ProgramStatus | 8 | What each session's program reports through OSC 7501 (a coding agent working, done or waiting on you), and how its shell's last long command ended. |
| `0x08` | Terminal API | 12 | The public terminal API. Not internal: see the [terminal API reference](terminal-api.md). |

## Terminal and Control frames

The Terminal and Control services carry frames: one byte of kind, a big-endian `u32` length, then the payload, at most 1 MiB. A pane's `workroom attach` sends `Attach` and then the user's typing and size; the app's own connection to each daemon sends the Control frames, to list the sessions it shows as detached, close one, hand the daemon off to a newer build, restart or stop a Run tab, and move a session to another workroom.

| Byte | Frame | Direction | Since protocol | Payload | What it does |
| ---- | ----- | --------- | -------------- | ------- | ------------ |
| `0x01` | `Attach` | to the daemon | 1 | The 16-byte session id, then NUL-terminated `KEY=VALUE` entries (below). | Attaches to the session, creating it unless `CREATE=0`. Answered `Attached`, then the session's screen and its `Output`, or `Failure`. |
| `0x02` | `Input` | to the daemon | 1 | Bytes. | Typed into the session's pty. |
| `0x03` | `Resize` | to the daemon | 1 | Columns and rows, then the width and height in pixels, each a big-endian `u16`. | The client's window size. The session follows the size of the client that last typed or clicked. |
| `0x11` | `Attached` | to the client | 1 | None. | The attach was accepted. |
| `0x12` | `Output` | to the client | 1 | Bytes. | What the session's program printed. |
| `0x13` | `Exited` | to the client | 1 | The shell's exit code, a big-endian `i32`. | The session ended. |
| `0x14` | `Failure` | to the client | 1 | A UTF-8 reason. | A request failed. `no session …` means the session is gone. |
| `0x21` | `List` | to the daemon | 1 | None. | Lists the live sessions. Answered `Sessions`. |
| `0x22` | `Info` | to the daemon | 1 | None. | Reserved: the app's frame decoder knows its byte, and this daemon answers nothing to it. |
| `0x23` | `Kill` | to the daemon | 1 | The 16-byte session id. | Ends the session. Answered `Acknowledged` once its processes are gone. |
| `0x24` | `KillAll` | to the daemon | 1 | None. | Ends every session. Answered `Acknowledged`. |
| `0x25` | `HandOff` | to the daemon | 6 | `force` as one byte, then the absolute path of a binary. | Replaces the daemon's program with that binary in place, keeping every session and its processes. Answered `Acknowledged` with `handing off` or `current`, or `Failure` with why it was refused. |
| `0x26` | `Signal` | to the daemon | 9 | The 16-byte session id, then one run signal byte (below). | Asks a run session's supervisor to restart, stop or quit its command. Answered `Acknowledged` once sent. |
| `0x27` | `Retag` | to the daemon | 10 | The 16-byte session id, then the workroom as UTF-8. | Tags a live session with another workroom. Answered `Acknowledged`. |
| `0x28` | `Pings` | to the daemon | 11 | None. | Says the client sends something at least every 15 s, so the daemon may close the connection after 60 s of silence. Answered `Acknowledged`. |
| `0x29` | `Peer` | to the daemon | 11 | NUL-terminated `KEY=VALUE` entries: the ssh login's environment. | Sent by `relay` alone, right after the greeting, and never answered. Sessions this connection creates from the host's environment are built from it. |
| `0x31` | `Sessions` | to the client | 1 | A count, then each session's id, pid, tty, folder, whether it is attached and its metadata. | The answer to `List`. |
| `0x32` | `Acknowledged` | to the client | 1 | None, or a UTF-8 word. | A control request was done. |

### Attach entries

| Entry | What it says |
| ----- | ------------ |
| `SHELL` | The shell to start, when the attach creates the session. |
| `COMMAND` | The command to run in place of a login shell. |
| `CWD` | The folder it starts in. |
| `RESOURCES` | Ghostty's resources folder, whose shell integration the shell is pointed at. |
| `COLS` | The client's columns. |
| `ROWS` | The client's rows. |
| `XPIXELS` | The client's width in pixels; 0 for unknown. |
| `YPIXELS` | The client's height in pixels; 0 for unknown. |
| `CREATE` | `0`: attach only to a session that exists, never create one. A restored pane sends it. |
| `HOST` | `1`: build the session from the host's own environment and account (a remote pane). |
| `CLIENT` | The client's kind, `pane`, `app` or `cli`, as `sessions --clients` reports it. |
| `HOSTNAME` | The machine the client is on: for a pane, the Mac showing it. |
| `ENV:NAME` | One variable for the session's environment, the client's own, not the daemon's. |

### Run signals

The byte a `Signal` frame carries.

| Byte | What it asks |
| ---- | ------------ |
| `1` | `SIGUSR1`: stop the command and run it again in place. |
| `2` | `SIGUSR2`: stop the command and keep the pane. |
| `3` | `SIGTERM`: stop the command, then end the session. |

## JSON services

### VCS

JSON on the chunked envelope: each payload starts with one byte, `0` for a continuation and `1` for the last, and a reply is at most 16 MiB. A read is `{"version": 1, "root", "backend": "git", "method", …}` with `limit`, `revision`, `path` and `base` as it needs them; a write or a stat names its `kind` instead. A reply is `{"version": 1, "result": …}` or `{"version": 1, "error": …}`. The app sends it for remote workrooms; a local workroom's repository is read on the Mac.

| Request | Takes and answers | When the app sends it |
| ------- | ----------------- | --------------------- |
| `capabilities` | → `{version, reads, exec}`: the read version, how many reads, and the exec service's version. | Before anything else on a connection to a host. |
| `log` | `limit` → a page of history. | The History tab. |
| `changeset` | `revision` → one commit's files and stats. | Selecting a commit. |
| `current_ref` | → the branch and commit checked out. | The branch shown for the workroom. |
| `working_status` | → uncommitted changes. | The Changes tab. |
| `file_diff` | `revision`, `path` → one file's diff in a commit. | A file's diff in a commit. |
| `working_file_diff` | `path`, `base: working_copy` → one file's uncommitted diff. | A changed file's diff. |
| `file_content` | `revision`, `path` → a file's contents at a commit. | Showing a file as it was. |
| `commit_parent_file_content` | `revision`, `path` → the file in the commit's parent. | The left side of a commit's diff. |
| `working_base_file_content` | `path`, `base: working_copy` → the file at `HEAD`. | The left side of an uncommitted diff. |
| `exec` | `kind: exec`, `executable: git`, `args`, `dir`, `timeout_ms`, and optional `stdin`, `env` and `host_environment` → `stdout`, `stderr`, `exit_code`, `timed_out`, `signaled`. | Every Git write on a remote workroom (commit, push, pull and the rest), which the app classifies as it would a local `git`. |
| `stat` | `kind: stat`, `paths` (at most 64), `read` → each path's `exists`, `is_dir`, `modified_at` and, for a small file in `read`, its `text`. | Checking files on a host, such as a project's scripts. |

### File

JSON on the VCS service's chunked envelope, one envelope per request. Paths are relative to the repository and resolved on the host.

| Request | Takes and answers | When the app sends it |
| ------- | ----------------- | --------------------- |
| `capabilities` | → the service's version and limits. | Before the first file request on a connection. |
| `list` | `root` → the repository's files, from a fixed `git` listing. | Listing a remote workroom's files. |
| `read` | `root`, `path` → one file's bytes, base64. | Opening a file in a remote workroom. |
| `resolve` | `root`, `path` → the repository path a path with `..` or links names on the host. | Opening a file path clicked in a remote terminal. |
| `watch` | `root`, `subscription` → changes, sent on stream 0 until `unwatch`. | Refreshing what the app shows of a remote workroom when its files change. |
| `unwatch` | `subscription` → stops it. | Closing what watched. |

### Layout

JSON on the chunked envelope. The daemon never parses a layout: it is the app's own JSON, kept as bytes beside `serve --screens`. A daemon with no screens folder keeps none and says so.

| Request | Takes and answers | When the app sends it |
| ------- | ----------------- | --------------------- |
| `capabilities` | → `{version, available, maxBlobBytes, maxKeys}`. | Before reading a remote workroom's layout. |
| `get` | `key` → `{revision, blob}`; revision 0 and no blob for a key never written. | Opening a remote workroom. |
| `put` | `key`, `expected` (the revision read), `blob` → `{revision}`, or a `stale` error with the current one. | Saving a remote workroom's tabs and splits when they change. |

### Forward

Each payload is one opcode byte, then a body: `0x01` OPEN (the JSON request, once), `0x02` REPLY (`{"version": 1, "result" | "error"}`), `0x03` DATA (the connection's bytes), `0x04` EOF (a half-close), `0x05` CLOSE (the stream is done; the daemon's is always its last word on it), `0x06` ACCEPTED (a listener has a connection to claim).

| Request | Takes and answers | When the app sends it |
| ------- | ----------------- | --------------------- |
| `open` | `host` (a loopback address), `port` → `{opened: true}`, then DATA both ways. | A port forwarded from a remote workroom, one stream per connection to it. |
| `listen` | `port` → a listener on the host's loopback, which sends ACCEPTED per connection. | Forwarding a port from the Mac to the host, such as Git's credential relay. |
| `accept` | `listener` → claims one waiting connection on a new stream. | Each ACCEPTED connection. |

### ProgramStatus

JSON, one envelope per request, each answered `{"version": 1, "result" | "error"}`. Events go to stream 0: one `status` per session, `snapshot-complete`, then each change. What programs send is OSC 7501, described in the repository's `docs/program-status.md`.

| Request | Takes and answers | When the app sends it |
| ------- | ----------------- | --------------------- |
| `subscribe` | → `{available: true}`, then the events. A daemon built without its terminal state answers `available: false`. | On every daemon connection, for the tabs' status marks and alerts. |
| `unsubscribe` | → `{ok: true}`. | When the app stops listening. |
| `seen` | `session`, `revision`, optional `states` → drops the `done` and `error` reports shown as of `revision`. | You looked at the pane. |
| `clear` | `session` → drops every report. | Clear Status. |

### The terminal API, as the app uses it

The app makes one subscription to each daemon's [terminal API](terminal-api.md): `events.subscribe` with `all: true` for `session.input` (the typing marker on a pane another session types into), `session.created` and `session.ended` (what `workroom new` and `workroom close` ask of the app) and `session.labelled` (tab names), and `events.unsubscribe` when it stops listening. It calls `session.label` when you rename a tab, and `api.describe` to learn which event types an older daemon has. Those are public, and described there.

## The daemon's subcommands

The same binary is the daemon. These subcommands are its own, never the CLI's commands, and `list` is the daemon's only with `--socket`. On a host the binary is installed as `workroomd`, the name this text uses:

```text
  workroomd serve --socket <path> [--idle-timeout <secs>|never] [--screens <dir>]
                  [--user <name|uid[:gid]> [--own <dir>]...]
        own ptys and services (the daemon role).
        --idle-timeout never is for a supervised remote daemon, which must keep running with no
        client attached.
        --screens <dir> keeps each session's screen in <dir>, so a pane reattaching after the
        host reboots is shown its last one. <dir> must survive a reboot: not the socket's.
        --user, run as root (a container's entrypoint), makes the socket's folder and each
        --own <dir> for that user, then becomes it; a ~ in --screens is that user's home.
  workroomd serve --stdio
        serve one connection over stdin/stdout, whose sessions die with it; a transport test
        entry point, not a persistent remote daemon (that is serve --idle-timeout never + relay)
  workroomd attach --socket <path> [--session <uuid>]
        relay stdio to a session; what libghostty forks
  workroomd attach [--no-create] --dial <command> [<argument>...]
        the same, to a daemon reached through the command's stdio (a remote pane,
        `--dial ssh -T <host> <binary> relay --socket <path>`): the session is built
        from the host's environment; exits 255 for a link to retry
  workroomd relay --socket <path>
        copy bytes between stdio and a running daemon's socket, and nothing else;
        what a driver runs on the far side (`ssh host workroomd relay --socket <path>`)
  workroomd list --socket <path>
        print the daemon's live sessions
  workroomd program-status --socket <path> [--json]
        print what each session's program says it is doing (OSC 7501), as the app is told it
  workroomd hand-off --socket <path> --binary <path> [--force]
        replace the running daemon's program with <binary>, keeping every session and its pid.
        Prints `current` when the daemon is running that binary already, `handed off` when it was
        replaced. Refused, with the daemon left running, when <binary> cannot restore its sessions
        (exit 1) or the daemon predates hand-off (exit 3). --force hands off to the same binary.
  workroomd handoff-check <table>
        whether this build can restore the sessions a hand-off table describes; run by the daemon
        handing off, before it replaces itself
  workroomd credential <get|store|erase>
        git's credential helper for a local container workroom: answers github.com with what the
        Mac relays
  workroomd credential relay --port <port>
        have a local container workroom ask the Mac for git's credentials through <port> on this
        box's loopback, reading the relay's secret from stdin, and make `workroomd credential`
        git's helper for https://github.com
  workroomd run-script --dir <dir> --timeout <secs> [--env NAME=VALUE]... -- <script>
        run a remote workroom's setup or teardown script in <dir>, with the login shell's
        environment and each NAME=VALUE, streaming its output. Exits with the script's status,
        124 when <secs> ran out, 126 when it could not start; the whole tree is killed on a
        timeout or a SIGTERM, SIGHUP or SIGINT
  workroomd run-supervisor --status <path> -- <command>
        what a run session's pty runs: the run supervisor around <command> in the login shell,
        writing its state (running, stopped, exited <code>) to <path>; USR1 restarts the command,
        USR2 stops it and keeps the pane, TERM stops it and exits
  workroomd protocol
        print the protocol version this build speaks
```

| Subcommand | When the app runs it |
| ---------- | -------------------- |
| `serve` | Starts the daemon: on the Mac when it first needs one, on a host from its supervisor. |
| `attach` | What every pane runs, which libghostty forks; with `--dial`, a remote pane's. |
| `relay` | What a host driver runs on the far side of ssh or a container's exec. |
| `list` | Checks a host's daemon and its sessions during bootstrap. |
| `program-status` | Not run by the app: a way to see what it is told. |
| `hand-off` | Updates a running daemon in place, on the Mac and on hosts. |
| `handoff-check` | Run by the daemon handing off, against the binary it would become. |
| `credential` | A local container's Git credential helper, and its relay. |
| `run-script` | Runs a remote workroom's setup and teardown scripts. |
| `run-supervisor` | What a run session's pty runs around its command. |
| `protocol` | Asks a binary which protocol it speaks before using it. |

## Hidden commands

The CLI has commands that `workroom --help` doesn't list, because the app runs them, not people. They take `--json` and keep the [JSON output contract](json-output.md) like every other command, and their kinds are in its tables. Shell completion runs one more, `workroom __complete ARGS… WORD` (and `__completeNoDesc`), which prints what to complete.

### `workroom add-project`

Register a project (internal; used by the macOS app via --json). The app runs it for: Adding a project, and with `--clone`, cloning one from a URL first.

Runs on a Mac only.

```text
workroom add-project [PATH]
```

| Flag | Takes a value | Required | Usage |
| ---- | ---- | ---- | ---- |
| `--clone` | yes |  | Clone this repository URL into PATH, then register it |
| `--create` |  |  | Create and git-initialize the directory if it does not already exist |

### `workroom claim-provisioned`

Move the remote entries a build made from another config into this one (used by the desktop app). The app runs it for: At launch, moving the remote workrooms a build made into its own config.

Runs on a Mac only.

```text
workroom claim-provisioned
```

| Flag | Takes a value | Required | Usage |
| ---- | ---- | ---- | ---- |
| `--from` | yes | yes | The config to move entries out of |
| `--provisioner` | yes | yes | The bundle ID of the build that made them |

### `workroom delete-project`

Remove a project (internal; used by the macOS app via --json). The app runs it for: Removing a project.

Runs on a Mac only.

```text
workroom delete-project [PATH]
```

| Flag | Takes a value | Required | Usage |
| ---- | ---- | ---- | ---- |
| `--confirm` | yes |  | Required in --json mode; must match the project path |
| `--from-disk` |  |  | App-only: runs teardowns, drops config, returns trash_paths; the caller (macOS app) moves those dirs to the Trash |
| `--skip-teardown` |  |  | With --with-workrooms or --from-disk: run no workroom's teardown script (after one failed) |
| `--with-workrooms` |  |  | Also tear down every workroom (worktree dirs + files; branches kept) |

### `workroom host`

Set or clear a project's or workroom's host descriptor (used by the desktop app). The app runs it for: Storing or clearing a project's or a remote workroom's host descriptor.

Runs on a Mac only.

```text
workroom host
```

#### `workroom host clear`

Remove the host descriptor.

```text
workroom host clear
```

| Flag | Takes a value | Required | Usage |
| ---- | ---- | ---- | ---- |
| `--project` | yes |  | Project directory (defaults to the current directory) |
| `--workroom` | yes |  | The project's workroom; omitted, the project's own descriptor |

#### `workroom host set`

Store DESCRIPTOR, a JSON object, as the host descriptor.

```text
workroom host set DESCRIPTOR
```

| Flag | Takes a value | Required | Usage |
| ---- | ---- | ---- | ---- |
| `--project` | yes |  | Project directory (defaults to the current directory) |
| `--workroom` | yes |  | The project's workroom; omitted, the project's own descriptor |

### `workroom include-archive`

Write the project's included files to a tar (used by the desktop app). The app runs it for: Creating a remote workroom: the project's `.worktreeinclude` files, packed to copy over.

Runs on a Mac only.

```text
workroom include-archive
```

| Flag | Takes a value | Required | Usage |
| ---- | ---- | ---- | ---- |
| `--output` | yes | yes | The file to write the tar to |
| `--project` | yes |  | Project directory (defaults to the current directory) |

### `workroom skill`

Install or remove the Workroom skill for Claude Code and Codex (used by the desktop app). The app runs it for: Settings ▸ AI Agents, and each host's bootstrap, to install or remove the Workroom skill.

```text
workroom skill install|remove
```

#### `workroom skill install`

Install the skill in Claude Code's and Codex's skill folders, where each is set up.

```text
workroom skill install
```

| Flag | Takes a value | Required | Usage |
| ---- | ---- | ---- | ---- |
| `--login-environment` |  |  | Read CLAUDE_CONFIG_DIR and CODEX_HOME from the login shell's environment |

#### `workroom skill remove`

Remove the skill Workroom installed, keeping anything else.

```text
workroom skill remove
```

| Flag | Takes a value | Required | Usage |
| ---- | ---- | ---- | ---- |
| `--login-environment` |  |  | Read CLAUDE_CONFIG_DIR and CODEX_HOME from the login shell's environment |

## Hidden flags

Flags of public commands that `--help` doesn't list, because the app passes them.

| Command | Flag | Takes a value | Usage |
| ------- | ---- | ---- | ----- |
| `workroom create` | `--host` | yes | Record a remote workroom with this host descriptor, a JSON object (used by the desktop app) |
| `workroom create` | `--host-parent` | yes | The absolute parent folder on the host; the generated name supplies the workroom's folder (with --host) |
| `workroom create` | `--host-path` | yes | The remote workroom's path on its host (with --host) |
| `workroom create` | `--start-commit` | yes | Start from this commit, the start_commit a refused create reported, without fetching (used by the desktop app) |
| `workroom trust` | `--stdin` | yes | Judge this script's contents, read from stdin, in place of the project's file (used by the desktop app) |
| `workroom trust` | `--base` | yes | Judge the setup script at this branch, on origin unless it names a remote ("" is origin's default), in place of the project's base (used by the desktop app) |
| `workroom trust` | `--devcontainer` |  | Judge the devcontainer.json a container create from --base would use too (used by the desktop app) |
| `workroom trust status` | `--stdin` | yes | Judge this script's contents, read from stdin, in place of the project's file (used by the desktop app) |
| `workroom trust status` | `--base` | yes | Judge the setup script at this branch, on origin unless it names a remote ("" is origin's default), in place of the project's base (used by the desktop app) |
| `workroom trust status` | `--devcontainer` |  | Judge the devcontainer.json a container create from --base would use too (used by the desktop app) |
