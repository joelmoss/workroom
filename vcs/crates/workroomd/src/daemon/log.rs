//! The daemon's own record of its sessions: one timestamped line per lifecycle event, on stderr.
//!
//! A session's shell can end in only a few ways (it exits, its pty fails, a client asks, a hand-off
//! fails to carry it), and before this none of them left a trace. A spawned daemon's stderr was
//! /dev/null, so when two sessions vanished across a Nightly update's hand-off there was nothing to
//! say which way they went. `redirect_stderr` gives such a daemon a file beside its socket instead.

use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::io::{AsRawFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Past this the log is renamed to `workroomd.log.1` and a fresh one begun (`rotate`), so a long-lived
/// daemon keeps at most twice this on disk and always the most recent lines.
const MAX_LOG: u64 = 4 << 20;

/// The file stderr is, once `redirect_stderr` has made it or found it, which is what `note` rotates.
static LOG: OnceLock<PathBuf> = OnceLock::new();

/// `note!("session {} ended", id)`: one line, timestamped, on stderr.
#[macro_export]
macro_rules! note {
    ($($arg:tt)*) => { $crate::daemon::log::note(format_args!($($arg)*)) };
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
/// the next rotation, and a second daemon racing for the socket cannot erase a live daemon's lines.
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
    // `O_NOFOLLOW`: a symlink planted at either name gets the daemon no log, rather than having it
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

/// The log beside `socket`: `workroomd.sock` logs to `workroomd.log`.
pub fn log_path(socket: &Path) -> PathBuf {
    socket.with_extension("log")
}

/// Points stderr at `log_path(socket)`, but only when it is /dev/null, which is how every spawner
/// starts a daemon (`serve::spawn_daemon`). A stderr someone is reading, such as a test's pipe or a
/// supervisor's log, is left alone. After a hand-off stderr is already this file, so the program
/// handed to keeps writing, and rotating, where its predecessor did.
///
/// Appends, never truncates: this runs before the instance lock, and a `serve` that then loses the
/// race for the socket must not have touched the running daemon's log.
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

/// Whether stderr is `path`'s file. Stderr is read with `fstat` on the descriptor itself, never by
/// looking up `/dev/fd/2`: on a busy Mac that lookup now and then fails with EBADF while fd 2 is
/// open, and a spawned daemon then logged its whole life to /dev/null (#639). std's metadata spares
/// the platform-dependent field types of a raw `stat`.
fn stderr_is(path: &Path) -> bool {
    // SAFETY: std holds fd 2 by number and nothing owns it; `ManuallyDrop` keeps this borrow of it
    // from closing it.
    let stderr = std::mem::ManuallyDrop::new(unsafe {
        <std::fs::File as std::os::fd::FromRawFd>::from_raw_fd(libc::STDERR_FILENO)
    });
    match (std::fs::metadata(path), stderr.metadata()) {
        (Ok(file), Ok(stderr)) => {
            file.dev() == stderr.dev() && file.ino() == stderr.ino() && file.rdev() == stderr.rdev()
        }
        _ => false,
    }
}

/// A panic on any thread is one timestamped line here, then whatever the previous hook prints. A
/// panic on the main thread ends the daemon, and the default hook's untimestamped lines alone do not
/// say when.
pub fn note_panics() {
    let previous = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let thread = std::thread::current();
        crate::note!(
            "panic on thread {}: {info}",
            thread.name().unwrap_or("unnamed")
        );
        previous(info);
    }));
}

/// The signals whose default action ends the daemon without a crash report. The faults (SIGSEGV,
/// SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP) are left alone: the system's crash reporter already
/// records those, and a handler would get in its way. SIGKILL and SIGSTOP cannot be caught.
const FATAL_SIGNALS: [libc::c_int; 11] = [
    libc::SIGTERM,
    libc::SIGHUP,
    libc::SIGINT,
    libc::SIGQUIT,
    libc::SIGUSR1,
    libc::SIGUSR2,
    libc::SIGALRM,
    libc::SIGXCPU,
    libc::SIGXFSZ,
    libc::SIGVTALRM,
    libc::SIGPROF,
];

/// The write end of the pipe `on_fatal_signal` reports on, and the pid that installed it.
static SIGNAL_PIPE: AtomicI32 = AtomicI32::new(-1);
static DAEMON_PID: AtomicI32 = AtomicI32::new(0);

extern "C" fn on_fatal_signal(signal: libc::c_int) {
    // A child between fork and exec still has this handler and the pipe; its signal is its own.
    // SAFETY: `getpid` and `write` are async-signal-safe and take no pointers we do not own.
    if unsafe { libc::getpid() } != DAEMON_PID.load(Ordering::Relaxed) {
        return;
    }
    let byte = signal as u8;
    // SAFETY: as above; one byte from a live local.
    unsafe {
        libc::write(
            SIGNAL_PIPE.load(Ordering::Relaxed),
            (&byte as *const u8).cast(),
            1,
        )
    };
}

/// Has each of `FATAL_SIGNALS` write a line here before it ends the daemon, as it would have.
///
/// The handler only writes the signal's number to a pipe, all a handler may safely do; a thread
/// reads it, logs it (waiting a second at most), and raises it again with the default action, so
/// the daemon still dies of that signal with the same status. One inherited as ignored is left so. `execve` resets caught signals to their default, so a session's
/// shell is not affected, and a hand-off's next program installs its own.
pub fn note_fatal_signals() {
    let mut fds = [0; 2];
    // SAFETY: `fds` is a live two-element array, as `pipe` requires.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return;
    }
    for fd in fds {
        wr_exec::set_cloexec(fd, true);
    }
    let [read, write] = fds;
    let reader = std::thread::Builder::new()
        .name("fatal-signals".into())
        .spawn(move || {
            let mut byte = 0u8;
            // SAFETY: one byte into a live local, from a descriptor this thread alone reads.
            while unsafe { libc::read(read, (&mut byte as *mut u8).cast(), 1) } != 1 {}
            let signal = libc::c_int::from(byte);
            // The line is written from its own thread and waited for briefly: a stderr that blocks
            // (a supervisor's pipe nobody drains) must not stop the signal from ending the daemon.
            let (logged, wait) = std::sync::mpsc::channel();
            if std::thread::Builder::new()
                .spawn(move || {
                    crate::note!("{}; exiting", describe_status(signal));
                    let _ = logged.send(());
                })
                .is_ok()
            {
                let _ = wait.recv_timeout(std::time::Duration::from_secs(1));
            }
            // SAFETY: plain integers; the default action for every one of these ends the process.
            unsafe {
                libc::signal(signal, libc::SIG_DFL);
                libc::raise(signal);
            }
            std::process::exit(128 + signal);
        });
    if reader.is_err() {
        // SAFETY: both descriptors are this function's own and nothing else has them.
        unsafe {
            libc::close(read);
            libc::close(write);
        }
        return;
    }
    SIGNAL_PIPE.store(write, Ordering::Relaxed);
    // SAFETY: `getpid` takes no arguments.
    DAEMON_PID.store(unsafe { libc::getpid() }, Ordering::Relaxed);
    for signal in FATAL_SIGNALS {
        // A signal the daemon was started with ignored stays ignored: `start.sh` runs an SSH host's
        // daemon under `nohup` and in the background, and logging must not make SIGHUP fatal there.
        // SAFETY: `sigaction` is plain old data, for which all zeroes is a valid value.
        let mut previous: libc::sigaction = unsafe { std::mem::zeroed() };
        // SAFETY: a null new action only reads the current one into the live `previous`.
        if unsafe { libc::sigaction(signal, std::ptr::null(), &mut previous) } != 0
            || previous.sa_sigaction == libc::SIG_IGN
        {
            continue;
        }
        // SAFETY: `sigaction` is plain old data, for which all zeroes is a valid value.
        let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
        action.sa_sigaction = on_fatal_signal as extern "C" fn(libc::c_int) as usize;
        action.sa_flags = libc::SA_RESTART;
        // SAFETY: `action` is a live, initialised sigaction and the old action is not asked for.
        unsafe { libc::sigaction(signal, &action, std::ptr::null_mut()) };
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
        libc::SIGQUIT => " (SIGQUIT)",
        libc::SIGUSR1 => " (SIGUSR1)",
        libc::SIGUSR2 => " (SIGUSR2)",
        _ => "",
    };
    format!("killed by signal {signal}{name}")
}

#[cfg(test)]
mod tests;
