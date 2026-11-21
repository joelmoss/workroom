//! `workroom prompt TARGET [TEXT] [--wait]` (#692): gives the coding agent in a terminal session a
//! prompt in one step, from the terminal API's `terminal.prompt`: TEXT (or with `--stdin`,
//! stdin's text) as a bracketed paste, then Enter. A session that runs no coding agent exits 3
//! (`NotAnAgent`), and so does an agent that is working, waiting on the user or has no prompt up
//! (`AgentBusy`). With `--wait` it returns once the turn the prompt starts has ended, never on the
//! status left from the turn before, printing the status it ended in (`--json`: the envelope with
//! the API's last result); `--timeout` gives up, exiting 8 (`WaitTimeout`) with the prompt still
//! typed. A hand-off of the daemon after the prompt was typed goes on waiting in the new program
//! (`terminal_api::stream`). Named `prompt_agent` as a module because `prompt` is the CLI's y/N
//! questions.

use serde_json::{Map, Value, json};

use super::kind::CliError;
use super::send::{Refused, read_text, too_large};
use super::{Args, Context, Flag, Outcome, terminal_api};
use crate::terminal::api::SEND_MAX_BYTES;

pub(super) const FLAGS: &[Flag] = &[
    Flag {
        name: "allow-self",
        usage: "Prompt the session this command runs in, which is otherwise refused",
        hidden: false,
        ..Flag::BOOL
    },
    Flag {
        name: "stdin",
        usage: "Prompt with stdin's text, exactly as it comes, in place of TEXT",
        hidden: false,
        ..Flag::BOOL
    },
    Flag {
        name: "timeout",
        usage: "With --wait, give up after this long (such as 30s or 10m), exiting 8; no limit \
                when not given",
        hidden: false,
        ..Flag::VALUE
    },
    Flag {
        name: "wait",
        usage: "Return once the turn the prompt starts has ended, printing the status it ended \
                in: done, blocked, idle or error",
        hidden: false,
        ..Flag::BOOL
    },
];

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    let params = match params(args) {
        Ok(params) => params,
        // Go checks the command line before the command runs, so the envelope names no command.
        Err(Refused::Usage(message)) => return Outcome::Usage(CliError::internal(message)),
        Err(Refused::Input(error)) => return Outcome::Failed(error),
    };
    let wait = params.contains_key("wait");
    // Every reply but the last says how far the prompt has got; the last is its answer.
    let mut last = Value::Null;
    let streamed = terminal_api::stream(
        context,
        "terminal.prompt",
        Value::Object(params),
        |replied| {
            last = replied.result;
            true
        },
    );
    match streamed {
        Err(error) => Outcome::Failed(error),
        Ok(()) if context.json => Outcome::Success(super::envelope::success("prompt", &last)),
        Ok(()) if wait => Outcome::Printed(format!(
            "status: {}\n",
            last["status"]
                .as_str()
                .unwrap_or("none, the agent's report went")
        )),
        Ok(()) => Outcome::Printed(String::new()),
    }
}

/// The request the command line makes, reading stdin's text with `--stdin`.
fn params(args: &Args) -> Result<Map<String, Value>, Refused> {
    request(args, || read_text(&mut std::io::stdin().lock()))
}

/// [`params`], with `stdin` reading the text when `--stdin` asks for it.
fn request(
    args: &Args,
    stdin: impl FnOnce() -> Result<String, Refused>,
) -> Result<Map<String, Value>, Refused> {
    let from_stdin = args.is_set("stdin");
    let (target, given) = match (args.positional.as_slice(), from_stdin) {
        ([], _) => {
            return Err(Refused::Usage(
                "`workroom prompt` needs a TARGET: the session whose coding agent to prompt".into(),
            ));
        }
        ([_], false) => {
            return Err(Refused::Usage(
                "`workroom prompt` needs the prompt: TEXT, or --stdin".into(),
            ));
        }
        ([target], true) => (target, None),
        ([target, text], false) => (target, Some(text.clone())),
        ([_, _], true) => {
            return Err(Refused::Usage(
                "`workroom prompt` takes TEXT or --stdin, not both".into(),
            ));
        }
        ([_, _, extra, ..], _) => {
            return Err(Refused::Usage(format!(
                "unknown command {extra:?} for \"workroom prompt\": TEXT is one argument, so \
                 quote it"
            )));
        }
    };
    let wait = args.is_set("wait");
    let timeout = args.value("timeout");
    if timeout.is_some() && !wait {
        return Err(Refused::Usage(
            "`workroom prompt`'s --timeout goes with --wait".into(),
        ));
    }
    let timeout_ms = timeout
        .map(|timeout| {
            super::wait::parse_duration(timeout)
                .map(|duration| u64::try_from(duration.as_millis()).unwrap_or(u64::MAX))
                .ok_or_else(|| {
                    Refused::Usage(format!(
                        "invalid argument {timeout:?} for \"--timeout\" flag: time: invalid \
                         duration {timeout:?}"
                    ))
                })
        })
        .transpose()?;
    let text = match given {
        Some(text) => text,
        None => stdin()?,
    };
    if text.len() > SEND_MAX_BYTES {
        return Err(Refused::Input(too_large(text.len())));
    }
    let mut params = Map::new();
    params.insert("target".into(), json!(target));
    params.insert("text".into(), json!(text));
    if wait {
        params.insert("wait".into(), json!(true));
    }
    if let Some(millis) = timeout_ms {
        params.insert("timeout_ms".into(), json!(millis));
    }
    if args.is_set("allow-self") {
        params.insert("allow_self".into(), json!(true));
    }
    Ok(params)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn requested(argv: &[&str]) -> Result<Value, Refused> {
        let argv: Vec<String> = argv.iter().map(|arg| (*arg).to_string()).collect();
        let (parsed, error) = super::super::parse(&argv, FLAGS);
        assert_eq!(error, None, "{argv:?}");
        let args = Args {
            positional: parsed.positional,
            values: parsed.values,
            flags: FLAGS,
        };
        request(&args, || Ok("from stdin\n".to_string())).map(Value::Object)
    }

    /// The text as given or from stdin; `wait`, its timeout and `allow_self` only when asked.
    #[test]
    fn the_command_line_is_the_request() {
        assert_eq!(
            requested(&["claude", "fix the test"]),
            Ok(json!({"target": "claude", "text": "fix the test"}))
        );
        assert_eq!(
            requested(&[
                "claude",
                "--stdin",
                "--wait",
                "--timeout",
                "2m",
                "--allow-self"
            ]),
            Ok(json!({
                "target": "claude",
                "text": "from stdin\n",
                "wait": true,
                "timeout_ms": 120_000,
                "allow_self": true,
            }))
        );
        assert_eq!(
            requested(&["claude", "--", "-n"]),
            Ok(json!({"target": "claude", "text": "-n"}))
        );
    }

    /// A malformed command line is a usage error, found before anything is read or sent.
    #[test]
    fn a_command_line_without_a_prompt_or_with_too_much_is_a_usage_error() {
        for (argv, says) in [
            (&[][..], "needs a TARGET"),
            (&["claude"][..], "needs the prompt"),
            (&["claude", "a", "b"][..], "unknown command \"b\""),
            (&["claude", "a", "--stdin"][..], "TEXT or --stdin"),
            (&["claude", "a", "--timeout", "1s"][..], "goes with --wait"),
            (
                &["claude", "a", "--wait", "--timeout", "1d"][..],
                "invalid duration",
            ),
        ] {
            match requested(argv) {
                Err(Refused::Usage(message)) => assert!(message.contains(says), "{message}"),
                other => panic!("{argv:?}: {other:?}"),
            }
        }
    }
}
