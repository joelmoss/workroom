//! A clone's staging folder, its lock, and the sweep of what a dead clone left: Go's ownership
//! proof (`internal/workroom/clone_project.go`, `staging_lock_unix.go`), rule for rule.
//!
//! A clone runs in a staging folder of its own, `.clone-<host>-<pid>-<random>` inside an existing
//! destination or `.<name>.clone-<host>-<pid>-<random>` beside a missing one, with a lock file at
//! the same name plus `.lock` that it holds with `flock(2)` for as long as it runs. git and every
//! helper it starts inherit that lock, so it stays held while any of them runs, even after the
//! CLI itself is SIGKILLed.
//!
//! A later clone into the same place sweeps only what it can prove is a dead clone's, made on
//! this machine:
//!
//! - the name carries this machine's host (an 8-hex FNV-32a of its hardware id, read and never
//!   stored) and a positive pid; with no machine id nothing is swept at all, since this machine's
//!   staging can't then be told from another's on a shared volume;
//! - a real folder (never a symlink) whose lock file is free is dead, whatever its pid; one whose
//!   lock is held is alive, whatever its pid; with no lock file to ask (an earlier build's staging,
//!   or a filesystem without `flock`), it is dead only once its pid is gone;
//! - a lock file whose folder is gone is dead once free;
//! - a name without an owner, another machine's, or anything else of that shape, is never
//!   touched: the refusal names it for the user instead.
//!
//! Each dead lock is held by the sweep while it removes its staging, so the dead run's name can't
//! be reused under it, and the folder is checked once more to be a real folder before it goes. A
//! FIFO planted at a lock path can't hang the probe: it is opened without blocking, and judged
//! held.

use std::ffi::OsStr;
use std::fs::File;
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use super::super::config::os_error;
use super::super::kind::CliError;
use super::{FINDER_JUNK, cancelled};

/// This machine's part of a staging name: an 8-hex hash of its hardware id, read once. None when
/// the machine has no id, which sweeps nothing.
pub(super) fn machine_host() -> Option<&'static str> {
    static HOST: OnceLock<Option<String>> = OnceLock::new();
    HOST.get_or_init(|| machine_id().map(|id| fnv_hex(&id)))
        .as_deref()
}

/// The owner part of this process's staging names: `<host>-<pid>-`, the host being the hostname's
/// hash when there is no machine id (nothing is ever swept by that).
pub(super) fn staging_owner() -> String {
    let host = machine_host().map_or_else(|| fnv_hex(&hostname()), str::to_string);
    format!("{host}-{}-", std::process::id())
}

/// `text` as 8 hex digits: its FNV-32a hash.
pub(super) fn fnv_hex(text: &str) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for byte in text.bytes() {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    format!("{hash:08x}")
}

fn hostname() -> String {
    let mut buffer = [0u8; 256];
    // SAFETY: the buffer is valid for its length, and gethostname writes at most that.
    let result = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
    if result != 0 {
        return "unknown".to_string();
    }
    let end = buffer.iter().position(|&b| b == 0).unwrap_or(buffer.len());
    String::from_utf8_lossy(&buffer[..end]).into_owned()
}

/// The Mac's IOPlatformUUID, the hardware id ioreg reports, which survives renaming the Mac,
/// reinstalling macOS and any network's view of its hostname.
#[cfg(target_os = "macos")]
fn machine_id() -> Option<String> {
    use std::io::Read;
    use std::process::{Command, Stdio};
    use std::time::Instant;
    let mut child = Command::new("/usr/sbin/ioreg")
        .args(["-rd1", "-c", "IOPlatformExpertDevice"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut out = Vec::new();
        let _ = stdout.read_to_end(&mut out);
        out
    });
    // Go's five-second context: a wedged ioreg is killed, and counts as no id.
    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(10)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    };
    let out = reader.join().ok()?;
    if !status.success() {
        return None;
    }
    let id = parse_ioplatform_uuid(&String::from_utf8_lossy(&out));
    (!id.is_empty()).then_some(id)
}

/// The machine id systemd keeps in /etc/machine-id, or D-Bus's copy where there is no systemd:
/// made once per install and unchanged by renaming the machine.
#[cfg(not(target_os = "macos"))]
fn machine_id() -> Option<String> {
    ["/etc/machine-id", "/var/lib/dbus/machine-id"]
        .iter()
        .filter_map(|path| std::fs::read(path).ok())
        .map(|bytes| parse_machine_id_file(&String::from_utf8_lossy(&bytes)))
        .find(|id| !id.is_empty())
}

/// The IOPlatformUUID out of `ioreg -rd1 -c IOPlatformExpertDevice`, whose line for it is
/// `"IOPlatformUUID" = "<uuid>"`; "" when it is missing or empty.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(super) fn parse_ioplatform_uuid(output: &str) -> String {
    for line in output.lines() {
        let Some((key, value)) = line.trim().split_once('=') else {
            continue;
        };
        if key.trim() != "\"IOPlatformUUID\"" {
            continue;
        }
        return value.trim().trim_matches('"').to_string();
    }
    String::new()
}

/// A systemd or D-Bus machine-id file's id; "" when it is blank or still holds the
/// "uninitialized" placeholder systemd writes before first boot completes, which every such
/// machine would share.
#[cfg_attr(target_os = "macos", allow(dead_code))]
pub(super) fn parse_machine_id_file(content: &str) -> String {
    let id = content.trim();
    if id == "uninitialized" {
        String::new()
    } else {
        id.to_string()
    }
}

/// Why [`create_lock`] made no lock.
pub(super) enum LockError {
    /// The name is taken: try another.
    Exists,
    /// A sweep took the fresh file before it was locked: try another name.
    Lost,
    /// The filesystem has no `flock`; the file was removed again, so no unlocked lock file sits
    /// beside live staging for a sweep to take for a dead clone's.
    Unsupported,
    /// Anything else, worded as Go's `PathError`.
    Failed(String),
}

/// Makes and locks a new lock file at `path`.
pub(super) fn create_lock(path: &Path) -> Result<File, LockError> {
    let file = match std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            return Err(LockError::Exists);
        }
        Err(error) => {
            return Err(LockError::Failed(format!(
                "open {}: {}",
                path.display(),
                os_error(&error)
            )));
        }
    };
    if let Err(error) = flock_exclusive(&file) {
        drop(file);
        // The file is this run's (O_EXCL), and left behind it would block the folder this run is
        // about to clone into.
        let _ = std::fs::remove_file(path);
        if error.raw_os_error() == Some(libc::EWOULDBLOCK) {
            // A sweep or a --pretend probe has it.
            return Err(LockError::Lost);
        }
        return Err(LockError::Unsupported);
    }
    if !same_file_at(&file, path) {
        // A sweep removed it between the create and the lock.
        return Err(LockError::Lost);
    }
    Ok(file)
}

/// Removes a staging folder's lock file, then closes it. It never unlocks: `LOCK_UN` would
/// release git's inherited hold too, where closing drops only this process's.
pub(super) fn release_lock(lock: Option<File>, stage: &Path) {
    if let Some(lock) = lock {
        let _ = std::fs::remove_file(lock_path(stage));
        drop(lock);
    }
}

/// `stage` with `.lock` after its name.
pub(super) fn lock_path(stage: &Path) -> PathBuf {
    let mut path = stage.as_os_str().to_owned();
    path.push(".lock");
    PathBuf::from(path)
}

fn flock_exclusive(file: &File) -> io::Result<()> {
    // SAFETY: a valid descriptor this owns.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// Whether `file` is still the file at `path`.
fn same_file_at(file: &File, path: &Path) -> bool {
    match (file.metadata(), std::fs::symlink_metadata(path)) {
        (Ok(open), Ok(named)) => open.dev() == named.dev() && open.ino() == named.ino(),
        _ => false,
    }
}

/// What a staging lock file says about its clone.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum LockState {
    /// Its clone, or a git it started, is running.
    Held,
    /// Nothing holds it: its clone is dead. The file comes with it, locked by this process.
    Free,
    /// There is no lock file.
    Missing,
    /// The filesystem can't say.
    Unsupported,
}

/// Tries a staging lock file's lock without waiting. `O_NONBLOCK`, so a FIFO planted at the path
/// can't block the open until a writer comes; `O_RDWR` though nothing is written, since on NFS
/// Linux turns flock into a byte-range lock, which needs a descriptor open for writing; no
/// `O_CREAT` or `O_TRUNC`, so `--pretend` still changes nothing. Anything it can't settle is
/// [`LockState::Held`], which keeps the staging.
pub(super) fn probe_lock(path: &Path) -> (Option<File>, LockState) {
    let file = match std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return (None, LockState::Missing),
        Err(_) => return (None, LockState::Held),
    };
    if !file.metadata().is_ok_and(|info| info.file_type().is_file()) {
        return (None, LockState::Held);
    }
    match flock_exclusive(&file) {
        Ok(()) if same_file_at(&file, path) => (Some(file), LockState::Free),
        // ENOTSUP and EOPNOTSUPP are one value on Linux, two on the Mac.
        Err(error)
            if error.raw_os_error().is_some_and(|code| {
                [libc::ENOTSUP, libc::EOPNOTSUPP, libc::ENOLCK].contains(&code)
            }) =>
        {
            (None, LockState::Unsupported)
        }
        _ => (None, LockState::Held),
    }
}

/// Whether `pid` is a running process: one this user may not signal (EPERM) counts as running.
fn process_alive(pid: libc::pid_t) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    let signalled = unsafe { libc::kill(pid, 0) } == 0;
    signalled || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// A dead clone's leftovers: its staging folder (none when only an orphan lock file is left) and
/// its lock file (none when it has none), that lock held by this process while the sweep removes
/// them.
pub(super) struct Stale {
    pub(super) dir: Option<PathBuf>,
    pub(super) lock: Option<PathBuf>,
    held: Option<File>,
}

impl Stale {
    /// What the leftovers occupy.
    pub(super) fn paths(&self) -> Vec<PathBuf> {
        self.dir.iter().chain(&self.lock).cloned().collect()
    }

    /// How the sweep's progress line names them.
    fn name(&self) -> String {
        self.dir
            .as_ref()
            .or(self.lock.as_ref())
            .and_then(|path| path.file_name())
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default()
    }

    /// Removes the staging folder, checking once more that it is still a real folder and not a
    /// symlink put in its place, then its lock file, and only then lets go of the lock.
    fn remove(self) {
        if let Some(dir) = &self.dir
            && std::fs::symlink_metadata(dir).is_ok_and(|info| info.is_dir())
        {
            let _ = std::fs::remove_dir_all(dir);
        }
        if let (Some(held), Some(lock)) = (self.held, &self.lock) {
            let _ = std::fs::remove_file(lock);
            drop(held);
        }
    }
}

/// What a dead clone into `canon` left: inside it (only when it is a real folder) and beside it.
pub(super) fn stale_staging_for(canon: &Path, host: &str) -> (Vec<Stale>, Vec<Stale>) {
    let inside = if std::fs::symlink_metadata(canon).is_ok_and(|info| info.is_dir()) {
        stale_staging(canon, b".clone-", host)
    } else {
        Vec::new()
    };
    let (Some(parent), Some(name)) = (canon.parent(), canon.file_name()) else {
        return (inside, Vec::new());
    };
    let mut prefix = b".".to_vec();
    prefix.extend_from_slice(name.as_bytes());
    prefix.extend_from_slice(b".clone-");
    (inside, stale_staging(parent, &prefix, host))
}

/// The entries of `dir` named `prefix<host>-<pid>-…` that are provably a dead clone's, made on
/// this machine (`host`; "" when it has no machine id, which sweeps nothing), in name order. See
/// the module's rules.
pub(super) fn stale_staging(dir: &Path, prefix: &[u8], host: &str) -> Vec<Stale> {
    if host.is_empty() {
        return Vec::new();
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut entries: Vec<_> = entries.filter_map(Result::ok).collect();
    entries.sort_by_key(std::fs::DirEntry::file_name);
    let mut stale = Vec::new();
    for entry in entries {
        let name = entry.file_name();
        let (staging_name, is_lock) = match name.as_bytes().strip_suffix(b".lock") {
            Some(stem) => (stem, true),
            None => (name.as_bytes(), false),
        };
        let Some(rest) = staging_name.strip_prefix(prefix) else {
            continue;
        };
        let mut parts = rest.splitn(3, |&b| b == b'-');
        let (Some(owner), Some(pid), Some(_)) = (parts.next(), parts.next(), parts.next()) else {
            continue;
        };
        if owner != host.as_bytes() {
            continue;
        }
        // A pid must fit one, as only this code writes them; Go's Atoi read any int, which can't
        // name a process either.
        let Some(pid) = std::str::from_utf8(pid)
            .ok()
            .and_then(|pid| pid.parse::<libc::pid_t>().ok())
            .filter(|&pid| pid > 0)
        else {
            continue;
        };
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        let stage = dir.join(OsStr::from_bytes(staging_name));
        let lock = lock_path(&stage);
        if is_lock {
            if !file_type.is_file() {
                continue;
            }
            match std::fs::symlink_metadata(&stage) {
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                // Judged with its folder.
                _ => continue,
            }
            if let (held, LockState::Free) = probe_lock(&lock) {
                stale.push(Stale {
                    dir: None,
                    lock: Some(lock),
                    held,
                });
            }
            continue;
        }
        if !file_type.is_dir() {
            continue;
        }
        match probe_lock(&lock) {
            (held, LockState::Free) => stale.push(Stale {
                dir: Some(stage),
                lock: Some(lock),
                held,
            }),
            (_, LockState::Missing | LockState::Unsupported) if !process_alive(pid) => {
                stale.push(Stale {
                    dir: Some(stage),
                    lock: None,
                    held: None,
                });
            }
            _ => {}
        }
    }
    stale
}

/// Removes what dead clones left, saying so on `progress` first. A cancel stops it at once with
/// `Cancelled`: a folder left half-removed is still a dead clone's, swept next time.
pub(super) fn remove_stale(
    signals: &crate::script::Signals,
    progress: &mut dyn Write,
    stale: Vec<Stale>,
) -> Result<(), CliError> {
    for stage in stale {
        if signals.received().is_some() {
            return Err(cancelled());
        }
        let _ = writeln!(
            progress,
            "Removing staging a crashed clone left: {}",
            stage.name()
        );
        let removing = std::thread::spawn(move || stage.remove());
        while !removing.is_finished() {
            if signals.received().is_some() {
                // The removal goes on without us; the rest's locks are let go of as they drop.
                return Err(cancelled());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    Ok(())
}

/// The staging-shaped entries (a `.clone-*` folder or `.clone-*.lock` file) that alone keep `dir`
/// from being empty, in name order: a clone still running, another machine's, one without an
/// owner in its name, or one the sweep couldn't remove. Empty when anything else is there too, a
/// `.clone-notes` file of the user's included.
pub(super) fn staging_in_the_way(dir: &Path, ignore: &[PathBuf]) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut entries: Vec<_> = entries.filter_map(Result::ok).collect();
    entries.sort_by_key(std::fs::DirEntry::file_name);
    let mut staging = Vec::new();
    for entry in entries {
        let name = entry.file_name();
        let bytes = name.as_bytes();
        let file_type = entry.file_type().ok();
        if FINDER_JUNK.iter().any(|junk| name == *junk) || ignore.contains(&entry.path()) {
            continue;
        }
        let shaped = bytes.starts_with(b".clone-")
            && file_type.is_some_and(|file_type| {
                file_type.is_dir() || (file_type.is_file() && bytes.ends_with(b".lock"))
            });
        if !shaped {
            return Vec::new();
        }
        staging.push(name.to_string_lossy().into_owned());
    }
    staging
}

#[cfg(test)]
mod tests;
