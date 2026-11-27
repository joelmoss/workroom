//! Resuming a program in a pane's new session (ADR 0082, #825): the file that carries a resume
//! record from the app to the relay and from the daemon to its helper, and the helper itself
//! (`workroomd resume-launch`).
//!
//! **How a record is run.** The session's shell starts as it would have, its own login shell with
//! Ghostty's integration, and is told of the launch file in its environment (`prepare`:
//! `FILE_VARIABLE`, and the helper in `HELPER_VARIABLE`). Workroom's hook for that shell
//! (`daemon::bin_dir`: zsh's `.zshenv`, bash's `ENV`, fish's `vendor_conf.d`) takes both out of
//! the environment before any startup file runs, and at the first prompt, once the startup files
//! have set PATH, runs `<helper> resume-launch <file>` as the shell's first foreground job. So the
//! program is a job of the pane's interactive shell, as one the user typed: ^Z suspends it to that
//! shell's prompt, `fg` brings it back, and quitting it leaves the prompt in its folder. Only the
//! file's path is ever in the shell's environment or the job's words, never the command, and the
//! hook runs no line the shell's history keeps. A shell with no such hook (sh, dash, ksh, nu,
//! elvish, macOS's own bash, which Ghostty's integration skips, or any session with no hooks
//! folder) is not resumed: it starts as a new shell (`bin_path::hooked`).
//!
//! **The helper.** `resume-launch` claims the launch file, goes to the record's folder and finds
//! the command on PATH, then forks. The child reports the record over OSC 7577 as its own pid (so
//! the record's owner is the process that runs the program, which keeps that pid) and `execv`s
//! the command literally, never through a shell: no word is split or expanded. The parent stays in
//! the job and waits, so it alone knows when the program has really ended, not merely stopped:
//! it ignores ^C, ^\ and ^Z, which are the program's, stops itself when the program stops (the
//! shell then sees the job stopped) and continues it again with the job. When the program ends
//! with an error, or could not start, the parent says so as an OSC 7577 report with
//! `workroomexit`, signed with the token the shell's environment gave it, which the daemon turns
//! into the status event's `resumeFailed` (`resume::Resume::exited`).
//!
//! **Why a file.** A command's arguments can hold secrets, and a process's arguments and
//! environment show in process listings. So the command goes from the app to the relay, and from
//! the daemon to its helper, in a file only this user can read (`0600` in a `0700` folder), which
//! its reader claims once and removes (`claim`). It holds the record alone (its command, folder
//! and time), never the session's token or environment, which the helper inherits from the shell.
//!
//! **Whose files these are.** A launch folder is made by this code alone, `0700`, beside the
//! daemon's socket (`dir_beside`) or in the app's own support folder, and a file in it is this
//! code's when its name is `resume-<session id>-<32 hex>.json` (`is_launch_name`), with `.claim`
//! after it once claimed. Nothing else writes such a name there. A file left behind (its pane
//! closed before its shell got as far as its first prompt) is removed by the daemon at a fresh
//! start, when no session it made can still be waiting for one, and at any later launch once it is
//! an hour old and its session (the id in its name) no longer runs: a running session's shell may
//! still be starting. So never one a helper could still claim. Only regular files are removed,
//! judged by `symlink_metadata`, so a link or a FIFO with such a name is left. A session that
//! could not be made after its file was written removes that one path (`discard`).
//!
//! The claim and the literal `execv` are ported from herdr-core (herdrdev/herdr-core#429,
//! `crates/herdr-core/src/resume/launch.rs` and `crates/herdr-core/src/platform/unix_resume.rs`
//! at `0cb50d57832f3ebb69157ce7f023fbbc520181a8`), Licensed under the Apache License, Version 2.0
//! (`LICENSE` beside this file). Changed from the original for Workroom: the claim is a hard link
//! and an unlink, which refuses to replace on every Unix this runs on, rather than `renameat2`; a
//! file's name carries its session's id; the session's own interactive shell runs the helper from
//! its first prompt, rather than a wrapper script that `exec`s a login shell after it, so the
//! program is one of that shell's jobs; the helper forks, its child reporting the record as its
//! own pid before it `execv`s and its parent reporting a failed program's status; and there is no
//! `first` mode, since a session's first process is always its shell.

use std::ffi::{OsStr, OsString};
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};

use crate::terminal::session::SessionId;
use crate::terminal::shell::{Invocation, shell_name};

/// The variable the app names its launch file in, for the relay (`WORKROOM_SESSION_RESUME`).
pub const APP_FILE_VARIABLE: &str = "WORKROOM_SESSION_RESUME";

/// The variable a resuming session's shell finds its launch file in, which its hook takes out of
/// the environment at once (module doc).
pub(crate) const FILE_VARIABLE: &str = "WORKROOM_RESUME_FILE";
/// The variable it finds the helper in: the daemon's own binary.
pub(crate) const HELPER_VARIABLE: &str = "WORKROOM_RESUME_HELPER";

/// How soon after it started a resumed program that exits with an error says it could not be
/// resumed (ADR 0082), counted from the helper's report, the moment the program starts: longer
/// than a program takes to fail at its start, shorter than a session anyone used.
pub(crate) const FAILED_WITHIN: Duration = Duration::from_secs(5);

/// The most a launch file may hold: a record is at most 8 KiB.
const MAX_FILE: u64 = 1 << 20;

/// How old a launch file must be before a later launch removes it: no helper waits that long.
const ABANDONED: Duration = Duration::from_secs(60 * 60);

/// The most words a record may have, as a report may carry (`protocol`).
const MAX_WORDS: usize = 64;
/// The most bytes its words may have together, as a report may carry (`protocol::LIMIT`).
const MAX_BYTES: usize = 8192;

/// What `resume-launch` runs: the command and its folder. Also the app's file for the relay,
/// which adds when it was reported.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Launch {
    pub argv: Vec<String>,
    pub cwd: String,
    #[serde(default, rename = "reportedAt")]
    pub reported_at_ms: u64,
}

impl std::fmt::Debug for Launch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The arguments can hold secrets: only the program is printed.
        write!(f, "Launch({})", super::program_name(&self.argv))
    }
}

impl Launch {
    /// Whether this is a record a report could have made (`protocol::parse`'s rules): a command
    /// of at most `MAX_WORDS` words and `MAX_BYTES`, its first an absolute path or a bare name,
    /// none with a control character, and an absolute folder.
    pub(crate) fn is_well_formed(&self) -> bool {
        let Some(first) = self.argv.first() else {
            return false;
        };
        let path = Path::new(first);
        let command = path.is_absolute()
            || (!first.starts_with('-')
                && !first.contains('/')
                && matches!(
                    path.components().next(),
                    Some(std::path::Component::Normal(_))
                ));
        command
            && self.argv.len() <= MAX_WORDS
            && self.argv.iter().map(String::len).sum::<usize>() <= MAX_BYTES
            && !self
                .argv
                .iter()
                .chain(std::iter::once(&self.cwd))
                .any(|word| word.chars().any(char::is_control))
            && Path::new(&self.cwd).is_absolute()
    }
}

/// The launch folder beside a daemon's `socket`.
pub fn dir_beside(socket: &Path) -> PathBuf {
    socket.with_extension("resume")
}

/// Makes `dir` this user's alone, if it is not already: made `0700` when new, and an existing one
/// must be a real folder this user owns, which is then tightened to `0700`.
pub(crate) fn private_dir(dir: &Path) -> io::Result<()> {
    match std::fs::DirBuilder::new().mode(0o700).create(dir) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    }
    let meta = std::fs::symlink_metadata(dir)?;
    if !meta.is_dir() || meta.uid() != uid() {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    if meta.mode() & 0o077 != 0 {
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Whether `dir` is a real folder this user owns that no one else can enter.
fn is_private_dir(dir: &Path) -> bool {
    std::fs::symlink_metadata(dir)
        .is_ok_and(|meta| meta.is_dir() && meta.uid() == uid() && meta.mode() & 0o077 == 0)
}

fn uid() -> u32 {
    // SAFETY: no preconditions.
    unsafe { libc::geteuid() }
}

/// A new launch file's name for session `id`: `resume-<id>-<32 hex>.<extension>`.
fn launch_name(id: SessionId, extension: &str) -> io::Result<String> {
    let mut bytes = [0u8; 16];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes)
        .map_err(|_| io::Error::other("the system's randomness failed"))?;
    let nonce: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    Ok(format!("resume-{}-{nonce}.{extension}", id.to_hyphenated()))
}

/// Whether `name` is a launch file's (`launch_name`), for session `id` when one is given.
pub(crate) fn is_launch_name(name: &str, id: Option<SessionId>) -> bool {
    launch_session(name).is_some_and(|session| id.is_none_or(|id| id == session))
}

/// The session a launch file's `name` (`launch_name`) is for; `None` for any other name.
fn launch_session(name: &str) -> Option<SessionId> {
    let stem = name
        .strip_suffix(".json")
        .and_then(|stem| stem.strip_prefix("resume-"))?;
    let (session, nonce) = stem.rsplit_once('-')?;
    let hex = nonce.len() == 32
        && nonce
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
    // The id in its one written form, lowercase and hyphenated, as `launch_name` writes it.
    wr_protocol::terminal::parse_session_id(OsStr::new(session))
        .filter(|parsed| hex && parsed.to_hyphenated() == session)
}

/// Writes `contents` to a new file for session `id` in the private folder `dir`, readable by this
/// user alone from its first byte. Its path.
fn write_new(dir: &Path, id: SessionId, extension: &str, contents: &[u8]) -> io::Result<PathBuf> {
    let path = dir.join(launch_name(id, extension)?);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&path)?;
    if let Err(error) = file.write_all(contents) {
        drop(file);
        let _ = std::fs::remove_file(&path);
        return Err(error);
    }
    Ok(path)
}

/// Writes `launch` as session `id`'s launch file in `dir`, made private first: the app's file for
/// the relay (its tests write it here too), or the daemon's for its helper.
pub fn write_launch(dir: &Path, id: SessionId, launch: &Launch) -> io::Result<PathBuf> {
    private_dir(dir)?;
    write_new(dir, id, "json", &serde_json::to_vec(launch)?)
}

/// Claims the launch file at `path` for session `id`, once: it must have a launch file's name in a
/// private folder, and be a regular file this user owns, readable by no one else, with no other
/// link. Its contents; the file is gone either way once the claim was made.
pub(crate) fn claim(path: &Path, id: Option<SessionId>) -> io::Result<Vec<u8>> {
    let name = path
        .file_name()
        .and_then(OsStr::to_str)
        .filter(|name| is_launch_name(name, id))
        .ok_or(io::ErrorKind::InvalidInput)?;
    let dir = path.parent().ok_or(io::ErrorKind::InvalidInput)?;
    if !path.is_absolute() || !is_private_dir(dir) {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    // A link that fails when the name exists, then the unlink: of two claims, one makes the link.
    let claimed = dir.join(format!("{name}.claim"));
    std::fs::hard_link(path, &claimed)?;
    let _ = std::fs::remove_file(path);
    let read = || -> io::Result<Vec<u8>> {
        let meta = std::fs::symlink_metadata(&claimed)?;
        if !meta.is_file()
            || meta.uid() != uid()
            || meta.nlink() != 1
            || meta.mode() & 0o077 != 0
            || meta.len() > MAX_FILE
        {
            return Err(io::ErrorKind::PermissionDenied.into());
        }
        let file = std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&claimed)?;
        let mut bytes = Vec::new();
        file.take(MAX_FILE + 1).read_to_end(&mut bytes)?;
        Ok(bytes)
    };
    let bytes = read();
    let _ = std::fs::remove_file(&claimed);
    bytes
}

/// Claims and reads a launch file (`claim`).
pub fn claim_launch(path: &Path, id: Option<SessionId>) -> io::Result<Launch> {
    let launch: Launch = serde_json::from_slice(&claim(path, id)?)?;
    if !launch.is_well_formed() {
        return Err(io::ErrorKind::InvalidData.into());
    }
    Ok(launch)
}

/// Removes the launch files in `dir` (`is_launch_name`, claimed or not) older than `older_than`,
/// or every one with `None`, but never one of a session `live` says runs: its shell may still be
/// starting, however long that takes. Only regular files, judged without following a link.
pub(crate) fn sweep(dir: &Path, older_than: Option<Duration>, live: impl Fn(SessionId) -> bool) {
    if !is_private_dir(dir) {
        return;
    }
    let now = SystemTime::now();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(session) = launch_session(name.strip_suffix(".claim").unwrap_or(name)) else {
            continue;
        };
        if live(session) {
            continue;
        }
        let path = entry.path();
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        let old = older_than.is_none_or(|age| {
            meta.modified()
                .ok()
                .and_then(|at| now.duration_since(at).ok())
                .is_some_and(|elapsed| elapsed >= age)
        });
        if meta.is_file() && meta.uid() == uid() && old {
            let _ = std::fs::remove_file(&path);
        }
    }
}

/// A daemon starting fresh removes every launch file a daemon before it left (`sweep`).
pub fn sweep_at_start(socket: &Path) {
    sweep(&dir_beside(socket), None, |_| false);
}

/// What a resuming session starts with (`prepare`): its own shell, told of its launch file, and
/// that file's path, which the session removes should it not start (`discard`).
pub(crate) struct Prepared {
    pub invocation: Invocation,
    pub file: PathBuf,
}

/// How a session starts that resumes `launch`: its `invocation` (the session's own, finished,
/// which `hooked` says runs Workroom's hook, `bin_path::hooked`) told of a launch file written to
/// `dir` for session `id`, with `helper` the daemon's own binary; `live` says which sessions run,
/// whose files are left alone. An error, and nothing written, when it can't: the session then
/// starts as it would have.
pub(crate) fn prepare(
    invocation: &Invocation,
    hooked: bool,
    launch: &Launch,
    dir: &Path,
    id: SessionId,
    helper: &Path,
    live: impl Fn(SessionId) -> bool,
) -> io::Result<Prepared> {
    if !launch.is_well_formed() {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    if !hooked {
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            format!(
                "{} has no Workroom hook to run it from",
                shell_name(&invocation.program.to_string_lossy())
            ),
        ));
    }
    if !Path::new(&launch.cwd).is_dir() {
        return Err(io::ErrorKind::NotFound.into());
    }
    private_dir(dir)?;
    sweep(dir, Some(ABANDONED), live);
    let file = write_launch(dir, id, launch)?;
    let mut invocation = invocation.clone();
    let env = &mut invocation.environment;
    env.retain(|(key, _)| key != FILE_VARIABLE && key != HELPER_VARIABLE);
    env.push((OsString::from(FILE_VARIABLE), file.clone().into_os_string()));
    env.push((
        OsString::from(HELPER_VARIABLE),
        helper.as_os_str().to_os_string(),
    ));
    Ok(Prepared { invocation, file })
}

/// Removes the launch file `prepare` wrote at `file` for session `id`, when its session could not
/// be made: that one path, only while it still has a launch file's name for `id` in a private
/// folder and is a regular file this user owns. A helper that claimed it meanwhile has renamed it,
/// and removes it itself.
pub(crate) fn discard(file: &Path, id: SessionId) {
    let named = file
        .file_name()
        .and_then(OsStr::to_str)
        .is_some_and(|name| is_launch_name(name, Some(id)));
    let ours = named
        && file.parent().is_some_and(is_private_dir)
        && std::fs::symlink_metadata(file).is_ok_and(|meta| meta.is_file() && meta.uid() == uid());
    if ours {
        let _ = std::fs::remove_file(file);
    }
}

/// An OSC 7577 report from this process, signed with the session's token, for its pty: `fields`
/// after `pid` and `time`. `None` with no token, so nothing is reported.
fn report(fields: &str) -> Option<Vec<u8>> {
    let token = std::env::var(super::TOKEN_VARIABLE).ok()?;
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .ok()?
        .as_secs();
    let body = format!("pid={}:time={now}:{fields}", std::process::id());
    let mac = super::protocol::mac(body.as_bytes(), &token);
    Some(format!("\x1b]7577;{body}:mac={mac}\x07").into_bytes())
}

/// Writes `report` to this process's terminal, its stdout, and leaves it there.
fn send(report: Option<Vec<u8>>) {
    if let Some(report) = report {
        let mut stdout = io::stdout();
        let _ = stdout.write_all(&report);
        let _ = stdout.flush();
    }
}

/// The record `launch` reports, so its owner is this process and so the program it becomes.
fn set_report(launch: &Launch) -> Option<Vec<u8>> {
    let words: Vec<String> = launch
        .argv
        .iter()
        .map(|word| crate::util::base64(word.as_bytes()))
        .collect();
    report(&format!(
        "argv={}:cwd={}",
        words.join(","),
        crate::util::base64(launch.cwd.as_bytes())
    ))
}

/// Whether a program's exit `status` is a failure to resume: not 0, and not ^C (130), which is
/// the user stopping it, as a command result reads it.
pub(crate) fn failed(status: i32) -> bool {
    status != 0 && status != 130
}

/// `workroomd resume-launch <file>`: claims the launch file, goes to its folder and runs its
/// command as a child that reports the record as its own pid, waiting for it as the module says.
/// Its status is the command's, or 128 and its signal; 127 for a command it could not find, else
/// 126, when it could not start. Either way a failure is reported first.
pub fn run_launch(args: &[String]) -> std::process::ExitCode {
    let status = launch_and_wait(args);
    if failed(status) {
        send(report(&format!("clear=1:workroomexit={status}")));
    }
    std::process::ExitCode::from(u8::try_from(status).unwrap_or(u8::MAX))
}

/// `run_launch` up to its report: the status it ends with.
fn launch_and_wait(args: &[String]) -> i32 {
    let Some(file) = args.get(1) else {
        eprintln!("usage: workroomd resume-launch <file>");
        return 126;
    };
    let launch = match claim_launch(Path::new(file), None) {
        Ok(launch) => launch,
        Err(error) => {
            eprintln!("workroom: couldn't resume the program: {error}\r");
            return 126;
        }
    };
    let program = super::program_name(&launch.argv);
    let command = match command(&launch) {
        Ok(command) => command,
        Err(error) => {
            eprintln!("workroom: couldn't resume {program}: {error}\r");
            return if error.kind() == io::ErrorKind::NotFound {
                127
            } else {
                126
            };
        }
    };
    match run_child(&launch, &command) {
        Ok(status) => status,
        Err(error) => {
            eprintln!("workroom: couldn't resume {program}: {error}\r");
            126
        }
    }
}

/// The command `execv` runs, found and in C form, before the fork.
struct Command {
    path: std::ffi::CString,
    words: Vec<std::ffi::CString>,
}

/// The signals that are the program's, which the parent leaves to it: the job's ^C, ^\ and ^Z.
const PROGRAMS: [libc::c_int; 3] = [libc::SIGINT, libc::SIGQUIT, libc::SIGTSTP];

/// Forks: the child reports `launch` as its own pid and `execv`s `command`; this process waits for
/// it as the module says. The child's status, as a shell reads it.
fn run_child(launch: &Launch, command: &Command) -> io::Result<i32> {
    let mut pointers: Vec<*const libc::c_char> =
        command.words.iter().map(|word| word.as_ptr()).collect();
    pointers.push(std::ptr::null());
    let pwd = std::ffi::CString::new(launch.cwd.as_bytes())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    // SAFETY: plain libc calls on values that outlive them; the helper runs no threads, so the
    // child may allocate its report. The program's signals are blocked across the fork, so none
    // ends this process before it ignores them; the child gets the mask it had back, and ignores
    // none, before it `execv`s.
    unsafe {
        let mut programs: libc::sigset_t = std::mem::zeroed();
        let mut before: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut programs);
        for signal in PROGRAMS {
            libc::sigaddset(&mut programs, signal);
        }
        libc::sigprocmask(libc::SIG_BLOCK, &programs, &mut before);
        let child = libc::fork();
        if child == 0 {
            libc::sigprocmask(libc::SIG_SETMASK, &before, std::ptr::null_mut());
            // Its own pid, so the record's owner is the program, which keeps it.
            if let Some(set) = set_report(launch) {
                write_all_raw(&set);
            }
            libc::setenv(c"PWD".as_ptr(), pwd.as_ptr(), 1);
            libc::execv(command.path.as_ptr(), pointers.as_ptr());
            write_all_raw(b"workroom: couldn't start the program\r\n");
            libc::_exit(126);
        }
        if child < 0 {
            let error = io::Error::last_os_error();
            libc::sigprocmask(libc::SIG_SETMASK, &before, std::ptr::null_mut());
            return Err(error);
        }
        for signal in PROGRAMS {
            libc::signal(signal, libc::SIG_IGN);
        }
        libc::sigprocmask(libc::SIG_SETMASK, &before, std::ptr::null_mut());
        Ok(wait_for(child))
    }
}

/// Writes `bytes` to stdout with `write(2)` alone, as a forked child may.
fn write_all_raw(mut bytes: &[u8]) {
    while !bytes.is_empty() {
        // SAFETY: `bytes` is valid for its length.
        let written = unsafe { libc::write(1, bytes.as_ptr().cast(), bytes.len()) };
        if written <= 0 {
            if written < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return;
        }
        bytes = &bytes[written.unsigned_abs()..];
    }
}

/// Waits for `child` to end: when it stops, this process stops too, by the same signal, so the
/// shell sees its job stopped as it would the program, and continues it once the job is
/// continued. Its status as a shell reads it.
fn wait_for(child: libc::pid_t) -> i32 {
    loop {
        let mut status = 0;
        // SAFETY: `status` outlives the call.
        let waited = unsafe { libc::waitpid(child, &mut status, libc::WUNTRACED) };
        if waited < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return 126;
        }
        if libc::WIFSTOPPED(status) {
            let signal = libc::WSTOPSIG(status);
            let ignored = PROGRAMS.contains(&signal);
            // SAFETY: signals to this process and its own child, and this process's own handling
            // of the one that stopped it, ignored again once it is continued.
            unsafe {
                if ignored {
                    libc::signal(signal, libc::SIG_DFL);
                }
                libc::kill(libc::getpid(), signal);
                if ignored {
                    libc::signal(signal, libc::SIG_IGN);
                }
                libc::kill(child, libc::SIGCONT);
            }
        } else if libc::WIFEXITED(status) {
            return libc::WEXITSTATUS(status);
        } else if libc::WIFSIGNALED(status) {
            return 128 + libc::WTERMSIG(status);
        }
    }
}

/// Goes to `launch`'s folder and finds its command, its first word looked up on PATH when it is a
/// bare name.
fn command(launch: &Launch) -> io::Result<Command> {
    std::env::set_current_dir(&launch.cwd)?;
    let executable = |path: &Path| -> Option<std::ffi::CString> {
        if !path.is_file() {
            return None;
        }
        let path = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
        // SAFETY: `path` is a NUL-terminated string that outlives the call.
        (unsafe { libc::access(path.as_ptr(), libc::X_OK) } == 0).then_some(path)
    };
    let name = Path::new(&launch.argv[0]);
    let found = if name.is_absolute() {
        executable(name)
    } else {
        std::env::var_os("PATH").and_then(|path| {
            std::env::split_paths(&path)
                .filter(|dir| dir.is_absolute())
                .find_map(|dir| executable(&dir.join(name)))
        })
    };
    let path = found.ok_or(io::ErrorKind::NotFound)?;
    let words = launch
        .argv
        .iter()
        .map(|word| std::ffi::CString::new(word.as_bytes()))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))?;
    Ok(Command { path, words })
}

#[cfg(test)]
mod tests;
