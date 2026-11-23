//! `workroom help agents` (#697): the terminal API (ADR 0079) explained to a coding agent in plain
//! words, as Markdown, which is also the body of the Workroom skill the app installs for Claude
//! Code and Codex (`skill`).
//!
//! It can't drift from the commands. Each terminal API command has its own section here
//! ([`GUIDED`]), and a section's usage line, summary, subcommands and flags are read from
//! `COMMANDS`, so a flag added to a command is in its section at once. The exit codes and kinds
//! are read from the kind registry, each with a meaning here ([`KINDS`]). Tests fail when any
//! command in the table, hidden and Mac-only ones too, is neither guided nor named in
//! `NOT_TERMINAL_API`, and when any kind in the registry is neither explained nor named in
//! `NOT_TERMINAL_API_KINDS`.

use super::kind::Kind;
use super::{Command, Flag};

/// One terminal API command's section: the command, and when and how to use it.
pub(super) struct Guided {
    pub(super) command: &'static str,
    pub(super) says: &'static str,
}

/// Every command that is not the terminal API's, so `help agents` leaves it out, by name, hidden
/// and Mac-only ones included: the workroom lifecycle, the app's own commands, and the CLI's.
#[cfg(test)]
pub(super) const NOT_TERMINAL_API: &[&str] = &[
    "add-project",
    "base",
    "claim-provisioned",
    "completion",
    "create",
    "delete",
    "delete-project",
    "help",
    "host",
    "include-archive",
    "list",
    "skill",
    "trust",
    "untrust",
    "update",
    "version",
];

/// Every kind in the registry no terminal API command ends with, by name: the workroom
/// lifecycle's and the CLI's own.
#[cfg(test)]
pub(super) const NOT_TERMINAL_API_KINDS: &[Kind] = &[
    Kind::InWorkroom,
    Kind::UnsupportedVcs,
    Kind::InvalidName,
    Kind::DirExists,
    Kind::WorkspaceExists,
    Kind::WorkspaceNotFound,
    Kind::ConfirmationMismatch,
    Kind::UnsafeDeletePath,
    Kind::Cancelled,
    Kind::SetupScriptFailed,
    Kind::TeardownScriptFailed,
    Kind::ConfigReadFailed,
    Kind::ConfigWriteFailed,
    Kind::VcsCommandFailed,
    Kind::RemoteProjectUnsupported,
    Kind::RemoteWorkroomUnsupported,
    Kind::ProjectNotFound,
    Kind::WorkroomNotFound,
    Kind::InvalidHostDescriptor,
    Kind::WorkroomExists,
    Kind::BaseBranchNotFound,
    Kind::ScriptNotTrusted,
    Kind::LocalWorkLeftOut,
    Kind::StartCommitUnusable,
    Kind::CloneFailed,
    Kind::DestinationNotEmpty,
    Kind::MacOnly,
    Kind::ManagedInstall,
    // Its rule is in the introduction's: never approve or delete for the user.
    Kind::NeedsTheUser,
];

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
(pane, app or cli), `hostname`, `attached_at_ms`, `size`, `owns_size` and `keepalive`.\n\
\n\
A session's `label` is its tab's name, one name on every Mac: the name the user gave the tab, or \
`new --title`'s. Label a session with `workroom api call session.label '{\"target\": \"TARGET\", \
\"label\": \"tests\"}'`, and clear it with `\"label\": null`: every Mac showing it renames its tab \
at once, and a cleared one shows its default name again. Control and format characters (escapes, \
line breaks, bidi and zero-width characters) are stripped, and it is cut to 256 bytes; the \
reply's `changed` says whether it was new. Labelling your own pane is allowed. A label is a \
target, ahead of the live title, so label the terminals you open to name them again later.",
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
starts; on an agent that is already working, that is the turn under way, so the wait ends with \
it. `current` is the turn under way. It prints `status: <state>`, the state the turn ended in.\n\
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
nothing in them runs a line at a time. Use it to answer a program's own question, to press a key \
(`--key Ctrl+C` to interrupt, `--key Escape`, `--key Up`), or to type into something that is not \
a shell. Never use it to answer another coding agent's permission prompt or question (its \
`coding_agent.state` is `blocked`): that is the user's to answer. To run a shell command use \
`command`, and to give a coding agent a prompt use `prompt`: \
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
paste, then Enter, in one step. Text the user already left in the agent's input box, a draft, is \
submitted with it, your text after the draft: `capture` first if that matters. With `--wait` it \
returns once the turn the prompt started has \
ended, printing `status: <state>` (done, blocked, idle or error); give it a `--timeout`. It \
refuses rather than interrupt: `NotAnAgent` (3) when no coding agent runs there (and with \
`--wait`, for an agent that has never reported a status), `AgentBusy` (3) while the agent is \
working or blocked on a question, or not ready for a prompt. When the agent started working \
between the paste and the Enter, `AgentBusy` says `error.details.typed: true, submitted: false`: \
the text is in its input box, not submitted. A prompt is never typed twice. An agent that is \
`blocked` is asking the user something, often permission to run a command: never press Enter or \
type an answer into it on the user's behalf. Tell the user what it asks, and wait (`wait TARGET \
--status working`, or `--turn current`) until they have answered.",
    },
    Guided {
        command: "events",
        says: "Streams what happens to the sessions, one JSON object per line, until stopped: first \
a `session` event for each session as it is, then `snapshot-complete`, then live events: \
`session.created`, `session.ended`, `session.program_status`, `session.run_state`, \
`session.moved`, `client.attached`, `client.detached`, `session.input` (someone typed into a \
session; `sender` is who) and `session.labelled` (its tab was renamed, or `session.label` set \
it; `label` null when cleared). Every event has `event`, `boot` and `revision`. By default your \
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
additions. Every method, event and error, with an example of each method, is in the reference at \
https://codaset.dev/workroom/docs/reference/terminal-api.",
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
        "The daemon is older than this `workroom`. Run `\"$WORKROOM_DAEMON.bin/path/workroom\"`, the \
         one that matches it; if that says so too, the daemon needs updating, which updating \
         the app does.",
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
`workroom` is missing or says `DaemonTooOld`, run `\"$WORKROOM_DAEMON.bin/path/workroom\"`, that \
same `workroom`, which works even where a startup file unset `WORKROOM_BIN_DIR`.

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
wait TARGET --turn current`. Use `send` for keys, and to answer a program's own question.
- **Never answer for the user.** A coding agent whose `coding_agent.state` is `blocked` is \
asking the user something, often permission to run a command. Don't press Enter or type into it \
on the user's behalf: report what it asks, and wait for the user.
- **Never approve or delete for the user.** Approving a project's setup and teardown scripts \
(`workroom trust`) and deleting a workroom or project (`workroom delete`, `delete-project`) are \
the user's to do. Run by a coding agent, each is refused with `NeedsTheUser` (exit 3) and changes \
nothing, whatever its flags, even in a terminal you hold; so is a `workroom create` that would \
run a setup script nobody has approved. `workroom delete --pretend` and `delete-project \
--pretend` run, and show what a delete would remove. When a create stops on an unapproved \
script, or a workroom should go, tell the user and ask them to do it in the Workroom app, or to \
run the command themselves in their own terminal; `create --skip-setup` creates without the script. Don't get around it, such as by \
typing the command into another terminal with `send`, or through tmux or `ssh localhost`: the \
refusal stops a mistake, not a determined agent, so it is yours to respect.
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

Name a terminal, its tab on every Mac, so you can target it by that name later:

```sh
workroom api call session.label '{\"target\": \"TARGET\", \"label\": \"tests\"}'
workroom command tests --timeout 10m -- npm test
```

A coding agent in another terminal is blocked on a question, such as permission to run a \
command: read what it asks, tell the user, and wait for them to answer it. Never answer it \
yourself:

```sh
workroom capture TARGET
workroom wait TARGET --status working --timeout 30m
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
        for sub in &subcommands {
            text += &format!("- `workroom {}`: {}.\n", sub.usage, sub.short);
        }
    }
    text += &flag_list("Flags", command.flags);
    for sub in subcommands {
        text += &flag_list(&format!("`workroom {}` flags", sub.usage), sub.flags);
    }
    text
}

/// A command's shown flags as a list under `heading`; nothing when it has none.
fn flag_list(heading: &str, flags: &[Flag]) -> String {
    let flags: Vec<&Flag> = flags.iter().filter(|flag| !flag.hidden).collect();
    if flags.is_empty() {
        return String::new();
    }
    let mut text = format!("\n{heading}:\n\n");
    for flag in flags {
        let value = if flag.takes_value { " VALUE" } else { "" };
        let default = if flag.default.is_empty() {
            String::new()
        } else {
            format!(" (default {})", flag.default)
        };
        text += &format!("- `--{}{value}`: {}{default}.\n", flag.name, flag.usage);
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The test that keeps `help agents` complete: every command in the table, hidden and Mac-only
    /// ones too, is either guided or named as not the terminal API's, never both, and every name
    /// in either list is a command. A guided command is shown and runs anywhere.
    #[test]
    fn help_agents_guides_every_terminal_api_command() {
        for command in super::super::COMMANDS {
            let guided = GUIDED.iter().any(|guided| guided.command == command.name);
            let excluded = NOT_TERMINAL_API.contains(&command.name);
            assert!(
                guided != excluded,
                "`workroom {}` must be in exactly one of `agents::GUIDED` (the terminal API's, \
                 which `help agents` explains) and `NOT_TERMINAL_API`",
                command.name
            );
            if guided {
                assert!(!command.hidden && !command.mac_only, "{}", command.name);
            }
        }
        for name in GUIDED
            .iter()
            .map(|guided| guided.command)
            .chain(NOT_TERMINAL_API.iter().copied())
        {
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
                for flag in sub.flags.iter().filter(|flag| !flag.hidden) {
                    assert!(
                        own.contains(&format!("- `--{}", flag.name)),
                        "`workroom {}`'s section lacks --{}",
                        sub.usage,
                        flag.name
                    );
                }
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

    /// Every kind in the registry, wherever it sits there, is explained with its exit code or
    /// named as no terminal API command's, never both, and no kind is listed twice.
    #[test]
    fn help_agents_explains_every_terminal_api_kind() {
        let text = text();
        for kind in super::super::kind::ALL.iter().copied() {
            let explained = KINDS.iter().any(|(listed, _)| *listed == kind);
            let excluded = NOT_TERMINAL_API_KINDS.contains(&kind);
            assert!(
                explained != excluded,
                "`{}` must be in exactly one of `agents::KINDS` and `NOT_TERMINAL_API_KINDS`",
                kind.code()
            );
            if explained {
                let line = format!("- `{}` ({}): ", kind.code(), kind.exit_code());
                assert!(text.contains(&line), "{line}");
            }
        }
        for (kind, _) in KINDS {
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
            "Never answer for the user",
            // #793: the commands only a person may run, and what to do instead.
            "Never approve or delete for the user",
            "`NeedsTheUser` (exit 3)",
            "in the Workroom app",
            "in their own terminal",
            "a draft",
            "WORKROOM_DAEMON.bin/path/workroom",
            // Labels (#694): setting, clearing, the event, and that a label is a target.
            "session.label",
            "\"label\": null",
            "session.labelled",
            "A label is a target",
        ] {
            assert!(text.contains(said), "{said}");
        }
        // Nothing teaches pressing Enter at another agent's question on the user's behalf.
        assert!(!text.contains("send TARGET --key Enter"), "{text}");
    }
}
