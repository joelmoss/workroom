//! The command that resumes a Claude Code conversation, from Claude's own arguments (#828,
//! ADR 0082): `claude --resume <id>` and the flags Claude was started with that shape the session.
//!
//! **The flags.** Each flag below is from the official Claude Code CLI reference,
//! <https://code.claude.com/docs/en/cli-reference> (read 2026-11-27), with the number of words it
//! takes as that page describes it. Claude Code reads its arguments with commander, so a flag that
//! takes a list (`--add-dir ../apps ../lib`) takes every word after it up to the next one that
//! starts with `-`, a flag whose value is optional (`--resume`) takes the next word unless it
//! starts with `-`, and a `--flag=value` word is that flag with its one value. Every other word is
//! a prompt, which the resumed conversation doesn't need again.
//!
//! - **Kept**, with their values: the flags that shape the session.
//! - **Dropped**, with their values: `--continue`, `--resume` and `--fork-session`, which the new
//!   `--resume <id>` stands for; `--session-id`, which would name another conversation; `--name`,
//!   which the conversation keeps; and `--debug` and `--debug-file`, which are diagnostics.
//!   Anything after `--`, which is a prompt.
//! - **No command at all**: a flag that makes Claude not an interactive conversation in this
//!   terminal (`-p`, `--bg`, `--cloud`, `--worktree` and the like, `NOT_RESUMED`), and any flag the
//!   reference doesn't list or whose words it leaves unclear (`--tools`, `--betas`, `--channels`,
//!   `--remote-control`'s optional name), since a word taken the wrong way would resume with a
//!   prompt as a flag's value or lose a flag's value as a prompt.

use std::path::Path;

use crate::terminal::process;

/// How many words after it a flag takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Takes {
    /// None.
    Nothing,
    /// Exactly one, which may start with `-`, as commander takes a required value.
    One,
    /// Every word up to the next that starts with `-`; at least one.
    List,
    /// The next word, unless it starts with `-`.
    Maybe,
}

/// What becomes of a flag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Fate {
    Kept,
    Dropped,
}

/// The flags the reference lists that a resumed session keeps or drops, by every name it gives
/// them.
const FLAGS: &[(&[&str], Takes, Fate)] = &[
    // Kept: the model, effort and advisor.
    (&["--model"], Takes::One, Fate::Kept),
    (&["--effort"], Takes::One, Fate::Kept),
    (&["--fallback-model"], Takes::One, Fate::Kept),
    (&["--advisor"], Takes::One, Fate::Kept),
    // Kept: permissions and the directories and tools they cover.
    (&["--permission-mode"], Takes::One, Fate::Kept),
    (
        &["--dangerously-skip-permissions"],
        Takes::Nothing,
        Fate::Kept,
    ),
    (
        &["--allow-dangerously-skip-permissions"],
        Takes::Nothing,
        Fate::Kept,
    ),
    (&["--add-dir"], Takes::List, Fate::Kept),
    (
        &["--allowedTools", "--allowed-tools"],
        Takes::List,
        Fate::Kept,
    ),
    (
        &["--disallowedTools", "--disallowed-tools"],
        Takes::List,
        Fate::Kept,
    ),
    // Kept: settings, agents, plugins and MCP servers.
    (&["--settings"], Takes::One, Fate::Kept),
    (&["--setting-sources"], Takes::One, Fate::Kept),
    (&["--agent"], Takes::One, Fate::Kept),
    (&["--agents"], Takes::One, Fate::Kept),
    (&["--teammate-mode"], Takes::One, Fate::Kept),
    (&["--plugin-dir"], Takes::One, Fate::Kept),
    (&["--plugin-url"], Takes::One, Fate::Kept),
    (&["--mcp-config"], Takes::List, Fate::Kept),
    (&["--strict-mcp-config"], Takes::Nothing, Fate::Kept),
    (&["--disable-slash-commands"], Takes::Nothing, Fate::Kept),
    // Kept: the system prompt (recorded on the conversation, so given again as it was).
    (&["--system-prompt"], Takes::One, Fate::Kept),
    (&["--system-prompt-file"], Takes::One, Fate::Kept),
    (&["--append-system-prompt"], Takes::One, Fate::Kept),
    (&["--append-system-prompt-file"], Takes::One, Fate::Kept),
    (&["--system-prompt-snapshot"], Takes::One, Fate::Kept),
    (&["--autocompact"], Takes::One, Fate::Kept),
    // Kept: how the session shows and what it connects to.
    (&["--verbose"], Takes::Nothing, Fate::Kept),
    (&["--ax-screen-reader"], Takes::Nothing, Fate::Kept),
    (&["--ide"], Takes::Nothing, Fate::Kept),
    (&["--chrome"], Takes::Nothing, Fate::Kept),
    (&["--no-chrome"], Takes::Nothing, Fate::Kept),
    // Dropped: what the new `--resume <id>` stands for, or would contradict.
    (&["--continue", "-c"], Takes::Nothing, Fate::Dropped),
    (&["--resume", "-r"], Takes::Maybe, Fate::Dropped),
    (&["--fork-session"], Takes::Nothing, Fate::Dropped),
    (&["--session-id"], Takes::One, Fate::Dropped),
    (&["--name", "-n"], Takes::One, Fate::Dropped),
    // Dropped: diagnostics. `--debug`'s filter binds only in its `=` form.
    (&["--debug"], Takes::Nothing, Fate::Dropped),
    (&["--debug-file"], Takes::One, Fate::Dropped),
];

/// Flags with which Claude is not an interactive conversation in this terminal, to carry on here:
/// it prints and exits, runs elsewhere, starts in a worktree of its own, or only sets up.
const NOT_RESUMED: &[&str] = &[
    "-p",
    "--print",
    "--bg",
    "--background",
    "--exec",
    "--cloud",
    "--remote",
    "--teleport",
    "--desktop",
    "--from-pr",
    "-w",
    "--worktree",
    "--tmux",
    "--init-only",
    "--init",
    "--maintenance",
    "-v",
    "--version",
    "-h",
    "--help",
];

/// Whether commander reads `word` as an option rather than a value.
fn is_option(word: &str) -> bool {
    word.len() > 1 && word.starts_with('-')
}

/// The flags that shape the session among Claude's arguments (`args`, those after the program),
/// as they were given; `None` when one of them means there is no conversation to resume here, or
/// is one this doesn't know (module doc).
pub(super) fn kept_flags(args: &[String]) -> Option<Vec<String>> {
    let mut kept = Vec::new();
    let mut words = args.iter().peekable();
    while let Some(word) = words.next() {
        if word == "--" {
            break;
        }
        if !is_option(word) {
            // A prompt.
            continue;
        }
        // `--flag=value`, or a short flag with its value attached (`-nfeature`), as commander
        // reads them.
        let (name, attached) = if word.starts_with("--") {
            match word.split_once('=') {
                Some((name, value)) => (name, Some(value)),
                None => (word.as_str(), None),
            }
        } else {
            match word.split_at_checked(2) {
                Some((name, value)) if !value.is_empty() => (name, Some(value)),
                _ => (word.as_str(), None),
            }
        };
        if NOT_RESUMED.contains(&name) {
            return None;
        }
        let &(_, takes, fate) = FLAGS.iter().find(|(names, ..)| names.contains(&name))?;
        // A value only where the flag takes one: not `--verbose=yes`, nor several short flags in
        // one word (`-cp`). `--debug`'s filter is the one value a flag takes only in this form.
        // An attached value is the flag's only one, even for a list: the words after it are
        // prompts, as commander reads them.
        if attached.is_some() && takes == Takes::Nothing && name != "--debug" {
            return None;
        }
        let mut taken = vec![word.clone()];
        if attached.is_none() {
            match takes {
                Takes::Nothing => {}
                Takes::One => taken.push(words.next()?.clone()),
                Takes::List => {
                    let first = words.next_if(|next| !is_option(next))?;
                    taken.push(first.clone());
                    while let Some(next) = words.next_if(|next| !is_option(next)) {
                        taken.push(next.clone());
                    }
                }
                Takes::Maybe => {
                    if let Some(next) = words.next_if(|next| !is_option(next)) {
                        taken.push(next.clone());
                    }
                }
            }
        }
        if fate == Fate::Kept {
            kept.extend(taken);
        }
    }
    Some(kept)
}

/// Folders that only Claude Code's own program is in: the native install's versions, and the npm
/// package and the Agent SDK's copy of it (as `needs_the_user::AGENT_FOLDERS` finds Claude).
const CLAUDE_FOLDERS: &[&str] = &[
    "/claude/versions/",
    "/@anthropic-ai/claude-code/",
    "/@anthropic-ai/claude-agent-sdk/",
];

fn is_claude(word: &str) -> bool {
    Path::new(word)
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name == "claude")
        || CLAUDE_FOLDERS.iter().any(|folder| word.contains(folder))
}

fn is_interpreter(word: &str) -> bool {
    Path::new(word)
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(process::is_interpreter)
}

/// What a process is, to the report.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Found<'a> {
    /// Claude Code, with its own arguments (those after its program), whole.
    Claude(&'a [String]),
    /// Claude Code, as its argv or its executable says, but with arguments that can't be shown
    /// to be the ones it was started with, so it gets no report: a resume without the flags it
    /// ran with (its model, its permissions) would be worse than none.
    Unproven,
    /// Some other process.
    Other,
}

/// What the process whose argv reads `argv` (`process::exact_arguments`, empty words kept) and
/// whose executable is `executable` is. Claude Code is its program named `claude` (or in one of
/// Claude's own folders), alone or as an interpreter's script (`process::program_index`, with
/// `is_file` telling a script from a word), or an executable in Claude's folders.
///
/// Its arguments count as whole only when nothing can have written over them. A runtime that
/// sets its title over argv (node's `process.title`, as an npm install's `cli.js` runs) leaves the
/// title as `argv[0]` and empties every word after it on macOS; on Linux `cmdline` then reads the
/// title alone. So: no word may be empty; the executable must be known; when it is an interpreter
/// (`node`, `bun`, `deno`), argv must say so too and name Claude's script; when it isn't, argv
/// must name Claude itself, not an interpreter.
pub(super) fn claude_arguments<'a>(
    argv: &'a [String],
    executable: Option<&str>,
    is_file: &dyn Fn(&str) -> bool,
) -> Found<'a> {
    let Some(first) = argv.first() else {
        return Found::Other;
    };
    let script = process::program_index(argv, is_file).filter(|index| *index > 0);
    let named = is_claude(first) || script.is_some_and(|index| is_claude(&argv[index]));
    if !named && !executable.is_some_and(is_claude) {
        return Found::Other;
    }
    if argv.iter().any(String::is_empty) {
        return Found::Unproven;
    }
    let Some(executable) = executable else {
        return Found::Unproven;
    };
    if is_interpreter(executable) {
        match script {
            Some(index) if is_interpreter(first) && is_claude(&argv[index]) => {
                Found::Claude(&argv[index + 1..])
            }
            _ => Found::Unproven,
        }
    } else if is_claude(first) && !is_interpreter(first) {
        Found::Claude(&argv[1..])
    } else {
        Found::Unproven
    }
}

/// Whether `id` is a conversation id as Claude gives one (a UUID): letters, digits, `-` and `_`.
fn is_conversation_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

/// The command that carries on conversation `id` from Claude's arguments `args`: `claude --resume
/// <id>` and the kept flags, after `env CLAUDE_CONFIG_DIR=<profile>` for a Claude profile other
/// than the default, since a report carries no environment. `None` when there is none to give
/// (`kept_flags`), or `id` is no conversation's.
pub(super) fn resume_command(
    args: &[String],
    id: &str,
    profile: Option<&str>,
) -> Option<Vec<String>> {
    if !is_conversation_id(id) {
        return None;
    }
    let kept = kept_flags(args)?;
    let mut command = Vec::new();
    if let Some(profile) = profile.filter(|profile| !profile.is_empty()) {
        command.push("env".to_string());
        command.push(format!("CLAUDE_CONFIG_DIR={profile}"));
    }
    command.extend(["claude".to_string(), "--resume".to_string(), id.to_string()]);
    command.extend(kept);
    Some(command)
}
