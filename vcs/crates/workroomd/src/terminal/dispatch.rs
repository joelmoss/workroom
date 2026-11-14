//! The Terminal service and its Control frames on one connection: Attach, Input, Resize, List,
//! Kill, Signal, Retag, KillAll and HandOff. `daemon::serve` hands every Terminal and Control
//! envelope here; the frames' payloads are `wr_protocol::terminal`'s.

use std::ffi::{OsStr, OsString};
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::sync::Arc;

use crate::daemon::rpc::{self, SharedWriter};
use crate::daemon::transport::Closer;
use crate::terminal::pty::Size;
use crate::terminal::session::{RunSignalError, SessionId, SessionInfo, SessionSpec, SessionStore};
use crate::terminal::shell;
use wr_protocol::envelope::{Envelope, MAX_ENVELOPE_PAYLOAD, Service};
use wr_protocol::frame::{
    Frame, FrameDecoder, FrameKind, HEADER_SIZE, MAX_PAYLOAD_SIZE, RunSignal,
};
use wr_protocol::terminal::{
    AttachRequest, MAX_WORKROOM_BYTES, SessionDescriptor, decode_resize, decode_retag,
};

/// The session one connection is attached to, if any, and which attachment of it this is.
pub(crate) struct Attachment {
    id: Option<SessionId>,
    /// Identifies THIS attachment, so ending this connection cannot detach a client that has since
    /// taken the session over.
    token: u64,
    /// Ends this connection: a probed client that stops answering is closed with it (ADR 0075).
    closer: Closer,
    /// The ssh variables this connection's `relay` passed on (`FrameKind::Peer`), set on the
    /// host-environment sessions it creates (ADR 0074).
    peer: Option<Vec<(OsString, OsString)>>,
}

impl Attachment {
    /// The attachment of the connection `closer` ends, attached to nothing yet.
    pub(crate) fn new(closer: Closer) -> Attachment {
        Attachment {
            id: None,
            token: 0,
            closer,
            peer: None,
        }
    }

    /// The connection has ended. The session keeps its reader; only the client goes. There is
    /// nothing to stop and nothing to join — which is also why a detached session keeps draining
    /// its pty instead of wedging the shell behind a full output queue.
    pub(crate) fn end(self, sessions: &SessionStore) {
        if let Some(id) = self.id {
            sessions.detach(id, self.token);
        }
    }
}

/// Handles one Terminal or Control envelope. Returns a reply to send, if any.
///
/// `send` is passed in as well as a reply being returned, because the Attach arm must emit
/// `Attached` BEFORE the session paints the screen behind it — and the painting happens inside
/// `SessionStore::attach`, under the lock that keeps it from being interleaved with live output.
/// `peer` names the connection in the log lines a kill or a hand-off writes.
pub(crate) fn dispatch(
    envelope: &Envelope,
    sessions: &SessionStore,
    attachment: &mut Attachment,
    peer: &str,
    writer: &SharedWriter,
    send: &dyn Fn(&[u8]) -> bool,
) -> Option<Envelope> {
    let mut frames = FrameDecoder::new();
    frames.push(&envelope.payload);
    let frame = frames.next_frame().ok().flatten()?;

    let reply = |frame: Frame| {
        Some(Envelope::new(
            envelope.service,
            envelope.stream,
            frame.encode(),
        ))
    };

    match frame.kind {
        FrameKind::Attach => {
            let request = AttachRequest::decode(&frame.payload)?;
            let id = request.id?;
            // A remote pane's attach asks to be probed, so a client whose Mac has gone stops
            // counting as attached (#593) and has this connection closed, which ends its relay
            // (ADR 0075). Read from the environment the relay forwards whole, so any relay carries
            // it.
            let keepalive = crate::terminal::session::keepalive_requested(&request.env)
                .then(|| Arc::clone(&attachment.closer));
            // A new session must register its first client before its reader starts: a command
            // such as `echo` can exit before attach, taking its output and exit status with it.
            let attach = || {
                send(
                    &Envelope::new(
                        Service::Control,
                        envelope.stream,
                        Frame::control(FrameKind::Attached).encode(),
                    )
                    .encode(),
                )
                .then_some(())
                .ok_or(crate::terminal::session::SessionError::NotFound(
                    id.to_hyphenated(),
                ))?;
                sessions.attach_client(
                    id,
                    Arc::clone(writer),
                    envelope.stream,
                    Size {
                        columns: request.columns,
                        rows: request.rows,
                        x_pixels: request.x_pixels,
                        y_pixels: request.y_pixels,
                    },
                    keepalive,
                )
            };
            // Refused, not created, for a client that asked to attach only to what exists: see
            // `AttachRequest::existing_only`. Before any `Attached`, so the client can tell it
            // apart from a failure on a session it is already showing.
            //
            // Read ONCE, for both this and the choice below: read twice, a session that exited in
            // between would pass the refusal and then be created. With one read, that race ends in
            // `attach()` finding nothing, which the client already takes as "ended".
            let exists = sessions.contains(id);
            if request.existing_only && !exists {
                // A session that ended with its host, whose last screen was kept (#232,
                // `crate::terminal::screens`): `Attached`, the screen, and nothing after.
                // `attachment` stays unset, so this connection's input and resizes go nowhere, and
                // the pane shows the screen until its user closes it. Chunked, as
                // `SessionStore::attach` chunks a repaint: `Frame::encode` panics above the frame
                // cap.
                let ended = sessions
                    .hooks()
                    .screens
                    .get()
                    .and_then(|screens| screens.render(id, request.columns, request.rows));
                if let Some(screen) = ended {
                    let attached = Frame::control(FrameKind::Attached).encode();
                    if send(&Envelope::new(Service::Control, envelope.stream, attached).encode()) {
                        for chunk in screen.chunks(crate::terminal::session::READ_CHUNK) {
                            let output = Frame::new(FrameKind::Output, chunk.to_vec()).encode();
                            let output = Envelope::new(Service::Terminal, envelope.stream, output);
                            if !send(&output.encode()) {
                                break;
                            }
                        }
                    }
                    return None;
                }
                return reply(Frame::new(
                    FrameKind::Failure,
                    format!("session ended: {}", id.to_hyphenated()).into_bytes(),
                ));
            }
            // Create on first attach, reattach afterwards. One code path, so a client that
            // crashed and came back does not have to know which case it is in.
            let result = if exists {
                attach()
            } else {
                // Not `<shell>` with no arguments: see `shell::invocation`. Spawning the shell
                // bare cost the login profile and ghostty's shell integration, which showed up in
                // the app as panes stuck on the title the user's own prompt sets.
                // **The session's own variables do not reach the session's shell**, matching what
                // the Swift attach client has always done (`SessionAttachClient.makeRequest`
                // filters the same prefix before sending). Leaking them had two consequences, both
                // real: `workroomd attach` typed inside a pane picked up THAT pane's id and socket
                // from its own environment and attached a second relay to the session it was
                // running in, with the pty fanning output to both; and `run_attach`'s "was I
                // invoked by the app" test — which reads exactly these variables — was true for
                // anything the user typed in a pane, so the usage-instead-of-nested-shell guard
                // could never fire there.
                //
                // A remote pane attached from the Mac is built from this host instead, with only
                // the client's terminal and locale (`host_session`, ADR 0074).
                let (child_environment, session_shell, resources) = if request.host_environment {
                    let host = sessions
                        .hooks()
                        .host
                        .session(&request.env, attachment.peer.as_deref().unwrap_or_default());
                    (host.environment, host.shell, host.resources)
                } else {
                    (
                        request
                            .env
                            .iter()
                            .filter(|(key, _)| {
                                !key.to_string_lossy().starts_with("WORKROOM_SESSION_")
                            })
                            .cloned()
                            .collect(),
                        shell::user_shell(request.shell.clone()),
                        request
                            .resources
                            .clone()
                            .unwrap_or_default()
                            .to_string_lossy()
                            .into_owned(),
                    )
                };
                let mut invocation = shell::invocation(
                    &request
                        .command
                        .clone()
                        .unwrap_or_default()
                        .to_string_lossy(),
                    &session_shell,
                    &resources,
                    &child_environment,
                );
                if crate::terminal::run::is_requested(&request.env) {
                    let run_shell = if request.host_environment {
                        Some(OsString::from(&session_shell))
                    } else {
                        request.shell.clone()
                    };
                    match run_invocation(sessions, id, &request, run_shell, invocation.environment)
                    {
                        Ok(run) => invocation = run,
                        Err(reason) => {
                            return reply(Frame::new(FrameKind::Failure, reason.into_bytes()));
                        }
                    }
                }
                sessions.create_then(
                    SessionSpec {
                        id,
                        program: &invocation.program,
                        argv0: invocation.arguments.first().map(|a| a.as_os_str()),
                        args: &invocation.arguments[1..],
                        env: &invocation.environment,
                        cwd: request.cwd.as_deref(),
                        columns: request.columns,
                        rows: request.rows,
                        metadata: &session_metadata(&request.env),
                        interactive: invocation.interactive,
                    },
                    |_| attach(),
                )
            };
            match result {
                Ok((_, granted)) => {
                    attachment.id = Some(id);
                    attachment.token = granted;
                    None
                }
                Err(e) => reply(Frame::new(FrameKind::Failure, e.to_string().into_bytes())),
            }
        }
        FrameKind::Input => {
            let id = attachment.id?;
            // Through the session, not straight at the pty, for two reasons: it writes with
            // `write_all` (the master is non-blocking, so a paste bigger than the pty's input queue
            // short-writes and the tail would be dropped in silence), and typing is also how a
            // client CLAIMS the session's size, which only the session can arbitrate.
            sessions.write_input(id, attachment.token, &frame.payload);
            None
        }
        FrameKind::Resize => {
            let id = attachment.id?;
            if let Some(size) = decode_resize(&frame.payload) {
                // Recorded always, applied only if this client owns the size or nobody does — a
                // background window resizing must not move the pty out from under whoever is
                // typing in another one.
                sessions.resize(id, attachment.token, size);
            }
            None
        }
        FrameKind::List => reply(list_reply(encode_descriptor_list(&sessions.list()))),
        FrameKind::Kill => {
            // Answered, not dropped: a request with no reply holds the app's request open until its
            // timeout.
            let Some(id) = frame.payload.get(..16).and_then(SessionId::from_slice) else {
                return reply(Frame::new(
                    FrameKind::Failure,
                    b"a kill names one 16-byte session id".to_vec(),
                ));
            };
            crate::note!(
                "kill of session {} requested by {}",
                id.to_hyphenated(),
                peer
            );
            kill_off_the_reader(sessions, id, writer, envelope.service, envelope.stream)
        }
        FrameKind::Signal => {
            let (Some(id), Some(signal)) = (
                frame.payload.get(..16).and_then(SessionId::from_slice),
                frame
                    .payload
                    .get(16)
                    .and_then(|byte| RunSignal::from_u8(*byte)),
            ) else {
                return reply(Frame::new(
                    FrameKind::Failure,
                    b"a signal names one 16-byte session id and a run signal".to_vec(),
                ));
            };
            match sessions.signal_run(id, signal) {
                Ok(()) => reply(Frame::control(FrameKind::Acknowledged)),
                Err(RunSignalError::NotFound) => reply(Frame::new(
                    FrameKind::Failure,
                    format!("no session {}", id.to_hyphenated()).into_bytes(),
                )),
                Err(RunSignalError::NotARun) => reply(Frame::new(
                    FrameKind::Failure,
                    format!("not a run session: {}", id.to_hyphenated()).into_bytes(),
                )),
                Err(RunSignalError::Failed(e)) => reply(Frame::new(
                    FrameKind::Failure,
                    format!("could not signal session {}: {e}", id.to_hyphenated()).into_bytes(),
                )),
            }
        }
        FrameKind::Retag => match decode_retag(&frame.payload) {
            Err(why) => reply(Frame::new(FrameKind::Failure, why.as_bytes().to_vec())),
            Ok((id, workroom)) if sessions.set_workroom(id, workroom) => {
                reply(Frame::control(FrameKind::Acknowledged))
            }
            Ok((id, _)) => reply(Frame::new(
                FrameKind::Failure,
                format!("no session {}", id.to_hyphenated()).into_bytes(),
            )),
        },
        // What `relay` knows about this connection: its ssh variables, and nothing else is taken.
        // Never answered: the relay sends it into the client's stream, which expects no reply.
        FrameKind::Peer => {
            // The first one only: the relay sends one, straight after the greeting, so any later
            // one is the client's own and changes nothing.
            if attachment.peer.is_some() {
                return None;
            }
            attachment.peer = Some(frame
                .payload
                .split(|byte| *byte == 0)
                .filter_map(|entry| {
                    let split = entry.iter().position(|byte| *byte == b'=')?;
                    let key = OsStr::from_bytes(&entry[..split]);
                    crate::terminal::host_session::PEER_VARIABLES
                        .iter()
                        .any(|name| key == *name)
                        .then(|| {
                            (
                                key.to_os_string(),
                                OsStr::from_bytes(&entry[split + 1..]).into(),
                            )
                        })
                })
                .collect());
            None
        }
        FrameKind::KillAll => {
            crate::note!("kill of every session requested by {}", peer);
            sessions.kill_all();
            reply(Frame::control(FrameKind::Acknowledged))
        }
        // `Acknowledged` with "current" when the binary is this program already, "handing off"
        // just before the exec (which then ends this connection), and `Failure` with the reason
        // when it refused or the exec failed. See `crate::daemon::handoff`.
        FrameKind::HandOff => {
            let (&force, path) = frame.payload.split_first()?;
            let binary = PathBuf::from(OsStr::from_bytes(path));
            let handing_off = || {
                let frame = Frame::new(FrameKind::Acknowledged, b"handing off".to_vec());
                send(&Envelope::new(envelope.service, envelope.stream, frame.encode()).encode())
            };
            crate::note!(
                "hand-off to {} requested by {}{}",
                binary.display(),
                peer,
                if force != 0 { " (forced)" } else { "" }
            );
            match crate::daemon::handoff::hand_off(sessions, &binary, force != 0, handing_off) {
                Ok(()) => {
                    crate::note!("hand-off not needed: {} is this program", binary.display());
                    reply(Frame::new(FrameKind::Acknowledged, b"current".to_vec()))
                }
                Err(reason) => {
                    crate::note!("hand-off refused: {reason}");
                    let mut reason = reason.to_string().into_bytes();
                    reason.truncate(crate::daemon::handoff::MAX_REASON);
                    reply(Frame::new(FrameKind::Failure, reason))
                }
            }
        }
        _ => None,
    }
}

/// What a run session's pty runs (#522): this binary's `run-supervisor` around the request's
/// command, writing to the status file the store names for `id`. `environment` is what a command
/// session would get (`shell::invocation`): the client's, with the shell integration's variables.
/// `SHELL` is the one the client asked for, which `run-supervisor` runs the command in.
fn run_invocation(
    sessions: &SessionStore,
    id: SessionId,
    request: &AttachRequest,
    shell: Option<OsString>,
    mut environment: Vec<(OsString, OsString)>,
) -> Result<shell::Invocation, String> {
    let command = request.command.clone().unwrap_or_default();
    if command.is_empty() {
        return Err(format!("run session {} has no command", id.to_hyphenated()));
    }
    let Some(status) = sessions.hooks().runs.status_path(id) else {
        return Err("this daemon keeps no run sessions: it serves no socket".to_string());
    };
    // A file left by an earlier session under this id must not be read as this one's.
    let _ = std::fs::remove_file(&status);
    let binary = crate::daemon::handoff::own_binary()
        .map_err(|e| format!("could not find this daemon's own binary: {e}"))?;
    if let Some(shell) = shell.filter(|shell| !shell.is_empty()) {
        environment.retain(|(key, _)| key != "SHELL");
        environment.push((OsString::from("SHELL"), shell));
    }
    Ok(shell::Invocation {
        program: binary.into_os_string(),
        arguments: [
            OsString::from("workroomd"),
            OsString::from("run-supervisor"),
            OsString::from("--status"),
            status.into_os_string(),
            OsString::from("--"),
            command,
        ]
        .into(),
        environment,
        interactive: false,
    })
}

/// Wraps an encoded session list in the frame to send, refusing one that is too big.
///
/// A `Sessions` reply grows with the session count and each session's cwd, and unlike output it
/// goes out as ONE frame. `Frame::encode` panics past the cap rather than truncating — and even if
/// it did not, a client that sees a declared length over the cap fails its decoder permanently, so
/// an over-long list would not merely fail, it would poison every later frame on that connection.
/// Answer with the failure the app already knows how to show instead.
///
/// The frame then goes out inside an envelope, whose own cap `Envelope::encode` asserts, and the
/// frame's header counts against it. So the limit is the smaller of the frame cap and what an
/// envelope leaves room for (#246).
fn list_reply(payload: Vec<u8>) -> Frame {
    let cap = MAX_PAYLOAD_SIZE.min(MAX_ENVELOPE_PAYLOAD - HEADER_SIZE);
    if payload.len() > cap {
        return Frame::new(
            FrameKind::Failure,
            format!(
                "session list of {} bytes exceeds the {cap}-byte reply cap",
                payload.len()
            )
            .into_bytes(),
        );
    }
    Frame::new(FrameKind::Sessions, payload)
}

/// Ends `id` on a thread of its own and acknowledges it there, once the shell is gone, counted in
/// `SessionStore::is_killing` meanwhile. A shell that declines SIGHUP holds `SessionStore::kill`
/// for `SIGHUP_GRACE` before the SIGKILL, and one stuck in the kernel holds it in `waitpid` for as
/// long as that lasts. Either, run on the connection's reader, held up every other request on the
/// connection behind it: the app's service connection to a host carries its VCS, File and
/// forwarding traffic as well (#283).
///
/// Only a live session gets a thread, or one another kill is still ending, which this kill waits on
/// so that it too is acknowledged only once the shell is gone. An id the store does not hold costs
/// the removal of a screen record and a refusal kept for `REFUSED_ID_WINDOW`, so it is ended here,
/// and a stream of kills for ids that are not sessions cannot start a thread apiece.
fn kill_off_the_reader(
    sessions: &SessionStore,
    id: SessionId,
    writer: &SharedWriter,
    service: Service,
    stream: u32,
) -> Option<Envelope> {
    let acknowledged = move || {
        Envelope::new(
            service,
            stream,
            Frame::control(FrameKind::Acknowledged).encode(),
        )
    };
    // First, so an attach still on its way cannot start the session after this has looked (#297).
    sessions.refuse(id);
    if sessions.end_if_absent(id) {
        return Some(acknowledged());
    }
    // Counted before the thread starts, so a hand-off read next on this connection already sees it.
    let in_flight = sessions.kill_in_flight();
    let (store, shared) = (sessions.clone(), Arc::clone(writer));
    let spawned = std::thread::Builder::new().spawn(move || {
        let _in_flight = in_flight;
        store.kill(id);
        rpc::write(&shared, &acknowledged().encode());
    });
    if spawned.is_ok() {
        return None;
    }
    // No thread to be had: the kill happens here after all rather than not at all.
    sessions.kill(id);
    Some(acknowledged())
}

/// The session list as a `Sessions` reply carries it (`wr_protocol::terminal`).
///
/// Each session's metadata: the foreground command, under the key the app's own daemon uses for
/// it, so a pane title resolves identically on either backend; then what the client said about the
/// session, which is how the app finds a workroom's sessions (#255). The Claude profile is sent
/// only for a confirmed `claude`, empty when unset; its absence tells the app there is no account
/// to show (#480).
fn encode_descriptor_list(sessions: &[SessionInfo]) -> Vec<u8> {
    let descriptors: Vec<SessionDescriptor<'_>> = sessions
        .iter()
        .map(|info| SessionDescriptor {
            id: info.id,
            pid: info.pid,
            cwd: info.cwd.as_deref().unwrap_or(""),
            attached: info.attached,
            metadata: info
                .foreground
                .iter()
                .map(|command| ("command", command.as_str()))
                .chain(
                    info.claude_profile
                        .iter()
                        .map(|profile| ("claude_profile", profile.as_str())),
                )
                .chain(
                    info.metadata
                        .iter()
                        .map(|(key, value)| (key.as_str(), value.as_str())),
                )
                .collect(),
        })
        .collect();
    wr_protocol::terminal::encode_descriptor_list(&descriptors)
}

/// The longest title a session keeps, cut at a character boundary. Every session's metadata goes
/// out in one list reply (`list_reply`), so one long title must not be able to fill it.
const MAX_TITLE_BYTES: usize = 256;

/// What the app said about a session it creates: its workroom and title, from the
/// variables it puts in the attach command's environment (`PersistentSessionService.launchEnvironment`,
/// mapped through `SessionMetadataKey.environmentVariables`), which the attach client forwards with
/// the rest of its environment. Under the keys the app reads them back by (`SessionMetadataKey`).
/// The app's `project` is not kept: nothing reads it, and it would double the list's worst case.
///
/// The shell never sees these (the create path drops `WORKROOM_SESSION_*` from its environment);
/// before #255 they were dropped here too, so a deleted workroom's sessions were never found.
fn session_metadata(env: &[(OsString, OsString)]) -> Vec<(String, String)> {
    let get = |name: &str| {
        env.iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.to_string_lossy().into_owned())
            .filter(|value| !value.is_empty())
    };
    let mut metadata = Vec::new();
    if let Some(workroom) = get("WORKROOM_SESSION_WORKROOM") {
        if workroom.len() > MAX_WORKROOM_BYTES {
            return Vec::new();
        }
        metadata.push(("workroom".to_string(), workroom));
    }
    if let Some(mut title) = get("WORKROOM_SESSION_TITLE") {
        if title.len() > MAX_TITLE_BYTES {
            let mut end = MAX_TITLE_BYTES;
            while !title.is_char_boundary(end) {
                end -= 1;
            }
            title.truncate(end);
        }
        metadata.push(("title".to_string(), title));
    }
    if crate::terminal::run::is_requested(env) {
        metadata.push((
            crate::terminal::run::KIND_KEY.to_string(),
            crate::terminal::run::RUN_KIND.to_string(),
        ));
    }
    metadata
}

#[cfg(test)]
mod tests;
