//! `workroom list`: every project and its workrooms, with warnings for the ones that look broken.
//!
//! With `--json` it is the app's listing, the same from any directory: every registered project,
//! empty ones too, sorted by path, each one's workrooms by name, with warnings at the `--warnings`
//! level. Without it, it is what a person sees from where they stand: the workroom they are in, the
//! project they are at the root of, or every project that has workrooms.
//!
//! `list --socket <path>` is not this: it is the daemon's session listing (ADR 0057), which
//! `cli::route` sends to the daemon before the CLI runs.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;

use serde::Serialize;

use super::config::{self, Config, Json, Project};
use super::git::is_git_repo;
use super::kind::CliError;
use super::panel::Paint;
use super::{Args, Context, Outcome};

/// How much work the listing does for its warnings.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Warnings {
    /// Config alone: no filesystem or VCS call, and each project's stored type verbatim.
    None,
    /// Also each workroom's directory, and each project's type detected from disk, healing the
    /// stored one when it differs (not under `--pretend`).
    Fast,
    /// Also each project's VCS workspaces, listed once per project.
    Full,
}

impl Warnings {
    fn parse(value: &str) -> Option<Warnings> {
        match value {
            "none" => Some(Warnings::None),
            "fast" => Some(Warnings::Fast),
            "full" => Some(Warnings::Full),
            _ => None,
        }
    }
}

/// One machine-readable workroom warning.
#[derive(Serialize)]
struct Warning {
    kind: &'static str,
    message: String,
    #[serde(skip_serializing_if = "str::is_empty")]
    path: String,
    #[serde(skip_serializing_if = "str::is_empty")]
    vcs: String,
}

#[derive(Serialize)]
struct WorkroomInfo {
    name: String,
    path: String,
    vcs_name: String,
    /// The entry's host descriptor, verbatim; absent for a workroom on this Mac.
    #[serde(skip_serializing_if = "Option::is_none")]
    host: Option<Json>,
    warnings: Vec<Warning>,
}

#[derive(Serialize)]
struct ProjectInfo {
    path: String,
    vcs: String,
    /// The project's host descriptor, verbatim; a project with one is still a local repository.
    #[serde(skip_serializing_if = "Option::is_none")]
    host: Option<Json>,
    #[serde(skip_serializing_if = "str::is_empty")]
    base_branch: String,
    /// Whether the root has an include file; absent at `--warnings none`, which reads only config.
    #[serde(skip_serializing_if = "Option::is_none")]
    has_include: Option<bool>,
    workrooms: Vec<WorkroomInfo>,
}

#[derive(Serialize)]
struct Payload {
    /// The global default base, left out when unset.
    #[serde(skip_serializing_if = "str::is_empty")]
    base_branch: String,
    config_path: String,
    projects: Vec<ProjectInfo>,
    workrooms_dir: String,
}

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    match list(context, args) {
        Ok(outcome) => outcome,
        Err(error) => Outcome::Failed(error),
    }
}

fn list(context: &Context, args: &Args) -> Result<Outcome, CliError> {
    let config = Config::new(context)?;
    if context.json {
        json(context, args, &config)
    } else {
        human(context, &config, &mut std::io::stdout().lock())?;
        // Already written, a project at a time.
        Ok(Outcome::Printed(String::new()))
    }
}

fn json(context: &Context, args: &Args, config: &Config) -> Result<Outcome, CliError> {
    let value = args.value_or_default("warnings");
    let level = Warnings::parse(value).ok_or_else(|| {
        CliError::internal(format!(
            "invalid --warnings value {value:?} (want none, fast, or full)"
        ))
    })?;
    let data = config.read()?;
    let mut projects: Vec<ProjectInfo> = config::all_projects(&data)
        .iter()
        .map(|(path, project)| project_info(heal(context, config), path, project, level))
        .collect();
    if let Some(wanted) = args.value("project").filter(|wanted| !wanted.is_empty()) {
        let canonical = config::canonical_path(wanted, context).map_err(CliError::internal)?;
        projects.retain(|project| project.path == canonical || project.path == wanted);
    }
    let payload = Payload {
        base_branch: config::base_branch(&data),
        config_path: config.path().to_string_lossy().into_owned(),
        projects,
        workrooms_dir: config::workrooms_dir(&data, context).unwrap_or_default(),
    };
    Ok(Outcome::Success(super::envelope::success("list", &payload)))
}

/// The config a listing heals a stale type in: `config`, but none under `--pretend`.
fn heal<'a>(context: &Context, config: &'a Config) -> Option<&'a Config> {
    (!context.pretend).then_some(config)
}

/// One project's view, its warnings computed at `level`. The human list and `--json` share it, so
/// both name each problem alike. A stale type is healed in `heal`, the config, which is none
/// under `--pretend` (#798).
fn project_info(
    heal: Option<&Config>,
    path: &str,
    project: &Project,
    level: Warnings,
) -> ProjectInfo {
    let vcs = if level == Warnings::None {
        project.vcs.clone()
    } else {
        effective_vcs(heal, path, &project.vcs)
    };
    let checks_dir = level != Warnings::None;
    // Listed once per project. None means the listing couldn't be had, which warns of nothing.
    let workspaces = (level == Warnings::Full)
        .then(|| workspace_names(path, &vcs))
        .flatten();
    let workrooms = project
        .workrooms
        .iter()
        .map(|(name, workroom)| {
            let mut warnings = Vec::new();
            if workroom.host_destroyed() {
                // From config alone, so at every level.
                warnings.push(Warning {
                    kind: "HostDestroyed",
                    message: "host destroyed by its provider".to_string(),
                    path: String::new(),
                    vcs: String::new(),
                });
            } else if !workroom.is_remote() {
                // Both checks are local: a remote workroom's path is on its host, and a remote
                // clone is never one of the local repository's workspaces.
                if checks_dir && is_missing(&workroom.path) {
                    warnings.push(Warning {
                        kind: "DirectoryMissing",
                        message: "directory not found".to_string(),
                        path: workroom.path.clone(),
                        vcs: String::new(),
                    });
                }
                if workspaces
                    .as_ref()
                    .is_some_and(|names| !names.contains(name))
                {
                    warnings.push(Warning {
                        kind: "VCSWorkroomMissing",
                        message: format!("{vcs} workroom not found"),
                        path: String::new(),
                        vcs: vcs.clone(),
                    });
                }
            }
            WorkroomInfo {
                name: name.clone(),
                path: workroom.path.clone(),
                vcs_name: format!("workroom/{name}"),
                host: workroom.host.clone(),
                warnings,
            }
        })
        .collect();
    ProjectInfo {
        path: path.to_string(),
        vcs,
        host: project.host.clone(),
        base_branch: project.base_branch.clone(),
        has_include: checks_dir.then(|| Path::new(path).join(".worktreeinclude").exists()),
        workrooms,
    }
}

/// Only "no such file" counts as missing, as Go's `os.IsNotExist`: a directory that can't be read
/// for another reason isn't reported gone.
fn is_missing(path: &str) -> bool {
    std::fs::metadata(path).is_err_and(|error| error.raw_os_error() == Some(libc::ENOENT))
}

/// The project's type as its directory shows it, so a stale stored type (a `jj` from before
/// Jujutsu support was removed) is reported right and healed in `heal`, the config, when there is
/// one. The stored type when the directory is gone or isn't a repository, so a moved project
/// still lists.
fn effective_vcs(heal: Option<&Config>, path: &str, stored: &str) -> String {
    if !is_git_repo(Path::new(path)) {
        return stored.to_string();
    }
    if let Some(config) = heal.filter(|_| stored != "git") {
        // Best-effort: the answer is already right even if the write fails.
        let _ = config.set_project_vcs(path, "git");
    }
    "git".to_string()
}

/// The names of the project's VCS workspaces: the base names of git's linked worktrees. None when
/// they can't be listed (no type, an unknown one, or a failed git), which the caller must read as
/// "don't warn", unlike an empty list.
pub(super) fn workspace_names(path: &str, vcs: &str) -> Option<Vec<String>> {
    if vcs != "git" {
        return None;
    }
    let names = worktree_paths(path)?
        .into_iter()
        .map(|directory| {
            Path::new(&directory).file_name().map_or_else(
                || directory.clone(),
                |name| name.to_string_lossy().into_owned(),
            )
        })
        .collect();
    Some(names)
}

/// The folders of the git project at `path`'s linked worktrees, as `git worktree list` prints
/// them: Go's `listWorktreePaths`. None when git fails.
pub(super) fn worktree_paths(path: &str) -> Option<Vec<String>> {
    let output = super::git::command(Path::new(path))
        .args(["worktree", "list", "--porcelain"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    let mut paths = Vec::new();
    let mut directory = "";
    for line in text.trim().split('\n') {
        if let Some(listed) = line.strip_prefix("worktree ") {
            directory = listed;
            continue;
        }
        let mut fields = line.split_whitespace();
        if fields.next() == Some("HEAD") && fields.next().is_some() && directory != path {
            paths.push(directory.to_string());
        }
    }
    Some(paths)
}

/// The human list from the working directory, written to `out` as it goes: the workroom it is in,
/// the project it is the root of, or every project with workrooms, each with its warnings. Each
/// project's path is written before its checks run, and its table before the next one's, as Go
/// writes them, so a project that stalls (a hung network volume) is named and holds back nothing
/// before it. A failed write is ignored, as Go's `fmt.Fprintln` is.
fn human(context: &Context, config: &Config, out: &mut impl Write) -> Result<(), CliError> {
    let cwd = config::getwd(context).map_err(CliError::internal)?;
    let data = config.read()?;
    let home = config::home_dir(context).ok();
    let display = |path: &str| config::display_path(home.as_deref(), path);
    let paint = Paint(context.color);
    let table = |project: &ProjectInfo| {
        let rows: Vec<Vec<String>> = project
            .workrooms
            .iter()
            .map(|workroom| {
                let mut row = vec![
                    paint.bold(&workroom.name),
                    paint.dim(&display(&workroom.path)),
                ];
                if !workroom.warnings.is_empty() {
                    let messages: Vec<&str> = workroom
                        .warnings
                        .iter()
                        .map(|warning| warning.message.as_str())
                        .collect();
                    row.push(paint.yellow(&format!("[{}]", messages.join(", "))));
                }
                row
            })
            .collect();
        print_table(&rows, 2)
    };

    let mut write = |text: &str| {
        let _ = out.write_all(text.as_bytes()).and_then(|()| out.flush());
    };
    match config::find_current_project(&data, &cwd) {
        Some((parent, _)) if parent != cwd => {
            write(&format!(
                "{}\nParent project is at {}\n",
                paint.yellow("You are already in a workroom."),
                display(&parent)
            ));
        }
        Some((path, project)) => {
            if project.workrooms.is_empty() {
                write("No workrooms found for this project.\n");
            } else {
                write(&table(&project_info(
                    heal(context, config),
                    &path,
                    &project,
                    Warnings::Full,
                )));
            }
        }
        None => {
            let projects: BTreeMap<String, Project> = config::all_projects(&data)
                .into_iter()
                .filter(|(_, project)| project.entries > 0)
                .collect();
            if projects.is_empty() {
                write("No workrooms found.\n");
            }
            for (path, project) in &projects {
                write(&format!("{}:\n", display(path)));
                write(&table(&project_info(
                    heal(context, config),
                    path,
                    project,
                    Warnings::Full,
                )));
                write("\n");
            }
        }
    }
    Ok(())
}

/// `rows` as columns two spaces apart, each as wide as its widest cell without its colour codes,
/// the last cell of a row never padded.
fn print_table(rows: &[Vec<String>], indent: usize) -> String {
    let columns = rows.iter().map(Vec::len).max().unwrap_or(0);
    let mut widths = vec![0; columns];
    for row in rows {
        for (index, cell) in row.iter().enumerate() {
            widths[index] = widths[index].max(strip_ansi(cell).len());
        }
    }
    let mut out = String::new();
    for row in rows {
        out += &" ".repeat(indent);
        for (index, cell) in row.iter().enumerate() {
            if index > 0 {
                out += "  ";
            }
            out += cell;
            if index + 1 < row.len() {
                out += &" ".repeat(widths[index] - strip_ansi(cell).len());
            }
        }
        out += "\n";
    }
    out
}

/// `text` without its ANSI escape sequences, for measuring it.
fn strip_ansi(text: &str) -> String {
    let mut plain = String::new();
    let mut escaped = false;
    for ch in text.chars() {
        if ch == '\x1b' {
            escaped = true;
        } else if escaped {
            escaped = !ch.is_ascii_alphabetic();
        } else {
            plain.push(ch);
        }
    }
    plain
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_table_pads_each_column_but_the_last_cell_by_its_text_alone() {
        let rows = vec![
            vec![Paint(true).bold("a"), "~/x".to_string()],
            vec![
                "calm".to_string(),
                "~/workrooms/calm".to_string(),
                "[gone]".to_string(),
            ],
        ];
        // The bytes the retired Go CLI's list printed: bold ends with `\x1b[22m`.
        assert_eq!(
            print_table(&rows, 2),
            "  \x1b[1ma\x1b[22m     ~/x\n  calm  ~/workrooms/calm  [gone]\n"
        );
    }

    #[test]
    fn only_no_such_file_is_missing() {
        assert!(is_missing("/nonexistent/workroom"));
        assert!(is_missing(""));
        assert!(!is_missing("/"));
        // A file in the way is ENOTDIR, not ENOENT.
        assert!(!is_missing("/etc/hosts/x"));
    }
}
