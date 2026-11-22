//! The daemon's own copy of its binary (#681), which every program it starts from itself runs:
//! each run session's `run-supervisor` (`terminal::dispatch`).
//!
//! **Why a copy.** The file a daemon was started from is not the daemon's to keep. An update
//! replaces or removes it: the swap (ADR 0078) took `Contents/MacOS/workroomd` away and left a
//! daemon an older app started running from a path that no longer exists, and a downgrade puts the
//! Go CLI back at `Contents/Resources/workroom`, which is no daemon at all. A daemon that started
//! its children from that path could start no run session after either. So at start each daemon
//! copies its own binary beside its socket, `<socket>.bin/workroom-<daemon build>`, and starts its
//! children from the copy. Keyed by the daemon build (#680) because that is what decides how a
//! child behaves: two binaries of one daemon build differ only in CLI commands, which a child of
//! the daemon never runs. A pane does run them, through the `workroom` link in the daemon's bin
//! folder (`bin_dir`, #695), which points at the copy; so a copy of this daemon build whose bytes
//! are not this binary's is made again, and the link runs the commands of the binary the daemon
//! runs.
//!
//! The bin folder lives in this folder too, as `path/`, beside `shell/`, its shells' hooks. The
//! sweep below takes only copies and staged copies, so it leaves both alone.
//!
//! **Whose files these are.** Only this code makes the folder, exclusively, and writes `OWNER` in
//! it when it does; a folder without that marker is someone else's, and nothing in it is used or
//! removed. In a folder of ours, a copy is a regular file named `workroom-<hex>` whose own daemon
//! build marker is that hex, which only a daemon binary carries. A daemon holds a shared lock on
//! the copy it runs from for as long as it runs, so another build's copy is removed only once no
//! daemon holds it (an exclusive lock taken without waiting), and only when the name still names
//! the file that was locked. A staged copy (`.workroom-<hex>.<pid>`) is removed only once the
//! process that staged it is gone. Anything else in the folder stays.
//!
//! A copy that cannot be made costs nothing the daemon had before: its children start from its own
//! file, as they always did, and the log says why.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use crate::daemon::handoff;

/// The marker file only this code writes, in a folder only it made.
const OWNER: &str = "OWNER";
const OWNER_TEXT: &str = "the Workroom daemon's copies of its own binary (own_copy.rs)\n";
/// A copy's name is this and its daemon build.
const PREFIX: &str = "workroom-";

struct Kept {
    path: PathBuf,
    /// The shared lock that tells a sweep this copy is in use. Close-on-exec: a hand-off's next
    /// program takes its own.
    _lock: File,
}

static KEPT: OnceLock<Kept> = OnceLock::new();

/// Where a socket's daemon keeps its copies: beside the socket, in the daemon's own folder.
pub fn dir_beside(socket: &Path) -> PathBuf {
    socket.with_extension("bin")
}

/// Makes this daemon build's copy in `dir`, or finds it there, holds it, and removes other builds'
/// copies no daemon holds. Once, at start, on a thread of its own: a copy is tens of MB, and a
/// daemon a hand-off just started must not keep its clients waiting for it. Until it is there,
/// children start from this program's own file, which it was started from a moment ago.
pub fn keep(dir: &Path) {
    let dir = dir.to_path_buf();
    let source = source();
    let _ = std::thread::Builder::new()
        .name("own-copy".into())
        .spawn(move || keep_now(&dir, &source));
}

fn keep_now(dir: &Path, source: &Path) {
    let build = handoff::daemon_build();
    match establish(dir, source, build) {
        Ok(kept) => {
            let name = file_name(build);
            let path = kept.path.clone();
            let _ = KEPT.set(kept);
            crate::note!("starting run sessions from {}", path.display());
            // Before the sweep, which removes the copy the link may still point at: the last
            // daemon's, after a hand-off to another daemon build.
            crate::daemon::bin_dir::point(&path);
            sweep(dir, &name);
        }
        Err(e) => crate::note!(
            "not keeping a copy of this binary in {}: {e}; run sessions start from its own file",
            dir.display()
        ),
    }
}

/// The binary this daemon starts its own children from: its copy, or its own file without one.
pub fn binary() -> io::Result<PathBuf> {
    pick(
        KEPT.get().map(|kept| kept.path.as_path()),
        handoff::own_binary,
    )
}

/// This daemon's copy, while it is still there.
pub(crate) fn kept() -> Option<&'static Path> {
    KEPT.get()
        .map(|kept| kept.path.as_path())
        .filter(|path| fs::symlink_metadata(path).is_ok_and(|meta| meta.is_file()))
}

/// The copy while it is still there, else `own`: a copy can go from under a daemon, as macOS's
/// cleaner deletes a `/tmp` fallback's files nobody touched for three days (#528).
fn pick(kept: Option<&Path>, own: impl FnOnce() -> io::Result<PathBuf>) -> io::Result<PathBuf> {
    match kept {
        Some(path) if fs::symlink_metadata(path).is_ok_and(|meta| meta.is_file()) => {
            Ok(path.to_path_buf())
        }
        _ => own(),
    }
}

/// The file this program runs. On Linux `/proc/self/exe`, which reads it even once its path is
/// gone; elsewhere its path, which at start is still there.
fn source() -> PathBuf {
    if cfg!(target_os = "linux") {
        PathBuf::from("/proc/self/exe")
    } else {
        std::env::current_exe().unwrap_or_default()
    }
}

fn file_name(build: &str) -> String {
    format!("{PREFIX}{build}")
}

/// The copy of `source`, daemon build `build`, in `dir`, locked shared.
fn establish(dir: &Path, source: &Path, build: &str) -> io::Result<Kept> {
    if build.is_empty() || !build.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(io::Error::other("this build has no daemon build identity"));
    }
    own_folder(dir)?;
    let path = dir.join(file_name(build));
    // A copy made in the instant between this one's check and its lock can replace it; a second
    // look is enough, a third means something else is at work.
    for _ in 0..3 {
        // A copy of this daemon build from a binary whose CLI commands alone differ is made again:
        // the `workroom` link every pane runs points at it (`bin_dir`).
        if is_copy(&path, build)? && !differs(&path, source) {
            let file = File::open(&path)?;
            // Waits out a sweep's exclusive lock, which it holds only to remove the file; the
            // name is then checked to still be this file.
            if !lock(&file, libc::LOCK_SH) {
                return Err(io::Error::last_os_error());
            }
            if same_file(&file, &path) {
                return Ok(Kept { path, _lock: file });
            }
            continue;
        }
        stage(dir, source, build, &path)?;
    }
    Err(io::Error::other(format!(
        "{} kept changing while it was made",
        path.display()
    )))
}

/// Makes `dir` this code's own, or checks that it is: made exclusively with `OWNER` written in it
/// at once, or found with that marker.
pub(crate) fn own_folder(dir: &Path) -> io::Result<()> {
    match fs::DirBuilder::new().mode(0o700).create(dir) {
        Ok(()) => {
            let mut marker = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(dir.join(OWNER))?;
            io::Write::write_all(&mut marker, OWNER_TEXT.as_bytes())
        }
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
            if marked(dir) {
                Ok(())
            } else {
                Err(io::Error::other(format!(
                    "{} is not a folder this daemon made",
                    dir.display()
                )))
            }
        }
        Err(e) => Err(e),
    }
}

/// Whether `dir` is a real folder holding the marker only `own_folder` writes.
pub(crate) fn marked(dir: &Path) -> bool {
    fs::symlink_metadata(dir).is_ok_and(|meta| meta.is_dir())
        && fs::symlink_metadata(dir.join(OWNER)).is_ok_and(|meta| meta.is_file())
        && fs::read_to_string(dir.join(OWNER)).is_ok_and(|text| text == OWNER_TEXT)
}

/// Whether `path` is a copy of daemon build `build`: a regular file carrying that build's marker.
fn is_copy(path: &Path, build: &str) -> io::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.is_file() => Ok(handoff::daemon_build_in(path)?.as_deref() == Some(build)),
        Ok(_) => Err(io::Error::other(format!(
            "{} is not a regular file",
            path.display()
        ))),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

/// Whether `source` can be read and its bytes are not `copy`'s. A source that is gone (an update
/// took it away) differs from nothing: the copy is what this daemon has left.
fn differs(copy: &Path, source: &Path) -> bool {
    let (Ok(theirs), Ok(ours)) = (File::open(source), File::open(copy)) else {
        return false;
    };
    match (theirs.metadata(), ours.metadata()) {
        (Ok(a), Ok(b)) if a.len() != b.len() => return true,
        (Ok(_), Ok(_)) => {}
        _ => return false,
    }
    let mut theirs = io::BufReader::with_capacity(1 << 16, theirs);
    let mut ours = io::BufReader::with_capacity(1 << 16, ours);
    loop {
        let (Ok(a), Ok(b)) = (
            io::BufRead::fill_buf(&mut theirs),
            io::BufRead::fill_buf(&mut ours),
        ) else {
            return false;
        };
        if a.is_empty() || b.is_empty() {
            return a.len() != b.len();
        }
        let n = a.len().min(b.len());
        if a[..n] != b[..n] {
            return true;
        }
        io::BufRead::consume(&mut theirs, n);
        io::BufRead::consume(&mut ours, n);
    }
}

/// Copies `source` to `path` through a file of this process's own, checked to be daemon build
/// `build` before it is renamed into place.
fn stage(dir: &Path, source: &Path, build: &str, path: &Path) -> io::Result<()> {
    let staged = dir.join(format!(".{}.{}", file_name(build), std::process::id()));
    // One already there under this pid is this process's own, left when a hand-off's exec ended
    // the thread making it (the pid outlives the exec), or a dead process's whose pid this one
    // reuses: no other live process has this pid.
    let _ = fs::remove_file(&staged);
    let mut out = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o700)
        .open(&staged)?;
    let written = File::open(source)
        .and_then(|mut input| io::copy(&mut input, &mut out))
        .and_then(|_| out.sync_all())
        .and_then(|()| match handoff::daemon_build_in(&staged)? {
            Some(found) if found == build => Ok(()),
            _ => Err(io::Error::other(format!(
                "{} is not this daemon build",
                source.display()
            ))),
        })
        .and_then(|()| fs::rename(&staged, path));
    if written.is_err() {
        // This process made it (`create_new`), so it is this process's to remove.
        let _ = fs::remove_file(&staged);
    }
    written
}

/// Removes, from a folder of ours, every other build's copy no daemon holds, and every staged copy
/// whose process is gone. `keep` is this daemon's own copy's name.
fn sweep(dir: &Path, keep: &str) {
    if !marked(dir) {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let path = entry.path();
        if name == keep {
            continue;
        }
        if let Some(build) = name.strip_prefix(PREFIX) {
            if remove_unheld_copy(&path, build) {
                crate::note!("removed {}, which no daemon runs from", path.display());
            }
        } else if let Some((build, pid)) = name
            .strip_prefix('.')
            .and_then(|rest| rest.strip_prefix(PREFIX))
            .and_then(|rest| rest.rsplit_once('.'))
            && build.bytes().all(|b| b.is_ascii_hexdigit())
            && let Ok(pid) = pid.parse::<i32>()
            && pid > 0
            && pid != std::process::id() as i32
            && gone(pid)
            && fs::symlink_metadata(&path).is_ok_and(|meta| meta.is_file())
        {
            let _ = fs::remove_file(&path);
        }
    }
}

/// Removes the copy at `path` when it is one (`is_copy`) and no daemon holds it, judged under an
/// exclusive lock taken without waiting, on the file the name still names.
fn remove_unheld_copy(path: &Path, build: &str) -> bool {
    if build.is_empty() || !build.bytes().all(|b| b.is_ascii_hexdigit()) {
        return false;
    }
    if !is_copy(path, build).unwrap_or(false) {
        return false;
    }
    let Ok(file) = File::open(path) else {
        return false;
    };
    if !lock(&file, libc::LOCK_EX | libc::LOCK_NB) || !same_file(&file, path) {
        return false;
    }
    fs::remove_file(path).is_ok()
}

fn lock(file: &File, operation: libc::c_int) -> bool {
    // SAFETY: the descriptor belongs to `file`, open for the call; flock takes integers.
    unsafe { libc::flock(file.as_raw_fd(), operation) == 0 }
}

/// Whether `path` still names the file `file` has open.
fn same_file(file: &File, path: &Path) -> bool {
    match (file.metadata(), fs::symlink_metadata(path)) {
        (Ok(open), Ok(named)) => open.dev() == named.dev() && open.ino() == named.ino(),
        _ => false,
    }
}

/// Whether no process has `pid`: `kill(pid, 0)` says there is none. A pid taken again since keeps
/// its staged file, which only costs the space.
pub(crate) fn gone(pid: i32) -> bool {
    // SAFETY: `kill` takes no pointers, and signal 0 delivers nothing.
    unsafe {
        libc::kill(pid, 0) != 0 && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
    }
}

#[cfg(test)]
mod tests;
