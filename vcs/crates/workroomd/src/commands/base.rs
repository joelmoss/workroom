//! `workroom base set|clear --global`: the branch new workrooms start from in every project that
//! names none of its own. Unset, they start from origin's freshly fetched default branch.
//!
//! Only the `--global` form is ported so far, as config.json's first Rust writer (#671). A
//! project's own base (`base set|clear` without `--global`) is still the Go CLI's until #673.

use serde::Serialize;

use super::config::Config;
use super::kind::CliError;
use super::{Args, Context, Outcome};

/// `base set`'s and `base clear`'s payload: the base branch ("" when cleared), global.
#[derive(Serialize)]
struct Payload<'a> {
    base_branch: &'a str,
    global: bool,
}

const HELP: &str =
    "Set or clear the branch new workrooms start from. BRANCH is a branch on origin, \
such as develop, or <remote>/<branch> for another remote, such as upstream/main. Workroom fetches \
that remote and uses its copy of the branch, else the local branch. A project's own base wins over \
the --global one. Unset, new workrooms start from origin's default branch.

Usage:
  workroom base [command]

Available Commands:
  clear       Start new workrooms from the global base, else origin's default branch
  set         Start new workrooms from BRANCH

Flags:
      --global          The default for every project that names no base branch
      --project string  Project directory (defaults to the current directory)
";

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    let branch = match args.positional.split_first() {
        Some((sub, rest)) if sub == "set" => match rest {
            [branch] => branch.as_str(),
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
            ""
        }
        // `base` alone, or with no subcommand it knows, is its help, as cobra shows it.
        _ => return Outcome::Printed(HELP.to_string()),
    };
    if !args.is_set("global") {
        return Outcome::Failed(CliError::internal(
            "`workroom base` for one project isn't in this build yet (#673); the Go CLI runs it \
             until the switch (ADR 0078)",
        ));
    }
    match set_global(context, branch) {
        Ok(()) if context.json => Outcome::Success(super::envelope::success(
            "base",
            &Payload {
                base_branch: branch,
                global: true,
            },
        )),
        Ok(()) => Outcome::Printed(String::new()),
        Err(error) => Outcome::Failed(error),
    }
}

fn set_global(context: &Context, branch: &str) -> Result<(), CliError> {
    if !branch.is_empty() {
        check_branch_name(branch)?;
    }
    let config = Config::new(context)?;
    if context.pretend {
        return Ok(());
    }
    config.set_global_base_branch(branch)
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
