//! `Service::ProgramStatus` (#358) end to end: what a program says through its pty reaches a
//! subscribed connection, in the order and shape the app depends on, and the program's probe is
//! answered through the pty whoever is attached.
//!
//! Sessions run `/bin/sh` scripts in a store the test holds, served over an in-process connection,
//! so nothing here touches a real agent, socket or session.

#[allow(dead_code)] // not every helper is used here
mod common;

use serde_json::{Value, json};
use std::ffi::{OsStr, OsString};
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};
use wr_agent::session::{SessionId, SessionSpec, SessionStore};
use wr_protocol::envelope::{Envelope, EnvelopeDecoder, Service};

struct Client {
    stream: UnixStream,
    decoder: EnvelopeDecoder,
    next_stream: u32,
}

impl Client {
    fn connect(store: &SessionStore) -> Client {
        let (stream, _server) = common::connect_in_process_to("program-status-test", store.clone());
        stream
            .set_read_timeout(Some(Duration::from_millis(50)))
            .unwrap();
        Client {
            stream,
            decoder: EnvelopeDecoder::new(),
            next_stream: 1,
        }
    }

    fn send_bytes(&mut self, payload: Vec<u8>) -> u32 {
        let stream = self.next_stream;
        self.next_stream += 1;
        self.stream
            .write_all(&Envelope::new(Service::ProgramStatus, stream, payload).encode())
            .unwrap();
        stream
    }

    /// The next envelope as (stream, JSON), or `None` once `timeout` passes.
    fn next(&mut self, timeout: Duration) -> Option<(u32, Value)> {
        let deadline = Instant::now() + timeout;
        loop {
            if let Some(envelope) = self.decoder.next_envelope().unwrap() {
                assert_eq!(envelope.service, Service::ProgramStatus);
                let (flag, body) = envelope.payload.split_first().unwrap();
                assert_eq!(*flag, 1, "every reply and event is one final envelope");
                return Some((envelope.stream, serde_json::from_slice(body).unwrap()));
            }
            if Instant::now() >= deadline {
                return None;
            }
            let mut bytes = [0u8; 65536];
            match self.stream.read(&mut bytes) {
                Ok(0) => panic!("the agent closed the connection"),
                Ok(n) => self.decoder.push(&bytes[..n]),
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(e) => panic!("read failed: {e}"),
            }
        }
    }

    /// The reply to `request`, which must come before anything else.
    fn request(&mut self, request: Value) -> Value {
        let stream = self.send_bytes(serde_json::to_vec(&request).unwrap());
        let (got, reply) = self.next(Duration::from_secs(10)).expect("a reply");
        assert_eq!(got, stream, "something came before the reply: {reply}");
        reply
    }

    /// The next event on stream 0.
    fn event(&mut self) -> Value {
        let (stream, event) = self.next(Duration::from_secs(10)).expect("an event");
        assert_eq!(stream, 0, "{event}");
        event
    }

    /// Events until one satisfies `done`, that one last.
    fn events_until(&mut self, done: impl Fn(&Value) -> bool) -> Vec<Value> {
        let mut seen = Vec::new();
        loop {
            let event = self.event();
            let last = done(&event);
            seen.push(event);
            if last {
                return seen;
            }
        }
    }
}

fn id(byte: u8) -> SessionId {
    SessionId([byte; 16])
}

fn start(store: &SessionStore, session: SessionId, script: &str) {
    let args = [OsString::from("-c"), OsString::from(script)];
    let env = [
        (OsString::from("TERM"), OsString::from("xterm-256color")),
        (OsString::from("PATH"), OsString::from("/usr/bin:/bin")),
    ];
    store
        .create(SessionSpec {
            id: session,
            program: OsStr::new("/bin/sh"),
            argv0: None,
            args: &args,
            env: &env,
            cwd: None,
            columns: 80,
            rows: 24,
            metadata: &[],
            interactive: false,
        })
        .expect("create");
}

/// The app reads `available` to decide whether to show program status at all.
#[test]
fn subscribing_says_whether_this_build_keeps_program_status() {
    let store = SessionStore::new();
    let mut client = Client::connect(&store);
    let reply = client.request(json!({"version": 1, "method": "subscribe"}));
    assert_eq!(reply["version"], 1);
    if cfg!(feature = "terminal-state") {
        assert_eq!(reply["result"]["available"], true, "{reply}");
        let events = client.events_until(|e| e["event"] == "snapshot-complete");
        let complete = &events[0];
        assert_eq!(complete["sessions"], json!([]));
    } else {
        assert_eq!(
            reply,
            json!({"version": 1, "result": {
                "available": false,
                "reason": "wr-agent was built without terminal-state; build with --features terminal-state",
            }})
        );
        assert!(client.next(Duration::from_millis(300)).is_none());
    }
}

/// Every request gets the reply shape the app decodes, and none of them ends the connection.
#[test]
fn requests_are_answered_in_the_shapes_the_app_decodes() {
    let store = SessionStore::new();
    start(&store, id(1), "sleep 5");
    let session = id(1).to_hyphenated();
    let unknown = id(2).to_hyphenated();
    let mut client = Client::connect(&store);
    let ok = json!({"version": 1, "result": {"ok": true}});
    let unknown_session = json!({"version": 1, "error": "unknown_session"});
    let unsupported = json!({"version": 1, "error": "unsupported"});
    for (request, want) in [
        (
            json!({"version": 1, "method": "seen", "session": session, "revision": 3}),
            &ok,
        ),
        (
            json!({"version": 1, "method": "seen", "session": session, "revision": 3, "states": ["done"]}),
            &ok,
        ),
        (
            json!({"version": 1, "method": "clear", "session": session}),
            &ok,
        ),
        (
            json!({"version": 1, "method": "clear", "session": unknown}),
            &unknown_session,
        ),
        (
            json!({"version": 1, "method": "seen", "session": unknown, "revision": 1}),
            &unknown_session,
        ),
        (
            json!({"version": 1, "method": "seen", "session": session}),
            &unsupported,
        ),
        (json!({"version": 1, "method": "clear"}), &unsupported),
        (
            json!({"version": 1, "method": "seen", "session": session, "revision": 1, "states": ["nope"]}),
            &unsupported,
        ),
        (json!({"version": 1, "method": "status"}), &unsupported),
        (json!({"version": 1, "method": "unsubscribe"}), &ok),
    ] {
        assert_eq!(&client.request(request.clone()), want, "{request}");
    }
    client.send_bytes(b"not json".to_vec());
    assert_eq!(
        client.next(Duration::from_secs(10)).expect("a reply").1,
        unsupported
    );
    store.kill_all();
}

/// What only a build with the shadow terminal does: answer probes and keep records.
#[cfg(feature = "terminal-state")]
mod live {
    use super::*;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};

    /// libghostty's answer to `OSC 7501 ; ?`, before the probe's own terminator.
    const ANSWER: &str =
        "\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth";

    const BLOCKED: &str =
        r"printf '\033]7501;state=blocked:kind=permission:app=claude-code:msg=QXBwbHk/\033\\'";
    const PROBE: &str = r"printf '\033]7501;?\033\\'";
    /// A prober as Claude Code is one: it reads the answer before it reports, so its report is
    /// trusted to alert. (A probe and a report printed together are not.)
    const ASK: &str = r"stty -echo -icanon min 0 time 50; printf '\033]7501;?\033\\'; dd bs=256 count=1 >/dev/null 2>&1";

    /// The session's status as a new subscriber's snapshot would carry it.
    fn status_of(store: &SessionStore, session: SessionId) -> Value {
        let (_, event) = store
            .program_status_events()
            .into_iter()
            .find(|(id, _)| *id == session)
            .expect("a live session");
        serde_json::from_slice(&event).unwrap()
    }

    /// Polls `read` for up to 10 s until `done` holds, and returns the last value.
    fn wait_until<T>(mut read: impl FnMut() -> T, done: impl Fn(&T) -> bool) -> T {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut value = read();
        while !done(&value) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
            value = read();
        }
        value
    }

    fn states(status: &Value) -> Vec<String> {
        status["records"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["state"].as_str().unwrap().to_string())
            .collect()
    }

    /// The `ok` reply to a `seen` or `clear` and the one status event it publishes. The agent hands
    /// the event to the subscriber's thread before it writes the reply, so they arrive in either order.
    fn update(client: &mut Client, request: Value) -> Value {
        let stream = client.send_bytes(serde_json::to_vec(&request).unwrap());
        let (mut reply, mut event) = (None, None);
        while reply.is_none() || event.is_none() {
            let (got, body) = client
                .next(Duration::from_secs(10))
                .expect("a reply and an event");
            let slot = if got == stream {
                &mut reply
            } else {
                &mut event
            };
            assert!(got == stream || got == 0, "stray stream {got}: {body}");
            assert!(
                slot.replace(body).is_none(),
                "a second envelope on stream {got}"
            );
        }
        assert_eq!(
            reply.unwrap(),
            json!({"version": 1, "result": {"ok": true}})
        );
        event.unwrap()
    }

    fn text(store: &SessionStore, session: SessionId) -> String {
        String::from_utf8_lossy(&store.replay_bytes(session)).into_owned()
    }

    /// A scratch directory for gate files, removed with the test.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Scratch {
            let dir = std::env::temp_dir().join(format!("wr-ps-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            Scratch(dir)
        }

        fn path(&self, name: &str) -> String {
            self.0.join(name).display().to_string()
        }

        fn open(&self, name: &str) {
            std::fs::write(self.0.join(name), b"").unwrap();
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// Everything a session sent an attached client.
    #[derive(Clone, Default)]
    struct Capture(Arc<Mutex<Vec<u8>>>);

    impl Write for Capture {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    fn attach(store: &SessionStore, session: SessionId, writer: impl Write + Send + 'static) {
        let writer: Arc<Mutex<Box<dyn Write + Send>>> = Arc::new(Mutex::new(Box::new(writer)));
        store.attach(session, writer, 1, 80, 24).expect("attach");
    }

    /// Value: protects=the probe's answer reaches the program through the pty exactly once, attached or not; fails_when=the reader stops writing replies, writes them per client, or only while attached; why_new=Claude reports nothing without the answer (Step 0); seam=none
    #[test]
    fn a_probe_is_answered_through_the_pty_once_whoever_is_attached() {
        let scratch = Scratch::new("probe");
        // The program reads its input with the echo off: everything that arrives within 2 s of the
        // probe, then anything more in the next 2 s.
        let script = format!(
            r#"until [ -e "{gate}" ]; do sleep 0.02; done
stty -echo -icanon min 0 time 20
{PROBE}
n=$(dd bs=4096 count=1 2>/dev/null | wc -c | tr -d ' ')
m=$(dd bs=4096 count=1 2>/dev/null | wc -c | tr -d ' ')
echo "GOT:$n:$m:"
sleep 5"#,
            gate = scratch.path("gate")
        );
        let store = SessionStore::new();
        for session in [id(1), id(2), id(3)] {
            start(&store, session, &script);
        }
        let one = Capture::default();
        attach(&store, id(2), one.clone());
        let (first, second) = (Capture::default(), Capture::default());
        attach(&store, id(3), first.clone());
        attach(&store, id(3), second.clone());
        scratch.open("gate");

        let want = format!("GOT:{}:0:", ANSWER.len() + 2);
        for (session, label) in [
            (id(1), "detached"),
            (id(2), "one client"),
            (id(3), "two clients"),
        ] {
            let seen = wait_until(|| text(&store, session), |t| t.contains("GOT:"));
            assert!(seen.contains(&want), "{label}: want {want}, got {seen:?}");
        }
        store.kill_all();
    }

    /// The reply goes out first, then a status per live session, then `snapshot-complete`, and only
    /// then the live changes, whose episode carries on from the snapshot's.
    #[test]
    fn the_reply_comes_first_then_the_snapshot_then_live_changes() {
        let scratch = Scratch::new("order");
        let store = SessionStore::new();
        start(
            &store,
            id(1),
            &format!(
                r#"{ASK}; {BLOCKED}; until [ -e "{gate}" ]; do sleep 0.02; done; printf '\033]7501;state=done:app=claude-code\033\\'; sleep 5"#,
                gate = scratch.path("gate")
            ),
        );
        start(&store, id(2), "sleep 5");
        let blocked = wait_until(|| status_of(&store, id(1)), |s| states(s) == ["blocked"]);
        assert_eq!(states(&blocked), ["blocked"], "fixture: {blocked}");

        let mut client = Client::connect(&store);
        let reply = client.request(json!({"version": 1, "method": "subscribe"}));
        assert_eq!(reply["result"]["available"], true);
        let boot = store.program_status().boot().to_hyphenated();
        let first = client.event();
        let second = client.event();
        let complete = client.event();
        assert_eq!(
            (&first["session"], &second["session"]),
            (&json!(id(1).to_hyphenated()), &json!(id(2).to_hyphenated()))
        );
        assert_eq!(first["event"], "status");
        assert_eq!(first["boot"], boot);
        assert_eq!(first["reporting"], true);
        let record = &first["records"][0];
        assert_eq!(
            (&record["state"], &record["kind"], &record["message"]),
            (&json!("blocked"), &json!("permission"), &json!("Apply?"))
        );
        assert_eq!(
            (&record["episode"], &record["notify"]),
            (&json!(1), &json!(true))
        );
        assert_eq!(second["records"], json!([]));
        assert_eq!(second["reporting"], false);
        assert_eq!(
            complete,
            json!({"event": "snapshot-complete", "boot": boot,
               "sessions": [id(1).to_hyphenated(), id(2).to_hyphenated()]})
        );

        scratch.open("gate");
        let live = client.event();
        assert_eq!(live["session"], id(1).to_hyphenated());
        assert_eq!(states(&live), ["done"]);
        assert_eq!(
            live["records"][0]["episode"], 1,
            "the episode is the record's"
        );
        assert!(live["revision"].as_u64() > first["revision"].as_u64());
        store.kill_all();
    }

    /// Both ways a session ends: its program exits, or a client kills it. Either way a subscriber
    /// hears its running records go, then `ended`.
    #[test]
    fn a_session_that_ends_says_so_after_its_last_status() {
        let scratch = Scratch::new("ended");
        let store = SessionStore::new();
        start(
            &store,
            id(1),
            &format!(
                r#"{BLOCKED}; until [ -e "{gate}" ]; do sleep 0.02; done; exit 0"#,
                gate = scratch.path("gate")
            ),
        );
        start(&store, id(2), &format!("{BLOCKED}; sleep 30"));
        for session in [id(1), id(2)] {
            wait_until(|| status_of(&store, session), |s| states(s) == ["blocked"]);
        }
        let mut client = Client::connect(&store);
        client.request(json!({"version": 1, "method": "subscribe"}));
        client.events_until(|e| e["event"] == "snapshot-complete");

        for (session, end) in [(id(1), "exits"), (id(2), "is killed")] {
            if session == id(1) {
                scratch.open("gate");
            } else {
                assert!(store.kill(session));
            }
            let events = client.events_until(|e| e["event"] == "ended");
            let ended = events.last().unwrap();
            assert_eq!(
                ended,
                &json!({"event": "ended", "boot": store.program_status().boot().to_hyphenated(),
                    "session": session.to_hyphenated()}),
                "when it {end}"
            );
            let last_status = events
                .iter()
                .rev()
                .find(|e| e["event"] == "status")
                .unwrap_or_else(|| panic!("no status before ended when it {end}: {events:?}"));
            assert_eq!(last_status["session"], session.to_hyphenated());
            assert_eq!(last_status["records"], json!([]), "when it {end}");
        }
    }

    /// An app from before protocol 8 never subscribes, and is never sent a service byte it would fail
    /// its connection on.
    #[test]
    fn a_connection_that_never_subscribes_is_sent_nothing() {
        let store = SessionStore::new();
        let mut client = Client::connect(&store);
        start(&store, id(1), &format!("{ASK}; {BLOCKED}; sleep 5"));
        let blocked = wait_until(|| status_of(&store, id(1)), |s| states(s) == ["blocked"]);
        assert_eq!(states(&blocked), ["blocked"], "fixture: {blocked}");
        assert!(client.next(Duration::from_millis(500)).is_none());
        store.kill_all();
    }

    /// `seen` drops the done record the app showed and `clear` every record, each publishing the
    /// result.
    #[test]
    fn seen_and_clear_publish_what_they_change() {
        let store = SessionStore::new();
        start(
            &store,
            id(1),
            r"printf '\033]7501;state=done\033\\\033]7501;id=b:state=blocked\033\\'; sleep 5",
        );
        wait_until(
            || status_of(&store, id(1)),
            |s| states(s) == ["done", "blocked"],
        );
        let mut client = Client::connect(&store);
        client.request(json!({"version": 1, "method": "subscribe"}));
        let snapshot = client.events_until(|e| e["event"] == "snapshot-complete");
        let shown = snapshot[0]["revision"].as_u64().unwrap();
        let session = id(1).to_hyphenated();

        let after_seen = update(
            &mut client,
            json!({"version": 1, "method": "seen", "session": session, "revision": shown}),
        );
        assert_eq!(states(&after_seen), ["blocked"]);
        assert_eq!(after_seen["revision"], shown + 1);

        let after_clear = update(
            &mut client,
            json!({"version": 1, "method": "clear", "session": session}),
        );
        assert_eq!(after_clear["records"], json!([]));
        assert_eq!(after_clear["reporting"], false);
        store.kill_all();
    }

    /// A hand-off keeps the records, their revision, episodes and notify, and the boot, so the app
    /// sees one store carry on.
    #[test]
    fn a_hand_off_carries_program_status_and_boot() {
        let before = SessionStore::new();
        start(&before, id(1), &format!("{ASK}; {BLOCKED}; sleep 5"));
        let blocked = wait_until(|| status_of(&before, id(1)), |s| states(s) == ["blocked"]);
        assert_eq!(states(&blocked), ["blocked"], "fixture: {blocked}");
        let frozen = before
            .frozen(Duration::from_secs(2), |all| all[0].clone())
            .expect("frozen");

        let after = SessionStore::new();
        after
            .program_status()
            .set_boot(before.program_status().boot());
        let args = [OsString::from("-c"), OsString::from("sleep 5")];
        let pty = wr_agent::pty::Pty::spawn(OsStr::new("/bin/sh"), None, &args, &[], None, 80, 24)
            .expect("pty");
        after.adopt(pty, frozen).expect("adopt");

        let carried = status_of(&after, id(1));
        assert_eq!(carried, blocked);
        assert_eq!(carried["records"][0]["episode"], 1);
        assert_eq!(carried["records"][0]["notify"], true);
        before.kill_all();
        after.kill_all();
    }

    /// Reports in quick succession reach a subscriber coalesced, at most one per throttle window, and
    /// the blocked one after them still arrives.
    #[test]
    fn quick_reports_are_coalesced_and_blocked_still_arrives() {
        let scratch = Scratch::new("throttle");
        let store = SessionStore::new();
        start(
            &store,
            id(1),
            &format!(
                r#"until [ -e "{gate}" ]; do sleep 0.02; done
i=0; while [ $i -lt 30 ]; do printf '\033]7501;id=s%d:state=working\033\\' $i; i=$((i+1)); sleep 0.01; done
{BLOCKED}; sleep 5"#,
                gate = scratch.path("gate")
            ),
        );
        let mut client = Client::connect(&store);
        client.request(json!({"version": 1, "method": "subscribe"}));
        client.events_until(|e| e["event"] == "snapshot-complete");
        let started = Instant::now();
        scratch.open("gate");
        let events = client.events_until(|e| states(e).contains(&"blocked".to_string()));
        let elapsed = started.elapsed();
        assert_eq!(
            events.last().unwrap()["records"].as_array().unwrap().len(),
            31
        );
        // Unthrottled, each of the 31 reports would be its own event.
        let windows = (elapsed.as_millis() / 50) as usize + 2;
        assert!(
            events.len() < 31 && events.len() <= windows,
            "{} events in {elapsed:?}",
            events.len()
        );
        store.kill_all();
    }

    /// A writer that stops taking bytes once `stalled` is set, until `released` is: a peer that has
    /// stopped reading.
    struct Stalling {
        stalled: Arc<AtomicBool>,
        released: Arc<AtomicBool>,
    }

    impl Write for Stalling {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            while self.stalled.load(Ordering::SeqCst) && !self.released.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(10));
            }
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// Value: protects=a subscriber that stops reading never stalls a session's output; fails_when=the reader writes events itself instead of marking the session dirty for the sink; why_new=a stuck peer must cost its own connection, not every pane; seam=writer
    #[test]
    fn a_stalled_subscriber_never_holds_up_a_session() {
        let store = SessionStore::new();
        start(
            &store,
            id(1),
            r"sleep 0.3; i=0; while [ $i -lt 100 ]; do printf '\033]7501;id=s%d:state=working\033\\TICK%d\n' $i $i; i=$((i+1)); sleep 0.005; done; sleep 5",
        );
        let output = Capture::default();
        attach(&store, id(1), output.clone());

        let stalled = Arc::new(AtomicBool::new(false));
        let released = Arc::new(AtomicBool::new(false));
        let writer: Arc<Mutex<Box<dyn Write + Send>>> = Arc::new(Mutex::new(Box::new(Stalling {
            stalled: Arc::clone(&stalled),
            released: Arc::clone(&released),
        })));
        let mut connection = wr_agent::program_status::Connection::new(
            Arc::clone(store.program_status()),
            writer,
            Arc::new(|| {}),
        );
        let subscribe = Envelope::new(
            Service::ProgramStatus,
            1,
            serde_json::to_vec(&json!({"version": 1, "method": "subscribe"})).unwrap(),
        );
        wr_agent::program_status::dispatch(&subscribe, &store, &mut connection);
        stalled.store(true, Ordering::SeqCst);

        let seen = wait_until(
            || String::from_utf8_lossy(&output.0.lock().unwrap()).into_owned(),
            |t| t.contains("TICK99"),
        );
        released.store(true, Ordering::SeqCst);
        assert!(
            seen.contains("TICK99"),
            "the session stalled behind its subscriber"
        );
        drop(connection);
        store.kill_all();
    }

    /// Value: protects=a blocked record survives its program being stopped (^Z) and goes once the program's group is gone; fails_when=the owner-liveness drop is removed, or keyed on the foreground group; why_new=a killed agent never says CLEAR, and without a prompt mark nothing else clears it; seam=none
    #[test]
    fn a_stopped_owner_keeps_blocked_and_a_killed_one_drops_it() {
        let scratch = Scratch::new("owner");
        let child = scratch.path("child.sh");
        std::fs::write(
            &child,
            format!(
                r#"{BLOCKED}; echo "PID:$$:"; until [ -e "{gate}" ]; do sleep 0.02; done"#,
                gate = scratch.path("never")
            ),
        )
        .unwrap();
        let store = SessionStore::new();
        // `set -m` gives the child a group of its own and the foreground, as an interactive shell
        // would. A ticker in another group keeps the pty producing output, and each read is when
        // owners are checked; bounded, so a failed run leaves nothing behind for long.
        start(
            &store,
            id(1),
            &format!(
                r#"set -m; (i=0; while [ $i -lt 400 ]; do echo TICK$i; i=$((i+1)); sleep 0.05; done) & /bin/sh "{child}"; sleep 30"#
            ),
        );
        let seen = wait_until(|| text(&store, id(1)), |t| t.contains("PID:"));
        let pid: libc::pid_t = seen
            .split("PID:")
            .nth(1)
            .and_then(|rest| rest.split(':').next())
            .and_then(|pid| pid.trim().parse().ok())
            .unwrap_or_else(|| panic!("fixture: no pid in {seen:?}"));
        let blocked = wait_until(|| status_of(&store, id(1)), |s| states(s) == ["blocked"]);
        assert_eq!(states(&blocked), ["blocked"], "fixture: {blocked}");

        // The newest tick on the screen.
        let tick = |store: &SessionStore| -> u32 {
            let text = text(store, id(1));
            let digits: String = text
                .rsplit("TICK")
                .next()
                .unwrap_or_default()
                .chars()
                .take_while(char::is_ascii_digit)
                .collect();
            digits.parse().unwrap_or(0)
        };
        // SAFETY: `kill` takes no pointers; the group is this test's own session's child's.
        assert_eq!(unsafe { libc::kill(-pid, libc::SIGSTOP) }, 0);
        let stopped_at = tick(&store);
        let later = wait_until(|| tick(&store), |t| *t >= stopped_at + 5);
        assert!(later >= stopped_at + 5, "fixture: the ticker stopped too");
        assert_eq!(
            states(&status_of(&store, id(1))),
            ["blocked"],
            "a stopped program lost its blocked record"
        );

        // SAFETY: as above.
        assert_eq!(unsafe { libc::kill(-pid, libc::SIGKILL) }, 0);
        let after = wait_until(|| status_of(&store, id(1)), |s| states(s).is_empty());
        assert_eq!(
            after["records"],
            json!([]),
            "a killed program's blocked record outlived it"
        );
        assert_eq!(after["reporting"], false);
        store.kill_all();
    }

    /// Value: protects=Claude Code's real sequence (probe, then idle, working, blocked, done, clear) gives the app a notifying blocked record and a done that outlives the turn, through a real session; fails_when=the agent stops answering the probe (the mock, like Claude, then reports nothing), or the records stop following Claude's order; why_new=every other test sends hand-written reports, none the recorded sequence; seam=testdata/program-status/mock-claude-code.sh
    #[test]
    fn the_recorded_claude_code_sequence_blocks_then_finishes() {
        let mock = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../testdata/program-status/mock-claude-code.sh");
        let store = SessionStore::new();
        start(
            &store,
            id(1),
            &format!(
                "MOCK_STEP=1 MOCK_ALERT_DELAY=0.2 sh '{}' --auto; sleep 10",
                mock.display()
            ),
        );

        let blocked = wait_until(|| status_of(&store, id(1)), |s| states(s) == ["blocked"]);
        let record = &blocked["records"][0];
        assert_eq!(
            (&record["state"], &record["kind"], &record["app"]),
            (
                &json!("blocked"),
                &json!("permission"),
                &json!("claude-code")
            ),
            "no request from the mock: did the agent answer its probe? {blocked}"
        );
        assert_eq!(record["message"], "approve Fetch: https://example.com");
        assert_eq!(record["notify"], true, "it asked first, so it may notify");

        let done = wait_until(|| status_of(&store, id(1)), |s| states(s) == ["done"]);
        assert_eq!(states(&done), ["done"], "the finished turn: {done}");

        let exited = wait_until(|| status_of(&store, id(1)), |s| states(s).is_empty());
        assert_eq!(exited["records"], json!([]), "Claude clears on exit");
        store.kill_all();
    }
}
