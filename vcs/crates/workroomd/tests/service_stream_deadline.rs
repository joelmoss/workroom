//! The service-stream deadline (ADR 0075), beside the pane keepalive (`attach_keepalive.rs`): the
//! app pings a remote service stream every 15 s and says so on connecting, and the daemon closes
//! one that said so and then sent nothing for 60 s. A connection that never said so (an older app,
//! or any local one) is never closed by it.
//!
//! The deadline runs at `DEADLINE` here, not 60 s, through `handle_connection_with` and
//! `Daemon::with_service_deadline`.

#[allow(dead_code)] // not every helper is used here
mod common;
use common::{RpcClient, Workspace, daemon_binary, wait_for};

use std::io::{Read, Write};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use workroomd::testing::{
    Daemon, FdStream, SessionStore, bind, handle_connection_with, set_nonblocking,
};
use wr_protocol::envelope::{Hello, Service};
use wr_protocol::frame::{Frame, FrameDecoder, FrameKind};

const DEADLINE: Duration = Duration::from_millis(300);

/// A greeted connection to a daemon whose service deadline is `DEADLINE`, and the thread serving
/// it, which ends when the daemon closes the connection.
fn connect() -> (RpcClient, std::thread::JoinHandle<()>) {
    let (mut stream, server) = UnixStream::pair().unwrap();
    let served = std::thread::spawn(move || {
        let _ = handle_connection_with(server, SessionStore::new(), DEADLINE);
    });
    stream
        .write_all(&Hello::current("deadline-test").encode())
        .unwrap();
    let mut greeting = Vec::new();
    while Hello::decode(&greeting).unwrap().is_none() {
        let mut byte = [0u8];
        stream.read_exact(&mut byte).unwrap();
        greeting.push(byte[0]);
    }
    stream
        .set_read_timeout(Some(Duration::from_millis(20)))
        .unwrap();
    let reader = stream.try_clone().unwrap();
    (RpcClient::over(reader, stream), served)
}

/// Says this connection pings, and waits for the daemon to take it.
fn announce<R: Read, W: Write>(client: &mut RpcClient<R, W>) {
    assert_eq!(
        control(client, FrameKind::Pings).map(|frame| frame.kind),
        Some(FrameKind::Acknowledged),
        "the announcement was not acknowledged"
    );
}

/// One Control request and its reply frame, or None when nothing came.
fn control<R: Read, W: Write>(client: &mut RpcClient<R, W>, kind: FrameKind) -> Option<Frame> {
    let stream = client.take_stream();
    client.send(Service::Control, stream, Frame::control(kind));
    let reply = client.next_on(Service::Control, stream, Duration::from_secs(2))?;
    let mut frames = FrameDecoder::new();
    frames.push(&reply.payload);
    frames.next_frame().ok().flatten()
}

/// Something from the app, as its ping is: a session list.
fn ping<R: Read, W: Write>(client: &mut RpcClient<R, W>) -> bool {
    control(client, FrameKind::List).is_some_and(|frame| frame.kind == FrameKind::Sessions)
}

/// The Mac went to sleep holding the app's service stream: nothing more arrives on it, and the
/// daemon closes it within about the deadline rather than writing to it for as long as the host
/// lives.
#[test]
fn a_pinging_connection_that_goes_silent_is_closed() {
    let (mut client, served) = connect();
    announce(&mut client);
    let started = Instant::now();
    assert!(
        wait_for(Duration::from_secs(5), || served.is_finished()),
        "a silent pinging connection was kept"
    );
    assert!(
        started.elapsed() >= DEADLINE / 2,
        "closed before the deadline: {:?}",
        started.elapsed()
    );
    // The client sees its stream end.
    client.pump(Instant::now() + Duration::from_secs(1));
    assert!(client.closed, "the client's stream did not end");
}

/// An app that keeps pinging keeps its connection, however many deadlines pass.
#[test]
fn a_pinging_connection_that_keeps_pinging_is_kept() {
    let (mut client, served) = connect();
    announce(&mut client);
    let until = Instant::now() + DEADLINE * 5;
    while Instant::now() < until {
        assert!(ping(&mut client), "a pinging connection was closed");
        std::thread::sleep(DEADLINE / 6);
    }
    assert!(!served.is_finished(), "a pinging connection was closed");
}

/// A large File reply over a slow link: while the daemon is still writing it, and the app is
/// still taking it, the stream is alive. The app keeps pinging, but the daemon's read loop takes
/// the first ping and then waits to write its answer behind the reply, so no later ping is read
/// until the reply is done. The reply, larger than the socket's buffer and read slowly for
/// several deadlines, arrives whole.
#[test]
fn a_large_reply_read_slowly_outlasts_the_deadline() {
    let root = std::env::temp_dir().join(format!("wr-deadline-slow-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let bytes: Vec<u8> = (0..600_000u32).map(|n| (n % 251) as u8).collect();
    std::fs::write(root.join("big.bin"), &bytes).unwrap();

    let (mut client, served) = connect();
    announce(&mut client);
    let stream = client.take_stream();
    let request = serde_json::json!({
        "version": 1, "method": "read", "root": root, "path": "big.bin",
        "symlinks": "refuse", "max_bytes": 8 * 1024 * 1024,
    });
    client.send_payload(Service::File, stream, serde_json::to_vec(&request).unwrap());

    // 4 KiB every 5 ms: the 800 KB of base64 takes about a second, three deadlines and more.
    let started = Instant::now();
    let mut decoder = wr_protocol::envelope::EnvelopeDecoder::new();
    let mut assembled = Vec::new();
    let mut buffer = [0u8; 4096];
    let mut pinged = Instant::now();
    'read: while Instant::now() < started + Duration::from_secs(30) {
        if pinged.elapsed() > DEADLINE / 6 {
            let ping = client.take_stream();
            client.send(Service::Control, ping, Frame::control(FrameKind::List));
            pinged = Instant::now();
        }
        let Some(n) = client.read_some(&mut buffer, Instant::now() + Duration::from_secs(2)) else {
            break;
        };
        decoder.push(&buffer[..n]);
        while let Some(envelope) = decoder.next_envelope().unwrap() {
            if envelope.service != Service::File || envelope.stream != stream {
                continue;
            }
            let (last, body) = envelope.payload.split_first().unwrap();
            assembled.extend_from_slice(body);
            if *last == 1 {
                break 'read;
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        !client.closed && !served.is_finished(),
        "the stream was closed while the reply was still being taken, after {:?}",
        started.elapsed()
    );
    assert!(
        started.elapsed() > DEADLINE * 2,
        "the reply came too fast to test anything: {:?}",
        started.elapsed()
    );
    let reply: serde_json::Value = serde_json::from_slice(&assembled).expect("a whole JSON reply");
    assert_eq!(reply["result"]["size"], bytes.len());
}

/// An older app, or any local connection, never said it pings: silence never closes it.
#[test]
fn a_connection_that_never_announced_is_never_closed() {
    let (mut client, served) = connect();
    std::thread::sleep(DEADLINE * 5);
    assert!(
        !served.is_finished(),
        "a connection that never announced was closed"
    );
    assert!(
        ping(&mut client),
        "a connection that never announced stopped answering"
    );
}

/// Through `relay`, the far side of the app's remote service stream: the daemon closing a silent
/// pinging connection ends the relay, which on Railway is what ends its durable session.
#[test]
fn the_relay_of_a_closed_connection_exits() {
    let scratch = Workspace::new("deadline-relay");
    let socket = scratch.socket();
    let listener = bind(&socket).unwrap();
    {
        let socket = socket.clone();
        std::thread::spawn(move || {
            let daemon = Daemon::new().with_service_deadline(DEADLINE);
            let _ = daemon.run(listener, &socket, Duration::from_secs(3600));
        });
    }

    let mut relay = Command::new(daemon_binary())
        .args(["relay", "--socket"])
        .arg(&socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("spawn relay");
    let stdin = relay.stdin.take().unwrap();
    let stdout = relay.stdout.take().unwrap();
    let reader = FdStream::new(stdout.as_raw_fd());
    set_nonblocking(&reader).unwrap();
    let mut client = RpcClient::over(reader, FdStream::new(stdin.as_raw_fd()));
    client.handshake();
    announce(&mut client);

    let exited = wait_for(Duration::from_secs(5), || {
        matches!(relay.try_wait(), Ok(Some(_)))
    });
    if !exited {
        let _ = relay.kill();
    }
    let _ = relay.wait();
    drop((stdin, stdout));
    assert!(exited, "the relay of a closed connection kept running");
}
