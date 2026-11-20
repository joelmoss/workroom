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
    handle(store, &serde_json::to_vec(&request).unwrap())
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
        json!({"method": "api.describe", "params": {"method": "x.y"}}),
    ] {
        let error = request(&store, bad.clone()).expect_err(&bad.to_string());
        assert_eq!(error.kind, kind::INVALID_REQUEST, "{bad}");
    }
    assert!(handle(&store, b"not json").is_err());
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
    assert_eq!(names, ["api.describe", "session.list", "session.resolve"]);
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

#[test]
fn an_empty_daemon_lists_no_sessions_and_resolves_nothing() {
    let store = SessionStore::new();
    assert_eq!(
        request(&store, json!({"method": "session.list"})).unwrap(),
        json!({"sessions": []})
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
    let wire = reply(Err(error));
    assert_eq!(wire["revision"], REVISION);
    assert_eq!(wire["error"]["kind"], "TargetAmbiguous");
    assert_eq!(wire["error"]["matches"].as_array().unwrap().len(), 2);
    let plain = reply(Err(ApiError::invalid("bad")));
    assert_eq!(
        plain,
        json!({"revision": REVISION, "error": {"kind": "InvalidRequest", "message": "bad"}})
    );
    assert_eq!(
        reply(Ok(json!({"sessions": []}))),
        json!({"revision": REVISION, "result": {"sessions": []}})
    );
}
