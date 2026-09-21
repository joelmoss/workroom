//! `Service::Forward` over a real connection and a real TCP listener: bytes cross the multiplex in
//! both directions, two forwards stay separate, and every way a connection can end closes the
//! socket it owns. The parsing and the loopback allowlist are unit-tested in `forward.rs`; this
//! covers the seam — the opcode framing, the socket, and the teardown.

use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{channel, Receiver};
use std::time::{Duration, Instant};
use wr_agent::protocol::envelope::{Envelope, EnvelopeDecoder, Hello, Service};
use wr_agent::serve::handle_connection;
use wr_agent::session::SessionStore;

const OPEN: u8 = 0x01;
const REPLY: u8 = 0x02;
const DATA: u8 = 0x03;
const EOF: u8 = 0x04;
const CLOSE: u8 = 0x05;

/// Long enough that a loaded machine does not fail a test for a scheduling reason.
const PATIENCE: Duration = Duration::from_secs(10);

// MARK: An echo server

/// What one accepted connection did, reported back to the test.
enum Served {
    /// The peer closed its write half, having sent this much.
    Eof(usize),
}

/// A listener on an ephemeral loopback port that echoes everything back until EOF.
struct Echo {
    port: u16,
    served: Receiver<Served>,
}

impl Echo {
    fn start() -> Echo {
        Echo::with(|mut socket| {
            let mut total = 0;
            let mut buffer = vec![0u8; 8192];
            loop {
                match socket.read(&mut buffer) {
                    Ok(0) => return Served::Eof(total),
                    Ok(count) => {
                        total += count;
                        if socket.write_all(&buffer[..count]).is_err() {
                            return Served::Eof(total);
                        }
                    }
                    Err(_) => return Served::Eof(total),
                }
            }
        })
    }

    /// A listener running `serve` on every accepted connection, each on its own thread — two
    /// concurrent forwards must be served concurrently or the test that interleaves them deadlocks.
    fn with(serve: impl Fn(TcpStream) -> Served + Send + Sync + 'static) -> Echo {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
        let port = listener.local_addr().unwrap().port();
        let (tx, served) = channel();
        let serve = std::sync::Arc::new(serve);
        std::thread::spawn(move || {
            for socket in listener.incoming() {
                let Ok(socket) = socket else { return };
                let tx = tx.clone();
                let serve = std::sync::Arc::clone(&serve);
                std::thread::spawn(move || {
                    let _ = tx.send(serve(socket));
                });
            }
        });
        Echo { port, served }
    }

    /// How the last finished connection ended, or `None` if none did within `PATIENCE`.
    fn finished(&self) -> Option<Served> {
        self.served.recv_timeout(PATIENCE).ok()
    }
}

// MARK: The client half of the multiplex

struct Client {
    stream: UnixStream,
    decoder: EnvelopeDecoder,
    /// Envelopes read while looking for something on another stream.
    pending: Vec<(u32, u8, Vec<u8>)>,
}

impl Client {
    fn connect() -> Client {
        let (mut stream, server) = UnixStream::pair().unwrap();
        std::thread::spawn(move || {
            let _ = handle_connection(server, SessionStore::new());
        });
        stream
            .write_all(&Hello::current("forward-test").encode())
            .unwrap();
        let mut greeting = Vec::new();
        while Hello::decode(&greeting).unwrap().is_none() {
            let mut byte = [0u8];
            stream.read_exact(&mut byte).unwrap();
            greeting.push(byte[0]);
        }
        stream
            .set_read_timeout(Some(Duration::from_millis(50)))
            .unwrap();
        Client {
            stream,
            decoder: EnvelopeDecoder::new(),
            pending: Vec::new(),
        }
    }

    fn send(&mut self, stream: u32, opcode: u8, body: &[u8]) {
        let mut payload = Vec::with_capacity(1 + body.len());
        payload.push(opcode);
        payload.extend_from_slice(body);
        self.stream
            .write_all(&Envelope::new(Service::Forward, stream, payload).encode())
            .unwrap();
    }

    fn open(&mut self, stream: u32, host: &str, port: u16) -> Value {
        let request = json!({"method": "open", "host": host, "port": port});
        self.send(stream, OPEN, &serde_json::to_vec(&request).unwrap());
        let (opcode, body) = self.next(stream).expect("a reply to open");
        assert_eq!(opcode, REPLY, "open is always answered with a reply");
        serde_json::from_slice(&body).unwrap()
    }

    /// Open a forward that is expected to succeed.
    fn opened(&mut self, stream: u32, port: u16) {
        let reply = self.open(stream, "127.0.0.1", port);
        assert_eq!(reply["result"]["opened"], true, "{reply}");
    }

    /// The next payload on `stream`, setting aside anything for another one.
    fn next(&mut self, stream: u32) -> Option<(u8, Vec<u8>)> {
        self.next_within(stream, PATIENCE)
    }

    fn next_within(&mut self, stream: u32, wait: Duration) -> Option<(u8, Vec<u8>)> {
        let deadline = Instant::now() + wait;
        loop {
            if let Some(index) = self.pending.iter().position(|(s, _, _)| *s == stream) {
                let (_, opcode, body) = self.pending.remove(index);
                return Some((opcode, body));
            }
            if Instant::now() >= deadline {
                return None;
            }
            match self.decoder.next_envelope().unwrap() {
                Some(envelope) => {
                    assert_eq!(envelope.service, Service::Forward);
                    let (opcode, body) = envelope.payload.split_first().expect("an opcode");
                    self.pending.push((envelope.stream, *opcode, body.to_vec()));
                }
                None => self.fill(),
            }
        }
    }

    fn fill(&mut self) {
        let mut bytes = [0u8; 65536];
        match self.stream.read(&mut bytes) {
            Ok(0) => panic!("the agent closed the connection"),
            Ok(count) => self.decoder.push(&bytes[..count]),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(error) => panic!("read failed: {error}"),
        }
    }

    /// Read exactly `want` bytes of DATA off `stream`, failing on anything else.
    fn read(&mut self, stream: u32, want: usize) -> Vec<u8> {
        let mut got = Vec::with_capacity(want);
        while got.len() < want {
            let (opcode, body) = self
                .next(stream)
                .unwrap_or_else(|| panic!("only {} of {want} bytes arrived", got.len()));
            assert_eq!(
                opcode,
                DATA,
                "expected data, got opcode {opcode:#04x} after {} bytes",
                got.len()
            );
            got.extend_from_slice(&body);
        }
        got
    }
}

// MARK: Tests

#[test]
fn bytes_round_trip_in_both_directions() {
    let echo = Echo::start();
    let mut client = Client::connect();
    client.opened(1, echo.port);

    client.send(1, DATA, b"hello");
    assert_eq!(client.read(1, 5), b"hello");

    // Larger than one envelope, so the agent's side of the pipe must span several DATA envelopes.
    // Kept under the agent's per-forward queue budget, because this sends everything before it
    // reads anything: past the budget the agent is entitled to kill the forward, and the amount the
    // kernel's socket buffers absorb in the meantime is not a thing a test may depend on.
    let big: Vec<u8> = (0..1_500_000u32).map(|i| (i % 251) as u8).collect();
    for chunk in big.chunks(500_000) {
        client.send(1, DATA, chunk);
    }
    assert_eq!(client.read(1, big.len()), big, "a multi-envelope payload");

    // And a payload delivered one byte per envelope: a DATA body has no minimum.
    for byte in b"split" {
        client.send(1, DATA, &[*byte]);
    }
    assert_eq!(client.read(1, 5), b"split");
}

#[test]
fn two_forwards_on_distinct_streams_do_not_mix_bytes() {
    let echo = Echo::start();
    let mut client = Client::connect();
    client.opened(7, echo.port);
    client.opened(9, echo.port);

    // Interleaved on the wire, so a mix-up would be visible rather than merely possible.
    for _ in 0..200 {
        client.send(7, DATA, b"seven");
        client.send(9, DATA, b"nine.");
    }
    assert_eq!(client.read(7, 1000), b"seven".repeat(200));
    assert_eq!(client.read(9, 1000), b"nine.".repeat(200));
}

#[test]
fn the_tcp_peer_closing_surfaces_as_eof_and_then_the_stream_ends() {
    // A server that says one thing and hangs up.
    let echo = Echo::with(|mut socket| {
        let _ = socket.write_all(b"bye");
        Served::Eof(0)
    });
    let mut client = Client::connect();
    client.opened(1, echo.port);

    assert_eq!(client.read(1, 3), b"bye");
    // EOF, not CLOSE: the peer stopped writing, and a client with more to send may still send it.
    assert_eq!(client.next(1).expect("eof").0, EOF);
    // The stream is finished once this side is done too.
    client.send(1, EOF, &[]);
    assert_eq!(client.next(1).expect("close").0, CLOSE);
}

#[test]
fn a_client_closing_the_stream_closes_the_tcp_connection() {
    let echo = Echo::start();
    let mut client = Client::connect();
    client.opened(1, echo.port);
    client.send(1, DATA, b"before the close");
    assert_eq!(client.read(1, 16), b"before the close");

    client.send(1, CLOSE, &[]);
    let Some(Served::Eof(total)) = echo.finished() else {
        panic!("the echo server never saw its peer go away");
    };
    assert_eq!(total, 16, "everything sent arrived before the close");
}

/// A half-close is a half-close: the peer sees EOF while the agent keeps relaying what comes back.
#[test]
fn a_client_eof_reaches_the_tcp_peer_as_eof() {
    // Answers only once its peer has stopped writing, which is what the client's EOF must produce.
    let echo = Echo::with(|mut socket| {
        let mut request = Vec::new();
        let _ = socket.read_to_end(&mut request);
        let _ = socket.write_all(format!("read {} bytes", request.len()).as_bytes());
        Served::Eof(request.len())
    });
    let mut client = Client::connect();
    client.opened(1, echo.port);
    client.send(1, DATA, b"request");
    client.send(1, EOF, &[]);
    assert_eq!(client.read(1, 12), b"read 7 bytes");
}

#[test]
fn a_refused_port_is_an_error_reply_rather_than_a_dropped_stream() {
    // Bound and dropped, so the port is almost certainly nobody's for the length of this test.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);

    let mut client = Client::connect();
    let reply = client.open(1, "127.0.0.1", port);
    assert!(reply["error"]["connect"].is_string(), "{reply}");
    assert_eq!(client.next(1).expect("close").0, CLOSE);

    // And the stream id is free again, which is what makes the error recoverable.
    let echo = Echo::start();
    client.opened(1, echo.port);
}

#[test]
fn a_non_loopback_host_is_refused_over_the_wire() {
    let mut client = Client::connect();
    let reply = client.open(1, "10.0.0.1", 80);
    assert_eq!(
        reply["error"]["refused"], "10.0.0.1 is not a loopback address",
        "{reply}"
    );
    assert_eq!(client.next(1).expect("close").0, CLOSE);
}

#[test]
fn dropping_the_multiplex_connection_closes_the_forwarded_socket() {
    let echo = Echo::start();
    let mut client = Client::connect();
    client.opened(1, echo.port);
    client.send(1, DATA, b"still here");
    assert_eq!(client.read(1, 10), b"still here");

    // No close, no EOF: the client simply goes away, as a crashed app would.
    drop(client);
    let Some(Served::Eof(total)) = echo.finished() else {
        panic!("a forwarded socket outlived the connection that owned it");
    };
    assert_eq!(total, 10);
}

/// The other half of "only carries while a client is attached": a second connection's forwards are
/// its own, and the first connection's going away does not touch them.
#[test]
fn a_second_connections_forward_survives_the_firsts_departure() {
    let echo = Echo::start();
    let mut first = Client::connect();
    let mut second = Client::connect();
    first.opened(1, echo.port);
    second.opened(1, echo.port);

    drop(first);
    assert!(echo.finished().is_some(), "the first forward closed");
    second.send(1, DATA, b"mine");
    assert_eq!(second.read(1, 4), b"mine");
}

#[test]
fn opening_a_stream_that_is_already_forwarding_is_refused_without_disturbing_it() {
    let echo = Echo::start();
    let mut client = Client::connect();
    client.opened(1, echo.port);

    let reply = client.open(1, "127.0.0.1", echo.port);
    assert_eq!(
        reply["error"]["refused"], "stream 1 is already forwarding",
        "{reply}"
    );
    // The forward that was already there is untouched.
    client.send(1, DATA, b"alive");
    assert_eq!(client.read(1, 5), b"alive");
}

/// A stream that is not forwarding is ignored rather than answered, exactly as `serve.rs` ignores a
/// service it does not handle — and the connection survives it.
#[test]
fn traffic_for_a_stream_that_is_not_forwarding_is_dropped() {
    let echo = Echo::start();
    let mut client = Client::connect();
    for opcode in [DATA, EOF, CLOSE] {
        client.send(404, opcode, b"nobody is listening");
    }
    // Stream 0 carries nothing on this service either.
    client.send(0, OPEN, br#"{"method":"open","host":"127.0.0.1","port":1}"#);
    // A short wait: this asserts that nothing arrives, so the whole wait is spent every run.
    assert!(
        client.next_within(0, Duration::from_millis(500)).is_none(),
        "stream 0 is never answered"
    );

    client.opened(1, echo.port);
    client.send(1, DATA, b"unaffected");
    assert_eq!(client.read(1, 10), b"unaffected");
}
