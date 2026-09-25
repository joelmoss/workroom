//! Hand-off (#230): a running agent replaces its own program and keeps every session.
//!
//! Real processes over a real socket, like `attach_survives_detach.rs`, because what these check
//! only exists across `execve`: the same pid still parenting the same shells, a socket that was
//! never unbound, and what dies with a program that fails after the exec.

use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output};
use std::time::{Duration, Instant};
use wr_agent::protocol::envelope::{Envelope, Hello, Service};
use wr_agent::protocol::frame::{Frame, FrameKind};

mod common;
use common::*;

fn type_line(client: &mut Child, line: &str) {
    let stdin = client.stdin.as_mut().expect("stdin");
    stdin.write_all(line.as_bytes()).expect("write");
    stdin.write_all(b"\n").expect("write");
    stdin.flush().expect("flush");
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

fn alive(pid: i32) -> bool {
    unsafe { libc::kill(pid, 0) == 0 }
}

/// A raw client connection, greeted: the agent has accepted it and is waiting for requests.
fn greeted(socket: &Path) -> UnixStream {
    let mut stream = UnixStream::connect(socket).expect("connect");
    let hello = Hello {
        protocol_version: 6,
        build: "test".into(),
    };
    stream.write_all(&hello.encode()).expect("greet");
    // The agent's greeting, read so the connection is still open when it reaches a request.
    let mut greeting = [0u8; 64];
    let _ = stream.read(&mut greeting).expect("greeting");
    stream
}

/// Asks, unforced, for a hand-off to `binary` on an already greeted connection.
fn ask_to_hand_off(stream: &mut UnixStream, binary: &Path) {
    let mut payload = vec![0u8];
    payload.extend_from_slice(std::os::unix::ffi::OsStrExt::as_bytes(binary.as_os_str()));
    let request = Frame::new(FrameKind::HandOff, payload);
    stream
        .write_all(&Envelope::new(Service::Control, 0, request.encode()).encode())
        .expect("request");
}

/// A fake agent's side of an attach up to the answer: greets, then reads the client's greeting
/// and its whole attach request. The request carries the environment and can be larger than the
/// socket's buffer, so it is read until the client goes quiet: stop early and the client's write
/// blocks until this side closes.
fn greet_an_attach(stream: &mut UnixStream) {
    let hello = Hello {
        protocol_version: 6,
        build: "fake".into(),
    };
    stream.write_all(&hello.encode()).expect("greet");
    let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
    let mut request = [0u8; 4096];
    while matches!(stream.read(&mut request), Ok(n) if n > 0) {}
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
    // Let the shell finish echoing, so none of it reaches the next client as live output.
    reader.drain(Duration::from_millis(200));
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
    let not_executable = workspace.dir.join("not-executable");
    std::fs::write(&not_executable, b"not a binary").expect("write");
    let refusals = [
        (missing.clone(), "cannot read"),
        (PathBuf::from("/usr/bin/false"), "cannot restore"),
        // A relative `--binary` is refused before anything is read or spawned.
        (PathBuf::from("wr-agent"), "is not an absolute path"),
        // Readable (so `digest` succeeds) but not executable: the check's own spawn fails,
        // distinct from a spawned check that exits non-zero.
        (not_executable.clone(), "could not start"),
        // Not a regular file: reading it to its end would never finish.
        (PathBuf::from("/dev/zero"), "not a regular file"),
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

/// A check that never answers is not waited out forever: `CHECK_TIMEOUT` (3s) kills it and
/// refuses, distinct from `a_binary_that_cannot_restore_is_refused_and_the_agent_keeps_running`
/// above, where the check exits quickly and non-zero. `exec sleep` so the check IS the timed-out
/// process (no child of its own left holding the pty/pipe once killed).
#[test]
fn a_check_that_never_finishes_is_refused_after_its_timeout() {
    let workspace = Workspace::new("checktimeout");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);
    let session = "4a4a4a4a-0000-4000-8000-000000000008";
    let shell = detached_session(&socket, session, "STILL-CHECKING");

    let hangs = workspace.dir.join("hangs-forever");
    std::fs::write(
        &hangs,
        "#!/bin/sh\nif [ \"$1\" = handoff-check ]; then exec sleep 30; fi\nexit 70\n",
    )
    .expect("script");
    std::fs::set_permissions(&hangs, std::fs::Permissions::from_mode(0o755)).expect("chmod");

    let started = Instant::now();
    let output = hand_off(&socket, &hangs, true);
    assert_eq!(output.status.code(), Some(1));
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("did not check the sessions within 3s"),
        "{stderr}"
    );
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "the refusal should land soon after the 3s deadline, took {:?}",
        started.elapsed()
    );

    assert!(agent.try_wait().expect("wait").is_none());
    assert!(alive(shell));
    assert!(list_sessions(&socket).contains(session));
}

/// A check that says far more than a pipe holds (a panic's backtrace, or a hostile binary) is
/// refused on its exit status, promptly, with a bounded reason. Unbounded, it read as a timeout,
/// and repeating it whole overflowed the reply frame, which panics the connection's thread.
#[test]
fn a_check_that_floods_stderr_is_refused_with_a_bounded_reason() {
    let workspace = Workspace::new("loud");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);

    let loud = workspace.dir.join("loud-agent");
    std::fs::write(
        &loud,
        "#!/bin/sh
head -c 2000000 /dev/zero | tr '\\0' x >&2
exit 1
",
    )
    .expect("script");
    std::fs::set_permissions(&loud, std::fs::Permissions::from_mode(0o755)).expect("chmod");

    let output = hand_off(&socket, &loud, true);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(1),
        "{}",
        &stderr[..stderr.len().min(200)]
    );
    assert!(
        stderr.contains("cannot restore"),
        "{}",
        &stderr[..stderr.len().min(200)]
    );
    assert!(
        stderr.len() < 8192,
        "the reason was not bounded: {} bytes",
        stderr.len()
    );
    assert!(agent.try_wait().expect("wait").is_none());
    // The same agent still answers, so the connection that carried the refusal did not panic.
    let again = hand_off(&socket, &agent_binary(), false);
    assert_eq!(String::from_utf8_lossy(&again.stdout).trim(), "current");
}

/// A second hand-off asked while one is still checking a candidate binary waits for it: the agent
/// stops accepting during a hand-off (`crate::handoff::accepting`), so the second request is taken
/// only once the first is over, here refused. `IN_PROGRESS` still guards one connection asking
/// twice.
#[test]
fn a_second_hand_off_while_one_is_checking_waits_for_it() {
    let workspace = Workspace::new("concurrent");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);
    let session = "4a4a4a4a-0000-4000-8000-000000000007";
    let shell = detached_session(&socket, session, "ONE-AT-A-TIME");

    let slow = workspace.dir.join("slow-checker");
    std::fs::write(
        &slow,
        "#!/bin/sh\nif [ \"$1\" = handoff-check ]; then sleep 2; exit 1; fi\nexit 70\n",
    )
    .expect("script");
    std::fs::set_permissions(&slow, std::fs::Permissions::from_mode(0o755)).expect("chmod");

    let socket_for_first = socket.clone();
    let first = std::thread::spawn(move || hand_off(&socket_for_first, &slow, true));
    // Inside the first request's 2s check.
    std::thread::sleep(Duration::from_millis(300));

    let started = Instant::now();
    let second = hand_off(&socket, &agent_binary(), true);
    assert!(
        started.elapsed() > Duration::from_secs(1),
        "the second request was answered while the first was still checking"
    );
    assert_eq!(
        String::from_utf8_lossy(&second.stdout).trim(),
        "handed off",
        "{}",
        String::from_utf8_lossy(&second.stderr)
    );

    let first = first.join().expect("first hand-off");
    assert_eq!(first.status.code(), Some(1), "{first:?}");
    assert!(String::from_utf8_lossy(&first.stderr).contains("cannot restore"));

    assert!(agent.try_wait().expect("wait").is_none());
    assert!(alive(shell));
    assert!(list_sessions(&socket).contains(session));
}

/// More than one session, and a hand-off right after a hand-off: both shells survive together,
/// the adopted program recomputes its own digest (so an unforced ask says `current`), and it
/// survives being handed off to itself again — exercising the `--handoff` argument-stripping
/// branch of `exec()` and `Pty::adopt` on a pty this process already adopted once.
#[test]
fn a_hand_off_carries_every_session_and_survives_a_second_one() {
    let workspace = Workspace::new("chained");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);
    let session_a = "4a4a4a4a-0000-4000-8000-000000000005";
    let session_b = "4a4a4a4a-0000-4000-8000-000000000006";
    let shell_a = detached_session(&socket, session_a, "FIRST-SESSION");
    let shell_b = detached_session(&socket, session_b, "SECOND-SESSION");

    let output = hand_off(&socket, &agent_binary(), true);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "handed off");
    assert!(agent.try_wait().expect("wait").is_none());

    // The adopted program recomputed its own digest at startup, so asking it to become the
    // binary it already is (unforced) says `current` rather than handing off again.
    let output = hand_off(&socket, &agent_binary(), false);
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "current");

    let output = hand_off(&socket, &agent_binary(), true);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "handed off");
    assert!(agent.try_wait().expect("wait").is_none());

    for (session, shell) in [(session_a, shell_a), (session_b, shell_b)] {
        assert!(alive(shell), "session {session} did not survive");
        let mut client = attach(&socket, session);
        let mut reader = ClientReader::new(&mut client);
        std::thread::sleep(Duration::from_millis(200));
        type_line(&mut client, "echo \"SAME=\"\"$$=\"");
        let seen = reader.read_until(&format!("SAME={shell}="), Duration::from_secs(10));
        assert!(
            seen.contains(&format!("SAME={shell}=")),
            "session {session}: a different shell answered after two hand-offs; got {seen:?}"
        );
    }
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

    let mut stream = greeted(&socket);
    ask_to_hand_off(&mut stream, &slow);
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

/// A pane that connects while a hand-off is under way is not accepted by the program about to be
/// replaced: it waits in the listener's backlog and is attached by the new one.
#[test]
fn a_client_that_connects_during_a_hand_off_is_attached_by_the_new_program() {
    let workspace = Workspace::new("during");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);

    // Checks slowly, then becomes the real agent.
    let slow = workspace.dir.join("slow-agent");
    std::fs::write(
        &slow,
        format!(
            "#!/bin/sh\nif [ \"$1\" = handoff-check ]; then sleep 1; fi\nexec '{}' \"$@\"\n",
            agent_binary().display()
        ),
    )
    .expect("script");
    std::fs::set_permissions(&slow, std::fs::Permissions::from_mode(0o755)).expect("chmod");

    let handing_off = {
        let socket = socket.clone();
        std::thread::spawn(move || hand_off(&socket, &slow, false))
    };
    // Inside the slow check: the old program has stopped accepting.
    std::thread::sleep(Duration::from_millis(400));
    let mut client = attach(&socket, "4a4a4a4a-0000-4000-8000-000000000010");
    let output = handing_off.join().expect("hand-off thread");
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "handed off",
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let mut reader = ClientReader::new(&mut client);
    std::thread::sleep(Duration::from_millis(300));
    type_line(&mut client, "echo \"AFTER\"\"-HANDOFF\"");
    let seen = reader.read_until("AFTER-HANDOFF", Duration::from_secs(10));
    assert!(seen.contains("AFTER-HANDOFF"), "got {seen:?}");
    assert!(agent.try_wait().expect("wait").is_none());
}

/// An agent that closes before answering an attach is most likely handing off, so the client sends
/// the attach again rather than giving the pane a plain shell. A fake agent drops the first
/// connection unanswered and answers the second.
#[test]
fn an_attach_the_agent_drops_unanswered_is_sent_again() {
    let workspace = Workspace::new("resend");
    let socket = workspace.socket();
    let listener = std::os::unix::net::UnixListener::bind(&socket).expect("bind");
    let fake = std::thread::spawn(move || {
        let (mut first, _) = listener.accept().expect("first");
        greet_an_attach(&mut first);
        drop(first);
        let (mut second, _) = listener.accept().expect("second");
        greet_an_attach(&mut second);
        for frame in [
            Frame::control(FrameKind::Attached),
            Frame::new(FrameKind::Output, b"ANSWERED-SECOND\r\n".to_vec()),
            Frame::new(FrameKind::Exited, 0i32.to_be_bytes().to_vec()),
        ] {
            let service = if frame.kind == FrameKind::Attached {
                Service::Control
            } else {
                Service::Terminal
            };
            second
                .write_all(&Envelope::new(service, 1, frame.encode()).encode())
                .expect("answer");
        }
        std::thread::sleep(Duration::from_millis(500));
    });

    let mut client = attach(&socket, "4a4a4a4a-0000-4000-8000-000000000011");
    let mut reader = ClientReader::new(&mut client);
    let seen = reader.read_until("ANSWERED-SECOND", Duration::from_secs(10));
    if !seen.contains("ANSWERED-SECOND") {
        let _ = client.kill();
        let mut stderr = String::new();
        let _ = client
            .stderr
            .take()
            .expect("stderr")
            .read_to_string(&mut stderr);
        panic!("got {seen:?}; the client said {stderr:?}");
    }
    assert!(wait_for(Duration::from_secs(5), || matches!(
        client.try_wait(),
        Ok(Some(_))
    )));
    assert_eq!(
        client.try_wait().expect("wait").expect("status").code(),
        Some(0)
    );
    fake.join().expect("fake agent");
}

/// An agent that keeps closing attaches unanswered is not retried forever: after 10s the pane gets
/// the plain shell every other failed attach gets.
#[test]
fn an_attach_the_agent_never_answers_falls_back_to_a_shell() {
    let workspace = Workspace::new("unanswered");
    let socket = workspace.socket();
    let listener = std::os::unix::net::UnixListener::bind(&socket).expect("bind");
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            greet_an_attach(&mut stream);
        }
    });

    let started = Instant::now();
    let mut client = attach(&socket, "4a4a4a4a-0000-4000-8000-000000000012");
    let mut reader = ClientReader::new(&mut client);
    // Buffered until the fallback shell reads it; nothing reads stdin before an attach is answered.
    type_line(&mut client, "echo \"FALLBACK\"-$WORKROOM_SESSION_FALLBACK");
    let seen = reader.read_until("FALLBACK-1", Duration::from_secs(20));
    assert!(seen.contains("FALLBACK-1"), "got {seen:?}");
    assert!(
        started.elapsed() >= Duration::from_secs(9),
        "gave up after {:?}, before the retry deadline",
        started.elapsed()
    );
}

/// A hand-off asked for while another is still checking is refused, not queued. The listener's
/// pause keeps new connections out; this is a connection the agent had already accepted.
#[test]
fn a_hand_off_asked_for_during_another_is_refused() {
    let workspace = Workspace::new("in-progress");
    let socket = workspace.socket();
    let mut agent = start_agent(&socket);

    let slow = workspace.dir.join("slow-checker");
    std::fs::write(
        &slow,
        "#!/bin/sh\nif [ \"$1\" = handoff-check ]; then sleep 2; exit 1; fi\nexit 70\n",
    )
    .expect("script");
    std::fs::set_permissions(&slow, std::fs::Permissions::from_mode(0o755)).expect("chmod");

    // Both greeted before either asks: once one asks, the agent accepts nobody new.
    let mut first = greeted(&socket);
    let mut second = greeted(&socket);
    ask_to_hand_off(&mut first, &slow);
    // Inside the first request's 2s check.
    std::thread::sleep(Duration::from_millis(300));
    ask_to_hand_off(&mut second, &slow);

    let _ = second.set_read_timeout(Some(Duration::from_secs(1)));
    let mut reply = Vec::new();
    let mut buffer = [0u8; 4096];
    while let Ok(n @ 1..) = second.read(&mut buffer) {
        reply.extend_from_slice(&buffer[..n]);
    }
    let reply = String::from_utf8_lossy(&reply);
    assert!(
        reply.contains("another hand-off is in progress"),
        "got {reply:?}"
    );

    drop(first);
    assert!(agent.try_wait().expect("wait").is_none());
}
