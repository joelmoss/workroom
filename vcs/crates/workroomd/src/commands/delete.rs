//! `workroom delete [NAME]`: deletes a workroom of the project `--project` names (else the current
//! directory's) as Go's `delete` does, through `teardown`: its approved teardown script, then
//! `git worktree remove --force`, then its config entry. Its branch is kept. A workroom whose folder
//! holds no git checkout, or a remote one whose host is destroyed, is only forgotten.
//!
//! The app runs it with `--json --confirm NAME`, the teardown's output going to stderr as
//! `teardown` events. A person may leave out `--confirm` and is asked, or leave out the name too
//! and pick the workrooms to delete. Each prompt is asked on the terminal (stdin when it is one,
//! else the controlling terminal, as Go's prompts open it); with no terminal the delete fails, and
//! nothing is deleted.

use std::io::{BufRead, BufReader, IsTerminal, Write};

use serde::Serialize;

use super::config::{self, Config, Json};
use super::envelope;
use super::kind::{CliError, Kind};
use super::teardown::{Approve, Confirm, Delete, Deleted, INVALID_NAME, Watcher};
use super::trust::{self, Paint};
use super::trusted_script::Script;
use super::{Args, Context, Outcome};

#[derive(Serialize)]
struct Payload<'a> {
    name: &'a str,
}

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    if args.positional.len() > 1 {
        return Outcome::Usage(CliError::internal(format!(
            "accepts at most 1 arg(s), received {}",
            args.positional.len()
        )));
    }
    match delete(context, args) {
        Ok(outcome) => outcome,
        Err(error) => Outcome::Failed(error),
    }
}

fn delete(context: &Context, args: &Args) -> Result<Outcome, CliError> {
    let config = Config::new(context)?;
    let dir = config::resolve_project(args.value("project"), context)?;
    let name = args.positional.first().map(String::as_str);
    let confirm = args.value_or_default("confirm");
    let skip_teardown = args.is_set("skip-teardown");
    if context.json {
        let Some(name) = name else {
            return Err(CliError::new(
                Kind::InvalidName,
                format!(
                    "{INVALID_NAME}: a workroom name is required in --json mode (interactive \
                     delete is unavailable)"
                ),
            ));
        };
        if confirm.is_empty() {
            return Err(CliError::new(
                Kind::ConfirmationMismatch,
                "confirmation value does not match the workroom name: --confirm <name> is \
                 required in --json mode",
            ));
        }
        let delete = Delete {
            context,
            config: &config,
            skip_teardown,
            watcher: Watcher::App,
        };
        delete.delete(&dir, name, Confirm::Value(confirm))?;
        return Ok(Outcome::Success(envelope::success(
            "delete",
            &Payload { name },
        )));
    }

    let paint = Paint(context.color);
    // Only a person at a terminal can read a script and approve it; anything else is refused.
    let approve = |script: &Script| {
        let mut stdout = std::io::stdout();
        let approved =
            trust::approve_script(&mut stdout, &mut std::io::stdin().lock(), paint, script);
        let _ = stdout.flush();
        approved
    };
    let delete = Delete {
        context,
        config: &config,
        skip_teardown,
        watcher: Watcher::Person {
            paint,
            approve: std::io::stdin()
                .is_terminal()
                .then_some(&approve as Approve<'_>),
        },
    };
    let home = config::home_dir(context).ok();
    let said = |name: &str, deleted: &Deleted| said(paint, home.as_deref(), name, deleted);
    let Some(name) = name else {
        return pick_and_delete(&delete, &config, &dir, paint, &said);
    };
    let deleted = if confirm.is_empty() {
        delete.delete(&dir, name, Confirm::Ask(&ask))?
    } else {
        delete.delete(&dir, name, Confirm::Value(confirm))?
    };
    Ok(Outcome::Printed(said(name, &deleted)))
}

/// Go's `InteractiveDelete`: offers the project's workrooms, asks to confirm the picks, and
/// deletes each, saying so as each is done. A pick is deleted as Go's `deleteByName` deletes it,
/// after the same checks: a live remote workroom stops it, and one git doesn't list whose folder
/// holds no checkout is only forgotten.
fn pick_and_delete(
    delete: &Delete,
    config: &Config,
    dir: &str,
    paint: Paint,
    said: &dyn Fn(&str, &Deleted) -> String,
) -> Result<Outcome, CliError> {
    delete.check_not_in_workroom(dir)?;
    // Go reads a config it can't parse as naming no project here.
    let data = config.read().unwrap_or(Json::Null);
    let names: Vec<String> = config::find_current_project(&data, dir)
        .map(|(_, project)| project.workrooms.into_keys().collect())
        .unwrap_or_default();
    if names.is_empty() {
        return Ok(Outcome::Printed(
            "No workrooms found for this project.\n".to_string(),
        ));
    }
    let picked = pick("Select workrooms to delete:", &names)?;
    if picked.is_empty() {
        return Ok(Outcome::Printed(format!(
            "{}\n",
            paint.yellow("Aborting. No workrooms were selected.")
        )));
    }
    let quoted: Vec<String> = picked.iter().map(|name| format!("'{name}'")).collect();
    if !ask(&format!(
        "Are you sure you want to delete {} workroom(s): {}?",
        picked.len(),
        quoted.join(", ")
    ))? {
        return Ok(Outcome::Printed(format!(
            "{}\n",
            paint.yellow("Aborting. No workrooms were deleted.")
        )));
    }
    delete.detect_vcs(dir)?;
    let mut stdout = std::io::stdout();
    for name in &picked {
        delete.destroyed_remote(dir, name)?;
        let orphan = if delete.context.pretend {
            None
        } else {
            delete.legacy_workroom_path(dir, name)?
        };
        let deleted = match orphan {
            Some(path) => delete.forget_non_git(dir, name, path)?,
            None => delete.delete_by_name(dir, name)?,
        };
        let _ = stdout.write_all(said(name, &deleted).as_bytes());
        let _ = stdout.flush();
    }
    Ok(Outcome::Printed(String::new()))
}

/// What a person is told a delete did with workroom `name`: Go's `printDeleteResult`.
fn said(paint: Paint, home: Option<&str>, name: &str, deleted: &Deleted) -> String {
    match deleted {
        Deleted::Removed { branch } => format!(
            "{}\n\nNote: Git branch '{branch}' was not deleted.\n      Delete manually with `git \
             branch -D {branch}` if needed.\n",
            paint.green(&format!("Workroom '{name}' deleted successfully."))
        ),
        Deleted::ForgotDestroyedRemote => format!(
            "{}\n",
            paint.green(&format!("Workroom '{name}' deleted successfully."))
        ),
        Deleted::ForgotNonGit { path } => {
            // Go's `DisplayPath`: HOME as `~`.
            let shown = match home.and_then(|home| path.strip_prefix(home)) {
                Some(rest) => format!("~{rest}"),
                None => path.clone(),
            };
            format!(
                "{}\nNote: its folder was left at {shown}. Delete it manually if needed.\n",
                paint.green(&format!(
                    "Workroom '{name}' removed from Workroom. It is not a git worktree, so no git \
                     or teardown ran."
                ))
            )
        }
        Deleted::Declined => format!(
            "{}\n",
            paint.yellow(&format!("Aborting. Workroom '{name}' was not deleted."))
        ),
    }
}

/// The terminal a person is asked on: where the question goes and where the answer comes from.
struct Terminal {
    out: Box<dyn Write>,
    input: Box<dyn BufRead>,
}

/// Stdin and stdout when stdin is a terminal, else the controlling terminal, which Go's prompts
/// (charmbracelet/huh) open too. No terminal is an error, so nothing is done on an answer no one
/// gave.
fn terminal() -> Result<Terminal, CliError> {
    if std::io::stdin().is_terminal() {
        return Ok(Terminal {
            out: Box::new(std::io::stdout()),
            input: Box::new(std::io::stdin().lock()),
        });
    }
    let tty = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty")
        .map_err(|error| {
            CliError::internal(format!(
                "could not open a terminal to ask on: open /dev/tty: {}",
                config::os_error(&error)
            ))
        })?;
    let input = tty.try_clone().map_err(|error| {
        CliError::internal(format!(
            "could not open a terminal to ask on: {}",
            config::os_error(&error)
        ))
    })?;
    Ok(Terminal {
        out: Box::new(tty),
        input: Box::new(BufReader::new(input)),
    })
}

/// Asks a person `question`, yes or no, on the terminal.
fn ask(question: &str) -> Result<bool, CliError> {
    let mut terminal = terminal()?;
    trust::confirm(&mut terminal.out, &mut terminal.input, question)
}

/// Asks a person which of `names` to pick, on the terminal.
fn pick(message: &str, names: &[String]) -> Result<Vec<String>, CliError> {
    let mut terminal = terminal()?;
    pick_from(&mut terminal.out, &mut terminal.input, message, names)
}

/// Shows `names` numbered under `message` on `out` and reads the numbers picked from `input`,
/// separated by spaces or commas: the picks in `names`' order, each once, and none for an empty
/// answer. A number that isn't one of them asks again. Input that ends before an answer is the
/// person giving up, as `trust::confirm` takes it. Where Go showed a list to tick (huh's
/// multi-select), this asks a line, as the CLI's other prompts do.
fn pick_from(
    out: &mut dyn Write,
    input: &mut dyn BufRead,
    message: &str,
    names: &[String],
) -> Result<Vec<String>, CliError> {
    let mut shown = format!("{message}\n");
    for (number, name) in names.iter().enumerate() {
        shown += &format!("  {}) {name}\n", number + 1);
    }
    let _ = out.write_all(shown.as_bytes());
    'ask: loop {
        let _ = write!(
            out,
            "Numbers to delete, separated by spaces (none to delete nothing): "
        );
        let _ = out.flush();
        let mut answer = String::new();
        match input.read_line(&mut answer) {
            Ok(0) => return Err(CliError::internal("user aborted")),
            Ok(_) => {}
            Err(error) => {
                return Err(CliError::internal(format!(
                    "read the answer: {}",
                    config::os_error(&error)
                )));
            }
        }
        let mut picked = vec![false; names.len()];
        for word in answer
            .split(|ch: char| ch.is_whitespace() || ch == ',')
            .filter(|word| !word.is_empty())
        {
            match word.parse::<usize>() {
                Ok(number) if (1..=names.len()).contains(&number) => picked[number - 1] = true,
                _ => {
                    let _ = writeln!(out, "{word} is not one of the numbers above.");
                    continue 'ask;
                }
            }
        }
        return Ok(names
            .iter()
            .zip(picked)
            .filter(|(_, picked)| *picked)
            .map(|(name, _)| name.clone())
            .collect());
    }
}

#[cfg(test)]
mod tests {
    use super::{Deleted, Paint, pick_from, said};

    fn picked(answer: &[u8]) -> (Result<Vec<String>, String>, String) {
        let names = ["bright-star".to_string(), "calm-river".to_string()];
        let mut out = Vec::new();
        let picked =
            pick_from(&mut out, &mut &answer[..], "Select:", &names).map_err(|error| error.message);
        (picked, String::from_utf8(out).expect("UTF-8"))
    }

    /// The names are numbered; the picks come back once each, in the list's order, and a number
    /// that isn't there asks again.
    #[test]
    fn a_pick_is_the_numbers_given_in_the_lists_order() {
        let question = "Numbers to delete, separated by spaces (none to delete nothing): ";
        let (got, shown) = picked(b"2 1,2\n");
        assert_eq!(got, Ok(vec!["bright-star".into(), "calm-river".into()]));
        assert_eq!(
            shown,
            format!("Select:\n  1) bright-star\n  2) calm-river\n{question}")
        );
        assert_eq!(picked(b"\n").0, Ok(vec![]));
        let (got, shown) = picked(b"3\nx\n2\n");
        assert_eq!(got, Ok(vec!["calm-river".into()]));
        assert!(
            shown.ends_with(&format!(
                "{question}3 is not one of the numbers above.\n{question}x is not one of the \
                 numbers above.\n{question}"
            )),
            "{shown:?}"
        );
        assert_eq!(picked(b"").0, Err("user aborted".into()));
    }

    /// Go's `printDeleteResult`, outcome by outcome.
    #[test]
    fn a_person_is_told_what_was_done() {
        let paint = Paint(false);
        let removed = Deleted::Removed {
            branch: "workroom/calm-river".into(),
        };
        assert_eq!(
            said(paint, None, "calm-river", &removed),
            "Workroom 'calm-river' deleted successfully.\n\nNote: Git branch \
             'workroom/calm-river' was not deleted.\n      Delete manually with `git branch -D \
             workroom/calm-river` if needed.\n"
        );
        let orphan = Deleted::ForgotNonGit {
            path: "/Users/dev/workrooms/plain".into(),
        };
        assert_eq!(
            said(paint, Some("/Users/dev"), "plain", &orphan),
            "Workroom 'plain' removed from Workroom. It is not a git worktree, so no git or \
             teardown ran.\nNote: its folder was left at ~/workrooms/plain. Delete it manually if \
             needed.\n"
        );
        assert_eq!(
            said(paint, None, "plain", &orphan),
            "Workroom 'plain' removed from Workroom. It is not a git worktree, so no git or \
             teardown ran.\nNote: its folder was left at /Users/dev/workrooms/plain. Delete it \
             manually if needed.\n"
        );
        assert_eq!(
            said(paint, None, "gone", &Deleted::ForgotDestroyedRemote),
            "Workroom 'gone' deleted successfully.\n"
        );
        assert_eq!(
            said(Paint(true), None, "x", &Deleted::Declined),
            "\x1b[33mAborting. Workroom 'x' was not deleted.\x1b[0m\n"
        );
    }
}
