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

use std::io::Read;
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
    attach_inner(env, None)
}

/// Same, but feeding the exec'd shell a script on stdin — the only way to observe the INTERACTIVE
/// branch, which takes no command argument by definition.
fn attach_with_stdin(env: &[(&str, &str)], stdin: &str) -> (String, Option<i32>) {
    attach_inner(env, Some(stdin))
}

fn attach_inner(env: &[(&str, &str)], stdin: Option<&str>) -> (String, Option<i32>) {
    let mut command = Command::new(agent_binary());
    command.arg("attach");
    command.env_clear();
    command.env("PATH", "/usr/bin:/bin");
    for (key, value) in env {
        command.env(key, value);
    }
    command.stdin(if stdin.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    });
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    let mut child = command.spawn().expect("spawn attach");
    if let Some(script) = stdin {
        use std::io::Write;
        let mut handle = child.stdin.take().expect("stdin");
        let _ = handle.write_all(script.as_bytes());
        // Closing it is what ends the interactive shell; without this the test hangs.
        drop(handle);
    }

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
        // A command, so this test has something to observe. The two branches are NOT identical —
        // an earlier comment here claimed they were — so the interactive one, which is the only
        // one the app can actually reach, is covered separately by
        // `the_interactive_fallback_is_a_real_login_shell`.
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

/// A malformed invocation is also a dead pane without the fallback. Note this needs the app to have
/// invoked us — `WORKROOM_SESSION_SOCKET` is set here — because a hand-run `attach` reports usage
/// instead; see `a_hand_run_attach_reports_usage_instead_of_opening_a_shell`.
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

/// **The branch production actually takes.** Every other test here sets
/// `WORKROOM_SESSION_COMMAND`, because a command gives the test something to observe — but
/// `PersistentSessionService` hardcodes that variable to `""`, and a pane with a run command never
/// gets a persistent session at all. So the interactive branch is the ONLY one the app can reach,
/// and it was the one branch with no coverage. The two differ by more than an argument now:
/// `shell::invocation` gives the interactive case a `-`-prefixed `argv[0]` and the shell-integration
/// environment, and the command case a POSIX `/bin/sh -c "exec …"`.
///
/// Asserted through `argv[0]`, which is what makes a login shell — there is no flag for it.
#[test]
fn the_interactive_fallback_is_a_real_login_shell() {
    let dir = scratch("login");
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).expect("bind fake agent");
    let accepter = std::thread::spawn(move || {
        if let Ok((stream, _)) = listener.accept() {
            drop(stream);
        }
    });

    // `-c` on the exec'd shell would take the command branch, so the login shell is driven the way
    // a pane drives it — over stdin — and asked to report its own argv[0].
    let (output, _) = attach_with_stdin(
        &[
            (
                "WORKROOM_SESSION_ID",
                "6B9B968D-0BD7-4172-850A-A373DA73BC70",
            ),
            ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
            ("WORKROOM_SESSION_SHELL", "/bin/sh"),
            ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
            // Empty, exactly as PersistentSessionService.launchEnvironment sets it.
            ("WORKROOM_SESSION_COMMAND", ""),
        ],
        "printf 'argv0=[%s]\\n' \"$0\"; printf 'fallback=[%s]\\n' \"${WORKROOM_SESSION_FALLBACK:-unset}\"\n",
    );
    let _ = accepter.join();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("will not survive quitting"),
        "the fallback did not fire, so this test is asserting nothing. got: {output:?}"
    );
    assert!(
        output.contains("argv0=[-sh]"),
        "the fallback shell is not a LOGIN shell: argv[0] must be the shell's name prefixed with \
         a dash, which is the only thing that makes it one. got: {output:?}"
    );
    assert!(
        output.contains("fallback=[1]"),
        "the exec'd shell must carry WORKROOM_SESSION_FALLBACK so the loss of persistence is \
         visible to more than one scrollable line. got: {output:?}"
    );
}

/// A session variable must not survive into the fallback shell, and the marker must.
#[test]
fn the_fallback_shell_reports_no_session_but_does_report_the_fallback() {
    let dir = scratch("marker");
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
            "echo id=[${WORKROOM_SESSION_ID:-unset}] fb=[${WORKROOM_SESSION_FALLBACK:-unset}]",
        ),
    ]);
    let _ = accepter.join();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("id=[unset]") && output.contains("fb=[1]"),
        "expected the session id stripped and the fallback marker set. got: {output:?}"
    );
}

/// A pane whose directory has been deleted must still get a shell.
///
/// `chdir` happens INSIDE `exec`, so a missing directory aborts it — and the relay then reported
/// "could not start /bin/zsh", blaming the shell, and exited 92: the dead pane the fallback exists
/// to prevent, in the one case where the user most needs it. Deleting a workroom while a tab is
/// open is a supported operation.
#[test]
fn a_deleted_working_directory_still_leaves_a_working_shell() {
    let dir = scratch("gonecwd");
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).expect("bind fake agent");
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
        (
            "WORKROOM_SESSION_CWD",
            "/tmp/wr-this-directory-does-not-exist",
        ),
        ("WORKROOM_SESSION_COMMAND", "echo FELL-BACK-TO-SHELL"),
    ]);
    let _ = accepter.join();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("FELL-BACK-TO-SHELL"),
        "a deleted working directory aborted the exec and produced a dead pane. got: {output:?}"
    );
    assert_eq!(code, Some(0));
}

/// Typed at a prompt rather than forked into a pane, `attach` must report usage — not silently
/// open a nested login shell inside the user's current one. Same reasoning `list` uses.
#[test]
fn a_hand_run_attach_reports_usage_instead_of_opening_a_shell() {
    let mut command = Command::new(agent_binary());
    command.arg("attach");
    command.env_clear();
    command.env("PATH", "/usr/bin:/bin");
    command.env("SHELL", "/bin/sh");
    command.stdin(Stdio::null());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    let output = command.output().expect("run attach");

    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        combined.contains("attach needs"),
        "a hand-run attach must explain itself. got: {combined:?}"
    );
    assert!(
        !combined.contains("will not survive quitting"),
        "a hand-run attach must not open a fallback shell. got: {combined:?}"
    );
    assert_ne!(output.status.code(), Some(0));
}

/// Negative control. Without this, every assertion above would pass just as well against a relay
/// that ALWAYS execs a shell and never attaches to anything — which would be a total regression
/// wearing the fallback's clothes.
///
/// The discriminator is the session variable, not the notice string. Asserting only on the absence
/// of "will not survive quitting" leaned on a literal from the same commit; `WORKROOM_SESSION_ID`
/// is passed THROUGH by a real session and STRIPPED by the fallback, so it separates the two
/// regardless of what any message says.
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
        (
            "WORKROOM_SESSION_COMMAND",
            "echo RAN-IN-A-SESSION id=[${WORKROOM_SESSION_ID:-unset}]",
        ),
    ]);

    let _ = agent.kill();
    let _ = agent.wait();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("RAN-IN-A-SESSION"),
        "a healthy agent should have run the command in a session. got: {output:?}"
    );
    assert!(
        !output.contains("id=[unset]"),
        "a real session passes WORKROOM_SESSION_ID through to its shell and the fallback strips \
         it, so an unset id here means the fallback fired against a HEALTHY agent — and every \
         other assertion in this file would pass against a relay that always execs. got: {output:?}"
    );
    assert!(
        !output.contains("will not survive quitting"),
        "a healthy attach must not print the fallback notice. got: {output:?}"
    );
}

/// **The line the fallback must NOT cross.** A `Failure` frame means the agent is TALKING, and the
/// session it is talking about is usually alive — `RepaintFailed` (session.rs) fires only on
/// reattach to a session that already has scrollback, which is precisely the pane holding the
/// user's work, and it explicitly invites a retry. Exec'ing a shell there is unrecoverable (exec is
/// one-way, so the retry can never happen) and hands back a healthy-looking prompt for a session
/// that is still running: the same "failure that looks like success" `confirmBeforeAttach` exists
/// to prevent on the app side.
///
/// An earlier version of `run_attach` made this a fallback, so this is a REGRESSION pin, and it is
/// the only test anywhere that reaches the `FrameKind::Failure` arm.
///
/// `WORKROOM_SESSION_COMMAND` is both the discriminator and the hang guard: in the regression the
/// exec'd shell runs the echo and exits, so the test fails on its assertions rather than blocking.
#[test]
fn a_failure_frame_is_reported_rather_than_replaced_by_a_shell() {
    use std::io::Write;
    use wr_agent::protocol::envelope::{Envelope, Hello, Service};
    use wr_agent::protocol::frame::{Frame, FrameKind};

    let dir = scratch("failure");
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).expect("bind fake agent");

    // A peer that negotiates successfully — so every earlier fallback branch is passed — and then
    // reports a failure, exactly as a session refusing a repaint does.
    let accepter = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        stream
            .write_all(&Hello::current("fake-peer").encode())
            .expect("greet");
        let _ = stream.flush();
        let frame = Frame::new(FrameKind::Failure, b"FAKE-REPAINT-FAILED".to_vec());
        stream
            .write_all(&Envelope::new(Service::Terminal, 1, frame.encode()).encode())
            .expect("failure frame");
        let _ = stream.flush();
        // Held open: closing here would race the client's read and arrive as an EOF instead, which
        // is a different branch and would make this test pass for the wrong reason.
        std::thread::sleep(std::time::Duration::from_secs(3));
    });

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
    let _ = accepter.join();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("FAKE-REPAINT-FAILED"),
        "the agent's failure was not shown to the user, so they cannot know to retry. got: \
         {output:?}"
    );
    assert!(
        !output.contains("FELL-BACK-TO-SHELL"),
        "a Failure frame exec'd a shell. The session is still running and now unreachable from \
         this pane, behind a prompt that looks like a successful reattach. got: {output:?}"
    );
    assert!(
        !output.contains("will not survive quitting"),
        "a Failure frame is not a broken agent and must not print the fallback notice. got: \
         {output:?}"
    );
    assert_eq!(
        code,
        Some(1),
        "a reported failure must exit non-zero so the pane does not look like a clean exit"
    );
}

/// The FIRST `give_up` in `run_attach`, which no other test reaches: the id arrives but the socket
/// does not. Its sibling — socket present, id missing — is
/// `a_missing_session_id_still_leaves_a_working_shell`; both must fall back, because either one
/// alone still means the app invoked us as a pane's command.
#[test]
fn a_missing_session_socket_still_leaves_a_working_shell() {
    let dir = scratch("nosocket");
    let (output, code) = attach(&[
        (
            "WORKROOM_SESSION_ID",
            "6B9B968D-0BD7-4172-850A-A373DA73BC70",
        ),
        ("WORKROOM_SESSION_SHELL", "/bin/sh"),
        ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
        ("WORKROOM_SESSION_COMMAND", "echo FELL-BACK-TO-SHELL"),
    ]);
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("FELL-BACK-TO-SHELL"),
        "attach with no session socket must open a shell, not exit. got: {output:?}"
    );
    assert!(
        output.contains("will not survive quitting"),
        "the fallback did not fire, so this test is asserting nothing. got: {output:?}"
    );
    assert_eq!(code, Some(0));
}

/// `first_usable_directory`'s SECOND rung. `a_deleted_working_directory_still_leaves_a_working_shell`
/// proves the chain does not abort the exec, but it runs with `HOME` unset, so it cannot tell the
/// home fallback from the `/` one — and landing a user in `/` when their home exists is the kind of
/// quietly-wrong terminal nobody reports.
#[test]
fn a_deleted_working_directory_falls_back_to_home_before_root() {
    let dir = scratch("homecwd");
    let home = std::fs::canonicalize(&dir).expect("canonicalize");
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
        (
            "WORKROOM_SESSION_CWD",
            "/tmp/wr-this-directory-does-not-exist",
        ),
        ("HOME", home.to_str().unwrap()),
        ("WORKROOM_SESSION_COMMAND", "pwd"),
    ]);
    let _ = accepter.join();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("will not survive quitting"),
        "the fallback did not fire, so this test is asserting nothing. got: {output:?}"
    );
    assert!(
        output.contains(home.to_str().unwrap()),
        "a pane whose directory was deleted landed somewhere other than the user's home. got: \
         {output:?}"
    );
}
