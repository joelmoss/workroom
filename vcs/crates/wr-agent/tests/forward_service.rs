//! `Service::Forward` over a real connection and a real TCP listener: bytes cross the multiplex in
//! both directions, two forwards stay separate, and every way a connection can end closes the
//! socket it owns. The parsing and the loopback allowlist are unit-tested in `forward.rs`; this
//! covers the seam — the opcode framing, the socket, and the teardown.

use serde_json::{Value, json};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{Receiver, channel};
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

/// A listener on an ephemeral loopback port that echoes everything back until EOF. `served`
/// carries, for each connection that ended, how many bytes its peer sent before going away.
struct Echo {
    port: u16,
    served: Receiver<usize>,
}

impl Echo {
    fn start() -> Echo {
        Echo::with(|mut socket| {
            let mut total = 0;
            let mut buffer = vec![0u8; 8192];
            loop {
                match socket.read(&mut buffer) {
                    Ok(0) => return total,
                    Ok(count) => {
                        total += count;
                        if socket.write_all(&buffer[..count]).is_err() {
                            return total;
                        }
                    }
                    Err(_) => return total,
                }
            }
        })
    }

    /// A listener running `serve` on every accepted connection, each on its own thread — two
    /// concurrent forwards must be served concurrently or the test that interleaves them deadlocks.
    fn with(serve: impl Fn(TcpStream) -> usize + Send + Sync + 'static) -> Echo {
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

    /// How much the next connection to finish had received, or `None` if none did within
    /// `PATIENCE`.
    fn finished(&self) -> Option<usize> {
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
        0
    });
    let mut client = Client::connect();
    client.opened(1, echo.port);

    assert_eq!(client.read(1, 3), b"bye");
    // EOF, not CLOSE: the peer stopped writing, and a client with more to send may still send it.
    assert_eq!(client.next(1).expect("eof").0, EOF);
    // The stream is finished once this side is done too. Reading "bye" first is what pins the
    // order: CLOSE follows whichever half finishes SECOND, so it would arrive after the peer's EOF
    // rather than after this one if the two were sent the other way round.
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
    let Some(total) = echo.finished() else {
        panic!("the echo server never saw its peer go away");
    };
    assert_eq!(total, 16, "everything sent arrived before the close");
    // And the client gets the CLOSE that frees the id — the agent's last word on the stream, and
    // NOT an EOF for the shutdown the close performed. Then the id is usable again.
    assert_eq!(client.next(1).expect("close").0, CLOSE);
    assert!(
        client.next_within(1, Duration::from_millis(300)).is_none(),
        "nothing after CLOSE"
    );
    client.opened(1, echo.port);
}

/// A forward the client stops draining is killed at the budget, and the client's last envelope
/// on that stream is the CLOSE: nothing the socket's reader still had (DATA, its EOF) follows it,
/// so a client that re-uses the id on CLOSE cannot receive the old forward's bytes.
#[test]
fn a_stalled_forward_is_closed_and_close_is_its_last_envelope() {
    // A server that never reads: the agent's socket writes stall once the kernel buffers fill,
    // and the client's bytes pile up in the agent's queue.
    let echo = Echo::with(|socket| {
        std::thread::sleep(Duration::from_secs(30));
        drop(socket);
        0
    });
    let mut client = Client::connect();
    client.opened(1, echo.port);
    let chunk = vec![1u8; 512 * 1024];
    // Past the budget plus whatever the kernel absorbs; the agent is entitled to kill the forward
    // anywhere past the budget, and this asserts only what happens when it does.
    for _ in 0..16 {
        client.send(1, DATA, &chunk);
    }
    let (opcode, _) = client.next(1).expect("the kill's CLOSE");
    assert_eq!(
        opcode, CLOSE,
        "CLOSE, not an EOF for the agent's own shutdown"
    );
    assert!(
        client.next_within(1, Duration::from_millis(300)).is_none(),
        "nothing after CLOSE"
    );
    // The id is free: a fresh forward on it works.
    let alive = Echo::start();
    client.opened(1, alive.port);
    client.send(1, DATA, b"reused");
    assert_eq!(client.read(1, 6), b"reused");
}

/// A peer that resets the connection (rather than closing it) ends the stream too: the reader's
/// error wakes the writer, and the pair finishes with CLOSE instead of holding the slot until
/// the client notices on its own.
#[test]
fn a_peer_reset_ends_the_stream_with_close() {
    // Reads one message, then drops the socket with unread data pending, which makes the kernel
    // send RST rather than FIN.
    let echo = Echo::with(|mut socket| {
        let mut buffer = [0u8; 8];
        let _ = socket.read(&mut buffer);
        // Unread bytes at close = RST on most stacks; SO_LINGER 0 makes it certain.
        let linger = libc::linger {
            l_onoff: 1,
            l_linger: 0,
        };
        // SAFETY: the option value is `linger` and the length passed is its exact size; `socket`
        // is open for the call.
        unsafe {
            use std::os::unix::io::AsRawFd;
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_LINGER,
                &linger as *const _ as *const libc::c_void,
                std::mem::size_of::<libc::linger>() as libc::socklen_t,
            );
        }
        drop(socket);
        0
    });
    let mut client = Client::connect();
    client.opened(1, echo.port);
    client.send(1, DATA, b"one");
    // Whatever arrives (an EOF if the FIN raced the RST, nothing if not), the stream ends with
    // CLOSE, and nothing follows it.
    let mut last = None;
    while let Some((opcode, _)) = client.next(1) {
        last = Some(opcode);
        if opcode == CLOSE {
            break;
        }
    }
    assert_eq!(last, Some(CLOSE));
    assert!(client.next_within(1, Duration::from_millis(300)).is_none());
    // The slot and the id are free.
    let alive = Echo::start();
    client.opened(1, alive.port);
}

/// `localhost` names both loopback families; a server bound to only `::1` is still reached.
#[test]
fn localhost_reaches_a_server_bound_only_to_the_v6_loopback() {
    let Ok(listener) = TcpListener::bind("[::1]:0") else {
        eprintln!("no IPv6 loopback here; skipping");
        return;
    };
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        if let Ok((mut socket, _)) = listener.accept() {
            let mut buffer = [0u8; 16];
            if let Ok(count) = socket.read(&mut buffer) {
                let _ = socket.write_all(&buffer[..count]);
            }
        }
    });
    let mut client = Client::connect();
    let reply = client.open(1, "localhost", port);
    assert_eq!(reply["result"]["opened"], true, "{reply}");
    client.send(1, DATA, b"v6");
    assert_eq!(client.read(1, 2), b"v6");
}

/// The cap counts a forward until BOTH its threads are gone. A client half-close ends the writer
/// thread while the reader and the socket live on; sixty-four of those are still sixty-four.
#[test]
fn a_half_closed_forward_still_counts_against_the_cap() {
    // A server that keeps the connection open after its peer's EOF, as a keep-alive server does.
    let echo = Echo::with(|socket| {
        std::thread::sleep(Duration::from_secs(30));
        drop(socket);
        0
    });
    let mut client = Client::connect();
    for stream in 1..=64u32 {
        client.opened(stream, echo.port);
        client.send(stream, EOF, &[]);
    }
    // The writer threads have had time to exit; the readers are parked on the peer.
    std::thread::sleep(Duration::from_millis(300));
    let reply = client.open(65, "127.0.0.1", echo.port);
    assert_eq!(
        reply["error"]["refused"], "too many forwarded connections",
        "{reply}"
    );
    assert_eq!(client.next(65).expect("close").0, CLOSE);
}

/// A DATA body may be empty, and it changes nothing.
#[test]
fn an_empty_data_body_is_harmless() {
    let echo = Echo::start();
    let mut client = Client::connect();
    client.opened(1, echo.port);
    client.send(1, DATA, &[]);
    client.send(1, DATA, b"after");
    assert_eq!(client.read(1, 5), b"after");
}

/// A half-close is a half-close: the peer sees EOF while the agent keeps relaying what comes back.
#[test]
fn a_client_eof_reaches_the_tcp_peer_as_eof() {
    // Answers only once its peer has stopped writing, which is what the client's EOF must produce.
    let echo = Echo::with(|mut socket| {
        let mut request = Vec::new();
        let _ = socket.read_to_end(&mut request);
        let _ = socket.write_all(format!("read {} bytes", request.len()).as_bytes());
        request.len()
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
    let Some(total) = echo.finished() else {
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
    // A connection finished — this one receiver is fed by both, so it is the two lines below that
    // establish WHICH: the second forward is still carrying bytes, so it was the first that went.
    assert!(echo.finished().is_some(), "a forward closed");
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

// MARK: Listening (the reverse direction)

const ACCEPTED: u8 = 0x06;

impl Client {
    /// Send one OPEN and return its REPLY.
    fn ask(&mut self, stream: u32, request: Value) -> Value {
        self.send(stream, OPEN, &serde_json::to_vec(&request).unwrap());
        let (opcode, body) = self.next(stream).expect("a reply");
        assert_eq!(opcode, REPLY, "an OPEN is always answered with a reply");
        serde_json::from_slice(&body).unwrap()
    }

    /// Start a listener on an ephemeral port that is expected to bind; the port it bound.
    fn listening(&mut self, stream: u32) -> u16 {
        let reply = self.ask(stream, json!({"method": "listen", "port": 0}));
        reply["result"]["listening"]
            .as_u64()
            .unwrap_or_else(|| panic!("{reply}")) as u16
    }
}

/// A process on the agent's box connecting to a listener's port.
fn connected_to(port: u16) -> TcpStream {
    let socket = TcpStream::connect(("127.0.0.1", port)).expect("connect to the listener");
    socket.set_read_timeout(Some(PATIENCE)).unwrap();
    socket
}

/// Whether nothing holds `port` any more. A bind, not a connect: a connect would be accepted, and
/// the agent's own failure to announce it to a departed client is a second way for the listener to
/// end, which would let a test pass without the path it means to check.
fn released(port: u16) -> bool {
    TcpListener::bind(("127.0.0.1", port)).is_ok()
}

/// Whether the connection was closed on the far side: a clean EOF or a reset, never a timeout.
fn ended(socket: &mut TcpStream) -> bool {
    let mut byte = [0u8];
    match socket.read(&mut byte) {
        Ok(0) => true,
        Ok(_) => false,
        Err(error) => !matches!(
            error.kind(),
            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
        ),
    }
}

#[test]
fn a_listener_carries_a_connection_both_ways() {
    let mut client = Client::connect();
    let port = client.listening(1);
    let mut peer = connected_to(port);
    assert_eq!(client.next(1), Some((ACCEPTED, vec![])));
    let reply = client.ask(2, json!({"method": "accept", "listener": 1}));
    assert_eq!(reply["result"]["opened"], true, "{reply}");

    peer.write_all(b"GET /up").unwrap();
    assert_eq!(client.read(2, 7), b"GET /up");
    client.send(2, DATA, b"200 OK");
    let mut answer = [0u8; 6];
    peer.read_exact(&mut answer).unwrap();
    assert_eq!(&answer, b"200 OK");

    // The two halves end independently, as any forward's do.
    peer.shutdown(std::net::Shutdown::Write).unwrap();
    assert_eq!(client.next(2), Some((EOF, vec![])));
    client.send(2, EOF, &[]);
    assert_eq!(client.next(2), Some((CLOSE, vec![])));
    assert!(ended(&mut peer));

    // The listener carries on: the next connection is announced too.
    let _second = connected_to(port);
    assert_eq!(client.next(1), Some((ACCEPTED, vec![])));
}

#[test]
fn an_accept_with_nothing_to_claim_is_refused_and_closed() {
    let mut client = Client::connect();
    let reply = client.ask(5, json!({"method": "accept", "listener": 1}));
    assert_eq!(
        reply["error"]["refused"], "stream 1 is not listening",
        "{reply}"
    );
    assert_eq!(client.next(5), Some((CLOSE, vec![])));

    client.listening(1);
    let reply = client.ask(6, json!({"method": "accept", "listener": 1}));
    assert_eq!(
        reply["error"]["refused"], "no connection is waiting",
        "{reply}"
    );
    assert_eq!(client.next(6), Some((CLOSE, vec![])));
}

#[test]
fn a_taken_port_is_a_bind_error() {
    let taken = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = taken.local_addr().unwrap().port();
    let mut client = Client::connect();
    let reply = client.ask(1, json!({"method": "listen", "port": port}));
    assert!(reply["error"]["bind"].is_string(), "{reply}");
    assert_eq!(client.next(1), Some((CLOSE, vec![])));
}

#[test]
fn closing_a_listener_releases_its_port_and_ends_what_waited() {
    let mut client = Client::connect();
    let port = client.listening(1);
    let mut waiting = connected_to(port);
    assert_eq!(client.next(1), Some((ACCEPTED, vec![])));

    client.send(1, CLOSE, &[]);
    assert_eq!(client.next(1), Some((CLOSE, vec![])));
    assert!(
        client.next_within(1, Duration::from_millis(300)).is_none(),
        "CLOSE is the agent's last word on the listener"
    );
    assert!(ended(&mut waiting), "the unclaimed connection was closed");
    assert!(released(port), "the port was released");
}

#[test]
fn an_unclaimed_connection_is_closed_after_the_pending_timeout() {
    let mut client = Client::connect();
    let port = client.listening(1);
    let started = Instant::now();
    let mut waiting = connected_to(port);
    assert_eq!(client.next(1), Some((ACCEPTED, vec![])));

    assert!(ended(&mut waiting), "never closed");
    let waited = started.elapsed();
    let timeout = wr_agent::forward::PENDING_TIMEOUT;
    assert!(waited >= timeout, "closed early, after {waited:?}");
    assert!(
        waited < timeout + Duration::from_secs(2),
        "closed late, after {waited:?}"
    );
    let reply = client.ask(2, json!({"method": "accept", "listener": 1}));
    assert_eq!(
        reply["error"]["refused"], "no connection is waiting",
        "{reply}"
    );
}

#[test]
fn connections_past_the_pending_limit_are_closed_at_once() {
    let mut client = Client::connect();
    let port = client.listening(1);
    let mut held = Vec::new();
    for _ in 0..wr_agent::forward::MAX_PENDING {
        held.push(connected_to(port));
        assert_eq!(client.next(1), Some((ACCEPTED, vec![])));
    }
    let mut over = connected_to(port);
    assert!(ended(&mut over), "the agent held one more than its limit");
    assert!(
        client.next_within(1, Duration::from_millis(300)).is_none(),
        "and did not announce it"
    );
}

#[test]
fn the_connection_ending_ends_its_listeners() {
    let mut client = Client::connect();
    let port = client.listening(1);
    drop(client);
    let deadline = Instant::now() + PATIENCE;
    while !released(port) {
        assert!(
            Instant::now() < deadline,
            "the port outlived its connection"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn the_fifth_listener_on_a_connection_is_refused() {
    let mut client = Client::connect();
    for stream in 1..=wr_agent::forward::MAX_LISTENERS as u32 {
        client.listening(stream);
    }
    let reply = client.ask(99, json!({"method": "listen", "port": 0}));
    assert_eq!(reply["error"]["refused"], "too many listeners", "{reply}");
    assert_eq!(client.next(99), Some((CLOSE, vec![])));
}

#[test]
fn a_listeners_stream_cannot_be_reopened_while_it_listens() {
    let echo = Echo::start();
    let mut client = Client::connect();
    let port = client.listening(1);
    let reply = client.open(1, "127.0.0.1", echo.port);
    assert_eq!(
        reply["error"]["refused"], "stream 1 is already forwarding",
        "{reply}"
    );
    let _peer = connected_to(port);
    assert_eq!(client.next(1), Some((ACCEPTED, vec![])));
}
