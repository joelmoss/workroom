//! `workroom api list | describe <method> | call <method> [<json>|@<file>|-]`: raw access to every
//! terminal API method (#360, ADR 0079), so a coding agent can use the API from this alone. Each
//! subcommand asks the daemon, never this binary's own table, so it says what the daemon it reaches
//! supports, on the Mac or on a host.

use std::io::Read;

use serde::Serialize;
use serde_json::{Value, json};

use super::kind::{CliError, Kind};
use super::{Args, Context, Outcome, terminal_api};

/// What `workroom api --help` says first.
pub(super) const LONG: &str = "Raw access to every terminal API method, on the daemon \
WORKROOM_DAEMON names. `api list` lists the methods, `api describe METHOD` shows the JSON Schema \
of its parameters and its result, with examples, and `api call METHOD [PARAMS]` calls it. PARAMS \
is a JSON object given inline, @FILE to read it from a file, or - to read it from stdin; left out, \
it is {}. With --json, `api call` prints the method's reply in the envelope: its `result`, and \
the API's `revision`.";

/// What `workroom api` alone prints, as cobra shows a command that has only subcommands.
const HELP: &str = "Raw access to every terminal API method: list them, describe one's parameter \
and result schemas, with examples, and call one with JSON parameters.

Usage:
  workroom api [command]

Available Commands:
  call        Call METHOD with JSON parameters: inline, @FILE, or - for stdin
  describe    Show METHOD's parameter and result schemas, with examples
  list        List every method the daemon has
";

/// Each subcommand's envelope names it, success and failure alike: one name per payload shape, as
/// Go's `trust status` is.
const LIST: &str = "api list";
const DESCRIBE: &str = "api describe";
const CALL: &str = "api call";

/// `api list`'s payload: the API's revision, and each method's name and summary.
#[derive(Serialize)]
struct Listing {
    revision: Value,
    methods: Vec<Named>,
}

#[derive(Serialize)]
struct Named {
    name: String,
    summary: String,
}

/// `api describe`'s payload: the API's revision, the method's description as `api.describe` gives
/// it, and the schema of a failed reply's `error` as `error_schema`, since every failure envelope's
/// `error` is the failure itself.
#[derive(Serialize)]
struct Description {
    revision: Value,
    method: Value,
    error_schema: Value,
}

/// `api call`'s payload: the method called, and its reply's `revision` and `result`, nested so
/// that no result field can stand in for one of the envelope's own.
#[derive(Serialize)]
struct Called<'a> {
    method: &'a str,
    revision: Value,
    result: Value,
}

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    match args.positional.split_first() {
        Some((sub, rest)) if sub == "list" => list(context, rest),
        Some((sub, rest)) if sub == "describe" => describe(context, rest),
        Some((sub, rest)) if sub == "call" => call(context, rest),
        // A mistyped subcommand fails, so a script never reads the help as its envelope.
        Some((sub, _)) => Outcome::Usage(CliError::internal(format!(
            "unknown command {sub:?} for \"workroom api\""
        ))),
        None => Outcome::Printed(HELP.to_string()),
    }
}

/// `api call METHOD [PARAMS]`. PARAMS only has to be JSON here: the daemon decides whether the
/// method takes it, so every caller gets the same answer.
fn call(context: &Context, rest: &[String]) -> Outcome {
    let (method, params) = match rest {
        [method] => (method, json!({})),
        [method, given] => match params(given) {
            Ok(params) => (method, params),
            Err(error) => return Outcome::FailedIn(CALL, error),
        },
        _ => {
            return Outcome::Usage(CliError::internal(format!(
                "accepts between 1 and 2 arg(s), received {}",
                rest.len()
            )));
        }
    };
    let replied = match terminal_api::reply(context, method, params) {
        Ok(replied) => replied,
        Err(error) => return Outcome::FailedIn(CALL, error),
    };
    if !context.json {
        return Outcome::Printed(pretty(&replied.result));
    }
    Outcome::Success(super::envelope::success(
        CALL,
        &Called {
            method,
            revision: replied.revision,
            result: replied.result,
        },
    ))
}

/// PARAMS as given: JSON inline, `@FILE` for a file's, or `-` for stdin's. Anything that isn't
/// JSON is a malformed request, `InvalidRequest`.
fn params(given: &str) -> Result<Value, CliError> {
    let invalid = |message: String| CliError::new(Kind::InvalidRequest, message);
    let (text, from) = if given == "-" {
        let mut text = String::new();
        std::io::stdin()
            .read_to_string(&mut text)
            .map_err(|error| invalid(format!("can't read PARAMS from stdin: {error}")))?;
        (text, "stdin")
    } else if let Some(path) = given.strip_prefix('@') {
        let text = std::fs::read_to_string(path)
            .map_err(|error| invalid(format!("can't read PARAMS from {path}: {error}")))?;
        (text, path)
    } else {
        (given.to_string(), "the command line")
    };
    serde_json::from_str(&text)
        .map_err(|error| invalid(format!("PARAMS from {from} is not JSON: {error}")))
}

/// cobra's `ExactArgs(1)` error.
fn one_arg(rest: &[String]) -> Result<&str, Outcome> {
    match rest {
        [one] => Ok(one),
        _ => Err(Outcome::Usage(CliError::internal(format!(
            "accepts 1 arg(s), received {}",
            rest.len()
        )))),
    }
}

/// `value` as indented JSON and a newline, for a person.
fn pretty(value: &Value) -> String {
    let mut text = serde_json::to_string_pretty(value).expect("JSON serializes");
    text.push('\n');
    text
}

fn describe(context: &Context, rest: &[String]) -> Outcome {
    let name = match one_arg(rest) {
        Ok(name) => name,
        Err(usage) => return usage,
    };
    let mut described = match terminal_api::call(context, "api.describe", json!({"method": name})) {
        Ok(described) => described,
        Err(error) => return Outcome::FailedIn(DESCRIBE, error),
    };
    let method = described["methods"][0].take();
    if !context.json {
        return Outcome::Printed(pretty(&method));
    }
    Outcome::Success(super::envelope::success(
        DESCRIBE,
        &Description {
            revision: described["revision"].take(),
            method,
            error_schema: described["error"].take(),
        },
    ))
}

/// `"unknown command"` for an argument a subcommand doesn't take, as cobra words it.
fn no_more(sub: &str, rest: &[String]) -> Option<Outcome> {
    rest.first().map(|extra| {
        Outcome::Usage(CliError::internal(format!(
            "unknown command {extra:?} for \"workroom api {sub}\""
        )))
    })
}

fn list(context: &Context, rest: &[String]) -> Outcome {
    if let Some(usage) = no_more("list", rest) {
        return usage;
    }
    let described = match terminal_api::call(context, "api.describe", json!({})) {
        Ok(described) => described,
        Err(error) => return Outcome::FailedIn(LIST, error),
    };
    let text = |value: &Value| value.as_str().unwrap_or_default().to_string();
    let methods: Vec<Named> = described["methods"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|method| Named {
            name: text(&method["name"]),
            summary: text(&method["summary"]),
        })
        .collect();
    if context.json {
        return Outcome::Success(super::envelope::success(
            LIST,
            &Listing {
                revision: described["revision"].clone(),
                methods,
            },
        ));
    }
    let width = methods
        .iter()
        .map(|method| method.name.len())
        .max()
        .unwrap_or(0);
    let lines: String = methods
        .iter()
        .map(|method| format!("{:width$}  {}\n", method.name, method.summary))
        .collect();
    Outcome::Printed(lines)
}

#[cfg(test)]
mod tests {
    use super::super::{Context, Output, Platform, run};

    fn run_on(platform: Platform, args: &[&str]) -> Output {
        let args: Vec<String> = args.iter().map(|arg| arg.to_string()).collect();
        run(
            &args,
            Context {
                json: false,
                pretend: false,
                verbose: false,
                platform,
                env: |_| None,
                color: false,
            },
        )
    }

    /// Like every terminal API command, `api` runs anywhere, and with no daemon named it exits 7.
    #[test]
    fn api_runs_anywhere_and_with_no_daemon_named_exits_7() {
        for platform in [Platform::Mac, Platform::Other] {
            for (args, command) in [
                (&["api", "list", "--json"][..], "api list"),
                (
                    &["api", "describe", "session.list", "--json"],
                    "api describe",
                ),
                (&["api", "call", "session.list", "--json"], "api call"),
            ] {
                let output = run_on(platform, args);
                assert_eq!((output.code, output.stderr.as_str()), (7, ""), "{args:?}");
                let envelope: serde_json::Value = serde_json::from_str(&output.stdout).unwrap();
                assert_eq!(envelope["error"]["kind"], "DaemonUnreachable");
                // Each subcommand's failure names it, as its success does.
                assert_eq!(envelope["command"], command);
            }
        }
    }

    /// PARAMS is read before any daemon is asked, so a file that can't be read is bad input (2),
    /// not an unreachable daemon. (`-` is the end-to-end tests', which give it a stdin.)
    #[test]
    fn params_from_a_missing_file_is_invalid_before_any_daemon_is_asked() {
        let output = run_on(
            Platform::Other,
            &["api", "call", "session.list", "@/nowhere/params.json"],
        );
        assert_eq!(output.code, 2, "{}", output.stderr);
        assert!(
            output
                .stderr
                .starts_with("Error: can't read PARAMS from /nowhere/params.json"),
            "{}",
            output.stderr
        );
    }

    #[test]
    fn a_lone_dash_is_an_argument_not_a_flag() {
        let (parsed, error) =
            super::super::parse(&["api".into(), "call".into(), "m".into(), "-".into()], &[]);
        assert_eq!(error, None);
        assert_eq!(parsed.positional, ["api", "call", "m", "-"]);
    }

    #[test]
    fn api_alone_shows_its_subcommands_and_its_help_explains_params() {
        let output = run_on(Platform::Other, &["api"]);
        assert_eq!(output.code, 0);
        assert!(
            output
                .stdout
                .contains("\n  call        Call METHOD with JSON parameters"),
            "{}",
            output.stdout
        );
        // A mistyped one is a bad command line, so a script never reads the help as an envelope.
        let typo = run_on(Platform::Other, &["api", "lst", "--json"]);
        assert_eq!(typo.code, 1);
        let envelope: serde_json::Value = serde_json::from_str(&typo.stdout).unwrap();
        assert_eq!(
            envelope["error"]["message"],
            "unknown command \"lst\" for \"workroom api\""
        );
        let help = run_on(Platform::Other, &["api", "--help"]);
        assert!(help.stdout.starts_with(super::LONG), "{}", help.stdout);
        assert!(help.stdout.contains("\nUsage:\n  workroom api [command]\n"));
        let all = run_on(Platform::Mac, &["--help"]);
        assert!(
            all.stdout.contains(
                "\n  api               List, describe and call the terminal API's methods\n"
            ),
            "{}",
            all.stdout
        );
    }
}
