//! `terminal.send` (#689): types into a session without attaching to it. Its text goes in as it
//! is given, as a bracketed paste when the program has turned that on; then its keys, each named
//! (`terminal::keys`) and encoded for the session's keyboard modes; then Enter, when asked.
//!
//! **No client.** The bytes go to the pty and nowhere else (`SessionStore::send_input`): no
//! repaint, nobody counted as attached, no size claimed or arbitrated (ADR 0042), no keepalive
//! probes, so a send can't change what anyone watching the pane sees, but for the program's own
//! answer to what it was typed.
//!
//! **Refusals**, bad input first, as every method's: parameters it can't read, a key it can't
//! name or text holding the paste's end (`InvalidRequest`), more than [`MAX_BYTES`] to type
//! (`TooLarge`); then a target that names no one session; then the caller's own session without
//! `allow_self` (`RefusedSelf`), keys for a session whose modes the daemon can't read
//! (`InternalError`), and a hand-off under way (`Busy`).
//!
//! **Bounded.** A send types for at most [`DEADLINE`], its wait for the session's input included,
//! and holds an `rpc::Permit` meanwhile, so a hand-off waits for it, or is refused, rather than
//! cut it off. One that stops early says how many bytes went (`cut_short`), and never leaves its
//! paste open for what comes next (`Pty::send`).
//!
//! **Every send is told** (`session.input`, `crate::terminal::events`), naming the session it came
//! from, before it is typed: a send the events can't tell, while a hand-off holds them, is refused.

use std::ffi::OsStr;
use std::time::Duration;

use serde_json::{Value, json};

use super::{Answer, ApiError, Call, caller_schema, kind, listed, resolve};
use crate::terminal::keys::{self, Key, Modes};
use crate::terminal::pty::{Stop, Stopped};

pub const NAME: &str = "terminal.send";

/// The most one send types, its bracketed paste's markers aside: text, keys and Enter together.
/// More is refused whole rather than typed in parts, so a paste never arrives half-typed.
pub const MAX_BYTES: usize = 1024 * 1024;

pub const ERRORS: &[&str] = &[
    kind::TARGET_NOT_FOUND,
    kind::TARGET_AMBIGUOUS,
    kind::TOO_LARGE,
    kind::REFUSED_SELF,
    kind::SESSION_ENDED,
    kind::BUSY,
    kind::INTERNAL_ERROR,
];

pub fn input() -> Value {
    let flag = |description: &str| json!({"type": "boolean", "default": false, "description": description});
    json!({
        "type": "object",
        "required": ["target"],
        "properties": {
            "target": {
                "type": "string",
                "description": "A session's id or id suffix, its label, or its live title.",
            },
            "text": {
                "type": "string",
                "description": "Typed as it is, first: as a bracketed paste when the session's \
                                program has turned that on. It may not hold the paste's end \
                                (ESC [ 2 0 1 ~, or its C1 form, U+009B 2 0 1 ~), which would \
                                end the paste early.",
            },
            "keys": {
                "type": "array",
                "items": {"type": "string"},
                "description": "Named keys, typed after the text in order, each encoded for the \
                                session's keyboard modes (kitty keyboard flags, application \
                                cursor keys): Enter, Tab, Escape (or Esc), Backspace, Space, Up, \
                                Down, Left, Right, Home, End, Insert, Delete, PageUp, PageDown, \
                                F1 to F12 or one character, after any of Ctrl+, Alt+, Shift+ \
                                and Super+, in any case (`Ctrl+C`, `Shift+Tab`).",
            },
            "enter": flag("Enter last, after the text and the keys."),
            "allow_self": flag(
                "Type into the caller's own session, which is otherwise refused with \
                 `RefusedSelf`.",
            ),
        },
    })
}

pub fn output() -> Value {
    let flag = |description: &str| json!({"type": "boolean", "description": description});
    json!({
        "type": "object",
        "required": ["session", "caller", "bytes", "modes"],
        "properties": {
            "session": {"type": "string", "description": "The id of the session typed into."},
            "caller": caller_schema(),
            "bytes": {
                "type": "integer",
                "description": "How many bytes were typed, a bracketed paste's markers included.",
            },
            "modes": {
                "type": ["object", "null"],
                "description": "The session's modes what was typed was encoded for. Null when \
                                the daemon can't read them (built without terminal-state, or its \
                                shadow terminal failed): the text then went as it is, never as a \
                                paste, and keys are refused.",
                "required": ["kitty_keyboard_flags", "application_cursor_keys", "bracketed_paste"],
                "properties": {
                    "kitty_keyboard_flags": {
                        "type": "integer",
                        "description": "The kitty keyboard protocol's flags its program pushed; \
                                        0 for none, the legacy encoding.",
                    },
                    "application_cursor_keys": flag("DECCKM: cursor keys as SS3."),
                    "bracketed_paste": flag(
                        "Bracketed paste (`CSI ? 2004 h`): the text went as a paste.",
                    ),
                },
            },
        },
    })
}

pub fn params_example() -> Value {
    json!({"target": "dev server", "text": "npm test", "enter": true})
}

pub fn result_example() -> Value {
    json!({
        "session": "c0ffee00-1111-4222-8333-44445555beef",
        "caller": "5a1e0f7e-0d6c-4c9f-9c3e-2b7f1d0a8e11",
        "bytes": 21,
        "modes": {"kitty_keyboard_flags": 0, "application_cursor_keys": false, "bracketed_paste": true},
    })
}

/// What one send asks to type.
struct Asked {
    target: String,
    text: String,
    keys: Vec<Key>,
    allow_self: bool,
}

/// `call`'s params, or why they are refused.
fn asked(call: &Call) -> Result<Asked, ApiError> {
    let params = call.params;
    let flag = |name: &str| match params.get(name) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(on)) => Ok(*on),
        Some(_) => Err(ApiError::invalid(format!("{NAME}'s `{name}` is a boolean"))),
    };
    let target = params
        .get("target")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid(format!("{NAME} needs a string `target`")))?
        .to_string();
    let text = match params.get("text") {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(text)) => text.clone(),
        Some(_) => return Err(ApiError::invalid(format!("{NAME}'s `text` is a string"))),
    };
    let mut keys = match params.get("keys") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(names)) => names
            .iter()
            .map(|name| {
                let name = name.as_str().ok_or_else(|| {
                    ApiError::invalid(format!("{NAME}'s `keys` are each a key's name"))
                })?;
                Key::parse(name).map_err(ApiError::invalid)
            })
            .collect::<Result<Vec<_>, _>>()?,
        Some(_) => {
            return Err(ApiError::invalid(format!(
                "{NAME}'s `keys` is a list of key names"
            )));
        }
    };
    if flag("enter")? {
        keys.push(Key::ENTER);
    }
    if text.is_empty() && keys.is_empty() {
        return Err(ApiError::invalid(format!(
            "{NAME} has nothing to type: give it `text`, `keys` or `enter`"
        )));
    }
    if keys::holds_paste_end(&text) {
        return Err(ApiError::invalid(
            "the text holds a bracketed paste's end (ESC [ 2 0 1 ~, or C1's CSI 2 0 1 ~), which \
             would end the paste early and type what follows it as keys",
        ));
    }
    if text.len() > MAX_BYTES {
        return Err(too_large(text.len()));
    }
    Ok(Asked {
        target,
        text,
        keys,
        allow_self: flag("allow_self")?,
    })
}

fn too_large(bytes: usize) -> ApiError {
    ApiError::new(
        kind::TOO_LARGE,
        format!(
            "this send types {bytes} bytes, more than the {MAX_BYTES} one send types; it is \
             refused whole, not typed in parts"
        ),
    )
}

/// The longest one send types for, its wait for the session's input included (`Pty::send`): a
/// program reading slowly is typed into for no longer, and an open paste is then closed, within
/// the pty's `WRITE_DEADLINE` more. The CLI waits for the answer past both (`terminal_api`).
pub const DEADLINE: Duration = Duration::from_secs(30);

/// How long after [`DEADLINE`] a send's answer may still come: closing its paste.
pub const DEADLINE_GRACE: Duration = crate::terminal::pty::WRITE_DEADLINE;

/// The error for a send that stopped before typing all `total` bytes, saying how many went.
/// `Busy` when another input to the session held it until the deadline, which a retry can get
/// past; `InternalError` when the program stopped reading or read too slowly, which a retry would
/// meet again.
fn cut_short(session: &str, stopped: &Stopped, total: usize) -> ApiError {
    let written = stopped.written;
    let paste = if stopped.paste_open {
        "; its paste was left open, and is closed before anything else is typed into the session"
    } else {
        ""
    };
    let (kind, why) = match &stopped.why {
        Stop::Turn => (
            kind::BUSY,
            format!(
                "another input to session {session} was still being typed after {} s; try \
                 again when it has been",
                DEADLINE.as_secs()
            ),
        ),
        Stop::Stalled => (
            kind::INTERNAL_ERROR,
            format!(
                "session {session}'s program read nothing for {} s",
                crate::terminal::pty::WRITE_DEADLINE.as_secs()
            ),
        ),
        Stop::Deadline => (
            kind::INTERNAL_ERROR,
            format!(
                "session {session}'s program read too slowly to take it within {} s",
                DEADLINE.as_secs()
            ),
        ),
        Stop::Failed(error) => (
            kind::INTERNAL_ERROR,
            format!("typing into session {session} failed: {error}"),
        ),
    };
    ApiError::new(
        kind,
        format!("{why}; {written} of {total} bytes were typed{paste}"),
    )
}

/// `terminal.send`: what is asked checked, the target resolved, then what it types encoded for
/// the session's modes, told, and written.
pub fn send(call: &Call) -> Result<Answer, ApiError> {
    let asked = asked(call)?;
    let session = resolve(&listed(call.sessions), &asked.target)?;
    let hyphenated = session["id"].as_str().unwrap_or_default().to_string();
    if !asked.allow_self && call.caller.as_deref() == Some(hyphenated.as_str()) {
        return Err(ApiError::new(
            kind::REFUSED_SELF,
            format!(
                "{:?} is the session this request comes from, and typing into it would feed its \
                 own input; `allow_self` types into it anyway",
                asked.target
            ),
        ));
    }
    let ended = || {
        ApiError::new(
            kind::SESSION_ENDED,
            format!("session {hyphenated} ended before it could be typed into"),
        )
    };
    let id = wr_protocol::terminal::parse_session_id(OsStr::new(&hyphenated)).ok_or_else(ended)?;
    let shadow = call.sessions.shadow(id).ok_or_else(ended)?;
    let modes: Option<Modes> = crate::util::lock_or_recover(&shadow).input_modes();
    if modes.is_none() && !asked.keys.is_empty() {
        return Err(ApiError::new(
            kind::INTERNAL_ERROR,
            format!(
                "{}, so it can't tell how session {hyphenated}'s program wants keys encoded; \
                 text alone goes as it is",
                super::no_screen(&hyphenated)
            ),
        ));
    }
    let bracketed = modes.is_some_and(|modes| modes.bracketed_paste);
    let mut typed = keys::pasted(&asked.text, bracketed);
    let paste = (bracketed && !asked.text.is_empty()).then_some(0..typed.len());
    let mut length = asked.text.len();
    for key in &asked.keys {
        let bytes = key.encode(modes.unwrap_or_default());
        length += bytes.len();
        typed.extend(bytes);
    }
    if length > MAX_BYTES {
        return Err(too_large(length));
    }
    // Held while it types, so a hand-off waits for it, or is refused, rather than cut it off with
    // the exec; and refused while one is under way.
    let Some(_permit) = crate::daemon::rpc::Permit::acquire() else {
        return Err(ApiError::new(
            kind::BUSY,
            "the daemon is being handed off to its next program, or is at its limit on \
             requests at once; try again when it has been",
        ));
    };
    let until = std::time::Instant::now() + DEADLINE;
    let hub = &call.sessions.hooks().events;
    if !hub.input(
        id,
        session["scope"].clone(),
        call.caller.as_deref(),
        typed.len(),
    ) {
        return Err(ApiError::new(
            kind::BUSY,
            "the daemon is being handed off to its next program; try again when it has been",
        ));
    }
    match call.sessions.send_input(id, &typed, paste, until) {
        None => return Err(ended()),
        Some(Err(_)) if !call.sessions.contains(id) => return Err(ended()),
        Some(Err(stopped)) => return Err(cut_short(&hyphenated, &stopped, typed.len())),
        Some(Ok(())) => {}
    }
    Ok(Answer::One(json!({
        "session": hyphenated,
        "caller": call.caller,
        "bytes": typed.len(),
        "modes": modes.map(|modes| json!({
            "kitty_keyboard_flags": modes.kitty_keyboard_flags,
            "application_cursor_keys": modes.application_cursor_keys,
            "bracketed_paste": modes.bracketed_paste,
        })),
    })))
}
