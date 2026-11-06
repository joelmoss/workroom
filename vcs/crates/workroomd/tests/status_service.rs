//! `Service::Status` after its retirement (#382): an app from before then still asks for `status`,
//! and must get a failure it already handles, on the stream it asked on, rather than silence (it
//! would wait out its own timeout) or a protocol error (it would lose the whole connection).

#[allow(dead_code)] // not every helper is used here
mod common;

use serde_json::{Value, json};
use std::io::{Read, Write};
use std::time::Duration;
use wr_protocol::envelope::{Envelope, Service};

struct Client(common::RpcClient);

impl Client {
    fn connect() -> Client {
        let (rpc, _server) = common::RpcClient::connect("status-test", Duration::from_millis(200));
        Client(rpc)
    }

    /// The reply to `request`, which must be the only thing the daemon sends: nothing on another
    /// stream or service.
    fn request(&mut self, request: &Value) -> Value {
        let stream = self.0.take_stream();
        let reply = self.0.request(Service::Status, stream, request);
        let stray: Vec<_> = self.0.other.iter().map(|e| (e.service, e.stream)).collect();
        assert!(stray.is_empty(), "arrived besides the reply: {stray:?}");
        reply
    }
}

/// Every request is refused the way the app's decoder (`DaemonStatusReply`) reads a failure:
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
        .0
        .writer
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
    match client.0.reader.read(&mut bytes) {
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
            ) => {}
        other => panic!("stream 0 must never be answered, got {other:?}"),
    }
    assert_eq!(client.request(&json!({"method": "status"}))["version"], 2);
}
