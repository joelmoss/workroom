//! `Service::Status` over a real connection: the wakefulness verdict as the app sees it, asked for
//! and pushed (#380). The classifier's own behaviour is unit-tested in `wakefulness/tests.rs`; this
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
        let (stream, server) = UnixStream::pair().unwrap();
        std::thread::spawn(move || {
            let _ = handle_connection(server, SessionStore::new());
        });
        Client::greet(stream)
    }

    /// A running agent's socket.
    #[cfg(target_os = "linux")]
    fn connect_to(socket: &std::path::Path) -> Client {
        Client::greet(UnixStream::connect(socket).unwrap())
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

    /// The next unsolicited Status event (stream 0), or None by `deadline`. Replies to earlier
    /// requests are skipped.
    #[cfg(target_os = "linux")]
    fn event(&mut self, deadline: Instant) -> Option<Value> {
        while Instant::now() < deadline {
            if let Some(envelope) = self.decoder.next_envelope().unwrap() {
                if envelope.service == Service::Status && envelope.stream == 0 {
                    let (_, body) = envelope.payload.split_first().unwrap();
                    return Some(serde_json::from_slice(body).unwrap());
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
        None
    }
}

#[test]
fn status_answers_with_the_verdict() {
    let mut client = Client::connect();
    let reply = client.request(&json!({"method": "status"}));
    assert_eq!(reply["version"], 2);
    let result = &reply["result"];
    for key in ["running", "verdict", "busy", "monotonic", "stalled"] {
        assert!(!result[key].is_null(), "{key}: {result}");
    }
    // A fresh agent has voted nothing, so it claims nothing: never BUSY by default.
    assert_eq!(result["verdict"], "IDLE");
    assert_eq!(result["busy"], false);
    // #257: what keeps a BUSY box awake, and why it is not. Nothing sent, nothing failed yet.
    assert!(result["keep_awake"].is_object(), "{result}");
    assert!(result["keep_awake"]["last_sent"].is_null());
    assert!(result["keep_awake"]["error"].is_null());
    assert_eq!(result["stalled"], false, "{result}");
    // #380: the awake ceiling is gone, and with it every field it reported.
    for gone in [
        "awake_ceiling_exceeded",
        "prompt_pending",
        "ceiling_seconds",
        "ask_at_ceiling",
    ] {
        assert!(result.get(gone).is_none(), "{gone}: {result}");
    }
}

/// Stream 0 is the agent's: it is where verdict changes go, never where a request arrives. A
/// request sent there is dropped, and the connection stays usable.
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

/// `status` is the one request: the ceiling's `keep` and `settings` went with it (#380), and the
/// service never sleeps a box on request.
#[test]
fn every_other_method_is_refused() {
    let mut client = Client::connect();
    for method in ["keep", "settings", "hibernate"] {
        let refused = client.request(&json!({"method": method}));
        assert!(
            !refused["error"]["unsupported"].is_null(),
            "{method}: {refused}"
        );
    }
}

/// A real agent on Linux, where the wakefulness service runs: a connection that has asked for
/// `status` is pushed the verdict without asking again (#380), and `status` reports the
/// heartbeat's fields from a running service.
#[cfg(target_os = "linux")]
#[test]
fn a_running_agent_pushes_its_verdict_to_a_listener() {
    let dir = std::env::temp_dir().join(format!("wr-status-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("agent.sock");
    let binary = std::env::var_os("WR_AGENT_BIN")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| env!("CARGO_BIN_EXE_wr-agent").into());
    // Killed, and its directory removed, however the test ends: a failed assertion must not leave
    // a never-idling agent behind.
    struct Agent(std::process::Child, std::path::PathBuf);
    impl Drop for Agent {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
            let _ = std::fs::remove_dir_all(&self.1);
        }
    }
    let child = std::process::Command::new(binary)
        .args(["serve", "--socket"])
        .arg(&socket)
        .args(["--idle-timeout", "never"])
        .env("SHELL", "/bin/sh")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .spawn()
        .expect("spawn agent");
    let _agent = Agent(child, dir.clone());
    let deadline = Instant::now() + Duration::from_secs(5);
    while !socket.exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    let mut client = Client::connect_to(&socket);
    // Asking makes this connection a listener. The service's first tick publishes a verdict it
    // has never pushed, so it pushes it.
    let asked = client.request(&json!({"method": "status"}));
    assert_eq!(asked["version"], 2);
    let event = client
        .event(Instant::now() + Duration::from_secs(10))
        .expect("no verdict was pushed");
    assert_eq!(event["version"], 2, "{event}");
    assert_eq!(event["event"], "status", "{event}");
    let status = &event["status"];
    assert_eq!(status["running"], true, "{event}");
    assert!(
        status["verdict"] == "BUSY" || status["verdict"] == "IDLE",
        "{event}"
    );
    assert_eq!(status["stalled"], false, "{event}");
    assert!(status["keep_awake"].is_object(), "{event}");
}
