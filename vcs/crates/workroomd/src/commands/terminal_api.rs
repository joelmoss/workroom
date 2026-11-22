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
use std::path::Path;
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
    let encode_as = |method: &str, params: &Value| {
        let mut request = json!({"method": method, "params": params});
        if let Some(pane) = context.env(PANE_VARIABLE).filter(|pane| !pane.is_empty()) {
            request["caller"] = Value::String(pane);
        }
        serde_json::to_vec(&request).expect("a request serializes")
    };
    let encode = |params: &Value| encode_as(method, params);
    // A request too big to send is bad input whether or not a daemon would take it, so it is
    // refused (2) before one is looked for.
    let mut request = encode(&params);
    let ceiling = max_request(method);
    if request.len() > ceiling {
        return Err(CliError::new(
            Kind::TooLarge,
            format!("the request is over {ceiling} bytes"),
        ));
    }
    let named = context
        .env(DAEMON_VARIABLE)
        .filter(|path| !path.is_empty())
        .or_else(context.daemon_above);
    // `new` alone starts a daemon (#693), and only this Mac's own, where the app keeps it: never
    // one on a socket a variable names, which may be anything.
    let (named, start_here) = daemon_to_ask(method, named, || local_socket(context))?;
    let Some(socket) = named else {
        return Err(unreachable(format!(
            "no daemon to ask: {DAEMON_VARIABLE} names none, and this process does not run \
             under a Workroom daemon (every Workroom pane does, and sets {DAEMON_VARIABLE})"
        )));
    };
    if start_here {
        start_if_absent(&socket, &daemon_environment(std::env::vars_os()))?;
    }
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
    // A waited prompt's last reply, once one has said it was typed: where a hand-off goes on
    // from, and the shape the turn's end, waited on in the new program, is told in.
    let mut prompted: Option<Value> = None;
    // Whether the replies now answer that wait rather than the prompt.
    let mut turn_waited = false;
    'connection: loop {
        stream
            .write_all(&envelopes(&request))
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
                // Never sent again: that would type the command a second time.
                Err(Ended::HungUp) if method == COMMAND => return Err(cut_off(&socket)),
                // Never sent again, which would type it a second time: once it was typed, its
                // turn is waited on in the new program (`turn_resumed`).
                Err(Ended::HungUp) if method == PROMPT && resumes < MAX_RESUMES => {
                    let Some(last) = &prompted else {
                        return Err(prompt_cut_off(&socket));
                    };
                    resumes += 1;
                    let (next, wait) = turn_resumed(&socket, last, &params, started)?;
                    eprintln!(
                        "workroom: the daemon on {socket} was handed off after the prompt was \
                         typed; waiting on its turn in the new one"
                    );
                    (stream, request) = (next, encode_as(WAIT, &wait));
                    answer = answer_timeout(WAIT, &wait);
                    turn_waited = true;
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
            if turn_waited && let Some(last) = &prompted {
                let ended = turn_ended(last, &reply)?;
                each(Replied {
                    revision: reply.get("revision").cloned().unwrap_or(Value::Null),
                    result: ended,
                    more: false,
                });
                return Ok(());
            }
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
            if method == PROMPT && more {
                prompted = Some(replied.result.clone());
            }
            if !each(replied) || !more {
                return Ok(());
            }
        }
    }
}

const WAIT: &str = "terminal.wait";

const SEND: &str = "terminal.send";

const COMMAND: &str = "terminal.command";

const PROMPT: &str = "terminal.prompt";

const NEW: &str = "session.new";

/// How long `new` waits for a daemon it started to take connections, as `attach` waits.
const START_TIMEOUT: Duration = Duration::from_secs(5);

/// The bundle id of the release app, whose daemon a `workroom` outside every app bundle reaches,
/// as the app falls back to it (`PersistentSessionPaths`).
const RELEASE_BUNDLE: &str = "com.developwithstyle.workroom";

/// The longest socket path a unix socket takes (`sun_path`), as the app counts it.
const SUN_PATH_LIMIT: usize = 104;

/// The daemon `method` asks, and whether one is started there when none answers: the one `named`
/// (`WORKROOM_DAEMON`, or the daemon above), never started; else, for `new` alone, this Mac's
/// own (`local`), started when it isn't running (#693).
pub(super) fn daemon_to_ask(
    method: &str,
    named: Option<String>,
    local: impl FnOnce() -> Result<Option<String>, CliError>,
) -> Result<(Option<String>, bool), CliError> {
    match named {
        Some(named) => Ok((Some(named), false)),
        None if method == NEW => {
            let local = local()?;
            let start = local.is_some();
            Ok((local, start))
        }
        None => Ok((None, false)),
    }
}

/// This Mac's daemon, for `new` from outside every pane with none named (#693): where the app
/// whose bundle holds this binary keeps its daemon, or the release app's for a binary in none.
/// None on a host, whose daemon only its supervisor starts.
///
/// A socket in the app's `/tmp` folder is used only while that folder is safe to trust
/// ([`trusted_folder`]); one that isn't is refused, as the app refuses it.
fn local_socket(context: &Context) -> Result<Option<String>, CliError> {
    if !cfg!(target_os = "macos") {
        return Ok(None);
    }
    let Some(home) = context.env("HOME").filter(|home| !home.is_empty()) else {
        return Ok(None);
    };
    let bundle = std::env::current_exe()
        .ok()
        .and_then(|exe| std::fs::canonicalize(exe).ok())
        .and_then(|exe| bundle_of(&exe))
        .unwrap_or_else(|| RELEASE_BUNDLE.to_string());
    // SAFETY: `getuid` takes nothing and cannot fail.
    let uid = unsafe { libc::getuid() };
    let place = mac_daemon_socket(&home, &bundle, uid);
    let trusted = |socket: &String| {
        !socket.starts_with("/tmp/")
            || Path::new(socket)
                .parent()
                .is_some_and(|folder| trusted_folder(folder, uid).is_ok())
    };
    if let Some(live) = place
        .candidates
        .iter()
        .filter(|socket| trusted(socket))
        .find(|socket| UnixStream::connect(socket).is_ok())
    {
        return Ok(Some(live.clone()));
    }
    if place.standard.starts_with("/tmp/")
        && let Some(folder) = Path::new(&place.standard).parent()
        && let Err(why) = trusted_folder(folder, uid)
    {
        return Err(unreachable(format!(
            "no daemon is listening, and none is started in {}: {why}",
            folder.display()
        )));
    }
    Ok(Some(place.standard))
}

/// Whether `folder` is safe to keep a daemon's socket in for user `uid`, as the app checks its
/// own (`PersistentSessionPaths.prepareFallbackDirectory`): absent (it is made, 0700), or a real
/// folder, not a link, that `uid` owns and nobody else can write to or read. Why not, otherwise.
pub(super) fn trusted_folder(folder: &Path, uid: u32) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;
    let metadata = match std::fs::symlink_metadata(folder) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(format!("it can't be read: {error}")),
    };
    if metadata.file_type().is_symlink() {
        return Err("it is a link".into());
    }
    if !metadata.is_dir() {
        return Err("it is no folder".into());
    }
    if metadata.uid() != uid {
        return Err(format!("another user ({}) owns it", metadata.uid()));
    }
    if metadata.mode() & 0o077 != 0 {
        return Err(format!(
            "others can reach it (mode {:o}); only its owner should",
            metadata.mode() & 0o777
        ));
    }
    Ok(())
}

/// What a daemon `new` starts is given of this process's environment: what a login has
/// (`HOME`, `USER`, `LOGNAME`, `SHELL`, `PATH`, `TMPDIR`) and its locale (`LANG`, `LC_*`), and
/// nothing else, so a script's own variables (a coding agent's, a `WORKROOM_*` of another pane)
/// never become every later session's.
pub(super) fn daemon_environment(
    vars: impl Iterator<Item = (std::ffi::OsString, std::ffi::OsString)>,
) -> Vec<(std::ffi::OsString, std::ffi::OsString)> {
    const KEPT: [&str; 7] = ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "LANG"];
    vars.filter(|(key, _)| {
        let key = key.to_string_lossy();
        KEPT.contains(&key.as_ref()) || key.starts_with("LC_")
    })
    .collect()
}

/// Where the app keeps its daemon's socket on this Mac (`PersistentSessionPaths.daemonSocket`):
/// `standard`, where one is started, and every path one may already answer on, first to last.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct MacDaemonSocket {
    pub(super) standard: String,
    pub(super) candidates: Vec<String>,
}

/// [`MacDaemonSocket`] for the app `bundle` of the user `uid` whose home is `home`: Application
/// Support's `<bundle>/sessions/workroomd`, or, when that is past `sun_path`, the app's fallback
/// folder `/tmp/workroom-<uid>-<bundle>`; and under either the name the daemon had before #525,
/// `agent.sock`, which a daemon an older build started keeps.
pub(super) fn mac_daemon_socket(home: &str, bundle: &str, uid: u32) -> MacDaemonSocket {
    let preferred = format!("{home}/Library/Application Support/{bundle}/sessions");
    let fallback = format!("/tmp/workroom-{uid}-{bundle}");
    let fits = |path: &String| path.len() < SUN_PATH_LIMIT;
    let new_preferred = format!("{preferred}/workroomd");
    let new_fallback = format!("{fallback}/workroomd");
    let standard = if fits(&new_preferred) {
        new_preferred.clone()
    } else {
        new_fallback.clone()
    };
    let candidates = [
        standard.clone(),
        new_fallback,
        format!("{preferred}/agent.sock"),
        format!("{fallback}/agent.sock"),
    ]
    .into_iter()
    .filter(fits)
    .collect();
    MacDaemonSocket {
        standard,
        candidates,
    }
}

/// The bundle id of the app whose `Contents/Resources` holds `exe`, from its `Info.plist`.
pub(super) fn bundle_of(exe: &Path) -> Option<String> {
    let resources = exe.parent()?;
    let contents = resources.parent()?;
    if resources.file_name()? != "Resources" || contents.file_name()? != "Contents" {
        return None;
    }
    let plist = std::fs::read_to_string(contents.join("Info.plist")).ok()?;
    plist_string(&plist, "CFBundleIdentifier")
}

/// The string an XML property list gives `key`: `<key>KEY</key>` and the `<string>` after it.
pub(super) fn plist_string(plist: &str, key: &str) -> Option<String> {
    let after = plist.split_once(&format!("<key>{key}</key>"))?.1;
    let value = after.trim_start().strip_prefix("<string>")?;
    let value = value.split_once("</string>")?.0.trim();
    (!value.is_empty() && !value.contains('<')).then(|| value.to_string())
}

/// Starts a daemon on `socket` when nothing answers there (#693), as `attach` does, and waits for
/// it to take connections: `new` from a script with no daemon running. A daemon that answers is
/// left as it is; whether it speaks the terminal API is for `connect` to say.
fn start_if_absent(
    socket: &str,
    environment: &[(std::ffi::OsString, std::ffi::OsString)],
) -> Result<(), CliError> {
    if UnixStream::connect(socket).is_ok() {
        return Ok(());
    }
    let path = Path::new(socket);
    if let Some(folder) = path.parent()
        && !folder.as_os_str().is_empty()
        && !folder.exists()
    {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(folder)
            .map_err(|error| {
                unreachable(format!(
                    "no daemon is listening on {socket}, and its folder can't be made: {error}"
                ))
            })?;
    }
    let binary = std::env::current_exe().map_err(|error| {
        unreachable(format!(
            "no daemon is listening on {socket}, and this binary can't be found to start one: \
             {error}"
        ))
    })?;
    crate::daemon::serve::spawn_daemon_with(&binary, path, Some(environment)).map_err(|error| {
        unreachable(format!(
            "no daemon is listening on {socket}, and one could not be started: {error}"
        ))
    })?;
    let deadline = Instant::now() + START_TIMEOUT;
    while Instant::now() < deadline {
        if UnixStream::connect(socket).is_ok() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    Err(unreachable(format!(
        "the daemon started on {socket} did not take connections within {}s",
        START_TIMEOUT.as_secs()
    )))
}

/// A `terminal.prompt` the daemon on `socket` hung up on before it said the prompt was typed: a
/// hand-off, when a daemon answers there at once, which is `WaitInterrupted` (3), since whether
/// it was typed went unsaid; else nobody listening, 7. Never sent again, which could type the
/// prompt a second time.
fn prompt_cut_off(socket: &str) -> CliError {
    match connect(socket) {
        Ok(_) => CliError::new(
            Kind::WaitInterrupted,
            format!(
                "the daemon on {socket} was handed off (replaced by its update) before it said \
                 whether the prompt was typed; it is not typed again, and `workroom capture` \
                 shows whether it was"
            ),
        ),
        Err(mut error) => {
            if error.kind == Kind::DaemonUnreachable {
                error.message = format!(
                    "the daemon on {socket} went away during the prompt, and none is listening \
                     there now"
                );
            }
            error
        }
    }
}

/// After the daemon on `socket` hung up on a waited prompt whose `last` reply said it was typed:
/// a connection to the program a hand-off put there, and the `terminal.wait` for its turn's end
/// to send it, by the session's id, with what is left of the prompt's timeout. `current` once the
/// last reply said the turn had started (`working`), as a wait for a state, since the status it
/// ends in stays; else `next`, for the turn still to start.
///
/// The one gap: a turn that started after the old program's last read and ended before the new
/// program's wait is added (the hand-off's frozen moment) is no `next` turn there, so it is waited
/// on to the timeout.
fn turn_resumed(
    socket: &str,
    last: &Value,
    params: &Value,
    started: Instant,
) -> Result<(UnixStream, Value), CliError> {
    let (stream, again) = resumed(socket, params, started)?;
    let turn = if last["status"] == "working" {
        "current"
    } else {
        "next"
    };
    let mut wait = json!({"target": last["session"], "turn": turn});
    if let Some(left) = again.get("timeout_ms") {
        wait["timeout_ms"] = left.clone();
    }
    Ok((stream, wait))
}

/// What the wait for a prompt's turn, sent after a hand-off, answers as the prompt would have:
/// its `last` reply with the status the turn ended in. A session the new program doesn't have
/// ended between the two, after the prompt was typed: `SessionEnded`, as the old would have said.
fn turn_ended(last: &Value, reply: &Value) -> Result<Value, CliError> {
    if let Some(error) = reply.get("error") {
        if error["kind"] == TARGET_NOT_FOUND {
            return Err(CliError::new(
                Kind::SessionEnded,
                format!(
                    "session {} ended during the daemon's hand-off, after the prompt was typed, \
                     before its turn did",
                    last["session"].as_str().unwrap_or_default()
                ),
            ));
        }
        return Err(failure(error));
    }
    let mut ended = last.clone();
    ended["status"] = reply["result"]["status"].clone();
    Ok(ended)
}

/// The longest request the CLI sends for `method`: one envelope's payload, but for
/// `terminal.send`, whose 1 MiB of text JSON may escape to six times that (a control character is
/// `\u001b`), so it goes in chunks up to the 16 MiB the daemon reassembles (`rpc::reassemble`),
/// and `terminal.command`, whose 1 MiB line may escape to twice that (a quote or a backslash).
fn max_request(method: &str) -> usize {
    // A prompt's 1 MiB of text likewise.
    if method == SEND || method == COMMAND || method == PROMPT {
        crate::daemon::rpc::MAX_REQUEST
    } else {
        MAX_ENVELOPE_PAYLOAD
    }
}

/// `request` as the envelopes that carry it, encoded: one when it fits, else chunks, each
/// payload starting with `rpc::REQUEST_CHUNK_MARKER` and then whether it is the last. A request
/// that fits one envelope goes as it is, JSON, which starts `{`.
fn envelopes(request: &[u8]) -> Vec<u8> {
    if request.len() <= MAX_ENVELOPE_PAYLOAD {
        return Envelope::new(Service::TerminalApi, STREAM, request.to_vec()).encode();
    }
    let chunks = request.chunks(MAX_ENVELOPE_PAYLOAD - 2);
    let count = chunks.len();
    chunks
        .enumerate()
        .flat_map(|(index, chunk)| {
            let mut payload = vec![
                crate::daemon::rpc::REQUEST_CHUNK_MARKER,
                u8::from(index + 1 == count),
            ];
            payload.extend_from_slice(chunk);
            Envelope::new(Service::TerminalApi, STREAM, payload).encode()
        })
        .collect()
}

const EVENTS: &str = "events.subscribe";

/// The events that say where a stream stands, besides the live ones, as against a snapshot's
/// sessions: `place` is a filtered stream's, which nothing else would move on.
const PLACES: [&str; 3] = ["snapshot-complete", "resumed", "place"];

/// `events.subscribe`'s stream, from `workroom events` and `api call events.subscribe` alike: read
/// with no timeout, since a quiet daemon is one with nothing to tell, and gone on with across a
/// hand-off. The daemon hanging up mid-stream is a hand-off's doing when a daemon answers on the
/// same socket at once (as for a wait, [`resumed`]): the stream is asked of the new program again,
/// `since` the last place it reached (the last live event's `boot` and `revision`, its snapshot's
/// end, or a `place` the daemon sends a filtered stream), and its `session` pinned to the id it
/// resolved to first. A daemon also closes a stream whose reader has stopped reading, which reads
/// the same here, so stderr says the connection ended, not why. The new program answers
/// `resumed`, which this swallows, and sends every event after that
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
                    // Not necessarily a hand-off: a daemon closes a stream its reader has stopped
                    // reading, and nothing on the wire tells the two apart.
                    eprintln!(
                        "workroom: the connection to the daemon on {socket} ended (a hand-off, or \
                         a reader too slow, ends it); asking again from where the events stood"
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

/// The conditions a wait is sent again for after a hand-off: states (`resumed`), and a coding
/// agent's turn, whose `current` is a state, and whose `next` misses a turn that started and
/// ended between the two programs (ADR 0079).
const STATES: [&str; 4] = ["status", "run", "ended", "turn"];

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

/// A `terminal.command` the daemon on `socket` hung up on before it answered: a hand-off, when a
/// daemon answers there at once, which is `WaitInterrupted` (3), as a `command_finished` wait's
/// is, since the command may have ended unseen in between; else nobody listening, 7. Never sent
/// again, which would type the command a second time.
fn cut_off(socket: &str) -> CliError {
    match connect(socket) {
        Ok(_) => CliError::new(
            Kind::WaitInterrupted,
            format!(
                "the daemon on {socket} was handed off (replaced by its update) while the command \
                 ran, so its end and its output went unseen; it may still be running, or have \
                 ended, and is not run again"
            ),
        ),
        Err(mut error) => {
            if error.kind == Kind::DaemonUnreachable {
                error.message = format!(
                    "the daemon on {socket} went away while the command ran, and none is \
                     listening there now"
                );
            }
            error
        }
    }
}

/// How long the daemon gets to answer `method` with `params` once the request is sent: `TIMEOUT`,
/// but for `terminal.wait`, which answers when what it waits for happens. That is its own
/// `timeout_ms` and `TIMEOUT` more, so its `WaitTimeout` arrives before the client gives up, and
/// no limit when it has none (`None`). A `timeout_ms` the daemon will refuse gets `TIMEOUT`: the
/// refusal comes at once. The same for `wait` and `api call terminal.wait`, so neither reads a
/// long wait as a daemon gone quiet (7). `terminal.command` waits as a wait does, and types its
/// command first, as a send does, so it gets the send's time beside its own.
pub(super) fn answer_timeout(method: &str, params: &Value) -> Option<Duration> {
    // A send types for up to its deadline, then closes its paste, so it gets both and `TIMEOUT`.
    let send = crate::terminal::api::SEND_DEADLINE + crate::terminal::api::SEND_DEADLINE_GRACE;
    if method == SEND {
        return Some(send + TIMEOUT);
    }
    // A prompt types as a send does, and with `wait` waits as a wait does, so it gets both.
    if method == PROMPT && params.get("wait") != Some(&Value::Bool(true)) {
        return Some(send + TIMEOUT);
    }
    let typing = match method {
        WAIT => Duration::ZERO,
        COMMAND | PROMPT => send,
        _ => return Some(TIMEOUT),
    };
    match params.get("timeout_ms") {
        None | Some(Value::Null) => None,
        Some(millis) => match millis.as_u64() {
            // Past what a `Duration` holds is no limit, as it is on the daemon.
            Some(millis) => Duration::from_millis(millis)
                .checked_add(typing)
                .and_then(|waited| waited.checked_add(TIMEOUT)),
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
