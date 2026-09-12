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
//! the driver's job, not the protocol's.

use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use wr_agent::protocol::envelope::{Envelope, EnvelopeDecoder, Hello, Service};
use wr_agent::protocol::frame::{Frame, FrameDecoder, FrameKind};
use wr_agent::serve::{handle_connection, AttachRequest};
use wr_agent::session::{SessionId, SessionStore};
use wr_agent::transport::{close, set_nonblocking, FdStream, PipeTransport};

/// Drives an agent from the client side of a stream, speaking the real protocol.
struct Client {
    reader: FdStream,
    writer: FdStream,
    decoder: EnvelopeDecoder,
    seen: Vec<u8>,
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
        let mut buffer = [0u8; 4096];
        while Instant::now() < deadline {
            if String::from_utf8_lossy(&self.seen).contains(needle) {
                break;
            }
            let n = match self.read_some(&mut buffer, deadline) {
                Some(n) => n,
                None => break,
            };
            self.decoder.push(&buffer[..n]);
            while let Ok(Some(envelope)) = self.decoder.next_envelope() {
                let mut frames = FrameDecoder::new();
                frames.push(&envelope.payload);
                while let Ok(Some(frame)) = frames.next_frame() {
                    if frame.kind == FrameKind::Output {
                        self.seen.extend_from_slice(&frame.payload);
                    }
                }
            }
        }
        String::from_utf8_lossy(&self.seen).into_owned()
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

/// `serve --stdio` is literally what a driver runs on the far side: `ssh host wr-agent serve
/// --stdio`. Here the "hop" is a pair of pipes to a child process, which exercises everything the
/// ssh case does except the network — argument handling, stdio wiring, and the agent serving a
/// stream it does not own.
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
