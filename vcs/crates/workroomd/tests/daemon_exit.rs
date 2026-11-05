//! Every way `serve` ends writes a line to `workroomd.log`, so a daemon that is gone says how: a
//! Nightly daemon once vanished with eleven sessions and left no line, no crash report and no
//! status to say whether it was killed, idled out or panicked.

#[allow(dead_code)] // not every helper is used here
mod common;

use std::os::unix::process::ExitStatusExt;
use std::process::{Command, Stdio};
use std::time::Duration;

use common::{Spawned, Workspace, daemon_binary, wait_for};

/// Spawned the way the app spawns one: stderr to /dev/null, so only the log can say anything.
fn serve(socket: &std::path::Path, idle: &str) -> Spawned {
    Spawned(
        Command::new(daemon_binary())
            .args(["serve", "--socket"])
            .arg(socket)
            .args(["--idle-timeout", idle])
            .env("SHELL", "/bin/sh")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn daemon"),
    )
}

fn exit_of(daemon: &mut Spawned) -> Option<std::process::ExitStatus> {
    let mut status = None;
    wait_for(Duration::from_secs(10), || {
        status = daemon.try_wait().expect("wait");
        status.is_some()
    });
    status
}

#[test]
fn a_signal_that_ends_the_daemon_is_logged_and_still_ends_it() {
    let workspace = Workspace::new("exit-signal");
    let socket = workspace.socket();
    let mut daemon = serve(&socket, "60");
    assert!(wait_for(Duration::from_secs(5), || socket.exists()));

    // SAFETY: a plain kill of the child this test spawned.
    unsafe { libc::kill(daemon.id() as i32, libc::SIGTERM) };
    let status = exit_of(&mut daemon).expect("the daemon outlived SIGTERM");
    let log = std::fs::read_to_string(socket.with_extension("log")).unwrap_or_default();
    assert_eq!(status.signal(), Some(libc::SIGTERM), "{status:?}");
    assert!(
        log.contains("killed by signal 15 (SIGTERM); exiting"),
        "{log}"
    );
}

/// `start.sh` runs an SSH host's daemon under `nohup`: a SIGHUP it was started ignoring must stay
/// harmless, not become a logged exit that takes every session with it.
#[test]
fn a_signal_the_daemon_was_started_ignoring_stays_ignored() {
    let workspace = Workspace::new("exit-ignored");
    let socket = workspace.socket();
    let mut daemon = Spawned(
        Command::new("/bin/sh")
            .arg("-c")
            .arg("trap '' HUP; exec \"$0\" serve --socket \"$1\" --idle-timeout 60")
            .arg(daemon_binary())
            .arg(&socket)
            .env("SHELL", "/bin/sh")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn daemon"),
    );
    assert!(wait_for(Duration::from_secs(5), || socket.exists()));

    // SAFETY: a plain kill of the child this test spawned.
    unsafe { libc::kill(daemon.id() as i32, libc::SIGHUP) };
    std::thread::sleep(Duration::from_millis(500));
    let log = std::fs::read_to_string(socket.with_extension("log")).unwrap_or_default();
    assert!(daemon.try_wait().expect("wait").is_none(), "{log}");
    assert!(!log.contains("SIGHUP"), "{log}");
}

/// A stderr that blocks (a supervisor's pipe nobody drains) costs the line, never the exit.
#[test]
fn a_signal_still_ends_a_daemon_whose_stderr_is_full() {
    use std::os::fd::{FromRawFd, OwnedFd};
    let workspace = Workspace::new("exit-full-stderr");
    let socket = workspace.socket();
    let mut fds = [0; 2];
    // SAFETY: `fds` is a live two-element array, as `pipe` requires.
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
    // SAFETY: both descriptors were just made by `pipe` and nothing else owns them.
    let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    // Fill the pipe, so the daemon's first line blocks with the stderr lock held.
    // SAFETY: plain integers on a descriptor this test owns.
    unsafe { libc::fcntl(fds[1], libc::F_SETFL, libc::O_NONBLOCK) };
    let chunk = [b'x'; 4096];
    loop {
        // SAFETY: the pointer and length come from one live array.
        let written = unsafe { libc::write(fds[1], chunk.as_ptr().cast(), chunk.len()) };
        if written <= 0 {
            break;
        }
    }
    // SAFETY: as above.
    unsafe { libc::fcntl(fds[1], libc::F_SETFL, 0) };
    let mut daemon = Spawned(
        Command::new(daemon_binary())
            .args(["serve", "--socket"])
            .arg(&socket)
            .args(["--idle-timeout", "60"])
            .env("SHELL", "/bin/sh")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::from(write))
            .spawn()
            .expect("spawn daemon"),
    );
    assert!(wait_for(Duration::from_secs(5), || socket.exists()));
    std::thread::sleep(Duration::from_millis(200));

    // SAFETY: a plain kill of the child this test spawned.
    unsafe { libc::kill(daemon.id() as i32, libc::SIGTERM) };
    let status = exit_of(&mut daemon).expect("a full stderr kept the daemon from SIGTERM");
    drop(read);
    assert_eq!(status.signal(), Some(libc::SIGTERM), "{status:?}");
}

#[test]
fn an_idle_exit_is_logged() {
    let workspace = Workspace::new("exit-idle");
    let socket = workspace.socket();
    let mut daemon = serve(&socket, "1");
    let status = exit_of(&mut daemon).expect("the daemon never idled out");
    let log = std::fs::read_to_string(socket.with_extension("log")).unwrap_or_default();
    assert!(status.success(), "{status:?}");
    assert!(
        log.contains("exiting: no session or client for 1s"),
        "{log}"
    );
}

#[test]
fn a_daemon_that_finds_one_serving_says_so_and_leaves() {
    let workspace = Workspace::new("exit-race");
    let socket = workspace.socket();
    let _running = serve(&socket, "60");
    assert!(wait_for(Duration::from_secs(5), || socket.exists()));

    let mut second = serve(&socket, "60");
    let status = exit_of(&mut second).expect("the second daemon kept running");
    let log = std::fs::read_to_string(socket.with_extension("log")).unwrap_or_default();
    assert!(status.success(), "{status:?}");
    assert!(
        log.contains(&format!(
            "[{}] not serving {}: another daemon already is",
            second.id(),
            socket.display()
        )),
        "{log}"
    );
}

#[test]
fn a_bad_idle_timeout_is_logged_even_with_no_stderr() {
    let workspace = Workspace::new("exit-flag");
    let socket = workspace.socket();
    let mut daemon = serve(&socket, "soon");
    let status = exit_of(&mut daemon).expect("the daemon ran with a bad flag");
    let log = std::fs::read_to_string(socket.with_extension("log")).unwrap_or_default();
    assert_eq!(status.code(), Some(1), "{status:?}");
    assert!(
        log.contains("error: --idle-timeout takes seconds or `never`"),
        "{log}"
    );
}
