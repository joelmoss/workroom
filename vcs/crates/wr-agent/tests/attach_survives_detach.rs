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

/// Reads from a child's stdout until `needle` appears. Runs on a thread so a child that says
/// nothing cannot hang the test.
fn read_until(child: &mut Child, needle: &str, timeout: Duration) -> String {
    let stdout = child.stdout.take().expect("stdout");
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        let mut seen = String::new();
        let mut byte = [0u8; 1];
        while reader.read(&mut byte).unwrap_or(0) > 0 {
            seen.push(byte[0] as char);
            if tx.send(seen.clone()).is_err() {
                return;
            }
        }
    });

    let deadline = Instant::now() + timeout;
    let mut latest = String::new();
    while Instant::now() < deadline {
        if let Ok(seen) = rx.recv_timeout(Duration::from_millis(100)) {
            latest = seen;
            if latest.contains(needle) {
                break;
            }
        }
    }
    latest
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
    let seen = read_until(&mut first, "FIRST-CLIENT-MARKER", Duration::from_secs(10));
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
    let seen = read_until(&mut second, "SECOND-CLIENT-MARKER", Duration::from_secs(10));
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
    let seen = read_until(&mut first, "SET-OK", Duration::from_secs(10));
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
    let seen = read_until(
        &mut second,
        "VALUE=survived-the-drop",
        Duration::from_secs(10),
    );
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
    let seen = read_until(&mut client, "STILL-SERVING", Duration::from_secs(10));
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
    let seen = read_until(&mut client, "SPAWNED-OK", Duration::from_secs(15));
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
