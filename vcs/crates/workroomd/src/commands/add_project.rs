//! `workroom add-project PATH --json`: registers a project with no workrooms yet so the app's
//! sidebar can show it, as Go's `Service.AddProject` and `Service.CloneProject` do. App-only, so
//! `--json` only.
//!
//! By default PATH must already be a git repository. `--create` makes a missing folder (and its
//! parents) and git-initializes it with one empty commit, or initializes an existing empty one;
//! `--clone URL` clones URL into PATH first (`clone`), streaming git's progress to stderr as
//! `clone` events. A remote PATH is refused (ADR 0032). `--pretend` writes nothing and reports what
//! would happen (`would_create`, `would_clone`).

mod clone;
mod staging;

use std::path::Path;

use serde::Serialize;

use super::config::{self, Config};
use super::git::is_git_repo;
use super::kind::{CliError, Kind};
use super::log::{CrSplitter, LogWriter};
use super::teardown::go_exit;
use super::{Args, Context, Outcome, envelope, git};

#[derive(Serialize)]
struct Payload<'a> {
    path: &'a str,
    vcs: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    would_clone: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    would_create: Option<bool>,
}

/// What Finder leaves in a folder it has shown, which doesn't make it non-empty. The app's New
/// Project sheet keeps the same list (`AddProjectSheetModel.finderJunk`).
const FINDER_JUNK: [&str; 2] = [".DS_Store", ".localized"];

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    // cobra's `MaximumNArgs(1)`, checked before the command runs.
    if args.positional.len() > 1 {
        return Outcome::Usage(CliError::internal(format!(
            "accepts at most 1 arg(s), received {}",
            args.positional.len()
        )));
    }
    match add_project(context, args) {
        Ok(outcome) => outcome,
        Err(error) => Outcome::Failed(error),
    }
}

fn add_project(context: &Context, args: &Args) -> Result<Outcome, CliError> {
    if !context.json {
        return Err(CliError::internal(
            "add-project is only available in --json mode",
        ));
    }
    let config = Config::new(context)?;
    let [path] = args.positional.as_slice() else {
        return Err(CliError::internal("a path argument is required"));
    };
    if let Some(url) = args.value("clone").filter(|url| !url.is_empty()) {
        if args.is_set("create") {
            return Err(CliError::internal(
                "--clone and --create cannot be used together",
            ));
        }
        // SIGTERM (the app's Cancel), SIGINT or SIGHUP cancels the clone, for as long as it runs,
        // as Go's `signal.NotifyContext` did: one this process was started ignoring included.
        let signals = crate::script::Signals::watch();
        signals.catch_ignored();
        let mut progress = CrSplitter::new(LogWriter::new(std::io::stderr(), "clone"));
        let cloned = clone::clone_project(context, &config, url, path, &mut progress, &signals);
        progress.flush_log();
        let canon = cloned?;
        return Ok(Outcome::Success(envelope::success(
            "add-project",
            &Payload {
                path: &canon,
                vcs: "git",
                would_clone: context.pretend.then_some(true),
                would_create: None,
            },
        )));
    }
    let added = if args.is_set("create") {
        add_created(context, &config, path)?
    } else {
        add_existing(context, &config, path)?
    };
    Ok(Outcome::Success(envelope::success(
        "add-project",
        &Payload {
            path: &added.path,
            vcs: "git",
            would_clone: None,
            would_create: context.pretend.then_some(added.would_create),
        },
    )))
}

/// The project registered, or that would be under `--pretend`.
struct Added {
    path: String,
    would_create: bool,
}

/// `path` canonical, refusing a remote one first, which canonicalizing would turn into
/// `<cwd>/host:repo`.
fn local_canonical(path: &str, context: &Context) -> Result<String, CliError> {
    if is_remote_path(path) {
        return Err(CliError::new(
            Kind::RemoteProjectUnsupported,
            format!(
                "remote projects are not supported: add the project from a local Git repository. \
                 A remote workroom belongs to a local project: {path}"
            ),
        ));
    }
    config::canonical_path(path, context).map_err(CliError::internal)
}

/// Whether `path` names a location on another machine: a URL (ssh://host/repo) or scp-style
/// host:path. It is git's own test: a colon before the first slash, which an absolute, "~/" or "./"
/// path never has.
fn is_remote_path(path: &str) -> bool {
    if path.contains("://") {
        return true;
    }
    match (path.find(':'), path.find('/')) {
        (Some(colon), slash) => colon > 0 && slash.is_none_or(|slash| colon < slash),
        (None, _) => false,
    }
}

/// The default: `path` must already be a git repository. Under `--pretend` it is still checked,
/// but nothing is written.
fn add_existing(context: &Context, config: &Config, path: &str) -> Result<Added, CliError> {
    let canon = local_canonical(path, context)?;
    if !is_git_repo(Path::new(&canon)) {
        return Err(super::teardown::unsupported_vcs());
    }
    if !context.pretend {
        config.add_project(&canon, "git")?;
    }
    Ok(Added {
        path: canon,
        would_create: false,
    })
}

/// `--create`, as Go's `addCreatedProject`:
///
/// ```text
/// stat(canon)
///  ├── a file, or a file in a parent ─► NotADirectory
///  ├── missing ──► make its parents and it (0755), resolve it again
///  └── a folder ─┐
///                ▼
///          a repository? ── yes ─► register it as it is
///           └── no ── empty (Finder's junk aside)? ── yes ─► git init + an empty commit ─► register
///                      └── no ─► UnsupportedVCS
/// ```
///
/// A folder this run made is removed again on any failure after it, so a retry starts clean; one
/// that was already there never is. Under `--pretend` nothing changes.
fn add_created(context: &Context, config: &Config, path: &str) -> Result<Added, CliError> {
    let canon = local_canonical(path, context)?;
    let exists = match std::fs::metadata(&canon) {
        Ok(info) if !info.is_dir() => return Err(not_a_directory()),
        Ok(_) => true,
        Err(error) if error.raw_os_error() == Some(libc::ENOTDIR) => {
            return Err(not_a_directory());
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        Err(error) => {
            return Err(CliError::internal(format!(
                "stat {canon}: {}",
                config::os_error(&error)
            )));
        }
    };
    if context.pretend {
        return Ok(Added {
            path: canon,
            would_create: !exists,
        });
    }
    let canon = if exists {
        initialize_and_register(config, &canon)?;
        canon
    } else {
        create_missing(context, config, canon)?
    };
    Ok(Added {
        path: canon,
        would_create: false,
    })
}

/// Makes the folder `canon` the stat found missing, then initializes and registers it as
/// [`initialize_and_register`] does, returning its path resolved again. Only a folder this run's
/// own exclusive `mkdir` made is removed again on failure, so a retry starts clean: one another
/// process made since the stat is taken as already there, as Go's `MkdirAll` takes it, and is
/// never removed.
fn create_missing(context: &Context, config: &Config, canon: String) -> Result<String, CliError> {
    let claimed = claim_dir(&canon)?;
    // The folder exists now, so resolve it again: under a symlinked parent it is stored in its
    // symlink-evaluated form, as an existing project's path is.
    let canon = config::canonical_path(&canon, context).unwrap_or(canon);
    let registered = initialize_and_register(config, &canon);
    if registered.is_err() && claimed {
        // This run made it, so nothing in it is anyone else's: an aborted init must not leave a
        // repository without a commit for the next try to take as a project.
        let _ = std::fs::remove_dir_all(&canon);
    }
    registered.map(|()| canon)
}

/// Makes `canon`'s parents (0755) as `mkdir -p` would, then `canon` itself with an exclusive
/// `mkdir`: `true` when this run made it, `false` when a folder was already there by then.
fn claim_dir(canon: &str) -> Result<bool, CliError> {
    use std::os::unix::fs::DirBuilderExt;
    let refused = |error: config::MkdirError| {
        if error.error.raw_os_error() == Some(libc::ENOTDIR) {
            not_a_directory()
        } else {
            config_write(format!("create directory {canon}: {error}"))
        }
    };
    let parent = &canon[..canon.rfind('/').unwrap_or(0)];
    if !parent.is_empty() {
        config::make_dir_all(parent).map_err(refused)?;
    }
    match std::fs::DirBuilder::new().mode(0o755).create(canon) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            if std::fs::metadata(canon).is_ok_and(|info| info.is_dir()) {
                Ok(false)
            } else {
                Err(not_a_directory())
            }
        }
        Err(error) => Err(refused(config::MkdirError {
            path: canon.to_string(),
            error,
        })),
    }
}

/// git-initializes `canon` when it is no repository and is empty, then registers it.
fn initialize_and_register(config: &Config, canon: &str) -> Result<(), CliError> {
    let dir = Path::new(canon);
    if !is_git_repo(dir) {
        if !dir_is_empty(dir, &[])? {
            return Err(super::teardown::unsupported_vcs());
        }
        init_git(dir).map_err(|error| {
            CliError::new(
                Kind::VcsCommandFailed,
                format!("version control command failed: git init {canon}: {error}"),
            )
        })?;
        if !is_git_repo(dir) {
            return Err(super::teardown::unsupported_vcs());
        }
    }
    config.add_project(canon, "git")
}

/// `git init`, then an empty first commit so the repository has a HEAD for a workroom to branch
/// from, with the identity and signing pinned and hooks skipped, so it works on a machine with no
/// git config at all: Go's `InitGit`. The error is Go's `exec` wording of what failed.
fn init_git(dir: &Path) -> Result<(), String> {
    let run = |args: &[&str]| -> Result<(), String> {
        let output = git::command(dir)
            .args(args)
            .output()
            .map_err(|error| go_start_error("git", &error))?;
        if output.status.success() {
            Ok(())
        } else {
            Err(go_exit(&output.status))
        }
    };
    run(&["init"])?;
    run(&[
        "-c",
        "user.name=Workroom",
        "-c",
        "user.email=workroom@localhost",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--allow-empty",
        "--no-verify",
        "-m",
        "Initial commit",
    ])
}

/// How Go's `exec` words a program that couldn't be started.
fn go_start_error(program: &str, error: &std::io::Error) -> String {
    if error.kind() == std::io::ErrorKind::NotFound {
        format!("exec: {program:?}: executable file not found in $PATH")
    } else {
        format!("fork/exec {program}: {}", config::os_error(error))
    }
}

/// Whether `dir` holds nothing but Finder's junk and the paths in `ignore`.
fn dir_is_empty(dir: &Path, ignore: &[std::path::PathBuf]) -> Result<bool, CliError> {
    let entries = std::fs::read_dir(dir).map_err(|error| {
        CliError::internal(format!(
            "open {}: {}",
            dir.display(),
            config::os_error(&error)
        ))
    })?;
    for entry in entries {
        let entry = entry.map_err(|error| {
            CliError::internal(format!(
                "readdirent {}: {}",
                dir.display(),
                config::os_error(&error)
            ))
        })?;
        let name = entry.file_name();
        if FINDER_JUNK.iter().any(|junk| name == *junk) || ignore.contains(&entry.path()) {
            continue;
        }
        return Ok(false);
    }
    Ok(true)
}

/// What a cancelling signal ends a clone with.
fn cancelled() -> CliError {
    CliError::new(Kind::Cancelled, "operation cancelled")
}

fn not_a_directory() -> CliError {
    CliError::new(Kind::NotADirectory, "path exists but is not a directory")
}

/// `ConfigWriteFailed`, worded as Go wraps `ErrConfigWrite`.
fn config_write(detail: String) -> CliError {
    CliError::new(
        Kind::ConfigWriteFailed,
        format!("failed to write config: {detail}"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_remote_path_is_one_with_a_colon_before_any_slash_or_a_scheme() {
        for remote in [
            "host:repo",
            "git@example.com:org/repo.git",
            "ssh://host/repo",
        ] {
            assert!(is_remote_path(remote), "{remote}");
        }
        for local in ["/a:b", "./a:b", "~/x", "repo", ":x", "a/b:c"] {
            assert!(!is_remote_path(local), "{local}");
        }
    }

    #[test]
    fn a_folder_made_after_the_stat_survives_a_failed_create() {
        // Another process made the folder between `--create`'s stat and its mkdir: this run
        // didn't make it, so its failure must leave it, and what is in it, alone.
        let dir = scratch("raced");
        let dest = dir.join("dest");
        std::fs::create_dir(&dest).unwrap();
        std::fs::write(dest.join("keep"), "theirs").unwrap();
        let config = Config::at(dir.join("config.json"));
        let error =
            create_missing(&context(), &config, dest.to_str().unwrap().to_string()).unwrap_err();
        assert_eq!(error.kind, Kind::UnsupportedVcs, "{}", error.message);
        assert_eq!(
            std::fs::read_to_string(dest.join("keep")).unwrap(),
            "theirs"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_folder_this_create_made_is_removed_when_it_fails() {
        // A config under a file can't be written, so registering fails after the folder is
        // made and initialized.
        let dir = scratch("made");
        let dest = dir.join("parent").join("dest");
        std::fs::write(dir.join("blocker"), "").unwrap();
        let config = Config::at(dir.join("blocker").join("config.json"));
        create_missing(&context(), &config, dest.to_str().unwrap().to_string()).unwrap_err();
        assert!(!dest.exists(), "the folder this run made is left behind");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    fn context() -> Context {
        Context {
            json: true,
            pretend: false,
            verbose: false,
            platform: super::super::Platform::current(),
            env: |_| None,
            color: false,
            // Never looked for in tests (#684): a test run in a pane must not find a real daemon.
            daemon_above: || None,
        }
    }

    /// A new directory of this test's own under the system temp dir, removed by the test.
    fn scratch(name: &str) -> std::path::PathBuf {
        for attempt in 0u32.. {
            let dir = std::env::temp_dir().join(format!(
                "workroom-add-project-{name}-{}-{attempt}",
                std::process::id()
            ));
            if std::fs::create_dir(&dir).is_ok() {
                return dir.canonicalize().unwrap();
            }
        }
        unreachable!()
    }
}
