//! `workroom command TARGET [--] COMMAND…` (#691): runs one shell command in a terminal session,
//! from the terminal API's `terminal.command`, and exits with the command's own exit code. Its
//! words are joined with spaces into one line, as `ssh` joins a remote command's, so quoting in it
//! is the session's shell's to read. Without `--json` it prints what the command printed; with it,
//! one envelope with the API's result: `exit_code`, `output` and `truncated`.
//!
//! **Its failures and the command's.** When `command` itself fails (the target, the session, the
//! daemon, the timeout), it exits with its error's code from the registry every command shares
//! (3, 7, 8…), which a command can exit with too. So the exit code alone never says which failed:
//! with `--json` the envelope does (`ok`, and `error.kind` beside no `exit_code`), and without it
//! a failure of `command`'s own is an `Error:` line on stderr with nothing on stdout, while
//! everything the command printed, its errors included, is on stdout, since the pane's terminal
//! merges the two.

use serde_json::{Map, Value, json};

use super::kind::{CliError, Kind};
use super::{Args, Context, Flag, Outcome, terminal_api};
use crate::terminal::api::SEND_MAX_BYTES;

pub(super) const FLAGS: &[Flag] = &[
    Flag {
        name: "allow-self",
        usage: "Run it in the session this command runs in, which is otherwise refused",
        hidden: false,
        ..Flag::BOOL
    },
    Flag {
        name: "timeout",
        usage: "Give up after this long (such as 30s or 10m), exiting 8 and leaving the command \
                running; no limit when not given",
        hidden: false,
        ..Flag::VALUE
    },
];

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    let params = match params(args) {
        Ok(params) => params,
        // Go checks the command line before the command runs, so the envelope names no command.
        Err(Refused::Usage(message)) => return Outcome::Usage(CliError::internal(message)),
        Err(Refused::Input(error)) => return Outcome::Failed(error),
    };
    match terminal_api::call(context, "terminal.command", Value::Object(params)) {
        Err(error) => Outcome::Failed(error),
        Ok(result) => {
            let code = exit_status(&result["exit_code"]);
            let outcome = if context.json {
                Outcome::Success(super::envelope::success("command", &result))
            } else {
                printed(&result)
            };
            Outcome::Status(code, Box::new(outcome))
        }
    }
}

/// Why the command line makes no request.
#[derive(Debug, PartialEq)]
enum Refused {
    /// A malformed command line: 1, as for every command.
    Usage(String),
    /// A command no request may carry: over the limit.
    Input(CliError),
}

/// The request the command line makes.
fn params(args: &Args) -> Result<Map<String, Value>, Refused> {
    let (target, words) = match args.positional.split_first() {
        None => {
            return Err(Refused::Usage(
                "`workroom command` needs a TARGET: the session to run the command in".into(),
            ));
        }
        Some((_, [])) => {
            return Err(Refused::Usage(
                "`workroom command` needs a COMMAND to run, after the TARGET (and `--` when it \
                 starts with a dash)"
                    .into(),
            ));
        }
        Some((target, words)) => (target, words),
    };
    let command = words.join(" ");
    if command.len() > SEND_MAX_BYTES {
        return Err(Refused::Input(CliError::new(
            Kind::TooLarge,
            format!(
                "the command is {} bytes, more than the {SEND_MAX_BYTES} one command types",
                command.len()
            ),
        )));
    }
    let mut params = Map::new();
    params.insert("target".into(), json!(target));
    params.insert("command".into(), json!(command));
    if args.is_set("allow-self") {
        params.insert("allow_self".into(), json!(true));
    }
    if let Some(timeout) = args.value("timeout") {
        let duration = super::wait::parse_duration(timeout).ok_or_else(|| {
            Refused::Usage(format!(
                "invalid argument {timeout:?} for \"--timeout\" flag: time: invalid duration \
                 {timeout:?}"
            ))
        })?;
        let millis = u64::try_from(duration.as_millis()).unwrap_or(u64::MAX);
        params.insert("timeout_ms".into(), json!(millis));
    }
    Ok(params)
}

/// The exit code `command` ends with: the command's own, 0 to 255 as a shell gives it, or 1 for
/// one it didn't give (its mark carried none) or that no process could exit with.
fn exit_status(exit_code: &Value) -> u8 {
    exit_code
        .as_i64()
        .and_then(|code| u8::try_from(code).ok())
        .unwrap_or(1)
}

/// What the command printed, for a person: its output and a newline, nothing for none. A cut
/// output says so on stderr, so stdout stays the command's.
fn printed(result: &Value) -> Outcome {
    let output = result["output"].as_str().unwrap_or_default();
    let stdout = if output.is_empty() {
        String::new()
    } else {
        format!("{output}\n")
    };
    if result["truncated"] == true {
        return Outcome::PrintedWithWarnings {
            stdout,
            warnings: "workroom: the command printed more than is kept, so this is its end\n"
                .into(),
        };
    }
    Outcome::Printed(stdout)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn requested(argv: &[&str]) -> Result<Value, Refused> {
        let argv: Vec<String> = argv.iter().map(|arg| (*arg).to_string()).collect();
        let (parsed, error) = super::super::parse(&argv, FLAGS);
        assert_eq!(error, None, "{argv:?}");
        params(&Args {
            positional: parsed.positional,
            values: parsed.values,
            flags: FLAGS,
        })
        .map(Value::Object)
    }

    /// The words after the target, joined with spaces as `ssh` joins them, after `--` or not; the
    /// timeout in milliseconds and `allow_self` only when asked.
    #[test]
    fn the_command_line_is_the_request() {
        assert_eq!(
            requested(&["tests", "--", "npm", "test", "--", "-t", "login"]),
            Ok(json!({"target": "tests", "command": "npm test -- -t login"}))
        );
        assert_eq!(
            requested(&[
                "tests",
                "--",
                "cargo",
                "test",
                "--json",
                "--verbose",
                "--help"
            ]),
            Ok(json!({"target": "tests", "command": "cargo test --json --verbose --help"})),
            "after `--`, the global flags are the command's"
        );
        assert_eq!(
            requested(&[
                "tests",
                "--timeout",
                "2m",
                "--allow-self",
                "make test && echo ok"
            ]),
            Ok(json!({
                "target": "tests",
                "command": "make test && echo ok",
                "timeout_ms": 120_000,
                "allow_self": true,
            }))
        );
    }

    #[test]
    fn a_command_line_without_a_command_or_with_a_bad_timeout_is_a_usage_error() {
        for (argv, says) in [
            (&[][..], "needs a TARGET"),
            (&["tests"][..], "needs a COMMAND"),
            (
                &["tests", "--timeout", "soon", "ls"][..],
                "invalid duration",
            ),
        ] {
            match requested(argv) {
                Err(Refused::Usage(message)) => assert!(message.contains(says), "{message}"),
                other => panic!("{argv:?}: {other:?}"),
            }
        }
        let long = "x".repeat(SEND_MAX_BYTES + 1);
        match requested(&["tests", &long]) {
            Err(Refused::Input(error)) => assert_eq!(error.kind, Kind::TooLarge),
            other => panic!("{other:?}"),
        }
    }

    /// The command's own code, but 1 for none and for one no process exits with.
    #[test]
    fn it_exits_with_the_commands_code() {
        for (code, exits) in [
            (json!(0), 0),
            (json!(3), 3),
            (json!(255), 255),
            (json!(null), 1),
            (json!(256), 1),
            (json!(-1), 1),
        ] {
            assert_eq!(exit_status(&code), exits, "{code}");
        }
    }
}
