//! `workroom host set|clear` (hidden, the desktop app's): the host descriptors the app owns
//! (#249, #252), which say which machine a remote workroom lives on, and a project's base machine.
//! A descriptor is stored verbatim; the CLI interprets only whether a workroom has one and its
//! `state`.

use serde::Serialize;

use super::config::{self, Config, Json};
use super::kind::{CliError, Kind};
use super::{Args, Context, Outcome};

/// `host set`'s and `host clear`'s payload. `workroom` is "" for the project's own descriptor.
#[derive(Serialize)]
struct Payload<'a> {
    project: &'a str,
    workroom: &'a str,
}

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    let host = match args.positional.split_first() {
        Some((sub, rest)) if sub == "set" => match rest {
            [descriptor] => match config::host_descriptor(descriptor) {
                Some(host) => Some(host),
                None => {
                    return Outcome::Failed(CliError::new(
                        Kind::InvalidHostDescriptor,
                        format!("a host descriptor must be a JSON object: {descriptor}"),
                    ));
                }
            },
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
                    "unknown command {extra:?} for \"workroom host clear\""
                )));
            }
            None
        }
        // `host` alone, or with no subcommand it knows, is its help, as cobra shows it.
        _ => return Outcome::Printed(super::help(super::find("host"))),
    };
    let workroom = args.value("workroom").unwrap_or_default();
    match set(context, args, workroom, host) {
        Ok(project) if context.json => Outcome::Success(super::envelope::success(
            "host",
            &Payload {
                project: &project,
                workroom,
            },
        )),
        Ok(_) => Outcome::Printed(String::new()),
        Err(error) => Outcome::Failed(error),
    }
}

/// Stores `host` (none to clear) on the project, or its `workroom`, and returns the project's
/// path. `--pretend` checks that the entry exists and writes nothing.
fn set(
    context: &Context,
    args: &Args,
    workroom: &str,
    host: Option<Json>,
) -> Result<String, CliError> {
    let config = Config::new(context)?;
    let dir = config::resolve_project(args.value("project"), context)?;
    if context.pretend {
        let projects = config::all_projects(&config.read()?);
        let project = projects
            .get(&dir)
            .ok_or_else(|| config::project_not_found(&dir))?;
        if !workroom.is_empty() && !project.workrooms.contains_key(workroom) {
            return Err(config::workroom_not_found(&dir, workroom));
        }
    } else {
        config.set_host(&dir, workroom, host)?;
    }
    Ok(dir)
}
