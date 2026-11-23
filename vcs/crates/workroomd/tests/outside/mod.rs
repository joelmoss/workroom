//! Starts a program outside this test's process tree, so none of the test's parents are the
//! program's: `cargo`, a terminal, or a coding agent running the tests. The commands only a person
//! may run (`trust`, `delete`, `delete-project`, #793) refuse to run under a coding agent, found
//! from the binary's parents, and nothing in the binary turns that off; a test run by a coding agent
//! starts them this way instead, and so do the tests that put a stand-in agent above them.
//!
//! How: the test forks (std's `spawn`), and that child starts a session of its own, forks again and
//! exits at once. Its child, orphaned, is adopted by init (or a subreaper on Linux): once its parent
//! has changed, it forks the program, waits for it, and writes the program's pid and wait status to
//! two files this harness reads. So the program's parent is that reaper, whose parent is init, and
//! the walk up from the program ends there. The reaper only makes system calls between the forks,
//! and closes every descriptor past stdio first, so std's own close-on-exec pipe closes when the
//! program starts, and `spawn` returns then rather than when the program exits.
//!
//! Stdout and stderr are piped through to the test, as `Command::output` pipes them; stdin is the
//! caller's to set (null, a pty), or the bytes `spawn` is given.

use std::ffi::{CStr, CString};
use std::io::Write;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::time::{Duration, Instant};

/// A program started outside this process's tree, killed when the test ends unless it was waited
/// for.
pub struct Outside {
    /// The program's own pid, to signal it.
    pub pid: i32,
    /// The first fork, already exited, whose pipes carry the program's output.
    first: Option<Child>,
    /// The folder of the reaper's pid and status files.
    report: PathBuf,
}

/// Starts `command` outside this process's tree with stdout and stderr piped, and `input`, when
/// given, written to its stdin and closed.
pub fn spawn(mut command: Command, input: Option<&[u8]>) -> Outside {
    let report = report_folder();
    let pid_file = path(&report.join("pid"));
    let status_file = path(&report.join("status"));
    command.stdout(Stdio::piped()).stderr(Stdio::piped());
    if input.is_some() {
        command.stdin(Stdio::piped());
    }
    // SAFETY: between the forks and the exec, `detach` only makes system calls, all on memory
    // allocated before the first fork; see its own comments.
    unsafe {
        command.pre_exec(move || detach(&pid_file, &status_file));
    }
    let mut first = command
        .spawn()
        .expect("start the program outside this tree");
    let pid = read_number(&report.join("pid"), Duration::from_secs(30));
    if let Some(input) = input {
        // A program that never reads its stdin may close it first, which is no failure here.
        let _ = first.stdin.take().expect("stdin").write_all(input);
    }
    Outside {
        pid,
        first: Some(first),
        report,
    }
}

impl Outside {
    /// The program's output and exit status, once it has exited and closed its output.
    pub fn wait_with_output(mut self) -> Output {
        let first = self.first.take().expect("not yet waited for");
        let output = first.wait_with_output().expect("read the program's output");
        // The reaper writes the status before it exits, and the pipes close only once it has.
        let status = read_number(&self.report.join("status"), Duration::from_secs(5));
        Output {
            status: ExitStatus::from_raw(status),
            stdout: output.stdout,
            stderr: output.stderr,
        }
    }
}

impl Drop for Outside {
    fn drop(&mut self) {
        if let Some(mut first) = self.first.take() {
            // SAFETY: signals the program this harness started, which has not been waited for.
            unsafe { libc::kill(self.pid, libc::SIGKILL) };
            let _ = first.wait();
        }
        let _ = std::fs::remove_dir_all(&self.report);
    }
}

/// A folder this harness made for one program's report: never one that was there already.
fn report_folder() -> PathBuf {
    let parent = std::env::temp_dir();
    for attempt in 0u32.. {
        let dir = parent.join(format!("workroom-outside-{}-{attempt}", std::process::id()));
        match std::fs::create_dir(&dir) {
            Ok(()) => return dir,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => panic!("create {}: {error}", dir.display()),
        }
    }
    unreachable!("u32 attempts ran out")
}

fn path(path: &Path) -> CString {
    CString::new(path.as_os_str().as_bytes()).expect("a path without NUL")
}

/// The number a reaper wrote to `file`, waiting up to `limit` for it to appear.
fn read_number(file: &Path, limit: Duration) -> i32 {
    let deadline = Instant::now() + limit;
    loop {
        if let Ok(text) = std::fs::read_to_string(file) {
            return text
                .trim()
                .parse()
                .unwrap_or_else(|_| panic!("{}: {text:?}", file.display()));
        }
        assert!(
            Instant::now() < deadline,
            "{} never appeared: the reaper could not start the program",
            file.display()
        );
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Runs in std's child, between its fork and its exec: a session of its own, then a reaper that
/// init adopts, which forks the program and reports it. Returns only in the program's process, for
/// std to exec it there.
fn detach(pid_file: &CStr, status_file: &CStr) -> std::io::Result<()> {
    // SAFETY: each call below is a system call (`setsid`, `getpid`, `fork`, `getppid`,
    // `nanosleep`, `close`, `waitpid`, `_exit`, and `report`'s), safe in the child of a fork of a
    // threaded process, given only memory this process already has.
    unsafe {
        if libc::setsid() == -1 {
            return Err(std::io::Error::last_os_error());
        }
        let first = libc::getpid();
        match libc::fork() {
            -1 => return Err(std::io::Error::last_os_error()),
            0 => {}
            _ => libc::_exit(0),
        }
        // The reaper: wait until the first fork is gone and something else has adopted it, so
        // the program never sees this test among its parents.
        while libc::getppid() == first {
            let pause = libc::timespec {
                tv_sec: 0,
                tv_nsec: 1_000_000,
            };
            libc::nanosleep(&pause, std::ptr::null_mut());
        }
        close_past_stdio();
        match libc::fork() {
            -1 => libc::_exit(127),
            0 => Ok(()),
            program => {
                report(pid_file, program);
                let mut status = 0;
                while libc::waitpid(program, &mut status, 0) == -1
                    && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR)
                {
                }
                report(status_file, status);
                libc::_exit(0)
            }
        }
    }
}

/// Closes every descriptor past stdio, std's close-on-exec error pipe among them.
///
/// # Safety
///
/// Only in a child of a fork that execs or exits next: it closes descriptors others may own.
unsafe fn close_past_stdio() {
    if closed_by_range() {
        return;
    }
    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: `limit` is a live local the call fills.
    let known = unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } == 0;
    let last = if known {
        limit.rlim_cur.min(65_536) as libc::c_int
    } else {
        65_536
    };
    for fd in 3..last {
        // SAFETY: closing a descriptor that is not open fails harmlessly.
        unsafe { libc::close(fd) };
    }
}

/// Linux's `close_range` past stdio, in one call; false on a kernel without it, and elsewhere.
#[cfg(target_os = "linux")]
fn closed_by_range() -> bool {
    // SAFETY: `close_range` takes no pointers.
    unsafe { libc::syscall(libc::SYS_close_range, 3u32, u32::MAX, 0u32) == 0 }
}

#[cfg(not(target_os = "linux"))]
fn closed_by_range() -> bool {
    false
}

/// Writes `number` in decimal to `file`, appearing whole: written beside it, then renamed.
///
/// # Safety
///
/// System calls on a stack buffer only, for a child of a fork.
unsafe fn report(file: &CStr, number: i32) {
    let mut text = [0u8; 16];
    let mut at = text.len();
    let negative = number < 0;
    let mut rest = (number as i64).unsigned_abs();
    loop {
        at -= 1;
        text[at] = b'0' + (rest % 10) as u8;
        rest /= 10;
        if rest == 0 {
            break;
        }
    }
    if negative {
        at -= 1;
        text[at] = b'-';
    }
    // `<file>~`, NUL-terminated, on the stack.
    let name = file.to_bytes();
    let mut partial = [0u8; 1024];
    if name.len() + 2 > partial.len() {
        return;
    }
    partial[..name.len()].copy_from_slice(name);
    partial[name.len()] = b'~';
    // SAFETY: `partial` and `file` are NUL-terminated, `text[at..]` is in bounds.
    unsafe {
        let fd = libc::open(
            partial.as_ptr().cast(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC | libc::O_CLOEXEC,
            0o600,
        );
        if fd == -1 {
            return;
        }
        libc::write(fd, text[at..].as_ptr().cast(), text.len() - at);
        libc::close(fd);
        libc::rename(partial.as_ptr().cast(), file.as_ptr());
    }
}
