//! The remote path, tested without a remote.
//!
//! The driver contract is a bidirectional byte stream, so `ssh host wr-agent serve --stdio`, a
//! provider's exec channel and a local socket are the same code path. That means almost all of the
//! remote behaviour can be exercised here: over a pipe, in this process, with no container, no ssh,
//! no provider and no network.
//!
//! A pipe is the honest stand-in rather than a convenient one. It has no message boundaries, no
//! socket options, and it can split a write anywhere — exactly the properties a remote stream has
//! and a unix socket hides. The bugs this catches are framing and lifecycle bugs, which is where
//! a transport change actually breaks things.
//!
//! **What this cannot cover, and what a container is still for:** another machine, its own process
//! space, a real ssh hop, and pushing the agent binary to a host that does not have it. Those are
//! the driver's job, not the protocol's. The ssh hop is covered at the end of this file, by tests
//! that are ignored unless `vcs/scripts/ssh-fixture/run.sh` has started the container they need.

use std::io::{Read, Write};
use std::os::fd::OwnedFd;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use wr_agent::protocol::envelope::{Envelope, EnvelopeDecoder, Hello, Service};
use wr_agent::protocol::frame::{Frame, FrameDecoder, FrameKind};
use wr_agent::screens::Screens;
use wr_agent::serve::{handle_connection, AttachRequest};
use wr_agent::session::{SessionId, SessionStore};
use wr_agent::transport::{close, set_nonblocking, FdStream, PipeTransport};

/// Drives an agent from the client side of a stream, speaking the real protocol.
struct Client {
    reader: FdStream,
    writer: FdStream,
    decoder: EnvelopeDecoder,
    seen: Vec<u8>,
    /// Envelopes for every service but Terminal, kept until `envelope` asks for them. Terminal
    /// output keeps flowing while a request is in flight, and neither may eat the other's bytes.
    other: Vec<Envelope>,
}

impl Client {
    /// One read that honours a deadline. The reader is non-blocking, so `WouldBlock` means "not
    /// yet" rather than an error — treating it as one is what made every read site here either
    /// hang or spuriously fail.
    fn read_some(&mut self, buffer: &mut [u8], deadline: Instant) -> Option<usize> {
        while Instant::now() < deadline {
            match self.reader.read(buffer) {
                Ok(0) => return None,
                Ok(n) => return Some(n),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(_) => return None,
            }
        }
        None
    }

    fn handshake(&mut self) {
        self.writer
            .write_all(&Hello::current("test-client").encode())
            .expect("send hello");
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut greeting = Vec::new();
        let mut byte = [0u8; 1];
        loop {
            if let Ok(Some(_)) = Hello::decode(&greeting) {
                break;
            }
            let n = self
                .read_some(&mut byte, deadline)
                .expect("the agent closed the stream or never greeted");
            greeting.push(byte[..n][0]);
        }
    }

    fn send(&mut self, service: Service, stream: u32, frame: Frame) {
        self.writer
            .write_all(&Envelope::new(service, stream, frame.encode()).encode())
            .expect("send");
    }

    /// Sends a frame one byte at a time. A remote stream can split anywhere, and the agent must
    /// not care — a decoder that assumed whole frames would pass every other test here.
    fn send_bytewise(&mut self, service: Service, stream: u32, frame: Frame) {
        let bytes = Envelope::new(service, stream, frame.encode()).encode();
        for byte in bytes {
            self.writer.write_all(&[byte]).expect("send byte");
        }
    }

    /// Accumulates output until `needle` appears, or the deadline passes.
    fn read_until(&mut self, needle: &str, timeout: Duration) -> String {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if String::from_utf8_lossy(&self.seen).contains(needle) {
                break;
            }
            if !self.pump(deadline) {
                break;
            }
        }
        String::from_utf8_lossy(&self.seen).into_owned()
    }

    /// Reads once and sorts what arrived: terminal output into `seen`, the rest into `other`.
    /// False when the stream ended or the deadline passed.
    fn pump(&mut self, deadline: Instant) -> bool {
        let mut buffer = [0u8; 65536];
        let Some(n) = self.read_some(&mut buffer, deadline) else {
            return false;
        };
        self.decoder.push(&buffer[..n]);
        // A decode error panics here, naming itself, rather than surfacing later as a timeout.
        while let Some(envelope) = self.decoder.next_envelope().expect("a malformed envelope") {
            if envelope.service != Service::Terminal {
                self.other.push(envelope);
                continue;
            }
            let mut frames = FrameDecoder::new();
            frames.push(&envelope.payload);
            while let Some(frame) = frames.next_frame().expect("a malformed frame") {
                if frame.kind == FrameKind::Output {
                    self.seen.extend_from_slice(&frame.payload);
                }
            }
        }
        true
    }

    /// The next envelope on `service`/`stream`, or a panic naming what never came.
    fn envelope(&mut self, service: Service, stream: u32, timeout: Duration) -> Envelope {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(index) = self
                .other
                .iter()
                .position(|e| e.service == service && e.stream == stream)
            {
                return self.other.remove(index);
            }
            assert!(
                self.pump(deadline),
                "nothing arrived on {service:?} stream {stream}"
            );
        }
    }

    /// One request to a JSON service (VCS, File, Status): the request goes out as one envelope,
    /// and the reply comes back as chunks whose first byte says whether more follow.
    fn request(&mut self, service: Service, stream: u32, request: &Value) -> Value {
        self.writer
            .write_all(
                &Envelope::new(service, stream, serde_json::to_vec(request).unwrap()).encode(),
            )
            .expect("send request");
        let mut assembled = Vec::new();
        loop {
            let envelope = self.envelope(service, stream, Duration::from_secs(20));
            let (last, body) = envelope.payload.split_first().expect("empty reply chunk");
            assembled.extend_from_slice(body);
            if *last == 1 {
                return serde_json::from_slice(&assembled).expect("a JSON reply");
            }
        }
    }
}

/// Serves an agent over a pipe on a background thread, and hands back the client end.
fn serve_over_pipe(sessions: SessionStore) -> (Client, std::thread::JoinHandle<()>) {
    let pair = PipeTransport::pair().expect("pipe pair");
    let agent = pair.agent;
    let handle = std::thread::spawn(move || {
        let _ = handle_connection(agent, sessions);
    });
    set_nonblocking(&pair.client_reader).expect("non-blocking client reader");
    (
        Client {
            reader: pair.client_reader,
            writer: pair.client_writer,
            decoder: EnvelopeDecoder::new(),
            seen: Vec::new(),
            other: Vec::new(),
        },
        handle,
    )
}

fn attach_frame(id: [u8; 16]) -> Frame {
    let request = AttachRequest {
        id: Some(SessionId(id)),
        shell: Some("/bin/sh".into()),
        columns: 80,
        rows: 24,
        env: vec![("PATH".into(), "/usr/bin:/bin".into())],
        ..Default::default()
    };
    Frame::new(FrameKind::Attach, request.encode())
}

#[test]
fn a_session_works_over_a_pipe() {
    let sessions = SessionStore::new();
    let (mut client, handle) = serve_over_pipe(sessions.clone());
    client.handshake();
    client.send(Service::Terminal, 1, attach_frame([1u8; 16]));

    std::thread::sleep(Duration::from_millis(400));
    client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Input, b"echo OVER-A-PIPE\n".to_vec()),
    );

    let seen = client.read_until("OVER-A-PIPE", Duration::from_secs(10));
    assert!(seen.contains("OVER-A-PIPE"), "got {seen:?}");

    close(&client.writer);
    let _ = handle.join();
    sessions.kill_all();
}

/// The property a socket hides: a remote stream can deliver a frame in pieces.
#[test]
fn a_frame_split_byte_by_byte_still_works() {
    let sessions = SessionStore::new();
    let (mut client, handle) = serve_over_pipe(sessions.clone());
    client.handshake();
    client.send_bytewise(Service::Terminal, 1, attach_frame([2u8; 16]));

    std::thread::sleep(Duration::from_millis(400));
    client.send_bytewise(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Input, b"echo SPLIT-FRAME\n".to_vec()),
    );

    let seen = client.read_until("SPLIT-FRAME", Duration::from_secs(10));
    assert!(seen.contains("SPLIT-FRAME"), "got {seen:?}");

    close(&client.writer);
    let _ = handle.join();
    sessions.kill_all();
}

/// A remote link dropping is the client's end of the stream closing. The session must survive it —
/// that is the entire reason the feature exists — and the connection thread must not leak.
#[test]
fn the_session_survives_the_stream_dropping() {
    let sessions = SessionStore::new();
    let (mut client, handle) = serve_over_pipe(sessions.clone());
    client.handshake();
    client.send(Service::Terminal, 1, attach_frame([3u8; 16]));
    std::thread::sleep(Duration::from_millis(400));
    client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Input, b"MARK=kept\n".to_vec()),
    );
    std::thread::sleep(Duration::from_millis(300));

    // Drop the link.
    close(&client.writer);
    close(&client.reader);
    // The handler must return rather than hang on an idle shell that will never speak again.
    let joined = handle.join();
    assert!(joined.is_ok(), "the connection thread panicked");

    assert!(
        sessions.contains(SessionId([3u8; 16])),
        "the session must outlive the stream"
    );
    assert!(!sessions.list()[0].attached, "and be reported detached");

    // A second stream reaches the SAME shell.
    let (mut second, handle) = serve_over_pipe(sessions.clone());
    second.handshake();
    second.send(Service::Terminal, 1, attach_frame([3u8; 16]));
    std::thread::sleep(Duration::from_millis(400));
    second.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Input, b"echo VALUE=$MARK\n".to_vec()),
    );
    let seen = second.read_until("VALUE=kept", Duration::from_secs(10));
    assert!(
        seen.contains("VALUE=kept"),
        "the shell was restarted rather than reattached; got {seen:?}"
    );

    close(&second.writer);
    let _ = handle.join();
    sessions.kill_all();
}

/// A restored pane (`CREATE=0`) naming a session that ended with its host is shown the record the
/// agent kept of it (#232): `Attached`, the screen and the notice, then nothing. What it types
/// reaches no shell and creates no session. Killing it, which is the app closing the pane, removes
/// the record.
#[test]
fn a_restored_pane_is_shown_the_record_of_a_session_that_ended_with_its_host() {
    if !cfg!(feature = "terminal-state") {
        eprintln!("skipping: built without the terminal-state feature, so no record repaints");
        return;
    }
    let dir = std::env::temp_dir().join(format!("wr-records-pipe-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let sessions = SessionStore::new();
    sessions.keep_screens(Screens::open(&dir).expect("records"));
    let id = SessionId([0x31; 16]);
    let screens = sessions.screens().expect("screens");
    screens
        .save(id, 80, 24, b"RECORD-MARK\r\n$ ")
        .expect("record");

    let (mut client, handle) = serve_over_pipe(sessions.clone());
    client.handshake();
    let restored = AttachRequest {
        id: Some(id),
        columns: 80,
        rows: 24,
        existing_only: true,
        ..Default::default()
    };
    client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Attach, restored.encode()),
    );
    let seen = client.read_until("Close it to start again", Duration::from_secs(10));
    assert!(
        seen.contains("RECORD-MARK") && seen.contains("Close it to start again"),
        "the record was not shown; got {seen:?}"
    );

    client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Input, b"echo LIVE-$((1+1))\n".to_vec()),
    );
    let seen = client.read_until("LIVE-2", Duration::from_millis(500));
    assert!(!seen.contains("LIVE-2"), "input reached a shell: {seen:?}");
    assert!(sessions.list().is_empty(), "a session was created");

    // On Control, so the acknowledgement lands where `envelope` can wait for it.
    client.send(
        Service::Control,
        2,
        Frame::new(FrameKind::Kill, id.0.to_vec()),
    );
    client.envelope(Service::Control, 2, Duration::from_secs(5));
    assert!(
        screens.load(id).is_none(),
        "closing the pane kept its record"
    );

    close(&client.writer);
    let _ = handle.join();
    let _ = std::fs::remove_dir_all(&dir);
}

/// The record dispatch chunks with `crate::session::READ_CHUNK`, precisely because `Frame::encode`
/// PANICS above the protocol's frame cap rather than truncating (see the comment on that call
/// site in `serve.rs`). A record wide enough that its repaint needs more than one 8 KiB frame must
/// still arrive whole, not merely not panic.
#[test]
fn a_restored_pane_with_a_screen_over_one_frame_still_gets_it_whole() {
    if !cfg!(feature = "terminal-state") {
        eprintln!("skipping: built without the terminal-state feature, so no record repaints");
        return;
    }
    let dir = std::env::temp_dir().join(format!("wr-records-big-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let sessions = SessionStore::new();
    sessions.keep_screens(Screens::open(&dir).expect("records"));
    let id = SessionId([0x32; 16]);
    let screens = sessions.screens().expect("screens");

    // A grid wide and tall enough that redrawing every cell needs well over 8 KiB — one row of 200
    // 'x's, on every one of 100 rows, each row positioned explicitly so the emulator cannot fold it
    // into a single run.
    let mut big = Vec::new();
    for row in 1..=100u16 {
        big.extend_from_slice(format!("\x1b[{row};1H").as_bytes());
        big.extend_from_slice(&[b'x'; 200]);
    }
    big.extend_from_slice(b"RECORD-TAIL");
    screens.save(id, 200, 100, &big).expect("record");

    let (mut client, handle) = serve_over_pipe(sessions.clone());
    client.handshake();
    let restored = AttachRequest {
        id: Some(id),
        columns: 200,
        rows: 100,
        existing_only: true,
        ..Default::default()
    };
    client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Attach, restored.encode()),
    );
    let seen = client.read_until("Close it to start again", Duration::from_secs(10));
    assert!(
        seen.len() > wr_agent::session::READ_CHUNK,
        "the record fit in one frame; this test proves nothing about chunking. got {} bytes",
        seen.len()
    );
    assert!(
        seen.contains("RECORD-TAIL") && seen.contains("Close it to start again"),
        "a multi-frame record arrived truncated or out of order; got {} bytes",
        seen.len()
    );

    close(&client.writer);
    let _ = handle.join();
    let _ = std::fs::remove_dir_all(&dir);
}

/// A peer that is not an agent — an ssh banner, an MOTD, a login message — must be rejected, not
/// waited on. This is the failure mode of a real ssh hop, where the remote shell prints before the
/// agent ever starts.
#[test]
fn a_banner_on_the_stream_is_rejected() {
    let sessions = SessionStore::new();
    let pair = PipeTransport::pair().expect("pipe pair");
    let agent = pair.agent;
    let handle = std::thread::spawn(move || handle_connection(agent, sessions).is_err());

    let mut writer = pair.client_writer;
    writer
        .write_all(b"Welcome to Ubuntu 24.04 LTS\r\n")
        .expect("write banner");

    let rejected = handle.join().expect("thread");
    assert!(rejected, "a non-agent peer must be rejected");
    close(&writer);
}

// ---------------------------------------------------------------------------
// The same thing, but across a real process boundary.

fn agent_binary() -> std::path::PathBuf {
    match std::env::var_os("WR_AGENT_BIN") {
        Some(path) => std::path::PathBuf::from(path),
        None => std::path::PathBuf::from(env!("CARGO_BIN_EXE_wr-agent")),
    }
}

/// `serve --stdio` over a pair of pipes to a child process: everything an ssh hop exercises except
/// the network — argument handling, stdio wiring, and the agent serving a stream it does not own.
/// (Production goes through `relay` to a supervised agent instead; see the relay tests below.)
#[test]
fn serve_stdio_is_the_remote_entry_point() {
    let mut child = Command::new(agent_binary())
        .args(["serve", "--stdio"])
        .env("SHELL", "/bin/sh")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn serve --stdio");

    let mut input = child.stdin.take().expect("stdin");
    let mut output = child.stdout.take().expect("stdout");

    input
        .write_all(&Hello::current("test-client").encode())
        .expect("hello");
    input.flush().expect("flush");

    // Read the greeting before anything else, exactly as a driver would.
    let mut greeting = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        if let Ok(Some(_)) = Hello::decode(&greeting) {
            break;
        }
        assert!(output.read(&mut byte).expect("read") > 0, "no greeting");
        greeting.push(byte[0]);
    }

    input
        .write_all(&Envelope::new(Service::Terminal, 1, attach_frame([9u8; 16]).encode()).encode())
        .expect("attach");
    input.flush().expect("flush");
    std::thread::sleep(Duration::from_millis(400));
    input
        .write_all(
            &Envelope::new(
                Service::Terminal,
                1,
                Frame::new(FrameKind::Input, b"echo REMOTE-ENTRY-OK\n".to_vec()).encode(),
            )
            .encode(),
        )
        .expect("input");
    input.flush().expect("flush");

    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut decoder = EnvelopeDecoder::new();
        let mut seen = Vec::new();
        let mut buffer = [0u8; 4096];
        loop {
            let n = match output.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            decoder.push(&buffer[..n]);
            while let Ok(Some(envelope)) = decoder.next_envelope() {
                let mut frames = FrameDecoder::new();
                frames.push(&envelope.payload);
                while let Ok(Some(frame)) = frames.next_frame() {
                    if frame.kind == FrameKind::Output {
                        seen.extend_from_slice(&frame.payload);
                        let text = String::from_utf8_lossy(&seen).into_owned();
                        if text.contains("REMOTE-ENTRY-OK") {
                            let _ = tx.send(text);
                            return;
                        }
                    }
                }
            }
        }
        let _ = tx.send(String::from_utf8_lossy(&seen).into_owned());
    });

    let seen = rx
        .recv_timeout(Duration::from_secs(10))
        .unwrap_or_else(|_| String::from("<nothing>"));
    assert!(seen.contains("REMOTE-ENTRY-OK"), "got {seen:?}");

    // Closing the stream ends the agent: with no socket and no listener, the stream was the only
    // way in, so there is nothing left for it to serve.
    drop(input);
    let exited = {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            match child.try_wait() {
                Ok(Some(_)) => break true,
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(50))
                }
                _ => break false,
            }
        }
    };
    let _ = child.kill();
    assert!(exited, "serve --stdio should exit when its stream closes");
}

/// A resize must reach the shell, or every full-screen program renders at the geometry the session
/// happened to be created with. The agent accepted Resize frames long before anything sent one.
/// Two clients on one session, over the real wire: the size-owner policy end to end.
///
/// The unit tests drive `SessionStore` directly; this one goes through the envelope, so it also
/// proves each connection carries its OWN attachment token. Get that wrong and one client's
/// keystrokes claim the size on another's behalf, which is invisible to a test that never
/// multiplexes.
#[test]
fn a_second_client_takes_the_size_only_by_acting() {
    let sessions = SessionStore::new();
    let (mut first, first_handle) = serve_over_pipe(sessions.clone());
    first.handshake();
    first.send(Service::Terminal, 1, attach_frame([9u8; 16]));
    std::thread::sleep(Duration::from_millis(400));

    // A second window on the same session, with a window of its own.
    let (mut second, second_handle) = serve_over_pipe(sessions.clone());
    second.handshake();
    let request = AttachRequest {
        id: Some(SessionId([9u8; 16])),
        shell: Some("/bin/sh".into()),
        columns: 120,
        rows: 40,
        env: vec![("PATH".into(), "/usr/bin:/bin".into())],
        ..Default::default()
    };
    second.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Attach, request.encode()),
    );
    std::thread::sleep(Duration::from_millis(400));

    // Attaching does not take the size, and neither does resizing in the background.
    let mut payload = Vec::new();
    payload.extend_from_slice(&200u16.to_be_bytes());
    payload.extend_from_slice(&50u16.to_be_bytes());
    second.send(Service::Terminal, 1, Frame::new(FrameKind::Resize, payload));
    std::thread::sleep(Duration::from_millis(200));

    first.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Input, b"stty size\n".to_vec()),
    );
    let seen = first.read_until("24 80", Duration::from_secs(10));
    assert!(
        seen.contains("24 80"),
        "a second client's resize must not move the pty; the shell reported {seen:?}"
    );

    // Typing in the second window is what takes it, and the size it recorded applies at once.
    second.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Input, b"stty size\n".to_vec()),
    );
    let seen = second.read_until("50 200", Duration::from_secs(10));
    assert!(
        seen.contains("50 200"),
        "typing must claim the size and apply what was recorded; the shell reported {seen:?}"
    );

    close(&first.writer);
    close(&second.writer);
    let _ = first_handle.join();
    let _ = second_handle.join();
    sessions.kill_all();
}

#[test]
fn a_resize_reaches_the_shell() {
    let sessions = SessionStore::new();
    let (mut client, handle) = serve_over_pipe(sessions.clone());
    client.handshake();
    client.send(Service::Terminal, 1, attach_frame([4u8; 16]));
    std::thread::sleep(Duration::from_millis(400));

    let mut payload = Vec::new();
    payload.extend_from_slice(&120u16.to_be_bytes());
    payload.extend_from_slice(&40u16.to_be_bytes());
    client.send(Service::Terminal, 1, Frame::new(FrameKind::Resize, payload));
    std::thread::sleep(Duration::from_millis(200));

    // Ask the shell itself rather than trusting the frame was accepted: `stty size` reports what
    // the pty actually carries, which is the only thing a program in it will ever see.
    client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Input, b"stty size\n".to_vec()),
    );
    let seen = client.read_until("40 120", Duration::from_secs(10));
    assert!(
        seen.contains("40 120"),
        "the pty was not resized; the shell reported {seen:?}"
    );

    close(&client.writer);
    let _ = handle.join();
    sessions.kill_all();
}

/// A zero size means "no terminal" — a relay forked into a pipe reports it. Applying it would
/// reset the session to a default and reflow everything for nothing.
#[test]
fn a_zero_resize_is_ignored() {
    let sessions = SessionStore::new();
    let (mut client, handle) = serve_over_pipe(sessions.clone());
    client.handshake();
    client.send(Service::Terminal, 1, attach_frame([5u8; 16]));
    std::thread::sleep(Duration::from_millis(400));

    client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Resize, vec![0, 0, 0, 0]),
    );
    std::thread::sleep(Duration::from_millis(200));
    client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Input, b"stty size\n".to_vec()),
    );

    // Still the size it was attached at, not a default and not 0x0.
    let seen = client.read_until("24 80", Duration::from_secs(10));
    assert!(seen.contains("24 80"), "got {seen:?}");

    close(&client.writer);
    let _ = handle.join();
    sessions.kill_all();
}

// ---------------------------------------------------------------------------
// Through `relay`: the far side of a persistent remote stream (issue #228).
//
// `serve --stdio` above dies with its stream, and so do its sessions. Production instead runs one
// supervised `serve --idle-timeout never` on the remote host and reaches it through
// `ssh host wr-agent relay --socket <path>`, so a dropped link ends the relay and nothing else.

/// A client whose stream is a child process's stdio: `wr-agent relay`, or ssh running one.
struct Relay {
    child: Child,
    client: Client,
    /// The descriptors `client` borrows. `stdin` is an Option so a test can close it: EOF on its
    /// stdin is how a relay learns that sshd lost the link.
    stdin: Option<ChildStdin>,
    /// An Option for the same reason: dropping it is how a test hangs up the link's read side.
    /// Underscored because only the Linux-only hang-up test reads it.
    _stdout: Option<ChildStdout>,
}

impl Relay {
    fn spawn(mut command: Command) -> Relay {
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn relay");
        let stdin = child.stdin.take().expect("stdin");
        let stdout = child.stdout.take().expect("stdout");
        let reader = FdStream::new(stdout.as_raw_fd());
        set_nonblocking(&reader).expect("non-blocking relay stdout");
        Relay {
            child,
            client: Client {
                reader,
                writer: FdStream::new(stdin.as_raw_fd()),
                decoder: EnvelopeDecoder::new(),
                seen: Vec::new(),
                other: Vec::new(),
            },
            stdin: Some(stdin),
            _stdout: Some(stdout),
        }
    }

    /// Waits for the relay to exit by itself.
    fn exited_within(&mut self, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if let Ok(Some(_)) = self.child.try_wait() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        false
    }
}

/// SIGKILL, which is also how the ssh tests below drop a link: the client end dies mid-stream
/// with no goodbye.
impl Drop for Relay {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn relay_command(socket: &Path) -> Command {
    let mut command = Command::new(agent_binary());
    command.args(["relay", "--socket"]).arg(socket);
    command
}

/// A scratch directory for a socket, removed when the test ends.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let dir = std::env::temp_dir().join(format!("wr-relay-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        Scratch(dir)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// An agent killed when the test ends, panic or not. It runs with `--idle-timeout never`, so a
/// leaked one would hold its session's shell forever.
struct Agent(Child);

impl Drop for Agent {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

/// A supervised-style agent (`--idle-timeout never`) on `socket`, serving once this returns.
fn start_agent(socket: &Path) -> Agent {
    let agent = Agent(
        Command::new(agent_binary())
            .args(["serve", "--socket"])
            .arg(socket)
            .args(["--idle-timeout", "never"])
            .env("SHELL", "/bin/sh")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn agent"),
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while !socket.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    agent
}

/// The local half of the persistent remote path, with no ssh: a supervised-style agent, a relay
/// in front of it, and a relay killed mid-session. The next relay must reach the SAME shell.
#[test]
fn a_relay_reaches_the_same_agent_after_the_link_drops() {
    let scratch = Scratch::new("drop");
    let socket = scratch.0.join("agent.sock");
    let agent = start_agent(&socket);

    let mut first = Relay::spawn(relay_command(&socket));
    first.client.handshake();
    first
        .client
        .send(Service::Terminal, 1, attach_frame([0x28; 16]));
    std::thread::sleep(Duration::from_millis(400));
    first.client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Input, b"MARK=kept\n".to_vec()),
    );
    std::thread::sleep(Duration::from_millis(300));
    drop(first);

    let mut second = Relay::spawn(relay_command(&socket));
    second.client.handshake();
    second
        .client
        .send(Service::Terminal, 1, attach_frame([0x28; 16]));
    std::thread::sleep(Duration::from_millis(400));
    second.client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Input, b"echo VALUE=$MARK\n".to_vec()),
    );
    let seen = second
        .client
        .read_until("VALUE=kept", Duration::from_secs(10));

    // EOF on stdin ends the relay by itself, which is how it learns that sshd lost the link.
    drop(second.stdin.take());
    let exited = second.exited_within(Duration::from_secs(5));

    drop(agent);
    assert!(
        seen.contains("VALUE=kept"),
        "the relay reached a new shell rather than the one the first relay left; got {seen:?}"
    );
    assert!(exited, "a relay whose stdin closed must exit");
}

/// A client that closes its sending side still gets the replies already asked for: EOF on stdin
/// is a half-close, not a hang-up. Then the relay exits once the agent has closed its end.
#[test]
fn a_relay_delivers_replies_after_its_stdin_closes() {
    let scratch = Scratch::new("half-close");
    let socket = scratch.0.join("agent.sock");
    let _agent = start_agent(&socket);

    let mut relay = Relay::spawn(relay_command(&socket));
    relay.client.handshake();
    let request = serde_json::to_vec(&json!({"method": "status"})).unwrap();
    relay
        .client
        .writer
        .write_all(&Envelope::new(Service::Status, 1, request).encode())
        .expect("send request");
    drop(relay.stdin.take());

    let reply = relay
        .client
        .envelope(Service::Status, 1, Duration::from_secs(10));
    let reply: Value = serde_json::from_slice(&reply.payload[1..]).expect("a JSON reply");
    assert!(reply["result"]["verdict"].is_string(), "{reply}");
    assert!(
        relay.exited_within(Duration::from_secs(5)),
        "the relay must exit once the agent closes its end"
    );
}

/// An agent that has gone quiet (it neither reads nor writes) must not keep a relay alive after its
/// link is gone. Here the relay's stdin thread is stuck mid-write to the silent agent, so it never
/// sees stdin's EOF, and nothing arrives to write to stdout. Only the hang-up on stdout can end it.
///
/// Linux only, as the relay is: macOS's poll does not report a pipe's readers going away.
#[cfg(target_os = "linux")]
#[test]
fn a_relay_to_a_silent_agent_exits_when_its_link_hangs_up() {
    let scratch = Scratch::new("silent");
    let socket = scratch.0.join("agent.sock");
    let listener = std::os::unix::net::UnixListener::bind(&socket).expect("bind");
    // Accepts, then holds the connection without ever touching it.
    let held = std::thread::spawn(move || listener.accept().map(|(stream, _)| stream));

    let mut relay = Relay::spawn(relay_command(&socket));
    let mut stdin = relay.stdin.take().expect("stdin");
    // More than the socket and pipe buffers can hold, so the relay's copy blocks mid-write.
    std::thread::spawn(move || {
        let chunk = vec![0u8; 1 << 20];
        for _ in 0..16 {
            if stdin.write_all(&chunk).is_err() {
                return;
            }
        }
    });
    std::thread::sleep(Duration::from_millis(500));
    assert!(
        relay.child.try_wait().expect("try_wait").is_none(),
        "the relay should be stuck on the silent agent before the link hangs up"
    );

    drop(relay._stdout.take());
    let exited = relay.exited_within(Duration::from_secs(5));
    drop(held);
    assert!(
        exited,
        "a relay whose link hung up must exit, even with a silent agent"
    );
}

/// `--idle-timeout never` is what keeps a supervised agent up with no client. Beside an agent that
/// idles out after a second, and idle at least as long, it must still be serving.
#[test]
fn an_agent_with_idle_timeout_never_outlives_one_that_idles_out() {
    let scratch = Scratch::new("never");
    let forever_socket = scratch.0.join("forever.sock");
    let short_socket = scratch.0.join("short.sock");
    let mut forever = start_agent(&forever_socket);
    let mut short = Agent(
        Command::new(agent_binary())
            .args(["serve", "--socket"])
            .arg(&short_socket)
            .args(["--idle-timeout", "1"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn agent"),
    );

    let deadline = Instant::now() + Duration::from_secs(10);
    while short.0.try_wait().expect("try_wait").is_none() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(
        short.0.try_wait().expect("try_wait").is_some(),
        "the control never idled out, so this proves nothing"
    );
    assert!(
        forever.0.try_wait().expect("try_wait").is_none(),
        "`--idle-timeout never` exited while idle"
    );
    assert!(
        std::os::unix::net::UnixStream::connect(&forever_socket).is_ok(),
        "and it is still serving, not merely running"
    );
}

/// No agent is the supervisor's problem, and the relay must say so at once rather than start one.
/// Both shapes: no socket file at all, and a stale one from an agent that died.
#[test]
fn a_relay_with_no_agent_fails_fast_and_says_so() {
    let scratch = Scratch::new("none");
    let missing = scratch.0.join("missing.sock");
    let stale = scratch.0.join("stale.sock");
    drop(std::os::unix::net::UnixListener::bind(&stale).expect("bind"));
    assert!(stale.exists(), "the stale socket file stays behind");

    for socket in [missing, stale] {
        let started = Instant::now();
        let output = relay_command(&socket)
            .stdin(Stdio::null())
            .output()
            .expect("run relay");
        assert!(started.elapsed() < Duration::from_secs(5), "{socket:?}");
        assert_eq!(output.status.code(), Some(92), "{socket:?}");
        assert!(output.stdout.is_empty(), "nothing may reach the stream");
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert!(stderr.contains("no agent listening on"), "{stderr}");
    }
}

/// A tty, or an exec channel that is one socket, hands the relay ONE open file as both stdin and
/// stdout. Making stdout non-blocking for its bounded writes makes stdin non-blocking too, and a
/// relay that took "nothing to read yet" for the end of its input would hang up on the agent.
#[test]
fn a_relay_whose_stdin_and_stdout_are_one_socket_keeps_reading() {
    let scratch = Scratch::new("one-socket");
    let socket = scratch.0.join("agent.sock");
    let _agent = start_agent(&socket);

    let (ours, theirs) = std::os::unix::net::UnixStream::pair().expect("socketpair");
    let mut relay = relay_command(&socket)
        .stdin(OwnedFd::from(theirs.try_clone().expect("clone")))
        .stdout(OwnedFd::from(theirs))
        .spawn()
        .expect("spawn relay");
    // Long enough for the relay's first read of stdin to find nothing there.
    std::thread::sleep(Duration::from_millis(300));

    let reader = FdStream::new(ours.as_raw_fd());
    set_nonblocking(&reader).expect("non-blocking client reader");
    let mut client = Client {
        reader,
        writer: FdStream::new(ours.as_raw_fd()),
        decoder: EnvelopeDecoder::new(),
        seen: Vec::new(),
        other: Vec::new(),
    };
    client.handshake();
    let reply = client.request(Service::Status, 1, &json!({"method": "status"}));

    let _ = relay.kill();
    let _ = relay.wait();
    assert!(reply["result"]["verdict"].is_string(), "{reply}");
}

// ---------------------------------------------------------------------------
// Over real ssh, into the container fixture. Ignored by default: they need
// `vcs/scripts/ssh-fixture/run.sh`, which starts the container, pins its host key and runs these
// with `--ignored`. CI runs them in the `agent-linux` job.

struct Fixture {
    config: String,
    socket: String,
}

fn fixture() -> Fixture {
    let need = |name: &str| {
        std::env::var(name).unwrap_or_else(|_| {
            panic!("{name} is unset; run these through vcs/scripts/ssh-fixture/run.sh")
        })
    };
    Fixture {
        config: need("WR_SSH_FIXTURE_CONFIG"),
        socket: need("WR_SSH_FIXTURE_SOCKET"),
    }
}

impl Fixture {
    /// ssh to the fixture with ONLY the fixture's config (`-F`), so a developer's own
    /// `~/.ssh/config` cannot change what this test runs against.
    fn ssh(&self) -> Command {
        let mut command = Command::new("ssh");
        command.args(["-F", &self.config, "fixture"]);
        command
    }

    fn relay(&self) -> Relay {
        let mut command = self.ssh();
        command.args(["wr-agent", "relay", "--socket", &self.socket]);
        Relay::spawn(command)
    }

    /// Runs a shell command on the fixture and returns its stdout.
    fn run(&self, script: &str) -> String {
        let output = self.ssh().arg(script).output().expect("run ssh");
        assert!(
            output.status.success(),
            "`{script}` failed on the fixture: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    /// Stops and starts the container, as a provider stops and reboots a box: every process in it
    /// is killed outright (`-t 0`), and its disk is kept. The restart publishes a new port, so the
    /// config is pointed at it. run.sh pins the host key by alias, so the key still matches.
    fn reboot(&self) {
        let need = |name: &str| {
            std::env::var(name).unwrap_or_else(|_| {
                panic!("{name} is unset; run these through vcs/scripts/ssh-fixture/run.sh")
            })
        };
        let runtime = need("WR_SSH_FIXTURE_RUNTIME");
        let container = need("WR_SSH_FIXTURE_CONTAINER");
        let restarted = Command::new(&runtime)
            .args(["restart", "-t", "0", &container])
            .output()
            .expect("restart the fixture");
        assert!(
            restarted.status.success(),
            "`{runtime} restart` failed: {}",
            String::from_utf8_lossy(&restarted.stderr)
        );
        let published = Command::new(&runtime)
            .args(["port", &container, "22/tcp"])
            .output()
            .expect("read the fixture's port");
        let published = String::from_utf8_lossy(&published.stdout);
        let port = published
            .lines()
            .next()
            .and_then(|line| line.rsplit(':').next())
            .unwrap_or_else(|| panic!("no published port in {published:?}"))
            .trim()
            .to_string();
        let config: String = std::fs::read_to_string(&self.config)
            .expect("read the ssh config")
            .lines()
            .map(|line| match line.trim_start().starts_with("Port ") {
                true => format!("  Port {port}\n"),
                false => format!("{line}\n"),
            })
            .collect();
        std::fs::write(&self.config, config).expect("write the ssh config");
        // Up means sshd answers AND the supervisor has the agent serving, as run.sh waits for it.
        assert!(
            self.wait_for(
                &format!(
                    "wr-agent list --socket {} >/dev/null && echo up",
                    self.socket
                ),
                |out| out.contains("up")
            ),
            "the fixture did not come back from its reboot"
        );
    }

    /// Polls a command until its output satisfies `done`.
    fn wait_for(&self, script: &str, done: impl Fn(&str) -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            let output = self.ssh().arg(script).output().expect("run ssh");
            if done(&String::from_utf8_lossy(&output.stdout)) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
        false
    }
}

/// The supervised agent's pid on the fixture. Its argv0 is the installed binary beside the socket
/// (#231): `/run/workroom/wr-agent`, or the staged `/run/workroom/wr-agent.new.<pid>` a hand-off
/// exec'd, which the install then renamed into place.
const SUPERVISED_AGENT: &str = "pgrep -f '^/run/workroom/wr-agent[^ ]* serve'";
/// Where the app installs the agent on the fixture: beside the socket (#231).
const INSTALLED_AGENT: &str = "/run/workroom/wr-agent";

/// One POSIX shell word, as `AgentBootstrap` quotes for the host's shell.
fn sh_quoted(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// SHA-256 as `sha256sum` prints it, of a file on THIS machine (a Mac has `shasum`, not
/// `sha256sum`).
fn sha256_hex(path: &Path) -> String {
    let output = Command::new("sh")
        .args([
            "-c",
            "sha256sum \"$1\" 2>/dev/null || shasum -a 256 \"$1\"",
            "sha",
        ])
        .arg(path)
        .output()
        .expect("hash");
    String::from_utf8_lossy(&output.stdout)[..64].to_string()
}

/// The value of a `WRB <key> …` line in a bootstrap script's output.
fn reported(output: &str, key: &str) -> Option<String> {
    output
        .lines()
        .filter_map(|line| line.strip_prefix("WRB "))
        .find_map(|line| {
            line.strip_prefix(key)
                .and_then(|rest| rest.strip_prefix(' '))
        })
        .map(str::to_string)
}

impl Fixture {
    /// One of the app's far-side scripts (`macapp/Resources/agent-bootstrap`), run on the
    /// fixture the way `AgentBootstrap` runs it: `sh -c '<script>' <name> <args>`, with `stdin`
    /// piped in. Returns the exit status and what it printed, stderr after stdout.
    fn bootstrap(&self, name: &str, args: &[&str], stdin: Option<&Path>) -> (Option<i32>, String) {
        let script = std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../../macapp/Resources/agent-bootstrap")
                .join(format!("{name}.sh")),
        )
        .expect("the app's bootstrap script");
        let mut command = format!("sh -c {} {name}", sh_quoted(&script));
        for arg in args {
            command.push(' ');
            command.push_str(&sh_quoted(arg));
        }
        let mut ssh = self.ssh();
        ssh.arg(command);
        match stdin {
            Some(path) => {
                ssh.stdin(std::fs::File::open(path).expect("open stdin"));
            }
            None => {
                ssh.stdin(Stdio::null());
            }
        }
        let output = ssh.output().expect("run ssh");
        (
            output.status.code(),
            format!(
                "{}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            ),
        )
    }

    /// The supervised agent's pid, once there is exactly one.
    fn supervised_agent(&self) -> u32 {
        let pid = std::cell::Cell::new(None);
        assert!(
            self.wait_for(&format!("{SUPERVISED_AGENT} || true"), |out| {
                pid.set(out.trim().parse::<u32>().ok());
                pid.get().is_some()
            }),
            "no supervised agent is running"
        );
        pid.get().expect("pid")
    }
}

/// A pane as the app runs one on a remote host (#229): `wr-agent attach --no-spawn` over ssh,
/// its stdin and stdout piped here. No terminal on this side, so ssh allocates none on the host
/// either, and the attach there relays over pipes.
struct Pane {
    child: Child,
    stdin: ChildStdin,
    reader: FdStream,
    _stdout: ChildStdout,
    seen: Vec<u8>,
}

impl Pane {
    fn attach(fixture: &Fixture, session: &str, restored: bool) -> Pane {
        let mut command = fixture.ssh();
        command.arg(format!(
            "env WORKROOM_SESSION_ID={session} WORKROOM_SESSION_SOCKET={} \
             WORKROOM_SESSION_CWD=/home/workroom TERM=xterm-256color {INSTALLED_AGENT} attach \
             --no-spawn{}",
            fixture.socket,
            if restored { " --no-create" } else { "" }
        ));
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn pane");
        let stdin = child.stdin.take().expect("stdin");
        let stdout = child.stdout.take().expect("stdout");
        let reader = FdStream::new(stdout.as_raw_fd());
        set_nonblocking(&reader).expect("non-blocking pane stdout");
        Pane {
            child,
            stdin,
            reader,
            _stdout: stdout,
            seen: Vec::new(),
        }
    }

    fn type_line(&mut self, line: &str) {
        self.stdin.write_all(line.as_bytes()).expect("type");
        self.stdin.write_all(b"\n").expect("type");
        self.stdin.flush().expect("flush");
    }

    fn read_until(&mut self, needle: &str, timeout: Duration) -> String {
        let deadline = Instant::now() + timeout;
        let mut buffer = [0u8; 65536];
        while Instant::now() < deadline && !String::from_utf8_lossy(&self.seen).contains(needle) {
            match self.reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(n) => self.seen.extend_from_slice(&buffer[..n]),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(_) => break,
            }
        }
        String::from_utf8_lossy(&self.seen).into_owned()
    }

    /// ssh's exit status, which is the attach's: the shell's own once it exits, or 255 for a lost
    /// link. Stdin stays open until then, as a pane's does.
    fn exit_code(&mut self, timeout: Duration) -> Option<i32> {
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            if let Ok(Some(status)) = self.child.try_wait() {
                return status.code();
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        None
    }
}

/// SIGKILL to ssh: the link drops with no goodbye, and the session detaches.
impl Drop for Pane {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The bootstrap's far side (#231), through the app's own scripts over ssh: a host with no agent
/// gets this build installed and started; a host already holding it is pushed nothing; a host
/// running another build is handed off to this one with an attached pane's shell, its pid and
/// its exit code intact, and the pane comes back; and a binary that passes every check and then
/// dies restoring is refused after the fact, leaving the old file for the supervisor to restart.
#[test]
#[ignore = "needs the ssh container fixture: vcs/scripts/ssh-fixture/run.sh"]
fn over_ssh_the_bootstrap_installs_hands_off_and_survives_a_crashed_restore() {
    let fixture = fixture();
    let elf = PathBuf::from(
        std::env::var("WR_SSH_FIXTURE_AGENT").expect("run.sh exports WR_SSH_FIXTURE_AGENT"),
    );
    let sha = sha256_hex(&elf);
    let probe = |bundled: &str| {
        // The same digest for both architectures: the container's is whichever this machine runs.
        let (status, output) = fixture.bootstrap(
            "probe",
            &[INSTALLED_AGENT, &fixture.socket, "1", bundled, bundled],
            None,
        );
        assert_eq!(status, Some(0), "probe: {output}");
        output
    };
    let install = |binary: &Path| {
        fixture.bootstrap(
            "install",
            &[INSTALLED_AGENT, &fixture.socket, "1", &sha256_hex(binary)],
            Some(binary),
        )
    };

    // A host holding this build already: the probe finds it, and the running agent is current.
    let output = probe(&sha);
    assert!(output.contains("WRB host Linux "), "{output}");
    assert_eq!(
        reported(&output, "installed").as_deref(),
        Some(sha.as_str())
    );
    assert_eq!(
        reported(&output, "hand-off").as_deref(),
        Some("0 current"),
        "{output}"
    );

    // A host with no agent: the file removed first, so the supervisor's loop finds nothing to
    // restart once the agent is killed, and idles.
    // By argv0, not `pkill -x wr-agent`: after a hand-off the process name is the staged file's.
    fixture.run(&format!(
        "rm -f {INSTALLED_AGENT}; {} || true",
        SUPERVISED_AGENT.replace("pgrep", "pkill")
    ));
    assert!(
        fixture.wait_for(&format!("{SUPERVISED_AGENT} || true"), |out| out
            .trim()
            .is_empty()),
        "the supervisor kept an agent running with no binary"
    );
    let output = probe(&sha);
    assert_eq!(
        reported(&output, "installed").as_deref(),
        Some("none"),
        "{output}"
    );
    assert_eq!(
        reported(&output, "hand-off").as_deref(),
        Some("none"),
        "{output}"
    );
    let (status, output) = install(&elf);
    assert_eq!(status, Some(0), "install: {output}");
    assert_eq!(
        reported(&output, "outcome").as_deref(),
        Some("installed"),
        "{output}"
    );
    assert_eq!(
        reported(&output, "serving").as_deref(),
        Some("yes"),
        "{output}"
    );
    fixture.run(&format!("wr-agent list --socket {}", fixture.socket));
    fixture.run(&format!(
        "test -x {INSTALLED_AGENT} && ! ls {INSTALLED_AGENT}.new.* 2>/dev/null"
    ));
    let agent = fixture.supervised_agent();

    // A newer app: the same ELF with a byte appended, which the loader ignores and both hashes
    // notice. A pane is attached throughout.
    let newer = elf.with_file_name("wr-agent-newer");
    let mut bytes = std::fs::read(&elf).expect("read the agent");
    bytes.push(b'\n');
    std::fs::write(&newer, &bytes).expect("write the newer agent");
    let newer_sha = sha256_hex(&newer);
    let session = "7b7b7b7b-0000-4000-8000-000000000001";
    let mut pane = Pane::attach(&fixture, session, false);
    std::thread::sleep(Duration::from_millis(500));
    pane.type_line("echo SHELL=$$ MARK-$((40+2))");
    let seen = pane.read_until("MARK-42", Duration::from_secs(10));
    let shell = number_after(&seen, "SHELL=").unwrap_or_else(|| panic!("no shell pid in {seen:?}"));

    let output = probe(&newer_sha);
    assert_eq!(
        reported(&output, "installed").as_deref(),
        Some(sha.as_str())
    );
    assert_eq!(
        reported(&output, "hand-off").as_deref(),
        Some("none"),
        "{output}"
    );
    let (status, output) = install(&newer);
    assert_eq!(status, Some(0), "install: {output}");
    assert_eq!(
        reported(&output, "outcome").as_deref(),
        Some("handed-off"),
        "{output}"
    );
    assert_eq!(
        fixture.supervised_agent(),
        agent,
        "the agent's pid must survive the hand-off"
    );
    fixture.run(&format!("kill -0 {shell}"));
    // The pane's link to the agent ended with the exec, and it says so with ssh's own status for
    // a dropped link, which the app answers by attaching it again as a restored one.
    assert_eq!(pane.exit_code(Duration::from_secs(10)), Some(255));
    drop(pane);

    // Repainted by the new program, the same shell, and its exit code still reaches the pane.
    let mut pane = Pane::attach(&fixture, session, true);
    let seen = pane.read_until("MARK-42", Duration::from_secs(10));
    assert!(
        seen.contains("MARK-42"),
        "the new program did not repaint; got {seen:?}"
    );
    std::thread::sleep(Duration::from_millis(200));
    pane.type_line("echo SHELL-NOW=$$; exit 7");
    let seen = pane.read_until(&format!("SHELL-NOW={shell}"), Duration::from_secs(10));
    assert!(
        seen.contains(&format!("SHELL-NOW={shell}")),
        "another shell answered: {seen:?}"
    );
    assert_eq!(pane.exit_code(Duration::from_secs(10)), Some(7));
    drop(pane);

    // The same build again pushes nothing: the probe finds the file, and the agent is current.
    let output = probe(&newer_sha);
    assert_eq!(
        reported(&output, "installed").as_deref(),
        Some(newer_sha.as_str())
    );
    assert_eq!(
        reported(&output, "hand-off").as_deref(),
        Some("0 current"),
        "{output}"
    );

    // The one unrecoverable case: a binary that passes `protocol` and the restore check (both
    // handed to the real agent, as is `hand-off` itself: the staged file is the hand-off client)
    // and then dies as the new program. The hand-off reports it, the install refuses after the
    // fact and leaves the on-disk file alone, and the supervisor restarts THAT, so the host
    // recovers with a clean agent. The session is lost: its shell is hung up with its pty.
    let session = "7b7b7b7b-0000-4000-8000-000000000002";
    let mut pane = Pane::attach(&fixture, session, false);
    std::thread::sleep(Duration::from_millis(500));
    pane.type_line("echo SHELL=$$ MARK-$((40+3))");
    let seen = pane.read_until("MARK-43", Duration::from_secs(10));
    let shell = number_after(&seen, "SHELL=").unwrap_or_else(|| panic!("no shell pid in {seen:?}"));
    drop(pane);
    let dying = elf.with_file_name("wr-agent-dying");
    std::fs::write(
        &dying,
        format!(
            "#!/bin/sh\ncase $1 in protocol|handoff-check|hand-off) exec {INSTALLED_AGENT} \"$@\" ;; esac\nexit 70\n"
        ),
    )
    .expect("write the dying agent");
    let before = fixture.supervised_agent();
    let started = Instant::now();
    let (status, output) = install(&dying);
    assert_eq!(status, Some(1), "install: {output}");
    let outcome = reported(&output, "outcome").unwrap_or_default();
    assert!(
        outcome.starts_with("refused ") && outcome.contains("did not answer"),
        "{output}"
    );
    assert!(
        fixture.wait_for(&format!("{SUPERVISED_AGENT} || true"), |out| out
            .trim()
            .parse::<u32>()
            .is_ok_and(|after| after != before)),
        "the supervisor did not restart the agent after the crash"
    );
    let list = format!("wr-agent list --socket {} && echo SERVING", fixture.socket);
    assert!(
        fixture.wait_for(&list, |out| out.contains("SERVING")),
        "the restarted agent never served"
    );
    let recovered = started.elapsed();
    // The table is `socket.with_extension("handoff")`: `agent.handoff`, beside `agent.sock`.
    fixture.run(&format!(
        "test \"$(sha256sum {INSTALLED_AGENT} | cut -c1-64)\" = {newer_sha} \
         && ! ls {INSTALLED_AGENT}.new.* 2>/dev/null && ! kill -0 {shell} 2>/dev/null \
         && test ! -e {}.handoff",
        fixture.socket.trim_end_matches(".sock")
    ));
    assert!(
        !fixture
            .run(&format!("wr-agent list --socket {}", fixture.socket))
            .contains(session),
        "the lost session came back"
    );
    // For the design doc's record of the one unrecoverable case.
    println!(
        "crashed restore: the supervisor served a clean agent {recovered:?} after the install \
         was refused"
    );
    let _ = std::fs::remove_file(&newer);
    let _ = std::fs::remove_file(&dying);
}

/// The number that follows `label` in terminal output, skipping the tty's echo of the command
/// itself, which shows `label` followed by `$`.
fn number_after(text: &str, label: &str) -> Option<u32> {
    text.match_indices(label).find_map(|(at, _)| {
        let digits: String = text[at + label.len()..]
            .chars()
            .take_while(char::is_ascii_digit)
            .collect();
        digits.parse().ok()
    })
}

/// The design doc's Phase 3 acceptance: open a session and start a long-running job, forcibly drop
/// the ssh transport, leave the job running with no client, reconnect, and verify it is the same
/// child and the terminal state is repainted.
#[test]
#[ignore = "needs the ssh container fixture: vcs/scripts/ssh-fixture/run.sh"]
fn over_ssh_a_job_outlives_a_dropped_link_and_the_screen_comes_back() {
    let fixture = fixture();
    // The repaint half needs the shipped build. Without terminal-state the reattach is blank and
    // the failure below would blame the transport.
    let protocol = fixture.run("wr-agent protocol");
    assert!(
        protocol.contains("terminal-state yes"),
        "the fixture's agent must be built with terminal-state:\n{protocol}"
    );

    // Fixed ids are enough: run.sh starts a fresh container for every run.
    let id = [0x81; 16];
    let mut first = fixture.relay();
    first.client.handshake();
    first.client.send(Service::Terminal, 1, attach_frame(id));
    std::thread::sleep(Duration::from_millis(500));
    // `$((40+2))` so the marker is in the OUTPUT only, never in the tty's echo of the command.
    first.client.send(
        Service::Terminal,
        1,
        Frame::new(
            FrameKind::Input,
            b"sleep 600 & echo JOB=$! SHELL=$$ MARK-$((40+2))\n".to_vec(),
        ),
    );
    let seen = first.client.read_until("MARK-42", Duration::from_secs(10));
    let job = number_after(&seen, "JOB=").unwrap_or_else(|| panic!("no job pid in {seen:?}"));
    let shell = number_after(&seen, "SHELL=").unwrap_or_else(|| panic!("no shell pid in {seen:?}"));

    // Forcibly drop the transport: SIGKILL the ssh client mid-session.
    drop(first);

    // sshd sees the connection die and closes the relay's stdin, and the relay goes with it.
    assert!(
        fixture.wait_for("pgrep -f '^wr-agent relay' || true", |out| out
            .trim()
            .is_empty()),
        "the far-side relay outlived its link"
    );
    // No client now, and the job and its shell carry on.
    std::thread::sleep(Duration::from_secs(2));
    fixture.run(&format!("kill -0 {job} && kill -0 {shell}"));

    let mut second = fixture.relay();
    second.client.handshake();
    second.client.send(Service::Terminal, 1, attach_frame(id));
    // Repainted: the marker is on screen before anything is typed.
    let seen = second.client.read_until("MARK-42", Duration::from_secs(10));
    assert!(
        seen.contains("MARK-42"),
        "the reattached client was not shown the screen; got {seen:?}"
    );
    second.client.send(
        Service::Terminal,
        1,
        Frame::new(
            FrameKind::Input,
            format!("echo SHELL-NOW=$$; kill -0 {job} && echo JOB-ALIVE-$((1+1))\n").into_bytes(),
        ),
    );
    let needle = format!("SHELL-NOW={shell}");
    let seen = second
        .client
        .read_until("JOB-ALIVE-2", Duration::from_secs(10));
    assert!(
        seen.contains(&needle) && seen.contains("JOB-ALIVE-2"),
        "reconnected to a different shell or the job died; want {needle}, got {seen:?}"
    );

    second.client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Kill, id.to_vec()),
    );
}

/// The design doc's stop-and-reboot criterion (#232): a full-screen program is running, the box
/// stops and starts (every process killed, the disk kept), and a restored pane is shown that
/// program's last screen, marked as ended. What it types reaches nothing, and closing the pane
/// removes the record.
#[test]
#[ignore = "needs the ssh container fixture: vcs/scripts/ssh-fixture/run.sh"]
fn over_ssh_a_restored_pane_is_shown_its_last_screen_after_a_reboot() {
    let fixture = fixture();
    let protocol = fixture.run("wr-agent protocol");
    assert!(
        protocol.contains("terminal-state yes"),
        "the fixture's agent must be built with terminal-state:\n{protocol}"
    );

    let id = SessionId([0x84; 16]);
    let screens = std::env::var("WR_SSH_FIXTURE_SCREENS").expect(
        "WR_SSH_FIXTURE_SCREENS is unset; run these through vcs/scripts/ssh-fixture/run.sh",
    );
    let record = format!("{screens}/{}.vt", id.to_hyphenated());
    let mut relay = fixture.relay();
    relay.client.handshake();
    relay.client.send(Service::Terminal, 1, attach_frame(id.0));
    std::thread::sleep(Duration::from_millis(500));
    relay.client.send(
        Service::Terminal,
        1,
        Frame::new(
            FrameKind::Input,
            b"printf '\\033[?1049h\\033[HFULL-SCREEN-%s\\n' $((40+2)); sleep 600\n".to_vec(),
        ),
    );
    let seen = relay
        .client
        .read_until("FULL-SCREEN-42", Duration::from_secs(10));
    assert!(
        seen.contains("FULL-SCREEN-42"),
        "setup failed; got {seen:?}"
    );
    // The reboot kills the agent outright, so only what it has already written can survive.
    assert!(
        fixture.wait_for(&format!("grep -c FULL-SCREEN-42 {record} || true"), |out| {
            out.trim().parse::<u32>().is_ok_and(|n| n > 0)
        }),
        "the screen was never written to {record}"
    );
    drop(relay);

    fixture.reboot();

    let mut relay = fixture.relay();
    relay.client.handshake();
    let restored = AttachRequest {
        id: Some(id),
        columns: 80,
        rows: 24,
        existing_only: true,
        ..Default::default()
    };
    relay.client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Attach, restored.encode()),
    );
    let seen = relay
        .client
        .read_until("Close it to start again", Duration::from_secs(10));
    assert!(
        seen.contains("FULL-SCREEN-42") && seen.contains("Close it to start again"),
        "the restored pane was not shown its last screen; got {seen:?}"
    );
    relay.client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Input, b"echo LIVE-$((1+1))\n".to_vec()),
    );
    let seen = relay.client.read_until("LIVE-2", Duration::from_secs(1));
    assert!(!seen.contains("LIVE-2"), "input reached a shell: {seen:?}");

    // Closing the pane is the app killing the session by id.
    relay.client.send(
        Service::Control,
        2,
        Frame::new(FrameKind::Kill, id.0.to_vec()),
    );
    relay
        .client
        .envelope(Service::Control, 2, Duration::from_secs(5));
    assert!(
        fixture
            .run(&format!("test -e {record} || echo gone"))
            .contains("gone"),
        "closing the pane kept its record"
    );
}

/// The rest of the multiplex through the same relay, while a terminal session streams on it:
/// Status, VCS, File and Forward each answer.
#[test]
#[ignore = "needs the ssh container fixture: vcs/scripts/ssh-fixture/run.sh"]
fn over_ssh_every_service_answers_through_the_relay() {
    let fixture = fixture();
    let root = fixture
        .run(
            "set -e; rm -rf ~/relay-repo; git init -q ~/relay-repo; cd ~/relay-repo; \
             printf 'hello wire' > hello.txt; git add hello.txt; \
             git -c user.name=fixture -c user.email=fixture@example.com commit -qm relay-commit; \
             pwd",
        )
        .trim()
        .to_string();

    let id = [0x82; 16];
    let mut relay = fixture.relay();
    let client = &mut relay.client;
    client.handshake();
    client.send(Service::Terminal, 1, attach_frame(id));
    client.send(
        Service::Terminal,
        1,
        Frame::new(
            FrameKind::Input,
            b"while :; do echo tick; sleep 0.2; done\n".to_vec(),
        ),
    );

    let status = client.request(Service::Status, 2, &json!({"method": "status"}));
    assert!(status["result"]["verdict"].is_string(), "{status}");

    let log = client.request(
        Service::Vcs,
        3,
        &json!({"version": 1, "method": "log", "backend": "git", "root": root}),
    );
    assert!(log.get("error").is_none(), "{log}");
    assert!(log.to_string().contains("relay-commit"), "{log}");

    let read = client.request(
        Service::File,
        4,
        &json!({
            "version": 1, "method": "read", "root": root, "path": "hello.txt",
            "symlinks": "follow_within_root", "max_bytes": 1024,
        }),
    );
    assert_eq!(read["result"]["content"], "aGVsbG8gd2lyZQ==", "{read}");

    // A forward to the container's own sshd, whose banner proves bytes crossed the relay.
    const OPEN: u8 = 0x01;
    const DATA: u8 = 0x03;
    const CLOSE: u8 = 0x05;
    let mut open = vec![OPEN];
    open.extend_from_slice(br#"{"method":"open","host":"127.0.0.1","port":22}"#);
    client
        .writer
        .write_all(&Envelope::new(Service::Forward, 5, open).encode())
        .expect("open forward");
    let reply = client.envelope(Service::Forward, 5, Duration::from_secs(10));
    assert!(
        String::from_utf8_lossy(&reply.payload).contains(r#""opened":true"#),
        "{:?}",
        String::from_utf8_lossy(&reply.payload)
    );
    let data = client.envelope(Service::Forward, 5, Duration::from_secs(10));
    assert_eq!(data.payload.first(), Some(&DATA));
    assert!(
        data.payload[1..].starts_with(b"SSH-2.0-"),
        "{:?}",
        String::from_utf8_lossy(&data.payload)
    );

    // And the terminal keeps streaming while the forward is open. Counted from HERE: the loop has
    // been printing since before any request, so ticks already seen prove nothing.
    let ticks = |client: &Client| {
        String::from_utf8_lossy(&client.seen)
            .matches("tick")
            .count()
    };
    let before = ticks(client);
    let deadline = Instant::now() + Duration::from_secs(10);
    while ticks(client) < before + 3 && client.pump(deadline) {}
    assert!(
        ticks(client) >= before + 3,
        "the terminal stopped streaming while a forward was open"
    );
    client
        .writer
        .write_all(&Envelope::new(Service::Forward, 5, vec![CLOSE]).encode())
        .expect("close forward");
    client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Kill, id.to_vec()),
    );
}

/// The fixture's supervisor is what makes the remote agent persistent: it must bring a killed
/// agent back, and a new relay must reach the new one.
#[test]
#[ignore = "needs the ssh container fixture: vcs/scripts/ssh-fixture/run.sh"]
fn over_ssh_the_supervisor_restarts_a_crashed_agent() {
    let fixture = fixture();
    // Anchored on the supervisor's argv0, so it matches the supervised agent and never this
    // command's own shell.
    let pid = |out: &str| out.trim().parse::<u32>().ok();
    let before =
        pid(&fixture.run(SUPERVISED_AGENT)).expect("exactly one supervised agent is running");

    fixture.run(&format!("kill -KILL {before}"));
    assert!(
        fixture.wait_for(&format!("{SUPERVISED_AGENT} || true"), |out| pid(out)
            .is_some_and(|after| after != before)),
        "the supervisor did not restart the agent"
    );

    // Serving again, not merely running: `list` handshakes, so it succeeds only once the new agent
    // has rebound the socket. Then a relay reaches it.
    let list = format!("wr-agent list --socket {} && echo SERVING", fixture.socket);
    assert!(
        fixture.wait_for(&list, |out| out.contains("SERVING")),
        "the restarted agent never served"
    );
    let mut relay = fixture.relay();
    relay.client.handshake();
    let status = relay
        .client
        .request(Service::Status, 1, &json!({"method": "status"}));
    assert!(status["result"]["verdict"].is_string(), "{status}");
}
