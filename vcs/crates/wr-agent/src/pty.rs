//! The pty the terminal service owns, ported from `macapp/WorkroomSession/SessionPTY.swift`.
//!
//! One piece here is load-bearing and easy to drop in a port: **the self-pipe exec-failure
//! check**. `forkpty` returning a pid tells the parent only that `fork` succeeded — not that the
//! child ever reached the shell. Without the pipe, a bad shell path acks the attach as created and
//! then closes moments later with no explanation, which is indistinguishable from a shell that
//! exited on its own. With it, a genuine exec failure reports the real `errno` instead.
//!
//! The mechanism: both pipe ends are close-on-exec, so a *successful* `execve` closes the child's
//! write end as part of the syscall and the parent reads EOF. A *failed* `execve` never reaches
//! that closure — the child is still running our code — so it writes its errno first.

use std::ffi::{CString, OsStr, OsString};
use std::os::unix::ffi::OsStrExt;

/// Signals reset to their default in the child. A pty child inheriting the agent's dispositions
/// would ignore the signals a terminal is expected to act on — a shell that cannot be interrupted
/// by ^C is the visible form of getting this wrong.
const RESET_SIGNALS: [libc::c_int; 8] = [
    libc::SIGINT,
    libc::SIGQUIT,
    libc::SIGTERM,
    libc::SIGHUP,
    libc::SIGPIPE,
    libc::SIGTSTP,
    libc::SIGTTIN,
    libc::SIGTTOU,
];

pub const DEFAULT_COLUMNS: u16 = 80;
pub const DEFAULT_ROWS: u16 = 24;

#[derive(Debug, thiserror::Error)]
pub enum PtyError {
    #[error("pipe failed: {0}")]
    Pipe(std::io::Error),
    #[error("forkpty failed: {0}")]
    ForkPty(std::io::Error),
    /// The child was created but never became the requested program. This is the case the
    /// self-pipe exists to distinguish from a shell that started and then exited.
    #[error("exec of {program} failed: {source}")]
    Exec {
        program: String,
        source: std::io::Error,
    },
    #[error("{0} contains an interior NUL")]
    InteriorNul(&'static str),
}

#[derive(Debug)]
pub struct Pty {
    master: libc::c_int,
    pid: libc::pid_t,
}

impl Pty {
    /// Forks a child on a new pty and execs `program`.
    ///
    /// `cwd` failing to resolve is not fatal — the child falls back to `$HOME`, then `/`, matching
    /// the Swift original. A workroom directory deleted while a session was detached should land
    /// the user in a working shell, not kill the session.
    pub fn spawn(
        program: &OsStr,
        argv0: Option<&OsStr>,
        args: &[OsString],
        env: &[(OsString, OsString)],
        cwd: Option<&OsStr>,
        columns: u16,
        rows: u16,
    ) -> Result<Pty, PtyError> {
        let c_program =
            CString::new(program.as_bytes()).map_err(|_| PtyError::InteriorNul("program"))?;
        let mut c_args: Vec<CString> = Vec::with_capacity(args.len() + 1);
        // argv[0] is not the program path. A shell decides it is a LOGIN shell by seeing its own
        // name prefixed with `-` here — there is no flag for it — so the caller must be able to
        // say what it is. `None` means the ordinary convention of repeating the program path.
        c_args.push(match argv0 {
            Some(name) => {
                CString::new(name.as_bytes()).map_err(|_| PtyError::InteriorNul("argv0"))?
            }
            None => c_program.clone(),
        });
        for arg in args {
            c_args
                .push(CString::new(arg.as_bytes()).map_err(|_| PtyError::InteriorNul("argument"))?);
        }
        let mut argv: Vec<*const libc::c_char> = c_args.iter().map(|a| a.as_ptr()).collect();
        argv.push(std::ptr::null());

        let c_env: Vec<CString> = env
            .iter()
            .map(|(k, v)| {
                let mut joined = k.as_bytes().to_vec();
                joined.push(b'=');
                joined.extend_from_slice(v.as_bytes());
                CString::new(joined).map_err(|_| PtyError::InteriorNul("environment"))
            })
            .collect::<Result<_, _>>()?;
        let mut envp: Vec<*const libc::c_char> = c_env.iter().map(|e| e.as_ptr()).collect();
        envp.push(std::ptr::null());

        let c_cwd = match cwd {
            Some(dir) => {
                Some(CString::new(dir.as_bytes()).map_err(|_| PtyError::InteriorNul("cwd"))?)
            }
            None => None,
        };

        let mut err_pipe: [libc::c_int; 2] = [-1, -1];
        if unsafe { libc::pipe(err_pipe.as_mut_ptr()) } != 0 {
            return Err(PtyError::Pipe(std::io::Error::last_os_error()));
        }
        let (err_read, err_write) = (err_pipe[0], err_pipe[1]);
        set_cloexec(err_read);
        set_cloexec(err_write);

        // `forkpty` takes the size as a const pointer — it reads the requested geometry and does
        // not write back — so this never needs to be mutable.
        let size = libc::winsize {
            ws_row: if rows == 0 { DEFAULT_ROWS } else { rows },
            ws_col: if columns == 0 {
                DEFAULT_COLUMNS
            } else {
                columns
            },
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let mut master: libc::c_int = -1;
        let pid = unsafe { forkpty(&mut master, std::ptr::null_mut(), std::ptr::null(), &size) };

        if pid < 0 {
            let err = std::io::Error::last_os_error();
            unsafe {
                libc::close(err_read);
                libc::close(err_write);
            }
            return Err(PtyError::ForkPty(err));
        }

        if pid == 0 {
            // Child. Everything from here to execve must be async-signal-safe: this is a forked
            // process, so allocating or taking a lock the parent held risks a deadlock rather than
            // an error. All the CStrings were built before the fork for exactly that reason.
            unsafe {
                libc::close(err_read);

                let mut empty: libc::sigset_t = std::mem::zeroed();
                libc::sigemptyset(&mut empty);
                libc::sigprocmask(libc::SIG_SETMASK, &empty, std::ptr::null_mut());
                for signal in RESET_SIGNALS {
                    libc::signal(signal, libc::SIG_DFL);
                }

                if let Some(dir) = &c_cwd {
                    if libc::chdir(dir.as_ptr()) != 0 {
                        let home = libc::getenv(c"HOME".as_ptr());
                        if home.is_null() || libc::chdir(home) != 0 {
                            libc::chdir(c"/".as_ptr());
                        }
                    }
                }

                libc::execve(c_program.as_ptr(), argv.as_ptr(), envp.as_ptr());

                // Only reachable when execve failed.
                let failure = errno_value();
                let bytes = failure.to_ne_bytes();
                libc::write(
                    err_write,
                    bytes.as_ptr() as *const libc::c_void,
                    bytes.len(),
                );
                libc::_exit(127);
            }
        }

        // Parent. Close our copy of the write end BEFORE reading: the child's copy closing on a
        // successful exec is only observable as EOF if no other descriptor holds the pipe open,
        // and ours would, so the read below would block forever.
        unsafe { libc::close(err_write) };
        let mut buffer = [0u8; 4];
        let mut total = 0usize;
        while total < buffer.len() {
            let n = unsafe {
                libc::read(
                    err_read,
                    buffer.as_mut_ptr().add(total) as *mut libc::c_void,
                    buffer.len() - total,
                )
            };
            if n > 0 {
                total += n as usize;
                continue;
            }
            if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            break;
        }
        unsafe { libc::close(err_read) };

        if total > 0 {
            let raw = i32::from_ne_bytes(buffer);
            unsafe {
                libc::close(master);
                // Reap the child that already _exit(127)'d, so a failed spawn leaves no zombie.
                let mut status = 0;
                libc::waitpid(pid, &mut status, 0);
            }
            return Err(PtyError::Exec {
                program: program.to_string_lossy().into_owned(),
                source: std::io::Error::from_raw_os_error(raw),
            });
        }

        set_nonblocking(master);
        set_cloexec(master);
        Ok(Pty { master, pid })
    }

    pub fn master_fd(&self) -> libc::c_int {
        self.master
    }

    pub fn child_pid(&self) -> libc::pid_t {
        self.pid
    }

    pub fn resize(&self, columns: u16, rows: u16) -> std::io::Result<()> {
        let size = libc::winsize {
            ws_row: if rows == 0 { DEFAULT_ROWS } else { rows },
            ws_col: if columns == 0 {
                DEFAULT_COLUMNS
            } else {
                columns
            },
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        let rc = unsafe { libc::ioctl(self.master, libc::TIOCSWINSZ, &size) };
        if rc != 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(())
    }

    /// The process group currently in the foreground of this pty — the one that owns the screen,
    /// and therefore the one whose name and cwd the title should reflect.
    ///
    /// Note what this cannot see: a child that calls `setsid` escapes the pty's foreground group
    /// entirely. `SessionPTY.swift`'s own `terminationTargets` comment documents the same escape.
    /// It is a real limit of the mechanism, not a bug in this call.
    pub fn foreground_pgid(&self) -> Option<libc::pid_t> {
        let group = unsafe { libc::tcgetpgrp(self.master) };
        (group > 0).then_some(group)
    }

    /// Non-blocking; `Ok(0)` means the child has gone.
    pub fn read(&self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let n = unsafe {
            libc::read(
                self.master,
                buffer.as_mut_ptr() as *mut libc::c_void,
                buffer.len(),
            )
        };
        if n < 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(n as usize)
    }

    pub fn write(&self, bytes: &[u8]) -> std::io::Result<usize> {
        let n = unsafe {
            libc::write(
                self.master,
                bytes.as_ptr() as *const libc::c_void,
                bytes.len(),
            )
        };
        if n < 0 {
            return Err(std::io::Error::last_os_error());
        }
        Ok(n as usize)
    }

    /// Blocks until the child exits, returning its status. Returns `None` if it was already reaped.
    pub fn wait(&self) -> Option<i32> {
        let mut status = 0;
        let rc = unsafe { libc::waitpid(self.pid, &mut status, 0) };
        (rc == self.pid).then_some(status)
    }
}

impl Drop for Pty {
    fn drop(&mut self) {
        if self.master >= 0 {
            unsafe { libc::close(self.master) };
        }
    }
}

/// The libc crate names errno's location differently per platform, and this is called from a
/// forked child where only async-signal-safe work is allowed — so it reads the raw location
/// rather than going through `std::io::Error`.
#[inline]
fn errno_value() -> i32 {
    #[cfg(target_vendor = "apple")]
    unsafe {
        *libc::__error()
    }
    #[cfg(not(target_vendor = "apple"))]
    unsafe {
        *libc::__errno_location()
    }
}

fn set_cloexec(fd: libc::c_int) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags >= 0 {
            libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
        }
    }
}

fn set_nonblocking(fd: libc::c_int) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags >= 0 {
            libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }
    }
}

// glibc puts forkpty in libutil; musl and Darwin put it in libc.
#[cfg_attr(target_env = "gnu", link(name = "util"))]
extern "C" {
    fn forkpty(
        amaster: *mut libc::c_int,
        name: *mut libc::c_char,
        termp: *const libc::termios,
        winp: *const libc::winsize,
    ) -> libc::pid_t;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::ffi::OsStringExt;
    use std::time::{Duration, Instant};

    fn env() -> Vec<(OsString, OsString)> {
        vec![
            (OsString::from("TERM"), OsString::from("xterm-256color")),
            (OsString::from("PATH"), OsString::from("/usr/bin:/bin")),
        ]
    }

    /// Reads until `needle` appears or the deadline passes. The master is non-blocking, so EAGAIN
    /// is the normal "nothing yet" answer rather than an error.
    fn read_until(pty: &Pty, needle: &str, timeout: Duration) -> String {
        let deadline = Instant::now() + timeout;
        let mut seen = String::new();
        let mut buffer = [0u8; 4096];
        while Instant::now() < deadline {
            match pty.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => {
                    seen.push_str(&String::from_utf8_lossy(&buffer[..n]));
                    if seen.contains(needle) {
                        break;
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(_) => break,
            }
        }
        seen
    }

    /// The ordinary exec convention: argv[0] repeats the program path.
    ///
    /// Wraps `Pty::spawn` so the tests that do not care about argv[0] do not have to say so. The
    /// ones that DO care call `Pty::spawn` directly.
    fn spawn(
        program: &OsStr,
        args: &[OsString],
        env: &[(OsString, OsString)],
        cwd: Option<&OsStr>,
        columns: u16,
        rows: u16,
    ) -> Result<Pty, PtyError> {
        Pty::spawn(program, None, args, env, cwd, columns, rows)
    }

    #[test]
    fn argv0_is_what_the_caller_says_it_is() {
        // The whole point of the parameter: a shell reads argv[0] to decide it is a login shell,
        // and `$0` is how that is observable from inside it.
        let pty = Pty::spawn(
            OsStr::new("/bin/sh"),
            Some(OsStr::new("-sh")),
            &[OsString::from("-c"), OsString::from("printf %s \"$0\"")],
            &env(),
            None,
            80,
            24,
        )
        .expect("spawn");
        assert_eq!(
            read_until(&pty, "-sh", Duration::from_secs(5)).trim(),
            "-sh"
        );
    }

    #[test]
    fn runs_a_command_and_reads_its_output() {
        let pty = spawn(
            OsStr::new("/bin/echo"),
            &[OsString::from("hello-from-pty")],
            &env(),
            None,
            80,
            24,
        )
        .expect("spawn");
        let output = read_until(&pty, "hello-from-pty", Duration::from_secs(5));
        assert!(output.contains("hello-from-pty"), "got {output:?}");
    }

    /// The reason the self-pipe exists. Without it this spawn "succeeds" and the session closes
    /// moments later, indistinguishable from a shell that exited on its own.
    #[test]
    fn reports_exec_failure_rather_than_a_live_session() {
        let result = spawn(OsStr::new("/nonexistent/shell"), &[], &env(), None, 80, 24);
        match result {
            Err(PtyError::Exec { program, source }) => {
                assert!(program.contains("nonexistent"));
                assert_eq!(source.raw_os_error(), Some(libc::ENOENT));
            }
            other => panic!("expected an exec failure, got {other:?}"),
        }
    }

    #[test]
    fn spawns_in_the_requested_directory() {
        let pty = spawn(
            OsStr::new("/bin/pwd"),
            &[],
            &env(),
            Some(OsStr::new("/tmp")),
            80,
            24,
        )
        .expect("spawn");
        let output = read_until(&pty, "tmp", Duration::from_secs(5));
        assert!(output.contains("tmp"), "got {output:?}");
    }

    /// A workroom directory deleted while the session was detached must still yield a working
    /// shell, not a dead session.
    #[test]
    fn falls_back_when_the_directory_is_gone() {
        let pty = spawn(
            OsStr::new("/bin/pwd"),
            &[],
            &env(),
            Some(OsStr::new("/definitely/not/here")),
            80,
            24,
        )
        .expect("a missing cwd must not fail the spawn");
        let output = read_until(&pty, "/", Duration::from_secs(5));
        assert!(output.contains('/'), "got {output:?}");
    }

    #[test]
    fn reports_the_size_it_was_given() {
        let pty = spawn(
            OsStr::new("/bin/sh"),
            &[OsString::from("-c"), OsString::from("stty size; exit")],
            &env(),
            None,
            120,
            40,
        )
        .expect("spawn");
        let output = read_until(&pty, "40 120", Duration::from_secs(5));
        assert!(output.contains("40 120"), "got {output:?}");
    }

    /// Zero is the "client has no size yet" sentinel, and a pty of 0x0 makes full-screen programs
    /// misbehave rather than fail, so it is replaced rather than passed through.
    #[test]
    fn substitutes_a_default_for_a_zero_size() {
        let pty = spawn(
            OsStr::new("/bin/sh"),
            &[OsString::from("-c"), OsString::from("stty size; exit")],
            &env(),
            None,
            0,
            0,
        )
        .expect("spawn");
        let output = read_until(&pty, "24 80", Duration::from_secs(5));
        assert!(output.contains("24 80"), "got {output:?}");
    }

    #[test]
    fn resize_reaches_the_child() {
        let pty = spawn(
            OsStr::new("/bin/sh"),
            &[
                OsString::from("-c"),
                // Wait for the resize, then report. `stty size` before it would race.
                OsString::from("sleep 0.4; stty size; exit"),
            ],
            &env(),
            None,
            80,
            24,
        )
        .expect("spawn");
        pty.resize(100, 30).expect("resize");
        let output = read_until(&pty, "30 100", Duration::from_secs(5));
        assert!(output.contains("30 100"), "got {output:?}");
    }

    #[test]
    fn reports_the_foreground_process() {
        let pty = spawn(
            OsStr::new("/bin/sh"),
            &[OsString::from("-c"), OsString::from("sleep 2")],
            &env(),
            None,
            80,
            24,
        )
        .expect("spawn");
        // The pty's foreground group exists as soon as the child is session leader.
        let mut pgid = None;
        for _ in 0..50 {
            pgid = pty.foreground_pgid();
            if pgid.is_some() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let pgid = pgid.expect("a foreground process group");
        assert!(pgid > 0);
        assert!(crate::process::executable_name(pgid).is_some());
    }

    #[test]
    fn input_written_to_the_master_reaches_the_child() {
        let pty = spawn(
            OsStr::new("/bin/sh"),
            &[
                OsString::from("-c"),
                OsString::from("read line; echo got:$line"),
            ],
            &env(),
            None,
            80,
            24,
        )
        .expect("spawn");
        std::thread::sleep(Duration::from_millis(200));
        pty.write(b"ping\n").expect("write");
        let output = read_until(&pty, "got:ping", Duration::from_secs(5));
        assert!(output.contains("got:ping"), "got {output:?}");
    }

    #[test]
    fn rejects_an_interior_nul_rather_than_truncating() {
        let bad = OsString::from_vec(b"/bin/sh\0extra".to_vec());
        assert!(matches!(
            spawn(&bad, &[], &env(), None, 80, 24),
            Err(PtyError::InteriorNul("program"))
        ));
    }
}
