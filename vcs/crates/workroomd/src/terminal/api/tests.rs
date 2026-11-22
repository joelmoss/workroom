use super::*;

fn session(id: &str, label: Option<&str>, title: Option<&str>) -> Value {
    json!({"id": id, "label": label, "title": title})
}

const A: &str = "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11";
const B: &str = "0b9d33c1-7a44-4e1b-8f00-6c2a1d0abeef";
const C: &str = "c0ffee00-1111-4222-8333-44445555beef";

fn listing() -> Vec<Value> {
    vec![
        session(A, Some("server"), Some("vim notes.md")),
        session(B, Some("tests"), Some("server")),
        session(C, Some("tests"), None),
    ]
}

fn resolved(target: &str) -> Result<String, (&'static str, Vec<String>)> {
    resolve(&listing(), target)
        .map(|session| session["id"].as_str().unwrap().to_string())
        .map_err(|error| {
            let ids = error
                .matches
                .iter()
                .map(|session| session["id"].as_str().unwrap().to_string())
                .collect();
            (error.kind, ids)
        })
}

#[test]
fn a_full_id_resolves_in_any_case_with_or_without_hyphens() {
    assert_eq!(resolved(A), Ok(A.into()));
    assert_eq!(resolved(&A.to_uppercase()), Ok(A.into()));
    assert_eq!(resolved(&A.replace('-', "")), Ok(A.into()));
}

#[test]
fn a_suffix_of_four_characters_resolves_and_a_shorter_one_does_not() {
    assert_eq!(resolved("8e11"), Ok(A.into()));
    assert_eq!(resolved("1d0a8e11"), Ok(A.into()));
    assert_eq!(
        resolved("-2b7f1d0a8e11"),
        Ok(A.into()),
        "typed with its hyphen"
    );
    assert_eq!(resolved("e11"), Err((kind::TARGET_NOT_FOUND, vec![])));
}

#[test]
fn a_suffix_two_ids_share_is_ambiguous_and_lists_both() {
    assert_eq!(
        resolved("beef"),
        Err((kind::TARGET_AMBIGUOUS, vec![B.into(), C.into()]))
    );
}

/// The id steps come first: "server" is A's label and B's title, and the label wins.
#[test]
fn a_label_resolves_before_a_live_title() {
    assert_eq!(resolved("server"), Ok(A.into()));
    assert_eq!(resolved("vim notes.md"), Ok(A.into()));
}

#[test]
fn a_label_two_sessions_share_is_ambiguous() {
    assert_eq!(
        resolved("tests"),
        Err((kind::TARGET_AMBIGUOUS, vec![B.into(), C.into()]))
    );
}

#[test]
fn labels_and_titles_match_exactly() {
    assert_eq!(resolved("Server"), Err((kind::TARGET_NOT_FOUND, vec![])));
    assert_eq!(resolved("vim"), Err((kind::TARGET_NOT_FOUND, vec![])));
    assert_eq!(resolved(""), Err((kind::TARGET_NOT_FOUND, vec![])));
}

fn request(store: &SessionStore, request: Value) -> Result<Value, ApiError> {
    handle(store, &serde_json::to_vec(&request).unwrap(), None).map(|answer| match answer {
        Answer::One(value) => value,
        Answer::Stream(_) => panic!("a stream from {request}"),
    })
}

/// A capture's parameters are checked before any session is looked for.
#[test]
fn a_capture_with_parameters_it_cannot_take_is_invalid() {
    let store = SessionStore::new();
    for params in [
        json!({}),
        json!({"target": 3}),
        json!({"target": "x", "lines": -1}),
        json!({"target": "x", "lines": 1.5}),
        json!({"target": "x", "lines": "10"}),
        json!({"target": "x", "lines": 5, "all": true}),
        json!({"target": "x", "unwrap": "yes"}),
        json!({"target": "x", "vt": 1}),
    ] {
        let error = request(
            &store,
            json!({"method": "terminal.capture", "params": params}),
        )
        .expect_err(&params.to_string());
        assert_eq!(error.kind, kind::INVALID_REQUEST, "{params}");
    }
    let missing = request(
        &store,
        json!({"method": "terminal.capture", "params": {"target": "x", "lines": 0}}),
    )
    .unwrap_err();
    assert_eq!(missing.kind, kind::TARGET_NOT_FOUND);
}

/// A capture from a copy takes one of a few places, and gives it back when its pieces are dropped.
#[test]
fn captures_past_the_cap_get_no_place_until_one_ends() {
    static HELD: AtomicUsize = AtomicUsize::new(0);
    let first = Slot::acquire_from(&HELD, 2).expect("a place");
    let second = Slot::acquire_from(&HELD, 2).expect("a place");
    assert!(Slot::acquire_from(&HELD, 2).is_none());
    drop(first);
    let third = Slot::acquire_from(&HELD, 2).expect("a place once one ended");
    drop((second, third));
    assert_eq!(HELD.load(Ordering::Acquire), 0);
}

/// `--all`'s chunks are whole lines of at most `max` bytes, which together are the text; a line
/// longer than that is cut between characters.
#[test]
fn a_long_capture_is_cut_into_chunks_of_whole_lines() {
    let pieces = |text: &str, max: usize| -> Vec<String> {
        chunks(text, max)
            .into_iter()
            .map(|range| text[range].to_string())
            .collect()
    };
    assert_eq!(pieces("", 8), [""]);
    assert_eq!(pieces("short", 8), ["short"]);
    assert_eq!(pieces("ab\ncd\nef\ngh", 6), ["ab\ncd\n", "ef\ngh"]);
    assert_eq!(pieces("ab\ncd\n", 6), ["ab\ncd\n"]);
    assert_eq!(pieces("abcdefgh\nij", 4), ["abcd", "efgh", "\nij"]);
    // Never inside a character: each é is two bytes.
    assert_eq!(pieces("ééé", 3), ["é", "é", "é"]);
    let text: String = (0..1000).map(|n| format!("line {n}\n")).collect();
    let cut = pieces(&text, 100);
    assert!(
        cut.iter()
            .all(|piece| piece.len() <= 100 && piece.ends_with('\n'))
    );
    assert_eq!(cut.concat(), text);
}

#[test]
fn a_request_that_is_not_a_method_call_is_invalid() {
    let store = SessionStore::new();
    for bad in [
        json!("session.list"),
        json!({}),
        json!({"method": "session.nope"}),
        json!({"method": "session.list", "params": [1]}),
        json!({"method": "session.resolve"}),
        json!({"method": "session.list", "params": {"all": "yes"}}),
        json!({"method": "session.list", "params": {"all": 1}}),
        json!({"method": "session.list", "params": {"all": null}}),
        json!({"method": "session.list", "caller": 7}),
        json!({"method": "api.describe", "params": {"method": "x.y"}}),
    ] {
        let error = request(&store, bad.clone()).expect_err(&bad.to_string());
        assert_eq!(error.kind, kind::INVALID_REQUEST, "{bad}");
    }
    assert!(handle(&store, b"not json", None).is_err());
}

#[test]
fn describe_publishes_every_method_with_both_schemas() {
    let store = SessionStore::new();
    let all = request(&store, json!({"method": "api.describe"})).unwrap();
    assert_eq!(all["revision"], REVISION);
    let names: Vec<&str> = all["methods"]
        .as_array()
        .unwrap()
        .iter()
        .map(|method| method["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        [
            "api.describe",
            "session.list",
            "session.resolve",
            "terminal.capture",
            "terminal.send",
            "terminal.command",
            "terminal.wait",
            "terminal.prompt",
            "session.new",
            "session.run_control",
            "session.close",
            "events.subscribe",
            "events.unsubscribe"
        ]
    );
    for method in all["methods"].as_array().unwrap() {
        for schema in ["input", "output"] {
            assert_eq!(method[schema]["type"], "object", "{method}");
        }
        let namespace = method["name"].as_str().unwrap().split('.').next().unwrap();
        assert!(
            ["api", "session", "terminal", "client", "events"].contains(&namespace),
            "{method}"
        );
    }
    // The error's schema is `error_schema`: a reply's `error` is only ever a failure.
    assert_eq!(all["error_schema"]["required"], json!(["kind", "message"]));
    assert!(all.get("error").is_none(), "{all}");
    let one = request(
        &store,
        json!({"method": "api.describe", "params": {"method": "session.resolve"}}),
    )
    .unwrap();
    assert_eq!(one["methods"].as_array().unwrap().len(), 1);
    assert_eq!(
        one["methods"][0]["errors"],
        json!(["TargetNotFound", "TargetAmbiguous"])
    );
}

/// `api.describe`'s result example is what it really replies to its params example, so neither a
/// method's summary nor its schemas can drift from it.
#[test]
fn describes_result_example_is_its_real_reply_to_its_params_example() {
    let store = SessionStore::new();
    let describe = &METHODS[0];
    assert_eq!(describe.name, "api.describe");
    let params = (describe.params_example)();
    let replied = request(
        &store,
        json!({"method": describe.name, "params": params.clone()}),
    )
    .unwrap();
    assert_eq!((describe.result_example)(), replied);
    assert_eq!(params, json!({"method": "session.list"}));
    assert_eq!(
        replied["methods"][0]["summary"], METHODS[1].summary,
        "{replied}"
    );
}

/// A caller's scope is the sessions with the same scope, kind and id both. A caller with no
/// scope, or no caller, keeps to nothing, so every session is listed.
#[test]
fn a_callers_scope_is_the_sessions_sharing_its_scope() {
    let scoped = |id: &str, scope: Value| json!({"id": id, "scope": scope});
    let workroom = |id: &str| json!({"kind": "workroom", "id": id});
    const D: &str = "d0d0d0d0-1111-4222-8333-444455556666";
    let listing = vec![
        scoped(A, workroom("wr-1")),
        scoped(B, workroom("wr-1")),
        scoped(C, workroom("wr-2")),
        scoped(D, Value::Null),
    ];
    let ids = |caller: Option<&str>| -> Vec<String> {
        in_scope_of(listing.clone(), caller)
            .iter()
            .map(|session| session["id"].as_str().unwrap().to_string())
            .collect()
    };
    assert_eq!(ids(Some(B)), [A, B]);
    assert_eq!(ids(Some(C)), [C]);
    assert_eq!(ids(Some(D)), [A, B, C, D]);
    assert_eq!(ids(None), [A, B, C, D]);
    assert_eq!(ids(Some("not-listed")), [A, B, C, D]);
    // Another kind with the same id is another scope.
    let mut other = listing.clone();
    other.push(scoped(
        "e0e0e0e0-1111-4222-8333-444455556666",
        json!({"kind": "terminal", "id": "wr-1"}),
    ));
    assert_eq!(in_scope_of(other, Some(A)).len(), 2);
}

#[test]
fn an_empty_daemon_lists_no_sessions_and_resolves_nothing() {
    let store = SessionStore::new();
    assert_eq!(
        request(&store, json!({"method": "session.list"})).unwrap(),
        json!({"sessions": [], "caller": null})
    );
    // A caller naming no session of this daemon is no caller.
    assert_eq!(
        request(
            &store,
            json!({"method": "session.list", "params": {"all": false}, "caller": A}),
        )
        .unwrap(),
        json!({"sessions": [], "caller": null})
    );
    let error = request(
        &store,
        json!({"method": "session.resolve", "params": {"target": "x"}}),
    )
    .unwrap_err();
    assert_eq!(error.kind, kind::TARGET_NOT_FOUND);
}

/// The reply's outer shape, the API's revision in `revision` (not the other services' `version`),
/// and an ambiguous target's matches.
#[test]
fn errors_reply_with_kind_message_and_matches() {
    let error = resolve(&listing(), "tests").unwrap_err();
    let wire = reply(Err(error), false);
    assert_eq!(wire["revision"], REVISION);
    assert_eq!(wire["error"]["kind"], "TargetAmbiguous");
    assert_eq!(wire["error"]["matches"].as_array().unwrap().len(), 2);
    let plain = reply(Err(ApiError::invalid("bad")), false);
    assert_eq!(
        plain,
        json!({
            "revision": REVISION,
            "error": {"kind": "InvalidRequest", "message": "bad"},
            "more": false,
        })
    );
    assert_eq!(
        reply(Ok(json!({"sessions": []})), false),
        json!({"revision": REVISION, "result": {"sessions": []}, "more": false})
    );
    // `more` is the reply's, outside the result, and an error always ends a stream.
    assert_eq!(reply(Ok(json!({})), true)["more"], true);
    assert_eq!(reply(Err(ApiError::invalid("bad")), true)["more"], false);
}

/// A stream says `more` on every reply but its last, stops at its first error, and stops making
/// results once a send fails: the rest are never made.
#[test]
fn a_stream_says_more_until_its_last_reply() {
    use std::cell::{Cell, RefCell};
    use std::rc::Rc;
    let sent = RefCell::new(Vec::new());
    let made = Rc::new(Cell::new(0));
    let results = |count: usize, made: Rc<Cell<usize>>| {
        Box::new((0..count).map(move |n| {
            made.set(made.get() + 1);
            Ok(json!({"n": n}))
        })) as Box<dyn Iterator<Item = Result<Value, ApiError>>>
    };
    stream(results(3, made.clone()), |value| {
        sent.borrow_mut().push(value);
        true
    });
    let mores: Vec<Value> = sent
        .borrow()
        .iter()
        .map(|reply| reply["more"].clone())
        .collect();
    assert_eq!(mores, [true, true, false]);

    sent.borrow_mut().clear();
    let failing = Box::new(
        [
            Ok(json!({})),
            Err(ApiError::invalid("broke")),
            Ok(json!({})),
        ]
        .into_iter(),
    );
    stream(failing, |value| {
        sent.borrow_mut().push(value);
        true
    });
    assert_eq!(sent.borrow().len(), 2);
    assert_eq!(sent.borrow()[0]["more"], true);
    assert_eq!(sent.borrow()[1]["error"]["kind"], "InvalidRequest");
    assert_eq!(sent.borrow()[1]["more"], false);

    // The client hung up after the first: only it and the one peeked behind it were made.
    made.set(0);
    stream(results(100, made.clone()), |_| false);
    assert_eq!(made.get(), 2);
}

/// What a connection's writer was given.
#[derive(Clone, Default)]
struct Written(std::sync::Arc<std::sync::Mutex<Vec<u8>>>);

impl std::io::Write for Written {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Written {
    /// The replies written, each one's chunks joined.
    fn replies(&self) -> Vec<Value> {
        let mut decoder = wr_protocol::envelope::EnvelopeDecoder::new();
        decoder.push(&self.0.lock().unwrap());
        let (mut replies, mut reply) = (Vec::new(), Vec::new());
        while let Some(envelope) = decoder.next_envelope().unwrap() {
            let (last, body) = envelope.payload.split_first().unwrap();
            reply.extend_from_slice(body);
            if *last == 1 {
                replies.push(serde_json::from_slice(&std::mem::take(&mut reply)).unwrap());
            }
        }
        replies
    }
}

fn start_wait(waits: &mut wait::Waits, store: &SessionStore, params: Value, writer: &SharedWriter) {
    let call = Call {
        sessions: store,
        params: &params,
        caller: None,
    };
    wait::start(waits, &call, writer, 1);
}

/// A session of `store`'s that runs `sleep 30`, with an id all of `byte`.
fn sleeping(store: &SessionStore, byte: u8) -> crate::terminal::session::SessionId {
    running(store, byte, "sleep 30")
}

/// A session of `store`'s that runs `script` with `/bin/sh -c`, with an id all of `byte`.
fn running(store: &SessionStore, byte: u8, script: &str) -> crate::terminal::session::SessionId {
    use std::ffi::{OsStr, OsString};
    let id = crate::terminal::session::SessionId([byte; 16]);
    let args = [OsString::from("-c"), OsString::from(script)];
    store
        .create(crate::terminal::session::SessionSpec {
            id,
            program: OsStr::new("/bin/sh"),
            argv0: None,
            args: &args,
            env: &[],
            cwd: None,
            columns: 80,
            rows: 24,
            metadata: &[],
            interactive: false,
        })
        .expect("a session");
    id
}

/// Until `done`, for at most 10 s.
fn eventually(done: impl Fn() -> bool) -> bool {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !done() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    done()
}

/// The one reply `written` gets, within 20 s.
#[cfg(feature = "terminal-state")]
fn the_reply(written: &Written) -> Value {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    while written.replies().is_empty() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let replies = written.replies();
    assert_eq!(replies.len(), 1, "{replies:?}");
    replies[0].clone()
}

/// A regex wait that starts while the session's output is inside a title's OSC or a kitty image's
/// APC matches nothing of the rest of it: only the text after it ends (#690). Inside a colour's
/// CSI, the text straight after its final byte is text, on the same line.
#[cfg(feature = "terminal-state")]
#[test]
fn a_regex_wait_started_mid_sequence_skips_the_rest_of_it() {
    let store = SessionStore::new();
    for (byte, opened, rest) in [
        (0x43, r"\033]2;title ", r"NOPE\007"),
        (0x44, r"\033_Ga=T,f=100;QUFB", r"NOPE\033\\"),
        (0x49, r"\033[3", "2m"),
    ] {
        // The sequence's rest 3 s on, by when the wait below has long started.
        let id = running(
            &store,
            byte,
            &format!("printf '{opened}'; sleep 3; printf '{rest}DONE\\n'; sleep 30"),
        );
        let shadow = store.shadow(id).expect("the session");
        assert!(
            eventually(|| crate::util::lock_or_recover(&shadow)
                .open_sequence()
                .is_some()),
            "fixture: the sequence's start never arrived"
        );
        let (written, writer) = written_writer();
        let mut connection = Connection::default();
        start_wait(
            &mut connection.waits,
            &store,
            json!({"target": id.to_hyphenated(), "regex": "NOPE|DONE", "timeout_ms": 20000}),
            &writer,
        );
        let reply = the_reply(&written);
        assert_eq!(
            reply["result"]["match"]["text"], "DONE",
            "{opened}: {reply}"
        );
        store.kill(id);
    }
}

/// `include_screen` matches the visible screen, as documented: not the history that scrolled off
/// it, and a line the pane wrapped as the program printed it.
#[cfg(feature = "terminal-state")]
#[test]
fn include_screen_matches_the_visible_screen_only() {
    let store = SessionStore::new();
    // 30 lines push the first off the 24-row screen; at 80 columns, the last line wraps.
    let id = running(
        &store,
        0x46,
        r#"echo SCROLLED-OFF; seq 30; printf 'WRAP%.0s' $(seq 30); echo; sleep 30"#,
    );
    let shadow = store.shadow(id).expect("the session");
    assert!(
        eventually(|| crate::util::lock_or_recover(&shadow)
            .screen_text()
            .contains(&"WRAP".repeat(30))),
        "fixture: the output never arrived"
    );
    let wait = |pattern: &str| {
        let (written, writer) = written_writer();
        let mut connection = Connection::default();
        start_wait(
            &mut connection.waits,
            &store,
            json!({
                "target": id.to_hyphenated(),
                "regex": pattern,
                "include_screen": true,
                // Met at once or never: the session prints nothing more.
                "timeout_ms": 1000,
            }),
            &writer,
        );
        the_reply(&written)
    };
    let off = wait("SCROLLED-OFF");
    assert_eq!(off["error"]["kind"], "WaitTimeout", "{off}");
    let wrapped = wait("(WRAP){30}");
    assert_eq!(
        wrapped["result"]["match"]["text"],
        "WRAP".repeat(30),
        "{wrapped}"
    );
    store.kill(id);
}

/// A wait that could never be met is refused as such before any bound is looked at: a session with
/// no shell integration is `NoShellIntegration` to a `command_finished` wait, even on a connection
/// that holds all it may. (With no grace: the session is past the age its first prompt could
/// still be coming at.)
#[cfg(feature = "terminal-state")]
#[test]
fn a_precondition_is_refused_before_a_full_connection_is_busy() {
    use std::sync::atomic::AtomicUsize;
    static HELD: AtomicUsize = AtomicUsize::new(0);
    let full = wait::Limits {
        session: 0,
        connection: 0,
        daemon: 0,
        marks_grace: std::time::Duration::ZERO,
    };
    let store = SessionStore::new();
    let id = sleeping(&store, 0x45);
    let (written, writer) = written_writer();
    let mut waits = wait::Waits::with(full, &HELD, None);
    for params in [
        json!({"target": id.to_hyphenated(), "command_finished": true}),
        json!({"target": id.to_hyphenated(), "ended": true}),
    ] {
        start_wait(&mut waits, &store, params, &writer);
    }
    let kinds: Vec<Value> = written
        .replies()
        .iter()
        .map(|reply| reply["error"]["kind"].clone())
        .collect();
    assert_eq!(kinds, ["NoShellIntegration", "Busy"]);
    store.kill(id);
}

/// A `command_finished` wait on a session young enough that its shell's first prompt may still be
/// coming isn't refused for want of marks: it waits out the grace for one. A shell that sends one
/// and then ends a command meets it; one that sends none is `NoShellIntegration` once the grace is
/// over, not at once and not at the wait's timeout.
#[cfg(feature = "terminal-state")]
#[test]
fn a_young_session_gets_a_grace_for_its_first_mark() {
    use std::sync::atomic::AtomicUsize;
    static HELD: AtomicUsize = AtomicUsize::new(0);
    let store = SessionStore::new();
    // Its prompt 3 s on, well inside a 20 s grace, by when the wait has long started.
    let marked = running(
        &store,
        0x47,
        r"sleep 3; printf '\033]133;A\007\033]133;C\007'; printf '\033]133;D;4\007'; sleep 30",
    );
    let wait = |id: SessionId, grace: u64| {
        let limits = wait::Limits {
            marks_grace: std::time::Duration::from_secs(grace),
            ..wait::LIMITS
        };
        let (written, writer) = written_writer();
        let mut waits = wait::Waits::with(limits, &HELD, None);
        start_wait(
            &mut waits,
            &store,
            json!({"target": id.to_hyphenated(), "command_finished": true, "timeout_ms": 60000}),
            &writer,
        );
        (written, waits)
    };
    let (finished, _held) = wait(marked, 20);
    let reply = the_reply(&finished);
    assert_eq!(reply["result"]["exit_code"], 4, "{reply}");

    // Made just now, so not refused at once, but 10 s from its creation, long before the wait's
    // 60 s timeout.
    let silent = sleeping(&store, 0x48);
    let (refused, _held) = wait(silent, 10);
    assert!(
        refused.replies().is_empty(),
        "a session inside its grace was refused at once"
    );
    let reply = the_reply(&refused);
    assert_eq!(reply["error"]["kind"], "NoShellIntegration", "{reply}");
    store.kill(marked);
    store.kill(silent);
}

/// A program that reports `working` and `done` in one write has passed through `working`, though
/// the shadow says `done` once the read is over: a wait for `working` is met (#690).
#[cfg(feature = "terminal-state")]
#[test]
fn a_status_reported_and_replaced_in_one_read_meets_a_wait_for_it() {
    let store = SessionStore::new();
    // 3 s on, by when the wait below has long started; one printf, so one write.
    let id = running(
        &store,
        0x41,
        r#"sleep 3; printf '\033]7501;state=working:app=t\033\\\033]7501;state=done:app=t\033\\'; sleep 30"#,
    );
    let (written, writer) = written_writer();
    let mut connection = Connection::default();
    start_wait(
        &mut connection.waits,
        &store,
        json!({"target": id.to_hyphenated(), "status": "working", "timeout_ms": 20000}),
        &writer,
    );
    let reply = the_reply(&written);
    assert_eq!(reply["result"]["status"], "working", "{reply}");
    let listed = listed(&store);
    assert_eq!(
        listed[0]["coding_agent"]["state"], "done",
        "fixture: {listed:?}"
    );
    store.kill(id);
}

/// A request that never probed becomes the session's status once the tick promotes it, with no
/// read to tell a wait: the tick tells it (`promote_unprobed`, #690).
#[cfg(feature = "terminal-state")]
#[test]
fn a_promoted_request_meets_a_wait_for_blocked() {
    let store = SessionStore::new();
    // A request under `a`, then `b` working: the newest record, so the one `sessions` reports
    // until the request may alert.
    let id = running(
        &store,
        0x42,
        r#"printf '\033]7501;state=blocked:id=a:app=t\033\\\033]7501;state=working:id=b:app=t\033\\'; sleep 60"#,
    );
    assert!(
        eventually(|| listed(&store)[0]["coding_agent"]["state"] == "working"),
        "fixture: the reports never arrived"
    );
    let (written, writer) = written_writer();
    let mut connection = Connection::default();
    start_wait(
        &mut connection.waits,
        &store,
        json!({"target": id.to_hyphenated(), "status": "blocked", "timeout_ms": 20000}),
        &writer,
    );
    assert!(
        written.replies().is_empty(),
        "met before the request was promoted"
    );
    store.promote_unprobed(
        std::time::Instant::now() + crate::terminal::program_status::limits::GRACE,
    );
    let reply = the_reply(&written);
    assert_eq!(reply["result"]["status"], "blocked", "{reply}");
    store.kill(id);
}

/// Waits are bounded on a session, a connection and the daemon (`wait::Limits`, lowered here); one
/// past a bound is `Busy`, and a place comes back when a wait ends. Bad input, and a target that
/// names no session, are refused as such even past a bound, never as `Busy`.
#[test]
fn waits_past_a_bound_are_busy_until_one_ends() {
    use std::sync::atomic::AtomicUsize;
    static HELD: AtomicUsize = AtomicUsize::new(0);
    let limits = wait::Limits {
        session: 2,
        connection: 3,
        daemon: 4,
        ..wait::LIMITS
    };
    let store = SessionStore::new();
    let (a, b) = (sleeping(&store, 0x31), sleeping(&store, 0x32));
    let (written, writer) = written_writer();
    let regex = |id: SessionId| json!({"target": id.to_hyphenated(), "regex": "never"});
    let kinds = |written: &Written| -> Vec<Value> {
        written
            .replies()
            .iter()
            .map(|reply| reply["error"]["kind"].clone())
            .collect()
    };

    let mut first = wait::Waits::with(limits, &HELD, None);
    start_wait(&mut first, &store, regex(a), &writer);
    start_wait(&mut first, &store, regex(a), &writer);
    // The session's bound.
    start_wait(&mut first, &store, regex(a), &writer);
    assert_eq!(kinds(&written), ["Busy"]);
    assert_eq!(store.waiter_count(a), 2);
    // The connection's: two on `a` and one on `b` are its three.
    start_wait(&mut first, &store, regex(b), &writer);
    start_wait(&mut first, &store, regex(b), &writer);
    assert_eq!(kinds(&written), ["Busy", "Busy"]);
    for refused in [
        json!({"target": "nobody", "regex": "never"}),
        json!({"target": b.to_hyphenated(), "regex": "("}),
    ] {
        start_wait(&mut first, &store, refused, &writer);
    }
    assert_eq!(
        kinds(&written),
        ["Busy", "Busy", "TargetNotFound", "InvalidRequest"]
    );

    // The daemon's: another connection gets its fourth place, and no fifth.
    let mut second = wait::Waits::with(limits, &HELD, None);
    start_wait(&mut second, &store, regex(b), &writer);
    assert_eq!(store.waiter_count(b), 2);
    start_wait(&mut second, &store, regex(b), &writer);
    let replies = written.replies();
    assert_eq!(replies.len(), 5, "{replies:?}");
    assert_eq!(replies[4]["error"]["kind"], "Busy");
    assert!(
        replies[4]["error"]["message"]
            .as_str()
            .unwrap()
            .contains("this daemon"),
        "{replies:?}"
    );

    // The first connection closing ends its waits, and their places come back.
    drop(first);
    assert!(eventually(|| HELD.load(Ordering::Acquire) == 1));
    start_wait(&mut second, &store, regex(a), &writer);
    assert_eq!(
        written.replies().len(),
        5,
        "a wait under every bound was refused"
    );
    assert_eq!(store.waiter_count(a), 1);

    drop(second);
    assert!(eventually(|| HELD.load(Ordering::Acquire) == 0));
    store.kill(a);
    store.kill(b);
}

/// A wait whose thread can't start answers `InternalError` at once, and leaves nothing held: no
/// waiter on the session, no wait on the connection, no place of the daemon's.
#[test]
fn a_wait_with_no_thread_answers_and_holds_nothing() {
    use std::sync::atomic::AtomicUsize;
    static HELD: AtomicUsize = AtomicUsize::new(0);
    let store = SessionStore::new();
    let id = sleeping(&store, 0x33);
    let (written, writer) = written_writer();
    let mut waits = wait::Waits::with(
        wait::LIMITS,
        &HELD,
        Some(|_| Err(std::io::Error::other("no threads left"))),
    );
    start_wait(
        &mut waits,
        &store,
        json!({"target": id.to_hyphenated(), "regex": "never"}),
        &writer,
    );
    let replies = written.replies();
    assert_eq!(replies.len(), 1, "{replies:?}");
    assert_eq!(replies[0]["error"]["kind"], "InternalError");
    assert_eq!(replies[0]["more"], false);
    assert_eq!(store.waiter_count(id), 0);
    assert_eq!(HELD.load(Ordering::Acquire), 0);
    assert_eq!(waits.held_count(), 0);
    store.kill(id);
}

/// A regex wait whose thread falls a queue behind its session's output answers `WaitInterrupted`
/// once it has matched what it kept, which is nothing here: what it dropped may have held a match.
/// The thread is held back from starting (the spawn seam) while the session prints twice the
/// queue, and let go once all of it has been read.
#[cfg(feature = "terminal-state")]
#[test]
fn a_regex_wait_that_falls_behind_is_interrupted() {
    use std::sync::atomic::AtomicUsize;
    type Work = Box<dyn FnOnce() + Send>;
    static HELD: AtomicUsize = AtomicUsize::new(0);
    static PARKED: std::sync::Mutex<Vec<Work>> = std::sync::Mutex::new(Vec::new());
    fn park(work: Work) -> std::io::Result<()> {
        crate::util::lock_or_recover(&PARKED).push(work);
        Ok(())
    }
    // A gate file inside a folder of this run's own, removed with it.
    let scratch = crate::commands::Scratch::in_temp("wr-wait-behind");
    let go = scratch.join("go");
    let store = SessionStore::new();
    let id = running(
        &store,
        0x34,
        &format!(
            "while [ ! -e '{go}' ]; do sleep 0.05; done; head -c {bytes} /dev/zero | tr '\\0' x; \
             echo; echo PRINTED; sleep 30",
            go = go.display(),
            bytes = 2 * crate::terminal::wait::QUEUE,
        ),
    );
    let (written, writer) = written_writer();
    let mut waits = wait::Waits::with(wait::LIMITS, &HELD, Some(park));
    start_wait(
        &mut waits,
        &store,
        json!({"target": id.to_hyphenated(), "regex": "NEVER", "timeout_ms": 20000}),
        &writer,
    );
    std::fs::write(&go, b"").expect("go");
    // Read, and so handed to the waiter, a read before `PRINTED` reached the screen.
    let shadow = store.shadow(id).expect("the session");
    assert!(
        eventually(|| crate::util::lock_or_recover(&shadow)
            .screen_text()
            .contains("PRINTED")),
        "fixture: the output never arrived"
    );
    let work = crate::util::lock_or_recover(&PARKED)
        .pop()
        .expect("the wait's thread, held back");
    std::thread::spawn(work);
    let reply = the_reply(&written);
    assert_eq!(reply["error"]["kind"], "WaitInterrupted", "{reply}");
    assert!(
        reply["error"]["message"]
            .as_str()
            .is_some_and(|message| message.contains("fell behind")),
        "{reply}"
    );
    store.kill(id);
}

fn written_writer() -> (Written, SharedWriter) {
    let written = Written::default();
    let writer: SharedWriter =
        std::sync::Arc::new(std::sync::Mutex::new(Box::new(written.clone())));
    (written, writer)
}

/// A reply over the 16 MiB one holds, a wait's included, goes out as a `TooLarge` reply like any
/// other: its revision, its error and `more`, never a bare error.
#[test]
fn an_over_limit_reply_is_a_whole_too_large_reply() {
    let too_large = json!({
        "revision": REVISION,
        "error": {"kind": "TooLarge", "message": "the reply is over 16 MiB"},
        "more": false,
    });
    let (written, writer) = written_writer();
    let huge = reply(Ok(json!({"text": "x".repeat(17 << 20)})), false);
    assert!(send(&writer, 1, huge));
    assert_eq!(written.replies(), vec![too_large.clone()]);

    // A wait's: a target of 9 MiB of quotes is named in its `TargetNotFound`, escaped twice over.
    let store = SessionStore::new();
    let (written, writer) = written_writer();
    start_wait(
        &mut Connection::default().waits,
        &store,
        json!({"target": "\"".repeat(9 << 20), "ended": true}),
        &writer,
    );
    assert_eq!(written.replies(), [too_large]);
}

/// A wait that fails at once answers on its stream as every method does: one reply, with its
/// revision and `more: false`.
#[test]
fn a_wait_replies_with_revision_and_more() {
    let store = SessionStore::new();
    let (written, writer) = written_writer();
    let mut connection = Connection::default();
    start_wait(
        &mut connection.waits,
        &store,
        json!({"target": "nobody", "ended": true}),
        &writer,
    );
    let replies = written.replies();
    assert_eq!(replies.len(), 1, "{replies:?}");
    assert_eq!(replies[0]["revision"], REVISION);
    assert_eq!(replies[0]["more"], false);
    assert_eq!(replies[0]["error"]["kind"], "TargetNotFound");
}

/// A caller that goes away takes its waits with it: nothing is left matching the session's output,
/// and nothing is answered to nobody.
#[test]
fn a_connection_that_closes_ends_its_waits() {
    let store = SessionStore::new();
    let id = sleeping(&store, 0x69);
    let (written, writer) = written_writer();
    let mut connection = Connection::default();
    for pattern in ["never", "nor this"] {
        start_wait(
            &mut connection.waits,
            &store,
            json!({"target": id.to_hyphenated(), "regex": pattern}),
            &writer,
        );
    }
    assert_eq!(store.waiter_count(id), 2);

    drop(connection);
    assert!(
        eventually(|| store.waiter_count(id) == 0),
        "a closed connection's waits are still held"
    );
    assert!(
        written.0.lock().unwrap().is_empty(),
        "a cancelled wait was answered"
    );
    store.kill(id);
}

fn subscribe(
    subscriptions: &mut events::Subscriptions,
    store: &SessionStore,
    writer: &SharedWriter,
    stream: u32,
) {
    let params = json!({"all": true});
    let call = Call {
        sessions: store,
        params: &params,
        caller: None,
    };
    events::start(subscriptions, &call, writer, stream);
}

/// The replies' `result.event`s, or `error.kind`s.
fn said(written: &Written) -> Vec<String> {
    written
        .replies()
        .iter()
        .map(|reply| {
            reply["result"]["event"]
                .as_str()
                .or(reply["error"]["kind"].as_str())
                .unwrap_or_default()
                .to_string()
        })
        .collect()
}

/// A connection and the daemon each hold a few subscriptions; one past either is `Busy` at once,
/// and a connection that closes gives its places back.
#[test]
fn events_past_a_bound_are_busy_until_a_connection_closes() {
    use std::sync::atomic::AtomicUsize;
    static HELD: AtomicUsize = AtomicUsize::new(0);
    let limits = events::Limits {
        connection: 2,
        daemon: 3,
    };
    let store = SessionStore::new();
    let (first_written, first_writer) = written_writer();
    let mut first = events::Subscriptions::with(limits, &HELD);
    for stream in 1..=3 {
        subscribe(&mut first, &store, &first_writer, stream);
    }
    assert!(
        eventually(|| said(&first_written).len() == 3),
        "{:?}",
        said(&first_written)
    );
    let mut first_said = said(&first_written);
    first_said.sort();
    assert_eq!(
        first_said,
        ["Busy", "snapshot-complete", "snapshot-complete"]
    );

    let (second_written, second_writer) = written_writer();
    let mut second = events::Subscriptions::with(limits, &HELD);
    for stream in 1..=2 {
        subscribe(&mut second, &store, &second_writer, stream);
    }
    assert!(eventually(|| said(&second_written).len() == 2));
    let mut second_said = said(&second_written);
    second_said.sort();
    assert_eq!(
        second_said,
        ["Busy", "snapshot-complete"],
        "the daemon's bound"
    );

    drop(first);
    let (third_written, third_writer) = written_writer();
    let mut third = events::Subscriptions::with(limits, &HELD);
    // Its threads end a moment after it closes; until then a place is still `Busy`.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let mut stream = 0;
    while std::time::Instant::now() < deadline {
        stream += 1;
        subscribe(&mut third, &store, &third_writer, stream);
        let replied = eventually(|| said(&third_written).len() == stream as usize);
        if replied && said(&third_written).last().map(String::as_str) == Some("snapshot-complete") {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert_eq!(
        said(&third_written).last().map(String::as_str),
        Some("snapshot-complete"),
        "a closed connection's places were never given back"
    );
    drop((second, third));
}

fn unsubscribe(
    subscriptions: &mut events::Subscriptions,
    store: &SessionStore,
    params: Value,
) -> Result<Value, ApiError> {
    let call = Call {
        sessions: store,
        params: &params,
        caller: None,
    };
    events::unsubscribe(subscriptions, &call)
}

/// `events.unsubscribe` (#696) ends one of the connection's subscriptions before the connection
/// does: its place is free at once, however many a caller gives up on, and its stream goes quiet.
/// Ending one it doesn't hold is `ended: false`, and bad input is `InvalidRequest`.
#[test]
fn events_unsubscribe_ends_a_subscription_and_frees_its_place() {
    use std::sync::atomic::AtomicUsize;
    static HELD: AtomicUsize = AtomicUsize::new(0);
    let limits = events::Limits {
        connection: 2,
        daemon: 2,
    };
    let store = SessionStore::new();
    let (written, writer) = written_writer();
    let mut subscriptions = events::Subscriptions::with(limits, &HELD);
    // Far past both bounds, each one ended before the next: none is ever `Busy`.
    for stream in 1..=10 {
        subscribe(&mut subscriptions, &store, &writer, stream);
        assert!(
            eventually(|| said(&written).len() == stream as usize),
            "{:?}",
            said(&written)
        );
        assert_eq!(
            said(&written).last().map(String::as_str),
            Some("snapshot-complete"),
            "subscription {stream} was refused: {:?}",
            said(&written)
        );
        let ended = unsubscribe(&mut subscriptions, &store, json!({"stream": stream})).unwrap();
        assert_eq!(ended, json!({"stream": stream, "ended": true}));
        // Its thread has stopped once the daemon's place is back.
        assert!(
            eventually(|| HELD.load(std::sync::atomic::Ordering::SeqCst) == 0),
            "subscription {stream}'s thread still holds its place"
        );
    }
    // Live events reach none of them.
    let before = written.replies().len();
    store
        .hooks()
        .events
        .input(SessionId([7; 16]), Value::Null, None, 3);
    std::thread::sleep(std::time::Duration::from_millis(200));
    assert_eq!(
        written.replies().len(),
        before,
        "an ended subscription was sent to"
    );

    // Once is enough; a stream that never held one isn't an error.
    assert_eq!(
        unsubscribe(&mut subscriptions, &store, json!({"stream": 3})).unwrap(),
        json!({"stream": 3, "ended": false})
    );
    for bad in [
        json!({}),
        json!({"stream": 0}),
        json!({"stream": "7"}),
        json!({"stream": -1}),
    ] {
        let error = unsubscribe(&mut subscriptions, &store, bad.clone()).unwrap_err();
        assert_eq!(error.kind, kind::INVALID_REQUEST, "{bad}");
    }
}

/// A connection whose every write fails, as one whose caller has read nothing for the transport's
/// `WRITE_TIMEOUT` does.
struct TimedOut;

impl std::io::Write for TimedOut {
    fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
        Err(std::io::Error::new(
            std::io::ErrorKind::TimedOut,
            "peer stopped reading",
        ))
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// A subscription whose write fails ends its connection, so its caller sees it drop and asks
/// again with `since`, rather than wait on a stream a half-written envelope has broken.
#[test]
fn a_subscription_whose_write_fails_closes_its_connection() {
    use std::sync::atomic::{AtomicBool, Ordering};
    let store = SessionStore::new();
    let writer: SharedWriter = std::sync::Arc::new(std::sync::Mutex::new(Box::new(TimedOut)));
    let closed = std::sync::Arc::new(AtomicBool::new(false));
    let seen = std::sync::Arc::clone(&closed);
    let mut subscriptions = events::Subscriptions::closing(std::sync::Arc::new(move || {
        seen.store(true, Ordering::SeqCst)
    }));
    subscribe(&mut subscriptions, &store, &writer, 1);
    assert!(
        eventually(|| closed.load(Ordering::SeqCst)),
        "the connection was left open"
    );
}

/// A connection that writes nothing a moment, as a caller that stops reading leaves it.
#[derive(Clone, Default)]
struct Stalled {
    open: std::sync::Arc<(std::sync::Mutex<bool>, std::sync::Condvar)>,
    /// Whether a write has been held, so a test knows its writer is stuck before it goes on.
    held: std::sync::Arc<std::sync::atomic::AtomicBool>,
    written: Written,
}

impl Stalled {
    fn held(&self) -> bool {
        self.held.load(std::sync::atomic::Ordering::SeqCst)
    }
}

impl std::io::Write for Stalled {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let (open, wake) = &*self.open;
        let mut open = open.lock().unwrap();
        while !*open {
            self.held.store(true, std::sync::atomic::Ordering::SeqCst);
            open = wake.wait(open).unwrap();
        }
        self.written.write(bytes)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// A subscriber that stops reading never holds up what makes events: more of them than the daemon
/// keeps are made while its write is stuck, and once it reads again it is told it fell behind,
/// with the state afresh, and goes on from there. Nothing is lost without its saying so.
#[test]
fn a_subscriber_that_stops_reading_slows_nothing_and_is_told_it_lagged() {
    let store = SessionStore::new();
    let stalled = Stalled::default();
    let writer: SharedWriter =
        std::sync::Arc::new(std::sync::Mutex::new(Box::new(stalled.clone())));
    let mut subscriptions = events::Subscriptions::default();
    subscribe(&mut subscriptions, &store, &writer, 1);
    // Its thread has taken the state as it is (at revision 0) and is stuck sending it: events
    // made before then would be in that snapshot, and it would never fall behind.
    assert!(eventually(|| stalled.held()), "the subscriber never wrote");

    let hub = &store.hooks().events;
    let id = crate::terminal::session::SessionId([0x70; 16]);
    let listing = json!({"id": id.to_hyphenated(), "scope": null, "coding_agent": null});
    let started = std::time::Instant::now();
    for _ in 0..crate::terminal::events::RING {
        hub.created(id, listing.clone());
        hub.ended(id, Some(0));
    }
    assert!(
        started.elapsed() < std::time::Duration::from_secs(5),
        "making events waited on the stuck subscriber: {:?}",
        started.elapsed()
    );
    {
        let (open, wake) = &*stalled.open;
        *open.lock().unwrap() = true;
        wake.notify_all();
    }
    assert!(
        eventually(|| said(&stalled.written).len() >= 2),
        "{:?}",
        said(&stalled.written)
    );
    let replies = stalled.written.replies();
    assert_eq!(
        replies[0]["result"]["reason"], "subscribed",
        "{:?}",
        replies[0]
    );
    let lagged = &replies[1]["result"];
    assert_eq!(lagged["event"], "snapshot-complete", "{lagged}");
    assert_eq!(lagged["reason"], "lagged", "{lagged}");
    assert_eq!(
        lagged["revision"],
        2 * crate::terminal::events::RING as u64,
        "{lagged}"
    );
    hub.created(id, listing);
    assert!(eventually(|| said(&stalled.written).len() == 3));
    assert_eq!(
        stalled.written.replies()[2]["result"]["event"],
        "session.created"
    );
}

/// `terminal.send` called as `caller`, as the connection's reader calls it.
fn send_as(store: &SessionStore, caller: Option<&str>, params: Value) -> Result<Value, ApiError> {
    let call = Call {
        sessions: store,
        params: &params,
        caller: caller.map(str::to_string),
    };
    match send::send(&call)? {
        Answer::One(value) => Ok(value),
        Answer::Stream(_) => panic!("a stream from {params}"),
    }
}

/// A send's parameters, its keys and its size are checked before any session is looked for: bad
/// input is `InvalidRequest`, and text past the limit `TooLarge`, whatever the target.
#[test]
fn a_send_with_input_it_cannot_take_is_refused_before_its_target() {
    let store = SessionStore::new();
    for params in [
        json!({}),
        json!({"target": 3, "text": "x"}),
        json!({"target": "x"}),
        json!({"target": "x", "text": ""}),
        json!({"target": "x", "text": 7}),
        json!({"target": "x", "keys": "Enter"}),
        json!({"target": "x", "keys": [1]}),
        json!({"target": "x", "keys": ["Hyper+a"]}),
        json!({"target": "x", "keys": ["Return"]}),
        json!({"target": "x", "enter": "yes"}),
        json!({"target": "x", "text": "x", "allow_self": 1}),
        json!({"target": "x", "text": "ls\u{1b}[201~rm -rf ~\n"}),
        json!({"target": "x", "text": "ls\u{9b}201~rm -rf ~\n"}),
    ] {
        let error = send_as(&store, None, params.clone()).expect_err(&params.to_string());
        assert_eq!(error.kind, kind::INVALID_REQUEST, "{params}: {error:?}");
    }
    let over = json!({"target": "x", "text": "x".repeat(send::MAX_BYTES + 1)});
    assert_eq!(
        send_as(&store, None, over).unwrap_err().kind,
        kind::TOO_LARGE
    );
    let at = json!({"target": "x", "text": "x".repeat(send::MAX_BYTES)});
    assert_eq!(
        send_as(&store, None, at).unwrap_err().kind,
        kind::TARGET_NOT_FOUND
    );
}

/// The caller's own session is refused without `allow_self`, and typed into with it; a send from
/// another session, or from none, is typed. Each one typed is told as `session.input` naming the
/// session it came from, and how many bytes it typed; one refused is not.
#[test]
fn a_send_into_the_callers_own_session_needs_allow_self_and_each_is_told() {
    use crate::terminal::events::{Cursor, Next, Start};
    let store = SessionStore::new();
    let target = sleeping(&store, 0x91).to_hyphenated();
    let other = sleeping(&store, 0x92).to_hyphenated();
    let hub = std::sync::Arc::clone(&store.hooks().events);
    let mut cursor = Cursor::new(Start::Fresh);
    assert!(matches!(
        hub.next(&mut cursor, &|| false),
        Next::Snapshot { .. }
    ));

    let refused = send_as(
        &store,
        Some(&target),
        json!({"target": target, "text": "x"}),
    );
    assert_eq!(refused.unwrap_err().kind, kind::REFUSED_SELF);
    let own = send_as(
        &store,
        Some(&target),
        json!({"target": target, "text": "x", "allow_self": true}),
    )
    .expect("typed with allow_self");
    assert_eq!(own["session"], target.as_str());
    assert_eq!(own["caller"], target.as_str());
    let from_other = send_as(
        &store,
        Some(&other),
        json!({"target": target, "keys": ["Ctrl+A"], "enter": true}),
    );
    let from_none = send_as(&store, None, json!({"target": target, "text": "ab"}));
    if cfg!(feature = "terminal-state") {
        let from_other = from_other.expect("typed from another session");
        assert_eq!(from_other["bytes"], 2, "{from_other}");
        assert_eq!(
            from_other["modes"]["kitty_keyboard_flags"], 0,
            "{from_other}"
        );
    } else {
        // No screen, so no modes to encode keys for.
        assert_eq!(from_other.unwrap_err().kind, kind::INTERNAL_ERROR);
    }
    let from_none = from_none.expect("typed from no session");
    assert_eq!(from_none["caller"], Value::Null);
    assert_eq!(from_none["bytes"], 2);

    let told: Vec<Value> = match hub.next_until(
        &mut cursor,
        &|| false,
        Some(std::time::Instant::now() + std::time::Duration::from_secs(5)),
    ) {
        Next::Events(events) => events.iter().map(|event| event.json.clone()).collect(),
        other => panic!("{other:?}"),
    };
    let senders: Vec<(Value, Value)> = told
        .iter()
        .filter(|event| event["event"] == "session.input")
        .inspect(|event| assert_eq!(event["session"], target.as_str(), "{event}"))
        .map(|event| (event["sender"].clone(), event["bytes"].clone()))
        .collect();
    let mut expected = vec![(json!(target), json!(1))];
    if cfg!(feature = "terminal-state") {
        expected.push((json!(other), json!(2)));
    }
    expected.push((Value::Null, json!(2)));
    assert_eq!(senders, expected, "{told:?}");
    store.kill_all();
}

/// Past the limit counting its keys, a send is refused whole, as `TooLarge`, once its target is
/// known; and while a hand-off holds the events, it is `Busy`, and typed once they are let go.
#[cfg(feature = "terminal-state")]
#[test]
fn a_send_too_large_with_its_keys_or_during_a_hand_off_is_refused() {
    let store = SessionStore::new();
    let target = sleeping(&store, 0x93).to_hyphenated();
    let over = json!({"target": target, "text": "x".repeat(send::MAX_BYTES), "enter": true});
    assert_eq!(
        send_as(&store, None, over).unwrap_err().kind,
        kind::TOO_LARGE
    );

    let hub = std::sync::Arc::clone(&store.hooks().events);
    let _carried = hub.carry();
    let held = send_as(&store, None, json!({"target": target, "text": "x"}));
    assert_eq!(held.unwrap_err().kind, kind::BUSY);
    hub.unseal();
    assert!(send_as(&store, None, json!({"target": target, "text": "x"})).is_ok());
    store.kill_all();
}
