//! `terminal.wait` (#690): its parameters and result, and the request's side of a wait. The
//! request is answered on its own stream once the wait ends, by a thread of its own, so the
//! connection goes on reading meanwhile; the session's side is `crate::terminal::wait`.
//!
//! Exactly one condition: `status`, `run`, `regex`, `ended` or `command_finished`. A status, a run
//! state and the session's end are states, so one already true meets the wait at once. A regex
//! and a command end are events: only output that arrives after the wait starts counts (and the
//! screen as it is then, with `include_screen`), and only a command that ends after it.

use std::sync::Arc;
use std::sync::atomic::AtomicUsize;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{ApiError, Call, Slot, kind, listed, resolve};
use crate::daemon::rpc::SharedWriter;
use crate::terminal::program_status::State;
use crate::terminal::session::{SessionId, SessionStore};
use crate::terminal::wait::{Condition, Matcher, Met, Outcome, RunState, Waiter};
use crate::util::lock_or_recover;

pub const NAME: &str = "terminal.wait";

const STATES: [&str; 5] = ["idle", "working", "done", "blocked", "error"];

/// The names of the conditions, as `params` and the result's `condition` spell them.
const CONDITIONS: [&str; 5] = ["status", "run", "regex", "ended", "command_finished"];

pub fn input() -> Value {
    let run_states: Vec<&str> = RunState::ALL.iter().map(|state| state.name()).collect();
    json!({
        "type": "object",
        "required": ["target"],
        "description": "Exactly one of `status`, `run`, `regex`, `ended` or `command_finished`.",
        "properties": {
            "target": {
                "type": "string",
                "description": "The session, as `session.resolve` takes it.",
            },
            "status": {
                "type": "string",
                "enum": STATES,
                "description": "Wait for the session's coding agent to have this program status, as \
                                `session.list` reports it; now counts.",
            },
            "run": {
                "type": "string",
                "enum": run_states,
                "description": "Wait for a run session's run to be in this state; now counts.",
            },
            "exit_code": {
                "type": "integer",
                "description": "With `run: exited`, the code the run should exit with. The wait \
                                still answers when the run exits, whatever its code: with this \
                                one, as any met wait does; with another, `ExitCodeMismatch`, \
                                whose message says which.",
            },
            "regex": {
                "type": "string",
                "description": "Wait for output matching this regex (Rust `regex` syntax), with \
                                escape sequences stripped. Only output after the wait starts \
                                counts; `^` and `$` match at line ends, `\\r\\n` included. A match \
                                is at most 16 KiB.",
            },
            "include_screen": {
                "type": "boolean",
                "description": "With `regex`, also match the screen as it is when the wait starts.",
            },
            "ended": {
                "type": "boolean",
                "description": "`true`: wait for the session to end; already ended counts.",
            },
            "command_finished": {
                "type": "boolean",
                "description": "`true`: wait for the next command to finish (the shell's OSC 133 \
                                command-end mark): the first to end after the wait starts, \
                                whether it was running then or starts later. A session whose \
                                shell has sent no marks fails with `NoShellIntegration`.",
            },
            "timeout_ms": {
                "type": "integer",
                "description": "Fail with `WaitTimeout` after this many milliseconds; no limit \
                                when left out.",
            },
        },
    })
}

pub fn output() -> Value {
    let run_states: Vec<Value> = RunState::ALL
        .iter()
        .map(|state| json!(state.name()))
        .chain([Value::Null])
        .collect();
    let mut states: Vec<Value> = STATES.iter().map(|state| json!(state)).collect();
    states.push(Value::Null);
    json!({
        "type": "object",
        "required": ["session", "condition", "status", "run_state", "match", "exit_code"],
        "properties": {
            "session": {"type": "string", "description": "The session's id."},
            "condition": {"type": "string", "enum": CONDITIONS},
            "status": {
                "type": ["string", "null"],
                "enum": states,
                "description": "The program status reached, for `status`.",
            },
            "run_state": {
                "type": ["string", "null"],
                "enum": run_states,
                "description": "The run state reached, for `run`: a state, not the session \
                                listing's `run`, which says whether it is a run session.",
            },
            "match": {
                "type": ["object", "null"],
                "description": "What the regex matched, for `regex`.",
                "required": ["text"],
                "properties": {"text": {
                    "type": "string",
                    "description": "The matched text, escape sequences stripped.",
                }},
            },
            "exit_code": {
                "type": ["integer", "null"],
                "description": "The run's exit code (`run: exited`), the command's \
                                (`command_finished`), or the session's shell's (`ended`), when \
                                there is one.",
            },
        },
    })
}

pub const ERRORS: &[&str] = &[
    kind::TARGET_NOT_FOUND,
    kind::TARGET_AMBIGUOUS,
    kind::WAIT_TIMEOUT,
    kind::SESSION_ENDED,
    kind::NO_SHELL_INTEGRATION,
    kind::EXIT_CODE_MISMATCH,
    kind::BUSY,
    kind::INTERNAL_ERROR,
];

pub fn params_example() -> Value {
    json!({"target": "dev server", "regex": "ready in \\d+ ms", "timeout_ms": 30000})
}

pub fn result_example() -> Value {
    json!({
        "session": "c0ffee00-1111-4222-8333-44445555beef",
        "condition": "regex",
        "status": null,
        "run_state": null,
        "match": {"text": "ready in 312 ms"},
        "exit_code": null,
    })
}

/// The most waits held at once: on one session, from one connection, and on the whole daemon.
/// Each wait is a thread and a matcher on its session's output, so they are bounded; one past a
/// bound is refused with `Busy` rather than queued, and a retry once one has ended can succeed.
/// Implementation limits, not contract (ADR 0079): a release may change them.
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub session: usize,
    pub connection: usize,
    pub daemon: usize,
}

pub const LIMITS: Limits = Limits {
    session: 32,
    connection: 64,
    daemon: 512,
};

/// The daemon's waits, each holding a `Slot` of `LIMITS.daemon` until its thread ends.
static WAITS: AtomicUsize = AtomicUsize::new(0);

/// How a wait's thread is started: `std::thread`, but for a test's seam.
type Spawn = fn(Box<dyn FnOnce() + Send>) -> std::io::Result<()>;

fn spawn_thread(work: Box<dyn FnOnce() + Send>) -> std::io::Result<()> {
    std::thread::Builder::new()
        .name("terminal wait".into())
        .spawn(work)
        .map(drop)
}

/// One connection's waits, cancelled when it closes: a caller that has gone away is waited for by
/// nobody, and must not leave a matcher on a session's output.
pub struct Waits {
    held: Vec<Arc<Waiter>>,
    limits: Limits,
    /// What the daemon's waits count against: `WAITS`, or a test's own.
    daemon: &'static AtomicUsize,
    spawn: Spawn,
}

impl Default for Waits {
    fn default() -> Waits {
        Waits {
            held: Vec::new(),
            limits: LIMITS,
            daemon: &WAITS,
            spawn: spawn_thread,
        }
    }
}

impl Waits {
    /// A connection's waits under `limits`, counted against `daemon` and started by `spawn`, so a
    /// test reaches each bound with a few waits and its own counter.
    #[cfg(test)]
    pub fn with(limits: Limits, daemon: &'static AtomicUsize, spawn: Option<Spawn>) -> Waits {
        Waits {
            held: Vec::new(),
            limits,
            daemon,
            spawn: spawn.unwrap_or(spawn_thread),
        }
    }

    /// How many waits the connection holds, ended ones not yet pruned included.
    #[cfg(test)]
    pub fn held_count(&self) -> usize {
        self.held.len()
    }
}

impl Drop for Waits {
    fn drop(&mut self) {
        for waiter in &self.held {
            waiter.cancel();
        }
    }
}

fn busy(held: usize, on: &str) -> ApiError {
    ApiError::new(
        kind::BUSY,
        format!(
            "{held} waits are already held on {on}, the most it holds at once; try again when one \
             has ended"
        ),
    )
}

/// A wait, parsed: what for, on which session, until when.
struct Request {
    id: SessionId,
    name: &'static str,
    include_screen: bool,
    /// For `run: exited`, the code it should exit with.
    exit_code: Option<i32>,
    /// None: no limit.
    deadline: Option<Instant>,
}

/// Starts the wait `params` asks for, answering on `stream` now when it fails or is already met,
/// else from its own thread when it ends.
pub fn start(waits: &mut Waits, call: &Call, writer: &SharedWriter, stream: u32) {
    let sessions = call.sessions;
    let send = {
        let writer = Arc::clone(writer);
        // One reply, the stream's last: a wait answers once.
        move |result: Result<Value, ApiError>| {
            super::send(&writer, stream, super::reply(result, false));
        }
    };
    let (request, waiter, slot) = match register(waits, sessions, call.params) {
        Ok(started) => started,
        Err(error) => return send(Err(error)),
    };
    if let Some(outcome) = waiter.outcome() {
        sessions.remove_waiter(request.id, &waiter);
        return send(result(&request, outcome));
    }
    waits.held.push(Arc::clone(&waiter));
    // What a thread that never starts needs to undo its wait: everything else is the thread's.
    let (id, held, answer) = (request.id, Arc::clone(&waiter), send.clone());
    let owned = sessions.clone();
    let spawned = (waits.spawn)(Box::new(move || {
        let _slot = slot;
        let outcome = waiter.wait(request.deadline);
        owned.remove_waiter(request.id, &waiter);
        if outcome != Outcome::Cancelled {
            send(result(&request, outcome));
        }
    }));
    if let Err(error) = spawned {
        crate::note!("terminal API: no thread for a wait: {error}");
        sessions.remove_waiter(id, &held);
        waits.held.retain(|waiter| !Arc::ptr_eq(waiter, &held));
        answer(Err(ApiError::new(
            kind::INTERNAL_ERROR,
            format!("the daemon could not start a thread for the wait: {error}"),
        )));
    }
}

/// Parses `params`, resolves the target, takes a place under each of `waits`' limits, and adds the
/// waiter to its session. Bad input and a target that names no one session are refused before any
/// limit is looked at, so neither is ever `Busy`.
fn register(
    waits: &mut Waits,
    sessions: &SessionStore,
    params: &Value,
) -> Result<(Request, Arc<Waiter>, Slot), ApiError> {
    let given: Vec<&str> = CONDITIONS
        .into_iter()
        .filter(|name| params.get(name).is_some_and(|value| !value.is_null()))
        .collect();
    let [name] = given.as_slice() else {
        return Err(ApiError::invalid(format!(
            "terminal.wait takes exactly one of `{}`",
            CONDITIONS.join("`, `")
        )));
    };
    let target = params
        .get("target")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid("terminal.wait needs a string `target`"))?;
    let flag = |key: &str| match params.get(key) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(on)) => Ok(*on),
        Some(_) => Err(ApiError::invalid(format!("`{key}` is a boolean"))),
    };
    let include_screen = flag("include_screen")?;
    if include_screen && *name != "regex" {
        return Err(ApiError::invalid("`include_screen` goes with `regex`"));
    }
    let deadline = match params.get("timeout_ms") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let millis = value
                .as_u64()
                .ok_or_else(|| ApiError::invalid("`timeout_ms` is a whole number, 0 or more"))?;
            // Past what an `Instant` holds is no limit.
            Instant::now().checked_add(Duration::from_millis(millis))
        }
    };
    let exit_code = match params.get("exit_code") {
        None | Some(Value::Null) => None,
        Some(value) => Some(
            value
                .as_i64()
                .and_then(|code| i32::try_from(code).ok())
                .ok_or_else(|| ApiError::invalid("`exit_code` is an integer"))?,
        ),
    };
    let text = |key: &str| {
        params[key]
            .as_str()
            .ok_or_else(|| ApiError::invalid(format!("`{key}` is a string")))
    };
    let shadowed = cfg!(feature = "terminal-state");
    let without_shadow = |what: &str| {
        ApiError::invalid(format!(
            "{what} needs the shadow terminal, which this daemon was built without (terminal-state)"
        ))
    };
    let condition = match *name {
        "status" => {
            let state = text("status")?;
            let state: State = serde_json::from_value(json!(state)).map_err(|_| {
                ApiError::invalid(format!("`status` is one of {}", STATES.join(", ")))
            })?;
            if !shadowed {
                return Err(without_shadow("waiting for a program status"));
            }
            Condition::Status(state)
        }
        "run" => {
            let state = RunState::named(text("run")?).ok_or_else(|| {
                let names: Vec<&str> = RunState::ALL.iter().map(|state| state.name()).collect();
                ApiError::invalid(format!("`run` is one of {}", names.join(", ")))
            })?;
            if exit_code.is_some() && state != RunState::Exited {
                return Err(ApiError::invalid("`exit_code` goes with `run: exited`"));
            }
            Condition::Run(state)
        }
        "regex" => {
            let matcher = Matcher::new(text("regex")?)
                .map_err(|error| ApiError::invalid(format!("`regex` is not a regex: {error}")))?;
            if include_screen && !shadowed {
                return Err(without_shadow("`include_screen`"));
            }
            Condition::Output(matcher)
        }
        "ended" if flag("ended")? => Condition::Ended,
        "command_finished" if flag("command_finished")? => {
            if !shadowed {
                return Err(without_shadow("waiting for a command to finish"));
            }
            Condition::CommandFinished
        }
        other => return Err(ApiError::invalid(format!("`{other}` is `true` when given"))),
    };
    if exit_code.is_some() && *name != "run" {
        return Err(ApiError::invalid("`exit_code` goes with `run: exited`"));
    }

    let session = resolve(&listed(sessions), target)?;
    let id = session["id"]
        .as_str()
        .and_then(|id| wr_protocol::terminal::parse_session_id(std::ffi::OsStr::new(id)))
        .expect("a listed session's id parses");
    let run = matches!(condition, Condition::Run(_));
    if run && session["run"] != true {
        return Err(ApiError::invalid(format!(
            "{target:?} is not a run session, so it has no run state"
        )));
    }
    let request = Request {
        id,
        name,
        include_screen,
        exit_code,
        deadline,
    };
    // A precondition of the session's, before any bound: a wait that could never be met is
    // refused as such, never as `Busy`. A shell's marks only ever start, so one seen here is
    // still there when the waiter is added.
    if matches!(condition, Condition::CommandFinished)
        && let Some(shadow) = sessions.shadow(id)
        && !lock_or_recover(&shadow).has_shell_marks()
    {
        return Err(ApiError::new(
            kind::NO_SHELL_INTEGRATION,
            format!(
                "{target:?} has sent no shell integration marks (OSC 133), so the end of its \
                 command can't be seen"
            ),
        ));
    }
    // Only waits not yet over count: a thread ending its wait leaves it here a moment longer.
    waits.held.retain(|held| held.outcome().is_none());
    if waits.held.len() >= waits.limits.connection {
        return Err(busy(waits.held.len(), "this connection"));
    }
    let slot = Slot::acquire_from(waits.daemon, waits.limits.daemon)
        .ok_or_else(|| busy(waits.limits.daemon, "this daemon"))?;
    let most = waits.limits.session;
    let mut condition = condition;
    let added = sessions.add_waiter(id, |shadow, held| {
        if held >= most {
            return Err(busy(held, &format!("session {}", id.to_hyphenated())));
        }
        // Joined mid-sequence, the next bytes are its rest, never text.
        if let Condition::Output(matcher) = &mut condition
            && shadow.mid_sequence()
        {
            matcher.resync();
        }
        let waiter = Arc::new(Waiter::new(condition, shadow.seen()));
        if request.include_screen {
            waiter.screen(shadow.visible_text().as_bytes());
        }
        Ok(waiter)
    });
    let waiter = match added {
        Some(added) => added?,
        // Gone since it was resolved: it has ended, which is all `ended` waits for.
        None if *name != "ended" => return Err(ended_error(&request)),
        None => {
            let waiter = Arc::new(Waiter::new(Condition::Ended, Default::default()));
            waiter.ended(None);
            waiter
        }
    };
    // The run's state now, read after the waiter is added: a change from here on reaches it from
    // the runs watcher, so none is missed between the two.
    if run
        && let Some(path) = sessions.hooks().runs.status_path(id)
        && let Ok(line) = std::fs::read_to_string(path)
    {
        waiter.run(line.trim());
    }
    Ok((request, waiter, slot))
}

fn ended_error(request: &Request) -> ApiError {
    ApiError::new(
        kind::SESSION_ENDED,
        format!(
            "session {} ended before what it was waited for happened",
            request.id.to_hyphenated()
        ),
    )
}

/// The reply to a wait that ended with `outcome`.
fn result(request: &Request, outcome: Outcome) -> Result<Value, ApiError> {
    let mut reply = json!({
        "session": request.id.to_hyphenated(),
        "condition": request.name,
        "status": null,
        "run_state": null,
        "match": null,
        "exit_code": null,
    });
    match outcome {
        Outcome::Met(Met::Status(state)) => reply["status"] = json!(state),
        Outcome::Met(Met::Run { state, exit_code }) => {
            // An exit, but not with the code asked for: answered now, since it will not exit
            // again until it is restarted, and refused, so a script's `&&` stops there. The code
            // it did exit with is in `details`, for a script to read.
            if let Some(wanted) = request.exit_code
                && exit_code != Some(wanted)
            {
                let exited =
                    exit_code.map_or("an unknown code".into(), |code| format!("code {code}"));
                let mut error = ApiError::new(
                    kind::EXIT_CODE_MISMATCH,
                    format!(
                        "session {}'s run exited with {exited}, not {wanted}",
                        request.id.to_hyphenated()
                    ),
                );
                error.details = Some(json!({"exit_code": exit_code}));
                return Err(error);
            }
            reply["run_state"] = json!(state.name());
            reply["exit_code"] = json!(exit_code);
        }
        Outcome::Met(Met::Output(text)) => {
            reply["match"] = json!({"text": String::from_utf8_lossy(&text)});
        }
        Outcome::Met(Met::Ended(exit_code) | Met::CommandFinished(exit_code)) => {
            reply["exit_code"] = json!(exit_code);
        }
        Outcome::SessionEnded => return Err(ended_error(request)),
        Outcome::TimedOut => {
            return Err(ApiError::new(
                kind::WAIT_TIMEOUT,
                format!("the wait for `{}` timed out", request.name),
            ));
        }
        // Never answered: nobody is there to read it.
        Outcome::Cancelled => {}
    }
    Ok(reply)
}
