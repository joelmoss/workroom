//! `workroom wait TARGET <condition> [--timeout DURATION]` (#690): waits, on the daemon, for one
//! thing to happen in a session, from the terminal API's `terminal.wait`. With `--json`, one
//! envelope with the API's result fields; without, a line saying what happened. A wait that runs
//! out of time exits 8, `WaitTimeout`.

use std::time::Duration;

use serde_json::{Map, Value, json};

use super::kind::CliError;
use super::{Args, Context, Flag, Outcome, terminal_api};

pub(super) const FLAGS: &[Flag] = &[
    value_flag(
        "status",
        "Wait for the coding agent's program status: idle, working, done, blocked or error",
    ),
    value_flag(
        "run",
        "Wait for a run session's state: starting, running, stopping, stopped or exited",
    ),
    value_flag(
        "exit-code",
        "With --run exited, only an exit with this code",
    ),
    value_flag(
        "regex",
        "Wait for output matching this regex, counting only output from now on",
    ),
    bool_flag(
        "include-screen",
        "With --regex, also match what is on the screen now",
    ),
    bool_flag("ended", "Wait for the session to end"),
    bool_flag(
        "command-finished",
        "Wait for the shell's current command to finish (needs shell integration)",
    ),
    value_flag(
        "timeout",
        "Give up after this long (such as 30s or 2m), exiting 8; no limit when not given",
    ),
];

const fn value_flag(name: &'static str, usage: &'static str) -> Flag {
    Flag {
        name,
        usage,
        ..Flag::VALUE
    }
}

const fn bool_flag(name: &'static str, usage: &'static str) -> Flag {
    Flag {
        name,
        usage,
        ..Flag::BOOL
    }
}

/// The conditions, as the flags name them and as the API's `params` do.
const CONDITIONS: [(&str, &str); 5] = [
    ("status", "status"),
    ("run", "run"),
    ("regex", "regex"),
    ("ended", "ended"),
    ("command-finished", "command_finished"),
];

/// The CLI waits for the daemon's answer as long as the wait may take, and a little more
/// (`terminal_api::answer_timeout`), as `api call terminal.wait` does.
pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    let params = match params(args) {
        Ok(params) => params,
        // Go checks the command line before the command runs, so the envelope names no command.
        Err(message) => return Outcome::Usage(CliError::internal(message)),
    };
    match terminal_api::call(context, "terminal.wait", Value::Object(params)) {
        Err(error) => Outcome::Failed(error),
        Ok(result) if context.json => Outcome::Success(super::envelope::success("wait", &result)),
        Ok(result) => Outcome::Printed(said(&result)),
    }
}

/// The request the command line makes, or the usage error in it.
fn params(args: &Args) -> Result<Map<String, Value>, String> {
    let target = match args.positional.as_slice() {
        [target] => target,
        [] => return Err("`workroom wait` needs a TARGET: the session to wait on".into()),
        [_, extra, ..] => return Err(format!("unknown command {extra:?} for \"workroom wait\"")),
    };
    let given: Vec<(&str, &str)> = CONDITIONS
        .into_iter()
        .filter(|(flag, _)| args.value(flag).is_some_and(|value| value != "false"))
        .collect();
    let [(flag, key)] = given.as_slice() else {
        return Err(
            "`workroom wait` takes exactly one of --status, --run, --regex, --ended or \
             --command-finished"
                .into(),
        );
    };
    let mut params = Map::new();
    params.insert("target".into(), json!(target));
    params.insert(
        (*key).into(),
        match args.value(flag) {
            Some("true") if matches!(*flag, "ended" | "command-finished") => json!(true),
            value => json!(value.unwrap_or_default()),
        },
    );
    if let Some(code) = args.value("exit-code") {
        let code: i32 = code.parse().map_err(|_| {
            format!("invalid argument {code:?} for \"--exit-code\" flag: not an integer")
        })?;
        params.insert("exit_code".into(), json!(code));
    }
    if args.is_set("include-screen") {
        params.insert("include_screen".into(), json!(true));
    }
    if let Some(timeout) = args.value("timeout") {
        let duration = parse_duration(timeout).ok_or_else(|| {
            format!(
                "invalid argument {timeout:?} for \"--timeout\" flag: time: invalid duration \
                 {timeout:?}"
            )
        })?;
        let millis = u64::try_from(duration.as_millis()).unwrap_or(u64::MAX);
        params.insert("timeout_ms".into(), json!(millis));
    }
    Ok(params)
}

/// A duration as Go's `time.ParseDuration` reads one: decimal numbers, each with a unit (`ns`,
/// `us`, `µs`, `ms`, `s`, `m`, `h`), run together (`1m30s`), or a bare `0`. Never negative.
pub(super) fn parse_duration(text: &str) -> Option<Duration> {
    if text == "0" {
        return Some(Duration::ZERO);
    }
    let mut rest = text.strip_prefix('+').unwrap_or(text);
    if rest.is_empty() {
        return None;
    }
    let mut total = 0f64;
    while !rest.is_empty() {
        let number_len = rest
            .find(|c: char| !c.is_ascii_digit() && c != '.')
            .unwrap_or(rest.len());
        let number = &rest[..number_len];
        if number.is_empty() || number == "." || number.matches('.').count() > 1 {
            return None;
        }
        let value: f64 = number.parse().ok()?;
        rest = &rest[number_len..];
        let unit_len = rest
            .find(|c: char| c.is_ascii_digit() || c == '.')
            .unwrap_or(rest.len());
        let seconds = match &rest[..unit_len] {
            "ns" => 1e-9,
            "us" | "µs" | "μs" => 1e-6,
            "ms" => 1e-3,
            "s" => 1.0,
            "m" => 60.0,
            "h" => 3600.0,
            _ => return None,
        };
        rest = &rest[unit_len..];
        total += value * seconds;
    }
    Duration::try_from_secs_f64(total).ok()
}

/// What happened, for a person.
fn said(result: &Value) -> String {
    let exit = || match result["exit_code"].as_i64() {
        Some(code) => format!(" (exit code {code})"),
        None => String::new(),
    };
    match result["condition"].as_str().unwrap_or_default() {
        "status" => format!(
            "status: {}\n",
            result["status"].as_str().unwrap_or_default()
        ),
        "run" => format!(
            "run: {}{}\n",
            result["run"].as_str().unwrap_or_default(),
            exit()
        ),
        "regex" => format!("{}\n", result["match"]["text"].as_str().unwrap_or_default()),
        "ended" => format!("ended{}\n", exit()),
        "command_finished" => format!("command finished{}\n", exit()),
        other => format!("{other}\n"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations_read_as_go_reads_them() {
        let ms = Duration::from_millis;
        for (text, want) in [
            ("0", Some(Duration::ZERO)),
            ("30s", Some(ms(30_000))),
            ("2m", Some(ms(120_000))),
            ("1h", Some(ms(3_600_000))),
            ("1m30s", Some(ms(90_000))),
            ("1.5s", Some(ms(1_500))),
            ("500ms", Some(ms(500))),
            ("+5s", Some(ms(5_000))),
            ("", None),
            ("5", None),
            ("-1s", None),
            ("1d", None),
            ("s", None),
            ("1..5s", None),
        ] {
            assert_eq!(
                parse_duration(text).map(|d| d.as_millis()),
                want.map(|d| d.as_millis()),
                "{text:?}"
            );
        }
    }
}
