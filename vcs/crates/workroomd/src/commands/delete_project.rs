//! `workroom delete-project PATH --json --confirm PATH`: removes a project so the app's sidebar
//! can drop it, as Go's `Service.DeleteProject` does. App-only, so `--json` only.
//!
//! By default only the config entry goes: nothing on disk is touched. `--with-workrooms` first
//! deletes each registered workroom as `delete` does (`teardown`), stopping at the first failure
//! with the project still registered. `--from-disk` runs each teardown script, drops the project
//! and returns the paths the app moves to the Trash: this never removes a folder itself in that
//! mode, and it refuses a path that would take more than the project with it (the root, HOME, the
//! workrooms folder, or an ancestor of it or of another project). Branches are always kept. A
//! project with any host descriptor, its own or a workroom's, is refused in every mode: it is the
//! only record of a remote machine.
//!
//! `--pretend` skips only the teardowns and the worktrees' removal; the project is still dropped
//! from config, as Go's is.

use std::path::Path;

use serde::Serialize;

use super::config::{self, Config, Json};
use super::envelope;
use super::kind::{CliError, Kind};
use super::teardown::{Confirm, Delete, Watcher};
use super::{Args, Context, Outcome};

#[derive(Serialize)]
struct Payload<'a> {
    path: &'a str,
    with_workrooms: bool,
}

#[derive(Serialize)]
struct FromDiskPayload<'a> {
    from_disk: bool,
    path: &'a str,
    trash_paths: &'a [String],
}

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    if args.positional.len() > 1 {
        return Outcome::Usage(CliError::internal(format!(
            "accepts at most 1 arg(s), received {}",
            args.positional.len()
        )));
    }
    match delete_project(context, args) {
        Ok(outcome) => outcome,
        Err(error) => Outcome::Failed(error),
    }
}

fn delete_project(context: &Context, args: &Args) -> Result<Outcome, CliError> {
    let config = Config::new(context)?;
    if !context.json {
        return Err(CliError::internal(
            "delete-project is only available in --json mode",
        ));
    }
    let [path] = args.positional.as_slice() else {
        return Err(CliError::internal("a path argument is required"));
    };
    // Canonical without asking git, so a project whose folder is gone, or is no repository any
    // more, is still removable. The confirmation may name either form.
    let canon = config::canonical_path(path, context).unwrap_or_else(|_| path.clone());
    let confirm = args.value_or_default("confirm");
    if confirm != canon && confirm != path {
        return Err(CliError::new(
            Kind::ConfirmationMismatch,
            "confirmation value does not match the workroom name: --confirm <path> is required \
             and must match the project path",
        ));
    }
    refuse_remote_project(&config, &canon)?;
    let delete = Delete {
        context,
        config: &config,
        skip_teardown: args.is_set("skip-teardown"),
        watcher: Watcher::App,
    };

    if args.is_set("from-disk") {
        if unsafe_to_delete(&canon, &config, context)? {
            return Err(CliError::new(
                Kind::UnsafeDeletePath,
                format!(
                    "refusing to delete an unsafe or reserved path: refusing to delete {}",
                    envelope::encode(canon.as_str(), false)
                ),
            ));
        }
        let data = config.read()?;
        let names = workroom_names(&data, &canon);
        let workrooms = data
            .as_object()
            .and_then(|top| top.get(&canon))
            .and_then(Json::as_object)
            .and_then(|project| project.get("workrooms"))
            .and_then(Json::as_object);
        let mut paths: Vec<String> = names
            .iter()
            .filter_map(|name| {
                let entry = workrooms?.get(name)?.as_object()?;
                let path = entry.get("path")?.as_str()?;
                (!path.is_empty()).then(|| path.to_string())
            })
            .collect();
        paths.sort();
        let mut trash_paths = vec![canon.clone()];
        trash_paths.extend(paths);
        // A teardown that fails leaves the project registered, so the delete can be retried.
        for name in &names {
            refuse_remote_project(&config, &canon)?;
            delete.run_teardown(&canon, name)?;
        }
        config.remove_project(&canon)?;
        return Ok(Outcome::Success(envelope::success(
            "delete-project",
            &FromDiskPayload {
                from_disk: true,
                path: &canon,
                trash_paths: &trash_paths,
            },
        )));
    }

    let with_workrooms = args.is_set("with-workrooms");
    if with_workrooms {
        // The workrooms deleted before a failure are gone, as when each is deleted by hand; the
        // project stays registered for a retry.
        let names = workroom_names(&config.read()?, &canon);
        for name in &names {
            // Again before each: a descriptor written during the cascade stops it here.
            refuse_remote_project(&config, &canon)?;
            // Go's `Delete(dir, name, name)`: the name confirms itself.
            delete.delete(&canon, name, Confirm::Value(name))?;
        }
    }
    config.remove_project(&canon)?;
    Ok(Outcome::Success(envelope::success(
        "delete-project",
        &Payload {
            path: &canon,
            with_workrooms,
        },
    )))
}

/// The names of every workroom entry `project` has, of any shape, sorted: Go's `WorkroomNames`.
fn workroom_names(data: &Json, project: &str) -> Vec<String> {
    data.as_object()
        .and_then(|top| top.get(project))
        .and_then(Json::as_object)
        .and_then(|project| project.get("workrooms"))
        .and_then(Json::as_object)
        .map(|workrooms| workrooms.keys().cloned().collect())
        .unwrap_or_default()
}

/// Refuses a project with a remote workroom, or with its own descriptor (its base machine).
fn refuse_remote_project(config: &Config, canon: &str) -> Result<(), CliError> {
    let data = config.read()?;
    let projects = config::all_projects(&data);
    let Some(project) = projects.get(canon) else {
        return Ok(());
    };
    let remote: Vec<&str> = project
        .workrooms
        .iter()
        .filter(|(_, workroom)| workroom.is_remote())
        .map(|(name, _)| name.as_str())
        .collect();
    if !remote.is_empty() {
        return Err(CliError::new(
            Kind::RemoteWorkroomUnsupported,
            format!(
                "not supported for a remote workroom yet: {canon} has remote workrooms: {}",
                remote.join(", ")
            ),
        ));
    }
    if project.host.is_some() {
        return Err(CliError::new(
            Kind::RemoteWorkroomUnsupported,
            format!(
                "not supported for a remote workroom yet: {canon} has a remote host (its base machine)"
            ),
        ));
    }
    Ok(())
}

/// Go's `unsafeProjectDeletePath`: whether moving `canon` to the Trash would take more than the
/// project: it is empty, relative or the root, HOME, the workrooms folder or an ancestor of it, or
/// another registered project or an ancestor of one. Compared both as given and symlink-resolved.
fn unsafe_to_delete(canon: &str, config: &Config, context: &Context) -> Result<bool, CliError> {
    if canon.is_empty() || !canon.starts_with('/') || canon == "/" {
        return Ok(true);
    }
    let resolved = config::canonical_path(canon, context);
    let canon = resolved.as_deref().unwrap_or(canon);
    let home = config::home_dir(context)
        .map_err(|error| CliError::internal(format!("determine home directory: {error}")))?;
    let resolve = |path: &str| config::canonical_path(path, context).unwrap_or_default();
    if canon == resolve(&home) || canon == home {
        return Ok(true);
    }
    // Go reads a config it can't parse as naming the default folder here.
    let data = config.read();
    let workrooms_dir = config::workrooms_dir(data.as_ref().unwrap_or(&Json::Null), context)
        .map_err(CliError::internal)?;
    let workrooms_resolved = resolve(&workrooms_dir);
    if canon == workrooms_resolved
        || canon == workrooms_dir
        || is_ancestor(canon, &workrooms_resolved)
    {
        return Ok(true);
    }
    let data = data?;
    for key in config::all_projects(&data).keys() {
        if key == canon {
            continue;
        }
        let other = resolve(key);
        if canon == other || is_ancestor(canon, &other) {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Whether `parent` is a strict ancestor of `child`, both clean absolute paths: Go's
/// `filepath.Rel` test.
fn is_ancestor(parent: &str, child: &str) -> bool {
    if child.is_empty() || !child.starts_with('/') {
        return false;
    }
    let parent = Path::new(parent);
    let child = Path::new(child);
    child != parent && child.starts_with(parent)
}
