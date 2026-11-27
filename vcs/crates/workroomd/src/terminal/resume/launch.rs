//! Resuming a program in a pane's new session (ADR 0082, #825): the files that carry a resume
//! record from the app to the relay and from the daemon to its helper, the login shell that runs
//! the helper, and the helper itself (`workroomd resume-launch`, `workroomd resume-shell`).
//!
//! **How a record is run.** The daemon starts the session's login shell, interactive, with a
//! script (`wrapper`) that runs `workroomd resume-launch <launch file>` and then `exec`s
//! `workroomd resume-shell <status> <shell file> <shell>`. The first claims the launch file,
//! goes to the record's folder, reports the record over OSC 7577 as its own pid (so the record's
//! owner is the process that runs the program, which keeps that pid), and `execv`s the command
//! literally, never through a shell: so the startup files' PATH applies and no word is split or
//! expanded. The second claims the shell file and becomes the session's shell as an ordinary
//! session would have it (`shell::invocation`, `bin_path::apply`): a login shell with Ghostty's
//! integration, which the wrapper's own startup consumed. Quitting the program, or its failing to
//! start, so leaves a shell prompt in its folder. When the program ended with an error, the second
//! says so first, as an OSC 7577 report with `workroomexit`, which the daemon turns into the
//! status event's `resumeFailed` when it came within `FAILED_WITHIN` of the session starting.
//!
//! **Why files.** A command's arguments can hold secrets, and a process's arguments and
//! environment show in process listings. So the command goes from the app to the relay, and from
//! the daemon to its helper, in a file only this user can read (`0600` in a `0700` folder), which
//! its reader claims once and removes (`claim`).
//!
//! **Whose files these are.** A launch folder is made by this code alone, `0700`, beside the
//! daemon's socket (`dir_beside`) or in the app's own support folder, and a file in it is this
//! code's when its name is `resume-<session id>-<32 hex>.json` or `.shell` (`is_launch_name`),
//! with `.claim` after it once claimed. Nothing else writes such a name there. A file left
//! behind (its pane closed before its shell got as far as the helper) is removed by the daemon
//! at a fresh start, when no session it made can still be waiting for one, and an hour after it
//! was written at any later launch: never one a helper could still be about to claim. Only regular
//! files are removed, judged by `symlink_metadata`, so a link or a FIFO with such a name is left.
//!
//! The claim, the literal `execv` and the wrapper script are ported from herdr-core
//! (herdrdev/herdr-core#429, `crates/herdr-core/src/resume/launch.rs` and
//! `crates/herdr-core/src/platform/unix_resume.rs` at `0cb50d57832f3ebb69157ce7f023fbbc520181a8`),
//! Licensed under the Apache License, Version 2.0 (`LICENSE` beside this file). Changed from the
//! original for Workroom: the claim is a hard link and an unlink, which refuses to replace on
//! every Unix this runs on, rather than `renameat2`; a file's name carries its session's id; the
//! shell left behind is the session's own invocation from a second file, not `exec "$0" -li`;
//! the helper reports the record as its own pid before it `execv`s; a failed program's status is
//! reported; there is no `first` mode, since a session's first process is always its shell; and
//! shells outside the sh family and fish run the wrapper in `/bin/sh`.

use std::ffi::{OsStr, OsString};
use std::io::{self, Read, Write};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};

use crate::terminal::session::SessionId;
use crate::terminal::shell::{Invocation, shell_name};

/// The variable the app names its launch file in, for the relay (`WORKROOM_SESSION_RESUME`).
pub const APP_FILE_VARIABLE: &str = "WORKROOM_SESSION_RESUME";

/// How soon after its session starts a resumed program that exits with an error says it could not
/// be resumed (ADR 0082): longer than a login shell's startup, shorter than a session anyone used.
pub(crate) const FAILED_WITHIN: Duration = Duration::from_secs(5);

/// The most a launch file may hold: a record is at most 8 KiB, and a shell file an environment.
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
                && matches!(path.components().next(), Some(std::path::Component::Normal(_))));
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

/// What `resume-shell` becomes: the session's shell as an ordinary session would start it.
#[derive(Serialize, Deserialize)]
struct Shell {
    program: Vec<u8>,
    arguments: Vec<Vec<u8>>,
    environment: Vec<(Vec<u8>, Vec<u8>)>,
    cwd: Vec<u8>,
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
    let Some(stem) = name
        .strip_suffix(".json")
        .or_else(|| name.strip_suffix(".shell"))
        .and_then(|stem| stem.strip_prefix("resume-"))
    else {
        return false;
    };
    let Some((session, nonce)) = stem.rsplit_once('-') else {
        return false;
    };
    // The id in its one written form, lowercase and hyphenated, as `launch_name` writes it.
    let parsed = wr_protocol::terminal::parse_session_id(OsStr::new(session))
        .filter(|parsed| parsed.to_hyphenated() == session);
    parsed.is_some_and(|parsed| id.is_none_or(|id| id == parsed))
        && nonce.len() == 32
        && nonce.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
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
/// or every one with `None`. Only regular files, judged without following a link.
pub(crate) fn sweep(dir: &Path, older_than: Option<Duration>) {
    if !is_private_dir(dir) {
        return;
    }
    let now = SystemTime::now();
    for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !is_launch_name(name.strip_suffix(".claim").unwrap_or(name), None) {
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
    sweep(&dir_beside(socket), None);
}

/// How a session starts that resumes `launch`: its `invocation` (the session's own, finished)
/// becomes the wrapper login shell, whose files are written to `dir` for session `id`, with
/// `helper` the daemon's own binary. `None`, and nothing written, when it can't: the session then
/// starts as it would have.
pub(crate) fn prepare(
    invocation: &Invocation,
    launch: &Launch,
    dir: &Path,
    id: SessionId,
    helper: &Path,
) -> io::Result<Invocation> {
    if !launch.is_well_formed() {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    if !Path::new(&launch.cwd).is_dir() {
        return Err(io::ErrorKind::NotFound.into());
    }
    private_dir(dir)?;
    sweep(dir, Some(ABANDONED));
    let shell = Shell {
        program: invocation.program.as_bytes().to_vec(),
        arguments: invocation
            .arguments
            .iter()
            .map(|a| a.as_bytes().to_vec())
            .collect(),
        environment: invocation
            .environment
            .iter()
            .map(|(k, v)| (k.as_bytes().to_vec(), v.as_bytes().to_vec()))
            .collect(),
        cwd: launch.cwd.as_bytes().to_vec(),
    };
    let launch_file = write_launch(dir, id, launch)?;
    let shell_file = match write_new(dir, id, "shell", &serde_json::to_vec(&shell)?) {
        Ok(path) => path,
        Err(error) => {
            let _ = std::fs::remove_file(&launch_file);
            return Err(error);
        }
    };
    Ok(wrapper(invocation, helper, &launch_file, &shell_file))
}

/// The sh family's wrapper script: `$0` the session's shell, `$1` the helper, `$2` the launch
/// file, `$3` the shell file. Only positional parameters, so no path is ever parsed as script.
const SH_SCRIPT: &str = r#""$1" resume-launch "$2"; exec "$1" resume-shell "$?" "$3" "$0""#;
/// fish's: `$argv[1]` the helper, `$argv[2]` the launch file, `$argv[3]` the shell file,
/// `$argv[4]` the session's shell.
const FISH_SCRIPT: &str = r#""$argv[1]" resume-launch "$argv[2]"; exec "$argv[1]" resume-shell $status "$argv[3]" "$argv[4]""#;

/// The wrapper login shell (module doc) for a session whose own shell is `invocation`, with its
/// environment: the session's shell itself for the sh family and fish, so its startup files give
/// the program their PATH; `/bin/sh` for any other, which can't run the script.
fn wrapper(invocation: &Invocation, helper: &Path, launch: &Path, shell: &Path) -> Invocation {
    let program = invocation.program.clone();
    let name = shell_name(&program.to_string_lossy()).to_string();
    let text = |path: &Path| path.as_os_str().to_os_string();
    let arguments = match name.as_str() {
        "zsh" | "bash" | "sh" | "dash" | "ksh" | "mksh" => {
            let mut arguments = invocation.arguments.clone();
            arguments.extend([
                OsString::from("-ic"),
                OsString::from(SH_SCRIPT),
                program.clone(),
                text(helper),
                text(launch),
                text(shell),
            ]);
            arguments
        }
        "fish" => vec![
            invocation
                .arguments
                .first()
                .cloned()
                .unwrap_or_else(|| OsString::from("-fish")),
            OsString::from("-i"),
            OsString::from("-c"),
            OsString::from(FISH_SCRIPT),
            text(helper),
            text(launch),
            text(shell),
            program.clone(),
        ],
        _ => {
            return Invocation {
                program: OsString::from(crate::terminal::shell::POSIX_SHELL),
                arguments: vec![
                    OsString::from("-sh"),
                    OsString::from("-ic"),
                    OsString::from(SH_SCRIPT),
                    program,
                    text(helper),
                    text(launch),
                    text(shell),
                ],
                environment: invocation.environment.clone(),
                interactive: true,
            };
        }
    };
    Invocation {
        program,
        arguments,
        environment: invocation.environment.clone(),
        interactive: true,
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

/// `workroomd resume-launch <file>`: claims the launch file, goes to its folder, reports its record
/// as this process, and becomes its command. Returns only when it could not, with the status the
/// wrapper passes on: 127 for a command it could not find, else 126.
pub fn run_launch(args: &[String]) -> std::process::ExitCode {
    let Some(file) = args.get(1) else {
        eprintln!("usage: workroomd resume-launch <file>");
        return std::process::ExitCode::from(126);
    };
    let launch = match claim_launch(Path::new(file), None) {
        Ok(launch) => launch,
        Err(error) => {
            eprintln!("workroom: couldn't resume the program: {error}\r");
            return std::process::ExitCode::from(126);
        }
    };
    let program = super::program_name(&launch.argv);
    let error = become_command(&launch);
    eprintln!("workroom: couldn't resume {program}: {error}\r");
    std::process::ExitCode::from(if error.kind() == io::ErrorKind::NotFound {
        127
    } else {
        126
    })
}

/// Goes to `launch`'s folder and `execv`s its command, its first word looked up on PATH when it is
/// a bare name. Returns only the reason it could not.
fn become_command(launch: &Launch) -> io::Error {
    if let Err(error) = std::env::set_current_dir(&launch.cwd) {
        return error;
    }
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
    let Some(path) = found else {
        return io::ErrorKind::NotFound.into();
    };
    let Ok(words) = launch
        .argv
        .iter()
        .map(|word| std::ffi::CString::new(word.as_bytes()))
        .collect::<Result<Vec<_>, _>>()
    else {
        return io::ErrorKind::InvalidInput.into();
    };
    let mut pointers: Vec<*const libc::c_char> = words.iter().map(|word| word.as_ptr()).collect();
    pointers.push(std::ptr::null());
    send(set_report(launch));
    // SAFETY: the helper runs no threads, so changing the environment races nothing; `path` and
    // every word outlive the call, and `pointers` ends in NULL.
    unsafe {
        std::env::set_var("PWD", &launch.cwd);
        libc::execv(path.as_ptr(), pointers.as_ptr());
    }
    io::Error::last_os_error()
}

/// `workroomd resume-shell <status> <file> <shell>`: says a program that ended with an error
/// failed to resume, then becomes the session's shell from the shell file, or a login `<shell>`
/// when the file can't be claimed. Returns only when neither could start.
pub fn run_shell(args: &[String]) -> std::process::ExitCode {
    use std::os::unix::process::CommandExt;
    let status: i32 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);
    if failed(status) {
        send(report(&format!("clear=1:workroomexit={status}")));
    }
    let file = args.get(2).map(PathBuf::from);
    let shell = file
        .as_deref()
        .and_then(|file| claim(file, None).ok())
        .and_then(|bytes| serde_json::from_slice::<Shell>(&bytes).ok());
    let error = match shell {
        Some(shell) => {
            let cwd = OsString::from_vec(shell.cwd);
            // The folder as the record names it, not its physical path, as the program had it.
            let here = std::env::set_current_dir(&cwd).is_ok();
            let mut command = std::process::Command::new(OsString::from_vec(shell.program));
            let mut arguments = shell.arguments.into_iter().map(OsString::from_vec);
            if let Some(argv0) = arguments.next() {
                command.arg0(argv0);
            }
            command.args(arguments);
            command.env_clear();
            command.envs(
                shell
                    .environment
                    .into_iter()
                    .map(|(k, v)| (OsString::from_vec(k), OsString::from_vec(v))),
            );
            if here {
                command.env("PWD", &cwd);
            }
            command.exec()
        }
        None => {
            let program = args
                .get(3)
                .filter(|shell| shell.starts_with('/'))
                .cloned()
                .unwrap_or_else(|| crate::terminal::shell::DEFAULT_SHELL.to_string());
            let argv0 = format!("-{}", shell_name(&program));
            std::process::Command::new(&program).arg0(argv0).exec()
        }
    };
    eprintln!("workroom: couldn't start this terminal's shell: {error}\r");
    std::process::ExitCode::from(126)
}

#[cfg(test)]
mod tests;
