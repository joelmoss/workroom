//! The CLI's commands (ADR 0078): `workroom <command>` runs one and exits, as the Go CLI did,
//! in its own process and never inside the daemon. The daemon's own subcommands (`serve`, `attach`,
//! `list --socket` and the rest that ADR 0057 pins) are still `main.rs`'s, which sends only the
//! rest to [`run_cli`].
//!
//! Every command keeps ADR 0013's contract, byte for byte as Go wrote it: one envelope on stdout
//! under `--json` (`envelope`), NDJSON logs on stderr (`log`), and a stable `kind` and exit
//! code for each failure (`kind`). Human output keeps Go's information but may change wording.
//!
//! The commands that read or write the Mac's config are Mac-only: listed in `--help` everywhere,
//! marked "(Mac only)", and failing with `MacOnly` anywhere else. Each is ported (#671–#678), on
//! `config`, the Rust reader and writer of config.json: `list` and `base --global` (#671),
//! `include-archive` (#675), the rest of `base` and `host` (#673), the app's project commands,
//! `add-project`, `claim-provisioned` and `delete-project` (#672), `trust`, `trust status` and
//! `untrust` (#674), `create` (#677) and `delete` (#678). `update` is ported too (#679), which
//! runs anywhere.
//!
//! The terminal API's commands (#360, ADR 0079) are born here and run anywhere: each is a thin
//! client of the daemon's terminal API (`terminal_api`).
//!
//! Shell completion works anywhere (#700): `completion` writes cobra's scripts, and the hidden
//! `__complete` answers them from `COMMANDS`, so every command's subcommands and flags, a Mac-only
//! one's included, are offered as Go offers them.

mod add_project;
mod api;
mod base;
mod capture;
pub(crate) mod channel;
mod claim;
mod command;
mod complete;
mod completion;
mod config;
mod create;
mod delete;
mod delete_project;
mod envelope;
mod events;
mod git;
mod host;
mod include_archive;
mod kind;
mod list;
mod log;
mod namegen;
mod panel;
mod prompt;
mod send;
mod sessions;
mod start;
mod teardown;
mod terminal_api;
mod trust;
mod trusted_script;
mod update;
mod version;
mod wait;

use std::ffi::OsString;
use std::io::{IsTerminal, Write};
use std::process::ExitCode;

use kind::{CliError, Kind};

/// This binary's version: `WORKROOM_VERSION` when it was built, else `dev`, as a plain `go build`
/// of the Go CLI reports.
pub(crate) const VERSION: &str = match option_env!("WORKROOM_VERSION") {
    Some(version) if !version.is_empty() => version,
    _ => "dev",
};

/// The release channel baked in at build time from `WORKROOM_RELEASE_CHANNEL` (`nightly` for the
/// Nightly build), which `version` reports in place of the configured one; none for any other.
pub(crate) const BAKED_CHANNEL: Option<&str> = match option_env!("WORKROOM_RELEASE_CHANNEL") {
    Some(channel) if !channel.is_empty() => Some(channel),
    _ => None,
};

/// Where a command can run.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Platform {
    Mac,
    /// A remote host, which has no Mac config, `gh` or host drivers.
    Other,
}

impl Platform {
    fn current() -> Platform {
        if cfg!(target_os = "macos") {
            Platform::Mac
        } else {
            Platform::Other
        }
    }
}

/// What a command runs on, and the global flags it was given.
pub(crate) struct Context {
    json: bool,
    /// `--pretend`: go through the command without changing anything.
    pretend: bool,
    /// `--verbose`: say more about what the command does.
    verbose: bool,
    platform: Platform,
    env: fn(&str) -> Option<String>,
    /// The socket of the daemon this process runs under, found from its parents, for a caller
    /// whose environment names none (`terminal_api::daemon_above`). Never looked for in tests: a
    /// test run in a Workroom pane would find the developer's own daemon.
    daemon_above: fn() -> Option<String>,
    /// Whether human output is coloured: stdout is a terminal and neither `NO_COLOR` nor a dumb
    /// `TERM` says otherwise, as Go's colour package decides.
    color: bool,
}

impl Context {
    fn env(&self, name: &str) -> Option<String> {
        (self.env)(name)
    }
}

/// How a command ended.
pub(crate) enum Outcome {
    /// Human output for stdout, exit 0.
    Printed(String),
    /// Human output for stdout, and warnings for stderr: lines about what the command skipped on
    /// the way, which don't fail it, so exit 0.
    PrintedWithWarnings { stdout: String, warnings: String },
    /// A success envelope, exit 0.
    Success(String),
    /// A failure, reported in the error envelope under `--json`, else as an `Error:` line.
    Failed(CliError),
    /// A failure reported as [`Outcome::Failed`] is, but in the envelope of the subcommand it
    /// names, such as `api call`: one name per payload shape, as Go's `trust status` is.
    FailedIn(&'static str, CliError),
    /// A usage error the command found in its arguments: reported as a failure is, but with no
    /// command in the envelope, since Go checks arguments before the command runs.
    Usage(CliError),
    /// Human output for stdout, then a failure reported as [`Outcome::Failed`] is: Go's `update`
    /// prints its progress before it fails, `--json` or not.
    PrintedThenFailed(String, CliError),
    /// The outcome inside, reported as it is, but ending with this exit code, as Go's
    /// `exitStatus` ends `trust status`: 1 after its envelope when a script isn't approved, and
    /// 2 for any failure, whatever its kind's own code.
    Status(u8, Box<Outcome>),
}

/// One of a command's own flags, beside the global ones.
struct Flag {
    name: &'static str,
    /// Its one-letter form (`-c`), which only a boolean flag has here.
    short: Option<char>,
    /// Takes a value (`--name value` or `--name=value`), else is a boolean.
    takes_value: bool,
    usage: &'static str,
    /// The value `--help` shows as the default; "" for none.
    default: &'static str,
    /// Left out of `--help` and shell completion: flags the app passes, not people.
    hidden: bool,
    /// Must be given, as cobra's `MarkFlagRequired` makes a flag: a usage error before the command
    /// runs when it isn't (`missing_required`). Given empty, it is. Shell completion offers it
    /// first, as cobra does.
    required: bool,
}

impl Flag {
    /// A boolean flag, shown, not required, with no one-letter form or default: what a `Flag` is
    /// in everything it doesn't say.
    const BOOL: Flag = Flag {
        name: "",
        short: None,
        takes_value: false,
        usage: "",
        default: "",
        hidden: false,
        required: false,
    };

    /// A flag that takes a value, otherwise as [`Flag::BOOL`].
    const VALUE: Flag = Flag {
        takes_value: true,
        ..Flag::BOOL
    };

    /// How pflag names it, in `--help` and in an error: `-c, --check`, or `--channel`.
    fn spelled(&self) -> String {
        match self.short {
            Some(short) => format!("-{short}, --{}", self.name),
            None => format!("--{}", self.name),
        }
    }
}

/// The flags every command takes, which cobra calls the root's persistent flags. `--help` is each
/// command's own (`help for <command>` in completion).
const PERSISTENT_FLAGS: &[Flag] = &[
    Flag {
        name: "json",
        usage: "Emit machine-readable JSON (exactly one object on stdout)",
        ..Flag::BOOL
    },
    Flag {
        name: "pretend",
        short: Some('p'),
        usage: "Run through the command without making changes (dry run)",
        ..Flag::BOOL
    },
    Flag {
        name: "verbose",
        short: Some('v'),
        usage: "Print detailed and verbose output",
        ..Flag::BOOL
    },
];

/// What a command was given besides the global flags.
pub(crate) struct Args {
    /// The arguments after the command's name.
    positional: Vec<String>,
    /// Each of the command's own flags that was set, by name, with its value as given (a boolean
    /// as `true` or `false`).
    values: Vec<(&'static str, String)>,
    /// The command's own flags, for their defaults.
    flags: &'static [Flag],
}

impl Args {
    /// The value the flag `name` was last given.
    fn value(&self, name: &str) -> Option<&str> {
        self.values
            .iter()
            .rev()
            .find(|(flag, _)| *flag == name)
            .map(|(_, value)| value.as_str())
    }

    /// The value the flag `name` was last given, else the default its `Flag` names (the one
    /// `--help` shows), else "".
    fn value_or_default(&self, name: &str) -> &str {
        self.value(name).unwrap_or_else(|| {
            self.flags
                .iter()
                .find(|flag| flag.name == name)
                .map_or("", |flag| flag.default)
        })
    }

    /// Whether the boolean flag `name` is on.
    fn is_set(&self, name: &str) -> bool {
        self.value(name) == Some("true")
    }
}

/// How a command takes arguments.
#[derive(Clone, Copy)]
enum Arity {
    /// None: an extra one is a usage error, found before the command runs.
    None,
    /// Its own subcommands and arguments, which it checks itself.
    Own,
}

/// What shell completion offers for a command's arguments, beside its subcommands.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Operands {
    /// Nothing of its own, so the shell falls back to file names.
    Files,
    /// Nothing at all, not even file names.
    Nothing,
    /// The commands `help` takes as its topic.
    Commands,
}

/// One command of the CLI, or a subcommand of one.
struct Command {
    name: &'static str,
    aliases: &'static [&'static str],
    /// The usage line after `workroom `.
    usage: &'static str,
    short: &'static str,
    /// What its own `--help` says first, when it says more than `short`.
    long: Option<&'static str>,
    /// Left out of `--help` and shell completion: commands the app runs, not people.
    hidden: bool,
    mac_only: bool,
    flags: &'static [Flag],
    /// `base set|clear`, `host set|clear`, `trust status`: for `--help`, shell completion and the
    /// flags each takes. A subcommand's `implementation` and `mac_only` are its parent's, whose
    /// `run` reads the subcommand from its arguments.
    subcommands: &'static [Command],
    arity: Arity,
    operands: Operands,
    implementation: Implementation,
}

/// What runs a command: every command runs in this binary (#667).
type Implementation = fn(&Context, &Args) -> Outcome;

/// Every command, in `--help`'s order. Names, aliases and help lines are the Go CLI's.
const COMMANDS: &[Command] = &[
    Command {
        hidden: true,
        // cobra's `MaximumNArgs(1)`, which `run` checks.
        arity: Arity::Own,
        ..mac_command(
            add_project::run,
            "add-project",
            "add-project [PATH]",
            "Register a project (internal; used by the macOS app via --json)",
            &[
                Flag {
                    name: "clone",
                    usage: "Clone this repository URL into PATH, then register it",
                    ..Flag::VALUE
                },
                Flag {
                    name: "create",
                    usage: "Create and git-initialize the directory if it does not already exist",
                    ..Flag::BOOL
                },
            ],
        )
    },
    Command {
        name: "api",
        aliases: &[],
        usage: "api [command]",
        short: "List, describe and call the terminal API's methods",
        long: Some(api::LONG),
        hidden: false,
        mac_only: false,
        flags: &[],
        // A METHOD is the daemon's to name and PARAMS is JSON, so no subcommand's arguments are
        // file names.
        subcommands: &[
            Command {
                operands: Operands::Nothing,
                ..subcommand(
                    API,
                    false,
                    "call",
                    "api call METHOD [PARAMS]",
                    "Call METHOD with JSON parameters: inline, @FILE, or - for stdin",
                    &[],
                )
            },
            Command {
                operands: Operands::Nothing,
                ..subcommand(
                    API,
                    false,
                    "describe",
                    "api describe METHOD",
                    "Show METHOD's parameter and result schemas, with examples",
                    &[],
                )
            },
            Command {
                operands: Operands::Nothing,
                ..subcommand(
                    API,
                    false,
                    "list",
                    "api list",
                    "List every method the daemon has",
                    &[],
                )
            },
        ],
        // Its subcommands and their arguments, which `api::run` checks.
        arity: Arity::Own,
        operands: Operands::Nothing,
        implementation: API,
    },
    Command {
        name: "base",
        aliases: &[],
        usage: "base",
        short: "Set or clear the branch new workrooms start from",
        long: Some(
            "Set or clear the branch new workrooms start from. BRANCH is a branch on origin, such \
             as develop, or <remote>/<branch> for another remote, such as upstream/main. Workroom \
             fetches that remote and uses its copy of the branch, else the local branch. A \
             project's own base wins over the --global one. Unset, new workrooms start from \
             origin's default branch.",
        ),
        hidden: false,
        mac_only: true,
        // Go gives the flags to `set` and `clear`, not to `base` itself.
        flags: &[],
        subcommands: &[
            subcommand(
                BASE,
                true,
                "clear",
                "base clear",
                "Start new workrooms from the global base, else origin's default branch",
                BASE_FLAGS,
            ),
            subcommand(
                BASE,
                true,
                "set",
                "base set BRANCH",
                "Start new workrooms from BRANCH",
                BASE_FLAGS,
            ),
        ],
        arity: Arity::Own,
        operands: Operands::Files,
        implementation: BASE,
    },
    Command {
        name: "capture",
        aliases: &[],
        usage: "capture TARGET",
        short: "Print a terminal session's screen, or its history, as text",
        long: None,
        hidden: false,
        mac_only: false,
        flags: capture::FLAGS,
        subcommands: &[],
        // One TARGET, which `capture::run` checks.
        arity: Arity::Own,
        // A TARGET is a session the daemon knows, never a file, as `sessions`' is.
        operands: Operands::Nothing,
        implementation: capture::run,
    },
    Command {
        hidden: true,
        ..mac_command(
            claim::run,
            "claim-provisioned",
            "claim-provisioned",
            "Move the remote entries a build made from another config into this one (used by the desktop app)",
            &[
                Flag {
                    name: "from",
                    usage: "The config to move entries out of",
                    required: true,
                    ..Flag::VALUE
                },
                Flag {
                    name: "provisioner",
                    usage: "The bundle ID of the build that made them",
                    required: true,
                    ..Flag::VALUE
                },
            ],
        )
    },
    Command {
        name: "command",
        aliases: &[],
        usage: "command TARGET [flags] -- COMMAND...",
        short: "Run a shell command in a terminal session and exit with its code",
        long: None,
        hidden: false,
        mac_only: false,
        flags: command::FLAGS,
        subcommands: &[],
        // A TARGET and the COMMAND's words, which `command::run` checks.
        arity: Arity::Own,
        // A TARGET is a session the daemon knows, never a file, as for `sessions`.
        operands: Operands::Nothing,
        implementation: command::run,
    },
    Command {
        name: "completion",
        aliases: &[],
        usage: "completion [command]",
        short: "Generate the autocompletion script for the specified shell",
        long: Some(
            "Generate the autocompletion script for workroom for the specified shell.\n\
             See each sub-command's help for details on how to use the generated script.",
        ),
        hidden: false,
        mac_only: false,
        flags: &[],
        subcommands: &[
            shell(
                "bash",
                "completion bash",
                "Generate the autocompletion script for bash",
                completion::BASH_HELP,
            ),
            shell(
                "fish",
                "completion fish [flags]",
                "Generate the autocompletion script for fish",
                completion::FISH_HELP,
            ),
            shell(
                "powershell",
                "completion powershell [flags]",
                "Generate the autocompletion script for powershell",
                completion::POWERSHELL_HELP,
            ),
            shell(
                "zsh",
                "completion zsh [flags]",
                "Generate the autocompletion script for zsh",
                completion::ZSH_HELP,
            ),
        ],
        arity: Arity::Own,
        operands: Operands::Nothing,
        implementation: COMPLETION,
    },
    Command {
        aliases: &["c"],
        ..mac_command(
            create::run,
            "create",
            "create",
            "Create a new workroom",
            &[
                Flag {
                    name: "host",
                    usage: "Record a remote workroom with this host descriptor, a JSON object \
                            (used by the desktop app)",
                    hidden: true,
                    ..Flag::VALUE
                },
                Flag {
                    name: "host-parent",
                    usage: "The absolute parent folder on the host; the generated name supplies \
                            the workroom's folder (with --host)",
                    hidden: true,
                    ..Flag::VALUE
                },
                Flag {
                    name: "host-path",
                    usage: "The remote workroom's path on its host (with --host)",
                    hidden: true,
                    ..Flag::VALUE
                },
                Flag {
                    name: "no-editor",
                    usage: "Do not offer to open the new workroom in $EDITOR",
                    ..Flag::BOOL
                },
                Flag {
                    name: "project",
                    usage: "Project directory to create the workroom in (defaults to the current \
                            directory)",
                    ..Flag::VALUE
                },
                Flag {
                    name: "skip-setup",
                    usage: "Create without running the setup script, and without asking to \
                            approve it",
                    ..Flag::BOOL
                },
                Flag {
                    name: "start",
                    usage: "What to include when you have commits you haven't pushed, or changes \
                            you haven't committed: local-with-changes (both), local (your \
                            commits), origin (neither), or ask (stop with exit 3 and say what \
                            there is). A terminal asks when unset",
                    ..Flag::VALUE
                },
                Flag {
                    name: "start-commit",
                    usage: "Start from this commit, the start_commit a refused create reported, \
                            without fetching (used by the desktop app)",
                    hidden: true,
                    ..Flag::VALUE
                },
            ],
        )
    },
    Command {
        aliases: &["d"],
        long: Some(
            "Delete an existing workroom. When run without a name, shows an interactive \
             multi-select menu.",
        ),
        // cobra's `MaximumNArgs(1)`, which `run` checks.
        arity: Arity::Own,
        ..mac_command(
            delete::run,
            "delete",
            "delete [NAME]",
            "Delete an existing workroom",
            &[
                Flag {
                    name: "confirm",
                    usage: "Skip confirmation if value matches the workroom name (required in \
                            --json mode)",
                    ..Flag::VALUE
                },
                Flag {
                    name: "project",
                    usage: "Project directory the workroom belongs to (defaults to the current \
                            directory)",
                    ..Flag::VALUE
                },
                Flag {
                    name: "skip-teardown",
                    usage: "Delete without running the teardown script (after it failed)",
                    ..Flag::BOOL
                },
            ],
        )
    },
    Command {
        hidden: true,
        // cobra's `MaximumNArgs(1)`, which `run` checks.
        arity: Arity::Own,
        ..mac_command(
            delete_project::run,
            "delete-project",
            "delete-project [PATH]",
            "Remove a project (internal; used by the macOS app via --json)",
            &[
                Flag {
                    name: "confirm",
                    usage: "Required in --json mode; must match the project path",
                    ..Flag::VALUE
                },
                Flag {
                    name: "from-disk",
                    usage: "App-only: runs teardowns, drops config, returns trash_paths; the \
                            caller (macOS app) moves those dirs to the Trash",
                    ..Flag::BOOL
                },
                Flag {
                    name: "skip-teardown",
                    usage: "With --with-workrooms or --from-disk: run no workroom's teardown \
                            script (after one failed)",
                    ..Flag::BOOL
                },
                Flag {
                    name: "with-workrooms",
                    usage: "Also tear down every workroom (worktree dirs + files; branches kept)",
                    ..Flag::BOOL
                },
            ],
        )
    },
    Command {
        name: "events",
        aliases: &[],
        usage: "events",
        short: "Stream terminal sessions' events as JSON lines: a snapshot, then live changes",
        long: None,
        hidden: false,
        mac_only: false,
        flags: events::FLAGS,
        subcommands: &[],
        // No arguments, which `events::run` checks.
        arity: Arity::Own,
        // `--session` takes a session the daemon knows, never a file, as `sessions`' TARGET is.
        operands: Operands::Nothing,
        implementation: events::run,
    },
    Command {
        name: "help",
        aliases: &[],
        usage: "help [command]",
        short: "Help about any command",
        long: None,
        hidden: false,
        mac_only: false,
        flags: &[],
        subcommands: &[],
        arity: Arity::Own,
        operands: Operands::Commands,
        implementation: help_command,
    },
    Command {
        name: "host",
        aliases: &[],
        usage: "host",
        short: "Set or clear a project's or workroom's host descriptor (used by the desktop app)",
        long: None,
        hidden: true,
        mac_only: true,
        // Go gives the flags to `set` and `clear`, not to `host` itself.
        flags: &[],
        subcommands: &[
            subcommand(
                HOST,
                true,
                "clear",
                "host clear",
                "Remove the host descriptor",
                HOST_FLAGS,
            ),
            subcommand(
                HOST,
                true,
                "set",
                "host set DESCRIPTOR",
                "Store DESCRIPTOR, a JSON object, as the host descriptor",
                HOST_FLAGS,
            ),
        ],
        arity: Arity::Own,
        operands: Operands::Files,
        implementation: HOST,
    },
    Command {
        name: "include-archive",
        aliases: &[],
        usage: "include-archive",
        short: "Write the project's included files to a tar (used by the desktop app)",
        long: None,
        hidden: true,
        mac_only: true,
        flags: &[
            Flag {
                name: "output",
                usage: "The file to write the tar to",
                required: true,
                ..Flag::VALUE
            },
            Flag {
                name: "project",
                usage: "Project directory (defaults to the current directory)",
                ..Flag::VALUE
            },
        ],
        subcommands: &[],
        arity: Arity::None,
        operands: Operands::Files,
        implementation: include_archive::run,
    },
    Command {
        name: "list",
        aliases: &["ls", "l"],
        usage: "list",
        short: "List all workrooms for the current project",
        long: None,
        hidden: false,
        mac_only: true,
        flags: &[
            Flag {
                name: "project",
                usage: "Limit JSON output to a single project directory",
                ..Flag::VALUE
            },
            Flag {
                name: "warnings",
                usage: "Warning detail for --json: none, fast, or full",
                default: "fast",
                ..Flag::VALUE
            },
        ],
        subcommands: &[],
        arity: Arity::None,
        operands: Operands::Files,
        implementation: list::run,
    },
    Command {
        name: "send",
        aliases: &[],
        usage: "send TARGET [TEXT] [flags]",
        short: "Type text and keys into a terminal session",
        long: None,
        hidden: false,
        mac_only: false,
        flags: send::FLAGS,
        subcommands: &[],
        // A TARGET and an optional TEXT, which `send::run` checks.
        arity: Arity::Own,
        // A TARGET is a session the daemon knows, never a file, as for `sessions`.
        operands: Operands::Nothing,
        implementation: send::run,
    },
    Command {
        name: "sessions",
        aliases: &[],
        usage: "sessions [TARGET]",
        short: "List the daemon's terminal sessions, or the one TARGET names",
        long: None,
        hidden: false,
        mac_only: false,
        flags: &[
            Flag {
                name: "all",
                usage: "List every session, not just those in this pane's workroom",
                ..Flag::BOOL
            },
            Flag {
                name: "clients",
                usage: "Also list each session's attached clients: kind, hostname, when it \
                        attached, size, size owner and keepalive",
                ..Flag::BOOL
            },
        ],
        subcommands: &[],
        // One optional TARGET, which `sessions::run` checks.
        arity: Arity::Own,
        // A TARGET is a session the daemon knows (an id, label or title), never a file, so
        // completion offers nothing rather than cobra's default of file names. Asking the daemon
        // for live labels is for later.
        operands: Operands::Nothing,
        implementation: sessions::run,
    },
    Command {
        name: "trust",
        aliases: &[],
        usage: "trust",
        short: "Approve a project's setup and teardown scripts so Workroom runs them",
        long: Some(trust::LONG),
        hidden: false,
        mac_only: true,
        flags: TRUST_FLAGS,
        subcommands: &[Command {
            long: Some(trust::STATUS_LONG),
            ..subcommand(
                TRUST,
                true,
                "status",
                "trust status",
                "Say whether a project's setup and teardown scripts are approved",
                TRUST_FLAGS,
            )
        }],
        // `status`, and the usage errors for anything else, which `trust::run` checks.
        arity: Arity::Own,
        operands: Operands::Files,
        implementation: TRUST,
    },
    Command {
        name: "untrust",
        aliases: &[],
        usage: "untrust",
        short: "Forget the approval of a project's setup and teardown scripts",
        long: None,
        hidden: false,
        mac_only: true,
        flags: &[Flag {
            name: "project",
            usage: "Project directory (defaults to the current directory)",
            ..Flag::VALUE
        }],
        subcommands: &[],
        arity: Arity::None,
        operands: Operands::Files,
        implementation: trust::untrust,
    },
    Command {
        name: "update",
        aliases: &["u"],
        usage: "update",
        short: "Update workroom to the latest version",
        long: Some(update::LONG),
        hidden: false,
        mac_only: false,
        flags: update::FLAGS,
        subcommands: &[],
        arity: Arity::None,
        operands: Operands::Files,
        implementation: update::run,
    },
    Command {
        name: "version",
        aliases: &[],
        usage: "version",
        short: "Print the version",
        long: None,
        hidden: false,
        mac_only: false,
        flags: &[],
        subcommands: &[],
        arity: Arity::None,
        operands: Operands::Files,
        implementation: version::run,
    },
    Command {
        name: "wait",
        aliases: &[],
        usage: "wait TARGET [flags]",
        short: "Wait for something to happen in a terminal session",
        long: None,
        hidden: false,
        mac_only: false,
        flags: wait::FLAGS,
        subcommands: &[],
        // One TARGET, which `wait::run` checks.
        arity: Arity::Own,
        // A TARGET is a session the daemon knows, never a file, as for `sessions`.
        operands: Operands::Nothing,
        implementation: wait::run,
    },
];

const API: Implementation = api::run;
const BASE: Implementation = base::run;
const HOST: Implementation = host::run;
const TRUST: Implementation = trust::run;

/// A Mac-only command run by `implementation`, shown in `--help`, with no aliases. It has the
/// flags Go gives it, so `--help` and shell completion match Go's.
const fn mac_command(
    implementation: Implementation,
    name: &'static str,
    usage: &'static str,
    short: &'static str,
    flags: &'static [Flag],
) -> Command {
    Command {
        name,
        aliases: &[],
        usage,
        short,
        long: None,
        hidden: false,
        mac_only: true,
        flags,
        subcommands: &[],
        arity: Arity::None,
        operands: Operands::Files,
        implementation,
    }
}

/// A subcommand of the command whose `implementation` and `mac_only` these are.
const fn subcommand(
    implementation: Implementation,
    mac_only: bool,
    name: &'static str,
    usage: &'static str,
    short: &'static str,
    flags: &'static [Flag],
) -> Command {
    Command {
        name,
        aliases: &[],
        usage,
        short,
        long: None,
        hidden: false,
        mac_only,
        flags,
        subcommands: &[],
        arity: Arity::Own,
        operands: Operands::Files,
        implementation,
    }
}

const BASE_FLAGS: &[Flag] = &[
    Flag {
        name: "global",
        usage: "The default for every project that names no base branch",
        ..Flag::BOOL
    },
    Flag {
        name: "project",
        usage: "Project directory (defaults to the current directory)",
        ..Flag::VALUE
    },
];

const HOST_FLAGS: &[Flag] = &[
    Flag {
        name: "project",
        usage: "Project directory (defaults to the current directory)",
        ..Flag::VALUE
    },
    Flag {
        name: "workroom",
        usage: "The project's workroom; omitted, the project's own descriptor",
        ..Flag::VALUE
    },
];

const TRUST_FLAGS: &[Flag] = &[
    Flag {
        name: "project",
        usage: "Project directory (defaults to the current directory)",
        ..Flag::VALUE
    },
    Flag {
        name: "stdin",
        usage: "Judge this script's contents, read from stdin, in place of the project's file \
                (used by the desktop app)",
        hidden: true,
        ..Flag::VALUE
    },
    Flag {
        name: "base",
        usage: "Judge the setup script at this branch, on origin unless it names a remote (\"\" is \
                origin's default), in place of the project's base (used by the desktop app)",
        hidden: true,
        ..Flag::VALUE
    },
    Flag {
        name: "devcontainer",
        usage: "Judge the devcontainer.json a container create from --base would use too (used \
                by the desktop app)",
        hidden: true,
        ..Flag::BOOL
    },
];

const NO_DESCRIPTIONS: &[Flag] = &[Flag {
    name: "no-descriptions",
    usage: "disable completion descriptions",
    ..Flag::BOOL
}];

/// `completion <shell>`, as cobra makes each.
const fn shell(
    name: &'static str,
    usage: &'static str,
    short: &'static str,
    long: &'static str,
) -> Command {
    Command {
        long: Some(long),
        operands: Operands::Nothing,
        ..subcommand(COMPLETION, false, name, usage, short, NO_DESCRIPTIONS)
    }
}

const COMPLETION: Implementation = completion::run;

/// The root's commands, as cobra finds one by name or alias.
fn find(name: &str) -> Option<&'static Command> {
    find_in(COMMANDS, name)
}

/// The command of `commands` that `name` names, or an alias of.
fn find_in(commands: &'static [Command], name: &str) -> Option<&'static Command> {
    commands
        .iter()
        .find(|command| command.name == name || command.aliases.contains(&name))
}

/// Runs the CLI command `args` names and returns its exit code. `main.rs` calls it only for what
/// is not one of the daemon's subcommands (`crate::cli::route`).
pub fn run_cli(args: &[OsString]) -> ExitCode {
    // As Go reads os.Args: bytes, with each one that isn't UTF-8 read as U+FFFD.
    let args: Vec<String> = args
        .iter()
        .map(|arg| log::go_lossy(arg.as_encoded_bytes()))
        .collect();
    let env = |name: &str| std::env::var(name).ok();
    let context = Context {
        json: false,
        pretend: false,
        verbose: false,
        platform: Platform::current(),
        env,
        daemon_above: terminal_api::daemon_above,
        color: std::io::stdout().is_terminal()
            && env("NO_COLOR").is_none_or(|value| value.is_empty())
            && env("TERM").as_deref() != Some("dumb"),
    };
    let output = run(&args, context);
    let _ = std::io::stdout().write_all(output.stdout.as_bytes());
    let _ = std::io::stderr().write_all(output.stderr.as_bytes());
    ExitCode::from(output.code)
}

/// The global flags, the command's own, and what is left once they are taken out.
#[derive(Default)]
struct Parsed {
    json: bool,
    help: bool,
    pretend: bool,
    verbose: bool,
    positional: Vec<String>,
    values: Vec<(&'static str, String)>,
}

/// Reads the arguments left to right, as Go's flag parser does: a bad flag stops it, with what was
/// set before it (so `--json --bogus` reports in the envelope and `--bogus --json` doesn't).
/// `flags` are the command's own, beside the global ones. A flag that takes a value takes the next
/// argument when it has no `=`, whatever that argument looks like, as pflag does.
fn parse(args: &[String], flags: &'static [Flag]) -> (Parsed, Option<String>) {
    let mut parsed = Parsed::default();
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        if arg == "--" {
            parsed.positional.extend(rest.by_ref().cloned());
            break;
        }
        if let Some(long) = arg.strip_prefix("--") {
            let (name, value) = match long.split_once('=') {
                Some((name, value)) => (name, Some(value)),
                None => (long, None),
            };
            let own = flags.iter().find(|flag| flag.name == name);
            if let Some(flag) = own.filter(|flag| flag.takes_value) {
                let value = match value {
                    Some(value) => value.to_string(),
                    None => match rest.next() {
                        Some(next) => next.clone(),
                        None => {
                            return (parsed, Some(format!("flag needs an argument: --{name}")));
                        }
                    },
                };
                parsed.values.push((flag.name, value));
                continue;
            }
            let on = match value.map(parse_bool) {
                None => true,
                Some(Some(on)) => on,
                Some(None) => {
                    let spelled = own.map_or_else(|| format!("--{name}"), Flag::spelled);
                    return (
                        parsed,
                        Some(format!(
                            "invalid argument {:?} for {spelled:?} flag: strconv.ParseBool: parsing {:?}: invalid syntax",
                            value.unwrap_or_default(),
                            value.unwrap_or_default()
                        )),
                    );
                }
            };
            match (name, own) {
                (_, Some(flag)) => parsed.values.push((flag.name, on.to_string())),
                ("json", None) => parsed.json = on,
                ("help", None) => parsed.help = on,
                ("pretend", None) => parsed.pretend = on,
                ("verbose", None) => parsed.verbose = on,
                _ => return (parsed, Some(format!("unknown flag: --{name}"))),
            }
        } else if let Some(shorts) = arg.strip_prefix('-').filter(|shorts| !shorts.is_empty()) {
            for short in shorts.chars() {
                let own = flags
                    .iter()
                    .find(|flag| flag.short == Some(short) && !flag.takes_value);
                match (short, own) {
                    (_, Some(flag)) => parsed.values.push((flag.name, "true".to_string())),
                    ('h', None) => parsed.help = true,
                    ('p', None) => parsed.pretend = true,
                    ('v', None) => parsed.verbose = true,
                    _ => {
                        return (
                            parsed,
                            Some(format!("unknown shorthand flag: '{short}' in {arg}")),
                        );
                    }
                }
            }
        } else {
            parsed.positional.push(arg.clone());
        }
    }
    (parsed, None)
}

/// Go's `strconv.ParseBool`.
fn parse_bool(value: &str) -> Option<bool> {
    match value {
        "1" | "t" | "T" | "TRUE" | "true" | "True" => Some(true),
        "0" | "f" | "F" | "FALSE" | "false" | "False" => Some(false),
        _ => None,
    }
}

/// What one run of the CLI writes, and how it exits.
#[derive(Debug, PartialEq, Eq)]
struct Output {
    stdout: String,
    stderr: String,
    code: u8,
}

impl Output {
    fn stdout(text: String) -> Output {
        Output {
            stdout: text,
            stderr: String::new(),
            code: 0,
        }
    }
}

/// Runs `args` in `context`, whose global flags the run sets. Separate from [`run_cli`] so a test
/// can choose the platform and the environment.
fn run(args: &[String], mut context: Context) -> Output {
    // The command is the first argument that isn't a flag, as Go finds it before parsing.
    let name = args.iter().find(|arg| !arg.starts_with('-')).cloned();
    let command = match name.as_deref() {
        None => None,
        // What a completion script asks on every Tab, which cobra answers before parsing a flag:
        // the rest of the line is the one to complete.
        Some(request @ ("__complete" | "__completeNoDesc")) => {
            let at = args.iter().position(|arg| arg == request).unwrap_or(0);
            let line = [&args[..at], &args[at + 1..]].concat();
            return complete::run(&line, request == "__completeNoDesc", &context);
        }
        Some(name) => match find(name) {
            Some(command) => Some(command),
            // Go reports this before its flags are parsed, so never in an envelope.
            None => {
                return Output {
                    stdout: String::new(),
                    stderr: format!("Error: unknown command {name:?} for \"workroom\"\n"),
                    code: 1,
                };
            }
        },
    };
    // A subcommand's own flags are its, not its parent's (`base set --global`), so the flags are
    // the subcommand's the arguments name, found as cobra finds it.
    let leaf = command.map(|command| {
        let at = args
            .iter()
            .position(|arg| !arg.starts_with('-'))
            .unwrap_or(0);
        let rest = [&args[..at], &args[at + 1..]].concat();
        complete::descend(command, rest).0
    });
    let (parsed, error) = parse(args, leaf.map_or(&[], |leaf| leaf.flags));
    context.json = parsed.json;
    context.pretend = parsed.pretend;
    context.verbose = parsed.verbose;
    // A Mac-only command away from the Mac refuses no flag: `MacOnly` is what it answers, whatever
    // it was given.
    let refuses_nothing =
        command.is_some_and(|command| command.mac_only && context.platform != Platform::Mac);
    if let Some(message) = error.filter(|_| !refuses_nothing) {
        return report(&context, None, Outcome::Usage(CliError::internal(message)));
    }
    let (Some(command), Some(leaf)) = (command, leaf) else {
        return Output::stdout(help(None));
    };
    if parsed.help {
        return Output::stdout(help(Some(leaf)));
    }
    // Go checks a command's arguments before it runs, so the envelope names no command.
    let args = Args {
        positional: parsed.positional.iter().skip(1).cloned().collect(),
        values: parsed.values,
        flags: leaf.flags,
    };
    if let (false, Arity::None, Some(extra)) =
        (refuses_nothing, command.arity, args.positional.first())
    {
        let message = format!(
            "unknown command {extra:?} for \"workroom {}\"",
            command.name
        );
        return report(&context, None, Outcome::Usage(CliError::internal(message)));
    }
    // Then its required flags, as cobra checks them after the arguments: the subcommand's, if the
    // arguments name one.
    if let Some(message) = missing_required(args.flags, &args.values).filter(|_| !refuses_nothing) {
        return report(&context, None, Outcome::Usage(CliError::internal(message)));
    }
    let outcome = if command.mac_only && context.platform != Platform::Mac {
        Outcome::Failed(CliError::new(
            Kind::MacOnly,
            format!(
                "`workroom {}` works only on the Mac: it reads and writes the Mac's Workroom config",
                command.name
            ),
        ))
    } else {
        (command.implementation)(&context, &args)
    };
    report(&context, Some(command.name), outcome)
}

/// cobra's `ValidateRequiredFlags`: the error naming each required flag in `flags` that `values`
/// doesn't set, in pflag's order (sorted by name). None when they are all set.
fn missing_required(flags: &[Flag], values: &[(&'static str, String)]) -> Option<String> {
    let mut missing: Vec<&str> = flags
        .iter()
        .filter(|flag| flag.required && !values.iter().any(|(name, _)| *name == flag.name))
        .map(|flag| flag.name)
        .collect();
    if missing.is_empty() {
        return None;
    }
    missing.sort_unstable();
    Some(format!(
        "required flag(s) \"{}\" not set",
        missing.join("\", \"")
    ))
}

/// `outcome` as what the run writes, and its exit code.
fn report(context: &Context, command: Option<&str>, outcome: Outcome) -> Output {
    let (printed, command, error) = match outcome {
        Outcome::Printed(text) | Outcome::Success(text) => return Output::stdout(text),
        Outcome::PrintedWithWarnings { stdout, warnings } => {
            return Output {
                stdout,
                stderr: warnings,
                code: 0,
            };
        }
        Outcome::Failed(error) => (String::new(), command, error),
        Outcome::FailedIn(subcommand, error) => (String::new(), Some(subcommand), error),
        Outcome::Usage(error) => (String::new(), None, error),
        Outcome::PrintedThenFailed(text, error) => (text, command, error),
        Outcome::Status(code, outcome) => {
            return Output {
                code,
                ..report(context, command, *outcome)
            };
        }
    };
    match error {
        error if context.json => Output {
            stdout: printed + &envelope::failure(command, &error),
            stderr: String::new(),
            code: error.kind.exit_code(),
        },
        error => {
            // An ambiguous target's matches, one per line, so a person can pick one by its id.
            let mut stderr = format!("Error: {}\n", error.message);
            for session in &error.matches {
                let field = |key: &str| session[key].as_str().unwrap_or_default().to_string();
                stderr += &format!(
                    "  {}  {}  {}\n",
                    field("id"),
                    field("label"),
                    field("title")
                );
            }
            Output {
                stdout: printed,
                stderr,
                code: error.kind.exit_code(),
            }
        }
    }
}

/// `help [command…]`: the help of the command (or subcommand) it names, else the CLI's.
fn help_command(_: &Context, args: &Args) -> Outcome {
    let topic = args.positional.split_first().and_then(|(name, rest)| {
        find(name).map(|command| complete::descend(command, rest.to_vec()).0)
    });
    Outcome::Printed(help(topic))
}

/// `--help` itself, as its table lists it.
const HELP_FLAG: Flag = Flag {
    name: "help",
    short: Some('h'),
    usage: "help",
    ..Flag::BOOL
};

/// `--help`'s flag table: `--help` and the global flags, then `own` but its hidden ones, each
/// usage in one column.
fn flag_table(own: &[Flag]) -> String {
    let mut rows: Vec<(String, String)> = Vec::new();
    let all = std::iter::once(&HELP_FLAG)
        .chain(PERSISTENT_FLAGS)
        .chain(own);
    for flag in all.filter(|flag| !flag.hidden) {
        let spelled = match flag.short {
            Some(_) => flag.spelled(),
            None => format!("    {}", flag.spelled()),
        };
        let name = if flag.takes_value {
            spelled + " string"
        } else {
            spelled
        };
        let usage = if flag.default.is_empty() {
            flag.usage.to_string()
        } else {
            format!("{} (default {:?})", flag.usage, flag.default)
        };
        rows.push((name, usage));
    }
    let width = rows.iter().map(|(name, _)| name.len()).max().unwrap_or(0);
    rows.iter()
        .map(|(name, usage)| format!("  {name:width$}   {usage}\n"))
        .collect()
}

/// `--help` for the CLI, or for one command.
fn help(command: Option<&Command>) -> String {
    let mark = |command: &Command| if command.mac_only { " (Mac only)" } else { "" };
    match command {
        Some(command) => {
            let mut text = format!(
                "{}{}\n\nUsage:\n  workroom {}\n",
                command.long.unwrap_or(command.short),
                mark(command),
                command.usage
            );
            let shown: Vec<&Command> = command
                .subcommands
                .iter()
                .filter(|sub| !sub.hidden)
                .collect();
            if !shown.is_empty() {
                let width = shown
                    .iter()
                    .map(|sub| sub.name.len())
                    .max()
                    .unwrap_or(0)
                    .max(11);
                text += "\nAvailable Commands:\n";
                for sub in shown {
                    text += &format!("  {:width$} {}\n", sub.name, sub.short);
                }
            }
            if !command.aliases.is_empty() {
                text += &format!(
                    "\nAliases:\n  {}, {}\n",
                    command.name,
                    command.aliases.join(", ")
                );
            }
            text + "\nFlags:\n" + &flag_table(command.flags)
        }
        None => {
            // As cobra lays it out: sorted by name, `help` among them, each name padded to the
            // longest command's, hidden ones included, and to at least 11.
            let mut shown: Vec<(&str, String)> = COMMANDS
                .iter()
                .filter(|command| !command.hidden)
                .map(|command| (command.name, format!("{}{}", command.short, mark(command))))
                .collect();
            shown.sort_by_key(|(name, _)| *name);
            let width = COMMANDS
                .iter()
                .map(|command| command.name.len())
                .max()
                .unwrap_or(0)
                .max(11);
            let mut text = String::from(
                "Create and manage local development workrooms using Git worktrees.\n\n\
                 Usage:\n  workroom [command]\n\nAvailable Commands:\n",
            );
            for (name, short) in shown {
                text += &format!("  {name:width$} {short}\n");
            }
            text + "\nFlags:\n"
                + &flag_table(&[])
                + "\nUse \"workroom [command] --help\" for more information about a command.\n"
        }
    }
}

/// A directory for one unit test, removed when it ends.
#[cfg(test)]
pub(crate) struct Scratch(pub(crate) std::path::PathBuf);

#[cfg(test)]
impl Scratch {
    /// A directory this run made itself, as the contract suite's `Home::new` makes one:
    /// `create_dir` fails on any path that already exists, so a leftover from a killed run, or
    /// another run's live directory, is skipped rather than reused, and only what this call
    /// created is ever removed.
    pub(crate) fn new(name: &str) -> Scratch {
        let parent = std::env::temp_dir();
        let pid = std::process::id();
        for attempt in 0u32.. {
            let dir = parent.join(format!("workroom-commands-{name}-{pid}-{attempt}"));
            match std::fs::create_dir(&dir) {
                Ok(()) => return Scratch(dir.canonicalize().expect("resolve scratch dir")),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("create {}: {error}", dir.display()),
            }
        }
        unreachable!("u32 attempts ran out")
    }
}

#[cfg(test)]
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// ((stdout, stderr), exit code) of running `args` on `platform`, with an empty environment.
    fn run_on(platform: Platform, args: &[&str]) -> ((String, String), u8) {
        let args: Vec<String> = args.iter().map(|arg| arg.to_string()).collect();
        let Output {
            stdout,
            stderr,
            code,
        } = run(
            &args,
            Context {
                json: false,
                pretend: false,
                verbose: false,
                platform,
                env: |_| None,
                daemon_above: || None,
                color: false,
            },
        );
        ((stdout, stderr), code)
    }

    #[test]
    fn a_mac_only_command_away_from_the_mac_fails_with_mac_only() {
        for name in [
            "create",
            "delete",
            "list",
            "base",
            "host",
            "trust",
            "untrust",
            "add-project",
            "delete-project",
            "claim-provisioned",
            "include-archive",
            "ls",
        ] {
            let ((stdout, stderr), code) = run_on(Platform::Other, &[name, "--json"]);
            assert_eq!(code, 3, "{name}");
            assert_eq!(stderr, "", "{name}");
            let envelope: serde_json::Value = serde_json::from_str(&stdout).unwrap();
            assert_eq!(envelope["error"]["kind"], "MacOnly", "{name}");
            assert_eq!(envelope["ok"], false, "{name}");
            let ((_, plain), code) = run_on(Platform::Other, &[name]);
            assert_eq!(code, 3, "{name}");
            assert!(plain.starts_with("Error: `workroom "), "{plain}");
        }
    }

    /// What `tests/commands_platform.rs` runs on a Linux host, and a ported command's own flags and
    /// arguments, bad ones included: away from the Mac each is `MacOnly`, never a usage error.
    #[test]
    fn a_ported_mac_only_command_away_from_the_mac_is_mac_only_whatever_its_arguments() {
        for args in [
            &["list", "--json"][..],
            &["ls", "--json"],
            &["list", "--json", "--warnings=bad"],
            &["list", "--json", "--bogus"],
            &["list", "--json", "extra"],
            &["base", "set", "main", "--json"],
            &["base", "set", "--global", "main", "--json"],
            &["base", "set", "a..b", "--json"],
            &["base", "set", "--json"],
            &["base", "clear", "--json", "--project", "/x"],
            &["base", "clear", "--json", "--bogus"],
            &["host", "set", "{}", "--json", "--project", "/x"],
            &["host", "set", "null", "--json"],
            &["host", "set", "--json"],
            &["host", "clear", "--json", "--workroom", "w"],
            &["trust", "--json", "--project", "/x"],
            &["trust", "status", "--json", "--base", "", "--devcontainer"],
            &["trust", "status", "--json", "--stdin", "bogus"],
            &["trust", "status", "extra", "--json"],
            &["trust", "extra", "--json"],
            &["untrust", "--json", "--project", "/x"],
            &["untrust", "extra", "--json"],
            &["create", "--json", "--no-editor"],
            &["add-project", "/tmp/x", "--json"],
            // Before its arguments are counted, and it clones and makes nothing.
            &["add-project", "/x", "/y", "--json"],
            &["add-project", "/tmp/x", "--json", "--clone", "file:///y"],
            &["add-project", "/tmp/x", "--json", "--create"],
            // Before its arguments are counted or its confirmation checked, and it deletes nothing.
            &["delete", "a", "b", "--json"],
            &["delete", "--json"],
            &["d", "calm-river", "--json", "--confirm", "nope"],
            &[
                "delete",
                "calm-river",
                "--json",
                "--confirm",
                "calm-river",
                "--project",
                "/x",
                "--skip-teardown",
            ],
            // Before its arguments are counted, and it deletes nothing.
            &["delete-project", "/x", "/y", "--json"],
            &[
                "delete-project",
                "/x",
                "--json",
                "--confirm",
                "/x",
                "--from-disk",
            ],
            // Before its required flags are checked.
            &["claim-provisioned", "--json"],
            &[
                "claim-provisioned",
                "--json",
                "--from",
                "/x",
                "--provisioner",
                "p",
            ],
            // Before its required `--output` is checked, and it writes no tar.
            &["include-archive", "--json"],
            &["include-archive", "--json", "--project=/x"],
            &[
                "include-archive",
                "--json",
                "--project",
                "/x",
                "--output",
                "/y.tar",
            ],
        ] {
            let ((stdout, _), code) = run_on(Platform::Other, args);
            assert_eq!(code, 3, "{args:?}");
            let envelope: serde_json::Value = serde_json::from_str(&stdout).unwrap();
            assert_eq!(envelope["error"]["kind"], "MacOnly", "{args:?}");
        }
    }

    #[test]
    fn a_commands_own_flag_takes_the_next_argument_or_its_equals_value() {
        let (parsed, error) = parse(
            &[
                "list".to_string(),
                "--warnings".to_string(),
                "--json".to_string(),
                "--project=".to_string(),
            ],
            find("list").unwrap().flags,
        );
        assert!(error.is_none());
        assert!(!parsed.json, "--json was --warnings's value");
        assert_eq!(
            parsed.values,
            [
                ("warnings", "--json".to_string()),
                ("project", String::new())
            ]
        );
        let (_, error) = parse(
            &["list".to_string(), "--project".to_string()],
            find("list").unwrap().flags,
        );
        assert_eq!(error.as_deref(), Some("flag needs an argument: --project"));
        let (parsed, _) = parse(
            &[
                "base".to_string(),
                "set".to_string(),
                "--global=false".to_string(),
                "-p".to_string(),
            ],
            find_in(find("base").unwrap().subcommands, "set")
                .unwrap()
                .flags,
        );
        assert_eq!(parsed.values, [("global", "false".to_string())]);
        assert!(parsed.pretend);
    }

    /// Completion works on a remote host as on the Mac: the scripts, and `__complete`'s
    /// candidates, Mac-only commands' flags included, come from the table, not the commands.
    #[test]
    fn completion_runs_anywhere() {
        for platform in [Platform::Mac, Platform::Other] {
            let ((stdout, stderr), code) = run_on(platform, &["__complete", "b"]);
            assert_eq!(
                (stdout.as_str(), code),
                (
                    "base\tSet or clear the branch new workrooms start from\n:4\n",
                    0
                )
            );
            assert_eq!(
                stderr,
                "Completion ended with directive: ShellCompDirectiveNoFileComp\n"
            );
            let ((stdout, _), _) = run_on(platform, &["__completeNoDesc", "base", "set", "--g"]);
            assert_eq!(stdout, "--global\n:4\n");
            let ((script, stderr), code) = run_on(platform, &["completion", "zsh"]);
            assert_eq!((stderr.as_str(), code), ("", 0));
            assert!(script.starts_with("#compdef workroom\n"), "{script}");
        }
    }

    /// `sessions` is Rust's alone (#683), so the contract suite's Go-recorded transcript can't
    /// hold it: completion offers it beside Go's commands, and the global flags after it, as for
    /// any command with no flags of its own.
    #[test]
    fn completion_offers_sessions_and_its_flags() {
        let ((stdout, _), code) = run_on(Platform::Other, &["__complete", "s"]);
        assert_eq!(
            (stdout.as_str(), code),
            (
                "send\tType text and keys into a terminal session\nsessions\tList the daemon's \
                 terminal sessions, or the one TARGET names\n:4\n",
                0
            )
        );
        let ((stdout, _), _) = run_on(Platform::Other, &["__completeNoDesc", ""]);
        assert!(stdout.lines().any(|line| line == "sessions"), "{stdout}");
        let ((stdout, _), _) = run_on(Platform::Other, &["__completeNoDesc", "sessions", "--"]);
        // In cobra's order, as `version`'s are in the contract suite's transcript: the inherited
        // flags, then its own (`--all`, `--clients`), then `--help`.
        assert_eq!(
            stdout,
            "--json\n--pretend\n--verbose\n--all\n--clients\n--help\n:4\n"
        );
        // A TARGET is never a file: no candidates, and no file names from the shell either.
        for args in [
            &["__complete", "sessions", ""][..],
            &["__complete", "sessions", "x", ""],
        ] {
            let ((stdout, _), code) = run_on(Platform::Other, args);
            assert_eq!((stdout.as_str(), code), (":4\n", 0), "{args:?}");
        }
    }

    /// `api` is Rust's alone too (#685): completion offers it, then its subcommands, and nothing
    /// for a METHOD or PARAMS, which are never file names.
    #[test]
    fn completion_offers_api_and_its_subcommands() {
        let ((stdout, _), _) = run_on(Platform::Other, &["__completeNoDesc", ""]);
        assert!(stdout.lines().any(|line| line == "api"), "{stdout}");
        let ((stdout, _), code) = run_on(Platform::Other, &["__completeNoDesc", "api", ""]);
        assert_eq!((stdout.as_str(), code), ("call\ndescribe\nlist\n:4\n", 0));
        let ((stdout, _), _) = run_on(Platform::Other, &["__complete", "api", "d"]);
        assert_eq!(
            stdout,
            "describe\tShow METHOD's parameter and result schemas, with examples\n:4\n"
        );
        for args in [
            &["__complete", "api", "describe", ""][..],
            &["__complete", "api", "call", "session.resolve", ""],
        ] {
            let ((stdout, _), code) = run_on(Platform::Other, args);
            assert_eq!((stdout.as_str(), code), (":4\n", 0), "{args:?}");
        }
    }

    /// `capture` is Rust's alone too (#686): completion offers it and its flags, and nothing for a
    /// TARGET, which is a session, never a file name, as `sessions`' is.
    #[test]
    fn completion_offers_capture_and_its_flags() {
        let ((stdout, _), _) = run_on(Platform::Other, &["__completeNoDesc", ""]);
        assert!(stdout.lines().any(|line| line == "capture"), "{stdout}");
        let ((stdout, _), _) = run_on(Platform::Other, &["__completeNoDesc", "capture", "--"]);
        for flag in ["--all", "--lines", "--unwrap", "--vt", "--json"] {
            assert!(stdout.lines().any(|line| line == flag), "{flag}: {stdout}");
        }
        for args in [
            &["__complete", "capture", ""][..],
            &["__complete", "capture", "server", ""],
        ] {
            let ((stdout, _), code) = run_on(Platform::Other, args);
            assert_eq!((stdout.as_str(), code), (":4\n", 0), "{args:?}");
        }
    }

    /// `events` is Rust's alone too (#687): completion offers it and its flags, and no file names,
    /// since it takes no arguments and `--session` a session.
    #[test]
    fn completion_offers_events_and_its_flags() {
        let ((stdout, _), _) = run_on(Platform::Other, &["__completeNoDesc", ""]);
        assert!(stdout.lines().any(|line| line == "events"), "{stdout}");
        let ((stdout, _), _) = run_on(Platform::Other, &["__completeNoDesc", "events", "--"]);
        for flag in ["--all", "--session", "--type", "--workroom", "--json"] {
            assert!(stdout.lines().any(|line| line == flag), "{flag}: {stdout}");
        }
        let ((stdout, _), code) = run_on(Platform::Other, &["__complete", "events", ""]);
        assert_eq!((stdout.as_str(), code), (":4\n", 0));
    }

    /// `send` is Rust's alone too (#689): completion offers it and its flags, and nothing for its
    /// TARGET or TEXT, neither of which is a file name.
    #[test]
    fn completion_offers_send_and_its_flags() {
        let ((stdout, _), _) = run_on(Platform::Other, &["__completeNoDesc", ""]);
        assert!(stdout.lines().any(|line| line == "send"), "{stdout}");
        let ((stdout, _), _) = run_on(Platform::Other, &["__completeNoDesc", "send", "--"]);
        for flag in ["--allow-self", "--enter", "--key", "--stdin", "--json"] {
            assert!(stdout.lines().any(|line| line == flag), "{flag}: {stdout}");
        }
        for args in [
            &["__complete", "send", ""][..],
            &["__complete", "send", "server", ""],
        ] {
            let ((stdout, _), code) = run_on(Platform::Other, args);
            assert_eq!((stdout.as_str(), code), (":4\n", 0), "{args:?}");
        }
    }

    /// `command` is Rust's alone too (#691): completion offers it and its flags, and nothing for
    /// its TARGET or its COMMAND, neither of which is a file name here.
    #[test]
    fn completion_offers_command_and_its_flags() {
        let ((stdout, _), _) = run_on(Platform::Other, &["__completeNoDesc", ""]);
        assert!(stdout.lines().any(|line| line == "command"), "{stdout}");
        let ((stdout, _), _) = run_on(Platform::Other, &["__completeNoDesc", "command", "--"]);
        for flag in ["--allow-self", "--timeout", "--json"] {
            assert!(stdout.lines().any(|line| line == flag), "{flag}: {stdout}");
        }
        for args in [
            &["__complete", "command", ""][..],
            &["__complete", "command", "server", ""],
        ] {
            let ((stdout, _), code) = run_on(Platform::Other, args);
            assert_eq!((stdout.as_str(), code), (":4\n", 0), "{args:?}");
        }
    }

    /// As in Go, `base`'s flags are `set`'s and `clear`'s, and each subcommand's `--help` is its
    /// own; `create`'s `--help` lists the flags Go gives it, but the hidden ones.
    #[test]
    fn a_subcommands_flags_and_help_are_its_own() {
        let ((stdout, stderr), code) = run_on(Platform::Mac, &["base", "--global"]);
        assert_eq!(
            (stdout.as_str(), stderr.as_str(), code),
            ("", "Error: unknown flag: --global\n", 1)
        );
        let ((text, _), code) = run_on(Platform::Mac, &["base", "set", "--help"]);
        assert_eq!(code, 0);
        assert!(
            text.starts_with(
                "Start new workrooms from BRANCH (Mac only)\n\nUsage:\n  workroom base set BRANCH\n"
            ),
            "{text}"
        );
        assert!(text.contains("      --global "), "{text}");
        let ((text, _), _) = run_on(Platform::Mac, &["create", "--help"]);
        assert!(text.contains("      --no-editor "), "{text}");
        assert!(!text.contains("--host"), "{text}");
    }

    #[test]
    fn help_names_a_subcommand_as_its_topic() {
        let ((text, _), code) = run_on(Platform::Other, &["help", "completion", "zsh"]);
        assert_eq!(code, 0);
        assert!(
            text.starts_with("Generate the autocompletion script for the zsh shell.\n"),
            "{text}"
        );
        let ((text, _), _) = run_on(Platform::Other, &["help", "completion"]);
        assert!(
            text.contains("\nAvailable Commands:\n  bash        Generate"),
            "{text}"
        );
        let ((unknown, _), _) = run_on(Platform::Other, &["help", "bogus"]);
        let ((root, _), _) = run_on(Platform::Other, &["--help"]);
        assert_eq!(unknown, root);
    }

    #[test]
    fn a_commands_help_lists_its_own_flags() {
        let ((text, _), _) = run_on(Platform::Mac, &["list", "--help"]);
        assert!(
            text.contains(
                "      --warnings string   Warning detail for --json: none, fast, or full (default \"fast\")\n"
            ),
            "{text}"
        );
        assert!(text.contains("  -h, --help              help\n"), "{text}");
        let ((text, _), _) = run_on(Platform::Other, &["include-archive", "--help"]);
        assert!(
            text.contains(
                "      --output string    The file to write the tar to\n      \
                 --project string   Project directory (defaults to the current directory)\n"
            ),
            "{text}"
        );
    }

    /// cobra checks a required flag before the command runs, so the envelope names no command.
    #[test]
    fn a_missing_required_flag_is_a_usage_error_naming_no_command() {
        let ((stdout, stderr), code) = run_on(
            Platform::Mac,
            &["include-archive", "--json", "--project", "/x"],
        );
        assert_eq!((stderr.as_str(), code), ("", 1));
        let envelope: serde_json::Value = serde_json::from_str(&stdout).unwrap();
        assert_eq!(
            envelope["error"]["message"],
            "required flag(s) \"output\" not set"
        );
        assert!(envelope.get("command").is_none(), "{envelope}");
    }

    /// cobra names every required flag that is missing, sorted, in one error (`claim-provisioned`'s
    /// `--from` and `--provisioner` in the Go CLI). One given, even empty, isn't missing.
    #[test]
    fn every_missing_required_flag_is_named_in_cobras_words() {
        const FLAGS: &[Flag] = &[
            Flag {
                name: "provisioner",
                required: true,
                ..Flag::VALUE
            },
            Flag {
                name: "from",
                required: true,
                ..Flag::VALUE
            },
            Flag {
                name: "other",
                ..Flag::VALUE
            },
        ];
        assert_eq!(
            missing_required(FLAGS, &[]).as_deref(),
            Some("required flag(s) \"from\", \"provisioner\" not set")
        );
        assert_eq!(
            missing_required(FLAGS, &[("from", String::new())]).as_deref(),
            Some("required flag(s) \"provisioner\" not set")
        );
        assert_eq!(
            missing_required(
                FLAGS,
                &[("from", "a".into()), ("provisioner", String::new())]
            ),
            None
        );
    }

    #[test]
    fn a_commands_short_flags_and_verbose_parse_as_pflag_parses_them() {
        let args = |list: &[&str]| list.iter().map(|arg| arg.to_string()).collect::<Vec<_>>();
        let (parsed, error) = parse(&args(&["update", "-cv", "--check=false"]), update::FLAGS);
        assert_eq!(error, None);
        assert!(parsed.verbose && !parsed.pretend);
        assert_eq!(
            parsed.values,
            [
                ("check", "true".to_string()),
                ("check", "false".to_string())
            ]
        );
        let (parsed, _) = parse(&args(&["update", "--verbose=false"]), update::FLAGS);
        assert!(!parsed.verbose);
        let (_, error) = parse(&args(&["update", "--check=maybe"]), update::FLAGS);
        assert_eq!(
            error.as_deref(),
            Some(
                "invalid argument \"maybe\" for \"-c, --check\" flag: strconv.ParseBool: parsing \"maybe\": invalid syntax"
            )
        );
        // Another command's short flags are unknown here.
        let ((_, stderr), code) = run_on(Platform::Mac, &["version", "-c"]);
        assert_eq!(
            (stderr.as_str(), code),
            ("Error: unknown shorthand flag: 'c' in -c\n", 1)
        );
    }

    #[test]
    fn updates_help_says_its_long_text_and_lists_its_short_flag() {
        let ((text, _), _) = run_on(Platform::Other, &["update", "--help"]);
        assert!(text.starts_with(update::LONG), "{text}");
        assert!(
            text.contains("  -c, --check            Only check if an update is available\n"),
            "{text}"
        );
        assert!(
            text.contains("      --channel string   Release channel: stable or pre"),
            "{text}"
        );
    }

    #[test]
    fn update_runs_away_from_the_mac_and_refuses_an_argument() {
        let ((stdout, _), code) = run_on(Platform::Other, &["update", "--json", "extra"]);
        assert_eq!(code, 1);
        assert!(
            stdout.contains(r#""message":"unknown command \"extra\" for \"workroom update\"""#),
            "{stdout}"
        );
        let ((stdout, _), code) = run_on(Platform::Other, &["update", "--json", "--channel"]);
        assert_eq!(code, 1);
        assert!(
            stdout.contains("flag needs an argument: --channel"),
            "{stdout}"
        );
    }

    #[test]
    fn version_runs_anywhere() {
        for platform in [Platform::Mac, Platform::Other] {
            let ((stdout, _), code) = run_on(platform, &["version"]);
            assert_eq!((stdout, code), (format!("{VERSION}\n"), 0));
        }
    }

    /// The terminal API's commands run anywhere, and with no daemon named they exit 7 (#360).
    #[test]
    fn sessions_with_no_daemon_named_is_daemon_unreachable_everywhere() {
        for platform in [Platform::Mac, Platform::Other] {
            let ((stdout, stderr), code) = run_on(platform, &["sessions", "--json"]);
            assert_eq!((code, stderr.as_str()), (7, ""));
            let envelope: serde_json::Value = serde_json::from_str(&stdout).unwrap();
            assert_eq!(envelope["error"]["kind"], "DaemonUnreachable");
            assert_eq!(envelope["command"], "sessions");
            assert!(envelope["error"].get("matches").is_none(), "{envelope}");
        }
    }

    #[test]
    fn sessions_takes_one_target_at_most() {
        let ((_, stderr), code) = run_on(Platform::Mac, &["sessions", "a", "b"]);
        assert_eq!(code, 1);
        assert_eq!(
            stderr,
            "Error: unknown command \"b\" for \"workroom sessions\"\n"
        );
    }

    #[test]
    fn help_lists_the_same_commands_everywhere_marking_the_mac_only_ones() {
        let ((mac, _), _) = run_on(Platform::Mac, &["--help"]);
        let ((other, _), _) = run_on(Platform::Other, &["--help"]);
        assert_eq!(mac, other);
        // Go's `workroom --help` lines (cobra pads to "claim-provisioned", the longest name), each
        // Mac-only one marked.
        for line in [
            "\n  base              Set or clear the branch new workrooms start from (Mac only)\n",
            "\n  create            Create a new workroom (Mac only)\n",
            "\n  delete            Delete an existing workroom (Mac only)\n",
            "\n  help              Help about any command\n",
            "\n  list              List all workrooms for the current project (Mac only)\n",
            "\n  update            Update workroom to the latest version\n",
            "\n  version           Print the version\n",
        ] {
            assert!(mac.contains(line), "{line:?} not in:\n{mac}");
        }
        // The app's commands stay out of it, as in Go.
        assert!(
            !mac.contains("add-project") && !mac.contains("include-archive"),
            "{mac}"
        );
        let ((none, _), code) = run_on(Platform::Other, &[]);
        assert_eq!((none, code), (mac, 0));
    }

    #[test]
    fn a_commands_help_marks_it_mac_only() {
        let ((text, _), code) = run_on(Platform::Other, &["list", "--help"]);
        assert_eq!(code, 0);
        assert!(
            text.starts_with("List all workrooms for the current project (Mac only)\n"),
            "{text}"
        );
        assert!(text.contains("list, ls, l"), "{text}");
    }

    #[test]
    fn a_bad_flag_after_json_is_in_the_envelope_and_before_it_is_not() {
        let ((stdout, stderr), code) = run_on(Platform::Mac, &["version", "--json", "--bogus"]);
        assert_eq!(code, 1);
        assert_eq!(stderr, "");
        assert!(
            stdout.contains(r#""message":"unknown flag: --bogus""#),
            "{stdout}"
        );
        assert!(!stdout.contains("\"command\""), "{stdout}");
        let ((stdout, stderr), code) = run_on(Platform::Mac, &["version", "--bogus", "--json"]);
        assert_eq!(
            (stdout.as_str(), stderr.as_str(), code),
            ("", "Error: unknown flag: --bogus\n", 1)
        );
    }
}
