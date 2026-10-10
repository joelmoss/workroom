//! The agent's own record of its sessions: one timestamped line per lifecycle event, on stderr.
//!
//! A session's shell can end in only a few ways (it exits, its pty fails, a client asks, a hand-off
//! fails to carry it), and before this none of them left a trace. A spawned agent's stderr was
//! /dev/null, so when two sessions vanished across a Nightly update's hand-off there was nothing to
//! say which way they went. `redirect_stderr` gives such an agent a file beside its socket instead.

use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::io::{AsRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

/// Past this the log is renamed to `agent.log.1` and a fresh one begun (`rotate`), so a long-lived
/// agent keeps at most twice this on disk and always the most recent lines.
const MAX_LOG: u64 = 4 << 20;

/// The file stderr is, once `redirect_stderr` has made it or found it, which is what `note` rotates.
static LOG: OnceLock<PathBuf> = OnceLock::new();

/// `note!("session {} ended", id)`: one line, timestamped, on stderr.
#[macro_export]
macro_rules! note {
    ($($arg:tt)*) => { $crate::log::note(format_args!($($arg)*)) };
}

pub fn note(message: std::fmt::Arguments) {
    let line = format!(
        "{} [{}] {}\n",
        timestamp(),
        std::process::id(),
        one_line(&message.to_string())
    );
    // One write per line under stderr's lock, so lines from different threads never interleave
    // mid-line, and the rotation that follows cannot split one either.
    let mut stderr = std::io::stderr().lock();
    let _ = stderr.write_all(line.as_bytes());
    if let Some(path) = LOG.get() {
        rotate(path, libc::STDERR_FILENO, MAX_LOG);
    }
}

/// `message` with every control character escaped. A message can quote what a client sent (a
/// hand-off's binary path, a refusal naming it), and a newline there would otherwise forge a line
/// of its own in a file read to find out what happened to a session.
fn one_line(message: &str) -> String {
    message
        .chars()
        .flat_map(|c| {
            let escaped: Vec<char> = if c.is_control() {
                c.escape_default().collect()
            } else {
                vec![c]
            };
            escaped
        })
        .collect()
}

/// Once the file `fd` writes to passes `max`, renames `path` to `<path>.1` (replacing the last one)
/// and points `fd` at a fresh `path`. A rename, never a truncation: nothing written is lost until
/// the next rotation, and a second agent racing for the socket cannot erase a live agent's lines.
///
/// The fresh file is opened first, under a name of its own, and only then is anything renamed. A
/// failed open therefore leaves everything where it was, to be tried again on the next line, where
/// opening after the rename would leave `fd` writing to `<path>.1` for good with no `path` at all.
fn rotate(path: &Path, fd: RawFd, max: u64) {
    // SAFETY: `stat` is plain old data, for which all zeroes is a valid value.
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: `stat` is a live, writable `libc::stat`; a stale `fd` only makes fstat fail.
    if unsafe { libc::fstat(fd, &mut stat) } != 0 || (stat.st_size as u64) <= max {
        return;
    }
    let sibling = |suffix: &str| {
        let mut name = path.as_os_str().to_owned();
        name.push(suffix);
        PathBuf::from(name)
    };
    let (fresh, previous) = (sibling(".new"), sibling(".1"));
    let _ = std::fs::remove_file(&fresh);
    let Ok(file) = open_log(&fresh) else { return };
    if std::fs::rename(path, &previous).is_err() {
        let _ = std::fs::remove_file(&fresh);
        return;
    }
    if std::fs::rename(&fresh, path).is_err() {
        // Put the log back, so `fd` is writing to `path` again.
        let _ = std::fs::rename(&previous, path);
        let _ = std::fs::remove_file(&fresh);
        return;
    }
    // SAFETY: `file` is open for the call. `fd` is a raw log descriptor no Rust value owns (stderr
    // in production), so replacing what it points at invalidates nothing.
    unsafe { libc::dup2(file.as_raw_fd(), fd) };
}

fn open_log(path: &Path) -> std::io::Result<std::fs::File> {
    // `O_NOFOLLOW`: a symlink planted at either name gets the agent no log, rather than having it
    // append wherever the link points.
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
}

/// Local time to the millisecond, the same clock `log show` prints, so a line here can be put
/// beside the app's own log and the system's.
fn timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    // Typed by `localtime_r`'s parameter rather than named: musl deprecates the `time_t` alias.
    let seconds = now.as_secs().try_into().unwrap_or_default();
    // SAFETY: `tm` is plain old data (its zone pointer may be null), so all zeroes is valid.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    // SAFETY: both pointers are to live locals, and the reentrant `_r` form keeps no static buffer.
    unsafe { libc::localtime_r(&seconds, &mut tm) };
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}.{:03}",
        tm.tm_year + 1900,
        tm.tm_mon + 1,
        tm.tm_mday,
        tm.tm_hour,
        tm.tm_min,
        tm.tm_sec,
        now.subsec_millis()
    )
}

/// The log beside `socket`: `agent.sock` logs to `agent.log`.
pub fn log_path(socket: &Path) -> PathBuf {
    socket.with_extension("log")
}

/// Points stderr at `log_path(socket)`, but only when it is /dev/null, which is how every spawner
/// starts an agent (`serve::spawn_agent`). A stderr someone is reading, such as a test's pipe or a
/// supervisor's log, is left alone. After a hand-off stderr is already this file, so the program
/// handed to keeps writing, and rotating, where its predecessor did.
///
/// Appends, never truncates: this runs before the instance lock, and a `serve` that then loses the
/// race for the socket must not have touched the running agent's log.
pub fn redirect_stderr(socket: &Path) {
    let path = log_path(socket);
    if stderr_is(Path::new("/dev/null")) {
        let Ok(file) = open_log(&path) else { return };
        // SAFETY: `file` is open for the call, and std holds fd 2 by number, not as an owned fd.
        unsafe { libc::dup2(file.as_raw_fd(), libc::STDERR_FILENO) };
    }
    if stderr_is(&path) {
        let _ = LOG.set(path);
    }
}

/// Whether stderr is `path`'s file. `/dev/fd/2` is stderr itself on both macOS and Linux, and std's
/// metadata spares the platform-dependent field types of a raw `stat`.
fn stderr_is(path: &Path) -> bool {
    match (std::fs::metadata(path), std::fs::metadata("/dev/fd/2")) {
        (Ok(file), Ok(stderr)) => {
            file.dev() == stderr.dev() && file.ino() == stderr.ino() && file.rdev() == stderr.rdev()
        }
        _ => false,
    }
}

/// A `waitpid` status as a person reads it: "exited 0", "killed by signal 1 (SIGHUP)".
pub fn describe_status(status: i32) -> String {
    let signal = status & 0o177;
    if signal == 0 {
        return format!("exited {}", (status >> 8) & 0xFF);
    }
    let name = match signal {
        libc::SIGHUP => " (SIGHUP)",
        libc::SIGINT => " (SIGINT)",
        libc::SIGKILL => " (SIGKILL)",
        libc::SIGTERM => " (SIGTERM)",
        _ => "",
    };
    format!("killed by signal {signal}{name}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_status_reads_as_an_exit_or_a_signal() {
        assert_eq!(describe_status(0), "exited 0");
        assert_eq!(describe_status(7 << 8), "exited 7");
        assert_eq!(describe_status(libc::SIGHUP), "killed by signal 1 (SIGHUP)");
        assert_eq!(
            describe_status(libc::SIGKILL | 0o200),
            "killed by signal 9 (SIGKILL)"
        );
    }

    #[test]
    fn a_message_cannot_start_a_line_of_its_own() {
        assert_eq!(
            one_line("hand-off to /tmp/x\n2026-10-01 session 1 killed\r\t"),
            "hand-off to /tmp/x\\n2026-10-01 session 1 killed\\r\\t"
        );
        assert_eq!(
            one_line("/Users/joël/it's \"fine\""),
            "/Users/joël/it's \"fine\""
        );
    }

    #[test]
    fn a_log_past_its_limit_moves_aside_and_writing_carries_on_in_a_fresh_one() {
        let dir = std::env::temp_dir().join(format!("wr-agent-log-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        let path = dir.join("agent.log");
        let file = open_log(&path).expect("log");
        // SAFETY: `file` is open for the call; dup takes and returns plain integers.
        let fd = unsafe { libc::dup(file.as_raw_fd()) };
        // SAFETY: the pointer and length come from one live slice, and `fd` stays open until the
        // close at the end of the test.
        let write = |bytes: &[u8]| unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };

        write(b"under\n");
        rotate(&path, fd, 10);
        assert!(!dir.join("agent.log.1").exists(), "rotated under the limit");

        write(b"now over the limit\n");
        rotate(&path, fd, 10);
        write(b"after\n");
        let kept = std::fs::read_to_string(dir.join("agent.log.1")).expect("previous");
        let fresh = std::fs::read_to_string(&path).expect("fresh");
        // SAFETY: `fd` is the test's own duplicate, closed once and not used after.
        unsafe { libc::close(fd) };
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(kept, "under\nnow over the limit\n");
        assert_eq!(fresh, "after\n");
    }

    /// The open that fails is the fresh file's, and a directory in its place makes it fail.
    #[test]
    fn a_rotation_that_cannot_open_a_fresh_log_leaves_the_log_in_place() {
        let dir = std::env::temp_dir().join(format!("wr-agent-log-stuck-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("agent.log.new")).expect("blocker");
        let path = dir.join("agent.log");
        let file = open_log(&path).expect("log");
        // SAFETY: `file` is open for the call; dup takes and returns plain integers.
        let fd = unsafe { libc::dup(file.as_raw_fd()) };
        // SAFETY: the pointer and length come from one live slice, and `fd` stays open until the
        // close at the end of the test.
        let write = |bytes: &[u8]| unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };

        write(b"over the limit\n");
        rotate(&path, fd, 5);
        write(b"still here\n");
        let log = std::fs::read_to_string(&path).unwrap_or_default();
        let moved = dir.join("agent.log.1").exists();
        // SAFETY: `fd` is the test's own duplicate, closed once and not used after.
        unsafe { libc::close(fd) };
        let _ = std::fs::remove_dir_all(&dir);
        assert!(!moved, "the log moved aside with nothing to replace it");
        assert_eq!(log, "over the limit\nstill here\n");
    }

    #[test]
    fn a_symlink_in_the_log_s_place_is_not_followed() {
        let dir = std::env::temp_dir().join(format!("wr-agent-log-link-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        let target = dir.join("elsewhere");
        std::os::unix::fs::symlink(&target, dir.join("agent.log")).expect("link");
        let opened = open_log(&dir.join("agent.log")).is_ok();
        let followed = target.exists();
        let _ = std::fs::remove_dir_all(&dir);
        assert!(!opened && !followed, "opened {opened}, followed {followed}");
    }

    #[test]
    fn the_log_sits_beside_the_socket() {
        assert_eq!(
            log_path(Path::new("/a/sessions/agent.sock")),
            Path::new("/a/sessions/agent.log")
        );
    }
}
