//! `workroom create` (#677), as Go's `cmd/create.go` and `Service.CreateNamed` make a workroom:
//! a generated name, a git worktree on a `workroom/<name>` branch from the start a create takes
//! (`start`), its config entry, the main checkout's uncommitted changes when asked, the root's
//! included files, and then the setup script, once this Mac has approved its bytes
//! (`trusted_script`), through the one script runner (`crate::script`).
//!
//! Under `--json` the app reads the steps as NDJSON on stderr while they run: a `step` event for
//! each change of `fetch`, `worktree`, `changes`, `include` and `script`, a `log` event for each
//! line git or the script prints, tagged with the step running, and a `created` event once the
//! workroom exists, before its setup script. A create is not transactional: one whose setup fails
//! has made the workroom, so its error envelope reports it as `created`.
//!
//! The create questions (ADR 0059) are asked before anything exists: work the start would leave
//! out (`LocalWorkLeftOut`, with `--start ask`) and a setup script this Mac hasn't approved
//! (`ScriptNotTrusted`). Each refusal carries the `start_commit` it was asked about, which the
//! answer passes back as `--start-commit` to start from the same commit, fetching nothing. Only a
//! person at a terminal is asked in place; anything else is refused.
//!
//! `--host` records a remote workroom the app is about to make (#253) and makes nothing here.

use std::io::{BufRead, IsTerminal, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;

use super::config::{self, Config, Json};
use super::kind::{CliError, Kind};
use super::log::{LogWriter, go_lossy};
use super::panel::{LogPanel, Paint};
use super::start::{self, FetchStep, LocalWork, Progress};
use super::trusted_script::{Judge, SETUP_SCRIPT, Script};
use super::{Args, Context, Outcome, envelope, git, include_archive, namegen, prompt, trust};

/// Between the SIGTERM and the SIGKILL when the setup script is ended: the app SIGKILLs the CLI
/// two seconds after its SIGTERM, so this leaves time to report (`docs/designs/one-script-runner.md`).
const KILL_GRACE: Duration = Duration::from_secs(1);

/// Where a create starts when the main checkout has work its remote's copy of the base branch
/// lacks: `--start`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Start {
    /// The remote's copy, leaving the work out.
    Origin,
    /// The local branch, with its unpushed commits.
    Local,
    /// The local branch, and a copy of the main checkout's uncommitted changes.
    LocalWithChanges,
    /// Refuse with `LocalWorkLeftOut` when there is work, so the app can ask.
    Ask,
}

/// `--start`'s values, in Go's order.
const STARTS: [(&str, Start); 4] = [
    ("origin", Start::Origin),
    ("local", Start::Local),
    ("local-with-changes", Start::LocalWithChanges),
    ("ask", Start::Ask),
];

/// A created workroom: `create`'s payload, and the `created` object of a create whose setup failed
/// after the workroom was made. Go's `createPayload`.
#[derive(Debug, PartialEq, Eq, Serialize)]
pub(crate) struct CreatePayload {
    name: String,
    path: String,
    project: String,
    vcs: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    warning: String,
}

pub(super) fn run(context: &Context, args: &Args) -> Outcome {
    create(context, args).unwrap_or_else(Outcome::Failed)
}

/// Go's order: the config, `--start`, `--start-commit`, the project, then `--host`.
fn create(context: &Context, args: &Args) -> Result<Outcome, CliError> {
    let config = Config::new(context)?;
    let start = match args.value_or_default("start") {
        "" => None,
        given => Some(
            STARTS
                .iter()
                .find(|(name, _)| *name == given)
                .map(|(_, start)| *start)
                .ok_or_else(|| {
                    let names: Vec<&str> = STARTS.iter().map(|(name, _)| *name).collect();
                    CliError::internal(format!(
                        "--start must be one of {}, not {given:?}",
                        names.join(", ")
                    ))
                })?,
        ),
    };
    // A commit hash only: it goes to git as an argument, never as an option or a revision
    // expression.
    let start_commit = args.value_or_default("start-commit");
    if !start_commit.is_empty() && !is_commit_hash(start_commit) {
        return Err(CliError::internal(format!(
            "--start-commit must be a commit hash, not {start_commit:?}"
        )));
    }
    let dir = config::resolve_project(args.value("project"), context)?;
    if let Some(host) = args.value("host") {
        return remote(context, &config, args, &dir, host);
    }
    let given = |flag: &str| !args.value_or_default(flag).is_empty();
    if given("host-path") || given("host-parent") {
        return Err(invalid_host("--host-path and --host-parent require --host"));
    }
    let mut creator = Creator {
        events: Events(
            context
                .json
                .then(|| LogWriter::new(std::io::stderr(), "setup")),
        ),
        panel: None,
        plan: Plan {
            context,
            config: &config,
            dir,
            start,
            start_commit,
            skip_setup: args.is_set("skip-setup"),
            ask: !context.json && std::io::stdin().is_terminal(),
        },
    };
    if context.json {
        let (made, result) = creator.create_named();
        creator.events.flush();
        return match (result, made) {
            (Ok(()), Some(made)) => Ok(Outcome::Success(envelope::success(
                "create",
                &made.payload(&creator.plan.dir),
            ))),
            (Ok(()), None) => unreachable!("a create that succeeds has made its workroom"),
            (Err(mut error), made) => {
                // Not transactional: the workroom exists, so the app can offer to delete it.
                if let Some(made) = made {
                    error.create_details().created = Some(made.payload(&creator.plan.dir));
                }
                Err(error)
            }
        };
    }
    human(&mut creator, !args.is_set("no-editor"))
}

/// Whether `text` is a full SHA-1 or SHA-256 commit hash, as git prints one.
fn is_commit_hash(text: &str) -> bool {
    matches!(text.len(), 40 | 64)
        && text
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Go's `ErrInvalidHost`, with why.
fn invalid_host(detail: &str) -> CliError {
    CliError::new(
        Kind::InvalidHostDescriptor,
        format!("a host descriptor must be a JSON object: {detail}"),
    )
}

/// `create --host`: records a remote workroom the app is about to make (#253), under a generated
/// name, and prints it. Nothing is made on this Mac: no worktree, folder or setup script. The
/// host's checkout is a clone, so its VCS is git, whatever the project uses here.
fn remote(
    context: &Context,
    config: &Config,
    args: &Args,
    dir: &str,
    text: &str,
) -> Result<Outcome, CliError> {
    let host = config::host_descriptor(text).ok_or_else(|| invalid_host(text))?;
    let host_path = args.value_or_default("host-path");
    let parent = args.value_or_default("host-parent");
    match (host_path.is_empty(), parent.is_empty()) {
        (true, true) => {
            return Err(invalid_host(
                "--host-path or --host-parent is required with --host",
            ));
        }
        (false, false) => {
            return Err(invalid_host(
                "--host-path and --host-parent are mutually exclusive",
            ));
        }
        // A POSIX path already resolved on the host, not on this Mac.
        (true, false) if !parent.starts_with('/') || parent.contains('\0') => {
            return Err(invalid_host(
                "--host-parent must be an absolute path on the host",
            ));
        }
        _ => {}
    }
    check_project(context, Path::new(dir))?;
    let name = unique_name(context, config, dir)?;
    let path = if host_path.is_empty() {
        config::clean(&format!("{parent}/{name}"))
    } else {
        host_path.to_string()
    };
    if !context.pretend {
        config.add_remote_workroom(dir, &name, &path, host)?;
    }
    if context.json {
        let payload = CreatePayload {
            name,
            path,
            project: dir.to_string(),
            vcs: "git".to_string(),
            warning: String::new(),
        };
        return Ok(Outcome::Success(envelope::success("create", &payload)));
    }
    Ok(Outcome::Printed(format!("{name}\n")))
}

/// Refuses a directory that is a workroom, or that holds no git checkout of its own.
fn check_project(context: &Context, dir: &Path) -> Result<(), CliError> {
    if std::fs::metadata(dir.join(".Workroom")).is_ok() {
        return Err(CliError::new(
            Kind::InWorkroom,
            "looks like you are already in a workroom. Run this command from the root of your \
             main development directory, not from within an existing workroom",
        ));
    }
    if !git::is_git_repo(dir) {
        return Err(CliError::unsupported_vcs());
    }
    trust::say(context, "repo", "Detected Git worktree");
    Ok(())
}

/// A name no workroom of the project has, in git or in config (a remote workroom is only in
/// config), and whose folder doesn't exist: five tries at a fresh name, then ten at the last one
/// with a number added. Go's `generateUniqueName`.
fn unique_name(context: &Context, config: &Config, dir: &str) -> Result<String, CliError> {
    let mut existing = super::list::workspace_names(dir, "git")
        .ok_or_else(|| CliError::internal(format!("git worktree list in {dir} failed")))?;
    if let Some(workrooms) = config
        .read()?
        .as_object()
        .and_then(|top| top.get(dir))
        .and_then(Json::as_object)
        .and_then(|entry| entry.get("workrooms"))
        .and_then(Json::as_object)
    {
        existing.extend(workrooms.keys().cloned());
    }
    let free = |name: &str| -> Result<bool, CliError> {
        let path = workroom_path(context, config, name)?;
        Ok(!existing.iter().any(|taken| taken == name)
            && std::fs::metadata(path)
                .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound))
    };
    let mut last = String::new();
    for _ in 0..5 {
        last = namegen::generate();
        if free(&last)? {
            return Ok(last);
        }
    }
    for _ in 0..10 {
        let candidate = format!("{last}-{}", namegen::below(90) + 10);
        if free(&candidate)? {
            return Ok(candidate);
        }
    }
    Err(CliError::internal(
        "failed to generate unique workroom name after multiple attempts",
    ))
}

/// Where workroom `name` goes: `workrooms_dir/<name>`. A config that can't be read names the
/// default folder, as Go's `WorkroomsDir` reads it.
fn workroom_path(context: &Context, config: &Config, name: &str) -> Result<String, CliError> {
    let data = config.read().unwrap_or(Json::Null);
    let dir = config::workrooms_dir(&data, context).map_err(CliError::internal)?;
    Ok(Path::new(&dir).join(name).to_string_lossy().into_owned())
}

/// What one create is asked to do, and the questions it asks on the way.
struct Plan<'a> {
    context: &'a Context,
    config: &'a Config,
    /// The project.
    dir: String,
    start: Option<Start>,
    /// `--start-commit`: the commit a create question was asked about; "" for none.
    start_commit: &'a str,
    /// `--skip-setup`: the app's Continue Without Script, which judges and runs nothing.
    skip_setup: bool,
    /// A person at a terminal, who is asked where to start and to approve a script. Anyone else
    /// is refused.
    ask: bool,
}

/// The workroom a create has made, as far as it got.
struct Made {
    name: String,
    path: String,
    /// For the user: the start may be out of date, or leaves out the main checkout's work.
    warning: String,
    /// The include step's warning and the symlinks it skipped, for the human create; `--json`
    /// callers read them from the step's events.
    include_warning: String,
    include_skipped: Vec<String>,
    /// The warning of the step that copies the main checkout's changes, for the human create.
    changes_warning: String,
    /// Whether the main checkout's changes are to be copied in, as the start chosen says.
    carry: bool,
}

impl Made {
    fn payload(&self, project: &str) -> CreatePayload {
        CreatePayload {
            name: self.name.clone(),
            path: self.path.clone(),
            project: project.to_string(),
            vcs: "git".to_string(),
            warning: self.warning.clone(),
        }
    }
}

struct Creator<'a> {
    events: Events,
    /// The human create's log panel, which the setup script's output streams into; none under
    /// `--json`, where it goes to the events.
    panel: Option<LogPanel<std::io::Stdout>>,
    plan: Plan<'a>,
}

impl Creator<'_> {
    /// Makes the workroom and sets it up: Go's `CreateNamed`. Returns the workroom once it exists,
    /// so a failure after that (its setup script, say) can still say what was made, with how the
    /// create ended. Under `--pretend` nothing is made or run: the name and path are what a create
    /// would use.
    fn create_named(&mut self) -> (Option<Made>, Result<(), CliError>) {
        match self.make() {
            Ok(mut made) => {
                let result = self.set_up(&mut made);
                (Some(made), result)
            }
            Err(error) => (None, Err(error)),
        }
    }

    /// Makes the workroom's worktree and config entry, once the checks and the create questions
    /// before them have passed.
    fn make(&mut self) -> Result<Made, CliError> {
        let context = self.plan.context;
        let pretend = context.pretend;
        let dir = PathBuf::from(&self.plan.dir);
        check_project(context, &dir)?;
        let name = unique_name(context, self.plan.config, &self.plan.dir)?;
        let path = workroom_path(context, self.plan.config, &name)?;
        if !pretend {
            let listed = super::list::workspace_names(&self.plan.dir, "git").ok_or_else(|| {
                CliError::internal(format!("git worktree list in {} failed", self.plan.dir))
            })?;
            if listed.contains(&name) {
                return Err(CliError::new(
                    Kind::WorkspaceExists,
                    format!("git worktree already exists: Git worktree '{name}' already exists"),
                ));
            }
            if std::fs::metadata(&path).is_ok() {
                return Err(CliError::new(
                    Kind::DirExists,
                    format!(
                        "workroom directory already exists: workroom directory '{}' already \
                         exists",
                        display_path(context, &path)
                    ),
                ));
            }
        }
        let mut warning = String::new();
        let mut carry = false;
        if !pretend {
            let (base, global) = self.plan.base()?;
            let data = self.plan.config.read().unwrap_or(Json::Null);
            let workrooms = config::workrooms_dir(&data, context).map_err(CliError::internal)?;
            config::make_dir_all(&workrooms)
                .map_err(|error| CliError::internal(error.to_string()))?;
            (warning, carry) = self.workspace(&name, &path, &base, global)?;
            self.plan
                .config
                .add_workroom(&self.plan.dir, &name, &path, "git")?;
        }
        Ok(Made {
            name,
            path,
            warning,
            include_warning: String::new(),
            include_skipped: Vec::new(),
            changes_warning: String::new(),
            carry,
        })
    }

    /// Announces the workroom `made`, copies the main checkout's changes in when asked for and the
    /// root's included files, then runs the setup script, once this Mac has approved it.
    fn set_up(&mut self, made: &mut Made) -> Result<(), CliError> {
        let context = self.plan.context;
        let pretend = context.pretend;
        let dir = PathBuf::from(&self.plan.dir);
        let path = PathBuf::from(&made.path);
        // Found before the workroom is announced, so the `created` event says whether a setup
        // script will run, and before the include step, which may copy an ignored one in.
        let (script, has_setup) = find_script(&path, &dir);
        if !pretend {
            #[derive(Serialize)]
            struct Created<'a> {
                name: &'a str,
                path: &'a str,
                project: &'a str,
                setup: bool,
                r#type: &'a str,
                vcs: &'a str,
                warning: &'a str,
            }
            self.events.event(&Created {
                name: &made.name,
                path: &made.path,
                project: &self.plan.dir,
                setup: has_setup,
                r#type: "created",
                vcs: "git",
                warning: &made.warning,
            });
        }
        // The main checkout's changes, when asked for, then the root's included files, both before
        // the setup script so it can rely on them (#367).
        if made.carry {
            made.changes_warning = self.carry_changes(&dir, &path);
        }
        if !pretend {
            (made.include_warning, made.include_skipped) = self.copy_included(&dir, &path);
        }
        if has_setup && self.plan.skip_setup {
            if !pretend {
                self.events
                    .step("script", "skipped", "Skipped without approval");
            }
            return Ok(());
        }
        if !has_setup {
            if !pretend {
                self.events.step("script", "skipped", "No setup script");
            }
            return Ok(());
        }
        trust::say(
            context,
            "setup",
            &format!("Running {} from {:?}", script.display(), made.path),
        );
        if pretend {
            return Ok(());
        }
        self.events.step("script", "running", "");
        // Again on the file about to run: it is what runs, whatever the early check read.
        if let Err(error) = self.plan.gate_found(&path, &script) {
            self.events.step("script", "failed", &error.message);
            return Err(error);
        }
        if let Err(error) = self.run_setup(&made.name, &path, &dir, &script) {
            self.events.step("script", "failed", &error.message);
            return Err(error);
        }
        self.events.step("script", "done", "");
        Ok(())
    }

    /// Makes the git worktree for workroom `name` at `path`, on `workroom/<name>`, from where the
    /// create starts: origin's default branch, as a remote workroom does, or `base` when there is
    /// one (`fallback` when it is the app-wide default), or the local branch when the person
    /// chooses it. `--no-track`: a workroom's branch has no upstream until published. Returns the
    /// warning for the user, or "", and whether the main checkout's changes are to be copied in.
    /// Go's `Git.Create`, with `CreateNamed`'s questions as its `BeforeWorktree`.
    fn workspace(
        &mut self,
        name: &str,
        path: &str,
        base: &str,
        fallback: bool,
    ) -> Result<(String, bool), CliError> {
        let dir = PathBuf::from(&self.plan.dir);
        let pin = self.plan.start_commit;
        let mut fs = FetchStep::new(&mut self.events, !pin.is_empty());
        // `reference` names the start point, for the local branch it is compared with and for its
        // wording; `at` is where the workroom starts from it: the ref itself, or the pinned commit.
        let (reference, mut warning) = match start::resolve(&dir, base, fallback, &mut fs) {
            Ok(found) => found,
            Err(error) => {
                fs.finish("", Some(&error));
                return Err(error);
            }
        };
        let mut at = reference.clone();
        if !pin.is_empty() {
            // The pin answers a question about this start point: it must be where the start
            // point's ref points, or behind it. Anything else (a commit that's gone, or another
            // branch's, as when the base branch changed in between) is refused, not used.
            if !start::is_ancestor(&dir, pin, &reference) {
                return Err(CliError::new(
                    Kind::StartCommitUnusable,
                    format!(
                        "the commit this create was asked about is no longer where it starts: \
                         {pin} is not on {}",
                        start::ref_name(&dir, &reference)
                    ),
                ));
            }
            at = pin.to_string();
        }
        // A start that already warns (a failed fetch, a fallback) is compared all the same, so a
        // start the person chose still holds, but marked stale: nobody is asked against it.
        let mut work = start::local_work_at(&dir, &reference, &at);
        work.stale = !warning.is_empty();
        let (start, carry, left_out) = match self.plan.before_worktree(&at, &work) {
            Ok(chosen) => chosen,
            Err(mut error) => {
                fs.finish(&warning, None);
                let commit = start::question_commit(&dir, &at);
                if !commit.is_empty() {
                    error.create_details().start_commit = Some(commit);
                }
                return Err(error);
            }
        };
        // The warning was about the remote's copy; a start switched to the local branch says what
        // it really is instead.
        if !warning.is_empty() && start != at {
            warning = start::local_start_warning(base, &reference, &work, fs.failed);
        }
        // The fetch step carries the start-point warning, so it ends only once the start is
        // settled: its row and the create's notice then say the same.
        fs.finish(&warning, None);
        self.events.step("worktree", "running", "");
        let branch = format!("workroom/{name}");
        let mut args = vec!["worktree", "add"];
        if !start.is_empty() {
            args.push("--no-track");
        }
        args.extend(["-b", &branch, path]);
        if !start.is_empty() {
            args.push(&start);
        }
        if let Err(error) = start::logged_git(&mut self.events, &dir, &args) {
            self.events.step("worktree", "failed", &error);
            return Err(CliError::vcs_failed(&error));
        }
        self.events.step("worktree", "done", "");
        if warning.is_empty() {
            warning = left_out;
        }
        Ok((warning, carry))
    }

    /// Runs the setup script at `script` in the workroom at `path`, its output streamed into the
    /// log panel or the events as it runs.
    fn run_setup(
        &mut self,
        name: &str,
        path: &Path,
        dir: &Path,
        script: &Path,
    ) -> Result<(), CliError> {
        let variables = crate::script::local_variables(name, path, dir);
        let mut runner = crate::script::Script::new(script, path, &variables, None);
        runner.kill_grace = KILL_GRACE;
        let sink: &mut dyn Write = match &mut self.panel {
            Some(panel) => panel,
            None => &mut self.events,
        };
        let outcome =
            crate::script::run(&runner, crate::script::Output::Combined(sink), |reason| {
                format!(
                    "workroom: couldn't read the login shell's environment ({reason}); using the \
                 current one\n"
                )
            });
        let script = script.display();
        match outcome {
            outcome if outcome.passed() => Ok(()),
            crate::script::Outcome::NotStarted(error) => Err(CliError::new(
                Kind::SetupScriptFailed,
                format!(
                    "setup script failed: {script} could not be started: fork/exec {script}: {}",
                    config::os_error(&error)
                ),
            )),
            // An exit, a signal, or this process told to stop: the script didn't finish.
            _ => Err(CliError::new(
                Kind::SetupScriptFailed,
                format!("setup script failed: {script} returned a non-zero exit code"),
            )),
        }
    }

    /// Copies the main checkout's uncommitted changes at `root` into the new workroom at `path`,
    /// which started from the same commit: changes to tracked files, staged or not, and the
    /// untracked files git doesn't ignore. The main checkout keeps them. It never fails the
    /// create: a problem ends the step as a warning, returned. Go's `carryChanges`.
    fn carry_changes(&mut self, root: &Path, path: &Path) -> String {
        self.events.step("changes", "running", "");
        let warn = |events: &mut Events, text: String| {
            events.step("changes", "warning", &text);
            text
        };
        let head = |dir: &Path| {
            git::output(dir, &["rev-parse", "--verify", "--quiet", "HEAD^{commit}"])
                .map(|out| String::from_utf8_lossy(&out).trim().to_string())
        };
        // Applied anywhere else, the changes conflict: the main checkout moved since the choice.
        match head(root) {
            Err(error) => {
                return warn(
                    &mut self.events,
                    format!("Couldn't copy your changes: {error}"),
                );
            }
            Ok(from) if from != head(path).unwrap_or_default() => {
                return warn(
                    &mut self.events,
                    "Your project moved to a different commit, so your changes weren't copied"
                        .to_string(),
                );
            }
            Ok(_) => {}
        }
        let stash = match git::output(root, &["stash", "create"]) {
            Ok(out) => String::from_utf8_lossy(&out).trim().to_string(),
            Err(error) => {
                return warn(
                    &mut self.events,
                    format!("Couldn't copy your changes: {error}"),
                );
            }
        };
        if !stash.is_empty() {
            if let Err(error) = git::output(path, &["stash", "apply", "--quiet", &stash]) {
                return warn(
                    &mut self.events,
                    format!("Couldn't copy your changes: {error}"),
                );
            }
            self.events.log("Copied your changes to existing files");
        }
        let untracked =
            match git::output(root, &["ls-files", "-z", "--others", "--exclude-standard"]) {
                Ok(out) => include_archive::split_nul(&out),
                Err(error) => {
                    return warn(
                        &mut self.events,
                        format!("Couldn't copy your new files: {error}"),
                    );
                }
            };
        // Regular files only, as the include step copies: a symlink could point outside the root.
        // git lists a folder that is a repository of its own as one entry, which isn't copied; it
        // is said, so the step doesn't end done over files the workroom lacks.
        let mut files = Vec::new();
        let mut repos = Vec::new();
        for file in untracked {
            let shown = go_lossy(&file);
            match std::fs::symlink_metadata(root.join(std::ffi::OsStr::from_bytes(&file))) {
                Ok(info) if info.is_file() => files.push(file),
                Ok(info) if info.file_type().is_symlink() => {
                    self.events.log(&skipped_symlink(&shown));
                }
                Ok(info) if info.is_dir() => {
                    self.events
                        .log(&format!("Skipped {shown}: it's a separate git repository"));
                    repos.push(shown);
                }
                _ => {}
            }
        }
        let copied = copy_files(root, path, &files);
        for file in &copied.copied {
            self.events.log(&format!("Copied {file}"));
        }
        if !copied.failures.is_empty() {
            return warn(
                &mut self.events,
                format!(
                    "Couldn't copy {}: {}",
                    count_files(copied.failures.len()),
                    copied.failures.join("; ")
                ),
            );
        }
        if !repos.is_empty() {
            return warn(
                &mut self.events,
                format!(
                    "Didn't copy {}: each is a separate git repository",
                    repos.join(", ")
                ),
            );
        }
        self.events.step("changes", "done", "");
        String::new()
    }

    /// The include step: copies the root's included files into the new workroom at `path`,
    /// logging each one. Nothing here fails the create: the step ends as a warning and the create
    /// carries on, since a missing file is easy to copy by hand. A root with no include file has
    /// no step. Returns the step's warning, or "", and the symlinks it skipped. Go's
    /// `copyIncluded`.
    fn copy_included(&mut self, root: &Path, path: &Path) -> (String, Vec<String>) {
        // Announced before the listing, which takes a second or so in a root with a large ignored
        // tree.
        if std::fs::metadata(root.join(include_archive::INCLUDE_FILE)).is_err() {
            return (String::new(), Vec::new());
        }
        self.events.step("include", "running", "");
        let included = match include_archive::included_files(root) {
            Ok(included) => included,
            Err(error) => {
                let text = format!("Could not list the included files: {error}");
                self.events.step("include", "warning", &text);
                return (text, Vec::new());
            }
        };
        let symlinks: Vec<String> = included.symlinks.iter().map(|f| go_lossy(f)).collect();
        for file in &symlinks {
            self.events.log(&skipped_symlink(file));
        }
        if included.files.is_empty() {
            // Named here, not only in the log: a skipped row's log can't be opened.
            let reason = if symlinks.is_empty() {
                "No matching files".to_string()
            } else {
                format!("Only symlinks matched: {}", symlinks.join(", "))
            };
            self.events.step("include", "skipped", &reason);
            return (String::new(), symlinks);
        }
        let copied = copy_files(root, path, &included.files);
        for file in &copied.copied {
            self.events.log(&format!("Copied {file}"));
        }
        self.events.log(&format!(
            "Copied {} ({})",
            count_files(copied.copied.len()),
            byte_size(copied.bytes)
        ));
        trust::say(
            self.plan.context,
            "include",
            &format!(
                "Copied {} from {}",
                count_files(copied.copied.len()),
                include_archive::INCLUDE_FILE
            ),
        );
        if !copied.failures.is_empty() {
            let text = format!(
                "Could not copy {}: {}",
                count_files(copied.failures.len()),
                copied.failures.join("; ")
            );
            self.events.step("include", "warning", &text);
            return (text, symlinks);
        }
        self.events.step("include", "done", "");
        (String::new(), symlinks)
    }
}

impl Plan<'_> {
    /// The branch a new workroom of the project starts from: the project's own, else the global
    /// one (then `true`), else "" for origin's default branch. An app-wide default must not block
    /// a project it doesn't fit, so it may fall back; a project's own is an explicit choice and
    /// still fails.
    fn base(&self) -> Result<(String, bool), CliError> {
        let data = self.config.read()?;
        let own = config::all_projects(&data)
            .get(&self.dir)
            .map(|project| project.base_branch.clone())
            .unwrap_or_default();
        if own.is_empty() {
            return Ok((config::base_branch(&data), true));
        }
        Ok((own, false))
    }

    /// Settles, before anything exists, where the create starts from `at` given the local `work`
    /// it would leave out, and that the setup script there may run, so a refusal leaves nothing
    /// behind. Returns the start ("" is HEAD), whether to copy the main checkout's changes in, and
    /// the warning for work left out with nobody to ask.
    fn before_worktree(
        &self,
        at: &str,
        work: &LocalWork,
    ) -> Result<(String, bool, String), CliError> {
        let mut start = at.to_string();
        let mut carry = false;
        let mut left_out = String::new();
        match self.choose_start(work)? {
            None if work.any() => {
                left_out = format!(
                    "{}. This workroom doesn't include that work, because new workrooms start \
                     from what you've pushed.",
                    work.summary()
                );
            }
            Some(choice @ (Start::Local | Start::LocalWithChanges)) => {
                start = format!("refs/heads/{}", work.branch);
                carry = choice == Start::LocalWithChanges && work.uncommitted;
            }
            _ => {}
        }
        if !self.skip_setup {
            // At the start chosen: a local branch can carry another setup script, and copied
            // changes can carry an edited one, which is then the one that runs.
            let judge = self.judge();
            let script = if carry {
                judge.root_script(SETUP_SCRIPT)?
            } else {
                judge.setup_script_at(&start)?
            };
            if let Some(script) = script {
                self.gate(&script)?;
            }
        }
        Ok((start, carry, left_out))
    }

    /// Where a create with work left out starts: `--start` when given, else a person's answer.
    /// None leaves the work out, starting from the remote's copy with a warning: what a create
    /// with nobody to ask does. Against a stale start (the fetch failed) nobody is asked, but a
    /// start chosen beforehand still holds. Go's `chooseStart`.
    fn choose_start(&self, work: &LocalWork) -> Result<Option<Start>, CliError> {
        if work.branch.is_empty() {
            return Ok(Some(Start::Origin));
        }
        let askable = work.any() && !work.stale;
        match self.start {
            Some(Start::Ask) if askable => {
                let behind = match work.behind_note() {
                    note if note.is_empty() => note,
                    note => format!(" {note}"),
                };
                let mut error = CliError::new(
                    Kind::LocalWorkLeftOut,
                    format!(
                        "the new workroom would leave out some of your work: {}.{behind} Choose \
                         what to include with --start local-with-changes (your commits and \
                         changes), local (your commits) or origin (neither)",
                        work.summary()
                    ),
                );
                error.create_details().local_work = Some(work.payload());
                Err(error)
            }
            Some(Start::Ask) => Ok(Some(Start::Origin)),
            Some(start) => Ok(Some(start)),
            None if askable && self.ask => {
                let mut stdout = std::io::stdout();
                ask_start(&mut stdout, &mut std::io::stdin().lock(), work).map(Some)
            }
            None => Ok(None),
        }
    }

    fn judge(&self) -> Judge<'_> {
        Judge {
            config: self.config,
            dir: &self.dir,
            say: &|_, _| {},
        }
    }

    /// Lets a trusted script through. An untrusted one is shown to a person at a terminal, whose
    /// yes records the approval and whose no cancels; anyone else is refused, with the script for
    /// the app to show.
    fn gate(&self, script: &Script) -> Result<(), CliError> {
        if script.trusted {
            return Ok(());
        }
        if !self.ask {
            return Err(script.untrusted());
        }
        if !prompt::approve(Paint(self.context.color), script)? {
            return Err(CliError::new(
                Kind::Cancelled,
                format!("operation cancelled: {} was not approved", script.file),
            ));
        }
        // Go's `Service.Trust`, registering the project if it is not yet.
        self.config.add_project(&self.dir, "git")?;
        self.config
            .set_trusted_script(&self.dir, script.name, &script.sha256)
    }

    /// [`Plan::gate`] for the setup script at `path`, about to run in the workroom at
    /// `workroom`. A person who approved it read the file while it sat on disk: the bytes that
    /// now run must still be the ones approved. Go's `gateFound`.
    fn gate_found(&self, workroom: &Path, path: &Path) -> Result<(), CliError> {
        let judge = self.judge();
        let script = match judge.found_script(SETUP_SCRIPT, workroom, path)? {
            Some(script) if !script.trusted => script,
            _ => return Ok(()),
        };
        self.gate(&script)?;
        match judge.found_script(SETUP_SCRIPT, workroom, path)? {
            Some(now) if now.sha256 != script.sha256 => Err(now.untrusted()),
            _ => Ok(()),
        }
    }
}

/// Asks a person at a terminal what a create that would leave work out includes: the commits and
/// changes, the commits only, or neither, offering only the choices that apply. Go asks with a
/// select menu; this asks for the choice's number, as `trust` asks its question on a line.
fn ask_start(
    out: &mut impl Write,
    input: &mut impl BufRead,
    work: &LocalWork,
) -> Result<Start, CliError> {
    let mut choices = Vec::new();
    if work.uncommitted && work.ahead > 0 {
        choices.push((Start::LocalWithChanges, "Include my commits and changes"));
        choices.push((Start::Local, "Include my commits only"));
    } else if work.uncommitted {
        choices.push((Start::LocalWithChanges, "Include my changes"));
    } else {
        choices.push((Start::Local, "Include my commits"));
    }
    choices.push((Start::Origin, "Leave it out"));
    let mut question =
        "New workrooms start from what you've pushed. Include this work in the new one?"
            .to_string();
    if !work.behind_note().is_empty() {
        question = format!("{} {question}", work.behind_note());
    }
    let _ = writeln!(out, "{}.\n{question}", work.summary());
    for (number, (_, label)) in choices.iter().enumerate() {
        let _ = writeln!(out, "  {}) {label}", number + 1);
    }
    loop {
        let _ = write!(out, "Choose 1-{}: ", choices.len());
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
        if let Some((start, _)) = answer
            .trim()
            .parse::<usize>()
            .ok()
            .and_then(|number| choices.get(number.wrapping_sub(1)))
        {
            return Ok(*start);
        }
    }
}

/// `scripts/workroom_setup` from the workroom, whose files it sets up, else from the project's
/// root checkout, where a gitignored, local-only script lives, and whether either has one.
/// Following a symlink. Go's `findScript`.
fn find_script(workroom: &Path, root: &Path) -> (PathBuf, bool) {
    [workroom, root]
        .iter()
        .map(|base| base.join("scripts").join(SETUP_SCRIPT))
        .find(|path| std::fs::metadata(path).is_ok())
        .map_or_else(
            || (root.join("scripts").join(SETUP_SCRIPT), false),
            |path| (path, true),
        )
}

/// The log line for a symlink that matched but isn't copied.
fn skipped_symlink(path: &str) -> String {
    format!("Skipped {path}: it's a symlink")
}

fn count_files(n: usize) -> String {
    if n == 1 {
        "1 file".to_string()
    } else {
        format!("{n} files")
    }
}

/// `n` bytes for a person, in decimal units as Finder shows sizes. Go's `byteSize`.
fn byte_size(n: u64) -> String {
    if n < 1000 {
        return format!("{n} B");
    }
    let mut value = n as f64 / 1000.0;
    let mut unit = "KB";
    for next in ["MB", "GB", "TB"] {
        if value < 1000.0 {
            break;
        }
        value /= 1000.0;
        unit = next;
    }
    format!("{value:.1} {unit}")
}

/// What copying files into a workroom did: the files copied and their total size, and each file
/// that couldn't be, as `path: reason`.
struct Copied {
    copied: Vec<String>,
    bytes: u64,
    failures: Vec<String>,
}

/// Copies `files` (relative to `root`) into `dest`, the new workroom, each with its mode exactly:
/// set after the write, since a mode given at create time is filtered by the umask. A file `dest`
/// already has is left as it is. A file that can't be copied is reported and the rest still are,
/// so one unreadable key never costs the others. Go's `CopyIncluded`.
fn copy_files(root: &Path, dest: &Path, files: &[Vec<u8>]) -> Copied {
    let mut copied = Copied {
        copied: Vec::new(),
        bytes: 0,
        failures: Vec::new(),
    };
    for file in files {
        let relative = std::ffi::OsStr::from_bytes(file);
        let to = dest.join(relative);
        if std::fs::symlink_metadata(&to).is_ok() {
            continue;
        }
        match copy_file(&root.join(relative), &to) {
            Ok(bytes) => {
                copied.copied.push(go_lossy(file));
                copied.bytes += bytes;
            }
            Err(error) => copied.failures.push(format!("{}: {error}", go_lossy(file))),
        }
    }
    copied
}

/// Copies the regular file `from` to a new file `to`, with `from`'s mode, removing what it wrote
/// if the copy fails part way. Each failure in Go's `*PathError` words (`open <path>: …`).
fn copy_file(from: &Path, to: &Path) -> Result<u64, String> {
    let failed = |step: &str, path: &Path, error: &std::io::Error| {
        format!("{step} {}: {}", path.display(), config::os_error(error))
    };
    let mut source = std::fs::File::open(from).map_err(|error| failed("open", from, &error))?;
    let info = source
        .metadata()
        .map_err(|error| failed("stat", from, &error))?;
    if let Some(parent) = to.parent() {
        config::make_dir_all(&parent.to_string_lossy()).map_err(|error| error.to_string())?;
    }
    let mut target = std::fs::File::options()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(to)
        .map_err(|error| failed("open", to, &error))?;
    let result = (|| {
        let mut buffer = vec![0u8; 64 << 10];
        let mut total = 0u64;
        loop {
            let n = match source.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => n,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(failed("read", from, &error)),
            };
            target
                .write_all(&buffer[..n])
                .map_err(|error| failed("write", to, &error))?;
            total += n as u64;
        }
        drop(target);
        std::fs::set_permissions(
            to,
            std::fs::Permissions::from_mode(info.permissions().mode() & 0o777),
        )
        .map_err(|error| failed("chmod", to, &error))?;
        Ok(total)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(to);
    }
    result
}

/// `path` with the home folder written as `~`, as Go's `ui.DisplayPath` shows it.
fn display_path(context: &Context, path: &str) -> String {
    config::display_path(config::home_dir(context).ok().as_deref(), path)
}

/// The human create: the setup script's output streams into a log panel, then any warnings, the
/// success line, and, unless `--no-editor`, the offer to open the workroom in `$EDITOR`. Go's
/// `createWorkroom`.
fn human(creator: &mut Creator, offer_editor: bool) -> Result<Outcome, CliError> {
    let context = creator.plan.context;
    let paint = Paint(context.color);
    creator.panel = Some(LogPanel::new(std::io::stdout(), "Setup", paint));
    let (made, result) = creator.create_named();
    let shown = creator.panel.take().is_some_and(|mut panel| {
        panel.close(result.is_ok());
        panel.shown()
    });
    let mut out = std::io::stdout();
    // Before a setup error too: offline, the fetch and a networked setup script fail together.
    if let Some(made) = &made {
        let mut warnings = Vec::new();
        if !made.warning.is_empty() {
            warnings.push(made.warning.clone());
        }
        warnings.extend(
            made.include_skipped
                .iter()
                .map(|file| skipped_symlink(file)),
        );
        warnings.extend(
            [&made.include_warning, &made.changes_warning]
                .into_iter()
                .filter(|warning| !warning.is_empty())
                .cloned(),
        );
        for warning in warnings {
            let _ = writeln!(out, "{}", paint.yellow(&warning));
        }
    }
    result?;
    let made = made.expect("a create that succeeds has made its workroom");
    if shown {
        let _ = writeln!(out);
    }
    let _ = writeln!(
        out,
        "{}",
        paint.green(&format!(
            "Workroom '{}' created successfully at {}.",
            made.name,
            display_path(context, &made.path)
        ))
    );
    let _ = out.flush();
    let editor = context.env("EDITOR").unwrap_or_default();
    if !editor.is_empty() && !context.pretend && offer_editor {
        // On the terminal, as Go's prompt (charmbracelet/huh) asks: a create with no terminal fails
        // here, after the workroom is made, as Go's does.
        if prompt::ask(&format!("Open workroom in {editor}?"))? {
            open_editor(&editor, &made.path)
                .map_err(|error| CliError::internal(format!("failed to open editor: {error}")))?;
        }
    }
    Ok(Outcome::Printed(String::new()))
}

/// Opens `path` with `editor`, a command line such as `$EDITOR`, attached to this terminal.
fn open_editor(editor: &str, path: &str) -> Result<(), String> {
    let mut words = editor.split_whitespace();
    let program = words.next().unwrap_or_default();
    let status = std::process::Command::new(program)
        .args(words)
        .arg(path)
        .status()
        .map_err(|error| {
            if error.kind() == std::io::ErrorKind::NotFound {
                format!("exec: {program:?}: executable file not found in $PATH")
            } else {
                format!("fork/exec {program}: {}", config::os_error(&error))
            }
        })?;
    if status.success() {
        Ok(())
    } else {
        Err(super::teardown::go_exit(&status))
    }
}

/// A create's steps and the git and script output behind them, as NDJSON on stderr under
/// `--json` (Go's `OnStep`, `OnReady` and `jsonLogWriter`); nothing otherwise.
struct Events(Option<LogWriter<std::io::Stderr>>);

impl Events {
    /// One `step` or `created` event, encoded as Go's `writeJSONEvent` encodes it: without the
    /// HTML escaping the log lines have.
    fn event<T: Serialize>(&mut self, event: &T) {
        if self.0.is_some() {
            let mut line = envelope::encode(event, false);
            line.push('\n');
            let _ = std::io::stderr().write_all(line.as_bytes());
        }
    }

    /// Sends what the log holds without a newline.
    fn flush(&mut self) {
        if let Some(log) = &mut self.0 {
            log.flush();
        }
    }
}

impl Progress for Events {
    fn step(&mut self, id: &str, state: &str, detail: &str) {
        #[derive(Serialize)]
        struct Step<'a> {
            #[serde(skip_serializing_if = "str::is_empty")]
            detail: &'a str,
            id: &'a str,
            state: &'a str,
            r#type: &'a str,
        }
        let Some(log) = &mut self.0 else {
            return;
        };
        // Log events carry the step running.
        if state == "running" {
            log.flush();
            log.step = id.to_string();
        }
        self.event(&Step {
            detail,
            id,
            state,
            r#type: "step",
        });
    }

    fn log(&mut self, line: &str) {
        if let Some(log) = &mut self.0 {
            log.feed(line.as_bytes());
            log.feed(b"\n");
        }
    }
}

/// The setup script's output, a line at a time.
impl Write for Events {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if let Some(log) = &mut self.0 {
            log.feed(bytes);
        }
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes_are_shown_as_go_shows_them() {
        assert_eq!(byte_size(999), "999 B");
        assert_eq!(byte_size(1000), "1.0 KB");
        assert_eq!(byte_size(1_234_567), "1.2 MB");
        assert_eq!(byte_size(999_999_999_999_999), "1000.0 TB");
    }

    /// Go's `TestChooseStartOffersAndMapsEachChoice`: only the choices that apply are offered,
    /// each maps to the start it says, and the summary and the behind note are said first.
    #[test]
    fn the_start_question_offers_and_maps_each_choice() {
        let work = |ahead, uncommitted, behind| LocalWork {
            branch: "main".to_string(),
            remote: "origin".to_string(),
            ahead,
            uncommitted,
            behind,
            stale: false,
        };
        let question = "New workrooms start from what you've pushed. Include this work in the new \
                        one?";
        for (work, said, starts) in [
            (
                work(2, true, 0),
                format!(
                    "You have 2 commits on main that you haven't pushed yet, and some changes you \
                     haven't committed.\n{question}\n  1) Include my commits and changes\n  2) \
                     Include my commits only\n  3) Leave it out\n"
                ),
                &[Start::LocalWithChanges, Start::Local, Start::Origin][..],
            ),
            (
                work(0, true, 3),
                format!(
                    "You have changes on main that you haven't committed yet.\nYour main is also \
                     3 commits behind origin, so including your work starts from your older \
                     copy. {question}\n  1) Include my changes\n  2) Leave it out\n"
                ),
                &[Start::LocalWithChanges, Start::Origin],
            ),
            (
                work(1, false, 0),
                format!(
                    "You have 1 commit on main that you haven't pushed yet.\n{question}\n  1) \
                     Include my commits\n  2) Leave it out\n"
                ),
                &[Start::Local, Start::Origin],
            ),
        ] {
            for (number, want) in starts.iter().enumerate() {
                let mut out = Vec::new();
                // An answer that is no choice is asked again.
                let answer = format!("x\n9\n{}\n", number + 1);
                let start = ask_start(&mut out, &mut answer.as_bytes(), &work).expect("answered");
                assert!(start == *want, "{said}: choice {number}");
                let out = String::from_utf8(out).expect("UTF-8");
                let prompt = format!("Choose 1-{}: ", starts.len());
                assert_eq!(out, format!("{said}{}", prompt.repeat(3)));
            }
            let error = ask_start(&mut Vec::new(), &mut &b""[..], &work).expect_err("no answer");
            assert_eq!(error.message, "user aborted");
        }
    }

    #[test]
    fn a_start_commit_is_a_full_hash() {
        assert!(is_commit_hash(&"ab".repeat(20)));
        assert!(is_commit_hash(&"0f".repeat(32)));
        for text in ["--upload-pack=touch x", "HEAD~1", "abc", &"AB".repeat(20)] {
            assert!(!is_commit_hash(text), "{text}");
        }
    }
}
