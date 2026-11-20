//! The CLI's commands (ADR 0078): `workroom <command>` runs one and exits, as the Go CLI did,
//! in its own process and never inside the daemon. The daemon's own subcommands (`serve`, `attach`,
//! `list --socket` and the rest that ADR 0057 pins) are still `main.rs`'s; [`dispatch`] leaves
//! them alone.
//!
//! Every command keeps ADR 0013's contract, byte for byte as Go wrote it: one envelope on stdout
//! under `--json` (`envelope`), NDJSON logs on stderr (`log`), and a stable `kind` and exit
//! code for each failure (`kind`). Human output keeps Go's information but may change wording.
//!
//! The commands that read or write the Mac's config are Mac-only: listed in `--help` everywhere,
//! marked "(Mac only)", and failing with `MacOnly` anywhere else. Until its own ticket ports it
//! (#671–#679), each of those, and `update`, is a stub here; the Go CLI still runs them.

pub(crate) mod channel;
mod envelope;
mod kind;
mod log;
mod version;

use std::ffi::OsString;
use std::io::Write;
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

/// The daemon's own subcommands, which `main.rs` runs (ADR 0057 pins their names). `list` is
/// the daemon's only with `--socket`; without it, it is the CLI's workroom list.
const DAEMON_SUBCOMMANDS: &[&str] = &[
    "serve",
    "attach",
    "relay",
    "program-status",
    "hand-off",
    "handoff-check",
    "credential",
    "run-script",
    "run-supervisor",
    "protocol",
];

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
    platform: Platform,
    env: fn(&str) -> Option<String>,
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
    /// A success envelope, exit 0.
    Success(String),
    /// A failure, reported in the error envelope under `--json`, else as an `Error:` line.
    Failed(CliError),
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
    /// The command, or `None` while its port is still to come (the ticket that ports it).
    run: Option<fn(&Context) -> Outcome>,
    port: &'static str,
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
    stub(
        "base",
        &[],
        "base",
        "Set or clear the branch new workrooms start from",
        false,
        true,
        "#673",
    ),
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
    stub(
        "include-archive",
        &[],
        "include-archive",
        "Write the project's included files to a tar (used by the desktop app)",
        true,
        true,
        "#675",
    ),
    stub(
        "list",
        &["ls", "l"],
        "list",
        "List all workrooms for the current project",
        false,
        true,
        "#671",
    ),
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
        run: Some(version::run),
        port: "",
    },
];

const fn stub(
    name: &'static str,
    aliases: &'static [&'static str],
    usage: &'static str,
    short: &'static str,
    hidden: bool,
    mac_only: bool,
    port: &'static str,
) -> Command {
    Command {
        name,
        aliases,
        usage,
        short,
        hidden,
        mac_only,
        run: None,
        port,
    }
}

fn find(name: &str) -> Option<&'static Command> {
    COMMANDS
        .iter()
        .find(|command| command.name == name || command.aliases.contains(&name))
}

/// Runs the CLI command `args` names and returns its exit code, or `None` when `args` are one of
/// the daemon's subcommands, for `main.rs` to run as before.
pub fn dispatch(args: &[OsString]) -> Option<ExitCode> {
    let first = args.first().and_then(|arg| arg.to_str());
    let socket = args.iter().any(|arg| {
        let arg = arg.to_string_lossy();
        arg == "--socket" || arg.starts_with("--socket=")
    });
    match first {
        Some(name) if DAEMON_SUBCOMMANDS.contains(&name) => return None,
        Some("list") if socket => return None,
        _ => {}
    }
    // As Go reads os.Args: bytes, with each one that isn't UTF-8 read as U+FFFD.
    let args: Vec<String> = args
        .iter()
        .map(|arg| log::go_lossy(arg.as_encoded_bytes()))
        .collect();
    let context = |json| Context {
        json,
        platform: Platform::current(),
        env: |name| std::env::var(name).ok(),
    };
    let (text, code) = run(&args, &context);
    let (stdout, stderr) = text;
    let _ = std::io::stdout().write_all(stdout.as_bytes());
    let _ = std::io::stderr().write_all(stderr.as_bytes());
    Some(ExitCode::from(code))
}

/// The global flags, and what is left once they are taken out.
#[derive(Default)]
struct Parsed {
    json: bool,
    help: bool,
    positional: Vec<String>,
}

/// Reads the arguments left to right, as Go's flag parser does: a bad flag stops it, with what was
/// set before it (so `--json --bogus` reports in the envelope and `--bogus --json` doesn't).
fn parse(args: &[String]) -> (Parsed, Option<String>) {
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
            match name {
                "json" => parsed.json = on,
                "help" => parsed.help = on,
                "pretend" | "verbose" => {}
                _ => return (parsed, Some(format!("unknown flag: --{name}"))),
            }
        } else if let Some(shorts) = arg.strip_prefix('-').filter(|shorts| !shorts.is_empty()) {
            for short in shorts.chars() {
                match short {
                    'h' => parsed.help = true,
                    'p' | 'v' => {}
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

/// Runs `args`, returning (stdout, stderr) and the exit code. Separate from [`dispatch`] so a test
/// can choose the platform and the environment.
fn run(args: &[String], context: &dyn Fn(bool) -> Context) -> ((String, String), u8) {
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
            return ((help(topic), String::new()), 0);
        }
        Some(name) => match find(name) {
            Some(command) => Some(command),
            // Go reports this before its flags are parsed, so never in an envelope.
            None => {
                let message = format!("unknown command {name:?} for \"workroom\"");
                return ((String::new(), format!("Error: {message}\n")), 1);
            }
        },
    };
    // A stub's own flags aren't known yet; it fails before it would read them.
    if let Some(command) = command.filter(|command| command.run.is_none()) {
        let (parsed, _) = parse(args);
        if parsed.help {
            return ((help(Some(command)), String::new()), 0);
        }
        let context = context(parsed.json);
        return report(
            &context,
            Some(command.name),
            Outcome::Failed(not_here(command, context.platform)),
        );
    }
    let (parsed, error) = parse(args);
    let context = context(parsed.json);
    if let Some(message) = error {
        return report(&context, None, Outcome::Failed(CliError::internal(message)));
    }
    let Some(command) = command else {
        return ((help(None), String::new()), 0);
    };
    if parsed.help {
        return ((help(Some(command)), String::new()), 0);
    }
    // The only argument is the command's name; none of today's commands takes more.
    if let Some(extra) = parsed.positional.get(1) {
        let message = format!(
            "unknown command {extra:?} for \"workroom {}\"",
            command.name
        );
        return report(&context, None, Outcome::Failed(CliError::internal(message)));
    }
    if command.mac_only && context.platform != Platform::Mac {
        return report(
            &context,
            Some(command.name),
            Outcome::Failed(mac_only(command)),
        );
    }
    let run = command.run.expect("a ported command runs");
    report(&context, Some(command.name), run(&context))
}

/// Why a command can't run in this binary yet: Mac-only away from the Mac, else not ported.
fn not_here(command: &Command, platform: Platform) -> CliError {
    if command.mac_only && platform != Platform::Mac {
        return mac_only(command);
    }
    CliError::internal(format!(
        "`workroom {}` isn't in this build yet ({}); the Go CLI runs it until the switch (ADR 0078)",
        command.name, command.port
    ))
}

fn mac_only(command: &Command) -> CliError {
    CliError::new(
        Kind::MacOnly,
        format!(
            "`workroom {}` works only on the Mac: it reads and writes the Mac's Workroom config",
            command.name
        ),
    )
}

/// `outcome` as stdout, stderr and the exit code.
fn report(context: &Context, command: Option<&str>, outcome: Outcome) -> ((String, String), u8) {
    match outcome {
        Outcome::Printed(text) | Outcome::Success(text) => ((text, String::new()), 0),
        Outcome::Failed(error) => {
            let code = error.kind.exit_code();
            if context.json {
                ((envelope::failure(command, &error), String::new()), code)
            } else {
                ((String::new(), format!("Error: {}\n", error.message)), code)
            }
        }
    }
}

const GLOBAL_FLAGS: &str = "  -h, --help      help
      --json      Emit machine-readable JSON (exactly one object on stdout)
  -p, --pretend   Run through the command without making changes (dry run)
  -v, --verbose   Print detailed and verbose output
";

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
            text + "\nFlags:\n" + GLOBAL_FLAGS
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
                + GLOBAL_FLAGS
                + "\nUse \"workroom [command] --help\" for more information about a command.\n"
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_on(platform: Platform, args: &[&str]) -> ((String, String), u8) {
        let args: Vec<String> = args.iter().map(|arg| arg.to_string()).collect();
        run(&args, &|json| Context {
            json,
            platform,
            env: |_| None,
        })
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
    fn the_daemons_subcommands_are_left_to_main() {
        let args = |list: &[&str]| list.iter().map(OsString::from).collect::<Vec<_>>();
        assert!(dispatch(&args(&["serve", "--socket", "/x"])).is_none());
        assert!(dispatch(&args(&["list", "--socket", "/x"])).is_none());
        assert!(dispatch(&args(&["list", "--socket=/x"])).is_none());
        assert!(dispatch(&args(&["protocol"])).is_none());
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
