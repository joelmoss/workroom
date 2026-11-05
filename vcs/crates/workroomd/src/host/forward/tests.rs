use super::*;
use std::sync::mpsc::Receiver as Rx;

/// Everything the daemon wrote toward the client, for the tests that have no socket.
#[derive(Clone, Default)]
struct Capture(Arc<Mutex<Vec<u8>>>);

impl Write for Capture {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().expect("capture").extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// A forward registered by hand, with nothing draining it — the state a socket writer parked on
/// a peer that has stopped reading would be in, without needing a peer that stops reading.
fn stalled(forwards: &Forwards, stream: u32) -> Rx<Msg> {
    let (tx, rx) = channel();
    forwards.live.fetch_add(1, Ordering::AcqRel);
    forwards.open.lock().unwrap().insert(
        stream,
        Conn {
            tx,
            queued: Arc::new(AtomicUsize::new(0)),
            socket: Arc::new(Mutex::new(None)),
            token: 0,
            killed: Arc::new(AtomicBool::new(false)),
            half_closed: AtomicBool::new(false),
        },
    );
    rx
}

fn killed(forwards: &Forwards, stream: u32) -> bool {
    forwards.open.lock().unwrap()[&stream]
        .killed
        .load(Ordering::Acquire)
}

/// The opcodes the daemon wrote toward the client, in order, with their streams.
fn sent(capture: &Capture) -> Vec<(u32, u8)> {
    let written = capture.0.lock().unwrap().clone();
    let mut decoder = wr_protocol::envelope::EnvelopeDecoder::new();
    decoder.push(&written);
    std::iter::from_fn(|| decoder.next_envelope().unwrap())
        .map(|e| (e.stream, e.payload[0]))
        .collect()
}

/// A task as `open` would have built it, for the connect-window tests.
fn task_for(forwards: &Forwards, writer: SharedWriter) -> (ForwardTask, Rx<Msg>) {
    let (tx, rx) = channel();
    let (_, probe) = channel();
    let killed = Arc::new(AtomicBool::new(false));
    let socket = Arc::new(Mutex::new(None));
    let conn = Conn {
        tx,
        queued: Arc::new(AtomicUsize::new(0)),
        socket: Arc::clone(&socket),
        token: 0,
        killed: Arc::clone(&killed),
        half_closed: AtomicBool::new(false),
    };
    forwards.open.lock().unwrap().insert(1, conn);
    forwards.live.fetch_add(1, Ordering::AcqRel);
    let task = ForwardTask {
        stream: 1,
        token: 0,
        rx,
        queued: Arc::new(AtomicUsize::new(0)),
        socket,
        killed,
        slot: Arc::new(Slot(Arc::clone(&forwards.live))),
        open: Arc::clone(&forwards.open),
        writer,
    };
    (task, probe)
}

/// The connect `open` would make to `port` on this box.
fn local(port: u16) -> Source {
    Source::Connect(vec![IpAddr::V4(Ipv4Addr::LOCALHOST)], port)
}

fn refusal(body: &[u8]) -> Value {
    match request(body) {
        Err(refusal) => refusal.value(),
        Ok(_) => panic!("expected a refusal"),
    }
}

#[test]
fn only_the_three_loopback_literals_are_accepted() {
    assert_eq!(
        loopback_addresses("127.0.0.1"),
        Some(vec![IpAddr::V4(Ipv4Addr::LOCALHOST)])
    );
    assert_eq!(
        loopback_addresses("::1"),
        Some(vec![IpAddr::V6(Ipv6Addr::LOCALHOST)])
    );
    // Both, because a server may be bound to only one of them.
    assert_eq!(loopback_addresses("localhost").unwrap().len(), 2);
    assert_eq!(loopback_addresses("LocalHost").unwrap().len(), 2);
}

/// The allowlist is a list of literals, not a range and not a resolution: anything else is
/// refused, including addresses that WOULD resolve to the loopback interface.
#[test]
fn everything_else_is_not_loopback() {
    for host in [
        "127.0.0.2",
        "127.1",
        "0.0.0.0",
        "localhost.evil.test",
        "evil.test",
        "10.0.0.1",
        "[::1]",
        "::ffff:127.0.0.1",
        "",
        " 127.0.0.1",
    ] {
        assert!(loopback_addresses(host).is_none(), "{host:?}");
    }
}

#[test]
fn an_open_request_parses_to_an_address_and_a_port() {
    let opening = request(br#"{"method":"open","host":"127.0.0.1","port":5173}"#)
        .ok()
        .expect("parsed");
    assert_eq!(
        opening,
        Opening::Connect(vec![IpAddr::V4(Ipv4Addr::LOCALHOST)], 5173)
    );
}

#[test]
fn a_non_loopback_host_is_refused_by_the_parser_before_any_socket_work() {
    let error = refusal(br#"{"method":"open","host":"10.0.0.1","port":80}"#);
    assert_eq!(
        error["error"]["refused"],
        "10.0.0.1 is not a loopback address"
    );
    assert_eq!(error["version"], FORWARD_SERVICE_VERSION);
}

#[test]
fn a_malformed_request_is_unsupported_rather_than_a_dropped_stream() {
    // Not JSON at all — a DATA payload that arrived before its OPEN, say.
    assert_eq!(
        refusal(b"\x00\x01binary")["error"]["unsupported"],
        "forward requests are a single JSON object"
    );
    for body in [
        &br#"{"method":"open","host":"127.0.0.1"}"#[..],
        br#"{"method":"open","port":5173}"#,
        br#"{"method":"listen","host":"127.0.0.1","port":5173}"#,
        // Ports are u16: 0 is legal to ASK for, 65536 is not a port at all.
        br#"{"method":"open","host":"127.0.0.1","port":65536}"#,
        br#"{"method":"open","host":"127.0.0.1","port":-1}"#,
        // Unknown fields are refused, so the request shape cannot drift silently.
        br#"{"method":"open","host":"127.0.0.1","port":80,"bind":"0.0.0.0"}"#,
        br#"{"#,
    ] {
        assert!(
            refusal(body)["error"]["unsupported"].is_string(),
            "{}",
            String::from_utf8_lossy(body)
        );
    }
}

/// The branch the whole backpressure argument rests on: a forward whose bytes are not being
/// taken is killed at the budget rather than buffered without limit. Killed, not closed from
/// here: the writer parked on `recv` gets the message, the entry stays so the id cannot be
/// re-opened under it, and the CLOSE is the threads' to send once they are out.
#[test]
fn a_forward_that_falls_past_the_queue_budget_is_killed_rather_than_buffered() {
    let forwards = Forwards::new();
    let capture = Capture::default();
    let rx = stalled(&forwards, 1);

    let chunk = vec![7u8; 256 * 1024];
    let mut delivered = 0;
    while !killed(&forwards, 1) {
        forwards.deliver(1, &chunk);
        delivered += chunk.len();
        assert!(
            delivered <= MAX_QUEUED_BYTES + chunk.len(),
            "the budget was never enforced: {delivered} bytes queued"
        );
    }
    // Enforced at the budget, not somewhere short of it: bytes plus the per-message overhead.
    let charged = delivered + MESSAGE_OVERHEAD * (delivered / chunk.len());
    assert!(charged > MAX_QUEUED_BYTES, "killed early at {delivered}");
    // Every chunk but the one that overflowed, then the kill that unparks the writer.
    let mut messages = 0;
    loop {
        match rx.try_recv() {
            Ok(Msg::Data(_)) => messages += 1,
            Ok(Msg::Kill) => break,
            other => panic!("expected the kill after the data, got {}", other.is_ok()),
        }
    }
    assert_eq!(messages, delivered / chunk.len() - 1);
    // Nothing said from here, and nothing more queued: the forward is over.
    assert!(sent(&capture).is_empty());
    forwards.deliver(1, &chunk);
    assert!(rx.try_recv().is_err());
    assert!(
        forwards.open.lock().unwrap().contains_key(&1),
        "the id is still held"
    );
}

/// Empty DATA and a second EOF are not free: each would be a channel node behind a stalled
/// writer. Empty DATA is dropped (nothing to write), EOF is queued once.
#[test]
fn empty_messages_do_not_grow_the_queue() {
    let forwards = Forwards::new();
    let rx = stalled(&forwards, 1);
    for _ in 0..10_000 {
        forwards.deliver(1, &[]);
        forwards.half_close(1);
    }
    let mut eofs = 0;
    while let Ok(message) = rx.try_recv() {
        assert!(matches!(message, Msg::Eof));
        eofs += 1;
    }
    assert_eq!(eofs, 1);
    assert!(!killed(&forwards, 1));
}

/// After the client's own EOF there is no writer to take its bytes, so they are dropped rather
/// than charged to a budget that would eventually kill a healthy forward still relaying the
/// peer's reply.
#[test]
fn data_after_the_clients_eof_is_dropped_not_charged() {
    let forwards = Forwards::new();
    let rx = stalled(&forwards, 1);
    forwards.half_close(1);
    let chunk = vec![7u8; 512 * 1024];
    for _ in 0..8 {
        forwards.deliver(1, &chunk);
    }
    assert!(!killed(&forwards, 1), "charged for bytes nobody would take");
    assert!(matches!(rx.try_recv(), Ok(Msg::Eof)));
    assert!(rx.try_recv().is_err());
}

/// A client's CLOSE kills the forward and holds its entry: the threads answer with CLOSE, and
/// until they have, the id cannot be re-opened under them.
#[test]
fn a_client_close_kills_the_forward_and_holds_the_id() {
    let forwards = Forwards::new();
    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    let rx = stalled(&forwards, 1);
    forwards.close(1);
    assert!(killed(&forwards, 1));
    assert!(matches!(rx.try_recv(), Ok(Msg::Kill)));
    assert!(
        sent(&capture).is_empty(),
        "the threads say CLOSE, not the dispatcher"
    );
    forwards.open(
        1,
        br#"{"method":"open","host":"127.0.0.1","port":1}"#,
        &writer,
    );
    let reply = sent(&capture);
    assert_eq!(
        reply,
        vec![(1, REPLY)],
        "refused without a CLOSE: {reply:?}"
    );
}

/// An OPEN for a stream that is already forwarding is refused whatever its body, and never
/// closed: a malformed duplicate used to take the parse-error branch first and send a CLOSE
/// for a healthy forward the daemon kept running.
#[test]
fn a_malformed_open_for_an_already_forwarding_stream_does_not_close_it() {
    let forwards = Forwards::new();
    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    let _rx = stalled(&forwards, 1);
    for body in [
        &br#"{"method":"listen"}"#[..],
        b"garbage",
        br#"{"method":"open","host":"10.0.0.1","port":1}"#,
    ] {
        forwards.open(1, body, &writer);
    }
    assert!(forwards.open.lock().unwrap().contains_key(&1));
    assert!(!killed(&forwards, 1));
    let opcodes = sent(&capture);
    assert_eq!(opcodes.len(), 3);
    assert!(opcodes.iter().all(|(_, op)| *op == REPLY), "{opcodes:?}");
}

/// The cap counts forwards alive, and the 65th is refused.
#[test]
fn the_65th_forward_on_a_connection_is_refused() {
    let forwards = Forwards::new();
    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    let _held: Vec<_> = (1..=MAX_FORWARDS as u32)
        .map(|stream| stalled(&forwards, stream))
        .collect();
    forwards.open(
        MAX_FORWARDS as u32 + 1,
        br#"{"method":"open","host":"127.0.0.1","port":1}"#,
        &writer,
    );
    assert_eq!(
        sent(&capture),
        vec![
            (MAX_FORWARDS as u32 + 1, REPLY),
            (MAX_FORWARDS as u32 + 1, CLOSE)
        ]
    );
    assert!(
        !forwards
            .open
            .lock()
            .unwrap()
            .contains_key(&(MAX_FORWARDS as u32 + 1))
    );
}

/// The connection went away while the connect was still in flight (`Forwards::drop` took the
/// entry): the socket that connect produces belongs to nobody, so it is shut down on the spot
/// and nothing is said — there is nobody to say it to.
#[test]
fn a_departure_that_lands_during_the_connect_shuts_the_socket_and_says_nothing() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let forwards = Forwards::new();
    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    let (task, _probe) = task_for(&forwards, writer);
    forwards.open.lock().unwrap().clear();
    connect_and_run(task, local(port));

    let (mut accepted, _) = listener.accept().unwrap();
    accepted
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    // The peer sees EOF at once: the socket was shut down, not parked on a reader thread.
    assert_eq!(accepted.read(&mut [0u8; 8]).unwrap(), 0);
    assert!(sent(&capture).is_empty(), "no REPLY, no CLOSE");
    assert!(forwards.open.lock().unwrap().is_empty());
}

/// The client sent CLOSE while the connect was still in flight: the socket is shut down on the
/// spot, the client gets the CLOSE it is waiting for and no `opened`, and the id is free.
#[test]
fn a_close_that_lands_during_the_connect_is_answered_with_close_alone() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let forwards = Forwards::new();
    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    let (task, _probe) = task_for(&forwards, writer);
    forwards.close(1);
    connect_and_run(task, local(port));

    let (mut accepted, _) = listener.accept().unwrap();
    accepted
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    assert_eq!(accepted.read(&mut [0u8; 8]).unwrap(), 0);
    assert_eq!(sent(&capture), vec![(1, CLOSE)]);
    assert!(forwards.open.lock().unwrap().is_empty());
}

/// The same, on the failure path: a connect that fails after the client gave up says CLOSE and
/// no error — and one that fails while the connection is gone says nothing at all.
#[test]
fn a_failing_connect_answers_only_what_the_client_is_still_waiting_for() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);

    let forwards = Forwards::new();
    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    let (task, _probe) = task_for(&forwards, writer.clone());
    connect_and_run(task, local(port));
    assert_eq!(
        sent(&capture),
        vec![(1, REPLY), (1, CLOSE)],
        "still wanted: error, then CLOSE"
    );

    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    let (task, _probe) = task_for(&forwards, writer.clone());
    forwards.close(1);
    connect_and_run(task, local(port));
    assert_eq!(sent(&capture), vec![(1, CLOSE)], "killed: CLOSE alone");

    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    let (task, _probe) = task_for(&forwards, writer);
    forwards.open.lock().unwrap().clear();
    connect_and_run(task, local(port));
    assert!(sent(&capture).is_empty(), "gone: nothing");
}

/// LOW 11 (connection thread): if `Forwards::open`'s connect-thread spawn fails, the stream must
/// still be freed rather than held for the rest of the connection. `retire_after_spawn_failure`
/// is the code that runs on that `Err`; exercised directly, since forcing a real
/// `std::thread::Builder::spawn` failure means exhausting real OS threads.
#[test]
fn a_forward_whose_connect_thread_failed_to_spawn_is_retired_not_left_open() {
    let forwards = Forwards::new();
    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    let _rx = stalled(&forwards, 1); // registers a Conn with token 0, as `open` would have.
    retire_after_spawn_failure(&forwards.open, &writer, 1, 0);
    assert!(
        !forwards.open.lock().unwrap().contains_key(&1),
        "the stream id must be freed"
    );
    assert_eq!(sent(&capture), vec![(1, REPLY), (1, CLOSE)]);
}

/// LOW 11 (forward writer thread): if the READER thread's spawn fails after the `opened: true`
/// REPLY already went out, the entry must still be retired — with CLOSE alone, never a second
/// REPLY — rather than left open with nothing left to ever send the CLOSE that frees it.
#[test]
fn a_forward_whose_reader_thread_failed_to_spawn_is_retired_with_close_alone() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let forwards = Forwards::new();
    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    let (task, _probe) = task_for(&forwards, writer);
    let socket = TcpStream::connect(("127.0.0.1", port)).unwrap();
    let (mut accepted, _) = listener.accept().unwrap();
    accepted
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();

    retire_after_reader_spawn_failure(&task, &socket);

    assert_eq!(
        sent(&capture),
        vec![(1, CLOSE)],
        "CLOSE alone: a REPLY already shipped, so there is no second one to send"
    );
    assert!(
        forwards.open.lock().unwrap().is_empty(),
        "the id must be freed"
    );
    assert_eq!(
        accepted.read(&mut [0u8; 8]).unwrap(),
        0,
        "the socket must actually be shut down, not merely forgotten"
    );
}

/// A host as long as an envelope allows must not produce a reply longer than one: the refusal
/// abbreviates what it echoes, and `send` refuses rather than asserts in any case.
#[test]
fn a_huge_host_gets_a_bounded_refusal_rather_than_a_panic() {
    let host = "h".repeat(MAX_ENVELOPE_PAYLOAD - 64);
    let body = format!(r#"{{"method":"open","host":"{host}","port":1}}"#);
    let error = refusal(body.as_bytes());
    let detail = error["error"]["refused"].as_str().unwrap();
    assert!(detail.len() < 200, "{}", detail.len());
    assert!(detail.ends_with("… is not a loopback address"));

    let capture = Capture::default();
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(capture.clone())));
    assert!(!send(&writer, 1, DATA, &vec![0u8; MAX_ENVELOPE_PAYLOAD]));
    assert!(sent(&capture).is_empty());
}

/// A second CLOSE (or a reset behind one) must not queue a second message behind a writer that
/// cannot drain the channel yet: a kill happens once.
#[test]
fn a_kill_happens_once() {
    let forwards = Forwards::new();
    let rx = stalled(&forwards, 1);
    for _ in 0..10_000 {
        forwards.close(1);
    }
    let mut kills = 0;
    while let Ok(message) = rx.try_recv() {
        assert!(matches!(message, Msg::Kill));
        kills += 1;
    }
    assert_eq!(kills, 1);
}

/// serde echoes input in some messages (an unknown field's name): a maximum-sized OPEN must still
/// get a refusal that fits an envelope, so the REPLY is not silently dropped before the CLOSE.
#[test]
fn a_huge_unknown_field_gets_a_bounded_refusal() {
    let field = "f".repeat(MAX_ENVELOPE_PAYLOAD - 80);
    let body = format!(r#"{{"method":"open","host":"127.0.0.1","port":1,"{field}":1}}"#);
    let error = refusal(body.as_bytes());
    let detail = error["error"]["unsupported"].as_str().unwrap();
    assert!(detail.len() < 400, "{}", detail.len());
    assert!(serde_json::to_vec(&error).unwrap().len() < 1024);
}

/// The budget is sized so two maximum-sized envelopes fit, overhead included: a forward that
/// stalled for one round trip behind a full envelope is not killed for it.
#[test]
fn two_maximum_envelopes_fit_the_budget() {
    let forwards = Forwards::new();
    let _rx = stalled(&forwards, 1);
    let full = vec![0u8; MAX_ENVELOPE_PAYLOAD - 1];
    forwards.deliver(1, &full);
    forwards.deliver(1, &full);
    assert!(!killed(&forwards, 1));
    forwards.deliver(1, &[1]);
    assert!(killed(&forwards, 1));
}

#[test]
fn listen_and_accept_parse_to_their_own_openings() {
    assert_eq!(
        request(br#"{"method":"listen","port":47123}"#).ok(),
        Some(Opening::Listen(47123))
    );
    assert_eq!(
        request(br#"{"method":"listen","port":0}"#).ok(),
        Some(Opening::Listen(0))
    );
    assert_eq!(
        request(br#"{"method":"accept","listener":7}"#).ok(),
        Some(Opening::Accept(7))
    );
}

/// Each method takes its own fields only, so a client mixing them up is told which.
#[test]
fn a_field_from_another_method_is_refused_by_name() {
    for (body, detail) in [
        (
            &br#"{"method":"listen","host":"127.0.0.1","port":1}"#[..],
            "listen takes only a port",
        ),
        (
            br#"{"method":"listen","port":1,"listener":2}"#,
            "listen takes only a port",
        ),
        (br#"{"method":"listen"}"#, "missing port"),
        (
            br#"{"method":"accept","listener":2,"port":1}"#,
            "accept takes only a listener",
        ),
        (
            br#"{"method":"accept","listener":2,"host":"::1"}"#,
            "accept takes only a listener",
        ),
        (br#"{"method":"accept"}"#, "missing listener"),
        (
            br#"{"method":"open","host":"127.0.0.1","port":1,"listener":2}"#,
            "open takes a host and a port",
        ),
    ] {
        assert_eq!(
            refusal(body)["error"]["unsupported"],
            detail,
            "{}",
            String::from_utf8_lossy(body)
        );
    }
}

/// The whole request object, and nothing else: the Swift client is written from this shape.
#[test]
fn the_request_is_exactly_method_host_and_port() {
    let request: Request =
        serde_json::from_slice(br#"{"method":"open","host":"localhost","port":0}"#).unwrap();
    assert_eq!(
        request,
        Request {
            method: "open".into(),
            host: Some("localhost".into()),
            port: Some(0),
            listener: None,
        }
    );
}
