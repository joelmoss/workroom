//! Run sessions (#522): a project's run command in a daemon session of its own, under the run
//! supervisor, so it survives the app quitting and runs the same way on this Mac and on a host.
//!
//! A real daemon and real attach clients over a real socket, as `attach_survives_detach` uses, with
//! `/bin/sh` commands standing in for a dev server.

#[allow(dead_code)] // not every helper is used here
mod common;

use std::path::{Path, PathBuf};
use std::time::Duration;

use common::{ClientReader, Workspace, attach_with_env, start_daemon, wait_for};
use wr_protocol::frame::{Frame, FrameKind, RunSignal};

const SESSION: &str = "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11";

/// Where the daemon keeps a run session's status: beside its socket, by session id.
fn status_path(socket: &Path, session: &str) -> PathBuf {
    socket
        .with_extension("runs")
        .join(format!("{session}.status"))
}

fn read_status(socket: &Path, session: &str) -> String {
    std::fs::read_to_string(status_path(socket, session))
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn session_bytes(session: &str) -> Vec<u8> {
    let hex: String = session.chars().filter(|c| *c != '-').collect();
    (0..16)
        .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap())
        .collect()
}

/// Asks the daemon to signal `session`'s supervisor, returning its reply.
fn signal(socket: &Path, session: &str, signal: RunSignal) -> Frame {
    let mut payload = session_bytes(session);
    payload.push(signal as u8);
    common::control(socket, Frame::new(FrameKind::Signal, payload))
}

fn start_run(socket: &Path, session: &str, command: &str) -> (common::Spawned, ClientReader) {
    let mut client = attach_with_env(
        socket,
        session,
        &[],
        &[
            ("WORKROOM_SESSION_RUN", "1"),
            ("WORKROOM_SESSION_COMMAND", command),
        ],
    );
    let reader = ClientReader::new(&mut client);
    (client, reader)
}

fn running(socket: &Path, session: &str) -> bool {
    read_status(socket, session).starts_with("running ")
}
/// Stop parks the run with its pane kept, and restart runs the command again in the same session:
/// the #7 controls, now asked of the daemon rather than signalled by the app itself.
#[test]
fn stop_parks_the_run_and_restart_runs_it_again() {
    let workspace = Workspace::new("run-stop-restart");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let (_client, mut reader) = start_run(&socket, SESSION, "echo up; sleep 30");
    assert!(wait_for(Duration::from_secs(10), || running(
        &socket, SESSION
    )));

    assert_eq!(
        signal(&socket, SESSION, RunSignal::Stop).kind,
        FrameKind::Acknowledged
    );
    assert!(
        wait_for(Duration::from_secs(10), || read_status(&socket, SESSION)
            == "stopped 1"),
        "status was {:?}",
        read_status(&socket, SESSION)
    );
    reader.read_until("Process exited", Duration::from_secs(5));

    assert_eq!(
        signal(&socket, SESSION, RunSignal::Restart).kind,
        FrameKind::Acknowledged
    );
    assert!(
        wait_for(Duration::from_secs(10), || running(&socket, SESSION)),
        "status was {:?}",
        read_status(&socket, SESSION)
    );
    assert!(
        common::list_sessions(&socket).contains(SESSION),
        "the same session"
    );
}

/// Quit stops the command first, then ends the session: nothing is left on the port.
#[test]
fn quit_stops_the_command_and_ends_the_session() {
    let workspace = Workspace::new("run-quit");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let (_client, _reader) = start_run(&socket, SESSION, "sleep 30");
    assert!(wait_for(Duration::from_secs(10), || running(
        &socket, SESSION
    )));
    let child: i32 = read_status(&socket, SESSION)
        .trim_start_matches("running ")
        .parse()
        .unwrap();

    assert_eq!(
        signal(&socket, SESSION, RunSignal::Quit).kind,
        FrameKind::Acknowledged
    );
    assert!(
        wait_for(Duration::from_secs(10), || !common::list_sessions(&socket)
            .contains(SESSION)),
        "the session ended"
    );
    assert!(wait_for(Duration::from_secs(5), || !alive(child)));
}

/// Only a run session's supervisor can be signalled, and only with the run's own controls: a shell
/// is never sent USR1, and an id the daemon does not hold is said to be gone, which the app reads
/// as the run having ended rather than as a failure to reach it.
#[test]
fn a_signal_is_refused_for_anything_but_a_run_session() {
    let workspace = Workspace::new("run-signal-refused");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);

    let absent = signal(&socket, SESSION, RunSignal::Stop);
    assert_eq!(absent.kind, FrameKind::Failure);
    assert!(absent.payload.starts_with(b"no session "), "{absent:?}");

    let shell = "6b2f1a8f-1e7d-4dad-8d4f-3c8e2e1b9f22";
    let _client = common::attach(&socket, shell);
    assert!(wait_for(Duration::from_secs(10), || common::list_sessions(
        &socket
    )
    .contains(shell)));
    let refused = signal(&socket, shell, RunSignal::Stop);
    assert_eq!(refused.kind, FrameKind::Failure);
    assert!(
        refused.payload.starts_with(b"not a run session"),
        "{refused:?}"
    );

    let mut unknown = session_bytes(shell);
    unknown.push(9);
    let bad = common::control(&socket, Frame::new(FrameKind::Signal, unknown));
    assert_eq!(bad.kind, FrameKind::Failure);
}

/// A subscription to the daemon's program status over its socket, as the app holds one.
struct StatusClient {
    stream: std::os::unix::net::UnixStream,
    decoder: wr_protocol::envelope::EnvelopeDecoder,
}

impl StatusClient {
    fn subscribe(socket: &Path) -> StatusClient {
        use std::io::{Read, Write};
        use wr_protocol::envelope::{Envelope, EnvelopeDecoder, Hello, Service};
        let mut stream = std::os::unix::net::UnixStream::connect(socket).expect("connect");
        stream.write_all(&Hello::current("test").encode()).unwrap();
        let mut greeting = Vec::new();
        while Hello::decode(&greeting).unwrap().is_none() {
            let mut byte = [0u8];
            stream.read_exact(&mut byte).unwrap();
            greeting.push(byte[0]);
        }
        stream
            .set_read_timeout(Some(Duration::from_millis(50)))
            .unwrap();
        let request = serde_json::json!({"version": 1, "method": "subscribe"});
        stream
            .write_all(
                &Envelope::new(
                    Service::ProgramStatus,
                    1,
                    serde_json::to_vec(&request).unwrap(),
                )
                .encode(),
            )
            .unwrap();
        StatusClient {
            stream,
            decoder: EnvelopeDecoder::new(),
        }
    }

    /// Events (and the subscribe reply) until one satisfies `done`, or `None` after `timeout`.
    fn until(
        &mut self,
        timeout: Duration,
        done: impl Fn(&serde_json::Value) -> bool,
    ) -> Option<serde_json::Value> {
        use std::io::Read;
        let deadline = std::time::Instant::now() + timeout;
        loop {
            while let Some(envelope) = self.decoder.next_envelope().unwrap() {
                let body: serde_json::Value =
                    serde_json::from_slice(&envelope.payload[1..]).unwrap();
                if done(&body) {
                    return Some(body);
                }
            }
            if std::time::Instant::now() >= deadline {
                return None;
            }
            let mut bytes = [0u8; 65536];
            match self.stream.read(&mut bytes) {
                Ok(0) => return None,
                Ok(n) => self.decoder.push(&bytes[..n]),
                Err(_) => {}
            }
        }
    }
}

fn run_of(event: &serde_json::Value, session: &str) -> Option<String> {
    (event["event"] == "status" && event["session"] == session)
        .then(|| event["run"].as_str().map(str::to_string))
        .flatten()
}

/// What the supervisor writes reaches every subscribed app with the session's program status, in
/// the snapshot a subscription starts with and live after it: an app that was closed when a run
/// failed learns how it ended when it subscribes again.
#[test]
fn a_runs_state_is_published_with_its_program_status() {
    if !common::has_terminal_state() {
        return;
    }
    let workspace = Workspace::new("run-status-published");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let (_client, _reader) = start_run(&socket, SESSION, "exit 3");
    assert!(wait_for(Duration::from_secs(10), || read_status(
        &socket, SESSION
    ) == "exited 3 1"));

    let mut app = StatusClient::subscribe(&socket);
    let snapshot = app.until(Duration::from_secs(10), |event| {
        run_of(event, SESSION).as_deref() == Some("exited 3 1")
    });
    assert!(
        snapshot.is_some(),
        "a subscription is told how the run ended"
    );

    let other = "7c3a2b9f-2f8e-4ebe-9e5a-4d9f3f2c0a33";
    let (_second, _second_reader) = start_run(&socket, other, "sleep 30");
    assert!(
        app.until(Duration::from_secs(10), |event| run_of(event, other)
            .is_some_and(|run| run.starts_with("running ")))
            .is_some(),
        "a live change is published"
    );
    assert_eq!(
        signal(&socket, other, RunSignal::Quit).kind,
        FrameKind::Acknowledged
    );
    assert!(
        app.until(Duration::from_secs(10), |event| event["event"] == "ended"
            && event["session"] == other)
            .is_some()
    );
    assert!(
        wait_for(Duration::from_secs(5), || !status_path(&socket, other)
            .exists()),
        "an ended run's status goes with it"
    );
}

/// A restart whose command fails again at once, the same way, still reaches the app: its run is
/// over before the daemon looks in on it, so only the launch the supervisor numbers its outcome
/// with tells the second failure from the first, and without it the tab says "Restarting…" for good.
#[test]
fn a_restart_that_fails_the_same_way_is_published_again() {
    if !common::has_terminal_state() {
        return;
    }
    let workspace = Workspace::new("run-refail");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let (_client, _reader) = start_run(&socket, SESSION, "exit 3");
    let mut app = StatusClient::subscribe(&socket);
    assert!(
        app.until(Duration::from_secs(10), |event| run_of(event, SESSION)
            .as_deref()
            == Some("exited 3 1"))
            .is_some(),
        "the first failure is published"
    );

    assert_eq!(
        signal(&socket, SESSION, RunSignal::Restart).kind,
        FrameKind::Acknowledged
    );
    assert!(
        app.until(Duration::from_secs(10), |event| run_of(event, SESSION)
            .as_deref()
            == Some("exited 3 2"))
            .is_some(),
        "the second failure is published"
    );
}

/// An update hands the daemon off to its new program: the run keeps going, its state is still
/// published, and its supervisor still answers stop and restart. Q6: a run survives an update.
#[test]
fn a_run_survives_a_hand_off_and_can_still_be_controlled() {
    if !common::has_terminal_state() {
        return;
    }
    let workspace = Workspace::new("run-hand-off");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let (_client, _reader) = start_run(&socket, SESSION, "sleep 30");
    assert!(wait_for(Duration::from_secs(10), || running(
        &socket, SESSION
    )));
    assert_eq!(
        signal(&socket, SESSION, RunSignal::Stop).kind,
        FrameKind::Acknowledged
    );
    assert!(wait_for(Duration::from_secs(10), || read_status(
        &socket, SESSION
    ) == "stopped 1"));

    let output = std::process::Command::new(common::daemon_binary())
        .args(["hand-off", "--socket"])
        .arg(&socket)
        .arg("--binary")
        .arg(common::daemon_binary())
        .arg("--force")
        .output()
        .expect("hand-off");
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "handed off");

    let mut app = StatusClient::subscribe(&socket);
    assert!(
        app.until(Duration::from_secs(10), |event| run_of(event, SESSION)
            .as_deref()
            == Some("stopped 1"))
            .is_some(),
        "the stopped run is still published after the hand-off"
    );
    assert_eq!(
        signal(&socket, SESSION, RunSignal::Restart).kind,
        FrameKind::Acknowledged
    );
    assert!(
        app.until(Duration::from_secs(10), |event| run_of(event, SESSION)
            .is_some_and(|run| run.starts_with("running ")))
            .is_some(),
        "the new program publishes the restart"
    );
}

/// A restored run tab whose session ended while the app was closed (a reboot, a daemon that died)
/// says so and starts nothing: a shell's restored pane gets a new session (#459), but a run's would
/// start the dev server unasked (D2).
#[test]
fn a_restored_run_whose_session_is_gone_is_never_started_again() {
    let workspace = Workspace::new("run-restored-gone");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);

    let mut client = attach_with_env(
        &socket,
        SESSION,
        &["--no-create"],
        &[
            ("WORKROOM_SESSION_RUN", "1"),
            ("WORKROOM_SESSION_COMMAND", "echo SHOULD-NOT-RUN"),
        ],
    );
    let mut reader = ClientReader::new(&mut client);
    let seen = reader
        .read_until("ended", Duration::from_secs(10))
        .to_string();
    reader.drain(Duration::from_millis(500));
    assert!(
        seen.contains("ended"),
        "the pane says the run ended: {seen:?}"
    );
    assert!(
        !reader
            .read_until("SHOULD-NOT-RUN", Duration::ZERO)
            .contains("SHOULD-NOT-RUN")
    );
    assert!(
        !common::list_sessions(&socket).contains(SESSION),
        "no session was made"
    );
}

/// A run never runs outside a daemon session: when no daemon can take it, the relay says why and
/// runs nothing, where a shell's would become a plain shell (D5).
#[test]
fn a_run_with_no_daemon_to_take_it_runs_nothing() {
    let workspace = Workspace::new("run-no-daemon");
    let socket = workspace.socket();

    let mut client = attach_with_env(
        &socket,
        SESSION,
        &["--no-spawn"],
        &[
            ("WORKROOM_SESSION_RUN", "1"),
            ("WORKROOM_SESSION_COMMAND", "echo SHOULD-NOT-RUN"),
        ],
    );
    let status = client.wait().expect("wait");
    let mut stdout = String::new();
    let mut stderr = String::new();
    use std::io::Read;
    client
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut stdout)
        .unwrap();
    client
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut stderr)
        .unwrap();
    assert!(!stdout.contains("SHOULD-NOT-RUN"), "{stdout:?}");
    assert!(
        !status.success(),
        "the relay reports it could not start the run"
    );
    assert!(stderr.contains("run"), "{stderr:?}");
}

/// A daemon older than run sessions (a hand-off that was refused, here or on a host) is never asked
/// to run one: it would run the command bare, with no supervisor to stop or restart it (D4).
#[test]
fn a_run_is_never_sent_to_a_daemon_older_than_run_sessions() {
    use std::io::{Read, Write};
    use std::os::unix::net::UnixListener;
    use wr_protocol::envelope::Hello;

    let workspace = Workspace::new("run-old-daemon");
    let socket = workspace.socket();
    let listener = UnixListener::bind(&socket).expect("bind fake daemon");
    let fake = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let hello = Hello {
            protocol_version: wr_protocol::envelope::MIN_RUN_VERSION - 1,
            build: "old".into(),
        };
        stream.write_all(&hello.encode()).expect("greet");
        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
        let mut received = Vec::new();
        let mut chunk = [0u8; 4096];
        while let Ok(read) = stream.read(&mut chunk) {
            if read == 0 {
                break;
            }
            received.extend_from_slice(&chunk[..read]);
        }
        let (_, consumed) = Hello::decode(&received)
            .expect("a greeting")
            .expect("a whole greeting");
        received.len() - consumed
    });

    // `--no-spawn`, so a relay that wrongly talks to the old daemon fails here rather than starting
    // a daemon of its own once the fake one has gone, and running the command in it.
    let mut client = attach_with_env(
        &socket,
        SESSION,
        &["--no-spawn"],
        &[
            ("WORKROOM_SESSION_RUN", "1"),
            ("WORKROOM_SESSION_COMMAND", "echo SHOULD-NOT-RUN"),
        ],
    );
    let status = client.wait().expect("wait");
    let mut stderr = String::new();
    client
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut stderr)
        .unwrap();
    assert_eq!(
        fake.join().unwrap(),
        0,
        "nothing was asked of the old daemon"
    );
    assert!(
        !status.success(),
        "the relay reports it could not start the run"
    );
    assert!(stderr.contains("older"), "{stderr:?}");
}

/// A `bin/dev`-style launcher forks its server into a process group of its own, which the
/// supervisor's group-wide Ctrl-C never reaches. When the run ends, whatever it left in the session
/// is ended too, so nothing outlives it on its port (R8; the app swept the session itself before).
#[test]
fn nothing_the_run_started_outlives_it() {
    // `set -m` gives the background job a process group of its own; it ignores INT and HUP, as a
    // server that only stops when told by its launcher does.
    let command = "set -m; (trap '' INT HUP; exec sleep 300) & echo leaf=$!; wait";
    leaves_nothing_behind("run-sweep", command, |socket| {
        assert_eq!(
            signal(socket, SESSION, RunSignal::Quit).kind,
            FrameKind::Acknowledged
        );
    });
}

/// The same when the session is killed, as closing a run tab finally does, and after the launcher
/// itself has exited: its server is then no process's descendant, only a member of the session.
#[test]
fn nothing_the_run_started_outlives_a_kill() {
    let command = "set -m; (trap '' INT HUP TERM; exec sleep 300) & echo leaf=$!";
    leaves_nothing_behind("run-sweep-kill", command, |socket| {
        assert!(wait_for(Duration::from_secs(10), || read_status(
            socket, SESSION
        ) == "exited 0 1"));
        let mut payload = session_bytes(SESSION);
        payload.truncate(16);
        let reply = common::control(socket, Frame::new(FrameKind::Kill, payload));
        assert_eq!(reply.kind, FrameKind::Acknowledged);
    });
}

fn leaves_nothing_behind(name: &str, command: &str, end: impl FnOnce(&Path)) {
    let workspace = Workspace::new(name);
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);
    let (_client, mut reader) = start_run(&socket, SESSION, command);
    let seen = reader
        .read_until("leaf=", Duration::from_secs(10))
        .to_string();
    reader.drain(Duration::from_millis(300));
    let leaf: i32 = reader
        .read_until("\n", Duration::ZERO)
        .split("leaf=")
        .nth(1)
        .and_then(|rest| rest.split_whitespace().next())
        .and_then(|pid| pid.parse().ok())
        .unwrap_or_else(|| panic!("no leaf pid in {seen:?}"));
    assert!(alive(leaf), "the leaf is running");

    end(&socket);
    assert!(
        wait_for(Duration::from_secs(15), || !alive(leaf)),
        "the leaf outlived its run"
    );
}

fn alive(pid: i32) -> bool {
    // SAFETY: `kill` takes no pointers, and signal 0 delivers nothing.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// A run command that ends on its own parks with how it ended, and its pane stays: the supervisor
/// keeps running, so the app can show the outcome and restart it in place.
#[test]
fn a_run_that_exits_parks_with_its_exit_code() {
    let workspace = Workspace::new("run-exits");
    let socket = workspace.socket();
    let _daemon = start_daemon(&socket);

    let mut client = attach_with_env(
        &socket,
        SESSION,
        &[],
        &[
            ("WORKROOM_SESSION_RUN", "1"),
            ("WORKROOM_SESSION_COMMAND", "echo run-started; exit 3"),
        ],
    );
    let mut reader = ClientReader::new(&mut client);
    let seen = reader.read_until("Process exited", Duration::from_secs(10));
    assert!(seen.contains("run-started"), "the command ran: {seen:?}");
    assert!(seen.contains("Process exited"), "the pane parks: {seen:?}");
    assert!(
        wait_for(Duration::from_secs(5), || read_status(&socket, SESSION)
            == "exited 3 1"),
        "status was {:?}",
        read_status(&socket, SESSION)
    );
    // Parked, not gone: the supervisor holds the session open for a restart.
    assert!(common::list_sessions(&socket).contains(SESSION));
}
