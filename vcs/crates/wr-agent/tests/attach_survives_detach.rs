//! The Phase 1 integration test the design doc names: "type a sentinel, drop the transport,
//! reconnect with the same pane UUID, assert [the session is still there]".
//!
//! This drives the real binary as two real processes over a real socket, because the properties
//! it checks only exist across a process boundary: the agent outliving its client is the entire
//! feature, and a client "dropping" has to be an actual kill, not a function returning.
//!
//! Note what it does NOT assert: that the reattached client sees the earlier screen. Restoring
//! terminal state is the `libghostty-vt` snapshot work, separate from session survival — see the
//! session module's doc comment. What it asserts is that the same shell is still running and still
//! talking, which is the property the socket layer is responsible for.

use std::ffi::OsString;
use std::io::Write;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use wr_agent::pty::Pty;

mod common;
use common::*;

const SESSION: &str = "550e8400-e29b-41d4-a716-446655440000";

#[test]
fn a_session_outlives_the_client_that_created_it() {
    let workspace = Workspace::new("survives");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);

    // First client: create the session and prove the shell is live by making it echo.
    let mut first = attach(&socket, SESSION);
    {
        let stdin = first.stdin.as_mut().expect("stdin");
        // A short sleep lets the shell print its prompt first, so the marker is not swallowed.
        std::thread::sleep(Duration::from_millis(400));
        stdin
            .write_all(b"echo FIRST-CLIENT-MARKER\n")
            .expect("write");
        stdin.flush().expect("flush");
    }
    let mut reader = ClientReader::new(&mut first);
    let seen = reader.read_until("FIRST-CLIENT-MARKER", Duration::from_secs(10));
    assert!(
        seen.contains("FIRST-CLIENT-MARKER"),
        "the first client never saw its own echo; got {seen:?}"
    );

    let listed = list_sessions(&socket);
    assert!(
        listed.contains(SESSION),
        "the agent should list the session; got {listed:?}"
    );

    // Drop the transport the hard way: kill the client outright, as a crash or a force-quit does.
    first.kill().expect("kill first client");
    first.wait().expect("reap first client");

    // The session must still be there, and now reported detached.
    let survived = wait_for(Duration::from_secs(5), || {
        let listed = list_sessions(&socket);
        listed.contains(SESSION) && listed.contains("detached")
    });
    let listed = list_sessions(&socket);
    assert!(
        survived,
        "the session must outlive its client; list said {listed:?}"
    );

    // Second client, same id: the shell must still answer.
    let mut second = attach(&socket, SESSION);
    {
        let stdin = second.stdin.as_mut().expect("stdin");
        std::thread::sleep(Duration::from_millis(400));
        stdin
            .write_all(b"echo SECOND-CLIENT-MARKER\n")
            .expect("write");
        stdin.flush().expect("flush");
    }
    let mut reader = ClientReader::new(&mut second);
    let seen = reader.read_until("SECOND-CLIENT-MARKER", Duration::from_secs(10));
    assert!(
        seen.contains("SECOND-CLIENT-MARKER"),
        "the reattached client could not reach the shell; got {seen:?}"
    );

    let listed = list_sessions(&socket);
    assert!(
        listed.contains("attached"),
        "the session should be attached again; got {listed:?}"
    );

    let _ = second.kill();
    let _ = second.wait();
    let _ = agent.kill();
    let _ = agent.wait();
}

/// State set before the drop must still be there after it — the shell is the same process, so a
/// variable it holds is the cheapest proof that nothing was restarted behind the scenes.
#[test]
fn shell_state_survives_the_drop() {
    let workspace = Workspace::new("state");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);
    let session = "11111111-2222-3333-4444-555555555555";

    let mut first = attach(&socket, session);
    {
        let stdin = first.stdin.as_mut().expect("stdin");
        std::thread::sleep(Duration::from_millis(400));
        stdin
            .write_all(b"MARKER=survived-the-drop\n")
            .expect("write");
        stdin.write_all(b"echo SET-OK\n").expect("write");
        stdin.flush().expect("flush");
    }
    let mut reader = ClientReader::new(&mut first);
    let seen = reader.read_until("SET-OK", Duration::from_secs(10));
    assert!(
        seen.contains("SET-OK"),
        "variable was never set; got {seen:?}"
    );

    first.kill().expect("kill");
    first.wait().expect("reap");
    assert!(
        wait_for(Duration::from_secs(5), || {
            list_sessions(&socket).contains("detached")
        }),
        "session did not detach"
    );

    let mut second = attach(&socket, session);
    {
        let stdin = second.stdin.as_mut().expect("stdin");
        std::thread::sleep(Duration::from_millis(400));
        stdin.write_all(b"echo VALUE=$MARKER\n").expect("write");
        stdin.flush().expect("flush");
    }
    let mut reader = ClientReader::new(&mut second);
    let seen = reader.read_until("VALUE=survived-the-drop", Duration::from_secs(10));
    assert!(
        seen.contains("VALUE=survived-the-drop"),
        "the shell was restarted rather than reattached; got {seen:?}"
    );

    let _ = second.kill();
    let _ = second.wait();
    let _ = agent.kill();
    let _ = agent.wait();
}

/// Two agents on one socket would each own half the sessions and neither would find the other's.
#[test]
fn a_second_agent_does_not_take_over_the_socket() {
    let workspace = Workspace::new("single");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);

    // The second exits 0 without serving: losing the race is a normal outcome, not an error —
    // the other agent is already serving, which is all the caller wanted.
    let second = Command::new(agent_binary())
        .args(["serve", "--socket"])
        .arg(&socket)
        .args(["--idle-timeout", "60"])
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .expect("second agent");
    assert!(
        second.status.success(),
        "a losing agent should exit cleanly, got {:?}",
        second.status
    );

    // And the first is still serving.
    let mut client = attach(&socket, "99999999-8888-7777-6666-555555555555");
    {
        let stdin = client.stdin.as_mut().expect("stdin");
        std::thread::sleep(Duration::from_millis(400));
        stdin.write_all(b"echo STILL-SERVING\n").expect("write");
        stdin.flush().expect("flush");
    }
    let mut reader = ClientReader::new(&mut client);
    let seen = reader.read_until("STILL-SERVING", Duration::from_secs(10));
    assert!(seen.contains("STILL-SERVING"), "got {seen:?}");

    let _ = client.kill();
    let _ = client.wait();
    let _ = agent.kill();
    let _ = agent.wait();
}

/// An attach with nothing listening must start the agent itself — the app has no installed
/// service to rely on, so the first client is what brings one up.
#[test]
fn attach_starts_an_agent_when_none_is_running() {
    let workspace = Workspace::new("spawn");
    let socket = workspace.socket();
    assert!(!socket.exists());

    let mut client = attach(&socket, "abcdefab-cdef-abcd-efab-cdefabcdefab");
    {
        let stdin = client.stdin.as_mut().expect("stdin");
        std::thread::sleep(Duration::from_millis(800));
        stdin.write_all(b"echo SPAWNED-OK\n").expect("write");
        stdin.flush().expect("flush");
    }
    let mut reader = ClientReader::new(&mut client);
    let seen = reader.read_until("SPAWNED-OK", Duration::from_secs(15));
    assert!(
        seen.contains("SPAWNED-OK"),
        "attach should have started an agent; got {seen:?}"
    );
    assert!(
        socket.exists(),
        "the spawned agent should have bound a socket"
    );

    // End the SHELL, not just the relay. This agent was spawned by `attach` and is detached from
    // this process, so no `Spawned` guard covers it — and it only exits when it is idle, which
    // means no connections AND no sessions. Killing the client alone leaves the session's shell
    // running, so the agent stays busy forever: a permanently leaked agent plus its `/bin/sh`, on
    // the SUCCESS path. `list` was here before and ends nothing — it is a read.
    //
    // Removing the socket afterwards made it worse rather than tidier: it left the agent alive and
    // unreachable, so nothing could ever ask it to stop.
    {
        let stdin = client.stdin.as_mut().expect("stdin");
        let _ = stdin.write_all(b"exit\n");
        let _ = stdin.flush();
    }
    // Long enough for the shell to exit and the session to leave the store. The agent is then idle
    // — no connections, no sessions — and exits on its own timer. Not asserted, because this is
    // cleanup: the test's subject is that an agent STARTED.
    std::thread::sleep(Duration::from_millis(500));
    let _ = client.kill();
    let _ = client.wait();
}

/// The payoff of the shadow terminal: a client that arrives late must be SHOWN the session, not
/// merely connected to it. Without the shadow a reattached client sees nothing until the next
/// keystroke produces output, which is what "reattach" looked like before terminal state.
///
/// **Getting this test honest took two attempts, and the first version was vacuous.** Asserting
/// that the second client sees a marker the first one printed passes with or without the shadow:
/// terminal echo means the marker appears twice in the pty's output, the first client's read
/// consumed only one, and the leftover reaches the next client as ordinary buffered output.
///
/// So the marker has to be *old*: printed, then followed by enough traffic that the first client
/// demonstrably drained past it, while staying on screen. Bytes that were consumed long ago can
/// only reach a fresh client by being repainted from state.
///
/// Skipped unless the agent was built with the feature — otherwise it would assert the feature is
/// on rather than that it works.
#[test]
fn a_reattaching_client_is_shown_the_screen() {
    if !has_terminal_state() {
        eprintln!("skipping: agent built without the terminal-state feature");
        return;
    }

    let workspace = Workspace::new("repaint");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);
    let session = "0a0a0a0a-0b0b-0c0c-0d0d-0e0e0e0e0e0e";

    let mut first = attach(&socket, session);
    {
        let stdin = first.stdin.as_mut().expect("stdin");
        std::thread::sleep(Duration::from_millis(400));
        stdin.write_all(b"echo OLD-MARKER\n").expect("write");
        // Enough lines that the marker is well behind the read cursor, few enough that it is
        // still on the 24-row SCREEN. Re-synthesis restores the active screen, not scrollback, so
        // a marker that has scrolled into history is genuinely unrecoverable — each command here
        // costs two rows (the shell echoes the input, then prints the output) plus a prompt.
        for n in 0..3 {
            stdin
                .write_all(format!("echo FILLER-{n}\n").as_bytes())
                .expect("write");
        }
        stdin.write_all(b"echo DRAINED\n").expect("write");
        stdin.flush().expect("flush");
    }
    // Reading to DRAINED consumes OLD-MARKER and its echo on the way past. The settle after it
    // matters: the shell must finish echoing everything it was sent, or leftover output reaches
    // the next client as ordinary buffered bytes and the assertion below proves nothing.
    let mut reader = ClientReader::new(&mut first);
    let seen = reader.read_until("DRAINED", Duration::from_secs(10));
    assert!(seen.contains("OLD-MARKER"), "setup failed; got {seen:?}");
    assert!(seen.contains("DRAINED"), "setup failed; got {seen:?}");
    reader.drain(Duration::from_millis(500));

    first.kill().expect("kill");
    first.wait().expect("reap");
    assert!(
        wait_for(Duration::from_secs(5), || {
            list_sessions(&socket).contains("detached")
        }),
        "session did not detach"
    );

    // The second client types NOTHING, and OLD-MARKER's bytes were consumed by the first client
    // long before it died. Seeing it now means the screen was repainted from state.
    let mut second = attach(&socket, session);
    let mut reader = ClientReader::new(&mut second);
    let seen = reader
        .read_until("OLD-MARKER", Duration::from_secs(10))
        .to_string();
    if std::env::var_os("WR_DEBUG_REPAINT").is_some() {
        eprintln!("--- second client saw: {seen:?}");
    }
    assert!(
        seen.contains("OLD-MARKER"),
        "the reattached client was not repainted; it saw {seen:?}"
    );

    let _ = second.kill();
    let _ = second.wait();
    let _ = agent.kill();
    let _ = agent.wait();
}

/// Scrollback is most of what a detach used to cost: the screen is only the last 24 rows, and a
/// build or test run's output is all above it. This marker is pushed well off-screen before the
/// drop, so seeing it again can only mean history was restored.
#[test]
fn a_reattaching_client_gets_its_scrollback() {
    if !has_terminal_state() {
        eprintln!("skipping: agent built without the terminal-state feature");
        return;
    }

    let workspace = Workspace::new("scrollback");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);
    let session = "1b1b1b1b-2c2c-3d3d-4e4e-5f5f5f5f5f5f";

    let mut first = attach(&socket, session);
    {
        let stdin = first.stdin.as_mut().expect("stdin");
        std::thread::sleep(Duration::from_millis(400));
        stdin
            .write_all(b"echo SCROLLED-OFF-MARKER\n")
            .expect("write");
        // Far more than a 24-row screen, so the marker is unambiguously in history.
        stdin
            .write_all(b"for i in 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5; do echo pad$i; done\n")
            .expect("write");
        stdin.write_all(b"echo DRAINED\n").expect("write");
        stdin.flush().expect("flush");
    }
    let mut reader = ClientReader::new(&mut first);
    let seen = reader.read_until("DRAINED", Duration::from_secs(10));
    assert!(
        seen.contains("SCROLLED-OFF-MARKER"),
        "setup failed: {seen:?}"
    );
    reader.drain(Duration::from_millis(500));

    first.kill().expect("kill");
    first.wait().expect("reap");
    assert!(
        wait_for(Duration::from_secs(5), || {
            list_sessions(&socket).contains("detached")
        }),
        "session did not detach"
    );

    let mut second = attach(&socket, session);
    let mut reader = ClientReader::new(&mut second);
    let seen = reader
        .read_until("SCROLLED-OFF-MARKER", Duration::from_secs(10))
        .to_string();
    assert!(
        seen.contains("SCROLLED-OFF-MARKER"),
        "scrollback was not restored; the client saw {} bytes",
        seen.len()
    );

    let _ = second.kill();
    let _ = second.wait();
    let _ = agent.kill();
    let _ = agent.wait();
}

/// The case the Swift replay buffer could not handle at all: it emptied itself on entering the
/// alternate screen, so a full-screen program — every long-running agent — reattached to a blank
/// pane. The marker is assembled by `printf` so the typed command line, which stays on the PRIMARY
/// screen, never contains it; seeing it means the alternate screen itself was restored.
#[test]
fn a_reattaching_client_gets_a_full_screen_programs_screen() {
    if !has_terminal_state() {
        eprintln!("skipping: agent built without the terminal-state feature");
        return;
    }

    let workspace = Workspace::new("altscreen");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);
    let session = "2c2c2c2c-3d3d-4e4e-5f5f-6a6a6a6a6a6a";

    let mut first = attach(&socket, session);
    {
        let stdin = first.stdin.as_mut().expect("stdin");
        std::thread::sleep(Duration::from_millis(400));
        stdin
            .write_all(b"printf '\\033[?1049h\\033[H%s-%s\\n' ALT SCREEN; sleep 30\n")
            .expect("write");
        stdin.flush().expect("flush");
    }
    let mut reader = ClientReader::new(&mut first);
    let seen = reader.read_until("ALT-SCREEN", Duration::from_secs(10));
    assert!(seen.contains("ALT-SCREEN"), "setup failed; got {seen:?}");
    reader.drain(Duration::from_millis(500));

    first.kill().expect("kill");
    first.wait().expect("reap");
    assert!(
        wait_for(Duration::from_secs(5), || {
            list_sessions(&socket).contains("detached")
        }),
        "session did not detach"
    );

    let mut second = attach(&socket, session);
    let mut reader = ClientReader::new(&mut second);
    let seen = reader
        .read_until("ALT-SCREEN", Duration::from_secs(10))
        .to_string();
    let entered = seen.find("\x1b[?1049h");
    let marker = seen.find("ALT-SCREEN");
    assert!(
        matches!((entered, marker), (Some(e), Some(m)) if e < m),
        "the alternate screen was not restored; the client saw {seen:?}"
    );

    let _ = second.kill();
    let _ = second.wait();
    let _ = agent.kill();
    let _ = agent.wait();
}

/// `PersistentSessionService.attachCommand()` builds the command line as `<binary> attach` with no
/// arguments — everything else is environment. So the agent has to be drivable that way, or the
/// Swift side needs a special case for which backend it picked.
#[test]
fn the_app_environment_contract_alone_is_enough() {
    let workspace = Workspace::new("envcontract");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);

    let cwd = workspace.dir.join("workroom-dir");
    std::fs::create_dir_all(&cwd).expect("cwd");

    // No --socket, no --session: exactly what the app passes.
    let mut client = Command::new(agent_binary())
        .arg("attach")
        .env(
            "WORKROOM_SESSION_ID",
            "deadbeef-dead-beef-dead-beefdeadbeef",
        )
        .env("WORKROOM_SESSION_SOCKET", &socket)
        .env("WORKROOM_SESSION_SHELL", "/bin/sh")
        .env("WORKROOM_SESSION_CWD", &cwd)
        // Empty means "an ordinary shell", not a command to run.
        .env("WORKROOM_SESSION_COMMAND", "")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn attach");

    {
        let stdin = client.stdin.as_mut().expect("stdin");
        std::thread::sleep(Duration::from_millis(400));
        // Proves the CWD travelled: the agent's own working directory is not this one.
        stdin.write_all(b"pwd\n").expect("write");
        stdin.flush().expect("flush");
    }
    let mut reader = ClientReader::new(&mut client);
    let seen = reader.read_until("workroom-dir", Duration::from_secs(10));
    assert!(
        seen.contains("workroom-dir"),
        "the session did not start in the requested directory; saw {seen:?}"
    );

    assert!(
        list_sessions(&socket).contains("deadbeef-dead-beef-dead-beefdeadbeef"),
        "the session id from the environment was not used"
    );

    let _ = client.kill();
    let _ = client.wait();
    let _ = agent.kill();
    let _ = agent.wait();
}

/// A run command is `/bin/sh -c "exec <command>"`, and must actually run rather than opening a
/// shell.
#[test]
fn a_run_command_from_the_environment_is_executed() {
    let workspace = Workspace::new("runcmd");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);

    let mut client = Command::new(agent_binary())
        .arg("attach")
        .env(
            "WORKROOM_SESSION_ID",
            "cafecafe-cafe-cafe-cafe-cafecafecafe",
        )
        .env("WORKROOM_SESSION_SOCKET", &socket)
        .env("WORKROOM_SESSION_SHELL", "/bin/sh")
        .env("WORKROOM_SESSION_COMMAND", "echo RAN-THE-COMMAND")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn attach");

    let mut reader = ClientReader::new(&mut client);
    let seen = reader.read_until("RAN-THE-COMMAND", Duration::from_secs(10));
    assert!(
        seen.contains("RAN-THE-COMMAND"),
        "the run command did not execute; saw {seen:?}"
    );

    let _ = client.kill();
    let _ = client.wait();
    let _ = agent.kill();
    let _ = agent.wait();
}

/// The shell must be started the way the app's own daemon starts it, not bare.
///
/// This is the regression test for two bugs seen in the app the first time it ran on the agent:
/// panes titled `user@host:~/dir` instead of by the app. That came from spawning `$SHELL` with no
/// argv[0] and no shell integration, so the login profile never ran and ghostty's OSC 133 prompt
/// marks — which are how the app learns a command finished and resets the title — were never
/// emitted. Asserting through a real attach is the point: `shell::invocation` had unit tests of
/// its own while the attach path quietly ignored it.
#[test]
fn the_shell_is_started_the_way_the_app_starts_it() {
    let workspace = Workspace::new("shellinvocation");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);

    let mut client = Command::new(agent_binary())
        .arg("attach")
        .env(
            "WORKROOM_SESSION_ID",
            "5e115e11-5e11-5e11-5e11-5e115e115e11",
        )
        .env("WORKROOM_SESSION_SOCKET", &socket)
        .env("WORKROOM_SESSION_SHELL", "/bin/sh")
        .env("WORKROOM_SESSION_COMMAND", "")
        .env("WORKROOM_SESSION_RESOURCES", "/res")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn attach");

    {
        let stdin = client.stdin.as_mut().expect("stdin");
        std::thread::sleep(Duration::from_millis(400));
        // `$0` is how a shell reports its own argv[0], and the leading dash is the ONLY thing that
        // makes it a login shell.
        stdin.write_all(b"echo \"argv0=[$0]\"\n").expect("write");
        stdin
            .write_all(b"echo \"res=[$GHOSTTY_RESOURCES_DIR]\"\n")
            .expect("write");
        stdin.flush().expect("flush");
    }

    let mut reader = ClientReader::new(&mut client);
    let seen = reader
        .read_until("res=[/res]", Duration::from_secs(10))
        .to_string();
    assert!(
        seen.contains("argv0=[-sh]"),
        "the shell was not started as a login shell; saw {seen:?}"
    );
    assert!(
        seen.contains("res=[/res]"),
        "ghostty's resources directory did not reach the shell; saw {seen:?}"
    );

    let _ = client.kill();
    let _ = client.wait();
    let _ = agent.kill();
    let _ = agent.wait();
}

/// A session with nobody attached must keep draining its pty.
///
/// This is the regression test for a real bug: while the pty reader belonged to the CONNECTION,
/// a detached session had no reader at all. A job producing output then filled the pty's queue and
/// **blocked** — the shell stopped mid-command and only resumed if someone reattached. Closing the
/// app on a running build was enough to do it.
///
/// The assertion is deliberately indirect, and that is what makes it discriminating: `seq 1 50000`
/// is far more than a pty queue holds, so the shell can only reach its `exit` if something drained
/// it. The agent ends a session when its shell exits, so a session that is GONE proves the drain
/// happened. Under the old code the shell blocks forever and the session is still listed.
#[test]
fn a_detached_session_keeps_draining_its_pty() {
    let workspace = Workspace::new("detacheddrain");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);

    // A second, idle session that outlives the test. It is the control: without it an empty or
    // failed listing would satisfy the assertion below and the test would pass against anything.
    // An earlier version of this test did exactly that.
    let anchor = "a0c40000-a0c4-0000-a0c4-0000a0c40000";
    let mut idle = Command::new(agent_binary())
        .arg("attach")
        .env("WORKROOM_SESSION_ID", anchor)
        .env("WORKROOM_SESSION_SOCKET", &socket)
        .env("WORKROOM_SESSION_SHELL", "/bin/sh")
        .env("WORKROOM_SESSION_COMMAND", "sleep 60")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn idle");

    let session = "d7a14ed0-d7a1-4ed0-d7a1-4ed0d7a14ed0";
    let mut client = Command::new(agent_binary())
        .arg("attach")
        .env("WORKROOM_SESSION_ID", session)
        .env("WORKROOM_SESSION_SOCKET", &socket)
        .env("WORKROOM_SESSION_SHELL", "/bin/sh")
        .env("WORKROOM_SESSION_COMMAND", "seq 1 50000; exit 0")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn attach");

    // The session must EXIST before it can be meaningfully detached — killing the client first
    // would leave nothing to assert about, which is how this test once passed vacuously.
    assert!(
        wait_for(Duration::from_secs(10), || list_sessions(&socket)
            .contains(session)),
        "the session under test never started"
    );

    // Now drop the client, while the command is still pouring out output.
    let _ = client.kill();
    let _ = client.wait();

    // The shell needs no help now — if it is being drained it reaches the end on its own, and the
    // session goes with it. Under a connection-owned pump it blocks on a full pty queue forever.
    let gone = wait_for(Duration::from_secs(20), || {
        let listed = list_sessions(&socket);
        listed.contains(anchor) && !listed.contains(session)
    });
    assert!(
        gone,
        "the detached session never finished; its shell is blocked on a pty nobody is reading"
    );

    let _ = idle.kill();
    let _ = idle.wait();
    let _ = agent.kill();
    let _ = agent.wait();
}

/// When the shell exits, the client must be told and must exit too.
///
/// Without an `Exited` frame the relay waits forever on a session that will never speak again.
/// In the app that is a dead pane with a live relay process behind it; on the command line it is
/// `wr-agent attach` hanging, which is how this was found.
#[test]
fn the_client_exits_when_the_shell_does() {
    let workspace = Workspace::new("shellexit");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);
    let session = "feedface-feed-face-feed-facefeedface";

    let mut client = attach(&socket, session);
    {
        let stdin = client.stdin.as_mut().expect("stdin");
        std::thread::sleep(Duration::from_millis(400));
        stdin.write_all(b"echo BYE; exit\n").expect("write");
        stdin.flush().expect("flush");
    }

    // The client must terminate on its own. Polling rather than `wait()` so a hang is a test
    // failure with a message instead of a suite that never finishes.
    let exited = wait_for(Duration::from_secs(10), || {
        matches!(client.try_wait(), Ok(Some(_)))
    });
    assert!(exited, "the client did not exit after its shell did");

    // And the session is gone rather than lingering as an unreattachable husk.
    let cleared = wait_for(Duration::from_secs(5), || {
        !list_sessions(&socket).contains(session)
    });
    assert!(
        cleared,
        "the dead session is still listed: {:?}",
        list_sessions(&socket)
    );

    let _ = client.kill();
    let _ = agent.kill();
    let _ = agent.wait();
}

/// The shell's exit code reaches the client's own exit status, through the path that actually
/// runs.
///
/// A unit test on the conversion alone is not enough, and this exists because twice now an edit
/// landed in a function nothing calls while the live path kept the old behaviour — first
/// `Pty::write_all`, then this very conversion, which was applied to a `pump_output` that had been
/// dead since the reader moved into the session. Asserting the number a real `wr-agent attach`
/// exits with is the only version of this test that cannot be satisfied by dead code.
#[test]
fn the_shells_exit_code_becomes_the_clients() {
    let workspace = Workspace::new("exitcode");
    let socket = workspace.socket();
    let _agent = start_agent(&socket);

    let mut client = attach(&socket, "0eadc0de-0000-4000-8000-00000eadc0de");
    {
        let stdin = client.stdin.as_mut().expect("stdin");
        std::thread::sleep(Duration::from_millis(400));
        stdin.write_all(b"exit 7\n").expect("write");
        stdin.flush().expect("flush");
    }

    let exited = wait_for(Duration::from_secs(10), || {
        matches!(client.try_wait(), Ok(Some(_)))
    });
    assert!(exited, "the client did not exit after its shell did");

    let status = client.try_wait().expect("wait").expect("status");
    // 7, not 1792 (the raw waitpid status) and not 255 (that value clamped into a byte).
    assert_eq!(
        status.code(),
        Some(7),
        "the shell's exit code did not reach the client"
    );
}

/// The attach client must put its own terminal into raw mode.
///
/// Every other test in this file gives the client a PIPE for stdin, and a pipe has no line
/// discipline — so all of them pass against a client that never calls `tcsetattr` at all. That is
/// exactly what shipped: the agent reached a nightly with its tty left cooked, and the pane it
/// served echoed every focus report, mouse report and paste marker onto the screen as text while
/// Ctrl-C killed the relay instead of reaching the program.
///
/// So this one gives it a real pty, which is the only way the defect is visible. Two assertions,
/// because they fail differently: the flags say the mode was never entered, and the Ctrl-C survival
/// says what the user actually loses when it wasn't.
#[test]
fn the_client_puts_its_own_terminal_into_raw_mode() {
    let workspace = Workspace::new("rawmode");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);

    let session = "f00dfeed-f00d-feed-f00d-feedf00dfeed";
    let env: Vec<(OsString, OsString)> = vec![
        ("WORKROOM_SESSION_ID".into(), session.into()),
        ("WORKROOM_SESSION_SOCKET".into(), socket.clone().into()),
        ("WORKROOM_SESSION_SHELL".into(), "/bin/sh".into()),
        ("WORKROOM_SESSION_CWD".into(), workspace.dir.clone().into()),
        ("WORKROOM_SESSION_COMMAND".into(), "".into()),
        ("PATH".into(), "/usr/bin:/bin".into()),
    ];
    let pty = Pty::spawn(
        agent_binary().as_os_str(),
        None,
        &[OsString::from("attach")],
        &env,
        Some(workspace.dir.as_os_str()),
        80,
        24,
    )
    .expect("spawn attach on a pty");

    // The shell is up once it answers. Proves the relay works at all, so a later failure is about
    // the terminal mode and not about a session that never started.
    assert!(
        wait_for(Duration::from_secs(10), || {
            list_sessions(&socket).contains(session)
        }),
        "the session never registered; the client is not relaying"
    );
    pty.write_all(b"echo ready\n").expect("write");
    assert!(
        read_until_on_pty(&pty, "ready", Duration::from_secs(10)),
        "the shell never answered through the pty"
    );

    // What the mode actually is. `tcgetattr` on the master reads the pty's line discipline, which
    // is the same one the client's stdin sees.
    let mut settings: libc::termios = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::tcgetattr(pty.master_fd(), &mut settings) };
    assert_eq!(rc, 0, "could not read the pty's terminal settings");
    for (name, flag) in [
        ("ECHO", libc::ECHO),
        ("ICANON", libc::ICANON),
        ("ISIG", libc::ISIG),
    ] {
        assert_eq!(
            settings.c_lflag & flag,
            0,
            "{name} is still set: the client left its terminal cooked, so the emulator's own \
             reports echo onto the screen and Ctrl-C never reaches the far side"
        );
    }

    // And what that costs. Cooked, `\x03` raises SIGINT in the client's own process group and the
    // relay dies; raw, it is a byte for the program on the far end and the relay is untouched.
    pty.write_all(b"\x03").expect("write ^C");
    std::thread::sleep(Duration::from_millis(500));
    pty.write_all(b"echo alive\n").expect("write");
    assert!(
        read_until_on_pty(&pty, "alive", Duration::from_secs(10)),
        "the client did not survive Ctrl-C: it took the SIGINT itself instead of forwarding \
         the byte"
    );

    let _ = agent.kill();
    let _ = agent.wait();
}

/// Reads the pty master until `needle` shows up or the deadline passes.
fn read_until_on_pty(pty: &Pty, needle: &str, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    let mut seen = String::new();
    let mut buffer = [0u8; 4096];
    while Instant::now() < deadline {
        match pty.read(&mut buffer) {
            Ok(0) => return false,
            Ok(n) => {
                seen.push_str(&String::from_utf8_lossy(&buffer[..n]));
                if seen.contains(needle) {
                    return true;
                }
            }
            Err(_) => std::thread::sleep(Duration::from_millis(25)),
        }
    }
    false
}
