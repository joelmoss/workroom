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
//! `{"revision": REVISION, "result": …, "more": false}` or
//! `{"revision": REVISION, "error": {"kind", "message"}, "more": false}` (the API's number is
//! `revision` everywhere, not the other services' `version`), where `kind` is a code from the same
//! registry every `workroom` command shares (ADR 0013), and an ambiguous target's error lists the
//! sessions it matched under `matches`. Nothing is ever sent unasked, which is what leaves a client
//! that never calls the service unaffected by it.
//!
//! **The caller** (#684) is the session a request comes from: the one whose shell the connecting
//! process descends from (its peer pid, then its parents), else the one its optional `"caller"`
//! names (the pane's `WORKROOM_PANE`, which the CLI sends), when that is one of this daemon's.
//! Results that depend on it say which they found.
//!
//! The namespaces are `session.*`, `terminal.*`, `client.*` and `events.*` (#360), and `api.*`
//! for the API describing itself.
//!
//! **A stream.** A method may answer with several replies on the request's stream, in order, each
//! a whole reply of the shape above. Every reply says whether another follows it (`more`), outside
//! the method's `result`, so a caller reads until `more` is false whatever the method. An error
//! ends a stream. `terminal.capture` with `all` sends a long history this way, so no reply has to
//! hold all of it.

use std::ffi::OsStr;
use std::ops::Range;

use serde_json::{Value, json};

use crate::daemon::rpc::{PartialRequests, SharedWriter};
use crate::terminal::session::{CREATED_KEY, Described, SessionId, SessionStore};
use crate::terminal::shadow::{Capture, Captured, Rows};
use crate::util::lock_or_recover;
use wr_protocol::envelope::{Envelope, Service};
use wr_protocol::terminal::parse_session_id;

/// The terminal API's revision, in every reply and in `api.describe`: raised by each release that
/// adds a method or a field, and never lowered. A caller that needs a later addition checks it.
pub const REVISION: u32 = 1;

/// The variable every session's shell is given its session's id in (#684), outside
/// `WORKROOM_SESSION_*`, which a shell never sees.
pub const PANE_VARIABLE: &str = "WORKROOM_PANE";

/// The variable every session's shell is given its daemon's socket in (#684).
pub const DAEMON_VARIABLE: &str = "WORKROOM_DAEMON";

/// The most text one chunk of a streamed capture carries, in bytes: escaped as JSON, at most six
/// times that, far under a reply's 16 MiB.
pub const CAPTURE_CHUNK_BYTES: usize = 64 * 1024;

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
    /// The session the target named ended before it could be read.
    pub const SESSION_ENDED: &str = "SessionEnded";
    /// Anything else, such as a screen the daemon has no copy of (a build without terminal-state,
    /// or a shadow terminal that failed) or one the formatter could not read.
    pub const INTERNAL_ERROR: &str = "InternalError";
}

/// What a method answers with: one reply, or several on the request's stream, in order. A stream
/// yields at least one result, each made only once the one before it is ready to send, and ends at
/// its first error.
pub enum Answer {
    One(Value),
    Stream(Box<dyn Iterator<Item = Result<Value, ApiError>>>),
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
    run: fn(&Call) -> Result<Answer, ApiError>,
}

/// One request as a method sees it.
pub struct Call<'a> {
    sessions: &'a SessionStore,
    params: &'a Value,
    /// The session the request comes from, hyphenated (`caller`), if it comes from one.
    caller: Option<String>,
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
        run: |call| describe(call).map(Answer::One),
    },
    Method {
        name: "session.list",
        summary: "The sessions that share the caller's scope, oldest first, or with `all: true` \
                  every session the daemon holds.",
        input: || {
            json!({
                "type": "object",
                "properties": {"all": {
                    "type": "boolean",
                    "default": false,
                    "description": "`true` lists every session. `false`, the default, lists the \
                                    sessions that share the caller's scope: every session when \
                                    the request comes from no session, or from one with no scope.",
                }},
            })
        },
        output: || {
            json!({
                "type": "object",
                "required": ["sessions", "caller"],
                "properties": {
                    "sessions": {"type": "array", "items": session_schema()},
                    "caller": caller_schema(),
                },
            })
        },
        errors: &[],
        params_example: || json!({"all": false}),
        result_example: || {
            json!({
                "sessions": [agent_session_example(), run_session_example()],
                "caller": agent_session_example()["id"],
            })
        },
        run: |call| {
            let listing = listed(call.sessions);
            let sessions = match call.params.get("all") {
                Some(Value::Bool(true)) => listing,
                None | Some(Value::Bool(false)) => in_scope_of(listing, call.caller.as_deref()),
                Some(_) => return Err(ApiError::invalid("session.list's `all` is true or false")),
            };
            Ok(Answer::One(
                json!({"sessions": sessions, "caller": call.caller}),
            ))
        },
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
                "required": ["session", "caller"],
                "properties": {"session": session_schema(), "caller": caller_schema()},
            })
        },
        errors: &[kind::TARGET_NOT_FOUND, kind::TARGET_AMBIGUOUS],
        params_example: || json!({"target": "dev server"}),
        result_example: || json!({"session": run_session_example(), "caller": agent_session_example()["id"]}),
        run: |call| {
            let target = call
                .params
                .get("target")
                .and_then(Value::as_str)
                .ok_or_else(|| ApiError::invalid("session.resolve needs a string `target`"))?;
            resolve(&listed(call.sessions), target)
                .map(|session| Answer::One(json!({"session": session, "caller": call.caller})))
        },
    },
    Method {
        name: "terminal.capture",
        summary: "A session's screen as text: the visible screen, trimmed, by default; with `lines`, \
                  that many rows of history above it too; with `all`, the whole scrollback, as \
                  several replies on the request's stream, each a chunk of whole lines (`chunk` \
                  counts from 0, and each reply's `more` says whether another follows). `unwrap` \
                  joins lines the pane \
                  soft-wrapped and `vt` keeps escape codes. Every reply also has the cursor, the \
                  size, whether the alternate screen is up and the live title. The alternate \
                  screen has no history of its own.",
        input: capture_input,
        output: capture_output,
        errors: &[
            kind::TARGET_NOT_FOUND,
            kind::TARGET_AMBIGUOUS,
            kind::SESSION_ENDED,
            kind::INTERNAL_ERROR,
        ],
        params_example: || json!({"target": "dev server", "lines": 100, "unwrap": true}),
        result_example: || {
            json!({
                "session": "c0ffee00-1111-4222-8333-44445555beef",
                "text": "$ npm run dev\n\n> vite\n\n  VITE ready in 312 ms\n  Local: http://localhost:5173/",
                "cursor": {"row": 6, "column": 0},
                "alternate_screen": false,
                "size": {"columns": 80, "rows": 24},
                "title": null,
                "chunk": 0,
            })
        },
        run: capture,
    },
];

/// The `caller` of a result: the session the request came from.
fn caller_schema() -> Value {
    json!({
        "type": ["string", "null"],
        "description": "The id of the session the request comes from: the session whose shell \
                        the connecting process descends from, else the request's `caller` when it \
                        names one of this daemon's sessions. Null for neither.",
    })
}

/// The JSON Schema of a request.
fn request_schema() -> Value {
    json!({
        "type": "object",
        "required": ["method"],
        "properties": {
            "method": {"type": "string", "description": "A method's name, such as `session.list`."},
            "params": {"type": "object", "description": "The method's parameters; `{}` when left out."},
            "caller": {
                "type": "string",
                "description": "The id of the session the request comes from: the caller's \
                                `WORKROOM_PANE`. The daemon finds the caller from the connecting \
                                process first, and uses this only when that process descends from \
                                none of its sessions' shells (a daemonized tmux server's, say).",
            },
        },
    })
}

fn capture_input() -> Value {
    let flag = |description: &str| json!({"type": "boolean", "description": description});
    json!({
        "type": "object",
        "required": ["target"],
        "properties": {
            "target": {
                "type": "string",
                "description": "A session's id or id suffix, its label, or its live title.",
            },
            "lines": {
                "type": "integer",
                "minimum": 0,
                "description": "Rows of history above the visible screen to include.",
            },
            "all": flag("The whole scrollback, streamed in chunks. Not with `lines`."),
            "unwrap": flag("Join lines the pane soft-wrapped."),
            "vt": flag("Keep escape codes (colours, styles) instead of plain text."),
        },
    })
}

fn capture_output() -> Value {
    let count = |description: &str| json!({"type": "integer", "description": description});
    json!({
        "type": "object",
        "required": [
            "session", "text", "cursor", "alternate_screen", "size", "title", "chunk",
        ],
        "properties": {
            "session": {"type": "string", "description": "The id of the session read."},
            "text": {
                "type": "string",
                "description": "The rows, one line each (one per wrapped line with `unwrap`), \
                                without a final newline. With `all`, this reply's chunk: whole \
                                lines, which joined are the text.",
            },
            "cursor": {
                "type": "object",
                "description": "On the visible screen, from 0 at its top left.",
                "required": ["row", "column"],
                "properties": {"row": count("From the top."), "column": count("From the left.")},
            },
            "alternate_screen": {
                "type": "boolean",
                "description": "Whether a full-screen program has the alternate screen up.",
            },
            "size": {
                "type": "object",
                "required": ["columns", "rows"],
                "properties": {"columns": count("Its width."), "rows": count("Its height.")},
            },
            "title": {
                "type": ["string", "null"],
                "description": "The live title its program last set (OSC 0 or 2).",
            },
            "chunk": count(
                "This reply's place among a capture's chunks, from 0; 0 without `all`. The \
                 reply's `more` says whether another follows.",
            ),
        },
    })
}

/// The sessions of `listing` (the listing's shape) that share `caller`'s scope: every one when
/// there is no caller, or the caller has no scope (a session tagged with none).
pub fn in_scope_of(listing: Vec<Value>, caller: Option<&str>) -> Vec<Value> {
    let scope = caller
        .and_then(|caller| listing.iter().find(|session| session["id"] == caller))
        .map(|session| session["scope"].clone())
        .filter(|scope| !scope.is_null());
    match scope {
        None => listing,
        Some(scope) => listing
            .into_iter()
            .filter(|session| session["scope"] == scope)
            .collect(),
    }
}

/// `terminal.capture`: the parameters checked, the target resolved (which reads every session's
/// live title, as `session.list` does), then the screen read under its own shadow lock, taken
/// alone. Only that session's screen is formatted, and its whole scrollback from a copy once that
/// lock is released (`Shadow::capture`).
fn capture(call: &Call) -> Result<Answer, ApiError> {
    let (sessions, params) = (call.sessions, call.params);
    let target = params
        .get("target")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid("terminal.capture needs a string `target`"))?;
    let flag = |name: &str| match params.get(name) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(on)) => Ok(*on),
        Some(_) => Err(ApiError::invalid(format!(
            "terminal.capture's `{name}` is a boolean"
        ))),
    };
    let lines = match params.get("lines") {
        None | Some(Value::Null) => None,
        Some(lines) => Some(
            lines
                .as_u64()
                .and_then(|lines| u32::try_from(lines).ok())
                .ok_or_else(|| {
                    ApiError::invalid("terminal.capture's `lines` is a whole number from 0")
                })?,
        ),
    };
    let (all, unwrap, vt) = (flag("all")?, flag("unwrap")?, flag("vt")?);
    let rows = match (all, lines) {
        (true, Some(_)) => {
            return Err(ApiError::invalid(
                "terminal.capture takes `lines` or `all`, not both",
            ));
        }
        (true, None) => Rows::All,
        (false, None | Some(0)) => Rows::Screen,
        (false, Some(lines)) => Rows::WithHistory(lines),
    };

    let session = resolve(&listed(sessions), target)?;
    let id = session["id"].as_str().unwrap_or_default().to_string();
    let ended = || {
        ApiError::new(
            kind::SESSION_ENDED,
            format!("session {id} ended before it could be read"),
        )
    };
    let shadow = wr_protocol::terminal::parse_session_id(OsStr::new(&id))
        .and_then(|parsed| sessions.shadow(parsed))
        .ok_or_else(ended)?;
    let job = lock_or_recover(&shadow)
        .capture(Capture { rows, unwrap, vt })
        .ok_or_else(|| ApiError::new(kind::INTERNAL_ERROR, no_screen(&id)))?;
    let captured = job().ok_or_else(|| {
        ApiError::new(
            kind::INTERNAL_ERROR,
            format!("session {id}'s screen could not be read"),
        )
    })?;
    let reply = move |captured: &Captured, text: &str, chunk: usize| {
        json!({
            "session": id,
            "text": text,
            "cursor": {"row": captured.cursor.0, "column": captured.cursor.1},
            "alternate_screen": captured.alternate,
            "size": {"columns": captured.size.0, "rows": captured.size.1},
            "title": captured.title,
            "chunk": chunk,
        })
    };
    if !all {
        return Ok(Answer::One(reply(&captured, &captured.text, 0)));
    }
    let pieces = chunks(&captured.text, CAPTURE_CHUNK_BYTES);
    Ok(Answer::Stream(Box::new(
        pieces
            .into_iter()
            .enumerate()
            .map(move |(chunk, range)| Ok(reply(&captured, &captured.text[range], chunk))),
    )))
}

/// Why there is no screen of session `id` to read: the daemon keeps none, or its copy failed.
fn no_screen(id: &str) -> String {
    if cfg!(feature = "terminal-state") {
        format!(
            "this daemon has no copy of session {id}'s screen: its shadow terminal could not be \
             made or has failed"
        )
    } else {
        format!(
            "this daemon has no copy of session {id}'s screen: it was built without \
             terminal-state, so it keeps no shadow terminal"
        )
    }
}

/// `text` cut into pieces of at most `max` bytes, each ending at a newline where one is in reach,
/// else between characters. At least one piece, which an empty text's is.
fn chunks(text: &str, max: usize) -> Vec<Range<usize>> {
    let mut pieces = Vec::new();
    let mut start = 0;
    while text.len() - start > max {
        let mut reach = start + max;
        while !text.is_char_boundary(reach) {
            reach -= 1;
        }
        if reach == start {
            // `max` is narrower than this character: it goes alone.
            reach = start + 1;
            while !text.is_char_boundary(reach) {
                reach += 1;
            }
        }
        let end = text[start..reach]
            .rfind('\n')
            .map_or(reach, |newline| start + newline + 1);
        pieces.push(start..end);
        start = end;
    }
    pieces.push(start..text.len());
    pieces
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
        "required": ["revision", "methods", "error_schema", "request"],
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
            "request": {
                "type": "object",
                "description": "The JSON Schema of a request, for every method.",
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

fn describe(call: &Call) -> Result<Value, ApiError> {
    match call.params.get("method") {
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
    Ok(json!({
        "revision": REVISION,
        "methods": methods,
        "error_schema": error_schema(),
        "request": request_schema(),
    }))
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

/// One request, separated from the transport so tests drive it directly. `peer` is the process
/// that connected, when the transport knows it.
fn handle(sessions: &SessionStore, bytes: &[u8], peer: Option<i32>) -> Result<Answer, ApiError> {
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
    let caller = match request.get("caller") {
        None | Some(Value::Null) => None,
        Some(Value::String(caller)) => Some(caller.as_str()),
        Some(_) => return Err(ApiError::invalid("`caller` is a session's id")),
    };
    (method.run)(&Call {
        sessions,
        params: &params,
        caller: caller_of(sessions, caller, peer).map(|id| id.to_hyphenated()),
    })
}

/// The session a request comes from: the one whose shell `peer` (the connecting process) is or
/// descends from, else the one its `caller` names, when that is one of `sessions`.
///
/// The process goes first because it can't be wrong about where it runs, and a variable can: a
/// process in pane B can carry pane A's `WORKROOM_PANE`, from a shell B's was started from, or a
/// tmux session first attached in A. The name is for a process outside every pane's tree, which
/// the walk can't place: one under a daemonized tmux server, or re-parented to init when its
/// parent exited. A name that is stale there, of a session this daemon no longer holds, is none.
fn caller_of(sessions: &SessionStore, named: Option<&str>, peer: Option<i32>) -> Option<SessionId> {
    peer.and_then(|pid| sessions.session_of_process(pid))
        .or_else(|| {
            named
                .and_then(|named| parse_session_id(std::ffi::OsStr::new(named)))
                .filter(|id| sessions.contains(*id))
        })
}

/// The reply on the wire: the API's `revision`, then its `result` or its `error`, and whether
/// `more` replies follow it on the stream. Not `wr_protocol::reply::Reply`, whose number is
/// `version`: this API's is `revision` everywhere. An error is always a stream's last reply.
fn reply(result: Result<Value, ApiError>, more: bool) -> Value {
    match result {
        Ok(result) => json!({"revision": REVISION, "result": result, "more": more}),
        Err(error) => json!({"revision": REVISION, "error": error.json(), "more": false}),
    }
}

/// Answers one envelope on its own stream.
pub fn dispatch(
    partial: &mut PartialRequests,
    envelope: &Envelope,
    sessions: &SessionStore,
    peer: Option<i32>,
    writer: &SharedWriter,
) {
    // Stream 0 belongs to the daemon, never to a request.
    if envelope.stream == 0 {
        return;
    }
    // Whether the reply went out: a client that hung up (`| head`) ends a stream.
    let send = |value: Value| {
        crate::daemon::rpc::send_with(writer, Service::TerminalApi, envelope.stream, value, || {
            reply(
                Err(ApiError::new(kind::TOO_LARGE, "the reply is over 16 MiB")),
                false,
            )
        })
    };
    match crate::daemon::rpc::reassemble(partial, envelope) {
        Ok(Some(bytes)) => match handle(sessions, &bytes, peer) {
            Ok(Answer::One(result)) => {
                send(reply(Ok(result), false));
            }
            Ok(Answer::Stream(results)) => stream(results, send),
            Err(error) => {
                send(reply(Err(error), false));
            }
        },
        Ok(None) => {}
        Err(error) => {
            send(reply(
                Err(ApiError::new(kind::TOO_LARGE, error.to_string())),
                false,
            ));
        }
    }
}

/// Sends each of `results` as it is made, each saying whether `more` follow, until the last, the
/// first error, or a send that fails, which drops the rest unmade.
fn stream(
    results: Box<dyn Iterator<Item = Result<Value, ApiError>>>,
    send: impl Fn(Value) -> bool,
) {
    let mut results = results.peekable();
    let Some(mut result) = results.next() else {
        send(reply(
            Err(ApiError::new(
                kind::INTERNAL_ERROR,
                "the method replied with nothing",
            )),
            false,
        ));
        return;
    };
    loop {
        let more = result.is_ok() && results.peek().is_some();
        if !send(reply(result, more)) || !more {
            return;
        }
        result = results.next().expect("peeked");
    }
}

#[cfg(test)]
mod tests;
