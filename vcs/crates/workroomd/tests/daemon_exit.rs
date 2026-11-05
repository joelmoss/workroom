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
