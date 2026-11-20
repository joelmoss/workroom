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
    let first = CaptureSlot::acquire_from(&HELD, 2).expect("a place");
    let second = CaptureSlot::acquire_from(&HELD, 2).expect("a place");
    assert!(CaptureSlot::acquire_from(&HELD, 2).is_none());
    drop(first);
    let third = CaptureSlot::acquire_from(&HELD, 2).expect("a place once one ended");
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
            "terminal.capture"
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
