//! `Service::TerminalApi`: the terminal API (#360, ADR 0079), the daemon's public, versioned JSON
//! service for coding agents and the user's scripts. The `workroom` commands are thin clients of
//! it (`commands::terminal_api`); the app never sends it.
//!
//! **A contract, not an internal wire.** Fields and methods are only ever added; none is removed,
//! renamed or given another meaning. [`REVISION`] counts the additions, and every reply carries
//! it. Each method publishes the JSON Schema of its parameters and its result ([`METHODS`],
//! served by `api.describe`), so a caller can find out what a daemon supports without docs.
//!
//! Requests are JSON on the chunked request/reply envelope (`rpc::reassemble`, `rpc::send`), one
//! stream each: `{"method": "<namespace>.<name>", "params": {…}}`, `params` optional. The reply is
//! `{"revision": REVISION, "result": …}` or `{"revision": REVISION, "error": {"kind", "message"}}`
//! (the API's number is `revision` everywhere, not the other services' `version`), where `kind` is a code from the same registry every `workroom` command shares (ADR 0013), and an
//! ambiguous target's error lists the sessions it matched under `matches`. Nothing is ever sent
//! unasked, which is what leaves a client that never calls the service unaffected by it.
//!
//! The namespaces are `session.*`, `terminal.*`, `client.*` and `events.*` (#360), and `api.*`
//! for the API describing itself.

use serde_json::{Value, json};

use crate::daemon::rpc::{PartialRequests, SharedWriter};
use crate::terminal::session::{CREATED_KEY, Described, SessionStore};
use wr_protocol::envelope::{Envelope, Service};

/// The terminal API's revision, in every reply and in `api.describe`: raised by each release that
/// adds a method or a field, and never lowered. A caller that needs a later addition checks it.
pub const REVISION: u32 = 1;

/// The variable every session's shell is given its session's id in (#684), outside
/// `WORKROOM_SESSION_*`, which a shell never sees.
pub const PANE_VARIABLE: &str = "WORKROOM_PANE";

/// The variable every session's shell is given its daemon's socket in (#684).
pub const DAEMON_VARIABLE: &str = "WORKROOM_DAEMON";

/// The shortest id suffix a target resolves by, so that a short word is never read as an id.
pub const MIN_SUFFIX: usize = 4;

/// The error codes this service replies with: the shared registry's (`commands::kind`), by name.
pub mod kind {
    /// No session matches the target.
    pub const TARGET_NOT_FOUND: &str = "TargetNotFound";
    /// More than one session matches the target; the error lists them.
    pub const TARGET_AMBIGUOUS: &str = "TargetAmbiguous";
    /// The request is not JSON, names no method this daemon has, or its parameters are wrong.
    pub const INVALID_REQUEST: &str = "InvalidRequest";
    /// The request or its reply is over the service's limit.
    pub const TOO_LARGE: &str = "TooLarge";
}

/// Why a request failed, as its reply's `error` carries it.
#[derive(Debug, Clone, PartialEq)]
pub struct ApiError {
    pub kind: &'static str,
    pub message: String,
    /// The sessions an ambiguous target matched, in the listing's shape.
    pub matches: Vec<Value>,
}

impl ApiError {
    fn new(kind: &'static str, message: impl Into<String>) -> ApiError {
        ApiError {
            kind,
            message: message.into(),
            matches: Vec::new(),
        }
    }

    fn invalid(message: impl Into<String>) -> ApiError {
        ApiError::new(kind::INVALID_REQUEST, message)
    }

    fn json(&self) -> Value {
        let mut error = json!({"kind": self.kind, "message": self.message});
        if !self.matches.is_empty() {
            error["matches"] = Value::Array(self.matches.clone());
        }
        error
    }
}

/// One method: its name, what it does, its schemas and how it runs.
pub struct Method {
    pub name: &'static str,
    pub summary: &'static str,
    /// The JSON Schema of its `params`.
    pub input: fn() -> Value,
    /// The JSON Schema of its `result`.
    pub output: fn() -> Value,
    /// The error kinds it can reply with, beyond `InvalidRequest`, which any method can.
    pub errors: &'static [&'static str],
    /// A `params` it accepts, which `api.describe` lists under the input schema's `examples`.
    pub params_example: fn() -> Value,
    /// A `result` it replies with, which `api.describe` lists under the output schema's `examples`.
    pub result_example: fn() -> Value,
    run: fn(&SessionStore, &Value) -> Result<Value, ApiError>,
}

/// Every method, in `api.describe`'s order.
pub const METHODS: &[Method] = &[
    Method {
        name: "api.describe",
        summary: "This API's revision and every method's parameter and result schemas, or one \
                  method's when `method` names it.",
        input: describe_input,
        output: describe_output,
        errors: &[],
        params_example: || json!({"method": "session.list"}),
        // The real description of the method `params_example` names, so it can't drift from what
        // `api.describe` replies. Never this method's or every method's: each would hold this
        // example again, without end.
        result_example: || {
            description(Some("session.list")).expect("session.list is a method to describe")
        },
        run: describe,
    },
    Method {
        name: "session.list",
        summary: "Every session the daemon holds, oldest first.",
        input: empty_input,
        output: || {
            json!({
                "type": "object",
                "required": ["sessions"],
                "properties": {"sessions": {"type": "array", "items": session_schema()}},
            })
        },
        errors: &[],
        params_example: || json!({}),
        result_example: || json!({"sessions": [agent_session_example(), run_session_example()]}),
        run: |sessions, _| Ok(json!({"sessions": listed(sessions)})),
    },
    Method {
        name: "session.resolve",
        summary: "The one session a target names: by full id, then an id suffix of at least 4 \
                  characters, then label, then live title. Several matches at the first step that \
                  has any is `TargetAmbiguous`, listing them.",
        input: || {
            json!({
                "type": "object",
                "required": ["target"],
                "properties": {"target": {
                    "type": "string",
                    "description": "A session's id or id suffix, its label, or its live title.",
                }},
            })
        },
        output: || {
            json!({
                "type": "object",
                "required": ["session"],
                "properties": {"session": session_schema()},
            })
        },
        errors: &[kind::TARGET_NOT_FOUND, kind::TARGET_AMBIGUOUS],
        params_example: || json!({"target": "dev server"}),
        result_example: || json!({"session": run_session_example()}),
        run: |sessions, params| {
            let target = params
                .get("target")
                .and_then(Value::as_str)
                .ok_or_else(|| ApiError::invalid("session.resolve needs a string `target`"))?;
            resolve(&listed(sessions), target).map(|session| json!({"session": session}))
        },
    },
];

fn empty_input() -> Value {
    json!({"type": "object", "properties": {}})
}

fn describe_input() -> Value {
    json!({
        "type": "object",
        "properties": {"method": {
            "type": "string",
            "description": "One method to describe; every method when left out.",
        }},
    })
}

fn describe_output() -> Value {
    json!({
        "type": "object",
        "required": ["revision", "methods", "error_schema"],
        "properties": {
            "revision": {
                "type": "integer",
                "description": "Raised by each release that adds a method or a field.",
            },
            "methods": {"type": "array", "items": {
                "type": "object",
                "required": ["name", "summary", "input", "output", "errors"],
                "properties": {
                    "name": {"type": "string"},
                    "summary": {"type": "string"},
                    "input": {
                        "type": "object",
                        "description": "The JSON Schema of `params`, with a `params` it accepts \
                                        under `examples`.",
                    },
                    "output": {
                        "type": "object",
                        "description": "The JSON Schema of `result`, with a `result` it replies \
                                        with under `examples`.",
                    },
                    "errors": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Error kinds beyond InvalidRequest, which any method has.",
                    },
                },
            }},
            "error_schema": {
                "type": "object",
                "description": "The JSON Schema of a failed reply's `error`, for every method, \
                                with errors under `examples`. Named `error_schema`, since an \
                                `error` is only ever a failure.",
            },
        },
    })
}

/// One session in every reply that lists sessions.
pub fn session_schema() -> Value {
    let text_or_null =
        |description: &str| json!({"type": ["string", "null"], "description": description});
    json!({
        "type": "object",
        "required": ["id", "label", "title", "scope", "run", "cwd", "coding_agent"],
        "properties": {
            "id": {"type": "string", "description": "The session's id, a hyphenated UUID."},
            "label": text_or_null("The name the app gave the session: its tab's name."),
            "title": text_or_null("The live title its program last set (OSC 0 or 2)."),
            "scope": {
                "type": ["object", "null"],
                "description": "What the session belongs to; null for none. `kind` is `workroom` \
                                today, and others may be added.",
                "required": ["kind", "id"],
                "properties": {
                    "kind": {"type": "string"},
                    "id": {"type": "string", "description": "The workroom, as the app tags it."},
                },
            },
            "run": {"type": "boolean", "description": "Whether it is a run session."},
            "cwd": text_or_null("The working directory of its foreground program."),
            "coding_agent": {
                "type": ["object", "null"],
                "description": "What its program last said through program status (OSC 7501): \
                                the newest report waiting on the user, else the newest. Null with \
                                none.",
                "required": ["state", "app", "message", "waiting_on_user"],
                "properties": {
                    "state": {
                        "type": "string",
                        "enum": ["idle", "working", "done", "blocked", "error"],
                    },
                    "app": {"type": "string", "description": "The program, such as `claude`."},
                    "message": {"type": "string"},
                    "waiting_on_user": {
                        "type": "boolean",
                        "description": "Whether a report is blocked on the user.",
                    },
                },
            },
        },
    })
}

/// A session running a coding agent that is waiting on the user, as the examples show one.
fn agent_session_example() -> Value {
    json!({
        "id": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
        "label": "claude",
        "title": "Fix the login test",
        "scope": {"kind": "workroom", "id": "4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e"},
        "run": false,
        "cwd": "/Users/you/workrooms/swift-meadow",
        "coding_agent": {
            "state": "blocked",
            "app": "claude",
            "message": "Allow `npm test`?",
            "waiting_on_user": true,
        },
    })
}

/// A run session with no coding agent, as the examples show one.
fn run_session_example() -> Value {
    json!({
        "id": "c0ffee00-1111-4222-8333-44445555beef",
        "label": "dev server",
        "title": null,
        "scope": {"kind": "workroom", "id": "4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e"},
        "run": true,
        "cwd": "/Users/you/workrooms/swift-meadow",
        "coding_agent": null,
    })
}

/// `schema` with `examples`, JSON Schema's keyword for values it accepts, as `api.describe`
/// publishes it.
fn with_examples(mut schema: Value, examples: Vec<Value>) -> Value {
    schema["examples"] = Value::Array(examples);
    schema
}

/// The `error` of a failed reply.
pub fn error_schema() -> Value {
    // Two sessions the one label names.
    let matches: Vec<Value> = [agent_session_example(), run_session_example()]
        .into_iter()
        .map(|mut session| {
            session["label"] = json!("tests");
            session
        })
        .collect();
    with_examples(
        error_fields(),
        vec![
            json!({"kind": kind::TARGET_NOT_FOUND, "message": "no session matches \"dev\""}),
            json!({
                "kind": kind::TARGET_AMBIGUOUS,
                "message": "\"tests\" matches 2 sessions; name one by its id",
                "matches": matches,
            }),
        ],
    )
}

fn error_fields() -> Value {
    json!({
        "type": "object",
        "required": ["kind", "message"],
        "properties": {
            "kind": {"type": "string", "description": "A stable code from the `workroom` registry."},
            "message": {"type": "string"},
            "matches": {
                "type": "array",
                "items": session_schema(),
                "description": "The sessions an ambiguous target matched.",
            },
        },
    })
}

fn describe(_sessions: &SessionStore, params: &Value) -> Result<Value, ApiError> {
    match params.get("method") {
        None => description(None),
        Some(Value::String(name)) => description(Some(name)),
        Some(_) => Err(ApiError::invalid("api.describe's `method` is a string")),
    }
}

/// `api.describe`'s result: the method `wanted` names, or every method when it names none.
fn description(wanted: Option<&str>) -> Result<Value, ApiError> {
    let methods: Vec<Value> = METHODS
        .iter()
        .filter(|method| wanted.is_none_or(|name| method.name == name))
        .map(|method| {
            json!({
                "name": method.name,
                "summary": method.summary,
                "input": with_examples((method.input)(), vec![(method.params_example)()]),
                "output": with_examples((method.output)(), vec![(method.result_example)()]),
                "errors": method.errors,
            })
        })
        .collect();
    if let (Some(name), true) = (wanted, methods.is_empty()) {
        return Err(ApiError::invalid(format!("no method {name:?}")));
    }
    Ok(json!({"revision": REVISION, "methods": methods, "error_schema": error_schema()}))
}

/// Every session in the listing's shape, oldest first.
fn listed(sessions: &SessionStore) -> Vec<Value> {
    let mut described = sessions.described();
    let created = |session: &Described| {
        metadata(session, CREATED_KEY)
            .and_then(|created| created.parse::<u64>().ok())
            .unwrap_or(u64::MAX)
    };
    described.sort_by_key(|session| (created(session), session.info.id));
    described.iter().map(session_json).collect()
}

fn metadata<'a>(session: &'a Described, key: &str) -> Option<&'a str> {
    session
        .info
        .metadata
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, value)| value.as_str())
}

fn session_json(session: &Described) -> Value {
    json!({
        "id": session.info.id.to_hyphenated(),
        "label": metadata(session, "title"),
        "title": session.title,
        "scope": metadata(session, "workroom").map(|workroom| json!({"kind": "workroom", "id": workroom})),
        "run": crate::terminal::run::is_run(&session.info.metadata),
        "cwd": session.info.cwd,
        "coding_agent": session.coding_agent,
    })
}

/// The one session in `sessions` (the listing's shape) that `target` names: by full id, then an id
/// suffix of at least `MIN_SUFFIX` characters, then label, then live title. The first step with
/// any match decides; more than one match there is ambiguous, and nothing is chosen.
pub fn resolve(sessions: &[Value], target: &str) -> Result<Value, ApiError> {
    let field = |session: &Value, key: &str| session[key].as_str().map(str::to_string);
    // Ids compare in lower case without hyphens, so a suffix may be typed either way.
    let bare = |text: &str| text.to_ascii_lowercase().replace('-', "");
    let wanted = bare(target);
    let id = |session: &Value| field(session, "id").map(|id| bare(&id)).unwrap_or_default();
    let steps: [&dyn Fn(&Value) -> bool; 4] = [
        &|session| !wanted.is_empty() && id(session) == wanted,
        &|session| wanted.len() >= MIN_SUFFIX && id(session).ends_with(&wanted),
        &|session| field(session, "label").as_deref() == Some(target),
        &|session| field(session, "title").as_deref() == Some(target),
    ];
    for step in steps {
        let matches: Vec<&Value> = sessions.iter().filter(|session| step(session)).collect();
        match matches.as_slice() {
            [] => continue,
            [one] => return Ok((*one).clone()),
            several => {
                return Err(ApiError {
                    kind: kind::TARGET_AMBIGUOUS,
                    message: format!(
                        "{target:?} matches {} sessions; name one by its id",
                        several.len()
                    ),
                    matches: several.iter().map(|session| (*session).clone()).collect(),
                });
            }
        }
    }
    Err(ApiError::new(
        kind::TARGET_NOT_FOUND,
        format!("no session matches {target:?}"),
    ))
}

/// One request, separated from the transport so tests drive it directly.
fn handle(sessions: &SessionStore, bytes: &[u8]) -> Result<Value, ApiError> {
    let request: Value = serde_json::from_slice(bytes)
        .map_err(|_| ApiError::invalid("a terminal API request is a JSON object"))?;
    let name = request
        .get("method")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid("a terminal API request names its `method`"))?;
    let method = METHODS
        .iter()
        .find(|method| method.name == name)
        .ok_or_else(|| ApiError::invalid(format!("this daemon has no method {name:?}")))?;
    let params = match request.get("params") {
        None | Some(Value::Null) => json!({}),
        Some(params @ Value::Object(_)) => params.clone(),
        Some(_) => return Err(ApiError::invalid("`params` is a JSON object")),
    };
    (method.run)(sessions, &params)
}

/// The reply on the wire: the API's `revision`, then its `result` or its `error`. Not
/// `wr_protocol::reply::Reply`, whose number is `version`: this API's is `revision` everywhere.
fn reply(result: Result<Value, ApiError>) -> Value {
    match result {
        Ok(result) => json!({"revision": REVISION, "result": result}),
        Err(error) => json!({"revision": REVISION, "error": error.json()}),
    }
}

/// Answers one envelope on its own stream.
pub fn dispatch(
    partial: &mut PartialRequests,
    envelope: &Envelope,
    sessions: &SessionStore,
    writer: &SharedWriter,
) {
    // Stream 0 belongs to the daemon, never to a request.
    if envelope.stream == 0 {
        return;
    }
    let send = |value: Value| {
        crate::daemon::rpc::send_with(writer, Service::TerminalApi, envelope.stream, value, || {
            reply(Err(ApiError::new(
                kind::TOO_LARGE,
                "the reply is over 16 MiB",
            )))
        })
    };
    match crate::daemon::rpc::reassemble(partial, envelope) {
        Ok(Some(bytes)) => send(reply(handle(sessions, &bytes))),
        Ok(None) => {}
        Err(error) => send(reply(Err(ApiError::new(
            kind::TOO_LARGE,
            error.to_string(),
        )))),
    }
}

#[cfg(test)]
mod tests;
