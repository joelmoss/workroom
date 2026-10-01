//! The agent's own record of its sessions: one timestamped line per lifecycle event, on stderr.
//!
//! A session's shell can end in only a few ways (it exits, its pty fails, a client asks, a hand-off
//! fails to carry it), and before this none of them left a trace. A spawned agent's stderr was
//! /dev/null, so when two sessions vanished across a Nightly update's hand-off there was nothing to
//! say which way they went. `redirect_stderr` gives such an agent a file beside its socket instead.

use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// A log past this size starts over when an agent starts, so it cannot grow without bound across
/// the months one agent's file is reused.
// ponytail: truncates at startup only; rotate if one agent's lifetime ever outgrows it.
const MAX_LOG: u64 = 4 << 20;

/// `note!("session {} ended", id)`: one line, timestamped, on stderr.
#[macro_export]
macro_rules! note {
    ($($arg:tt)*) => { $crate::log::note(format_args!($($arg)*)) };
}

pub fn note(message: std::fmt::Arguments) {
    // One write per line, so lines from different threads never interleave mid-line.
    let line = format!("{} [{}] {message}\n", timestamp(), std::process::id());
    let _ = std::io::stderr().lock().write_all(line.as_bytes());
}

/// Local time to the millisecond, the same clock `log show` prints, so a line here can be put
/// beside the app's own log and the system's.
fn timestamp() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    // Typed by `localtime_r`'s parameter rather than named: musl deprecates the `time_t` alias.
    let seconds = now.as_secs().try_into().unwrap_or_default();
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
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
/// handed to keeps writing where its predecessor did.
pub fn redirect_stderr(socket: &Path) {
    if !stderr_is_dev_null() {
        return;
    }
    let path = log_path(socket);
    let start_over = std::fs::metadata(&path).is_ok_and(|meta| meta.len() > MAX_LOG);
    let mut options = std::fs::OpenOptions::new();
    options.create(true).mode(0o600);
    if start_over {
        options.write(true).truncate(true);
    } else {
        options.append(true);
    }
    if let Ok(file) = options.open(&path) {
        unsafe { libc::dup2(file.as_raw_fd(), libc::STDERR_FILENO) };
    }
}

fn stderr_is_dev_null() -> bool {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};
    // `/dev/fd/2` is stderr itself on both macOS and Linux, and std's metadata spares a
    // platform-dependent `st_rdev` cast.
    match (
        std::fs::metadata("/dev/null"),
        std::fs::metadata("/dev/fd/2"),
    ) {
        (Ok(null), Ok(stderr)) => {
            stderr.file_type().is_char_device() && stderr.rdev() == null.rdev()
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
    fn the_log_sits_beside_the_socket() {
        assert_eq!(
            log_path(Path::new("/a/sessions/agent.sock")),
            Path::new("/a/sessions/agent.log")
        );
    }
}
