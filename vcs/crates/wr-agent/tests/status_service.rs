//! `Service::Status` over a real connection: the wakefulness verdict and the awake ceiling as the
//! app sees them. The classifier's own behaviour is unit-tested in `wakefulness/tests.rs`; this
//! covers the seam — that the envelope reaches the service and comes back in the agreed shape.

use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};
use wr_agent::protocol::envelope::{Envelope, EnvelopeDecoder, Hello, Service};
use wr_agent::serve::handle_connection;
use wr_agent::session::SessionStore;

struct Client {
    stream: UnixStream,
    decoder: EnvelopeDecoder,
    next_stream: u32,
}

impl Client {
    fn connect() -> Client {
        let (mut stream, server) = UnixStream::pair().unwrap();
        std::thread::spawn(move || {
            let _ = handle_connection(server, SessionStore::new());
        });
        stream
            .write_all(&Hello::current("status-test").encode())
            .unwrap();
        let mut greeting = Vec::new();
        while Hello::decode(&greeting).unwrap().is_none() {
            let mut byte = [0u8];
            stream.read_exact(&mut byte).unwrap();
            greeting.push(byte[0]);
        }
        stream
            .set_read_timeout(Some(Duration::from_millis(200)))
            .unwrap();
        Client {
            stream,
            decoder: EnvelopeDecoder::new(),
            next_stream: 1,
        }
    }

    fn request(&mut self, request: &Value) -> Value {
        let stream = self.next_stream;
        self.next_stream += 1;
        self.stream
            .write_all(
                &Envelope::new(
                    Service::Status,
                    stream,
                    serde_json::to_vec(request).unwrap(),
                )
                .encode(),
            )
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut assembled = Vec::new();
        while Instant::now() < deadline {
            if let Some(envelope) = self.decoder.next_envelope().unwrap() {
                assert_eq!(envelope.service, Service::Status);
                assert_eq!(envelope.stream, stream);
                let (flag, body) = envelope.payload.split_first().unwrap();
                assembled.extend_from_slice(body);
                if *flag == 1 {
                    return serde_json::from_slice(&assembled).unwrap();
                }
                continue;
            }
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
        panic!("no reply on stream {stream}");
    }
}

#[test]
fn status_answers_with_the_verdict_and_the_ceiling() {
    let mut client = Client::connect();
    let reply = client.request(&json!({"method": "status"}));
    assert_eq!(reply["version"], 1);
    let result = &reply["result"];
    // Everything the app needs to show BUSY/IDLE and to run the ceiling prompt itself.
    for key in [
        "running",
        "verdict",
        "busy",
        "monotonic",
        "awake_seconds",
        "awake_ceiling_exceeded",
        "prompt_pending",
        "prompt_deadline",
        "suppressed",
        "ceiling_seconds",
        "prompt_timeout_seconds",
        "ask_at_ceiling",
    ] {
        assert!(!result[key].is_null() || key == "prompt_deadline", "{key}");
    }
    // A fresh agent has voted nothing, so it claims nothing: never BUSY by default.
    assert_eq!(result["verdict"], "IDLE");
    assert_eq!(result["busy"], false);
    assert_eq!(result["awake_ceiling_exceeded"], false);
    assert_eq!(result["prompt_pending"], false);
    // OQ22's defaults: 4 h, 10 min, advisory-only.
    assert_eq!(result["ceiling_seconds"], 14400.0);
    assert_eq!(result["prompt_timeout_seconds"], 600.0);
    assert_eq!(result["ask_at_ceiling"], false);
}

#[test]
fn keep_is_acknowledged_and_an_unknown_method_is_refused() {
    let mut client = Client::connect();
    assert_eq!(
        client.request(&json!({"method": "keep"}))["result"]["kept"],
        true
    );
    let refused = client.request(&json!({"method": "hibernate"}));
    assert!(
        !refused["error"].is_null(),
        "the service never sleeps a box on request: {refused}"
    );
}
