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
//! marked "(Mac only)", and failing with `MacOnly` anywhere else. Until its own ticket ports it
//! (#672–#679), each of those, and `update`, is a stub here; the Go CLI still runs them. `list`
//! and `base --global` are ported (#671), on `config`, the Rust reader and writer of config.json,
//! and so is `include-archive` (#675).
//!
//! The terminal API's commands (#360, ADR 0079) are born here and run anywhere: each is a thin
//! client of the daemon's terminal API (`terminal_api`).

mod base;
pub(crate) mod channel;
mod config;
mod envelope;
mod git;
mod include_archive;
mod kind;
mod list;
mod log;
mod sessions;
mod terminal_api;
mod version;

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
    platform: Platform,
    env: fn(&str) -> Option<String>,
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
    /// Human output for stdout, and lines for stderr about what failed on the way, exit 0.
    PrintedWithErrors { stdout: String, stderr: String },
    /// A success envelope, exit 0.
    Success(String),
    /// A failure, reported in the error envelope under `--json`, else as an `Error:` line.
    Failed(CliError),
    /// A usage error the command found in its arguments: reported as a failure is, but with no
    /// command in the envelope, since Go checks arguments before the command runs.
    Usage(CliError),
}

/// One of a command's own flags, beside the global ones.
struct Flag {
    name: &'static str,
    /// Takes a value (`--name value` or `--name=value`), else is a boolean.
    takes_value: bool,
    usage: &'static str,
    /// The value `--help` shows as the default; "" for none.
    default: &'static str,
    /// Must be given, as cobra's `MarkFlagRequired` makes a flag: a usage error before the command
    /// runs when it isn't (`missing_required`). Given empty, it is.
    required: bool,
}

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

/// One command of the CLI.
struct Command {
    name: &'static str,
    aliases: &'static [&'static str],
    /// The usage line after `workroom `.
    usage: &'static str,
    short: &'static str,
    /// Left out of `--help`: commands the app runs, not people.
    hidden: bool,
    mac_only: bool,
    flags: &'static [Flag],
    arity: Arity,
    implementation: Implementation,
}

/// Whether a command runs in this binary yet.
#[derive(Clone, Copy)]
enum Implementation {
    Ported(fn(&Context, &Args) -> Outcome),
    /// Still the Go CLI's, until `ticket` ports it.
    Stub {
        ticket: &'static str,
    },
}

/// Every command, in `--help`'s order. Names, aliases and help lines are the Go CLI's.
const COMMANDS: &[Command] = &[
    stub(
        "add-project",
        &[],
        "add-project [PATH]",
        "Register a project (internal; used by the macOS app via --json)",
        true,
        true,
        "#672",
    ),
    Command {
        name: "base",
        aliases: &[],
        usage: "base",
        short: "Set or clear the branch new workrooms start from",
        hidden: false,
        mac_only: true,
        flags: &[
            Flag {
                name: "global",
                takes_value: false,
                usage: "The default for every project that names no base branch",
                default: "",
                required: false,
            },
            Flag {
                name: "project",
                takes_value: true,
                usage: "Project directory (defaults to the current directory)",
                default: "",
                required: false,
            },
        ],
        arity: Arity::Own,
        implementation: Implementation::Ported(base::run),
    },
    stub(
        "claim-provisioned",
        &[],
        "claim-provisioned",
        "Move the remote entries a build made from another config into this one (used by the desktop app)",
        true,
        true,
        "#672",
    ),
    stub(
        "create",
        &["c"],
        "create",
        "Create a new workroom",
        false,
        true,
        "#677",
    ),
    stub(
        "delete",
        &["d"],
        "delete [NAME]",
        "Delete an existing workroom",
        false,
        true,
        "#678",
    ),
    stub(
        "delete-project",
        &[],
        "delete-project [PATH]",
        "Remove a project (internal; used by the macOS app via --json)",
        true,
        true,
        "#672",
    ),
    stub(
        "host",
        &[],
        "host",
        "Set or clear a project's or workroom's host descriptor (used by the desktop app)",
        true,
        true,
        "#673",
    ),
    Command {
        name: "include-archive",
        aliases: &[],
        usage: "include-archive",
        short: "Write the project's included files to a tar (used by the desktop app)",
        hidden: true,
        mac_only: true,
        flags: &[
            Flag {
                name: "output",
                takes_value: true,
                usage: "The file to write the tar to",
                default: "",
                required: true,
            },
            Flag {
                name: "project",
                takes_value: true,
                usage: "Project directory (defaults to the current directory)",
                default: "",
                required: false,
            },
        ],
        arity: Arity::None,
        implementation: Implementation::Ported(include_archive::run),
    },
    Command {
        name: "list",
        aliases: &["ls", "l"],
        usage: "list",
        short: "List all workrooms for the current project",
        hidden: false,
        mac_only: true,
        flags: &[
            Flag {
                name: "project",
                takes_value: true,
                usage: "Limit JSON output to a single project directory",
                default: "",
                required: false,
            },
            Flag {
                name: "warnings",
                takes_value: true,
                usage: "Warning detail for --json: none, fast, or full",
                default: "fast",
                required: false,
            },
        ],
        arity: Arity::None,
        implementation: Implementation::Ported(list::run),
    },
    Command {
        name: "sessions",
        aliases: &[],
        usage: "sessions [TARGET]",
        short: "List the daemon's terminal sessions, or the one TARGET names",
        hidden: false,
        mac_only: false,
        flags: &[],
        // One optional TARGET, which `sessions::run` checks.
        arity: Arity::Own,
        implementation: Implementation::Ported(sessions::run),
    },
    stub(
        "trust",
        &[],
        "trust",
        "Approve a project's setup and teardown scripts so Workroom runs them",
        false,
        true,
        "#674",
    ),
    stub(
        "untrust",
        &[],
        "untrust",
        "Forget the approval of a project's setup and teardown scripts",
        false,
        true,
        "#674",
    ),
    stub(
        "update",
        &["u"],
        "update",
        "Update workroom to the latest version",
        false,
        false,
        "#679",
    ),
    Command {
        name: "version",
        aliases: &[],
        usage: "version",
        short: "Print the version",
        hidden: false,
        mac_only: false,
        flags: &[],
        arity: Arity::None,
        implementation: Implementation::Ported(version::run),
    },
];

const fn stub(
    name: &'static str,
    aliases: &'static [&'static str],
    usage: &'static str,
    short: &'static str,
    hidden: bool,
    mac_only: bool,
    ticket: &'static str,
) -> Command {
    Command {
        name,
        aliases,
        usage,
        short,
        hidden,
        mac_only,
        flags: &[],
        arity: Arity::None,
        implementation: Implementation::Stub { ticket },
    }
}

fn find(name: &str) -> Option<&'static Command> {
    COMMANDS
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
        platform: Platform::current(),
        env,
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
                    return (
                        parsed,
                        Some(format!(
                            "invalid argument {:?} for \"--{name}\" flag: strconv.ParseBool: parsing {:?}: invalid syntax",
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
                ("verbose", None) => {}
                _ => return (parsed, Some(format!("unknown flag: --{name}"))),
            }
        } else if let Some(shorts) = arg.strip_prefix('-').filter(|shorts| !shorts.is_empty()) {
            for short in shorts.chars() {
                match short {
                    'h' => parsed.help = true,
                    'p' => parsed.pretend = true,
                    'v' => {}
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
        Some("help") => {
            let topic = args
                .iter()
                .filter(|arg| !arg.starts_with('-'))
                .nth(1)
                .and_then(|topic| find(topic));
            return Output::stdout(help(topic));
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
    let (parsed, error) = parse(args, command.map_or(&[], |command| command.flags));
    context.json = parsed.json;
    context.pretend = parsed.pretend;
    // A stub's own flags aren't known yet, so it doesn't refuse them; it fails below anyway. Nor
    // does a Mac-only command away from the Mac: `MacOnly` is what it answers, whatever it was given.
    let refuses_nothing = command.is_some_and(|command| {
        matches!(command.implementation, Implementation::Stub { .. })
            || (command.mac_only && context.platform != Platform::Mac)
    });
    if let Some(message) = error.filter(|_| !refuses_nothing) {
        return report(&context, None, Outcome::Usage(CliError::internal(message)));
    }
    let Some(command) = command else {
        return Output::stdout(help(None));
    };
    if parsed.help {
        return Output::stdout(help(Some(command)));
    }
    // Go checks a command's arguments before it runs, so the envelope names no command.
    let args = Args {
        positional: parsed.positional.iter().skip(1).cloned().collect(),
        values: parsed.values,
        flags: command.flags,
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
    // Then its required flags, as cobra checks them after the arguments.
    if let Some(message) =
        missing_required(command.flags, &args.values).filter(|_| !refuses_nothing)
    {
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
        match command.implementation {
            Implementation::Ported(run) => run(&context, &args),
            Implementation::Stub { ticket } => Outcome::Failed(CliError::internal(format!(
                "`workroom {}` isn't in this build yet ({ticket}); the Go CLI runs it until the \
                 switch (ADR 0078)",
                command.name
            ))),
        }
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
    let (command, error) = match outcome {
        Outcome::Printed(text) | Outcome::Success(text) => return Output::stdout(text),
        Outcome::PrintedWithErrors { stdout, stderr } => {
            return Output {
                stdout,
                stderr,
                code: 0,
            };
        }
        Outcome::Failed(error) => (command, error),
        Outcome::Usage(error) => (None, error),
    };
    match error {
        error if context.json => Output {
            stdout: envelope::failure(command, &error),
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
                stdout: String::new(),
                stderr,
                code: error.kind.exit_code(),
            }
        }
    }
}

/// The flags every command takes, as `--help` lists them.
const GLOBAL_FLAGS: &[(&str, &str)] = &[
    ("-h, --help", "help"),
    (
        "    --json",
        "Emit machine-readable JSON (exactly one object on stdout)",
    ),
    (
        "-p, --pretend",
        "Run through the command without making changes (dry run)",
    ),
    ("-v, --verbose", "Print detailed and verbose output"),
];

/// `--help`'s flag table: the global flags, then `own`, each usage in one column.
fn flag_table(own: &[Flag]) -> String {
    let mut rows: Vec<(String, String)> = GLOBAL_FLAGS
        .iter()
        .map(|(name, usage)| (name.to_string(), usage.to_string()))
        .collect();
    for flag in own {
        let name = if flag.takes_value {
            format!("    --{} string", flag.name)
        } else {
            format!("    --{}", flag.name)
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
                command.short,
                mark(command),
                command.usage
            );
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
            shown.push(("help", "Help about any command".to_string()));
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
                platform,
                env: |_| None,
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
            &["create", "--json", "--no-editor"],
            &["add-project", "/tmp/x", "--json"],
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
                "--global=false".to_string(),
                "-p".to_string(),
            ],
            find("base").unwrap().flags,
        );
        assert_eq!(parsed.values, [("global", "false".to_string())]);
        assert!(parsed.pretend);
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
                takes_value: true,
                usage: "",
                default: "",
                required: true,
            },
            Flag {
                name: "from",
                takes_value: true,
                usage: "",
                default: "",
                required: true,
            },
            Flag {
                name: "other",
                takes_value: true,
                usage: "",
                default: "",
                required: false,
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
    fn on_the_mac_an_unported_command_says_so_rather_than_mac_only() {
        let ((stdout, _), code) = run_on(Platform::Mac, &["create", "--json", "--project", "x"]);
        assert_eq!(code, 1);
        let envelope: serde_json::Value = serde_json::from_str(&stdout).unwrap();
        assert_eq!(envelope["error"]["kind"], "InternalError");
        assert_eq!(envelope["command"], "create");
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
