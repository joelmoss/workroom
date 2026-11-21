use super::*;

fn id(byte: u8) -> SessionId {
    SessionId([byte; 16])
}

fn listing(byte: u8, workroom: &str) -> Value {
    json!({
        "id": id(byte).to_hyphenated(),
        "label": "server",
        "title": null,
        "scope": {"kind": "workroom", "id": workroom},
        "run": false,
        "cwd": "/tmp",
        "coding_agent": null,
    })
}

fn agent(state: &str, message: &str) -> Value {
    json!({"state": state, "app": "claude", "message": message, "waiting_on_user": state == "blocked"})
}

/// What a subscriber at `cursor` is sent next, which must not block: something is waiting.
fn next(hub: &Hub, cursor: &mut Cursor) -> Next {
    hub.next(cursor, &|| false)
}

fn events(next: Next) -> Vec<Value> {
    match next {
        Next::Events(events) => events.iter().map(|event| event.json.clone()).collect(),
        other => panic!("not events: {other:?}"),
    }
}

fn names(events: &[Value]) -> Vec<&str> {
    events
        .iter()
        .map(|event| event["event"].as_str().unwrap())
        .collect()
}

#[test]
fn a_snapshot_is_the_state_its_revision_gives_and_the_events_after_it_follow() {
    let hub = Hub::default();
    hub.created(id(1), listing(1, "wr-1"));
    hub.program_status(id(1), agent("working", "a"));
    let mut cursor = Cursor::new(Start::Fresh);
    let Next::Snapshot {
        revision,
        sessions,
        reason,
        boot,
    } = next(&hub, &mut cursor)
    else {
        panic!("no snapshot first");
    };
    assert_eq!((revision, reason), (2, Reason::Subscribed));
    assert_eq!(boot, hub.boot().to_hyphenated());
    assert_eq!(sessions[&id(1)].coding_agent, agent("working", "a"));

    hub.program_status(id(1), agent("blocked", "Allow?"));
    hub.ended(id(1), Some(3));
    let live = events(next(&hub, &mut cursor));
    assert_eq!(
        names(&live),
        [name::PROGRAM_STATUS, name::ENDED],
        "{live:?}"
    );
    assert_eq!(live[0]["revision"], 3);
    assert_eq!(live[0]["coding_agent"], agent("blocked", "Allow?"));
    assert_eq!(live[1]["revision"], 4);
    assert_eq!(live[1]["exit_code"], 3);
    assert_eq!(live[1]["scope"], json!({"kind": "workroom", "id": "wr-1"}));
    assert_eq!(live[1]["boot"], json!(hub.boot().to_hyphenated()));
}

/// A working agent's message alone is not news; its state, and a message while it waits, are.
#[test]
fn only_news_of_a_coding_agent_is_an_event() {
    let hub = Hub::default();
    hub.created(id(1), listing(1, "wr-1"));
    let mut cursor = Cursor::new(Start::Since {
        boot: hub.boot().to_hyphenated(),
        revision: 1,
    });
    assert!(matches!(
        next(&hub, &mut cursor),
        Next::Resumed { revision: 1, .. }
    ));
    for message in ["t", "to", "tok", "toke"] {
        hub.program_status(id(1), agent("working", message));
    }
    hub.program_status(id(1), agent("blocked", "Allow?"));
    hub.program_status(id(1), agent("blocked", "Which file?"));
    hub.program_status(id(1), Value::Null);
    let live = events(next(&hub, &mut cursor));
    let said: Vec<Value> = live
        .iter()
        .map(|event| event["coding_agent"].clone())
        .collect();
    assert_eq!(
        said,
        [
            agent("working", "t"),
            agent("blocked", "Allow?"),
            agent("blocked", "Which file?"),
            Value::Null
        ]
    );
    // The snapshot has the latest message even so.
    hub.created(id(2), listing(2, "wr-1"));
    hub.program_status(id(2), agent("working", "a"));
    hub.program_status(id(2), agent("working", "ab"));
    let Next::Snapshot { sessions, .. } = next(&hub, &mut Cursor::new(Start::Fresh)) else {
        panic!("no snapshot");
    };
    assert_eq!(sessions[&id(2)].coding_agent, agent("working", "ab"));
}

/// A session tagged with another scope is `session.moved`, saying both, once; its later events and
/// its snapshots carry the new one. A tag it already has is no event.
#[test]
fn a_session_tagged_with_another_scope_is_moved() {
    let hub = Hub::default();
    hub.created(id(1), listing(1, "wr-1"));
    let mut cursor = Cursor::new(Start::Since {
        boot: hub.boot().to_hyphenated(),
        revision: 1,
    });
    let _ = next(&hub, &mut cursor);
    let to = json!({"kind": "workroom", "id": "wr-2"});
    hub.rescoped(id(1), to.clone());
    hub.rescoped(id(1), to.clone());
    hub.ended(id(1), Some(0));
    let live = events(next(&hub, &mut cursor));
    assert_eq!(names(&live), [name::MOVED, name::ENDED], "{live:?}");
    assert_eq!(live[0]["scope"], to);
    assert_eq!(
        live[0]["previous_scope"],
        json!({"kind": "workroom", "id": "wr-1"})
    );
    assert_eq!(live[1]["scope"], to, "its end is in the new scope");
}

/// A logged run is told each transition once, by number, and never again from its status file; a
/// run with no log is told its file's changes.
#[test]
fn a_run_state_is_told_once_from_its_log_or_from_its_file_without_one() {
    let hub = Hub::default();
    hub.created(id(1), listing(1, "wr-1"));
    hub.created(id(2), listing(2, "wr-1"));
    let mut cursor = Cursor::new(Start::Since {
        boot: hub.boot().to_hyphenated(),
        revision: 2,
    });
    let _ = next(&hub, &mut cursor);
    hub.run(id(1), "starting", Some(1));
    hub.run(id(1), "starting", None);
    hub.run(id(1), "running 42", Some(2));
    hub.run(id(1), "running 42", Some(2));
    hub.run(id(1), "stopping", Some(3));
    hub.run(id(1), "starting", Some(4));
    hub.run(id(1), "exited 1 3", Some(5));
    hub.run(id(1), "exited 1 3", None);
    hub.run(id(2), "running 7", None);
    hub.run(id(2), "running 7", None);
    hub.run(id(2), "exited 0 1", None);
    hub.run(id(2), "not a state", None);
    let live = events(next(&hub, &mut cursor));
    let said: Vec<(String, Value, Value)> = live
        .iter()
        .map(|event| {
            (
                event["session"].as_str().unwrap()[..2].to_string(),
                event["run_state"].clone(),
                event["exit_code"].clone(),
            )
        })
        .collect();
    let one = |state: &str, code: Value| ("01".to_string(), json!(state), code);
    let two = |state: &str, code: Value| ("02".to_string(), json!(state), code);
    assert_eq!(
        said,
        [
            one("starting", Value::Null),
            one("running", Value::Null),
            one("stopping", Value::Null),
            one("starting", Value::Null),
            one("exited", json!(1)),
            two("running", Value::Null),
            two("exited", json!(0)),
        ]
    );
    assert_eq!(hub.lock().sessions[&id(1)].run_seq, Some(5));
}

/// A run a hand-off adopted is told the transitions its log gained after the old program last
/// told one, when the events were carried; with none carried, it takes the log's last untold.
#[test]
fn an_adopted_run_is_told_what_its_log_gained_during_the_hand_off() {
    let log: Vec<(u64, String)> = [(1, "starting"), (2, "running 9"), (3, "stopping")]
        .into_iter()
        .map(|(seq, line)| (seq, line.to_string()))
        .collect();
    let old = Hub::default();
    old.created(id(1), listing(1, "wr-1"));
    for (seq, line) in &log[..2] {
        old.run(id(1), line, Some(*seq));
    }
    let carried = Hub::default();
    assert!(carried.adopt(&old.carry()));
    carried.adopted_run(id(1), &log);
    let mut cursor = Cursor::new(Start::Since {
        boot: old.boot().to_hyphenated(),
        revision: 3,
    });
    let _ = next(&carried, &mut cursor);
    let told = events(next(&carried, &mut cursor));
    assert_eq!(names(&told), [name::RUN_STATE]);
    assert_eq!(told[0]["run_state"], "stopping");

    let fresh = Hub::default();
    fresh.reconcile(vec![(id(1), listing(1, "wr-1"))], false);
    fresh.adopted_run(id(1), &log);
    let Next::Snapshot {
        revision, sessions, ..
    } = next(&fresh, &mut Cursor::new(Start::Fresh))
    else {
        panic!("no snapshot");
    };
    assert_eq!(revision, 0, "nothing told");
    assert_eq!(sessions[&id(1)].run_state.as_deref(), Some("stopping"));
}

#[test]
fn a_resume_from_a_place_the_ring_no_longer_holds_or_another_boot_is_a_gap() {
    let hub = Hub::default();
    hub.created(id(1), listing(1, "wr-1"));
    let boot = hub.boot().to_hyphenated();
    for n in 0..RING + 5 {
        hub.program_status(id(1), agent(if n % 2 == 0 { "idle" } else { "done" }, ""));
    }
    let latest = (RING + 6) as u64;
    for (since, gap) in [
        (0, true),
        (latest - RING as u64 - 1, true),
        (latest - RING as u64, false),
        (latest, false),
        (latest + 1, true),
        (u64::MAX, true),
    ] {
        let mut cursor = Cursor::new(Start::Since {
            boot: boot.clone(),
            revision: since,
        });
        match next(&hub, &mut cursor) {
            Next::Snapshot {
                reason, revision, ..
            } => {
                assert!(gap, "{since} is in the ring");
                assert_eq!((reason, revision), (Reason::Gap, latest));
            }
            Next::Resumed { revision, .. } => {
                assert!(!gap, "{since} is not in the ring");
                assert_eq!(revision, since);
            }
            other => panic!("{since}: {other:?}"),
        }
    }
    let mut elsewhere = Cursor::new(Start::Since {
        boot: SessionId([9; 16]).to_hyphenated(),
        revision: latest,
    });
    assert!(matches!(
        next(&hub, &mut elsewhere),
        Next::Snapshot {
            reason: Reason::Gap,
            ..
        }
    ));
}

/// A subscriber that falls past the ring's start is sent the state as it is now, and goes on from
/// there; none in between is sent half.
#[test]
fn a_subscriber_that_falls_behind_the_ring_is_sent_the_state_afresh() {
    let hub = Hub::default();
    hub.created(id(1), listing(1, "wr-1"));
    let mut cursor = Cursor::new(Start::Fresh);
    let _ = next(&hub, &mut cursor);
    for n in 0..=RING {
        hub.program_status(id(1), agent(if n % 2 == 0 { "idle" } else { "done" }, ""));
    }
    let Next::Snapshot {
        reason, revision, ..
    } = next(&hub, &mut cursor)
    else {
        panic!("no snapshot");
    };
    assert_eq!((reason, revision), (Reason::Lagged, RING as u64 + 2));
    hub.ended(id(1), None);
    let live = events(next(&hub, &mut cursor));
    assert_eq!(live[0]["revision"], RING as u64 + 3);

    // Behind while a hand-off has the ring sealed: it waits for the seal, and is sent the state
    // afresh once it is lifted.
    hub.created(id(1), listing(1, "wr-1"));
    let _ = hub.carry();
    for n in 0..=RING {
        hub.program_status(id(1), agent(if n % 2 == 0 { "idle" } else { "done" }, ""));
    }
    let closed = std::sync::atomic::AtomicBool::new(false);
    std::thread::scope(|scope| {
        let waiting = scope.spawn(|| {
            hub.next(&mut cursor, &|| {
                closed.load(std::sync::atomic::Ordering::SeqCst)
            })
        });
        std::thread::sleep(std::time::Duration::from_millis(50));
        closed.store(true, std::sync::atomic::Ordering::SeqCst);
        hub.wake();
        assert_eq!(
            waiting.join().unwrap(),
            Next::Closed,
            "nothing while sealed"
        );
    });
    hub.unseal();
    assert!(matches!(
        next(&hub, &mut cursor),
        Next::Snapshot {
            reason: Reason::Lagged,
            ..
        }
    ));
}

/// What a hand-off carries numbers on in the next program, which tells what changed while it was
/// under way; nothing the old one numbered after carrying it is sent, and if the hand-off is
/// called off, it is.
#[test]
fn a_carried_hub_numbers_on_and_tells_what_the_hand_off_missed() {
    let old = Hub::default();
    old.created(id(1), listing(1, "wr-1"));
    old.created(id(2), listing(2, "wr-1"));
    let mut cursor = Cursor::new(Start::Fresh);
    let _ = next(&old, &mut cursor);
    let carried = old.carry();
    // Numbered after the seal: held back.
    old.program_status(id(1), agent("working", "a"));
    let closed = std::sync::atomic::AtomicBool::new(false);
    std::thread::scope(|scope| {
        let waiting = scope.spawn(|| {
            old.next(&mut cursor, &|| {
                closed.load(std::sync::atomic::Ordering::SeqCst)
            })
        });
        std::thread::sleep(std::time::Duration::from_millis(50));
        closed.store(true, std::sync::atomic::Ordering::SeqCst);
        old.wake();
        assert_eq!(waiting.join().unwrap(), Next::Closed);
    });

    let new = Hub::default();
    assert!(new.adopt(&carried));
    assert_eq!(new.boot(), old.boot());
    // Session 2 ended and 3 started while it was under way, and 1's agent changed.
    let mut one = listing(1, "wr-1");
    one["coding_agent"] = agent("working", "a");
    new.reconcile(vec![(id(1), one), (id(3), listing(3, "wr-2"))], true);
    let mut resumed = Cursor::new(Start::Since {
        boot: old.boot().to_hyphenated(),
        revision: 2,
    });
    assert!(matches!(
        next(&new, &mut resumed),
        Next::Resumed { revision: 2, .. }
    ));
    let live = events(next(&new, &mut resumed));
    assert_eq!(
        names(&live),
        [name::ENDED, name::PROGRAM_STATUS, name::CREATED],
        "{live:?}"
    );
    let revisions: Vec<u64> = live
        .iter()
        .map(|e| e["revision"].as_u64().unwrap())
        .collect();
    assert_eq!(revisions, [3, 4, 5]);

    // Called off: the held event goes out.
    old.unseal();
    let mut cursor = Cursor::new(Start::Since {
        boot: old.boot().to_hyphenated(),
        revision: 2,
    });
    let _ = next(&old, &mut cursor);
    assert_eq!(
        names(&events(next(&old, &mut cursor))),
        [name::PROGRAM_STATUS]
    );
}

/// With nothing carried, the sessions are taken as they are, silently, under a new boot.
#[test]
fn an_uncarried_hand_off_takes_the_sessions_as_they_are() {
    let hub = Hub::default();
    hub.reconcile(vec![(id(1), listing(1, "wr-1"))], false);
    let Next::Snapshot {
        revision, sessions, ..
    } = next(&hub, &mut Cursor::new(Start::Fresh))
    else {
        panic!("no snapshot");
    };
    assert_eq!(revision, 0);
    assert!(sessions.contains_key(&id(1)));
    assert!(!hub.adopt(b"not json"));
}
