//! `events.subscribe` (#687): the daemon's events as a stream of replies, on the request's own
//! stream, from a thread of its own, so the connection goes on taking requests. The events and
//! their numbering are `crate::terminal::events`'.
//!
//! The stream starts with the state as it is (one `session` per session, then
//! `snapshot-complete`), or with `resumed` when `since` names a place this daemon still holds, and
//! goes on with live events, each reply's `more` true. It ends only when the caller hangs up, or
//! the daemon goes (a hand-off's included, after which a caller asks the next program with
//! `since`). A snapshot later in a stream says events were dropped: the caller fell further behind
//! than the daemon keeps, and the snapshot replaces what it knew.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use serde_json::{Value, json};

use super::{ApiError, Call, Slot, kind, listed, resolve};
use crate::daemon::rpc::SharedWriter;
use crate::daemon::transport::Closer;
use crate::terminal::events::{Cursor, Known, Next, Start, name, session_event};

pub const NAME: &str = "events.subscribe";

/// The most subscriptions held at once: from one connection, and on the whole daemon. Each is a
/// thread, so they are bounded; one past a bound is refused with `Busy` rather than queued, and a
/// retry once one has ended can succeed. Implementation limits, not contract (ADR 0079).
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub connection: usize,
    pub daemon: usize,
}

pub const LIMITS: Limits = Limits {
    connection: 8,
    daemon: 64,
};

/// The daemon's subscriptions, each holding a `Slot` of `LIMITS.daemon` until its thread ends.
static SUBSCRIPTIONS: AtomicUsize = AtomicUsize::new(0);

/// One connection's subscriptions, ended when it closes: a caller that has gone away is sent to by
/// nobody.
pub struct Subscriptions {
    held: Vec<Arc<AtomicBool>>,
    limits: Limits,
    daemon: &'static AtomicUsize,
    /// The hub they wait on, for closing to wake them: the store's, set by the first.
    hub: Option<Arc<crate::terminal::events::Hub>>,
    /// Ends the connection, which a subscription whose write fails calls: a write fails once its
    /// caller has read nothing for the transport's `WRITE_TIMEOUT`, and may leave part of an
    /// envelope behind it, so the stream can't go on. Its caller sees the connection drop and asks
    /// again with `since`.
    closer: Option<Closer>,
}

impl Default for Subscriptions {
    fn default() -> Subscriptions {
        Subscriptions {
            held: Vec::new(),
            limits: LIMITS,
            daemon: &SUBSCRIPTIONS,
            hub: None,
            closer: None,
        }
    }
}

impl Subscriptions {
    /// A connection's subscriptions, whose failed writes end it with `closer`.
    pub fn closing(closer: Closer) -> Subscriptions {
        let mut subscriptions = Subscriptions::default();
        subscriptions.closer = Some(closer);
        subscriptions
    }

    /// A connection's subscriptions under `limits`, counted against `daemon`, so a test reaches
    /// each bound with a few and its own counter.
    #[cfg(test)]
    pub fn with(limits: Limits, daemon: &'static AtomicUsize) -> Subscriptions {
        let mut subscriptions = Subscriptions::default();
        subscriptions.limits = limits;
        subscriptions.daemon = daemon;
        subscriptions
    }
}

impl Drop for Subscriptions {
    fn drop(&mut self) {
        for closed in &self.held {
            closed.store(true, Ordering::SeqCst);
        }
        // Every subscription on the store shares the hub's wake, so each sees its own flag.
        if let Some(hub) = &self.hub {
            hub.wake();
        }
    }
}

/// What a subscription is sent: events of one session, of one scope and of some types.
#[derive(Debug, Clone, Default, PartialEq)]
struct Filter {
    /// A session's id, hyphenated.
    session: Option<String>,
    /// A scope, as a session's `scope` is: `{kind, id}`.
    scope: Option<Value>,
    /// Live event names; every one when `None`.
    types: Option<Vec<String>>,
}

impl Filter {
    /// Whether an event about a session (its `session` and `scope`), named `event`, is sent.
    /// `snapshot` events (a snapshot's sessions) are sent whatever `types` names.
    fn passes(&self, event: &Value, snapshot: bool) -> bool {
        let session = self
            .session
            .as_ref()
            .is_none_or(|id| event["session"] == *id.as_str());
        let scope = self
            .scope
            .as_ref()
            .is_none_or(|scope| event["scope"] == *scope);
        let named = snapshot
            || self.types.as_ref().is_none_or(|types| {
                event["event"]
                    .as_str()
                    .is_some_and(|name| types.iter().any(|wanted| wanted == name))
            });
        session && scope && named
    }
}

pub fn input() -> Value {
    json!({
        "type": "object",
        "properties": {
            "workroom": {
                "type": "string",
                "description": "Only the sessions of this workroom (a session's `scope.id`). By \
                                default, the caller's scope: the caller's workroom's sessions, or \
                                every session when the request comes from no session, or from \
                                one with no scope. Not with `all`.",
            },
            "all": {
                "type": "boolean",
                "default": false,
                "description": "`true`: every session's events, whatever the caller's scope.",
            },
            "session": {
                "type": "string",
                "description": "Only this session's events: a target, as `session.resolve` takes \
                                it, resolved once as the subscription starts.",
            },
            "types": {
                "type": "array",
                "items": {"type": "string", "enum": name::LIVE},
                "description": "Only live events of these types; every type when left out. A \
                                snapshot's sessions, `snapshot-complete` and `resumed` are always \
                                sent.",
            },
            "since": {
                "type": "object",
                "required": ["boot", "revision"],
                "description": "Resume after the last event the caller had: its `boot` and \
                                `revision`. Answered `resumed`, then every event after it that \
                                the filters pass, when this daemon still holds them (a hand-off \
                                keeps them); else a snapshot whose `snapshot-complete` says \
                                `gap`.",
                "properties": {
                    "boot": {"type": "string"},
                    "revision": {"type": "integer", "minimum": 0},
                },
            },
        },
    })
}

pub fn output() -> Value {
    let text_or_null =
        |description: &str| json!({"type": ["string", "null"], "description": description});
    let mut names: Vec<&str> = vec![name::SESSION, name::SNAPSHOT_COMPLETE, name::RESUMED];
    names.extend(name::LIVE);
    let session = super::session_schema();
    json!({
        "type": "object",
        "required": ["event", "boot", "revision"],
        "description": "One event. Every one has `event`, `boot` and `revision`; the others are \
                        those its `event` carries, as each field says. Callers ignore an `event` \
                        they don't know: later revisions add more.",
        "properties": {
            "event": {
                "type": "string",
                "enum": names,
                "description": "`session`: one session as it is, in a snapshot. \
                                `snapshot-complete`: the snapshot's end; live events follow. \
                                `resumed`: the subscription went on after `since`; live events \
                                follow. `session.created`, `session.ended`, \
                                `session.program_status` (its coding agent's state, program or \
                                waiting on the user changed, or its message did while it isn't \
                                working) and `session.run_state` (each transition of a run, \
                                passing ones included): live events.",
            },
            "boot": {
                "type": "string",
                "description": "Names this daemon's numbering of events: kept across a \
                                hand-off, new when the daemon starts afresh.",
            },
            "revision": {
                "type": "integer",
                "description": "The event's place in its boot's numbering, daemon-wide, from 1: \
                                each live event's is higher than any before it, but a filtered \
                                stream skips those it doesn't pass, so it is not consecutive. A \
                                snapshot's sessions and its `snapshot-complete` have the revision \
                                the snapshot was taken at, `resumed` the one it resumed after. \
                                Not the reply's `revision`, the API's own, which it sits inside.",
            },
            "session": {
                "type": "string",
                "description": "The session's id: every event but `snapshot-complete` and \
                                `resumed`.",
            },
            "scope": {
                "type": ["object", "null"],
                "description": "The session's scope, as `session.list` gives it.",
            },
            "label": text_or_null("`session` and `session.created`: as `session.list` gives it."),
            "title": text_or_null("`session` and `session.created`: as `session.list` gives it."),
            "run": {
                "type": "boolean",
                "description": "`session` and `session.created`: whether it is a run session.",
            },
            "cwd": text_or_null("`session` and `session.created`: as `session.list` gives it."),
            "coding_agent": {
                "type": ["object", "null"],
                "description": "`session`, `session.created` and `session.program_status`: as \
                                `session.list` gives it.",
                "properties": session["properties"]["coding_agent"]["properties"],
            },
            "run_state": {
                "type": ["string", "null"],
                "enum": run_states(),
                "description": "`session` and `session.created`: the run's state, null before \
                                its first or for a session that isn't a run; \
                                `session.run_state`: the state it moved to.",
            },
            "exit_code": {
                "type": ["integer", "null"],
                "description": "`session` and `session.run_state`: the run's exit code, when it \
                                exited; `session.ended`: the shell's, when the daemon saw it.",
            },
            "sessions": {
                "type": "array",
                "items": {"type": "string"},
                "description": "`snapshot-complete`: the ids of the snapshot's sessions.",
            },
            "reason": {
                "type": "string",
                "enum": ["subscribed", "lagged", "gap"],
                "description": "`snapshot-complete`: why the snapshot was sent. `subscribed`: \
                                the subscription started. `lagged`: the caller fell further \
                                behind than the daemon keeps, and events it was never sent were \
                                dropped. `gap`: `since` named a place this daemon doesn't hold \
                                (another boot's, or older than it keeps). After either of the \
                                last two, the snapshot replaces what the caller knew.",
            },
        },
    })
}

fn run_states() -> Vec<Value> {
    crate::terminal::wait::RunState::ALL
        .iter()
        .map(|state| json!(state.name()))
        .chain([Value::Null])
        .collect()
}

pub const ERRORS: &[&str] = &[
    kind::TARGET_NOT_FOUND,
    kind::TARGET_AMBIGUOUS,
    kind::BUSY,
    kind::INTERNAL_ERROR,
];

pub fn params_example() -> Value {
    json!({"types": ["session.program_status", "session.run_state"]})
}

pub fn result_example() -> Value {
    json!({
        "event": name::PROGRAM_STATUS,
        "boot": "9b2f6c1e-3d4a-4f5b-8c6d-7e8f9a0b1c2d",
        "revision": 42,
        "session": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
        "scope": {"kind": "workroom", "id": "4c0f5f2e-2b49-4c4d-9c1e-6a1b2b3c0d4e"},
        "coding_agent": {
            "state": "blocked",
            "app": "claude",
            "message": "Allow `npm test`?",
            "waiting_on_user": true,
        },
    })
}

/// Starts the subscription `params` asks for, answering on `stream` now when it is refused, else
/// from its own thread, for as long as the caller listens.
pub fn start(subscriptions: &mut Subscriptions, call: &Call, writer: &SharedWriter, stream: u32) {
    let send = {
        let writer = Arc::clone(writer);
        move |result: Result<Value, ApiError>, more: bool| {
            super::send(&writer, stream, super::reply(result, more))
        }
    };
    let (filter, begin) = match parse(call) {
        Ok(parsed) => parsed,
        Err(error) => {
            send(Err(error), false);
            return;
        }
    };
    subscriptions
        .held
        .retain(|closed| !closed.load(Ordering::SeqCst));
    if subscriptions.held.len() >= subscriptions.limits.connection {
        send(
            Err(busy(subscriptions.held.len(), "this connection")),
            false,
        );
        return;
    }
    let Some(slot) = Slot::acquire_from(subscriptions.daemon, subscriptions.limits.daemon) else {
        send(Err(busy(subscriptions.limits.daemon, "this daemon")), false);
        return;
    };
    let hub = Arc::clone(&call.sessions.hooks().events);
    subscriptions.hub.get_or_insert_with(|| Arc::clone(&hub));
    let closed = Arc::new(AtomicBool::new(false));
    let sessions = call.sessions.clone();
    let ended = Arc::clone(&closed);
    let closer = subscriptions.closer.clone();
    let spawned = std::thread::Builder::new()
        .name("terminal events".into())
        .spawn(move || {
            let _slot = slot;
            let mut cursor = Cursor::new(begin);
            loop {
                let sent = match hub.next(&mut cursor, &|| ended.load(Ordering::SeqCst)) {
                    Next::Closed => return,
                    Next::Resumed { boot, revision } => send(
                        Ok(json!({"event": name::RESUMED, "boot": boot, "revision": revision})),
                        true,
                    ),
                    Next::Snapshot {
                        boot,
                        revision,
                        sessions: known,
                        reason,
                    } => snapshot(&sessions, &filter, known, &boot, revision, reason)
                        .into_iter()
                        .all(|event| send(Ok(event), true)),
                    Next::Events(events) => events
                        .iter()
                        .filter(|event| filter.passes(&event.json, false))
                        .all(|event| send(Ok(event.json.clone()), true)),
                };
                // A caller that hung up, or stopped reading, ends it, and its connection with it.
                if !sent {
                    ended.store(true, Ordering::SeqCst);
                    if let Some(close) = &closer {
                        crate::note!(
                            "terminal API: an events subscriber stopped reading; closing it"
                        );
                        close();
                    }
                    return;
                }
            }
        });
    match spawned {
        Ok(_) => subscriptions.held.push(closed),
        Err(error) => {
            crate::note!("terminal API: no thread for an events subscription: {error}");
            let writer = Arc::clone(writer);
            super::send(
                &writer,
                stream,
                super::reply(
                    Err(ApiError::new(
                        kind::INTERNAL_ERROR,
                        format!(
                            "the daemon could not start a thread for the subscription: {error}"
                        ),
                    )),
                    false,
                ),
            );
        }
    }
}

fn busy(held: usize, on: &str) -> ApiError {
    ApiError::new(
        kind::BUSY,
        format!(
            "{held} event subscriptions are already held on {on}, the most it holds at once; try \
             again when one has ended"
        ),
    )
}

/// The events the snapshot `known` (as of `revision`) is sent as: each session the filter passes,
/// with what `session.list` says of it now for the fields no event tells (its label, title and
/// cwd), then `snapshot-complete`.
fn snapshot(
    sessions: &crate::terminal::session::SessionStore,
    filter: &Filter,
    known: std::collections::BTreeMap<crate::terminal::session::SessionId, Known>,
    boot: &str,
    revision: u64,
    reason: crate::terminal::events::Reason,
) -> Vec<Value> {
    let live = listed(sessions);
    let mut events: Vec<Value> = known
        .into_iter()
        .map(|(id, mut known)| {
            let hyphenated = id.to_hyphenated();
            if let Some(now) = live.iter().find(|session| session["id"] == *hyphenated) {
                for key in ["label", "title", "cwd"] {
                    known.listing[key] = now[key].clone();
                }
            }
            let mut event = session_event(name::SESSION, id, &known);
            event["boot"] = json!(boot);
            event["revision"] = json!(revision);
            event
        })
        .filter(|event| filter.passes(event, true))
        .collect();
    let ids: Vec<Value> = events
        .iter()
        .map(|event| event["session"].clone())
        .collect();
    events.push(json!({
        "event": name::SNAPSHOT_COMPLETE,
        "boot": boot,
        "revision": revision,
        "sessions": ids,
        "reason": reason.name(),
    }));
    events
}

/// The filter and the place to start from that `call`'s params ask for, or why they are refused:
/// bad input first, then a `session` that names no one session.
fn parse(call: &Call) -> Result<(Filter, Start), ApiError> {
    let params = call.params;
    let text = |key: &str| match params.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.clone())),
        Some(_) => Err(ApiError::invalid(format!("{NAME}'s `{key}` is a string"))),
    };
    let workroom = text("workroom")?;
    let target = text("session")?;
    let all = match params.get("all") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(all)) => *all,
        Some(_) => {
            return Err(ApiError::invalid(format!(
                "{NAME}'s `all` is true or false"
            )));
        }
    };
    if all && workroom.is_some() {
        return Err(ApiError::invalid(format!(
            "{NAME} takes `workroom` or `all`, not both"
        )));
    }
    let types = match params.get("types") {
        None | Some(Value::Null) => None,
        Some(Value::Array(types)) => Some(
            types
                .iter()
                .map(|wanted| {
                    wanted
                        .as_str()
                        .filter(|wanted| name::LIVE.contains(wanted))
                        .map(str::to_string)
                        .ok_or_else(|| {
                            ApiError::invalid(format!(
                                "{NAME}'s `types` are each one of {}",
                                name::LIVE.join(", ")
                            ))
                        })
                })
                .collect::<Result<Vec<_>, _>>()?,
        ),
        Some(_) => {
            return Err(ApiError::invalid(format!(
                "{NAME}'s `types` is a list of event types"
            )));
        }
    };
    let start = match params.get("since") {
        None | Some(Value::Null) => Start::Fresh,
        Some(since) => match (since["boot"].as_str(), since["revision"].as_u64()) {
            (Some(boot), Some(revision)) => Start::Since {
                boot: boot.to_string(),
                revision,
            },
            _ => {
                return Err(ApiError::invalid(format!(
                    "{NAME}'s `since` is the `boot` and `revision` of an event"
                )));
            }
        },
    };
    let listing = listed(call.sessions);
    let session = match target {
        None => None,
        Some(target) => match resolve(&listing, &target) {
            Ok(session) => session["id"].as_str().map(str::to_string),
            // A session that has ended since the caller last heard from it is no longer here to
            // resolve, but the events it missed are still its: resuming, a full id is taken as
            // it is.
            Err(error) if error.kind == kind::TARGET_NOT_FOUND && start != Start::Fresh => Some(
                wr_protocol::terminal::parse_session_id(std::ffi::OsStr::new(&target))
                    .ok_or(error)?
                    .to_hyphenated(),
            ),
            Err(error) => return Err(error),
        },
    };
    let scope = match workroom {
        Some(workroom) => Some(json!({"kind": "workroom", "id": workroom})),
        None if all => None,
        None => call
            .caller
            .as_deref()
            .and_then(|caller| listing.iter().find(|session| session["id"] == caller))
            .map(|session| session["scope"].clone())
            .filter(|scope| !scope.is_null()),
    };
    Ok((
        Filter {
            session,
            scope,
            types,
        },
        start,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_filter_passes_its_session_scope_and_types_and_a_snapshot_whatever_its_types() {
        let event = json!({
            "event": name::PROGRAM_STATUS,
            "session": "a",
            "scope": {"kind": "workroom", "id": "wr-1"},
        });
        assert!(Filter::default().passes(&event, false));
        let only = |filter: Filter| filter.passes(&event, false);
        assert!(only(Filter {
            session: Some("a".into()),
            ..Filter::default()
        }));
        assert!(!only(Filter {
            session: Some("b".into()),
            ..Filter::default()
        }));
        assert!(!only(Filter {
            scope: Some(json!({"kind": "workroom", "id": "wr-2"})),
            ..Filter::default()
        }));
        let types = Filter {
            types: Some(vec![name::RUN_STATE.into()]),
            ..Filter::default()
        };
        assert!(!types.passes(&event, false));
        assert!(types.passes(&event, true), "a snapshot's session");
    }
}
