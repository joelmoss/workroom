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

use std::io::{BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

fn agent_binary() -> PathBuf {
    // `CARGO_BIN_EXE_wr-agent` is resolved at COMPILE time and bakes in an absolute path from the
    // build host. That is right for `cargo test`, and wrong the moment the cross-compiled test
    // binary is carried to the machine it targets — which is exactly how the Linux side of this
    // crate is verified. `WR_AGENT_BIN` lets the runner say where the binary actually is.
    match std::env::var_os("WR_AGENT_BIN") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(env!("CARGO_BIN_EXE_wr-agent")),
    }
}

struct Workspace {
    dir: PathBuf,
}

impl Workspace {
    fn new(name: &str) -> Workspace {
        let dir = std::env::temp_dir().join(format!("wr-agent-it-{}-{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("workspace");
        Workspace { dir }
    }

    fn socket(&self) -> PathBuf {
        self.dir.join("agent.sock")
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn start_agent(socket: &Path) -> Child {
    let child = Command::new(agent_binary())
        .args(["serve", "--socket"])
        .arg(socket)
        .args(["--idle-timeout", "60"])
        // The agent spawns $SHELL, so without this these tests run the DEVELOPER's shell — an
        // interactive zsh with a git-aware prompt and a line editor that redraws pending typeahead
        // on reattach. That redraw looks exactly like a repaint and made an earlier version of the
        // repaint test below pass with the feature switched off.
        .env("SHELL", "/bin/sh")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn agent");
    wait_for(Duration::from_secs(5), || socket.exists());
    assert!(socket.exists(), "agent never bound its socket");
    child
}

fn wait_for(timeout: Duration, mut condition: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if condition() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    false
}

fn attach(socket: &Path, session: &str) -> Child {
    Command::new(agent_binary())
        .args(["attach", "--socket"])
        .arg(socket)
        .args(["--session", session])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn attach")
}

/// A client's stdout, readable more than once.
///
/// It owns the reader thread, because taking `child.stdout` is a one-shot: an earlier version
/// called a `read_until` helper twice on the same client and panicked on the second take.
struct ClientReader {
    rx: std::sync::mpsc::Receiver<String>,
    seen: String,
}

impl ClientReader {
    fn new(child: &mut Child) -> ClientReader {
        let stdout = child.stdout.take().expect("stdout");
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            let mut byte = [0u8; 1];
            while reader.read(&mut byte).unwrap_or(0) > 0 {
                if tx
                    .send(String::from_utf8_lossy(&byte).into_owned())
                    .is_err()
                {
                    return;
                }
            }
        });
        ClientReader {
            rx,
            seen: String::new(),
        }
    }

    /// Accumulates until `needle` appears or the deadline passes. Everything read so far is kept,
    /// so a later call continues rather than starting over.
    fn read_until(&mut self, needle: &str, timeout: Duration) -> &str {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if self.seen.contains(needle) {
                break;
            }
            match self.rx.recv_timeout(Duration::from_millis(100)) {
                Ok(chunk) => self.seen.push_str(&chunk),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(_) => break,
            }
        }
        &self.seen
    }

    /// Reads whatever is still arriving, for `quiet`, then stops. Used to be sure the shell has
    /// finished echoing before the client is killed — leftover output would otherwise reach the
    /// NEXT client as ordinary buffered bytes and make a repaint assertion prove nothing.
    fn drain(&mut self, quiet: Duration) {
        while let Ok(chunk) = self.rx.recv_timeout(quiet) {
            self.seen.push_str(&chunk);
        }
    }
}

fn list_sessions(socket: &Path) -> String {
    let output = Command::new(agent_binary())
        .args(["list", "--socket"])
        .arg(socket)
        .output()
        .expect("list");
    String::from_utf8_lossy(&output.stdout).into_owned()
}

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
    wait_for(Duration::from_secs(5), || {
        list_sessions(&socket).contains("detached")
    });

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

    let _ = client.kill();
    let _ = client.wait();
    // The spawned agent is detached from this process, so end it through its own control plane.
    let _ = Command::new(agent_binary())
        .args(["list", "--socket"])
        .arg(&socket)
        .output();
    let _ = std::fs::remove_file(&socket);
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
    if std::env::var_os("WR_AGENT_HAS_TERMINAL_STATE").is_none() {
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
    wait_for(Duration::from_secs(5), || {
        list_sessions(&socket).contains("detached")
    });

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
    if std::env::var_os("WR_AGENT_HAS_TERMINAL_STATE").is_none() {
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
    wait_for(Duration::from_secs(5), || {
        list_sessions(&socket).contains("detached")
    });

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

/// A run command is `<shell> -c <command>`, and must actually run rather than opening a shell.
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
