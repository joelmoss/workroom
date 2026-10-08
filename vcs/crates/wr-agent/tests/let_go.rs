//! The wakefulness let-go (#380) over real connections: which connections `serve::connections()`
//! closes once the box has been idle, and which it must leave alone. The registry's rules are
//! unit-tested in `serve.rs` with hand-set flags; this covers the seam, that `handle_connection`
//! registers each connection, that an attached pane and a forward in flight really mark theirs, and
//! that a close reaches the peer.
//!
//! One test, in a binary of its own: the registry is process-global (one box, one decision), so a
//! second test here would have its connections closed by this one's let-go.

// Value: protects=the let-go spares a connection while a pane is attached or a forward is in flight, and closes an unused one;
// fails_when=Attach stops marking its connection a pane, Forwards::carrying stops counting an open forward, or registration is dropped;
// why_new=serve.rs sets the flags by hand and never goes through handle_connection's Attach and Forward dispatch; seam=none

use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use wr_agent::protocol::envelope::{Envelope, EnvelopeDecoder, Hello, Service};
use wr_agent::protocol::frame::{Frame, FrameKind};
use wr_agent::serve::{connections, handle_connection, AttachRequest};
use wr_agent::session::{SessionId, SessionStore};

const FORWARD_OPEN: u8 = 0x01;
const PATIENCE: Duration = Duration::from_secs(10);

struct Client {
    stream: UnixStream,
    decoder: EnvelopeDecoder,
}

impl Client {
    fn connect(sessions: &SessionStore) -> Client {
        let (mut stream, server) = UnixStream::pair().unwrap();
        let sessions = sessions.clone();
        std::thread::spawn(move || {
            let _ = handle_connection(server, sessions);
        });
        stream
            .write_all(&Hello::current("let-go-test").encode())
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
        }
    }

    fn send(&mut self, service: Service, stream: u32, payload: Vec<u8>) {
        self.stream
            .write_all(&Envelope::new(service, stream, payload).encode())
            .unwrap();
    }

    /// Reads until `wait` has passed and says whether the agent closed the connection meanwhile.
    fn closed_within(&mut self, wait: Duration) -> bool {
        let deadline = Instant::now() + wait;
        while Instant::now() < deadline {
            let mut bytes = [0u8; 65536];
            match self.stream.read(&mut bytes) {
                Ok(0) => return true,
                Ok(count) => self.decoder.push(&bytes[..count]),
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(_) => return true,
            }
        }
        false
    }

    /// Reads until an envelope of `service` arrives.
    fn wait_for(&mut self, service: Service) {
        let deadline = Instant::now() + PATIENCE;
        while Instant::now() < deadline {
            while let Some(envelope) = self.decoder.next_envelope().unwrap() {
                if envelope.service == service {
                    return;
                }
            }
            let mut bytes = [0u8; 65536];
            match self.stream.read(&mut bytes) {
                Ok(0) => panic!("the agent closed the connection"),
                Ok(count) => self.decoder.push(&bytes[..count]),
                Err(_) => {}
            }
        }
        panic!("no {service:?} envelope arrived");
    }
}

#[test]
fn the_let_go_spares_a_pane_and_a_forward_and_closes_an_unused_connection() {
    let sessions = SessionStore::new();
    let mut idle = Client::connect(&sessions);
    let mut pane = Client::connect(&sessions);
    let mut forwarding = Client::connect(&sessions);

    // A pane: an attached shell.
    let attach = AttachRequest {
        id: Some(SessionId([7u8; 16])),
        shell: Some("/bin/sh".into()),
        columns: 80,
        rows: 24,
        env: vec![("PATH".into(), "/usr/bin:/bin".into())],
        ..Default::default()
    };
    pane.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Attach, attach.encode()).encode(),
    );
    let deadline = Instant::now() + PATIENCE;
    while !sessions.list().first().is_some_and(|s| s.attached) {
        assert!(Instant::now() < deadline, "the pane never attached");
        std::thread::sleep(Duration::from_millis(10));
    }
    // The connection is marked a pane right after the session attaches.
    std::thread::sleep(Duration::from_millis(300));

    // A forward in flight: the target accepts and holds the connection.
    let target = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = target.local_addr().unwrap().port();
    std::thread::spawn(move || {
        let held: Vec<_> = target.incoming().flatten().collect();
        std::thread::sleep(Duration::from_secs(60));
        drop(held);
    });
    let open = serde_json::json!({"method": "open", "host": "127.0.0.1", "port": port});
    let mut payload = vec![FORWARD_OPEN];
    payload.extend_from_slice(&serde_json::to_vec(&open).unwrap());
    forwarding.send(Service::Forward, 1, payload);
    forwarding.wait_for(Service::Forward);

    // Grace zero: every connection is old enough, so only what is in use can save one.
    let registry = connections();
    assert_eq!(
        registry.let_go(Instant::now(), Duration::ZERO),
        0,
        "nothing goes while a pane is attached"
    );
    assert!(!idle.closed_within(Duration::from_millis(300)));
    assert!(!forwarding.closed_within(Duration::from_millis(300)));

    // The pane's connection ends. What is left is one a forward is using and one nothing is.
    drop(pane);
    let deadline = Instant::now() + PATIENCE;
    let mut closed = 0;
    while closed == 0 {
        assert!(
            Instant::now() < deadline,
            "the pane's connection never left the registry"
        );
        closed = registry.let_go(Instant::now(), Duration::ZERO);
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(closed, 1, "only the unused connection goes");
    assert!(idle.closed_within(PATIENCE), "the peer never saw the close");
    assert!(
        !forwarding.closed_within(Duration::from_millis(300)),
        "a forward in flight is traffic"
    );
    sessions.kill_all();
}
