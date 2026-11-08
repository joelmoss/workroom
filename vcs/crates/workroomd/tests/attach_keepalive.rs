//! Keepalive on a remote pane's attach (#593), through the real connection handler: a client that
//! asked to be probed and stops answering stops counting as attached, one that answers stays, and
//! one that never asked (an older app) is never probed.
//!
//! The ticker runs at `INTERVAL` here, not 15 s, through `SessionStore::with_keepalive_interval`.
//! Probes go out only at ground, which needs the shadow terminal: the probed tests return early
//! without it, as the repaint tests do.

#[allow(dead_code)] // not every helper is used here
mod common;
use common::{RpcClient, has_terminal_state, wait_for};

use std::time::{Duration, Instant};

use workroomd::testing::{KEEPALIVE_PROBE, KEEPALIVE_VARIABLE, SessionId, SessionStore};
use wr_protocol::envelope::Service;
use wr_protocol::frame::{Frame, FrameKind};
use wr_protocol::terminal::AttachRequest;

const INTERVAL: Duration = Duration::from_millis(100);

/// What the pane's terminal answers the probe with.
const ANSWER: &[u8] = b"\x1b[?25930;0$y";

fn attach(store: &SessionStore, session: [u8; 16], keepalive: bool) -> RpcClient {
    let (mut client, _server) =
        RpcClient::connect_to("keepalive-test", store.clone(), Duration::from_millis(20));
    let mut env = vec![("PATH".into(), "/usr/bin:/bin".into())];
    if keepalive {
        env.push((KEEPALIVE_VARIABLE.into(), "1".into()));
    }
    let request = AttachRequest {
        id: Some(SessionId(session)),
        shell: Some("/bin/sh".into()),
        columns: 80,
        rows: 24,
        env,
        ..Default::default()
    };
    client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Attach, request.encode()),
    );
    client
}

fn attached(store: &SessionStore, session: [u8; 16]) -> bool {
    store
        .list()
        .iter()
        .find(|info| info.id == SessionId(session))
        .is_some_and(|info| info.attached)
}

fn probes(client: &RpcClient) -> usize {
    client
        .seen
        .windows(KEEPALIVE_PROBE.len())
        .filter(|window| *window == KEEPALIVE_PROBE)
        .count()
}

fn input(client: &mut RpcClient, bytes: &[u8]) {
    client.send(
        Service::Terminal,
        1,
        Frame::new(FrameKind::Input, bytes.to_vec()),
    );
}

/// The Mac holding the pane went to sleep: its relay is still connected, but nothing answers.
/// Within a few intervals the session reads detached, so another Mac's list shows it. The client
/// is not cut off, though: its first answer brings it back, and output still reaches it.
#[test]
fn a_probed_client_that_stops_answering_stops_counting_as_attached() {
    if !has_terminal_state() {
        return;
    }
    let store = SessionStore::with_keepalive_interval(INTERVAL);
    let session = [0x59; 16];
    let mut client = attach(&store, session, true);
    let probed = wait_for_probe(&mut client, 1);
    assert!(probed, "no probe arrived; got {:?}", client.seen);
    assert!(attached(&store, session), "detached before it missed any");

    let stale = wait_for(Duration::from_secs(5), || {
        client.pump(Instant::now() + Duration::from_millis(20));
        !attached(&store, session)
    });
    assert!(
        stale,
        "a client that never answered still counts as attached"
    );
    assert!(!client.closed, "the stale client was cut off");

    input(&mut client, ANSWER);
    let back = wait_for(Duration::from_secs(5), || attached(&store, session));
    assert!(back, "its answer did not bring it back");
    input(&mut client, b"echo STILL-HERE\n");
    let seen = client.read_until("STILL-HERE", Duration::from_secs(5));
    assert!(seen.contains("STILL-HERE"), "output stopped; got {seen:?}");
    store.kill_all();
}

/// An idle pane whose terminal answers every probe stays attached however long nobody types, and
/// the answers never reach the shell: with the pty echoing, one that did would show on screen.
#[test]
fn a_probed_client_that_answers_stays_attached_without_typing() {
    if !has_terminal_state() {
        return;
    }
    let store = SessionStore::with_keepalive_interval(INTERVAL);
    let session = [0x5A; 16];
    let mut client = attach(&store, session, true);
    let mut answered = 0;
    let until = Instant::now() + INTERVAL * 12;
    while Instant::now() < until {
        client.pump(Instant::now() + Duration::from_millis(5));
        while answered < probes(&client) {
            input(&mut client, ANSWER);
            answered += 1;
        }
        if answered > 0 {
            assert!(
                attached(&store, session),
                "detached after {answered} answers"
            );
        }
    }
    assert!(answered >= 4, "only {answered} probes in 12 intervals");
    input(&mut client, b"echo DONE\n");
    let seen = client.read_until("DONE", Duration::from_secs(5));
    assert!(seen.contains("DONE"), "got {seen:?}");
    assert!(
        !seen.contains("25930;"),
        "an answer reached the shell: {seen:?}"
    );
    store.kill_all();
}

/// A client that never asked, as an older app's, is never probed and never goes stale, whether or
/// not the daemon has the shadow terminal.
#[test]
fn a_client_that_did_not_ask_is_never_probed_or_stale() {
    let store = SessionStore::with_keepalive_interval(INTERVAL);
    let session = [0x5B; 16];
    let mut client = attach(&store, session, false);
    let started = wait_for(Duration::from_secs(5), || attached(&store, session));
    assert!(started, "the session never attached");
    let until = Instant::now() + INTERVAL * (3 + 4);
    while Instant::now() < until {
        client.pump(Instant::now() + Duration::from_millis(20));
        assert!(
            attached(&store, session),
            "a client that never asked went stale"
        );
    }
    assert_eq!(probes(&client), 0, "probed without asking");
    store.kill_all();
}

fn wait_for_probe(client: &mut RpcClient, count: usize) -> bool {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if probes(client) >= count {
            return true;
        }
        client.pump(Instant::now() + Duration::from_millis(20));
    }
    false
}
