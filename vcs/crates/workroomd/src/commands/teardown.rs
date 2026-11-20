//! Deleting one local workroom as Go's `Service.Delete` does: its approved teardown script, then
//! `git worktree remove --force`, then its config entry. Its branch is always kept. A workroom
//! whose folder holds no git checkout (a workspace Jujutsu made before #266) is only forgotten,
//! its folder left for the user, and nothing runs in it.
//!
//! `delete-project --with-workrooms` and `--from-disk` are its callers (#672); `delete` (#678) is
//! its next. The trust gate here is Go's `gateFound` without a person to ask: the `--json` caller
//! has none, so a script this Mac hasn't approved is refused with its bytes in the envelope, for
//! the app to show and approve (`trust`, #674, owns approving).

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;

use super::config::{self, Config, Json};
use super::git::is_git_repo;
use super::kind::{CliError, Kind};
use super::list::workspace_names;
use super::log::{LogWriter, go_lossy};
use super::{Context, git};

/// The project script a workroom's teardown runs, and its name in `trusted_scripts`.
const TEARDOWN: &str = "workroom_teardown";

/// The largest script read to judge, as Go's `MaxScriptBytes`.
const MAX_SCRIPT_BYTES: u64 = 1 << 20;

/// Between the SIGTERM and the SIGKILL when a teardown is ended: the app SIGKILLs the CLI two
/// seconds after its SIGTERM, so this leaves time to report (`docs/designs/one-script-runner.md`).
const KILL_GRACE: Duration = Duration::from_secs(1);

/// How a delete runs: `--pretend` and `--skip-teardown`.
pub(super) struct Delete<'a> {
    pub(super) context: &'a Context,
    pub(super) config: &'a Config,
    pub(super) skip_teardown: bool,
}

impl Delete<'_> {
    fn pretend(&self) -> bool {
        self.context.pretend
    }

    fn data(&self) -> Result<Json, CliError> {
        self.config.read()
    }

    /// Where workroom `name`'s checkout is on this Mac: `workrooms_dir/<name>`, as Go's
    /// `workroomPath` finds it, whatever the entry records.
    fn workroom_path(&self, name: &str) -> Result<PathBuf, CliError> {
        // Go reads a config it can't parse as naming the default folder.
        let data = self.data().unwrap_or(Json::Null);
        let dir = config::workrooms_dir(&data, self.context).map_err(CliError::internal)?;
        Ok(Path::new(&dir).join(name))
    }

    /// Deletes workroom `name` of project `dir`, as Go's `Delete(dir, name, name)`.
    pub(super) fn delete(&self, dir: &str, name: &str) -> Result<(), CliError> {
        if std::fs::metadata(Path::new(dir).join(".Workroom")).is_ok() {
            return Err(CliError::new(
                Kind::InWorkroom,
                "looks like you are already in a workroom. Run this command from the root of your \
                 main development directory, not from within an existing workroom",
            ));
        }
        if !valid_name(name) {
            return Err(CliError::new(
                Kind::InvalidName,
                format!(
                    "workroom name must be alphanumeric (dashes and underscores allowed), and must \
                     not start or end with a dash or underscore: {}",
                    super::envelope::encode(name, false)
                ),
            ));
        }
        let destroyed = self.destroyed_remote(dir, name)?;
        if !destroyed && !is_git_repo(Path::new(dir)) {
            return Err(unsupported_vcs());
        }
        if !self.pretend() && !destroyed {
            let listed = workspace_names(dir, "git")
                .ok_or_else(|| CliError::internal(format!("git worktree list in {dir} failed")))?;
            if !listed.iter().any(|listed| listed == name) {
                if self.non_git_workroom_path(dir, name)?.is_none() {
                    return Err(CliError::new(
                        Kind::WorkspaceNotFound,
                        format!(
                            "git worktree does not exist: Git worktree '{name}' does not exist"
                        ),
                    ));
                }
                // Only its entry goes: no git there (it would find an ancestor repository) and no
                // teardown (it would run in that folder). The folder is the user's.
                return self.config.remove_workroom(dir, name);
            }
        }
        if destroyed {
            // Nothing runs: there is no box for the teardown, and no workspace on this Mac.
            if !self.pretend() {
                self.config.remove_workroom(dir, name)?;
            }
            return Ok(());
        }
        let path = self.workroom_path(name)?;
        self.run_teardown(dir, name)?;
        if !self.pretend() {
            let output = git::command(Path::new(dir))
                .arg("worktree")
                .arg("remove")
                .arg(&path)
                .arg("--force")
                .output()
                .map_err(|error| vcs_failed(&error.to_string()))?;
            if !output.status.success() {
                return Err(vcs_failed(&go_exit(&output.status)));
            }
            self.config.remove_workroom(dir, name)?;
        }
        Ok(())
    }

    /// Whether `name` is a remote workroom whose host is already destroyed, which is only
    /// forgotten. A remote workroom whose host is still there is refused.
    fn destroyed_remote(&self, dir: &str, name: &str) -> Result<bool, CliError> {
        let data = self.data()?;
        let projects = config::all_projects(&data);
        let workroom = projects
            .get(dir)
            .and_then(|project| project.workrooms.get(name));
        match workroom {
            Some(workroom) if workroom.is_remote() && !workroom.host_destroyed() => {
                Err(remote_workroom(name))
            }
            Some(workroom) => Ok(workroom.host_destroyed()),
            None => Ok(false),
        }
    }

    /// The recorded path of workroom `name` when its folder holds no git checkout, else none.
    fn non_git_workroom_path(&self, dir: &str, name: &str) -> Result<Option<String>, CliError> {
        let data = self.data()?;
        let projects = config::all_projects(&data);
        let Some(workroom) = projects
            .get(dir)
            .and_then(|project| project.workrooms.get(name))
        else {
            return Ok(None);
        };
        // A remote workroom's path is on its host, so its absent local .git says nothing about it.
        if workroom.path.is_empty()
            || workroom.is_remote()
            || is_git_repo(Path::new(&workroom.path))
        {
            return Ok(None);
        }
        Ok(Some(workroom.path.clone()))
    }

    /// Runs workroom `name`'s teardown script, if it has one, as Go's `RunTeardown`: the
    /// workroom's own copy, else the project root's, once this Mac has approved its bytes, with its
    /// output streamed to stderr as `teardown` events. Under `--pretend` nothing runs, and
    /// `--skip-teardown` skips it.
    pub(super) fn run_teardown(&self, dir: &str, name: &str) -> Result<(), CliError> {
        let data = self.data()?;
        let projects = config::all_projects(&data);
        if projects
            .get(dir)
            .and_then(|project| project.workrooms.get(name))
            .is_some_and(config::Workroom::is_remote)
        {
            return Err(remote_workroom(name));
        }
        let path = self.workroom_path(name)?;
        let Some(script) = find_script(&path, Path::new(dir)) else {
            return Ok(());
        };
        if self.skip_teardown || self.pretend() {
            return Ok(());
        }
        self.gate(dir, &path, &script)?;
        let variables = crate::script::local_variables(name, &path, Path::new(dir));
        let mut runner = crate::script::Script::new(&script, &path, &variables, None);
        runner.kill_grace = KILL_GRACE;
        let mut events = Events(LogWriter::new(std::io::stderr(), "teardown"));
        let outcome = crate::script::run(
            &runner,
            crate::script::Output::Combined(&mut events),
            |reason| {
                format!(
                    "workroom: couldn't read the login shell's environment ({reason}); using the \
                     current one\n"
                )
            },
        );
        events.0.flush();
        let script = script.display();
        match outcome {
            outcome if outcome.passed() => Ok(()),
            crate::script::Outcome::NotStarted(error) => Err(CliError::new(
                Kind::TeardownScriptFailed,
                format!("teardown script failed: {script} could not be started: {error}"),
            )),
            _ => Err(CliError::new(
                Kind::TeardownScriptFailed,
                format!("teardown script failed: {script} returned a non-zero exit code"),
            )),
        }
    }

    /// Go's `gateFound`: lets the script at `path` through when this Mac approved its bytes, or
    /// when they are the root's gitignored copy, which no pull brings; refuses it otherwise.
    fn gate(&self, dir: &str, workroom: &Path, path: &Path) -> Result<(), CliError> {
        let Some(text) = read_script(path)? else {
            return Ok(());
        };
        let origin = if path.parent().and_then(Path::parent) == Some(workroom) {
            "workroom"
        } else {
            "root"
        };
        let sha256 = sha256_hex(&text);
        let data = self.data()?;
        let approved = data
            .as_object()
            .and_then(|top| top.get(dir))
            .and_then(Json::as_object)
            .and_then(|project| project.get("trusted_scripts"))
            .and_then(Json::as_object)
            .and_then(|trusted| trusted.get(TEARDOWN))
            .and_then(Json::as_str)
            == Some(sha256.as_str());
        let file = format!("scripts/{TEARDOWN}");
        let exempt = ignored_root_copy(Path::new(dir), &file, &sha256);
        if approved || exempt {
            return Ok(());
        }
        Err(untrusted(Untrusted {
            bytes: crate::util::base64(&text),
            exempt,
            file,
            name: TEARDOWN.to_string(),
            origin: origin.to_string(),
            sha256,
            text: go_lossy(&text),
            trusted: false,
        }))
    }
}

/// `<wr>/scripts/workroom_teardown` when it exists (following a symlink), else the root's, else
/// none: Go's `findScript`.
fn find_script(workroom: &Path, root: &Path) -> Option<PathBuf> {
    [workroom, root]
        .iter()
        .map(|base| base.join("scripts").join(TEARDOWN))
        .find(|path| std::fs::metadata(path).is_ok())
}

/// The regular file at `path`, following a symlink, refusing anything else or anything over
/// [`MAX_SCRIPT_BYTES`]; none when there is no file.
fn read_script(path: &Path) -> Result<Option<Vec<u8>>, CliError> {
    let refused = |why: &str| {
        CliError::new(
            Kind::ScriptNotTrusted,
            format!(
                "script is not trusted on this Mac: {} {why}",
                path.display()
            ),
        )
    };
    let info = match std::fs::metadata(path) {
        Ok(info) => info,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(CliError::internal(error.to_string())),
    };
    if !info.is_file() {
        return Err(refused("is not a regular file"));
    }
    let too_big = || refused(&format!("is larger than {MAX_SCRIPT_BYTES} bytes"));
    if info.len() > MAX_SCRIPT_BYTES {
        return Err(too_big());
    }
    let mut text = Vec::new();
    let file = std::fs::File::open(path).map_err(|error| CliError::internal(error.to_string()))?;
    std::io::Read::read_to_end(
        &mut std::io::Read::take(file, MAX_SCRIPT_BYTES + 1),
        &mut text,
    )
    .map_err(|error| CliError::internal(error.to_string()))?;
    if text.len() as u64 > MAX_SCRIPT_BYTES {
        return Err(too_big());
    }
    Ok(Some(text))
}

/// Whether the root's file at `relative` is a gitignored regular file (not a symlink) holding the
/// bytes whose SHA-256 is `digest`.
fn ignored_root_copy(root: &Path, relative: &str, digest: &str) -> bool {
    let path = root.join(relative);
    if !std::fs::symlink_metadata(&path).is_ok_and(|info| info.is_file()) {
        return false;
    }
    let Ok(Some(text)) = read_script(&path) else {
        return false;
    };
    sha256_hex(&text) == digest
        && git::command(root)
            .args(["check-ignore", "-q", "--", relative])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
}

/// The script a `ScriptNotTrusted` carries, in Go's `scriptPayload` key order.
#[derive(Serialize)]
struct Untrusted {
    bytes: String,
    exempt: bool,
    file: String,
    name: String,
    origin: String,
    sha256: String,
    text: String,
    trusted: bool,
}

fn untrusted(script: Untrusted) -> CliError {
    // `workroom trust` judges the root's copy, never a workroom's own.
    let (label, how) = if script.origin == "workroom" {
        (
            "in the workroom",
            "Run the same command in a terminal to review and approve it",
        )
    } else {
        (
            "in the project's root",
            "Review and approve it with `workroom trust`",
        )
    };
    let mut error = CliError::new(
        Kind::ScriptNotTrusted,
        format!(
            "script is not trusted on this Mac: {} {label} is new, or changed since it was \
             approved. {how}",
            script.file
        ),
    );
    error.script = Some(super::envelope::encode(&script, false));
    error
}

/// Go's `validNameRe`: letters and digits, with dashes and underscores inside.
fn valid_name(name: &str) -> bool {
    let bytes = name.as_bytes();
    let edge = |byte: &u8| byte.is_ascii_alphanumeric();
    bytes.first().is_some_and(edge)
        && bytes.last().is_some_and(edge)
        && bytes
            .iter()
            .all(|byte| byte.is_ascii_alphanumeric() || *byte == b'-' || *byte == b'_')
}

fn sha256_hex(bytes: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, bytes)
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

pub(super) fn unsupported_vcs() -> CliError {
    CliError::new(
        Kind::UnsupportedVcs,
        "no supported VCS detected in this directory. Workroom requires Git to manage workrooms",
    )
}

fn remote_workroom(name: &str) -> CliError {
    CliError::new(
        Kind::RemoteWorkroomUnsupported,
        format!("not supported for a remote workroom yet: workroom '{name}' is remote"),
    )
}

fn vcs_failed(detail: &str) -> CliError {
    CliError::new(
        Kind::VcsCommandFailed,
        format!("version control command failed: {detail}"),
    )
}

/// How Go's `exec.ExitError` words an exit: `exit status N`, or `signal: …`.
pub(super) fn go_exit(status: &std::process::ExitStatus) -> String {
    use std::os::unix::process::ExitStatusExt;
    match (status.code(), status.signal()) {
        (Some(code), _) => format!("exit status {code}"),
        (None, Some(signal)) => format!("signal: {signal}"),
        (None, None) => "exit status -1".to_string(),
    }
}

/// The script's combined output as `teardown` events, a line at a time.
struct Events<W: Write>(LogWriter<W>);

impl<W: Write> Write for Events<W> {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.feed(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
