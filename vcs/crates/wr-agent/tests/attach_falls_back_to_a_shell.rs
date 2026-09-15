//! An agent that passes the app's health probe and then fails to serve must still leave the user a
//! working terminal.
//!
//! **Why this is not covered by the probe.** `SessionBackendProbe` (macapp) runs `wr-agent protocol`
//! and parses a version string. That answers "can this binary start and print", not "can it serve a
//! session": a stale socket it cannot bind, a peer it cannot negotiate with, a crash between the
//! two — all pass the probe and fail here. And by the time `wr-agent attach` runs, the app has
//! already chosen; `applyPersistentSession` set libghostty's `config.command`, and
//! `config.wait_after_command` is false, so a relay that exits leaves a pane with no shell in it at
//! all. Nothing the app can do at that point recovers it, which is why the relay execs a shell.
//!
//! The claim under test is the one the eng review said was not established: *if the agent breaks,
//! you still get a working terminal.*

use std::io::{Read, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn agent_binary() -> PathBuf {
    match std::env::var_os("WR_AGENT_BIN") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(env!("CARGO_BIN_EXE_wr-agent")),
    }
}

/// A short directory: a unix socket address is capped at 104 bytes and cargo's target dir is long.
fn scratch(name: &str) -> PathBuf {
    let dir = PathBuf::from(format!("/tmp/wr-fb-{}-{}", name, std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

/// Runs `wr-agent attach` with the app's environment contract and returns (stdout+stderr, code).
fn attach(env: &[(&str, &str)]) -> (String, Option<i32>) {
    let mut command = Command::new(agent_binary());
    command.arg("attach");
    command.env_clear();
    command.env("PATH", "/usr/bin:/bin");
    for (key, value) in env {
        command.env(key, value);
    }
    command.stdin(Stdio::null());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    let mut child = command.spawn().expect("spawn attach");

    let mut out = String::new();
    let mut err = String::new();
    child
        .stdout
        .take()
        .expect("stdout")
        .read_to_string(&mut out)
        .expect("read stdout");
    child
        .stderr
        .take()
        .expect("stderr")
        .read_to_string(&mut err)
        .expect("read stderr");
    let status = child.wait().expect("wait");
    (format!("{out}{err}"), status.code())
}

/// The realistic shape of "passed the probe, failed at attach": something IS listening on the
/// socket — so the client connects, exactly as it would to a healthy agent — and then the peer goes
/// away without negotiating. Before the fallback this exited 92 and the pane was dead.
#[test]
fn a_peer_that_cannot_negotiate_still_leaves_a_working_shell() {
    let dir = scratch("negotiate");
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).expect("bind fake agent");

    // Accept one connection and drop it immediately: connect succeeds, the handshake cannot.
    let accepter = std::thread::spawn(move || {
        if let Ok((stream, _)) = listener.accept() {
            drop(stream);
        }
    });

    let (output, code) = attach(&[
        (
            "WORKROOM_SESSION_ID",
            "6B9B968D-0BD7-4172-850A-A373DA73BC70",
        ),
        ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
        ("WORKROOM_SESSION_SHELL", "/bin/sh"),
        ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
        // A command rather than an interactive shell, only so the test has something to observe:
        // the fallback path is identical, and an interactive `sh -l` on a null stdin would exit
        // immediately with nothing to assert on.
        ("WORKROOM_SESSION_COMMAND", "echo FELL-BACK-TO-SHELL"),
    ]);
    let _ = accepter.join();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("FELL-BACK-TO-SHELL"),
        "attach did not become a shell after the peer refused to negotiate; the pane would be \
         dead. got: {output:?}"
    );
    assert_eq!(
        code,
        Some(0),
        "the shell's own status must be the process's, so the pane behaves like a normal terminal"
    );
    assert!(
        output.contains("will not survive quitting"),
        "the user must be told persistence was lost, or they find out by losing work. got: \
         {output:?}"
    );
}

/// Nothing listening at all, and no agent can be started there because the directory does not
/// exist. Slower than the test above (it waits out the spawn deadline), so it is the second case
/// rather than the first.
#[test]
fn an_agent_that_cannot_be_started_still_leaves_a_working_shell() {
    let dir = scratch("nostart");
    let socket = dir.join("missing").join("a.sock");

    let (output, code) = attach(&[
        (
            "WORKROOM_SESSION_ID",
            "6B9B968D-0BD7-4172-850A-A373DA73BC70",
        ),
        ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
        ("WORKROOM_SESSION_SHELL", "/bin/sh"),
        ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
        ("WORKROOM_SESSION_COMMAND", "echo FELL-BACK-TO-SHELL"),
    ]);
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("FELL-BACK-TO-SHELL"),
        "attach did not become a shell when no agent could be started. got: {output:?}"
    );
    assert_eq!(code, Some(0));
}

/// A malformed invocation — the app resolved a command but not an environment — is also a dead pane
/// without the fallback. `PersistentSessionService` builds the two from separate resolutions, so
/// this state is reachable rather than hypothetical.
#[test]
fn a_missing_session_id_still_leaves_a_working_shell() {
    let dir = scratch("nosession");
    let (output, code) = attach(&[
        (
            "WORKROOM_SESSION_SOCKET",
            dir.join("a.sock").to_str().unwrap(),
        ),
        ("WORKROOM_SESSION_SHELL", "/bin/sh"),
        ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
        ("WORKROOM_SESSION_COMMAND", "echo FELL-BACK-TO-SHELL"),
    ]);
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("FELL-BACK-TO-SHELL"),
        "attach with no session id must open a shell, not exit. got: {output:?}"
    );
    assert_eq!(code, Some(0));
}

/// The fallback runs in the directory the pane asked for. A shell that opens in the wrong place is
/// a visibly broken terminal even though it is a working one.
/// Same trap as the test below it: an absent socket in an existing directory spawns a REAL agent,
/// which also runs `pwd` in the right place, so this passed without the fallback ever running.
#[test]
fn the_fallback_shell_starts_in_the_requested_directory() {
    let dir = scratch("cwd");
    let canonical = std::fs::canonicalize(&dir).expect("canonicalize");
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).expect("bind fake agent");
    let accepter = std::thread::spawn(move || {
        if let Ok((stream, _)) = listener.accept() {
            drop(stream);
        }
    });

    let (output, _) = attach(&[
        (
            "WORKROOM_SESSION_ID",
            "6B9B968D-0BD7-4172-850A-A373DA73BC70",
        ),
        ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
        ("WORKROOM_SESSION_SHELL", "/bin/sh"),
        ("WORKROOM_SESSION_CWD", canonical.to_str().unwrap()),
        ("WORKROOM_SESSION_COMMAND", "pwd"),
    ]);
    let _ = accepter.join();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("will not survive quitting"),
        "the fallback did not fire, so this test is asserting nothing. got: {output:?}"
    );
    assert!(
        output.contains(canonical.to_str().unwrap()),
        "the fallback shell did not start in the pane's directory. got: {output:?}"
    );
}

/// The session variables are stripped before exec, so nothing downstream — a shell hook, a nested
/// `wr-agent`, the app's own shell integration — believes it is inside a session that does not
/// exist.
///
/// Must use the non-negotiating peer, not merely an absent socket. An absent socket in a directory
/// that EXISTS makes the client spawn a real agent, which serves the session perfectly well — the
/// first draft of this test did that, saw the variables, and blamed the fallback for a path it had
/// never reached. The fallback has to actually fire for this assertion to mean anything.
#[test]
fn the_fallback_shell_does_not_inherit_the_session_variables() {
    let dir = scratch("env");
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).expect("bind fake agent");
    let accepter = std::thread::spawn(move || {
        if let Ok((stream, _)) = listener.accept() {
            drop(stream);
        }
    });

    let (output, _) = attach(&[
        (
            "WORKROOM_SESSION_ID",
            "6B9B968D-0BD7-4172-850A-A373DA73BC70",
        ),
        ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
        ("WORKROOM_SESSION_SHELL", "/bin/sh"),
        ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
        (
            "WORKROOM_SESSION_COMMAND",
            "echo id=[${WORKROOM_SESSION_ID:-unset}] sock=[${WORKROOM_SESSION_SOCKET:-unset}]",
        ),
    ]);
    let _ = accepter.join();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("will not survive quitting"),
        "the fallback did not fire, so this test is asserting nothing. got: {output:?}"
    );
    assert!(
        output.contains("id=[unset]") && output.contains("sock=[unset]"),
        "the fallback shell inherited session variables for a session it is not in. got: \
         {output:?}"
    );
}

/// Negative control. Without this, every assertion above would pass just as well against a relay
/// that ALWAYS execs a shell and never attaches to anything — which would be a total regression
/// wearing the fallback's clothes.
#[test]
fn a_healthy_agent_is_not_replaced_by_a_shell() {
    let dir = scratch("healthy");
    let socket = dir.join("a.sock");

    let mut agent = Command::new(agent_binary())
        .arg("serve")
        .arg("--socket")
        .arg(&socket)
        .arg("--idle-timeout")
        .arg("30")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn agent");

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !socket.exists() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(socket.exists(), "the agent never bound its socket");

    let (output, _) = attach(&[
        (
            "WORKROOM_SESSION_ID",
            "6B9B968D-0BD7-4172-850A-A373DA73BC71",
        ),
        ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
        ("WORKROOM_SESSION_SHELL", "/bin/sh"),
        ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
        ("WORKROOM_SESSION_COMMAND", "echo RAN-IN-A-SESSION"),
    ]);

    let _ = agent.kill();
    let _ = agent.wait();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("RAN-IN-A-SESSION"),
        "a healthy agent should have run the command in a session. got: {output:?}"
    );
    assert!(
        !output.contains("will not survive quitting"),
        "a healthy attach must NOT print the fallback notice — the fallback is firing when it \
         should not, and every other test here would pass anyway. got: {output:?}"
    );
}

/// Keeps the unused-import lint honest about `Write`, which the fake peer does not need but a
/// future one will. Deliberately trivial.
#[test]
fn scratch_directories_are_writable() {
    let dir = scratch("writable");
    let path = dir.join("probe");
    let mut file = std::fs::File::create(&path).expect("create");
    file.write_all(b"ok").expect("write");
    let _ = std::fs::remove_dir_all(&dir);
}
