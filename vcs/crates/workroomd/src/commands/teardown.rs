//! Deleting one local workroom as Go's `Service.Delete` does: its approved teardown script, then
//! `git worktree remove --force`, then its config entry. Its branch is always kept. A workroom
//! whose folder holds no git checkout (a workspace Jujutsu made before #266) is only forgotten,
//! its folder left for the user, and nothing runs in it.
//!
//! `delete` (#678) and `delete-project --with-workrooms` and `--from-disk` (#672) are its callers.
//! The trust gate here is Go's `gateFound`: a script this Mac hasn't approved is refused with its
//! bytes in the envelope, for the app to show and approve, unless a person at a terminal is there
//! to be asked. The judging is `trusted_script`'s, the one `trust` uses (#674).
//!
//! Nothing here removes a folder itself. The one removal is `git worktree remove`, run in the
//! project, of `<workrooms folder>/<name>`, and git's own check covers it: git removes only a
//! worktree of that repository registered at that path, so a folder of the user's, or another
//! project's worktree, there is refused, not removed. The teardown runs in that folder before
//! git is asked, so `run_teardown` first checks that git registers that very folder as a worktree
//! of the project, symlinks resolved, and refuses it otherwise: a name git lists is no proof, as
//! any folder of that name matches it. This covers every caller: `delete NAME`, a person's picks,
//! and `delete-project`'s cascade and `--from-disk`. Every name, a config key's too, must be
//! letters, digits, dashes and underscores before it is joined onto the workrooms folder, so the
//! path never leaves it.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use super::config::{self, Config, Json};
use super::git::is_git_repo;
use super::kind::{CliError, Kind};
use super::list::{workspace_names, worktree_paths};
use super::log::LogWriter;
use super::panel::{LogPanel, Paint};
use super::trusted_script::{Judge, Script, TEARDOWN_SCRIPT};
use super::{Context, git};

/// Go's `ErrInvalidName`, which each refusal of a name begins with.
pub(super) const INVALID_NAME: &str = "workroom name must be alphanumeric (dashes and underscores \
     allowed), and must not start or end with a dash or underscore";

/// Between the SIGTERM and the SIGKILL when a teardown is ended: the app SIGKILLs the CLI two
/// seconds after its SIGTERM, so this leaves time to report (`docs/designs/one-script-runner.md`).
const KILL_GRACE: Duration = Duration::from_secs(1);

/// How a delete runs: `--pretend` and `--skip-teardown`, and who watches it.
pub(super) struct Delete<'a> {
    pub(super) context: &'a Context,
    pub(super) config: &'a Config,
    pub(super) skip_teardown: bool,
    pub(super) watcher: Watcher<'a>,
}

/// Who watches a delete's teardown.
pub(super) enum Watcher<'a> {
    /// The app (`--json`): the script's output goes to stderr as `teardown` events.
    App,
    /// A person: the script's output goes to stdout in a panel, and `approve`, when a terminal is
    /// there to ask on, is asked about a script this Mac hasn't approved.
    Person {
        paint: Paint,
        approve: Option<Approve<'a>>,
    },
}

/// Shows a person a script this Mac hasn't approved and asks whether to approve and run it.
pub(super) type Approve<'a> = &'a dyn Fn(&Script) -> Result<bool, CliError>;

/// Asks a person a question, yes or no.
pub(super) type Ask<'a> = &'a dyn Fn(&str) -> Result<bool, CliError>;

/// Shows a person names under a message and asks which to pick.
pub(super) type Pick<'a> = &'a dyn Fn(&str, &[String]) -> Result<Vec<String>, CliError>;

/// How a delete is confirmed: by the `--confirm` value, which must be the name, or by asking.
pub(super) enum Confirm<'a> {
    Value(&'a str),
    Ask(Ask<'a>),
}

/// What a delete did with a workroom: Go's `DeleteOutcome`.
pub(super) enum Deleted {
    /// Its teardown ran, its worktree is removed and its entry dropped. Its branch is kept.
    Removed { branch: String },
    /// A remote workroom whose host is gone: only its entry is dropped.
    ForgotDestroyedRemote,
    /// Not a git checkout: only its entry is dropped, its folder left at `path`.
    ForgotNonGit { path: String },
    /// The person said no when asked, so nothing was done.
    Declined,
}

/// How a person's pick of workrooms to delete ended: Go's `PickOutcome`.
pub(super) enum Picked {
    /// Every pick was deleted, each reported as it went.
    Deleted,
    /// The project has no workrooms, so nothing was offered.
    NoWorkrooms,
    /// The person picked none.
    Nothing,
    /// The person said no to the picks, so nothing was deleted.
    Declined,
}

impl Delete<'_> {
    fn pretend(&self) -> bool {
        self.context.pretend
    }

    /// One `--verbose` step, as Go's `Service.Status` prints it: only to a person.
    fn say(&self, status: &str, message: &str) {
        if self.context.verbose && !self.context.json {
            let mut stdout = std::io::stdout();
            let _ = writeln!(stdout, "{status:>12}  {message}");
            let _ = stdout.flush();
        }
    }

    /// Refuses `dir` when it is a workroom itself: Go's `CheckNotInWorkroom`.
    fn check_not_in_workroom(&self, dir: &str) -> Result<(), CliError> {
        if std::fs::metadata(Path::new(dir).join(".Workroom")).is_ok() {
            return Err(CliError::new(
                Kind::InWorkroom,
                "looks like you are already in a workroom. Run this command from the root of your \
                 main development directory, not from within an existing workroom",
            ));
        }
        Ok(())
    }

    /// Refuses `dir` when it is no git repository: Go's `detectVCS`.
    fn detect_vcs(&self, dir: &str) -> Result<(), CliError> {
        if !is_git_repo(Path::new(dir)) {
            return Err(CliError::unsupported_vcs());
        }
        self.say("repo", "Detected Git worktree");
        Ok(())
    }

    /// Whether git lists a worktree of the project at `dir` whose folder is named `name`: Go's
    /// `workroomExists`.
    fn listed(&self, dir: &str, name: &str) -> Result<bool, CliError> {
        let listed = workspace_names(dir, "git")
            .ok_or_else(|| CliError::internal(format!("git worktree list in {dir} failed")))?;
        Ok(listed.iter().any(|listed| listed == name))
    }

    fn data(&self) -> Result<Json, CliError> {
        self.config.read()
    }

    /// Where workroom `name`'s checkout is on this Mac: `workrooms_dir/<name>`, as Go's
    /// `workroomPath` finds it, whatever the entry records. A `name` that is no name (`..`, `/x`,
    /// `a/b`, which a config key may be) is refused as `InvalidName`: joined on, it could lead out
    /// of the workrooms folder, and an absolute one would replace it.
    fn workroom_path(&self, name: &str) -> Result<PathBuf, CliError> {
        check_name(name)?;
        // Go reads a config it can't parse as naming the default folder.
        let data = self.data().unwrap_or(Json::Null);
        let dir = config::workrooms_dir(&data, self.context).map_err(CliError::internal)?;
        Ok(Path::new(&dir).join(name))
    }

    /// Deletes workroom `name` of project `dir`, once `confirm` says to: Go's `Delete`. What
    /// stops it is checked first, in Go's order: the project being a workroom, the name, a live
    /// remote workroom, the project being no repository, and the workroom being neither a worktree
    /// git lists nor an entry whose folder holds no checkout. `--pretend` skips the last, and
    /// asks for no confirmation.
    pub(super) fn delete(
        &self,
        dir: &str,
        name: &str,
        confirm: Confirm<'_>,
    ) -> Result<Deleted, CliError> {
        self.check_not_in_workroom(dir)?;
        check_name(name)?;
        let destroyed = self.destroyed_remote(dir, name)?;
        // A destroyed remote workroom is only dropped from config, which needs no repository: the
        // project's checkout may be gone by then.
        if !destroyed {
            self.detect_vcs(dir)?;
        }
        let mut orphan = None;
        if !self.pretend() {
            if !destroyed && !self.listed(dir, name)? {
                orphan = self.non_git_workroom_path(dir, name)?;
                if orphan.is_none() {
                    return Err(CliError::new(
                        Kind::WorkspaceNotFound,
                        format!(
                            "git worktree does not exist: Git worktree '{name}' does not exist"
                        ),
                    ));
                }
            }
            match confirm {
                Confirm::Value(value) if value != name => {
                    return Err(CliError::new(
                        Kind::ConfirmationMismatch,
                        format!(
                            "confirmation value does not match the workroom name: --confirm value \
                             '{value}' does not match workroom name '{name}'"
                        ),
                    ));
                }
                Confirm::Value(_) => {}
                Confirm::Ask(ask) => {
                    if !ask(&format!(
                        "Are you sure you want to delete workroom '{name}'?"
                    ))? {
                        return Ok(Deleted::Declined);
                    }
                }
            }
        }
        if let Some(path) = orphan {
            return self.forget_non_git(dir, name, path);
        }
        self.delete_by_name(dir, name)
    }

    /// Offers the workrooms config records for project `dir` to `pick`, asks `ask` to confirm the
    /// picks, and deletes each, handing `report` what was done as soon as it is: Go's
    /// `InteractiveDelete`. A pick is deleted as `delete` deletes one, after the same checks: a
    /// key that is no name or a live remote workroom stops it, and one git doesn't list whose
    /// folder holds no checkout is only forgotten.
    pub(super) fn delete_picks(
        &self,
        dir: &str,
        pick: Pick<'_>,
        ask: Ask<'_>,
        report: &mut dyn FnMut(&str, &Deleted),
    ) -> Result<Picked, CliError> {
        self.check_not_in_workroom(dir)?;
        // Go reads a config it can't parse as naming no project here.
        let data = self.data().unwrap_or(Json::Null);
        let names: Vec<String> = config::find_current_project(&data, dir)
            .map(|(_, project)| project.workrooms.into_keys().collect())
            .unwrap_or_default();
        if names.is_empty() {
            return Ok(Picked::NoWorkrooms);
        }
        let picked = pick("Select workrooms to delete:", &names)?;
        if picked.is_empty() {
            return Ok(Picked::Nothing);
        }
        let quoted: Vec<String> = picked.iter().map(|name| format!("'{name}'")).collect();
        if !ask(&format!(
            "Are you sure you want to delete {} workroom(s): {}?",
            picked.len(),
            quoted.join(", ")
        ))? {
            return Ok(Picked::Declined);
        }
        self.detect_vcs(dir)?;
        for name in &picked {
            // A pick is a config key, which may be any string: one that is no name is refused, as
            // `delete NAME` refuses it, before it is joined onto a path.
            check_name(name)?;
            self.destroyed_remote(dir, name)?;
            let orphan = if self.pretend() {
                None
            } else {
                self.legacy_workroom_path(dir, name)?
            };
            let deleted = match orphan {
                Some(path) => self.forget_non_git(dir, name, path)?,
                None => self.delete_by_name(dir, name)?,
            };
            report(name, &deleted);
        }
        Ok(Picked::Deleted)
    }

    /// Deletes workroom `name` of project `dir` with nothing asked or checked first but a live
    /// remote workroom: Go's `deleteByName`, which `delete`, and a person's pick of several, end
    /// with. A destroyed remote workroom is only forgotten; anything else has its teardown run,
    /// then `git worktree remove`, which removes only a worktree of this repository, then loses its
    /// entry.
    fn delete_by_name(&self, dir: &str, name: &str) -> Result<Deleted, CliError> {
        if self.destroyed_remote(dir, name)? {
            // Nothing runs: there is no box for the teardown, and no workspace on this Mac.
            if !self.pretend() {
                self.config.remove_workroom(dir, name)?;
            }
            return Ok(Deleted::ForgotDestroyedRemote);
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
                .map_err(|error| CliError::vcs_failed(&error.to_string()))?;
            if !output.status.success() {
                return Err(CliError::vcs_failed(&go_exit(&output.status)));
            }
            self.config.remove_workroom(dir, name)?;
        }
        Ok(Deleted::Removed {
            branch: format!("workroom/{name}"),
        })
    }

    /// Drops the entry of workroom `name`, whose folder at `path` holds no git checkout, and
    /// nothing else: no git (it would find an ancestor repository) and no teardown (it would run
    /// in that folder). The folder is the user's. Go's `forgetNonGitWorkroom`.
    fn forget_non_git(&self, dir: &str, name: &str, path: String) -> Result<Deleted, CliError> {
        self.config.remove_workroom(dir, name)?;
        Ok(Deleted::ForgotNonGit { path })
    }

    /// [`Delete::non_git_workroom_path`] for a workroom git doesn't list, or none when git lists
    /// it: Go's `legacyWorkroomPath`.
    fn legacy_workroom_path(&self, dir: &str, name: &str) -> Result<Option<String>, CliError> {
        if self.listed(dir, name)? {
            return Ok(None);
        }
        self.non_git_workroom_path(dir, name)
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
    /// output streamed to whoever watches. Under `--pretend` nothing runs, and `--skip-teardown`
    /// skips it. It runs in `<workrooms folder>/<name>`, so first, under both of those too, that
    /// folder must be a worktree git registers for the project, or it is refused
    /// (`WorkspaceNotFound`): a name git lists matches a folder of the user's of that name too.
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
        if !registered(dir, &path)? {
            return Err(CliError::new(
                Kind::WorkspaceNotFound,
                format!(
                    "git worktree does not exist: git lists no worktree of this project at {}",
                    super::envelope::encode(&path.to_string_lossy(), false)
                ),
            ));
        }
        let Some(script) = find_script(&path, Path::new(dir)) else {
            return Ok(());
        };
        if self.skip_teardown {
            self.say(
                "teardown",
                &format!("Skipping {}, as asked", script.display()),
            );
            return Ok(());
        }
        self.say(
            "teardown",
            &format!(
                "Running {} from {}",
                script.display(),
                super::envelope::encode(&path.to_string_lossy(), false)
            ),
        );
        if self.pretend() {
            return Ok(());
        }
        self.gate(dir, &path, &script)?;
        let variables = crate::script::local_variables(name, &path, Path::new(dir));
        let mut runner = crate::script::Script::new(&script, &path, &variables, None);
        runner.kill_grace = KILL_GRACE;
        let fallback = |reason: &str| {
            format!(
                "workroom: couldn't read the login shell's environment ({reason}); using the \
                 current one\n"
            )
        };
        let outcome = match self.watcher {
            Watcher::App => {
                let mut events = Events(LogWriter::new(std::io::stderr(), "teardown"));
                let outcome = crate::script::run(
                    &runner,
                    crate::script::Output::Combined(&mut events),
                    fallback,
                );
                events.0.flush();
                outcome
            }
            Watcher::Person { paint, .. } => {
                let mut panel = LogPanel::new(std::io::stdout(), "Teardown", paint);
                let outcome = crate::script::run(
                    &runner,
                    crate::script::Output::Combined(&mut panel),
                    fallback,
                );
                let passed = outcome.passed();
                panel.close(passed);
                // A blank line between the panel and what is said next.
                if passed && panel.shown() {
                    let mut stdout = std::io::stdout();
                    let _ = writeln!(stdout);
                    let _ = stdout.flush();
                }
                outcome
            }
        };
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
    /// when they are the root's gitignored copy, which no pull brings. Otherwise a person at a
    /// terminal is asked: a yes records the approval, a no cancels. With no one to ask (the
    /// `--json` caller asks for itself) it is refused.
    fn gate(&self, dir: &str, workroom: &Path, path: &Path) -> Result<(), CliError> {
        let judge = Judge {
            config: self.config,
            dir,
            say: &|_, _| {},
        };
        let Some(script) = judge.found_script(TEARDOWN_SCRIPT, workroom, path)? else {
            return Ok(());
        };
        if script.trusted {
            return Ok(());
        }
        let Watcher::Person {
            approve: Some(approve),
            ..
        } = self.watcher
        else {
            return Err(script.untrusted());
        };
        if !approve(&script)? {
            return Err(CliError::new(
                Kind::Cancelled,
                format!("operation cancelled: {} was not approved", script.file),
            ));
        }
        // Go's `Trust`: the project is registered if it is not yet. `--pretend` never gets here.
        self.config.add_project(dir, "git")?;
        self.config
            .set_trusted_script(dir, script.name, &script.sha256)?;
        // The person read the file while it sat on disk, for as long as the prompt stayed open:
        // the bytes that run must still be the ones they approved.
        match judge.found_script(TEARDOWN_SCRIPT, workroom, path)? {
            Some(now) if now.sha256 != script.sha256 => Err(now.untrusted()),
            _ => Ok(()),
        }
    }
}

/// Whether git registers `path` as a linked worktree of the project at `dir`, symlinks resolved on
/// both sides, so a symlinked workrooms folder still matches: Go's `Git.HasWorktree`. The
/// project's own checkout is not one, and a project that is no git repository registers none.
fn registered(dir: &str, path: &Path) -> Result<bool, CliError> {
    if !is_git_repo(Path::new(dir)) {
        return Ok(false);
    }
    let listed = worktree_paths(dir)
        .ok_or_else(|| CliError::internal(format!("git worktree list in {dir} failed")))?;
    let want = resolved(path);
    if want == resolved(Path::new(dir)) {
        return Ok(false);
    }
    Ok(listed
        .iter()
        .any(|listed| resolved(Path::new(listed)) == want))
}

/// `path` with its symlinks resolved; when it is gone, its parent's resolved with its name joined
/// on; else `path` as it is. Go's `resolvedPath`.
fn resolved(path: &Path) -> PathBuf {
    if let Ok(real) = path.canonicalize() {
        return real;
    }
    match (path.parent(), path.file_name()) {
        (Some(parent), Some(name)) => parent
            .canonicalize()
            .map_or_else(|_| path.to_path_buf(), |parent| parent.join(name)),
        _ => path.to_path_buf(),
    }
}

/// `<wr>/scripts/workroom_teardown` when it exists (following a symlink), else the root's, else
/// none: Go's `findScript`.
fn find_script(workroom: &Path, root: &Path) -> Option<PathBuf> {
    [workroom, root]
        .iter()
        .map(|base| base.join("scripts").join(TEARDOWN_SCRIPT))
        .find(|path| std::fs::metadata(path).is_ok())
}

/// Refuses `name` as `InvalidName` unless it is [`valid_name`]: Go's `checkName`.
fn check_name(name: &str) -> Result<(), CliError> {
    if valid_name(name) {
        return Ok(());
    }
    Err(CliError::new(
        Kind::InvalidName,
        format!("{INVALID_NAME}: {}", super::envelope::encode(name, false)),
    ))
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

fn remote_workroom(name: &str) -> CliError {
    CliError::new(
        Kind::RemoteWorkroomUnsupported,
        format!("not supported for a remote workroom yet: workroom '{name}' is remote"),
    )
}

/// How Go's `exec.ExitError` words an exit (`os.ProcessState.String`): `exit status N`, or
/// `signal: ` and the signal's name, with ` (core dumped)` after it when it dumped one.
pub(super) fn go_exit(status: &std::process::ExitStatus) -> String {
    use std::os::unix::process::ExitStatusExt;
    match (status.code(), status.signal()) {
        (Some(code), _) => format!("exit status {code}"),
        (None, Some(signal)) => {
            let dumped = if status.core_dumped() {
                " (core dumped)"
            } else {
                ""
            };
            format!("signal: {}{dumped}", go_signal_name(signal))
        }
        (None, None) => "exit status -1".to_string(),
    }
}

/// Go's `syscall.Signal.String`: the name in the platform's `signals` table, or `signal N` for
/// one it doesn't name.
fn go_signal_name(signal: i32) -> String {
    usize::try_from(signal)
        .ok()
        .and_then(|index| GO_SIGNALS.get(index))
        .filter(|name| !name.is_empty())
        .map_or_else(|| format!("signal {signal}"), |name| (*name).to_string())
}

/// Go's `signals` table in `syscall/zerrors_darwin_arm64.go` (amd64's is the same).
#[cfg(target_os = "macos")]
const GO_SIGNALS: [&str; 32] = [
    "",
    "hangup",
    "interrupt",
    "quit",
    "illegal instruction",
    "trace/BPT trap",
    "abort trap",
    "EMT trap",
    "floating point exception",
    "killed",
    "bus error",
    "segmentation fault",
    "bad system call",
    "broken pipe",
    "alarm clock",
    "terminated",
    "urgent I/O condition",
    "suspended (signal)",
    "suspended",
    "continued",
    "child exited",
    "stopped (tty input)",
    "stopped (tty output)",
    "I/O possible",
    "cputime limit exceeded",
    "filesize limit exceeded",
    "virtual timer expired",
    "profiling timer expired",
    "window size changes",
    "information request",
    "user defined signal 1",
    "user defined signal 2",
];

/// Go's `signals` table in `syscall/zerrors_linux_amd64.go`, the same on every Linux it builds
/// for but MIPS, whose signal numbers differ.
#[cfg(not(target_os = "macos"))]
const GO_SIGNALS: [&str; 32] = [
    "",
    "hangup",
    "interrupt",
    "quit",
    "illegal instruction",
    "trace/breakpoint trap",
    "aborted",
    "bus error",
    "floating point exception",
    "killed",
    "user defined signal 1",
    "segmentation fault",
    "user defined signal 2",
    "broken pipe",
    "alarm clock",
    "terminated",
    "stack fault",
    "child exited",
    "continued",
    "stopped (signal)",
    "stopped",
    "stopped (tty input)",
    "stopped (tty output)",
    "urgent I/O condition",
    "CPU time limit exceeded",
    "file size limit exceeded",
    "virtual timer expired",
    "profiling timer expired",
    "window changed",
    "I/O possible",
    "power failure",
    "bad system call",
];

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

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::os::unix::process::ExitStatusExt;
    use std::path::{Path, PathBuf};
    use std::process::ExitStatus;

    use super::{Approve, Delete, Watcher, go_exit};
    use crate::commands::Context;
    use crate::commands::config::Config;
    use crate::commands::kind::{CliError, Kind};
    use crate::commands::panel::Paint;
    use crate::commands::trusted_script::Script;

    /// The digest of `#!/bin/sh\necho hi\n`.
    const HI_SHA256: &str = "299001868fb8c02fd431c336c6d058f5558c5dff5b5af5e6fe04b870a6a9cbba";

    fn context() -> Context {
        Context {
            json: false,
            pretend: false,
            verbose: false,
            platform: crate::commands::Platform::current(),
            env: |_| None,
            color: false,
            // Never looked for in tests (#684): a test run in a pane must not find a real daemon.
            daemon_above: || None,
        }
    }

    /// A new directory of this test's own under the system temp dir, removed by the test.
    fn scratch(name: &str) -> PathBuf {
        for attempt in 0u32.. {
            let dir = std::env::temp_dir().join(format!(
                "workroom-teardown-{name}-{}-{attempt}",
                std::process::id()
            ));
            if std::fs::create_dir(&dir).is_ok() {
                return dir.canonicalize().unwrap();
            }
        }
        unreachable!()
    }

    /// The gate's answer for `project`'s unapproved teardown script when `approve` is asked, or
    /// none is there to ask, with how many times it was asked.
    fn gated(
        config: &Config,
        project: &Path,
        answer: Option<Result<bool, CliError>>,
    ) -> (Result<(), CliError>, u32) {
        let asked = Cell::new(0);
        let someone = answer.is_some();
        let answer = Cell::new(answer);
        let approve = |script: &Script| {
            assert_eq!(script.file, "scripts/workroom_teardown");
            asked.set(asked.get() + 1);
            answer.take().expect("asked once")
        };
        let context = context();
        let delete = Delete {
            context: &context,
            config,
            skip_teardown: false,
            watcher: Watcher::Person {
                paint: Paint(false),
                approve: someone.then_some(&approve as Approve<'_>),
            },
        };
        let workroom = project.join("../../workrooms/w");
        let script = project.join("scripts/workroom_teardown");
        let gated = delete.gate(project.to_str().unwrap(), &workroom, &script);
        (gated, asked.get())
    }

    /// In a terminal, Go's `ApproveScriptFn`: a no cancels and records nothing, a yes records the
    /// digest and lets the script run, and a script already approved isn't asked about. With no
    /// one to ask it is refused.
    #[test]
    fn a_person_approves_an_unapproved_teardown_or_cancels_the_delete() {
        let dir = scratch("approve");
        let project = dir.join("src/app");
        std::fs::create_dir_all(project.join("scripts")).unwrap();
        std::fs::write(
            project.join("scripts/workroom_teardown"),
            "#!/bin/sh\necho hi\n",
        )
        .unwrap();
        let config = Config::at(dir.join("config.json"));
        let registered = format!(
            "{{\"{}\": {{\"vcs\": \"git\", \"workrooms\": {{}}}}}}",
            project.display()
        );
        std::fs::write(config.path(), &registered).unwrap();

        let (result, asked) = gated(&config, &project, None);
        assert_eq!(result.unwrap_err().kind, Kind::ScriptNotTrusted);
        assert_eq!(asked, 0);

        let (result, asked) = gated(&config, &project, Some(Ok(false)));
        let error = result.unwrap_err();
        assert_eq!(error.kind, Kind::Cancelled);
        assert_eq!(
            error.message,
            "operation cancelled: scripts/workroom_teardown was not approved"
        );
        assert_eq!(asked, 1);
        assert_eq!(std::fs::read_to_string(config.path()).unwrap(), registered);

        let (result, asked) = gated(&config, &project, Some(Ok(true)));
        result.unwrap();
        assert_eq!(asked, 1);
        let written = std::fs::read_to_string(config.path()).unwrap();
        assert!(
            written.contains(&format!("\"workroom_teardown\": \"{HI_SHA256}\"")),
            "{written}"
        );

        // Approved now, so no one is asked.
        let (result, asked) = gated(&config, &project, Some(Ok(false)));
        result.unwrap();
        assert_eq!(asked, 0);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Only the very folder git registers for the project is one, reached through a symlinked
    /// workrooms folder too; a folder of the user's with a listed worktree's name, the project's
    /// own checkout and a project that is no repository are not.
    #[test]
    fn a_teardown_folder_must_be_a_worktree_git_registers_for_the_project() {
        let dir = scratch("registered");
        let project = dir.join("src/app");
        std::fs::create_dir_all(&project).unwrap();
        let git = |args: &[&str]| {
            let status = crate::commands::git::command(&project)
                .args(args)
                .stdout(std::process::Stdio::null())
                .status()
                .unwrap();
            assert!(status.success(), "git {args:?}");
        };
        git(&["init", "-q"]);
        git(&[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--no-verify",
            "-q",
            "--allow-empty",
            "-m",
            "i",
        ]);
        let workrooms = dir.join("workrooms");
        for (name, at) in [
            ("ours", workrooms.join("ours")),
            ("mine", dir.join("elsewhere/mine")),
        ] {
            git(&["worktree", "add", "-q", "-b", name, at.to_str().unwrap()]);
        }
        std::fs::create_dir_all(workrooms.join("mine")).unwrap();
        let link = dir.join("link");
        std::os::unix::fs::symlink(&workrooms, &link).unwrap();
        let app = project.to_str().unwrap();

        assert!(super::registered(app, &workrooms.join("ours")).unwrap());
        assert!(super::registered(app, &link.join("ours")).unwrap());
        assert!(!super::registered(app, &link.join("mine")).unwrap());
        assert!(!super::registered(app, &link.join("gone")).unwrap());
        assert!(!super::registered(app, &project).unwrap());
        let plain = dir.join("plain");
        std::fs::create_dir_all(&plain).unwrap();
        assert!(!super::registered(plain.to_str().unwrap(), &link.join("ours")).unwrap());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn an_exit_is_worded_as_gos_exec_error() {
        assert_eq!(go_exit(&ExitStatus::from_raw(3 << 8)), "exit status 3");
        assert_eq!(
            go_exit(&ExitStatus::from_raw(libc::SIGKILL)),
            "signal: killed"
        );
        assert_eq!(
            go_exit(&ExitStatus::from_raw(libc::SIGTERM)),
            "signal: terminated"
        );
        assert_eq!(
            go_exit(&ExitStatus::from_raw(libc::SIGSEGV | 0x80)),
            "signal: segmentation fault (core dumped)"
        );
        // A number Go's table doesn't name.
        assert_eq!(go_exit(&ExitStatus::from_raw(40)), "signal: signal 40");
    }
}
