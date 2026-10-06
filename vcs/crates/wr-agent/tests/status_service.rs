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
    // #257: what keeps a BUSY box awake, and why it is not. Nothing sent, nothing failed yet.
    assert!(result["keep_awake"].is_object(), "{result}");
    assert!(result["keep_awake"]["last_sent"].is_null());
    assert!(result["keep_awake"]["error"].is_null());
    assert_eq!(result["stalled"], false, "{result}");
}

/// The app's ceiling settings (#257): accepted and echoed back, or refused whole. Applying them is
/// the service thread's, unit-tested in `wakefulness/tests.rs`.
#[test]
fn settings_are_echoed_back_and_unusable_ones_refused() {
    let mut client = Client::connect();
    let accepted = client.request(&json!({
        "method": "settings",
        "ceiling_seconds": 7200,
        "prompt_timeout_seconds": 120,
        "ask_at_ceiling": true,
    }));
    assert_eq!(accepted["version"], 1);
    assert_eq!(
        accepted["result"]["settings"],
        json!({"ceiling_seconds": 7200.0, "prompt_timeout_seconds": 120.0, "ask_at_ceiling": true}),
        "{accepted}"
    );
    let refused = client.request(&json!({
        "method": "settings",
        "ceiling_seconds": -1,
        "prompt_timeout_seconds": 120,
        "ask_at_ceiling": true,
    }));
    assert!(!refused["error"]["invalid"].is_null(), "{refused}");
    assert!(refused["result"].is_null());
}

/// Stream 0 is the agent's: it is where the ceiling prompt goes, never where a request arrives. A
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
    assert_eq!(client.request(&json!({"method": "status"}))["version"], 1);
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

/// A real agent on Linux, where the wakefulness service runs (#257): the settings kept beside its
/// socket win over its flags at start, a `settings` request is applied by the service and kept for
/// the next start, and `status` reports the heartbeat's fields from a running service.
#[cfg(target_os = "linux")]
#[test]
fn a_running_agent_starts_with_its_kept_settings_and_keeps_new_ones() {
    let dir = std::env::temp_dir().join(format!("wr-status-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("agent.sock");
    let kept = dir.join("agent.sock.settings");
    std::fs::write(
        &kept,
        r#"{"ceiling_seconds":7200.0,"prompt_timeout_seconds":120.0,"ask_at_ceiling":true}"#,
    )
    .unwrap();
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
        .args(["--idle-timeout", "never", "--awake-ceiling", "100"])
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
    // The service starts on its own thread; poll until it has published a tick.
    let status =
        |client: &mut Client| client.request(&json!({"method": "status"}))["result"].clone();
    let until = |client: &mut Client, what: &str, done: &dyn Fn(&Value) -> bool| {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let result = status(client);
            if done(&result) {
                return result;
            }
            assert!(Instant::now() < deadline, "{what}: {result}");
            std::thread::sleep(Duration::from_millis(100));
        }
    };

    let started = until(&mut client, "the service never ran", &|r| {
        r["running"] == true
    });
    assert_eq!(
        started["ceiling_seconds"], 7200.0,
        "the kept file wins over the flag"
    );
    assert_eq!(started["ask_at_ceiling"], true);
    assert_eq!(started["stalled"], false);
    assert!(started["keep_awake"].is_object(), "{started}");

    let echoed = client.request(&json!({
        "method": "settings",
        "ceiling_seconds": 3600,
        "prompt_timeout_seconds": 600,
        "ask_at_ceiling": false,
    }));
    assert_eq!(
        echoed["result"]["settings"]["ceiling_seconds"], 3600.0,
        "{echoed}"
    );
    let applied = until(&mut client, "never applied", &|r| {
        r["ceiling_seconds"] == 3600.0
    });
    assert_eq!(applied["ask_at_ceiling"], false);
    // Kept by the saver's own thread, so polled rather than read once.
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let saved = std::fs::read(&kept)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
        if saved
            .as_ref()
            .is_some_and(|s| s["ceiling_seconds"] == 3600.0)
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "never kept for the next start: {saved:?}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// A `settings` request the moment the agent is up, before its service has ticked, is still kept
/// for the next start: where it is kept is settled before the agent accepts a connection.
#[cfg(target_os = "linux")]
#[test]
fn settings_sent_before_the_first_tick_are_kept() {
    let dir = std::env::temp_dir().join(format!("wr-status-early-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("agent.sock");
    let kept = dir.join("agent.sock.settings");
    let binary = std::env::var_os("WR_AGENT_BIN")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| env!("CARGO_BIN_EXE_wr-agent").into());
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
        std::thread::sleep(Duration::from_millis(5));
    }
    let mut client = Client::connect_to(&socket);
    let echoed = client.request(&json!({
        "method": "settings",
        "ceiling_seconds": 5400,
        "prompt_timeout_seconds": 300,
        "ask_at_ceiling": true,
    }));
    assert_eq!(
        echoed["result"]["settings"]["ceiling_seconds"], 5400.0,
        "{echoed}"
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let saved = std::fs::read(&kept)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok());
        if saved
            .as_ref()
            .is_some_and(|s| s["ceiling_seconds"] == 5400.0)
        {
            break;
        }
        assert!(Instant::now() < deadline, "never kept: {saved:?}");
        std::thread::sleep(Duration::from_millis(50));
    }
}
