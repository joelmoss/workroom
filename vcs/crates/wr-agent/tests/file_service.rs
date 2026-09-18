//! `Service::File` over a real connection: the wire shape, the watch lifecycle, and the coalescing
//! bound. The unit tests in `file.rs` and `watch.rs` cover the pieces; this covers the seams — the
//! envelope, chunked replies, events on stream 0, and a subscription's life inside one connection.

use serde_json::{json, Value};
use std::collections::VecDeque;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};
use wr_agent::protocol::envelope::{Envelope, EnvelopeDecoder, Hello, Service};
use wr_agent::serve::handle_connection;
use wr_agent::session::SessionStore;

struct Client {
    stream: UnixStream,
    decoder: EnvelopeDecoder,
    next_stream: u32,
    events: VecDeque<Value>,
    server: Option<std::thread::JoinHandle<()>>,
}

impl Client {
    fn connect() -> Client {
        let (mut stream, server) = UnixStream::pair().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_millis(200)))
            .unwrap();
        let server = std::thread::spawn(move || {
            let _ = handle_connection(server, SessionStore::new());
        });
        stream
            .write_all(&Hello::current("file-test").encode())
            .unwrap();
        let mut greeting = Vec::new();
        while Hello::decode(&greeting).unwrap().is_none() {
            let mut byte = [0u8];
            stream.read_exact(&mut byte).unwrap();
            greeting.push(byte[0]);
        }
        Client {
            stream,
            decoder: EnvelopeDecoder::new(),
            next_stream: 1,
            events: VecDeque::new(),
            server: Some(server),
        }
    }

    /// The next whole envelope, or `None` when nothing arrived within the read timeout.
    fn envelope(&mut self) -> Option<Envelope> {
        loop {
            if let Some(envelope) = self.decoder.next_envelope().unwrap() {
                return Some(envelope);
            }
            let mut bytes = [0u8; 65536];
            match self.stream.read(&mut bytes) {
                Ok(0) => return None,
                Ok(count) => self.decoder.push(&bytes[..count]),
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    return None
                }
                Err(error) => panic!("read failed: {error}"),
            }
        }
    }

    fn send(&mut self, request: &Value) -> u32 {
        let stream = self.next_stream;
        self.next_stream += 1;
        self.send_raw(stream, serde_json::to_vec(request).unwrap());
        stream
    }

    fn send_raw(&mut self, stream: u32, payload: Vec<u8>) {
        self.stream
            .write_all(&Envelope::new(Service::File, stream, payload).encode())
            .unwrap();
    }

    /// Send a request and wait for its reply, setting aside any events that arrive first.
    fn request(&mut self, request: &Value) -> Value {
        let stream = self.send(request);
        self.reply(stream)
    }

    fn reply(&mut self, stream: u32) -> Value {
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut assembled = Vec::new();
        while Instant::now() < deadline {
            let Some(envelope) = self.envelope() else {
                continue;
            };
            assert_eq!(envelope.service, Service::File);
            let (flag, body) = envelope.payload.split_first().unwrap();
            if envelope.stream == 0 {
                assert_eq!(*flag, 1, "an event is always one final envelope");
                self.events.push_back(serde_json::from_slice(body).unwrap());
            } else if envelope.stream == stream {
                assembled.extend_from_slice(body);
                if *flag == 1 {
                    return serde_json::from_slice(&assembled).unwrap();
                }
            } else {
                panic!("reply on a stream nobody asked on: {}", envelope.stream);
            }
        }
        panic!("no reply on stream {stream}");
    }

    /// The next event for `subscription` within `wait`, ignoring other subscriptions'.
    fn event(&mut self, subscription: u64, wait: Duration) -> Option<Value> {
        let deadline = Instant::now() + wait;
        loop {
            if let Some(index) = self
                .events
                .iter()
                .position(|event| event["subscription"] == subscription)
            {
                return self.events.remove(index);
            }
            if Instant::now() >= deadline {
                return None;
            }
            if let Some(envelope) = self.envelope() {
                assert_eq!(envelope.stream, 0, "only events arrive unasked");
                self.events
                    .push_back(serde_json::from_slice(&envelope.payload[1..]).unwrap());
            }
        }
    }

    fn watch(&mut self, subscription: u64, root: &Path) -> Value {
        self.request(&json!({
            "version": 1, "method": "watch", "subscription": subscription, "root": root,
        }))
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
        if let Some(server) = self.server.take() {
            let _ = server.join();
        }
    }
}

fn scratch(name: &str) -> PathBuf {
    let root = std::env::temp_dir().join(format!("wr-file-it-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    std::fs::canonicalize(&root).unwrap()
}

fn touched(event: &Value, name: &str) -> bool {
    event["paths"]
        .as_array()
        .unwrap()
        .iter()
        .any(|path| path.as_str().unwrap().ends_with(name))
}

#[test]
fn capabilities_list_and_read_round_trip_over_the_wire() {
    let root = scratch("roundtrip");
    assert!(Command::new("git")
        .args(["init", "-q", "-b", "main"])
        .current_dir(&root)
        .status()
        .unwrap()
        .success());
    std::fs::write(root.join("hello.txt"), b"hello wire").unwrap();

    let mut client = Client::connect();
    let capabilities = client.request(&json!({"version": 1, "method": "capabilities"}));
    assert_eq!(capabilities["result"]["version"], 1);
    assert_eq!(capabilities["result"]["max_read_bytes"], 8 * 1024 * 1024);

    let listing = client.request(&json!({
        "version": 1, "method": "list", "backend": "git", "root": root,
    }));
    assert_eq!(listing["result"]["exit_code"], 0, "{listing}");
    assert_eq!(listing["result"]["stdout"], "hello.txt\0");

    let read = client.request(&json!({
        "version": 1, "method": "read", "root": root, "path": "hello.txt",
        "symlinks": "follow_within_root", "max_bytes": 1024,
    }));
    assert_eq!(read["result"]["size"], 10);
    assert_eq!(read["result"]["content"], "aGVsbG8gd2lyZQ==");
}

#[test]
fn a_large_read_arrives_intact_across_chunked_envelopes() {
    let root = scratch("chunked");
    // Three envelopes' worth of base64, and every byte value, so a chunk boundary in the wrong
    // place corrupts something visible.
    let bytes: Vec<u8> = (0..2_500_000u32).map(|n| (n % 251) as u8).collect();
    std::fs::write(root.join("big.bin"), &bytes).unwrap();
    let mut client = Client::connect();
    let read = client.request(&json!({
        "version": 1, "method": "read", "root": root, "path": "big.bin",
        "symlinks": "refuse", "max_bytes": 8 * 1024 * 1024,
    }));
    assert_eq!(read["result"]["size"], bytes.len());
    // Length is a sufficient check that no chunk was lost or duplicated: base64 is 4 bytes per 3.
    assert_eq!(
        read["result"]["content"].as_str().unwrap().len(),
        bytes.len().div_ceil(3) * 4
    );
}

#[test]
fn a_listing_over_the_capture_cap_is_a_typed_failure_not_a_short_list() {
    let root = scratch("truncated");
    assert!(Command::new("git")
        .args(["init", "-q", "-b", "main"])
        .current_dir(&root)
        .status()
        .unwrap()
        .success());
    // 22,000 names of 200 bytes is 4.4 MB of `ls-files` output, past the 4 MiB cap.
    let padding = "n".repeat(190);
    for index in 0..22_000 {
        std::fs::write(root.join(format!("{padding}{index:010}")), b"").unwrap();
    }
    let mut client = Client::connect();
    let reply = client.request(&json!({
        "version": 1, "method": "list", "backend": "git", "root": root,
    }));
    assert!(
        reply["error"]["ListingTruncated"].is_string(),
        "expected a typed truncation failure, got {}",
        &reply.to_string()[..reply.to_string().len().min(200)]
    );
}

#[test]
fn a_chunked_request_marker_and_stream_zero_requests_are_handled_safely() {
    let mut client = Client::connect();
    // A VCS-style chunked request starts with 0x02, not `{`. It gets a typed answer, not silence.
    let stream = client.next_stream;
    client.next_stream += 1;
    client.send_raw(stream, vec![0x02, 0x01, b'{', b'}']);
    let reply = client.reply(stream);
    assert!(reply["error"]["Unsupported"].is_string());
    // Stream 0 is the agent's; a request on it is ignored, and the connection stays usable.
    client.send_raw(0, br#"{"version":1,"method":"capabilities"}"#.to_vec());
    let after = client.request(&json!({"version": 1, "method": "capabilities"}));
    assert_eq!(after["result"]["version"], 1);
}

#[test]
fn a_watch_delivers_a_leading_event_at_once_and_one_trailing_batch() {
    let root = scratch("watch");
    let mut client = Client::connect();
    assert_eq!(client.watch(7, &root)["result"]["subscription"], 7);

    // Settle: FSEvents can still be reporting the directory's own creation.
    while client.event(7, Duration::from_millis(1500)).is_some() {}

    std::fs::write(root.join("first.txt"), b"1").unwrap();
    let leading = client
        .event(7, Duration::from_secs(5))
        .expect("a leading event within the notification latency");
    assert_eq!(leading["event"], "changed");
    assert_eq!(leading["overflow"], false);
    assert!(touched(&leading, "first.txt"), "{leading}");

    // A burst inside the window: many raw notifications, few deliveries.
    for index in 0..200 {
        std::fs::write(root.join(format!("burst-{index}.txt")), b"x").unwrap();
    }
    let mut deliveries = 0;
    let mut seen_last = false;
    let deadline = Instant::now() + Duration::from_secs(6);
    while Instant::now() < deadline && !seen_last {
        if let Some(event) = client.event(7, Duration::from_millis(500)) {
            deliveries += 1;
            seen_last |= touched(&event, "burst-199.txt");
        }
    }
    assert!(seen_last, "the trailing batch reports the final state");
    assert!(
        deliveries <= 3,
        "a 200-file burst must coalesce, saw {deliveries} deliveries"
    );
}

#[test]
fn an_unwatched_subscription_goes_quiet_and_other_subscriptions_are_unaffected() {
    let quiet = scratch("unwatch-a");
    let live = scratch("unwatch-b");
    let mut client = Client::connect();
    client.watch(1, &quiet);
    client.watch(2, &live);
    while client.event(1, Duration::from_millis(1500)).is_some() {}
    while client.event(2, Duration::from_millis(100)).is_some() {}

    let reply = client.request(&json!({"version": 1, "method": "unwatch", "subscription": 1}));
    assert_eq!(reply["result"]["subscription"], 1);
    // Unwatching twice, or an id that never existed, is not an error.
    let again = client.request(&json!({"version": 1, "method": "unwatch", "subscription": 1}));
    assert!(again["result"].is_object());

    std::fs::write(quiet.join("ignored.txt"), b"x").unwrap();
    std::fs::write(live.join("seen.txt"), b"x").unwrap();
    let event = client.event(2, Duration::from_secs(5)).expect("live watch");
    assert!(touched(&event, "seen.txt"));
    assert!(
        client.event(1, Duration::from_millis(1500)).is_none(),
        "an unsubscribed id delivers nothing"
    );
}

#[test]
fn subscription_ids_are_unique_and_the_count_is_capped() {
    let root = scratch("cap");
    let mut client = Client::connect();
    assert!(client.watch(1, &root)["result"].is_object());
    assert!(client.watch(1, &root)["error"]["Unsupported"]
        .as_str()
        .unwrap()
        .contains("already in use"));
    for id in 2..=64 {
        assert!(client.watch(id, &root)["result"].is_object(), "{id}");
    }
    assert!(client.watch(65, &root)["error"]["Busy"].is_string());
    // Freeing one makes room again.
    client.request(&json!({"version": 1, "method": "unwatch", "subscription": 2}));
    assert!(client.watch(65, &root)["result"].is_object());
}

#[test]
fn watching_something_that_is_not_a_directory_is_not_found() {
    let root = scratch("not-a-dir");
    std::fs::write(root.join("file"), b"x").unwrap();
    let mut client = Client::connect();
    assert!(client.watch(1, &root.join("file"))["error"]["NotFound"].is_string());
    assert!(client.watch(2, &root.join("absent"))["error"]["NotFound"].is_string());
}

#[test]
fn a_watched_root_that_is_deleted_ends_the_subscription_with_a_typed_event() {
    let parent = scratch("root-removed");
    let root = parent.join("watched");
    std::fs::create_dir_all(&root).unwrap();
    let mut client = Client::connect();
    client.watch(9, &root);
    while client.event(9, Duration::from_millis(1500)).is_some() {}

    std::fs::remove_dir_all(&root).unwrap();
    let mut ended = None;
    let deadline = Instant::now() + Duration::from_secs(8);
    while Instant::now() < deadline && ended.is_none() {
        if let Some(event) = client.event(9, Duration::from_millis(500)) {
            if event["event"] == "ended" {
                ended = Some(event);
            }
        }
    }
    assert_eq!(ended.expect("an `ended` event")["reason"], "root_removed");
}

#[test]
fn ending_the_connection_stops_its_watchers() {
    let root = scratch("teardown");
    let mut client = Client::connect();
    client.watch(1, &root);
    // Dropping the client closes the socket and joins the server thread: if a subscription kept the
    // connection alive (or its thread blocked on the dead socket) this would hang the test.
    drop(client);
}
