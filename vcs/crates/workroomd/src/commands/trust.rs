//! `workroom trust`, `trust status` and `untrust` (#363): approving, checking and forgetting the
//! approval of the setup and teardown scripts a project's next create or delete would run, by
//! their exact bytes. The approvals are config's per-project `trusted_scripts` records
//! (`config`), the same ones Go writes.
//!
//! In a terminal `trust` shows each unapproved script and asks; with `--json`, `--stdin`, or no
//! terminal on stdin it approves without asking, as Go's does: the caller has shown the bytes, or
//! no one is there to ask. The refusal of an unapproved script is `create`'s and `delete`'s.
//!
//! The app's flags: `--stdin NAME` judges the bytes on stdin in place of the project's file (a
//! remote host's copy), `--base BRANCH` the setup script at the branch a remote create checks out,
//! and `--devcontainer` that start's devcontainer.json too.

use std::io::{IsTerminal, Read, Write};

use serde::Serialize;

use super::config::{self, Config};
use super::kind::CliError;
use super::panel::Paint;
use super::prompt;
use super::start::{LocalWork, LocalWorkPayload};
use super::trusted_script::{self, Judge, Script, ScriptPayload};
use super::{Args, Context, Outcome};

/// `trust`'s and `trust status`'s `--help`, after the short line.
pub(super) const LONG: &str = "Approve the setup and teardown scripts a create or delete would \
    run next, by their exact contents. In a terminal each one is shown first and you are asked. \
    A changed script needs approving again. A script git ignores in the project's root needs no \
    approval. With --pretend it fetches nothing, and warns that the start it judges may be out \
    of date.";

pub(super) const STATUS_LONG: &str = "Say whether the setup and teardown scripts a create or \
    delete would run next are approved. Exits 0 when every script there is approved or ignored \
    by git, 1 when one is not, and 2 when it cannot tell. With --pretend it fetches nothing, and \
    warns that the start it judges may be out of date.";

/// `trust`'s payload: the scripts judged, with what was approved.
#[derive(Serialize)]
struct TrustPayload<'a> {
    scripts: Vec<ScriptPayload>,
    /// Under `--pretend`, which fetches nothing, that the start judged may be out of date (#798).
    #[serde(skip_serializing_if = "str::is_empty")]
    warning: &'a str,
}

/// `trust status`'s. `local_work` is what a create from that start leaves out, for a remote create
/// to warn about, and `start` the commit `--base` names.
#[derive(Serialize)]
struct StatusPayload<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    local_work: Option<LocalWorkPayload>,
    scripts: Vec<ScriptPayload>,
    #[serde(skip_serializing_if = "str::is_empty")]
    start: &'a str,
    trusted: bool,
    /// As [`TrustPayload`]'s.
    #[serde(skip_serializing_if = "str::is_empty")]
    warning: &'a str,
}

/// `untrust`'s.
#[derive(Serialize)]
struct UntrustPayload<'a> {
    project: &'a str,
}

/// `trust`, or with `status` as its argument, `trust status`.
pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    match args.positional.split_first() {
        Some((sub, rest)) if sub == "status" => match rest.first() {
            Some(extra) => Outcome::Usage(CliError::internal(format!(
                "unknown command {extra:?} for \"workroom trust status\""
            ))),
            None => status(context, args),
        },
        Some((extra, _)) => Outcome::Usage(CliError::internal(format!(
            "unknown command {extra:?} for \"workroom trust\""
        ))),
        None => trust(context, args),
    }
}

/// What the trust commands judged: the project, its config, its scripts, the local work a create
/// from that start leaves out, and the commit `--base` names.
struct Judged {
    config: Config,
    dir: String,
    scripts: Vec<Script>,
    work: LocalWork,
    start: String,
    /// Under `--pretend`, which fetches nothing, that the start may be out of date; else "".
    unfetched: String,
}

/// The project the trust commands name, judged: the one script read from stdin with `--stdin`,
/// else the scripts it would run next. Go's `judgedScripts`.
fn judged(context: &Context, args: &Args) -> Result<Judged, CliError> {
    let config = Config::new(context)?;
    let dir = project(context, &config, args)?;
    let say = |status: &str, message: &str| say(context, status, message);
    let judge = Judge {
        config: &config,
        dir: &dir,
        say: &say,
        fetch: !context.pretend,
    };
    let mut work = LocalWork::default();
    let mut start = String::new();
    let mut unfetched = String::new();
    let stdin = args.value("stdin").unwrap_or_default();
    let scripts = if stdin.is_empty() {
        let next = match args.value("base") {
            Some(base) => {
                let mut next = judge.scripts_from(base, args.is_set("devcontainer"))?;
                start = std::mem::take(&mut next.start);
                next
            }
            None if args.is_set("devcontainer") => {
                return Err(CliError::internal(
                    "--devcontainer judges a container create's file, so it needs --base",
                ));
            }
            None => judge.scripts()?,
        };
        (work, unfetched) = (next.work, next.unfetched);
        next.scripts
    } else {
        let Some(name) = trusted_script::known_name(stdin) else {
            return Err(CliError::internal(format!(
                "--stdin takes {}, {} or {}, not {stdin:?}",
                trusted_script::SETUP_SCRIPT,
                trusted_script::TEARDOWN_SCRIPT,
                trusted_script::DEV_CONTAINER
            )));
        };
        let mut text = Vec::new();
        std::io::stdin()
            .read_to_end(&mut text)
            .map_err(|error| CliError::internal(format!("read {}", config::os_error(&error))))?;
        vec![judge.judge(name, trusted_script::Origin::Stdin, text)?]
    };
    Ok(Judged {
        config,
        dir,
        scripts,
        work,
        start,
        unfetched,
    })
}

/// `text`, a person's, with `warning` (`--pretend`'s unfetched start, or "") after it on stderr.
fn printed(text: String, warning: &str) -> Outcome {
    if warning.is_empty() {
        return Outcome::Printed(text);
    }
    Outcome::PrintedWithWarnings {
        stdout: text,
        warnings: format!("{warning}\n"),
    }
}

/// The project the trust commands act on: `--project` or the current directory, or, inside one
/// of its workrooms (where every terminal pane opens), that workroom's project. Approvals are the
/// project's, so a workroom's path must never take them. Go's `trustedProject`.
fn project(context: &Context, config: &Config, args: &Args) -> Result<String, CliError> {
    let dir = config::resolve_project(args.value("project"), context)?;
    // A config that can't be read finds no project here; judging the scripts reports it.
    Ok(config
        .read()
        .ok()
        .and_then(|data| config::find_current_project(&data, &dir))
        .map_or(dir, |(project, _)| project))
}

/// Writes one `--verbose` status line, as Go's `Service.Status` prints one, straight to stdout:
/// before anything the command prints at its end.
pub(super) fn say(context: &Context, status: &str, message: &str) {
    if context.verbose && !context.json {
        let mut stdout = std::io::stdout();
        let _ = writeln!(stdout, "{status:>12}  {message}");
        let _ = stdout.flush();
    }
}

/// `trust`: approves each script there that isn't yet.
fn trust(context: &Context, args: &Args) -> Outcome {
    let Judged {
        config,
        dir,
        mut scripts,
        unfetched,
        ..
    } = match judged(context, args) {
        Ok(judged) => judged,
        Err(error) => return Outcome::Failed(error),
    };
    let from_stdin = !args.value("stdin").unwrap_or_default().is_empty();
    let paint = Paint(context.color);
    let mut lines = Vec::new();
    for sc in &mut scripts {
        if sc.exempt {
            lines.push(format!(
                "{} is ignored by git, so it needs no approval.",
                sc.file
            ));
            continue;
        }
        if sc.trusted {
            lines.push(format!("{} is already approved.", sc.file));
            continue;
        }
        // The bytes came on stdin from a caller that has shown them, or no one is here to ask.
        if !from_stdin && !context.json && std::io::stdin().is_terminal() {
            match prompt::approve(paint, sc) {
                Ok(true) => {}
                Ok(false) => {
                    lines.push(format!("{} was left unapproved.", sc.file));
                    continue;
                }
                Err(error) => return Outcome::Failed(error),
            }
        }
        if let Err(error) = record(context, &config, &dir, sc, from_stdin) {
            return Outcome::Failed(error);
        }
        sc.trusted = true;
        lines.push(paint.green(&format!("Approved {} {}.", sc.file, sc.origin.label())));
    }
    if context.json {
        let payload = TrustPayload {
            scripts: scripts.iter().map(Script::payload).collect(),
            warning: &unfetched,
        };
        return Outcome::Success(super::envelope::success("trust", &payload));
    }
    if !from_stdin {
        lines.extend(absent(&scripts));
    }
    printed(lines.join("\n") + "\n", &unfetched)
}

/// Records `sc`'s bytes as approved for the project at `dir`, registering the project if it is
/// not yet: Go's `Service.Trust`. Bytes from stdin are the app's, for a project it has registered,
/// so one gone meanwhile is refused rather than registered again. `--pretend` records nothing.
fn record(
    context: &Context,
    config: &Config,
    dir: &str,
    sc: &Script,
    from_stdin: bool,
) -> Result<(), CliError> {
    if context.pretend {
        return Ok(());
    }
    if !from_stdin {
        config.add_project(dir, "git")?;
    }
    config.set_trusted_script(dir, sc.name, &sc.sha256)
}

/// `trust status`: whether each script there is approved, exiting 0 when all are, 1 when one is
/// not, and 2 when it can't tell, as Go's `exitStatus` ends it. A failure's envelope names
/// `trust status`.
fn status(context: &Context, args: &Args) -> Outcome {
    let judged = match judged(context, args) {
        Ok(judged) => judged,
        Err(error) => {
            return Outcome::Status(2, Box::new(Outcome::FailedIn("trust status", error)));
        }
    };
    let trusted = judged.scripts.iter().all(|sc| sc.trusted);
    let outcome = if context.json {
        let payload = StatusPayload {
            local_work: judged.work.any().then(|| judged.work.payload()),
            scripts: judged.scripts.iter().map(Script::payload).collect(),
            start: &judged.start,
            trusted,
            warning: &judged.unfetched,
        };
        Outcome::Success(super::envelope::success("trust status", &payload))
    } else {
        let paint = Paint(context.color);
        let mut text = String::new();
        for sc in &judged.scripts {
            let state = if sc.exempt {
                paint.green("ignored by git, needs no approval")
            } else if sc.trusted {
                paint.green("approved")
            } else {
                paint.red("not approved")
            };
            text += &format!("{} {}: {state}\n", sc.file, sc.origin.label());
        }
        if args.value("stdin").unwrap_or_default().is_empty() {
            for line in absent(&judged.scripts) {
                text += &line;
                text.push('\n');
            }
        }
        printed(text, &judged.unfetched)
    };
    if trusted {
        outcome
    } else {
        Outcome::Status(1, Box::new(outcome))
    }
}

/// `untrust`: forgets every approval of the project's scripts and its devcontainer.json. The
/// project must be registered; `--pretend` forgets nothing and checks nothing.
pub(super) fn untrust(context: &Context, args: &Args) -> Outcome {
    let result = Config::new(context).and_then(|config| {
        let dir = project(context, &config, args)?;
        if !context.pretend {
            config.untrust(
                &dir,
                &[
                    trusted_script::SETUP_SCRIPT,
                    trusted_script::TEARDOWN_SCRIPT,
                    trusted_script::DEV_CONTAINER,
                ],
            )?;
        }
        Ok(dir)
    });
    match result {
        Ok(dir) if context.json => Outcome::Success(super::envelope::success(
            "untrust",
            &UntrustPayload { project: &dir },
        )),
        Ok(_) => Outcome::Printed("Forgot the approval of this project's scripts.\n".to_string()),
        Err(error) => Outcome::Failed(error),
    }
}

/// Which of the project's scripts it has none of.
fn absent(scripts: &[Script]) -> Vec<String> {
    [
        trusted_script::SETUP_SCRIPT,
        trusted_script::TEARDOWN_SCRIPT,
    ]
    .into_iter()
    .filter(|name| !scripts.iter().any(|sc| sc.name == *name))
    .map(|name| format!("No scripts/{name}."))
    .collect()
}
