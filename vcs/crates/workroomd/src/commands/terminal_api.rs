//! The terminal API's client (ADR 0079): one request to the daemon's `Service::TerminalApi` and its
//! reply, for the commands that wrap it.
//!
//! The daemon is the one `WORKROOM_DAEMON` names, the socket every pane's shell is given (#684).
//! Without it (`env -i`, `sudo`), it is the nearest daemon this process runs under
//! ([`daemon_above`]): a pane's shell is its daemon's child. No other daemon is ever reached;
//! `new` starting one is #693's. The request names its caller, the pane's `WORKROOM_PANE`, when
//! that is set. The daemon finds the caller from the connecting process first, and takes the name
//! only when that process runs in none of its panes (under a daemonized tmux server, say).

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::Context;
use super::kind::{CliError, Kind};
use wr_protocol::envelope::{
    Envelope, EnvelopeDecoder, MAX_ENVELOPE_PAYLOAD, MIN_TERMINAL_API_VERSION, Service,
};

/// How long the daemon gets to greet and to answer.
const TIMEOUT: Duration = Duration::from_secs(10);

use crate::terminal::api::{DAEMON_VARIABLE, PANE_VARIABLE};

/// The request's stream: one request per connection.
const STREAM: u32 = 1;

/// Calls `method` with `params` and returns its `result`, or the daemon's error as the command's.
pub(super) fn call(context: &Context, method: &str, params: Value) -> Result<Value, CliError> {
    reply(context, method, params).map(|reply| reply.result)
}

/// A successful reply: the API's revision the daemon speaks, the method's `result`, and whether
/// `more` replies follow it on the stream.
pub(super) struct Replied {
    pub(super) revision: Value,
    pub(super) result: Value,
    pub(super) more: bool,
}

/// [`call`], keeping the reply's `revision` beside its `result`: the first reply of a stream.
pub(super) fn reply(context: &Context, method: &str, params: Value) -> Result<Replied, CliError> {
    let mut answer = None;
    stream(context, method, params, |replied| {
        answer = Some(replied);
        false
    })?;
    Ok(answer.expect("a stream that succeeds hands over a reply"))
}

/// Calls `method` with `params` and hands each reply to `each` as it arrives, until one says no
/// `more` follow (ADR 0079's stream rule, for any method), or `each` says it wants no more (its
/// reader went away). The daemon's error, at any point, is the command's.
///
/// The read timeout is for each read, not the whole stream: a long one stays alive while its
/// replies keep coming, and only a daemon silent for `TIMEOUT` is unreachable. A wait's is its
/// own ([`answer_timeout`]).
///
/// A wait the daemon hangs up on before answering is a hand-off's doing, when a daemon answers
/// on the same socket at once: the program was replaced in place, and every client connection
/// closed with the old one ([`resumed`]). Then a wait for a state (`status`, `run`, `ended`) is
/// sent again to the new program, with what is left of its timeout, and a wait for an event
/// (`regex`, `command_finished`) is `WaitInterrupted` (3). With no daemon there it is 7, as ever.
pub(super) fn stream(
    context: &Context,
    method: &str,
    params: Value,
    mut each: impl FnMut(Replied) -> bool,
) -> Result<(), CliError> {
    let encode = |params: &Value| {
        let mut request = json!({"method": method, "params": params});
        if let Some(pane) = context.env(PANE_VARIABLE).filter(|pane| !pane.is_empty()) {
            request["caller"] = Value::String(pane);
        }
        serde_json::to_vec(&request).expect("a request serializes")
    };
    // A request too big to send is bad input whether or not a daemon would take it, so it is
    // refused (2) before one is looked for.
    let mut request = encode(&params);
    if request.len() > MAX_ENVELOPE_PAYLOAD {
        return Err(CliError::new(
            Kind::TooLarge,
            format!("the request is over {MAX_ENVELOPE_PAYLOAD} bytes"),
        ));
    }
    let Some(socket) = context
        .env(DAEMON_VARIABLE)
        .filter(|path| !path.is_empty())
        .or_else(context.daemon_above)
    else {
        return Err(unreachable(format!(
            "no daemon to ask: {DAEMON_VARIABLE} names none, and this process does not run \
             under a Workroom daemon (every Workroom pane does, and sets {DAEMON_VARIABLE})"
        )));
    };
    if method == EVENTS {
        return events(context, &socket, params, encode, each);
    }
    let started = Instant::now();
    // A wait that may be sent again is pinned to the session its target names now, so the next
    // program is asked about that one session, and can say it has gone ([`gone`]). It is sent
    // the first time as it was given, so the daemon checks it as it would any request, and its
    // errors name the target as typed.
    let pinned = pin(context, method, &params);
    let typed = params
        .get("target")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let mut answer = answer_timeout(method, &params);
    let mut stream = connect(&socket)?;
    let mut resumes = 0;
    'connection: loop {
        stream
            .write_all(&Envelope::new(Service::TerminalApi, STREAM, request.clone()).encode())
            .map_err(|error| unreachable(format!("the daemon on {socket} hung up: {error}")))?;
        // A timeout the socket can't hold (macOS refuses one past its bounds) is none, rather
        // than leaving `TIMEOUT` to cut a long wait short.
        if stream.set_read_timeout(answer).is_err() {
            let _ = stream.set_read_timeout(None);
        }
        let mut decoder = EnvelopeDecoder::new();
        let mut answered = false;
        loop {
            let reply = match read_reply(&mut stream, &mut decoder) {
                Ok(reply) => reply,
                Err(Ended::HungUp) if method == WAIT && !answered && resumes < MAX_RESUMES => {
                    resumes += 1;
                    let (next, mut again) = resumed(&socket, &params, started)?;
                    if let Some(id) = &pinned {
                        again["target"] = json!(id);
                    }
                    eprintln!(
                        "workroom: the daemon on {socket} was handed off during the wait; \
                         waiting on in the new one"
                    );
                    (stream, request) = (next, encode(&again));
                    answer = answer_timeout(method, &again);
                    continue 'connection;
                }
                Err(_) => {
                    return Err(unreachable(format!(
                        "the daemon on {socket} did not answer"
                    )));
                }
            };
            answered = true;
            let reply: Value = serde_json::from_slice(&reply)
                .map_err(|_| CliError::internal("the daemon's reply is not JSON"))?;
            if let Some(error) = reply.get("error") {
                if resumes > 0
                    && let Some(id) = &pinned
                    && error["kind"] == TARGET_NOT_FOUND
                {
                    let ended = gone(id, &typed, &params)?;
                    each(Replied {
                        revision: reply.get("revision").cloned().unwrap_or(Value::Null),
                        result: ended,
                        more: false,
                    });
                    return Ok(());
                }
                let mut failure = failure(error);
                // Sent again by its id, the wait's errors still name the target as typed.
                if resumes > 0
                    && let Some(id) = &pinned
                {
                    failure.message = failure
                        .message
                        .replace(&format!("{id:?}"), &format!("{typed:?}"));
                }
                return Err(failure);
            }
            let replied = Replied {
                revision: reply.get("revision").cloned().unwrap_or(Value::Null),
                result: reply.get("result").cloned().unwrap_or(Value::Null),
                // A reply that doesn't say is the last.
                more: reply.get("more") == Some(&Value::Bool(true)),
            };
            let more = replied.more;
            if !each(replied) || !more {
                return Ok(());
            }
        }
    }
}

const WAIT: &str = "terminal.wait";

const EVENTS: &str = "events.subscribe";

/// The live events, which say where a stream stands, as against a snapshot's sessions.
const PLACES: [&str; 2] = ["snapshot-complete", "resumed"];

/// `events.subscribe`'s stream, from `workroom events` and `api call events.subscribe` alike: read
/// with no timeout, since a quiet daemon is one with nothing to tell, and gone on with across a
/// hand-off. The daemon hanging up mid-stream is a hand-off's doing when a daemon answers on the
/// same socket at once (as for a wait, [`resumed`]): the stream is asked of the new program again,
/// `since` the last place it reached (the last live event's `boot` and `revision`, or its
/// snapshot's end), and its `session` pinned to the id it resolved to first. The new program
/// answers `resumed`, which this swallows, saying so on stderr, and sends every event after that
/// place: nothing missed, nothing twice. When it can't (the daemon started afresh, or the place is
/// older than it keeps), it sends the sessions afresh, a snapshot whose `snapshot-complete` says
/// `gap`; that goes to `each` like any reply, and stderr says events may have been missed. With no
/// daemon there it is 7, as ever.
fn events(
    context: &Context,
    socket: &str,
    params: Value,
    encode: impl Fn(&Value) -> Vec<u8>,
    mut each: impl FnMut(Replied) -> bool,
) -> Result<(), CliError> {
    let pinned = params
        .get("session")
        .and_then(Value::as_str)
        .and_then(|target| reply(context, "session.resolve", json!({"target": target})).ok())
        .and_then(|resolved| {
            resolved.result["session"]["id"]
                .as_str()
                .map(str::to_string)
        });
    let mut request = encode(&params);
    let mut stream = connect(socket)?;
    // Where the stream stands: the boot and revision a resume asks to go on after.
    let mut place: Option<(Value, Value)> = None;
    let mut resumes = 0;
    // Whether the next reply answers a resume this made.
    let mut resuming = false;
    'connection: loop {
        stream
            .write_all(&Envelope::new(Service::TerminalApi, STREAM, request.clone()).encode())
            .map_err(|error| unreachable(format!("the daemon on {socket} hung up: {error}")))?;
        let _ = stream.set_read_timeout(None);
        let mut decoder = EnvelopeDecoder::new();
        loop {
            let reply = match read_reply(&mut stream, &mut decoder) {
                Ok(reply) => reply,
                Err(Ended::HungUp) if resumes < MAX_RESUMES => {
                    resumes += 1;
                    stream = connect(socket).map_err(|mut error| {
                        if error.kind == Kind::DaemonUnreachable {
                            error.message = format!(
                                "the daemon on {socket} went away during the events, and none \
                                 is listening there now"
                            );
                        }
                        error
                    })?;
                    let mut again = params.clone();
                    if let Some(id) = &pinned {
                        again["session"] = json!(id);
                    }
                    if let Some((boot, revision)) = &place {
                        again["since"] = json!({"boot": boot, "revision": revision});
                    }
                    resuming = place.is_some();
                    eprintln!(
                        "workroom: the daemon on {socket} was handed off during the events; going \
                         on in the new one"
                    );
                    request = encode(&again);
                    continue 'connection;
                }
                Err(_) => {
                    return Err(unreachable(format!(
                        "the daemon on {socket} did not answer"
                    )));
                }
            };
            let reply: Value = serde_json::from_slice(&reply)
                .map_err(|_| CliError::internal("the daemon's reply is not JSON"))?;
            if let Some(error) = reply.get("error") {
                return Err(failure(error));
            }
            let result = reply.get("result").cloned().unwrap_or(Value::Null);
            let event = result["event"].as_str().unwrap_or_default();
            if resuming {
                resuming = false;
                if event == "resumed" {
                    continue;
                }
                eprintln!(
                    "workroom: the new daemon could not go on from where the events stood, so \
                     events may have been missed; the sessions follow afresh"
                );
            }
            if PLACES.contains(&event) || event.contains('.') {
                place = Some((result["boot"].clone(), result["revision"].clone()));
            }
            if event.contains('.') {
                resumes = 0;
            }
            let more = reply.get("more") == Some(&Value::Bool(true));
            let replied = Replied {
                revision: reply.get("revision").cloned().unwrap_or(Value::Null),
                result,
                more,
            };
            if !each(replied) || !more {
                return Ok(());
            }
        }
    }
}

/// The daemon's `error` as the command's.
fn failure(error: &Value) -> CliError {
    let mut failure = CliError::new(
        Kind::from_code(error["kind"].as_str().unwrap_or_default()),
        error["message"]
            .as_str()
            .unwrap_or("the daemon refused")
            .to_string(),
    );
    failure.matches = error["matches"].as_array().cloned().unwrap_or_default();
    failure.details = error
        .get("details")
        .filter(|details| details.is_object())
        .map(|details| Box::new(details.clone()));
    failure
}

const TARGET_NOT_FOUND: &str = crate::terminal::api::kind::TARGET_NOT_FOUND;

/// The conditions a wait is sent again for after a hand-off: states (`resumed`).
const STATES: [&str; 3] = ["status", "run", "ended"];

/// For a wait for a state, the id of the session its target names, by `session.resolve`, which
/// resolves as `terminal.wait` does: what is sent again after a hand-off, in place of the target.
/// `None` for any other request, and for a target that names no one session, or a daemon that
/// can't be asked: the wait itself, sent as given, then fails as the daemon finds, bad input
/// before an unknown target, and is never sent again.
fn pin(context: &Context, method: &str, params: &Value) -> Option<String> {
    let state = STATES
        .iter()
        .any(|key| params.get(key).is_some_and(|value| !value.is_null()));
    let target = params.get("target").and_then(Value::as_str)?;
    if method != WAIT || !state {
        return None;
    }
    let resolved = reply(context, "session.resolve", json!({"target": target})).ok()?;
    resolved.result["session"]["id"]
        .as_str()
        .map(str::to_string)
}

/// What a wait for a state, sent again after a hand-off, answers when the new program has no
/// session `id`, which `typed` named: it ended between the two programs, with nobody left to say
/// so. Ended, for an `ended` wait (its exit code unknown), as the old program would have answered
/// had it seen the end; `SessionEnded` for any other, as a wait whose session ends is.
fn gone(id: &str, typed: &str, params: &Value) -> Result<Value, CliError> {
    if params.get("ended").is_some_and(|value| !value.is_null()) {
        return Ok(json!({
            "session": id,
            "condition": "ended",
            "status": null,
            "run_state": null,
            "match": null,
            "exit_code": null,
        }));
    }
    Err(CliError::new(
        Kind::SessionEnded,
        format!(
            "{typed:?} (session {id}) ended during the daemon's hand-off, before what it was \
             waited for happened"
        ),
    ))
}

/// The most times one wait is sent again after a hand-off, so a daemon that hangs up on it each
/// time it is sent is unreachable (7), never asked forever.
const MAX_RESUMES: u32 = 16;

/// No daemon to be had: the command's 7.
fn unreachable(message: String) -> CliError {
    CliError::new(Kind::DaemonUnreachable, message)
}

/// A connection to the daemon on `socket`, greeted, that speaks the terminal API.
fn connect(socket: &str) -> Result<UnixStream, CliError> {
    let mut stream = UnixStream::connect(socket)
        .map_err(|error| unreachable(format!("no daemon is listening on {socket}: {error}")))?;
    let _ = stream.set_read_timeout(Some(TIMEOUT));
    let _ = stream.set_write_timeout(Some(TIMEOUT));
    let version = crate::cli::handshake(&mut stream)
        .map_err(|_| unreachable(format!("the process on {socket} is not a Workroom daemon")))?;
    // An older daemon's decoder fails the whole connection on a service byte it doesn't know, so
    // nothing is sent to one. It is running, so the caller is told to update it, not start one.
    if version < MIN_TERMINAL_API_VERSION {
        return Err(CliError::new(
            Kind::DaemonTooOld,
            format!(
                "the daemon on {socket} speaks protocol {version}, which predates the terminal \
                 API (protocol {MIN_TERMINAL_API_VERSION}); it needs updating, which updating \
                 the app does"
            ),
        ));
    }
    Ok(stream)
}

/// After the daemon on `socket` hung up on a wait for `params` sent at `started`: a connection to
/// the program a hand-off put there, and the wait to send it, with what is left of its timeout.
///
/// A hand-off replaces the daemon's program in place and keeps its listening socket, so the
/// connection is taken at once, from the backlog, by the new program. A daemon that has gone
/// leaves nobody listening: unreachable (7).
///
/// A state (`status`, `run`, `ended`) is one already reached or still to come, so the new
/// program answers as the old would have. An event is not: output read, or a command ended,
/// between the old program's last read and the new one's wait starting would never be seen, so
/// a `regex` or `command_finished` wait is `WaitInterrupted` (3) rather than waited on for what
/// may already have gone by. The sessions' unread output stays in their ptys across the hand-off
/// itself, so the gap is from the new program's readers starting to the wait reaching it.
fn resumed(
    socket: &str,
    params: &Value,
    started: Instant,
) -> Result<(UnixStream, Value), CliError> {
    let stream = connect(socket).map_err(|error| {
        let mut error = error;
        if error.kind == Kind::DaemonUnreachable {
            error.message = format!(
                "the daemon on {socket} went away during the wait, and none is listening there \
                 now"
            );
        }
        error
    })?;
    let given = |key: &str| params.get(key).is_some_and(|value| !value.is_null());
    if let Some(event) = ["regex", "command_finished"]
        .into_iter()
        .find(|key| given(key))
    {
        return Err(CliError::new(
            Kind::WaitInterrupted,
            format!(
                "the daemon on {socket} was handed off (replaced by its update) during the \
                 `{event}` wait, so what happened in between may have gone unseen; wait again"
            ),
        ));
    }
    let mut again = params.clone();
    if let Some(millis) = params.get("timeout_ms").and_then(Value::as_u64) {
        let spent = u64::try_from(started.elapsed().as_millis()).unwrap_or(u64::MAX);
        again["timeout_ms"] = json!(millis.saturating_sub(spent));
    }
    Ok((stream, again))
}

/// How long the daemon gets to answer `method` with `params` once the request is sent: `TIMEOUT`,
/// but for `terminal.wait`, which answers when what it waits for happens. That is its own
/// `timeout_ms` and `TIMEOUT` more, so its `WaitTimeout` arrives before the client gives up, and
/// no limit when it has none (`None`). A `timeout_ms` the daemon will refuse gets `TIMEOUT`: the
/// refusal comes at once. The same for `wait` and `api call terminal.wait`, so neither reads a
/// long wait as a daemon gone quiet (7).
pub(super) fn answer_timeout(method: &str, params: &Value) -> Option<Duration> {
    if method != "terminal.wait" {
        return Some(TIMEOUT);
    }
    match params.get("timeout_ms") {
        None | Some(Value::Null) => None,
        Some(millis) => match millis.as_u64() {
            // Past what a `Duration` holds is no limit, as it is on the daemon.
            Some(millis) => Duration::from_millis(millis).checked_add(TIMEOUT),
            None => Some(TIMEOUT),
        },
    }
}

/// The socket of the nearest daemon this process runs under, for a caller whose environment names
/// none (`env -i`, `sudo`): a pane's shell is its daemon's child, so a command in a pane has that
/// daemon among its parents, as `<binary> serve --socket <path>`, which a hand-off keeps.
pub(super) fn daemon_above() -> Option<String> {
    // SAFETY: `getppid` takes no pointers and cannot fail.
    let parent = unsafe { libc::getppid() };
    wr_exec::ancestry(parent).into_iter().find_map(|pid| {
        crate::terminal::process::arguments(pid).and_then(|argv| served_socket(&argv))
    })
}

/// The binary names a daemon runs as: `workroom` (ADR 0078), and `workroomd`, which the app's
/// bundle and every host install still call it.
const DAEMON_NAMES: &[&str] = &["workroom", "workroomd"];

/// The socket `argv` serves, when it is a daemon's: `<binary> serve --socket <path>`, its binary
/// named as [`DAEMON_NAMES`], so another program that happens to take the same arguments is not
/// mistaken for one.
pub(super) fn served_socket(argv: &[String]) -> Option<String> {
    let named = argv
        .first()
        .and_then(|program| std::path::Path::new(program).file_name())
        .and_then(std::ffi::OsStr::to_str)
        .is_some_and(|name| DAEMON_NAMES.contains(&name));
    if !named || argv.get(1).map(String::as_str) != Some("serve") {
        return None;
    }
    let at = argv.iter().position(|argument| argument == "--socket")?;
    argv.get(at + 1).filter(|path| !path.is_empty()).cloned()
}

/// Why no reply came.
enum Ended {
    /// The daemon closed the connection, or reset it: a hand-off does, as the old program goes.
    HungUp,
    /// It said nothing for the read timeout, or something unreadable.
    Quiet,
}

/// The next reply on `STREAM`, its chunks joined (`rpc::send`: each payload's first byte says
/// whether it is the last), or why none came. `decoder` carries what was read past one reply to
/// the next.
fn read_reply(stream: &mut UnixStream, decoder: &mut EnvelopeDecoder) -> Result<Vec<u8>, Ended> {
    let mut reply = Vec::new();
    let mut buffer = [0u8; 64 * 1024];
    loop {
        while let Some(envelope) = decoder.next_envelope().map_err(|_| Ended::Quiet)? {
            if envelope.service != Service::TerminalApi || envelope.stream != STREAM {
                continue;
            }
            let (last, body) = envelope.payload.split_first().ok_or(Ended::Quiet)?;
            reply.extend_from_slice(body);
            if *last == 1 {
                return Ok(reply);
            }
        }
        match stream.read(&mut buffer) {
            Ok(0) => return Err(Ended::HungUp),
            Ok(n) => decoder.push(&buffer[..n]),
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => {
                return Err(match error.kind() {
                    std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::BrokenPipe => {
                        Ended::HungUp
                    }
                    _ => Ended::Quiet,
                });
            }
        }
    }
}

#[cfg(test)]
mod tests;
