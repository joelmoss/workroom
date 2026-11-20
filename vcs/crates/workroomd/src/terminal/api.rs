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
//! `{"version": REVISION, "result": …}` or `{"version": REVISION, "error": {"kind", "message"}}`,
//! where `kind` is a code from the same registry every `workroom` command shares (ADR 0013), and an
//! ambiguous target's error lists the sessions it matched under `matches`. Nothing is ever sent
//! unasked, which is what leaves a client that never calls the service unaffected by it.
//!
//! The namespaces are `session.*`, `terminal.*`, `client.*` and `events.*` (#360), and `api.*`
//! for the API describing itself.

use serde_json::{Value, json};

use crate::daemon::rpc::{PartialRequests, SharedWriter};
use crate::terminal::session::{CREATED_KEY, Described, SessionStore};
use wr_protocol::envelope::{Envelope, Service};
use wr_protocol::reply::Reply;

/// The terminal API's revision, in every reply and in `api.describe`: raised by each release that
/// adds a method or a field, and never lowered. A caller that needs a later addition checks it.
pub const REVISION: u32 = 1;

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
    /// A `params` it accepts, for `api.describe`.
    pub example: fn() -> Value,
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
        example: || json!({"method": "session.list"}),
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
        example: || json!({}),
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
        example: || json!({"target": "dev server"}),
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
        "required": ["revision", "methods", "error"],
        "properties": {
            "revision": {
                "type": "integer",
                "description": "Raised by each release that adds a method or a field.",
            },
            "methods": {"type": "array", "items": {
                "type": "object",
                "required": ["name", "summary", "input", "output", "errors", "example"],
                "properties": {
                    "name": {"type": "string"},
                    "summary": {"type": "string"},
                    "input": {"type": "object", "description": "The JSON Schema of `params`."},
                    "output": {"type": "object", "description": "The JSON Schema of `result`."},
                    "errors": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Error kinds beyond InvalidRequest, which any method has.",
                    },
                    "example": {"type": "object", "description": "A `params` it accepts."},
                },
            }},
            "error": {
                "type": "object",
                "description": "The JSON Schema of a failed reply's `error`, for every method.",
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

/// The `error` of a failed reply.
pub fn error_schema() -> Value {
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
    let wanted = match params.get("method") {
        None => None,
        Some(Value::String(name)) => Some(name.as_str()),
        Some(_) => return Err(ApiError::invalid("api.describe's `method` is a string")),
    };
    let methods: Vec<Value> = METHODS
        .iter()
        .filter(|method| wanted.is_none_or(|name| method.name == name))
        .map(|method| {
            json!({
                "name": method.name,
                "summary": method.summary,
                "input": (method.input)(),
                "output": (method.output)(),
                "errors": method.errors,
                "example": (method.example)(),
            })
        })
        .collect();
    if let (Some(name), true) = (wanted, methods.is_empty()) {
        return Err(ApiError::invalid(format!("no method {name:?}")));
    }
    Ok(json!({"revision": REVISION, "methods": methods, "error": error_schema()}))
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

fn reply(result: Result<Value, ApiError>) -> Value {
    json!(Reply::new(REVISION, result.map_err(|error| error.json())))
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
            ApiError::new(kind::TOO_LARGE, "the reply is over 16 MiB").json()
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
