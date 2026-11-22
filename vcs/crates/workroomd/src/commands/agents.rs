//! `workroom help agents` (#697): the terminal API (ADR 0079) explained to a coding agent in plain
//! words, as Markdown, which is also the body of the Workroom skill the app installs for Claude
//! Code and Codex (`agent_skill`).
//!
//! It can't drift from the commands. Each terminal API command has its own section here
//! ([`GUIDED`]), and a section's usage line, summary, subcommands and flags are read from
//! `COMMANDS`, so a flag added to a command is in its section at once. The exit codes and kinds
//! are read from the kind registry, each with a meaning here ([`KINDS`]). Tests fail when a public
//! command is neither guided nor named in `NOT_TERMINAL_API`, and when a terminal API kind has
//! no meaning.

use super::kind::Kind;
use super::{Command, Flag};

/// One terminal API command's section: the command, and when and how to use it.
pub(super) struct Guided {
    pub(super) command: &'static str,
    pub(super) says: &'static str,
}

/// The public commands that are not the terminal API's, so `help agents` leaves them out: the
/// lifecycle commands and the CLI's own. A Mac-only command never is, so isn't listed.
#[cfg(test)]
pub(super) const NOT_TERMINAL_API: &[&str] = &["completion", "help", "update", "version"];

/// The terminal API's commands, in the order an agent meets them.
pub(super) const GUIDED: &[Guided] = &[
    Guided {
        command: "sessions",
        says: "Start here. It lists the terminals in your pane's workroom, one row each, or with \
`--json` a `sessions` array: each session's `id`, `label` (its tab's name), `title` (what its \
program last set), `scope` (the workroom it belongs to), `run` (whether it is a run tab), `cwd` \
and `coding_agent` (the program status a coding agent last reported: `state` idle, working, done, \
blocked or error, `app`, `message` and `waiting_on_user`), and `caller`, the id of the pane the \
daemon took you for. `workroom sessions TARGET` shows the one session a target names, so you can \
check a target before you act on it. `--clients` adds who is attached to each session: `kind` \
(pane, app or cli), `hostname`, `attached_at_ms`, `size`, `owns_size` and `keepalive`.",
    },
    Guided {
        command: "capture",
        says: "Reads a session's screen as plain text, as it shows now: what to look at before \
you type, and after a command whose output you need. `--lines N` adds N rows of history above the \
screen, `--all` streams the whole scrollback (one envelope per chunk with `--json`, each with \
`chunk` and `more`), `--unwrap` joins lines the pane wrapped and `--vt` keeps escape codes. Every \
reply has `cursor`, `size`, `alternate_screen` (a full-screen program is up) and the live `title`. \
A capture never types anything, and works under a full-screen program too.",
    },
    Guided {
        command: "wait",
        says: "Waits on the daemon for one thing to happen in a session, so you never poll. Give \
exactly one condition, and always a `--timeout` (past it, `WaitTimeout`, exit 8):\n\
\n\
- `--status STATE`: the coding agent's program status is that state. Already true answers at \
once.\n\
- `--turn next|current`: a coding agent's turn ends. `next` is the turn a `working` from now on \
starts, `current` the one under way. It prints `status: <state>`, the state the turn ended in.\n\
- `--run STATE`: a run tab's command is starting, running, stopping, stopped or exited. With \
`--run exited --exit-code N` it answers when the run exits and is `ExitCodeMismatch` (exit 3) \
when it exited with another code; `error.details.exit_code` has the code.\n\
- `--regex RE`: output matching RE, counting only output printed from now on (escape codes \
stripped; `^` and `$` are line anchors). `--include-screen` also matches what is on the screen \
now. It prints the match.\n\
- `--ended`: the session ends.\n\
- `--command-finished`: the next command the shell ends, running now or started later. It needs \
shell integration (`NoShellIntegration` without).\n\
\n\
A state is checked at once; output and a command's end are events, so only those after the wait \
starts count. Start the wait before you cause what it waits for, or use `command` or \
`prompt --wait`, which pair the two for you.",
    },
    Guided {
        command: "send",
        says: "Types into a session as if someone typed it, without attaching: TEXT (or `--stdin`, \
taken exactly as it comes), then each `--key` in order, then Enter with `--enter`. Text goes as \
a bracketed paste when the program has turned that on, so several lines arrive as one paste and \
nothing in them runs a line at a time. Use it to answer a program's question, to press a key \
(`--key Ctrl+C` to interrupt, `--key Escape`, `--key Up`), or to type into something that is not \
a shell. To run a shell command use `command`, and to give a coding agent a prompt use `prompt`: \
`send` doesn't wait, and can't tell you what happened. At most 1 MiB in one call (`TooLarge`, \
exit 2). A send that stopped part way says how many bytes went; what was typed can't be taken \
back.",
    },
    Guided {
        command: "command",
        says: "Runs one shell command in a session's shell and exits with its exit code, printing \
what it printed, as the pane shows it (`--vt`: as printed, escape codes and all). The words after \
`--` are joined with spaces into one line, which the session's shell reads, so quote for that \
shell; join several commands with `;` or `&&`. It needs the shell's integration marks to see the \
command end: a session without them is `NoShellIntegration` (exit 3) and nothing is typed. A \
shell that is busy with a command, or has text already at its prompt, is `Busy` (3), nothing \
typed: retry once it is free, or use `capture` to see why. A full-screen program up, or one the \
command opens, is `AlternateScreen` (3), the program left running. `--timeout` is `WaitTimeout` \
(8) and leaves the command running in the pane. The last 1 MiB of output is kept; `truncated` \
says when it was cut. A command can exit with any code, including workroom's own, so read the \
result with `--json`: `ok: true` with `exit_code` is the command's, `ok: false` with `error.kind` \
is workroom's.",
    },
    Guided {
        command: "prompt",
        says: "Gives the coding agent (Claude Code or Codex) in a session a prompt: the text as a \
paste, then Enter, in one step. With `--wait` it returns once the turn the prompt started has \
ended, printing `status: <state>` (done, blocked, idle or error); give it a `--timeout`. It \
refuses rather than interrupt: `NotAnAgent` (3) when no coding agent runs there (and with \
`--wait`, for an agent that has never reported a status), `AgentBusy` (3) while the agent is \
working or blocked on a question, or not ready for a prompt. When the agent started working \
between the paste and the Enter, `AgentBusy` says `error.details.typed: true, submitted: false`: \
the text is in its input box, not submitted. Use `send` to answer a blocked agent's question, \
after `capture` shows you what it asks. A prompt is never typed twice.",
    },
    Guided {
        command: "events",
        says: "Streams what happens to the sessions, one JSON object per line, until stopped: first \
a `session` event for each session as it is, then `snapshot-complete`, then live events: \
`session.created`, `session.ended`, `session.program_status`, `session.run_state`, \
`session.moved`, `client.attached`, `client.detached` and `session.input` (someone typed into a \
session; `sender` is who). Every event has `event`, `boot` and `revision`. By default your \
workroom's sessions; `--all` for every session, `--workroom ID` for one workroom, `--session \
TARGET` for one session, `--type` for some event types only. A `snapshot-complete` with `reason` \
`gap` or `lagged` replaced what you knew: start from it again. Ignore event types you don't know. \
To wait for one thing, `wait` is simpler.",
    },
    Guided {
        command: "new",
        says: "Opens a new terminal beside yours, as a tab, or as a split with `--split right` or \
`--split down`, and prints its id (with `--json`, the new `session`). It starts as your pane was \
made, with your pane's PATH and shell integration, in this command's folder or `--cwd`. `--title` \
names it. `--run CMD` makes it a run tab: the command runs under a supervisor, so `run-control` \
restarts and stops it and `wait --run` waits on it. Follow it with `command` or `wait` on the id \
it printed. A `--cwd` that is no folder is `NotADirectory` (3).",
    },
    Guided {
        command: "close",
        says: "Closes a session: its shell ends, and its tab or split closes in the app. It can't \
be undone, so its TARGET is a session's id, the end of its id or its label, never its live \
title. Close only what you opened, or what you were asked to close. A session that already \
ended is `SessionEnded` (3).",
    },
    Guided {
        command: "run-control",
        says: "Restarts or stops the command of a run tab, as its Run tab's buttons do. Follow a \
restart with `wait TARGET --run running --timeout 1m` to know it is back up. A session that is \
no run tab is `NotARun` (3).",
    },
    Guided {
        command: "api",
        says: "Raw access to every terminal API method on the daemon, for what no command above \
covers. `api list` lists the methods, `api describe METHOD` shows the JSON Schema of its \
parameters, its result and its errors, with examples, and `api call METHOD [PARAMS]` calls it, \
PARAMS a JSON object inline, `@FILE` or `-` for stdin. A method that streams prints one reply \
per line until `more` is false. The API only ever adds fields and methods; `revision` counts the \
additions.",
    },
];

/// Every kind a terminal API command can end with, and what to do about it. The registry gives
/// each its exit code; a test checks that every terminal API kind is here.
pub(super) const KINDS: &[(Kind, &str)] = &[
    (
        Kind::TargetNotFound,
        "No session matches the target. List them with `workroom sessions --all`.",
    ),
    (
        Kind::TargetAmbiguous,
        "More than one session matches; `error.matches` lists them. Use an id.",
    ),
    (
        Kind::SessionEnded,
        "The session ended before or while it was asked.",
    ),
    (
        Kind::RefusedSelf,
        "The target is your own pane. Pass `--allow-self` only when you mean it.",
    ),
    (
        Kind::AgentBusy,
        "The coding agent is working or waiting on a question. Wait for its turn to end.",
    ),
    (Kind::NotAnAgent, "No coding agent runs in that session."),
    (Kind::NotARun, "The session is no run tab."),
    (
        Kind::AlternateScreen,
        "A full-screen program is up. `capture` it, then `send` keys to quit it.",
    ),
    (
        Kind::NoShellIntegration,
        "The shell sends no integration marks, so a command's end can't be seen.",
    ),
    (
        Kind::NotADirectory,
        "`new --cwd` names something that is not a folder.",
    ),
    (
        Kind::ExitCodeMismatch,
        "The run exited, with another code; `error.details.exit_code` has it.",
    ),
    (
        Kind::WaitInterrupted,
        "The daemon was updated mid-wait, or the output came too fast, so the event may have \
         gone by. Look with `capture`, then wait again.",
    ),
    (
        Kind::Busy,
        "The session or the daemon is busy (a command running, text at the prompt, too many \
         waits). Retry shortly.",
    ),
    (
        Kind::InvalidRequest,
        "The daemon can't read the request: an unknown method or parameters it refuses.",
    ),
    (
        Kind::TooLarge,
        "More than one request carries (1 MiB of text or parameters), or than one reply holds \
         (16 MiB, as `capture --lines` can ask; `--all` streams any length).",
    ),
    (
        Kind::DaemonUnreachable,
        "No daemon answers: outside a Workroom pane, or `WORKROOM_DAEMON` names none.",
    ),
    (
        Kind::DaemonTooOld,
        "The daemon is older than the command. Run `\"$WORKROOM_BIN_DIR/workroom\"`.",
    ),
    (
        Kind::WaitTimeout,
        "The `--timeout` passed first. What you waited on is still going.",
    ),
    (
        Kind::InternalError,
        "Anything else, a malformed command line included. Read the message.",
    ),
];

const INTRO: &str = "# Workroom's terminals, for coding agents

Workroom runs every terminal pane under a daemon, on the Mac and on remote hosts. The `workroom` \
commands below talk to that daemon's terminal API, so from inside one pane you can list the other \
terminals, read their screens, type into them, run commands in them, wait for something to happen \
in them, open and close them, and hand work to another coding agent.

Every pane's shell has three variables Workroom sets:

- `WORKROOM_PANE`: this pane's session id. Commands use it to know who is calling.
- `WORKROOM_DAEMON`: the daemon's socket. Commands reach the daemon without being told.
- `WORKROOM_BIN_DIR`: the folder of the `workroom` that matches that daemon, first on `PATH`. If \
`workroom` is missing or says `DaemonTooOld`, run `\"$WORKROOM_BIN_DIR/workroom\"` instead.

## Rules

- **Read results as JSON.** Add `--json` and a command prints one JSON object on stdout: `ok`, \
`schema_version`, `command` and the result's fields, or `ok: false` with `error.kind` and \
`error.message`. Streams (`events`, `capture --all`) print one object per line. Branch on \
`error.kind` or the exit code, never on the message, and ignore fields you don't know.
- **Look before you act.** `workroom sessions` first, then `capture` the screen you are about to \
type into.
- **Never type into your own pane.** `send`, `command`, `prompt` and `close` refuse the session \
you run in with `RefusedSelf` unless you pass `--allow-self`. Your own pane is `caller` in \
`sessions --json`.
- **Prefer the command that waits.** Run a shell command with `command`, not `send` and Enter: it \
waits for the command to end and gives you its exit code and output. Prompt a coding agent with \
`prompt --wait`, not `send`, and wait for a turn an agent already has under way with `workroom \
wait TARGET --turn current`. Use `send` for keys and answers.
- **Wait on the daemon, never poll.** `wait`, `command` and `prompt --wait` answer the moment it \
happens. Give each a `--timeout` (such as `30s`, `10m`).
- **Use ids.** Once you know a session, name it by the `id` from `sessions --json`.

## Targets

A TARGET names one session: its full id, else the end of its id (4 characters or more), else its \
label (its tab's name), else its live title (what its program last set). The first of those that \
matches anything decides: more than one match there is `TargetAmbiguous` and nothing happens. \
`close` never matches a live title.

## Scope

`sessions` and `events` keep to the sessions in your pane's workroom; `--all` widens them to \
every session the daemon runs. A target names any session, in any workroom. Run from no pane, \
every session is listed. Each daemon has its own sessions: a pane on a remote host sees that \
host's terminals, not the Mac's.

## Commands
";

const PATTERNS: &str = "## Patterns

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
workroom wait \"$id\" --regex 'ready in [0-9]+ ?ms' --include-screen --timeout 2m
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
";

/// `help agents`' text: the introduction, each guided command's section, the exit codes and
/// kinds, and the patterns.
pub(super) fn text() -> String {
    let mut text = INTRO.to_string();
    for guided in GUIDED {
        let command = super::find(guided.command)
            .unwrap_or_else(|| panic!("`help agents` guides `{}`, no command", guided.command));
        text += &section(command, guided.says);
    }
    text += &exit_codes();
    text += "\n";
    text += PATTERNS;
    text
}

/// One command's section: its usage and summary, its subcommands and its own flags, from the
/// table, then what `says` adds.
fn section(command: &Command, says: &str) -> String {
    let mut text = format!(
        "\n### `workroom {}`\n\n`workroom {}`: {}.\n\n{says}\n",
        command.name, command.usage, command.short
    );
    let subcommands: Vec<&Command> = command
        .subcommands
        .iter()
        .filter(|sub| !sub.hidden)
        .collect();
    if !subcommands.is_empty() {
        text += "\n";
        for sub in subcommands {
            text += &format!("- `workroom {}`: {}.\n", sub.usage, sub.short);
        }
    }
    let flags: Vec<&Flag> = command.flags.iter().filter(|flag| !flag.hidden).collect();
    if !flags.is_empty() {
        text += "\nFlags:\n\n";
        for flag in flags {
            let value = if flag.takes_value { " VALUE" } else { "" };
            let default = if flag.default.is_empty() {
                String::new()
            } else {
                format!(" (default {})", flag.default)
            };
            text += &format!("- `--{}{value}`: {}{default}.\n", flag.name, flag.usage);
        }
    }
    text
}

/// The exit codes, then every kind with its code and meaning.
fn exit_codes() -> String {
    let mut text = String::from(
        "\n## Exit codes and kinds

- 0: it worked. `command` exits with the command's own code instead.
- 1: an internal error, or a malformed command line.
- 2: bad input: a request the daemon can't read, or one too large.
- 3: not now, or not found: the session can't take it as it is (busy, ended, no agent, your own \
pane) or the target names no one session. Retrying later, or with another target, can work.
- 7: no daemon could be used: none answers, or it is too old.
- 8: a wait timed out.

`error.kind` says which, with `error.details` for what a kind says beside its message:

",
    );
    for (kind, meaning) in KINDS {
        text += &format!("- `{}` ({}): {meaning}\n", kind.code(), kind.exit_code());
    }
    text
}

/// The kinds a terminal API command can end with: the registry's from `TargetAmbiguous` on, which
/// the terminal API added (ADR 0079), and `NotADirectory`, which `new --cwd` reuses.
#[cfg(test)]
pub(super) fn terminal_api_kinds() -> Vec<Kind> {
    let first = super::kind::ALL
        .iter()
        .position(|kind| *kind == Kind::TargetAmbiguous)
        .expect("TargetAmbiguous is in the registry");
    std::iter::once(Kind::NotADirectory)
        .chain(super::kind::ALL[first..].iter().copied())
        .collect()
}

/// The public commands `help agents` must guide: every one shown in `--help` that runs anywhere
/// and is not in [`NOT_TERMINAL_API`].
#[cfg(test)]
pub(super) fn terminal_api_commands() -> impl Iterator<Item = &'static Command> {
    super::COMMANDS.iter().filter(|command| {
        !command.hidden && !command.mac_only && !NOT_TERMINAL_API.contains(&command.name)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The test that keeps `help agents` complete: a command added to the CLI that runs anywhere is
    /// either guided or named as not the terminal API's, and every guided name is a command.
    #[test]
    fn help_agents_guides_every_terminal_api_command() {
        for command in terminal_api_commands() {
            assert!(
                GUIDED.iter().any(|guided| guided.command == command.name),
                "`workroom {}` is a public command that `help agents` doesn't guide: add it to \
                 `agents::GUIDED`, or to `NOT_TERMINAL_API` when it isn't the terminal API's",
                command.name
            );
        }
        for guided in GUIDED {
            let command = super::super::find(guided.command)
                .unwrap_or_else(|| panic!("`{}` is guided but no command", guided.command));
            assert!(
                terminal_api_commands().any(|listed| listed.name == command.name),
                "`{}` is guided but hidden, Mac-only or listed as not the terminal API's",
                guided.command
            );
        }
        for name in NOT_TERMINAL_API {
            assert!(super::super::find(name).is_some(), "`{name}` is no command");
        }
        let mut names: Vec<&str> = GUIDED.iter().map(|guided| guided.command).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), GUIDED.len(), "a command is guided twice");
    }

    /// Each command's own section holds its usage, every subcommand and every flag it shows in
    /// `--help`, so a flag can't be missing from the section of its own command.
    #[test]
    fn each_section_holds_its_commands_usage_subcommands_and_flags() {
        let text = text();
        for guided in GUIDED {
            let command = super::super::find(guided.command).expect("command");
            let heading = format!("\n### `workroom {}`\n", command.name);
            let start = text.find(&heading).unwrap_or_else(|| panic!("{heading}"));
            let rest = &text[start + heading.len()..];
            let end = rest
                .find("\n### ")
                .or_else(|| rest.find("\n## "))
                .expect("end");
            let own = &rest[..end];
            assert!(
                own.contains(&format!("`workroom {}`", command.usage)),
                "{own}"
            );
            for sub in command.subcommands.iter().filter(|sub| !sub.hidden) {
                assert!(own.contains(&format!("`workroom {}`", sub.usage)), "{own}");
            }
            for flag in command.flags.iter().filter(|flag| !flag.hidden) {
                assert!(
                    own.contains(&format!("- `--{}", flag.name)),
                    "`workroom {}`'s section lacks --{}",
                    command.name,
                    flag.name
                );
            }
        }
    }

    /// Every kind a terminal API command can end with has a meaning, with its exit code from the
    /// registry, and no kind is listed twice.
    #[test]
    fn help_agents_explains_every_terminal_api_kind() {
        let text = text();
        for kind in terminal_api_kinds() {
            assert!(
                KINDS.iter().any(|(listed, _)| *listed == kind),
                "`{}` has no meaning in `agents::KINDS`",
                kind.code()
            );
            let line = format!("- `{}` ({}): ", kind.code(), kind.exit_code());
            assert!(text.contains(&line), "{line}");
        }
        for (kind, _) in KINDS {
            assert!(terminal_api_kinds().contains(kind), "{}", kind.code());
            assert_eq!(
                KINDS.iter().filter(|(listed, _)| listed == kind).count(),
                1,
                "{}",
                kind.code()
            );
        }
        for code in ["- 0:", "- 1:", "- 2:", "- 3:", "- 7:", "- 8:"] {
            assert!(text.contains(code), "{code}");
        }
    }

    /// The safe patterns the guide teaches are in it.
    #[test]
    fn help_agents_teaches_the_safe_patterns() {
        let text = text();
        for said in [
            "--allow-self",
            "RefusedSelf",
            "--json",
            "--turn current",
            "prompt --wait",
            "WORKROOM_PANE",
            "WORKROOM_DAEMON",
            "WORKROOM_BIN_DIR",
            "--timeout",
        ] {
            assert!(text.contains(said), "{said}");
        }
    }
}
