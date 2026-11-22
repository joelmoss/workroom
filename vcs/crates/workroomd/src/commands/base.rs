//! `workroom base set|clear`: the branch new workrooms start from, for one project or, with
//! `--global`, for every project that names none of its own. Unset, they start from origin's
//! freshly fetched default branch.
//!
//! `set` checks only that git would take the name as a branch: a branch that exists nowhere yet is
//! stored, and a create that can't find it fails then (`BaseBranchNotFound`), as Go's does.

use std::path::Path;

use serde::Serialize;

use super::config::{self, Config};
use super::kind::{CliError, Kind};
use super::{Args, Context, Outcome};

/// `base set`'s and `base clear`'s payload: the base branch ("" when cleared) of the project, or
/// with `--global` the default for every project.
#[derive(Serialize)]
struct Payload<'a> {
    base_branch: &'a str,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    global: bool,
    #[serde(skip_serializing_if = "str::is_empty")]
    project: &'a str,
}

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    // `Some` for `set`, `None` for `clear`.
    let branch = match args.positional.split_first() {
        Some((sub, rest)) if sub == "set" => match rest {
            [branch] => Some(branch.as_str()),
            _ => {
                return Outcome::Usage(CliError::internal(format!(
                    "accepts 1 arg(s), received {}",
                    rest.len()
                )));
            }
        },
        Some((sub, rest)) if sub == "clear" => {
            if let Some(extra) = rest.first() {
                return Outcome::Usage(CliError::internal(format!(
                    "unknown command {extra:?} for \"workroom base clear\""
                )));
            }
            None
        }
        // `base` alone, or with no subcommand it knows, is its help, as cobra shows it.
        _ => return Outcome::Printed(super::command_help("base")),
    };
    let global = args.is_set("global");
    let result = match branch {
        Some(branch) => check_branch_name(branch).and_then(|()| change(context, args, branch)),
        None => change(context, args, ""),
    };
    match result {
        Ok(project) if context.json => Outcome::Success(super::envelope::success(
            "base",
            &Payload {
                base_branch: branch.unwrap_or_default(),
                global,
                project: &project,
            },
        )),
        Ok(_) => Outcome::Printed(String::new()),
        Err(error) => Outcome::Failed(error),
    }
}

/// Stores `branch` ("" to clear) as the global base, or the project's, and returns the project's
/// path ("" for the global one). `--pretend` checks everything and writes nothing.
fn change(context: &Context, args: &Args, branch: &str) -> Result<String, CliError> {
    let config = Config::new(context)?;
    if args.is_set("global") {
        if !context.pretend {
            config.set_global_base_branch(branch)?;
        }
        return Ok(String::new());
    }
    let dir = config::resolve_project(args.value("project"), context)?;
    refuse_workroom(&config, &dir)?;
    // The CLI otherwise registers a project at its first create, which a base may have to come
    // before, so `set` registers a repository as add-project does. `clear` only edits, so it still
    // works for a project whose folder has moved.
    if !branch.is_empty() && !super::git::is_git_repo(Path::new(&dir)) {
        return Err(CliError::new(
            Kind::UnsupportedVcs,
            "no supported VCS detected in this directory. Workroom requires Git to manage \
             workrooms",
        ));
    }
    if !context.pretend {
        if !branch.is_empty() {
            config.add_project(&dir, "git")?;
        }
        config.set_base_branch(&dir, branch)?;
    }
    Ok(dir)
}

/// Refuses `dir` when it is a workroom: a linked worktree or any project's registered workroom.
/// A base belongs to the project's root checkout; run from a workroom terminal, `base set` would
/// otherwise register that workroom as a project of its own.
fn refuse_workroom(config: &Config, dir: &str) -> Result<(), CliError> {
    let in_workroom = super::git::linked_worktree(Path::new(dir))
        || config::all_projects(&config.read()?)
            .values()
            .any(|project| project.workrooms.values().any(|w| w.path == dir));
    if in_workroom {
        return Err(CliError::new(
            Kind::InWorkroom,
            "looks like you are already in a workroom. Run this command from the root of your \
             main development directory, not from within an existing workroom",
        ));
    }
    Ok(())
}

/// git's own rule for a branch name, so a typo is refused now, not at the next create.
fn check_branch_name(branch: &str) -> Result<(), CliError> {
    let output = std::process::Command::new("git")
        .args(["check-ref-format", "--branch", branch])
        .stdin(std::process::Stdio::null())
        .output();
    match output {
        Ok(output) if output.status.success() => Ok(()),
        Ok(output) => {
            let mut said = output.stdout;
            said.extend_from_slice(&output.stderr);
            Err(CliError::internal(format!(
                "invalid branch name {branch:?}: {}",
                String::from_utf8_lossy(&said)
            )))
        }
        Err(_) => Err(CliError::internal(format!(
            "invalid branch name {branch:?}: "
        ))),
    }
}
