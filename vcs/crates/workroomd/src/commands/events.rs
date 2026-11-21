//! `workroom events` (#687): the daemon's events, from the terminal API's `events.subscribe`, one
//! JSON object per line: the sessions as they are (one `session` each), `snapshot-complete`, then
//! each session created and ended, each change of a coding agent's program status, each run
//! state and each client attaching and detaching as it happens, every one with the `boot` and `revision` it is numbered by. With `--json`,
//! each is one ADR 0013 envelope per line instead, the event's fields in it. By default the
//! caller's scope's events (its workroom's, or every session's from no pane); `--workroom`,
//! `--all`, `--session` and `--type` say whose and which. It runs until it is stopped, or its
//! reader goes away, and goes on across the daemon's hand-off (`terminal_api::stream`).

use std::io::Write;

use serde_json::{Map, Value, json};

use super::kind::CliError;
use super::{Args, Context, Flag, Outcome, terminal_api};

pub(super) const FLAGS: &[Flag] = &[
    Flag {
        name: "all",
        usage: "Every session's events, not only the caller's workroom's",
        hidden: false,
        ..Flag::BOOL
    },
    Flag {
        name: "session",
        usage: "Only this session's events (a TARGET, as for sessions)",
        hidden: false,
        ..Flag::VALUE
    },
    Flag {
        name: "type",
        usage: "Only live events of this type, repeated or comma-separated: session.created, \
                session.ended, session.program_status, session.run_state, session.moved, \
                client.attached, client.detached or session.input",
        hidden: false,
        ..Flag::VALUE
    },
    Flag {
        name: "workroom",
        usage: "Only this workroom's sessions' events (its id, a session's scope id)",
        hidden: false,
        ..Flag::VALUE
    },
];

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    let params = match params(args) {
        Ok(params) => params,
        // Go checks the command line before the command runs, so the envelope names no command.
        Err(message) => return Outcome::Usage(CliError::internal(message)),
    };
    // Each event goes to stdout as it arrives, so a script reads it at once.
    let mut stdout = std::io::stdout().lock();
    let streamed = terminal_api::stream(context, "events.subscribe", params, |replied| {
        // Where a filtered stream stands, for resuming (`terminal_api::stream`): nothing to show.
        if replied.result["event"] == "place" {
            return true;
        }
        let mut line = if context.json {
            super::envelope::success("events", &replied.result)
        } else {
            replied.result.to_string()
        };
        if !line.ends_with('\n') {
            line.push('\n');
        }
        // A reader that went away (`| head`) ends the stream.
        stdout.write_all(line.as_bytes()).is_ok() && stdout.flush().is_ok()
    });
    drop(stdout);
    match streamed {
        Ok(()) => Outcome::Printed(String::new()),
        Err(error) => Outcome::Failed(error),
    }
}

/// The request the command line makes, or the usage error in it.
fn params(args: &Args) -> Result<Value, String> {
    if let Some(extra) = args.positional.first() {
        return Err(format!("unknown command {extra:?} for \"workroom events\""));
    }
    let mut params = Map::new();
    if args.is_set("all") {
        if args.value("workroom").is_some() {
            return Err(
                "if any flags in the group [all workroom] are set none of the others can be; \
                 [all workroom] were all set"
                    .into(),
            );
        }
        params.insert("all".into(), json!(true));
    }
    for key in ["workroom", "session"] {
        if let Some(value) = args.value(key) {
            params.insert(key.into(), json!(value));
        }
    }
    let types: Vec<&str> = args
        .values
        .iter()
        .filter(|(flag, _)| *flag == "type")
        .flat_map(|(_, value)| value.split(','))
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .collect();
    if !types.is_empty() {
        params.insert("types".into(), json!(types));
    }
    Ok(Value::Object(params))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(argv: &[&str]) -> Result<Value, String> {
        let argv: Vec<String> = argv.iter().map(|arg| (*arg).to_string()).collect();
        let (parsed, error) = super::super::parse(&argv, FLAGS);
        assert_eq!(error, None, "{argv:?}");
        params(&Args {
            positional: parsed.positional,
            values: parsed.values,
            flags: FLAGS,
        })
    }

    #[test]
    fn types_are_repeated_or_comma_separated_and_all_excludes_a_workroom() {
        assert_eq!(request(&[]), Ok(json!({})));
        assert_eq!(
            request(&[
                "--type",
                "session.created, session.ended",
                "--type=session.run_state"
            ]),
            Ok(json!({"types": ["session.created", "session.ended", "session.run_state"]}))
        );
        assert_eq!(
            request(&["--session", "server", "--workroom", "wr-1"]),
            Ok(json!({"session": "server", "workroom": "wr-1"}))
        );
        assert_eq!(request(&["--all"]), Ok(json!({"all": true})));
        assert!(request(&["--all", "--workroom", "wr-1"]).is_err());
        assert!(request(&["extra"]).is_err());
    }
}
