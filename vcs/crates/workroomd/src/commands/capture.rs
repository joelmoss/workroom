//! `workroom capture TARGET`: a session's screen as text, from the terminal API's
//! `terminal.capture` (#686). The visible screen by default; `--lines N` adds N rows of history
//! above it, `--all` the whole scrollback, `--unwrap` joins lines the pane wrapped and `--vt`
//! keeps escape codes. With `--json`, one envelope with the API's reply as it is, which adds the
//! cursor, size, alternate screen and title; with `--all`, one envelope per chunk, each written
//! as it arrives, so a long history never sits whole in this process.

use std::io::Write;

use serde_json::{Value, json};

use super::kind::CliError;
use super::{Args, Context, Flag, Outcome, terminal_api};

pub(super) const FLAGS: &[Flag] = &[
    Flag {
        name: "all",
        usage: "The whole scrollback, streamed (one envelope per chunk with --json)",
        hidden: false,
        ..Flag::BOOL
    },
    Flag {
        name: "lines",
        usage: "Rows of history above the visible screen to add",
        default: "0",
        hidden: false,
        ..Flag::VALUE
    },
    Flag {
        name: "unwrap",
        usage: "Join lines the pane wrapped",
        hidden: false,
        ..Flag::BOOL
    },
    Flag {
        name: "vt",
        usage: "Keep escape codes (colours and styles)",
        hidden: false,
        ..Flag::BOOL
    },
];

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    let params = match params(args) {
        Ok(params) => params,
        // Go checks arguments and flags before the command runs, so the envelope names no command.
        Err(error) => return Outcome::Usage(error),
    };
    // Each reply goes to stdout as it arrives, until the one with no `more` behind it. What is left
    // to report, a failure, follows them.
    let mut stdout = std::io::stdout().lock();
    let streamed = terminal_api::stream(context, "terminal.capture", params, |replied| {
        let out = if context.json {
            super::envelope::success("capture", &replied.result)
        } else {
            text(&replied.result, !replied.more)
        };
        // A reader that went away (`| head`) ends the stream.
        stdout.write_all(out.as_bytes()).is_ok() && stdout.flush().is_ok()
    });
    drop(stdout);
    match streamed {
        Ok(()) => Outcome::Printed(String::new()),
        Err(error) => Outcome::Failed(error),
    }
}

/// A reply's text for a person: as the daemon sent it, ending with a newline once it is the
/// capture's last, unless it is empty.
fn text(result: &Value, last: bool) -> String {
    let mut text = result["text"].as_str().unwrap_or_default().to_string();
    if last && !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
    text
}

/// The request's parameters, or the usage error the command line makes: cobra's for the one
/// TARGET, pflag's for an `--lines` that is not a count, and cobra's for flags that exclude each
/// other.
fn params(args: &Args) -> Result<Value, CliError> {
    let [target] = args.positional.as_slice() else {
        return Err(CliError::internal(format!(
            "accepts 1 arg(s), received {}",
            args.positional.len()
        )));
    };
    let lines = args.value("lines");
    let count = match lines {
        None => None,
        Some(given) => Some(given.parse::<u32>().map_err(|_| {
            CliError::internal(format!(
                "invalid argument {given:?} for \"--lines\" flag: a count of rows from 0"
            ))
        })?),
    };
    if args.is_set("all") && lines.is_some() {
        return Err(CliError::internal(
            "if any flags in the group [all lines] are set none of the others can be; [all lines] \
             were all set",
        ));
    }
    let mut params = json!({
        "target": target,
        "unwrap": args.is_set("unwrap"),
        "vt": args.is_set("vt"),
    });
    match count {
        _ if args.is_set("all") => params["all"] = json!(true),
        Some(count) => params["lines"] = json!(count),
        None => {}
    }
    Ok(params)
}
