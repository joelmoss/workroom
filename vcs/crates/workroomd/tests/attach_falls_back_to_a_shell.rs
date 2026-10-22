//! A daemon that passes the app's health probe and then fails to serve must still leave the user a
//! working terminal.
//!
//! **Why this is not covered by the probe.** `SessionBackendProbe` (macapp) runs `workroomd protocol`
//! and parses a version string. That answers "can this binary start and print", not "can it serve a
//! session": a stale socket it cannot bind, a peer it cannot negotiate with, a crash between the
//! two — all pass the probe and fail here. And by the time `workroomd attach` runs, the app has
//! already chosen; `applyPersistentSession` set libghostty's `config.command`, and
//! `config.wait_after_command` is false, so a relay that exits leaves a pane with no shell in it at
//! all. Nothing the app can do at that point recovers it, which is why the relay execs a shell.
//!
//! The claim under test is the one the eng review said was not established: *if the daemon breaks,
//! you still get a working terminal.*

#[allow(dead_code)] // not every helper is used here
mod common;
use common::{Spawned, daemon_binary};

use std::io::Read;
use std::os::unix::net::UnixListener;
use std::path::PathBuf;
use std::process::{Command, Stdio};

/// A short directory: a unix socket address is capped at 104 bytes and cargo's target dir is long.
fn scratch(name: &str) -> PathBuf {
    let dir = PathBuf::from(format!("/tmp/wr-fb-{}-{}", name, std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch dir");
    dir
}

/// Runs `workroomd attach` with the app's environment contract and returns (stdout+stderr, code).
fn attach(env: &[(&str, &str)]) -> (String, Option<i32>) {
    attach_inner(env, None)
}

/// Same, but feeding the exec'd shell a script on stdin — the only way to observe the INTERACTIVE
/// branch, which takes no command argument by definition.
fn attach_with_stdin(env: &[(&str, &str)], stdin: &str) -> (String, Option<i32>) {
    attach_inner(env, Some(stdin))
}

fn attach_inner(env: &[(&str, &str)], stdin: Option<&str>) -> (String, Option<i32>) {
    attach_with_args(&[], env, stdin)
}

fn attach_with_args(
    args: &[&str],
    env: &[(&str, &str)],
    stdin: Option<&str>,
) -> (String, Option<i32>) {
    let mut command = Command::new(daemon_binary());
    command.arg("attach").args(args);
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
/// socket — so the client connects, exactly as it would to a healthy daemon — and then the peer goes
/// away without negotiating. Before the fallback this exited 92 and the pane was dead.
#[test]
fn a_peer_that_cannot_negotiate_still_leaves_a_working_shell() {
    let dir = scratch("negotiate");
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).expect("bind fake daemon");

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

/// Nothing listening, and the spawned daemon cannot start there.
///
/// The guard below is load-bearing and was missing. The reason the daemon fails is NOT "the
/// directory does not exist" — `serve.rs` does `create_dir_all(parent)` before binding. It fails
/// because `acquire_instance_lock` opens `<socket>.lock` first and that ENOENTs. Move the lock
/// below the mkdir, a plausible refactor, and a REAL daemon binds and runs the command, so every
/// assertion below passes without the fallback ever executing. The notice is what proves which
/// path ran.
#[test]
fn a_daemon_that_cannot_be_started_still_leaves_a_working_shell() {
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
        output.contains("will not survive quitting"),
        "the fallback did not fire, so this test is asserting nothing. got: {output:?}"
    );
    assert!(
        output.contains("FELL-BACK-TO-SHELL"),
        "attach did not become a shell when no daemon could be started. got: {output:?}"
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
        output.contains("will not survive quitting"),
        "the fallback did not fire, so this test is asserting nothing. got: {output:?}"
    );
    assert!(
        output.contains("FELL-BACK-TO-SHELL"),
        "attach with no session id must open a shell, not exit. got: {output:?}"
    );
    assert_eq!(code, Some(0));
}

/// The fallback runs in the directory the pane asked for. A shell that opens in the wrong place is
/// a visibly broken terminal even though it is a working one.
/// Same trap as the test below it: an absent socket in an existing directory spawns a REAL daemon,
/// which also runs `pwd` in the right place, so this passed without the fallback ever running.
#[test]
fn the_fallback_shell_starts_in_the_requested_directory() {
    let dir = scratch("cwd");
    let canonical = std::fs::canonicalize(&dir).expect("canonicalize");
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).expect("bind fake daemon");
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
/// `workroomd`, the app's own shell integration — believes it is inside a session that does not
/// exist.
///
/// Must use the non-negotiating peer, not merely an absent socket. An absent socket in a directory
/// that EXISTS makes the client spawn a real daemon, which serves the session perfectly well — the
/// first draft of this test did that, saw the variables, and blamed the fallback for a path it had
/// never reached. The fallback has to actually fire for this assertion to mean anything.
#[test]
fn the_fallback_shell_does_not_inherit_the_session_variables() {
    let dir = scratch("env");
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).expect("bind fake daemon");
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
    let listener = UnixListener::bind(&socket).expect("bind fake daemon");
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

/// Apple's `/bin/bash` was started with `--posix` for an integration it never loads, so it stayed
/// in POSIX mode: `<(…)` was a syntax error. Asserted on the real shell, because the unit test of
/// `shell::invocation` once pinned `--posix` as correct. Stdin is a pipe, so this bash is not
/// interactive; the interactive startup is the live PTY probe's job.
#[cfg(target_os = "macos")]
#[test]
fn apple_bash_is_not_left_in_posix_mode() {
    let dir = scratch("applebash");
    let (output, _) = attach_with_stdin(
        &[
            // A socket and a cwd but no session id: app-invoked, and the fallback shell runs.
            (
                "WORKROOM_SESSION_SOCKET",
                dir.join("a.sock").to_str().unwrap(),
            ),
            ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
            ("WORKROOM_SESSION_SHELL", "/bin/bash"),
            ("WORKROOM_SESSION_COMMAND", ""),
            ("WORKROOM_SESSION_RESOURCES", "/res"),
            // No developer dotfiles.
            ("HOME", dir.to_str().unwrap()),
        ],
        // Separate lines: a syntax error in the second must not stop the first from printing.
        "shopt -o posix\ncat <(echo procsub-ok)\n",
    );
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("will not survive quitting"),
        "the fallback did not fire, so this test is asserting nothing. got: {output:?}"
    );
    assert!(
        output
            .lines()
            .any(|line| line.split_whitespace().eq(["posix", "off"])),
        "Apple bash was left in POSIX mode. got: {output:?}"
    );
    assert!(
        output.contains("procsub-ok"),
        "process substitution failed, which POSIX mode does. got: {output:?}"
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
    let listener = UnixListener::bind(&socket).expect("bind fake daemon");
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
    let mut command = Command::new(daemon_binary());
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

/// REGRESSION. A hand-typed `attach --session <uuid>` must ALSO report usage, not open a shell.
///
/// The classification reads `WORKROOM_SESSION_ID` from the environment, and the `--session` flag
/// WRITES that variable into this process's own environment. Reading the flag first therefore let a
/// hand-typed invocation forge the evidence that classified it as app-invoked, and the only test
/// covering the classifier ran bare `attach` with no flags — so it could not see it. The fix is
/// ordering: the environment is read before any flag can write to it.
#[test]
fn a_hand_run_attach_with_a_session_flag_still_reports_usage() {
    let dir = scratch("handsession");
    let mut command = Command::new(daemon_binary());
    command.arg("attach");
    // `--session` ONLY, deliberately. With a socket as well this never reaches the classifier: it
    // spawns a real daemon, attaches, and sits on an interactive shell forever — and because the
    // daemon is setsid'd while inheriting the test's stdout pipe, `output()` then waits on an EOF
    // that never comes. The classifier is reached exactly when something is missing, which is also
    // the state a typo produces.
    command
        .arg("--session")
        .arg("6B9B968D-0BD7-4172-850A-A373DA73BC70");
    command.env_clear();
    command.env("PATH", "/usr/bin:/bin");
    command.env("SHELL", "/bin/sh");
    command.stdin(Stdio::null());
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    let output = command.output().expect("run attach");
    let _ = std::fs::remove_dir_all(&dir);

    let combined = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        !combined.contains("will not survive quitting"),
        "a flag the user typed classified them as the app and opened a nested login shell inside \
         their own terminal. got: {combined:?}"
    );
    assert!(
        combined.contains("attach needs"),
        "a hand-run attach must explain itself. got: {combined:?}"
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
fn a_healthy_daemon_is_not_replaced_by_a_shell() {
    let dir = scratch("healthy");
    let socket = dir.join("a.sock");

    let mut daemon = Command::new(daemon_binary())
        .arg("serve")
        .arg("--socket")
        .arg(&socket)
        .arg("--idle-timeout")
        .arg("30")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn daemon");

    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !socket.exists() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(socket.exists(), "the daemon never bound its socket");

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
            "echo RAN-IN-A-SESSION fb=[${WORKROOM_SESSION_FALLBACK:-unset}]",
        ),
    ]);

    let _ = daemon.kill();
    let _ = daemon.wait();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        output.contains("RAN-IN-A-SESSION"),
        "a healthy daemon should have run the command in a session. got: {output:?}"
    );
    assert!(
        output.contains("fb=[unset]"),
        "WORKROOM_SESSION_FALLBACK is set ONLY by fall_back_to_shell, so seeing it here means the \
         fallback fired against a HEALTHY daemon — and every other assertion in this file would \
         pass against a relay that always execs. got: {output:?}"
    );
    assert!(
        !output.contains("will not survive quitting"),
        "a healthy attach must not print the fallback notice. got: {output:?}"
    );
}

/// **The line the fallback must NOT cross.** A `Failure` frame means the daemon is TALKING, and the
/// session it is talking about is usually alive — `RepaintFailed` (session.rs) fires only on
/// reattach to a session that already has scrollback, which is precisely the pane holding the
/// user's work, and it explicitly invites a retry. Exec'ing a shell there is unrecoverable (exec is
/// one-way, so the retry can never happen) and hands back a healthy-looking prompt for a session
/// that is still running: the same "failure that looks like success" `--no-create` exists to
/// prevent.
///
/// An earlier version of `run_attach` made this a fallback, so this is a REGRESSION pin, and it is
/// the only test anywhere that reaches the `FrameKind::Failure` arm.
///
/// `WORKROOM_SESSION_COMMAND` is both the discriminator and the hang guard: in the regression the
/// exec'd shell runs the echo and exits, so the test fails on its assertions rather than blocking.
#[test]
fn a_failure_frame_is_reported_rather_than_replaced_by_a_shell() {
    use std::io::Write;
    use wr_protocol::envelope::{Envelope, Hello, Service};
    use wr_protocol::frame::{Frame, FrameKind};

    let dir = scratch("failure");
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).expect("bind fake daemon");

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
        "the daemon's failure was not shown to the user, so they cannot know to retry. got: \
         {output:?}"
    );
    assert!(
        !output.contains("FELL-BACK-TO-SHELL"),
        "a Failure frame exec'd a shell. The session is still running and now unreachable from \
         this pane, behind a prompt that looks like a successful reattach. got: {output:?}"
    );
    assert!(
        !output.contains("will not survive quitting"),
        "a Failure frame is not a broken daemon and must not print the fallback notice. got: \
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
    let listener = UnixListener::bind(&socket).expect("bind fake daemon");
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

/// A healthy daemon on `socket`, killed when the guard drops.
fn start_daemon(socket: &std::path::Path) -> Spawned {
    let daemon = Spawned(
        Command::new(daemon_binary())
            .args(["serve", "--socket"])
            .arg(socket)
            .args(["--idle-timeout", "30"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn daemon"),
    );
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !socket.exists() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(socket.exists(), "the daemon never bound its socket");
    daemon
}

/// `--no-spawn` (a pane on a remote host, #229): with no daemon listening, a shell rather than a
/// spawned daemon. On a remote host the supervisor starts the daemon, and one started here would be
/// the idle-exit kind, racing the supervised one for the socket.
#[test]
fn no_spawn_falls_back_to_a_shell_instead_of_starting_a_daemon() {
    let dir = scratch("no-spawn");
    let socket = dir.join("a.sock");
    let (output, _) = attach_with_args(
        &["--no-spawn"],
        &[
            (
                "WORKROOM_SESSION_ID",
                "6B9B968D-0BD7-4172-850A-A373DA73BC72",
            ),
            ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
            ("WORKROOM_SESSION_SHELL", "/bin/sh"),
            ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
            (
                "WORKROOM_SESSION_COMMAND",
                "echo FELL-BACK fb=[${WORKROOM_SESSION_FALLBACK:-unset}]",
            ),
        ],
        None,
    );
    std::thread::sleep(std::time::Duration::from_millis(500));
    let spawned = socket.exists();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        output.contains("FELL-BACK fb=[1]"),
        "expected the fallback shell. got: {output:?}"
    );
    assert!(!spawned, "a daemon was started despite --no-spawn");
}

/// A restored pane on a remote host (`--no-spawn --no-create`) with no daemon listening yet exits
/// 255, so the app attaches it again. After a reboot sshd can accept before the supervisor's daemon
/// binds, and a shell here would be a live one hiding the session's last screen (#232).
#[test]
fn a_restored_remote_pane_with_no_daemon_yet_exits_255_to_be_retried() {
    let dir = scratch("no-daemon-yet");
    let socket = dir.join("a.sock");
    let (output, status) = attach_with_args(
        &["--no-spawn", "--no-create"],
        &[
            (
                "WORKROOM_SESSION_ID",
                "6B9B968D-0BD7-4172-850A-A373DA73BC77",
            ),
            ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
            ("WORKROOM_SESSION_SHELL", "/bin/sh"),
            ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
            (
                "WORKROOM_SESSION_COMMAND",
                "echo FELL-BACK fb=[${WORKROOM_SESSION_FALLBACK:-unset}]",
            ),
        ],
        None,
    );
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(status, Some(255), "got: {output:?}");
    assert!(
        !output.contains("FELL-BACK"),
        "a shell was started: {output:?}"
    );
}

/// But a peer that answers and cannot negotiate is not a daemon still starting: asking again cannot
/// help, so a restored remote pane gets the shell here, as it did before 255 was ever retried.
#[test]
fn a_restored_remote_pane_whose_peer_cannot_negotiate_gets_a_shell() {
    let dir = scratch("no-daemon-negotiate");
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).expect("bind fake daemon");
    let accepter = std::thread::spawn(move || {
        if let Ok((stream, _)) = listener.accept() {
            drop(stream);
        }
    });
    let (output, status) = attach_with_args(
        &["--no-spawn", "--no-create"],
        &[
            (
                "WORKROOM_SESSION_ID",
                "6B9B968D-0BD7-4172-850A-A373DA73BC78",
            ),
            ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
            ("WORKROOM_SESSION_SHELL", "/bin/sh"),
            ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
            (
                "WORKROOM_SESSION_COMMAND",
                "echo FELL-BACK fb=[${WORKROOM_SESSION_FALLBACK:-unset}]",
            ),
        ],
        None,
    );
    let _ = accepter.join();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(output.contains("FELL-BACK fb=[1]"), "got: {output:?}");
    assert_ne!(status, Some(255), "a broken peer was retried: {output:?}");
}

/// `--no-create` (a restored pane): a session the daemon does not hold is refused, and on this Mac
/// the pane gets a new session under the same id, not a fallback shell. (The app says so in a toast,
/// decided before it attaches.)
#[test]
fn no_create_turns_an_ended_session_into_a_new_one() {
    let dir = scratch("no-create-ended");
    let socket = dir.join("a.sock");
    let _daemon = start_daemon(&socket);
    let (output, _) = attach_with_args(
        &["--no-create"],
        &[
            (
                "WORKROOM_SESSION_ID",
                "6B9B968D-0BD7-4172-850A-A373DA73BC73",
            ),
            ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
            ("WORKROOM_SESSION_SHELL", "/bin/sh"),
            ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
            (
                "WORKROOM_SESSION_COMMAND",
                "sh -c 'sleep 1; echo NEW-SESSION fb=[${WORKROOM_SESSION_FALLBACK:-unset}]'",
            ),
        ],
        None,
    );
    let _ = std::fs::remove_dir_all(&dir);
    assert!(!output.contains("has ended"), "got: {output:?}");
    assert!(
        output.contains("NEW-SESSION fb=[unset]"),
        "expected a new session, not a fallback shell. got: {output:?}"
    );
}

/// #459: once a restored pane's ended session is replaced, its id is live, so the next restore
/// attaches it instead of saying "ended" again.
#[test]
fn a_replaced_ended_session_is_reattached_on_the_next_restore() {
    let dir = scratch("no-create-replaced");
    let socket = dir.join("a.sock");
    let _daemon = start_daemon(&socket);
    let env = [
        (
            "WORKROOM_SESSION_ID",
            "6B9B968D-0BD7-4172-850A-A373DA73BC7A",
        ),
        ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
        ("WORKROOM_SESSION_SHELL", "/bin/sh"),
        ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
        (
            "WORKROOM_SESSION_COMMAND",
            "sh -c 'sleep 2; echo STILL-THE-SAME fb=[${WORKROOM_SESSION_FALLBACK:-unset}]'",
        ),
    ];
    // The first restore finds no session and makes one; killed at once, as a quit leaves it.
    let mut first = Command::new(daemon_binary());
    first
        .args(["attach", "--no-create"])
        .env_clear()
        .env("PATH", "/usr/bin:/bin");
    for (key, value) in env {
        first.env(key, value);
    }
    let mut first = first
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn first attach");
    std::thread::sleep(std::time::Duration::from_millis(500));
    let _ = first.kill();
    let _ = first.wait();
    // Listed under the pane's id, so the second restore below reattaches it rather than making
    // another, which would print the same output.
    let listed = Command::new(daemon_binary())
        .args(["list", "--socket"])
        .arg(&socket)
        .output()
        .expect("list");

    let (output, _) = attach_with_args(&["--no-create"], &env, None);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        String::from_utf8_lossy(&listed.stdout).contains("6b9b968d-0bd7-4172-850a-a373da73bc7a"),
        "the first restore's new session is not held under the pane's id: {:?}",
        String::from_utf8_lossy(&listed.stdout)
    );
    assert!(
        output.contains("STILL-THE-SAME fb=[unset]"),
        "expected the session the first restore made. got: {output:?}"
    );
    assert!(!output.contains("has ended"), "got: {output:?}");
}

/// A hand-run `attach --no-create` (no app environment) for a session the daemon does not hold is
/// refused, not replaced: only the app's panes get a new session, and a toast saying so.
#[test]
fn a_hand_run_no_create_attach_does_not_create_the_session() {
    let dir = scratch("no-create-hand-run");
    let socket = dir.join("a.sock");
    let _daemon = start_daemon(&socket);
    let (output, _) = attach_with_args(
        &[
            "--no-create",
            "--socket",
            socket.to_str().unwrap(),
            "--session",
            "6B9B968D-0BD7-4172-850A-A373DA73BC7C",
        ],
        // Not variables `run_attach` takes as the app's mark. The command exits either way; only
        // the fallback shell sets WORKROOM_SESSION_FALLBACK, never a session the daemon made.
        &[
            ("WORKROOM_SESSION_SHELL", "/bin/sh"),
            (
                "WORKROOM_SESSION_COMMAND",
                "echo HAND-RUN fb=[${WORKROOM_SESSION_FALLBACK:-unset}]",
            ),
        ],
        None,
    );
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        output.contains("HAND-RUN fb=[1]"),
        "a hand-run --no-create attach was given a new session instead of being refused: {output:?}"
    );
}

/// When the new session is refused too, the pane gets the fallback shell after exactly one retry,
/// rather than asking again forever.
// Value: protects=a refused create ends in a working shell after one retry; fails_when=the
// one-retry guard goes, so a refusing daemon is asked again and again; why_new=the real daemon never
// refuses a create; seam=none; no_claim=why a real create fails (fake daemon)
#[test]
fn a_refused_new_session_falls_back_to_a_shell_after_one_retry() {
    use std::io::Write;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use wr_protocol::envelope::{Envelope, Hello, Service};
    use wr_protocol::frame::{Frame, FrameKind};

    let dir = scratch("no-create-refused-twice");
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).expect("bind fake daemon");
    let attaches = Arc::new(AtomicUsize::new(0));
    let counted = Arc::clone(&attaches);
    // Refuses the first two attaches. Any later one is closed unanswered, which the relay retries
    // only until its 10s deadline, so a regression ends in a count above 2 instead of a hang.
    std::thread::spawn(move || {
        let mut held = Vec::new();
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            if counted.fetch_add(1, Ordering::SeqCst) >= 2 {
                continue;
            }
            let _ = stream.write_all(&Hello::current("fake-peer").encode());
            let frame = Frame::new(FrameKind::Failure, b"session ended".to_vec());
            let _ = stream.write_all(&Envelope::new(Service::Terminal, 1, frame.encode()).encode());
            let _ = stream.flush();
            held.push(stream);
        }
    });

    let (output, _) = attach_with_args(
        &["--no-create"],
        &[
            (
                "WORKROOM_SESSION_ID",
                "6B9B968D-0BD7-4172-850A-A373DA73BC7B",
            ),
            ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
            ("WORKROOM_SESSION_SHELL", "/bin/sh"),
            ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
            (
                "WORKROOM_SESSION_COMMAND",
                "echo FELL-BACK fb=[${WORKROOM_SESSION_FALLBACK:-unset}]",
            ),
        ],
        None,
    );
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(
        attaches.load(Ordering::SeqCst),
        2,
        "expected the refusal and one retry. got: {output:?}"
    );
    assert!(
        output.contains("has ended") && output.contains("FELL-BACK fb=[1]"),
        "expected the ended notice and the fallback shell. got: {output:?}"
    );
}

/// On a remote host (`--no-spawn`) a restored pane whose session has ended gets no shell (#255,
/// D7): one started by the attach client would be no daemon session, invisible to every other Mac
/// and gone with the ssh link. The pane says the terminal ended and holds until it is closed, here
/// at once, since stdin is already at its end.
#[test]
fn a_restored_remote_pane_whose_session_ended_says_so_and_starts_no_shell() {
    let dir = scratch("no-create-remote-ended");
    let socket = dir.join("a.sock");
    let _daemon = start_daemon(&socket);
    let (output, status) = attach_with_args(
        &["--no-spawn", "--no-create"],
        &[
            (
                "WORKROOM_SESSION_ID",
                "6B9B968D-0BD7-4172-850A-A373DA73BC79",
            ),
            ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
            ("WORKROOM_SESSION_SHELL", "/bin/sh"),
            ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
            (
                "WORKROOM_SESSION_COMMAND",
                "echo NEW-SHELL fb=[${WORKROOM_SESSION_FALLBACK:-unset}]",
            ),
        ],
        None,
    );
    let listed = Command::new(daemon_binary())
        .args(["list", "--socket"])
        .arg(&socket)
        .output()
        .expect("list");
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        output.contains("This terminal has ended. Close it to start again."),
        "expected the ended notice. got: {output:?}"
    );
    assert!(
        !output.contains("NEW-SHELL"),
        "a shell was started: {output:?}"
    );
    // Not 255, which the app reads as a dropped link and attaches again.
    assert_eq!(status, Some(0), "got: {output:?}");
    assert!(
        !String::from_utf8_lossy(&listed.stdout).contains("6b9b968d"),
        "the daemon created the session anyway: {:?}",
        String::from_utf8_lossy(&listed.stdout)
    );
}

/// And a session that exists is reattached as usual: `--no-create` only refuses to make one.
#[test]
fn no_create_reattaches_a_session_that_exists() {
    let dir = scratch("no-create-live");
    let socket = dir.join("a.sock");
    let _daemon = start_daemon(&socket);
    let env = [
        (
            "WORKROOM_SESSION_ID",
            "6B9B968D-0BD7-4172-850A-A373DA73BC74",
        ),
        ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
        ("WORKROOM_SESSION_SHELL", "/bin/sh"),
        ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
        (
            "WORKROOM_SESSION_COMMAND",
            // Its own `sh -c`: a session's command is run as `exec <command>`, which would end at
            // `sleep`.
            "sh -c 'sleep 2; echo STILL-THE-SAME fb=[${WORKROOM_SESSION_FALLBACK:-unset}]'",
        ),
    ];
    // The first attach creates it; killed at once, it leaves the session running with no client.
    let mut first = Command::new(daemon_binary());
    first.arg("attach").env_clear().env("PATH", "/usr/bin:/bin");
    for (key, value) in env {
        first.env(key, value);
    }
    let mut first = first
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn first attach");
    std::thread::sleep(std::time::Duration::from_millis(500));
    let _ = first.kill();
    let _ = first.wait();

    let (output, _) = attach_with_args(&["--no-create"], &env, None);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        output.contains("STILL-THE-SAME fb=[unset]"),
        "expected the running session's own output. got: {output:?}"
    );
    assert!(!output.contains("has ended"), "got: {output:?}");
}

/// On a remote host (`--no-spawn`) the attach's exit status is ssh's, and 255 is ssh's own
/// failure, which the app answers by reconnecting. So a session that ended with 255 exits 254
/// there; locally it stays 255.
#[test]
fn a_remote_attach_never_exits_255_for_a_session_that_did() {
    let dir = scratch("exit-255");
    let socket = dir.join("a.sock");
    let _daemon = start_daemon(&socket);
    let run = |id: &str, args: &[&str]| {
        attach_with_args(
            args,
            &[
                ("WORKROOM_SESSION_ID", id),
                ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
                ("WORKROOM_SESSION_SHELL", "/bin/sh"),
                ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
                ("WORKROOM_SESSION_COMMAND", "sh -c 'exit 255'"),
            ],
            None,
        )
        .1
    };
    let local = run("6B9B968D-0BD7-4172-850A-A373DA73BC75", &[]);
    let remote = run("6B9B968D-0BD7-4172-850A-A373DA73BC76", &["--no-spawn"]);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(local, Some(255));
    assert_eq!(remote, Some(254));
}

/// The other half of that contract (#231): a remote attach whose daemon goes away WITHOUT saying
/// the shell ended exits 255, which the app reads as a dropped link and answers by attaching the
/// pane again as a restored one. The session may well be alive: a hand-off (#230) closes every
/// connection and carries the sessions to the new program. A local attach ends as it always has,
/// as if the shell had.
#[test]
fn a_remote_attach_whose_daemon_goes_away_exits_255() {
    let dir = scratch("daemon-gone");
    let run = |name: &str, id: &str, args: &[&str]| -> Option<i32> {
        // A socket per run: a killed daemon leaves its file behind, which `start_daemon` would take
        // for the next one having bound.
        let socket = dir.join(format!("{name}.sock"));
        let daemon = start_daemon(&socket);
        let mut command = Command::new(daemon_binary());
        command.arg("attach").args(args);
        command.env_clear();
        command.env("PATH", "/usr/bin:/bin");
        for (key, value) in [
            ("WORKROOM_SESSION_ID", id),
            ("WORKROOM_SESSION_SOCKET", socket.to_str().unwrap()),
            ("WORKROOM_SESSION_SHELL", "/bin/sh"),
            ("WORKROOM_SESSION_CWD", dir.to_str().unwrap()),
            // Quotes split the marker so nothing but the command's own output can satisfy it.
            (
                "WORKROOM_SESSION_COMMAND",
                "sh -c 'echo REA\"\"DY; sleep 30'",
            ),
        ] {
            command.env(key, value);
        }
        command.stdin(Stdio::null());
        command.stdout(Stdio::piped());
        command.stderr(Stdio::null());
        let mut child = command.spawn().expect("spawn attach");
        let mut stdout = child.stdout.take().expect("stdout");
        // Read on a thread, so both waits below have a deadline: a regression that keeps the
        // attach running must fail this test, not hang the lane.
        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = seen.clone();
        std::thread::spawn(move || {
            let mut buf = [0u8; 256];
            while let Ok(n) = stdout.read(&mut buf) {
                if n == 0 {
                    break;
                }
                sink.lock().unwrap().extend_from_slice(&buf[..n]);
            }
        });
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !String::from_utf8_lossy(&seen.lock().unwrap()).contains("READY") {
            assert!(
                child.try_wait().expect("wait").is_none(),
                "the attach ended before its command ran: {}",
                String::from_utf8_lossy(&seen.lock().unwrap())
            );
            assert!(
                std::time::Instant::now() < deadline,
                "the attach's command never ran"
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        // SIGKILL: the connection ends with nothing said, as it does at a hand-off's exec.
        drop(daemon);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        loop {
            if let Some(status) = child.try_wait().expect("wait") {
                break status.code();
            }
            if std::time::Instant::now() >= deadline {
                let _ = child.kill();
                panic!("the attach outlived its daemon by 10s");
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    };
    let local = run("local", "6B9B968D-0BD7-4172-850A-A373DA73BC77", &[]);
    let remote = run(
        "remote",
        "6B9B968D-0BD7-4172-850A-A373DA73BC78",
        &["--no-spawn"],
    );
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(local, Some(0));
    assert_eq!(remote, Some(255));
}

/// `list` is the readiness probe (`BoxdHostDriver`'s derive, daemon bootstrap, the ssh fixture),
/// so a daemon that negotiates and then hangs up without a `Sessions` reply must fail it. It used
/// to exit 0, and a derive could return a host whose daemon was not answering.
///
/// The peer reads the whole request before closing: closed any earlier, the client's write fails
/// instead, which is a different branch and already exits non-zero.
#[test]
fn list_fails_when_the_daemon_hangs_up_without_answering() {
    use std::io::Write;
    use workroomd::serve::BUILD;
    use wr_protocol::envelope::{Envelope, Hello, Service};
    use wr_protocol::frame::{Frame, FrameKind};

    let dir = scratch("list-eof");
    let socket = dir.join("a.sock");
    let listener = UnixListener::bind(&socket).expect("bind fake daemon");
    let request = Envelope::new(
        Service::Control,
        0,
        Frame::control(FrameKind::List).encode(),
    );
    let expected = Hello::current(BUILD).encode().len() + request.encode().len();
    let accepter = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        stream
            .write_all(&Hello::current("fake-peer").encode())
            .expect("greet");
        let mut received = vec![0u8; expected];
        stream.read_exact(&mut received).expect("the list request");
    });

    let output = Command::new(daemon_binary())
        .args(["list", "--socket"])
        .arg(&socket)
        .output()
        .expect("list");
    accepter.join().expect("the fake daemon read the request");
    let _ = std::fs::remove_dir_all(&dir);
    assert_ne!(
        output.status.code(),
        Some(0),
        "list passed a daemon that never answered: {output:?}"
    );
}
