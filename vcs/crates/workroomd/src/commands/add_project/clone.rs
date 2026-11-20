//! `add-project --clone URL PATH` (#620), as Go's `Service.CloneProject`: clones URL into the
//! local PATH and registers the clone. URL is anything `git clone` accepts. git never prompts: it
//! runs in a session of its own with no controlling terminal and `GIT_TERMINAL_PROMPT=0`, so
//! missing credentials fail fast, and it inherits none of the repository variables a git hook or
//! alias would pass down.
//!
//! ```text
//! sweep a dead clone's staging in PATH and beside it (`staging`) ── a signal ──► Cancelled
//! stat(PATH)
//!  ├── a file, or a dangling symlink ──► NotADirectory
//!  ├── a folder with files in it ──────► DestinationNotEmpty (naming any staging in the way)
//!  ├── an empty folder ──► lock PATH/.clone-*.lock; git clone --progress -- URL PATH/.clone-*
//!  │                        └── ok ─► move each entry up into PATH ─┐
//!  │                                   └── a name taken meanwhile ──► DestinationNotEmpty
//!  └── missing ──► make missing parents; lock <parent>/.<name>.clone-*.lock;
//!                  git clone --progress -- URL <parent>/.<name>.clone-* (0755 less umask)
//!                   └── ok ─► rename the staging to PATH ──────────┐
//!                              └── PATH created meanwhile ──► DestinationNotEmpty
//!   either clone ├── a signal ──► Cancelled                       │
//!                └── git fails ─► CloneFailed, with git's own error lines
//!                                                                  ▼
//!                                       remove the lock; register ── fails ──► ConfigWriteFailed;
//!                                                                              the clone is kept
//! ```
//!
//! A failure or a cancel before the clone is in place removes only what this run made: its
//! staging folder, the entries it moved, its lock file, and any parent folder it made that is
//! still empty. An existing folder is cloned into, never replaced, so it keeps its mode, ACLs,
//! xattrs and Finder tags, and the staging never crosses filesystems. A concurrent clone into the
//! same path or a sibling, or a file saved into a parent meanwhile, survives.
//!
//! A SIGTERM, SIGINT or SIGHUP to the CLI SIGTERMs git's whole process group, so a transport
//! helper or ssh it started dies with it, and SIGKILLs what is left after [`KILL_GRACE`]. Under
//! `--pretend` nothing is cloned or written.

use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

use super::super::config::{self, Config, os_error};
use super::super::kind::{CliError, Kind};
use super::staging::{self, LockError};
use super::{
    Context, FINDER_JUNK, cancelled, config_write, dir_is_empty, go_exit, go_start_error,
    local_canonical, not_a_directory,
};
use crate::script::Signals;

/// How long git's process group has to exit after the SIGTERM a cancel sends it, before a
/// SIGKILL.
const KILL_GRACE: Duration = Duration::from_secs(3);

/// How long git's stderr is still read once git has exited, for a helper it left holding the
/// pipe: Go's `WaitDelay`.
const WAIT_DELAY: Duration = Duration::from_secs(2);

const POLL: Duration = Duration::from_millis(20);

/// Clones `url` into `path` and registers it, returning the path registered (or that would be,
/// under `--pretend`). git's output streams to `progress` as it runs.
pub(super) fn clone_project(
    context: &Context,
    config: &Config,
    url: &str,
    path: &str,
    progress: &mut dyn Write,
    signals: &Signals,
) -> Result<String, CliError> {
    let mut canon = local_canonical(path, context)?;
    let target = PathBuf::from(&canon);

    // Staging a crashed or killed clone left behind would make the destination look taken. What
    // is provably dead is swept first (not under --pretend, which only looks past it).
    let host = staging::machine_host().unwrap_or("");
    let (inside, beside) = staging::stale_staging_for(&target, host);
    let mut ignore = Vec::new();
    if context.pretend {
        ignore.extend(inside.iter().flat_map(staging::Stale::paths));
        drop((inside, beside));
    } else {
        staging::remove_stale(
            signals,
            progress,
            inside.into_iter().chain(beside).collect(),
        )?;
    }
    let existed = clone_destination(&target, &canon, &ignore)?;
    if context.pretend {
        return Ok(canon);
    }

    let made = mkdir_parents(target.parent().unwrap_or(Path::new("/")))?;
    let (stage, lock) = match make_staging(&target, &canon, existed, &staging::staging_owner()) {
        Ok(made_stage) => made_stage,
        Err(error) => {
            remove_empty_dirs(&made);
            return Err(error);
        }
    };
    let mut run = Run {
        canon: target.clone(),
        stage,
        lock,
        placed: Vec::new(),
        made,
        published: false,
    };
    run_clone(url, &run.stage, progress, run.lock.as_ref(), signals)?;
    if existed {
        move_up(&run.stage, &target, &mut run.placed)?;
    } else {
        rename_into(&run.stage, &target, &canon)?;
    }
    run.publish();

    // The clone exists now, so resolve it: under a symlinked parent it is stored in its
    // symlink-evaluated form, as an existing project's path is.
    if let Ok(resolved) = config::canonical_path(&canon, context) {
        canon = resolved;
    }
    config.add_project(&canon, "git").map_err(|error| {
        config_write(format!(
            "the clone is at {canon} but could not be registered: {}",
            error.message
        ))
    })?;
    Ok(canon)
}

/// One clone's own paths, removed again unless the clone reaches its place: what it moved into
/// the destination, its staging, then its lock file (last, so no sweep sees the staging unlocked)
/// and the empty parents it made (after the lock, which may be the last thing in one).
struct Run {
    canon: PathBuf,
    stage: PathBuf,
    lock: Option<File>,
    /// What `move_up` has put in the destination so far.
    placed: Vec<std::ffi::OsString>,
    made: Vec<PathBuf>,
    /// The whole clone is in place: from here on it is kept.
    published: bool,
}

impl Run {
    fn publish(&mut self) {
        self.published = true;
        staging::release_lock(self.lock.take(), &self.stage);
    }
}

impl Drop for Run {
    fn drop(&mut self) {
        if self.published {
            return;
        }
        for name in &self.placed {
            remove_all(&self.canon.join(name));
        }
        remove_all(&self.stage);
        staging::release_lock(self.lock.take(), &self.stage);
        remove_empty_dirs(&self.made);
    }
}

/// Go's `os.RemoveAll` of a path this run made: a folder with what is in it, anything else
/// itself, a symlink never followed.
fn remove_all(path: &Path) {
    match std::fs::symlink_metadata(path) {
        Ok(info) if info.is_dir() => {
            let _ = std::fs::remove_dir_all(path);
        }
        Ok(_) => {
            let _ = std::fs::remove_file(path);
        }
        Err(_) => {}
    }
}

/// Whether `target` can take a clone: true when it is an empty folder already, false when it is
/// missing.
fn clone_destination(target: &Path, canon: &str, ignore: &[PathBuf]) -> Result<bool, CliError> {
    // A symlink left at the path is one canonicalizing couldn't resolve: it points nowhere (an
    // unmounted drive, say). It is refused, not taken for a missing folder and replaced.
    if std::fs::symlink_metadata(target).is_ok_and(|info| info.file_type().is_symlink()) {
        return Err(not_a_directory());
    }
    match std::fs::metadata(target) {
        Ok(info) if !info.is_dir() => Err(not_a_directory()),
        Ok(_) => {
            if dir_is_empty(target, ignore)? {
                return Ok(true);
            }
            let blocking = staging::staging_in_the_way(target, ignore);
            if blocking.is_empty() {
                return Err(destination_not_empty(canon));
            }
            Err(CliError::new(
                Kind::DestinationNotEmpty,
                format!(
                    "the destination folder is not empty: {canon} (a clone's staging is in the \
                     way: {}; remove it if no clone is running)",
                    blocking.join(", ")
                ),
            ))
        }
        Err(error) if error.raw_os_error() == Some(libc::ENOTDIR) => Err(not_a_directory()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(CliError::internal(format!(
            "stat {canon}: {}",
            os_error(&error)
        ))),
    }
}

fn destination_not_empty(canon: &str) -> CliError {
    CliError::new(
        Kind::DestinationNotEmpty,
        format!("the destination folder is not empty: {canon}"),
    )
}

/// Makes `dir` and any missing folders above it, returning the ones this call made, outermost
/// first. A folder another process makes meanwhile is used but not claimed.
fn mkdir_parents(dir: &Path) -> Result<Vec<PathBuf>, CliError> {
    let mut missing = Vec::new();
    let mut at = dir;
    loop {
        match std::fs::metadata(at) {
            Ok(_) => break,
            Err(error) if error.raw_os_error() == Some(libc::ENOTDIR) => {
                return Err(not_a_directory());
            }
            Err(_) => missing.push(at.to_path_buf()),
        }
        match at.parent() {
            Some(parent) => at = parent,
            None => break,
        }
    }
    let mut made = Vec::new();
    for folder in missing.iter().rev() {
        match std::fs::DirBuilder::new().mode(0o755).create(folder) {
            Ok(()) => made.push(folder.clone()),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => {
                remove_empty_dirs(&made);
                if error.raw_os_error() == Some(libc::ENOTDIR) {
                    return Err(not_a_directory());
                }
                let folder = folder.display();
                return Err(config_write(format!(
                    "create directory {folder}: mkdir {folder}: {}",
                    os_error(&error)
                )));
            }
        }
    }
    Ok(made)
}

/// Removes the folders [`mkdir_parents`] made, innermost first, leaving any that something else
/// has written into: `rmdir` only removes an empty one.
fn remove_empty_dirs(made: &[PathBuf]) {
    for folder in made.iter().rev() {
        let _ = std::fs::remove_dir(folder);
    }
}

/// Makes the folder the clone runs in: inside the destination (`.clone-*`, 0700) when it exists,
/// else beside it (`.<name>.clone-*`, 0755 less the umask, since it becomes the project folder
/// itself, so a private umask keeps a private repo private). Its lock file is made and locked
/// first, so a sweep never sees this run's staging unlocked; no lock where the filesystem has no
/// `flock`, which leaves the pid in the name to speak for the run.
fn make_staging(
    target: &Path,
    canon: &str,
    existed: bool,
    owner: &str,
) -> Result<(PathBuf, Option<File>), CliError> {
    let (parent, prefix, mode) = if existed {
        (target.to_path_buf(), format!(".clone-{owner}"), 0o700)
    } else {
        let name = target
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        (
            target.parent().unwrap_or(Path::new("/")).to_path_buf(),
            format!(".{name}.clone-{owner}"),
            0o755,
        )
    };
    for attempt in 0u32..100 {
        let stage = parent.join(format!("{prefix}{}", base36(random_u32(attempt))));
        let lock = match staging::create_lock(&staging::lock_path(&stage)) {
            Ok(lock) => Some(lock),
            Err(LockError::Exists | LockError::Lost) => continue,
            Err(LockError::Unsupported) => None,
            Err(LockError::Failed(error)) => {
                return Err(config_write(format!(
                    "create staging lock for {canon}: {error}"
                )));
            }
        };
        match std::fs::DirBuilder::new().mode(mode).create(&stage) {
            Ok(()) => return Ok((stage, lock)),
            Err(error) => {
                staging::release_lock(lock, &stage);
                if error.kind() != io::ErrorKind::AlreadyExists {
                    return Err(config_write(format!(
                        "create staging folder for {canon}: mkdir {}: {}",
                        stage.display(),
                        os_error(&error)
                    )));
                }
            }
        }
    }
    Err(config_write(format!(
        "create staging folder for {canon}: no free name"
    )))
}

fn random_u32(attempt: u32) -> u32 {
    use std::hash::{BuildHasher, RandomState};
    RandomState::new().hash_one((std::process::id(), Instant::now(), attempt)) as u32
}

/// `value` in base 36, as Go's `strconv.FormatUint(v, 36)`.
fn base36(mut value: u32) -> String {
    const DIGITS: &[u8; 36] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut out = Vec::new();
    loop {
        out.push(DIGITS[(value % 36) as usize]);
        value /= 36;
        if value == 0 {
            break;
        }
    }
    out.reverse();
    String::from_utf8(out).expect("ASCII digits")
}

/// Go's `os.Rename` on Unix: refused with EEXIST when the target is an existing folder (rename(2)
/// would replace an empty one), else rename(2). The error is Go's `LinkError` wording.
fn go_rename(from: &Path, to: &Path) -> Result<(), String> {
    let refused = |error: &io::Error| {
        format!(
            "rename {} {}: {}",
            from.display(),
            to.display(),
            os_error(error)
        )
    };
    if let Ok(target) = std::fs::symlink_metadata(to)
        && target.is_dir()
    {
        use std::os::unix::fs::MetadataExt;
        match std::fs::symlink_metadata(from) {
            Err(error) => return Err(refused(&error)),
            Ok(source)
                if from == to || source.dev() != target.dev() || source.ino() != target.ino() =>
            {
                return Err(refused(&io::Error::from_raw_os_error(libc::EEXIST)));
            }
            Ok(_) => {}
        }
    }
    std::fs::rename(from, to).map_err(|error| refused(&error))
}

/// Renames the staging folder to the destination, which did not exist when the clone started. If
/// something has made it meanwhile the rename fails, and the destination then existing is what
/// says why.
fn rename_into(stage: &Path, target: &Path, canon: &str) -> Result<(), CliError> {
    go_rename(stage, target).map_err(|error| {
        if std::fs::symlink_metadata(target).is_ok() {
            destination_not_empty(canon)
        } else {
            config_write(format!("move the clone to {canon}: {error}"))
        }
    })
}

/// Moves the clone out of a staging folder inside the destination into the destination itself,
/// recording each entry it moves. It refuses if anything but Finder's junk and the staging's own
/// lock file has appeared there, or if a clone entry would land on a name that is taken.
fn move_up(
    stage: &Path,
    target: &Path,
    placed: &mut Vec<std::ffi::OsString>,
) -> Result<(), CliError> {
    let canon = target.display().to_string();
    // Junk the clone might also hold (a tracked .DS_Store) would otherwise clash with Finder's.
    for junk in FINDER_JUNK {
        let path = target.join(junk);
        if std::fs::remove_file(&path).is_err() {
            let _ = std::fs::remove_dir(&path);
        }
    }
    let read = |dir: &Path| {
        std::fs::read_dir(dir).map_err(|error| {
            CliError::internal(format!("open {}: {}", dir.display(), os_error(&error)))
        })
    };
    let stage_name = stage.file_name().unwrap_or_default().to_os_string();
    let mut lock_name = stage_name.clone();
    lock_name.push(".lock");
    for entry in read(target)?.filter_map(Result::ok) {
        let name = entry.file_name();
        if name != stage_name && name != lock_name && !FINDER_JUNK.iter().any(|junk| name == *junk)
        {
            return Err(destination_not_empty(&canon));
        }
    }
    let mut names: Vec<_> = read(stage)?
        .filter_map(Result::ok)
        .map(|entry| entry.file_name())
        .collect();
    names.sort();
    for name in names {
        let from = stage.join(&name);
        let to = target.join(&name);
        if std::fs::symlink_metadata(&to).is_ok() {
            return Err(destination_not_empty(&canon));
        }
        if let Err(error) = go_rename(&from, &to) {
            if std::fs::symlink_metadata(&from).is_err() {
                // It moved after all; claim it so a cleanup removes it.
                placed.push(name);
            } else if std::fs::symlink_metadata(&to).is_ok() {
                return Err(destination_not_empty(&canon));
            }
            return Err(config_write(format!("move the clone to {canon}: {error}")));
        }
        placed.push(name);
    }
    std::fs::remove_dir(stage).map_err(|error| {
        CliError::internal(format!("remove {}: {}", stage.display(), os_error(&error)))
    })
}

/// The inherited variables that would aim the clone at another repository's files, which a
/// `workroom` run from a git hook or alias inherits: `git::command`'s redirects plus the rest of
/// `git rev-parse --local-env-vars` but its config variables. git's config, ssh and protocol
/// variables (`GIT_CONFIG*`, `GIT_SSH_COMMAND`, `GIT_ASKPASS`, `GIT_ALLOW_PROTOCOL`…) are the
/// user's and are kept.
const CLONE_REPO_VARIABLES: [&str; 14] = [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CEILING_DIRECTORIES",
    "GIT_NAMESPACE",
    "GIT_PREFIX",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_GRAFT_FILE",
    "GIT_NO_REPLACE_OBJECTS",
    "GIT_REPLACE_REF_BASE",
    "GIT_SHALLOW_FILE",
];

/// `git clone --progress -- url dest`, in this process's directory, with its environment less
/// [`CLONE_REPO_VARIABLES`] and with `GIT_TERMINAL_PROMPT=0` (names compared ignoring case, as Go
/// compares them), in a session of its own. It inherits `lock` as an extra open file, so it and
/// every helper it starts hold the staging's lock too. `inherited` is this process's environment:
/// a test's seam.
fn clone_command(
    url: &str,
    dest: &Path,
    lock: Option<&File>,
    inherited: impl Iterator<Item = (std::ffi::OsString, std::ffi::OsString)>,
) -> Command {
    let mut command = Command::new("git");
    command
        .args(["clone", "--progress", "--"])
        .arg(url)
        .arg(dest)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    for (key, _) in inherited {
        let name = key.to_string_lossy();
        if name.eq_ignore_ascii_case("GIT_TERMINAL_PROMPT")
            || CLONE_REPO_VARIABLES
                .iter()
                .any(|variable| name.eq_ignore_ascii_case(variable))
        {
            command.env_remove(&key);
        }
    }
    command.env("GIT_TERMINAL_PROMPT", "0");
    let lock_fd = lock.map(AsRawFd::as_raw_fd);
    // SAFETY: between fork and exec this only calls setsid and fcntl, which are async-signal-safe,
    // on a descriptor this process holds open for the whole spawn.
    unsafe {
        command.pre_exec(move || {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            if let Some(fd) = lock_fd {
                // Only this child keeps the lock across exec; every other spawn's copy closes.
                let flags = libc::fcntl(fd, libc::F_GETFD);
                if flags == -1 || libc::fcntl(fd, libc::F_SETFD, flags & !libc::FD_CLOEXEC) == -1 {
                    return Err(io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    command
}

/// Runs the clone, streaming git's stderr to `progress` and keeping its tail for the error. A
/// cancelling signal SIGTERMs git's group, then SIGKILLs it after [`KILL_GRACE`]; once git is
/// reaped, its group is signalled again only while a member of it is left, since an empty group's
/// id is free for reuse.
fn run_clone(
    url: &str,
    dest: &Path,
    progress: &mut dyn Write,
    lock: Option<&File>,
    signals: &Signals,
) -> Result<(), CliError> {
    let mut child = clone_command(url, dest, lock, std::env::vars_os())
        .spawn()
        .map_err(|error| clone_failed(&go_start_error("git", &error)))?;
    let group = child.id() as libc::pid_t;
    let mut stderr = child.stderr.take();
    let mut tail = TailBuffer::default();
    let mut status: Option<(ExitStatus, Instant)> = None;
    let mut terminated: Option<Instant> = None;
    let mut killed = false;
    loop {
        if status.is_none()
            && let Ok(Some(exited)) = child.try_wait()
        {
            status = Some((exited, Instant::now()));
        }
        if let Some((_, at)) = status
            && (stderr.is_none() || at.elapsed() >= WAIT_DELAY)
        {
            break;
        }
        if signals.received().is_some() {
            match terminated {
                None if status.is_none() || group_alive(group) => {
                    signal_group(group, libc::SIGTERM);
                    terminated = Some(Instant::now());
                }
                Some(at) if !killed && status.is_none() && at.elapsed() >= KILL_GRACE => {
                    signal_group(group, libc::SIGKILL);
                    killed = true;
                }
                _ => {}
            }
        }
        match &mut stderr {
            Some(pipe) => {
                if !read_some(pipe, progress, &mut tail) {
                    stderr = None;
                }
            }
            None => std::thread::sleep(POLL),
        }
    }
    let Some((status, _)) = status else {
        unreachable!("the loop ends only once git has exited");
    };
    if signals.received().is_some() {
        // git is gone. A member of its group that ignored the SIGTERM (a helper still holding
        // stderr) keeps the group id allocated, so a SIGKILL to the group reaches only it.
        if group_alive(group) {
            signal_group(group, libc::SIGKILL);
        }
        return Err(cancelled());
    }
    // git exited 0 and only a helper it left behind kept stderr open: that is success.
    if status.success() {
        return Ok(());
    }
    let lines = clone_error_lines(&tail.text());
    if lines.is_empty() {
        Err(clone_failed(&go_exit(&status)))
    } else {
        Err(clone_failed(&lines))
    }
}

/// Copies what git has written to its stderr within one poll, if anything. False once the pipe
/// has closed.
fn read_some(
    pipe: &mut std::process::ChildStderr,
    progress: &mut dyn Write,
    tail: &mut TailBuffer,
) -> bool {
    let mut poll = libc::pollfd {
        fd: pipe.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: one valid pollfd, for a descriptor this owns.
    let ready = unsafe { libc::poll(&mut poll, 1, POLL.as_millis() as libc::c_int) };
    if ready <= 0 {
        return true;
    }
    let mut chunk = [0u8; 65536];
    match pipe.read(&mut chunk) {
        Ok(0) => false,
        Ok(count) => {
            let _ = progress.write_all(&chunk[..count]);
            tail.write(&chunk[..count]);
            true
        }
        Err(error) if error.kind() == io::ErrorKind::Interrupted => true,
        Err(_) => false,
    }
}

fn signal_group(group: libc::pid_t, signal: libc::c_int) {
    // SAFETY: signals the process group git leads; it may already be gone.
    unsafe { libc::kill(-group, signal) };
}

/// Whether any process is left in git's group.
fn group_alive(group: libc::pid_t) -> bool {
    // SAFETY: signal 0 only checks that the group has a member.
    unsafe { libc::kill(-group, 0) == 0 }
}

fn clone_failed(detail: &str) -> CliError {
    CliError::new(Kind::CloneFailed, format!("git clone failed: {detail}"))
}

/// How much of git's stderr is kept for the error: its tail, where git says why it failed. A
/// server streaming progress forever can't grow it further.
const STDERR_CAP: usize = 64 << 10;

/// The last [`STDERR_CAP`] bytes written.
#[derive(Default)]
struct TailBuffer {
    kept: Vec<u8>,
    truncated: bool,
}

impl TailBuffer {
    fn write(&mut self, mut bytes: &[u8]) {
        if bytes.len() >= STDERR_CAP {
            bytes = &bytes[bytes.len() - STDERR_CAP..];
            self.kept.clear();
            self.truncated = true;
        } else if let Some(over) = (self.kept.len() + bytes.len()).checked_sub(STDERR_CAP)
            && over > 0
        {
            self.kept.drain(..over);
            self.truncated = true;
        }
        self.kept.extend_from_slice(bytes);
    }

    /// What is kept, without the line the cap cut into, which a filter could mistake for an error
    /// line.
    fn text(&self) -> String {
        let mut kept = &self.kept[..];
        if self.truncated {
            match kept.iter().position(|&b| b == b'\r' || b == b'\n') {
                Some(end) => kept = &kept[end + 1..],
                None => return String::new(),
            }
        }
        super::super::log::go_lossy(kept)
    }
}

/// git clone's stderr without its progress: the "Cloning into" line, every "<what>: <n>% (…)"
/// counter, redrawn or finished, every finished "…, done." line, and the server's own object
/// counts. What's left is git's own account of the failure, which doesn't always say "fatal:"
/// ("Permission denied (publickey).", "remote: Repository not found.").
fn clone_error_lines(stderr: &str) -> String {
    const REMOTE_PROGRESS: [&str; 4] = [
        "remote: Enumerating objects:",
        "remote: Counting objects:",
        "remote: Compressing objects:",
        "remote: Total ",
    ];
    stderr
        .split(['\n', '\r'])
        .map(str::trim)
        .filter(|line| {
            !line.is_empty()
                && !line.starts_with("Cloning into ")
                && !line.contains("% (")
                && !line.ends_with(", done.")
                && !REMOTE_PROGRESS
                    .iter()
                    .any(|prefix| line.starts_with(prefix))
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests;
