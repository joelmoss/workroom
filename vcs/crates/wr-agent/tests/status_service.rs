//! `Service::Status` after its retirement (#382): an app from before then still asks for `status`,
//! and must get a failure it already handles, on the stream it asked on, rather than silence (it
//! would wait out its own timeout) or a protocol error (it would lose the whole connection).

use serde_json::{Value, json};
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
        let (stream, server) = UnixStream::pair().unwrap();
        std::thread::spawn(move || {
            let _ = handle_connection(server, SessionStore::new());
        });
        Client::greet(stream)
    }

    fn greet(mut stream: UnixStream) -> Client {
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

/// Every request is refused the way the app's decoder (`AgentStatusReply`) reads a failure:
/// version 2, the last it speaks, and one `unsupported` error. The connection stays usable.
#[test]
fn every_status_request_is_refused_as_unsupported() {
    let mut client = Client::connect();
    for method in ["status", "keep", "settings"] {
        let refused = client.request(&json!({"method": method}));
        assert_eq!(refused["version"], 2, "{method}: {refused}");
        assert!(refused["result"].is_null(), "{method}: {refused}");
        let error = refused["error"].as_object().expect("an error object");
        assert_eq!(error.len(), 1, "{method}: {refused}");
        assert!(error["unsupported"].is_string(), "{method}: {refused}");
    }
}

/// Stream 0 was where verdict changes were pushed, never where a request arrives. A request sent
/// there is dropped, and the connection stays usable.
#[test]
fn a_request_on_stream_zero_gets_no_reply() {
    let mut client = Client::connect();
    client
        .stream
        .write_all(
            &Envelope::new(
                Service::Status,
                0,
                serde_json::to_vec(&json!({"method": "status"})).unwrap(),
            )
            .encode(),
        )
        .unwrap();
    let mut bytes = [0u8; 64];
    match client.stream.read(&mut bytes) {
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) => {}
        other => panic!("stream 0 must never be answered, got {other:?}"),
    }
    assert_eq!(client.request(&json!({"method": "status"}))["version"], 2);
}
