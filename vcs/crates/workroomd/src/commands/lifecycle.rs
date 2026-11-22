//! `workroom new`, `workroom close TARGET` and `workroom run-control TARGET restart|stop` (#693):
//! the terminal API's `session.new`, `session.close` and `session.run_control`.
//!
//! `new` opens a terminal like the caller's, in its workroom, and the app shows it: a tab, or with
//! `--split` a split beside the caller's pane. It starts in this command's folder, or `--cwd`'s,
//! resolved here, since the daemon's folder is not the caller's. It prints the new session's id,
//! or with `--json` the envelope. It is the one command that starts a daemon when none is
//! listening (`terminal_api::stream`). `close` ends a session and the app closes its tab or split;
//! the caller's own is `RefusedSelf` (3) without `--allow-self`, as for `send`. `run-control`
//! restarts or stops a run session's command, `NotARun` (3) for any other session.

use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use super::kind::CliError;
use super::{Args, Context, Flag, Outcome, terminal_api};

pub(super) const NEW_FLAGS: &[Flag] = &[
    Flag {
        name: "title",
        usage: "Its name: the session's label, and its tab's name in the app",
        ..Flag::VALUE
    },
    Flag {
        name: "run",
        usage: "A command to run in it under a run supervisor, as the Run tab runs one, so \
                run-control restarts and stops it; a shell when not given",
        ..Flag::VALUE
    },
    Flag {
        name: "cwd",
        usage: "The folder it starts in; this command's folder when not given",
        ..Flag::VALUE
    },
    Flag {
        name: "split",
        usage: "Open it as a split beside this pane, right or down, when the pane is on screen; \
                a tab otherwise",
        ..Flag::VALUE
    },
];

pub(super) const CLOSE_LONG: &str = "Close a terminal session, and its tab or split in the app.\n\n\
TARGET is the session's id, the end of its id (4 characters or more) or its label. Never its live \
title, as other commands take: its program sets that, and anything it prints can change it, and \
a close can't be undone. The session this command runs in is refused unless --allow-self is \
given.";

pub(super) const CLOSE_FLAGS: &[Flag] = &[Flag {
    name: "allow-self",
    usage: "Close the session this command runs in, which is otherwise refused",
    ..Flag::BOOL
}];

pub(super) fn run_new(context: &Context, args: &Args) -> Outcome {
    let here = std::env::current_dir().ok();
    let params = match new_request(args, here.as_deref()) {
        Ok(params) => params,
        Err(message) => return Outcome::Usage(CliError::internal(message)),
    };
    match terminal_api::call(context, "session.new", Value::Object(params)) {
        Err(error) => Outcome::Failed(error),
        Ok(result) if context.json => Outcome::Success(super::envelope::success("new", &result)),
        Ok(result) => Outcome::Printed(format!(
            "{}\n",
            result["session"]["id"].as_str().unwrap_or_default()
        )),
    }
}

/// The request `new`'s command line makes, its folder `--cwd` resolved against `here` (this
/// process's folder), or `here` itself.
fn new_request(args: &Args, here: Option<&Path>) -> Result<Map<String, Value>, String> {
    if let Some(extra) = args.positional.first() {
        return Err(format!(
            "unknown command {extra:?} for \"workroom new\": it takes only flags"
        ));
    }
    let mut params = Map::new();
    if let Some(title) = args.value("title") {
        params.insert("title".into(), json!(title));
    }
    if let Some(run) = args.value("run") {
        if run.trim().is_empty() {
            return Err("`workroom new --run` needs a command".into());
        }
        params.insert("run".into(), json!(run));
    }
    let cwd: Option<PathBuf> = match args.value("cwd") {
        Some("") => return Err("`workroom new --cwd` needs a folder".into()),
        Some(cwd) if Path::new(cwd).is_absolute() => Some(PathBuf::from(cwd)),
        Some(cwd) => here.map(|here| here.join(cwd)),
        None => here.map(Path::to_path_buf),
    };
    if let Some(cwd) = cwd {
        params.insert("cwd".into(), json!(cwd.to_string_lossy()));
    }
    match args.value("split") {
        None => {}
        Some(split @ ("right" | "down")) => {
            params.insert("split".into(), json!(split));
        }
        Some(other) => {
            return Err(format!(
                "`workroom new --split` is right or down, not {other:?}"
            ));
        }
    }
    Ok(params)
}

pub(super) fn run_close(context: &Context, args: &Args) -> Outcome {
    let target = match args.positional.as_slice() {
        [target] => target,
        [] => {
            return Outcome::Usage(CliError::internal(
                "`workroom close` needs a TARGET: the session to close",
            ));
        }
        [_, extra, ..] => {
            return Outcome::Usage(CliError::internal(format!(
                "unknown command {extra:?} for \"workroom close\": it closes one TARGET"
            )));
        }
    };
    let mut params = json!({"target": target});
    if args.is_set("allow-self") {
        params["allow_self"] = json!(true);
    }
    match terminal_api::call(context, "session.close", params) {
        Err(error) => Outcome::Failed(error),
        Ok(result) if context.json => Outcome::Success(super::envelope::success("close", &result)),
        Ok(_) => Outcome::Printed(String::new()),
    }
}

pub(super) fn run_control(context: &Context, args: &Args) -> Outcome {
    let (target, action) = match args.positional.as_slice() {
        [target, action] if action == "restart" || action == "stop" => (target, action),
        [_, action] => {
            return Outcome::Usage(CliError::internal(format!(
                "`workroom run-control` restarts or stops a run: restart or stop, not {action:?}"
            )));
        }
        [_, _, extra, ..] => {
            return Outcome::Usage(CliError::internal(format!(
                "unknown command {extra:?} for \"workroom run-control\""
            )));
        }
        _ => {
            return Outcome::Usage(CliError::internal(
                "`workroom run-control` needs a TARGET and restart or stop",
            ));
        }
    };
    let params = json!({"target": target, "action": action});
    match terminal_api::call(context, "session.run_control", params) {
        Err(error) => Outcome::Failed(error),
        Ok(result) if context.json => {
            Outcome::Success(super::envelope::success("run-control", &result))
        }
        Ok(_) => Outcome::Printed(String::new()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(argv: &[&str]) -> Args {
        let argv: Vec<String> = argv.iter().map(|arg| (*arg).to_string()).collect();
        let (parsed, error) = super::super::parse(&argv, NEW_FLAGS);
        assert_eq!(error, None, "{argv:?}");
        Args {
            positional: parsed.positional,
            values: parsed.values,
            flags: NEW_FLAGS,
        }
    }

    /// Each flag as the API names it; the folder this command's, or `--cwd`'s against it.
    #[test]
    fn new_sends_its_flags_and_a_folder_resolved_here() {
        let here = Path::new("/work/app");
        assert_eq!(
            new_request(&parsed(&[]), Some(here)),
            Ok(json!({"cwd": "/work/app"}).as_object().cloned().unwrap())
        );
        assert_eq!(
            new_request(
                &parsed(&[
                    "--title",
                    "dev",
                    "--run",
                    "npm run dev",
                    "--cwd",
                    "web",
                    "--split",
                    "down"
                ]),
                Some(here)
            ),
            Ok(json!({
                "title": "dev",
                "run": "npm run dev",
                "cwd": "/work/app/web",
                "split": "down",
            })
            .as_object()
            .cloned()
            .unwrap())
        );
        assert_eq!(
            new_request(&parsed(&["--cwd", "/tmp"]), Some(here)).map(|p| p["cwd"].clone()),
            Ok(json!("/tmp"))
        );
        assert_eq!(
            new_request(&parsed(&[]), None),
            Ok(Map::new()),
            "no folder to send: the daemon's default"
        );
    }

    #[test]
    fn new_refuses_a_bad_split_an_empty_run_and_an_operand() {
        for (argv, says) in [
            (&["--split", "left"][..], "right or down"),
            (&["--run", " "][..], "needs a command"),
            (&["--cwd", ""][..], "needs a folder"),
            (&["extra"][..], "only flags"),
        ] {
            match new_request(&parsed(argv), Some(Path::new("/"))) {
                Err(message) => assert!(message.contains(says), "{argv:?}: {message}"),
                other => panic!("{argv:?}: {other:?}"),
            }
        }
    }
}
