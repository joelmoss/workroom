//! `session.new`, `session.close` and `session.run_control` (#693): the terminal API opening,
//! closing and restarting terminals.
//!
//! **`session.new`** makes a session the way the caller's own was made (`Recipe`: its environment,
//! shell and Ghostty resources), tagged with the caller's scope, then asks the app to show it. The
//! asking is the `session.created` event's `opened` (`will_open`): who asked (`by`), whether as a
//! split (`split`) and which Mac is to show it (`hostname`). The Mac is the daemon's choice, so
//! every Mac that hears the event comes to the same answer ([`showing_mac`]): the one whose pane
//! has the caller's session, among the caller's live pane clients, the size owner first (the one
//! its user last typed or clicked in, ADR 0042), else the one that attached last. None shows it
//! when none has: every Mac lists it with the detached sessions. Tabs and layouts stay the app's
//! (ADR 0069); the daemon only says what was asked.
//!
//! **`session.close`** ends a session, and its `session.ended` says `closed`, so the app closes
//! its tab or split rather than leave the pane showing that its shell exited. A run session's
//! supervisor is asked to quit first, as the app's own close of a run tab does (#7), so its
//! command stops cleanly; one that hasn't within [`QUIT_GRACE`] is killed. The caller's own
//! session is `RefusedSelf` without `allow_self`, as for `terminal.send`.
//!
//! **`session.run_control`** restarts or stops a run session's command through its supervisor's
//! run signal (`SessionStore::signal_run`), as the app's Run tab does. A session that is no run is
//! `NotARun`.

use std::ffi::{OsStr, OsString};
use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{ApiError, Call, caller_schema, kind, listed, resolve};
use crate::terminal::session::{
    ClientInfo, ClientKind, KeepaliveState, Recipe, SessionId, SessionStore,
};

pub const NEW: &str = "session.new";
pub const CLOSE: &str = "session.close";
pub const RUN_CONTROL: &str = "session.run_control";

/// The metadata key a session `session.new` made carries: who asked for it, the caller's id, or
/// `outside` for a request from no pane. The app reads it so a run made this way is never taken
/// for the workroom's own Run (D7).
pub const OPENED_BY_KEY: &str = "opened_by";

/// The longest title a session keeps, as an attach's (`dispatch::MAX_TITLE_BYTES`).
const MAX_TITLE_BYTES: usize = 256;

/// How long `session.close` gives a run's supervisor to quit before the session is killed: its
/// own SIGKILL of a command that ignores the quit comes after 6 s.
pub const QUIT_GRACE: Duration = Duration::from_secs(7);

/// How long `session.run_control` waits for a run's supervisor to write its first status, which
/// it does once its traps are set, before it signals it.
const SUPERVISOR_START: Duration = Duration::from_secs(5);

pub const NEW_ERRORS: &[&str] = &[kind::NOT_A_DIRECTORY, kind::BUSY, kind::INTERNAL_ERROR];

pub const CLOSE_ERRORS: &[&str] = &[
    kind::TARGET_NOT_FOUND,
    kind::TARGET_AMBIGUOUS,
    kind::REFUSED_SELF,
    kind::SESSION_ENDED,
    kind::BUSY,
];

pub const RUN_CONTROL_ERRORS: &[&str] = &[
    kind::TARGET_NOT_FOUND,
    kind::TARGET_AMBIGUOUS,
    kind::NOT_A_RUN,
    kind::SESSION_ENDED,
    kind::INTERNAL_ERROR,
];

/// What a split asks for: a pane on the caller's right, or below it.
const SPLITS: [&str; 2] = ["right", "down"];

/// The actions `session.run_control` takes.
const ACTIONS: [&str; 2] = ["restart", "stop"];

fn target_schema() -> Value {
    json!({
        "type": "string",
        "description": "A session's id or id suffix, its label, or its live title.",
    })
}

pub fn new_input() -> Value {
    json!({
        "type": "object",
        "properties": {
            "title": {
                "type": "string",
                "description": "Its label, and the name of its tab in the app.",
            },
            "run": {
                "type": "string",
                "description": "A command to run in it, under a run supervisor as the app's Run \
                                tab runs one, so `session.run_control` restarts and stops it and \
                                `terminal.wait` waits on its run state. Without it, a login \
                                shell.",
            },
            "cwd": {
                "type": "string",
                "description": "The absolute path of the folder it starts in; the caller's \
                                folder when left out, or the home folder from no pane. \
                                `workroom new` sends its own.",
            },
            "split": {
                "type": "string",
                "enum": SPLITS,
                "description": "Show it as a split beside the caller's pane, on its right or \
                                below it, when the Mac showing that pane has it on screen; a tab \
                                otherwise.",
            },
        },
    })
}

/// `opened`: what `session.new` asked of the app, in its result and its `session.created`.
pub fn opened_schema() -> Value {
    json!({
        "type": ["object", "null"],
        "description": "`session.created`, and `session.new`'s result: what `session.new` asked \
                        of the app, null for a session made any other way. The Mac `hostname` \
                        names shows it, beside the pane of the session `by` names, as a split \
                        when `split` asks for one and that pane is on screen, else as a tab; \
                        every other Mac lists it with the detached sessions. With `hostname` \
                        null, no Mac shows the caller's pane, and every one lists it as \
                        detached.",
        "required": ["by", "split", "hostname"],
        "properties": {
            "by": {
                "type": ["string", "null"],
                "description": "The id of the session that asked for it; null from no pane.",
            },
            "split": {
                "type": ["string", "null"],
                "enum": ["right", "down", null],
                "description": "The split asked for, or null for a tab.",
            },
            "hostname": {
                "type": ["string", "null"],
                "description": "The Mac to show it, as its pane's attach named it: the caller's \
                                pane client that owns its size, else the one that attached \
                                last, of those still answering. Null when none.",
            },
        },
    })
}

pub fn new_output() -> Value {
    json!({
        "type": "object",
        "required": ["session", "caller", "opened"],
        "properties": {
            "session": super::session_schema(),
            "caller": caller_schema(),
            "opened": opened_schema(),
        },
    })
}

pub fn new_params_example() -> Value {
    json!({"title": "dev server", "run": "npm run dev", "split": "right"})
}

pub fn new_result_example() -> Value {
    let mut session = super::run_session_example();
    session["coding_agent"] = Value::Null;
    json!({
        "session": session,
        "caller": super::agent_session_example()["id"],
        "opened": {
            "by": super::agent_session_example()["id"],
            "split": "right",
            "hostname": "joels-macbook.local",
        },
    })
}

pub fn close_input() -> Value {
    json!({
        "type": "object",
        "required": ["target"],
        "properties": {
            "target": {
                "type": "string",
                "description": "A session's id or id suffix, or its label: never its live title, \
                                which its program sets and anything it prints can change, since \
                                a close can't be undone.",
            },
            "allow_self": {
                "type": "boolean",
                "default": false,
                "description": "Close the session this request comes from, which is otherwise \
                                refused as `RefusedSelf`.",
            },
        },
    })
}

pub fn close_output() -> Value {
    json!({
        "type": "object",
        "required": ["session", "caller"],
        "properties": {
            "session": {"type": "string", "description": "The id of the session closed."},
            "caller": caller_schema(),
        },
    })
}

pub fn close_params_example() -> Value {
    json!({"target": "dev server"})
}

pub fn close_result_example() -> Value {
    json!({
        "session": super::run_session_example()["id"],
        "caller": super::agent_session_example()["id"],
    })
}

pub fn run_control_input() -> Value {
    json!({
        "type": "object",
        "required": ["target", "action"],
        "properties": {
            "target": target_schema(),
            "action": {
                "type": "string",
                "enum": ACTIONS,
                "description": "`restart`: stop the run's command and start it again in place. \
                                `stop`: stop it and keep the pane.",
            },
        },
    })
}

pub fn run_control_output() -> Value {
    json!({
        "type": "object",
        "required": ["session", "caller", "action"],
        "properties": {
            "session": {"type": "string", "description": "The id of the run session."},
            "caller": caller_schema(),
            "action": {"type": "string", "enum": ACTIONS},
        },
    })
}

pub fn run_control_params_example() -> Value {
    json!({"target": "dev server", "action": "restart"})
}

pub fn run_control_result_example() -> Value {
    json!({
        "session": super::run_session_example()["id"],
        "caller": super::agent_session_example()["id"],
        "action": "restart",
    })
}

/// A parameter that is a string when given, `None` when left out or null.
fn text<'a>(call: &'a Call, method: &str, name: &str) -> Result<Option<&'a str>, ApiError> {
    match call.params.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.as_str())),
        Some(_) => Err(ApiError::invalid(format!(
            "{method}'s `{name}` is a string"
        ))),
    }
}

/// The parsed `session.new` parameters.
struct Asked {
    title: Option<String>,
    run: Option<String>,
    cwd: Option<String>,
    split: Option<&'static str>,
}

fn asked(call: &Call) -> Result<Asked, ApiError> {
    let title = text(call, NEW, "title")?
        .filter(|title| !title.is_empty())
        .map(|title| {
            let mut end = title.len().min(MAX_TITLE_BYTES);
            while !title.is_char_boundary(end) {
                end -= 1;
            }
            title[..end].to_string()
        });
    let run = match text(call, NEW, "run")? {
        Some(run) if run.trim().is_empty() => {
            return Err(ApiError::invalid(format!(
                "{NEW}'s `run` is a command; leave it out for a shell"
            )));
        }
        Some(run) if run.contains('\0') => {
            return Err(ApiError::invalid(format!("{NEW}'s `run` holds a NUL")));
        }
        run => run.map(str::to_string),
    };
    let cwd = match text(call, NEW, "cwd")? {
        Some(cwd) if !Path::new(cwd).is_absolute() || cwd.contains('\0') => {
            return Err(ApiError::invalid(format!(
                "{NEW}'s `cwd` is an absolute path"
            )));
        }
        cwd => cwd.map(str::to_string),
    };
    let split = match text(call, NEW, "split")? {
        None => None,
        Some(split) => Some(
            SPLITS
                .into_iter()
                .find(|known| *known == split)
                .ok_or_else(|| ApiError::invalid(format!("{NEW}'s `split` is right or down")))?,
        ),
    };
    Ok(Asked {
        title,
        run,
        cwd,
        split,
    })
}

/// The Mac to show a session `session.new` made beside its caller's pane: the hostname of the
/// caller's pane client that owns its size, else of the one that attached last, among those that
/// say which Mac they are on and still answer their probes. None when no pane has the caller's
/// session, which every Mac then lists as detached.
pub fn showing_mac(clients: &[ClientInfo]) -> Option<String> {
    let panes: Vec<&ClientInfo> = clients
        .iter()
        .filter(|client| {
            client.identity.kind == Some(ClientKind::Pane)
                && client.identity.hostname.is_some()
                && client.keepalive != KeepaliveState::Stale
        })
        .collect();
    panes
        .iter()
        .find(|client| client.owns_size)
        .or_else(|| {
            panes
                .iter()
                .max_by_key(|client| (client.attached_at, client.id))
        })
        .and_then(|client| client.identity.hostname.clone())
}

/// What a session is built from when its caller's recipe isn't known: from no pane, or from one a
/// hand-off adopted. The daemon's own environment, held to what a host session takes from it
/// (`host_session`), with Ghostty's terminal and its resources when the daemon keeps them, and the
/// shell the daemon's `SHELL` names, else its account's.
fn fallback_recipe(sessions: &SessionStore) -> Recipe {
    let client = [
        (OsString::from("TERM"), OsString::from("xterm-ghostty")),
        (OsString::from("COLORTERM"), OsString::from("truecolor")),
    ];
    let mut host = sessions.hooks().host.session(&client, None);
    if let Some(shell) = std::env::var_os("SHELL").filter(|shell| !shell.is_empty()) {
        host.shell = shell.to_string_lossy().into_owned();
        host.environment.retain(|(key, _)| key != "SHELL");
        host.environment.push((OsString::from("SHELL"), shell));
    }
    Recipe {
        run_shell: Some(OsString::from(&host.shell)),
        environment: host.environment,
        shell: host.shell,
        resources: host.resources,
        commands: host.commands,
    }
}

/// The value of `key` in `environment`.
fn variable<'a>(environment: &'a [(OsString, OsString)], key: &str) -> Option<&'a OsStr> {
    environment
        .iter()
        .find(|(name, _)| name == key)
        .map(|(_, value)| value.as_os_str())
}

/// `session.new`: the parameters checked, the session made as the caller's was, in the caller's
/// scope, and the app asked to show it.
pub fn create(call: &Call) -> Result<Value, ApiError> {
    let asked = asked(call)?;
    let sessions = call.sessions;
    if let Some(cwd) = &asked.cwd
        && !Path::new(cwd).is_dir()
    {
        return Err(ApiError::new(
            kind::NOT_A_DIRECTORY,
            format!("{cwd:?} is not a folder this daemon can start a session in"),
        ));
    }
    let caller_id = call
        .caller
        .as_deref()
        .and_then(|caller| wr_protocol::terminal::parse_session_id(OsStr::new(caller)));
    let caller = caller_id.and_then(|id| {
        sessions
            .described()
            .into_iter()
            .find(|session| session.info.id == id)
    });
    let recipe = caller_id
        .and_then(|id| sessions.recipe(id))
        .map(|recipe| (*recipe).clone())
        .unwrap_or_else(|| fallback_recipe(sessions));
    // The folder asked for, else the caller's, else the home folder, else the root: a default is
    // never refused, since nobody chose it.
    let cwd = asked
        .cwd
        .clone()
        .or_else(|| {
            caller
                .as_ref()
                .and_then(|caller| caller.info.cwd.clone())
                .filter(|cwd| Path::new(cwd).is_dir())
        })
        .or_else(|| {
            variable(&recipe.environment, "HOME")
                .map(|home| home.to_string_lossy().into_owned())
                .filter(|home| Path::new(home).is_dir())
        })
        .unwrap_or_else(|| "/".to_string());
    let (columns, rows) = caller_id
        .and_then(|id| sessions.pty_size(id))
        .unwrap_or((0, 0));
    let workroom = caller.as_ref().and_then(|caller| {
        caller
            .info
            .metadata
            .iter()
            .find(|(key, _)| key == "workroom")
            .map(|(_, value)| value.clone())
    });
    let mut metadata = Vec::new();
    if let Some(workroom) = workroom {
        metadata.push(("workroom".to_string(), workroom));
    }
    if let Some(title) = &asked.title {
        metadata.push(("title".to_string(), title.clone()));
    }
    if asked.run.is_some() {
        metadata.push((
            crate::terminal::run::KIND_KEY.to_string(),
            crate::terminal::run::RUN_KIND.to_string(),
        ));
    }
    metadata.push((
        OPENED_BY_KEY.to_string(),
        call.caller.clone().unwrap_or_else(|| "outside".to_string()),
    ));
    let opened = json!({
        "by": call.caller,
        "split": asked.split,
        "hostname": caller.as_ref().and_then(|caller| showing_mac(&caller.clients)),
    });

    // Held while the session is made and told, so a hand-off waits for it rather than carry a
    // table without it; refused while one is under way.
    let Some(_permit) = crate::daemon::rpc::Permit::acquire() else {
        return Err(ApiError::new(
            kind::BUSY,
            "the daemon is being handed off to its next program, or is at its limit on \
             requests at once; try again when it has been",
        ));
    };
    let id = crate::terminal::program_status::new_boot();
    let hub = &sessions.hooks().events;
    hub.will_open(id, opened.clone());
    let launched = crate::terminal::dispatch::launch(
        sessions,
        crate::terminal::dispatch::Launch {
            id,
            recipe,
            command: asked.run.clone().map(OsString::from).unwrap_or_default(),
            run: asked.run.is_some(),
            cwd: Some(OsStr::new(&cwd)),
            columns,
            rows,
            metadata,
        },
        Ok,
    );
    if let Err(reason) = launched {
        hub.forget_asked(id);
        return Err(ApiError::new(
            kind::INTERNAL_ERROR,
            format!("the session could not be started: {reason}"),
        ));
    }
    let hyphenated = id.to_hyphenated();
    let session = listed(sessions)
        .into_iter()
        .find(|session| session["id"] == hyphenated.as_str())
        .ok_or_else(|| {
            ApiError::new(
                kind::SESSION_ENDED,
                format!("session {hyphenated} ended as it started"),
            )
        })?;
    Ok(json!({"session": session, "caller": call.caller, "opened": opened}))
}

/// The one session `target` names, resolved as every target is, and its id.
/// `by_title` false leaves out the last step, the live title, which the session's program sets
/// and anything printed can change: `session.close`'s target, since a close can't be undone.
fn resolved(
    call: &Call,
    method: &str,
    by_title: bool,
) -> Result<(Value, SessionId, String), ApiError> {
    let target = text(call, method, "target")?
        .ok_or_else(|| ApiError::invalid(format!("{method} needs a string `target`")))?;
    let full = listed(call.sessions);
    let mut listing = full.clone();
    if !by_title {
        for session in &mut listing {
            session["title"] = Value::Null;
        }
    }
    let session = resolve(&listing, target).map_err(|mut error| {
        if !by_title && error.kind == kind::TARGET_NOT_FOUND {
            error.message.push_str(
                "; a close names a session by its id, an id suffix or its label, never its live \
                 title",
            );
        }
        // The matches as they are listed, live titles and all.
        for matched in &mut error.matches {
            if let Some(listed) = full.iter().find(|session| session["id"] == matched["id"]) {
                *matched = listed.clone();
            }
        }
        error
    })?;
    let hyphenated = session["id"].as_str().unwrap_or_default().to_string();
    let id = wr_protocol::terminal::parse_session_id(OsStr::new(&hyphenated))
        .ok_or_else(|| ApiError::new(kind::SESSION_ENDED, format!("session {target:?} ended")))?;
    Ok((session, id, hyphenated))
}

/// `session.close`: the target resolved and checked, its run's supervisor asked to quit, then the
/// session ended, its `session.ended` saying `closed`. Answered once its shell has gone, from a
/// thread of its own: a kill waits out a shell's SIGHUP grace.
pub fn close(call: &Call) -> Result<Value, ApiError> {
    let allow_self = match call.params.get("allow_self") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(allow)) => *allow,
        Some(_) => {
            return Err(ApiError::invalid(format!(
                "{CLOSE}'s `allow_self` is true or false"
            )));
        }
    };
    let (session, id, hyphenated) = resolved(call, CLOSE, false)?;
    let target = call.params["target"].as_str().unwrap_or_default();
    if !allow_self && call.caller.as_deref() == Some(hyphenated.as_str()) {
        return Err(ApiError::new(
            kind::REFUSED_SELF,
            format!(
                "{target:?} is the session this request comes from, and closing it would end \
                 the caller; `allow_self` closes it anyway"
            ),
        ));
    }
    let ended = || {
        ApiError::new(
            kind::SESSION_ENDED,
            format!("session {hyphenated} ended before it could be closed"),
        )
    };
    let sessions = call.sessions;
    let Some(_permit) = crate::daemon::rpc::Permit::acquire() else {
        return Err(ApiError::new(
            kind::BUSY,
            "the daemon is being handed off to its next program, or is at its limit on \
             requests at once; try again when it has been",
        ));
    };
    let hub = &sessions.hooks().events;
    hub.will_close(id);
    // First, as every kill refuses first (#297): a pane's attach on its way can't start the
    // session again under its id, whether the run quits by itself or is killed.
    sessions.refuse(id);
    if session["run"] == true
        && sessions
            .signal_run(id, wr_protocol::frame::RunSignal::Quit)
            .is_ok()
    {
        let deadline = Instant::now() + QUIT_GRACE;
        while sessions.contains(id) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        if !sessions.contains(id) {
            return Ok(json!({"session": hyphenated, "caller": call.caller}));
        }
    }
    if !sessions.kill(id) {
        hub.forget_asked(id);
        return Err(ended());
    }
    Ok(json!({"session": hyphenated, "caller": call.caller}))
}

/// `session.run_control`: the run signal `action` names, sent to the target's supervisor.
pub fn run_control(call: &Call) -> Result<Value, ApiError> {
    let action = text(call, RUN_CONTROL, "action")?
        .and_then(|action| ACTIONS.into_iter().find(|known| *known == action))
        .ok_or_else(|| ApiError::invalid(format!("{RUN_CONTROL}'s `action` is restart or stop")))?;
    let (session, id, hyphenated) = resolved(call, RUN_CONTROL, true)?;
    let not_a_run = || {
        ApiError::new(
            kind::NOT_A_RUN,
            format!(
                "session {hyphenated} is no run session: only a run's command can be restarted \
                 or stopped (`workroom new --run`, or the app's Run tab)"
            ),
        )
    };
    // At once, before any wait for a supervisor a shell never has.
    if session["run"] != true {
        return Err(not_a_run());
    }
    // A supervisor sent its signal before it has set its traps dies of it, taking its run with
    // it: a `run-control` straight after `new --run`. Its first status comes after them.
    if let Some(status) = call.sessions.hooks().runs.status_path(id) {
        let deadline = Instant::now() + SUPERVISOR_START;
        while !status.exists() && call.sessions.contains(id) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    let signal = match action {
        "restart" => wr_protocol::frame::RunSignal::Restart,
        _ => wr_protocol::frame::RunSignal::Stop,
    };
    use crate::terminal::session::RunSignalError;
    match call.sessions.signal_run(id, signal) {
        Ok(()) => Ok(json!({"session": hyphenated, "caller": call.caller, "action": action})),
        Err(RunSignalError::NotARun) => Err(not_a_run()),
        Err(RunSignalError::NotFound) => Err(ApiError::new(
            kind::SESSION_ENDED,
            format!("session {hyphenated} ended before it could be signalled"),
        )),
        Err(RunSignalError::Failed(error)) => Err(ApiError::new(
            kind::INTERNAL_ERROR,
            format!("session {hyphenated}'s supervisor could not be signalled: {error}"),
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::session::ClientIdentity;

    fn client(id: u64, kind: Option<ClientKind>, host: Option<&str>, at: u64) -> ClientInfo {
        ClientInfo {
            id,
            identity: ClientIdentity {
                kind,
                hostname: host.map(str::to_string),
            },
            attached_at: at,
            columns: 80,
            rows: 24,
            owns_size: false,
            keepalive: KeepaliveState::Answering,
        }
    }

    /// The size owner's Mac, else the last to attach; a pane that says no Mac, one gone stale and
    /// a client that is no pane never count, and with none of them, no Mac shows it.
    #[test]
    fn the_mac_shown_is_the_size_owners_else_the_last_pane_to_attach() {
        let laptop = client(1, Some(ClientKind::Pane), Some("laptop"), 100);
        let mut studio = client(2, Some(ClientKind::Pane), Some("studio"), 200);
        assert_eq!(
            showing_mac(&[laptop.clone(), studio.clone()]),
            Some("studio".into())
        );
        let mut owner = laptop.clone();
        owner.owns_size = true;
        assert_eq!(
            showing_mac(&[owner.clone(), studio.clone()]),
            Some("laptop".into())
        );
        studio.keepalive = KeepaliveState::Stale;
        assert_eq!(
            showing_mac(&[laptop.clone(), studio]),
            Some("laptop".into())
        );
        let mut stale_owner = owner;
        stale_owner.keepalive = KeepaliveState::Stale;
        let later = client(3, Some(ClientKind::Pane), Some("mini"), 300);
        assert_eq!(showing_mac(&[stale_owner, later]), Some("mini".into()));
        let cli = client(4, Some(ClientKind::Cli), Some("laptop"), 400);
        let unnamed = client(5, Some(ClientKind::Pane), None, 500);
        let unknown = client(6, None, Some("laptop"), 600);
        assert_eq!(showing_mac(&[cli, unnamed, unknown]), None);
        assert_eq!(showing_mac(&[]), None);
    }
}
