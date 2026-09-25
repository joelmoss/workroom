//! Hand-off (#230): a running agent replaces its own program and keeps every session.
//!
//! Real processes over a real socket, like `attach_survives_detach.rs`, because what these check
//! only exists across `execve`: the same pid still parenting the same shells, a socket that was
//! never unbound, and what dies with a program that fails after the exec.

use std::io::{BufReader, Read, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

fn agent_binary() -> PathBuf {
    // See `attach_survives_detach.rs`: the runner names the binary when the test is carried to
    // the machine it targets.
    match std::env::var_os("WR_AGENT_BIN") {
        Some(path) => PathBuf::from(path),
        None => PathBuf::from(env!("CARGO_BIN_EXE_wr-agent")),
    }
}

/// Killed when the test ends, panic or not: a leaked agent holds its shells forever.
struct Spawned(Child);

impl Drop for Spawned {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

impl std::ops::Deref for Spawned {
    type Target = Child;
    fn deref(&self) -> &Child {
        &self.0
    }
}

impl std::ops::DerefMut for Spawned {
    fn deref_mut(&mut self) -> &mut Child {
        &mut self.0
    }
}

struct Workspace {
    dir: PathBuf,
}

impl Workspace {
    fn new(name: &str) -> Workspace {
        let dir = std::env::temp_dir().join(format!("wr-agent-ho-{}-{}", name, std::process::id()));
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

fn start_agent(socket: &Path) -> Spawned {
    let child = Command::new(agent_binary())
        .args(["serve", "--socket"])
        .arg(socket)
        .args(["--idle-timeout", "60"])
        .env("SHELL", "/bin/sh")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn agent");
    let child = Spawned(child);
    assert!(
        wait_for(Duration::from_secs(5), || socket.exists()),
        "agent never bound its socket"
    );
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

fn attach(socket: &Path, session: &str) -> Spawned {
    let child = Command::new(agent_binary())
        .args(["attach", "--socket"])
        .arg(socket)
        .args(["--session", session])
        .env("SHELL", "/bin/sh")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn attach");
    Spawned(child)
}

/// A client's stdout, accumulated by a thread so it can be read more than once.
struct ClientReader {
    rx: std::sync::mpsc::Receiver<u8>,
    seen: Vec<u8>,
}

impl ClientReader {
    fn new(child: &mut Child) -> ClientReader {
        let stdout = child.stdout.take().expect("stdout");
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            let mut byte = [0u8; 1];
            while reader.read(&mut byte).unwrap_or(0) > 0 {
                if tx.send(byte[0]).is_err() {
                    return;
                }
            }
        });
        ClientReader {
            rx,
            seen: Vec::new(),
        }
    }

    fn read_until(&mut self, needle: &str, timeout: Duration) -> String {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline && !self.text().contains(needle) {
            if let Ok(byte) = self.rx.recv_timeout(Duration::from_millis(100)) {
                self.seen.push(byte);
            }
        }
        self.text()
    }

    fn text(&self) -> String {
        String::from_utf8_lossy(&self.seen).into_owned()
    }
}

fn type_line(client: &mut Child, line: &str) {
    let stdin = client.stdin.as_mut().expect("stdin");
    stdin.write_all(line.as_bytes()).expect("write");
    stdin.write_all(b"\n").expect("write");
    stdin.flush().expect("flush");
}

fn list_sessions(socket: &Path) -> String {
    let output = Command::new(agent_binary())
        .args(["list", "--socket"])
        .arg(socket)
        .output()
        .expect("list");
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn hand_off(socket: &Path, binary: &Path, force: bool) -> Output {
    let mut command = Command::new(agent_binary());
    command
        .args(["hand-off", "--socket"])
        .arg(socket)
        .arg("--binary")
        .arg(binary);
    if force {
        command.arg("--force");
    }
    command.output().expect("hand-off")
}

fn has_terminal_state() -> bool {
    std::env::var_os("WR_AGENT_HAS_TERMINAL_STATE").is_some_and(|value| !value.is_empty())
}

fn alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

/// Starts a session, prints a marker in it, and returns the shell's pid with the client detached.
fn detached_session(socket: &Path, session: &str, marker: &str) -> i32 {
    let mut client = attach(socket, session);
    std::thread::sleep(Duration::from_millis(400));
    // Split so the pty's echo of the command line never matches: only the output does.
    type_line(
        &mut client,
        &format!(
            "echo \"{}\"\"{}\"; echo \"PID=$$=\"",
            &marker[..3],
            &marker[3..]
        ),
    );
    let mut reader = ClientReader::new(&mut client);
    let seen = reader.read_until("=\r\n", Duration::from_secs(10));
    assert!(
        seen.contains(marker),
        "the shell never answered; got {seen:?}"
    );
    // The last one: the pty's echo of the command line comes first and holds `$$`, not a pid.
    let pid = seen
        .rsplit("PID=")
        .next()
        .and_then(|rest| rest.split('=').next())
        .and_then(|pid| pid.trim().parse::<i32>().ok())
        .unwrap_or_else(|| panic!("no pid in {seen:?}"));
    client.kill().expect("kill client");
    client.wait().expect("reap client");
    assert!(
        wait_for(Duration::from_secs(5), || list_sessions(socket)
            .contains("detached")),
        "the session never detached"
    );
    pid
}

/// Everything the acceptance criteria ask of a successful hand-off, on one session: the same
/// agent pid, the same shell and its pid, a socket never unbound, a reattaching client repainted,
/// and the shell's exit code still reaching the client, which only the shell's parent can know.
#[test]
fn a_hand_off_keeps_every_shell_its_pid_and_its_exit_code() {
    let workspace = Workspace::new("keeps");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);
    let session = "4a4a4a4a-0000-4000-8000-000000000001";
    let shell = detached_session(&socket, session, "BEFORE-HANDOFF");
    let socket_inode = std::fs::metadata(&socket).expect("socket").ino();

    let output = hand_off(&socket, &agent_binary(), true);
    assert!(
        output.status.success(),
        "hand-off failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "handed off");

    assert!(
        agent.try_wait().expect("wait").is_none(),
        "the agent's pid must survive the hand-off"
    );
    // `bind` makes a new inode, so an unchanged one is a socket that was never unbound.
    assert_eq!(
        std::fs::metadata(&socket).expect("socket").ino(),
        socket_inode
    );
    assert!(alive(shell), "the shell did not survive the hand-off");
    assert!(list_sessions(&socket).contains(session));

    let mut client = attach(&socket, session);
    let mut reader = ClientReader::new(&mut client);
    if has_terminal_state() {
        let seen = reader.read_until("BEFORE-HANDOFF", Duration::from_secs(10));
        assert!(
            seen.contains("BEFORE-HANDOFF"),
            "the new program did not repaint the screen the old one had; got {seen:?}"
        );
    }
    std::thread::sleep(Duration::from_millis(200));
    type_line(&mut client, "echo \"SAME=\"\"$$=\"");
    let seen = reader.read_until(&format!("SAME={shell}="), Duration::from_secs(10));
    assert!(
        seen.contains(&format!("SAME={shell}=")),
        "a different shell answered after the hand-off; got {seen:?}"
    );

    type_line(&mut client, "exit 7");
    assert!(
        wait_for(Duration::from_secs(10), || matches!(
            client.try_wait(),
            Ok(Some(_))
        )),
        "the client did not exit after its shell did"
    );
    assert_eq!(
        client.try_wait().expect("wait").expect("status").code(),
        Some(7),
        "the shell's exit code did not reach the client through the new program"
    );
}

/// The app asks on every launch, so asking an agent to become the binary it already is must
/// change nothing.
#[test]
fn the_binary_already_running_is_not_handed_to() {
    let workspace = Workspace::new("current");
    let socket = workspace.socket();
    let _agent = start_agent(&socket);
    let socket_inode = std::fs::metadata(&socket).expect("socket").ino();

    let output = hand_off(&socket, &agent_binary(), false);
    assert!(output.status.success());
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "current");
    assert_eq!(
        std::fs::metadata(&socket).expect("socket").ino(),
        socket_inode
    );
}

/// A binary that cannot start, or starts and cannot restore these sessions, is refused, and the
/// agent that refused it carries on with its sessions untouched. `/usr/bin/false` stands in for a
/// build that predates hand-off: it exits non-zero on `handoff-check` as such a build does.
#[test]
fn a_binary_that_cannot_restore_is_refused_and_the_agent_keeps_running() {
    let workspace = Workspace::new("refused");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);
    let session = "4a4a4a4a-0000-4000-8000-000000000002";
    let shell = detached_session(&socket, session, "STILL-HERE");

    let missing = workspace.dir.join("no-such-agent");
    let refusals = [
        (missing.clone(), "cannot read"),
        (PathBuf::from("/usr/bin/false"), "cannot restore"),
    ];
    for (binary, reason) in refusals {
        let output = hand_off(&socket, &binary, true);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(output.status.code(), Some(1), "{binary:?}: {stderr}");
        assert!(stderr.contains(reason), "{binary:?}: {stderr}");
    }

    assert!(agent.try_wait().expect("wait").is_none());
    assert!(alive(shell));
    let mut client = attach(&socket, session);
    let mut reader = ClientReader::new(&mut client);
    std::thread::sleep(Duration::from_millis(300));
    type_line(&mut client, "echo \"SAME=\"\"$$=\"");
    let seen = reader.read_until(&format!("SAME={shell}="), Duration::from_secs(10));
    assert!(seen.contains(&format!("SAME={shell}=")), "got {seen:?}");
}

/// An agent that predates hand-off is never sent the request, so it keeps running. A fake agent
/// that greets as protocol 5 records everything the client sends after its own greeting.
#[test]
fn an_agent_that_predates_hand_off_is_not_asked() {
    let workspace = Workspace::new("predates");
    let socket = workspace.socket();
    let listener = std::os::unix::net::UnixListener::bind(&socket).expect("bind");
    let recorder = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let hello = wr_agent::protocol::envelope::Hello {
            protocol_version: 5,
            build: "wr-agent old".into(),
        };
        stream.write_all(&hello.encode()).expect("greet");
        let mut received = Vec::new();
        let _ = stream.read_to_end(&mut received);
        received
    });

    let output = hand_off(&socket, &agent_binary(), true);
    assert_eq!(output.status.code(), Some(3));
    let received = recorder.join().expect("recorder");
    let (greeting, _) = wr_agent::protocol::envelope::Hello::decode(&received)
        .expect("a greeting")
        .expect("a whole greeting");
    let greeting_length = greeting.encode().len();
    assert_eq!(
        received.len(),
        greeting_length,
        "the client sent something after its greeting: {:?}",
        &received[greeting_length..]
    );
}

/// The residual risk, done on purpose: a binary that passes the check and then dies while it
/// restores. This records exactly what is lost.
///
/// - Every session: the dead program held every pty master, so every shell is hung up.
/// - The socket answers nothing: its path is still there, and nothing listens on it.
/// - Nothing else: the next agent starts clean on the same path, and removes the table the dead
///   program never read (which holds the lost screens).
#[test]
fn a_binary_that_dies_while_restoring_loses_every_session() {
    let workspace = Workspace::new("crash");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);
    let session = "4a4a4a4a-0000-4000-8000-000000000003";
    let shell = detached_session(&socket, session, "LOST-SCREEN");

    // Passes the check by handing it to the real binary, then dies as the new program.
    let dying = workspace.dir.join("dying-agent");
    std::fs::write(
        &dying,
        format!(
            "#!/bin/sh\nif [ \"$1\" = handoff-check ]; then exec '{}' \"$@\"; fi\nexit 70\n",
            agent_binary().display()
        ),
    )
    .expect("script");
    std::fs::set_permissions(&dying, std::fs::Permissions::from_mode(0o755)).expect("chmod");

    let output = hand_off(&socket, &dying, false);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(1), "{stderr}");
    assert!(stderr.contains("did not answer"), "{stderr}");

    assert!(
        wait_for(Duration::from_secs(5), || matches!(
            agent.try_wait(),
            Ok(Some(_))
        )),
        "the dead program's process should have exited"
    );
    assert_eq!(
        agent.try_wait().expect("wait").expect("status").code(),
        Some(70)
    );
    assert!(
        wait_for(Duration::from_secs(5), || !alive(shell)),
        "the shell should have been hung up with its pty"
    );
    assert!(socket.exists(), "the socket's path is left behind");
    assert!(
        std::os::unix::net::UnixStream::connect(&socket).is_err(),
        "nothing should be listening on it"
    );
    let table = socket.with_extension("handoff");
    assert!(table.exists(), "the unread table is left behind");

    let _next = start_agent(&socket);
    assert!(
        wait_for(Duration::from_secs(5), || {
            std::os::unix::net::UnixStream::connect(&socket).is_ok()
        }),
        "the next agent should serve the same path"
    );
    assert!(
        wait_for(Duration::from_secs(5), || !table.exists()),
        "the next agent should remove the dead program's table"
    );
    assert!(
        !list_sessions(&socket).contains(session),
        "the lost session cannot come back"
    );
}

/// A requester that stops waiting calls the hand-off off. The app gives up after a few seconds and
/// goes on to attach its panes, and an exec after that would drop every one of them.
///
/// The binary checks slowly and then dies as the new program, so if the hand-off went ahead the
/// agent would exit.
#[test]
fn a_hand_off_nobody_is_waiting_for_is_called_off() {
    use wr_agent::protocol::envelope::{Envelope, Hello, Service};
    use wr_agent::protocol::frame::{Frame, FrameKind};

    let workspace = Workspace::new("abandoned");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);
    let session = "4a4a4a4a-0000-4000-8000-000000000004";
    let shell = detached_session(&socket, session, "KEPT-SCREEN");

    let slow = workspace.dir.join("slow-agent");
    std::fs::write(
        &slow,
        format!(
            "#!/bin/sh\nif [ \"$1\" = handoff-check ]; then sleep 1; exec '{}' \"$@\"; fi\nexit 70\n",
            agent_binary().display()
        ),
    )
    .expect("script");
    std::fs::set_permissions(&slow, std::fs::Permissions::from_mode(0o755)).expect("chmod");

    let mut stream = std::os::unix::net::UnixStream::connect(&socket).expect("connect");
    let hello = Hello {
        protocol_version: 6,
        build: "test".into(),
    };
    stream.write_all(&hello.encode()).expect("greet");
    // The agent's greeting, read so the connection is still open when it reaches the request.
    let mut greeting = [0u8; 64];
    let _ = stream.read(&mut greeting).expect("greeting");
    let mut payload = vec![0u8];
    payload.extend_from_slice(std::os::unix::ffi::OsStrExt::as_bytes(slow.as_os_str()));
    let request = Frame::new(FrameKind::HandOff, payload);
    stream
        .write_all(&Envelope::new(Service::Control, 0, request.encode()).encode())
        .expect("request");
    // Gone while the binary is still checking.
    std::thread::sleep(Duration::from_millis(300));
    drop(stream);

    std::thread::sleep(Duration::from_millis(2500));
    assert!(
        agent.try_wait().expect("wait").is_none(),
        "the hand-off went ahead with nobody waiting for it"
    );
    assert!(alive(shell));
    assert!(list_sessions(&socket).contains(session));
    assert!(!socket.with_extension("handoff").exists());
}
